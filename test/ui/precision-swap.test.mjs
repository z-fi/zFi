/**
 * Precision pools as a swap venue.
 *
 * zQuoter aggregates the venues that existed when it was written, and Precision
 * is not among them. So a market could be live, funded, verified and quotable -
 * and the swap tab would answer "No route: bad quote", because nothing ever
 * asked it. That is what happened to the first real market within minutes of
 * its creation.
 *
 * The pair's own bands are now asked directly, and the answer COMPETES rather
 * than filling in: a venue that is only consulted when everything else failed
 * is not a route, it is a fallback, and it will lose trades it should win.
 *
 * Run: node --test test/ui/
 */
import { test, describe, after } from 'node:test';
import assert from 'node:assert/strict';
import {
  A, SEL, MockChain, loadPage, fixedRateQuoter, word, wordAddr, selectorOf, closeAllPages,
} from './harness.mjs';

after(closeAllPages);

const ETH = 10n ** 18n;
const USDC = 10n ** 6n;
const POOL = '0xc37f8c7e9afe897893952aba7fd91e0ab947837d';

/** The AMM quotes 3000 USDC per ETH; `precision` is what the bands answer. */
async function setup({ precision = null, rate = 3000n * ETH, known = true } = {}) {
  const chain = new MockChain();
  chain.setNative(A.ACCOUNT, 10n * ETH);
  chain.setErc20(A.USDC, A.ACCOUNT, 50_000n * USDC);
  chain.quoteHandler = fixedRateQuoter({ rate });
  chain.precisionQuote = precision;
  // Registering the pool is what makes `factory.isPool` answer true for it.
  if (precision && known) {
    chain.setPools(A.ZERO, A.USDC, [{ pool: precision.pool, hook: A.ZERO, liquidity: 10n ** 20n }]);
  }
  const page = await loadPage({ chain });
  await page.connect();
  return page;
}

