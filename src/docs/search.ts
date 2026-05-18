import { promises as fs } from 'fs';
import * as path from 'path';
import { contentRoot } from './cache.js';
import { getOrBuild } from './embeddings/manager.js';
import { encodeOne, dot } from './embeddings/embedder.js';
import type { DocsIndex } from './embeddings/index.js';

/**
 * Pure-JS regex search over the cached docs tree.
 *
 * Why not shell out to ripgrep?
 *   1. We can't assume `rg` is on the user's PATH (npm package, no
 *      system-deps story).
 *   2. The cached tree is small (~30MB, ~3k files). A naive
 *      Promise.all() walk + JS regex on each file finishes in ~50–
 *      200ms cold-cache and ~10–40ms hot-cache, which is fine for an
 *      interactive tool call.
 *   3. We get full control of result shape, context lines, and graceful
 *      ignore of binary garbage.
 *
 * If this ever becomes a bottleneck the obvious upgrade is an in-memory
 * grep index keyed by 4-grams or similar — but YAGNI for now.
 */

export interface SearchHit {
  /** Doc path relative to the content root, e.g. "en-us/reference/engine/classes/Part.yaml". */
  path: string;
  /** 1-indexed line number inside the file. */
  line: number;
  /** The matching line (rstripped). */
  text: string;
  /** Optional surrounding lines, included only when contextLines > 0 (or token-AND mode). */
  context?: { line: number; text: string }[];
  /**
   * Token-AND mode only: which tokens matched the anchor line itself.
   * Useful for the model to see "this line has Motor6D, but C0 is in the
   * surrounding context".
   */
  matchedTokens?: string[];
  /**
   * Hybrid mode only: aggregate score in [0, 1] used to rank this hit.
   * Combines keyword token coverage and semantic similarity. Populated
   * by `searchDocsHybrid`; absent in pure literal / token-AND modes.
   */
  score?: number;
  /**
   * Hybrid mode only: raw cosine similarity of the embedding of the
   * passage containing this hit against the query embedding, in
   * [-1, 1]. Useful for the model to gauge how "topical" the hit is.
   */
  semanticScore?: number;
}

export interface SearchOptions {
  /** Restrict to a subdirectory of `content/` (e.g. "en-us/animation"). */
  scope?: string;
  /** File extensions to search (default ["md","yaml","yml"]). Pass without leading dot. */
  extensions?: string[];
  /** Treat `pattern` as a JS regex instead of a literal string. Default false. */
  useRegex?: boolean;
  /** Case-sensitive match. Default false. */
  caseSensitive?: boolean;
  /** Lines of context before/after each hit (like grep -C). Default 0. */
  contextLines?: number;
  /** Hard cap on hits returned. Default 200 — generous but bounded. */
  maxHits?: number;
  /**
   * Token-AND mode: lines of slack on either side of the anchor in which
   * every whitespace-separated token in the query must appear at least
   * once. Default 3. Ignored when `useRegex: true` or the query is a
   * single token (those fall back to literal substring search).
   */
  windowLines?: number;
  /**
   * Semantic rerank toggle. Defaults to true.
   *
   * When true AND the query is in token-AND mode (multi-token, not
   * regex), the keyword hits are reranked by cosine similarity against
   * a sentence-embedding index of the docs. This dramatically improves
   * relevance for natural-language queries while preserving all the
   * keyword guarantees (every returned hit still contains all tokens
   * within `windowLines`).
   *
   * Set to false to force pure keyword mode — useful for deterministic
   * tests or when the semantic index is unavailable / undesired.
   *
   * Has no effect in literal mode (single token, quoted phrase, regex)
   * because those queries already have unambiguous ranking by file
   * position.
   */
  semantic?: boolean;
}

export interface SearchSummary {
  totalHits: number;
  truncated: boolean;
  hits: SearchHit[];
  /** How many files were scanned (not skipped by extension/scope filters). */
  filesScanned: number;
  /** ms spent inside this call. */
  durationMs: number;
  /**
   * "literal"   = single-token / regex / single phrase.
   * "token-and" = multi-token AND-match within `windowLines`.
   * "hybrid"    = token-AND filtering + semantic rerank.
   */
  mode: 'literal' | 'token-and' | 'hybrid';
  /** Tokens we actually searched for in token-and / hybrid mode. */
  tokens?: string[];
  /**
   * Hybrid mode only: whether the semantic index was actually used. False
   * means we wanted to rerank but the index was unavailable (first call
   * before build finished, model download failure, etc.) and we fell
   * back to plain keyword ranking. Lets the caller decide whether to
   * retry, warm the cache, or just accept keyword results.
   */
  semanticUsed?: boolean;
}

