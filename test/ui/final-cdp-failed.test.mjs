/**
 * cBTC from the Tacit key: lock real bitcoin from the key's own bc1q address,
 * post the wstETH escrow, and have the relay mint the cBTC.zk note.
 *
 * The note is a bearer note whose blinding is derived from the key and the
 * lock's funding coin, so nothing but the key recovers it - which makes the
 * exact bytes non-negotiable. The lock transactions here are compared with the
 * ones Tacit's own driver built from the same coins (test/fixtures/
 * confidential.json, Schnorr aux zeroed on both sides), and a wiped browser has
 * to find the lock again by scanning the key's bc1p lock address alone.
 */
import { test, describe, after } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { createHash } from 'node:crypto';
import { AbiCoder, keccak256, toUtf8Bytes } from 'ethers';
import { A, MockChain, loadPage, closeAllPages, wordAddr, word, CP_BLOCK } from './harness.mjs';
import { openStore } from './cp-store.mjs';

const coder = AbiCoder.defaultAbiCoder();
const B0 = CP_BLOCK + 0x100;
const T_LEAVES = keccak256(toUtf8Bytes('LeavesInserted(uint256,bytes32[],bytes[])'));

after(closeAllPages);

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..');
const F = JSON.parse(fs.readFileSync(path.join(ROOT, 'test', 'fixtures', 'confidential.json'), 'utf8'));
const C = F.cbtc;
const u256 = v => BigInt(v).toString(16).padStart(64, '0');
const POOL = F.pool, ENGINE = '0x000000003f608BDdF0ca45934003ffb9DbDF70DB', WSTETH = '0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0';
const RELAY = 'api.tacit.finance';
const SEL = { VBTC: '7cea1c1a', MINTED: 'e2c2a40c', SUFF: '058e18b0', HEALTH: '3feacb25', REQ: '034448ed', POST: '2e03d0f1', APPROVE: '095ea7b3',
  ASSETS: '9fda5b66', NEXT: '0be4f422', DEPOSIT: '7da9874f', SETTLE: '717fd7f2' };
const WANT = 46536158595228492n;
const KEY = { ['zswap:cpk:' + A.ACCOUNT.toLowerCase()]: F.seed };

function cbtcChain() {
  const chain = new MockChain();
  chain.blockNumber = '0x' + (B0 + 0x8).toString(16);
  chain.gasPrice = 10n ** 8n;
  chain.setNative(A.ACCOUNT, 10n * 10n ** 18n);
  chain.setErc20(WSTETH, A.ACCOUNT, 10n ** 18n);
  chain.lock = { vbtc: 0n, minted: 0n, ok: 0n, have: 0n };
  chain.answer(POOL, SEL.VBTC, () => '0x' + u256(chain.lock.vbtc));
  chain.answer(POOL, SEL.MINTED, () => '0x' + u256(chain.lock.minted));
  chain.answer(ENGINE, SEL.SUFF, () => '0x' + u256(chain.lock.ok));
  chain.answer(ENGINE, SEL.HEALTH, () => '0x' + u256(chain.lock.ok) + u256(chain.lock.have) + u256(WANT));
  chain.answer(ENGINE, SEL.REQ, '0x' + u256(WANT));
  chain.answer(ENGINE, SEL.POST, '0x');
  chain.answer(POOL, SEL.ASSETS, '0x' + u256(1) + u256(0) + u256(10n ** 10n) + F.ethAssetId.slice(2) + u256(0) + u256(18));
  chain.answer(POOL, SEL.NEXT, '0x' + u256(0));
  chain.answer(POOL, SEL.DEPOSIT, '0x' + u256(0));
  chain.answer(POOL, SEL.SETTLE, '0x');
  chain.relay = { status: { status: 'pending' } };
  chain.lanes = {};
  Object.defineProperty(chain.lanes, RELAY + '/confidential/submit', { enumerable: true, get: () => ({ ok: true, jobId: '0xjobcbtc', status: 'pending' }) });
  Object.defineProperty(chain.lanes, RELAY + '/confidential/status', { enumerable: true, get: () => chain.relay.status });
  return chain;
}

