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

describe('locking bitcoin into cBTC', () => {
  test('the page broadcasts exactly the lock Tacit\'s own driver builds', async () => {
    const p = await open();
    await lock(p);
    const sent = p.window.__posts.filter(x => /\/tx$/.test(x.url)).map(x => x.body);
    assert.deepEqual([...new Set(sent)], [C.commit, C.reveal], 'commit then reveal, byte for byte');
    const rec = JSON.parse(p.window.localStorage[Object.keys(p.window.localStorage).find(k => k.startsWith('zswap:cpl:'))])[0];
    assert.equal(rec.t, C.lockTxid);
    assert.equal(rec.b, C.blinding, 'the note blinding derived from the key and the funding coin');
    assert.equal(rec.an, C.anchor.txid + ':' + C.anchor.vout, 'anchored to the coin the lock spends first');
    assert.match(p.text('pvList'), /0\.001 BTC lock/);
    assert.match(p.text('pvList'), /awaiting confirmations/);
    await p.settle();
    p.close();
  });

  test('the lock is funded only from plain coins: never a coin that carries a Tacit note, and never dust', async () => {
    const B = F.btcNote, chain = cbtcChain();
    // Ahead of the catch-all broadcast lane below, so the note scan reads this transaction.
    chain.lanes['/tx/' + B.txid] = B.tx;
    const p = await open(chain);
    // This key's received note and its change (vouts 0 and 1), priced to be the first coins a lock would take.
    p.chain.lanes['/address/' + F.btc.address + '/utxo'] = [
      { txid: B.txid, vout: 0, value: 100001 }, { txid: B.txid, vout: 1, value: 100001 },
      { txid: B.txid, vout: 2, value: 546 }, { txid: B.txid, vout: 3, value: 546 }, ...C.utxos];
    p.chain.lanes['/fee-estimates'] = { 2: C.feeRate };
    p.chain.lanes['api/tx'] = 'ok';
    p.queuePrompt('0.001');
    p.queueConfirm(true);
    p.click(p.$('pvKey').querySelector('button[data-a="lockbtc"]'));
    await p.waitFor(() => /Locked/.test(p.text('stat')), { label: 'the lock to be sent', ...SLOW });
    const sent = [...new Set(p.window.__posts.filter(x => /\/tx$/.test(x.url)).map(x => x.body))];
    assert.deepEqual(sent, [C.commit, C.reveal], 'exactly the lock the plain coins alone make');
    const noteTx = Buffer.from(B.txid, 'hex').reverse().toString('hex');
    assert.ok(!sent.some(h => h.includes(noteTx)), 'no input spends the note transaction');
    await p.settle();
    p.close();
  });

  test('once recorded, wstETH already held is posted with one permit signature, then the relay mints fee-free', async () => {
    const chain = cbtcChain(), HELPER = '0x000000008ecd09f922c9fbbdd9aca5ae8f0bebfa';
    chain.answer(WSTETH, '7ecebe00', '0x' + u256(0));
    chain.answer(WSTETH, '3644e515', keccak256(coder.encode(['bytes32', 'bytes32', 'bytes32', 'uint256', 'address'], [
      keccak256(toUtf8Bytes('EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)')),
      keccak256(toUtf8Bytes('Wrapped liquid staked Ether 2.0')), keccak256(toUtf8Bytes('1')), 1, WSTETH])));
    chain.answer(HELPER, '20ef3f6b', '0x');
    const p = await open(chain);
    await lock(p);
    p.chain.lock.vbtc = BigInt(C.amountSats);
    advance(p);
    poke(p);
    await p.waitFor(() => p.$('pvList').querySelector('button[data-a="lesc"]'), { label: 'the escrow button', ...SLOW });
    p.queueConfirm(true);
    p.click(p.$('pvList').querySelector('button[data-a="lesc"]'));
    await p.waitFor(() => p.chain.sentTo(HELPER).length === 1, { label: 'postEscrowWithPermit', ...SLOW });
    const add = WANT * 105n / 100n, tx = p.chain.sentTo(HELPER)[0], td = p.chain.signed.at(-1).typedData;
    assert.equal(td.domain.verifyingContract.toLowerCase(), WSTETH.toLowerCase(), 'a wstETH permit');
    assert.equal(td.message.spender.toLowerCase(), HELPER.toLowerCase(), 'for the helper to pull');
    assert.equal(td.message.value, String(add), 'the escrow plus 5% headroom');
    assert.equal(tx.data.slice(0, 10 + 128), '0x20ef3f6b' + C.outpoint.slice(2) + u256(add), 'postEscrowWithPermit(outpoint, amount, …)');
    assert.ok(tx.data.endsWith('11'.repeat(32) + '22'.repeat(32)), 'the signature rides in the call');
    assert.equal(p.chain.sentTo(WSTETH).length, 0, 'no standing approval is ever sent');

    p.chain.lock.ok = 1n;
    p.chain.lock.have = add;
    advance(p);
    poke(p);
    await p.waitFor(() => p.$('pvList').querySelector('button[data-a="lmint"]'), { label: 'the mint button', ...SLOW });
    p.click(p.$('pvList').querySelector('button[data-a="lmint"]'));
    await p.waitFor(() => p.window.__posts.some(x => x.url.includes('/confidential/submit')), { label: 'the mint to reach the relay', ...SLOW });
    const job = JSON.parse(p.window.__posts.find(x => x.url.includes('/confidential/submit')).body);
    assert.equal(job.type, 'cbtcmint');
    assert.equal(job.mode, 'settle');
    assert.deepEqual(job.memos, ['0x'], 'a bearer note carries no memo');
    assert.deepEqual(job.op, C.mintOp, 'the op Tacit\'s buildCbtcMintOp makes for this lock');

    p.chain.lock.minted = 1n;
    p.chain.relay.status = { status: 'settled' };
    advance(p);
    poke(p);
    await p.waitFor(() => /minted as cBTC/.test(p.text('pvList')), { label: 'the minted lock', ...SLOW });
    await p.settle();
    p.close();
  });
});

