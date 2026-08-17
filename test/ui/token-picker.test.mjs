/**
 * The token picker shows what the registry actually carries.
 *
 * A native <option> renders text and nothing else, so the logo, the name and
 * the blurb the registry serves for every listing had nowhere to go - the
 * picker was a list of ticker symbols sitting on top of a list that knows far
 * more than that.
 *
 * The <select> is still the source of truth. It keeps its value, keeps firing
 * change, and keeps working with JS off; the panel only reflects it and writes
 * back through it. That is what lets the rest of the page - and the rest of
 * this suite - stay unaware that any of this exists, and it is the property
 * most worth pinning, because the day it stops being true every read of
 * `fromSel.value` in the page becomes a guess.
 *
 * Run: node --test test/ui/
 */
import { test, describe, after } from 'node:test';
import assert from 'node:assert/strict';
import { A, MockChain, loadPage, fixedRateQuoter, closeAllPages } from './harness.mjs';

after(closeAllPages);

const ETH = 10n ** 18n;
// A 1x1 gif, which is all safeUrl needs to see to admit it.
const LOGO = 'data:image/gif;base64,R0lGODlhAQABAAAAACH5BAEKAAEALAAAAAABAAEAAAICTAEAOw==';

const row = (sym, addr, over = {}) => ({
  i: '1', c: 1, k: 'eip155', p: 'ERC-20', x: true, o: false, f: false,
  a: addr, n: `${sym} Token`, s: sym, d: 18, t: '#888', r: 1,
  u: '', au: '', l: LOGO, desc: `${sym} is a token the registry describes at length.`,
  e: [], v: true, ...over,
});
const ROWS = [
  row('ETH', A.ZERO, { p: 'Native', n: 'Ether', desc: 'The native asset.' }),
  row('WBTC', A.WBTC, { d: 8 }),
  row('USDC', A.USDC, { d: 6, n: 'USD Coin', desc: 'A dollar stablecoin issued by Circle.' }),
];

async function open(which = 'toSel', rows = ROWS) {
  const chain = new MockChain();
  chain.registry = rows;
  chain.conviction = rows.map((_, i) => i + 1);
  chain.setNative(A.ACCOUNT, 10n * ETH);
  chain.quoteHandler = fixedRateQuoter({ rate: 3000n * ETH });
  const page = await loadPage({ chain, hash: null });
  await page.connect({ pin: false });
  page.click(which === 'toSel' ? 'toPick' : 'fromPick');
  await page.settle();
  return page;
}

const rowsIn = page => [...page.$('tkList').querySelectorAll('.tkr')];
const symOf = r => r.querySelector('b')?.textContent;

