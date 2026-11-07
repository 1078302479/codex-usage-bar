import { createHash } from 'node:crypto';
import { createWriteStream } from 'node:fs';
import { rename, rm, writeFile } from 'node:fs/promises';
import { resolve } from 'node:path';
import { Transform } from 'node:stream';
import { pipeline } from 'node:stream/promises';
import { pathToFileURL } from 'node:url';

const REPOSITORY = '1078302479/codex-usage-bar';
const INSTALLER = 'CodexUsageBar-Windows-x64-Setup.exe';
const VERSION = /^(?:0|[1-9]\d{0,8})\.(?:0|[1-9]\d{0,8})\.(?:0|[1-9]\d{0,8})$/;
const SHA256 = /^[a-f0-9]{64}$/i;
const MAX_INSTALLER_SIZE = 128 * 1024 * 1024;
const downloadUrl = version => 'https://github.com/' + REPOSITORY + '/releases/download/windows-v' + version + '/' + INSTALLER;

function compareVersions(left, right) {
  const numbers = left.split('.').map(Number);
  const other = right.split('.').map(Number);
  return numbers[0] - other[0] || numbers[1] - other[1] || numbers[2] - other[2];
}

function validInstallerSize(size) {
  return Number.isInteger(size) && size > 0 && size <= MAX_INSTALLER_SIZE;
}

export async function findWindowsUpdate(installedVersion, request = fetch) {
  if (!VERSION.test(installedVersion)) throw new Error('Invalid installed Windows version');
  const signal = AbortSignal.timeout(6000);
  const pageSize = 100;
  let candidate = null;
  for (let page = 1; ; page += 1) {
    const url = 'https://api.github.com/repos/' + REPOSITORY + '/releases?per_page=' + pageSize + '&page=' + page;
    const response = await request(url, { signal, redirect: 'error', headers: { Accept: 'application/vnd.github+json' } });
    if (!response.ok) throw new Error('GitHub release check failed');
    const releases = await response.json();
    if (!Array.isArray(releases)) throw new Error('Invalid GitHub release response');
    for (const release of releases) {
      if (release?.draft !== false || typeof release.tag_name !== 'string'
        || !release.tag_name.startsWith('windows-v') || !Array.isArray(release.assets)) continue;
      const version = release.tag_name.slice('windows-v'.length);
      if (!VERSION.test(version) || compareVersions(version, candidate?.version ?? installedVersion) <= 0) continue;
      const asset = release.assets.find(asset => asset?.name === INSTALLER && asset.state === 'uploaded'
        && asset.browser_download_url === downloadUrl(version) && validInstallerSize(asset.size)
        && typeof asset.digest === 'string' && asset.digest.startsWith('sha256:') && SHA256.test(asset.digest.slice(7)));
      if (asset) candidate = { version, sha256: asset.digest.slice(7).toLowerCase(), size: asset.size };
    }
    if (releases.length < pageSize) return candidate;
  }
}

export async function downloadWindowsUpdate({ version, sha256, size }, destination, request = fetch) {
  if (!VERSION.test(version) || !SHA256.test(sha256) || !validInstallerSize(size)) {
    throw new Error('Invalid installer metadata');
  }
  const signal = AbortSignal.timeout(180000);
  let url = new URL(downloadUrl(version));
  let response;
  for (let redirects = 0; redirects <= 3; redirects += 1) {
    if (!['https://github.com', 'https://release-assets.githubusercontent.com',
      'https://objects.githubusercontent.com'].includes(url.origin) || url.username || url.password) {
      throw new Error('Unexpected installer download host');
    }
    response = await request(url.href, { signal, redirect: 'manual' });
    if (response.ok && response.body) break;
    await response.body?.cancel();
    const location = response.headers.get('location');
    if (redirects === 3 || ![301, 302, 303, 307, 308].includes(response.status) || !location) {
      throw new Error('Installer download failed');
    }
    url = new URL(location, url);
  }

  const hash = createHash('sha256');
  let received = 0;
  const verifier = new Transform({
    transform(chunk, encoding, callback) {
      received += chunk.length;
      if (received > size) return callback(new Error('Installer size mismatch'));
      hash.update(chunk);
      callback(null, chunk);
    },
  });
  const partial = destination + '.part';
  try {
    await pipeline(response.body, verifier, createWriteStream(partial, { flags: 'wx' }), { signal });
    if (received !== size || hash.digest('hex') !== sha256.toLowerCase()) throw new Error('Installer checksum mismatch');
    await rename(partial, destination);
  } finally {
    await rm(partial, { force: true });
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  const [command, ...args] = process.argv.slice(2);
  try {
    if (command === 'check' && args.length === 1) {
      console.log(JSON.stringify(await findWindowsUpdate(args[0])));
    } else if (command === 'download' && args.length === 4) {
      const [version, sha256, size, destination] = args;
      await downloadWindowsUpdate({ version, sha256, size: Number(size) }, destination);
      if (process.platform === 'win32') {
        await writeFile(destination + ':Zone.Identifier', '[ZoneTransfer]\r\nZoneId=3\r\n');
      }
    } else {
      throw new Error('Invalid update command');
    }
  } catch (error) {
    console.error(error.message);
    process.exitCode = 1;
  }
}
