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
-- Phase 2 scope:
--   - Builds a typed Context via Runtime.new (was a stub in Phase 1).
--   - Wires the button to start/stop the polling loop (was widget-toggle
--     only in Phase 1; we keep widget toggle on a separate click).
--   - Registers a single inline `/api/ping` handler (the Phase 2 verification
--     hook) that returns `{ ok = true }`. Phase 3 replaces this with a
--     real Dispatcher that owns handler registration.
--   - Wires Settings:changed to push the server URL the user typed into
--     a future-Phase 6 text input (no UI yet; the value comes from
--     persisted settings or the default).
--
-- Out of Phase 2 scope (deliberately deferred):
--   - The 11-section dock-widget UI: Phase 6. Until then the widget shows
--     a simple TextLabel ("Phase 2 — polling started") so the user has a
--     hint the plugin is alive.
--   - Real handler dispatch beyond /api/ping: Phase 3.
--   - Test-companion injection / playSolo: Phase 4-5.

local Janitor = require(script.Parent.Parent.Packages.Janitor)
local Runtime = require(script.Parent.Parent.runtime.Runtime)
local Constants = require(script.Parent.Parent.runtime.Constants)
local PluginHandles = require(script.Parent.Parent.runtime.PluginHandles)

-- One frozen constants table read once at bootstrap; we use a few of its
-- fields (UI strings, widget id) directly here. The Context's `.constants`
-- is the same table, available to every other layer.
local constants = Constants.new()

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
statusLabel.Name = "Phase2StatusLabel"
statusLabel.Size = UDim2.new(1, -20, 1, -20)
statusLabel.Position = UDim2.new(0, 10, 0, 10)
statusLabel.BackgroundColor3 = Color3.fromRGB(17, 24, 39)
statusLabel.BorderSizePixel = 0
statusLabel.Text = "MCP " .. constants.PLUGIN_VERSION .. "\nClick the toolbar button to connect."
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
-- 5. INLINE DISPATCH (Phase 2 placeholder)
-- ============================================================================
-- Phase 2 ships one handler: /api/ping. Phase 3 will introduce the
-- Dispatcher in domain/handler/Dispatcher.luau, which takes over the role
-- this closure plays. The CONTRACT (signature) is the same — that's the
-- whole point of Runtime accepting a `Dispatch` callback rather than
-- knowing about the Dispatcher type directly: the swap from inline to
-- real-dispatcher will be a one-line change.
--
-- The handler table is kept here (rather than scattered in modules) so the
-- inline placeholder remains a single, easy-to-delete block when Phase 3
-- lands.
local inlineHandlers: { [string]: (data: any) -> any } = {
	["/api/ping"] = function(_data)
		-- Sanity payload: the bridge's `ping` MCP tool surfaces ok=true,
		-- version, and a timestamp so the user can confirm the plugin is
		-- the version they think it is.
		return {
			ok = true,
			version = constants.PLUGIN_VERSION,
			timestamp = os.time(),
		}
	end,
}

local function dispatch(request: Runtime.HandlerRequest): any
	local handler = inlineHandlers[request.endpoint]
	if handler == nil then
		return {
			error = "Unknown endpoint: " .. tostring(request.endpoint),
			phase = "Phase 2 — only /api/ping is registered",
		}
	end
	-- pcall is defensive even for the trivial /api/ping handler: a future
	-- typo here must not crash the polling loop.
	local ok, result = pcall(handler, request.data)
	if not ok then
		return { error = "Handler crashed: " .. tostring(result) }
	end
	return result
end

-- ============================================================================
-- 6. CONTEXT — single typed DI graph for the whole plugin.
-- ============================================================================
local ctx = Runtime.new(plugin, handles, janitor, dispatch)

-- ============================================================================
-- 7. STATUS LABEL UPDATE (Phase 2 placeholder UI feedback)
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
