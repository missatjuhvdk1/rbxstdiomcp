--!strict
-- domain/handler/Handler.luau
--
-- THE Handler contract (ARCHITECTURE §6.1). Every MCP endpoint is a value
-- satisfying this type. Handlers live in domain/handlers/<Group>Handlers.luau
-- modules; the HandlerRegistry enumerates them, the Dispatcher routes one
-- request to one handler.
--
-- This is the structural mirror of BuilderTool/domain/tool/Tool.luau:
--   - Tool         ↔ Handler              (one self-contained unit)
--   - ToolHost     ↔ Dispatcher           (the single active dispatch target)
--   - ToolRegistry ↔ HandlerRegistry      (the typed enumeration)
--
-- ============================================================================
-- WHY HANDLERS NEVER CALL ChangeHistoryService THEMSELVES
-- ============================================================================
-- The legacy plugin.luau had per-handler `ChangeHistoryService:TryBeginRecording`
-- / `FinishRecording` calls scattered across L2038, L4692, L4783, L4848, L4883
-- and more — each with a slightly different pattern, each with its own
-- branching for success/failure/no-op. That sprawl is the single biggest
-- maintenance pain in the legacy file (see ARCHITECTURE §8).
--
-- Phase 3 inverts the control flow: the Dispatcher owns CHS recordings AND
-- the ActionLog stage/commit/discard transitions. A Handler just DESCRIBES
-- what it did via the RecordResult it returns; the Dispatcher reads that
-- description and decides commit-vs-cancel for both the CHS waypoint and the
-- tracked action log entry.
--
-- This means a handler module is purely "what would I do, given a Context
-- and a request body?" — easy to unit-test (pass a fake Context), easy to
-- reason about (no global undo bookkeeping), easy to add (write a function,
-- register it).
--
-- ============================================================================
-- THE RecordResult DECISION TABLE (Dispatcher consumes this)
-- ============================================================================
--   nil                         → Read-only handler. Dispatcher opens no recording.
--   { didMutate = false }       → Handler ran but produced no mutation (e.g.
--                                 find_and_replace with zero matches). Cancel
--                                 the CHS recording AND discard any staged
--                                 ActionLog entry.
--   { isSourceEditOnly = true } → Script-source-only edit. Cancel the CHS
--                                 recording (no waypoint to keep) but COMMIT
--                                 the ActionLog entry (which carries the
--                                 pre/post Source snapshots needed for the
--                                 plugin-side undo path; see ActionLog.luau).
--   { mutatesUnknown = true }   → execute_lua only. Dispatcher decides via
--                                 a synchronous tree-size delta whether to
--                                 commit (mirrors legacy L2059-2067).
--   { didMutate = true }        → Trusted mutator (set_property, create_object,
--                                 etc.). Commit BOTH the CHS recording and
--                                 the ActionLog entry.
--
-- The `name` field becomes the user-visible label in Studio's undo menu
-- ("Undo Set Property: Part.Color"); the Dispatcher prefixes it with "MCP:".
--
-- ============================================================================
-- CONTEXT
-- ============================================================================
-- We re-export runtime/Runtime.Context as Handler.Context so handler modules
-- can refer to a single type name without a deep require chain. This is the
-- same trick BuilderTool's Tool.luau uses to keep the handler-side surface
-- as small as one require.

local Runtime = require(script.Parent.Parent.Parent.runtime.Runtime)

local Handler = {}

-- ============================================================================
-- TYPES
-- ============================================================================

-- Re-export so handler modules write `Handler.Context` rather than reaching
-- across two `script.Parent.Parent` chains to runtime/Runtime.luau.
export type Context = Runtime.Context

-- The plugin-side undo "what was edited" descriptor. Mirrors
-- runtime/ActionLog.luau ScriptEdit so handlers and ActionLog share a
-- vocabulary without one requiring the other.
export type ScriptEdit = {
	instancePath: string,
	preSource: string,
	postSource: string,
}

