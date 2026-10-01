/**
 * The private panel's relay client and lock handling, held to Tacit's current
 * relay. A tipped deposit names its transaction when it asks for the settle, so
 * the relay can read the tip. A relay that gave up on a settle it may still land
 * does not make the page forget a split's halves, says so when the send is
 * forgotten, and marks a failed exit "still pending" from its broadcast hashes
 * even when the error text does not say it. A proof the relay reports before it
 * has the artifacts is asked for again, and a found deposit self-settles with
 * the memo its proof commits to. A lock the relay failed is retried on the
 * settle path chosen now. Every memo offered for a lock is tried, so a decoy
 * call in the same transaction cannot hide a payment, and a relayed lock that
 * landed with another memo than the one sealed here is reported. A cBTC escrow
 * whose requirement cannot be priced is not reported as covered. Each case
 * failed on the page before it.
 */
import { test, describe, after } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { createHash } from 'node:crypto';
import { AbiCoder, keccak256, toUtf8Bytes, concat } from 'ethers';
import { A, MockChain, loadPage, closeAllPages, CP_BLOCK } from './harness.mjs';

after(closeAllPages);

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..');
const F = JSON.parse(fs.readFileSync(path.join(ROOT, 'test', 'fixtures', 'confidential.json'), 'utf8'));
const S = F.send, C = F.cbtc;
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
const sleep = ms => new Promise(r => setTimeout(r, ms));
const leafOf = (o, asset = F.ethAssetId) => keccak256(concat([asset, o.cx, o.cy, o.owner]));

// The random stream the fixture's ops were built under, handed to the page in place of the browser's.
const stream = tag => {
  let c = 0, buf = Buffer.alloc(0);
  return a => { let o = 0; while (o < a.length) { if (!buf.length) buf = createHash('sha256').update(tag + ':' + c++).digest(); const k = Math.min(buf.length, a.length - o); a.set(buf.subarray(0, k), o); buf = buf.subarray(k); o += k; } return a; };
};
const useStream = (p, tag) => Object.defineProperty(p.window.crypto, 'getRandomValues', { configurable: true, value: stream(tag) });

// PublicValues as settle() calldata carries them: nullifiers (3), note leaves (4), lock leaves (17), lock nullifiers (18).
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

const wrapLog = chain => chain.logs.push({ address: POOL, blockNumber: '0x' + (B0 - 1).toString(16), logIndex: '0x0', topics: [T.WRAP, F.depositId, F.ethAssetId], data: '0x' + u256(F.amountWei) });
/** The fixture note: deposited under this key at its derivation index and settled into leaf 0. */
function withNote(chain) {
  wrapLog(chain);
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
  p.click('pvGo');                       // one signature per visit unlocks the key
  await p.waitFor(() => /Key unlocked/.test(p.text('pvKey')), { label: 'the key to unlock' });
  await p.waitFor(() => p.window.eval('!!cpPool'), { label: 'the pool to load', ...SLOW });
  return p;
}
const ready = async p => {
  poke(p);
  await p.waitFor(() => /0\.01 tETH/.test(p.text('pvList')) && p.$('pvList').querySelector('button[data-a="split"]'), { label: 'the note, found from the key', ...SLOW });
};
/** Refresh the panel until `fn` holds or the tries run out; returns whether it holds. */
const tries = async (p, fn, n = 60) => { for (let i = 0; i < n && !fn(); i++) { poke(p); await p.settle(); await sleep(50); } return !!fn(); };
const until = async (p, fn, label) => { if (!await tries(p, fn)) await p.waitFor(fn, { label, ...SLOW }); };
const btn = (p, a) => p.$('pvList').querySelector(`button[data-a="${a}"]`);

// ---------------------------------------------------------------------------

describe('a tipped deposit', () => {
  const TIPFWD = '0x000000d218b03db5837943b0b05dea2965ae956e';
  test('names its deposit transaction when it asks the relay to settle', async () => {
    const chain = poolChain();
    chain.gasPrice = 10n ** 8n;
    Object.defineProperty(chain.lanes, RELAY + '/confidential/quote', {
      configurable: true, enumerable: true,
      get: () => ({ ticker: 'cETH', assetId: F.ethAssetId, relayFeeEligible: true, recommendedWrapTipWei: '30000000000000' }),
    });
    chain.answer(TIPFWD, 'fc24c435', '0x');
    const p = await open(chain);
    p.type('pvAmt', '0.001');
    await p.waitFor(() => /Relay tip/.test(p.text('pvPrev')), { label: 'the tip in the preview', ...SLOW });
    p.click('pvGo');
    await p.waitFor(() => posts(p).some(x => x.type === 'wrap'), { label: 'the wrap to reach the relay', ...SLOW });
    assert.equal(p.chain.sentTo(TIPFWD).length, 1, 'the deposit rode the tip forwarder');
    const sub = posts(p).find(x => x.type === 'wrap'), tx = p.window.eval('cpNotes.find(n=>n.tx).tx');
    assert.match(tx, /^0x[0-9a-f]{64}$/);
    assert.equal(sub.depositTx, tx, 'the relay is told which transaction paid its tip');
    assert.equal(sub.mode, 'settle');
    p.close();
  });
});

