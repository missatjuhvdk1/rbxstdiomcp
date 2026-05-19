# BuilderTool — Architecture & Engineering Standards

> Status: **frozen contract**. Code implements this document; it does not
> silently redesign it. A needed change is a dated amendment note in this
> file, not an undocumented divergence. Every reviewer and every agent reads
> this before touching `src/shared/BuilderTool/`.

---

## 1. Product scope

BuilderTool is a Roblox **Studio plugin**: an in-viewport building toolkit in
the spirit of F3X (Building Tools by F3X) and BTByStravant. The user opens a
**tool palette** (a dockable widget), picks a tool (Move, Resize, Rotate,
Paint, New Part, …), and all manipulation happens **in the 3D viewport** via
handles, hover highlights, and click/drag — not through form dialogs.

**In scope:** part-level geometry edits (move/resize/rotate/clone/delete),
appearance (color/material/surface), creation, alignment/snapping, selection.

**Out of scope (non-goals, keep them out unless this doc is amended):** terrain,
scripting/codegen, animation, networked/runtime gameplay code, anything that
ships inside the user's *place* — BuilderTool is edit-time tooling only.

**Distribution:** built to a single `.rbxm` and published to the Creator Store
as a plugin. It must survive install → uninstall → reinstall and version
upgrades with zero leaked instances, connections, or settings corruption.

---

## 2. Toolchain & tech stack

Managed by **aftman** (`aftman.toml` at repo root) — do not invoke
globally-installed tools, use the pinned versions:

| Tool | Version | Role |
|---|---|---|
| Rojo | `7.7.0-rc.1` | source ⇄ Roblox; builds the plugin `.rbxm` |
| Lune | `0.10.4` | headless Luau for tests / build tooling |
| selene | `0.28.0` | static analysis (gate, see §16) |
| StyLua | `2.0.2` | formatting (gate, see §16) |

- **Language:** Luau, `--!strict` in **every** file (§13). No `.lua`, only
  `.luau`.
- **UI:** React-lua (`jsdotlua` React + ReactRoblox), vendored under
  `Packages/` (§3). Function components + hooks only.
- **State:** one explicitly-constructed, fully-typed **`Context`** threaded by
  argument (§5). No globals, ever.
- **Source rule:** the repo is **pure source**. The plugin `.rbxm`, the place
  file, and `sourcemap.json` are build outputs — git-ignored, never committed
  (matches the root `.gitignore`). Binary assets that *are* inputs (icons) are
  the only committed binaries and live under `assets/`.

Formatting/lint settings are repo-wide and **not** overridable per file:
StyLua = tabs, width 4, column 120, `AutoPreferDouble` quotes, no statement
collapsing; selene = `roblox` std. Run both before every commit.

---

## 3. Repository & build layout

The plugin is one self-contained package:

```
src/shared/BuilderTool/
├── ARCHITECTURE.md          ← this file (the contract)
├── CLAUDE.md                ← condensed rules for agents (points here)
├── init.meta.json           ← root instance = Folder + build attributes
├── wally.toml               ← dependency manifest (React, Janitor, …)
├── Packages/                ← `wally install` output — git-ignored
├── app/
│   └── Plugin.client.luau   ← THE bootstrap (the only auto-run script)
├── runtime/                 ← leaf layer (Roblox-facing). See §4–§6.
├── domain/                  ← tool system + pure logic. See §6.
├── ui/                      ← React tree. See §11.
└── assets/                  ← committed icon binaries only
```

Build (from repo root):

```bash
wally install                               # restores Packages/ (first time)
rojo build builder-tool.project.json -o BuilderTool.rbxm
```

`builder-tool.project.json` (repo root) packages **only** this folder as the
plugin model — it is independent of `default.project.json` (which is the test
*place*). Drag `BuilderTool.rbxm` into `Plugins/`, or
`rojo serve builder-tool.project.json` for live iteration.