describe('the token picker', () => {
  test('shows a token its OWN on-chain art, not just the registry logo', async () => {
  // The other half of the launcher's image feature, and the half nothing was
  // testing: the page stores the art and encodes the calldata, but for a long
  // while nothing ever READ `contractURI()` back - so an uploaded logo was
  // invisible in the very dapp that uploaded it.
  const PNG = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQdvt9AAAADElEQVQI12P4z8AAAAMBAQC1o38rAAAAAElFTkSuQmCC';
  const doc = JSON.stringify({ name: 'Zero Cat', symbol: 'ZCAT', description: '',
    image: 'data:image/png;base64,' + PNG });
  const TOK = '0x00000000000000000000000000000000000000aa';
  const chain = new MockChain();
  chain.contractURIs = { [TOK]: 'data:application/json;base64,' + Buffer.from(doc, 'utf8').toString('base64') };
  chain.setToken(TOK, { symbol: 'ZCAT', decimals: 18, name: 'Zero Cat' });
  chain.setNative(A.ACCOUNT, 10n * ETH);
  chain.quoteHandler = fixedRateQuoter({ rate: 3000n * ETH });
  const p = await loadPage({ chain, hash: null });
  await p.connect({ pin: false });

  p.queuePrompt(TOK);
  p.select('toSel', '__custom');
  await p.settle();
  p.click('toPick');
  await p.settle();

  const row = rowsIn(p).find(r => symOf(r) === 'ZCAT');
  assert.ok(row, 'the pasted token is not in the list');
  const img = row.querySelector('img');
  assert.ok(img, 'a token carrying its own art must render it');
  assert.ok(img.getAttribute('src').includes(PNG.slice(0, 40)), 'the bytes are not the ones on chain');
  // As an <img src>, never inlined. An SVG in an <img> cannot run script; the
  // same markup written into the DOM could, and this field is owner-controlled.
  assert.doesNotMatch(row.innerHTML, /<svg|<script/i, 'art must never be inlined');
  p.close();
});

test('opens as a bottom sheet on a touch screen, not an anchored dropdown', async () => {
  // On a phone the button is halfway up a screen held at the bottom, so an
  // anchored panel opens under the thumb, over the card, or off the side. The
  // sheet is placed by CSS against the viewport edge - so the job here is to
  // stop writing inline coordinates that would override it.
  const p = await loadPage({ chain: new MockChain() });
  p.window.matchMedia = q => ({ media: q, matches: /pointer:\s*coarse/.test(q),
    addEventListener() {}, removeEventListener() {}, addListener() {}, removeListener() {} });
  p.click('toPick');
  const st = p.$('tkPanel').style;
  assert.equal(st.top, '', 'a sheet must not carry an inline top');
  assert.equal(st.left, '', 'nor a left');
  assert.equal(st.maxHeight, '', 'nor a measured height');
  assert.ok(p.visible('tkPanel'), 'and it still opens');
  assert.equal(p.$('toPick').getAttribute('aria-expanded'), 'true');
  p.close();
});

test('hangs off the card, and opens downward', async () => {
  // Aligned to the BUTTON it drifted out of the card's column, and because the
  // old rule took whichever side was larger, a tall window always flipped it
  // upward - a list floating over empty space, joined to the control that
  // opened it by a gap. It belongs in the one column the eye is already in.
  const p = await loadPage({ chain: new MockChain() });
  p.doc.querySelector('.card').getBoundingClientRect =
    () => ({ left: 760, top: 310, right: 1240, bottom: 940, width: 480, height: 630 });
  p.$('toPick').getBoundingClientRect =
    () => ({ left: 1080, top: 640, bottom: 670, right: 1200, width: 120, height: 30 });
  Object.defineProperty(p.window, 'innerHeight', { value: 1253, configurable: true });
  Object.defineProperty(p.window, 'innerWidth', { value: 2000, configurable: true });
  Object.defineProperty(p.$('tkPanel'), 'scrollHeight', { value: 900, configurable: true });
  Object.defineProperty(p.$('tkPanel'), 'offsetHeight', { value: 900, configurable: true });
  p.click('toPick');
  const st = p.$('tkPanel').style;
  assert.equal(st.left, '760px', 'it should share the card\'s left edge');
  assert.equal(st.width, '480px', 'and the card\'s width');
  // 670 is the button's bottom, so anything above it means it flipped upward
  // in a window with ample room below - the direction nobody expects.
  assert.ok(parseFloat(st.top) > 670, `opened upward (top ${st.top}) with room below`);
  // Menu-sized, not stretched to fill whatever space exists. Writing an inline
  // max-height silently overrode the stylesheet's 32em, so on a tall window the
  // list grew to ~900px and swallowed the screen - at which point it stops
  // reading as a dropdown at all.
  assert.ok(parseFloat(st.maxHeight) <= 520, `${st.maxHeight} is a takeover, not a menu`);
  assert.ok(parseFloat(st.top) + parseFloat(st.maxHeight) < 1253, 'it runs off the bottom');
  p.close();
});

test('never opens above the top of the screen', async () => {
  // Flipping the panel above its button computed `b.top - h` with no floor, so
  // a list taller than the space above it started at a negative offset: the
  // first entries sat off the top of the viewport, unreachable and unscrollable
  // - on a real screen ETH was simply gone. Fit to the gap, then clamp.
  const p = await loadPage({ chain: new MockChain() });
  const btn = p.$('toPick');
  btn.getBoundingClientRect = () => ({ left: 900, top: 700, bottom: 730, right: 1000, width: 100, height: 30 });
  Object.defineProperty(p.window, 'innerHeight', { value: 760, configurable: true });
  Object.defineProperty(p.$('tkPanel'), 'scrollHeight', { value: 1400, configurable: true });
  Object.defineProperty(p.$('tkPanel'), 'offsetHeight', { value: 1400, configurable: true });
  p.click('toPick');
  const st = p.$('tkPanel').style;
  assert.ok(parseFloat(st.top) >= 8, `panel top is ${st.top}, which is off-screen`);
  // And it caps itself to the gap so the list scrolls inside rather than out.
  assert.ok(parseFloat(st.maxHeight) <= 700, `maxHeight ${st.maxHeight} exceeds the space above`);
  p.close();
});

test('shows the logo, the name and the description the registry serves', async () => {
    const p = await open();
    const usdc = rowsIn(p).find(r => symOf(r) === 'USDC');
    assert.ok(usdc, 'USDC should be listed');
    assert.equal(usdc.querySelector('img')?.getAttribute('src'), LOGO, 'the registry logo');
    assert.equal(usdc.querySelector('.tkn')?.textContent, 'USD Coin', 'the name beside the symbol');
    assert.match(usdc.querySelector('.tkd')?.textContent || '', /dollar stablecoin/,
      'the blurb the registry carries');
    p.close();
  });

  test('falls back to a generated mark when a listing has no logo', async () => {
    const p = await open('toSel', [ROWS[0], row('NOPIC', A.USDT, { l: '' })]);
    const r = rowsIn(p).find(x => symOf(x) === 'NOPIC');
    assert.ok(r.querySelector('svg'), 'a listing without a logo still gets an icon');
    assert.equal(r.querySelector('img'), null);
    p.close();
  });

  test('picking a row drives the select, which is still the source of truth', async () => {
    const p = await open();
    const before = p.$('toSel').value;
    const usdc = rowsIn(p).find(r => symOf(r) === 'USDC');
    p.click(usdc);
    await p.settle();

    const sel = p.$('toSel');
    assert.notEqual(sel.value, before, 'the select moved');
    assert.equal([...sel.options].find(o => o.value === sel.value)?.textContent, 'USDC');
    assert.equal(p.$('tkPanel').classList.contains('hide'), true, 'and the panel closed');
    assert.equal(p.$('toPick').querySelector('.tkbs').textContent, 'USDC', 'the button follows');
    p.close();
  });

  test('searching filters by symbol, by name and by address', async () => {
    const p = await open();
    const find = p.$('tkFind');
    const type = v => { find.value = v; find.dispatchEvent(new p.window.Event('input', { bubbles: true })); };

    type('usd');
    assert.deepEqual(rowsIn(p).map(symOf), ['USDC'], 'matches the name, not only the ticker');
    type(A.WBTC.slice(0, 12));
    assert.deepEqual(rowsIn(p).map(symOf), ['WBTC'], 'an address pasted in should find its token');
    type('nothinglikethis');
    assert.equal(rowsIn(p).length, 0);
    assert.match(p.$('tkList').textContent, /No token matches/i, 'and says so rather than going blank');
    p.close();
  });

  test('will not select the token already chosen on the other side', async () => {
    // syncDisabled() writes the disabled flags on the <option>s; the panel is
    // built from those options, so it inherits the rule instead of copying it.
    const p = await open();
    const from = [...p.$('fromSel').options].find(o => o.value === p.$('fromSel').value)?.textContent;
    const dupe = rowsIn(p).find(r => symOf(r) === from);
    assert.equal(dupe.getAttribute('aria-disabled'), 'true', `${from} is taken on the pay side`);

    const before = p.$('toSel').value;
    p.click(dupe);
    await p.settle();
    assert.equal(p.$('toSel').value, before, 'clicking it changes nothing');
    p.close();
  });

  test('escape closes it and leaves the pair alone', async () => {
    const p = await open();
    const before = p.$('toSel').value;
    p.$('tkPanel').dispatchEvent(new p.window.KeyboardEvent('keydown', { key: 'Escape', bubbles: true }));
    await p.settle();
    assert.equal(p.$('tkPanel').classList.contains('hide'), true);
    assert.equal(p.$('toSel').value, before);
    assert.equal(p.$('toPick').getAttribute('aria-expanded'), 'false');
    p.close();
  });

  test('keeps the description reachable after the choice is made', async () => {
    // Selecting is when the blurb LEAVES the screen, and the chosen row is
    // where someone goes to re-read what an unfamiliar ticker stands for.
    const p = await open();
    p.click(rowsIn(p).find(r => symOf(r) === 'USDC'));
    await p.settle();

    const pill = p.$('toPick').closest('.pill');
    assert.match(pill.title, /USDC — USD Coin/, 'names the asset, not just the ticker');
    assert.match(pill.title, /dollar stablecoin issued by Circle/, 'and carries the blurb');
    p.close();
  });

  test('shows no tooltip at all for a listing with nothing to say', async () => {
    // An empty tooltip is worse than none: it opens a blank box on hover and
    // reads as a rendering fault.
    const p = await open('toSel', [ROWS[0], row('BARE', A.USDT, { n: 'BARE', desc: '' })]);
    p.click(rowsIn(p).find(r => symOf(r) === 'BARE'));
    await p.settle();

    const pill = p.$('toPick').closest('.pill');
    assert.equal(pill.hasAttribute('title'), false, 'no title attribute, not an empty one');
    p.close();
  });

  test('lists every token, and scrolling the list does not close it', async () => {
    // The panel is anchored to a point on the page, so it closes when the page
    // scrolls under it - and that listener is in the capture phase, so it also
    // saw the list scrolling ITSELF and shut on the first wheel tick. The list
    // then looked truncated to whatever happened to fit on screen.
    const many = [ROWS[0], ...Array.from({ length: 12 }, (_, i) =>
      row(`TK${i}`, '0x' + String(i + 1).padStart(40, '0')))];
    const p = await open('toSel', many);

    const syms = rowsIn(p).map(symOf);
    for (const r of many) assert.ok(syms.includes(r.s), `${r.s} is missing from the panel`);
    // Plus two entries this fixture does not supply: the custom-token row,
    // which is an <option> like any other, and WETH - which the page keeps
    // whatever the registry says, because it cannot wrap, unwrap or pay a
    // native pool without it. Neither is a listing, so neither is optional.
    assert.ok(syms.includes('WETH'), 'the wrapper must survive a registry that omits it');
    assert.equal(syms.length, many.length + 2, 'every listing is rendered, not a visible subset');
    assert.ok(syms.some(x => /Custom token/i.test(x)));

    const list = p.$('tkList');
    list.dispatchEvent(new p.window.Event('scroll', { bubbles: true }));
    await p.settle();
    assert.equal(p.$('tkPanel').classList.contains('hide'), false,
      'scrolling the list is "still reading", not "dismiss"');

    // The page scrolling under it still dismisses it.
    p.window.document.dispatchEvent(new p.window.Event('scroll', { bubbles: true }));
    await p.settle();
    assert.equal(p.$('tkPanel').classList.contains('hide'), true,
      'a panel pinned to a stale position must not linger');
    p.close();
  });

  test('each side remembers which ASSET it is on, however it got there', async () => {
    /**
     * `restorePair` re-points a side that moved during a token-list load by
     * reading `dataset.addr` off the select. That stamp was written in exactly
     * one place - the change handler - so it recorded the last choice made BY
     * HAND rather than the current selection, and every programmatic move left
     * it behind: `flip` swaps the two values and leaves each stamp naming the
     * token now on the OTHER side.
     *
     * A list landing after that re-points the pair at a token nobody selected.
     * The invariant is the fix, so the invariant is what this asserts.
     */
    const p = await open();
    const addrOf = which => (p.$(which).dataset.addr || '').toLowerCase();
    const selectedAddr = which => {
      const sym = p.$(which).selectedOptions[0].textContent;
      return (ROWS.find(r => r.s === sym)?.a || '').toLowerCase();
    };
    const agrees = where => {
      for (const which of ['fromSel', 'toSel'])
        assert.equal(addrOf(which), selectedAddr(which), `${which} after ${where}`);
    };
    p.pickToken('toSel', 'WBTC');
    await p.settle();
    agrees('a deliberate pick');
    p.click('flip');
    await p.settle();
    agrees('a flip');
    p.pickToken('fromSel', 'USDC');
    await p.settle();
    agrees('a pick on the other side');
    p.click('flip');
    await p.settle();
    agrees('a second flip');
    p.close();
  });

  test('the native select survives, so nothing downstream has to know', async () => {
    const p = await open();
    const sel = p.$('toSel');
    assert.ok(sel, 'the <select> is still in the document');
    assert.ok(sel.options.length > 1, 'still carrying its options');
    // The path every existing test and every page read uses.
    p.pickToken('toSel', 'WBTC');
    await p.settle();
    assert.equal([...sel.options].find(o => o.value === sel.value)?.textContent, 'WBTC');
    assert.equal(p.$('toPick').querySelector('.tkbs').textContent, 'WBTC',
      'and the button reflects a change it did not make');
    p.close();
  });
});
