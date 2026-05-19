--!strict
-- runtime/Viewport/RotateGizmo.luau
--
-- Three-axis rotation gizmo. Three CylinderHandleAdornment rings (X/Y/Z world
-- axes) sit at the pivot center. Four SphereHandleAdornment dots float outside
-- each ring at the cardinal positions. Hover/click detection is dot-only (not
-- ring arc), so the user clicks a dot to begin a drag. Rings and dots use
-- separate adornee Parts so dots render on top regardless of adornment type.
-- Drag accumulates a signed total angle via per-frame atan2.

local Janitor = require(script.Parent.Parent.Parent.Packages.Janitor)

-- ── Constants ──────────────────────────────────────────────────────────────

local CAM_DIST_REF   = 10
local BASE_RING_R    = 2.5   -- ring outer radius in studs at scale 1
local RING_THICKNESS = 0.05  -- Radius - InnerRadius at scale 1
local RING_HEIGHT    = 0.08  -- CylinderHandleAdornment Height at scale 1
local TICK_DIST      = BASE_RING_R + 0.55 -- dot center sits clearly outside the ring edge
local BASE_TICK_R    = 0.22  -- sphere dot radius at scale 1
local HOVER_PX       = 20    -- screen-pixel threshold for dot hover
local HOVER_COLOR    = Color3.fromRGB(255, 210, 40)

local RING_DATA = table.freeze({
	{ id = "X", axis = Vector3.xAxis, dot = Vector3.yAxis, color = Color3.fromRGB(220,  50,  50) },
	{ id = "Y", axis = Vector3.yAxis, dot = Vector3.zAxis, color = Color3.fromRGB( 50, 200,  50) },
	{ id = "Z", axis = Vector3.zAxis, dot = Vector3.xAxis, color = Color3.fromRGB( 50,  90, 230) },
})

-- ── Types ──────────────────────────────────────────────────────────────────

export type AxisId = "X" | "Y" | "Z"

export type DragState = {
	axisId:     AxisId,
	worldAxis:  Vector3,
	pivot:      Vector3,
	prevDir:    Vector3?,
	totalAngle: number,
}

type RingHandle = {
	id:           AxisId,
	axis:         Vector3,
	dirs:         { Vector3 },  -- 4 cardinal unit vectors in the ring plane
	defaultColor: Color3,
	ring:         CylinderHandleAdornment,
	ticks:        { SphereHandleAdornment },
}

export type RotateGizmo = {
	dragStarted:  RBXScriptSignal,
	show:         (self: RotateGizmo, center: Vector3) -> (),
	hide:         (self: RotateGizmo) -> (),
	update:       (self: RotateGizmo, center: Vector3) -> (),
	drag:         (self: RotateGizmo) -> DragState?,
	computeAngle: (self: RotateGizmo, screenPos: Vector2) -> number,
	stopDrag:     (self: RotateGizmo) -> (),
}

type Internal = RotateGizmo & {
	_adornee:     Part,
	_tickAdornee: Part,
	_rings:       { RingHandle },
	_visible:     boolean,
	_drag:        DragState?,
	_signalBE:    BindableEvent,
	_hoveredRing: RingHandle?,
	_scale:       number,
}

-- ── Math ───────────────────────────────────────────────────────────────────

local function rotateZTo(dir: Vector3): CFrame
	local fwd = Vector3.zAxis
	if math.abs(fwd:Dot(dir)) > 0.9999 then
		return if dir.Z > 0 then CFrame.identity else CFrame.Angles(0, math.pi, 0)
	end
	local axis = fwd:Cross(dir).Unit
	return CFrame.fromAxisAngle(axis, math.acos(math.clamp(fwd:Dot(dir), -1, 1)))
end


local function rayPlane(
	rayOrigin:   Vector3,
	rayDir:      Vector3,
	planeOrigin: Vector3,
	planeNormal: Vector3
): Vector3?
	local denom = planeNormal:Dot(rayDir)
	if math.abs(denom) < 1e-6 then return nil end
	local t = planeNormal:Dot(planeOrigin - rayOrigin) / denom
	if t < 0 then return nil end
	return rayOrigin + rayDir * t
end

local function getScale(pos: Vector3): number
	local cam = workspace.CurrentCamera
	if cam == nil then return 1 end
	return math.clamp((cam.CFrame.Position - pos).Magnitude / CAM_DIST_REF, 0.05, 50)
