/**
 * Floorboard, the bid side of the book, end to end through the page.
 *
 * A standing bid is liquidity for the same trade the swap panel quotes — a
 * bidder offering USDC for ETH is somewhere an ETH seller can sell — but it is
 * stated from the BUYER's side, so every field is mirrored relative to an ask.
 * `token` is what the bid buys, which is what the user pays; `quote` is what it
 * pays out, which is what the user receives. A page that has that backwards
 * produces quotes that look plausible and route the wrong direction.
 *
 * So these tests assert the mirror, the arithmetic (the board rounds DOWN
 * against a basis of the bid's ORIGINAL size, which a linear rate does not
 * reproduce), and the exact transaction the wallet is handed.
 */
import { test, describe, it, after } from 'node:test';
import assert from 'node:assert/strict';
import {
  A, SEL, MockChain, loadPage, fixedRateQuoter, word, wordAddr, selectorOf, closeAllPages,
} from './harness.mjs';

after(closeAllPages);

const ETH = 10n ** 18n;
const USDC = 10n ** 6n;

/**
 * A bid buying WETH and paying USDC at 4,000 per ETH, sized at 10 ETH.
 * Flat schedule, so `price` is the whole ask for the whole initial size.
 */
const bidWethForUsdc = (over = {}) => ({
  id: 7n,
  token: A.WETH,
  quote: A.USDC,
  remaining: 10n * ETH,
  initial: 10n * ETH,
  price: 40_000n * USDC,
  proceeds: 40_000n * USDC,
  expiry: 0n,
  tokenDecimals: 18,
  quoteDecimals: 6,
  tokenSymbol: 'WETH',
  quoteSymbol: 'USDC',
  ...over,
});

async function setup(prep = () => {}, { rate = 3000n * ETH } = {}) {
  const chain = new MockChain();
  chain.setNative(A.ACCOUNT, 100n * ETH);
  chain.setErc20(A.WETH, A.ACCOUNT, 100n * ETH);
  chain.setErc20(A.USDC, A.ACCOUNT, 500_000n * USDC);
  chain.quoteHandler = fixedRateQuoter({ rate });
  prep(chain);
  const p = await loadPage({ chain });
  await p.connect();
  return p;
}

/** Quote ETH -> USDC and settle. */
async function quoteEthToUsdc(p, amount = '1') {
  p.select('fromSel', 0);   // ETH
  p.select('toSel', 5);     // USDC
  await p.settle();
  // `typeAmount`, not `type`: the page debounces input by 250ms, so settling on
  // RPC quiet alone returns before the quote has started.
  await p.typeAmount('amt', amount);
}

// ---------------------------------------------------------------- the mirror

describe('reading bids as routable liquidity', () => {
  it('maps a bid onto the taker\'s side of the trade', async () => {
    const p = await setup(c => { c.floorBids = [bidWethForUsdc()]; });
    const rows = await p.window.floorCandidates(A.ZERO, A.USDC, 'latest');
    assert.equal(rows.length, 1, 'the bid was not offered for ETH -> USDC');
    const r = rows[0];
    // What the user PAYS is the asset the bid buys...
    assert.equal(r.tB.toLowerCase(), A.WETH.toLowerCase());
    assert.equal(r.aB, 10n * ETH);
    // ...and what they RECEIVE is what it pays out.
    assert.equal(r.tA.toLowerCase(), A.USDC.toLowerCase());
    assert.equal(r.aA, 40_000n * USDC);
    assert.equal(r.board.toLowerCase(), A.FLOOR.toLowerCase());
    assert.equal(r.floor, 1);
    assert.equal(r.pf, 1, 'a fungible bid is partially fillable');
    p.close();
  });

  it('does not offer a bid pointing the other way', async () => {
    // Buys USDC, pays WETH. Same two tokens, opposite trade.
    const p = await setup(c => {
      c.floorBids = [bidWethForUsdc({ token: A.USDC, quote: A.WETH })];
    });
    const rows = await p.window.floorCandidates(A.ZERO, A.USDC, 'latest');
    assert.equal(rows.length, 0, 'a bid selling ETH was offered to an ETH seller');
    p.close();
  });

  it('leaves NFT bids out of the fungible route', async () => {
    const p = await setup(c => {
      c.floorBids = [bidWethForUsdc({ isNFT: true, anyId: true })];
    });
    const rows = await p.window.floorCandidates(A.ZERO, A.USDC, 'latest');
    assert.equal(rows.length, 0);
    p.close();
  });

  it('un-biases the board\'s decimals+1 convention', async () => {
    const p = await setup(c => { c.floorBids = [bidWethForUsdc()]; });
    const [r] = await p.window.floorCandidates(A.ZERO, A.USDC, 'latest');
    // 6, not 7, and not 18. Off by one here renders every amount 10x wrong.
    assert.equal(r.dA, 6);
    assert.equal(r.dB, 18);
    p.close();
  });

  it('reports unknown decimals as null rather than guessing 18', async () => {
    const p = await setup(c => {
      c.floorBids = [bidWethForUsdc({ tokenDecimals: null, quoteDecimals: null })];
    });
    const [r] = await p.window.floorCandidates(A.ZERO, A.USDC, 'latest');
    assert.equal(r.dA, null);
    assert.equal(r.dB, null);
    p.close();
  });
});

