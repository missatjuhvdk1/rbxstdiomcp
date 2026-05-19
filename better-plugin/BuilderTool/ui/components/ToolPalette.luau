--!strict
-- ui/components/ToolPalette.luau
--
-- The tool-picker UI (ARCHITECTURE §11). Function component, hooks only.
-- Reads the tool registry + active tool from the Context, dispatches
-- ctx.tools:equip(id) on click. Matches ResurfacePlugin's primary-toolbar
-- shape: dark rounded bar with surface transparency, tool group on the left,
-- a divider, then the settings button. Settings panel drops below on toggle.

local React = require(script.Parent.Parent.Parent.Packages.React)

local ToolRegistry = require(script.Parent.Parent.Parent.domain.tool.ToolRegistry)
local Button = require(script.Parent.Button)
local Divider = require(script.Parent.Divider)
local SettingsPanel = require(script.Parent.SettingsPanel)
local ToolOptionsPanel = require(script.Parent.ToolOptionsPanel)
local useRuntime = require(script.Parent.Parent.hooks.useRuntime)
local useSignal = require(script.Parent.Parent.hooks.useSignal)
local useTheme = require(script.Parent.Parent.hooks.useTheme)

export type Props = {}

local DIVIDER_ORDER = 1000
local SETTINGS_ORDER = 1001

local function sortedTools()
	local tools = {}
	for _, tool in ToolRegistry do
		table.insert(tools, tool)
	end
	table.sort(tools, function(a, b)
		return a.order < b.order
	end)
	return tools
end

local function ToolPalette(): React.ReactNode
	local ctx = useRuntime()
	local theme = useTheme()

	local activeId = useSignal(ctx.tools.changed, function(): string?
		local active = ctx.tools:getActive()
		return if active then active.id else nil
	end)
	local isSettingsOpen, setSettingsOpen = React.useState(false)

	-- Corner radius for the bar: cornerRadius + spacing (matches ResurfacePlugin).
	local barCorner = UDim.new(0, theme.cornerRadius.Offset + theme.spacing)

	local barChildren: { [string]: React.ReactNode } = {
		layout = React.createElement("UIListLayout", {
			FillDirection = Enum.FillDirection.Horizontal,
			VerticalAlignment = Enum.VerticalAlignment.Center,
			SortOrder = Enum.SortOrder.LayoutOrder,
			Padding = UDim.new(0, theme.spacing),
		}),
		padding = React.createElement("UIPadding", {
			PaddingTop = UDim.new(0, theme.spacing),
			PaddingBottom = UDim.new(0, theme.spacing),
			PaddingLeft = UDim.new(0, math.floor(theme.spacing * 1.5)),
			PaddingRight = UDim.new(0, theme.spacing),
		}),
		corner = React.createElement("UICorner", {
			CornerRadius = barCorner,
		}),
	}

	for _, tool in sortedTools() do
		local id = tool.id
		barChildren["tool_" .. id] = React.createElement(Button, {
			text = tool.name,
			selected = activeId == id,
			layoutOrder = tool.order,
			onClick = function()
				ctx.tools:equip(id)
			end,
		})
	end

	barChildren.divider = React.createElement(Divider, {
		orientation = "vertical",
		layoutOrder = DIVIDER_ORDER,
	})

	barChildren.settings = React.createElement(Button, {
		text = "Settings",
		selected = isSettingsOpen,
		layoutOrder = SETTINGS_ORDER,
		onClick = function()
			setSettingsOpen(function(open)
				return not open
			end)
		end,
	})

	local bar = React.createElement("Frame", {
		AutomaticSize = Enum.AutomaticSize.XY,
		BackgroundColor3 = theme.surface,
		BackgroundTransparency = theme.surfaceTransparency,
		BorderSizePixel = 0,
		Size = UDim2.fromOffset(0, 0),
		LayoutOrder = 0,
	}, barChildren)

	return React.createElement("Frame", {
		AutomaticSize = Enum.AutomaticSize.XY,
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(0, 0),
	}, {
		layout = React.createElement("UIListLayout", {
			FillDirection = Enum.FillDirection.Vertical,
			HorizontalAlignment = Enum.HorizontalAlignment.Left,
			SortOrder = Enum.SortOrder.LayoutOrder,
			Padding = UDim.new(0, theme.spacing),
		}),
		bar = bar,
		optionsPanel = React.createElement(ToolOptionsPanel, {}),
		settingsPanel = React.createElement(SettingsPanel, {
			visible = isSettingsOpen,
		}),
	})
end

return React.memo(ToolPalette)
