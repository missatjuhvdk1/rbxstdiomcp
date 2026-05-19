--!strict
-- ui/RuntimeContext.luau
--
-- The React context that TRANSPORTS the one typed Context into the tree
-- (ARCHITECTURE §11). The React context is only a carrier; the typed object
-- is the source of truth. Components reach it via hooks/useRuntime, never by
-- importing Runtime directly.

local React = require(script.Parent.Parent.Packages.React)
local Runtime = require(script.Parent.Parent.runtime.Runtime)

export type Context = Runtime.Context

local RuntimeContext = React.createContext((nil :: any) :: Context)

return RuntimeContext
