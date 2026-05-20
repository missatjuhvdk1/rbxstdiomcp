--!strict
-- domain/handlers/AttributeHandlers.luau
--
-- Attribute read + write. Four endpoints:
--   - getAttribute     ← legacy plugin.luau L4607-4652  (read, Phase 3)
--   - getAttributes    ← legacy plugin.luau L4710-4764  (read, Phase 3)
--   - setAttribute     ← legacy plugin.luau L4654-4708  (write, Phase 4)
--   - deleteAttribute  ← legacy plugin.luau L4766-4799  (write, Phase 4)
--
-- Read and write pairs are co-located so the wire-format quirks (legacy
-- `_type` discriminator vs Serialize's `type`, see below) are documented
-- once and respected by both halves.
--
-- ============================================================================
-- PHASE 4 WRITE-SIDE NOTES
-- ============================================================================
-- setAttribute / deleteAttribute use Convert.fromWire for incoming values
-- (same coercion as set_property). Attribute APIs accept the same value
-- shapes the property APIs do — { 1, 2, 3 } → Vector3, etc. — so we route
-- through the existing Convert pipeline rather than duplicating shape
-- detection.
--
-- LLM-stomp: neither handler refuses companion-protected instances.
-- Attribute changes are recoverable (the editor shows them in the
-- properties panel and an undo reverts them) and the AI legitimately wants
-- to read/inspect companion-tagged metadata during debugging.
--
-- ActionLog: both write handlers stage a single entry. Unlike property
-- writes, attribute changes are individually meaningful (each attribute is
-- a named user-facing knob) so they appear in get_history.
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
local Convert = require(script.Parent.Parent.Parent.runtime.instance.Convert)

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

type SetAttributeRequest = {
	instancePath: string?,
	attributeName: string?,
	attributeValue: any,
}

type DeleteAttributeRequest = {
	instancePath: string?,
	attributeName: string?,
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

-- setAttribute: write one named attribute on one Instance. Legacy L4654-4708.
-- Routes wire-shape values through Convert.fromWire so { X = .., Y = ..,
-- Z = .. } → Vector3 etc. matches the property-write coercion behaviour.
AttributeHandlers.setAttribute = Handler.define(
	"/api/set-attribute",
	function(ctx, data: SetAttributeRequest): (any, Handler.RecordResult?)
		local instancePath = data.instancePath
		local attributeName = data.attributeName
		local attributeValue = data.attributeValue

		if instancePath == nil or attributeName == nil then
			return { error = "Instance path and attribute name are required" }, nil
		end

		local instance = Path.getInstanceByPath(instancePath)
		if instance == nil then
			return { error = "Instance not found: " .. instancePath }, nil
		end

		-- Capture the previous value for the action-log details bag — gives
		-- get_history enough info to describe the change.
		local okOld, oldValue = pcall(function()
			return instance:GetAttribute(attributeName :: string)
		end)
		local previousValue: any = if okOld then oldValue else nil

		-- Convert.fromWire wants a property name for type inference. For
		-- attributes there is no fixed-typed slot to probe, so we pass the
		-- attribute name; the inference falls through to the name-hint
		-- table (Position / Size / Color etc.) and otherwise returns the
		-- value verbatim. That's the correct legacy behaviour.
		local converted = Convert.fromWire(instance, attributeName :: string, attributeValue)
		if converted == nil then
			converted = attributeValue
		end

		local ok, err = pcall(function()
			instance:SetAttribute(attributeName :: string, converted)
		end)
		if not ok then
			return {
				error = "Failed to set attribute: " .. tostring(err),
				instancePath = instancePath,
				attributeName = attributeName,
			},
				nil
		end

		ctx.actionLog:stage(
			"set_attribute",
			instancePath,
			string.format("Set attribute %s on %s", attributeName :: string, instancePath),
			{
				attributeName = attributeName,
				newValue = serializeAttributeValue(converted),
				previousValue = serializeAttributeValue(previousValue),
			}
		)

		return {
			success = true,
			instancePath = instancePath,
			attributeName = attributeName,
			attributeValue = attributeValue,
			message = "Attribute set successfully",
		}, {
			name = "Set Attribute: " .. (attributeName :: string),
			didMutate = true,
		}
	end
)

-- deleteAttribute: clear one named attribute. Legacy L4766-4799.
-- Roblox's API is SetAttribute(name, nil) for deletion.
AttributeHandlers.deleteAttribute = Handler.define(
	"/api/delete-attribute",
	function(ctx, data: DeleteAttributeRequest): (any, Handler.RecordResult?)
		local instancePath = data.instancePath
		local attributeName = data.attributeName

		if instancePath == nil or attributeName == nil then
			return { error = "Instance path and attribute name are required" }, nil
		end

		local instance = Path.getInstanceByPath(instancePath)
		if instance == nil then
			return { error = "Instance not found: " .. instancePath }, nil
		end

		-- No-op if the attribute doesn't exist — return didMutate=false so
		-- the dispatcher cancels both CHS and the (un-staged) action log
		-- entry. This matches the find_and_replace zero-match pattern.
		local okProbe, probed = pcall(function()
			return instance:GetAttribute(attributeName :: string)
		end)
		if okProbe and probed == nil then
			return {
				success = true,
				instancePath = instancePath,
				attributeName = attributeName,
				message = "Attribute did not exist; no change made",
			}, {
				name = "Delete Attribute: " .. (attributeName :: string),
				didMutate = false,
			}
		end

		local previousValue: any = if okProbe then probed else nil

		local ok, err = pcall(function()
			instance:SetAttribute(attributeName :: string, nil)
		end)
		if not ok then
			return {
				error = "Failed to delete attribute: " .. tostring(err),
				instancePath = instancePath,
				attributeName = attributeName,
			},
				nil
		end

		ctx.actionLog:stage(
			"delete_attribute",
			instancePath,
			string.format("Deleted attribute %s from %s", attributeName :: string, instancePath),
			{
				attributeName = attributeName,
				previousValue = serializeAttributeValue(previousValue),
			}
		)

		return {
			success = true,
			instancePath = instancePath,
			attributeName = attributeName,
			message = "Attribute deleted successfully",
		}, {
			name = "Delete Attribute: " .. (attributeName :: string),
			didMutate = true,
		}
	end
)

return AttributeHandlers
