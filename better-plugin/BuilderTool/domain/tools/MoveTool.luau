--!strict
-- domain/tools/MoveTool.luau
--
-- Translate selected parts along a world-space axis using the MoveGizmo.
-- Equip shows the three-axis arrows for the current selection; unequip hides
-- them. A drag opens one history batch (one undo step per gesture).
-- When the "snap" option is on, drag movements snap face-to-face against
-- nearby parts along the active axis.

local Janitor = require(script.Parent.Parent.Parent.Packages.Janitor)
local Tool    = require(script.Parent.Parent.tool.Tool)

-- Per-equip mutable state hung directly on the tool (safe: only one equip at
-- a time, ToolHost guarantees it). Cleared in unequip.
type Self = Tool.Tool & {
	_j:             Janitor.Janitor?,
	_initCFrames:   { [BasePart]: CFrame }?,
	_batchId:       string?,
	_snapParams:    OverlapParams?,
	_lastSnapDelta: number?,
}

-- ── Constants ──────────────────────────────────────────────────────────────

local SNAP_SEARCH_HALF  = 15  -- half-side of the snap search box in studs
local SNAP_THRESHOLD    = 1.0 -- within this many studs along the axis, a face-snap fires
local SNAP_DOT_VIS      = SNAP_THRESHOLD * 3 -- show preview dots within this distance
local SNAP_PERP_MARGIN  = 1.0 -- extra leeway in the perpendicular overlap check (studs)

-- ── Helpers ────────────────────────────────────────────────────────────────

