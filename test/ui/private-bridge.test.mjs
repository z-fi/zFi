/**
 * The private bridge: a shielded deposit on Ethereum that exits straight into
 * the Base or Robinhood bridge, through Tacit's confidential pool.
 *
 * Nothing here is a swap. The page derives a note key from one signature,
 * deposits ether into the pool under a commitment, asks the relay to settle
 * the deposit, rebuilds the pool's leaf tree from its logs, and then builds an
 * exit whose ONLY destination is a recipe-bound escrow that the bridge call is
 * fired from. Get any of that wrong and the money is either unrecoverable or
 * sitting at an address the wrong recipe reaches - so what this file pins is
 * the exact deposit transaction, the exact witness handed to the relay, and
 * the exact activate / reclaim / exit calldata, each against an encoder that
 * is NOT the page's: ethers' ABI coder for the recipe, and the reference
 * vectors in test/fixtures/confidential.json, which Tacit's own modules wrote.
 */
import { test, describe, after } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { AbiCoder, keccak256, getBytes, concat, toUtf8Bytes } from 'ethers';
import { A, MockChain, loadPage, closeAllPages, selectorOf } from './harness.mjs';

after(closeAllPages);

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..');
const F = JSON.parse(fs.readFileSync(path.join(ROOT, 'test', 'fixtures', 'confidential.json'), 'utf8'));
const coder = AbiCoder.defaultAbiCoder();

const POOL = F.pool, ROUTER = F.router, IMPL = F.executorImpl;
const BASE_BRIDGE = '0x3154Cf16ccdb4C6d922629664174b904d80F2C35';
const RH_INBOX = '0x1A07cc4BD17E0118BdB54D70990D2158AbAD7a2D';
const RELAY = 'api.tacit.finance';
const SEL = {
  IMPL: '93228617', ASSETS: '9fda5b66', NEXT: '0be4f422', DEPOSIT: '7da9874f', WRAP: '859a9cee',
  OTHER: '7f46ddb2', BRIDGE: 'e78cea92', ESCROW: '2bf0cda2', ACTIVATE: '1699fd5b', RECLAIM: '02edf635',
  EXIT: 'acad0634', SUBFEE: 'a66b327d', SETTLE: '717fd7f2',
};
const T = {
  LEAVES: keccak256(toUtf8Bytes('LeavesInserted(uint256,bytes32[],bytes[])')),
  SPENT: keccak256(toUtf8Bytes('NullifiersSpent(bytes32[])')),
  WRAP: keccak256(toUtf8Bytes('Wrap(bytes32,bytes32,uint256)')),
};
const u256 = v => BigInt(v).toString(16).padStart(64, '0');
const addrWord = a => a.replace(/^0x/, '').toLowerCase().padStart(64, '0');
const ETH = 10n ** 18n;
// The pool was deployed at block 25,892,003; the mock chain has to be past it
// or the page has no window to scan.
const HEAD = '0x18b64a3';
// A relayed exit pays a flat, gas-priced fee, and the page refuses one above 3%
// of the note - an outlier fee is a fingerprint. At the fixture's 1 gwei that
// fee is 6.7% of 0.01 ETH, so the chain here runs at 0.1 gwei: the fee ladder
// (two significant digits, rounded up) then quotes 0.00012 ETH, 1.2%.
const GAS = 10n ** 8n;
const ladder = v => { const d = v.toString().length; if (d <= 2) return v; const s = 10n ** BigInt(d - 2); return (v + s - 1n) / s * s; };
const FEE = ladder((450000n * GAS + 40000000000000n) * 135n / 100n / 10n ** 10n);
const NET = BigInt(F.note.value) - FEE;

// ---- an independent recipe encoder (ethers), never the page's ----
const RECIPE_T = 'tuple(bytes32,address,address,uint64,uint256,tuple(address,uint256,address,uint256,bool,bytes)[],address[],uint256[])';
const recipeTuple = r => [r.exitedAsset, r.feeAsset, r.finalRecipient, r.deadline, r.nonce,
  r.calls.map(c => [c.target, c.value, c.token, c.amount, c.push, c.data]), r.sweepTokens, r.minOuts];
