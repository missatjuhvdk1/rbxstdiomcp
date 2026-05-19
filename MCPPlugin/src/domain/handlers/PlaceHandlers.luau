--!strict
-- domain/handlers/PlaceHandlers.luau
--
-- Place-/Studio-environment read-only handlers. Five endpoints:
--   - getPlaceInfo   ← legacy plugin.luau L2214-2225
--   - getServices    ← legacy plugin.luau L2227-2274
--   - getSelection   ← legacy plugin.luau L4935-4964
--   - getOutput      ← legacy plugin.luau L4970-5036
--   - ping           ← diagnostic (replaces Phase 2's inline /api/ping)
--
-- ============================================================================
-- WHY THESE FIVE LIVE TOGETHER
-- ============================================================================
-- All five answer "tell me about the Studio environment surrounding the data
-- model" rather than the data model itself:
--   - getPlaceInfo / getServices : the place identity and its top-level
--     containers. The AI uses these to know "where am I" before touching
--     anything.
--   - getSelection               : what the user clicked in Studio. The AI
--     uses this to disambiguate "this part" in chat-style prompts.
--   - getOutput                  : what the user / a running script has been
--     printing. The AI uses this to debug previous turns.
--   - ping                       : sanity / version check. Surfaced by the
--     bridge so the user can confirm the plugin is loaded and on the
--     expected version.
--
-- They're grouped because none of them walks the user data model — they
-- read environment metadata. Keeping them out of the instance-walker
-- modules keeps the latter focused on "what is at <path>".
--
-- ============================================================================
-- WHY game:FindFirstChild AND NOT game:GetService FOR SERVICE LOOKUP
-- ============================================================================
-- ARCHITECTURE §4.3 / §15 A3: `game:GetService` is allowed only in
-- runtime/Services.luau. Every other file is mechanically rejected by the
-- golden-gate CI check. Service lookup here uses `game:FindFirstChild`
-- instead, which works for every container service that Studio loads at
-- startup (Workspace, Players, ServerScriptService, ReplicatedStorage,
-- StarterGui, …) — and these are precisely the services this handler
-- exposes. A service that wasn't instantiated wouldn't appear in
-- `game:GetChildren()`, but the COMMON_SERVICES list below is curated to
-- only contain services Studio always instantiates.
--
-- The user-arg `serviceName` path also uses FindFirstChild, which means
-- it cannot look up services that have never been GetService()'d. In
-- practice every meaningful service in a running Studio session has
-- already been instantiated by the time the MCP host queries it; if a
-- caller really wants a never-touched service they should add it to
-- runtime/Services.luau (the proper home for the quarantine).
--
-- This pattern is identical to FileTreeHandlers.getProjectStructure's
-- service-overview code path — keeping the two consistent means a future
-- reader sees one idiom, not two.

local Handler = require(script.Parent.Parent.handler.Handler)
local Path = require(script.Parent.Parent.Parent.runtime.instance.Path)

-- ============================================================================
-- TYPED REQUEST/RESPONSE SHAPES
-- ============================================================================

type GetServicesRequest = {
	serviceName: string?,
}

type GetOutputRequest = {
	limit: number?,
	since: number?,
	messageTypes: { string }?,
	clear: boolean?,
}

-- The commonly-queried Studio services. Verbatim from legacy L2247-2258 so
-- existing MCP prompts that branch on this set keep working. Curated to
-- contain ONLY services Studio always instantiates so `game:FindFirstChild`
-- is sufficient (see module header).
local COMMON_SERVICES = {
	"Workspace",
	"Players",
	"StarterGui",
	"StarterPack",
	"StarterPlayer",
	"ReplicatedStorage",
	"ServerStorage",
	"ServerScriptService",
	"HttpService",
	"TeleportService",
	"DataStoreService",
}

-- ============================================================================
-- HANDLERS
-- ============================================================================

local PlaceHandlers = {}

-- getPlaceInfo: identity + workspace summary. Legacy L2214-2225.
-- Pure read; touches only `game` top-level properties + `workspace`.
PlaceHandlers.getPlaceInfo = Handler.define("/api/place-info", function(_ctx, _data: any): (any, Handler.RecordResult?)
	return {
		placeName = game.Name,
		placeId = game.PlaceId,
		gameId = game.GameId,
		jobId = game.JobId,
		workspace = {
			name = workspace.Name,
			className = workspace.ClassName,
		},
	},
		nil
end)

-- getServices: filtered or full common-service list. Legacy L2227-2274.
-- If `serviceName` is supplied, return a single-service detail; otherwise
-- return the full COMMON_SERVICES list (skipping any that aren't loaded).
PlaceHandlers.getServices = Handler.define(
	"/api/services",
	function(_ctx, data: GetServicesRequest): (any, Handler.RecordResult?)
		local serviceName = data.serviceName

		if serviceName ~= nil then
			local service = game:FindFirstChild(serviceName)
			if service ~= nil then
				return {
					service = {
						name = service.Name,
						className = service.ClassName,
						path = Path.getInstancePath(service),
						childCount = #service:GetChildren(),
					},
				},
					nil
			else
				return { error = "Service not found: " .. serviceName }, nil
			end
		end

		local services: { any } = {}
		for _, name in COMMON_SERVICES do
			local service = game:FindFirstChild(name)
			if service ~= nil then
				table.insert(services, {
					name = service.Name,
					className = service.ClassName,
					path = Path.getInstancePath(service),
					childCount = #service:GetChildren(),
				})
			end
		end

		return { services = services }, nil
	end
)

-- getSelection: what the user has selected in Studio. Legacy L4935-4964.
-- Goes through the quarantined Selection service (ctx.services.selectionService)
-- rather than reaching for Selection directly.
PlaceHandlers.getSelection = Handler.define(
	"/api/get-selection",
	function(ctx, _data: any): (any, Handler.RecordResult?)
		local selection = ctx.services.selectionService:Get()

		if #selection == 0 then
			return {
				success = true,
				selection = {},
				count = 0,
				message = "No objects selected",
			},
				nil
		end

		local selectedObjects: { any } = {}
		for _, instance in selection do
			table.insert(selectedObjects, {
				name = instance.Name,
				className = instance.ClassName,
				path = Path.getInstancePath(instance),
				parent = instance.Parent ~= nil and Path.getInstancePath(instance.Parent) or nil,
			})
		end

		return {
			success = true,
			selection = selectedObjects,
			count = #selection,
			message = #selection .. " object(s) selected",
		},
			nil
	end
)

-- getOutput: drain the Logger ring buffer, optionally supplement with
-- LogService:GetLogHistory(). Legacy L4970-5036.
-- ----------------------------------------------------------------------------
-- The dual-source merge is preserved bit-identical: buffer first, then
-- historical log entries that aren't already represented (dedup by message
-- text). Filtering by timestamp / messageTypes / limit is applied uniformly
-- to both sources. The `clear` arg drops the Logger buffer after reading,
-- mirroring legacy behaviour exactly.
PlaceHandlers.getOutput = Handler.define(
	"/api/get-output",
	function(ctx, data: GetOutputRequest): (any, Handler.RecordResult?)
		local limit = data.limit or 100
		local since = data.since
		local messageTypes = data.messageTypes
		local clear = data.clear == true

		-- Drain our in-memory buffer first. The Logger already keeps a flat
		-- list; we just snapshot a slice from the tail (most recent `limit`
		-- entries) and apply the request filters.
		local bufferEntries = ctx.logger:getEntries()
		local combined: { any } = {}
		local startIdx = math.max(1, #bufferEntries - limit + 1)
		for i = startIdx, #bufferEntries do
			local entry = bufferEntries[i]
			if entry ~= nil then
				local passesSince = since == nil or entry.timestamp >= since
				local passesType = messageTypes == nil or table.find(messageTypes, entry.messageType) ~= nil
				if passesSince and passesType then
					table.insert(combined, entry)
				end
			end
		end

		-- Supplement with LogService history if our buffer is under quota.
		-- pcall'd because GetLogHistory can throw on certain Studio internal
		-- states (during a long blocking script load, for example).
		if #combined < limit then
			local ok, history = pcall(function()
				return ctx.services.logService:GetLogHistory()
			end)
			if ok and history ~= nil then
				for _, logEntry in history do
					if #combined >= limit then
						break
					end
					local entry = {
						message = logEntry.message,
						messageType = tostring(logEntry.messageType),
						timestamp = logEntry.timestamp or 0,
					}
					-- Dedup by message text. The legacy code did this with a
					-- linear scan; we preserve that exactly (O(n^2) on the
					-- merged set, but `limit` defaults to 100 so worst case
					-- is 10k comparisons — well below per-request budget).
					local isDuplicate = false
					for _, existing in combined do
						if existing.message == entry.message then
							isDuplicate = true
							break
						end
					end
					if not isDuplicate then
						local passesSince = since == nil or entry.timestamp >= since
						local passesType = messageTypes == nil or table.find(messageTypes, entry.messageType) ~= nil
						if passesSince and passesType then
							table.insert(combined, entry)
						end
					end
				end
			end
		end

		-- Optional buffer reset. Done AFTER reading so the same call that
		-- drains the buffer also empties it — matches legacy semantics so
		-- existing MCP prompts ("read & clear") continue to work.
		if clear then
			ctx.logger:clear()
		end

		return {
			success = true,
			output = combined,
			count = #combined,
			bufferSize = ctx.logger:count(),
			timestamp = os.time(),
		},
			nil
	end
)

-- ping: diagnostic sanity payload. Replaces Phase 2's inline /api/ping
-- closure in app/Plugin.client.luau so the bootstrap can route ALL
-- endpoints through the Dispatcher uniformly. The TS bridge surfaces this
-- via its own `ping` MCP tool; users invoke it to confirm
--   (a) the plugin process is alive, and
--   (b) which version is running (catches "did my Rojo sync land?" mistakes).
PlaceHandlers.ping = Handler.define("/api/ping", function(ctx, _data: any): (any, Handler.RecordResult?)
	return {
		ok = true,
		version = ctx.constants.PLUGIN_VERSION,
		timestamp = os.time(),
	}, nil
end)

return PlaceHandlers
