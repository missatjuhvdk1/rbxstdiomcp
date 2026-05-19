--!strict
-- runtime/Runtime.luau
--
-- THE typed dependency-injection object (ARCHITECTURE §5). There is no
-- global state. app/Plugin.client.luau builds exactly one Context via
-- Runtime.new(plugin) and threads it everywhere by explicit argument; the
-- UI receives the same object through one React context provider.
--
-- This module OWNS the Context shape. Nothing else mutates it. Pure helpers
-- (Geometry, Snapping) are NOT hung off the Context — they are required
-- where used. Keep this lean.

local Janitor = require(script.Parent.Parent.Packages.Janitor)

local Services = require(script.Parent.Services)
local Constants = require(script.Parent.Constants)
local Settings = require(script.Parent.Settings)
local PluginHandles = require(script.Parent.PluginHandles)
local Input = require(script.Parent.Input)
local History = require(script.Parent.History)
local Viewport = require(script.Parent.Viewport)

local Selection = require(script.Parent.Parent.domain.Selection)
local ToolHost = require(script.Parent.Parent.domain.tool.ToolHost)

export type Context = {
	services: Services.Services,
	plugin: PluginHandles.Handles,
	constants: Constants.Constants,
	settings: Settings.Settings,
	input: Input.Input,
	history: History.History,
	selection: Selection.Selection,
	viewport: Viewport.Viewport,
	tools: ToolHost.ToolHost,
	janitor: Janitor.Janitor,
}

local Runtime = {}

function Runtime.new(plugin: Plugin): Context
	local janitor = Janitor.new()
	local services = Services.new()
	local constants = Constants.new()

	-- Build order matters: settings (with migration) before anything that
	-- reads a preference; viewport/input before the tool host.
	local sessionId = tostring(os.clock()):gsub("%.", ""):sub(1, 8)
	local context: Context = {
		services = services,
		plugin = PluginHandles.new(plugin),
		constants = constants,
		settings = Settings.new(plugin, constants.SCHEMA_VERSION, janitor),
		input = Input.new(services.userInput, janitor),
		history = History.new(services.changeHistory),
		selection = Selection.new(services.selection, janitor),
		viewport = Viewport.new(services.coreGui, sessionId, janitor, services.userInput),
		tools = nil :: any, -- set below (needs the assembled context)
		janitor = janitor,
	}

	context.tools = ToolHost.new(context)
	return context
end

return Runtime
