# Agent rules for `studio-plugin/`

> If you are an LLM editing files under this folder, read this first. It is
> the condensed contract; the full document is `ARCHITECTURE.md` in this
> directory.
>
> `REFACTOR_PLAN.md` is historical (the seven-phase rebuild that produced
> this folder, Phases 1–7 complete). The "studio-plugin/" you are now in is
> the destination of that plan's Phase 7 cutover; before cutover it lived at
> `MCPPlugin/`. Path references in the plan still read `MCPPlugin/` —
> mentally substitute `studio-plugin/`.

## The two source-of-truth documents

- **`studio-plugin/ARCHITECTURE.md`** — the frozen engineering contract.
  Invariants, layer rules, the `Context` shape, the `Handler` contract, the
  forbidden-pattern catalogue, the CI gates. Code implements this document;
  it does not silently redesign it. A needed change is a dated amendment
  note in that file, not an undocumented divergence.
- **`studio-plugin/REFACTOR_PLAN.md`** — historical record of the seven-phase
  rebuild. Useful for archaeology (which legacy lines map to which new
  module). Don't treat as a future plan.

## Reference repos in this workspace

| Folder | Role | Touch? |
|---|---|---|
| `studio-plugin-legacy/` | The 7,022-line single-file plugin — the **behavioural specification**. "What did this endpoint return?" → check here. | **Read-only.** Going away one release after v3.0.0. |
| `better-plugin/BuilderTool/` | Golden-rules reference — the **structural specification**. "How is this kind of thing structured?" → check here. | **Read-only.** Never modify. |
| `studio-plugin/` | The active plugin. Where all real work happens. | This is the writable plugin folder. |
| `src/` | TypeScript MCP server. Unchanged throughout the refactor. | Don't touch unless explicitly asked. |

## Non-negotiables (carry from commit #1)

1. **`--!strict` on line 1** of every `.luau` file. Always.
2. **No globals.** No `_G`, `shared`, `getfenv`, `setfenv`, `loadstring` in
   `studio-plugin/src/`. State flows through the one typed `Context`.
3. **Layer direction is one-way:** `app → ui → domain → runtime`. No upward
   `require`s, no cycles. `runtime/` depends on Roblox + `Packages/` only.
4. **`game:GetService(...)` only in `runtime/Services.luau`.**
5. **`Instance.new` of GUI and `React.createElement` only under `ui/`** (and
   the React render-root creation in `app/Plugin.client.luau`).
6. **Every mutation of the user's data model goes through
   `ctx.history:record(name, fn)`** opened by the **dispatcher**, not by
   the handler. One MCP request → one undo step.
7. **Source-only edits use `ctx.actionLog`**, not CHS — preserving the
   legacy plugin's "Bug 1 fix" (see ARCHITECTURE §8).
8. **Every connection, Instance, BindToRenderStep, and React root is
   Janitor-tracked at creation.** Teardown is one `ctx.janitor:Destroy()`.
9. **One responsibility per module, ≤ ~400 lines** (~600 hard cap with a
   top-of-file justification comment).
10. **Destructive handlers refuse to operate on `_MCPTestCompanion`-tagged
    instances** via the shared helper in
    `runtime/testsession/Companions.luau`.

## Adding code

- A new endpoint → a function in an existing or new
  `domain/handlers/<Group>Handlers.luau`, plus a line in
  `domain/handler/HandlerRegistry.luau`. Nothing else changes.
- A new Roblox service → add it to `runtime/Services.luau`. Nowhere else.
- A new persisted preference → typed setter + key in
  `runtime/Settings.luau`. Bump `SCHEMA_VERSION` and add the migration step.
- A new UI component → one file under `ui/components/`, function component,
  reads via `useRuntime()`/`useSignal()`. No business logic in components.

## Before commit

```bash
# from studio-plugin/
stylua --check src/
selene src/
lune run tools/golden/check.lune.luau
rojo build rbxstudio-plugin.project.json -o /tmp/MCPPlugin.rbxm
```

All four must be green. The Lune script encodes the §16 CI gate; the build
step proves the plugin still packages.

## When in doubt

- Behaviour question → re-read the relevant lines of
  `studio-plugin-legacy/plugin.luau`. The legacy file is the spec until it
  is removed in the next minor release.
- Structure question → re-read the relevant module of
  `better-plugin/BuilderTool/`. That is the pattern.
- Both at once → re-read `REFACTOR_PLAN.md §8` (the reference index that
  pairs each new module with its legacy lines and its BuilderTool analog).
