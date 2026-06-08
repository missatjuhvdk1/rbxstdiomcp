import { promises as fs } from 'fs';
import * as os from 'os';
import * as path from 'path';
import { Readable } from 'stream';
import * as tar from 'tar';
import { contentRoot, readMeta, writeMeta } from '../docs/cache';
import { ensureDocsCache } from '../docs/fetcher';

function jsonResponse(body: unknown) {
  return {
    ok: true,
    status: 200,
    statusText: 'OK',
    json: async () => body,
  };
}

function tarballResponse(buffer: Buffer) {
  return {
    ok: true,
    status: 200,
    statusText: 'OK',
    body: Readable.toWeb(Readable.from(buffer)),
  };
}

async function makeCreatorDocsTarball(label: string): Promise<Buffer> {
  const src = await fs.mkdtemp(path.join(os.tmpdir(), 'creator-docs-src-'));
  const tarPath = path.join(src, 'docs.tar.gz');
  const repo = path.join(src, 'creator-docs-main');
  await fs.mkdir(path.join(repo, 'content', 'en-us', 'reference', 'engine', 'classes'), {
    recursive: true,
  });
  await fs.mkdir(path.join(repo, 'content', 'en-us', 'animation'), { recursive: true });
  await fs.mkdir(path.join(repo, 'content', 'en-us', 'unkept'), { recursive: true });
  await fs.writeFile(
    path.join(repo, 'content', 'en-us', 'reference', 'engine', 'classes', 'Part.yaml'),
    `name: Part\nsummary: ${label}\n`,
    'utf8',
  );
  await fs.writeFile(
    path.join(repo, 'content', 'en-us', 'animation', 'rigging.md'),
    `# Rigging ${label}\n`,
    'utf8',
  );
  await fs.writeFile(
    path.join(repo, 'content', 'en-us', 'unkept', 'skip.md'),
    'not extracted',
    'utf8',
  );
  await fs.writeFile(
    path.join(repo, 'content', 'en-us', 'animation', 'skip.txt'),
    'wrong extension',
    'utf8',
  );

  await tar.c({ gzip: true, cwd: src, file: tarPath }, ['creator-docs-main']);
  const buffer = await fs.readFile(tarPath);
  await fs.rm(src, { recursive: true, force: true });
  return buffer;
}

