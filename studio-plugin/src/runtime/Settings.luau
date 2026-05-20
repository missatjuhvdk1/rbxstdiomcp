--!strict
-- runtime/Settings.luau
--
-- Typed in-memory mirror of persisted preferences (ARCHITECTURE §10).
-- Read via getters; write ONLY via typed setters; every setter persists
-- through `plugin:SetSetting` and fires `changed`. This is the ONLY module
-- that calls plugin:Get/SetSetting — see ARCHITECTURE §10.
--
-- Why a typed mirror instead of "just call plugin:GetSetting everywhere":
--   1. Get/SetSetting hits Studio's serializer on every call; mirroring
--      in memory makes per-frame reads (e.g. the polling loop reading the
--      retry interval) free.
--   2. plugin:GetSetting returns `any`; the caller must remember the
--      expected type at every read site. Getters here type-launder once,
--      with the fallback rule centralised: bad/missing → default.
--   3. The migration ladder (`migrate` below) is the seam where v(n)→v(n+1)
--      key renames or value-shape changes live. Scattered get/set calls
--      would force the migration into every reader.
--
-- Why one frozen KEYS table instead of inline string literals:
--   plugin:SetSetting takes any string and silently writes; a typo at a
--   write site that doesn't have a matching typo at the read site loses
--   data forever. Naming every key once and referencing the constant
--   means a typo is a Luau type error, not a silent data-loss bug.

local Janitor = require(script.Parent.Parent.Parent.Packages.Janitor)

-- One frozen table of namespaced keys — no scattered string literals.
-- The "MCP/" prefix avoids collisions with other plugins that share the
-- per-user Studio settings store.
local KEYS = table.freeze({
	schemaVersion = "MCP/schemaVersion",
	serverUrl = "MCP/serverUrl",
	pollInterval = "MCP/pollInterval",
	autoConnect = "MCP/autoConnect",
})

-- Defaults live here. The plain (non-prefixed) Settings.new signature only
-- receives the plugin + schema target, NOT Constants — defaults belong with
-- the persistence layer that has to fall back to them on missing/corrupt
-- data, not with the read-only Constants table.
--
-- DEFAULT_SERVER_URL must match the local MCP bridge's default port. Bumped
-- past the legacy 3002 only with a coordinated bridge-side change.
local DEFAULTS = table.freeze({
	serverUrl = "http://localhost:3002",
	pollInterval = 0.5,
	autoConnect = false,
})

export type Settings = {
	-- Reactive: UI subscribes; never poll the values directly to detect change.
	changed: RBXScriptSignal,

	getServerUrl: (self: Settings) -> string,
	setServerUrl: (self: Settings, value: string) -> (),

	getPollInterval: (self: Settings) -> number,
	setPollInterval: (self: Settings, value: number) -> (),

	isAutoConnect: (self: Settings) -> boolean,
	setAutoConnect: (self: Settings, value: boolean) -> (),
}

type State = {
	serverUrl: string,
	pollInterval: number,
	autoConnect: boolean,
}

type Internal = Settings & {
	_plugin: Plugin,
	_state: State,
	_signal: BindableEvent,
}

local Settings = {}
Settings.__index = Settings

-- Read a persisted value, falling back to `default` whenever the stored
-- value is missing or the wrong type. NEVER errors on bad stored data
-- (§10 — bad persisted data is a corruption case the user can recover from
-- by deleting the plugin's Studio settings; we should not crash the plugin).
local function readTyped<T>(plugin: Plugin, key: string, default: T): T
	local stored = plugin:GetSetting(key)
	if typeof(stored) == typeof(default) then
		return stored :: any
	end
	return default
end

-- Explicit migration ladder. Unknown/missing → defaults; NEVER error on bad
-- stored data (§10). SCHEMA_VERSION is currently 1, so the only real step is
-- v0 (no key) → v1; the structure is in place for future v(n)→v(n+1) steps.
local function migrate(plugin: Plugin, targetVersion: number)
	local stored = plugin:GetSetting(KEYS.schemaVersion)
	local version = if typeof(stored) == "number" then stored else 0

	if version < 1 then
		-- v0 → v1: first-run / pre-versioned install. Nothing to transform;
		-- absent keys resolve to DEFAULTS through readTyped.
		version = 1
	end

	-- A newer-than-known or corrupt version is degraded, not fatal: clamp to
	-- the target and let readTyped fall back per key.
	if version ~= targetVersion then
		version = targetVersion
	end

	plugin:SetSetting(KEYS.schemaVersion, version)
end

function Settings.new(plugin: Plugin, targetVersion: number, janitor: Janitor.Janitor): Settings
	migrate(plugin, targetVersion)

	local signal = Instance.new("BindableEvent")
	signal.Name = "MCPSettingsChanged"
	janitor:Add(signal, "Destroy")

	local self: Internal = setmetatable({
		changed = signal.Event,
		_plugin = plugin,
		_signal = signal,
		_state = {
			serverUrl = readTyped(plugin, KEYS.serverUrl, DEFAULTS.serverUrl),
			pollInterval = readTyped(plugin, KEYS.pollInterval, DEFAULTS.pollInterval),
			autoConnect = readTyped(plugin, KEYS.autoConnect, DEFAULTS.autoConnect),
		},
	}, Settings) :: any

	return self
end

-- Write-through: update the in-memory mirror, persist, then fire `changed`.
-- No-ops when the value is unchanged so the UI is not woken needlessly.
local function commit(self: Internal, key: string, field: string, value: any)
	local state = self._state :: any
	if state[field] == value then
		return
	end
	state[field] = value
	self._plugin:SetSetting(key, value)
	self._signal:Fire()
end

function Settings.getServerUrl(self: Internal): string
	return self._state.serverUrl
end

function Settings.setServerUrl(self: Internal, value: string)
	-- Trim trailing slash so handlers don't have to: URL .. "/poll" should
	-- never produce "http://x//poll".
	local trimmed = value
	while #trimmed > 0 and trimmed:sub(-1) == "/" do
		trimmed = trimmed:sub(1, -2)
	end
	commit(self, KEYS.serverUrl, "serverUrl", trimmed)
end

function Settings.getPollInterval(self: Internal): number
	return self._state.pollInterval
end

function Settings.setPollInterval(self: Internal, value: number)
	-- Clamp to [0.05, 60] so a misconfiguration can't either peg CPU (0)
	-- or appear to hang the plugin forever (Math.huge).
	local clamped = math.max(0.05, math.min(60, value))
	commit(self, KEYS.pollInterval, "pollInterval", clamped)
end

function Settings.isAutoConnect(self: Internal): boolean
	return self._state.autoConnect
end

function Settings.setAutoConnect(self: Internal, value: boolean)
	commit(self, KEYS.autoConnect, "autoConnect", value)
end

return Settings
