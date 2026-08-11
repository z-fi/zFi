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
const fill = async (p, vals) => {
  const box = form(p);
  for (const [id, v] of Object.entries(vals)) {
    const el = box.querySelector('#' + id);
    el.value = v;
    el.dispatchEvent(new p.window.Event('input', { bubbles: true }));
  }
  await new Promise(r => p.window.setTimeout(r, 360));
  await p.settle();
};
const good = { lqLo: '1000', lqHi: '5000', lqPx: '3000', lqA0: '1', lqA1: '3000' };

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
    await fill(p, { ...good, lqLo: '5000', lqHi: '1000' });
    assert.match(p.$('lqPv').textContent, /low price must be below/i);
    assert.equal(p.$('lqCreate').disabled, true);
    p.close();
  });

  test('refuses an opening price outside its own band', async () => {
    // The pool would take it and the first trade would arbitrage it. Cheaper
    // to say so than to let the chain answer with a revert.
    const p = await setup();
    await fill(p, { ...good, lqPx: '9000' });
    assert.match(p.$('lqPv').textContent, /inside the band/i);
    assert.equal(p.$('lqCreate').disabled, true);
    p.close();
  });

  test('previews exactly when the market exists but was never seeded', async () => {
    // The factory allows this and seeds rather than rejecting, and it is the
    // only case where the lens has a pool to read.
    const p = await setup({ deployed: true });
    await fill(p, good);
    assert.match(p.$('lqPv').textContent, /Seeds 1 ETH \+ 3,?000 USDC/);
    assert.equal(p.$('lqCreate').disabled, false);
    p.close();
  });

  test('says when the rest comes back, because the amounts are maxima', async () => {
    // A seed takes the ratio the opening price implies and returns the excess.
    const p = await setup({ band: { low: sq(1000), high: sq(5000), used0: ETH / 2n }, deployed: true });
    await fill(p, good);
    assert.match(p.$('lqPv').textContent, /the rest is returned/i);
    p.close();
  });

  test('deploys and seeds in one transaction, with the band it previewed', async () => {
    const p = await setup();
    await fill(p, good);
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
    assert.equal(word(b, 8), sq(3000), 'sqrtPriceInit: where trading opens');
    assert.equal(word(b, 9), ETH, 'amount0');
    assert.equal(word(b, 10), 3000n * USDC, 'amount1');
    assert.equal(wordAddr(b, 12).toLowerCase(), A.ACCOUNT.toLowerCase(), 'LP shares to you');
    p.close();
  });

  test('names the market to you, at no fee to traders', async () => {
    // An unnamed market may be seeded by anyone, so a stranger could open it at
    // a price of their choosing before you do. Naming closes that, and a zero
    // creator fee means it costs traders nothing to be protected.
    const p = await setup();
    await fill(p, good);
    p.click('lqCreate');
    await p.waitFor(() => p.chain.sent.length > 0, { label: 'create' });
    await p.settle();

    const b = '0x' + p.chain.lastSent.data.replace(/^0x/, '').slice(8);
    assert.equal(wordAddr(b, 6).toLowerCase(), A.ACCOUNT.toLowerCase(),
      'feeRecipient: only its creator may seed a named market');
    assert.equal(word(b, 7), 0n, 'creatorFeeBps: naming should cost traders nothing');
    p.close();
  });

  test('carries a slippage floor under the previewed shares', async () => {
    const p = await setup({ deployed: true });
    await fill(p, good);
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
    await fill(p, good);
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
    await fill(p, good);
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
    await fill(p, good);
    assert.match(p.$('lqPv').textContent, /Deposits up to 1 ETH \+ 3,?000 USDC/);
    assert.match(p.$('lqPv').textContent, /returns the rest/i, 'the amounts are maxima either way');
    assert.equal(p.$('lqCreate').disabled, false, 'and it must still be creatable');
    p.close();
  });

  test('sends no share floor when there was no preview to floor', async () => {
    // Not a gap: the market is NAMED, so nobody else can seed it, there is no
    // other liquidity to move against, and the opening price is the caller's
    // own. minLP guards rounding here, not a counterparty.
    const p = await setup();
    await fill(p, good);
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
    await fill(p, { lqLo: '1000', lqHi: '5000', lqPx: '1000', lqA0: '1', lqA1: '' });
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
    await fill(p, { lqLo: '1000', lqHi: '5000', lqPx: '5000', lqA0: '', lqA1: '3000' });
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

  test('says where to move the opening price when one side is left out', async () => {
    // The pool would answer ZeroAmount, which does not tell you that moving
    // the opening price to the edge is the fix.
    const p = await setup();
    await fill(p, { lqLo: '1000', lqHi: '5000', lqPx: '3000', lqA0: '1', lqA1: '' });
    assert.match(p.$('lqPv').textContent, /ETH-only band has to open at its low price/i);
    assert.match(p.$('lqPv').textContent, /1000/, 'and names the price to use');
    assert.equal(p.$('lqCreate').disabled, true);
    assert.equal(p.chain.sent.length, 0);
    p.close();
  });
});
