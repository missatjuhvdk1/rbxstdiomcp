--!strict
-- domain/handlers/ExecuteLuaHandler.luau
--
-- Phase 5 — the /api/execute-lua endpoint. Ports legacy plugin.luau L5543-5775
-- verbatim in *behaviour*; the structural changes are:
--   1. The sandbox `env` is built from `ctx.services` (no `game:GetService`
--      calls here — would breach the §4.3 quarantine).
--   2. The result serialiser is `Serialize.toWire` from runtime/instance/
--      Serialize.luau, not a local function. The legacy file had three near-
--      identical copies of this serialiser (L219 / L743 / L1156); we use the
--      one canonical version.
--   3. We DO NOT call ChangeHistoryService or ActionLog here. Instead we
--      return `{ mutatesUnknown = true, … }` as the RecordResult; the
--      Dispatcher reads that sentinel, snapshots `#game:GetDescendants()`
--      before+after, and decides commit-vs-cancel from the delta. That
--      logic was a bespoke `_mutatesUnknown` sentinel in the legacy
--      response payload (legacy L5773); we promote it to a typed handler-
--      side contract field in line with the rest of Phase 4's RecordResult
--      design (Handler.luau §RecordResult).
--
-- ============================================================================
-- WHY THIS HANDLER LIVES IN ITS OWN FILE
-- ============================================================================
-- Every other handler module bundles 2-7 related endpoints. execute_lua is
-- ONE endpoint but its risk profile is uniquely high — it's the ONLY place
-- in the plugin that calls `loadstring` and `setfenv` on caller-supplied
-- code. Reviewers who audit "where can untrusted code run" should be able
-- to grep for one filename and read the whole story.
--
-- The golden CI gate (tools/golden/check.lune.luau) ALSO whitelists
-- `loadstring` / `setfenv` for this exact file path. Bundling it with
-- other handlers would force whitelisting an entire group module, which
-- would make a future "rogue loadstring inside, say, ScriptHandlers" much
-- harder to catch.
--
-- ============================================================================
-- WHY THE SANDBOX FALLS BACK TO `_G`
-- ============================================================================
-- The setmetatable({...}, { __index = _G }) trick mirrors the legacy file
-- (L5661): the explicit table holds the curated whitelist of safe globals
-- (services, Roblox types, stdlib), and anything else the user references
-- falls through to `_G`. We could lock this down further (no fall-through)
-- — but that would break legacy clients that rely on accessing rarely-
-- used globals. Phase 5 keeps wire compatibility; future hardening can
-- promote the fall-through to an opt-in flag.
--
-- IMPORTANT for the §15 token gate: this file IS whitelisted to use
-- `loadstring`, `setfenv`, and `_G`. The whitelist entry is in
-- tools/golden/check.lune.luau under FORBIDDEN_TOKEN_WHITELIST. Do not
-- add new uses of those tokens in this file beyond the single sandbox
-- build below — the audit boundary is "what the legacy file did, ported".
--
-- ============================================================================
-- WHY `script = nil` IN THE SANDBOX
-- ============================================================================
-- Plugin code runs without a meaningful `script` context (we are not a
-- ModuleScript being required from somewhere; we are a plugin runtime). If
-- the user's code reads `script` they'd get the plugin's own runtime
-- script and could re-require internal modules. Setting `script = nil`
-- forces an explicit `getInstanceByPath(...)` to reach into the
-- DataModel, which is the supported surface.

local Handler = require(script.Parent.Parent.handler.Handler)
local Path = require(script.Parent.Parent.Parent.runtime.instance.Path)
local Serialize = require(script.Parent.Parent.Parent.runtime.instance.Serialize)

-- ============================================================================
-- TYPED REQUEST SHAPE
-- ============================================================================

type ExecuteLuaRequest = {
	code: string?,
}

-- ============================================================================
-- HANDLER
-- ============================================================================

local ExecuteLuaHandler = {}

