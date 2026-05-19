--!strict
-- ui/theme/Theme.luau
--
-- Fixed dark palette (ARCHITECTURE §11). The toolbar floats over the 3D
-- viewport so it is always dark, regardless of the Studio editor theme.
-- Components reference token names, never raw Color3 literals.

export type Tokens = {
	-- surfaces
	background: Color3,
	surface: Color3,
	surfaceTransparency: number,
	-- text
	textPrimary: Color3,
	textSecondary: Color3,
	-- accent (selected state)
	accent: Color3,
	onAccent: Color3,
	-- button states
	button: Color3,
	buttonHovered: Color3,
	buttonPressed: Color3,
	buttonBorder: Color3,
	-- divider / stroke
	border: Color3,
	-- layout
	spacing: number,
	cornerRadius: UDim,
	textSize: number,
}

local Theme = {}

function Theme.resolve(): Tokens
	return {
		background = Color3.new(0, 0, 0),
		surface = Color3.new(0, 0, 0),
		surfaceTransparency = 0.1,

		textPrimary = Color3.fromHex("d3d3d3"),
		textSecondary = Color3.fromHex("afafaf"),

		accent = Color3.fromHex("ffdf35"),
		onAccent = Color3.new(0, 0, 0),

		button = Color3.fromHex("3c3c3c"),
		buttonHovered = Color3.fromHex("4a4a4a"),
		buttonPressed = Color3.fromHex("1e1e1e"),
		buttonBorder = Color3.fromHex("2e2e2e"),

		border = Color3.fromHex("2e2e2e"),

		spacing = 8,
		cornerRadius = UDim.new(0, 5),
		textSize = 16,
	}
end

return Theme