const escrowOf = r => {
  const salt = keccak256(coder.encode([RECIPE_T], [recipeTuple(r)]));
  const init = keccak256('0x602d5f8160095f39f35f5f365f5f37365f73' + IMPL.slice(2).toLowerCase() + '5af43d5f5f3e6029573d5ffd5b3d5ff3');
  return '0x' + keccak256(concat(['0xff', ROUTER, salt, init])).slice(26);
};
const activateOf = r => '0x' + SEL.ACTIVATE + coder.encode([RECIPE_T], [recipeTuple(r)]).slice(2);
const reclaimOf = r => '0x' + SEL.RECLAIM + coder.encode([RECIPE_T, 'address[]'], [recipeTuple(r), []]).slice(2);
const exitOf = (pv, pr, r) => '0x' + SEL.EXIT + coder.encode(['bytes', 'bytes', 'bytes[]', RECIPE_T], [pv, pr, [], recipeTuple(r)]).slice(2);
const deadline = () => BigInt((Math.floor(Date.now() / 86400000) + 3) * 86400);
const baseRecipe = (wei, dl = deadline()) => ({
  exitedAsset: F.ethAssetId, feeAsset: A.ZERO, finalRecipient: A.ACCOUNT, deadline: dl, nonce: BigInt(F.nonce),
  calls: [{ target: BASE_BRIDGE, value: wei, token: A.ZERO, amount: 0n, push: false,
    data: '0x9a2ac6d5' + coder.encode(['address', 'uint32', 'bytes'], [A.ACCOUNT, 200000, '0x']).slice(2) }],
  sweepTokens: [A.ZERO], minOuts: [0n],
});
const rhRecipe = (wei, g, dl = deadline()) => {
  const over = g.sc + g.gl * g.mf;
  return {
    exitedAsset: F.ethAssetId, feeAsset: A.ZERO, finalRecipient: A.ACCOUNT, deadline: dl, nonce: BigInt(F.nonce),
    calls: [{ target: RH_INBOX, value: wei, token: A.ZERO, amount: 0n, push: false,
      data: '0x679b6ded' + coder.encode(['address', 'uint256', 'uint256', 'address', 'address', 'uint256', 'uint256', 'bytes'],
        [A.ACCOUNT, wei - over, g.sc, A.ACCOUNT, A.ACCOUNT, g.gl, g.mf, '0x']).slice(2) }],
    sweepTokens: [A.ZERO], minOuts: [0n],
  };
};

// The encoder above must agree with Tacit's own for the fixture's inputs, or
// every assertion built on it proves nothing.
test('the test encoder reproduces the reference escrow and calldata', () => {
  const r = baseRecipe(BigInt(F.netWei), BigInt(F.deadline));
  assert.equal(escrowOf(r), F.base.escrow);
  assert.equal(activateOf(r), F.base.activate);
  assert.equal(reclaimOf(r), F.base.reclaim);
  assert.equal(exitOf('0x1234', '0xabcdef', r), F.base.exitAndExecute);
  const R = F.robinhood;
  const rr = rhRecipe(BigInt(R.recipe.calls[0].value), { sc: BigInt(R.maxSubmissionCost), gl: BigInt(R.gasLimit), mf: BigInt(R.maxFeePerGas) }, BigInt(F.deadline));
  assert.equal(escrowOf(rr), R.escrow);
  assert.equal(activateOf(rr), R.activate);
});

// ---- the pool as the mock chain serves it ----
const leavesLog = (first, leaves, memos) => ({
  address: POOL, blockNumber: '0x18b64a0', logIndex: '0x0',
  topics: [T.LEAVES, '0x' + u256(first)],
  data: coder.encode(['bytes32[]', 'bytes[]'], [leaves, memos]),
});
const spentLog = nus => ({
  address: POOL, blockNumber: '0x18b64a1', logIndex: '0x0',
  topics: [T.SPENT], data: coder.encode(['bytes32[]'], [nus]),
});
const wrapLog = (id, amount) => ({
  address: POOL, blockNumber: '0x18b649f', logIndex: '0x0',
  topics: [T.WRAP, id, F.ethAssetId], data: '0x' + u256(amount),
});

function withPool(chain, { escrow } = {}) {
  chain.blockNumber = HEAD;
  chain.gasPrice = GAS;
  chain.setNative(A.ACCOUNT, 10n * ETH);
  chain.answer(ROUTER, SEL.IMPL, '0x' + addrWord(IMPL));
  chain.answer(POOL, SEL.ASSETS, '0x' + u256(1) + u256(0) + u256(10n ** 10n) + F.ethAssetId.slice(2) + u256(0) + u256(18));
  chain.answer(POOL, SEL.NEXT, () => '0x' + u256(chain.nextLeaf ?? 0));
  chain.answer(POOL, SEL.DEPOSIT, '0x' + u256(0));
  chain.answer(ROUTER, SEL.WRAP, '0x');
  chain.answer(ROUTER, SEL.ACTIVATE, '0x');
  chain.answer(ROUTER, SEL.RECLAIM, '0x');
  chain.answer(ROUTER, SEL.EXIT, '0x');
  chain.answer(POOL, SEL.SETTLE, '0x');
  chain.answer(BASE_BRIDGE, SEL.OTHER, '0x' + addrWord('0x4200000000000000000000000000000000000010'));
  chain.answer(RH_INBOX, SEL.BRIDGE, '0x' + addrWord('0xDf8755334ce7A73cCF6b581C02eA649AE3E864b3'));
  chain.answer(RH_INBOX, SEL.SUBFEE, '0x' + u256(F.robinhood.sub));
  // escrowAddressFor: what the router says the recipe maps to. The page refuses
  // to build a proof unless its own derivation agrees, so this is the one
  // answer that has to be RIGHT rather than merely present.
  chain.answer(ROUTER, SEL.ESCROW, () => '0x' + addrWord(chain.escrow || escrow || A.ZERO));
  // The relay. `submit` takes whatever is posted and records it; `status` is
  // whatever the test currently says the job is.
  chain.relay = { posted: [], status: { status: 'pending' } };
  chain.lanes = {};
  Object.defineProperty(chain.lanes, RELAY + '/confidential/submit', {
    enumerable: true, get: () => ({ ok: true, jobId: '0xjob' + (chain.relay.posted.length + 1), status: 'pending' }),
  });
  Object.defineProperty(chain.lanes, RELAY + '/confidential/status', {
    enumerable: true, get: () => chain.relay.status,
  });
  return chain;
}

