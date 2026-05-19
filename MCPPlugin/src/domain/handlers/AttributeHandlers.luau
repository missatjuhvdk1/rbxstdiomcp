--!strict
-- domain/handlers/AttributeHandlers.luau
--
-- Phase 3 ships the READ half only:
--   - getAttribute   ← legacy plugin.luau L4607-4652
--   - getAttributes  ← legacy plugin.luau L4710-4764
--
-- The mutating siblings (setAttribute, deleteAttribute — legacy L4654-4708,
-- L4766-4799) ship in Phase 4 alongside the rest of the destructive
-- handlers; they'll live in this same module so the read/write pair is
-- co-located.
--
-- ============================================================================
-- WHY ATTRIBUTES USE A DIFFERENT WIRE FORMAT THAN PROPERTY VALUES
-- ============================================================================
-- The legacy attribute serializer (L4626-4636) uses
--   { X = ..., Y = ..., Z = ..., _type = "Vector3" }
-- with an UNDERSCORE-prefixed `_type` discriminator. That is NOT the same
-- shape as runtime/instance/Serialize.luau's `toWire`, which uses
--   { type = "Vector3", X = ..., Y = ..., Z = ... }
-- with no underscore.
--
-- We preserve the underscore-prefixed `_type` here EXACTLY because the TS
-- bridge's get_attribute / get_attributes MCP tools currently parse that
-- specific shape. Changing it without a bridge-side change would silently
-- break every existing MCP client that reads attribute values.
--
-- A future Phase 5 cleanup may unify these by versioning the wire schema;
-- until then the rule is simple: attributes use `_type`, everything else
-- uses Serialize.toWire's `type`.
--
-- ============================================================================
-- WHY ONLY 5 TYPES ARE EXPLICITLY SERIALIZED
-- ============================================================================
-- Roblox attributes are limited to the set documented at
-- https://create.roblox.com/docs/reference/engine/classes/Instance#SetAttribute
-- (bool, string, number, UDim, UDim2, BrickColor, Color3, Vector2, Vector3,
-- CFrame, NumberSequence, ColorSequence, NumberRange, Rect, Font). The
-- legacy handler explicitly serializes only Vector3, Color3, CFrame, UDim2,
-- and BrickColor; the other rich types fall through to `tostring`-on-
-- JSON-encode behaviour. We preserve that asymmetry — fixing it would
-- change the wire shape for clients that rely on the current form.

local Handler = require(script.Parent.Parent.handler.Handler)
local Path = require(script.Parent.Parent.Parent.runtime.instance.Path)

-- ============================================================================
-- TYPED REQUEST/RESPONSE SHAPES
-- ============================================================================

type GetAttributeRequest = {
	instancePath: string?,
	attributeName: string?,
}

type GetAttributesRequest = {
	instancePath: string?,
}

-- ============================================================================
-- INTERNAL: attribute-specific wire serializer
-- ============================================================================
-- Returns the JSON-friendly form using the LEGACY `_type` discriminator.
-- See module header for why this can't share Serialize.toWire.
local function serializeAttributeValue(value: any): any
	local valueType = typeof(value)
	if valueType == "Vector3" then
		return { X = value.X, Y = value.Y, Z = value.Z, _type = "Vector3" }
	elseif valueType == "Color3" then
		return { R = value.R, G = value.G, B = value.B, _type = "Color3" }
	elseif valueType == "CFrame" then
		-- The legacy form only persists the Position (NOT the rotation).
		-- That's lossy but preserved verbatim; bridge clients have no
		-- way to roundtrip rotated CFrame attributes via get_attribute.
		-- A future schema version should send the full GetComponents()
		-- payload here.
		return {
			Position = { X = value.Position.X, Y = value.Position.Y, Z = value.Position.Z },
			_type = "CFrame",
		}
	elseif valueType == "UDim2" then
		return {
			X = { Scale = value.X.Scale, Offset = value.X.Offset },
			Y = { Scale = value.Y.Scale, Offset = value.Y.Offset },
			_type = "UDim2",
		}
	elseif valueType == "BrickColor" then
		return { Name = value.Name, _type = "BrickColor" }
	end
	-- Bool / number / string / Font / Rect / NumberRange / etc. pass through
	-- as-is — the bridge's JSON encoder handles them directly.
	return value
end

-- ============================================================================
-- HANDLERS
-- ============================================================================

local AttributeHandlers = {}

-- getAttribute: read one named attribute on one Instance. Legacy L4607-4652.
-- Returns { exists = false } when the attribute is unset rather than an
-- error, so the AI can branch on the boolean without parsing error text.
AttributeHandlers.getAttribute = Handler.define(
	"/api/get-attribute",
	function(_ctx, data: GetAttributeRequest): (any, Handler.RecordResult?)
		local instancePath = data.instancePath
		local attributeName = data.attributeName

		if instancePath == nil or attributeName == nil then
			return { error = "Instance path and attribute name are required" }, nil
		end

		local instance = Path.getInstanceByPath(instancePath)
		if instance == nil then
			return { error = "Instance not found: " .. instancePath }, nil
		end

		-- pcall guard: GetAttribute itself doesn't throw on missing names
		-- (returns nil) but plugins can install __index metamethods on
		-- Instance proxies that hijack the call. Cheap belt-and-braces.
		local ok, result = pcall(function()
			local value = instance:GetAttribute(attributeName)
			return {
				instancePath = instancePath,
				attributeName = attributeName,
				value = serializeAttributeValue(value),
				valueType = typeof(value),
				exists = value ~= nil,
			}
		end)

		if ok then
			return result, nil
		else
			return { error = "Failed to get attribute: " .. tostring(result) }, nil
		end
	end
)

-- getAttributes: dump every attribute on one Instance with type metadata.
-- Legacy L4710-4764. The wrapper shape is
--   { name = { value = <serialized>, type = <typeof> } }
-- which differs from getAttribute's flat shape — we preserve both.
AttributeHandlers.getAttributes = Handler.define(
	"/api/get-attributes",
	function(_ctx, data: GetAttributesRequest): (any, Handler.RecordResult?)
		local instancePath = data.instancePath
		if instancePath == nil then
			return { error = "Instance path is required" }, nil
		end

		local instance = Path.getInstanceByPath(instancePath)
		if instance == nil then
			return { error = "Instance not found: " .. instancePath }, nil
		end

		local ok, result = pcall(function()
			local attributes = instance:GetAttributes()
			local serialized: { [string]: any } = {}
			local count = 0

			for name, value in pairs(attributes) do
				serialized[name] = {
					value = serializeAttributeValue(value),
					type = typeof(value),
				}
				count += 1
			end

			return {
				instancePath = instancePath,
				attributes = serialized,
				count = count,
			}
		end)

		if ok then
			return result, nil
		else
			return { error = "Failed to get attributes: " .. tostring(result) }, nil
		end
	end
)

return AttributeHandlers
