--!strict
-- ui/components/ToolOptionsPanel.luau
--
-- Per-tool options bar. Reads the active tool's `options` descriptor and
-- renders controls in a horizontal bar below the toolbar. No business logic;
-- dispatches ctx.settings:setToolOption() on change.

local React = require(script.Parent.Parent.Parent.Packages.React)

local Button = require(script.Parent.Button)
local Divider = require(script.Parent.Divider)
local useRuntime = require(script.Parent.Parent.hooks.useRuntime)
local useTheme = require(script.Parent.Parent.hooks.useTheme)

export type Props = {}

type PanelState = {
	toolId: string?,
	options: { any },
	values: { [string]: any },
}

-- ── NumberOption ──────────────────────────────────────────────────────────────
-- Extracted into its own component so it can hold text-editing state (hooks
-- cannot be called inside a loop in the parent).

type NumberOptionProps = {
	toolId:      string,
	optKey:      string,
	opt:         any,
	val:         number,
	layoutOrder: number,
}

local function NumberOption(props: NumberOptionProps): React.ReactNode
	local ctx   = useRuntime()
	local theme = useTheme()

	local toolId = props.toolId
	local optKey = props.optKey
	local opt    = props.opt
	local val    = props.val
	local step   = (opt.step or 1)         :: number
	local minVal = (opt.min  or 0)         :: number
	local maxVal = (opt.max  or math.huge) :: number

	-- committed: local copy of the saved value, updated immediately on +/-
	-- so buttons respond without waiting for settings.changed to round-trip.
	local committed, setCommitted = React.useState(val)

	-- Sync when val changes from an external source (e.g. tool switch).
	React.useEffect(function()
		setCommitted(val)
	end, { val } :: { any })

	local function apply(n: number)
		local clamped = math.clamp(n, minVal, maxVal)
		ctx.settings:setToolOption(toolId, optKey, clamped)
		setCommitted(clamped)
	end

	-- Compact arrow button for the stacked spinner.
	local function arrowBtn(sym: string, order: number, delta: number): React.ReactNode
		return React.createElement("TextButton", {
			AutomaticSize    = Enum.AutomaticSize.XY,
			BackgroundColor3 = theme.button,
			BorderSizePixel  = 0,
			Text             = sym,
			TextColor3       = theme.textPrimary,
			TextSize         = 11,
			FontFace         = Font.new(
				"rbxasset://fonts/families/BuilderSans.json",
				Enum.FontWeight.Bold
			),
			LayoutOrder      = order,
			[React.Event.Activated] = function()
				apply(committed + delta)
			end,
		}, {
			corner  = React.createElement("UICorner", { CornerRadius = theme.cornerRadius }),
			stroke  = React.createElement("UIStroke", {
				ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
				Color           = theme.buttonBorder,
				Thickness       = 1,
			}),
			padding = React.createElement("UIPadding", {
				PaddingTop    = UDim.new(0, 3),
				PaddingBottom = UDim.new(0, 3),
				PaddingLeft   = UDim.new(0, 7),
				PaddingRight  = UDim.new(0, 7),
			}),
		})
	end

	-- The TextBox key encodes the committed value so that when committed changes
	-- (via +/- or after a successful manual entry) React unmounts the old TextBox
	-- and mounts a fresh one. This eliminates the controlled-input problem: React
	-- never tries to reconcile Text against a box the user is mid-editing.
	local displayText = string.format("%g", committed)

	return React.createElement("Frame", {
		AutomaticSize          = Enum.AutomaticSize.XY,
		BackgroundTransparency = 1,
		LayoutOrder            = props.layoutOrder,
	}, {
		layout = React.createElement("UIListLayout", {
			FillDirection     = Enum.FillDirection.Horizontal,
			VerticalAlignment = Enum.VerticalAlignment.Center,
			SortOrder         = Enum.SortOrder.LayoutOrder,
			Padding           = UDim.new(0, 4),
		}),
		-- icon placeholder: swap Frame for ImageLabel once an icon library exists
		icon = React.createElement("Frame", {
			Size                   = UDim2.fromOffset(16, 16),
			BackgroundTransparency = 1,
			LayoutOrder            = 0,
		}),
		field = React.createElement("Frame", {
			AutomaticSize    = Enum.AutomaticSize.XY,
			BackgroundColor3 = theme.button,
			BorderSizePixel  = 0,
			LayoutOrder      = 1,
		}, {
			corner  = React.createElement("UICorner", { CornerRadius = theme.cornerRadius }),
			stroke  = React.createElement("UIStroke", {
				ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
				Color           = theme.buttonBorder,
				Thickness       = 1,
			}),
			padding = React.createElement("UIPadding", {
				PaddingTop    = UDim.new(0, theme.spacing),
				PaddingBottom = UDim.new(0, theme.spacing),
				PaddingLeft   = UDim.new(0, theme.spacing),
				PaddingRight  = UDim.new(0, theme.spacing),
			}),
			[displayText] = React.createElement("TextBox", {
				AutomaticSize          = Enum.AutomaticSize.XY,
				BackgroundTransparency = 1,
				Text                   = displayText,
				TextColor3             = theme.textPrimary,
				TextSize               = theme.textSize,
				FontFace               = Font.new(
					"rbxasset://fonts/families/BuilderSans.json",
					Enum.FontWeight.SemiBold
				),
				ClearTextOnFocus       = false,
				[React.Event.Focused] = function(rbx)
					rbx.Text = ""
				end,
				-- Enter: trigger FocusLost (may not auto-fire in CoreGui plugin mode).
				[React.Event.InputBegan] = function(rbx, input: InputObject)
					if input.KeyCode == Enum.KeyCode.Return
						or input.KeyCode == Enum.KeyCode.KeypadEnter
					then
						rbx:ReleaseFocus()
					end
				end,
				[React.Event.FocusLost] = function(rbx)
					local text = (rbx.Text :: string):gsub(",", ".")
					local n    = tonumber(text)
					if n then
						local clamped = math.clamp(n, minVal, maxVal)
						if clamped ~= committed then
							apply(n)   -- different value → key changes → remount
						else
							rbx.Text = displayText  -- already at boundary, reset display
						end
					else
						rbx.Text = displayText
					end
				end,
				[React.Change.Text] = function(rbx)
					local cleaned = (rbx.Text :: string):gsub("[^%d%.%,]", "")
					if cleaned ~= rbx.Text then rbx.Text = cleaned end
				end,
			}, {
				minWidth = React.createElement("UISizeConstraint", {
					MinSize = Vector2.new(48, 0),
				}),
			}),
		}),
		arrows = React.createElement("Frame", {
			AutomaticSize          = Enum.AutomaticSize.XY,
			BackgroundTransparency = 1,
			LayoutOrder            = 2,
		}, {
			layout = React.createElement("UIListLayout", {
				FillDirection       = Enum.FillDirection.Vertical,
				HorizontalAlignment = Enum.HorizontalAlignment.Center,
				SortOrder           = Enum.SortOrder.LayoutOrder,
				Padding             = UDim.new(0, 2),
			}),
			up   = arrowBtn("+", 0,  step),
			down = arrowBtn("−", 1, -step),
		}),
	})
