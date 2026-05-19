--!strict
-- runtime/render/Camera.luau
--
-- Phase 5 — camera-and-lighting primitives shared by Viewport.luau (the
-- off-screen ViewportFrame render path) and RenderHandlers.focusCamera
-- (the live-Studio-camera focus path). Legacy plugin.luau housed these
-- inline at L6233-6376; lifting them to a runtime module gives BOTH call
-- sites the same direction vectors and the same bounding-box semantics,
-- which is exactly what we want — render_object_view and focus_camera
-- *should* frame an object identically when passed the same angle.
--
-- ============================================================================
-- WHY UNIT DIRECTION VECTORS, NOT EULER ANGLES
-- ============================================================================
-- The 11 preset angles describe a direction FROM target TOWARD camera. We
-- combine that with CFrame.lookAt(targetCenter + dir * distance, targetCenter)
-- to produce the final camera CFrame in ONE step. Euler-based approaches
-- (the original v1 of legacy) double-applied rotation — once to construct
-- the camera CFrame and once again when the engine resolved the lookAt —
-- which made "iso" cameras roll randomly. Lookat-only is the fix.
--
-- For custom angles (caller passes a `{pitch, yaw}` table), we build the
-- direction by yaw-around-Y then pitch-around-X applied to the +Z basis,
-- then negate (LookVector points camera→target; we want target→camera).
--
-- ============================================================================
-- BOUNDING-BOX SEMANTICS
-- ============================================================================
-- getModelBoundingBox prefers Model:GetBoundingBox() when available because
-- it handles rotation and attachments uniformly. Falls back to a manual
-- 8-corner-per-part transform when the target is a single BasePart or when
-- GetBoundingBox is unavailable (e.g. Folder with parts inside). The
-- fallback projects each part's local-space size box through its world
-- CFrame and intersects all 8 corners — this gives a *rotated AABB* of
-- the world hull, not a naive min/max of CFrame.Position which would
-- under-size any rotated part.
--
-- ============================================================================
-- LIGHTING PRESETS
-- ============================================================================
-- The preset names match the legacy ("bright"/"showcase", "studio"/"flat",
-- "dark"/"dramatic", default = ambient-only). We accept aliases so existing
-- MCP requests keep working. Lights are parented under the caller's
-- WorldModel and removed in the same module — keeping them ephemeral.

local Camera = {}

-- ============================================================================
-- ANGLE PRESETS
-- ============================================================================
-- UNIT direction vectors pointing FROM target TO camera. Constructed at
-- module load so each preset is a single shared Vector3, not re-computed
-- per render call. Note: Vector3 is immutable so this is safe.
local PRESETS: { [string]: Vector3 } = {
	-- Orthographic axes
	front = Vector3.new(0, 0, 1).Unit,
	back = Vector3.new(0, 0, -1).Unit,
	right = Vector3.new(1, 0, 0).Unit,
	left = Vector3.new(-1, 0, 0).Unit,
	top = Vector3.new(0, 1, 0).Unit,
	bottom = Vector3.new(0, -1, 0).Unit,

	-- Isometric trio
	iso = Vector3.new(1, 1, 1).Unit,
	iso_front = Vector3.new(0, 1, 1).Unit,
	iso_back = Vector3.new(0, 1, -1).Unit,

	-- Dramatic angles
	low_angle = Vector3.new(0, -0.4, 1).Unit,
	high_angle = Vector3.new(0, 1.2, 0.6).Unit,
}
Camera.PRESETS = PRESETS

-- Resolve an angle argument to a unit direction Vector3.
-- Accepted shapes:
--   - string: a preset key. Unknown → falls back to "iso" (matches legacy).
--   - table:  `{ pitch = degrees?, yaw = degrees?, roll = ignored }`.
--             pitch is tilt around X, yaw is spin around Y. We start from the
--             "front" basis (+Z) and yaw, then pitch, then negate the
--             LookVector so the result points TARGET→CAMERA.
--   - anything else: "iso" fallback.
function Camera.resolveDirection(angle: any): Vector3
	if type(angle) == "string" then
		local preset = PRESETS[angle]
		if preset ~= nil then
			return preset
		end
		return PRESETS.iso
	elseif type(angle) == "table" then
		local pitch = math.rad(tonumber(angle.pitch) or 0)
		local yaw = math.rad(tonumber(angle.yaw) or 0)
		-- Start with "front" (LookVector pointing +Z), apply yaw then pitch,
		-- then negate because we want the FROM-target-to-camera direction
		-- and LookVector points the other way.
		local rotated = (CFrame.Angles(0, yaw, 0) * CFrame.Angles(pitch, 0, 0)).LookVector
		return (-rotated).Unit
	end
	return PRESETS.iso
end

