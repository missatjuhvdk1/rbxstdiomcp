import type { ToolDef } from '../types.js';

/**
 * Script editing tools — string-based (Claude Code-style) only.
 *
 * The legacy line-based partial editors (edit_script_lines /
 * insert_script_lines / delete_script_lines) were removed: line numbers
 * shift on every edit, the model has to count manually, and `edit_script`
 * does the same job more reliably with exact string matching + automatic
 * syntax validation.
 *
 * `search_script` was also removed: the `grep` tool (inspection.ts)
 * supersedes it — passing a single script path as `grep`'s `path` does
 * the exact same single-script search, plus everything `grep` adds
 * (cross-file, glob/type filters, output modes, head limits). Keeping
 * two near-identical tools just creates choice paralysis for the LLM.
 */
export const scriptTools: ToolDef[] = [
  {
    name: 'get_script_source',
    description:
      'Read the source of a Roblox script (LocalScript, Script, or ModuleScript). Returns both `source` (raw) and `numberedSource` (line-numbered, like `cat -n`). ' +
      '⚠️ For scripts >500 lines, you SHOULD pass `startLine`/`endLine` instead of slurping the whole file — or better, use `search_script` / `get_script_function` to pull just the part you need.',
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
            'Optional: Start line number (1-indexed). RECOMMENDED for any script >500 lines.',
        },
        endLine: {
          type: 'number',
          description:
            'Optional: End line number (inclusive). RECOMMENDED for any script >500 lines.',
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
      '⚠️ EXPENSIVE — FOR FULL REWRITES OR NEW-SCRIPT POPULATION ONLY. Replaces the ENTIRE source of a script. ' +
      'For any partial change (adding a function, fixing a bug, refactoring a block) use `edit_script` instead — it is dramatically cheaper in tokens and far less likely to silently truncate the file. ' +
      'Use this tool only when: (a) you just created the script via `create_object` and are populating it from scratch, or (b) you genuinely want to overwrite >80% of the existing source.',
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
          description: 'New source code for the script (replaces the entire existing content)',
        },
      },
      required: ['instancePath', 'source'],
    },
    handler: (args, { tools }) => tools.setScriptSource(args?.instancePath, args?.source),
  },

  {
    name: 'edit_script',
    description:
      "RECOMMENDED for all partial script edits. String-based editing like Claude Code's Edit tool: find exact text and replace it — no line numbers, no shifting offsets, no truncation risk. " +
      'Fails safely if `old_string` is not found, or appears more than once (unless `replace_all` is true). Validates Luau syntax after the edit and reverts if broken.',
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
      'Find and replace text across multiple scripts at once. Like `edit_script` but for batch operations. Validates all scripts after editing.',
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
