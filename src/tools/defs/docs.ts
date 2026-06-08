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
      'Returns matching passages with file path, line number, and surrounding context (plus a relevance score in hybrid mode). ' +
      'Use this FIRST for authoritative info on a Roblox API or behavior — especially things models get wrong (animation, Motor6D C0/C1, R6/R15 rigs, AlignOrientation, etc.). ' +
      '\n\nMulti-word queries use **hybrid mode**: meaningful tokens (stopwords stripped) must all appear within `window_lines` of each other, then hits are reranked by semantic similarity to your full query (`keywordFiltered: true`). If that finds nothing it falls back to pure-semantic top-K (`keywordFiltered: false` — topically relevant, not guaranteed to contain every term). Single tokens, regex, and quoted phrases use literal substring search. Wrap a phrase in double quotes to force one literal token, e.g. `"Class.Motor6D.C0"`. Pass `semantic: false` for deterministic keyword-only ranking. ' +
      '\n\nFirst use downloads ~30MB of docs (~5s) and builds a one-time semantic index (~25MB model + embeds ~19k chunks; minutes on a single CPU). Until the index is ready the tool falls back to keyword ranking and sets `semanticUsed: false`. Subsequent calls hit the cache instantly (refreshed at most once per 24h).',
    inputSchema: {
      type: 'object',
      properties: {
        query: {
          type: 'string',
          description:
            'Search query. Multiple whitespace-separated words trigger hybrid mode (keyword token-AND + semantic rerank). Single tokens / regex / quoted phrases use literal substring search. Use double quotes to force a phrase: `"Class.Motor6D"` is one token. Examples: "Motor6D C0", "AlignOrientation servo", "how do I rotate a body part smoothly", "humanoid animation rig".',
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
            'Treat `query` as a single JS regex. Disables hybrid mode (no token splitting, no semantic rerank). Default false.',
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
            'Lines of context before/after each hit (like grep -C). 0–10. Default 0 in literal mode; in hybrid mode the matched token-AND window is always emitted, and this widens it further if larger than `window_lines`.',
          default: 0,
        },
        window_lines: {
          type: 'number',
          description:
            'Hybrid / token-AND mode only: how close (in lines) the tokens must appear to count as a hit. 1–10. Default 3. Lower = stricter (tokens on adjacent lines), higher = looser (tokens anywhere in a paragraph).',
          default: 3,
        },
        max_hits: {
          type: 'number',
          description:
            'Cap on results returned. Default 200, max 1000. In hybrid mode, an internal high-recall pool of up to 3× this is generated for reranking, then the top `max_hits` by relevance are returned.',
          default: 200,
        },
        semantic: {
          type: 'boolean',
          description:
            'Toggle semantic reranking for multi-token queries. Default true. Set to false to force plain keyword ranking (faster, deterministic, no model load). Has no effect on single-token / regex / quoted-phrase queries.',
          default: true,
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
          semantic: args?.semantic ?? true,
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
      'List directory contents within the cached Roblox docs tree (like `ls`) to discover what reference docs or guides exist. An empty path lists top-level locales ("en-us"). Paginated at 100 (response has totalEntries/offset/limit/truncated; max limit 1000) — but prefer search_roblox_docs or get_roblox_api_reference to find a specific entry.',
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
