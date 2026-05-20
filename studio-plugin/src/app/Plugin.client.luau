--!strict
-- app/Plugin.client.luau
--
-- THE bootstrap. The ONLY auto-run script and the ONLY file with top-level
-- side effects (ARCHITECTURE §12). Thin by design: build the root Janitor,
-- create the toolbar + toggle button, create the dock widget, build the
-- Runtime Context, mount the React UI, start polling on activate, stop on
-- deactivate, and register ONE plugin.Unloading handler whose entire body is
-- `janitor:Destroy()`.
--
-- Phase 6 scope:
--   - Replaces the Phase 3 placeholder TextLabel with a full React tree
--     (ReactRoblox.createRoot + ui/App). DockShell paints header + connection
--     panel + status panel, hooks subscribe to ctx.polling.statusChanged and
--     ctx.settings.changed and re-render on signal (never poll).
--   - Bridges UI Connect/Disconnect button → bootstrap setActive() via the
--     handles.activationRequested BindableEvent. The toolbar button keeps
--     the same Click connection; both paths converge on the same closure.
--   - Drops the Phase-3 `statusChanged → statusLabel` listener (the React
--     hooks own that surface now). Drops the placeholder TextLabel itself.
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
--
-- ============================================================================
-- WHY THE REACT ROOT MOUNTS DIRECTLY INTO THE DOCK WIDGET
-- ============================================================================
-- BuilderTool mounts into a ScreenGui parented to CoreGui because its tool is
-- a floating palette over the 3D viewport. Ours is a docked side panel; the
-- DockWidgetPluginGui IS a Gui container and Studio already manages its
-- visibility / docking / resize. Parenting an extra ScreenGui inside it would
-- add a layer Studio doesn't expect and we don't need.

local React = require(script.Parent.Parent.Packages.React)
local ReactRoblox = require(script.Parent.Parent.Packages.ReactRoblox)
local Janitor = require(script.Parent.Parent.Packages.Janitor)

local Runtime = require(script.Parent.Parent.runtime.Runtime)
local Constants = require(script.Parent.Parent.runtime.Constants)
local PluginHandles = require(script.Parent.Parent.runtime.PluginHandles)
local Dispatcher = require(script.Parent.Parent.domain.handler.Dispatcher)
local HandlerRegistry = require(script.Parent.Parent.domain.handler.HandlerRegistry)
local App = require(script.Parent.Parent.ui.App)

-- One frozen constants table read once at bootstrap; we use a few of its
-- fields (UI strings, widget id) directly here. The Context's `.constants`
-- is the same table, available to every other layer.
local constants = Constants.new()

-- ============================================================================
-- 1. ROOT TEARDOWN SCOPE
-- ============================================================================
-- Everything disposable goes through this. The plugin.Unloading handler at
-- the bottom of this file never changes — it always reduces to one call.
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
-- match the legacy v2.0.0 widget so Phase 6 UI screenshots diff cleanly
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

-- ============================================================================
-- 4. PLUGIN HANDLES — vended into the Context so domain/ui code never has
--    to close over the locals above. Allocates the two activation
--    BindableEvents (Changed = outbound, Requested = inbound) and tracks
--    them on the same janitor.
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
-- 7. REACT MOUNT — the dock widget IS our render root.
-- ============================================================================
-- We render <App context={ctx}/> directly into the DockWidgetPluginGui.
-- ReactRoblox.createRoot returns a root with a typed unmount() method;
-- Janitor's "unmount" cleanup-method-name string invokes it on Destroy().
-- The widget itself is also janitored (above) so cleanup order is:
--   1. plugin.Unloading fires
--   2. janitor:Destroy() iterates in reverse-add order
--   3. root:unmount() detaches the React tree (calls all useEffect cleanups,
--      disconnecting every useSignal subscription)
--   4. widget:Destroy() tears down the (now-empty) container
local root = ReactRoblox.createRoot(widget)
root:render(React.createElement(App, { context = ctx }))
janitor:Add(root, "unmount")

-- ============================================================================
-- 8. ACTIVATION WIRING
-- ============================================================================
-- TWO entry points converge on the SAME setActive() closure:
--
--   a. Toolbar button (button.Click) — Studio-owned chrome.
--   b. UI Connect/Disconnect button — fires handles.activationRequested via
--      the React tree (see ui/components/ConnectionPanel.luau).
--
-- The closure handles the side-effects (POST /ready or /disconnect, start
-- or stop polling, update toolbar button state, fire activationChanged so
-- the UI can repaint). activationChanged is the OUTBOUND signal; the React
-- ConnectionPanel subscribes to it via useSignal so the button label flips
-- without us threading state through props.
local function setActive(active: boolean)
	-- Idempotency guard: re-entry is harmless but produces noisy /ready or
	-- /disconnect POSTs that confuse the bridge logs.
	if ctx.polling:isActive() == active then
		return
	end

	if active then
		-- Notify the bridge we're starting; one-shot, ignore the response.
		-- Mirrors legacy /ready (L6948-6959) so the bridge can paint its
		-- "plugin attached" status immediately rather than waiting for the
		-- first /poll to land.
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

-- Toolbar entry point — also opens the widget when the user has it closed.
janitor:Add(
	button.Click:Connect(function()
		if not widget.Enabled then
			widget.Enabled = true
		end
		setActive(not ctx.polling:isActive())
	end),
	"Disconnect"
)

-- UI entry point — fires from ConnectionPanel's Connect/Disconnect button.
-- The `desired` payload lets the UI request a specific state rather than a
-- toggle, which keeps the React side stateless wrt the button's current
-- label (the label comes from useSignal(activationChanged) on its own).
janitor:Add(
	handles.activationRequested.Event:Connect(function(desired: boolean)
		setActive(desired)
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
