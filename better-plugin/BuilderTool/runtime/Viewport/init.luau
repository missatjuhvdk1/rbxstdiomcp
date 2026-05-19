--!strict
-- runtime/Viewport/init.luau
--
-- Facade over the viewport primitives. Tools orchestrate the viewport ONLY
-- through `ctx.viewport` — they never touch workspace/CoreGui/raycasting
-- directly (ARCHITECTURE §7).

local Raycaster    = require(script.Raycaster)
local Adornments   = require(script.Adornments)
local MoveGizmo    = require(script.MoveGizmo)
local ResizeGizmo  = require(script.ResizeGizmo)
local RotateGizmo  = require(script.RotateGizmo)
local Janitor      = require(script.Parent.Parent.Packages.Janitor)

export type Viewport = {
	raycaster:   Raycaster.Raycaster,
	adornments:  Adornments.Adornments,
	moveGizmo:   MoveGizmo.MoveGizmo,
	resizeGizmo: ResizeGizmo.ResizeGizmo,
	rotateGizmo: RotateGizmo.RotateGizmo,
}

local Viewport = {}

function Viewport.new(coreGui: CoreGui, sessionId: string, janitor: Janitor.Janitor, userInput: UserInputService): Viewport
	local adornments = Adornments.new(coreGui, sessionId, janitor)
	return {
		raycaster   = Raycaster.new(),
		adornments  = adornments,
		moveGizmo   = MoveGizmo.new(adornments.folder, janitor, userInput),
		resizeGizmo = ResizeGizmo.new(adornments.folder, janitor, userInput),
		rotateGizmo = RotateGizmo.new(adornments.folder, janitor, userInput),
	}
end

return Viewport
