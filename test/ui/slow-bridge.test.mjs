/**
 * Sending ETH from Ethereum to Base or Robinhood, and what the sender can
 * still do about it once it lands.
 *
 * Two lanes leave mainnet. An INSTANT send is the destination chain's own
 * deposit: OptimismPortal.depositTransaction for Base, Inbox.createRetryableTicket
 * for Robinhood, recipient named as the target and no calldata. A TIME-LOCKED
 * send is the same message aimed at SlowArrival, carrying
 * `arrive(to, delay, originHint, bounty)` — because SLOW records
 * `pendingTransfers[id].from = msg.sender`, and on this route that would be the
 * bridge, not the sender. SlowArrival becomes the depositor instead and hands
 * the reverse back to the origin it recovered.
 *
 * The `originHint` is the whole point of the second lane and is what these
 * tests are most careful about. Nitro aliases retryable senders unconditionally
 * — EOAs included — so on Robinhood the caller SlowArrival sees is the sender's
 * address plus 0x1111…1111, which has a key on neither chain. The hint is what
 * `SlowOrigin.recover` matches against that alias. Send it wrong and the ether
 * arrives under an address nobody can reverse from.
 *
 * On the far side the sender does not appear in their own
 * `getOutboundTransfers` — SlowArrival is `from` there. Discovery is
 * SlowArrival's outbound set narrowed by `originOf`, and the buttons on those
 * rows must call SlowArrival rather than SLOW, which is the other thing these
 * tests pin.
 */
import { test, describe, after } from 'node:test';
import assert from 'node:assert/strict';
import {
  A, SEL, MockChain, loadPage, word, wordAddr, selectorOf, closeAllPages, relayIntentId,
} from './harness.mjs';

after(closeAllPages);

const ETH = 10n ** 18n;
const GWEI = 10n ** 9n;
const BASE = '0x2105', RH = '0x1237';

/** Mainnet, connected, on the Send tab, with both destinations reachable. */
async function setup(prep = () => {}) {
  const chain = new MockChain();
  chain.setNative(A.ACCOUNT, 10n * ETH);
  chain.setErc20(A.USDC, A.ACCOUNT, 5_000n * 10n ** 6n);
  // The page asks the DESTINATION whether the recipient has code, and asks
  // Robinhood its gas price. Both go out over plain HTTP to that chain's node.
  chain.remotes['base-rpc'] = new MockChain({ chainId: BASE });
  chain.remotes['base.org'] = chain.remotes['base-rpc'];
  chain.remotes['robinhood'] = new MockChain({ chainId: RH });
  prep(chain);
  const p = await loadPage({ chain });
  await p.connect();
  p.click('tabSend');
  await p.settle();
  return p;
}

async function recipient(p, v) {
  p.type('rc', v);
  await new Promise(r => p.window.setTimeout(r, 320));
  await p.settle();
}

/** Connected on an L2's Send tab. */
async function onChainSend(chainId = BASE, prep = () => {}, storage = {}) {
  const chain = new MockChain({ chainId });
  chain.setNative(A.ACCOUNT, 10n * ETH);
  prep(chain);
  const p = await loadPage({ chain, hash: null, storage });
  await p.connect({ pin: false });
  p.click('tabSend');
  await p.settle();
  return p;
}

// Leaving an L2 hands the money to a relayer that may not exist yet, so the
// lane is OFF unless the browser opts in. Everything below opts in; the tests
// that the default is off live in the selector describe.
const RELAY_ON = { 'zswap:relay': '1' };
const L1_GWEI = 10n ** 9n;

/** An L2 with the relay lane enabled and a mainnet node to price the fee from. */
async function onBaseSend(prep = () => {}, storage = {}) {
  return onChainSend(BASE, c => {
    const l1 = new MockChain({ chainId: '0x1', gasPrice: L1_GWEI });
    c.remotes['ethereum-rpc'] = l1;
    c.remotes['blastapi'] = l1;
    c.l1 = l1;
    prep(c);
  }, { ...RELAY_ON, ...storage });
}

/** As above, but localStorage refuses every write. */
async function onBaseSendBrokenStorage() {
  const chain = new MockChain({ chainId: BASE });
  chain.setNative(A.ACCOUNT, 10n * ETH);
  const l1 = new MockChain({ chainId: '0x1', gasPrice: L1_GWEI });
  chain.remotes['ethereum-rpc'] = l1;
  chain.remotes['blastapi'] = l1;
  const p = await loadPage({ chain, hash: null, storage: RELAY_ON, storageBroken: true });
  await p.connect({ pin: false });
  p.click('tabSend');
  await p.settle();
  return p;
}

/** The fee the page must charge: a rate, floored by one mainnet transaction. */
const expectFee = (amount, dest) => {
  const bps = { 1: 2n, 8453: 30n, 4663: 35n }[dest];
  const rate = amount * bps / 10000n;
  const flat = L1_GWEI * 600000n;
  return rate > flat ? rate : flat;
};

/** The 11 static words of a SlowRelay Intent, as `open` takes them inline. */
function intentOf(data) {
  assert.equal(selectorOf(data), SEL.ROPEN, 'leaving an L2 opens an escrow');
  const b = '0x' + data.slice(10);
  return {
    sender: wordAddr(b, 0), recipient: wordAddr(b, 1),
    srcToken: wordAddr(b, 2), dstToken: wordAddr(b, 3),
    amount: word(b, 4), fee: word(b, 5), delay: word(b, 6),
    srcChainId: word(b, 7), dstChainId: word(b, 8),
    fillDeadline: word(b, 9), nonce: word(b, 10),
  };
}

/** Fill in a send and press the button, returning the transaction it built. */
async function sendTo(p, { dest, amount = '2', delay = '0', to = A.OTHER }) {
  await p.typeAmount('amt', amount);
  await recipient(p, to);
  p.select('dly', delay);
  p.select('sdChain', dest);
  await p.settle();
  // Changing the destination re-resolves the recipient, and an ENS name takes
  // more round trips than a hex address. Wait for the page to be ready to send
  // rather than for a fixed delay.
  await p.waitFor(() => !p.disabled('swap'), { label: 'a send the page will make' });
  p.click('swap');
  await p.waitFor(() => p.chain.sent.length > 0, { label: 'bridge tx' });
  await p.settle();
  return p.chain.lastSent;
}

/** The `arrive` call SlowArrival runs on the far side, unpacked. */
function arriveCall(inner) {
  assert.equal(selectorOf(inner), SEL.ARRIVE, 'the far side runs arrive(), not depositTo()');
  const body = '0x' + inner.slice(10);
  return {
    to: wordAddr(body, 0), delay: word(body, 1),
    originHint: wordAddr(body, 2), bounty: word(body, 3),
  };
}

/** The bytes argument of an OP deposit / an Arbitrum retryable. */
function tail(data, offWord) {
  const body = '0x' + data.slice(10);
  const off = Number(word(body, offWord));
  assert.equal(off, (offWord + 1) * 32, 'the bytes argument sits right after the head');
  const len = Number(word(body, offWord + 1));
  return len === 0 ? '0x' : '0x' + body.slice(2 + (offWord + 2) * 64, 2 + (offWord + 2) * 64 + len * 2);
}

