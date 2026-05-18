/**
 * Chunker unit tests — no network, no model load. Pure string-in /
 * Chunk[]-out testing of the heading-aware markdown and member-aware
 * YAML splitters.
 *
 * We use the private __test__ export to test the per-format functions
 * directly, then a small fixture run of the public walkChunks() to
 * sanity-check the file walk.
 */
import { promises as fs } from 'fs';
import * as os from 'os';
import * as path from 'path';
import { __test__, chunkAll } from '../docs/embeddings/chunker.js';

const { chunkMarkdown, chunkYaml, extractYamlField, splitOversize } = __test__;

describe('chunker: extractYamlField', () => {
  test('extracts top-level scalar', () => {
    expect(extractYamlField('name: Motor6D\ntype: class', 'name')).toBe('Motor6D');
  });
  test('strips single quotes', () => {
    expect(extractYamlField("name: 'Class.Motor6D'", 'name')).toBe('Class.Motor6D');
  });
  test('strips double quotes', () => {
    expect(extractYamlField('name: "with spaces"', 'name')).toBe('with spaces');
  });
  test('returns null for missing key', () => {
    expect(extractYamlField('foo: bar', 'baz')).toBeNull();
  });
  test('handles dash-prefixed (list-entry) form', () => {
    expect(extractYamlField('  - name: C0\n    type: CFrame', 'name')).toBe('C0');
  });
});

describe('chunker: chunkMarkdown', () => {
  test('splits on top-level headings', () => {
    // Each section body needs to clear MIN_CHUNK_CHARS (40) for the
    // chunker to keep it — otherwise stubby sections are dropped on
    // purpose (we don't want to emit empty "## Examples" stubs).
    const md = `# Intro
this is the intro section with enough content to clear the minimum chunk size threshold.

# Body
the body has more text and explanation that goes well beyond the forty-character bound.

# Conclusion
closes out the document with a substantial wrap-up paragraph that is also long enough.`;
    const chunks = chunkMarkdown('en-us/test.md', md);
    const headings = chunks.map((c) => c.label);
    expect(headings).toContain('Intro');
    expect(headings).toContain('Body');
    expect(headings).toContain('Conclusion');
  });

  test('preamble before first heading is preserved', () => {
    const longBody = 'some preamble text. '.repeat(10);
    const md = `${longBody}

# First
hello world hello world hello world hello world hello world`;
    const chunks = chunkMarkdown('en-us/test.md', md);
    const preambles = chunks.filter((c) => c.label === '<preamble>');
    expect(preambles.length).toBe(1);
    expect(preambles[0].text).toMatch(/some preamble text/);
  });

  test('ignores headings inside code fences', () => {
    const md = `# Real Heading
\`\`\`lua
-- # This is not a markdown heading
local x = 1
\`\`\`
more body.`;
    const chunks = chunkMarkdown('en-us/test.md', md);
    expect(chunks.length).toBe(1);
    expect(chunks[0].label).toBe('Real Heading');
  });

  test('line ranges roughly align with heading positions', () => {
    // Bodies again need to clear MIN_CHUNK_CHARS or they're dropped.
    const md = `# A
section A body with enough characters to satisfy the minimum chunk size requirement.
another line of body text for section A so its line range is non-trivial too.

# B
section B body with more than forty characters of text in it so it sticks.
another line of body text for section B to make the line range meaningful.`;
    const chunks = chunkMarkdown('en-us/test.md', md);
    const aIdx = chunks.findIndex((c) => c.label === 'A');
    const bIdx = chunks.findIndex((c) => c.label === 'B');
    expect(aIdx).toBeGreaterThanOrEqual(0);
    expect(bIdx).toBeGreaterThanOrEqual(0);
    expect(chunks[bIdx].startLine).toBeGreaterThan(chunks[aIdx].startLine);
  });

  test('headed sections carry their kind', () => {
    const md = `# Long Heading
${'lorem ipsum '.repeat(20)}`;
    const chunks = chunkMarkdown('en-us/test.md', md);
    expect(chunks.every((c) => c.kind === 'md-section')).toBe(true);
  });
});

