--!strict
-- domain/handlers/CreationHandlers.luau
--
-- Phase 4 — instance creation / deletion / duplication / asset insertion.
-- Seven endpoints:
--   - createObject                    ← legacy plugin.luau L2807-2906
--   - massCreateObjects               ← legacy plugin.luau L3014-3060
--   - massCreateObjectsWithProperties ← legacy plugin.luau L3062-3168 (the
--                                       only multi-property creation tool;
--                                       there is NO separate
--                                       create_object_with_properties)
--   - deleteObject                    ← legacy plugin.luau L3170-3275
--   - smartDuplicate                  ← legacy plugin.luau L5781-5868
--   - massDuplicate                   ← legacy plugin.luau L5870-5921
--   - insertAsset                     ← legacy plugin.luau L3277-3410
--
-- ============================================================================
-- WHY CREATE / DELETE / DUPLICATE LIVE IN ONE MODULE
-- ============================================================================
-- They're the "tree-shape mutation" family. They all:
--   1. Take a parent path (or array of them) as the dominant input,
--   2. Allocate or free Instance refs (and so are the hot path for memory
--      leaks if a handler forgets to :Destroy on the error path),
--   3. Need the same Companions refusal predicate to keep an over-eager AI
--      from deleting the test companion or parenting under it.
-- Keeping them in one module means the protections and parent-resolution
-- helpers live next to all their callers, not in a util module no one
-- thinks to update.
--
-- ============================================================================
-- LLM-STOMP PROTECTION
-- ============================================================================
-- The legacy plugin.luau (L48-53) DOCUMENTED a "destructive tools refuse to
-- operate on companion instances" intent but an audit shows it was NEVER
-- actually implemented. Phase 4 closes the gap here:
--   - createObject / massCreate*: refuse if the resolved PARENT is a
--     protected instance (an AI could otherwise stuff hostile children
--     inside the companion folder).
--   - deleteObject: refuse if the resolved TARGET is protected (also refuses
--     `instance == game`, the other obvious foot-gun).
--   - smartDuplicate / massDuplicate: refuse if the SOURCE is protected
--     (duplicating the companion would split the log pipeline) AND if any
--     destination parent in `targetParents` is protected.
--
-- ============================================================================
-- PROPERTY-VS-PARENT ORDERING
-- ============================================================================
-- Two quirks preserved verbatim from legacy:
--   1. createObject sets the `properties` table BEFORE setting Parent (legacy
--      L2879). Parts created with both Size and CFrame and then parented are
--      one frame less likely to be visible in the wrong place.
--   2. massCreateObjectsWithProperties sets Parent FIRST and properties AFTER
--      (legacy L3133-3141). This is the inverse and is the legacy behaviour:
--      because the batch endpoint may set properties that depend on the
--      parent's CFrame (e.g. WorldPosition on an Attachment).
-- The asymmetry is intentional and bug-compatible. Future cleanup should
-- pick one ordering and version the wire schema; until then, mirror legacy.
--
-- ============================================================================
-- WHY DUPLICATE IS A SINGLE CHS RECORDING
-- ============================================================================
-- smartDuplicate may clone an instance N times. The legacy file wrapped the
-- entire loop in one CHS recording so Ctrl+Z reverts the whole batch (one
-- waypoint, not N). We preserve this: the handler returns one RecordResult
-- with didMutate = (anyCloneSucceeded), and the dispatcher records once.
-- The same applies to mass_duplicate (which iterates N smart_duplicates).

local Handler = require(script.Parent.Parent.handler.Handler)
local Path = require(script.Parent.Parent.Parent.runtime.instance.Path)
local Convert = require(script.Parent.Parent.Parent.runtime.instance.Convert)
local Companions = require(script.Parent.Parent.Parent.runtime.testsession.Companions)

-- ============================================================================
-- TYPED REQUEST SHAPES
-- ============================================================================

type CreateObjectRequest = {
	className: string?,
	parent: string?,
	name: string?,
	properties: { [string]: any }?,
}

