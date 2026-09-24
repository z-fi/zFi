/**
 * Three-hop routes on every chain.
 *
 * Mainnet zQuoter builds them itself. The Base and Robinhood quoters do not, so
 * on those chains the page asks the three-hop companion (`Z3H`) with the same
 * selector and decodes the same answer. What is worth pinning is where each
 * request goes: a three-hop ask sent to an L2 quoter that has no such function
 * is a route that silently never appears.
 */
import { test, describe, after } from 'node:test';
import assert from 'node:assert/strict';
import { A, SEL, MockChain, loadPage, fixedRateQuoter, closeAllPages } from './harness.mjs';

after(closeAllPages);

const ETH = 10n ** 18n;
const lower = a => a.toLowerCase();

async function quoteOn(chainId, pair) {
  const chain = new MockChain({ chainId });
  chain.setNative(A.ACCOUNT, 10n * ETH);
  chain.quoteHandler = fixedRateQuoter({ rate: 3000n * ETH });
  const p = await loadPage({ chain });
  await p.connect(chainId === '0x1' ? undefined : { pin: false });
  await p.settle();
  const [from, to] = pair || ['ETH', chainId === '0x1237' ? 'NVDA' : 'USDC'];
  p.pickToken('toSel', to);
  p.pickToken('fromSel', from);
  p.pickToken('toSel', to);
  await p.settle();
  await p.typeAmount('amt', '1');
  await p.settle();
  const hops = chain.calls.filter(c => c.selector === SEL.QUOTE_MULTI);
  return { p, hops };
}

describe('three-hop routes', () => {
  for (const [name, id] of [['Base', '0x2105'], ['Robinhood', '0x1237']]) {
    test(`on ${name}, are asked of the companion, never of the quoter`, async () => {
      const { p, hops } = await quoteOn(id);
      assert.ok(hops.length > 0, 'no three-hop route was asked for');
      assert.ok(hops.every(c => lower(c.to) === lower(A.Z3H)),
        `a three-hop ask went elsewhere: ${[...new Set(hops.map(c => c.to))]}`);
      p.close();
    });
  }

  test('on Ethereum, are asked of zQuoter itself', async () => {
    const { p, hops } = await quoteOn('0x1', ['USDC', 'WBTC']);
    assert.ok(hops.length > 0, 'no three-hop route was asked for');
    assert.ok(hops.every(c => lower(c.to) === lower(A.ZQUOTER)), 'mainnet keeps its own builder');
    p.close();
  });

  // zQuoter's 3-hop search with ether at either end runs past 500M gas on
  // mainnet, beyond what the read nodes serve, so asking only produces
  // out-of-gas answers and a false "some venues unreachable".
  test('on Ethereum, are not asked for a pair with ether at either end', async () => {
    const { p, hops } = await quoteOn('0x1');
    assert.equal(hops.length, 0);
    assert.doesNotMatch(p.text('rate'), /unreachable/);
    p.close();
  });
});
