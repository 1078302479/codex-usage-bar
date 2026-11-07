import { readFile, mkdir, copyFile, rename, unlink, open, realpath, stat } from 'node:fs/promises';
import { constants } from 'node:fs';
import { resolve, join, dirname, basename } from 'node:path';
import { randomUUID } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { pathToFileURL } from 'node:url';
import { openAsar, sha256 } from './asar.mjs';
import { PROFILE } from './profile.mjs';
import { AUTO_ADAPTER, discoverAdapter, transformAuto } from './auto-adapter.mjs';
import { buildArchive, buildExecutable, hashFile } from './archive-build.mjs';

const FILES = ['resources/app.asar', 'ChatGPT.exe'];
const MANIFEST = 'usagebar-patch.json';

async function writeJson(path, value) {
  const { writeFile } = await import('node:fs/promises');
  await writeFile(path, `${JSON.stringify(value, null, 2)}\n`, { flag: 'wx' });
}

export async function stagePatch(appDirectory, outputDirectory, display = null) {
  const app = await realpath(appDirectory);
  const output = resolve(outputDirectory);
  // A stage must be new, and must not be inside the installed app.
  if (output.toLowerCase().startsWith(app.toLowerCase() + '\\') || output === app) throw new Error('Stage must be outside the app');
  await mkdir(output, { recursive: false });
  await mkdir(join(output, 'resources'));
  const archivePath = join(app, 'resources/app.asar');
  const archive = await openAsar(archivePath);
  let transformed, adapter, sourceHeaderSha256;
  try {
    sourceHeaderSha256 = sha256(archive.headerBytes);
    adapter = await discoverAdapter(archive);
    transformed = transformAuto(adapter.source, adapter.analysis, adapter.resetCredits, display);
  } finally { await archive.close(); }
  const syntax = spawnSync(process.execPath, ['--check', '--input-type=module'],
    { input: transformed, encoding: 'utf8', windowsHide: true, timeout: 15000 });
  if (syntax.error || syntax.status !== 0) throw new Error('Generated renderer JavaScript failed syntax validation');
  const beforeArchiveHash = await hashFile(archivePath);
  const headers = await buildArchive(archivePath, join(output, FILES[0]), adapter.target, Buffer.from(transformed));
  if (headers.beforeHeaderSha256 !== sourceHeaderSha256) throw new Error('Client changed after analysis; discard this stage');
  const exe = await buildExecutable(join(app, FILES[1]), join(output, FILES[1]), headers.beforeHeaderSha256, headers.afterHeaderSha256);
  // Detect an update of the original client during preparation.
  if (await hashFile(archivePath) !== beforeArchiveHash) throw new Error('Client changed while staging; discard this stage');
  const manifest = { schema: 1, profile: adapter.id, clientVersion: adapter.version,
    createdAt: new Date().toISOString(), targetAsset: adapter.target,
    sourceSha256: adapter.sourceSha256, adaptation: 'AST-validated native rail structure',
    resetCredits: adapter.resetCredits,
    display,
    signatureImpact: 'Changing the embedded ASAR header hash invalidates ChatGPT.exe Authenticode signature. Integrity validation stays enabled.',
    activation: 'Offline stage only. No installed client files have been modified.',
    files: {
      [FILES[0]]: { before: beforeArchiveHash, after: await hashFile(join(output, FILES[0])) },
      [FILES[1]]: { before: exe.beforeSha256, after: exe.afterSha256 },
    }, ...headers };
  await writeJson(join(output, MANIFEST), manifest);
  return manifest;
}

export async function loadManifest(directory) {
  const value = JSON.parse(await readFile(join(directory, MANIFEST), 'utf8'));
  const legacy = value.profile === PROFILE.id && value.clientVersion === PROFILE.version;
  const structural = value.profile === AUTO_ADAPTER && /^[A-Za-z0-9._-]{1,80}$/.test(value.clientVersion)
    && /^[a-f0-9]{64}$/.test(value.sourceSha256)
    && /^webview\/[A-Za-z0-9_./-]+\.m?js$/.test(value.targetAsset) && !value.targetAsset.includes('..');
  if (value.schema !== 1 || !(legacy || structural)
      || Object.keys(value.files ?? {}).sort().join('|') !== [...FILES].sort().join('|')
      || FILES.some(file => !/^[a-f0-9]{64}$/.test(value.files[file]?.before)
        || !/^[a-f0-9]{64}$/.test(value.files[file]?.after))) throw new Error('Invalid patch manifest');
  return value;
}

export async function checkFiles(root, manifest, state) {
  const directory = await realpath(root);
  for (const file of FILES) {
    const path = await realpath(join(directory, file));
    const expected = resolve(directory, file);
    if (path.toLowerCase() !== expected.toLowerCase()) throw new Error('Linked targets are not supported');
    if (await hashFile(path) !== manifest.files[file][state]) throw new Error(`File changed; refusing to overwrite: ${file}`);
  }
}

