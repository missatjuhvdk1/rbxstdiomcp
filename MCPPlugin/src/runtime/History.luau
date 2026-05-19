--!strict
-- runtime/History.luau
--
-- THE only sanctioned wrapper around ChangeHistoryService for general
-- recording (ARCHITECTURE §8). One user gesture = one record() = one
-- undo step in Studio's stack. The legacy plugin.luau called
-- TryBeginRecording / FinishRecording inline inside processRequest (L2038,
-- L2076-2082) with three different success/failure branches per call site;
-- this module collapses that to a single typed wrapper.
--
-- WHAT THIS WRAPPER DOES NOT DO:
--   - It does NOT manage the parallel ActionLog (the plugin-side tracked
--     undo entries used by get_history / undo-with-source-restore). That
--     lives in runtime/ActionLog.luau and is wired by the dispatcher in
--     Phase 3 around handler calls.
--   - It does NOT auto-detect mutation kind. The legacy
--     `_isSourceEditOnly` / `_didNotMutate` / `_mutatesUnknown` sentinels
--     were a clever-but-fragile way of letting one wrapper handle all
--     handler shapes. Phase 3 will move that decision into the dispatcher
--     where the handler return value is already in hand. This wrapper
--     is for the SIMPLE case: "do this thing, commit if it succeeded,
--     cancel if it threw."
--
-- USAGE PATTERNS:
--
--   ctx.history:record("Move Camera", function()
--       camera.CFrame = newCFrame
--   end)
--
--   -- For the legacy "decide commit/cancel based on handler return" case:
--   local id = ctx.history:beginRecording("Mass Set Property")
--   local ok, result = pcall(handler, data)
--   ctx.history:finishRecording(id, ok and shouldCommit(result))

local History = {}
History.__index = History

export type History = {
	-- The simple case: run `mutate`, commit on success, cancel on error.
	-- Returns whatever `mutate` returns. Re-raises errors after cancel.
	-- If we're already inside a recording (nested call), we don't open a
	-- new one — we just run mutate, since Studio doesn't allow nesting.
	record: <T...>(self: History, name: string, mutate: () -> T...) -> T...,

	-- The dispatcher case: open a recording, return its id (or nil if
	-- another one is already open). finishRecording then commits OR cancels
	-- based on the boolean. The dispatcher in Phase 3 will use this so it
	-- can decide commit/cancel based on the handler's return shape.
	beginRecording: (self: History, name: string) -> string?,
	finishRecording: (self: History, id: string?, commit: boolean) -> (),
}

type Internal = History & {
	_chs: ChangeHistoryService,
}

function History.new(chs: ChangeHistoryService): History
	local self: Internal = setmetatable({
		_chs = chs,
	}, History) :: any
	return self
end

function History.record<T...>(self: Internal, name: string, mutate: () -> T...): T...
	local id = self._chs:TryBeginRecording(name)
	if not id then
		-- Already inside a recording — nest, don't double-open. Studio
		-- refuses overlapping recordings, so we just run the mutator and
		-- let the outer record() commit it.
		return mutate()
	end

	-- pcall the mutator so we can cancel on error without losing the
	-- error to be re-raised after cleanup.
	local results = table.pack(pcall(mutate))
	if not results[1] then
		self._chs:FinishRecording(id, Enum.FinishRecordingOperation.Cancel)
		-- Re-raise the original error so the caller sees it; we already
		-- cancelled the waypoint so Studio's undo stack is clean.
		error(results[2])
	end

	self._chs:FinishRecording(id, Enum.FinishRecordingOperation.Commit)
	return table.unpack(results, 2, results.n)
end

function History.beginRecording(self: Internal, name: string): string?
	return self._chs:TryBeginRecording(name)
end

function History.finishRecording(self: Internal, id: string?, commit: boolean)
	if id == nil then
		return
	end
	local op = if commit then Enum.FinishRecordingOperation.Commit else Enum.FinishRecordingOperation.Cancel
	self._chs:FinishRecording(id, op)
end

return History
