/**
 * Private sends inside Tacit's pool, from the Tacit key alone: a stealth lock of
 * a whole note to another Tacit address, a split, a claim of a payment someone
 * locked to this key, and - with nothing shielded - a wrap and transfer in one
 * transaction that then locks to the recipient.
 *
 * Every op the page hands the relay is compared with the op Tacit's own builders
 * made under the same random stream (test/fixtures/confidential.json, `send`), so
 * what the relay proves for the page is the statement tacit.finance would submit.
 * The lock set is not in any event: the page reads it from settle() calldata, so
 * the pool here serves its settles as transactions, not just logs.
 */
import { test, describe, after } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { createHash } from 'node:crypto';
import { AbiCoder, keccak256, toUtf8Bytes, concat } from 'ethers';
import { A, MockChain, loadPage, closeAllPages, CP_BLOCK, ensNamehash } from './harness.mjs';

after(closeAllPages);

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..');
const F = JSON.parse(fs.readFileSync(path.join(ROOT, 'test', 'fixtures', 'confidential.json'), 'utf8'));
const S = F.send;
const coder = AbiCoder.defaultAbiCoder();
const POOL = F.pool, ROUTER = F.router, RELAY = 'api.tacit.finance';
const SEL = { ASSETS: '9fda5b66', NEXT: '0be4f422', DEPOSIT: '7da9874f', SETTLE: '717fd7f2', WT: '50de88e1' };
const T = {
  LEAVES: keccak256(toUtf8Bytes('LeavesInserted(uint256,bytes32[],bytes[])')),
  SPENT: keccak256(toUtf8Bytes('NullifiersSpent(bytes32[])')),
  WRAP: keccak256(toUtf8Bytes('Wrap(bytes32,bytes32,uint256)')),
};
const u256 = v => BigInt(v).toString(16).padStart(64, '0');
const KEY = { ['zswap:cpk:' + A.ACCOUNT.toLowerCase()]: F.seed };
const SLOW = { timeout: 30000 };
const B0 = CP_BLOCK + 0x100;
const canon = o => JSON.stringify(o, (k, v) => (v && typeof v === 'object' && !Array.isArray(v) ? Object.fromEntries(Object.keys(v).sort().map(x => [x, v[x]])) : v));
const leafOf = (o, asset = F.ethAssetId) => keccak256(concat([asset, o.cx, o.cy, o.owner]));
const lockNu = leaf => keccak256(concat([leaf, toUtf8Bytes('spent')]));

// The random stream the fixture's ops were built under, handed to the page in place of the browser's.
const stream = tag => {
  let c = 0, buf = Buffer.alloc(0);
  return a => { let o = 0; while (o < a.length) { if (!buf.length) buf = createHash('sha256').update(tag + ':' + c++).digest(); const k = Math.min(buf.length, a.length - o); a.set(buf.subarray(0, k), o); buf = buf.subarray(k); o += k; } return a; };
};
const useStream = (p, tag) => Object.defineProperty(p.window.crypto, 'getRandomValues', { configurable: true, value: stream(tag) });

// The pool's PublicValues, as settle() calldata carries them: the struct head with the note leaves (field 4), the
// new lock leaves (17) and the spent lock nullifiers (18) filled in. Nothing else is read for the lock set.
const pvWith = ({ nullifiers = [], leaves = [], lockLeaves = [], lockNullifiers = [] }) => {
  const arrs = { 3: nullifiers, 4: leaves, 17: lockLeaves, 18: lockNullifiers }, head = [];
  let tail = '', off = 34 * 32;
  for (let i = 0; i < 34; i++) {
    if (!arrs[i]) { head.push(u256(0)); continue; }
    head.push(u256(off));
    const enc = u256(arrs[i].length) + arrs[i].map(x => x.slice(2)).join('');
    tail += enc; off += enc.length / 2;
  }
  return '0x' + u256(32) + head.join('') + tail;
};

function poolChain() {
  const chain = new MockChain();
  chain.blockNumber = '0x' + (B0 + 0x100).toString(16);
  chain.gasPrice = 0n;
  chain.setNative(A.ACCOUNT, 10n ** 18n);
  chain.answer(POOL, SEL.ASSETS, '0x' + u256(1) + u256(0) + u256(10n ** 10n) + F.ethAssetId.slice(2) + u256(0) + u256(18));
  chain.answer(POOL, SEL.NEXT, () => '0x' + u256(chain.nextLeaf ?? 0));
  chain.answer(POOL, SEL.DEPOSIT, () => '0x' + u256(chain.depositStatus ?? 0));
  chain.answer(POOL, SEL.SETTLE, '0x');
  chain.answer(ROUTER, SEL.WT, '0x');
  chain.txs = new Map();
  chain.ntx = 0;
  chain.jobs = 0;
  chain.relay = { status: { status: 'pending' } };
  chain.lanes = {};
  Object.defineProperty(chain.lanes, RELAY + '/confidential/submit', { enumerable: true, get: () => ({ ok: true, jobId: '0xjob' + (++chain.jobs), status: 'pending' }) });
  Object.defineProperty(chain.lanes, RELAY + '/confidential/status', { enumerable: true, get: () => chain.relay.status });
  return chain;
}

/** The events one settle emits, as the pool emits them: NullifiersSpent when it spends notes, and
 *  LeavesInserted only when it inserts note leaves - a lock-only settle emits no LeavesInserted at all. */
