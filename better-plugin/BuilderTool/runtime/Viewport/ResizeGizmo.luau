--!strict
-- runtime/Viewport/ResizeGizmo.luau
--
-- Six face-dot resize gizmo. One invisible Part in CurrentCamera serves as the
-- adornee; six SphereHandleAdornments sit at the bounding-box face centres
-- (one per ±X/Y/Z world axis). Dragging a dot resizes the selection along that
-- axis. AlwaysOnTop = true so dots render through geometry.

local Janitor = require(script.Parent.Parent.Parent.Packages.Janitor)

-- ── Constants ──────────────────────────────────────────────────────────────

local CAM_DIST_REF     = 10
local BASE_DOT_R       = 0.18
local FACE_OFFSET      = 0.25  -- extra studs beyond face (scales with camera distance)
local HOVER_PX         = 14
local HOVER_COLOR      = Color3.fromRGB(255, 210, 40)
local SNAP_DOT_R       = BASE_DOT_R * 1.3
local MAX_SNAP_DOTS    = 32
local ACTIVE_DOT_COLOR = Color3.fromRGB(255, 210, 40)
local IDLE_DOT_COLOR   = Color3.fromRGB(255, 255, 255)

local FACE_DATA = table.freeze({
	{ id = "PX", dir = Vector3.xAxis,  color = Color3.fromRGB(220,  50,  50) },
	{ id = "NX", dir = -Vector3.xAxis, color = Color3.fromRGB(220,  50,  50) },
	{ id = "PY", dir = Vector3.yAxis,  color = Color3.fromRGB( 50, 200,  50) },
	{ id = "NY", dir = -Vector3.yAxis, color = Color3.fromRGB( 50, 200,  50) },
	{ id = "PZ", dir = Vector3.zAxis,  color = Color3.fromRGB( 50,  90, 230) },
	{ id = "NZ", dir = -Vector3.zAxis, color = Color3.fromRGB( 50,  90, 230) },
})

-- ── Types ──────────────────────────────────────────────────────────────────

export type FaceId = "PX" | "NX" | "PY" | "NY" | "PZ" | "NZ"

export type DragState = {
	faceId:      FaceId,
	worldDir:    Vector3,  -- unit vector from bounding-box center toward dragged face
	gizmoCenter: Vector3,  -- adornee position at drag start
	initScalar:  number?,  -- first-frame projection, set once and subtracted
}

type FaceHandle = {
	id:           FaceId,
	dir:          Vector3,
	defaultColor: Color3,
	dot:          SphereHandleAdornment,
}

export type ResizeGizmo = {
	dragStarted:  RBXScriptSignal,
	show:         (self: ResizeGizmo, center: Vector3, halfExtents: Vector3) -> (),
	hide:         (self: ResizeGizmo) -> (),
	update:       (self: ResizeGizmo, center: Vector3, halfExtents: Vector3) -> (),
	drag:         (self: ResizeGizmo) -> DragState?,
	computeDelta: (self: ResizeGizmo, screenPos: Vector2) -> number,
	stopDrag:     (self: ResizeGizmo) -> (),
	showSnapDots: (self: ResizeGizmo, candidates: { Vector3 }, activeDotPos: Vector3?) -> (),
	hideSnapDots: (self: ResizeGizmo) -> (),
}

type Internal = ResizeGizmo & {
	_adornee:     Part,
	_faces:       { FaceHandle },
	_visible:     boolean,
	_drag:        DragState?,
	_signalBE:    BindableEvent,
	_hoveredFace: FaceHandle?,
	_scale:       number,
	_halfExtents: Vector3,
	_snapAdornee: Part,
	_snapDots:    { SphereHandleAdornment },
}

-- ── Math ───────────────────────────────────────────────────────────────────

-- Intersect a ray with the world-axis-aligned plane through planeOrigin that is
-- most face-on to the camera and not perpendicular to dragAxis.
local function rayBestPlane(
	rayOrigin:   Vector3,
	rayDir:      Vector3,
	planeOrigin: Vector3,
	dragAxis:    Vector3,
	camLook:     Vector3
): Vector3?
	local bestDot = -math.huge
	local normal  = Vector3.yAxis
	for _, n in { Vector3.xAxis, Vector3.yAxis, Vector3.zAxis } do
		if math.abs(n:Dot(dragAxis)) < 0.99 then
			local d = math.abs(n:Dot(camLook))
			if d > bestDot then
				bestDot = d
				normal  = n
			end
		end
	end
	local denom = normal:Dot(rayDir)
	if math.abs(denom) < 1e-6 then return nil end
	local t = normal:Dot(planeOrigin - rayOrigin) / denom
	if t < 0 then return nil end
	return rayOrigin + rayDir * t
end

local function getScale(pos: Vector3): number
	local cam = workspace.CurrentCamera
	if cam == nil then return 1 end
	return math.clamp((cam.CFrame.Position - pos).Magnitude / CAM_DIST_REF, 0.05, 50)
