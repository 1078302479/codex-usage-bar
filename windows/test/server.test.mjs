import test from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { once } from 'node:events';

test('demo server serves complete UI, labels sample data, and rejects cross-origin access', async () => {
  const child = spawn(process.execPath, ['server.mjs', '--demo'], {
    cwd: new URL('..', import.meta.url), stdio: ['ignore', 'pipe', 'pipe'], windowsHide: true,
  });
  try {
    const address = await new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error('server-start-timeout')), 5000);
      let output = '';
      child.stdout.on('data', bytes => {
        output += bytes;
        const url = output.match(/http:\/\/127\.0\.0\.1:\d+/)?.[0];
        if (url) { clearTimeout(timer); resolve(url); }
      });
      child.on('error', error => { clearTimeout(timer); reject(error); });
    });
    for (const path of ['/', '/widget.mjs', '/quota.mjs', '/preview.mjs']) {
      const response = await fetch(address + path);
      assert.equal(response.status, 200, path);
      assert.ok((await response.text()).length > 50);
    }
    const data = await (await fetch(address + '/api/quota')).json();
    assert.equal(data.demo, true);
    assert.equal(data.snapshot.primary.remaining, 82);
    assert.equal(data.snapshot.secondary.remaining, 64);
    assert.equal((await fetch(address + '/api/quota', { method: 'POST' })).status, 403);
    assert.equal((await fetch(address + '/api/quota', { headers: { 'Sec-Fetch-Site': 'cross-site' } })).status, 403);
    assert.equal((await fetch(address + '/not-found')).status, 404);
  } finally {
    const exit = once(child, 'exit');
    child.kill();
    await exit;
  }
});
