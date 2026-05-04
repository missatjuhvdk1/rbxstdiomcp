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
  /** Optional surrounding lines, included only when contextLines > 0. */
  context?: { line: number; text: string }[];
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
}

export interface SearchSummary {
  totalHits: number;
  truncated: boolean;
  hits: SearchHit[];
  /** How many files were scanned (not skipped by extension/scope filters). */
  filesScanned: number;
  /** ms spent inside this call. */
  durationMs: number;
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

export async function searchDocs(
  cacheDir: string,
  pattern: string,
  options: SearchOptions = {},
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
 */
export interface DocListing {
  path: string;
  entries: { name: string; type: 'file' | 'dir'; size?: number }[];
}

export async function listDocs(
  cacheDir: string,
  relPath: string = '',
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
  const result: DocListing['entries'] = [];
  for (const e of entries) {
    if (e.isDirectory()) {
      result.push({ name: e.name, type: 'dir' });
    } else if (e.isFile()) {
      try {
        const stat = await fs.stat(path.join(full, e.name));
        result.push({ name: e.name, type: 'file', size: stat.size });
      } catch {
        result.push({ name: e.name, type: 'file' });
      }
    }
  }
  // Stable order: directories first, then files, alphabetic within each.
  result.sort((a, b) => {
    if (a.type !== b.type) return a.type === 'dir' ? -1 : 1;
    return a.name.localeCompare(b.name);
  });
  return { path: safe, entries: result };
}
