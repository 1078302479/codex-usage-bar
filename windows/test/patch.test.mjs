import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, writeFile, readFile, mkdir, rm, realpath, stat } from 'node:fs/promises';
import { join, dirname, basename } from 'node:path';
import { tmpdir } from 'node:os';
import { openAsar, sha256 } from '../patch/asar.mjs';
import { encodeHeader, fileIntegrity, buildArchive, updateEmbeddedHeaderHash } from '../patch/archive-build.mjs';
import { transformSidebar, PROFILE } from '../patch/profile.mjs';
import { nativeWindowData, createSidebarQuota } from '../patch/sidebar-runtime.mjs';
import { activatePatch, checkFiles } from '../patch/manage.mjs';
import { AUTO_ADAPTER } from '../patch/auto-adapter.mjs';

async function temporary(t) {
  const root = await realpath(tmpdir());
  const folder = await mkdtemp(join(root, 'usagebar-patch-test-'));
  t.after(async () => {
    const resolved = await realpath(folder);
    if (dirname(resolved) !== root || !basename(resolved).startsWith('usagebar-patch-test-')) throw new Error('Unsafe cleanup path');
    await rm(resolved, { recursive: true });
  });
  return folder;
}

test('native GUI windows preserve unknown and zero, and handle weekly-only plans', () => {
  const now = Date.now();
  const weekly = { rate_limit: { primary_window: { used_percent: 100, limit_window_seconds: 604800, reset_at: now / 1000 + 60 } } };
  const result = nativeWindowData(weekly, now, now);
  assert.equal(result.windows[0].remaining, null);
  assert.equal(result.windows[1].remaining, 0);
  assert.equal(result.windows[1].label, '周');
  assert.equal(result.windows[1].expired, false);
  assert.equal(nativeWindowData(weekly, now, now + 60001).windows[1].expired, true);
  assert.equal(nativeWindowData(weekly, now, now + 300001).stale, true);
  for (const used_percent of [null, undefined, -1, 101, NaN, '18']) {
    const value = nativeWindowData({ rate_limit: { primary_window: { used_percent } } }, now, now);
    assert.equal(value.windows[0].remaining, null);
  }
  assert.equal(nativeWindowData(null, now, now).available, false);
});