**Packaging detail:** the root is a `Folder` (via `init.meta.json`). The only
instance Studio auto-runs is `app/Plugin.client.luau` (a `LocalScript`).
Everything else is a `ModuleScript` and runs **only when required** — this is
why the bootstrap must be the single side-effecting entry point (§12). This
matches the proven pattern in this repo's example plugins; do not scatter
`*.client.luau`/`*.server.luau` scripts elsewhere in the tree.

---

## 4. Architecture: layers & the dependency invariant

Four layers. Dependencies point **one way only**:

```
app  ──►  ui  ──►  domain  ──►  runtime
                      └────────────┘   (domain & ui both read the typed Context)
runtime = leaf: depends on Roblox + Packages only, nothing in the package
```

| Layer | Owns | May require | May NOT require |
|---|---|---|---|
| `runtime/` | services, plugin handles, constants, settings, input adapter, history wrapper, raycast/adornment primitives | Roblox, `Packages/` | anything in `domain/`, `ui/`, `app/` |
| `domain/` | the Tool system, selection model, geometry/snap math, each concrete tool | `runtime/` | `ui/`, `app/` |
| `ui/` | React components, hooks, theme, the render root | `domain/`, `runtime/` | `app/` |
| `app/` | the bootstrap only | everything | — |

**Hard invariants (CI-enforced, §16):**

1. **No upward edges.** `domain/` never requires `ui/`; `runtime/` requires
   nothing in the package. Cycles are a design error, not a TODO.
2. **No globals.** `_G`/`shared`/`getfenv`/`setfenv`/`loadstring` are
   forbidden in `src/` (they are the SunAnimator anti-pattern, §15).
3. **Services are quarantined.** `game:GetService(...)` appears **only** in
   `runtime/Services.luau`. Everywhere else receives services through the
   `Context`.
4. **UI instances are quarantined.** `Instance.new("Frame" | "TextButton" |
   "ScreenGui" | …)` and React rendering appear **only** under `ui/`.
   `domain/` and `runtime/` never construct GUI.
5. **One responsibility per module**, ≤ ~400 lines (hard cap ~600 with a
   written justification comment at the top). A growing file is a missing
   module.

The point of (3) and (4) is the same lesson the SunAnimator refactor learned
the hard way: when raw Roblox coupling is confined to one named place, the
rest of the codebase is testable, renamable, and reviewable. That is the
*single* most important rule in this document.

---

## 5. The typed `Context` (dependency injection)

There is no global state. `runtime/Runtime.luau` exports a `Context` type and
a single `Runtime.new(plugin)` constructor. `app/Plugin.client.luau` builds
**exactly one** Context and passes it down by explicit argument. UI receives
the same object through a single React context provider (§11) — the React
context is only a *transport*; the typed object is the source of truth.

```lua
--!strict
export type Context = {
    services: Services.Services,        -- §1: game:GetService handles
    plugin:   PluginHandles.Handles,    -- plugin, toolbar, button, mouse, widget
    constants: Constants.Constants,     -- frozen (table.freeze)
    settings:  Settings.Settings,       -- mutable, typed setters, persisted
    input:     Input.Input,             -- UserInputService adapter
    history:   History.History,         -- ChangeHistoryService recording wrapper
    selection: Selection.Selection,     -- the selection model (§9)
    viewport:  Viewport.Viewport,       -- raycast + adornment primitives (§7)
    tools:     ToolHost.ToolHost,       -- active-tool manager (§6)
    janitor:   Janitor.Janitor,         -- root teardown scope (§12)
}
```

Design rules (carried over from this repo's runtime-context design, proven on
the SunAnimator refactor):

- **Lean.** The Context holds only true cross-cutting state. Pure helpers
  (geometry, snapping) are ordinary modules required where used — they are
  **not** hung off the Context. No god-object.
- **Typed.** Every field has a real type. `any` is allowed only for
  documented opaque Roblox-instance handles.
- **Mutability is explicit.** Immutable values live in `constants`
  (`table.freeze`d). Anything written at runtime lives in `settings` and is
  changed **only** through typed setters — so "who mutates this" is greppable.
