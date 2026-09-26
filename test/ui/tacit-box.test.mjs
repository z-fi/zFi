// Tacit EVM pool deposit boxes: a #tacit-box= link from a Tacit wallet names a
// DepositIntent and its keeper hint. The page takes the box address from the
// router's own depositBoxOf view, hands the intent to a keeper listed in the
// zEndpoints roster, and then fills in an ordinary ETH send to the box. Every
// recipient path refuses a box unless exactly the intent's amount arrives on
// the intent's chain, and an expired box that still holds funds is offered
// back to its refund address.
import { test, describe, after } from 'node:test';
import assert from 'node:assert/strict';
import { A, MockChain, loadPage, closeAllPages } from './harness.mjs';

after(closeAllPages);

const ROUTER = '0x0000006c96afa6f1cd4df8fe19bc0d8b6a6cd7b5';
const BOX = '0x00000000000000000000000000000000000b0c5e';
const KEEPER = 'https://keeper.test';
const AMOUNT = 5n * 10n ** 17n;  // 0.5 ETH
const now = () => Math.floor(Date.now() / 1000);

const intent = (o = {}) => ({
  amount: AMOUNT.toString(), outLeaf0: '123', outLeaf1: '0',
  memo0Hash: '0x' + 'c5'.repeat(32), memo1Hash: '0x' + 'd2'.repeat(32),
  refund: A.ACCOUNT, deadline: String(now() + 86400), nonce: '7', ...o,
});
const hint = { outputs: [{ v: (AMOUNT - 10n ** 15n).toString(), npk: '5', rho: '9' }, null], fee: '1000000000000000', memo0: '0x', memo1: '0x' };
const link = (o = {}, chainId = 1) => 'tacit-box=' + Buffer.from(JSON.stringify({ chainId, intent: intent(o), hint })).toString('base64url');
const roster = (k1 = [KEEPER]) => ({ 'zswap:ep3': JSON.stringify({ t: Date.now(), v: [[], [], [], [], [], [], [], [], k1, [], [], []] }) });

function pool(chain, { live = true } = {}) {
  if (live) chain.answers.set(`${ROUTER}:34a44915`, '0x' + BOX.slice(2).padStart(64, '0'));
  chain.lanes = chain.lanes || {};
  chain.lanes[KEEPER.slice(8) + '/evm-pool/keeper/deposit'] = { box: BOX, kind: 'deposit' };
  return chain;
}

async function open({ hash, storage = roster(), chain = pool(new MockChain()), confirm = [] } = {}) {
  const p = await loadPage({ chain, storage, beforeParse: w => {
    const inner = w.fetch;
    w.__keeper = [];
    w.fetch = async (url, init) => {
      if (String(url).includes('/evm-pool/keeper/') && init && init.body) w.__keeper.push({ url: String(url), body: JSON.parse(init.body) });
      return inner(url, init);
    };
  } });
  p.queueConfirm(...confirm);
  await p.connect();
  await p.settle();
  if (hash) { p.window.location.hash = hash; await p.settle(); }
  return p;
}

