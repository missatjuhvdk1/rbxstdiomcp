--!strict
-- domain/handler/Dispatcher.luau
--
-- THE one-and-only request router and CHS-recording owner (ARCHITECTURE §6.2).
-- The structural mirror of BuilderTool/domain/tool/ToolHost.luau:
--   - ToolHost.equip(id)   ↔ Dispatcher:dispatch({ endpoint, data, requestId })
--   - one active tool      ↔ one in-flight request (the Polling loop serialises)
--   - safely(...)          ↔ pcall around handler.run
-- The two patterns are deliberately identical: one place enforces the
-- "exactly one is in charge right now" invariant for both plugins.
--
-- THE LEGACY THIS REPLACES
-- ============================================================================
-- Legacy plugin.luau L1966-2106 (`processRequest`) was the single biggest
-- piece of branching in the codebase. It mixed FOUR concerns into one
-- function body:
--   1. Endpoint lookup (Unknown endpoint → 404)
--   2. Mutation classification (mutationEndpoints table; per-endpoint test)
--   3. CHS recording lifecycle (TryBeginRecording / FinishRecording with
--      Commit OR Cancel based on sentinel inspection of the return value)
--   4. ActionLog stage/commit/discard tracking
-- Plus inline knowledge of execute_lua's descendant-count delta trick.
--
-- The handler modules then carried the OTHER half of the branching: each
-- one decided which sentinel flags to set on its return, which meant the
-- decision table was effectively split between every handler and the
-- dispatcher. Adding a new endpoint required understanding both halves.
--
-- Phase 3 collapses this:
--   - The Handler returns a typed RecordResult (Handler.luau).
--   - The Dispatcher reads RecordResult and runs the decision table.
--   - Adding an endpoint is "write a handler module + one registry line";
--     the recording lifecycle is automatic.
--
-- WHY THE DISPATCHER IS THE BRIDGE
-- ============================================================================
-- The Runtime.Context has a `bridge: Bridge?` field that the bootstrap fills
-- in AFTER Runtime.new returns. The Dispatcher satisfies that contract:
-- `Dispatcher:dispatch(request)` IS `Bridge:dispatch(self, request)`. This
-- lets the Polling loop call `ctx.bridge:dispatch(request)` without the
-- runtime/ layer needing to require domain/ — which would violate
-- ARCHITECTURE §4.1's "runtime cannot import domain" rule. The bridge
-- field's type lives in runtime/Runtime.luau, the implementation lives
-- here, and the bootstrap stitches them together. Standard dependency
-- inversion.

local Handler = require(script.Parent.Handler)
local HandlerRegistry = require(script.Parent.HandlerRegistry)

-- ============================================================================
-- RECORDING-BYPASS SET
-- ============================================================================
-- A small allowlist of endpoints whose handler does its OWN CHS lifecycle
-- and must NOT be wrapped in an outer recording. The only members are the
-- undo/redo handlers: their bodies call `actionLog:undo()` which in turn
-- calls `CHS:Undo()` — and calling Undo inside an open recording is
-- undefined behaviour at the Studio API surface. Mirrors the legacy
-- "these endpoints aren't in mutationEndpoints" treatment.
--
-- Adding to this set requires explicit justification — the read-only and
-- normal-mutator paths cover everything else.
local RECORDING_BYPASS: { [string]: boolean } = {
	["/api/undo"] = true,
	["/api/redo"] = true,
}

-- ============================================================================
-- TYPES
-- ============================================================================

-- The dispatch interface the Runtime.Context.bridge field expects. The shape
-- intentionally matches runtime/Runtime.Bridge so we don't have to plumb a
-- different type into the polling loop; we satisfy it structurally.
export type Dispatcher = {
	dispatch: (self: Dispatcher, request: Handler.HandlerRequest) -> any,
}

type Internal = Dispatcher & {
	_ctx: Handler.Context,
	_registry: { [Handler.EndpointName]: Handler.Handler },
}

local Dispatcher = {}
Dispatcher.__index = Dispatcher

-- ============================================================================
-- CONSTRUCTOR
-- ============================================================================
-- A single dispatcher per Context. The registry is the one produced by
-- HandlerRegistry; we accept it as a parameter (rather than re-requiring
-- it here) so test code can pass a stub registry with one handler.
function Dispatcher.new(ctx: Handler.Context, registry: { [Handler.EndpointName]: Handler.Handler }?): Dispatcher
	local self: Internal = setmetatable({
		_ctx = ctx,
		_registry = registry or HandlerRegistry,
	}, Dispatcher) :: any
	return self
