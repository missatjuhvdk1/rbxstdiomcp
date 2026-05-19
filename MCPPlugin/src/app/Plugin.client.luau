--!strict
-- app/Plugin.client.luau
--
-- THE bootstrap. The ONLY auto-run script and the ONLY file with top-level
-- side effects (ARCHITECTURE §12). Thin by design: build the root Janitor,
-- create the toolbar + toggle button, create the dock widget, build the
-- Runtime Context, start polling on activate, stop on deactivate, and
-- register ONE plugin.Unloading handler whose entire body is
-- `janitor:Destroy()`.
--
-- Phase 3 scope:
--   - Builds a typed Context via Runtime.new (Phase 2 stable).
--   - Wires the button to start/stop the polling loop (Phase 2 stable).
--   - Replaces the Phase 2 inline `/api/ping` closure with the real
--     Dispatcher (domain/handler/Dispatcher.luau), which routes every
--     endpoint declared in HandlerRegistry — including a real /api/ping
--     supplied by PlaceHandlers. The bootstrap no longer enumerates
--     endpoints; it just hands the polling loop a dispatch closure that
--     forwards to ctx.bridge:dispatch (where bridge IS the Dispatcher).
--   - Wires Settings:changed to push the server URL the user typed into
--     a future-Phase 6 text input (no UI yet; the value comes from
--     persisted settings or the default).
--
-- Out of Phase 3 scope (deliberately deferred):
--   - The 11-section dock-widget UI: Phase 6. Until then the widget shows
--     a simple TextLabel ("Phase 3 — N handlers registered") so the user
--     has a hint the plugin is alive.
--   - Mutating handlers (edit_script, set_property, create_object, …): Phase 4.
--   - Test-companion injection / playSolo: Phase 4-5.
--
-- ============================================================================
-- WHY THE DISPATCHER IS BUILT AFTER Runtime.new
-- ============================================================================
-- The Runtime constructor takes a `dispatch: (HandlerRequest) -> any`
-- callback (the polling loop's request flow needs it before the loop is
-- constructed), but the Dispatcher needs the FULL Context to inject into
-- handlers. Classic chicken-and-egg.
--
-- Resolution: forward-declare a local `dispatcher` variable, pass a
-- closure that reads it (Runtime.new accepts the closure), build the
-- Context, then assign the real Dispatcher into the local + the
-- ctx.bridge slot. Until the assignment lands, the closure refuses
-- requests with an error — but Runtime.new doesn't dispatch anything
-- synchronously, so the racing window is empty.

local Janitor = require(script.Parent.Parent.Packages.Janitor)
local Runtime = require(script.Parent.Parent.runtime.Runtime)
local Constants = require(script.Parent.Parent.runtime.Constants)
local PluginHandles = require(script.Parent.Parent.runtime.PluginHandles)
local Dispatcher = require(script.Parent.Parent.domain.handler.Dispatcher)
local HandlerRegistry = require(script.Parent.Parent.domain.handler.HandlerRegistry)

-- One frozen constants table read once at bootstrap; we use a few of its
-- fields (UI strings, widget id) directly here. The Context's `.constants`
-- is the same table, available to every other layer.
local constants = Constants.new()

-- Count of registered endpoints. Computed once at boot so the status label
-- below can render an accurate "Phase 3 — N handlers registered" line
-- without us hardcoding the number; as Phase 4+ extends HandlerRegistry the
-- label stays honest automatically.
local handlerCount = 0
for _ in HandlerRegistry do
	handlerCount += 1
end

-- ============================================================================
-- 1. ROOT TEARDOWN SCOPE
-- ============================================================================
-- Everything disposable goes through this. Subsequent phases extend it; the
-- plugin.Unloading handler at the bottom of this file never changes.
local janitor = Janitor.new()

-- ============================================================================
-- 2. TOOLBAR + BUTTON (Studio-owned; Click connection is ours)
-- ============================================================================
-- CreateToolbar/CreateButton return handles Studio owns; we don't Add() them
-- to the janitor (Studio cleans them up when the plugin unloads). The Click
-- connection, however, is ours, and goes in the janitor below.
local toolbar = plugin:CreateToolbar(constants.TOOLBAR_NAME)
local button = toolbar:CreateButton(constants.BUTTON_NAME, constants.BUTTON_TOOLTIP, constants.BUTTON_ICON)
button.ClickableWhenViewportHidden = true

