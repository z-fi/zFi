/**
 * Orders tab: placing fixed and Dutch orders, and the live orderbook list
 * (fill, cancel, and the tags that tell a user what they are looking at).
 */
import { test, describe, after } from 'node:test';
import assert from 'node:assert/strict';
import {
  A, SEL, MockChain, loadPage, fixedRateQuoter, word, wordAddr, selectorOf, closeAllPages,
} from './harness.mjs';

after(closeAllPages);

const ETH = 10n ** 18n;
const USDC = 10n ** 6n;

async function setup(prep = () => {}) {
  const chain = new MockChain();
  chain.setNative(A.ACCOUNT, 100n * ETH);
  chain.setErc20(A.USDC, A.ACCOUNT, 500_000n * USDC);
  chain.setErc20(A.WETH, A.ACCOUNT, 100n * ETH);
  chain.quoteHandler = fixedRateQuoter({ rate: 3000n * ETH });
  prep(chain);
  const p = await loadPage({ chain });
  await p.connect();
  p.click('tabBook');
  await p.settle();
  return p;
}

/** Pull the inner calls out of a multicall(bytes[]) payload. */
function innerCalls(data) {
  assert.equal(selectorOf(data), SEL.MULTICALL);
  const body = data.replace(/^0x/, '').slice(8);
  const n = Number(word('0x' + body, 1));
  const out = [];
  for (let i = 0; i < n; i++) {
    const off = Number(word('0x' + body, 2 + i)) / 32;
    const len = Number(word('0x' + body, 2 + off));
    const start = (2 + off + 1) * 64;
    out.push('0x' + body.slice(start, start + len * 2));
  }
  return out;
}

/** The executor payload carried by an snwap(...) call. */
function snwapPayload(data) {
  assert.equal(selectorOf(data), SEL.SNWAP);
  const body = data.replace(/^0x/, '').slice(8);
  const off = Number(word('0x' + body, 6)) * 2;
  const len = Number(word('0x' + body, off / 64)) * 2;
  return '0x' + body.slice(off + 64, off + 64 + len);
}

/** Find the order-placement payload inside whatever wrapper the page used. */
function placementPayload(tx) {
  const calls = selectorOf(tx.data) === SEL.MULTICALL ? innerCalls(tx.data) : [tx.data];
  for (const c of calls) {
    if (selectorOf(c) !== SEL.SNWAP) continue;
    const inner = snwapPayload(c);
    if (selectorOf(inner) === SEL.ORDER_FIXED || selectorOf(inner) === SEL.ORDER_DUTCH) return inner;
  }
  throw Error('no order placement found in the transaction');
}

describe('orders tab layout', () => {
  test('reuses the pay/receive panels as sell/want', async () => {
    const p = await setup();
    assert.equal(p.text('payL'), 'You sell');
    assert.equal(p.text('rcvHdr'), 'You want');
    assert.equal(p.visible('kindL'), true, 'order type must be choosable');
    assert.equal(p.visible('fillL'), true, 'fixed orders choose partial vs all-or-nothing');
    assert.equal(p.visible('floorL'), false, 'the floor only applies to a Dutch order');
    assert.equal(p.visible('slipL'), false, 'a limit order has no slippage');
    p.close();
  });

  test('switching to Dutch swaps the fill control for a decay floor', async () => {
    const p = await setup();
    p.select('kind', 'dutch');
    await p.settle();
    assert.equal(p.visible('floorL'), true);
    assert.equal(p.visible('fillL'), false);
    assert.equal(p.text('rcvHdr'), 'Start ask total');
    assert.equal(p.visible('rc'), false, 'a Dutch auction cannot be made private');
    p.close();
  });

  test('the expiry select is relabelled from the send-tab time lock', async () => {
    const p = await setup();
    assert.match(p.$('dlyL').textContent, /Expires/);
    assert.equal(p.$('dly').options[0].textContent, 'Never');
    p.close();
  });
});

