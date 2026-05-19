--!strict
-- runtime/History.luau
--
-- The ONLY sanctioned path for mutating the user's data model
-- (ARCHITECTURE §8). Wraps the MODERN ChangeHistoryService recording API.
-- One user gesture = one record() = one undo step. Failure cancels the
-- recording and re-raises; nesting reuses the open recording.

export type History = {
	record: <T...>(self: History, name: string, mutate: () -> T...) -> T...,
	-- Async pair for drag operations: open keeps the recording alive across
	-- frames; close commits or cancels it.
	openBatch: (self: History, name: string) -> string?,
	closeBatch: (self: History, id: string?, commit: boolean) -> (),
}

local History = {}
History.__index = History

function History.new(changeHistory: ChangeHistoryService): History
	return setmetatable({ _chs = changeHistory }, History) :: any
end

function History.record<T...>(self: History, name: string, mutate: () -> T...): T...
	local chs = (self :: any)._chs :: ChangeHistoryService
	local id = chs:TryBeginRecording(name)
	if not id then
		-- Already inside a recording — nest, don't double-open.
		return mutate()
	end

	local results = table.pack(pcall(mutate))
	if not results[1] then
		chs:FinishRecording(id, Enum.FinishRecordingOperation.Cancel)
		error(results[2])
	end

	chs:FinishRecording(id, Enum.FinishRecordingOperation.Commit)
	return table.unpack(results, 2, results.n)
end

function History.openBatch(self: History, name: string): string?
	return ((self :: any)._chs :: ChangeHistoryService):TryBeginRecording(name)
end

function History.closeBatch(self: History, id: string?, commit: boolean)
	if id == nil then return end
	local op = if commit
		then Enum.FinishRecordingOperation.Commit
		else Enum.FinishRecordingOperation.Cancel
	;((self :: any)._chs :: ChangeHistoryService):FinishRecording(id, op)
end

return History