type MassCreateObjectsRequest = {
	className: string?,
	parent: string?,
	count: number?,
	namePattern: string?,
}

type MassCreateWithPropertiesRequest = {
	objects: { MassCreateObjectEntry }?,
}

type MassCreateObjectEntry = {
	className: string?,
	parent: string?,
	name: string?,
	properties: { [string]: any }?,
}

type DeleteObjectRequest = {
	instancePath: string?,
}

type SmartDuplicateRequest = {
	instancePath: string?,
	count: number?,
	options: SmartDuplicateOptions?,
}

type SmartDuplicateOptions = {
	namePattern: string?,
	positionOffset: any?,
	rotationOffset: any?,
	scaleOffset: any?,
	propertyVariations: { [string]: any }?,
	targetParents: { string }?,
}

type MassDuplicateRequest = {
	requests: { SmartDuplicateRequest }?,
}

type InsertAssetRequest = {
	assetId: (number | string)?,
	parentPath: string?,
	name: string?,
}

-- ============================================================================
-- INTERNAL HELPERS
-- ============================================================================

-- Apply a property table to a freshly-created instance. We route each entry
-- through Convert.fromWire so vector/color/enum shorthand works. Errors are
-- per-property — one bad property doesn't kill the create.
local function applyProperties(
	instance: Instance,
	properties: { [string]: any }
): { propertiesSet: { [string]: any }, propertiesFailed: { [string]: string } }
	local propertiesSet: { [string]: any } = {}
	local propertiesFailed: { [string]: string } = {}

	for propertyName, propertyValue in properties do
		-- Name is the only "string property that's always a string" we
		-- special-case before Convert — Convert would happily accept a
		-- string and route it through the bool/enum shorthand paths.
		if propertyName == "Name" then
			local strVal = tostring(propertyValue)
			local ok, err = pcall(function()
				(instance :: any).Name = strVal
			end)
			if ok then
				propertiesSet[propertyName] = strVal
			else
				propertiesFailed[propertyName] = tostring(err)
			end
			continue
		end

		-- Parent in a property bag refers to a path string (same convention
		-- as set_property). Resolve and assign separately.
		if propertyName == "Parent" then
			if type(propertyValue) ~= "string" then
				propertiesFailed[propertyName] = "Parent must be a string path"
				continue
			end
			local target = Path.getInstanceByPath(propertyValue :: string)
			if target == nil then
				propertiesFailed[propertyName] = "Parent instance not found: " .. (propertyValue :: string)
				continue
			end
			local ok, err = pcall(function()
				instance.Parent = target
			end)
			if ok then
				propertiesSet[propertyName] = propertyValue
			else
				propertiesFailed[propertyName] = tostring(err)
			end
			continue
		end

		local converted = Convert.fromWire(instance, propertyName, propertyValue)
		if converted == nil then
			converted = propertyValue
		end

		local ok, err = pcall(function()
			(instance :: any)[propertyName] = converted
		end)
		if ok then
			propertiesSet[propertyName] = propertyValue
		else
			propertiesFailed[propertyName] = tostring(err)
		end
	end

	return { propertiesSet = propertiesSet, propertiesFailed = propertiesFailed }
end

-- Coerce a wire value that may be either { X = .., Y = .., Z = .. } or
-- { x, y, z } or a plain Vector3 into Vector3. Returns nil if it can't.
local function asVector3(value: any): Vector3?
	if value == nil then
		return nil
	end
	if typeof(value) == "Vector3" then
		return value
	end
	if type(value) == "table" then
		if value.X ~= nil or value.Y ~= nil or value.Z ~= nil then
			return Vector3.new(value.X or 0, value.Y or 0, value.Z or 0)
		end
		if #value >= 3 then
			return Vector3.new(value[1] or 0, value[2] or 0, value[3] or 0)
		end
	end
	return nil
end

