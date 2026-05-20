--!strict
-- runtime/instance/Path.luau
--
-- THE one place that converts between dotted instance paths
-- ("game.Workspace.Part") and live Instance references. The legacy
-- plugin.luau had `getInstanceByPath` at L2108 and `getInstancePath` at
-- L1650; both are reproduced here with identical semantics so any future
-- handler that consumes a wire-format path resolves it the same way.
--
-- Why a dedicated module and not "just inline it":
--   1. EVERY handler that takes a path arg uses these. If we duplicate the
--      logic, a future fix (e.g. handling escaped dots in instance names)
--      has to find N copies. The legacy file already had subtle drift
--      between getInstancePath and the path-building inside getFileTree.
--   2. The next phase's destructive-mutation refusal list needs to walk
--      the resolved Instance — having the resolver as a pure function
--      makes the refusal check trivial.
--   3. We can unit-test these without touching Studio: the tests substitute
--      a fake `root` instance.
--
-- Limitations carried forward from legacy (documented so they're not bugs):
--   - Names containing literal "." cannot be addressed (no escape syntax).
--     Studio's GetFullName has the same limitation; mirror its behaviour
--     rather than introduce a new escape that callers would have to learn.
--   - The path "game" and "" both resolve to game itself (legacy L2109).

local Path = {}

-- Parse a dotted path into a list of name segments, stripping the optional
-- "game." prefix. Returns an empty list for "game" / "" (i.e. root).
local function splitSegments(path: string): { string }
	-- Normalise: strip a single leading "game." if present.
	local stripped = path:gsub("^game%.", "")
	-- If the input was just "game" or "", stripped is now "" or "game".
	-- Treat both as root.
	if stripped == "" or stripped == "game" then
		return {}
	end

	local out: { string } = {}
	for segment in stripped:gmatch("[^%.]+") do
		table.insert(out, segment)
	end
	return out
end

-- Resolve a dotted path to an Instance under `root` (defaults to `game`).
-- Returns nil when any segment is missing — callers are responsible for
-- turning that into a user-visible "Path not found: <path>" error.
--
-- We accept `root` as a parameter for testability (pass a Folder to scope
-- the lookup), but production callers always pass game (or omit it).
function Path.getInstanceByPath(path: string, root: Instance?): Instance?
	local origin: Instance = root or game

	if path == "game" or path == "" then
		return origin
	end

	local current: Instance? = origin
	for _, name in splitSegments(path) do
		if current == nil then
			return nil
		end
		current = (current :: Instance):FindFirstChild(name)
	end
	return current
end

-- Build a dotted path from an Instance up to the data-model root.
-- Mirrors legacy L1650; returns "game" for the root itself.
--
-- We deliberately do NOT use instance:GetFullName() because that returns
-- e.g. "Workspace.Part" (no leading "game.") and uses spaces around the
-- separator inconsistently across Studio versions; we want a canonical
-- form the bridge can roundtrip.
function Path.getInstancePath(instance: Instance?): string
	if instance == nil or instance == game then
		return "game"
	end
	-- Local copy so Luau narrows the nil branch out.
	local i = instance :: Instance

	local segments: { string } = {}
	local current: Instance? = i
	while current ~= nil and current ~= game do
		table.insert(segments, 1, (current :: Instance).Name)
		current = (current :: Instance).Parent
	end

	if current ~= game then
		-- The instance isn't in the data model (orphaned / Destroyed mid-walk).
		-- Return the best-effort path so debug output is still useful.
		return "<orphan>." .. table.concat(segments, ".")
	end

	if #segments == 0 then
		return "game"
	end
	return "game." .. table.concat(segments, ".")
end

return Path