end

-- ============================================================================
-- HELPERS — the decision table from ARCHITECTURE §6.2
-- ============================================================================

-- True iff the handler's return value carries a top-level `error` field.
-- Legacy L2041 — a handler can succeed-pcall but still report a
-- domain-level failure (e.g. "Instance not found: ..."); we treat that as
-- "discard recordings, return the error payload to the bridge".
local function isErrorResponse(response: any): boolean
	return type(response) == "table" and response.error ~= nil
end

-- Apply the Dispatcher decision table to a (response, recordResult) pair.
-- Returns (commitCHS, commitLog) for the lifecycle code below to act on.
-- See ARCHITECTURE §6.2 for the full semantics; comments inline keep the
-- WHY next to each branch.
local function classifyOutcome(
	handlerOK: boolean,
	response: any,
	recordResult: Handler.RecordResult?,
	descendantsBefore: number?,
	descendantsAfter: number?
): (boolean, boolean)
	if not handlerOK then
		-- pcall failure: hard error escaped the handler body. Cancel
		-- everything — the recording would otherwise hold an incomplete
		-- mutation the user couldn't sensibly undo.
		return false, false
	end
	if isErrorResponse(response) then
		-- Domain-level error (handler returned { error = ... }). The
		-- partial mutations are still in the data model (we can't roll
		-- them back without CHS:Undo, which we're explicitly opting out
		-- of here) but we DON'T want a waypoint with the failed entry's
		-- name. Cancel both. Mirrors legacy L2041's `handlerOK = ... and
		-- not (result.error)`.
		return false, false
	end
	if recordResult == nil then
		-- Read-only handler. The dispatcher never opened a recording in
		-- this case, so commit flags are moot; return (false, false) for
		-- consistency.
		return false, false
	end

	-- From here on recordResult is non-nil; default each optional field
	-- defensively so a handler that only sets `name` is treated as a
	-- normal mutator.
	local didMutate = recordResult.didMutate
	if didMutate == nil then
		didMutate = true
	end

	if not didMutate then
		-- Explicit no-op (e.g. find_and_replace_in_scripts with zero
		-- matches; legacy L2055-2058). Cancel both.
		return false, false
	end

	if recordResult.isSourceEditOnly == true then
		-- Source-only edit. CHS does NOT capture .Source assignments,
		-- so a CHS waypoint here is empty; cancelling it keeps Studio's
		-- undo stack clean. The ActionLog entry carries the snapshots
		-- needed for plugin-side undo, so commit the log.
		return false, true
	end

	if recordResult.mutatesUnknown == true then
		-- execute_lua: arbitrary user code. Use synchronous descendant-
		-- count delta to decide whether anything tree-shaped changed.
		-- Property-only mutations are invisible to this check — accepted
		-- edge case documented at legacy L2059-2064.
		local before = descendantsBefore or 0
		local after = descendantsAfter or 0
		local treeChanged = (after ~= before)
		return treeChanged, treeChanged
	end

	-- Trusted mutator path: handler reported success and we have no
	-- reason to second-guess. Commit both.
	return true, true
end

-- ============================================================================
-- DISPATCH
-- ============================================================================
-- The single entry point. Called once per request by the Polling loop's
-- dispatch callback (wired in app/Plugin.client.luau).
function Dispatcher.dispatch(self: Internal, request: Handler.HandlerRequest): any
	local endpoint = request.endpoint
	local data = request.data
	if data == nil then
		-- Bridge sometimes sends a body-less request (e.g. /api/play-solo);
		-- normalise to an empty table so handlers can read `data.x` without
		-- a nil-check on the wrapper.
		data = {}
	end

	local handler = self._registry[endpoint]
	if handler == nil then
		-- Mirrors legacy L1978-1980 — same error shape so the TS bridge
		-- doesn't have to special-case a renamed field.
		return { error = "Unknown endpoint: " .. tostring(endpoint) }
	end

	-- Bypass-recording short-circuit: undo/redo handlers manage CHS
	-- themselves. We just call the handler directly and return its
	-- response; the ActionLog lifecycle is the handler's responsibility
	-- and CHS is never opened on this path. See RECORDING_BYPASS header.
	if RECORDING_BYPASS[endpoint] then
		local okBypass, retBypass = pcall(handler.run, self._ctx, data)
		if not okBypass then
			return { error = "Handler error: " .. tostring(retBypass) }
		end
		return retBypass
	end

	-- Snapshot the tree size BEFORE the handler runs, but only if any
	-- handler in the registry might want the delta (we currently use it
	-- only for execute_lua). It's a cheap O(N) walk; the legacy code did
	-- it conditionally to spare non-execute_lua requests the cost. We
	-- replicate that — read-only handlers and trusted mutators never pay.
	local descendantsBefore: number? = nil
	if endpoint == "/api/execute-lua" then
		descendantsBefore = #game:GetDescendants()
	end

	-- Open a CHS recording speculatively, before we know the handler's
	-- outcome. The recording-name argument is the user-facing label; we
	-- prefix "MCP: " so undo-menu entries are visibly ours. The
	-- recording id may be nil if Studio refuses to open one (another
	-- recording already in flight) — the lifecycle code handles nil
	-- safely.
	--
	-- We use a placeholder name when the handler hasn't given us one
	-- yet; the legacy file used a static mutationEndpoints lookup, but
	-- we'd rather the name come from the handler (which knows what
	-- it's doing). Read-only handlers don't open a recording at all,
	-- but we don't know "is this read-only" until the handler returns —
	-- so we open speculatively and CANCEL on read-only returns. The
	-- net cost is one Studio API call per read-only request; sub-µs.
	local provisionalName = "MCP: " .. endpoint
	local recordingId = self._ctx.history:beginRecording(provisionalName)

	-- Reset the pending ActionLog slot. Handlers stage into this; the
	-- dispatcher commits or discards based on the outcome. Single-slot
	-- buffer per ActionLog.luau's contract — one in-flight request at
	-- a time, the Polling loop serialises.
	if self._ctx.actionLog:hasPending() then
		-- A previous handler stage that was never committed/discarded
		-- means the previous request crashed BEFORE we reached this
		-- code path. Discard defensively so a stuck entry doesn't
		-- attach itself to this request.
		self._ctx.actionLog:discard()
	end

	-- Run the handler in pcall. The handler's body is allowed to throw —
	-- we'd rather catch the error here than crash the polling loop.
	local ok, retA, retB = pcall(handler.run, self._ctx, data)

	local response: any
	local recordResult: Handler.RecordResult? = nil
	if ok then
		response = retA
		recordResult = retB
	else
		-- pcall caught a thrown error. retA is the error message.
		response = { error = "Handler error: " .. tostring(retA) }
	end

	local descendantsAfter: number? = nil
	if descendantsBefore ~= nil then
		descendantsAfter = #game:GetDescendants()
	end

	local commitCHS, commitLog = classifyOutcome(ok, response, recordResult, descendantsBefore, descendantsAfter)

	-- Lifecycle the CHS recording. If commitCHS is true we commit; in
	-- every other case we cancel — which is safe for the read-only path
	-- because we already established the recording held no mutations
	-- (handler returned no RecordResult). Studio is lenient about empty
	-- cancellations.
	self._ctx.history:finishRecording(recordingId, commitCHS)

	-- Lifecycle the ActionLog. We do this AFTER the CHS lifecycle so that
	-- get_history's `canUndo`/`canRedo` flags reflect the just-finalised
	-- state — the snapshot reads ChangeHistoryService:GetCanUndo() which
	-- is only accurate post-FinishRecording.
	if commitLog then
		-- If the handler signalled isSourceEditOnly, fold its scriptEdits
		-- list into whatever the handler staged. We do this by re-staging
		-- with the augmented details payload — ActionLog:stage replaces
		-- the pending slot's contents, so we read it back, augment, and
		-- restage. (We can't peek at the staged entry directly without
		-- exposing internals; this round-trip is the price of keeping
		-- ActionLog's API tight.)
		if recordResult and recordResult.isSourceEditOnly == true and recordResult.scriptEdits ~= nil then
			-- The handler MUST have called stage() (legacy contract). If
			-- it didn't, we fall back to staging here with what we know,
			-- so the source-edit undo path still works.
			if not self._ctx.actionLog:hasPending() then
				self._ctx.actionLog:stage(
					endpoint,
					"<unknown>",
					recordResult.name,
					{ scriptEdits = recordResult.scriptEdits }
				)
			end
			-- Either way, commit. The handler-staged entry already
			-- contains the snapshots in its own details bag if the
			-- handler put them there (the canonical pattern); if not,
			-- the fallback above did it.
		end
		self._ctx.actionLog:commit()
	else
		self._ctx.actionLog:discard()
	end

	return response
end

return Dispatcher
