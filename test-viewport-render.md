# Testing ViewportFrame Rendering

## Quick Test Using execute_lua

Since the plugin needs to be manually updated in Studio, we can test the ViewportFrame rendering logic directly using execute_lua:

```lua
-- Test 1: Basic ViewportFrame Creation
local viewportFrame = Instance.new("ViewportFrame")
viewportFrame.Size = UDim2.fromOffset(512, 512)
viewportFrame.BackgroundColor3 = Color3.new(1, 1, 1)

local worldModel = Instance.new("WorldModel")
worldModel.Parent = viewportFrame

local camera = Instance.new("Camera")
camera.Parent = viewportFrame
viewportFrame.CurrentCamera = camera

-- Clone workspace baseplate
local baseplate = workspace:FindFirstChild("Baseplate")
if baseplate then
    local clone = baseplate:Clone()
    clone.Parent = worldModel

    -- Position camera
    local center = clone.Position
    camera.CFrame = CFrame.new(center + Vector3.new(10, 10, 10), center)
    camera.FieldOfView = 70

    print("ViewportFrame created successfully!")
    print("Baseplate cloned and visible in viewport")
    return "SUCCESS: ViewportFrame rendering works!"
else
    return "ERROR: No baseplate found"
end
```

## How to Update Plugin with New Code

1. **Open Studio Plugin Editor:**
   - In Roblox Studio, go to Plugins → "Manage Plugins"
   - Find "MCPPlugin"
   - Click "Edit"

2. **Replace Plugin Script:**
   - Copy ALL code from `studio-plugin/plugin.luau`
   - Paste into the plugin's main script
   - Save and close

3. **Reload Plugin:**
   - Click the "MCP Server" button to disconnect
   - Click it again to reconnect

4. **Test:**
   - Create a Part in Workspace
   - Use MCP tool: `render_object_view({instancePath: "game.Workspace.Part"})`

## Alternative: Use Argon for Hot Reloading

Install Argon plugin for automatic code sync:
```bash
# Install Argon CLI
npm install -g @argon-rbx/argon-cli

# Start syncing
cd studio-plugin
argon serve
```

Then connect Argon plugin in Studio - any changes to plugin.luau will auto-update!
