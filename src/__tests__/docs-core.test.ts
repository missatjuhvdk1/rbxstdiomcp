import { promises as fs } from 'fs';
import * as os from 'os';
import * as path from 'path';
import {
  approxSizeOnDisk,
  clearContent,
  contentRoot,
  ensureCacheDir,
  readMeta,
  writeMeta,
} from '../docs/cache';
import { resolveReference } from '../docs/reference';
import { listDocs, readDocFile, searchDocs } from '../docs/search';

describe('docs cache helpers', () => {
  let dir: string;

  beforeEach(async () => {
    dir = await fs.mkdtemp(path.join(os.tmpdir(), 'rbxdocs-cache-'));
  });

  afterEach(async () => {
    await fs.rm(dir, { recursive: true, force: true });
  });

  test('writeMeta/readMeta round-trips current-schema metadata', async () => {
    await writeMeta(dir, {
      repo: 'Roblox/creator-docs',
      branch: 'main',
      sha: 'abc',
      downloadedAt: '2026-01-01T00:00:00.000Z',
      lastCheckedAt: '2026-01-01T00:00:00.000Z',
      fileCount: 2,
      bytesOnDisk: 10,
    });

    await expect(readMeta(dir)).resolves.toMatchObject({
      repo: 'Roblox/creator-docs',
      sha: 'abc',
      schemaVersion: 1,
    });
  });

  test('readMeta treats missing, corrupt, and stale-schema metadata as empty', async () => {
    await expect(readMeta(dir)).resolves.toBeNull();

    await ensureCacheDir(dir);
    await fs.writeFile(path.join(dir, 'meta.json'), 'not-json', 'utf8');
    await expect(readMeta(dir)).resolves.toBeNull();

    await fs.writeFile(path.join(dir, 'meta.json'), JSON.stringify({ schemaVersion: 0 }), 'utf8');
    await expect(readMeta(dir)).resolves.toBeNull();
  });

  test('clearContent removes docs content and approxSizeOnDisk ignores missing paths', async () => {
    const root = contentRoot(dir);
    await fs.mkdir(path.join(root, 'nested'), { recursive: true });
    await fs.writeFile(path.join(root, 'nested', 'file.md'), '12345', 'utf8');

    await expect(approxSizeOnDisk(root)).resolves.toBe(5);
    await clearContent(dir);
    await expect(approxSizeOnDisk(root)).resolves.toBe(0);
  });
});

describe('docs search, listing, and reference resolution', () => {
  let dir: string;

  beforeEach(async () => {
    dir = await fs.mkdtemp(path.join(os.tmpdir(), 'rbxdocs-core-'));
    const root = contentRoot(dir);
    await fs.mkdir(path.join(root, 'en-us', 'reference', 'engine', 'classes'), { recursive: true });
    await fs.mkdir(path.join(root, 'en-us', 'reference', 'engine', 'datatypes'), { recursive: true });
    await fs.mkdir(path.join(root, 'en-us', 'guide'), { recursive: true });
    await fs.writeFile(
      path.join(root, 'en-us', 'reference', 'engine', 'classes', 'Part.yaml'),
      `name: Part
type: class
summary: A part is a 3D object.
properties:
  - name: Anchored
    summary: Anchored prevents physics from moving the part.
`,
      'utf8',
    );
    await fs.writeFile(
      path.join(root, 'en-us', 'reference', 'engine', 'datatypes', 'Vector3.yaml'),
      `name: Vector3
type: datatype
summary: Three dimensional vector.
`,
      'utf8',
    );
    await fs.writeFile(
      path.join(root, 'en-us', 'guide', 'physics.md'),
      `# Physics
Set Anchored when a part should not move.
Use constraints when a body must rotate smoothly.
`,
      'utf8',
    );
  });

  afterEach(async () => {
    await fs.rm(dir, { recursive: true, force: true });
  });

  test('readDocFile blocks traversal and reads safe files', async () => {
    await expect(readDocFile(dir, '../meta.json')).resolves.toBeNull();

    const doc = await readDocFile(dir, 'en-us/guide/physics.md');
    expect(doc).toMatchObject({
      path: 'en-us/guide/physics.md',
    });
    expect(doc?.content).toContain('Set Anchored');
  });

  test('listDocs sorts directories before files and paginates', async () => {
    const listing = await listDocs(dir, 'en-us/reference/engine', { limit: 1 });

    expect(listing).toMatchObject({
      path: 'en-us/reference/engine',
      totalEntries: 2,
      offset: 0,
      limit: 1,
      truncated: true,
      entries: [{ name: 'classes', type: 'dir' }],
    });
    await expect(listDocs(dir, '../outside')).resolves.toBeNull();
  });

  test('searchDocs supports literal, regex, scoped, and token-AND searches', async () => {
    const literal = await searchDocs(dir, 'Anchored', {
      scope: 'en-us/reference',
      contextLines: 1,
      semantic: false,
    });
    expect(literal).toMatchObject({
      mode: 'literal',
      totalHits: 2,
      filesScanned: 2,
    });
    expect(literal.hits[0].context).toEqual(
      expect.arrayContaining([{ line: 4, text: 'properties:' }]),
    );

    const regex = await searchDocs(dir, 'Vector\\d', { useRegex: true });
    expect(regex).toMatchObject({ mode: 'literal', totalHits: 1 });

    const tokenAnd = await searchDocs(dir, 'rotate body smoothly', {
      semantic: false,
      windowLines: 2,
    });
    expect(tokenAnd).toMatchObject({
      mode: 'token-and',
      tokens: ['rotate', 'body', 'smoothly'],
      totalHits: 1,
    });
    expect(tokenAnd.hits[0].path).toBe('en-us/guide/physics.md');
  });

  test('resolveReference finds categories case-insensitively and returns raw YAML', async () => {
    const part = await resolveReference(dir, 'part');
    expect(part).toMatchObject({
      category: 'class',
      name: 'Part',
      path: 'en-us/reference/engine/classes/Part.yaml',
      data: { name: 'Part', type: 'class' },
    });
    expect(part?.raw).toContain('name: Part');

    const vector = await resolveReference(dir, 'Vector3', 'datatype');
    expect(vector).toMatchObject({
      category: 'datatype',
      name: 'Vector3',
    });
    await expect(resolveReference(dir, 'Missing')).resolves.toBeNull();
  });
});
