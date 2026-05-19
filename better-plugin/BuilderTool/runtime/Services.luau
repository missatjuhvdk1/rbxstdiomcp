--!strict
-- runtime/Services.luau
--
-- The ONLY place `game:GetService` may appear (ARCHITECTURE §4.3).
-- Everywhere else receives services through the typed Context. The Studio
-- *settings* object (which carries the editor Theme — that lives on the
-- `Studio` settings service, NOT on StudioService) is quarantined here too,
-- so the `settings()` global has exactly one call site, same as §4.3's intent.

export type Services = {
	changeHistory: ChangeHistoryService,
	userInput: UserInputService,
	selection: Selection,
	studio: StudioService,
	studioSettings: Studio,
	run: RunService,
	coreGui: CoreGui,
}

local Services = {}

function Services.new(): Services
	return {
		changeHistory = game:GetService("ChangeHistoryService"),
		userInput = game:GetService("UserInputService"),
		selection = game:GetService("Selection"),
		studio = game:GetService("StudioService"),
		studioSettings = settings():GetService("Studio"),
		run = game:GetService("RunService"),
		coreGui = game:GetService("CoreGui"),
	}
end

return Services
