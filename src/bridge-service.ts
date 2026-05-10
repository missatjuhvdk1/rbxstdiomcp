import { v4 as uuidv4 } from 'uuid';

interface PendingRequest {
  id: string;
  endpoint: string;
  data: any;
  timestamp: number;
  resolve: (value: any) => void;
  reject: (error: any) => void;
}

// ============================================================================
// Test session — separate channel for the in-Studio companion scripts that
// run inside the test's Server and Client DataModels.
//
// Why this exists: StudioTestService:EndTest() can ONLY be called from the
// running test's Server DataModel, not from the plugin (which lives in the
// Edit DataModel). To stop a test cleanly we inject a tiny companion Script
// before ExecutePlayModeAsync; the companion polls /test-session/poll for
// commands and pipes LogService.MessageOut to /test-session/log.
//
// run_live_lua extension: companions also accept "eval" commands carrying
// a replyId + code + timeoutMs. The companion compiles via loadstring,
// runs under xpcall on a spawned task, captures LogService output during
// the call, and POSTs the result back to /test-session/eval-result. This
// gives the AI a way to fire RemoteEvents, query Players, mutate the test
// world, etc. — things the Edit-side execute_lua cannot reach because it
// runs in a different DataModel.
//
// We track companions in two pools:
//   - 1 server companion (in ServerScriptService)
//   - N client companions (one per Player; injected via StarterPlayerScripts
//     so each player gets their own LocalScript clone)
// ============================================================================

export interface TestSessionLogEntry {
  seq: number;
  message: string;
  messageType: string;
  timestamp: number;
  source: 'server' | 'plugin' | 'client';
}

export interface TestSessionCommand {
  cmd: 'end' | 'eval';
  args?: any;
}

export interface EvalReplyPayload {
  ok: boolean;
  // Lua multi-return is packed as an array of serialized values. A single
  // return becomes an array of length 1; nil/no-return is an empty array.
  values?: any[];
  errorType?:
    | 'compile_error'
    | 'runtime_error'
    | 'timeout'
    | 'loadstring_disabled'
    | 'companion_error';
  error?: string;
  traceback?: string;
  logs?: Array<{ message: string; messageType: string; timestamp: number }>;
  durationMs?: number;
}

export interface TestClientState {
  userId: number;
  name: string;
  loadstringReady: boolean;
  ready: boolean; // received at least one poll with a hello
  registeredAt: number;
  lastPolledAt: number;
  pendingCommands: TestSessionCommand[];
}

interface PendingEvalReply {
  resolve: (payload: EvalReplyPayload) => void;
  timeoutHandle: ReturnType<typeof setTimeout>;
  target: 'server' | { client: number };
  claimed: boolean; // companion has popped the command but not yet replied
  startedAt: number;
}

export interface TestSessionState {
  sessionId: string;
  status: 'active' | 'ended';
  startedAt: number;
  endedAt: number | null;
  endReason: string | null;
  endValue: any;

  // Server companion handshake state
  serverReady: boolean;
  serverLoadstringReady: boolean;
  serverLastPolledAt: number;

  // Client companions, keyed by userId. Populated as clients poll in.
  clients: Map<number, TestClientState>;

  // Per-target command queues. Server queue handles both 'end' and 'eval'
  // commands. Client queues are per-user and hold 'eval' only — clients
  // don't need an explicit 'end' command, the bridge's `ended` flag in
  // the poll response is sufficient for them to self-terminate.
  pendingCommandsServer: TestSessionCommand[];

  // Output stream (server + client logs both flow here, tagged by source).
  outputBuffer: TestSessionLogEntry[];
  outputSeq: number;

  // Eval reply waiters, keyed by replyId.
  evalReplies: Map<string, PendingEvalReply>;

  endWaiters: Array<(ended: boolean) => void>;
}

const MAX_OUTPUT_BUFFER = 5000;

// How long after the user-supplied timeoutMs we keep waiting before giving
// up entirely. Accounts for HTTP RTT + companion poll latency.
const EVAL_GRACE_MS = 1500;
// Hard cap on how long a single eval can take before we abandon the reply
// slot regardless of what the companion claims.
const EVAL_HARD_CAP_MS = 60_000;