describe('a relay that gave up on a settle it may still land', () => {
  test('keeps a split\'s halves until the send is forgotten, and forgetting says the settle may still land', async () => {
    const p = await open(withNote(poolChain()));
    await ready(p);
    useStream(p, S.xfer.tag);
    p.queuePrompt('0.0025');
    p.click(btn(p, 'split'));
    await p.waitFor(() => posts(p).some(x => x.type === 'transfer'), { label: 'the split to reach the relay', ...SLOW });
    p.chain.relay.status = { status: 'failed', error: 'settle reverted: timeout', broadcastHashes: ['0x' + 'ab'.repeat(32)] };
    await until(p, () => btn(p, 'sforget') && /failed/.test(p.text('pvList')), 'the failed split');
    const sid = p.window.eval('cpSends[0].id'), outs = `cpNotes.filter(n=>n.sid===${JSON.stringify(sid)})`;
    assert.equal(p.window.eval(outs + '.length'), 2, 'both halves are kept while the settle may still land');
    assert.match(p.text('pvList'), /Shielded 0 · settling 0\.0099 tETH/, 'and the note it spends is held, not counted twice');
    // It lands after all.
    settleOn(p.chain, { nullifiers: [F.nullifier], leaves: S.xfer.op.outputs.map(o => leafOf(o)), memos: S.xfer.memos });
    await until(p, () => p.window.eval(outs + '.every(n=>cpStatus(n).s==="ready")'), 'the halves on chain');
    p.queueConfirm(true);
    p.click(btn(p, 'sforget'));
    await p.waitFor(() => p.asked.confirm.length, { label: 'the forget to ask', ...SLOW });
    assert.match(p.asked.confirm[0], /may still settle it later/);
    await until(p, () => /0\.0025 tETH/.test(p.text('pvList')) && /0\.0074 tETH/.test(p.text('pvList')) && /Shielded 0\.0099 tETH/.test(p.text('pvList')), 'both halves as notes');
    assert.ok(!btn(p, 'sforget'), 'the send is gone');
    p.close();
  });

  test('marks a failed exit still pending from its broadcast hashes, so the retry keeps its own terms', async () => {
    const p = await open(poolChain());
    const key = p.window.eval(`(()=>{const n={i:-1,v:"1000000",s:"0x${'00'.repeat(31)}0b",b:"0x${'00'.repeat(31)}0d",at:nowS()};
      n.ex={ch:1,to:"${A.OTHER}",self:0,job:"0xjob9",js:"pending",du:String(nowS()+3600),dl:String(nowS()+259200),fee:"0",wei:"10000000000000000",nonce:"1"};
      cpNotes.push(n);window.__X=n;return cpKeyOf(n)})()`);
    // The error text was cut before it named the hashes; the status still carries them.
    p.chain.relay.status = { status: 'failed', error: 'settle reverted: replacement transaction underpriced', broadcastHashes: ['0x' + 'cd'.repeat(32)] };
    await p.window.eval('cpRelayPoll(__X)');
    assert.equal(p.window.eval('__X.ex.js'), 'failed');
    assert.match(p.window.eval('__X.ex.je'), /still pending/);
    p.window.eval('cpPaint()');
    const retry = [...p.$('pvList').querySelectorAll('button[data-a="exit"]')].find(b => b.dataset.k === key);
    assert.equal(retry?.textContent, 'retry');
    p.click(retry);
    await p.waitFor(() => p.asked.confirm.length || /has not settled|already exiting/.test(p.text('stat')), { label: 'the retry to answer', ...SLOW });
    assert.ok(!p.asked.confirm.some(m => /Build this exit again/.test(m)), 'a settle that may still land is not rebuilt');
    assert.match(p.text('stat'), /has not settled into the pool yet/);
    p.close();
  });

  test('keeps a take-back\'s note while its settle may still land, and a second take-back replaces it', async () => {
    const chain = withNote(poolChain());
    settleOn(chain, { nullifiers: [F.nullifier], lockLeaves: [S.lock.op.lockLeaf], lockMemos: [S.lock.memoFull] });
    const p = await open(chain);
    await until(p, () => /waiting for the recipient/.test(p.text('pvList')), 'the send, found from the key');
    p.window.Date.now = () => (Number(S.deadline) + 60) * 1000;
    await until(p, () => btn(p, 'srefund'), 'the take-back button');
    useStream(p, S.refund.tag);
    p.click(btn(p, 'srefund'));
    await p.waitFor(() => posts(p).some(x => x.type === 'stealthrefund'), { label: 'the take-back to reach the relay', ...SLOW });
    const outs = `cpNotes.filter(n=>n.sid===cpSends[0].id+"r")`;
    p.chain.relay.status = { status: 'failed', error: 'settle reverted: timeout', broadcastHashes: ['0x' + 'ef'.repeat(32)] };
    await until(p, () => btn(p, 'srefund'), 'the take-back offered again');
    assert.equal(p.window.eval(outs + '.length'), 1, 'the note it would return is kept while that settle may still land');
    // Gas moved, so the second take-back pays another fee and returns another note.
    p.chain.gasPrice = 10n ** 8n;
    p.chain.relay.status = { status: 'pending' };
    p.click(btn(p, 'srefund'));
    await p.waitFor(() => posts(p).filter(x => x.type === 'stealthrefund').length === 2, { label: 'the second take-back', ...SLOW });
    const [a, b] = posts(p).filter(x => x.type === 'stealthrefund');
    assert.notEqual(a.op.fee, b.op.fee);
    assert.equal(p.window.eval(outs + '.length'), 1, 'it replaces the first one\'s note rather than adding beside it');
    assert.equal(p.window.eval(outs + '[0].v'), String(1000000 - b.op.fee));
    p.close();
  });
});

