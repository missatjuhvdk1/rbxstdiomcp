--!strict
-- runtime/render/Screenshot.luau
--
-- Phase 5 — full-screen capture pipeline. Legacy plugin.luau L6046-6228.
--
-- ============================================================================
-- PIPELINE OVERVIEW
-- ============================================================================
--   1. CaptureService:CaptureScreenshot(callback) → asynchronous, hands back
--      a `rbxtemp://` content id when the next-frame screenshot is ready.
--   2. AssetService:CreateEditableImageAsync(Content.fromUri(id)) loads the
--      capture into an EditableImage so we can read pixels.
--   3. If caller wants a smaller image (or the raw RGBA exceeds our HTTP
--      bridge cap), build a second EditableImage at the target size and
--      DrawImageTransformed the source into it.
--   4. ReadPixelsBuffer → RGBA byte string → Base64.encode → return.
--
-- ============================================================================
-- WHY THE BindableEvent HANDSHAKE
-- ============================================================================
-- CaptureScreenshot takes a callback and returns immediately; the screenshot
-- arrives on a later frame. We need the *handler* to block until the
-- screenshot is ready (so it can respond on the same HTTP request), but we
-- don't have a Future API. A BindableEvent gives us a yield-and-wake
-- primitive that lives entirely inside this function — no global signal,
-- no leaked connection. We hard-arm a 5-second timeout on a separate task
-- so a stuck screenshot doesn't wedge the polling loop forever.
--
-- ============================================================================
-- AUTO-SHRINK
-- ============================================================================
-- Raw RGBA is 4 bytes/pixel. At 2048×2048 that's 16 MB before base64 (~21 MB
-- after). The bridge accepts up to MAX_RAW_PIXEL_BYTES; beyond that, requests
-- get rejected by Roblox's HTTP body limit before they reach us. We compute
-- a uniform shrink factor (sqrt of the cap ratio) and tag the result with
-- `autoShrunk = true` so the caller can decide whether to re-request at
-- the auto-shrunk size next time.
--
-- ============================================================================
-- LEGACY PARITY
-- ============================================================================
-- Default maxWidth/maxHeight = 768. The legacy comment said this avoids "a
-- CaptureService bug with <600 px". Modern Studio fixed that bug, but
-- 768×768 is also a sensible default for vision-LLM inputs, so we keep it
-- as the published default to avoid changing observable behaviour.

local Base64 = require(script.Parent.Base64)

local Screenshot = {}

-- 16 MB raw → ~21.3 MB base64 → well within localhost HTTP body limits.
-- At 4 bytes/pixel this is 4 194 304 pixels (≈ 2048×2048). Bumping this
-- requires verifying both the local HTTP bridge body cap AND Studio's
-- RequestAsync outbound cap; do not raise blind.
local MAX_RAW_PIXEL_BYTES = 16 * 1024 * 1024

-- Wait timeout (seconds) for the screenshot callback. The legacy used 5;
-- empirically CaptureScreenshot resolves in <100 ms in normal Studio sessions.
-- A 5-second timeout means a stuck capture doesn't wedge the polling loop
-- for more than one request cycle.
local CAPTURE_TIMEOUT_SECONDS = 5

export type CaptureRequest = {
	maxWidth: number?,
	maxHeight: number?,
	returnBase64: boolean?,
}

export type CaptureResult = {
	success: boolean,
	originalWidth: number?,
	originalHeight: number?,
	width: number?,
	height: number?,
	contentId: string?,
	base64: string?,
	format: string?,
	encoding: string?,
	pixelDataSize: number?,
	autoShrunk: boolean?,
	message: string?,
	error: string?,
}

export type Deps = {
	captureService: any,
	assetService: AssetService,
}

-- ============================================================================
-- INTERNAL HELPERS
-- ============================================================================

-- Trigger CaptureScreenshot and yield until the callback fires (or timeout).
-- Returns (contentId, nil) on success or (nil, errorString) on failure.
local function captureAndAwait(captureService: any): (string?, string?)
	local complete = Instance.new("BindableEvent")
	local contentId: string? = nil
	local errStr: string? = nil

	local startOk, startErr = pcall(function()
		captureService:CaptureScreenshot(function(id)
			if id ~= nil then
				contentId = tostring(id)
			else
				errStr = "CaptureScreenshot returned nil"
			end
			complete:Fire()
		end)
	end)

	if not startOk then
		complete:Destroy()
		return nil, "Failed to call CaptureScreenshot: " .. tostring(startErr)
	end

	-- Watchdog: if the callback never fires, wake up on our own.
	local timeoutThread = task.delay(CAPTURE_TIMEOUT_SECONDS, function()
		if contentId == nil and errStr == nil then
			errStr = string.format("Capture timed out after %d seconds", CAPTURE_TIMEOUT_SECONDS)
			complete:Fire()
		end
	end)

	complete.Event:Wait()
	task.cancel(timeoutThread)
	complete:Destroy()

	return contentId, errStr
end

-- ============================================================================
-- ENTRY POINT
-- ============================================================================

