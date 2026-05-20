--!strict
-- domain/handler/HandlerRegistry.luau
--
-- THE one place that enumerates MCP endpoints (ARCHITECTURE §6.3). Populated
-- by EXPLICIT require of each domain/handlers/<Group>Handlers.luau module
-- and explicit insertion of each exported handler. Adding an endpoint =
-- write the handler in its module + ONE line here. Nothing else changes.
--
-- This is the structural mirror of BuilderTool's ToolRegistry.luau:
--   - Static, top-level requires (never dynamic / string-driven).
--   - Frozen at module load; the Dispatcher reads, never writes.
--   - The single greppable catalogue of "what endpoints does this plugin
--     expose to the bridge".
--
-- ============================================================================
-- WHY EXPLICIT-REQUIRE INSTEAD OF FOLDER SCAN
-- ============================================================================
-- The legacy plugin.luau put all 50+ endpoints in one literal table at
-- L6805-6864. That table at least had the virtue of being one greppable
-- list. A folder-scan registry would lose that property — to know what
-- endpoints exist you'd have to enumerate the filesystem.
--
-- Phase 3+ keeps the legacy file's "one greppable list" property while
-- moving the implementations into per-group modules. The cost is one line
-- per endpoint here; the benefit is `grep -n /api/ HandlerRegistry.luau`
-- still answers "what endpoints does this plugin serve".
--
-- ============================================================================
-- THE LEGACY → PHASE-3 MAPPING
-- ============================================================================
-- This file replaces legacy plugin.luau L6805-6864. The legacy `mutationEndpoints`
-- classification table (L1934-1961) is gone — endpoints classify themselves
-- via the RecordResult their run() function returns (Handler.luau). One
-- source of truth, owned by the handler.
--
-- Phase 4 adds the mutating handlers (property writes, creation/deletion,
-- hierarchy, attribute/tag writes, script edits, undo/redo) as additional
-- rows below the Phase-3 reads. Read AND write halves of each handler group
-- share a module so a reviewer reading "what does the AttributeHandlers
-- module do?" sees both sides at once.

local Handler = require(script.Parent.Handler)

local FileTreeHandlers = require(script.Parent.Parent.handlers.FileTreeHandlers)
local PlaceHandlers = require(script.Parent.Parent.handlers.PlaceHandlers)
local InstanceHandlers = require(script.Parent.Parent.handlers.InstanceHandlers)
local AttributeHandlers = require(script.Parent.Parent.handlers.AttributeHandlers)
local TagHandlers = require(script.Parent.Parent.handlers.TagHandlers)
local ScriptHandlers = require(script.Parent.Parent.handlers.ScriptHandlers)
local HistoryHandlers = require(script.Parent.Parent.handlers.HistoryHandlers)
local PropertyHandlers = require(script.Parent.Parent.handlers.PropertyHandlers)
local CreationHandlers = require(script.Parent.Parent.handlers.CreationHandlers)
local HierarchyHandlers = require(script.Parent.Parent.handlers.HierarchyHandlers)
-- Phase 5: heavy handlers (test sessions, execute_lua, render pipelines).
-- Each lives in its own module — see the per-module headers for the legacy
-- line ranges they port from and the §15 token-gate whitelist entries they
-- require.
local PlaytestHandlers = require(script.Parent.Parent.handlers.PlaytestHandlers)
local ExecuteLuaHandler = require(script.Parent.Parent.handlers.ExecuteLuaHandler)
local RenderHandlers = require(script.Parent.Parent.handlers.RenderHandlers)

