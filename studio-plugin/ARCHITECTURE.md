# MCPPlugin — Architecture & Engineering Standards

> Status: **frozen contract**. Code implements this document; it does not
> silently redesign it. A needed change is a dated amendment note in this
> file, not an undocumented divergence. Every reviewer and every agent reads
> this before touching `studio-plugin/src/`.
>
> Modelled on `better-plugin/BuilderTool/ARCHITECTURE.md`. Where the two
> documents disagree, this one wins for the MCP plugin; where they agree, the
> BuilderTool wording is canonical and we mirror it verbatim — that is a
> feature, not redundancy.

---

## 1. Product scope

MCPPlugin is a Roblox **Studio plugin** that acts as the in-Studio bridge for
the Model Context Protocol (MCP) server in `../src/`. The user opens a
**dockable widget**, points it at the MCP server URL, and the plugin polls the
server for tool-call requests, executes them inside the edit/run DataModel,
and POSTs the responses back. The MCP server in turn exposes those tools to
AI clients (Claude Desktop, Claude Code, …).

**In scope:** instance/property/script/tag/attribute inspection and
mutation; off-screen ViewportFrame rendering and screenshot capture;
play-solo orchestration with server/client companion scripts; an
`execute_lua` sandbox; undo/redo bookkeeping for everything above.

**Out of scope (non-goals, keep them out unless this doc is amended):**
shipping anything inside the user's *place* (the plugin is edit-time tooling
only — except for the deliberately injected, tagged, sweepable test-session
companions during a play-solo round); networked gameplay code; Studio
extensions beyond the toolbar button + dock widget surface.

**Distribution:** built to a single `.rbxm` via Rojo and dropped into the
user's Studio Plugins folder (or installed via `scripts/install-plugin.mjs`).
It must survive install → uninstall → reinstall and version upgrades with
zero leaked instances, connections, settings corruption, or orphan
`_MCPTestCompanion*` scripts in the open place.

---

## 2. Toolchain & tech stack

Managed by **aftman** (`studio-plugin/aftman.toml`). Versions are pinned exactly;
bump deliberately, never floating:

| Tool | Version | Role |
|---|---|---|
| Rojo | `7.7.0-rc.1` | source ⇄ Roblox; builds the plugin `.rbxm` |
| Lune | `0.10.4` | headless Luau for tests / the §16 CI gate |
| Wally | `0.3.2` | package manager; restores `Packages/` |
| selene | `0.28.0` | static analysis (gate, §16) |
| StyLua | `2.0.2` | formatting (gate, §16) |

- **Language:** Luau, `--!strict` in **every** file (§13). No `.lua`, only
  `.luau`.
- **UI:** React-lua (`jsdotlua/react` + `jsdotlua/react-roblox`), vendored
  under `Packages/` via Wally (§3). Function components + hooks only. (UI
  lands in Phase 6 of the refactor.)
- **State:** one explicitly-constructed, fully-typed **`Context`** threaded
  by argument (§5). No globals, ever.
- **Source rule:** the repo is **pure source**. The plugin `.rbxm`,
  `sourcemap.json`, and `Packages/` are build outputs — git-ignored, never
  committed. The only committed binary inputs are icons under `src/assets/`.

Formatting/lint settings are repo-wide and **not** overridable per file:
StyLua = tabs, width 4, column 120, `AutoPreferDouble` quotes, no statement
collapsing; selene = `roblox` std. Run both before every commit.

---

## 3. Repository & build layout

The plugin is one self-contained package:

```
studio-plugin/
├── ARCHITECTURE.md          ← this file (the contract)
├── CLAUDE.md                ← condensed rules for agents (points here)
├── REFACTOR_PLAN.md         ← the rolling refactor plan (Phases 1–7)
├── aftman.toml              ← pinned tool versions
├── wally.toml               ← dependency manifest (React, Janitor, …)
├── wally.lock               ← tracked (reproducible builds, §7.1 Q2)
├── stylua.toml              ← format config
├── selene.toml              ← lint config
├── .gitignore               ← Packages/, *.rbxm, sourcemap.json, …
├── rbxstudio-plugin.project.json   ← Rojo target (Plugin model)
├── Packages/                ← `wally install` output — git-ignored
├── src/
│   ├── init.meta.json       ← root: className=Folder, attributes.Plugin="MCPServer"
│   ├── app/
│   │   └── Plugin.client.luau   ← THE bootstrap (the only auto-run script)
│   ├── runtime/             ← leaf layer (Roblox-facing). See §4–§6.
│   ├── domain/              ← handler system + pure logic. See §6.
│   ├── ui/                  ← React tree. See §11.
│   └── assets/              ← committed icon binaries only
└── tools/
    └── golden/
        └── check.lune.luau  ← §16 CI gate, executable
```