-- ============================================================================
-- 3. DOCK WIDGET (sized to match legacy v2 for visual diff parity)
-- ============================================================================
-- Float initial state so first-run users see it; resizable. The dimensions
-- match the legacy v2.0.0 widget so Phase 6 UI screenshots can be diffed
-- against the old plugin without rescaling.
local widgetInfo = DockWidgetPluginGuiInfo.new(
	Enum.InitialDockState.Float, -- initialDockState
	false, -- initialEnabled
	false, -- overrideEnabledRestore
	400, -- floatingXSize
	500, -- floatingYSize
	350, -- minWidth
	450 -- minHeight
)
local widget = plugin:CreateDockWidgetPluginGuiAsync(constants.WIDGET_ID, widgetInfo)
widget.Title = constants.WIDGET_TITLE
widget.Name = constants.WIDGET_ID
widget.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
janitor:Add(widget, "Destroy")

-- Phase 6 will replace this placeholder with the real React tree. For now,
-- one TextLabel so a developer running the plugin sees that it's alive and
-- which state the polling loop is in. This is the ONLY UI Instance the
-- bootstrap creates pre-Phase 6.
local statusLabel = Instance.new("TextLabel")
statusLabel.Name = "Phase3StatusLabel"
statusLabel.Size = UDim2.new(1, -20, 1, -20)
statusLabel.Position = UDim2.new(0, 10, 0, 10)
statusLabel.BackgroundColor3 = Color3.fromRGB(17, 24, 39)
statusLabel.BorderSizePixel = 0
statusLabel.Text = string.format(
	"MCP %s\nPhase 3 — %d read-only handlers registered.\nClick the toolbar button to connect.",
	constants.PLUGIN_VERSION,
	handlerCount
)
statusLabel.TextColor3 = Color3.fromRGB(229, 231, 235)
statusLabel.TextWrapped = true
statusLabel.TextSize = 14
statusLabel.Font = Enum.Font.Code
statusLabel.TextXAlignment = Enum.TextXAlignment.Left
statusLabel.TextYAlignment = Enum.TextYAlignment.Top
statusLabel.Parent = widget

-- ============================================================================
-- 4. PLUGIN HANDLES — vended into the Context so domain/ui code never has
--    to close over the locals above.
-- ============================================================================
local handles = PluginHandles.new(plugin, toolbar, button, widget, janitor)

-- ============================================================================
-- 5. DISPATCHER FORWARD-DECLARATION
-- ============================================================================
-- See the header comment block "WHY THE DISPATCHER IS BUILT AFTER Runtime.new"
-- for the full rationale. Short version: Runtime.new wants a Dispatch callback
-- NOW, the Dispatcher wants a fully-built Context to inject into handlers,
-- and the Context has a `bridge` field the Dispatcher will fill. We resolve
-- the cycle by forward-declaring the dispatcher local, passing a closure that
-- reads it, then assigning the real Dispatcher after Runtime.new returns.
--
-- The closure refuses requests with an error until the assignment lands, but
-- Runtime.new does not synchronously dispatch anything (the polling loop is
-- inert until ctx.polling:start() is called from setActive below), so the
-- racing window is empty in practice. The guard is defensive only.
local dispatcher: Dispatcher.Dispatcher? = nil

local function dispatch(request: Runtime.HandlerRequest): any
	if dispatcher == nil then
		-- Unreachable in practice (see comment above); kept as a hard guard
		-- so a future refactor that DOES dispatch synchronously from inside
		-- Runtime.new fails loud rather than NPE'ing inside the closure.
		return { error = "Dispatcher not yet wired" }
	end
	return dispatcher:dispatch(request)
end

-- ============================================================================
-- 6. CONTEXT — single typed DI graph for the whole plugin.
-- ============================================================================
local ctx = Runtime.new(plugin, handles, janitor, dispatch)