- **Construction is centralized.** Every field is populated by
  `Runtime.new`. Nothing else mutates the Context *shape*.

---

## 6. The Tool system (the core)

A "tool" is the central abstraction. Each tool is a self-contained module
implementing one frozen interface. Only **one tool is active at a time**; the
`ToolHost` owns equip/unequip and routes all input to the active tool.

### 6.1 The `Tool` contract — `domain/tool/Tool.luau`

```lua
--!strict
export type ToolId = string  -- stable, lowercase, e.g. "move" (NEVER renamed once shipped — it is a persisted/settings key)

export type Tool = {
    id:    ToolId,
    name:  string,   -- display label
    icon:  string,   -- rbxassetid; sourced from assets/, never inline magic
    order: number,   -- palette sort key

    -- Lifecycle. equip/unequip are mandatory and MUST be symmetric:
    -- everything equip() creates/connects, unequip() destroys/disconnects.
    equip:   (self: Tool, ctx: Context) -> (),
    unequip: (self: Tool, ctx: Context) -> (),

    -- Input. Return true iff the event was consumed (stops propagation).
    onInputBegan:   ((self: Tool, ctx: Context, input: InputObject) -> boolean)?,
    onInputChanged: ((self: Tool, ctx: Context, input: InputObject) -> boolean)?,
    onInputEnded:   ((self: Tool, ctx: Context, input: InputObject) -> boolean)?,

    -- Reacts to the shared selection model changing (§9).
    onSelectionChanged: ((self: Tool, ctx: Context) -> ())?,

    -- Declarative options descriptor. UI renders it; the tool never builds
    -- GUI itself (invariant §4.4).
    options: ToolOptions?,
}
```

Tools are **declarative about UI**: a tool exposes an `options` descriptor
(typed: toggles, number fields, enum pickers) and the `ui/` layer renders the
panel. A tool that calls `Instance.new` or `React.createElement` is a bug.

### 6.2 `ToolHost` — `domain/tool/ToolHost.luau`

- Holds the active tool (or none). `host:equip(id)` calls the previous tool's
  `unequip`, then the new tool's `equip`. Equip is **idempotent and
  exception-safe**: if `equip` throws, the host rolls back to no-tool and the
  error surfaces — a half-equipped tool must never be reachable.
- Owns the **single** set of UserInputService connections (via `ctx.input`)
  and fans events to the active tool's handlers. Individual tools do **not**
  connect to UserInputService directly — they implement the handler methods.
  This is the antidote to SunAnimator's unbounded, never-cleaned connection
  sprawl.
- Each tool gets its **own child Janitor** from the host on equip; `unequip`
  destroys it. A tool cannot leak past its own equip scope.

### 6.3 Tool registry — `domain/tool/ToolRegistry.luau`

