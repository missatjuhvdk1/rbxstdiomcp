-- ============================================
-- VIEWPORT FRAME RENDERING SYSTEM
-- ============================================
-- This is the #1 priority feature to add visual capabilities to the MCP
-- Allows AI to "see" what it creates by rendering objects to images

local AssetService = game:GetService("AssetService")
local RunService = game:GetService("RunService")

-- ============================================
-- HELPER: Camera Angle Presets
-- ============================================

local CameraPresets = {
	-- Standard orthographic views
	front = CFrame.new(0, 0, 10) * CFrame.Angles(0, 0, 0),
	back = CFrame.new(0, 0, -10) * CFrame.Angles(0, math.pi, 0),
	left = CFrame.new(-10, 0, 0) * CFrame.Angles(0, math.pi/2, 0),
	right = CFrame.new(10, 0, 0) * CFrame.Angles(0, -math.pi/2, 0),
	top = CFrame.new(0, 10, 0) * CFrame.Angles(-math.pi/2, 0, 0),
	bottom = CFrame.new(0, -10, 0) * CFrame.Angles(math.pi/2, 0, 0),

	-- Isometric views (popular for thumbnails)
	iso = CFrame.new(7, 7, 7) * CFrame.Angles(-math.pi/6, math.pi/4, 0),
	iso_front = CFrame.new(5, 5, 10) * CFrame.Angles(-math.pi/6, 0, 0),
	iso_back = CFrame.new(-5, 5, -10) * CFrame.Angles(-math.pi/6, math.pi, 0),

	-- Dramatic angles
	low_angle = CFrame.new(0, -5, 10) * CFrame.Angles(math.pi/6, 0, 0),
	high_angle = CFrame.new(0, 15, 8) * CFrame.Angles(-math.pi/3, 0, 0),
}

-- ============================================
-- HELPER: Lighting Presets
-- ============================================

local function applyLightingPreset(worldModel, preset)
	-- Remove existing lighting
	for _, child in ipairs(worldModel:GetChildren()) do
		if child:IsA("Light") or child:IsA("Sky") or child:IsA("Atmosphere") then
			child:Destroy()
		end
	end

	if preset == "bright" or preset == "showcase" then
		-- Three-point lighting setup
		local keyLight = Instance.new("PointLight")
		keyLight.Brightness = 2
		keyLight.Range = 60
		keyLight.Color = Color3.fromRGB(255, 255, 255)
		keyLight.Parent = worldModel

		local fillLight = Instance.new("PointLight")
		fillLight.Brightness = 1
		fillLight.Range = 40
		fillLight.Color = Color3.fromRGB(200, 220, 255)
		fillLight.Parent = worldModel

		local rimLight = Instance.new("PointLight")
		rimLight.Brightness = 1.5
		rimLight.Range = 50
		rimLight.Color = Color3.fromRGB(255, 240, 200)
		rimLight.Parent = worldModel

	elseif preset == "studio" or preset == "flat" then
		-- Flat, even lighting like in Studio
		local ambientLight = Instance.new("PointLight")
		ambientLight.Brightness = 1
		ambientLight.Range = 100
		ambientLight.Color = Color3.fromRGB(255, 255, 255)
		ambientLight.Parent = worldModel

	elseif preset == "dark" or preset == "dramatic" then
		-- Single directional light
		local light = Instance.new("PointLight")
		light.Brightness = 1.5
		light.Range = 40
		light.Color = Color3.fromRGB(255, 200, 150)
		light.Parent = worldModel

	-- default: no lights added (ambient only)
	end
end

-- ============================================
-- HELPER: Calculate Bounding Box
-- ============================================

local function getModelBoundingBox(model)
	local parts = {}

	-- Collect all BaseParts
	local function collectParts(parent)
		for _, child in ipairs(parent:GetDescendants()) do
			if child:IsA("BasePart") then
				table.insert(parts, child)
			end
		end
	end
	collectParts(model)

	if #parts == 0 then
		return Vector3.new(1, 1, 1), Vector3.new(0, 0, 0)
	end

	-- Calculate bounding box
	local minPos = parts[1].Position - parts[1].Size/2
	local maxPos = parts[1].Position + parts[1].Size/2

	for _, part in ipairs(parts) do
		local partMin = part.Position - part.Size/2
		local partMax = part.Position + part.Size/2

		minPos = Vector3.new(
			math.min(minPos.X, partMin.X),
			math.min(minPos.Y, partMin.Y),
			math.min(minPos.Z, partMin.Z)
		)
		maxPos = Vector3.new(
			math.max(maxPos.X, partMax.X),
			math.max(maxPos.Y, partMax.Y),
			math.max(maxPos.Z, partMax.Z)
		)
	end

	local size = maxPos - minPos
	local center = (minPos + maxPos) / 2

	return size, center
