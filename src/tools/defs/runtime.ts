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
];