describe('the destination selector', () => {
  test('is offered on mainnet and defaults to staying here', async () => {
    const p = await setup();
    assert.equal(p.visible('sdChainL'), true);
    assert.equal(p.value('sdChain'), '0', 'a send goes nowhere new unless it is asked to');
    p.close();
  });

  test('offers both L2s from mainnet, where the bridges are the chains\' own', async () => {
    const p = await setup();
    const opts = [...p.$('sdChain').options].map(o => o.value);
    assert.deepEqual(opts, ['0', '8453', '4663'], 'mainnet reaches both L2s');
    p.close();
  });

  // Leaving an L2 escrows the money against a relayer delivering the far leg.
  // Until one is actually running that is a way to lock your own funds for
  // eight days, so the lane is not offered unless the browser asks for it.
  // Closed by default, but reachable — a lane nobody can turn on is a lane
  // that never gets a first user, and it needs one before it can have a
  // relayer. The door states the whole downside before it opens.
  test('is closed on an L2 by default, behind a door that says why', async () => {
    const p = await onChainSend(BASE);
    assert.equal(p.visible('sdChainL'), false, 'not offered until it is asked for');
    assert.equal(p.visible('rlOptL'), true, 'but the way to ask is right there');
    p.close();
  });

  test('the door says the money can be locked for eight days before it opens', async () => {
    const p = await onChainSend(BASE);
    let asked = '';
    p.window.confirm = (t) => { asked = t; return false; };
    p.click('rlOpt');
    await p.settle();
    assert.match(asked, /8 days and 6 hours/, 'the worst case is stated, not implied');
    assert.match(asked, /Nobody is obliged/);
    assert.equal(p.visible('sdChainL'), false, 'declining leaves it closed');
    p.close();
  });

  test('accepting opens the lane and remembers it', async () => {
    const p = await onChainSend(BASE);
    p.window.confirm = () => true;
    p.click('rlOpt');
    await p.settle();
    assert.equal(p.visible('sdChainL'), true);
    assert.equal(p.visible('rlOptL'), false, 'the door closes behind you');
    assert.deepEqual([...p.$('sdChain').options].map(o => o.value), ['0', '1', '4663']);
    assert.equal(p.window.localStorage.getItem('zswap:relay'), '1');
    p.close();
  });

  test('mainnet never shows the door — its bridges need no relayer', async () => {
    const p = await setup();
    assert.equal(p.visible('rlOptL'), false);
    assert.equal(p.visible('sdChainL'), true);
    p.close();
  });

  test('is offered on an L2 once the browser opts in', async () => {
    const b = await onBaseSend();
    assert.equal(b.visible('sdChainL'), true);
    const bopts = [...b.$('sdChain').options].map(o => o.value);
    assert.deepEqual(bopts, ['0', '1', '4663'],
      'from Base the destinations are Ethereum and Robinhood — not Base');
    b.close();
  });

  test('is put away when the tab is left, and forgotten', async () => {
    const p = await setup();
    p.select('sdChain', '8453');
    await p.settle();
    p.click('tabSwap');
    await p.settle();
    assert.equal(p.visible('sdChainL'), false);
    p.click('tabSend');
    await p.settle();
    assert.equal(p.value('sdChain'), '0',
      'a destination that survived the tab would send the next payment to another chain');
    p.close();
  });

  test('says where the money is going before it is sent', async () => {
    const p = await setup();
    await p.typeAmount('amt', '2');
    await recipient(p, A.OTHER);
    p.select('sdChain', '4663');
    await p.settle();
    assert.match(p.text('swap'), /Send 2 ETH → .* on Robinhood/);
    p.close();
  });

  test('refuses anything but ether', async () => {
    const p = await setup();
    p.pickToken('fromSel', 'USDC');
    await p.settle();
    await p.typeAmount('amt', '100');
    await recipient(p, A.OTHER);
    p.select('sdChain', '8453');
    await p.settle();
    assert.match(p.text('stat'), /Only ETH can be sent to another chain/);
    assert.equal(p.disabled('swap'), true, 'a canonical bridge does not carry a USDC balance across');
    p.close();
  });

  // A name is an Ethereum name whichever chain the money lands on: the page
  // resolves it here, against mainnet, and what crosses is the address. Both
  // registries the panel reads are exercised, because a bridged send that
  // resolved to the wrong address cannot be taken back.
  for (const [kind, name, seed] of [
    ['an ENS name', 'alice.eth', c => { c.ensResolver = A.ENSRESOLVER; c.ensNames.set('alice.eth', A.OTHER); }],
    ['a .wei name', 'alice.wei', c => c.names.set('alice.wei', A.OTHER)],
  ]) {
    test(`sends to ${kind} on Base, resolved before it crosses`, async () => {
      const p = await setup(seed);
      const tx = await sendTo(p, { dest: '8453', to: name });
      assert.equal(wordAddr('0x' + tx.data.slice(10), 0).toLowerCase(), A.OTHER.toLowerCase(),
        'the address the name resolved to is what the far side credits');
      p.close();
    });

    test(`sends to ${kind} on Robinhood, locked, with the name kept out of the calldata`, async () => {
      const p = await setup(seed);
      const tx = await sendTo(p, { dest: '4663', delay: '3600', to: name });
      const call = arriveCall(tail(tx.data, 7));
      assert.equal(call.to.toLowerCase(), A.OTHER.toLowerCase());
      assert.equal(call.originHint.toLowerCase(), A.ACCOUNT.toLowerCase());
      p.close();
    });
  }

  test('does not sell a keeper tip for a lock that lands on another chain', async () => {
    const p = await setup();
    p.select('dly', '86400');
    await p.settle();
    assert.equal(p.visible('tipL'), true, 'a mainnet lock is watched by a keeper');
    p.select('sdChain', '8453');
    await p.settle();
    assert.equal(p.visible('tipL'), false,
      'the tip pays a keeper that only watches mainnet; the lock would be on Base');
    p.close();
  });
});

describe('Base — the OP Stack deposit', () => {
  test('an instant send is a portal deposit straight to the recipient', async () => {
    const p = await setup();
    const tx = await sendTo(p, { dest: '8453' });

    assert.equal(tx.to.toLowerCase(), A.OP_PORTAL.toLowerCase(), 'Base\'s own portal');
    assert.equal(selectorOf(tx.data), SEL.OPDEP);
    const body = '0x' + tx.data.slice(10);
    assert.equal(wordAddr(body, 0).toLowerCase(), A.OTHER.toLowerCase(),
      'with no lock there is nothing for SlowArrival to hold');
    assert.equal(word(body, 1), 2n * ETH, 'the deposit mints what it carries');
    assert.equal(word(body, 3), 0n, 'not a contract creation');
    assert.equal(tail(tx.data, 4), '0x', 'a plain send delivers no calldata');
    assert.equal(BigInt(tx.value), 2n * ETH, 'and nothing beyond the amount is spent');
    p.close();
  });

  test('a locked send is the same deposit, aimed at SlowArrival', async () => {
    const p = await setup();
    const tx = await sendTo(p, { dest: '8453', delay: '86400' });

    assert.equal(tx.to.toLowerCase(), A.OP_PORTAL.toLowerCase());
    const body = '0x' + tx.data.slice(10);
    assert.equal(wordAddr(body, 0).toLowerCase(), A.ARRIVAL.toLowerCase(),
      'SLOW would record the portal as the sender; SlowArrival is what keeps the reverse');
    assert.equal(word(body, 1), 2n * ETH);
    assert.equal(BigInt(tx.value), 2n * ETH);

    const call = arriveCall(tail(tx.data, 4));
    assert.equal(call.to.toLowerCase(), A.OTHER.toLowerCase());
    assert.equal(call.delay, 86400n, 'the lock is chosen here and applied there');
    assert.equal(call.originHint.toLowerCase(), A.ACCOUNT.toLowerCase(),
      'the hint is who may reverse it — omit it and the position belongs to nobody');
    assert.equal(call.bounty, 0n,
      'an L1 to L2 message executes itself, so there is no finaliser to pay');
    p.close();
  });

  test('buys more destination gas when the recipient is a contract', async () => {
    const p = await setup(c => c.remotes['base-rpc'].code.set(A.OTHER.toLowerCase(), '0x60006000'));
    const tx = await sendTo(p, { dest: '8453', delay: '3600' });
    assert.equal(word('0x' + tx.data.slice(10), 2), 2_500_000n,
      'a contract recipient runs onERC1155Received on the way in');
    p.close();
  });

  test('costs nothing beyond the amount, and stops saying it does', async () => {
    const p = await setup();
    await p.typeAmount('amt', '2');
    await recipient(p, A.OTHER);
    p.select('sdChain', '4663');
    await p.waitFor(() => p.text('brNote').startsWith('+'), { label: 'a ticket to quote' });
    p.select('sdChain', '8453');
    await p.waitFor(() => p.text('brNote') === '', { label: 'the quote clearing' });
    await p.settle();
    assert.equal(p.text('brNote'), '',
      'an OP deposit buys its destination gas with L1 gas, so nothing extra leaves the wallet');
    p.close();
  });
});

