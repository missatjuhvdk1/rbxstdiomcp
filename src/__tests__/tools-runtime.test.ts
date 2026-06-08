import { BridgeService } from '../bridge-service';
import { RobloxStudioTools } from '../tools/index';
import { parseToolText } from './helpers';

function setupWithRealBridge(response: any = { success: true }) {
  const bridge = new BridgeService();
  const sendRequest = jest.spyOn(bridge, 'sendRequest').mockResolvedValue(response);
  const tools = new RobloxStudioTools(bridge);
  return { bridge, sendRequest, tools };
}

describe('play-test runtime tools', () => {
  afterEach(() => {
    jest.useRealTimers();
  });

  test('playSolo starts a bridge session and passes its sessionId to Studio', async () => {
    const { bridge, sendRequest, tools } = setupWithRealBridge({ success: true, mode: 'play' });

    const body = parseToolText(await tools.playSolo());

    expect(body).toMatchObject({
      success: true,
      mode: 'play',
      note: 'Use get_playtest_output to read logs; stop_play to end.',
    });
    expect(body.sessionId).toBe(bridge.testSession?.sessionId);
    expect(sendRequest).toHaveBeenCalledWith('/api/play-solo', { sessionId: body.sessionId });
    expect(bridge.testSession?.status).toBe('active');
  });

  test('playSolo marks the bridge session ended when Studio rejects the start request', async () => {
    const bridge = new BridgeService();
    jest.spyOn(bridge, 'sendRequest').mockRejectedValue(new Error('studio unavailable'));
    const tools = new RobloxStudioTools(bridge);

    await expect(tools.playSolo()).rejects.toThrow('studio unavailable');

    expect(bridge.testSession).toMatchObject({
      status: 'ended',
      endReason: 'plugin_request_failed',
    });
  });

  test('stopPlay is idempotent when no session exists or the session already ended', async () => {
    const { bridge, tools } = setupWithRealBridge();

    expect(parseToolText(await tools.stopPlay())).toMatchObject({
      success: true,
      alreadyEnded: true,
    });

    const sessionId = bridge.startTestSession();
    bridge.endTestSession(sessionId, 'user_stop');

    expect(parseToolText(await tools.stopPlay())).toMatchObject({
      success: true,
      alreadyEnded: true,
      sessionId,
      endReason: 'user_stop',
    });
  });

  test('stopPlay enqueues an end command and reports confirmed completion', async () => {
    jest.useFakeTimers();
    const { bridge, tools } = setupWithRealBridge();
    const sessionId = bridge.startTestSession();

    const stopPromise = tools.stopPlay();
    const poll = bridge.popTestCommand(sessionId, 'server');
    expect(poll.command).toEqual({ cmd: 'end', args: 'MCP_Stop' });
    bridge.endTestSession(sessionId, 'companion_end');

    const body = parseToolText(await stopPromise);

    expect(body).toMatchObject({
      success: true,
      confirmed: true,
      sessionId,
      status: 'ended',
      endReason: 'companion_end',
    });
  });

  test('getPlaytestOutput reads the bridge buffer instead of calling Studio', async () => {
    const { bridge, sendRequest, tools } = setupWithRealBridge();
    const sessionId = bridge.startTestSession();
    bridge.appendTestOutput(sessionId, [{ message: 'hello', messageType: 'MessageOutput', timestamp: 1 }]);

    const body = parseToolText(await tools.getPlaytestOutput(0, 10, ['MessageOutput']));

    expect(body).toMatchObject({
      sessionId,
      status: 'active',
      nextSinceSeq: 1,
      entries: [
        {
          seq: 1,
          message: 'hello',
          messageType: 'MessageOutput',
          source: 'server',
        },
      ],
    });
    expect(sendRequest).not.toHaveBeenCalled();
  });
});

