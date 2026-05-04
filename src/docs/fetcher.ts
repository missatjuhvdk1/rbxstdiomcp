import { promises as fs } from 'fs';
import * as path from 'path';
import { Readable } from 'stream';
import { pipeline } from 'stream/promises';
import * as tar from 'tar';
import {
  approxSizeOnDisk,
  clearContent,
  contentRoot,
  ensureCacheDir,
  readMeta,
  resolveCacheDir,
  writeMeta,
  type DocsMeta,
} from './cache.js';

/**
 * Mirror Roblox/creator-docs locally as a flat file tree, refreshed on
 * demand.
 *
 * Why tarball instead of `git clone`?
 *   1. No git binary requirement — works on any Node install.
 *   2. ~30MB filtered tarball downloads in ~3s on a normal connection.
 *   3. We don't need history, only the current tree.
 *
 * Why scope-filter to a subset of `content/en-us/`?
 *   The full creator-docs repo is ~200MB. The AI overwhelmingly needs
 *   the API reference (`reference/engine`) plus the long-form guides
 *   for things it tends to struggle with (animation, characters, ui,
 *   workspace). Filtering during extract keeps the on-disk footprint
 *   to ~30MB.
 */

const REPO_OWNER = 'Roblox';
const REPO_NAME = 'creator-docs';
const REPO_BRANCH = 'main';

/**
 * Path prefixes (relative to repo root) we keep on disk.
 *
 * After the tarball is extracted with `strip: 2`, the leading
 * `<repo>-<branch>/content/` is removed, so on-disk these become
 * `<cacheDir>/content/en-us/...`. The filter however receives the
 * pre-strip path, so we match the `content/en-us/...` form here.
 */
const KEEP_PREFIXES = [
  'content/en-us/reference/',
  'content/en-us/animation/',
  'content/en-us/characters/',
  'content/en-us/ui/',
  'content/en-us/scripting/',
  'content/en-us/physics/',
  'content/en-us/workspace/',
  'content/en-us/players/',
  'content/en-us/input/',
  'content/en-us/cloud-services/',
  'content/en-us/sound/',
];

/** File extensions we keep within the prefixes above. */
const KEEP_EXTENSIONS = new Set(['.md', '.yaml', '.yml']);

/** GitHub API: latest commit SHA on a branch. */
const REFS_URL = `https://api.github.com/repos/${REPO_OWNER}/${REPO_NAME}/commits/${REPO_BRANCH}`;
/** codeload.github.com tarball — much faster + no auth required. */
const TARBALL_URL = `https://codeload.github.com/${REPO_OWNER}/${REPO_NAME}/tar.gz/refs/heads/${REPO_BRANCH}`;

/** How long a cache entry is "fresh enough" before we re-check upstream. */
const TTL_MS = 24 * 60 * 60 * 1000; // 24h

export interface EnsureDocsResult {
  cacheDir: string;
  meta: DocsMeta;
  /** What did this call actually do? */
  action: 'fresh' | 'sha-short-circuit' | 'redownloaded' | 'first-download';
  /** Wall-clock duration of the operation in ms. */
  durationMs: number;
}

export interface EnsureDocsOptions {
  /** Force a redownload regardless of TTL/SHA. */
  force?: boolean;
  /** Override the TTL window (ms). Default 24h. */
  ttlMs?: number;
}

function commonHeaders(): Record<string, string> {
  // Identify ourselves to GitHub. They rate-limit unauthenticated
  // requests but the daily SHA check is well under the limit.
  return {
    'User-Agent': 'rbxstudio-mcp (Roblox docs cache, https://github.com/boshyxd/robloxstudio-mcp)',
    Accept: 'application/vnd.github+json',
  };
}

/** Hit GitHub's commits API to get the current head SHA on `main`. */
async function fetchHeadSha(): Promise<string> {
  const res = await fetch(REFS_URL, { headers: commonHeaders() });
  if (!res.ok) {
    throw new Error(`GitHub API ${res.status} ${res.statusText} when fetching ${REFS_URL}`);
  }
  const body: any = await res.json();
  if (typeof body?.sha !== 'string') {
    throw new Error('GitHub API returned no sha for HEAD commit');
  }
  return body.sha as string;
}

/**
 * Strip the leading `<repo>-<branch>/` directory that codeload tarballs
 * wrap everything in, returning the path relative to the repo root.
 * Returns null for the wrapper directory entry itself.
 */
function relativizeTarPath(tarPath: string): string | null {
  const slash = tarPath.indexOf('/');
  if (slash < 0) return null;
  const rel = tarPath.slice(slash + 1);
  if (!rel || rel === '/') return null;
  return rel;
}

/**
 * Download the tarball and stream it through tar's extractor with a
 * filter so only matching paths are written to disk.
 *
 * Note on tar v7 behavior: the `filter` callback receives the ORIGINAL
 * (pre-strip) path, not the post-strip path. `strip:1` only affects the
 * on-disk output path. So we relativize here just to make the filter
 * comparison readable.
 */
