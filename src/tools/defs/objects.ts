import type { ToolDef } from '../types.js';

/**
 * Object lifecycle tools: create, delete, clone, move, insert from Creator Store.
 */
export const objectTools: ToolDef[] = [
  {
    name: 'create_object',
    description: 'Create a new Roblox object instance (basic, without properties)',
    inputSchema: {
      type: 'object',
      properties: {
        className: {
          type: 'string',
          description: 'Roblox class name (e.g., "Part", "Script", "Folder")',
        },
        parent: {
          type: 'string',
          description: 'Path to the parent instance (e.g., "game.Workspace")',
        },
        name: {
          type: 'string',
          description: 'Optional name for the new object',
        },
      },
      required: ['className', 'parent'],
    },
    handler: (args, { tools }) => tools.createObject(args?.className, args?.parent, args?.name),
  },

  {
    name: 'delete_object',
    description: 'Delete a Roblox object instance',
    inputSchema: {
      type: 'object',
      properties: {
        instancePath: {
          type: 'string',
          description: 'Path to the instance to delete',
        },
      },
      required: ['instancePath'],
    },
    handler: (args, { tools }) => tools.deleteObject(args?.instancePath),
  },

  {
    name: 'clone_instance',
    description:
      'Clone (copy) a Roblox instance to a new parent location. Creates a deep copy including all children and properties.',
    inputSchema: {
      type: 'object',
      properties: {
        sourcePath: {
          type: 'string',
          description: 'Path to the instance to clone (e.g., "game.Workspace.walkietalkie")',
        },
        targetParent: {
          type: 'string',
          description: 'Path to the new parent (e.g., "game.ReplicatedStorage")',
        },
        newName: {
          type: 'string',
          description: 'Optional new name for the cloned instance',
        },
      },
      required: ['sourcePath', 'targetParent'],
    },
    handler: (args, { tools }) =>
      tools.cloneInstance(args?.sourcePath, args?.targetParent, args?.newName),
  },

  {
    name: 'move_instance',
    description: 'Move a Roblox instance to a new parent location. Changes the Parent property.',
    inputSchema: {
      type: 'object',
      properties: {
        instancePath: {
          type: 'string',
          description: 'Path to the instance to move (e.g., "game.Workspace.Tool")',
        },
        newParent: {
          type: 'string',
          description: 'Path to the new parent (e.g., "game.StarterPack")',
        },
      },
      required: ['instancePath', 'newParent'],
    },
    handler: (args, { tools }) => tools.moveInstance(args?.instancePath, args?.newParent),
  },

  {
    name: 'insert_asset',
    description:
      'Download and insert a Creator Store asset (model, package, etc.) into Roblox Studio for reference. Uses game:GetObjects() which works with any free/public asset. Perfect for loading reference code, example implementations, or asset libraries that the AI can then read and analyze using get_instance_children and get_script_source.',
    inputSchema: {
      type: 'object',
      properties: {
        assetId: {
          type: 'number',
          description:
            'The Creator Store asset ID (the number from the asset URL, e.g., 104116977416770)',
        },
        folderName: {
          type: 'string',
          description:
            'Name of the folder to create/use for storing assets (default: "AIReferences")',
          default: 'AIReferences',
        },
        targetParent: {
          type: 'string',
          description:
            'Parent path where the folder should be created (default: "game.Workspace"). Use "game.ReplicatedStorage" or "game.ServerStorage" to keep assets out of the visible workspace.',
          default: 'game.Workspace',
        },
      },
      required: ['assetId'],
    },
    handler: (args, { tools }) =>
      tools.insertAsset(args?.assetId, args?.folderName, args?.targetParent),
  },
];
