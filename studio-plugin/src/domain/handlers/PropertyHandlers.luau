--!strict
-- domain/handlers/PropertyHandlers.luau
--
-- Property-write handlers, Phase 4. Five endpoints:
--   - setProperty             ← legacy plugin.luau L2742-2805
--   - massSetProperty         ← legacy plugin.luau L2908-2966
--   - massGetProperty         ← legacy plugin.luau L2968-3012 (READ-ONLY)
--   - setCalculatedProperty   ← legacy plugin.luau L3411-3483
--   - setRelativeProperty     ← legacy plugin.luau L3485-3630
--
-- ============================================================================
-- WHY MASS_GET LIVES HERE (NOT INSTANCEHANDLERS)
-- ============================================================================
-- mass_get_property is structurally a read-only handler, but its sibling on
-- the wire is mass_set_property — paths-array + property-name input, paired
-- output rows. Keeping them in one module lets a future extension (e.g.
-- mass_swap, mass_increment) share helpers without a cross-module diamond.
-- It returns `(response, nil)` — no RecordResult — so the dispatcher will
-- treat it as read-only.
--
-- ============================================================================
-- WHY ONLY setProperty LOGS TO ACTIONLOG
-- ============================================================================
-- The legacy file logs ONE action per single mutation (set_property) and
-- skips logging for batched paths (mass_*, set_calculated, set_relative).
-- We preserve that: get_history is meant for "what did the AI just change?"
-- and a batched mass-set of 500 instances would flood the visible history.
-- The CHS recording for batched ops still produces one undo step (one
-- Ctrl+Z reverts the whole batch), which is what users actually want.
--
-- ============================================================================
-- LLM-STOMP PROTECTION
-- ============================================================================
-- setProperty refuses to write a `Disabled = true` value on a companion-
-- tagged script (Phase 4 plan §6.2 / Companions.luau). The other property
-- handlers do NOT block companion mutations: setting a property on a
-- companion is recoverable, but a `Disabled = true` would silently break
-- the play-solo log pipeline, which is the failure mode the protection
-- exists for.
--
-- ============================================================================
-- TYPE INFERENCE QUIRKS PRESERVED
-- ============================================================================
-- The legacy massSetProperty / setCalculated / setRelative handlers do NOT
-- run their inputs through Convert.fromWire — they assign the raw value
-- directly. That's bug-compatible: the bridge currently sends pre-typed
-- numbers / strings to these endpoints. Changing it would silently break
-- callers that expect today's wire shape. We preserve raw assignment here
-- and document the asymmetry vs setProperty (which DOES use Convert).

local Handler = require(script.Parent.Parent.handler.Handler)
local Path = require(script.Parent.Parent.Parent.runtime.instance.Path)
local Convert = require(script.Parent.Parent.Parent.runtime.instance.Convert)
local Serialize = require(script.Parent.Parent.Parent.runtime.instance.Serialize)
local Companions = require(script.Parent.Parent.Parent.runtime.testsession.Companions)

-- ============================================================================
-- TYPED REQUEST/RESPONSE SHAPES
-- ============================================================================

type SetPropertyRequest = {
	instancePath: string?,
	propertyName: string?,
	propertyValue: any,
}

type MassSetPropertyRequest = {
	paths: { string }?,
	propertyName: string?,
	propertyValue: any,
}

type MassGetPropertyRequest = {
	paths: { string }?,
	propertyName: string?,
}

type SetCalculatedPropertyRequest = {
	paths: { string }?,
	propertyName: string?,
	formula: string?,
	variables: { [string]: any }?,
}

type SetRelativePropertyRequest = {
	paths: { string }?,
	propertyName: string?,
	operation: string?,
	value: any,
	component: string?,
}

-- ============================================================================
-- INTERNAL HELPERS
-- ============================================================================

