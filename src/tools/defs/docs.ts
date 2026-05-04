import type { ToolDef } from '../types.js';

/**
 * Roblox documentation tools — read-only access to a local mirror of
 * https://github.com/Roblox/creator-docs.
 *
 * The mirror is downloaded lazily on first use and refreshed at most
 * once every 24 hours (with a SHA short-circuit so unchanged upstream
 * = no redownload). See `src/docs/fetcher.ts` for the cache strategy.
 *
 * These tools exist because the model frequently struggles with
 * topics where it has stale or imprecise training data — animation,
 * Motor6D / C0, R6 rig anatomy, ScreenGui properties, etc. Giving it
 * `search_roblox_docs` + `get_roblox_doc` means the canonical answer
 * is always one tool call away.
 */
export const docTools: ToolDef[] = [
  {
    name: 'search_roblox_docs',
    description:
      "Search Roblox's official creator documentation (mirror of github.com/Roblox/creator-docs). " +
      'Returns matching lines with file path, line number, and surrounding context. ' +
      'Use this FIRST when you need authoritative info on a Roblox API, behavior, or guide topic — especially for things AI models commonly get wrong (animation, Motor6D C0/C1, R6/R15 rigs, AlignOrientation, etc.). ' +
      '\n\n**Token-AND mode** (default for multi-word queries): the query is split on whitespace and every token must appear within `window_lines` (default 3) of the anchor line. So `"Motor6D C0"` finds any passage where Motor6D and C0 are mentioned together — even if the docs literally write `Motor6D.C0` or `Class.Motor6D.C0|C0`. This is what you almost always want; do NOT pre-mangle queries to match the docs\' exact punctuation. ' +
      'Wrap a phrase in double quotes to force a literal match, e.g. `"Class.Motor6D.C0"` (one token). Single-token queries fall back to literal substring search. ' +
      '\n\nOn first use the tool downloads ~30MB of docs to a local cache (~5s). Subsequent calls hit the cache instantly and refresh from upstream at most once per 24h.',
    inputSchema: {
      type: 'object',
      properties: {
        query: {
          type: 'string',
          description:
            'Search query. Multiple whitespace-separated words trigger token-AND mode (each token must appear within `window_lines` of the anchor). Use double quotes to force a phrase: `"Class.Motor6D"` is one token. Examples: "Motor6D C0", "AlignOrientation servo", "humanoid animation rig".',
        },
        scope: {
          type: 'string',
          description:
            'Optional: restrict search to a subdirectory of the docs tree. Examples: "en-us/reference/engine/classes", "en-us/animation", "en-us/characters". Useful when a generic term ("frame") would otherwise match thousands of lines.',
        },
        extensions: {
          type: 'array',
          items: { type: 'string' },
          description:
            'File extensions to include (without leading dot). Default ["md","yaml","yml"]. Pass ["yaml"] to search only structured API reference, ["md"] to search only long-form guides.',
        },
        use_regex: {
          type: 'boolean',
          description:
            'Treat `query` as a single JS regex. Disables token-AND mode. Default false.',
          default: false,
        },
        case_sensitive: {
          type: 'boolean',
          description: 'Match case exactly. Default false.',
          default: false,
        },
        context_lines: {
          type: 'number',
          description:
            'Lines of context before/after each hit (like grep -C). 0–10. Default 0 in literal mode; in token-AND mode the matched window is always emitted, and this widens it further if larger than `window_lines`.',
          default: 0,
        },
        window_lines: {
          type: 'number',
          description:
            'Token-AND mode only: how close (in lines) the tokens must appear to count as a hit. 1–10. Default 3. Lower = stricter (tokens on adjacent lines), higher = looser (tokens anywhere in a paragraph).',
          default: 3,
        },
        max_hits: {
          type: 'number',
          description: 'Cap on results returned. Default 200, max 1000.',
          default: 200,
        },
      },
      required: ['query'],
    },
    handler: (args, { tools }) =>
      tools.searchRobloxDocs(
        args?.query,
        {
          scope: args?.scope,
          extensions: args?.extensions,
          useRegex: args?.use_regex ?? false,
          caseSensitive: args?.case_sensitive ?? false,
          contextLines: args?.context_lines ?? 0,
          windowLines: args?.window_lines ?? 3,
          maxHits: args?.max_hits ?? 200,
        },
      ),
  },

  {
    name: 'get_roblox_doc',
    description:
      "Fetch the full content of a single Roblox docs file by its relative path under the cached `content/` tree. " +
      'Use this AFTER `search_roblox_docs` to read the surrounding section once you have a promising hit. ' +
      'For structured API reference (Class/DataType/Enum) prefer `get_roblox_api_reference` — it does the path resolution for you.',
    inputSchema: {
      type: 'object',
      properties: {
        path: {
          type: 'string',
          description:
            'Path relative to the docs content root. Examples: "en-us/animation/using.md", "en-us/reference/engine/classes/Motor6D.yaml". `search_roblox_docs` returns hits in this format already.',
        },
      },
      required: ['path'],
    },
    handler: (args, { tools }) => tools.getRobloxDoc(args?.path),
  },

  {
    name: 'list_roblox_docs',
    description:
      'List directory contents within the cached Roblox docs tree (like `ls`). Use to discover what reference docs or guides exist before searching/reading. ' +
      'Pass an empty path to see top-level locales (just "en-us" today). ' +
      '\n\n**Paginated**: large directories (engine `classes/` has ~1000 entries) are paginated at 100 items by default. The response includes `totalEntries`, `offset`, `limit`, and `truncated`. Bump `offset` to page through, or raise `limit` (max 1000) if you genuinely need everything in one shot — but you almost never do; prefer `search_roblox_docs` or `get_roblox_api_reference` to find a specific entry.',
    inputSchema: {
      type: 'object',
      properties: {
        path: {
          type: 'string',
          description:
            'Path relative to the docs content root. Empty string lists the top level. Examples: "en-us/reference/engine", "en-us/animation".',
          default: '',
        },
        offset: {
          type: 'number',
          description: 'Pagination offset (0-indexed). Default 0.',
          default: 0,
        },
        limit: {
          type: 'number',
          description: 'Page size. Default 100, max 1000.',
          default: 100,
        },
      },
    },
    handler: (args, { tools }) =>
      tools.listRobloxDocs(args?.path ?? '', {
        offset: args?.offset ?? 0,
        limit: args?.limit ?? 100,
      }),
  },

  {
    name: 'get_roblox_api_reference',
    description:
      "Fetch the structured YAML API reference for a Roblox class, datatype, enum, global, or library by name. Returns parsed YAML (with `members`, `properties`, `methods`, etc. depending on category) plus the raw source. " +
      'PREFER THIS over `get_roblox_doc` when you know what you\'re looking for — it does category resolution and case-folding automatically. ' +
      'Examples that work: "Motor6D", "Part", "CFrame", "Vector3", "Material", "KeyCode", "math", "string".',
    inputSchema: {
      type: 'object',
      properties: {
        name: {
          type: 'string',
          description:
            'API name as it appears in Lua/Luau code. Case-insensitive but PascalCase recommended ("Motor6D" not "motor6d").',
        },
        category: {
          type: 'string',
          enum: ['class', 'datatype', 'enum', 'global', 'library'],
          description:
            'Optional category to disambiguate. If omitted, the tool searches in order: class, datatype, enum, global, library — first match wins.',
        },
      },
      required: ['name'],
    },
    handler: (args, { tools }) => tools.getRobloxApiReference(args?.name, args?.category),
  },

];
