--!strict
-- ui/components/StepRow.luau
--
-- One row in the "step-by-step status" stack inside StatusPanel. Refactors
-- the legacy `createStepRow` factory at [studio-plugin/plugin.luau L1525].
-- Each row is: small coloured dot on the left, label text to its right.
-- The dot's colour is the only signal we paint; the label text is fixed
-- per row (the caller passes a string like "1. HTTP server reachable").
--
-- Stateless and presentational — no signal subscriptions, no Context read.
-- The parent (StatusPanel) computes the state for all three rows in one
-- pass and forwards each row's colour as a prop.

local React = require(script.Parent.Parent.Parent.Packages.React)
local Theme = require(script.Parent.Parent.theme.Theme)
local useTheme = require(script.Parent.Parent.hooks.useTheme)

export type StepState = "idle" | "ok" | "waiting" | "error"

export type Props = {
	label: string,
	state: StepState,
	layoutOrder: number?,
}

local function colourFor(theme: Theme.Tokens, state: StepState): Color3
	if state == "ok" then
		return theme.stateConnected
	elseif state == "waiting" then
		return theme.stateWaiting
	elseif state == "error" then
		return theme.stateError
	else
		return theme.stateIdle
	end
end

local function StepRow(props: Props): React.ReactNode
	local theme = useTheme()
	local dotColour = colourFor(theme, props.state)

	return React.createElement("Frame", {
		Size = UDim2.new(1, 0, 0, 16),
		BackgroundTransparency = 1,
		LayoutOrder = props.layoutOrder,
	}, {
		dot = React.createElement("Frame", {
			Size = UDim2.fromOffset(10, 10),
			Position = UDim2.fromOffset(0, 3),
			BackgroundColor3 = dotColour,
			BorderSizePixel = 0,
		}, {
			corner = React.createElement("UICorner", {
				CornerRadius = UDim.new(1, 0),
			}),
		}),
		label = React.createElement("TextLabel", {
			Size = UDim2.new(1, -18, 1, 0),
			Position = UDim2.fromOffset(18, 0),
			BackgroundTransparency = 1,
			Text = props.label,
			TextColor3 = theme.textSecondary,
			TextSize = 11,
			Font = Enum.Font.Jura,
			TextXAlignment = Enum.TextXAlignment.Left,
		}),
	})
end

return React.memo(StepRow)
