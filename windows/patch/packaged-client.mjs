import { spawnSync } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { lstat, readFile, readdir, realpath, rename, rm, writeFile } from 'node:fs/promises';
import { basename, dirname, join, resolve, sep } from 'node:path';
import { fileURLToPath } from 'node:url';
import { activatePatch, checkFiles, loadManifest, stagePatch } from './manage.mjs';
import { displayPreferences, readDisplayPreferences } from './display-preferences.mjs';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const local = join(root, '.local');
const client = join(local, 'windows-sidebar-client');
const pointer = join(local, 'windows-sidebar-active-stage.txt');
const lockName = 'windows-sidebar-launch.lock';
const preferences = join(local, 'display-settings.json');

async function exists(path) {
  try { await lstat(path); return true; } catch (error) {
    if (error.code === 'ENOENT') return false;
    throw error;
  }
}

function checkClosed(path) {
  const result = spawnSync(join(root, 'CodexUsageBar.exe'), ['check-path', path], { windowsHide: true, timeout: 15000 });
  if (result.error || result.status !== 0) {
    throw new Error('Exit Codex UsageBar from the File menu or system tray, then try again.');
  }
}

async function remove(path) {
  await rm(path, { recursive: true, force: true, maxRetries: 3 });
}

async function install(source) {
  const official = await realpath(source);
  if (official.toLowerCase() === local.toLowerCase() || official.toLowerCase().startsWith(local.toLowerCase() + sep)
      || local.toLowerCase().startsWith(official.toLowerCase() + sep)) {
    throw new Error('The source and generated client directories must be separate.');
  }
  checkClosed(client);
  const id = randomUUID().replaceAll('-', '');
  const stage = join(local, 'windows-sidebar-stage-' + id);
  const candidate = join(local, 'new-' + id);
  const previous = join(local, 'old-' + id);
  const newPointer = join(local, 'windows-sidebar-active-' + id + '.txt');
  const oldStage = await exists(pointer) ? (await readFile(pointer, 'utf8')).trim() : '';
  let committed = false;
  try {
    await stagePatch(official, stage, await readDisplayPreferences(preferences));
    const robocopy = join(process.env.SystemRoot, 'System32', 'robocopy.exe');
    const copied = spawnSync(robocopy, [official, candidate, '/E', '/XJ', '/COPY:DAT', '/DCOPY:DAT', '/R:1', '/W:1',
      '/NFL', '/NDL', '/NJH', '/NJS', '/NP'], { windowsHide: true, encoding: 'utf8' });
    if (copied.error || copied.status === null || copied.status >= 8) {
      throw new Error('Failed to copy the Store client. ' + (copied.stdout ?? '').trim());
    }
    await activatePatch(candidate, stage, { processGuard: checkClosed });
    await writeFile(newPointer, stage + '\n', { flag: 'wx' });
    checkClosed(client);
    const hadPrevious = await exists(client);
    if (hadPrevious) await rename(client, previous);
    try {
      await rename(candidate, client);
      try {
        await rename(newPointer, pointer);
      } catch (error) {
        await rename(client, candidate);
        throw error;
      }
    } catch (error) {
      if (hadPrevious) await rename(previous, client);
      throw error;
    }
    committed = true;
    await remove(previous).catch(error => console.warn(error.message));
    if (dirname(oldStage) === local && /^windows-sidebar-stage-[a-f0-9]{32}$/.test(basename(oldStage))) {
      await remove(oldStage).catch(error => console.warn(error.message));
    }
  } finally {
    for (const path of [candidate, newPointer, ...(committed ? [] : [stage])]) {
      await remove(path).catch(error => console.warn(error.message));
    }
  }
}

async function verify() {
  const stage = (await readFile(pointer, 'utf8')).trim();
  const manifest = await loadManifest(stage);
  await checkFiles(stage, manifest, 'after');
  await checkFiles(client, manifest, 'after');
}

try {
  if ((await realpath(local)).toLowerCase() !== local.toLowerCase()) throw new Error('Linked output directories are unsupported.');
  const [command, source] = process.argv.slice(2);
  if (command === 'install' && source) await install(source);
  else if (command === 'verify') await verify();
  else if (command === 'display-pending') {
    const stage = (await readFile(pointer, 'utf8')).trim();
    const manifest = await loadManifest(stage);
    const requested = await readDisplayPreferences(preferences);
    console.log(JSON.stringify(displayPreferences(manifest.display)) !== JSON.stringify(requested));
  }
  else if (command === 'remove') {
    checkClosed(client);
    for (const entry of await readdir(local)) {
      if (entry !== lockName) await remove(join(local, entry));
    }
  } else throw new Error('Invalid packaged client command.');
} catch (error) {
  console.error(error.message);
  process.exitCode = 1;
}
