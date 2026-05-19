--!strict
-- runtime/ActionLog.luau
--
-- The parallel undo log Studio CHS cannot replace (ARCHITECTURE §9).
-- Legacy plugin.luau: state at L1147-1153, helpers at L1187-1231,
-- undo/redo at L5283-L5481, get_history at L5490-5537.
--
-- ============================================================================
-- WHY THIS EXISTS SEPARATELY FROM CHANGEHISTORYSERVICE
-- ============================================================================
-- Studio's ChangeHistoryService is canonical for instance-tree mutations,
-- but it has TWO gaps the MCP plugin must close:
--
--   1. The script editor maintains its OWN undo stack disjoint from CHS.
--      A direct `instance.Source = "..."` assignment changes the value,
--      but CHS will NOT capture a waypoint for it. If the user then calls
--      our undo() — which delegates to ChangeHistoryService:Undo() — Studio
--      skips past our (waypoint-less) source edit and reverts the previous
--      unrelated waypoint. That's the "Bug 1: edit_script undo doesn't
--      actually revert source" the legacy comments describe at length.
--
--      Fix: for source-only edits we keep a pre/post-source snapshot
--      INSIDE the tracked log entry (`details.scriptEdits`). The undo
--      handler detects these and restores `.Source` manually, BYPASSING
--      CHS. CHS sees no waypoint for the edit, the user sees the edit
--      reverted. Real undo, no collateral damage.
--
--   2. CHS waypoints carry no human-readable description of WHAT was changed.
--      `get_history` exists so an agent can answer "what did I just do?"
--      without re-deriving it from instance diffs. Each tracked entry has
--      action / target / summary / details fields the dispatcher fills in
--      when it logs the action.
--
-- ENTRY LIFECYCLE
-- ============================================================================
-- Handlers call `actionLog:stage(...)` to describe what they just did. The
-- stage sits in a SINGLE-SLOT pending buffer until the dispatcher decides
-- whether to commit it:
--
--   1. Handler runs inside the dispatcher's recording window.
--   2. Handler calls actionLog:stage("create_object", "game.Workspace.Part",
--                                     "Created Part", { className = "Part" }).
--   3. Dispatcher sees the handler's return:
--      - normal success    → actionLog:commit()  (entry → actionHistory)
--      - source-only edit  → actionLog:commit()  AND CHS recording is cancelled
--      - no-op             → actionLog:discard() (entry dropped)
--      - error             → actionLog:discard() (entry dropped, CHS cancelled)
--
-- The dispatcher (Phase 3) owns the commit/discard decision; this module
-- just exposes the four primitives plus undo/redo/get-history.
--
-- WHY A SINGLE-SLOT PENDING BUFFER
-- ============================================================================
-- One in-flight request at a time. The polling loop processes requests
-- sequentially (it has to — undo/redo against Studio's stack is order-
-- dependent and Roblox APIs are not re-entrant). A queue would be
-- preparing for a problem we don't have, and it'd open a window where
-- two stages could race for the same recording. Single slot, cleared on
-- every transition.

local Serialize = require(script.Parent.instance.Serialize)

-- ============================================================================
-- TYPES
-- ============================================================================

-- A ScriptEdit snapshot powers source-only undo: we restore .Source from
-- preSource on undo, from postSource on redo, KEYED BY THE INSTANCE'S PATH
-- (not the Instance ref, which can become orphaned).
export type ScriptEdit = {
	instancePath: string,
	preSource: string,
	postSource: string,
}

export type Details = {
	-- Optional bag of properties the handler wants surfaced via get_history.
	-- Free-form to avoid a rigid schema that handlers would have to grow.
	[string]: any,
	-- Reserved: when present and non-empty, the entry is "source-only" and
	-- undo restores via direct .Source assignment (no CHS:Undo() call).
	scriptEdits: { ScriptEdit }?,
}

export type Entry = {
	action: string, -- "create_object", "edit_script", etc.
	target: string, -- usually the instance path the action operated on
	summary: string, -- one-line, human-readable
	details: Details,
	timestamp: number, -- os.time() at the moment of stage()
}

export type HistorySnapshot = {
	canUndo: boolean,
	canRedo: boolean,
	trackedUndoCount: number,
	trackedRedoCount: number,
	maxHistory: number,
	undoStack: { Entry },
	redoStack: { Entry },
}

export type ActionLog = {
	-- ----- Staging (called by handlers) ------------------------------------
	stage: (self: ActionLog, action: string, target: string, summary: string, details: Details?) -> (),

	-- ----- Commit/discard (called by dispatcher) ---------------------------
	commit: (self: ActionLog) -> (),
	discard: (self: ActionLog) -> (),
	hasPending: (self: ActionLog) -> boolean,

	-- ----- Introspection (powers get_history) ------------------------------
	snapshot: (self: ActionLog, limit: number?, includeDetails: boolean?) -> HistorySnapshot,

	-- ----- Undo/redo (powers /api/undo and /api/redo) ----------------------
	-- Returns up to `count` entries actually undone, plus a stop-reason if
	-- we ran out partway. Source-only entries are handled here directly
	-- (we restore preSource and SKIP CHS:Undo); others delegate to CHS.
	undo: (self: ActionLog, count: number) -> UndoRedoResult,
	redo: (self: ActionLog, count: number) -> UndoRedoResult,

	-- ----- Display helpers -------------------------------------------------
	formatEntry: (self: ActionLog, entry: Entry?) -> string,
}