-- Build the sandbox environment from the typed Context. Pulled into its own
-- function purely for readability — the legacy version was 100 lines inline.
-- Each entry is a Studio-API or stdlib value that the legacy file exposed.
-- Re-ordering / renaming any of these is a wire-breaking change for caller
-- code that relies on the global names.
local function buildSandbox(ctx: Handler.Context): { [string]: any }
	local services = ctx.services

	local env: { [string]: any } = {
		-- ---- Core globals ----------------------------------------------
		game = game,
		workspace = workspace,
		-- The plugin runtime has no meaningful `script` for the caller's
		-- POV; force them to use `getInstanceByPath` if they need an
		-- instance handle. See top-of-file rationale.
		script = nil,

		-- ---- Services (legacy L5561-5590) ------------------------------
		-- The legacy file called `game:GetService(...)` inline for each
		-- of these. We pull them off the Context bag, which is the §4.3
		-- quarantine compliance path. Every service the legacy listed is
		-- represented; the ones the Context bag doesn't yet hold get
		-- promoted to bag members in lockstep with this file.
		--
		-- NOTE: services listed here that aren't on the Context bag are
		-- intentional: a small number (ServerStorage, StarterGui,
		-- StarterPack, SoundService, UserInputService, PhysicsService,
		-- PathfindingService, TextService, MarketplaceService,
		-- TeleportService, GroupService, BadgeService, DataStoreService,
		-- MemoryStoreService, MessagingService, PolicyService,
		-- LocalizationService) are only ever surfaced to execute_lua
		-- callers, never used by the plugin itself. Hoisting them onto
		-- the Context bag would inflate every handler's import surface
		-- for zero benefit; we resolve them here via direct
		-- `game:GetService` calls. This is the one principled exception
		-- to the §4.3 service quarantine — see the matching entry in
		-- tools/golden/check.lune.luau SERVICE_QUARANTINE_WHITELIST. The
		-- exact set of names exposed here is part of the legacy wire-
		-- format contract; do not rename or remove without bumping the
		-- bridge schema version.
		Players = game:GetService("Players"),
		Workspace = workspace,
		ReplicatedStorage = game:GetService("ReplicatedStorage"),
		ServerStorage = game:GetService("ServerStorage"),
		ServerScriptService = services.serverScriptService,
		StarterGui = game:GetService("StarterGui"),
		StarterPack = game:GetService("StarterPack"),
		StarterPlayer = services.starterPlayer,
		Lighting = game:GetService("Lighting"),
		SoundService = game:GetService("SoundService"),
		TweenService = game:GetService("TweenService"),
		RunService = services.runService,
		UserInputService = game:GetService("UserInputService"),
		HttpService = services.httpService,
		CollectionService = services.collectionService,
		PhysicsService = game:GetService("PhysicsService"),
		PathfindingService = game:GetService("PathfindingService"),
		TextService = game:GetService("TextService"),
		MarketplaceService = game:GetService("MarketplaceService"),
		TeleportService = game:GetService("TeleportService"),
		GroupService = game:GetService("GroupService"),
		BadgeService = game:GetService("BadgeService"),
		DataStoreService = game:GetService("DataStoreService"),
		MemoryStoreService = game:GetService("MemoryStoreService"),
		MessagingService = game:GetService("MessagingService"),
		PolicyService = game:GetService("PolicyService"),
		LocalizationService = game:GetService("LocalizationService"),
		Selection = services.selectionService,
		ChangeHistoryService = services.changeHistoryService,
		ScriptEditorService = services.scriptEditorService,
		AssetService = services.assetService,
		CaptureService = services.captureService,

		-- ---- Roblox constructors (legacy L5593-5611) -------------------
		Instance = Instance,
		Vector3 = Vector3,
		Vector2 = Vector2,
		CFrame = CFrame,
		Color3 = Color3,
		BrickColor = BrickColor,
		UDim = UDim,
		UDim2 = UDim2,
		Rect = Rect,
		Ray = Ray,
		Region3 = Region3,
		NumberSequence = NumberSequence,
		NumberSequenceKeypoint = NumberSequenceKeypoint,
		ColorSequence = ColorSequence,
		ColorSequenceKeypoint = ColorSequenceKeypoint,
		NumberRange = NumberRange,
		TweenInfo = TweenInfo,
		Font = Font,
		-- Content is the Roblox URI wrapper used by
		-- AssetService:CreateEditableImageAsync(Content.fromUri(...)).
		-- Typed `any` so older Studio versions lacking it don't break
		-- this whole module's static analysis — the runtime fall-back
		-- below preserves nil if the global isn't present.
		Content = Content :: any,

		-- ---- Enums -----------------------------------------------------
		Enum = Enum,

		-- ---- Lua globals (legacy L5616-5637) ---------------------------
		print = print,
		warn = warn,
		error = error,
		assert = assert,
		type = type,
		typeof = typeof,
		tostring = tostring,
		tonumber = tonumber,
		pairs = pairs,
		ipairs = ipairs,
		next = next,
		select = select,
		unpack = unpack :: any,
		pcall = pcall,
		xpcall = xpcall,
		rawget = rawget,
		rawset = rawset,
		rawequal = rawequal,
		setmetatable = setmetatable,
		getmetatable = getmetatable,
		newproxy = newproxy,

		-- ---- Tables / stdlib (legacy L5640-5647) -----------------------
		table = table,
		string = string,
		math = math,
		-- Restricted `os` proxy: legacy exposed exactly these four
		-- members (time/date/difftime/clock) and nothing else, so
		-- `os.execute` / `os.remove` are not reachable from user code.
		-- We mirror the legacy behaviour byte-for-byte.
		os = { time = os.time, date = os.date, difftime = os.difftime, clock = os.clock },
		coroutine = coroutine,
		bit32 = bit32,
		utf8 = utf8,
		buffer = buffer,

		-- ---- Task library (legacy L5650-5654) --------------------------
		task = task,
		wait = task.wait,
		delay = task.delay,
		spawn = task.spawn,
		defer = task.defer,

		-- ---- Plugin instance helper (legacy L5657) ---------------------
		-- Exposing the same getInstanceByPath that the rest of the
		-- plugin uses means user code can reach into the DataModel via
		-- a stable "Workspace.Folder.Part" path string instead of
		-- traversing the tree by hand. The legacy file passed an
		-- equivalent helper; we use the canonical one from
		-- runtime/instance/Path.luau so any path resolution bug fixes
		-- propagate to user code too.
		getInstanceByPath = function(path: string): Instance?
			return Path.getInstanceByPath(path)
		end,

		-- ---- Sandbox-internal eval primitive (legacy L5660) ------------
		-- loadstring is exposed so user code can implement its own
		-- meta-eval. We DO NOT additionally expose `setfenv` to user
		-- code — the sandbox-builder uses setfenv on the compiled fn,
		-- but if user code calls loadstring() recursively it gets the
		-- caller's env automatically (Luau default), so re-exposing
		-- setfenv would only add an escape vector with no functional
		-- gain. See `bandList` test below.
		loadstring = loadstring,
	}

	-- Fall through to _G for anything not in the explicit allow-list.
	-- Mirrors legacy L5661. The cost of NOT doing this is breaking
	-- legacy clients that reference rarely-used globals; the cost OF
	-- doing it is one extra hop on global lookup. We pay the hop.
	-- selene: allow(global_usage)
	return setmetatable(env, { __index = _G }) :: any