A typed table `{ [ToolId]: Tool }`, populated by explicit `require` of each
`domain/tools/<Name>Tool.luau`. **No dynamic/string-driven module loading**
(that was SunAnimator's `getfenv` DI — see §15). Adding a tool = add the
module + one registry line. The registry is the only place that enumerates
tools.

### 6.4 Adding a tool (the canonical recipe)

1. `domain/tools/FooTool.luau` returning a value satisfying `Tool`.
2. `equip` builds handles/highlights via `ctx.viewport`; connects nothing
   directly (handlers only); registers options via the `options` field.
3. Every mutation goes through `ctx.history:record(...)` (§8). No exceptions.
4. `unequip` is the exact mirror of `equip`.
5. Add it to `ToolRegistry`.
6. Add a Lune test for any pure math it introduced (§17).

---

## 7. Viewport interaction standards

Viewport primitives are Roblox-facing and live in `runtime/viewport/`
(`Raycaster`, `Adornments`). Tools orchestrate them through
`ctx.viewport` — tools never touch `workspace`/`CoreGui`/raycasting directly.

- **Raycasting:** mouse → world via
  `camera:ViewportPointToRay()` + `workspace:Raycast(origin, dir, params)`.
  `RaycastParams` use the `StudioSelectable` collision group and filter out
  the plugin's own adornment folder. One shared params object, not one per
  frame.
- **Adornment hygiene:** all 3D adornments (`Handles`, `ArcHandles`,
  `BoxHandleAdornment`, `SelectionBox`, `Highlight`) are parented to **one**
  plugin-owned folder created in `CoreGui` by `runtime/viewport`, named with
  a build-session suffix (so two plugin versions never collide), and added to
  the **root Janitor** at creation. Never parent adornments to `workspace`.
- **Per-frame work:** if a tool needs per-frame updates use
  `RunService:BindToRenderStep` with a **unique** name and **always**
  `UnbindFromRenderStep` in the tool's `unequip`/Janitor. An unbound render
  step is a forbidden defect (§15) — this is the single most damaging
  SunAnimator bug and CI/review must reject any `BindToRenderStep` whose
  matching unbind is not in the same module.
- **Snapping/grid:** geometry math (grid snap, surface snap, rotation
  increments) is **pure** and lives in `domain/Snapping.luau` /
  `domain/Geometry.luau` — no Roblox services, fully Lune-unit-testable.
  Tools call these; the viewport layer only renders the result.
- **Hover vs selection** are distinct visual states with distinct adornments;
  never reuse one instance for both.

---

## 8. Mutation discipline — undo/redo

**Every** change to the user's data model (any property write, parenting,
creation, deletion) goes through the history wrapper. No mutation outside a
recording. This is non-negotiable and is what makes the plugin trustworthy.

`runtime/History.luau` wraps the **modern** ChangeHistoryService recording
API (not the legacy `SetWaypoint`, which SunAnimator used):

```lua
--!strict
-- One user gesture = one recording = one undo step.
function History.record<T...>(self: History, name: string, mutate: () -> T...): T...
    local id = self._chs:TryBeginRecording(name)
    if not id then return mutate() end  -- already inside a recording: nest, don't double-open
    local results = table.pack(pcall(mutate))
    if not results[1] then
        self._chs:FinishRecording(id, Enum.FinishRecordingOperation.Cancel)
        error(results[2])
    end
    self._chs:FinishRecording(id, Enum.FinishRecordingOperation.Commit)
    return table.unpack(results, 2, results.n)
end
```

Rules:

- **One gesture, one recording.** A click-drag that moves parts is *one*
  `record("Move parts")`, opened on drag-begin, committed on drag-end — not
  one per frame.
- **Recording names are user-facing** (they appear in Edit ▸ Undo). Sentence
  case, action-first: `"Move parts"`, `"Resize part"`, `"Recolor 4 parts"`.
- **Failure cancels the recording** and re-raises — never leave a recording
  open and never half-commit.
- A tool that mutates outside `ctx.history:record` is a bug caught in review.

---

## 9. Selection model — `domain/Selection.luau`

BuilderTool keeps its **own** selection set (like F3X) so it controls
multi-select semantics and visuals, but it stays **bidirectionally synced**
with Studio's `Selection` service so the Explorer/Properties stay coherent:

- `Selection` owns an ordered set of `Instance`s + a `changed` signal.
- On Studio `Selection.SelectionChanged`, mirror in (filtered to selectable
  `BasePart`s the plugin can edit).
- On internal change, push to `Selection:Set(...)`.
- A re-entrancy guard prevents the sync loop from ping-ponging.
- Tools react via the `onSelectionChanged` hook, never by polling.
- Dead/destroyed instances are pruned on access — selection never holds a
  parented-to-nil reference.

---

## 10. Settings & persistence — `runtime/Settings.luau`

- `Settings` is the **typed in-memory mirror** of persisted preferences (grid
  size, snap on/off, rotation increment, last tool, theme follow-Studio).
- Read via fields; write **only** through typed setters; every setter persists
  through `plugin:SetSetting(KEY, value)` and fires a `changed` signal the UI
  subscribes to.
- All keys are namespaced (`"BuilderTool/<camelCaseKey>"`) and declared in one
  frozen `KEYS` table — no scattered string literals.
