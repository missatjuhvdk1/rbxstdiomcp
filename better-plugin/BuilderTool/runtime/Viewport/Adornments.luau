--!strict
-- runtime/Viewport/Adornments.luau
--
-- The plugin-owned CoreGui adornment surface (ARCHITECTURE §7). ONE folder,
-- named with a build-session suffix so two plugin versions never collide,
-- added to the root Janitor at creation. Never parents to workspace. Hover
-- and selection use DISTINCT instances.

local Janitor = require(script.Parent.Parent.Parent.Packages.Janitor)

-- Mirrors Constants.ADORNMENT_FOLDER_PREFIX; Adornments.new is handed only the
-- sessionId, so the prefix is duplicated here as the persistence-free default.
local FOLDER_PREFIX = "BuilderToolAdornments"

export type Role = "hover" | "selection"

export type Adornments = {
	folder: Folder,
	-- Acquire/release pooled adornments by role; release returns them to the
	-- pool, it does not Destroy (the root Janitor owns final teardown).
	acquireHighlight: (self: Adornments, role: Role) -> Highlight,
	releaseHighlight: (self: Adornments, highlight: Highlight) -> (),
}

type Internal = Adornments & {
	_free: { [Role]: { Highlight } },
}

local Adornments = {}
Adornments.__index = Adornments

-- Hover and selection are visually distinct (§7): a thin outline-only hover
-- vs. a filled selection. Created disabled; the caller enables on acquire.
local function makeHighlight(folder: Folder, role: Role): Highlight
	local highlight = Instance.new("Highlight")
	highlight.Name = `BuilderTool_{role}`
	highlight.Enabled = false
	highlight.Adornee = nil
	highlight.DepthMode = Enum.HighlightDepthMode.Occluded
	if role == "hover" then
		highlight.FillTransparency = 1
		highlight.OutlineColor = Color3.fromRGB(255, 255, 255)
	else
		highlight.FillColor = Color3.fromRGB(50, 130, 255)
		highlight.FillTransparency = 0.7
		highlight.OutlineColor = Color3.fromRGB(50, 130, 255)
	end
	highlight.Parent = folder
	return highlight
end

function Adornments.new(coreGui: CoreGui, sessionId: string, janitor: Janitor.Janitor): Adornments
	local folder = Instance.new("Folder")
	folder.Name = `{FOLDER_PREFIX}_{sessionId}`
	folder.Parent = coreGui
	-- Destroying the folder destroys every pooled adornment with it; this is
	-- the single teardown path for the whole adornment surface (§12).
	janitor:Add(folder, "Destroy")

	local self: Internal = setmetatable({
		folder = folder,
		_free = {
			hover = {},
			selection = {},
		},
	}, Adornments) :: any

	return self
end

function Adornments.acquireHighlight(self: Internal, role: Role): Highlight
	local pooled = table.remove(self._free[role])
	if pooled then
		pooled.Enabled = true
		return pooled
	end
	local highlight = makeHighlight(self.folder, role)
	highlight.Enabled = true
	return highlight
end

function Adornments.releaseHighlight(self: Internal, highlight: Highlight)
	highlight.Enabled = false
	highlight.Adornee = nil
	local role: Role = if highlight.Name == "BuilderTool_selection" then "selection" else "hover"
	table.insert(self._free[role], highlight)
end

return Adornments
