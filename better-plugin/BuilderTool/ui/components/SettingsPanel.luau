--!strict
-- ui/components/SettingsPanel.luau
--
-- The settings popover (ARCHITECTURE §11). Reads live preferences via
-- useSignal(ctx.settings.changed, …) and dispatches typed setters — no
-- business logic, no Color3 literals. Minimal for the menu phase: snap
-- toggle + grid-size stepper (both real, both persisted by Settings §10).

local React = require(script.Parent.Parent.Parent.Packages.React)

local Button = require(script.Parent.Button)
local useRuntime = require(script.Parent.Parent.hooks.useRuntime)
local useSignal = require(script.Parent.Parent.hooks.useSignal)
local useTheme = require(script.Parent.Parent.hooks.useTheme)

export type Props = {
	visible: boolean,
}

local function row(layoutOrder: number, label: string, labelColor: Color3, control: React.ReactNode): React.ReactNode
	return React.createElement("Frame", {
		AutomaticSize = Enum.AutomaticSize.Y,
		Size = UDim2.new(1, 0, 0, 0),
		BackgroundTransparency = 1,
		LayoutOrder = layoutOrder,
	}, {
		layout = React.createElement("UIListLayout", {
			FillDirection = Enum.FillDirection.Horizontal,
			VerticalAlignment = Enum.VerticalAlignment.Center,
			HorizontalAlignment = Enum.HorizontalAlignment.Left,
			SortOrder = Enum.SortOrder.LayoutOrder,
			Padding = UDim.new(0, 8),
		}),
		label = React.createElement("TextLabel", {
			AutomaticSize = Enum.AutomaticSize.XY,
			BackgroundTransparency = 1,
			Text = label,
			TextColor3 = labelColor,
			TextSize = 14,
			Font = Enum.Font.Gotham,
			LayoutOrder = 0,
		}),
		control = control,
	})
end

local function SettingsPanel(props: Props): React.ReactNode
	local ctx = useRuntime()
	local theme = useTheme()
	local settings = ctx.settings

	local isSnapEnabled = useSignal(settings.changed, function(): boolean
		return settings:isSnapEnabled()
	end)
	local gridSize = useSignal(settings.changed, function(): number
		return settings:getGridSize()
	end)

	if not props.visible then
		return nil
	end

	local snapControl = React.createElement(Button, {
		text = if isSnapEnabled then "On" else "Off",
		selected = isSnapEnabled,
		layoutOrder = 1,
		onClick = function()
			settings:setSnapEnabled(not isSnapEnabled)
		end,
	})

	local gridControl = React.createElement("Frame", {
		AutomaticSize = Enum.AutomaticSize.XY,
		BackgroundTransparency = 1,
		LayoutOrder = 1,
	}, {
		layout = React.createElement("UIListLayout", {
			FillDirection = Enum.FillDirection.Horizontal,
			VerticalAlignment = Enum.VerticalAlignment.Center,
			SortOrder = Enum.SortOrder.LayoutOrder,
			Padding = UDim.new(0, 6),
		}),
		minus = React.createElement(Button, {
			text = "-",
			layoutOrder = 0,
			onClick = function()
				settings:setGridSize(math.max(gridSize - 1, 0))
			end,
		}),
		value = React.createElement("TextLabel", {
			AutomaticSize = Enum.AutomaticSize.XY,
			BackgroundTransparency = 1,
			Text = string.format("%g", gridSize),
			TextColor3 = theme.textPrimary,
			TextSize = 14,
			Font = Enum.Font.GothamMedium,
			LayoutOrder = 1,
		}),
		plus = React.createElement(Button, {
			text = "+",
			layoutOrder = 2,
			onClick = function()
				settings:setGridSize(gridSize + 1)
			end,
		}),
	})

	return React.createElement("Frame", {
		AutomaticSize = Enum.AutomaticSize.Y,
		Size = UDim2.fromOffset(220, 0),
		BackgroundColor3 = theme.surface,
		LayoutOrder = 2,
		BorderSizePixel = 0,
	}, {
		corner = React.createElement("UICorner", {
			CornerRadius = UDim.new(0, 8),
		}),
		stroke = React.createElement("UIStroke", {
			Color = theme.border,
			Thickness = 1,
		}),
		padding = React.createElement("UIPadding", {
			PaddingTop = UDim.new(0, 12),
			PaddingBottom = UDim.new(0, 12),
			PaddingLeft = UDim.new(0, 12),
			PaddingRight = UDim.new(0, 12),
		}),
		layout = React.createElement("UIListLayout", {
			FillDirection = Enum.FillDirection.Vertical,
			SortOrder = Enum.SortOrder.LayoutOrder,
			Padding = UDim.new(0, 10),
		}),
		title = React.createElement("TextLabel", {
			AutomaticSize = Enum.AutomaticSize.XY,
			BackgroundTransparency = 1,
			Text = "Settings",
			TextColor3 = theme.textPrimary,
			TextSize = 16,
			Font = Enum.Font.GothamBold,
			LayoutOrder = 0,
		}),
		snapRow = row(1, "Snap to grid", theme.textSecondary, snapControl),
		gridRow = row(2, "Grid size", theme.textSecondary, gridControl),
	})
end

return React.memo(SettingsPanel)
