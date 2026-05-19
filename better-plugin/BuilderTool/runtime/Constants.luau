--!strict
-- runtime/Constants.luau
--
-- Immutable values only. `table.freeze`d so a write is a hard error and
-- "this never changes at runtime" is enforced, not just documented (§5).

export type Constants = {
	SCHEMA_VERSION: number,
	GRID_DEFAULT: number,
	ROTATION_INCREMENT_DEFAULT: number,
	ADORNMENT_FOLDER_PREFIX: string,
}

local Constants = {}

function Constants.new(): Constants
	return table.freeze({
		SCHEMA_VERSION = 1,
		GRID_DEFAULT = 1,
		ROTATION_INCREMENT_DEFAULT = 45,
		ADORNMENT_FOLDER_PREFIX = "BuilderToolAdornments",
	})
end

return Constants