end

-- ============================================
-- MAIN HANDLER: Render Object View
-- ============================================

handlers.renderObjectView = function(requestData)
	local success, result = pcall(function()
		-- Parse parameters
		local instancePath = requestData.instancePath
		if not instancePath then
			return {
				success = false,
				error = "instancePath is required"
			}
		end

		local resolution = requestData.resolution or {width = 512, height = 512}
		local width = resolution.width or 512
		local height = resolution.height or 512

		-- Clamp resolution for performance
		width = math.clamp(width, 64, 2048)
		height = math.clamp(height, 64, 2048)

		local anglePreset = requestData.angle or "iso"
		local lighting = requestData.lighting or "bright"
		local background = requestData.background or "transparent"
		local autoDistance = requestData.autoDistance ~= false -- default true

		-- Get the target instance
		local targetInstance = getInstanceByPath(instancePath)
		if not targetInstance then
			return {
				success = false,
				error = "Instance not found: " .. instancePath
			}
		end

		-- Create ViewportFrame in memory (no parent = no GUI overhead)
		local viewportFrame = Instance.new("ViewportFrame")
		viewportFrame.Size = UDim2.fromOffset(width, height)
		viewportFrame.BackgroundTransparency = background == "transparent" and 1 or 0
		viewportFrame.BackgroundColor3 = background == "grid" and Color3.fromRGB(128, 128, 128) or Color3.fromRGB(255, 255, 255)

		-- Create WorldModel for the viewport
		local worldModel = Instance.new("WorldModel")
		worldModel.Parent = viewportFrame
		viewportFrame.CurrentCamera = Instance.new("Camera", viewportFrame)

		-- Clone target into WorldModel
		local clonedInstance = targetInstance:Clone()
		clonedInstance.Parent = worldModel

		-- Calculate bounding box and center
		local boundingSize, boundingCenter = getModelBoundingBox(clonedInstance)
		local maxDimension = math.max(boundingSize.X, boundingSize.Y, boundingSize.Z)

		-- Position camera
		local cameraOffset
		if type(anglePreset) == "string" and CameraPresets[anglePreset] then
			cameraOffset = CameraPresets[anglePreset]
		elseif type(anglePreset) == "table" then
			-- Custom angle {pitch, yaw, roll} in degrees
			local pitch = math.rad(anglePreset.pitch or anglePreset[1] or 0)
			local yaw = math.rad(anglePreset.yaw or anglePreset[2] or 0)
			local roll = math.rad(anglePreset.roll or anglePreset[3] or 0)
			local distance = anglePreset.distance or 10
			cameraOffset = CFrame.new(0, 0, distance) * CFrame.Angles(pitch, yaw, roll)
		else
			cameraOffset = CameraPresets.iso
		end

		-- Auto-calculate distance to fit object in frame
		local cameraDistance = 10
		if autoDistance then
			-- FOV of 70 degrees, we want object to fill ~80% of frame
			local fov = 70
			cameraDistance = maxDimension / (2 * math.tan(math.rad(fov / 2))) * 1.3
		else
			if type(anglePreset) == "table" and anglePreset.distance then
				cameraDistance = anglePreset.distance
			end
		end

		-- Apply distance scaling to camera offset
		local offsetDirection = cameraOffset.Position.Unit
		local finalCameraPos = boundingCenter + (offsetDirection * cameraDistance)

		viewportFrame.CurrentCamera.CFrame = CFrame.new(finalCameraPos, boundingCenter) * cameraOffset.Rotation
		viewportFrame.CurrentCamera.FieldOfView = 70

		-- Apply lighting preset
		applyLightingPreset(worldModel, lighting)

		-- Add grid background if requested
		if background == "grid" then
			local gridPart = Instance.new("Part")
			gridPart.Size = Vector3.new(maxDimension * 5, 0.1, maxDimension * 5)
			gridPart.Position = boundingCenter - Vector3.new(0, boundingSize.Y/2 + 0.1, 0)
			gridPart.Anchored = true
			gridPart.Material = Enum.Material.SmoothPlastic
			gridPart.Color = Color3.fromRGB(200, 200, 200)
			gridPart.Parent = worldModel
		end

		-- Wait for viewport to render (important!)
		task.wait(0.1)
		RunService.Heartbeat:Wait()

		-- Capture to EditableImage
		local editableImage = AssetService:CreateEditableImage({
			Size = Vector2.new(width, height)
		})

		-- Read pixels from viewport
		local pixels = viewportFrame:CaptureSnapshotAsync()
		editableImage:WritePixels(Vector2.zero, pixels.Size, pixels:ReadPixels())

		-- Convert to RGBA buffer
		local pixelData = editableImage:ReadPixels(Vector2.zero, editableImage.Size)
		local rgbaBuffer = {}
		for y = 0, height - 1 do
			for x = 0, width - 1 do
				local i = (y * width + x) * 4
				table.insert(rgbaBuffer, string.char(
					pixelData[i + 1] or 0,   -- R
					pixelData[i + 2] or 0,   -- G
					pixelData[i + 3] or 0,   -- B
					pixelData[i + 4] or 255  -- A
				))
			end
		end

		local rgbaString = table.concat(rgbaBuffer)
		local base64 = base64encode(rgbaString)

		-- Cleanup
		viewportFrame:Destroy()

		return {
			success = true,
			base64 = base64,
			width = width,
			height = height,
			viewInfo = {
				objectName = targetInstance.Name,
				objectClass = targetInstance.ClassName,
				boundingBox = {
					size = {x = boundingSize.X, y = boundingSize.Y, z = boundingSize.Z},
					center = {x = boundingCenter.X, y = boundingCenter.Y, z = boundingCenter.Z}
				},
				camera = {
					distance = cameraDistance,
					position = {x = finalCameraPos.X, y = finalCameraPos.Y, z = finalCameraPos.Z}
				},
				settings = {
					angle = anglePreset,
					lighting = lighting,
					background = background,
					resolution = {width = width, height = height}
				}
			},
			message = "Rendered " .. targetInstance.Name .. " at " .. width .. "x" .. height
		}
	end)

	if success then
		return result
	else
		return {
			success = false,
			error = "Failed to render object: " .. tostring(result)
		}
	end
