/**
 * The V4 route: token list -> pool key -> quote -> transaction.
 *
 * zSwap ships as immutable contract code, so a pool cannot be added by editing
 * the page. It is read at load from a listing's `zfi.v4pool` extra, and the two
 * things that can go wrong are both invisible to a DOM assertion: a pool key
 * parsed slightly wrong routes into a pool that does not exist, and a swap sent
 * with the wrong target, spender or msg.value loses money while displaying a
 * correct-looking quote.
 *
 * So these tests assert the parse, and then the EXACT transaction: who it goes
 * to, what the calldata decodes to, and what value rides along.
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import { describe, it, after } from 'node:test';
import { AbiCoder } from 'ethers';
import {
  A, MockChain, loadPage, closeAllPages, fixedRateQuoter,
  word, wordAddr, selectorOf,
} from './harness.mjs';

const coder = AbiCoder.defaultAbiCoder();
const ETH = 10n ** 18n;
const HOOK = '0x2C67ebA8A50AF0dB5Fba55F725247a75CbDA6444';
const FWA = '0xa0Df17B5aC76ABaBA36E1450E2cbCd18A620C845';
const V4SWAP = '48e6f730';

after(closeAllPages);

/** A page whose USDC listing carries one hooked ETH pool. */
async function setup({ v4Quote, extra = '' } = {}) {
  const chain = new MockChain();
  chain.setNative(A.ACCOUNT, 10n * ETH);
  chain.setErc20(A.USDC, A.ACCOUNT, 50_000n * 10n ** 6n);
  chain.quoteHandler = fixedRateQuoter({ rate: 3000n * ETH });
  chain.v4Quote = v4Quote || null;
  const page = await loadPage({
    chain,
    // Inject the pool onto the built-in USDC row, which is what parsing a
    // listing would have produced. The parser itself is tested directly below.
    patch: [[
      `{sym:"USDC",  addr:"${A.USDC}",dec:6, icon:USDC_ICON},`,
      `{sym:"USDC",  addr:"${A.USDC}",dec:6, icon:USDC_ICON,v4:[{c0:"${A.ZERO}",c1:"${A.USDC}",fee:0,ts:60,hooks:"${HOOK}"}]${extra}},`,
    ]],
  });
  await page.connect();
  return page;
}

