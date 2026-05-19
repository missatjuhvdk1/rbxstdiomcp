--!strict
-- ui/components/Button.luau
--
-- Toolbar button (ARCHITECTURE §11). Matches ResurfacePlugin's button visual:
-- rounded rectangle, UIStroke border, spring-animated background/text colour
-- transitions, yellow accent when selected. No business logic; forwards onClick.

local React = require(script.Parent.Parent.Parent.Packages.React)
local ReactSpring = require(script.Parent.Parent.Parent.Packages.ReactSpring)
local useTheme = require(script.Parent.Parent.hooks.useTheme)

export type Props = {
	text: string?,
	selected: boolean?,
	onClick: () -> (),
	layoutOrder: number?,
}

local function Button(props: Props): React.ReactNode
	local theme = useTheme()
	local isHovered, setHovered = React.useState(false)
	local isPressed, setPressed = React.useState(false)

	local selected = props.selected == true

	local bg = if selected then theme.accent
		elseif isPressed then theme.buttonPressed
		elseif isHovered then theme.buttonHovered
		else theme.button
	local textCol = if selected then theme.onAccent else theme.textPrimary

	local springs = ReactSpring.useSpring({
		backgroundColor = bg,
		textColor = textCol,
		borderColor = theme.buttonBorder,
		config = { duration = 0.125, easing = ReactSpring.easings.easeOutQuad },
	})

	return React.createElement("TextButton", {
		AutoButtonColor = false,
		AutomaticSize = Enum.AutomaticSize.XY,
		BackgroundColor3 = springs.backgroundColor,
		BackgroundTransparency = 0,
		BorderSizePixel = 0,
		Text = "",
		LayoutOrder = props.layoutOrder,
		[React.Event.MouseEnter] = function()
			setHovered(true)
		end,
		[React.Event.MouseLeave] = function()
			setHovered(false)
			setPressed(false)
		end,
		[React.Event.MouseButton1Down] = function()
			setPressed(true)
		end,
		[React.Event.MouseButton1Up] = function()
			setPressed(false)
		end,
		[React.Event.Activated] = function()
			props.onClick()
		end,
	}, {
		corner = React.createElement("UICorner", {
			CornerRadius = theme.cornerRadius,
		}),
		stroke = React.createElement("UIStroke", {
			ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
			Color = springs.borderColor,
			Thickness = 1,
		}),
		layout = React.createElement("UIListLayout", {
			HorizontalAlignment = Enum.HorizontalAlignment.Center,
			VerticalAlignment = Enum.VerticalAlignment.Center,
			FillDirection = Enum.FillDirection.Horizontal,
			SortOrder = Enum.SortOrder.LayoutOrder,
		}),
		padding = React.createElement("UIPadding", {
			PaddingTop = UDim.new(0, theme.spacing),
			PaddingBottom = UDim.new(0, theme.spacing),
			PaddingLeft = UDim.new(0, theme.spacing),
			PaddingRight = UDim.new(0, theme.spacing),
		}),
		label = props.text and React.createElement("TextLabel", {
			AutomaticSize = Enum.AutomaticSize.XY,
			BackgroundTransparency = 1,
			Text = props.text,
			TextColor3 = springs.textColor,
			TextSize = theme.textSize,
			FontFace = Font.new(
				"rbxasset://fonts/families/BuilderSans.json",
				Enum.FontWeight.SemiBold
			),
		}) or nil,
	})
end

return React.memo(Button)