describe('escrow through CbtcEscrowHelper', () => {
  const HELPER = '0x000000008ecd09f922c9fbbdd9aca5ae8f0bebfa', HELPER0 = '0x00000000689c71e690e5842df088af97f9d4f71b';
  const STETH_PER = 1243945528957798802n;                    // stETH per wstETH, as the live token quoted it
  const helperChain = () => {
    const chain = cbtcChain();
    chain.setErc20(WSTETH, A.ACCOUNT, 0n);
    chain.answer(WSTETH, 'bb2952fc', data => '0x' + u256(word('0x' + data.slice(10), 0) * STETH_PER / 10n ** 18n));
    for (const s of ['20ef3f6b', 'c0e2d9a1', '2bb12527']) chain.answer(HELPER, s, '0x');
    return chain;
  };
  const recorded = async p => {
    await lock(p);
    p.chain.lock.vbtc = BigInt(C.amountSats);
    advance(p);
    poke(p);
    await p.waitFor(() => p.$('pvList').querySelector('button[data-a="lone"]'), { label: 'the escrow actions', ...SLOW });
  };

  test('with no wstETH in the wallet, the escrow is paid in ETH and staked by the helper', async () => {
    const p = await open(helperChain());
    await recorded(p);
    p.queueConfirm(true);
    p.click(p.$('pvList').querySelector('button[data-a="lesc"]'));
    await p.waitFor(() => p.chain.sentTo(HELPER).length === 1, { label: 'postEscrowWithETH', ...SLOW });
    const tx = p.chain.sentTo(HELPER)[0], add = WANT * 105n / 100n;
    assert.equal(tx.data, '0xc0e2d9a1' + C.outpoint.slice(2), 'postEscrowWithETH(outpoint)');
    assert.equal(BigInt(tx.value), add * STETH_PER / 10n ** 18n * 1005n / 1000n + 1n, 'wstETH\'s own ETH quote for the escrow, plus 0.5%');
    assert.equal(p.chain.sentTo(WSTETH).length, 0, 'no approval: the helper stakes the ETH itself');
    await p.settle();
    p.close();
  });

  // The same one transaction, with the relay quoting for the proof it made. Only
  // `stakeAmount` reaches the helper, which the forwarder calls naming this
  // wallet as the depositor; the rest of msg.value is the tip. The head grows
  // from four words to six, so the bytes offsets all move.
  test('escrow, mint and the relay\'s pay ride one transaction, through the forwarder bound to the current helper', async () => {
    const EFWD = '0x000000006fcb52aa67ac4a420a4d43a0e48f136f';
    const p = await open(helperChain());
    Object.defineProperty(p.chain.lanes, RELAY + '/confidential/quote', {
      configurable: true, enumerable: true,
      get: () => ({ ticker: 'cETH', relayFeeEligible: true, recommendedProveTipWei: '90000000000000' }),
    });
    p.chain.answer(EFWD, 'ef3dc43b', '0x');
    await recorded(p);
    p.click(p.$('pvList').querySelector('button[data-a="lone"]'));
    await p.waitFor(() => p.window.__posts.some(x => x.url.includes('/confidential/submit')), { label: 'the proof request', ...SLOW });
    const pv = '0x' + '12'.repeat(64) + C.outpoint.slice(2), pr = '0x' + 'ab'.repeat(260);
    p.chain.relay.status = { status: 'proven', publicValues: pv, proof: pr };
    advance(p);
    poke(p);
    await p.waitFor(() => !!p.$('pvList').querySelector('button[data-a="lsettle"]'), { label: 'the one-transaction button', ...SLOW });
    p.queueConfirm(true);
    p.click(p.$('pvList').querySelector('button[data-a="lsettle"]'));
    await p.waitFor(() => p.chain.sentTo(EFWD).length === 1, { label: 'postEscrowWithETHAndSettleWithTip', ...SLOW });
    const tx = p.chain.sentTo(EFWD)[0];
    assert.equal(tx.data.slice(2, 10), 'ef3dc43b');
    const [op, stake, pvOut, prOut, memos, to] =
      coder.decode(['bytes32', 'uint256', 'bytes', 'bytes', 'bytes[]', 'address'], '0x' + tx.data.slice(10));
    assert.equal(op, C.outpoint);
    assert.equal(pvOut, pv, 'the offsets still land on the proof, six head words in');
    assert.equal(prOut, pr);
    assert.deepEqual([...memos], ['0x']);
    assert.equal(to.toLowerCase(), '0x006cd14f36f65ecbb29b2519ccbe63a0dc8549f2', 'the payee the page carries');
    assert.equal(BigInt(tx.value) - stake, 90000000000000n, 'exactly the tip rides above the stake');
    assert.ok(stake > 0n, 'and the stake is what the helper receives');
    assert.equal(p.chain.sentTo(HELPER).length, 0, 'nothing goes to the helper directly');
    assert.equal(p.chain.sentTo(HELPER0).length, 0, 'nor to the first helper');
    assert.equal(p.chain.sentTo(POOL).length, 0, 'the pool is settled from inside the helper');
    await p.settle();
    p.close();
  });

  test('a share posted to the first helper is reclaimed from the first helper', async () => {
    const chain = helperChain();
    chain.answer(HELPER0, '78808388', '0x' + u256(WANT));
    chain.answer(HELPER0, 'c5211d27', '0x');
    const p = await open(chain);
    await recorded(p);
    await p.waitFor(() => p.$('pvList').querySelector('button[data-a="lrecl"]'), { label: 'the reclaim button', ...SLOW });
    p.click(p.$('pvList').querySelector('button[data-a="lrecl"]'));
    await p.waitFor(() => p.chain.sentTo(HELPER0).length === 1, { label: 'reclaimEscrow', ...SLOW });
    assert.equal(p.chain.sentTo(HELPER0)[0].data, '0xc5211d27' + C.outpoint.slice(2));
    assert.equal(p.chain.sentTo(HELPER).length, 0, 'not the current helper, which holds nothing of this wallet\'s');
    await p.settle();
    p.close();
  });

  test('escrow and mint in one transaction: the relay only proves, the helper posts and settles', async () => {
    const p = await open(helperChain());
    await recorded(p);
    p.click(p.$('pvList').querySelector('button[data-a="lone"]'));
    await p.waitFor(() => p.window.__posts.some(x => x.url.includes('/confidential/submit')), { label: 'the proof request', ...SLOW });
    const job = JSON.parse(p.window.__posts.find(x => x.url.includes('/confidential/submit')).body);
    assert.equal(job.type, 'cbtcmint');
    assert.equal(job.mode, 'prove', 'the relay proves; the settle rides the helper transaction');
    assert.deepEqual(job.op, C.mintOp, 'still Tacit\'s fee-free mint op, so nothing is paid out to the helper');
    const pv = '0x' + '12'.repeat(64) + C.outpoint.slice(2), pr = '0x' + 'ab'.repeat(260);
    p.chain.relay.status = { status: 'proven', publicValues: pv, proof: pr };
    advance(p);
    poke(p);
    await p.waitFor(() => /escrow \+ mint/.test(p.text('pvList')) && p.$('pvList').querySelector('button[data-a="lsettle"]'), { label: 'the one-transaction button', ...SLOW });
    p.queueConfirm(true);
    p.click(p.$('pvList').querySelector('button[data-a="lsettle"]'));
    await p.waitFor(() => p.chain.sentTo(HELPER).length === 1, { label: 'postEscrowWithETHAndSettle', ...SLOW });
    const tx = p.chain.sentTo(HELPER)[0];
    assert.equal(tx.data.slice(2, 10), '2bb12527');
    const [op, pvOut, prOut, memos] = coder.decode(['bytes32', 'bytes', 'bytes', 'bytes[]'], '0x' + tx.data.slice(10));
    assert.equal(op, C.outpoint);
    assert.equal(pvOut, pv);
    assert.equal(prOut, pr);
    assert.deepEqual([...memos], ['0x'], 'a bearer note carries no memo');
    assert.ok(BigInt(tx.value) > 0n, 'the escrow rides as ETH');
    assert.equal(p.chain.sentTo(POOL).length, 0, 'the pool is settled from inside the helper, not separately');
    await p.settle();
    p.close();
  });
});