export class BridgeService {
  private pendingRequests: Map<string, PendingRequest> = new Map();
  private requestTimeout = 30000; // 30 seconds timeout

  // Active test session, or null when no test is running and no recent
  // session is available for output queries. Cleared on the next
  // startTestSession call.
  testSession: TestSessionState | null = null;

  async sendRequest(endpoint: string, data: any): Promise<any> {
    const requestId = uuidv4();

    return new Promise((resolve, reject) => {
      const request: PendingRequest = {
        id: requestId,
        endpoint,
        data,
        timestamp: Date.now(),
        resolve,
        reject
      };

      this.pendingRequests.set(requestId, request);

      // Set timeout
      setTimeout(() => {
        if (this.pendingRequests.has(requestId)) {
          this.pendingRequests.delete(requestId);
          reject(new Error('Request timeout'));
        }
      }, this.requestTimeout);
    });
  }

  getPendingRequest(): { requestId: string; request: { endpoint: string; data: any } } | null {
    // Get oldest pending request
    let oldestRequest: PendingRequest | null = null;

    for (const request of this.pendingRequests.values()) {
      if (!oldestRequest || request.timestamp < oldestRequest.timestamp) {
        oldestRequest = request;
      }
    }

    if (oldestRequest) {
      return {
        requestId: oldestRequest.id,
        request: {
          endpoint: oldestRequest.endpoint,
          data: oldestRequest.data
        }
      };
    }

    return null;
  }

  resolveRequest(requestId: string, response: any) {
    const request = this.pendingRequests.get(requestId);
    if (request) {
      this.pendingRequests.delete(requestId);
      request.resolve(response);
    }
  }

  rejectRequest(requestId: string, error: any) {
    const request = this.pendingRequests.get(requestId);
    if (request) {
      this.pendingRequests.delete(requestId);
      request.reject(error);
    }
  }

  // Clean up old requests
  cleanupOldRequests() {
    const now = Date.now();
    for (const [id, request] of this.pendingRequests.entries()) {
      if (now - request.timestamp > this.requestTimeout) {
        this.pendingRequests.delete(id);
        request.reject(new Error('Request timeout'));
      }
    }
  }

  // Force cleanup all pending requests (used on disconnect)
  clearAllPendingRequests() {
    for (const [, request] of this.pendingRequests.entries()) {
      request.reject(new Error('Connection closed'));
    }
    this.pendingRequests.clear();
  }

  // ==========================================================================
  // Test session API
  // ==========================================================================

  /**
   * Begin a new test session. If one was already active, mark it ended
   * (with reason "superseded") so output queries don't bleed across runs.
   * Returns the new sessionId which must be passed to the plugin so it can
   * embed it in the injected companion script.
   */
  startTestSession(): string {
    // If a previous session was still 'active', mark it superseded — the
    // plugin will stop it before starting the new one but we don't want
    // its waiters hanging.
    if (this.testSession && this.testSession.status === 'active') {
      this.markTestSessionEnded('superseded');
    }

    const sessionId = uuidv4();
    this.testSession = {
      sessionId,
      status: 'active',
      startedAt: Date.now(),
      endedAt: null,
      endReason: null,
      endValue: null,
      serverReady: false,
      serverLoadstringReady: false,
      serverLastPolledAt: 0,
      clients: new Map(),
      pendingCommandsServer: [],
      outputBuffer: [],
      outputSeq: 0,
      evalReplies: new Map(),
      endWaiters: [],
    };
    return sessionId;
  }

  /**
   * Internal: transition the current session to 'ended' and wake waiters.
   * Idempotent — calling on an already-ended session is a no-op.
   */
  private markTestSessionEnded(reason: string, value?: any) {
    const session = this.testSession;
    if (!session || session.status === 'ended') return;
    session.status = 'ended';
    session.endedAt = Date.now();
    session.endReason = reason;
    session.endValue = value ?? null;

    // Reject any in-flight eval waiters — the test died before the
    // companion could reply. Clear their watchdog timers too.
    for (const [replyId, pending] of session.evalReplies.entries()) {
      clearTimeout(pending.timeoutHandle);
      pending.resolve({
        ok: false,
        errorType: 'companion_error',
        error: `Play test ended (${reason}) before eval reply could be delivered.`,
      });
      session.evalReplies.delete(replyId);
    }

    const waiters = session.endWaiters.splice(0);
    for (const w of waiters) {
      try { w(true); } catch { /* swallow */ }
    }
  }