end

-- ── ToolOptionsPanel ───────────────────────────────────────────────────────────

local function ToolOptionsPanel(_props: Props): React.ReactNode
	local ctx = useRuntime()
	local theme = useTheme()

	local function computeState(): PanelState
		local active = ctx.tools:getActive()
		if active == nil then
			return { toolId = nil, options = {}, values = {} }
		end
		local opts: { any } = (active.options :: any) or {}
		if #opts == 0 then
			return { toolId = nil, options = {}, values = {} }
		end
		local vals: { [string]: any } = {}
		for _, opt in opts do
			local o = opt :: any
			vals[o.key] = ctx.settings:getToolOption(active.id, o.key, o.default)
		end
		return { toolId = active.id, options = opts, values = vals }
	end

	local state, setState = React.useState(computeState())

	React.useEffect(function()
		local function update()
			setState(computeState())
		end
		local c1 = ctx.tools.changed:Connect(update)
		local c2 = ctx.settings.changed:Connect(update)
		return function()
			c1:Disconnect()
			c2:Disconnect()
		end
	end, {} :: { any })

	if state.toolId == nil or #state.options == 0 then
		return nil
	end

	local barCorner = UDim.new(0, theme.cornerRadius.Offset + theme.spacing)

	local children: { [string]: React.ReactNode } = {
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
			PaddingRight = UDim.new(0, math.floor(theme.spacing * 1.5)),
		}),
		corner = React.createElement("UICorner", {
			CornerRadius = barCorner,
		}),
	}

	local layoutOrder = 0
	for i, rawOpt in state.options do
		local opt = rawOpt :: any
		local key: string = opt.key
		local kind: string = opt.kind
		local toolId = state.toolId :: string

		if i > 1 then
			layoutOrder += 1
			children["div_" .. key] = React.createElement(Divider, {
				orientation = "vertical",
				layoutOrder = layoutOrder,
			})
		end

		layoutOrder += 1
		local order = layoutOrder

		if kind == "number" then
			local val = ((state.values[key] :: any) or opt.default) :: number

			children["opt_" .. key] = React.createElement(NumberOption, {
				toolId      = toolId,
				optKey      = key,
				opt         = opt,
				val         = val,
				layoutOrder = order,
			})

		elseif kind == "enum" then
			local val = ((state.values[key] :: any) or opt.default) :: string
			local choices: { string } = opt.choices

			local choiceChildren: { [string]: React.ReactNode } = {
				layout = React.createElement("UIListLayout", {
					FillDirection = Enum.FillDirection.Horizontal,
					VerticalAlignment = Enum.VerticalAlignment.Center,
					SortOrder = Enum.SortOrder.LayoutOrder,
					Padding = UDim.new(0, 4),
				}),
			}
			for j, choice in choices do
				local c = choice
				choiceChildren["choice_" .. c] = React.createElement(Button, {
					text = c,
					selected = val == c,
					layoutOrder = j,
					onClick = function()
						ctx.settings:setToolOption(toolId, key, c)
					end,
				})
			end

			children["opt_" .. key] = React.createElement("Frame", {
				AutomaticSize = Enum.AutomaticSize.XY,
				BackgroundTransparency = 1,
				LayoutOrder = order,
			}, choiceChildren)

		elseif kind == "toggle" then
			local val = (state.values[key] :: any) == true
			local label: string = opt.label

			children["opt_" .. key] = React.createElement(Button, {
				text = label,
				selected = val,
				layoutOrder = order,
				onClick = function()
					ctx.settings:setToolOption(toolId, key, not val)
				end,
			})
		end
	end

	return React.createElement("Frame", {
		AutomaticSize = Enum.AutomaticSize.XY,
		BackgroundColor3 = theme.surface,
		BackgroundTransparency = theme.surfaceTransparency,
		BorderSizePixel = 0,
		Size = UDim2.fromOffset(0, 0),
		LayoutOrder = 1,
	}, children)
end

return React.memo(ToolOptionsPanel)
