/**
 * Portability across RPC providers.
 *
 * The page runs from whatever node the connected wallet points at, and every
 * provider caps eth_call at its own undocumented value. A capped provider does
 * not return partial results - it refuses the whole request, so Multicall's
 * allowFailure cannot help: the batch never runs.
 *
 * Two regressions came out of getting this wrong, and both are pinned here:
 *
 *   1. A batch that died took the WHOLE quote down, including venues that had
 *      already answered. A thin token has no conventional liquidity, so its
 *      probes traverse the most and cost the most - exactly the token whose
 *      quote must survive on the venue that does have it.
 *   2. The "fix" was naming a gas number, which is the same bug facing the
 *      other way: a value above a provider's cap is REJECTED, so a page that
 *      states its own gas breaks on the very providers it was meant to please.
 *      That one broke every pair on the page.
 *
 * So the page names no gas anywhere and adapts instead: halve the batch until
 * it fits. That is provider-agnostic, and it covers response-size caps too.
 *
 * Run: node --test test/ui/
 */
import { test, describe, after } from 'node:test';
import assert from 'node:assert/strict';
import { A, SEL, MockChain, loadPage, fixedRateQuoter, closeAllPages } from './harness.mjs';

after(closeAllPages);

const ETH = 10n ** 18n;
const USDC = 10n ** 6n;
const RATE = 3000n * ETH;

async function setup(batchLimit) {
  const chain = new MockChain();
  chain.setNative(A.ACCOUNT, 10n * ETH);
  chain.setErc20(A.USDC, A.ACCOUNT, 50_000n * USDC);
  chain.quoteHandler = fixedRateQuoter({ rate: RATE });
  if (batchLimit !== undefined) chain.batchLimit = batchLimit;
  const page = await loadPage({ chain });
  await page.connect();
  return page;
}

const agg3Calls = chain => chain.calls.filter(c => c.selector === SEL.AGG3);

describe('a capped RPC provider', () => {
  test('still quotes when the provider refuses the full batch', async () => {
    // Tight enough that the page's quote batch cannot go through whole.
    const p = await setup(3);
    await p.typeAmount('amt', '1');
    assert.equal(p.value('outAmt'), '3000',
      'a provider with a small cap must still produce the quote, not "No route"');
    p.close();
  });

  test('gets there by halving rather than by asking for more gas', async () => {
    const p = await setup(3);
    await p.typeAmount('amt', '1');

    const batches = agg3Calls(p.chain);
    assert.ok(batches.length > 1,
      'the page should have split the batch instead of giving up after one try');
    assert.ok(batches.every(c => c.gas === undefined),
      'the page must never state a gas figure: a value over the cap is rejected outright');
    p.close();
  });

  test('costs nothing extra when the provider is healthy', async () => {
    // Bisection is a recovery path. On a provider that answers, the page must
    // still make exactly one round trip per batch - otherwise every user pays
    // for the rare provider.
    const healthy = await setup();
    await healthy.typeAmount('amt', '1');
    const healthyBatches = agg3Calls(healthy.chain).length;

    const capped = await setup(3);
    await capped.typeAmount('amt', '1');
    const cappedBatches = agg3Calls(capped.chain).length;

    assert.ok(cappedBatches > healthyBatches,
      'the capped provider is the one that should pay for the extra round trips');
    assert.equal(healthy.value('outAmt'), capped.value('outAmt'),
      'and both should arrive at the same quote');
    healthy.close();
    capped.close();
  });

  test('degrades to no route rather than hanging when nothing fits', async () => {
    // batchLimit 0 refuses even a single call, so bisection bottoms out. The
    // page must settle, not spin: an unreachable node is a real state.
    const p = await setup(0);
    await p.typeAmount('amt', '1');
    assert.equal(p.value('outAmt'), '', 'no quote is available');
    assert.match(p.text('stat'), /No route/, 'and the page says so rather than hanging');
    p.close();
  });
});
