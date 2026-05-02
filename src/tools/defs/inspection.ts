import type { ToolDef } from '../types.js';

/**
 * Read-only inspection tools: place info, services, instance/class/project
 * structure, current selection, and Studio output buffer.
 */
export const inspectionTools: ToolDef[] = [
  {
    name: 'get_place_info',
    description: 'Get place ID, name, and game settings',
    inputSchema: {
      type: 'object',
      properties: {},
    },
    handler: (_args, { tools }) => tools.getPlaceInfo(),
  },

  {
    name: 'get_services',
    description: 'Get available Roblox services and their children',
    inputSchema: {
      type: 'object',
      properties: {
        serviceName: {
          type: 'string',
          description: 'Optional specific service name to query',
        },
      },
    },
    handler: (args, { tools }) => tools.getServices(args?.serviceName),
  },

  {
    name: 'get_instance_properties',
    description: 'Get all properties of a specific Roblox instance in Studio',
    inputSchema: {
      type: 'object',
      properties: {
        instancePath: {
          type: 'string',
          description:
            'Roblox instance path using dot notation (e.g., "game.Workspace.Part", "game.ServerScriptService.MainScript", "game.ReplicatedStorage.ModuleScript")',
        },
      },
      required: ['instancePath'],
    },
    handler: (args, { tools }) => tools.getInstanceProperties(args?.instancePath),
  },

  {
    name: 'get_class_info',
    description: 'Get available properties/methods for Roblox classes',
    inputSchema: {
      type: 'object',
      properties: {
        className: {
          type: 'string',
          description: 'Roblox class name',
        },
      },
      required: ['className'],
    },
    handler: (args, { tools }) => tools.getClassInfo(args?.className),
  },

  {
    name: 'get_project_structure',
    description:
      'Get complete game hierarchy. IMPORTANT: Use maxDepth parameter (default: 3) to explore deeper levels of the hierarchy. Set higher values like 5-10 for comprehensive exploration',
    inputSchema: {
      type: 'object',
      properties: {
        path: {
          type: 'string',
          description: 'Optional path to start from (defaults to workspace root)',
          default: '',
        },
        maxDepth: {
          type: 'number',
          description:
            'Maximum depth to traverse (default: 3). RECOMMENDED: Use 5-10 for thorough exploration. Higher values provide more complete structure',
          default: 3,
        },
        scriptsOnly: {
          type: 'boolean',
          description: 'Show only scripts and script containers',
          default: false,
        },
      },
    },
    handler: (args, { tools }) =>
      tools.getProjectStructure(args?.path, args?.maxDepth, args?.scriptsOnly),
  },

  {
    name: 'get_selection',
    description: 'Get all currently selected objects',
    inputSchema: {
      type: 'object',
      properties: {},
    },
    handler: (_args, { tools }) => tools.getSelection(),
  },

  {
    name: 'get_output',
    description:
      'Read the Output window content from Roblox Studio. Captures print(), warn(), and error() messages. Use after play_solo to debug scripts.',
    inputSchema: {
      type: 'object',
      properties: {
        limit: {
          type: 'number',
          description: 'Maximum number of messages to return (default: 100)',
          default: 100,
        },
        since: {
          type: 'number',
          description: 'Only return messages after this Unix timestamp',
        },
        messageTypes: {
          type: 'array',
          items: { type: 'string' },
          description:
            'Filter by message type: MessageOutput, MessageInfo, MessageWarning, MessageError',
        },
        clear: {
          type: 'boolean',
          description: 'Clear the output buffer after reading (default: false)',
          default: false,
        },
      },
    },
    handler: (args, { tools }) =>
      tools.getOutput(args?.limit, args?.since, args?.messageTypes, args?.clear),
  },
];
