--!strict
-- domain/handlers/RenderHandlers.luau
--
-- Phase 5 — three render endpoints, thin domain wrappers over the
-- runtime/render/ modules:
--   - captureScreenshot   ← legacy plugin.luau L6045-6228
--   - renderObjectView    ← legacy plugin.luau L6378-6691
--   - focusCamera         ← legacy plugin.luau L6700-6802
--
-- ============================================================================
-- WHY ONLY THIN WRAPPERS LIVE HERE
-- ============================================================================
-- All the heavy lifting (CaptureService, AssetService, ViewportFrame, Camera
-- math) is in runtime/render/. The domain layer's job is exactly two things:
--   1. Path-resolve the caller's `instancePath` (and Companions-refuse if
--      the resolved instance is a protected test companion).
--   2. Hand the validated arguments to runtime/render/ and shape the result
--      into the wire response the bridge expects.
--
-- Keeping the handlers this small makes the legacy diff trivially auditable
-- — every Studio API call is in runtime/render/, every dispatcher contract
-- (RecordResult, refusal payload, error shape) is here.
--
-- ============================================================================
-- WHY captureScreenshot AND focusCamera ARE NOT WRITES
-- ============================================================================
-- captureScreenshot reads the framebuffer. focusCamera writes the Studio
-- camera CFrame but does NOT touch the saved DataModel — the Studio
-- camera is per-session UI state, not persisted. Both return `nil` as
-- their RecordResult, which tells the Dispatcher to skip CHS + ActionLog
-- entirely. renderObjectView clones the target instance into a transient
-- WorldModel and destroys it inside the runtime/render module; the user-
-- visible workspace is never touched.
--
-- ============================================================================
-- LLM-STOMP PROTECTION
-- ============================================================================
-- renderObjectView clones the target instance. If a caller asked to render
-- the test companion, we'd briefly host a copy of the companion under
-- CoreGui and then destroy it — the source companion is untouched. Still,
-- we refuse for two reasons:
--   1. The cloned companion still runs its top-level code in some Studio
--      builds while parented to a WorldModel, which could re-establish
--      HTTP polling from the wrong DataModel.
--   2. Symmetry with the rest of the destructive handlers — if it's
--      protected for one, it's protected for all. Easier to reason about.
-- focusCamera and captureScreenshot have no instance mutation surface; the
-- companion refusal does not apply.

local Handler = require(script.Parent.Parent.handler.Handler)
local Path = require(script.Parent.Parent.Parent.runtime.instance.Path)
local Companions = require(script.Parent.Parent.Parent.runtime.testsession.Companions)
local Screenshot = require(script.Parent.Parent.Parent.runtime.render.Screenshot)
local Viewport = require(script.Parent.Parent.Parent.runtime.render.Viewport)
local CameraHelpers = require(script.Parent.Parent.Parent.runtime.render.Camera)

-- ============================================================================
-- TYPED REQUEST SHAPES
-- ============================================================================

type CaptureScreenshotRequest = {
	maxWidth: number?,
	maxHeight: number?,
	returnBase64: boolean?,
}

type RenderObjectViewRequest = {
	instancePath: string?,
	resolution: Viewport.ResolutionParam?,
	angle: any?,
	lighting: string?,
	background: string?,
	backgroundColor: Viewport.ColorRGB?,
	autoDistance: boolean?,
}

type FocusCameraRequest = {
	instancePath: string?,
	angle: any?, -- string preset or { pitch, yaw, roll? }
	distance: number?,
	autoDistance: boolean?,
}

-- ============================================================================
-- HANDLERS
-- ============================================================================

local RenderHandlers = {}

-- captureScreenshot: full-screen capture from CaptureService. Legacy L6045-6228.
-- Read-only as far as the DataModel is concerned (the call doesn't mutate any
-- instances). Returns base64 RGBA + diagnostics. RecordResult = nil so the
-- dispatcher skips CHS + ActionLog.
RenderHandlers.captureScreenshot = Handler.define(
	"/api/capture-screenshot",
	function(ctx, data: CaptureScreenshotRequest): (any, Handler.RecordResult?)
		local request: Screenshot.CaptureRequest = {
			maxWidth = data.maxWidth,
			maxHeight = data.maxHeight,
			returnBase64 = data.returnBase64,
		}
		local result = Screenshot.capture({
			captureService = ctx.services.captureService,
			assetService = ctx.services.assetService,
		}, request)
		-- Screenshot.capture returns a well-formed CaptureResult on both
		-- success and failure (never throws), so we can pass it through
		-- unmodified. The dispatcher sees `nil` RecordResult and treats
		-- this as read-only.
		return result, nil
	end
)

