/**
 * The Deepstate venue on Robinhood Chain.
 *
 * DEEP's only market is Deepstate's order book - there is no AMM pool for it
 * anywhere - so before this path existed the page priced it at nothing and a
 * user picking it got "no route" for a token that trades. `DeepstateQuoteLens`
 * prices the book in one `view` call, and these tests cover the two things that
 * can still go wrong after a correct quote:
 *
 *   - the quote is right but never competes, so the venue is invisible; and
 *   - the quote is right, wins, and the calldata built from it names a
 *     different trade than the one that was priced.
 *
 * The second is the dangerous one. `swapDeep` takes the taker's packed order
 * word, and a bid's quantity is the base to MATCH with the fee taken afterwards
 * - so a caller that rebuilds that word from `amountOut` is taxed twice and
 * silently under-delivers. The lens returns the exact word it priced; this
 * asserts the page forwards that word rather than reconstructing one.
 */
import { test, after } from 'node:test';
import assert from 'node:assert/strict';
import { A, MockChain, loadPage, fixedRateQuoter, closeAllPages } from './harness.mjs';

after(closeAllPages);

const ETH = 10n ** 18n;
const DEEP = '0x1da24f6bb623b9d1afeae3f3146659a2662d6d27';
const USDG = '0x5fc5360d0400a0fd4f2af552add042d716f1d168';
const SWAPDEEP = 'ad33b1d0';
// The exact word the deployed lens returns for "sell 5,000 DEEP".
const ORDER = '0x8000000000000000000000000000010f0cf064dd59200000000000000000000000';

async function robinhood({ deep, rate = 3000n * ETH } = {}) {
  const chain = new MockChain({ chainId: '0x1237' }); // 4663
  chain.setNative(A.ACCOUNT, 10n * ETH);
  chain.setErc20(DEEP, A.ACCOUNT, 1_000_000n * ETH);
  chain.quoteHandler = fixedRateQuoter({ rate });
  chain.deepQuote = deep;
  const p = await loadPage({ chain, hash: null });
  await p.connect();
  return { p, chain };
}

test('the lens is asked, and its answer becomes a swapDeep leg', async () => {
  const { p, chain } = await robinhood({
    deep: { out: 6_243_750n, used: 5000n * ETH, epoch: 0n, order: ORDER.slice(0, 66), isBid: false },
  });
  const q = await p.window.eval(`deepQuote("${DEEP}","${USDG}",${5000n * ETH}n)`);
  assert.ok(q, 'the lens returned nothing');
  assert.equal(BigInt(q.out), 6_243_750n, 'output');
  assert.equal(BigInt(q.inUsed), 5000n * ETH, 'input absorbed');
  assert.equal(q.isBid, false, 'selling token0 is a taker ask');
  // Exactly one call, to the lens — no state overrides, no slot probing.
  const calls = chain.log.filter(r => r.method === 'eth_call'
    && String(r.params?.[0]?.data || '').slice(2, 10) === '1a0dc93f');
  assert.equal(calls.length, 1, `expected one lens call, saw ${calls.length}`);
  assert.equal(calls[0].params.length, 2, 'the lens must be a plain eth_call — no state override');
  p.close();
});

test('the order word the lens returned is forwarded verbatim into the calldata', async () => {
  const word = ORDER.slice(0, 66);
  const { p } = await robinhood({
    deep: { out: 6_243_750n, used: 5000n * ETH, epoch: 7n, order: word, isBid: false },
  });
  // Build the leg the way the page does, inside the page, so this exercises the
  // page's own encoders rather than a copy of them.
  const built = await p.window.eval(`(async()=>{
    const q=await deepQuote("${DEEP}","${USDG}",${5000n * ETH}n);
    if(!q)return null;
    return {epoch:q.epoch.toString(),order:q.order,
      leg:"0x${SWAPDEEP}"+encAddr("${A.ACCOUNT}")+encAddr(q.t0)+encAddr(q.t1)+encUint(q.epoch)
        +strip0x(q.order)+encUint(q.isBid?1:0)+encUint(${5000n * ETH}n)+encUint(0n)+encUint(0n)};
  })()`);
  assert.ok(built, 'no quote');
  assert.ok(built.leg.includes(word.slice(2)), 'the lens order word is not in the calldata');
  assert.equal(built.epoch, '7', 'epoch must come from the lens, not be assumed zero');
  p.close();
});

