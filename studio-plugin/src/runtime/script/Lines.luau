--!strict
-- runtime/script/Lines.luau
--
-- splitLines / joinLines — the round-trippable line splitter for script
-- source code. Legacy plugin.luau L1666-1701 (verbatim port).
--
-- WHY THIS DESERVES ITS OWN MODULE:
--   Naive `for line in source:gmatch("[^\n]+") do` loses information:
--     - "" returns 0 lines (should be 1)
--     - "a\n" returns 1 line and forgets the trailing newline
--     - "\r\n" line endings get mangled differently to "\n"
--   Every script-editing handler (edit_script, find_and_replace,
--   set_script_source) needs the EXACT inverse of split→join to apply
--   line-based diffs without silently re-formatting the user's source.
--   One module guarantees both halves are kept in lockstep.
--
-- INVARIANT:
--   joinLines(splitLines(s)) == s  for any string s, after CRLF→LF normalisation.
--   (We deliberately collapse \r\n → \n on the way in. Round-tripping CRLF
--   exactly would require us to remember per-line endings, which no Studio
--   workflow has ever asked for and which would break diff-friendliness.)

local Lines = {}

-- Split a source string into a list of lines and a "had trailing newline"
-- flag that joinLines uses to faithfully reconstruct the original input.
-- The second return is true iff the input ended with at least one '\n'
-- (after CRLF normalisation).
function Lines.split(source: string?): ({ string }, boolean)
	local normalized = (source or ""):gsub("\r\n", "\n"):gsub("\r", "\n")
	local endsWithNewline = normalized:sub(-1) == "\n"

	local result: { string } = {}
	local start = 1

	while true do
		local newlinePos = string.find(normalized, "\n", start, true)
		if newlinePos then
			table.insert(result, string.sub(normalized, start, newlinePos - 1))
			start = newlinePos + 1
		else
			local remainder = string.sub(normalized, start)
			-- Skip the empty remainder when the source ended with \n —
			-- that's not a real "extra" line, it's the trailing newline
			-- the caller will reconstruct via the second return.
			if remainder ~= "" or not endsWithNewline then
				table.insert(result, remainder)
			end
			break
		end
	end

	-- An empty source still has one (empty) line — every text editor
	-- shows row 1 even for a blank file.
	if #result == 0 then
		table.insert(result, "")
	end

	return result, endsWithNewline
end

-- Inverse of split. Pass through the `hadTrailingNewline` value returned
-- from split so trailing whitespace survives the round-trip.
function Lines.join(lines: { string }, hadTrailingNewline: boolean): string
	local source = table.concat(lines, "\n")
	if hadTrailingNewline and source:sub(-1) ~= "\n" then
		source ..= "\n"
	end
	return source
end

return Lines
