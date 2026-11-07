import { createServer } from 'node:http';
import { readFile } from 'node:fs/promises';
import { QuotaClient } from './client.mjs';
import { normalizeQuota } from './quota.mjs';

const demo = process.argv.includes('--demo');
const client = new QuotaClient({ executable: process.env.CODEX_EXECUTABLE || 'codex' });
const files = {
  '/': ['preview.html', 'text/html'],
  '/widget.mjs': ['widget.mjs', 'text/javascript'],
  '/preview.mjs': ['preview.mjs', 'text/javascript'],
  '/quota.mjs': ['quota.mjs', 'text/javascript'],
};
let snapshot = null;
let error = null;
let busy = false;
async function refresh() {
  if (busy || demo) return;
  busy = true;
  try { snapshot = await client.fetch(); error = null; }
  catch (failure) {
    error = ['login-required', 'no-quota', 'account-changed', 'timeout'].includes(failure.message)
      ? failure.message : 'connection-failed';
    // Never retain a previous account's quota after failed authentication/revalidation.
    snapshot = null;
    client.stop();
  } finally { busy = false; }
}
const server = createServer(async (request, response) => {
  if (request.headers.host !== `127.0.0.1:${server.address().port}` || request.method !== 'GET'
      || (request.headers['sec-fetch-site'] && !['none', 'same-origin'].includes(request.headers['sec-fetch-site']))) {
    response.writeHead(403).end(); return;
  }
  response.setHeader('Cache-Control', 'no-store');
  response.setHeader('X-Content-Type-Options', 'nosniff');
  response.setHeader('Content-Security-Policy', "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; connect-src 'self'; frame-ancestors 'none'");
  if (request.url === '/api/quota') {
    const now = Date.now();
    const sample = demo ? normalizeQuota({ rateLimits: {
      primary: { usedPercent: 18, windowDurationMins: 300, resetsAt: now / 1000 + 7920 },
      secondary: { usedPercent: 36, windowDurationMins: 10080, resetsAt: now / 1000 + 300000 },
    } }) : snapshot;
    response.writeHead(200, { 'Content-Type': 'application/json' });
    response.end(JSON.stringify({ snapshot: sample, error, demo, busy })); return;
  }
  const file = files[request.url];
  if (!file) { response.writeHead(404).end(); return; }
  try {
    const content = await readFile(new URL(file[0], import.meta.url));
    response.writeHead(200, { 'Content-Type': `${file[1]}; charset=utf-8` }).end(content);
  } catch { response.writeHead(500).end(); }
});
server.listen(0, '127.0.0.1', () => {
  console.log(`${demo ? 'DEMO — 示例数据' : '本机 Codex 额度'}: http://127.0.0.1:${server.address().port}`);
  void refresh();
});
const timer = setInterval(refresh, 60000);
for (const signal of ['SIGINT', 'SIGTERM']) process.on(signal, () => {
  clearInterval(timer); client.stop(); server.close();
});
