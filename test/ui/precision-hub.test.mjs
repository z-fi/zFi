/**
 * Two Precision markets that share ether, used as one route.
 *
 * Every Precision pool created so far is quoted against ether, so two launched
 * coins have no band between them: `poolsForPairCount` for the pair is zero,
 * confirmed on chain for every combination of the 32 live markets. zQuoter
 * cannot see Precision at all and the WETH hub route only asks zQuoter, so the
 * pair had no route from anywhere — while each coin had a funded market, and
 * for most of them it is the ONLY market they have.
 *
 * `PrecisionRoute` already walks a pool ARRAY and derives the token at each
 * step from the pool itself, so the fix is a second address in the array it is
 * handed rather than a new contract. Verified against mainnet before it was
 * written: a ZCAT->ETH->FATCAT walk through the two live bands returned the
 * chained quote to the wei.
 *
 * Run: node --test test/ui/
 */
import { test, describe, after } from 'node:test';
import assert from 'node:assert/strict';
import {
  A, SEL, MockChain, loadPage, closeAllPages, selectorOf,
} from './harness.mjs';

after(closeAllPages);

const ETH = 10n ** 18n;
const USDC = 10n ** 6n;
const USDT = 10n ** 6n;
const POOL_IN = '0x6666666666666666666666666666666666666666';   // ETH/USDC
const POOL_OUT = '0x7777777777777777777777777777777777777777';  // ETH/USDT

/** 3000 USDC -> 1 ETH -> 2000 USDT, priced by the pools rather than by a constant. */
const IN_LEG = {
  pool: POOL_IN, pair: [A.ZERO, A.USDC], fee: 3000, effFee: 3000,
  perIn: amt => amt * 10n ** 12n / 3000n,
};
const OUT_LEG = {
  pool: POOL_OUT, pair: [A.ZERO, A.USDT], fee: 10000, effFee: 10000,
  perIn: amt => amt * 2000n / 10n ** 12n,
};

/**
 * `direct` adds a USDC/USDT band, which is the case the hub must NOT displace.
 * The AMM answers nothing at all, so anything quoted here came from Precision.
 */
async function setup({ legs = [IN_LEG, OUT_LEG], direct = null, register = legs } = {}) {
  const chain = new MockChain();
  chain.setNative(A.ACCOUNT, 10n * ETH);
  chain.setErc20(A.USDC, A.ACCOUNT, 100_000n * USDC);
  chain.setErc20(A.USDT, A.ACCOUNT, 100_000n * USDT);
  chain.quoteHandler = () => null;
  const all = direct ? [...legs, direct] : legs;
  chain.precisionQuote = all;
  // Registering is what makes `factory.isPool` vouch for it, and what gives
  // `poolsForPairCount` a nonzero answer for the pair.
  for (const q of (direct ? [...register, direct] : register)) {
    chain.setPools(q.pair[0], q.pair[1], [{ pool: q.pool, hook: A.ZERO, liquidity: 10n ** 20n }]);
  }
  const page = await loadPage({ chain });
  await page.connect();
  // Output side first: USDC is the default output, so it cannot be taken as the
  // input until something else is.
  page.pickToken('toSel', 'USDT');
  page.pickToken('fromSel', 'USDC');
  return page;
}

/** Every pool address named anywhere in what the page is about to send. */
const poolsIn = tx => [POOL_IN, POOL_OUT]
  .filter(p => tx.data.toLowerCase().includes(p.slice(2).toLowerCase()));