end

-- ── Helpers ────────────────────────────────────────────────────────────────

-- Distance from centre to the dot along face.dir (bounding box face + outward offset).
local function dotDist(faceDir: Vector3, halfExtents: Vector3, scale: number): number
	return math.abs(faceDir.X) * halfExtents.X
		+ math.abs(faceDir.Y) * halfExtents.Y
		+ math.abs(faceDir.Z) * halfExtents.Z
		+ FACE_OFFSET * scale
end

-- Apply per-dot size based on how much each face points toward the camera.
-- Dots facing away become smaller (occlusion cue without raycasting).
-- Skips hovered face (hover color owns it) and skips during drag.
local function applyOcclusion(self: Internal, center: Vector3, scale: number)
	if self._drag then return end
	local cam = workspace.CurrentCamera
	if cam == nil then return end
	local camDir = (cam.CFrame.Position - center).Unit
	for _, face in self._faces do
		if not face.dot.Visible then continue end
		local t = face.dir:Dot(camDir)  -- +1 = facing cam, -1 = back-facing
		local sizeFrac = if t >= 0 then 1 else math.max(0.35, 1 + t * 0.65)
		face.dot.Radius = BASE_DOT_R * scale * sizeFrac
		if face ~= self._hoveredFace then
			face.dot.Color3 = face.defaultColor
		end
	end
end

-- ── Constructor ────────────────────────────────────────────────────────────

local ResizeGizmo = {}
ResizeGizmo.__index = ResizeGizmo

function ResizeGizmo.new(adornmentsFolder: Folder, janitor: Janitor.Janitor, userInput: UserInputService): ResizeGizmo
	local be = Instance.new("BindableEvent")
	janitor:Add(be, "Destroy")

	local adornee = Instance.new("Part")
	adornee.Name         = "ResizeGizmoAdornee"
	adornee.Anchored     = true
	adornee.CanCollide   = false
	adornee.CanQuery     = false
	adornee.CastShadow   = false
	adornee.Transparency = 1
	adornee.Size         = Vector3.one
	adornee.Parent       = workspace.CurrentCamera
	janitor:Add(adornee, "Destroy")

	local faces: { FaceHandle } = {}
	for _, data in FACE_DATA do
		local dot = Instance.new("SphereHandleAdornment")
		dot.Adornee     = adornee
		dot.Color3      = data.color
		dot.Radius      = BASE_DOT_R
		dot.AlwaysOnTop = true
		dot.ZIndex      = 3
		dot.Visible     = false
		dot.Parent      = adornmentsFolder
		janitor:Add(dot, "Destroy")
		table.insert(faces, {
			id           = data.id :: FaceId,
			dir          = data.dir,
			defaultColor = data.color,
			dot          = dot,
		})
	end

	-- Fixed-at-origin adornee for snap dots. Snap dot CFrames are world-space
	-- positions directly, so this part must never move.
	local snapAdornee = Instance.new("Part")
	snapAdornee.Name         = "ResizeSnapDotsAdornee"
	snapAdornee.Anchored     = true
	snapAdornee.CanCollide   = false
	snapAdornee.CanQuery     = false
	snapAdornee.CastShadow   = false
	snapAdornee.Transparency = 1
	snapAdornee.Size         = Vector3.one
	snapAdornee.CFrame       = CFrame.identity
	snapAdornee.Parent       = workspace.CurrentCamera
	janitor:Add(snapAdornee, "Destroy")

	local snapDots: { SphereHandleAdornment } = {}
	for i = 1, MAX_SNAP_DOTS do
		local dot = Instance.new("SphereHandleAdornment")
		dot.Name        = "ResizeSnapDot"
		dot.Adornee     = snapAdornee
		dot.Color3      = IDLE_DOT_COLOR
		dot.Radius      = SNAP_DOT_R
		dot.AlwaysOnTop = true
		dot.ZIndex      = 4
		dot.Visible     = false
		dot.Parent      = adornmentsFolder
		janitor:Add(dot, "Destroy")
		snapDots[i] = dot
	end

	local self: Internal = setmetatable({
		dragStarted  = be.Event,
		_adornee     = adornee,
		_faces       = faces,
		_visible     = false,
		_drag        = nil,
		_signalBE    = be,
		_hoveredFace = nil,
		_scale       = 1,
		_halfExtents = Vector3.one,
		_snapAdornee = snapAdornee,
		_snapDots    = snapDots,
	}, ResizeGizmo) :: any

	-- ── Hover: screen-space distance to each dot ───────────────────────────
	janitor:Add(userInput.InputChanged:Connect(function(input: InputObject)
		if input.UserInputType ~= Enum.UserInputType.MouseMovement then return end
		if not self._visible or self._drag then return end
		local cam = workspace.CurrentCamera
		if cam == nil then return end

		local mouse = Vector2.new(input.Position.X, input.Position.Y)
		local gpos  = self._adornee.CFrame.Position
		local scale = self._scale

		local bestDist = math.huge
		local bestFace: FaceHandle? = nil
		for _, face in self._faces do
			local worldPos = gpos + face.dir * dotDist(face.dir, self._halfExtents, scale)
			local s, onScreen = cam:WorldToViewportPoint(worldPos)
			if onScreen then
				local d = (mouse - Vector2.new(s.X, s.Y)).Magnitude
				if d < bestDist then
					bestDist = d
					bestFace = face
				end
			end
		end

		local newHover: FaceHandle? = if bestDist <= HOVER_PX then bestFace else nil
		if newHover == self._hoveredFace then return end

		local prev = self._hoveredFace
		if prev then prev.dot.Color3 = prev.defaultColor end
		self._hoveredFace = newHover
		if newHover then newHover.dot.Color3 = HOVER_COLOR end
	end), "Disconnect")

	-- ── Click to start drag ────────────────────────────────────────────────
	janitor:Add(userInput.InputBegan:Connect(function(input: InputObject)
		if input.UserInputType ~= Enum.UserInputType.MouseButton1 then return end
		local hovered = self._hoveredFace
		if hovered == nil or not self._visible or self._drag then return end
		self._drag = {
			faceId      = hovered.id,
			worldDir    = hovered.dir,
			gizmoCenter = self._adornee.CFrame.Position,
			initScalar  = nil,
		}
		for _, face in self._faces do
			if face.id ~= hovered.id then
				face.dot.Visible = false
			else
				face.dot.Color3 = HOVER_COLOR
				face.dot.Radius = BASE_DOT_R * self._scale
			end
		end
		self._signalBE:Fire(hovered.id)
	end), "Disconnect")

	return self