describe('order validation', () => {
  test('needs both a sell and a want amount', async () => {
    const p = await setup();
    assert.equal(p.text('swap'), 'Place order');
    assert.equal(p.disabled('swap'), true);
    p.type('amt', '1');
    await p.settle();
    assert.equal(p.disabled('swap'), true, 'a price is still missing');
    p.type('outAmt', '4000');
    await p.settle();
    assert.equal(p.disabled('swap'), false);
    p.close();
  });

  test('previews the exact order on the button', async () => {
    const p = await setup();
    p.type('amt', '1');
    p.type('outAmt', '4000');
    await p.settle();
    assert.match(p.text('swap'), /Place order — 1 ETH → 4000 USDC/);
    p.close();
  });

  test('an order that wants ETH says it will settle in WETH', async () => {
    const p = await setup();
    p.click('flip');           // sell USDC, want ETH
    await p.settle();
    p.type('amt', '3000');
    p.type('outAmt', '1');
    await p.settle();
    assert.match(p.text('swap'), /→ 1 WETH/,
      'the board is a WETH book, and the button must not promise raw ETH');
    p.close();
  });

  test('an all-or-nothing order says so before it is placed', async () => {
    const p = await setup();
    p.type('amt', '1');
    p.type('outAmt', '4000');
    p.select('fill', '0');
    await p.settle();
    assert.match(p.text('swap'), /all-or-nothing/);
    p.close();
  });

  test('refuses to sell more than the balance', async () => {
    const p = await setup();
    p.type('amt', '9999');
    p.type('outAmt', '1');
    await p.settle();
    assert.equal(p.text('swap'), 'Insufficient balance');
    assert.equal(p.disabled('swap'), true);
    p.close();
  });

  test('a Dutch floor above the starting ask is rejected', async () => {
    const p = await setup();
    p.select('kind', 'dutch');
    await p.settle();
    p.type('amt', '1');
    p.type('outAmt', '3000');
    p.type('floorAmt', '4000');
    await p.settle();
    assert.equal(p.text('swap'), 'Floor exceeds start');
    assert.equal(p.disabled('swap'), true);
    p.close();
  });

  test('the floor is seeded from the ask instead of defaulting to free', async () => {
    // An empty Floor total reads as ZERO, and zero is a real price: the
    // schedule rests at its floor once the window elapses, so the lot can be
    // taken for nothing, indefinitely. That is a legitimate shape and it is not
    // what an empty field means. Half the opening is the classic auction shape
    // - open at twice your reserve, decay to it - and above all it is a number
    // the seller has seen.
    const p = await setup();
    p.select('kind', 'dutch');
    await p.settle();
    p.type('amt', '1');
    p.type('outAmt', '3000');
    await p.settle();
    assert.equal(p.value('floorAmt'), '1500', 'the floor follows the ask');
    p.close();
  });

  test('a floor the user typed is never overwritten, including a zero', async () => {
    const p = await setup();
    p.select('kind', 'dutch');
    await p.settle();
    p.type('amt', '1');
    p.type('outAmt', '3000');
    await p.settle();
    p.type('floorAmt', '0');           // a deliberate come-and-take-it launch
    await p.settle();
    p.type('outAmt', '4000');          // re-pricing must not undo that choice
    await p.settle();
    assert.equal(p.value('floorAmt'), '0', 'the page stopped having opinions once asked');
    p.close();
  });

  test('a zero floor is asked about before it is signed', async () => {
    const p = await setup();
    p.select('kind', 'dutch');
    await p.settle();
    p.type('amt', '1');
    p.type('outAmt', '3000');
    await p.settle();
    p.type('floorAmt', '0');
    await p.settle();

    // Declined: nothing is sent.
    p.queueConfirm(false);
    p.click('swap');
    await p.settle();
    assert.equal(p.chain.sent.length, 0, 'a refused confirmation places no order');

    // Accepted: it goes, because this shape is allowed on purpose.
    p.queueConfirm(true);
    p.click('swap');
    await p.settle();
    assert.ok(p.chain.sent.length > 0, 'a confirmed zero floor is still placeable');
    p.close();
  });

  test('the duration control is named for what it does, per order type', async () => {
    // One control, three meanings, and only one of them was "Expires". On a
    // fixed order the duration IS an expiry. On a Dutch it is the decay window,
    // and `placeDutch` takes no expiry at all - the listing rests at its floor
    // until cancelled, so "Expires: 1 day" promised the opposite of the truth.
    const p = await setup();
    const label = () => p.$('dlyL').textContent.replace(/\s+/g, ' ').trim();
    assert.match(label(), /^Expires/, 'a fixed order really does expire');

    p.select('kind', 'dutch');
    await p.settle();
    assert.match(label(), /^Decays over/, 'a Dutch decays; it does not expire');

    p.select('kind', 'floor');
    await p.settle();
    assert.match(label(), /^Bid window/, 'a bid is dead past its window, not resting');
    p.close();
  });

  test('the form says what the order will still be doing tomorrow', async () => {
    // The button states the terms. It cannot state the BEHAVIOUR, which is the
    // part people get wrong - a Dutch that ends its window keeps sitting there,
    // fillable at the floor, and nothing on the form said so.
    const p = await setup();
    p.select('kind', 'dutch');
    await p.settle();
    p.type('amt', '1');
    p.type('outAmt', '3000');
    p.type('floorAmt', '1000');
    await p.settle();

    const said = p.text('rate');
    assert.match(said, /Falls from 3000 to 1000/, 'states the schedule');
    assert.match(said, /rests at 1000 .* until you cancel/i,
      'and states the resting behaviour, which is the part that surprises people');
    p.close();
  });

  test('a Dutch order defaults to a real decay window rather than "Never"', async () => {
    const p = await setup();
    p.select('kind', 'dutch');
    await p.settle();
    assert.notEqual(p.value('dly'), '0', 'a decay with no duration is not an auction');
    p.close();
  });

  test('a Dutch order with no duration cannot be placed', async () => {
    const p = await setup();
    p.select('kind', 'dutch');
    await p.settle();
    p.select('dly', '0');
    p.type('amt', '1');
    p.type('outAmt', '3000');
    await p.settle();
    assert.equal(p.text('swap'), 'Choose decay duration');
    assert.equal(p.disabled('swap'), true);
    p.close();
  });
});

