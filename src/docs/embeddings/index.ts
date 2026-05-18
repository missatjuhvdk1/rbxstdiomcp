import { promises as fs } from 'fs';
import * as path from 'path';
import { chunkAll, type Chunk } from './chunker.js';
import { dot, encode, encodeOne, EMBED_DIM } from './embedder.js';

/**
 * Vector index for the Roblox creator-docs mirror.
 *
 * On-disk layout (sits next to the cached docs tree):
 *
 *   <cacheDir>/
 *     content/                    ← (existing) extracted docs
 *     index/
 *       meta.json                 ← schema version, chunk count, sha
 *       chunks.json               ← Chunk[] metadata (path, lines, …)
 *       vectors.bin               ← Float32Array, N*EMBED_DIM packed
 *
 * Why a separate `index/` dir instead of jamming it into `meta.json`?
 *   1. We keep it adjacent to the data it indexes — the docs cache
 *      already knows how to wipe itself; we just nuke `index/` alongside.
 *   2. `vectors.bin` is a flat Float32 dump (~4.6MB at 3k chunks) —
 *      loading it with `fs.readFile` + `new Float32Array(buf.buffer)`
 *      is sub-10ms vs. parsing the same data out of JSON.
 *
 * Why flat cosine instead of HNSW / IVF?
 *   At ~19k chunks × 384 dims (measured on the real docs tree),
 *   brute-force takes ~5-15ms in JS — still well within "interactive"
 *   for a tool call. HNSW would add a dependency and complexity for
 *   savings that don't move the user-visible needle. If the index
 *   grows past ~100k chunks we should reconsider.
 */

const INDEX_SCHEMA_VERSION = 2;

export interface IndexMeta {
  schemaVersion: number;
  /** Docs SHA this index was built against. Used to detect staleness. */
  sha: string;
  /** Embedding model identifier; mismatched models are incompatible vectors. */
  model: string;
  /** Vector dimension (defensive — matches embedder.EMBED_DIM at build time). */
  dim: number;
  /** Number of chunks indexed. */
  chunkCount: number;
  /** ISO timestamp of the build. */
  builtAt: string;
  /** ms spent building (informational). */
  buildDurationMs: number;
}

export interface DocsIndex {
  meta: IndexMeta;
  chunks: Chunk[];
  /** Packed N*dim vectors. */
  vectors: Float32Array;
}

export interface QueryHit {
  chunk: Chunk;
  /** Raw cosine score in [-1, 1] (in practice [0, 1] for these vectors). */
  score: number;
}

export function indexDir(cacheDir: string): string {
  return path.join(cacheDir, 'index');
}

function indexMetaPath(cacheDir: string): string {
  return path.join(indexDir(cacheDir), 'meta.json');
}

function indexChunksPath(cacheDir: string): string {
  return path.join(indexDir(cacheDir), 'chunks.json');
}

function indexVectorsPath(cacheDir: string): string {
  return path.join(indexDir(cacheDir), 'vectors.bin');
}

// ---------- Build ----------

export interface BuildOptions {
  /** Override the embedding model identifier recorded in meta. */
  model?: string;
  /**
   * Chunks per embed call. Larger = fewer round-trips, but each call
   * holds the batch in memory. 64 is a comfortable middle.
   */
  batchSize?: number;
  /** Optional progress callback for long builds. */
  onProgress?: (done: number, total: number) => void;
}

/**
 * Build (or rebuild) the vector index for the docs tree in `cacheDir`.
 * Writes atomically: builds into a tmp dir then renames into place
 * so a partial/aborted build never leaves the index half-written.
 */
