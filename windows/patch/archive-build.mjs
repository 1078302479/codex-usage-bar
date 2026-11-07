import { createReadStream, createWriteStream } from 'node:fs';
import { readFile, stat, writeFile } from 'node:fs/promises';
import { pipeline } from 'node:stream/promises';
import { createHash } from 'node:crypto';
import { openAsar, sha256 } from './asar.mjs';

export async function hashFile(path) {
  const hash = createHash('sha256');
  for await (const bytes of createReadStream(path)) hash.update(bytes);
  return hash.digest('hex');
}

export function encodeHeader(header) {
  const json = Buffer.from(JSON.stringify(header));
  const payloadSize = Math.ceil((4 + json.length) / 4) * 4;
  const bytes = Buffer.alloc(12 + payloadSize);
  bytes.writeUInt32LE(4, 0);
  bytes.writeUInt32LE(4 + payloadSize, 4);
  bytes.writeUInt32LE(payloadSize, 8);
  bytes.writeUInt32LE(json.length, 12);
  json.copy(bytes, 16);
  return bytes;
}

export function fileIntegrity(bytes, blockSize = 4 * 1024 * 1024) {
  if (!Number.isSafeInteger(blockSize) || blockSize < 1) throw new Error('Invalid ASAR integrity block size');
  const blocks = [];
  for (let at = 0; at < bytes.length; at += blockSize) blocks.push(sha256(bytes.subarray(at, at + blockSize)));
  return { algorithm: 'SHA256', hash: sha256(bytes), blockSize, blocks };
}

export async function buildArchive(source, destination, target, replacement) {
  const archive = await openAsar(source);
  try {
    // Validate source entry before carrying any content over to the staged file.
    await archive.read(target);
    const originalSize = (await stat(source)).size;
    const entry = archive.entries.get(target);
    entry.offset = String(originalSize - archive.base);
    entry.size = replacement.length;
    entry.integrity = fileIntegrity(replacement, entry.integrity?.blockSize);
    const header = encodeHeader(archive.header);
    async function* chunks() {
      yield header;
      yield* createReadStream(source, { start: archive.base });
      yield replacement;
    }
    await pipeline(chunks(), createWriteStream(destination, { flags: 'wx' }));
    const checked = await openAsar(destination);
    try {
      if (!(await checked.read(target)).equals(replacement)) throw new Error('Staged archive verification failed');
      return { beforeHeaderSha256: sha256(archive.headerBytes), afterHeaderSha256: sha256(checked.headerBytes) };
    } finally { await checked.close(); }
  } finally { await archive.close(); }
}

export function updateEmbeddedHeaderHash(executable, beforeHash, afterHash) {
  const before = Buffer.from(`[{"file":"resources\\\\app.asar","alg":"SHA256","value":"${beforeHash}"}]`);
  const at = executable.indexOf(before);
  if (at < 0 || executable.indexOf(before, at + 1) >= 0) throw new Error('Unsupported executable integrity record');
  const result = Buffer.from(executable);
  const hashAt = at + before.indexOf(beforeHash);
  result.write(afterHash, hashAt, 64, 'ascii');
  return result;
}

export async function buildExecutable(source, destination, beforeHash, afterHash) {
  const original = await readFile(source);
  const patched = updateEmbeddedHeaderHash(original, beforeHash, afterHash);
  await writeFile(destination, patched, { flag: 'wx' });
  return { beforeSha256: sha256(original), afterSha256: sha256(patched) };
}