test('an empty book is no route, not a zero-priced one', async () => {
  const { p } = await robinhood({ deep: { out: 0n, used: 0n, epoch: 0n, order: '0x' + '0'.repeat(64), isBid: false } });
  assert.equal(await p.window.eval(`deepQuote("${DEEP}","${USDG}",${5000n * ETH}n)`), null);
  p.close();
});

test('the venue is Robinhood-only', async () => {
  const chain = new MockChain(); // mainnet
  chain.setNative(A.ACCOUNT, 10n * ETH);
  chain.quoteHandler = fixedRateQuoter({ rate: 3000n * ETH });
  chain.deepQuote = { out: 1n, used: 1n, epoch: 0n, order: '0x' + '1'.repeat(64), isBid: false };
  const p = await loadPage({ chain, hash: null });
  await p.connect();
  assert.equal(await p.window.eval(`deepQuote("${DEEP}","${USDG}",${1000n * ETH}n)`), null,
    'Deepstate must not be quoted off Robinhood Chain');
  p.close();
});

/**
 * The venue has to stand on its own.
 *
 * Every test above hands the page a working AMM quoter, which is the one thing
 * production never has for these pairs: DEEP has no pool anywhere, so zQuoter
 * reverts and the page threw "bad quote" before it had even awaited the book.
 * The lens was right, the leg was right, and every token whose only market is
 * the book was unreachable: USDG/DEEP, DEEP/USDG and USDG/STATE all read "No
 * route" on the live chain, while NVDA quoted fine throughout because it also
 * has an AMM pool for the book to be compared against. That is the tell - the
 * venue only failed where it was the sole venue. So the case worth pinning is
 * the one with no AMM answer at all.
 */
test('a pair only the book prices still quotes, with no AMM route to compare', async () => {
  const chain = new MockChain({ chainId: '0x1237' });
  chain.setNative(A.ACCOUNT, 10n * ETH);
  chain.setErc20(USDG, A.ACCOUNT, 1_000_000n * 10n ** 6n);
  // Exactly production: the quoter has nothing for this pair and reverts.
  chain.quoteHandler = () => null;
  chain.deepQuote = { out: 666n * ETH, used: 10n ** 6n, epoch: 0n, order: ORDER.slice(0, 66), isBid: true };
  const p = await loadPage({ chain, hash: null });
  await p.connect();
  // DEEP first: USDG is the landing pair's output, so it cannot be picked as
  // the input until the other side has moved off it.
  p.pickToken('toSel', 'DEEP');
  p.pickToken('fromSel', 'USDG');
  await p.settle();
  await p.typeAmount('amt', '1');
  assert.equal(p.text('stat'), '', 'the book alone must not read as "no route"');
  const shown = Number(p.value('outAmt'));
  assert.ok(Math.abs(shown - 666 * 0.995) < 0.01, `the book price, less the bid's slack, is shown: ${shown}`);
  const built = await p.window.eval('last.callData');
  assert.ok(built.includes(bidWord(ORDER.slice(0, 66))), 'the bid names its quantity less the slack');
  assert.equal(await p.window.eval('last.limit.toString()'), bidOut(666n * ETH).toString(),
    "a bid's floor is its exact output, not that output less slippage again");
  p.close();
});

/**
 * Reaching the book through an AMM.
 *
 * Every Deepstate book on the chain is quoted in USDG - NVDA, DEEP and STATE
 * each book against it and nothing else - so ETH/DEEP is not a market and never
 * will be. It is two legs: an AMM leg to USDG and then the book. The router
 * already chains them, because a leg addressed to the router leaves its output
 * as a transient credit and `swapDeep` spends that credit when one covers its
 * `amountInMax`.
 *
 * That last word is the whole risk. `swapDeep` takes a literal maximum with no
 * "spend whatever the last leg produced" form, so if the book leg is sized at
 * what the AMM was *expected* to deliver and the AMM delivers a hair less, the
 * credit no longer covers it, the router falls back to pulling from the caller,
 * and the whole trade reverts. Sizing it at the AMM's guaranteed floor instead
 * is what makes the composition safe, and that is what these pin.
 */
const HOPSWEEP = 'dc2c256f';

/**
 * A BID names the base quantity it buys, at the widest price limit, with the
 * budget as its only bound. Named at exactly what the budget buys today, any
 * uptick on the asks makes it cost more than the budget and the fill reverts,
 * whatever the slippage setting. So the page names a bid SLACK smaller -
 * min(slippage, 0.5%) - and takes the change back: the unspent input is
 * refunded by the router (or swept, inside a hop). Its output is then exact
 * (less a unit of rounding), so a bid's floor is that output itself.
 */
