/**
 * What the page binds to the wallet's chain, and what it refuses to.
 *
 * Every send used to compare the wallet's chain to the literal 1, so a wallet
 * on Base or Robinhood quoted fine and then died at the button with "wallet
 * changed". The Permit2 domain, the Curve ordinal, the custom-token store and
 * the explorer links were pinned to mainnet the same way. These pin the
 * chain-bound behaviour on both sides of the line.
 */
import { test, describe, after } from 'node:test';
import assert from 'node:assert/strict';
import { A, MockChain, loadPage, closeAllPages } from './harness.mjs';

after(closeAllPages);

const ETH = 10n ** 18n;
const BASE = '0x2105';
const MOON = '0x' + '77'.repeat(20);
const MAIN = '0x' + '88'.repeat(20);

const onBase = (extra = {}) => {
  const chain = new MockChain({ chainId: BASE });
  chain.setNative(A.ACCOUNT, 10n * ETH);
  return loadPage({ chain, hash: null, ...extra });
};

describe('a wallet on Base', () => {
  test('is allowed to send, and is not told it changed', async () => {
    const p = await onBase();
    await p.connect({ pin: false });
    assert.equal(p.window.eval('CHAIN_ID'), 8453);
    p.pickToken('fromSel', 'ETH');
    p.pickToken('toSel', 'WETH');
    await p.settle();
    await p.typeAmount('amt', '2');
    p.click('swap');
    await p.waitFor(() => p.chain.sent.length > 0 || /Error/.test(p.text('stat')), { label: 'send' });
    assert.doesNotMatch(p.text('stat'), /wallet changed|Switch your wallet/, 'the wallet is on the page\'s chain');
    assert.equal(p.chain.sent.length, 1, 'the wrap is sent');
    p.close();
  });

  test('binds the chain-scoped state to the chain, not to mainnet', async () => {
    const p = await onBase();
    await p.connect({ pin: false });
    const w = p.window;
    assert.equal(w.eval('P2DOM().chainId'), 8453, 'Permit2 typed data names the live chain');
    assert.equal(w.eval('SRC_CURVE'), -1, 'the Curve ordinal is the chain table\'s, not update()\'s');
    assert.equal(w.eval('STORE()'), 'zswap:custom:8453', 'custom tokens are kept per chain');
    assert.match(w.eval('txLink("0x" + "ab".repeat(32), "Done")'), /basescan\.org\/tx\//, 'tx links go to the chain\'s explorer');
    assert.match(w.eval('escan("' + MOON + '")'), /basescan\.org\/token\//);
    assert.equal(p.visible('ln'), false, 'launch mode is withheld where the launcher is not deployed');
    assert.equal(p.visible('wn'), false, 'names are registered on mainnet only');
    p.close();
  });

  test('restores the custom tokens kept for that chain and not mainnet\'s', async () => {
    const p = await onBase({ storage: {
      'zswap:custom': JSON.stringify([{ sym: 'MAIN', addr: MAIN, dec: 18, std: 'ft' }]),
      'zswap:custom:8453': JSON.stringify([{ sym: 'MOON', addr: MOON, dec: 18, std: 'ft' }]),
    } });
    await p.connect({ pin: false });
    const syms = [...p.$('fromSel').options].map(o => o.textContent);
    assert.ok(syms.includes('MOON'), `Base custom token restored (have ${syms})`);
    assert.ok(!syms.includes('MAIN'), 'mainnet custom token does not leak into Base');
    p.close();
  });
});

describe('a wallet on mainnet', () => {
  test('keeps the mainnet bindings', async () => {
    const chain = new MockChain();
    chain.setNative(A.ACCOUNT, 10n * ETH);
    const p = await loadPage({ chain });
    await p.connect();
    const w = p.window;
    assert.equal(w.eval('CHAIN_ID'), 1);
    assert.equal(w.eval('P2DOM().chainId'), 1);
    assert.equal(w.eval('SRC_CURVE'), 5);
    assert.equal(w.eval('STORE()'), 'zswap:custom');
    assert.match(w.eval('txLink("0x" + "ab".repeat(32), "Done")'), /etherscan\.io\/tx\//);
    assert.equal(w.eval('BOARDS().length'), 2);
    assert.equal(p.visible('ln'), true);
    p.close();
  });

  test('names the chain to switch to when the wallet has moved under the page', async () => {
    const chain = new MockChain();
    chain.setNative(A.ACCOUNT, 10n * ETH);
    const p = await loadPage({ chain });
    await p.connect({ pin: false });
    p.pickToken('fromSel', 'ETH');
    p.pickToken('toSel', 'WETH');
    await p.settle();
    await p.typeAmount('amt', '1');
    // The wallet answers eth_chainId with Base from here on, without emitting
    // chainChanged, which is what a wallet mid-switch looks like.
    chain.chainId = BASE;
    p.click('swap');
    await p.waitFor(() => p.text('stat') !== '', { label: 'refusal' });
    assert.match(p.text('stat'), /Switch your wallet to Ethereum/);
    assert.equal(chain.sent.length, 0, 'nothing is sent to the wrong chain');
    p.close();
  });

  test('a link for another chain is named rather than silently misapplied', async () => {
    const chain = new MockChain();
    const p = await loadPage({ chain, hash: 'token=ETH&out=USDC&chain=8453' });
    await p.waitFor(() => /This link is for Base/.test(p.text('stat')), { label: 'chain notice' });
    p.close();
  });
});

describe('share links', () => {
  test('carry the chain off mainnet and omit it on mainnet', async () => {
    const p = await onBase();
    await p.connect({ pin: false });
    p.click('lk');
    await p.settle();
    assert.match(String(p.copied()), /chain=8453/);
    p.close();
    const chain = new MockChain();
    const q = await loadPage({ chain });
    await q.connect();
    q.click('lk');
    await q.settle();
    assert.doesNotMatch(String(q.copied()), /chain=/);
    q.close();
  });
});
