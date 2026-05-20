--!strict
-- domain/handlers/HierarchyHandlers.luau
--
-- Phase 4 — clone & re-parent. Two endpoints:
--   - cloneInstance ← legacy plugin.luau L5042-5093
--   - moveInstance  ← legacy plugin.luau L5095-5151
--
-- ============================================================================
-- WHY THESE TWO LIVE TOGETHER (NOT IN CREATIONHANDLERS)
-- ============================================================================
-- Both manipulate the existing-tree-shape (re-parent / clone-and-parent) but
-- with one key difference from the create_object family: they operate on an
-- ALREADY-EXISTING instance, not an Instance.new() call. The legacy file
-- handled them with a different code path (no className arg, no property
-- bag, no name pattern resolution) and we preserve that split.
--
-- The mass_* variants of these live in CreationHandlers as smart_duplicate /
-- mass_duplicate — the API surface there is the user-facing "I want N
-- copies" shape; cloneInstance is the lower-level "give me exactly one
-- clone" primitive.
--
-- ============================================================================
-- LLM-STOMP PROTECTION
-- ============================================================================
-- cloneInstance:
--   - Refuses if SOURCE is protected (would split the log pipeline).
--   - Refuses if destination PARENT is protected (would hide hostile content
--     under the companion folder).
-- moveInstance:
--   - Refuses if SOURCE is protected (moving the companion mid-playtest
--     could detach it from its watcher).
--   - Refuses if destination PARENT is protected.
--
-- ============================================================================
-- WHY NEITHER HANDLER STAGES AN ACTIONLOG ENTRY
-- ============================================================================
-- Mirrors legacy behaviour: clone and move are recorded by CHS (one
-- waypoint each, Ctrl+Z reverts them) but are NOT logged to action history.
-- The rationale matches PropertyHandlers' mass-set: action history exists
-- for human introspection ("what did the AI just change?") and clone/move
-- of a single instance is the most common operation an agent does during
-- iterative refinement — every action entry would be drowned in noise.
-- If a future schema version wants to surface these, the change is one
-- ctx.actionLog:stage(...) call per handler.

local Handler = require(script.Parent.Parent.handler.Handler)
local Path = require(script.Parent.Parent.Parent.runtime.instance.Path)
local Companions = require(script.Parent.Parent.Parent.runtime.testsession.Companions)

-- ============================================================================
-- TYPED REQUEST SHAPES
-- ============================================================================

type CloneInstanceRequest = {
	instancePath: string?,
	parentPath: string?,
	name: string?,
}

type MoveInstanceRequest = {
	instancePath: string?,
	parentPath: string?,
}

-- ============================================================================
-- HANDLERS
-- ============================================================================

local HierarchyHandlers = {}

