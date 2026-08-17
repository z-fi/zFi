/**
 * Listing an NFT for sale.
 *
 * Every fungible order on this tab routes through zRouter and the Orderbol
 * adapter, which pulls the escrow. That adapter refuses any order carrying an
 * NFT leg - `o.nftA || o.nftB` in _checkSwapboardOrder - so the routed path is
 * not merely unbuilt for collections, it is closed.
 *
 * Swapboard takes the other route: `safeTransferFrom` with the terms in
 * `data`. The collection is the CALLER, so a seller cannot name a collection
 * they do not control, and the token is already escrowed by the time the board
 * reads the terms. One transaction and no approval - strictly less than the
 * fungible path beside it needs.
 *
 * The transaction is decoded here rather than merely observed, because it
 * MOVES AN NFT. A wrong word in the terms is not a failed quote, it is a token
 * escrowed against an ask nobody meant to make.
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
const PUNKS = '0xfeed567890abcdef1234567890abcdef12345678';
// keccak256("Swapboard.PushOrder.v1"), the same constant the board checks.
const MAGIC = '0x381bcb9ccaaab09ca206deb73834ed7b483c58bb3face9b43e8c7b50193253e2';

async function setup({ id = 7, owner = A.ACCOUNT } = {}) {
  const chain = new MockChain();
  chain.setNative(A.ACCOUNT, 10n * ETH);
  chain.setToken(PUNKS, { symbol: 'PUNK', name: 'CryptoPunks', erc721: true });
  chain.setNftOwner(PUNKS, id, owner);
  chain.quoteHandler = fixedRateQuoter({ rate: 3000n * ETH });
  const p = await loadPage({ chain });
  await p.connect();
  p.click('tabBook');
  await p.settle();

  p.queuePrompt(PUNKS);
  p.select('fromSel', '__custom');
  await p.waitFor(() => p.$('fromSel').selectedOptions[0]?.textContent === 'PUNK',
    { label: 'collection imported' });
  // Quote in ETH, which is the interesting case: the board calls the quote
  // token, so native ETH cannot be it and the page has to substitute.
  p.pickToken('toSel', 'ETH');
  await p.settle();
  return p;
}

/** Fill in an ask and a token id, the way the form is used. */
async function ask(p, { price = '10', id = '7' } = {}) {
  p.type('outAmt', price);
  p.type('nftId', id);
  await p.settle();
}

/** Decode safeTransferFrom(address,address,uint256,bytes) and its PushOrder. */
function decodeListing(tx) {
  assert.equal(selectorOf(tx.data), 'b88d4fde', 'expected safeTransferFrom with data');
  const body = '0x' + tx.data.replace(/^0x/, '').slice(8);
  const dataOff = Number(word(body, 3)) / 32;
  const len = Number(word(body, dataOff));
  const terms = '0x' + body.replace(/^0x/, '').slice((dataOff + 1) * 64);
  return {
    from: wordAddr(body, 0),
    to: wordAddr(body, 1),
    tokenId: word(body, 2),
    termsLength: len,
    magic: '0x' + terms.replace(/^0x/, '').slice(0, 64),
    tokenB: wordAddr(terms, 1),
    amountB: word(terms, 2),
    expiry: word(terms, 3),
    nftB: word(terms, 4),
    counterparty: wordAddr(terms, 5),
  };
}