describe('a hub hop between two ether markets', () => {
  test('routes a pair that has no band of its own', async () => {
    const p = await setup();
    await p.typeAmount('amt', '3000');
    assert.equal(p.value('outAmt'), '2000',
      'the chained quote is what executes, so it is what must be shown');
    assert.match(p.text('rate'), /Precision/, 'and Precision is named as the venue');
    p.close();
  });

  test('carries BOTH pools, in the order the walk needs them', async () => {
    // The route derives each hop's token from the pool in front of it, so the
    // order is the path. Reversed, the second hop is handed a token its pool
    // does not hold and the walk reverts on `WrongTokenOut` — after the funds
    // have already moved into the route.
    const p = await setup();
    await p.typeAmount('amt', '3000');
    p.click('swap');
    await p.waitFor(() => p.chain.sent.some(t => poolsIn(t).length === 2),
      { label: 'a two-pool route' });
    const tx = p.chain.sent.find(t => poolsIn(t).length === 2);
    // DECODE THE CALL, don't just look for the addresses in the blob. A
    // substring check passes on bytes that are in the wrong words, and the
    // shape below is the one verified against the deployed PrecisionRoute:
    // route(address[] pools, address tokenIn, address tokenOut, uint256
    // amountIn, uint256 minOut, address to), the array tail-encoded at 0xc0.
    const at = tx.data.toLowerCase().indexOf(SEL.PROUTE_ROUTE);
    assert.ok(at > 0, 'the send must carry a PrecisionRoute.route call');
    const arg = i => tx.data.slice(at + 8 + i * 64, at + 8 + (i + 1) * 64);
    const addr = i => '0x' + arg(i).slice(24);
    assert.equal(BigInt('0x' + arg(0)), 192n, 'the pools array is the tail argument');
    assert.equal(addr(1).toLowerCase(), A.USDC.toLowerCase(), 'tokenIn');
    assert.equal(addr(2).toLowerCase(), A.USDT.toLowerCase(), 'tokenOut');
    assert.equal(BigInt('0x' + arg(3)), 3000n * USDC, 'amountIn');
    assert.equal(BigInt('0x' + arg(6)), 2n, 'two hops');
    assert.equal(addr(7).toLowerCase(), POOL_IN.toLowerCase(),
      'the pool holding the input token must come first');
    assert.equal(addr(8).toLowerCase(), POOL_OUT.toLowerCase(),
      'and the pool holding the output token second');
    // The bound is below the quote and not exact, or any traffic reverts it.
    const min = BigInt('0x' + arg(4));
    assert.ok(min > 0n && min < 2000n * USDT, `minOut must be a bound, got ${min}`);
    p.close();
  });

  test('quotes the fee BOTH hops charge, composed the way the pool composes one', async () => {
    // 0.3% then 1% is not 0.3% — the number a route that reported only its
    // first hop would show — and it is not 1.3% either: the second hop is
    // charged on what the first one left. (1-total) = (1-a)(1-b), which is how
    // `effectiveFeeFor` already composes a base rate with a surcharge, giving
    // 12,970 pips. The tier is shown in bps, so it truncates to 1.29% the same
    // way a single hop's 3,000 pips shows as 0.3%.
    const p = await setup();
    await p.typeAmount('amt', '3000');
    assert.match(p.text('rate'), /Precision\s1\.29%/,
      `expected the composed rate, got ${p.text('rate')}`);
    p.close();
  });

  test('leaves a pair that HAS its own band alone', async () => {
    // A band holding both tokens cannot be beaten by two that hold one each,
    // and asking anyway would double the calls on the path every ordinary swap
    // takes. So the hub is only reached when the direct search came back empty.
    const DIRECT = {
      pool: '0x8888888888888888888888888888888888888888',
      pair: [A.USDC, A.USDT], fee: 500, effFee: 500,
      perIn: amt => amt * 999n / 1000n,
    };
    const p = await setup({ direct: DIRECT });
    await p.typeAmount('amt', '3000');
    assert.equal(p.value('outAmt'), '2997', 'the direct band is what should win');
    p.click('swap');
    await p.waitFor(() => p.chain.sent.length, { label: 'a send' });
    const tx = p.chain.sent[p.chain.sent.length - 1];
    assert.equal(poolsIn(tx).length, 0, 'and no hub pool should appear in it');
    p.close();
  });

  test('is silent when only one side of the hub has a market', async () => {
    // Half a path is not a path. Quoting the first hop and stopping would
    // strand the input in the route.
    const p = await setup({ legs: [IN_LEG] });
    await p.typeAmount('amt', '3000');
    assert.equal(p.value('outAmt'), '', `expected no quote, got ${p.value('outAmt')}`);
    p.close();
  });

  test('refuses to send when the factory disclaims ANY hop', async () => {
    // The guard read the first pool and vouched for the route. A two-hop route
    // has somewhere to hide a second one, so it now reads every hop — this
    // disowns the SECOND, which the old check never looked at.
    const p = await setup();
    await p.typeAmount('amt', '3000');
    p.chain.disownPool(POOL_OUT);
    p.click('swap');
    await p.waitFor(() => /not one the factory made/.test(p.text('stat')),
      { label: 'the refusal' });
    assert.equal(p.chain.sent.length, 0, 'and nothing may go out');
    p.close();
  });
});