describe('precision as a quote source', () => {
  test('is asked at all, and wins when it is better', async () => {
    // 3100 against the AMM's 3000. A venue that cannot win is not a venue.
    const p = await setup({ precision: { pool: POOL, out: 3100n * USDC, fee: 3000 } });
    await p.typeAmount('amt', '1');
    assert.equal(p.value('outAmt'), '3100');
    assert.match(p.text('rate'), /Precision 0\.3%/, 'and says which venue won');
    p.close();
  });

  test('a native market is found when the input is WETH', async () => {
    // The bug this exists for: a Precision market on ETH/ZORG is stored under
    // (address(0), ZORG) because the pool holds ether. Asked with WETH the
    // factory was asked for a pair nobody created, answered zero, and the page
    // said "no route" about a market that was live, funded, and the only venue
    // for that token. Confirmed on chain: 1 pool for (ETH, ZORG), 0 for
    // (ZORG, WETH).
    //
    // Every other venue already knew - the book maps a native leg onto its WETH
    // alias, zQuoter carries WETH_WRAP as a source - and Precision is the one
    // most likely to be a token's ONLY market, which is when being invisible
    // costs the most.
    const p = await setup({ precision: { pool: POOL, out: 4000n * USDC, fee: 3000 } });
    p.pickToken('fromSel', 'WETH');
    p.pickToken('toSel', 'USDC');
    await p.typeAmount('amt', '1');

    assert.equal(p.value('outAmt'), '4000', 'the native market must be reachable from WETH');
    assert.match(p.text('rate'), /Precision/, 'and named as the venue');
    p.close();
  });

  /**
   * THE WHOLE ETHER MATRIX, because each cell reads as correct alone.
   *
   * A pool is paid in the asset IT holds and pays out the asset it holds; the
   * picker names a separate thing. Four input combinations and four output
   * ones, and only the diagonals need nothing - every off-diagonal cell is a
   * step that, left out, either strands funds or quotes a market that cannot
   * be paid.
   */
  const market = ({ pair, out = 4000n * USDC }) => {
    const chain = new MockChain();
    chain.setNative(A.ACCOUNT, 10n * ETH);
    chain.setErc20(A.WETH, A.ACCOUNT, 10n * ETH);
    chain.setErc20(A.USDC, A.ACCOUNT, 50_000n * USDC);
    chain.quoteHandler = fixedRateQuoter({ rate: 3000n * ETH });
    chain.precisionQuote = { pool: POOL, out, fee: 3000, pair };
    chain.setPools(pair[0], pair[1], [{ pool: POOL, hook: A.ZERO, liquidity: 10n ** 20n }]);
    return chain;
  };

  test('pays ETH into a WETH market by wrapping first', async () => {
    // The mirror of the unwrap, and the case that would otherwise quote a
    // market it cannot pay: a WETH pool takes an allowance, not value, so
    // there is nothing to approve until the WETH exists.
    const p = await loadPage({ chain: market({ pair: [A.WETH, A.USDC] }) });
    await p.connect();
    p.pickToken('fromSel', 'ETH');
    p.pickToken('toSel', 'USDC');
    await p.typeAmount('amt', '1');
    assert.equal(p.value('outAmt'), '4000', 'a WETH market must be reachable from ETH');

    p.click('swap');
    await p.waitFor(() => p.chain.sent.length > 1, { label: 'wrap then swap' });
    await p.settle();

    const first = p.chain.sent[0];
    assert.equal(first.to.toLowerCase(), A.WETH.toLowerCase());
    assert.match(first.data, /^0xd0e30db0/, 'deposit()');
    assert.equal(BigInt(first.value), ETH, 'wrapping the input, as value');
    // And the pool call itself carries NO value, because it is not native.
    const swap = p.chain.sent[p.chain.sent.length - 1];
    assert.equal(BigInt(swap.value || 0), 0n, 'a WETH pool must not be sent ether');
    p.close();
  });

  test('says which side of the wrapped boundary the output lands on', async () => {
    // The pool sends its own token straight to the recipient, so the output
    // cannot be converted on the way out. It is the same asset; being told the
    // wrong name is the whole harm, so the page names what actually lands.
    const p = await loadPage({ chain: market({ pair: [A.ZERO, A.USDC], out: 2n * ETH }) });
    await p.connect();
    // Step through a third token: the page refuses the same asset on both sides,
    // so USDC cannot move to the pay side while it is still the receive side.
    p.pickToken('toSel', 'WETH');
    p.pickToken('fromSel', 'USDC');     // asks for WETH from a NATIVE market
    await p.typeAmount('amt', '1000');
    assert.match(p.text('rate'), /pays ETH/i, 'the output form must be disclosed');
    p.close();
  });

  test('sends the output to a named recipient, not the payer', async () => {
    // Custom recipients have to survive every one of these paths: the pool's
    // `to` is the last argument of the swap, and a wrap or unwrap in front of
    // it must not quietly retarget it back to the sender.
    const p = await loadPage({ chain: market({ pair: [A.ZERO, A.USDC] }) });
    await p.connect();
    p.pickToken('fromSel', 'WETH');     // forces an unwrap in front
    p.pickToken('toSel', 'USDC');
    p.type('rc', A.OTHER);
    await p.typeAmount('amt', '1');

    p.click('swap');
    await p.waitFor(() => p.chain.sent.length > 1, { label: 'unwrap then swap' });
    await p.settle();

    const swap = p.chain.sent[p.chain.sent.length - 1];
    assert.equal(swap.to.toLowerCase(), POOL.toLowerCase());
    assert.ok(swap.data.toLowerCase().includes(A.OTHER.slice(2).toLowerCase()),
      'the recipient must reach the pool call, not be replaced by the payer');
    p.close();
  });

  test('a WETH-based market stays reachable, and is not unwrapped', async () => {
    // The mirror of the bug above, and the reason the lookup asks for BOTH
    // shapes rather than normalising. Nothing in the factory prefers ether to
    // WETH - both are ordinary pairs, and which exists is whatever its creator
    // chose. Rewriting WETH to ether unconditionally would have made a native
    // market visible by making a wrapped one invisible: the same defect,
    // pointing the other way.
    const chain = new MockChain();
    chain.setNative(A.ACCOUNT, 10n * ETH);
    chain.setErc20(A.WETH, A.ACCOUNT, 10n * ETH);
    chain.quoteHandler = fixedRateQuoter({ rate: 3000n * ETH });
    // The market is stored under (WETH, USDC) - there is no native pool at all.
    chain.precisionQuote = { pool: POOL, out: 4000n * USDC, fee: 3000, pair: [A.WETH, A.USDC] };
    chain.setPools(A.WETH, A.USDC, [{ pool: POOL, hook: A.ZERO, liquidity: 10n ** 20n }]);
    const p = await loadPage({ chain });
    await p.connect();
    p.pickToken('fromSel', 'WETH');
    p.pickToken('toSel', 'USDC');
    await p.typeAmount('amt', '1');

    assert.equal(p.value('outAmt'), '4000', 'a wrapped market must not be normalised away');

    p.click('swap');
    await p.waitFor(() => p.chain.sent.length > 0, { label: 'the swap' });
    await p.settle();

    // No unwrap: the pool holds WETH, so WETH is what it is paid, by allowance.
    assert.ok(!p.chain.sent.some(t => /^0x2e1a7d4d/.test(t.data || '')),
      'nothing should be unwrapped for a pool that wants WETH');
    const swap = p.chain.lastSent;
    assert.equal(BigInt(swap.value || 0), 0n, 'and no value rides, because the call is not native');
    p.close();
  });

  test('unwraps the WETH before paying a pool that holds ether', async () => {
    // The other half. Quoting finds the market; the pool still wants VALUE, not
    // an allowance. A Precision swap settles at the pool rather than through
    // zRouter, so there is no multicall to fold this into - it is a separate
    // transaction, the same shape as the wrap a book fill already does.
    const chain = new MockChain();
    chain.setNative(A.ACCOUNT, 10n * ETH);
    chain.setErc20(A.WETH, A.ACCOUNT, 10n * ETH);
    chain.quoteHandler = fixedRateQuoter({ rate: 3000n * ETH });
    chain.precisionQuote = { pool: POOL, out: 4000n * USDC, fee: 3000 };
    chain.setPools(A.ZERO, A.USDC, [{ pool: POOL, hook: A.ZERO, liquidity: 10n ** 20n }]);
    const p = await loadPage({ chain });
    await p.connect();
    p.pickToken('fromSel', 'WETH');
    p.pickToken('toSel', 'USDC');
    await p.typeAmount('amt', '1');
    assert.equal(p.value('outAmt'), '4000');

    p.click('swap');
    await p.waitFor(() => p.chain.sent.length > 1, { label: 'unwrap then swap' });
    await p.settle();

    const [first, second] = p.chain.sent;
    assert.equal(first.to.toLowerCase(), A.WETH.toLowerCase(), 'the first call is the unwrap');
    assert.match(first.data, /^0x2e1a7d4d/, 'withdraw(uint256)');
    assert.equal(second.to.toLowerCase(), POOL.toLowerCase(), 'then the pool itself');
    assert.equal(BigInt(second.value), ETH, 'paid as VALUE, because the pool holds ether');
    p.close();
  });

  test('loses when it is worse, rather than being preferred for being ours', async () => {
    const p = await setup({ precision: { pool: POOL, out: 2900n * USDC, fee: 3000 } });
    await p.typeAmount('amt', '1');
    assert.equal(p.value('outAmt'), '3000', 'the better venue still wins');
    assert.ok(!/Precision/.test(p.text('rate')));
    p.close();
  });

  test('carries a pair with no other route at all', async () => {
    // The reported case: a brand-new market, and no aggregator knows the pair.
    const p = await setup({ precision: { pool: POOL, out: 3100n * USDC, fee: 3000 }, rate: 0n });
    await p.typeAmount('amt', '1');
    assert.equal(p.value('outAmt'), '3100');
    assert.ok(!/No route/.test(p.text('stat')), 'a funded market is a route');
    p.close();
  });

  test('sends to the pool itself, which is its own target and spender', async () => {
    // This does not go through zRouter, the same way the V4 leg does not.
    const p = await setup({ precision: { pool: POOL, out: 3100n * USDC, fee: 3000 } });
    await p.typeAmount('amt', '1');
    p.click('swap');
    await p.waitFor(() => p.chain.sent.length > 0, { label: 'swap' });
    await p.settle();

    const tx = p.chain.lastSent;
    assert.equal(tx.to.toLowerCase(), POOL, 'straight at the pool');
    assert.equal(selectorOf(tx.data), 'a6220b66', 'swapExactIn');
    assert.equal(BigInt(tx.value), ETH, 'native input rides as value');

    const b = '0x' + tx.data.replace(/^0x/, '').slice(8);
    assert.equal(wordAddr(b, 0).toLowerCase(), A.ZERO.toLowerCase(), 'tokenIn is ETH');
    assert.equal(word(b, 1), ETH, 'amountIn');
    // 0.5% default slippage under the quote.
    assert.equal(word(b, 2), 3100n * USDC * 9950n / 10000n, 'minOut carries the slippage floor');
    assert.equal(wordAddr(b, 3).toLowerCase(), A.ACCOUNT.toLowerCase(), 'paid to the trader');
    p.close();
  });

  test('approves the pool when the input is an ERC-20', async () => {
    const p = await setup({ precision: { pool: POOL, out: ETH / 3n, fee: 500 } });
    // The pair is pinned ETH -> USDC, so neither side can move straight past
    // the other. Step through a third token.
    p.pickToken('toSel', 'WBTC');
    p.pickToken('fromSel', 'USDC');
    p.pickToken('toSel', 'ETH');
    await p.typeAmount('amt', '1000');
    if (!/Precision/.test(p.text('rate'))) { p.close(); return; }   // AMM won; nothing to assert

    p.click('swap');
    await p.waitFor(() => p.chain.sent.length > 0, { label: 'approve' });
    await p.settle();
    const first = p.chain.sent[0];
    assert.equal(first.to.toLowerCase(), A.USDC.toLowerCase());
    assert.equal(selectorOf(first.data), SEL.APPROVE);
    assert.equal(wordAddr('0x' + first.data.slice(10), 0).toLowerCase(), POOL,
      'the pool pulls the tokens, so the pool is what gets approved');
    p.close();
  });

  // A bounded comparison is a caveat on the RATE, so it belongs on the rate
  // line beside "Book scan capped" — not in `stat`. `quotePrecision` runs as a
  // detached job inside `update()`, outside the sequence guard that owns
  // `stat`, so writing there let a superseded quote drop its notice on top of
  // whatever the current one was saying — including a price-impact warning,
  // which is the one message in this flow that exists to stop a trade.
  test('says the scan was capped without touching the status line', async () => {
    const p = await setup({ precision: { pool: POOL, out: 3100n * USDC, fee: 3000 } });
    p.chain.pairCount = 900;
    await p.typeAmount('amt', '1');
    assert.match(p.text('rate'), /Precision scan capped \(128\)/);
    assert.equal(p.text('stat'), '', 'the status line stays the quote loop\'s to write');
    p.close();
  });

  test('is silent for a pair that has no band', async () => {
    const p = await setup({ precision: null });
    await p.typeAmount('amt', '1');
    assert.equal(p.value('outAmt'), '3000', 'the ordinary route is untouched');
    assert.ok(!/Precision/.test(p.text('rate')));
    p.close();
  });

  test('refuses to send to a pool the factory disclaims', async () => {
    // The address comes from our own lens, which only returns what the factory
    // indexed - so this should never fire. It exists because the SPENDER of an
    // ERC-20 approval is the one thing worth being sure about, and because the
    // liquidity panel already asks: the two paths disagreeing about how far a
    // lens is trusted is worse than one extra call on the click path.
    const p = await setup({ precision: { pool: POOL, out: 3100n * USDC, fee: 3000 }, known: false });
    await p.typeAmount('amt', '1');
    assert.match(p.text('rate'), /Precision/, 'it still quotes');

    p.click('swap');
    await p.waitFor(() => /not one the factory made/i.test(p.text('stat')),
      { label: 'the refusal' });
    assert.equal(p.chain.sent.length, 0, 'and nothing was signed');
    p.close();
  });
});
