// The Tacit pool's private ETH receive address: one standing address per Tacit key, the same on every chain,
// that shields the ETH it is sent (any other token sent to it is lost). The page derives the note key in page (Poseidon over BabyJubJub) and takes
// the address from the router's own receiveBoxOf, so nothing shows before the pool is live on the chain.
import { test, describe, after } from 'node:test';
import assert from 'node:assert/strict';
import { A, MockChain, loadPage, closeAllPages } from './harness.mjs';

after(closeAllPages);

const ROUTER = '0x0000006c96afa6f1cd4df8fe19bc0d8b6a6cd7b5';
const BOX = '0x52fc37ee7741468a15ce879320a7a41cebaeb232';
const KEEPER = 'https://keeper.test/evm-pool/keeper';
// Tacit's vectors (docs/EVM-POOL.md, "Receive address"): identity key 0x11 × 32.
const KEY = '0x' + '11'.repeat(32);
const NPK0 = 4783613888947850950044057964142544727340891053660060203316524895455918575012n;
const word = x => BigInt(x).toString(16).padStart(64, '0');

const roster = k => ({ 'zswap:ep3': JSON.stringify({ t: Date.now(), v: [[], [], [], [], [], [], [], [], k[1] || [], k[8453] || [], [], []] }) });

function chainOn(id, { live = true, infoChain } = {}) {
  const chain = new MockChain({ chainId: '0x' + id.toString(16) });
  if (live) chain.code.set(ROUTER, '0x5f5ff3');
  chain.answers.set(`${ROUTER}:7944b37a`, '0x' + word(BOX));
  chain.lanes = chain.lanes || {};
  chain.lanes['keeper.test/evm-pool/keeper/receive'] = { box: BOX, kind: 'receive', status: 'watching' };
  chain.lanes['keeper.test/evm-pool/keeper/info'] = { chainId: infoChain ?? id, router: ROUTER };
  chain.lanes['keeper.test/evm-pool/keeper/quote'] = { sweepFee: '5000000000000', receiveMin: '2000000000000000' };
  for (const h of ['tacit-evm-pool-keeper.onrender.com', 'tacit-evm-pool-keeper-base.onrender.com', 'tacit-evm-pool-keeper-robinhood.onrender.com']) chain.lanes[h] = 404;
  return chain;
}

