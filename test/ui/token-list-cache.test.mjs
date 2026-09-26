/**
 * The list a visitor sees first is the list the network will confirm.
 *
 * The page paints before the registry answers, and for three seconds that was
 * the built-in list: then zList landed, the landing pair moved, every icon was
 * swapped for the registry's art, and the picker reordered under the cursor.
 * The registry's answer cannot be known before it arrives - but on every
 * visit after the first it is almost always the answer it gave last time. So
 * the last good list is kept per chain and painted at once, and the live read
 * replaces it quietly.
 *
 * The same suite pins search order and imported-symbol disambiguation, which
 * are what decide whether the picker finds the right token.
 *
 * Run: node --test test/ui/
 */
import { test, describe, after } from 'node:test';
import assert from 'node:assert/strict';
import { A, MockChain, loadPage, fixedRateQuoter, closeAllPages } from './harness.mjs';

after(closeAllPages);

const ETH = 10n ** 18n;
const LOGO = 'data:image/gif;base64,R0lGODlhAQABAAAAACH5BAEKAAEALAAAAAABAAEAAAICTAEAOw==';
const row = (sym, addr, over = {}) => ({
  i: '1', c: 1, k: 'eip155', p: 'ERC-20', x: true, o: false, f: false,
  a: addr, n: `${sym} Token`, s: sym, d: 18, t: '#888', r: 1,
  u: '', au: '', l: LOGO, desc: '', e: [], v: true, ...over,
});
const ROWS = [
  row('ETH', A.ZERO, { p: 'Native', n: 'Ether' }),
  row('WBTC', A.WBTC, { d: 8, n: 'Wrapped Bitcoin' }),
  row('USDC', A.USDC, { d: 6, n: 'USD Coin' }),
];

function chainWith(registry) {
  const chain = new MockChain();
  chain.registry = registry;
  if (registry) chain.conviction = registry.map((_, i) => i + 1);
  chain.setNative(A.ACCOUNT, 10n * ETH);
  chain.quoteHandler = fixedRateQuoter({ rate: 3000n * ETH });
  return chain;
}

const symIn = (p, id) => p.$(id).selectedOptions[0]?.textContent.trim();
const rowsIn = p => [...p.$('tkList').querySelectorAll('.tkr')];
const symOf = r => r.querySelector('b')?.textContent;
const search = (p, q) => {
  const f = p.$('tkFind');
  f.value = q;
  f.dispatchEvent(new p.window.Event('input', { bubbles: true }));
};

