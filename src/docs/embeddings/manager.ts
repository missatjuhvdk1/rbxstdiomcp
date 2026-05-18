import { buildIndex, loadIndex, type DocsIndex, type IndexMeta } from './index.js';
import { EMBED_MODEL } from './embedder.js';

/**
 * Process-wide manager for the semantic docs index.
 *
 * Responsibilities:
 *   1. Lazy-load the index on first semantic query so plain keyword
 *      searches don't pay the cost.
 *   2. Cache the loaded index in memory (vectors are mmap-able and
 *      small; ~4.6MB for ~3k chunks).
 *   3. Coalesce concurrent first-callers onto the same load/build
 *      promise so we don't run two builds in parallel.
 *   4. Rebuild on docs-SHA mismatch (the fetcher handed us a new
 *      docs cache → invalidate stale vectors).
 *
 * NOT this module's job:
 *   - Deciding *when* to rebuild based on TTL — that's the fetcher.
 *   - Knowing about the keyword search — `search.ts` calls this lazily
 *     and falls back to keyword-only if the load/build fails.
 */

interface CachedEntry {
  cacheDir: string;
  sha: string;
  index: DocsIndex;
}

let cached: CachedEntry | null = null;
/** In-flight load/build promise for de-duplication of concurrent calls. */
let inFlight: Promise<DocsIndex | null> | null = null;

/**
 * Test seam: lets unit tests inject a precanned index and skip the
 * load/build path entirely. The keyword + hybrid rerank machinery
 * uses `getOrBuild` directly, so injecting here is enough to
 * deterministically exercise reranking.
 */
export function __setIndexForTests(entry: CachedEntry | null): void {
  cached = entry;
  inFlight = null;
}

export interface GetOrBuildOptions {
  /** If true, suppress build-on-miss and only attempt a load. */
  loadOnly?: boolean;
  /** Build progress hook (passed through to buildIndex). */
  onProgress?: (done: number, total: number) => void;
}

/**
 * Return a usable in-memory index for `cacheDir`@`docsSha`, building
 * it if necessary. Returns null when the index can't be obtained — the
 * caller should fall back to keyword-only mode in that case.
 *
 * Decision tree:
 *   1. We already have a hot index for this (cacheDir, sha) → return it.
 *   2. Otherwise try to loadIndex() from disk — if it matches the sha,
 *      cache + return it.
 *   3. Otherwise, if loadOnly: return null.
 *   4. Otherwise build a fresh index (heavy: 30–90s + 25MB model
 *      download on first ever call) and cache it.
 *
 * Errors during build are swallowed (returned as null) because we
 * don't want a semantic-index failure to break the keyword search.
 */
export async function getOrBuild(
  cacheDir: string,
  docsSha: string,
  options: GetOrBuildOptions = {},
): Promise<DocsIndex | null> {
  if (cached && cached.cacheDir === cacheDir && cached.sha === docsSha) {
    return cached.index;
  }
  if (inFlight) return inFlight;

  inFlight = (async () => {
    try {
      // 1. Try disk first — if the on-disk index matches our expected
      //    sha+model, just memo it.
      const loaded = await loadIndex(cacheDir, docsSha, EMBED_MODEL);
      if (loaded) {
        cached = { cacheDir, sha: docsSha, index: loaded };
        return loaded;
      }

      if (options.loadOnly) return null;

      // 2. Build from scratch. Heavy: model download + embed every
      //    chunk. Subsequent process restarts hit the disk cache.
      const meta = await buildIndex(cacheDir, docsSha, {
        model: EMBED_MODEL,
        onProgress: options.onProgress,
      });
      // Reload from disk after building — keeps the load/build paths
      // exercising the same code (so a bug in load doesn't only
      // manifest after a process restart).
      const built = await loadIndex(cacheDir, docsSha, EMBED_MODEL);
      if (!built) {
        // Shouldn't happen — we just wrote it. Log via stderr so a
        // partial build is at least visible.
        // eslint-disable-next-line no-console
        console.error(
          `[rbxstudio-mcp] built docs index reported ${meta.chunkCount} chunks but reload failed`,
        );
        return null;
      }
      cached = { cacheDir, sha: docsSha, index: built };
      return built;
    } catch (err: any) {
      // eslint-disable-next-line no-console
      console.error(
        `[rbxstudio-mcp] semantic index unavailable (${err?.message ?? err}); ` +
          `falling back to keyword-only search`,
      );
      return null;
    } finally {
      inFlight = null;
    }
  })();

  return inFlight;
}

/**
 * Drop the in-memory cache. Used when the docs cache itself is
 * re-fetched and we know the on-disk vectors are now stale. The
 * fetcher (or its caller) is expected to nuke the index directory
 * separately if it wants the on-disk vectors gone too — typically
 * `buildIndex` will overwrite atomically on the next call anyway.
 */
export function invalidate(): void {
  cached = null;
}

/** Diagnostic: is anything cached right now? */
export function currentMeta(): IndexMeta | null {
  return cached?.index.meta ?? null;
}
