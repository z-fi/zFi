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
 * Price-impact protection for a coin no other venue quotes.
 *
 * The reference used to be a tiny quote through the hub router, and the hub
 * has no route for a token that lives only in a Precision pool - which is
 * every coin launched here. `imp` came back null and all three guardrails sat
 * behind `imp !== null`, so the thinnest pools on the platform were the only
 * ones with no protection whatsoever.
 *
 * A real user bought 89% of a pool's token reserve at +656% impact and the
 * page said nothing.
 */
async function open_({ big = 3000n * ETH, small = 40n * ETH } = {}) {
  const chain = new MockChain();
  chain.registry = [row('ETH', A.ZERO, { p: 'Native' }), row('USDC', A.USDC, { d: 6 })];
  chain.conviction = [1, 2];
  chain.setToken(COIN, { symbol: 'ZCAT', decimals: 18, name: '' });
  chain.setNative(A.ACCOUNT, 100n * ETH);
  /* The hub must answer for ordinary pairs and NOTHING for ZCAT - that
     absence is the entire condition being tested, and a fixture whose router
     quotes everything cannot reach the fallback at all. */
  const hub = fixedRateQuoter({ rate: 3000n * ETH, decOut: 18 });
  chain.quoteHandler = (req) => {
    if (String(req.data || '').toLowerCase().includes(COIN.slice(2).toLowerCase())) return null;
    return hub(req);
  };
  chain.setLaunched([{ pool: POOL, token: COIN, reserve0: 15n * ETH }]);
  chain.setPools(A.ZERO, COIN, [{ pool: POOL, hook: A.ZERO, liquidity: 10n ** 20n }]);
  /* Size-dependent, which is what makes impact measurable: the reference
     quote is 1/100th of the trade, so a pool that pays proportionally MORE on
     the small quote is a pool the big trade is moving. */
  chain.precisionQuote = { pool: POOL, out: big, small, fee: 10000, pair: [A.ZERO, COIN] };
  const p = await loadPage({ chain, hash: null });
  await p.connect({ pin: false });
  p.pickToken('toSel', 'USDC');
  p.pickToken('fromSel', 'ETH');
  p.pickToken('toSel', 'ZCAT');
  await p.typeAmount('amt', '1');
  return p;
}

describe('impact on a coin nothing else quotes', () => {
  test('is measured at all', async () => {
    // 1 ETH gets 3,000 but 0.01 ETH gets 40 — i.e. 4,000 per ETH at the
    // margin. The trade is 25% worse than the marginal price.
    const p = await open_();
    const t = p.$('rate').textContent + ' ' + p.$('stat').textContent;
    assert.match(t, /Impact/, `no impact shown for a Precision-only coin: ${t}`);
    p.close();
  });

  test('a violent trade is called out loudly, not in grey text', async () => {
    // The shape of the real incident: the marginal price is many times better
    // than what the trade executes at.
    const p = await open_({ big: 1000n * ETH, small: 80n * ETH });
    assert.match(p.$('stat').textContent, /High price impact/, p.$('stat').textContent);
    p.close();
  });

  test('a shallow trade stays quiet', async () => {
    // Guardrails that fire on everything get ignored. 1% must not shout.
    const p = await open_({ big: 3000n * ETH, small: 30n * ETH + 3n * ETH / 10n });
    assert.ok(!/High price impact/.test(p.$('stat').textContent), p.$('stat').textContent);
    p.close();
  });

  /* EXACT-OUT IS NOT AN UNGUARDED PATH, it is an absent one: the page only
   * asks Precision for exact-IN quotes, so a token nothing else can price
   * yields no route at all when the receive box is typed. Pinned here so the
   * distinction is on the record - a future exact-out route must bring its own
   * reference with it. */
  test('exact-out on a Precision-only coin produces no route at all', async () => {
    const p = await open_({ big: 1000n * ETH, small: 80n * ETH });
    await p.typeAmount('outAmt', '900');
    assert.equal(p.value('amt'), '', `a route was built without a reference: ${p.text('rate')}`);
    p.close();
  });
});