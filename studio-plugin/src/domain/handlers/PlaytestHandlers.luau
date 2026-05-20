--!strict
-- domain/handlers/PlaytestHandlers.luau
--
-- Phase 5 — playtest control:
--   - playSolo  ← legacy plugin.luau L5870-5980
--   - stopPlay  ← legacy plugin.luau L5982-5993 (deprecated stub kept for
--                 backward compatibility with older bridges/clients)
--
-- ============================================================================
-- WHY playSolo HAS NO RecordResult
-- ============================================================================
-- Starting a play test mutates Studio session state (it spawns a test
-- DataModel) but does NOT mutate the Edit DataModel that ChangeHistoryService
-- tracks. Ctrl-Z should not "undo a playtest". RecordResult = nil tells the
-- Dispatcher to skip both CHS and ActionLog.
--
-- The companion *injection* DOES touch the Edit DataModel — we create a
-- Script + LocalScript and parent them under ServerScriptService and
-- StarterPlayerScripts respectively. Those instances:
--   - Carry the TEST_COMPANION_TAG so the cleanup sweep can find them.
--   - Are deleted before the test ends (by the spawn'd `task.spawn` block).
--   - Are protected by Companions.isProtected so a misbehaving LLM can't
--     delete them mid-test.
-- We intentionally do NOT track these inject/cleanup operations in the undo
-- stack: the user expects "start playtest / stop playtest" to be transparent
-- around their place edits.
--
-- ============================================================================
-- WHY ExecutePlayModeAsync RUNS ON A task.spawn'd THREAD
-- ============================================================================
-- ExecutePlayModeAsync yields until the test ends. If we awaited it inside
-- the handler, the bridge's HTTP response for /api/play-solo would be held
-- open for the entire test session (could be minutes), and the polling loop
-- would block on this one request the entire time. Off-thread it, return
-- the start payload immediately, and let the spawn'd thread handle cleanup
-- + bridge notification when the test eventually ends.
--
-- ============================================================================
-- WHY stopPlay IS DEPRECATED
-- ============================================================================
-- StudioTestService:EndTest can ONLY be called from inside the test's Server
-- DataModel (not the Edit DataModel that the plugin runs in). The modern
-- protocol routes stop_play through the bridge to the in-test companion,
-- which calls EndTest from inside the test. This handler exists only so
-- older callers that POST /api/stop-play directly get an actionable error
-- rather than a 404.

local Handler = require(script.Parent.Parent.handler.Handler)
local Path = require(script.Parent.Parent.Parent.runtime.instance.Path)
local Companions = require(script.Parent.Parent.Parent.runtime.testsession.Companions)

-- ============================================================================
-- TYPED REQUEST SHAPES
-- ============================================================================

type PlaySoloRequest = {
	sessionId: string?,
}

-- stopPlay's body is ignored (it's deprecated) but we still take a `data` arg
-- for the handler signature.

-- ============================================================================
-- HANDLERS
-- ============================================================================

local PlaytestHandlers = {}

