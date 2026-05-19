--!strict
-- ui/App.luau
--
-- Root React component (ARCHITECTURE §11). Provides the one typed Context to
-- the tree via RuntimeContext, then renders the shell (background + palette).
-- Owns no state itself — it is pure transport + composition.

local React = require(script.Parent.Parent.Packages.React)
local RuntimeContext = require(script.Parent.RuntimeContext)
local PaletteShell = require(script.Parent.components.PaletteShell)

export type Props = {
	context: RuntimeContext.Context,
}

local function App(props: Props): React.ReactNode
	return React.createElement(RuntimeContext.Provider, {
		value = props.context,
	}, {
		shell = React.createElement(PaletteShell),
	})
end

return App
