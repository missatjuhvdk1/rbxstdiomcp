--!strict
-- domain/handlers/TagHandlers.luau
--
-- CollectionService tag read + write. Four endpoints:
--   - getTags    ← legacy plugin.luau L4802-4828  (read, Phase 3)
--   - getTagged  ← legacy plugin.luau L4901-4933  (read, Phase 3)
--   - addTag     ← legacy plugin.luau L4831-4868  (write, Phase 4)
--   - removeTag  ← legacy plugin.luau L4870-4898  (write, Phase 4)
--
-- ============================================================================
-- LLM-STOMP NOTE
-- ============================================================================
-- The test-companion protection works by tag (TEST_COMPANION_TAG), so the
-- naive read of "destructive tag ops should refuse companion instances"
-- would make it impossible for the plugin to set up its own companion at
-- test-start. We compromise: addTag / removeTag refuse only when an LLM
-- tries to ADD or REMOVE the SPECIFIC companion tag (TEST_COMPANION_TAG).
-- Other tags on the companion instance are fair game; that lets the AI
-- categorise the companion for diagnostics without breaking the protection
-- predicate.
--
-- ============================================================================
-- WHY collectionService FLOWS THROUGH ctx INSTEAD OF DIRECT IMPORT
-- ============================================================================
-- ARCHITECTURE §4.3 / §15 A3: `game:GetService` lives only in
-- runtime/Services.luau. Every other module accesses Studio services
-- through `ctx.services.<name>`. That's why these handlers read
-- `ctx.services.collectionService` rather than the legacy's bare
-- `CollectionService` global.

local Handler = require(script.Parent.Parent.handler.Handler)
local Path = require(script.Parent.Parent.Parent.runtime.instance.Path)

-- ============================================================================
-- TYPED REQUEST/RESPONSE SHAPES
-- ============================================================================

type GetTagsRequest = {
	instancePath: string?,
}

type GetTaggedRequest = {
	tagName: string?,
}

type AddTagRequest = {
	instancePath: string?,
	tagName: string?,
}

type RemoveTagRequest = {
	instancePath: string?,
	tagName: string?,
}

-- ============================================================================
-- HANDLERS
-- ============================================================================

local TagHandlers = {}

-- getTags: list every tag CollectionService has bound to an instance.
-- Legacy L4802-4828.
TagHandlers.getTags = Handler.define("/api/get-tags", function(ctx, data: GetTagsRequest): (any, Handler.RecordResult?)
	local instancePath = data.instancePath
	if instancePath == nil then
		return { error = "Instance path is required" }, nil
	end

	local instance = Path.getInstanceByPath(instancePath)
	if instance == nil then
		return { error = "Instance not found: " .. instancePath }, nil
	end

	local ok, result = pcall(function()
		local tags = ctx.services.collectionService:GetTags(instance)
		return {
			instancePath = instancePath,
			tags = tags,
			count = #tags,
		}
	end)

	if ok then
		return result, nil
	else
		return { error = "Failed to get tags: " .. tostring(result) }, nil
	end
end)

-- getTagged: list every instance carrying a given tag. Legacy L4901-4933.
-- The result is a flat list of { name, className, path } so the AI can
-- pick targets without a follow-up getInstancePath call.
TagHandlers.getTagged = Handler.define(
	"/api/get-tagged",
	function(ctx, data: GetTaggedRequest): (any, Handler.RecordResult?)
		local tagName = data.tagName
		if tagName == nil then
			return { error = "Tag name is required" }, nil
		end

		local ok, result = pcall(function()
			local taggedInstances = ctx.services.collectionService:GetTagged(tagName)
			local instances: { any } = {}
			for _, instance in taggedInstances do
				table.insert(instances, {
					name = instance.Name,
					className = instance.ClassName,
					path = Path.getInstancePath(instance),
				})
			end

			return {
				tagName = tagName,
				instances = instances,
				count = #instances,
			}
		end)

		if ok then
			return result, nil
		else
			return { error = "Failed to get tagged instances: " .. tostring(result) }, nil
		end
	end
)