describe('borrowing cUSD against the cBTC note', () => {
  const D = F.cdp, CBTC = '0x62a20d98fc1cd20289621d1315294cb8772f934d822e404b71e1f471cf0679c8';
  const fp = createHash('sha256').update('zswap-cp-v1:' + F.seed).digest('hex').slice(0, 16);
  const withNote = () => ({ ...KEY, ['zswap:cpn:' + fp]: JSON.stringify([{ i: -1, v: '100000', a: CBTC, s: '0x' + '00'.repeat(32), b: C.blinding, z: 1, at: 0 }]) });
  const engine = chain => {
    chain.answer(ENGINE, 'd5901347', '0x' + u256(7676504869n));      // btcToUsd(100000 sats) ≈ $76.77
    chain.answer(ENGINE, '2c4e722e', '0x' + u256(10n ** 27n));       // rate(): RAY while the stability fee is dormant
    chain.answer(ENGINE, '4827ecb3', '0x' + u256(15000n));           // cdpRatioBps
  };

  test('the loan is the op Tacit\'s buildCdpMintOp makes, with the key-derived position and debt secrets', async () => {
    const chain = cbtcChain();
    engine(chain);
    chain.logs.push({ address: POOL, blockNumber: '0x' + (B0 + 0x5).toString(16), logIndex: '0x0', topics: [T_LEAVES, '0x' + u256(0)],
      data: coder.encode(['bytes32[]', 'bytes[]'], [[D.cbtcLeaf, F.otherLeaf], ['0x', '0x']]) });
    chain.answer(POOL, SEL.NEXT, '0x' + u256(2));
    const p = await loadPage({ chain, storage: withNote() });
    const inner = p.window.fetch;
    p.window.__posts = [];
    p.window.fetch = async (url, init) => { if (init && init.body) p.window.__posts.push({ url: String(url), body: init.body }); return inner(url, init); };
    await p.connect();
    p.click('pv');
    await p.settle();
    p.click('pvGo');
    await p.waitFor(() => /Key unlocked/.test(p.text('pvKey')), { label: 'the key to unlock' });
    await p.waitFor(() => p.$('pvList').querySelector('button[data-a="borrow"]'), { label: 'the borrow action on the cBTC note', ...SLOW });
    p.queuePrompt('30');
    p.click(p.$('pvList').querySelector('button[data-a="borrow"]'));
    await p.waitFor(() => p.window.__posts.some(x => x.url.includes('/confidential/submit')), { label: 'the loan to reach the relay', ...SLOW });
    const job = JSON.parse(p.window.__posts.find(x => x.url.includes('/confidential/submit')).body);
    assert.equal(job.type, 'cdpmint');
    // A loan op carries fee "0", and OP_CDP_MINT is fee-CAPABLE rather than
    // fee-less by design, so the relay's floor refuses to settle one for
    // nothing. The relay proves it and this wallet sends the settle, which the
    // prove tip pays for.
    assert.equal(job.mode, 'prove', 'a fee-less loan op is proved, never relayed');
    assert.deepEqual(job.op, D.op, 'byte-identical to Tacit\'s op for the same note, debt and key');
    assert.equal(job.memos.length, 1, 'one sealed memo, for the cUSD note');
    assert.match(job.memos[0], /^0x0[23][0-9a-f]{336}$/, 'ephemeral key (33 B) + ciphertext (136 B)');
    const pos = JSON.parse(p.window.localStorage['zswap:cpc:' + fp])[0];
    assert.equal(pos.leaf, D.positionLeaf, 'the position leaf Tacit computes');
    const notes = JSON.parse(p.window.localStorage['zswap:cpn:' + fp]);
    assert.ok(notes.some(n => n.s === D.debtNk && n.v === D.debtValue), 'the cUSD note is kept with its key-derived nk');
    await p.settle();
    p.close();
  });

  // The loan is kept before it is sent, so a lost answer never loses its keys; only the relay's own refusal takes it back.
  const borrowWith = async answer => {
    const chain = cbtcChain();
    engine(chain);
    chain.logs.push({ address: POOL, blockNumber: '0x' + (B0 + 0x5).toString(16), logIndex: '0x0', topics: [T_LEAVES, '0x' + u256(0)],
      data: coder.encode(['bytes32[]', 'bytes[]'], [[D.cbtcLeaf, F.otherLeaf], ['0x', '0x']]) });
    chain.answer(POOL, SEL.NEXT, '0x' + u256(2));
    const p = await loadPage({ chain, storage: withNote() });
    const inner = p.window.fetch;
    let asked = 0;
    p.window.fetch = async (url, init) => (String(url).includes('/confidential/submit') && init && /cdpmint/.test(init.body) ? (asked++, answer()) : inner(url, init));
    await p.connect();
    p.click('pv');
    await p.settle();
    p.click('pvGo');
    await p.waitFor(() => /Key unlocked/.test(p.text('pvKey')), { label: 'the key to unlock' });
    await p.waitFor(() => p.$('pvList').querySelector('button[data-a="borrow"]'), { label: 'the borrow action on the cBTC note', ...SLOW });
    p.queuePrompt('30');
    p.click(p.$('pvList').querySelector('button[data-a="borrow"]'));
    await p.waitFor(() => asked && !/Building the loan/.test(p.text('stat')), { label: 'the loan attempt to finish', ...SLOW });
    await p.settle();
    const cdps = JSON.parse(p.window.localStorage['zswap:cpc:' + fp] || '[]');
    const cusd = JSON.parse(p.window.localStorage['zswap:cpn:' + fp]).filter(n => n.s === D.debtNk);
    return { p, cdps, cusd };
  };

  test('a loan the relay refuses leaves no position and no cUSD note behind', async () => {
    const { p, cdps, cusd } = await borrowWith(async () => ({ ok: false, status: 400, json: async () => ({ error: 'bad op' }) }));
    assert.match(p.text('stat'), /bad op/);
    assert.equal(cdps.length, 0, 'no position the engine never opened');
    assert.equal(cusd.length, 0, 'no cUSD note the pool never minted');
    assert.doesNotMatch(p.text('pvList'), /cUSD against/);
    p.close();
  });

  test('a loan whose answer never comes back keeps its position and cUSD note', async () => {
    const { p, cdps, cusd } = await borrowWith(async () => { throw Object.assign(new Error('aborted'), { name: 'AbortError' }); });
    assert.match(p.text('stat'), /did not answer/);
    assert.equal(cdps.length, 1, 'the relay may have taken it, so the position stays');
    assert.equal(cdps[0].leaf, D.positionLeaf);
    assert.equal(cusd.length, 1, 'and so does the debt note\'s key');
    p.close();
  });

  test('a wiped browser finds the position again from the engine\'s CdpMinted event', async () => {
    const chain = cbtcChain();
    chain.logs.push({ address: ENGINE, blockNumber: '0x' + (B0 + 0x6).toString(16), logIndex: '0x0',
      topics: ['0x232c7d098ca44092999087e6ee530a2171f95f9ecb1caa363f6dcf448fb7dd57', D.positionLeaf], data: '0x' + u256(D.debtValue) + u256(7676504869n) });
    const p = await loadPage({ chain, storage: withNote() });
    await p.connect();
    p.click('pv');
    await p.settle();
    p.click('pvGo');
    await p.waitFor(() => /Key unlocked/.test(p.text('pvKey')), { label: 'the key to unlock' });
    p.click(p.$('pvKey').querySelector('button[data-a="recover"]'));
    await p.waitFor(() => /30 cUSD/.test(p.text('pvList')), { label: 'the position to be recovered', ...SLOW });
    assert.match(p.text('pvList'), /30 cUSD against 0\.001 cBTC/);
    await p.settle();
    p.close();
  });
});

