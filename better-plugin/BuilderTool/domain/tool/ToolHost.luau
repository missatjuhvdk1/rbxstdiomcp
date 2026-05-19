--!strict
-- domain/tool/ToolHost.luau
--
-- Owns the active tool (or none) and ALL input routing (ARCHITECTURE §6.2).
-- Equip is idempotent and exception-safe: if equip() throws, the host rolls
-- back to no-tool — a half-equipped tool must never be reachable. Each tool
-- gets its own child Janitor on equip; unequip destroys it, so a tool cannot
-- leak past its equip scope.

local Janitor = require(script.Parent.Parent.Parent.Packages.Janitor)

local Tool = require(script.Parent.Tool)
local ToolRegistry = require(script.Parent.ToolRegistry)

export type ToolHost = {
	equip: (self: ToolHost, id: Tool.ToolId) -> (),
	unequipActive: (self: ToolHost) -> (),
	getActive: (self: ToolHost) -> Tool.Tool?,
	changed: RBXScriptSignal, -- fires when the active tool changes (UI subscribes)
}

type Internal = ToolHost & {
	_ctx: Tool.Context,
	_signal: BindableEvent,
	_active: Tool.Tool?,
	-- The active tool's scope. Destroyed on unequip; nothing a tool touches
	-- may outlive it.
	_activeJanitor: Janitor.Janitor?,
	-- False until the plugin button is clicked; false again when another plugin
	-- or Roblox's native tools take focus.  Blocks keyboard equip shortcuts.
	_enabled: boolean,
}

local HANDLER_BY_PHASE = table.freeze({
	Began = "onInputBegan",
	Changed = "onInputChanged",
	Ended = "onInputEnded",
})

local KEY_TOOL: { [EnumItem]: string } = table.freeze({
	[Enum.KeyCode.Z] = "move",
	[Enum.KeyCode.X] = "resize",
	[Enum.KeyCode.C] = "rotate",
})

local ToolHost = {}
ToolHost.__index = ToolHost

-- A faulty tool handler is warned, not fatal: one bad event must not wedge
-- the input pipeline or the plugin (§13).
local function safely(label: string, fn: () -> ())
	local ok, err = pcall(fn)
	if not ok then
		warn(`[BuilderTool] {label}: {err}`)
	end
end

function ToolHost.new(ctx: Tool.Context): ToolHost
	local signal = Instance.new("BindableEvent")
	ctx.janitor:Add(signal, "Destroy")

	local self: Internal = setmetatable({
		changed = signal.Event,
		_ctx = ctx,
		_signal = signal,
		_active = nil,
		_activeJanitor = nil,
		_enabled = false,
	}, ToolHost) :: any

	-- The single input subscription. Tools NEVER connect to UIS themselves
	-- (§6.2); the host fans each phase to the active tool's handler.
	local unsubscribe = ctx.input:subscribe(function(phase, input)
		local tool = self._active
		if tool == nil then
			return
		end
		local handlerName = HANDLER_BY_PHASE[phase]
		local handler = (tool :: any)[handlerName]
		if handler ~= nil then
			safely(`tool "{tool.id}" {handlerName}`, function()
				handler(tool, ctx, input)
			end)
		end
	end)
	ctx.janitor:Add(unsubscribe, true)

	-- Disable/enable tools when the plugin loses or gains activation focus.
	-- Another plugin or Roblox's native tools taking focus fires Deactivation,
	-- which causes Plugin.client.luau to Fire(false) here.
	ctx.janitor:Add(ctx.plugin.activationChanged.Event:Connect(function(active: boolean)
		self._enabled = active
		if not active then
			self:unequipActive()
		end
	end), "Disconnect")

	-- Key bindings: Z/X/C equip the corresponding tool; pressing the active
	-- tool's key toggles it off (same behaviour as clicking the button).
	-- Only fires while the plugin is active (_enabled).
	local unsubscribeKeys = ctx.input:subscribe(function(phase, input)
		if phase ~= "Began" then return end
		if not self._enabled then return end
		if input.UserInputType ~= Enum.UserInputType.Keyboard then return end
		local toolId = KEY_TOOL[input.KeyCode]
		if toolId == nil then return end
		if self._active ~= nil and self._active.id == toolId then return end
		self:equip(toolId)
	end)
	ctx.janitor:Add(unsubscribeKeys, true)

	-- Selection changes reach the active tool through its hook, never polling.
	ctx.janitor:Add(
		ctx.selection.changed:Connect(function()
			local tool = self._active
			if tool == nil or tool.onSelectionChanged == nil then
				return
			end
			safely(`tool "{tool.id}" onSelectionChanged`, function()
				(tool.onSelectionChanged :: any)(tool, ctx)
			end)
		end),
		"Disconnect"
	)

	-- Plugin teardown must leave no tool equipped (§12 checklist).
	ctx.janitor:Add(function()
		self:unequipActive()
	end, true)

	return self
end

function ToolHost.getActive(self: Internal): Tool.Tool?
	return self._active
end

function ToolHost.unequipActive(self: Internal)
	local tool = self._active
	if tool == nil then
		return
	end

	-- Drop the reference first so a faulty unequip cannot leave a
	-- half-live tool reachable.
	self._active = nil
	local toolJanitor = self._activeJanitor
	self._activeJanitor = nil

	safely(`tool "{tool.id}" unequip`, function()
		tool:unequip(self._ctx)
	end)
	if toolJanitor ~= nil then
		toolJanitor:Destroy()
	end

	self._signal:Fire()
end

function ToolHost.equip(self: Internal, id: Tool.ToolId)
	if self._active ~= nil and self._active.id == id then
		self:unequipActive() -- toggle: clicking/keying the active tool deselects it
		return
	end

	local tool = ToolRegistry[id]
	if tool == nil then
		error(`[BuilderTool] equip: no tool registered with id "{id}" (see ToolRegistry.luau)`)
	end

	self:unequipActive()

	local toolJanitor = Janitor.new()
	local ok, err = pcall(function()
		tool:equip(self._ctx)
	end)
	if not ok then
		-- Roll back to a clean no-tool state, then surface the failure.
		toolJanitor:Destroy()
		self._signal:Fire()
		error(`[BuilderTool] tool "{id}" equip failed: {err}`)
	end

	self._active = tool
	self._activeJanitor = toolJanitor
	self._ctx.settings:setLastToolId(id)
	self._signal:Fire()
end

return ToolHost
