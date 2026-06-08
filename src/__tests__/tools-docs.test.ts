import { promises as fs } from 'fs';
import * as os from 'os';
import * as path from 'path';
import { BridgeService } from '../bridge-service';
import { RobloxStudioTools } from '../tools/index';
import { parseToolText } from './helpers';

describe('Roblox documentation tools', () => {
  let cacheDir: string;
  let tools: RobloxStudioTools;

  beforeAll(async () => {
    cacheDir = await fs.mkdtemp(path.join(os.tmpdir(), 'rbxstudio-doc-tools-'));
    process.env.RBXSTUDIO_DOCS_DIR = cacheDir;

    const root = path.join(cacheDir, 'content', 'en-us');
    await fs.mkdir(path.join(root, 'reference', 'engine', 'classes'), { recursive: true });
    await fs.mkdir(path.join(root, 'reference', 'engine', 'datatypes'), { recursive: true });
    await fs.mkdir(path.join(root, 'animation'), { recursive: true });

    await fs.writeFile(
      path.join(root, 'reference', 'engine', 'classes', 'Part.yaml'),
      `name: Part
type: class
summary: |
  A basic 3D object.
properties:
  - name: Anchored
    summary: |
      Determines whether physics moves the part.
    type: boolean
`,
      'utf8',
    );
    await fs.writeFile(
      path.join(root, 'reference', 'engine', 'datatypes', 'CFrame.yaml'),
      `name: CFrame
type: datatype
summary: Coordinate frame value.
`,
      'utf8',
    );
    await fs.writeFile(
      path.join(root, 'animation', 'rigging.md'),
      `# Rigging
Motor6D joints are used to connect body parts in Roblox rigs.
`,
      'utf8',
    );
    await fs.writeFile(
      path.join(cacheDir, 'meta.json'),
      JSON.stringify(
        {
          repo: 'Roblox/creator-docs',
          branch: 'main',
          sha: 'fixture-sha',
          downloadedAt: new Date().toISOString(),
          lastCheckedAt: new Date().toISOString(),
          fileCount: 3,
          bytesOnDisk: 1,
          schemaVersion: 1,
        },
        null,
        2,
      ),
      'utf8',
    );

    tools = new RobloxStudioTools(new BridgeService());
  });

  afterAll(async () => {
    delete process.env.RBXSTUDIO_DOCS_DIR;
    if (cacheDir) await fs.rm(cacheDir, { recursive: true, force: true });
  });

  test('searchRobloxDocs searches the fresh local docs cache', async () => {
    const body = parseToolText(
      await tools.searchRobloxDocs('Anchored', {
        semantic: false,
        maxHits: 10,
      }),
    );

    expect(body).toMatchObject({
      mode: 'literal',
      totalHits: 1,
      filesScanned: 3,
    });
    expect(body.hits[0]).toMatchObject({
      path: 'en-us/reference/engine/classes/Part.yaml',
      text: '  - name: Anchored',
    });
  });

  test('getRobloxDoc reads a single docs file by relative path', async () => {
    const body = parseToolText(await tools.getRobloxDoc('en-us/animation/rigging.md'));

    expect(body).toMatchObject({
      path: 'en-us/animation/rigging.md',
    });
    expect(body.content).toContain('Motor6D joints');
  });

  test('listRobloxDocs returns paginated directory entries', async () => {
    const body = parseToolText(await tools.listRobloxDocs('en-us/reference/engine', { limit: 1 }));

    expect(body).toMatchObject({
      path: 'en-us/reference/engine',
      totalEntries: 2,
      limit: 1,
      truncated: true,
    });
    expect(body.entries[0]).toEqual({ name: 'classes', type: 'dir' });
  });

  test('getRobloxApiReference resolves names case-insensitively and parses YAML', async () => {
    const body = parseToolText(await tools.getRobloxApiReference('part'));

    expect(body).toMatchObject({
      category: 'class',
      name: 'Part',
      path: 'en-us/reference/engine/classes/Part.yaml',
    });
    expect(body.data).toMatchObject({
      name: 'Part',
      type: 'class',
      properties: [{ name: 'Anchored' }],
    });
    expect(body.raw).toContain('name: Part');
  });

  test('docs tools return structured not-found responses', async () => {
    expect(parseToolText(await tools.getRobloxDoc('../secret'))).toMatchObject({
      error: expect.stringContaining('Doc not found'),
      cache: { sha: 'fixture-sha', fileCount: 3 },
    });
    expect(parseToolText(await tools.listRobloxDocs('../secret'))).toMatchObject({
      error: expect.stringContaining('Path not found'),
      cache: { sha: 'fixture-sha', fileCount: 3 },
    });
    expect(parseToolText(await tools.getRobloxApiReference('Nope'))).toMatchObject({
      error: expect.stringContaining('No API reference found'),
      cache: { sha: 'fixture-sha', fileCount: 3 },
    });
  });
});
