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
}
