--!strict
-- runtime/Logger.luau
--
-- LogService.MessageOut buffer with a fixed-size ring (ARCHITECTURE §6.2).
-- The get_output MCP tool drains this; nothing else should append. The legacy
-- plugin.luau has TWO copies of this buffer (L1234 plugin-side and L304 inside
-- the companion template) — the companion template is a separate execution
-- context (Phase 5 will convert it to a real script), but the plugin-side
-- buffer is the one we replace here.
--
-- Architectural notes:
--
--   1. We do NOT drain LogService on a timer. The legacy code did
--      `task.spawn(while ... do ...)` to flush a companion buffer over
--      HTTP; that's the companion's job (Phase 5). On the plugin side we
--      keep a *passive* in-memory buffer and let get_output pull-paginate
--      it. No render-step or task.wait loops live here.
--
--   2. The Connect() is Janitor-tracked. The §15 A5 "connection sprawl"
--      antipattern is what we're avoiding — every event sink in MCPPlugin
--      must be reachable from the root janitor so one Destroy() at unload
--      reliably tears everything down.
--
--   3. The buffer is a flat array, not a linked list. Appending O(1)
--      via table.insert; dropping the oldest at cap is O(n). For
--      MAX_OUTPUT_BUFFER=1000 the worst-case per-message cost is ~1000
--      copies, which is far below the latency Studio gives us between
--      MessageOut firings. A ring buffer optimisation here would be
--      premature.

local Janitor = require(script.Parent.Parent.Parent.Packages.Janitor)

export type LogEntry = {
	message: string,
	messageType: string, -- the .Name field of the Enum.MessageType
	timestamp: number, -- os.time() seconds since epoch
}

export type Logger = {
	-- Snapshot of the buffer; returns a new table so the caller can iterate
	-- without us mutating under them. Use `since` (a timestamp) to filter
	-- — the polling/UI layers may want only fresh entries.
	getEntries: (self: Logger, since: number?) -> { LogEntry },
	-- Drop everything. The get_output handler exposes this via the `clear`
	-- arg; nothing else should call it.
	clear: (self: Logger) -> (),
	-- Current count (so the UI/poll loop can render "120 buffered" without
	-- copying the buffer).
	count: (self: Logger) -> number,
}

type Internal = Logger & {
	_buffer: { LogEntry },
	_cap: number,
}

local Logger = {}
Logger.__index = Logger

function Logger.new(logService: LogService, cap: number, janitor: Janitor.Janitor): Logger
	local self: Internal = setmetatable({
		_buffer = {},
		_cap = cap,
	}, Logger) :: any

	janitor:Add(
		logService.MessageOut:Connect(function(message: string, messageType: Enum.MessageType)
			-- Defensive: tostring() in case Studio ever passes a non-string
			-- (shouldn't happen per docs, but the legacy companion did this
			-- and we'd rather absorb the cost than surface a wire-format
			-- error to the AI).
			table.insert(self._buffer, {
				message = tostring(message),
				messageType = messageType.Name,
				timestamp = os.time(),
			})
			if #self._buffer > self._cap then
				-- Drop oldest so the buffer is bounded; we'd rather lose
				-- stale output than balloon memory in a long Studio session.
				table.remove(self._buffer, 1)
			end
		end),
		"Disconnect"
	)

	return self
end

function Logger.getEntries(self: Internal, since: number?): { LogEntry }
	if since == nil then
		-- Shallow copy so callers can't mutate our internal buffer.
		return table.clone(self._buffer)
	end
	local cutoff = since
	local out: { LogEntry } = {}
	for _, entry in self._buffer do
		if entry.timestamp >= cutoff then
			table.insert(out, entry)
		end
	end
	return out
end

function Logger.clear(self: Internal)
	table.clear(self._buffer)
end

function Logger.count(self: Internal): number
	return #self._buffer
end

return Logger
