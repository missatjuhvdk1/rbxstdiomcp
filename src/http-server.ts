import express from 'express';
import cors from 'cors';
import { RobloxStudioTools } from './tools/index.js';
import { BridgeService } from './bridge-service.js';

export function createHttpServer(tools: RobloxStudioTools, bridge: BridgeService) {
  const app = express();
  let pluginConnected = false;
  let mcpServerActive = false;
  let lastMCPActivity = 0;
  let mcpServerStartTime = 0;
  let lastPluginActivity = 0;

  // Track MCP server lifecycle
  const setMCPServerActive = (active: boolean) => {
    mcpServerActive = active;
    if (active) {
      mcpServerStartTime = Date.now();
      lastMCPActivity = Date.now();
    } else {
      mcpServerStartTime = 0;
      lastMCPActivity = 0;
    }
  };

  const trackMCPActivity = () => {
    if (mcpServerActive) {
      lastMCPActivity = Date.now();
    }
  };

  const isMCPServerActive = () => {
    return mcpServerActive && (Date.now() - lastMCPActivity < 15000); // 15 second timeout
  };

  const isPluginConnected = () => {
    // Consider plugin disconnected if no activity for 10 seconds
    return pluginConnected && (Date.now() - lastPluginActivity < 10000);
  };

  app.use(cors());
  app.use(express.json({ limit: '50mb' }));
  app.use(express.urlencoded({ limit: '50mb', extended: true }));

  // Health check endpoint
  app.get('/health', (req, res) => {
    res.json({ 
      status: 'ok', 
      service: 'robloxstudio-mcp',
      pluginConnected,
      mcpServerActive: isMCPServerActive(),
      uptime: mcpServerActive ? Date.now() - mcpServerStartTime : 0
    });
  });

  // Plugin readiness endpoint
  app.post('/ready', (req, res) => {
    pluginConnected = true;
    lastPluginActivity = Date.now();
    res.json({ success: true });
  });

  // Plugin disconnect endpoint
  app.post('/disconnect', (req, res) => {
    pluginConnected = false;
    // Clear any pending requests when plugin disconnects
    bridge.clearAllPendingRequests();
    res.json({ success: true });
  });

  // Enhanced status endpoint
  app.get('/status', (req, res) => {
    res.json({ 
      pluginConnected,
      mcpServerActive: isMCPServerActive(),
      lastMCPActivity,
      uptime: mcpServerActive ? Date.now() - mcpServerStartTime : 0
    });
  });

  // Enhanced polling endpoint for Studio plugin
  app.get('/poll', (req, res) => {
    // Always track that plugin is polling (shows it's trying to connect)
    if (!pluginConnected) {
      pluginConnected = true;
    }
    lastPluginActivity = Date.now();
    
    if (!isMCPServerActive()) {
      res.status(503).json({ 
        error: 'MCP server not connected',
        pluginConnected: true,
        mcpConnected: false,
        request: null
      });
      return;
    }
    
    trackMCPActivity();
    
    const pendingRequest = bridge.getPendingRequest();
    if (pendingRequest) {
      res.json({ 
        request: pendingRequest.request, 
        requestId: pendingRequest.requestId,
        mcpConnected: true,
        pluginConnected: true
      });
    } else {
      res.json({ 
        request: null,
        mcpConnected: true,
        pluginConnected: true
      });
    }
  });

  // Response endpoint for Studio plugin
  app.post('/response', (req, res) => {
    const { requestId, response, error } = req.body;
    
    if (error) {
      bridge.rejectRequest(requestId, error);
    } else {
      bridge.resolveRequest(requestId, response);
    }
    
    res.json({ success: true });
  });

  // Middleware to track MCP activity for all MCP endpoints
  app.use('/mcp/*', (req, res, next) => {
    trackMCPActivity();
    next();
  });

  // MCP tool proxy endpoints - these will be called by AI tools
  app.post('/mcp/get_file_tree', async (req, res) => {
    try {
      const result = await tools.getFileTree(req.body.path);
      res.json(result);
    } catch (error) {
      res.status(500).json({ error: error instanceof Error ? error.message : 'Unknown error' });
    }
  });


  app.post('/mcp/search_files', async (req, res) => {
    try {
      const result = await tools.searchFiles(req.body.query, req.body.searchType);
      res.json(result);
    } catch (error) {
      res.status(500).json({ error: error instanceof Error ? error.message : 'Unknown error' });
    }
  });


  app.post('/mcp/get_place_info', async (req, res) => {
    try {
      const result = await tools.getPlaceInfo();
      res.json(result);
    } catch (error) {
      res.status(500).json({ error: error instanceof Error ? error.message : 'Unknown error' });
    }
  });

  app.post('/mcp/get_services', async (req, res) => {
    try {
      const result = await tools.getServices(req.body.serviceName);
      res.json(result);
    } catch (error) {
      res.status(500).json({ error: error instanceof Error ? error.message : 'Unknown error' });
    }
  });


  app.post('/mcp/search_objects', async (req, res) => {
    try {
      const result = await tools.searchObjects(req.body.query, req.body.searchType, req.body.propertyName);
      res.json(result);
    } catch (error) {
      res.status(500).json({ error: error instanceof Error ? error.message : 'Unknown error' });
    }
  });

  app.post('/mcp/get_instance_properties', async (req, res) => {
    try {
      const result = await tools.getInstanceProperties(req.body.instancePath);
      res.json(result);
    } catch (error) {
      res.status(500).json({ error: error instanceof Error ? error.message : 'Unknown error' });
    }
  });

  app.post('/mcp/get_instance_children', async (req, res) => {
    try {
      const result = await tools.getInstanceChildren(req.body.instancePath);
      res.json(result);
    } catch (error) {
      res.status(500).json({ error: error instanceof Error ? error.message : 'Unknown error' });
    }
  });

  app.post('/mcp/search_by_property', async (req, res) => {
    try {
      const result = await tools.searchByProperty(req.body.propertyName, req.body.propertyValue);
      res.json(result);
    } catch (error) {
      res.status(500).json({ error: error instanceof Error ? error.message : 'Unknown error' });
    }
  });

  app.post('/mcp/get_class_info', async (req, res) => {
    try {
      const result = await tools.getClassInfo(req.body.className);
      res.json(result);
    } catch (error) {
      res.status(500).json({ error: error instanceof Error ? error.message : 'Unknown error' });
    }
  });

  app.post('/mcp/mass_set_property', async (req, res) => {
    try {
      const result = await tools.massSetProperty(req.body.paths, req.body.propertyName, req.body.propertyValue);
      res.json(result);
    } catch (error) {
      res.status(500).json({ error: error instanceof Error ? error.message : 'Unknown error' });
    }
  });

  app.post('/mcp/mass_get_property', async (req, res) => {
    try {
      const result = await tools.massGetProperty(req.body.paths, req.body.propertyName);
      res.json(result);
    } catch (error) {
      res.status(500).json({ error: error instanceof Error ? error.message : 'Unknown error' });
    }
  });

  app.post('/mcp/create_object_with_properties', async (req, res) => {
    try {
      const result = await tools.createObjectWithProperties(req.body.className, req.body.parent, req.body.name, req.body.properties);
      res.json(result);
    } catch (error) {
      res.status(500).json({ error: error instanceof Error ? error.message : 'Unknown error' });
    }
  });

  app.post('/mcp/mass_create_objects', async (req, res) => {
    try {
      const result = await tools.massCreateObjects(req.body.objects);
      res.json(result);
    } catch (error) {
      res.status(500).json({ error: error instanceof Error ? error.message : 'Unknown error' });
    }
  });

  app.post('/mcp/mass_create_objects_with_properties', async (req, res) => {
    try {
      const result = await tools.massCreateObjectsWithProperties(req.body.objects);
      res.json(result);
    } catch (error) {
      res.status(500).json({ error: error instanceof Error ? error.message : 'Unknown error' });
    }
  });

  app.post('/mcp/get_project_structure', async (req, res) => {
    try {
      const result = await tools.getProjectStructure(req.body.path, req.body.maxDepth, req.body.scriptsOnly);
      res.json(result);
    } catch (error) {
      res.status(500).json({ error: error instanceof Error ? error.message : 'Unknown error' });
    }
  });

  // Script management endpoints (parity with tools)
  app.post('/mcp/get_script_source', async (req, res) => {
    try {
      const result = await tools.getScriptSource(req.body.instancePath);
      res.json(result);
    } catch (error) {
      res.status(500).json({ error: error instanceof Error ? error.message : 'Unknown error' });
    }
  });

  app.post('/mcp/set_script_source', async (req, res) => {
    try {
      const result = await tools.setScriptSource(req.body.instancePath, req.body.source);
      res.json(result);
    } catch (error) {
      res.status(500).json({ error: error instanceof Error ? error.message : 'Unknown error' });
    }
  });

  app.post('/mcp/get_selection', async (req, res) => {
    try {
      const result = await tools.getSelection();
      res.json(result);
    } catch (error) {
      res.status(500).json({ error: error instanceof Error ? error.message : 'Unknown error' });
    }
  });

  // ==========================================================================
  // Test session endpoints — used by the companion script that runs INSIDE
  // the Studio test's Server DataModel (not by the Edit-side plugin).
  //
  // The companion polls /test-session/poll for commands (like "end"), posts
  // log batches to /test-session/log, and reports completion to
  // /test-session/ended. The Edit-side plugin also posts to /ended when its
  // ExecutePlayModeAsync call returns naturally.
  // ==========================================================================

  // Companion polls this for commands. Always echoes back the session
  // status so the companion can self-terminate cleanly when the session
  // is marked ended (e.g. user clicked Studio's Stop button).
  //
  // Body shape:
  //   { sessionId: string,
  //     target?: 'server' | 'client',  // defaults to 'server' for back-compat
  //     userId?: number,                // required when target='client'
  //     playerName?: string,            // optional, helps run_live_lua resolve targets
  //     hello?: { loadstringReady: boolean }  // sent on first poll }
  app.post('/test-session/poll', (req, res) => {
    const { sessionId, target, userId, playerName, hello } = req.body || {};
    if (typeof sessionId !== 'string' || sessionId.length === 0) {
      res.status(400).json({ error: 'sessionId required' });
      return;
    }
    const normalizedTarget = target === 'client' ? 'client' : 'server';
    const options: {
      userId?: number;
      playerName?: string;
      hello?: { loadstringReady?: boolean };
    } = {};
    if (typeof userId === 'number') options.userId = userId;
    if (typeof playerName === 'string') options.playerName = playerName;
    if (hello && typeof hello === 'object') {
      options.hello = {
        loadstringReady: !!hello.loadstringReady,
      };
    }
    const result = bridge.popTestCommand(sessionId, normalizedTarget, options);
    res.json({
      command: result.command,
      ended: result.ended,
      sessionMatch: result.sessionMatch,
    });
  });

  // Companion streams LogService output here. Body shape:
  //   { sessionId: string,
  //     source?: 'server' | 'client',  // tags entries so consumers can split
  //     messages: [{ message, messageType, timestamp }] }
  app.post('/test-session/log', (req, res) => {
    const { sessionId, messages, source } = req.body || {};
    if (typeof sessionId !== 'string' || sessionId.length === 0) {
      res.status(400).json({ error: 'sessionId required' });
      return;
    }
    if (!Array.isArray(messages)) {
      res.status(400).json({ error: 'messages must be an array' });
      return;
    }
    const normalizedSource: 'server' | 'client' = source === 'client' ? 'client' : 'server';
    const result = bridge.appendTestOutput(sessionId, messages, normalizedSource);
    res.json({ accepted: result.accepted, sessionMatch: result.sessionMatch });
  });

  // Companion delivers run_live_lua results here. Body shape:
  //   { sessionId, replyId, ok, values?, errorType?, error?, traceback?,
  //     logs?, durationMs? }
  // Idempotent w.r.t. the same replyId — late deliveries (after the
  // watchdog already fired) are accepted but discarded.
  app.post('/test-session/eval-result', (req, res) => {
    const { sessionId, replyId, ok, values, errorType, error, traceback, logs, durationMs } = req.body || {};
    if (typeof sessionId !== 'string' || sessionId.length === 0) {
      res.status(400).json({ error: 'sessionId required' });
      return;
    }
    if (typeof replyId !== 'string' || replyId.length === 0) {
      res.status(400).json({ error: 'replyId required' });
      return;
    }
    const matched = bridge.resolveEvalReply(sessionId, replyId, {
      ok: !!ok,
      values: Array.isArray(values) ? values : undefined,
      errorType,
      error: typeof error === 'string' ? error : undefined,
      traceback: typeof traceback === 'string' ? traceback : undefined,
      logs: Array.isArray(logs) ? logs : undefined,
      durationMs: typeof durationMs === 'number' ? durationMs : undefined,
    });
    res.json({ matched });
  });

  // Either the companion (after processing an end command) or the Edit-side
  // plugin (after ExecutePlayModeAsync returns) reports the session ended.
  // First caller wins; subsequent calls are idempotent.
  app.post('/test-session/ended', (req, res) => {
    const { sessionId, reason, value } = req.body || {};
    if (typeof sessionId !== 'string' || sessionId.length === 0) {
      res.status(400).json({ error: 'sessionId required' });
      return;
    }
    const ok = bridge.endTestSession(sessionId, String(reason || 'unknown'), value);
    res.json({ ok });
  });

  // Add methods to control and check server status
  (app as any).isPluginConnected = isPluginConnected;
  (app as any).setMCPServerActive = setMCPServerActive;
  (app as any).isMCPServerActive = isMCPServerActive;
  (app as any).trackMCPActivity = trackMCPActivity;

  return app;
}