-- ============================================================================
-- LIGHTING
-- ============================================================================
-- Strip existing Light/Sky/Atmosphere children, then add a preset.
-- Idempotent — calling twice with the same preset results in one set of
-- lights, not two. We intentionally do NOT touch the world's ambient
-- properties (Lighting service is global and editing it would leak state
-- outside the ViewportFrame).
function Camera.applyLightingPreset(worldModel: WorldModel, preset: string?)
	-- Strip old.
	for _, child in worldModel:GetChildren() do
		if child:IsA("Light") or child:IsA("Sky") or child:IsA("Atmosphere") then
			child:Destroy()
		end
	end

	local p = preset or "bright"

	if p == "bright" or p == "showcase" then
		-- Three-point rig: warm key, cool fill, warm rim.
		local key = Instance.new("PointLight")
		key.Brightness = 2
		key.Range = 60
		key.Color = Color3.fromRGB(255, 255, 255)
		key.Parent = worldModel

		local fill = Instance.new("PointLight")
		fill.Brightness = 1
		fill.Range = 40
		fill.Color = Color3.fromRGB(200, 220, 255)
		fill.Parent = worldModel

		local rim = Instance.new("PointLight")
		rim.Brightness = 1.5
		rim.Range = 50
		rim.Color = Color3.fromRGB(255, 240, 200)
		rim.Parent = worldModel
	elseif p == "studio" or p == "flat" then
		-- Flat / no-shadow approximation: single bright wide-range light.
		local ambient = Instance.new("PointLight")
		ambient.Brightness = 1
		ambient.Range = 100
		ambient.Color = Color3.fromRGB(255, 255, 255)
		ambient.Parent = worldModel
	elseif p == "dark" or p == "dramatic" then
		-- Single warm key, tight range for hard shadows.
		local dramatic = Instance.new("PointLight")
		dramatic.Brightness = 1.5
		dramatic.Range = 40
		dramatic.Color = Color3.fromRGB(255, 200, 150)
		dramatic.Parent = worldModel
	end
	-- Any other value → no lights added; ViewportFrame's default ambient
	-- shading applies. This is the "ambient" preset by another name.
end

-- ============================================================================
-- BOUNDING BOX
-- ============================================================================
-- Returns (size, center) in world space for a BasePart OR a Model.
-- Handles rotation correctly: for a single rotated part, project the 8
-- corners of its local size-box through its world CFrame and AABB the
-- resulting world points. For a Model, prefer Model:GetBoundingBox() —
-- it does the same projection internally and also covers MeshParts and
-- attachments uniformly. Falls back to the manual path when GetBoundingBox
-- fails or returns a zero-size box (empty model).
local CORNER_SIGNS: { Vector3 } = {
	Vector3.new(1, 1, 1),
	Vector3.new(1, 1, -1),
	Vector3.new(1, -1, 1),
	Vector3.new(1, -1, -1),
	Vector3.new(-1, 1, 1),
	Vector3.new(-1, 1, -1),
	Vector3.new(-1, -1, 1),
	Vector3.new(-1, -1, -1),
}

function Camera.getModelBoundingBox(target: Instance): (Vector3, Vector3)
	-- Path 1: Model:GetBoundingBox(). Cheapest and most correct.
	if target:IsA("Model") then
		local ok, cf, sz = pcall(function()
			return target:GetBoundingBox()
		end)
		if ok and cf ~= nil and sz ~= nil and sz.Magnitude > 0 then
			return sz, cf.Position
		end
	end

	-- Path 2: collect BaseParts (target itself + descendants) and rotated-AABB
	-- them ourselves. This handles single BaseParts and Folders-of-parts.
	local parts: { BasePart } = {}
	if target:IsA("BasePart") then
		table.insert(parts, target)
	end
	for _, child in target:GetDescendants() do
		if child:IsA("BasePart") then
			table.insert(parts, child)
		end
	end

	if #parts == 0 then
		-- Nothing to frame. Caller gets a 1×1×1 box at origin — render still
		-- produces *something*, which is friendlier than erroring.
		return Vector3.new(1, 1, 1), Vector3.new(0, 0, 0)
	end

	local huge = math.huge
	local minX, minY, minZ = huge, huge, huge
	local maxX, maxY, maxZ = -huge, -huge, -huge

	for _, part in parts do
		local cf = part.CFrame
		local h = part.Size / 2 -- half-extents in local space
		for _, s in CORNER_SIGNS do
			local world = cf * Vector3.new(h.X * s.X, h.Y * s.Y, h.Z * s.Z)
			if world.X < minX then
				minX = world.X
			end
			if world.Y < minY then
				minY = world.Y
			end
			if world.Z < minZ then
				minZ = world.Z
			end
			if world.X > maxX then
				maxX = world.X
			end
			if world.Y > maxY then
				maxY = world.Y
			end
			if world.Z > maxZ then
				maxZ = world.Z
			end
		end
	end

	local size = Vector3.new(maxX - minX, maxY - minY, maxZ - minZ)
	local center = Vector3.new((minX + maxX) / 2, (minY + maxY) / 2, (minZ + maxZ) / 2)
	return size, center
end

return Camera