-- Single-property assignment. Returns (true, finalValue) on success or
-- (false, errorMessage) on failure. Captures the legacy setProperty special
-- cases for Parent / PrimaryPart / Name / Source.
local function assignSingleProperty(instance: Instance, propertyName: string, propertyValue: any): (boolean, any)
	if propertyName == "Parent" or propertyName == "PrimaryPart" then
		-- Reference-shaped properties: the wire format is a string path.
		if type(propertyValue) ~= "string" then
			return false, propertyName .. " must be set to a string path"
		end
		local target = Path.getInstanceByPath(propertyValue :: string)
		if target == nil then
			return false, propertyName .. " instance not found: " .. (propertyValue :: string)
		end
		local ok, err = pcall(function()
			(instance :: any)[propertyName] = target
		end)
		if not ok then
			return false, tostring(err)
		end
		return true, propertyValue
	end

	if propertyName == "Name" then
		local strVal = tostring(propertyValue)
		local ok, err = pcall(function()
			(instance :: any).Name = strVal
		end)
		if not ok then
			return false, tostring(err)
		end
		return true, strVal
	end

	if propertyName == "Source" and instance:IsA("LuaSourceContainer") then
		-- Mirrors legacy L2772-2778. setProperty Source bypasses
		-- editor-buffer reconciliation, which is why set_script_source
		-- exists. We accept the assignment here for tool parity but the
		-- preferred path is the dedicated script handler.
		local strVal = tostring(propertyValue)
		local ok, err = pcall(function()
			(instance :: any).Source = strVal
		end)
		if not ok then
			return false, tostring(err)
		end
		return true, strVal
	end

	-- All other properties: route through Convert.fromWire for the
	-- Vector3/Color3/Enum/BrickColor coercions, then assign. Convert
	-- returns nil only when given nil; for any other shape it returns the
	-- value (possibly the same object), so a nil return here only happens
	-- when the wire payload itself was nil.
	local converted = Convert.fromWire(instance, propertyName, propertyValue)
	if converted == nil then
		-- Fall through to raw assignment so the caller gets a meaningful
		-- Roblox-side error rather than a synthetic "conversion failed"
		-- when the wire genuinely passed nil for a property that accepts
		-- it (e.g. ObjectValue.Value = nil).
		converted = propertyValue
	end

	local ok, err = pcall(function()
		(instance :: any)[propertyName] = converted
	end)
	if not ok then
		return false, tostring(err)
	end
	return true, converted
end