-- Apply per-clone offsets to a BasePart-or-Model clone. Mirrors legacy
-- L5800-5848. All four offsets are optional and silently no-op when the
-- target instance doesn't support the corresponding property (e.g. a Folder
-- has no Position).
local function applyCloneOffsets(clone: Instance, options: SmartDuplicateOptions, index: number)
	local cloneIndex = index - 1 -- 0-based so the FIRST clone gets the
	-- original's position when offset is 0; mirrors legacy.

	local posOff = asVector3(options.positionOffset)
	if posOff ~= nil then
		pcall(function()
			if clone:IsA("BasePart") then
				(clone :: BasePart).Position = (clone :: BasePart).Position + posOff * cloneIndex
			elseif clone:IsA("Model") then
				local model = clone :: Model
				local primary = model.PrimaryPart
				if primary ~= nil then
					model:PivotTo(primary.CFrame + posOff * cloneIndex)
				end
			end
		end)
	end

	local rotOff = asVector3(options.rotationOffset)
	if rotOff ~= nil then
		pcall(function()
			local degToRad = math.pi / 180
			local rx = rotOff.X * cloneIndex * degToRad
			local ry = rotOff.Y * cloneIndex * degToRad
			local rz = rotOff.Z * cloneIndex * degToRad
			if clone:IsA("BasePart") then
				local part = clone :: BasePart
				part.CFrame = part.CFrame * CFrame.Angles(rx, ry, rz)
			elseif clone:IsA("Model") then
				local model = clone :: Model
				model:PivotTo(model:GetPivot() * CFrame.Angles(rx, ry, rz))
			end
		end)
	end

	local scaleOff = asVector3(options.scaleOffset)
	if scaleOff ~= nil then
		pcall(function()
			if clone:IsA("BasePart") then
				local part = clone :: BasePart
				part.Size = part.Size + scaleOff * cloneIndex
			end
		end)
	end

	-- Per-property variations: each entry is either a single value (applied
	-- as-is to every clone) or an array indexed by clone index.
	if options.propertyVariations ~= nil then
		for propertyName, variation in options.propertyVariations :: { [string]: any } do
			local valueForThisClone: any
			if type(variation) == "table" and #variation > 0 then
				valueForThisClone = variation[(cloneIndex % #variation) + 1]
			else
				valueForThisClone = variation
			end
			local converted = Convert.fromWire(clone, propertyName, valueForThisClone)
			if converted == nil then
				converted = valueForThisClone
			end
			pcall(function()
				(clone :: any)[propertyName] = converted
			end)
		end
	end
end

-- Resolve a name pattern with {index} / {name} substitutions. Used by
-- mass_create_objects and smart_duplicate.
local function resolveNamePattern(pattern: string?, originalName: string, index: number): string
	if pattern == nil or pattern == "" then
		return originalName .. "_" .. tostring(index)
	end
	local out = pattern
	out = out:gsub("{index}", tostring(index))
	out = out:gsub("{name}", originalName)
	return out
end

-- ============================================================================
-- HANDLERS
-- ============================================================================

local CreationHandlers = {}

-- createObject: one Instance under one Parent. Legacy L2807-2906.
-- LLM-stomp: refuses if `parent` resolves to a protected instance.
CreationHandlers.createObject = Handler.define(
	"/api/create-object",
	function(ctx, data: CreateObjectRequest): (any, Handler.RecordResult?)
		local className = data.className
		local parentPath = data.parent
		local name = data.name
		local properties = data.properties

		if className == nil or parentPath == nil then
			return { error = "className and parent are required" }, nil
		end

		local parent = Path.getInstanceByPath(parentPath)
		if parent == nil then
			return { error = "Parent not found: " .. parentPath }, nil
		end

		-- LLM-stomp: refuse to create children inside a companion subtree.
		local refusal = Companions.refuseIfProtected({
			services = ctx.services,
			constants = ctx.constants,
		}, parent)
		if refusal ~= nil then
			return refusal, nil
		end

		local okNew, newInstance = pcall(function()
			return Instance.new(className :: string)
		end)
		if not okNew then
			return { error = "Failed to create " .. (className :: string) .. ": " .. tostring(newInstance) }, nil
		end
		local instance = newInstance :: Instance

		-- Optional Name. Apply BEFORE properties so a property-failure
		-- error message references the right name.
		if name ~= nil then
			pcall(function()
				instance.Name = name :: string
			end)
		end

		-- Apply properties BEFORE parenting (legacy quirk; see header).
		local applied = { propertiesSet = {} :: { [string]: any }, propertiesFailed = {} :: { [string]: string } }
		if properties ~= nil then
			applied = applyProperties(instance, properties :: { [string]: any })
		end

		-- Now parent. If parenting fails, Destroy() the orphan so we don't
		-- leak instance refs into the data model.
		local okParent, parentErr = pcall(function()
			instance.Parent = parent
		end)
		if not okParent then
			pcall(function()
				instance:Destroy()
			end)
			return {
				error = "Failed to set parent: " .. tostring(parentErr),
				className = className,
				name = name,
				parent = parentPath,
			},
				nil
		end

		local newPath = Path.getInstancePath(instance)
		local finalName = instance.Name
		ctx.actionLog:stage(
			"create_object",
			newPath,
			string.format("Created %s '%s'", className :: string, finalName),
			{ className = className, parent = parentPath }
		)

		return {
			success = true,
			path = newPath,
			className = className,
			name = finalName,
			parent = parentPath,
			propertiesSet = applied.propertiesSet,
			propertiesFailed = applied.propertiesFailed,
		}, {
			name = "Create " .. (className :: string),
			didMutate = true,
		}
	end
)

-- massCreateObjects: N instances of the SAME className, all under one Parent.
-- Legacy L3014-3060. No per-object properties; use mass_create_with_properties
-- if you need that.
CreationHandlers.massCreateObjects = Handler.define(
	"/api/mass-create-objects",
	function(ctx, data: MassCreateObjectsRequest): (any, Handler.RecordResult?)
		local className = data.className
		local parentPath = data.parent
		local count = data.count
		local namePattern = data.namePattern

		if className == nil or parentPath == nil or count == nil then
			return { error = "className, parent, and count are required" }, nil
		end
		if (count :: number) < 1 then
			return { error = "count must be >= 1" }, nil
		end
		if (count :: number) > 1000 then
			return { error = "count exceeds maximum (1000) — split into multiple requests" }, nil
		end

		local parent = Path.getInstanceByPath(parentPath)
		if parent == nil then
			return { error = "Parent not found: " .. parentPath }, nil
		end

		local refusal = Companions.refuseIfProtected({
			services = ctx.services,
			constants = ctx.constants,
		}, parent)
		if refusal ~= nil then
			return refusal, nil
		end

		local results: { any } = {}
		local successCount = 0
		local failCount = 0

		for i = 1, count :: number do
			local okNew, newInstance = pcall(function()
				return Instance.new(className :: string)
			end)
			if not okNew then
				table.insert(results, {
					index = i,
					success = false,
					error = "Failed to create " .. (className :: string) .. ": " .. tostring(newInstance),
				})
				failCount += 1
				continue
			end
			local instance = newInstance :: Instance

			local resolvedName = resolveNamePattern(namePattern, className :: string, i)
			pcall(function()
				instance.Name = resolvedName
			end)

			local okParent, parentErr = pcall(function()
				instance.Parent = parent
			end)
			if not okParent then
				pcall(function()
					instance:Destroy()
				end)
				table.insert(results, {
					index = i,
					success = false,
					error = "Failed to set parent: " .. tostring(parentErr),
				})
				failCount += 1
				continue
			end

			table.insert(results, {
				index = i,
				success = true,
				path = Path.getInstancePath(instance),
				name = instance.Name,
			})
			successCount += 1
		end

		return {
			results = results,
			summary = {
				total = count,
				succeeded = successCount,
				failed = failCount,
			},
			className = className,
			parent = parentPath,
		}, {
			name = string.format("Mass Create %d × %s", count :: number, className :: string),
			didMutate = successCount > 0,
		}
	end
)

-- massCreateObjectsWithProperties: heterogeneous batch — each entry has its
-- own className/parent/properties. Legacy L3062-3168.
-- Parent is set FIRST, properties AFTER (legacy quirk; see header).
CreationHandlers.massCreateObjectsWithProperties = Handler.define(
	"/api/mass-create-objects-with-properties",
	function(ctx, data: MassCreateWithPropertiesRequest): (any, Handler.RecordResult?)
		local objects = data.objects

		if objects == nil or #objects == 0 then
			return { error = "objects array is required and must be non-empty" }, nil
		end
		if #objects > 500 then
			return { error = "objects array exceeds maximum (500) — split into multiple requests" }, nil
		end

		local results: { any } = {}
		local successCount = 0
		local failCount = 0

		for i, entry in objects :: { MassCreateObjectEntry } do
			local className = entry.className
			local parentPath = entry.parent
			local entryName = entry.name
			local properties = entry.properties

			if className == nil or parentPath == nil then
				table.insert(
					results,
					{ index = i, success = false, error = "className and parent are required per entry" }
				)
				failCount += 1
				continue
			end

			local parent = Path.getInstanceByPath(parentPath)
			if parent == nil then
				table.insert(results, {
					index = i,
					success = false,
					error = "Parent not found: " .. parentPath,
				})
				failCount += 1
				continue
			end

			local protection = Companions.isProtected({
				services = ctx.services,
				constants = ctx.constants,
			}, parent)
			if protection.protected then
				table.insert(results, {
					index = i,
					success = false,
					error = protection.reason,
					refused = true,
				})
				failCount += 1
				continue
			end

			local okNew, newInstance = pcall(function()
				return Instance.new(className :: string)
			end)
			if not okNew then
				table.insert(results, {
					index = i,
					success = false,
					error = "Failed to create: " .. tostring(newInstance),
				})
				failCount += 1
				continue
			end
			local instance = newInstance :: Instance

			if entryName ~= nil then
				pcall(function()
					instance.Name = entryName :: string
				end)
			end

			-- Parent FIRST (legacy L3133-3141 quirk).
			local okParent, parentErr = pcall(function()
				instance.Parent = parent
			end)
			if not okParent then
				pcall(function()
					instance:Destroy()
				end)
				table.insert(results, {
					index = i,
					success = false,
					error = "Failed to set parent: " .. tostring(parentErr),
				})
				failCount += 1
				continue
			end

			-- Properties AFTER parent (legacy quirk).
			local applied = { propertiesSet = {} :: { [string]: any }, propertiesFailed = {} :: { [string]: string } }
			if properties ~= nil then
				applied = applyProperties(instance, properties :: { [string]: any })
			end

			table.insert(results, {
				index = i,
				success = true,
				path = Path.getInstancePath(instance),
				className = className,
				name = instance.Name,
				propertiesSet = applied.propertiesSet,
				propertiesFailed = applied.propertiesFailed,
			})
			successCount += 1
		end

		return {
			results = results,
			summary = {
				total = #(objects :: { MassCreateObjectEntry }),
				succeeded = successCount,
				failed = failCount,
			},
		}, {
			name = string.format("Mass Create %d objects", #(objects :: { MassCreateObjectEntry })),
			didMutate = successCount > 0,
		}
	end
)

-- deleteObject: remove ONE instance. Legacy L3170-3275.
-- Refuses `instance == game`, refuses companion-protected instances.
CreationHandlers.deleteObject = Handler.define(
	"/api/delete-object",
	function(ctx, data: DeleteObjectRequest): (any, Handler.RecordResult?)
		local instancePath = data.instancePath

		if instancePath == nil then
			return { error = "Instance path is required" }, nil
		end

		local instance = Path.getInstanceByPath(instancePath)
		if instance == nil then
			return { error = "Instance not found: " .. instancePath }, nil
		end

		if instance == game then
			return { error = "Refusing to delete the game DataModel" }, nil
		end

		-- LLM-stomp: refuse to delete companions or descendants.
		local refusal = Companions.refuseIfProtected({
			services = ctx.services,
			constants = ctx.constants,
		}, instance)
		if refusal ~= nil then
			return refusal, nil
		end

		-- Capture name/class BEFORE destruction for the action-log entry —
		-- post-Destroy the instance ref is unusable.
		local className = instance.ClassName
		local name = instance.Name

		local ok, err = pcall(function()
			(instance :: Instance):Destroy()
		end)
		if not ok then
			return {
				error = "Failed to delete: " .. tostring(err),
				instancePath = instancePath,
			}, nil
		end

		ctx.actionLog:stage(
			"delete_object",
			instancePath,
			string.format("Deleted %s '%s'", className, name),
			{ className = className, name = name }
		)

		return {
			success = true,
			instancePath = instancePath,
			className = className,
			name = name,
			message = "Object deleted successfully",
		}, {
			name = string.format("Delete %s", className),
			didMutate = true,
		}
	end
)

-- smartDuplicate: clone ONE source N times with optional per-clone offsets
-- and variations. Legacy L5781-5868.
-- LLM-stomp: refuses if source OR any targetParent is protected.
CreationHandlers.smartDuplicate = Handler.define(
	"/api/smart-duplicate",
	function(ctx, data: SmartDuplicateRequest): (any, Handler.RecordResult?)
		local instancePath = data.instancePath
		local count = data.count or 1
		local options = data.options or {}

		if instancePath == nil then
			return { error = "Instance path is required" }, nil
		end
		if count < 1 then
			return { error = "count must be >= 1" }, nil
		end
		if count > 500 then
			return { error = "count exceeds maximum (500)" }, nil
		end

		local source = Path.getInstanceByPath(instancePath)
		if source == nil then
			return { error = "Source not found: " .. instancePath }, nil
		end

		local deps = { services = ctx.services, constants = ctx.constants }

		-- LLM-stomp: refuse to clone the companion (would split the log pipeline).
		local sourceRefusal = Companions.refuseIfProtected(deps, source)
		if sourceRefusal ~= nil then
			return sourceRefusal, nil
		end

		-- Resolve target parents (one entry per clone, cycling). If empty,
		-- the source's own parent is used for every clone.
		local targetParents: { Instance } = {}
		if options.targetParents ~= nil and #(options.targetParents :: { string }) > 0 then
			for j, parentPath in options.targetParents :: { string } do
				local parent = Path.getInstanceByPath(parentPath)
				if parent == nil then
					return {
						error = string.format("targetParents[%d] not found: %s", j, parentPath),
					}, nil
				end
				local parentRefusal = Companions.refuseIfProtected(deps, parent)
				if parentRefusal ~= nil then
					return parentRefusal, nil
				end
				table.insert(targetParents, parent)
			end
		else
			local defaultParent = source.Parent
			if defaultParent == nil then
				return { error = "Source has no parent and no targetParents were provided" }, nil
			end
			table.insert(targetParents, defaultParent)
		end

		local results: { any } = {}
		local successCount = 0
		local failCount = 0

		for i = 1, count do
			local okClone, clone = pcall(function()
				return source:Clone()
			end)
			if not okClone or clone == nil then
				table.insert(results, {
					index = i,
					success = false,
					error = "Failed to clone: " .. tostring(clone),
				})
				failCount += 1
				continue
			end
			local cloneInstance = clone :: Instance

			-- Name pattern.
			local resolvedName = resolveNamePattern(options.namePattern, source.Name, i)
			pcall(function()
				cloneInstance.Name = resolvedName
			end)

			-- Per-clone offsets / variations.
			applyCloneOffsets(cloneInstance, options, i)

			-- Parent — cycle through targetParents.
			local targetParent = targetParents[((i - 1) % #targetParents) + 1]
			local okParent, parentErr = pcall(function()
				cloneInstance.Parent = targetParent
			end)
			if not okParent then
				pcall(function()
					cloneInstance:Destroy()
				end)
				table.insert(results, {
					index = i,
					success = false,
					error = "Failed to set parent: " .. tostring(parentErr),
				})
				failCount += 1
				continue
			end

			table.insert(results, {
				index = i,
				success = true,
				path = Path.getInstancePath(cloneInstance),
				name = cloneInstance.Name,
			})
			successCount += 1
		end

		return {
			results = results,
			summary = {
				total = count,
				succeeded = successCount,
				failed = failCount,
			},
			source = instancePath,
		}, {
			name = string.format("Smart Duplicate %d × %s", count, source.ClassName),
			didMutate = successCount > 0,
		}
	end
)

-- massDuplicate: an array of smart-duplicate requests, each run independently.
-- Legacy L5870-5921. One CHS recording covers the whole batch.
CreationHandlers.massDuplicate = Handler.define(
	"/api/mass-duplicate",
	function(ctx, data: MassDuplicateRequest): (any, Handler.RecordResult?)
		local requests = data.requests

		if requests == nil or #requests == 0 then
			return { error = "requests array is required and must be non-empty" }, nil
		end
		if #requests > 100 then
			return { error = "requests array exceeds maximum (100)" }, nil
		end

		local deps = { services = ctx.services, constants = ctx.constants }

		local batchResults: { any } = {}
		local totalSucceeded = 0
		local totalFailed = 0

		for i, request in requests :: { SmartDuplicateRequest } do
			local instancePath = request.instancePath
			local count = request.count or 1
			local options = request.options or {}

			if instancePath == nil then
				table.insert(batchResults, { index = i, success = false, error = "instancePath required" })
				totalFailed += count
				continue
			end

			local source = Path.getInstanceByPath(instancePath)
			if source == nil then
				table.insert(batchResults, { index = i, success = false, error = "Source not found: " .. instancePath })
				totalFailed += count
				continue
			end

			local sourceRefusal = Companions.refuseIfProtected(deps, source)
			if sourceRefusal ~= nil then
				table.insert(batchResults, {
					index = i,
					success = false,
					error = sourceRefusal.error,
					refused = true,
				})
				totalFailed += count
				continue
			end

			-- Resolve target parents for THIS sub-request.
			local targetParents: { Instance } = {}
			local targetResolveFailed: string? = nil
			if options.targetParents ~= nil and #(options.targetParents :: { string }) > 0 then
				for _, parentPath in options.targetParents :: { string } do
					local parent = Path.getInstanceByPath(parentPath)
					if parent == nil then
						targetResolveFailed = "targetParent not found: " .. parentPath
						break
					end
					local protection = Companions.isProtected(deps, parent)
					if protection.protected then
						targetResolveFailed = protection.reason
						break
					end
					table.insert(targetParents, parent)
				end
			else
				local defaultParent = source.Parent
				if defaultParent ~= nil then
					table.insert(targetParents, defaultParent)
				else
					targetResolveFailed = "Source has no parent and no targetParents were provided"
				end
			end

			if targetResolveFailed ~= nil then
				table.insert(batchResults, { index = i, success = false, error = targetResolveFailed })
				totalFailed += count
				continue
			end

			local subResults: { any } = {}
			local subSuccess = 0
			local subFail = 0
			for j = 1, count do
				local okClone, clone = pcall(function()
					return source:Clone()
				end)
				if not okClone or clone == nil then
					table.insert(subResults, {
						index = j,
						success = false,
						error = "Failed to clone: " .. tostring(clone),
					})
					subFail += 1
					continue
				end
				local cloneInstance = clone :: Instance
				local resolvedName = resolveNamePattern(options.namePattern, source.Name, j)
				pcall(function()
					cloneInstance.Name = resolvedName
				end)
				applyCloneOffsets(cloneInstance, options, j)
				local targetParent = targetParents[((j - 1) % #targetParents) + 1]
				local okParent, parentErr = pcall(function()
					cloneInstance.Parent = targetParent
				end)
				if not okParent then
					pcall(function()
						cloneInstance:Destroy()
					end)
					table.insert(subResults, {
						index = j,
						success = false,
						error = "Failed to set parent: " .. tostring(parentErr),
					})
					subFail += 1
					continue
				end
				table.insert(subResults, {
					index = j,
					success = true,
					path = Path.getInstancePath(cloneInstance),
					name = cloneInstance.Name,
				})
				subSuccess += 1
			end

			table.insert(batchResults, {
				index = i,
				success = subSuccess > 0,
				source = instancePath,
				results = subResults,
				summary = { total = count, succeeded = subSuccess, failed = subFail },
			})
			totalSucceeded += subSuccess
			totalFailed += subFail
		end

		return {
			batchResults = batchResults,
			summary = {
				totalRequests = #(requests :: { SmartDuplicateRequest }),
				totalSucceeded = totalSucceeded,
				totalFailed = totalFailed,
			},
		}, {
			name = string.format("Mass Duplicate (%d requests)", #(requests :: { SmartDuplicateRequest })),
			didMutate = totalSucceeded > 0,
		}
	end
)

-- insertAsset: pull an rbxasset by ID via game:GetObjects and parent it.
-- Legacy L3277-3410. Auto-creates folder parents on the silent fallback to
-- Workspace path; otherwise the bridge tolerates the assetId being a string
-- ("rbxassetid://...") or a bare number.
CreationHandlers.insertAsset = Handler.define(
	"/api/insert-asset",
	function(ctx, data: InsertAssetRequest): (any, Handler.RecordResult?)
		local assetId = data.assetId
		local parentPath = data.parentPath
		local name = data.name

		if assetId == nil then
			return { error = "assetId is required" }, nil
		end

		-- Coerce to "rbxassetid://N" string.
		local assetUri: string
		if type(assetId) == "number" then
			assetUri = "rbxassetid://" .. tostring(assetId)
		else
			local s = tostring(assetId)
			if s:find("^rbxassetid://") then
				assetUri = s
			else
				-- Number-as-string: prepend the protocol.
				assetUri = "rbxassetid://" .. s
			end
		end

		-- Resolve parent. Silent fallback to Workspace mirrors legacy.
		local parent: Instance
		if parentPath ~= nil and parentPath ~= "" then
			local resolved = Path.getInstanceByPath(parentPath :: string)
			if resolved == nil then
				return { error = "Parent not found: " .. (parentPath :: string) }, nil
			end
			parent = resolved
		else
			parent = workspace
		end

		local refusal = Companions.refuseIfProtected({
			services = ctx.services,
			constants = ctx.constants,
		}, parent)
		if refusal ~= nil then
			return refusal, nil
		end

		local okFetch, fetched = pcall(function()
			return game:GetObjects(assetUri)
		end)
		if not okFetch then
			return {
				error = "Failed to fetch asset: " .. tostring(fetched),
				assetId = assetId,
				parentPath = parentPath,
			},
				nil
		end

		local objects = fetched :: { Instance }
		if objects == nil or #objects == 0 then
			return {
				error = "No objects returned for asset " .. assetUri,
				assetId = assetId,
			}, nil
		end

		local inserted: { string } = {}
		for i, obj in objects do
			-- First object gets the optional name override; siblings keep
			-- their own names (matches legacy L3354 behaviour).
			if i == 1 and name ~= nil then
				pcall(function()
					obj.Name = name :: string
				end)
			end
			local okParent = pcall(function()
				obj.Parent = parent
			end)
			if okParent then
				table.insert(inserted, Path.getInstancePath(obj))
			else
				pcall(function()
					obj:Destroy()
				end)
			end
		end

		if #inserted == 0 then
			return {
				error = "Failed to parent any of the " .. tostring(#objects) .. " fetched objects",
				assetId = assetId,
			},
				nil
		end

		ctx.actionLog:stage(
			"insert_asset",
			inserted[1],
			string.format("Inserted asset %s into %s (%d objects)", assetUri, Path.getInstancePath(parent), #inserted),
			{ assetId = assetId, parentPath = Path.getInstancePath(parent) }
		)

		return {
			success = true,
			assetId = assetId,
			parentPath = Path.getInstancePath(parent),
			insertedPaths = inserted,
			count = #inserted,
		}, {
			name = string.format("Insert Asset (%d objects)", #inserted),
			didMutate = true,
		}
	end
)

return CreationHandlers
