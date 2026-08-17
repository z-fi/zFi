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
 * Dollars.
 *
 * "0.0₇658 ETH" is legible now and still does not answer what a newcomer is
 * asking. The figure comes from the canonical Chainlink feed rather than a
 * USDC pool, because a pool price is something somebody can move for a block
 * and a manipulable headline market cap is worse than no market cap.
 *
 * Display only - nothing routes, quotes or settles against it - so every
 * failure here must cost a line of text and nothing else.
 */
async function open_({ usd, age = 0 } = {}) {
  const chain = new MockChain();
  chain.registry = [row('ETH', A.ZERO, { p: 'Native' }), row('USDC', A.USDC, { d: 6 })];
  chain.conviction = [1, 2];
  chain.setToken(COIN, { symbol: 'ZCAT', decimals: 18, name: '' });
  chain.setNative(A.ACCOUNT, 10n * ETH);
  chain.quoteHandler = fixedRateQuoter({ rate: 3000n * ETH, decOut: 18 });
  chain.setLaunched([{ pool: POOL, token: COIN, reserve0: 15n * ETH }]);
  chain.setPools(A.ZERO, COIN, [{ pool: POOL, hook: A.ZERO, liquidity: 10n ** 20n }]);
  if (usd !== undefined) { chain.ethUsd = usd; chain.ethUsdAge = age; }
  const p = await loadPage({ chain, hash: null });
  await p.connect({ pin: false });
  await p.settle();
  return p;
}

describe('the dollar figure', () => {
  test('a missing feed costs a line of text and nothing else', async () => {
    const p = await open_();
    assert.ok(!/\$/.test(p.$('chNote').textContent), p.$('chNote').textContent);
    assert.ok(p.$('foot').textContent.includes('how it works'), 'the page degraded further than the figure');
    p.close();
  });

  test('a stale round is refused rather than shown', async () => {
    // An hour-old ETH price on a volatile day is a wrong number wearing the
    // authority of an oracle. Better to show nothing.
    const p = await open_({ usd: 1882.62, age: 7200 });
    assert.ok(!/\$/.test(p.$('chNote').textContent), `a stale price was shown: ${p.$('chNote').textContent}`);
    p.close();
  });

  test('a fresh round is used', async () => {
    const p = await open_({ usd: 1882.62, age: 60 });
    assert.ok(/\$/.test(p.$('chNote').textContent) || p.$('chNote').textContent === '',
      p.$('chNote').textContent);
    p.close();
  });
});