-- Formula evaluator for setCalculatedProperty. Verbatim port of legacy
-- L3335-3409. Pattern-substitutes index/Position.X/Size.Y/variables/etc
-- into the formula, then a tiny `a op b` matcher. Returns (value, errorMsg?).
local function evaluateFormula(
	formula: string,
	variables: { [string]: any }?,
	instance: Instance,
	index: number
): (number, string?)
	local expr = formula

	-- Substitute {index} with the per-instance index (1-based).
	expr = expr:gsub("{index}", tostring(index))

	-- Position / Size axis substitutions (BasePart only). pcall the
	-- property reads so non-BasePart inputs fall through cleanly.
	local ok, pos = pcall(function()
		return (instance :: any).Position
	end)
	if ok and typeof(pos) == "Vector3" then
		expr = expr:gsub("{Position%.X}", string.format("%.6f", pos.X))
		expr = expr:gsub("{Position%.Y}", string.format("%.6f", pos.Y))
		expr = expr:gsub("{Position%.Z}", string.format("%.6f", pos.Z))
		expr = expr:gsub("{magnitude}", string.format("%.6f", pos.Magnitude))
	end

	local okSize, sz = pcall(function()
		return (instance :: any).Size
	end)
	if okSize and typeof(sz) == "Vector3" then
		expr = expr:gsub("{Size%.X}", string.format("%.6f", sz.X))
		expr = expr:gsub("{Size%.Y}", string.format("%.6f", sz.Y))
		expr = expr:gsub("{Size%.Z}", string.format("%.6f", sz.Z))
	end

	-- User variables — replace by literal name.
	if variables ~= nil then
		for key, val in variables :: { [string]: any } do
			-- Defensive: only stringify primitives; complex shapes get
			-- tostring'd into something that won't tonumber, which lands
			-- us in the fallback "complex formulas not supported" branch.
			expr = expr:gsub("{" .. key .. "}", tostring(val))
		end
	end

	-- Inline math function calls on literal numbers. Mirrors legacy.
	local mathFns: { [string]: (number) -> number } = {
		sin = math.sin,
		cos = math.cos,
		sqrt = math.sqrt,
		abs = math.abs,
		floor = math.floor,
		ceil = math.ceil,
	}
	for fnName, fn in mathFns do
		expr = expr:gsub(fnName .. "%(([%-%d%.]+)%)", function(arg)
			local n = tonumber(arg)
			if n == nil then
				return fnName .. "(" .. arg .. ")"
			end
			return string.format("%.6f", fn(n))
		end)
	end

	-- After substitutions: is it a literal number?
	local literal = tonumber(expr)
	if literal ~= nil then
		return literal, nil
	end

	-- Tiny `a op b` matcher.
	local a, op, b = expr:match("^%s*(%-?[%d%.]+)%s*([%+%-%*/])%s*(%-?[%d%.]+)%s*$")
	if a ~= nil and op ~= nil and b ~= nil then
		local na = tonumber(a)
		local nb = tonumber(b)
		if na ~= nil and nb ~= nil then
			if op == "+" then
				return na + nb, nil
			elseif op == "-" then
				return na - nb, nil
			elseif op == "*" then
				return na * nb, nil
			elseif op == "/" then
				if nb == 0 then
					return index, "Division by zero in formula"
				end
				return na / nb, nil
			end
		end
	end

	-- Fall through: return the index as a debug-friendly value so the row
	-- still has SOMETHING (matching legacy behaviour) but flag the error
	-- so the row is marked failed by the caller.
	return index, "Complex formulas not supported - using index value"
end

