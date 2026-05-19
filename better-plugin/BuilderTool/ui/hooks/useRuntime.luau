--!strict
-- ui/hooks/useRuntime.luau
--
-- The ONLY way a component reaches services / tools / selection / settings
-- (ARCHITECTURE §11). Components never import runtime/ or domain/ directly
-- and never call game:GetService / ChangeHistoryService / workspace.

local React = require(script.Parent.Parent.Parent.Packages.React)
local RuntimeContext = require(script.Parent.Parent.RuntimeContext)

local function useRuntime(): RuntimeContext.Context
	return React.useContext(RuntimeContext)
end

return useRuntime
