--!strict
-- runtime/PluginHandles.luau
--
-- Holder for the Studio handles vended by the `plugin` global (toolbar,
-- toggle button, dock widget). Built once at bootstrap and stored on the
-- Context so domain/ui code reaches them by explicit reference, never by
-- closing over module-level locals the way the legacy plugin.luau did
-- (the toolbar/button/widget there are top-level locals that EVERY part
-- of the file can read — a classic globals-by-another-name antipattern,
-- §15 A1).
--
-- We DO NOT create the handles inside this module. The bootstrap
-- (app/Plugin.client.luau) creates them and passes them in, because:
--   1. Toolbar/Button/Widget creation has the side effect of changing
--      Studio's UI, which §12 reserves for the bootstrap layer.
--   2. The lifetimes are owned by the root Janitor (also bootstrap-only),
--      and the Janitor:Add() calls happen at creation time so we can't
--      defer ownership.
--   3. `plugin:CreateDockWidgetPluginGuiAsync` yields — running it inside a
--      runtime constructor would surprise callers expecting Runtime.new to
--      return synchronously.
--
-- activationChanged is a BindableEvent so UI (Phase 6) can subscribe and
-- repaint without polling `pluginState.isActive`. Phase 2 doesn't fire it
-- yet (no toggle handler exists until the bootstrap wires polling), but
-- the channel is provisioned now so adding a fire site later is one line.
--
-- activationRequested (added in Phase 6) is the SYMMETRIC inbound channel:
-- the UI's Connect/Disconnect button fires it, the bootstrap listens and
-- runs the same setActive() path the toolbar button takes. Why a
-- BindableEvent instead of a typed callback on Handles:
--
--   1. PluginHandles.new() is called BEFORE the bootstrap defines its
--      setActive closure (the closure needs ctx + http + polling, and
--      ctx is built AFTER handles). A BindableEvent fixes the temporal
--      ordering: handles ship empty Event, bootstrap connects later.
--   2. A Bindable is naturally Janitor-tracked (we Add it to the same
--      janitor that owns activationChanged) — one fewer thing for the
--      bootstrap to remember to clean up.
--   3. The fire site (UI Connect button) and the listener (bootstrap) are
--      decoupled; future code that wants to programmatically toggle
--      activation (e.g. a `connect-on-launch` setting) fires the same
--      event without reaching into the bootstrap's locals.

local Janitor = require(script.Parent.Parent.Parent.Packages.Janitor)

export type Handles = {
	plugin: Plugin,
	toolbar: PluginToolbar,
	button: PluginToolbarButton,
	widget: DockWidgetPluginGui,
	-- Fires(isActive: boolean) every time the user (or another module) flips
	-- the active state. UI subscribes; never poll.
	activationChanged: BindableEvent,
	-- UI fires(desired: boolean) to request an activation toggle. The
	-- bootstrap listens and runs the setActive() path. See header comment.
	activationRequested: BindableEvent,
}

local PluginHandles = {}

function PluginHandles.new(
	plugin: Plugin,
	toolbar: PluginToolbar,
	button: PluginToolbarButton,
	widget: DockWidgetPluginGui,
	janitor: Janitor.Janitor
): Handles
	-- BindableEvents are the ONLY Instances allocated inside the runtime
	-- layer; they do not belong to the Studio UI tree, so they don't violate
	-- the §4.4 "UI Instances stay under src/ui/ or src/app/" rule (we're not
	-- creating a Frame/TextLabel/etc). Both ends of the activation channel
	-- live here so the bootstrap has a single place to look up wiring.
	local activationChanged = Instance.new("BindableEvent")
	activationChanged.Name = "MCPActivationChanged"
	janitor:Add(activationChanged, "Destroy")

	local activationRequested = Instance.new("BindableEvent")
	activationRequested.Name = "MCPActivationRequested"
	janitor:Add(activationRequested, "Destroy")

	return {
		plugin = plugin,
		toolbar = toolbar,
		button = button,
		widget = widget,
		activationChanged = activationChanged,
		activationRequested = activationRequested,
	}
end

return PluginHandles
