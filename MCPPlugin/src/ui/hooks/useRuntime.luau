--!strict
-- ui/hooks/useRuntime.luau
--
-- The ONLY way a component reaches services / settings / polling / dispatcher
-- (ARCHITECTURE §11). Components never `require` anything from `runtime/` or
-- `domain/` directly. They never call `game:GetService` (banned outright by
-- the CI gate's service-quarantine rule), never construct a HistoryService
-- recording, never POST JSON. Every side effect flows through the typed bag
-- this hook returns.

local React = require(script.Parent.Parent.Parent.Packages.React)
local RuntimeContext = require(script.Parent.Parent.RuntimeContext)

local function useRuntime(): RuntimeContext.Context
	return React.useContext(RuntimeContext)
end

return useRuntime