end

local function makeAdornee(name: string, janitor: Janitor.Janitor): Part
	local p = Instance.new("Part")
	p.Name         = name
	p.Anchored     = true
	p.CanCollide   = false
	p.CanQuery     = false
	p.CastShadow   = false
	p.Transparency = 1
	p.Size         = Vector3.one
	p.Parent       = workspace.CurrentCamera
	janitor:Add(p, "Destroy")
	return p
end

-- ── Constructor ────────────────────────────────────────────────────────────

local RotateGizmo = {}
RotateGizmo.__index = RotateGizmo

function RotateGizmo.new(adornmentsFolder: Folder, janitor: Janitor.Janitor, userInput: UserInputService): RotateGizmo
	local be = Instance.new("BindableEvent")
	janitor:Add(be, "Destroy")

	local adornee     = makeAdornee("RotateGizmoAdornee",     janitor)
	local tickAdornee = makeAdornee("RotateGizmoTickAdornee", janitor)

	local rings: { RingHandle } = {}
	for _, data in RING_DATA do
		local ring = Instance.new("CylinderHandleAdornment")
		ring.Adornee     = adornee
		ring.Color3      = data.color
		ring.AlwaysOnTop = true
		ring.ZIndex      = 1
		ring.Visible     = false
		ring.Height      = RING_HEIGHT
		ring.Radius      = BASE_RING_R
		ring.InnerRadius = BASE_RING_R - RING_THICKNESS
		ring.CFrame      = rotateZTo(data.axis)
		ring.Parent      = adornmentsFolder
		janitor:Add(ring, "Destroy")

		local dirs = { data.dot, -data.dot }
		local ticks: { SphereHandleAdornment } = {}
		for _, dir in dirs do
			local tick = Instance.new("SphereHandleAdornment")
			tick.Adornee     = tickAdornee
			tick.Color3      = data.color
			tick.AlwaysOnTop = true
			tick.ZIndex      = 1
			tick.Visible     = false
			tick.Radius      = BASE_TICK_R
			tick.CFrame      = CFrame.new(dir * TICK_DIST)
			tick.Parent      = adornmentsFolder
			janitor:Add(tick, "Destroy")
			table.insert(ticks, tick)
		end

		table.insert(rings, {
			id           = data.id :: AxisId,
			axis         = data.axis,
			dirs         = dirs,
			defaultColor = data.color,
			ring         = ring,
			ticks        = ticks,
		})
	end

	local self: Internal = setmetatable({
		dragStarted  = be.Event,
		_adornee     = adornee,
		_tickAdornee = tickAdornee,
		_rings       = rings,
		_visible     = false,
		_drag        = nil,
		_signalBE    = be,
		_hoveredRing = nil,
		_scale       = 1,
	}, RotateGizmo) :: any

	-- ── Hover: screen-space distance to each ring's 4 dot positions ────────
	janitor:Add(userInput.InputChanged:Connect(function(input: InputObject)
		if input.UserInputType ~= Enum.UserInputType.MouseMovement then return end
		if not self._visible or self._drag then return end
		local cam = workspace.CurrentCamera
		if cam == nil then return end

		local mouse  = Vector2.new(input.Position.X, input.Position.Y)
		local gpos   = self._tickAdornee.CFrame.Position
		local scale  = self._scale
		local dist   = TICK_DIST * scale

		local bestDist = math.huge
		local bestRing: RingHandle? = nil
		for _, rh in self._rings do
			for _, dir in rh.dirs do
				local s, on = cam:WorldToViewportPoint(gpos + dir * dist)
				if on then
					local d = (mouse - Vector2.new(s.X, s.Y)).Magnitude
					if d < bestDist then
						bestDist = d
						bestRing = rh
					end
				end
			end
		end

		local newHover: RingHandle? = if bestDist <= HOVER_PX then bestRing else nil
		if newHover == self._hoveredRing then return end

		local prev = self._hoveredRing
		if prev then
			prev.ring.Color3 = prev.defaultColor
			for _, tick in prev.ticks do tick.Color3 = prev.defaultColor end
		end
		self._hoveredRing = newHover
		if newHover then
			newHover.ring.Color3 = HOVER_COLOR
			for _, tick in newHover.ticks do tick.Color3 = HOVER_COLOR end
		end
	end), "Disconnect")

	-- ── Click to start drag ────────────────────────────────────────────────
	janitor:Add(userInput.InputBegan:Connect(function(input: InputObject)
		if input.UserInputType ~= Enum.UserInputType.MouseButton1 then return end
		local hovered = self._hoveredRing
		if hovered == nil or not self._visible or self._drag then return end
		self._drag = {
			axisId     = hovered.id,
			worldAxis  = hovered.axis,
			pivot      = self._adornee.CFrame.Position,
			prevDir    = nil,
			totalAngle = 0,
		}
		for _, rh in self._rings do
			if rh.id ~= hovered.id then
				rh.ring.Visible = false
				for _, tick in rh.ticks do tick.Visible = false end
			else
				rh.ring.Color3 = HOVER_COLOR
			end
		end
		self._signalBE:Fire(hovered.id)
	end), "Disconnect")

	return self