describe('ensureDocsCache', () => {
  let cacheDir: string;
  let firstTarball: Buffer;
  let secondTarball: Buffer;
  const originalFetch = global.fetch;

  beforeAll(async () => {
    cacheDir = await fs.mkdtemp(path.join(os.tmpdir(), 'rbxdocs-fetcher-'));
    process.env.RBXSTUDIO_DOCS_DIR = cacheDir;
    firstTarball = await makeCreatorDocsTarball('first');
    secondTarball = await makeCreatorDocsTarball('second');
  });

  afterAll(async () => {
    global.fetch = originalFetch;
    delete process.env.RBXSTUDIO_DOCS_DIR;
    if (cacheDir) await fs.rm(cacheDir, { recursive: true, force: true });
  });

  beforeEach(async () => {
    jest.restoreAllMocks();
    await fs.rm(cacheDir, { recursive: true, force: true });
    await fs.mkdir(cacheDir, { recursive: true });
  });

  function mockFetchSequence(...responses: any[]) {
    const fetchMock = jest.fn();
    for (const response of responses) {
      fetchMock.mockResolvedValueOnce(response);
    }
    global.fetch = fetchMock as any;
    return fetchMock;
  }

  test('downloads, filters, extracts, writes metadata, and clears stale semantic index files', async () => {
    await fs.mkdir(path.join(cacheDir, 'index'), { recursive: true });
    await fs.writeFile(path.join(cacheDir, 'index', 'stale.json'), '{}', 'utf8');
    const fetchMock = mockFetchSequence(
      jsonResponse({ sha: 'sha-first' }),
      tarballResponse(firstTarball),
    );

    const result = await ensureDocsCache();

    expect(result).toMatchObject({
      cacheDir,
      action: 'first-download',
      meta: {
        repo: 'Roblox/creator-docs',
        branch: 'main',
        sha: 'sha-first',
        fileCount: 2,
        schemaVersion: 1,
      },
    });
    expect(fetchMock).toHaveBeenCalledTimes(2);
    await expect(
      fs.readFile(
        path.join(contentRoot(cacheDir), 'en-us', 'reference', 'engine', 'classes', 'Part.yaml'),
        'utf8',
      ),
    ).resolves.toContain('first');
    await expect(
      fs.access(path.join(contentRoot(cacheDir), 'en-us', 'unkept', 'skip.md')),
    ).rejects.toBeTruthy();
    await expect(fs.access(path.join(cacheDir, 'index', 'stale.json'))).rejects.toBeTruthy();
  });

  test('uses fresh metadata without hitting the network', async () => {
    await writeMeta(cacheDir, {
      repo: 'Roblox/creator-docs',
      branch: 'main',
      sha: 'fresh-sha',
      downloadedAt: new Date().toISOString(),
      lastCheckedAt: new Date().toISOString(),
      fileCount: 1,
      bytesOnDisk: 5,
    });
    const fetchMock = mockFetchSequence();

    const result = await ensureDocsCache();

    expect(result.action).toBe('fresh');
    expect(result.meta.sha).toBe('fresh-sha');
    expect(fetchMock).not.toHaveBeenCalled();
  });

  test('short-circuits on expired metadata when upstream SHA is unchanged', async () => {
    await writeMeta(cacheDir, {
      repo: 'Roblox/creator-docs',
      branch: 'main',
      sha: 'same-sha',
      downloadedAt: '2000-01-01T00:00:00.000Z',
      lastCheckedAt: '2000-01-01T00:00:00.000Z',
      fileCount: 1,
      bytesOnDisk: 5,
    });
    const fetchMock = mockFetchSequence(jsonResponse({ sha: 'same-sha' }));

    const result = await ensureDocsCache({ ttlMs: 0 });
    const meta = await readMeta(cacheDir);

    expect(result.action).toBe('sha-short-circuit');
    expect(result.meta.sha).toBe('same-sha');
    expect(meta?.lastCheckedAt).not.toBe('2000-01-01T00:00:00.000Z');
    expect(fetchMock).toHaveBeenCalledTimes(1);
  });

  test('redownloads when forced or when upstream SHA changed', async () => {
    await writeMeta(cacheDir, {
      repo: 'Roblox/creator-docs',
      branch: 'main',
      sha: 'old-sha',
      downloadedAt: '2000-01-01T00:00:00.000Z',
      lastCheckedAt: '2000-01-01T00:00:00.000Z',
      fileCount: 1,
      bytesOnDisk: 5,
    });
    mockFetchSequence(jsonResponse({ sha: 'new-sha' }), jsonResponse({ sha: 'new-sha' }), tarballResponse(secondTarball));

    const changed = await ensureDocsCache({ ttlMs: 0 });

    expect(changed.action).toBe('redownloaded');
    expect(changed.meta.sha).toBe('new-sha');
    await expect(
      fs.readFile(
        path.join(contentRoot(cacheDir), 'en-us', 'reference', 'engine', 'classes', 'Part.yaml'),
        'utf8',
      ),
    ).resolves.toContain('second');

    mockFetchSequence(jsonResponse({ sha: 'forced-sha' }), tarballResponse(firstTarball));
    const forced = await ensureDocsCache({ force: true });
    expect(forced.action).toBe('redownloaded');
    expect(forced.meta.sha).toBe('forced-sha');
  });

  test('surfaces GitHub and tarball errors with actionable messages', async () => {
    mockFetchSequence(jsonResponse({ sha: 'sha' }), {
      ok: false,
      status: 500,
      statusText: 'Server Error',
      json: async () => ({}),
    });
    await expect(ensureDocsCache()).rejects.toThrow('Tarball download failed');

    await writeMeta(cacheDir, {
      repo: 'Roblox/creator-docs',
      branch: 'main',
      sha: 'old-sha',
      downloadedAt: '2000-01-01T00:00:00.000Z',
      lastCheckedAt: '2000-01-01T00:00:00.000Z',
      fileCount: 1,
      bytesOnDisk: 5,
    });
    mockFetchSequence({
      ok: false,
      status: 403,
      statusText: 'Forbidden',
      json: async () => ({}),
    });
    await expect(ensureDocsCache({ ttlMs: 0 })).rejects.toThrow('GitHub API 403 Forbidden');
  });
});
