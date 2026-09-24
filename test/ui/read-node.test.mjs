/**
 * The read node a person pins for themselves.
 *
 * Reads leave the page over plain HTTPS: for a visitor with no extension, and
 * for every WalletConnect session, they go through the page's pool rather than
 * through a wallet. Anyone who has their own node — or who cannot reach the
 * public ones at all — needs a way to say so, on whichever chain they are on,
 * and the pin has to be the very first endpoint tried.
 *
 * These pin the store (one key per chain), the honouring of the pin on all
 * three chains, and the picker entry that is the only way most people will
 * ever find it.
 *
 * Run: node --test --test-concurrency=1 test/ui/read-node.test.mjs
 */
import { test, describe, after } from 'node:test';
import assert from 'node:assert/strict';
import { A, MockChain, loadPage, closeAllPages } from './harness.mjs';

after(closeAllPages);

const ETH = 10n ** 18n;
const PIN = 'https://node.example/rpc';
const PIN2 = 'https://other.example/rpc';

const CHAINS = [
  { id: 1, hex: '0x1', key: 'zswap:rpc', name: 'mainnet' },
  { id: 8453, hex: '0x2105', key: 'zswap:rpc:8453', name: 'Base' },
  { id: 4663, hex: '0x1237', key: 'zswap:rpc:4663', name: 'Robinhood' },
];

const open = (c, storage = {}) => {
  const chain = new MockChain({ chainId: c.hex });
  chain.setNative(A.ACCOUNT, 10n * ETH);
  return loadPage({ walletless: true, chain, storage });
};

const used = p => (p.chain.httpLog || []).map(r => r.url);

describe('a pinned read node', () => {
  for (const c of CHAINS) {
    test(`is used ahead of the pool on ${c.name}`, async () => {
      const p = await open(c, { [c.key]: PIN });
      assert.equal(p.window.eval('CHAIN_ID'), c.id, 'the page seated the chain under test');
      assert.equal(p.window.eval('rpcPin()'), PIN, 'the page did not read its own store');
      const log = used(p);
      assert.ok(log.length, 'no read ever left the page');
      assert.ok(log.some(u => u.startsWith(PIN)), `the pin was never tried (saw ${log.slice(0, 3)})`);
      p.close();
    });
  }

  test('is kept per chain — a Base pin leaves mainnet on the pool', async () => {
    const base = await open(CHAINS[1], { 'zswap:rpc:8453': PIN });
    assert.equal(base.window.eval('wcNode()'), PIN, 'Base ignored its own pin');
    base.close();
    // The same store, read from mainnet: the Base key is not mainnet's key.
    const main = await open(CHAINS[0], { 'zswap:rpc:8453': PIN });
    assert.equal(main.window.eval('rpcPin()'), '', 'the Base pin leaked onto mainnet');
    assert.ok(!used(main).some(u => u.startsWith(PIN)), 'mainnet read through the Base pin');
    main.close();
  });

  test('falls back to the pool once it is cleared', async () => {
    const p = await open(CHAINS[0], { 'zswap:rpc': PIN });
    const w = p.window;
    p.queuePrompt('');
    assert.equal(await w.eval('askReadNode()'), true, 'clearing was refused');
    assert.equal(w.localStorage.getItem('zswap:rpc'), null, 'the pin survived a blank answer');
    assert.equal(w.eval('rpcPin()'), '', 'the page still reports a pin');
    assert.equal(w.eval('wcNode()'), w.eval('rpcPool[rpcPi]'), 'reads did not return to the pool');
    p.close();
  });

  test('refuses anything that is not https, and keeps what is already pinned', async () => {
    const p = await open(CHAINS[0], { 'zswap:rpc': PIN });
    const w = p.window;
    for (const bad of ['http://node.example/rpc', 'ws://node.example', 'node.example', 'javascript:alert(1)']) {
      p.queuePrompt(bad);
      assert.equal(await w.eval('askReadNode()'), false, `${bad} was accepted`);
      assert.equal(w.localStorage.getItem('zswap:rpc'), PIN, `${bad} displaced the pin`);
    }
    p.queuePrompt(PIN2);
    assert.equal(await w.eval('askReadNode()'), true, 'a valid https node was refused');
    assert.equal(w.localStorage.getItem('zswap:rpc'), PIN2, 'the new node was not stored');
    assert.equal(w.eval('wcNode()'), PIN2, 'reads did not move to the new node');
    p.close();
  });
});

describe('the network picker', () => {
  test('offers the read node under the chains, showing the one in use', async () => {
    const p = await open(CHAINS[1], { 'zswap:rpc:8453': PIN });
    p.click('net');
    await p.settle();
    const rows = [...p.$('wkList').querySelectorAll('.tkr')];
    const last = rows[rows.length - 1];
    assert.match(last.textContent, /^Read node/, 'no read-node row under the chains');
    assert.match(last.textContent, /node\.example/, 'the row does not name the node in use');
    p.queuePrompt(PIN2);
    p.click(last);
    await p.settle();
    await p.waitFor(() => p.window.localStorage.getItem('zswap:rpc:8453') === PIN2,
      { label: 'the picked node to be stored' });
    assert.equal(p.window.eval('wcNode()'), PIN2);
    assert.equal(p.reloads(), 0, 'changing the read node reloaded the page');
    p.close();
  });

  test('stores a node picked on Base under Base, not under mainnet', async () => {
    const p = await open(CHAINS[1]);
    p.queuePrompt(PIN);
    assert.equal(await p.window.eval('askReadNode()'), true);
    assert.equal(p.window.localStorage.getItem('zswap:rpc'), null, 'Base wrote mainnet\'s key');
    assert.equal(p.window.localStorage.getItem('zswap:rpc:8453'), PIN);
    p.close();
  });
});
