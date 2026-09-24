/**
 * Multi-leg routes and the user's slippage bound.
 *
 * zQuoter's multi-leg builders apply the bound they are given to EVERY leg, and
 * size each later leg off the previous leg's floor. Asked at the user's full
 * setting, an n-leg route's final floor sits about n times that far under the
 * quote the page shows. The page therefore asks them at the setting split
 * across the legs, and the floor it shows must still be the one the calldata
 * enforces.
 */
import { test, describe, after } from 'node:test';
import assert from 'node:assert/strict';
import { A, SEL, MockChain, loadPage, closeAllPages, encodeQuote, word } from './harness.mjs';

after(closeAllPages);

const ETH = 10n ** 18n, BTC = 10n ** 8n, USDC = 10n ** 6n, B = 10000n;
const MARK = 'feedface';
const u = v => BigInt(v).toString(16).padStart(64, '0');
const floor = (x, s) => x * (B - s) / B;

/** A multicall holding one marker call whose only word is the encoded floor. */
const markCall = lim => {
  const inner = MARK + u(lim);
  return '0x' + SEL.MULTICALL + u(32) + u(1) + u(32) + u(inner.length / 2) + inner.padEnd(128, '0');
};

/**
 * WBTC -> WETH -> DAI -> USDC at 60,000 USDC per WBTC. Each later leg is priced
 * off the previous leg's floor and each leg is floored at the bound it was
 * asked with, as zQuoter's builders do. The two-leg route is 1% worse, so the
 * three-hop one wins.
 */
function legQuoter(asked) {
  const L1 = x => x * 2n * 10n ** 11n, L2 = x => x * 3000n, L3 = x => x / 10n ** 12n;
  return ({ selector, data }) => {
    if (selector !== SEL.QUOTE && selector !== SEL.QUOTE_MULTI) return null;
    const via = selector === SEL.QUOTE, body = '0x' + data.replace(/^0x/, '').slice(8), b = via ? 2 : 1;
    if (word(body, b) === 1n) return null;
    const amt = word(body, b + 3), s = word(body, b + 4);
    if (!amt) return null;
    asked.push({ via, s });
    const qa = L1(amt), m1 = floor(qa, s);
    if (via) {
      const qb = L3(L2(m1)) * 99n / 100n;
      return encodeQuote({ u: 4, legs: [
        { source: 3, feeBps: 30n, amountIn: amt, amountOut: qa },
        { source: 3, feeBps: 30n, amountIn: m1, amountOut: qb }], callData: markCall(floor(qb, s)) });
    }
    const qb = L2(m1), m2 = floor(qb, s), qc = L3(m2);
    return encodeQuote({ u: 8, legs: [
      { source: 3, feeBps: 30n, amountIn: amt, amountOut: qa },
      { source: 3, feeBps: 30n, amountIn: m1, amountOut: qb },
      { source: 3, feeBps: 30n, amountIn: m2, amountOut: qc }], callData: markCall(floor(qc, s)) });
  };
}

async function quote(slip) {
  const chain = new MockChain();
  chain.setNative(A.ACCOUNT, ETH);
  chain.setErc20(A.WBTC, A.ACCOUNT, 10n * BTC);
  chain.setAllowance(A.WBTC, A.ACCOUNT, A.ZROUTER, 10n ** 30n);
  const asked = [];
  chain.quoteHandler = legQuoter(asked);
  const p = await loadPage({ chain });
  await p.connect();
  await p.settle();
  if (slip) {
    p.$('slip').value = slip;
    p.$('slip').dispatchEvent(new p.window.Event('input', { bubbles: true }));
  }
  p.pickToken('toSel', 'USDC');
  p.pickToken('fromSel', 'WBTC');
  p.pickToken('toSel', 'USDC');
  await p.settle();
  await p.typeAmount('amt', '1');
  await p.settle();
  return { p, asked };
}

describe('multi-leg slippage', () => {
  for (const [slip, bps] of [[null, 50n], ['1', 100n]]) {
    test(`at ${bps} bps the legs split the bound and the floor holds end to end`, async () => {
      const { p, asked } = await quote(slip);
      const hop3 = asked.filter(x => !x.via && x.s), via = asked.filter(x => x.via && x.s);
      assert.ok(hop3.length, 'no executable three-hop build was asked for');
      assert.ok(via.length, 'no executable two-leg build was asked for');
      assert.deepEqual([...new Set(hop3.map(x => x.s))], [bps / 3n], 'three-hop per-leg bound');
      assert.deepEqual([...new Set(via.map(x => x.s))], [bps / 2n], 'two-leg per-leg bound');

      const expected = 60_000n * USDC;
      assert.equal(p.value('outAmt'), '60000');
      const m = p.text('rate').match(/Min ([\d.]+) USDC/);
      assert.ok(m, p.text('rate'));
      const [ip, fp = ''] = m[1].split('.');
      const min = BigInt(ip) * USDC + BigInt((fp + '000000').slice(0, 6));

      p.click('swap');
      await p.waitFor(() => p.chain.sent.length > 0, { label: 'swap tx' });
      await p.settle();
      const d = p.chain.lastSent.data.replace(/^0x/, ''), i = d.indexOf(MARK);
      assert.ok(i >= 0, 'the three-hop callData was not sent');
      const limit = BigInt('0x' + d.slice(i + 8, i + 72));
      assert.equal(min, limit, 'the Min shown is the floor the calldata enforces');
      assert.ok(limit >= floor(expected, bps) - 2n,
        `floor ${limit} is more than ${bps} bps under the ${expected} quote`);
      p.close();
    });
  }
});
