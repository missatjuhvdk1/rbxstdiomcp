--!strict
-- runtime/Input.luau
--
-- UserInputService adapter. Owns ONE set of input connections (created on
-- start, all added to the root Janitor). The ToolHost subscribes here and
-- fans events to the active tool; individual tools NEVER connect to
-- UserInputService directly (ARCHITECTURE §6.2 — the antidote to the
-- SunAnimator connection sprawl, §15 A5).

local Janitor = require(script.Parent.Parent.Packages.Janitor)

export type InputPhase = "Began" | "Changed" | "Ended"
export type Listener = (phase: InputPhase, input: InputObject) -> ()

export type Input = {
	-- Returns an unsubscribe function. The subscription is also Janitor-owned.
	subscribe: (self: Input, listener: Listener) -> () -> (),
	destroy: (self: Input) -> (),
}

type Internal = Input & {
	_listeners: { [Listener]: true },
}

local Input = {}
Input.__index = Input

-- One bad listener must not wedge the others or the input pipeline (§13).
local function dispatch(self: Internal, phase: InputPhase, input: InputObject)
	for listener in self._listeners do
		local ok, err = pcall(listener, phase, input)
		if not ok then
			warn(`[BuilderTool] input listener error ({phase}): {err}`)
		end
	end
end

function Input.new(userInput: UserInputService, janitor: Janitor.Janitor): Input
	local self: Internal = setmetatable({
		_listeners = {},
	}, Input) :: any

	-- gameProcessed = the event was consumed by Studio's own UI; never act on
	-- it (clicking the palette must not also manipulate the viewport).
	janitor:Add(
		userInput.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
			if not gameProcessed then
				dispatch(self, "Began", input)
			end
		end),
		"Disconnect"
	)
	janitor:Add(
		userInput.InputChanged:Connect(function(input: InputObject, gameProcessed: boolean)
			if not gameProcessed then
				dispatch(self, "Changed", input)
			end
		end),
		"Disconnect"
	)
	janitor:Add(
		userInput.InputEnded:Connect(function(input: InputObject, gameProcessed: boolean)
			if not gameProcessed then
				dispatch(self, "Ended", input)
			end
		end),
		"Disconnect"
	)

	return self
end

function Input.subscribe(self: Internal, listener: Listener): () -> ()
	self._listeners[listener] = true
	return function()
		self._listeners[listener] = nil
	end
end

function Input.destroy(self: Internal)
	table.clear(self._listeners)
end

return Input
