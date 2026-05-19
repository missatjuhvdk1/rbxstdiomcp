--!strict
-- ui/hooks/useSignal.luau
--
-- Subscribe a component to a plain signal (typically a BindableEvent.Event
-- exposed by `runtime/`) and re-render with a derived value. The disconnect
-- in the effect cleanup is MANDATORY (ARCHITECTURE §11). It is the leak the
-- legacy plugin made over and over: signal connections opened in one
-- start()-style function with no symmetric stop() that disconnects them.
--
-- React-lua subtleties:
--
--   1. The initial-state computation receives `get` as the lazy initializer.
--      React passes the prior state to lazy initializers, so we cast it via
--      `(get :: any)` — the cast is OK because the prior state is unused on
--      first render and `get()` returns the typed T we promise.
--   2. The deps array is `{ signal }`: if the signal IDENTITY changes (rare
--      — the parent component would have to pass a fresh signal object), we
--      disconnect from the old and connect to the new. We deliberately do
--      NOT include `get` in deps even though it's used inside the effect:
--      callers typically pass an inline closure that captures fresh state,
--      and re-subscribing on every render would burn the connection
--      every frame. The contract is: `get` must be safe to call from any
--      signal-emission context (it usually just reads `ctx.<x>:getStatus()`).
--   3. The cleanup function unconditionally disconnects, even if the signal
--      already fired one last time. RBXScriptConnection:Disconnect is
--      idempotent in Roblox so a double-disconnect from React strict-mode
--      double-invoke is harmless.

local React = require(script.Parent.Parent.Parent.Packages.React)

local function useSignal<T>(signal: RBXScriptSignal, get: () -> T): T
	local value, setValue = React.useState(get :: any)

	React.useEffect(function()
		-- Resync on (re)subscribe in case the value changed between render
		-- and the effect firing — without this, a polling state transition
		-- that lands one tick before mount would be invisible until the
		-- next state change.
		setValue(get())

		-- We deliberately ignore the signal's payload (varargs would be
		-- typed `...any` here, which selene/strict mode would flag as
		-- unused). The hook contract is "re-derive from `get()` on every
		-- emission" — the payload itself is callers' responsibility to
		-- read inside `get` if they need it.
		local connection = signal:Connect(function()
			setValue(get())
		end)
		return function()
			connection:Disconnect()
		end
	end, { signal } :: { any })

	return value
end

return useSignal