  /**
   * Called by both the companion (when it processes an "end" command) and
   * the plugin (when ExecutePlayModeAsync returns naturally). Idempotent
   * w.r.t. the same session — first caller wins.
   */
  endTestSession(sessionId: string, reason: string, value?: any): boolean {
    const session = this.testSession;
    if (!session || session.sessionId !== sessionId) return false;
    if (session.status === 'ended') return true;
    this.markTestSessionEnded(reason, value);
    return true;
  }

  /**
   * Queue a command for either the server companion or a specific client
   * companion. Defaults to the server queue (preserves prior call-site
   * behavior for the existing 'end' command path).
   *
   * Returns false if the targeted queue doesn't exist (e.g. no such
   * client), the session is null/ended, etc.
   */
  enqueueTestCommand(
    cmd: TestSessionCommand,
    target: 'server' | { client: number } = 'server'
  ): boolean {
    const session = this.testSession;
    if (!session || session.status !== 'active') return false;
    if (target === 'server') {
      session.pendingCommandsServer.push(cmd);
      return true;
    }
    const client = session.clients.get(target.client);
    if (!client) return false;
    client.pendingCommands.push(cmd);
    return true;
  }

  /**
   * Companion poll: returns the oldest pending command for this target,
   * or null if none. If the session was already marked ended, signals
   * that so the companion stops polling.
   *
   * The hello payload (sent by a companion on its first poll) registers
   * its readiness state. Server companion sends `{ loadstringReady }`;
   * client companions add `{ userId, name, loadstringReady }`.
   */
  popTestCommand(
    sessionId: string,
    target: 'server' | 'client' = 'server',
    options: {
      userId?: number;
      playerName?: string;
      hello?: { loadstringReady?: boolean };
    } = {}
  ): {
    command: TestSessionCommand | null;
    ended: boolean;
    sessionMatch: boolean;
  } {
    const session = this.testSession;
    if (!session || session.sessionId !== sessionId) {
      return { command: null, ended: true, sessionMatch: false };
    }

    // Update handshake/poll-time bookkeeping regardless of status, so
    // late polls after end still update lastPolledAt for diagnostics.
    if (target === 'server') {
      if (!session.serverReady) {
        session.serverReady = true;
        session.serverLoadstringReady = !!options.hello?.loadstringReady;
      } else if (options.hello && typeof options.hello.loadstringReady === 'boolean') {
        // Allow re-handshake (e.g. companion re-checked).
        session.serverLoadstringReady = options.hello.loadstringReady;
      }
      session.serverLastPolledAt = Date.now();
    } else {
      // Client target: require userId for routing.
      const userId = typeof options.userId === 'number' ? options.userId : null;
      if (userId === null) {
        return { command: null, ended: session.status === 'ended', sessionMatch: true };
      }
      let client = session.clients.get(userId);
      if (!client) {
        client = {
          userId,
          name: options.playerName || `User_${userId}`,
          loadstringReady: !!options.hello?.loadstringReady,
          ready: true,
          registeredAt: Date.now(),
          lastPolledAt: Date.now(),
          pendingCommands: [],
        };
        session.clients.set(userId, client);
      } else {
        client.lastPolledAt = Date.now();
        if (options.playerName) client.name = options.playerName;
        if (options.hello && typeof options.hello.loadstringReady === 'boolean') {
          client.loadstringReady = options.hello.loadstringReady;
        }
      }
    }

    if (session.status === 'ended') {
      return { command: null, ended: true, sessionMatch: true };
    }

    let command: TestSessionCommand | null = null;
    if (target === 'server') {
      command = session.pendingCommandsServer.shift() ?? null;
    } else {
      const userId = typeof options.userId === 'number' ? options.userId : null;
      if (userId !== null) {
        const client = session.clients.get(userId);
        command = client?.pendingCommands.shift() ?? null;
      }
    }

    // If we just popped an eval, mark its reply slot as claimed so the
    // watchdog knows the companion at least picked it up.
    if (command && command.cmd === 'eval' && command.args && typeof command.args.replyId === 'string') {
      const slot = session.evalReplies.get(command.args.replyId);
      if (slot) slot.claimed = true;
    }

    return { command, ended: false, sessionMatch: true };
  }

