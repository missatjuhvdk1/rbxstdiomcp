--!strict
-- runtime/testsession/ServerCompanion.luau
--
-- Phase 5 — server-side test-session companion source, as data.
--
-- ============================================================================
-- WHAT THIS MODULE IS (READ THIS BEFORE EDITING)
-- ============================================================================
-- This module DOES NOT execute companion code in the plugin runtime. It
-- returns the *literal source text* of the server-side test companion as a
-- string constant. `Companions.inject(...)` reads `.source`, plain-text
-- replaces the `__MCP_SERVER_URL__` / `__MCP_SESSION_ID__` placeholders,
-- then assigns the result to a freshly created `Script` instance which is
-- parented into ServerScriptService at play-test injection time. That
-- Script runs in the *test* DataModel (not the plugin's edit DataModel),
-- where it has its own services, its own LogService, its own RemoteEvents.
--
-- It MUST stay as a string-constant module:
--   1. The code below uses `loadstring`, `setfenv`, and `_G` — those are
--      banned in plugin-runtime code by §15. They are legal *here* only
--      because they're inside a long-string literal. The golden CI gate
--      whitelists this file with written justification.
--   2. The companion runs in a separate Roblox DataModel; even if we
--      authored it as a regular Luau module, the test-side DataModel
--      cannot `require` modules from the plugin DataModel.
--   3. Authoring as a long-string is the smallest, most legible way to
--      keep the legacy 600-line body intact while letting us version,
--      review, and diff it like normal code.
--
-- ============================================================================
-- PLACEHOLDERS
-- ============================================================================
-- The literal substrings `__MCP_SERVER_URL__` and `__MCP_SESSION_ID__` are
-- substituted at injection time. Picked specifically to never be valid
-- Lua tokens, so a syntax-aware tool can still read the body sensibly,
-- and so plain-text gsub is safe (no pattern characters).
--
-- ============================================================================
-- DELIMITER CHOICE
-- ============================================================================
-- We use `[==[ ... ]==]` (level-2 long-string) because the body contains
-- `]]` from table indexes and from inner `[[ ... ]]` strings. `[==[` keeps
-- the parser happy as long as the body never contains `]==]`, which we
-- verify by inspection (legacy text has no triple-equals brackets).
--
-- ============================================================================
-- WIRE-CONTRACT POINTERS (do not change without bumping the bridge schema)
-- ============================================================================
-- The companion POSTs JSON to these bridge endpoints:
--   POST /test-session/poll        { sessionId, target, hello? }
--                                    → returns { command?, ended? }
--   POST /test-session/log         { sessionId, source, messages[] }
--   POST /test-session/eval-result { sessionId, replyId, ok, values?, ... }
--   POST /test-session/ended       { sessionId, reason }
-- ReplicatedStorage Remotes (created here, mirrored in ClientCompanion):
--   _MCPClientHello : RemoteEvent     (client → server)
--   _MCPClientLogs  : RemoteEvent     (client → server)
--   _MCPClientRelay : RemoteFunction  (server → client, server invokes)

local ServerCompanion = {}

-- Substring tokens replaced at inject time. Exposed as module fields so the
-- injector and any test code reference the same literals — drift between
-- the placeholder in the body and the gsub target would silently leave
-- the test session unable to find the bridge.
ServerCompanion.SERVER_URL_PLACEHOLDER = "__MCP_SERVER_URL__"
ServerCompanion.SESSION_ID_PLACEHOLDER = "__MCP_SESSION_ID__"

ServerCompanion.source = [==[-- _MCPTestCompanion (auto-generated, safe to delete)
-- Runs in the Server DataModel of a Studio test session started by the MCP
-- plugin. Pipes output back to the local MCP bridge, listens for an "end"
-- command to terminate the test cleanly via StudioTestService:EndTest(), and
-- runs run_live_lua "eval" commands on the test's actual server.
--
-- DO NOT modify or delete while a play test is running — it will be cleaned
-- up automatically by the MCP plugin.

local HttpService = game:GetService("HttpService")
local LogService = game:GetService("LogService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StudioTestService
do
	local ok, svc = pcall(function() return game:GetService("StudioTestService") end)
	if ok then StudioTestService = svc end
end

local SERVER_URL = "__MCP_SERVER_URL__"
local SESSION_ID = "__MCP_SESSION_ID__"
local POLL_INTERVAL = 0.4
local LOG_FLUSH_INTERVAL = 0.25
local MAX_BUFFER = 5000
local MAX_CONSECUTIVE_FAILURES = 30 -- ~12s of failed polls before we give up

local outputBuffer = {}
local stopRequested = false
local consecutiveFailures = 0

-- Probe loadstring availability ONCE up front. Result goes into the hello
-- payload so the bridge can refuse run_live_lua with a clear error if the
-- user hasn't enabled ServerScriptService.LoadStringEnabled.
local LOADSTRING_READY = false
do
	local ok, fn = pcall(loadstring, "return 1")
	if ok and type(fn) == "function" then
		local execOk, execVal = pcall(fn)
		if execOk and execVal == 1 then
			LOADSTRING_READY = true
		end
	end
end

-- ---------------------------------------------------------------------------
-- CLIENT RELAY (server-side gateway)
-- ---------------------------------------------------------------------------
-- HttpService:RequestAsync is server-only in Roblox: LocalScripts can't make
-- HTTP requests. So the server companion is the only HTTP gateway, and the
-- client companion talks to us through these Remotes:
--
--   _MCPClientHello  RemoteEvent     client -> server, register/loadstring info
--   _MCPClientLogs   RemoteEvent     client -> server, batched LogService output
--   _MCPClientRelay  RemoteFunction  server -> client, dispatch run_live_lua eval
--
-- We keep these in ReplicatedStorage with Archivable=false so they don't get
-- saved into the place file, and they're cleaned up automatically when the
-- test session ends and the cloned DataModel is torn down.
-- ---------------------------------------------------------------------------
local clientRelay
local clientHello
local clientLogs
do
	local function makeRemote(className, name)
		local existing = ReplicatedStorage:FindFirstChild(name)
		if existing and existing.ClassName == className then
			return existing
		elseif existing then
			pcall(function() existing:Destroy() end)
		end
		local inst = Instance.new(className)
		inst.Name = name
		inst.Archivable = false
		inst.Parent = ReplicatedStorage
		return inst
	end
	clientRelay = makeRemote("RemoteFunction", "_MCPClientRelay")
	clientHello = makeRemote("RemoteEvent", "_MCPClientHello")
	clientLogs  = makeRemote("RemoteEvent", "_MCPClientLogs")
end

local function postJSON(path, body)
	local ok, response = pcall(function()
		return HttpService:RequestAsync({
			Url = SERVER_URL .. path,
			Method = "POST",
			Headers = { ["Content-Type"] = "application/json" },
			Body = HttpService:JSONEncode(body),
		})
	end)
	if ok and response and response.Success then
		consecutiveFailures = 0
		return true, response
	else
		consecutiveFailures += 1
		return false, nil
	end
end

-- ---------------------------------------------------------------------------
-- Client gateway: forward client-side Remote events into the bridge over HTTP.
-- Clients can't make HTTP requests themselves (HttpService is server-only), so
-- they fire RemoteEvents at us and we forward.
-- ---------------------------------------------------------------------------
clientHello.OnServerEvent:Connect(function(player, payload)
	-- payload = { loadstringReady = bool }
	-- Register the client with the bridge by issuing a single poll on its
	-- behalf with a hello field. The bridge populates its clients map from
	-- this poll, which is what run_live_lua's target='client' resolution
	-- looks at.
	local loadstringReady = false
	if type(payload) == "table" and payload.loadstringReady ~= nil then
		loadstringReady = payload.loadstringReady and true or false
	end
	task.spawn(function()
		postJSON("/test-session/poll", {
			sessionId = SESSION_ID,
			target = "client",
			userId = player.UserId,
			playerName = player.Name,
			hello = { loadstringReady = loadstringReady },
		})
	end)
end)

clientLogs.OnServerEvent:Connect(function(player, messages)
	-- messages: array of { message, messageType, timestamp }
	if type(messages) ~= "table" then return end
	-- Tag each message with the player's name so multi-client tests are
	-- legible in get_playtest_output.
	local tagged = {}
	for i, m in ipairs(messages) do
		if type(m) == "table" then
			tagged[i] = {
				message = "[" .. player.Name .. "] " .. tostring(m.message or ""),
				messageType = m.messageType or "MessageOutput",
				timestamp = m.timestamp or os.time(),
			}
		end
	end
	if #tagged == 0 then return end
	task.spawn(function()
		postJSON("/test-session/log", {
			sessionId = SESSION_ID,
			source = "client",
			messages = tagged,
		})
	end)
end)

-- ---------------------------------------------------------------------------
-- Result serializer (mirrors the plugin's executeLua serializer so MCP
-- clients see the same shapes whether they're running edit-mode execute_lua
-- or runtime run_live_lua). Depth + cycle guarded.
-- ---------------------------------------------------------------------------
local function serializeValue(value, depth, seen)
	depth = depth or 0
	seen = seen or {}
	if depth > 8 then return "<max depth>" end

	local t = typeof(value)
	if value == nil then
		return nil
	elseif t == "string" then
		-- Cap very long strings so a runaway print doesn't pollute the wire.
		if #value > 65536 then
			return string.sub(value, 1, 65536) .. "...<truncated>"
		end
		return value
	elseif t == "number" then
		-- JSON can't represent NaN/Infinity; coerce to string.
		if value ~= value then return "NaN" end
		if value == math.huge then return "Infinity" end
		if value == -math.huge then return "-Infinity" end
		return value
	elseif t == "boolean" then
		return value
	elseif t == "Vector3" then
		return { type = "Vector3", X = value.X, Y = value.Y, Z = value.Z }
	elseif t == "Vector2" then
		return { type = "Vector2", X = value.X, Y = value.Y }
	elseif t == "CFrame" then
		return { type = "CFrame", components = { value:GetComponents() } }
	elseif t == "Color3" then
		return { type = "Color3", R = value.R, G = value.G, B = value.B }
	elseif t == "BrickColor" then
		return { type = "BrickColor", Name = value.Name }
	elseif t == "UDim" then
		return { type = "UDim", Scale = value.Scale, Offset = value.Offset }
	elseif t == "UDim2" then
		return {
			type = "UDim2",
			X = { Scale = value.X.Scale, Offset = value.X.Offset },
			Y = { Scale = value.Y.Scale, Offset = value.Y.Offset },
		}
	elseif t == "Rect" then
		return { type = "Rect", Min = { X = value.Min.X, Y = value.Min.Y }, Max = { X = value.Max.X, Y = value.Max.Y } }
	elseif t == "Ray" then
		return {
			type = "Ray",
			Origin = { X = value.Origin.X, Y = value.Origin.Y, Z = value.Origin.Z },
			Direction = { X = value.Direction.X, Y = value.Direction.Y, Z = value.Direction.Z },
		}
	elseif t == "NumberRange" then
		return { type = "NumberRange", Min = value.Min, Max = value.Max }
	elseif t == "EnumItem" then
		return { type = "EnumItem", Name = tostring(value), Value = value.Value }
	elseif t == "Instance" then
		local fullName = "<unparented>"
		pcall(function() fullName = value:GetFullName() end)
		return { type = "Instance", ClassName = value.ClassName, Name = value.Name, Path = fullName }
	elseif t == "table" then
		if seen[value] then return "<cycle>" end
		seen[value] = true
		local result = {}
		local count = 0
		for k, v in pairs(value) do
			count += 1
			if count > 200 then
				result["__truncated__"] = true
				break
			end
			local keyStr = type(k) == "string" and k or tostring(k)
			result[keyStr] = serializeValue(v, depth + 1, seen)
		end
		seen[value] = nil
		return result
	elseif t == "function" then
		return "<function>"
	elseif t == "thread" then
		return "<thread>"
	elseif t == "buffer" then
		return "<buffer>"
	else
		-- Fallback: stringify whatever it is.
		local ok, str = pcall(tostring, value)
		return ok and str or ("<" .. t .. ">")
	end
end

LogService.MessageOut:Connect(function(message, messageType)
	if #outputBuffer >= MAX_BUFFER then
		-- Drop oldest to keep buffer bounded; we'd rather lose stale output
		-- than balloon memory in a long-running test.
		table.remove(outputBuffer, 1)
	end
	table.insert(outputBuffer, {
		message = tostring(message),
		messageType = messageType.Name,
		timestamp = os.time(),
	})
end)

-- Log flusher
task.spawn(function()
	while not stopRequested do
		if #outputBuffer > 0 then
			local toSend = outputBuffer
			outputBuffer = {}
			local ok = postJSON("/test-session/log", {
				sessionId = SESSION_ID,
				source = "server",
				messages = toSend,
			})
			if not ok then
				-- Re-queue (capped) so we don't lose log lines on a transient
				-- bridge hiccup. Newer entries take priority since they're
				-- usually what the AI wants to see.
				for i = 1, math.min(#toSend, MAX_BUFFER - #outputBuffer) do
					table.insert(outputBuffer, toSend[i])
				end
			end
		end
		task.wait(LOG_FLUSH_INTERVAL)
	end
end)

-- ---------------------------------------------------------------------------
-- Eval handler. Compiles user code via loadstring, runs under xpcall on its
-- own task thread, captures LogService output during the call window, and
-- POSTs the result back to /test-session/eval-result. A task.delay watchdog
-- forces a 'timeout' reply if the user code yields too long.
-- ---------------------------------------------------------------------------
local function buildEvalEnv()
	-- Mirror executeLua's sandbox so the same conveniences are available
	-- on the in-test side. We expose game/services so the AI can mutate
	-- live state, fire RemoteEvents, etc.
	return setmetatable({
		game = game,
		workspace = workspace,
		Players = Players,
		Workspace = workspace,
		ReplicatedStorage = ReplicatedStorage,
		ServerStorage = game:GetService("ServerStorage"),
		ServerScriptService = game:GetService("ServerScriptService"),
		StarterGui = game:GetService("StarterGui"),
		StarterPack = game:GetService("StarterPack"),
		StarterPlayer = game:GetService("StarterPlayer"),
		Lighting = game:GetService("Lighting"),
		SoundService = game:GetService("SoundService"),
		TweenService = game:GetService("TweenService"),
		RunService = game:GetService("RunService"),
		UserInputService = game:GetService("UserInputService"),
		HttpService = HttpService,
		CollectionService = game:GetService("CollectionService"),
		PhysicsService = game:GetService("PhysicsService"),
		PathfindingService = game:GetService("PathfindingService"),
		TextService = game:GetService("TextService"),
		MarketplaceService = game:GetService("MarketplaceService"),
		TeleportService = game:GetService("TeleportService"),
		DataStoreService = game:GetService("DataStoreService"),
		MemoryStoreService = game:GetService("MemoryStoreService"),
		MessagingService = game:GetService("MessagingService"),
		BadgeService = game:GetService("BadgeService"),
		Instance = Instance,
		Vector3 = Vector3, Vector2 = Vector2, CFrame = CFrame, Color3 = Color3,
		BrickColor = BrickColor, UDim = UDim, UDim2 = UDim2, Rect = Rect, Ray = Ray,
		Region3 = Region3, NumberSequence = NumberSequence,
		NumberSequenceKeypoint = NumberSequenceKeypoint, ColorSequence = ColorSequence,
		ColorSequenceKeypoint = ColorSequenceKeypoint, NumberRange = NumberRange,
		TweenInfo = TweenInfo, Font = Font, Enum = Enum,
		print = print, warn = warn, error = error, assert = assert,
		type = type, typeof = typeof, tostring = tostring, tonumber = tonumber,
		pairs = pairs, ipairs = ipairs, next = next, select = select, unpack = unpack,
		pcall = pcall, xpcall = xpcall,
		rawget = rawget, rawset = rawset, rawequal = rawequal,
		setmetatable = setmetatable, getmetatable = getmetatable, newproxy = newproxy,
		table = table, string = string, math = math,
		os = { time = os.time, date = os.date, difftime = os.difftime, clock = os.clock },
		coroutine = coroutine, bit32 = bit32, utf8 = utf8, buffer = buffer,
		task = task, wait = task.wait, delay = task.delay, spawn = task.spawn, defer = task.defer,
		loadstring = loadstring,
		require = require,
		debug = debug,
		tick = tick,
	}, { __index = _G })
end

local function postEvalResult(replyId, payload)
	payload.sessionId = SESSION_ID
	payload.replyId = replyId
	postJSON("/test-session/eval-result", payload)
end

local function handleEvalCommand(args)
	if not args or type(args.replyId) ~= "string" or type(args.code) ~= "string" then
		return -- malformed; bridge will time out, no point replying without replyId
	end
	local replyId = args.replyId
	local code = args.code
	local timeoutMs = type(args.timeoutMs) == "number" and args.timeoutMs or 5000
	local captureLogs = args.captureLogs ~= false -- default true

	-- Run the eval on its own task so this command poller can keep going
	-- (a slow eval shouldn't block log streaming or further commands).
	task.spawn(function()
		local startedAt = os.clock()
		local replied = false
		local function safeReply(payload)
			if replied then return end
			replied = true
			payload.durationMs = math.floor((os.clock() - startedAt) * 1000)
			postEvalResult(replyId, payload)
		end

		-- ----------------------------------------------------------------
		-- forwardTo path: run_live_lua with target='client' enqueues on the
		-- server queue with forwardTo metadata; we dispatch via InvokeClient
		-- through _MCPClientRelay. The client's OnClientInvoke handler does
		-- the actual eval and returns the payload.
		-- ----------------------------------------------------------------
		if type(args.forwardTo) == "table" then
			local targetUserId = args.forwardTo.userId
			local targetName = args.forwardTo.playerName
			local target = nil
			if type(targetUserId) == "number" then
				for _, p in ipairs(Players:GetPlayers()) do
					if p.UserId == targetUserId then target = p; break end
				end
			end
			if not target and type(targetName) == "string" and #targetName > 0 then
				target = Players:FindFirstChild(targetName)
			end
			if not target then
				safeReply({
					ok = false,
					errorType = "no_such_player",
					error = string.format(
						"Could not resolve target client (userId=%s, playerName=%s) — they may have left the test.",
						tostring(targetUserId), tostring(targetName)
					),
				})
				return
			end

			-- Server-side watchdog: InvokeClient blocks until the client
			-- returns, but if the client hangs we still want a bounded reply.
			task.delay(timeoutMs / 1000 + 1, function()
				if replied then return end
				safeReply({
					ok = false,
					errorType = "timeout",
					error = string.format(
						"Client eval did not return within %d ms (server-side watchdog).",
						timeoutMs
					),
				})
			end)

			local invokeOk, payload = pcall(function()
				return clientRelay:InvokeClient(target, {
					replyId = replyId,
					code = code,
					timeoutMs = timeoutMs,
					captureLogs = captureLogs,
				})
			end)
			if not invokeOk then
				safeReply({
					ok = false,
					errorType = "client_disconnected",
					error = "InvokeClient failed (client likely left the test): " .. tostring(payload),
				})
				return
			end
			if type(payload) ~= "table" then
				safeReply({
					ok = false,
					errorType = "client_protocol_error",
					error = "Client returned a non-table payload: " .. typeof(payload),
				})
				return
			end
			safeReply(payload)
			return
		end

		if not LOADSTRING_READY then
			safeReply({
				ok = false,
				errorType = "loadstring_disabled",
				error = "loadstring is disabled. Enable ServerScriptService.LoadStringEnabled in the Properties pane (it has the NotScriptable tag so it cannot be flipped from code) and start a new play test.",
			})
			return
		end

		-- Capture logs scoped to this eval call. We collect into a private
		-- buffer via a fresh LogService connection, then disconnect once
		-- we've replied.
		local localLogs = {}
		local logConn = nil
		if captureLogs then
			logConn = LogService.MessageOut:Connect(function(message, messageType)
				if #localLogs >= 200 then return end
				table.insert(localLogs, {
					message = tostring(message),
					messageType = messageType.Name,
					timestamp = os.time(),
				})
			end)
		end

		local function detachLogs()
			if logConn then
				pcall(function() logConn:Disconnect() end)
				logConn = nil
			end
		end

		-- Compile. NOTE: loadstring returns (nil, errorMessage) on syntax
		-- failure rather than throwing — wrapping in pcall would discard the
		-- error message into pcall's third return slot and leave fnOrErr=nil.
		-- Calling loadstring directly captures both function and error cleanly.
		local fnOrErr, compileErr = loadstring(code, "run_live_lua")
		if type(fnOrErr) ~= "function" then
			detachLogs()
			safeReply({
				ok = false,
				errorType = "compile_error",
				error = "Failed to compile: " .. tostring(compileErr or fnOrErr or "<unknown>"),
				logs = captureLogs and localLogs or nil,
			})
			return
		end

		setfenv(fnOrErr, buildEvalEnv())

		-- Watchdog: if the user code yields longer than timeoutMs, reply
		-- with a synthetic timeout. The user thread will keep running
		-- (we can't kill a yielded thread cleanly) but the AI gets a
		-- bounded response.
		task.delay(timeoutMs / 1000, function()
			if replied then return end
			detachLogs()
			safeReply({
				ok = false,
				errorType = "timeout",
				error = string.format("Eval did not return within %d ms (the spawned thread may still be running in the test).", timeoutMs),
				logs = captureLogs and localLogs or nil,
			})
		end)

		-- Execute. Pack multi-return into an array so the bridge can
		-- preserve `return a, b, c` semantics.
		local results = table.pack(xpcall(fnOrErr, function(err)
			return { error = tostring(err), traceback = debug.traceback(nil, 2) }
		end))
		local execOk = results[1]
		if replied then
			-- Watchdog already responded.
			detachLogs()
			return
		end

		-- LogService.MessageOut events are deferred and need TWO Heartbeats
		-- to actually invoke listeners (verified empirically — one task.wait
		-- isn't enough). Yield twice so prints fired during the eval land
		-- in localLogs before we detach + reply. Total cost ~32ms.
		if captureLogs then
			task.wait()
			task.wait()
		end

		if not execOk then
			detachLogs()
			local err = results[2] or {}
			safeReply({
				ok = false,
				errorType = "runtime_error",
				error = (type(err) == "table" and err.error) or tostring(err),
				traceback = (type(err) == "table") and err.traceback or nil,
				logs = captureLogs and localLogs or nil,
			})
			return
		end

		-- Pack remaining values (results[2..n]) as the multi-return array.
		local values = {}
		for i = 2, results.n do
			values[i - 1] = serializeValue(results[i], 0, {})
		end

		detachLogs()
		safeReply({
			ok = true,
			values = values,
			logs = captureLogs and localLogs or nil,
		})
	end)
end

-- Command poller
task.spawn(function()
	-- First poll includes hello so the bridge can record loadstring
	-- readiness for later run_live_lua callers.
	local helloSent = false
	while not stopRequested and consecutiveFailures < MAX_CONSECUTIVE_FAILURES do
		local pollBody = { sessionId = SESSION_ID, target = "server" }
		if not helloSent then
			pollBody.hello = { loadstringReady = LOADSTRING_READY }
		end
		local ok, response = postJSON("/test-session/poll", pollBody)
		if ok then
			helloSent = true
		end
		if ok and response and response.Body then
			local decodeOk, body = pcall(function()
				return HttpService:JSONDecode(response.Body)
			end)
			if decodeOk and body then
				-- Bridge tells us the session is over (e.g. user clicked Stop
				-- in Studio, or the plugin was reloaded). Stop polling.
				if body.ended then
					stopRequested = true
					break
				end
				if body.command and body.command.cmd == "end" then
					stopRequested = true
					-- Final flush of any pending output before we tear down.
					if #outputBuffer > 0 then
						local final = outputBuffer
						outputBuffer = {}
						postJSON("/test-session/log", {
							sessionId = SESSION_ID,
							source = "server",
							messages = final,
						})
					end
					-- Tell the bridge we're acknowledging the stop. This wakes
					-- any stop_play caller waiting on a confirmation.
					postJSON("/test-session/ended", {
						sessionId = SESSION_ID,
						reason = "mcp_stop",
					})
					-- Finally, end the test. This terminates the yielding
					-- ExecutePlayModeAsync call back in the Edit-side plugin.
					if StudioTestService then
						pcall(function()
							StudioTestService:EndTest(body.command.args or "MCP_Stop")
						end)
					end
					return
				elseif body.command and body.command.cmd == "eval" then
					handleEvalCommand(body.command.args)
				end
			end
		end
		task.wait(POLL_INTERVAL)
	end
end)
]==]

return ServerCompanion
