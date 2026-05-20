--!strict
-- ui/RuntimeContext.luau
--
-- The React context that TRANSPORTS the one typed runtime Context into the
-- tree (ARCHITECTURE §11). The React context is only a carrier; the typed
-- `Runtime.Context` object is the source of truth. Components reach it via
-- `ui/hooks/useRuntime`, never by `require`ing `runtime/Runtime` directly —
-- doing so would create the layer violation `ui → runtime/Runtime` which the
-- CI gate's `checkLayerInvariant` would still allow (because runtime is below
-- ui) but which defeats the test-seam intent of routing everything through
-- the Context bag.
--
-- The default `nil :: any :: Context` is a deliberate footgun: if a component
-- renders OUTSIDE a `<RuntimeContext.Provider>` (e.g. someone forgot to wrap
-- the App tree in `Plugin.client.luau`), the first hook call will NPE on a
-- nil field. That's louder than silently propagating defaults and faster to
-- find than chasing rendering bugs through a tree with stale state.

local React = require(script.Parent.Parent.Packages.React)
local Runtime = require(script.Parent.Parent.runtime.Runtime)

export type Context = Runtime.Context

local RuntimeContext = React.createContext((nil :: any) :: Context)

return RuntimeContext