// ------------------------------------------------------------- the arithmetic

describe('quoting a partial take the way the board settles it', () => {
  it('reproduces the round-down against the ORIGINAL size', async () => {
    const p = await setup(c => { c.floorBids = [bidWethForUsdc()]; });
    const { floorGet, floorPay } = p.window;
    const [o] = await p.window.floorCandidates(A.ZERO, A.USDC, 'latest');

    // proceeds = price * give / initial, floored.
    assert.equal(floorGet(o, 1n * ETH), 4_000n * USDC);
    assert.equal(floorGet(o, 3n * ETH), 12_000n * USDC);
    // A give that does not divide evenly rounds DOWN, never up.
    assert.equal(floorGet(o, 1n), 40_000n * USDC / (10n * ETH) * 1n);
    // The inverse rounds the other way: the SMALLEST give that still clears.
    const need = 4_000n * USDC;
    const give = floorPay(o, need);
    assert.ok(floorGet(o, give) >= need, 'inverse undershot its own target');
    assert.ok(floorGet(o, give - 1n) < need, 'inverse was not the smallest give');
    p.close();
  });

  it('a partial leg is quoted below what a linear rate would claim', async () => {
    // `remaining` below `initial` is where the two disagree: the basis stays
    // the original size, so a rate derived from what is LEFT overstates.
    const p = await setup(c => {
      c.floorBids = [bidWethForUsdc({
        remaining: 3n * ETH,
        initial: 10n * ETH,
        proceeds: 12_000n * USDC,
      })];
    });
    const { floorGet } = p.window;
    const [o] = await p.window.floorCandidates(A.ZERO, A.USDC, 'latest');
    assert.equal(floorGet(o, 3n * ETH), 12_000n * USDC, 'full remainder must match the lens');
    assert.equal(floorGet(o, 1n * ETH), 4_000n * USDC);
    p.close();
  });
});

// ---------------------------------------------------------------- the routing

describe('routing a swap into a bid', () => {
  it('prefers the bid when it beats the AMM, and sends it through Swapbol', async () => {
    // AMM pays 3,000/ETH; the bid pays 4,000. The bid must win.
    const p = await setup(c => { c.floorBids = [bidWethForUsdc()]; });
    await quoteEthToUsdc(p, '1');

    const rate = p.text('rate');
    assert.match(rate, /Orderbook/, `expected a book route, got: ${rate}`);

    p.click('swap');
    await p.settle();
    const tx = p.chain.sent.at(-1);
    assert.ok(tx, 'no transaction was sent');
    assert.equal(tx.to.toLowerCase(), A.ZROUTER.toLowerCase());
    // Native input, so the whole budget rides as value.
    assert.equal(BigInt(tx.value), 1n * ETH);
    p.close();
  });

  it('names the bid board on the leg it plans', async () => {
    const p = await setup(c => { c.floorBids = [bidWethForUsdc()]; });
    await quoteEthToUsdc(p, '1');
    p.click('swap');
    await p.settle();
    const data = p.chain.sent.at(-1).data;
    // The plan carries the board address in each Fill; Floorboard has to be the
    // one named, or the executor rejects the leg as an unknown venue.
    assert.ok(
      data.toLowerCase().includes(A.FLOOR.toLowerCase().replace(/^0x/, '')),
      'the planned leg does not name Floorboard',
    );
    p.close();
  });

  it('ignores the bid board when the executor does not know it', async () => {
    // The page and the executor ship separately. An executor without the
    // binding rejects the leg AFTER the user signs, so the page must not plan
    // one at all — it should quietly fall back to the AMM.
    const p = await setup(c => {
      c.floorBids = [bidWethForUsdc()];
      c.swapbolFloorboard = A.ZERO;
    });
    await quoteEthToUsdc(p, '1');
    const rate = p.text('rate');
    assert.doesNotMatch(rate, /Orderbook/, `planned a bid leg anyway: ${rate}`);
    p.close();
  });

  it('leaves the AMM route alone when the bid is worse', async () => {
    // Bid pays 2,000/ETH against an AMM at 3,000.
    const p = await setup(c => {
      c.floorBids = [bidWethForUsdc({
        price: 20_000n * USDC, proceeds: 20_000n * USDC,
      })];
    });
    await quoteEthToUsdc(p, '1');
    const rate = p.text('rate');
    assert.doesNotMatch(rate, /Orderbook/, `took a worse bid: ${rate}`);
    p.close();
  });

  it('takes the bid for the part it covers and the AMM for the rest', async () => {
    // The bid wants 2 ETH at 4,000; the user is selling 5.
    const p = await setup(c => {
      c.floorBids = [bidWethForUsdc({
        remaining: 2n * ETH, initial: 2n * ETH,
        price: 8_000n * USDC, proceeds: 8_000n * USDC,
      })];
    });
    await quoteEthToUsdc(p, '5');
    const rate = p.text('rate');
    // 2 of the 5 ETH go to the bid, so the label must name the share, not just
    // the fact that a book was involved.
    assert.match(rate, /Orderbook 40% \+ \S/, `expected a split route, got: ${rate}`);
    p.close();
  });
});