describe('Robinhood — the Arbitrum retryable', () => {
  test('a locked send prepays the ticket and the destination gas', async () => {
    const p = await setup();
    const tx = await sendTo(p, { dest: '4663', delay: '600' });

    assert.equal(tx.to.toLowerCase(), A.ARB_INBOX.toLowerCase());
    assert.equal(selectorOf(tx.data), SEL.RETRY);
    const body = '0x' + tx.data.slice(10);
    assert.equal(wordAddr(body, 0).toLowerCase(), A.ARRIVAL.toLowerCase());
    assert.equal(word(body, 1), 2n * ETH, 'the l2CallValue is what the recipient gets');

    const submission = word(body, 2), gas = word(body, 5), maxFee = word(body, 6);
    assert.equal(submission, 10n ** 14n * 3n / 2n, 'the quoted submission fee, with headroom');
    assert.equal(gas, 800_000n);
    assert.equal(maxFee, 8n * GWEI, 'eight times the destination gas price');
    assert.equal(wordAddr(body, 3).toLowerCase(), A.ACCOUNT.toLowerCase(),
      'unused ticket fees come back to the sender');
    assert.equal(wordAddr(body, 4).toLowerCase(), A.ACCOUNT.toLowerCase());

    assert.equal(BigInt(tx.value), 2n * ETH + submission + gas * maxFee,
      'value = amount + ticket + prepaid destination gas, or the ticket never redeems');

    const call = arriveCall(tail(tx.data, 7));
    assert.equal(call.to.toLowerCase(), A.OTHER.toLowerCase());
    assert.equal(call.delay, 600n);
    assert.equal(call.originHint.toLowerCase(), A.ACCOUNT.toLowerCase(),
      'Nitro aliases every retryable sender, EOAs included — without the hint the reverse is dead');
    p.close();
  });

  test('an instant send carries no calldata and names the recipient', async () => {
    const p = await setup();
    const tx = await sendTo(p, { dest: '4663' });
    const body = '0x' + tx.data.slice(10);
    assert.equal(wordAddr(body, 0).toLowerCase(), A.OTHER.toLowerCase());
    assert.equal(tail(tx.data, 7), '0x');
    assert.equal(word(body, 5), 100_000n, 'a bare transfer needs no room to run');
    p.close();
  });

  test('shows the extra the ticket costs before it is signed', async () => {
    const p = await setup();
    await p.typeAmount('amt', '2');
    await recipient(p, A.OTHER);
    p.select('dly', '600');
    p.select('sdChain', '4663');
    await p.waitFor(() => p.text('brNote').startsWith('+'), { label: 'fee quote' });
    assert.match(p.text('brNote'), /^\+ [\d.]+ ETH gas, unused part refunded there$/);
    p.close();
  });

  test('will not sign a send whose ticket the balance cannot cover', async () => {
    const p = await setup(c => c.setNative(A.ACCOUNT, 2n * ETH));
    await p.typeAmount('amt', '2');
    await recipient(p, A.OTHER);
    p.select('dly', '600');
    p.select('sdChain', '4663');
    await p.waitFor(() => p.disabled('swap'), { label: 'refusal' });
    assert.match(p.text('swap'), /Insufficient ETH for amount \+ destination gas/,
      'the whole amount would leave nothing for the ticket');
    p.close();
  });

  test('refuses rather than guessing when the destination will not quote', async () => {
    const p = await setup(c => { delete c.remotes['robinhood']; c.answer(A.ARB_INBOX, SEL.SUBFEE, '0x'); });
    await p.typeAmount('amt', '2');
    await recipient(p, A.OTHER);
    p.select('dly', '600');
    p.select('sdChain', '4663');
    await p.settle();
    assert.equal(p.disabled('swap'), false, 'the page still offers the send');
    p.click('swap');
    await p.waitFor(() => /could not be quoted/.test(p.text('stat')), { label: 'the refusal' });
    assert.equal(p.chain.sent.length, 0,
      'a ticket priced from a guess sits unredeemable on the far side');
    p.close();
  });
});

/**
 * The far side. SlowArrival is `pt.from` for everything it brought over, so a
 * sender looking for their own transfer in `getOutboundTransfers(account)`
 * finds nothing. The page reads SlowArrival's outbound set instead and keeps
 * the rows `originOf` attributes to the connected account.
 */
