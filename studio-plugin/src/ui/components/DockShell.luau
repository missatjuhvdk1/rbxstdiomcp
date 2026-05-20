--!strict
-- ui/components/DockShell.luau
--
-- Outer composition of the dock-widget contents. Replaces the legacy
-- mainFrame + contentFrame plumbing at [studio-plugin/plugin.luau
-- L1273-L1387]. Layout:
--
--   ┌─────────────────────────────────────┐
--   │ Header (60px, gradient)             │  ← fixed
--   ├─────────────────────────────────────┤
--   │ ConnectionPanel                     │  ← scrolling content
--   │ StatusPanel                         │
--   └─────────────────────────────────────┘
--
-- The whole thing fills the dock widget (which is sized + parented by
-- the bootstrap). Inside, header is pinned to the top, the rest scrolls.

local React = require(script.Parent.Parent.Parent.Packages.React)
local useTheme = require(script.Parent.Parent.hooks.useTheme)
local Header = require(script.Parent.Header)
local ConnectionPanel = require(script.Parent.ConnectionPanel)
local StatusPanel = require(script.Parent.StatusPanel)

local function DockShell(): React.ReactNode
	local theme = useTheme()

	return React.createElement("Frame", {
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = theme.background,
		BorderSizePixel = 0,
	}, {
		header = React.createElement("Frame", {
			Size = UDim2.new(1, -20, 0, 60),
			Position = UDim2.fromOffset(10, 10),
			BackgroundTransparency = 1,
		}, {
			child = React.createElement(Header, {}),
		}),

		content = React.createElement("ScrollingFrame", {
			Size = UDim2.new(1, -20, 1, -80),
			Position = UDim2.fromOffset(10, 80),
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			ScrollBarThickness = 6,
			ScrollBarImageColor3 = theme.scrollbar,
			-- AutomaticCanvasSize keeps the canvas in sync with the
			-- UIListLayout's content size, so adding/removing the
			-- troubleshoot tip (StatusPanel) doesn't strand a scroll
			-- offset past the new end.
			AutomaticCanvasSize = Enum.AutomaticSize.Y,
			CanvasSize = UDim2.fromOffset(0, 0),
		}, {
			layout = React.createElement("UIListLayout", {
				Padding = UDim.new(0, 12),
				SortOrder = Enum.SortOrder.LayoutOrder,
			}),
			padding = React.createElement("UIPadding", {
				PaddingTop = UDim.new(0, 0),
				PaddingBottom = UDim.new(0, 12),
			}),
			connection = React.createElement(ConnectionPanel, { layoutOrder = 1 }),
			status = React.createElement(StatusPanel, { layoutOrder = 2 }),
		}),
	})
end

return React.memo(DockShell)