describe('Tacit notes on Bitcoin', () => {
  test('the key alone finds the notes its Bitcoin address holds, received or change, and no one else\'s', async () => {
    const B = F.btcNote, chain = cbtcChain();
    chain.lanes['/address/' + F.btc.address + '/utxo'] = [0, 1, 2, 3].map(o => ({ txid: B.txid, vout: o, value: 546 }));
    chain.lanes['/tx/' + B.txid] = B.tx;
    // Tacit's reflection holds the received note but not (yet) the change.
    const [got, fresh] = B.found;
    chain.lanes[RELAY + '/reflection/note-witness'] = { network: 'mainnet', root: '0x' + 'ab'.repeat(32), height: 966812,
      witnesses: { [got.leaf]: { leafIndex: 7, path: [] }, [fresh.leaf]: null } };
    const p = await open(chain);
    p.click(p.$('pvKey').querySelector('button[data-a="recover"]'));
    await p.waitFor(() => /on Bitcoin/.test(p.text('pvList')), { label: 'the Bitcoin notes', ...SLOW });
    const t = p.text('pvList');
    assert.match(t, /12345678 units on Bitcoin\s*verified/, 'received over ECDH from the sender, and in the reflected note set');
    assert.match(t, /777 units on Bitcoin\s*not reflected yet/, 'this key\'s own change, not reflected yet');
    assert.equal((t.match(/on Bitcoin/g) || []).length, 2, 'the sender\'s change and padding are not this key\'s');
    const asked = p.window.__posts.filter(x => /\/reflection\/note-witness$/.test(x.url)).map(x => JSON.parse(x.body));
    assert.deepEqual(asked, [{ leaves: [got.leaf, fresh.leaf] }], 'one batch, carrying exactly the leaves Tacit\'s reflection folds these outputs under');
    await p.settle();
    p.close();
  });
});

