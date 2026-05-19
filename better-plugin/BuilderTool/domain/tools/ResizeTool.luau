--!strict
-- domain/tools/ResizeTool.luau
--
-- Resize selected parts along a world-space axis using the ResizeGizmo.
-- Equip shows the six face-dots for the current selection; unequip hides them.
-- A drag opens one history batch (one undo step per gesture).
-- "Snap" enables face-to-face snap on the moving face (same as MoveTool).
-- "Uniform" scales all three dimensions together from the opposite face anchor.
-- "stepSize" quantizes the delta to whole-stud grid increments.

local Janitor = require(script.Parent.Parent.Parent.Packages.Janitor)
local Tool    = require(script.Parent.Parent.tool.Tool)

type PartInitData = {
	cf:   CFrame,
	size: Vector3,
}

type Self = Tool.Tool & {
	_j:             Janitor.Janitor?,
	_initData:      { [BasePart]: PartInitData }?,
	_batchId:       string?,
	_initBBCenter:  Vector3?,
	_initBBHalfE:   Vector3?,
	_snapParams:    OverlapParams?,
	_lastSnapDelta: number?,
}

-- ── Constants ──────────────────────────────────────────────────────────────

local MIN_PART_SIZE    = 0.05
local SNAP_SEARCH_HALF = 15
local SNAP_THRESHOLD   = 1.0
local SNAP_DOT_VIS     = SNAP_THRESHOLD * 3
local SNAP_PERP_MARGIN = 1.0

-- ── Helpers ────────────────────────────────────────────────────────────────

-- World-axis-aligned half-extents of a potentially rotated part.
local function halfExtentAABB(cf: CFrame, size: Vector3): Vector3
	local h = size * 0.5
	return Vector3.new(
		math.abs(cf.RightVector.X) * h.X + math.abs(cf.UpVector.X) * h.Y + math.abs(cf.LookVector.X) * h.Z,
		math.abs(cf.RightVector.Y) * h.X + math.abs(cf.UpVector.Y) * h.Y + math.abs(cf.LookVector.Y) * h.Z,
		math.abs(cf.RightVector.Z) * h.X + math.abs(cf.UpVector.Z) * h.Y + math.abs(cf.LookVector.Z) * h.Z
	)
end

local function computeBoundingBox(parts: { BasePart }): (Vector3, Vector3)
	if #parts == 0 then
		return Vector3.zero, Vector3.one * 0.5
	end
	local minX, minY, minZ =  math.huge,  math.huge,  math.huge
	local maxX, maxY, maxZ = -math.huge, -math.huge, -math.huge
	for _, p in parts do
		local pos = p.Position
		local he  = halfExtentAABB(p.CFrame, p.Size)
		minX = math.min(minX, pos.X - he.X); maxX = math.max(maxX, pos.X + he.X)
		minY = math.min(minY, pos.Y - he.Y); maxY = math.max(maxY, pos.Y + he.Y)
		minZ = math.min(minZ, pos.Z - he.Z); maxZ = math.max(maxZ, pos.Z + he.Z)
	end
	return Vector3.new((minX+maxX)/2, (minY+maxY)/2, (minZ+maxZ)/2),
	       Vector3.new((maxX-minX)/2, (maxY-minY)/2, (maxZ-minZ)/2)
end

-- Projected half-extent of a (possibly rotated) part along a world-space axis.
local function halfExtentOnAxis(cf: CFrame, size: Vector3, axis: Vector3): number
	local h = size * 0.5
	return math.abs(cf.RightVector:Dot(axis)) * h.X
		+ math.abs(cf.UpVector:Dot(axis)) * h.Y
		+ math.abs(cf.LookVector:Dot(axis)) * h.Z