-- renderObjectView: off-screen ViewportFrame render. Legacy L6378-6691.
-- The path resolution + Companions refusal live here (domain concern);
-- the rendering itself is fully in runtime/render/Viewport.luau.
RenderHandlers.renderObjectView = Handler.define(
	"/api/render-object-view",
	function(ctx, data: RenderObjectViewRequest): (any, Handler.RecordResult?)
		local instancePath = data.instancePath
		if instancePath == nil or instancePath == "" then
			return { success = false, error = "instancePath is required" }, nil
		end

		local target = Path.getInstanceByPath(instancePath)
		if target == nil then
			return { success = false, error = "Instance not found: " .. instancePath }, nil
		end

		-- Refuse if the target is a protected test companion. See top-of-
		-- file rationale.
		local deps = { services = ctx.services, constants = ctx.constants }
		local refusal = Companions.refuseIfProtected(deps, target)
		if refusal ~= nil then
			-- Match the success=false shape captureScreenshot uses; the
			-- bridge surfaces .error to the LLM either way.
			refusal.success = false
			return refusal, nil
		end

		local request: Viewport.ViewportRequest = {
			resolution = data.resolution,
			angle = data.angle,
			lighting = data.lighting,
			background = data.background,
			backgroundColor = data.backgroundColor,
			autoDistance = data.autoDistance,
		}
		local result = Viewport.renderObject({
			captureService = ctx.services.captureService,
			assetService = ctx.services.assetService,
			coreGui = ctx.services.coreGui,
			runService = ctx.services.runService,
		}, target, request)
		return result, nil
	end
)

-- focusCamera: drive the Studio camera onto an object. Legacy L6700-6802.
-- We do NOT lock CameraType — Studio's mouse/WASD navigation continues to
-- work after this call. The camera CFrame change is per-session UI state,
-- not a DataModel mutation, so we skip CHS + ActionLog.
RenderHandlers.focusCamera = Handler.define(
	"/api/focus-camera",
	function(_ctx, data: FocusCameraRequest): (any, Handler.RecordResult?)
		local instancePath = data.instancePath
		if instancePath == nil or instancePath == "" then
			return { success = false, error = "instancePath is required" }, nil
		end

		local target = Path.getInstanceByPath(instancePath)
		if target == nil then
			return { success = false, error = "Instance not found: " .. instancePath }, nil
		end

		local anglePreset: any = data.angle or "iso"
		local customDistance = tonumber(data.distance)
		local autoDistance = data.autoDistance ~= false

		local boundingSize, boundingCenter = CameraHelpers.getModelBoundingBox(target)
		local direction = CameraHelpers.resolveDirection(anglePreset)

		local camera = workspace.CurrentCamera
		if camera == nil then
			return { success = false, error = "workspace.CurrentCamera is unavailable" }, nil
		end

		-- Distance: customDistance wins, then autoDistance via bounding-sphere,
		-- else a 20-stud fallback (matches legacy default).
		local cameraDistance: number
		if customDistance ~= nil then
			cameraDistance = math.max(customDistance :: number, 0.1)
		elseif autoDistance then
			local sphereRadius = math.max(boundingSize.Magnitude / 2, 0.5)
			local viewportSize = camera.ViewportSize
			local aspect: number = 1
			if viewportSize.X > 0 and viewportSize.Y > 0 then
				aspect = viewportSize.X / viewportSize.Y
			end
			local vFovRad = math.rad(camera.FieldOfView)
			local hFovRad = 2 * math.atan(math.tan(vFovRad / 2) * aspect)
			local minFov = math.min(vFovRad, hFovRad)
			cameraDistance = (sphereRadius / math.sin(minFov / 2)) * 1.3 -- 30% padding (legacy parity)
			cameraDistance = math.max(cameraDistance, 5) -- never closer than 5 studs
		else
			cameraDistance = 20
		end

		local finalCameraPos = boundingCenter + direction * cameraDistance
		local newCFrame = CFrame.lookAt(finalCameraPos, boundingCenter)

		-- Drive Studio camera. NOT changing CameraType is intentional —
		-- preserves mouse/WASD nav after the call (legacy comment L6697-6699).
		local writeOk, writeErr = pcall(function()
			camera.CFrame = newCFrame
			camera.Focus = CFrame.new(boundingCenter)
		end)
		if not writeOk then
			return { success = false, error = "Failed to set camera CFrame: " .. tostring(writeErr) }, nil
		end

		-- Echo the angle in canonical shape. String → pass-through; table →
		-- normalised to pitch/yaw/roll number triplet.
		local angleResponse: any
		if type(anglePreset) == "string" then
			angleResponse = anglePreset
		elseif type(anglePreset) == "table" then
			angleResponse = {
				pitch = tonumber(anglePreset.pitch) or 0,
				yaw = tonumber(anglePreset.yaw) or 0,
				roll = tonumber(anglePreset.roll) or 0,
			}
		else
			angleResponse = "iso"
		end

		return {
			success = true,
			object = {
				name = target.Name,
				className = target.ClassName,
				boundingBox = {
					size = { x = boundingSize.X, y = boundingSize.Y, z = boundingSize.Z },
					center = { x = boundingCenter.X, y = boundingCenter.Y, z = boundingCenter.Z },
				},
			},
			camera = {
				position = { x = finalCameraPos.X, y = finalCameraPos.Y, z = finalCameraPos.Z },
				lookAt = { x = boundingCenter.X, y = boundingCenter.Y, z = boundingCenter.Z },
				direction = { x = direction.X, y = direction.Y, z = direction.Z },
				distance = cameraDistance,
				angle = angleResponse,
			},
			message = "Focused camera on "
				.. target.Name
				.. " from "
				.. (type(anglePreset) == "string" and anglePreset or "custom")
				.. " angle",
		},
			nil
	end
)

return RenderHandlers