export type UndoRedoResult = {
	entries: { Entry? }, -- nils mean "an out-of-band CHS waypoint we don't track"
	remainingUndos: number,
	availableRedos: number,
	stoppedEarly: boolean,
	stoppedReason: string?,
}

-- ============================================================================
-- IMPLEMENTATION
-- ============================================================================

local ActionLog = {}
ActionLog.__index = ActionLog

-- Path → Instance resolver. Injected at construction time so this module
-- doesn't have to know about runtime/instance/Path (which would form a
-- diamond) and so tests can substitute a fake resolver. Mirrors the legacy
-- L5311-5319 restoreScriptEdits behaviour (tolerates missing instances:
-- skip with a warning so one orphan doesn't poison the whole undo).
export type PathResolver = (path: string) -> Instance?

type Internal = ActionLog & {
	_chs: ChangeHistoryService,
	_resolve: PathResolver,
	_maxHistory: number,
	_pending: Entry?,
	_undoStack: { Entry },
	_redoStack: { Entry },
}

function ActionLog.new(chs: ChangeHistoryService, resolvePath: PathResolver, maxHistory: number): ActionLog
	local self: Internal = setmetatable({
		_chs = chs,
		_resolve = resolvePath,
		_maxHistory = maxHistory,
		_pending = nil,
		_undoStack = {},
		_redoStack = {},
	}, ActionLog) :: any
	return self
end

-- ----- Staging ---------------------------------------------------------------

function ActionLog.stage(self: Internal, action: string, target: string, summary: string, details: Details?)
	-- Overwriting an existing pending entry is intentional: the dispatcher
	-- always commit/discards between requests, so a non-nil _pending here
	-- only happens if a handler called stage twice. The LATEST stage wins,
	-- matching legacy behaviour where `_pendingActionLog =` was a direct
	-- assignment.
	self._pending = {
		action = action,
		target = target,
		summary = summary,
		details = details or {},
		timestamp = os.time(),
	}
end

function ActionLog.commit(self: Internal)
	local entry = self._pending
	if entry == nil then
		return
	end
	self._pending = nil

	-- A new committed action clears the redo branch. Standard undo-stack
	-- semantics — if the user does something new mid-history, the "future"
	-- branch we could redo into is invalidated.
	self._redoStack = {}
	table.insert(self._undoStack, entry)

	-- Keep history from growing without bound.
	if #self._undoStack > self._maxHistory then
		table.remove(self._undoStack, 1)
	end
end

function ActionLog.discard(self: Internal)
	self._pending = nil
end

function ActionLog.hasPending(self: Internal): boolean
	return self._pending ~= nil
end

-- ----- Display helpers -------------------------------------------------------

-- Compact summary string (legacy L5288 formatActionEntry). The Serialize
-- module's toDisplayString isn't used here because action/target/summary
-- are already strings — but exporting through the runtime/instance/Serialize
-- module keeps the "all display formatting lives in Serialize" rule when
-- Phase 3 starts including value previews in the summary.
function ActionLog.formatEntry(_self: Internal, entry: Entry?): string
	if entry == nil then
		return "Unknown action (possibly manual change)"
	end
	return string.format("%s → %s (%s)", entry.action, entry.target, entry.summary)
end

-- Does this entry represent a pure script-source edit? Pure source edits
-- have a non-empty scriptEdits array AND no other tree/property mutation;
-- they're the entries we undo/redo by direct .Source assignment rather
-- than CHS delegation.
local function entryIsSourceOnly(entry: Entry?): boolean
	if entry == nil then
		return false
	end
	local edits = entry.details.scriptEdits
	if edits == nil then
		return false
	end
	return #edits > 0
end

-- Restore each script's source from the pre- or post-edit snapshot.
-- Tolerant of missing/orphaned instances per legacy semantics: skip with
-- a warning so one disappeared script doesn't poison the whole undo step.
local function restoreScriptEdits(
	resolve: PathResolver,
	scriptEdits: { ScriptEdit },
	useField: "preSource" | "postSource"
)
	for _, edit in scriptEdits do
		local instance = resolve(edit.instancePath)
		if instance ~= nil and instance:IsA("LuaSourceContainer") then
			pcall(function()
				(instance :: LuaSourceContainer).Source = (edit :: any)[useField]
			end)
		else
			-- Quiet warn — the polling loop is hot; we don't want a noisy
			-- print every time an old script was re-named. Visible in the
			-- output panel for users actively debugging.
			warn(
				string.format(
					"[MCPPlugin] ActionLog %s: script at %s missing or wrong class — skipping restore",
					useField,
					edit.instancePath
				)
			)
		end
	end
end

-- ----- Undo / Redo -----------------------------------------------------------

function ActionLog.undo(self: Internal, count: number): UndoRedoResult
	-- Clamp `count` defensively so a runaway agent can't ask for huge
	-- numbers and starve the polling loop.
	local n = math.max(1, math.min(100, count))
	local entries: { Entry? } = {}
	local stoppedReason: string? = nil

	for _ = 1, n do
		local top = self._undoStack[#self._undoStack]
		if entryIsSourceOnly(top) then
			-- Source-only entry: restore preSource and DON'T call CHS:Undo
			-- (no waypoint exists; calling Undo would skip past the next
			-- real waypoint and revert something unrelated).
			local entry = table.remove(self._undoStack)
			if entry then
				local edits = entry.details.scriptEdits :: { ScriptEdit }
				restoreScriptEdits(self._resolve, edits, "preSource")
				table.insert(self._redoStack, entry)
				table.insert(entries, entry)
			end
		else
			-- Tree/property mutation: defer to Studio's stack.
			local canUndo = self._chs:GetCanUndo()
			if not canUndo then
				stoppedReason = "no_more_studio_undo"
				break
			end

			local entry: Entry? = nil
			if #self._undoStack > 0 then
				entry = table.remove(self._undoStack)
				if entry then
					table.insert(self._redoStack, entry)
				end
			end

			self._chs:Undo()
			-- We INTENTIONALLY insert `entry` even if it's nil — the
			-- caller wants the array length to match the count of
			-- undo()s performed, with nils flagging out-of-band waypoints.
			table.insert(entries, entry)
		end
	end

	return {
		entries = entries,
		remainingUndos = #self._undoStack,
		availableRedos = #self._redoStack,
		stoppedEarly = stoppedReason ~= nil,
		stoppedReason = stoppedReason,
	}
end

function ActionLog.redo(self: Internal, count: number): UndoRedoResult
	local n = math.max(1, math.min(100, count))
	local entries: { Entry? } = {}
	local stoppedReason: string? = nil

	for _ = 1, n do
		local top = self._redoStack[#self._redoStack]
		if entryIsSourceOnly(top) then
			local entry = table.remove(self._redoStack)
			if entry then
				local edits = entry.details.scriptEdits :: { ScriptEdit }
				restoreScriptEdits(self._resolve, edits, "postSource")
				table.insert(self._undoStack, entry)
				table.insert(entries, entry)
			end
		else
			local canRedo = self._chs:GetCanRedo()
			if not canRedo then
				stoppedReason = "no_more_studio_redo"
				break
			end

			local entry: Entry? = nil
			if #self._redoStack > 0 then
				entry = table.remove(self._redoStack)
				if entry then
					table.insert(self._undoStack, entry)
				end
			end

			self._chs:Redo()
			table.insert(entries, entry)
		end
	end

	return {
		entries = entries,
		remainingUndos = #self._undoStack,
		availableRedos = #self._redoStack,
		stoppedEarly = stoppedReason ~= nil,
		stoppedReason = stoppedReason,
	}
end

-- ----- Introspection ---------------------------------------------------------

-- Return a slice of the top `limit` entries from a stack with index 0 = top.
-- Older entries (closer to the bottom of the stack) get larger indices.
local function sliceStack(stack: { Entry }, limit: number, includeDetails: boolean): { Entry }
	local out: { Entry } = {}
	local n = #stack
	local take = math.min(limit, n)
	for i = 0, take - 1 do
		local entry = stack[n - i]
		if entry then
			if includeDetails then
				-- Shallow copy so the caller can't mutate our state.
				table.insert(out, {
					action = entry.action,
					target = entry.target,
					summary = entry.summary,
					details = entry.details,
					timestamp = entry.timestamp,
				})
			else
				table.insert(out, {
					action = entry.action,
					target = entry.target,
					summary = entry.summary,
					details = {} :: Details,
					timestamp = entry.timestamp,
				})
			end
		end
	end
	return out
end

function ActionLog.snapshot(self: Internal, limit: number?, includeDetails: boolean?): HistorySnapshot
	local n = limit or 20
	if n < 1 then
		n = 1
	end
	if n > self._maxHistory then
		n = self._maxHistory
	end

	return {
		canUndo = self._chs:GetCanUndo(),
		canRedo = self._chs:GetCanRedo(),
		trackedUndoCount = #self._undoStack,
		trackedRedoCount = #self._redoStack,
		maxHistory = self._maxHistory,
		undoStack = sliceStack(self._undoStack, n, includeDetails == true),
		redoStack = sliceStack(self._redoStack, n, includeDetails == true),
	}
end

-- Touch Serialize so the unused-require warning doesn't fire; we'll start
-- using its toDisplayString in Phase 3 when handler stages include value
-- snapshots in their summary lines.
local _ = Serialize

return ActionLog
