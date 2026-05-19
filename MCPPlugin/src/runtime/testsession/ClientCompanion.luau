--!strict
-- runtime/testsession/ClientCompanion.luau
--
-- Phase 5 — client-side test-session companion source, as data.
--
-- ============================================================================
-- WHAT THIS MODULE IS (READ THIS BEFORE EDITING)
-- ============================================================================
-- Sister to ServerCompanion.luau. Returns the literal source text of the
-- client-side test companion as a string constant. `Companions.inject(...)`
-- reads `.source` and assigns it to a freshly created `LocalScript` instance
-- which is parented into StarterPlayer.StarterPlayerScripts at play-test
-- injection time so every Player gets a copy in PlayerScripts on join.
--
-- ============================================================================
-- WHY CLIENT-SIDE AT ALL
-- ============================================================================
-- run_live_lua's `target = "client"` route needs code to execute on a real
-- Player's machine (not the test server). Without a LocalScript companion
-- the server-side InvokeClient call would have nothing to invoke. We also
-- want client LogService.MessageOut piped back, which a server LogService
-- listener cannot observe (client LogService only emits client-local logs).
--
-- ============================================================================
-- NO PLACEHOLDERS
-- ============================================================================
-- Unlike ServerCompanion, the client never makes an HTTP request and never
-- learns the bridge URL or session ID. It talks to the server companion via
-- ReplicatedStorage RemoteEvents/RemoteFunctions, which the server side
-- created. The server forwards everything over HTTP on the client's behalf.
-- So there's nothing to gsub — the body is injected verbatim.
--
-- ============================================================================
-- WHY MUST IT STAY A STRING-CONSTANT MODULE
-- ============================================================================
--   1. The body uses `loadstring`, `setfenv`, and indirectly `_G` (via the
--      env metatable `__index = _G`). Those tokens are banned in plugin-
--      runtime code by §15. They are legal *here* only because they live
--      inside a long-string literal. The golden CI gate whitelists this
--      file with written justification.
--   2. The companion runs in a separate Roblox DataModel; even if we
--      authored it as a real Luau module, the test-side DataModel cannot
--      `require` modules from the plugin DataModel.
--   3. Authoring as a long-string keeps the legacy 350-line body intact
--      while letting us version, review, and diff it like normal code.
--
-- ============================================================================
-- DELIMITER CHOICE
-- ============================================================================
-- We use `[==[ ... ]==]` (level-2 long-string) because the body contains
-- `]]` from table indexes and from inner `[[ ... ]]` long strings (e.g.
-- chunk name "run_live_lua_client"). `[==[` keeps the parser happy as long
-- as the body never contains `]==]`, which we verify by inspection
-- (legacy text has no triple-equals brackets).
--
-- ============================================================================
-- WIRE-CONTRACT POINTERS (mirror ServerCompanion)
-- ============================================================================
-- Talks to these ReplicatedStorage instances by name:
--   _MCPClientHello : RemoteEvent     (we FireServer with loadstring probe)
--   _MCPClientLogs  : RemoteEvent     (we FireServer with batched logs)
--   _MCPClientRelay : RemoteFunction  (server InvokeClient → us → reply)

local ClientCompanion = {}