async function downloadAndExtract(cacheDir: string): Promise<{ fileCount: number }> {
  const dest = contentRoot(cacheDir);
  // Wipe before extract so deleted upstream files don't linger.
  await clearContent(cacheDir);
  await fs.mkdir(dest, { recursive: true });

  const res = await fetch(TARBALL_URL, { headers: commonHeaders() });
  if (!res.ok || !res.body) {
    throw new Error(`Tarball download failed: ${res.status} ${res.statusText} from ${TARBALL_URL}`);
  }

  let fileCount = 0;

  const extractor = tar.x({
    cwd: dest,
    // `strip: 2` drops both the "<repo>-<branch>/" wrapper directory AND
    // the upstream "content/" directory, so on-disk we end up with
    //   <cacheDir>/content/en-us/reference/engine/classes/Motor6D.yaml
    // matching what `contentRoot()` expects.
    //
    // Filter still sees the ORIGINAL pre-strip path
    // (`creator-docs-main/content/en-us/…`), which is why we relativize
    // it manually before checking against KEEP_PREFIXES.
    strip: 2,
    filter: (tarPath) => {
      const rel = relativizeTarPath(tarPath);
      if (!rel) return false;
      // Directory entries end in `/` — let tar create them if needed.
      // We only care about counting / filtering files.
      if (rel.endsWith('/')) {
        return KEEP_PREFIXES.some((p) => p.startsWith(rel) || rel.startsWith(p));
      }
      if (!KEEP_PREFIXES.some((p) => rel.startsWith(p))) return false;
      const ext = path.extname(rel).toLowerCase();
      if (!KEEP_EXTENSIONS.has(ext)) return false;
      fileCount++;
      return true;
    },
  });

  // node-fetch / undici body is a Web ReadableStream. Convert to a
  // Node Readable and pipe into tar.
  const nodeStream = Readable.fromWeb(res.body as any);
  await pipeline(nodeStream, extractor);

  return { fileCount };
}

/**
 * Public entry point used by all docs tools. Guarantees that, by the
 * time it returns, `cacheDir/content/...` contains a usable mirror of
 * the docs (or throws).
 *
 * Decision tree:
 *   1. No cache on disk          → first-download
 *   2. force=true                → redownloaded
 *   3. cache age <= TTL          → fresh (no network call)
 *   4. cache age >  TTL && SHA same → sha-short-circuit (network: SHA only)
 *   5. cache age >  TTL && SHA different → redownloaded
 */
export async function ensureDocsCache(options: EnsureDocsOptions = {}): Promise<EnsureDocsResult> {
  const cacheDir = resolveCacheDir();
  const ttlMs = options.ttlMs ?? TTL_MS;
  const t0 = Date.now();

  await ensureCacheDir(cacheDir);
  const existing = await readMeta(cacheDir);

  // 1. No cache yet.
  if (!existing || !existing.sha) {
    return await doDownload(cacheDir, t0, 'first-download');
  }

  // 2. Forced.
  if (options.force) {
    return await doDownload(cacheDir, t0, 'redownloaded');
  }

  // 3. Within TTL window — trust the cache.
  const downloadedAt = Date.parse(existing.downloadedAt);
  const fresh = Number.isFinite(downloadedAt) && Date.now() - downloadedAt <= ttlMs;
  if (fresh) {
    return {
      cacheDir,
      meta: existing,
      action: 'fresh',
      durationMs: Date.now() - t0,
    };
  }

  // 4 / 5. TTL expired — ask GitHub if anything changed.
  const upstreamSha = await fetchHeadSha();
  if (upstreamSha === existing.sha) {
    // Just bump lastCheckedAt so the next call hits TTL again.
    const updated: Omit<DocsMeta, 'schemaVersion'> = {
      ...existing,
      lastCheckedAt: new Date().toISOString(),
    };
    await writeMeta(cacheDir, updated);
    return {
      cacheDir,
      meta: { ...updated, schemaVersion: 1 },
      action: 'sha-short-circuit',
      durationMs: Date.now() - t0,
    };
  }

  return await doDownload(cacheDir, t0, 'redownloaded');
}

async function doDownload(
  cacheDir: string,
  t0: number,
  action: EnsureDocsResult['action'],
): Promise<EnsureDocsResult> {
  // Get the SHA we're locking to. If this fails, we can't sensibly
  // record provenance, but the tarball itself is the source of truth.
  let sha = '';
  try {
    sha = await fetchHeadSha();
  } catch {
    // Network blip on the SHA endpoint shouldn't block the download.
    sha = '';
  }

  const { fileCount } = await downloadAndExtract(cacheDir);
  const bytesOnDisk = await approxSizeOnDisk(contentRoot(cacheDir));
  const now = new Date().toISOString();

  const meta: Omit<DocsMeta, 'schemaVersion'> = {
    repo: `${REPO_OWNER}/${REPO_NAME}`,
    branch: REPO_BRANCH,
    sha,
    downloadedAt: now,
    lastCheckedAt: now,
    fileCount,
    bytesOnDisk,
  };
  await writeMeta(cacheDir, meta);

  return {
    cacheDir,
    meta: { ...meta, schemaVersion: 1 },
    action,
    durationMs: Date.now() - t0,
  };
}
