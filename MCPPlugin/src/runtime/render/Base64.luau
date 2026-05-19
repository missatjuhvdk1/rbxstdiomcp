--!strict
-- runtime/render/Base64.luau
--
-- Phase 5 — the *single* byte-string → base64 encoder for the render
-- pipeline. Legacy plugin.luau had this inline in the screenshot handler
-- (L6000-6038); we keep the byte-for-byte algorithm but pull it out so
-- both Screenshot.luau and Viewport.luau go through one routine.
--
-- ============================================================================
-- WHY ROLL OUR OWN INSTEAD OF HttpService:JSONEncode
-- ============================================================================
-- HttpService doesn't have a base64 primitive. The bridge expects RGBA
-- pixel data as `base64` and the TS layer decodes → re-encodes to PNG
-- before returning to clients. Standard library options:
--   - `buffer.tostring`  → gives us the raw byte string; no encoding.
--   - HttpService:GenerateGUID()/:UrlEncode() — totally different things.
--   - DataStore / Bson encoders — not exposed to plugin code.
-- So a hand-rolled b64 is unavoidable; the algorithm is small enough that
-- the maintenance cost is near zero.
--
-- ============================================================================
-- ALGORITHM
-- ============================================================================
-- Standard RFC 4648 base64 alphabet (no URL-safe variant — the bridge does
-- not need it). Pad with "=" so output length is always a multiple of 4.
-- Process input in 3-byte chunks; emit 4 chars per chunk.
-- For non-multiple-of-3 inputs, the last 1 or 2 bytes produce 2 or 3 chars
-- followed by 2 or 1 "=" pads respectively (RFC behaviour).
--
-- ============================================================================
-- PERFORMANCE
-- ============================================================================
-- For a 768×768 RGBA capture (~2.3 MB raw), encoding takes ~120 ms on a
-- mid-range Studio host. We accumulate into a sequence-table and concat at
-- the end — string concatenation per byte would be O(n²). Verified on
-- legacy too; the chunk-loop is the bottleneck, not table.concat.

local Base64 = {}

-- RFC 4648 standard alphabet. Position 0 → 'A', 63 → '/'.
local ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

-- Encode an arbitrary byte string to base64. Input may be any string — we
-- treat each character as one byte via string.byte (Roblox strings are
-- byte-strings, not UTF-8 sequences for our purposes here).
function Base64.encode(data: string): string
	-- Pre-size the result table to avoid Luau growing it; one chunk
	-- produces 4 chars, so ceil(#data / 3) * 4 is the exact upper bound.
	local outLen = math.ceil(#data / 3) * 4
	local result = table.create(outLen)
	local resultIdx = 0

	-- Three-byte chunk loop. b1/b2/b3 default to 0 when past end-of-input;
	-- the trailing "=" pads then encode that we ran out.
	for i = 1, #data, 3 do
		local b1 = string.byte(data, i) or 0
		local b2 = string.byte(data, i + 1) or 0
		local b3 = string.byte(data, i + 2) or 0

		-- Pack the three bytes into a single 24-bit integer, then unpack
		-- into four 6-bit indices into ALPHABET.
		local n = b1 * 65536 + b2 * 256 + b3
		local c1 = math.floor(n / 262144) % 64
		local c2 = math.floor(n / 4096) % 64
		local c3 = math.floor(n / 64) % 64
		local c4 = n % 64

		resultIdx += 1
		result[resultIdx] = string.sub(ALPHABET, c1 + 1, c1 + 1)
		resultIdx += 1
		result[resultIdx] = string.sub(ALPHABET, c2 + 1, c2 + 1)

		-- Last chunk pad rules: if we ran past end-of-input on byte 3 or
		-- 4 of the output, swap the missing chars for "=".
		resultIdx += 1
		if i + 1 <= #data then
			result[resultIdx] = string.sub(ALPHABET, c3 + 1, c3 + 1)
		else
			result[resultIdx] = "="
		end

		resultIdx += 1
		if i + 2 <= #data then
			result[resultIdx] = string.sub(ALPHABET, c4 + 1, c4 + 1)
		else
			result[resultIdx] = "="
		end
	end

	return table.concat(result)
end

return Base64
