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

local Janitor = require(script.Parent.Parent.Parent.Packages.Janitor)

export type Handles = {
	plugin: Plugin,
	toolbar: PluginToolbar,
	button: PluginToolbarButton,
	widget: DockWidgetPluginGui,
	-- Fires(isActive: boolean) every time the user (or another module) flips
	-- the active state. UI subscribes; never poll.
	activationChanged: BindableEvent,
}

local PluginHandles = {}

function PluginHandles.new(
	plugin: Plugin,
	toolbar: PluginToolbar,
	button: PluginToolbarButton,
	widget: DockWidgetPluginGui,
	janitor: Janitor.Janitor
): Handles
	-- BindableEvent is the ONLY Instance allocated inside the runtime layer;
	-- it does not belong to the Studio UI tree, so it doesn't violate the
	-- §4.4 "UI Instances stay under src/ui/ or src/app/" rule (we're not
	-- creating a Frame/TextLabel/etc).
	local activationChanged = Instance.new("BindableEvent")
	activationChanged.Name = "MCPActivationChanged"
	janitor:Add(activationChanged, "Destroy")

	return {
		plugin = plugin,
		toolbar = toolbar,
		button = button,
		widget = widget,
		activationChanged = activationChanged,
	}
end

return PluginHandles
