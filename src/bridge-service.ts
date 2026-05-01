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
// Test session — separate channel for the in-Studio companion script that
// runs inside the test's Server DataModel.
//
// Why this exists: StudioTestService:EndTest() can ONLY be called from the
// running test's Server DataModel, not from the plugin (which lives in the
// Edit DataModel). To stop a test cleanly we inject a tiny companion Script
// before ExecutePlayModeAsync; the companion polls /test-session/poll for
// commands and pipes LogService.MessageOut to /test-session/log.
// ============================================================================

export interface TestSessionLogEntry {
  seq: number;
  message: string;
  messageType: string;
  timestamp: number;
  source: 'server' | 'plugin';
}

export interface TestSessionCommand {
  cmd: 'end';
  args?: any;
}

export interface TestSessionState {
  sessionId: string;
  status: 'active' | 'ended';
  startedAt: number;
  endedAt: number | null;
  endReason: string | null;
  endValue: any;
  pendingCommands: TestSessionCommand[];
  outputBuffer: TestSessionLogEntry[];
  outputSeq: number;
  endWaiters: Array<(ended: boolean) => void>;
}

const MAX_OUTPUT_BUFFER = 5000;

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
      pendingCommands: [],
      outputBuffer: [],
      outputSeq: 0,
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
   * Queue a command for the companion to pick up on its next poll.
   * Currently the only command is 'end'.
   */
  enqueueTestCommand(cmd: TestSessionCommand): boolean {
    const session = this.testSession;
    if (!session || session.status !== 'active') return false;
    session.pendingCommands.push(cmd);
    return true;
  }

  /**
   * Companion poll: returns the oldest pending command, or null if none.
   * If the session was already marked ended, signals that so the companion
   * stops polling.
   */
  popTestCommand(sessionId: string): { command: TestSessionCommand | null; ended: boolean; sessionMatch: boolean } {
    const session = this.testSession;
    if (!session || session.sessionId !== sessionId) {
      return { command: null, ended: true, sessionMatch: false };
    }
    if (session.status === 'ended') {
      return { command: null, ended: true, sessionMatch: true };
    }
    const command = session.pendingCommands.shift() ?? null;
    return { command, ended: false, sessionMatch: true };
  }

  /**
   * Append a batch of log entries from the companion. Drops oldest entries
   * if the buffer would exceed MAX_OUTPUT_BUFFER. Each entry gets a
   * monotonically increasing seq for "since" cursor support.
   */
  appendTestOutput(
    sessionId: string,
    messages: Array<{ message: string; messageType: string; timestamp: number }>,
    source: 'server' | 'plugin' = 'server'
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
}