describe('a bridged lock, seen from the chain it landed on', () => {
  const DAY = 86400n;

  /** One live arrival on Base, from `origin`, maturing in a day. */
  function arrived(chain, origin = A.ACCOUNT, id = '7') {
    const now = Math.floor(Date.now() / 1000);
    chain.slowArrivalOut = [BigInt(id)];
    chain.arrivalOrigin.set(id, origin);
    chain.slowPending.set(id, {
      timestamp: BigInt(now), id: BigInt(A.ZERO) | (DAY << 160n), amount: ETH,
    });
  }

  async function onBase(prep = () => {}) {
    const chain = new MockChain({ chainId: BASE });
    chain.setNative(A.ACCOUNT, 10n * ETH);
    prep(chain);
    const p = await loadPage({ chain, hash: null });
    await p.connect({ pin: false });
    p.click('tabSend');
    await p.settle();
    return p;
  }
  const btn = (p, label) =>
    [...p.$('pos').querySelectorAll('button')].find(b => b.textContent === label);

  test('appears for the sender even though SLOW says the bridge sent it', async () => {
    const p = await onBase(c => arrived(c));
    await p.waitFor(() => p.$('pos').textContent.includes('Bridged in'), { label: 'arrival row' });
    assert.match(p.$('pos').textContent, /Bridged in · reversible · sends in/);
    assert.ok(btn(p, 'Reverse'), 'the sender kept the reverse across the crossing');
    p.close();
  });

  test('reverses through SlowArrival, which is the only address SLOW will hear', async () => {
    const p = await onBase(c => arrived(c));
    await p.waitFor(() => btn(p, 'Reverse'), { label: 'arrival row' });
    p.click(btn(p, 'Reverse'));
    await p.waitFor(() => p.chain.sent.length > 0, { label: 'reverse tx' });
    await p.settle();

    const tx = p.chain.lastSent;
    assert.equal(tx.to.toLowerCase(), A.ARRIVAL.toLowerCase(),
      'SLOW.reverse from here would revert — the account is not pt.from');
    assert.equal(selectorOf(tx.data), SEL.AREV);
    const body = '0x' + tx.data.slice(10);
    assert.equal(word(body, 0), 7n);
    assert.equal(wordAddr(body, 1).toLowerCase(), A.ACCOUNT.toLowerCase(),
      'the ether comes back here, on this chain');
    p.close();
  });

  test('claws back through SlowArrival once the grace has run', async () => {
    const GRACE = 2592000;
    const p = await onBase(c => {
      arrived(c);
      c.slowPending.set('7', {
        timestamp: BigInt(Math.floor(Date.now() / 1000) - GRACE - 60) - DAY,
        id: BigInt(A.ZERO) | (DAY << 160n), amount: ETH,
      });
    });
    await p.waitFor(() => btn(p, 'Clawback'), { label: 'clawback' });
    p.click(btn(p, 'Clawback'));
    await p.waitFor(() => p.chain.sent.length > 0, { label: 'clawback tx' });
    await p.settle();
    assert.equal(p.chain.lastSent.to.toLowerCase(), A.ARRIVAL.toLowerCase());
    assert.equal(selectorOf(p.chain.lastSent.data), SEL.ACLAW);
    p.close();
  });

  test('leaves someone else\'s arrival alone', async () => {
    const now = Math.floor(Date.now() / 1000);
    const p = await onBase(c => {
      arrived(c, A.OTHER);
      // An ordinary inbound row, so the list is known to have been drawn: the
      // assertion below is about what is missing from it.
      c.slowIn = [9n];
      c.slowPending.set('9', {
        timestamp: BigInt(now), id: BigInt(A.ZERO) | (DAY << 160n), amount: ETH,
      });
    });
    await p.waitFor(() => p.$('pos').textContent.includes('Arrives in'), { label: 'positions' });
    assert.equal(p.$('pos').textContent.includes('Bridged in'), false,
      'originOf is what says whose it is; the outbound set alone says only that it was bridged');
    assert.equal(btn(p, 'Reverse'), undefined);
    p.close();
  });

  // The recipient's half. SlowArrival is only the depositor; `pt.to` is the
  // address named on Ethereum, so on the far side the position is an ordinary
  // SLOW one and settles through SLOW. Routing it through SlowArrival would
  // revert — the recipient is not its origin.
  test('the recipient claims a bridged lock the ordinary way', async () => {
    const now = Math.floor(Date.now() / 1000);
    const p = await onBase(c => {
      c.slowArrivalOut = [7n];
      c.arrivalOrigin.set('7', A.OTHER);   // somebody else sent it
      c.slowIn = [7n];                     // and this account is who it is for
      c.slowPending.set('7', {
        timestamp: BigInt(now) - 2n * DAY, id: BigInt(A.ZERO) | (DAY << 160n), amount: ETH,
      });
    });
    await p.waitFor(() => p.$('pos').textContent.includes('Ready to claim'), { label: 'positions' });
    assert.equal(btn(p, 'Reverse'), undefined, 'the recipient never had the reverse');

    p.click(btn(p, 'Claim'));
    await p.waitFor(() => p.chain.sent.length > 0, { label: 'claim tx' });
    await p.settle();
    const tx = p.chain.lastSent;
    assert.equal(tx.to.toLowerCase(), A.SLOW.toLowerCase(),
      'claim is msg.sender == pt.to, which is this account — SLOW hears it directly');
    assert.equal(selectorOf(tx.data), SEL.CLAIM);
    assert.equal(word('0x' + tx.data.slice(10), 0), 7n);
    p.close();
  });

  test('a guarded recipient unlocks a bridged lock instead', async () => {
    const now = Math.floor(Date.now() / 1000);
    const p = await onBase(c => {
      c.slowGuardian = A.SLOW_GATE;
      c.slowArrivalOut = [7n];
      c.arrivalOrigin.set('7', A.OTHER);
      c.slowIn = [7n];
      c.slowPending.set('7', {
        timestamp: BigInt(now) - 2n * DAY, id: BigInt(A.ZERO) | (DAY << 160n), amount: ETH,
      });
    });
    await p.waitFor(() => btn(p, 'Unlock'), { label: 'positions' });
    p.click(btn(p, 'Unlock'));
    await p.waitFor(() => p.chain.sent.length > 0, { label: 'unlock tx' });
    await p.settle();
    assert.equal(p.chain.lastSent.to.toLowerCase(), A.SLOW.toLowerCase());
    assert.equal(selectorOf(p.chain.lastSent.data), SEL.UNLOCK,
      'claim reverts for a guarded recipient, bridged or not');
    p.close();
  });

  test('a lock sent to yourself is both reversible and claimable, each by the right route', async () => {
    const now = Math.floor(Date.now() / 1000);
    const p = await onBase(c => {
      c.slowArrivalOut = [7n];
      c.arrivalOrigin.set('7', A.ACCOUNT);
      c.slowIn = [7n];
      c.slowPending.set('7', {
        timestamp: BigInt(now), id: BigInt(A.ZERO) | (DAY << 160n), amount: ETH,
      });
    });
    await p.waitFor(() => p.$('pos').textContent.includes('Bridged in'), { label: 'positions' });
    p.click(btn(p, 'Reverse'));
    await p.waitFor(() => p.chain.sent.length > 0, { label: 'reverse tx' });
    await p.settle();
    assert.equal(p.chain.lastSent.to.toLowerCase(), A.ARRIVAL.toLowerCase(),
      'while it is still locked the origin takes it back, and that goes through SlowArrival');
    p.close();
  });

  test('offers back ether that arrived but could not be locked', async () => {
    const p = await onBase(c => { c.arrivalRescue = ETH / 2n; });
    await p.waitFor(() => p.$('pos').textContent.includes('could not be locked'),
      { label: 'rescue row' });
    assert.match(p.$('pos').textContent, /0\.5 ETH/);

    p.click(btn(p, 'Recover'));
    await p.waitFor(() => p.chain.sent.length > 0, { label: 'rescue tx' });
    await p.settle();
    const tx = p.chain.lastSent;
    assert.equal(tx.to.toLowerCase(), A.ARRIVAL.toLowerCase());
    assert.equal(selectorOf(tx.data), SEL.ACLAIMR,
      'arrive() never reverts — a failed deposit is held, not lost');
    assert.equal(wordAddr('0x' + tx.data.slice(10), 0).toLowerCase(), A.ACCOUNT.toLowerCase());
    p.close();
  });
});

/**
 * Leaving an L2. There is no canonical way down that does not take six days,
 * so the page opens a SlowRelay escrow instead: the sender's funds stay on the
 * chain they started on, a relayer fronts the far leg from its own inventory,
 * and the escrow pays that relayer only against a canonical proof of fill. The
 * sender's exits are unconditional — cancel if nobody delivers, reverse on the
 * far side if somebody did.
 *
 * What these pin is the escrow itself. An intent is 11 static words and the
 * WHOLE struct is the id, so a single wrong word is an escrow that no relayer
 * can fill and that `cancel` cannot address either, because `cancel` re-derives
 * the same id from the same words.
 */
