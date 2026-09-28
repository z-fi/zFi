// Private ether in one place. On Ethereum the private panel leads with the Tacit pool for ether (proved on this
// device, for simple payments) and keeps V1 one tap away (tETH notes for Bitcoin and DeFi); the choice is kept.
// The pool's deposit, send and withdraw go through the panel's own buttons and the Private ETH menu alike.
import { test, describe, after } from 'node:test';
import assert from 'node:assert/strict';
import { A, MockChain, loadPage, closeAllPages } from './harness.mjs';
import { FAKE_POOL } from './tacit-fake-pool.mjs';

after(closeAllPages);

const ROUTER = '0x0000006c96afa6f1cd4df8fe19bc0d8b6a6cd7b5';
const BOX = '0x52fc37ee7741468a15ce879320a7a41cebaeb232';
const KEY = '0x' + '11'.repeat(32);
const word = x => BigInt(x).toString(16).padStart(64, '0');

async function open(id = 1, storage = { 'zswap:pvin': '' }) {
  const chain = new MockChain({ chainId: '0x' + id.toString(16) });
  chain.code.set(ROUTER, '0x5f5ff3');
  chain.answers.set(`${ROUTER}:7944b37a`, '0x' + word(BOX));
  chain.lanes = { 'tacit-evm-pool-keeper': 404 };
  const p = await loadPage({ chain, storage });
  await p.connect({ pin: false });
  await p.settle();
  p.window.eval(`cpUse(${JSON.stringify(KEY)})`);
  p.window.eval(FAKE_POOL);
  return p;
}
const calls = p => JSON.parse(p.window.eval('JSON.stringify(twW.calls)'));
const shown = (p, id) => !p.$(id).classList.contains('hide');
const row = (p, name) => [...p.$('wkList').querySelectorAll('button.tkr')].find(b => b.textContent.startsWith(name));
const okIn = p => [...p.$('wkList').querySelectorAll('button')].find(b => b.textContent === 'OK');
async function answer(p, text) {
  await p.waitFor(() => okIn(p) && p.$('wkList').querySelector('textarea'), { label: 'a prompt' });
  p.$('wkList').querySelector('textarea').value = text;
  p.click(okIn(p));
  await p.settle();
}

