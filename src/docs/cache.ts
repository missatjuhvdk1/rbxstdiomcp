import { promises as fs } from 'fs';
import * as path from 'path';

/**
 * Cache layout for the Roblox creator-docs mirror.
 *
 *   <cacheDir>/
 *     meta.json                 ← bookkeeping (sha, downloadedAt, …)
 *     content/                  ← extracted, scope-filtered docs tree
 *       en-us/
 *         reference/engine/classes/Part.yaml
 *         reference/engine/datatypes/CFrame.yaml
 *         …
 *
 * Cache directory is resolved by `env-paths` (cross-platform) but can be
 * overridden via `RBXSTUDIO_DOCS_DIR` for tests, sandboxes, or users with
 * non-standard layouts.
 */

export interface DocsMeta {
  /** Repo we cloned from, e.g. "Roblox/creator-docs". */
  repo: string;
  /** Branch/ref we tracked, e.g. "main". */
  branch: string;
  /** Commit SHA of the snapshot on disk. Empty if cache is empty. */
  sha: string;
  /** ISO timestamp of when the tarball was last extracted. */
  downloadedAt: string;
  /** ISO timestamp of when we last hit the GitHub API to check freshness. */
  lastCheckedAt: string;
  /** How many files survived scope-filtering and are sitting in `content/`. */
  fileCount: number;
  /** Approximate bytes-on-disk for the extracted tree. */
  bytesOnDisk: number;
  /** Schema version — bump if we change the layout incompatibly. */
  schemaVersion: number;
}

const SCHEMA_VERSION = 1;

/**
 * Resolve the docs cache directory. Honors `RBXSTUDIO_DOCS_DIR` first,
 * otherwise falls back to OS-conventional cache paths via `env-paths`.
 *
 *   Linux   → ~/.cache/rbxstudio-mcp-nodejs/docs
 *   macOS   → ~/Library/Caches/rbxstudio-mcp-nodejs/docs
 *   Windows → %LOCALAPPDATA%\rbxstudio-mcp-nodejs\Cache\docs
 *
 * Note: `env-paths` is pure ESM and Jest's CJS sandbox can't load it at
 * the top level of a TS module that may be imported by tests. Loading
 * it on first call sidesteps that without affecting production
 * behavior — runs at most once per process thanks to the cache below.
 */
let cachedDir: string | null = null;
export function resolveCacheDir(): string {
  if (cachedDir) return cachedDir;
  const override = process.env.RBXSTUDIO_DOCS_DIR;
  if (override && override.trim().length > 0) {
    cachedDir = path.resolve(override);
    return cachedDir;
  }
  // Inline the env-paths logic so we don't need a runtime ESM import
  // (which would force the surrounding module into top-level await).
  // env-paths v3 returns OS-conventional cache paths; we replicate them.
  cachedDir = defaultCacheDir();
  return cachedDir;
}

function defaultCacheDir(): string {
  const home = process.env.HOME ?? process.env.USERPROFILE ?? process.cwd();
  const appName = 'rbxstudio-mcp-nodejs';
  switch (process.platform) {
    case 'darwin':
      return path.join(home, 'Library', 'Caches', appName, 'docs');
    case 'win32': {
      const localAppData = process.env.LOCALAPPDATA ?? path.join(home, 'AppData', 'Local');
      return path.join(localAppData, appName, 'Cache', 'docs');
    }
    default: {
      // Linux / *nix: respect XDG_CACHE_HOME if set.
      const xdg = process.env.XDG_CACHE_HOME;
      const base = xdg && xdg.trim().length > 0 ? xdg : path.join(home, '.cache');
      return path.join(base, appName, 'docs');
    }
  }
}

export function metaPath(cacheDir: string): string {
  return path.join(cacheDir, 'meta.json');
}

export function contentRoot(cacheDir: string): string {
  return path.join(cacheDir, 'content');
}

export async function readMeta(cacheDir: string): Promise<DocsMeta | null> {
  try {
    const raw = await fs.readFile(metaPath(cacheDir), 'utf8');
    const parsed = JSON.parse(raw) as DocsMeta;
    if (parsed.schemaVersion !== SCHEMA_VERSION) {
      // Old/incompatible cache — treat as empty so we re-download.
      return null;
    }
    return parsed;
  } catch (err: any) {
    if (err?.code === 'ENOENT') return null;
    // Any other error (corrupt JSON, EACCES, …) → behave like no cache,
    // upstream code will re-fetch.
    return null;
  }
}

export async function writeMeta(cacheDir: string, meta: Omit<DocsMeta, 'schemaVersion'>): Promise<void> {
  await fs.mkdir(cacheDir, { recursive: true });
  const full: DocsMeta = { ...meta, schemaVersion: SCHEMA_VERSION };
  await fs.writeFile(metaPath(cacheDir), JSON.stringify(full, null, 2), 'utf8');
}

export async function ensureCacheDir(cacheDir: string): Promise<void> {
  await fs.mkdir(cacheDir, { recursive: true });
}

/**
 * Wipe the extracted content tree (but keep the cacheDir itself, so users
 * can `tail -F` it if they want to).
 */
export async function clearContent(cacheDir: string): Promise<void> {
  const dir = contentRoot(cacheDir);
  await fs.rm(dir, { recursive: true, force: true });
}

/**
 * Best-effort byte-count of the content tree. Used for status reporting
 * only; not safety-critical, so errors are swallowed.
 */
export async function approxSizeOnDisk(dir: string): Promise<number> {
  let total = 0;
  async function walk(d: string): Promise<void> {
    let entries;
    try {
      entries = await fs.readdir(d, { withFileTypes: true });
    } catch {
      return;
    }
    for (const e of entries) {
      const p = path.join(d, e.name);
      if (e.isDirectory()) {
        await walk(p);
      } else if (e.isFile()) {
        try {
          const stat = await fs.stat(p);
          total += stat.size;
        } catch {
          // ignore
        }
      }
    }
  }
  await walk(dir);
  return total;
}