describe('leaving an L2 through the relay', () => {
  const GRACE = 8 * 86400;

  async function open(p, { dest = '1', amount = '2', delay = '3600' } = {}) {
    await p.typeAmount('amt', amount);
    await recipient(p, A.OTHER);
    p.select('dly', delay);
    p.select('sdChain', dest);
    await p.settle();
    await p.waitFor(() => !p.disabled('swap'), { label: 'a send the page will make' });
    p.click('swap');
    await p.waitFor(() => p.chain.sent.length > 0, { label: 'open tx' });
    await p.settle();
    return p.chain.lastSent;
  }

  test('escrows on the chain it is leaving, naming both legs', async () => {
    const p = await onBaseSend();
    const tx = await open(p);

    assert.equal(tx.to.toLowerCase(), A.RELAY.toLowerCase(),
      'the money stays here, in the escrow — it never enters a bridge');
    const i = intentOf(tx.data);

    assert.equal(i.sender.toLowerCase(), A.ACCOUNT.toLowerCase());
    assert.equal(i.recipient.toLowerCase(), A.OTHER.toLowerCase());
    assert.equal(i.amount, 2n * ETH);
    assert.equal(i.fee, expectFee(2n * ETH, 1), 'a rate, floored by one mainnet transaction');
    assert.equal(BigInt(tx.value), i.amount + i.fee, 'the escrow holds the fee too');
    assert.equal(i.delay, 3600n, 'the timelock is passed to the far side unchanged');
    assert.equal(i.srcChainId, 8453n);
    assert.equal(i.dstChainId, 1n);
    assert.notEqual(i.nonce, 0n, 'identical terms must still be distinct intents');

    // Both legs are named. One `token` field would let a relayer deliver
    // whatever sits at that address on the other chain and collect the escrow.
    assert.equal(i.srcToken, A.ZERO);
    assert.equal(i.dstToken, A.ZERO);
    p.close();
  });

  test('the fill window is real and bounded', async () => {
    const p = await onBaseSend();
    const i = intentOf((await open(p)).data);
    const now = BigInt(Math.floor(Date.now() / 1000));
    assert.ok(i.fillDeadline > now, 'an already-passed deadline is refused at open');
    assert.ok(i.fillDeadline <= now + 30n * 86400n,
      'past the contract ceiling the escrow would have no refund at all, ever');
    p.close();
  });

  test('reaches the other L2 as readily as it reaches Ethereum', async () => {
    const p = await onBaseSend();
    const i = intentOf((await open(p, { dest: '4663' })).data);
    assert.equal(i.srcChainId, 8453n);
    assert.equal(i.dstChainId, 4663n, 'Base to Robinhood is one escrow, not two withdrawals');
    p.close();
  });

  // The fee has to cover the CANONICAL LATENCY OF THE RETURN LEG, because that
  // is how long the relayer's own money is locked. The proof travels
  // destination -> source, so where the FILL lands decides it: a fill on
  // Ethereum is repaid by one L1->L2 message in minutes, while a fill on an L2
  // has to withdraw - six to seven days - before the hop back down. Pricing
  // both the same either overpays the fast leg or leaves the slow one unfilled,
  // and an unfilled escrow is eight days of the sender's money going nowhere.
  test('costs more to the other L2 than to Ethereum, because the relayer waits longer', async () => {
    const toL1 = await onBaseSend();
    const a = intentOf((await open(toL1, { dest: '1', amount: '5' })).data);
    toL1.close();

    const toL2 = await onBaseSend();
    const b = intentOf((await open(toL2, { dest: '4663', amount: '5' })).data);
    toL2.close();

    assert.equal(a.amount, b.amount, 'same size, so the fees are comparable');
    assert.ok(b.fee > a.fee,
      'a week of locked inventory cannot be priced like a few minutes of it');
    assert.equal(a.fee, expectFee(5n * ETH, 1));
    assert.equal(b.fee, expectFee(5n * ETH, 4663));
  });

  // A rate cannot price a cost that is a fixed mainnet transaction. Every route
  // needs at least one L1 tx to repay the relayer, so on a small send the flat
  // component IS the price — a proportional-only fee offers pennies against
  // hundreds of thousands of gas and the escrow is simply never filled.
  test('a small send is priced by mainnet gas, not by a percentage', async () => {
    const p = await onBaseSend();
    const i = intentOf((await open(p, { dest: '1', amount: '0.05' })).data);
    const rate = 5n * ETH / 100n * 2n / 10000n;
    assert.ok(i.fee > rate * 10n, 'a rate here would offer a relayer a few cents');
    assert.equal(i.fee, L1_GWEI * 600000n, 'the floor is one mainnet transaction');
    p.close();
  });

  test('refuses to quote at all when mainnet gas reads as zero', async () => {
    const p = await onChainSend(BASE, c => {
      const l1 = new MockChain({ chainId: '0x1', gasPrice: 0n });
      c.remotes['ethereum-rpc'] = l1; c.remotes['blastapi'] = l1;
    }, RELAY_ON);
    await p.typeAmount('amt', '2');
    await recipient(p, A.OTHER);
    p.select('sdChain', '1');
    await p.settle();
    await p.waitFor(() => !p.disabled('swap'), { label: 'ready' });
    p.click('swap');
    await p.settle();
    assert.equal(p.chain.sent.length, 0,
      'quoting the fee off a zero gas price would escrow against a fee of zero');
    p.close();
  });

  test('an instant send across is the same escrow with no timelock', async () => {
    const p = await onBaseSend();
    const i = intentOf((await open(p, { delay: '0' })).data);
    assert.equal(i.delay, 0n);
    p.close();
  });

  test('refuses to escrow a token, because only ETH is quoted', async () => {
    const p = await onBaseSend(c => c.setErc20(A.USDC, A.ACCOUNT, 5_000n * 10n ** 6n));
    p.pickToken('fromSel', 'USDC');
    p.select('sdChain', '1');
    await p.typeAmount('amt', '100');
    await recipient(p, A.OTHER);
    await p.settle();
    assert.equal(p.disabled('swap'), true);
    assert.match(p.text('stat'), /Only ETH can be sent to another chain/);
    p.close();
  });
});

/**
 * The escrow, seen by the sender afterwards. It is the sender's own money
 * sitting on their own chain, so the page has to show it and has to offer the
 * way out. An escrow a UI cannot cancel is worse than no UI.
 */
