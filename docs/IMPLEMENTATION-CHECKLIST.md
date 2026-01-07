# ✅ Visual Improvements Implementation Checklist

## 🎯 Priority 1: ViewportFrame Rendering (HIGHEST IMPACT)

### Plugin.luau Changes
- [ ] Copy viewport rendering implementation from `viewport-rendering-implementation.lua`
- [ ] Add camera angle presets table
- [ ] Add lighting presets function
- [ ] Add bounding box calculation helper
- [ ] Add `handlers.renderObjectView` function
- [ ] Add `handlers.renderMultiView` function (optional but recommended)
- [ ] Register handlers in route table:
  ```lua
  ["/api/render-object-view"] = handlers.renderObjectView,
  ["/api/render-multi-view"] = handlers.renderMultiView,
  ```

### TypeScript Changes (src/tools/index.ts)
- [ ] Add `renderObjectView()` method to RobloxStudioTools class
- [ ] Add `renderMultiView()` method (optional)
- [ ] Copy PNG conversion logic from `captureScreenshot()`

### MCP Tool Registration (src/index.ts)
- [ ] Add `render_object_view` tool definition
- [ ] Add `render_multi_view` tool definition
- [ ] Add descriptions emphasizing this is PRIMARY visual feedback tool

### Testing
- [ ] Test basic rendering: `render_object_view({instancePath: "game.Workspace.Baseplate"})`
- [ ] Test different angles: iso, front, top
- [ ] Test custom angles: `{pitch: 30, yaw: 45}`
- [ ] Test in Edit mode
- [ ] Test in Play mode (should work!)
- [ ] Test with different lighting presets
- [ ] Test with transparent/grid backgrounds
- [ ] Test multi-view rendering

**Estimated Time**: 2-4 hours
**Impact**: ⭐⭐⭐⭐⭐ (Transformative)

---

## 🎯 Priority 2: Camera Control

### Plugin.luau Changes
- [ ] Add `handlers.setCameraView` function
  ```lua
  -- Move Studio camera to specific position/angle
  -- Support both instance paths and Vector3 targets
  ```
- [ ] Add `handlers.focusSelection` function
  ```lua
  -- Like pressing F in Studio
  -- Optionally takes instance paths
  ```
- [ ] Register handlers in route table

### TypeScript Changes
- [ ] Add `setCameraView()` method
- [ ] Add `focusSelection()` method

### MCP Tool Registration
- [ ] Add `set_camera_view` tool
- [ ] Add `focus_selection` tool

### Testing
- [ ] Test focusing on specific object
- [ ] Test focusing on Vector3 position
- [ ] Test different angle presets
- [ ] Test smooth camera transitions

**Estimated Time**: 1-2 hours
**Impact**: ⭐⭐⭐⭐ (Very useful with existing screenshot)

---

## 🎯 Priority 3: Workspace State Management

### Plugin.luau Changes
- [ ] Add state serialization function
  ```lua
  -- Serialize workspace hierarchy, properties, scripts
  -- Return state ID
  ```
- [ ] Add state restoration function
  ```lua
  -- Restore from saved state
  -- Handle conflicts/errors gracefully
  ```
- [ ] Add `handlers.saveWorkspaceState`
- [ ] Add `handlers.restoreWorkspaceState`
- [ ] Add `handlers.listWorkspaceStates` (see saved states)
- [ ] Register handlers in route table

### TypeScript Changes
- [ ] Add `saveWorkspaceState()` method
- [ ] Add `restoreWorkspaceState()` method
- [ ] Add `listWorkspaceStates()` method

### MCP Tool Registration
- [ ] Add `save_workspace_state` tool
- [ ] Add `restore_workspace_state` tool
- [ ] Add `list_workspace_states` tool

### Testing
- [ ] Save state, make changes, restore - verify restoration
- [ ] Test with scripts (source code restored?)
- [ ] Test with properties
- [ ] Test with large workspaces
- [ ] Test error handling for missing states

**Estimated Time**: 3-4 hours
**Impact**: ⭐⭐⭐⭐ (Fixes "stop doesn't restore" issue)

---

## 🎯 Priority 4: Enhanced Play/Stop

### Plugin.luau Changes
- [ ] Modify `handlers.playSolo` to auto-save state before playing
  ```lua
  -- Save state with ID: "pre_play_state"
  -- Start play mode
  -- Return state ID in response
  ```
- [ ] Modify `handlers.stopPlay` to offer restoration
  ```lua
  -- Stop play
  -- Check if restore is requested
  -- Restore pre-play state if available
  ```

### TypeScript Changes
- [ ] Update `playSolo()` to accept `saveState: boolean` option
- [ ] Update `stopPlay()` to accept `restoreState: boolean` option

### MCP Tool Descriptions
- [ ] Update `play_solo` description to mention auto-state-save
- [ ] Update `stop_play` description to mention restoration option

### Testing
- [ ] Play → create objects → stop with restore → verify cleanup
- [ ] Play → stop without restore → verify changes persist
- [ ] Multiple play/stop cycles

**Estimated Time**: 1 hour
**Impact**: ⭐⭐⭐ (Better play/stop UX)

---

## 🎯 Optional: Advanced Visual Tools

### First-Person View Simulator
- [ ] `handlers.simulatePlayerView` - Place character, render first-person
- **Time**: 2 hours | **Impact**: ⭐⭐⭐

### Model Preview Generator
- [ ] `handlers.generateModelPreview` - Nice thumbnail generation
- **Time**: 1 hour | **Impact**: ⭐⭐

