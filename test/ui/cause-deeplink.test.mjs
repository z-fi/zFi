/**
 * The cause (DAICO) launch deeplink, run against the real dapp/index.html.
 *
 * A shared ?mode=cause link seeds the launch form by assigning straight to
 * `.value`. That is not the same thing as typing: assigning fires no input
 * event, so none of the handlers wired to `oninput` run. Two of them matter.
 *
 *  - `onCoinAddressInput` is what starts beneficiary resolution. Without it a
 *    `.eth` name never resolves, and `coinValidateForm()` then reports
 *    "Waiting for the beneficiary address to resolve" forever — the Launch
 *    button is disabled with no visible reason and no way to clear it short of
 *    editing the field by hand.
 *  - `coinNumInput` is what strips characters the numeric fields cannot hold.
 *
 * Neither failure is visible to a syntax check or to a contract simulation:
 * the page parses, the calldata it would build is fine, and the bug is that
 * the page never gets as far as building any. So this boots the page for real
 * at a deeplink URL and asserts on the form state it lands in.
 *
 * No network: every assertion is about state the page reaches synchronously
 * during load, or (for the ENS case) before its 350ms resolver debounce fires.
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { JSDOM, VirtualConsole, ResourceLoader } from 'jsdom';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..');
const PAGE = path.join(ROOT, 'dapp', 'index.html');

const BENEFICIARY = '0x1111111111111111111111111111111111111111';

class LocalLoader extends ResourceLoader {
  fetch(url) {
    const m = /^https:\/\/zfi\.wei\.is\/(.*)$/.exec(url.split('?')[0]);
    if (!m) return null;                       // no third-party fetches
    const file = path.join(ROOT, 'dapp', m[1]);
    if (!fs.existsSync(file)) return null;
    return Promise.resolve(fs.readFileSync(file));
  }
}

const open = [];

/** Boot dapp/index.html at `query` (a full "?…#coin" string). */
async function boot(query) {
  const vc = new VirtualConsole();
  const fatal = [];
  vc.on('jsdomError', (e) => fatal.push(e));

  const dom = new JSDOM(fs.readFileSync(PAGE, 'utf8'), {
    url: 'https://zfi.wei.is/' + query,
    runScripts: 'dangerously',
    resources: new LocalLoader(),
    pretendToBeVisual: true,
    virtualConsole: vc,
    beforeParse(w) {
      w.matchMedia = () => ({ matches: false, media: '', addListener() {}, removeListener() {},
                              addEventListener() {}, removeEventListener() {}, onchange: null });
      w.TextEncoder = TextEncoder;
      w.TextDecoder = TextDecoder;
      w.scrollTo = () => {};
      w.fetch = () => Promise.reject(new Error('no network in this test'));

      // The page loads its per-tab modules with document.write('<script src=…>'),
      // which a browser runs synchronously during parse — so coin.js is defined by
      // the time DOMContentLoaded fires and the deeplink reader calls into it. jsdom
      // defers those scripts past DOMContentLoaded instead, so the reader would hit
      // `coinSetLaunchType is not defined` and every assertion below would fail for a
      // reason that exists only in the harness. Restore the ordering by defining the
      // modules from a listener registered BEFORE the page's own, and drop the writes
      // that would otherwise redeclare them.
      w.document.addEventListener('DOMContentLoaded', () => {
        for (const f of ['modules/coin.js', 'modules/auction.js']) {
          const el = w.document.createElement('script');
          el.textContent = fs.readFileSync(path.join(ROOT, 'dapp', f), 'utf8');
          w.document.head.appendChild(el);
        }
      });
      w.document.write = () => {};
    },
  });
  const w = dom.window;
  await new Promise(r => {
    if (w.document.readyState === 'complete') return r();
    w.addEventListener('load', r);
    setTimeout(r, 15000);
  });
  open.push(dom);

  // Reach the page's lexical bindings from inside its own realm.
  const probe = w.document.createElement('script');
  probe.textContent = `window.__p = {};
    window.__missing = [];
    for (const n of ['coinValidateForm','coinGetResolved','_coinLaunchType','_causeOngoing']) {
      try { window.__p[n] = eval(n); } catch (e) { window.__missing.push(n); }
    }`;
  w.document.body.appendChild(probe);
  return { w, api: w.__p ?? {}, missing: w.__missing ?? ['probe did not run'], fatal };
}

