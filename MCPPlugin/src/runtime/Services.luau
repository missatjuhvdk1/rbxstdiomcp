--!strict
-- runtime/Services.luau
--
-- The ONLY place `game:GetService` may appear (ARCHITECTURE §4.3, §15 A3).
-- Everywhere else receives services through the typed Context. The CI gate
-- (tools/golden/check.lune.luau → `checkServiceQuarantine`) hard-fails on any
-- other file that calls `game:GetService(`, which makes this quarantine
-- mechanically enforced rather than relying on reviewer vigilance.
--
-- Why every service goes here (even ones used in only one handler):
--   1. Single source of truth — there's exactly one list to audit when we
--      add or remove a Studio integration surface.
--   2. Test seam — domain code that takes `services.x` as a parameter can
--      be exercised in isolation by passing a stub table with the same
--      shape. Direct `game:GetService(...)` calls inside handlers preclude
--      that and are why the legacy plugin.luau is impossible to unit-test.
--   3. Startup audit — one place to see the entire Studio dependency
--      footprint of the plugin, useful when documenting permissions or
--      auditing for forbidden APIs (§15).
--
-- StudioTestService is optional: some Studio builds (and Lune at lint time)
-- don't have it. We probe via pcall and store nil-or-service; consumers MUST
-- handle the nil case (used only by the future playSolo handler, Phase 4).
--
-- ScriptEditorService is included even though Phase 2 doesn't use it yet —
-- Phase 4's script-mutation handlers (edit_script, set_script_source) need
-- it for OpenScriptDocumentAsync / change-via-editor flows. Listing it here
-- now keeps the eventual Phase 4 PR a one-line addition to handler code,
-- not a runtime/ shape change.

export type Services = {
	httpService: HttpService,
	studioService: StudioService,
	selectionService: Selection,
	runService: RunService,
	changeHistoryService: ChangeHistoryService,
	scriptEditorService: ScriptEditorService,
	collectionService: CollectionService,
	logService: LogService,
	studioTestService: any?, -- typed `any?` because it may legitimately not exist
}

local Services = {}

local function tryGetService(name: string): any?
	local ok, svc = pcall(function()
		return game:GetService(name)
	end)
	if ok then
		return svc
	end
	return nil
end

function Services.new(): Services
	return {
		httpService = game:GetService("HttpService"),
		studioService = game:GetService("StudioService"),
		selectionService = game:GetService("Selection"),
		runService = game:GetService("RunService"),
		changeHistoryService = game:GetService("ChangeHistoryService"),
		scriptEditorService = game:GetService("ScriptEditorService"),
		collectionService = game:GetService("CollectionService"),
		logService = game:GetService("LogService"),
		-- StudioTestService is the modern playtest control service. The
		-- legacy plugin.luau (L11-18) intentionally probed via pcall because
		-- older Studio versions lacked it — keep that defensiveness here.
		studioTestService = tryGetService("StudioTestService"),
	}
end

return Services