end

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
-- Checks whether the moving face of the selection's bounding box is close to
-- any face of a nearby part along worldDir.
local function computeSnapResult(
	bbCenter: Vector3,
	bbHalfE:  Vector3,
	rawDelta: number,
	worldDir: Vector3,
	params:   OverlapParams
): (number, { Vector3 }, Vector3?)
	local axisB, axisC = perpAxes(worldDir)

	local axisHE = math.abs(worldDir.X) * bbHalfE.X
		+ math.abs(worldDir.Y) * bbHalfE.Y
		+ math.abs(worldDir.Z) * bbHalfE.Z

	-- World-scalar of the moving face at drag start.
	local initFaceScalar = worldDir:Dot(bbCenter) + axisHE

	-- Perpendicular extents of the bounding box (for overlap culling).
	local selMinB = axisB:Dot(bbCenter) - axisB:Dot(bbHalfE)
	local selMaxB = axisB:Dot(bbCenter) + axisB:Dot(bbHalfE)
	local selMinC = axisC:Dot(bbCenter) - axisC:Dot(bbHalfE)
	local selMaxC = axisC:Dot(bbCenter) + axisC:Dot(bbHalfE)

	local searchCenter = bbCenter + worldDir * (axisHE + rawDelta)
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
		local qPosB  = axisB:Dot(q.Position)
		local qHalfB = halfExtentOnAxis(q.CFrame, q.Size, axisB)
		if selMaxB + SNAP_PERP_MARGIN < qPosB - qHalfB
			or qPosB + qHalfB < selMinB - SNAP_PERP_MARGIN then
			continue
		end
		local qPosC  = axisC:Dot(q.Position)
		local qHalfC = halfExtentOnAxis(q.CFrame, q.Size, axisC)
		if selMaxC + SNAP_PERP_MARGIN < qPosC - qHalfC
			or qPosC + qHalfC < selMinC - SNAP_PERP_MARGIN then
			continue
		end

		local qPosA  = worldDir:Dot(q.Position)
		local qHalfA = halfExtentOnAxis(q.CFrame, q.Size, worldDir)
		for _, qFaceA in { qPosA + qHalfA, qPosA - qHalfA } do
			local cand = qFaceA - initFaceScalar
			local dist = math.abs(cand - rawDelta)
			if dist < SNAP_DOT_VIS and #dots < 32 then
				table.insert(dots, q.Position + worldDir * (qFaceA - qPosA))
			end
			if dist < bestDist then
				bestDist   = dist
				bestDelta  = cand
				bestDotPos = q.Position + worldDir * (qFaceA - qPosA)
			end
		end
	end

	return bestDelta, dots, bestDotPos
end

-- ── Tool ───────────────────────────────────────────────────────────────────

