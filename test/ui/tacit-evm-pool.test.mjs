/**
 * The Tacit EVM pool wallet the page opens, held to Tacit's own pay page. The wallet keeps its synced state in
 * this browser (sealed under the view key by the module), so a reload resumes where it left off, with each chain's
 * confirmation depth (3 on Ethereum, 10 on Base and Robinhood). Its relayer is the listed Tacit keeper even when
 * the viewer pinned a keeper of their own: the pin serves /receive only, since the wallet refuses a relayer address
 * that is not Tacit's. A move out to Base or Robinhood registers the private ETH address with that chain's keeper.
 * The private ETH address and what waits at it are read from public nodes, never through the connected wallet. A
 * pool withdrawal to a known Tacit box gets the same refusal as a swap or a send to it. Max for a pool payment
 * offers what one spend can carry: the two largest notes, less the keeper's fee. Each case failed on the page
 * before it.
 */
import { test, describe, after } from 'node:test';
import assert from 'node:assert/strict';
import { A, MockChain, loadPage, closeAllPages } from './harness.mjs';
import { FAKE_POOL } from './tacit-fake-pool.mjs';

after(closeAllPages);

const ROUTER = '0x0000006c96afa6f1cd4df8fe19bc0d8b6a6cd7b5';
const BOX = '0x52fc37ee7741468a15ce879320a7a41cebaeb232';
// Tacit's vectors (docs/EVM-POOL.md, "Receive address"): identity key 0x11 x 32.
const KEY = '0x' + '11'.repeat(32);
const NPK0 = '4783613888947850950044057964142544727340891053660060203316524895455918575012';
const KEEPERS = {
  1: 'https://tacit-evm-pool-keeper.onrender.com/evm-pool/keeper',
  8453: 'https://tacit-evm-pool-keeper-base.onrender.com/evm-pool/keeper',
  4663: 'https://tacit-evm-pool-keeper-robinhood.onrender.com/evm-pool/keeper',
};
const MINE = 'https://my.keeper/evm-pool/keeper';
const ETH = 10n ** 18n;
const word = x => BigInt(x).toString(16).padStart(64, '0');

// jsdom has no dynamic import, so the wallet bundle is handed to twLoad here: the page's own call, with the
// options it builds, reaches this stand-in. It keeps state the way the module does, through `store`.
const BUNDLE = ['const m=await import(', 'const m=await window.__imp(async()=>'];
function standIn(w) {
  w.__opts = [];
  w.__seen = [];
  w.__imp = async () => ({
    PIN: {},
    makeEvmPoolWallet: async o => {
      w.__opts.push(o);
      const k = `tacit-evm-pool-v1:${o.chainId}:pool:bp1qstandin`;
      const had = o.store ? o.store.get(k) : undefined;
      w.__seen.push(had ?? null);
      if (o.store) o.store.set(k, 'enc1:' + (had ? 'resumed' : 'first'));
      return { address: 'bp1qstandin', receive: { address: BOX }, sync: async () => ({ balance: 0n }), balance: () => 0n, notes: () => [], terminate() {} };
    },
  });
}

function chainOn(id) {
  const chain = new MockChain({ chainId: '0x' + id.toString(16) });
  chain.code.set(ROUTER, '0x5f5ff3');
  chain.answers.set(`${ROUTER}:7944b37a`, '0x' + word(BOX));
  chain.lanes = { 'tacit-evm-pool-keeper': 404, 'my.keeper': 404 };
  return chain;
}

async function open(id, { storage = {}, patch = [], beforeParse } = {}) {
  const p = await loadPage({ chain: chainOn(id), storage: { 'zswap:pvin': '', ...storage }, patch, beforeParse: w => {
    const inner = w.fetch;
    w.__keeper = [];
    w.fetch = async (url, init) => {
      if (String(url).includes('/evm-pool/keeper/') && init && init.body) w.__keeper.push({ url: String(url), body: JSON.parse(init.body) });
      return inner(url, init);
    };
    if (beforeParse) beforeParse(w);
  } });
  await p.connect({ pin: false });
  await p.settle();
  p.window.eval(`cpUse(${JSON.stringify(KEY)})`);
  return p;
}
const calls = p => JSON.parse(p.window.eval('JSON.stringify(twW.calls)'));
const row = (p, name) => [...p.$('wkList').querySelectorAll('button.tkr')].find(b => b.textContent.startsWith(name));