describe('listing an NFT', () => {
  test('offers to list once a price and a token id are named', async () => {
    const p = await setup();
    assert.match(p.text('swap'), /Name the token id/i, 'a seller holds particular tokens');
    await ask(p, { price: '10', id: '7' });
    assert.match(p.text('swap'), /List PUNK #7/);
    assert.equal(p.$('swap').disabled, false);
    p.close();
  });

  test('pushes the token to the board with its terms attached', async () => {
    const p = await setup();
    await ask(p, { price: '10', id: '7' });
    p.click('swap');
    await p.waitFor(() => p.chain.sent.length > 0, { label: 'listing' });
    await p.settle();

    const tx = p.chain.lastSent;
    // Sent to the COLLECTION, not to zRouter: the adapter refuses NFT legs, and
    // the board's own route needs no approval and no escrow step.
    assert.equal(tx.to.toLowerCase(), PUNKS.toLowerCase());
    assert.equal(BigInt(tx.value || 0), 0n, 'listing costs nothing but gas');

    const d = decodeListing(tx);
    assert.equal(d.from.toLowerCase(), A.ACCOUNT.toLowerCase());
    assert.equal(d.to.toLowerCase(), A.SB2.toLowerCase(), 'escrowed at the fixed board');
    assert.equal(d.tokenId, 7n);
    assert.equal(d.termsLength, 192, 'the board length-checks this exactly');
    assert.equal(d.magic, MAGIC, 'without the magic the board treats it as a stray transfer');
    assert.equal(d.amountB, 10n * ETH, 'the ask, in the quote token\'s units');
    assert.equal(d.nftB, 0n, 'the payment side is fungible');
    assert.equal(d.counterparty.toLowerCase(), A.ZERO.toLowerCase(), 'public by default');
    p.close();
  });

  test('asks in WETH when the price is quoted in ETH', async () => {
    // The board CALLS the quote token, so native ETH cannot be the ask - it has
    // no code to call. Everywhere else on the page substitutes WETH; so here.
    const p = await setup();
    await ask(p);
    p.click('swap');
    await p.waitFor(() => p.chain.sent.length > 0, { label: 'listing' });
    await p.settle();

    assert.equal(decodeListing(p.chain.lastSent).tokenB.toLowerCase(), A.WETH.toLowerCase());
    p.close();
  });

  test('refuses a token the seller does not hold, before the wallet is asked', async () => {
    // The board reverts on this, and "execution reverted" would not say which
    // of the id and the collection was wrong.
    const p = await setup({ id: 7, owner: A.OTHER });
    await ask(p, { id: '7' });
    p.click('swap');
    await p.waitFor(() => /do not own/i.test(p.text('stat')), { label: 'the refusal' });
    assert.equal(p.chain.sent.length, 0, 'nothing was sent');
    p.close();
  });

  test('refuses an id that does not exist at all', async () => {
    const p = await setup({ id: 7 });
    await ask(p, { id: '99' });
    p.click('swap');
    await p.waitFor(() => /does not exist/i.test(p.text('stat')), { label: 'the refusal' });
    assert.equal(p.chain.sent.length, 0);
    p.close();
  });

  test('will not decay the price of something indivisible', async () => {
    const p = await setup();
    await ask(p);
    p.select('kind', 'dutch');
    await p.settle();
    assert.match(p.text('swap'), /fixed price/i, 'an ERC-721 settles only at its full ask');
    assert.equal(p.$('swap').disabled, true);
    p.close();
  });

  test('carries a private counterparty when one is named', async () => {
    const p = await setup();
    await ask(p);
    p.type('rc', A.OTHER);
    await p.settle();
    p.click('swap');
    await p.waitFor(() => p.chain.sent.length > 0, { label: 'listing' });
    await p.settle();

    assert.equal(decodeListing(p.chain.lastSent).counterparty.toLowerCase(), A.OTHER.toLowerCase());
    p.close();
  });

  test('asks for the price too, once the id is there', async () => {
    const p = await setup();
    p.type('nftId', '7');
    await p.settle();
    assert.match(p.text('swap'), /Set a price/i, 'an id alone is not an offer');
    p.close();
  });
});

/**
 * Bidding for one specific NFT.
 *
 * The mirror of listing, and it cannot use the routed path either - Orderbol
 * refuses an order with an NFT leg - so the escrow is placed at Swapboard
 * directly. Paying in ETH is one transaction and no approval, because
 * `createOrderWithEth` wraps the value itself.
 *
 * `amountB` is a TOKEN ID, not an amount. That is exactly why a
 * collection-wide want cannot be expressed here: an order names one token.
 */
describe('bidding for an NFT', () => {
  /** Collection on the RECEIVE side, paying from the pay side. */
  async function buying({ pay = 'ETH' } = {}) {
    const p = await setup();
    // PUNK is on the pay side from setup; step through a third token so the
    // equal-pair guard has somewhere to put each side.
    p.pickToken('fromSel', 'USDC');
    p.pickToken('toSel', 'PUNK');
    p.pickToken('fromSel', pay);
    await p.settle();
    return p;
  }

  const bid = async (p, { price = '2', id = '7' } = {}) => {
    p.type('amt', price);
    p.type('nftId', id);
    await p.settle();
  };

  test('hides the controls a collection order cannot carry', async () => {
    // A form showing a control the order cannot express asks a question with no
    // answer, and the user cannot tell that from one that matters.
    //
    // Fill is the clearest case: `placeFloor` has no partial-fill parameter and
    // neither does an NFT listing - a token transfers or it does not, there is
    // no 60% of one - so `fill.value` never reached either call. It was already
    // hidden for Dutch and climbing bids; a collection was not part of that test.
    const p = await buying();
    assert.equal(p.visible('fillL'), false,
      'an NFT order cannot be partially filled, so Fill must not be offered');

    // And Floorboard has no "never expires" - the window IS the bid - so
    // offering "Never" offers something the button then refuses, one step late.
    await bid(p, { price: '2', id: '' });
    assert.match(p.$('dlyL').textContent, /Bid window/,
      'a collection bid is a window, not an expiry');
    assert.notEqual(p.$('dly').options[0].textContent, 'Never',
      '"Never" is not on offer for a board that cannot express it');
    p.close();
  });

  test('typing an id moves it back to a Swapboard order, and the controls follow', async () => {
    // A collection bid and a bid for one token are different orders on
    // different boards. The controls have to move with the keystroke rather
    // than wait for the order type to be touched.
    const p = await buying();
    await bid(p, { price: '2', id: '' });
    assert.match(p.$('dlyL').textContent, /Bid window/);

    await bid(p, { price: '2', id: '7' });
    assert.match(p.$('dlyL').textContent, /Expires/,
      'a bid for one token is a Swapboard order, which really does expire');
    assert.equal(p.$('dly').options[0].textContent, 'Never');
    p.close();
  });

  test('offers to bid once a price and a token id are named', async () => {
    const p = await buying();
    // A blank id is not a missing answer now - it is the collection bid.
    await bid(p, { price: '2', id: '' });
    assert.match(p.text('swap'), /Bid for any PUNK/i);
    await bid(p, { price: '2', id: '7' });
    assert.match(p.text('swap'), /Bid for PUNK #7/);
    assert.equal(p.$('swap').disabled, false);
    p.close();
  });

  test('escrows ETH at the board in one transaction, with no approval', async () => {
    const p = await buying();
    await bid(p, { price: '2', id: '7' });
    p.click('swap');
    await p.waitFor(() => p.chain.sent.length > 0, { label: 'bid' });
    await p.settle();

    assert.equal(p.chain.sent.length, 1, 'no approval step for native ether');
    const tx = p.chain.lastSent;
    assert.equal(tx.to.toLowerCase(), A.SB2.toLowerCase(), 'placed at the board, not the router');
    assert.equal(BigInt(tx.value), 2n * ETH, 'the bid rides as value and the board wraps it');
    assert.equal(selectorOf(tx.data), '0e8e31d3', 'createOrderWithEth');

    const b = '0x' + tx.data.replace(/^0x/, '').slice(8);
    assert.equal(wordAddr(b, 0).toLowerCase(), PUNKS.toLowerCase(), 'the collection is tokenB');
    assert.equal(word(b, 1), 7n, 'amountB is the TOKEN ID, not a quantity');
    assert.equal(word(b, 2), 0n, 'partial fills refused: NFTNotDivisible');
    assert.equal(word(b, 4), 1n, 'nftB');
    assert.equal(wordAddr(b, 5).toLowerCase(), A.ZERO.toLowerCase(), 'public by default');
    p.close();
  });

  test('approves and creates when paying in an ERC-20', async () => {
    const p = await buying({ pay: 'USDC' });
    await bid(p, { price: '5000', id: '7' });
    p.click('swap');
    await p.waitFor(() => p.chain.sent.length > 1, { label: 'approve then create' });
    await p.settle();

    const [approve] = p.chain.sent;
    assert.equal(approve.to.toLowerCase(), A.USDC.toLowerCase());
    assert.equal(selectorOf(approve.data), SEL.APPROVE);
    assert.equal(wordAddr('0x' + approve.data.slice(10), 0).toLowerCase(), A.SB2.toLowerCase(),
      'the board pulls the escrow, so the board is what gets approved');

    const tx = p.chain.lastSent;
    assert.equal(selectorOf(tx.data), '8e14f9f8', 'createOrder');
    assert.equal(BigInt(tx.value || 0), 0n);
    const b = '0x' + tx.data.replace(/^0x/, '').slice(8);
    assert.equal(wordAddr(b, 0).toLowerCase(), A.USDC.toLowerCase(), 'paying in USDC');
    assert.equal(word(b, 1), 5000n * 10n ** 6n, 'in the pay token\'s units');
    assert.equal(wordAddr(b, 2).toLowerCase(), PUNKS.toLowerCase());
    assert.equal(word(b, 3), 7n, 'the token id');
    assert.equal(word(b, 6), 0n, 'nftA false');
    assert.equal(word(b, 7), 1n, 'nftB true');
    p.close();
  });

  test('refuses an id that does not exist, before escrowing anything', async () => {
    // The board escrows the payment but cannot check the token: an id nobody
    // owns would lock funds against an order that can never be filled.
    const p = await buying();
    await bid(p, { id: '99' });
    p.click('swap');
    await p.waitFor(() => /does not exist/i.test(p.text('stat')), { label: 'the refusal' });
    assert.equal(p.chain.sent.length, 0, 'nothing escrowed');
    p.close();
  });

  test('bids for any id from the collection at a fixed price', async () => {
    // Floorboard interpolates between startPrice and endPrice over the window,
    // so EQUAL ENDPOINTS are a fixed offer. The board can do both shapes; the
    // page used to treat climbing as the only one it could do.
    const p = await buying();
    await bid(p, { price: '2', id: '' });
    p.click('swap');
    await p.waitFor(() => p.chain.sent.length > 0, { label: 'bid' });
    await p.settle();

    const tx = p.chain.lastSent;
    assert.equal(tx.to.toLowerCase(), A.FLOOR.toLowerCase(),
      'the routed adapter hardcodes isNFT false, so this goes to the board itself');
    assert.equal(selectorOf(tx.data), '3d8d260b', 'bid(Terms)');
    assert.equal(BigInt(tx.value), 2n * ETH, 'the board takes the ceiling exactly, as value');

    // Terms rides behind an offset; ids behind another, relative to the struct.
    const b = '0x' + tx.data.replace(/^0x/, '').slice(8);
    assert.equal(word(b, 0), 32n, 'offset to Terms');
    assert.equal(wordAddr(b, 1).toLowerCase(), PUNKS.toLowerCase(), 'token');
    assert.equal(wordAddr(b, 2).toLowerCase(), A.ZERO.toLowerCase(), 'quote 0 = ETH, escrowed as WETH');
    assert.equal(word(b, 3), 1n, 'want: a count, not an amount');
    assert.equal(word(b, 4), 2n * ETH, 'startPrice');
    assert.equal(word(b, 5), 2n * ETH, 'endPrice EQUAL to it: a fixed offer');
    assert.equal(word(b, 8), 1n, 'isNFT');
    assert.equal(word(b, 9), 288n, 'offset to ids, relative to the struct');
    assert.equal(word(b, 10), 0n, 'no ids: ANY token from the collection');
    p.close();
  });

  test('climbs from an opening bid when asked to', async () => {
    const p = await buying();
    await bid(p, { price: '2', id: '' });
    p.select('kind', 'floor');
    p.type('floorAmt', '1');
    await p.settle();
    assert.match(p.text('swap'), /Climbing bid for any PUNK/i);

    p.click('swap');
    await p.waitFor(() => p.chain.sent.length > 0, { label: 'bid' });
    await p.settle();

    const b = '0x' + p.chain.lastSent.data.replace(/^0x/, '').slice(8);
    assert.equal(word(b, 4), ETH, 'starts at the opening bid');
    assert.equal(word(b, 5), 2n * ETH, 'and climbs toward the ceiling');
    assert.equal(BigInt(p.chain.lastSent.value), 2n * ETH,
      'escrow is the ceiling: the most it can ever owe');
    p.close();
  });

  test('bids for several from one collection', async () => {
    const p = await buying();
    p.type('amt', '5');
    p.type('outAmt', '3');
    await p.settle();
    p.click('swap');
    await p.waitFor(() => p.chain.sent.length > 0, { label: 'bid' });
    await p.settle();

    const b = '0x' + p.chain.lastSent.data.replace(/^0x/, '').slice(8);
    assert.equal(word(b, 3), 3n, 'want three of them');
    assert.equal(word(b, 5), 5n * ETH,
      'the ceiling is a TOTAL, not a price each - the board escrows exactly it');
    p.close();
  });

  test('refuses a fraction of a token at the gate, not after the click', async () => {
    // `want` is a COUNT and bidCollection has always refused anything else -
    // but only once the button had been pressed. Until then the form read
    // "Bid for any PUNK" and was enabled, so the first news of the mistake
    // arrived as an error where a wallet prompt was expected.
    const p = await buying();
    p.type('amt', '5');
    p.type('outAmt', '1.5');
    await p.settle();
    assert.match(p.text('swap'), /whole number/i);
    assert.equal(p.$('swap').disabled, true);

    p.type('outAmt', '0');
    await p.settle();
    assert.match(p.text('swap'), /at least one/i, 'a bid for none is not a bid');
    assert.equal(p.$('swap').disabled, true);

    p.type('outAmt', '3');
    await p.settle();
    assert.match(p.text('swap'), /Bid for any PUNK/i, 'and a count is fine');
    assert.equal(p.$('swap').disabled, false);
    p.close();
  });

  test('clears the opening bid once one is placed', async () => {
    // The fungible path resets floorAmt and floorTouched; this one did not, so
    // a placed climb left its opening bid sitting in the form to be carried,
    // unnoticed, into whatever order was typed next.
    const p = await buying();
    await bid(p, { price: '2', id: '' });
    p.select('kind', 'floor');
    p.type('floorAmt', '1');
    await p.settle();
    p.click('swap');
    await p.waitFor(() => p.chain.sent.length > 0, { label: 'bid' });
    await p.settle();

    assert.equal(p.$('floorAmt').value, '', 'the opening bid does not outlive its bid');
    assert.equal(p.$('amt').value, '');
    assert.equal(p.$('outAmt').value, '');
    p.close();
  });

  test('needs a window, because a bid IS its window', async () => {
    const p = await buying();
    await bid(p, { price: '2', id: '' });
    p.select('dly', '0');       // "Never"
    await p.settle();
    assert.match(p.text('swap'), /needs a window/i,
      'Floorboard refuses duration 0, so the page must not offer it');
    assert.equal(p.$('swap').disabled, true);
    p.close();
  });
});

/**
 * The pair itself, before any amount is typed.
 *
 * Every branch below the pair reads ONE leg as the collection and the other as
 * the money for it, and the two readers disagree about which is which: render
 * checks `t.std === "nft"` first and calls the pair a bid, in the seller's
 * decimals; placeOrder checks `f.std === "nft"` first and calls it a listing.
 * With a collection on both sides they answer differently about the same form,
 * and the one that wins is the one that spends - safeTransferFrom pushing a
 * token into escrow against an ERC-721 named as the quote, which Swapboard's
 * fungibility check must then reject with the token already gone from the
 * wallet's point of view until the revert lands.
 *
 * The swap tab never allowed a collection at all, so this pair was only ever
 * reachable here, and nothing on the tab said no to it.
 */
describe('two collections', () => {
  const APES = '0xbeef567890abcdef1234567890abcdef12345678';

  /** Import a collection into `sel` the way the custom-token path does. */
  async function importInto(p, sel, addr, sym) {
    p.queuePrompt(addr);
    p.select(sel, '__custom');
    await p.waitFor(() => p.$(sel).selectedOptions[0]?.textContent === sym,
      { label: `${sym} imported` });
    await p.settle();
  }

  async function twoCollections() {
    const chain = new MockChain();
    chain.setNative(A.ACCOUNT, 10n * ETH);
    chain.setToken(PUNKS, { symbol: 'PUNK', name: 'CryptoPunks', erc721: true });
    chain.setToken(APES, { symbol: 'APE', name: 'Apes', erc721: true });
    chain.setNftOwner(PUNKS, 7, A.ACCOUNT);
    chain.quoteHandler = fixedRateQuoter({ rate: 3000n * ETH });
    const p = await loadPage({ chain });
    await p.connect();
    p.click('tabBook');
    await p.settle();
    return p;
  }

  test('the side the user did not touch gives way to a token', async () => {
    const p = await twoCollections();
    await importInto(p, 'fromSel', PUNKS, 'PUNK');
    assert.equal(p.$('fromSel').selectedOptions[0].textContent, 'PUNK');

    // Naming a collection to BUY is the newer intent, so the sell side yields
    // rather than the keystroke being undone.
    await importInto(p, 'toSel', APES, 'APE');
    assert.equal(p.$('toSel').selectedOptions[0].textContent, 'APE',
      'the side just touched keeps what was typed into it');
    assert.notEqual(p.$('fromSel').selectedOptions[0].textContent, 'PUNK',
      'the other side must become the money');
    p.close();
  });

  test('and the button refuses the pair even if one forms anyway', async () => {
    // The gate is what placeOrder trusts, so it says no on its own rather than
    // relying on the pair repair having run.
    const p = await twoCollections();
    await importInto(p, 'fromSel', PUNKS, 'PUNK');
    await importInto(p, 'toSel', APES, 'APE');
    const punk = [...p.$('fromSel').options].find(o => o.textContent === 'PUNK');
    p.$('fromSel').value = punk.value;   // straight past the repair
    p.type('amt', '1');
    p.type('nftId', '7');
    await p.settle();

    assert.match(p.text('swap'), /One side must be a token/i);
    assert.equal(p.$('swap').disabled, true);
    p.click('swap');
    await p.settle();
    assert.equal(p.chain.sent.length, 0, 'and nothing is pushed to any board');
    p.close();
  });
});

/**
 * Getting the escrow back.
 *
 * All three new paths lock real value at three different boards - a listing
 * holds the NFT at Swapboard, a per-token bid holds ether there, a collection
 * bid holds it at Floorboard - and none of them had been proven to unwind.
 * Placing is the half that is easy to test and the half that costs nothing to
 * get wrong; cancelling is where a wrong selector or a wrong board strands
 * somebody's money.
 *
 * The refund SHAPE differs per path and the page has to pick it:
 *   an NFT escrow returns the token, and unwrapping it is nonsense
 *   a WETH escrow can return as ETH or as WETH, which is the one real choice
 *   Floorboard's cancel pair is Dutchboard's, not Swapboard's
 */
describe('cancelling', () => {
  const ETH_ = 10n ** 18n;

  async function book(prep) {
    const chain = new MockChain();
    chain.setNative(A.ACCOUNT, 10n * ETH_);
    chain.setToken(PUNKS, { symbol: 'PUNK', name: 'CryptoPunks', erc721: true });
    chain.quoteHandler = fixedRateQuoter({ rate: 3000n * ETH_ });
    prep(chain);
    const p = await loadPage({ chain });
    await p.connect();
    p.click('tabBook');
    await p.waitFor(() => /Cancel/.test(p.$('book').textContent), { label: 'own row' });
    await p.settle();
    return p;
  }

  const cancel = async p => {
    const btn = [...p.$('book').querySelectorAll('.o button')].find(b => b.textContent === 'Cancel');
    assert.ok(btn, 'the row should offer a cancel');
    p.click(btn);
    await p.waitFor(() => p.chain.sent.length > 0, { label: 'cancel sent' });
    await p.settle();
    return p.chain.lastSent;
  };

  test('a listing returns the token, and does not try to unwrap it', async () => {
    // nftA: the escrow IS the NFT. cancelOrderUnwrap would revert NotWETH.
    const tx = await cancel(await book(c => {
      c.recent = [{
        id: 11, board: A.SB2, maker: A.ACCOUNT, pf: false, exp: 0,
        tA: PUNKS, aA: 7n, symA: 'PUNK', decA: 0, nA: true,
        tB: A.WETH, aB: ETH_, symB: 'WETH', decB: 18,
      }];
    }));
    assert.equal(tx.to.toLowerCase(), A.SB2.toLowerCase());
    assert.equal(selectorOf(tx.data), '514fcac7', 'cancelOrder, not the unwrapping variant');
    assert.equal(word('0x' + tx.data.slice(10), 0), 11n, 'the order id');
  });

  test('a per-token bid returns the escrow as ETH by default', async () => {
    // The escrow is WETH - createOrderWithEth wrapped it - and Receive is ETH.
    const tx = await cancel(await book(c => {
      c.recent = [{
        id: 12, board: A.SB2, maker: A.ACCOUNT, pf: false, exp: 0,
        tA: A.WETH, aA: 2n * ETH_, symA: 'WETH', decA: 18,
        tB: PUNKS, aB: 7n, symB: 'PUNK', decB: 0, nB: true,
      }];
    }));
    assert.equal(tx.to.toLowerCase(), A.SB2.toLowerCase());
    assert.equal(selectorOf(tx.data), '21dd76f9', 'cancelOrderUnwrap: back as ether');
  });

  test('and as WETH when that is what was asked for', async () => {
    const p = await book(c => {
      c.recent = [{
        id: 12, board: A.SB2, maker: A.ACCOUNT, pf: false, exp: 0,
        tA: A.WETH, aA: 2n * ETH_, symA: 'WETH', decA: 18,
        tB: PUNKS, aB: 7n, symB: 'PUNK', decB: 0, nB: true,
      }];
    });
    p.select('ethMode', 'weth');
    await p.settle();
    const tx = await cancel(p);
    assert.equal(selectorOf(tx.data), '514fcac7', 'plain cancelOrder keeps it wrapped');
    p.close();
  });

  test('a collection bid unwinds at Floorboard, whose cancel is not Swapboard\'s', async () => {
    const tx = await cancel(await book(c => {
      c.floorBids = [{
        id: 5n, bidder: A.ACCOUNT, token: PUNKS, quote: A.WETH,
        isNFT: true, anyId: true, remaining: 1n, initial: 1n,
        price: 2n * ETH_, proceeds: 2n * ETH_, expiry: 0n,
        tokenDecimals: 0, quoteDecimals: 18, tokenSymbol: 'PUNK', quoteSymbol: 'WETH',
      }];
    }));
    assert.equal(tx.to.toLowerCase(), A.FLOOR.toLowerCase(), 'the board that holds it');
    assert.equal(selectorOf(tx.data), '8382de65',
      'cancelUnwrap — Floorboard shares Dutchboard\'s pair, not Swapboard\'s');
    assert.equal(word('0x' + tx.data.slice(10), 0), 5n, 'the bid id');
  });
});
