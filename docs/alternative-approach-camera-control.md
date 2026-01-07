# Alternative Approach: Camera Control + Screenshot

## Problem with ViewportFrame
ViewportFrame in Roblox **cannot have its pixels read directly**. It requires:
- Parenting to ScreenGui
- Using CaptureService (same limitations as regular screenshot)
- Doesn't work in play mode
- Has 2-5 second delay

## Better Solution: Camera Control

Instead of ViewportFrame, implement:

###handlers.focusCamera = function(requestData)
    local instancePath = requestData.instancePath
    local angle = requestData.angle or "iso"
    local distance = requestData.distance

    -- Get target instance
    local target = getInstanceByPath(instancePath)
    
    -- Calculate bounding box
    local size, center = getModelBoundingBox(target)
    
    -- Position camera using angle presets
    local cameraPos = center + (angleOffset * distance)
    
    -- Set Studio camera
    workspace.CurrentCamera.CFrame = CFrame.new(cameraPos, center)
    workspace.CurrentCamera.Focus = CFrame.new(center)
    
    return {success = true, camera = {...}}
end
```

### Usage
```javascript
// Focus camera on object
focus_camera({instancePath: "game.Workspace.Part", angle: "iso"})

// Then take screenshot  
capture_screenshot()
```

## Benefits
✅ Works in Edit mode (where screenshot works)
✅ Full camera control
✅ Angle presets
✅ Auto-distance calculation
✅ No API limitations
✅ Immediate (no ViewportFrame render delay)

## Implementation Priority
This is **much simpler and more reliable** than ViewportFrame approach.
Should replace ViewportFrame rendering entirely.