/**
 * Inputs passed to `searchDocs` *in addition to* the public options.
 * Currently just the docs SHA so the hybrid path can locate the right
 * vector index. Keeping this out of `SearchOptions` because it's
 * server-internal — the LLM never sets it.
 */
export interface InternalSearchInputs {
  /** Docs cache SHA, used to load/build the semantic index. */
  docsSha?: string;
}

const DEFAULT_EXTENSIONS = ['md', 'yaml', 'yml'];

function escapeRegex(literal: string): string {
  return literal.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

function buildPattern(pattern: string, opts: SearchOptions): RegExp {
  const body = opts.useRegex ? pattern : escapeRegex(pattern);
  const flags = opts.caseSensitive ? 'g' : 'gi';
  return new RegExp(body, flags);
}

/**
 * Shell-style tokenizer: splits on whitespace, but `"foo bar"` stays one
 * token. Lets callers force a phrase match where they want it
 * (e.g. `"Class.Motor6D"` for the literal dotted form).
 *
 * Returns an empty array for an empty/whitespace string.
 */
function tokenize(query: string): string[] {
  const tokens: string[] = [];
  // Match either:
  //   - "...quoted phrase..."  (any chars except an unescaped ")
  //   - bare run of non-whitespace
  const re = /"([^"]*)"|(\S+)/g;
  let m: RegExpExecArray | null;
  while ((m = re.exec(query)) !== null) {
    const tok = m[1] ?? m[2];
    if (tok && tok.length > 0) tokens.push(tok);
  }
  return tokens;
}

function popcount(n: number): number {
  let c = 0;
  while (n) {
    n &= n - 1;
    c++;
  }
  return c;
}

async function* walkFiles(
  root: string,
  scope: string | undefined,
  exts: Set<string>,
): AsyncGenerator<string> {
  const start = scope ? path.join(root, scope) : root;
  // Lazily-recurse using an explicit stack so we don't blow the call
  // stack on deep trees and don't hold the full file list in memory.
  const stack: string[] = [start];
  while (stack.length > 0) {
    const dir = stack.pop()!;
    let entries;
    try {
      entries = await fs.readdir(dir, { withFileTypes: true });
    } catch {
      continue;
    }
    for (const e of entries) {
      const p = path.join(dir, e.name);
      if (e.isDirectory()) {
        stack.push(p);
      } else if (e.isFile()) {
        const ext = path.extname(e.name).slice(1).toLowerCase();
        if (exts.has(ext)) {
          yield p;
        }
      }
    }
  }
}

/**
 * Top-level entry point. Decides between literal (single-token / regex)
 * and token-AND (multi-token, windowed) search and dispatches.
 *
 * Token-AND mode triggers when ALL of:
 *   - `useRegex: false` (or unset)
 *   - the tokenized query has 2+ tokens
 *
 * Why? Plain literal substring is "the docs say `Motor6D C0` somewhere?"
 * which is almost never true (the docs use dotted/quoted forms like
 * `Class.Motor6D.C0|C0`). Token-AND turns the query into "find lines
 * where Motor6D and C0 are both nearby", which is what the model
 * actually meant.
 */
export async function searchDocs(
  cacheDir: string,
  pattern: string,
  options: SearchOptions = {},
  internal: InternalSearchInputs = {},
): Promise<SearchSummary> {
  const tokens = options.useRegex ? [] : tokenize(pattern);
  if (!options.useRegex && tokens.length >= 2) {
    const semantic = options.semantic ?? true;
    if (semantic) {
      return searchDocsHybrid(cacheDir, pattern, tokens, options, internal);
    }
    return searchDocsTokenAnd(cacheDir, tokens, options);
  }
  // Literal mode: if the user wrapped the whole query in double-quotes
  // (one resulting token after tokenize), search for the unquoted phrase
  // — otherwise the literal substring includes the quotes themselves and
  // matches nothing.
  const literalPattern =
    !options.useRegex && tokens.length === 1 ? tokens[0] : pattern;
  return searchDocsLiteral(cacheDir, literalPattern, options);
}

