--!strict
-- domain/tool/ToolRegistry.luau
--
-- The ONLY place that enumerates tools (ARCHITECTURE §6.3). Populated by
-- EXPLICIT require of each domain/tools/<Name>Tool.luau — never dynamic /
-- string-driven module loading (the SunAnimator dynamic-DI anti-pattern,
-- §15 A2). Adding a tool = add the module + one line here.

local Tool = require(script.Parent.Tool)

local MoveTool = require(script.Parent.Parent.tools.MoveTool)
local ResizeTool = require(script.Parent.Parent.tools.ResizeTool)
local RotateTool = require(script.Parent.Parent.tools.RotateTool)

local registry: { [Tool.ToolId]: Tool.Tool } = {
	[MoveTool.id] = MoveTool,
	[ResizeTool.id] = ResizeTool,
	[RotateTool.id] = RotateTool,
}

return registry