const SLACK = 50n;
const bidOut = out => out - (out * SLACK) / 10000n - 1n;
const bidWord = (word, k = SLACK) => {
  const M = (1n << 160n) - 1n, w = BigInt(word), q = (w >> 64n) & M;
  return (w & ~(M << 64n) | (q - (q * k) / 10000n) << 64n).toString(16).padStart(64, '0');
};

function hopChain({ rate = 2500n * ETH } = {}) {
  const chain = new MockChain({ chainId: '0x1237' });
  chain.setNative(A.ACCOUNT, 10n * ETH);
  chain.setErc20(DEEP, A.ACCOUNT, 1_000_000n * ETH);
  // The AMM prices ETH -> USDG and nothing else; DEEP has no pool at all.
  chain.quoteHandler = ({ selector, data }) => {
    const inner = fixedRateQuoter({ rate });
    const body = '0x' + data.slice(10);
    if (!body.toLowerCase().includes(USDG.slice(2))) return null;
    return inner({ selector, data });
  };
  // Only USDG books against DEEP, and the fill is proportional to what is sent.
  chain.deepQuote = ({ tokenIn, tokenOut, amount }) => {
    if (tokenIn.toLowerCase() !== USDG || tokenOut.toLowerCase() !== DEEP) return null;
    return { out: amount * 10n ** 12n * 666n, used: amount, epoch: 3n, order: ORDER.slice(0, 66), isBid: true };
  };
  return chain;
}

test('ETH to DEEP composes an AMM leg into the book', async () => {
  const chain = hopChain();
  const p = await loadPage({ chain, hash: null });
  await p.connect();
  p.pickToken('toSel', 'DEEP');
  p.pickToken('fromSel', 'ETH');
  await p.settle();
  await p.typeAmount('amt', '1');
  assert.equal(p.text('stat'), '', 'a two-leg route must not read as no route');
  assert.ok(Number(p.value('outAmt')) > 0, `expected DEEP out, got "${p.value('outAmt')}"`);

  const built = await p.window.eval('last.callData');
  assert.ok(built.includes(SWAPDEEP), 'no swapDeep leg in the composed calldata');
  assert.ok(built.includes(bidWord(ORDER.slice(0, 66), SLACK / 2n)), 'the book leg carries the lens word, its bid quantity cut by the slack');
  assert.ok(built.includes(HOPSWEEP), 'the surplus of the intermediate must be swept back');
  assert.equal(await p.window.eval('last.msgValue.toString()'), (10n ** 18n).toString(),
    'the ether leg is paid with the transaction value');
  p.close();
});

test('the book leg is sized at the AMM floor, never at its expected output', async () => {
  const seen = [];
  const chain = hopChain();
  const book = chain.deepQuote;
  chain.deepQuote = (ask) => { seen.push(ask); return book(ask); };
  const p = await loadPage({ chain, hash: null });
  await p.connect();
  p.pickToken('toSel', 'DEEP');
  p.pickToken('fromSel', 'ETH');
  await p.settle();
  await p.typeAmount('amt', '1');
  const priced = seen.filter(a => a.tokenIn.toLowerCase() === USDG && a.amount > 0n).pop();
  assert.ok(priced, 'the book was never asked to price the second leg');
  // 1 ETH at the fixture rate, less the 0.25% the AMM leg is allowed to slip
  // (half the 0.5% setting: the hop has two legs).
  const expected = 2500n * 10n ** 6n;
  const floor = expected * 9975n / 10000n;
  assert.ok(priced.amount <= floor,
    `the book was sized at ${priced.amount}, above the AMM floor ${floor} - a short fill would revert`);
  assert.ok(priced.amount > floor * 9990n / 10000n,
    `sized at ${priced.amount}, needlessly far below the floor ${floor}`);
  p.close();
});

