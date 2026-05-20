--!strict
-- ui/components/Header.luau
--
-- The 60px-tall blue→purple gradient banner at the top of the dock widget.
-- Replaces the legacy [studio-plugin/plugin.luau L1283-1371] block. Shows:
--
--   - The "MCP Server" title (Jura 18, left-aligned)
--   - The "AI Integration • v<version>" subtitle (Jura 12, left, blue-200)
--   - A pulsing status dot on the right with a small OFFLINE/WAITING/READY
--     caption beneath it
--
-- Reads connection state via the useStatus hook (which subscribes to the
-- polling status signal under the hood). Plugin version comes from the
-- typed Constants via useRuntime() — no string literals in the UI.

local React = require(script.Parent.Parent.Parent.Packages.React)
local Theme = require(script.Parent.Parent.theme.Theme)
local useRuntime = require(script.Parent.Parent.hooks.useRuntime)
local useStatus = require(script.Parent.Parent.hooks.useStatus)
local useTheme = require(script.Parent.Parent.hooks.useTheme)
local PulseDot = require(script.Parent.PulseDot)

export type Props = {
	layoutOrder: number?,
}

local function dotColourAndCaption(theme: Theme.Tokens, status: useStatus.DerivedStatus): (Color3, string, boolean)
	-- Return (colour, caption, shouldPulse). The caption matches the
	-- legacy mini-label below the dot (legacy L1361-1370). We expose a
	-- richer set of captions than v2 (which only had OFFLINE/ONLINE) so
	-- the WAITING and RETRYING states are visible without expanding the
	-- panel below.
	if status.headlineState == "connected" then
		return theme.stateConnected, "ONLINE", true
	elseif status.headlineState == "waiting" then
		return theme.stateWaiting, "WAITING", true
	elseif status.headlineState == "error" then
		return theme.stateError, "ERROR", false
	else
		return theme.stateError, "OFFLINE", false
	end
end

local function Header(props: Props): React.ReactNode
	local theme = useTheme()
	local ctx = useRuntime()
	local status = useStatus()

	local dotColour, caption, shouldPulse = dotColourAndCaption(theme, status)

	return React.createElement("Frame", {
		Size = UDim2.new(1, 0, 0, 60),
		BackgroundColor3 = theme.headerStart,
		BorderSizePixel = 0,
		LayoutOrder = props.layoutOrder,
	}, {
		corner = React.createElement("UICorner", {
			CornerRadius = theme.cornerRadiusPanel,
		}),
		gradient = React.createElement("UIGradient", {
			Color = ColorSequence.new({
				ColorSequenceKeypoint.new(0, theme.headerStart),
				ColorSequenceKeypoint.new(1, theme.headerEnd),
			}),
			Rotation = 45,
		}),

		titleContainer = React.createElement("Frame", {
			Size = UDim2.new(1, -70, 1, 0),
			Position = UDim2.fromOffset(15, 0),
			BackgroundTransparency = 1,
		}, {
			title = React.createElement("TextLabel", {
				Size = UDim2.new(1, 0, 0, 28),
				Position = UDim2.fromOffset(0, 8),
				BackgroundTransparency = 1,
				Text = "MCP Server",
				TextColor3 = theme.textPrimary,
				TextSize = 18,
				Font = Enum.Font.Jura,
				TextXAlignment = Enum.TextXAlignment.Left,
			}),
			subtitle = React.createElement("TextLabel", {
				Size = UDim2.new(1, 0, 0, 16),
				Position = UDim2.fromOffset(0, 32),
				BackgroundTransparency = 1,
				Text = "AI Integration • v" .. ctx.constants.PLUGIN_VERSION,
				TextColor3 = theme.textBlueSubtle,
				TextSize = 12,
				Font = Enum.Font.Jura,
				TextXAlignment = Enum.TextXAlignment.Left,
			}),
		}),

		statusContainer = React.createElement("Frame", {
			AnchorPoint = Vector2.new(1, 0),
			Size = UDim2.fromOffset(50, 40),
			Position = UDim2.new(1, -10, 0, 10),
			BackgroundTransparency = 1,
		}, {
			dotWrapper = React.createElement("Frame", {
				Size = UDim2.fromOffset(16, 16),
				Position = UDim2.fromOffset(17, 5),
				BackgroundTransparency = 1,
			}, {
				dot = React.createElement(PulseDot, {
					pulsing = shouldPulse,
					colour = dotColour,
				}),
			}),
			caption = React.createElement("TextLabel", {
				Size = UDim2.fromOffset(50, 12),
				Position = UDim2.fromOffset(0, 24),
				BackgroundTransparency = 1,
				Text = caption,
				TextColor3 = theme.textPrimary,
				TextSize = 8,
				Font = Enum.Font.Jura,
				TextXAlignment = Enum.TextXAlignment.Center,
			}),
		}),
	})
end

return React.memo(Header)
