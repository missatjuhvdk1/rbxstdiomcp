--!strict
-- ui/App.luau
--
-- Root React component (ARCHITECTURE §11). The job is small but precise:
-- transport the one typed Context into the React tree via RuntimeContext.Provider
-- then render the dock shell. Owns no state itself — the components below it
-- reach into Context via useRuntime() and subscribe to signals via useSignal().
--
-- Why this file is tiny:
--   - State lives next to the producer (Runtime), not in the root component.
--   - Composition stays in DockShell (which IS the visual root); App is the
--     IO boundary between bootstrap and tree.
--   - Keeping App.luau a pure transport means swapping shells in tests is a
--     one-line change: `React.createElement(TestShell)` instead of DockShell.
--
-- Mirrors BuilderTool/ui/App.luau (same RuntimeContext-as-carrier pattern,
-- different shell). See ARCHITECTURE §11 "React context is only a carrier".

local React = require(script.Parent.Parent.Packages.React)
local RuntimeContext = require(script.Parent.RuntimeContext)
local DockShell = require(script.Parent.components.DockShell)

export type Props = {
	context: RuntimeContext.Context,
}

local function App(props: Props): React.ReactNode
	return React.createElement(RuntimeContext.Provider, {
		value = props.context,
	}, {
		shell = React.createElement(DockShell),
	})
end

return App