async function open(id, { live = true, keepers = { [id]: [KEEPER] }, infoChain } = {}) {
  const p = await loadPage({ chain: chainOn(id, { live, infoChain }), storage: roster(keepers), beforeParse: w => {
    const inner = w.fetch;
    w.__keeper = [];
    w.__opened = [];
    w.open = (...a) => { w.__opened.push(a); return null; };
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
const row = (p, name) => [...p.$('wkList').querySelectorAll('button.tkr')].find(b => b.textContent.startsWith(name));
const menu = p => p.visible('wkWrap') && row(p, 'Your private ETH address');
async function choose(p, name) {
  await p.waitFor(() => menu(p), { label: 'the private ETH menu' });
  p.click(row(p, name));
  await p.settle();
}

describe('the private ETH receive address', () => {
  test('the note key derived in page is Tacit\'s own', async () => {
    const p = await open(1);
    unlock(p);
    assert.equal(p.window.eval('String(rxNpk())'), NPK0.toString());
    p.close();
  });

  test('on Base and Robinhood, Private is there from the first load, with Tacit\'s own keepers built in', async () => {
    for (const id of [8453, 4663]) {
      const p = await open(id, { keepers: {} });
      assert.ok(shown(p), 'Private on chain ' + id);
      p.close();
    }
  });

  test('on Base, Private shows the address from the router, tells the keeper, and fills in a send to it', async () => {
    const p = await open(8453);
    await p.waitFor(() => shown(p), { label: 'the Private button on Base' });
    unlock(p);
    p.click('pv');
    await p.waitFor(() => menu(p), { label: 'the private ETH menu' });
    assert.equal(p.text('wkHdr'), 'Private ETH · Base');
    assert.match(row(p, 'Your private ETH address').textContent, /0x52fc37…aeb232 · send at least 0\.002 ETH/, 'the keeper\'s minimum for a sweep');
    await choose(p, 'Your private ETH address');
    await p.waitFor(() => okIn(p), { label: 'the address, in full' });
    assert.equal(p.$('wkList').querySelector('textarea').value, BOX);
    assert.match(p.text('wkList'), /ETH sent to it on Ethereum, Base or Robinhood is shielded into your Tacit balance there, less at most 0\.25%/);
    assert.match(p.text('wkList'), /any other token is lost/);
    p.click(okIn(p));
    await p.settle();
    const call = p.chain.calls.find(c => c.to === ROUTER && c.selector === '7944b37a');
    assert.equal(call.data, '0x7944b37a' + word(NPK0) + word(25), 'receiveBoxOf(npk, 25)');
    assert.deepEqual(p.window.__keeper.map(k => [k.url, k.body]), [[KEEPER + '/receive', { chainId: 8453, npk: NPK0.toString(), feeBps: 25 }]], 'the first keeper that accepts, and only it');
    assert.ok(!p.window.eval('pvMode'), 'the Ethereum panel stays shut on Base');
    p.click('pv');
    await choose(p, 'Shield ETH into it');
    await p.waitFor(() => p.value('rc') === BOX, { label: 'a send to the address' });
    assert.equal(p.window.eval('CHAIN_ID'), 8453);
    assert.equal(p.$('tabSend').getAttribute('aria-selected'), 'true');
    p.close();
  });

  test('sending and withdrawing private ETH open tacit.finance on this chain, in a new tab', async () => {
    const p = await open(8453);
    await p.waitFor(() => shown(p), { label: 'the Private button on Base' });
    unlock(p);
    for (const [name, doing] of [['Send privately', 'send'], ['Withdraw', 'withdraw']]) {
      p.click('pv');
      await choose(p, name);
    }
    assert.deepEqual(p.window.__opened.map(a => [a[0], a[1], a[2]]), [
      ['https://tacit.finance/sats/#eth=8453&do=send', '_blank', 'noopener'],
      ['https://tacit.finance/sats/#eth=8453&do=withdraw', '_blank', 'noopener']]);
    assert.equal(p.window.eval('CHAIN_ID'), 8453, 'zSwap stays where it was');
    p.close();
  });

  test('on Ethereum, the key row offers the address', async () => {
    const p = await open(1);
    unlock(p);
    p.click('pv');
    await p.waitFor(() => p.$('pvKey').querySelector('button[data-a="rx"]'), { label: 'the private ETH address button' });
    p.click(p.$('pvKey').querySelector('button[data-a="rx"]'));
    await p.waitFor(() => menu(p), { label: 'the private ETH menu' });
    assert.equal(p.text('wkHdr'), 'Private ETH · Ethereum');
    p.close();
  });

  test('unlocking the key registers the address with the keeper, so a payment is swept at once', async () => {
    const p = await open(1);
    p.click('pv');
    await p.settle();
    p.click('pvGo');
    await p.waitFor(() => /Key unlocked/.test(p.text('pvKey')), { label: 'the key to unlock' });
    await p.waitFor(() => p.window.__keeper.length > 0, { label: 'the keeper to hear of the address' });
    const npk = p.window.eval('String(rxNpk())');
    assert.deepEqual(p.window.__keeper.map(k => [k.url, k.body]), [[KEEPER + '/receive', { chainId: 1, npk, feeBps: 25 }]]);
    assert.ok(!p.visible('wkWrap'), 'no sheet opens: this happens quietly');
    p.close();
  });

  test('when the listed keeper does not answer, Tacit\'s built-in keeper for the chain is asked', async () => {
    const p = await open(8453);
    p.chain.lanes['keeper.test/evm-pool/keeper/receive'] = 404;
    p.chain.lanes['tacit-evm-pool-keeper-base.onrender.com'] = { box: BOX, kind: 'receive', status: 'watching' };
    unlock(p);
    p.window.eval('rxPost()');
    await p.waitFor(() => (p.chain.httpLog || []).some(x => x.url.startsWith('https://tacit-evm-pool-keeper-base.onrender.com/evm-pool/keeper/receive')), { label: 'the built-in keeper' });
    p.close();
  });

  test('a viewer can use a keeper of their own, checked against its /info first', async () => {
    const MINE = 'https://my.keeper/evm-pool/keeper';
    const p = await open(8453);
    p.chain.lanes['my.keeper/evm-pool/keeper/info'] = { chainId: 8453, router: ROUTER, minReceiveFeeBps: 1 };
    p.chain.lanes['my.keeper/evm-pool/keeper/receive'] = { box: BOX, kind: 'receive', status: 'watching' };
    p.chain.lanes['bad.keeper/evm-pool/keeper/info'] = { chainId: 1, router: ROUTER, minReceiveFeeBps: 1 };
    unlock(p);
    const setKeeper = async v => {
      p.click('pv');
      await choose(p, 'Keeper');
      await p.waitFor(() => okIn(p), { label: 'the keeper prompt' });
      p.$('wkList').querySelector('textarea').value = v;
      p.click(okIn(p));
      await p.settle();
    };
    await setKeeper('https://bad.keeper/evm-pool/keeper');
    await p.waitFor(() => /not a Tacit pool keeper for Base/.test(p.text('stat')), { label: 'the refusal' });
    assert.equal(p.window.localStorage.getItem('zswap:evk:8453'), null, 'a keeper for another chain is not kept');
    await setKeeper(MINE + '/');
    await p.waitFor(() => p.window.localStorage.getItem('zswap:evk:8453') === MINE, { label: 'the keeper to be kept' });
    await p.waitFor(() => p.window.__keeper.some(k => k.url === MINE + '/receive'), { label: 'the address registered with it' });
    assert.equal(p.window.__keeper.filter(k => k.url.endsWith('/receive')).at(-1).url, MINE + '/receive', 'your own keeper goes first');
    p.click('pv');
    await p.waitFor(() => menu(p), { label: 'the private ETH menu' });
    assert.match(row(p, 'Keeper').textContent, /yours · my\.keeper/);
    p.click([...p.$('wkList').querySelectorAll('button')].find(b => b.textContent === 'Cancel'));
    await p.settle();
    await setKeeper('');
    assert.equal(p.window.localStorage.getItem('zswap:evk:8453'), null, 'blank goes back to the listed keepers');
    p.close();
  });

  test('the menu\'s Private stays on Base', async () => {
    let p = await open(8453);
    await p.waitFor(() => shown(p), { label: 'the Private button on Base' });
    unlock(p);
    p.window.location.hash = 'm=pv';
    await p.waitFor(() => menu(p), { label: 'the private ETH menu on Base' });
    assert.equal(p.window.eval('CHAIN_ID'), 8453);
    p.close();
  });
});
