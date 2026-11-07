import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { mkdtemp, readFile, readdir, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';
import { downloadWindowsUpdate, findWindowsUpdate } from '../patch/update-release.mjs';

const filename = 'CodexUsageBar-Windows-x64-Setup.exe';
const downloadRoot = 'https://github.com/1078302479/codex-usage-bar/releases/download/';
const bytes = Buffer.from('sample installer bytes');
const sha256 = createHash('sha256').update(bytes).digest('hex');
const metadata = { version: '0.1.11', sha256, size: bytes.length };
const release = (version, asset = {}) => ({
  tag_name: 'windows-v' + version,
  draft: false,
  prerelease: true,
  assets: [{
    name: filename, state: 'uploaded', size: bytes.length, digest: 'sha256:' + sha256,
    browser_download_url: downloadRoot + 'windows-v' + version + '/' + filename, ...asset,
  }],
});

test('finds the highest usable Windows release across pages and accepts preview builds', async () => {
  const firstPage = [release('0.1.9'), { ...release('9.0.0'), tag_name: 'v9.0.0' },
    { ...release('1.0.0'), draft: true }, release('1.1.0', { digest: null }),
    release('1.2.0', { browser_download_url: 'https://example.com/setup.exe' }), ...Array(95).fill({})];
  const pages = [];
  const request = async url => {
    pages.push(new URL(url).searchParams.get('page'));
    return Response.json(pages.length === 1 ? firstPage : [release('0.1.11'), release('0.1.10')]);
  };
  assert.deepEqual(await findWindowsUpdate('0.1.8', request), metadata);
  assert.deepEqual(pages, ['1', '2']);
  assert.equal(await findWindowsUpdate('0.1.11', async () => Response.json([release('0.1.11')])), null);
  await assert.rejects(findWindowsUpdate('0.1.8', async () => new Response(null, { status: 503 })), /check failed/);
});

test('only a complete verified installer is exposed, and external redirects are refused', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'usagebar-update-test-'));
  try {
    const installer = join(dir, filename);
    const requests = [];
    const githubAsset = 'https://release-assets.githubusercontent.com/sample-asset';
    await downloadWindowsUpdate(metadata, installer, async (url, { redirect }) => {
      assert.equal(redirect, 'manual');
      requests.push(url);
      return requests.length === 1 ? Response.redirect(githubAsset, 302) : new Response(bytes);
    });
    assert.deepEqual(requests, [downloadRoot + 'windows-v0.1.11/' + filename, githubAsset]);
    assert.deepEqual(await readFile(installer), bytes);
    await rm(installer);

    await assert.rejects(downloadWindowsUpdate(metadata, installer,
      async () => new Response(Buffer.alloc(bytes.length))), /checksum mismatch/);
    await assert.rejects(downloadWindowsUpdate(metadata, installer,
      async () => new Response(Buffer.alloc(bytes.length + 1))), /size mismatch/);
    await assert.rejects(downloadWindowsUpdate(metadata, installer, async url => {
      assert.ok(url.startsWith(downloadRoot));
      return Response.redirect('https://example.com/setup.exe', 302);
    }), /Unexpected installer download host/);
    assert.deepEqual(await readdir(dir), []);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});