/**
 * The same blind spot, one tab over.
 *
 * A native market is stored under address(0) because the pool holds ether, so
 * asking the lens for (coin, WETH) answers zero about a pool that is live and
 * funded. The swap tab has derived both shapes since the first market went up;
 * the liquidity tab did not, so it drew an empty list and then offered a form
 * to create a SECOND pool for a pair that already had one — the one outcome
 * worse than showing nothing, because it splits the liquidity of a token whose
 * Precision band is usually its only venue.
 */
describe('the liquidity tab and the two shapes of ether', () => {
  const POOL = '0x9999999999999999999999999999999999999999';

  async function open({ pairWith = A.ZERO } = {}) {
    const chain = new MockChain();
    chain.setNative(A.ACCOUNT, 10n * ETH);
    chain.setErc20(A.USDC, A.ACCOUNT, 100_000n * USDC);
    chain.setErc20(A.WETH, A.ACCOUNT, 10n * ETH);
    chain.quoteHandler = () => null;
    chain.setPools(pairWith, A.USDC, [{ pool: POOL, hook: A.ZERO, liquidity: 10n ** 20n }]);
    const page = await loadPage({ chain });
    await page.connect();
    page.click('lq');
    await page.settle();
    return page;
  }

  test('offers the shape that HAS the band instead of a duplicate of it', async () => {
    const p = await open({ pairWith: A.ZERO });
    p.pickToken('fromSel', 'WETH');
    await p.settle();
    await p.waitFor(() => p.$('lqSwitch'), { label: 'the switch' });
    assert.match(p.text('lqList'), /band holds ETH, not WETH/);
    assert.equal(p.$('lqList').querySelector('#lqCreate'), null,
      'and must NOT offer to create a second pool for a pair that has one');
    p.close();
  });

  test('clears the deposit rows the create form it replaced had shown', async () => {
    // Arriving here FROM a create form is the ordinary path — a pair with no
    // band in either shape, then one token changed. Every other terminal branch
    // of loadLq re-syncs these rows; this one is not exempt just because it
    // renders no form of its own, or they stay on screen belonging to nothing.
    const p = await open({ pairWith: A.ZERO });
    p.pickToken('fromSel', 'WETH');
    p.pickToken('toSel', 'USDT');           // no band in either shape
    await p.settle();
    await p.waitFor(() => p.$('lqList').querySelector('#lqCreate'), { label: 'the create form' });
    assert.equal(p.$('amtRow').classList.contains('hide'), false, 'the form shows them');
    p.pickToken('toSel', 'USDC');           // a native band exists for this one
    await p.settle();
    await p.waitFor(() => p.$('lqSwitch'), { label: 'the switch' });
    assert.ok(p.$('amtRow').classList.contains('hide'),
      'and the rows must go with the form that owned them');
    p.close();
  });

  test('the switch actually repoints the pair, so the band then lists', async () => {
    const p = await open({ pairWith: A.ZERO });
    p.pickToken('fromSel', 'WETH');
    await p.settle();
    await p.waitFor(() => p.$('lqSwitch'), { label: 'the switch' });
    p.$('lqSwitch').click();
    await p.waitFor(() => p.$('lqList').querySelectorAll('.lqrow').length,
      { label: 'the band, once the pair is named the way it was created' });
    assert.match(p.text('lqSub'), /ETH \/ USDC/);
    p.close();
  });

  test('still offers to create one for a pair that really is new', async () => {
    // The counterpart must be ASKED, not assumed: a pair with no band in either
    // shape is exactly what the create form is for.
    const p = await open({ pairWith: A.WBTC });
    p.pickToken('fromSel', 'WETH');
    await p.settle();
    await p.waitFor(() => p.$('lqList').querySelector('#lqCreate'), { label: 'the create form' });
    assert.equal(p.$('lqSwitch'), null, 'and nothing to switch to');
    p.close();
  });
});

