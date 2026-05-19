--!strict
-- ui/hooks/useTheme.luau
--
-- Returns the fixed dark theme tokens (ARCHITECTURE §11). The palette is
-- constant, so this is a plain require-and-return — no Studio theme
-- subscription needed.

local Theme = require(script.Parent.Parent.theme.Theme)

local function useTheme(): Theme.Tokens
	return Theme.resolve()
end

return useTheme
