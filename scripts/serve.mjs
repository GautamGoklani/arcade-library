#!/usr/bin/env node
/**
 * A static file server for local play — `npm run serve`, then open
 * http://localhost:8080.
 *
 * This exists for one reason: **`WebAssembly.instantiateStreaming` needs an
 * HTTP response with `Content-Type: application/wasm`**, and a `file://` URL
 * has neither. Opening a page that fetches a `.wasm` straight off disk fails
 * with a CORS error in Chrome and a MIME-type error in Firefox, which is one of
 * the first walls anyone hits learning WebAssembly.
 *
 * The single-file builds (`games/<title>/index.html`) carry the engine as
 * base64 and therefore *do* open from disk — that is the whole point of
 * embedding it. Everything else wants a server.
 */
import { createServer } from 'node:http';
import { createReadStream, statSync } from 'node:fs';
import { extname, join, normalize, resolve } from 'node:path';
import { dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = resolve(join(dirname(fileURLToPath(import.meta.url)), '..'));
const PORT = Number(process.env.PORT) || 8080;

const TYPES = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.mjs': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.svg': 'image/svg+xml',
  '.png': 'image/png',
  '.md': 'text/markdown; charset=utf-8',
  // The one that matters.
  '.wasm': 'application/wasm',
  '.wat': 'text/plain; charset=utf-8',
};

createServer((req, res) => {
  const url = decodeURIComponent(new URL(req.url, 'http://localhost').pathname);
  // normalize() collapses `..` before the prefix check, so a crafted path
  // cannot climb out of the repo.
  let path = join(ROOT, normalize(url));
  if (!path.startsWith(ROOT)) {
    res.writeHead(403).end('Forbidden');
    return;
  }

  try {
    if (statSync(path).isDirectory()) path = join(path, 'index.html');
  } catch {
    res.writeHead(404).end('Not found');
    return;
  }

  try {
    statSync(path);
  } catch {
    res.writeHead(404).end('Not found');
    return;
  }

  res.writeHead(200, {
    'Content-Type': TYPES[extname(path).toLowerCase()] ?? 'application/octet-stream',
    'Cache-Control': 'no-cache',
  });
  createReadStream(path).pipe(res);
}).listen(PORT, () => {
  console.log(`arcade-library → http://localhost:${PORT}`);
});
