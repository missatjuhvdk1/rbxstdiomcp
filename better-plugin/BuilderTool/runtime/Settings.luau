--!strict
-- runtime/Settings.luau
--
-- Typed in-memory mirror of persisted preferences (ARCHITECTURE §10).
-- Read via getters; write ONLY via typed setters; every setter persists
-- through `plugin:SetSetting` and fires `changed`. This is the ONLY module
-- that calls Get/SetSetting.

local Janitor = require(script.Parent.Parent.Packages.Janitor)

-- One frozen table of namespaced keys — no scattered string literals.
local KEYS = table.freeze({
	schemaVersion = "BuilderTool/schemaVersion",
	gridSize = "BuilderTool/gridSize",
	snapEnabled = "BuilderTool/snapEnabled",
	rotationIncrement = "BuilderTool/rotationIncrement",
	lastToolId = "BuilderTool/lastToolId",
})

-- Defaults live here (Settings.new only receives the plugin + schema target,
-- not Constants). Constants mirrors these for other consumers; this table is
-- the persistence-layer fallback when a key is missing or corrupt.
local DEFAULTS = table.freeze({
	gridSize = 1,
	snapEnabled = true,
	rotationIncrement = 45,
})

export type Settings = {
	-- Reactive: UI subscribes; never poll.
	changed: RBXScriptSignal,

	getGridSize: (self: Settings) -> number,
	setGridSize: (self: Settings, value: number) -> (),
	isSnapEnabled: (self: Settings) -> boolean,
	setSnapEnabled: (self: Settings, value: boolean) -> (),
	getRotationIncrement: (self: Settings) -> number,
	setRotationIncrement: (self: Settings, value: number) -> (),
	getLastToolId: (self: Settings) -> string?,
	setLastToolId: (self: Settings, id: string?) -> (),

	getToolOption: (self: Settings, toolId: string, key: string, default: any) -> any,
	setToolOption: (self: Settings, toolId: string, key: string, value: any) -> (),
}

type State = {
	gridSize: number,
	snapEnabled: boolean,
	rotationIncrement: number,
	lastToolId: string?,
	toolOptions: { [string]: any },
}

type Internal = Settings & {
	_plugin: Plugin,
	_state: State,
	_signal: BindableEvent,
}

local Settings = {}
Settings.__index = Settings

-- Read a persisted value, falling back to `default` whenever the stored value
-- is missing or the wrong type. NEVER errors on bad stored data (§10).
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
	janitor:Add(signal, "Destroy")

	local storedToolId = plugin:GetSetting(KEYS.lastToolId)
	local self: Internal = setmetatable({
		changed = signal.Event,
		_plugin = plugin,
		_signal = signal,
		_state = {
			gridSize = readTyped(plugin, KEYS.gridSize, DEFAULTS.gridSize),
			snapEnabled = readTyped(plugin, KEYS.snapEnabled, DEFAULTS.snapEnabled),
			rotationIncrement = readTyped(plugin, KEYS.rotationIncrement, DEFAULTS.rotationIncrement),
			lastToolId = if typeof(storedToolId) == "string" then storedToolId else nil,
			toolOptions = {},
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

function Settings.getGridSize(self: Internal): number
	return self._state.gridSize
end

function Settings.setGridSize(self: Internal, value: number)
	commit(self, KEYS.gridSize, "gridSize", math.max(value, 0))
end

function Settings.isSnapEnabled(self: Internal): boolean
	return self._state.snapEnabled
end

function Settings.setSnapEnabled(self: Internal, value: boolean)
	commit(self, KEYS.snapEnabled, "snapEnabled", value)
end

function Settings.getRotationIncrement(self: Internal): number
	return self._state.rotationIncrement
end

function Settings.setRotationIncrement(self: Internal, value: number)
	commit(self, KEYS.rotationIncrement, "rotationIncrement", math.max(value, 0))
end

function Settings.getLastToolId(self: Internal): string?
	return self._state.lastToolId
end

function Settings.setLastToolId(self: Internal, id: string?)
	commit(self, KEYS.lastToolId, "lastToolId", id)
end

function Settings.getToolOption(self: Internal, toolId: string, key: string, default: any): any
	local slot = toolId .. "/" .. key
	local cached = self._state.toolOptions[slot]
	if cached ~= nil then
		return cached
	end
	local stored = self._plugin:GetSetting("BuilderTool/toolOpt/" .. slot)
	local resolved: any = if typeof(stored) == typeof(default) then stored else default
	self._state.toolOptions[slot] = resolved
	return resolved
end

function Settings.setToolOption(self: Internal, toolId: string, key: string, value: any)
	local slot = toolId .. "/" .. key
	if self._state.toolOptions[slot] == value then
		return
	end
	self._state.toolOptions[slot] = value
	self._plugin:SetSetting("BuilderTool/toolOpt/" .. slot, value)
	self._signal:Fire()
end

return Settings
