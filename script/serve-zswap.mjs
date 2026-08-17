#!/usr/bin/env node
/**
 * Serve the REAL zSwap.html on localhost, against real Ethereum, with your real
 * wallet.
 *
 * WHY THIS EXISTS AND THE PREVIEW DOES NOT REPLACE IT. The preview is the same
 * page over a simulated chain, which is exactly right for looking at layout,
 * charts and order cards - and exactly useless for deciding whether a contract
 * is ready to freeze. Nothing in it can produce a wallet prompt, a real revert,
 * a real gas estimate, or a real allowance. Those are the things that tell you
 * the backend is correct.
 *
 * It also cannot be an artifact or any other hosted page here: a wallet
 * extension injects `window.ethereum` into a top-level document, not into a
 * sandboxed iframe. `file://` mostly works but some wallets refuse to inject
 * there, and localStorage behaves differently. A plain localhost origin is the
 * one place the page behaves exactly as it will once it is served on chain.
 *
 * Usage:
 *   node script/serve-zswap.mjs            # zSwap.html on :8899
 *   node script/serve-zswap.mjs --preview  # the simulated build instead
 *   node script/serve-zswap.mjs --port 3000
 *
 * Then open the printed URL, connect a wallet on mainnet, and everything is
 * live - including transactions. Use small amounts.
 */
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const argv = process.argv.slice(2);
const has = (f) => argv.includes(f);
const val = (f, d) => { const i = argv.indexOf(f); return i >= 0 ? argv[i + 1] : d; };

const PREVIEW = has('--preview');
const FILE = PREVIEW
  ? path.join(ROOT, 'dapp', 'preview', 'index.html')
  : path.join(ROOT, 'zSwap.html');
const PORT = Number(val('--port', 8899));

if (!fs.existsSync(FILE)) {
  console.error(`missing ${path.relative(ROOT, FILE)}`);
  if (PREVIEW) console.error('run: node script/build-zSwap-preview.mjs');
  process.exit(1);
}

// Read per request rather than once, so editing the page and hitting reload is
// the whole edit loop. No watcher, no build step, no cache to bust.
const server = http.createServer((req, res) => {
  const url = (req.url || '/').split('?')[0];
  if (url !== '/' && url !== '/index.html' && url !== '/zSwap.html') {
    res.writeHead(404, { 'content-type': 'text/plain' });
    return res.end('not found');
  }
  let html;
  try { html = fs.readFileSync(FILE); }
  catch (e) { res.writeHead(500); return res.end(String(e)); }
  res.writeHead(200, {
    'content-type': 'text/html; charset=utf-8',
    // No caching: a stale page is indistinguishable from a change that did not
    // take, which is the worst thing to debug while testing contracts.
    'cache-control': 'no-store, must-revalidate',
  });
  res.end(html);
});

server.listen(PORT, '127.0.0.1', () => {
  const rel = path.relative(ROOT, FILE);
  console.log('');
  console.log(`  ${PREVIEW ? 'PREVIEW (simulated chain)' : 'LIVE (real Ethereum, real wallet)'}`);
  console.log(`  serving ${rel}`);
  console.log(`  http://127.0.0.1:${PORT}`);
  console.log('');
  if (!PREVIEW) {
    console.log('  Wallet prompts are real and transactions are real. Contracts in play:');
    console.log('    factory  0x000000Eb27B557aB426d9E99cFd54EC455799e81');
    console.log('    route    0x0000007Be74558A1F8c9045301c6F44C8eD0c9eB');
    console.log('    launcher 0x0000002fC8E77585A008Aa45d78A71ad36293aEe  (the coin button)');
    console.log('    splitter 0x000000aA142133107c7D2664F900f80e28BbfFbd  (no split set yet)');
    console.log('    launch lens 0x00000041201F1542EE49F9722b2590DEDFE4296B\n    lens     0x000000Bad3a2fa57ed74fa06000573ccddF6B7fB');
    console.log('    lq lens  0x000000956bf20A41C54BaE4a4b6F5C8A166DAB4E');
    console.log('');
    console.log('  poolCount() is 0 until a market is seeded, so the droplet');
    console.log('  will show an empty band list for every pair until then.');
    console.log('');
  }
  console.log('  Reload picks up edits to the file. Ctrl-C to stop.');
  console.log('');
});