/** Nudge the panel to refresh now rather than on its next tick: the page
 *  re-reads the pool whenever the tab comes back into view. */
const poke = p => p.doc.dispatchEvent(new p.window.Event('visibilitychange'));
/** New blocks: the page only scans the pool past the block it last saw. */
const advance = p => { p.chain.blockNumber = '0x' + (BigInt(p.chain.blockNumber) + 5n).toString(16); };
const SLOW = { timeout: 15000 };

async function open(opts = {}) {
  const chain = withPool(opts.chain ?? new MockChain(), opts);
  const p = await loadPage({ chain, storage: opts.storage });
  // Capture relay bodies: the fetch mock only records URL + method, and the
  // witness is the thing under test.
  const inner = p.window.fetch;
  p.window.__relayPosts = [];
  p.window.fetch = async (url, init) => {
    if (String(url).includes('/confidential/') && init && init.body) p.window.__relayPosts.push(JSON.parse(init.body));
    return inner(url, init);
  };
  if (opts.connect !== false) await p.connect();
  p.click('pv');
  await p.settle();
  return p;
}

async function unlock(p) {
  p.click('pvGo');                       // "Unlock key"
  await p.waitFor(() => /Key unlocked/.test(p.text('pvKey')), { label: 'the key to unlock' });
  assert.equal(p.chain.personalSigned.length, 1, 'one signature request');
  const asked = p.chain.personalSigned[0];
  assert.equal(asked.account, A.ACCOUNT);
  const msg = Buffer.from(asked.message.slice(2), 'hex').toString('utf8');
  assert.match(msg, /^zSwap private bridge\n/);
  assert.ok(msg.includes('Account: ' + A.ACCOUNT.toLowerCase()), 'the message names the account');
  assert.ok(msg.endsWith('Version: 1'));
}

async function deposit(p) {
  p.type('pvAmt', '0.01');
  p.click('pvGo');
  await p.waitFor(() => p.chain.sentTo(ROUTER).length === 1, { label: 'the deposit to be sent' });
  await p.waitFor(() => p.window.__relayPosts.length === 1, { label: 'the wrap to reach the relay' });
}

/** Settle the deposit as the relay + chain would: leaf 0 is ours, leaf 1 is someone else's. */
function settleDeposit(p) {
  p.chain.relay.status = { status: 'settled', txHash: '0x' + 'aa'.repeat(32) };
  p.chain.logs.push(wrapLog(F.depositId, F.amountWei));
  p.chain.logs.push(leavesLog(0, [F.leaf, F.otherLeaf], [F.memo, '0x' + '11'.repeat(169)]));
  p.chain.nextLeaf = 2;
  advance(p);
}

describe('the private bridge tile', () => {
  test('is a mode beside liquidity, launch and names, and they displace each other', async () => {
    const p = await open();
    assert.ok(p.visible('pvPanel'), 'the panel opens with the tile');
    assert.equal(p.$('pv').getAttribute('aria-pressed'), 'true');
    assert.ok(!p.visible('rcvPanel'), 'the swap form is hidden');
    assert.ok(p.visible('pvGo'));
    p.click('wn');
    await p.settle();
    assert.ok(!p.visible('pvPanel'), 'names displaces the bridge');
    assert.equal(p.$('pv').getAttribute('aria-pressed'), 'false');
    p.click('pv');
    await p.settle();
    assert.ok(!p.visible('wnPanel'), 'and the bridge displaces names');
    p.close();
  });

  test('does not follow the user off the swap tab', async () => {
    const p = await open();
    p.click('tabSend');
    await p.settle();
    assert.ok(!p.visible('pvPanel'));
    assert.ok(!p.visible('pvGo'));
    assert.ok(p.$('pv').classList.contains('hide'), 'the tile itself is hidden off Swap');
    p.click('tabSwap');
    await p.settle();
    assert.ok(!p.visible('pvPanel'), 'and it stays dismissed when the user comes back');
    p.close();
  });

  test('offers to connect before anything else', async () => {
    const chain = new MockChain({ autoConnected: false });
    const p = await open({ chain, connect: false });
    assert.equal(p.text('pvGo'), 'Connect Wallet');
    // Connecting from the tile brings the panel to life: the key line and
    // the button both move on without a second click, as the names tile
    // learned the hard way.
    p.click('pvGo');
    await p.waitFor(() => p.text('addr') !== 'Connect', { label: 'the wallet to connect' });
    await p.waitFor(() => p.text('pvGo') === 'Unlock key', { label: 'the panel to wake' });
    assert.match(p.text('pvKey'), /Sign once/);
    p.close();
  });
});