-- addTag: bind a CollectionService tag to one instance. Legacy L4831-4868.
-- No-op if the tag is already present (CollectionService:AddTag is idempotent
-- but we want to return didMutate=false so the dispatcher cancels the CHS
-- waypoint).
TagHandlers.addTag = Handler.define("/api/add-tag", function(ctx, data: AddTagRequest): (any, Handler.RecordResult?)
	local instancePath = data.instancePath
	local tagName = data.tagName

	if instancePath == nil or tagName == nil then
		return { error = "Instance path and tag name are required" }, nil
	end

	-- LLM-stomp: refuse to apply the companion tag from a non-plugin
	-- caller. The companion tag is owned by runtime/testsession.
	if tagName == ctx.constants.TEST_COMPANION_TAG then
		return {
			error = "Refusing to apply "
				.. tagName
				.. " — that tag is reserved for the MCP test-companion machinery.",
			refused = true,
		},
			nil
	end

	local instance = Path.getInstanceByPath(instancePath)
	if instance == nil then
		return { error = "Instance not found: " .. instancePath }, nil
	end

	local collectionService = ctx.services.collectionService

	local okProbe, alreadyHas = pcall(function()
		return collectionService:HasTag(instance, tagName :: string)
	end)
	if okProbe and alreadyHas then
		return {
			success = true,
			instancePath = instancePath,
			tagName = tagName,
			message = "Tag already present; no change made",
		}, {
			name = "Add Tag: " .. (tagName :: string),
			didMutate = false,
		}
	end

	local ok, err = pcall(function()
		collectionService:AddTag(instance, tagName :: string)
	end)
	if not ok then
		return {
			error = "Failed to add tag: " .. tostring(err),
			instancePath = instancePath,
			tagName = tagName,
		},
			nil
	end

	ctx.actionLog:stage(
		"add_tag",
		instancePath,
		string.format("Added tag '%s' to %s", tagName :: string, instancePath),
		{ tagName = tagName }
	)

	return {
		success = true,
		instancePath = instancePath,
		tagName = tagName,
		message = "Tag added successfully",
	}, {
		name = "Add Tag: " .. (tagName :: string),
		didMutate = true,
	}
end)

-- removeTag: clear a tag from one instance. Legacy L4870-4898.
-- Refuses removal of the companion tag (would un-protect a companion mid-
-- session).
TagHandlers.removeTag = Handler.define(
	"/api/remove-tag",
	function(ctx, data: RemoveTagRequest): (any, Handler.RecordResult?)
		local instancePath = data.instancePath
		local tagName = data.tagName

		if instancePath == nil or tagName == nil then
			return { error = "Instance path and tag name are required" }, nil
		end

		if tagName == ctx.constants.TEST_COMPANION_TAG then
			return {
				error = "Refusing to remove "
					.. tagName
					.. " — that tag protects the MCP test companion from accidental mutation.",
				refused = true,
			},
				nil
		end

		local instance = Path.getInstanceByPath(instancePath)
		if instance == nil then
			return { error = "Instance not found: " .. instancePath }, nil
		end

		local collectionService = ctx.services.collectionService

		local okProbe, hasTag = pcall(function()
			return collectionService:HasTag(instance, tagName :: string)
		end)
		if okProbe and not hasTag then
			return {
				success = true,
				instancePath = instancePath,
				tagName = tagName,
				message = "Tag was not present; no change made",
			}, {
				name = "Remove Tag: " .. (tagName :: string),
				didMutate = false,
			}
		end

		local ok, err = pcall(function()
			collectionService:RemoveTag(instance, tagName :: string)
		end)
		if not ok then
			return {
				error = "Failed to remove tag: " .. tostring(err),
				instancePath = instancePath,
				tagName = tagName,
			},
				nil
		end

		ctx.actionLog:stage(
			"remove_tag",
			instancePath,
			string.format("Removed tag '%s' from %s", tagName :: string, instancePath),
			{ tagName = tagName }
		)

		return {
			success = true,
			instancePath = instancePath,
			tagName = tagName,
			message = "Tag removed successfully",
		}, {
			name = "Remove Tag: " .. (tagName :: string),
			didMutate = true,
		}
	end
)

return TagHandlers
