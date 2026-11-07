import { spawn } from 'node:child_process';
import { createInterface } from 'node:readline';
import { normalizeQuota } from './quota.mjs';

export class QuotaClient {
  constructor({ executable = 'codex', spawnProcess = spawn, timeout = 12000 } = {}) {
    this.executable = executable;
    this.spawnProcess = spawnProcess;
    this.timeout = timeout;
    this.pending = new Map();
    this.counter = 0;
  }

  async start() {
    if (this.child) return;
    const child = this.spawnProcess(this.executable,
      ['app-server', '--stdio', '-c', 'analytics.enabled=false'],
      { windowsHide: true, stdio: ['pipe', 'pipe', 'pipe'] });
    this.child = child;
    this.lines = createInterface({ input: child.stdout });
    this.lines.on('line', line => {
      let message;
      try { message = JSON.parse(line); } catch { return; }
      if (message.method === 'account/updated') this.identityEpoch++;
      const pending = this.pending.get(message.id);
      if (!pending) return;
      this.pending.delete(message.id);
      clearTimeout(pending.timer);
      if (message.error) pending.reject(new Error('request-failed'));
      else pending.resolve(message.result);
    });
    // Drain stderr without logging potentially sensitive server messages.
    child.stderr.resume();
    child.stdin.on('error', () => this.disconnect(child));
    child.on('error', () => this.disconnect(child));
    child.on('exit', () => this.disconnect(child));
    this.identityEpoch = 0;
    try {
      await this.rpc('initialize', { clientInfo: {
        name: 'usagebar_windows', title: 'Codex Sidebar Quota', version: '0.1.0',
      } });
      child.stdin.write(`${JSON.stringify({ method: 'initialized', params: {} })}\n`);
    } catch (error) { this.stop(); throw error; }
  }

  disconnect(child) {
    if (this.child !== child) return;
    this.stop();
  }

  rpc(method, params = {}) {
    if (!['initialize', 'account/read', 'account/rateLimits/read'].includes(method)) {
      return Promise.reject(new Error('method-not-allowed'));
    }
    if (!this.child) return Promise.reject(new Error('disconnected'));
    const id = ++this.counter;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error('timeout'));
      }, this.timeout);
      this.pending.set(id, { resolve, reject, timer });
      this.child.stdin.write(`${JSON.stringify({ id, method, params })}\n`);
    });
  }

  async fetch() {
    await this.start();
    const epoch = this.identityEpoch;
    const before = (await this.rpc('account/read', { refreshToken: false }))?.account;
    if (!before || before.type !== 'chatgpt') throw new Error('login-required');
    const response = await this.rpc('account/rateLimits/read');
    const after = (await this.rpc('account/read', { refreshToken: false }))?.account;
    const identity = account => JSON.stringify([account?.type, account?.chatgptAccountId,
      account?.id, account?.email, account?.workspaceId]);
    if (!after || identity(before) !== identity(after) || epoch !== this.identityEpoch) {
      throw new Error('account-changed');
    }
    // No account identifiers, credentials, or raw responses leave this reader.
    return normalizeQuota(response);
  }

  stop() {
    const child = this.child;
    this.child = null;
    this.lines?.close();
    for (const { reject, timer } of this.pending.values()) {
      clearTimeout(timer);
      reject(new Error('disconnected'));
    }
    this.pending.clear();
    if (child && !child.killed) child.kill();
  }
}