end

-- ── Methods ────────────────────────────────────────────────────────────────

function ResizeGizmo.show(self: Internal, center: Vector3, halfExtents: Vector3)
	self._adornee.CFrame = CFrame.new(center)
	self._halfExtents    = halfExtents
	self._visible        = true
	local scale = getScale(center)
	self._scale = scale
	for _, face in self._faces do
		face.dot.CFrame  = CFrame.new(face.dir * dotDist(face.dir, halfExtents, scale))
		face.dot.Radius  = BASE_DOT_R * scale
		face.dot.Visible = true
	end
	applyOcclusion(self, center, scale)
end

function ResizeGizmo.hide(self: Internal)
	self._visible = false
	self:stopDrag()
	for _, face in self._faces do
		face.dot.Visible = false
	end
end

function ResizeGizmo.update(self: Internal, center: Vector3, halfExtents: Vector3)
	self._adornee.CFrame = CFrame.new(center)
	self._halfExtents    = halfExtents
	local scale = getScale(center)
	self._scale = scale
	for _, face in self._faces do
		face.dot.CFrame = CFrame.new(face.dir * dotDist(face.dir, halfExtents, scale))
		if self._drag then
			face.dot.Radius = BASE_DOT_R * scale
		end
	end
	applyOcclusion(self, center, scale)
end

function ResizeGizmo.drag(self: Internal): DragState?
	return self._drag
end

function ResizeGizmo.computeDelta(self: Internal, screenPos: Vector2): number
	local drag = self._drag
	if drag == nil then return 0 end
	local cam = workspace.CurrentCamera
	if cam == nil then return 0 end

	local ray = cam:ViewportPointToRay(screenPos.X, screenPos.Y)
	local pt  = rayBestPlane(
		ray.Origin, ray.Direction,
		drag.gizmoCenter, drag.worldDir,
		cam.CFrame.LookVector
	)
	if pt == nil then return 0 end

	local scalar = drag.worldDir:Dot(pt - drag.gizmoCenter)
	if drag.initScalar == nil then
		drag.initScalar = scalar
		return 0
	end
	return scalar - drag.initScalar
end

function ResizeGizmo.stopDrag(self: Internal)
	if self._drag == nil then return end
	self._drag        = nil
	self._hoveredFace = nil
	self:hideSnapDots()
	if not self._visible then return end
	for _, face in self._faces do
		face.dot.Color3  = face.defaultColor
		face.dot.Visible = true
	end
	-- Occlusion sizes will be corrected on the next update call.
end

function ResizeGizmo.showSnapDots(self: Internal, candidates: { Vector3 }, activeDotPos: Vector3?)
	local radius = SNAP_DOT_R * self._scale
	for i, dot in self._snapDots do
		if i > #candidates then
			dot.Visible = false
			continue
		end
		local pos    = candidates[i]
		local active = activeDotPos ~= nil and (pos - activeDotPos).Magnitude < 0.05
		dot.CFrame  = CFrame.new(pos)
		dot.Color3  = if active then ACTIVE_DOT_COLOR else IDLE_DOT_COLOR
		dot.Radius  = radius
		dot.Visible = true
	end
end

function ResizeGizmo.hideSnapDots(self: Internal)
	for _, dot in self._snapDots do
		dot.Visible = false
	end
end

return ResizeGizmo