/**
 * The routability policy, which is deployed for this reader and no other.
 *
 * `PrecisionPoolPolicy` is live, owned, and bound to the same factory these
 * pools come from — and nothing on chain consults it, deliberately: the factory
 * and the route stay permissionless so that no owner holds a kill switch over
 * the one path that has none. Its docblock names who should read it instead —
 * "frontends, aggregators, and anyone assembling a `pools` array off-chain" —
 * and this page was not doing so. Under `Default` it allows an unhooked pool
 * and denies a hooked one, and `createPool` is permissionless, so the pool the
 * page routes through was chosen with no view of its hook at all.
 */
describe('the routability policy', () => {
  const GOOD = '0xaaaa000000000000000000000000000000000001';
  const BAD = '0xbbbb000000000000000000000000000000000002';

  /** Two bands on ETH/USDC. `BAD` quotes better, so it is what wins unscreened. */
  async function setup({ block = null, unreadable = false } = {}) {
    const chain = new MockChain();
    chain.setNative(A.ACCOUNT, 10n * ETH);
    chain.setErc20(A.USDC, A.ACCOUNT, 100_000n * USDC);
    chain.quoteHandler = () => null;
    chain.precisionQuote = [
      // Linear, so the reference-sized quote the impact meter takes agrees with
      // the full one. A flat `out` makes a hundredth of the trade look a hundred
      // times better and trips the high-impact confirmation.
      { pool: GOOD, pair: [A.ZERO, A.USDC], fee: 3000, effFee: 3000,
        perIn: amt => amt * 3000n / 10n ** 12n },
      { pool: BAD, pair: [A.ZERO, A.USDC], fee: 3000, effFee: 3000,
        perIn: amt => amt * 3500n / 10n ** 12n },
    ];
    chain.setPools(A.ZERO, A.USDC, [
      { pool: GOOD, hook: A.ZERO, liquidity: 10n ** 20n },
      { pool: BAD, hook: A.ZERO, liquidity: 10n ** 20n },
    ]);
    if (block) chain.blockPool(block);
    chain.policyUnreadable = unreadable;
    const page = await loadPage({ chain });
    await page.connect();
    return page;
  }

  test('routes the best pool when the policy allows it', async () => {
    const p = await setup();
    await p.typeAmount('amt', '1');
    assert.equal(p.value('outAmt'), '3500', 'the best band, unrefused');
    p.close();
  });

  test('re-picks rather than dropping the pair when the winner is refused', async () => {
    // THE POINT OF THE FALLBACK. `quoteBestFor` answers with one pool and no
    // reason, so a refused winner would take the whole pair down with it — and
    // anyone may create a pool for any pair, which would turn that into a way
    // to unlist a token whose band is its only venue.
    const p = await setup({ block: BAD });
    await p.typeAmount('amt', '1');
    assert.equal(p.value('outAmt'), '3000', 'the next band down must still route');
    p.click('swap');
    await p.waitFor(() => p.chain.sent.length, { label: 'a send' });
    const tx = p.chain.sent[p.chain.sent.length - 1];
    assert.ok(!tx.data.toLowerCase().includes(BAD.slice(2).toLowerCase()),
      'and the refused pool must not appear in what is sent');
    assert.ok(tx.data.toLowerCase().includes(GOOD.slice(2).toLowerCase()));
    p.close();
  });

  test('quotes nothing when every band for the pair is refused', async () => {
    const p = await setup({ block: BAD });
    p.chain.blockPool(GOOD);
    await p.typeAmount('amt', '1');
    assert.equal(p.value('outAmt'), '', `expected no quote, got ${p.value('outAmt')}`);
    p.close();
  });

  test('AN UNREADABLE POLICY ALLOWS, because the alternative is a kill switch', async () => {
    // A dropped call or a chain with nothing at that address must not disable
    // the venue: that is the switch the contract went out of its way not to
    // build, only self-inflicted. Allowing is also what the page did before the
    // screen existed, so it is a no-op rather than a regression.
    const p = await setup({ unreadable: true });
    await p.typeAmount('amt', '1');
    assert.equal(p.value('outAmt'), '3500', 'an unreadable policy must not cost the route');
    p.close();
  });
});
