#!/usr/bin/env node
/**
 * Local dapp instance for UI testing.
 *
 * Serves dapp/ as the web root (like dev_server.mjs) and adds:
 *   - /proxy?url=...  CORS-blocked metadata fetches (same as dev_server.mjs)
 *   - /api/*          reverse proxy to the API service
 *   - an injected shim in every HTML response that rewrites
 *     https://api.zfi.wei.is/... -> /api/... so the UI never talks to
 *     production directly and CORS is a non-issue.
 *
 * Where /api/* goes is controlled by API_TARGET:
 *   API_TARGET=https://api.zfi.wei.is   (default) real quotes/data, no keys needed
 *   API_TARGET=http://localhost:8080    the local server/ instance (needs env keys)
 *
 * Usage:
 *   node dev_local.mjs                       # dapp on :3000, API -> production
 *   API_TARGET=http://localhost:8080 node dev_local.mjs   # full local stack
 *   PORT=4000 node dev_local.mjs
 */
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = path.join(path.dirname(fileURLToPath(import.meta.url)), 'dapp');
const PORT = parseInt(process.env.PORT, 10) || 3000;
const API_TARGET = (process.env.API_TARGET || 'https://api.zfi.wei.is').replace(/\/$/, '');
const PROD_API = 'https://api.zfi.wei.is';

const MIME = {
  '.html': 'text/html', '.js': 'application/javascript', '.mjs': 'application/javascript',
  '.css': 'text/css', '.json': 'application/json', '.png': 'image/png', '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg', '.gif': 'image/gif', '.svg': 'image/svg+xml', '.ico': 'image/x-icon',
  '.woff': 'font/woff', '.woff2': 'font/woff2', '.wasm': 'application/wasm', '.map': 'application/json',
};

// Injected into every HTML page: route production API URLs back through this
// server so a single API_TARGET switch moves the whole UI.
const SHIM = `<script>
(function () {
  var PROD = ${JSON.stringify(PROD_API)};
  function local(u) {
    return (typeof u === 'string' && u.indexOf(PROD) === 0) ? '/api' + u.slice(PROD.length) : u;
  }
  var _fetch = window.fetch;
  window.fetch = function (input, init) {
    if (typeof input === 'string') input = local(input);
    else if (input && input.url) input = new Request(local(input.url), input);
    return _fetch.call(this, input, init);
  };
  var _open = XMLHttpRequest.prototype.open;
  XMLHttpRequest.prototype.open = function (m, u) {
    arguments[1] = local(u);
    return _open.apply(this, arguments);
  };
  console.info('[zFi local] API -> ' + ${JSON.stringify(API_TARGET)});
})();
</script>
`;

function send(res, status, type, body, extra = {}) {
  res.writeHead(status, {
    'Content-Type': type,
    'Access-Control-Allow-Origin': '*',
    'Cache-Control': 'no-store',
    'Content-Length': Buffer.byteLength(body),
    ...extra,
  });
  res.end(body);
}

async function passthrough(res, target, init) {
  try {
    const upstream = await fetch(target, { ...init, signal: AbortSignal.timeout(20_000) });
    const body = Buffer.from(await upstream.arrayBuffer());
    res.writeHead(upstream.status, {
      'Content-Type': upstream.headers.get('content-type') || 'application/octet-stream',
      'Access-Control-Allow-Origin': '*',
      'Content-Length': body.length,
    });
    res.end(body);
  } catch (e) {
    send(res, 502, 'text/plain', `upstream error: ${e}`);
  }
}

async function readBody(req) {
  if (req.method === 'GET' || req.method === 'HEAD') return undefined;
  const chunks = [];
  for await (const c of req) chunks.push(c);
  return Buffer.concat(chunks);
}

async function handleApi(req, res, url) {
  const target = API_TARGET + url.pathname.slice('/api'.length) + url.search;
  const headers = {};
  for (const h of ['content-type', 'accept', 'authorization']) {
    if (req.headers[h]) headers[h] = req.headers[h];
  }
  await passthrough(res, target, { method: req.method, headers, body: await readBody(req) });
}

async function handleProxy(req, res, url) {
  const target = url.searchParams.get('url');
  if (!target) return send(res, 400, 'text/plain', 'Missing url param');
  await passthrough(res, target, { headers: { 'User-Agent': 'Mozilla/5.0' } });
}

function resolveFile(pathname) {
  let filePath = path.join(ROOT, decodeURIComponent(pathname));
  if (!filePath.startsWith(ROOT + path.sep) && filePath !== ROOT) return null;
  if (filePath.endsWith('/') || !path.extname(filePath)) {
    const idx = path.join(filePath, 'index.html');
    if (fs.existsSync(idx)) return idx;
    if (!path.extname(filePath) && fs.existsSync(filePath + '.html')) return filePath + '.html';
  }
  if (!fs.existsSync(filePath) || fs.statSync(filePath).isDirectory()) return null;
  return filePath;
}

function serveStatic(req, res, url) {
  const filePath = resolveFile(url.pathname);
  if (!filePath) return send(res, 404, 'text/plain', 'Not found');

  const ext = path.extname(filePath).toLowerCase();
  if (ext === '.html') {
    let html = fs.readFileSync(filePath, 'utf8');
    // Inject as early as possible so the shim is installed before page scripts run.
    html = html.includes('<head>') ? html.replace('<head>', '<head>\n' + SHIM) : SHIM + html;
    return send(res, 200, 'text/html; charset=utf-8', html);
  }
  return send(res, 200, MIME[ext] || 'application/octet-stream', fs.readFileSync(filePath));
}

http.createServer(async (req, res) => {
  const url = new URL(req.url, `http://localhost:${PORT}`);
  try {
    if (url.pathname === '/proxy') return await handleProxy(req, res, url);
    // The dapp ships its own /api/ docs page — a real static file always wins
    // over the proxy so the local instance mirrors production routing.
    if ((url.pathname === '/api' || url.pathname.startsWith('/api/')) && !resolveFile(url.pathname)) {
      return await handleApi(req, res, url);
    }
    return serveStatic(req, res, url);
  } catch (e) {
    send(res, 500, 'text/plain', String(e));
  }
}).listen(PORT, () => {
  console.log(`zFi dapp   http://localhost:${PORT}`);
  console.log(`API target ${API_TARGET}  (override with API_TARGET=http://localhost:8080)`);
});
