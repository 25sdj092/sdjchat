// SDJ Chat Vercel build
// The large application bundle is stored as small base64+gzip chunks so the repository
// can be populated from a browser-based GitHub workflow. Rebuild the public asset here.
import { existsSync, readdirSync, readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { gunzipSync } from 'node:zlib';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');

function restoreGzipChunks(name, target) {
  const dir = join(root, 'scripts', 'payload', name);
  if (!existsSync(dir)) throw new Error(`Missing compressed payload directory: ${dir}`);

  const parts = readdirSync(dir)
    .filter((file) => /^\d+\.b64$/.test(file))
    .sort((a, b) => Number.parseInt(a, 10) - Number.parseInt(b, 10));

  if (!parts.length) throw new Error(`No payload chunks found for ${name}`);

  const base64 = parts.map((file) => readFileSync(join(dir, file), 'utf8').trim()).join('');
  if (!/^[A-Za-z0-9+/]+={0,2}$/.test(base64) || base64.length % 4 !== 0) {
    throw new Error(`Invalid base64 payload for ${name}`);
  }

  const output = gunzipSync(Buffer.from(base64, 'base64'));
  mkdirSync(dirname(join(root, target)), { recursive: true });
  writeFileSync(join(root, target), output);
  console.log(`[build] ${target}: ${output.byteLength.toLocaleString()} bytes restored`);
}

restoreGzipChunks('app', 'public/app.js');

// The Supabase SDK is loaded from its official UMD CDN in index.html, reducing
// the amount of code served from this static project.
if (existsSync(join(root, 'scripts', 'payload', 'schema'))) {
  restoreGzipChunks('schema', 'supabase/schema.sql');
}

const configPath = join(root, 'public', 'config.js');
if (!existsSync(configPath)) throw new Error('public/config.js is missing');
console.log('[build] ready');