describe('ether in the private panel on Ethereum', () => {
  test('leads with the pool for payments, keeps V1 one tap away, and remembers the choice', async () => {
    const p = await open();
    p.click('pv');
    await p.settle();
    assert.ok(shown(p, 'pvInL'), 'ether offers the choice');
    assert.equal(p.value('pvIn'), 'p', 'a first visit leads with the pool');
    assert.match(p.text('pvHint'), /Deposit ETH into the Tacit pool, proved on this device with no relay\. It earns TAC points/);
    assert.ok(p.$('pvPath').parentElement.classList.contains('hide'), 'V1\'s relay settle choice stands down');
    p.select('pvIn', 'v');
    await p.settle();
    assert.equal(p.window.localStorage.getItem('zswap:pvin'), 'v');
    assert.match(p.text('pvHint'), /tETH/, 'V1 deposits ether as tETH notes');
    assert.ok(!p.$('pvPath').parentElement.classList.contains('hide'), 'and its relay choice is back');
    p.close();
    const q = await open(1, { 'zswap:pvin': 'v' });
    q.click('pv');
    await q.settle();
    assert.equal(q.value('pvIn'), 'v', 'the choice is kept across visits');
    q.close();
  });

  test('the pool deposits, sends to a bp1 address, and withdraws through the panel\'s own buttons', async () => {
    const p = await open();
    p.click('pv');
    await p.settle();
    p.type('pvAmt', '0.1');
    p.click('pvGo');
    await p.waitFor(() => /Sent: 0xdep/.test(p.text('stat')), { label: 'the deposit' });
    p.select('pvAct', 'send');
    p.type('pvRc', 'tacit1qqqq');
    p.click('pvGo');
    await p.waitFor(() => /goes to a bp1… Tacit address/.test(p.text('stat')), { label: 'a V1 address refused for a pool payment' });
    p.type('pvRc', 'bp1qfriend');
    p.click('pvGo');
    await p.waitFor(() => /Sent: 0xsend/.test(p.text('stat')), { label: 'the pool payment' });
    p.select('pvAct', 'out');
    p.type('pvTo', A.OTHER);
    p.click('pvGo');
    await p.waitFor(() => /Sent: 0xwd/.test(p.text('stat')), { label: 'the withdrawal' });
    assert.deepEqual(calls(p), [
      ['deposit', '100000000000000000'],
      ['send', 'bp1qfriend', '100000000000000000', 'keeper'],
      ['withdraw', A.OTHER, '100000000000000000', 'keeper'],
    ]);
    p.close();
  });

  test('a bp1 address pasted while V1 is chosen switches ether to the pool', async () => {
    const p = await open(1, { 'zswap:pvin': 'v' });
    p.click('pv');
    await p.settle();
    p.select('pvAct', 'send');
    p.type('pvRc', 'bp1qfriend');
    await p.settle();
    assert.equal(p.value('pvIn'), 'p');
    assert.match(p.text('pvHint'), /Pay a bp1… Tacit pool address privately/);
    p.close();
  });

  test('when the keeper refuses a payment, it is sent from this wallet only after asking', async () => {
    const p = await open();
    p.window.eval('twW.failRelay=1');
    p.click('pv');
    await p.settle();
    p.select('pvAct', 'send');
    p.type('pvAmt', '0.2');
    p.type('pvRc', 'bp1qfriend');
    p.queueConfirm(true);
    p.click('pvGo');
    await p.waitFor(() => /Sent: 0xsend/.test(p.text('stat')), { label: 'the payment, from this wallet' });
    assert.match(p.asked.confirm.at(-1), /links this wallet to it on chain/);
    assert.deepEqual(calls(p).map(c => c[3]), ['keeper', 'self']);
    p.close();
  });

  test('V1 ether moves into the pool with one tap from the Private ETH menu', async () => {
    const p = await open();
    p.click('pv');
    await p.settle();
    p.click(p.$('pvKey').querySelector('button[data-a="rx"]'));
    await p.waitFor(() => row(p, 'Move V1 ETH into it'), { label: 'the move row' });
    p.click(row(p, 'Move V1 ETH into it'));
    await p.settle();
    assert.equal(p.value('pvIn'), 'v');
    assert.equal(p.value('pvAct'), 'out');
    assert.equal(p.value('pvChain'), '1');
    assert.equal(p.value('pvTo'), BOX, 'a V1 withdrawal to your own private ETH address');
    p.close();
  });

  test('pool ether moves into V1 as a tETH note this key owns, kept before it is sent', async () => {
    const p = await open();
    p.chain.answers.set('0x000000000ed1eabd231be41d93b719056f7febfc:7da9874f', '0x' + word(0));
    p.click('pv');
    await p.settle();
    p.click(p.$('pvKey').querySelector('button[data-a="rx"]'));
    await p.waitFor(() => row(p, 'Move it into V1'), { label: 'the move row' });
    p.click(row(p, 'Move it into V1'));
    await answer(p, '0.1');
    await p.waitFor(() => calls(p).some(c => c[0] === 'toV1'), { label: 'the move' });
    const [, amt, commit] = calls(p).find(c => c[0] === 'toV1');
    assert.equal(amt, '100000000000000000');
    assert.match(commit, /^0x[0-9a-f]{64}$/);
    const n = JSON.parse(p.window.eval('JSON.stringify(cpNotes.filter(n=>n.v==="10000000"))'));
    assert.equal(n.length, 1, 'one V1 note for 0.1 ETH');
    assert.ok(n[0].i >= 0, 'derived from the key, so recover finds it again');
    assert.equal(n[0].tx, '0x' + 'a1'.repeat(32));
    assert.equal(p.window.eval(`cpDepId(10000000n,${JSON.stringify(commit)})`), p.window.eval('cpNoteOf(cpNotes.find(n=>n.v==="10000000")).dep'),
      'the deposit the router makes is the one this note settles');
    await p.settle();
    p.close();
  });
});

describe('a move into V1 that does not go', () => {
  test('leaves no V1 note behind', async () => {
    const p = await open();
    p.chain.answers.set('0x000000000ed1eabd231be41d93b719056f7febfc:7da9874f', '0x' + word(0));
    p.window.eval('twW.failV1=1');
    p.click('pv');
    await p.settle();
    p.click(p.$('pvKey').querySelector('button[data-a="rx"]'));
    await p.waitFor(() => row(p, 'Move it into V1'), { label: 'the move row' });
    p.click(row(p, 'Move it into V1'));
    await answer(p, '0.1');
    await p.waitFor(() => /not enough in the pool/.test(p.text('stat')), { label: 'the refusal' });
    assert.equal(p.window.eval('cpNotes.filter(n=>n.v==="10000000").length'), 0, 'the note saved for it is dropped');
    assert.equal(p.window.eval('cpLoadNotes().filter(n=>n.v==="10000000").length'), 0, 'from storage too');
    p.close();
  });
});