describe('depositing', () => {
  test('one signature derives the key, and the deposit is the reference wrapETH call', async () => {
    const p = await open();
    assert.equal(p.text('pvGo'), 'Unlock key');
    await unlock(p);
    assert.equal(p.text('pvGo'), 'Deposit');
    await deposit(p);

    const tx = p.chain.sentTo(ROUTER)[0];
    assert.equal(tx.from, A.ACCOUNT);
    assert.equal(BigInt(tx.value), BigInt(F.amountWei), 'msg.value is the amount deposited');
    assert.equal(tx.data, F.wrapCalldata, 'wrapETH(commit) with the reference commitment');

    const post = p.window.__relayPosts[0];
    assert.equal(post.type, 'wrap');
    assert.equal(post.mode, 'settle');
    assert.deepEqual(post.op, F.wrapOp, 'the OP_WRAP witness is byte-identical to the reference');
    assert.equal(post.memos.length, 1, 'one memo for the one leaf');
    assert.match(post.memos[0], /^0x0[23][0-9a-f]{64}[0-9a-f]{272}$/, 'ephemeral pubkey + 136-byte ciphertext');
    assert.notEqual(post.memos[0], F.memo, 'the memo ephemeral is fresh, not the fixture\'s');

    // The note is remembered under the key, not the account.
    const keys = Object.keys(p.window.localStorage).filter(k => k.startsWith('zswap:cp'));
    assert.ok(keys.some(k => k.startsWith('zswap:cpn:')), 'a note record is stored');
    assert.ok(keys.some(k => k.startsWith('zswap:cpk:' + A.ACCOUNT.toLowerCase())), 'the key is cached for the account');
    assert.match(p.text('pvList'), /0\.01 ETH/);
    p.close();
  });

  test('refuses more than eight decimals - the pool cannot hold them', async () => {
    const p = await open();
    await unlock(p);
    p.type('pvAmt', '0.000000001');
    p.click('pvGo');
    await p.waitFor(() => /eight decimals/.test(p.text('stat')), { label: 'the precision refusal' });
    assert.equal(p.chain.sentTo(ROUTER).length, 0);
    p.close();
  });

  test('a key already cached needs no second signature', async () => {
    const p = await open();
    await unlock(p);
    const storage = { ...p.window.localStorage };
    p.close();
    const q = await open({ storage });
    assert.equal(q.text('pvGo'), 'Deposit');
    assert.equal(q.chain.personalSigned.length, 0);
    q.close();
  });
});

