--!strict
-- domain/handlers/ScriptHandlers.luau
--
-- Script-source inspection AND mutation. Eight endpoints:
--   - getScriptSource             ← legacy plugin.luau L3632-3731 (read, Phase 3)
--   - searchScript                ← legacy plugin.luau L4050-4118 (read, Phase 3)
--   - grep                        ← legacy plugin.luau L4120-4329 (read, Phase 3)
--   - getScriptFunction           ← legacy plugin.luau L4331-4460 (read, Phase 3)
--   - setScriptSource             ← legacy plugin.luau L3733-3865 (write, Phase 4)
--   - editScript                  ← legacy plugin.luau L3904-4049 (write, Phase 4)
--   - findAndReplaceInScripts     ← legacy plugin.luau L4462-4606 (write, Phase 4)
--   - validateScript              ← legacy plugin.luau L5156-5280 (read, Phase 4)
--
-- ============================================================================
-- WHY THIS MODULE IS >400 LINES
-- ============================================================================
-- The architecture guide's "soft cap" is 400 lines per module. This module
-- legitimately exceeds it because the read AND write halves of script
-- handling SHARE the Lines.split contract, the Lua-pattern function-extract
-- heuristic, and the LuaSourceContainer:IsA gating. Splitting into a
-- separate ScriptMutationHandlers.luau would either:
--   (a) duplicate those helpers across two modules (drift risk), or
--   (b) extract them to a `domain/handlers/script_internal.luau` shared
--       module — but domain/handlers/ may not import each other, and
--       runtime/script/ already owns the genuinely-shared helpers
--       (Lines, Validator). The remaining shared state is purely "I know
--       how to detect a script" which doesn't justify a separate file.
-- Keep them together. The line-count is in service of "one greppable owner
-- of script handling".
--
-- ============================================================================
-- THE SOURCE-EDIT UNDO DECOUPLING (Phase 4 Bug 1 fix)
-- ============================================================================
-- Roblox CHS does NOT capture .Source assignments. If we just wrote Source
-- in a recording window, the user's Ctrl+Z would skip past our source edit
-- and revert some unrelated waypoint underneath ours. The fix is the
-- isSourceEditOnly RecordResult flag (Handler.luau): for every handler
-- here that ONLY changes .Source, we return
--   { isSourceEditOnly = true, scriptEdits = { ... } }
-- where each scriptEdit carries { instancePath, preSource, postSource }.
-- The Dispatcher then:
--   1. Cancels the CHS recording (no waypoint to keep).
--   2. Commits the ActionLog entry (which carries scriptEdits in details).
-- The plugin-side undo path (ActionLog:undo) detects entries with
-- non-empty scriptEdits and restores .Source manually, BYPASSING CHS.
-- Net: Ctrl+Z reverts our edit, real undo, no collateral damage.
--
-- ============================================================================
-- LLM-STOMP PROTECTION
-- ============================================================================
-- Every mutating handler in this module checks Companions.refuseIfProtected
-- against the resolved target instance. The companion scripts are the
-- single most expensive thing for an LLM to overwrite — it's how the
-- play-solo log pipeline gets to the AI, and a corrupted companion source
-- means a play-solo session with no diagnostics. Refusal is mandatory here.
--
-- ============================================================================
-- WHY validateScript IS READ-ONLY
-- ============================================================================
-- validateScript probes loadstring; it never assigns .Source. So it
-- returns (response, nil) and the dispatcher skips CHS and ActionLog
-- entirely. The reason it's grouped here is the typical caller is
-- "I'm about to set_script_source; let me check syntax first".
--
-- ============================================================================
-- WHY ALL FOUR USE Lines.split, NOT THEIR OWN PARSER
-- ============================================================================
-- runtime/script/Lines.luau owns the canonical split/join contract: ONE
-- inverse pair, used by both read AND write handlers so an
-- edit_script(line=N) sees the same line N that get_script_source(N)
-- reported. The legacy file had three subtly different inline splitters;
-- the consolidation here is the single biggest correctness improvement
-- in Phase 3's script handler set (see Lines.luau header for examples
-- of the legacy splitters' edge-case bugs).
--
-- ============================================================================
-- WHY grep IS A SCRIPT HANDLER AND NOT A FILE-TREE HANDLER
-- ============================================================================
-- grep walks descendants like FileTreeHandlers.searchFiles, but its
-- primary use case is content scanning of script Source. Co-locating it
-- with the other script-source readers makes sense because:
--   1. Its pattern semantics, multiline mode, contextBefore/After all
--      operate on Lines.split output — same as searchScript.
--   2. Future grep extensions (regex flavours, --include semantics) will
--      land alongside the file-aware searchScript / find_and_replace
--      changes; one module reduces the churn surface.
-- The lone twist is grep can ALSO match non-script instances by name/
-- className alone (when typeFilter expands beyond LuaSourceContainer).
-- We preserve that surface verbatim — see the `(not isScript)` clause
-- in the body.
--
-- ============================================================================
-- LARGE-SCRIPT TRUNCATION (getScriptSource only)
-- ============================================================================
-- Scripts >50000 chars without an explicit startLine/endLine get
-- truncated to their first 1000 lines and the response carries
-- `truncated = true` + a `note` field. Legacy L3704-3717. The cap exists
-- because the bridge's HTTP body limit is finite and a 200k-line script
-- would OOM the AI's context faster than it would the bridge buffer.

