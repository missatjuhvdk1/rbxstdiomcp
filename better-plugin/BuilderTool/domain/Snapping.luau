--!strict
-- domain/Snapping.luau
--
-- PURE snapping math (ARCHITECTURE §7/§17). No Roblox services, no Context.
-- Grid snap, surface snap, rotation increments. Lune-unit-tested.

local Snapping = {}

-- Snap a world position to the grid when enabled.
function Snapping.snapToGrid(position: Vector3, gridSize: number, enabled: boolean): Vector3
	if not enabled or gridSize <= 0 then
		return position
	end
	local function s(n: number): number
		return math.round(n / gridSize) * gridSize
	end
	return Vector3.new(s(position.X), s(position.Y), s(position.Z))
end

-- Snap an angle (degrees) to the rotation increment.
function Snapping.snapAngle(degrees: number, increment: number): number
	if increment <= 0 then
		return degrees
	end
	return math.round(degrees / increment) * increment
end

return Snapping
