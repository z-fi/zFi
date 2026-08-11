/**
 * Creating a Precision band from the liquidity panel.
 *
 * A pool is a PRICE RANGE, not just a pair, so creating one is a decision the
 * page cannot make for you: where the band sits, and where inside it trading
 * starts. That is why it was never folded into "add liquidity" - adding joins
 * a band somebody already chose, and choosing badly here is arbitrageable
 * rather than merely suboptimal.
 *
 * Two defaults are opinions, and both are asserted below because both are
 * security-relevant rather than cosmetic:
 *
 *   the market is created NAMED (feeRecipient = you), which is the only thing
 *   that stops a stranger seeding your pool at a price of their choosing
 *
 *   the creator fee is ZERO, so naming costs traders nothing
 *
 * Run: node --test test/ui/
 */
import { test, describe, after } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import {
  A, SEL, MockChain, loadPage, fixedRateQuoter, word, wordAddr, selectorOf,
  HTML_PATH, closeAllPages,
} from './harness.mjs';

after(closeAllPages);

const ETH = 10n ** 18n;
const USDC = 10n ** 6n;
const LENS = '0x4444444444444444444444444444444444444444';
const patchLens = (() => {
  const m = fs.readFileSync(HTML_PATH, 'utf8').match(/const PPLENS="(0x[0-9a-fA-F]{40})"/);
  if (!m) throw Error('zSwap.html no longer declares PPLENS');
  return [[m[0], `const PPLENS="${LENS}"`]];
})();

// sqrt(price) * 1e18, the pool's own units, for a pair of 18/6-decimal tokens.
// price is USDC per ETH, so the decimal bias is 10^(6-18).
const sq = px => BigInt(Math.round(Math.sqrt(px * 10 ** -12) * 1e9)) * 10n ** 9n;

async function setup({ band = { low: sq(1000), high: sq(5000) }, deployed = false } = {}) {
  const chain = new MockChain();
  chain.setNative(A.ACCOUNT, 50n * ETH);
  chain.setErc20(A.USDC, A.ACCOUNT, 100_000n * USDC);
  chain.quoteHandler = fixedRateQuoter({ rate: 3000n * ETH });
  chain.setCode(LENS, '0x60006000');
  chain.seedBand = band;
  // The lens reads the band off the pool, so it can only answer for a market
  // that already exists. Creating one usually means it does NOT - see the
  // "not yet deployed" tests below for the ordinary case.
  chain.seedDeployed = deployed;
  // No pools registered for the pair: the panel's empty state is the entry
  // point, which is the whole point of putting creation there.
  const page = await loadPage({ chain, patch: patchLens });
  await page.connect();
  page.click('lq');
  await page.settle();
  return page;
}

const form = p => p.$('lqList').querySelector('.lqnew');
/** Select a range preset. "custom" reveals the two price inputs. */
const preset = async (p, v) => {
  const el = form(p).querySelector('#lqRange');
  el.value = v;
  el.dispatchEvent(new p.window.Event('change', { bubbles: true }));
  await new Promise(r => p.window.setTimeout(r, 60));
  await p.settle();
};

/**
 * Type a deposit and any form fields.
 *
 * The two amounts live on the SWAP TILE, not in this form: they are the
 * deposit, and their ratio is the opening price - which is how pool creation
 * works everywhere else, and the reason the form no longer asks for a price
 * it can already read.
 */
const fill = async (p, { a0, a1, ...fields } = {}) => {
  const box = form(p);
  for (const [id, v] of Object.entries(fields)) {
    const el = box.querySelector('#' + id);
    if (!el) throw Error(`no #${id} in the create form`);
    el.value = v;
    el.dispatchEvent(new p.window.Event('input', { bubbles: true }));
  }
  if (a0 !== undefined) { p.$('amt').value = a0; p.type('amt', a0); }
  if (a1 !== undefined) { p.$('outAmt').value = a1; p.type('outAmt', a1); }
  await new Promise(r => p.window.setTimeout(r, 420));
  await p.settle();
};

// 1 ETH and 3000 USDC: a ratio of 3000, which IS the opening price.
const good = { a0: '1', a1: '3000' };
const customBand = { lqLo: '1000', lqHi: '5000' };
const custom = async (p, vals = { ...good, ...customBand }) => {
  await preset(p, 'custom');
  await fill(p, vals);
};

