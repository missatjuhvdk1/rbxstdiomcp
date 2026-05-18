import type { ToolDef } from '../types.js';

/**
 * Studio runtime tools: undo/redo and Play Solo session control.
 */
export const runtimeTools: ToolDef[] = [
  {
    name: 'undo',
    description:
      'Undo the last MCP mutation(s) in Roblox Studio. All MCP mutation tools (create, delete, set_property, edit_script, execute_lua, etc.) are automatically wrapped in ChangeHistoryService recordings, so each tool call = one Ctrl+Z. Pass `count` to undo multiple steps in one round-trip; stops early at the bottom of Studio\'s undo stack and reports `stopped_early: true` in that case. The response\'s `entries` array describes each action undone (most-recent first). Call `get_history` first if you want to peek without committing.',
    inputSchema: {
      type: 'object',
      properties: {
        count: {
          type: 'number',
          description:
            'How many steps to undo (default 1, max 100). Each step is one MCP tool call worth of changes — e.g. mass_create_objects of 100 parts is ONE step. Stops early at the bottom of the undo stack.',
          default: 1,
          minimum: 1,
          maximum: 100,
        },
      },
    },
    handler: (args, { tools }) => tools.undo(args?.count),
  },

  {
    name: 'redo',
    description:
      'Redo previously undone change(s) in Roblox Studio. Mirrors `undo`: pass `count` to redo multiple steps; stops early at the top of the redo stack and reports `stopped_early`. The redo stack is cleared whenever a new mutation is made (standard undo/redo semantics).',
    inputSchema: {
      type: 'object',
      properties: {
        count: {
          type: 'number',
          description: 'How many steps to redo (default 1, max 100).',
          default: 1,
          minimum: 1,
          maximum: 100,
        },
      },
    },
    handler: (args, { tools }) => tools.redo(args?.count),
  },

  {
    name: 'get_history',
    description:
      "Read-only view of the recent MCP undo/redo stacks. Use this to peek at what `undo` would revert before calling it, to recover situational awareness after a session resume, or to decide how far back (`count`) to roll an `undo` call.\n\nReturns Studio's authoritative `can_undo`/`can_redo` flags plus both stacks (most-recent first; `index: 0` is the next entry that `undo`/`redo` would consume). Each entry includes `action`, `target`, `summary`, `timestamp`, `age_seconds`. Pass `include_details: true` for the per-action `details` payload (omitted by default to keep responses small — mass operations have large details blobs).\n\nNote: Studio's undo stack is shared with the user's own Ctrl+Z edits. `can_undo` can be true even when `tracked_undo_count` is 0 (e.g. fresh session, or user made manual changes before the plugin connected).",
    inputSchema: {
      type: 'object',
      properties: {
        limit: {
          type: 'number',
          description:
            'Max entries to return per stack (default 20, max 100). The plugin retains the last 100 MCP actions.',
          default: 20,
          minimum: 1,
          maximum: 100,
        },
        include_details: {
          type: 'boolean',
          description:
            'Include the per-action `details` payload (e.g. property values, batch counts). Off by default to save context — turn on when you actually need the granular data.',
          default: false,
        },
      },
    },
    handler: (args, { tools }) => tools.getHistory(args?.limit, args?.include_details),
  },

  {
    name: 'play_solo',
    description:
      'Start a play test (Play Solo) in Roblox Studio via StudioTestService:ExecutePlayModeAsync. Automatically injects an in-test companion script so stop_play and get_playtest_output work. If a previous test is still tracked, stops it first. Returns a sessionId that ties together start, stop, and output reads.',
    inputSchema: {
      type: 'object',
      properties: {},
    },
    handler: (_args, { tools }) => tools.playSolo(),
  },

  {
    name: 'stop_play',
    description:
      'Stop the current play test cleanly via StudioTestService:EndTest (called from inside the test by an injected companion script). Restores pre-play state — unlike RunService:Stop, this is the proper way to end a Play Solo session. Idempotent: returns successfully if no test is running.',
    inputSchema: {
      type: 'object',
      properties: {},
    },
    handler: (_args, { tools }) => tools.stopPlay(),
  },

  {
    name: 'get_playtest_output',
    description:
      "Read script output (print/warn/error) captured DURING a play test session. Streamed live from the test's Server DataModel by the injected companion. Survives after the test ends so you can debug post-hoc. For non-playtest output (Edit-mode plugin output, build messages), use get_output instead. Use the sinceSeq cursor returned in nextSinceSeq to tail incrementally.",
    inputSchema: {
      type: 'object',
      properties: {
        sinceSeq: {
          type: 'number',
          description:
            'Only return entries with seq > this value. Pass back nextSinceSeq from a prior call to avoid re-reading.',
        },
        limit: {
          type: 'number',
          description: 'Max entries to return (default 500, max 5000).',
          default: 500,
        },
        messageTypes: {
          type: 'array',
          items: { type: 'string' },
          description:
            'Filter by MessageType: MessageOutput, MessageInfo, MessageWarning, MessageError.',
        },
      },
    },
    handler: (args, { tools }) =>
      tools.getPlaytestOutput(args?.sinceSeq, args?.limit, args?.messageTypes),
  },

  {
    name: 'run_live_lua',
    description:
      'Execute Lua/Luau code INSIDE a running play test (started via play_solo). Runs in the test\'s Server DataModel with full access to running game state — fire RemoteEvents, query Players, read Workspace state at the current physics tick, mutate the live world, etc. This is different from execute_lua (which runs in the Edit-mode plugin context).\n\n**target="server" is the primary mode.** Server requires `Game Settings → Security → LoadString` to be enabled (place-level toggle) since execution uses `loadstring`. **target="client" is currently engine-blocked** — Roblox permanently disables `loadstring` in LocalScripts regardless of the LoadStringEnabled flag, so client eval will always return `loadstring_disabled`. The relay infrastructure for client eval is wired up (client registration + log streaming work) but actual code execution on the client requires a future workaround. For now, drive client behavior from the server via Remotes.\n\nNever throws — every failure path is reported in the response body as { success: false, error: <enum>, message }. Possible error enums: "no_playtest" (call play_solo first), "playtest_ended" (start a new test), "companion_not_ready" (wait briefly), "loadstring_disabled" (server: enable LoadStringEnabled in Game Settings; client: engine-blocked), "no_clients_connected" / "multiple_clients" / "no_such_player" (client targeting), "compile_error", "runtime_error", "timeout", "companion_error" (often caused by a previous spinloop wedging the companion — restart play_solo).\n\nReturns ALL Lua return values packed into `values` (an array — single-return becomes length-1, no-return becomes empty). If captureLogs=true, prints/warns/errors emitted by the executed code are returned in `logs`. Errors include `traceback` from debug.traceback. **Avoid `while true do end` without a `task.wait()`** — the engine kills the offending coroutine but leaves the companion in a degraded state; use `task.wait` or set a sane `timeoutMs`.',
    inputSchema: {
      type: 'object',
      properties: {
        code: {
          type: 'string',
          description:
            'Lua/Luau source to execute. Has access to the full Roblox API in the test DataModel: game, workspace, all services (Players, ReplicatedStorage, etc.), Instance, Vector3, CFrame, Color3, etc., plus loadstring, require, debug. Use `return` to send values back to the caller (multi-return supported).',
        },
        target: {
          type: 'string',
          enum: ['server', 'client'],
          description:
            'Where to run the code. "server" runs in the test\'s Server DataModel (full Game/RemoteEvent/DataStore access; needs LoadStringEnabled=true in place settings). "client" runs in a Player\'s LocalPlayer context (PlayerGui, ContextActionService, LocalPlayer.Character). Defaults to "server".',
          default: 'server',
        },
        playerName: {
          type: 'string',
          description:
            'Only used when target="client" and multiple clients are connected. The display name (or username) of the Player to run the code on. If omitted and exactly one client is connected, that one is used.',
        },
        timeoutMs: {
          type: 'number',
          description:
            'Max time the code may run before the watchdog fires with errorType="timeout". Range 1000–30000ms, default 5000ms.',
          default: 5000,
          minimum: 1000,
          maximum: 30000,
        },
        captureLogs: {
          type: 'boolean',
          description:
            'When true (default), capture print()/warn()/error() output emitted by the code and return it in `logs`. Set to false if your code is chatty and you only care about return values.',
          default: true,
        },
      },
      required: ['code'],
    },
    handler: (args, { tools }) =>
      tools.runLiveLua(
        args?.code,
        (args?.target as 'server' | 'client') ?? 'server',
        args?.playerName,
        args?.timeoutMs,
        args?.captureLogs,
      ),
  },
];