describe('a Tacit EVM pool deposit box', () => {
  test('before the pool is deployed the link says so and asks nothing of the keeper', async () => {
    const p = await open({ hash: link(), chain: pool(new MockChain(), { live: false }) });
    await p.waitFor(() => /not live on Ethereum yet/.test(p.text('stat')), { label: 'the not-live notice' });
    assert.equal(p.window.__keeper.length, 0);
    assert.equal(p.chain.sent.length, 0);
    p.close();
  });

  test('with no keeper listed for the chain nothing is filled in', async () => {
    const p = await open({ hash: link(), storage: roster([]) });
    await p.waitFor(() => /No keeper serves Ethereum yet/.test(p.text('stat')), { label: 'the no-keeper notice' });
    assert.notEqual(p.value('rc'), BOX);
    p.close();
  });

  test('the keeper gets the intent and hint verbatim, then an exact ETH send to the box is filled in', async () => {
    const h = link(), sent = JSON.parse(Buffer.from(h.slice(10), 'base64url').toString());
    const p = await open({ hash: h, confirm: [true] });
    await p.waitFor(() => p.value('rc') === BOX, { label: 'the box as recipient' });
    await p.settle();
    assert.equal(p.window.__keeper.length, 1);
    assert.equal(p.window.__keeper[0].url, KEEPER + '/evm-pool/keeper/deposit');
    assert.deepEqual(p.window.__keeper[0].body, { intent: sent.intent, hint: sent.hint });
    assert.match(p.asked.confirm[0], /Shield 0\.5 ETH into the Tacit pool on Ethereum for the wallet that made this link/);
    assert.match(p.asked.confirm[0], /keeper fee of 0\.001 ETH/);
    assert.equal(p.value('amt'), '0.5');
    assert.doesNotMatch(p.text('stat'), /Tacit pool box/, 'the filled-in send is the exact one');
    const kept = JSON.parse(p.window.localStorage.getItem('zswap:tb'));
    assert.equal(kept.length, 1);
    assert.equal(kept[0].b, BOX);
    const call = p.chain.calls.find(c => c.to === ROUTER);
    assert.equal(call.selector, '34a44915', 'the box comes from the router, not from the link');
    p.close();
  });

  test('a changed amount, or a swap that is not exact ETH out, is refused', async () => {
    const p = await open({ hash: link(), confirm: [true] });
    await p.waitFor(() => p.value('rc') === BOX, { label: 'the box as recipient' });
    p.type('amt', '0.4');
    await p.waitFor(() => /A Tacit pool box takes exactly 0\.5 ETH on Ethereum/.test(p.text('stat')), { label: 'the send refusal' });
    const w = p.window;
    assert.equal(w.eval(`tbChk("${BOX}",${AMOUNT}n)`), '');
    assert.match(w.eval(`tbChk("${BOX}",${AMOUNT}n,8453)`), /takes exactly/, 'the same box on another chain never completes');
    assert.match(w.eval(`tbChk("${BOX}",-1n)`), /takes exactly/, 'a path that is not an exact ETH arrival');
    assert.equal(w.eval(`tbChk("${A.ACCOUNT}",1n)`), '', 'any other address is untouched');
    p.close();
  });

  test('a swap pays a box only as exact ETH out of the intent\'s amount', async () => {
    const storage = { ...roster(), 'zswap:tb': JSON.stringify([{ c: 1, b: BOX, i: intent() }]) };
    const refusal = /A Tacit pool box takes exactly 0\.5 ETH on Ethereum/;
    const swapTo = async (hash, want) => {
      const p = await loadPage({ chain: pool(new MockChain()), storage, hash });
      await p.connect({ pin: false });
      await p.settle();
      assert.equal(p.window.eval('TOKENS[toSel.value].sym'), want.out);
      assert.equal(p.window.eval('mode'), want.mode);
      return p;
    };
    let p = await swapTo('token=ETH&out=USDC&amount=0.5&to=' + BOX, { out: 'USDC', mode: 'in' });
    await p.waitFor(() => refusal.test(p.text('stat')), { label: 'an exact-in swap to the box refused' });
    p.close();
    p = await swapTo('token=USDC&out=ETH&amount=0.4&exactOut=1&to=' + BOX, { out: 'ETH', mode: 'out' });
    await p.waitFor(() => refusal.test(p.text('stat')), { label: 'the wrong amount of ETH out refused' });
    p.close();
    p = await swapTo('token=USDC&out=ETH&amount=0.5&exactOut=1&to=' + BOX, { out: 'ETH', mode: 'out' });
    assert.doesNotMatch(p.text('stat'), refusal, 'exactly the box\'s amount of ETH out is allowed');
    assert.ok(!p.$('rc').classList.contains('bad'));
    p.close();
  });

  test('a box that already holds funds is not paid again', async () => {
    const chain = pool(new MockChain());
    chain.native.set(BOX, AMOUNT);
    const p = await open({ hash: link(), chain });
    await p.waitFor(() => /already paid/.test(p.text('stat')), { label: 'the already-paid notice' });
    assert.equal(p.window.__keeper.length, 0);
    p.close();
  });

  test('a box on a chain zSwap does not serve is refused in words', async () => {
    const p = await open({ hash: 'tacit-box=' + Buffer.from(JSON.stringify({ chainId: 10, intent: intent(), hint })).toString('base64url') });
    await p.waitFor(() => /a chain zSwap does not serve/.test(p.text('stat')), { label: 'the chain refusal' });
    assert.equal(p.window.__keeper.length, 0);
    p.close();
  });

  test('a box close to its deadline is refused', async () => {
    const p = await open({ hash: link({ deadline: String(now() + 600) }) });
    await p.waitFor(() => /expires within the hour/.test(p.text('stat')), { label: 'the deadline refusal' });
    p.close();
  });

  test('an expired box still holding funds is offered back to its refund address', async () => {
    const chain = pool(new MockChain());
    chain.native.set(BOX, AMOUNT);
    const I = intent({ deadline: String(now() - 60) });
    const storage = { ...roster(), 'zswap:tb': JSON.stringify([{ c: 1, b: BOX, i: I }]) };
    const p = await open({ chain, storage, confirm: [true] });
    await p.waitFor(() => p.chain.sentTo(ROUTER).length === 1, { label: 'the reclaim' });
    const tx = p.chain.sentTo(ROUTER)[0];
    assert.ok(tx.data.startsWith('0xf255eb45'), 'reclaimDeposit(intent, address(0))');
    assert.equal(tx.data.length, 2 + 8 + 64 * 9);
    assert.match(p.asked.confirm.find(q => /past its deadline/.test(q)), /holds 0\.5 ETH past its deadline/);
    p.close();
  });

  test('an expired box that was emptied is forgotten', async () => {
    const I = intent({ deadline: String(now() - 60) });
    const storage = { ...roster(), 'zswap:tb': JSON.stringify([{ c: 1, b: BOX, i: I }]) };
    const p = await open({ storage });
    await p.waitFor(() => p.window.localStorage.getItem('zswap:tb') === '[]', { label: 'the box to be dropped' });
    assert.equal(p.chain.sent.length, 0);
    p.close();
  });
});