test('quota flyout uses the native menu surface and official theme classes', () => {
  const React = { useState: init => [typeof init === 'function' ? init() : init, () => {}], useRef: current => ({ current }), useEffect() {} };
  const jsx = { jsx: (type, props) => ({ type, props }) };
  const NativeMenu = Symbol('official menu');
  const Component = createSidebarQuota(React, jsx, NativeMenu, nativeWindowData);
  const tree = Component({ usage: { rate_limit: { primary_window: { used_percent: 18, limit_window_seconds: 18000 } } } });
  assert.equal(tree.type, NativeMenu);
  assert.equal(tree.props.surface, 'menu');
  assert.equal(tree.props.contentWidth, 'menuReadout');
  assert.equal(tree.props.openOnHover, true);
  assert.equal(tree.props.modal, false);
  assert.equal(tree.props.contentStyle.width, 'max-content');
  assert.ok(tree.props.contentStyle.maxWidth.includes('100vw'));
  const content = JSON.stringify(tree.props.children);
  assert.ok(content.includes('text-default'));
  assert.ok(content.includes('bg-surface-secondary'));
  assert.ok(content.includes('bg-text'));
  assert.equal(/#[0-9a-f]{3,8}/i.test(content), false);
  assert.ok(content.includes('nowrap'));
  let prevented = false;
  tree.props.onOpenAutoFocus({ preventDefault() { prevented = true; } });
  assert.equal(prevented, true);
});

test('renderer patch requires an exact fingerprint and unique anchors', () => {
  const source = 'function ee(e){return a,T}function en(e){}';
  const profile = { ...PROFILE, sourceSha256: sha256(Buffer.from(source)) };
  const patched = transformSidebar(source, profile);
  assert.ok(patched.includes('data-usagebar-wrapper'));
  assert.ok(patched.includes('usage:F'));
  assert.throws(() => transformSidebar(source), /fingerprint/);
  assert.throws(() => transformSidebar(patched, profile), /Already patched/);
  const ambiguous = source + source;
  assert.throws(() => transformSidebar(ambiguous, { sourceSha256: sha256(Buffer.from(ambiguous)) }), /not unique/);
});

test('ASAR stage preserves original entries, validates hashes, and refuses overwrite', async t => {
  const folder = await temporary(t);
  const old = Buffer.from('original renderer');
  const untouched = Buffer.from('unchanged');
  const header = { files: {
    'renderer.js': { offset: '0', size: old.length, integrity: fileIntegrity(old, 4) },
    'keep.txt': { offset: String(old.length), size: untouched.length, integrity: fileIntegrity(untouched) },
  } };
  const input = join(folder, 'app.asar'), output = join(folder, 'patched.asar');
  await writeFile(input, Buffer.concat([encodeHeader(header), old, untouched]));
  const replacement = Buffer.from('patched renderer, with more content');
  const result = await buildArchive(input, output, 'renderer.js', replacement);
  assert.notEqual(result.beforeHeaderSha256, result.afterHeaderSha256);
  const archive = await openAsar(output);
  try {
    assert.deepEqual(await archive.read('renderer.js'), replacement);
    assert.deepEqual(await archive.read('keep.txt'), untouched);
  } finally { await archive.close(); }
  await assert.rejects(buildArchive(input, output, 'renderer.js', replacement), /EEXIST/);
  const original = await openAsar(input);
  try { assert.deepEqual(await original.read('renderer.js'), old); } finally { await original.close(); }
  assert.throws(() => fileIntegrity(old, 0), /block size/);
});

test('embedded executable checksum update changes only the 64-byte hash and never disables validation', () => {
  const before = 'a'.repeat(64), after = 'b'.repeat(64);
  const bytes = Buffer.from(`prefix[{"file":"resources\\\\app.asar","alg":"SHA256","value":"${before}"}]suffix`);
  const updated = updateEmbeddedHeaderHash(bytes, before, after);
  assert.equal(updated.length, bytes.length);
  assert.equal(updated.toString(), bytes.toString().replace(before, after));
  assert.throws(() => updateEmbeddedHeaderHash(Buffer.concat([bytes, bytes]), before, after), /record/);
  assert.throws(() => updateEmbeddedHeaderHash(Buffer.from('unknown executable'), before, after), /record/);
});

async function activationFixture(t) {
  const folder = await temporary(t), app = join(folder, 'app'), stage = join(folder, 'stage');
  const files = ['resources/app.asar', 'ChatGPT.exe'];
  for (const path of [app, stage]) await mkdir(join(path, 'resources'), { recursive: true });
  const manifest = { schema: 1, profile: PROFILE.id, clientVersion: PROFILE.version, files: {} };
  for (const file of files) {
    const before = Buffer.from('original ' + file), after = Buffer.from('patched ' + file);
    await writeFile(join(app, file), before); await writeFile(join(stage, file), after);
    manifest.files[file] = { before: sha256(before), after: sha256(after) };
  }
  await writeFile(join(stage, 'usagebar-patch.json'), JSON.stringify(manifest));
  return { app, stage, manifest };
}

test('apply makes verified backups; restore returns byte-for-byte original files', async t => {
  const { app, stage, manifest } = await activationFixture(t);
  const options = { processGuard() {} };
  await activatePatch(app, stage, options);
  await checkFiles(app, manifest, 'after');
  await activatePatch(app, stage, { ...options, restore: true });
  await checkFiles(app, manifest, 'before');
});

test('failed second-file replacement rolls back the first file', async t => {
  const { app, stage, manifest } = await activationFixture(t);
  let writes = 0;
  await assert.rejects(activatePatch(app, stage, { processGuard() {},
    async replace(source, destination) {
      if (++writes === 2) throw new Error('simulated locked executable');
      await writeFile(destination, await readFile(source));
    },
  }), /locked executable/);
  await checkFiles(app, manifest, 'before');
});

test('changed client or interrupted backup is never overwritten', async t => {
  const { app, stage } = await activationFixture(t);
  const exe = join(app, 'ChatGPT.exe');
  await writeFile(exe, 'new client version');
  await assert.rejects(activatePatch(app, stage, { processGuard() {} }), /File changed/);
  assert.equal(await readFile(exe, 'utf8'), 'new client version');
  assert.equal((await stat(exe)).isFile(), true);
});

test('structural manifests support newer versions with verified backup and restore', async t => {
  const { app, stage, manifest } = await activationFixture(t);
  manifest.profile = AUTO_ADAPTER;
  manifest.clientVersion = '99.12.34';
  manifest.sourceSha256 = sha256(Buffer.from('new renderer'));
  manifest.targetAsset = 'webview/assets/renamed.mjs';
  await writeFile(join(stage, 'usagebar-patch.json'), JSON.stringify(manifest));
  const result = await activatePatch(app, stage, { processGuard() {} });
  assert.ok(result.backup.includes('structural-'));
  await checkFiles(app, manifest, 'after');
  await activatePatch(app, stage, { processGuard() {}, restore: true });
  await checkFiles(app, manifest, 'before');
});
