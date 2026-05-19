--!strict
-- runtime/Viewport/MoveGizmo.luau
--
-- Three-axis translate gizmo (ARCHITECTURE §7). One invisible Part anchored
-- in workspace.CurrentCamera serves as the adornee; eight HandleAdornments
-- (cylinder shaft + cone arrowhead per axis, mirrored ±dir) plus a centre
-- sphere live in the adornments folder.  AlwaysOnTop = true so arrows
-- render through geometry.
--
-- CylinderHandleAdornment extends along its CFrame local +Z axis.
-- ConeHandleAdornment tip points in the -Z direction from the CFrame.
--
-- Hit detection uses screen-space distance (WorldToViewportPoint) so the
-- click area is independent of the thin visual shaft radius.

local Janitor = require(script.Parent.Parent.Parent.Packages.Janitor)

-- ── Constants ──────────────────────────────────────────────────────────────

local CAM_DIST_REF = 10    -- studs reference distance where scale = 1
local BASE_SHAFT   = 3.0
local BASE_CONE_H  = 0.6
local BASE_GAP     = 0.65  -- gap between centre and arrow start
local SHAFT_R      = 0.08
local CONE_R       = 0.20
local SPHERE_R     = 0.09  -- centre dot
local HOVER_PX     = 12    -- screen-pixel threshold for hover
local SNAP_DOT_R   = SPHERE_R * 1.5  -- snap candidate dot radius (scaled)
local MAX_SNAP_DOTS = 32

local AXIS_DATA = table.freeze({
	{ id = "X", dir = Vector3.xAxis, color = Color3.fromRGB(220, 50,  50)  },
	{ id = "Y", dir = Vector3.yAxis, color = Color3.fromRGB(50,  200, 50)  },
	{ id = "Z", dir = Vector3.zAxis, color = Color3.fromRGB(50,  90,  230) },
})

local HOVER_COLOR  = Color3.fromRGB(255, 210, 40)
local SPHERE_COLOR = Color3.fromRGB(220, 220, 220)

-- ── Types ──────────────────────────────────────────────────────────────────

export type AxisId = "X" | "Y" | "Z"

export type DragState = {
	axisId:      AxisId,
	worldDir:    Vector3,
	gizmoOrigin: Vector3,
	initScalar:  number?,
}

type AxisHandle = {
	id:           AxisId,
	dir:          Vector3,
	defaultColor: Color3,
	shaft:        CylinderHandleAdornment,
	cone:         ConeHandleAdornment,
	shaftNeg:     CylinderHandleAdornment,
	coneNeg:      ConeHandleAdornment,
}

export type MoveGizmo = {
	dragStarted:  RBXScriptSignal,
	show:         (self: MoveGizmo, cf: CFrame) -> (),
	hide:         (self: MoveGizmo) -> (),
	update:       (self: MoveGizmo, cf: CFrame) -> (),
	drag:         (self: MoveGizmo) -> DragState?,
	computeDelta: (self: MoveGizmo, screenPos: Vector2) -> number,
	stopDrag:     (self: MoveGizmo) -> (),
	showSnapDots: (self: MoveGizmo, candidates: { Vector3 }, activeDotPos: Vector3?) -> (),
	hideSnapDots: (self: MoveGizmo) -> (),
}

type Internal = MoveGizmo & {
	_adornee:     Part,
	_sphere:      SphereHandleAdornment,
	_axes:        { AxisHandle },
	_visible:     boolean,
	_drag:        DragState?,
	_signalBE:    BindableEvent,
	_hoveredAxis: AxisHandle?,
	_scale:       number,
	_snapAdornee: Part,
	_snapDots:    { SphereHandleAdornment },
}

-- ── Math ───────────────────────────────────────────────────────────────────

-- Rotate so that local +Z points toward dir (shaft extend axis).
local function rotateZTo(dir: Vector3): CFrame
	local fwd = Vector3.zAxis
	if math.abs(fwd:Dot(dir)) > 0.9999 then
		return if dir.Z > 0 then CFrame.identity else CFrame.Angles(0, math.pi, 0)
	end
	local axis = fwd:Cross(dir).Unit
	return CFrame.fromAxisAngle(axis, math.acos(math.clamp(fwd:Dot(dir), -1, 1)))
end

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

