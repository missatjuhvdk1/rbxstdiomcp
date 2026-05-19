--!strict
-- ui/hooks/useTheme.luau
--
-- Returns the resolved theme tokens (ARCHITECTURE §11). Today the palette
-- is fixed (see ui/theme/Theme.luau header for the legacy-parity rationale)
-- so this is a plain require-and-return. When we eventually follow the
-- Studio theme, this hook becomes the subscription seam:
--
--   local services = useRuntime().services
--   useSignal(services.studioService:GetPropertyChangedSignal("Theme"), …)
--
-- All call sites stay `local theme = useTheme()` — that's the point.

local Theme = require(script.Parent.Parent.theme.Theme)

local function useTheme(): Theme.Tokens
	return Theme.resolve()
end

return useTheme
