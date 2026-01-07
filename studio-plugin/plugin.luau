local HttpService = game:GetService("HttpService")
local StudioService = game:GetService("StudioService")
local Selection = game:GetService("Selection")
local RunService = game:GetService("RunService")
local ChangeHistoryService = game:GetService("ChangeHistoryService")
local ScriptEditorService = game:GetService("ScriptEditorService")
local CollectionService = game:GetService("CollectionService")
local LogService = game:GetService("LogService")

-- StudioTestService for play/stop control (may not be available in all contexts)
local StudioTestService = nil
pcall(function()
	StudioTestService = game:GetService("TestService")
end)

-- Track output log for get_output
local outputBuffer = {}
local MAX_OUTPUT_BUFFER = 1000

-- Track action history for enhanced undo/redo
local actionHistory = {}  -- Stack of actions that can be undone
local redoHistory = {}    -- Stack of actions that can be redone
local MAX_ACTION_HISTORY = 100

-- Helper to serialize values nicely for logging
local function serializeValue(value)
	local t = typeof(value)
	if t == "Vector3" then
		return string.format("Vector3(%.2f, %.2f, %.2f)", value.X, value.Y, value.Z)
	elseif t == "Vector2" then
		return string.format("Vector2(%.2f, %.2f)", value.X, value.Y)
	elseif t == "Color3" then
		return string.format("Color3(%.2f, %.2f, %.2f)", value.R, value.G, value.B)
	elseif t == "BrickColor" then
		return "BrickColor(" .. value.Name .. ")"
	elseif t == "UDim2" then
		return string.format("UDim2(%.2f, %d, %.2f, %d)", value.X.Scale, value.X.Offset, value.Y.Scale, value.Y.Offset)
	elseif t == "UDim" then
		return string.format("UDim(%.2f, %d)", value.Scale, value.Offset)
	elseif t == "CFrame" then
		return string.format("CFrame(%.1f, %.1f, %.1f)", value.X, value.Y, value.Z)
	elseif t == "table" then
		if #value > 0 then
			local parts = {}
			for i, v in ipairs(value) do
				if i > 3 then table.insert(parts, "...") break end
				table.insert(parts, serializeValue(v))
			end
			return "{" .. table.concat(parts, ", ") .. "}"
		end
		return "{...}"
	else
		return tostring(value)
	end
end

-- Helper to log an action for undo tracking
local function logAction(actionType, target, summary, details)
	-- Clear redo history when a new action is performed
	redoHistory = {}

	table.insert(actionHistory, {
		action = actionType,
		target = target,
		summary = summary,
		details = details or {},
		timestamp = os.time()
	})

	-- Keep history from growing too large
	if #actionHistory > MAX_ACTION_HISTORY then
		table.remove(actionHistory, 1)
	end
end

-- Connect to LogService to capture output
LogService.MessageOut:Connect(function(message, messageType)
	table.insert(outputBuffer, {
		message = message,
		messageType = messageType.Name,
		timestamp = os.time()
	})
	-- Keep buffer from growing too large
	if #outputBuffer > MAX_OUTPUT_BUFFER then
		table.remove(outputBuffer, 1)
	end
end)

local toolbar = plugin:CreateToolbar("MCP Integration")
local button =
	toolbar:CreateButton("MCP Server", "Connect to MCP Server for AI Integration", "rbxassetid://10734944444")

local pluginState = {
	serverUrl = "http://localhost:3002",
	mcpServerUrl = "http://localhost:3001",
	isActive = false,
	pollInterval = 0.5,
	lastPoll = 0,
	consecutiveFailures = 0,
	maxFailuresBeforeError = 50,
	lastSuccessfulConnection = 0,
	currentRetryDelay = 0.5,
	maxRetryDelay = 5,
	retryBackoffMultiplier = 1.2,
	-- UI step tracking
	lastHttpOk = false,
	mcpWaitStartTime = nil,
}

local screenGui = plugin:CreateDockWidgetPluginGuiAsync(
	"MCPServerInterface",
	DockWidgetPluginGuiInfo.new(Enum.InitialDockState.Float, false, false, 400, 500, 350, 450)
)
screenGui.Title = "MCP Server v2.0.0"

local mainFrame = Instance.new("Frame")
mainFrame.Size = UDim2.new(1, 0, 1, 0)
mainFrame.BackgroundColor3 = Color3.fromRGB(17, 24, 39)
mainFrame.BorderSizePixel = 0
mainFrame.Parent = screenGui

local mainCorner = Instance.new("UICorner")
mainCorner.CornerRadius = UDim.new(0, 8)
mainCorner.Parent = mainFrame

local headerFrame = Instance.new("Frame")
headerFrame.Size = UDim2.new(1, 0, 0, 60)
headerFrame.Position = UDim2.new(0, 0, 0, 0)
headerFrame.BackgroundColor3 = Color3.fromRGB(59, 130, 246)
headerFrame.BorderSizePixel = 0
headerFrame.Parent = mainFrame

local headerCorner = Instance.new("UICorner")
headerCorner.CornerRadius = UDim.new(0, 8)
headerCorner.Parent = headerFrame

local headerGradient = Instance.new("UIGradient")
headerGradient.Color = ColorSequence.new{
	ColorSequenceKeypoint.new(0, Color3.fromRGB(59, 130, 246)),
	ColorSequenceKeypoint.new(1, Color3.fromRGB(147, 51, 234))
}
headerGradient.Rotation = 45
headerGradient.Parent = headerFrame

local titleContainer = Instance.new("Frame")
titleContainer.Size = UDim2.new(1, -70, 1, 0)
titleContainer.Position = UDim2.new(0, 15, 0, 0)
titleContainer.BackgroundTransparency = 1
titleContainer.Parent = headerFrame

local titleLabel = Instance.new("TextLabel")
titleLabel.Size = UDim2.new(1, 0, 0, 28)
titleLabel.Position = UDim2.new(0, 0, 0, 8)
titleLabel.BackgroundTransparency = 1
titleLabel.Text = "MCP Server"
titleLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
titleLabel.TextScaled = false
titleLabel.TextSize = 18
titleLabel.Font = Enum.Font.Jura
titleLabel.TextXAlignment = Enum.TextXAlignment.Left
titleLabel.Parent = titleContainer

local versionLabel = Instance.new("TextLabel")
versionLabel.Size = UDim2.new(1, 0, 0, 16)
versionLabel.Position = UDim2.new(0, 0, 0, 32)
versionLabel.BackgroundTransparency = 1
versionLabel.Text = "AI Integration • v2.0.0"
versionLabel.TextColor3 = Color3.fromRGB(191, 219, 254)
versionLabel.TextScaled = false
versionLabel.TextSize = 12
versionLabel.Font = Enum.Font.Jura
versionLabel.TextXAlignment = Enum.TextXAlignment.Left
versionLabel.Parent = titleContainer

local statusContainer = Instance.new("Frame")
statusContainer.Size = UDim2.new(0, 50, 0, 40)
statusContainer.Position = UDim2.new(1, -60, 0, 10)
statusContainer.BackgroundTransparency = 1
statusContainer.Parent = headerFrame

local statusIndicator = Instance.new("Frame")
statusIndicator.Size = UDim2.new(0, 16, 0, 16)
statusIndicator.Position = UDim2.new(0.5, -8, 0, 5)
statusIndicator.BackgroundColor3 = Color3.fromRGB(239, 68, 68)
statusIndicator.BorderSizePixel = 0
statusIndicator.Parent = statusContainer

local statusCorner = Instance.new("UICorner")
statusCorner.CornerRadius = UDim.new(1, 0)
statusCorner.Parent = statusIndicator

local statusPulse = Instance.new("Frame")
statusPulse.Size = UDim2.new(0, 16, 0, 16)
statusPulse.Position = UDim2.new(0, 0, 0, 0)
statusPulse.BackgroundColor3 = Color3.fromRGB(239, 68, 68)
statusPulse.BackgroundTransparency = 0.7
statusPulse.BorderSizePixel = 0
statusPulse.Parent = statusIndicator

local pulseCorner = Instance.new("UICorner")
pulseCorner.CornerRadius = UDim.new(1, 0)
pulseCorner.Parent = statusPulse

local statusText = Instance.new("TextLabel")
statusText.Size = UDim2.new(0, 50, 0, 12)
statusText.Position = UDim2.new(0, 0, 0, 24)
statusText.BackgroundTransparency = 1
statusText.Text = "OFFLINE"
statusText.TextColor3 = Color3.fromRGB(255, 255, 255)
statusText.TextScaled = false
statusText.TextSize = 8
statusText.Font = Enum.Font.Jura
statusText.TextXAlignment = Enum.TextXAlignment.Center
statusText.Parent = statusContainer

local contentFrame = Instance.new("ScrollingFrame")
contentFrame.Size = UDim2.new(1, -20, 1, -80)
contentFrame.Position = UDim2.new(0, 10, 0, 70)
contentFrame.BackgroundTransparency = 1
contentFrame.BorderSizePixel = 0
contentFrame.ScrollBarThickness = 6
contentFrame.ScrollBarImageColor3 = Color3.fromRGB(99, 102, 241)
contentFrame.CanvasSize = UDim2.new(0, 0, 0, 243)
contentFrame.AutomaticCanvasSize = Enum.AutomaticSize.None
contentFrame.Parent = mainFrame

local contentLayout = Instance.new("UIListLayout")
contentLayout.Padding = UDim.new(0, 12)
contentLayout.SortOrder = Enum.SortOrder.LayoutOrder
contentLayout.Parent = contentFrame

local connectionSection = Instance.new("Frame")
connectionSection.Size = UDim2.new(1, 0, 0, 110)
connectionSection.BackgroundColor3 = Color3.fromRGB(31, 41, 55)
connectionSection.BorderSizePixel = 0
connectionSection.LayoutOrder = 1
connectionSection.Parent = contentFrame

local connectionCorner = Instance.new("UICorner")
connectionCorner.CornerRadius = UDim.new(0, 8)
connectionCorner.Parent = connectionSection

local connectionPadding = Instance.new("UIPadding")
connectionPadding.PaddingLeft = UDim.new(0, 15)
connectionPadding.PaddingRight = UDim.new(0, 15)
connectionPadding.PaddingTop = UDim.new(0, 15)
connectionPadding.PaddingBottom = UDim.new(0, 15)
connectionPadding.Parent = connectionSection

local connectionTitle = Instance.new("TextLabel")
connectionTitle.Size = UDim2.new(1, 0, 0, 20)
connectionTitle.Position = UDim2.new(0, 0, 0, 0)
connectionTitle.BackgroundTransparency = 1
connectionTitle.Text = "Connection Settings"
connectionTitle.TextColor3 = Color3.fromRGB(255, 255, 255)
connectionTitle.TextScaled = false
connectionTitle.TextSize = 14
connectionTitle.Font = Enum.Font.Jura
connectionTitle.TextXAlignment = Enum.TextXAlignment.Left
connectionTitle.Parent = connectionSection

local urlLabel = Instance.new("TextLabel")
urlLabel.Size = UDim2.new(1, 0, 0, 16)
urlLabel.Position = UDim2.new(0, 0, 0, 30)
urlLabel.BackgroundTransparency = 1
urlLabel.Text = "Server URL"
urlLabel.TextColor3 = Color3.fromRGB(156, 163, 175)
urlLabel.TextScaled = false
urlLabel.TextSize = 12
urlLabel.Font = Enum.Font.Jura
urlLabel.TextXAlignment = Enum.TextXAlignment.Left
urlLabel.Parent = connectionSection

local urlInput = Instance.new("TextBox")
urlInput.Size = UDim2.new(1, 0, 0, 32)
urlInput.Position = UDim2.new(0, 0, 0, 50)
urlInput.BackgroundColor3 = Color3.fromRGB(55, 65, 81)
urlInput.BorderSizePixel = 1
urlInput.BorderColor3 = Color3.fromRGB(99, 102, 241)
urlInput.Text = "http://localhost:3002"
urlInput.TextColor3 = Color3.fromRGB(255, 255, 255)
urlInput.TextScaled = false
urlInput.TextSize = 12
urlInput.Font = Enum.Font.Jura
urlInput.ClearTextOnFocus = false
urlInput.PlaceholderText = "Enter server URL..."
urlInput.PlaceholderColor3 = Color3.fromRGB(107, 114, 128)
urlInput.Parent = connectionSection

local urlCorner = Instance.new("UICorner")
urlCorner.CornerRadius = UDim.new(0, 6)
urlCorner.Parent = urlInput

local urlPadding = Instance.new("UIPadding")
urlPadding.PaddingLeft = UDim.new(0, 12)
urlPadding.PaddingRight = UDim.new(0, 12)
urlPadding.Parent = urlInput

local statusSection = Instance.new("Frame")
statusSection.Size = UDim2.new(1, 0, 0, 170)
statusSection.BackgroundColor3 = Color3.fromRGB(31, 41, 55)
statusSection.BorderSizePixel = 0
statusSection.LayoutOrder = 2
statusSection.Parent = contentFrame

local statusSectionCorner = Instance.new("UICorner")
statusSectionCorner.CornerRadius = UDim.new(0, 8)
statusSectionCorner.Parent = statusSection

local statusSectionPadding = Instance.new("UIPadding")
statusSectionPadding.PaddingLeft = UDim.new(0, 15)
statusSectionPadding.PaddingRight = UDim.new(0, 15)
statusSectionPadding.PaddingTop = UDim.new(0, 15)
statusSectionPadding.PaddingBottom = UDim.new(0, 15)
statusSectionPadding.Parent = statusSection

local statusTitle = Instance.new("TextLabel")
statusTitle.Size = UDim2.new(1, 0, 0, 20)
statusTitle.Position = UDim2.new(0, 0, 0, 0)
statusTitle.BackgroundTransparency = 1
statusTitle.Text = "Connection Status"
statusTitle.TextColor3 = Color3.fromRGB(255, 255, 255)
statusTitle.TextScaled = false
statusTitle.TextSize = 14
statusTitle.Font = Enum.Font.Jura
statusTitle.TextXAlignment = Enum.TextXAlignment.Left
statusTitle.Parent = statusSection

local statusLabel = Instance.new("TextLabel")
statusLabel.Size = UDim2.new(1, 0, 0, 20)
statusLabel.Position = UDim2.new(0, 0, 0, 30)
statusLabel.BackgroundTransparency = 1
statusLabel.Text = "Disconnected"
statusLabel.TextColor3 = Color3.fromRGB(239, 68, 68)
statusLabel.TextScaled = false
statusLabel.TextSize = 13
statusLabel.Font = Enum.Font.Jura
statusLabel.TextXAlignment = Enum.TextXAlignment.Left
statusLabel.TextWrapped = true
statusLabel.Parent = statusSection

local detailStatusLabel = Instance.new("TextLabel")
detailStatusLabel.Size = UDim2.new(1, 0, 0, 12)
detailStatusLabel.Position = UDim2.new(0, 0, 0, 50)
detailStatusLabel.BackgroundTransparency = 1
detailStatusLabel.Text = "HTTP: X  MCP: X"
detailStatusLabel.TextColor3 = Color3.fromRGB(156, 163, 175)
detailStatusLabel.TextScaled = false
detailStatusLabel.TextSize = 10
detailStatusLabel.Font = Enum.Font.Jura
detailStatusLabel.TextXAlignment = Enum.TextXAlignment.Left
detailStatusLabel.TextWrapped = true
detailStatusLabel.Parent = statusSection

-- Step-by-step status rows
local stepsFrame = Instance.new("Frame")
stepsFrame.Size = UDim2.new(1, 0, 0, 60)
stepsFrame.Position = UDim2.new(0, 0, 0, 68)
stepsFrame.BackgroundTransparency = 1
stepsFrame.Parent = statusSection

local stepsLayout = Instance.new("UIListLayout")
stepsLayout.Padding = UDim.new(0, 6)
stepsLayout.FillDirection = Enum.FillDirection.Vertical
stepsLayout.SortOrder = Enum.SortOrder.LayoutOrder
stepsLayout.Parent = stepsFrame

local function createStepRow(text)
    local row = Instance.new("Frame")
    row.Size = UDim2.new(1, 0, 0, 16)
    row.BackgroundTransparency = 1

    local dot = Instance.new("Frame")
    dot.Size = UDim2.new(0, 10, 0, 10)
    dot.Position = UDim2.new(0, 0, 0, 3)
    dot.BackgroundColor3 = Color3.fromRGB(156, 163, 175)
    dot.BorderSizePixel = 0
    dot.Parent = row

    local dotCorner = Instance.new("UICorner")
    dotCorner.CornerRadius = UDim.new(1, 0)
    dotCorner.Parent = dot

    local label = Instance.new("TextLabel")
    label.Size = UDim2.new(1, -18, 1, 0)
    label.Position = UDim2.new(0, 18, 0, 0)
    label.BackgroundTransparency = 1
    label.Text = text
    label.TextColor3 = Color3.fromRGB(209, 213, 219)
    label.TextScaled = false
    label.TextSize = 11
    label.Font = Enum.Font.Jura
    label.TextXAlignment = Enum.TextXAlignment.Left
    label.Parent = row

    row.Parent = stepsFrame
    return row, dot, label
end

local step1Row, step1Dot, step1Label = createStepRow("1. HTTP server reachable")
local step2Row, step2Dot, step2Label = createStepRow("2. MCP bridge connected")
local step3Row, step3Dot, step3Label = createStepRow("3. Ready for commands")

-- Troubleshooting tip for common stuck state
local troubleshootLabel = Instance.new("TextLabel")
troubleshootLabel.Size = UDim2.new(1, 0, 0, 40)
troubleshootLabel.Position = UDim2.new(0, 0, 0, 130)
troubleshootLabel.BackgroundTransparency = 1
troubleshootLabel.TextWrapped = true
troubleshootLabel.Visible = false
troubleshootLabel.Text = "HTTP is OK but MCP isn't responding. Close all node.exe in Task Manager and restart the server."
troubleshootLabel.TextColor3 = Color3.fromRGB(245, 158, 11)
troubleshootLabel.TextScaled = false
troubleshootLabel.TextSize = 11
troubleshootLabel.Font = Enum.Font.Jura
troubleshootLabel.TextXAlignment = Enum.TextXAlignment.Left
troubleshootLabel.Parent = statusSection

local connectButton = Instance.new("TextButton")
connectButton.Size = UDim2.new(1, 0, 0, 48)
connectButton.BackgroundColor3 = Color3.fromRGB(16, 185, 129)
connectButton.BorderSizePixel = 0
connectButton.Text = "Connect"
connectButton.TextColor3 = Color3.fromRGB(255, 255, 255)
connectButton.TextScaled = false
connectButton.TextSize = 16
connectButton.Font = Enum.Font.Jura
connectButton.LayoutOrder = 3
connectButton.Parent = contentFrame

local connectCorner = Instance.new("UICorner")
connectCorner.CornerRadius = UDim.new(0, 12)
connectCorner.Parent = connectButton



local TweenService = game:GetService("TweenService")
local buttonHover = false

connectButton.MouseEnter:Connect(function()
	buttonHover = true
	connectButton.BackgroundColor3 = not pluginState.isActive and Color3.fromRGB(5, 150, 105) or Color3.fromRGB(220, 38, 38)
end)

