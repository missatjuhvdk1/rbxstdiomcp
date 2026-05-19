--!strict
-- tools/golden/check.lune.luau
--
-- The §16 CI gate, executable. Run with:
--   lune run tools/golden/check.lune.luau
--
-- This is the mechanical enforcement of MCPPlugin/ARCHITECTURE.md's §4 layer
-- invariants and §15 forbidden-pattern catalogue. It is intentionally simple
-- and grep-based — the goal is *no false negatives*, not perfect parsing.
-- Reviewers still read code; this script catches the things humans miss.
--
-- Exits 0 if all gates are green, 1 otherwise. Each failure is printed with
-- file + line so it can be jumped to from any editor.
--
-- Phase 1 baseline: this script is INITIALLY GREEN. As the codebase grows
-- (Phases 2–6) the same script keeps the invariants enforced — that is the
-- whole point of writing it now, before there is much code to police.

local fs = require("@lune/fs")
local process = require("@lune/process")
local stdio = require("@lune/stdio")

-- ---------------------------------------------------------------------------
-- Configuration: what we check.
-- ---------------------------------------------------------------------------

local SRC_DIR = "src"
local FILE_SIZE_CAP = 7022 -- legacy plugin.luau line count, the sanity guard

-- §15 A2/A7: globals + reflection + loadstring banned in our code.
-- ExecuteLuaHandler is the one principled exception (documented in
-- ARCHITECTURE §4 invariant 2). Add other whitelisted files here ONLY with a
-- written justification in this comment block.
local FORBIDDEN_TOKENS = {
	"_G",
	"shared",
	"getfenv",
	"setfenv",
	"loadstring",
}
-- Whitelisted files may use the otherwise-forbidden tokens above. EACH entry
-- must have a written justification in this comment block:
--
--   src/domain/handlers/ExecuteLuaHandler.luau
--     The user-requested arbitrary-Lua execution endpoint. loadstring IS
--     its product; refusing it would defeat the feature. Architectural
--     containment: every other file is checked.
--
--   src/runtime/script/Validator.luau
--     Lua syntax validation needs to invoke the real Roblox parser, which
--     loadstring is the only public surface for. The validator NEVER calls
--     the returned function — it just inspects whether one was produced.
--     The alternative (a from-scratch Luau parser) would be 10000+ lines
--     that drift from Studio's actual parser version.
local FORBIDDEN_TOKEN_WHITELIST = {
	["src/domain/handlers/ExecuteLuaHandler.luau"] = true,
	["src/runtime/script/Validator.luau"] = true,
}

-- §16 service quarantine.
local SERVICE_QUARANTINE_FILE = "src/runtime/Services.luau"

-- §16 UI quarantine — these GUI Instance classes are UI-layer-only.
local GUI_CLASSES = {
	"Frame",
	"TextLabel",
	"TextButton",
	"TextBox",
	"ScrollingFrame",
	"ScreenGui",
	"UICorner",
	"UIPadding",
	"UIGradient",
	"UIListLayout",
	"UIStroke",
	"UIAspectRatioConstraint",
	"ImageLabel",
	"ImageButton",
}

-- §15 A6: decompiler banner regex.
local DECOMPILER_BANNERS = {
	"AI use of source code prohibited",
}

-- §4 layer invariant: parent-folder name → folders it must NOT require.
local FORBIDDEN_UPWARD_REQUIRES: { [string]: { string } } = {
	runtime = { "domain", "ui", "app" },
	domain = { "ui", "app" },
	ui = { "app" },
}

-- ---------------------------------------------------------------------------
-- Output helpers.
-- ---------------------------------------------------------------------------

type Failure = {
	file: string,
	line: number?,
	gate: string,
	message: string,
}

local failures: { Failure } = {}

local function fail(gate: string, file: string, line: number?, message: string)
	table.insert(failures, {
		file = file,
		line = line,
		gate = gate,
		message = message,
	})
end

-- ---------------------------------------------------------------------------
-- Filesystem helpers.
-- ---------------------------------------------------------------------------

local function listLuauFiles(dir: string): { string }
	local out: { string } = {}
	local function walk(path: string)
		if not fs.isDir(path) then
			return
		end
		for _, entry in fs.readDir(path) do
			local full = path .. "/" .. entry
			if fs.isDir(full) then
				walk(full)
			elseif fs.isFile(full) and full:sub(-5) == ".luau" then
				table.insert(out, full)
			end
		end
	end
	walk(dir)
	table.sort(out)
	return out
end