function eventsOf(chain, tx, block, c, at = 0) {
  const all = [...(c.memos || []), ...(c.lockMemos || [])], first = chain.nextLeaf ?? 0;
  if ((c.nullifiers || []).length) chain.logs.push({ address: POOL, blockNumber: block, logIndex: '0x' + (at++).toString(16), transactionHash: tx, topics: [T.SPENT], data: coder.encode(['bytes32[]'], [c.nullifiers]) });
  if ((c.leaves || []).length) {
    chain.logs.push({ address: POOL, blockNumber: block, logIndex: '0x' + (at++).toString(16), transactionHash: tx, topics: [T.LEAVES, '0x' + u256(first)], data: coder.encode(['bytes32[]', 'bytes[]'], [c.leaves, all]) });
    chain.nextLeaf = first + c.leaves.length;
  }
  return at;
}
const nextBlock = chain => { chain.blockNumber = '0x' + (BigInt(chain.blockNumber) + 5n).toString(16); };
const txHash = (chain, tag) => '0x' + createHash('sha256').update(tag + (++chain.ntx)).digest('hex');

/** One pool.settle() transaction: its calldata (the lock set lives only there) and its events. */
function settleOn(chain, c) {
  const tx = txHash(chain, 'settle-'), all = [...(c.memos || []), ...(c.lockMemos || [])];
  chain.txs.set(tx, { hash: tx, to: POOL, input: '0x' + SEL.SETTLE + coder.encode(['bytes', 'bytes', 'bytes[]'], [pvWith(c), '0x00', all]).slice(2) });
  eventsOf(chain, tx, '0x' + (B0 + chain.ntx).toString(16), c);
  nextBlock(chain);
}

/** A settle someone else sent through their own contract (a searcher resending the relay's settle for its fee):
 *  the settle calldata rides nested as a bytes argument of an unrelated call. */
const SEARCHER = '0xf1d1aba8bdb1d0c0d0e0f0a0b0c0d0e0f0a0b0c0';
function nestedOn(chain, c) {
  const tx = txHash(chain, 'nested-'), all = [...(c.memos || []), ...(c.lockMemos || [])];
  const inner = '0x' + SEL.SETTLE + coder.encode(['bytes', 'bytes', 'bytes[]'], [pvWith(c), '0x00', all]).slice(2);
  chain.txs.set(tx, { hash: tx, to: SEARCHER, input: '0xc35d5cb3' + coder.encode(['address', 'uint256', 'bytes'], [POOL, 0, inner]).slice(2) });
  eventsOf(chain, tx, '0x' + (B0 + chain.ntx).toString(16), c);
  nextBlock(chain);
}

/** A TacitRelayer.relaySettle batch: every inner call rides the calldata, but only the calls that landed emit. */
const RELAYER = '0x000000009C28617AC88B52Eae5EFaAcdD4aC34c3';
function relayOn(chain, calls) {
  const tx = txHash(chain, 'relay-'), block = '0x' + (B0 + chain.ntx).toString(16);
  const enc = calls.map(c => [pvWith(c), '0x00', [...(c.memos || []), ...(c.lockMemos || [])]]);
  chain.txs.set(tx, { hash: tx, to: RELAYER, input: '0xfcccb833' + coder.encode(['tuple(bytes,bytes,bytes[])[]', 'address[]', 'uint256[]', 'address[]', 'uint256[]'], [enc, [], [], [], []]).slice(2) });
  let at = 0;
  for (const c of calls) if (!c.failed) at = eventsOf(chain, tx, block, c, at);
  nextBlock(chain);
}

/** The fixture note: deposited under this key at its derivation index and settled into leaf 0. */
function withNote(chain) {
  chain.logs.push({ address: POOL, blockNumber: '0x' + (B0 - 1).toString(16), logIndex: '0x0', topics: [T.WRAP, F.depositId, F.ethAssetId], data: '0x' + u256(F.amountWei) });
  settleOn(chain, { leaves: [F.leaf, F.otherLeaf], memos: [F.memo, '0x' + '11'.repeat(169)] });
  return chain;
}

const poke = p => p.doc.dispatchEvent(new p.window.Event('visibilitychange'));
const posts = p => p.window.__posts.filter(x => /\/confidential\/submit$/.test(x.url)).map(x => JSON.parse(x.body));

async function open(chain) {
  const p = await loadPage({ chain, storage: { ...KEY } });
  const inner = p.window.fetch;
  p.window.__posts = [];
  p.window.fetch = async (url, init) => {
    if (init && init.body) p.window.__posts.push({ url: String(url), body: init.body });
    return inner(url, init);
  };
  await p.connect();
  p.click('pv');
  await p.settle();
  await p.waitFor(() => /Key unlocked/.test(p.text('pvKey')), { label: 'the cached key' });
  return p;
}
const ready = async p => {
  poke(p);
  await p.waitFor(() => /0\.01 tETH/.test(p.text('pvList')) && p.$('pvList').querySelector('button[data-a="split"]'), { label: 'the note, found from the key', ...SLOW });
};
const until = async (p, fn, label) => { for (let i = 0; i < 40 && !fn(); i++) { poke(p); await p.settle(); await new Promise(r => setTimeout(r, 50)); } await p.waitFor(fn, { label, ...SLOW }); };

