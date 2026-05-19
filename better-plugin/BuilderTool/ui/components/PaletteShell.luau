--!strict
-- ui/components/PaletteShell.luau
--
-- Floating viewport widget (ARCHITECTURE §11). Fills the ScreenGui with a
-- transparent full-screen frame and positions the toolbar at the top-centre,
-- matching ResurfacePlugin's viewport widget pattern. Spring-animates alpha,
-- scale, and position when the plugin activates/deactivates.

local React = require(script.Parent.Parent.Parent.Packages.React)
local ReactSpring = require(script.Parent.Parent.Parent.Packages.ReactSpring)

local ToolPalette = require(script.Parent.ToolPalette)
local useRuntime = require(script.Parent.Parent.hooks.useRuntime)
local useSignal = require(script.Parent.Parent.hooks.useSignal)

local function PaletteShell(): React.ReactNode
	local ctx = useRuntime()

	local isActive = useSignal(ctx.plugin.activationChanged.Event, function(): boolean
		return ctx.plugin.plugin:IsActivated()
	end)

	local springs, api = ReactSpring.useSpring(function()
		return { alpha = 0 }
	end)

	React.useEffect(function()
		local easing = if isActive
			then ReactSpring.easings.easeOutBack
			else ReactSpring.easings.easeOutQuint
		api.start({
			alpha = if isActive then 1 else 0,
			config = { duration = 0.225, easing = easing },
		})
	end, { isActive } :: { any })

	return React.createElement("Frame", {
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
	}, {
		widget = React.createElement("Frame", {
			AnchorPoint = springs.alpha:map(function(a: number)
				return Vector2.new(0.5, 1 - a)
			end),
			AutomaticSize = Enum.AutomaticSize.XY,
			BackgroundTransparency = 1,
			Position = springs.alpha:map(function(a: number)
				return UDim2.new(0.5, 0, 0, 16 * a)
			end),
			Visible = springs.alpha:map(function(a: number)
				return a ~= 0
			end),
		}, {
			scale = React.createElement("UIScale", {
				Scale = springs.alpha:map(function(a: number)
					return 0.8 + 0.3 * a
				end),
			}),
			layout = React.createElement("UIListLayout", {
				HorizontalAlignment = Enum.HorizontalAlignment.Center,
				SortOrder = Enum.SortOrder.LayoutOrder,
				Padding = UDim.new(0, 4),
			}),
			toolbar = React.createElement(ToolPalette),
		}),
	})
end

return React.memo(PaletteShell)