describe('an open escrow', () => {
  const GRACE = 8 * 86400;
  const NONCE = '12345678901234567890';

  /** One intent in this browser's store, as `open` left it, plus its id. */
  function stored({ dl, dc = '1', a = String(ETH) } = {}) {
    const i = {
      s: A.ACCOUNT, r: A.OTHER, st: A.ZERO, dt: A.ZERO,
      a, f: String(BigInt(a) / 1000n), d: '3600',
      sc: '8453', dc, dl: String(dl), n: NONCE,
    };
    return { json: JSON.stringify([i]), id: relayIntentId(i) };
  }
  const rows = p => p.$('pos').textContent;
  const btn = (p, label) =>
    [...p.$('pos').querySelectorAll('button')].find(b => b.textContent === label);

  test('shows what is waiting, and says when it can be taken back', async () => {
    const dl = Math.floor(Date.now() / 1000) + 3600;
    const e = stored({ dl });
    const p = await onBaseSend(c => { c.relayStatus.set(e.id, 1); }, { 'zswap:rl:8453': e.json });
    await p.waitFor(() => rows(p).includes('Escrowed for'), { label: 'escrow row' });
    assert.match(rows(p), /Escrowed for Ethereum · refundable/);
    assert.equal(btn(p, 'Take back'), undefined,
      'refunding before a fill can prove itself would take the relayer\'s money');
    p.close();
  });

  test('offers it back once nobody has delivered', async () => {
    const dl = Math.floor(Date.now() / 1000) - GRACE - 60;
    const e = stored({ dl });
    const p = await onBaseSend(c => { c.relayStatus.set(e.id, 1); }, { 'zswap:rl:8453': e.json });
    await p.waitFor(() => btn(p, 'Take back'), { label: 'take back' });
    assert.match(rows(p), /Nobody delivered it/);

    p.click(btn(p, 'Take back'));
    await p.waitFor(() => p.chain.sent.length > 0, { label: 'cancel tx' });
    await p.settle();
    const tx = p.chain.lastSent;
    assert.equal(tx.to.toLowerCase(), A.RELAY.toLowerCase());
    assert.equal(selectorOf(tx.data), SEL.RCANCEL);
    // cancel re-derives the id from the words it is given, so they have to be
    // the words the escrow was opened with - to the last one.
    assert.equal(word('0x' + tx.data.slice(10), 10).toString(), NONCE,
      'a cancel built from anything but the stored intent addresses nothing');
    p.close();
  });

  // `filledBy` is written by `fill` on the DESTINATION chain and `provenBy` on
  // the SOURCE chain when the proof lands, days later. Reading the wrong one
  // here shows an escrow as unfilled and offers a Take back that either reverts
  // or - worse - looks available for the whole week the proof is in flight.
  test('a delivery is seen on the destination while the proof is still crossing', async () => {
    const dl = Math.floor(Date.now() / 1000) - GRACE - 60;
    const e = stored({ dl });
    const l1 = new MockChain({ chainId: '0x1' });
    l1.relayFilledBy.set(e.id, A.OTHER);          // filled over there
    const p = await onBaseSend(c => {
      c.relayStatus.set(e.id, 1);                 // still OPEN here
      c.remotes['ethereum-rpc'] = l1;
      c.remotes['blastapi'] = l1;
    }, { 'zswap:rl:8453': e.json });

    await p.waitFor(() => rows(p).includes('proof is still crossing'), { label: 'filled row' });
    assert.match(rows(p), /Delivered on Ethereum · the proof is still crossing/);
    assert.equal(btn(p, 'Take back'), undefined,
      'refunding now would take the money of a relayer who already delivered');
    p.close();
  });

  test('and on the source chain once the proof has landed', async () => {
    const dl = Math.floor(Date.now() / 1000) - GRACE - 60;
    const e = stored({ dl });
    const p = await onBaseSend(c => {
      c.relayStatus.set(e.id, 1);
      c.relayProvenBy.set(e.id, A.OTHER);
    }, { 'zswap:rl:8453': e.json });
    await p.waitFor(() => rows(p).includes('paying the relayer'), { label: 'proven row' });
    assert.equal(btn(p, 'Take back'), undefined, 'cancel reverts once provenBy is set');
    p.close();
  });

  // Taking an escrow back names every term it was opened with, so the browser
  // record is load-bearing: lose it and the money is unreachable until someone
  // reconstructs eleven words exactly. `Opened` carries all of them, and its
  // sender is indexed, so the page can read them back.
  test('finds an escrow again when the browser has forgotten it', async () => {
    const dl = Math.floor(Date.now() / 1000) - GRACE - 60;
    const e = stored({ dl });
    const i = JSON.parse(e.json)[0];
    const w = v => BigInt(v).toString(16).padStart(64, '0');
    const p = await onBaseSend(c => {
      c.relayStatus.set(e.id, 1);
      c.logs.push({
        address: A.RELAY,
        topics: [SEL.OPENED, e.id, '0x' + w(BigInt(A.ACCOUNT))],
        // slowId, then the Intent's eleven static words, encoded inline.
        data: '0x' + w(0) + w(i.s) + w(i.r) + w(i.st) + w(i.dt) + w(i.a) + w(i.f)
          + w(i.d) + w(i.sc) + w(i.dc) + w(i.dl) + w(i.n),
        blockNumber: '0x1', logIndex: '0x0',
      });
    }); // no storage at all — a cleared browser, or another device

    await p.waitFor(() => btn(p, 'Take back'), { label: 'recovered escrow' });
    p.click(btn(p, 'Take back'));
    await p.waitFor(() => p.chain.sent.length > 0, { label: 'cancel tx' });
    await p.settle();
    assert.equal(selectorOf(p.chain.lastSent.data), SEL.RCANCEL);
    assert.equal(word('0x' + p.chain.lastSent.data.slice(10), 10).toString(), NONCE,
      'the terms came back off the chain intact, or cancel addresses nothing');
    p.close();
  });

  test('will not adopt a log whose words do not hash to the id it claims', async () => {
    const dl = Math.floor(Date.now() / 1000) - GRACE - 60;
    const e = stored({ dl });
    const i = JSON.parse(e.json)[0];
    const w = v => BigInt(v).toString(16).padStart(64, '0');
    const p = await onBaseSend(c => {
      c.relayStatus.set(e.id, 1);
      c.logs.push({
        address: A.RELAY,
        topics: [SEL.OPENED, e.id, '0x' + w(BigInt(A.ACCOUNT))],
        // The amount is inflated: a log an impostor contract could emit.
        data: '0x' + w(0) + w(i.s) + w(i.r) + w(i.st) + w(i.dt) + w(BigInt(i.a) * 9n) + w(i.f)
          + w(i.d) + w(i.sc) + w(i.dc) + w(i.dl) + w(i.n),
        blockNumber: '0x1', logIndex: '0x0',
      });
    });
    await p.settle();
    assert.equal(rows(p).includes('Escrowed for'), false,
      'the id is keccak of the whole struct — a mismatch means these are not its terms');
    p.close();
  });

  test('a settled escrow stops being shown at all', async () => {
    const dl = Math.floor(Date.now() / 1000) - GRACE - 60;
    const e = stored({ dl });
    const p = await onBaseSend(c => { c.relayStatus.set(e.id, 2); }, { 'zswap:rl:8453': e.json });
    await p.settle();
    assert.equal(rows(p).includes('Escrowed for'), false, 'RELEASED is finished business');
    p.close();
  });
});

/**
 * The far leg. A relayed fill and a bridged arrival look identical in SLOW -
 * both are a position whose `from` is a contract - but the right to reverse
 * lives in a DIFFERENT contract for each. The page reads each row's own holder.
 */
describe('a relayed fill, seen on the chain it landed on', () => {
  const DAY = 86400n;

  test('the sender reverses it through SlowRelay, not through SlowArrival', async () => {
    const now = Math.floor(Date.now() / 1000);
    const p = await onChainSend(BASE, c => {
      c.slowRelayOut = [9n];
      c.relayOrigin.set('9', A.ACCOUNT);
      c.slowPending.set('9', {
        timestamp: BigInt(now), id: BigInt(A.ZERO) | (DAY << 160n), amount: ETH,
      });
    });
    await p.waitFor(() => p.$('pos').textContent.includes('Bridged in'), { label: 'fill row' });
    const b = [...p.$('pos').querySelectorAll('button')].find(x => x.textContent === 'Reverse');
    p.click(b);
    await p.waitFor(() => p.chain.sent.length > 0, { label: 'reverse tx' });
    await p.settle();
    assert.equal(p.chain.lastSent.to.toLowerCase(), A.RELAY.toLowerCase(),
      'SlowArrival holds no origin for this transfer and would revert NotOrigin');
    assert.equal(selectorOf(p.chain.lastSent.data), SEL.AREV,
      'the two contracts share the selector; only the address tells them apart');
    p.close();
  });

  test('two rows from two holders each go to their own', async () => {
    const now = Math.floor(Date.now() / 1000);
    const pend = { timestamp: BigInt(now), id: BigInt(A.ZERO) | (DAY << 160n), amount: ETH };
    const p = await onChainSend(BASE, c => {
      c.slowArrivalOut = [7n];
      c.arrivalOrigin.set('7', A.ACCOUNT);
      c.slowRelayOut = [9n];
      c.relayOrigin.set('9', A.ACCOUNT);
      c.slowPending.set('7', pend);
      c.slowPending.set('9', pend);
    });
    await p.waitFor(() => [...p.$('pos').querySelectorAll('button')]
      .filter(x => x.textContent === 'Reverse').length === 2, { label: 'both rows' });

    const seen = new Set();
    for (const b of [...p.$('pos').querySelectorAll('button')].filter(x => x.textContent === 'Reverse')) {
      seen.add(b.dataset.v.toLowerCase());
    }
    assert.deepEqual([...seen].sort(), [A.RELAY.toLowerCase(), A.ARRIVAL.toLowerCase()].sort(),
      'each row carries the contract that actually holds its reverse');
    p.close();
  });
});

