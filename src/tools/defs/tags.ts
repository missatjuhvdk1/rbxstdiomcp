import type { ToolDef } from '../types.js';

/**
 * CollectionService tag tools: list, add, remove, query by tag.
 */
export const tagTools: ToolDef[] = [
  {
    name: 'get_tags',
    description: 'Get all CollectionService tags on a Roblox instance',
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
    handler: (args, { tools }) => tools.getTags(args?.instancePath),
  },

  {
    name: 'add_tag',
    description: 'Add a CollectionService tag to a Roblox instance',
    inputSchema: {
      type: 'object',
      properties: {
        instancePath: {
          type: 'string',
          description: 'Roblox instance path using dot notation (e.g., "game.Workspace.Part")',
        },
        tagName: {
          type: 'string',
          description: 'Name of the tag to add',
        },
      },
      required: ['instancePath', 'tagName'],
    },
    handler: (args, { tools }) => tools.addTag(args?.instancePath, args?.tagName),
  },

  {
    name: 'remove_tag',
    description: 'Remove a CollectionService tag from a Roblox instance',
    inputSchema: {
      type: 'object',
      properties: {
        instancePath: {
          type: 'string',
          description: 'Roblox instance path using dot notation (e.g., "game.Workspace.Part")',
        },
        tagName: {
          type: 'string',
          description: 'Name of the tag to remove',
        },
      },
      required: ['instancePath', 'tagName'],
    },
    handler: (args, { tools }) => tools.removeTag(args?.instancePath, args?.tagName),
  },

  {
    name: 'get_tagged',
    description: 'Get all instances with a specific tag',
    inputSchema: {
      type: 'object',
      properties: {
        tagName: {
          type: 'string',
          description: 'Name of the tag to search for',
        },
      },
      required: ['tagName'],
    },
    handler: (args, { tools }) => tools.getTagged(args?.tagName),
  },
];
