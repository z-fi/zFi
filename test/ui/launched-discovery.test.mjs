import { test, describe } from 'node:test';
import assert from 'node:assert/strict';
import { A, MockChain, loadPage, fixedRateQuoter, closeAllPages } from './harness.mjs';

const ETH = 10n ** 18n;
const COIN_A = '0x00000000000000000000000000000000000c0a01';
const COIN_B = '0x00000000000000000000000000000000000c0a02';
const POOL_A = '0x00000000000000000000000000000000000b0001';
const POOL_B = '0x00000000000000000000000000000000000b0002';

const row = (s, a, o = {}) => ({
  i: '1', c: 1, k: 'eip155', p: 'ERC-20', x: true, o: false, f: false,
  a, n: `${s} Token`, s, d: 18, t: '#888', r: 1, u: '', au: '', l: '', desc: '', e: [], v: true, ...o,
});

/**
 * A coin minted here is tradeable from its first block, but for a while the
 * only way to REACH one in this page was to paste its address — the launch
 * added it to the creator's own browser and to nobody else's. So the person who
 * made it could see it and the people they told could not, which is most of the
 * value of "launch and you have a market".
 *
 * The factory indexes pools by creator, and a launched pool's creator IS the
 * launcher, so one call enumerates every one of them.
 */
const PNG = 'data:image/png;base64,iVBORw0KGgo=';

async function open_({ launched = true, connect = false, art = true } = {}) {
  const rows = [row('ETH', A.ZERO, { p: 'Native' }), row('USDC', A.USDC, { d: 6 })];
  const chain = new MockChain();
  chain.registry = rows;
  chain.conviction = rows.map((_, i) => i + 1);
  chain.setToken(COIN_A, { symbol: 'ZCAT', decimals: 18, name: 'Zero Cat' });
  chain.setToken(COIN_B, { symbol: 'BORGZ', decimals: 18, name: 'borgz' });
  chain.setNative(A.ACCOUNT, 10n * ETH);
  chain.quoteHandler = fixedRateQuoter({ rate: 3000n * ETH });
  if (launched) {
    chain.setLaunched([{ pool: POOL_A, token: COIN_A }, { pool: POOL_B, token: COIN_B }]);
    // Only COIN_A carries art, so one assertion covers the fallback too.
    if (art) chain.contractURIs = {
      [COIN_A]: 'data:application/json;base64,' + Buffer.from(JSON.stringify(
        { name: 'Zero Cat', symbol: 'ZCAT', image: PNG })).toString('base64'),
    };
  }
  const p = await loadPage({ chain, hash: null });
  if (connect) await p.connect({ pin: false });
  await p.settle();
  return p;
}

const rowFor = (p, sym) => [...p.$('tkList').querySelectorAll('.tkr')]
  .find(r => (r.textContent || '').includes(sym));
const optFor = (p, sym) => [...p.$('toSel').options].find(o => o.textContent === sym);
const syms = p => [...p.$('toSel').options].map(o => o.textContent);
const groups = p => [...p.$('toSel').querySelectorAll('optgroup')].map(g => g.label);