describe('a deposit settled from this wallet', () => {
  const PV = '0x' + u256(32) + F.depositId.slice(2) + u256(7);
  const found = async () => {
    const chain = poolChain();
    wrapLog(chain);                        // deposited, not yet settled
    const p = await open(chain);
    p.select('pvPath', 'self');
    await until(p, () => btn(p, 'settle'), 'the deposit, found from the key');
    return p;
  };

  test('asks the relay again for a proof it reported before the proof was attached', async () => {
    const p = await found();
    p.chain.relay.status = { status: 'proven' };
    p.click(btn(p, 'settle'));
    await p.waitFor(() => posts(p).some(x => x.type === 'wrap'), { label: 'the wrap to reach the relay', ...SLOW });
    assert.equal(posts(p).find(x => x.type === 'wrap').mode, 'prove');
    await until(p, () => p.window.eval('cpNotes[0].js') === 'proven', 'the early proven status');
    const fresh = p.window.eval('cpNotes[0].memo');
    // A memo that does not open to this note under this key is not taken in place of the page's own.
    p.chain.relay.status = { status: 'proven', publicValues: PV, proof: '0x1234', memos: ['0x' + '11'.repeat(169)] };
    assert.ok(await tries(p, () => btn(p, 'wrapsend')), 'the proof is picked up and the settle offered');
    assert.equal(p.window.eval('cpNotes[0].pv'), PV);
    assert.equal(p.window.eval('cpNotes[0].memo'), fresh);
    p.close();
  });

  test('a found deposit settles with the memo its proof commits to', async () => {
    const p = await found();
    const fresh = p.window.eval('cpNotes[0].memo');
    assert.notEqual(fresh, F.memo, 'a found note is sealed afresh');
    p.chain.relay.status = { status: 'proven', publicValues: PV, proof: '0x1234', memos: [F.memo] };
    p.click(btn(p, 'settle'));
    await until(p, () => btn(p, 'wrapsend'), 'the proof');
    assert.equal(p.window.eval('cpNotes[0].memo'), F.memo, 'the memo the relay proved, which opens to this note');
    p.click(btn(p, 'wrapsend'));
    await p.waitFor(() => p.chain.sentTo(POOL).length === 1, { label: 'the settle', ...SLOW });
    const data = p.chain.sentTo(POOL)[0].data.toLowerCase();
    assert.equal(data.slice(0, 10), '0x' + SEL.SETTLE);
    assert.ok(data.includes(F.memo.slice(2).toLowerCase()), 'the settle carries the proven memo');
    assert.ok(!data.includes(fresh.slice(2).toLowerCase()), 'and not the one sealed on this visit');
    p.close();
  });
});