local function readLines(path: string): { string }
	local content = fs.readFile(path)
	local lines: { string } = {}
	-- Preserve every line including empty ones for accurate line numbers.
	for line in (content .. "\n"):gmatch("([^\n]*)\n") do
		table.insert(lines, line)
	end
	-- Trailing empty line from the appended \n: drop only if the file
	-- didn't already end with a newline of its own.
	if #content > 0 and content:sub(-1) ~= "\n" then
		-- The last line is real content with no trailing newline; keep it.
	else
		-- File ended with a newline; the loop produced an extra empty.
		if #lines > 0 and lines[#lines] == "" then
			table.remove(lines, #lines)
		end
	end
	return lines
end

-- ---------------------------------------------------------------------------
-- Per-file gate checks.
-- ---------------------------------------------------------------------------

local function checkStrict(file: string, lines: { string })
	-- §13: --!strict on line 1 of every .luau file.
	if #lines == 0 or not lines[1]:match("^%-%-!strict%s*$") then
		fail("Strict", file, 1, "first line must be `--!strict` (got: " .. (lines[1] or "<empty>") .. ")")
	end
end

local function checkForbiddenTokens(file: string, lines: { string })
	if FORBIDDEN_TOKEN_WHITELIST[file] then
		return
	end
	for i, line in lines do
		-- Strip line comments before matching so a token appearing inside a
		-- WHY-comment doesn't trip the gate.
		local code = line:gsub("%-%-.*$", "")
		for _, token in FORBIDDEN_TOKENS do
			-- Match as a word boundary so `shared` doesn't match e.g. `sharedAssets`.
			local pattern = "[^%w_]" .. token .. "[^%w_]"
			local padded = " " .. code .. " "
			if padded:find(pattern) then
				fail("NoGlobals", file, i, "forbidden token `" .. token .. "` (ARCHITECTURE §15 A1/A2/A7)")
			end
		end
	end
end

local function checkServiceQuarantine(file: string, lines: { string })
	if file == SERVICE_QUARANTINE_FILE then
		return
	end
	for i, line in lines do
		local code = line:gsub("%-%-.*$", "")
		if code:find("game:GetService%(") then
			fail(
				"ServiceQuarantine",
				file,
				i,
				"`game:GetService(` may only appear in " .. SERVICE_QUARANTINE_FILE .. " (ARCHITECTURE §4.3)"
			)
		end
	end
end

local function isUiOrAppFile(file: string): boolean
	return file:find("^src/ui/") ~= nil or file:find("^src/app/") ~= nil
end

local function checkUiQuarantine(file: string, lines: { string })
	if isUiOrAppFile(file) then
		return
	end
	for i, line in lines do
		local code = line:gsub("%-%-.*$", "")
		for _, class in GUI_CLASSES do
			-- Match Instance.new("ClassName") with double or single quotes.
			local pat = 'Instance%.new%(["\']' .. class .. '["\']'
			if code:find(pat) then
				fail(
					"UiQuarantine",
					file,
					i,
					"`Instance.new(\"" .. class .. "\")` may only appear under src/ui/ or src/app/ (ARCHITECTURE §4.4)"
				)
			end
		end
		if code:find("React%.createElement") or code:find("ReactRoblox%.createRoot") then
			fail(
				"UiQuarantine",
				file,
				i,
				"React rendering may only appear under src/ui/ or src/app/ (ARCHITECTURE §4.4)"
			)
		end
	end
end

local function checkRenderStepPairing(file: string, lines: { string })
	-- §15 A4 / §16 render-step safety: every BindToRenderStep in a module
	-- must have a matching UnbindFromRenderStep in the same module.
	local binds = 0
	local unbinds = 0
	local firstBindLine: number? = nil
	for i, line in lines do
		local code = line:gsub("%-%-.*$", "")
		if code:find("BindToRenderStep%(") then
			binds += 1
			if not firstBindLine then
				firstBindLine = i
			end
		end
		if code:find("UnbindFromRenderStep%(") then
			unbinds += 1
		end
	end
	if binds > unbinds then
		fail(
			"RenderStepSafety",
			file,
			firstBindLine,
			string.format(
				"%d `BindToRenderStep(` call(s) but only %d `UnbindFromRenderStep(` — must be paired in the same module (ARCHITECTURE §15 A4)",
				binds,
				unbinds
			)
		)
	end
end

local function checkDecompilerBanner(file: string, lines: { string })
	for i, line in lines do
		for _, banner in DECOMPILER_BANNERS do
			if line:find(banner, 1, true) then
				fail("NoDecompilerBanner", file, i, "decompiler banner found (ARCHITECTURE §15 A6)")
			end
		end
	end
end

local function checkLayerInvariant(file: string, lines: { string })
	-- Determine which layer this file lives in.
	local layer: string? = file:match("^src/(%w+)/")
	if not layer then
		return
	end
	local banned = FORBIDDEN_UPWARD_REQUIRES[layer]
	if not banned then
		return
	end
	for i, line in lines do
		local code = line:gsub("%-%-.*$", "")
		-- Detect requires that traverse up out of this layer.
		-- We're conservative: match either the
		--   require(script.Parent.Parent.<layer>...)
		-- or any literal "src/<layer>/" string path appearing in a require.
		for _, badLayer in banned do
			-- Match `.<badLayer>.` or `.<badLayer>)` in a require chain.
			local req = code:match("require%([^%)]*%)")
			if req then
				if req:find("[%.%[\"']" .. badLayer .. "[%.%[\"'%)]") then
					fail(
						"LayerInvariant",
						file,
						i,
						"`" .. layer .. "/` may not require `" .. badLayer .. "/` (ARCHITECTURE §4)"
					)
				end
			end
		end
	end
end

local function checkFileSizeCap(file: string, lines: { string })
	if #lines > FILE_SIZE_CAP then
		fail(
			"FileSize",
			file,
			nil,
			string.format(
				"%d lines exceeds the %d-line sanity cap (the legacy plugin.luau length) — split this module (ARCHITECTURE §4 invariant 5)",
				#lines,
				FILE_SIZE_CAP
			)
		)
	end
end

-- ---------------------------------------------------------------------------
-- External-tool gates (stylua + selene), invoked if those binaries exist on
-- $PATH. We do NOT hard-fail if a developer hasn't aftman-installed yet;
-- CI will. Print a clear note instead.
-- ---------------------------------------------------------------------------

-- Lune 0.10's process API: `process.exec(program, args, options)` returns
-- a result table `{ ok, code, stdout, stderr }`. It throws if the binary
-- itself cannot be located (ENOENT), which we catch via pcall.
type ExecResult = {
	ok: boolean,
	code: number,
	stdout: string,
	stderr: string,
}

local function tryRun(program: string, args: { string }): (boolean, string, boolean)
	-- Returns (success, output, wasFound). wasFound=false means the binary
	-- is not on $PATH — we treat that as a soft skip, not a gate failure.
	local ok, result = pcall(function(): ExecResult
		return (process :: any).exec(program, args, { cwd = "." })
	end)
	if not ok then
		local err = tostring(result)
		local missing = err:find("not found", 1, true) ~= nil
			or err:find("ENOENT", 1, true) ~= nil
			or err:find("No such file", 1, true) ~= nil
			or err:find("os error 2", 1, true) ~= nil
		return false, err, not missing
	end
	if not result.ok then
		return false, result.stdout .. result.stderr, true
	end
	return true, result.stdout, true
end

local function runExternalGates()
	local gates = {
		{ name = "Format", program = "stylua", args = { "--check", SRC_DIR } },
		{ name = "Lint", program = "selene", args = { SRC_DIR } },
	}
	for _, gate in gates do
		local ok, out, wasFound = tryRun(gate.program, gate.args)
		if ok then
			stdio.write(string.format("  · %s green\n", gate.program))
		elseif not wasFound then
			stdio.write(
				string.format("  · %s not on PATH — skipping (install via `aftman install`)\n", gate.program)
			)
		else
			fail(gate.name, "<" .. gate.program .. ">", nil, gate.program .. " failed:\n" .. out)
		end
	end
end

-- ---------------------------------------------------------------------------
-- Main.
-- ---------------------------------------------------------------------------

local function main()
	stdio.write("MCPPlugin golden-rules CI gate (ARCHITECTURE §16)\n")
	stdio.write("=================================================\n")

	if not fs.isDir(SRC_DIR) then
		fail("Setup", SRC_DIR, nil, "src/ directory not found — run from MCPPlugin/")
		return
	end

	local files = listLuauFiles(SRC_DIR)
	stdio.write(string.format("Scanning %d .luau file(s) under %s/\n\n", #files, SRC_DIR))

	for _, file in files do
		local lines = readLines(file)
		checkStrict(file, lines)
		checkForbiddenTokens(file, lines)
		checkServiceQuarantine(file, lines)
		checkUiQuarantine(file, lines)
		checkRenderStepPairing(file, lines)
		checkDecompilerBanner(file, lines)
		checkLayerInvariant(file, lines)
		checkFileSizeCap(file, lines)
	end

	stdio.write("Running external gates (stylua, selene)...\n")
	runExternalGates()
end

main()

if #failures == 0 then
	stdio.write("\n\27[32m✓ all gates green\27[0m\n")
	process.exit(0)
else
	stdio.write(string.format("\n\27[31m✗ %d failure(s):\27[0m\n", #failures))
	for _, f in failures do
		local loc = f.file
		if f.line then
			loc = loc .. ":" .. tostring(f.line)
		end
		stdio.write(string.format("  [%s] %s — %s\n", f.gate, loc, f.message))
	end
	process.exit(1)
end
