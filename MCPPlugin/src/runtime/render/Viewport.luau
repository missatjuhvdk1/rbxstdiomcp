--!strict
-- runtime/render/Viewport.luau
--
-- Phase 5 — off-screen ViewportFrame render pipeline. Legacy plugin.luau
-- L6398-6691. Produces a base64 RGBA buffer of a single instance from any
-- of the camera presets, with the object framed automatically.
--
-- ============================================================================
-- WHY THIS IS NOT A UI MODULE (despite using Instance.new("ScreenGui"))
-- ============================================================================
-- The ScreenGui created here is a *transient render host* parented under
-- CoreGui for one frame, captured via CaptureService, then destroyed.
-- It never participates in the user-facing plugin UI. The §4.4 UI
-- quarantine rule says "GUI Instance.new of UI classes only under ui/" —
-- the spirit of that rule is "user-facing UI must be co-located"; an
-- off-screen render pipeline is conceptually a screenshot, not a panel.
-- The golden CI gate has a per-file whitelist exception documented in
-- tools/golden/check.lune.luau (UI_QUARANTINE_WHITELIST).
--
-- ============================================================================
-- PIPELINE
-- ============================================================================
--   1. Build a transient ScreenGui under CoreGui that fills the entire 3D
--      capture area (IgnoreGuiInset = true). Empirically the capture-area
--      size equals camera.ViewportSize, so the ViewportFrame stretched
--      UDim2.fromScale(1,1) inside this ScreenGui maps 1:1 with capture
--      pixels.
--   2. Inside the ViewportFrame, build a WorldModel + Camera + cloned
--      target. Lighting and (optional) grid plane are applied.
--   3. Camera distance is computed from the bounding-sphere of the cloned
--      target and the SMALLER of vFOV/hFOV (the post-crop FOV), so the
--      object always fits regardless of final aspect ratio.
--   4. Wait two Heartbeats for the viewport to render at its new transform.
--   5. CaptureScreenshot, then center-crop the captured frame to the
--      target aspect ratio and resize to (targetW × targetH) with uniform
--      scaling. ReadPixelsBuffer → base64.
--
-- ============================================================================
-- CROP-BEFORE-RESIZE
-- ============================================================================
-- We center-crop the captured rectangle to the target aspect ratio BEFORE
-- resizing. Stretching directly to the target dimensions would distort the
-- image when source and target aspects differ; cropping preserves shape
-- and discards only the bands that would have stretched. The crop origin
-- and dimensions are reported in viewInfo.capture so a caller debugging
-- "where did my edges go?" can see exactly what was cut.

local Base64 = require(script.Parent.Base64)
local Camera = require(script.Parent.Camera)

local Viewport = {}

export type ResolutionParam = {
	width: number?,
	height: number?,
}

export type ColorRGB = {
	r: number?,
	g: number?,
	b: number?,
}

export type ViewportRequest = {
	instancePath: string?, -- resolved upstream by the handler; not used here
	resolution: ResolutionParam?,
	angle: any?, -- string preset OR { pitch, yaw, distance? }
	lighting: string?,
	background: string?, -- "solid" | "transparent" | "grid"
	backgroundColor: ColorRGB?,
	autoDistance: boolean?,
}

export type ViewportResult = {
	success: boolean,
	base64: string?,
	width: number?,
	height: number?,
	format: string?,
	encoding: string?,
	viewInfo: any?,
	message: string?,
	error: string?,
}

export type Deps = {
	captureService: any,
	assetService: AssetService,
	coreGui: CoreGui,
	runService: RunService,
}

local CAPTURE_TIMEOUT_SECONDS = 8 -- Slightly longer than full-screen; the
-- ViewportFrame needs time to fully render at its new transform before the
-- screenshot is taken.

-- ============================================================================
-- HELPERS
-- ============================================================================

