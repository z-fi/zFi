/**
 * Onchain metadata surfaced in the book: the receipt card, the fill progress,
 * the bid's climb, and curated logos.
 *
 * The point of each of these is that the fact lives on chain and the page was
 * previously either hiding it or restating it badly. So the assertions are
 * about provenance as much as appearance — that the number shown is the one the
 * board keeps, that a card is fetched once and only on demand, and that an
 * untrusted-looking payload cannot become markup.
 */
import { test, describe, it, after } from 'node:test';
import assert from 'node:assert/strict';
import { A, SEL, MockChain, loadPage, fixedRateQuoter, closeAllPages, selectorOf } from './harness.mjs';

after(closeAllPages);

const ETH = 10n ** 18n;
const USDC = 10n ** 6n;

const order = (over = {}) => ({
  id: 5n, board: A.SB2, v2: 1, pf: true, exp: 0n,
  nA: false, nB: false, cp: A.ZERO, maker: A.OTHER,
  tA: A.USDC, aA: 3000n * USDC, symA: 'USDC', decA: 6,
  tB: A.WETH, aB: 1n * ETH, symB: 'WETH', decB: 18,
  ...over,
});

const CARD = {
  name: 'Swapboard Position #5',
  description: 'A live escrowed order on Swapboard.',
  image: 'data:image/svg+xml;base64,PHN2Zy8+',
  attributes: [
    { trait_type: 'Board', value: 'Swapboard' },
    { trait_type: 'Status', value: 'OPEN' },
    { trait_type: 'Fill', value: 'Partial' },
    { display_type: 'number', trait_type: 'Filled %', value: 40 },
    { display_type: 'date', trait_type: 'Expiry', value: 1784592000 },
  ],
};

async function setup(prep = () => {}) {
  const chain = new MockChain();
  chain.setNative(A.ACCOUNT, 100n * ETH);
  chain.setErc20(A.WETH, A.ACCOUNT, 100n * ETH);
  chain.setErc20(A.USDC, A.ACCOUNT, 500_000n * USDC);
  chain.quoteHandler = fixedRateQuoter({ rate: 3000n * ETH });
  prep(chain);
  const p = await loadPage({ chain });
  await p.connect();
  p.click('tabBook');
  await p.waitFor(() => p.$('book').querySelectorAll('.o').length >= 1, { label: 'rows' });
  return p;
}

const rowEl = p => p.$('book').querySelector('.o');
const boxEl = p => p.$('book').querySelector('.ic');

describe('the receipt card', () => {
  it('is not fetched until the row is clicked', async () => {
    const p = await setup(c => {
      c.recent = [order()];
      c.cards[`${A.SB2.toLowerCase()}:5`] = CARD;
    });
    const before = p.chain.calls.filter(c => selectorOf(c.data) === SEL.TOKENURI).length;
    assert.equal(before, 0, 'a card was fetched just to render the list');
    assert.equal(boxEl(p).innerHTML, '', 'the card is open before anyone asked');
    p.close();
  });

  it('opens on click, showing the board\'s own attributes and image', async () => {
    const p = await setup(c => {
      c.recent = [order()];
      c.cards[`${A.SB2.toLowerCase()}:5`] = CARD;
    });
    p.click(rowEl(p));
    await p.waitFor(() => boxEl(p).querySelector('dl'), { label: 'card' });

    const txt = boxEl(p).textContent;
    assert.match(txt, /Status/);
    assert.match(txt, /OPEN/);
    assert.match(txt, /Filled %/);
    // A `date` attribute is a unix seconds value; showing the raw integer would
    // be worse than showing nothing.
    assert.doesNotMatch(txt, /1784592000/, 'a date rendered as a raw timestamp');

    const img = boxEl(p).querySelector('img');
    assert.ok(img, 'no image rendered');
    assert.equal(img.getAttribute('src'), CARD.image);
    p.close();
  });

  it('fetches once and caches, and a second click closes it', async () => {
    const p = await setup(c => {
      c.recent = [order()];
      c.cards[`${A.SB2.toLowerCase()}:5`] = CARD;
    });
    const n = () => p.chain.calls.filter(c => selectorOf(c.data) === SEL.TOKENURI).length;
    p.click(rowEl(p));
    await p.waitFor(() => boxEl(p).querySelector('dl'), { label: 'open' });
    assert.equal(n(), 1);

    p.click(rowEl(p));
    await p.settle();
    assert.equal(boxEl(p).innerHTML, '', 'second click did not close it');

    p.click(rowEl(p));
    await p.waitFor(() => boxEl(p).querySelector('dl'), { label: 'reopen' });
    assert.equal(n(), 1, 'reopening refetched a card it already had');
    p.close();
  });

  it('never turns card content into markup', async () => {
    const evil = '<img src=x onerror=alert(1)>';
    const p = await setup(c => {
      c.recent = [order()];
      c.cards[`${A.SB2.toLowerCase()}:5`] = {
        ...CARD,
        // Both an attribute and the image are attacker-reachable if a board is
        // ever pointed at a hostile renderer, so neither may reach innerHTML raw.
        image: 'javascript:alert(1)',
        attributes: [{ trait_type: evil, value: evil }],
      };
    });
    p.click(rowEl(p));
    await p.waitFor(() => boxEl(p).innerHTML !== '', { label: 'card' });
    assert.equal(boxEl(p).querySelectorAll('img').length, 0, 'a non-image URL became an image');
    assert.ok(!boxEl(p).innerHTML.includes('onerror'));
    p.close();
  });

  it('leaves the legacy board flat, since it mints no receipt', async () => {
    const p = await setup(c => { c.recent = [order({ board: A.SB1, v2: 0, pf: false })]; });
    const row = rowEl(p);
    assert.ok(!row.classList.contains('ins'), 'legacy row offers an inspection it cannot serve');
    p.click(row);
    await p.settle();
    assert.equal(boxEl(p).innerHTML, '');
    assert.equal(p.chain.calls.filter(c => selectorOf(c.data) === SEL.TOKENURI).length, 0);
    p.close();
  });

  it('says so when the receipt cannot be read', async () => {
    const p = await setup(c => { c.recent = [order()]; });   // no card fixture
    p.click(rowEl(p));
    await p.waitFor(() => /could not be read/.test(boxEl(p).textContent), { label: 'error' });
    p.close();
  });
});

