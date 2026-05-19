--!strict
-- runtime/PluginHandles.luau
--
-- The plugin object and the Studio UI handles it vends. Built once; the
-- toolbar/button are created in app/Plugin.client.luau and stored here so
-- tools/UI reach them through the Context, never via a global (§5).
-- activationChanged fires(isActive: boolean) on every activation toggle so
-- the UI can animate without polling plugin:IsActivated().

export type Handles = {
	plugin: Plugin,
	toolbar: PluginToolbar?,
	button: PluginToolbarButton?,
	activationChanged: BindableEvent,
	mouse: PluginMouse,
}

local PluginHandles = {}

function PluginHandles.new(plugin: Plugin): Handles
	return {
		plugin = plugin,
		toolbar = nil,
		button = nil,
		activationChanged = Instance.new("BindableEvent"),
		mouse = plugin:GetMouse(),
	}
end

return PluginHandles