end

-- ── Methods ────────────────────────────────────────────────────────────────

function RotateGizmo.show(self: Internal, center: Vector3)
	local cf = CFrame.new(center)
	self._adornee.CFrame     = cf
	self._tickAdornee.CFrame = cf
	self._visible            = true
	local scale = getScale(center)
	self._scale = scale
	local dist  = TICK_DIST * scale
	for _, rh in self._rings do
		rh.ring.Radius      = BASE_RING_R * scale
		rh.ring.InnerRadius = (BASE_RING_R - RING_THICKNESS) * scale
		rh.ring.Height      = RING_HEIGHT * scale
		rh.ring.CFrame      = rotateZTo(rh.axis)
		rh.ring.Visible     = true
		for j, tick in rh.ticks do
			tick.CFrame  = CFrame.new(rh.dirs[j] * dist)
			tick.Radius  = BASE_TICK_R * scale
			tick.Color3  = rh.defaultColor
			tick.Visible = true
		end
	end
end

function RotateGizmo.hide(self: Internal)
	self._visible = false
	self:stopDrag()
	for _, rh in self._rings do
		rh.ring.Visible = false
		for _, tick in rh.ticks do tick.Visible = false end
	end
end

function RotateGizmo.update(self: Internal, center: Vector3)
	local cf = CFrame.new(center)
	self._adornee.CFrame     = cf
	self._tickAdornee.CFrame = cf
	local scale = getScale(center)
	self._scale = scale
	local dist  = TICK_DIST * scale
	for _, rh in self._rings do
		rh.ring.Radius      = BASE_RING_R * scale
		rh.ring.InnerRadius = (BASE_RING_R - RING_THICKNESS) * scale
		rh.ring.Height      = RING_HEIGHT * scale
		for j, tick in rh.ticks do
			tick.CFrame = CFrame.new(rh.dirs[j] * dist)
			tick.Radius = BASE_TICK_R * scale
		end
	end
end

function RotateGizmo.drag(self: Internal): DragState?
	return self._drag
end

function RotateGizmo.computeAngle(self: Internal, screenPos: Vector2): number
	local drag = self._drag
	if drag == nil then return 0 end
	local cam = workspace.CurrentCamera
	if cam == nil then return drag.totalAngle end

	local ray = cam:ViewportPointToRay(screenPos.X, screenPos.Y)
	local hit = rayPlane(ray.Origin, ray.Direction, drag.pivot, drag.worldAxis)
	if hit == nil then return drag.totalAngle end

	local offset  = hit - drag.pivot
	local inPlane = offset - drag.worldAxis * drag.worldAxis:Dot(offset)
	if inPlane.Magnitude < 0.001 then return drag.totalAngle end
	local currDir = inPlane.Unit

	local prevDir = drag.prevDir
	if prevDir == nil then
		drag.prevDir = currDir
		return 0
	end

	local cross = prevDir:Cross(currDir)
	local delta = math.atan2(cross:Dot(drag.worldAxis), prevDir:Dot(currDir))
	drag.totalAngle += delta
	drag.prevDir     = currDir

	return drag.totalAngle
end

function RotateGizmo.stopDrag(self: Internal)
	if self._drag == nil then return end
	self._drag        = nil
	self._hoveredRing = nil
	if not self._visible then return end
	for _, rh in self._rings do
		rh.ring.Color3  = rh.defaultColor
		rh.ring.Visible = true
		for _, tick in rh.ticks do
			tick.Color3  = rh.defaultColor
			tick.Visible = true
		end
	end
end

return RotateGizmo
