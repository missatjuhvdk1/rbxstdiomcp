import { promises as fs } from 'fs';
import * as path from 'path';
import { contentRoot } from '../cache.js';

/**
 * Chunker for the Roblox creator-docs mirror.
 *
 * Goal: turn the on-disk md/yaml files into bite-sized, semantically
 * coherent passages suitable for sentence-embedding. We index the
 * resulting chunks once (per docs SHA) and rerank keyword hits against
 * them at query time.
 *
 * Strategy per file type:
 *
 *   .md   → split on top-level (`#`) and second-level (`##`) ATX
 *           headings. Each chunk = heading + body until the next
 *           heading of equal/higher level. Long chunks are further
 *           split on `###` and then on paragraph boundaries until they
 *           fit MAX_CHUNK_CHARS.
 *
 *   .yaml → the Roblox API schema is a single top-level document with
 *           a `properties:` / `methods:` / `events:` list of members.
 *           Each member is its own chunk (name + description + tags).
 *           Top-level fields (summary, description, code_samples) get
 *           one preamble chunk so a query like "Motor6D" — which
 *           matches the class-level summary, not any specific member —
 *           still has something to rank against.
 *
 * Each chunk records its source path and the line range it covers so
 * downstream code can deep-link back to the original file (matches the
 * shape `searchDocs` already returns: { path, line, ... }).
 *
 * Why ranges and not single lines? An embedding represents a passage,
 * not a single line. When a chunk wins on cosine score we want to point
 * the model at the whole passage, not just the heading.
 */

export interface Chunk {
  /** Doc path relative to the content root. Same shape as SearchHit.path. */
  path: string;
  /** 1-indexed inclusive start line in the source file. */
  startLine: number;
  /** 1-indexed inclusive end line in the source file. */
  endLine: number;
  /**
   * The text we feed to the embedder. Includes the heading / member
   * name as a prefix so the model knows what the passage is about
   * (sentence-transformers do better with explicit context).
   */
  text: string;
  /**
   * Short label for debugging / UI: the heading, member name, or
   * "<preamble>" for the file-level chunk.
   */
  label: string;
  /**
   * Categorical hint used by the hybrid scorer to bias certain queries.
   * Mirrors the reference categories in `reference.ts`.
   */
  kind: 'md-section' | 'yaml-preamble' | 'yaml-member' | 'yaml-misc';
}

/**
 * Hard cap on chunk size in characters. all-MiniLM-L6-v2 truncates at
 * 256 wordpieces (~1000 chars of English). Going much higher just gets
 * truncated and wastes embedding compute. We aim a bit under so the
 * heading prefix + body fits cleanly.
 *
 * Lower bound — chunks smaller than MIN_CHUNK_CHARS get merged with
 * the next one so we don't emit dozens of useless "## Examples" stubs.
 */
const MAX_CHUNK_CHARS = 900;
const MIN_CHUNK_CHARS = 40;

/**
 * File extensions the chunker handles. Anything else is silently
 * skipped (binaries, images, etc. shouldn't be in the filtered cache
 * but we don't rely on that).
 */
const CHUNKABLE_EXTENSIONS = new Set(['.md', '.yaml', '.yml']);

// ---------- Markdown ----------

/**
 * Split markdown into heading-bounded sections.
 *
 * Edge cases handled:
 *  - Code fences (```...```) — heading-looking lines inside fences
 *    are ignored. (Without this we'd split on a `# comment` inside a
 *    Lua snippet, which would be wrong.)
 *  - Documents with no headings at all → one big chunk per
 *    MAX_CHUNK_CHARS slice.
 *  - Front-matter (`---\n...\n---` at the top) — treated as a
 *    preamble chunk.
 */