/**
 * What the page refuses to do, and why each refusal is load-bearing.
 *
 * `SlowArrival._push` will not hop a CONTRACT origin onward, and its comment
 * asserts that the page "refuses this route over outright". It has to: Nitro
 * rewrites BOTH retryable refund addresses to `alias(sender)` when the sender
 * holds code, and `callValueRefundAddress` is the ticket's beneficiary — the
 * only address that can cancel it and the one that receives the whole payload
 * if it is never redeemed. `alias(a Safe)` is reachable by nobody.
 */
describe('the refusals', () => {
  const withCode = (chain, addr, code = '0x60006000fd') =>
    chain.code.set(addr.toLowerCase(), code);

  async function tryToSend(p, { dest = '8453', to = A.OTHER, delay = '0' } = {}) {
    await p.typeAmount('amt', '1');
    await recipient(p, to);
    p.select('dly', delay);
    p.select('sdChain', dest);
    await p.settle();
    await p.waitFor(() => !p.disabled('swap'), { label: 'ready' });
    p.click('swap');
    await p.settle();
    return p.chain.sent.length;
  }

  for (const [name, dest] of [['Base', '8453'], ['Robinhood', '4663']]) {
    test(`will not bridge to ${name} from a contract wallet`, async () => {
      const p = await setup(c => withCode(c, A.ACCOUNT));
      assert.equal(await tryToSend(p, { dest }), 0, 'nothing may be signed');
      assert.match(p.text('stat'), /contract/i);
      p.close();
    });
  }

  // The same refusal has to cover the relay lane, and for a different reason.
  // `originOf` gates reverse/clawback on address equality ACROSS chains, so a
  // sender that holds code can be impersonated on the destination by replaying
  // its initcode and salt through a permissionless CREATE2 factory — the
  // impostor then reverses the recipient's leg inside the timelock. The relayer
  // is still paid; the loss is entirely the sender's. So it is a refusal, not a
  // warning, and it must sit ahead of BOTH lanes.
  test('will not open a relay escrow from a contract wallet either', async () => {
    const p = await onBaseSend(c => withCode(c, A.ACCOUNT));
    assert.equal(await tryToSend(p, { dest: '1' }), 0);
    assert.match(p.text('stat'), /contract/i);
    p.close();
  });

  // An EIP-7702-delegated tx.origin can push `arrive`'s failure tail past its
  // 60,000-gas reserve, and the OP portal marks a withdrawal finalized before
  // calling and never replays it — so a non-zero bounty is ETH destroyed, not
  // stranded. The page has no reason to offer one: an L1->L2 message executes
  // itself, so there is no finaliser to pay.
  test('never offers a bounty on a deposit that executes itself', async () => {
    const p = await setup();
    for (const dest of ['8453', '4663']) {
      const tx = await sendTo(p, { dest, delay: '3600' });
      const call = arriveCall(tail(tx.data, dest === '8453' ? 4 : 7));
      assert.equal(call.bounty, 0n, 'nobody finalises an L1->L2 message; a bounty only burns');
      p.chain.sent.length = 0;
    }
    p.close();
  });

  // An EIP-7702 account holds a delegation designator, not contract code: the
  // OP portal does not alias it and nobody can deploy an impostor at a
  // key-derived address. Robinhood's Inbox still aliases any sender with code.
  const D7702 = '0xef0100' + '11'.repeat(20);
  test('bridges to Base from a 7702-delegated account', async () => {
    const p = await setup(c => withCode(c, A.ACCOUNT, D7702));
    assert.equal(await tryToSend(p, { dest: '8453' }), 1);
    p.close();
  });

  test('but not to Robinhood, whose Inbox aliases it', async () => {
    const p = await setup(c => withCode(c, A.ACCOUNT, D7702));
    assert.equal(await tryToSend(p, { dest: '4663' }), 0);
    assert.match(p.text('stat'), /contract/i);
    p.close();
  });

  test('and opens a relay escrow from one', async () => {
    const p = await onBaseSend(c => withCode(c, A.ACCOUNT, D7702));
    assert.equal(await tryToSend(p, { dest: '1' }), 1);
    p.close();
  });

  test('still bridges normally from an ordinary account', async () => {
    const p = await setup();
    assert.equal(await tryToSend(p, { dest: '8453' }), 1);
    p.close();
  });

  // A codeless answer that is not well-formed hex must read as "has code":
  // guessing "no code" picks the small gas limit, and a deposit that runs out
  // of gas on the far side is minted to the sender's address there.
  test('treats a malformed eth_getCode answer as code, not as absence', async () => {
    const p = await setup(c => { c.remotes['base-rpc'].codeRaw = null; });
    await p.typeAmount('amt', '1');
    await recipient(p, A.OTHER);
    p.select('dly', '3600');
    p.select('sdChain', '8453');
    await p.settle();
    await p.waitFor(() => !p.disabled('swap'), { label: 'ready' });
    p.click('swap');
    await p.waitFor(() => p.chain.sent.length > 0, { label: 'tx' });
    await p.settle();
    const b = '0x' + p.chain.lastSent.data.slice(10);
    assert.equal(word(b, 2), 2500000n,
      'an unreadable answer must buy the larger gas budget, not the smaller');
    p.close();
  });

  for (const [name, addr] of [['SlowArrival', A.ARRIVAL], ['SlowRelay', A.RELAY], ['SLOW', A.SLOW]]) {
    test(`will not send to ${name} itself`, async () => {
      const p = await setup();
      assert.equal(await tryToSend(p, { to: addr }), 0);
      assert.match(p.text('stat'), /bridge itself/i);
      p.close();
    });
  }
});

/**
 * The pending list is the only route to Claim, Reverse, Clawback and the
 * escrow's Take back. A read failure must cost the rows it could not read, not
 * the panel.
 */