local Handler = require(script.Parent.Parent.handler.Handler)
local Path = require(script.Parent.Parent.Parent.runtime.instance.Path)
local Lines = require(script.Parent.Parent.Parent.runtime.script.Lines)
local Validator = require(script.Parent.Parent.Parent.runtime.script.Validator)
local Companions = require(script.Parent.Parent.Parent.runtime.testsession.Companions)

-- ============================================================================
-- TYPED REQUEST/RESPONSE SHAPES
-- ============================================================================

type GetScriptSourceRequest = {
	instancePath: string?,
	startLine: number?,
	endLine: number?,
}

type SearchScriptRequest = {
	instancePath: string?,
	pattern: string?,
	useRegex: boolean?,
	contextLines: number?,
}

type GrepRequest = {
	pattern: string?,
	path: string?,
	glob: string?,
	type: { string }?,
	caseInsensitive: boolean?,
	after: number?,
	before: number?,
	context: number?,
	outputMode: string?,
	headLimit: number?,
	multiline: boolean?,
}

type GetScriptFunctionRequest = {
	instancePath: string?,
	functionName: string?,
}

type SetScriptSourceRequest = {
	instancePath: string?,
	source: string?,
}

type EditScriptRequest = {
	instancePath: string?,
	operation: string?, -- "replace_lines" | "insert_lines" | "delete_lines"
	startLine: number?,
	endLine: number?,
	newContent: string?,
}

type FindAndReplaceInScriptsRequest = {
	path: string?,
	findText: string?,
	replaceText: string?,
	useRegex: boolean?,
	caseInsensitive: boolean?,
	dryRun: boolean?,
	scriptPaths: { string }?,
}

type ValidateScriptRequest = {
	instancePath: string?,
	source: string?,
}

-- ============================================================================
-- CAPS
-- ============================================================================

-- Source-size cap for getScriptSource auto-truncation. Legacy L3704.
local LARGE_SOURCE_CHAR_THRESHOLD = 50000
-- Truncated-mode line cap. Legacy L3707.
local LARGE_SOURCE_LINE_LIMIT = 1000

-- ============================================================================
-- HANDLERS
-- ============================================================================

local ScriptHandlers = {}