describe('runLiveLua preflight and reply flow', () => {
  test('returns structured failures for missing, ended, or unready sessions', async () => {
    const { bridge, tools } = setupWithRealBridge();

    expect(parseToolText(await tools.runLiveLua('return 1'))).toMatchObject({
      success: false,
      error: 'no_playtest',
    });

    const endedSessionId = bridge.startTestSession();
    bridge.endTestSession(endedSessionId, 'done');
    expect(parseToolText(await tools.runLiveLua('return 1'))).toMatchObject({
      success: false,
      error: 'playtest_ended',
    });

    bridge.startTestSession();
    expect(parseToolText(await tools.runLiveLua('return 1'))).toMatchObject({
      success: false,
      error: 'companion_not_ready',
    });
  });

  test('refuses server execution when the companion reports loadstring disabled', async () => {
    const { bridge, tools } = setupWithRealBridge();
    const sessionId = bridge.startTestSession();
    bridge.popTestCommand(sessionId, 'server', { hello: { loadstringReady: false } });

    expect(parseToolText(await tools.runLiveLua('return 1'))).toMatchObject({
      success: false,
      error: 'loadstring_disabled',
      target: 'server',
    });
  });

  test('executes server-targeted code through an eval command and resolves the reply', async () => {
    const { bridge, tools } = setupWithRealBridge();
    const sessionId = bridge.startTestSession();
    bridge.popTestCommand(sessionId, 'server', { hello: { loadstringReady: true } });

    const resultPromise = tools.runLiveLua('return 2', 'server', undefined, 1500, false);
    const poll = bridge.popTestCommand(sessionId, 'server');

    expect(poll.command?.cmd).toBe('eval');
    expect(poll.command?.args).toMatchObject({
      code: 'return 2',
      timeoutMs: 1500,
      captureLogs: false,
    });

    bridge.resolveEvalReply(sessionId, poll.command!.args.replyId, {
      ok: true,
      values: [2],
      logs: [{ message: 'ran', messageType: 'MessageOutput', timestamp: 1 }],
      durationMs: 12,
    });

    expect(parseToolText(await resultPromise)).toMatchObject({
      success: true,
      target: 'server',
      timeoutMs: 1500,
      durationMs: 12,
      values: [2],
      logs: [{ message: 'ran' }],
    });
  });

  test('maps eval error replies into structured failure output', async () => {
    const { bridge, tools } = setupWithRealBridge();
    const sessionId = bridge.startTestSession();
    bridge.popTestCommand(sessionId, 'server', { hello: { loadstringReady: true } });

    const resultPromise = tools.runLiveLua('error("boom")', 'server');
    const poll = bridge.popTestCommand(sessionId, 'server');
    bridge.resolveEvalReply(sessionId, poll.command!.args.replyId, {
      ok: false,
      errorType: 'runtime_error',
      error: 'boom',
      traceback: 'trace',
    });

    expect(parseToolText(await resultPromise)).toMatchObject({
      success: false,
      error: 'runtime_error',
      message: 'boom',
      traceback: 'trace',
    });
  });

  test('returns structured client-targeting failures before enqueueing eval', async () => {
    const { bridge, tools } = setupWithRealBridge();
    const sessionId = bridge.startTestSession();

    expect(parseToolText(await tools.runLiveLua('return 1', 'client'))).toMatchObject({
      success: false,
      error: 'no_clients_connected',
    });

    bridge.popTestCommand(sessionId, 'client', {
      userId: 1,
      playerName: 'Alice',
      hello: { loadstringReady: true },
    });
    bridge.popTestCommand(sessionId, 'client', {
      userId: 2,
      playerName: 'Bob',
      hello: { loadstringReady: true },
    });

    expect(parseToolText(await tools.runLiveLua('return 1', 'client'))).toMatchObject({
      success: false,
      error: 'multiple_clients',
    });
    expect(parseToolText(await tools.runLiveLua('return 1', 'client', 'Carla'))).toMatchObject({
      success: false,
      error: 'no_such_player',
    });
  });

  test('forwards client-targeted evals through the server companion queue', async () => {
    const { bridge, tools } = setupWithRealBridge();
    const sessionId = bridge.startTestSession();
    bridge.popTestCommand(sessionId, 'client', {
      userId: 1,
      playerName: 'Alice',
      hello: { loadstringReady: true },
    });

    const resultPromise = tools.runLiveLua('return game.Players.LocalPlayer.Name', 'client');
    const poll = bridge.popTestCommand(sessionId, 'server');

    expect(poll.command?.cmd).toBe('eval');
    expect(poll.command?.args.forwardTo).toEqual({ userId: 1, playerName: 'Alice' });

    bridge.resolveEvalReply(sessionId, poll.command!.args.replyId, {
      ok: true,
      values: ['Alice'],
    });

    expect(parseToolText(await resultPromise)).toMatchObject({
      success: true,
      target: 'client',
      player: { name: 'Alice', userId: 1 },
      values: ['Alice'],
    });
  });
});