test('DEEP to ETH takes the book first, then the AMM', async () => {
  const chain = new MockChain({ chainId: '0x1237' });
  chain.setNative(A.ACCOUNT, 10n * ETH);
  chain.setErc20(DEEP, A.ACCOUNT, 1_000_000n * ETH);
  chain.quoteHandler = ({ selector, data }) => {
    const body = '0x' + data.slice(10);
    if (!body.toLowerCase().includes(USDG.slice(2))) return null;
    return fixedRateQuoter({ rate: ETH / 2500n, decIn: 6, decOut: 18 })({ selector, data });
  };
  chain.deepQuote = ({ tokenIn, tokenOut, amount }) => {
    if (tokenIn.toLowerCase() !== DEEP || tokenOut.toLowerCase() !== USDG) return null;
    return { out: amount / 10n ** 12n / 666n, used: amount, epoch: 1n, order: ORDER.slice(0, 66), isBid: false };
  };
  const p = await loadPage({ chain, hash: null });
  await p.connect();
  p.pickToken('fromSel', 'DEEP');
  p.pickToken('toSel', 'ETH');
  await p.settle();
  await p.typeAmount('amt', '5000');
  assert.equal(p.text('stat'), '', 'selling into the book through an AMM must quote');
  const built = await p.window.eval('last.callData');
  const bookAt = built.indexOf(SWAPDEEP);
  assert.ok(bookAt > 0, 'no swapDeep leg');
  // Selling means the book runs first and hands the AMM its credit, so the
  // book leg has to appear ahead of the sweeps that clean up after it.
  assert.ok(bookAt < built.indexOf(HOPSWEEP), 'the book leg must precede the sweeps');
  assert.equal(await p.window.eval('last.msgValue.toString()'), '0', 'selling a token attaches no value');
  assert.equal(await p.window.eval('last.spender'), await p.window.eval('ZROUTER'),
    'the router has to be approved to pull the token being sold');
  p.close();
});

test('a pair with a direct route is left alone', async () => {
  const chain = hopChain();
  let bookAsks = 0;
  chain.deepQuote = () => { bookAsks++; return null; };
  const p = await loadPage({ chain, hash: null });
  await p.connect();
  p.pickToken('toSel', 'USDG');
  p.pickToken('fromSel', 'ETH');
  await p.settle();
  await p.typeAmount('amt', '1');
  assert.ok(Number(p.value('outAmt')) > 0, 'the direct AMM route still quotes');
  const built = await p.window.eval('last.callData');
  assert.ok(!built.includes(SWAPDEEP), 'a pair the AMM prices must not be routed through the book');
  p.close();
});

/**
 * Both legs can be the book.
 *
 * DEEP and STATE each book against USDG and nothing else, and neither has an
 * AMM pool, so DEEP/STATE is two book legs with USDG in between - no AMM
 * anywhere in the route. The router allows it: the fill lock is restored after
 * each fill, so the second `swapDeep` does not read as nested and spends the
 * credit the first one left.
 *
 * This also pins the shape of the composed call, because a route that is priced
 * correctly and then encoded with the wrong arity throws inside the quote, gets
 * swallowed by the catch that guards it, and reads on screen as an ordinary
 * "no route" - or, worse, as a working quote that came from somewhere else.
 */
const STATE = '0xbfb7b3ff3d498a559b946b836d26f0e168f273d5';

test('a pair only two books can reach is routed through both', async () => {
  const chain = new MockChain({ chainId: '0x1237' });
  chain.setNative(A.ACCOUNT, 10n * ETH);
  chain.setErc20(DEEP, A.ACCOUNT, 1_000_000n * ETH);
  // No AMM route exists for anything here.
  chain.quoteHandler = () => null;
  chain.deepQuote = ({ tokenIn, tokenOut, amount }) => {
    const inTok = tokenIn.toLowerCase(), outTok = tokenOut.toLowerCase();
    // DEEP -> USDG at 1/800 (18 dec in, 6 dec out)
    if (inTok === DEEP && outTok === USDG) {
      return { out: amount / 10n ** 12n / 800n, used: amount, epoch: 1n, order: ORDER.slice(0, 66), isBid: false };
    }
    // USDG -> STATE at 50 (6 dec in, 18 dec out)
    if (inTok === USDG && outTok === STATE) {
      return { out: amount * 10n ** 12n * 50n, used: amount, epoch: 2n, order: ORDER.slice(0, 66), isBid: true };
    }
    return null;
  };
  const p = await loadPage({ chain, hash: null });
  await p.connect();
  await p.window.eval(`addCustomToken("${STATE}",0)`).catch(() => {});
  await p.settle();
  const hop = await p.window.eval(`(async()=>{
    const c = await deepHop({addr:"${DEEP}"},{addr:"${STATE}"},${5000n * ETH}n,50n,
      BigInt(Math.floor(Date.now()/1e3)+1800),"${A.ACCOUNT}",await blockNow(),"${A.ACCOUNT}");
    if(!c) return null;
    return {out:c.best.amountOut.toString(), books:(c.callData.match(/${SWAPDEEP}/g)||[]).length,
            msgValue:c.msgValue.toString()};
  })()`);
  assert.ok(hop, 'two books that share a quote asset must compose into a route');
  assert.equal(hop.books, 2, 'a book-to-book route is two swapDeep legs, not one');
  assert.equal(hop.msgValue, '0', 'selling a token attaches no value');
  // 5000 DEEP -> 6.25 USDG, less 0.5% slippage and the basis point, times 50.
  const mid = (5000n * ETH / 10n ** 12n / 800n) * 9950n / 10000n;
  const expected = bidOut((mid - mid / 10000n) * 10n ** 12n * 50n);
  assert.equal(hop.out, expected.toString(), 'the second book must price what the first one guarantees');
  p.close();
});