describe('private sends', () => {
  test('the key alone finds its note and shows the shielded balance', async () => {
    const p = await open(withNote(poolChain()));
    await ready(p);
    assert.match(p.text('pvList'), /Shielded 0\.01 tETH/);
    p.click(p.$('pvKey').querySelector('button[data-a="addr"]'));
    await p.settle();
    assert.equal(p.window.__promptDefaults.at(-1), S.address, 'the address is the key\'s tacit1 address, with its Ethereum lane');
    p.close();
  });

  test('sending a whole note is the stealth lock Tacit builds, and the page follows it to the claim', async () => {
    const p = await open(withNote(poolChain()));
    await ready(p);
    p.window.Date.now = () => (Number(S.deadline) - 7776000) * 1000;
    p.select('pvAct', 'send');
    await p.settle();
    assert.ok(p.visible('pvRcL'), 'the recipient field appears');
    for (const id of ['pvChain', 'pvTo']) assert.ok(p.$(id).parentElement.classList.contains('hide'), id + ' is not part of a send');
    assert.equal(p.text('pvGo'), 'Send');
    p.type('pvAmt', '0.01');
    p.type('pvRc', S.lock.recipient);
    useStream(p, S.lock.tag);
    p.click('pvGo');
    await p.waitFor(() => posts(p).some(x => x.type === 'stealthlock'), { label: 'the lock to reach the relay', ...SLOW });
    const sub = posts(p).find(x => x.type === 'stealthlock');
    assert.equal(canon(sub.op), canon(S.lock.op), 'the lock witness Tacit\'s stealthSend submits');
    assert.deepEqual(sub.memos, [S.lock.memoFull], 'sealed to the recipient\'s key, with a tail sealed back to this one');
    assert.equal(sub.memos[0].slice(0, 292), S.lock.memo, 'the part the recipient reads is Tacit\'s own memo');
    assert.equal(sub.mode, 'settle');
    assert.match(p.text('pvList'), /sent to 02|sent to 03/);
    settleOn(p.chain, { nullifiers: [F.nullifier], lockLeaves: [S.lock.op.lockLeaf], lockMemos: [S.lock.memoFull] });
    p.chain.relay.status = { status: 'settled' };
    await until(p, () => /waiting for the recipient/.test(p.text('pvList')), 'the lock to land');
    settleOn(p.chain, { leaves: ['0x' + '44'.repeat(32)], memos: ['0x'], lockNullifiers: [lockNu(S.lock.op.lockLeaf)] });
    await until(p, () => /claimed/.test(p.text('pvList')), 'the recipient\'s claim to be seen');
    p.close();
  });

  test('the sending key alone finds an unclaimed send again, and takes it back after the deadline', async () => {
    const chain = withNote(poolChain());
    settleOn(chain, { nullifiers: [F.nullifier], lockLeaves: [S.lock.op.lockLeaf], lockMemos: [S.lock.memoFull] });
    const p = await open(chain);
    await until(p, () => /sent to 0[23]/.test(p.text('pvList')) && /waiting for the recipient/.test(p.text('pvList')), 'the send, found from the key');
    p.window.Date.now = () => (Number(S.deadline) + 60) * 1000;
    await until(p, () => p.$('pvList').querySelector('button[data-a="srefund"]'), 'the take-back button');
    useStream(p, S.refund.tag);
    p.click(p.$('pvList').querySelector('button[data-a="srefund"]'));
    await p.waitFor(() => posts(p).some(x => x.type === 'stealthrefund'), { label: 'the refund to reach the relay', ...SLOW });
    const sub = posts(p).find(x => x.type === 'stealthrefund');
    assert.equal(canon(sub.op), canon(S.refund.op), 'the refund witness Tacit\'s stealthRefund submits');
    assert.deepEqual(sub.memos, S.refund.memos);
    p.close();
  });

  test('a split is Tacit\'s transfer, and both halves come back as notes', async () => {
    const p = await open(withNote(poolChain()));
    await ready(p);
    useStream(p, S.xfer.tag);
    p.queuePrompt('0.0025');
    p.click(p.$('pvList').querySelector('button[data-a="split"]'));
    await p.waitFor(() => posts(p).some(x => x.type === 'transfer'), { label: 'the split to reach the relay', ...SLOW });
    const sub = posts(p).find(x => x.type === 'transfer');
    assert.equal(canon(sub.op), canon(S.xfer.op), 'the transfer witness Tacit\'s buildTransferOp makes');
    assert.deepEqual(sub.memos, S.xfer.memos);
    assert.equal(sub.op.fee, S.fee, 'the relay\'s floor, taken from the change');
    settleOn(p.chain, { nullifiers: [F.nullifier], leaves: S.xfer.op.outputs.map(o => leafOf(o)), memos: S.xfer.memos });
    p.chain.relay.status = { status: 'settled' };
    await until(p, () => /0\.0025 tETH/.test(p.text('pvList')) && /0\.0074 tETH/.test(p.text('pvList')) && /Shielded 0\.0099 tETH/.test(p.text('pvList')), 'both halves');
    p.close();
  });

  test('a payment locked to this key through a relayer batch shows as incoming, and the claim is Tacit\'s', async () => {
    const chain = withNote(poolChain());
    // Three locks batched through TacitRelayer; the middle one failed inside the batch and never landed, so
    // it must not take a place in the lock tree - the claim's witness puts this key's payment at index 1.
    relayOn(chain, [
      { nullifiers: ['0x' + '77'.repeat(32)], lockLeaves: [S.lock.op.lockLeaf], lockMemos: [S.lock.memo] },
      { failed: true, nullifiers: ['0x' + '78'.repeat(32)], lockLeaves: ['0x' + '55'.repeat(32)], lockMemos: [S.lock.memo] },
      { nullifiers: ['0x' + '79'.repeat(32)], lockLeaves: [S.claim.leaf], lockMemos: [S.claim.memo] },
    ]);
    const p = await open(chain);
    await ready(p);
    await until(p, () => /0\.03 tETH received privately/.test(p.text('pvList')), 'the payment, found from the key');
    assert.match(p.text('pvList'), /incoming 0\.03 tETH/);
    assert.equal(p.$('pvList').querySelectorAll('button[data-a="claim"]').length, 1, 'only the lock sealed to this key');
    // A sender can refund after the deadline, so the receiver is told when it falls.
    assert.match(p.text('pvList'), /received privately · claim by \w+/);
    useStream(p, S.claim.tag);
    p.click(p.$('pvList').querySelector('button[data-a="claim"]'));
    await p.waitFor(() => posts(p).some(x => x.type === 'stealthclaim'), { label: 'the claim to reach the relay', ...SLOW });
    const sub = posts(p).find(x => x.type === 'stealthclaim');
    assert.equal(canon(sub.op), canon(S.claim.op), 'the claim witness Tacit\'s buildStealthClaim makes');
    assert.deepEqual(sub.memos, S.claim.memos);
    settleOn(p.chain, { leaves: [leafOf({ cx: S.claim.op.mCx, cy: S.claim.op.mCy, owner: S.claim.op.mOwner })], memos: S.claim.memos, lockNullifiers: [lockNu(S.claim.leaf)] });
    p.chain.relay.status = { status: 'settled' };
    await until(p, () => !/received privately/.test(p.text('pvList')) && /Shielded 0\.0399 tETH/.test(p.text('pvList')), 'the claimed note');
    p.close();
  });

  test('a claim that lands inside someone else\'s transaction still reads as claimed', async () => {
    const chain = withNote(poolChain());
    relayOn(chain, [
      { nullifiers: ['0x' + '77'.repeat(32)], lockLeaves: [S.lock.op.lockLeaf], lockMemos: [S.lock.memo] },
      { failed: true, nullifiers: ['0x' + '78'.repeat(32)], lockLeaves: ['0x' + '55'.repeat(32)], lockMemos: [S.lock.memo] },
      { nullifiers: ['0x' + '79'.repeat(32)], lockLeaves: [S.claim.leaf], lockMemos: [S.claim.memo] },
    ]);
    const p = await open(chain);
    await ready(p);
    await until(p, () => /0\.03 tETH received privately/.test(p.text('pvList')), 'the payment, found from the key');
    useStream(p, S.claim.tag);
    p.click(p.$('pvList').querySelector('button[data-a="claim"]'));
    await p.waitFor(() => posts(p).some(x => x.type === 'stealthclaim'), { label: 'the claim to reach the relay', ...SLOW });
    // A searcher lands the relay's claim first, through its own contract; the relay's copy then reverts.
    nestedOn(p.chain, { leaves: [leafOf({ cx: S.claim.op.mCx, cy: S.claim.op.mCy, owner: S.claim.op.mOwner })], memos: S.claim.memos, lockNullifiers: [lockNu(S.claim.leaf)] });
    p.chain.relay.status = { status: 'failed', error: 'settle reverted: LockAlreadySpent()' };
    await until(p, () => !/received privately/.test(p.text('pvList')) && /Shielded 0\.0399 tETH/.test(p.text('pvList')), 'the claim, found in the other transaction');
    p.close();
  });

  test('a lock the pool never took is left out before the claim is built', async () => {
    const chain = withNote(poolChain());
    settleOn(chain, { nullifiers: ['0x' + '77'.repeat(32)], lockLeaves: [S.lock.op.lockLeaf], lockMemos: [S.lock.memo] });
    // Someone's contract carries a settle it never ran, with a lock leaf the pool never took, checked only
    // against the event its real (unseen) call emitted.
    nestedOn(chain, { nullifiers: ['0x' + '78'.repeat(32)], lockLeaves: ['0x' + '55'.repeat(32)], lockMemos: [S.lock.memo] });
    settleOn(chain, { nullifiers: ['0x' + '79'.repeat(32)], lockLeaves: [S.claim.leaf], lockMemos: [S.claim.memo] });
    // The pool's own lock count and root.
    chain.storage = new Map([[POOL.toLowerCase() + ':54', '0x' + u256(2)], [POOL.toLowerCase() + ':55', S.claim.op.lockSetRoot]]);
    const p = await open(chain);
    await ready(p);
    await until(p, () => /0\.03 tETH received privately/.test(p.text('pvList')), 'the payment, found from the key');
    useStream(p, S.claim.tag);
    p.click(p.$('pvList').querySelector('button[data-a="claim"]'));
    await p.waitFor(() => posts(p).some(x => x.type === 'stealthclaim'), { label: 'the claim to reach the relay', ...SLOW });
    assert.equal(canon(posts(p).find(x => x.type === 'stealthclaim').op), canon(S.claim.op), 'built on the pool\'s own lock set');
    p.close();
  });

  test('a payment the pool records as claimed reads as claimed, with no claim in any calldata here', async () => {
    const chain = withNote(poolChain());
    relayOn(chain, [{ nullifiers: ['0x' + '79'.repeat(32)], lockLeaves: [S.claim.leaf], lockMemos: [S.claim.memo] }]);
    chain.storage = new Map();
    const p = await open(chain);
    await ready(p);
    await until(p, () => /0\.03 tETH received privately/.test(p.text('pvList')), 'the payment');
    const slot = keccak256(concat([lockNu(S.claim.leaf), '0x' + u256(119)]));
    p.chain.storage.set(POOL.toLowerCase() + ':' + BigInt(slot).toString(16), '0x' + u256(1));
    await until(p, () => !/received privately/.test(p.text('pvList')), 'the payment to read as claimed');
    p.close();
  });

  test('a lock the relay did not take is sent again as the same op, so it can only ever land once', async () => {
    const p = await open(withNote(poolChain()));
    await ready(p);
    p.window.Date.now = () => (Number(S.deadline) - 7776000) * 1000;
    p.select('pvAct', 'send');
    await p.settle();
    p.type('pvAmt', '0.01');
    p.type('pvRc', S.lock.recipient);
    useStream(p, S.lock.tag);
    const inner = p.window.fetch;
    let refused = 0;
    p.window.fetch = async (url, init) => {
      if (!refused && String(url).includes('/confidential/submit') && init && /stealthlock/.test(init.body)) {
        refused++;
        p.window.__posts.push({ url: String(url), body: init.body });
        throw new TypeError('connection reset');
      }
      return inner(url, init);
    };
    p.click('pvGo');
    await until(p, () => posts(p).filter(x => x.type === 'stealthlock').length >= 2, 'the lock to be sent again');
    const [a, b] = posts(p).filter(x => x.type === 'stealthlock');
    assert.equal(canon(b.op), canon(a.op), 'the same op, not a second lock with fresh randomness');
    assert.deepEqual(b.memos, a.memos);
    assert.equal(canon(a.op), canon(S.lock.op));
    p.close();
  });

  test('records another tab saved survive this tab saving its own', async () => {
    const p = await open(withNote(poolChain()));
    await ready(p);
    const fp = Object.keys(p.window.localStorage).find(k => k.startsWith('zswap:cpn:')).slice('zswap:cpn:'.length);
    const send = { id: 'othertab1', a: F.ethAssetId, v: '1000', to: '02' + '11'.repeat(32), st: 'sent', lf: '0x' + '66'.repeat(32), dl: S.deadline, ins: [], at: 0 };
    const inbox = { k: 9, lf: '0x' + '67'.repeat(32), a: F.ethAssetId, v: '2000', dl: S.deadline, at: 0 };
    p.window.localStorage['zswap:cps:' + fp] = JSON.stringify([send]);
    p.window.localStorage['zswap:cpi:' + fp] = JSON.stringify([inbox]);
    p.window.eval('cpSaveS();cpSaveI()');
    assert.ok(JSON.parse(p.window.localStorage['zswap:cps:' + fp]).some(x => x.id === send.id), 'the other tab\'s send survives');
    assert.ok(JSON.parse(p.window.localStorage['zswap:cpi:' + fp]).some(x => x.lf === inbox.lf), 'and its incoming payment');
    p.close();
  });

  test('withdrawing part of a note is Tacit\'s send-and-unwrap, and the rest stays shielded as change', async () => {
    const p = await open(withNote(poolChain()));
    await ready(p);
    p.window.Date.now = () => (Number(S.su.deadline) - 3600) * 1000;
    p.select('pvAct', 'out');
    p.select('pvChain', '1');
    await p.settle();
    assert.equal(p.text('pvGo'), 'Withdraw');
    p.type('pvAmt', '0.004');
    useStream(p, S.su.tag);
    p.click('pvGo');
    await p.waitFor(() => posts(p).some(x => x.type === 'sendunwrap'), { label: 'the withdrawal to reach the relay', ...SLOW });
    const sub = posts(p).find(x => x.type === 'sendunwrap');
    assert.equal(canon(sub.op), canon(S.su.op), 'the send-and-unwrap witness Tacit\'s sendUnwrap builds');
    assert.deepEqual(sub.memos, S.su.memos, 'the change memo, sealed to this key');
    assert.equal(sub.op.payout, 390000, '0.004 leaves the pool, less the relay fee');
    assert.match(p.text('pvList'), /0\.004 of 0\.01 tETH/);
    settleOn(p.chain, { nullifiers: [F.nullifier], leaves: [leafOf(S.su.op.change[0])], memos: S.su.memos });
    p.chain.relay.status = { status: 'settled' };
    await until(p, () => /on Ethereum/.test(p.text('pvList')) && /Shielded 0\.006 tETH/.test(p.text('pvList')), 'the withdrawal and the change');
    p.close();
  });

  test('a withdrawal larger than any one note merges notes first, then exits the merged note', async () => {
    const chain = withNote(poolChain());
    settleOn(chain, { leaves: [F.found.leaf], memos: [F.found.memo] });
    const p = await open(chain);
    await ready(p);
    await until(p, () => /Shielded 0\.03 tETH/.test(p.text('pvList')), 'both notes');
    p.select('pvAct', 'out');
    p.select('pvChain', '1');
    p.type('pvAmt', '0.025');
    p.click('pvGo');
    await p.waitFor(() => posts(p).some(x => x.type === 'transfer'), { label: 'the merge to reach the relay', ...SLOW });
    const merge = posts(p).find(x => x.type === 'transfer');
    assert.equal(merge.op.inputs.length, 2, 'both notes go in');
    assert.equal(merge.op.fee, S.fee);
    assert.match(p.text('pvList'), /merge for a withdrawal/);
    const nus = [F.nullifier, keccak256(concat([F.found.note.secret, F.found.leaf, toUtf8Bytes('tacit-native-nullifier-v1')]))];
    settleOn(p.chain, { nullifiers: nus, leaves: merge.op.outputs.map(o => leafOf(o)), memos: merge.memos });
    p.chain.relay.status = { status: 'settled' };
    await until(p, () => posts(p).some(x => x.type === 'unwrap'), 'the exit of the merged note');
    const exit = posts(p).find(x => x.type === 'unwrap');
    assert.equal(exit.op.value, '2500000', 'the merged note is exactly the amount asked for');
    assert.equal(exit.op.recipient, F.account.toLowerCase());
    p.close();
  });

  test('with nothing shielded, a send wraps and transfers in one transaction, then locks', async () => {
    const p = await open(poolChain());
    p.select('pvAct', 'send');
    p.type('pvAmt', '0.005');
    p.type('pvRc', S.lock.recipient);
    p.queueConfirm(true);
    useStream(p, S.wt.tag);
    p.click('pvGo');
    await p.waitFor(() => posts(p).some(x => x.type === 'wraptransfer'), { label: 'the wrap-and-transfer to reach the relay', ...SLOW });
    const sub = posts(p).find(x => x.type === 'wraptransfer');
    assert.equal(sub.mode, 'prove', 'proved only: this wallet sends it');
    assert.equal(canon(sub.op), canon(S.wt.op), 'the witness Tacit\'s buildWrapTransferOp makes');
    assert.deepEqual(sub.memos, S.wt.memos);
    const pv = '0x' + '00'.repeat(32) + S.wt.depositId.slice(2), proof = '0xabcdef';
    p.chain.relay.status = { status: 'proven', publicValues: pv, proof };
    await until(p, () => p.$('pvList').querySelector('button[data-a="sgo"]'), 'the wrap to be sendable');
    p.click(p.$('pvList').querySelector('button[data-a="sgo"]'));
    await p.waitFor(() => p.chain.sentTo(ROUTER).length === 1, { label: 'the router transaction', ...SLOW });
    const tx = p.chain.sentTo(ROUTER)[0], wei = BigInt(S.wt.value) * 10n ** 10n;
    assert.equal(BigInt(tx.value), wei, 'exactly the deposit, no fee on top');
    assert.equal(tx.data, '0x' + SEL.WT + coder.encode(['uint256', 'bytes32', 'bytes', 'bytes', 'bytes[]', 'address'], [wei, S.wt.commit, pv, proof, S.wt.memos, A.ZERO]).slice(2));
    p.chain.depositStatus = 2;
    p.chain.logs.push({ address: POOL, blockNumber: '0x' + (B0 + 0x80).toString(16), logIndex: '0x0', topics: [T.WRAP, S.wt.depositId, F.ethAssetId], data: '0x' + u256(wei) });
    settleOn(p.chain, { leaves: [leafOf(S.wt.op.outputs[0])], memos: S.wt.memos });
    await until(p, () => posts(p).some(x => x.type === 'stealthlock'), 'the lock that follows');
    const lock = posts(p).find(x => x.type === 'stealthlock');
    assert.equal(lock.op.nCx, S.wt.op.outputs[0].cx, 'it locks the note the wrap made');
    assert.ok(!/#0/.test(p.text('pvList')), 'the consumed deposit is not mistaken for a pending one');
    p.close();
  });
});

/**
 * A name as the registry. The protocol has none, and a 0x address cannot
 * reveal a spend key, so a recipient publishes their tacit1… address once as
 * the "finance.tacit" text record on a name they own (ENSIP-5 service key),
 * and anyone can then pay them privately by typing the name.
 */
describe('paying a name', () => {
  const tacitFor = (p, key) => p.window.eval(`cpTacEnc("tacit",cpCat([0,3],hexToBytes("${key}"),hexToBytes("${key}"),hexToBytes("${key}")))`);
  const sendTo = async (p, who, ok = true) => {
    p.window.Date.now = () => (Number(S.deadline) - 7776000) * 1000;
    p.select('pvAct', 'send');
    await p.settle();
    p.type('pvAmt', '0.01');
    p.type('pvRc', who);
    useStream(p, S.lock.tag);
    p.queueConfirm(ok);
    p.click('pvGo');
  };

  for (const tld of ['wei', 'gwei']) test(`a .${tld} name with a published Tacit address is paid privately, exactly as the key`, async () => {
    const chain = withNote(poolChain());
    const p = await open(chain);
    await ready(p);
    chain.texts = new Map([[`bob.${tld}|finance.tacit`, tacitFor(p, S.lock.recipient)]]);
    await sendTo(p, `bob.${tld}`);
    await p.waitFor(() => posts(p).some(x => x.type === 'stealthlock'), { label: 'the lock', ...SLOW });
    const sub = posts(p).find(x => x.type === 'stealthlock');
    assert.equal(canon(sub.op), canon(S.lock.op), 'the same lock as sending to the key itself');
    assert.match(p.asked.confirm.at(-1), new RegExp(`bob\\.${tld} → tacit1`), 'the sender sees where the name points before paying');
    p.close();
  });

  test('a .eth name is read through its ENS resolver the same way', async () => {
    const chain = withNote(poolChain());
    chain.ensResolver = A.ENSRESOLVER;
    chain.ensNames.set('bob.eth', A.OTHER);
    const p = await open(chain);
    await ready(p);
    chain.texts = new Map([['bob.eth|finance.tacit', tacitFor(p, S.lock.recipient)]]);
    await sendTo(p, 'bob.eth');
    await p.waitFor(() => posts(p).some(x => x.type === 'stealthlock'), { label: 'the lock', ...SLOW });
    assert.equal(canon(posts(p).find(x => x.type === 'stealthlock').op), canon(S.lock.op));
    p.close();
  });

  test('declining the name check sends nothing', async () => {
    const chain = withNote(poolChain());
    const p = await open(chain);
    await ready(p);
    chain.texts = new Map([['bob.wei|finance.tacit', tacitFor(p, S.lock.recipient)]]);
    await sendTo(p, 'bob.wei', false);
    await p.settle();
    await new Promise(r => setTimeout(r, 300));
    assert.ok(!posts(p).some(x => x.type === 'stealthlock'));
    assert.doesNotMatch(p.text('stat'), /error/i);
    p.close();
  });

  test('a name with nothing published is refused plainly, and nothing is sent', async () => {
    const p = await open(withNote(poolChain()));
    await ready(p);
    p.chain.texts = new Map();
    await sendTo(p, 'carol.wei');
    await p.waitFor(() => /carol\.wei has no Tacit address published/.test(p.text('stat')), { label: 'the refusal', ...SLOW });
    assert.ok(!posts(p).some(x => x.type === 'stealthlock'));
    p.close();
  });

  test('publishing writes this key\'s tacit1 address to the wallet\'s own .wei name', async () => {
    const chain = withNote(poolChain());
    chain.names.set('alice.wei', A.ACCOUNT);
    chain.reverse.set(A.ACCOUNT.toLowerCase(), 'alice.wei');
    const p = await open(chain);
    await ready(p);
    p.queueConfirm(true);
    p.click(p.$('pvKey').querySelector('button[data-a="pub"]'));
    await p.waitFor(() => chain.sentTo(A.WNS).length > 0, { label: 'the setText', ...SLOW });
    const tx = chain.sentTo(A.WNS).at(-1);
    assert.equal(tx.data.slice(2, 10), '3fb24782', 'setText(uint256 tokenId,string,string)');
    const [id, key, value] = coder.decode(['uint256', 'string', 'string'], '0x' + tx.data.slice(10));
    assert.equal('0x' + id.toString(16).padStart(64, '0'), ensNamehash('alice.wei'), 'the name\'s own token id');
    assert.equal(key, 'finance.tacit');
    assert.equal(value, S.address, 'this key\'s own tacit1 address');
    p.close();
  });
});

/**
 * A recipient with only a 0x cannot be paid privately: a lock needs their
 * Tacit key, and a 0x does not reveal one. Tacit's advice is to offer the
 * public payout by default, said plainly: the sender is hidden, the amount and
 * recipient are not. So a 0x (or a name with no Tacit address behind it)
 * hands over to the withdraw form rather than dead-ending in an error.
 */
describe('a recipient with only a 0x', () => {
  const tryPay = async (p, who, ok) => {
    p.select('pvAct', 'send');
    await p.settle();
    p.type('pvAmt', '0.01');
    p.type('pvRc', who);
    if (ok !== undefined) p.queueConfirm(ok);
    p.click('pvGo');
    await p.settle();
    await new Promise(r => setTimeout(r, 300));
  };

  test('a 0x is offered as a public payout, and the form is filled in', async () => {
    const p = await open(withNote(poolChain()));
    await ready(p);
    await tryPay(p, A.OTHER, true);
    assert.match(p.asked.confirm.at(-1), /cannot be paid privately[\s\S]*hidden as the sender[\s\S]*visible on chain/);
    assert.equal(p.value('pvAct'), 'out');
    assert.equal(p.value('pvTo'), A.OTHER);
    assert.equal(p.value('pvAmt'), '0.01');
    assert.match(p.text('stat'), /Switched to a public payout/);
    assert.ok(!posts(p).length, 'nothing is sent until the user presses Withdraw');
    p.close();
  });

  test('a 0x whose primary name publishes a Tacit address is paid privately instead', async () => {
    const chain = withNote(poolChain());
    chain.names.set('erin.wei', A.OTHER);
    chain.reverse.set(A.OTHER.toLowerCase(), 'erin.wei');
    const p = await open(chain);
    await ready(p);
    chain.texts = new Map([['erin.wei|finance.tacit', p.window.eval(`cpTacEnc("tacit",cpCat([0,3],hexToBytes("${S.lock.recipient}"),hexToBytes("${S.lock.recipient}"),hexToBytes("${S.lock.recipient}")))`)]]);
    p.window.Date.now = () => (Number(S.deadline) - 7776000) * 1000;
    p.select('pvAct', 'send');
    await p.settle();
    p.type('pvAmt', '0.01');
    p.type('pvRc', A.OTHER);
    useStream(p, S.lock.tag);
    p.queueConfirm(true);
    p.click('pvGo');
    await p.waitFor(() => posts(p).some(x => x.type === 'stealthlock'), { label: 'the private lock', ...SLOW });
    assert.match(p.asked.confirm.at(-1), /→ erin\.wei → tacit1/, 'the whole path is shown');
    assert.equal(canon(posts(p).find(x => x.type === 'stealthlock').op), canon(S.lock.op));
    assert.equal(p.value('pvAct'), 'send', 'no public payout');
    p.close();
  });

  test('declining keeps the private send as it was', async () => {
    const p = await open(withNote(poolChain()));
    await ready(p);
    await tryPay(p, A.OTHER, false);
    assert.equal(p.value('pvAct'), 'send');
    assert.equal(p.text('stat'), '');
    p.close();
  });

  test('a name with no Tacit address but a 0x behind it is offered the same way, by name', async () => {
    const chain = withNote(poolChain());
    chain.names.set('dave.wei', A.OTHER);
    chain.texts = new Map();
    const p = await open(chain);
    await ready(p);
    await tryPay(p, 'dave.wei', true);
    assert.match(p.asked.confirm.at(-1), /^dave\.wei has no Tacit address/);
    assert.equal(p.value('pvTo'), A.OTHER);
    p.close();
  });

  test('the everyday key actions are in view, the rest behind more', async () => {
    const p = await open(withNote(poolChain()));
    await ready(p);
    const shown = a => { const b = p.$('pvKey').querySelector(`button[data-a="${a}"]`); return !!b && !b.closest('.hide'); };
    for (const a of ['addr', 'pub', 'request', 'pay']) assert.ok(shown(a), a + ' is in view');
    for (const a of ['backup', 'relay', 'btckey']) assert.ok(!shown(a), a + ' waits behind more');
    p.click(p.$('pvKey').querySelector('button[data-a="more"]'));
    await p.settle();
    for (const a of ['backup', 'relay', 'btckey']) assert.ok(shown(a), a + ' after more');
    p.close();
  });
});

describe('when the relay says no', () => {
  test('a lock the relay keeps refusing ends as relay failed, with the reason and a retry', async () => {
    const p = await open(withNote(poolChain()));
    await ready(p);
    p.window.Date.now = () => (Number(S.deadline) - 7776000) * 1000;
    p.select('pvAct', 'send');
    await p.settle();
    p.type('pvAmt', '0.01');
    p.type('pvRc', S.lock.recipient);
    useStream(p, S.lock.tag);
    const inner = p.window.fetch;
    p.window.fetch = async (url, init) => {
      if (String(url).includes('/confidential/submit') && init && /stealthlock/.test(init.body)) return { ok: false, status: 429, json: async () => ({ error: 'free_budget: no free relays left today' }) };
      return inner(url, init);
    };
    p.click('pvGo');
    await until(p, () => p.$('pvList').querySelector('button[data-a="slock"]'), 'the send to read as relay failed');
    const why = [...p.$('pvList').querySelectorAll('span[title]')].find(s => s.textContent === 'relay failed');
    assert.ok(why, 'the row says relay failed');
    assert.match(why.getAttribute('title'), /free_budget/, 'and says why');
    assert.ok(p.$('pvList').querySelector('button[data-a="sforget"]'));
    p.close();
  });

  test('the halves of a split read as settling, never as an unseen deposit to settle or forget', async () => {
    const p = await open(withNote(poolChain()));
    await ready(p);
    useStream(p, S.xfer.tag);
    p.queuePrompt('0.0025');
    p.click(p.$('pvList').querySelector('button[data-a="split"]'));
    await p.waitFor(() => posts(p).some(x => x.type === 'transfer'), { label: 'the split to reach the relay', ...SLOW });
    const t0 = Date.now();
    p.window.Date.now = () => t0 + 7e5;
    poke(p);
    await p.settle();
    assert.match(p.text('pvList'), /settling…/);
    assert.doesNotMatch(p.text('pvList'), /deposit not seen/);
    assert.ok(!p.$('pvList').querySelector('button[data-a="settle"]'), 'no settle button that has nothing to settle');
    assert.ok(!p.$('pvList').querySelector('button[data-a="forget"]'), 'no invitation to forget a real note');
    p.close();
  });

  test('a payment on its way to someone else is not shown as incoming', async () => {
    const p = await open(withNote(poolChain()));
    await ready(p);
    p.window.Date.now = () => (Number(S.deadline) - 7776000) * 1000;
    p.select('pvAct', 'send');
    await p.settle();
    p.type('pvAmt', '0.005');
    p.type('pvRc', S.lock.recipient);
    useStream(p, S.xfer.tag);
    p.click('pvGo');
    await p.waitFor(() => posts(p).some(x => x.type === 'transfer'), { label: 'the split for the send', ...SLOW });
    poke(p);
    await p.settle();
    assert.match(p.text('pvList'), /incoming 0\.0049 tETH/, 'only the change comes back to this key');
    assert.doesNotMatch(p.text('pvList'), /incoming 0\.0099/, 'the part paid away is not counted as incoming');
    p.close();
  });
});
