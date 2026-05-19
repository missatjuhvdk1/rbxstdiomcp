--!strict
-- runtime/Constants.luau
--
-- Immutable runtime configuration. `table.freeze`d so a write is a hard
-- error and "this never changes at runtime" is enforced, not just documented
-- (ARCHITECTURE §5). User-tunable values DO NOT live here — they live in
-- Settings (which mirrors persisted preferences); the difference is:
--
--   Constants → ship-time decisions (companion tag string, schema version,
--               bridge endpoint suffixes, log buffer caps, retry bounds).
--   Settings  → user-or-session decisions (server URL the user typed,
--               whether the dock is enabled, current poll interval).
--
-- When in doubt: if a value could ever be changed by the user mid-session
-- without re-loading the plugin, it belongs in Settings, not here.
--
-- ============================================================================
-- WHY THESE PARTICULAR NUMBERS
-- ============================================================================
-- POLL_INTERVAL_DEFAULT = 0.5  — legacy plugin.luau L1254. Tight enough for
--   sub-second tool turnaround, loose enough that 50 idle plugins per Studio
--   process don't saturate the local HTTP loop. Anything faster pegs the CPU
--   on macOS where launchd-throttles the bridge.
-- MAX_RETRY_DELAY = 5          — legacy L1260. Backoff ceiling chosen so a
--   bounced bridge re-connects within "tab-switch" time.
-- RETRY_BACKOFF_MULTIPLIER = 1.2 — legacy L1261. Gentle exponential; we want
--   the steady state visible-to-user to recover within a few seconds.
-- MAX_FAILURES_BEFORE_ERROR = 50 — legacy L1257. At 0.5s interval that's ~25s
--   before we paint the "Server unavailable" red banner — long enough that a
--   reload of the bridge process doesn't trigger a scary UI flash, short
--   enough that a truly dead bridge is reported within half a minute.
-- MAX_OUTPUT_BUFFER = 1000     — legacy L1148. Ring buffer cap for get_output.
-- MAX_ACTION_HISTORY = 100     — legacy L1153. Ring buffer for undo/redo
--   tracking (separate from Studio's CHS stack; see ActionLog.luau).
--
-- The legacy file had these scattered across L54-56, L1148, L1153, L1254-1265,
-- and L5856-5864. Co-locating them here means a future "we should poll faster"
-- change is one diff against one file.

export type Constants = {
	-- Plugin identity ------------------------------------------------------
	PLUGIN_VERSION: string,
	SCHEMA_VERSION: number,

	-- Bridge endpoints -----------------------------------------------------
	-- Suffixes only; the base URL (e.g. http://localhost:3002) is a Setting.
	-- Path strings are kept frozen so a typo is caught at build time, not at
	-- runtime when an MCP tool quietly returns 404.
	ENDPOINT_POLL: string,
	ENDPOINT_RESPONSE: string,
	ENDPOINT_READY: string,
	ENDPOINT_DISCONNECT: string,

	-- Polling / retry budget ----------------------------------------------
	POLL_INTERVAL_DEFAULT: number,
	MAX_RETRY_DELAY: number,
	RETRY_BACKOFF_MULTIPLIER: number,
	MAX_FAILURES_BEFORE_ERROR: number,

	-- Buffers -------------------------------------------------------------
	MAX_OUTPUT_BUFFER: number,
	MAX_ACTION_HISTORY: number,

	-- Test companions (Phase 4 will use these; defined here so the
	-- destructive-mutation refusal lists in Phase 3 can reference one source
	-- of truth without circular requires).
	TEST_COMPANION_NAME: string,
	TEST_COMPANION_NAME_CLIENT: string,
	TEST_COMPANION_TAG: string,

	-- UI identity ---------------------------------------------------------
	WIDGET_ID: string,
	WIDGET_TITLE: string,
	TOOLBAR_NAME: string,
	BUTTON_NAME: string,
	BUTTON_TOOLTIP: string,
	BUTTON_ICON: string,
}

local Constants = {}

function Constants.new(): Constants
	return table.freeze({
		PLUGIN_VERSION = "3.0.0-pre",
		SCHEMA_VERSION = 1,

		ENDPOINT_POLL = "/poll",
		ENDPOINT_RESPONSE = "/response",
		ENDPOINT_READY = "/ready",
		ENDPOINT_DISCONNECT = "/disconnect",

		POLL_INTERVAL_DEFAULT = 0.5,
		MAX_RETRY_DELAY = 5,
		RETRY_BACKOFF_MULTIPLIER = 1.2,
		MAX_FAILURES_BEFORE_ERROR = 50,

		MAX_OUTPUT_BUFFER = 1000,
		MAX_ACTION_HISTORY = 100,

		TEST_COMPANION_NAME = "_MCPTestCompanion",
		TEST_COMPANION_NAME_CLIENT = "_MCPTestCompanion_Client",
		TEST_COMPANION_TAG = "_MCPTestCompanion",

		WIDGET_ID = "MCPServerInterface",
		WIDGET_TITLE = "MCP Server v3.0.0-pre",
		TOOLBAR_NAME = "MCP Integration",
		BUTTON_NAME = "MCP Server",
		BUTTON_TOOLTIP = "Connect to MCP Server for AI Integration",
		BUTTON_ICON = "rbxassetid://10734944444",
	})
end

return Constants