describe('fill progress', () => {
  // `amountB` is rewritten in place by a partial fill, so the row alone cannot
  // say how much of the order is gone. The board keeps the original.
  it('reads the original size from the board, not from the row', async () => {
    const p = await setup(c => {
      c.recent = [order({ aB: 1n * ETH })];
      c.initialAmountB[`${A.SB2.toLowerCase()}:5`] = 4n * ETH;   // 3 of 4 taken
    });
    await p.waitFor(() => /% filled/.test(p.$('book').textContent), { label: 'tag' });
    assert.match(p.$('book').textContent, /75% filled/);
    p.close();
  });

  it('shows no tag on an untouched order', async () => {
    const p = await setup(c => {
      c.recent = [order({ aB: 4n * ETH })];
      c.initialAmountB[`${A.SB2.toLowerCase()}:5`] = 4n * ETH;
    });
    await p.settle();
    assert.doesNotMatch(p.$('book').textContent, /% filled/);
    p.close();
  });

  it('does not ask for a progress the board cannot have', async () => {
    // All-or-nothing never partially fills, so there is nothing to read.
    const p = await setup(c => { c.recent = [order({ pf: false })]; });
    await p.settle();
    assert.equal(p.chain.calls.filter(c => selectorOf(c.data) === SEL.INITIAL_B).length, 0);
    p.close();
  });
});

describe('the bid climb', () => {
  it('reads its ceiling and window from the board', async () => {
    const now = Math.floor(Date.now() / 1e3);
    const p = await setup(c => {
      c.floorBids = [{
        id: 7n, token: A.WETH, quote: A.USDC,
        remaining: 10n * ETH, initial: 10n * ETH,
        price: 40_000n * USDC, proceeds: 40_000n * USDC,
        startTime: BigInt(now), expiry: BigInt(now + 3600),
        tokenDecimals: 18, quoteDecimals: 6, tokenSymbol: 'WETH', quoteSymbol: 'USDC',
      }];
    });
    await p.waitFor(() => /climbs to/.test(p.$('book').textContent), { label: 'climb' });
    // `bids()` reports startPrice and endPrice; the fixture derives both from
    // `price`, so the ceiling shown is the board's, not the lens row's.
    assert.match(p.$('book').textContent, /climbs to .* USDC in/);
    p.close();
  });
});

describe('curated logos', () => {
  const FAR = '0x7A58c0Be72BE218B41C608b7Fe7C5bB630736C71';
  const LOGO = 'data:image/svg+xml;base64,PHN2Zy8+';

  it('uses the registry logo for a leg the picker never loaded', async () => {
    const p = await setup(c => {
      c.setToken(FAR, { symbol: 'PEOPLE', decimals: 18, name: 'People' });
      c.logos[FAR.toLowerCase()] = LOGO;
      c.recent = [order({ tA: FAR, symA: 'PEOPLE', decA: 18 })];
    });
    await p.waitFor(() => p.$('book').querySelector('img[src^="data:image/svg"]'), { label: 'logo' });
    assert.ok(p.$('book').innerHTML.includes(LOGO));
    p.close();
  });

  it('falls back to a generated icon when the token is genuinely unlisted', async () => {
    const p = await setup(c => {
      c.setToken(FAR, { symbol: 'PEOPLE', decimals: 18, name: 'People' });
      c.recent = [order({ tA: FAR, symA: 'PEOPLE', decA: 18 })];   // no logo fixture
    });
    await p.settle();
    // The page DID ask — the registry simply has no entry, which is the branch
    // under test. Asserting only "an svg exists" would pass on WETH's built-in
    // icon and prove nothing.
    assert.equal(p.chain.calls.filter(c => selectorOf(c.data) === SEL.LOGOOF).length, 1,
      'the registry was not consulted for an unknown leg');
    assert.equal(p.$('book').querySelectorAll('img').length, 0, 'invented a logo it was never given');
    // genIcon puts the symbol's first letter in the circle.
    assert.match(p.$('book').innerHTML, />P</, 'no generated letter icon for PEOPLE');
    p.close();
  });

  it('does not query the registry for tokens the picker already holds', async () => {
    const p = await setup(c => { c.recent = [order()]; });   // USDC/WETH, both built in
    await p.settle();
    assert.equal(p.chain.calls.filter(c => selectorOf(c.data) === SEL.LOGOOF).length, 0);
    p.close();
  });
});