-- ============================================================================
-- 6b. DISPATCHER WIRING — now that ctx exists, build the real dispatcher and
--     close the forward-declaration cycle by populating ctx.bridge.
-- ============================================================================
-- HandlerRegistry is the single greppable catalogue of MCP endpoints (one
-- row per endpoint, see domain/handler/HandlerRegistry.luau). Passing it
-- explicitly (rather than letting Dispatcher.new re-require it internally)
-- keeps test seams open: a future test can build a Dispatcher with a stub
-- registry of one handler.
dispatcher = Dispatcher.new(ctx, HandlerRegistry)
ctx.bridge = dispatcher

-- ============================================================================
-- 7. STATUS LABEL UPDATE (Phase 3 placeholder UI feedback)
-- ============================================================================
-- Bridge the typed status signal to the placeholder TextLabel. Phase 6
-- will replace this listener with the proper React state binding. We use
-- ctx.polling.statusChanged (signal, not poll) so the label only repaints
-- on state transitions — no per-frame churn.
janitor:Add(
	ctx.polling.statusChanged:Connect(function(update)
		local serverUrl = ctx.settings:getServerUrl()
		statusLabel.Text = string.format(
			"MCP %s\n%s\nstatus: %s\nfailures: %d\nlast error: %s",
			constants.PLUGIN_VERSION,
			serverUrl,
			update.status,
			update.consecutiveFailures,
			update.lastError or "<none>"
		)
	end),
	"Disconnect"
)

-- ============================================================================
-- 8. ACTIVATION WIRING
-- ============================================================================
-- Button.Click toggles activation. We track the "active" boolean locally
-- (mirroring ctx.polling:isActive()) so we can fire the
-- PluginHandles.activationChanged BindableEvent — the UI (Phase 6) will
-- listen to that for repaint without polling.
local function setActive(active: boolean)
	if active then
		-- Notify the bridge we're starting; one-shot, ignore the response.
		-- This mirrors legacy /ready (L6948-6959) so the bridge can paint
		-- its "plugin attached" status immediately rather than waiting for
		-- the first /poll to land.
		local readyUrl = ctx.settings:getServerUrl() .. ctx.constants.ENDPOINT_READY
		ctx.http:postJson(readyUrl, {
			pluginReady = true,
			version = ctx.constants.PLUGIN_VERSION,
			timestamp = os.time(),
		})

		ctx.polling:start()
		widget.Enabled = true
		button:SetActive(true)
		handles.activationChanged:Fire(true)
	else
		-- Notify the bridge we're stopping; one-shot, ignore the response.
		-- Mirrors legacy /disconnect (L6978-6989).
		local disconnectUrl = ctx.settings:getServerUrl() .. ctx.constants.ENDPOINT_DISCONNECT
		ctx.http:postJson(disconnectUrl, {
			timestamp = os.time(),
		})

		ctx.polling:stop()
		button:SetActive(false)
		handles.activationChanged:Fire(false)
		-- We deliberately do NOT auto-hide the widget on deactivate; the
		-- user may want to keep the panel open to read the last error
		-- before they fix the bridge and re-enable. The X button still works.
	end
end

janitor:Add(
	button.Click:Connect(function()
		setActive(not ctx.polling:isActive())
	end),
	"Disconnect"
)

-- ============================================================================
-- 9. THE SINGLE TEARDOWN PATH
-- ============================================================================
-- ARCHITECTURE §12 checklist is satisfied by one call. Every disposable
-- thing created above lives under `janitor`; one Destroy() reliably tears
-- the whole thing down. The CI gate enforces the no-orphans property by
-- catching forbidden patterns at compile time; this is the runtime side.
plugin.Unloading:Connect(function()
	-- Best-effort disconnect notification before tearing down. We can't
	-- guarantee the bridge sees it (Studio kills the plugin process on
	-- some unload paths), but it's polite to try.
	pcall(function()
		if ctx.polling:isActive() then
			local disconnectUrl = ctx.settings:getServerUrl() .. ctx.constants.ENDPOINT_DISCONNECT
			ctx.http:postJson(disconnectUrl, { timestamp = os.time(), reason = "unloading" })
		end
	end)
	janitor:Destroy()
end)
