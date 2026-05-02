import type { ToolDef } from './types.js';
import { inspectionTools } from './defs/inspection.js';
import { propertyTools } from './defs/properties.js';
import { attributeTools } from './defs/attributes.js';
import { tagTools } from './defs/tags.js';
import { objectTools } from './defs/objects.js';
import { scriptTools } from './defs/scripts.js';
import { runtimeTools } from './defs/runtime.js';
import { visualTools } from './defs/visual.js';
import { executeTools } from './defs/execute.js';

/**
 * The full registry of MCP tool definitions.
 *
 * Adding a new tool: drop a `ToolDef` into the appropriate file under
 * `src/tools/defs/`, or create a new category file and import its array
 * here. No need to touch `src/index.ts` — it dispatches via this list.
 */
export const allTools: ToolDef[] = [
  ...inspectionTools,
  ...propertyTools,
  ...attributeTools,
  ...tagTools,
  ...objectTools,
  ...scriptTools,
  ...runtimeTools,
  ...visualTools,
  ...executeTools,
];

/** Fast lookup: tool name → ToolDef. */
export const toolsByName: Record<string, ToolDef> = Object.fromEntries(
  allTools.map((t) => [t.name, t]),
);

// Sanity check: no duplicate names. Throws at import time if violated, so
// a typo in a category file can't silently shadow another tool.
if (Object.keys(toolsByName).length !== allTools.length) {
  const seen = new Set<string>();
  const dupes: string[] = [];
  for (const t of allTools) {
    if (seen.has(t.name)) dupes.push(t.name);
    seen.add(t.name);
  }
  throw new Error(`Duplicate tool name(s) in registry: ${dupes.join(', ')}`);
}