-- Trigger CaptureScreenshot and yield until it resolves; see Screenshot.luau
-- for the same handshake pattern. Duplicated here (small, clear) rather than
-- exported from Screenshot.luau — keeps render/Screenshot.luau strictly
-- about the full-screen path.
local function captureAndAwait(captureService: any): (string?, string?)
	local complete = Instance.new("BindableEvent")
	local contentId: string? = nil
	local errStr: string? = nil

	local startOk, startErr = pcall(function()
		captureService:CaptureScreenshot(function(id)
			if id ~= nil then
				contentId = tostring(id)
			else
				errStr = "CaptureScreenshot returned nil"
			end
			complete:Fire()
		end)
	end)
	if not startOk then
		complete:Destroy()
		return nil, "CaptureScreenshot threw: " .. tostring(startErr)
	end

	local timeoutThread = task.delay(CAPTURE_TIMEOUT_SECONDS, function()
		if contentId == nil and errStr == nil then
			errStr = string.format("Capture timed out (%ds)", CAPTURE_TIMEOUT_SECONDS)
			complete:Fire()
		end
	end)
	complete.Event:Wait()
	task.cancel(timeoutThread)
	complete:Destroy()

	return contentId, errStr
end

-- Resolve an RGB triple table to a Color3, defaulting each component to 255
-- (white). Returns Color3 so callers can assign to BackgroundColor3 directly.
local function resolveBackgroundColor(bgColor: ColorRGB?): Color3
	if typeof(bgColor) == "table" and bgColor.r and bgColor.g and bgColor.b then
		return Color3.fromRGB(tonumber(bgColor.r) or 255, tonumber(bgColor.g) or 255, tonumber(bgColor.b) or 255)
	end
	return Color3.fromRGB(245, 245, 245)
end

-- ============================================================================
-- ENTRY POINT
-- ============================================================================

