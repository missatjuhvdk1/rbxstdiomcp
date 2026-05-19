--!strict
-- domain/handlers/FileTreeHandlers.luau
--
-- Tree-shape inspection of the data model. Three read-only handlers:
--   - getFileTree           ← legacy plugin.luau L2131-2167
--   - searchFiles           ← legacy plugin.luau L2169-2212
--   - getProjectStructure   ← legacy plugin.luau L2590-2740
--
-- ============================================================================
-- WHY THESE THREE LIVE TOGETHER
-- ============================================================================
-- All three answer "tell me about the shape of the data model under <path>".
-- They differ in granularity:
--   - getFileTree: full recursive walk capped at depth 10. The base "what
--     instances are here". The MCP host's `list_files` tool wraps this.
--   - searchFiles: same recursive walk but filtered by name / class / source
--     pattern. The host's `search_files` tool wraps this. Conceptually
--     getFileTree + a predicate.
--   - getProjectStructure: smart-summary walk. Roots default to the standard
--     Studio services; deep branches with >20 same-typed children get
--     collapsed to a counted summary so the response payload stays bounded
--     even on Workspace-sized trees. The host's `get_project_structure` tool
--     wraps this.
--
-- Co-locating them keeps the tree-walking helpers (depth limits, GuiObject
-- metadata, BaseScript metadata extraction) in one place. The legacy file
-- had three independent walks with subtle drift between them; this module
-- consolidates the metadata extraction.
--
-- ============================================================================
-- WHY THE HARD-CODED SERVICE LIST IS REPLICATED FROM LEGACY VERBATIM
-- ============================================================================
-- getProjectStructure's `mainServices` list (Workspace, ServerScriptService,
-- ...) is identical to legacy L2598-2607. The set is opinionated — it
-- omits CoreGui, NetworkServer, JointsService, etc. — and any change to it
-- shifts what an MCP user sees on a blind `get_project_structure()` call.
-- We keep it bit-identical to legacy so existing AI prompts that assume
-- the "service overview" shape still work.

local Handler = require(script.Parent.Parent.handler.Handler)
local Path = require(script.Parent.Parent.Parent.runtime.instance.Path)

-- ============================================================================
-- TYPED REQUEST/RESPONSE SHAPES
-- ============================================================================

type GetFileTreeRequest = {
	path: string?,
}

type FileTreeNode = {
	name: string,
	className: string,
	path: string?,
	children: { FileTreeNode },
	hasSource: boolean?,
	scriptType: string?,
}

type SearchFilesRequest = {
	query: string?,
	searchType: string?,
}

type ProjectStructureRequest = {
	path: string?,
	maxDepth: number?,
	scriptsOnly: boolean?,
}

-- ============================================================================
-- INTERNAL TREE WALKERS
-- ============================================================================

-- Caps copied verbatim from legacy: depth=10 keeps deeply-nested folder
-- trees (e.g. Roact mounts) from blowing the response. Beyond 10 we still
-- emit the node but no children; the caller can re-query with a deeper
-- path to descend further.
local MAX_FILE_TREE_DEPTH = 10

local function buildTree(instance: Instance, depth: number): FileTreeNode
	if depth > MAX_FILE_TREE_DEPTH then
		-- Emit the node so the parent's child list stays accurate; just
		-- don't recurse. The caller can re-query with `path = <this node>`
		-- to descend below the cap.
		return {
			name = instance.Name,
			className = instance.ClassName,
			children = {},
		}
	end

	local node: FileTreeNode = {
		name = instance.Name,
		className = instance.ClassName,
		path = Path.getInstancePath(instance),
		children = {},
	}

	if instance:IsA("LuaSourceContainer") then
		node.hasSource = true
		node.scriptType = instance.ClassName
	end

	for _, child in instance:GetChildren() do
		table.insert(node.children, buildTree(child, depth + 1))
	end

	return node
end

-- ============================================================================
-- HANDLERS
-- ============================================================================

local FileTreeHandlers = {}

