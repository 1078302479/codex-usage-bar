import { openAsar, sha256 } from './asar.mjs';
import { pathToFileURL } from 'node:url';

export async function inspectClient(archivePath, { snippets = false } = {}) {
  const archive = await openAsar(archivePath);
  try {
    const pkg = JSON.parse((await archive.read('package.json')).toString());
    const result = { version: pkg.version, product: pkg.productName,
      headerSha256: sha256(archive.headerBytes), candidates: [] };
    for (const [path, entry] of archive.entries) {
      if (!/^webview\/assets\/async\/.*\.js$/.test(path) || entry.size > 1_000_000) continue;
      const source = (await archive.read(path)).toString();
      const matches = [...source.matchAll(/(?:description|defaultMessage):"[^"\n]{0,260}(?:usage|Usage)[^"\n]{0,180}"/g)]
        .filter(match => /navigation rail|usage navigation|rail button/i.test(match[0]));
      if (matches.length) result.candidates.push({ path, sha256: sha256(Buffer.from(source)),
        ...(snippets ? { matches: matches.map(match => ({ position: match.index, text: match[0] })) } : {}) });
    }
    return result;
  } finally { await archive.close(); }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const archivePath = process.argv[2];
  if (!archivePath) { console.error('Usage: node windows/patch/inspect.mjs <app.asar> [--snippets]'); process.exitCode = 1; }
  else console.log(JSON.stringify(await inspectClient(archivePath, { snippets: process.argv.includes('--snippets') }), null, 2));
}
