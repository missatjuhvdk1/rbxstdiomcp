--!strict
-- ui/hooks/useStatus.luau
--
-- Derived view of `ctx.polling`'s status signal. Returns the shape the UI
-- actually wants to render — booleans + a short headline string + the
-- "show troubleshoot tip" gate — so components don't have to repeat the
-- same status-string switch in three places.
--
-- ============================================================================
-- THE TROUBLESHOOT GATE
-- ============================================================================
-- Phase 6 sign-off explicitly requires: "Troubleshoot label appears after 8s
-- of HTTP-ok-but-MCP-down state." That maps to the StatusUpdate shape as
-- `httpReachable == true and mcpConnected == false`. We can't gate it on the
-- raw signal alone — the polling loop emits status transitions only, not a
-- timer — so this hook owns a small `task.delay` that flips a local React
-- state to `true` after the threshold, and resets it whenever httpReachable
-- or mcpConnected change.
--
-- That timer is intentionally hook-local rather than living in Polling: the
-- threshold is a UI presentation decision (it's the time at which a HUMAN
-- starts wondering if something is wrong), not a state-machine concept the
-- runtime should know about. Putting it here keeps `Polling.luau` focused on
-- the protocol and keeps the threshold tunable without restarting the loop.
--
-- ============================================================================
-- WHY USE TASK.DELAY (NOT HEARTBEAT)
-- ============================================================================
-- We need to fire ONCE after 8 seconds of a steady state — not on every
-- frame. `task.delay` is exactly that, and Luau's `task` library cancels via
-- a captured-token pattern: each delay sees a fresh `version` upvalue and
-- compares to the latest. A new state transition increments the version,
-- so the in-flight delay's check fails and it no-ops. No connection bag,
-- no cleanup other than the version bump. The mount-cycle cleanup is still
-- there for the React strict-mode double-invoke case.

local React = require(script.Parent.Parent.Parent.Packages.React)
local Polling = require(script.Parent.Parent.Parent.runtime.http.Polling)
local useRuntime = require(script.Parent.useRuntime)
local useSignal = require(script.Parent.useSignal)

local TROUBLESHOOT_THRESHOLD_SECONDS = 8

export type DerivedStatus = {
	-- Pass-throughs from the polling StatusUpdate, kept so components can
	-- key on the underlying status name when a switch is genuinely needed.
	raw: Polling.StatusUpdate,
	-- Convenience booleans matching the three step indicators.
	httpOk: boolean,
	mcpConnected: boolean,
	isReady: boolean,
	-- Headline + colour-state for the prominent status label.
	headline: string,
	headlineState: "connected" | "waiting" | "error" | "idle",
	-- True once the user has been HTTP-OK-but-MCP-DOWN long enough for the
	-- troubleshoot tip to be more helpful than confusing.
	shouldShowTroubleshoot: boolean,
}

local function headlineFor(update: Polling.StatusUpdate): (string, "connected" | "waiting" | "error" | "idle")
	if update.status == "connected" then
		return "Connected", "connected"
	elseif update.status == "waiting" then
		return "Connected to bridge, waiting for MCP...", "waiting"
	elseif update.status == "connecting" then
		return "Connecting...", "waiting"
	elseif update.status == "retrying" then
		local seconds = math.max(1, math.floor(update.nextRetryDelay + 0.5))
		return string.format("Retrying in ~%ds...", seconds), "waiting"
	elseif update.status == "error" then
		return "Server unavailable", "error"
	else
		return "Disconnected", "idle"
	end
end

local function useStatus(): DerivedStatus
	local ctx = useRuntime()

	local raw = useSignal(ctx.polling.statusChanged, function(): Polling.StatusUpdate
		return ctx.polling:getStatus()
	end)

	local headline, headlineState = headlineFor(raw)

	-- Troubleshoot delay: only when http is OK but MCP is not, AND we stay
	-- there for THRESHOLD seconds. Any other state cancels the in-flight
	-- timer via the captured-version pattern.
	local shouldShowTroubleshoot, setShouldShowTroubleshoot = React.useState(false)
	local versionRef = React.useRef(0)

	React.useEffect(function()
		-- Bump the version so any in-flight delay no-ops on resume.
		versionRef.current = (versionRef.current :: number) + 1
		local thisVersion = versionRef.current :: number

		if raw.httpReachable and not raw.mcpConnected then
			-- We MIGHT be in the troubleshoot-pending window. Schedule.
			setShouldShowTroubleshoot(false)
			task.delay(TROUBLESHOOT_THRESHOLD_SECONDS, function()
				if versionRef.current == thisVersion then
					setShouldShowTroubleshoot(true)
				end
			end)
		else
			-- Any other state hides the tip immediately (don't leave a
			-- stale "MCP isn't responding" up after we've reconnected).
			setShouldShowTroubleshoot(false)
		end

		return function()
			-- Effect cleanup just bumps the version. The pending closure
			-- still runs but its == check fails, so it no-ops.
			versionRef.current = (versionRef.current :: number) + 1
		end
	end, { raw.httpReachable, raw.mcpConnected } :: { any })

	return {
		raw = raw,
		httpOk = raw.httpReachable,
		mcpConnected = raw.mcpConnected,
		isReady = raw.status == "connected",
		headline = headline,
		headlineState = headlineState,
		shouldShowTroubleshoot = shouldShowTroubleshoot,
	}
end

return useStatus