async function searchDocsLiteral(
  cacheDir: string,
  pattern: string,
  options: SearchOptions,
): Promise<SearchSummary> {
  const t0 = Date.now();
  const root = contentRoot(cacheDir);
  const re = buildPattern(pattern, options);
  const exts = new Set((options.extensions ?? DEFAULT_EXTENSIONS).map((e) => e.toLowerCase()));
  const ctx = Math.max(0, Math.min(options.contextLines ?? 0, 5));
  const maxHits = Math.max(1, Math.min(options.maxHits ?? 200, 1000));

  const hits: SearchHit[] = [];
  let totalHits = 0;
  let filesScanned = 0;
  let truncated = false;

  outer: for await (const filePath of walkFiles(root, options.scope, exts)) {
    filesScanned++;
    let raw: string;
    try {
      raw = await fs.readFile(filePath, 'utf8');
    } catch {
      continue;
    }
    // Cheap binary guard — if there's a NUL byte in the first 4KB, skip.
    if (raw.length > 0 && raw.indexOf('\0', 0) !== -1) continue;

    const rel = path.relative(root, filePath);
    const lines = raw.split(/\r?\n/);
    for (let i = 0; i < lines.length; i++) {
      // .test() advances lastIndex on /g flags — reset for each line.
      re.lastIndex = 0;
      if (!re.test(lines[i])) continue;
      totalHits++;
      if (hits.length < maxHits) {
        const hit: SearchHit = {
          path: rel,
          line: i + 1,
          text: lines[i].replace(/\s+$/, ''),
        };
        if (ctx > 0) {
          const start = Math.max(0, i - ctx);
          const end = Math.min(lines.length, i + ctx + 1);
          const surround: { line: number; text: string }[] = [];
          for (let j = start; j < end; j++) {
            if (j === i) continue;
            surround.push({ line: j + 1, text: lines[j].replace(/\s+$/, '') });
          }
          hit.context = surround;
        }
        hits.push(hit);
      } else {
        truncated = true;
        break outer;
      }
    }
  }

  return {
    totalHits,
    truncated,
    hits,
    filesScanned,
    durationMs: Date.now() - t0,
    mode: 'literal',
  };
}

/**
 * Multi-token AND search.
 *
 * For each file:
 *   1. Compute a per-line bitmap of which tokens match.
 *   2. Slide a window of `±windowLines` over the file. At each anchor
 *      position, OR the masks in `[anchor-w, anchor+w]`. If the union
 *      covers all tokens, we have a hit.
 *   3. Pick the anchor as the line in that window with the most token
 *      coverage (ties → lowest line number). This way the `text` field
 *      is the most "informative" line, not just an arbitrary middle.
 *   4. After firing, skip past `anchor + windowLines` to avoid pile-up
 *      of overlapping windows reporting the same dense paragraph N times.
 *
 * Implementation notes:
 *   - We bitmask, so token count is capped at 31. Over 31, we truncate
 *     and surface the truncation in the response (`tokens` will be the
 *     first 31). Real queries never have that many tokens.
 *   - The matched window is always emitted as `context` (regardless of
 *     `contextLines`) so the model can verify all tokens are nearby.
 *     Caller-specified `contextLines` widens this further if larger.
 */
