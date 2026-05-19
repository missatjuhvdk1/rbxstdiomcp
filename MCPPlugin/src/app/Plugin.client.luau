--!strict
-- app/Plugin.client.luau
--
-- THE bootstrap. The ONLY auto-run script and the ONLY file with top-level
-- side effects (ARCHITECTURE §12). Thin by design: build the root Janitor,
-- create the toolbar + toggle button, create the dock widget, wire button-
-- click to widget-visibility, and register ONE plugin.Unloading handler whose
-- entire body is `janitor:Destroy()`.
--
-- Phase 1 scope: this file is intentionally a "Hello, plugin" stub. It does
-- NOT yet build a typed Context (Runtime.new) or mount a React tree — those
-- arrive in Phase 2 and Phase 6 respectively. Until then, every disposable
-- thing this file creates is added to one Janitor at the moment it is
-- created, exactly as required by §12. That invariant is the seam that
-- makes the later phases drop in without rewriting the bootstrap.

local Janitor = require(script.Parent.Parent.Packages.Janitor)

local TOOLBAR_NAME = "MCP Integration"
local BUTTON_NAME = "MCP Server"
local BUTTON_TOOLTIP = "Connect to MCP Server for AI Integration"
local BUTTON_ICON = "rbxassetid://10734944444"

local WIDGET_ID = "MCPServerInterface"
local WIDGET_TITLE = "MCP Server v3.0.0-pre"

-- 1. Root teardown scope. Everything disposable goes through this.
local janitor = Janitor.new()

-- 2. Toolbar + toggle button. CreateToolbar/CreateButton return handles that
--    Studio owns; we don't `Add` them to the janitor (Studio cleans them up
--    when the plugin unloads). The Click connection, however, is ours.
local toolbar = plugin:CreateToolbar(TOOLBAR_NAME)
local button = toolbar:CreateButton(BUTTON_NAME, BUTTON_TOOLTIP, BUTTON_ICON)
button.ClickableWhenViewportHidden = true

-- 3. Dock widget. Initial state Float so first-run users see it; resizable.
--    Sized to match the legacy v2.0.0 dimensions so Phase 6 UI screenshots
--    can be diffed against the old plugin without rescaling.
local widgetInfo = DockWidgetPluginGuiInfo.new(
	Enum.InitialDockState.Float, -- initialDockState
	false, -- initialEnabled
	false, -- overrideEnabledRestore
	400, -- floatingXSize
	500, -- floatingYSize
	350, -- minWidth
	450 -- minHeight
)
local widget = plugin:CreateDockWidgetPluginGuiAsync(WIDGET_ID, widgetInfo)
widget.Title = WIDGET_TITLE
widget.Name = WIDGET_ID
widget.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
janitor:Add(widget, "Destroy")

-- 4. Activation wiring. The button toggles widget visibility; widget itself
--    syncs button state back when the user closes via the X. Both
--    connections are Janitor-tracked (ARCHITECTURE §12 teardown checklist).
janitor:Add(
	button.Click:Connect(function()
		widget.Enabled = not widget.Enabled
	end),
	"Disconnect"
)

janitor:Add(
	widget:GetPropertyChangedSignal("Enabled"):Connect(function()
		button:SetActive(widget.Enabled)
	end),
	"Disconnect"
)

-- 5. The single teardown path. ARCHITECTURE §12 checklist is satisfied by
--    one call. Subsequent phases extend `janitor`; this line never changes.
plugin.Unloading:Connect(function()
	janitor:Destroy()
end)