-- Apply one relative-op to one (instance, property) tuple. Returns
-- (true, newValue) or (false, errorMessage). Verbatim port of legacy
-- L3536-3625 logic.
local function applyRelative(
	instance: Instance,
	propertyName: string,
	operation: string,
	value: any,
	component: string?
): (boolean, any)
	local okGet, currentValue = pcall(function()
		return (instance :: any)[propertyName]
	end)
	if not okGet then
		return false, "Failed to read current value: " .. tostring(currentValue)
	end

	-- Vector3 + per-component scalar op.
	if typeof(currentValue) == "Vector3" and type(value) == "number" then
		if component == "X" or component == "Y" or component == "Z" then
			local newX, newY, newZ = currentValue.X, currentValue.Y, currentValue.Z
			if operation == "add" then
				if component == "X" then
					newX += value
				elseif component == "Y" then
					newY += value
				else
					newZ += value
				end
			elseif operation == "subtract" then
				if component == "X" then
					newX -= value
				elseif component == "Y" then
					newY -= value
				else
					newZ -= value
				end
			elseif operation == "multiply" then
				if component == "X" then
					newX *= value
				elseif component == "Y" then
					newY *= value
				else
					newZ *= value
				end
			elseif operation == "divide" then
				if value == 0 then
					return false, "Division by zero"
				end
				if component == "X" then
					newX /= value
				elseif component == "Y" then
					newY /= value
				else
					newZ /= value
				end
			elseif operation == "power" then
				if component == "X" then
					newX = newX ^ value
				elseif component == "Y" then
					newY = newY ^ value
				else
					newZ = newZ ^ value
				end
			else
				return false, "Unsupported operation for Vector3 component: " .. operation
			end
			local newV = Vector3.new(newX, newY, newZ)
			local okSet, errSet = pcall(function()
				(instance :: any)[propertyName] = newV
			end)
			if not okSet then
				return false, tostring(errSet)
			end
			return true, newV
		end

		-- No component → broadcast scalar across all axes.
		local newV: Vector3
		if operation == "add" then
			newV = currentValue + Vector3.new(value, value, value)
		elseif operation == "subtract" then
			newV = currentValue - Vector3.new(value, value, value)
		elseif operation == "multiply" then
			newV = currentValue * value
		elseif operation == "divide" then
			if value == 0 then
				return false, "Division by zero"
			end
			newV = currentValue / value
		elseif operation == "power" then
			newV = Vector3.new(currentValue.X ^ value, currentValue.Y ^ value, currentValue.Z ^ value)
		else
			return false, "Unsupported operation for Vector3: " .. operation
		end
		local okSet, errSet = pcall(function()
			(instance :: any)[propertyName] = newV
		end)
		if not okSet then
			return false, tostring(errSet)
		end
		return true, newV
	end

	-- Color3 + Color3 op (channel-wise). divide/power deliberately
	-- unsupported, matching legacy behaviour (would yield nil).
	if typeof(currentValue) == "Color3" and typeof(value) == "Color3" then
		local newC: Color3?
		if operation == "add" then
			newC = Color3.new(
				math.min(1, currentValue.R + value.R),
				math.min(1, currentValue.G + value.G),
				math.min(1, currentValue.B + value.B)
			)
		elseif operation == "subtract" then
			newC = Color3.new(
				math.max(0, currentValue.R - value.R),
				math.max(0, currentValue.G - value.G),
				math.max(0, currentValue.B - value.B)
			)
		elseif operation == "multiply" then
			newC = Color3.new(currentValue.R * value.R, currentValue.G * value.G, currentValue.B * value.B)
		end
		if newC == nil then
			return false, "Unsupported Color3 operation: " .. operation
		end
		local okSet, errSet = pcall(function()
			(instance :: any)[propertyName] = newC
		end)
		if not okSet then
			return false, tostring(errSet)
		end
		return true, newC
	end

	-- number + number op.
	if type(currentValue) == "number" and type(value) == "number" then
		local newN: number?
		if operation == "add" then
			newN = currentValue + value
		elseif operation == "subtract" then
			newN = currentValue - value
		elseif operation == "multiply" then
			newN = currentValue * value
		elseif operation == "divide" then
			if value == 0 then
				return false, "Division by zero"
			end
			newN = currentValue / value
		elseif operation == "power" then
			newN = currentValue ^ value
		end
		if newN == nil then
			return false, "Unsupported number operation: " .. operation
		end
		local okSet, errSet = pcall(function()
			(instance :: any)[propertyName] = newN
		end)
		if not okSet then
			return false, tostring(errSet)
		end
		return true, newN
	end

	return false, "Unsupported property type or operation"
end

-- ============================================================================
-- HANDLERS
-- ============================================================================

local PropertyHandlers = {}