export async function buildIndex(
  cacheDir: string,
  docsSha: string,
  options: BuildOptions = {},
): Promise<IndexMeta> {
  const t0 = Date.now();
  const model = options.model ?? 'Xenova/all-MiniLM-L6-v2';
  const batchSize = Math.max(1, Math.min(options.batchSize ?? 64, 256));

  const chunks = await chunkAll(cacheDir);
  if (chunks.length === 0) {
    throw new Error(
      `No chunks produced from ${cacheDir}/content — is the docs cache empty?`,
    );
  }

  // Embed in batches. The packed Float32Array is allocated up-front
  // so each batch writes directly into its slice — no per-batch
  // concat / copy.
  const vectors = new Float32Array(chunks.length * EMBED_DIM);
  for (let i = 0; i < chunks.length; i += batchSize) {
    const batch = chunks.slice(i, i + batchSize);
    const vecs = await encode(batch.map((c) => c.text));
    for (let j = 0; j < vecs.length; j++) {
      vectors.set(vecs[j], (i + j) * EMBED_DIM);
    }
    options.onProgress?.(Math.min(i + batchSize, chunks.length), chunks.length);
  }

  // Write atomically via tmp dir → rename.
  const dir = indexDir(cacheDir);
  const tmp = `${dir}.tmp-${process.pid}-${Date.now()}`;
  await fs.mkdir(tmp, { recursive: true });

  const meta: IndexMeta = {
    schemaVersion: INDEX_SCHEMA_VERSION,
    sha: docsSha,
    model,
    dim: EMBED_DIM,
    chunkCount: chunks.length,
    builtAt: new Date().toISOString(),
    buildDurationMs: Date.now() - t0,
  };

  await fs.writeFile(path.join(tmp, 'meta.json'), JSON.stringify(meta, null, 2), 'utf8');
  await fs.writeFile(path.join(tmp, 'chunks.json'), JSON.stringify(chunks), 'utf8');
  await fs.writeFile(
    path.join(tmp, 'vectors.bin'),
    Buffer.from(vectors.buffer, vectors.byteOffset, vectors.byteLength),
  );

  // Wipe old, rename new. Two-step because some platforms (Windows)
  // don't allow renaming over an existing directory.
  await fs.rm(dir, { recursive: true, force: true });
  await fs.rename(tmp, dir);

  return meta;
}

// ---------- Load / check ----------

/**
 * Try to load the on-disk index. Returns null if absent, corrupt, or
 * mismatched against `expectedSha` / model / dim. Callers should treat
 * null as "needs rebuild".
 */
export async function loadIndex(
  cacheDir: string,
  expectedSha?: string,
  expectedModel?: string,
): Promise<DocsIndex | null> {
  let metaRaw: string;
  let chunksRaw: string;
  let vecBuf: Buffer;
  try {
    [metaRaw, chunksRaw, vecBuf] = await Promise.all([
      fs.readFile(indexMetaPath(cacheDir), 'utf8'),
      fs.readFile(indexChunksPath(cacheDir), 'utf8'),
      fs.readFile(indexVectorsPath(cacheDir)),
    ]);
  } catch {
    return null;
  }

  let meta: IndexMeta;
  try {
    meta = JSON.parse(metaRaw);
  } catch {
    return null;
  }
  if (meta.schemaVersion !== INDEX_SCHEMA_VERSION) return null;
  if (expectedSha && meta.sha && meta.sha !== expectedSha) return null;
  if (expectedModel && meta.model !== expectedModel) return null;
  if (meta.dim !== EMBED_DIM) return null;

  let chunks: Chunk[];
  try {
    chunks = JSON.parse(chunksRaw);
  } catch {
    return null;
  }
  if (!Array.isArray(chunks) || chunks.length !== meta.chunkCount) return null;

  // Wrap the underlying buffer as a Float32Array — zero-copy.
  // `vecBuf.buffer` may be larger than vecBuf if Node pooled it, so
  // honor byteOffset/byteLength.
  const expectedBytes = meta.chunkCount * meta.dim * 4;
  if (vecBuf.byteLength !== expectedBytes) return null;
  const vectors = new Float32Array(
    vecBuf.buffer,
    vecBuf.byteOffset,
    meta.chunkCount * meta.dim,
  );

  return { meta, chunks, vectors };
}

// ---------- Query ----------

export interface QueryOptions {
  /** Number of results to return. Default 10. */
  topK?: number;
  /**
   * MMR diversity weight in [0, 1]. 0 = pure relevance, 1 = pure
   * diversity. Default 0.3 — small bias toward diversity so we don't
   * return five near-identical chunks from the same page.
   */
  diversity?: number;
  /**
   * Restrict to chunks whose `path` starts with this prefix.
   * Mirrors `SearchOptions.scope` from the keyword search.
   */
  scope?: string;
  /**
   * Restrict to chunks of these kinds. Default: all kinds.
   * Useful for "search only API reference" (yaml-member / yaml-preamble).
   */
  kinds?: Chunk['kind'][];
  /**
   * Initial candidate pool size before MMR rerank. Should be >= topK.
   * Default 4× topK, capped at 200. Bigger = better diversity options
   * but more cosine math at query time.
   */
  poolSize?: number;
}