describe('the list survives bad data', () => {
  test('a multicall that gives up does not blank the whole panel', async () => {
    const now = Math.floor(Date.now() / 1000);
    const dl = now - 8 * 86400 - 60;
    const e = { s: A.ACCOUNT, r: A.OTHER, st: A.ZERO, dt: A.ZERO, a: String(ETH),
      f: '1000', d: '3600', sc: '8453', dc: '1', dl: String(dl), n: '77', o: 1 };
    const p = await onBaseSend(c => {
      c.failCallsTo.add(A.RELAY.toLowerCase()); // only the escrow reads come back null
      c.slowIn = [4n];
      c.slowPending.set('4', {
        timestamp: BigInt(now) - 2n * 86400n,
        id: BigInt(A.ZERO) | (86400n << 160n), amount: ETH,
      });
    }, { 'zswap:rl:8453': JSON.stringify([e]) });

    await p.waitFor(() => p.$('pos').textContent.includes('claim'), { label: 'the other rows' });
    assert.match(p.$('pos').textContent, /Ready to claim/,
      'an unreadable escrow must not take the claimable SLOW position down with it');
    p.close();
  });

  test('a corrupted stored escrow is dropped, not thrown on', async () => {
    const now = Math.floor(Date.now() / 1000);
    const p = await onBaseSend(c => {
      c.slowIn = [4n];
      c.slowPending.set('4', {
        timestamp: BigInt(now) - 2n * 86400n,
        id: BigInt(A.ZERO) | (86400n << 160n), amount: ETH,
      });
    }, { 'zswap:rl:8453': JSON.stringify([{ s: A.ACCOUNT, r: 'notanaddress', a: 'x' }]) });

    await p.waitFor(() => p.$('pos').textContent.includes('claim'), { label: 'the other rows' });
    assert.match(p.$('pos').textContent, /Ready to claim/);
    p.close();
  });

  test('refuses the send when the browser will not keep the terms', async () => {
    const p = await onBaseSendBrokenStorage();
    await p.typeAmount('amt', '1');
    await recipient(p, A.OTHER);
    p.select('sdChain', '1');
    await p.settle();
    await p.waitFor(() => !p.disabled('swap'), { label: 'ready' });
    p.click('swap');
    await p.settle();
    assert.equal(p.chain.sent.length, 0,
      'an escrow whose terms were never written is one that cannot be taken back');
    assert.match(p.text('stat'), /storage|private browsing/i);
    p.close();
  });
});

/**
 * The store the page falls back to when `localStorage` cannot even be reached
 * — a blocked origin, some in-wallet browsers. The page keeps a plain object
 * instead, so every write "succeeds" and every read inside the session works.
 * Reading back what you just wrote therefore proves nothing; the escrow's terms
 * are gone the moment the tab is closed.
 */
describe('a store that only looks like one', () => {
  test('refuses the send when localStorage is unreachable', async () => {
    const chain = new MockChain({ chainId: BASE });
    chain.setNative(A.ACCOUNT, 10n * ETH);
    const l1 = new MockChain({ chainId: '0x1', gasPrice: L1_GWEI });
    chain.remotes['ethereum-rpc'] = l1;
    chain.remotes['blastapi'] = l1;
    const p = await loadPage({
      chain, hash: null, storage: RELAY_ON,
      patch: [['try{LS=localStorage||{}}catch{LS={}}', 'LS={"zswap:relay":"1"}']],
    });
    await p.connect({ pin: false });
    p.click('tabSend');
    await p.settle();

    await p.typeAmount('amt', '1');
    await recipient(p, A.OTHER);
    p.select('sdChain', '1');
    await p.settle();
    await p.waitFor(() => !p.disabled('swap'), { label: 'ready' });
    p.click('swap');
    await p.settle();
    assert.equal(p.chain.sent.length, 0,
      'a record that dies with the tab is not a record the escrow can rely on');
    p.close();
  });
});

/**
 * The switch the page itself does not hold.
 *
 * A per-browser opt-in is one-directional: a viewer who enabled a lane keeps
 * it, and an immutable page has no way to take the offer back if the contract
 * behind it turns out to be broken. `zSwapFlags` is that missing direction —
 * one mainnet read, keyed by the chain the user is ON, answering: on for
 * everyone, off for everyone, or left to the viewer.
 *
 * OFF is the state that could not be expressed any other way, so it is the one
 * these tests are most careful about: it has to beat an opt-in already made,
 * and it has to survive a read that fails afterwards.
 */
describe('the on-chain switch', () => {
  const flagged = (v, storage = {}) =>
    onChainSend(BASE, c => { if (v !== undefined) c.bridgeFlag.set('8453', v); }, storage);

  test('unset leaves the choice to the viewer, which is not the same as off', async () => {
    const p = await flagged(0);
    assert.equal(p.visible('rlOptL'), true, 'the door is still there');
    assert.equal(p.visible('sdChainL'), false);
    p.close();
  });

  test('on opens the lane for everyone, with no opt-in to find', async () => {
    const p = await flagged(1);
    await p.waitFor(() => p.visible('sdChainL'), { label: 'the lane' });
    assert.equal(p.visible('rlOptL'), false, 'nobody needs to be told to enable it');
    assert.deepEqual([...p.$('sdChain').options].map(o => o.value), ['0', '1', '4663']);
    p.close();
  });

  test('off withdraws the lane from a viewer who had already opted in', async () => {
    const p = await flagged(2, RELAY_ON);
    await p.waitFor(() => !p.visible('sdChainL'), { label: 'the lane closing' });
    assert.equal(p.visible('rlOptL'), false,
      'and does not offer the door back, which would be a lane you could re-open');
    p.close();
  });

  test('off is remembered, so a failed read cannot re-open the lane', async () => {
    const first = await flagged(2, RELAY_ON);
    await first.waitFor(() => !first.visible('sdChainL'), { label: 'off' });
    const kept = first.window.localStorage.getItem('zswap:flag:8453');
    first.close();
    assert.equal(kept, '2', 'the decision is cached');

    // Now the flag read fails entirely — a hostile or simply broken node.
    const p = await onChainSend(BASE, c => { c.failCallsTo.add(A.FLAGS.toLowerCase()); },
      { ...RELAY_ON, 'zswap:flag:8453': '2' });
    await p.settle();
    assert.equal(p.visible('sdChainL'), false,
      'a node that refuses to answer must not be able to undo a withdrawal');
    p.close();
  });

  test('mainnet is unaffected by an L2 flag — its bridges need no relayer', async () => {
    const chain = new MockChain();
    chain.setNative(A.ACCOUNT, 10n * ETH);
    chain.bridgeFlag.set('8453', 2);
    chain.remotes['base-rpc'] = new MockChain({ chainId: BASE });
    chain.remotes['base.org'] = chain.remotes['base-rpc'];
    chain.remotes['robinhood'] = new MockChain({ chainId: RH });
    const p = await loadPage({ chain });
    await p.connect();
    p.click('tabSend');
    await p.settle();
    assert.equal(p.visible('sdChainL'), true, 'the flag is keyed by the chain you are on');
    p.close();
  });

  test('a lane closed after a destination was picked does not send here instead', async () => {
    const p = await setup(c => c.failCallsTo.add(A.FLAGS.toLowerCase()));
    await p.typeAmount('amt', '1');
    await recipient(p, A.OTHER);
    p.select('sdChain', '8453');
    await p.settle();
    await p.waitFor(() => /on Base/.test(p.text('swap')), { label: 'on Base' });
    p.chain.failCallsTo.clear();
    p.chain.bridgeFlag.set('1', 2);
    await p.window.eval('brFlagSync()');
    await p.settle();
    assert.doesNotMatch(p.text('swap'), /on Base/, 'the button follows the closed lane');
    p.click('swap');
    await p.settle();
    assert.equal(p.chain.sent.length, 0, 'a plain transfer on Ethereum is not what was asked for');
    assert.match(p.text('stat'), /destination changed/);
    p.close();
  });

  test('and mainnet can be closed too, if its own lane ever needs withdrawing', async () => {
    const chain = new MockChain();
    chain.setNative(A.ACCOUNT, 10n * ETH);
    chain.bridgeFlag.set('1', 2);
    const p = await loadPage({ chain });
    await p.connect();
    p.click('tabSend');
    await p.settle();
    await p.waitFor(() => !p.visible('sdChainL'), { label: 'mainnet lane closing' });
    assert.equal(p.visible('rlOptL'), false);
    p.close();
  });
});