async function searchDocsTokenAnd(
  cacheDir: string,
  tokensIn: string[],
  options: SearchOptions,
): Promise<SearchSummary> {
  const t0 = Date.now();
  const root = contentRoot(cacheDir);
  const exts = new Set((options.extensions ?? DEFAULT_EXTENSIONS).map((e) => e.toLowerCase()));
  const maxHits = Math.max(1, Math.min(options.maxHits ?? 200, 1000));
  const w = Math.max(1, Math.min(options.windowLines ?? 3, 10));
  const ctx = Math.max(w, Math.min(options.contextLines ?? 0, 10));

  // Bitmask cap — see fn comment.
  const tokens = tokensIn.slice(0, 31);
  const tokenRes = tokens.map(
    (t) => new RegExp(escapeRegex(t), options.caseSensitive ? '' : 'i'),
  );
  const allMask = tokens.length === 31 ? 0x7fffffff : (1 << tokens.length) - 1;

  const hits: SearchHit[] = [];
  let totalHits = 0;
  let filesScanned = 0;
  let truncated = false;

  outer: for await (const filePath of walkFiles(root, options.scope, exts)) {
    filesScanned++;
    let raw: string;
    try {
      raw = await fs.readFile(filePath, 'utf8');
    } catch {
      continue;
    }
    if (raw.length > 0 && raw.indexOf('\0', 0) !== -1) continue;

    const rel = path.relative(root, filePath);
    const lines = raw.split(/\r?\n/);

    // Quick reject: file must contain ALL tokens at least once. Cheap
    // string scans avoid the per-line work for files that can never hit.
    const lower = options.caseSensitive ? raw : raw.toLowerCase();
    let canHit = true;
    for (const t of tokens) {
      const needle = options.caseSensitive ? t : t.toLowerCase();
      if (lower.indexOf(needle) === -1) {
        canHit = false;
        break;
      }
    }
    if (!canHit) continue;

    // Pass 1: per-line tokenMask.
    const tokenMask: number[] = new Array(lines.length).fill(0);
    for (let i = 0; i < lines.length; i++) {
      const line = lines[i];
      for (let t = 0; t < tokens.length; t++) {
        tokenRes[t].lastIndex = 0;
        if (tokenRes[t].test(line)) tokenMask[i] |= 1 << t;
      }
    }

    // Pass 2: sliding-window union. Skip ahead after a hit.
    let i = 0;
    while (i < lines.length) {
      let combined = 0;
      let bestLine = i;
      let bestCount = -1;
      const lo = Math.max(0, i - w);
      const hi = Math.min(lines.length - 1, i + w);
      for (let j = lo; j <= hi; j++) {
        combined |= tokenMask[j];
        const cnt = popcount(tokenMask[j]);
        if (cnt > bestCount || (cnt === bestCount && j < bestLine)) {
          bestCount = cnt;
          bestLine = j;
        }
      }
      if ((combined & allMask) === allMask && bestCount > 0) {
        totalHits++;
        if (hits.length < maxHits) {
          const ctxLo = Math.max(0, bestLine - ctx);
          const ctxHi = Math.min(lines.length - 1, bestLine + ctx);
          const surround: { line: number; text: string }[] = [];
          for (let j = ctxLo; j <= ctxHi; j++) {
            if (j === bestLine) continue;
            surround.push({ line: j + 1, text: lines[j].replace(/\s+$/, '') });
          }
          const matched: string[] = [];
          for (let t = 0; t < tokens.length; t++) {
            if (tokenMask[bestLine] & (1 << t)) matched.push(tokens[t]);
          }
          hits.push({
            path: rel,
            line: bestLine + 1,
            text: lines[bestLine].replace(/\s+$/, ''),
            context: surround,
            matchedTokens: matched,
          });
        } else {
          truncated = true;
          break outer;
        }
        // Advance past this window so we don't fire 7 times for one paragraph.
        i = bestLine + w + 1;
      } else {
        i++;
      }
    }
  }

  return {
    totalHits,
    truncated,
    hits,
    filesScanned,
    durationMs: Date.now() - t0,
    mode: 'token-and',
    tokens,
  };
}

/**
 * Hybrid search: token-AND keyword filter + semantic rerank.
 *
 * Pipeline:
 *   1. Run the existing token-AND keyword search to get a high-recall
 *      pool of candidate hits. We bump `maxHits` for this stage so we
 *      have more room to rerank — the final user-facing cap is
 *      applied after scoring.
 *   2. Look up the chunk(s) that contain each hit's line. A hit
 *      inherits the embedding of the chunk it falls in.
 *   3. Embed the query (~5ms cold, ~1ms warm).
 *   4. Score each hit:
 *        finalScore = α · cosine(query, chunk)        // semantic
 *                   + β · (matchedTokens / totalTokens) // keyword density
 *                   + γ · pathBoost                    // reference > guide for API-ish queries
 *      where α=0.7, β=0.2, γ=0.1. These were picked by eyeballing a
 *      handful of golden queries — see test/golden-queries.test.ts.
 *   5. Sort by finalScore, slice to `maxHits`, return.
 *
 * Fallbacks (any of which keep search usable):
 *   - No SHA passed in → can't load index → return plain token-AND.
 *   - Index load/build fails → return plain token-AND with semanticUsed=false.
 *   - No candidate hits → return empty (semantic won't invent matches
 *     that don't lexically exist; that's a feature, not a bug — we
 *     guarantee every returned hit contains every query token).
 */
