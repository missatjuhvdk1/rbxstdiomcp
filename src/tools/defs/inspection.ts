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
    description:
      'Get available properties/methods for a Roblox class via live Studio reflection (what this engine build actually exposes). For canonical docs with descriptions and deprecation notes, use get_roblox_api_reference instead.',
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
    name: 'grep',
    description:
      "Powerful grep over the Roblox instance tree — like Claude Code's Grep, but for the explorer instead of the filesystem. " +
      'Walks descendants of `path` (default `game`), filters by `glob` (Name pattern) and `type` (ClassName / IsA), then searches script `Source` for `pattern`. ' +
      'Use this FIRST when the user mentions a script/instance you have not seen — much faster than browsing get_project_structure.\n\n' +
      '`output_mode` controls the shape: "files_with_matches" (default) = instance paths with hits; "content" = matching lines with numbers + optional context (-A/-B/-C); "count" = per-instance counts. -i, head_limit, and multiline behave like Claude Code Grep.\n\n' +
      'Notes: `pattern` is a Luau string pattern (NOT PCRE — use `%.` for a literal dot). Default `type` is ["LuaSourceContainer"] (all script kinds); Source is only read for those, so to search non-script instances by Name pass a `type` like ["Part"] plus `glob`, and for a Name-only search pass `pattern: ".*"` with a `glob`.',
    inputSchema: {
      type: 'object',
      properties: {
        pattern: {
          type: 'string',
          description:
            'The Luau pattern to search for in script Source. Matched line-by-line by default, or against the whole source if `multiline` is true. To do a name-only search, pass ".*" here and use `glob` to filter by Name.',
        },
        path: {
          type: 'string',
          description:
            'Instance path to scope the search to (e.g. "game.ServerScriptService"). Defaults to "game" (the entire DataModel).',
        },
        glob: {
          type: 'string',
          description:
            'Filter which instances to even consider by their Name (Luau pattern, e.g. "Damage.*", "PlayerHandler"). Analogous to glob in Claude Code Grep.',
        },
        type: {
          type: 'array',
          items: { type: 'string' },
          description:
            'Filter by ClassName(s) or IsA group(s). E.g. ["Script", "LocalScript"], or ["LuaSourceContainer"] (matches all script kinds), or ["GuiObject"] for any UI element. Defaults to ["LuaSourceContainer"]. Each entry is tested with `instance:IsA(name)` so abstract types work.',
        },
        '-i': {
          type: 'boolean',
          description:
            'Case-insensitive matching. Applies to both `pattern` (Source) and `glob` (Name). Default false.',
          default: false,
        },
        '-A': {
          type: 'number',
          description:
            'Lines of context AFTER each match (like grep -A). Requires output_mode="content".',
          default: 0,
        },
        '-B': {
          type: 'number',
          description:
            'Lines of context BEFORE each match (like grep -B). Requires output_mode="content".',
          default: 0,
        },
        '-C': {
          type: 'number',
          description:
            'Lines of context BEFORE AND AFTER each match (like grep -C). Requires output_mode="content". Overrides -A/-B.',
          default: 0,
        },
        output_mode: {
          type: 'string',
          enum: ['files_with_matches', 'content', 'count'],
          description:
            'Output format. "files_with_matches" (default) = paths only, like `grep -l`. "content" = matching lines with line numbers and context. "count" = match count per instance.',
          default: 'files_with_matches',
        },
        head_limit: {
          type: 'number',
          description:
            'Limit output to first N entries across all modes (like `| head -N`). 0 = unlimited (default).',
          default: 0,
        },
        multiline: {
          type: 'boolean',
          description:
            'When true, match the pattern against the entire source as one string (so `.` matches newlines, patterns can span lines). When false (default), match line-by-line.',
          default: false,
        },
      },
      required: ['pattern'],
    },
    handler: (args, { tools }) =>
      tools.grep(args?.pattern, {
        path: args?.path,
        glob: args?.glob,
        type: args?.type,
        caseInsensitive: args?.['-i'] ?? false,
        after: args?.['-A'] ?? 0,
        before: args?.['-B'] ?? 0,
        context: args?.['-C'] ?? 0,
        outputMode: args?.output_mode ?? 'files_with_matches',
        headLimit: args?.head_limit ?? 0,
        multiline: args?.multiline ?? false,
      }),
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
