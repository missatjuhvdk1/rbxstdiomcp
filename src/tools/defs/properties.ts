import type { ToolDef } from '../types.js';

/**
 * Property modification tools: single-instance and bulk set/get.
 */
export const propertyTools: ToolDef[] = [
  {
    name: 'set_property',
    description: 'Set a property on any Roblox instance',
    inputSchema: {
      type: 'object',
      properties: {
        instancePath: {
          type: 'string',
          description: 'Path to the instance (e.g., "game.Workspace.Part")',
        },
        propertyName: {
          type: 'string',
          description: 'Name of the property to set',
        },
        propertyValue: {
          description: 'Value to set the property to (any type)',
        },
      },
      required: ['instancePath', 'propertyName', 'propertyValue'],
    },
    handler: (args, { tools }) =>
      tools.setProperty(args?.instancePath, args?.propertyName, args?.propertyValue),
  },

  {
    name: 'mass_set_property',
    description: 'Set the same property on multiple instances at once',
    inputSchema: {
      type: 'object',
      properties: {
        paths: {
          type: 'array',
          items: { type: 'string' },
          description: 'Array of instance paths to modify',
        },
        propertyName: {
          type: 'string',
          description: 'Name of the property to set',
        },
        propertyValue: {
          description: 'Value to set the property to (any type)',
        },
      },
      required: ['paths', 'propertyName', 'propertyValue'],
    },
    handler: (args, { tools }) =>
      tools.massSetProperty(args?.paths, args?.propertyName, args?.propertyValue),
  },

  {
    name: 'mass_get_property',
    description: 'Get the same property from multiple instances at once',
    inputSchema: {
      type: 'object',
      properties: {
        paths: {
          type: 'array',
          items: { type: 'string' },
          description: 'Array of instance paths to read from',
        },
        propertyName: {
          type: 'string',
          description: 'Name of the property to get',
        },
      },
      required: ['paths', 'propertyName'],
    },
    handler: (args, { tools }) => tools.massGetProperty(args?.paths, args?.propertyName),
  },
];
