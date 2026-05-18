import type { ToolDef } from '../types.js';

/**
 * Arbitrary Lua execution — the swiss-army knife.
 */
export const executeTools: ToolDef[] = [
  {
    name: 'execute_lua',
    description:
      "Execute arbitrary Lua/Luau code in Roblox Studio. This is a powerful tool that runs code directly in the Studio plugin context with access to all services, Instance constructors, and the full Roblox API. Use this for complex operations that would require multiple tool calls, debugging, prototyping, or any task that's easier to express in code. Returns the result of the last expression.\n\n**Undo support:** The entire execution is wrapped in a single ChangeHistoryService recording. All mutations made by the code are captured under ONE waypoint and can be reverted via the `undo` tool or Ctrl+Z. If the code errors, the recording is canceled and Studio automatically rolls back any partial mutations.\n\n**Caveat — yielded/async code:** Mutations performed AFTER the handler returns (e.g. inside `task.spawn`/`task.delay` callbacks, or after long `task.wait`s that exceed the handler's lifetime) are NOT captured in the waypoint. Keep mutation work synchronous within the call for reliable undo.",
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
