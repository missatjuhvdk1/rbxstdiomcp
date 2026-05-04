import { promises as fs } from 'fs';
import * as path from 'path';
import * as yaml from 'js-yaml';
import { contentRoot } from './cache.js';

/**
 * `get_roblox_api_reference` resolver.
 *
 * The creator-docs repo stores structured API reference under:
 *
 *   content/en-us/reference/engine/
 *     classes/<ClassName>.yaml      (e.g. Motor6D.yaml, Part.yaml)
 *     datatypes/<TypeName>.yaml     (e.g. CFrame.yaml, Vector3.yaml)
 *     enums/<EnumName>.yaml         (e.g. Material.yaml, KeyCode.yaml)
 *     globals/<API>.yaml            (e.g. RobloxGlobals.yaml)
 *     libraries/<Lib>.yaml          (e.g. math.yaml, string.yaml)
 *
 * The model usually knows what it's looking for ("Motor6D", "CFrame",
 * "Material") but doesn't know which subdirectory to look in. This
 * module resolves a name to the correct file and returns parsed YAML.
 */

const ENGINE_REL = path.join('en-us', 'reference', 'engine');

const CATEGORY_DIRS = {
  class: 'classes',
  datatype: 'datatypes',
  enum: 'enums',
  global: 'globals',
  library: 'libraries',
} as const;

export type ReferenceCategory = keyof typeof CATEGORY_DIRS;

export interface ReferenceLookupResult {
  /** Where it was found, e.g. "classes" or "datatypes". */
  category: ReferenceCategory;
  /** The canonical name as it appears on disk (e.g. "Motor6D"). */
  name: string;
  /** Path relative to the content root. */
  path: string;
  /** Parsed YAML body. Shape mirrors creator-docs' API schema. */
  data: unknown;
  /** Raw YAML source — handy for grep-style follow-ups. */
  raw: string;
}

async function exists(p: string): Promise<boolean> {
  try {
    await fs.access(p);
    return true;
  } catch {
    return false;
  }
}

async function findInDir(dir: string, name: string): Promise<string | null> {
  // Try the obvious filename first (cheap, no readdir).
  const direct = path.join(dir, `${name}.yaml`);
  if (await exists(direct)) return direct;

  // Fall back to a case-insensitive scan. Roblox YAML names are
  // PascalCase, but the model sometimes lowercases them ("part",
  // "cframe"). Scanning the directory once is fine — there are
  // <2k files total across all categories.
  let entries;
  try {
    entries = await fs.readdir(dir);
  } catch {
    return null;
  }
  const target = `${name.toLowerCase()}.yaml`;
  for (const f of entries) {
    if (f.toLowerCase() === target) {
      return path.join(dir, f);
    }
  }
  return null;
}

/**
 * Resolve a bare name like "Motor6D" or "CFrame" to a parsed YAML doc.
 *
 * Resolution order (when `category` is omitted):
 *   1. classes
 *   2. datatypes
 *   3. enums
 *   4. globals
 *   5. libraries
 *
 * The first match wins. Roblox's namespace doesn't currently have name
 * collisions across these categories that I know of, but if it ever
 * does the caller can disambiguate via `category`.
 */
export async function resolveReference(
  cacheDir: string,
  name: string,
  category?: ReferenceCategory,
): Promise<ReferenceLookupResult | null> {
  if (!name) return null;
  const root = path.join(contentRoot(cacheDir), ENGINE_REL);

  const order: ReferenceCategory[] = category
    ? [category]
    : ['class', 'datatype', 'enum', 'global', 'library'];

  for (const cat of order) {
    const dir = path.join(root, CATEGORY_DIRS[cat]);
    const hit = await findInDir(dir, name);
    if (!hit) continue;

    const raw = await fs.readFile(hit, 'utf8');
    let data: unknown = null;
    try {
      data = yaml.load(raw, { filename: hit, schema: yaml.JSON_SCHEMA });
    } catch (err: any) {
      // Don't fail the tool call just because YAML parse went sideways
      // — return the raw text so the model can still grep through it.
      data = { __parseError: err?.message ?? String(err) };
    }

    return {
      category: cat,
      name: path.basename(hit, '.yaml'),
      path: path.relative(contentRoot(cacheDir), hit),
      data,
      raw,
    };
  }
  return null;
}