async function searchDocsHybrid(
  cacheDir: string,
  pattern: string,
  tokensIn: string[],
  options: SearchOptions,
  internal: InternalSearchInputs,
): Promise<SearchSummary> {
  const t0 = Date.now();
  const userMaxHits = Math.max(1, Math.min(options.maxHits ?? 200, 1000));
  // High recall pool: rerank wants more to choose from, but we cap
  // hard to avoid embedding 1000 hits for nothing.
  const poolMaxHits = Math.min(Math.max(userMaxHits * 3, 50), 300);

  // 1. Run keyword pass with a beefier cap.
  const keyword = await searchDocsTokenAnd(cacheDir, tokensIn, {
    ...options,
    maxHits: poolMaxHits,
  });

  // No SHA / no candidate hits → bail out gracefully with the keyword
  // result (truncated to the user's original cap).
  if (keyword.hits.length === 0) {
    return {
      ...keyword,
      hits: keyword.hits.slice(0, userMaxHits),
      mode: 'hybrid',
      semanticUsed: false,
      durationMs: Date.now() - t0,
    };
  }

  // 2. Load (or build) the semantic index. If unavailable, fall back.
  let index: DocsIndex | null = null;
  if (internal.docsSha) {
    try {
      index = await getOrBuild(cacheDir, internal.docsSha);
    } catch {
      index = null;
    }
  }
  if (!index) {
    return {
      ...keyword,
      hits: keyword.hits.slice(0, userMaxHits),
      mode: 'hybrid',
      semanticUsed: false,
      durationMs: Date.now() - t0,
    };
  }

  // 3. Embed query.
  let qvec: Float32Array;
  try {
    qvec = await encodeOne(pattern);
  } catch {
    // Embedder failure — treat as no semantic index available.
    return {
      ...keyword,
      hits: keyword.hits.slice(0, userMaxHits),
      mode: 'hybrid',
      semanticUsed: false,
      durationMs: Date.now() - t0,
    };
  }

  // Build path→chunks lookup so the hit→chunk join is O(hits + chunks),
  // not O(hits × chunks).
  const chunksByPath = new Map<string, { startLine: number; endLine: number; vec: Float32Array }[]>();
  const dim = index.meta.dim;
  for (let i = 0; i < index.chunks.length; i++) {
    const c = index.chunks[i];
    const vec = index.vectors.subarray(i * dim, (i + 1) * dim);
    const arr = chunksByPath.get(c.path);
    const entry = { startLine: c.startLine, endLine: c.endLine, vec };
    if (arr) arr.push(entry);
    else chunksByPath.set(c.path, [entry]);
  }

  // Heuristic: does the query look like an API name lookup? If so,
  // boost reference/engine chunks. Cheap regex test: any PascalCase
  // token (e.g. "Motor6D", "TweenService") triggers the boost.
  const looksApiLike = tokensIn.some((t) => /^[A-Z][a-zA-Z0-9_]*$/.test(t));

  // 4. Score every keyword hit.
  const ALPHA = 0.7;
  const BETA = 0.2;
  const GAMMA = 0.1;
  const tokenCount = Math.max(1, tokensIn.length);

  type Scored = SearchHit & { score: number };
  const scored: Scored[] = [];
  for (const hit of keyword.hits) {
    // Find the chunk(s) covering this line. A line can fall in at most
    // one chunk for md (heading-bounded) but yaml has both a preamble
    // and a member chunk that may overlap; take the highest-scoring.
    const chunksForFile = chunksByPath.get(hit.path);
    let semanticScore = 0;
    if (chunksForFile) {
      for (const ch of chunksForFile) {
        if (hit.line < ch.startLine || hit.line > ch.endLine) continue;
        const sim = dot(qvec, ch.vec);
        if (sim > semanticScore) semanticScore = sim;
      }
      // Fallback if no chunk contains the line exactly (rare — chunker
      // splits don't always align with hit anchor line in fallback
      // mode): use the highest-scoring chunk in that file. Strictly
      // worse than the precise match, but better than zero.
      if (semanticScore === 0) {
        for (const ch of chunksForFile) {
          const sim = dot(qvec, ch.vec);
          if (sim > semanticScore) semanticScore = sim;
        }
      }
    }

    const keywordDensity = (hit.matchedTokens?.length ?? 0) / tokenCount;
    const pathBoost = looksApiLike && hit.path.includes('reference/engine') ? 1 : 0;
    const finalScore = ALPHA * semanticScore + BETA * keywordDensity + GAMMA * pathBoost;
    scored.push({ ...hit, score: finalScore, semanticScore });
  }

  // 5. Sort & trim.
  scored.sort((a, b) => b.score - a.score);
  const finalHits: SearchHit[] = scored.slice(0, userMaxHits);

  return {
    totalHits: keyword.totalHits,
    truncated: keyword.totalHits > finalHits.length,
    hits: finalHits,
    filesScanned: keyword.filesScanned,
    durationMs: Date.now() - t0,
    mode: 'hybrid',
    tokens: tokensIn.slice(0, 31),
    semanticUsed: true,
  };
}