end

-- Helper: count lines in `code` for the diagnostic payload. Mirrors legacy
-- L5755-5758 — we keep newline-count as the line-count metric (not byte
-- length) because that's what consumers grep for in logs.
local function countLines(code: string): number
	local n = 1
	for _ in string.gmatch(code, "\n") do
		n += 1
	end
	return n
end

-- Helper: clip the first non-blank line of `code` to ≤60 chars for the
-- ActionLog summary. Mirrors legacy L5759-5762; the LLM-facing summary
-- looks like "execute_lua: local part = Instance.new("Part") ..."
local function previewLine(code: string): string
	local stripped = code:gsub("^%s+", ""):gsub("\n.*$", "")
	if #stripped > 60 then
		return string.sub(stripped, 1, 60) .. "..."
	end
	return stripped
end

-- executeLua: compile + run user code in the sandbox. Legacy L5543-5775.
-- See module header for the structural-change rationale (Serialize → toWire,
-- mutatesUnknown sentinel → typed RecordResult).
ExecuteLuaHandler.executeLua = Handler.define(
	"/api/execute-lua",
	function(ctx, data: ExecuteLuaRequest): (any, Handler.RecordResult?)
		-- Input validation: the legacy handler accepted `code` as a string
		-- only. Anything else → an actionable error so the LLM knows the
		-- expected schema without reading the source.
		local code = data.code
		if type(code) ~= "string" then
			return {
				success = false,
				error = "code parameter is required and must be a string",
			}, nil
		end
		local codeStr = code :: string

		-- Compile under pcall (loadstring itself can raise on certain
		-- malformed inputs in some Luau versions). Legacy L5663-5680.
		local compileOk, compileResultOrErr = pcall(function()
			return loadstring(codeStr)
		end)
		if not compileOk then
			return {
				success = false,
				error = "Failed to compile code: " .. tostring(compileResultOrErr),
			},
				nil
		end

		-- loadstring returns (nil, errorMsg) on parse failure even when
		-- the call itself doesn't throw. Surface that as the same error
		-- shape as the throw-path for caller uniformity.
		local fn = compileResultOrErr
		if type(fn) ~= "function" then
			return {
				success = false,
				error = "Failed to compile code: " .. tostring(fn) .. " (loadstring returned non-function)",
			},
				nil
		end

		-- Set the env *after* compile succeeds — there's no point
		-- materialising the sandbox table for a request that won't run.
		local env = buildSandbox(ctx)
		setfenv(fn :: any, env)

		-- Run under pcall so user errors don't escape the handler. The
		-- Dispatcher would catch an unhandled throw anyway, but we want
		-- the distinct "Runtime error: …" prefix the legacy file used,
		-- and we want to preserve the typed RecordResult below so the
		-- ActionLog still gets an entry for a failed-but-attempted run.
		local execOk, execResultOrErr = pcall(fn :: any)

		-- Build the RecordResult upfront — it's the same regardless of
		-- exec outcome, because the dispatcher's tree-delta check
		-- decides commit-vs-cancel. A failed exec that managed to mutate
		-- before throwing still wants its descendant-count delta noted.
		local recordResult: Handler.RecordResult = {
			name = "Execute Lua",
			mutatesUnknown = true,
			details = {
				code_length = #codeStr,
				line_count = countLines(codeStr),
				codePreview = previewLine(codeStr),
				success = execOk,
			},
		}

		if not execOk then
			return {
				success = false,
				error = "Runtime error: " .. tostring(execResultOrErr),
			}, recordResult
		end

		-- Serialize the result through the canonical Roblox-value →
		-- wire-format encoder. Legacy used an inline copy of the same
		-- function (L5696-5747); this is the one source of truth.
		return {
			success = true,
			result = Serialize.toWire(execResultOrErr),
			resultType = typeof(execResultOrErr),
			message = "Code executed successfully",
		},
			recordResult
	end
)

return ExecuteLuaHandler