-- Screen-space pixel distance from `mouse` to the projection of world segment [p1, p2].
local function screenDistToSeg(cam: Camera, p1: Vector3, p2: Vector3, mouse: Vector2): number
	local s1, on1 = cam:WorldToViewportPoint(p1)
	local s2, on2 = cam:WorldToViewportPoint(p2)
	if not on1 and not on2 then return math.huge end
	if not on1 then return (mouse - Vector2.new(s2.X, s2.Y)).Magnitude end
	if not on2 then return (mouse - Vector2.new(s1.X, s1.Y)).Magnitude end
	local a     = Vector2.new(s1.X, s1.Y)
	local b     = Vector2.new(s2.X, s2.Y)
	local ab    = b - a
	local lenSq = ab:Dot(ab)
	local t     = if lenSq < 1 then 0 else math.clamp((mouse - a):Dot(ab) / lenSq, 0, 1)
	return (mouse - (a + ab * t)).Magnitude
end

-- ── Helpers ────────────────────────────────────────────────────────────────

local function applyScale(axis: AxisHandle, scale: number)
	local shaftLen = BASE_SHAFT * scale
	local coneH    = BASE_CONE_H * scale
	local gap      = BASE_GAP * scale

	axis.shaft.Height      = shaftLen
	axis.shaft.Radius      = SHAFT_R * scale
	axis.shaft.InnerRadius = 0
	axis.shaft.CFrame      = CFrame.new(axis.dir * (gap + shaftLen * 0.5)) * rotateZTo(axis.dir)

	axis.cone.Height = coneH
	axis.cone.Radius = CONE_R * scale
	axis.cone.CFrame = CFrame.new(axis.dir * (gap + shaftLen)) * rotateZTo(-axis.dir)

	axis.shaftNeg.Height      = shaftLen
	axis.shaftNeg.Radius      = SHAFT_R * scale
	axis.shaftNeg.InnerRadius = 0
	axis.shaftNeg.CFrame      = CFrame.new(-axis.dir * (gap + shaftLen * 0.5)) * rotateZTo(-axis.dir)

	axis.coneNeg.Height = coneH
	axis.coneNeg.Radius = CONE_R * scale
	axis.coneNeg.CFrame = CFrame.new(-axis.dir * (gap + shaftLen)) * rotateZTo(axis.dir)
end

local function getScale(gizmoPos: Vector3): number
	local cam = workspace.CurrentCamera
	if cam == nil then return 1 end
	return math.clamp((cam.CFrame.Position - gizmoPos).Magnitude / CAM_DIST_REF, 0.05, 50)
end

-- ── Constructor ────────────────────────────────────────────────────────────

local MoveGizmo = {}
MoveGizmo.__index = MoveGizmo

