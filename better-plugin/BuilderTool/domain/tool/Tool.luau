--!strict
-- domain/tool/Tool.luau
--
-- THE Tool contract (ARCHITECTURE §6.1). Every tool is a self-contained
-- module returning a value satisfying this type. One tool active at a time;
-- the ToolHost owns equip/unequip and input routing. Tools are declarative
-- about UI: they expose an `options` descriptor and NEVER build GUI.

local Janitor = require(script.Parent.Parent.Parent.Packages.Janitor)

local Services = require(script.Parent.Parent.Parent.runtime.Services)
local PluginHandles = require(script.Parent.Parent.Parent.runtime.PluginHandles)
local Constants = require(script.Parent.Parent.Parent.runtime.Constants)
local Settings = require(script.Parent.Parent.Parent.runtime.Settings)
local Input = require(script.Parent.Parent.Parent.runtime.Input)
local History = require(script.Parent.Parent.Parent.runtime.History)
local Selection = require(script.Parent.Parent.Selection)
local Viewport = require(script.Parent.Parent.Parent.runtime.Viewport)

-- Structural view of the tool host as seen by a tool. Tools never call back
-- into the host, but the field must be present so Context is complete.
type ToolHostRef = {
	equip: (self: ToolHostRef, id: string) -> (),
	unequipActive: (self: ToolHostRef) -> (),
	getActive: (self: ToolHostRef) -> any,
	changed: RBXScriptSignal,
}

export type Context = {
	services: Services.Services,
	plugin: PluginHandles.Handles,
	constants: Constants.Constants,
	settings: Settings.Settings,
	input: Input.Input,
	history: History.History,
	selection: Selection.Selection,
	viewport: Viewport.Viewport,
	tools: ToolHostRef,
	janitor: Janitor.Janitor,
}

-- Stable, lowercase, NEVER renamed once shipped (it is a persisted key).
export type ToolId = string

-- Declarative options the UI renders into the tool's panel. The tool never
-- constructs the panel itself.
export type ToolOption =
	{ kind: "toggle", key: string, label: string, default: boolean }
	| { kind: "number", key: string, label: string, default: number, min: number?, max: number?, step: number? }
	| { kind: "enum", key: string, label: string, choices: { string }, default: string }

export type ToolOptions = { ToolOption }

export type Tool = {
	id: ToolId,
	name: string,
	icon: string, -- rbxassetid sourced from assets/, never an inline magic number
	order: number,

	-- Mandatory, and MUST be exact mirrors: everything equip() creates or
	-- connects, unequip() destroys or disconnects.
	equip: (self: Tool, ctx: Context) -> (),
	unequip: (self: Tool, ctx: Context) -> (),

	-- Input handlers. Return true iff the event was consumed.
	onInputBegan: ((self: Tool, ctx: Context, input: InputObject) -> boolean)?,
	onInputChanged: ((self: Tool, ctx: Context, input: InputObject) -> boolean)?,
	onInputEnded: ((self: Tool, ctx: Context, input: InputObject) -> boolean)?,

	onSelectionChanged: ((self: Tool, ctx: Context) -> ())?,

	options: ToolOptions?,
}

return nil
