--!strict
-- runtime/testsession/Companions.luau
--
-- Phase 4 shipped the read-only refusal predicate (isProtected /
-- refuseIfProtected). Phase 5 grew this module to its full responsibility:
-- *injecting* and *cleaning up* the test companions that drive play-solo.
--
-- ============================================================================
-- WHY THIS LIVES IN runtime/ AND NOT domain/
-- ============================================================================
-- The protection check is a runtime concern (it consults
-- CollectionService:HasTag + name equality) and is used by handlers in
-- multiple modules (delete_object, set_property, edit_script,
-- set_script_source, move_instance, find_and_replace_in_scripts). The
-- injection/cleanup path is the same concern from the other direction: it
-- *creates* the very instances those handlers refuse to mutate. Co-locating
-- inject + cleanup + isProtected in one runtime module guarantees that the
-- name/tag triplet is sourced from ONE place — Constants — and the three
-- code paths can never get out of sync.
--
-- ============================================================================
-- LEGACY PARITY
-- ============================================================================
-- The injection code mirrors legacy plugin.luau L1050-1144 exactly:
--   1. cleanupTestCompanions() first — guarantees ≤1 of each name exists.
--   2. Build server companion from ServerCompanion.source with both
--      __MCP_SERVER_URL__ and __MCP_SESSION_ID__ substituted; parent under
--      ServerScriptService; tag it; Archivable=true (see below).
--   3. Build client companion from ClientCompanion.source (no placeholders,
--      it talks to the server companion via Remotes); parent under
--      StarterPlayer.StarterPlayerScripts; tag it.
--
-- IMPORTANT: Archivable MUST stay true. ExecutePlayModeAsync builds the
-- test DataModel by Clone()-ing the Edit DataModel, and Instance:Clone()
-- silently returns nil for any instance with Archivable=false. We previously
-- tried Archivable=false as "safety" against saving the companion into the
-- user's place file — but the side effect was that the companion never made
-- it into the test session at all (no log streaming, no end-command path).
-- Three cleanup sweeps (plugin activate, before each test, after each test)
-- keep companions out of the saved file instead.
--
-- ============================================================================
-- WHY plainReplace, NOT string.gsub
-- ============================================================================
-- The serverUrl can legitimately contain `%` characters in some hosting
-- setups (proxies, encoded paths). string.gsub treats `%` as a pattern
-- escape in the replacement string, which would silently corrupt the URL.
-- We use string.find(plain=true) to slice and table.concat to splice —
-- byte-for-byte literal replacement, no pattern interpretation anywhere.
--
-- ============================================================================
-- WHY THE Deps BAG GREW
-- ============================================================================
-- Phase 4's predicate needed only services + constants. Phase 5's inject
-- also needs ServerCompanion / ClientCompanion (for the .source field).
-- We pass them in the Deps bag rather than `require`-ing siblings so a
-- test can provide a stubbed companion source (e.g. for a unit test of
-- the substitution logic without actually exercising the real bodies).

local Constants = require(script.Parent.Parent.Constants)
local Services = require(script.Parent.Parent.Services)
local ServerCompanion = require(script.Parent.ServerCompanion)
local ClientCompanion = require(script.Parent.ClientCompanion)

-- ============================================================================
-- TYPES
-- ============================================================================

export type Result = {
	protected: boolean,
	-- When protected, a human-readable reason naming the culprit. nil when
	-- protected = false. Handlers surface this through their error payload
	-- so the AI gets a useful diagnostic, not just a refusal.
	reason: string?,
}

-- We need read access to two services (CollectionService + Constants); we
-- accept a tiny dependency bag so handlers don't have to pass the whole
-- Context around just for this one check. The check happens hot during
-- destructive ops, so we keep the call site as narrow as possible.
export type Deps = {
	services: Services.Services,
	constants: Constants.Constants,
}

export type InjectResult = {
	serverScript: Script,
	-- The client companion is a `LocalScript` per legacy. Marked optional
	-- because the pcall'd parent-resolution path can legitimately bail
	-- without throwing on a misconfigured place (StarterPlayer missing).
	clientScript: LocalScript?,
}

-- ============================================================================
-- THE PREDICATE
-- ============================================================================

local Companions = {}