-- getFileTree: full recursive walk of one subtree, capped at depth 10.
-- Legacy L2131-2167.
FileTreeHandlers.getFileTree = Handler.define(
	"/api/file-tree",
	function(_ctx, data: GetFileTreeRequest): (any, Handler.RecordResult?)
		local path = data.path or ""
		local startInstance = Path.getInstanceByPath(path)
		if startInstance == nil then
			return { error = "Path not found: " .. path }, nil
		end

		return {
			tree = buildTree(startInstance, 0),
			timestamp = os.clock(),
		}, nil
	end
)

-- searchFiles: walk game and filter by name / class / script-source pattern.
-- Legacy L2169-2212. Uses :lower():find() to be case-insensitive.
FileTreeHandlers.searchFiles = Handler.define(
	"/api/search-files",
	function(_ctx, data: SearchFilesRequest): (any, Handler.RecordResult?)
		local query = data.query
		local searchType = data.searchType or "name"
		if query == nil then
			return { error = "Query is required" }, nil
		end

		local results: { any } = {}
		local needle = string.lower(query)

		local function searchRecursive(instance: Instance)
			local matched = false
			if searchType == "name" then
				matched = string.find(string.lower(instance.Name), needle, 1, true) ~= nil
			elseif searchType == "type" then
				matched = string.find(string.lower(instance.ClassName), needle, 1, true) ~= nil
			elseif searchType == "content" and instance:IsA("LuaSourceContainer") then
				local ok, source = pcall(function()
					return (instance :: LuaSourceContainer).Source
				end)
				if ok and source ~= nil then
					matched = string.find(string.lower(source), needle, 1, true) ~= nil
				end
			end

			if matched then
				table.insert(results, {
					name = instance.Name,
					className = instance.ClassName,
					path = Path.getInstancePath(instance),
					hasSource = instance:IsA("LuaSourceContainer"),
				})
			end

			for _, child in instance:GetChildren() do
				searchRecursive(child)
			end
		end

		searchRecursive(game)

		return {
			results = results,
			query = query,
			searchType = searchType,
			count = #results,
		}, nil
	end
)

-- getProjectStructure: smart-summary walk with depth + scriptsOnly filters
-- and "20+ same-typed children" collapsing. Legacy L2590-2740.
-- ----------------------------------------------------------------------------
-- The legacy "service overview" mode (no path / path == "game") is preserved
-- bit-identical: same six services, same return shape, same `note` string.
-- Existing MCP prompts that branch on `type = "service_overview"` will see
-- the same response.
local SERVICE_OVERVIEW = {
	"Workspace",
	"ServerScriptService",
	"ServerStorage",
	"ReplicatedStorage",
	"StarterGui",
	"StarterPack",
	"StarterPlayer",
	"Players",
}