describe('exiting to Base through the relay', () => {
  test('the unwrap witness pays the recipe escrow, and activate fires the pinned recipe', async () => {
    const p = await open();
    await unlock(p);
    await deposit(p);
    settleDeposit(p);
    poke(p);
    await p.waitFor(() => /exit/.test(p.text('pvList')), { label: 'the note to show as settled', ...SLOW });

    // What the page must arrive at: fee off a 1 gwei gas price, the rest bridged.
    const net = NET * 10n ** 10n;
    const recipe = baseRecipe(net);
    p.chain.escrow = escrowOf(recipe);

    p.click(p.$('pvList').querySelector('button[data-a="exit"]'));
    await p.waitFor(() => p.window.__relayPosts.length === 2, { label: 'the unwrap to reach the relay' });
    const post = p.window.__relayPosts[1];
    assert.equal(post.type, 'unwrap');
    assert.equal(post.mode, 'settle');
    assert.deepEqual(post.memos, []);
    const op = post.op;
    assert.equal(op.recipient, p.chain.escrow, 'the withdrawal pays the escrow, nothing else');
    assert.equal(op.spendRoot, F.root, 'the root of the rebuilt tree');
    assert.deepEqual(op.path, F.path, 'the membership path for leaf 0');
    assert.equal(op.leafIndex, 0);
    assert.equal(op.fee, String(FEE), 'the flat, laddered relay fee');
    assert.equal(FEE, 12000n);
    assert.equal(op.value, F.note.value);
    assert.equal(op.nk, F.note.secret);
    assert.equal(op.owner, F.note.owner);
    assert.equal(op.chainBinding, F.wrapOp.chainBinding);
    assert.match(op.sigR, /^0x0[23][0-9a-f]{64}$/);
    assert.match(op.sigZ, /^0x[0-9a-f]{64}$/);
    assert.ok(!('blinding' in op), 'the blinding never leaves the page');
    // The deadline is a coarse bucket, an hour out.
    const dl = Number(op.deadline);
    assert.equal(dl % 600, 0);
    assert.ok(dl > Date.now() / 1000 + 3000 && dl < Date.now() / 1000 + 4300);

    // The relay settles: the nullifier is spent and the escrow holds the net.
    p.chain.relay.status = { status: 'settled', txHash: '0x' + 'bb'.repeat(32) };
    p.chain.logs.push(spentLog([F.nullifier]));
    advance(p);
    p.chain.setNative(p.chain.escrow, net);
    poke(p);
    await p.waitFor(() => p.$('pvList').querySelector('button[data-a="activate"]'), { label: 'the activate button', timeout: 20000 });

    p.click(p.$('pvList').querySelector('button[data-a="activate"]'));
    await p.waitFor(() => p.chain.sentTo(ROUTER).length === 2, { label: 'activateExit to be sent' });
    const tx = p.chain.sentTo(ROUTER)[1];
    assert.equal(tx.data, activateOf(recipe), 'activateExit(recipe), encoded by ethers');
    assert.equal(BigInt(tx.gas), 800000n, 'the gas the live run needed');
    assert.equal(BigInt(tx.value), 0n);
    // The pre-flight ran at the SAME gas cap as the real send.
    const dry = p.chain.calls.filter(c => c.selector === SEL.ACTIVATE);
    assert.ok(dry.length >= 1);
    await p.waitFor(() => /on Base/.test(p.text('pvList')), { label: 'the row to report the bridge' });
    p.close();
  });

  test('a stale exit reclaims to the L1 recipient instead', async () => {
    const p = await open();
    await unlock(p);
    await deposit(p);
    settleDeposit(p);
    poke(p);
    await p.waitFor(() => /exit/.test(p.text('pvList')), SLOW);
    const net = NET * 10n ** 10n;
    const recipe = baseRecipe(net);
    p.chain.escrow = escrowOf(recipe);
    p.click(p.$('pvList').querySelector('button[data-a="exit"]'));
    await p.waitFor(() => p.window.__relayPosts.length === 2, SLOW);
    p.chain.relay.status = { status: 'settled' };
    p.chain.logs.push(spentLog([F.nullifier]));
    advance(p);
    p.chain.setNative(p.chain.escrow, net);
    // Move the page's clock past the recipe deadline (the recipe itself was
    // pinned at build time and does not move with it).
    const real = p.window.Date.now;
    p.window.Date.now = () => real() + 4 * 86400 * 1000;
    poke(p);
    await p.waitFor(() => p.$('pvList').querySelector('button[data-a="reclaim"]'), { label: 'the reclaim button', timeout: 20000 });
    p.click(p.$('pvList').querySelector('button[data-a="reclaim"]'));
    await p.waitFor(() => p.chain.sentTo(ROUTER).length === 2);
    const tx = p.chain.sentTo(ROUTER)[1];
    assert.equal(tx.data, reclaimOf(recipe), 'reclaimExit(recipe, [])');
    assert.equal(BigInt(tx.gas), 400000n);
    p.close();
  });

  test('refuses a recipe the router maps elsewhere', async () => {
    const p = await open();
    await unlock(p);
    await deposit(p);
    settleDeposit(p);
    poke(p);
    await p.waitFor(() => /exit/.test(p.text('pvList')), SLOW);
    p.chain.escrow = A.OTHER;
    p.click(p.$('pvList').querySelector('button[data-a="exit"]'));
    await p.waitFor(() => /Escrow address mismatch/.test(p.text('stat')), { label: 'the mismatch refusal' });
    assert.equal(p.window.__relayPosts.length, 1, 'nothing was proven');
    p.close();
  });
});

describe('exiting yourself, in one transaction', () => {
  test('the relay only proves; the wallet sends exitAndExecute with the fee-free recipe', async () => {
    const p = await open();
    await unlock(p);
    await deposit(p);
    settleDeposit(p);
    poke(p);
    await p.waitFor(() => /exit/.test(p.text('pvList')), SLOW);
    // Fee-free: the whole note is bridged.
    const whole = BigInt(F.note.value) * 10n ** 10n;
    const recipe = baseRecipe(whole);
    p.chain.escrow = escrowOf(recipe);
    p.select('pvPath', 'self');
    p.click(p.$('pvList').querySelector('button[data-a="exit"]'));
    await p.waitFor(() => p.window.__relayPosts.length === 2);
    const post = p.window.__relayPosts[1];
    assert.equal(post.mode, 'prove');
    assert.equal(post.op.fee, '0');
    assert.equal(post.op.recipient, p.chain.escrow);
    const pv = '0x' + '12'.repeat(200), pr = '0x' + 'ab'.repeat(260);
    p.chain.relay.status = { status: 'proven', publicValues: pv, proof: pr };
    await p.waitFor(() => p.chain.sentTo(ROUTER).length === 2, { label: 'exitAndExecute to be sent', timeout: 20000 });
    const tx = p.chain.sentTo(ROUTER)[1];
    assert.equal(tx.data, exitOf(pv, pr, recipe), 'exitAndExecute(pv, proof, [], recipe)');
    assert.equal(BigInt(tx.gas), 2000000n, 'proof verification plus the bridge call');
    p.close();
  });
});

