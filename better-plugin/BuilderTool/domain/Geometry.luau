--!strict
-- domain/Geometry.luau
--
-- PURE geometry math (ARCHITECTURE §7/§17). No Roblox services, no Context —
-- fully Lune-unit-testable. Tools call these; the viewport layer only
-- renders the result.

local Geometry = {}

-- Bounding region (CFrame + size) enclosing a set of parts in world space.
function Geometry.boundingBox(_parts: { BasePart }): (CFrame, Vector3)
	-- TODO(impl): aggregate part CFrames/sizes into a world-aligned box.
	error("Geometry.boundingBox not implemented — see ARCHITECTURE.md §17")
end

return Geometry