/**
 * Two ways out of the intermediate, and only one of them is best.
 *
 * Once the first leg has sold into a book, the credit sitting on the router can
 * be taken by a pool OR by a second book - USDG has both an AMM market and a
 * book against some tokens. Both second legs are priced on the same guaranteed
 * midMin, so their outputs are directly comparable, and the page compares every
 * other venue it knows about. Taking whichever answered first instead would
 * quietly hand the trade to the pool whenever a pool existed, however much
 * better the book was paying.
 */
const hopBoth = ({ ammRate }) => {
  const chain = new MockChain({ chainId: '0x1237' });
  chain.setNative(A.ACCOUNT, 10n * ETH);
  chain.setErc20(DEEP, A.ACCOUNT, 1_000_000n * ETH);
  // The pool prices USDG -> STATE and nothing else; DEEP has no pool at all.
  chain.quoteHandler = ({ selector, data }) => {
    const body = '0x' + data.slice(10);
    if (!body.toLowerCase().includes(USDG.slice(2))) return null;
    return fixedRateQuoter({ rate: ammRate * ETH, decIn: 6, decOut: 18 })({ selector, data });
  };
  chain.deepQuote = ({ tokenIn, tokenOut, amount }) => {
    const a = tokenIn.toLowerCase(), b = tokenOut.toLowerCase();
    // DEEP -> USDG at 1/800, and a USDG -> STATE book paying 50.
    if (a === DEEP && b === USDG) {
      return { out: amount / 10n ** 12n / 800n, used: amount, epoch: 1n, order: ORDER.slice(0, 66), isBid: false };
    }
    if (a === USDG && b === STATE) {
      return { out: amount * 10n ** 12n * 50n, used: amount, epoch: 2n, order: ORDER.slice(0, 66), isBid: true };
    }
    return null;
  };
  return chain;
};

const IN = 5000n * ETH;
// 5,000 DEEP -> 6.25 USDG, less the 0.5% the first leg may slip and the basis
// point of headroom, is what either second leg is sized and priced on.
const MID_MIN = (() => {
  const out = IN / 10n ** 12n / 800n;
  const slipped = out - (out * 50n) / 10000n;
  return slipped - slipped / 10000n;
})();

const askHop = p => p.window.eval(`(async()=>{
  const c = await deepHop({addr:"${DEEP}"},{addr:"${STATE}"},${IN}n,50n,
    BigInt(Math.floor(Date.now()/1e3)+1800),"${A.ACCOUNT}",await blockNow(),"${A.ACCOUNT}");
  if(!c) return null;
  return {out:c.best.amountOut.toString(), books:(c.callData.match(/${SWAPDEEP}/g)||[]).length};
})()`);

test('the book takes the second leg when it pays more than the pool', async () => {
  const p = await loadPage({ chain: hopBoth({ ammRate: 40n }), hash: null });
  await p.connect();
  await p.settle();
  const hop = await askHop(p);
  assert.ok(hop, 'a route exists through either second leg');
  assert.equal(hop.books, 2, 'the better-paying book must take the second leg, not the pool');
  assert.equal(hop.out, bidOut(MID_MIN * 10n ** 12n * 50n).toString(), 'and its price, less the bid slack, is what is quoted');
  p.close();
});

test('the pool takes the second leg when it pays more than the book', async () => {
  const p = await loadPage({ chain: hopBoth({ ammRate: 60n }), hash: null });
  await p.connect();
  await p.settle();
  const hop = await askHop(p);
  assert.ok(hop, 'a route exists through either second leg');
  assert.equal(hop.books, 1, 'only the first leg is a book when the pool pays more');
  assert.equal(hop.out, (MID_MIN * 60n * 10n ** 12n).toString(), 'and its price is what is quoted');
  p.close();
});