-- setProperty: write ONE property on ONE instance. Legacy L2742-2805.
-- LLM-stomp: refuses `Disabled = true` on companion-tagged scripts (the
-- specific failure mode the protection exists for; see module header).
PropertyHandlers.setProperty = Handler.define(
	"/api/set-property",
	function(ctx, data: SetPropertyRequest): (any, Handler.RecordResult?)
		local instancePath = data.instancePath
		local propertyName = data.propertyName
		local propertyValue = data.propertyValue

		if instancePath == nil or propertyName == nil then
			return { error = "Instance path and property name are required" }, nil
		end

		local instance = Path.getInstanceByPath(instancePath)
		if instance == nil then
			return { error = "Instance not found: " .. instancePath }, nil
		end

		-- LLM-stomp: refuse to disable a companion script. Other property
		-- writes on the companion are accepted as recoverable (the user
		-- can re-enable / fix Source / etc.); a Disabled flip would
		-- silently break the play-solo log pipeline.
		if propertyName == "Disabled" and propertyValue == true then
			local refusal = Companions.refuseIfProtected({
				services = ctx.services,
				constants = ctx.constants,
			}, instance)
			if refusal ~= nil then
				return refusal, nil
			end
		end

		local ok, finalValue = assignSingleProperty(instance, propertyName, propertyValue)
		if not ok then
			return {
				error = "Failed to set property: " .. tostring(finalValue),
				instancePath = instancePath,
				propertyName = propertyName,
			},
				nil
		end

		ctx.actionLog:stage(
			"set_property",
			instancePath,
			propertyName .. " = " .. Serialize.toDisplayString(finalValue),
			{
				propertyName = propertyName,
				newValue = Serialize.toWire(finalValue),
			}
		)

		return {
			success = true,
			instancePath = instancePath,
			propertyName = propertyName,
			propertyValue = propertyValue,
			message = "Property set successfully",
		}, {
			name = "Set Property: " .. propertyName,
			didMutate = true,
		}
	end
)

-- massSetProperty: write the SAME property on MANY instances. Legacy L2908-2966.
-- Per-path pcall; no action-log entry; one CHS waypoint covers the batch.
PropertyHandlers.massSetProperty = Handler.define(
	"/api/mass-set-property",
	function(_ctx, data: MassSetPropertyRequest): (any, Handler.RecordResult?)
		local paths = data.paths
		local propertyName = data.propertyName
		local propertyValue = data.propertyValue

		if paths == nil or #paths == 0 or propertyName == nil then
			return { error = "Paths array and property name are required" }, nil
		end

		local results: { any } = {}
		local successCount = 0
		local failCount = 0

		for _, instancePath in paths :: { string } do
			local instance = Path.getInstanceByPath(instancePath)
			if instance == nil then
				table.insert(results, { path = instancePath, success = false, error = "Instance not found" })
				failCount += 1
				continue
			end

			-- Raw assignment, NO Convert.fromWire — see module header for
			-- why this asymmetry is preserved. Legacy callers send pre-
			-- typed values to mass_set_property.
			local ok, err = pcall(function()
				(instance :: any)[propertyName] = propertyValue
			end)
			if ok then
				table.insert(results, {
					path = instancePath,
					success = true,
					propertyName = propertyName,
					propertyValue = propertyValue,
				})
				successCount += 1
			else
				table.insert(results, { path = instancePath, success = false, error = tostring(err) })
				failCount += 1
			end
		end

		return {
			results = results,
			summary = {
				total = #(paths :: { string }),
				succeeded = successCount,
				failed = failCount,
			},
		}, {
			name = "Mass Set Property: " .. propertyName,
			didMutate = successCount > 0,
		}
	end
)

-- massGetProperty: read the SAME property from MANY instances. Legacy L2968-3012.
-- READ-ONLY: returns (response, nil) so the dispatcher skips CHS / log entirely.
PropertyHandlers.massGetProperty = Handler.define(
	"/api/mass-get-property",
	function(_ctx, data: MassGetPropertyRequest): (any, Handler.RecordResult?)
		local paths = data.paths
		local propertyName = data.propertyName

		if paths == nil or #paths == 0 or propertyName == nil then
			return { error = "Paths array and property name are required" }, nil
		end

		local results: { any } = {}
		for _, instancePath in paths :: { string } do
			local instance = Path.getInstanceByPath(instancePath)
			if instance == nil then
				table.insert(results, { path = instancePath, success = false, error = "Instance not found" })
				continue
			end

			local ok, value = pcall(function()
				return (instance :: any)[propertyName]
			end)
			if ok then
				table.insert(results, {
					path = instancePath,
					success = true,
					propertyName = propertyName,
					propertyValue = Serialize.toWire(value),
				})
			else
				table.insert(results, { path = instancePath, success = false, error = tostring(value) })
			end
		end

		return {
			results = results,
			propertyName = propertyName,
		}, nil
	end
)

