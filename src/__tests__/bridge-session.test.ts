import { BridgeService } from '../bridge-service';

describe('BridgeService test sessions', () => {
  afterEach(() => {
    jest.useRealTimers();
  });

  test('startTestSession initializes state and supersedes an active session', async () => {
    jest.useFakeTimers();
    const bridge = new BridgeService();
    const first = bridge.startTestSession();
    const waiter = bridge.waitForTestEnd(1000);

    const second = bridge.startTestSession();

    await expect(waiter).resolves.toBe(true);
    expect(second).not.toBe(first);
    expect(bridge.testSession).toMatchObject({
      sessionId: second,
      status: 'active',
      serverReady: false,
      serverLoadstringReady: false,
    });
  });

  test('server companion polling records readiness and pops queued commands', () => {
    const bridge = new BridgeService();
    const sessionId = bridge.startTestSession();

    expect(bridge.enqueueTestCommand({ cmd: 'end', args: 'stop' })).toBe(true);

    const firstPoll = bridge.popTestCommand(sessionId, 'server', {
      hello: { loadstringReady: true },
    });
    expect(firstPoll).toEqual({
      command: { cmd: 'end', args: 'stop' },
      ended: false,
      sessionMatch: true,
    });
    expect(bridge.getTestSessionStatus()).toMatchObject({
      sessionId,
      serverReady: true,
      serverLoadstringReady: true,
    });

    expect(bridge.popTestCommand(sessionId, 'server').command).toBeNull();
  });

  test('client companion polling registers, updates, and receives per-client commands', () => {
    const bridge = new BridgeService();
    const sessionId = bridge.startTestSession();

    const firstPoll = bridge.popTestCommand(sessionId, 'client', {
      userId: 42,
      playerName: 'Alice',
      hello: { loadstringReady: true },
    });
    expect(firstPoll).toMatchObject({ command: null, ended: false, sessionMatch: true });
    expect(bridge.getTestSessionStatus()?.clients).toEqual([
      { userId: 42, name: 'Alice', ready: true, loadstringReady: true },
    ]);

    expect(bridge.enqueueTestCommand({ cmd: 'eval', args: { replyId: 'client-reply' } }, { client: 42 })).toBe(true);
    const secondPoll = bridge.popTestCommand(sessionId, 'client', {
      userId: 42,
      playerName: 'AliceRenamed',
      hello: { loadstringReady: false },
    });

    expect(secondPoll.command).toEqual({ cmd: 'eval', args: { replyId: 'client-reply' } });
    expect(bridge.getTestSessionStatus()?.clients).toEqual([
      { userId: 42, name: 'AliceRenamed', ready: true, loadstringReady: false },
    ]);
    expect(bridge.enqueueTestCommand({ cmd: 'eval' }, { client: 404 })).toBe(false);
  });

  test('polling with the wrong or missing session returns non-matching ended state', () => {
    const bridge = new BridgeService();

    expect(bridge.popTestCommand('missing')).toEqual({
      command: null,
      ended: true,
      sessionMatch: false,
    });

    const sessionId = bridge.startTestSession();
    expect(bridge.popTestCommand(sessionId, 'client')).toEqual({
      command: null,
      ended: false,
      sessionMatch: true,
    });
  });

  test('appendTestOutput filters, limits, cursors, and trims the ring buffer', () => {
    const bridge = new BridgeService();
    const sessionId = bridge.startTestSession();

    expect(
      bridge.appendTestOutput('wrong', [{ message: 'ignored', messageType: 'MessageOutput', timestamp: 1 }]),
    ).toEqual({ accepted: 0, sessionMatch: false });

    bridge.appendTestOutput(sessionId, [
      { message: 'one', messageType: 'MessageOutput', timestamp: 1 },
      { message: 'warn', messageType: 'MessageWarning', timestamp: 2 },
      { message: 'two', messageType: 'MessageOutput', timestamp: 3 },
    ]);

    expect(
      bridge.getTestOutput({ sinceSeq: 1, messageTypes: ['MessageOutput'], limit: 1 }),
    ).toMatchObject({
      sessionId,
      status: 'active',
      nextSinceSeq: 3,
      entries: [{ seq: 3, message: 'two' }],
    });

    const many = Array.from({ length: 5005 }, (_, index) => ({
      message: `m${index}`,
      messageType: 'MessageOutput',
      timestamp: index,
    }));
    bridge.appendTestOutput(sessionId, many);
    const capped = bridge.getTestOutput({ limit: 5000 });
    expect(capped.entries).toHaveLength(5000);
    expect(capped.entries[0].seq).toBeGreaterThan(1);
  });

  test('endTestSession is idempotent and wakes waiters', async () => {
    jest.useFakeTimers();
    const bridge = new BridgeService();
    const sessionId = bridge.startTestSession();
    const waiter = bridge.waitForTestEnd(1000);

    expect(bridge.endTestSession('wrong', 'done')).toBe(false);
    expect(bridge.endTestSession(sessionId, 'done', { ok: true })).toBe(true);
    expect(bridge.endTestSession(sessionId, 'late')).toBe(true);

    await expect(waiter).resolves.toBe(true);
    expect(bridge.testSession).toMatchObject({
      status: 'ended',
      endReason: 'done',
      endValue: { ok: true },
    });
  });

  test('waitForTestEnd resolves false on timeout and true without an active session', async () => {
    jest.useFakeTimers();
    const bridge = new BridgeService();

    await expect(bridge.waitForTestEnd(100)).resolves.toBe(true);

    bridge.startTestSession();
    const waiter = bridge.waitForTestEnd(100);
    jest.advanceTimersByTime(100);
    await expect(waiter).resolves.toBe(false);
  });

  test('registerEvalReply resolves delivered replies and rejects stale sessions', async () => {
    const bridge = new BridgeService();

    await expect(bridge.registerEvalReply('none', 'server', 1000)).resolves.toMatchObject({
      ok: false,
      errorType: 'companion_error',
    });

    const sessionId = bridge.startTestSession();
    const reply = bridge.registerEvalReply('reply-1', 'server', 1000);
    expect(bridge.resolveEvalReply('wrong', 'reply-1', { ok: true })).toBe(false);
    expect(bridge.resolveEvalReply(sessionId, 'reply-1', { ok: true, values: ['ok'] })).toBe(true);
    expect(bridge.resolveEvalReply(sessionId, 'reply-1', { ok: true })).toBe(false);

    await expect(reply).resolves.toEqual({ ok: true, values: ['ok'] });
  });

  test('registerEvalReply watchdog distinguishes unclaimed commands from claimed timeouts', async () => {
    jest.useFakeTimers();
    const bridge = new BridgeService();
    const sessionId = bridge.startTestSession();

    const unclaimed = bridge.registerEvalReply('unclaimed', 'server', 1000);
    jest.advanceTimersByTime(2500);
    await expect(unclaimed).resolves.toMatchObject({
      ok: false,
      errorType: 'companion_error',
    });

    const claimed = bridge.registerEvalReply('claimed', 'server', 1000);
    bridge.enqueueTestCommand({ cmd: 'eval', args: { replyId: 'claimed' } });
    bridge.popTestCommand(sessionId, 'server');
    jest.advanceTimersByTime(2500);

    await expect(claimed).resolves.toMatchObject({
      ok: false,
      errorType: 'timeout',
    });
  });

  test('ending a session resolves pending eval replies with companion_error', async () => {
    const bridge = new BridgeService();
    const sessionId = bridge.startTestSession();
    const reply = bridge.registerEvalReply('reply', 'server', 5000);

    bridge.endTestSession(sessionId, 'manual_stop');

    await expect(reply).resolves.toMatchObject({
      ok: false,
      errorType: 'companion_error',
      error: expect.stringContaining('manual_stop'),
    });
  });
});