export function assertAppClosed(app) {
  if (process.platform !== 'win32') throw new Error('Activation is Windows-only');
  const powershell = join(process.env.SystemRoot ?? 'C:\\Windows', 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe');
  const result = spawnSync(powershell, ['-NoProfile', '-NonInteractive', '-Command',
    '$ErrorActionPreference="Stop"; $target=$env:USAGEBAR_TARGET_DIRECTORY; $active=Get-Process | Where-Object { $_.Path -and $_.Path.StartsWith($target,[System.StringComparison]::OrdinalIgnoreCase) }; if($active){exit 17}'],
  { env: { ...process.env, USAGEBAR_TARGET_DIRECTORY: app + '\\' }, windowsHide: true, encoding: 'utf8', timeout: 15000 });
  if (result.error || result.status !== 0) throw new Error('Client is running or process check failed. Save work and close the client before activation.');
}

async function replaceFile(source, destination) {
  const temp = join(dirname(destination), `.${basename(destination)}.usagebar-${randomUUID()}.tmp`);
  try {
    await copyFile(source, temp, constants.COPYFILE_EXCL);
    await rename(temp, destination);
  } finally { await unlink(temp).catch(error => { if (error.code !== 'ENOENT') throw error; }); }
}

export async function activatePatch(appDirectory, stageDirectory, { restore = false,
  processGuard = assertAppClosed, replace = replaceFile } = {}) {
  const app = await realpath(appDirectory);
  // Never take ownership of or alter the managed Store package. Test on an
  // explicitly prepared portable copy instead; no signature enforcement bypass.
  if (/[\\/]WindowsApps[\\/]/i.test(app + '/')) throw new Error('Managed WindowsApps installation is not an activation target. Use a portable copy.');
  const stage = await realpath(stageDirectory);
  const manifest = await loadManifest(stage);
  const backupId = manifest.profile === AUTO_ADAPTER
    ? `structural-${manifest.files['resources/app.asar'].before.slice(0, 12)}-${manifest.files['resources/app.asar'].after.slice(0, 12)}` : PROFILE.id;
  let backup = join(app, '.usagebar-backup', backupId);
  if (restore && manifest.profile === AUTO_ADAPTER) {
    try { await stat(backup); } catch (error) {
      if (error.code !== 'ENOENT') throw error;
      // Read older backups made before per-patch backup directories existed.
      backup = join(app, '.usagebar-backup', `structural-${manifest.files['resources/app.asar'].before.slice(0, 16)}`);
    }
    const saved = await loadManifest(backup);
    if (FILES.some(file => saved.files[file].before !== manifest.files[file].before
      || saved.files[file].after !== manifest.files[file].after)) throw new Error('Backup belongs to another patch');
  }
  const lock = await open(join(app, '.usagebar-patch.lock'), 'wx');
  try {
    processGuard(app);
    if (restore) {
      await checkFiles(stage, manifest, 'after');
      await checkFiles(backup, manifest, 'before');
      await checkFiles(app, manifest, 'after');
    } else {
      await checkFiles(stage, manifest, 'after');
      await checkFiles(app, manifest, 'before');
      // No overwrite of backups, including leftovers from an interrupted run.
      await mkdir(dirname(backup), { recursive: true });
      await mkdir(backup);
      await mkdir(join(backup, 'resources'));
      for (const file of FILES) await copyFile(join(app, file), join(backup, file), constants.COPYFILE_EXCL);
      await checkFiles(backup, manifest, 'before');
      await writeJson(join(backup, MANIFEST), manifest);
    }
    const source = restore ? backup : stage;
    const previous = restore ? stage : backup;
    const changed = [];
    try {
      for (const file of FILES) {
        await replace(join(source, file), join(app, file));
        changed.push(file);
      }
      await checkFiles(app, manifest, restore ? 'before' : 'after');
    } catch (error) {
      // Only roll back files modified by this attempt; never delete a backup.
      for (const file of changed.reverse()) await replaceFile(join(previous, file), join(app, file));
      throw error;
    }
    return { action: restore ? 'restored' : 'applied', app, backup, clientVersion: manifest.clientVersion };
  } finally { await lock.close(); await unlink(join(app, '.usagebar-patch.lock')); }
}

async function main() {
  const [command, app, directory] = process.argv.slice(2);
  if (command === 'analyze' && app) {
    const archive = await openAsar(join(await realpath(app), 'resources/app.asar'));
    try {
      const { source, ...report } = await discoverAdapter(archive);
      transformAuto(source, report.analysis, report.resetCredits);
      return { rendererCompatible: true, binaryIntegrityRecord: 'Checked separately during staging', ...report };
    } finally { await archive.close(); }
  }
  if (!app || !directory || !['stage', 'check', 'verify', 'apply', 'restore'].includes(command)) {
    throw new Error('Usage: node windows/patch/manage.mjs analyze <app-directory> OR stage|check|verify|apply|restore <app-directory> <stage-directory>');
  }
  if (command === 'stage') return stagePatch(app, directory);
  if (command === 'check' || command === 'verify') {
    const manifest = await loadManifest(directory);
    await checkFiles(directory, manifest, 'after');
    await checkFiles(app, manifest, command === 'verify' ? 'after' : 'before');
    return { compatible: true, state: command === 'verify' ? 'patched' : 'original',
      profile: manifest.profile, signatureImpact: manifest.signatureImpact };
  }
  return activatePatch(app, directory, { restore: command === 'restore' });
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main().then(result => console.log(JSON.stringify(result, null, 2)))
    .catch(error => { console.error(error.message); process.exitCode = 1; });
}
