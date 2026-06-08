import type { RobloxStudioTools } from './index.js';

export interface ToolContext {
  tools: RobloxStudioTools;
}

export interface ToolDef {
  /** MCP tool name (snake_case). */
  name: string;
  /** Human-readable description shown to the LLM. */
  description: string;
  /** JSON Schema for the tool's input arguments. */
  inputSchema: Record<string, unknown>;
  /** Handler invoked when the tool is called. */
  handler: (args: any, ctx: ToolContext) => Promise<unknown>;
  /**
   * Optional just-in-time steering appended to this tool's result as an extra
   * text content block. Unlike the always-on `description` (which the model
   * pays for on every turn), a nudge only arrives when the tool is actually
   * called — the most reliable moment to remind the model how to behave
   * (e.g. "instrument and hand off; don't loop play-tests to judge feel").
   * Applied centrally in the dispatch layer via `applyNudge`.
   */
  nudge?: string;
}