describe('parsing a listing into pool keys', () => {
  it('reads the published FWA entry', async () => {
    const page = await setup();
    const { parseV4Pools } = page.window;
    // Byte-for-byte what setExtra wrote to the live token list.
    const pools = parseV4Pools(
      [{ k: '0x95a932c205571d4d1ca72715c642a2eca21dde79ffc28ff11509681f9383385f',
         v: `v1:0:0:60:${HOOK}` }],
      FWA,
    );
    assert.equal(pools.length, 1);
    // v4 sorts the pair, and the page does not get to choose: native ETH is
    // the zero address, so it is always currency0.
    assert.equal(pools[0].c0, A.ZERO);
    assert.equal(pools[0].c1.toLowerCase(), FWA.toLowerCase());
    assert.equal(pools[0].fee, 0);
    assert.equal(pools[0].ts, 60);
    assert.equal(pools[0].hooks.toLowerCase(), HOOK.toLowerCase());
    page.close();
  });

  it('carries several pools, because a token gets more than one', async () => {
    const page = await setup();
    const pools = page.window.parseV4Pools(
      [{ k: '0x95a932c205571d4d1ca72715c642a2eca21dde79ffc28ff11509681f9383385f',
         v: `v1:0:0:60:${HOOK};v1:0:3000:60:0` }],
      FWA,
    );
    assert.equal(pools.length, 2);
    assert.equal(pools[1].fee, 3000);
    assert.equal(pools[1].hooks.toLowerCase(), A.ZERO, 'a pool with no hook is spelled 0');
    page.close();
  });

  /**
   * TokenList truncates an extra past 256 characters SILENTLY. A sheared pool
   * key is a half-address, and half an address must be dropped rather than
   * padded, guessed, or routed to.
   */
  it('drops a truncated or malformed entry instead of routing to it', async () => {
    const page = await setup();
    const { parseV4Pools } = page.window;
    const K = '0x95a932c205571d4d1ca72715c642a2eca21dde79ffc28ff11509681f9383385f';
    const bad = [
      `v1:0:0:60:${HOOK.slice(0, 30)}`,      // truncated hook
      'v1:0:0:60',                            // missing a field
      `v2:0:0:60:${HOOK}`,                    // a version this page cannot read
      `v1:0:x:60:${HOOK}`,                    // non-numeric fee
      `v1:0:0:0:${HOOK}`,                     // tickSpacing 0 addresses no pool
      `v1:${FWA}:0:60:${HOOK}`,               // paired against itself
    ];
    for (const v of bad) {
      assert.equal(parseV4Pools([{ k: K, v }], FWA).length, 0, `should reject: ${v}`);
    }
    // A good entry alongside a bad one still survives.
    assert.equal(parseV4Pools([{ k: K, v: `${bad[0]};v1:0:0:60:${HOOK}` }], FWA).length, 1);
    assert.equal(parseV4Pools([], FWA).length, 0);
    assert.equal(parseV4Pools([{ k: '0xdead', v: `v1:0:0:60:${HOOK}` }], FWA).length, 0,
      'a different extra key is not a pool');
    page.close();
  });

  it('only offers a pool that trades the pair on screen', async () => {
    const page = await setup();
    const { v4PoolsFor } = page.window;
    const usdc = { addr: A.USDC, v4: [{ c0: A.ZERO, c1: A.USDC, fee: 0, ts: 60, hooks: HOOK }] };
    const eth = { addr: A.ZERO, v4: [] };
    const wbtc = { addr: A.WBTC, v4: [] };
    assert.equal(v4PoolsFor(eth, usdc).length, 1, 'ETH -> USDC matches');
    assert.equal(v4PoolsFor(usdc, eth).length, 1, 'and so does the reverse');
    assert.equal(v4PoolsFor(wbtc, usdc).length, 0, 'WBTC -> USDC does not');
    // Direction is derived from the sorted key, not from which box it is in.
    assert.equal(v4PoolsFor(eth, usdc)[0].zeroForOne, true);
    assert.equal(v4PoolsFor(usdc, eth)[0].zeroForOne, false);
    page.close();
  });
});