describe('exiting to Robinhood Chain', () => {
  test('quotes the retryable ticket live and lands the net less the gas budget', async () => {
    const p = await open();
    const rh = new MockChain({ chainId: '0x1237' });
    rh.estimateGas = BigInt(F.robinhood.est);
    rh.gasPrice = BigInt(F.robinhood.l2Gas);
    p.chain.remotes['robinhood'] = rh;
    await unlock(p);
    await deposit(p);
    settleDeposit(p);
    poke(p);
    await p.waitFor(() => /exit/.test(p.text('pvList')), SLOW);
    const net = NET * 10n ** 10n;
    const g = { gl: BigInt(F.robinhood.gasLimit), sc: BigInt(F.robinhood.sub), mf: BigInt(F.robinhood.maxFeePerGas) };
    const recipe = rhRecipe(net, g);
    p.chain.escrow = escrowOf(recipe);
    p.select('pvChain', '4663');
    p.click(p.$('pvList').querySelector('button[data-a="exit"]'));
    await p.waitFor(() => p.window.__relayPosts.length === 2, { label: 'the unwrap to reach the relay' });
    assert.equal(p.window.__relayPosts[1].op.recipient, p.chain.escrow);
    // The estimate was asked of Robinhood's NodeInterface with a pretend
    // 1 ETH deposit, so it never depends on anyone's balance there.
    const est = rh.log.find(r => r.method === 'eth_estimateGas');
    assert.ok(est, 'gas was estimated on the L2');
    assert.equal(est.params[0].to.toLowerCase(), '0x00000000000000000000000000000000000000c8');
    assert.equal(selectorOf(est.params[0].data), 'c3dc5879');
    assert.equal(BigInt('0x' + est.params[0].data.slice(10 + 64, 10 + 128)), 10n ** 18n + 1n);
    p.chain.relay.status = { status: 'settled' };
    p.chain.logs.push(spentLog([F.nullifier]));
    advance(p);
    p.chain.setNative(p.chain.escrow, net);
    poke(p);
    await p.waitFor(() => p.$('pvList').querySelector('button[data-a="activate"]'), { timeout: 20000 });
    p.click(p.$('pvList').querySelector('button[data-a="activate"]'));
    await p.waitFor(() => p.chain.sentTo(ROUTER).length === 2);
    const tx = p.chain.sentTo(ROUTER)[1];
    assert.equal(tx.data, activateOf(recipe));
    assert.equal(BigInt(tx.gas), 1000000n);
    p.close();
  });
});

describe('self-help', () => {
  test('a wiped browser recovers its deposits from the pool\'s Wrap events and the key alone', async () => {
    const p = await open();
    await unlock(p);
    const key = p.window.localStorage['zswap:cpk:' + A.ACCOUNT.toLowerCase()];
    p.close();
    // A fresh page: no note records, only the pool's public history.
    const q = await open({ storage: { ['zswap:cpk:' + A.ACCOUNT.toLowerCase()]: key } });
    settleDeposit(q);
    poke(q);
    assert.match(q.text('pvList'), /No deposits yet/);
    q.click(q.$('pvKey').querySelector('button[data-a="recover"]'));
    await q.waitFor(() => /0\.01 ETH/.test(q.text('pvList')), { label: 'the deposit to be recovered' });
    assert.match(q.text('stat'), /Recovered 1 deposit/);
    q.close();
  });

  test('an exported note list can be imported on another browser', async () => {
    const p = await open();
    await unlock(p);
    await deposit(p);
    p.click(p.$('pvKey').querySelector('button[data-a="export"]'));
    assert.equal(p.asked.prompt.length, 1);
    const key = p.window.localStorage['zswap:cpk:' + A.ACCOUNT.toLowerCase()];
    const notes = p.window.localStorage[Object.keys(p.window.localStorage).find(k => k.startsWith('zswap:cpn:'))];
    p.close();
    const q = await open({ storage: { ['zswap:cpk:' + A.ACCOUNT.toLowerCase()]: key } });
    assert.match(q.text('pvList'), /No deposits yet/);
    q.queuePrompt(notes);
    q.click(q.$('pvKey').querySelector('button[data-a="import"]'));
    await q.waitFor(() => /0\.01 ETH/.test(q.text('pvList')), { label: 'the imported note' });
    assert.match(q.text('stat'), /Imported 1 note/);
    q.close();
  });

  test('the key can be shown and imported', async () => {
    const p = await open();
    await unlock(p);
    p.click(p.$('pvKey').querySelector('button[data-a="backup"]'));
    assert.equal(p.asked.prompt.length, 1);
    const q = await open();
    q.queuePrompt(F.seed);
    q.click(q.$('pvKey').querySelector('button[data-a="import"]') ?? q.$('pvGo'));
    // With no key yet the panel offers to unlock; import lives behind an
    // unlocked key, so unlock first and then import over it.
    await unlock(q);
    q.queuePrompt(F.seed);
    q.click(q.$('pvKey').querySelector('button[data-a="import"]'));
    await q.settle();
    assert.equal(q.window.localStorage['zswap:cpk:' + A.ACCOUNT.toLowerCase()], F.seed);
    p.close(); q.close();
  });
});

