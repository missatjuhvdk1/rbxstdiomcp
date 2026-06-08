import request from 'supertest';
import { Application } from 'express';
import { BridgeService } from '../bridge-service';
import { createHttpServer } from '../http-server';
import { RobloxStudioTools } from '../tools/index';

type RouteCase = {
  path: string;
  body: Record<string, unknown>;
  method: string;
  expectedArgs: unknown[];
};

const routeCases: RouteCase[] = [
  { path: '/mcp/get_file_tree', body: { path: 'game' }, method: 'getFileTree', expectedArgs: ['game'] },
  {
    path: '/mcp/search_files',
    body: { query: 'Enemy', searchType: 'source' },
    method: 'searchFiles',
    expectedArgs: ['Enemy', 'source'],
  },
  { path: '/mcp/get_place_info', body: {}, method: 'getPlaceInfo', expectedArgs: [] },
  {
    path: '/mcp/get_services',
    body: { serviceName: 'Workspace' },
    method: 'getServices',
    expectedArgs: ['Workspace'],
  },
  {
    path: '/mcp/search_objects',
    body: { query: 'Part', searchType: 'className', propertyName: 'Name' },
    method: 'searchObjects',
    expectedArgs: ['Part', 'className', 'Name'],
  },
  {
    path: '/mcp/get_instance_properties',
    body: { instancePath: 'game.Workspace.Part' },
    method: 'getInstanceProperties',
    expectedArgs: ['game.Workspace.Part'],
  },
  {
    path: '/mcp/get_instance_children',
    body: { instancePath: 'game.Workspace' },
    method: 'getInstanceChildren',
    expectedArgs: ['game.Workspace'],
  },
  {
    path: '/mcp/search_by_property',
    body: { propertyName: 'Name', propertyValue: 'Part' },
    method: 'searchByProperty',
    expectedArgs: ['Name', 'Part'],
  },
  {
    path: '/mcp/get_class_info',
    body: { className: 'Part' },
    method: 'getClassInfo',
    expectedArgs: ['Part'],
  },
  {
    path: '/mcp/mass_set_property',
    body: { paths: ['a'], propertyName: 'Name', propertyValue: 'Block' },
    method: 'massSetProperty',
    expectedArgs: [['a'], 'Name', 'Block'],
  },
  {
    path: '/mcp/mass_get_property',
    body: { paths: ['a'], propertyName: 'Name' },
    method: 'massGetProperty',
    expectedArgs: [['a'], 'Name'],
  },
  {
    path: '/mcp/create_object_with_properties',
    body: { className: 'Part', parent: 'game.Workspace', name: 'Block', properties: { Anchored: true } },
    method: 'createObjectWithProperties',
    expectedArgs: ['Part', 'game.Workspace', 'Block', { Anchored: true }],
  },
  {
    path: '/mcp/mass_create_objects',
    body: { objects: [{ className: 'Part', parent: 'game.Workspace' }] },
    method: 'massCreateObjects',
    expectedArgs: [[{ className: 'Part', parent: 'game.Workspace' }]],
  },
  {
    path: '/mcp/mass_create_objects_with_properties',
    body: { objects: [{ className: 'Part', parent: 'game.Workspace', properties: { Anchored: true } }] },
    method: 'massCreateObjectsWithProperties',
    expectedArgs: [[{ className: 'Part', parent: 'game.Workspace', properties: { Anchored: true } }]],
  },
  {
    path: '/mcp/get_project_structure',
    body: { path: 'game', maxDepth: 3, scriptsOnly: true },
    method: 'getProjectStructure',
    expectedArgs: ['game', 3, true],
  },
  {
    path: '/mcp/get_script_source',
    body: { instancePath: 'game.Script' },
    method: 'getScriptSource',
    expectedArgs: ['game.Script'],
  },
  {
    path: '/mcp/set_script_source',
    body: { instancePath: 'game.Script', source: 'print("hi")' },
    method: 'setScriptSource',
    expectedArgs: ['game.Script', 'print("hi")'],
  },
  { path: '/mcp/get_selection', body: {}, method: 'getSelection', expectedArgs: [] },
];

function createMockTools() {
  const methods = new Map<string, jest.Mock>();
  const tools = new Proxy(
    {},
    {
      get(_target, prop: string) {
        if (!methods.has(prop)) {
          methods.set(prop, jest.fn().mockResolvedValue({ ok: prop }));
        }
        return methods.get(prop);
      },
    },
  ) as RobloxStudioTools;
  return { tools, methods };
}

