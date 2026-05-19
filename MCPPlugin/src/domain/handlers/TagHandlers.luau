--!strict
-- domain/handlers/TagHandlers.luau
--
-- CollectionService tag inspection. Phase 3 ships the READ half only:
--   - getTags    ← legacy plugin.luau L4802-4828
--   - getTagged  ← legacy plugin.luau L4901-4933
--
-- The mutating siblings (addTag, removeTag — legacy L4831-4898) ship in
-- Phase 4 and will live in this same module.
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

return TagHandlers
