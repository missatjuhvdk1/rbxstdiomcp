--!strict
-- domain/handlers/HistoryHandlers.luau
--
-- View + control of the parallel ActionLog. Three endpoints:
--   - getHistory ← legacy plugin.luau L5490-5537 (read, Phase 3)
--   - undo       ← legacy plugin.luau L5283-L5380 (write, Phase 4)
--   - redo       ← legacy plugin.luau L5382-L5481 (write, Phase 4)
--
-- ============================================================================
-- WHY UNDO/REDO ARE IN THE DISPATCHER'S BYPASS SET
-- ============================================================================
-- Both handlers delegate to ActionLog:undo() / ActionLog:redo(), which in
-- turn call ChangeHistoryService:Undo() / Redo() for non-source-only
-- entries. Calling Undo/Redo inside an already-open CHS recording is
-- undefined at the Studio API surface (in legacy plugin.luau this was
-- avoided by leaving undo/redo OUT of the `mutationEndpoints` lookup, so
-- TryBeginRecording was never called for them). The new architecture
-- preserves that by adding both endpoints to Dispatcher.RECORDING_BYPASS,
-- which short-circuits the recording lifecycle entirely.
--
-- These handlers therefore:
--   - Do NOT return a RecordResult (the dispatcher never inspects it on
--     the bypass path; we still return `nil` for shape consistency).
--   - Do NOT call `ctx.actionLog:stage`. The ActionLog:undo / :redo
--     internals manage their own undo/redo stack transitions.
--
-- ============================================================================
-- WIRE SHAPE
-- ============================================================================
-- The TS bridge expects snake_case for these too. ActionLog.UndoRedoResult
-- gives us:
--   { entries, remainingUndos, availableRedos, stoppedEarly, stoppedReason }
-- We translate at the wire boundary to:
--   { undone_count / redone_count, entries, remaining_undos,
--     available_redos, stopped_early, stopped_reason }
-- Nil entries in the result array mean "an out-of-band CHS waypoint we
-- don't track" (the user did something in Studio between requests); we
-- keep them in the array to make the count truthful but mark them with
-- `untracked = true` so the bridge knows what to display.
--
-- ============================================================================
-- WHY THE WIRE FORMAT USES snake_case
-- ============================================================================
-- The TS bridge's get_history MCP tool expects snake_case field names
-- (`can_undo`, `tracked_undo_count`, `undo_stack`, `age_seconds`, etc.).
-- runtime/ActionLog.luau exposes the snapshot using internal camelCase
-- (`canUndo`, `trackedUndoCount`, …) — that's the Luau house style and
-- shouldn't leak into the wire format. We rename here, ONCE, at the
-- handler boundary so the rest of the codebase stays consistent and the
-- bridge sees what the legacy plugin used to send.
--
-- The `index` and `age_seconds` per-entry fields are NOT carried by the
-- ActionLog snapshot (it just exposes the entries themselves); we compute
-- them here so the snapshot type stays minimal and the wire-shape
-- decisions live with the wire-shape code.

local Handler = require(script.Parent.Parent.handler.Handler)

-- ============================================================================
-- TYPED REQUEST/RESPONSE SHAPES
-- ============================================================================

type GetHistoryRequest = {
	limit: number?,
	includeDetails: boolean?,
}

type UndoRedoRequest = {
	count: number?,
}

-- ============================================================================
-- HANDLERS
-- ============================================================================

local HistoryHandlers = {}