function chunkMarkdown(relPath: string, raw: string): Chunk[] {
  const lines = raw.split(/\r?\n/);
  const sections: { start: number; end: number; heading: string; level: number }[] = [];

  let inFence = false;
  let lastHeadingIdx = -1;
  let lastHeading = '';
  let lastLevel = 0;

  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    // Toggle on triple-backtick fences (and tilde, less common).
    if (/^\s*(```|~~~)/.test(line)) {
      inFence = !inFence;
      continue;
    }
    if (inFence) continue;

    // ATX heading: 1–6 `#` chars at line start, then space, then text.
    const m = /^(#{1,6})\s+(.+?)\s*#*\s*$/.exec(line);
    if (!m) continue;

    if (lastHeadingIdx >= 0) {
      sections.push({
        start: lastHeadingIdx,
        end: i - 1,
        heading: lastHeading,
        level: lastLevel,
      });
    } else if (i > 0) {
      // Content before any heading → preamble.
      sections.push({
        start: 0,
        end: i - 1,
        heading: '<preamble>',
        level: 0,
      });
    }
    lastHeadingIdx = i;
    lastHeading = m[2];
    lastLevel = m[1].length;
  }

  // Close out the trailing section (or whole file if no headings).
  if (lastHeadingIdx >= 0) {
    sections.push({
      start: lastHeadingIdx,
      end: lines.length - 1,
      heading: lastHeading,
      level: lastLevel,
    });
  } else if (sections.length === 0) {
    sections.push({
      start: 0,
      end: lines.length - 1,
      heading: '<preamble>',
      level: 0,
    });
  }

  const chunks: Chunk[] = [];
  for (const sec of sections) {
    const body = lines.slice(sec.start, sec.end + 1).join('\n').trim();
    if (body.length === 0) continue;
    // Heading already lives in `body[0]` for non-preamble sections —
    // don't double-add it. For preamble we prepend a label so the
    // embedder has *some* context.
    const text =
      sec.heading === '<preamble>'
        ? `${pathToLabel(relPath)}\n${body}`
        : body;

    // Split oversize sections on blank lines until each piece fits.
    const pieces = splitOversize(text, sec.start, sec.end);
    for (const p of pieces) {
      // Skip pure-stub chunks ("## Examples" with no body underneath).
      if (p.text.replace(/^#+\s.*$/m, '').trim().length < MIN_CHUNK_CHARS) {
        // ...unless the heading itself is informative enough to keep
        // (rare; usually it's not, so we skip).
        continue;
      }
      chunks.push({
        path: relPath,
        startLine: p.startLine,
        endLine: p.endLine,
        text: p.text,
        label: sec.heading === '<preamble>' ? '<preamble>' : sec.heading,
        kind: 'md-section',
      });
    }
  }
  return chunks;
}

/**
 * Split a too-long chunk along blank-line boundaries. Each output
 * piece carries the line range from its slice of the original.
 *
 * Lines are recomputed: each piece's line range is computed by walking
 * the text and counting newlines from the parent's startLine.
 */
function splitOversize(
  text: string,
  parentStart: number,
  parentEnd: number,
): { text: string; startLine: number; endLine: number }[] {
  if (text.length <= MAX_CHUNK_CHARS) {
    return [
      { text, startLine: parentStart + 1, endLine: parentEnd + 1 },
    ];
  }
  // Split on blank lines, then greedily merge into MAX_CHUNK_CHARS bins.
  const paragraphs = text.split(/\n\s*\n/);
  const out: { text: string; startLine: number; endLine: number }[] = [];
  let buf = '';
  let bufLines = 0;
  let cursor = parentStart;
  let bufStart = parentStart;

  const flush = () => {
    if (!buf.trim()) return;
    out.push({
      text: buf.trim(),
      startLine: bufStart + 1,
      endLine: bufStart + Math.max(1, bufLines),
    });
  };

  for (const p of paragraphs) {
    const plines = p.split(/\r?\n/).length;
    // +2 for the blank line we just split on.
    const need = (buf ? 2 : 0) + p.length;
    if (buf && buf.length + need > MAX_CHUNK_CHARS) {
      flush();
      buf = p;
      bufStart = cursor;
      bufLines = plines;
    } else {
      if (buf) {
        buf += '\n\n' + p;
        bufLines += plines + 1; // +1 for blank line
      } else {
        buf = p;
        bufStart = cursor;
        bufLines = plines;
      }
    }
    cursor += plines + 1; // +1 for blank line consumed by split
  }
  flush();

  // Don't run past parentEnd (the blank-line accounting is approximate).
  for (const piece of out) {
    if (piece.endLine > parentEnd + 1) piece.endLine = parentEnd + 1;
    if (piece.startLine > parentEnd + 1) piece.startLine = parentEnd + 1;
  }
  return out;
}

/**
 * Best-effort filename → display label, used for the preamble chunk
 * of an unheaded markdown file.
 *   "en-us/animation/using.md" → "animation/using"
 */
function pathToLabel(relPath: string): string {
  return relPath
    .replace(/^en-us\//, '')
    .replace(/\.(md|ya?ml)$/i, '')
    .replace(/\\/g, '/');
}

// ---------- YAML ----------

/**
 * Lightweight YAML splitter for the Roblox creator-docs API schema.
 *
 * The schema is regular enough that we don't need a full YAML parser
 * to chunk it sensibly. We look for top-level list keys
 * (`properties:`, `methods:`, `events:`, `callbacks:`, `items:`) and
 * split each list entry (a `- name: Foo` block) into its own chunk.
 *
 * Everything else at the top of the file (`name:`, `type:`, `summary:`,
 * `description:`, `code_samples:`) becomes a single preamble chunk.
 *
 * If the YAML doesn't match the expected shape (e.g. a non-reference
 * doc that happens to be yaml), we fall back to one giant
 * chunk-per-MAX-chars slice.
 */
function chunkYaml(relPath: string, raw: string): Chunk[] {
  const lines = raw.split(/\r?\n/);

  // Detect schema-like docs: must have at least one of the known
  // top-level list keys at column 0.
  const listKeyRe = /^(properties|methods|events|callbacks|items):\s*$/;
  const hasSchema = lines.some((l) => listKeyRe.test(l));
  if (!hasSchema) {
    return chunkYamlFallback(relPath, raw);
  }

  const chunks: Chunk[] = [];

  // Preamble: everything from line 0 up to the first known list key.
  let firstListLine = lines.length;
  for (let i = 0; i < lines.length; i++) {
    if (listKeyRe.test(lines[i])) {
      firstListLine = i;
      break;
    }
  }
  const preamble = lines.slice(0, firstListLine).join('\n').trim();
  if (preamble.length >= MIN_CHUNK_CHARS) {
    const label = extractYamlField(preamble, 'name') ?? pathToLabel(relPath);
    chunks.push({
      path: relPath,
      startLine: 1,
      endLine: firstListLine,
      text: trimTo(`${label}\n${preamble}`, MAX_CHUNK_CHARS),
      label,
      kind: 'yaml-preamble',
    });
  }

  // Walk list bodies. State: we're "inside" a list when the current
  // line is `properties:` etc. and continues until we hit another
  // top-level key (`^\S`) or EOF.
  let i = firstListLine;
  while (i < lines.length) {
    const listMatch = listKeyRe.exec(lines[i]);
    if (!listMatch) {
      i++;
      continue;
    }
    const listKey = listMatch[1];
    const listStart = i;
    i++;

    // Find end of this list section.
    let listEnd = lines.length;
    for (let j = i; j < lines.length; j++) {
      if (/^\S/.test(lines[j]) && !/^\s*-/.test(lines[j])) {
        listEnd = j;
        break;
      }
    }

    // Split into entries. Each entry starts with `  - name:` or
    // `  - ` at the indent established by the first entry. We just
    // detect `^\s*-\s` as the entry boundary.
    const entryStarts: number[] = [];
    for (let j = i; j < listEnd; j++) {
      if (/^\s*-\s/.test(lines[j])) entryStarts.push(j);
    }
    entryStarts.push(listEnd); // sentinel

    for (let e = 0; e < entryStarts.length - 1; e++) {
      const eStart = entryStarts[e];
      const eEnd = entryStarts[e + 1] - 1;
      const body = lines.slice(eStart, eEnd + 1).join('\n').trim();
      if (body.length < MIN_CHUNK_CHARS) continue;
      const memberName = extractYamlField(body, 'name') ?? `${listKey}[${e}]`;
      const preambleLabel =
        extractYamlField(preamble, 'name') ?? pathToLabel(relPath);
      // Give the embedder both the parent name and the member name —
      // "Motor6D · C0" rather than just "C0".
      const text = trimTo(
        `${preambleLabel} · ${memberName} (${listKey})\n${body}`,
        MAX_CHUNK_CHARS,
      );
      chunks.push({
        path: relPath,
        startLine: eStart + 1,
        endLine: eEnd + 1,
        text,
        label: `${preambleLabel}.${memberName}`,
        kind: 'yaml-member',
      });
    }

    i = listEnd;
  }

  return chunks;
}

/**
 * Non-schema YAML: just slice the file into MAX-chars chunks on
 * blank-line boundaries. Best-effort line accounting.
 */
function chunkYamlFallback(relPath: string, raw: string): Chunk[] {
  const lines = raw.split(/\r?\n/);
  const total = lines.length;
  const piece = splitOversize(raw, 0, total - 1);
  return piece
    .filter((p) => p.text.length >= MIN_CHUNK_CHARS)
    .map((p) => ({
      path: relPath,
      startLine: p.startLine,
      endLine: p.endLine,
      text: trimTo(`${pathToLabel(relPath)}\n${p.text}`, MAX_CHUNK_CHARS),
      label: pathToLabel(relPath),
      kind: 'yaml-misc' as const,
    }));
}

/**
 * Pull a top-level `key: value` out of a YAML block. Returns the bare
 * value (quotes stripped) or null if not found. Only looks for keys
 * at column 0 or one level of dash-indent — sufficient for our schema.
 */
function extractYamlField(block: string, key: string): string | null {
  // Top-level: `name: value`
  // Or first-line-of-entry: `- name: value`
  const re = new RegExp(`^\\s*-?\\s*${key}:\\s*(.+?)\\s*$`, 'm');
  const m = re.exec(block);
  if (!m) return null;
  let v = m[1].trim();
  // Strip surrounding quotes.
  if (
    (v.startsWith('"') && v.endsWith('"')) ||
    (v.startsWith("'") && v.endsWith("'"))
  ) {
    v = v.slice(1, -1);
  }
  return v.length > 0 ? v : null;
}

function trimTo(s: string, n: number): string {
  if (s.length <= n) return s;
  return s.slice(0, n - 1) + '…';
}

// ---------- Public API ----------

/**
 * Walk the docs content tree and yield chunks for every chunkable
 * file. Walks lazily so we can stream chunks into the embedder
 * without holding the full set in RAM (though at ~3k chunks × ~500
 * chars ≈ 1.5MB, RAM isn't actually a problem).
 */
export async function* walkChunks(cacheDir: string): AsyncGenerator<Chunk> {
  const root = contentRoot(cacheDir);
  const stack: string[] = [root];
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
        const ext = path.extname(e.name).toLowerCase();
        if (!CHUNKABLE_EXTENSIONS.has(ext)) continue;
        const rel = path.relative(root, p);
        let raw: string;
        try {
          raw = await fs.readFile(p, 'utf8');
        } catch {
          continue;
        }
        if (raw.indexOf('\0') !== -1) continue;
        const chunks = ext === '.md' ? chunkMarkdown(rel, raw) : chunkYaml(rel, raw);
        for (const c of chunks) yield c;
      }
    }
  }
}

/** Eager version of walkChunks — convenient for tests / index builds. */
export async function chunkAll(cacheDir: string): Promise<Chunk[]> {
  const out: Chunk[] = [];
  for await (const c of walkChunks(cacheDir)) out.push(c);
  return out;
}

// Export internals for tests.
export const __test__ = { chunkMarkdown, chunkYaml, splitOversize, extractYamlField };
