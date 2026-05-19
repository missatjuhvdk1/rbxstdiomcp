--!strict
-- runtime/instance/Convert.luau
--
-- Wire-format → Roblox-value coercion. Inverse of Serialize.toWire but
-- *not* strictly symmetric — incoming property writes from JSON come in
-- one of several shorthand shapes the MCP host already established (legacy
-- L1703-1775), so we tolerate:
--
--   { 1, 2, 3 }                 → Vector3 (length=3 → Vector3, length=2 → Vector2)
--   { X = 1, Y = 2, Z = 3 }     → Vector3
--   { R = 1, G = 0, B = 0 }     → Color3
--   "Ball"  (with EnumItem prop) → Enum.PartType.Ball
--   "RedFlip" (with BrickColor)  → BrickColor.new(...)
--   "true" / "false"            → boolean
--   anything else               → return verbatim (caller may still assign)
--
-- Why type-inference from the CURRENT property value:
--   The MCP host sends [r, g, b] for both Vector3 and Color3 — same JSON
--   shape, different Roblox type. To disambiguate, we read the existing
--   property type via `pcall(function() return instance[name] end)` and
--   route accordingly. This is the legacy L1721-1736 trick, kept verbatim
--   because every existing MCP tool relies on it.
--
-- Failures fall through to "return propertyValue as-is" so the caller's
-- assignment will throw a more meaningful Roblox-side error than we could
-- synthesize. We're a hint provider, not a strict validator.

local Convert = {}

local function nameLower(s: string): string
	return s:lower()
end

-- Property name → expected typed shape, used as a fast path when the
-- current value's type can't be probed (e.g. property doesn't yet exist
-- on the instance because we're about to create it).
local NAME_HINT_VECTOR3: { [string]: true } = {
	position = true,
	size = true,
	orientation = true,
	velocity = true,
	angularvelocity = true,
}

local NAME_HINT_COLOR3: { [string]: true } = {
	color = true,
	color3 = true,
}

-- Coerce a wire value into the appropriate Roblox type for `instance[propertyName]`.
-- The Roblox-side assignment is the caller's responsibility.
function Convert.fromWire(instance: Instance?, propertyName: string, value: any): any
	if value == nil then
		return nil
	end

	-- Probe the current property value for type-inference. Wrap in pcall:
	-- accessing an unknown property name errors, and we want a clean
	-- fallback through to the name-hint table.
	local hasCurrent, currentVal = pcall(function()
		if instance == nil then
			return nil
		end
		return (instance :: any)[propertyName]
	end)

	-- Array-shaped value: { 1, 2, 3 } → Vector3, { 1, 2 } → Vector2.
	if type(value) == "table" and #value > 0 then
		if #value == 3 then
			local pn = nameLower(propertyName)
			if NAME_HINT_VECTOR3[pn] then
				return Vector3.new(value[1] or 0, value[2] or 0, value[3] or 0)
			elseif NAME_HINT_COLOR3[pn] then
				return Color3.new(value[1] or 0, value[2] or 0, value[3] or 0)
			elseif hasCurrent then
				if typeof(currentVal) == "Vector3" then
					return Vector3.new(value[1] or 0, value[2] or 0, value[3] or 0)
				elseif typeof(currentVal) == "Color3" then
					return Color3.new(value[1] or 0, value[2] or 0, value[3] or 0)
				end
			end
		elseif #value == 2 then
			if hasCurrent and typeof(currentVal) == "Vector2" then
				return Vector2.new(value[1] or 0, value[2] or 0)
			end
		end
	end

	-- Object-shaped value with X/Y/Z (Vector3).
	if type(value) == "table" and (value.X ~= nil or value.Y ~= nil or value.Z ~= nil) then
		return Vector3.new(value.X or 0, value.Y or 0, value.Z or 0)
	end

	-- Object-shaped value with R/G/B (Color3).
	if type(value) == "table" and (value.R ~= nil or value.G ~= nil or value.B ~= nil) then
		return Color3.new(value.R or 0, value.G or 0, value.B or 0)
	end

	-- String value: try Enum lookup against the current property's EnumType,
	-- then BrickColor by name, then bool-string shorthand.
	if type(value) == "string" then
		if hasCurrent and typeof(currentVal) == "EnumItem" then
			local enumType = tostring((currentVal :: EnumItem).EnumType)
			local enumOk, enumVal = pcall(function()
				return (Enum :: any)[enumType][value]
			end)
			if enumOk and enumVal ~= nil then
				return enumVal
			end
		end

		if propertyName == "BrickColor" then
			local bcOk, bc = pcall(function()
				return BrickColor.new(value)
			end)
			if bcOk then
				return bc
			end
		end

		if value == "true" then
			return true
		end
		if value == "false" then
			return false
		end
	end

	-- Primitive (number, boolean, plain string) or unrecognised shape:
	-- hand it back unchanged and let the assignment site error.
	return value
end

return Convert
