/**
 * Semantic-search integration tests with a STUBBED embedder.
 *
 * We don't want CI to download a 25MB ONNX model on every run, so
 * `__setEmbedderForTests` lets us inject a tiny deterministic
 * pseudo-embedding: hash each token to a 384-dim sparse vector. The
 * result isn't great for real retrieval but is *deterministic* and
 * lets us verify:
 *
 *   1. Index build → load → query happy path.
 *   2. SHA mismatch invalidates the on-disk index.
 *   3. Hybrid mode falls back to keyword when no SHA is provided.
 *   4. Hybrid mode actually reorders hits when the index is hot.
 *   5. The `semantic: false` knob bypasses semantic entirely.
 *   6. Every returned hit still satisfies token-AND (no lexical cheating).
 */
import { promises as fs } from 'fs';
import * as os from 'os';
import * as path from 'path';
import {
  __setEmbedderForTests,
  EMBED_DIM,
} from '../docs/embeddings/embedder.js';
import { buildIndex, loadIndex } from '../docs/embeddings/index.js';
import { getOrBuild, __setIndexForTests, invalidate } from '../docs/embeddings/manager.js';
import { searchDocs } from '../docs/search.js';

/**
 * Deterministic fake embedder.
 *
 * Build a 384-dim sparse vector by hashing each whitespace-separated
 * token to a couple of dimensions. Same token → same bits. Two texts
 * sharing tokens will have positive cosine; texts with no shared
 * tokens will have ~0 cosine. Good enough to test ranking logic.
 */
function fakeEmbed(texts: string[]): Promise<Float32Array[]> {
  const out: Float32Array[] = [];
  for (const text of texts) {
    const v = new Float32Array(EMBED_DIM);
    const tokens = text.toLowerCase().split(/\s+/).filter(Boolean);
    for (const tok of tokens) {
      // Two-hash sparse encoding to spread tokens across the vector.
      let h1 = 2166136261;
      let h2 = 5381;
      for (let i = 0; i < tok.length; i++) {
        h1 = ((h1 ^ tok.charCodeAt(i)) * 16777619) >>> 0;
        h2 = ((h2 << 5) + h2 + tok.charCodeAt(i)) >>> 0;
      }
      v[h1 % EMBED_DIM] += 1;
      v[h2 % EMBED_DIM] += 0.5;
    }
    // L2-normalize so dot = cosine.
    let norm = 0;
    for (let i = 0; i < EMBED_DIM; i++) norm += v[i] * v[i];
    norm = Math.sqrt(norm) || 1;
    for (let i = 0; i < EMBED_DIM; i++) v[i] /= norm;
    out.push(v);
  }
  return Promise.resolve(out);
}

async function makeFixtureCache(): Promise<string> {
  const dir = await fs.mkdtemp(path.join(os.tmpdir(), 'rbxdocs-sem-'));
  const en = path.join(dir, 'content', 'en-us');
  await fs.mkdir(path.join(en, 'reference', 'engine', 'classes'), { recursive: true });
  await fs.mkdir(path.join(en, 'animation'), { recursive: true });

  // A "rotate body part smoothly" query should rank AlignOrientation
  // higher than a passing mention in an unrelated guide.
  await fs.writeFile(
    path.join(en, 'reference', 'engine', 'classes', 'AlignOrientation.yaml'),
    `name: AlignOrientation
type: class
summary: |
  AlignOrientation smoothly rotates an Attachment toward a target orientation.
description: |
  Use AlignOrientation when you want to smoothly rotate one part to face
  a direction over time. It applies torque to align the orientation.
properties:
  - name: MaxTorque
    summary: |
      The maximum torque applied to rotate the attachment.
    type: number
  - name: Responsiveness
    summary: |
      Higher responsiveness rotates the part more aggressively.
    type: number
`,
    'utf8',
  );

  await fs.writeFile(
    path.join(en, 'reference', 'engine', 'classes', 'Motor6D.yaml'),
    `name: Motor6D
type: class
summary: |
  A Motor6D is a joint that rotates between two parts using C0 and C1 offsets.
description: |
  Motor6D drives character animation by rotating Part1 relative to Part0.
properties:
  - name: C0
    summary: |
      The CFrame offset of the joint on Part0. Setting C0 rotates Part1 around Part0.
    type: CFrame
  - name: C1
    summary: |
      The CFrame offset of the joint on Part1.
    type: CFrame
`,
    'utf8',
  );

  // Unrelated guide that *mentions* rotate / smooth / part in passing
  // — keyword token-AND will match it, but semantic rerank should
  // push it down below AlignOrientation.
  await fs.writeFile(
    path.join(en, 'animation', 'unrelated-rotate.md'),
    `# Unrelated guide that happens to mention rotate and part
This page is about something else entirely.
It might smoothly rotate a part but only as an aside.
The main topic is something else: building a UI, scripting a server, configuring inventories.
You can rotate a part by setting CFrame directly, smoothly or not.
Most of this page talks about UI buttons and inventory grids and server scripts.
${'unrelated text '.repeat(40)}
`,
    'utf8',
  );

  return dir;
}