-- cloneInstance: deep-copy ONE source under ONE parent. Legacy L5042-5093.
-- If parentPath is omitted, the clone lands next to the source (same parent).
-- Optional `name` overrides the default "<sourceName>" copy name.
HierarchyHandlers.cloneInstance = Handler.define(
	"/api/clone-instance",
	function(ctx, data: CloneInstanceRequest): (any, Handler.RecordResult?)
		local instancePath = data.instancePath
		local parentPath = data.parentPath
		local name = data.name

		if instancePath == nil then
			return { error = "Instance path is required" }, nil
		end

		local source = Path.getInstanceByPath(instancePath)
		if source == nil then
			return { error = "Source not found: " .. instancePath }, nil
		end

		local deps = { services = ctx.services, constants = ctx.constants }
		local sourceRefusal = Companions.refuseIfProtected(deps, source)
		if sourceRefusal ~= nil then
			return sourceRefusal, nil
		end

		-- Default destination = source's parent. Required because the
		-- source might be orphaned (we still want a clear error in that case).
		local destination: Instance
		if parentPath ~= nil and parentPath ~= "" then
			local resolved = Path.getInstanceByPath(parentPath :: string)
			if resolved == nil then
				return { error = "Parent not found: " .. (parentPath :: string) }, nil
			end
			destination = resolved
		else
			local sourceParent = source.Parent
			if sourceParent == nil then
				return { error = "Source has no parent and no parentPath was provided" }, nil
			end
			destination = sourceParent
		end

		local destRefusal = Companions.refuseIfProtected(deps, destination)
		if destRefusal ~= nil then
			return destRefusal, nil
		end

		local okClone, clone = pcall(function()
			return source:Clone()
		end)
		if not okClone or clone == nil then
			return {
				error = "Failed to clone: " .. tostring(clone),
				instancePath = instancePath,
			}, nil
		end
		local cloneInstance = clone :: Instance

		if name ~= nil then
			pcall(function()
				cloneInstance.Name = name :: string
			end)
		end

		local okParent, parentErr = pcall(function()
			cloneInstance.Parent = destination
		end)
		if not okParent then
			pcall(function()
				cloneInstance:Destroy()
			end)
			return {
				error = "Failed to set parent: " .. tostring(parentErr),
				instancePath = instancePath,
				parentPath = parentPath,
			},
				nil
		end

		return {
			success = true,
			source = instancePath,
			clonePath = Path.getInstancePath(cloneInstance),
			name = cloneInstance.Name,
			parent = Path.getInstancePath(destination),
		}, {
			name = string.format("Clone %s", source.ClassName),
			didMutate = true,
		}
	end
)

-- moveInstance: re-parent ONE instance. Legacy L5095-5151.
-- Refuses cycles (parenting an instance inside its own descendants) by
-- walking the destination's ancestry; Roblox would catch this at assign
-- time too, but a pre-check yields a clearer error.
HierarchyHandlers.moveInstance = Handler.define(
	"/api/move-instance",
	function(ctx, data: MoveInstanceRequest): (any, Handler.RecordResult?)
		local instancePath = data.instancePath
		local parentPath = data.parentPath

		if instancePath == nil or parentPath == nil then
			return { error = "instancePath and parentPath are required" }, nil
		end

		local instance = Path.getInstanceByPath(instancePath)
		if instance == nil then
			return { error = "Instance not found: " .. instancePath }, nil
		end

		if instance == game then
			return { error = "Refusing to re-parent the game DataModel" }, nil
		end

		local newParent = Path.getInstanceByPath(parentPath)
		if newParent == nil then
			return { error = "Parent not found: " .. parentPath }, nil
		end

		local deps = { services = ctx.services, constants = ctx.constants }
		local sourceRefusal = Companions.refuseIfProtected(deps, instance)
		if sourceRefusal ~= nil then
			return sourceRefusal, nil
		end
		local destRefusal = Companions.refuseIfProtected(deps, newParent)
		if destRefusal ~= nil then
			return destRefusal, nil
		end

		-- Cycle check: walking newParent's ancestry must not hit `instance`.
		-- Roblox throws at assignment time too, but we get a cleaner error.
		local current: Instance? = newParent
		while current ~= nil do
			if current == instance then
				return {
					error = "Refusing to move " .. instancePath .. " inside its own descendants (" .. parentPath .. ")",
				},
					nil
			end
			current = (current :: Instance).Parent
		end

		local oldParent = instance.Parent
		local oldParentPath = if oldParent ~= nil then Path.getInstancePath(oldParent) else "<orphan>"

		local ok, err = pcall(function()
			instance.Parent = newParent
		end)
		if not ok then
			return {
				error = "Failed to re-parent: " .. tostring(err),
				instancePath = instancePath,
				parentPath = parentPath,
			},
				nil
		end

		return {
			success = true,
			instancePath = instancePath,
			newPath = Path.getInstancePath(instance),
			oldParent = oldParentPath,
			newParent = parentPath,
		}, {
			name = string.format("Move %s", instance.ClassName),
			didMutate = true,
		}
	end
)

return HierarchyHandlers
