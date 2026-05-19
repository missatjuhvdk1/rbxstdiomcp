--!strict
-- domain/handlers/HistoryHandlers.luau
--
-- Read-side view of the parallel ActionLog. Phase 3 ships:
--   - getHistory ← legacy plugin.luau L5490-5537
--
-- The mutating siblings (undo, redo — legacy L5283-L5481) ship in Phase 4
-- and will live in this same module. They aren't "mutations" in the
-- normal CHS sense (they DELEGATE to CHS:Undo / CHS:Redo, and they take
-- ownership of the source-edit branch directly) but they DO change game
-- state, so the Dispatcher will run them as mutating handlers.
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

return HistoryHandlers
