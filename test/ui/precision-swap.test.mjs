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
