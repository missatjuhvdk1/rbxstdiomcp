--!strict
-- domain/Selection.luau
--
-- BuilderTool's own ordered selection set, kept BIDIRECTIONALLY synced with
-- Studio's Selection service (ARCHITECTURE §9). A re-entrancy guard prevents
-- the sync loop ping-ponging. Destroyed instances are pruned on access.

local Janitor = require(script.Parent.Parent.Packages.Janitor)

export type Selection = {
	changed: RBXScriptSignal,
	get: (self: Selection) -> { BasePart },
	set: (self: Selection, parts: { BasePart }) -> (),
	add: (self: Selection, part: BasePart) -> (),
	remove: (self: Selection, part: BasePart) -> (),
	clear: (self: Selection) -> (),
}

type Internal = Selection & {
	_service: Selection,
	_signal: BindableEvent,
	_items: { BasePart },
	-- True while WE are writing to Studio's Selection so the resulting
	-- SelectionChanged does not mirror straight back in (the ping-pong guard).
	_syncing: boolean,
}

local Selection = {}
Selection.__index = Selection

local function isEditable(instance: Instance): boolean
	return instance:IsA("BasePart") and not (instance :: BasePart).Locked
end

-- Drop any part that is no longer in the data model. Returns true if the set
-- shrank (caller decides whether to broadcast).
local function prune(self: Internal): boolean
	local kept: { BasePart } = {}
	for _, part in self._items do
		if part.Parent ~= nil then
			table.insert(kept, part)
		end
	end
	if #kept ~= #self._items then
		self._items = kept
		return true
	end
	return false
end

-- Studio → us. Read the service set, keep only editable BaseParts, broadcast.
-- Models are expanded to their BasePart descendants so selecting a Model in the
-- Explorer still populates the tool's selection with its parts.
local function mirrorIn(self: Internal)
	local incoming = self._service:Get()
	local kept: { BasePart } = {}
	local seen: { [BasePart]: true } = {}

	local function addPart(inst: Instance)
		if not inst:IsA("BasePart") then return end
		local part = inst :: BasePart
		if not isEditable(part) then return end
		if seen[part] then return end
		seen[part] = true
		table.insert(kept, part)
	end

	for _, instance in incoming do
		if instance:IsA("Model") then
			for _, desc in (instance :: Model):GetDescendants() do
				addPart(desc)
			end
		else
			addPart(instance)
		end
	end

	self._items = kept
	self._signal:Fire()
end

-- Us → Studio. Guarded so the resulting SelectionChanged is ignored, then
-- broadcast our own change.
local function pushOut(self: Internal)
	self._syncing = true
	local ok, err = pcall(function()
		self._service:Set(self._items :: { Instance })
	end)
	self._syncing = false
	if not ok then
		warn(`[BuilderTool] selection push failed: {err}`)
	end
	self._signal:Fire()
end

function Selection.new(service: Selection, janitor: Janitor.Janitor): Selection
	local signal = Instance.new("BindableEvent")
	janitor:Add(signal, "Destroy")

	local self: Internal = setmetatable({
		changed = signal.Event,
		_service = service,
		_signal = signal,
		_items = {},
		_syncing = false,
	}, Selection) :: any

	janitor:Add(
		service.SelectionChanged:Connect(function()
			if not self._syncing then
				mirrorIn(self)
			end
		end),
		"Disconnect"
	)

	-- Adopt whatever is already selected when the plugin loads.
	mirrorIn(self)
	return self
end

function Selection.get(self: Internal): { BasePart }
	prune(self)
	return table.clone(self._items)
end

function Selection.set(self: Internal, parts: { BasePart })
	local filtered: { BasePart } = {}
	local seen: { [BasePart]: true } = {}
	for _, part in parts do
		if isEditable(part) and not seen[part] then
			seen[part] = true
			table.insert(filtered, part)
		end
	end
	self._items = filtered
	pushOut(self)
end

function Selection.add(self: Internal, part: BasePart)
	if not isEditable(part) then
		return
	end
	if table.find(self._items, part) then
		return
	end
	table.insert(self._items, part)
	pushOut(self)
end

function Selection.remove(self: Internal, part: BasePart)
	local index = table.find(self._items, part)
	if not index then
		return
	end
	table.remove(self._items, index)
	pushOut(self)
end

function Selection.clear(self: Internal)
	if #self._items == 0 then
		return
	end
	self._items = {}
	pushOut(self)
end

return Selection