  /**
   * Append a batch of log entries from a companion. Drops oldest entries
   * if the buffer would exceed MAX_OUTPUT_BUFFER. Each entry gets a
   * monotonically increasing seq for "since" cursor support.
   */
  appendTestOutput(
    sessionId: string,
    messages: Array<{ message: string; messageType: string; timestamp: number }>,
    source: 'server' | 'plugin' | 'client' = 'server'
  ): { accepted: number; sessionMatch: boolean } {
    const session = this.testSession;
    if (!session || session.sessionId !== sessionId) {
      return { accepted: 0, sessionMatch: false };
    }
    let accepted = 0;
    for (const m of messages) {
      session.outputSeq += 1;
      session.outputBuffer.push({
        seq: session.outputSeq,
        message: String(m.message ?? ''),
        messageType: String(m.messageType ?? 'MessageOutput'),
        timestamp: typeof m.timestamp === 'number' ? m.timestamp : Date.now() / 1000,
        source,
      });
      accepted += 1;
    }
    // Trim from the front if oversized
    if (session.outputBuffer.length > MAX_OUTPUT_BUFFER) {
      session.outputBuffer.splice(0, session.outputBuffer.length - MAX_OUTPUT_BUFFER);
    }
    return { accepted, sessionMatch: true };
  }

  /**
   * Read buffered output for the current (or last) session. Filters by:
   *  - sinceSeq: only entries with seq > sinceSeq
   *  - messageTypes: only matching MessageType names
   *  - limit: cap on number of entries returned
   */
  getTestOutput(opts: {
    sinceSeq?: number;
    messageTypes?: string[];
    limit?: number;
  } = {}): {
    sessionId: string | null;
    status: 'active' | 'ended' | 'none';
    entries: TestSessionLogEntry[];
    nextSinceSeq: number;
    endReason: string | null;
    endedAt: number | null;
  } {
    const session = this.testSession;
    if (!session) {
      return {
        sessionId: null,
        status: 'none',
        entries: [],
        nextSinceSeq: 0,
        endReason: null,
        endedAt: null,
      };
    }
    const sinceSeq = opts.sinceSeq ?? 0;
    const limit = Math.max(1, Math.min(opts.limit ?? 500, MAX_OUTPUT_BUFFER));
    const types = opts.messageTypes && opts.messageTypes.length > 0 ? new Set(opts.messageTypes) : null;

    const filtered: TestSessionLogEntry[] = [];
    for (const e of session.outputBuffer) {
      if (e.seq <= sinceSeq) continue;
      if (types && !types.has(e.messageType)) continue;
      filtered.push(e);
      if (filtered.length >= limit) break;
    }
    const nextSinceSeq = filtered.length > 0 ? filtered[filtered.length - 1].seq : sinceSeq;
    return {
      sessionId: session.sessionId,
      status: session.status,
      entries: filtered,
      nextSinceSeq,
      endReason: session.endReason,
      endedAt: session.endedAt,
    };
  }

  /**
   * Wait until the current session is marked ended, up to timeoutMs.
   * Resolves true if it ended in time, false on timeout. If there's no
   * active session, resolves true immediately.
   */
  waitForTestEnd(timeoutMs: number): Promise<boolean> {
    const session = this.testSession;
    if (!session || session.status === 'ended') return Promise.resolve(true);
    return new Promise<boolean>((resolve) => {
      let done = false;
      const finish = (ok: boolean) => {
        if (done) return;
        done = true;
        resolve(ok);
      };
      session.endWaiters.push(() => finish(true));
      setTimeout(() => finish(false), timeoutMs);
    });
  }

