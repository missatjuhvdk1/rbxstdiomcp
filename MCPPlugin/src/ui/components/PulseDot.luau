--!strict
-- ui/components/PulseDot.luau
--
-- The animated status indicator in the dock header. Replaces the legacy
-- TweenService:Create pulse at [studio-plugin/plugin.luau L1609-1638]: a
-- 1s sin-wave that grows the dot from 16px → 24px and fades its
-- transparency from 0.7 → 1.0 while the plugin is "connecting" or
-- "connected". When idle/error, the pulse is OFF and only the base dot
-- shows.
--
-- ============================================================================
-- WHY HEARTBEAT + REF INSTEAD OF REACT STATE PER FRAME
-- ============================================================================
-- Animating via React.useState(transparency) would re-render the whole tree
-- every Heartbeat tick — gross. The escape hatch React-lua sanctions for
-- this is: useRef to the Frame instance, then mutate properties directly
-- inside a Heartbeat callback. React just paints the first frame; from
-- there the animation is a sibling concern.
--
-- We pull `runService` from the typed Context (useRuntime), NOT from
-- `game:GetService` — the CI gate's service-quarantine forbids that
-- outside `runtime/Services.luau` (ARCHITECTURE §4.3, §15 A3). The
-- Heartbeat connection is opened in useEffect and disconnected in
-- cleanup; the architecture's "every connection Janitor-tracked at
-- creation" rule (§4 invariant 7) is satisfied by React's effect cleanup
-- being a strict-mode-safe equivalent for component-local connections.
--
-- ============================================================================
-- WHY NO TWEENSERVICE
-- ============================================================================
-- TweenService would require either:
--   (a) adding it to Services.luau (a Studio-API surface this plugin
--       otherwise doesn't touch — bigger blast radius than warranted), or
--   (b) calling game:GetService("TweenService") from this file (forbidden).
-- A 12-line sin-wave on Heartbeat is fewer lines than the diff to add the
-- service and creates zero TweenBase instances that need cleanup.

local React = require(script.Parent.Parent.Parent.Packages.React)
local useRuntime = require(script.Parent.Parent.hooks.useRuntime)

export type Props = {
	-- Whether the pulse animation should run. When false, the dot is solid
	-- with no halo (offline/error states).
	pulsing: boolean,
	-- Base colour of the dot. Caller (Header) picks from the theme's
	-- state* tokens based on current connection state. Passing the colour
	-- via props (rather than reading useTheme() here) keeps this component
	-- presentational — it doesn't need to know which state the dot is
	-- representing, just what colour to paint.
	colour: Color3,
}

local BASE_SIZE = 16
local PULSE_GROWTH_PX = 8 -- 16 → 24 at peak, matching legacy L1619.
local PULSE_PERIOD_SECONDS = 1.0

local function PulseDot(props: Props): React.ReactNode
	local ctx = useRuntime()

	local pulseRef = React.useRef(nil :: Frame?)
	local pulsing = props.pulsing

	React.useEffect(function()
		if not pulsing then
			-- Reset to resting state.
			local frame = pulseRef.current
			if frame then
				frame.Size = UDim2.fromOffset(BASE_SIZE, BASE_SIZE)
				frame.Position = UDim2.fromOffset(0, 0)
				frame.BackgroundTransparency = 0.7
			end
			return function() end
		end

		local startClock = os.clock()
		local connection = ctx.services.runService.Heartbeat:Connect(function()
			local frame = pulseRef.current
			if not frame then
				return
			end
			-- Sinusoidal pulse 0 → 1 → 0 over PULSE_PERIOD_SECONDS, easing
			-- via half-period sine. Matches the legacy InOut Sine tween's
			-- visual character at L1618 without needing a TweenInfo.
			local t = (os.clock() - startClock) % PULSE_PERIOD_SECONDS / PULSE_PERIOD_SECONDS
			local phase = math.sin(t * math.pi) -- 0..1..0

			local growth = math.floor(PULSE_GROWTH_PX * phase + 0.5)
			frame.Size = UDim2.fromOffset(BASE_SIZE + growth, BASE_SIZE + growth)
			frame.Position = UDim2.fromOffset(-growth / 2, -growth / 2)
			-- Transparency goes 0.7 (solid-ish) → 1.0 (invisible) at peak,
			-- so the halo fades out as it grows, exactly like the legacy.
			frame.BackgroundTransparency = 0.7 + 0.3 * phase
		end)

		return function()
			connection:Disconnect()
		end
	end, { pulsing, ctx.services.runService } :: { any })

	return React.createElement("Frame", {
		Size = UDim2.fromOffset(BASE_SIZE, BASE_SIZE),
		BackgroundColor3 = props.colour,
		BorderSizePixel = 0,
	}, {
		corner = React.createElement("UICorner", {
			CornerRadius = UDim.new(1, 0),
		}),
		-- The halo. Sits ABOVE the base dot in the same frame; its size
		-- grows past the parent's bounds which is fine because we are NOT
		-- ClipDescendants on the parent.
		pulse = React.createElement("Frame", {
			ref = pulseRef,
			Size = UDim2.fromOffset(BASE_SIZE, BASE_SIZE),
			Position = UDim2.fromOffset(0, 0),
			BackgroundColor3 = props.colour,
			BackgroundTransparency = 0.7,
			BorderSizePixel = 0,
			ZIndex = 2,
		}, {
			corner = React.createElement("UICorner", {
				CornerRadius = UDim.new(1, 0),
			}),
		}),
	})
end

return React.memo(PulseDot)