describe('quoting and sending', () => {
  it('sends the swap to V4Port, not zRouter, when the pool wins', async () => {
    // Ten times the hub's rate, so the V4 leg is unambiguously better.
    const page = await setup({ v4Quote: ({ amountIn }) => amountIn * 30_000n / 10n ** 12n });
    await page.typeAmount('amt', '1');
    page.click('swap');
    await page.settle();

    const tx = page.chain.lastSent;
    assert.equal(tx.to.toLowerCase(), A.V4PORT.toLowerCase(), 'target is the port');
    assert.equal(selectorOf(tx.data), V4SWAP, 'and the call is V4Port.swap');
    assert.equal(BigInt(tx.value), 1n * ETH, 'native input rides as msg.value');

    const body = '0x' + tx.data.replace(/^0x/, '').slice(8);
    assert.equal(wordAddr(body, 0), A.ZERO, 'currency0');
    assert.equal(wordAddr(body, 1).toLowerCase(), A.USDC.toLowerCase(), 'currency1');
    assert.equal(word(body, 2), 0n, 'fee');
    assert.equal(word(body, 3), 60n, 'tickSpacing');
    assert.equal(wordAddr(body, 4).toLowerCase(), HOOK.toLowerCase(), 'hooks');
    assert.equal(word(body, 5), 1n, 'zeroForOne: buying currency1');
    assert.equal(word(body, 6), 1n * ETH, 'amountIn matches what was typed');
    assert.equal(wordAddr(body, 8).toLowerCase(), A.ACCOUNT.toLowerCase(), 'recipient');
    page.close();
  });

  /** The floor is the page's, and it must actually bind. */
  it('carries a slippage floor below the quote but not far below', async () => {
    const page = await setup({ v4Quote: ({ amountIn }) => amountIn * 30_000n / 10n ** 12n });
    await page.typeAmount('amt', '1');
    page.click('swap');
    await page.settle();

    const body = '0x' + page.chain.lastSent.data.replace(/^0x/, '').slice(8);
    const quoted = 30_000n * 10n ** 6n;
    const minOut = word(body, 7);
    assert.ok(minOut > 0n && minOut < quoted, 'a real floor, not zero and not the quote');
    assert.ok(minOut >= quoted * 99n / 100n, 'and within a sane slippage of it');
    page.close();
  });

  /**
   * The one thing this route does that no other pair in the page does: a sell
   * approves V4Port itself. V4Port pulls from `msg.sender`, which is what stops
   * an allowance to it from becoming a standing option a stranger can exercise
   * - but it means zRouter is the wrong spender here, and approving zRouter
   * would leave the swap to revert with the tokens already committed.
   */
  it('approves the port, not the router, when selling into it', async () => {
    const page = await setup({ v4Quote: ({ amountIn }) => amountIn * 10n ** 12n / 1000n });
    page.select('fromSel', '5');   // USDC
    page.select('toSel', '0');     // ETH
    await page.settle();
    await page.typeAmount('amt', '1000');
    page.click('swap');
    await page.settle();

    const approvals = page.chain.sentTo(A.USDC);
    assert.ok(approvals.length >= 1, 'an approval was sent');
    const spender = wordAddr('0x' + approvals.at(-1).data.replace(/^0x/, '').slice(8), 0);
    assert.equal(spender.toLowerCase(), A.V4PORT.toLowerCase(),
      'the port is the spender - approving zRouter would strand the swap');

    const tx = page.chain.lastSent;
    assert.equal(tx.to.toLowerCase(), A.V4PORT.toLowerCase());
    assert.equal(BigInt(tx.value || 0), 0n, 'an ERC20 sell attaches no ETH');
    page.close();
  });

  it('wins on merit against the hub, and only after the planner has run', async () => {
    // The comparison happens LAST, not where the candidate is built. A V4Port
    // swap settles by itself and cannot be a leg of a zRouter multicall, so
    // promoting it early would have the book+AMM planner build a hybrid around
    // a route that cannot be combined - which is why it is held back and then
    // replaces the plan wholesale.
    const page = await setup({ v4Quote: ({ amountIn }) => amountIn * 3300n / 10n ** 12n });
    await page.typeAmount('amt', '1');
    assert.equal(page.value('outAmt'), '3300', 'the better price wins the comparison');
    assert.match(page.text('rate'), /UniV4/, 'and it says which venue won');

    page.click('swap');
    await page.waitFor(() => page.chain.sent.length > 0, { label: 'swap' });
    await page.settle();
    assert.equal(page.chain.lastSent.to.toLowerCase(), A.V4PORT.toLowerCase(),
      'and the trade goes to the port, not the router');
    page.close();
  });


  it('leaves the ordinary route alone when the pool is worse', async () => {
    // A tenth of the hub's rate: the V4 leg must lose and stay out of the way.
    const page = await setup({ v4Quote: ({ amountIn }) => amountIn * 300n / 10n ** 12n });
    await page.typeAmount('amt', '1');
    page.click('swap');
    await page.settle();

    assert.equal(page.chain.lastSent.to.toLowerCase(), A.ZROUTER.toLowerCase(),
      'still zRouter');
    page.close();
  });

  it('quotes nothing rather than something when the pool is dead', async () => {
    const page = await setup({ v4Quote: () => 0n });
    await page.typeAmount('amt', '1');
    // The hub still has a route, so the page quotes - just not through V4.
    page.click('swap');
    await page.settle();
    assert.equal(page.chain.lastSent.to.toLowerCase(), A.ZROUTER.toLowerCase());
    page.close();
  });
});
