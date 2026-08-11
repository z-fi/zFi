#!/usr/bin/env node
/**
 * Every token in the list must quote in the preview.
 *
 * The preview's simulated chain prices routes from its own table, and a token
 * missing from it does not fail as "the simulation has no price" - it fails as
 * `No route: bad quote`, which is exactly what a real routing bug looks like.
 * DAI, BOLD and LUSD sat like that while quoting fine on mainnet, and the time
 * went into reading the swap path instead of the fixture.
 *
 * So this asserts the property directly: load the built preview, and quote
 * ETH into every token the registry lists.
 *
 * Usage:
 *   node script/build-zSwap-preview.mjs && node script/check-preview.mjs
 */
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { JSDOM } from 'jsdom';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const FILE = path.join(ROOT, 'dapp', 'preview', 'index.html');
if (!fs.existsSync(FILE)) {
  console.error('no preview built — run: node script/build-zSwap-preview.mjs');
  process.exit(1);
}

const registry = JSON.parse(fs.readFileSync(path.join(ROOT, 'script', 'fixtures', 'tokenlist.json'), 'utf8'))
  .map(r => JSON.parse(r.json));

const dom = new JSDOM(fs.readFileSync(FILE, 'utf8'), {
  runScripts: 'dangerously',
  pretendToBeVisual: true,
  url: 'https://preview.local/',
  beforeParse(w) {
    w.TextEncoder = TextEncoder;
    w.TextDecoder = TextDecoder;
    if (!w.crypto?.getRandomValues) {
      w.crypto = { getRandomValues: a => { for (let i = 0; i < a.length; i++) a[i] = (i * 7 + 11) & 255; return a; } };
    }
    w.matchMedia = w.matchMedia || (q => ({ matches: false, media: q, addEventListener() {}, removeEventListener() {} }));
  },
});
const w = dom.window;
const d = w.document;
const $ = id => d.getElementById(id);
const sleep = ms => new Promise(r => setTimeout(r, ms));
const until = async (fn, ms, label) => {
  const end = Date.now() + ms;
  while (Date.now() < end) { try { if (fn()) return true; } catch {} await sleep(60); }
  throw Error('timed out: ' + label);
};

await sleep(1200);
$('swap').click();
await until(() => $('addr').textContent !== 'Not connected', 15000, 'connect');
await sleep(500);

let failed = 0;
let checked = 0;
for (const t of registry) {
  if (t.s === 'ETH') continue;                       // the input side
  const opt = [...$('toSel').options].find(o => o.textContent === t.s);
  if (!opt) { console.log(`SKIP  ${t.s} — not offered in the dropdown`); continue; }
  if (opt.disabled) continue;
  checked++;
  try {
    const sel = $('toSel');
    sel.value = opt.value;
    sel.dispatchEvent(new w.Event('change', { bubbles: true }));
    await sleep(220);
    const amt = $('amt');
    amt.value = '1';
    amt.dispatchEvent(new w.Event('input', { bubbles: true }));
    await until(() => {
      const o = $('outAmt').value, s = $('stat').textContent;
      return (o && o !== '...') || /No route/i.test(s);
    }, 15000, 'quote ' + t.s);
    await sleep(100);
    const out = $('outAmt').value;
    if (!out || out === '...') {
      failed++;
      console.log(`FAIL  ETH -> ${t.s}: ${$('stat').textContent}`);
    } else {
      console.log(`ok    ETH -> ${t.s} = ${out}`);
    }
  } catch (e) {
    failed++;
    console.log(`FAIL  ETH -> ${t.s}: ${e.message}`);
  }
}
w.close();

console.log(`\n${checked - failed}/${checked} pairs quote in the preview`);
if (failed) {
  console.error('A pair that does not quote here reads as a contract bug. Add the token to');
  console.error('the USD table in script/build-zSwap-preview.mjs.');
  process.exit(1);
}