// ----------------------------------------------------------------- placement

describe('placing a bid', () => {
  it('escrows the ceiling and routes through Orderbol', async () => {
    const p = await setup();
    p.click('tabBook');
    await p.settle();
    p.select('kind', 'floor');
    await p.settle();

    // WETH, not ETH: the board escrows and delivers tokens, so `Terms.token`
    // must be a contract. Bidding for native ETH is not a thing it can express.
    // BY SYMBOL, NOT BY INDEX - the list has reordered under this test once.
    // Receive side first: USDC starts selected there, and the picker disables
    // a token that is already chosen on the other side.
    p.pickToken('toSel', 'WETH');
    p.pickToken('fromSel', 'USDC');
    await p.settle();
    p.type('amt', '4200');    // the ceiling, and the escrow
    p.type('outAmt', '1');    // one WETH wanted
    p.type('floorAmt', '3800'); // opening bid
    await p.settle();

    assert.match(p.text('swap'), /^Bid 3,?800 → 4,?200 USDC for 1 WETH$/,
      `button read: ${p.text('swap')}`);

    p.click('swap');
    await p.settle();
    const tx = p.chain.sent.at(-1);
    assert.ok(tx, 'no placement transaction');
    assert.equal(tx.to.toLowerCase(), A.ZROUTER.toLowerCase());
    assert.ok(tx.data.includes(SEL.ORDER_FLOOR), 'not a placeFloor call');
    p.close();
  });

  it('refuses an opening bid above the ceiling', async () => {
    const p = await setup();
    p.click('tabBook');
    await p.settle();
    p.select('kind', 'floor');
    p.select('fromSel', 5);
    p.select('toSel', 1);
    await p.settle();
    p.type('amt', '3800');
    p.type('outAmt', '1');
    p.type('floorAmt', '4200');
    await p.settle();
    assert.match(p.text('swap'), /Opening exceeds maximum/);
    assert.ok(p.disabled('swap'));
    p.close();
  });

  it('needs a window, since a bid with none is dead on arrival', async () => {
    const p = await setup();
    p.click('tabBook');
    await p.settle();
    p.select('kind', 'floor');
    p.select('fromSel', 5);
    p.select('toSel', 1);
    p.select('dly', '0');
    await p.settle();
    p.type('amt', '4200');
    p.type('outAmt', '1');
    p.type('floorAmt', '3800');
    await p.settle();
    assert.match(p.text('swap'), /Choose a bid window/);
    p.close();
  });
});

// -------------------------------------------------------------- the book row

describe('listing a climbing bid in the book', () => {
  /** Open the Orders tab with the pair filter dropped. */
  const openBook = async p => {
    p.click('tabBook');
    await p.waitFor(() => p.$('book').querySelector('[data-bf="0"]'), { label: 'filter chips' });
    p.click(p.$('book').querySelector('[data-bf="0"]'));
    await p.settle();
  };

  it('states the climb against what is LEFT, not the original lot', async () => {
    // The bid opened wanting 10 ETH and has 4 left. `endPrice` is the total for
    // the FULL INITIAL lot, so printing it raw promised a seller 50,000 USDC
    // for a remainder that can only ever pay 20,000 — the same basis mistake
    // the partial-take arithmetic above exists to avoid.
    const p = await setup(c => {
      c.floorBids = [bidWethForUsdc({
        remaining: 4n * ETH,
        initial: 10n * ETH,
        price: 40_000n * USDC,
        proceeds: 16_000n * USDC,
        startPrice: 40_000n * USDC,
        endPrice: 50_000n * USDC,
        startTime: BigInt(Math.floor(Date.now() / 1000)),
        duration: 3600n,
      })];
    });
    await openBook(p);
    const row = [...p.$('book').querySelectorAll('.o')]
      .find(o => o.textContent.includes('climbs to'));
    assert.ok(row, `no climbing bid on the book: ${p.$('book').textContent}`);
    assert.match(row.textContent, /climbs to 20000 USDC/,
      `the climb must be scaled to the remaining lot: ${row.textContent}`);
    assert.doesNotMatch(row.textContent, /climbs to 50000/);
    p.close();
  });
});