end

-- ============================================
-- BONUS: Multi-Angle Render
-- ============================================

handlers.renderMultiView = function(requestData)
	local instancePath = requestData.instancePath
	local angles = requestData.angles or {"front", "iso", "top"}
	local resolution = requestData.resolution or {width = 256, height = 256}
	local lighting = requestData.lighting or "bright"

	local results = {}

	for _, angle in ipairs(angles) do
		local renderResult = handlers.renderObjectView({
			instancePath = instancePath,
			angle = angle,
			resolution = resolution,
			lighting = lighting,
			background = requestData.background or "transparent",
			autoDistance = true
		})

		if renderResult.success then
			table.insert(results, {
				angle = angle,
				base64 = renderResult.base64,
				width = renderResult.width,
				height = renderResult.height
			})
		end
	end

	return {
		success = true,
		views = results,
		count = #results,
		message = "Rendered " .. #results .. " views of " .. instancePath
	}
end

-- ============================================
-- USAGE EXAMPLES
-- ============================================

--[[

1. Basic render:
renderObjectView({
	instancePath = "game.Workspace.Model1",
	angle = "iso",
	resolution = {width = 512, height = 512},
	lighting = "bright"
})

2. Custom angle:
renderObjectView({
	instancePath = "game.Workspace.Tool",
	angle = {pitch = 30, yaw = 45, distance = 8},
	lighting = "studio"
})

3. Multiple views at once:
renderMultiView({
	instancePath = "game.Workspace.Vehicle",
	angles = {"front", "back", "left", "right", "top", "iso"},
	resolution = {width = 256, height = 256}
})

4. With grid background:
renderObjectView({
	instancePath = "game.Workspace.Character",
	angle = "iso_front",
	background = "grid",
	lighting = "bright"
})

]]