describe('placing orders', () => {
  test('a fixed order routes through the adapter with the right terms', async () => {
    const p = await setup();
    p.type('amt', '2');
    p.type('outAmt', '7000');
    await p.settle();
    p.click('swap');
    await p.waitFor(() => p.chain.sent.length > 0, { label: 'placement' });
    await p.settle();

    const tx = p.chain.lastSent;
    assert.equal(tx.to.toLowerCase(), A.ZROUTER.toLowerCase(), 'placement is routed, not direct');
    assert.equal(BigInt(tx.value), 2n * ETH, 'the sold ETH rides as msg.value');

    const order = placementPayload(tx);
    assert.equal(selectorOf(order), SEL.ORDER_FIXED);
    const b = '0x' + order.slice(10);
    assert.equal(wordAddr(b, 0).toLowerCase(), A.SB2.toLowerCase(), 'placed on the current board');
    assert.equal(wordAddr(b, 1).toLowerCase(), A.ACCOUNT.toLowerCase(), 'maker is the connected account');
    assert.equal(wordAddr(b, 3), A.ZERO, 'selling native ETH');
    assert.equal(word(b, 4), 2n * ETH, 'sell amount');
    assert.equal(wordAddr(b, 5).toLowerCase(), A.USDC.toLowerCase(), 'quote token');
    assert.equal(word(b, 6), 7000n * USDC, 'want amount, in the quote token\'s units');
    assert.equal(word(b, 7), 1n, 'partial fills allowed by default');
    // The tab defaults to a 1-day expiry rather than "Never", so a forgotten
    // order stops being fillable instead of lingering against a stale price.
    const now = BigInt(Math.floor(Date.now() / 1000));
    assert.ok(word(b, 8) > now && word(b, 8) <= now + 86500n, 'default 1-day expiry');
    assert.equal(wordAddr(b, 9), A.ZERO, 'public order');
    p.close();
  });

  test('an all-or-nothing order sets the partial-fill flag off', async () => {
    const p = await setup();
    p.type('amt', '2');
    p.type('outAmt', '7000');
    p.select('fill', '0');
    await p.settle();
    p.click('swap');
    await p.waitFor(() => p.chain.sent.length > 0, { label: 'placement' });
    await p.settle();
    assert.equal(word('0x' + placementPayload(p.chain.lastSent).slice(10), 7), 0n);
    p.close();
  });

  test('an expiry is written as an absolute deadline', async () => {
    const p = await setup();
    p.type('amt', '1');
    p.type('outAmt', '3000');
    p.select('dly', '3600');
    await p.settle();
    p.click('swap');
    await p.waitFor(() => p.chain.sent.length > 0, { label: 'placement' });
    await p.settle();

    const exp = word('0x' + placementPayload(p.chain.lastSent).slice(10), 8);
    const now = BigInt(Math.floor(Date.now() / 1000));
    assert.ok(exp > now && exp <= now + 3700n, `expiry ${exp} should be ~1h out, now ${now}`);
    p.close();
  });

  test('a private order carries the resolved counterparty', async () => {
    const p = await setup(c => c.names.set('bob.wei', A.OTHER));
    p.type('amt', '1');
    p.type('outAmt', '3000');
    p.type('rc', 'bob.wei');
    await p.settle();
    p.click('swap');
    await p.waitFor(() => p.chain.sent.length > 0, { label: 'placement' });
    await p.settle();

    const cp = wordAddr('0x' + placementPayload(p.chain.lastSent).slice(10), 9);
    assert.equal(cp.toLowerCase(), A.OTHER.toLowerCase(),
      'the name must be resolved to an address before it is booked');
    p.close();
  });

  test('a Dutch order carries start, floor and duration', async () => {
    const p = await setup();
    p.select('kind', 'dutch');
    await p.settle();
    p.type('amt', '5');
    p.type('outAmt', '20000');
    p.type('floorAmt', '15000');
    p.select('dly', '86400');
    await p.settle();
    assert.match(p.text('swap'), /Dutch 5 ETH · 20000 → 15000 USDC/);

    p.click('swap');
    await p.waitFor(() => p.chain.sent.length > 0, { label: 'placement' });
    await p.settle();

    const order = placementPayload(p.chain.lastSent);
    assert.equal(selectorOf(order), SEL.ORDER_DUTCH);
    const b = '0x' + order.slice(10);
    assert.equal(wordAddr(b, 0).toLowerCase(), A.DUTCH.toLowerCase());
    assert.equal(wordAddr(b, 3), A.ZERO, 'selling ETH');
    assert.equal(wordAddr(b, 4).toLowerCase(), A.USDC.toLowerCase(), 'quoted in USDC');
    assert.equal(word(b, 5), 5n * ETH, 'lot size');
    assert.equal(word(b, 6), 20000n * USDC, 'starting ask');
    assert.equal(word(b, 7), 15000n * USDC, 'floor');
    assert.equal(word(b, 9), 86400n, 'decay duration');
    p.close();
  });

  test('an ERC-20 sale snapshots the adapter before funding it', async () => {
    const p = await setup(c => c.setAllowance(A.USDC, A.ACCOUNT, A.ZROUTER, 10n ** 30n));
    p.click('flip');   // sell USDC for ETH
    await p.settle();
    p.type('amt', '3000');
    p.type('outAmt', '1');
    await p.settle();
    p.click('swap');
    await p.waitFor(() => p.chain.sent.length > 0, { label: 'placement' });
    await p.settle();

    const calls = innerCalls(p.chain.lastSent.data);
    // Without the checkpoint, tokens already sitting in the adapter could be
    // swept into this caller's order.
    const checkpoint = calls.find(c =>
      selectorOf(c) === SEL.SNWAP && selectorOf(snwapPayload(c)) === SEL.CHECKPOINT);
    assert.ok(checkpoint, 'placement must checkpoint the adapter balance first');
    assert.equal(p.chain.lastSent.value, '0x0', 'an ERC-20 sale sends no ether');
    p.close();
  });

  test('refuses to place when the adapter is not deployed', async () => {
    const p = await setup(c => c.undeploy(A.ORDERBOL));
    p.type('amt', '1');
    p.type('outAmt', '3000');
    await p.settle();
    p.click('swap');
    await p.settle();
    assert.equal(p.chain.sent.length, 0);
    assert.match(p.text('stat'), /not deployed/);
    p.close();
  });
});