local ResizeTool: Self = {
	id    = "resize",
	name  = "Resize",
	icon  = "",
	order = 2,

	options = {
		{ kind = "toggle", key = "snap",     label = "Snap",    default = true  },
		{ kind = "toggle", key = "uniform",  label = "Uniform", default = false },
		{ kind = "number", key = "stepSize", label = "studs",   default = 1, min = 1, max = 100, step = 1 },
	},

	_j             = nil,
	_initData      = nil,
	_batchId       = nil,
	_initBBCenter  = nil,
	_initBBHalfE   = nil,
	_snapParams    = nil,
	_lastSnapDelta = nil,

	equip = function(self: Self, ctx: Tool.Context)
		local j = Janitor.new()
		self._j = j

		local params = OverlapParams.new()
		params.FilterType = Enum.RaycastFilterType.Exclude
		self._snapParams = params

		local parts = ctx.selection:get()
		if #parts > 0 then
			local center, halfExtents = computeBoundingBox(parts)
			ctx.viewport.resizeGizmo:show(center, halfExtents)
		end

		-- Snapshot initial CFrames, sizes, and bounding box when a dot is clicked.
		j:Add(ctx.viewport.resizeGizmo.dragStarted:Connect(function()
			local selected = ctx.selection:get()
			local init: { [BasePart]: PartInitData } = {}
			for _, p in selected do
				init[p] = { cf = p.CFrame, size = p.Size }
			end
			self._initData      = init
			self._batchId       = ctx.history:openBatch("Resize")
			self._lastSnapDelta = nil
			local center, halfExtents = computeBoundingBox(selected)
			self._initBBCenter  = center
			self._initBBHalfE   = halfExtents
			-- Exclude selected parts so they don't snap to themselves.
			params.FilterDescendantsInstances = selected
		end), "Disconnect")

		j:Add(ctx.services.run.Heartbeat:Connect(function()
			local current = ctx.selection:get()
			if #current > 0 then
				local center, halfExtents = computeBoundingBox(current)
				ctx.viewport.resizeGizmo:update(center, halfExtents)
			end
		end), "Disconnect")
	end,

	unequip = function(self: Self, ctx: Tool.Context)
		local gizmo = ctx.viewport.resizeGizmo
		if gizmo:drag() then
			gizmo:stopDrag()
			ctx.history:closeBatch(self._batchId, false)
		end
		gizmo:hide()
		self._initData      = nil
		self._batchId       = nil
		self._initBBCenter  = nil
		self._initBBHalfE   = nil
		self._snapParams    = nil
		self._lastSnapDelta = nil
		if self._j then
			self._j:Destroy()
			self._j = nil
		end
	end,

	onSelectionChanged = function(_, ctx: Tool.Context)
		local gizmo = ctx.viewport.resizeGizmo
		if gizmo:drag() then return end
		local parts = ctx.selection:get()
		if #parts == 0 then
			gizmo:hide()
		else
			local center, halfExtents = computeBoundingBox(parts)
			gizmo:show(center, halfExtents)
		end
	end,

	onInputBegan = function(_, ctx: Tool.Context, input: InputObject): boolean
		if input.UserInputType ~= Enum.UserInputType.MouseButton1 then return false end
		-- Dot clicks set drag BEFORE UIS.InputBegan fires; skip selection.
		if ctx.viewport.resizeGizmo:drag() then return false end

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
		local gizmo = ctx.viewport.resizeGizmo
		local drag  = gizmo:drag()
		if drag == nil or self._initData == nil then return false end

		local rawDelta = gizmo:computeDelta(Vector2.new(input.Position.X, input.Position.Y))
		local snapOn   = ctx.settings:getToolOption("resize", "snap",     true)  :: boolean
		local stepSize = ctx.settings:getToolOption("resize", "stepSize", 1)     :: number

		-- Face-to-face snap on the moving face.
		local dots: { Vector3 } = {}
		local activeDotPos: Vector3? = nil
		if snapOn and self._snapParams ~= nil
			and self._initBBCenter ~= nil and self._initBBHalfE ~= nil then
			rawDelta, dots, activeDotPos = computeSnapResult(
				self._initBBCenter, self._initBBHalfE,
				rawDelta, drag.worldDir, self._snapParams
			)
		end

		-- Grid snap (studs); face-snap takes priority and anchors the grid origin.
		if activeDotPos ~= nil then
			self._lastSnapDelta = rawDelta
		elseif stepSize > 0 then
			local origin = self._lastSnapDelta or 0
			rawDelta = origin + math.round((rawDelta - origin) / stepSize) * stepSize
		end

		local axisVec = Vector3.new(
			math.abs(drag.worldDir.X),
			math.abs(drag.worldDir.Y),
			math.abs(drag.worldDir.Z)
		)
		local isUniform = ctx.settings:getToolOption("resize", "uniform", false) :: boolean

		if isUniform and self._initBBCenter ~= nil and self._initBBHalfE ~= nil then
			-- Uniform mode: scale all three dimensions by the same factor.
			-- The anchor is the centre of the opposite face (a 3D point).
			local bbCenter = self._initBBCenter
			local axisHE   = axisVec:Dot(self._initBBHalfE)
			if axisHE > 0.001 then
				local anchorPoint = bbCenter - drag.worldDir * axisHE
				local s = math.max((2 * axisHE + rawDelta) / (2 * axisHE), 0.001)
				for part, init in self._initData do
					part.Size = Vector3.new(
						math.max(init.size.X * s, MIN_PART_SIZE),
						math.max(init.size.Y * s, MIN_PART_SIZE),
						math.max(init.size.Z * s, MIN_PART_SIZE)
					)
					part.CFrame = init.cf + (init.cf.Position - anchorPoint) * (s - 1)
				end
			end
		else
			-- Axis mode: each part grows or shrinks independently along the drag axis.
			for part, init in self._initData do
				local axisSize = axisVec:Dot(init.size)
				local d = math.max(rawDelta, MIN_PART_SIZE - axisSize)
				part.Size   = init.size + axisVec * d
				part.CFrame = init.cf + drag.worldDir * (d * 0.5)
			end
		end

		local center, halfExtents = computeBoundingBox(ctx.selection:get())
		ctx.viewport.resizeGizmo:update(center, halfExtents)
		ctx.viewport.resizeGizmo:showSnapDots(dots, activeDotPos)
		return true
	end,

	onInputEnded = function(self: Self, ctx: Tool.Context, input: InputObject): boolean
		if input.UserInputType ~= Enum.UserInputType.MouseButton1 then return false end
		local gizmo = ctx.viewport.resizeGizmo
		if gizmo:drag() == nil then return false end

		gizmo:stopDrag()  -- also calls hideSnapDots
		ctx.history:closeBatch(self._batchId, true)
		self._batchId       = nil
		self._initData      = nil
		self._initBBCenter  = nil
		self._initBBHalfE   = nil
		self._lastSnapDelta = nil
		return false
	end,
} :: Self

return ResizeTool :: Tool.Tool