describe('the pool wallet the page opens', () => {
  test('keeps its synced state across visits, with each chain\'s confirmation depth', async () => {
    const p = await open(8453, { patch: [BUNDLE], beforeParse: standIn });
    await p.window.eval('twLoad()');
    assert.equal(p.window.__opts[0].confirmations, 10, 'Base waits ten blocks, as Tacit\'s pay page does');
    assert.equal(p.window.__seen[0], null, 'nothing kept yet on a first visit');
    const kept = p.window.localStorage.getItem('tacit-evm-pool-v1:8453:pool:bp1qstandin');
    assert.equal(kept, 'enc1:first', 'what the wallet keeps lands in this browser\'s storage');
    p.close();

    const q = await open(8453, { storage: { 'tacit-evm-pool-v1:8453:pool:bp1qstandin': kept }, patch: [BUNDLE], beforeParse: standIn });
    await q.window.eval('twLoad()');
    assert.equal(q.window.__seen[0], 'enc1:first', 'the next visit opens the wallet with what the last one kept');
    assert.equal(q.window.localStorage.getItem('tacit-evm-pool-v1:8453:pool:bp1qstandin'), 'enc1:resumed');
    q.close();

    const e = await open(1, { patch: [BUNDLE], beforeParse: standIn });
    await e.window.eval('twLoad()');
    assert.equal(e.window.__opts[0].confirmations, 3, 'Ethereum waits three');
    e.close();
  });

  test('relays through Tacit\'s listed keeper even when the viewer pinned one for /receive', async () => {
    const p = await open(8453, { storage: { 'zswap:evk:8453': MINE }, patch: [BUNDLE], beforeParse: standIn });
    await p.window.eval('twLoad()');
    assert.equal(p.window.eval('tbKs(8453)[0]'), MINE, 'the viewer\'s keeper is pinned');
    assert.equal(p.window.__opts[0].relay, KEEPERS[8453], 'the relayer is Tacit\'s listed keeper, not the pin');
    assert.equal(p.window.__opts[0].relay, p.window.eval('TB_K[8453][0]'));
    p.window.eval('rxPost()');
    await p.waitFor(() => p.window.__keeper.some(k => k.url === MINE + '/receive'), { label: 'the pin still hears of the address' });
    p.close();
  });
});

describe('a move out to Base or Robinhood', () => {
  test('registers the private ETH address with the destination chain\'s keeper', async () => {
    const p = await open(1);
    p.window.eval(FAKE_POOL);
    p.chain.lanes['tacit-evm-pool-keeper-base.onrender.com'] = { status: 'watching' };
    p.chain.lanes['tacit-evm-pool-keeper-robinhood.onrender.com'] = { status: 'watching' };
    p.click('pv');
    await p.settle();
    p.select('pvAct', 'out');
    for (const [ch, amt] of [[8453, '0.1'], [4663, '0.05']]) {
      p.select('pvChain', String(ch));
      await p.settle();
      p.type('pvAmt', amt);
      p.click('pvGo');
      await p.waitFor(() => p.window.__keeper.some(k => k.url === KEEPERS[ch] + '/receive'), { label: 'the keeper on ' + ch });
      await p.waitFor(() => /Sent: 0xbridge/.test(p.text('stat')) && calls(p).length === (ch === 8453 ? 1 : 2), { label: 'the bridge to ' + ch });
      const reg = p.window.__keeper.filter(k => k.url === KEEPERS[ch] + '/receive');
      assert.deepEqual(reg.map(k => k.body), [{ chainId: ch, npk: NPK0, feeBps: 25 }], 'box 0 on chain ' + ch + ', as watchReceive registers it');
    }
    assert.deepEqual(calls(p).map(c => c.slice(0, 3)), [['bridgeOut', 8453, '100000000000000000'], ['bridgeOut', 4663, '50000000000000000']]);
    p.close();
  });
});