-- getHistory: snapshot the parallel ActionLog stacks. Legacy L5490-5537.
-- ----------------------------------------------------------------------------
-- The translation from ActionLog.HistorySnapshot (camelCase, no per-entry
-- index/age) to the wire format (snake_case, index 0 = top, age in seconds)
-- happens here. The `limit` is clamped to MAX_ACTION_HISTORY upstream in
-- ActionLog.snapshot so callers can't request more than we keep.
HistoryHandlers.getHistory = Handler.define(
	"/api/get-history",
	function(ctx, data: GetHistoryRequest): (any, Handler.RecordResult?)
		local request = data or {}
		local includeDetails = request.includeDetails == true
		local now = os.time()

		-- ActionLog.snapshot clamps the limit internally; we just forward.
		local snapshot = ctx.actionLog:snapshot(request.limit, includeDetails)

		-- Decorate the entry slices with index + age_seconds, and translate
		-- the field names to the wire shape. The legacy handler did this
		-- inline; we keep the same shape for backwards compat.
		local function decorate(entries: { any }): { any }
			local out: { any } = {}
			for i, entry in entries do
				local sliced: { [string]: any } = {
					index = i - 1, -- 0 = top of stack (next to be popped)
					action = entry.action,
					target = entry.target,
					summary = entry.summary,
					timestamp = entry.timestamp,
					age_seconds = now - (entry.timestamp or now),
				}
				if includeDetails then
					sliced.details = entry.details
				end
				table.insert(out, sliced)
			end
			return out
		end

		return {
			success = true,
			can_undo = snapshot.canUndo,
			can_redo = snapshot.canRedo,
			tracked_undo_count = snapshot.trackedUndoCount,
			tracked_redo_count = snapshot.trackedRedoCount,
			max_history = snapshot.maxHistory,
			undo_stack = decorate(snapshot.undoStack),
			redo_stack = decorate(snapshot.redoStack),
		},
			nil
	end
)

-- Internal: project an ActionLog.Entry (camelCase, with details) onto the
-- wire format the bridge expects. Nil entries become `untracked = true`
-- placeholders so the caller can tell the difference between "we don't know
-- what got undone" and "the entry below us in the stack".
local function projectEntry(entry: any?, now: number): any
	if entry == nil then
		return {
			untracked = true,
			summary = "Untracked Studio waypoint",
		}
	end
	return {
		action = entry.action,
		target = entry.target,
		summary = entry.summary,
		timestamp = entry.timestamp,
		age_seconds = now - (entry.timestamp or now),
	}
end

-- undo: pop up to `count` entries from the parallel ActionLog and revert
-- them (source-only via direct .Source restore, others via CHS:Undo).
-- Legacy L5283-5380. Bypasses the Dispatcher's recording lifecycle —
-- see RECORDING_BYPASS in Dispatcher.luau.
HistoryHandlers.undo = Handler.define("/api/undo", function(ctx, data: UndoRedoRequest): (any, Handler.RecordResult?)
	local count = data.count or 1
	if count < 1 then
		return { error = "count must be >= 1" }, nil
	end

	local result = ctx.actionLog:undo(count)
	local now = os.time()

	local entries: { any } = {}
	local undoneCount = 0
	for _, entry in result.entries do
		table.insert(entries, projectEntry(entry, now))
		undoneCount += 1
	end

	return {
		success = true,
		undone_count = undoneCount,
		entries = entries,
		remaining_undos = result.remainingUndos,
		available_redos = result.availableRedos,
		stopped_early = result.stoppedEarly,
		stopped_reason = result.stoppedReason,
	},
		nil
end)

-- redo: re-apply up to `count` entries from the redo stack. Legacy L5382-5481.
-- Same bypass semantics as undo above.
HistoryHandlers.redo = Handler.define("/api/redo", function(ctx, data: UndoRedoRequest): (any, Handler.RecordResult?)
	local count = data.count or 1
	if count < 1 then
		return { error = "count must be >= 1" }, nil
	end

	local result = ctx.actionLog:redo(count)
	local now = os.time()

	local entries: { any } = {}
	local redoneCount = 0
	for _, entry in result.entries do
		table.insert(entries, projectEntry(entry, now))
		redoneCount += 1
	end

	return {
		success = true,
		redone_count = redoneCount,
		entries = entries,
		remaining_undos = result.remainingUndos,
		available_redos = result.availableRedos,
		stopped_early = result.stoppedEarly,
		stopped_reason = result.stoppedReason,
	},
		nil
end)

return HistoryHandlers