-- getScriptSource: full script source + numbered form, with optional
-- line-range selection and auto-truncation for huge scripts.
-- Legacy L3632-3731.
ScriptHandlers.getScriptSource = Handler.define(
	"/api/get-script-source",
	function(_ctx, data: GetScriptSourceRequest): (any, Handler.RecordResult?)
		local instancePath = data.instancePath
		local startLine = data.startLine
		local endLine = data.endLine

		if instancePath == nil then
			return { error = "Instance path is required" }, nil
		end

		local instance = Path.getInstanceByPath(instancePath)
		if instance == nil then
			return { error = "Instance not found: " .. instancePath }, nil
		end

		if not instance:IsA("LuaSourceContainer") then
			return { error = "Instance is not a script-like object: " .. instance.ClassName }, nil
		end

		local ok, result = pcall(function()
			local fullSource = (instance :: LuaSourceContainer).Source
			local lines, hasTrailingNewline = Lines.split(fullSource)
			local totalLineCount = #lines

			local sourceToReturn = fullSource
			local returnedStartLine = 1
			local returnedEndLine = totalLineCount

			if startLine ~= nil or endLine ~= nil then
				local actualStartLine = math.max(1, startLine or 1)
				local actualEndLine = math.min(#lines, endLine or #lines)

				local selectedLines: { string } = {}
				for i = actualStartLine, actualEndLine do
					table.insert(selectedLines, lines[i] or "")
				end

				sourceToReturn = table.concat(selectedLines, "\n")
				-- Preserve trailing newline if (a) the original had one and
				-- (b) we're returning the tail of the file. Mirrors L3670-3672.
				if hasTrailingNewline and actualEndLine == #lines and string.sub(sourceToReturn, -1) ~= "\n" then
					sourceToReturn ..= "\n"
				end
				returnedStartLine = actualStartLine
				returnedEndLine = actualEndLine
			end

			-- Build the numbered form. For the partial case we re-split
			-- `sourceToReturn` so numbering aligns with what we actually
			-- returned in `source` (handles odd trailing-newline cases).
			local linesToNumber: { string }
			if startLine ~= nil then
				linesToNumber = Lines.split(sourceToReturn)
			else
				linesToNumber = lines
			end
			local lineOffset = returnedStartLine - 1
			local numberedLines: { string } = {}
			for i, line in linesToNumber do
				table.insert(numberedLines, tostring(i + lineOffset) .. ": " .. line)
			end
			local numberedSource = table.concat(numberedLines, "\n")

			local resp: { [string]: any } = {
				instancePath = instancePath,
				className = instance.ClassName,
				name = instance.Name,
				source = sourceToReturn,
				numberedSource = numberedSource,
				sourceLength = string.len(fullSource),
				lineCount = totalLineCount,
				startLine = returnedStartLine,
				endLine = returnedEndLine,
				isPartial = (startLine ~= nil or endLine ~= nil),
				truncated = false,
			}

			-- Large-script auto-truncation. Only kicks in when the caller did
			-- NOT specify a range (i.e. they asked for "everything") and the
			-- source exceeds LARGE_SOURCE_CHAR_THRESHOLD. Legacy L3704-3717.
			if startLine == nil and endLine == nil and string.len(fullSource) > LARGE_SOURCE_CHAR_THRESHOLD then
				local maxLines = math.min(LARGE_SOURCE_LINE_LIMIT, #lines)
				local truncatedLines: { string } = {}
				local truncatedNumberedLines: { string } = {}
				for i = 1, maxLines do
					table.insert(truncatedLines, lines[i])
					table.insert(truncatedNumberedLines, tostring(i) .. ": " .. lines[i])
				end
				resp.source = table.concat(truncatedLines, "\n")
				resp.numberedSource = table.concat(truncatedNumberedLines, "\n")
				resp.truncated = true
				resp.endLine = maxLines
				resp.note =
					"Script truncated to first 1000 lines. Use startLine/endLine parameters to read specific sections."
			end

			if instance:IsA("BaseScript") then
				resp.enabled = (instance :: BaseScript).Enabled
			end
			return resp
		end)

		if ok then
			return result, nil
		else
			return { error = "Failed to get script source: " .. tostring(result) }, nil
		end
	end
)

-- searchScript: per-line pattern search inside ONE script, with optional
-- before/after context lines. Legacy L4050-4118. The `useRegex` flag
-- switches between Lua-pattern (string.match) and plain substring
-- (string.find with plain=true).
ScriptHandlers.searchScript = Handler.define(
	"/api/search-script",
	function(_ctx, data: SearchScriptRequest): (any, Handler.RecordResult?)
		local instancePath = data.instancePath
		local pattern = data.pattern
		local useRegex = data.useRegex == true
		local contextLines = data.contextLines or 0

		if instancePath == nil or pattern == nil then
			return { error = "Instance path and pattern are required" }, nil
		end

		local instance = Path.getInstanceByPath(instancePath)
		if instance == nil then
			return { error = "Instance not found: " .. instancePath }, nil
		end

		if not instance:IsA("LuaSourceContainer") then
			return { error = "Instance is not a script: " .. instance.ClassName }, nil
		end

		local ok, result = pcall(function()
			local source = (instance :: LuaSourceContainer).Source
			local lines, _ = Lines.split(source)
			local matches: { any } = {}

			for lineNum, line in lines do
				local found
				if useRegex then
					found = string.match(line, pattern) ~= nil
				else
					found = string.find(line, pattern, 1, true) ~= nil
				end

				if found then
					local match: { [string]: any } = {
						lineNumber = lineNum,
						content = line,
						context = {},
					}
					if contextLines > 0 then
						for i = math.max(1, lineNum - contextLines), lineNum - 1 do
							table.insert(match.context, { lineNumber = i, content = lines[i], type = "before" })
						end
						for i = lineNum + 1, math.min(#lines, lineNum + contextLines) do
							table.insert(match.context, { lineNumber = i, content = lines[i], type = "after" })
						end
					end
					table.insert(matches, match)
				end
			end

			return {
				instancePath = instancePath,
				pattern = pattern,
				useRegex = useRegex,
				matches = matches,
				matchCount = #matches,
				totalLines = #lines,
			}
		end)

		if ok then
			return result, nil
		else
			return { error = "Failed to search script: " .. tostring(result) }, nil
		end
	end
)

-- grep: Claude-Code-style search across the instance tree. Walks
-- descendants of `path`, pre-filters by `type` (IsA) and `glob` (Lua
-- pattern over Name), then scans script Source. Three output modes
-- mirror `grep -l` / `grep` / `grep -c`. Legacy L4120-4329.
--
-- The three output modes have different payload shapes; we preserve
-- them bit-identical because the TS bridge unpacks them with mode-
-- specific code:
--   files_with_matches: { mode, ..., matches = [{path, className, name}] }
--   content:            { mode, ..., matches = [..., lines = [{lineNumber, content, context}]], totalMatches }
--   count:              { mode, ..., matches = [..., count], totalMatches }
ScriptHandlers.grep = Handler.define("/api/grep", function(_ctx, data: GrepRequest): (any, Handler.RecordResult?)
	local pattern = data.pattern
	if type(pattern) ~= "string" or #pattern == 0 then
		return { error = 'pattern is required (use ".*" for name-only searches)' }, nil
	end

	local rootPath = data.path
	if type(rootPath) ~= "string" or #(rootPath :: string) == 0 then
		rootPath = "game"
	end

	local glob = data.glob
	if type(glob) ~= "string" or #(glob :: string) == 0 then
		glob = nil
	end

	local typeFilter = data.type
	if typeof(typeFilter) ~= "table" or #(typeFilter :: { string }) == 0 then
		typeFilter = { "LuaSourceContainer" }
	end

	local caseInsensitive = data.caseInsensitive == true
	local outputMode = data.outputMode or "files_with_matches"
	if outputMode ~= "files_with_matches" and outputMode ~= "content" and outputMode ~= "count" then
		return { error = "outputMode must be one of: files_with_matches, content, count" }, nil
	end

	local contextAround = tonumber(data.context) or 0
	local contextAfter = tonumber(data.after) or 0
	local contextBefore = tonumber(data.before) or 0
	if contextAround > 0 then
		-- -C overrides -A/-B, matching real grep semantics.
		contextAfter = contextAround
		contextBefore = contextAround
	end

	local headLimit = tonumber(data.headLimit) or 0
	local multiline = data.multiline == true

	-- Resolve root.
	local rootInstance: Instance?
	if rootPath == "game" or rootPath == "" then
		rootInstance = game
	else
		rootInstance = Path.getInstanceByPath(rootPath :: string)
		if rootInstance == nil then
			return { error = "Path not found: " .. (rootPath :: string) }, nil
		end
	end

	-- Case-folding helper. We can't use a "(?i)" Lua-pattern prefix,
	-- so we lowercase both haystack and needle when caseInsensitive is
	-- set. Original-case line content is preserved in the response.
	local function caseFold(s: string): string
		if caseInsensitive then
			return string.lower(s)
		end
		return s
	end

	local patternFolded = caseFold(pattern :: string)
	local globFolded = if glob then caseFold(glob :: string) else nil

	-- GetDescendants + the root itself, so grep on a specific Script
	-- path works even though that path is the root, not a descendant.
	local descendants = (rootInstance :: Instance):GetDescendants()
	table.insert(descendants, 1, rootInstance :: Instance)

	local scanned = 0
	local matches: { any } = {}
	local totalMatches = 0
	local hitLimit = false

	for _, inst in descendants do
		-- Type filter: pass if inst:IsA(name) for ANY name in typeFilter.
		local typeOk = false
		for _, t in typeFilter :: { string } do
			local isAOk, isA = pcall(function()
				return inst:IsA(t)
			end)
			if isAOk and isA then
				typeOk = true
				break
			end
		end
		if not typeOk then
			continue
		end

		-- Glob filter: Lua-pattern match against Name.
		if globFolded ~= nil then
			local nameFolded = caseFold(inst.Name)
			if string.find(nameFolded, globFolded) == nil then
				continue
			end
		end

		scanned += 1

		local isScript = inst:IsA("LuaSourceContainer")
		local source = ""
		if isScript then
			local sourceOk, src = pcall(function()
				return (inst :: LuaSourceContainer).Source
			end)
			if sourceOk and src ~= nil then
				source = src
			end
		end

		local instMatchCount = 0
		local lineHits: { any }? = nil

		if isScript and #source > 0 then
			if multiline then
				-- Whole-source match; report a single virtual line for
				-- simplicity. The matched substring (capped at 500 chars)
				-- becomes the "line content" so the AI sees the actual hit.
				local hay = caseFold(source)
				local s, e = string.find(hay, patternFolded)
				if s ~= nil then
					instMatchCount = 1
					if outputMode == "content" then
						local snippet = string.sub(source, s :: number, math.min(e :: number, (s :: number) + 500))
						lineHits = { { lineNumber = 1, content = snippet, context = {} } }
					end
				end
			else
				local lines, _ = Lines.split(source)
				for lineNum, line in lines do
					local hay = caseFold(line)
					if string.find(hay, patternFolded) ~= nil then
						instMatchCount += 1
						if outputMode == "content" then
							if lineHits == nil then
								lineHits = {}
							end
							local hit: { [string]: any } = {
								lineNumber = lineNum,
								content = line,
								context = {},
							}
							if contextBefore > 0 then
								for i = math.max(1, lineNum - contextBefore), lineNum - 1 do
									table.insert(hit.context, { lineNumber = i, content = lines[i], type = "before" })
								end
							end
							if contextAfter > 0 then
								for i = lineNum + 1, math.min(#lines, lineNum + contextAfter) do
									table.insert(hit.context, { lineNumber = i, content = lines[i], type = "after" })
								end
							end
							table.insert(lineHits :: { any }, hit)
						end
					end
				end
			end
		end

		-- Non-script instances that pass name/class filters count as
		-- name-only hits, so grep doubles as a unified search.
		local isHit = (instMatchCount > 0) or not isScript
		if not isHit then
			continue
		end

		totalMatches += instMatchCount

		local entry: { [string]: any } = {
			path = Path.getInstancePath(inst),
			className = inst.ClassName,
			name = inst.Name,
		}
		if outputMode == "content" then
			entry.lines = lineHits or {}
		elseif outputMode == "count" then
			entry.count = instMatchCount
		end
		table.insert(matches, entry)

		if headLimit > 0 and #matches >= headLimit then
			hitLimit = true
			break
		end
	end

	local response: { [string]: any } = {
		mode = outputMode,
		pattern = pattern,
		path = rootPath,
		scanned = scanned,
		matchCount = #matches,
		matches = matches,
	}
	if outputMode ~= "files_with_matches" then
		response.totalMatches = totalMatches
	end
	if hitLimit then
		response.truncated = true
		response.note = string.format(
			"Output truncated at head_limit=%d. Increase head_limit or narrow with `glob`/`path`/`type`.",
			headLimit
		)
	end
	return response, nil
end)

-- getScriptFunction: extract one named function from a script by walking
-- the source line-by-line and tracking nesting depth.
-- Legacy L4331-4460.
--
-- The depth tracker is intentionally crude — it counts `function`/`if
-- ... then`/`for ... do`/`while ... do`/`do` openers and bare `end`
-- closers. It does NOT parse strings or comments, so an `end` inside a
-- multi-line string would confuse it. That limitation is preserved
-- because (a) any real Luau parser pulled in here would be a Phase 5
-- scope expansion, and (b) the legacy heuristic worked for the
-- straightforward function-extraction cases the AI actually asks for.
ScriptHandlers.getScriptFunction = Handler.define(
	"/api/get-script-function",
	function(_ctx, data: GetScriptFunctionRequest): (any, Handler.RecordResult?)
		local instancePath = data.instancePath
		local functionName = data.functionName

		if instancePath == nil or functionName == nil then
			return { error = "Instance path and function name are required" }, nil
		end

		local instance = Path.getInstanceByPath(instancePath)
		if instance == nil then
			return { error = "Instance not found: " .. instancePath }, nil
		end

		if not instance:IsA("LuaSourceContainer") then
			return { error = "Instance is not a script: " .. instance.ClassName }, nil
		end

		local ok, result = pcall(function()
			local source = (instance :: LuaSourceContainer).Source
			local lines, _ = Lines.split(source)

			local functionStart: number? = nil
			local functionEnd: number? = nil
			local depth = 0
			local inFunction = false

			-- Four patterns cover the common Lua/Luau function-declaration
			-- shapes. We use string.match (Lua patterns, NOT regex) — the
			-- legacy patterns are reproduced verbatim.
			local patterns = {
				"^%s*function%s+" .. functionName .. "%s*%(",
				"^%s*local%s+function%s+" .. functionName .. "%s*%(",
				functionName .. "%s*=%s*function%s*%(",
				"local%s+" .. functionName .. "%s*=%s*function%s*%(",
			}

			for lineNum, line in lines do
				if not inFunction then
					for _, pat in patterns do
						if string.match(line, pat) ~= nil then
							functionStart = lineNum
							inFunction = true
							depth = 1
							-- One-liner detector: the function also ends on
							-- this line (e.g. `local f = function() end`).
							if
								string.match(line, "%send%s*$") ~= nil
								or string.match(line, "%send%s*[%)%];,]") ~= nil
							then
								functionEnd = lineNum
								inFunction = false
							end
							break
						end
					end
				else
					-- Count openers. We're inside the body now, so any new
					-- block opener increments depth and the matching `end`
					-- decrements it. False positives (commented `function`,
					-- `function` inside strings) are accepted limitations.
					if
						string.match(line, "^%s*function%s") ~= nil
						or string.match(line, "=%s*function%s*%(") ~= nil
					then
						depth += 1
					end
					if string.match(line, "^%s*if%s") ~= nil and string.match(line, "%sthen%s*$") ~= nil then
						depth += 1
					end
					if string.match(line, "^%s*for%s") ~= nil and string.match(line, "%sdo%s*$") ~= nil then
						depth += 1
					end
					if string.match(line, "^%s*while%s") ~= nil and string.match(line, "%sdo%s*$") ~= nil then
						depth += 1
					end
					if string.match(line, "^%s*do%s*$") ~= nil then
						depth += 1
					end

					if
						string.match(line, "^%s*end%s*$") ~= nil
						or string.match(line, "^%s*end[%)%],;%s]") ~= nil
						or string.match(line, "%send%s*$") ~= nil
					then
						depth -= 1
						if depth == 0 then
							functionEnd = lineNum
							break
						end
					end
				end
			end

			if functionStart == nil then
				return {
					success = false,
					error = "Function '" .. functionName .. "' not found in script",
					hint = "Check the function name spelling. Use search_script to find available functions.",
				}
			end

			if functionEnd == nil then
				return {
					success = false,
					error = "Could not find the end of function '"
						.. functionName
						.. "' - the function may be malformed",
					startLine = functionStart,
				}
			end

			local startIdx = functionStart :: number
			local endIdx = functionEnd :: number

			local functionLines: { string } = {}
			for i = startIdx, endIdx do
				table.insert(functionLines, lines[i])
			end
			local functionSource = table.concat(functionLines, "\n")

			local numberedLines: { string } = {}
			for i = startIdx, endIdx do
				table.insert(numberedLines, string.format("%4d: %s", i, lines[i]))
			end
			local numberedSource = table.concat(numberedLines, "\n")

			return {
				success = true,
				instancePath = instancePath,
				functionName = functionName,
				startLine = startIdx,
				endLine = endIdx,
				lineCount = endIdx - startIdx + 1,
				source = functionSource,
				numberedSource = numberedSource,
			}
		end)

		if ok then
			return result, nil
		else
			return { error = "Failed to get function: " .. tostring(result) }, nil
		end
	end
)

-- ============================================================================
-- MUTATION HANDLERS (Phase 4)
-- ============================================================================
-- Every handler below returns isSourceEditOnly = true with the scriptEdits
-- list of pre/post snapshots, so the Dispatcher cancels the CHS recording
-- (no waypoint exists for .Source assignments) and commits the ActionLog
-- entry — which is what powers the plugin-side undo/redo of script edits.

-- Internal: convenience to resolve a script-or-error in one place. Returns
-- (LuaSourceContainer, nil) on success or (nil, errorTable) on failure.
local function resolveScript(instancePath: string?): (LuaSourceContainer?, { [string]: any }?)
	if instancePath == nil then
		return nil, { error = "Instance path is required" }
	end
	local instance = Path.getInstanceByPath(instancePath)
	if instance == nil then
		return nil, { error = "Instance not found: " .. instancePath }
	end
	if not instance:IsA("LuaSourceContainer") then
		return nil, { error = "Instance is not a script: " .. instance.ClassName }
	end
	return instance :: LuaSourceContainer, nil
end

-- setScriptSource: overwrite the entire .Source of one script.
-- Legacy L3733-3865.
ScriptHandlers.setScriptSource = Handler.define(
	"/api/set-script-source",
	function(ctx, data: SetScriptSourceRequest): (any, Handler.RecordResult?)
		local instancePath = data.instancePath
		local newSource = data.source

		if newSource == nil then
			return { error = "source is required" }, nil
		end

		local instance, err = resolveScript(instancePath)
		if err ~= nil then
			return err, nil
		end
		local script = instance :: LuaSourceContainer

		-- LLM-stomp: refuse to overwrite a companion's source.
		local refusal = Companions.refuseIfProtected({
			services = ctx.services,
			constants = ctx.constants,
		}, script)
		if refusal ~= nil then
			return refusal, nil
		end

		local preSource = script.Source
		local newSourceStr = newSource :: string

		-- No-op when source hasn't changed: didMutate=false so the
		-- dispatcher cancels CHS and discards the (un-staged) log entry.
		if preSource == newSourceStr then
			return {
				success = true,
				instancePath = instancePath,
				message = "Source unchanged; no edit applied",
				charactersBefore = #preSource,
				charactersAfter = #newSourceStr,
			}, {
				name = "Set Script Source",
				didMutate = false,
			}
		end

		local okWrite, writeErr = pcall(function()
			script.Source = newSourceStr
		end)
		if not okWrite then
			return {
				error = "Failed to set source: " .. tostring(writeErr),
				instancePath = instancePath,
			},
				nil
		end

		ctx.actionLog:stage(
			"set_script_source",
			instancePath :: string,
			string.format("Replaced %d chars with %d chars in %s", #preSource, #newSourceStr, instancePath :: string),
			{
				scriptEdits = {
					{
						instancePath = instancePath :: string,
						preSource = preSource,
						postSource = newSourceStr,
					},
				},
			}
		)

		return {
			success = true,
			instancePath = instancePath,
			charactersBefore = #preSource,
			charactersAfter = #newSourceStr,
			message = "Source replaced",
		}, {
			name = "Set Script Source",
			didMutate = true,
			isSourceEditOnly = true,
			scriptEdits = {
				{
					instancePath = instancePath :: string,
					preSource = preSource,
					postSource = newSourceStr,
				},
			},
		}
	end
)

-- editScript: line-range surgery (replace/insert/delete) on ONE script.
-- Legacy L3904-4049.
ScriptHandlers.editScript = Handler.define(
	"/api/edit-script",
	function(ctx, data: EditScriptRequest): (any, Handler.RecordResult?)
		local instancePath = data.instancePath
		local operation = data.operation
		local startLine = data.startLine
		local endLine = data.endLine
		local newContent = data.newContent

		if operation == nil then
			return { error = "operation is required (replace_lines | insert_lines | delete_lines)" }, nil
		end
		if operation ~= "replace_lines" and operation ~= "insert_lines" and operation ~= "delete_lines" then
			return {
				error = "operation must be one of: replace_lines, insert_lines, delete_lines",
			}, nil
		end

		local instance, err = resolveScript(instancePath)
		if err ~= nil then
			return err, nil
		end
		local script = instance :: LuaSourceContainer

		local refusal = Companions.refuseIfProtected({
			services = ctx.services,
			constants = ctx.constants,
		}, script)
		if refusal ~= nil then
			return refusal, nil
		end

		local preSource = script.Source
		local lines, hadTrailingNewline = Lines.split(preSource)
		local totalLines = #lines

		-- Per-operation argument validation + slice/insert logic.
		if operation == "replace_lines" then
			if startLine == nil or endLine == nil or newContent == nil then
				return { error = "replace_lines requires startLine, endLine, and newContent" }, nil
			end
			local s = math.max(1, startLine :: number)
			local e = math.min(totalLines, endLine :: number)
			if s > e then
				return { error = string.format("Invalid line range: startLine=%d > endLine=%d", s, e) }, nil
			end
			local newLines: { string } = {}
			-- Keep lines BEFORE the slice.
			for i = 1, s - 1 do
				table.insert(newLines, lines[i])
			end
			-- Insert the replacement lines.
			for _, nl in Lines.split(newContent :: string) do
				table.insert(newLines, nl)
			end
			-- Keep lines AFTER the slice.
			for i = e + 1, totalLines do
				table.insert(newLines, lines[i])
			end
			lines = newLines
		elseif operation == "insert_lines" then
			if startLine == nil or newContent == nil then
				return { error = "insert_lines requires startLine and newContent" }, nil
			end
			local s = math.max(1, startLine :: number)
			s = math.min(s, totalLines + 1)
			local newLines: { string } = {}
			for i = 1, s - 1 do
				table.insert(newLines, lines[i])
			end
			for _, nl in Lines.split(newContent :: string) do
				table.insert(newLines, nl)
			end
			for i = s, totalLines do
				table.insert(newLines, lines[i])
			end
			lines = newLines
		else -- delete_lines
			if startLine == nil or endLine == nil then
				return { error = "delete_lines requires startLine and endLine" }, nil
			end
			local s = math.max(1, startLine :: number)
			local e = math.min(totalLines, endLine :: number)
			if s > e then
				return { error = string.format("Invalid line range: startLine=%d > endLine=%d", s, e) }, nil
			end
			local newLines: { string } = {}
			for i = 1, s - 1 do
				table.insert(newLines, lines[i])
			end
			for i = e + 1, totalLines do
				table.insert(newLines, lines[i])
			end
			lines = newLines
			-- An empty file still has one (empty) row — preserve Lines.split contract.
			if #lines == 0 then
				table.insert(lines, "")
			end
		end

		local postSource = Lines.join(lines, hadTrailingNewline)

		if preSource == postSource then
			return {
				success = true,
				instancePath = instancePath,
				message = "Source unchanged after edit; no-op",
				operation = operation,
			}, {
				name = "Edit Script: " .. (operation :: string),
				didMutate = false,
			}
		end

		local okWrite, writeErr = pcall(function()
			script.Source = postSource
		end)
		if not okWrite then
			return {
				error = "Failed to set source: " .. tostring(writeErr),
				instancePath = instancePath,
			},
				nil
		end

		ctx.actionLog:stage(
			"edit_script",
			instancePath :: string,
			string.format(
				"%s on %s (lines %s-%s)",
				operation :: string,
				instancePath :: string,
				tostring(startLine),
				tostring(endLine)
			),
			{
				operation = operation,
				startLine = startLine,
				endLine = endLine,
				scriptEdits = {
					{
						instancePath = instancePath :: string,
						preSource = preSource,
						postSource = postSource,
					},
				},
			}
		)

		return {
			success = true,
			instancePath = instancePath,
			operation = operation,
			startLine = startLine,
			endLine = endLine,
			linesBefore = totalLines,
			linesAfter = #lines,
		}, {
			name = "Edit Script: " .. (operation :: string),
			didMutate = true,
			isSourceEditOnly = true,
			scriptEdits = {
				{
					instancePath = instancePath :: string,
					preSource = preSource,
					postSource = postSource,
				},
			},
		}
	end
)

-- findAndReplaceInScripts: text/regex replace across many scripts.
-- Legacy L4462-4606. Returns isSourceEditOnly + scriptEdits per script
-- actually changed, so undo restores all of them in one Ctrl+Z.
-- dryRun = true returns the same shape but skips the .Source assignment.
ScriptHandlers.findAndReplaceInScripts = Handler.define(
	"/api/find-and-replace-in-scripts",
	function(ctx, data: FindAndReplaceInScriptsRequest): (any, Handler.RecordResult?)
		local rootPath = data.path or "game"
		local findText = data.findText
		local replaceText = data.replaceText
		local useRegex = data.useRegex == true
		local caseInsensitive = data.caseInsensitive == true
		local dryRun = data.dryRun == true
		local scriptPathsFilter = data.scriptPaths

		if findText == nil or replaceText == nil then
			return { error = "findText and replaceText are required" }, nil
		end

		-- Resolve the set of candidate scripts. Two modes:
		--   1. scriptPaths array provided — operate only on those.
		--   2. otherwise — walk descendants of `path`.
		local candidates: { LuaSourceContainer } = {}

		if scriptPathsFilter ~= nil and #(scriptPathsFilter :: { string }) > 0 then
			for _, p in scriptPathsFilter :: { string } do
				local inst = Path.getInstanceByPath(p)
				if inst ~= nil and inst:IsA("LuaSourceContainer") then
					table.insert(candidates, inst :: LuaSourceContainer)
				end
			end
		else
			local rootInstance: Instance?
			if rootPath == "game" or rootPath == "" then
				rootInstance = game
			else
				rootInstance = Path.getInstanceByPath(rootPath)
				if rootInstance == nil then
					return { error = "Path not found: " .. rootPath }, nil
				end
			end
			for _, inst in (rootInstance :: Instance):GetDescendants() do
				if inst:IsA("LuaSourceContainer") then
					table.insert(candidates, inst :: LuaSourceContainer)
				end
			end
		end

		local deps = { services = ctx.services, constants = ctx.constants }

		-- caseInsensitive fold helper. We can't use a Lua-pattern flag for
		-- this, so we lowercase both haystack and needle when set.
		local needle = findText :: string
		if caseInsensitive and not useRegex then
			needle = string.lower(needle)
		end

		local fileChanges: { any } = {}
		local scriptEdits: { Handler.ScriptEdit } = {}
		local totalReplacements = 0

		for _, script in candidates do
			local scriptPath = Path.getInstancePath(script)

			-- LLM-stomp: skip companions (don't error — find/replace is
			-- typically a bulk op and one refusal shouldn't blow up the
			-- whole batch; reported in fileChanges).
			local protection = Companions.isProtected(deps, script)
			if protection.protected then
				table.insert(fileChanges, {
					path = scriptPath,
					skipped = true,
					reason = protection.reason,
				})
				continue
			end

			local okRead, source = pcall(function()
				return script.Source
			end)
			if not okRead or source == nil then
				table.insert(fileChanges, { path = scriptPath, error = "Failed to read source" })
				continue
			end

			local original = source :: string
			local replaced: string
			local count: number

			if useRegex then
				-- Lua-pattern replace. case-insensitive is NOT supported in
				-- regex mode (Lua patterns have no inline (?i) flag).
				replaced, count = string.gsub(original, findText :: string, replaceText :: string)
			else
				-- Plain-text replace (NO Lua-pattern interpretation). We
				-- can't use string.gsub here because gsub always treats
				-- its pattern as a Lua pattern — `.` and `(` would be
				-- magic. Roll our own with string.find(..., plain=true).
				-- This also gives us the natural place to fold case if
				-- caseInsensitive is set.
				local haystack = if caseInsensitive then string.lower(original) else original
				local out = ""
				local idx = 1
				local replacements = 0
				while true do
					local s, e = string.find(haystack, needle, idx, true)
					if s == nil then
						out ..= string.sub(original, idx)
						break
					end
					out ..= string.sub(original, idx, (s :: number) - 1)
					out ..= replaceText :: string
					idx = (e :: number) + 1
					replacements += 1
				end
				replaced = out
				count = replacements
			end

			if count == 0 then
				continue
			end

			totalReplacements += count
			table.insert(fileChanges, {
				path = scriptPath,
				replacements = count,
				charactersBefore = #original,
				charactersAfter = #replaced,
			})

			if not dryRun then
				local okWrite, writeErr = pcall(function()
					script.Source = replaced
				end)
				if not okWrite then
					fileChanges[#fileChanges].error = tostring(writeErr)
					continue
				end
				table.insert(scriptEdits, {
					instancePath = scriptPath,
					preSource = original,
					postSource = replaced,
				})
			end
		end

		local didChangeAnything = (#scriptEdits > 0)

		if not dryRun and didChangeAnything then
			ctx.actionLog:stage(
				"find_and_replace_in_scripts",
				rootPath,
				string.format(
					"Replaced %d occurrence%s across %d script%s",
					totalReplacements,
					(if totalReplacements == 1 then "" else "s"),
					#scriptEdits,
					(if #scriptEdits == 1 then "" else "s")
				),
				{
					findText = findText,
					replaceText = replaceText,
					useRegex = useRegex,
					caseInsensitive = caseInsensitive,
					scriptEdits = scriptEdits,
				}
			)
		end

		local response = {
			success = true,
			dryRun = dryRun,
			findText = findText,
			replaceText = replaceText,
			path = rootPath,
			filesChanged = fileChanges,
			totalReplacements = totalReplacements,
			scriptsAffected = #scriptEdits,
		}

		if dryRun then
			-- Dry-run: never mutate; no record result needed.
			return response, { name = "Find & Replace (dry-run)", didMutate = false }
		end

		if not didChangeAnything then
			return response, { name = "Find & Replace", didMutate = false }
		end

		return response,
			{
				name = string.format(
					"Find & Replace: %d replacement%s",
					totalReplacements,
					(if totalReplacements == 1 then "" else "s")
				),
				didMutate = true,
				isSourceEditOnly = true,
				scriptEdits = scriptEdits,
			}
	end
)

-- validateScript: probe-only Lua syntax check. READ-ONLY. Legacy L5156-5280.
-- Accepts EITHER an instancePath (reads .Source) OR a raw `source` string,
-- so callers can validate before set_script_source.
ScriptHandlers.validateScript = Handler.define(
	"/api/validate-script",
	function(_ctx, data: ValidateScriptRequest): (any, Handler.RecordResult?)
		local instancePath = data.instancePath
		local source = data.source

		local sourceToValidate: string
		if source ~= nil then
			sourceToValidate = source :: string
		elseif instancePath ~= nil then
			local instance, err = resolveScript(instancePath)
			if err ~= nil then
				return err, nil
			end
			sourceToValidate = (instance :: LuaSourceContainer).Source
		else
			return { error = "Either instancePath or source is required" }, nil
		end

		local result = Validator.validate(sourceToValidate)
		return {
			valid = result.valid,
			errors = result.errors,
			sourceLength = #sourceToValidate,
			instancePath = instancePath,
		},
			nil
	end
)

return ScriptHandlers
