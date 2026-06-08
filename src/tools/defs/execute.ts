import type { ToolDef } from '../types.js';

/**
 * Arbitrary Lua execution — the swiss-army knife.
 */
export const executeTools: ToolDef[] = [
  {
    name: 'execute_lua',
    description:
      "Execute arbitrary Lua/Luau in the Studio plugin context (Edit mode) with full access to services, Instance constructors, and the Roblox API. Use it for complex operations that would otherwise need many tool calls, debugging, or prototyping. Returns the last expression's value. For code that must run inside a play test, use run_live_lua instead.\n\nUndo: the whole execution is one ChangeHistoryService waypoint (revert via `undo` / Ctrl+Z); if the code errors the recording is canceled and partial mutations roll back. Caveat: mutations made AFTER the handler returns (inside task.spawn/task.delay, or past long task.waits) are NOT captured — keep mutation work synchronous for reliable undo.",
    inputSchema: {
      type: 'object',
      properties: {
        code: {
          type: 'string',
          description:
            'The Lua/Luau code to execute. Has access to: game, workspace, all services (Players, ReplicatedStorage, etc.), Instance constructors (Vector3, CFrame, Color3, etc.), and helper function getInstanceByPath(path). Return a value to get it back in the response.',
        },
      },
      required: ['code'],
    },
    handler: (args, { tools }) => tools.executeLua(args?.code),
  },
];
