// The Tacit pool's private ETH receive address: one standing address per Tacit key, the same on every chain,
// that shields whatever it is sent. The page derives the note key in page (Poseidon over BabyJubJub) and takes
// the address from the router's own receiveBoxOf, so nothing shows before the pool is live on the chain.
import { test, describe, after } from 'node:test';
import assert from 'node:assert/strict';
import { A, MockChain, loadPage, closeAllPages } from './harness.mjs';

after(closeAllPages);

const ROUTER = '0x0000006c96afa6f1cd4df8fe19bc0d8b6a6cd7b5';
const BOX = '0x52fc37ee7741468a15ce879320a7a41cebaeb232';
const KEEPER = 'https://keeper.test';
// Tacit's vectors (docs/EVM-POOL.md, "Receive address"): identity key 0x11 × 32.
const KEY = '0x' + '11'.repeat(32);
const NPK0 = 4783613888947850950044057964142544727340891053660060203316524895455918575012n;
const word = x => BigInt(x).toString(16).padStart(64, '0');

const roster = k => ({ 'zswap:ep3': JSON.stringify({ t: Date.now(), v: [[], [], [], [], [], [], [], [], k[1] || [], k[8453] || [], [], []] }) });

function chainOn(id, { live = true } = {}) {
  const chain = new MockChain({ chainId: '0x' + id.toString(16) });
  if (live) chain.code.set(ROUTER, '0x5f5ff3');
  chain.answers.set(`${ROUTER}:7944b37a`, '0x' + word(BOX));
  chain.lanes = chain.lanes || {};
  chain.lanes['keeper.test/evm-pool/keeper/receive'] = { box: BOX, kind: 'receive', status: 'watching' };
  return chain;
}

async function open(id, { live = true, keepers = { [id]: [KEEPER] } } = {}) {
  const p = await loadPage({ chain: chainOn(id, { live }), storage: roster(keepers), beforeParse: w => {
    const inner = w.fetch;
    w.__keeper = [];
    w.fetch = async (url, init) => {
      if (String(url).includes('/evm-pool/keeper/') && init && init.body) w.__keeper.push({ url: String(url), body: JSON.parse(init.body) });
      return inner(url, init);
    };
  } });
  await p.connect({ pin: false });
  await p.settle();
  return p;
}
const shown = p => !p.$('pv').classList.contains('hide');
const unlock = p => p.window.eval(`cpUse(${JSON.stringify(KEY)})`);
const okIn = p => [...p.$('wkList').querySelectorAll('button')].find(b => b.textContent === 'OK');

describe('the private ETH receive address', () => {
  test('the note key derived in page is Tacit\'s own', async () => {
    const p = await open(1);
    unlock(p);
    assert.equal(p.window.eval('String(rxNpk())'), NPK0.toString());
    p.close();
  });

  test('on Base, Private appears once the pool and a keeper are live there', async () => {
    let p = await open(8453);
    await p.waitFor(() => shown(p), { label: 'the Private button on Base' });
    p.close();
    p = await open(8453, { live: false });
    assert.ok(!shown(p), 'no router code: no Private button');
    p.close();
    p = await open(8453, { keepers: {} });
    assert.ok(!shown(p), 'no keeper listed: no Private button');
    p.close();
  });

  test('on Base, Private shows the address from the router, tells the keeper, and fills in a send to it', async () => {
    const p = await open(8453);
    await p.waitFor(() => shown(p), { label: 'the Private button on Base' });
    unlock(p);
    p.click('pv');
    await p.waitFor(() => p.visible('wkWrap') && okIn(p), { label: 'the address sheet' });
    assert.equal(p.$('wkList').querySelector('textarea').value, BOX);
    assert.match(p.text('wkList'), /Your private ETH address/);
    const call = p.chain.calls.find(c => c.to === ROUTER && c.selector === '7944b37a');
    assert.equal(call.data, '0x7944b37a' + word(NPK0) + word(25), 'receiveBoxOf(npk, 25)');
    assert.deepEqual(p.window.__keeper.map(k => [k.url, k.body]), [[KEEPER + '/evm-pool/keeper/receive', { chainId: 8453, npk: NPK0.toString(), feeBps: 25 }]]);
    assert.ok(!p.window.eval('pvMode'), 'the Ethereum panel stays shut on Base');
    p.click(okIn(p));
    await p.waitFor(() => p.value('rc') === BOX, { label: 'a send to the address' });
    assert.equal(p.window.eval('CHAIN_ID'), 8453);
    assert.equal(p.$('tabSend').getAttribute('aria-selected'), 'true');
    p.close();
  });

  test('on Ethereum, the key row offers the address once the pool is live', async () => {
    const p = await open(1);
    unlock(p);
    p.click('pv');
    await p.waitFor(() => p.$('pvKey').querySelector('button[data-a="rx"]'), { label: 'the private ETH address button' });
    p.click(p.$('pvKey').querySelector('button[data-a="rx"]'));
    await p.waitFor(() => p.visible('wkWrap') && okIn(p), { label: 'the address sheet' });
    assert.equal(p.$('wkList').querySelector('textarea').value, BOX);
    p.close();
  });

  test('unlocking the key registers the address with the keeper, so a payment is swept at once', async () => {
    const p = await open(1);
    await p.waitFor(() => p.window.eval('rxOn[1]') === 1, { label: 'the pool to read as live' });
    p.click('pv');
    await p.settle();
    p.click('pvGo');
    await p.waitFor(() => /Key unlocked/.test(p.text('pvKey')), { label: 'the key to unlock' });
    await p.waitFor(() => p.window.__keeper.length > 0, { label: 'the keeper to hear of the address' });
    const npk = p.window.eval('String(rxNpk())');
    assert.deepEqual(p.window.__keeper.map(k => [k.url, k.body]), [[KEEPER + '/evm-pool/keeper/receive', { chainId: 1, npk, feeBps: 25 }]]);
    assert.ok(!p.visible('wkWrap'), 'no sheet opens: this happens quietly');
    p.close();
  });

  test('the menu\'s Private stays on Base when the pool is live there, and goes to Ethereum when it is not', async () => {
    let p = await open(8453);
    await p.waitFor(() => shown(p), { label: 'the Private button on Base' });
    unlock(p);
    p.window.location.hash = 'm=pv';
    await p.waitFor(() => p.visible('wkWrap') && okIn(p), { label: 'the address sheet on Base' });
    assert.equal(p.window.eval('CHAIN_ID'), 8453);
    p.close();
    p = await open(8453, { live: false });
    p.window.location.hash = 'm=pv';
    await p.waitFor(() => p.window.eval('CHAIN_ID') === 1, { label: 'the switch to Ethereum' });
    p.close();
  });
});
