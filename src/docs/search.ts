import { promises as fs } from 'fs';
import * as path from 'path';
import { contentRoot } from './cache.js';

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
   * "literal" = single-token / regex / single phrase.
   * "token-and" = multi-token AND-match within `windowLines`.
   */
  mode: 'literal' | 'token-and';
  /** Tokens we actually searched for in token-and mode. */
  tokens?: string[];
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
): Promise<SearchSummary> {
  const tokens = options.useRegex ? [] : tokenize(pattern);
  if (!options.useRegex && tokens.length >= 2) {
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
