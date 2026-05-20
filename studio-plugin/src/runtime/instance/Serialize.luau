--!strict
-- runtime/instance/Serialize.luau
--
-- THE one canonical Roblox-value → wire-format serializer (ARCHITECTURE §11).
-- The legacy plugin.luau had THREE serializers:
--   - L219  : the rich Vector3/CFrame/etc. → JSON-friendly table form, used
--             by the SERVER companion template (a quoted string at the top
--             of the file; will become a real script in Phase 5).
--   - L743  : an identical copy inside the CLIENT companion template.
--   - L1156 : a PLAIN-STRING "Vector3(1.00, 2.00, 3.00)" form, used by the
--             action-log summary (display only).
--
-- The two rich copies were already bug-for-bug identical (we diffed them).
-- Phase 5 will produce companion scripts that REQUIRE this single module
-- via `require(script.Parent.Parent.runtime.instance.Serialize)`, killing
-- both copies in one move.
--
-- The display form is kept here too — but as a *separate exported function*
-- (`toDisplayString`) on the same module. Conceptually it serializes; we
-- just want one place to look for "how do we represent Roblox values to a
-- human/machine consumer". Two functions, one canon.
--
-- IMPORTANT INVARIANTS (do NOT break without a wire-format version bump):
--
--   - Each typed value is wrapped as { type = "Vector3", X=..., Y=..., Z=... }
--     etc. The bridge / MCP host pattern-matches on the `type` discriminator.
--     New types added here must be added to the bridge schema in lockstep.
--   - Strings >65536 chars are truncated with "...<truncated>" so a runaway
--     print() can't OOM the bridge or starve the polling loop on a giant
--     RequestAsync body.
--   - Cycles in tables become "<cycle>" — not an error, because user code
--     legitimately builds graphs that touch themselves (linked GUIs, etc.)
--     and we'd rather show partial data than refuse the whole result.
--   - Max table depth = 8 and max entries per table = 200; same legacy caps.
--     Both produce sentinel markers ("<max depth>" / `__truncated__ = true`)
--     so the consumer can tell the result was clipped.

local Serialize = {}

-- ---------------------------------------------------------------------------
-- toWire: rich JSON-friendly serialization. Used by handler responses and
-- companion eval-result payloads.
-- ---------------------------------------------------------------------------

-- These caps live as locals (not Constants) because changing them would
-- silently change wire format for downstream consumers; we want the
-- numbers visible right next to the code that enforces them.
local MAX_DEPTH = 8
local MAX_STRING_LEN = 65536
local MAX_TABLE_ENTRIES = 200

type WireValue = any -- intentionally open: leaf types are string/number/bool
-- and nested tables. Strong-typing this is more work than it pays for; the
-- bridge has its own schema.

