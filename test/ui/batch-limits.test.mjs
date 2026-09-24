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
import { A, SEL, MockChain, loadPage, fixedRateQuoter, closeAllPages, encodeQuote } from './harness.mjs';

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

  test('settles rather than hanging when nothing fits', async () => {
    // batchLimit 0 refuses even a single call, so bisection bottoms out. The
    // page must settle, not spin: an unreachable node is a real state. WHAT it
    // says about it is the next test - this one is only that it stops.
    const p = await setup(0);
    await p.typeAmount('amt', '1');
    assert.equal(p.value('outAmt'), '', 'no quote is available');
    assert.ok(p.text('stat').length > 0, 'and it reaches a verdict rather than spinning');
    p.close();
  });

  test('blames the node, not the market, when reads were abandoned', async () => {
    // Found on a fork whose eth_call gas cap is lower than mainnet's: the
    // quote batch failed, bisection bottomed out, every venue came back null,
    // and the page said "No route: bad quote". That is the market being
    // blamed for the RPC - and a user reading it concludes the pair has no
    // liquidity when their node simply could not answer.
    const p = await setup(0);          // refuses even a single call
    await p.typeAmount('amt', '1');
    await p.waitFor(() => p.text('stat').length > 0, { label: 'a verdict' });

    assert.match(p.text('stat'), /RPC could not complete/i, 'says whose failure it was');
    assert.ok(!/No route/i.test(p.text('stat')),
      'and does not report absent liquidity for a question nobody asked');
    p.close();
  });

  test('blames the node when the batch returned but every call in it failed', async () => {
    // The gap between the two tests above. `batchLimit` kills the whole request,
    // which bisection notices and counts. This is the other shape: the batch
    // SUCCEEDS and allowFailure hands back a full set of per-call failures, so
    // nothing bisects, nothing is abandoned, and every venue reads as empty.
    //
    // Found on a fork whose eth_call gas cap could not cover an exact-out probe.
    // The page said "No route: bad quote" - the market blamed for a budget.
    const chain = new MockChain();
    chain.setNative(A.ACCOUNT, 10n * ETH);
    chain.setErc20(A.USDC, A.ACCOUNT, 50_000n * USDC);
    chain.quoteHandler = fixedRateQuoter({ rate: RATE });
    const p = await loadPage({ chain });
    await p.connect();
    chain.failEveryCall = true;          // only once the page is up and connected
    await p.typeAmount('amt', '1');
    await p.waitFor(() => p.text('stat').length > 0, { label: 'a verdict' });

    assert.match(p.text('stat'), /RPC could not complete/i,
      'a node that answered nothing at all is not a market with no liquidity');
    assert.ok(!/No route/i.test(p.text('stat')));
    p.close();
  });

  test('still says no route when the venues genuinely answered nothing', async () => {
    // The other half: a healthy node that simply has no route must NOT be
    // reported as a node failure, or the message becomes noise.
    const chain = new MockChain();
    chain.setNative(A.ACCOUNT, 10n * ETH);
    chain.quoteHandler = () => null;   // answers, with nothing
    const p = await loadPage({ chain });
    await p.connect();
    await p.typeAmount('amt', '1');
    await p.waitFor(() => /No route/i.test(p.text('stat')), { label: 'no route' });
    assert.ok(!/RPC could not complete/i.test(p.text('stat')));
    p.close();
  });
});

/**
 * A connected wallet's node that cannot run the quoter.
 *
 * The mainnet quoter needs 50-250M gas for common pairs and most nodes stop at
 * 50M. A connected user's reads stay with their wallet's provider, so when the
 * provider cannot answer, the quote is asked of the public pool with the
 * account and the recipient replaced by fresh random addresses, and the real
 * ones put back into the calldata that comes home. The pool learns a pair and
 * an amount, never who is trading.
 */
describe('a connected wallet whose node cannot run the quoter', () => {
  const ACCT = A.ACCOUNT.slice(2).toLowerCase();
  function setup() {
    const wallet = new MockChain();
    wallet.setNative(A.ACCOUNT, 10n * ETH);
    wallet.quoteHandler = () => { throw Object.assign(Error('out of gas: gas required exceeds allowance'), { code: -32003 }); };
    const pool = new MockChain();
    const seen = [];
    pool.quoteHandler = ({ selector, data }) => {
      seen.push(data.toLowerCase());
      if (selector !== SEL.QUOTE) return null;
      const body = data.replace(/^0x/, '').slice(8);
      const recipient = body.slice(24, 64);
      const amountIn = BigInt('0x' + body.slice(5 * 64, 6 * 64));
      if (!amountIn) return null;
      const out = amountIn * 3000n / 10n ** 12n;
      // The route names its recipient, as a real one does.
      return encodeQuote({ u: 4, legs: [{ source: 3, feeBps: 30n, amountIn, amountOut: out }],
        callData: '0x' + SEL.MULTICALL + '00'.repeat(12) + recipient, msgValue: amountIn });
    };
    wallet.remotes = { publicnode: pool, blastapi: pool, mevblocker: pool };
    return { wallet, seen };
  }

  test('still quotes, from the pool, without the pool learning the account', async () => {
    const { wallet, seen } = setup();
    const p = await loadPage({ chain: wallet });
    await p.connect();
    await p.typeAmount('amt', '1');
    assert.equal(p.value('outAmt'), '3000', 'the pool answered the quote the wallet could not');
    assert.ok(seen.length > 0, 'the pool was asked');
    for (const d of seen) assert.ok(!d.includes(ACCT), 'the account reached a public node');
    const cd = await p.window.eval('last.callData');
    assert.ok(cd.toLowerCase().includes(ACCT), 'the route pays the real account');
    p.close();
  });

  test('two quotes blind the account differently', async () => {
    const { wallet, seen } = setup();
    const p = await loadPage({ chain: wallet });
    await p.connect();
    await p.typeAmount('amt', '1');
    await p.typeAmount('amt', '2');
    const rcpts = new Set(seen.filter(d => d.startsWith('0x' + SEL.QUOTE)).map(d => d.slice(10 + 24, 10 + 64)));
    assert.ok(rcpts.size > 1, 'a fixed placeholder would link one user\'s quotes together');
    p.close();
  });
});