function MoveGizmo.new(adornmentsFolder: Folder, janitor: Janitor.Janitor, userInput: UserInputService): MoveGizmo
	local be = Instance.new("BindableEvent")
	janitor:Add(be, "Destroy")

	local adornee = Instance.new("Part")
	adornee.Name         = "MoveGizmoAdornee"
	adornee.Anchored     = true
	adornee.CanCollide   = false
	adornee.CanQuery     = false
	adornee.CastShadow   = false
	adornee.Transparency = 1
	adornee.Size         = Vector3.one
	adornee.Parent       = workspace.CurrentCamera
	janitor:Add(adornee, "Destroy")

	-- Centre dot
	local sphere = Instance.new("SphereHandleAdornment")
	sphere.Adornee     = adornee
	sphere.Color3      = SPHERE_COLOR
	sphere.Radius      = SPHERE_R
	sphere.AlwaysOnTop = true
	sphere.ZIndex      = 3
	sphere.Visible     = false
	sphere.Parent      = adornmentsFolder
	janitor:Add(sphere, "Destroy")

	local axes: { AxisHandle } = {}
	for _, data in AXIS_DATA do
		local shaft = Instance.new("CylinderHandleAdornment")
		shaft.Adornee     = adornee
		shaft.Color3      = data.color
		shaft.AlwaysOnTop = true
		shaft.ZIndex      = 1
		shaft.Visible     = false
		shaft.Parent      = adornmentsFolder
		janitor:Add(shaft, "Destroy")

		local cone = Instance.new("ConeHandleAdornment")
		cone.Adornee     = adornee
		cone.Color3      = data.color
		cone.AlwaysOnTop = true
		cone.ZIndex      = 2
		cone.Visible     = false
		cone.Parent      = adornmentsFolder
		janitor:Add(cone, "Destroy")

		local shaftNeg = Instance.new("CylinderHandleAdornment")
		shaftNeg.Adornee     = adornee
		shaftNeg.Color3      = data.color
		shaftNeg.AlwaysOnTop = true
		shaftNeg.ZIndex      = 1
		shaftNeg.Visible     = false
		shaftNeg.Parent      = adornmentsFolder
		janitor:Add(shaftNeg, "Destroy")

		local coneNeg = Instance.new("ConeHandleAdornment")
		coneNeg.Adornee     = adornee
		coneNeg.Color3      = data.color
		coneNeg.AlwaysOnTop = true
		coneNeg.ZIndex      = 2
		coneNeg.Visible     = false
		coneNeg.Parent      = adornmentsFolder
		janitor:Add(coneNeg, "Destroy")

		table.insert(axes, {
			id           = data.id :: AxisId,
			dir          = data.dir,
			defaultColor = data.color,
			shaft        = shaft,
			cone         = cone,
			shaftNeg     = shaftNeg,
			coneNeg      = coneNeg,
		})
	end

	-- Fixed-at-origin adornee for snap dots. Snap dot CFrames are world-space
	-- positions directly, so this part must never move.
	local snapAdornee = Instance.new("Part")
	snapAdornee.Name         = "SnapDotsAdornee"
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
		dot.Name        = "SnapDot"
		dot.Adornee     = snapAdornee
		dot.Color3      = Color3.fromRGB(255, 255, 255)
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
		_sphere      = sphere,
		_axes        = axes,
		_visible     = false,
		_drag        = nil,
		_signalBE    = be,
		_hoveredAxis = nil,
		_scale       = 1,
		_snapAdornee = snapAdornee,
		_snapDots    = snapDots,
	}, MoveGizmo) :: any

	-- ── Hover: screen-space distance to each axis segment ──────────────────
	janitor:Add(userInput.InputChanged:Connect(function(input: InputObject)
		if input.UserInputType ~= Enum.UserInputType.MouseMovement then return end
		if not self._visible or self._drag then return end
		local cam = workspace.CurrentCamera
		if cam == nil then return end

		local mouse = Vector2.new(input.Position.X, input.Position.Y)
		local gpos  = self._adornee.CFrame.Position
		local scale = self._scale
		local gap   = BASE_GAP * scale
		local total = gap + (BASE_SHAFT + BASE_CONE_H) * scale

		local bestDist = math.huge
		local bestAxis: AxisHandle? = nil
		for _, axis in self._axes do
			local d = math.min(
				screenDistToSeg(cam, gpos + axis.dir * gap, gpos + axis.dir * total, mouse),
				screenDistToSeg(cam, gpos - axis.dir * gap, gpos - axis.dir * total, mouse)
			)
			if d < bestDist then
				bestDist = d
				bestAxis = axis
			end
		end

		local newHover: AxisHandle? = if bestDist <= HOVER_PX then bestAxis else nil
		if newHover == self._hoveredAxis then return end

		local prev = self._hoveredAxis
		if prev then
			prev.shaft.Color3    = prev.defaultColor
			prev.cone.Color3     = prev.defaultColor
			prev.shaftNeg.Color3 = prev.defaultColor
			prev.coneNeg.Color3  = prev.defaultColor
		end
		self._hoveredAxis = newHover
		if newHover then
			newHover.shaft.Color3    = HOVER_COLOR
			newHover.cone.Color3     = HOVER_COLOR
			newHover.shaftNeg.Color3 = HOVER_COLOR
			newHover.coneNeg.Color3  = HOVER_COLOR
		end
	end), "Disconnect")

	-- ── Click to start drag ────────────────────────────────────────────────
	janitor:Add(userInput.InputBegan:Connect(function(input: InputObject)
		if input.UserInputType ~= Enum.UserInputType.MouseButton1 then return end
		local hovered = self._hoveredAxis
		if hovered == nil or not self._visible or self._drag then return end
		self._drag = {
			axisId      = hovered.id,
			worldDir    = hovered.dir,
			gizmoOrigin = self._adornee.CFrame.Position,
			initScalar  = nil,
		}
		for _, other in self._axes do
			local active = other.id == hovered.id
			other.shaft.Visible    = active
			other.cone.Visible     = active
			other.shaftNeg.Visible = active
			other.coneNeg.Visible  = active
			if active then
				other.shaft.Color3    = HOVER_COLOR
				other.cone.Color3     = HOVER_COLOR
				other.shaftNeg.Color3 = HOVER_COLOR
				other.coneNeg.Color3  = HOVER_COLOR
			end
		end
		self._signalBE:Fire(hovered.id)
	end), "Disconnect")

	return self