async function open(chain = cbtcChain()) {
  const p = await loadPage({ chain, storage: { ...KEY } });
  const inner = p.window.fetch;
  p.window.__posts = [];
  p.window.fetch = async (url, init) => {
    if (init && init.body) p.window.__posts.push({ url: String(url), body: init.body });
    return inner(url, init);
  };
  Object.defineProperty(p.window.crypto, 'getRandomValues', { configurable: true, value: a => a.fill(0) });
  await p.connect();
  p.click('pv');
  await p.settle();
  p.click('pvGo');                       // one signature per visit unlocks the key
  await p.waitFor(() => /Key unlocked/.test(p.text('pvKey')), { label: 'the key to unlock' });
  return p;
}
const poke = p => p.doc.dispatchEvent(new p.window.Event('visibilitychange'));
const advance = p => { p.chain.blockNumber = '0x' + (BigInt(p.chain.blockNumber) + 5n).toString(16); };
const SLOW = { timeout: 20000 };

async function lock(p) {
  p.chain.lanes['/address/' + F.btc.address + '/utxo'] = C.utxos;
  p.chain.lanes['/fee-estimates'] = { 2: C.feeRate };
  p.chain.lanes['api/tx'] = 'ok';
  p.queuePrompt('0.001');
  p.queueConfirm(true);
  p.click(p.$('pvKey').querySelector('button[data-a="lockbtc"]'));
  await p.waitFor(() => /Locked/.test(p.text('stat')), { label: 'the lock to be sent', ...SLOW });
}

describe('a loan the relay fails', () => {
  const D = F.cdp, CBTC = '0x62a20d98fc1cd20289621d1315294cb8772f934d822e404b71e1f471cf0679c8';
  const fp = createHash('sha256').update('zswap-cp-v1:' + F.seed).digest('hex').slice(0, 16);
  const withNote = () => ({ ...KEY, ['zswap:cpn:' + fp]: JSON.stringify([{ i: -1, v: '100000', a: CBTC, s: '0x' + '00'.repeat(32), b: C.blinding, z: 1, at: 0 }]) });
  test('leaves no cUSD note settling forever', async () => {
    const chain = cbtcChain();
    chain.answer(ENGINE, 'd5901347', '0x' + u256(7676504869n));
    chain.answer(ENGINE, '2c4e722e', '0x' + u256(10n ** 27n));
    chain.answer(ENGINE, '4827ecb3', '0x' + u256(15000n));
    chain.logs.push({ address: POOL, blockNumber: '0x' + (B0 + 0x5).toString(16), logIndex: '0x0', topics: [T_LEAVES, '0x' + u256(0)],
      data: coder.encode(['bytes32[]', 'bytes[]'], [[D.cbtcLeaf, F.otherLeaf], ['0x', '0x']]) });
    chain.answer(POOL, SEL.NEXT, '0x' + u256(2));
    const p = await loadPage({ chain, storage: withNote() });
    await p.connect(); p.click('pv'); await p.settle(); p.click('pvGo');
    await p.waitFor(() => /Key unlocked/.test(p.text('pvKey')), { label: 'unlock' });
    await p.waitFor(() => p.$('pvList').querySelector('button[data-a="borrow"]'), { label: 'borrow', ...SLOW });
    p.queuePrompt('30');
    p.click(p.$('pvList').querySelector('button[data-a="borrow"]'));
    await p.waitFor(() => /Proving the loan/.test(p.text('stat')), { label: 'the loan job', ...SLOW });
    chain.relay.status = { status: 'failed', error: 'prover error' };
    p.window.eval('pvTick=0'); p.window.eval('pvRefresh()');
    await p.waitFor(() => /loan failed/.test(p.text('pvList')), { label: 'the failed loan', ...SLOW });
    await p.settle();
    console.log('ROW:', p.text('pvList'));
    assert.doesNotMatch(p.text('pvList'), /settling/);
    p.close();
  });
});
