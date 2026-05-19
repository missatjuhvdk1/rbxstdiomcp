--!strict
-- domain/tools/RotateTool.luau
--
-- Rotate selected parts around a world-axis ring using the RotateGizmo.
-- Equip shows the three rings at the selection pivot; unequip hides them.
-- A drag opens one history batch (one undo step per gesture).
-- "Snap" quantizes the total angle to stepAngle degree increments.

local Janitor = require(script.Parent.Parent.Parent.Packages.Janitor)
local Tool    = require(script.Parent.Parent.tool.Tool)

type Self = Tool.Tool & {
	_j:        Janitor.Janitor?,
	_initData: { [BasePart]: CFrame }?,
	_batchId:  string?,
}

-- ── Helpers ────────────────────────────────────────────────────────────────

-- Average world position of selected parts — serves as the rotation pivot.
local function computePivot(parts: { BasePart }): Vector3
	if #parts == 0 then return Vector3.zero end
	local sum = Vector3.zero
	for _, p in parts do
		sum += p.Position
	end
	return sum / #parts
end

-- ── Tool ───────────────────────────────────────────────────────────────────

local RotateTool: Self = {
	id    = "rotate",
	name  = "Rotate",
	icon  = "",
	order = 3,

	options = {
		{ kind = "toggle", key = "snap",      label = "Snap", default = true },
		{ kind = "number", key = "stepAngle", label = "deg",  default = 45, min = 5, max = 90, step = 5 },
	},

	_j        = nil,
	_initData = nil,
	_batchId  = nil,

	equip = function(self: Self, ctx: Tool.Context)
		local j = Janitor.new()
		self._j = j

		local parts = ctx.selection:get()
		if #parts > 0 then
			ctx.viewport.rotateGizmo:show(computePivot(parts))
		end

		-- Snapshot initial CFrames when a ring is clicked.
		j:Add(ctx.viewport.rotateGizmo.dragStarted:Connect(function()
			local selected = ctx.selection:get()
			local init: { [BasePart]: CFrame } = {}
			for _, p in selected do
				init[p] = p.CFrame
			end
			self._initData = init
			self._batchId  = ctx.history:openBatch("Rotate")
		end), "Disconnect")

		-- Keep gizmo on the selection pivot while not dragging.
		j:Add(ctx.services.run.Heartbeat:Connect(function()
			local current = ctx.selection:get()
			if #current > 0 and ctx.viewport.rotateGizmo:drag() == nil then
				ctx.viewport.rotateGizmo:update(computePivot(current))
			end
		end), "Disconnect")
	end,

	unequip = function(self: Self, ctx: Tool.Context)
		local gizmo = ctx.viewport.rotateGizmo
		if gizmo:drag() then
			gizmo:stopDrag()
			ctx.history:closeBatch(self._batchId, false)
		end
		gizmo:hide()
		self._initData = nil
		self._batchId  = nil
		if self._j then
			self._j:Destroy()
			self._j = nil
		end
	end,

	onSelectionChanged = function(_, ctx: Tool.Context)
		local gizmo = ctx.viewport.rotateGizmo
		if gizmo:drag() then return end
		local parts = ctx.selection:get()
		if #parts == 0 then
			gizmo:hide()
		else
			gizmo:show(computePivot(parts))
		end
	end,

	onInputBegan = function(_, ctx: Tool.Context, input: InputObject): boolean
		if input.UserInputType ~= Enum.UserInputType.MouseButton1 then return false end
		-- Ring clicks set drag BEFORE Input.luau dispatches; skip selection.
		if ctx.viewport.rotateGizmo:drag() then return false end

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
		local gizmo = ctx.viewport.rotateGizmo
		local drag  = gizmo:drag()
		if drag == nil or self._initData == nil then return false end

		local totalAngle = gizmo:computeAngle(Vector2.new(input.Position.X, input.Position.Y))
		local snapOn     = ctx.settings:getToolOption("rotate", "snap",      true) :: boolean
		local stepAngle  = ctx.settings:getToolOption("rotate", "stepAngle", 45)   :: number

		if snapOn then
			local step = math.rad(stepAngle)
			totalAngle = math.round(totalAngle / step) * step
		end

		local pivotCF = CFrame.new(drag.pivot)
		local rotCF   = CFrame.fromAxisAngle(drag.worldAxis, totalAngle)
		for part, initCF in self._initData do
			part.CFrame = pivotCF * rotCF * pivotCF:Inverse() * initCF
		end
		return true
	end,

	onInputEnded = function(self: Self, ctx: Tool.Context, input: InputObject): boolean
		if input.UserInputType ~= Enum.UserInputType.MouseButton1 then return false end
		local gizmo = ctx.viewport.rotateGizmo
		if gizmo:drag() == nil then return false end

		gizmo:stopDrag()
		ctx.history:closeBatch(self._batchId, true)
		self._batchId  = nil
		self._initData = nil
		return false
	end,
} :: Self

return RotateTool :: Tool.Tool
