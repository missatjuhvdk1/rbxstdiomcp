--!strict
-- ui/theme/Theme.luau
--
-- Semantic UI tokens (ARCHITECTURE §11). One frozen palette per resolve().
-- Components reference token names, never raw Color3 literals. The CI gate
-- doesn't enforce that mechanically yet, but the convention is: if you find
-- yourself typing Color3.fromRGB inside a component, the colour belongs HERE
-- with a name describing what it MEANS, not what it LOOKS like.
--
-- ============================================================================
-- WHY FIXED-DARK INSTEAD OF FOLLOWS-STUDIO-THEME
-- ============================================================================
-- The legacy v2.0.0 widget ([studio-plugin/plugin.luau L1283-1638]) hard-coded
-- a single dark palette regardless of Studio's editor theme — the gradient
-- header, the slate panels, the indigo accents stayed the same in Studio's
-- light theme too. Phase 6's verification gate explicitly asks for visual
-- parity with v2.0.0, so this module ships the same fixed palette.
--
-- ARCHITECTURE §11 documents the eventual goal of following the Studio theme
-- via StudioService. That is a future iteration: when we do it, this module
-- is the single point of change. The seam:
--
--   1. Theme.resolve() becomes Theme.resolve(studioService): the function
--      reads studioService.Theme and switches between dark/light token sets.
--   2. ui/hooks/useTheme.luau wraps useSignal(studioService:GetPropertyChangedSignal("Theme"))
--      and re-resolves on theme change.
--   3. Components keep their `local theme = useTheme()` line; the rest of
--      the change is invisible to them.
--
-- That's a Phase-7+ task. Today, useTheme() returns the frozen dark set.
--
-- ============================================================================
-- HOW THE LEGACY COLOURS MAP TO SEMANTIC TOKENS
-- ============================================================================
--   surface          = #1F2937 (slate-800)   — panel backgrounds, legacy L1391
--   surfaceVariant   = #374151 (slate-700)   — TextBox background, legacy L1434
--   border           = #6366F1 (indigo-500)  — input border, legacy L1436
--   headerStart      = #3B82F6 (blue-500)    — gradient start, legacy L1286/1296
--   headerEnd        = #9333EA (purple-600)  — gradient end, legacy L1297
--   textPrimary      = #FFFFFF               — headings, legacy L1313/1412
--   textSecondary    = #D1D5DB (gray-300)    — step labels, legacy L1546
--   textMuted        = #9CA3AF (gray-400)    — secondary labels, legacy L1424
--   textHint         = #6B7280 (gray-500)    — placeholder text, legacy L1444
--   textBlueSubtle   = #BFDBFE (blue-200)    — version subtitle, legacy L1325
--   accentConnect    = #10B981 (emerald-500) — connect button bg, legacy L1578
--   accentConnectHi  = #059669 (emerald-600) — connect button hover, legacy L1599
--   accentDisconnect = #EF4444 (red-500)     — disconnect / offline dot, legacy L1341/1604
--   accentDisconnectHi = #DC2626 (red-600)   — disconnect hover, legacy L1599
--   stateConnected   = #10B981 (emerald-500) — green step dot
--   stateWaiting     = #F59E0B (amber-500)   — amber step dot, legacy L1569
--   stateError       = #EF4444 (red-500)     — red step dot
--   stateIdle        = #9CA3AF (gray-400)    — neutral step dot, legacy L1533
--   scrollbar        = #6366F1 (indigo-500)  — scrollbar tint, legacy L1379

export type Tokens = {
	-- Surfaces
	background: Color3,
	surface: Color3,
	surfaceVariant: Color3,

	-- Header gradient
	headerStart: Color3,
	headerEnd: Color3,

	-- Text
	textPrimary: Color3,
	textSecondary: Color3,
	textMuted: Color3,
	textHint: Color3,
	textBlueSubtle: Color3,

	-- Accents (connect button + status dot)
	accentConnect: Color3,
	accentConnectHover: Color3,
	accentDisconnect: Color3,
	accentDisconnectHover: Color3,

	-- Status-state colours (step dots, status label, troubleshooting note)
	stateConnected: Color3,
	stateWaiting: Color3,
	stateError: Color3,
	stateIdle: Color3,
	troubleshoot: Color3,

	-- Borders / lines
	border: Color3,
	inputBorder: Color3,

	-- Misc
	scrollbar: Color3,

	-- Layout numbers (kept here so spacing tweaks are one diff, one file)
	padding: number,
	cornerRadiusPanel: UDim,
	cornerRadiusInput: UDim,
	cornerRadiusButton: UDim,
}

local Theme = {}

-- A single frozen instance reused per resolve. Freezing makes accidental
-- mutation by a component a hard error rather than a silent corruption of
-- the palette for every other component.
local TOKENS: Tokens = table.freeze({
	background = Color3.fromRGB(17, 24, 39),
	surface = Color3.fromRGB(31, 41, 55),
	surfaceVariant = Color3.fromRGB(55, 65, 81),

	headerStart = Color3.fromRGB(59, 130, 246),
	headerEnd = Color3.fromRGB(147, 51, 234),

	textPrimary = Color3.fromRGB(255, 255, 255),
	textSecondary = Color3.fromRGB(209, 213, 219),
	textMuted = Color3.fromRGB(156, 163, 175),
	textHint = Color3.fromRGB(107, 114, 128),
	textBlueSubtle = Color3.fromRGB(191, 219, 254),

	accentConnect = Color3.fromRGB(16, 185, 129),
	accentConnectHover = Color3.fromRGB(5, 150, 105),
	accentDisconnect = Color3.fromRGB(239, 68, 68),
	accentDisconnectHover = Color3.fromRGB(220, 38, 38),

	stateConnected = Color3.fromRGB(16, 185, 129),
	stateWaiting = Color3.fromRGB(245, 158, 11),
	stateError = Color3.fromRGB(239, 68, 68),
	stateIdle = Color3.fromRGB(156, 163, 175),
	troubleshoot = Color3.fromRGB(245, 158, 11),

	border = Color3.fromRGB(75, 85, 99),
	inputBorder = Color3.fromRGB(99, 102, 241),

	scrollbar = Color3.fromRGB(99, 102, 241),

	padding = 15,
	cornerRadiusPanel = UDim.new(0, 8),
	cornerRadiusInput = UDim.new(0, 6),
	cornerRadiusButton = UDim.new(0, 12),
})

function Theme.resolve(): Tokens
	return TOKENS
end

return Theme