describe('the key alone finds its locks', () => {
  // The reveal's witness is [sig(64), envelope script, control block(33)]; lift the script out of the fixture tx.
  const envelopeScript = () => {
    const b = Buffer.from(C.reveal, 'hex');
    let o = 4 + 2 + 1 + 36 + 1 + 4;
    const nOut = b[o++];
    for (let i = 0; i < nOut; i++) { o += 8; o += 1 + b[o]; }
    o += 1;                       // witness item count
    o += 1 + b[o];                // the signature
    let len = b[o++];
    if (len === 0xfd) { len = b.readUInt16LE(o); o += 2; }
    return b.subarray(o, o + len).toString('hex');
  };

  test('a wiped browser rediscovers the lock and its note blinding from the bc1p lock address', async () => {
    const chain = cbtcChain();
    const p = await open(chain);
    const la = p.window.eval('cpSeg("bc",bKeys(cpSeed).lock.slice(2),1)');
    assert.match(la, /^bc1p/);
    chain.lanes['/tx/' + C.commitTxid] = { vin: [{ txid: C.anchor.txid, vout: C.anchor.vout }] };
    chain.lanes['/address/' + la + '/txs'] = [{
      txid: C.lockTxid, status: { confirmed: true, block_time: 1 },
      vin: [{ txid: C.commitTxid, vout: 0, witness: ['00'.repeat(64), envelopeScript(), 'c0' + '00'.repeat(32)] }],
      vout: [{ scriptpubkey: '0014' + '00'.repeat(20), value: 546 }, { scriptpubkey: C.lockSpk, value: C.amountSats }],
    }];
    p.click(p.$('pvKey').querySelector('button[data-a="recover"]'));
    await p.waitFor(() => /Recovered 1 deposit/.test(p.text('stat')), { label: 'the lock to be rediscovered', ...SLOW });
    const rec = JSON.parse(p.window.localStorage[Object.keys(p.window.localStorage).find(k => k.startsWith('zswap:cpl:'))])[0];
    assert.equal(rec.t, C.lockTxid);
    assert.equal(rec.b, C.blinding, 'the same blinding, re-derived from the funding coin alone');
    assert.match(p.text('pvList'), /0\.001 BTC lock/);
    await p.settle();
    p.close();
  });
});