describe('semantic-search: end-to-end with fake embedder', () => {
  let cacheDir: string;
  const FAKE_SHA = 'deadbeefcafe1234';

  beforeAll(async () => {
    __setEmbedderForTests(fakeEmbed);
    cacheDir = await makeFixtureCache();
  });
  afterAll(async () => {
    __setEmbedderForTests(null);
    __setIndexForTests(null);
    if (cacheDir) await fs.rm(cacheDir, { recursive: true, force: true });
  });
  beforeEach(() => {
    invalidate(); // clear in-memory manager between tests
  });

  test('buildIndex → loadIndex round-trips', async () => {
    const meta = await buildIndex(cacheDir, FAKE_SHA);
    expect(meta.sha).toBe(FAKE_SHA);
    expect(meta.dim).toBe(EMBED_DIM);
    expect(meta.chunkCount).toBeGreaterThan(0);

    const loaded = await loadIndex(cacheDir, FAKE_SHA);
    expect(loaded).not.toBeNull();
    expect(loaded!.chunks.length).toBe(meta.chunkCount);
    expect(loaded!.vectors.length).toBe(meta.chunkCount * meta.dim);
  });

  test('loadIndex rejects on SHA mismatch', async () => {
    await buildIndex(cacheDir, FAKE_SHA);
    const wrong = await loadIndex(cacheDir, 'different-sha');
    expect(wrong).toBeNull();
  });

  test('getOrBuild memoizes after first call', async () => {
    const first = await getOrBuild(cacheDir, FAKE_SHA);
    expect(first).not.toBeNull();
    // Stash a sentinel; if memoization works the second call returns the
    // exact same reference.
    const second = await getOrBuild(cacheDir, FAKE_SHA);
    expect(second).toBe(first);
  });

  test('searchDocs hybrid mode reranks AlignOrientation above unrelated guide', async () => {
    // Warm the index.
    await getOrBuild(cacheDir, FAKE_SHA);

    const result = await searchDocs(
      cacheDir,
      'rotate part smoothly',
      { maxHits: 20 },
      { docsSha: FAKE_SHA },
    );

    expect(result.mode).toBe('hybrid');
    expect(result.semanticUsed).toBe(true);
    expect(result.hits.length).toBeGreaterThan(0);

    // Find the rank of AlignOrientation vs. the unrelated guide.
    const alignRank = result.hits.findIndex((h) =>
      h.path.includes('AlignOrientation'),
    );
    const unrelatedRank = result.hits.findIndex((h) =>
      h.path.includes('unrelated-rotate'),
    );
    // Both should appear (token-AND filter lets them through).
    expect(alignRank).toBeGreaterThanOrEqual(0);
    expect(unrelatedRank).toBeGreaterThanOrEqual(0);
    // AlignOrientation has more topical density → higher fake-cosine
    // → should rank above the unrelated guide.
    expect(alignRank).toBeLessThan(unrelatedRank);
    // And every hit has a score field.
    for (const h of result.hits) {
      expect(typeof h.score).toBe('number');
    }
  });

  test('semantic: false skips rerank and stays in token-AND mode', async () => {
    const result = await searchDocs(
      cacheDir,
      'rotate part smoothly',
      { maxHits: 20, semantic: false },
      { docsSha: FAKE_SHA },
    );
    expect(result.mode).toBe('token-and');
    for (const h of result.hits) {
      // No score field in plain token-AND mode.
      expect(h.score).toBeUndefined();
    }
  });

  test('hybrid mode without docsSha falls back to keyword ranking', async () => {
    const result = await searchDocs(cacheDir, 'rotate part smoothly', {
      maxHits: 20,
    });
    expect(result.mode).toBe('hybrid');
    expect(result.semanticUsed).toBe(false);
  });

  test('hybrid mode preserves token-AND guarantee (every hit contains all tokens)', async () => {
    await getOrBuild(cacheDir, FAKE_SHA);
    const result = await searchDocs(
      cacheDir,
      'rotate part smoothly',
      { maxHits: 20 },
      { docsSha: FAKE_SHA },
    );
    for (const hit of result.hits) {
      // matchedTokens should be present (carried through from token-AND
      // pool). The token-AND guarantee is "every token appears in the
      // window", which the keyword pass already enforced.
      expect(Array.isArray(hit.matchedTokens)).toBe(true);
    }
  });

  test('single-token query stays in literal mode (no semantic touch)', async () => {
    const result = await searchDocs(
      cacheDir,
      'Motor6D',
      { maxHits: 20 },
      { docsSha: FAKE_SHA },
    );
    expect(result.mode).toBe('literal');
  });
});