- A `SCHEMA_VERSION` integer is persisted. On load, run an explicit migration
  ladder (`v1→v2→…`); unknown/missing → defaults. Never `error` on a bad
  stored value — degrade to default and continue. (ResurfacePlugin's
  `currentVersion` legacy-transition check is the reference pattern.)
- No setting is read with `GetSetting` outside this module.

---

## 11. UI architecture (React-lua)

- **Function components + hooks only.** No class components, no
  `Roact.Component`. One component per file, file name = component name,
  PascalCase, returns the component.
- **No business logic in components.** Components read state and dispatch
  intent; all logic lives in `domain/`. A component never calls
  `ChangeHistoryService`, `Selection`, `workspace`, or `game:GetService`.
- **Context transport:** `ui/RuntimeContext.luau` is a React context whose
  value is the one typed `Context`. `ui/hooks/useRuntime.luau` returns it.
  Components reach services/tools/selection **only** through `useRuntime`.
- **Reactivity bridge:** `domain`/`runtime` expose plain signals
  (`BindableEvent.Event` or a tiny typed Signal). A `useSignal(signal, get)`
  hook subscribes and `setState`s — and **must disconnect in the effect
  cleanup** (the `useValue` pattern in ResurfacePlugin is the reference; the
  disconnect is mandatory, not optional).
- **The render root** is created and owned by `app/Plugin.client.luau`:
  one `ScreenGui`/widget container, `ReactRoblox.createRoot`,
  `root:render(App)`. The root, the container, and the React root are all
  added to the root Janitor (`janitor:Add(root, "unmount")`,
  `janitor:Add(container, "Destroy")`).
- **Theme:** `ui/theme/Theme.luau` exposes semantic tokens
  (`background`, `accent`, `textPrimary`, …) and follows
  `settings:GetColor`/Studio theme via `StudioService` — no hard-coded
  `Color3` literals in components.
- **Keys & lists:** stable keys for mapped children (a `createUniqueKey`-style
  helper), never array index.

---

## 12. Plugin lifecycle & resource management

`app/Plugin.client.luau` is **thin** and is the *only* file with top-level
side effects. Exact sequence:

1. `local ctx = Runtime.new(plugin)` — builds services, constants, settings
   (with migration), the root `Janitor`, input, history, selection, viewport,
   tool host.
2. Create the toolbar + toggle button (`plugin:CreateToolbar`,
   `:CreateButton`); create the dock widget
   (`plugin:CreateDockWidgetPluginGui`).
3. Create the React render root into the widget; `root:render(App)` with the
   Context provider.
4. Wire activation: button click toggles widget visibility / plugin
   activation; `plugin.Deactivation` and the active-tool state stay in sync
   (ResurfacePlugin's `LocalStore.isPluginActive` ⇄ `plugin:Activate/Deactivate`
   pattern, but the state lives in `ctx.settings`/a typed signal, not a
   module singleton).
5. Register **one** `plugin.Unloading` connection whose body is
   `ctx.janitor:Destroy()`.

**The Janitor mandate:** every connection, every Instance, every
`BindToRenderStep`, the React root, the widget, the toolbar — *everything*
disposable is `:Add`ed to a Janitor at the moment it is created. Teardown is
a single `ctx.janitor:Destroy()`. There are **no** ad-hoc `events = {}`
arrays and **no** "I'll disconnect it later" (both are SunAnimator defects,
§15). Teardown checklist that `plugin.Unloading` must satisfy:

- [ ] active tool `unequip`ed (its child Janitor destroyed)
- [ ] all UserInputService / RenderStep connections gone
- [ ] CoreGui adornment folder destroyed
- [ ] React root unmounted, widget/ScreenGui destroyed
- [ ] toolbar button state reset, plugin deactivated if active
- [ ] no `BuilderTool*` instance left in `CoreGui`/`workspace`

If reinstalling the plugin in a session leaves a duplicate widget or a stray
CoreGui folder, teardown is broken — treat as a release blocker.

---

## 13. Code style & conventions

