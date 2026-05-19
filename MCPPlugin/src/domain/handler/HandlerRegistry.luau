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
-- Phase 3 ships READ-ONLY handlers (no mutations). Phase 4 will add the
-- mutating handlers as additional rows in this table.

local Handler = require(script.Parent.Handler)

local FileTreeHandlers = require(script.Parent.Parent.handlers.FileTreeHandlers)
local PlaceHandlers = require(script.Parent.Parent.handlers.PlaceHandlers)
local InstanceHandlers = require(script.Parent.Parent.handlers.InstanceHandlers)
local AttributeHandlers = require(script.Parent.Parent.handlers.AttributeHandlers)
local TagHandlers = require(script.Parent.Parent.handlers.TagHandlers)
local ScriptHandlers = require(script.Parent.Parent.handlers.ScriptHandlers)
local HistoryHandlers = require(script.Parent.Parent.handlers.HistoryHandlers)

-- ============================================================================
-- THE REGISTRY
-- ============================================================================
-- One row per endpoint. The endpoint string is duplicated on both the table
-- key and the handler's `.endpoint` field — that's intentional: keying by
-- string makes lookups O(1), keeping the field on the handler keeps the
-- handler self-describing (which is what the type system requires for the
-- explicit-define helper Handler.define(name, run) to enforce).
--
-- Phase 3 registers the Phase-3 read-only set ONLY. Each comment block
-- below names the legacy line range the handler ports from, so a reviewer
-- can diff old-vs-new behaviour without grepping.
local registry: { [Handler.EndpointName]: Handler.Handler } = {
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
}

return registry
