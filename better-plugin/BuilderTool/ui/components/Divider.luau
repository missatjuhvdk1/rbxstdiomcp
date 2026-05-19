--!strict
-- ui/components/Divider.luau
--
-- A thin separator (ARCHITECTURE §11). Function component, theme-driven, no
-- state. Mirrors the ResurfacePlugin toolbar divider between the tool group
-- and the settings group.

local React = require(script.Parent.Parent.Parent.Packages.React)
local useTheme = require(script.Parent.Parent.hooks.useTheme)

export type Props = {
	orientation: "vertical" | "horizontal",
	layoutOrder: number?,
}

local function Divider(props: Props): React.ReactNode
	local theme = useTheme()

	local size = if props.orientation == "vertical"
		then UDim2.new(0, 1, 0, 20)
		else UDim2.new(1, 0, 0, 1)

	return React.createElement("Frame", {
		BackgroundColor3 = theme.border,
		BackgroundTransparency = 0.4,
		BorderSizePixel = 0,
		Size = size,
		LayoutOrder = props.layoutOrder,
	})
end

return React.memo(Divider)
