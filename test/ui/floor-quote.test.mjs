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
 * The floor, which the page had never shown.
 *
 * A launched coin can always be burned back to the launcher for its share of
 * the ether locked in its pool. That backing is the whole reason this
 * launchpad differs from every other one, and a seller could not see it - so
 * on a coin whose market had fallen below its own backing, they would sell
 * into the pool for less ether than the protocol was holding for them.
 */
async function open_({ floor = 0n, rate = 3000n * ETH, poolOut = 1n * ETH } = {}) {
  const chain = new MockChain();
  chain.registry = [row('ETH', A.ZERO, { p: 'Native' }), row('USDC', A.USDC, { d: 6 })];
  chain.conviction = [1, 2];
  chain.setToken(COIN, { symbol: 'ZCAT', decimals: 18, name: '' });
  chain.setNative(A.ACCOUNT, 10n * ETH);
  chain.setErc20(COIN, A.ACCOUNT, 1000n * ETH);
  chain.quoteHandler = fixedRateQuoter({ rate, decOut: 18 });
  chain.setLaunched([{ pool: POOL, token: COIN, reserve0: 15n * ETH }]);
  chain.setPools(A.ZERO, COIN, [{ pool: POOL, hook: A.ZERO, liquidity: 10n ** 20n }]);
  chain.precisionQuote = { pool: POOL, out: poolOut, fee: 3000, pair: [A.ZERO, COIN] };
  /* Per WHOLE TOKEN, because that is what `floorPrice` answers and what the
     page scales from - the sale below is of exactly 1 token, so the two
     coincide here by construction rather than by luck. */
  chain.floorPrice = floor;
  const p = await loadPage({ chain, hash: null });
  await p.connect({ pin: false });
  await p.settle();
  p.pickToken('toSel', 'USDC');
  p.pickToken('fromSel', 'ZCAT');
  p.pickToken('toSel', 'ETH');
  await p.typeAmount('amt', '1');
  return p;
}

describe('the floor under a launched coin', () => {
  test('is named when redeeming pays more than selling', async () => {
    const p = await open_({ floor: 5n * ETH, rate: ETH / 1000n });
    assert.match(p.$('rate').textContent, /Floor pays more/, p.$('rate').textContent);
    p.close();
  });

  test('is still shown, quietly, when selling wins', async () => {
    // A seller should learn the backing exists even when it is not the better
    // route today - it is the reason to hold rather than the reason to sell.
    const p = await open_({ floor: ETH / 1000n, rate: 3000n * ETH });
    const t = p.$('rate').textContent;
    assert.ok(/Floor /.test(t) && !/Floor pays more/.test(t), t);
    p.close();
  });

  test('says nothing for a coin with no backing', async () => {
    const p = await open_({ floor: 0n, rate: 3000n * ETH });
    assert.ok(!/Floor/.test(p.$('rate').textContent), p.$('rate').textContent);
    p.close();
  });
});