Build (from `studio-plugin/`):

```bash
wally install                                                   # restores Packages/
rojo build rbxstudio-plugin.project.json -o MCPPlugin.rbxm     # produces the plugin model
```

Drag `MCPPlugin.rbxm` into Studio's Plugins folder, or
`rojo serve rbxstudio-plugin.project.json` for live iteration.

**Packaging detail:** the root is a `Folder` (via `src/init.meta.json`) with
attribute `Plugin="MCPServer"`. The only instance Studio auto-runs is
`src/app/Plugin.client.luau` (a `LocalScript` by Rojo convention from the
`.client.luau` suffix). Everything else is a `ModuleScript` and runs **only
when required** — which is why the bootstrap must be the single
side-effecting entry point (§12). Do not scatter `*.client.luau`/`*.server
.luau` scripts elsewhere in the tree.

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
| `runtime/` | services, plugin handles, constants, settings, logger, HTTP client + polling loop, history wrapper, action log, instance/script helpers, render primitives, test-session companions | Roblox, `Packages/` | anything in `domain/`, `ui/`, `app/` |
| `domain/` | the Handler system, every MCP tool handler, request dispatch | `runtime/` | `ui/`, `app/` |
| `ui/` | React components, hooks, theme, the render root | `domain/`, `runtime/` | `app/` |
| `app/` | the bootstrap only | everything | — |

**Hard invariants (CI-enforced, §16):**

1. **No upward edges.** `domain/` never requires `ui/`; `runtime/` requires
   nothing in the package. Cycles are a design error, not a TODO.
2. **No globals.** `_G`/`shared`/`getfenv`/`setfenv`/`loadstring` are
   forbidden in `studio-plugin/src/`. The one principled exception is the
   `execute_lua` sandbox closure inside
   `domain/handlers/ExecuteLuaHandler.luau`, which deliberately constructs a
   user-code environment (the §15 rule applies to *our* code, not to the
   environment we hand to user-supplied Luau strings). That exception is
   documented in the file and whitelisted in the CI gate.
3. **Services are quarantined.** `game:GetService(...)` appears **only** in
   `runtime/Services.luau`. Everywhere else receives services through the
   `Context`.
4. **UI instances are quarantined.** `Instance.new("Frame" | "TextButton"
   | "ScreenGui" | "ScrollingFrame" | "UICorner" | "UIGradient" |
   "UIListLayout" | "UIPadding" | "TextLabel" | "TextBox" | "ImageLabel")`
   and `React.createElement` / `ReactRoblox.createRoot` appear **only**
   under `ui/` (and the React render-root creation in `app/Plugin.client
   .luau`). `domain/` and `runtime/` never construct GUI. Test-session
   companion *Scripts* and the render layer's *ViewportFrame* are not GUI —
   they live under `runtime/`.
5. **One responsibility per module**, ≤ ~400 lines (hard cap ~600 with a
   written justification comment at the top). A growing file is a missing
   module. The legacy `studio-plugin/plugin.luau` is 7,022 lines; no
   MCPPlugin module may ever exceed that — a sanity guard, not the real cap.

