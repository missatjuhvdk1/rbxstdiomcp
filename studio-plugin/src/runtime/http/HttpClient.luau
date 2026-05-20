--!strict
-- runtime/http/HttpClient.luau
--
-- One typed wrapper around HttpService:RequestAsync. The polling loop and
-- (eventually) every handler that talks to the bridge goes through this
-- module. The legacy plugin.luau had FIVE distinct call sites that each
-- wrote out `HttpService:RequestAsync({ Url=..., Method=..., Headers=... })`
-- with slightly different error handling (L1786, L1917, L6948, plus the
-- companion script's L145 and L324). The first round of bugs in v2.0 was
-- a divergence between those copies. One wrapper → one error model.
--
-- DESIGN POINTS
--
-- 1. We return a tagged Result, not (success, body). The legacy form encoded
--    failure as either `pcall == false` OR `result.Success == false` OR
--    `result.StatusCode >= 400` — three orthogonal failure shapes that
--    every handler had to remember to check. Here, `Result` is a discriminated
--    union: `{ ok: true, ... }` or `{ ok: false, ... }`. Luau's type narrowing
--    flows through the field and stops the caller from forgetting a branch.
--
-- 2. 503 is treated as a SOFT failure that still carries a body. The
--    bridge replies 503 with a JSON `{ mcpConnected = false }` payload when
--    the MCP side is briefly offline (legacy L1796 special-case). We surface
--    that as `ok = true` with a flag in `softUnavailable`, so the polling
--    loop can paint the right UI without a parse-failure branch.
--
-- 3. JSON encode/decode wraps HttpService:JSONEncode and HttpService:JSONDecode
--    in pcall and returns a typed `(ok, valueOrErr)` tuple. Decode on bridge
--    responses is the #1 failure mode when the bridge crashes mid-write and
--    a half-buffer arrives — we want to log that, not crash the polling
--    coroutine.
--
-- 4. Retry/backoff state is OWNED BY THE POLLING LOOP, not by this module.
--    HttpClient is stateless except for the cached HttpService reference.
--    That keeps the wrapper testable (no hidden state across calls) and
--    means a future handler that does a one-off request doesn't accidentally
--    inherit the polling loop's backoff timer.

export type Method = "GET" | "POST" | "PUT" | "PATCH" | "DELETE"

export type Headers = { [string]: string }

export type RequestOptions = {
	url: string,
	method: Method,
	headers: Headers?,
	body: string?,
}

-- Tagged result. Always check `ok` first; Luau narrows to the right shape.
export type Result = {
	ok: true,
	statusCode: number,
	statusMessage: string,
	body: string,
	-- True when status was 503 and the bridge sent a payload anyway.
	-- The polling loop uses this to detect "bridge OK, MCP backend not
	-- ready yet" without conflating it with a true error.
	softUnavailable: boolean,
} | {
	ok: false,
	-- Why the request failed. Falls into one of:
	--   "network"   — pcall failed (DNS, refused connection, etc.)
	--   "http"      — request succeeded but statusCode >= 400 (and not 503)
	--   "timeout"   — Roblox surfaced a timeout-shaped error
	statusCode: number?, -- present iff kind == "http"
	message: string,
}

export type HttpClient = {
	request: (self: HttpClient, opts: RequestOptions) -> Result,
	-- Convenience for POSTing JSON with the correct Content-Type. Body is
	-- the LUA table to encode; encoding failure becomes an `ok=false` Result.
	postJson: (self: HttpClient, url: string, body: any) -> Result,
	-- GET with no body / no extra headers (the polling loop's bread and
	-- butter). Returns the same tagged Result.
	get: (self: HttpClient, url: string) -> Result,
	-- Decode the body of a successful Result. Returns (ok, valueOrErr).
	decodeJson: (self: HttpClient, body: string) -> (boolean, any),
}

type Internal = HttpClient & {
	_http: HttpService,
}

local HttpClient = {}
HttpClient.__index = HttpClient

function HttpClient.new(httpService: HttpService): HttpClient
	local self: Internal = setmetatable({
		_http = httpService,
	}, HttpClient) :: any
	return self
end

-- Classify a pcall error string so the caller can do something useful.
-- Roblox's RequestAsync doesn't expose a structured error code; we pattern-
-- match the legacy messages. Conservative: if we don't recognise it, call
-- it "network" — we still surface the message verbatim so the user can see
-- what Roblox said.
local function classifyError(msg: string): "network" | "timeout"
	local lower = msg:lower()
	if lower:find("timed out") or lower:find("timeout") then
		return "timeout"
	end
	return "network"
end

function HttpClient.request(self: Internal, opts: RequestOptions): Result
	local payload: { [string]: any } = {
		Url = opts.url,
		Method = opts.method,
	}
	if opts.headers then
		payload.Headers = opts.headers
	end
	if opts.body ~= nil then
		payload.Body = opts.body
	end

	local ok, response = pcall(function()
		return self._http:RequestAsync(payload)
	end)

	if not ok then
		local msg = tostring(response)
		return {
			ok = false,
			message = msg,
			statusCode = nil,
		} :: Result
	end

	local status = response.StatusCode :: number
	local statusMsg = response.StatusMessage :: string
	local body = response.Body :: string
	local success = response.Success :: boolean

	-- 503 carries a body and means "bridge is up but MCP isn't" — soft.
	if status == 503 then
		return {
			ok = true,
			statusCode = status,
			statusMessage = statusMsg,
			body = body,
			softUnavailable = true,
		}
	end

	if not success then
		return {
			ok = false,
			statusCode = status,
			message = string.format("HTTP %d %s", status, statusMsg),
		}
	end

	return {
		ok = true,
		statusCode = status,
		statusMessage = statusMsg,
		body = body,
		softUnavailable = false,
	}
end

function HttpClient.postJson(self: Internal, url: string, body: any): Result
	local encodeOk, encoded = pcall(function()
		return self._http:JSONEncode(body)
	end)
	if not encodeOk then
		return {
			ok = false,
			message = "JSON encode failed: " .. tostring(encoded),
			statusCode = nil,
		} :: Result
	end

	return HttpClient.request(self, {
		url = url,
		method = "POST",
		headers = { ["Content-Type"] = "application/json" },
		body = encoded :: string,
	})
end

function HttpClient.get(self: Internal, url: string): Result
	return HttpClient.request(self, {
		url = url,
		method = "GET",
		headers = { ["Content-Type"] = "application/json" },
	})
end

function HttpClient.decodeJson(self: Internal, body: string): (boolean, any)
	local ok, value = pcall(function()
		return self._http:JSONDecode(body)
	end)
	if not ok then
		return false, tostring(value)
	end
	return true, value
end

-- classifyError isn't currently consumed by the public API, but the polling
-- loop will use it via a downstream extension; expose for the test suite.
-- Storing it on the module table (not the instance) keeps it stateless.
(HttpClient :: any).classifyError = classifyError

return HttpClient
