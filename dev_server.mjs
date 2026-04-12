#!/usr/bin/env node
/**
 * Dev server with /proxy endpoint for CORS-blocked metadata fetches.
 * Node equivalent of serve.py — used by .claude/launch.json for preview.
 */
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = path.join(path.dirname(fileURLToPath(import.meta.url)), 'dapp');
const PORT = parseInt(process.env.PORT, 10) || 3000;

const MIME = {
  '.html': 'text/html',
  '.js':   'application/javascript',
  '.mjs':  'application/javascript',
  '.css':  'text/css',
  '.json': 'application/json',
  '.png':  'image/png',
  '.jpg':  'image/jpeg',
  '.svg':  'image/svg+xml',
  '.ico':  'image/x-icon',
  '.wasm': 'application/wasm',
};

async function handleProxy(req, res) {
  const u = new URL(req.url, `http://localhost:${PORT}`);
  const target = u.searchParams.get('url');
  if (!target) {
    res.writeHead(400, { 'Content-Type': 'text/plain' });
    return res.end('Missing url param');
  }
  try {
    const resp = await fetch(target, {
      headers: { 'User-Agent': 'Mozilla/5.0' },
      signal: AbortSignal.timeout(10_000),
    });
    const body = Buffer.from(await resp.arrayBuffer());
    res.writeHead(200, {
      'Content-Type': 'application/json',
      'Access-Control-Allow-Origin': '*',
      'Content-Length': body.length,
    });
    res.end(body);
  } catch (e) {
    res.writeHead(502, { 'Content-Type': 'text/plain', 'Access-Control-Allow-Origin': '*' });
    res.end(String(e));
  }
}

function serveStatic(req, res) {
  const u = new URL(req.url, `http://localhost:${PORT}`);
  let filePath = path.join(__dirname, decodeURIComponent(u.pathname));

  if (!filePath.startsWith(__dirname + path.sep) && filePath !== __dirname) {
    res.writeHead(403, { 'Content-Type': 'text/plain' });
    return res.end('Forbidden');
  }

  if (filePath.endsWith('/') || !path.extname(filePath)) {
    const asDir = filePath.endsWith('/') ? filePath : filePath + '/';
    const idx = path.join(asDir, 'index.html');
    if (fs.existsSync(idx)) filePath = idx;
    else if (!path.extname(filePath) && fs.existsSync(filePath + '.html')) filePath += '.html';
  }

  if (!fs.existsSync(filePath) || fs.statSync(filePath).isDirectory()) {
    res.writeHead(404, { 'Content-Type': 'text/plain', 'Access-Control-Allow-Origin': '*' });
    return res.end('Not found');
  }

  const ext = path.extname(filePath).toLowerCase();
  const mime = MIME[ext] || 'application/octet-stream';
  const body = fs.readFileSync(filePath);
  res.writeHead(200, {
    'Content-Type': mime,
    'Access-Control-Allow-Origin': '*',
    'Content-Length': body.length,
  });
  res.end(body);
}

const server = http.createServer((req, res) => {
  if (req.url.startsWith('/proxy?')) return handleProxy(req, res);
  serveStatic(req, res);
});

server.listen(PORT, () => {
  console.log(`Dev server listening on http://localhost:${PORT}`);
});
