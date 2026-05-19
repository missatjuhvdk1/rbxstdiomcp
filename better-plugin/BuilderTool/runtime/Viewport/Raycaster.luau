--!strict
-- runtime/Viewport/Raycaster.luau
--
-- Mouse → world raycasting (ARCHITECTURE §7). One reusable RaycastParams
-- object (NOT one per frame). Filters out the plugin's own adornment folder.

local RAY_LENGTH = 10000

export type Hit = {
	instance: BasePart,
	position: Vector3,
	normal: Vector3,
}

export type Raycaster = {
	-- screenPoint in pixels; nil if nothing selectable was hit.
	cast: (self: Raycaster, screenPoint: Vector2) -> Hit?,
	setIgnore: (self: Raycaster, ignore: { Instance }) -> (),
}

type Internal = Raycaster & {
	_params: RaycastParams,
}

local Raycaster = {}
Raycaster.__index = Raycaster

function Raycaster.new(): Raycaster
	-- One reusable params object. StudioSelectable matches Studio's own pick
	-- semantics (locked/hidden parts excluded the same way the editor does).
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.CollisionGroup = "StudioSelectable"
	params.IgnoreWater = true
	params.FilterDescendantsInstances = {}

	local self: Internal = setmetatable({
		_params = params,
	}, Raycaster) :: any

	return self
end

-- The adornment folder (and any tool-supplied extras) must never be hit.
function Raycaster.setIgnore(self: Internal, ignore: { Instance })
	self._params.FilterDescendantsInstances = ignore
end

function Raycaster.cast(self: Internal, screenPoint: Vector2): Hit?
	local camera = workspace.CurrentCamera
	if not camera then
		return nil
	end

	local ray = camera:ViewportPointToRay(screenPoint.X, screenPoint.Y)
	local result = workspace:Raycast(ray.Origin, ray.Direction * RAY_LENGTH, self._params)
	if result == nil then
		return nil
	end

	local instance = result.Instance
	if instance == nil or not instance:IsA("BasePart") then
		return nil
	end

	return {
		instance = instance,
		position = result.Position,
		normal = result.Normal,
	}
end

return Raycaster