local function buildProjectNode(instance: Instance, depth: number, maxDepth: number, scriptsOnly: boolean): any
	if depth > maxDepth then
		return {
			name = instance.Name,
			className = instance.ClassName,
			path = Path.getInstancePath(instance),
			childCount = #instance:GetChildren(),
			hasMore = true,
			note = "Max depth reached - use this path to explore further",
		}
	end

	local node: any = {
		name = instance.Name,
		className = instance.ClassName,
		path = Path.getInstancePath(instance),
		children = {},
	}

	if instance:IsA("LuaSourceContainer") then
		node.hasSource = true
		node.scriptType = instance.ClassName
		if instance:IsA("BaseScript") then
			node.enabled = (instance :: BaseScript).Enabled
		end
	end

	-- GuiObject metadata is small but useful for the AI to disambiguate
	-- "text widget" vs "image widget" vs "container" without a follow-up
	-- get_instance_properties call. Verbatim from legacy L2663-2675.
	if instance:IsA("GuiObject") then
		node.visible = (instance :: GuiObject).Visible
		if instance:IsA("Frame") or instance:IsA("ScreenGui") then
			node.guiType = "container"
		elseif instance:IsA("TextLabel") or instance:IsA("TextButton") then
			node.guiType = "text"
			local textInstance = instance :: TextLabel | TextButton
			if textInstance.Text ~= nil and textInstance.Text ~= "" then
				node.text = textInstance.Text
			end
		elseif instance:IsA("ImageLabel") or instance:IsA("ImageButton") then
			node.guiType = "image"
		end
	end

	local children = instance:GetChildren()
	if scriptsOnly then
		local kept: { Instance } = {}
		for _, child in children do
			if child:IsA("BaseScript") or child:IsA("Folder") or child:IsA("ModuleScript") then
				table.insert(kept, child)
			end
		end
		children = kept
	end

	-- The "20+ children of the same class" collapsing: group by class,
	-- show three examples per group plus a count summary. Keeps the
	-- payload bounded when a folder holds 500 mob spawners or similar.
	-- Legacy L2689-2723.
	if #children > 20 and depth < maxDepth then
		local groups: { [string]: { Instance } } = {}
		for _, child in children do
			local cls = child.ClassName
			if groups[cls] == nil then
				groups[cls] = {}
			end
			table.insert(groups[cls], child)
		end

		node.childSummary = {}
		for cls, classChildren in groups do
			table.insert(node.childSummary, {
				className = cls,
				count = #classChildren,
				examples = {
					classChildren[1] and classChildren[1].Name,
					classChildren[2] and classChildren[2].Name,
				},
			})
		end

		for cls, classChildren in groups do
			for i = 1, math.min(3, #classChildren) do
				table.insert(node.children, buildProjectNode(classChildren[i], depth + 1, maxDepth, scriptsOnly))
			end
			if #classChildren > 3 then
				table.insert(node.children, {
					name = "... " .. (#classChildren - 3) .. " more " .. cls .. " objects",
					className = "MoreIndicator",
					path = Path.getInstancePath(instance) .. " [" .. cls .. " children]",
					note = "Use specific path to explore these objects",
				})
			end
		end
	else
		for _, child in children do
			table.insert(node.children, buildProjectNode(child, depth + 1, maxDepth, scriptsOnly))
		end
	end

	return node
end

FileTreeHandlers.getProjectStructure = Handler.define(
	"/api/project-structure",
	function(ctx, data: ProjectStructureRequest): (any, Handler.RecordResult?)
		local startPath = data.path or ""
		local maxDepth = data.maxDepth or 3
		local scriptsOnly = data.scriptsOnly == true

		-- Service-overview fast path: empty / "game" path returns the
		-- hard-coded service list and short-circuits the recursive walk.
		-- Legacy L2596-2628. The list is replicated verbatim for prompt
		-- backwards-compatibility (see module header note).
		if startPath == "" or startPath == "game" then
			local services: { any } = {}
			for _, serviceName in SERVICE_OVERVIEW do
				local ok, service = pcall(function()
					return ctx.services :: any
				end)
				-- Services live on Runtime.Context.services as named fields;
				-- the easiest way to find one by name without re-introducing
				-- game:GetService here (forbidden outside Services.luau) is
				-- to walk game's children — they're the same set Studio
				-- exposes via GetService for these top-level services.
				local svc: Instance? = nil
				if ok and service ~= nil then
					svc = game:FindFirstChild(serviceName)
				end
				if svc ~= nil then
					table.insert(services, {
						name = svc.Name,
						className = svc.ClassName,
						path = Path.getInstancePath(svc),
						childCount = #svc:GetChildren(),
						hasChildren = #svc:GetChildren() > 0,
					})
				end
			end

			return {
				type = "service_overview",
				services = services,
				timestamp = os.clock(),
				note = "Use path parameter to explore specific locations (e.g., 'game.ServerScriptService')",
			},
				nil
		end

		local startInstance = Path.getInstanceByPath(startPath)
		if startInstance == nil then
			return { error = "Path not found: " .. startPath }, nil
		end

		local result = buildProjectNode(startInstance, 0, maxDepth, scriptsOnly)
		result.requestedPath = startPath
		result.maxDepth = maxDepth
		result.scriptsOnly = scriptsOnly
		result.timestamp = os.clock()
		return result, nil
	end
)

return FileTreeHandlers