describe('the last good list', () => {
  test('is kept, and painted on the next visit without waiting for the registry', async () => {
    const first = await loadPage({ chain: chainWith(ROWS), hash: null });
    await first.settle();
    const kept = first.window.localStorage.getItem('zswap:list');
    assert.ok(kept, 'the live list was not kept');
    const landed = [symIn(first, 'fromSel'), symIn(first, 'toSel')];
    first.close();

    // The registry is unreachable this time: whatever zList shows came from
    // the kept copy, and it must be the same list and the same pair.
    const again = await loadPage({ chain: chainWith(null), hash: null, storage: { 'zswap:list': kept } });
    await again.settle();
    const syms = [...again.$('fromSel').options].map(o => o.textContent.trim());
    assert.ok(syms.includes('WBTC') && syms.includes('USDC'), `kept list not painted: ${syms}`);
    assert.deepEqual([symIn(again, 'fromSel'), symIn(again, 'toSel')], landed,
      'the landing pair moved even though the list did not');
    assert.match(again.text('listNote'), /last seen/, 'a stale list should say so');
    again.click('toPick');
    await again.settle();
    assert.match(again.$('tkList').textContent, /zList/, 'the kept list is still zList');
    again.close();
  });

  test('with nothing kept, the first paint ranks the built-in list the way zList does', async () => {
    // No kept copy and no registry: the pair painted is the built-in list's
    // own ranked top. It is ordered like zList, so a first visit lands where
    // the registry will send it instead of on a stablecoin it then leaves.
    // Read the pair as painted, before the list load can move it.
    const BOOT = 'applyLink();\nloadTokenList().then(()=>{';
    const p = await loadPage({ chain: chainWith(null), hash: null, patch: [[BOOT,
      'window.__painted=[fromSel,toSel].map(s=>TOKENS[s.value].sym);' + BOOT]] });
    await p.settle();
    assert.deepEqual([...p.window.__painted], ['ETH', 'wstETH'], 'the first paint is not the ranked pair');
    assert.deepEqual([symIn(p, 'fromSel'), symIn(p, 'toSel')], ['ETH', 'wstETH']);
    p.close();
  });

  test('is replaced by the live one when the registry answers', async () => {
    const stale = JSON.stringify({ f: 0, r: [JSON.stringify(ROWS[0]), JSON.stringify(ROWS[1])] });
    const p = await loadPage({ chain: chainWith(ROWS), hash: null, storage: { 'zswap:list': stale } });
    await p.settle();
    const syms = [...p.$('fromSel').options].map(o => o.textContent.trim());
    assert.ok(syms.includes('USDC'), 'the live list should replace the kept one');
    assert.equal(p.text('listNote'), '', 'a refreshed list needs no note');
    assert.equal(JSON.parse(p.window.localStorage.getItem('zswap:list')).r.length, 3);
    p.close();
  });

  test('is read through the same checks as the live one', async () => {
    // A kept row for another chain, one with an absurd decimals, and garbage.
    const bad = JSON.stringify({ f: 0, r: [
      JSON.stringify(row('EVIL', A.WBTC, { c: 8453 })),
      JSON.stringify(row('HUGE', A.USDC, { d: 99 })),
      '{not json', 42, null,
    ] });
    const p = await loadPage({ chain: chainWith(null), hash: null, storage: { 'zswap:list': bad } });
    await p.settle();
    const syms = [...p.$('fromSel').options].map(o => o.textContent.trim());
    assert.ok(!syms.includes('EVIL') && !syms.includes('HUGE'), `bad kept rows admitted: ${syms}`);
    assert.ok(syms.includes('USDC'), 'with nothing usable kept, the built-in list stands');
    p.close();
  });
});

describe('search', () => {
  async function picker(storage = {}) {
    const p = await loadPage({ chain: chainWith(ROWS), hash: null, storage });
    await p.connect({ pin: false });
    p.click('toPick');
    await p.settle();
    return p;
  }

  test('ranks a name-word match above a loose one, and Enter takes the top', async () => {
    const p = await picker();
    search(p, 'c');
    // USDC's name has a word starting "c" (Coin); WBTC only contains one.
    assert.deepEqual(rowsIn(p).map(symOf).slice(0, 2), ['USDC', 'WBTC']);
    p.$('tkPanel').dispatchEvent(new p.window.KeyboardEvent('keydown', { key: 'Enter', bubbles: true }));
    await p.settle();
    assert.equal(symIn(p, 'toSel'), 'USDC');
    p.close();
  });

  test('does not match a letter against every address', async () => {
    const p = await picker();
    search(p, 'f');
    assert.equal(rowsIn(p).length, 0, `matched by address hex: ${rowsIn(p).map(symOf)}`);
    search(p, '0x2260f');
    assert.deepEqual(rowsIn(p).map(symOf), ['WBTC'], 'an address prefix should still find it');
    p.close();
  });

  test('an imported token that shares a listed symbol is told apart', async () => {
    const SPOOF = '0x00000000000000000000000000000000000c0ffe';
    const p = await picker({ 'zswap:custom': JSON.stringify([{ sym: 'USDC', addr: SPOOF, dec: 6, std: 'ft' }]) });
    search(p, 'usdc');
    const syms = rowsIn(p).map(symOf);
    assert.equal(syms[0], 'USDC', 'the listed one comes first');
    assert.ok(syms.some(s => /^USDC 0x0000…$/.test(s)), `imported twin not suffixed: ${syms}`);
    p.close();
  });
});