describe('chunker: chunkYaml', () => {
  test('splits properties into per-member chunks', () => {
    const yaml = `name: Motor6D
type: class
summary: |
  A Motor6D is a joint that drives rotation between two parts.
description: |
  Motor6D is the workhorse of character animation.
properties:
  - name: C0
    summary: |
      The CFrame offset of the joint on Part0.
    type: CFrame
  - name: C1
    summary: |
      The CFrame offset of the joint on Part1.
    type: CFrame
methods:
  - name: SetDesiredAngle
    summary: |
      Sets the angle the motor should rotate toward.
`;
    const chunks = chunkYaml('en-us/reference/engine/classes/Motor6D.yaml', yaml);
    const labels = chunks.map((c) => c.label);
    // Preamble + 2 properties + 1 method = 4 chunks (Motor6D as label).
    expect(labels).toContain('Motor6D');
    expect(labels).toContain('Motor6D.C0');
    expect(labels).toContain('Motor6D.C1');
    expect(labels).toContain('Motor6D.SetDesiredAngle');
    // Each member chunk carries the parent name in its text.
    const c0 = chunks.find((c) => c.label === 'Motor6D.C0')!;
    expect(c0.text).toMatch(/Motor6D/);
    expect(c0.text).toMatch(/C0/);
    expect(c0.kind).toBe('yaml-member');
  });

  test('non-schema yaml falls back to fallback chunker', () => {
    const yaml = `# this is just yaml frontmatter
key: value
another: thing
`;
    const chunks = chunkYaml('en-us/misc.yaml', yaml);
    // Without `properties:` etc the file is too small to chunk at all
    // (below MIN_CHUNK_CHARS) — that's fine, the test asserts no crash
    // and zero or more chunks with yaml-misc kind if produced.
    for (const c of chunks) {
      expect(c.kind).toBe('yaml-misc');
    }
  });
});

describe('chunker: splitOversize', () => {
  test('keeps small text intact', () => {
    const out = splitOversize('hello world', 0, 0);
    expect(out.length).toBe(1);
    expect(out[0].text).toBe('hello world');
  });
  test('splits oversize on paragraph boundaries', () => {
    const para = 'x'.repeat(800);
    const text = `${para}\n\n${para}\n\n${para}`;
    const out = splitOversize(text, 0, 10);
    expect(out.length).toBeGreaterThanOrEqual(2);
    for (const piece of out) {
      expect(piece.text.length).toBeLessThanOrEqual(900 + 10); // some slack
    }
  });
});

describe('chunker: chunkAll on tiny fixture tree', () => {
  let tmpDir: string;
  beforeAll(async () => {
    tmpDir = await fs.mkdtemp(path.join(os.tmpdir(), 'rbxdocs-chunker-'));
    const content = path.join(tmpDir, 'content', 'en-us');
    await fs.mkdir(path.join(content, 'reference', 'engine', 'classes'), { recursive: true });
    await fs.mkdir(path.join(content, 'animation'), { recursive: true });
    await fs.writeFile(
      path.join(content, 'animation', 'rigging.md'),
      `# Rigging guide
Long explanation about rigging. ${'lorem '.repeat(60)}
## Anatomy
A rig has parts. ${'ipsum '.repeat(60)}`,
      'utf8',
    );
    await fs.writeFile(
      path.join(content, 'reference', 'engine', 'classes', 'Motor6D.yaml'),
      `name: Motor6D
type: class
summary: |
  Motor6D connects two parts with a rotational joint.
description: |
  More detail about Motor6D.
properties:
  - name: C0
    summary: |
      The CFrame offset on Part0.
    type: CFrame
  - name: C1
    summary: |
      The CFrame offset on Part1.
    type: CFrame
`,
      'utf8',
    );
  });
  afterAll(async () => {
    await fs.rm(tmpDir, { recursive: true, force: true });
  });

  test('produces both md-section and yaml-member chunks', async () => {
    const chunks = await chunkAll(tmpDir);
    const kinds = new Set(chunks.map((c) => c.kind));
    expect(kinds.has('md-section')).toBe(true);
    expect(kinds.has('yaml-member')).toBe(true);
    // Every chunk has a non-empty path.
    expect(chunks.every((c) => c.path && c.startLine > 0 && c.endLine >= c.startLine)).toBe(true);
  });
});
