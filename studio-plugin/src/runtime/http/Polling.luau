--!strict
-- runtime/http/Polling.luau
--
-- The Heartbeat → /poll loop. Legacy plugin.luau: pollForRequests at L1781,
-- sendResponse at L1917, activate/deactivate at L6934-7004, with the
-- Heartbeat:Connect at L6962.
--
-- ============================================================================
-- WHAT THIS MODULE OWNS AND WHAT IT DOES NOT
-- ============================================================================
-- OWNS:
--   - The single RunService.Heartbeat connection (the §15 A4 render-step
--     pairing rule means it MUST be opened and closed in the same module;
--     CI gate `checkRenderStepPairing` enforces that for BindToRenderStep
--     specifically, but we treat Heartbeat the same way for hygiene).
--   - Retry/backoff state (consecutive-failure counter, current delay).
--   - The "is active" flag.
--   - Emits typed status signals via BindableEvents that the UI subscribes
--     to. CRUCIALLY: this module does NOT touch any UI Instance — no
--     setting label text, no painting status dots. That's the antipattern
--     the legacy plugin's L1805-L1913 represents (140 lines of
--     `statusLabel.Text = ...` interleaved with retry logic). UI listens
--     and renders; this loop emits structured events.
--
-- DOES NOT OWN:
--   - Request dispatch. We take a `dispatch` function in our constructor
--     and call it when /poll returns a request. The dispatcher itself
--     (Phase 3) registers handlers; this module just relays.
--   - JSON encoding/decoding strategy. All JSON goes through HttpClient.
--   - The connect / disconnect HTTP notifications (legacy /ready and
--     /disconnect). Those are one-shot bootstrap concerns; the bootstrap
--     fires them around start/stop. We're the steady-state poller.
--
-- ============================================================================
-- STATUS MODEL
-- ============================================================================
-- The polling loop transitions through a small state machine that the UI
-- can render directly. Events fire only on TRANSITION, not every tick, so
-- the UI doesn't get a 2Hz repaint storm:
--
--   "idle"       → polling not started
--   "connecting" → started, no successful poll yet OR retrying after failure
--   "connected"  → bridge responded AND MCP backend reports connected
--   "waiting"    → bridge responded but MCP backend not yet connected (503)
--   "retrying"   → consecutive failures > 5, in backoff window
--   "error"      → consecutive failures past MAX_FAILURES_BEFORE_ERROR
--
-- The full StatusUpdate carries enough context for the UI to render
-- step-by-step diagnostics ("1. HTTP server reachable", etc.) without
-- the loop having to know about labels at all.

local Janitor = require(script.Parent.Parent.Parent.Parent.Packages.Janitor)

local HttpClient = require(script.Parent.HttpClient)
local Constants = require(script.Parent.Parent.Constants)
local Settings = require(script.Parent.Parent.Settings)

-- ============================================================================
-- TYPES
-- ============================================================================

export type Status = "idle" | "connecting" | "connected" | "waiting" | "retrying" | "error"

export type StatusUpdate = {
	status: Status,
	consecutiveFailures: number,
	-- True iff the most recent /poll request reached the bridge at all
	-- (any HTTP response, including 503 and 4xx). Drives the
	-- "1. HTTP server reachable" step indicator.
	httpReachable: boolean,
	-- True iff the bridge reported mcpConnected==true in its last payload.
	-- Drives the "2. MCP bridge connected" step.
	mcpConnected: boolean,
	-- When current state is "retrying", how long until the next attempt.
	nextRetryDelay: number,
	-- Optional human-readable error from the last failed request. Cleared
	-- on the next successful poll.
	lastError: string?,
}

export type Request = {
	endpoint: string,
	data: any,
	requestId: string,
}

-- Dispatch function: takes a request and returns the response table to
-- POST back to the bridge. We do NOT enforce a particular response shape
-- here; the dispatcher (Phase 3) and the bridge agree on it.
export type Dispatch = (request: Request) -> any

export type Polling = {
	-- Reactive status: subscribe to repaint UI, never poll.
	statusChanged: RBXScriptSignal,
	-- Current status snapshot, useful when a subscriber first connects.
	getStatus: (self: Polling) -> StatusUpdate,
	-- Start the Heartbeat connection. Idempotent: a second call is a no-op.
	start: (self: Polling) -> (),
	-- Stop polling. Connection is disconnected; state resets to "idle".
	stop: (self: Polling) -> (),
	isActive: (self: Polling) -> boolean,
}

