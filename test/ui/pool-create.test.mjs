/**
 * Creating a Precision band from the liquidity panel.
 *
 * A pool is a PRICE RANGE, not just a pair, so creating one is a decision the
 * page cannot make for you: where the band sits, and where inside it trading
 * starts. That is why it was never folded into "add liquidity" - adding joins
 * a band somebody already chose, and choosing badly here is arbitrageable
 * rather than merely suboptimal.
 *
 * Two defaults are asserted below because both are security-relevant rather
 * than cosmetic:
 *
 *   the market is created UNOWNED (feeRecipient zero), so anyone may add and
 *   no creator fee can ever be charged - see 'creates an unowned market by
 *   default'
 *
 *   the creator fee is ZERO, which is what ownership would otherwise buy
 *
 * This header used to claim the opposite - that the market is created NAMED,
 * "the only thing that stops a stranger seeding your pool at a price of their
 * choosing". The assertion below has always checked for a zero recipient, so
 * the prose and the test disagreed. What actually protects the opening price
 * is that `createAndSeed` deploys and seeds in ONE call and reverts `Exists()`
 * on a pool that already holds liquidity.
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

async function setup({ band = { low: sq(1000), high: sq(5000) }, deployed = false, supply = 0n } = {}) {
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
  // What the predicted address answers `totalSupply()` with. Nonzero means the
  // band already exists AND holds liquidity, which `createAndSeed` refuses.
  chain.seedSupply = supply;
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
  // The tile's two boxes are the deposit, mapped BY TOKEN: `chPair()` sorts by
  // address because that is how a pool stores its pair, while the tile is in
  // picker order. `a0`/`a1` here mean token0/token1, so put each one wherever
  // that token currently sits.
  const pay = p.$('fromSel');
  const payIs0 = (p.window.getComputedStyle ? true : true) &&
    (p.$('fromSel').dataset.addr || '').toLowerCase() <= (p.$('toSel').dataset.addr || '').toLowerCase();
  const el0 = payIs0 ? 'amt' : 'outAmt', el1 = payIs0 ? 'outAmt' : 'amt';
  if (a0 !== undefined) { p.$(el0).value = a0; p.type(el0, a0); }
  if (a1 !== undefined) { p.$(el1).value = a1; p.type(el1, a1); }
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

  test('previews the seed itself, deployed or not', async () => {
    // `previewSeed` cannot answer for a band that does not exist - `_band`
    // reverts NoPool on an address with no code - and a band that does not
    // exist is what this form creates. So the seed is mirrored in the page
    // (`lqSeedQuote`, pinned to the lens by test/fixtures/seed-preview.json)
    // and the answer no longer depends on whether anyone deployed the market
    // first. It used to: undeployed, the page printed the amounts back
    // unchecked, which is not a preview of anything.
    const a = await setup();                     // predicted, no code
    await custom(a);
    const undeployed = a.$('lqPv').textContent;
    assert.match(undeployed, /^Seeds /);
    assert.equal(a.$('lqCreate').disabled, false);

    const b = await setup({ deployed: true });   // created but never seeded
    await custom(b);
    assert.equal(b.$('lqPv').textContent, undeployed, 'the same seed, either way');
    a.close(); b.close();
  });

  test('says when the rest comes back, because the amounts are maxima', async () => {
    // A seed takes the ratio the opening price implies and returns the excess.
    // 1 ETH against 3000 USDC over a 1000-5000 band consumes all of the USDC
    // and a hair under the ETH, which is a refund and has to be spoken of as
    // one - the figure is what the pool will really take.
    const p = await setup();
    await custom(p);
    assert.match(p.$('lqPv').textContent, /Seeds 0\.999999 ETH \+ 3,?000 USDC/);
    assert.match(p.$('lqPv').textContent, /the rest is returned/i);
    p.close();
  });

  test('will not create a band that is already seeded', async () => {
    // `createAndSeed` reverts Exists() on a market that holds liquidity - the
    // address is CREATE2-derived from the whole tuple, so an identical band
    // cannot be redeployed. Cheaper to say so than to let the wallet say it.
    const p = await setup({ deployed: true, supply: 10n ** 21n });
    await custom(p);
    assert.match(p.$('lqPv').textContent, /already exists/i);
    assert.equal(p.$('lqCreate').disabled, true);
    assert.equal(p.chain.sent.length, 0);
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

  test('mints the shares to the recipient field, not always to you', async () => {
    // The field is live in this mode - it resolves names, and both `addLiquidity`
    // and the zap honour it. Seeding sent `account` regardless, which is the one
    // place the label ("LP shares to") and the transaction disagreed.
    const to = '0x' + '5c'.repeat(20);
    const p = await setup();
    await custom(p);
    p.type('rc', to);
    await new Promise(r => p.window.setTimeout(r, 340));
    await p.settle();
    p.click('lqCreate');
    await p.waitFor(() => p.chain.sent.length > 0, { label: 'create' });
    await p.settle();

    const b = '0x' + p.chain.lastSent.data.replace(/^0x/, '').slice(8);
    assert.equal(wordAddr(b, 12).toLowerCase(), to, 'LP shares go where the field says');
    p.close();
  });

  test('refuses to create when the recipient does not resolve', async () => {
    const p = await setup();
    await custom(p);
    p.type('rc', 'nope.eth');
    await new Promise(r => p.window.setTimeout(r, 340));
    await p.settle();
    p.click('lqCreate');
    await p.settle();
    assert.equal(p.chain.sent.length, 0, 'nothing signed against an unresolved name');
    assert.match(p.text('stat'), /must be an address or a/i);
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

  test('does not ask about ownership at all', async () => {
    // The only thing it could buy today is a gate on who may OPEN the market -
    // creatorFeeBps is fixed at zero here and immutable in the pool - and that
    // is a narrow, jargon-heavy trade to put at the same weight as Range and
    // Fee, which change what the position earns. It comes back with the
    // creator fee, because a fee REQUIRES a recipient: they are one decision.
    const p = await setup();
    await custom(p);
    assert.equal(form(p).querySelector('#lqOwn'), null, 'no ownership control');
    assert.match(p.$('lqOwnNote').textContent, /Unowned, like any AMM pool/i);
    assert.match(p.$('lqOwnNote').textContent, /no creator fee can ever be charged/i);
    p.close();
  });



  test('carries a slippage floor under the previewed shares', async () => {
    // And it carries one on EVERY create, not only when a lens happened to
    // answer. This used to send zero whenever the band did not already exist,
    // which is the ordinary case, on the reasoning that the market was NAMED
    // and so nobody else could seed it - but the page creates an UNOWNED
    // market (see 'creates an unowned market by default' above), so that
    // reasoning had not been true for some time.
    const p = await setup();
    await custom(p);
    p.click('lqCreate');
    await p.waitFor(() => p.chain.sent.length > 0, { label: 'create' });
    await p.settle();

    const b = '0x' + p.chain.lastSent.data.replace(/^0x/, '').slice(8);
    const seeded = p.window.lqSeedQuote(word(b, 2), word(b, 3), word(b, 8), word(b, 9), word(b, 10));
    assert.ok(seeded.ok && seeded.lp > 0n, 'the calldata sent describes a seed that works');
    const minLP = word(b, 11);
    assert.ok(minLP > 0n && minLP < seeded.lp, 'a floor, not the preview itself');
    assert.equal(minLP, seeded.lp * 9950n / 10000n, 'the page slippage, 0.5% by default');
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
    // The pool needs both virtual reserves above MIN_RESOLUTION, which is a
    // property of the band's WIDTH against the deposit - a band the deposit
    // cannot back at all is a different thing from a poor rate, and it must
    // not be clickable. THE ORDINARY CASE IS THE UNDEPLOYED ONE, and this
    // refusal was unreachable there for as long as it came from the lens.
    const p = await setup();                 // not deployed
    await custom(p, { a0: '1', a1: '3000', lqLo: '0.0001', lqHi: '300000000' });
    assert.match(p.$('lqPv').textContent, /cannot open at that price/i);
    assert.equal(p.$('lqCreate').disabled, true);
    assert.equal(p.chain.sent.length, 0);
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

  test('reads the two deposits by token, not by which field they sit in', async () => {
    /**
     * The tile's fields are in PICKER order; `chPair()` sorts the pair by
     * ADDRESS, because that is the order a pool is stored in. They agree only
     * by luck - ETH sorts first as the zero address, so every other test here
     * uses a pair that hides this - and disagree the moment the pay side is
     * the higher address.
     *
     * USDC (0xa0b8…) → WBTC (0x2260…) is exactly that: the form read the USDC
     * figure as amount0 and parsed it with WBTC's 8 decimals, so the opening
     * price came out reciprocal and the band, the seed and `createAndSeed`'s
     * value were all built from the two deposits swapped.
     */
    const p = await setup();
    // Receive side first: USDC starts there, and the page refuses the same
    // asset on both sides, so it has to move before the pay side can take it.
    p.pickToken('toSel', 'WBTC');
    p.pickToken('fromSel', 'USDC');
    await p.settle();
    // token0 is WBTC here, so the panel prices USDC per WBTC either way - what
    // the bug changed is which field it took each amount from.
    assert.match(p.$('lqSub').textContent, /WBTC\s*\/\s*USDC/, 'sorted, as the pool stores it');
    // A preset band is centred on the opening price, so what the line reports
    // is the ratio itself rather than a seed price solved against fixed edges.
    p.type('amt', '3000');       // USDC, the pay side
    p.type('outAmt', '1');       // WBTC, the receive side
    await new Promise(r => p.window.setTimeout(r, 420));
    await p.settle();
    const band = p.$('lqRangeOut').textContent;
    assert.match(band, /opens at 3,?000 USDC per WBTC/,
      `1 WBTC against 3000 USDC is a price of 3000, got: ${band}`);
    // The reciprocal is what the bug produced, and it is inside the band too -
    // so the preview looked perfectly healthy while seeding the wrong pool.
    assert.doesNotMatch(band, /opens at 0\.000/, 'the price must not come out inverted');
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

  test('prices the deployment before the wallet is asked', async () => {
    // A Precision market IS a contract: the create deploys ~19.4 KB of pool
    // code, and code deposit alone is 200 gas a byte. The first real create
    // cost 4.63M gas - twenty-odd times an ordinary transaction - and a wallet
    // offering its usual tip on top turned 0.0014 ETH into 0.010 ETH without
    // ever looking wrong. The number has to be visible while it can still be
    // questioned.
    const p = await setup();
    await custom(p);
    await p.waitFor(() => /M gas/.test(p.$('lqGas').textContent), { label: 'the cost' });
    assert.match(p.$('lqGas').textContent, /deploys the pool contract/i);
    assert.match(p.$('lqGas').textContent, /4\.7M gas/);
    assert.match(p.$('lqGas').textContent, /check the fee your wallet offers/i,
      'the tip is the half the dapp cannot set');
    p.close();
  });
});
