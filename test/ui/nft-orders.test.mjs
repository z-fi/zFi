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

  test('offers to bid once a price and a token id are named', async () => {
    const p = await buying();
    assert.match(p.text('swap'), /Name the token id to buy/i,
      'an order names one token: there is no "any of them" here');
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

  test('points a collection-wide want at the board that can express it', async () => {
    const p = await buying();
    await bid(p);
    p.select('kind', 'floor');
    await p.settle();
    assert.match(p.text('swap'), /Collection bids are not enabled yet/i,
      'a different board with a different shape, not a silent failure');
    p.close();
  });
});