-- ============================================================================
-- THE REGISTRY
-- ============================================================================
-- One row per endpoint. The endpoint string is duplicated on both the table
-- key and the handler's `.endpoint` field — that's intentional: keying by
-- string makes lookups O(1), keeping the field on the handler keeps the
-- handler self-describing (which is what the type system requires for the
-- explicit-define helper Handler.define(name, run) to enforce).
--
-- Phase 4 adds the mutating endpoints below the Phase-3 read-only set.
-- Each comment block names the legacy line range the handler ports from
-- so a reviewer can diff old-vs-new behaviour without grepping. Read and
-- write halves of the same group (AttributeHandlers / TagHandlers /
-- ScriptHandlers / HistoryHandlers) are split into two comment blocks so
-- the read/write boundary is visible from this catalogue alone.
local registry: { [Handler.EndpointName]: Handler.Handler } = {
	-- ========================================================================
	-- READ-ONLY ENDPOINTS (Phase 3)
	-- ========================================================================

	-- ----- FileTreeHandlers (legacy L2131-2213, 2590-2741) ----------------
	["/api/file-tree"] = FileTreeHandlers.getFileTree,
	["/api/search-files"] = FileTreeHandlers.searchFiles,
	["/api/project-structure"] = FileTreeHandlers.getProjectStructure,

	-- ----- PlaceHandlers (legacy L2214-2274, 4936-4964, 4970-5036) --------
	["/api/place-info"] = PlaceHandlers.getPlaceInfo,
	["/api/services"] = PlaceHandlers.getServices,
	["/api/get-selection"] = PlaceHandlers.getSelection,
	["/api/get-output"] = PlaceHandlers.getOutput,

	-- ----- InstanceHandlers (legacy L2276-2589) ---------------------------
	["/api/instance-properties"] = InstanceHandlers.getInstanceProperties,
	["/api/instance-children"] = InstanceHandlers.getInstanceChildren,
	["/api/search-objects"] = InstanceHandlers.searchObjects,
	["/api/search-by-property"] = InstanceHandlers.searchByProperty,
	["/api/class-info"] = InstanceHandlers.getClassInfo,

	-- ----- AttributeHandlers (read part, legacy L4607-4652, 4710-4764) ----
	["/api/get-attribute"] = AttributeHandlers.getAttribute,
	["/api/get-attributes"] = AttributeHandlers.getAttributes,

	-- ----- TagHandlers (read part, legacy L4802-4828, 4901-4933) ----------
	["/api/get-tags"] = TagHandlers.getTags,
	["/api/get-tagged"] = TagHandlers.getTagged,

	-- ----- ScriptHandlers (read part, legacy L3632-3731, 4050-4118,
	--       4138-4329, 4332-4462) ------------------------------------------
	["/api/get-script-source"] = ScriptHandlers.getScriptSource,
	["/api/search-script"] = ScriptHandlers.searchScript,
	["/api/grep"] = ScriptHandlers.grep,
	["/api/get-script-function"] = ScriptHandlers.getScriptFunction,

	-- ----- HistoryHandlers (read part, legacy L5490-5537) -----------------
	["/api/get-history"] = HistoryHandlers.getHistory,

	-- ----- Diagnostic (replaces Phase 2's inline /api/ping) ---------------
	-- Sanity payload: TS bridge's `ping` MCP tool surfaces ok=true + version
	-- + timestamp so the user can confirm the plugin is the version they
	-- think it is. The implementation lives in PlaceHandlers so we don't
	-- need a one-handler module.
	["/api/ping"] = PlaceHandlers.ping,

	-- ========================================================================
	-- MUTATING ENDPOINTS (Phase 4)
	-- ========================================================================
	-- Each handler below returns a RecordResult that drives the Dispatcher's
	-- CHS recording + ActionLog commit decisions. Source-only edits return
	-- isSourceEditOnly=true + scriptEdits so undo can restore .Source
	-- directly (decoupled from CHS waypoints). Undo/redo themselves are in
	-- Dispatcher.RECORDING_BYPASS — they short-circuit the recording
	-- lifecycle because CHS:Undo/Redo inside an open recording is undefined.

	-- ----- PropertyHandlers (legacy L2745-2861, 3211-3415, 3417-3471,
	--       3473-3552, 3554-3629) ------------------------------------------
	["/api/set-property"] = PropertyHandlers.setProperty,
	["/api/mass-set-property"] = PropertyHandlers.massSetProperty,
	["/api/mass-get-property"] = PropertyHandlers.massGetProperty,
	["/api/set-calculated-property"] = PropertyHandlers.setCalculatedProperty,
	["/api/set-relative-property"] = PropertyHandlers.setRelativeProperty,

	-- ----- CreationHandlers (legacy L2863-2974, 2976-3072, 3074-3209,
	--       4467-4500, 4503-4604, 5040-5152, 5154-5278) --------------------
	["/api/create-object"] = CreationHandlers.createObject,
	["/api/mass-create-objects"] = CreationHandlers.massCreateObjects,
	["/api/mass-create-objects-with-properties"] = CreationHandlers.massCreateObjectsWithProperties,
	["/api/delete-object"] = CreationHandlers.deleteObject,
	["/api/smart-duplicate"] = CreationHandlers.smartDuplicate,
	["/api/mass-duplicate"] = CreationHandlers.massDuplicate,
	["/api/insert-asset"] = CreationHandlers.insertAsset,

	-- ----- HierarchyHandlers (legacy L5540-5612, 5614-5680) ---------------
	["/api/clone-instance"] = HierarchyHandlers.cloneInstance,
	["/api/move-instance"] = HierarchyHandlers.moveInstance,

	-- ----- AttributeHandlers (write part, legacy L4654-4708, 4766-4799) ---
	["/api/set-attribute"] = AttributeHandlers.setAttribute,
	["/api/delete-attribute"] = AttributeHandlers.deleteAttribute,

	-- ----- TagHandlers (write part, legacy L4831-4868, 4870-4898) ---------
	["/api/add-tag"] = TagHandlers.addTag,
	["/api/remove-tag"] = TagHandlers.removeTag,

	-- ----- ScriptHandlers (write part, legacy L3733-3812, 3815-3955,
	--       3957-4047, 4464-4520) ------------------------------------------
	-- All four return isSourceEditOnly=true + scriptEdits where applicable
	-- so source restores happen via .Source assignment, bypassing CHS.
	-- validateScript is read-only (loadstring probe) but lives here because
	-- it shares the script-resolution helpers with the write handlers.
	["/api/set-script-source"] = ScriptHandlers.setScriptSource,
	["/api/edit-script"] = ScriptHandlers.editScript,
	["/api/find-and-replace-in-scripts"] = ScriptHandlers.findAndReplaceInScripts,
	["/api/validate-script"] = ScriptHandlers.validateScript,

	-- ----- HistoryHandlers (write part, legacy L5283-5380, 5382-5481) -----
	-- Both endpoints are in Dispatcher.RECORDING_BYPASS so the dispatcher
	-- does NOT open a CHS recording around them. See HistoryHandlers.luau
	-- module header for the full rationale.
	["/api/undo"] = HistoryHandlers.undo,
	["/api/redo"] = HistoryHandlers.redo,

	-- ========================================================================
	-- HEAVY ENDPOINTS (Phase 5)
	-- ========================================================================
	-- Test sessions, execute_lua, and the render pipelines all share an
	-- elevated risk profile (loadstring, off-thread spawns, off-screen
	-- DataModel writes) so their per-module headers document the legacy
	-- mapping and audit boundaries in detail. The registry just lists them.

	-- ----- PlaytestHandlers (legacy L5870-5993) ---------------------------
	-- play_solo injects companion scripts + spawns ExecutePlayModeAsync on
	-- a separate thread; stop_play is a deprecated stub kept for backward
	-- compatibility with older bridges. RecordResult = nil on both (test
	-- session state is per-session, not part of Edit-DataModel undo).
	["/api/play-solo"] = PlaytestHandlers.playSolo,
	["/api/stop-play"] = PlaytestHandlers.stopPlay,

	-- ----- ExecuteLuaHandler (legacy L5543-5775) --------------------------
	-- The only place in the plugin that calls loadstring/setfenv on
	-- caller-supplied code. Returns mutatesUnknown=true so the Dispatcher
	-- decides commit-vs-cancel via #game:GetDescendants() delta.
	["/api/execute-lua"] = ExecuteLuaHandler.executeLua,

	-- ----- RenderHandlers (legacy L6045-6802) -----------------------------
	-- capture-screenshot and focus-camera are read-only as far as the
	-- DataModel is concerned. render-object-view clones the target under
	-- CoreGui's transient ScreenGui and destroys it before returning.
	-- All three return RecordResult = nil.
	["/api/capture-screenshot"] = RenderHandlers.captureScreenshot,
	["/api/render-object-view"] = RenderHandlers.renderObjectView,
	["/api/focus-camera"] = RenderHandlers.focusCamera,
}

return registry
