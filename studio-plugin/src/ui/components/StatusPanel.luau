--!strict
-- ui/components/StatusPanel.luau
--
-- The "Connection Status" panel. Replaces the legacy [studio-plugin/plugin.luau
-- L1456-1574] block. Shows:
--
--   - A prominent headline ("Connected", "Server unavailable", "Retrying in
--     ~3s...") coloured by state.
--   - A small HTTP/MCP indicator row.
--   - Three step rows (StepRow) — HTTP reachable, MCP bridge connected,
--     ready for commands.
--   - A troubleshoot tip that only appears after 8s of HTTP-OK-but-MCP-DOWN
--     (see useStatus for the timer logic).
--
-- All state comes from useStatus (which subscribes to ctx.polling under the
-- hood). The component itself is stateless.

local React = require(script.Parent.Parent.Parent.Packages.React)
local Theme = require(script.Parent.Parent.theme.Theme)
local useStatus = require(script.Parent.Parent.hooks.useStatus)
local useTheme = require(script.Parent.Parent.hooks.useTheme)
local StepRow = require(script.Parent.StepRow)

export type Props = {
	layoutOrder: number?,
}

local function headlineColour(theme: Theme.Tokens, state: "connected" | "waiting" | "error" | "idle"): Color3
	if state == "connected" then
		return theme.stateConnected
	elseif state == "waiting" then
		return theme.stateWaiting
	elseif state == "error" then
		return theme.stateError
	else
		return theme.accentDisconnect
	end
end

local function detailText(httpOk: boolean, mcpConnected: boolean): string
	-- The legacy panel showed "HTTP: X  MCP: X" with check/cross glyphs as
	-- characters. We keep the format but use plain ✓/✗ — render font (Jura)
	-- supports them and they survive copy-paste in case a user grabs the
	-- text for a bug report.
	local httpMark = if httpOk then "✓" else "✗"
	local mcpMark = if mcpConnected then "✓" else "✗"
	return string.format("HTTP: %s  MCP: %s", httpMark, mcpMark)
end

local function StatusPanel(props: Props): React.ReactNode
	local theme = useTheme()
	local status = useStatus()

	-- Map each of the three steps to its StepRow state. The rules mirror
	-- legacy plugin.luau L1880-L1900 — HTTP/MCP/ready in cascading order,
	-- so a later step never goes "ok" before an earlier one is.
	local step1State: StepRow.StepState
	local step2State: StepRow.StepState
	local step3State: StepRow.StepState

	if status.headlineState == "error" then
		step1State = "error"
		step2State = "error"
		step3State = "error"
	else
		step1State = if status.httpOk then "ok" else "waiting"
		step2State = if status.mcpConnected then "ok" elseif status.httpOk then "waiting" else "idle"
		step3State = if status.isReady then "ok" elseif status.mcpConnected then "waiting" else "idle"
	end

	return React.createElement("Frame", {
		Size = UDim2.new(1, 0, 0, 170),
		BackgroundColor3 = theme.surface,
		BorderSizePixel = 0,
		LayoutOrder = props.layoutOrder,
	}, {
		corner = React.createElement("UICorner", {
			CornerRadius = theme.cornerRadiusPanel,
		}),
		padding = React.createElement("UIPadding", {
			PaddingTop = UDim.new(0, theme.padding),
			PaddingBottom = UDim.new(0, theme.padding),
			PaddingLeft = UDim.new(0, theme.padding),
			PaddingRight = UDim.new(0, theme.padding),
		}),

		title = React.createElement("TextLabel", {
			Size = UDim2.new(1, 0, 0, 20),
			Position = UDim2.fromOffset(0, 0),
			BackgroundTransparency = 1,
			Text = "Connection Status",
			TextColor3 = theme.textPrimary,
			TextSize = 14,
			Font = Enum.Font.Jura,
			TextXAlignment = Enum.TextXAlignment.Left,
		}),

		headline = React.createElement("TextLabel", {
			Size = UDim2.new(1, 0, 0, 20),
			Position = UDim2.fromOffset(0, 30),
			BackgroundTransparency = 1,
			Text = status.headline,
			TextColor3 = headlineColour(theme, status.headlineState),
			TextSize = 13,
			Font = Enum.Font.Jura,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextWrapped = true,
		}),

		detail = React.createElement("TextLabel", {
			Size = UDim2.new(1, 0, 0, 12),
			Position = UDim2.fromOffset(0, 50),
			BackgroundTransparency = 1,
			Text = detailText(status.httpOk, status.mcpConnected),
			TextColor3 = theme.textMuted,
			TextSize = 10,
			Font = Enum.Font.Jura,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextWrapped = true,
		}),

		steps = React.createElement("Frame", {
			Size = UDim2.new(1, 0, 0, 60),
			Position = UDim2.fromOffset(0, 68),
			BackgroundTransparency = 1,
		}, {
			layout = React.createElement("UIListLayout", {
				Padding = UDim.new(0, 6),
				FillDirection = Enum.FillDirection.Vertical,
				SortOrder = Enum.SortOrder.LayoutOrder,
			}),
			step1 = React.createElement(StepRow, {
				label = "1. HTTP server reachable",
				state = step1State,
				layoutOrder = 1,
			}),
			step2 = React.createElement(StepRow, {
				label = "2. MCP bridge connected",
				state = step2State,
				layoutOrder = 2,
			}),
			step3 = React.createElement(StepRow, {
				label = "3. Ready for commands",
				state = step3State,
				layoutOrder = 3,
			}),
		}),

		-- Troubleshoot tip — only mounted when needed so a screen-reader
		-- isn't reading a visually-hidden Visible=false node.
		troubleshoot = status.shouldShowTroubleshoot and React.createElement("TextLabel", {
			Size = UDim2.new(1, 0, 0, 40),
			Position = UDim2.fromOffset(0, 130),
			BackgroundTransparency = 1,
			TextWrapped = true,
			Text = "HTTP is OK but MCP isn't responding. Close all node.exe in Task Manager and restart the server.",
			TextColor3 = theme.troubleshoot,
			TextSize = 11,
			Font = Enum.Font.Jura,
			TextXAlignment = Enum.TextXAlignment.Left,
		}) or nil,
	})
end

return React.memo(StatusPanel)
