--!strict
-- domain/handlers/InstanceHandlers.luau
--
-- Per-instance inspection: properties, children, search, class metadata.
-- Five read-only handlers:
--   - getInstanceProperties ← legacy plugin.luau L2326-2431
--   - getInstanceChildren   ← legacy plugin.luau L2433-2460
--   - searchObjects         ← legacy plugin.luau L2276-2324
--   - searchByProperty      ← legacy plugin.luau L2462-2499
--   - getClassInfo          ← legacy plugin.luau L2501-2588
--
-- ============================================================================
-- WHY THESE LIVE TOGETHER
-- ============================================================================
-- All five answer "tell me about ONE Instance (or class)" rather than the
-- tree-shaped questions in FileTreeHandlers. They share the same pattern:
-- accept a path or class name, pcall the various property probes (third-
-- party plugins routinely install Instances with __index metamethods that
-- throw on unknown reads), and return a tostring()'d property map.
--
-- ============================================================================
-- WHY ALL PROPERTIES ARE COERCED TO STRING
-- ============================================================================
-- The legacy `getInstanceProperties` returns every property as a `tostring()`
-- form — including Vector3, CFrame, etc. — instead of the rich wire format
-- produced by runtime/instance/Serialize.luau. This is intentional and
-- preserved verbatim:
--   1. The MCP host's `get_instance_properties` tool wraps this and surfaces
--      strings to the LLM. The LLM reads "Vector3(1.00, 2.00, 3.00)" more
--      reliably than `{ type = "Vector3", X = 1, ... }`.
--   2. Properties whose getters throw are silently skipped — only those
--      that `pcall` resolves get into the response.
-- The rich wire format is still available via mutating handlers (Phase 4)
-- where the LLM needs round-trippable values to feed into Convert.fromWire.
--
-- ============================================================================
-- WHY commonProps LISTS ARE REPLICATED
-- ============================================================================
-- getInstanceProperties and getClassInfo each have their own "common
-- properties" list. They are NOT identical in the legacy file:
--   - getInstanceProperties (L2358-2388) includes Face / SurfaceType
--   - getClassInfo            (L2522-2553) omits them
-- We preserve the asymmetry exactly so existing MCP prompts that branch on
-- one or the other field set see the same shape.

local Handler = require(script.Parent.Parent.handler.Handler)
local Path = require(script.Parent.Parent.Parent.runtime.instance.Path)

-- ============================================================================
-- TYPED REQUEST/RESPONSE SHAPES
-- ============================================================================

type InstancePathRequest = {
	instancePath: string?,
}

type SearchObjectsRequest = {
	query: string?,
	searchType: string?,
	propertyName: string?,
}

type SearchByPropertyRequest = {
	propertyName: string?,
	propertyValue: string?,
}

type GetClassInfoRequest = {
	className: string?,
}

-- ============================================================================
-- INTERNAL LISTS
-- ============================================================================

-- Verbatim from legacy L2358-2388. The "what should I show" set for
-- getInstanceProperties; spans BasePart, GuiObject, light source, and
-- ValueObject properties. Intersection with the actual instance is
-- pcall-checked at request time.
local INSTANCE_COMMON_PROPS = {
	"Size",
	"Position",
	"Rotation",
	"CFrame",
	"Anchored",
	"CanCollide",
	"Transparency",
	"BrickColor",
	"Material",
	"Color",
	"Text",
	"TextColor3",
	"BackgroundColor3",
	"Image",
	"ImageColor3",
	"Visible",
	"Active",
	"ZIndex",
	"BorderSizePixel",
	"BackgroundTransparency",
	"ImageTransparency",
	"TextTransparency",
	"Value",
	"Enabled",
	"Brightness",
	"Range",
	"Shadows",
	"Face",
	"SurfaceType",
}

-- Verbatim from legacy L2522-2553. The "what does this class expose" set
-- for getClassInfo. Intentionally omits Face/SurfaceType vs above.
local CLASS_COMMON_PROPS = {
	"Name",
	"ClassName",
	"Parent",
	"Size",
	"Position",
	"Rotation",
	"CFrame",
	"Anchored",
	"CanCollide",
	"Transparency",
	"BrickColor",
	"Material",
	"Color",
	"Text",
	"TextColor3",
	"BackgroundColor3",
	"Image",
	"ImageColor3",
	"Visible",
	"Active",
	"ZIndex",
	"BorderSizePixel",
	"BackgroundTransparency",
	"ImageTransparency",
	"TextTransparency",
	"Value",
	"Enabled",
	"Brightness",
	"Range",
	"Shadows",
}