-- Capture the current Studio viewport and return base64 RGBA.
-- Returns a CaptureResult; never throws (all paths return a structured
-- result table with success=false on any failure).
function Screenshot.capture(deps: Deps, params: CaptureRequest): CaptureResult
	local maxWidth = tonumber(params.maxWidth) or 768
	local maxHeight = tonumber(params.maxHeight) or 768
	local returnBase64 = params.returnBase64 ~= false -- default true

	local contentId, captureErr = captureAndAwait(deps.captureService)
	if contentId == nil then
		return {
			success = false,
			error = captureErr or "Unknown capture failure",
		}
	end

	-- Load the captured frame into an EditableImage so we can resize/read.
	local editOk, sourceImage = pcall(function()
		return deps.assetService:CreateEditableImageAsync(Content.fromUri(contentId :: string))
	end)
	if not editOk or sourceImage == nil then
		return {
			success = false,
			error = "Failed to load capture into EditableImage: " .. tostring(sourceImage),
			contentId = contentId,
		}
	end

	local originalSize = sourceImage.Size
	local result: CaptureResult = {
		success = true,
		originalWidth = originalSize.X,
		originalHeight = originalSize.Y,
		contentId = contentId,
		message = "Screenshot captured successfully",
	}

	if not returnBase64 then
		sourceImage:Destroy()
		return result
	end

	-- Compute target size honouring caller's bounds without upscaling.
	local scaleX = maxWidth / originalSize.X
	local scaleY = maxHeight / originalSize.Y
	local scale = math.min(scaleX, scaleY, 1)
	local targetWidth = math.max(1, math.floor(originalSize.X * scale))
	local targetHeight = math.max(1, math.floor(originalSize.Y * scale))

	-- Auto-shrink if raw pixel data would exceed our HTTP bridge cap.
	local requiredBytes = targetWidth * targetHeight * 4
	local autoShrunk = false
	if requiredBytes > MAX_RAW_PIXEL_BYTES then
		local shrink = math.sqrt(MAX_RAW_PIXEL_BYTES / requiredBytes)
		targetWidth = math.max(1, math.floor(targetWidth * shrink))
		targetHeight = math.max(1, math.floor(targetHeight * shrink))
		autoShrunk = true
	end

	-- Build final image — re-use source if no resize needed.
	local resized: any
	local needsResize = (targetWidth ~= originalSize.X) or (targetHeight ~= originalSize.Y)
	if needsResize then
		local allocOk, allocated = pcall(function()
			return deps.assetService:CreateEditableImage({
				Size = Vector2.new(targetWidth, targetHeight),
			})
		end)
		if not allocOk or allocated == nil then
			sourceImage:Destroy()
			return {
				success = false,
				error = "Failed to allocate resized EditableImage: " .. tostring(allocated),
				contentId = contentId,
			}
		end
		resized = allocated

		local sx = targetWidth / originalSize.X
		local sy = targetHeight / originalSize.Y
		local drawOk, drawErr = pcall(function()
			-- DrawImageTransformed maps source PivotPoint (default = source
			-- center) to the destination `position`. Center-place the scaled
			-- source so it fills the destination exactly.
			resized:DrawImageTransformed(
				Vector2.new(targetWidth / 2, targetHeight / 2),
				Vector2.new(sx, sy),
				0,
				sourceImage,
				{ CombineType = Enum.ImageCombineType.Overwrite }
			)
		end)
		if not drawOk then
			sourceImage:Destroy()
			resized:Destroy()
			return {
				success = false,
				error = "Failed to resize image: " .. tostring(drawErr),
				contentId = contentId,
			}
		end
	else
		resized = sourceImage
	end

	-- Read the pixel buffer and encode.
	local readOk, pixelBuffer = pcall(function()
		return resized:ReadPixelsBuffer(Vector2.new(0, 0), Vector2.new(targetWidth, targetHeight))
	end)
	local pixelString: string? = nil
	if readOk and pixelBuffer ~= nil then
		pixelString = buffer.tostring(pixelBuffer)
	end

	local expectedBytes = targetWidth * targetHeight * 4
	if pixelString ~= nil and #(pixelString :: string) == expectedBytes then
		local bytes = pixelString :: string
		result.base64 = Base64.encode(bytes)
		result.width = targetWidth
		result.height = targetHeight
		result.format = "RGBA"
		result.encoding = "base64"
		result.pixelDataSize = #bytes
		if autoShrunk then
			result.autoShrunk = true
			result.message = string.format(
				"Screenshot captured. Auto-shrunk from requested %dx%d to %dx%d to stay under HTTP bridge limit.",
				math.floor(originalSize.X * scale),
				math.floor(originalSize.Y * scale),
				targetWidth,
				targetHeight
			)
		end
	else
		result.success = false
		result.error = "Failed to read pixel buffer (got "
			.. tostring(pixelString and #(pixelString :: string) or "nil")
			.. " bytes, expected "
			.. tostring(expectedBytes)
			.. ")"
		result.width = targetWidth
		result.height = targetHeight
	end

	if resized ~= sourceImage then
		resized:Destroy()
	end
	sourceImage:Destroy()

	return result
end

return Screenshot
