--!strict
-- ui/hooks/useSignal.luau
--
-- Subscribes a component to a plain signal (a BindableEvent.Event exposed by
-- domain/runtime) and re-renders with a derived value. The disconnect in the
-- effect cleanup is MANDATORY (ARCHITECTURE §11 — the ResurfacePlugin
-- useValue pattern; the leak it prevents is the SunAnimator failure mode).

local React = require(script.Parent.Parent.Parent.Packages.React)

local function useSignal<T>(signal: RBXScriptSignal, get: () -> T): T
	local value, setValue = React.useState(get :: any)

	React.useEffect(function()
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