type Internal = Polling & {
	_http: HttpClient.HttpClient,
	_constants: Constants.Constants,
	_settings: Settings.Settings,
	_runService: RunService,
	_dispatch: Dispatch,

	_connection: RBXScriptConnection?,
	_signal: BindableEvent,
	_active: boolean,
	_lastPollTime: number,

	-- Retry state
	_consecutiveFailures: number,
	_currentRetryDelay: number,

	-- Last emitted status (so we can dedupe transitions). `statusChanged`
	-- itself is set as a per-instance field in `new`, not on the metatable,
	-- because it's the BindableEvent's Event property and binding it once
	-- at construction is simpler than via __index trickery.
	_status: StatusUpdate,
}

-- ============================================================================
-- CONSTRUCTION
-- ============================================================================

local Polling = {}
Polling.__index = Polling

function Polling.new(
	http: HttpClient.HttpClient,
	constants: Constants.Constants,
	settings: Settings.Settings,
	runService: RunService,
	dispatch: Dispatch,
	janitor: Janitor.Janitor
): Polling
	local signal = Instance.new("BindableEvent")
	signal.Name = "MCPPollingStatusChanged"
	janitor:Add(signal, "Destroy")

	local self: Internal = setmetatable({
		statusChanged = signal.Event,

		_http = http,
		_constants = constants,
		_settings = settings,
		_runService = runService,
		_dispatch = dispatch,

		_connection = nil,
		_signal = signal,
		_active = false,
		_lastPollTime = 0,

		_consecutiveFailures = 0,
		_currentRetryDelay = constants.POLL_INTERVAL_DEFAULT,

		_status = {
			status = "idle" :: Status,
			consecutiveFailures = 0,
			httpReachable = false,
			mcpConnected = false,
			nextRetryDelay = constants.POLL_INTERVAL_DEFAULT,
			lastError = nil,
		},
	}, Polling) :: any

	-- ALSO register the connection-disconnect in the janitor as a cleanup
	-- function so `:stop()` AND `janitor:Destroy()` both reliably tear
	-- down the Heartbeat:Connect. This is the §15 A5 "connection sprawl"
	-- antidote — there's exactly one Heartbeat connection per Polling
	-- instance and it's owned at the janitor level.
	janitor:Add(function()
		Polling.stop(self)
	end, true)

	return self
end

-- ============================================================================
-- STATUS EMISSION
-- ============================================================================

-- Emit only when something the UI cares about changed; ignore tick-level
-- updates that wouldn't repaint anything (e.g. the failure counter going
-- from 12 to 13 if we're already in "error" state).
local function setStatus(self: Internal, next: StatusUpdate)
	local prev = self._status
	if
		prev.status == next.status
		and prev.consecutiveFailures == next.consecutiveFailures
		and prev.httpReachable == next.httpReachable
		and prev.mcpConnected == next.mcpConnected
		and prev.nextRetryDelay == next.nextRetryDelay
		and prev.lastError == next.lastError
	then
		return
	end
	self._status = next
	self._signal:Fire(next)
end

function Polling.getStatus(self: Internal): StatusUpdate
	return self._status
end

-- ============================================================================
-- HANDLE ONE /poll RESPONSE
-- ============================================================================

local function onSuccess(self: Internal, body: string, softUnavailable: boolean)
	self._consecutiveFailures = 0
	self._currentRetryDelay = self._settings:getPollInterval()

	local decodeOk, payload = self._http:decodeJson(body)
	if not decodeOk then
		-- Bridge sent us garbage. Treat as a soft "waiting" — don't escalate
		-- to error because the next request might be fine.
		setStatus(self, {
			status = "waiting",
			consecutiveFailures = 0,
			httpReachable = true,
			mcpConnected = false,
			nextRetryDelay = self._currentRetryDelay,
			lastError = "decode failed: " .. tostring(payload),
		})
		return
	end

	local mcpConnected = (type(payload) == "table" and payload.mcpConnected == true) and not softUnavailable

	if mcpConnected then
		setStatus(self, {
			status = "connected",
			consecutiveFailures = 0,
			httpReachable = true,
			mcpConnected = true,
			nextRetryDelay = self._currentRetryDelay,
			lastError = nil,
		})
	else
		setStatus(self, {
			status = "waiting",
			consecutiveFailures = 0,
			httpReachable = true,
			mcpConnected = false,
			nextRetryDelay = self._currentRetryDelay,
			lastError = nil,
		})
	end

	-- Did the bridge include a pending request? Dispatch it.
	-- Guard with type(payload) == "table" so a malformed bridge response
	-- (e.g. JSON null) doesn't error here.
	if type(payload) == "table" and payload.request and payload.requestId and mcpConnected then
		local req: Request = {
			endpoint = payload.request.endpoint,
			data = payload.request.data,
			requestId = payload.requestId,
		}

		-- Dispatch in pcall — a broken handler must NOT kill the polling
		-- loop. Worst case we send back an error response.
		local dispatchOk, response = pcall(function()
			return self._dispatch(req)
		end)
		if not dispatchOk then
			response = { error = "Handler crashed: " .. tostring(response) }
		end

		-- POST the response. Failure here is logged but not fatal — the
		-- bridge has its own request timeout, the agent will retry, and
		-- we don't want a single response failure to flip us to error.
		local serverUrl = self._settings:getServerUrl()
		local sendResult = self._http:postJson(serverUrl .. self._constants.ENDPOINT_RESPONSE, {
			requestId = req.requestId,
			response = response,
		})
		if not sendResult.ok then
			warn(string.format("[MCPPlugin] failed to POST response for %s: %s", req.endpoint, sendResult.message))
		end
	end