describe('a private send locked through the relay', () => {
  const sendLock = async () => {
    const p = await open(withNote(poolChain()));
    await ready(p);
    p.window.Date.now = () => (Number(S.deadline) - 7776000) * 1000;
    p.select('pvAct', 'send');
    await p.settle();
    p.type('pvAmt', '0.01');
    p.type('pvRc', S.lock.recipient);
    useStream(p, S.lock.tag);
    p.click('pvGo');
    await p.waitFor(() => posts(p).some(x => x.type === 'stealthlock'), { label: 'the lock to reach the relay', ...SLOW });
    return p;
  };

  test('a lock the relay failed is retried on the settle path chosen now', async () => {
    const p = await sendLock();
    assert.equal(posts(p).find(x => x.type === 'stealthlock').mode, 'settle');
    p.chain.relay.status = { status: 'failed', error: 'settle reverted: x' };
    await until(p, () => btn(p, 'slock'), 'the failed lock');
    p.chain.relay.status = { status: 'pending' };
    p.select('pvPath', 'self');
    p.click(btn(p, 'slock'));
    await p.waitFor(() => posts(p).filter(x => x.type === 'stealthlock').length === 2, { label: 'the retry', ...SLOW });
    assert.equal(posts(p).filter(x => x.type === 'stealthlock')[1].mode, 'prove', 'proved for this wallet to send');
    const lf = p.window.eval('cpSends[0].lf'), m = p.window.eval('cpSends[0].lop.m[0]');
    p.chain.relay.status = { status: 'proven', publicValues: '0x' + u256(32) + lf.slice(2), proof: '0x1234' };
    await until(p, () => btn(p, 'sgo'), 'the proof to send');
    p.click(btn(p, 'sgo'));
    await p.waitFor(() => p.chain.sentTo(POOL).length === 1, { label: 'the lock from this wallet', ...SLOW });
    assert.ok(p.chain.sentTo(POOL)[0].data.toLowerCase().includes(m.slice(2)), 'sent with the memo sealed here');
    settleOn(p.chain, { nullifiers: [F.nullifier], lockLeaves: [lf], lockMemos: [m] });
    await until(p, () => /waiting for the recipient/.test(p.text('pvList')), 'the lock to land');
    assert.doesNotMatch(p.text('stat'), /different memo/, 'a lock that lands with its sealed memo says nothing of it');
    p.close();
  });

  test('a lock that lands with another memo than the one sealed here is reported, and the sealed copy kept', async () => {
    const p = await sendLock();
    const sealed = posts(p).find(x => x.type === 'stealthlock').memos[0];
    assert.equal(sealed, S.lock.memoFull);
    // The settle drops the sender's tail: the recipient's part alone.
    settleOn(p.chain, { nullifiers: [F.nullifier], lockLeaves: [S.lock.op.lockLeaf], lockMemos: [S.lock.memo] });
    p.chain.relay.status = { status: 'settled' };
    await until(p, () => /waiting for the recipient/.test(p.text('pvList')), 'the lock to land');
    assert.match(p.text('stat'), /different memo than the one sealed here/);
    assert.equal(p.window.eval('cpSends[0].lop.m[0]'), sealed, 'the sealed memo stays on the send');
    p.close();
  });
});

describe('a payment behind a decoy', () => {
  test('a second call in the same batch claiming the lock with another memo does not hide it', async () => {
    const chain = withNote(poolChain());
    const nu = '0x' + '79'.repeat(32), decoy = '0x02' + 'ab'.repeat((S.claim.memo.length - 4) / 2);
    // The decoy rides first and never ran; the real call spends the same nullifier and emits it.
    relayOn(chain, [
      { failed: true, nullifiers: [nu], lockLeaves: [S.claim.leaf], lockMemos: [decoy] },
      { nullifiers: [nu], lockLeaves: [S.claim.leaf], lockMemos: [S.claim.memo] },
    ]);
    const p = await open(chain);
    await ready(p);
    assert.ok(await tries(p, () => /0\.03 tETH received privately/.test(p.text('pvList'))), 'the payment, found from the key');
    assert.equal(p.window.eval('cpPool.lk.length'), 1, 'one lock, not two');
    assert.ok(btn(p, 'claim'), 'and it can be claimed');
    p.close();
  });
});

