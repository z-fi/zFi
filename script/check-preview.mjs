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
const until = async (fn, ms, label, step = 60) => {
  const end = Date.now() + ms;
  while (Date.now() < end) { try { if (fn()) return true; } catch {} await sleep(step); }
  throw Error('timed out: ' + label);
};

await sleep(1200);
$('swap').click();
await until(() => $('addr').textContent !== 'Not connected', 15000, 'connect');

/**
 * WAIT FOR THE LIST TO STOP MOVING.
 *
 * An option's value is an INDEX into TOKENS, and the registry's conviction
 * ranking lands after connect and rebuilds the whole dropdown - so an index
 * read before the rebuild names a different token after it. That is how this
 * script came to report "ETH -> USDC = 259,990" with a rate line that said
 * ZORG: the quote was real and correct, for the token the stale index actually
 * pointed at. Two identical readings of the option list, half a second apart.
 */
let sig = '';
await until(() => {
  const s = [...$('toSel').options].map(o => o.textContent).join(',');
  if (s && s === sig) return true;
  sig = s; return false;
}, 15000, 'token list settled', 500);

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
    // Belt and braces: confirm the page ended up on the token this iteration
    // is about, rather than trusting an index to still mean what it meant.
    await until(() => sel.options[sel.selectedIndex]?.textContent === t.s,
      5000, 'select ' + t.s);
    await sleep(220);
    const amt = $('amt');
    amt.value = '1';
    amt.dispatchEvent(new w.Event('input', { bubbles: true }));
    // CLEAR THE PREVIOUS ANSWER FIRST. The wait below returns as soon as the
    // output box is non-empty, and the box still holds the LAST token's quote
    // for as long as this one takes to run - so the wait returned instantly,
    // the page then blanked the field for the new quote, and the read 100ms
    // later saw "". That reported a token quoting perfectly well as a routing
    // failure, and only ever the token whose predecessor had been slow.
    // No event dispatched: writing this field is how exact-out is requested.
    $('outAmt').value = '';
    // ...and then wait for an answer that STAYS. Clearing the box is not enough
    // on its own: the previous token's quote can still be in flight, land in
    // the box after the clear, and satisfy a one-shot wait - and the new quote
    // blanks it again a moment later. Two equal, non-empty samples 400ms apart
    // is the difference between "a quote arrived" and "this token's quote
    // arrived", and it is the whole of the intermittency in this script.
    // WAIT FOR THIS TOKEN'S QUOTE, NOT FOR ANY QUOTE.
    //
    // The rate line names the token it priced, and that is the only reliable
    // signal that the answer on screen belongs to the pair under test. Waiting
    // for "the box is non-empty" instead picked up two different strangers: the
    // previous token's quote still in flight, and the page's own recovery -
    // when a quote fails it advances the output to the next ranked token and
    // quotes THAT, which lands a moment later under whatever is selected by
    // then. Both produced a real number for the wrong asset, which is a pass
    // that means nothing and a failure that means nothing either.
    await until(() => {
      const o = $('outAmt').value, s = $('stat').textContent;
      if (/No route/i.test(s)) return true;
      // The page may have moved the output itself while we waited - a failed
      // quote advances to the next ranked token. Put it back and ask again,
      // which is what a person watching this happen would do.
      if (sel.options[sel.selectedIndex]?.textContent !== t.s) {
        const again = [...sel.options].find(o2 => o2.textContent === t.s);
        if (!again || again.disabled) return false;
        sel.value = again.value;
        sel.dispatchEvent(new w.Event('change', { bubbles: true }));
        amt.value = '1';
        amt.dispatchEvent(new w.Event('input', { bubbles: true }));
        return false;
      }
      return o && o !== '...' && $('rate').textContent.includes(t.s);
    }, 15000, 'quote ' + t.s, 200);
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