### Comparison View
- [ ] `handlers.compareBeforeAfter` - Side-by-side visual diff
- **Time**: 2 hours | **Impact**: ⭐⭐

### Bounding Box Visualization
- [ ] `handlers.visualizeBounds` - Show dimensions visually
- **Time**: 1 hour | **Impact**: ⭐⭐

### Play State Detection
- [ ] `handlers.getPlayState` - Detailed state info
- **Time**: 30 minutes | **Impact**: ⭐

---

## 📋 Quick Start (Minimum Viable Visual)

Want to get visual feedback ASAP? Do just this:

### ⚡ Quick Implementation (2 hours)
1. ✅ Copy viewport rendering Lua code to plugin
2. ✅ Add TypeScript wrapper
3. ✅ Add MCP tool definition
4. ✅ Test with one object

That's it! You now have AI visual feedback.

### 🎯 Recommended Implementation (4-6 hours)
1. ✅ ViewportFrame rendering (Priority 1)
2. ✅ Camera control (Priority 2)
3. ✅ Workspace state save/restore (Priority 3)

This gives you:
- ✅ AI can see what it creates
- ✅ AI can control camera
- ✅ Play/stop properly restores state

---

## 🧪 Testing Scenarios

### Visual Feedback Test
```javascript
// Create object
create_object("Part", "game.Workspace", "TestPart")

// Render it
render_object_view({
  instancePath: "game.Workspace.TestPart",
  angle: "iso"
})

// Expected: PNG image returned
```

### Camera Control Test
```javascript
// Focus camera
set_camera_view({
  target: "game.Workspace.TestPart",
  angle: "front",
  distance: 5
})

// Take screenshot
capture_screenshot()

// Expected: Screenshot of part from front angle
```

### State Management Test
```javascript
// Save state
save_workspace_state() // → stateId: "abc123"

// Make changes
create_object("Part", "game.Workspace", "Temp")

// Restore
restore_workspace_state({stateId: "abc123"})

// Expected: Temp part is gone
```

### Play/Stop with Restore Test
```javascript
// Save and play
play_solo({saveState: true})

// Create objects during play
execute_lua({code: "Instance.new('Part', workspace)"})

// Stop and restore
stop_play({restoreState: true})

// Expected: Workspace back to pre-play state
```

---

## 📊 Success Metrics

After implementing Priority 1 (ViewportFrame Rendering):

- [ ] AI can render any object from any angle ✅
- [ ] Rendering works in ALL Studio states (Edit/Play/Run) ✅
- [ ] Rendering completes in <500ms ✅
- [ ] Multiple renders can be done in succession ✅
- [ ] PNG images display correctly in AI response ✅

After implementing Priority 2 (Camera Control):

- [ ] Can programmatically position Studio camera ✅
- [ ] Screenshots now show what you want to see ✅

After implementing Priority 3 (State Management):

- [ ] Can save workspace state ✅
- [ ] Can restore to previous state ✅
- [ ] Play/stop now properly cleans up ✅

---

## 🚀 Rollout Plan

### Week 1: Core Visual (Priority 1)
- Implement ViewportFrame rendering
- Test thoroughly
- Get user feedback

### Week 2: Polish (Priority 2-3)
- Add camera control
- Add state management
- Integrate with existing tools

### Week 3: Advanced Features (Optional)
- First-person simulator
- Comparison views
- Other nice-to-haves

---

## 📝 Documentation Updates

After implementation, update:

- [ ] README.md - Add visual tools section
- [ ] Add examples showing AI using visual feedback
- [ ] Add screenshots of rendered objects
- [ ] Update tool count (28 → 32+ tools)
- [ ] Emphasize "AI can see what it creates" in marketing

---

## 🎉 Launch Messaging

New tagline ideas:
- "Now with AI visual feedback - your AI can see what it creates!"
- "Full visual + code integration for Roblox Studio"
- "The only MCP that gives AI eyes into Roblox Studio"

Forum post update:
- Emphasize viewport rendering as killer feature
- Show before/after examples
- Demo video of AI building and viewing simultaneously

---

## 🤔 Decision Points

### Resolution Defaults
- **Recommendation**: 512x512 for single views, 256x256 for multi-view
- Higher = better quality but slower
- Lower = faster but less detail

### Auto-Rendering
Should render_object_view be called automatically after create_object?
- **Pros**: Automatic visual feedback, better UX
- **Cons**: Extra tokens, slower responses
- **Recommendation**: Make it opt-in via tool parameter

### State Storage
Where to store workspace state snapshots?
- **Option 1**: In-memory (lost on plugin restart)
- **Option 2**: HttpService POST to MCP server (persists)
- **Option 3**: File in temp folder
- **Recommendation**: Start with in-memory, add persistence later

---

## 🐛 Known Issues / Gotchas

### ViewportFrame Limitations
- Cannot render particles in real-time (static only)
- Some special effects may not render correctly
- Humanoid animations won't play in viewport

### State Restoration
- Scripts that are running cannot be perfectly restored
- Some Roblox services (Players, etc.) cannot be serialized
- Very large workspaces may take time to serialize

### Camera Control
- Camera changes are immediate in Edit mode
- In Play mode, camera control may be limited
- Player character may override camera in some cases

---

## ✨ Final Notes

The ViewportFrame rendering system is the **game-changer**. It transforms your MCP from "great for code" to "complete visual + code integration".

**Start with Priority 1** - even a basic implementation will massively improve the user experience. The other priorities are important but not as transformative.

Good luck! 🚀
