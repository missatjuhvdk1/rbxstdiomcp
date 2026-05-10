import type { ToolDef } from '../types.js';

/**
 * Studio runtime tools: undo/redo and Play Solo session control.
 */
export const runtimeTools: ToolDef[] = [
  {
    name: 'undo',
    description:
      'Undo the last change made in Roblox Studio. All MCP mutations are automatically recorded for undo support. Use this to revert mistakes.',
    inputSchema: {
      type: 'object',
      properties: {},
    },
    handler: (_args, { tools }) => tools.undo(),
  },

  {
    name: 'redo',
    description: 'Redo a previously undone change in Roblox Studio.',
    inputSchema: {
      type: 'object',
      properties: {},
    },
    handler: (_args, { tools }) => tools.redo(),
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
      'Execute Lua/Luau code INSIDE a running play test (started via play_solo). Runs in the test\'s Server or Client DataModel, with full access to running game state — fire RemoteEvents, query Players, read Workspace state at the current physics tick, mutate the live world, etc. This is different from execute_lua (which runs in the Edit-mode plugin context).\n\nNever throws — every failure path is reported in the response body as { success: false, error: <enum>, message }. Possible error enums: "no_playtest" (call play_solo first), "playtest_ended" (start a new test), "companion_not_ready" (wait briefly), "loadstring_disabled" (server only — enable LoadStringEnabled before play_solo), "no_clients_connected" / "multiple_clients" / "no_such_player" (client targeting), "compile_error", "runtime_error", "timeout", "companion_error".\n\nReturns ALL Lua return values packed into `values` (an array — single-return becomes length-1, no-return becomes empty). If captureLogs=true, prints/warns/errors emitted by the executed code are returned in `logs`. Errors include `traceback` from debug.traceback.',
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