end

-- ── Methods ────────────────────────────────────────────────────────────────

function MoveGizmo.show(self: Internal, cf: CFrame)
	self._adornee.CFrame = CFrame.new(cf.Position)
	self._visible = true
	local scale = getScale(cf.Position)
	self._scale = scale
	self._sphere.Radius  = SPHERE_R * scale
	self._sphere.Visible = true
	for _, axis in self._axes do
		applyScale(axis, scale)
		axis.shaft.Visible    = true
		axis.cone.Visible     = true
		axis.shaftNeg.Visible = true
		axis.coneNeg.Visible  = true
	end
end

function MoveGizmo.hide(self: Internal)
	self._visible = false
	self:stopDrag()
	self._sphere.Visible = false
	for _, axis in self._axes do
		axis.shaft.Visible    = false
		axis.cone.Visible     = false
		axis.shaftNeg.Visible = false
		axis.coneNeg.Visible  = false
	end
end

function MoveGizmo.update(self: Internal, cf: CFrame)
	self._adornee.CFrame = CFrame.new(cf.Position)
	local scale = getScale(cf.Position)
	self._scale = scale
	self._sphere.Radius = SPHERE_R * scale
	for _, axis in self._axes do
		applyScale(axis, scale)
	end
end

function MoveGizmo.drag(self: Internal): DragState?
	return self._drag
end

function MoveGizmo.computeDelta(self: Internal, screenPos: Vector2): number
	local drag = self._drag
	if drag == nil then return 0 end
	local cam = workspace.CurrentCamera
	if cam == nil then return 0 end

	local ray = cam:ViewportPointToRay(screenPos.X, screenPos.Y)
	local pt  = rayBestPlane(
		ray.Origin, ray.Direction,
		drag.gizmoOrigin, drag.worldDir,
		cam.CFrame.LookVector
	)
	if pt == nil then return 0 end

	local scalar = drag.worldDir:Dot(pt - drag.gizmoOrigin)
	if drag.initScalar == nil then
		drag.initScalar = scalar
		return 0
	end
	return scalar - drag.initScalar
end

function MoveGizmo.stopDrag(self: Internal)
	if self._drag == nil then return end
	self._drag = nil
	self._hoveredAxis = nil
	self:hideSnapDots()
	if not self._visible then return end
	for _, axis in self._axes do
		axis.shaft.Color3    = axis.defaultColor
		axis.cone.Color3     = axis.defaultColor
		axis.shaftNeg.Color3 = axis.defaultColor
		axis.coneNeg.Color3  = axis.defaultColor
		axis.shaft.Visible    = true
		axis.cone.Visible     = true
		axis.shaftNeg.Visible = true
		axis.coneNeg.Visible  = true
	end
end

local ACTIVE_DOT_COLOR = Color3.fromRGB(255, 210, 40) -- matches HOVER_COLOR
local IDLE_DOT_COLOR   = Color3.fromRGB(255, 255, 255)

function MoveGizmo.showSnapDots(self: Internal, candidates: { Vector3 }, activeDotPos: Vector3?)
	local radius = SNAP_DOT_R * self._scale
	for i, dot in self._snapDots do
		if i > #candidates then
			dot.Visible = false
			continue
		end
		local pos    = candidates[i]
		local active = activeDotPos ~= nil and (pos - activeDotPos).Magnitude < 0.05
		dot.CFrame  = CFrame.new(pos) -- world-space: snapAdornee is at CFrame.identity
		dot.Color3  = if active then ACTIVE_DOT_COLOR else IDLE_DOT_COLOR
		dot.Radius  = radius
		dot.Visible = true
	end
end

function MoveGizmo.hideSnapDots(self: Internal)
	for _, dot in self._snapDots do
		dot.Visible = false
	end
end

return MoveGizmo
