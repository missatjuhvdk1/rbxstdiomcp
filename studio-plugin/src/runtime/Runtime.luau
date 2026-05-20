--!strict
-- runtime/Runtime.luau
--
-- THE typed dependency-injection object (ARCHITECTURE §5). There is no
-- global state. app/Plugin.client.luau builds exactly one Context via
-- Runtime.new(plugin, ...) and threads it everywhere by explicit
-- argument; the UI (Phase 6) will receive the same object through one
-- React context provider.
--
-- This module OWNS the Context shape. Nothing else mutates it. Pure
-- helpers (Path / Convert / Lines / Validator / Serialize) are NOT hung
-- off the Context — they are stateless, so consumers `require` them
-- where used. Keeping them off the Context means a hypothetical fake
-- Context for tests doesn't have to stub out 10 helper modules.
--
-- ============================================================================
-- WHAT BUILDS WHAT (read top-to-bottom; the order in Runtime.new mirrors it)
-- ============================================================================
--   services        ← game:GetService (Services.luau)
--   constants       ← frozen table       (Constants.luau)
--   pluginHandles   ← built by bootstrap, passed in (PluginHandles.luau)
--   settings        ← needs plugin + schemaVersion + janitor
--   logger          ← needs LogService + cap + janitor
--   http            ← needs HttpService
--   history         ← needs ChangeHistoryService
--   actionLog       ← needs ChangeHistoryService + path resolver + maxHistory
--   polling         ← needs http, constants, settings, RunService, dispatch, janitor
--   bridge          ← NIL in Phase 2; the bootstrap may set this later when
--                     Phase 3's Dispatcher lands. The Context field is typed
--                     `Bridge?` so consumers branch on its presence.
--
-- The `dispatch` parameter to Runtime.new lets the bootstrap supply a
-- callback for the Polling loop (Phase 2 supplies an inline /api/ping-only
-- handler; Phase 3 will replace it with `ctx.bridge:dispatch`). Decoupling
-- this means Runtime.luau doesn't have to know about the dispatcher type
-- — which would create the diamond (runtime/ → domain/ → runtime/) the
-- layer rules forbid.

local Janitor = require(script.Parent.Parent.Packages.Janitor)

local Services = require(script.Parent.Services)
local Constants = require(script.Parent.Constants)
local Settings = require(script.Parent.Settings)
local PluginHandles = require(script.Parent.PluginHandles)
local Logger = require(script.Parent.Logger)
local History = require(script.Parent.History)
local ActionLog = require(script.Parent.ActionLog)
local Path = require(script.Parent.instance.Path)
local HttpClient = require(script.Parent.http.HttpClient)
local Polling = require(script.Parent.http.Polling)

-- ============================================================================
-- BRIDGE INTERFACE (forward-declared here, implemented in Phase 3)
-- ============================================================================
-- The Dispatcher (domain/handler/Dispatcher.luau in Phase 3) will satisfy
-- this interface. Defining it here keeps the dependency arrow pointing
-- the right way: domain depends on runtime, never the reverse. The bridge
-- field on Context is OPTIONAL because Phase 2 ships without a dispatcher
-- — the Polling loop dispatches through an inline closure instead.

export type HandlerRequest = {
	endpoint: string,
	data: any,
	requestId: string,
}

export type Bridge = {
	dispatch: (self: Bridge, request: HandlerRequest) -> any,
}

-- ============================================================================
-- CONTEXT
-- ============================================================================

export type Context = {
	services: Services.Services,
	plugin: PluginHandles.Handles,
	constants: Constants.Constants,
	settings: Settings.Settings,
	logger: Logger.Logger,
	http: HttpClient.HttpClient,
	history: History.History,
	actionLog: ActionLog.ActionLog,
	polling: Polling.Polling,
	-- Filled by the bootstrap AFTER Runtime.new returns; nil during Phase 2
	-- (no Dispatcher exists yet). Consumers MUST handle the nil case
	-- defensively.
	bridge: Bridge?,
	janitor: Janitor.Janitor,
}

local Runtime = {}

-- The dispatch callback wires the Polling loop's request flow. In Phase 2
-- the bootstrap supplies an inline handler that knows about /api/ping
-- only. In Phase 3, the bootstrap will build a Dispatcher and supply
-- `function(req) return ctx.bridge:dispatch(req) end` instead.
function Runtime.new(
	plugin: Plugin,
	handles: PluginHandles.Handles,
	janitor: Janitor.Janitor,
	dispatch: Polling.Dispatch
): Context
	local services = Services.new()
	local constants = Constants.new()

	local context: Context = {
		services = services,
		plugin = handles,
		constants = constants,
		settings = Settings.new(plugin, constants.SCHEMA_VERSION, janitor),
		logger = Logger.new(services.logService, constants.MAX_OUTPUT_BUFFER, janitor),
		http = HttpClient.new(services.httpService),
		history = History.new(services.changeHistoryService),
		-- ActionLog needs a path resolver so it can restore script Source
		-- by path (instances may be re-parented between edit and undo).
		-- We pass Path.getInstanceByPath bound to the default `game` root.
		actionLog = ActionLog.new(services.changeHistoryService, function(p: string): Instance?
			return Path.getInstanceByPath(p)
		end, constants.MAX_ACTION_HISTORY),
		-- Polling is constructed last because it needs http/constants/
		-- settings AND a dispatch callback. The callback (often a closure
		-- over the Context) wires the request flow.
		polling = nil :: any, -- set below
		bridge = nil, -- Phase 3 will set this on the returned Context.
		janitor = janitor,
	}

	context.polling =
		Polling.new(context.http, context.constants, context.settings, services.runService, dispatch, janitor)

	return context
end

return Runtime