connectButton.MouseLeave:Connect(function()
	buttonHover = false
	connectButton.BackgroundColor3 = not pluginState.isActive and Color3.fromRGB(16, 185, 129) or Color3.fromRGB(239, 68, 68)
end)

local pulseAnimation = nil

local function createPulseAnimation()
	if pulseAnimation then
		pcall(function()
			pulseAnimation:Cancel()
		end)
		pulseAnimation = nil
	end
	
	pcall(function()
		pulseAnimation = TweenService:Create(statusPulse, TweenInfo.new(1, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true), {
			Size = UDim2.new(0, 24, 0, 24),
			Position = UDim2.new(0, -4, 0, -4),
			BackgroundTransparency = 1
		})
	end)
	
	return pulseAnimation
end

local function stopPulseAnimation()
	statusPulse.Size = UDim2.new(0, 16, 0, 16)
	statusPulse.Position = UDim2.new(0, 0, 0, 0)
	statusPulse.BackgroundTransparency = 0.7
end

local function startPulseAnimation()
	statusPulse.Size = UDim2.new(0, 16, 0, 16)
	statusPulse.Position = UDim2.new(0, 0, 0, 0)
	statusPulse.BackgroundTransparency = 0.7
end

local function safeCall(func, ...)
	local success, result = pcall(func, ...)
	if success then
		return result
	else
		warn("MCP Plugin Error: " .. tostring(result))
		return nil
	end
end

local function getInstancePath(instance)
	if not instance or instance == game then
		return "game"
	end

	local path = {}
	local current = instance

	while current and current ~= game do
		table.insert(path, 1, current.Name)
		current = current.Parent
	end

	return "game." .. table.concat(path, ".")
end

-- Helper to normalize line endings and split without inventing an extra trailing line
local function splitLines(source)
	local normalized = (source or ""):gsub("\r\n", "\n"):gsub("\r", "\n")
	local endsWithNewline = normalized:sub(-1) == "\n"

	local lines = {}
	local start = 1

	while true do
		local newlinePos = string.find(normalized, "\n", start, true)
		if newlinePos then
			table.insert(lines, string.sub(normalized, start, newlinePos - 1))
			start = newlinePos + 1
		else
			local remainder = string.sub(normalized, start)
			if remainder ~= "" or not endsWithNewline then
				table.insert(lines, remainder)
			end
			break
		end
	end

	if #lines == 0 then
		table.insert(lines, "")
	end

	return lines, endsWithNewline
end

local function joinLines(lines, hadTrailingNewline)
	local source = table.concat(lines, "\n")
	if hadTrailingNewline and source:sub(-1) ~= "\n" then
		source ..= "\n"
	end
	return source
end

-- Helper to convert property values from JSON to Roblox types
local function convertPropertyValue(instance, propertyName, propertyValue)
	-- Handle nil
	if propertyValue == nil then
		return nil
	end

	-- Handle arrays (likely Vector3, Color3, UDim2)
	if type(propertyValue) == "table" and #propertyValue > 0 then
		-- Check if it's a Vector3-like property
		if #propertyValue == 3 then
			local prop = propertyName:lower()
			if prop == "position" or prop == "size" or prop == "orientation" or prop == "velocity" or prop == "angularvelocity" then
				return Vector3.new(propertyValue[1] or 0, propertyValue[2] or 0, propertyValue[3] or 0)
			elseif prop == "color" or prop == "color3" then
				return Color3.new(propertyValue[1] or 0, propertyValue[2] or 0, propertyValue[3] or 0)
			else
				-- Try to infer from current property type
				local success, currentVal = pcall(function() return instance[propertyName] end)
				if success then
					if typeof(currentVal) == "Vector3" then
						return Vector3.new(propertyValue[1] or 0, propertyValue[2] or 0, propertyValue[3] or 0)
					elseif typeof(currentVal) == "Color3" then
						return Color3.new(propertyValue[1] or 0, propertyValue[2] or 0, propertyValue[3] or 0)
					end
				end
			end
		elseif #propertyValue == 2 then
			-- Possibly Vector2
			local success, currentVal = pcall(function() return instance[propertyName] end)
			if success and typeof(currentVal) == "Vector2" then
				return Vector2.new(propertyValue[1] or 0, propertyValue[2] or 0)
			end
		end
	end

	-- Handle object with X, Y, Z keys (Vector3)
	if type(propertyValue) == "table" and (propertyValue.X or propertyValue.Y or propertyValue.Z) then
		return Vector3.new(propertyValue.X or 0, propertyValue.Y or 0, propertyValue.Z or 0)
	end

	-- Handle object with R, G, B keys (Color3)
	if type(propertyValue) == "table" and (propertyValue.R or propertyValue.G or propertyValue.B) then
		return Color3.new(propertyValue.R or 0, propertyValue.G or 0, propertyValue.B or 0)
	end

	-- Handle Enum values (strings like "Ball", "Cylinder", etc.)
	if type(propertyValue) == "string" then
		local success, currentVal = pcall(function() return instance[propertyName] end)
		if success and typeof(currentVal) == "EnumItem" then
			local enumType = tostring(currentVal.EnumType)
			local enumSuccess, enumVal = pcall(function()
				return Enum[enumType][propertyValue]
			end)
			if enumSuccess and enumVal then
				return enumVal
			end
		end
		-- Handle BrickColor
		if propertyName == "BrickColor" then
			return BrickColor.new(propertyValue)
		end
	end

	-- Handle boolean strings
	if type(propertyValue) == "string" then
		if propertyValue == "true" then return true end
		if propertyValue == "false" then return false end
	end

	-- Return as-is for primitives (number, boolean, string)
	return propertyValue
end

local processRequest
local sendResponse
local handlers = {}

local function pollForRequests()
	if not pluginState.isActive then
		return
	end

	local success, result = pcall(function()
		return HttpService:RequestAsync({
			Url = pluginState.serverUrl .. "/poll",
			Method = "GET",
			Headers = {
				["Content-Type"] = "application/json",
			},
		})
	end)

	if success and (result.Success or result.StatusCode == 503) then
		pluginState.consecutiveFailures = 0
		pluginState.currentRetryDelay = 0.5
		pluginState.lastSuccessfulConnection = tick()

		local data = HttpService:JSONDecode(result.Body)
		local mcpConnected = data.mcpConnected == true
		-- Step indicators: HTTP request succeeded
		pluginState.lastHttpOk = true
		step1Dot.BackgroundColor3 = Color3.fromRGB(34, 197, 94)
		step1Label.Text = "1. HTTP server reachable (OK)"
		
		if mcpConnected and not statusLabel.Text:find("Connected") then
			statusLabel.Text = "Connected"
			statusLabel.TextColor3 = Color3.fromRGB(34, 197, 94)
			statusIndicator.BackgroundColor3 = Color3.fromRGB(34, 197, 94)
			statusPulse.BackgroundColor3 = Color3.fromRGB(34, 197, 94)
			statusText.Text = "ONLINE"
			detailStatusLabel.Text = "HTTP: OK  MCP: OK"
			detailStatusLabel.TextColor3 = Color3.fromRGB(34, 197, 94)
			-- Steps 2/3 OK
			step2Dot.BackgroundColor3 = Color3.fromRGB(34, 197, 94)
			step2Label.Text = "2. MCP bridge connected (OK)"
			step3Dot.BackgroundColor3 = Color3.fromRGB(34, 197, 94)
			step3Label.Text = "3. Ready for commands (OK)"
			pluginState.mcpWaitStartTime = nil
			troubleshootLabel.Visible = false
			stopPulseAnimation()
		elseif not mcpConnected then
			statusLabel.Text = "Waiting for MCP server"
			statusLabel.TextColor3 = Color3.fromRGB(245, 158, 11)
			statusIndicator.BackgroundColor3 = Color3.fromRGB(245, 158, 11)
			statusPulse.BackgroundColor3 = Color3.fromRGB(245, 158, 11)
			statusText.Text = "WAITING"
			detailStatusLabel.Text = "HTTP: OK  MCP: ..."
			detailStatusLabel.TextColor3 = Color3.fromRGB(245, 158, 11)
			-- Step 2/3 pending
			step2Dot.BackgroundColor3 = Color3.fromRGB(245, 158, 11)
			step2Label.Text = "2. MCP bridge connected (waiting...)"
			step3Dot.BackgroundColor3 = Color3.fromRGB(245, 158, 11)
			step3Label.Text = "3. Ready for commands (waiting...)"
			-- Track stuck state where HTTP is OK but MCP isn't
			if not pluginState.mcpWaitStartTime then
				pluginState.mcpWaitStartTime = tick()
			end
			local elapsed = tick() - (pluginState.mcpWaitStartTime or tick())
			troubleshootLabel.Visible = elapsed > 8
			startPulseAnimation()
		end

		if data.request and mcpConnected then
			local response = processRequest(data.request)
			sendResponse(data.requestId, response)
		end
	elseif pluginState.isActive then
		pluginState.consecutiveFailures = pluginState.consecutiveFailures + 1

		if pluginState.consecutiveFailures > 1 then
			pluginState.currentRetryDelay =
				math.min(pluginState.currentRetryDelay * pluginState.retryBackoffMultiplier, pluginState.maxRetryDelay)
		end

		if pluginState.consecutiveFailures >= pluginState.maxFailuresBeforeError then
			statusLabel.Text = "Server unavailable"
			statusLabel.TextColor3 = Color3.fromRGB(239, 68, 68)
			statusIndicator.BackgroundColor3 = Color3.fromRGB(239, 68, 68)
			statusPulse.BackgroundColor3 = Color3.fromRGB(239, 68, 68)
			statusText.Text = "ERROR"
			detailStatusLabel.Text = "HTTP: X  MCP: X"
			detailStatusLabel.TextColor3 = Color3.fromRGB(239, 68, 68)
			-- Steps show error
			step1Dot.BackgroundColor3 = Color3.fromRGB(239, 68, 68)
			step1Label.Text = "1. HTTP server reachable (error)"
			step2Dot.BackgroundColor3 = Color3.fromRGB(239, 68, 68)
			step2Label.Text = "2. MCP bridge connected (error)"
			step3Dot.BackgroundColor3 = Color3.fromRGB(239, 68, 68)
			step3Label.Text = "3. Ready for commands (error)"
			pluginState.mcpWaitStartTime = nil
			troubleshootLabel.Visible = false
			stopPulseAnimation()
		elseif pluginState.consecutiveFailures > 5 then
			local waitTime = math.ceil(pluginState.currentRetryDelay)
			statusLabel.Text = "Retrying (" .. waitTime .. "s)"
			statusLabel.TextColor3 = Color3.fromRGB(245, 158, 11)
			statusIndicator.BackgroundColor3 = Color3.fromRGB(245, 158, 11)
			statusPulse.BackgroundColor3 = Color3.fromRGB(245, 158, 11)
			statusText.Text = "RETRY"
			detailStatusLabel.Text = "HTTP: ...  MCP: ..."
			detailStatusLabel.TextColor3 = Color3.fromRGB(245, 158, 11)
			-- Steps show retrying
			step1Dot.BackgroundColor3 = Color3.fromRGB(245, 158, 11)
			step1Label.Text = "1. HTTP server reachable (retrying...)"
			step2Dot.BackgroundColor3 = Color3.fromRGB(245, 158, 11)
			step2Label.Text = "2. MCP bridge connected (retrying...)"
			step3Dot.BackgroundColor3 = Color3.fromRGB(245, 158, 11)
			step3Label.Text = "3. Ready for commands (retrying...)"
			pluginState.mcpWaitStartTime = nil
			troubleshootLabel.Visible = false
			startPulseAnimation()
		elseif pluginState.consecutiveFailures > 1 then
			statusLabel.Text = "Connecting (attempt " .. pluginState.consecutiveFailures .. ")"
			statusLabel.TextColor3 = Color3.fromRGB(245, 158, 11)
			statusIndicator.BackgroundColor3 = Color3.fromRGB(245, 158, 11)
			statusPulse.BackgroundColor3 = Color3.fromRGB(245, 158, 11)
			statusText.Text = "CONNECTING"
			detailStatusLabel.Text = "HTTP: ...  MCP: ..."
			detailStatusLabel.TextColor3 = Color3.fromRGB(245, 158, 11)
			-- Steps show connecting
			step1Dot.BackgroundColor3 = Color3.fromRGB(245, 158, 11)
			step1Label.Text = "1. HTTP server reachable (connecting...)"
			step2Dot.BackgroundColor3 = Color3.fromRGB(245, 158, 11)
			step2Label.Text = "2. MCP bridge connected (connecting...)"
			step3Dot.BackgroundColor3 = Color3.fromRGB(245, 158, 11)
			step3Label.Text = "3. Ready for commands (connecting...)"
			pluginState.mcpWaitStartTime = nil
			troubleshootLabel.Visible = false
			startPulseAnimation()
		end
end
end

sendResponse = function(requestId, responseData)
	pcall(function()
		HttpService:RequestAsync({
			Url = pluginState.serverUrl .. "/response",
			Method = "POST",
			Headers = {
				["Content-Type"] = "application/json",
			},
			Body = HttpService:JSONEncode({
				requestId = requestId,
				response = responseData,
			}),
		})
	end)
end

-- Endpoints that modify data (need undo recording)
local mutationEndpoints = {
	["/api/set-property"] = "Set Property",
	["/api/mass-set-property"] = "Mass Set Property",
	["/api/create-object"] = "Create Object",
	["/api/mass-create-objects"] = "Mass Create Objects",
	["/api/mass-create-objects-with-properties"] = "Mass Create Objects",
	["/api/delete-object"] = "Delete Object",
	["/api/smart-duplicate"] = "Smart Duplicate",
	["/api/mass-duplicate"] = "Mass Duplicate",
	["/api/set-calculated-property"] = "Set Calculated Property",
	["/api/set-relative-property"] = "Set Relative Property",
	["/api/set-script-source"] = "Set Script Source",
	["/api/edit-script-lines"] = "Edit Script Lines",
	["/api/insert-script-lines"] = "Insert Script Lines",
	["/api/delete-script-lines"] = "Delete Script Lines",
	["/api/set-attribute"] = "Set Attribute",
	["/api/delete-attribute"] = "Delete Attribute",
	["/api/add-tag"] = "Add Tag",
	["/api/remove-tag"] = "Remove Tag",
	["/api/clone-instance"] = "Clone Instance",
	["/api/move-instance"] = "Move Instance",
	["/api/insert-asset"] = "Insert Asset",
}

-- Endpoint to handler mapping (populated after handlers are defined below)
local endpointHandlers

processRequest = function(request)
	local endpoint = request.endpoint
	local data = request.data or {}

	-- Handle undo/redo specially (no recording needed)
	if endpoint == "/api/undo" then
		return handlers.undo(data)
	elseif endpoint == "/api/redo" then
		return handlers.redo(data)
	end

	local handler = endpointHandlers[endpoint]
	if not handler then
		return { error = "Unknown endpoint: " .. tostring(endpoint) }
	end

	-- Check if this is a mutation endpoint
	local recordingName = mutationEndpoints[endpoint]
	if recordingName then
		-- Wrap in ChangeHistoryService recording for proper undo
		local recording = ChangeHistoryService:TryBeginRecording("MCP: " .. recordingName)
		local success, result = pcall(handler, data)

		if recording then
			if success and not (result and result.error) then
				ChangeHistoryService:FinishRecording(recording, Enum.FinishRecordingOperation.Commit)
			else
				ChangeHistoryService:FinishRecording(recording, Enum.FinishRecordingOperation.Cancel)
			end
		end

		if success then
			return result
		else
			return { error = "Handler error: " .. tostring(result) }
		end
	else
		-- Read-only endpoint, no recording needed
		return handler(data)
	end
end

local function getInstanceByPath(path)
	if path == "game" or path == "" then
		return game
	end

	path = path:gsub("^game%.", "")

	local parts = {}
	for part in path:gmatch("[^%.]+") do
		table.insert(parts, part)
	end

	local current = game
	for _, part in ipairs(parts) do
		current = current:FindFirstChild(part)
		if not current then
			return nil
		end
	end

	return current
end

handlers.getFileTree = function(requestData)
	local path = requestData.path or ""
	local startInstance = getInstanceByPath(path)

	if not startInstance then
		return { error = "Path not found: " .. path }
	end

	local function buildTree(instance, depth)
		if depth > 10 then
			return { name = instance.Name, className = instance.ClassName, children = {} }
		end

		local node = {
			name = instance.Name,
			className = instance.ClassName,
			path = getInstancePath(instance),
			children = {},
		}

		if instance:IsA("LuaSourceContainer") then
			node.hasSource = true
			node.scriptType = instance.ClassName
		end

		for _, child in ipairs(instance:GetChildren()) do
			table.insert(node.children, buildTree(child, depth + 1))
		end

		return node
	end

	return {
		tree = buildTree(startInstance, 0),
		timestamp = tick(),
	}
end

handlers.searchFiles = function(requestData)
	local query = requestData.query
	local searchType = requestData.searchType or "name"

	if not query then
		return { error = "Query is required" }
	end

	local results = {}

	local function searchRecursive(instance)
		local match = false

		if searchType == "name" then
			match = instance.Name:lower():find(query:lower()) ~= nil
		elseif searchType == "type" then
			match = instance.ClassName:lower():find(query:lower()) ~= nil
		elseif searchType == "content" and instance:IsA("LuaSourceContainer") then
			match = instance.Source:lower():find(query:lower()) ~= nil
		end

		if match then
			table.insert(results, {
				name = instance.Name,
				className = instance.ClassName,
				path = getInstancePath(instance),
				hasSource = instance:IsA("LuaSourceContainer"),
			})
		end

		for _, child in ipairs(instance:GetChildren()) do
			searchRecursive(child)
		end
	end

	searchRecursive(game)

	return {
		results = results,
		query = query,
		searchType = searchType,
		count = #results,
	}
end

handlers.getPlaceInfo = function(requestData)
	return {
		placeName = game.Name,
		placeId = game.PlaceId,
		gameId = game.GameId,
		jobId = game.JobId,
		workspace = {
			name = workspace.Name,
			className = workspace.ClassName,
		},
	}
end