-- Stable, lowercase, NEVER renamed once shipped (it is a persisted wire-
-- format identifier the TS bridge depends on). Adding a new endpoint is
-- always additive; renaming or removing breaks every existing MCP client.
export type EndpointName = string

-- The decoded HTTP request the Polling loop hands the Dispatcher. Matches
-- runtime/Runtime.HandlerRequest exactly — we re-declare it here so the
-- handler-side type surface doesn't have to import Runtime just for one
-- name.
export type HandlerRequest = {
	endpoint: EndpointName,
	data: any,
	requestId: string,
}

-- The RecordResult is the Handler → Dispatcher decision interface. ALL fields
-- are optional so a handler can omit the ones it doesn't care about; the
-- Dispatcher fills in sane defaults (didMutate = true if any other field is
-- set, scriptEdits = {} if isSourceEditOnly without explicit edits, etc.).
export type RecordResult = {
	-- User-facing undo entry name. The Dispatcher prefixes "MCP: " so the
	-- user sees "MCP: Set Property: Part.Color" in Studio's undo menu.
	-- REQUIRED when the handler mutates anything; it's the only string the
	-- user can use to identify what they're about to undo.
	name: string,
	-- True iff the handler actually changed game state. False = no-op /
	-- zero-match / refused; the Dispatcher cancels the recording so we
	-- don't pollute Studio's undo stack with empty waypoints.
	didMutate: boolean?,
	-- True iff every mutation was a Script .Source assignment (no tree or
	-- property changes). The Dispatcher Cancels CHS (no waypoint exists)
	-- and commits ONLY the ActionLog entry, which holds the snapshots used
	-- for plugin-side source undo (the legacy "Bug 1 fix").
	isSourceEditOnly: boolean?,
	-- The pre/post Source snapshots for every script the handler edited.
	-- REQUIRED when isSourceEditOnly == true; otherwise nil. The Dispatcher
	-- pushes this list into the ActionLog entry's details.scriptEdits so
	-- the undo path can restore via direct .Source assignment.
	scriptEdits: { ScriptEdit }?,
	-- execute_lua sentinel. The handler doesn't know whether arbitrary
	-- user code added or removed instances; the Dispatcher checks a
	-- before/after #game:GetDescendants() delta and decides accordingly.
	-- All other handlers leave this nil.
	mutatesUnknown: boolean?,
	-- Optional free-form details bag for the ActionLog entry. Surfaced by
	-- get_history when `includeDetails = true`. Handlers use this for
	-- "what did I change" diagnostics (e.g. "replaced 7 occurrences").
	details: { [string]: any }?,
}

-- The Handler's main entry point. Returns (responsePayload, RecordResult?).
-- The Dispatcher wraps this in pcall — handlers do NOT have to pcall their
-- own bodies for top-level safety. They SHOULD still pcall individual
-- Roblox API calls that may throw (e.g. probing arbitrary properties), but
-- the Dispatcher catches anything that escapes.
--
-- Read-only handlers return (response, nil). Mutating handlers return
-- (response, recordResult). Returning ({ error = "..." }, anything) is
-- treated as a handler-level error: the Dispatcher discards the
-- RecordResult and returns the error payload to the bridge unchanged.
export type Run = (ctx: Context, data: any) -> (any, RecordResult?)

export type Handler = {
	endpoint: EndpointName,
	run: Run,
}

-- Tiny constructor so handler modules can write
--   return Handler.define("/api/foo", function(ctx, data) ... end)
-- instead of an open-coded table. The function is a thin pass-through but
-- it gives Luau a place to enforce the EndpointName type at the call site,
-- catching e.g. accidentally registering a number as an endpoint.
function Handler.define(endpoint: EndpointName, run: Run): Handler
	return {
		endpoint = endpoint,
		run = run,
	}
end

return Handler