describe('the pool bridges out to an L2', () => {
  test('picking Base or Robinhood hides the recipient, updates the hint, and bridges instead of withdrawing', async () => {
    const p = await open();
    p.click('pv');
    await p.settle();
    p.select('pvAct', 'out');
    assert.ok(!p.$('pvTo').parentElement.classList.contains('hide'), 'same-chain withdraw still asks for a recipient');
    p.select('pvChain', '8453');
    await p.settle();
    assert.ok(p.$('pvTo').parentElement.classList.contains('hide'), 'a bridge has no recipient to choose');
    assert.match(p.text('pvHint'), /Bridges to your private ETH address on Base.*which note paid is not/);
    p.type('pvAmt', '0.1');
    p.click('pvGo');
    await p.waitFor(() => /Sent: 0xbridge/.test(p.text('stat')), { label: 'the Base bridge' });
    p.select('pvChain', '4663');
    await p.settle();
    assert.match(p.text('pvHint'), /Robinhood/);
    p.type('pvAmt', '0.05');
    p.click('pvGo');
    await p.waitFor(() => /Sent: 0xbridge/.test(p.text('stat')), { label: 'the Robinhood bridge' });
    p.select('pvChain', '1');
    await p.settle();
    assert.ok(!p.$('pvTo').parentElement.classList.contains('hide'), 'back on Ethereum, the recipient returns');
    assert.match(p.text('pvHint'), /Withdraw to any 0x on Ethereum/);
    p.type('pvAmt', '0.1');
    p.type('pvTo', A.OTHER);
    p.click('pvGo');
    await p.waitFor(() => /Sent: 0xwd/.test(p.text('stat')), { label: 'an ordinary same-chain withdrawal' });
    assert.deepEqual(calls(p), [
      ['bridgeOut', 8453, '100000000000000000', 'none'],
      ['bridgeOut', 4663, '50000000000000000', 'l2rpc'],
      ['withdraw', A.OTHER, '100000000000000000', 'keeper'],
    ], 'Base gets no l2Rpc, Robinhood does, Ethereum stays a plain withdraw');
    p.close();
  });
});

describe('the pool\'s guards', () => {
  test('a withdrawal to this wallet asks first, and one to something that is not an address is refused', async () => {
    const p = await open();
    p.click('pv');
    await p.settle();
    p.select('pvAct', 'out');
    p.type('pvAmt', '0.1');
    p.queueConfirm(false);
    p.click('pvGo');
    await p.waitFor(() => /Not withdrawn/.test(p.text('stat')), { label: 'the refusal' });
    assert.match(p.asked.confirm.at(-1), /links this wallet to the pool on chain/);
    p.type('pvTo', 'bob');
    p.click('pvGo');
    await p.waitFor(() => /Withdraw to a 0x address/.test(p.text('stat')), { label: 'a bad address refused' });
    p.type('pvTo', A.OTHER);
    p.click('pvGo');
    await p.waitFor(() => /Sent: 0xwd/.test(p.text('stat')), { label: 'the withdrawal elsewhere' });
    assert.deepEqual(calls(p), [['withdraw', A.OTHER, '100000000000000000', 'keeper']], 'nothing left for the declined or refused ones');
    p.close();
  });

  test('max for a pool payment leaves the keeper\'s fee', async () => {
    const p = await open();
    p.click('pv');
    await p.settle();
    p.select('pvAct', 'send');
    p.click('pvMax');
    await p.waitFor(() => p.value('pvAmt') === '0.499', { label: 'the balance less the keeper fee' });
    p.close();
  });

  test('the Private ETH menu opens even when no mirror answers for the wallet, and two loads share one', async () => {
    const chain = new MockChain({ chainId: '0x2105' });
    chain.code.set(ROUTER, '0x5f5ff3');
    chain.answers.set(`${ROUTER}:7944b37a`, '0x' + word(BOX));
    chain.lanes = { 'tacit-evm-pool-keeper': 404, 'githubusercontent': 404, 'tacit.finance/evm-pool': 404, 'filebase': 404 };
    const p = await loadPage({ chain, storage: { 'zswap:pvin': '' } });
    await p.connect({ pin: false });
    await p.settle();
    p.window.eval(`cpUse(${JSON.stringify(KEY)})`);
    assert.equal(p.window.eval('twLoad()===twLoad()'), true, 'one load in flight, shared');
    p.click('pv');
    await p.waitFor(() => row(p, 'Your pool address'), { label: 'the menu, without the wallet' });
    assert.match(row(p, 'Your pool address').textContent, /bp1 address and balance/);
    assert.ok(row(p, 'Shield ETH into it') && row(p, 'Keeper'), 'the rows that need no wallet are all there');
    p.close();
  });
});

describe('private ether on Base and Robinhood', () => {
  test('the menu shows your pool address and balance, and pays privately from it', async () => {
    const p = await open(8453);
    p.click('pv');
    await p.waitFor(() => row(p, 'Your pool address'), { label: 'the private ETH menu' });
    assert.match(row(p, 'Your pool address').textContent, /bp1qfakepool… · 0\.5 ETH held privately/);
    assert.equal(row(p, 'Move V1 ETH into it'), undefined, 'V1 lives on Ethereum only');
    p.click(row(p, 'Your pool address'));
    await p.waitFor(() => okIn(p), { label: 'the address, to copy' });
    assert.equal(p.$('wkList').querySelector('textarea').value, 'bp1qfakepool0000000000000000');
    p.click(okIn(p));
    await p.settle();
    p.click('pv');
    await p.waitFor(() => row(p, 'Send privately'), { label: 'the private ETH menu' });
    p.click(row(p, 'Send privately'));
    await answer(p, 'bp1qfriend');
    await answer(p, '0.25');
    await p.waitFor(() => /Sent: 0xsend/.test(p.text('stat')), { label: 'the payment' });
    assert.deepEqual(calls(p), [['send', 'bp1qfriend', '250000000000000000', 'keeper']]);
    assert.equal(p.window.eval('CHAIN_ID'), 8453);
    p.close();
  });
});