handlers.getServices = function(requestData)
	local serviceName = requestData.serviceName

	if serviceName then
		local service = safeCall(game.GetService, game, serviceName)
		if service then
			return {
				service = {
					name = service.Name,
					className = service.ClassName,
					path = getInstancePath(service),
					childCount = #service:GetChildren(),
				},
			}
		else
			return { error = "Service not found: " .. serviceName }
		end
	else
		local services = {}
		local commonServices = {
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

		for _, serviceName in ipairs(commonServices) do
			local service = safeCall(game.GetService, game, serviceName)
			if service then
				table.insert(services, {
					name = service.Name,
					className = service.ClassName,
					path = getInstancePath(service),
					childCount = #service:GetChildren(),
				})
			end
		end

		return { services = services }
	end
end

handlers.searchObjects = function(requestData)
	local query = requestData.query
	local searchType = requestData.searchType or "name"
	local propertyName = requestData.propertyName

	if not query then
		return { error = "Query is required" }
	end

	local results = {}

	local function searchRecursive(instance)
		local match = false

		if searchType == "name" then
			match = instance.Name:lower():find(query:lower()) ~= nil
		elseif searchType == "class" then
			match = instance.ClassName:lower():find(query:lower()) ~= nil
		elseif searchType == "property" and propertyName then
			local success, value = pcall(function()
				return tostring(instance[propertyName])
			end)
			if success then
				match = value:lower():find(query:lower()) ~= nil
			end
		end

		if match then
			table.insert(results, {
				name = instance.Name,
				className = instance.ClassName,
				path = getInstancePath(instance),
			})
		end

		for _, child in ipairs(instance:GetChildren()) do
			searchRecursive(child)
		end
	end

	searchRecursive(game)

	return {
		results = results,
		query = query,
		searchType = searchType,
		count = #results,
	}
end

handlers.getInstanceProperties = function(requestData)
	local instancePath = requestData.instancePath
	if not instancePath then
		return { error = "Instance path is required" }
	end

	local instance = getInstanceByPath(instancePath)
	if not instance then
		return { error = "Instance not found: " .. instancePath }
	end

	local properties = {}
	local success, result = pcall(function()
		local classInfo = {}

		local basicProps = { "Name", "ClassName", "Parent" }
		for _, prop in ipairs(basicProps) do
			local propSuccess, propValue = pcall(function()
				local val = instance[prop]
				if prop == "Parent" and val then
					return getInstancePath(val)
				elseif val == nil then
					return "nil"
				else
					return tostring(val)
				end
			end)
			if propSuccess then
				properties[prop] = propValue
			end
		end

		local commonProps = {
			"Size",
			"Position",
			"Rotation",
			"CFrame",
			"Anchored",
			"CanCollide",
			"Transparency",
			"BrickColor",
			"Material",
			"Color",
			"Text",
			"TextColor3",
			"BackgroundColor3",
			"Image",
			"ImageColor3",
			"Visible",
			"Active",
			"ZIndex",
			"BorderSizePixel",
			"BackgroundTransparency",
			"ImageTransparency",
			"TextTransparency",
			"Value",
			"Enabled",
			"Brightness",
			"Range",
			"Shadows",
			"Face",
			"SurfaceType",
		}

		for _, prop in ipairs(commonProps) do
			local propSuccess, propValue = pcall(function()
				return tostring(instance[prop])
			end)
			if propSuccess then
				properties[prop] = propValue
			end
		end

		if instance:IsA("LuaSourceContainer") then
			properties.Source = instance.Source
			if instance:IsA("BaseScript") then
				properties.Enabled = tostring(instance.Enabled)
			end
		end

		-- Only Parts have a Shape property; MeshParts do not.
		if instance:IsA("Part") then
			properties.Shape = tostring(instance.Shape)
		end

		-- TopSurface and BottomSurface exist on all BaseParts
		if instance:IsA("BasePart") then
			properties.TopSurface = tostring(instance.TopSurface)
			properties.BottomSurface = tostring(instance.BottomSurface)
		end

		properties.ChildCount = tostring(#instance:GetChildren())

		return properties
	end)

	if success then
		return {
			instancePath = instancePath,
			className = instance.ClassName,
			properties = properties,
		}
	else
		return { error = "Failed to get properties: " .. tostring(result) }
	end
end

handlers.getInstanceChildren = function(requestData)
	local instancePath = requestData.instancePath
	if not instancePath then
		return { error = "Instance path is required" }
	end

	local instance = getInstanceByPath(instancePath)
	if not instance then
		return { error = "Instance not found: " .. instancePath }
	end

	local children = {}
	for _, child in ipairs(instance:GetChildren()) do
		table.insert(children, {
			name = child.Name,
			className = child.ClassName,
			path = getInstancePath(child),
			hasChildren = #child:GetChildren() > 0,
			hasSource = child:IsA("LuaSourceContainer"),
		})
	end

	return {
		instancePath = instancePath,
		children = children,
		count = #children,
	}
end

handlers.searchByProperty = function(requestData)
	local propertyName = requestData.propertyName
	local propertyValue = requestData.propertyValue

	if not propertyName or not propertyValue then
		return { error = "Property name and value are required" }
	end

	local results = {}

	local function searchRecursive(instance)
		local success, value = pcall(function()
			return tostring(instance[propertyName])
		end)

		if success and value:lower():find(propertyValue:lower()) then
			table.insert(results, {
				name = instance.Name,
				className = instance.ClassName,
				path = getInstancePath(instance),
				propertyValue = value,
			})
		end

		for _, child in ipairs(instance:GetChildren()) do
			searchRecursive(child)
		end
	end

	searchRecursive(game)

	return {
		propertyName = propertyName,
		propertyValue = propertyValue,
		results = results,
		count = #results,
	}
end

handlers.getClassInfo = function(requestData)
	local className = requestData.className
	if not className then
		return { error = "Class name is required" }
	end

	local success, tempInstance = pcall(function()
		return Instance.new(className)
	end)

	if not success then
		return { error = "Invalid class name: " .. className }
	end

	local classInfo = {
		className = className,
		properties = {},
		methods = {},
		events = {},
	}

	local commonProps = {
		"Name",
		"ClassName",
		"Parent",
		"Size",
		"Position",
		"Rotation",
		"CFrame",
		"Anchored",
		"CanCollide",
		"Transparency",
		"BrickColor",
		"Material",
		"Color",
		"Text",
		"TextColor3",
		"BackgroundColor3",
		"Image",
		"ImageColor3",
		"Visible",
		"Active",
		"ZIndex",
		"BorderSizePixel",
		"BackgroundTransparency",
		"ImageTransparency",
		"TextTransparency",
		"Value",
		"Enabled",
		"Brightness",
		"Range",
		"Shadows",
	}

	for _, prop in ipairs(commonProps) do
		local propSuccess, _ = pcall(function()
			return tempInstance[prop]
		end)
		if propSuccess then
			table.insert(classInfo.properties, prop)
		end
	end

	local commonMethods = {
		"Destroy",
		"Clone",
		"FindFirstChild",
		"FindFirstChildOfClass",
		"GetChildren",
		"IsA",
		"IsAncestorOf",
		"IsDescendantOf",
		"WaitForChild",
	}

	for _, method in ipairs(commonMethods) do
		local methodSuccess, _ = pcall(function()
			return tempInstance[method]
		end)
		if methodSuccess then
			table.insert(classInfo.methods, method)
		end
	end

	tempInstance:Destroy()

	return classInfo
end

handlers.getProjectStructure = function(requestData)
	local startPath = requestData.path or ""
	local maxDepth = requestData.maxDepth or 3
	local showScriptsOnly = requestData.scriptsOnly or false

	local startInstance
	if startPath == "" or startPath == "game" then
		local services = {}
		local mainServices = {
			"Workspace",
			"ServerScriptService",
			"ServerStorage",
			"ReplicatedStorage",
			"StarterGui",
			"StarterPack",
			"StarterPlayer",
			"Players",
		}

		for _, serviceName in ipairs(mainServices) do
			local service = safeCall(game.GetService, game, serviceName)
			if service then
				local serviceInfo = {
					name = service.Name,
					className = service.ClassName,
					path = getInstancePath(service),
					childCount = #service:GetChildren(),
					hasChildren = #service:GetChildren() > 0,
				}
				table.insert(services, serviceInfo)
			end
		end

		return {
			type = "service_overview",
			services = services,
			timestamp = tick(),
			note = "Use path parameter to explore specific locations (e.g., 'game.ServerScriptService')",
		}
	else
		startInstance = getInstanceByPath(startPath)
		if not startInstance then
			return { error = "Path not found: " .. startPath }
		end
	end

	local function getStructure(instance, depth, currentPath)
		if depth > maxDepth then
			return {
				name = instance.Name,
				className = instance.ClassName,
				path = getInstancePath(instance),
				childCount = #instance:GetChildren(),
				hasMore = true,
				note = "Max depth reached - use this path to explore further",
			}
		end

		local node = {
			name = instance.Name,
			className = instance.ClassName,
			path = getInstancePath(instance),
			children = {},
		}

		if instance:IsA("LuaSourceContainer") then
			node.hasSource = true
			node.scriptType = instance.ClassName
			if instance:IsA("BaseScript") then
				node.enabled = instance.Enabled
			end
		end

		if instance:IsA("GuiObject") then
			node.visible = instance.Visible
			if instance:IsA("Frame") or instance:IsA("ScreenGui") then
				node.guiType = "container"
			elseif instance:IsA("TextLabel") or instance:IsA("TextButton") then
				node.guiType = "text"
				if instance.Text and instance.Text ~= "" then
					node.text = instance.Text
				end
			elseif instance:IsA("ImageLabel") or instance:IsA("ImageButton") then
				node.guiType = "image"
			end
		end

		local children = instance:GetChildren()
		if showScriptsOnly then
			local scriptChildren = {}
			for _, child in ipairs(children) do
				if child:IsA("BaseScript") or child:IsA("Folder") or child:IsA("ModuleScript") then
					table.insert(scriptChildren, child)
				end
			end
			children = scriptChildren
		end

		local childCount = #children
		if childCount > 20 and depth < maxDepth then
			local classGroups = {}
			for _, child in ipairs(children) do
				local className = child.ClassName
				if not classGroups[className] then
					classGroups[className] = {}
				end
				table.insert(classGroups[className], child)
			end

			node.childSummary = {}
			for className, classChildren in pairs(classGroups) do
				table.insert(node.childSummary, {
					className = className,
					count = #classChildren,
					examples = {
						classChildren[1] and classChildren[1].Name,
						classChildren[2] and classChildren[2].Name,
					},
				})
			end

			for className, classChildren in pairs(classGroups) do
				for i = 1, math.min(3, #classChildren) do
					table.insert(node.children, getStructure(classChildren[i], depth + 1, currentPath))
				end
				if #classChildren > 3 then
					table.insert(node.children, {
						name = "... " .. (#classChildren - 3) .. " more " .. className .. " objects",
						className = "MoreIndicator",
						path = getInstancePath(instance) .. " [" .. className .. " children]",
						note = "Use specific path to explore these objects",
					})
				end
			end
		else
			for _, child in ipairs(children) do
				table.insert(node.children, getStructure(child, depth + 1, currentPath))
			end
		end

		return node
	end

	local result = getStructure(startInstance, 0, startPath)
	result.requestedPath = startPath
	result.maxDepth = maxDepth
	result.scriptsOnly = showScriptsOnly
	result.timestamp = tick()

	return result
end

handlers.setProperty = function(requestData)
	local instancePath = requestData.instancePath
	local propertyName = requestData.propertyName
	local propertyValue = requestData.propertyValue

	if not instancePath or not propertyName then
		return { error = "Instance path and property name are required" }
	end

	local instance = getInstanceByPath(instancePath)
	if not instance then
		return { error = "Instance not found: " .. instancePath }
	end

	local success, result = pcall(function()
		-- Handle instance reference properties (Parent, PrimaryPart, etc.)
		if propertyName == "Parent" or propertyName == "PrimaryPart" then
			if type(propertyValue) == "string" then
				local refInstance = getInstanceByPath(propertyValue)
				if refInstance then
					instance[propertyName] = refInstance
				else
					return { error = propertyName .. " instance not found: " .. propertyValue }
				end
			end
		elseif propertyName == "Name" then
			instance.Name = tostring(propertyValue)
		elseif propertyName == "Source" and instance:IsA("LuaSourceContainer") then
			instance.Source = tostring(propertyValue)
		else
			-- Use the generic converter for all other properties
			local convertedValue = convertPropertyValue(instance, propertyName, propertyValue)
			if convertedValue ~= nil then
				instance[propertyName] = convertedValue
			else
				instance[propertyName] = propertyValue
			end
		end

		ChangeHistoryService:SetWaypoint("Set " .. propertyName .. " property")
		return true
	end)

	if success and result ~= false then
		-- Log for undo tracking
		logAction("set_property", instancePath, propertyName .. " = " .. serializeValue(propertyValue), {
			propertyName = propertyName,
			newValue = propertyValue
		})
		return {
			success = true,
			instancePath = instancePath,
			propertyName = propertyName,
			propertyValue = propertyValue,
			message = "Property set successfully",
		}
	else
		return { 
			error = "Failed to set property: " .. tostring(result),
			instancePath = instancePath,
			propertyName = propertyName,
		}
	end
end

handlers.createObject = function(requestData)
	local className = requestData.className
	local parentPath = requestData.parent
	local name = requestData.name
	local properties = requestData.properties or {}

	if not className or not parentPath then
		return { error = "Class name and parent are required" }
	end

	local parentInstance = getInstanceByPath(parentPath)
	if not parentInstance then
		return { error = "Parent instance not found: " .. parentPath }
	end

	local success, newInstance = pcall(function()
		local instance = Instance.new(className)
		
		if name then
			instance.Name = name
		end

		for propertyName, propertyValue in pairs(properties) do
			pcall(function()
				instance[propertyName] = propertyValue
			end)
		end

		instance.Parent = parentInstance
		ChangeHistoryService:SetWaypoint("Create " .. className)
		return instance
	end)

	if success and newInstance then
		local newPath = getInstancePath(newInstance)
		-- Log for undo tracking
		logAction("create_object", newPath, "Created " .. className .. " '" .. newInstance.Name .. "'", {
			className = className,
			parent = parentPath
		})
		return {
			success = true,
			className = className,
			parent = parentPath,
			instancePath = newPath,
			name = newInstance.Name,
			message = "Object created successfully",
		}
	else
		return { 
			error = "Failed to create object: " .. tostring(newInstance),
			className = className,
			parent = parentPath,
		}
	end
end

handlers.deleteObject = function(requestData)
	local instancePath = requestData.instancePath

	if not instancePath then
		return { error = "Instance path is required" }
	end

	local instance = getInstanceByPath(instancePath)
	if not instance then
		return { error = "Instance not found: " .. instancePath }
	end

	if instance == game then
		return { error = "Cannot delete the game instance" }
	end

	local name = instance.Name
	local className = instance.ClassName

	local success, result = pcall(function()
		instance:Destroy()
		ChangeHistoryService:SetWaypoint("Delete " .. className .. " (" .. name .. ")")
		return true
	end)

	if success then
		-- Log for undo tracking
		logAction("delete_object", instancePath, "Deleted " .. className .. " '" .. name .. "'", {
			className = className,
			name = name
		})
		return {
			success = true,
			instancePath = instancePath,
			message = "Object deleted successfully",
		}
	else
		return { 
			error = "Failed to delete object: " .. tostring(result),
			instancePath = instancePath,
		}
	end
end

handlers.massSetProperty = function(requestData)
	local paths = requestData.paths
	local propertyName = requestData.propertyName
	local propertyValue = requestData.propertyValue

	if not paths or type(paths) ~= "table" or #paths == 0 or not propertyName then
		return { error = "Paths array and property name are required" }
	end

	local results = {}
	local successCount = 0
	local failureCount = 0

	for _, path in ipairs(paths) do
		local instance = getInstanceByPath(path)
		if instance then
			local success, err = pcall(function()
				instance[propertyName] = propertyValue
			end)
			
			if success then
				successCount = successCount + 1
				table.insert(results, {
					path = path,
					success = true,
					propertyName = propertyName,
					propertyValue = propertyValue
				})
			else
				failureCount = failureCount + 1
				table.insert(results, {
					path = path,
					success = false,
					error = tostring(err)
				})
			end
		else
			failureCount = failureCount + 1
			table.insert(results, {
				path = path,
				success = false,
				error = "Instance not found"
			})
		end
	end

	if successCount > 0 then
		ChangeHistoryService:SetWaypoint("Mass set " .. propertyName .. " property")
	end

	return {
		results = results,
		summary = {
			total = #paths,
			succeeded = successCount,
			failed = failureCount
		}
	}
end

handlers.massGetProperty = function(requestData)
	local paths = requestData.paths
	local propertyName = requestData.propertyName

	if not paths or type(paths) ~= "table" or #paths == 0 or not propertyName then
		return { error = "Paths array and property name are required" }
	end

	local results = {}

	for _, path in ipairs(paths) do
		local instance = getInstanceByPath(path)
		if instance then
			local success, value = pcall(function()
				return instance[propertyName]
			end)
			
			if success then
				table.insert(results, {
					path = path,
					success = true,
					propertyName = propertyName,
					propertyValue = value
				})
			else
				table.insert(results, {
					path = path,
					success = false,
					error = tostring(value)
				})
			end
		else
			table.insert(results, {
				path = path,
				success = false,
				error = "Instance not found"
			})
		end
	end

	return {
		results = results,
		propertyName = propertyName
	}
end

handlers.massCreateObjects = function(requestData)
	local objects = requestData.objects

	if not objects or type(objects) ~= "table" or #objects == 0 then
		return { error = "Objects array is required" }
	end

	local results = {}
	local successCount = 0
	local failureCount = 0

	for _, objData in ipairs(objects) do
		local className = objData.className
		local parentPath = objData.parent
		local name = objData.name

		if className and parentPath then
			local parentInstance = getInstanceByPath(parentPath)
			if parentInstance then
				local success, newInstance = pcall(function()
					local instance = Instance.new(className)
					if name then
						instance.Name = name
					end
					instance.Parent = parentInstance
					return instance
				end)

				if success and newInstance then
					successCount = successCount + 1
					table.insert(results, {
						success = true,
						className = className,
						parent = parentPath,
						instancePath = getInstancePath(newInstance),
						name = newInstance.Name
					})
				else
					failureCount = failureCount + 1
					table.insert(results, {
						success = false,
						className = className,
						parent = parentPath,
						error = tostring(newInstance)
					})
				end
			else
				failureCount = failureCount + 1
				table.insert(results, {
					success = false,
					className = className,
					parent = parentPath,
					error = "Parent instance not found"
				})
			end
		else
			failureCount = failureCount + 1
			table.insert(results, {
				success = false,
				error = "Class name and parent are required"
			})
		end
	end

	if successCount > 0 then
		ChangeHistoryService:SetWaypoint("Mass create objects")
	end

	return {
		results = results,
		summary = {
			total = #objects,
			succeeded = successCount,
			failed = failureCount
		}
	}
end

handlers.massCreateObjectsWithProperties = function(requestData)
	local objects = requestData.objects

	if not objects or type(objects) ~= "table" or #objects == 0 then
		return { error = "Objects array is required" }
	end

	local results = {}
	local successCount = 0
	local failureCount = 0

	for _, objData in ipairs(objects) do
		local className = objData.className
		local parentPath = objData.parent
		local name = objData.name
		local properties = objData.properties or {}

		if className and parentPath then
			local parentInstance = getInstanceByPath(parentPath)
			if parentInstance then
				local success, newInstance = pcall(function()
					local instance = Instance.new(className)

					if name then
						instance.Name = name
					end

					-- Set Parent first so property type inference works
					instance.Parent = parentInstance

					for propertyName, propertyValue in pairs(properties) do
						pcall(function()
							local convertedValue = convertPropertyValue(instance, propertyName, propertyValue)
							if convertedValue ~= nil then
								instance[propertyName] = convertedValue
							end
						end)
					end

					return instance
				end)

				if success and newInstance then
					successCount = successCount + 1
					table.insert(results, {
						success = true,
						className = className,
						parent = parentPath,
						instancePath = getInstancePath(newInstance),
						name = newInstance.Name
					})
				else
					failureCount = failureCount + 1
					table.insert(results, {
						success = false,
						className = className,
						parent = parentPath,
						error = tostring(newInstance)
					})
				end
			else
				failureCount = failureCount + 1
				table.insert(results, {
					success = false,
					className = className,
					parent = parentPath,
					error = "Parent instance not found"
				})
			end
		else
			failureCount = failureCount + 1
			table.insert(results, {
				success = false,
				error = "Class name and parent are required"
			})
		end
	end

	if successCount > 0 then
		ChangeHistoryService:SetWaypoint("Mass create objects with properties")
	end

	return {
		results = results,
		summary = {
			total = #objects,
			succeeded = successCount,
			failed = failureCount
		}
	}
end

handlers.smartDuplicate = function(requestData)
	local instancePath = requestData.instancePath
	local count = requestData.count
	local options = requestData.options or {}

	if not instancePath or not count or count < 1 then
		return { error = "Instance path and count > 0 are required" }
	end

	local instance = getInstanceByPath(instancePath)
	if not instance then
		return { error = "Instance not found: " .. instancePath }
	end

	local results = {}
	local successCount = 0
	local failureCount = 0

	for i = 1, count do
		local success, newInstance = pcall(function()
			local clone = instance:Clone()
			
			if options.namePattern then
				clone.Name = options.namePattern:gsub("{n}", tostring(i))
			else
				clone.Name = instance.Name .. i
			end

			if options.positionOffset and clone:IsA("BasePart") then
				local offset = options.positionOffset
				local currentPos = clone.Position
				clone.Position = Vector3.new(
					currentPos.X + (offset[1] or 0) * i,
					currentPos.Y + (offset[2] or 0) * i,
					currentPos.Z + (offset[3] or 0) * i
				)
			end

			if options.rotationOffset and clone:IsA("BasePart") then
				local offset = options.rotationOffset
				local currentCFrame = clone.CFrame
				clone.CFrame = currentCFrame * CFrame.Angles(
					math.rad((offset[1] or 0) * i),
					math.rad((offset[2] or 0) * i),
					math.rad((offset[3] or 0) * i)
				)
			end

			if options.scaleOffset and clone:IsA("BasePart") then
				local offset = options.scaleOffset
				local currentSize = clone.Size
				clone.Size = Vector3.new(
					currentSize.X * ((offset[1] or 1) ^ i),
					currentSize.Y * ((offset[2] or 1) ^ i),
					currentSize.Z * ((offset[3] or 1) ^ i)
				)
			end

			if options.propertyVariations then
				for propName, values in pairs(options.propertyVariations) do
					if values and #values > 0 then
						local valueIndex = ((i - 1) % #values) + 1
						pcall(function()
							clone[propName] = values[valueIndex]
						end)
					end
				end
			end

			if options.targetParents and options.targetParents[i] then
				local targetParent = getInstanceByPath(options.targetParents[i])
				if targetParent then
					clone.Parent = targetParent
				else
					clone.Parent = instance.Parent
				end
			else
				clone.Parent = instance.Parent
			end

			return clone
		end)

		if success and newInstance then
			successCount = successCount + 1
			table.insert(results, {
				success = true,
				instancePath = getInstancePath(newInstance),
				name = newInstance.Name,
				index = i
			})
		else
			failureCount = failureCount + 1
			table.insert(results, {
				success = false,
				index = i,
				error = tostring(newInstance)
			})
		end
	end

	if successCount > 0 then
		ChangeHistoryService:SetWaypoint("Smart duplicate " .. instance.Name .. " (" .. successCount .. " copies)")
	end

	return {
		results = results,
		summary = {
			total = count,
			succeeded = successCount,
			failed = failureCount
		},
		sourceInstance = instancePath
	}
end

handlers.massDuplicate = function(requestData)
	local duplications = requestData.duplications

	if not duplications or type(duplications) ~= "table" or #duplications == 0 then
		return { error = "Duplications array is required" }
	end

	local allResults = {}
	local totalSuccess = 0
	local totalFailures = 0

	for _, duplication in ipairs(duplications) do
		local result = handlers.smartDuplicate(duplication)
		table.insert(allResults, result)
		
		if result.summary then
			totalSuccess = totalSuccess + result.summary.succeeded
			totalFailures = totalFailures + result.summary.failed
		end
	end

	if totalSuccess > 0 then
		ChangeHistoryService:SetWaypoint("Mass duplicate operations (" .. totalSuccess .. " objects)")
	end

	return {
		results = allResults,
		summary = {
			total = totalSuccess + totalFailures,
			succeeded = totalSuccess,
			failed = totalFailures
		}
	}
end

local function evaluateFormula(formula, variables, instance, index)
	
	local value = formula
	
	value = value:gsub("index", tostring(index))
	
	if instance and instance:IsA("BasePart") then
		local pos = instance.Position
		local size = instance.Size
		value = value:gsub("Position%.X", tostring(pos.X))
		value = value:gsub("Position%.Y", tostring(pos.Y))
		value = value:gsub("Position%.Z", tostring(pos.Z))
		value = value:gsub("Size%.X", tostring(size.X))
		value = value:gsub("Size%.Y", tostring(size.Y))
		value = value:gsub("Size%.Z", tostring(size.Z))
		value = value:gsub("magnitude", tostring(pos.magnitude))
	end
	
	if variables then
		for k, v in pairs(variables) do
			value = value:gsub(k, tostring(v))
		end
	end
	
	value = value:gsub("sin%(([%d%.%-]+)%)", function(x) return tostring(math.sin(tonumber(x) or 0)) end)
	value = value:gsub("cos%(([%d%.%-]+)%)", function(x) return tostring(math.cos(tonumber(x) or 0)) end)
	value = value:gsub("sqrt%(([%d%.%-]+)%)", function(x) return tostring(math.sqrt(tonumber(x) or 0)) end)
	value = value:gsub("abs%(([%d%.%-]+)%)", function(x) return tostring(math.abs(tonumber(x) or 0)) end)
	value = value:gsub("floor%(([%d%.%-]+)%)", function(x) return tostring(math.floor(tonumber(x) or 0)) end)
	value = value:gsub("ceil%(([%d%.%-]+)%)", function(x) return tostring(math.ceil(tonumber(x) or 0)) end)
	
	local result = tonumber(value)
	if result then
		return result, nil
	end
	
	local success, evalResult = pcall(function()
		
		local num = tonumber(value)
		if num then
			return num
		end
		
		local a, b = value:match("^([%d%.%-]+)%s*%*%s*([%d%.%-]+)$")
		if a and b then
			return (tonumber(a) or 0) * (tonumber(b) or 0)
		end
		
		a, b = value:match("^([%d%.%-]+)%s*%+%s*([%d%.%-]+)$")
		if a and b then
			return (tonumber(a) or 0) + (tonumber(b) or 0)
		end
		
		a, b = value:match("^([%d%.%-]+)%s*%-%s*([%d%.%-]+)$")
		if a and b then
			return (tonumber(a) or 0) - (tonumber(b) or 0)
		end
		
		a, b = value:match("^([%d%.%-]+)%s*/%s*([%d%.%-]+)$")
		if a and b then
			local divisor = tonumber(b) or 1
			if divisor ~= 0 then
				return (tonumber(a) or 0) / divisor
			end
		end
		
		error("Unsupported formula pattern: " .. value)
	end)
	
	if success and type(evalResult) == "number" then
		return evalResult, nil
	else
		return index, "Complex formulas not supported - using index value"
	end
end

handlers.setCalculatedProperty = function(requestData)
	local paths = requestData.paths
	local propertyName = requestData.propertyName
	local formula = requestData.formula
	local variables = requestData.variables

	if not paths or type(paths) ~= "table" or #paths == 0 or not propertyName or not formula then
		return { error = "Paths, property name, and formula are required" }
	end

	local results = {}
	local successCount = 0
	local failureCount = 0

	for index, path in ipairs(paths) do
		local instance = getInstanceByPath(path)
		if instance then
			local value, evalError = evaluateFormula(formula, variables, instance, index)
			
			if value ~= nil and not evalError then
				local success, err = pcall(function()
					instance[propertyName] = value
				end)
				
				if success then
					successCount = successCount + 1
					table.insert(results, {
						path = path,
						success = true,
						propertyName = propertyName,
						calculatedValue = value,
						formula = formula
					})
				else
					failureCount = failureCount + 1
					table.insert(results, {
						path = path,
						success = false,
						error = "Property set failed: " .. tostring(err)
					})
				end
			else
				failureCount = failureCount + 1
				table.insert(results, {
					path = path,
					success = false,
					error = evalError or "Formula evaluation failed"
				})
			end
		else
			failureCount = failureCount + 1
			table.insert(results, {
				path = path,
				success = false,
				error = "Instance not found"
			})
		end
	end

	if successCount > 0 then
		ChangeHistoryService:SetWaypoint("Set calculated " .. propertyName .. " property")
	end

	return {
		results = results,
		summary = {
			total = #paths,
			succeeded = successCount,
			failed = failureCount
		},
		formula = formula
	}
end

handlers.setRelativeProperty = function(requestData)
	local paths = requestData.paths
	local propertyName = requestData.propertyName
	local operation = requestData.operation
	local value = requestData.value
	local component = requestData.component

	if not paths or type(paths) ~= "table" or #paths == 0 or not propertyName or not operation or value == nil then
		return { error = "Paths, property name, operation, and value are required" }
	end

	local results = {}
	local successCount = 0
	local failureCount = 0

	for _, path in ipairs(paths) do
		local instance = getInstanceByPath(path)
		if instance then
			local success, err = pcall(function()
				local currentValue = instance[propertyName]
				local newValue

				if component and typeof(currentValue) == "Vector3" then
					local x, y, z = currentValue.X, currentValue.Y, currentValue.Z
					local targetValue = value
					
					if component == "X" then
						if operation == "add" then x = x + targetValue
						elseif operation == "subtract" then x = x - targetValue
						elseif operation == "multiply" then x = x * targetValue
						elseif operation == "divide" then x = x / targetValue
						elseif operation == "power" then x = x ^ targetValue
						end
					elseif component == "Y" then
						if operation == "add" then y = y + targetValue
						elseif operation == "subtract" then y = y - targetValue
						elseif operation == "multiply" then y = y * targetValue
						elseif operation == "divide" then y = y / targetValue
						elseif operation == "power" then y = y ^ targetValue
						end
					elseif component == "Z" then
						if operation == "add" then z = z + targetValue
						elseif operation == "subtract" then z = z - targetValue
						elseif operation == "multiply" then z = z * targetValue
						elseif operation == "divide" then z = z / targetValue
						elseif operation == "power" then z = z ^ targetValue
						end
					end
					
					newValue = Vector3.new(x, y, z)
				elseif typeof(currentValue) == "Color3" and typeof(value) == "Color3" then
					local r, g, b = currentValue.R, currentValue.G, currentValue.B
					
					if operation == "add" then
						newValue = Color3.new(
							math.min(1, r + value.R),
							math.min(1, g + value.G),
							math.min(1, b + value.B)
						)
					elseif operation == "subtract" then
						newValue = Color3.new(
							math.max(0, r - value.R),
							math.max(0, g - value.G),
							math.max(0, b - value.B)
						)
					elseif operation == "multiply" then
						newValue = Color3.new(r * value.R, g * value.G, b * value.B)
					end
				elseif type(currentValue) == "number" and type(value) == "number" then
					if operation == "add" then
						newValue = currentValue + value
					elseif operation == "subtract" then
						newValue = currentValue - value
					elseif operation == "multiply" then
						newValue = currentValue * value
					elseif operation == "divide" then
						newValue = currentValue / value
					elseif operation == "power" then
						newValue = currentValue ^ value
					end
				elseif typeof(currentValue) == "Vector3" and type(value) == "number" then
					local x, y, z = currentValue.X, currentValue.Y, currentValue.Z
					
					if operation == "add" then
						newValue = Vector3.new(x + value, y + value, z + value)
					elseif operation == "subtract" then
						newValue = Vector3.new(x - value, y - value, z - value)
					elseif operation == "multiply" then
						newValue = Vector3.new(x * value, y * value, z * value)
					elseif operation == "divide" then
						newValue = Vector3.new(x / value, y / value, z / value)
					elseif operation == "power" then
						newValue = Vector3.new(x ^ value, y ^ value, z ^ value)
					end
				else
					error("Unsupported property type or operation")
				end

				instance[propertyName] = newValue
				return newValue
			end)
			
			if success then
				successCount = successCount + 1
				table.insert(results, {
					path = path,
					success = true,
					propertyName = propertyName,
					operation = operation,
					value = value,
					component = component,
					newValue = err
				})
			else
				failureCount = failureCount + 1
				table.insert(results, {
					path = path,
					success = false,
					error = tostring(err)
				})
			end
		else
			failureCount = failureCount + 1
			table.insert(results, {
				path = path,
				success = false,
				error = "Instance not found"
			})
		end
	end

	if successCount > 0 then
		ChangeHistoryService:SetWaypoint("Set relative " .. propertyName .. " property")
	end

	return {
		results = results,
		summary = {
			total = #paths,
			succeeded = successCount,
			failed = failureCount
		},
		operation = operation,
		value = value
	}
end

handlers.getScriptSource = function(requestData)
	local instancePath = requestData.instancePath
	local startLine = requestData.startLine
	local endLine = requestData.endLine

	if not instancePath then
		return { error = "Instance path is required" }
	end

	local instance = getInstanceByPath(instancePath)
	if not instance then
		return { error = "Instance not found: " .. instancePath }
	end

	if not instance:IsA("LuaSourceContainer") then
		return { error = "Instance is not a script-like object: " .. instance.ClassName }
	end

	local success, result = pcall(function()
		local fullSource = instance.Source
		local lines, hasTrailingNewline = splitLines(fullSource)
		local totalLineCount = #lines

		-- If line range is specified, extract only those lines
		local sourceToReturn = fullSource
		local returnedStartLine = 1
		local returnedEndLine = totalLineCount

		if startLine or endLine then
			local actualStartLine = math.max(1, startLine or 1)
			local actualEndLine = math.min(#lines, endLine or #lines)

			local selectedLines = {}
			for i = actualStartLine, actualEndLine do
				table.insert(selectedLines, lines[i] or "")
			end

			sourceToReturn = table.concat(selectedLines, '\n')
			if hasTrailingNewline and actualEndLine == #lines and sourceToReturn:sub(-1) ~= "\n" then
				sourceToReturn ..= "\n"
			end
			returnedStartLine = actualStartLine
			returnedEndLine = actualEndLine
		end

		-- Build numbered source for AI agents to accurately identify line numbers
		local numberedLines = {}
		local linesToNumber = startLine and select(1, splitLines(sourceToReturn)) or lines
		local lineOffset = returnedStartLine - 1
		for i, line in ipairs(linesToNumber) do
			table.insert(numberedLines, (i + lineOffset) .. ": " .. line)
		end
		local numberedSource = table.concat(numberedLines, "\n")

		local resp = {
			instancePath = instancePath,
			className = instance.ClassName,
			name = instance.Name,
			source = sourceToReturn,
			numberedSource = numberedSource,
			sourceLength = string.len(fullSource),
			lineCount = totalLineCount,
			-- Line range info
			startLine = returnedStartLine,
			endLine = returnedEndLine,
			isPartial = (startLine ~= nil or endLine ~= nil),
			-- Helpful metadata for large scripts
			truncated = false,
		}

		-- If the source is very large (>50000 chars) and no range specified,
		-- return first 1000 lines with truncation notice
		if not startLine and not endLine and string.len(fullSource) > 50000 then
			local truncatedLines = {}
			local truncatedNumberedLines = {}
			local maxLines = math.min(1000, #lines)
			for i = 1, maxLines do
				table.insert(truncatedLines, lines[i])
				table.insert(truncatedNumberedLines, i .. ": " .. lines[i])
			end
			resp.source = table.concat(truncatedLines, '\n')
			resp.numberedSource = table.concat(truncatedNumberedLines, '\n')
			resp.truncated = true
			resp.endLine = maxLines
			resp.note = "Script truncated to first 1000 lines. Use startLine/endLine parameters to read specific sections."
		end

		if instance:IsA("BaseScript") then
			resp.enabled = instance.Enabled
		end
		return resp
	end)

	if success then
		return result
	else
		return { error = "Failed to get script source: " .. tostring(result) }
	end
end

handlers.setScriptSource = function(requestData)
	local instancePath = requestData.instancePath
	local newSource = requestData.source

	if not instancePath or not newSource then
		return { error = "Instance path and source are required" }
	end

	local instance = getInstanceByPath(instancePath)
	if not instance then
		return { error = "Instance not found: " .. instancePath }
	end

	if not instance:IsA("LuaSourceContainer") then
		return { error = "Instance is not a script-like object: " .. instance.ClassName }
	end

	-- Normalize escape sequences that may have been double-escaped
	local sourceToSet = newSource :: string
	-- Fix double-escaped newlines, tabs, etc.
	sourceToSet = sourceToSet:gsub("\\n", "\n")
	sourceToSet = sourceToSet:gsub("\\t", "\t")
	sourceToSet = sourceToSet:gsub("\\r", "\r")
	sourceToSet = sourceToSet:gsub("\\\\", "\\")
	local updateSuccess, updateResult = pcall(function()
		local oldSourceLength = string.len(instance.Source)

		ScriptEditorService:UpdateSourceAsync(instance, function(oldContent)
			return sourceToSet
		end)

		ChangeHistoryService:SetWaypoint("Set script source: " .. instance.Name)

		return {
			success = true,
			instancePath = instancePath,
			oldSourceLength = oldSourceLength,
			newSourceLength = string.len(sourceToSet),
			method = "UpdateSourceAsync",
			message = "Script source updated successfully (editor-safe)"
		}
	end)

	if updateSuccess then
		return updateResult
	end

	-- Fallback to direct assignment if UpdateSourceAsync fails
	local directSuccess, directResult = pcall(function()
		local oldSource = instance.Source
		instance.Source = sourceToSet

		ChangeHistoryService:SetWaypoint("Set script source: " .. instance.Name)

		return {
			success = true,
			instancePath = instancePath,
			oldSourceLength = string.len(oldSource),
			newSourceLength = string.len(sourceToSet),
			method = "direct",
			message = "Script source updated successfully (direct assignment)"
		}
	end)

	if directSuccess then
		-- Log for undo tracking
		logAction("set_script_source", instancePath, "Script source replaced (" .. directResult.newSourceLength .. " chars)", {
			method = "direct"
		})
		return directResult
	end

	-- Final fallback: replace the script entirely
	local replaceSuccess, replaceResult = pcall(function()
		local parent = instance.Parent
		local name = instance.Name
		local className = instance.ClassName
		local wasBaseScript = instance:IsA("BaseScript")
		local enabled
		if wasBaseScript then
			enabled = instance.Enabled
		end

		local newScript = Instance.new(className)
		newScript.Name = name
		newScript.Source = sourceToSet
		if wasBaseScript then
			newScript.Enabled = enabled
		end

		newScript.Parent = parent
		instance:Destroy()

		ChangeHistoryService:SetWaypoint("Replace script: " .. name)

		return {
			success = true,
			instancePath = getInstancePath(newScript),
			method = "replace",
			message = "Script replaced successfully with new source"
		}
	end)

	if replaceSuccess then
		-- Log for undo tracking
		logAction("set_script_source", replaceResult.instancePath, "Script replaced entirely", {
			method = "replace"
		})
		return replaceResult
	else
		return {
			error = "Failed to set script source. UpdateSourceAsync failed: " .. tostring(updateResult) ..
			        ". Direct assignment failed: " .. tostring(directResult) ..
			        ". Replace method failed: " .. tostring(replaceResult)
		}
	end
end

-- Partial Script Editing: Edit specific lines
handlers.editScriptLines = function(requestData)
	local instancePath = requestData.instancePath
	local startLine = requestData.startLine
	local endLine = requestData.endLine
	local newContent = requestData.newContent

	if not instancePath or not startLine or not endLine or not newContent then
		return { error = "Instance path, startLine, endLine, and newContent are required" }
	end

	-- Normalize escape sequences that may have been double-escaped
	newContent = newContent:gsub("\\n", "\n")
	newContent = newContent:gsub("\\t", "\t")
	newContent = newContent:gsub("\\r", "\r")
	newContent = newContent:gsub("\\\\", "\\")

	local instance = getInstanceByPath(instancePath)
	if not instance then
		return { error = "Instance not found: " .. instancePath }
	end

	if not instance:IsA("LuaSourceContainer") then
		return { error = "Instance is not a script-like object: " .. instance.ClassName }
	end

	local success, result = pcall(function()
		local lines, hadTrailingNewline = splitLines(instance.Source)
		local totalLines = #lines

		if startLine < 1 or startLine > totalLines then
			error("startLine out of range (1-" .. totalLines .. ")")
		end
		if endLine < startLine or endLine > totalLines then
			error("endLine out of range (" .. startLine .. "-" .. totalLines .. ")")
		end

		-- Split new content into lines
		local newLines = select(1, splitLines(newContent))

		-- Build new source: lines before + new content + lines after
		local resultLines = {}

		-- Lines before the edit
		for i = 1, startLine - 1 do
			table.insert(resultLines, lines[i])
		end

		-- New content lines
		for _, line in ipairs(newLines) do
			table.insert(resultLines, line)
		end

		-- Lines after the edit
		for i = endLine + 1, totalLines do
			table.insert(resultLines, lines[i])
		end

		local newSource = joinLines(resultLines, hadTrailingNewline)

		-- Use UpdateSourceAsync for editor compatibility
		ScriptEditorService:UpdateSourceAsync(instance, function(oldContent)
			return newSource
		end)

		ChangeHistoryService:SetWaypoint("Edit script lines " .. startLine .. "-" .. endLine .. ": " .. instance.Name)

		return {
			success = true,
			instancePath = instancePath,
			editedLines = { startLine = startLine, endLine = endLine },
			linesRemoved = endLine - startLine + 1,
			linesAdded = #newLines,
			newLineCount = #resultLines,
			message = "Script lines edited successfully"
		}
	end)

	if success then
		return result
	else
		return { error = "Failed to edit script lines: " .. tostring(result) }
	end
end

-- Partial Script Editing: Insert lines after a specific line
handlers.insertScriptLines = function(requestData)
	local instancePath = requestData.instancePath
	local afterLine = requestData.afterLine or 0 -- 0 means insert at beginning
	local newContent = requestData.newContent

	if not instancePath or not newContent then
		return { error = "Instance path and newContent are required" }
	end

	-- Normalize escape sequences that may have been double-escaped
	newContent = newContent:gsub("\\n", "\n")
	newContent = newContent:gsub("\\t", "\t")
	newContent = newContent:gsub("\\r", "\r")
	newContent = newContent:gsub("\\\\", "\\")

	local instance = getInstanceByPath(instancePath)
	if not instance then
		return { error = "Instance not found: " .. instancePath }
	end

	if not instance:IsA("LuaSourceContainer") then
		return { error = "Instance is not a script-like object: " .. instance.ClassName }
	end

	local success, result = pcall(function()
		local lines, hadTrailingNewline = splitLines(instance.Source)
		local totalLines = #lines

		if afterLine < 0 or afterLine > totalLines then
			error("afterLine out of range (0-" .. totalLines .. ")")
		end

		-- Split new content into lines
		local newLines = select(1, splitLines(newContent))

		-- Build new source
		local resultLines = {}

		-- Lines before insertion point
		for i = 1, afterLine do
			table.insert(resultLines, lines[i])
		end

		-- New content lines
		for _, line in ipairs(newLines) do
			table.insert(resultLines, line)
		end

		-- Lines after insertion point
		for i = afterLine + 1, totalLines do
			table.insert(resultLines, lines[i])
		end

		local newSource = joinLines(resultLines, hadTrailingNewline)

		-- Use UpdateSourceAsync for editor compatibility
		ScriptEditorService:UpdateSourceAsync(instance, function(oldContent)
			return newSource
		end)

		ChangeHistoryService:SetWaypoint("Insert script lines after line " .. afterLine .. ": " .. instance.Name)

		return {
			success = true,
			instancePath = instancePath,
			insertedAfterLine = afterLine,
			linesInserted = #newLines,
			newLineCount = #resultLines,
			message = "Script lines inserted successfully"
		}
	end)

	if success then
		return result
	else
		return { error = "Failed to insert script lines: " .. tostring(result) }
	end
end

-- Partial Script Editing: Delete specific lines
handlers.deleteScriptLines = function(requestData)
	local instancePath = requestData.instancePath
	local startLine = requestData.startLine
	local endLine = requestData.endLine

	if not instancePath or not startLine or not endLine then
		return { error = "Instance path, startLine, and endLine are required" }
	end

	local instance = getInstanceByPath(instancePath)
	if not instance then
		return { error = "Instance not found: " .. instancePath }
	end

	if not instance:IsA("LuaSourceContainer") then
		return { error = "Instance is not a script-like object: " .. instance.ClassName }
	end

	local success, result = pcall(function()
		local lines, hadTrailingNewline = splitLines(instance.Source)
		local totalLines = #lines

		if startLine < 1 or startLine > totalLines then
			error("startLine out of range (1-" .. totalLines .. ")")
		end
		if endLine < startLine or endLine > totalLines then
			error("endLine out of range (" .. startLine .. "-" .. totalLines .. ")")
		end

		-- Build new source without the deleted lines
		local resultLines = {}

		for i = 1, startLine - 1 do
			table.insert(resultLines, lines[i])
		end

		for i = endLine + 1, totalLines do
			table.insert(resultLines, lines[i])
		end

		local newSource = joinLines(resultLines, hadTrailingNewline)

		-- Use UpdateSourceAsync for editor compatibility
		ScriptEditorService:UpdateSourceAsync(instance, function(oldContent)
			return newSource
		end)

		ChangeHistoryService:SetWaypoint("Delete script lines " .. startLine .. "-" .. endLine .. ": " .. instance.Name)

		return {
			success = true,
			instancePath = instancePath,
			deletedLines = { startLine = startLine, endLine = endLine },
			linesDeleted = endLine - startLine + 1,
			newLineCount = #resultLines,
			message = "Script lines deleted successfully"
		}
	end)

	if success then
		return result
	else
		return { error = "Failed to delete script lines: " .. tostring(result) }
	end
end

-- ============================================
-- CLAUDE CODE-STYLE SCRIPT EDITING TOOLS
-- ============================================

-- Helper: Count occurrences of a substring
local function countOccurrences(source, searchStr)
	local count = 0
	local start = 1
	while true do
		local pos = string.find(source, searchStr, start, true) -- plain search
		if pos then
			count = count + 1
			start = pos + 1
		else
			break
		end
	end
	return count
end

-- Helper: Real Lua syntax validation using loadstring (same as validate_script)
local function validateLuaSyntax(source)
	local success, result = pcall(function()
		local fn, err = loadstring(source)
		if err then
			return { valid = false, error = err }
		end
		return { valid = true }
	end)

	if not success then
		return false, { "Failed to validate: " .. tostring(result) }
	end

	if result.error then
		return false, { result.error }
	end

	return true, {}
end

-- edit_script: String-based editing like Claude Code's Edit tool
handlers.editScript = function(requestData)
	local instancePath = requestData.instancePath
	local oldString = requestData.oldString
	local newString = requestData.newString
	local replaceAll = requestData.replaceAll or false
	local validateAfter = requestData.validateAfter
	if validateAfter == nil then validateAfter = true end

	if not instancePath then
		return { error = "Instance path is required" }
	end
	if not oldString or oldString == "" then
		return { error = "old_string is required and cannot be empty" }
	end
	if newString == nil then
		return { error = "new_string is required" }
	end
	if oldString == newString then
		return { error = "old_string and new_string must be different" }
	end

	local instance = getInstanceByPath(instancePath)
	if not instance then
		return { error = "Instance not found: " .. instancePath }
	end

	if not instance:IsA("LuaSourceContainer") then
		return { error = "Instance is not a script: " .. instance.ClassName }
	end

	local success, result = pcall(function()
		local source = instance.Source

		-- Normalize escape sequences that may have been double-escaped
		local searchStr = oldString:gsub("\\n", "\n"):gsub("\\t", "\t"):gsub("\\r", "\r"):gsub("\\\\", "\\")
		local replaceStr = newString:gsub("\\n", "\n"):gsub("\\t", "\t"):gsub("\\r", "\r"):gsub("\\\\", "\\")

		-- Count occurrences
		local occurrences = countOccurrences(source, searchStr)

		if occurrences == 0 then
			return {
				success = false,
				error = "old_string not found in script. Make sure the text matches exactly, including whitespace and indentation.",
				hint = "Tip: Use get_script_source first to see the exact content, then copy the text precisely."
			}
		end

		if occurrences > 1 and not replaceAll then
			return {
				success = false,
				error = "old_string appears " .. occurrences .. " times in the script. Either provide more context to make it unique, or set replace_all=true to replace all occurrences.",
				occurrences = occurrences
			}
		end

		-- Perform the replacement
		local newSource
		if replaceAll then
			newSource = string.gsub(source, searchStr:gsub("([^%w])", "%%%1"), replaceStr) -- Escape pattern chars
		else
			-- Replace just the first occurrence
			local pos = string.find(source, searchStr, 1, true)
			newSource = string.sub(source, 1, pos - 1) .. replaceStr .. string.sub(source, pos + #searchStr)
		end

		-- Validate syntax if requested
		if validateAfter then
			local isValid, syntaxErrors = validateLuaSyntax(newSource)
			if not isValid then
				return {
					success = false,
					error = "Edit would create invalid Lua syntax",
					syntaxErrors = syntaxErrors,
					hint = "The edit was NOT applied. Fix the syntax issues in new_string and try again."
				}
			end
		end

		-- Apply the change
		ScriptEditorService:UpdateSourceAsync(instance, function(oldContent)
			return newSource
		end)

		ChangeHistoryService:SetWaypoint("Edit script: " .. instance.Name)

		-- Prepare summary for logging
		local shortOld = #searchStr > 30 and (string.sub(searchStr, 1, 30) .. "...") or searchStr
		local shortNew = #replaceStr > 30 and (string.sub(replaceStr, 1, 30) .. "...") or replaceStr

		return {
			success = true,
			instancePath = instancePath,
			replacements = replaceAll and occurrences or 1,
			oldLength = #source,
			newLength = #newSource,
			validated = validateAfter,
			message = replaceAll
				and ("Replaced " .. occurrences .. " occurrence(s) successfully")
				or "Edit applied successfully",
			_logSummary = shortOld:gsub("\n", "\\n") .. " → " .. shortNew:gsub("\n", "\\n")
		}
	end)

	if success then
		if result.success then
			-- Log for undo tracking
			logAction("edit_script", instancePath, result._logSummary or "Script edited", {
				replacements = result.replacements
			})
			result._logSummary = nil  -- Remove internal field
		end
		return result
	else
		return { error = "Failed to edit script: " .. tostring(result) }
	end
end

-- search_script: Search for patterns within a script (like grep)
handlers.searchScript = function(requestData)
	local instancePath = requestData.instancePath
	local pattern = requestData.pattern
	local useRegex = requestData.useRegex or false
	local contextLines = requestData.contextLines or 0

	if not instancePath or not pattern then
		return { error = "Instance path and pattern are required" }
	end

	local instance = getInstanceByPath(instancePath)
	if not instance then
		return { error = "Instance not found: " .. instancePath }
	end

	if not instance:IsA("LuaSourceContainer") then
		return { error = "Instance is not a script: " .. instance.ClassName }
	end

	local success, result = pcall(function()
		local source = instance.Source
		local lines, _ = splitLines(source)
		local matches = {}

		for lineNum, line in ipairs(lines) do
			local found = false
			if useRegex then
				found = string.match(line, pattern) ~= nil
			else
				found = string.find(line, pattern, 1, true) ~= nil
			end

			if found then
				local match = {
					lineNumber = lineNum,
					content = line,
					context = {}
				}

				-- Add context lines
				if contextLines > 0 then
					for i = math.max(1, lineNum - contextLines), lineNum - 1 do
						table.insert(match.context, { lineNumber = i, content = lines[i], type = "before" })
					end
					for i = lineNum + 1, math.min(#lines, lineNum + contextLines) do
						table.insert(match.context, { lineNumber = i, content = lines[i], type = "after" })
					end
				end

				table.insert(matches, match)
			end
		end

		return {
			instancePath = instancePath,
			pattern = pattern,
			useRegex = useRegex,
			matches = matches,
			matchCount = #matches,
			totalLines = #lines
		}
	end)

	if success then
		return result
	else
		return { error = "Failed to search script: " .. tostring(result) }
	end
end

-- get_script_function: Extract a specific function by name
handlers.getScriptFunction = function(requestData)
	local instancePath = requestData.instancePath
	local functionName = requestData.functionName

	if not instancePath or not functionName then
		return { error = "Instance path and function name are required" }
	end

	local instance = getInstanceByPath(instancePath)
	if not instance then
		return { error = "Instance not found: " .. instancePath }
	end

	if not instance:IsA("LuaSourceContainer") then
		return { error = "Instance is not a script: " .. instance.ClassName }
	end

	local success, result = pcall(function()
		local source = instance.Source
		local lines, _ = splitLines(source)

		local functionStart = nil
		local functionEnd = nil
		local depth = 0
		local inFunction = false

		-- Patterns to match function definitions
		local patterns = {
			"^%s*function%s+" .. functionName .. "%s*%(", -- function name(
			"^%s*local%s+function%s+" .. functionName .. "%s*%(", -- local function name(
			functionName .. "%s*=%s*function%s*%(", -- name = function(
			"local%s+" .. functionName .. "%s*=%s*function%s*%(" -- local name = function(
		}

		for lineNum, line in ipairs(lines) do
			-- Check if this line starts the function we're looking for
			if not inFunction then
				for _, pat in ipairs(patterns) do
					if string.match(line, pat) then
						functionStart = lineNum
						inFunction = true
						depth = 1
						-- Check if function also ends on this line (one-liner)
						if string.match(line, "%send%s*$") or string.match(line, "%send%s*[%)%];,]") then
							functionEnd = lineNum
							inFunction = false
						end
						break
					end
				end
			else
				-- We're inside the function, track depth
				-- Count block openers
				if string.match(line, "^%s*function%s") or string.match(line, "=%s*function%s*%(") then
					depth = depth + 1
				end
				if string.match(line, "^%s*if%s") and string.match(line, "%sthen%s*$") then
					depth = depth + 1
				end
				if string.match(line, "^%s*for%s") and string.match(line, "%sdo%s*$") then
					depth = depth + 1
				end
				if string.match(line, "^%s*while%s") and string.match(line, "%sdo%s*$") then
					depth = depth + 1
				end
				if string.match(line, "^%s*do%s*$") then
					depth = depth + 1
				end

				-- Count block closers
				if string.match(line, "^%s*end%s*$") or string.match(line, "^%s*end[%)%],;%s]") or string.match(line, "%send%s*$") then
					depth = depth - 1
					if depth == 0 then
						functionEnd = lineNum
						break
					end
				end
			end
		end

		if not functionStart then
			return {
				success = false,
				error = "Function '" .. functionName .. "' not found in script",
				hint = "Check the function name spelling. Use search_script to find available functions."
			}
		end

		if not functionEnd then
			return {
				success = false,
				error = "Could not find the end of function '" .. functionName .. "' - the function may be malformed",
				startLine = functionStart
			}
		end

		-- Extract the function source
		local functionLines = {}
		for i = functionStart, functionEnd do
			table.insert(functionLines, lines[i])
		end

		local functionSource = table.concat(functionLines, "\n")

		-- Create numbered version
		local numberedLines = {}
		for i = functionStart, functionEnd do
			table.insert(numberedLines, string.format("%4d: %s", i, lines[i]))
		end
		local numberedSource = table.concat(numberedLines, "\n")

		return {
			success = true,
			instancePath = instancePath,
			functionName = functionName,
			startLine = functionStart,
			endLine = functionEnd,
			lineCount = functionEnd - functionStart + 1,
			source = functionSource,
			numberedSource = numberedSource
		}
	end)

	if success then
		return result
	else
		return { error = "Failed to get function: " .. tostring(result) }
	end
end

-- find_and_replace_in_scripts: Batch replace across multiple scripts
handlers.findAndReplaceInScripts = function(requestData)
	local paths = requestData.paths
	local oldString = requestData.oldString
	local newString = requestData.newString
	local validateAfter = requestData.validateAfter
	if validateAfter == nil then validateAfter = true end

	if not paths or #paths == 0 then
		return { error = "Paths array is required" }
	end
	if not oldString or oldString == "" then
		return { error = "old_string is required" }
	end
	if newString == nil then
		return { error = "new_string is required" }
	end

	local results = {}
	local successCount = 0
	local failCount = 0
	local skippedCount = 0

	for _, path in ipairs(paths) do
		local instance = getInstanceByPath(path)
		if not instance then
			table.insert(results, { path = path, success = false, error = "Instance not found" })
			failCount = failCount + 1
		elseif not instance:IsA("LuaSourceContainer") then
			table.insert(results, { path = path, success = false, error = "Not a script" })
			failCount = failCount + 1
		else
			local source = instance.Source
			local searchStr = oldString:gsub("\\n", "\n"):gsub("\\t", "\t"):gsub("\\r", "\r"):gsub("\\\\", "\\")
			local replaceStr = newString:gsub("\\n", "\n"):gsub("\\t", "\t"):gsub("\\r", "\r"):gsub("\\\\", "\\")

			local occurrences = countOccurrences(source, searchStr)

			if occurrences == 0 then
				table.insert(results, { path = path, success = true, skipped = true, reason = "Pattern not found" })
				skippedCount = skippedCount + 1
			else
				local newSource = string.gsub(source, searchStr:gsub("([^%w])", "%%%1"), replaceStr)

				if validateAfter then
					local isValid, syntaxErrors = validateLuaSyntax(newSource)
					if not isValid then
						table.insert(results, { path = path, success = false, error = "Would create invalid syntax", syntaxErrors = syntaxErrors })
						failCount = failCount + 1
					else
						pcall(function()
							ScriptEditorService:UpdateSourceAsync(instance, function() return newSource end)
						end)
						table.insert(results, { path = path, success = true, replacements = occurrences })
						successCount = successCount + 1
					end
				else
					pcall(function()
						ScriptEditorService:UpdateSourceAsync(instance, function() return newSource end)
					end)
					table.insert(results, { path = path, success = true, replacements = occurrences })
					successCount = successCount + 1
				end
			end
		end
	end

	if successCount > 0 then
		ChangeHistoryService:SetWaypoint("Batch replace in " .. successCount .. " scripts")
	end

	return {
		success = failCount == 0,
		results = results,
		summary = {
			total = #paths,
			successful = successCount,
			failed = failCount,
			skipped = skippedCount
		}
	}
end

-- Attribute Tools: Get a single attribute
handlers.getAttribute = function(requestData)
	local instancePath = requestData.instancePath
	local attributeName = requestData.attributeName

	if not instancePath or not attributeName then
		return { error = "Instance path and attribute name are required" }
	end

	local instance = getInstanceByPath(instancePath)
	if not instance then
		return { error = "Instance not found: " .. instancePath }
	end

	local success, result = pcall(function()
		local value = instance:GetAttribute(attributeName)
		local valueType = typeof(value)

		-- Serialize the value for JSON transport
		local serializedValue = value
		if valueType == "Vector3" then
			serializedValue = { X = value.X, Y = value.Y, Z = value.Z, _type = "Vector3" }
		elseif valueType == "Color3" then
			serializedValue = { R = value.R, G = value.G, B = value.B, _type = "Color3" }
		elseif valueType == "CFrame" then
			serializedValue = { Position = { X = value.Position.X, Y = value.Position.Y, Z = value.Position.Z }, _type = "CFrame" }
		elseif valueType == "UDim2" then
			serializedValue = { X = { Scale = value.X.Scale, Offset = value.X.Offset }, Y = { Scale = value.Y.Scale, Offset = value.Y.Offset }, _type = "UDim2" }
		elseif valueType == "BrickColor" then
			serializedValue = { Name = value.Name, _type = "BrickColor" }
		end

		return {
			instancePath = instancePath,
			attributeName = attributeName,
			value = serializedValue,
			valueType = valueType,
			exists = value ~= nil
		}
	end)

	if success then
		return result
	else
		return { error = "Failed to get attribute: " .. tostring(result) }
	end
end

-- Attribute Tools: Set an attribute
handlers.setAttribute = function(requestData)
	local instancePath = requestData.instancePath
	local attributeName = requestData.attributeName
	local attributeValue = requestData.attributeValue
	local valueType = requestData.valueType -- Optional type hint

	if not instancePath or not attributeName then
		return { error = "Instance path and attribute name are required" }
	end

	local instance = getInstanceByPath(instancePath)
	if not instance then
		return { error = "Instance not found: " .. instancePath }
	end

	local success, result = pcall(function()
		local value = attributeValue

		-- Handle special type conversions
		if type(attributeValue) == "table" then
			if attributeValue._type == "Vector3" or valueType == "Vector3" then
				value = Vector3.new(attributeValue.X or 0, attributeValue.Y or 0, attributeValue.Z or 0)
			elseif attributeValue._type == "Color3" or valueType == "Color3" then
				value = Color3.new(attributeValue.R or 0, attributeValue.G or 0, attributeValue.B or 0)
			elseif attributeValue._type == "UDim2" or valueType == "UDim2" then
				value = UDim2.new(
					attributeValue.X and attributeValue.X.Scale or 0,
					attributeValue.X and attributeValue.X.Offset or 0,
					attributeValue.Y and attributeValue.Y.Scale or 0,
					attributeValue.Y and attributeValue.Y.Offset or 0
				)
			elseif attributeValue._type == "BrickColor" or valueType == "BrickColor" then
				value = BrickColor.new(attributeValue.Name or "Medium stone grey")
			end
		end

		instance:SetAttribute(attributeName, value)
		ChangeHistoryService:SetWaypoint("Set attribute " .. attributeName .. " on " .. instance.Name)

		return {
			success = true,
			instancePath = instancePath,
			attributeName = attributeName,
			value = attributeValue,
			message = "Attribute set successfully"
		}
	end)

	if success then
		return result
	else
		return { error = "Failed to set attribute: " .. tostring(result) }
	end
end

-- Attribute Tools: Get all attributes
handlers.getAttributes = function(requestData)
	local instancePath = requestData.instancePath

	if not instancePath then
		return { error = "Instance path is required" }
	end

	local instance = getInstanceByPath(instancePath)
	if not instance then
		return { error = "Instance not found: " .. instancePath }
	end

	local success, result = pcall(function()
		local attributes = instance:GetAttributes()
		local serializedAttributes = {}

		for name, value in pairs(attributes) do
			local valueType = typeof(value)
			local serializedValue = value

			if valueType == "Vector3" then
				serializedValue = { X = value.X, Y = value.Y, Z = value.Z, _type = "Vector3" }
			elseif valueType == "Color3" then
				serializedValue = { R = value.R, G = value.G, B = value.B, _type = "Color3" }
			elseif valueType == "CFrame" then
				serializedValue = { Position = { X = value.Position.X, Y = value.Position.Y, Z = value.Position.Z }, _type = "CFrame" }
			elseif valueType == "UDim2" then
				serializedValue = { X = { Scale = value.X.Scale, Offset = value.X.Offset }, Y = { Scale = value.Y.Scale, Offset = value.Y.Offset }, _type = "UDim2" }
			elseif valueType == "BrickColor" then
				serializedValue = { Name = value.Name, _type = "BrickColor" }
			end

			serializedAttributes[name] = {
				value = serializedValue,
				type = valueType
			}
		end

		local count = 0
		for _ in pairs(serializedAttributes) do count = count + 1 end

		return {
			instancePath = instancePath,
			attributes = serializedAttributes,
			count = count
		}
	end)

	if success then
		return result
	else
		return { error = "Failed to get attributes: " .. tostring(result) }
	end
end

-- Attribute Tools: Delete an attribute
handlers.deleteAttribute = function(requestData)
	local instancePath = requestData.instancePath
	local attributeName = requestData.attributeName

	if not instancePath or not attributeName then
		return { error = "Instance path and attribute name are required" }
	end

	local instance = getInstanceByPath(instancePath)
	if not instance then
		return { error = "Instance not found: " .. instancePath }
	end

	local success, result = pcall(function()
		local existed = instance:GetAttribute(attributeName) ~= nil
		instance:SetAttribute(attributeName, nil)
		ChangeHistoryService:SetWaypoint("Delete attribute " .. attributeName .. " from " .. instance.Name)

		return {
			success = true,
			instancePath = instancePath,
			attributeName = attributeName,
			existed = existed,
			message = existed and "Attribute deleted successfully" or "Attribute did not exist"
		}
	end)

	if success then
		return result
	else
		return { error = "Failed to delete attribute: " .. tostring(result) }
	end
end

-- Tag Tools: Get all tags on an instance
handlers.getTags = function(requestData)
	local instancePath = requestData.instancePath

	if not instancePath then
		return { error = "Instance path is required" }
	end

	local instance = getInstanceByPath(instancePath)
	if not instance then
		return { error = "Instance not found: " .. instancePath }
	end

	local success, result = pcall(function()
		local tags = CollectionService:GetTags(instance)

		return {
			instancePath = instancePath,
			tags = tags,
			count = #tags
		}
	end)

	if success then
		return result
	else
		return { error = "Failed to get tags: " .. tostring(result) }
	end
end

-- Tag Tools: Add a tag to an instance
handlers.addTag = function(requestData)
	local instancePath = requestData.instancePath
	local tagName = requestData.tagName

	if not instancePath or not tagName then
		return { error = "Instance path and tag name are required" }
	end

	local instance = getInstanceByPath(instancePath)
	if not instance then
		return { error = "Instance not found: " .. instancePath }
	end

	local success, result = pcall(function()
		local alreadyHad = CollectionService:HasTag(instance, tagName)
		CollectionService:AddTag(instance, tagName)
		ChangeHistoryService:SetWaypoint("Add tag " .. tagName .. " to " .. instance.Name)

		return {
			success = true,
			instancePath = instancePath,
			tagName = tagName,
			alreadyHad = alreadyHad,
			message = alreadyHad and "Instance already had this tag" or "Tag added successfully"
		}
	end)

	if success then
		return result
	else
		return { error = "Failed to add tag: " .. tostring(result) }
	end
end

-- Tag Tools: Remove a tag from an instance
handlers.removeTag = function(requestData)
	local instancePath = requestData.instancePath
	local tagName = requestData.tagName

	if not instancePath or not tagName then
		return { error = "Instance path and tag name are required" }
	end

	local instance = getInstanceByPath(instancePath)
	if not instance then
		return { error = "Instance not found: " .. instancePath }
	end

	local success, result = pcall(function()
		local hadTag = CollectionService:HasTag(instance, tagName)
		CollectionService:RemoveTag(instance, tagName)
		ChangeHistoryService:SetWaypoint("Remove tag " .. tagName .. " from " .. instance.Name)

		return {
			success = true,
			instancePath = instancePath,
			tagName = tagName,
			hadTag = hadTag,
			message = hadTag and "Tag removed successfully" or "Instance did not have this tag"
		}
	end)

	if success then
		return result
	else
		return { error = "Failed to remove tag: " .. tostring(result) }
	end
end

-- Tag Tools: Get all instances with a specific tag
handlers.getTagged = function(requestData)
	local tagName = requestData.tagName

	if not tagName then
		return { error = "Tag name is required" }
	end

	local success, result = pcall(function()
		local taggedInstances = CollectionService:GetTagged(tagName)
		local instances = {}

		for _, instance in ipairs(taggedInstances) do
			table.insert(instances, {
				name = instance.Name,
				className = instance.ClassName,
				path = getInstancePath(instance)
			})
		end

		return {
			tagName = tagName,
			instances = instances,
			count = #instances
		}
	end)

	if success then
		return result
	else
		return { error = "Failed to get tagged instances: " .. tostring(result) }
	end
end

-- Selection handlers
handlers.getSelection = function(requestData)
	local selection = Selection:Get()
	
	if #selection == 0 then
		return {
			success = true,
			selection = {},
			count = 0,
			message = "No objects selected"
		}
	end
	
	local selectedObjects = {}
	for _, instance in ipairs(selection) do
		table.insert(selectedObjects, {
			name = instance.Name,
			className = instance.ClassName,
			path = getInstancePath(instance),
			parent = instance.Parent and getInstancePath(instance.Parent) or nil
		})
	end
	
	return {
		success = true,
		selection = selectedObjects,
		count = #selection,
		message = #selection .. " object(s) selected"
	}
end

-- ============================================
-- OUTPUT CAPTURE HANDLER
-- ============================================

handlers.getOutput = function(requestData)
	local limit = requestData.limit or 100 -- Default to last 100 messages
	local since = requestData.since -- Optional timestamp filter
	local messageTypes = requestData.messageTypes -- Optional filter: {"MessageOutput", "MessageInfo", "MessageWarning", "MessageError"}
	local clear = requestData.clear -- Optional: clear buffer after reading

	-- Also get historical log from LogService
	local success, historyResult = pcall(function()
		return LogService:GetLogHistory()
	end)

	local combinedOutput = {}

	-- Add from our buffer first
	for i = math.max(1, #outputBuffer - limit + 1), #outputBuffer do
		local entry = outputBuffer[i]
		if entry then
			-- Apply timestamp filter
			if not since or entry.timestamp >= since then
				-- Apply message type filter
				if not messageTypes or table.find(messageTypes, entry.messageType) then
					table.insert(combinedOutput, entry)
				end
			end
		end
	end

	-- If we have history from LogService and buffer is small, supplement with history
	if success and historyResult and #combinedOutput < limit then
		for _, logEntry in ipairs(historyResult) do
			if #combinedOutput >= limit then break end
			local entry = {
				message = logEntry.message,
				messageType = tostring(logEntry.messageType),
				timestamp = logEntry.timestamp or 0
			}
			-- Check if not already in our buffer (simple dedup by message)
			local isDuplicate = false
			for _, existing in ipairs(combinedOutput) do
				if existing.message == entry.message then
					isDuplicate = true
					break
				end
			end
			if not isDuplicate then
				if not since or entry.timestamp >= since then
					if not messageTypes or table.find(messageTypes, entry.messageType) then
						table.insert(combinedOutput, entry)
					end
				end
			end
		end
	end

	-- Clear buffer if requested
	if clear then
		outputBuffer = {}
	end

	return {
		success = true,
		output = combinedOutput,
		count = #combinedOutput,
		bufferSize = #outputBuffer,
		timestamp = os.time()
	}
end

-- ============================================
-- INSTANCE MANIPULATION HANDLERS (clone, move)
-- ============================================

handlers.cloneInstance = function(requestData)
	local sourcePath = requestData.sourcePath
	local targetParent = requestData.targetParent
	local newName = requestData.newName -- Optional new name for the clone

	if not sourcePath then
		return { success = false, error = "sourcePath is required" }
	end
	if not targetParent then
		return { success = false, error = "targetParent is required" }
	end

	local sourceInstance = getInstanceByPath(sourcePath)
	if not sourceInstance then
		return { success = false, error = "Source instance not found: " .. sourcePath }
	end

	local parentInstance = getInstanceByPath(targetParent)
	if not parentInstance then
		return { success = false, error = "Target parent not found: " .. targetParent }
	end

	local success, result = pcall(function()
		ChangeHistoryService:SetWaypoint("Before MCP Clone")

		local clone = sourceInstance:Clone()
		if newName then
			clone.Name = newName
		end
		clone.Parent = parentInstance

		ChangeHistoryService:SetWaypoint("After MCP Clone")

		return {
			success = true,
			clonedInstance = {
				name = clone.Name,
				className = clone.ClassName,
				path = getInstancePath(clone),
				parent = getInstancePath(parentInstance)
			},
			message = "Successfully cloned " .. sourceInstance.Name .. " to " .. parentInstance.Name
		}
	end)

	if success then
		return result
	else
		return {
			success = false,
			error = "Failed to clone instance: " .. tostring(result)
		}
	end
end

handlers.moveInstance = function(requestData)
	local instancePath = requestData.instancePath
	local newParent = requestData.newParent

	if not instancePath then
		return { success = false, error = "instancePath is required" }
	end
	if not newParent then
		return { success = false, error = "newParent is required" }
	end

	local instance = getInstanceByPath(instancePath)
	if not instance then
		return { success = false, error = "Instance not found: " .. instancePath }
	end

	local parentInstance = getInstanceByPath(newParent)
	if not parentInstance then
		return { success = false, error = "New parent not found: " .. newParent }
	end

	local oldParent = instance.Parent
	local oldPath = getInstancePath(instance)

	local success, result = pcall(function()
		ChangeHistoryService:SetWaypoint("Before MCP Move")

		instance.Parent = parentInstance

		ChangeHistoryService:SetWaypoint("After MCP Move")

		return {
			success = true,
			movedInstance = {
				name = instance.Name,
				className = instance.ClassName,
				newPath = getInstancePath(instance),
				oldPath = oldPath,
				oldParent = oldParent and oldParent.Name or nil,
				newParent = parentInstance.Name
			},
			message = "Successfully moved " .. instance.Name .. " to " .. parentInstance.Name
		}
	end)

	if success then
		return result
	else
		return {
			success = false,
			error = "Failed to move instance: " .. tostring(result)
		}
	end
end

-- ============================================
-- SCRIPT VALIDATION HANDLER
-- ============================================

handlers.validateScript = function(requestData)
	local instancePath = requestData.instancePath
	local source = requestData.source -- Optional: validate this source instead of script's current source

	local scriptInstance = nil
	local sourceToValidate = source

	if instancePath then
		scriptInstance = getInstanceByPath(instancePath)
		if not scriptInstance then
			return { success = false, error = "Script not found: " .. instancePath }
		end
		if not scriptInstance:IsA("LuaSourceContainer") then
			return { success = false, error = "Instance is not a script: " .. instancePath }
		end
		if not sourceToValidate then
			sourceToValidate = scriptInstance.Source
		end
	end

	if not sourceToValidate then
		return { success = false, error = "Either instancePath or source is required" }
	end

	-- Use ScriptEditorService for syntax analysis
	local success, analysisResult = pcall(function()
		-- Try to use ScriptAnalyzer if available
		local ScriptAnalyzer = game:FindService("ScriptAnalyzer")
		if ScriptAnalyzer then
			local diagnostics = ScriptAnalyzer:Analyze(sourceToValidate)
			return diagnostics
		end
		return nil
	end)

	-- Fallback: Basic Lua syntax check using loadstring
	local syntaxErrors = {}
	local hasError = false

	local loadSuccess, loadResult = pcall(function()
		-- Try to compile the source (won't execute, just parse)
		local fn, err = loadstring(sourceToValidate)
		if err then
			return { error = err }
		end
		return { valid = true }
	end)

	if loadSuccess and loadResult.error then
		hasError = true
		-- Parse the error message for line number
		local lineNum, errorMsg = loadResult.error:match(':(%d+): (.+)')
		table.insert(syntaxErrors, {
			line = tonumber(lineNum) or 0,
			message = errorMsg or loadResult.error,
			severity = "Error"
		})
	elseif not loadSuccess then
		hasError = true
		table.insert(syntaxErrors, {
			line = 0,
			message = tostring(loadResult),
			severity = "Error"
		})
	end

	-- Additional checks for common Luau patterns that loadstring might miss
	local lines = {}
	for line in sourceToValidate:gmatch("[^\r\n]+") do
		table.insert(lines, line)
	end

	local warnings = {}

	-- Check for some common issues
	for i, line in ipairs(lines) do
		-- Check for undefined global access patterns (basic heuristic)
		if line:match("^%s*[%a_][%w_]*%s*=") and not line:match("local") then
			local varName = line:match("^%s*([%a_][%w_]*)%s*=")
			if varName and not _G[varName] and varName ~= "script" then
				table.insert(warnings, {
					line = i,
					message = "Implicit global variable: " .. varName .. " (consider using 'local')",
					severity = "Warning"
				})
			end
		end

		-- Check for deprecated patterns
		if line:match("wait%(") then
			table.insert(warnings, {
				line = i,
				message = "Consider using task.wait() instead of wait() (deprecated)",
				severity = "Info"
			})
		end
		if line:match("spawn%(") then
			table.insert(warnings, {
				line = i,
				message = "Consider using task.spawn() instead of spawn() (deprecated)",
				severity = "Info"
			})
		end
		if line:match("delay%(") then
			table.insert(warnings, {
				line = i,
				message = "Consider using task.delay() instead of delay() (deprecated)",
				severity = "Info"
			})
		end
	end

	return {
		success = true,
		isValid = not hasError,
		errors = syntaxErrors,
		warnings = warnings,
		lineCount = #lines,
		scriptPath = instancePath,
		message = hasError
			and (#syntaxErrors .. " error(s) found")
			or ("Script is valid" .. (#warnings > 0 and " with " .. #warnings .. " warning(s)" or ""))
	}
end

-- ============================================
-- UNDO/REDO HANDLERS (Enhanced with action tracking)
-- ============================================

handlers.undo = function(requestData)
	local success, result = pcall(function()
		-- Pop the last action from history
		local lastAction = nil
		if #actionHistory > 0 then
			lastAction = table.remove(actionHistory)
			-- Move it to redo history
			table.insert(redoHistory, lastAction)
		end

		ChangeHistoryService:Undo()

		return {
			success = true,
			undone = lastAction and (lastAction.action .. " → " .. lastAction.target .. " (" .. lastAction.summary .. ")") or "Unknown action (possibly manual change)",
			action = lastAction and lastAction.action or nil,
			target = lastAction and lastAction.target or nil,
			summary = lastAction and lastAction.summary or nil,
			details = lastAction and lastAction.details or nil,
			remaining_undos = #actionHistory,
			available_redos = #redoHistory,
			message = lastAction and ("Undone: " .. lastAction.summary) or "Undo executed"
		}
	end)

	if success then
		return result
	else
		return {
			success = false,
			error = "Failed to undo: " .. tostring(result),
			remaining_undos = #actionHistory,
			available_redos = #redoHistory
		}
	end
end

handlers.redo = function(requestData)
	local success, result = pcall(function()
		-- Pop the last undone action from redo history
		local redoneAction = nil
		if #redoHistory > 0 then
			redoneAction = table.remove(redoHistory)
			-- Move it back to action history
			table.insert(actionHistory, redoneAction)
		end

		ChangeHistoryService:Redo()

		return {
			success = true,
			redone = redoneAction and (redoneAction.action .. " → " .. redoneAction.target .. " (" .. redoneAction.summary .. ")") or "Unknown action",
			action = redoneAction and redoneAction.action or nil,
			target = redoneAction and redoneAction.target or nil,
			summary = redoneAction and redoneAction.summary or nil,
			details = redoneAction and redoneAction.details or nil,
			remaining_undos = #actionHistory,
			available_redos = #redoHistory,
			message = redoneAction and ("Redone: " .. redoneAction.summary) or "Redo executed"
		}
	end)

	if success then
		return result
	else
		return {
			success = false,
			error = "Failed to redo: " .. tostring(result),
			remaining_undos = #actionHistory,
			available_redos = #redoHistory
		}
	end
end

-- ============================================
-- EXECUTE LUA HANDLER (Run arbitrary Lua code)
-- ============================================

handlers.executeLua = function(requestData)
	local code = requestData.code

	if not code or type(code) ~= "string" then
		return {
			success = false,
			error = "code parameter is required and must be a string"
		}
	end

	-- Create a sandboxed environment with access to game services and Roblox types
	local env = setmetatable({
		-- Core globals
		game = game,
		workspace = workspace,
		script = nil, -- No script context

		-- Services (commonly used)
		Players = game:GetService("Players"),
		Workspace = workspace,
		ReplicatedStorage = game:GetService("ReplicatedStorage"),
		ServerStorage = game:GetService("ServerStorage"),
		ServerScriptService = game:GetService("ServerScriptService"),
		StarterGui = game:GetService("StarterGui"),
		StarterPack = game:GetService("StarterPack"),
		StarterPlayer = game:GetService("StarterPlayer"),
		Lighting = game:GetService("Lighting"),
		SoundService = game:GetService("SoundService"),
		TweenService = game:GetService("TweenService"),
		RunService = game:GetService("RunService"),
		UserInputService = game:GetService("UserInputService"),
		HttpService = game:GetService("HttpService"),
		CollectionService = game:GetService("CollectionService"),
		PhysicsService = game:GetService("PhysicsService"),
		PathfindingService = game:GetService("PathfindingService"),
		TextService = game:GetService("TextService"),
		MarketplaceService = game:GetService("MarketplaceService"),
		TeleportService = game:GetService("TeleportService"),
		GroupService = game:GetService("GroupService"),
		BadgeService = game:GetService("BadgeService"),
		DataStoreService = game:GetService("DataStoreService"),
		MemoryStoreService = game:GetService("MemoryStoreService"),
		MessagingService = game:GetService("MessagingService"),
		PolicyService = game:GetService("PolicyService"),
		LocalizationService = game:GetService("LocalizationService"),
		Selection = game:GetService("Selection"),
		ChangeHistoryService = game:GetService("ChangeHistoryService"),
		ScriptEditorService = game:GetService("ScriptEditorService"),

		-- Roblox constructors
		Instance = Instance,
		Vector3 = Vector3,
		Vector2 = Vector2,
		CFrame = CFrame,
		Color3 = Color3,
		BrickColor = BrickColor,
		UDim = UDim,
		UDim2 = UDim2,
		Rect = Rect,
		Ray = Ray,
		Region3 = Region3,
		NumberSequence = NumberSequence,
		NumberSequenceKeypoint = NumberSequenceKeypoint,
		ColorSequence = ColorSequence,
		ColorSequenceKeypoint = ColorSequenceKeypoint,
		NumberRange = NumberRange,
		TweenInfo = TweenInfo,
		Font = Font,

		-- Enums
		Enum = Enum,

		-- Lua globals
		print = print,
		warn = warn,
		error = error,
		assert = assert,
		type = type,
		typeof = typeof,
		tostring = tostring,
		tonumber = tonumber,
		pairs = pairs,
		ipairs = ipairs,
		next = next,
		select = select,
		unpack = unpack,
		pcall = pcall,
		xpcall = xpcall,
		rawget = rawget,
		rawset = rawset,
		rawequal = rawequal,
		setmetatable = setmetatable,
		getmetatable = getmetatable,
		newproxy = newproxy,

		-- Tables
		table = table,
		string = string,
		math = math,
		os = { time = os.time, date = os.date, difftime = os.difftime, clock = os.clock },
		coroutine = coroutine,
		bit32 = bit32,
		utf8 = utf8,
		buffer = buffer,

		-- Task library
		task = task,
		wait = task.wait,
		delay = task.delay,
		spawn = task.spawn,
		defer = task.defer,

		-- Instance helper from plugin
		getInstanceByPath = getInstanceByPath,

		-- Allow loadstring for dynamic code (we're already in a plugin context)
		loadstring = loadstring,
	}, { __index = _G })

	local success, compileResult = pcall(function()
		return loadstring(code)
	end)

	if not success then
		return {
			success = false,
			error = "Failed to compile code: " .. tostring(compileResult)
		}
	end

	local fn = compileResult
	if not fn then
		return {
			success = false,
			error = "Failed to compile code (loadstring returned nil)"
		}
	end

	-- Set the environment
	setfenv(fn, env)

	-- Execute the code
	local execSuccess, execResult = pcall(fn)

	if not execSuccess then
		return {
			success = false,
			error = "Runtime error: " .. tostring(execResult)
		}
	end

	-- Serialize the result
	local function serializeResult(value, depth)
		depth = depth or 0
		if depth > 5 then return "<max depth>" end

		local t = typeof(value)

		if value == nil then
			return nil
		elseif t == "string" then
			return value
		elseif t == "number" or t == "boolean" then
			return value
		elseif t == "Vector3" then
			return { type = "Vector3", X = value.X, Y = value.Y, Z = value.Z }
		elseif t == "Vector2" then
			return { type = "Vector2", X = value.X, Y = value.Y }
		elseif t == "CFrame" then
			local components = { value:GetComponents() }
			return { type = "CFrame", components = components }
		elseif t == "Color3" then
			return { type = "Color3", R = value.R, G = value.G, B = value.B }
		elseif t == "BrickColor" then
			return { type = "BrickColor", Name = value.Name }
		elseif t == "UDim2" then
			return { type = "UDim2", X = { Scale = value.X.Scale, Offset = value.X.Offset }, Y = { Scale = value.Y.Scale, Offset = value.Y.Offset } }
		elseif t == "UDim" then
			return { type = "UDim", Scale = value.Scale, Offset = value.Offset }
		elseif t == "Instance" then
			return { type = "Instance", ClassName = value.ClassName, Name = value.Name, Path = value:GetFullName() }
		elseif t == "EnumItem" then
			return { type = "EnumItem", Name = tostring(value) }
		elseif t == "table" then
			local result = {}
			local count = 0
			for k, v in pairs(value) do
				count = count + 1
				if count > 100 then
					result["__truncated__"] = true
					break
				end
				local keyStr = type(k) == "string" and k or tostring(k)
				result[keyStr] = serializeResult(v, depth + 1)
			end
			return result
		elseif t == "function" then
			return "<function>"
		elseif t == "thread" then
			return "<thread>"
		else
			return "<" .. t .. ">"
		end
	end

	return {
		success = true,
		result = serializeResult(execResult),
		resultType = typeof(execResult),
		message = "Code executed successfully"
	}
end

-- ============================================
-- INSERT ASSET HANDLER (Creator Store)
-- ============================================

handlers.insertAsset = function(requestData)
	local assetId = requestData.assetId
	local folderName = requestData.folderName or "AIReferences"
	local targetParent = requestData.targetParent or "game.Workspace"

	if not assetId then
		return { error = "Asset ID is required" }
	end

	-- Convert to number if string
	assetId = tonumber(assetId)
	if not assetId then
		return { error = "Asset ID must be a valid number" }
	end

	local success, result = pcall(function()
		-- Get or create the reference folder
		local parentInstance = getInstanceByPath(targetParent)
		if not parentInstance then
			parentInstance = game.Workspace
		end

		local folder = parentInstance:FindFirstChild(folderName)
		if not folder then
			folder = Instance.new("Folder")
			folder.Name = folderName
			folder.Parent = parentInstance
		end

		-- Use game:GetObjects to load the asset (works with any free asset in plugins)
		local assetUrl = "rbxassetid://" .. tostring(assetId)
		local objects = game:GetObjects(assetUrl)

		if not objects or #objects == 0 then
			return {
				success = false,
				error = "Failed to load asset - it may be private, unavailable, or not a model asset"
			}
		end

		-- Parent all loaded objects to the folder
		local insertedPaths = {}
		for i, obj in ipairs(objects) do
			-- Name the object with the asset ID for easy identification
			if #objects == 1 then
				obj.Name = "Asset_" .. tostring(assetId)
			else
				obj.Name = "Asset_" .. tostring(assetId) .. "_" .. tostring(i)
			end
			obj.Parent = folder
			table.insert(insertedPaths, getInstancePath(obj))
		end

		return {
			success = true,
			assetId = assetId,
			folderPath = getInstancePath(folder),
			insertedObjects = insertedPaths,
			objectCount = #objects,
			message = "Successfully loaded " .. #objects .. " object(s) from asset " .. tostring(assetId)
		}
	end)

	if success then
		return result
	else
		return {
			success = false,
			error = "Failed to insert asset: " .. tostring(result),
			assetId = assetId
		}
	end
end

-- ============================================
-- PLAYTEST CONTROL HANDLERS
-- ============================================

-- Track active play test task
local activePlayTestTask = nil

handlers.playSolo = function(requestData)
	local success, result = pcall(function()
		local wasRunning = RunService:IsRunning()

		-- If already running, stop first
		if wasRunning then
			RunService:Stop()
			task.wait(0.2)
		end

		-- Try the new StudioTestService first (available since Dec 2025)
		local studioTestSuccess, studioTestService = pcall(function()
			return game:GetService("StudioTestService")
		end)

		if studioTestSuccess and studioTestService then
			-- Use the new StudioTestService API for proper Play Solo mode
			-- Run in background task so we don't block the HTTP response
			activePlayTestTask = task.spawn(function()
				-- ExecutePlayModeAsync(args: Variant?) - per official docs, pass a string identifier
				local testResult = studioTestService:ExecutePlayModeAsync("MCP_PlayTest")
				activePlayTestTask = nil
			end)

			return {
				success = true,
				wasRunning = wasRunning,
				method = "StudioTestService:ExecutePlayModeAsync",
				message = wasRunning and "Restarted Play Solo (was already running)" or "Started Play Solo mode",
				note = "Use get_output to read script output. Use stop_play when done."
			}
		else
			-- Fallback to RunService for older Studio versions
			RunService:Run()

			return {
				success = true,
				wasRunning = wasRunning,
				method = "RunService:Run (fallback)",
				message = wasRunning and "Restarted play test (was already running)" or "Started Run mode (fallback - StudioTestService not available)",
				note = "Use get_output to read script output. Use stop_play when done."
			}
		end
	end)

	if success then
		return result
	else
		return {
			success = false,
			error = "Failed to start play test: " .. tostring(result)
		}
	end
end

handlers.stopPlay = function(requestData)
	local success, result = pcall(function()
		-- NOTE: RunService:IsRunning() returns false from plugin context even when play test is running
		-- So we always try to stop via StudioTestService first

		-- Try StudioTestService:EndTest first (matches ExecutePlayModeAsync)
		local studioTestSuccess, studioTestService = pcall(function()
			return game:GetService("StudioTestService")
		end)

		if studioTestSuccess and studioTestService then
			local endSuccess, endError = pcall(function()
				studioTestService:EndTest()
			end)

			if endSuccess then
				activePlayTestTask = nil
				return {
					success = true,
					method = "StudioTestService:EndTest",
					message = "Stopped play test"
				}
			else
				-- EndTest failed, try RunService:Stop as fallback
				RunService:Stop()
				activePlayTestTask = nil
				return {
					success = true,
					method = "RunService:Stop (fallback)",
					message = "Stopped play test",
					warning = "EndTest failed: " .. tostring(endError) .. ". Used RunService:Stop() which does NOT restore pre-play state."
				}
			end
		end

		-- No StudioTestService, use RunService:Stop
		RunService:Stop()
		activePlayTestTask = nil

		return {
			success = true,
			method = "RunService:Stop",
			message = "Stopped play test",
			warning = "Note: RunService:Stop() does NOT restore pre-play state. Objects created/modified during play remain changed."
		}
	end)

	if success then
		return result
	else
		return {
			success = false,
			error = "Failed to stop play test: " .. tostring(result)
		}
	end
end

-- ============================================
-- SCREENSHOT HANDLER
-- ============================================

-- Base64 encoding table
local b64chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

local function base64encode(data)
	local result = {}
	local padding = ""

	-- Process in chunks of 3 bytes
	for i = 1, #data, 3 do
		local b1 = string.byte(data, i) or 0
		local b2 = string.byte(data, i + 1) or 0
		local b3 = string.byte(data, i + 2) or 0

		-- Combine into 24-bit number
		local n = b1 * 65536 + b2 * 256 + b3

		-- Extract 4 6-bit values
		local c1 = math.floor(n / 262144) % 64
		local c2 = math.floor(n / 4096) % 64
		local c3 = math.floor(n / 64) % 64
		local c4 = n % 64

		table.insert(result, string.sub(b64chars, c1 + 1, c1 + 1))
		table.insert(result, string.sub(b64chars, c2 + 1, c2 + 1))

		if i + 1 <= #data then
			table.insert(result, string.sub(b64chars, c3 + 1, c3 + 1))
		else
			table.insert(result, "=")
		end

		if i + 2 <= #data then
			table.insert(result, string.sub(b64chars, c4 + 1, c4 + 1))
		else
			table.insert(result, "=")
		end
	end

	return table.concat(result)
end

handlers.captureScreenshot = function(requestData)
	local CaptureService = game:GetService("CaptureService")
	local AssetService = game:GetService("AssetService")

	-- Parameters (default 768 to avoid CaptureService bug with <600px)
	local maxWidth = requestData.maxWidth or 768
	local maxHeight = requestData.maxHeight or 768
	local returnBase64 = requestData.returnBase64 ~= false -- Default true

	-- Use a BindableEvent to wait for the async callback
	local captureComplete = Instance.new("BindableEvent")
	local captureResult = nil
	local captureError = nil

	local success, err = pcall(function()
		CaptureService:CaptureScreenshot(function(contentId)
			if contentId then
				captureResult = contentId
			else
				captureError = "CaptureScreenshot returned nil"
			end
			captureComplete:Fire()
		end)
	end)

	if not success then
		captureComplete:Destroy()
		return {
			success = false,
			error = "Failed to call CaptureScreenshot: " .. tostring(err)
		}
	end

	-- Wait for callback (with timeout)
	local timeoutThread = task.delay(5, function()
		if not captureResult and not captureError then
			captureError = "Capture timed out after 5 seconds"
			captureComplete:Fire()
		end
	end)

	captureComplete.Event:Wait()
	task.cancel(timeoutThread)
	captureComplete:Destroy()

	if captureError then
		return {
			success = false,
			error = captureError
		}
	end

	-- Now load into EditableImage
	local editSuccess, editableImage = pcall(function()
		return AssetService:CreateEditableImageAsync(Content.fromUri(tostring(captureResult)))
	end)

	if not editSuccess or not editableImage then
		return {
			success = false,
			error = "Failed to load capture into EditableImage: " .. tostring(editableImage),
			contentId = tostring(captureResult)
		}
	end

	local originalSize = editableImage.Size
	local resultData = {
		success = true,
		originalWidth = originalSize.X,
		originalHeight = originalSize.Y,
		contentId = tostring(captureResult),
		message = "Screenshot captured successfully"
	}

	-- Resize if needed and return base64
	if returnBase64 then
		-- Calculate resize dimensions maintaining aspect ratio
		local scaleX = maxWidth / originalSize.X
		local scaleY = maxHeight / originalSize.Y
		local scale = math.min(scaleX, scaleY, 1) -- Don't upscale

		local newWidth = math.floor(originalSize.X * scale)
		local newHeight = math.floor(originalSize.Y * scale)

		-- Create resized image
		local resizedImage
		if scale < 1 then
			resizedImage = AssetService:CreateEditableImage({Size = Vector2.new(newWidth, newHeight)})
			-- Draw the original scaled down
			resizedImage:DrawImageTransformed(
				Vector2.new(0, 0), -- position
				Vector2.new(scale, scale), -- scale
				0, -- rotation
				editableImage,
				{
					CombineType = Enum.ImageCombineType.Overwrite
				}
			)
		else
			resizedImage = editableImage
			newWidth = originalSize.X
			newHeight = originalSize.Y
		end

		-- Read pixels
		local pixelSuccess, pixelBuffer = pcall(function()
			return resizedImage:ReadPixelsBuffer(Vector2.new(0, 0), Vector2.new(newWidth, newHeight))
		end)

		if pixelSuccess and pixelBuffer then
			-- Convert buffer to string for base64 encoding
			local pixelString = buffer.tostring(pixelBuffer)

			-- Base64 encode (for smaller images only due to size)
			if #pixelString <= 1024 * 1024 then -- Max 1MB raw
				local base64Data = base64encode(pixelString)
				resultData.base64 = base64Data
				resultData.width = newWidth
				resultData.height = newHeight
				resultData.format = "RGBA"
				resultData.encoding = "base64"
				resultData.pixelDataSize = #pixelString
			else
				resultData.warning = "Image too large for base64 encoding (" .. #pixelString .. " bytes). Use smaller maxWidth/maxHeight."
				resultData.width = newWidth
				resultData.height = newHeight
			end
		else
			resultData.warning = "Failed to read pixels: " .. tostring(pixelBuffer)
		end

		if resizedImage ~= editableImage then
			resizedImage:Destroy()
		end
	end

	editableImage:Destroy()

	return resultData
end

-- ============================================
-- VIEWPORTFRAME RENDERING SYSTEM
-- ============================================

-- Camera angle presets
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

-- Apply lighting preset to WorldModel
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
	end
	-- default: no lights added (ambient only)
end

-- Calculate bounding box of a model
local function getModelBoundingBox(model)
	local parts = {}

	-- Collect all BaseParts
	for _, child in ipairs(model:GetDescendants()) do
		if child:IsA("BasePart") then
			table.insert(parts, child)
		end
	end

	if #parts == 0 then
		-- No parts found, return default
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

-- Main handler: Render Object View
handlers.renderObjectView = function(requestData)
	local success, result = pcall(function()
		local instancePath = requestData.instancePath
		if not instancePath then
			return {
				success = false,
				error = "instancePath is required"
			}
		end

		-- Parse resolution (default 768 to avoid CaptureService bug with <600px)
		local resolution = requestData.resolution or {width = 768, height = 768}
		local width = resolution.width or 768
		local height = resolution.height or 768

		-- Clamp resolution for performance
		width = math.clamp(width, 64, 2048)
		height = math.clamp(height, 64, 2048)

		local anglePreset = requestData.angle or "iso"
		local lighting = requestData.lighting or "bright"
		local background = requestData.background or "transparent"
		local autoDistance = requestData.autoDistance ~= false

		-- Get target instance
		local targetInstance = getInstanceByPath(instancePath)
		if not targetInstance then
			return {
				success = false,
				error = "Instance not found: " .. instancePath
			}
		end

		-- Create ViewportFrame (no parent = no GUI overhead)
		local viewportFrame = Instance.new("ViewportFrame")
		viewportFrame.Size = UDim2.fromOffset(width, height)
		viewportFrame.BackgroundTransparency = background == "transparent" and 1 or 0
		viewportFrame.BackgroundColor3 = background == "grid" and Color3.fromRGB(128, 128, 128) or Color3.fromRGB(255, 255, 255)

		-- Create WorldModel for viewport
		local worldModel = Instance.new("WorldModel")
		worldModel.Parent = viewportFrame

		local camera = Instance.new("Camera")
		camera.Parent = viewportFrame
		viewportFrame.CurrentCamera = camera

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
			-- Custom angle {pitch, yaw, roll, distance}
			local pitch = math.rad(anglePreset.pitch or 0)
			local yaw = math.rad(anglePreset.yaw or 0)
			local roll = math.rad(anglePreset.roll or 0)
			local distance = anglePreset.distance or 10
			cameraOffset = CFrame.new(0, 0, distance) * CFrame.Angles(pitch, yaw, roll)
		else
			cameraOffset = CameraPresets.iso
		end

		-- Auto-calculate distance to fit object
		local cameraDistance = 10
		if autoDistance then
			local fov = 70
			cameraDistance = maxDimension / (2 * math.tan(math.rad(fov / 2))) * 1.3
			cameraDistance = math.max(cameraDistance, 1) -- Minimum distance
		elseif type(anglePreset) == "table" and anglePreset.distance then
			cameraDistance = anglePreset.distance
		end

		-- Apply distance to camera offset
		local offsetDirection = cameraOffset.Position.Unit
		local finalCameraPos = boundingCenter + (offsetDirection * cameraDistance)

		camera.CFrame = CFrame.new(finalCameraPos, boundingCenter) * cameraOffset.Rotation
		camera.FieldOfView = 70

		-- Apply lighting
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

		-- Wait for viewport to render
		task.wait(0.1)
		RunService.Heartbeat:Wait()

		-- WORKAROUND: ViewportFrame doesn't support direct pixel reading
		-- We need to temporarily parent it to screen and use CaptureService
		-- This is a limitation of Roblox's API
		local StarterGui = game:GetService("StarterGui")
		local CaptureService = game:GetService("CaptureService")
		local AssetService = game:GetService("AssetService")

		-- Create temporary ScreenGui
		local tempGui = Instance.new("ScreenGui")
		tempGui.Name = "MCPTempCapture"
		tempGui.ResetOnSpawn = false
		tempGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

		-- CRITICAL FIX: Scale ViewportFrame to fill most of the screen before capture
		-- CaptureScreenshot captures the ENTIRE screen, so a small ViewportFrame = tiny object
		-- By scaling to ~90% of screen, the object fills most of the captured image
		local screenSize = workspace.CurrentCamera.ViewportSize
		viewportFrame.Size = UDim2.fromOffset(screenSize.X * 0.9, screenSize.Y * 0.9)
		viewportFrame.Position = UDim2.fromOffset(screenSize.X * 0.05, screenSize.Y * 0.05)
		viewportFrame.Parent = tempGui
		tempGui.Parent = game.CoreGui

		-- Wait a frame for rendering
		RunService.Heartbeat:Wait()
		task.wait(0.05) -- Extra wait to ensure viewport renders at new size

		-- Capture screenshot of the viewport
		local captureComplete = Instance.new("BindableEvent")
		local captureResult = nil
		local captureError = nil

		pcall(function()
			CaptureService:CaptureScreenshot(function(contentId)
				if contentId then
					captureResult = contentId
				else
					captureError = "CaptureScreenshot returned nil"
				end
				captureComplete:Fire()
			end)
		end)

		-- Wait with timeout
		local timeoutThread = task.delay(5, function()
			if not captureResult and not captureError then
				captureError = "Capture timed out"
				captureComplete:Fire()
			end
		end)

		captureComplete.Event:Wait()
		task.cancel(timeoutThread)
		captureComplete:Destroy()
		tempGui:Destroy()
		viewportFrame:Destroy()

		if captureError then
			return {
				success = false,
				error = "Failed to capture viewport: " .. captureError,
				note = "ViewportFrame capture requires CaptureService (limitation of Roblox API)"
			}
		end

		-- Load captured image
		local editableImage = AssetService:CreateEditableImageAsync(Content.fromUri(tostring(captureResult)))

		-- Resize if needed
		local originalSize = editableImage.Size
		if originalSize.X ~= width or originalSize.Y ~= height then
			local resizedImage = AssetService:CreateEditableImage({Size = Vector2.new(width, height)})
			local scaleX = width / originalSize.X
			local scaleY = height / originalSize.Y
			resizedImage:DrawImageTransformed(
				Vector2.new(0, 0),
				Vector2.new(scaleX, scaleY),
				0,
				editableImage,
				{CombineType = Enum.ImageCombineType.Overwrite}
			)
			editableImage:Destroy()
			editableImage = resizedImage
		end

		-- Convert to base64 RGBA
		local rgbaBuffer = editableImage:ReadPixelsBuffer(Vector2.new(0, 0), editableImage.Size)
		local rgbaString = buffer.tostring(rgbaBuffer)
		local base64Data = base64encode(rgbaString)
		editableImage:Destroy()

		return {
			success = true,
			base64 = base64Data,
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
-- CAMERA CONTROL SYSTEM
-- ============================================

-- Focus Studio camera on an object (like pressing F in Studio)
handlers.focusCamera = function(requestData)
	local success, result = pcall(function()
		local instancePath = requestData.instancePath
		if not instancePath then
			return {
				success = false,
				error = "instancePath is required"
			}
		end

		local anglePreset = requestData.angle or "iso"
		local autoDistance = requestData.autoDistance ~= false
		local customDistance = requestData.distance

		-- Get target instance
		local targetInstance = getInstanceByPath(instancePath)
		if not targetInstance then
			return {
				success = false,
				error = "Instance not found: " .. instancePath
			}
		end

		-- Calculate bounding box and center (reuse from ViewportFrame code)
		local boundingSize, boundingCenter = getModelBoundingBox(targetInstance)
		local maxDimension = math.max(boundingSize.X, boundingSize.Y, boundingSize.Z)

		-- Get camera offset from presets
		local cameraOffset
		if type(anglePreset) == "string" and CameraPresets[anglePreset] then
			cameraOffset = CameraPresets[anglePreset]
		elseif type(anglePreset) == "table" then
			-- Custom angle {pitch, yaw, roll, distance}
			local pitch = math.rad(anglePreset.pitch or 0)
			local yaw = math.rad(anglePreset.yaw or 0)
			local roll = math.rad(anglePreset.roll or 0)
			cameraOffset = CFrame.new(0, 0, 10) * CFrame.Angles(pitch, yaw, roll)
		else
			cameraOffset = CameraPresets.iso
		end

		-- Calculate distance to fit object in view (like F shortcut)
		local cameraDistance
		if customDistance then
			cameraDistance = customDistance
		elseif autoDistance then
			-- FOV of 70 degrees, fit object with some padding
			local fov = 70
			cameraDistance = maxDimension / (2 * math.tan(math.rad(fov / 2))) * 1.5
			cameraDistance = math.max(cameraDistance, 5) -- Minimum 5 studs
		else
			cameraDistance = 20 -- Default distance
		end

		-- Apply distance to camera offset direction
		local offsetDirection = cameraOffset.Position.Unit
		local finalCameraPos = boundingCenter + (offsetDirection * cameraDistance)

		-- Set Studio camera (workspace.CurrentCamera)
		local camera = workspace.CurrentCamera
		camera.CameraType = Enum.CameraType.Fixed
		camera.CFrame = CFrame.new(finalCameraPos, boundingCenter) * cameraOffset.Rotation
		camera.Focus = CFrame.new(boundingCenter)

		return {
			success = true,
			object = {
				name = targetInstance.Name,
				className = targetInstance.ClassName,
				boundingBox = {
					size = {x = boundingSize.X, y = boundingSize.Y, z = boundingSize.Z},
					center = {x = boundingCenter.X, y = boundingCenter.Y, z = boundingCenter.Z}
				}
			},
			camera = {
				position = {x = finalCameraPos.X, y = finalCameraPos.Y, z = finalCameraPos.Z},
				lookAt = {x = boundingCenter.X, y = boundingCenter.Y, z = boundingCenter.Z},
				distance = cameraDistance,
				angle = anglePreset
			},
			message = "Focused camera on " .. targetInstance.Name .. " from " .. tostring(anglePreset) .. " angle"
		}
	end)

	if success then
		return result
	else
		return {
			success = false,
			error = "Failed to focus camera: " .. tostring(result)
		}
	end
end

-- Now that all handlers are defined, populate the endpoint mapping table
endpointHandlers = {
	["/api/file-tree"] = handlers.getFileTree,
	["/api/search-files"] = handlers.searchFiles,
	["/api/place-info"] = handlers.getPlaceInfo,
	["/api/services"] = handlers.getServices,
	["/api/search-objects"] = handlers.searchObjects,
	["/api/instance-properties"] = handlers.getInstanceProperties,
	["/api/instance-children"] = handlers.getInstanceChildren,
	["/api/search-by-property"] = handlers.searchByProperty,
	["/api/class-info"] = handlers.getClassInfo,
	["/api/project-structure"] = handlers.getProjectStructure,
	["/api/set-property"] = handlers.setProperty,
	["/api/mass-set-property"] = handlers.massSetProperty,
	["/api/mass-get-property"] = handlers.massGetProperty,
	["/api/create-object"] = handlers.createObject,
	["/api/mass-create-objects"] = handlers.massCreateObjects,
	["/api/mass-create-objects-with-properties"] = handlers.massCreateObjectsWithProperties,
	["/api/delete-object"] = handlers.deleteObject,
	["/api/smart-duplicate"] = handlers.smartDuplicate,
	["/api/mass-duplicate"] = handlers.massDuplicate,
	["/api/set-calculated-property"] = handlers.setCalculatedProperty,
	["/api/set-relative-property"] = handlers.setRelativeProperty,
	["/api/get-script-source"] = handlers.getScriptSource,
	["/api/set-script-source"] = handlers.setScriptSource,
	["/api/edit-script-lines"] = handlers.editScriptLines,
	["/api/insert-script-lines"] = handlers.insertScriptLines,
	["/api/delete-script-lines"] = handlers.deleteScriptLines,
	-- Claude Code-style script editing tools
	["/api/edit-script"] = handlers.editScript,
	["/api/search-script"] = handlers.searchScript,
	["/api/get-script-function"] = handlers.getScriptFunction,
	["/api/find-and-replace-in-scripts"] = handlers.findAndReplaceInScripts,
	["/api/get-attribute"] = handlers.getAttribute,
	["/api/set-attribute"] = handlers.setAttribute,
	["/api/get-attributes"] = handlers.getAttributes,
	["/api/delete-attribute"] = handlers.deleteAttribute,
	["/api/get-tags"] = handlers.getTags,
	["/api/add-tag"] = handlers.addTag,
	["/api/remove-tag"] = handlers.removeTag,
	["/api/get-tagged"] = handlers.getTagged,
	["/api/get-selection"] = handlers.getSelection,
	["/api/get-output"] = handlers.getOutput,
	["/api/clone-instance"] = handlers.cloneInstance,
	["/api/move-instance"] = handlers.moveInstance,
	["/api/validate-script"] = handlers.validateScript,
	["/api/insert-asset"] = handlers.insertAsset,
	["/api/undo"] = handlers.undo,
	["/api/redo"] = handlers.redo,
	-- Execute Lua
	["/api/execute-lua"] = handlers.executeLua,
	-- Playtest control
	["/api/play-solo"] = handlers.playSolo,
	["/api/stop-play"] = handlers.stopPlay,
	-- Screenshot
	["/api/capture-screenshot"] = handlers.captureScreenshot,
	-- ViewportFrame rendering
	["/api/render-object-view"] = handlers.renderObjectView,
	-- Camera control
	["/api/focus-camera"] = handlers.focusCamera,
}

local function updateUIState()
	if pluginState.isActive then
		statusLabel.Text = "Connecting..."
		statusLabel.TextColor3 = Color3.fromRGB(245, 158, 11)
		statusIndicator.BackgroundColor3 = Color3.fromRGB(245, 158, 11)
		statusPulse.BackgroundColor3 = Color3.fromRGB(245, 158, 11)
		statusText.Text = "CONNECTING"
		if pluginState.consecutiveFailures == 0 then
			detailStatusLabel.Text = "HTTP: ...  MCP: ..."
		else
			detailStatusLabel.Text = "HTTP: X  MCP: X"
		end
		detailStatusLabel.TextColor3 = Color3.fromRGB(245, 158, 11)
		connectButton.Text = "Disconnect"
		connectButton.TextColor3 = Color3.fromRGB(255, 255, 255)
		startPulseAnimation()

		-- Reset steps to connecting state
		step1Dot.BackgroundColor3 = Color3.fromRGB(245, 158, 11)
		step1Label.Text = "1. HTTP server reachable (connecting...)"
		step2Dot.BackgroundColor3 = Color3.fromRGB(245, 158, 11)
		step2Label.Text = "2. MCP bridge connected (connecting...)"
		step3Dot.BackgroundColor3 = Color3.fromRGB(245, 158, 11)
		step3Label.Text = "3. Ready for commands (connecting...)"
		pluginState.mcpWaitStartTime = nil
		troubleshootLabel.Visible = false
		
		if not buttonHover then
			connectButton.BackgroundColor3 = Color3.fromRGB(239, 68, 68)
		end
		
		
		urlInput.TextEditable = false
		urlInput.BackgroundColor3 = Color3.fromRGB(55, 65, 81)
		urlInput.BorderColor3 = Color3.fromRGB(75, 85, 99)
	else
		statusLabel.Text = "Disconnected"
		statusLabel.TextColor3 = Color3.fromRGB(239, 68, 68)
		statusIndicator.BackgroundColor3 = Color3.fromRGB(239, 68, 68)
		statusPulse.BackgroundColor3 = Color3.fromRGB(239, 68, 68)
		statusText.Text = "OFFLINE"
		detailStatusLabel.Text = "HTTP: X  MCP: X"
		detailStatusLabel.TextColor3 = Color3.fromRGB(239, 68, 68)
		connectButton.Text = "Connect"
		connectButton.TextColor3 = Color3.fromRGB(255, 255, 255)
		stopPulseAnimation()

		-- Reset steps to offline state
		step1Dot.BackgroundColor3 = Color3.fromRGB(239, 68, 68)
		step1Label.Text = "1. HTTP server reachable (offline)"
		step2Dot.BackgroundColor3 = Color3.fromRGB(239, 68, 68)
		step2Label.Text = "2. MCP bridge connected (offline)"
		step3Dot.BackgroundColor3 = Color3.fromRGB(239, 68, 68)
		step3Label.Text = "3. Ready for commands (offline)"
		pluginState.mcpWaitStartTime = nil
		troubleshootLabel.Visible = false
		
		if not buttonHover then
			connectButton.BackgroundColor3 = Color3.fromRGB(16, 185, 129)
		end
		
		
		urlInput.TextEditable = true
		urlInput.BackgroundColor3 = Color3.fromRGB(55, 65, 81)
		urlInput.BorderColor3 = Color3.fromRGB(99, 102, 241)
	end
end

local function activatePlugin()
	pluginState.serverUrl = urlInput.Text

	pluginState.isActive = true
	pluginState.consecutiveFailures = 0
	pluginState.currentRetryDelay = 0.5
	screenGui.Enabled = true
	updateUIState()

	pcall(function()
		HttpService:RequestAsync({
			Url = pluginState.serverUrl .. "/ready",
			Method = "POST",
			Headers = {
				["Content-Type"] = "application/json",
			},
			Body = HttpService:JSONEncode({
				pluginReady = true,
				timestamp = tick(),
			}),
		})
	end)

	if not pluginState.connection then
		pluginState.connection = RunService.Heartbeat:Connect(function()
			local now = tick()
			local currentInterval = pluginState.consecutiveFailures > 5 and pluginState.currentRetryDelay
				or pluginState.pollInterval
			if now - pluginState.lastPoll > currentInterval then
				pluginState.lastPoll = now
				pollForRequests()
			end
		end)
	end
end

local function deactivatePlugin()
	pluginState.isActive = false
	updateUIState()

	pcall(function()
		HttpService:RequestAsync({
			Url = pluginState.serverUrl .. "/disconnect",
			Method = "POST",
			Headers = {
				["Content-Type"] = "application/json",
			},
			Body = HttpService:JSONEncode({
				timestamp = tick(),
			}),
		})
	end)

	if pluginState.connection then
		pluginState.connection:Disconnect()
		pluginState.connection = nil
	end
	
	pluginState.consecutiveFailures = 0
	pluginState.currentRetryDelay = 0.5
end

connectButton.Activated:Connect(function()
	if pluginState.isActive then
		deactivatePlugin()
	else
		activatePlugin()
	end
end)

button.Click:Connect(function()
	screenGui.Enabled = not screenGui.Enabled
end)

plugin.Unloading:Connect(function()
	deactivatePlugin()
end)

updateUIState()