function Serialize.toWire(value: any, depth: number?, seen: { [any]: boolean }?): WireValue
	local d = depth or 0
	local s = seen or {}
	if d > MAX_DEPTH then
		return "<max depth>"
	end

	local t = typeof(value)
	if value == nil then
		return nil
	elseif t == "string" then
		if #value > MAX_STRING_LEN then
			return string.sub(value, 1, MAX_STRING_LEN) .. "...<truncated>"
		end
		return value
	elseif t == "number" then
		-- JSON can't represent NaN/Infinity; coerce to string so the bridge's
		-- decoder doesn't refuse the whole response.
		if value ~= value then
			return "NaN"
		end
		if value == math.huge then
			return "Infinity"
		end
		if value == -math.huge then
			return "-Infinity"
		end
		return value
	elseif t == "boolean" then
		return value
	elseif t == "Vector3" then
		return { type = "Vector3", X = value.X, Y = value.Y, Z = value.Z }
	elseif t == "Vector2" then
		return { type = "Vector2", X = value.X, Y = value.Y }
	elseif t == "CFrame" then
		-- GetComponents returns 12 numbers (position + 3 right vectors).
		-- We send the full set so the bridge can reconstruct the CFrame
		-- exactly, not an approximation built from position + lookVector.
		return { type = "CFrame", components = { value:GetComponents() } }
	elseif t == "Color3" then
		return { type = "Color3", R = value.R, G = value.G, B = value.B }
	elseif t == "BrickColor" then
		return { type = "BrickColor", Name = value.Name }
	elseif t == "UDim" then
		return { type = "UDim", Scale = value.Scale, Offset = value.Offset }
	elseif t == "UDim2" then
		return {
			type = "UDim2",
			X = { Scale = value.X.Scale, Offset = value.X.Offset },
			Y = { Scale = value.Y.Scale, Offset = value.Y.Offset },
		}
	elseif t == "Rect" then
		return {
			type = "Rect",
			Min = { X = value.Min.X, Y = value.Min.Y },
			Max = { X = value.Max.X, Y = value.Max.Y },
		}
	elseif t == "Ray" then
		return {
			type = "Ray",
			Origin = { X = value.Origin.X, Y = value.Origin.Y, Z = value.Origin.Z },
			Direction = { X = value.Direction.X, Y = value.Direction.Y, Z = value.Direction.Z },
		}
	elseif t == "NumberRange" then
		return { type = "NumberRange", Min = value.Min, Max = value.Max }
	elseif t == "EnumItem" then
		return { type = "EnumItem", Name = tostring(value), Value = value.Value }
	elseif t == "Instance" then
		-- Resolve GetFullName under pcall: an Instance that's been Destroyed
		-- mid-walk will throw on .Parent access. We want a usable summary,
		-- not an error.
		local fullName = "<unparented>"
		pcall(function()
			fullName = value:GetFullName()
		end)
		return {
			type = "Instance",
			ClassName = value.ClassName,
			Name = value.Name,
			Path = fullName,
		}
	elseif t == "table" then
		if s[value] then
			return "<cycle>"
		end
		s[value] = true
		local result: { [string]: any } = {}
		local count = 0
		for k, v in pairs(value) do
			count += 1
			if count > MAX_TABLE_ENTRIES then
				result["__truncated__"] = true
				break
			end
			local keyStr = type(k) == "string" and k or tostring(k)
			result[keyStr] = Serialize.toWire(v, d + 1, s)
		end
		s[value] = nil
		return result
	elseif t == "function" then
		return "<function>"
	elseif t == "thread" then
		return "<thread>"
	elseif t == "buffer" then
		return "<buffer>"
	else
		-- Fallback: stringify whatever it is. Wrapping in pcall because
		-- userdata with broken __tostring metamethods do exist in third-
		-- party libraries.
		local ok, str = pcall(tostring, value)
		return ok and str or ("<" .. t .. ">")
	end
end

-- ---------------------------------------------------------------------------
-- toDisplayString: short human-readable summary. Used by ActionLog so the
-- get_history tool can show "Set Position → Vector3(1.0, 2.0, 3.0)" without
-- the consumer having to pretty-print the toWire form.
-- ---------------------------------------------------------------------------

function Serialize.toDisplayString(value: any): string
	local t = typeof(value)
	if t == "Vector3" then
		return string.format("Vector3(%.2f, %.2f, %.2f)", value.X, value.Y, value.Z)
	elseif t == "Vector2" then
		return string.format("Vector2(%.2f, %.2f)", value.X, value.Y)
	elseif t == "Color3" then
		return string.format("Color3(%.2f, %.2f, %.2f)", value.R, value.G, value.B)
	elseif t == "BrickColor" then
		return "BrickColor(" .. value.Name .. ")"
	elseif t == "UDim2" then
		return string.format("UDim2(%.2f, %d, %.2f, %d)", value.X.Scale, value.X.Offset, value.Y.Scale, value.Y.Offset)
	elseif t == "UDim" then
		return string.format("UDim(%.2f, %d)", value.Scale, value.Offset)
	elseif t == "CFrame" then
		return string.format("CFrame(%.1f, %.1f, %.1f)", value.X, value.Y, value.Z)
	elseif t == "EnumItem" then
		return tostring(value)
	elseif t == "Instance" then
		return value.ClassName .. "(" .. value.Name .. ")"
	elseif t == "table" then
		local arr = value :: { any }
		if #arr > 0 then
			local parts: { string } = {}
			for i, v in ipairs(arr) do
				if i > 3 then
					table.insert(parts, "...")
					break
				end
				table.insert(parts, Serialize.toDisplayString(v))
			end
			return "{" .. table.concat(parts, ", ") .. "}"
		end
		return "{...}"
	else
		return tostring(value)
	end
end

return Serialize