-- Verbatim from legacy L2564-2574. The standard Instance-tree methods the
-- AI most often wants to know are available on a class.
local CLASS_COMMON_METHODS = {
	"Destroy",
	"Clone",
	"FindFirstChild",
	"FindFirstChildOfClass",
	"GetChildren",
	"IsA",
	"IsAncestorOf",
	"IsDescendantOf",
	"WaitForChild",
}

-- ============================================================================
-- HANDLERS
-- ============================================================================

local InstanceHandlers = {}

-- getInstanceProperties: stringified property map for one instance.
-- Legacy L2326-2431. The outer pcall covers the rare case where Parent
-- is being mutated concurrently and `instance[prop]` throws mid-walk.
InstanceHandlers.getInstanceProperties = Handler.define(
	"/api/instance-properties",
	function(_ctx, data: InstancePathRequest): (any, Handler.RecordResult?)
		local instancePath = data.instancePath
		if instancePath == nil then
			return { error = "Instance path is required" }, nil
		end

		local instance = Path.getInstanceByPath(instancePath)
		if instance == nil then
			return { error = "Instance not found: " .. instancePath }, nil
		end

		local properties: { [string]: string } = {}
		local ok, errResult = pcall(function()
			-- Basic / identity properties. Parent is path-rendered for
			-- consistency with everything else that exposes Instance refs.
			local basicProps = { "Name", "ClassName", "Parent" }
			for _, prop in basicProps do
				local propOk, propValue = pcall(function(): string
					local val = (instance :: any)[prop]
					if prop == "Parent" and val ~= nil then
						return Path.getInstancePath(val)
					elseif val == nil then
						return "nil"
					else
						return tostring(val)
					end
				end)
				if propOk then
					properties[prop] = propValue
				end
			end

			-- Best-effort scan of the common-properties intersection. Properties
			-- whose getter throws (forbidden / missing) are silently skipped.
			for _, prop in INSTANCE_COMMON_PROPS do
				local propOk, propValue = pcall(function(): string
					return tostring((instance :: any)[prop])
				end)
				if propOk then
					properties[prop] = propValue
				end
			end

			-- LuaSourceContainer-specific: Source is exposed wholesale so
			-- get_instance_properties on a Script returns its full body.
			-- The MCP host's get_script_source tool is the preferred path for
			-- this, but legacy callers rely on the property surface too.
			if instance:IsA("LuaSourceContainer") then
				properties.Source = (instance :: LuaSourceContainer).Source
				if instance:IsA("BaseScript") then
					properties.Enabled = tostring((instance :: BaseScript).Enabled)
				end
			end

			-- Part-only (NOT MeshPart) Shape property. Legacy L2406-2409.
			if instance:IsA("Part") then
				properties.Shape = tostring((instance :: Part).Shape)
			end

			-- BasePart-wide surface properties. Legacy L2412-2415.
			if instance:IsA("BasePart") then
				properties.TopSurface = tostring((instance :: BasePart).TopSurface)
				properties.BottomSurface = tostring((instance :: BasePart).BottomSurface)
			end

			properties.ChildCount = tostring(#instance:GetChildren())
		end)

		if ok then
			return {
				instancePath = instancePath,
				className = instance.ClassName,
				properties = properties,
			},
				nil
		else
			return { error = "Failed to get properties: " .. tostring(errResult) }, nil
		end
	end
)

-- getInstanceChildren: one-level enumeration of direct children. Used
-- when the AI wants a shallow lookup without paying for the full
-- getFileTree walk. Legacy L2433-2460.
InstanceHandlers.getInstanceChildren = Handler.define(
	"/api/instance-children",
	function(_ctx, data: InstancePathRequest): (any, Handler.RecordResult?)
		local instancePath = data.instancePath
		if instancePath == nil then
			return { error = "Instance path is required" }, nil
		end

		local instance = Path.getInstanceByPath(instancePath)
		if instance == nil then
			return { error = "Instance not found: " .. instancePath }, nil
		end

		local children: { any } = {}
		for _, child in instance:GetChildren() do
			table.insert(children, {
				name = child.Name,
				className = child.ClassName,
				path = Path.getInstancePath(child),
				hasChildren = #child:GetChildren() > 0,
				hasSource = child:IsA("LuaSourceContainer"),
			})
		end

		return {
			instancePath = instancePath,
			children = children,
			count = #children,
		}, nil
	end
)

-- searchObjects: recursive walk of game with a flexible match predicate.
-- Three search types: name, class, property. Case-insensitive substring.
-- Legacy L2276-2324.
InstanceHandlers.searchObjects = Handler.define(
	"/api/search-objects",
	function(_ctx, data: SearchObjectsRequest): (any, Handler.RecordResult?)
		local query = data.query
		local searchType = data.searchType or "name"
		local propertyName = data.propertyName

		if query == nil then
			return { error = "Query is required" }, nil
		end

		local needle = string.lower(query)
		local results: { any } = {}

		local function searchRecursive(instance: Instance)
			local matched = false

			if searchType == "name" then
				matched = string.find(string.lower(instance.Name), needle, 1, true) ~= nil
			elseif searchType == "class" then
				matched = string.find(string.lower(instance.ClassName), needle, 1, true) ~= nil
			elseif searchType == "property" and propertyName ~= nil then
				local ok, value = pcall(function(): string
					return tostring((instance :: any)[propertyName])
				end)
				if ok then
					matched = string.find(string.lower(value), needle, 1, true) ~= nil
				end
			end

			if matched then
				table.insert(results, {
					name = instance.Name,
					className = instance.ClassName,
					path = Path.getInstancePath(instance),
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

-- searchByProperty: shorthand for searchObjects with searchType="property"
-- but kept separate so existing MCP prompts that use the dedicated
-- endpoint continue to work. Legacy L2462-2499.
InstanceHandlers.searchByProperty = Handler.define(
	"/api/search-by-property",
	function(_ctx, data: SearchByPropertyRequest): (any, Handler.RecordResult?)
		local propertyName = data.propertyName
		local propertyValue = data.propertyValue

		if propertyName == nil or propertyValue == nil then
			return { error = "Property name and value are required" }, nil
		end

		local needle = string.lower(propertyValue)
		local results: { any } = {}

		local function searchRecursive(instance: Instance)
			local ok, value = pcall(function(): string
				return tostring((instance :: any)[propertyName])
			end)
			if ok and string.find(string.lower(value), needle, 1, true) ~= nil then
				table.insert(results, {
					name = instance.Name,
					className = instance.ClassName,
					path = Path.getInstancePath(instance),
					propertyValue = value,
				})
			end

			for _, child in instance:GetChildren() do
				searchRecursive(child)
			end
		end

		searchRecursive(game)

		return {
			propertyName = propertyName,
			propertyValue = propertyValue,
			results = results,
			count = #results,
		},
			nil
	end
)

-- getClassInfo: introspect what properties + methods a class exposes by
-- probing a temporary instance. Legacy L2501-2588.
--
-- We Instance.new() a throwaway, pcall-probe every name in the common
-- lists, then Destroy() it. The temporary instance is parented to nil
-- (Instance.new default) so it never appears in the data model — the
-- mutating endpoint refusal rules don't apply because nothing observable
-- changes. The Dispatcher receives nil RecordResult so no CHS recording
-- is opened.
InstanceHandlers.getClassInfo = Handler.define(
	"/api/class-info",
	function(_ctx, data: GetClassInfoRequest): (any, Handler.RecordResult?)
		local className = data.className
		if className == nil then
			return { error = "Class name is required" }, nil
		end

		-- Most "class doesn't exist" errors surface here. We catch and turn
		-- them into a user-facing error rather than letting the Dispatcher
		-- pcall surface "Unable to assign property ClassName" or similar.
		local ok, tempInstance = pcall(function(): Instance
			return Instance.new(className :: any)
		end)
		if not ok then
			return { error = "Invalid class name: " .. className }, nil
		end

		local classInfo = {
			className = className,
			properties = {} :: { string },
			methods = {} :: { string },
			events = {} :: { string }, -- reserved; legacy populates this lazily
		}

		for _, prop in CLASS_COMMON_PROPS do
			local propOk, _ = pcall(function()
				return (tempInstance :: any)[prop]
			end)
			if propOk then
				table.insert(classInfo.properties, prop)
			end
		end

		for _, method in CLASS_COMMON_METHODS do
			local methodOk, _ = pcall(function()
				return (tempInstance :: any)[method]
			end)
			if methodOk then
				table.insert(classInfo.methods, method)
			end
		end

		tempInstance:Destroy()

		return classInfo, nil
	end
)

return InstanceHandlers