- **`--!strict` is the first line of every `.luau` file.** No `--!nonstrict`,
  no `--!nocheck`. Type errors are build-breaking, not advisory.
- **No file headers from decompilers.** The literal
  `-- AI use of source code prohibited.` and any decompiler banner are
  **banned** (CI regex, §16). This is original source. Third-party code that
  is *legitimately* vendored keeps its real upstream licence header and lives
  isolated under `Packages/` or a clearly-marked `runtime/thirdparty/`.
- **Naming:**

  | Kind | Convention | Example |
  |---|---|---|
  | Module / type / React component | `PascalCase` | `ToolHost`, `MoveTool`, `ToolPalette` |
  | Local var / function / field | `camelCase` | `activeTool`, `recordMove` |
  | Constant (frozen) | `SCREAMING_SNAKE` | `GRID_DEFAULT`, `SCHEMA_VERSION` |
  | Boolean | `is*/has*/should*` prefix | `isDragging`, `hasSelection` |
  | React hook | `use*` | `useRuntime`, `useSignal` |
  | Persisted `ToolId` / setting key | stable `lowercase` | `"move"`, `"BuilderTool/gridSize"` |
  | File | == the value it returns | `ToolHost.luau` ⇒ `ToolHost` |

- **No abbreviations, no brand/meme tokens, no `script.Name`-as-type.** The
  SunAnimator refactor exists precisely to undo `_g`, `chs`, `g_e`,
  `objIsType`. Write `changeHistory`, not `chs`.
- **OOP** (only where genuinely stateful — tools, models): explicit
  `require` + a typed `__index` chain. **Never** `getfenv`-injected `super`,
  never `script.Name` pushed into a `type` array. Prefer plain function
  modules and closures over classes when there is no inheritance.
- **Errors:** validate at boundaries; `error`/`assert` with an actionable
  message for programmer mistakes; degrade gracefully for bad *user/persisted*
  data (never crash the plugin over a stale setting or a deleted instance).
  Wrap fallible user-triggered actions so one failure can't wedge the tool.
- **Comments** explain *why*, not *what*. A module that needs a comment to
  explain *what* it does is too big or badly named.
- **No** `wait`/`spawn`/`delay` (deprecated) — use `task.*`. No
  `while true do` without a Janitor-bound exit.

---

## 14. Module & file conventions

- One module = one responsibility = one return value. ≤ ~400 lines; ~600 hard
  cap and only with a top-of-file justification comment naming the planned
  split seam (the SunAnimator monoliths are the cautionary tale).
- `init.luau`/`init.client.luau` only where Rojo packaging requires it
  (`app/Plugin.client.luau`, package root). Never use `init.luau` as a
  dumping ground.
- `.meta.json` is used **only** for what Rojo can't express in the tree
  (root `className`, build attributes). It is not a config side-channel.
- Requires are explicit and relative (`require(script.Parent.Foo)` /
  `require(ctx...)`), grouped at the top, never inside hot paths, never
  dynamic/string-built.

---

## 15. Forbidden anti-patterns (the SunAnimator catalogue)

These are concrete defects observed in the legacy example plugin. Each is a
**review-blocking** error in BuilderTool, not a style nit:

| # | Anti-pattern | Real legacy form | Why it is banned |
|---|---|---|---|
| A1 | Global state facade | `_G.MoonGlobal`, `_g = _G.MoonGlobal` in 132 files | untestable, unrenamable, any module can corrupt state → use the typed `Context` (§5) |
| A2 | `getfenv`/`setfenv` DI | `_g.req("Object")` injecting `super` into caller scope | hidden dependencies, not type-checkable → explicit `require` + typed `__index` (§13) |
| A3 | `script.Name` as type | `table.insert(ctor.type, 1, script.Name)` + `objIsType` | rename = breakage, no static check → real Luau types |
| A4 | Unbound `BindToRenderStep` | `BindToRenderStep("MA_PartSelect", …)` never unbound | runs forever after unload; CPU + leak → mandatory paired unbind in same module (§7) |
| A5 | Ad-hoc connection arrays | `events = {}` + manual disconnect loop | always misses some → single root **Janitor** (§12) |
| A6 | Decompiler header | `-- AI use of source code prohibited.` | not original source; provenance/licensing → banned by CI (§16) |
| A7 | Decompiled 3rd-party in tree | `KojoGizmos/*` pasted into source | unaudited, unlicensed → vendor via Wally, isolate, keep real licence |
| A8 | `newproxy()` nil sentinel | `_g.NIL_VALUE = newproxy()` | papering over bad optional design → use `T?` and explicit checks |
| A9 | Service handles on a global | `_g.chs`, `_g.http`, `_g.input_serv` | see A1; also abbreviated → `runtime/Services.luau` only (§4.3) |

