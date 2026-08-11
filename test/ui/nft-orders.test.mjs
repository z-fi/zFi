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

  test('says plainly that BUYING one is not supported', async () => {
    // Not the same gap: selling needs no adapter, buying would have to escrow
    // the payment directly because Orderbol refuses an order with an NFT leg.
    const p = await setup();
    // PUNK is on the pay side and ETH on the receive side, so neither can move
    // straight past the other - which is the equal-pair guard doing its job.
    // Step through a third token.
    p.pickToken('fromSel', 'USDC');
    p.pickToken('toSel', 'PUNK');
    await p.settle();
    assert.match(p.text('swap'), /Buying an NFT is not supported/i);
    assert.equal(p.$('swap').disabled, true);
    p.close();
  });
});