-- True iff `instance` (or any of its ancestors up to game) is a test
-- companion we should refuse to mutate. `deps` is a slice of the runtime
-- Context — passing only what we need keeps test stubs trivial.
function Companions.isProtected(deps: Deps, instance: Instance?): Result
	if instance == nil then
		return { protected = false, reason = nil }
	end

	local collectionService = deps.services.collectionService
	local tag = deps.constants.TEST_COMPANION_TAG
	local name = deps.constants.TEST_COMPANION_NAME
	local nameClient = deps.constants.TEST_COMPANION_NAME_CLIENT

	-- Walk from `instance` up to (but not including) game itself. game can
	-- never be tagged a companion, and walking through it would pin us at
	-- the root forever.
	local current: Instance? = instance
	while current ~= nil and current ~= game do
		-- Name check first: cheaper than HasTag, and the companion is
		-- always named with one of the two reserved names.
		local currentName = (current :: Instance).Name
		if currentName == name then
			return {
				protected = true,
				reason = string.format(
					"%s is the server-side MCP test companion (or a descendant). "
						.. "Refuse to mutate. End the test session to clean up.",
					(instance :: Instance):GetFullName()
				),
			}
		elseif currentName == nameClient then
			return {
				protected = true,
				reason = string.format(
					"%s is the client-side MCP test companion (or a descendant). "
						.. "Refuse to mutate. End the test session to clean up.",
					(instance :: Instance):GetFullName()
				),
			}
		end

		-- Tag check via CollectionService. HasTag is cheap (O(1) per tag)
		-- and pcall-guarded because third-party plugins occasionally hook
		-- CollectionService methods.
		local ok, hasTag = pcall(function(): boolean
			return collectionService:HasTag(current :: Instance, tag)
		end)
		if ok and hasTag then
			return {
				protected = true,
				reason = string.format(
					"%s carries the %s tag (or is a descendant of an instance "
						.. "that does). Refuse to mutate. End the test session to clean up.",
					(instance :: Instance):GetFullName(),
					tag
				),
			}
		end

		current = (current :: Instance).Parent
	end

	return { protected = false, reason = nil }
end

-- Tiny convenience used by handlers to refuse with one line:
--   local refusal = Companions.refuseIfProtected(ctx, instance)
--   if refusal then return refusal, nil end
-- Returns the error payload OR nil. Putting the wrapping here keeps each
-- handler's body free of repeated refusal boilerplate while still letting
-- the handler decide what RecordResult to return (always nil — we want
-- the dispatcher to skip both CHS and ActionLog on a refusal).
function Companions.refuseIfProtected(deps: Deps, instance: Instance?): { [string]: any }?
	local result = Companions.isProtected(deps, instance)
	if not result.protected then
		return nil
	end
	return {
		error = result.reason,
		refused = true,
		hint = "MCP test companions are auto-managed during play-solo sessions. "
			.. "If you need to inspect them, use read-only handlers. To remove them, "
			.. "stop the test session.",
	}
end

-- ============================================================================
-- PLAIN-STRING SUBSTITUTION
-- ============================================================================
-- string.gsub's replacement string supports `%` patterns (e.g. `%0` = whole
-- match, `%1`-`%9` = captures, `%%` = literal `%`). The serverUrl we splice
-- in is opaque user-provided text and could contain `%`, which would silently
-- corrupt the URL. plainReplace uses string.find with plain=true to slice
-- byte-for-byte; no pattern interpretation anywhere.
local function plainReplace(haystack: string, needle: string, replacement: string): string
	local result: { string } = {}
	local i = 1
	while true do
		local s, e = string.find(haystack, needle, i, true)
		if not s then
			table.insert(result, string.sub(haystack, i))
			break
		end
		table.insert(result, string.sub(haystack, i, s - 1))
		table.insert(result, replacement)
		i = (e :: number) + 1
	end
	return table.concat(result)
end