describe('the orderbook drawer', () => {
  const row = over => ({
    id: 1, board: A.SB2, maker: A.OTHER, pf: true, exp: 0,
    tA: A.USDC, aA: 3000n * USDC, symA: 'USDC', decA: 6,
    tB: A.WETH, aB: ETH, symB: 'WETH', decB: 18,
    ...over,
  });

  test('there is no control when the book is empty', async () => {
    const p = await setup();
    await p.settle();
    assert.equal(p.visible('bkTog'), false, 'an empty book needs no caret');
    p.close();
  });

  test('appears with a count once orders exist, and the list scrolls', async () => {
    const p = await setup(c => { c.recent = [row({ id: 1 }), row({ id: 2 })]; });
    await p.waitFor(() => p.visible('bkTog'), { label: 'caret' });
    assert.match(p.text('bkTog'), /Orderbook \(2\)/);
    assert.equal(p.visible('book'), true);
    // Capped height with its own scroller, so a long book cannot stretch the tile.
    const css = [...p.doc.querySelectorAll('style')].map(x => x.textContent).join('');
    assert.match(css, /#book\{[^}]*max-height/);
    assert.match(css, /#book\{[^}]*overflow-y:auto/);
    p.close();
  });

  test('collapses and remembers the choice', async () => {
    const p = await setup(c => { c.recent = [row()]; });
    await p.waitFor(() => p.visible('bkTog'), { label: 'caret' });
    p.click('bkTog');
    assert.equal(p.visible('book'), false, 'the list hides');
    assert.equal(p.$('bkTog').getAttribute('aria-expanded'), 'false');
    assert.equal(p.window.localStorage.getItem('bk'), '0');
    p.close();

    // A fresh page with the stored preference must come back collapsed.
    const chain = new MockChain();
    chain.setNative(A.ACCOUNT, 100n * ETH);
    chain.quoteHandler = fixedRateQuoter({ rate: 3000n * ETH });
    chain.recent = [row()];
    const p2 = await loadPage({ chain, storage: { bk: '0' } });
    await p2.connect();
    p2.click('tabBook');
    await p2.waitFor(() => p2.visible('bkTog'), { label: 'caret' });
    assert.equal(p2.visible('book'), false, 'a collapsed book stays collapsed');
    p2.close();
  });

  test('is absent on the swap and send tabs', async () => {
    const p = await setup(c => { c.recent = [row()]; });
    await p.waitFor(() => p.visible('bkTog'), { label: 'caret' });
    p.click('tabSwap');
    await p.settle();
    assert.equal(p.visible('bkTog'), false);
    p.close();
  });
});

describe('the orderbook list', () => {
  const order = over => ({
    id: 1, board: A.SB2, maker: A.OTHER, pf: true, exp: 0,
    tA: A.USDC, aA: 3000n * USDC, symA: 'USDC', decA: 6,
    tB: A.WETH, aB: ETH, symB: 'WETH', decB: 18,
    ...over,
  });

  test('Fill asks how much, and takes only that much', async () => {
    // The button used to mean "take the whole order", which on a large one
    // quotes a number most people cannot cover and stops - while the same order
    // was available in pieces to the swap path all along. Reported from the
    // field as "why can't I buy a small amount?".
    const p = await setup(c => { c.recent = [order({ id: 5 })]; });
    await p.waitFor(() => p.$('book').textContent.includes('Orderbook'), { label: 'book' });

    p.queuePrompt('0.25');                       // a quarter of the 1 WETH ask
    p.click(p.$('book').querySelector('button'));
    await p.waitFor(() => p.chain.sent.length > 0, { label: 'fill' });
    await p.settle();

    // The amount that goes out is the one that was asked for, not the ask.
    const tx = p.chain.lastSent;
    const paid = JSON.stringify(tx).toLowerCase();
    assert.ok(paid.includes((250000000000000000n).toString(16)),
      'the transaction should carry the 0.25 WETH the user chose');
    assert.ok(!paid.includes((1000000000000000000n).toString(16).padStart(16, '0') + '0'.repeat(0)) ||
      paid.includes((250000000000000000n).toString(16)),
      'and not silently take the whole order');
    p.close();
  });

  test('a declined amount sends nothing at all', async () => {
    const p = await setup(c => { c.recent = [order({ id: 5 })]; });
    await p.waitFor(() => p.$('book').textContent.includes('Orderbook'), { label: 'book' });
    p.click(p.$('book').querySelector('button'));   // no queued answer = cancelled
    await p.settle();
    assert.equal(p.chain.sent.length, 0, 'dismissing the prompt must not place a fill');
    p.close();
  });

  test('an all-or-nothing order is never asked about', async () => {
    // Only the board can split an order. Asking "how much?" about one that
    // cannot be split would offer a choice that does not exist.
    const p = await setup(c => { c.recent = [order({ id: 5, pf: false })]; });
    await p.waitFor(() => p.$('book').textContent.includes('Orderbook'), { label: 'book' });
    p.click(p.$('book').querySelector('button'));   // no prompt queued, yet it proceeds
    await p.waitFor(() => p.chain.sent.length > 0, { label: 'fill' });
    p.close();
  });

  test('lists other makers\' orders with a fill action', async () => {
    const p = await setup(c => { c.recent = [order()]; });
    await p.waitFor(() => p.$('book').textContent.includes('Orderbook'), { label: 'book' });
    assert.match(p.$('book').textContent, /3000 USDC → 1 WETH/);
    const btn = p.$('book').querySelector('button');
    assert.equal(btn.textContent, 'Fill');
    p.close();
  });

  test('separates your own orders and offers to cancel them', async () => {
    const p = await setup(c => { c.recent = [order({ maker: A.ACCOUNT })]; });
    await p.waitFor(() => p.$('book').textContent.includes('Your orders'), { label: 'own orders' });
    assert.equal(p.$('book').querySelector('button').textContent, 'Cancel');
    p.close();
  });

  test('tags all-or-nothing, private and Dutch rows', async () => {
    const p = await setup(c => {
      c.recent = [
        order({ id: 1, pf: false }),
        order({ id: 2, cp: A.ACCOUNT }),
        order({ id: 3, dutch: true, board: A.DUTCH }),
      ];
    });
    await p.waitFor(() => p.$('book').querySelectorAll('.o').length >= 3, { label: 'rows' });
    const tags = [...p.$('book').querySelectorAll('.tg')].map(t => t.textContent);
    assert.ok(tags.includes('AON'), 'an all-or-nothing order must be marked');
    assert.ok(tags.includes('private'), 'a restricted order must be marked');
    assert.ok(tags.includes('Dutch'), 'a decaying order must be marked');
    p.close();
  });

  test('a native leg is not linked to the zero-address token page', async () => {
    // Dutchboard can quote a lot in native ETH, and ETH has no token contract.
    const p = await setup(c => { c.recent = [order({ tB: A.ZERO, symB: 'ETH', decB: 18 })]; });
    await p.waitFor(() => p.$('book').querySelectorAll('.o').length >= 1, { label: 'rows' });
    const links = [...p.$('book').querySelectorAll('a')].map(a => a.getAttribute('href'));
    assert.ok(!links.some(h => /0x0{40}/.test(h || '')),
      'a link to the zero address is a dead end, not a token page');
    p.close();
  });

  test('warns on tokens that are not on the known list', async () => {
    const p = await setup(c => {
      c.recent = [order({ tA: '0x9999999999999999999999999999999999999999', symA: 'SCAM' })];
    });
    await p.waitFor(() => p.$('book').querySelectorAll('.o').length >= 1, { label: 'rows' });
    const warn = p.$('book').querySelector('.tg.w');
    assert.ok(warn, 'an unrecognised token must carry a visible warning');
    assert.equal(warn.textContent, 'unverified');
    p.close();
  });

  test('hides orders private to somebody else', async () => {
    const p = await setup(c => {
      c.recent = [order({ id: 1 }), order({ id: 2, cp: '0x8888888888888888888888888888888888888888' })];
    });
    await p.waitFor(() => p.$('book').querySelectorAll('.o').length >= 1, { label: 'rows' });
    assert.equal(p.$('book').querySelectorAll('.o').length, 1,
      'an order you cannot fill must not be advertised to you');
    p.close();
  });

  test('hides expired orders', async () => {
    const p = await setup(c => {
      c.recent = [order({ id: 1, exp: Math.floor(Date.now() / 1000) - 60 })];
    });
    await p.settle();
    assert.equal(p.$('book').querySelectorAll('.o').length, 0);
    p.close();
  });

  test('a hostile token symbol cannot inject markup into the list', async () => {
    const evil = '<img src=x onerror=alert(1)>';
    const p = await setup(c => {
      c.recent = [order({ tA: '0x9999999999999999999999999999999999999999', symA: evil })];
    });
    await p.waitFor(() => p.$('book').querySelectorAll('.o').length >= 1, { label: 'rows' });
    assert.equal(p.$('book').querySelectorAll('img').length, 0,
      'lens-provided metadata is attacker-controlled and must never become markup');
    assert.ok(!p.$('book').innerHTML.includes('onerror'));
    p.close();
  });

  test('cancelling an order calls the board directly', async () => {
    const p = await setup(c => { c.recent = [order({ id: 7, maker: A.ACCOUNT })]; });
    await p.waitFor(() => p.$('book').textContent.includes('Your orders'), { label: 'own orders' });
    // Fill now asks HOW MUCH; answering with the whole ask is the old behaviour.
    p.queuePrompt('1');
    p.click(p.$('book').querySelector('button'));
    await p.waitFor(() => p.chain.sent.length > 0, { label: 'cancel' });
    await p.settle();

    const tx = p.chain.lastSent;
    assert.equal(tx.to.toLowerCase(), A.SB2.toLowerCase());
    assert.equal(word('0x' + tx.data.slice(10), 0), 7n, 'cancels the order that was clicked');
    p.close();
  });

  // Which side of the native boundary a fill pays from is a property of the
  // ORDER and of what the account holds — not of the swap pickers, which are
  // set for an unrelated trade. So the same row has two correct executions,
  // and both are pinned here.
  test('filling a public order pays in WETH when the account holds enough', async () => {
    // setup() funds the account with WETH, which covers the 1 WETH ask.
    const p = await setup(c => { c.recent = [order({ id: 5 })]; });
    await p.waitFor(() => p.$('book').textContent.includes('Orderbook'), { label: 'book' });
    // Fill now asks HOW MUCH; answering with the whole ask is the old behaviour.
    p.queuePrompt('1');
    p.click(p.$('book').querySelector('button'));
    await p.waitFor(() => p.chain.sent.length > 0, { label: 'fill' });
    await p.settle();

    const tx = p.chain.lastSent;
    assert.equal(tx.to.toLowerCase(), A.ZROUTER.toLowerCase());
    // No wrap step and no extra approval: the balance is already in the form
    // the board wants, so nothing rides as value.
    assert.equal(BigInt(tx.value), 0n, 'spent ETH while holding enough WETH');
    p.close();
  });

  test('filling a public order sends ETH when the WETH balance cannot cover it', async () => {
    const p = await setup(c => {
      c.recent = [order({ id: 5 })];
      c.setErc20(A.WETH, A.ACCOUNT, 0n);
    });
    await p.waitFor(() => p.$('book').textContent.includes('Orderbook'), { label: 'book' });
    // Fill now asks HOW MUCH; answering with the whole ask is the old behaviour.
    p.queuePrompt('1');
    p.click(p.$('book').querySelector('button'));
    await p.waitFor(() => p.chain.sent.length > 0, { label: 'fill' });
    await p.settle();

    const tx = p.chain.lastSent;
    assert.equal(tx.to.toLowerCase(), A.ZROUTER.toLowerCase());
    assert.equal(BigInt(tx.value), ETH, 'must send exactly the order\'s asking amount');
    p.close();
  });

  test('wraps the shortfall when neither balance covers it but both together do', async () => {
    // The case the old setting could not express at all: half wrapped, half
    // not, and a 1 WETH order that neither half can pay for. It used to be a
    // fill the page simply refused while the money was sitting right there.
    const p = await setup(c => {
      c.recent = [order({ id: 5 })];
      c.setErc20(A.WETH, A.ACCOUNT, ETH / 2n);
      c.setNative(A.ACCOUNT, ETH / 2n + ETH / 10n);   // the halves, plus gas
    });
    await p.waitFor(() => p.$('book').textContent.includes('Orderbook'), { label: 'book' });
    // Fill now asks HOW MUCH; answering with the whole ask is the old behaviour.
    p.queuePrompt('1');
    p.click(p.$('book').querySelector('button'));
    await p.waitFor(() => p.chain.sent.length > 1, { label: 'wrap then fill' });
    await p.settle();

    const [wrap] = p.chain.sent;
    assert.equal(wrap.to.toLowerCase(), A.WETH.toLowerCase(), 'wraps first');
    assert.equal(selectorOf(wrap.data), SEL.WETH_DEPOSIT);
    assert.equal(BigInt(wrap.value), ETH / 2n, 'exactly the shortfall, not the whole ask');

    const fill = p.chain.lastSent;
    assert.equal(fill.to.toLowerCase(), A.ZROUTER.toLowerCase(), 'then fills');
    assert.equal(BigInt(fill.value || 0), 0n, 'paying in WETH now that it covers the leg');
    p.close();
  });

  test('keeps a gas reserve back rather than wrapping the last wei', async () => {
    // Wrapping everything leaves nothing to send the fill with, which is a
    // worse failure than the one being avoided.
    const p = await setup(c => {
      c.recent = [order({ id: 5 })];
      c.setErc20(A.WETH, A.ACCOUNT, ETH / 2n);
      c.setNative(A.ACCOUNT, ETH / 2n);   // exactly the shortfall, no gas margin
    });
    await p.waitFor(() => p.$('book').textContent.includes('Orderbook'), { label: 'book' });
    // Fill now asks HOW MUCH; answering with the whole ask is the old behaviour.
    p.queuePrompt('1');
    p.click(p.$('book').querySelector('button'));
    await p.waitFor(() => /Not enough ether/i.test(p.text('stat')), { label: 'the refusal' });
    assert.equal(p.chain.sent.length, 0, 'and nothing was wrapped on the way to failing');
    p.close();
  });

  test('refuses a fill the account cannot pay for, before any approval', async () => {
    // The reported case: an order asking 100 WETH against an account holding
    // none. It cost an approval and then reverted, and "execution reverted"
    // says nothing about the balance being the problem.
    const p = await setup(c => {
      c.recent = [order({ id: 5 })];
      c.setErc20(A.WETH, A.ACCOUNT, 0n);
      c.setNative(A.ACCOUNT, 0n);              // no ETH to wrap either
    });
    await p.waitFor(() => p.$('book').textContent.includes('Orderbook'), { label: 'book' });
    // Fill now asks HOW MUCH; answering with the whole ask is the old behaviour.
    p.queuePrompt('1');
    p.click(p.$('book').querySelector('button'));
    await p.waitFor(() => /Not enough/i.test(p.text('stat')), { label: 'the refusal' });
    await p.settle();

    // Both balances, not one: "not enough WETH" while holding ether reads as a
    // page that cannot see the money it is standing on.
    assert.match(p.text('stat'), /Not enough ether/i, 'must say what is short');
    assert.match(p.text('stat'), /0 WETH plus 0 ETH/i, 'and account for both sides of it');
    // The point of checking first: no approval, no gas, no allowance left
    // standing for a trade that could never have settled.
    assert.equal(p.chain.sent.length, 0, 'nothing was sent, least of all an approval');
    p.close();
  });

  test('asks only what it cannot work out for itself', async () => {
    // The old control conflated two things and asked about both: which balance
    // to spend, and what to be paid in. The first is arithmetic - the page can
    // see both balances - and getting it wrong is a revert, not a matter of
    // taste. Only the second is a preference, so only the second is asked.
    const p = await setup();
    // It said "Receive", which names the outcome but not the ACT - and it sits
    // in the placement form, so it read as "how this order pays me". It does not
    // govern that and cannot: a board denominates in WETH, and a maker's
    // proceeds are transferred as WETH with no unwrap available. Asked about a
    // real placement, the page had to print a note explaining that the control
    // the user had just set would not apply. Naming the two acts it DOES govern
    // is what stops the misreading.
    const label = p.$('ethModeL').textContent.replace(/\s+/g, ' ').trim();
    assert.match(label, /^Fills & cancels pay/,
      'the label should name what it decides, and it decides about fills and cancels');
    assert.deepEqual([...p.$('ethMode').options].map(o => o.textContent), ['ETH', 'WETH'],
      'two outcomes, both of which land in the wallet');

    const help = p.$('ethModeL').getAttribute('title') || '';
    assert.match(help, /Paying is not a setting/i, 'and says so, so nobody looks for it');
    assert.match(help, /does NOT change what an order you place pays you/i,
      'and the one thing it is most likely to be mistaken for is denied outright');
    p.close();
  });

  test('an empty book renders nothing at all', async () => {
    const p = await setup();
    await p.settle();
    assert.equal(p.text('book'), '', 'no rows, no header, no empty-state clutter');
    assert.equal(p.visible('bkTog'), false);
    p.close();
  });
});
