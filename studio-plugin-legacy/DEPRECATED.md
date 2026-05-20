# DEPRECATED — legacy single-file plugin

> ⚠️ **This folder is read-only archaeology.** The active Studio plugin lives in
> `studio-plugin/` (a multi-module Rojo project, REFACTOR_PLAN Phase 1–6).
> This folder will be deleted in a follow-up release.

## What's in here

- `plugin.luau` — the 7,022-line single-file plugin that powered MCP through
  v2.4.x. Kept verbatim so we can diff against it while flushing out subtle
  behavioural regressions in the rewrite.
- `plugin.json` — the original Roblox plugin manifest.
- `INSTALLATION.md` — the user-facing install guide for the legacy binary.

## Why it's still here

Per REFACTOR_PLAN §5 Phase 7 sign-off: we keep the legacy source for one
release so anyone bisecting a behaviour difference between v2.x and v3.0.0
can read the original implementation without `git checkout`-ing back in time.

## When it's going away

The next minor release after v3.0.0 (provisionally v3.0.1) will delete this
folder. If you need it after that, fetch the v3.0.0 git tag.

## What to use instead

- **Source:** `studio-plugin/src/` (Rojo project: `studio-plugin/rbxstudio-plugin.project.json`)
- **Build:** `npm run plugin:install` (invokes rojo + drops the `.rbxm` into Studio's Plugins folder)
- **Install (end users):** download `MCPPlugin.rbxm` from the GitHub Releases page
- **Architecture:** `studio-plugin/ARCHITECTURE.md`
