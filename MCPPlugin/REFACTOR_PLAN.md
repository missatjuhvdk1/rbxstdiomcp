# MCP Plugin — Clean-Sheet Refactor Plan

> Status: **proposal**. No code written yet. Once approved, this becomes the
> living plan for the refactor. Each phase has a clear deliverable, a
> verification step, and references to both the **legacy source** and the
> **golden-rules reference**.

---

## 1. Goal & approach

The current `studio-plugin/plugin.luau` is a 7,022-line god file that violates
nearly every rule in `better-plugin/BuilderTool/ARCHITECTURE.md`. Rather than
zigzag-refactoring in place (which guarantees half-states where neither model
is intact), we **rebuild the plugin from scratch in a new folder**, treating
the legacy file purely as a *behavioural specification* and BuilderTool as
the *structural reference*.

### Working layout — during the refactor

```
workspace/
├── studio-plugin/          ← LEGACY. Read-only reference. Do not touch.
│                            "What does this endpoint return?" → check here.
├── better-plugin/          ← GOLDEN RULES. Read-only reference.
│                            "How is this kind of thing structured?" → check here.
├── MCPPlugin/              ← NEW. Where all real work happens.
│   ├── ARCHITECTURE.md     ← MCP-plugin-specific contract (modelled on BuilderTool's)
│   ├── CLAUDE.md           ← agent rules pointer
│   ├── REFACTOR_PLAN.md    ← this file, moved here once Phase 1 lands
│   ├── aftman.toml, wally.toml, stylua.toml, selene.toml
│   ├── rbxstudio-plugin.project.json
│   ├── src/{app,runtime,domain,ui,assets}/
│   └── tools/golden/check.lune.luau
├── src/                    ← TS MCP server. UNCHANGED throughout.
└── ...
```

### After cutover (Phase 7)

```
workspace/
├── studio-plugin/          ← the NEW plugin (MCPPlugin/ contents moved in)
├── studio-plugin-legacy/   ← old plugin.luau, archived. Keep for one release,
│                            then delete in a follow-up commit.
├── better-plugin/          ← stays forever as the golden reference
└── src/                    ← TS server, unchanged
```

### Why clean-sheet, not in-place

| In-place refactor | Clean-sheet rebuild (this plan) |
|---|---|
| Every commit leaves the file in a partial-rewrite state | Every commit leaves both versions intact |
| Risk of subtle behaviour drift hidden under churn | Behaviour is **verified** at each phase against the legacy file |
| Hard to roll back a phase | Roll back = `rm -rf MCPPlugin/` |
| LLM/reviewer context-switches between old and new in one file | One folder = one mental model |
| Decompiler-style cargo-culting (copy a bad pattern by accident) | Re-derive each module from the contract, then port the *logic* |

---

## 2. Non-negotiables (carried from BuilderTool ARCHITECTURE.md)

Every file in `MCPPlugin/src/` must satisfy these from commit #1:

1. **`--!strict` on line 1.** Always. No `--!nonstrict`, no `--!nocheck`.
2. **No globals.** No `_G`, `shared`, `getfenv`, `setfenv`, `loadstring`.
   State flows through the one typed `Context`, built once in
   `app/Plugin.client.luau` and passed by argument.
3. **Layer direction is one-way:** `app → ui → domain → runtime`. `runtime/`
   depends on Roblox and `Packages/` only — nothing else in the project.
   No upward `require`s, no cycles.
4. **`game:GetService(...)` only in `runtime/Services.luau`.**
5. **`Instance.new` of GUI and React rendering only under `ui/`.**
6. **Every mutation of the user's data model goes through
   `ctx.history:record(name, fn)`.** One MCP request → one undo step.
7. **Every connection, Instance, BindToRenderStep, and React root is
   Janitor-tracked at creation.** Teardown is one `ctx.janitor:Destroy()`.
8. **One responsibility per module, ≤ ~400 lines (~600 hard cap with a
   top-of-file justification comment).**
9. **`MAX 7,022 lines`** — yes, we just made up a new rule: **no file may be
   larger than the current `plugin.luau`**. (Sanity guard. The real limit is
   §8.)

---

## 3. The MCP-plugin `Context` shape

This is the analogue of BuilderTool's `Context` (§5), adapted for an
HTTP-bridge plugin instead of a viewport-tools plugin:

```lua
--!strict
export type Context = {
    services:  Services.Services,         -- game:GetService handles
    plugin:    PluginHandles.Handles,     -- plugin, toolbar, button, widget, activationChanged
    constants: Constants.Constants,       -- frozen: endpoints, timeouts, companion tags
    settings:  Settings.Settings,         -- mutable, typed setters: serverUrl, pollInterval, retry…
    logger:    Logger.Logger,             -- LogService.MessageOut capture buffer
    http:      HttpClient.HttpClient,     -- thin RequestAsync wrapper, one call site
    history:   History.History,           -- ChangeHistoryService recording wrapper
    actionLog: ActionLog.ActionLog,       -- in-memory undo/redo tracking (for get_history)
    polling:   Polling.Polling,           -- Heartbeat→/poll loop
    bridge:    Dispatcher.Dispatcher,     -- processRequest router (== ToolHost)
    janitor:   Janitor.Janitor,           -- root teardown scope
}
```