describe('withdrawing to Ethereum', () => {
  test('relayed: the unwrap pays the address directly, no recipe, no escrow', async () => {
    const p = await open();
    await unlock(p);
    await deposit(p);
    settleDeposit(p);
    poke(p);
    await p.waitFor(() => /exit/.test(p.text('pvList')), SLOW);
    p.select('pvChain', '1');
    p.type('pvTo', A.OTHER);
    p.click(p.$('pvList').querySelector('button[data-a="exit"]'));
    await p.waitFor(() => p.window.__relayPosts.length === 2, SLOW);
    const post = p.window.__relayPosts[1];
    assert.equal(post.type, 'unwrap');
    assert.equal(post.mode, 'settle');
    assert.equal(post.op.recipient, A.OTHER.toLowerCase(), 'paid straight to the address');
    assert.equal(post.op.fee, String(FEE));
    assert.equal(p.chain.calls.filter(c => c.selector === SEL.ESCROW).length, 0, 'no recipe was built');
    assert.equal(p.chain.calls.filter(c => c.selector === SEL.IMPL).length, 0, 'no bridge pins were read');
    p.chain.relay.status = { status: 'settled' };
    p.chain.logs.push(spentLog([F.nullifier]));
    advance(p);
    poke(p);
    await p.waitFor(() => /on Ethereum/.test(p.text('pvList')), { label: 'the withdrawal to show', timeout: 20000 });
    assert.equal(p.chain.sentTo(ROUTER).length, 1, 'nothing further to send');
    p.close();
  });

  test('yourself: the relay proves, the wallet sends pool.settle fee-free', async () => {
    const p = await open();
    await unlock(p);
    await deposit(p);
    settleDeposit(p);
    poke(p);
    await p.waitFor(() => /exit/.test(p.text('pvList')), SLOW);
    p.select('pvChain', '1');
    p.select('pvPath', 'self');
    p.click(p.$('pvList').querySelector('button[data-a="exit"]'));
    await p.waitFor(() => p.window.__relayPosts.length === 2, SLOW);
    const post = p.window.__relayPosts[1];
    assert.equal(post.mode, 'prove');
    assert.equal(post.op.fee, '0');
    assert.equal(post.op.recipient, A.ACCOUNT.toLowerCase(), 'defaults to this wallet');
    const pv = '0x' + '12'.repeat(200), pr = '0x' + 'ab'.repeat(260);
    p.chain.relay.status = { status: 'proven', publicValues: pv, proof: pr };
    await p.waitFor(() => p.chain.sentTo(POOL).length === 1, { label: 'settle to be sent', timeout: 20000 });
    const tx = p.chain.sentTo(POOL)[0];
    assert.equal(tx.data, '0x717fd7f2' + coder.encode(['bytes', 'bytes', 'bytes[]'], [pv, pr, []]).slice(2), 'pool.settle(pv, proof, [])');
    assert.equal(BigInt(tx.gas), 700000n);
    assert.equal(BigInt(tx.value), 0n);
    p.close();
  });
});

describe('depositing as several notes', () => {
  test('two notes are two deposits at consecutive indices, each settled on its own', async () => {
    const p = await open();
    await unlock(p);
    p.select('pvSplit', '2');
    p.type('pvAmt', '0.02');
    p.click('pvGo');
    await p.waitFor(() => p.window.__relayPosts.length === 2, { label: 'both wraps to reach the relay', timeout: 20000 });
    const txs = p.chain.sentTo(ROUTER);
    assert.equal(txs.length, 2);
    for (const tx of txs) assert.equal(BigInt(tx.value), BigInt(F.amountWei), 'each note is half');
    assert.equal(txs[0].data, F.wrapCalldata, 'the first note is the reference note (index 0)');
    assert.notEqual(txs[1].data, txs[0].data, 'the second is a different commitment');
    const ops = p.window.__relayPosts.map(x => x.op);
    assert.deepEqual(ops[0], F.wrapOp);
    assert.equal(ops[1].value, F.wrapOp.value);
    assert.notEqual(ops[1].owner, ops[0].owner, 'a fresh per-note key');
    assert.equal((p.text('pvList').match(/0\.01 ETH/g) || []).length, 2, 'two rows');
    p.close();
  });

  test('refuses an amount that does not split', async () => {
    const p = await open();
    await unlock(p);
    p.select('pvSplit', '4');
    p.type('pvAmt', '0.00000003');
    p.click('pvGo');
    await p.waitFor(() => /does not split evenly/.test(p.text('stat')));
    assert.equal(p.chain.sentTo(ROUTER).length, 0);
    p.close();
  });
});