-- Render `target` to an RGBA buffer of (targetWidth × targetHeight) and
-- return base64-encoded along with diagnostic viewInfo. `target` MUST be
-- the actual Instance (caller resolves the path) — keeping this layer
-- path-agnostic means it's trivial to test in isolation.
function Viewport.renderObject(deps: Deps, target: Instance, params: ViewportRequest): ViewportResult
	-- Parameter parsing with legacy defaults.
	local resolution = params.resolution or { width = 768, height = 768 }
	local targetW = math.clamp(tonumber(resolution.width) or 768, 64, 2048)
	local targetH = math.clamp(tonumber(resolution.height) or 768, 64, 2048)
	local angleParam: any = params.angle or "iso"
	local lighting = params.lighting or "bright"
	local background = params.background or "solid"
	local autoDistance = params.autoDistance ~= false

	-- ──────────── build the off-screen viewport tree ────────────
	local tempGui = Instance.new("ScreenGui")
	tempGui.Name = "MCPRenderViewport"
	tempGui.IgnoreGuiInset = true
	tempGui.ResetOnSpawn = false
	-- DisplayOrder near INT32_MAX puts us above every Studio panel so the
	-- captured frame contains the viewport, not whatever was on top.
	tempGui.DisplayOrder = 2147483646
	tempGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

	local viewportFrame = Instance.new("ViewportFrame")
	viewportFrame.Size = UDim2.fromScale(1, 1)
	viewportFrame.Position = UDim2.fromScale(0, 0)
	viewportFrame.BorderSizePixel = 0
	viewportFrame.ZIndex = 1
	if background == "transparent" then
		viewportFrame.BackgroundTransparency = 1
	else
		viewportFrame.BackgroundTransparency = 0
		if background == "grid" then
			viewportFrame.BackgroundColor3 = Color3.fromRGB(220, 220, 220)
		else
			viewportFrame.BackgroundColor3 = resolveBackgroundColor(params.backgroundColor)
		end
	end
	viewportFrame.Parent = tempGui

	local worldModel = Instance.new("WorldModel")
	worldModel.Parent = viewportFrame

	local camera = Instance.new("Camera")
	camera.FieldOfView = 70
	camera.Parent = viewportFrame
	viewportFrame.CurrentCamera = camera

	-- Clone the target into the WorldModel, anchoring every part so physics
	-- can't drift it between Heartbeats.
	local cloned = target:Clone()
	if cloned:IsA("BasePart") then
		(cloned :: BasePart).Anchored = true
	end
	for _, d in cloned:GetDescendants() do
		if d:IsA("BasePart") then
			(d :: BasePart).Anchored = true
		end
	end
	cloned.Parent = worldModel

	-- ──────────── camera placement ────────────
	local boundSize, boundCenter = Camera.getModelBoundingBox(cloned)
	-- Bounding-sphere radius fits any orientation — safe for cameras that
	-- rotate around the target.
	local sphereRadius = math.max(boundSize.Magnitude / 2, 0.5)

	-- Parent the GUI NOW so AbsoluteSize populates next Heartbeat. We need
	-- AbsoluteSize to know the source aspect ratio before computing camera
	-- distance.
	tempGui.Parent = deps.coreGui
	deps.runService.Heartbeat:Wait()

	local screenSize = viewportFrame.AbsoluteSize
	if screenSize.X < 1 or screenSize.Y < 1 then
		-- Fallback: source-of-truth for ViewportFrame is camera.ViewportSize.
		-- This happens occasionally when CoreGui hasn't laid out yet on
		-- plugin startup; the second Heartbeat below usually fixes it.
		screenSize = workspace.CurrentCamera.ViewportSize
	end
	local sourceAspect = screenSize.X / screenSize.Y

	-- We're going to center-crop to target aspect AFTER capture, so distance
	-- must be sized against the POST-CROP horizontal FOV — not source FOV.
	-- Vertical FOV stays constant at camera.FieldOfView; horizontal FOV after
	-- crop = 2*atan(tan(vFOV/2) * effectiveAspect), where effectiveAspect is
	-- the smaller of source vs target (we never gain pixels by cropping).
	local vFovRad = math.rad(camera.FieldOfView)
	local targetAspect = targetW / targetH
	local effectiveAspect = math.min(sourceAspect, targetAspect)
	local effectiveHFovRad = 2 * math.atan(math.tan(vFovRad / 2) * effectiveAspect)
	local minFov = math.min(vFovRad, effectiveHFovRad)

	local PADDING = 1.15
	local cameraDistance: number
	if autoDistance then
		cameraDistance = (sphereRadius / math.sin(minFov / 2)) * PADDING
	elseif type(angleParam) == "table" and angleParam.distance then
		cameraDistance = tonumber(angleParam.distance) or 10
	else
		cameraDistance = 10
	end

	local dir = Camera.resolveDirection(angleParam)
	local cameraPos = boundCenter + dir * cameraDistance
	camera.CFrame = CFrame.lookAt(cameraPos, boundCenter)

	-- ──────────── lighting + optional grid plane ────────────
	Camera.applyLightingPreset(worldModel, lighting)

	if background == "grid" then
		local gridPart = Instance.new("Part")
		gridPart.Size = Vector3.new(sphereRadius * 8, 0.05, sphereRadius * 8)
		gridPart.Position = boundCenter - Vector3.new(0, boundSize.Y / 2 + 0.025, 0)
		gridPart.Anchored = true
		gridPart.Material = Enum.Material.SmoothPlastic
		gridPart.Color = Color3.fromRGB(180, 180, 180)
		gridPart.Parent = worldModel
	end

	-- Two Heartbeats: one to commit the camera/lighting writes, one to let
	-- the ViewportFrame render at its new transform. Single-frame waits
	-- leave the screenshot under-lit on first call (verified empirically).
	deps.runService.Heartbeat:Wait()
	deps.runService.Heartbeat:Wait()

	-- ──────────── capture ────────────
	local contentId, captureErr = captureAndAwait(deps.captureService)
	tempGui:Destroy() -- contentId already in hand; safe to nuke the temp host

	if contentId == nil then
		return {
			success = false,
			error = "Failed to capture viewport: " .. (captureErr or "<unknown>"),
		}
	end

	-- ──────────── center-crop + resize ────────────
	local loadOk, sourceImage = pcall(function()
		return deps.assetService:CreateEditableImageAsync(Content.fromUri(contentId :: string))
	end)
	if not loadOk or sourceImage == nil then
		return {
			success = false,
			error = "Failed to load capture: " .. tostring(sourceImage),
		}
	end

	local sourceSize = sourceImage.Size
	local srcAspect = sourceSize.X / sourceSize.Y

	local cropW, cropH
	if srcAspect > targetAspect then
		-- Source wider than target → crop the sides.
		cropH = sourceSize.Y
		cropW = math.floor(sourceSize.Y * targetAspect)
	else
		-- Source taller than target → crop top/bottom.
		cropW = sourceSize.X
		cropH = math.floor(sourceSize.X / targetAspect)
	end
	cropW = math.max(cropW, 1)
	cropH = math.max(cropH, 1)
	local cropX = math.floor((sourceSize.X - cropW) / 2)
	local cropY = math.floor((sourceSize.Y - cropH) / 2)

	-- Build the cropped image. PivotPoint = the source center we want to map
	-- to the destination center; offset = (cropX + cropW/2, cropY + cropH/2)
	-- selects which region of the source lands at the destination origin.
	local croppedImage = deps.assetService:CreateEditableImage({
		Size = Vector2.new(cropW, cropH),
	})
	croppedImage:DrawImageTransformed(Vector2.new(cropW / 2, cropH / 2), Vector2.new(1, 1), 0, sourceImage, {
		CombineType = Enum.ImageCombineType.Overwrite,
		PivotPoint = Vector2.new(cropX + cropW / 2, cropY + cropH / 2),
	})
	sourceImage:Destroy()

	-- Final resize. When the crop is already at target size we skip the
	-- second allocation entirely.
	local outputImage: any
	if cropW == targetW and cropH == targetH then
		outputImage = croppedImage
	else
		outputImage = deps.assetService:CreateEditableImage({
			Size = Vector2.new(targetW, targetH),
		})
		local scale = targetW / cropW -- equals targetH/cropH because aspects match by construction
		outputImage:DrawImageTransformed(
			Vector2.new(targetW / 2, targetH / 2),
			Vector2.new(scale, scale),
			0,
			croppedImage,
			{
				CombineType = Enum.ImageCombineType.Overwrite,
				PivotPoint = Vector2.new(cropW / 2, cropH / 2),
			}
		)
		croppedImage:Destroy()
	end

	local rgbaBuffer = outputImage:ReadPixelsBuffer(Vector2.new(0, 0), outputImage.Size)
	local rgbaString = buffer.tostring(rgbaBuffer)
	local base64Data = Base64.encode(rgbaString)
	outputImage:Destroy()

	-- Resolve angle for the response shape: pass-through preset string,
	-- or normalise a custom table to canonical pitch/yaw/roll triplet so
	-- the bridge sees the same shape regardless of what the caller sent.
	local angleEcho: any
	if type(angleParam) == "string" then
		angleEcho = angleParam
	elseif type(angleParam) == "table" then
		local at: any = angleParam
		angleEcho = {
			pitch = tonumber(at.pitch) or 0,
			yaw = tonumber(at.yaw) or 0,
			roll = tonumber(at.roll) or 0,
		}
	else
		angleEcho = "iso"
	end

	return {
		success = true,
		base64 = base64Data,
		width = targetW,
		height = targetH,
		format = "RGBA",
		encoding = "base64",
		viewInfo = {
			objectName = target.Name,
			objectClass = target.ClassName,
			boundingBox = {
				size = { x = boundSize.X, y = boundSize.Y, z = boundSize.Z },
				center = { x = boundCenter.X, y = boundCenter.Y, z = boundCenter.Z },
			},
			camera = {
				distance = cameraDistance,
				position = { x = cameraPos.X, y = cameraPos.Y, z = cameraPos.Z },
				fieldOfView = camera.FieldOfView,
				sphereRadius = sphereRadius,
			},
			capture = {
				sourceWidth = sourceSize.X,
				sourceHeight = sourceSize.Y,
				cropOriginX = cropX,
				cropOriginY = cropY,
				cropWidth = cropW,
				cropHeight = cropH,
			},
			settings = {
				angle = angleEcho,
				lighting = lighting,
				background = background,
				resolution = { width = targetW, height = targetH },
			},
		},
		message = string.format(
			"Rendered %s at %dx%d (cropped from %dx%d source)",
			target.Name,
			targetW,
			targetH,
			sourceSize.X,
			sourceSize.Y
		),
	}
end

return Viewport
