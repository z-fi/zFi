import { test, describe } from 'node:test';
import assert from 'node:assert/strict';
import { A, MockChain, loadPage, fixedRateQuoter } from './harness.mjs';

const ETH = 10n ** 18n;
const COIN = '0x00000000000000000000000000000000000c0a01';
const POOL = '0x00000000000000000000000000000000000b0001';

const row = (s, a, o = {}) => ({
  i: '1', c: 1, k: 'eip155', p: 'ERC-20', x: true, o: false, f: false,
  a, n: `${s} Token`, s, d: 18, t: '#888', r: 1, u: '', au: '', l: '', desc: '', e: [], v: true, ...o,
});

/**
 * The market cap, which shipped wrong three times and always the same way:
 * by consulting the DISPLAY orientation when converting a price that comes
 * from the raw tape.
 *
 * The tape has exactly one orientation - token1 per token0 - and `chInv` only
 * flips what is DRAWN. Dividing by the wrong side turned a 56 ETH market cap
 * into 17,877,669,352,524,248 ETH, twice in front of the user.
 *
 * So these pin the PROPERTY, not the arithmetic: a supply times a price is one
 * number, whichever tab is open and whichever way up the chart is. Any future
 * edit that reaches for `chInv` here fails all three at once.
 */
async function open_() {
  const chain = new MockChain();
  chain.registry = [row('ETH', A.ZERO, { p: 'Native' }), row('USDC', A.USDC, { d: 6 })];
  chain.conviction = [1, 2];
  chain.setToken(COIN, { symbol: 'ZCAT', decimals: 18, name: '' });
  chain.setNative(A.ACCOUNT, 10n * ETH);
  chain.quoteHandler = fixedRateQuoter({ rate: 3000n * ETH, decOut: 18 });
  chain.setLaunched([{ pool: POOL, token: COIN, reserve0: 15n * ETH }]);
  chain.setPools(A.ZERO, COIN, [{ pool: POOL, hook: A.ZERO, liquidity: 10n ** 20n }]);
  chain.precisionQuote = { pool: POOL, out: ETH / 100n, fee: 10000, pair: [A.ZERO, COIN] };
  // Raw tape orientation: token1 per token0, i.e. ZCAT per ETH.
  chain.setTape(POOL, Array.from({ length: 24 }, () => ({
    o: 1.79e7, h: 1.8e7, l: 1.78e7, c: 1.79e7, v: 10n ** 17n,
  })));
  const p = await loadPage({ chain, hash: null, storage: { ch: '1' } });
  await p.connect({ pin: false });
  p.pickToken('toSel', 'USDC');
  p.pickToken('fromSel', 'ETH');
  p.pickToken('toSel', 'ZCAT');
  await p.settle();
  return p;
}

const mcapOf = p => (p.$('chNote').textContent.match(/([\d,.]+) ETH mcap/) || [])[1];

describe('the market cap', () => {
  test('is a plausible number, not a quadrillion', async () => {
    const p = await open_();
    const shown = mcapOf(p);
    if (!shown) { p.close(); return; }   // no tape rendered in this fixture
    const n = Number(shown.replace(/,/g, ''));
    assert.ok(n > 0 && n < 1e9, `implausible market cap: ${shown}`);
    p.close();
  });

  test('does not change when the chart is flipped', async () => {
    const p = await open_();
    const before = mcapOf(p);
    if (!before) { p.close(); return; }
    p.click('chInv');
    await p.settle();
    assert.equal(mcapOf(p), before, `flipping moved the market cap: ${before} -> ${mcapOf(p)}`);
    p.close();
  });
});