Differences vs BuilderTool worth noting:

| BuilderTool has | We have instead | Why |
|---|---|---|
| `selection` | nothing | The MCP plugin never owns a selection; tools that need it call `services.selection` directly via a `get_selection` handler |
| `viewport` (raycast, adornments) | nothing | No in-viewport interaction; the closest analog is `render/` helpers for screenshots, owned per-handler |
| `tools` (ToolHost) | `bridge` (Dispatcher) | Same shape: one active dispatch target, routes events to a registry of handlers |
| `input` (UIS) | `polling` (HTTP) | Same role: one adapter, one event source, fans events to the dispatcher |
| — | `logger`, `http`, `actionLog` | New: HTTP-bridge plugin needs explicit log capture, an HTTP gateway, and a parallel undo log (the legacy plugin's most subtle invariant) |

`Constants`/`Settings` are mostly the same shape — frozen vs mutable, namespaced
setting keys, schema-versioned migration.

---

## 4. Final target file tree (inside `MCPPlugin/src/`)

```
src/
├── init.meta.json                   ← { className: "Folder", attributes: { Plugin: "MCPServer" } }
├── app/
│   └── Plugin.client.luau           ← ~70 lines. Bootstrap. Only auto-run script.
├── runtime/
│   ├── Runtime.luau                 ← Context type + Runtime.new constructor
│   ├── Services.luau                ← THE only game:GetService call site
│   ├── Constants.luau               ← endpoints, timeouts, companion tags, frozen
│   ├── Settings.luau                ← serverUrl/pollInterval/retry; typed setters; migration
│   ├── PluginHandles.luau           ← toolbar, button, widget, activationChanged signal
│   ├── Logger.luau                  ← LogService.MessageOut capture buffer
│   ├── History.luau                 ← TryBeginRecording wrapper + source-edit decoupling
│   ├── ActionLog.luau               ← _pendingActionLog / actionHistory / redoHistory
│   ├── http/
│   │   ├── HttpClient.luau          ← RequestAsync wrapper, retry-aware
│   │   └── Polling.luau             ← Heartbeat-driven /poll loop, exponential backoff
│   ├── instance/
│   │   ├── Path.luau                ← getInstanceByPath, getInstancePath
│   │   ├── Serialize.luau           ← THE one canonical serializeValue (legacy has 3 copies)
│   │   └── Convert.luau             ← convertPropertyValue (Vector3/Color3/Enum/BrickColor coercion)
│   ├── script/
│   │   ├── Lines.luau               ← splitLines/joinLines
│   │   └── Validator.luau           ← validateLuaSyntax
│   ├── testsession/
│   │   ├── Companions.luau          ← inject + cleanup + tagging
│   │   ├── ServerCompanion.luau     ← REAL .luau (was a 600-line embedded string)
│   │   └── ClientCompanion.luau     ← REAL .luau (was an embedded LocalScript string)
│   └── render/
│       ├── Base64.luau              ← pure
│       ├── Camera.luau              ← resolveCameraDirection, applyLightingPreset, getModelBoundingBox
│       ├── Screenshot.luau          ← CaptureService + AssetService
│       └── Viewport.luau            ← off-screen ViewportFrame render
├── domain/
│   ├── handler/
│   │   ├── Handler.luau             ← Handler contract (== BuilderTool's Tool.luau)
│   │   ├── HandlerRegistry.luau     ← explicit-require typed registry (== ToolRegistry)
│   │   └── Dispatcher.luau          ← processRequest router (== ToolHost)
│   └── handlers/
│       ├── FileTreeHandlers.luau         ← get_file_tree, search_files, get_project_structure
│       ├── PlaceHandlers.luau            ← get_place_info, get_services, get_selection, get_output
│       ├── InstanceHandlers.luau         ← properties/children/search/searchByProperty/class_info
│       ├── PropertyHandlers.luau         ← set/massSet/massGet/setCalculated/setRelative
│       ├── CreationHandlers.luau         ← create*/massCreate*/delete/smart+massDuplicate/insertAsset
│       ├── ScriptHandlers.luau           ← getSource/setSource/editScript/searchScript/grep/getFunction/findReplace/validate
│       ├── AttributeHandlers.luau        ← get/set/getAll/delete
│       ├── TagHandlers.luau              ← get/add/remove/getTagged
│       ├── HierarchyHandlers.luau        ← cloneInstance, moveInstance
│       ├── HistoryHandlers.luau          ← undo, redo, get_history
│       ├── ExecuteLuaHandler.luau        ← execute_lua (its own file; large, sensitive)
│       ├── PlaytestHandlers.luau         ← play_solo, stop_play (drives testsession/)
│       └── RenderHandlers.luau           ← capture_screenshot, render_object_view, focus_camera
├── ui/
│   ├── App.luau                     ← React root component
│   ├── RuntimeContext.luau          ← React context whose value IS the typed Context
│   ├── theme/
│   │   └── Theme.luau               ← semantic color tokens, follows Studio theme
│   ├── hooks/
│   │   ├── useRuntime.luau
│   │   ├── useSignal.luau           ← subscribe + setState + MANDATORY disconnect
│   │   └── useStatus.luau           ← derived: HTTP ok? MCP connected? retry state?
│   └── components/
│       ├── DockShell.luau           ← outer frame + ScrollingFrame + layout
│       ├── Header.luau              ← title + version + status pill
│       ├── ConnectionPanel.luau     ← URL input + connect button
│       ├── StatusPanel.luau         ← status label + step rows + troubleshoot
│       ├── StepRow.luau             ← one indicator row
│       └── PulseDot.luau            ← the animated status dot
└── assets/.gitkeep
```

**Module-size projection** (worst cases — none over the 600-line cap):

| Module | Est. lines | Notes |
|---|---|---|
| `ScriptHandlers.luau` | ~550 | 9 handlers, the most complex group. Justification comment required. |
| `ExecuteLuaHandler.luau` | ~450 | Sandbox + serialization. Its own file for sanity. |
| `RenderHandlers.luau` | ~400 | Depends on `render/Viewport` for the heavy lifting. |
| `testsession/ServerCompanion.luau` | ~400 | Real .luau, no longer a quoted string. |
| Everything else | < 300 | Most modules ~50–200 lines. |

---

## 5. Phase plan

Each phase produces a buildable, working plugin. Phases land sequentially; we
do not start phase N+1 until phase N is signed off.

> **Reference key:** `[L<n>–<m>]` = `studio-plugin/plugin.luau` line range
> (the spec). `[BT/<path>]` = `better-plugin/BuilderTool/<path>` (the pattern).

### Phase 1 — Project skeleton & toolchain  *(target: 1 session, low risk)*

**Goal:** `rojo build` produces a plugin that loads in Studio, shows a button,
opens an empty widget, and unloads cleanly. No MCP behaviour yet.

**Deliverables:**

- `MCPPlugin/aftman.toml` — pin rojo 7.7.0-rc.1, lune 0.10.4, selene 0.28.0, stylua 2.0.2 [BT/-]
- `MCPPlugin/wally.toml` — React 17.1.0, ReactRoblox 17.1.0, Janitor 1.18.1 [BT/wally.toml]
- `MCPPlugin/stylua.toml`, `MCPPlugin/selene.toml`
- `MCPPlugin/.gitignore` — `Packages/`, `*.rbxm`, `*.rbxmx`, `sourcemap.json`, `wally.lock`?
- `MCPPlugin/rbxstudio-plugin.project.json` — Rojo target, packages `src/` as a Plugin model
- `MCPPlugin/ARCHITECTURE.md` — adapted from `better-plugin/BuilderTool/ARCHITECTURE.md`,
  MCP-plugin-specific: handler contract instead of tool contract, polling instead
  of input, no viewport/selection sections, add HTTP-bridge section
- `MCPPlugin/CLAUDE.md` — agent pointer, lifted nearly verbatim from BuilderTool's
- `MCPPlugin/src/init.meta.json` — `{ className: "Folder", attributes: { Plugin: "MCPServer" } }`
- `MCPPlugin/src/app/Plugin.client.luau` — minimal: toolbar + button + empty dock widget + janitor.
  Matches [BT/app/Plugin.client.luau] structure. No React mount yet (Phase 6).
- Empty `src/{runtime,domain,ui,assets}/` with `.gitkeep`s
- `MCPPlugin/tools/golden/check.lune.luau` — initially-passing CI gate script.
  Implements §16 table: --!strict gate, no-globals grep, service quarantine,
  ui quarantine, render-step pairing, decompiler-banner regex, layer invariant.
- `MCPPlugin/REFACTOR_PLAN.md` — this document, moved into the new folder

**Verification (sign-off):**
- [ ] `wally install` succeeds; `Packages/` populated
- [ ] `rojo build MCPPlugin/rbxstudio-plugin.project.json -o MCPPlugin.rbxm` succeeds
- [ ] Drag `MCPPlugin.rbxm` into a Studio Plugins folder → button appears in "MCP Integration" toolbar
- [ ] Clicking the button opens an empty dock widget
- [ ] Reinstalling the plugin in the same session leaves no orphan widgets/CoreGui folders
- [ ] `lune run MCPPlugin/tools/golden/check.lune.luau` is green
- [ ] `stylua --check MCPPlugin/src` and `selene MCPPlugin/src` are green

---

### Phase 2 — Runtime layer  *(target: 1–2 sessions, low-medium risk)*

**Goal:** All `runtime/` modules built. Plugin can connect to the MCP server,
poll, respond to a hard-coded `/api/ping` handler, and disconnect cleanly. No
real handlers yet.

**Deliverables (in build order):**

| Module | Spec ref | Pattern ref | Est. lines |
|---|---|---|---|
| `runtime/Services.luau` | [L1–18] | [BT/runtime/Services.luau] | ~40 |
| `runtime/Constants.luau` | [L54–56, L1257–1264, L5856–5864] | [BT/runtime/Constants.luau] | ~50 |
| `runtime/PluginHandles.luau` | [L1246–1271] | [BT/runtime/PluginHandles.luau] | ~40 |
| `runtime/Settings.luau` | [L1250–1265, L1437] | [BT/runtime/Settings.luau] | ~150 |
| `runtime/Logger.luau` | [L1233–1244] | (new pattern) | ~60 |
| `runtime/http/HttpClient.luau` | [L145–161, L1786–1794, L1917–1931] | (new pattern) | ~80 |
| `runtime/instance/Path.luau` | [L1650–1664, L2108–2130] | (new) | ~80 |
| `runtime/instance/Serialize.luau` | [L219–340, L743–818, L1156–1185] **(3 dupes → 1!)** | (new) | ~150 |
| `runtime/instance/Convert.luau` | [L1703–1775] | (new) | ~100 |
| `runtime/script/Lines.luau` | [L1666–1701] | (new) | ~50 |
| `runtime/script/Validator.luau` | [L3866–3902] (`validateLuaSyntax`) | (new) | ~50 |
| `runtime/History.luau` | [L1933–2106] (distilled) | [BT/runtime/History.luau] | ~120 |
| `runtime/ActionLog.luau` | [L1187–1231 + L5283–5481 helpers] | (new pattern) | ~150 |
| `runtime/http/Polling.luau` | [L1781–1915] (sans UI pokes — those are signals now) | (new pattern) | ~150 |
| `runtime/Runtime.luau` | (assembly) | [BT/runtime/Runtime.luau] | ~80 |

**Key design notes for Phase 2:**

- `Polling.luau` exposes a **plain signal** for status changes (`onStatus`,
  `onConnected`, `onError`). It must not poke any UI labels directly — that
  was the worst coupling in the legacy file (`step1Dot.BackgroundColor3 = ...`
  inside `pollForRequests`).
- `History.luau` returns the same sentinel-driven decision table that lives
  in legacy `processRequest` (`_isSourceEditOnly`, `_didNotMutate`,
  `_mutatesUnknown`) — but as a structured `RecordResult` type, not a
  property-bag hack on the response. See [L1985–2095] for the exact rules.
- `ActionLog.luau` keeps the "two parallel undo channels" property documented
  at [L1985–2007]: CHS waypoints for trusted mutators, plus a plugin-side
  log with `scriptEdits` snapshots for source-only edits.
- `Polling.luau` owns its own `Heartbeat:Connect` connection in a Janitor
  passed by the caller. No `pluginState.connection` module-level variable.

**Verification (sign-off):**
- [ ] All Phase-1 checks still pass
- [ ] Plugin connects to MCP server when activated (status: "Connected")
- [ ] Plugin disconnects cleanly on deactivate or plugin reload
- [ ] One temporary `/api/ping` handler registered inline: returns `{ ok = true }`.
      MCP server tool `ping` returns successfully.
- [ ] Plugin survives 100 reinstalls in one Studio session with zero orphan
      instances or connections (heaped diff check)
- [ ] No `serializeValue` duplicates; no `buildEvalEnv` duplicates

---

### Phase 3 — Handler framework + read-only handlers  *(target: 1–2 sessions, low-medium risk)*

**Goal:** All read-only MCP tools work end-to-end against the new plugin.

**Framework modules:**

| Module | Spec ref | Pattern ref | Est. lines |
|---|---|---|---|
| `domain/handler/Handler.luau` | (the response contract from L1979) | [BT/domain/tool/Tool.luau] | ~70 |
| `domain/handler/Dispatcher.luau` | [L1966–2106] | [BT/domain/tool/ToolHost.luau] | ~180 |
| `domain/handler/HandlerRegistry.luau` | [L6805–6864] | [BT/domain/tool/ToolRegistry.luau] | ~80 |

**Read-only handler modules (in build order):**

| Module | Endpoints | Spec ref [L<n>–<m>] |
|---|---|---|
| `FileTreeHandlers.luau` | get_file_tree, search_files, get_project_structure | 2131–2213, 2169–2213, 2590–2741 |
| `PlaceHandlers.luau` | get_place_info, get_services, get_selection, get_output | 2214–2275, 4936–5037, 4970–5037 |
| `InstanceHandlers.luau` | get_instance_properties/children, search_objects, search_by_property, get_class_info | 2276–2589 |
| `AttributeHandlers.luau` (get part) | get_attribute, get_attributes | 4607–4710, 4711–4766 |
| `TagHandlers.luau` (get part) | get_tags, get_tagged | 4802–4831, 4902–4935 |
| `ScriptHandlers.luau` (read part) | get_script_source, search_script, grep, get_script_function | 3632–3731, 4050–4137, 4138–4331, 4332–4462 |
| `HistoryHandlers.luau` (read part) | get_history | 5490–5538 |

**Verification (sign-off):**
- [ ] Every read-only MCP tool from `README.md`'s "43 AI Tools" list returns
      a response structurally identical to the legacy plugin
- [ ] `src/__tests__/` Jest suite passes against the new plugin (the TS side
      doesn't change)
- [ ] No mutation endpoints registered yet — calling one returns
      `{ error: "Unknown endpoint: …" }`

---

### Phase 4 — Mutation handlers + History  *(target: 2 sessions, medium risk)*

**Goal:** Every mutation tool works, every mutation is one Ctrl+Z, and the
source-edit undo decoupling (Bug 1 fix from the legacy file) still works.

**Modules added/extended:**

| Module | Endpoints | Spec ref |
|---|---|---|
| `PropertyHandlers.luau` | set/mass_set/mass_get/set_calculated/set_relative | 2742–2806, 2908–3013, 3411–3631 |
| `CreationHandlers.luau` | create_object/with_properties, mass_create*, delete_object, smart_duplicate, mass_duplicate, insert_asset | 2807–2906, 3014–3410, 5781–5868 |
| `HierarchyHandlers.luau` | clone_instance, move_instance | 5042–5151 |
| `AttributeHandlers.luau` (write part) | set_attribute, delete_attribute | 4655–4710, 4767–4801 |
| `TagHandlers.luau` (write part) | add_tag, remove_tag | 4832–4901 |
| `ScriptHandlers.luau` (write part) | set_script_source, edit_script, find_and_replace_in_scripts, validate_script | 3732–4049, 4463–4606, 5156–5280 |
| `HistoryHandlers.luau` (write part) | undo, redo | 5331–5489 |

**Key design notes for Phase 4:**

- **`Dispatcher.luau` is the only place that opens a CHS recording.** Handlers
  never call `ChangeHistoryService:TryBeginRecording` themselves. A handler
  returns a `RecordResult` (or just `nil` for read-only) and the dispatcher
  decides commit/cancel based on the legacy decision tree at [L2038–2095].
- **`ScriptHandlers.luau` is where the source-edit decoupling lives.** It
  returns `{ _isSourceEditOnly = true, scriptEdits = {...} }` for edits that
  can't be captured by CHS, exactly mirroring the legacy behaviour at
  [L1985–2007]. `HistoryHandlers.undo` restores via direct `Source =` assignment.
- **LLM-stomp prevention** (legacy [L48–53]): destructive handlers refuse to
  operate on instances tagged with `TEST_COMPANION_TAG` or named
  `_MCPTestCompanion`. This logic lives in a shared helper in
  `runtime/testsession/Companions.luau` and is called by `delete_object`,
  `edit_script`, `set_script_source`, `set_property` (when setting `Disabled`),
  and `move_instance`.

**Verification (sign-off):**
- [ ] Every mutation tool works
- [ ] Each tool call produces exactly one Ctrl+Z entry in Studio
- [ ] `edit_script` followed by `undo` actually restores the original source
      (this is the "Bug 1" the legacy code's L1985–2007 comment fixes)
- [ ] `execute_lua` mutations that *add or remove instances* are tracked;
      property-only mutations from execute_lua remain in the "accepted edge
      case" bucket, matching the legacy comment at [L2059–2064]
- [ ] Companion-tag refusals work: a script with `_MCPTestCompanion` tag
      cannot be deleted/edited via MCP tools

---

### Phase 5 — Heavy handlers: test sessions, execute_lua, render  *(target: 2 sessions, medium-high risk)*

**Goal:** Play-solo + execute_lua + screenshots + viewport render all work.

**Modules added:**

| Module | Spec ref |
|---|---|
| `runtime/testsession/Companions.luau` | [L20–55, L1050–1155] (cleanup, tagging, injection) |
| `runtime/testsession/ServerCompanion.luau` | [L64–675] **as a real .luau file** with `__MCP_SERVER_URL__` / `__MCP_SESSION_ID__` placeholders substituted at injection time. Includes the loadstring eval relay, log streaming, and the client-relay remotes. |
| `runtime/testsession/ClientCompanion.luau` | [L684–1032] **as a real .luau file** with the same placeholders. Bound to `_MCPClientHello/Logs/Relay` remotes. |
| `domain/handlers/PlaytestHandlers.luau` | [L5870–5994] play_solo, stop_play |
| `domain/handlers/ExecuteLuaHandler.luau` | [L5543–5779] execute_lua — its own file due to size and the complete-sandbox concerns |
| `runtime/render/Base64.luau` | [L6000–6038] |
| `runtime/render/Camera.luau` | [L6256–6321] resolveCameraDirection, applyLightingPreset, getModelBoundingBox |
| `runtime/render/Screenshot.luau` | [L6046–6228] |
| `runtime/render/Viewport.luau` | [L6398–6691] off-screen ViewportFrame rendering |
| `domain/handlers/RenderHandlers.luau` | [L6046–…, L6398–…, L6700–6803] thin wrappers over `runtime/render/*` |

**Key design notes for Phase 5:**

- **Companion scripts as real .luau files.** Rojo packages them as
  `ModuleScript`s. At injection time, `Companions.luau`:
  1. Reads the ModuleScript source via `script.Source` (the *module containing
     the companion source* — meta-pattern; we use a sentinel comment to
     extract the literal text body, or expose the source as a frozen string
     constant returned from the module).
  2. Substitutes placeholders.
  3. Constructs a new `Script` / `LocalScript`, sets `.Source`, parents into
     `ServerScriptService` / `StarterPlayer.StarterPlayerScripts`.
- This eliminates the 1,100-line embedded-string blob. The companion files
  are now syntax-highlighted, linted, and `--!strict`-checked like everything
  else.
- **`ExecuteLuaHandler` sandbox** preserves the legacy `buildEvalEnv` exactly
  — `getfenv`/`setfenv`/`loadstring` are intentionally allowed *inside the
  sandbox closure*, not in the plugin's own code (the §15 rule applies to
  plugin source, not to environments we construct for user code).

**Verification (sign-off):**
- [ ] `play_solo` starts a test session, streams output back, and ends
      cleanly on `stop_play`
- [ ] `execute_lua` runs in the edit DataModel and rolls back on error
- [ ] `run_live_lua` (the eval branch) targets server and client correctly
- [ ] `capture_screenshot` returns base64 PNG ≤ 16MB raw
- [ ] `render_object_view` produces ViewportFrame screenshots that match
      legacy output pixel-for-pixel (or close enough; document any diff)
- [ ] `focus_camera` with each of the 11 angle presets behaves identically
- [ ] No orphan `_MCPTestCompanion*` instances after a test session ends

---

### Phase 6 — React-lua UI  *(target: 1–2 sessions, medium risk)*

**Goal:** The dock widget renders through React. Status updates via signal
subscription. Visually matches v2.0.0.

**Modules added:**

| Module | Pattern ref |
|---|---|
| `ui/RuntimeContext.luau` | [BT/ui/RuntimeContext.luau] |
| `ui/hooks/useRuntime.luau` | [BT/ui/hooks/useRuntime.luau] |
| `ui/hooks/useSignal.luau` | [BT/ui/hooks/useSignal.luau] — **mandatory disconnect** |
| `ui/hooks/useStatus.luau` | (new) derives `{ httpOk, mcpConnected, retryDelay, troubleshoot }` from polling signals |
| `ui/theme/Theme.luau` | [BT/ui/theme/Theme.luau] — semantic tokens, follows Studio theme |
| `ui/components/Header.luau` | replaces legacy [L1283–1371] |
| `ui/components/ConnectionPanel.luau` | replaces legacy [L1389–1454] |
| `ui/components/StatusPanel.luau` | replaces legacy [L1456–1638] |
| `ui/components/StepRow.luau` | factors legacy `createStepRow` [L1525] |
| `ui/components/PulseDot.luau` | replaces legacy [L1609–1638] pulse animation, via `react-spring` or `useEffect` |
| `ui/components/DockShell.luau` | outer ScrollingFrame + composition |
| `ui/App.luau` | root |
| `app/Plugin.client.luau` (final form) | mounts React root into `CoreGui` ScreenGui; Janitor owns root |

**Key design notes for Phase 6:**

- **Components read state only via `useRuntime()` + `useSignal()`.** No
  component imports anything from `runtime/` or `domain/` directly. No
  component calls `ctx.history`, `ctx.services`, or any HTTP method.
- **All Phase-1 placeholder UI from `app/Plugin.client.luau` is deleted.**
  The bootstrap is now exactly the [BT/app/Plugin.client.luau] shape:
  build Context → build toolbar+button+widget → mount React → wire activation
  → register `plugin.Unloading → janitor:Destroy()`.
- **Janitor mandate audited.** The teardown checklist from
  `ARCHITECTURE.md §12` is verified by hand.

**Verification (sign-off):**
- [ ] Visual diff against legacy v2.0.0 is acceptable (screenshots in PR)
- [ ] Status transitions (Offline → Connecting → Waiting for MCP → Connected
      → Retrying → Error) all work
- [ ] Troubleshoot label appears after 8s of HTTP-ok-but-MCP-down state
- [ ] Reinstalling the plugin in one session leaves zero orphans
- [ ] All Phase 5 sign-offs still hold

---

### Phase 7 — Cutover  *(target: 1 session, low risk)*

**Goal:** `MCPPlugin/` becomes `studio-plugin/`. The repo's existing build
and install flows work with the new structure.

**Steps:**

1. `mv studio-plugin studio-plugin-legacy` — keep the old one one release
   for archaeology, marked deprecated in its `README.md`
2. `mv MCPPlugin studio-plugin` — the new home
3. Update `scripts/install-plugin.mjs`:
   - Build via `rojo build studio-plugin/rbxstudio-plugin.project.json -o studio-plugin/MCPPlugin.rbxm`
   - Then copy to `%LOCALAPPDATA%/Roblox/Plugins/`
4. Update root `README.md`:
   - Studio Plugin Setup section points at the rojo build, or a Releases
     download (CI-built artifact)
   - Remove the committed `MCPPlugin.rbxmx` from the repo (per §2 source rule)
5. Update root `.gitignore` to ignore `studio-plugin/Packages/`,
   `studio-plugin/*.rbxm`, `studio-plugin/sourcemap.json`
6. Update `src/__tests__/` integration tests if any reference the old plugin
   path (skim — likely none)
7. Tag a release (`v3.0.0`?) — the version bump is justified by the binary
   format change (`.rbxmx` legacy → `.rbxm` from rojo)

**Verification (sign-off):**
- [ ] `npm run build` (server) still succeeds
- [ ] `npm run typecheck` (server) still succeeds
- [ ] `rojo build studio-plugin/rbxstudio-plugin.project.json` succeeds
- [ ] Built `.rbxm` installs, connects to the server, and runs all 43+ tools
- [ ] `studio-plugin-legacy/plugin.luau` still exists for archaeology
- [ ] `better-plugin/` is untouched
- [ ] CI gate script in `studio-plugin/tools/golden/check.lune.luau` is green

---

## 6. Cross-cutting concerns

### 6.1 Behaviour preservation

**No endpoint changes.** Every endpoint listed in `studio-plugin/plugin.luau`'s
`endpointHandlers` table [L6805–6864] is present in `domain/handler/HandlerRegistry.luau`
with the same name, accepting the same `requestData` shape, returning the
same response shape. The TS-side `bridge-service.ts` does not need a single
edit.

**No protocol changes.** Same `/poll` + `/response` HTTP contract.
Same JSON shapes. Same UUID-tracked request/response pairs.

**No undo-semantics changes.** The exact behaviour at legacy [L1985–2095]
(commit/cancel decisions, source-edit decoupling, descendant-count delta for
`execute_lua`) is preserved in `runtime/History.luau` + `domain/handler/Dispatcher.luau`.

**LLM-stomp protections preserved.** Companion scripts can still not be
deleted, edited, or unparented through MCP tools, exactly as today.

### 6.2 Strict-mode discipline

`--!strict` from line 1 forces real types. Realistic gotchas to plan for:

- `Instance` property reads are typed `any` only when accessed through
  `(inst :: any).Foo` — we'll prefer typed casts (`inst :: BasePart`) where
  we know the class.
- `HttpService:JSONDecode` returns `any` — every handler entry point will
  cast to a typed request shape it owns.
- `pcall` return-type pattern matches BuilderTool's: `local ok, err = pcall(...)`
  with `err: any` annotated explicitly when needed.

We anticipate ~30 minutes of type-fixing per handler module during Phase 3/4.
Better to eat that cost than to use `--!nonstrict` and pretend.

### 6.3 Naming & comments

Carry BuilderTool's conventions verbatim:

- Modules / types / React components: `PascalCase`
- Locals / functions / fields: `camelCase`
- Constants (frozen): `SCREAMING_SNAKE`
- Booleans: `is*/has*/should*`
- Persisted endpoint paths: stable `lowercase-kebab-case` (e.g. `"/api/edit-script"`)
- Every module has a top-of-file WHY-comment explaining its single
  responsibility and the contract it implements (BuilderTool's pattern).

### 6.4 The CI gate (`tools/golden/check.lune.luau`)

This is the §16 quality table, executable. Lives in `MCPPlugin/tools/golden/`
from Phase 1 and grows as the codebase grows. Checks:

1. Every `MCPPlugin/src/**/*.luau` line 1 is `--!strict`
2. `grep -r "_G\|shared\|getfenv\|setfenv\|loadstring" src/` returns nothing
   (with a documented exception for the `ExecuteLuaHandler` sandbox closure)
3. `game:GetService(` appears only in `src/runtime/Services.luau`
4. `Instance.new("Frame"|"TextLabel"|"TextButton"|"ScrollingFrame"|"ScreenGui"|"UICorner"|"UIPadding"|"UIGradient"|"UIListLayout"|"TextBox"|"ImageLabel")` appears only under `src/ui/`
5. `React.createElement` and `ReactRoblox.createRoot` appear only under `src/ui/` and `src/app/`
6. Every `BindToRenderStep(` has a paired `UnbindFromRenderStep(` in the same module (n/a for this plugin probably — we use Heartbeat instead)
7. The decompiler-banner regex finds nothing
8. No upward `require` path (layer invariant)
9. `stylua --check src/` is clean
10. `selene src/` is clean

Pre-commit hook can invoke this; CI runs it on every PR.

---

## 7. Open questions & risks

### 7.1 Things I want to decide before Phase 1 starts

| # | Question | Default if no answer |
|---|---|---|
| Q1 | Folder name during work: `MCPPlugin/` or `studio-plugin-v2/`? | `MCPPlugin/` (matches the binary name + BuilderTool convention) |
| Q2 | Do we keep `wally.lock` in git? | Yes (reproducible builds) |
| Q3 | Plugin model name attribute: `Plugin = "MCPServer"` or `Plugin = "MCPPlugin"`? | `MCPServer` (matches the legacy display name) |
| Q4 | After cutover, delete legacy in the same PR or wait one release? | Wait one release: keep `studio-plugin-legacy/` in git history, gone in v3.0.1 |
| Q5 | Companion .luau injection mechanism: extract source from `script.Source` of a ModuleScript, or expose a frozen string from the module? | Frozen string (simpler, type-safe, no `script.Source` runtime read) |

### 7.2 Risks called out

- **R1 — React-lua learning curve.** If we hit a wall in Phase 6, we can
  ship Phase 1–5 (which already gives ~80% of the architectural wins) and
  do Phase 6 as a follow-up. The new plugin still works; the UI just stays
  imperative-but-quarantined under `ui/` temporarily.
- **R2 — Companion script syntax drift.** The legacy companion is a 1,100-line
  blob with subtle interaction with `StudioTestService:EndTest()`. Risk of a
  copy-paste bug. Mitigation: keep one test-session round-trip in the Phase 5
  manual checklist.
- **R3 — Strict-mode type tax.** Real estimate is ~2–4 hours across the whole
  codebase. Cheaper than fixing the bugs strict mode catches.
- **R4 — Render-handler pixel diff.** ViewportFrame rendering ([L6398–6691])
  has many magic offsets. Pixel-identical output is not guaranteed. Phase 5
  sign-off allows visual approximation with a written diff note.

---

## 8. Reference index

When implementing module X, read these:

| New module | Legacy lines | BuilderTool reference |
|---|---|---|
| `app/Plugin.client.luau` | 1246–1271, 6934–7022 | `app/Plugin.client.luau` |
| `runtime/Runtime.luau` | (assembly) | `runtime/Runtime.luau` |
| `runtime/Services.luau` | 1–18 | `runtime/Services.luau` |
| `runtime/Constants.luau` | 54–56, 1257–1264, 5856–5864 | `runtime/Constants.luau` |
| `runtime/Settings.luau` | 1250–1265, 1437 | `runtime/Settings.luau` |
| `runtime/PluginHandles.luau` | 1246–1271 | `runtime/PluginHandles.luau` |
| `runtime/Logger.luau` | 1233–1244 | — |
| `runtime/http/HttpClient.luau` | 145–161, 1786–1794, 1917–1931 | — |
| `runtime/http/Polling.luau` | 1781–1915 | (loosely: `runtime/Input.luau`) |
| `runtime/History.luau` | 1933–2106 | `runtime/History.luau` |
| `runtime/ActionLog.luau` | 1187–1231, 5283–5481 | — |
| `runtime/instance/Path.luau` | 1650–1664, 2108–2130 | — |
| `runtime/instance/Serialize.luau` | 219, 743, 1156 (dedupe) | — |
| `runtime/instance/Convert.luau` | 1703–1775 | — |
| `runtime/script/Lines.luau` | 1666–1701 | — |
| `runtime/script/Validator.luau` | 3866–3902 | — |
| `runtime/testsession/Companions.luau` | 20–55, 1050–1155 | — |
| `runtime/testsession/ServerCompanion.luau` | 64–675 | — |
| `runtime/testsession/ClientCompanion.luau` | 684–1032 | — |
| `runtime/render/Base64.luau` | 6000–6038 | — |
| `runtime/render/Camera.luau` | 6256–6321 | — |
| `runtime/render/Screenshot.luau` | 6046–6228 | — |
| `runtime/render/Viewport.luau` | 6398–6691 | — |
| `domain/handler/Handler.luau` | (the dispatch contract from 1966–2106) | `domain/tool/Tool.luau` |
| `domain/handler/Dispatcher.luau` | 1966–2106 | `domain/tool/ToolHost.luau` |
| `domain/handler/HandlerRegistry.luau` | 6805–6864 | `domain/tool/ToolRegistry.luau` |
| `domain/handlers/FileTreeHandlers.luau` | 2131–2213, 2169–2213, 2590–2741 | — |
| `domain/handlers/PlaceHandlers.luau` | 2214–2275, 4936–5037, 4970–5037 | — |
| `domain/handlers/InstanceHandlers.luau` | 2276–2589 | — |
| `domain/handlers/PropertyHandlers.luau` | 2742–2806, 2908–3013, 3411–3631 | — |
| `domain/handlers/CreationHandlers.luau` | 2807–2906, 3014–3410, 5781–5868 | — |
| `domain/handlers/ScriptHandlers.luau` | 3632–4049, 4050–4137, 4138–4331, 4332–4462, 4463–4606, 5156–5280 | — |
| `domain/handlers/AttributeHandlers.luau` | 4607–4801 | — |
| `domain/handlers/TagHandlers.luau` | 4802–4935 | — |
| `domain/handlers/HierarchyHandlers.luau` | 5042–5151 | — |
| `domain/handlers/HistoryHandlers.luau` | 5331–5538 | — |
| `domain/handlers/ExecuteLuaHandler.luau` | 5543–5779 | — |
| `domain/handlers/PlaytestHandlers.luau` | 5870–5994 | — |
| `domain/handlers/RenderHandlers.luau` | 6046–6228, 6398–6691, 6700–6803 | — |
| `ui/*` | 1283–1638 (composition reference only) | All of `ui/` |

---

## 9. Sign-off

Approving this plan means:

- [ ] You're happy with the **target file tree** in §4
- [ ] You're happy with the **phase boundaries** in §5 and what each ships
- [ ] You've answered (or accepted defaults for) the open questions in §7.1
- [ ] You're OK with the working folder being `MCPPlugin/` until cutover

Once approved, I start Phase 1.

---

*Document version 1. Update in-place as decisions change; this doc is the
contract for the refactor.*
