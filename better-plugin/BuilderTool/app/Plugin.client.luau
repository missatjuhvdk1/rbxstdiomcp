--!strict
-- app/Plugin.client.luau
--
-- THE bootstrap. The ONLY auto-run script and the ONLY file with top-level
-- side effects (ARCHITECTURE §12). Thin by design: build the Context, create
-- the ScreenGui viewport widget, mount React, wire activation, register ONE
-- Unloading handler that destroys the root Janitor.

local React = require(script.Parent.Parent.Packages.React)
local ReactRoblox = require(script.Parent.Parent.Packages.ReactRoblox)

local Runtime = require(script.Parent.Parent.runtime.Runtime)
local App = require(script.Parent.Parent.ui.App)

local TOOLBAR_NAME = "BuilderTool"
local BUTTON_TOOLTIP = "Open the BuilderTool palette"

-- 1. The one typed Context (services, settings, janitor, input, history,
--    selection, viewport, tool host).
local context = Runtime.new(plugin)
local janitor = context.janitor
local activationChanged = context.plugin.activationChanged

-- BindableEvent must be cleaned up by the janitor.
janitor:Add(activationChanged, "Destroy")

-- 2. Toolbar + toggle button.
local toolbar = plugin:CreateToolbar(TOOLBAR_NAME)
local button = toolbar:CreateButton("BuilderTool", BUTTON_TOOLTIP, "")
button.ClickableWhenViewportHidden = true
context.plugin.toolbar = toolbar
context.plugin.button = button

-- 3. ScreenGui viewport widget + React render root.
--    Lives in CoreGui so it floats over the 3D viewport (ResurfacePlugin
--    pattern). The React tree handles visibility via spring animation.
local container = Instance.new("ScreenGui")
container.Name = "BuilderToolViewport"
container.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
container.IgnoreGuiInset = true
container.ResetOnSpawn = false
container.Parent = context.services.coreGui

local root = ReactRoblox.createRoot(container)
root:render(React.createElement(App, { context = context }))

-- 4. Activation wiring. Toolbar button ⇄ plugin:Activate/Deactivate ⇄ signal.
janitor:Add(button.Click:Connect(function()
	if plugin:IsActivated() then
		plugin:Deactivate()
		-- Deactivation signal fires plugin.Deactivation below, no extra Fire needed.
	else
		plugin:Activate(true)
		button:SetActive(true)
		activationChanged:Fire(true)
	end
end), "Disconnect")

janitor:Add(plugin.Deactivation:Connect(function()
	button:SetActive(false)
	activationChanged:Fire(false)
end), "Disconnect")

-- 5. Resource ownership: one Janitor owns everything disposable.
janitor:Add(root, "unmount")
janitor:Add(container, "Destroy")

-- 6. The single teardown path (ARCHITECTURE §12 checklist).
plugin.Unloading:Connect(function()
	if plugin:IsActivated() then
		plugin:Deactivate()
	end
	janitor:Destroy()
end)
