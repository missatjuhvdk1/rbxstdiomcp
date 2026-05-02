import type { ToolDef } from '../types.js';

/**
 * Script editing tools — both Claude Code-style (string-based) and
 * legacy line-based — plus search, function extraction, and validation.
 */
export const scriptTools: ToolDef[] = [
  {
    name: 'get_script_source',
    description:
      'Get the source code of a Roblox script (LocalScript, Script, or ModuleScript). Returns both "source" (raw code) and "numberedSource" (with line numbers prefixed like "1: code"). Use numberedSource to accurately identify line numbers for editing. For large scripts (>1500 lines), use startLine/endLine to read specific sections.',
    inputSchema: {
      type: 'object',
      properties: {
        instancePath: {
          type: 'string',
          description:
            'Roblox instance path to the script using dot notation (e.g., "game.ServerScriptService.MainScript", "game.StarterPlayer.StarterPlayerScripts.LocalScript")',
        },
        startLine: {
          type: 'number',
          description:
            'Optional: Start line number (1-indexed). Use for reading specific sections of large scripts.',
        },
        endLine: {
          type: 'number',
          description:
            'Optional: End line number (inclusive). Use for reading specific sections of large scripts.',
        },
      },
      required: ['instancePath'],
    },
    handler: (args, { tools }) =>
      tools.getScriptSource(args?.instancePath, args?.startLine, args?.endLine),
  },

  {
    name: 'set_script_source',
    description:
      'Replace the entire source code of a Roblox script. Uses ScriptEditorService:UpdateSourceAsync (works with open editors). For partial edits, prefer edit_script_lines, insert_script_lines, or delete_script_lines.',
    inputSchema: {
      type: 'object',
      properties: {
        instancePath: {
          type: 'string',
          description:
            'Roblox instance path to the script (e.g., "game.ServerScriptService.MainScript")',
        },
        source: {
          type: 'string',
          description: 'New source code for the script',
        },
      },
      required: ['instancePath', 'source'],
    },
    handler: (args, { tools }) => tools.setScriptSource(args?.instancePath, args?.source),
  },

  {
    name: 'edit_script_lines',
    description:
      'Replace specific lines in a Roblox script without rewriting the entire source. IMPORTANT: Use the "numberedSource" field from get_script_source to identify the correct line numbers. Lines are 1-indexed and ranges are inclusive.',
    inputSchema: {
      type: 'object',
      properties: {
        instancePath: {
          type: 'string',
          description:
            'Roblox instance path to the script (e.g., "game.ServerScriptService.MainScript")',
        },
        startLine: {
          type: 'number',
          description: 'First line to replace (1-indexed). Get this from the "numberedSource" field.',
        },
        endLine: {
          type: 'number',
          description: 'Last line to replace (inclusive). Get this from the "numberedSource" field.',
        },
        newContent: {
          type: 'string',
          description:
            'New content to replace the specified lines (can be multiple lines separated by newlines)',
        },
      },
      required: ['instancePath', 'startLine', 'endLine', 'newContent'],
    },
    handler: (args, { tools }) =>
      tools.editScriptLines(args?.instancePath, args?.startLine, args?.endLine, args?.newContent),
  },

  {
    name: 'insert_script_lines',
    description:
      'Insert new lines into a Roblox script at a specific position. IMPORTANT: Use the "numberedSource" field from get_script_source to identify the correct line numbers.',
    inputSchema: {
      type: 'object',
      properties: {
        instancePath: {
          type: 'string',
          description:
            'Roblox instance path to the script (e.g., "game.ServerScriptService.MainScript")',
        },
        afterLine: {
          type: 'number',
          description:
            'Insert after this line number (0 = insert at very beginning, 1 = after first line). Get line numbers from "numberedSource".',
          default: 0,
        },
        newContent: {
          type: 'string',
          description: 'Content to insert (can be multiple lines separated by newlines)',
        },
      },
      required: ['instancePath', 'newContent'],
    },
    handler: (args, { tools }) =>
      tools.insertScriptLines(args?.instancePath, args?.afterLine, args?.newContent),
  },

  {
    name: 'delete_script_lines',
    description:
      'Delete specific lines from a Roblox script. IMPORTANT: Use the "numberedSource" field from get_script_source to identify the correct line numbers.',
    inputSchema: {
      type: 'object',
      properties: {
        instancePath: {
          type: 'string',
          description:
            'Roblox instance path to the script (e.g., "game.ServerScriptService.MainScript")',
        },
        startLine: {
          type: 'number',
          description: 'First line to delete (1-indexed). Get this from the "numberedSource" field.',
        },
        endLine: {
          type: 'number',
          description: 'Last line to delete (inclusive). Get this from the "numberedSource" field.',
        },
      },
      required: ['instancePath', 'startLine', 'endLine'],
    },
    handler: (args, { tools }) =>
      tools.deleteScriptLines(args?.instancePath, args?.startLine, args?.endLine),
  },

  {
    name: 'edit_script',
    description:
      "RECOMMENDED: String-based script editing like Claude Code's Edit tool. Find exact text and replace it - no line numbers needed! This is the safest and most reliable way to edit scripts. The edit will FAIL safely if old_string is not found or appears multiple times (unless replace_all is true). Always validates syntax after editing.",
    inputSchema: {
      type: 'object',
      properties: {
        instancePath: {
          type: 'string',
          description:
            'Roblox instance path to the script (e.g., "game.ServerScriptService.MainScript")',
        },
        old_string: {
          type: 'string',
          description:
            'The exact text to find and replace (must match exactly, including whitespace/indentation)',
        },
        new_string: {
          type: 'string',
          description: 'The text to replace it with (must be different from old_string)',
        },
        replace_all: {
          type: 'boolean',
          description:
            'If true, replace ALL occurrences of old_string. If false (default), fails if old_string appears more than once.',
          default: false,
        },
        validate_after: {
          type: 'boolean',
          description:
            'If true (default), validates the script syntax after editing and reverts if invalid.',
          default: true,
        },
      },
      required: ['instancePath', 'old_string', 'new_string'],
    },
    handler: (args, { tools }) =>
      tools.editScript(
        args?.instancePath,
        args?.old_string,
        args?.new_string,
        args?.replace_all ?? false,
        args?.validate_after ?? true,
      ),
  },

  {
    name: 'search_script',
    description:
      'Search for patterns within a script source code (like grep). Returns matching lines with line numbers and optional context.',
    inputSchema: {
      type: 'object',
      properties: {
        instancePath: {
          type: 'string',
          description:
            'Roblox instance path to the script (e.g., "game.ServerScriptService.MainScript")',
        },
        pattern: {
          type: 'string',
          description: 'Search pattern (literal string or regex if use_regex is true)',
        },
        use_regex: {
          type: 'boolean',
          description: 'If true, treat pattern as a Lua regex pattern. Default false (literal match).',
          default: false,
        },
        context_lines: {
          type: 'number',
          description: 'Number of lines to show before and after each match (like grep -C). Default 0.',
          default: 0,
        },
      },
      required: ['instancePath', 'pattern'],
    },
    handler: (args, { tools }) =>
      tools.searchScript(
        args?.instancePath,
        args?.pattern,
        args?.use_regex ?? false,
        args?.context_lines ?? 0,
      ),
  },

  {
    name: 'get_script_function',
    description:
      'Extract a specific function from a script by name. Returns the function source code with start/end line numbers. Perfect for editing just one function without affecting the rest of the script.',
    inputSchema: {
      type: 'object',
      properties: {
        instancePath: {
          type: 'string',
          description:
            'Roblox instance path to the script (e.g., "game.ServerScriptService.MainScript")',
        },
        function_name: {
          type: 'string',
          description: 'Name of the function to extract (e.g., "onPlayerJoin", "handleDamage")',
        },
      },
      required: ['instancePath', 'function_name'],
    },
    handler: (args, { tools }) =>
      tools.getScriptFunction(args?.instancePath, args?.function_name),
  },

  {
    name: 'find_and_replace_in_scripts',
    description:
      'Find and replace text across multiple scripts at once. Like edit_script but for batch operations. Validates all scripts after editing.',
    inputSchema: {
      type: 'object',
      properties: {
        paths: {
          type: 'array',
          items: { type: 'string' },
          description: 'Array of script paths to search and replace in',
        },
        old_string: {
          type: 'string',
          description: 'The exact text to find and replace',
        },
        new_string: {
          type: 'string',
          description: 'The text to replace it with',
        },
        validate_after: {
          type: 'boolean',
          description: 'If true (default), validates syntax after each edit.',
          default: true,
        },
      },
      required: ['paths', 'old_string', 'new_string'],
    },
    handler: (args, { tools }) =>
      tools.findAndReplaceInScripts(
        args?.paths,
        args?.old_string,
        args?.new_string,
        args?.validate_after ?? true,
      ),
  },

  {
    name: 'validate_script',
    description:
      'Validate Lua/Luau script syntax without running it. Returns syntax errors and warnings for deprecated patterns (wait, spawn, delay). Can validate either an existing script or raw source code.',
    inputSchema: {
      type: 'object',
      properties: {
        instancePath: {
          type: 'string',
          description:
            'Path to the script to validate (e.g., "game.ServerScriptService.MainScript")',
        },
        source: {
          type: 'string',
          description: 'Raw Lua source code to validate (alternative to instancePath)',
        },
      },
    },
    handler: (args, { tools }) => tools.validateScript(args?.instancePath, args?.source),
  },
];
