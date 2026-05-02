#!/usr/bin/env node

/**
 * Roblox Studio MCP Server
 *
 * This server provides Model Context Protocol (MCP) tools for interacting
 * with Roblox Studio. It allows AI assistants to access Studio data,
 * scripts, and objects through a bridge plugin.
 *
 * Tools are defined declaratively in `src/tools/defs/*.ts` and aggregated
 * by `src/tools/registry.ts`. To add a new tool, edit one of those files —
 * this bootstrap doesn't need to change.
 *
 * Usage:
 *   npx rbxstudio-mcp
 */

import { Server } from '@modelcontextprotocol/sdk/server/index.js';
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';
import {
  CallToolRequestSchema,
  ErrorCode,
  ListToolsRequestSchema,
  McpError,
} from '@modelcontextprotocol/sdk/types.js';
import { createHttpServer } from './http-server.js';
import { RobloxStudioTools } from './tools/index.js';
import { BridgeService } from './bridge-service.js';
import { allTools, toolsByName } from './tools/registry.js';

class RobloxStudioMCPServer {
  private server: Server;
  private tools: RobloxStudioTools;
  private bridge: BridgeService;

  constructor() {
    this.server = new Server(
      {
        name: 'rbxstudio-mcp',
        version: '2.0.0',
      },
      {
        capabilities: {
          tools: {},
        },
      },
    );

    this.bridge = new BridgeService();
    this.tools = new RobloxStudioTools(this.bridge);
    this.setupToolHandlers();
  }

  private setupToolHandlers() {
    // List tools — strip handlers, expose only MCP-visible fields.
    this.server.setRequestHandler(ListToolsRequestSchema, async () => ({
      tools: allTools.map(({ name, description, inputSchema }) => ({
        name,
        description,
        inputSchema,
      })),
    }));

    // Dispatch a single tool call via the registry.
    this.server.setRequestHandler(CallToolRequestSchema, async (request) => {
      const { name, arguments: args } = request.params;
      const tool = toolsByName[name];

      if (!tool) {
        throw new McpError(ErrorCode.MethodNotFound, `Unknown tool: ${name}`);
      }

      try {
        return (await tool.handler(args ?? {}, { tools: this.tools })) as any;
      } catch (error) {
        throw new McpError(
          ErrorCode.InternalError,
          `Tool execution failed: ${error instanceof Error ? error.message : String(error)}`,
        );
      }
    });
  }

  async run() {
    const port = process.env.ROBLOX_STUDIO_PORT
      ? parseInt(process.env.ROBLOX_STUDIO_PORT)
      : 3002;
    const host = process.env.ROBLOX_STUDIO_HOST || '0.0.0.0';
    const httpServer = createHttpServer(this.tools, this.bridge);

    await new Promise<void>((resolve) => {
      httpServer.listen(port, host, () => {
        console.error(`HTTP server listening on ${host}:${port} for Studio plugin`);
        resolve();
      });
    });

    const transport = new StdioServerTransport();
    await this.server.connect(transport);
    console.error('Roblox Studio MCP server running on stdio');

    (httpServer as any).setMCPServerActive(true);
    console.error('MCP server marked as active');

    console.error(`Registered ${allTools.length} tools, waiting for Studio plugin...`);

    setInterval(() => {
      const pluginConnected = (httpServer as any).isPluginConnected();
      const mcpActive = (httpServer as any).isMCPServerActive();

      if (pluginConnected && mcpActive) {
        // both up; quiet
      } else if (pluginConnected && !mcpActive) {
        console.error('Studio plugin connected, but MCP server inactive');
      } else if (!pluginConnected && mcpActive) {
        console.error('MCP server active, waiting for Studio plugin...');
      } else {
        console.error('Waiting for connections...');
      }
    }, 5000);

    setInterval(() => {
      this.bridge.cleanupOldRequests();
    }, 5000);
  }
}

const server = new RobloxStudioMCPServer();
server.run().catch((error) => {
  console.error('Server failed to start:', error);
  process.exit(1);
});