local function computePivot(parts: { BasePart }): CFrame
	if #parts == 0 then return CFrame.identity end
	local sum = Vector3.zero
	for _, p in parts do
		sum += p.Position
	end
	return CFrame.new(sum / #parts)
end

-- Half-extent of a part along a world-space unit axis, accounting for rotation.
local function halfExtent(cf: CFrame, size: Vector3, axis: Vector3): number
	local h = size * 0.5
	return math.abs(cf.RightVector:Dot(axis)) * h.X
		+ math.abs(cf.UpVector:Dot(axis)) * h.Y
		+ math.abs(cf.LookVector:Dot(axis)) * h.Z
end

-- Returns the two world-space axes perpendicular to a world-aligned drag axis.
local function perpAxes(axis: Vector3): (Vector3, Vector3)
	if math.abs(axis.X) > 0.5 then
		return Vector3.yAxis, Vector3.zAxis
	elseif math.abs(axis.Y) > 0.5 then
		return Vector3.xAxis, Vector3.zAxis
	else
		return Vector3.xAxis, Vector3.yAxis
	end
end

-- Returns (snappedDelta, dotCandidates, activeDotPos).
-- dotCandidates: world positions of nearby face-snap points to visualise.
-- activeDotPos:  the candidate currently being snapped to, or nil.
local function computeSnapResult(
	initCFrames: { [BasePart]: CFrame },
	rawDelta:    number,
	dragDir:     Vector3,
	params:      OverlapParams
): (number, { Vector3 }, Vector3?)
	local axisB, axisC = perpAxes(dragDir)

	local selMinA, selMaxA =  math.huge, -math.huge
	local selMinB, selMaxB =  math.huge, -math.huge
	local selMinC, selMaxC =  math.huge, -math.huge
	local selSum  = Vector3.zero
	local count   = 0

	for part, initCF in initCFrames do
		count += 1
		selSum += initCF.Position
		local function expand(axis: Vector3, minV: number, maxV: number): (number, number)
			local pos = axis:Dot(initCF.Position)
			local h   = halfExtent(initCF, part.Size, axis)
			return math.min(minV, pos - h), math.max(maxV, pos + h)
		end
		selMinA, selMaxA = expand(dragDir, selMinA, selMaxA)
		selMinB, selMaxB = expand(axisB,   selMinB, selMaxB)
		selMinC, selMaxC = expand(axisC,   selMinC, selMaxC)
	end
	if count == 0 then return rawDelta, {}, nil end

	-- Perpendicular-to-dragDir component of the selection centroid.
	-- Used to reconstruct the selection's own face positions in world space.
	local selCentroid    = selSum / count
	local selCenterPerp  = selCentroid - dragDir * dragDir:Dot(selCentroid)

	local searchCenter = selSum / count + dragDir * rawDelta
	local nearby = workspace:GetPartBoundsInBox(
		CFrame.new(searchCenter),
		Vector3.one * (SNAP_SEARCH_HALF * 2),
		params
	)

	local bestDelta  = rawDelta
	local bestDist   = SNAP_THRESHOLD
	local bestDotPos: Vector3? = nil
	local dots: { Vector3 } = {}

	for _, q in nearby do
		-- Skip parts that don't overlap the selection in the two perpendicular axes.
		-- This prevents dots appearing on parts that are far above/below/beside
		-- the selection and could never realistically face-snap to it.
		local qPosB  = axisB:Dot(q.Position)
		local qHalfB = halfExtent(q.CFrame, q.Size, axisB)
		if selMaxB + SNAP_PERP_MARGIN < qPosB - qHalfB
			or qPosB + qHalfB < selMinB - SNAP_PERP_MARGIN then
			continue
		end
		local qPosC  = axisC:Dot(q.Position)
		local qHalfC = halfExtent(q.CFrame, q.Size, axisC)
		if selMaxC + SNAP_PERP_MARGIN < qPosC - qHalfC
			or qPosC + qHalfC < selMinC - SNAP_PERP_MARGIN then
			continue
		end

		local qPosA  = dragDir:Dot(q.Position)
		local qHalfA = halfExtent(q.CFrame, q.Size, dragDir)

		-- For each face of Q, both faces of the selection can snap to it.
		-- This covers: flush-abutting (sel− on Q+, sel+ on Q−) and
		-- coplanar-alignment (sel+ on Q+, sel− on Q−).
		local qFaces = { qPosA + qHalfA, qPosA - qHalfA }
		local selFaces = { { selMinA, selCenterPerp + dragDir * (selMinA + rawDelta) },
		                   { selMaxA, selCenterPerp + dragDir * (selMaxA + rawDelta) } }
		for _, qFaceA in qFaces do
			local facePos = q.Position + dragDir * (qFaceA - qPosA)
			for _, selFace in selFaces do
				local selFaceA, selFacePos = selFace[1], selFace[2]
				local cand = qFaceA - selFaceA
				local dist = math.abs(cand - rawDelta)
				if dist < SNAP_DOT_VIS and #dots + 1 < 32 then
					table.insert(dots, facePos)
					table.insert(dots, selFacePos)
				end
				if dist < bestDist then
					bestDist   = dist
					bestDelta  = cand
					bestDotPos = facePos
				end
			end
		end
	end

	return bestDelta, dots, bestDotPos
end

-- ── Tool ───────────────────────────────────────────────────────────────────

local MoveTool: Self = {
	id    = "move",
	name  = "Move",
	icon  = "",
	order = 1,

	options = {
		{ kind = "toggle", key = "snap",     label = "Snap",  default = true },
		{ kind = "number", key = "stepSize", label = "studs", default = 1, min = 0.01, max = 100, step = 1 },
		{ kind = "enum",   key = "space",    label = "Space", choices = { "World", "Local" }, default = "World" },
	},

	_j             = nil,
	_initCFrames   = nil,
	_batchId       = nil,
	_snapParams    = nil,
	_lastSnapDelta = nil,

	equip = function(self: Self, ctx: Tool.Context)
		local j = Janitor.new()
		self._j = j

		local params = OverlapParams.new()
		params.FilterType = Enum.RaycastFilterType.Exclude
		self._snapParams = params

		-- Show gizmo for whatever is already selected.
		local parts = ctx.selection:get()
		if #parts > 0 then
			ctx.viewport.moveGizmo:show(computePivot(parts))
		end

		-- When an arrow is clicked: snapshot initial CFrames and open the
		-- history batch. All property changes until closeBatch are one undo step.
		j:Add(ctx.viewport.moveGizmo.dragStarted:Connect(function()
			local selected = ctx.selection:get()
			local init: { [BasePart]: CFrame } = {}
			for _, p in selected do
				init[p] = p.CFrame
			end
			self._initCFrames   = init
			self._lastSnapDelta = nil
			self._batchId = ctx.history:openBatch("Move")
			-- Exclude moved parts from snap search so we never snap to ourselves.
			params.FilterDescendantsInstances = selected
		end), "Disconnect")

		-- Keep the gizmo scaled to camera distance every frame so it maintains
		-- a constant screen-space size as the camera orbits or zooms.
		-- RenderStepped only fires in run mode; Heartbeat works in edit mode.
		j:Add(ctx.services.run.Heartbeat:Connect(function()
			local current = ctx.selection:get()
			if #current > 0 then
				ctx.viewport.moveGizmo:update(computePivot(current))
			end
		end), "Disconnect")
	end,

	unequip = function(self: Self, ctx: Tool.Context)
		local gizmo = ctx.viewport.moveGizmo
		if gizmo:drag() then
			gizmo:stopDrag()
			ctx.history:closeBatch(self._batchId, false) -- cancel mid-drag
		end
		gizmo:hide()
		self._initCFrames   = nil
		self._batchId       = nil
		self._snapParams    = nil
		self._lastSnapDelta = nil
		if self._j then
			self._j:Destroy()
			self._j = nil
		end
	end,

	onSelectionChanged = function(_self: Self, ctx: Tool.Context)
		local gizmo = ctx.viewport.moveGizmo
		if gizmo:drag() then return end -- don't reposition during a drag
		local parts = ctx.selection:get()
		if #parts == 0 then
			gizmo:hide()
		else
			gizmo:show(computePivot(parts))
		end
	end,

	onInputBegan = function(_self: Self, ctx: Tool.Context, input: InputObject): boolean
		if input.UserInputType ~= Enum.UserInputType.MouseButton1 then return false end
		-- Adornment clicks set drag BEFORE UIS.InputBegan fires; skip selection.
		if ctx.viewport.moveGizmo:drag() then return false end

		local screenPos = Vector2.new(input.Position.X, input.Position.Y)
		local hit       = ctx.viewport.raycaster:cast(screenPos)
		local uis       = ctx.services.userInput
		local shiftHeld = uis:IsKeyDown(Enum.KeyCode.LeftShift)
			or uis:IsKeyDown(Enum.KeyCode.RightShift)

		if hit then
			if shiftHeld then
				local current = ctx.selection:get()
				if table.find(current, hit.instance) then
					ctx.selection:remove(hit.instance)
				else
					ctx.selection:add(hit.instance)
				end
			else
				ctx.selection:set({ hit.instance })
			end
		elseif not shiftHeld then
			ctx.selection:clear()
		end
		return true
	end,

	onInputChanged = function(self: Self, ctx: Tool.Context, input: InputObject): boolean
		if input.UserInputType ~= Enum.UserInputType.MouseMovement then return false end
		local gizmo = ctx.viewport.moveGizmo
		local drag  = gizmo:drag()
		if drag == nil or self._initCFrames == nil then return false end

		local delta    = gizmo:computeDelta(Vector2.new(input.Position.X, input.Position.Y))
		local snapOn   = ctx.settings:getToolOption("move", "snap", true) :: boolean
		local stepSize = ctx.settings:getToolOption("move", "stepSize", 1) :: number
		local snapP    = self._snapParams
		local dots: { Vector3 } = {}
		local activeDotPos: Vector3? = nil
		if snapOn and snapP ~= nil then
			delta, dots, activeDotPos = computeSnapResult(self._initCFrames, delta, drag.worldDir, snapP)
		end

		-- Quantize to stepSize; face-snap takes priority when snap is on.
		-- Grid snap (studs) always runs; Snap toggle only gates face-to-face snap.
		if activeDotPos ~= nil then
			self._lastSnapDelta = delta
		elseif stepSize > 0 then
			local origin = self._lastSnapDelta or 0
			delta = origin + math.round((delta - origin) / stepSize) * stepSize
		end

		local offset = drag.worldDir * delta
		for part, initCF in self._initCFrames do
			part.CFrame = initCF + offset
		end
		gizmo:update(computePivot(ctx.selection:get()))
		gizmo:showSnapDots(dots, activeDotPos)
		return true
	end,

	onInputEnded = function(self: Self, ctx: Tool.Context, input: InputObject): boolean
		if input.UserInputType ~= Enum.UserInputType.MouseButton1 then return false end
		local gizmo = ctx.viewport.moveGizmo
		if gizmo:drag() == nil then return false end

		gizmo:stopDrag()
		ctx.history:closeBatch(self._batchId, true)
		self._batchId       = nil
		self._initCFrames   = nil
		self._lastSnapDelta = nil
		return false
	end,
} :: Self

return MoveTool :: Tool.Tool