ClientCompanion.source = [==[-- _MCPTestCompanion_Client (auto-generated, safe to delete)
-- Runs in each Player's PlayerScripts during a Studio test session started by
-- the MCP plugin. Streams local LogService output to the server companion via
-- RemoteEvents and runs run_live_lua eval commands dispatched through a
-- RemoteFunction.
--
-- IMPORTANT: HttpService is server-only in Roblox. LocalScripts CANNOT make
-- HTTP requests (they'll silently fail with HttpError). So everything goes
-- through Remotes. The server companion in ServerScriptService is the only
-- HTTP gateway and forwards messages on our behalf.
--
-- DO NOT modify or delete while a play test is running — it will be cleaned
-- up automatically by the MCP plugin.

local LogService = game:GetService("LogService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LOG_FLUSH_INTERVAL = 0.25
local MAX_BUFFER = 5000
local REMOTE_WAIT_TIMEOUT = 30 -- seconds

local localPlayer = Players.LocalPlayer
if not localPlayer then return end -- LocalScript guarantees LocalPlayer; bail otherwise
local PLAYER_NAME = localPlayer.Name

-- Wait for the server companion to create the Remotes in ReplicatedStorage.
-- The server companion runs slightly before us in test mode (Server scripts
-- start before LocalScripts), but we still WaitForChild defensively.
local clientRelay = ReplicatedStorage:WaitForChild("_MCPClientRelay", REMOTE_WAIT_TIMEOUT)
local clientHello = ReplicatedStorage:WaitForChild("_MCPClientHello", REMOTE_WAIT_TIMEOUT)
local clientLogs  = ReplicatedStorage:WaitForChild("_MCPClientLogs",  REMOTE_WAIT_TIMEOUT)
if not (clientRelay and clientHello and clientLogs) then
	-- Server companion didn't set up Remotes in time. Nothing we can do.
	warn("[_MCPTestCompanion_Client] Remotes not found in ReplicatedStorage — server companion missing or slow")
	return
end

-- Probe loadstring availability ONCE up front. Note: client-side gating may
-- differ from server's ServerScriptService.LoadStringEnabled, so we probe.
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

-- Announce ourselves to the server companion, which will register us with
-- the bridge over HTTP on our behalf.
clientHello:FireServer({ loadstringReady = LOADSTRING_READY })

-- ---------------------------------------------------------------------------
-- Result serializer (matches the server companion's serializer 1:1).
-- ---------------------------------------------------------------------------
local function serializeValue(value, depth, seen)
	depth = depth or 0
	seen = seen or {}
	if depth > 8 then return "<max depth>" end
	local t = typeof(value)
	if value == nil then
		return nil
	elseif t == "string" then
		if #value > 65536 then return string.sub(value, 1, 65536) .. "...<truncated>" end
		return value
	elseif t == "number" then
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
			if count > 200 then result["__truncated__"] = true; break end
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
		local ok, str = pcall(tostring, value)
		return ok and str or ("<" .. t .. ">")
	end
end

-- ---------------------------------------------------------------------------
-- LogService streaming → batched FireServer
-- ---------------------------------------------------------------------------
local outputBuffer = {}
LogService.MessageOut:Connect(function(message, messageType)
	if #outputBuffer >= MAX_BUFFER then
		table.remove(outputBuffer, 1)
	end
	table.insert(outputBuffer, {
		message = tostring(message),
		messageType = messageType.Name,
		timestamp = os.time(),
	})
end)

task.spawn(function()
	while true do
		if #outputBuffer > 0 then
			local toSend = outputBuffer
			outputBuffer = {}
			-- FireServer is fire-and-forget; the server companion will tag
			-- with our PLAYER_NAME and forward to /test-session/log.
			pcall(function() clientLogs:FireServer(toSend) end)
		end
		task.wait(LOG_FLUSH_INTERVAL)
	end
end)

-- ---------------------------------------------------------------------------
-- Eval handler. The server companion calls clientRelay:InvokeClient(player,
-- args), which suspends the server until we return a payload table. We do
-- the same setfenv/xpcall sandbox dance as the server, with our own watchdog.
-- ---------------------------------------------------------------------------
local function buildEvalEnv()
	return setmetatable({
		game = game,
		workspace = workspace,
		Players = Players,
		Workspace = workspace,
		ReplicatedStorage = ReplicatedStorage,
		StarterGui = game:GetService("StarterGui"),
		StarterPlayer = game:GetService("StarterPlayer"),
		Lighting = game:GetService("Lighting"),
		SoundService = game:GetService("SoundService"),
		TweenService = game:GetService("TweenService"),
		RunService = game:GetService("RunService"),
		UserInputService = game:GetService("UserInputService"),
		ContextActionService = game:GetService("ContextActionService"),
		CollectionService = game:GetService("CollectionService"),
		GuiService = game:GetService("GuiService"),
		TextService = game:GetService("TextService"),
		MarketplaceService = game:GetService("MarketplaceService"),
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
		LocalPlayer = localPlayer,
		PlayerGui = localPlayer:FindFirstChildOfClass("PlayerGui"),
	}, { __index = _G })
end

local function runEval(args)
	-- args = { replyId, code, timeoutMs, captureLogs }
	if type(args) ~= "table" or type(args.code) ~= "string" then
		return { ok = false, errorType = "client_protocol_error", error = "Invalid eval args" }
	end
	local code = args.code
	local timeoutMs = type(args.timeoutMs) == "number" and args.timeoutMs or 5000
	local captureLogs = args.captureLogs ~= false

	local startedAt = os.clock()
	local replied = false
	local resultPayload = nil
	local function reply(payload)
		if replied then return end
		replied = true
		payload.durationMs = math.floor((os.clock() - startedAt) * 1000)
		resultPayload = payload
	end

	if not LOADSTRING_READY then
		reply({
			ok = false,
			errorType = "loadstring_disabled",
			error = "loadstring is disabled on this client. (LocalScript loadstring depends on Studio settings; ServerScriptService.LoadStringEnabled may also be required.)",
		})
		return resultPayload
	end

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

	-- Capture both return values directly (loadstring returns nil + error
	-- message on syntax failure rather than throwing).
	local fnOrErr, compileErr = loadstring(code, "run_live_lua_client")
	if type(fnOrErr) ~= "function" then
		detachLogs()
		reply({
			ok = false,
			errorType = "compile_error",
			error = "Failed to compile: " .. tostring(compileErr or fnOrErr or "<unknown>"),
			logs = captureLogs and localLogs or nil,
		})
		return resultPayload
	end
	setfenv(fnOrErr, buildEvalEnv())

	-- Local watchdog: if user code yields longer than timeoutMs, the watchdog
	-- pre-fills resultPayload with a timeout response, then the slow code
	-- still finishes (we can't kill it cleanly) but its result is discarded.
	task.delay(timeoutMs / 1000, function()
		if replied then return end
		detachLogs()
		reply({
			ok = false,
			errorType = "timeout",
			error = string.format("Eval did not return within %d ms (the spawned thread may still be running in the client).", timeoutMs),
			logs = captureLogs and localLogs or nil,
		})
	end)

	local results = table.pack(xpcall(fnOrErr, function(err)
		return { error = tostring(err), traceback = debug.traceback(nil, 2) }
	end))
	local execOk = results[1]
	if replied then
		detachLogs()
		return resultPayload
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
		reply({
			ok = false,
			errorType = "runtime_error",
			error = (type(err) == "table" and err.error) or tostring(err),
			traceback = (type(err) == "table") and err.traceback or nil,
			logs = captureLogs and localLogs or nil,
		})
		return resultPayload
	end

	local values = {}
	for i = 2, results.n do
		values[i - 1] = serializeValue(results[i], 0, {})
	end
	detachLogs()
	reply({
		ok = true,
		values = values,
		logs = captureLogs and localLogs or nil,
	})
	return resultPayload
end

clientRelay.OnClientInvoke = function(args)
	-- pcall the whole thing so a runtime crash inside runEval still produces
	-- a deterministic reply for the server-side InvokeClient caller.
	local ok, payloadOrErr = pcall(runEval, args)
	if ok and type(payloadOrErr) == "table" then
		return payloadOrErr
	end
	return {
		ok = false,
		errorType = "client_protocol_error",
		error = "runEval crashed: " .. tostring(payloadOrErr),
	}
end
]==]

return ClientCompanion
