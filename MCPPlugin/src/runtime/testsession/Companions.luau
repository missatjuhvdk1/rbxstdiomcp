--!strict
-- runtime/testsession/Companions.luau
--
-- Phase 4 STUB of the LLM-stomp prevention helper. The full module (full
-- injection + cleanup + tagging of test-companion scripts during play-solo)
-- ships in Phase 5; Phase 4 only needs the read-only refusal predicate so
-- destructive mutation handlers can hard-refuse on companion-tagged or
-- companion-named instances.
--
-- ============================================================================
-- WHY THIS LIVES IN runtime/ AND NOT domain/
-- ============================================================================
-- The protection check is a runtime concern (it consults
-- CollectionService:HasTag + name equality) and is used by handlers in
-- multiple modules (delete_object, set_property, edit_script,
-- set_script_source, move_instance, find_and_replace_in_scripts). Putting it
-- in domain/ would either force a domain → domain require (handlers can't
-- import each other; the registry is the only inter-handler link) or
-- duplicate the helper into each handler module. runtime/ is the right
-- home: it's stateless, layer-correct (domain may import runtime), and the
-- same module will grow the injection + cleanup APIs in Phase 5.
--
-- ============================================================================
-- LEGACY GAP THIS CLOSES
-- ============================================================================
-- Legacy plugin.luau L48-53 documents the intent ("destructive MCP tools
-- refuse to operate on instances bearing TEST_COMPANION_TAG or matching
-- TEST_COMPANION_NAME") but a full audit of the legacy file shows the
-- refusal was NEVER actually implemented in any destructive handler. This
-- is a real, latent bug in the legacy plugin: an over-eager AI could ask
-- delete_object on the test companion mid-playtest and tear down the very
-- script streaming play-solo logs back to it.
--
-- Phase 4 closes the gap. Every destructive handler that takes an instance
-- path checks `Companions.isProtected(ctx, instance)` before mutating; if
-- protected, it returns a structured error (with a hint suggesting
-- cleanupTestCompanions) and writes NO action-log entry.
--
-- ============================================================================
-- THE PREDICATE
-- ============================================================================
-- An instance is "protected" iff:
--   1. It carries the TEST_COMPANION_TAG (CollectionService:HasTag), OR
--   2. Its Name matches TEST_COMPANION_NAME exactly, OR
--   3. Its Name matches TEST_COMPANION_NAME_CLIENT exactly, OR
--   4. ANY ancestor up the parent chain to game satisfies (1)-(3).
--
-- The ancestor walk matters because an LLM might ask to delete a child of
-- the companion (a child Script under the LocalScript companion folder,
-- for example) rather than the companion itself. Refusing only direct hits
-- would leave a backdoor.

local Constants = require(script.Parent.Parent.Constants)
local Services = require(script.Parent.Parent.Services)

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

-- ============================================================================
-- THE HELPER
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

return Companions