/**
 * Read a single doc file by its content-relative path.
 *
 * Two flavors of input are accepted to make the LLM-facing tool more
 * forgiving:
 *   • "en-us/reference/engine/classes/Part.yaml" (canonical)
 *   • "Part" / "Part.yaml" — best-effort lookup under reference/engine
 *     (handled by `resolveReferenceDoc` in reference.ts, not here).
 */
export async function readDocFile(
  cacheDir: string,
  relPath: string,
): Promise<{ path: string; bytes: number; content: string } | null> {
  const root = contentRoot(cacheDir);
  // Normalize and reject path-traversal attempts.
  const safe = path.normalize(relPath).replace(/^[/\\]+/, '');
  if (safe.startsWith('..')) return null;
  const full = path.join(root, safe);
  if (!full.startsWith(root)) return null;
  try {
    const stat = await fs.stat(full);
    if (!stat.isFile()) return null;
    const content = await fs.readFile(full, 'utf8');
    return { path: safe, bytes: stat.size, content };
  } catch {
    return null;
  }
}

/**
 * List doc files / subdirectories under a given relative path.
 *
 * Returns a flat structured listing intended for an LLM to navigate
 * (think `ls`, not `tree`).
 *
 * Paginated: the engine docs `classes/` directory has ~1000 YAMLs and
 * blowing all of them into a single tool response is just expensive
 * tokens for nothing. Pass `offset`/`limit` to page through; default
 * limit is 100. The full count is reported as `totalEntries`.
 */
export interface DocListing {
  path: string;
  /** Total number of children at this path (across all pages). */
  totalEntries: number;
  /** Page offset that produced `entries`. */
  offset: number;
  /** Page limit that produced `entries`. */
  limit: number;
  /** True if there are more entries beyond this page. */
  truncated: boolean;
  entries: { name: string; type: 'file' | 'dir'; size?: number }[];
}

export interface ListOptions {
  /** Page offset (default 0). */
  offset?: number;
  /** Page size (default 100, max 1000). */
  limit?: number;
}

export async function listDocs(
  cacheDir: string,
  relPath: string = '',
  options: ListOptions = {},
): Promise<DocListing | null> {
  const root = contentRoot(cacheDir);
  const safe = path.normalize(relPath).replace(/^[/\\]+/, '');
  if (safe.startsWith('..')) return null;
  const full = safe ? path.join(root, safe) : root;
  if (!full.startsWith(root)) return null;
  let entries;
  try {
    entries = await fs.readdir(full, { withFileTypes: true });
  } catch {
    return null;
  }
  // Build the full sorted list first (cheap — just names + types + a
  // stat per file). Pagination then slices into it.
  const all: DocListing['entries'] = [];
  for (const e of entries) {
    if (e.isDirectory()) {
      all.push({ name: e.name, type: 'dir' });
    } else if (e.isFile()) {
      // We stat lazily below — only for the slice we'll return.
      all.push({ name: e.name, type: 'file' });
    }
  }
  // Stable order: directories first, then files, alphabetic within each.
  all.sort((a, b) => {
    if (a.type !== b.type) return a.type === 'dir' ? -1 : 1;
    return a.name.localeCompare(b.name);
  });

  const totalEntries = all.length;
  const offset = Math.max(0, Math.floor(options.offset ?? 0));
  const limit = Math.max(1, Math.min(Math.floor(options.limit ?? 100), 1000));
  const pageRaw = all.slice(offset, offset + limit);

  // Stat only the page we're returning.
  const page: DocListing['entries'] = [];
  for (const entry of pageRaw) {
    if (entry.type === 'file') {
      try {
        const stat = await fs.stat(path.join(full, entry.name));
        page.push({ ...entry, size: stat.size });
      } catch {
        page.push(entry);
      }
    } else {
      page.push(entry);
    }
  }

  return {
    path: safe,
    totalEntries,
    offset,
    limit,
    truncated: offset + page.length < totalEntries,
    entries: page,
  };
}