describe('HTTP MCP route contracts', () => {
  let app: Application & any;
  let methods: Map<string, jest.Mock>;

  beforeEach(() => {
    const mock = createMockTools();
    methods = mock.methods;
    app = createHttpServer(mock.tools, new BridgeService()) as Application & any;
    app.setMCPServerActive(true);
  });

  test.each(routeCases)('$path calls $method with request-body arguments', async (testCase) => {
    const response = await request(app).post(testCase.path).send(testCase.body).expect(200);

    expect(response.body).toEqual({ ok: testCase.method });
    expect(methods.get(testCase.method)).toHaveBeenCalledTimes(1);
    expect(methods.get(testCase.method)).toHaveBeenCalledWith(...testCase.expectedArgs);
  });

  test('MCP route errors are returned as 500 JSON bodies', async () => {
    methods.set('getPlaceInfo', jest.fn().mockRejectedValueOnce(new Error('Studio exploded')));

    const response = await request(app).post('/mcp/get_place_info').send({}).expect(500);

    expect(response.body).toEqual({ error: 'Studio exploded' });
  });
});

describe('HTTP companion test-session endpoints', () => {
  let app: Application & any;
  let bridge: BridgeService;

  beforeEach(() => {
    bridge = new BridgeService();
    app = createHttpServer(new RobloxStudioTools(bridge), bridge) as Application & any;
  });

  test('poll validates sessionId and returns queued server commands', async () => {
    await request(app).post('/test-session/poll').send({}).expect(400, { error: 'sessionId required' });

    const sessionId = bridge.startTestSession();
    bridge.enqueueTestCommand({ cmd: 'end', args: 'stop' });

    const response = await request(app)
      .post('/test-session/poll')
      .send({ sessionId, hello: { loadstringReady: true } })
      .expect(200);

    expect(response.body).toEqual({
      command: { cmd: 'end', args: 'stop' },
      ended: false,
      sessionMatch: true,
    });
  });

  test('client poll registers a player and returns client queue state', async () => {
    const sessionId = bridge.startTestSession();

    const response = await request(app)
      .post('/test-session/poll')
      .send({
        sessionId,
        target: 'client',
        userId: 7,
        playerName: 'Alice',
        hello: { loadstringReady: true },
      })
      .expect(200);

    expect(response.body).toEqual({ command: null, ended: false, sessionMatch: true });
    expect(bridge.getTestSessionStatus()?.clients).toEqual([
      { userId: 7, name: 'Alice', ready: true, loadstringReady: true },
    ]);
  });

  test('log endpoint validates payloads and appends source-tagged output', async () => {
    await request(app).post('/test-session/log').send({}).expect(400, { error: 'sessionId required' });

    const sessionId = bridge.startTestSession();
    await request(app)
      .post('/test-session/log')
      .send({ sessionId, messages: 'not-array' })
      .expect(400, { error: 'messages must be an array' });

    const response = await request(app)
      .post('/test-session/log')
      .send({
        sessionId,
        source: 'client',
        messages: [{ message: 'hi', messageType: 'MessageOutput', timestamp: 1 }],
      })
      .expect(200);

    expect(response.body).toEqual({ accepted: 1, sessionMatch: true });
    expect(bridge.getTestOutput().entries).toEqual([
      {
        seq: 1,
        message: 'hi',
        messageType: 'MessageOutput',
        timestamp: 1,
        source: 'client',
      },
    ]);
  });

  test('eval-result validates identifiers and resolves matching replies', async () => {
    await request(app).post('/test-session/eval-result').send({}).expect(400, {
      error: 'sessionId required',
    });

    const sessionId = bridge.startTestSession();
    await request(app).post('/test-session/eval-result').send({ sessionId }).expect(400, {
      error: 'replyId required',
    });

    const reply = bridge.registerEvalReply('reply', 'server', 1000);
    const response = await request(app)
      .post('/test-session/eval-result')
      .send({ sessionId, replyId: 'reply', ok: true, values: ['ok'], durationMs: 3 })
      .expect(200);

    expect(response.body).toEqual({ matched: true });
    await expect(reply).resolves.toEqual({ ok: true, values: ['ok'], durationMs: 3 });
  });

  test('ended endpoint validates sessionId and marks sessions ended idempotently', async () => {
    await request(app).post('/test-session/ended').send({}).expect(400, { error: 'sessionId required' });

    const sessionId = bridge.startTestSession();
    const first = await request(app)
      .post('/test-session/ended')
      .send({ sessionId, reason: 'done', value: { ok: true } })
      .expect(200);
    const second = await request(app)
      .post('/test-session/ended')
      .send({ sessionId, reason: 'late' })
      .expect(200);

    expect(first.body).toEqual({ ok: true });
    expect(second.body).toEqual({ ok: true });
    expect(bridge.testSession).toMatchObject({
      status: 'ended',
      endReason: 'done',
      endValue: { ok: true },
    });
  });
});
