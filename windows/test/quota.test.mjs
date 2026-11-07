import test from 'node:test';
import assert from 'node:assert/strict';
import { PassThrough, Writable } from 'node:stream';
import { EventEmitter } from 'node:events';
import { quotaWindow, normalizeQuota, displayWindow } from '../quota.mjs';
import { QuotaClient } from '../client.mjs';

test('missing, malformed and out-of-range percentages are unknown, zero is valid', () => {
  for (const usedPercent of [null, undefined, NaN, Infinity, -1, 101, '18']) {
    assert.equal(quotaWindow({ usedPercent }, '短期').remaining, null);
  }
  assert.equal(quotaWindow({ usedPercent: 100 }, '短期').remaining, 0);
  assert.equal(quotaWindow({ usedPercent: 0 }, '短期').remaining, 100);
});
test('prefer Codex bucket, never substitute another product', () => {
  const bucket = { primary: { usedPercent: 18 }, secondary: { usedPercent: 36 } };
  const snapshot = normalizeQuota({ rateLimitsByLimitId: { codex: bucket, other: {} } });
  assert.equal(snapshot.primary.remaining, 82);
  assert.equal(snapshot.secondary.remaining, 64);
  assert.throws(() => normalizeQuota({ rateLimitsByLimitId: { other: bucket } }), /no-quota/);
});
test('real window lengths drive labels, reset boundaries never refill quota', () => {
  const now = 1_800_000_000_000;
  const snapshot = normalizeQuota({ rateLimits: {
    primary: { usedPercent: 45, windowDurationMins: 120, resetsAt: now / 1000 + 60 },
  } }, now);
  assert.equal(snapshot.primary.label, '2h');
  assert.equal(displayWindow(snapshot.primary, snapshot, now).text, '55%');
  assert.equal(displayWindow(snapshot.primary, snapshot, now + 60_000).text, '--');
});
test('expired snapshots are marked, unknown reset dates stay unknown', () => {
  const snapshot = normalizeQuota({ rateLimits: { primary: { usedPercent: 94 } } }, 1000);
  assert.equal(displayWindow(snapshot.primary, snapshot, 400000).text, '6%*');
  assert.equal(displayWindow(snapshot.primary, snapshot, 1000).tone, 'warning');
  assert.equal(snapshot.primary.resetsAt, null);
});

function fixture(accountChange = false) {
  const child = new EventEmitter();
  child.stdout = new PassThrough(); child.stderr = new PassThrough();
  let reads = 0;
  child.stdin = new Writable({ write(bytes, encoding, done) {
    const request = JSON.parse(bytes.toString());
    if (request.id) {
      let result = {};
      if (request.method === 'account/read') result = { account: {
        type: 'chatgpt', email: accountChange && reads++ ? 'b@example.test' : 'a@example.test',
      } };
      if (request.method === 'account/rateLimits/read') result = { rateLimits: { primary: { usedPercent: 18 } } };
      queueMicrotask(() => child.stdout.write(`${JSON.stringify({ id: request.id, result })}\n`));
    }
    done();
  } });
  child.kill = () => { child.killed = true; child.stdout.end(); child.emit('exit', 0); };
  return child;
}
test('stdio reader validates identity and strips raw account identifiers', async () => {
  const child = fixture();
  const client = new QuotaClient({ spawnProcess: () => child });
  try {
    const snapshot = await client.fetch();
    assert.equal(snapshot.primary.remaining, 82);
    assert.equal(JSON.stringify(snapshot).includes('example.test'), false);
    await assert.rejects(client.rpc('account/login/start'), /method-not-allowed/);
  } finally { client.stop(); }
  assert.equal(child.killed, true);
});
test('account change during request discards result', async () => {
  const client = new QuotaClient({ spawnProcess: () => fixture(true) });
  try { await assert.rejects(client.fetch(), /account-changed/); }
  finally { client.stop(); }
});
test('RPC timeout and disconnect reject pending requests', async () => {
  const child = fixture();
  const client = new QuotaClient({ spawnProcess: () => child, timeout: 20 });
  await client.start();
  child.stdin._write = (chunk, encoding, done) => done();
  await assert.rejects(client.rpc('account/read'), /timeout/);
  const pending = client.rpc('account/read');
  client.stop();
  await assert.rejects(pending, /disconnected/);
});