-- ============================================================================
-- CLEANUP
-- ============================================================================
-- Sweep ALL companion instances out of the Edit DataModel. Returns the
-- number of instances removed. Idempotent — calling on a clean place
-- returns 0. Called:
--   1. On plugin activate (handle leftovers from a Studio crash).
--   2. Before every play-solo (defensive double-clean).
--   3. After play-solo ends (the normal path).
function Companions.cleanup(deps: Deps): number
	local services = deps.services
	local constants = deps.constants

	local count = 0

	-- Path 1: anything that still carries the tag, regardless of where it
	-- lives. This is the canonical sweep and catches descendants we may
	-- have parented under unusual containers.
	pcall(function()
		local tagged = services.collectionService:GetTagged(constants.TEST_COMPANION_TAG)
		for _, inst in tagged do
			pcall(function()
				inst:Destroy()
			end)
			count += 1
		end
	end)

	-- Path 2: belt-and-suspenders sweep of ServerScriptService by NAME, in
	-- case the tag was somehow stripped (third-party plugin, manual edit).
	pcall(function()
		for _, child in services.serverScriptService:GetChildren() do
			if child.Name == constants.TEST_COMPANION_NAME or child.Name == constants.TEST_COMPANION_NAME_CLIENT then
				pcall(function()
					child:Destroy()
				end)
				count += 1
			end
		end
	end)

	-- Path 3: same belt-and-suspenders sweep but under
	-- StarterPlayer.StarterPlayerScripts (where the client companion
	-- lives). StarterPlayerScripts may not exist in empty places — skip
	-- silently if so; nothing to clean up.
	pcall(function()
		local sps = services.starterPlayer:FindFirstChild("StarterPlayerScripts")
		if sps then
			for _, child in sps:GetChildren() do
				if
					child.Name == constants.TEST_COMPANION_NAME
					or child.Name == constants.TEST_COMPANION_NAME_CLIENT
				then
					pcall(function()
						child:Destroy()
					end)
					count += 1
				end
			end
		end
	end)

	return count
end

-- ============================================================================
-- INJECT
-- ============================================================================
-- Create exactly one server companion (Script under ServerScriptService) and
-- one client companion (LocalScript under StarterPlayer.StarterPlayerScripts)
-- with serverUrl/sessionId substituted into the server template.
--
-- Always cleans up first to guarantee at most one of each companion exists
-- — calling inject() twice with different sessionIds *replaces* the running
-- companion rather than duplicating it.
function Companions.inject(deps: Deps, serverUrl: string, sessionId: string): InjectResult
	-- Defensive sweep before creating. This is the third of the three
	-- cleanup points (see CLEANUP block above); cheap and idempotent.
	Companions.cleanup(deps)

	local services = deps.services
	local constants = deps.constants

	-- ----- SERVER companion ----------------------------------------------
	-- Substitute placeholders. plainReplace is order-independent because
	-- neither placeholder appears in the other's value (they're literal
	-- sentinel tokens chosen for exactly that property).
	local serverSource = ServerCompanion.source
	serverSource = plainReplace(serverSource, ServerCompanion.SERVER_URL_PLACEHOLDER, serverUrl)
	serverSource = plainReplace(serverSource, ServerCompanion.SESSION_ID_PLACEHOLDER, sessionId)

	local serverScript = Instance.new("Script")
	serverScript.Name = constants.TEST_COMPANION_NAME
	serverScript.Source = serverSource
	-- Archivable=true is REQUIRED. ExecutePlayModeAsync clones the Edit
	-- DataModel to build the test DataModel; Instance:Clone() returns nil
	-- for Archivable=false instances. We rely on the cleanup sweeps to
	-- keep companions out of the saved place file instead — see top-of-
	-- file comment.
	serverScript.Archivable = true
	serverScript.Parent = services.serverScriptService
	pcall(function()
		services.collectionService:AddTag(serverScript, constants.TEST_COMPANION_TAG)
	end)

	-- ----- CLIENT companion ----------------------------------------------
	-- LocalScripts in StarterPlayer.StarterPlayerScripts auto-clone into
	-- each Player's PlayerScripts on join, so this one LocalScript yields
	-- one client companion per player in the test session.
	--
	-- Wrapped in pcall because pathological place files can ship without
	-- StarterPlayerScripts. We do NOT try to `Instance.new` the container:
	-- StarterPlayerScripts is service-bound and cannot be constructed
	-- from scripts (Studio enforces a singleton). Studio creates one
	-- automatically as a child of StarterPlayer; if it's missing, we
	-- skip the client companion silently — the server companion still
	-- works for target="server" eval, just no `target="client"` route.
	local clientScript: LocalScript? = nil
	pcall(function()
		local sps: Instance? = services.starterPlayer:FindFirstChild("StarterPlayerScripts")
		if sps == nil then
			-- Pathological place file. Skip client companion silently.
			return
		end

		local ls = Instance.new("LocalScript")
		ls.Name = constants.TEST_COMPANION_NAME_CLIENT
		ls.Source = ClientCompanion.source
		ls.Archivable = true
		ls.Parent = sps
		pcall(function()
			services.collectionService:AddTag(ls, constants.TEST_COMPANION_TAG)
		end)
		clientScript = ls
	end)

	return {
		serverScript = serverScript,
		clientScript = clientScript,
	}
end

return Companions
