import { test, describe, after } from 'node:test';
import assert from 'node:assert/strict';
import { AbiCoder, Interface } from 'ethers';
import { readFileSync } from 'node:fs';
import { A, MockChain, loadPage, closeAllPages } from './harness.mjs';

const SRC = readFileSync(new URL('../../zSwap.html', import.meta.url), 'utf8');
const EPS = /const EPS="(0x[0-9a-fA-F]{40})"/.exec(SRC)[1].toLowerCase();
const RPCS_PIN = /const RPCS_PIN="(0x[0-9a-fA-F]{40})"/.exec(SRC)[1].toLowerCase();

after(closeAllPages);

const coder = AbiCoder.defaultAbiCoder();
const IFACE = new Interface(['function listsOf(bytes32[],uint256[]) view returns (string[][])']);
const SEL = IFACE.getFunction('listsOf').selector;
const b32 = s => '0x' + Buffer.from(s, 'ascii').toString('hex').padEnd(64, '0');

/* The order the page asks in, which is the order its answer is read back in.
   Pinned here as data so a reordering on either side fails loudly instead of
   pouring the Bitcoin list into the Tacit relay. */
const ASKED = [['rpc', 8453], ['rpc', 4663], ['logs', 1], ['tacit', 1], ['btc', 0], ['wc', 0], ['wcpid', 0], ['tacad', 1], ['evk', 1], ['evk', 8453], ['evk', 4663]];

const PID = 'ab'.repeat(16);
const CURATED = [
  ['https://base.cur'], ['https://rh.cur'], ['https://logs.cur'], ['https://relay.cur/'],
  ['https://btc.cur/api'], ['wss://wc.cur'], [PID], ['https://ad.cur/proofs/'],
  ['https://k1.cur'], ['https://k8453.cur/'], ['https://k4663.cur/keeper'],
];

/* Serves the roster, and zRpcList's rpcs(), from whichever node asks. `each`
   lets a test answer the Nth ask differently, which is how two nodes disagree. */
function serve(chain, lists, { l1 = ['https://l1.cur'], each } = {}) {
  const ethCall = chain.ethCall.bind(chain);
  let n = 0;
  chain.epAsks = [];
  chain.ethCall = (tx, block) => {
    const to = (tx.to || '').toLowerCase();
    if (to === EPS && tx.data.startsWith(SEL)) {
      chain.epAsks.push(tx.data);
      const l = each ? each(n++) : lists;
      if (l instanceof Error) throw l;
      return coder.encode(['string[][]'], [l]);
    }
    if (to === RPCS_PIN && tx.data.startsWith('0xd77e4c79')) return coder.encode(['string[]'], [l1]);
    return ethCall(tx, block);
  };
  return chain;
}

const ev = (p, js) => p.window.eval(js);