  // ==========================================================================
  // run_live_lua eval reply tracking
  // ==========================================================================

  /**
   * Snapshot of companion readiness for diagnostic / pre-flight callers.
   * Returns null if no session is tracked.
   */
  getTestSessionStatus():
    | null
    | {
        sessionId: string;
        status: 'active' | 'ended';
        serverReady: boolean;
        serverLoadstringReady: boolean;
        clients: Array<{
          userId: number;
          name: string;
          ready: boolean;
          loadstringReady: boolean;
        }>;
      } {
    const session = this.testSession;
    if (!session) return null;
    return {
      sessionId: session.sessionId,
      status: session.status,
      serverReady: session.serverReady,
      serverLoadstringReady: session.serverLoadstringReady,
      clients: [...session.clients.values()].map((c) => ({
        userId: c.userId,
        name: c.name,
        ready: c.ready,
        loadstringReady: c.loadstringReady,
      })),
    };
  }

  /**
   * Register a pending eval and return a Promise that resolves with the
   * companion's reply (or a synthetic timeout reply).
   *
   * The watchdog fires at `timeoutMs + EVAL_GRACE_MS`, capped at
   * EVAL_HARD_CAP_MS. If the command was never claimed by a companion,
   * we surface `companion_error` (companion unreachable) rather than
   * `timeout` so the AI can distinguish "infinite loop in user code"
   * from "no companion picked up the work".
   */
  registerEvalReply(
    replyId: string,
    target: 'server' | { client: number },
    timeoutMs: number
  ): Promise<EvalReplyPayload> {
    const session = this.testSession;
    if (!session || session.status !== 'active') {
      return Promise.resolve({
        ok: false,
        errorType: 'companion_error',
        error: 'No active play test session.',
      });
    }
    const watchdogMs = Math.min(EVAL_HARD_CAP_MS, Math.max(1000, timeoutMs + EVAL_GRACE_MS));
    return new Promise<EvalReplyPayload>((resolve) => {
      let done = false;
      const finish = (payload: EvalReplyPayload) => {
        if (done) return;
        done = true;
        const cur = this.testSession;
        if (cur && cur.sessionId === session.sessionId) {
          const slot = cur.evalReplies.get(replyId);
          if (slot) {
            clearTimeout(slot.timeoutHandle);
            cur.evalReplies.delete(replyId);
          }
        }
        resolve(payload);
      };
      const timeoutHandle = setTimeout(() => {
        const cur = this.testSession;
        if (!cur || cur.sessionId !== session.sessionId) {
          finish({
            ok: false,
            errorType: 'companion_error',
            error: 'Play test session changed while waiting for eval reply.',
          });
          return;
        }
        const slot = cur.evalReplies.get(replyId);
        if (!slot) {
          // Reply already arrived and removed the slot — race with timeout.
          finish({
            ok: false,
            errorType: 'companion_error',
            error: 'Eval reply slot vanished before resolution (internal race).',
          });
          return;
        }
        if (!slot.claimed) {
          finish({
            ok: false,
            errorType: 'companion_error',
            error:
              'Companion never picked up the eval command within the watchdog window. The injected companion script may have died, or its HTTP polling is blocked.',
          });
        } else {
          finish({
            ok: false,
            errorType: 'timeout',
            error: `Eval did not complete within ${timeoutMs}ms (watchdog fired after ${watchdogMs}ms grace).`,
          });
        }
      }, watchdogMs);

      session.evalReplies.set(replyId, {
        resolve: finish,
        timeoutHandle,
        target,
        claimed: false,
        startedAt: Date.now(),
      });
    });
  }

  /**
   * Companion-side eval result delivery. Idempotent w.r.t. the same
   * replyId. Returns true if the reply was matched and dispatched.
   */
  resolveEvalReply(sessionId: string, replyId: string, payload: EvalReplyPayload): boolean {
    const session = this.testSession;
    if (!session || session.sessionId !== sessionId) return false;
    const slot = session.evalReplies.get(replyId);
    if (!slot) return false;
    slot.resolve(payload);
    return true;
  }
}