/**
 * Run a semantic query against the index. Returns top-K hits ranked
 * by cosine similarity and diversified with MMR.
 *
 * MMR (Maximal Marginal Relevance) algorithm:
 *   1. Pick the highest-cosine candidate as the first result.
 *   2. For each subsequent slot, score remaining candidates as
 *        λ * cosine_to_query - (1 - λ) * max_cosine_to_already_picked
 *      and pick the highest.
 *   3. Repeat until we have K results.
 *
 * This guarantees that a query like "Motor6D" doesn't return six
 * near-duplicate snippets from the same Motor6D.yaml file — we get
 * the top member, then the next-best chunk that's *also* different
 * from what we've already shown.
 */
export async function query(
  index: DocsIndex,
  queryText: string,
  options: QueryOptions = {},
): Promise<QueryHit[]> {
  if (!queryText || index.chunks.length === 0) return [];

  const topK = Math.max(1, Math.min(options.topK ?? 10, 100));
  const diversity = clamp(options.diversity ?? 0.3, 0, 1);
  const poolSize = Math.max(
    topK,
    Math.min(options.poolSize ?? topK * 4, Math.min(200, index.chunks.length)),
  );

  const qvec = await encodeOne(queryText);

  // Score every chunk that passes the scope / kind filter.
  // For 3k chunks this is ~1.1M float multiplies = sub-millisecond.
  const dim = index.meta.dim;
  const scope = options.scope;
  const kinds = options.kinds ? new Set(options.kinds) : null;

  const scored: { idx: number; score: number }[] = [];
  for (let i = 0; i < index.chunks.length; i++) {
    const c = index.chunks[i];
    if (scope && !c.path.startsWith(scope)) continue;
    if (kinds && !kinds.has(c.kind)) continue;
    const vec = index.vectors.subarray(i * dim, (i + 1) * dim);
    scored.push({ idx: i, score: dot(qvec, vec) });
  }
  if (scored.length === 0) return [];

  // Partial sort: take top poolSize candidates. For our sizes a full
  // sort is fast enough; if perf ever matters use a heap.
  scored.sort((a, b) => b.score - a.score);
  const pool = scored.slice(0, poolSize);

  // MMR. λ in textbook MMR == "relevance weight" — we use
  // λ = 1 - diversity so that diversity=0 → λ=1 → pure relevance,
  // diversity=1 → λ=0 → pure diversity.
  const lambda = 1 - diversity;
  const picked: number[] = []; // positions inside `pool`
  const used = new Uint8Array(pool.length);

  // Always pick the highest-score candidate first.
  picked.push(0);
  used[0] = 1;

  while (picked.length < topK && picked.length < pool.length) {
    let bestI = -1;
    let bestScore = -Infinity;
    for (let i = 0; i < pool.length; i++) {
      if (used[i]) continue;
      const cand = pool[i];
      const candVec = index.vectors.subarray(cand.idx * dim, (cand.idx + 1) * dim);
      // Max similarity to anything already picked.
      let maxSim = -Infinity;
      for (const pi of picked) {
        const pickedVec = index.vectors.subarray(pool[pi].idx * dim, (pool[pi].idx + 1) * dim);
        const sim = dot(candVec, pickedVec);
        if (sim > maxSim) maxSim = sim;
      }
      const mmrScore = lambda * cand.score - (1 - lambda) * maxSim;
      if (mmrScore > bestScore) {
        bestScore = mmrScore;
        bestI = i;
      }
    }
    if (bestI < 0) break;
    picked.push(bestI);
    used[bestI] = 1;
  }

  return picked.map((p) => ({
    chunk: index.chunks[pool[p].idx],
    score: pool[p].score,
  }));
}

function clamp(n: number, lo: number, hi: number): number {
  return Math.min(hi, Math.max(lo, n));
}

// ---------- Convenience ----------

/**
 * Has an index been built for this cache dir? Cheap stat — doesn't
 * touch the vector file.
 */
export async function indexExists(cacheDir: string): Promise<boolean> {
  try {
    const stat = await fs.stat(indexMetaPath(cacheDir));
    return stat.isFile();
  } catch {
    return false;
  }
}

/** Wipe the index directory. */
export async function clearIndex(cacheDir: string): Promise<void> {
  await fs.rm(indexDir(cacheDir), { recursive: true, force: true });
}