When raw Roblox coupling is confined to one named place, the rest of the
codebase is testable, renamable, and reviewable. That is the *single* most
important rule in this document.

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
    services:  Services.Services,          -- §1: game:GetService handles + LogService
    plugin:    PluginHandles.Handles,      -- plugin, toolbar, button, widget, activationChanged
    constants: Constants.Constants,        -- frozen: endpoints, timeouts, companion tags
    settings:  Settings.Settings,          -- mutable, typed setters: serverUrl, pollInterval, retry…
    logger:    Logger.Logger,              -- LogService.MessageOut capture buffer (for get_output)
    http:      HttpClient.HttpClient,      -- thin RequestAsync wrapper, one call site
    history:   History.History,            -- ChangeHistoryService recording wrapper
    actionLog: ActionLog.ActionLog,        -- in-memory undo/redo tracking (for get_history + source-edit undo)
    polling:   Polling.Polling,            -- Heartbeat→/poll loop; emits onStatus/onConnected/onError
    bridge:    Dispatcher.Dispatcher,      -- processRequest router (the MCP equivalent of ToolHost)
    janitor:   Janitor.Janitor,            -- root teardown scope (§12)
}
```

### Differences vs BuilderTool's Context

| BuilderTool has | We have instead | Why |
|---|---|---|
| `selection` | nothing | The MCP plugin never owns a selection; handlers that need it call `services.selection` directly via a `get_selection` handler |
| `viewport` (raycast, adornments) | nothing | No in-viewport interaction; the closest analog is `runtime/render/*` helpers for screenshots, owned per-handler |
| `tools` (ToolHost) | `bridge` (Dispatcher) | Same shape: one active dispatch target, routes events to a registry of handlers |
| `input` (UIS) | `polling` (HTTP) | Same role: one adapter, one event source, fans events to the dispatcher |
| — | `logger`, `http`, `actionLog` | New: HTTP-bridge plugin needs explicit log capture, an HTTP gateway, and a parallel undo log (the legacy plugin's most subtle invariant — see §8) |

Design rules (carried over from BuilderTool):

- **Lean.** The Context holds only true cross-cutting state. Pure helpers
  (`runtime/instance/Serialize.luau`, `runtime/script/Lines.luau`,
  `runtime/render/Base64.luau`) are ordinary modules required where used —
  they are **not** hung off the Context. No god-object.
- **Typed.** Every field has a real type. `any` is allowed only for
  documented opaque Roblox-instance handles and JSON-decoded request bodies
  at the very edge (the handler entry point immediately casts to a typed
  request shape it owns — §13).
- **Mutability is explicit.** Immutable values live in `constants`
  (`table.freeze`d). Anything written at runtime lives in `settings` and is
  changed **only** through typed setters — so "who mutates this" is
  greppable.
- **Construction is centralized.** Every field is populated by
  `Runtime.new`. Nothing else mutates the Context *shape*.

---

## 6. The Handler system (the core)

A "handler" is the central abstraction. Each MCP endpoint (e.g.
`get_instance_properties`, `set_property`, `play_solo`) is implemented by a
function inside a *handler module* (`domain/handlers/<Group>Handlers.luau`).
A handler module exports one or more named handlers; the **registry** lists
which endpoint names route to which handler; the **dispatcher** receives one
HTTP request, looks it up, calls it inside the appropriate history scope, and
returns a typed response.

### 6.1 The `Handler` contract — `domain/handler/Handler.luau`

```lua
--!strict
export type EndpointName = string  -- stable, lowercase-underscore, e.g. "set_property"
                                   -- NEVER renamed once shipped — this is the wire protocol

export type HandlerRequest = {
    endpoint: EndpointName,
    data:     any,          -- the JSON-decoded request body; the handler casts it
    requestId: string,      -- the UUID from /poll, used for /response pairing
}

export type RecordResult = {
    -- The dispatcher uses this to decide commit / cancel / no-record.
    -- Returning `nil` from the handler means "read-only, no recording opened".
    name:               string,   -- user-facing undo entry name (sentence-cased, action-first)
    didMutate:          boolean,
    isSourceEditOnly:   boolean,  -- if true, dispatcher SKIPS CHS and uses ActionLog scriptEdits
    scriptEdits:        { ScriptEdit }?,  -- present iff isSourceEditOnly
    mutatesUnknown:     boolean,  -- execute_lua: dispatcher uses descendant-count delta heuristic
}

export type Handler = {
    endpoint: EndpointName,
    -- The handler returns (responsePayload, recordResult). recordResult is
    -- nil for read-only handlers. The handler does NOT call
    -- ChangeHistoryService itself (§8) — it just describes what it did.
    run: (ctx: Context, data: any) -> (any, RecordResult?),
}
```

### 6.2 `Dispatcher` — `domain/handler/Dispatcher.luau`

- Receives one decoded `HandlerRequest`. Looks up `registry[endpoint]`. If
  unknown → returns `{ error = "Unknown endpoint: " .. endpoint }` with the
  same shape the TS server expects.
- Opens a CHS recording **before** calling the handler — but only after a
  speculative "this endpoint may mutate" check based on a static
  `MUTATING_ENDPOINTS` set. Read-only endpoints never open a recording.
- Calls `handler.run(ctx, data)` inside a `pcall`. On error → cancel the
  recording, return `{ error = err }`.
- On success, uses the returned `RecordResult` to decide:
  - `recordResult == nil` → read-only, nothing to do
  - `didMutate == false` → cancel the recording (no undo entry created)
  - `isSourceEditOnly == true` → cancel CHS, append `scriptEdits` to
    `ctx.actionLog` so `undo`/`redo` handlers can restore via direct
    `Source =` assignment (this is the legacy plugin's "Bug 1 fix"; see §8)
  - `mutatesUnknown == true` (execute_lua only) → commit only if
    descendant-count delta on workspace+ServerStorage+ReplicatedStorage+…
    is non-zero (matches legacy [L2059–2064] heuristic)
  - otherwise → commit
- **Handlers never call `ChangeHistoryService:TryBeginRecording` themselves.**
  This is the antidote to the legacy plugin's per-handler ad-hoc recording
  pattern.

### 6.3 Handler registry — `domain/handler/HandlerRegistry.luau`

A typed table `{ [EndpointName]: Handler }`, populated by explicit `require`
of each `domain/handlers/<Group>Handlers.luau` module and explicit insertion
of each exported handler. **No dynamic/string-driven module loading.** Adding
an endpoint = add the handler in its module + one registry line. The
registry is the only place that enumerates endpoints; the TS-side
`bridge-service.ts` consumes this same set of names by convention.

### 6.4 Adding a handler (the canonical recipe)

1. In an existing or new `domain/handlers/<Group>Handlers.luau`, write a
   function that takes `(ctx: Context, data: <YourTypedRequest>)` and returns
   `(responseTable, RecordResult?)`.
2. Define the typed request and response shapes at the top of the module.
   Never reach into `data` as `any` past the first cast.
3. If the handler mutates the data model, return a `RecordResult` with a
   user-facing `name` (e.g. `"Set Property: Part.Color"`). The dispatcher
   opens/commits the recording for you (§8).
4. For *source* mutations only (script edits), return `isSourceEditOnly =
   true` plus `scriptEdits` snapshots — the dispatcher handles the
   ActionLog path instead of CHS.
5. Apply destructive-action LLM-stomp protections (companion-tag refusal,
   §15) for any handler that deletes/edits/unparents instances or sets
   `Disabled` on scripts.
6. Register it in `HandlerRegistry`.
7. If the handler introduced pure logic, add a Lune test (§17).

---

## 7. HTTP bridge & polling

The MCP plugin's *only* event source is the MCP server. All event handling
flows through one polling loop and one dispatcher; there are no direct
UserInputService connections, no Studio-keybind tools, no inputs except
endpoint requests arriving over HTTP.

`runtime/http/HttpClient.luau`:

- The **only** call site of `HttpService:RequestAsync`. Every other module
  asks the HttpClient. One place to set timeouts, attach headers, retry on
  5xx, JSON-encode bodies, JSON-decode responses.
- Returns a typed `{ ok: boolean, status: number, body: any, error: string? }`.
  Never throws on non-2xx — handlers see a value, not an exception.

`runtime/http/Polling.luau`:

- One `RunService.Heartbeat:Connect` connection, owned by a Janitor passed
  in by the caller. There is **no** `pluginState.connection` module-level
  variable (legacy anti-pattern).
- Calls `GET /poll` at most once per `settings.pollInterval`. On a 200 with
  a request body, hands it to `ctx.bridge:dispatch(request)`. POSTs the
  result back via `POST /response`.
- **Emits plain signals** (`onStatus`, `onConnected`, `onError`,
  `onRetryDelayChanged`). It must **not** poke any UI label, BackgroundColor3,
  or React state directly — that was the worst coupling in the legacy file.
  The UI subscribes via `ui/hooks/useSignal` (§11).
- Exponential backoff on consecutive failures (current delay, multiplier,
  cap) lives in `Settings` as typed values, not magic numbers in the loop.

---

## 8. Mutation discipline — undo/redo

**Every** mutation goes through one of two channels:

1. **CHS recording (the normal path).** Opened by the dispatcher (§6.2),
   wraps the handler call. One MCP request = one recording = one Ctrl+Z.
2. **ActionLog (source-edit-only path).** Some script-source mutations
   (notably `set_script_source` and `edit_script`) cannot be captured by
   ChangeHistoryService when applied via `ScriptEditorService` or direct
   `Source =` writes outside an open recording context that touches a
   tracked property. The plugin maintains a parallel undo log of `before /
   after` source snapshots so `undo`/`redo` handlers can restore them by
   direct assignment. This is the **legacy plugin's most subtle invariant**
   (see legacy `studio-plugin/plugin.luau` lines L1985–2007 for the original
   reasoning) and it must be preserved.

`runtime/History.luau` wraps the **modern** CHS recording API
(`TryBeginRecording` / `FinishRecording`):

```lua
--!strict
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

`runtime/ActionLog.luau` keeps two ring-buffered lists (`actionHistory`,
`redoHistory`) plus a transient `_pendingActionLog` used during dispatch.
Each entry is typed: it carries `{ endpoint, timestamp, scriptEdits?,
description }`. `get_history` reads this. `undo` and `redo` *first* try CHS
(`Undo()` / `Redo()`); then they pop the matching ActionLog entry and
restore any `scriptEdits` by direct `Source =` assignment.

Rules:

- **One MCP request, one recording.** Read-only requests never open one.
- **Recording names are user-facing** (they appear in Edit ▸ Undo). Sentence
  case, action-first: `"Set property"`, `"Create part"`, `"Edit script"`.
- **Failure cancels the recording** and re-raises — never leave a recording
  open and never half-commit.
- A handler that opens its own recording is a bug caught in review (§6.2).

---

## 9. Settings & persistence — `runtime/Settings.luau`

- `Settings` is the **typed in-memory mirror** of persisted preferences
  (server URL, MCP server URL, poll interval, retry delays, multiplier,
  failure thresholds).
- Read via fields; write **only** through typed setters; every setter persists
  through `plugin:SetSetting(KEY, value)` and fires a `changed` signal the UI
  subscribes to.
- All keys are namespaced (`"MCPServer/<camelCaseKey>"`) and declared in one
  frozen `KEYS` table — no scattered string literals.
- A `SCHEMA_VERSION` integer is persisted. On load, run an explicit migration
  ladder (`v1→v2→…`); unknown/missing → defaults. Never `error` on a bad
  stored value — degrade to default and continue.
- No setting is read with `plugin:GetSetting` outside this module.

---

## 10. Test sessions — companion scripts

`play_solo` injects two **real** `.luau` modules (Phase 5):

- `runtime/testsession/ServerCompanion.luau` — a frozen string returned from
  the module, substituted with `__MCP_SERVER_URL__` / `__MCP_SESSION_ID__` at
  injection time, then materialised as a `Script` in `ServerScriptService`.
- `runtime/testsession/ClientCompanion.luau` — same shape, materialised as
  a `LocalScript` in `StarterPlayer.StarterPlayerScripts`.

Both are tagged with `_MCPTestCompanion` via `CollectionService` and named
`_MCPTestCompanion[_Client]`. This eliminates the legacy ~1,100-line embedded-
string blob; the companions are syntax-highlighted, linted, and `--!strict`-
checked like every other module.

**LLM-stomp prevention** is the single most important reliability concern
here. Destructive handlers (`delete_object`, `edit_script`,
`set_script_source`, `move_instance`, and `set_property` when setting
`Disabled`) refuse to operate on any instance that:

- carries the `_MCPTestCompanion` tag, OR
- has a name matching `_MCPTestCompanion*`

The refusal logic lives in a shared helper in
`runtime/testsession/Companions.luau` and is called by every destructive
handler. This protects an LLM agent from accidentally deleting/disabling
the very plumbing that lets it observe the test session.

Cleanup sweeps run on plugin activate, on every `play_solo` start, and after
the test ends (whether via `stop_play`, natural end, or user clicking Stop).
A plugin reinstall must leave zero `_MCPTestCompanion*` instances in the
place.

---

## 11. UI architecture (React-lua)

(Phase 6 of the refactor. Until then, the bootstrap renders an empty dock
widget — that placeholder is removed when this layer lands.)

- **Function components + hooks only.** No class components, no
  `Roact.Component`. One component per file, file name = component name,
  PascalCase, returns the component.
- **No business logic in components.** Components read state and dispatch
  intent; all logic lives in `domain/` and `runtime/`. A component never
  calls `ChangeHistoryService`, `HttpService`, `workspace`, or
  `game:GetService`.
- **Context transport:** `ui/RuntimeContext.luau` is a React context whose
  value is the one typed `Context`. `ui/hooks/useRuntime.luau` returns it.
  Components reach services/handlers/polling state **only** through
  `useRuntime`.
- **Reactivity bridge:** `runtime/http/Polling.luau` exposes plain signals.
  A `useSignal(signal, get)` hook subscribes and `setState`s — and **must
  disconnect in the effect cleanup**. The disconnect is mandatory, not
  optional.
- **The render root** is created and owned by `app/Plugin.client.luau`:
  the dock widget, `ReactRoblox.createRoot`, `root:render(App)`. The root,
  the widget, and the React root are all added to the root Janitor
  (`janitor:Add(root, "unmount")`, `janitor:Add(widget, "Destroy")`).
- **Theme:** `ui/theme/Theme.luau` exposes semantic tokens
  (`background`, `accent`, `textPrimary`, `connected`, `error`, …) and
  follows the Studio theme via `StudioService` — no hard-coded `Color3`
  literals in components.

---

## 12. Plugin lifecycle & resource management

`app/Plugin.client.luau` is **thin** and is the *only* file with top-level
side effects. Exact sequence (Phase 6 endpoint; Phase 1 is a stub of this
shape):

1. `local ctx = Runtime.new(plugin)` — builds services, constants, settings
   (with migration), the root `Janitor`, logger, HTTP client, history,
   action log, polling, dispatcher, and the handler registry.
2. Create the toolbar + toggle button (`plugin:CreateToolbar`,
   `:CreateButton`); create the dock widget
   (`plugin:CreateDockWidgetPluginGuiAsync`).
3. Create the React render root into the widget; `root:render(App)` with the
   Context provider.
4. Wire activation: button click toggles widget `Enabled`; widget
   `Enabled`-changed syncs button `SetActive`. Both connections are
   Janitor-tracked.
5. Register **one** `plugin.Unloading` connection whose body is
   `ctx.janitor:Destroy()`.

**The Janitor mandate:** every connection, every Instance (including the
dock widget, any ScreenGui, the React root), every CompanionScript injected
into the place, every `Heartbeat:Connect` — *everything* disposable is
`:Add`ed to a Janitor at the moment it is created. Teardown is a single
`ctx.janitor:Destroy()`. There are **no** ad-hoc `connections = {}` arrays
and **no** "I'll disconnect it later". Teardown checklist that
`plugin.Unloading` must satisfy:

- [ ] Polling loop's Heartbeat connection disconnected
- [ ] Any in-flight HTTP request allowed to finish; no new ones started
- [ ] All `_MCPTestCompanion*` instances swept from the place
- [ ] React root unmounted; dock widget destroyed
- [ ] Toolbar button state reset (button itself is Studio-owned)
- [ ] LogService.MessageOut connection disconnected
- [ ] No `MCP*` instance left in `CoreGui`/`workspace`/`ServerScriptService`/`StarterPlayer*`

If reinstalling the plugin in a session leaves a duplicate widget, a stray
companion, or any `MCP*` orphan, teardown is broken — treat as a release
blocker.

---

## 13. Code style & conventions

- **`--!strict` is the first line of every `.luau` file.** No `--!nonstrict`,
  no `--!nocheck`. Type errors are build-breaking, not advisory.
- **No file headers from decompilers.** The literal
  `-- AI use of source code prohibited.` and any decompiler banner are
  **banned** (CI regex, §16).
- **Naming:**

  | Kind | Convention | Example |
  |---|---|---|
  | Module / type / React component | `PascalCase` | `Dispatcher`, `HandlerRegistry`, `StatusPanel` |
  | Local var / function / field | `camelCase` | `pendingRequest`, `recordChange` |
  | Constant (frozen) | `SCREAMING_SNAKE` | `TEST_COMPANION_TAG`, `MAX_OUTPUT_BUFFER` |
  | Boolean | `is*/has*/should*` prefix | `isConnected`, `hasPendingActionLog` |
  | React hook | `use*` | `useRuntime`, `useSignal`, `useStatus` |
  | Persisted endpoint path / setting key | stable `lowercase` / `kebab-case` | `"set_property"`, `"MCPServer/serverUrl"` |
  | File | == the value it returns | `Dispatcher.luau` ⇒ `Dispatcher` |

- **No abbreviations, no brand/meme tokens.** Write `changeHistory`, not
  `chs`; `httpService`, not `http_serv`.
- **Errors at the edge.** Validate at boundaries (the handler entry point
  cast from `any` → typed request); `error`/`assert` with an actionable
  message for programmer mistakes; degrade gracefully for bad
  *user/persisted* data (never crash the plugin over a stale setting or a
  deleted instance). Every handler is wrapped in the dispatcher's `pcall`
  so one failure cannot wedge the polling loop.
- **Comments** explain *why*, not *what*. A module that needs a comment to
  explain *what* it does is too big or badly named.
- **No** `wait`/`spawn`/`delay` (deprecated) — use `task.*`. No
  `while true do` without a Janitor-bound exit.

---

## 14. Module & file conventions

- One module = one responsibility = one return value. ≤ ~400 lines; ~600
  hard cap and only with a top-of-file justification comment naming the
  planned split seam.
- `init.luau`/`init.client.luau` only where Rojo packaging requires it
  (`app/Plugin.client.luau`, package root). Never use `init.luau` as a
  dumping ground.
- `.meta.json` is used **only** for what Rojo can't express in the tree
  (root `className`, build attributes). It is not a config side-channel.
- Requires are explicit and relative (`require(script.Parent.Foo)` /
  `require(ctx...)`), grouped at the top, never inside hot paths, never
  dynamic/string-built (except inside the `execute_lua` user-code sandbox,
  §4 invariant 2).

---

## 15. Forbidden anti-patterns

Each is a **review-blocking** error, not a style nit. The legacy
`studio-plugin/plugin.luau` violates several of these — that file is the
*specification of behaviour*, not a style reference. Do not port a defect
just because the legacy file has it.

| # | Anti-pattern | Why it is banned |
|---|---|---|
| A1 | Global state facade (`_G.MCP`, `shared.MCP`, …) | untestable, unrenamable, any module can corrupt state → use the typed `Context` (§5) |
| A2 | `getfenv`/`setfenv` DI | hidden dependencies, not type-checkable → explicit `require` + typed `__index` (§13). The `execute_lua` sandbox is a single documented exception |
| A3 | `script.Name` as type | rename = breakage, no static check → real Luau types |
| A4 | Unbound `BindToRenderStep` | runs forever after unload → mandatory paired unbind in same module (§16) |
| A5 | Ad-hoc connection arrays | `connections = {}` + manual disconnect loop always misses some → single root **Janitor** (§12) |
| A6 | Decompiler header | `-- AI use of source code prohibited.` → CI regex (§16) |
| A7 | `loadstring` outside the sandbox | arbitrary code execution path inside the plugin's own code → keep it inside the `ExecuteLuaHandler` user-environment only |
| A8 | UI poked from polling | `step1Dot.BackgroundColor3 = …` inside `pollForRequests` — the legacy plugin's worst coupling. Polling emits signals; UI subscribes (§7, §11) |
| A9 | Duplicate "core" helpers | the legacy file has THREE `serializeValue` definitions. Every helper lives in exactly one module |
| A10 | Embedded script-as-string blobs | the legacy 1,100-line companion string → real `.luau` files, substituted at injection time (§10) |
| A11 | Per-handler CHS recordings | the dispatcher owns recordings (§6.2, §8) |
| A12 | Source mutations bypassing ActionLog | `set_script_source` / `edit_script` without an ActionLog entry breaks `undo` (§8) |

Additionally banned (general): mutating `Context` shape outside
`Runtime.new`, business logic inside React components, `Instance.new` of
GUI outside `ui/`, `game:GetService` outside `runtime/Services.luau`,
committing build artifacts.

---

## 16. Quality gates (CI seams)

A change is not "done" until all gates are green. These are mechanical and
non-negotiable; they encode the invariants of §4 and §15 so review can focus
on design, not policing. Implementation: `tools/golden/check.lune.luau`.

| Gate | Check |
|---|---|
| Format | `stylua --check src/` is clean |
| Lint | `selene src/` is clean |
| Strict | every `src/**/*.luau` first line is `--!strict` |
| Build | `rojo build rbxstudio-plugin.project.json` succeeds |
| No globals | grep finds no `_G`, `shared`, `getfenv`, `setfenv`, `loadstring` in `src/` — except inside `domain/handlers/ExecuteLuaHandler.luau`, which is whitelisted with a documented `-- selene: allow(…)` block |
| Service quarantine | `game:GetService(` appears only in `src/runtime/Services.luau` |
| UI quarantine | `Instance.new("Frame"\|"TextLabel"\|"TextButton"\|"ScrollingFrame"\|"ScreenGui"\|"UICorner"\|"UIPadding"\|"UIGradient"\|"UIListLayout"\|"TextBox"\|"ImageLabel")` and `React.createElement` / `ReactRoblox.createRoot` only under `src/ui/` and `src/app/` |
| Render-step safety | every `BindToRenderStep(` has a matching `UnbindFromRenderStep(` in the same module |
| No decompiler banner | the prohibited header regex finds nothing |
| Layer invariant | no `require` path goes up the layer order (§4) — `runtime/` requires nothing in the package; `domain/` doesn't require `ui/`/`app/`; `ui/` doesn't require `app/` |
| File size | no file > 7,022 lines (the legacy `plugin.luau` line count — a sanity guard, not the real cap which is §4 invariant 5) |

The Lune script runs pre-commit (developer responsibility) and in CI on
every PR.

---

## 17. Testing strategy

- **Pure logic is unit-tested with Lune** (`tools/` or a `tests/` Lune
  runner): `runtime/instance/Serialize.luau`, `runtime/instance/Convert.luau`,
  `runtime/script/Lines.luau`, `runtime/script/Validator.luau`, `History.record`
  commit/cancel/nest behaviour, settings migration ladder, the dispatcher's
  decision tree (commit / cancel / source-edit / mutates-unknown). These have
  **no** Roblox-service dependency by design — that is *why* §4.3/§4.4 exist.
- **End-to-end behaviour is verified by the TS-side Jest suite in
  `../src/__tests__/`**, run against a Studio session with the plugin loaded.
  The TS server's contract does not change across the refactor (REFACTOR_PLAN
  §6.1) — so a green Jest run is the high-confidence behavioural-equivalence
  signal.
- **Studio behaviour is verified against a written manual matrix** per
  release: install → connect → 43-tool smoke → uninstall leaves zero
  orphans. The teardown checklist (§12) is part of every release sign-off.
- A bug fix lands with the test that would have caught it.

---

## 18. Glossary

| Term | Meaning |
|---|---|
| **Context** | the one typed DI object built by `Runtime.new`, threaded everywhere (§5) |
| **Handler** | a function satisfying the `Handler` contract; one per MCP endpoint (§6) |
| **Dispatcher** | owns CHS recordings + request routing; one per Context (§6.2) |
| **Registry** | the explicit endpoint → handler table; the wire protocol surface (§6.3) |
| **Recording** | one ChangeHistoryService undo step = one MCP request (§8) |
| **ActionLog** | the parallel plugin-side undo log for source-only edits (§8) |
| **Polling** | the one Heartbeat-driven loop that talks to the MCP server (§7) |
| **Janitor** | the single teardown scope; everything disposable is added to it (§12) |
| **Companion** | a tagged `_MCPTestCompanion*` Script/LocalScript injected during play_solo (§10) |
| **Gate** | a mechanical CI check that must be green to merge (§16) |

---

### Amendment log

- *2026-05-19* — Document created in `MCPPlugin/` as part of the clean-sheet
  refactor (REFACTOR_PLAN.md). Adapted from
  `better-plugin/BuilderTool/ARCHITECTURE.md`; the MCP-specific deltas
  (Handler vs Tool, Polling vs Input, no viewport/selection, HTTP bridge,
  ActionLog/source-edit decoupling, companion-tag LLM-stomp protections) are
  documented above and trace one-to-one to the corresponding sections of
  REFACTOR_PLAN §3.
- *2026-05-19* — **Phase 7 cutover.** `MCPPlugin/` renamed to `studio-plugin/`;
  the legacy single-file plugin moved to `studio-plugin-legacy/` (read-only,
  removed in the next minor release). Path references in this document
  updated; the binary still ships as `MCPPlugin.rbxm` to match the published
  asset name. See root README "Studio Plugin Setup" for the user-facing
  install flow.
