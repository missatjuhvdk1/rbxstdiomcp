import type { ToolDef } from '../types.js';

/**
 * Attribute tools: get/set/list/delete instance attributes.
 */
export const attributeTools: ToolDef[] = [
  {
    name: 'get_attribute',
    description: 'Get a single attribute value from a Roblox instance',
    inputSchema: {
      type: 'object',
      properties: {
        instancePath: {
          type: 'string',
          description:
            'Roblox instance path using dot notation (e.g., "game.Workspace.Part", "game.ServerStorage.DataStore")',
        },
        attributeName: {
          type: 'string',
          description: 'Name of the attribute to get',
        },
      },
      required: ['instancePath', 'attributeName'],
    },
    handler: (args, { tools }) => tools.getAttribute(args?.instancePath, args?.attributeName),
  },

  {
    name: 'set_attribute',
    description:
      'Set an attribute value on a Roblox instance. Supports string, number, boolean, Vector3, Color3, UDim2, and BrickColor.',
    inputSchema: {
      type: 'object',
      properties: {
        instancePath: {
          type: 'string',
          description: 'Roblox instance path using dot notation (e.g., "game.Workspace.Part")',
        },
        attributeName: {
          type: 'string',
          description: 'Name of the attribute to set',
        },
        attributeValue: {
          description:
            'Value to set. For Vector3: {X, Y, Z}, Color3: {R, G, B}, UDim2: {X: {Scale, Offset}, Y: {Scale, Offset}}',
        },
        valueType: {
          type: 'string',
          description: 'Optional type hint: "Vector3", "Color3", "UDim2", "BrickColor"',
        },
      },
      required: ['instancePath', 'attributeName', 'attributeValue'],
    },
    handler: (args, { tools }) =>
      tools.setAttribute(
        args?.instancePath,
        args?.attributeName,
        args?.attributeValue,
        args?.valueType,
      ),
  },

  {
    name: 'get_attributes',
    description: 'Get all attributes on a Roblox instance',
    inputSchema: {
      type: 'object',
      properties: {
        instancePath: {
          type: 'string',
          description: 'Roblox instance path using dot notation (e.g., "game.Workspace.Part")',
        },
      },
      required: ['instancePath'],
    },
    handler: (args, { tools }) => tools.getAttributes(args?.instancePath),
  },

  {
    name: 'delete_attribute',
    description: 'Delete an attribute from a Roblox instance',
    inputSchema: {
      type: 'object',
      properties: {
        instancePath: {
          type: 'string',
          description: 'Roblox instance path using dot notation (e.g., "game.Workspace.Part")',
        },
        attributeName: {
          type: 'string',
          description: 'Name of the attribute to delete',
        },
      },
      required: ['instancePath', 'attributeName'],
    },
    handler: (args, { tools }) => tools.deleteAttribute(args?.instancePath, args?.attributeName),
  },
];
