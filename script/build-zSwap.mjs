#!/usr/bin/env node
// Refreshes src/zSwap.sol from zSwap.html:
//   - updates the payload-size and headroom mentions in the natspec
//   - rewrites the trailing /* ===== zSwap.html source ===== */ comment block
//   - rewrites the same figures in README.md and docs/src/README.md
//
// The page is NO LONGER embedded in this file. It is deployed as separate data
// contracts (script/build-zSwap-chunks.mjs) whose addresses are passed to the
// zSwap constructor, so EIP-170 caps each chunk rather than the whole page.
//
// Aborts if the HTML contains a "*/" sequence (it would end the comment early).
// Run all three in order — skipping the registry step leaves
// script/zSwapRegistry-*.calldata.txt pinned to a stale page:
//   node script/build-zSwap.mjs
//   node script/build-zSwap-chunks.mjs
//   node script/build-zSwapRegistry-call.mjs

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const HTML_PATH = path.join(ROOT, 'zSwap.html');
const SOL_PATH = path.join(ROOT, 'src', 'zSwap.sol');

const EIP170_LIMIT = 24576;
const CHUNKS = 3;

const html = fs.readFileSync(HTML_PATH);
const htmlText = html.toString('utf8');

if (htmlText.includes('*/')) {
  console.error('ERROR: zSwap.html contains "*/" which would break the trailing Solidity block comment.');
  process.exit(1);
}

const perChunk = Math.ceil(html.length / CHUNKS);
if (perChunk > EIP170_LIMIT) {
  console.error(
    `ERROR: ${html.length} B over ${CHUNKS} chunks is ${perChunk} B each, above EIP-170 (${EIP170_LIMIT} B). Raise CHUNKS.`
  );
  process.exit(1);
}

const sol = fs.readFileSync(SOL_PATH, 'utf8');
const headroom = EIP170_LIMIT * CHUNKS - html.length;

const sized = sol
  .replace(/(HTML payload \()[\d,]+( B\))/, `$1${html.length}$2`)
  .replace(/(across )\d+( data contracts)/, `$1${CHUNKS}$2`)
  .replace(/(\d+ B per chunk, )[\d,]+( B headroom)/, `$1${headroom}$2`);

const sourceMarker = '\n\n/* ===== zSwap.html source';
const before = sized.includes(sourceMarker)
  ? sized.slice(0, sized.indexOf(sourceMarker))
  : sized.replace(/\s*$/, '');

const sourceBlock =
  `\n\n/* ===== zSwap.html source (canonical, byte-for-byte equivalent of the deployed chunks) =====\n\n` +
  htmlText +
  `\n===== end of zSwap.html source ===== */\n`;

fs.writeFileSync(SOL_PATH, before + sourceBlock);

// The same three numbers appear prose-style in the READMEs. They used to be
// hand-maintained and silently rotted every time the page changed, so rewrite
// them from the real payload here rather than trusting anyone to remember.
// Chunk sizes must mirror how build-zSwap-chunks.mjs actually slices the file —
// ceil(len/n) per chunk with the remainder in the last — not a balanced split.
// The two agree at the current size but diverge in general, and the README must
// describe what is really deployed.
const per = Math.ceil(html.length / CHUNKS);
const chunkSizes = Array.from({length: CHUNKS}, (_, i) =>
  Math.max(0, Math.min((i + 1) * per, html.length) - i * per)
).filter(Boolean);
// Formatted numbers contain commas, so the chunk list is joined with " / "
// rather than commas — otherwise neither the sentence nor the regex below can
// tell a thousands separator from a list separator.
const n = v => v.toLocaleString('en-US');
const sentence =
  `The current payload is ${n(html.length)} bytes across ${CHUNKS} data contracts ` +
  `(${chunkSizes.map(n).join(' / ')} bytes), with ${n(headroom)} bytes of ${CHUNKS}-chunk headroom.`;

const READMES = [path.join(ROOT, 'README.md'), path.join(ROOT, 'docs', 'src', 'README.md')];
// Anchored on the stable prefix and the ", with N bytes of ...headroom." suffix so
// it keeps matching whatever shape the middle took on a previous run.
const SENTENCE_RE = /The current payload is [\d,]+ bytes across .*?, with [\d,]+ bytes of [\w-]+ headroom\./;
for (const p of READMES) {
  if (!fs.existsSync(p)) continue;
  const txt = fs.readFileSync(p, 'utf8');
  if (!SENTENCE_RE.test(txt)) {
    console.warn(`WARNING: ${path.relative(ROOT, p)} has no payload-size sentence to update — check it by hand.`);
    continue;
  }
  const next = txt.replace(SENTENCE_RE, sentence);
  if (next !== txt) fs.writeFileSync(p, next);
}

console.log(`zSwap.html: ${html.length} B across ${CHUNKS} chunks (${headroom} B headroom)`);
console.log(`  chunks: ${chunkSizes.map(n).join(' / ')} B`);
console.log(`src/zSwap.sol: natspec + canonical source comment refreshed`);
console.log(`README.md + docs/src/README.md: payload sizes refreshed`);
console.log(`next: node script/build-zSwap-chunks.mjs && node script/build-zSwapRegistry-call.mjs && node script/check-zSwap.mjs`);