// ---- cBTC, as cbtc.test.mjs serves it ----
describe('a cBTC escrow while the price feed is stale', () => {
  const ENGINE = '0x000000003f608BDdF0ca45934003ffb9DbDF70DB', WSTETH = '0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0';
  const HELPER = '0x000000008ecd09f922c9fbbdd9aca5ae8f0bebfa';
  const CS = { VBTC: '7cea1c1a', MINTED: 'e2c2a40c', SUFF: '058e18b0', HEALTH: '3feacb25', REQ: '034448ed', TOTAL: 'e06e89c9', POST: '2e03d0f1',
    ASSETS: '9fda5b66', NEXT: '0be4f422', DEPOSIT: '7da9874f', SETTLE: '717fd7f2' };
  const WANT = 46536158595228492n;
  const cbtcChain = () => {
    const chain = new MockChain();
    chain.blockNumber = '0x' + (B0 + 0x8).toString(16);
    chain.gasPrice = 10n ** 8n;
    chain.setNative(A.ACCOUNT, 10n * 10n ** 18n);
    chain.setErc20(WSTETH, A.ACCOUNT, 10n ** 18n);
    chain.lock = { vbtc: 0n, minted: 0n, ok: 0n, have: 0n };
    chain.answer(POOL, CS.VBTC, () => '0x' + u256(chain.lock.vbtc));
    chain.answer(POOL, CS.MINTED, () => '0x' + u256(chain.lock.minted));
    chain.answer(ENGINE, CS.SUFF, () => '0x' + u256(chain.lock.ok));
    chain.answer(ENGINE, CS.HEALTH, () => '0x' + u256(chain.lock.ok) + u256(chain.lock.have) + u256(WANT));
    chain.answer(ENGINE, CS.TOTAL, () => '0x' + u256(chain.lock.have));
    chain.answer(ENGINE, CS.REQ, '0x' + u256(WANT));
    chain.answer(ENGINE, CS.POST, '0x');
    chain.answer(POOL, CS.ASSETS, '0x' + u256(1) + u256(0) + u256(10n ** 10n) + F.ethAssetId.slice(2) + u256(0) + u256(18));
    chain.answer(POOL, CS.NEXT, '0x' + u256(0));
    chain.answer(POOL, CS.DEPOSIT, '0x' + u256(0));
    chain.answer(POOL, CS.SETTLE, '0x');
    chain.relay = { status: { status: 'pending' } };
    chain.lanes = {};
    Object.defineProperty(chain.lanes, RELAY + '/confidential/submit', { enumerable: true, get: () => ({ ok: true, jobId: '0xjobcbtc', status: 'pending' }) });
    Object.defineProperty(chain.lanes, RELAY + '/confidential/status', { enumerable: true, get: () => chain.relay.status });
    return chain;
  };

  test('is not reported as covered: the requirement it cannot read is an error, and nothing is posted', async () => {
    const p = await loadPage({ chain: cbtcChain(), storage: { ...KEY } });
    Object.defineProperty(p.window.crypto, 'getRandomValues', { configurable: true, value: a => a.fill(0) });
    await p.connect();
    p.click('pv');
    await p.settle();
    p.click('pvGo');
    await p.waitFor(() => /Key unlocked/.test(p.text('pvKey')), { label: 'the key to unlock' });
    p.chain.lanes['/address/' + F.btc.address + '/utxo'] = C.utxos;
    p.chain.lanes['/fee-estimates'] = { 2: C.feeRate };
    p.chain.lanes['api/tx'] = 'ok';
    p.queuePrompt('0.001');
    p.queueConfirm(true);
    p.click(p.$('pvKey').querySelector('button[data-a="lockbtc"]'));
    await p.waitFor(() => /Locked/.test(p.text('stat')), { label: 'the lock to be sent', ...SLOW });
    p.chain.lock.vbtc = BigInt(C.amountSats);
    p.chain.blockNumber = '0x' + (BigInt(p.chain.blockNumber) + 5n).toString(16);
    poke(p);
    await p.waitFor(() => btn(p, 'lesc'), { label: 'the escrow button', ...SLOW });
    // The BTC/USD feed goes stale: every priced read at the engine reverts.
    for (const s of [CS.REQ, CS.HEALTH, CS.SUFF]) { p.chain.answer(ENGINE, s, () => null); p.chain.revertOn(ENGINE, s, 'execution reverted: StalePrice()'); }
    p.queueConfirm(true);
    p.click(btn(p, 'lesc'));
    await p.waitFor(() => /could not be read|already covers/.test(p.text('stat')), { label: 'the escrow answer', ...SLOW });
    assert.match(p.text('stat'), /The escrow this lock needs could not be read/);
    assert.equal(p.chain.sentTo(HELPER).length + p.chain.sentTo(ENGINE).length + p.chain.sentTo(WSTETH).length, 0, 'nothing is posted');
    await p.settle();
    p.close();
  });
});