describe('creating a band', () => {
  test('is offered exactly where there is no band to join', async () => {
    const p = await setup();
    assert.match(p.$('lqList').textContent, /No Precision band for this pair yet/);
    assert.ok(form(p), 'the empty state should be the way in, not a dead end');
    assert.equal(form(p).querySelector('#lqCreate').disabled, true, 'until it is filled in');
    p.close();
  });

  test('refuses a band that is not a range, before asking the chain anything', async () => {
    const p = await setup();
    await custom(p, { ...good, lqLo: '5000', lqHi: '1000' });
    assert.match(p.$('lqPv').textContent, /low price must be below/i);
    assert.equal(p.$('lqCreate').disabled, true);
    p.close();
  });

  test('refuses an opening price outside its own band', async () => {
    // The pool would take it and the first trade would arbitrage it. Cheaper
    // to say so than to let the chain answer with a revert.
    const p = await setup();
    await custom(p, { ...good, ...customBand, lqLo: '4000', lqHi: '5000' });
    assert.match(p.$('lqPv').textContent, /amounts imply 3,?000, which is outside that band/i);
    assert.equal(p.$('lqCreate').disabled, true);
    p.close();
  });

  test('previews exactly when the market exists but was never seeded', async () => {
    // The factory allows this and seeds rather than rejecting, and it is the
    // only case where the lens has a pool to read.
    const p = await setup({ deployed: true });
    await custom(p);
    assert.match(p.$('lqPv').textContent, /Seeds 1 ETH \+ 3,?000 USDC/);
    assert.equal(p.$('lqCreate').disabled, false);
    p.close();
  });

  test('says when the rest comes back, because the amounts are maxima', async () => {
    // A seed takes the ratio the opening price implies and returns the excess.
    const p = await setup({ band: { low: sq(1000), high: sq(5000), used0: ETH / 2n }, deployed: true });
    await custom(p);
    assert.match(p.$('lqPv').textContent, /the rest is returned/i);
    p.close();
  });

  test('deploys and seeds in one transaction, with the band it previewed', async () => {
    const p = await setup();
    await custom(p);
    p.click('lqCreate');
    await p.waitFor(() => p.chain.sent.length > 0, { label: 'create' });
    await p.settle();

    const tx = p.chain.lastSent;
    assert.equal(tx.to.toLowerCase(), A.PFACTORY.toLowerCase());
    assert.equal(selectorOf(tx.data), '7163352a', 'createAndSeed');
    // ETH is token0 (address zero sorts first), so the native leg rides as value.
    assert.equal(BigInt(tx.value), ETH, 'the ETH side is sent, not pulled');

    // Market is eight STATIC words, so it is encoded INLINE and first - no
    // offset. An offset word here shifts every field by one and the factory
    // reads it as token0, which reverts Bad(). A fixture that decodes with the
    // same mistake agrees with itself, so this is asserted against the layout
    // the live factory actually accepts.
    const b = '0x' + tx.data.replace(/^0x/, '').slice(8);
    assert.equal(wordAddr(b, 0).toLowerCase(), A.ZERO.toLowerCase(), 'token0 is ETH');
    assert.equal(wordAddr(b, 1).toLowerCase(), A.USDC.toLowerCase(), 'token1');
    assert.equal(word(b, 2), sq(1000), 'sqrtPLow');
    assert.equal(word(b, 3), sq(5000), 'sqrtPHigh');
    assert.equal(word(b, 4), 3000n, 'the fee tier selected');
    assert.equal(wordAddr(b, 5).toLowerCase(), A.ZERO.toLowerCase(), 'no hook');
    // Then the scalars.
    // The opening price is DERIVED from the ratio: the price at which both
    // deposits are consumed in full. It is not the naive a1/a0 - a band shifts
    // it - so what matters is that it sits strictly inside, which is what
    // makes it a two-sided seed at all.
    const sp = word(b, 8);
    assert.ok(sp > word(b, 2) && sp < word(b, 3), 'opens strictly inside its own band');
    assert.equal(word(b, 9), ETH, 'amount0');
    assert.equal(word(b, 10), 3000n * USDC, 'amount1');
    assert.equal(wordAddr(b, 12).toLowerCase(), A.ACCOUNT.toLowerCase(), 'LP shares to you');
    p.close();
  });

  test('creates an unowned market by default', async () => {
    // The AMM norm, and the credibly neutral one: nobody is privileged and
    // nobody can ever take a fee from it. A squatter CAN seed it first and
    // leave the creator's transaction reverting - but that costs them real
    // capital, and the price they pin is arbitraged straight back out.
    const p = await setup();
    await custom(p);
    p.click('lqCreate');
    await p.waitFor(() => p.chain.sent.length > 0, { label: 'create' });
    await p.settle();

    const b = '0x' + p.chain.lastSent.data.replace(/^0x/, '').slice(8);
    assert.equal(wordAddr(b, 6).toLowerCase(), A.ZERO.toLowerCase(),
      'feeRecipient zero: an unowned market');
    assert.equal(word(b, 7), 0n, 'and no creator fee, which the zero recipient also requires');
    p.close();
  });

  test('can gate seeding to the creator when that is what matters', async () => {
    // For a launch the opening price IS the product, so being squatted is not
    // noise. Naming the market is the only thing that stops it, and it still
    // costs traders nothing - creatorFeeBps is immutable at zero.
    const p = await setup();
    await custom(p);
    const own = form(p).querySelector('#lqOwn');
    own.value = '1';
    own.dispatchEvent(new p.window.Event('change', { bubbles: true }));
    await new Promise(r => p.window.setTimeout(r, 420));
    await p.settle();

    assert.match(p.$('lqOwnNote').textContent, /Only your address can seed/i);
    p.click('lqCreate');
    await p.waitFor(() => p.chain.sent.length > 0, { label: 'create' });
    await p.settle();

    const b = '0x' + p.chain.lastSent.data.replace(/^0x/, '').slice(8);
    assert.equal(wordAddr(b, 6).toLowerCase(), A.ACCOUNT.toLowerCase(), 'named to the creator');
    assert.equal(word(b, 7), 0n, 'and still no fee');
    p.close();
  });

  test('says which of the two was chosen, since neither can charge a trader', async () => {
    const p = await setup();
    await custom(p);
    assert.match(p.$('lqOwnNote').textContent, /Unowned, like any AMM pool/i);
    assert.match(p.$('lqOwnNote').textContent, /nobody can ever take a fee/i);
    p.close();
  });


  test('carries a slippage floor under the previewed shares', async () => {
    const p = await setup({ deployed: true });
    await custom(p);
    p.click('lqCreate');
    await p.waitFor(() => p.chain.sent.length > 0, { label: 'create' });
    await p.settle();

    const b = '0x' + p.chain.lastSent.data.replace(/^0x/, '').slice(8);
    const previewed = ETH + 3000n * USDC;             // what the fixture returns
    const minLP = word(b, 11);
    assert.ok(minLP > 0n && minLP < previewed, 'a floor, not the preview itself');
    assert.equal(minLP, previewed * 9950n / 10000n, 'the page slippage, 0.5% by default');
    p.close();
  });

  test('approves the ERC-20 side to the factory before creating', async () => {
    const p = await setup();
    await custom(p);
    p.click('lqCreate');
    await p.waitFor(() => p.chain.sent.length > 1, { label: 'approve then create' });
    await p.settle();

    const [approve] = p.chain.sent;
    assert.equal(approve.to.toLowerCase(), A.USDC.toLowerCase());
    assert.equal(selectorOf(approve.data), SEL.APPROVE);
    assert.equal(wordAddr('0x' + approve.data.slice(10), 0).toLowerCase(),
      A.PFACTORY.toLowerCase(), 'the factory pulls it, so the factory is approved');
    p.close();
  });

  test('reports a band the pool would refuse rather than sending it', async () => {
    // previewSeed answering `ok: false` is the band saying this cannot open
    // here at all - a different thing from a poor rate, and it must not be
    // clickable.
    const p = await setup({ band: { low: sq(4000), high: sq(5000) }, deployed: true });
    await custom(p);
    assert.match(p.$('lqPv').textContent, /cannot open at that price/i);
    assert.equal(p.$('lqCreate').disabled, true);
    assert.equal(p.chain.sent.length, 0);
    p.close();
  });
  test('previews honestly when the band does not exist yet', async () => {
    // THE ORDINARY CASE. previewSeed reads the band off the pool, and there is
    // no code at a CREATE2 address until it is deployed - so on mainnet it
    // REVERTS rather than answering. A page that treated that as a failure
    // would refuse to create the very thing it exists to create.
    const p = await setup();                 // not deployed
    await custom(p);
    assert.match(p.$('lqPv').textContent, /Deposits 1 ETH \+ 3,?000 USDC/);
    assert.equal(p.$('lqCreate').disabled, false, 'and it must still be creatable');
    p.close();
  });

  test('sends no share floor when there was no preview to floor', async () => {
    // Not a gap: the market is NAMED, so nobody else can seed it, there is no
    // other liquidity to move against, and the opening price is the caller's
    // own. minLP guards rounding here, not a counterparty.
    const p = await setup();
    await custom(p);
    p.click('lqCreate');
    await p.waitFor(() => p.chain.sent.length > 0, { label: 'create' });
    await p.settle();

    const b = '0x' + p.chain.lastSent.data.replace(/^0x/, '').slice(8);
    assert.equal(word(b, 11), 0n);
    p.close();
  });

  /**
   * One-sided bands, which is how a launch pool is seeded.
   *
   * The rule is Uniswap v3's: a band lying entirely on one side of the opening
   * price is a single asset. Inside the band the pool takes `min` of what each
   * side supports, so a missing side makes that zero and it reverts
   * ZeroAmount - confirmed against the live factory, which accepts a one-sided
   * seed at an edge and refuses the same amounts one price step inside.
   */
  test('accepts a token0-only band that opens at its low price', async () => {
    const p = await setup();
    await custom(p, { a0: '1', a1: '', lqPx: '1000', lqLo: '1000', lqHi: '5000' });
    assert.equal(p.$('lqCreate').disabled, false, 'the whole position is ETH, and that is allowed');
    p.click('lqCreate');
    await p.waitFor(() => p.chain.sent.length > 0, { label: 'create' });
    await p.settle();

    const b = '0x' + p.chain.lastSent.data.replace(/^0x/, '').slice(8);
    assert.equal(word(b, 8), word(b, 2), 'opening price sits exactly on sqrtPLow');
    assert.equal(word(b, 10), 0n, 'and nothing of token1 is deposited');
    p.close();
  });

  test('accepts a token1-only band that opens at its high price', async () => {
    const p = await setup();
    await custom(p, { a0: '', a1: '3000', lqPx: '5000', lqLo: '1000', lqHi: '5000' });
    assert.equal(p.$('lqCreate').disabled, false);
    p.click('lqCreate');
    await p.waitFor(() => p.chain.sent.length > 0, { label: 'create' });
    await p.settle();

    const b = '0x' + p.chain.lastSent.data.replace(/^0x/, '').slice(8);
    assert.equal(word(b, 8), word(b, 3), 'opening price sits exactly on sqrtPHigh');
    assert.equal(word(b, 9), 0n, 'no ETH');
    assert.equal(BigInt(p.chain.lastSent.value || 0), 0n, 'and nothing rides as value');
    p.close();
  });

  test('says where a one-sided band opens, rather than ignoring the price typed', async () => {
    // The opening price is DERIVED for a single asset - it is the edge the
    // band touches, which is what makes it single-asset. Quietly overriding
    // what someone typed is worse than refusing it.
    const p = await setup();
    await custom(p, { a0: '1', a1: '', lqPx: '1000', lqLo: '1000', lqHi: '5000' });
    assert.match(p.$('lqRangeOut').textContent, /opens at 1,?000 USDC per ETH/i);
    assert.match(p.$('lqRangeOut').textContent, /ETH only/i);
    assert.equal(p.$('lqCreate').disabled, false);

    p.click('lqCreate');
    await p.waitFor(() => p.chain.sent.length > 0, { label: 'create' });
    await p.settle();
    const b = '0x' + p.chain.lastSent.data.replace(/^0x/, '').slice(8);
    assert.equal(word(b, 8), word(b, 2), 'and it really does open at the low edge');
    p.close();
  });


  /**
   * Ranges as a width, not two prices.
   *
   * Two absolute prices are the hardest possible way to ask - nobody holds
   * them in their head, and they hide the only thing that matters, which is
   * how far the price can move before the position stops earning. A multiple
   * of the opening price says that directly.
   */
  test('a preset places the band around the opening price', async () => {
    const p = await setup();
    await preset(p, '2');
    await fill(p, { a0: '1', a1: '3000' });
    assert.match(p.$('lqRangeOut').textContent, /1,?500 – 6,?000/, 'a 2x width is half to double');
    assert.match(p.$('lqRangeOut').textContent, /opens at 3,?000 USDC per ETH/,
      'and the ratio of the deposit is what it opens at');
    p.close();
  });

  test('a one-sided deposit puts the whole band on one side of the price', async () => {
    // The Uniswap v3 rule, applied as a consequence rather than as a question:
    // depositing one asset IS a band that lies entirely on one side.
    const p = await setup();
    await preset(p, '2');
    // A single asset has no ratio, so this is the one case a price is asked
    // for - and the band then lies entirely on one side of it.
    await fill(p, { a0: '1', a1: '', lqPx: '3000' });
    assert.equal(p.$('lqPxRow').classList.contains('hide'), false, 'the price is asked for here');
    assert.match(p.$('lqRangeOut').textContent, /3,?000 – 6,?000/, 'above, for token0');
    assert.match(p.$('lqRangeOut').textContent, /ETH only/);

    const p2 = await setup();
    await preset(p2, '2');
    await fill(p2, { a0: '', a1: '3000', lqPx: '3000' });
    assert.match(p2.$('lqRangeOut').textContent, /1,?500 – 3,?000/, 'below, for token1');
    p2.close();
    p.close();
  });

  test('full range asks the chain how wide this deposit can go', async () => {
    // Width is bought with capital - the pool needs its virtual reserves above
    // MIN_RESOLUTION - so a fixed "full range" constant would fail for small
    // deposits, making the easiest option the most likely error. The widths
    // are tried in turn and the first the chain accepts is taken.
    const p = await setup();
    await fill(p, { a0: '1', a1: '3000' });
    // The mock accepts every createAndSeed, so the widest is chosen.
    assert.match(p.$('lqRangeOut').textContent, /^3(\.0+)? – 3,?000,?000/,
      'the widest width on offer, once nothing refuses it');
    assert.equal(p.$('lqCreate').disabled, false);
    p.close();
  });

  test('full range narrows when the deposit cannot back the widest', async () => {
    // Width is bought with capital: the pool needs lp above MIN_LIQUIDITY and
    // both virtual reserves above MIN_RESOLUTION. This deposit is a hundredth
    // of the one above, so the widest band no longer holds up.
    const p = await setup();
    await fill(p, { a0: '0.01', a1: '30' });
    const band = p.$('lqRangeOut').textContent;
    assert.match(band, /opens at 3,?000 USDC per ETH/, 'same price, from the same ratio');
    assert.ok(!/3,?000,?000/.test(band), `expected a narrower band than the widest, got ${band}`);
    assert.equal(p.$('lqCreate').disabled, false, 'and it is still creatable');
    p.close();
  });

  test('says so when even the narrowest range is out of reach', async () => {
    // Dust: no band at any width. Better than letting the pool answer
    // ZeroAmount after a wallet prompt.
    const p = await setup();
    // USDC has six decimals, so the dust has to be expressible in them.
    await fill(p, { a0: '0.000000000000001', a1: '0.000001' });
    assert.match(p.$('lqPv').textContent, /narrowest range needs more than this deposit/i);
    assert.equal(p.$('lqCreate').disabled, true);
    p.close();
  });

  test('draws where the band opens, on a log scale', async () => {
    // A full range spans six decades - 10 to 10,000,000 is ordinary - so a
    // linear mark would sit against the left edge at every realistic price and
    // say nothing.
    const p = await setup();
    await fill(p, good);
    const bar = p.$('lqRangeOut').querySelector('.lqbar');
    assert.ok(bar, 'the band should be drawn, not only spelled out');
    const at = parseFloat(bar.style.getPropertyValue('--at'));
    assert.ok(at > 45 && at < 55,
      `a band centred on its opening price should mark the middle, got ${at}%`);
    assert.equal(bar.classList.contains('out'), false);
    p.close();
  });

  test('marks a one-sided band at the edge it opens on', async () => {
    const p = await setup();
    await preset(p, '2');
    await fill(p, { a0: '1', a1: '', lqPx: '3000' });
    const at = parseFloat(p.$('lqRangeOut').querySelector('.lqbar').style.getPropertyValue('--at'));
    assert.ok(at < 5, `token0-only opens at the LOW edge, got ${at}%`);
    p.close();
  });

  test('offers a balance and a Max on the second side too', async () => {
    // Both fields are a deposit here, so "how much can I put in" applies to
    // both. On the swap tab the receive side is an output and never had one.
    const p = await setup();
    await p.waitFor(() => /Balance/.test(p.$('bal1').textContent), { label: 'second balance' });
    assert.equal(p.visible('bal1'), true);

    p.click(p.$('bal1').querySelector('a'));
    await p.settle();
    assert.equal(p.$('outAmt').value, '100000', 'the whole USDC balance, which needs no gas held back');
    p.close();
  });
});
