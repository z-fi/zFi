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
