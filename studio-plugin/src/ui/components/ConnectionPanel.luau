--!strict
-- ui/components/ConnectionPanel.luau
--
-- The "Connection Settings" + Connect/Disconnect button. Replaces the
-- legacy [studio-plugin/plugin.luau L1389-1454] panel plus the
-- [L1576-1605] connect button. The two are merged into one section here
-- because they share state (the panel reads `ctx.settings:getServerUrl()`,
-- the button toggles `ctx.plugin.activationRequested` with the same URL
-- in flight) and giving them one parent simplifies the layout (one fixed
-- height, two children).
--
-- ============================================================================
-- WIRING
-- ============================================================================
-- - The TextBox shows the current persisted server URL (via useSignal on
--   ctx.settings.changed). On focus-lost it writes back via
--   ctx.settings:setServerUrl. We don't commit per-keystroke: half-typed
--   URLs are useless to persist, and the Polling loop would thrash a
--   per-character setting change.
-- - The button text + colour switch on isActive (via useSignal on
--   ctx.plugin.activationChanged.Event). Click fires
--   ctx.plugin.activationRequested.
--
-- The component owns no business logic — every state read is a signal
-- subscription, every state write goes through a typed setter or the
-- activation BindableEvent. ChangeHistoryService is never touched here.

local React = require(script.Parent.Parent.Parent.Packages.React)
local useRuntime = require(script.Parent.Parent.hooks.useRuntime)
local useSignal = require(script.Parent.Parent.hooks.useSignal)
local useTheme = require(script.Parent.Parent.hooks.useTheme)

export type Props = {
	layoutOrder: number?,
}

local function ConnectionPanel(props: Props): React.ReactNode
	local theme = useTheme()
	local ctx = useRuntime()

	-- Reactive reads. The Settings module fires `changed` after any setter
	-- mutates state, so the input stays in sync if a future panel (or a
	-- future setting-restore-on-corruption migration) ever rewrites it.
	local serverUrl = useSignal(ctx.settings.changed, function(): string
		return ctx.settings:getServerUrl()
	end)

	local isActive = useSignal(ctx.plugin.activationChanged.Event, function(): boolean
		return ctx.polling:isActive()
	end)

	-- Local edit buffer: we don't write through to settings on every
	-- keystroke. The buffer is hydrated from the persisted URL whenever
	-- the persisted value changes (a different module updates settings,
	-- a setting reload, etc.) so the input never drifts out of sync.
	local buffer, setBuffer = React.useState(serverUrl)
	React.useEffect(function()
		setBuffer(serverUrl)
	end, { serverUrl } :: { any })

	local function commitBuffer(newValue: string)
		-- Settings.setServerUrl trims trailing slashes etc. — we just hand
		-- off the raw string and let the runtime layer normalise.
		if newValue ~= serverUrl then
			ctx.settings:setServerUrl(newValue)
		end
	end

	local buttonColour = if isActive then theme.accentDisconnect else theme.accentConnect
	local buttonText = if isActive then "Disconnect" else "Connect"

	return React.createElement("Frame", {
		Size = UDim2.new(1, 0, 0, 110 + 12 + 48), -- panel + padding + button
		BackgroundTransparency = 1,
		LayoutOrder = props.layoutOrder,
	}, {
		layout = React.createElement("UIListLayout", {
			Padding = UDim.new(0, 12),
			SortOrder = Enum.SortOrder.LayoutOrder,
		}),

		settingsPanel = React.createElement("Frame", {
			Size = UDim2.new(1, 0, 0, 110),
			BackgroundColor3 = theme.surface,
			BorderSizePixel = 0,
			LayoutOrder = 1,
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
				Text = "Connection Settings",
				TextColor3 = theme.textPrimary,
				TextSize = 14,
				Font = Enum.Font.Jura,
				TextXAlignment = Enum.TextXAlignment.Left,
			}),

			urlLabel = React.createElement("TextLabel", {
				Size = UDim2.new(1, 0, 0, 16),
				Position = UDim2.fromOffset(0, 30),
				BackgroundTransparency = 1,
				Text = "Server URL",
				TextColor3 = theme.textMuted,
				TextSize = 12,
				Font = Enum.Font.Jura,
				TextXAlignment = Enum.TextXAlignment.Left,
			}),

			urlInput = React.createElement("TextBox", {
				Size = UDim2.new(1, 0, 0, 32),
				Position = UDim2.fromOffset(0, 50),
				BackgroundColor3 = theme.surfaceVariant,
				BorderSizePixel = 1,
				BorderColor3 = theme.inputBorder,
				Text = buffer,
				TextColor3 = theme.textPrimary,
				TextSize = 12,
				Font = Enum.Font.Jura,
				ClearTextOnFocus = false,
				PlaceholderText = "Enter server URL...",
				PlaceholderColor3 = theme.textHint,
				TextXAlignment = Enum.TextXAlignment.Left,
				[React.Change.Text] = function(rbx: TextBox)
					setBuffer(rbx.Text)
				end,
				[React.Event.FocusLost] = function(rbx: TextBox, enterPressed: boolean)
					-- Commit only on enter or focus-lost (the standard
					-- Roblox "I'm done editing" idiom). We DON'T commit
					-- on every keystroke (half-typed URLs are not a
					-- useful persisted state) but we DO accept either
					-- finishing path so a user who tabs away gets their
					-- change saved.
					local _ = enterPressed
					commitBuffer(rbx.Text)
				end,
			}, {
				corner = React.createElement("UICorner", {
					CornerRadius = theme.cornerRadiusInput,
				}),
				padding = React.createElement("UIPadding", {
					PaddingLeft = UDim.new(0, 12),
					PaddingRight = UDim.new(0, 12),
				}),
			}),
		}),

		connectButton = React.createElement("TextButton", {
			AutoButtonColor = false, -- we paint our own hover state
			Size = UDim2.new(1, 0, 0, 48),
			BackgroundColor3 = buttonColour,
			BorderSizePixel = 0,
			Text = buttonText,
			TextColor3 = theme.textPrimary,
			TextSize = 16,
			Font = Enum.Font.Jura,
			LayoutOrder = 2,
			[React.Event.Activated] = function()
				-- The bootstrap owns the activation state machine; the UI
				-- just expresses intent through this BindableEvent. The
				-- bootstrap's listener does the actual ctx.polling:start /
				-- :stop call plus the /ready or /disconnect POST.
				ctx.plugin.activationRequested:Fire(not isActive)
			end,
		}, {
			corner = React.createElement("UICorner", {
				CornerRadius = theme.cornerRadiusButton,
			}),
		}),
	})
end

return React.memo(ConnectionPanel)