-- playSolo: inject companions + start ExecutePlayModeAsync. Legacy L5870-5980.
-- Returns the start payload immediately; the actual test runs on a spawn'd
-- thread that cleans up companions and posts /test-session/ended when done.
PlaytestHandlers.playSolo = Handler.define(
	"/api/play-solo",
	function(ctx, data: PlaySoloRequest): (any, Handler.RecordResult?)
		-- sessionId is bridge-generated; older clients without it cannot
		-- correlate logs with the right session, so we hard-require it.
		local sessionId = data.sessionId
		if type(sessionId) ~= "string" or sessionId == "" then
			return {
				success = false,
				error = "sessionId required (the bridge generates one and passes it; older clients won't have it).",
			},
				nil
		end

		-- StudioTestService preflight. The Services module probes optionally
		-- (older Studio versions lacked it) and stores nil-or-service.
		local sts = ctx.services.studioTestService
		if sts == nil then
			return {
				success = false,
				error = "StudioTestService unavailable in this Studio version. "
					.. "Update Roblox Studio to use playtest features.",
			},
				nil
		end

		-- HttpService.HttpEnabled preflight. Plugins (this script) bypass
		-- HttpEnabled, but the companion runs as an in-game script in the
		-- test DataModel and does NOT bypass it. Without HttpEnabled the
		-- companion can't reach the bridge and stop_play silently times out.
		-- LocalUserSecurity prevents a plugin from flipping HttpEnabled, so
		-- the best we can do is fail fast with an actionable error.
		local httpEnabledOk, httpEnabled = pcall(function(): boolean
			return ctx.services.httpService.HttpEnabled
		end)
		if httpEnabledOk and httpEnabled == false then
			return {
				success = false,
				error = "HttpService.HttpEnabled is false. The injected test-session companion "
					.. "runs as an in-game script and needs HTTP access to stream logs and "
					.. "receive the stop command. Enable it in Studio: Game Settings → Security "
					.. "→ Allow HTTP Requests. A plugin cannot toggle this setting itself "
					.. "(LocalUserSecurity).",
				fixSteps = {
					"Open Game Settings (Home tab → Game Settings, or File → Game Settings)",
					"Go to the Security section",
					"Toggle 'Allow HTTP Requests' ON",
					"Click Save, then call play_solo again",
				},
			},
				nil
		end

		-- Pre-flight cleanup: best-effort sweep any orphan companion from a
		-- previous crashed test. If there's a *live* test, we can't detect
		-- it from the Edit DataModel; the user has to stop it manually.
		local deps = { services = ctx.services, constants = ctx.constants }
		Companions.cleanup(deps)

		-- Inject + spawn the test. injectTestCompanion → ExecutePlayModeAsync
		-- on a spawn'd thread so this HTTP response returns now.
		local serverUrl = ctx.settings:getServerUrl()
		local injectOk, injectResultOrErr = pcall(function()
			return Companions.inject(deps, serverUrl, sessionId :: string)
		end)
		if not injectOk then
			-- If inject blew up, make doubly sure we didn't leave a partial
			-- companion behind (the inject function does its own cleanup
			-- pre-create but a failure during AddTag could still leak).
			pcall(function()
				Companions.cleanup(deps)
			end)
			return {
				success = false,
				sessionId = sessionId,
				error = "Failed to inject companions: " .. tostring(injectResultOrErr),
			},
				nil
		end
		local injectResult = injectResultOrErr :: Companions.InjectResult

		-- ExecutePlayModeAsync yields. Off-thread it so our HTTP response
		-- can return immediately. When the test ends, this thread:
		--   1. Sweeps the companion out of the Edit DataModel.
		--   2. Posts /test-session/ended to tell the bridge the session is
		--      over (the in-test companion may have already done this; the
		--      bridge's endTestSession endpoint is idempotent).
		task.spawn(function()
			local execOk, execResult = pcall(function()
				return sts:ExecutePlayModeAsync(sessionId)
			end)

			-- Always clean up the Edit-DataModel companion. The one in the
			-- test DM died with the test.
			pcall(function()
				Companions.cleanup(deps)
			end)

			-- Notify the bridge. Use HttpClient via ctx for retry/timeout
			-- behaviour consistent with the rest of the plugin.
			pcall(function()
				ctx.services.httpService:RequestAsync({
					Url = serverUrl .. "/test-session/ended",
					Method = "POST",
					Headers = { ["Content-Type"] = "application/json" },
					Body = ctx.services.httpService:JSONEncode({
						sessionId = sessionId,
						reason = execOk and "natural" or "exec_error",
						value = execOk and execResult or nil,
						error = (not execOk) and tostring(execResult) or nil,
					}),
				})
			end)
		end)

		local clientCompanionPath: string? = nil
		if injectResult.clientScript ~= nil then
			clientCompanionPath = Path.getInstancePath(injectResult.clientScript :: LocalScript)
		end

		return {
			success = true,
			sessionId = sessionId,
			method = "StudioTestService:ExecutePlayModeAsync",
			companionPath = Path.getInstancePath(injectResult.serverScript),
			clientCompanionPath = clientCompanionPath,
			message = "Started Play Solo with MCP server + client companions. "
				.. "Use stop_play to end, get_playtest_output to read logs, "
				.. "run_live_lua to execute code in the running test.",
		},
			nil
	end
)

-- stopPlay: deprecated stub. Legacy L5982-5993. Returns a structured error
-- explaining the new protocol. NOT a RecordResult — read-only by definition
-- (does literally nothing).
PlaytestHandlers.stopPlay = Handler.define("/api/stop-play", function(_ctx, _data: any): (any, Handler.RecordResult?)
	return {
		success = false,
		deprecated = true,
		error = "/api/stop-play is deprecated. The MCP stop_play tool now signals the "
			.. "in-test companion via the bridge — update your MCP server to a version "
			.. "that includes the test-session protocol.",
	},
		nil
end)

return PlaytestHandlers