describe('the endpoint roster', () => {
  test('asks for exactly the lists it uses, in one call per node', async () => {
    const chain = serve(new MockChain(), CURATED);
    const p = await loadPage({ walletless: true, chain });
    await p.settle();
    assert.equal(chain.epAsks.length, 2, 'two nodes, one call each');
    assert.equal(chain.epAsks[0], chain.epAsks[1]);
    const [svc, ids] = IFACE.decodeFunctionData('listsOf', chain.epAsks[0]);
    assert.deepEqual([...svc], ASKED.map(q => b32(q[0])));
    assert.deepEqual([...ids].map(Number), ASKED.map(q => q[1]));
    p.close();
  });

  test('curated lists land ahead of the built-in ones, which stay behind them', async () => {
    const chain = serve(new MockChain(), CURATED);
    const p = await loadPage({ walletless: true, chain });
    await p.settle();
    const base = ev(p, 'CHAINS[8453].rpcs');
    assert.equal(base[0], 'https://base.cur');
    assert.ok(base.includes('https://base.rpc.blxrbdn.com'), 'a built-in node was dropped');
    assert.equal(ev(p, 'CHAINS[4663].rpcs[0]'), 'https://rh.cur');
    assert.equal(ev(p, 'CP_LOGS[0]'), 'https://logs.cur');
    assert.ok(ev(p, 'CP_LOGS').includes('https://mainnet.gateway.tenderly.co'));
    assert.equal(ev(p, 'cpRelayBase()'), 'https://relay.cur', 'the relay, trailing slash trimmed');
    assert.equal(ev(p, 'B_API[0]'), 'https://btc.cur/api');
    assert.ok(ev(p, 'B_API').includes('https://mempool.space/api'));
    assert.equal(ev(p, 'WC_RELAY[0]'), 'wss://wc.cur');
    assert.equal(ev(p, 'WC_PID'), PID);
    assert.equal(ev(p, 'L1_RPCS[0]'), 'https://l1.cur', "zRpcList reaches the L1 read path too");
    assert.equal(ev(p, 'AD_API[0]'), 'https://ad.cur/proofs/', 'a curated airdrop mirror goes first');
    assert.deepEqual(JSON.parse(ev(p, 'JSON.stringify(TB_K[1])')), ['https://k1.cur']);
    assert.deepEqual(JSON.parse(ev(p, 'JSON.stringify(TB_K[8453])')), [], 'a keeper base ending in / is refused');
    assert.deepEqual(JSON.parse(ev(p, 'JSON.stringify(TB_K[4663])')), ['https://k4663.cur/keeper'], 'each chain keeps its own keepers');
    assert.ok(ev(p, 'AD_API').some(u => u.startsWith('https://cdn.jsdelivr.net/')), 'the built-in mirrors stay behind it');
    const kept = JSON.parse(p.window.localStorage.getItem('zswap:ep3'));
    assert.ok(kept && kept.t > 0 && kept.v.length === 12, 'the answer is kept for the next load');
    assert.deepEqual(p.consoleErrors, []);
    p.close();
  });

  test('a viewer who picked a relay keeps it over the curated one', async () => {
    const chain = serve(new MockChain(), CURATED);
    const p = await loadPage({ walletless: true, chain, storage: { 'zswap:cprelay': 'https://mine.example' } });
    await p.settle();
    assert.equal(ev(p, 'cpRelayBase()'), 'https://mine.example');
    p.close();
  });

  test('a Base page reads through the curated Base node first', async () => {
    const chain = serve(new MockChain({ chainId: '0x2105' }), CURATED);
    const p = await loadPage({ walletless: true, chain });
    await p.settle();
    assert.equal(ev(p, 'CHAIN_ID'), 8453);
    assert.equal(ev(p, 'rpcPool[0]'), 'https://base.cur');
    assert.equal(chain.epAsks.length, 2, 'the roster is read from mainnet on an L2 too');
    p.close();
  });

  test('entries the page cannot use are dropped and the rest kept', async () => {
    const chain = serve(new MockChain(), [
      ['ftp://x', ' https://ok.cur ', 'https://has space'], [], ['http://plain'],
      ['http://insecure', 'javascript:alert(1)', 'https://relay.cur/a?b=1'],
      ['https://btc.cur/api'], ['https://not-a-socket', 'wss://wc.cur/path'], ['XYZ', 'AB'.repeat(16)],
      ['https://ad.cur/proofs', 'http://ad.cur/proofs/', 'https://ad.cur/p/?x=1/'], [], [], [],
    ], { l1: ['http://l1.plain'] });
    const p = await loadPage({ walletless: true, chain });
    await p.settle();
    assert.equal(ev(p, 'CHAINS[8453].rpcs[0]'), 'https://ok.cur', 'trimmed and kept');
    assert.ok(!ev(p, 'CHAINS[8453].rpcs').some(u => /ftp|space/.test(u)));
    assert.ok(!ev(p, 'CP_LOGS').includes('http://plain'));
    assert.equal(ev(p, 'cpRelayBase()'), 'https://api.tacit.finance', 'no usable relay: the built-in one stays');
    assert.equal(ev(p, 'WC_RELAY').length, 1, 'no usable socket: the built-in relay stays');
    assert.equal(ev(p, 'WC_PID'), '1e8390ef1c1d8a185e035912a1409749', 'upper-case and short ids refused');
    assert.ok(!ev(p, 'L1_RPCS').includes('http://l1.plain'));
    assert.equal(ev(p, 'AD_API').length, 2, 'a mirror that is not an https folder is skipped');
    p.close();
  });

  test('a roster kept by an older page, in the old order, is not applied', async () => {
    const chain = serve(new MockChain(), CURATED);
    const old = [['https://b.old'], [], [], [], [], [], [], ['https://l1.old']];
    const p = await loadPage({ walletless: true, chain, storage: { 'zswap:ep': JSON.stringify({ t: Date.now(), v: old }) } });
    await p.settle();
    assert.ok(!ev(p, 'AD_API').includes('https://l1.old'), 'an L1 node never lands among the airdrop mirrors');
    assert.equal(chain.epAsks.length, 2, 'the roster is read afresh');
    p.close();
  });

  test('a roster kept before the keeper lists, with L1 nodes at slot 8, is not applied', async () => {
    const chain = serve(new MockChain(), CURATED.map(() => []));
    const old = [[], [], [], [], [], [], [], [], ['https://l1.old']];
    const p = await loadPage({ walletless: true, chain, storage: { 'zswap:ep2': JSON.stringify({ t: Date.now(), v: old }) } });
    await p.settle();
    assert.deepEqual(JSON.parse(ev(p, 'JSON.stringify(TB_K[1])')), [], 'an L1 node never becomes a keeper');
    assert.equal(chain.epAsks.length, 2, 'the roster is read afresh');
    p.close();
  });

  test('a roster only one node vouches for is not adopted', async () => {
    const chain = serve(new MockChain(), null, {
      each: n => (n === 0 ? CURATED : CURATED.map(() => [])),
    });
    const p = await loadPage({ walletless: true, chain });
    await p.settle();
    assert.equal(ev(p, 'cpRelayBase()'), 'https://api.tacit.finance');
    assert.notEqual(ev(p, 'CHAINS[8453].rpcs[0]'), 'https://base.cur');
    assert.equal(p.window.localStorage.getItem('zswap:ep3'), null, 'nothing kept from a split answer');
    p.close();
  });

  test('a kept roster applies at once, and a fresh one is not asked for again', async () => {
    const chain = serve(new MockChain(), CURATED.map(() => []));
    const v = CURATED.concat([['https://l1.cur']]);
    const p = await loadPage({
      walletless: true, chain,
      storage: { 'zswap:ep3': JSON.stringify({ t: Date.now(), v }) },
    });
    await p.settle();
    assert.equal(ev(p, 'cpRelayBase()'), 'https://relay.cur');
    assert.equal(ev(p, 'CHAINS[4663].rpcs[0]'), 'https://rh.cur');
    assert.equal(chain.epAsks.length, 0, 'a fresh copy was asked for anyway');
    p.close();
  });

  test('a stale kept roster still applies while the refresh runs', async () => {
    const chain = serve(new MockChain(), CURATED.map(() => []));
    const v = CURATED.concat([[]]);
    const p = await loadPage({
      walletless: true, chain,
      storage: { 'zswap:ep3': JSON.stringify({ t: Date.now() - 7 * 3600e3, v }) },
    });
    await p.settle();
    assert.equal(chain.epAsks.length, 2, 'a stale copy must be refreshed');
    assert.equal(ev(p, 'cpRelayBase()'), 'https://relay.cur', 'an empty refresh does not unlist what was kept');
    p.close();
  });

  test('a roster that cannot be read leaves every built-in endpoint in place', async () => {
    const chain = serve(new MockChain(), null, { each: () => new Error('execution reverted') });
    const p = await loadPage({ walletless: true, chain });
    await p.settle();
    assert.equal(ev(p, 'cpRelayBase()'), 'https://api.tacit.finance');
    assert.deepEqual([...ev(p, 'B_API')], ['https://mempool.space/api', 'https://blockstream.info/api']);
    assert.deepEqual([...ev(p, 'WC_RELAY')], ['wss://relay.walletconnect.org']);
    assert.deepEqual(p.consoleErrors, []);
    p.close();
  });
});