Additionally banned (general): `loadstring`, `_G`/`shared`, mutating
`Context` shape outside `Runtime.new`, business logic inside React
components, `Instance.new` of GUI outside `ui/`, `game:GetService` outside
`runtime/Services.luau`, committing build artifacts.

---

## 16. Quality gates (CI seams)

A change is not "done" until all gates are green. These are mechanical and
non-negotiable; they encode the invariants of §4 and §15 so review can focus
on design, not policing.

| Gate | Check |
|---|---|
| Format | `stylua --check src/shared/BuilderTool` is clean |
| Lint | `selene src/shared/BuilderTool` is clean |
| Strict | every `.luau` first line is `--!strict` |
| Build | `rojo build builder-tool.project.json` succeeds; output byte-identical to last baseline unless the diff is intended |
| No globals | grep finds no `_G`, `shared`, `getfenv`, `setfenv`, `loadstring` in `src/` |
| Service quarantine | `game:GetService(` appears only in `runtime/Services.luau` |
| UI quarantine | `Instance.new("Frame"/…)` & `React.createElement` only under `ui/` |
| Render-step safety | every `BindToRenderStep(` has a matching `UnbindFromRenderStep(` in the same module |
| No decompiler banner | regex for the prohibited header finds nothing |
| Layer invariant | no `require` path goes up the layer order (§4) |

These should land as a Lune script under `tools/` (mirroring this repo's
existing `tools/golden/` containment-guard approach) and be run pre-commit.
Until that script exists, reviewers enforce the table by hand — the rules
apply from commit #1, the automation is the convenience.

---

## 17. Testing strategy

- **Pure logic is unit-tested with Lune** (`tools/` or a `tests/` Lune
  runner): `domain/Geometry.luau`, `domain/Snapping.luau`,
  `domain/Selection.luau` (pruning/dedup), the `History.record`
  commit/cancel/nest behaviour, settings migration ladder. These have **no**
  Roblox-service dependency by design — that is *why* §4.3/§4.4 exist.
- **Viewport behaviour is verified in Studio** against a written manual
  matrix per tool (equip → manipulate → undo → redo → unequip → reinstall
  leaves nothing). The teardown checklist (§12) is part of every release
  sign-off.
- A bug fix lands with the test that would have caught it.

---

## 18. Glossary

| Term | Meaning |
|---|---|
| **Context** | the one typed DI object built by `Runtime.new`, threaded everywhere (§5) |
| **Tool** | a module satisfying the `Tool` contract; one active at a time (§6) |
| **ToolHost** | owns equip/unequip + input routing; one per Context (§6.2) |
| **Recording** | one ChangeHistoryService undo step = one user gesture (§8) |
| **Janitor** | the single teardown scope; everything disposable is added to it (§12) |
| **Adornment** | a CoreGui-parented 3D handle/highlight; plugin-owned, Janitor-tracked (§7) |
| **Gate** | a mechanical CI check that must be green to merge (§16) |

---

### Amendment log

- *2026-05-16* — Document created. Decisions locked: React-lua UI; typed
  Context DI; modern ChangeHistoryService recording API; Janitor lifecycle;
  pure-source Rojo plugin build. Grounded against this repo's existing
  toolchain, the SunAnimator refactor design docs, and the ResurfacePlugin /
  SunAnimator example plugins.
