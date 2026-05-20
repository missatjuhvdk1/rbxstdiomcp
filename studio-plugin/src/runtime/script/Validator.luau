--!strict
-- runtime/script/Validator.luau
--
-- Lua source syntax validation. Legacy plugin.luau L3866-3902.
--
-- This module legitimately uses `loadstring` to probe the parser:
-- `loadstring(source)` returns (function|nil, errmsg). If err is nil the
-- source compiles. We do NOT run the function — we throw it away after
-- the parse check completes.
--
-- ============================================================================
-- WHY THIS FILE IS WHITELISTED FROM THE `loadstring` PROHIBITION
-- ============================================================================
-- ARCHITECTURE §15 A7 bans loadstring across the codebase. The CI gate
-- (tools/golden/check.lune.luau) enforces this with a hard fail except for
-- two explicitly whitelisted files:
--
--   1. src/domain/handlers/ExecuteLuaHandler.luau   (the user-asked-for-it case)
--   2. src/runtime/script/Validator.luau            (this file)
--
-- The Validator's use is read-only: we never execute the returned function,
-- only inspect whether one was produced. The alternative — implementing a
-- Lua parser in Luau — would be 10000+ lines of code that drifts from the
-- actual Roblox parser. Probing the real parser is the correct trade-off.
--
-- Calling pattern is double-wrapped in pcall because in some Studio
-- versions an obviously-invalid source has caused loadstring ITSELF to
-- raise rather than return an error. The outer pcall absorbs that case.

-- selene: allow(incorrect_standard_library_use, deprecated)
-- stylua: skip-next-line
-- NOTE: do NOT remove the selene allow above. selene's default config flags
-- loadstring as deprecated (it is in Lua 5.4, but Luau retains it). This
-- file deliberately uses it.

local Validator = {}

export type Result = {
	valid: boolean,
	-- Empty when valid; one or more error strings otherwise. We return a
	-- LIST (not a single string) so a future per-statement check can grow
	-- here without breaking the wire format.
	errors: { string },
}

function Validator.validate(source: string): Result
	if source == nil then
		return { valid = false, errors = { "source is nil" } }
	end

	-- loadstring is exposed on _G in Luau and may be nil in environments
	-- where the host disabled it (e.g. ServerScriptService with
	-- LoadStringEnabled = false). Falling back to "valid = false" would be
	-- a false negative; instead we surface the inability to validate as a
	-- distinct error string the caller can act on.
	local loadstringFn = (loadstring :: any) :: ((src: string) -> (any, string?))?
	if type(loadstringFn) ~= "function" then
		return {
			valid = false,
			errors = {
				"loadstring is unavailable in this environment; " .. "cannot validate Lua syntax",
			},
		}
	end

	local outerOk, outerResult = pcall(function()
		local fn, err = loadstringFn(source)
		if err ~= nil then
			return { valid = false, errors = { err } }
		end
		if fn == nil then
			-- Defensive: per docs we either get a function or an error.
			-- If somehow neither came back, refuse the source.
			return { valid = false, errors = { "loadstring returned no function and no error" } }
		end
		return { valid = true, errors = {} }
	end)

	if not outerOk then
		return {
			valid = false,
			errors = { "loadstring raised: " .. tostring(outerResult) },
		}
	end

	return outerResult :: Result
end

return Validator