describe('the private ETH address on Base', () => {
  test('and what waits at it are read from public nodes, never through the wallet', async () => {
    const p = await open(8453, { beforeParse: w => {
      w.__wallet = [];
      const inner = w.ethereum.request;
      w.ethereum.request = a => { w.__wallet.push(a); return inner(a); };
    } });
    p.window.eval(FAKE_POOL);
    p.chain.native.set(BOX, ETH / 100n);
    p.window.__wallet.length = 0;
    p.chain.httpLog = [];
    p.click('pv');
    await p.waitFor(() => row(p, 'Your private ETH address'), { label: 'the private ETH menu' });
    assert.match(row(p, 'Your private ETH address').textContent, /0x52fc37…aeb232 · 0\.01 ETH waiting/);
    const viaWallet = p.window.__wallet.filter(x => JSON.stringify(x.params || []).toLowerCase().includes(BOX.slice(2))
      || (x.method === 'eth_call' && /^0x7944b37a/.test(x.params?.[0]?.data || '')));
    assert.deepEqual(viaWallet, [], 'the wallet never sees the address or the call that names it');
    const pub = p.chain.httpLog.map(x => x.method);
    assert.ok(pub.includes('eth_call') && pub.includes('eth_getBalance'), 'both reads went to a public node');
    assert.equal(p.chain.calls.filter(c => c.selector === '7944b37a').length, 1, 'receiveBoxOf read once');
    p.close();
  });
});

describe('a pool withdrawal to a Tacit box', () => {
  test('is refused unless exactly the box\'s amount arrives, as a swap or a send to it is', async () => {
    const TB = '0x00000000000000000000000000000000000b0c5e';
    const intent = { amount: (5n * ETH / 100n).toString(), outLeaf0: '1', outLeaf1: '0', memo0Hash: '0x' + 'c5'.repeat(32), memo1Hash: '0x' + 'd2'.repeat(32), refund: A.ACCOUNT, deadline: String(Math.floor(Date.now() / 1000) + 86400), nonce: '7' };
    const p = await open(1, { storage: { 'zswap:tb': JSON.stringify([{ c: 1, b: TB, i: intent }]) } });
    p.window.eval(FAKE_POOL);
    p.click('pv');
    await p.settle();
    p.select('pvAct', 'out');
    p.type('pvTo', TB);
    p.type('pvAmt', '0.1');
    p.click('pvGo');
    await p.waitFor(() => /A Tacit pool box takes exactly 0\.05 ETH on Ethereum, sent directly\./.test(p.text('stat')), { label: 'the refusal' });
    assert.deepEqual(calls(p), [], 'nothing withdrawn');
    p.type('pvAmt', '0.05');
    p.click('pvGo');
    await p.waitFor(() => /Sent: 0xwd/.test(p.text('stat')), { label: 'the exact amount goes' });
    assert.deepEqual(calls(p), [['withdraw', TB, '50000000000000000', 'keeper']]);
    p.close();
  });
});

describe('Max for a pool payment with three notes', () => {
  test('offers the two largest notes less the keeper\'s fee, what one spend can carry', async () => {
    const p = await open(1);
    p.window.eval(FAKE_POOL);
    p.window.eval('twW.notes=()=>[{v:"100000000000000000"},{v:"300000000000000000"},{v:"200000000000000000"}];twW.balance=()=>6n*10n**17n');
    p.click('pv');
    await p.settle();
    p.select('pvAct', 'send');
    p.click('pvMax');
    await p.waitFor(() => p.value('pvAmt') !== '', { label: 'the max amount' });
    assert.equal(p.value('pvAmt'), '0.499', '0.3 + 0.2 less the 0.001 fee, not the whole 0.6 balance');
    p.close();
  });
});
