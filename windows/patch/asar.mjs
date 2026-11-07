import { open, stat } from 'node:fs/promises';
import { createHash } from 'node:crypto';

export const sha256 = bytes => createHash('sha256').update(bytes).digest('hex');

// Minimal read-only ASAR reader. Never loads the entire client archive in RAM.
export async function openAsar(path) {
  const file = await open(path, 'r');
  try {
    const prefix = Buffer.alloc(16);
    await file.read(prefix, 0, 16, 0);
    const size = prefix.readUInt32LE(12);
    const headerSize = prefix.readUInt32LE(4);
    const total = (await stat(path)).size;
    if (prefix.readUInt32LE(0) !== 4 || size < 2 || size > 32 * 1024 * 1024
        || headerSize < size + 8 || headerSize > size + 12 || 8 + headerSize > total) {
      throw new Error('Unsupported ASAR header');
    }
    const headerBytes = Buffer.alloc(size);
    await file.read(headerBytes, 0, size, 16);
    const header = JSON.parse(headerBytes.toString('utf8'));
    const base = 8 + headerSize;
    const entries = new Map();
    function walk(node, prefix = '') {
      for (const [name, entry] of Object.entries(node.files ?? {})) {
        if (!name || name === '.' || name === '..' || /[\\/]/.test(name)) throw new Error('Unsafe ASAR path');
        const key = prefix + name;
        if (entry.files) walk(entry, key + '/');
        else entries.set(key, entry);
      }
    }
    walk(header);
    return {
      file, header, headerBytes, base, entries,
      async read(key) {
        const entry = entries.get(key);
        if (!entry || entry.unpacked || entry.link) throw new Error(`Not a packed regular file: ${key}`);
        const offset = Number(entry.offset), length = entry.size;
        if (!Number.isSafeInteger(offset) || offset < 0 || !Number.isSafeInteger(length)
            || length < 0 || base + offset + length > total) throw new Error('Invalid ASAR entry range');
        const bytes = Buffer.alloc(length);
        const { bytesRead } = await file.read(bytes, 0, length, base + offset);
        if (bytesRead !== length) throw new Error('Truncated ASAR entry');
        if (entry.integrity) {
          if (entry.integrity.algorithm !== 'SHA256' || sha256(bytes) !== entry.integrity.hash) {
            throw new Error(`ASAR entry integrity mismatch: ${key}`);
          }
        }
        return bytes;
      },
      close: () => file.close(),
    };
  } catch (error) { await file.close(); throw error; }
}