end

local function onFailure(self: Internal, message: string)
	self._consecutiveFailures += 1

	-- Exponential-ish backoff after the second failure (first failure could
	-- be a benign hiccup; second one onwards we start slowing down).
	if self._consecutiveFailures > 1 then
		self._currentRetryDelay = math.min(
			self._currentRetryDelay * self._constants.RETRY_BACKOFF_MULTIPLIER,
			self._constants.MAX_RETRY_DELAY
		)
	end

	-- Status escalation ladder mirrors the legacy L1858-L1913 thresholds.
	local nextStatus: Status
	if self._consecutiveFailures >= self._constants.MAX_FAILURES_BEFORE_ERROR then
		nextStatus = "error"
	elseif self._consecutiveFailures > 5 then
		nextStatus = "retrying"
	else
		nextStatus = "connecting"
	end

	setStatus(self, {
		status = nextStatus,
		consecutiveFailures = self._consecutiveFailures,
		httpReachable = false,
		mcpConnected = false,
		nextRetryDelay = self._currentRetryDelay,
		lastError = message,
	})
end

-- ============================================================================
-- POLL ONCE
-- ============================================================================

local function pollOnce(self: Internal)
	if not self._active then
		return
	end

	local serverUrl = self._settings:getServerUrl()
	local result = self._http:get(serverUrl .. self._constants.ENDPOINT_POLL)

	if result.ok then
		onSuccess(self, result.body, result.softUnavailable)
	else
		onFailure(self, result.message)
	end
end

-- ============================================================================
-- LIFECYCLE
-- ============================================================================

function Polling.start(self: Internal)
	if self._active then
		return
	end
	self._active = true
	self._consecutiveFailures = 0
	self._currentRetryDelay = self._settings:getPollInterval()
	self._lastPollTime = 0

	setStatus(self, {
		status = "connecting",
		consecutiveFailures = 0,
		httpReachable = false,
		mcpConnected = false,
		nextRetryDelay = self._currentRetryDelay,
		lastError = nil,
	})

	-- ONE Heartbeat connection, owned at the janitor level. The legacy
	-- file had this connection re-checked on every activate cycle which
	-- is a recipe for the dreaded "two connections fighting each other"
	-- bug (§15 A5) — we keep it strictly bound to active/inactive.
	self._connection = self._runService.Heartbeat:Connect(function()
		if not self._active then
			return
		end
		local now = os.clock()
		-- Pick interval: when we're in backoff, use the longer delay so we
		-- don't spam a dead bridge. Otherwise use the user-configured poll
		-- interval from Settings.
		local interval = if self._consecutiveFailures > 5
			then self._currentRetryDelay
			else self._settings:getPollInterval()
		if now - self._lastPollTime < interval then
			return
		end
		self._lastPollTime = now
		-- Run pollOnce in pcall so a Roblox API hiccup (rare) doesn't kill
		-- the Heartbeat callback — that would silently freeze the plugin.
		local ok, err = pcall(pollOnce, self)
		if not ok then
			warn(string.format("[MCPPlugin] polling crashed: %s", tostring(err)))
			onFailure(self, "polling exception: " .. tostring(err))
		end
	end)
end

function Polling.stop(self: Internal)
	self._active = false
	if self._connection then
		self._connection:Disconnect()
		self._connection = nil
	end
	-- Reset retry counters so a subsequent start() is a clean attempt.
	self._consecutiveFailures = 0
	self._currentRetryDelay = self._settings:getPollInterval()

	setStatus(self, {
		status = "idle",
		consecutiveFailures = 0,
		httpReachable = false,
		mcpConnected = false,
		nextRetryDelay = self._currentRetryDelay,
		lastError = nil,
	})
end

function Polling.isActive(self: Internal): boolean
	return self._active
end

return Polling