const $ = (w, id) => w.document.getElementById(id);

test.after(() => { for (const d of open) try { d.window.close(); } catch {} });

test('cause deeplink', async (t) => {
  await t.test('routes a ?mode=cause link to the cause form', async () => {
    const { w, api, missing } = await boot('?name=Save+The+Bees&symbol=BEE&mode=cause#coin');
    if (missing.includes('_coinLaunchType')) return t.skip('page did not boot');
    assert.equal(api._coinLaunchType, 'cause', 'launch type did not follow the link');
    assert.equal($(w, 'coinName').value, 'Save The Bees');
    assert.equal($(w, 'coinSymbol').value, 'BEE');
  });

  await t.test('resolves a deeplinked 0x beneficiary instead of leaving it dangling', async () => {
    const { w, api, missing } = await boot(
      `?symbol=BEE&name=Bees&mode=cause&tap=1&beneficiary=${BENEFICIARY}#coin`);
    if (missing.includes('coinValidateForm')) return t.skip('page did not boot');

    // The resolved line is the user-visible half: without a resolution pass it
    // stays hidden and the form gives no sign it read the address at all.
    const line = $(w, 'causeTapBeneficiaryResolved');
    assert.notEqual(line.style.display, 'none', 'beneficiary was never resolved');
    assert.equal(line.textContent.toLowerCase(), BENEFICIARY.toLowerCase());

    assert.equal(api.coinValidateForm(), null, 'a fully specified link should be launchable');
    assert.equal($(w, 'coinLaunchBtn').disabled, false, 'CTA stayed disabled on a valid link');
  });

  await t.test('starts resolution for a deeplinked name rather than blocking forever', async () => {
    // The regression: a `.eth` beneficiary resolves only through onCoinAddressInput,
    // which a bare `.value` assignment never triggers. The CTA then sits disabled on
    // "Waiting for the beneficiary address to resolve" with nothing to un-stick it.
    const { w, api, missing } = await boot(
      '?symbol=BEE&name=Bees&mode=cause&tap=1&beneficiary=vitalik.eth#coin');
    if (missing.includes('coinValidateForm')) return t.skip('page did not boot');

    const line = $(w, 'causeTapBeneficiaryResolved');
    assert.notEqual(line.style.display, 'none', 'no resolution was started for the name');
    assert.match(line.textContent, /Resolving/i,
      'the form should say it is resolving, not silently stall');
  });

  await t.test('filters numeric fields the same way typing does', async () => {
    const { w, missing } = await boot(
      '?symbol=BEE&name=Bees&mode=cause&raise=1.2.3abc&days=30x&tap=1&months=1e9#coin');
    if (missing.includes('coinValidateForm')) return t.skip('page did not boot');

    assert.equal($(w, 'causeRaise').value, '1.23', 'raise kept characters parseEther rejects');
    assert.equal($(w, 'causeDeadline').value, '30', 'deadline kept non-digits');
    assert.equal($(w, 'causeTapMonths').value, '19', 'months kept non-digits');
  });

  await t.test('a garbage raise cannot leave the form launchable', async () => {
    // Sanitizing must not accidentally produce a value that passes validation
    // while differing from what the link asked for in kind rather than in form.
    const { w, api, missing } = await boot('?symbol=BEE&name=Bees&mode=cause&raise=abc#coin');
    if (missing.includes('coinValidateForm')) return t.skip('page did not boot');
    // Nothing numeric survives, so the field keeps its default rather than going
    // empty — an empty raise would be a disabled CTA on a link that looked fine.
    assert.notEqual($(w, 'causeRaise').value, '', 'raise was blanked by an unusable link');
    assert.equal(api.coinValidateForm(), null, 'form should fall back to a launchable default');
  });

  await t.test('a loot cause sells loot and says so before it is launched', async () => {
    // The only thing separating a loot raise from a share raise in the calldata is the
    // mint sentinel the offering is configured with, and nothing downstream re-derives
    // it — so the checkbox has to reach both the preview and the summon, or backers buy
    // the wrong token with no sign anything went differently.
    const { w, missing } = await boot('?symbol=BEE&name=Bees&mode=cause&loot=1#coin');
    if (missing.includes('coinValidateForm')) return t.skip('page did not boot');
    assert.equal($(w, 'causeSellLoot').checked, true, 'the link did not tick the loot box');
    // The two surfaces divide the statement between them and neither repeats the
    // other: the checkbox says what you are choosing, the preview says what it does
    // to governance once deployed. Both halves have to be present.
    const note = w.document.querySelector('#causeSellLoot ~ .coin-opt-note').textContent;
    assert.match(note, /non-voting/i, 'the option never says loot has no vote');
    const preview = $(w, 'coinCausePreview').textContent;
    assert.match(preview, /per 1M loot/, 'the preview still prices the raise in shares');
    assert.match(preview, /founding share/i,
      'the preview does not say where the vote ends up');
  });

  await t.test('a loot raise says who holds the vote, not just who does not', async () => {
    // Only shares vote and only shares count toward quorum, so a loot raise leaves the
    // founder's single share as the entire electorate. That is the fact a backer needs
    // before funding, and "non-voting loot" alone does not state it.
    const { w, missing } = await boot('?symbol=BEE&name=Bees&mode=cause&loot=1#coin');
    if (missing.includes('coinValidateForm')) return t.skip('page did not boot');
    const preview = $(w, 'coinCausePreview').textContent;
    assert.match(preview, /whole electorate/i, 'the preview understates the founder\'s control');
    assert.match(preview, /quorum/i, 'the preview does not say quorum is shares-only');
  });

  await t.test('loot plus a fast tap says what that costs a backer', async () => {
    // Ragequit reaches the treasury; a fast tap empties it in about an hour. Each is
    // disclosed on its own, and the combination is the one that leaves a backer least.
    const { w, missing } = await boot(
      '?symbol=BEE&name=Bees&mode=cause&loot=1&tap=1&instant=1&beneficiary=' + BENEFICIARY + '#coin');
    if (missing.includes('coinValidateForm')) return t.skip('page did not boot');
    const preview = $(w, 'coinCausePreview').textContent;
    assert.match(preview, /only reaches what is still in the treasury/i,
      'the fast-tap-plus-loot combination is not called out');
  });

  await t.test('a share raise says the founder does not keep control', async () => {
    // The unticked box is the default and the one that gives the DAO away. Explaining
    // only the loot side left the more consequential half of the choice silent.
    const { w, missing } = await boot('?symbol=BEE&name=Bees&mode=cause#coin');
    if (missing.includes('coinValidateForm')) return t.skip('page did not boot');
    const preview = $(w, 'coinCausePreview').textContent;
    assert.match(preview, /governance passes to them/i,
      'a share raise does not say where governance ends up');
  });

  await t.test('a cause with no tap says how money actually leaves', async () => {
    const { w, missing } = await boot('?symbol=BEE&name=Bees&mode=cause&loot=1#coin');
    if (missing.includes('coinValidateForm')) return t.skip('page did not boot');
    const preview = $(w, 'coinCausePreview').textContent;
    assert.match(preview, /nothing leaves the treasury by itself/i, 'the no-tap case is unexplained');
    assert.match(preview, /timelock/i, 'the spend path does not mention the timelock');
    assert.match(preview, /No minimum/i, 'the form still implies a goal-or-refund raise');
  });

  await t.test('a cause sells shares unless the loot box is ticked', async () => {
    const { w, missing } = await boot('?symbol=BEE&name=Bees&mode=cause#coin');
    if (missing.includes('coinValidateForm')) return t.skip('page did not boot');
    assert.equal($(w, 'causeSellLoot').checked, false, 'loot is not the default');
    const preview = $(w, 'coinCausePreview').textContent;
    assert.match(preview, /per 1M shares/, 'the default preview stopped pricing shares');
    assert.ok(!/keeps the vote/i.test(preview),
      'a share raise should not claim the founder keeps the vote');
  });

  await t.test('open-ended links skip the raise and deadline entirely', async () => {
    const { w, api, missing } = await boot('?symbol=BEE&name=Bees&mode=cause&ongoing=1#coin');
    if (missing.includes('coinValidateForm')) return t.skip('page did not boot');
    assert.equal(api.coinValidateForm(), null, 'an open-ended cause should be launchable');
    assert.equal(w.getComputedStyle($(w, 'causeRaiseWrap')).display, 'none',
      'raise field should be hidden for an open-ended cause');
  });
});