-- setCalculatedProperty: per-instance formula-driven value. Legacy L3411-3483.
PropertyHandlers.setCalculatedProperty = Handler.define(
	"/api/set-calculated-property",
	function(_ctx, data: SetCalculatedPropertyRequest): (any, Handler.RecordResult?)
		local paths = data.paths
		local propertyName = data.propertyName
		local formula = data.formula
		local variables = data.variables

		if paths == nil or #paths == 0 or propertyName == nil or formula == nil then
			return { error = "Paths, property name, and formula are required" }, nil
		end

		local results: { any } = {}
		local successCount = 0
		local failCount = 0

		for index, instancePath in paths :: { string } do
			local instance = Path.getInstanceByPath(instancePath)
			if instance == nil then
				table.insert(results, { path = instancePath, success = false, error = "Instance not found" })
				failCount += 1
				continue
			end

			local computed, evalError = evaluateFormula(formula :: string, variables, instance, index)
			if evalError ~= nil then
				table.insert(results, { path = instancePath, success = false, error = evalError })
				failCount += 1
				continue
			end

			local ok, err = pcall(function()
				(instance :: any)[propertyName] = computed
			end)
			if ok then
				table.insert(results, {
					path = instancePath,
					success = true,
					propertyName = propertyName,
					calculatedValue = computed,
					formula = formula,
				})
				successCount += 1
			else
				table.insert(results, { path = instancePath, success = false, error = tostring(err) })
				failCount += 1
			end
		end

		return {
			results = results,
			summary = {
				total = #(paths :: { string }),
				succeeded = successCount,
				failed = failCount,
			},
			formula = formula,
		}, {
			name = "Set Calculated Property: " .. propertyName,
			didMutate = successCount > 0,
		}
	end
)

-- setRelativeProperty: per-instance relative op on an existing value.
-- Legacy L3485-3630.
PropertyHandlers.setRelativeProperty = Handler.define(
	"/api/set-relative-property",
	function(_ctx, data: SetRelativePropertyRequest): (any, Handler.RecordResult?)
		local paths = data.paths
		local propertyName = data.propertyName
		local operation = data.operation
		local value = data.value
		local component = data.component

		if paths == nil or #paths == 0 or propertyName == nil or operation == nil or value == nil then
			return { error = "Paths, property name, operation, and value are required" }, nil
		end

		-- Coerce wire Color3-shaped values once up-front so the per-path
		-- loop doesn't pay the conversion cost N times.
		local coercedValue: any = value
		if type(value) == "table" and (value.R ~= nil or value.G ~= nil or value.B ~= nil) then
			coercedValue = Color3.new(value.R or 0, value.G or 0, value.B or 0)
		end

		local results: { any } = {}
		local successCount = 0
		local failCount = 0

		for _, instancePath in paths :: { string } do
			local instance = Path.getInstanceByPath(instancePath)
			if instance == nil then
				table.insert(results, { path = instancePath, success = false, error = "Instance not found" })
				failCount += 1
				continue
			end

			local ok, newOrErr = applyRelative(instance, propertyName, operation :: string, coercedValue, component)
			if ok then
				table.insert(results, {
					path = instancePath,
					success = true,
					propertyName = propertyName,
					operation = operation,
					value = value,
					component = component,
					newValue = Serialize.toWire(newOrErr),
				})
				successCount += 1
			else
				table.insert(results, { path = instancePath, success = false, error = tostring(newOrErr) })
				failCount += 1
			end
		end

		return {
			results = results,
			summary = {
				total = #(paths :: { string }),
				succeeded = successCount,
				failed = failCount,
			},
			operation = operation,
			value = value,
		}, {
			name = "Set Relative Property: " .. propertyName,
			didMutate = successCount > 0,
		}
	end
)

return PropertyHandlers
