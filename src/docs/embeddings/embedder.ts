/**
 * Thin wrapper around @huggingface/transformers' feature-extraction
 * pipeline.
 *
 * Why a wrapper instead of using `pipeline()` directly at call sites?
 *   1. The pipeline is HEAVY to load (~25MB model download + ~200ms
 *      ORT init). We want exactly one instance per process, created
 *      lazily on first use.
 *   2. The library is pure ESM and import-heavy; isolating it here
 *      means the rest of the codebase doesn't pay the cost on startup
 *      and tests that don't need embeddings don't load it.
 *   3. We want a stable surface (encode(string[]) → Float32Array[])
 *      regardless of which Transformers.js version we're on.
 *
 * Model: sentence-transformers/all-MiniLM-L6-v2 (via the Xenova ONNX
 * port). 384-dim normalized sentence embeddings, ~25MB on disk,
 * ~5–10ms per encode on a modern CPU. Trained on 1B+ sentence pairs
 * with contrastive loss → great general-purpose retrieval quality at
 * tiny model size.
 */

export const EMBED_DIM = 384;
export const EMBED_MODEL = 'Xenova/all-MiniLM-L6-v2';

/**
 * Cached pipeline promise. We store the promise (not the resolved
 * value) so concurrent first-callers all wait on the same
 * initialization instead of each kicking off their own.
 */
let pipelinePromise: Promise<any> | null = null;

/**
 * For the test/dev path where we want to inject a stub instead of
 * downloading 25MB of weights into a temp dir.
 */
let overrideEmbed: ((texts: string[]) => Promise<Float32Array[]>) | null = null;

export function __setEmbedderForTests(
  fn: ((texts: string[]) => Promise<Float32Array[]>) | null,
): void {
  overrideEmbed = fn;
  // Also clear any lazily-loaded real pipeline so a test that runs
  // after a real load doesn't accidentally use the stub afterward.
  pipelinePromise = null;
}

async function loadPipeline(): Promise<any> {
  if (pipelinePromise) return pipelinePromise;
  pipelinePromise = (async () => {
    // Dynamic import keeps the heavy ESM out of the module-load graph
    // until someone actually needs an embedding. The whole transformers
    // package weighs ~30MB of JS — not something we want loaded just
    // because a user called `search_roblox_docs` with one keyword.
    const t = await import('@huggingface/transformers');
    // `pipeline('feature-extraction', ...)` returns a callable that
    // takes a string or string[] and returns a Tensor.
    return await t.pipeline('feature-extraction', EMBED_MODEL, {
      // fp32 is the safest dtype on Node — q4f16 hit ORT graph-fusion
      // bugs (see HF issue #1567). Size on disk is ~90MB for fp32 vs
      // ~25MB for q8; for a one-time download we accept that cost in
      // exchange for not having to debug runtime errors later.
      dtype: 'fp32',
    });
  })();
  return pipelinePromise;
}

/**
 * Encode an array of strings into normalized 384-dim Float32 vectors.
 *
 * Normalization is done by the model (pooling: 'mean', normalize: true)
 * so cosine similarity == plain dot product, which is hot-path-cheap.
 *
 * Batched internally — pass big arrays (50–200 items per call is fine)
 * to amortize tensor allocation overhead.
 */
export async function encode(texts: string[]): Promise<Float32Array[]> {
  if (texts.length === 0) return [];
  if (overrideEmbed) return await overrideEmbed(texts);

  const pipe = await loadPipeline();
  const output: any = await pipe(texts, { pooling: 'mean', normalize: true });

  // Transformers.js returns a single Tensor of shape [N, EMBED_DIM]
  // even for single-input calls. `.tolist()` would give a nested
  // array; for perf we slice the flat backing buffer ourselves.
  const data: Float32Array =
    output.data instanceof Float32Array
      ? output.data
      : Float32Array.from(output.data);
  const dim = output.dims?.[1] ?? EMBED_DIM;
  if (dim !== EMBED_DIM) {
    // Defensive: if HF ever updates the model and dim changes, we'd
    // index incompatible vectors and silently return garbage. Loud
    // failure is better.
    throw new Error(
      `Embedding dim mismatch: model returned ${dim}, expected ${EMBED_DIM}. ` +
        `Bump EMBED_DIM and rebuild the docs index.`,
    );
  }
  const out: Float32Array[] = new Array(texts.length);
  for (let i = 0; i < texts.length; i++) {
    out[i] = data.subarray(i * dim, (i + 1) * dim).slice(); // copy
  }
  return out;
}

/** Convenience: encode a single string. */
export async function encodeOne(text: string): Promise<Float32Array> {
  const [vec] = await encode([text]);
  return vec;
}

/**
 * Dot product of two normalized vectors == cosine similarity. Tight
 * loop, no allocations, called millions of times during query.
 */
export function dot(a: Float32Array, b: Float32Array): number {
  const n = a.length;
  let s = 0;
  for (let i = 0; i < n; i++) s += a[i] * b[i];
  return s;
}