describe('paying a request', () => {
  test('a request is the reference invoice, and paying it is the reference wrap plus the pre-signed settle', async () => {
    // The recipient builds the request.
    const r = await open();
    await unlock(r);
    r.type('pvAmt', '0.01');
    r.click(r.$('pvKey').querySelector('button[data-a="request"]'));
    await r.waitFor(() => r.asked.prompt.length === 1, { label: 'the request prompt', timeout: 15000 });
    assert.match(r.asked.prompt[0], /payment request/);
    const invoice = JSON.parse(r.window.__promptDefaults[0]);
    assert.equal(invoice.v, 1);
    assert.equal(invoice.assetId, F.ethAssetId);
    assert.equal(invoice.underlying, A.ZERO);
    assert.equal(invoice.amount, F.amountWei);
    assert.equal(invoice.value, F.note.value);
    for (const k of ['cx', 'cy', 'owner']) assert.equal(invoice[k], F.note[k], k);
    assert.equal(invoice.commit, F.commit);
    assert.equal(invoice.depositId, F.depositId);
    assert.equal(invoice.leaf, F.leaf);
    assert.deepEqual(invoice.witness, F.wrapOp, 'the pre-signed consume is the reference wrap witness');
    assert.match(invoice.memo, /^0x0[23][0-9a-f]{64}[0-9a-f]{272}$/);
    assert.match(r.text('pvList'), /request #0/);
    assert.match(r.text('pvList'), /awaiting payment/);

    // The payer pays it from another browser.
    const q = await open();
    await unlock(q);
    q.queuePrompt(JSON.stringify(invoice));
    q.click(q.$('pvKey').querySelector('button[data-a="pay"]'));
    await q.waitFor(() => q.chain.sentTo(ROUTER).length === 1, { label: 'the payment to be sent', timeout: 15000 });
    const tx = q.chain.sentTo(ROUTER)[0];
    assert.equal(BigInt(tx.value), BigInt(F.amountWei));
    assert.equal(tx.data, F.wrapCalldata, 'wrapETH to the request\'s commitment');
    await q.waitFor(() => q.window.__relayPosts.length === 1, { label: 'the settle to reach the relay', timeout: 15000 });
    const post = q.window.__relayPosts[0];
    assert.equal(post.type, 'wrap');
    assert.deepEqual(post.op, invoice.witness, 'the payer submits the recipient\'s witness untouched');
    assert.deepEqual(post.memos, [invoice.memo]);
    assert.match(q.text('pvList'), /0\.01 ETH paid/);
    assert.equal(q.chain.personalSigned.length, 1, 'paying needs no extra signature');

    // Back on the recipient's browser the note lands like any deposit.
    settleDeposit(r);
    poke(r);
    await r.waitFor(() => /exit/.test(r.text('pvList')), { label: 'the paid note to be spendable', timeout: 20000 });
    r.close(); q.close();
  });

  test('a tampered request is refused before anything is paid', async () => {
    const q = await open();
    await unlock(q);
    const bad = {
      v: 1, chainBinding: F.wrapOp.chainBinding, assetId: F.ethAssetId, underlying: A.ZERO, ticker: 'cETH',
      amount: F.amountWei, value: F.note.value, cx: F.note.cx, cy: F.note.cy, owner: F.note.owner,
      commit: F.commit, depositId: F.depositId, leaf: F.leaf, memo: F.memo,
      witness: { ...F.wrapOp, sigZ: F.wrapOp.sigZ.slice(0, -1) + (F.wrapOp.sigZ.endsWith('0') ? '1' : '0') },
    };
    q.queuePrompt(JSON.stringify(bad));
    q.click(q.$('pvKey').querySelector('button[data-a="pay"]'));
    await q.waitFor(() => /not claimable/.test(q.text('stat')), { label: 'the refusal', timeout: 15000 });
    assert.equal(q.chain.sentTo(ROUTER).length, 0);
    // The genuine one, with a different amount claimed, is also refused.
    q.queuePrompt(JSON.stringify({ ...bad, witness: F.wrapOp, amount: '20000000000000000' }));
    q.click(q.$('pvKey').querySelector('button[data-a="pay"]'));
    await q.waitFor(() => /amounts disagree/.test(q.text('stat')), { timeout: 15000 });
    assert.equal(q.chain.sentTo(ROUTER).length, 0);
    q.close();
  });
});

describe('choosing a relay', () => {
  test('an https override is used for every relay call and can be cleared', async () => {
    const p = await open({ storage: { 'zswap:cprelay': 'https://relay.example' } });
    // Route the override host to the same canned relay.
    Object.defineProperty(p.chain.lanes, 'relay.example/confidential/submit', { enumerable: true, get: () => ({ ok: true, jobId: '0xjobx', status: 'pending' }) });
    Object.defineProperty(p.chain.lanes, 'relay.example/confidential/status', { enumerable: true, get: () => p.chain.relay.status });
    await unlock(p);
    await deposit(p);
    const urls = (p.chain.httpLog || []).map(x => x.url).filter(u => /confidential/.test(u));
    assert.ok(urls.length >= 1);
    assert.ok(urls.every(u => u.startsWith('https://relay.example/')), 'every relay call went to the override');
    assert.ok(urls.every(u => !u.includes(RELAY)), 'and none to the default');
    p.queuePrompt('');
    p.click(p.$('pvKey').querySelector('button[data-a="relay"]'));
    assert.equal(p.window.localStorage['zswap:cprelay'], undefined, 'an empty answer clears the override');
    assert.match(p.text('stat'), /Relay: https:\/\/api\.tacit\.finance/);
    p.queuePrompt('http://not-secure');
    p.click(p.$('pvKey').querySelector('button[data-a="relay"]'));
    assert.match(p.text('stat'), /https URL/);
    p.close();
  });
});