describe('launched coins are findable', () => {
  test('appear in the picker without being listed', async () => {
    const p = await open_({ connect: true });
    assert.ok(syms(p).includes('ZCAT'), 'a launched coin is missing from the picker');
    assert.ok(syms(p).includes('BORGZ'), 'a launched coin is missing from the picker');
    p.close();
  });

  test('are reachable with no wallet connected', async () => {
    // The state a shared link lands in. `eth_call` needs no account, so there
    // is no reason a visitor should see fewer coins than the creator does.
    const p = await open_({ connect: false });
    assert.ok(syms(p).includes('ZCAT'), 'not enumerated before connecting');
    p.close();
  });

  test('sit in their own group, below the curated list', async () => {
    // zList decides what is RANKED. This only decides what is REACHABLE, which
    // is a much weaker claim, and the label has to say so — otherwise a coin
    // minted five minutes ago shares a visual space with USDC.
    const p = await open_({ connect: true });
    const g = groups(p);
    assert.ok(g.some(x => /Launched on zSwap/.test(x)), `no launched group, got ${JSON.stringify(g)}`);
    assert.ok(g.some(x => /not curated/i.test(x)), 'the group must not imply curation');
    const all = syms(p);
    assert.ok(all.indexOf('USDC') < all.indexOf('ZCAT'), 'curated entries must come first');
    p.close();
  });

  test('a registry entry is never duplicated by the launched sweep', async () => {
    // A coin can be launched here AND listed later. It must appear once, in the
    // curated group, not twice.
    const rows = [row('ETH', A.ZERO, { p: 'Native' }), row('ZCAT', COIN_A)];
    const chain = new MockChain();
    chain.registry = rows;
    chain.conviction = [1, 2];
    chain.setToken(COIN_A, { symbol: 'ZCAT', decimals: 18, name: 'Zero Cat' });
    chain.setNative(A.ACCOUNT, 10n * ETH);
    chain.quoteHandler = fixedRateQuoter({ rate: 3000n * ETH });
    chain.setLaunched([{ pool: POOL_A, token: COIN_A }]);
    const p = await loadPage({ chain, hash: null });
    await p.connect({ pin: false });
    await p.settle();
    assert.equal(syms(p).filter(s => s === 'ZCAT').length, 1, 'listed and launched showed twice');
    p.close();
  });

  test('a factory that cannot be read costs nothing else', async () => {
    // Enumeration is a convenience. If it fails, the curated list must still
    // load — this read must never be able to take the token list down with it.
    const p = await open_({ launched: false, connect: true });
    assert.ok(syms(p).includes('USDC'), 'the curated list did not survive');
    assert.ok(!groups(p).some(x => /Launched/.test(x)), 'an empty sweep should add no group');
    p.close();
  });

  /* The creator pays real gas to put a logo on chain - SSTORE2, as contract
   * code - and the first build of this read the symbol and threw the art away,
   * so every launched coin rendered as the same grey initial. What was uploaded
   * is what should show. */
  test('an uploaded logo is what the picker shows', async () => {
    const p = await open_({ connect: true });
    p.click('toPick');
    const r = rowFor(p, 'ZCAT');
    assert.ok(r, 'the coin left the picker');
    const img = r.querySelector('img');
    assert.ok(img, 'rendered a generated initial instead of the uploaded logo');
    assert.equal(img.getAttribute('src'), PNG, 'a different image than was stored');
    p.close();
  });

  test('a coin with no art still gets an initial, not a gap', async () => {
    const p = await open_({ connect: true });
    p.click('toPick');
    const r = rowFor(p, 'BORGZ');
    assert.ok(r, 'a token without art fell out of the list');
    assert.ok(!r.querySelector('img'), 'invented art for a token that has none');
    assert.ok(r.querySelector('svg'), 'no fallback mark at all');
    p.close();
  });

  test('two coins sharing a ticker are told apart', async () => {
    // Nothing stops two people minting the same symbol, and several already
    // have. Repeated identically, the list reads as one coin duplicated.
    const chain = new MockChain();
    chain.registry = [row('ETH', A.ZERO, { p: 'Native' })];
    chain.conviction = [1];
    chain.setToken(COIN_A, { symbol: 'BORGZ', decimals: 18, name: 'borgz' });
    chain.setToken(COIN_B, { symbol: 'BORGZ', decimals: 18, name: 'borgz' });
    chain.setNative(A.ACCOUNT, 10n * ETH);
    chain.quoteHandler = fixedRateQuoter({ rate: 3000n * ETH });
    chain.setLaunched([{ pool: POOL_A, token: COIN_A }, { pool: POOL_B, token: COIN_B }]);
    const p = await loadPage({ chain, hash: null });
    await p.connect({ pin: false });
    await p.settle();
    const both = syms(p).filter(s => s.startsWith('BORGZ'));
    assert.equal(both.length, 2, `expected both, got ${JSON.stringify(both)}`);
    assert.notEqual(both[0], both[1], 'two different coins render identically');
    assert.ok(both.some(s => s.includes(COIN_B.slice(2, 6))), 'no address to tell them apart');
    p.close();
  });

  /* The factory's creator index is append-ordered, so a fixed slice from zero
   * returns the OLDEST markets. At 24 launches that quietly stopped showing
   * new ones - with nothing on screen to say anything was missing. There were
   * 23 the day this was written. */
  test('a new launch past the cap still appears', async () => {
    const many = Array.from({ length: 40 }, (_, i) => ({
      pool: '0x' + String(i + 1).padStart(40, '0'),
      token: '0x' + String(i + 1).padStart(39, '0') + 'a',
      // Ascending depth, so the NEWEST are also the deepest here.
      reserve0: BigInt(i + 1) * ETH,
    }));
    const chain = new MockChain();
    chain.registry = [row('ETH', A.ZERO, { p: 'Native' })];
    chain.conviction = [1];
    for (const m of many) chain.setToken(m.token, { symbol: 'C' + m.reserve0 / ETH, decimals: 18, name: '' });
    chain.setNative(A.ACCOUNT, 10n * ETH);
    chain.quoteHandler = fixedRateQuoter({ rate: 3000n * ETH });
    chain.setLaunched(many);
    const p = await loadPage({ chain, hash: null });
    await p.connect({ pin: false });
    await p.settle();
    const all = syms(p);
    assert.ok(all.includes('C40'), 'the newest launch was invisible');
    assert.ok(all.includes('C39'), 'the second newest was invisible');
    p.close();
  });

  /* Ranking is what makes a cap defensible: what falls off the end should be
   * the emptiest markets, not the newest ones. */
  test('the deepest markets are the ones shown, and shown first', async () => {
    const mk = (i, depth) => ({
      pool: '0x' + String(i).padStart(40, '0'),
      token: '0x' + String(i).padStart(39, '0') + 'a',
      reserve0: depth,
    });
    // A deep market launched FIRST, so ordering cannot be an accident of age.
    const many = [mk(1, 900n * ETH), ...Array.from({ length: 30 }, (_, i) => mk(i + 2, BigInt(i + 1)))];
    const chain = new MockChain();
    chain.registry = [row('ETH', A.ZERO, { p: 'Native' })];
    chain.conviction = [1];
    chain.setToken(many[0].token, { symbol: 'DEEP', decimals: 18, name: '' });
    for (const m of many.slice(1)) chain.setToken(m.token, { symbol: 'T' + m.reserve0, decimals: 18, name: '' });
    chain.setNative(A.ACCOUNT, 10n * ETH);
    chain.quoteHandler = fixedRateQuoter({ rate: 3000n * ETH });
    chain.setLaunched(many);
    const p = await loadPage({ chain, hash: null });
    await p.connect({ pin: false });
    await p.settle();
    const all = syms(p);
    assert.ok(all.includes('DEEP'), 'the deepest market was dropped');
    // The shallowest are what got cut, not the deepest.
    assert.ok(!all.includes('T1'), 'an empty market outranked a deep one');
    const launched = all.filter(x => x === 'DEEP' || /^T\d+$/.test(x));
    assert.equal(launched[0], 'DEEP', `deepest not first: ${launched.slice(0, 3)}`);
    p.close();
  });

  /* A row has to answer two questions a bare ticker cannot: can I trade this,
   * and whose is it. Five identical BORGZ rows answer neither. */
  test('a row shows its depth and its creator', async () => {
    const chain = new MockChain();
    chain.registry = [row('ETH', A.ZERO, { p: 'Native' })];
    chain.conviction = [1];
    chain.setToken(COIN_A, { symbol: 'ZCAT', decimals: 18, name: '' });
    chain.setNative(A.ACCOUNT, 10n * ETH);
    chain.quoteHandler = fixedRateQuoter({ rate: 3000n * ETH });
    chain.setLaunched([{ pool: POOL_A, token: COIN_A, reserve0: 15021300000000000000n }]);
    chain.creatorOfAnswer = '0x00000000000000000000000000000000deadbeef';
    const p = await loadPage({ chain, hash: null });
    await p.connect({ pin: false });
    await p.settle();
    p.click('toPick');
    const r = rowFor(p, 'ZCAT');
    assert.match(r.textContent, /15\.021 ETH liquidity/, r.textContent);
    assert.match(r.textContent, /by 0x0000/, r.textContent);
    p.close();
  });

  test('an empty market says so rather than showing a blank', async () => {
    const chain = new MockChain();
    chain.registry = [row('ETH', A.ZERO, { p: 'Native' })];
    chain.conviction = [1];
    chain.setToken(COIN_A, { symbol: 'ZCAT', decimals: 18, name: '' });
    chain.setNative(A.ACCOUNT, 10n * ETH);
    chain.quoteHandler = fixedRateQuoter({ rate: 3000n * ETH });
    chain.setLaunched([{ pool: POOL_A, token: COIN_A, reserve0: 0n }]);
    const p = await loadPage({ chain, hash: null });
    await p.connect({ pin: false });
    await p.settle();
    p.click('toPick');
    assert.match(rowFor(p, 'ZCAT').textContent, /no liquidity yet/, 'an empty pool looked identical to a deep one');
    p.close();
  });
});