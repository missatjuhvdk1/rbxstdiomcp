/**
 * End-to-end smoke test for the hybrid semantic upgrade.
 *
 * This script:
 *   1. Downloads the real Roblox docs (via the existing fetcher).
 *   2. Builds the real Xenova/all-MiniLM-L6-v2 vector index.
 *   3. Runs a battery of natural-language queries through the actual
 *      searchDocs() flow (hybrid mode) and prints the top-5 hits.
 *   4. Runs the SAME queries with `semantic: false` (pure keyword)
 *      so we can eyeball whether the rerank actually helps.
 *
 * Run with:  npx tsx scripts/eval-semantic.mts
 */

import { ensureDocsCache } from '../src/docs/fetcher.js';
import { searchDocs } from '../src/docs/search.js';
import { getOrBuild, currentMeta } from '../src/docs/embeddings/manager.js';
import { chunkAll } from '../src/docs/embeddings/chunker.js';

const QUERIES = [
  // Natural-language phrasing the model would actually type.
  'how do I rotate a body part smoothly',
  'how do I make a character flip mid-air',
  'how do I get a player to walk faster',
  'how do I detect when a part is touched',
  'play a sound when a player joins',
  'create a billboard that follows the camera',
  'restrict editing of a part to one player',
  'make a UI element draggable on mobile',
  'spawn an NPC and make it chase the player',
  // Mixed / API-ish to verify keyword guarantees still hold.
  'Motor6D C0 offset',
  'AlignOrientation servo',
  'HumanoidRootPart anchor',
];

function fmt(s: string, n: number): string {
  if (s.length <= n) return s.padEnd(n);
  return s.slice(0, n - 1) + '…';
}

async function main() {
  const t0 = Date.now();
  console.log('[1/4] ensuring docs cache…');
  const ensured = await ensureDocsCache();
  console.log(
    `      ${ensured.action} sha=${ensured.meta.sha?.slice(0, 7) || '?'} files=${ensured.meta.fileCount} ${ensured.durationMs}ms`,
  );

  console.log('[2/4] chunking docs (preview)…');
  const tc = Date.now();
  const chunks = await chunkAll(ensured.cacheDir);
  console.log(
    `      ${chunks.length} chunks in ${Date.now() - tc}ms (kinds: ${[...new Set(chunks.map((c) => c.kind))].join(', ')})`,
  );

  console.log('[3/4] building / loading semantic index (first time: ~30-90s + model download)…');
  const tb = Date.now();
  let lastPct = -1;
  const idx = await getOrBuild(ensured.cacheDir, ensured.meta.sha || '', {
    onProgress: (done, total) => {
      const pct = Math.floor((done / total) * 20) * 5;
      if (pct !== lastPct) {
        lastPct = pct;
        process.stdout.write(`\r      embedding: ${done}/${total} (${pct}%)`);
      }
    },
  });
  process.stdout.write('\n');
  if (!idx) {
    console.error('!! semantic index unavailable — see logs above');
    process.exitCode = 1;
    return;
  }
  console.log(
    `      built/loaded in ${Date.now() - tb}ms: ${idx.meta.chunkCount} chunks, model=${idx.meta.model}, dim=${idx.meta.dim}`,
  );

  console.log('[4/4] running queries…\n');
  for (const q of QUERIES) {
    console.log('━'.repeat(80));
    console.log(`QUERY: ${q}`);

    // Hybrid (default, semantic on)
    const tH = Date.now();
    const hybrid = await searchDocs(
      ensured.cacheDir,
      q,
      { maxHits: 5, contextLines: 1 },
      { docsSha: ensured.meta.sha },
    );
    const dH = Date.now() - tH;
    console.log(
      `\n  HYBRID  (mode=${hybrid.mode}, semanticUsed=${hybrid.semanticUsed}, ${dH}ms, totalHits=${hybrid.totalHits})`,
    );
    if (hybrid.hits.length === 0) {
      console.log('    (no hits)');
    }
    hybrid.hits.forEach((h, i) => {
      const sc = h.score !== undefined ? h.score.toFixed(3) : '----';
      const ss = h.semanticScore !== undefined ? h.semanticScore.toFixed(3) : '----';
      console.log(`    ${i + 1}. score=${sc} sem=${ss}  ${fmt(h.path, 55)}  L${h.line}`);
      console.log(`       ${fmt(h.text.trim(), 76)}`);
    });

    // Pure keyword
    const tK = Date.now();
    const keyword = await searchDocs(
      ensured.cacheDir,
      q,
      { maxHits: 5, contextLines: 1, semantic: false },
      { docsSha: ensured.meta.sha },
    );
    const dK = Date.now() - tK;
    console.log(
      `\n  KEYWORD (mode=${keyword.mode}, ${dK}ms, totalHits=${keyword.totalHits})`,
    );
    if (keyword.hits.length === 0) {
      console.log('    (no hits)');
    }
    keyword.hits.forEach((h, i) => {
      console.log(`    ${i + 1}. ${fmt(h.path, 55)}  L${h.line}`);
      console.log(`       ${fmt(h.text.trim(), 76)}`);
    });
    console.log();
  }

  console.log('━'.repeat(80));
  console.log(`done in ${Date.now() - t0}ms`);
  console.log(`final meta: ${JSON.stringify(currentMeta(), null, 2)}`);
}

main().catch((err) => {
  console.error('FATAL:', err);
  process.exitCode = 1;
});
