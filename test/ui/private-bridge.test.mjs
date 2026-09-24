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
import { AbiCoder, keccak256, getBytes, concat, toUtf8Bytes, sha256, computeAddress } from 'ethers';
import { A, MockChain, loadPage, closeAllPages, selectorOf, CP_BLOCK } from './harness.mjs';

after(closeAllPages);

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..');
const F = JSON.parse(fs.readFileSync(path.join(ROOT, 'test', 'fixtures', 'confidential.json'), 'utf8'));
const coder = AbiCoder.defaultAbiCoder();

const POOL = F.pool, ROUTER = F.router, IMPL = F.executorImpl;
const BASE_BRIDGE = '0x3154Cf16ccdb4C6d922629664174b904d80F2C35';
const RH_INBOX = '0x1A07cc4BD17E0118BdB54D70990D2158AbAD7a2D';
const RELAY = 'api.tacit.finance';
const SEL = {
  IMPL: '93228617', ASSETS: '9fda5b66', NEXT: '0be4f422', DEPOSIT: '7da9874f', WRAP: '8be3ad21',
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
// The mock chain has to run past the pool's deploy block, which the page pins
// as CP_BLOCK, or the page has no window to scan.
const B0 = CP_BLOCK + 0x100;
const HEAD = '0x' + (B0 + 0x8).toString(16);
// A relayed exit pays a flat, gas-priced fee, never below the relay's 0.0001
// ETH floor, and the page refuses one above 3% of the note - an outlier fee is
// a fingerprint. At the fixture's 1 gwei that fee is 6.7% of 0.01 ETH, so the
// chain here runs at 0.1 gwei: the fee ladder (two significant digits, rounded
// up) then quotes 0.00012 ETH, 1.2%.
const GAS = 10n ** 8n;
const ladder = v => { const d = v.toString().length; if (d <= 2) return v; const s = 10n ** BigInt(d - 2); return (v + s - 1n) / s * s; };
const feeFor = g => (f => f < 10000n ? 10000n : f)(ladder((g * GAS + 40000000000000n) * 135n / 100n / 10n ** 10n));
const FEE = feeFor(450000n);
const NET = BigInt(F.note.value) - FEE;
// An exit to an L2 also pays for the relay's activateExit: half the page's
// activation gas limit on top of the settle.
const FEE_BASE = feeFor(450000n + 600000n), NET_BASE = BigInt(F.note.value) - FEE_BASE;
const FEE_RH = feeFor(450000n + 500000n), NET_RH = BigInt(F.note.value) - FEE_RH;
const jsonOf = r => JSON.parse(JSON.stringify(r, (_, v) => typeof v === 'bigint' ? String(v) : typeof v === 'string' ? v.toLowerCase() : v));

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
  address: POOL, blockNumber: '0x' + (B0 + 0x5).toString(16), logIndex: '0x0',
  topics: [T.LEAVES, '0x' + u256(first)],
  data: coder.encode(['bytes32[]', 'bytes[]'], [leaves, memos]),
});
const spentLog = nus => ({
  address: POOL, blockNumber: '0x' + (B0 + 0x6).toString(16), logIndex: '0x0',
  topics: [T.SPENT], data: coder.encode(['bytes32[]'], [nus]),
});
const wrapLog = (id, amount) => ({
  address: POOL, blockNumber: '0x' + (B0 + 0x4).toString(16), logIndex: '0x0',
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
  chain.answer(POOL, SEL.WRAP, '0x');
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
  const p = await loadPage({ chain, storage: opts.storage, chime: opts.chime, hash: opts.hash, patch: opts.patch });
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
  assert.equal(msg, F.identityMessage, 'Tacit\'s own identity message, so tacit.finance derives the same key');
}

async function deposit(p) {
  p.type('pvAmt', '0.01');
  p.click('pvGo');
  await p.waitFor(() => p.chain.sentTo(POOL).length === 1, { label: 'the deposit to be sent' });
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

describe('the deposit commitment', () => {
  // Tacit's own KAT (contracts/sp1/confidential/fixtures/deposit_id_vectors.json).
  // A wrap and a payment request share this primitive, so a drift here would
  // silently point requests at commitments nobody can pay.
  test('the page derives Tacit\'s depositCommit and depositId, case for case', async () => {
    const p = await open();
    for (const v of F.depositIdKat) {
      const commit = p.window.eval(`cpDepCommit("${v.cx}","${v.cy}","${v.owner}")`);
      assert.equal(commit.toLowerCase(), v.depositCommit.toLowerCase(), 'depositCommit for ' + v.value);
      const id = p.window.eval(`cpDepId(${v.value}n,"${v.depositCommit}","${v.assetId}")`);
      assert.equal(id.toLowerCase(), v.depositId.toLowerCase(), 'depositId for ' + v.value);
    }
    assert.ok(F.depositIdKat.length >= 5);
    p.close();
  });
});

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
  test('one signature derives the key, and the deposit is the reference pool.wrap call', async () => {
    const p = await open();
    assert.equal(p.text('pvGo'), 'Unlock key');
    await unlock(p);
    assert.equal(p.text('pvGo'), 'Deposit');
    await deposit(p);

    const tx = p.chain.sentTo(POOL)[0];
    assert.equal(tx.from, A.ACCOUNT);
    assert.equal(BigInt(tx.value), BigInt(F.amountWei), 'msg.value is the amount deposited');
    assert.equal(tx.data, F.wrapCalldata, 'pool.wrap(ETH, amount, commit) with the reference commitment');
    assert.equal(p.chain.sentTo(ROUTER).length, 0, 'the router is not in the deposit path');

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
    assert.match(p.text('pvList'), /0\.01 tETH/);
    p.close();
  });

  test('the deposit chimes when it lands, and again when the relay settles it', async () => {
    const GOT = [392, 493.88, 587.33, 783.99];
    const p = await open({ chime: true });
    await unlock(p);
    await deposit(p);
    await p.waitFor(() => /relay is settling/.test(p.text('stat')), { label: 'the deposit to confirm' });
    const heard = () => p.window.__chime.voices.filter(v => v.join() === GOT.join()).length;
    assert.equal(heard(), 1, 'the confirmed deposit should sing once');
    settleDeposit(p);
    poke(p);
    await p.waitFor(() => heard() === 2, { label: 'the relay settle to sing', ...SLOW });
    poke(p);
    await p.settle();
    assert.equal(heard(), 2, 'a settled job sang again on the next poll');
    p.close();
  });

  test('refuses more than eight decimals - the pool cannot hold them', async () => {
    const p = await open();
    await unlock(p);
    p.type('pvAmt', '0.000000001');
    p.click('pvGo');
    await p.waitFor(() => /eight decimals/.test(p.text('stat')), { label: 'the precision refusal' });
    assert.equal(p.chain.sentTo(POOL).length, 0);
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
  test('deposit asks for no destination, and exit from a note opens Withdraw for it', async () => {
    const p = await open();
    assert.ok(p.$('pvChain').parentElement.classList.contains('hide'), 'no destination chain under Deposit');
    assert.ok(p.$('pvTo').parentElement.classList.contains('hide'), 'no recipient under Deposit');
    await unlock(p);
    await deposit(p);
    settleDeposit(p);
    poke(p);
    await p.waitFor(() => /exit/.test(p.text('pvList')), { label: 'the note to show as settled', ...SLOW });
    const posts = p.window.__relayPosts.length;
    p.click(p.$('pvList').querySelector('button[data-a="exit"]'));
    await p.settle();
    assert.equal(p.$('pvAct').value, 'out', 'the panel switches to Withdraw');
    assert.ok(!p.$('pvChain').parentElement.classList.contains('hide'), 'the destination is shown to confirm');
    assert.ok(!p.$('pvTo').parentElement.classList.contains('hide'));
    assert.ok(p.$('pvAmt').value, 'the note amount is filled in');
    assert.equal(p.text('pvGo'), 'Withdraw');
    assert.equal(p.window.__relayPosts.length, posts, 'nothing is sent until Withdraw is pressed');
    p.close();
  });

  test('the unwrap witness pays the recipe escrow, and activate fires the pinned recipe', async () => {
    const p = await open();
    await unlock(p);
    await deposit(p);
    settleDeposit(p);
    poke(p);
    await p.waitFor(() => /exit/.test(p.text('pvList')), { label: 'the note to show as settled', ...SLOW });

    // What the page must arrive at: a settle-and-activate fee off the gas price, the rest bridged.
    const net = NET_BASE * 10n ** 10n;
    const recipe = baseRecipe(net);
    p.chain.escrow = escrowOf(recipe);
    p.select('pvChain', '8453');
    p.select('pvAct', 'out');
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
    assert.equal(op.fee, String(FEE_BASE), 'the flat, laddered relay fee, covering the settle and the activation');
    assert.equal(FEE_BASE, 20000n);
    assert.deepEqual(jsonOf(post.exit), jsonOf(recipe), 'the recipe rides along for the relay to activate');
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
    await p.waitFor(() => p.chain.sentTo(ROUTER).length === 1, { label: 'activateExit to be sent' });
    const tx = p.chain.sentTo(ROUTER)[0];
    assert.equal(tx.data, activateOf(recipe), 'activateExit(recipe), encoded by ethers');
    assert.equal(BigInt(tx.gas), 1200000n, 'the activate gas limit');
    assert.equal(BigInt(tx.value), 0n);
    // The pre-flight ran at the SAME gas cap as the real send.
    const dry = p.chain.calls.filter(c => c.selector === SEL.ACTIVATE);
    assert.ok(dry.length >= 1);
    await p.waitFor(() => /on Base/.test(p.text('pvList')), { label: 'the row to report the bridge' });
    const on = [...p.$('pvList').querySelectorAll('a')].find(a => /on Base/.test(a.textContent));
    assert.match(on ? on.getAttribute('href') : '', /\/address\/0x[0-9a-fA-F]{40}$/, 'the explorer link opens the address page');
    p.close();
  });

  test('a recipient left in the hidden Withdraw form is shown, not used, when exit is pressed from Send', async () => {
    const p = await open();
    await unlock(p);
    await deposit(p);
    settleDeposit(p);
    poke(p);
    await p.waitFor(() => /exit/.test(p.text('pvList')), { label: 'the note to show as settled', ...SLOW });
    p.$('pvAct').value = 'out'; p.$('pvAct').dispatchEvent(new p.window.Event('change', { bubbles: true }));
    p.$('pvTo').value = A.OTHER;
    p.$('pvAct').value = 'send'; p.$('pvAct').dispatchEvent(new p.window.Event('change', { bubbles: true }));
    assert.ok(p.$('pvTo').parentElement.classList.contains('hide'), 'the recipient box is hidden in Send');
    const posts = p.window.__relayPosts.length;
    p.click(p.$('pvList').querySelector('button[data-a="exit"]'));
    await p.settle();
    assert.equal(p.window.__relayPosts.length, posts, 'nothing leaves on a recipient the user cannot see');
    assert.equal(p.$('pvAct').value, 'out');
    assert.ok(!p.$('pvTo').parentElement.classList.contains('hide'), 'the recipient is on screen to confirm');
    assert.equal(p.$('pvTo').value, A.OTHER);
    p.close();
  });

  test('a stale exit reclaims to the L1 recipient instead', async () => {
    const p = await open();
    await unlock(p);
    await deposit(p);
    settleDeposit(p);
    poke(p);
    await p.waitFor(() => /exit/.test(p.text('pvList')), SLOW);
    const net = NET_BASE * 10n ** 10n;
    const recipe = baseRecipe(net);
    p.chain.escrow = escrowOf(recipe);
    p.select('pvChain', '8453');
    p.select('pvAct', 'out');
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
    await p.waitFor(() => p.chain.sentTo(ROUTER).length === 1);
    const tx = p.chain.sentTo(ROUTER)[0];
    assert.equal(tx.data, reclaimOf(recipe), 'reclaimExit(recipe, [])');
    assert.equal(BigInt(tx.gas), 400000n);
    p.close();
  });

  test('an exit already activated from another browser is marked bridged, not activated again', async () => {
    const p = await open();
    await unlock(p);
    await deposit(p);
    settleDeposit(p);
    poke(p);
    await p.waitFor(() => /exit/.test(p.text('pvList')), SLOW);
    p.chain.escrow = escrowOf(baseRecipe(NET_BASE * 10n ** 10n));
    p.select('pvChain', '8453');
    p.select('pvAct', 'out');
    p.click(p.$('pvList').querySelector('button[data-a="exit"]'));
    await p.waitFor(() => p.window.__relayPosts.length === 2, SLOW);
    p.chain.relay.status = { status: 'settled' };
    p.chain.logs.push(spentLog([F.nullifier]));
    advance(p);
    p.chain.code.set(p.chain.escrow, '0x6000');
    poke(p);
    await p.waitFor(() => p.$('pvList').querySelector('button[data-a="activate"]'), { label: 'the activate button', timeout: 20000 });
    p.click(p.$('pvList').querySelector('button[data-a="activate"]'));
    await p.waitFor(() => /Already activated/.test(p.text('stat')), { label: 'the activation to be recognised' });
    assert.equal(p.chain.sentTo(ROUTER).length, 0, 'no activation is sent');
    await p.waitFor(() => /on Base/.test(p.text('pvList')), { label: 'the row to report the bridge' });
    p.close();
  });

  test('a retry while the first attempt can still land keeps its escrow and fee', async () => {
    const p = await open();
    await unlock(p);
    await deposit(p);
    settleDeposit(p);
    poke(p);
    await p.waitFor(() => /exit/.test(p.text('pvList')), SLOW);
    p.chain.escrow = escrowOf(baseRecipe(NET_BASE * 10n ** 10n));
    const inner = p.window.fetch;
    let dropped = false;
    p.window.fetch = async (url, init) => {
      if (!dropped && String(url).includes('/confidential/submit')) {
        dropped = true;
        p.window.__relayPosts.push(JSON.parse(init.body));
        throw new Error('connection reset');
      }
      return inner(url, init);
    };
    p.select('pvChain', '8453');
    p.select('pvAct', 'out');
    p.click(p.$('pvList').querySelector('button[data-a="exit"]'));
    await p.waitFor(() => /relay failed/.test(p.text('pvList')), { label: 'the retry to be offered', ...SLOW });
    p.chain.gasPrice = GAS * 2n;
    p.select('pvChain', '8453');
    p.select('pvAct', 'out');
    p.click(p.$('pvList').querySelector('button[data-a="exit"]'));
    await p.waitFor(() => p.window.__relayPosts.length === 3, { label: 'the retry to reach the relay', ...SLOW });
    const [, first, again] = p.window.__relayPosts;
    assert.equal(again.op.recipient, first.op.recipient, 'the same escrow');
    assert.equal(again.op.fee, first.op.fee, 'the same fee, though gas moved');
    assert.equal(again.op.fee, String(FEE_BASE));
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
    p.select('pvChain', '8453');
    p.select('pvAct', 'out');
    p.click(p.$('pvList').querySelector('button[data-a="exit"]'));
    await p.waitFor(() => /Escrow address mismatch/.test(p.text('stat')), { label: 'the mismatch refusal' });
    assert.equal(p.window.__relayPosts.length, 1, 'nothing was proven');
    p.close();
  });

  async function relayedBaseExit() {
    const p = await open();
    await unlock(p);
    await deposit(p);
    settleDeposit(p);
    poke(p);
    await p.waitFor(() => /exit/.test(p.text('pvList')), SLOW);
    const net = NET_BASE * 10n ** 10n;
    p.chain.escrow = escrowOf(baseRecipe(net));
    // A relay that activates reports it pending from the moment the exit is queued.
    p.chain.relay.status = { status: 'pending', activation: 'pending', activateTx: null };
    p.select('pvChain', '8453');
    p.select('pvAct', 'out');
    p.click(p.$('pvList').querySelector('button[data-a="exit"]'));
    await p.waitFor(() => p.window.__relayPosts.length === 2, SLOW);
    return { p, net };
  }
  const settledOnChain = (p, net) => {
    p.chain.logs.push(spentLog([F.nullifier]));
    advance(p);
    p.chain.setNative(p.chain.escrow, net);
    poke(p);
  };

  test('the relay activates it: the row waits, then reports the bridge, and this wallet sends nothing', async () => {
    const { p, net } = await relayedBaseExit();
    assert.match(p.text('stat'), /this wallet sends nothing/);
    p.chain.relay.status = { status: 'settled', txHash: '0x' + 'bb'.repeat(32), activation: 'pending', activateTx: null };
    settledOnChain(p, net);
    await p.waitFor(() => /bridging…/.test(p.text('pvList')), { label: 'the row to wait on the relay', timeout: 20000 });
    assert.equal(p.$('pvList').querySelector('button[data-a="activate"]'), null, 'no activate button while the relay activates');
    p.chain.relay.status = { ...p.chain.relay.status, activation: 'done', activateTx: '0x' + 'cc'.repeat(32) };
    advance(p);
    poke(p);
    await p.waitFor(() => /on Base/.test(p.text('pvList')), { label: 'the row to report the bridge', timeout: 20000 });
    assert.equal(p.chain.sentTo(ROUTER).length, 0, 'the wallet sent no activation');
    p.close();
  });

  test('when the relay cannot activate it, the row offers activate', async () => {
    const { p, net } = await relayedBaseExit();
    p.chain.relay.status = { status: 'settled', txHash: '0x' + 'bb'.repeat(32), activation: 'failed', activateError: 'the fee is below the settle plus activation cost' };
    settledOnChain(p, net);
    await p.waitFor(() => p.$('pvList').querySelector('button[data-a="activate"]'), { label: 'the activate button', timeout: 20000 });
    assert.doesNotMatch(p.text('pvList'), /bridging…/);
    p.close();
  });

  async function expiredExit() {
    const { p, net } = await relayedBaseExit();
    p.chain.relay.status = { status: 'failed', error: 'prove failed' };
    // Past the proof's own deadline, so the first attempt can no longer land.
    const real = p.window.Date.now;
    p.window.Date.now = () => real() + 2 * 3600 * 1000;
    poke(p);
    await p.waitFor(() => p.$('pvList').querySelector('button[data-a="xdrop"]'), { label: 'the retry and cancel buttons', timeout: 20000 });
    return { p, net };
  }

  test('a retry after the exit expired rebuilds the same exit, whatever the form now says', async () => {
    const { p, net } = await expiredExit();
    // The form has moved on: another chain, another recipient.
    p.select('pvChain', '1');
    p.type('pvTo', A.OTHER);
    const recipe = baseRecipe(net, BigInt((Math.floor(p.window.Date.now() / 86400000) + 3) * 86400));
    p.chain.escrow = escrowOf(recipe);
    p.queueConfirm(true);
    p.select('pvAct', 'out');
    p.click(p.$('pvList').querySelector('button[data-a="exit"]'));
    await p.waitFor(() => p.window.__relayPosts.length === 3, { label: 'the rebuilt exit', ...SLOW });
    const post = p.window.__relayPosts[2];
    assert.equal(post.op.recipient, p.chain.escrow, 'the escrow of the Base recipe it had, not a withdrawal to the form\'s address');
    assert.deepEqual(jsonOf(post.exit), jsonOf(recipe));
    assert.equal(post.op.value, F.note.value, 'the whole note, as first asked');
    p.close();
  });

  test('an expired exit can be cancelled, which makes the note spendable again', async () => {
    const { p } = await expiredExit();
    p.queueConfirm(true);
    p.click(p.$('pvList').querySelector('button[data-a="xdrop"]'));
    await p.waitFor(() => p.$('pvList').querySelector('button[data-a="split"]'), { label: 'the note, spendable again', timeout: 20000 });
    assert.doesNotMatch(p.text('pvList'), /relay failed/);
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
    const pv = '0x' + '12'.repeat(200) + F.nullifier.slice(2), pr = '0x' + 'ab'.repeat(260);
    p.chain.relay.status = { status: 'proven', publicValues: pv, proof: pr };
    p.select('pvChain', '8453');
    p.select('pvAct', 'out');
    p.click(p.$('pvList').querySelector('button[data-a="exit"]'));
    await p.waitFor(() => p.window.__relayPosts.length === 2);
    const post = p.window.__relayPosts[1];
    assert.equal(post.mode, 'prove');
    assert.equal(post.op.fee, '0');
    assert.equal(post.op.recipient, p.chain.escrow);
    assert.ok(!('exit' in post), 'a self exit hands the relay no recipe to activate');
    await p.waitFor(() => p.$('pvList').querySelector('button[data-a="send"]'), { label: 'the send button', timeout: 20000 });
    p.click(p.$('pvList').querySelector('button[data-a="send"]'));
    await p.waitFor(() => p.chain.sentTo(ROUTER).length === 1, { label: 'exitAndExecute to be sent', timeout: 20000 });
    const tx = p.chain.sentTo(ROUTER)[0];
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
    const net = NET_RH * 10n ** 10n;
    const g = { gl: BigInt(F.robinhood.gasLimit), sc: BigInt(F.robinhood.sub), mf: 8n * BigInt(F.robinhood.l2Gas) };
    const recipe = rhRecipe(net, g);
    p.chain.escrow = escrowOf(recipe);
    p.select('pvChain', '4663');
    p.select('pvAct', 'out');
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
    await p.waitFor(() => p.chain.sentTo(ROUTER).length === 1);
    const tx = p.chain.sentTo(ROUTER)[0];
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
    await q.waitFor(() => /0\.01 tETH/.test(q.text('pvList')), { label: 'the deposit to be recovered' });
    assert.match(q.text('stat'), /Recovered 1 deposit/);
    q.close();
  });

  test('recovery from a busy pool derives each note index once, and the page keeps running while it scans', async () => {
    const storage = { ['zswap:cpk:' + A.ACCOUNT.toLowerCase()]: F.seed };
    // A second deposit of ours, at index 5 and another amount. Its id comes from
    // the page's single-note derivation, which the reference vectors pin; the
    // scan below has to land on the same id by its own route.
    const p = await open({ storage });
    const mine = p.window.eval('cpNoteOf({i:5,v:"2500000"}).dep');
    p.close();
    const q = await open({ storage });
    // Every call to derive a note secret encodes this domain tag exactly once.
    let derived = 0;
    const Enc = q.window.TextEncoder;
    q.window.TextEncoder = class extends Enc {
      encode(s) { if (s === 'tacit-evm-cnote-v1') derived++; return super.encode(s); }
    };
    const foreign = k => keccak256(toUtf8Bytes('someone else ' + k));
    for (let k = 0; k < 30; k++) q.chain.logs.push(wrapLog(foreign(k), (1000001n + BigInt(k)) * 10n ** 10n));
    for (let k = 30; k < 36; k++) q.chain.logs.push(wrapLog(foreign(k), F.amountWei));
    q.chain.logs.push(wrapLog(foreign(36), 10n ** 10n + 1n));
    q.chain.logs.push(wrapLog(F.depositId, F.amountWei));
    q.chain.logs.push(wrapLog(mine, 2500000n * 10n ** 10n));
    advance(q);
    poke(q);
    await q.settle();
    assert.match(q.text('pvList'), /No deposits yet/);
    let ticks = 0, gap = 0, at = performance.now();
    const beat = q.window.setInterval(() => { const t = performance.now(); gap = Math.max(gap, t - at); at = t; ticks++; }, 0);
    derived = 0;
    let t0 = performance.now();
    q.click(q.$('pvKey').querySelector('button[data-a="recover"]'));
    await q.waitFor(() => /Recovered 2 deposits/.test(q.text('stat')), { label: 'both deposits to be recovered', timeout: 30000 });
    const first = performance.now() - t0;
    q.window.clearInterval(beat);
    // The window runs 64 indices past the highest one known: 0..63 for the scan, then out to 69 once index 5 is found.
    assert.ok(derived <= 64 + 6 + 2, `indices out to 64 past the highest known one, plus one per recovered note, not 64 per distinct amount: ${derived}`);
    // `ticks` is the property: a scan that never yielded would beat once or
    // twice, not twenty times. The stall bound is a second opinion on the same
    // thing, so it is measured against the scan it interrupted rather than
    // against the clock - an absolute 400 ms failed here whenever the machine
    // was busy with something else, which says nothing about whether the page
    // stayed responsive.
    assert.ok(ticks > 20 && gap < Math.max(400, first / 4),
      `the scan yields to the event loop: ${ticks} timer ticks, longest stall ${Math.round(gap)} ms of ${Math.round(first)} ms`);
    assert.match(q.text('pvList'), /0\.01 tETH/);
    assert.match(q.text('pvList'), /0\.025 tETH/);
    const stored = JSON.parse(q.window.localStorage[Object.keys(q.window.localStorage).find(k => k.startsWith('zswap:cpn:'))]);
    assert.deepEqual(stored.map(n => [n.i, n.v]), [[0, '1000000'], [5, '2500000']]);
    assert.deepEqual(stored[0].op, F.wrapOp, 'the recovered deposit carries the reference witness');
    assert.ok(stored.every(n => /^0x[0-9a-f]+$/i.test(n.memo)), 'and a memo for the relay');
    derived = 0;
    t0 = performance.now();
    q.click(q.$('pvKey').querySelector('button[data-a="recover"]'));
    await q.waitFor(() => /Nothing new on chain/.test(q.text('stat')), { label: 'the second scan', timeout: 30000 });
    const second = performance.now() - t0;
    assert.equal(derived, 0, 'a second scan reuses the index table');
    assert.ok(second < first / 4, `and skips the wraps it already ruled out: ${Math.round(second)} ms against ${Math.round(first)} ms`);
    assert.equal(JSON.parse(q.window.localStorage[Object.keys(q.window.localStorage).find(k => k.startsWith('zswap:cpn:'))]).length, 2);
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
    await q.waitFor(() => /0\.01 tETH/.test(q.text('pvList')), { label: 'the imported note' });
    assert.match(q.text('stat'), /Imported 1 note/);
    q.close();
  });

  // An imported record is refused at the door rather than imported and then
  // rendered safely. The key one is `dep`: it is what cpKeyOf returns for a paid
  // note, and it lands in a data-k="…" attribute, so a record carrying a quote
  // there could close the attribute and run script on the origin that holds the
  // spending key. Every field cpKeyOf can return is now shape-checked.
  const hostile = [
    ['a paid note whose deposit id is markup', { i: 0, v: '1', p: 1, dep: '" autofocus onfocus="alert(1)' }],
    ['a locked note whose blinding is markup', { i: 0, v: '1', z: 1, b: '"><img src=x onerror=alert(1)>' }],
    ['a paid note with no deposit id at all', { i: 123456, v: '1', p: 1, js: 'settled', tx: '"><img src=x onerror=alert(1)>' }],
  ];
  for (const [what, rec] of hostile) {
    test(`refuses to import ${what}`, async () => {
      const p = await open();
      await unlock(p);
      p.queuePrompt(JSON.stringify([rec]));
      p.click(p.$('pvKey').querySelector('button[data-a="import"]'));
      await p.waitFor(() => /Nothing new in that list\./.test(p.text('stat')), { label: 'the import result' });
      assert.equal(p.$('pvList').querySelector('img'), null, 'no markup is rendered');
      assert.equal(p.$('pvList').querySelector('[onerror]'), null, 'no event handler is rendered');
      assert.equal(p.$('pvList').querySelector('[autofocus]'), null, 'no attribute breaks out of data-k');
      p.close();
    });
  }

  test('still imports a well-formed paid note', async () => {
    const p = await open();
    await unlock(p);
    p.queuePrompt(JSON.stringify([{ i: -1, v: '1', p: 1, dep: '0x' + 'ab'.repeat(32) }]));
    p.click(p.$('pvKey').querySelector('button[data-a="import"]'));
    await p.waitFor(() => /Imported 1 note/.test(p.text('stat')), { label: 'the import result' });
    p.close();
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

/**
 * Safari private browsing and a blocked origin both leave the page with a plain
 * object in place of `localStorage`, so nothing written survives the tab. An L2
 * exit cannot be rebuilt from the key — its escrow recipe pins gas quoted at
 * build time — so it is refused. An Ethereum withdrawal pins nothing: the relay
 * settles it to the address, and a note that never settles stays spendable.
 */
/**
 * The relay is the one thing here the page cannot do itself: a deposit reaches
 * the pool without it, but nothing moves until something proves. `zEndpoints`
 * hands out a LIST of relays, so a submit walks it — and the job records which
 * one took it, because only that one can be polled for the proof.
 */
describe('a relay that does not answer', () => {
  const roster = (...rs) => ({
    storage: { 'zswap:ep2': JSON.stringify({ t: Date.now(), v: [[], [], [], rs, [], [], [], [], []] }) },
  });

  test('the roster keeps every relay it names, the built-in one last', async () => {
    const p = await open(roster('https://a.relay/', 'https://b.relay'));
    assert.deepEqual([...p.window.eval('CP_RELAYS')],
      ['https://a.relay', 'https://b.relay', 'https://api.tacit.finance'],
      'trailing slashes trimmed, and the built-in relay stays as the last resort');
    assert.equal(p.window.eval('cpRelayBase()'), 'https://a.relay');
    p.close();
  });

  test('a submit falls over to the next one, and the job remembers which took it', async () => {
    const p = await open(roster('https://down.relay'));
    assert.equal(p.window.eval('cpRelayBase()'), 'https://down.relay');
    await unlock(p);
    p.type('pvAmt', '0.01');
    p.click('pvGo');
    await p.waitFor(() => p.chain.sentTo(POOL).length === 1, { label: 'the deposit to be sent' });
    await p.waitFor(() => /settling it into the pool/.test(p.text('stat')), { label: 'the deposit to be taken', ...SLOW });
    assert.equal(p.window.__relayPosts.length, 2, 'the same submit, offered to each relay in turn');
    const tried = (p.chain.httpLog || []).filter(h => /\/confidential\/submit/.test(h.url)).map(h => h.url);
    assert.deepEqual(tried, ['https://down.relay/confidential/submit', 'https://api.tacit.finance/confidential/submit']);
    assert.equal(p.window.eval('cpNotes[0].rb'), 'https://api.tacit.finance',
      'the job is polled at the relay that answered, not the one that did not');
    assert.equal(p.window.eval('cpNotes[0].job'), '0xjob1');
    p.close();
  });

  test('a relay the viewer pinned is used alone, with no fallback', async () => {
    const p = await open({ storage: {
      'zswap:ep2': JSON.stringify({ t: Date.now(), v: [[], [], [], [], [], [], [], [], []] }),
      'zswap:cprelay': 'https://down.relay',
    } });
    assert.equal(p.window.eval('cpRelayBase()'), 'https://down.relay');
    assert.ok([...p.window.eval('CP_RELAYS')].includes('https://api.tacit.finance'), 'which would have answered');
    await unlock(p);
    await deposit(p);
    await p.waitFor(() => /did not take the settle/.test(p.text('stat')), { label: 'the pinned relay to be the only one tried', ...SLOW });
    assert.equal(p.window.eval('cpNotes[0].job'), undefined, 'no job: the viewer\'s choice was not second-guessed');
    assert.equal(p.chain.sentTo(POOL).length, 1, 'the deposit itself still reached the pool');
    p.close();
  });
});

describe('a browser that keeps nothing', () => {
  const noStore = { patch: [['try{LS=localStorage||{}}catch{LS={}}', 'LS={};']] };

  test('an Ethereum withdrawal still goes through', async () => {
    const p = await open(noStore);
    await unlock(p);
    await deposit(p);
    settleDeposit(p);
    poke(p);
    await p.waitFor(() => /exit/.test(p.text('pvList')), SLOW);
    p.select('pvChain', '1');
    p.type('pvTo', A.OTHER);
    p.select('pvAct', 'out');
    p.click(p.$('pvList').querySelector('button[data-a="exit"]'));
    await p.waitFor(() => p.window.__relayPosts.length === 2, SLOW);
    const post = p.window.__relayPosts[1];
    assert.equal(post.type, 'unwrap');
    assert.equal(post.op.recipient, A.OTHER.toLowerCase(), 'paid straight to the address');
    assert.doesNotMatch(p.text('stat'), /storage|private browsing/);
    p.close();
  });

  test('an exit to an L2 is refused before anything is proven', async () => {
    const p = await open(noStore);
    await unlock(p);
    await deposit(p);
    settleDeposit(p);
    poke(p);
    await p.waitFor(() => /exit/.test(p.text('pvList')), SLOW);
    const posts = p.window.__relayPosts.length;
    p.select('pvChain', '8453');
    p.select('pvAct', 'out');
    p.click(p.$('pvList').querySelector('button[data-a="exit"]'));
    await p.waitFor(() => /storage|private browsing/.test(p.text('stat')), { label: 'the refusal', ...SLOW });
    assert.equal(p.window.__relayPosts.length, posts, 'an escrow whose terms were never written is one that cannot be taken back');
    assert.equal(p.chain.calls.filter(c => c.selector === SEL.IMPL).length, 0, 'the bridge pins were never read');
    p.close();
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
    p.select('pvAct', 'out');
    p.click(p.$('pvList').querySelector('button[data-a="exit"]'));
    await p.waitFor(() => p.window.__relayPosts.length === 2, SLOW);
    const post = p.window.__relayPosts[1];
    assert.equal(post.type, 'unwrap');
    assert.equal(post.mode, 'settle');
    assert.equal(post.op.recipient, A.OTHER.toLowerCase(), 'paid straight to the address');
    assert.ok(!('exit' in post), 'an Ethereum withdrawal has no recipe');
    assert.equal(post.op.fee, String(FEE));
    assert.equal(p.chain.calls.filter(c => c.selector === SEL.ESCROW).length, 0, 'no recipe was built');
    assert.equal(p.chain.calls.filter(c => c.selector === SEL.IMPL).length, 0, 'no bridge pins were read');
    p.chain.relay.status = { status: 'settled' };
    p.chain.logs.push(spentLog([F.nullifier]));
    advance(p);
    poke(p);
    await p.waitFor(() => /on Ethereum/.test(p.text('pvList')), { label: 'the withdrawal to show', timeout: 20000 });
    assert.equal(p.chain.sentTo(POOL).length, 1, 'nothing further to send');
    assert.equal(p.chain.sentTo(ROUTER).length, 0);
    p.close();
  });

  test('a fee over the privacy guard offers to settle from this wallet instead', async () => {
    const p = await open();
    await unlock(p);
    await deposit(p);
    settleDeposit(p);
    poke(p);
    await p.waitFor(() => /exit/.test(p.text('pvList')), SLOW);
    p.chain.gasPrice = 10n ** 9n;
    p.select('pvChain', '1');
    p.queueConfirm(false);
    p.select('pvAct', 'out');
    p.click(p.$('pvList').querySelector('button[data-a="exit"]'));
    await p.waitFor(() => /6\.7% of this note/.test(p.text('stat')), { label: 'the refusal', ...SLOW });
    assert.equal(p.window.__relayPosts.length, 1, 'declined: nothing was proven');
    p.queueConfirm(true);
    p.select('pvAct', 'out');
    p.click(p.$('pvList').querySelector('button[data-a="exit"]'));
    await p.waitFor(() => p.window.__relayPosts.length === 2, SLOW);
    const post = p.window.__relayPosts[1];
    assert.equal(post.mode, 'prove', 'accepted: the relay only proves');
    assert.equal(post.op.fee, '0', 'and takes nothing');
    p.close();
  });

  test('at a very low gas price the relay fee is its 0.0001 ETH floor', async () => {
    const p = await open();
    p.chain.gasPrice = 10n ** 7n;
    await unlock(p);
    await deposit(p);
    settleDeposit(p);
    poke(p);
    await p.waitFor(() => /exit/.test(p.text('pvList')), SLOW);
    p.select('pvChain', '1');
    p.select('pvAct', 'out');
    p.click(p.$('pvList').querySelector('button[data-a="exit"]'));
    await p.waitFor(() => p.window.__relayPosts.length === 2, SLOW);
    assert.equal(p.window.__relayPosts[1].op.fee, '10000', 'the floor, not the 0.000061 ETH the gas alone prices');
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
    const pv = '0x' + '12'.repeat(200) + F.nullifier.slice(2), pr = '0x' + 'ab'.repeat(260);
    p.chain.relay.status = { status: 'proven', publicValues: pv, proof: pr };
    p.select('pvAct', 'out');
    p.click(p.$('pvList').querySelector('button[data-a="exit"]'));
    await p.waitFor(() => p.window.__relayPosts.length === 2, SLOW);
    const post = p.window.__relayPosts[1];
    assert.equal(post.mode, 'prove');
    assert.equal(post.op.fee, '0');
    assert.equal(post.op.recipient, A.ACCOUNT.toLowerCase(), 'defaults to this wallet');
    await p.waitFor(() => p.$('pvList').querySelector('button[data-a="send"]'), { label: 'the send button', timeout: 20000 });
    p.click(p.$('pvList').querySelector('button[data-a="send"]'));
    await p.waitFor(() => p.chain.sentTo(POOL).length === 2, { label: 'settle to be sent', timeout: 20000 });
    const tx = p.chain.sentTo(POOL)[1];
    assert.equal(tx.data, '0x717fd7f2' + coder.encode(['bytes', 'bytes', 'bytes[]'], [pv, pr, []]).slice(2), 'pool.settle(pv, proof, [])');
    assert.equal(BigInt(tx.gas), 700000n);
    assert.equal(BigInt(tx.value), 0n);
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
    await r.waitFor(() => r.$('wkList').querySelector('textarea'), { label: 'the request link box', timeout: 15000 });
    assert.match(r.text('wkList'), /payment request link/);
    const link = r.$('wkList').querySelector('textarea').value;
    assert.match(link, /#tacit-invoice=[A-Za-z0-9_-]+$/, 'a link with the request in its fragment');
    const invoice = JSON.parse(Buffer.from(link.split('#tacit-invoice=')[1], 'base64url').toString('utf8'));
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
    assert.match(r.text('pvList'), /payment request/);
    assert.match(r.text('pvList'), /unpaid/, 'an unpaid request says so, with copy link and cancel beside it');


    // The payer pays it from another browser.
    const q = await open();
    await unlock(q);
    q.queuePrompt(link);
    q.queueConfirm(true);
    q.click(q.$('pvKey').querySelector('button[data-a="pay"]'));
    await q.waitFor(() => q.chain.sentTo(POOL).length === 1, { label: 'the payment to be sent', timeout: 15000 });
    assert.match(q.asked.confirm.at(-1), /^Pay 0\.01 ETH into this private request \(deposit 0x/, 'the payer confirms the amount and the deposit');
    const tx = q.chain.sentTo(POOL)[0];
    assert.equal(BigInt(tx.value), BigInt(F.amountWei));
    assert.equal(tx.data, F.wrapCalldata, 'pool.wrap to the request\'s commitment');
    await q.waitFor(() => q.window.__relayPosts.length === 1, { label: 'the settle to reach the relay', timeout: 15000 });
    const post = q.window.__relayPosts[0];
    assert.equal(post.type, 'wrap');
    assert.deepEqual(post.op, invoice.witness, 'the payer submits the recipient\'s witness untouched');
    assert.deepEqual(post.memos, [invoice.memo]);
    assert.match(q.text('pvList'), /0\.01 tETH paid/);
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
    assert.equal(q.chain.sentTo(POOL).length, 0);
    // The genuine one, with a different amount claimed, is also refused.
    q.queuePrompt(JSON.stringify({ ...bad, witness: F.wrapOp, amount: '20000000000000000' }));
    q.click(q.$('pvKey').querySelector('button[data-a="pay"]'));
    await q.waitFor(() => /amounts disagree/.test(q.text('stat')), { timeout: 15000 });
    assert.equal(q.chain.sentTo(POOL).length, 0);
    q.close();
  });
});

describe('one key, two chains', () => {
  test('the key is the one Tacit derives, and it reads as a Bitcoin address and a WIF', async () => {
    const p = await open();
    await unlock(p);
    assert.equal(p.window.localStorage['zswap:cpk:' + A.ACCOUNT.toLowerCase()], F.seed, 'Tacit\'s identity for this signature');
    const link = p.$('pvKey').querySelector('a[href*="mempool.space/address/"]');
    assert.ok(link, 'the Bitcoin address is shown');
    assert.equal(link.getAttribute('href'), 'https://mempool.space/address/' + F.btc.address);
    p.click(p.$('pvKey').querySelector('button[data-a="btckey"]'));
    assert.equal(p.window.__promptDefaults.at(-1), F.btc.wif, 'the same key, as a WIF for any Bitcoin wallet');
    p.close();
  });

  test('the Bitcoin balance of that address is shown beside it', async () => {
    const p = await open();
    p.chain.lanes['mempool.space/api/address/'] = { chain_stats: { funded_txo_sum: 150000, spent_txo_sum: 50000 }, mempool_stats: { funded_txo_sum: 0, spent_txo_sum: 0 } };
    await unlock(p);
    poke(p);
    await p.waitFor(() => /0\.001 BTC/.test(p.text('pvKey')), { label: 'the balance' });
    await p.settle();
    p.close();
  });

  test('a wallet that reports v as 0/1 derives the same key as one that reports 27/28', async () => {
    const p = await open();
    p.chain.personalSig = F.sig.slice(0, 130) + '00';
    await unlock(p);
    assert.equal(p.window.localStorage['zswap:cpk:' + A.ACCOUNT.toLowerCase()], F.seed, 'v is canonicalized before hashing, as Tacit does');
    p.close();
  });

  test('a contract wallet must sign identically twice, is warned, and is handed its key', async () => {
    const p = await open();
    p.chain.code.set(A.ACCOUNT.toLowerCase(), '0x6000');
    p.queueConfirm(true);
    p.click('pvGo');
    await p.waitFor(() => /Key unlocked/.test(p.text('pvKey')), { label: 'the key to unlock' });
    assert.equal(p.chain.personalSigned.length, 2, 'signed twice to prove it signs the same way');
    assert.equal(p.window.__promptDefaults.at(-1), F.seed, 'and the key is shown to keep');
    p.close();
  });

  test('a contract wallet that signs differently each time is refused', async () => {
    const p = await open();
    p.chain.code.set(A.ACCOUNT.toLowerCase(), '0x6000');
    let k = 0;
    Object.defineProperty(p.chain, 'personalSig', { configurable: true, get: () => '0x' + (k++ ? '44' : '33').repeat(64) + '1b' });
    p.click('pvGo');
    await p.waitFor(() => /two different ways/.test(p.text('stat')), { label: 'the refusal' });
    assert.doesNotMatch(p.text('pvKey'), /Key unlocked/);
    assert.equal(p.window.localStorage['zswap:cpk:' + A.ACCOUNT.toLowerCase()], undefined, 'no key is kept');
    p.close();
  });

  test('an EIP-7702 account is an ordinary account', async () => {
    const p = await open();
    p.chain.code.set(A.ACCOUNT.toLowerCase(), '0xef0100' + 'ab'.repeat(20));
    await unlock(p);
    assert.equal(p.asked.confirm?.length ?? 0, 0, 'no contract-wallet warning');
    p.close();
  });

  test('the key alone recovers a note sealed to it elsewhere, and it can be withdrawn', async () => {
    const p = await open({ storage: { ['zswap:cpk:' + A.ACCOUNT.toLowerCase()]: F.seed } });
    p.chain.logs.push(leavesLog(0, [F.found.leaf], [F.found.memo]));
    p.chain.nextLeaf = 1;
    advance(p);
    p.click(p.$('pvKey').querySelector('button[data-a="recover"]'));
    await p.waitFor(() => /Recovered 1 deposit/.test(p.text('stat')), { label: 'the memo to be opened', ...SLOW });
    assert.match(p.text('pvList'), /0\.02 tETH found/);
    p.select('pvChain', '1');
    p.select('pvAct', 'out');
    p.click(p.$('pvList').querySelector('button[data-a="exit"]'));
    await p.waitFor(() => p.window.__relayPosts.length === 1, { label: 'the withdrawal to reach the relay', ...SLOW });
    const op = p.window.__relayPosts[0].op;
    assert.equal(op.nk, F.found.note.secret, 'spent with the secret its memo carried');
    assert.equal(op.value, F.found.note.value);
    assert.equal(op.leafIndex, 0);
    p.close();
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
    await p.settle();
    assert.equal(p.window.localStorage['zswap:cprelay'], undefined, 'an empty answer clears the override');
    assert.match(p.text('stat'), /Relay: https:\/\/api\.tacit\.finance/);
    p.queuePrompt('http://not-secure');
    p.click(p.$('pvKey').querySelector('button[data-a="relay"]'));
    await p.settle();
    assert.match(p.text('stat'), /https URL/);
    p.close();
  });
});

describe('settling from this wallet', () => {
  test('a deposit can have the relay prove only, and the wallet sends pool.settle with the memo', async () => {
    const p = await open();
    await unlock(p);
    p.select('pvPath', 'self');
    await deposit(p);
    const post = p.window.__relayPosts[0];
    assert.equal(post.type, 'wrap');
    assert.equal(post.mode, 'prove');
    const memo = post.memos[0];
    const pv = '0x' + '12'.repeat(200) + F.depositId.slice(2), pr = '0x' + 'ab'.repeat(260);
    p.chain.relay.status = { status: 'proven', publicValues: pv, proof: pr };
    poke(p);
    await p.waitFor(() => p.$('pvList').querySelector('button[data-a="wrapsend"]'), { label: 'the settle button', timeout: 20000 });
    p.click(p.$('pvList').querySelector('button[data-a="wrapsend"]'));
    await p.waitFor(() => p.chain.sentTo(POOL).length === 2, { label: 'settle to be sent', timeout: 15000 });
    const tx = p.chain.sentTo(POOL)[1];
    assert.equal(tx.data, '0x717fd7f2' + coder.encode(['bytes', 'bytes', 'bytes[]'], [pv, pr, [memo]]).slice(2), 'pool.settle(pv, proof, [memo])');
    assert.equal(BigInt(tx.gas), 700000n);
    await p.waitFor(() => /Settled into the pool/.test(p.text('stat')), { timeout: 15000 });
    p.close();
  });
});

describe('the rescue key', () => {
  test('a recipient with contract code gets a derived rescue address, and the key is shown on demand', async () => {
    const p = await open();
    p.chain.code.set(A.OTHER.toLowerCase(), '0x6000');
    await unlock(p);
    await deposit(p);
    settleDeposit(p);
    poke(p);
    await p.waitFor(() => /exit/.test(p.text('pvList')), SLOW);
    // The rescue address is a key derived from the note key and the index, exactly as the page does it:
    // sha256("zswap-exit-rescue-v1" ‖ key ‖ index_be8) mod n.
    const key = p.window.localStorage['zswap:cpk:' + A.ACCOUNT.toLowerCase()];
    const N = 0xfffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141n;
    const be8 = (n) => '0x' + BigInt(n).toString(16).padStart(16, '0');
    const priv = (BigInt(sha256(concat([toUtf8Bytes('zswap-exit-rescue-v1'), key, be8(0)]))) % N) || 1n;
    const rescuePriv = '0x' + priv.toString(16).padStart(64, '0');
    const rescue = computeAddress(rescuePriv).toLowerCase();
    const net = NET_BASE * 10n ** 10n;
    const recipe = { ...baseRecipe(net), finalRecipient: rescue };
    recipe.calls[0].data = '0x9a2ac6d5' + coder.encode(['address', 'uint32', 'bytes'], [A.OTHER, 200000, '0x']).slice(2);
    p.chain.escrow = escrowOf(recipe);
    p.type('pvTo', A.OTHER);
    p.select('pvChain', '8453');
    p.select('pvAct', 'out');
    p.click(p.$('pvList').querySelector('button[data-a="exit"]'));
    await p.waitFor(() => p.window.__relayPosts.length === 2, SLOW);
    assert.equal(p.window.__relayPosts[1].op.recipient, p.chain.escrow, 'the recipe with the rescue recipient is what was proven');
    await p.waitFor(() => p.$('pvList').querySelector('button[data-a="rescue"]'), { label: 'the rescue key button' });
    p.click(p.$('pvList').querySelector('button[data-a="rescue"]'));
    const shown = p.window.__promptDefaults[p.window.__promptDefaults.length - 1];
    assert.equal(shown, rescuePriv, 'the offered key is the derived one');
    assert.match(p.asked.prompt[p.asked.prompt.length - 1], new RegExp(rescue, 'i'), 'and the prompt names its address');
    p.close();
  });
});

describe('a deposit that never landed', () => {
  async function lostDeposit() {
    const p = await open();
    await unlock(p);
    p.type('pvAmt', '0.01');
    p.chain.failNextReceipt = true;          // accepted by the wallet, thrown out by the chain
    p.click('pvGo');
    await p.waitFor(() => p.chain.sentTo(POOL).length === 1);
    await p.waitFor(() => /reverted/.test(p.text('stat')), { label: 'the failed receipt' });
    assert.equal(p.window.__relayPosts.length, 0, 'nothing was sent to the relay');
    assert.match(p.text('pvList'), /settle/, 'fresh: still offered as settle');
    const real = p.window.Date.now;
    p.window.Date.now = () => real() + 11 * 60 * 1000;
    poke(p);
    await p.waitFor(() => /deposit not seen/.test(p.text('pvList')), { label: 'the stale warning', timeout: 15000 });
    return p;
  }

  test('is called out after ten minutes, and the warning clears the moment the chain shows the deposit', async () => {
    const p = await lostDeposit();
    p.queueConfirm(false);
    p.click(p.$('pvList').querySelector('button[data-a="forget"]'));
    assert.match(p.text('pvList'), /0\.01 tETH/, 'declined: the record stays');
    p.chain.logs.push(wrapLog(F.depositId, F.amountWei));
    advance(p);
    poke(p);
    await p.waitFor(() => !/deposit not seen/.test(p.text('pvList')), { label: 'the warning to clear once the Wrap is seen', timeout: 15000 });
    assert.match(p.text('pvList'), /settle/, 'a deposit the chain shows is offered for settling, never for forgetting');
    p.close();
  });

  test('can be forgotten once confirmed', async () => {
    const p = await lostDeposit();
    p.queueConfirm(true);
    p.click(p.$('pvList').querySelector('button[data-a="forget"]'));
    await p.settle();
    assert.match(p.text('pvList'), /No deposits yet/, 'confirmed: the record is gone');
    assert.equal(Object.keys(p.window.localStorage).filter(k => k.startsWith('zswap:cpn:')).map(k => JSON.parse(p.window.localStorage[k]).length)[0], 0, 'and not stored either');
    p.close();
  });
});

/**
 * A key found in storage is not proof of anything: one script run on the
 * origin could have written it, and deposits, sends to self and the Bitcoin
 * address shown would then belong to whoever planted it. The first action
 * re-derives the key from the wallet, and a mismatch is the user's call.
 */
describe('a key the wallet did not derive', () => {
  const PLANTED = '0x' + '5a'.repeat(32);
  const planted = () => open({ storage: { ['zswap:cpk:' + A.ACCOUNT.toLowerCase()]: PLANTED } });
  const verify = async p => {
    await p.waitFor(() => p.$('pvKey').querySelector('[data-a="verify"]'), { label: 'verify button' });
    assert.ok(!/mempool\.space/.test(p.$('pvKey').innerHTML), 'no receive address before the key is checked');
    p.click(p.$('pvKey').querySelector('[data-a="verify"]'));
    await p.settle();
  };

  test('is replaced by the wallet\'s own key unless the user says they imported it', async () => {
    const p = await planted();
    p.queueConfirm(false);
    await verify(p);
    assert.equal(p.chain.personalSigned.length, 1, 'one signature to check it');
    assert.equal(p.window.localStorage['zswap:cpk:' + A.ACCOUNT.toLowerCase()], F.seed);
    assert.match(p.text('stat'), /own key is now in use/);
    assert.match(p.$('pvKey').innerHTML, /mempool\.space/, 'the verified key shows its address');
    p.close();
  });

  test('an imported key is kept when the user confirms it', async () => {
    const p = await planted();
    p.queueConfirm(true);
    await verify(p);
    assert.equal(p.window.localStorage['zswap:cpk:' + A.ACCOUNT.toLowerCase()], PLANTED);
    assert.equal(p.window.eval('cpVer'), 1);
    p.close();
  });
});

/**
 * Some in-app wallet browsers return from prompt() at once without showing
 * it, or throw. The key backup is shown only through that dialog, so on those
 * browsers the user was told to keep a key they never saw. The page now asks
 * in its own dialog when the browser's is blocked.
 */
describe('a browser that blocks prompt()', () => {
  test('the key backup opens in the page, with the key and a copy button', async () => {
    const p = await open();
    await unlock(p);
    p.window.prompt = () => { throw new Error('blocked'); };
    const backup = [...p.$('pvKey').querySelectorAll('button')].find(b => b.dataset.a === 'backup')
      || p.doc.querySelector('[data-a="backup"]');
    assert.ok(backup, 'a backup control');
    p.click(backup);
    await p.waitFor(() => !p.$('wkWrap').classList.contains('hide'), { label: 'the in-page dialog' });
    assert.equal(p.$('wkList').querySelector('textarea').value, F.seed);
    assert.ok([...p.$('wkList').querySelectorAll('button')].some(b => b.textContent === 'Copy'));
    [...p.$('wkList').querySelectorAll('button')].find(b => b.textContent === 'OK').click();
    await p.waitFor(() => p.$('wkWrap').classList.contains('hide'), { label: 'dialog closed' });
    p.close();
  });
});

describe('deposits the relay or the pool turn away', () => {
  test('a deposit the relay would not settle says so, and says what to do', async () => {
    const p = await open();
    await unlock(p);
    const inner = p.window.fetch;
    p.window.fetch = async (url, init) => {
      if (String(url).includes('/confidential/submit') && init && /"type":"wrap"/.test(init.body)) return { ok: false, status: 429, json: async () => ({ error: 'free_budget: no free relays left today' }) };
      return inner(url, init);
    };
    p.type('pvAmt', '0.01');
    p.click('pvGo');
    await p.waitFor(() => p.chain.sentTo(POOL).length === 1, { label: 'the deposit to be sent' });
    await p.waitFor(() => /did not take the settle/.test(p.text('stat')), { label: 'the refusal', ...SLOW });
    assert.match(p.text('stat'), /free_budget/);
    assert.match(p.text('stat'), /Settle: from this wallet/);
    assert.doesNotMatch(p.text('stat'), /relay is settling/);
    p.close();
  });

  test('a deposit the pool already consumed is not handed to the relay again', async () => {
    const p = await open();
    await unlock(p);
    p.chain.answer(POOL, SEL.DEPOSIT, () => '0x' + u256(p.chain.sentTo(POOL).length ? 2 : 0));
    p.type('pvAmt', '0.01');
    p.click('pvGo');
    await p.waitFor(() => p.chain.sentTo(POOL).length === 1, { label: 'the deposit to be sent' });
    await p.waitFor(() => /Deposited/.test(p.text('stat')), { label: 'the deposit to finish', ...SLOW });
    assert.equal(p.window.__relayPosts.filter(x => x.type === 'wrap').length, 0);
    p.close();
  });

  test('a retired pool takes no deposits, and says what still works', async () => {
    const p = await open();
    p.chain.answer(POOL, '6ff968c3', '0x' + '00'.repeat(12) + '11'.repeat(20));
    await unlock(p);
    poke(p);
    await p.waitFor(() => /retired/.test(p.text('pvHint')), { label: 'the retired note', ...SLOW });
    assert.match(p.text('pvHint'), /can still be withdrawn/);
    p.type('pvAmt', '0.01');
    p.click('pvGo');
    await p.waitFor(() => /retired/.test(p.text('stat')), { label: 'the refusal' });
    assert.equal(p.chain.sentTo(POOL).length, 0, 'nothing is sent to a retired pool');
    p.close();
  });
});

/**
 * The relay eats a deposit's gas and proof and nothing in the pool can make a
 * depositor pay for it — passesFloor short-circuits every wrap-type job, and
 * the tip lives outside the proof where a fee gate structurally cannot see it.
 * So the tip is a default, not a rule: it rides WrapTipForwarder as plain ETH
 * on top of msg.value, the relay's own quote sizes it, the page bounds it, and
 * any trouble on that path falls back to the wrap we have always sent.
 */
/**
 * The failure path of ec36f6d. A pool whose history will not load is not a pool
 * with nothing in it, but the page used to render it that way: notes read as
 * "deposit not seen" over a "Shielded 0" summary, with a destructive "forget"
 * beside them. A read that failed must never be presented as a fact about
 * someone's money — so this drives the failure rather than the happy path.
 */
/**
 * Tacit's points program is read-only and lives on a host of its own, so the
 * page tries the relay first and the indexer second. Every way that can fail —
 * both hosts down, a row for a different address, an unparseable total, no row
 * at all — must leave the panel saying nothing rather than saying zero: a
 * deposit the program has not counted is not a deposit worth nothing.
 */
/**
 * Settling from this wallet still costs Tacit a proof — the pool pays fees to
 * msg.sender, which under self-settle is the depositor, so nothing inside the
 * proof can reach the relay. The tip therefore rides the settle transaction the
 * wallet is already sending, and the relay quotes it separately from a wrap's.
 * A relay that quotes no prove figure, or a forwarder that is not there yet,
 * sends the settle exactly as this page has always sent it.
 */
/**
 * A settleWithTip whose arguments are encoded wrong fails in the worst way
 * available: the pre-flight reverts, the fallback sends a plain untipped settle,
 * everything looks healthy and the relay is never paid. So the encoding is
 * pinned against a vector Tacit generated with `cast` from the real ABI, using
 * the page's own ABI helpers rather than a reimplementation of them.
 */
describe('the settleWithTip encoding', () => {
  test('reproduces Tacit\'s own calldata vector byte for byte', async () => {
    const p = await open();
    const data = p.window.eval(`(() => {
      const pv = "0xdeadbeef", pr = "0xcafebabe", ms = ["0x${'11'.repeat(32)}"], to = "0x0000000000000000000000000000000000001337";
      const a = encBytes(pv), b = encBytes(pr), tl = ms.map(encBytes);
      let off = ms.length * 32, hd = encUint(ms.length);
      for (const x of tl) { hd += encUint(off); off += x.length / 2 }
      const mo = 128 + (a.length + b.length) / 2;
      return "0x" + SEL_CPSTIP + encUint(128) + encUint(128 + a.length / 2) + encUint(mo)
        + encAddr(to) + a + b + hd + tl.join("");
    })()`);
    const vector = '0x70b16a7d'
      + '0000000000000000000000000000000000000000000000000000000000000080'
      + '00000000000000000000000000000000000000000000000000000000000000c0'
      + '0000000000000000000000000000000000000000000000000000000000000100'
      + '0000000000000000000000000000000000000000000000000000000000001337'
      + '0000000000000000000000000000000000000000000000000000000000000004'
      + 'deadbeef00000000000000000000000000000000000000000000000000000000'
      + '0000000000000000000000000000000000000000000000000000000000000004'
      + 'cafebabe00000000000000000000000000000000000000000000000000000000'
      + '0000000000000000000000000000000000000000000000000000000000000001'
      + '0000000000000000000000000000000000000000000000000000000000000020'
      + '0000000000000000000000000000000000000000000000000000000000000020'
      + '1111111111111111111111111111111111111111111111111111111111111111';
    assert.equal(data.toLowerCase(), vector.toLowerCase());
    p.close();
  });
});

describe('tipping the relay for a proof it did not charge for', () => {
  const SFWD = '0x0000008353ee6dea1236544938c546e27010416d';
  const quoteProve = (p, wei) => {
    Object.defineProperty(p.chain.lanes, RELAY + '/confidential/quote', {
      configurable: true, enumerable: true,
      get: () => ({ ticker: 'cETH', relayFeeEligible: true, recommendedProveTipWei: String(wei) }),
    });
    p.chain.answer(SFWD, '70b16a7d', '0x');
  };

  test('an absurd prove quote is bounded absolutely, not by the gas price', async () => {
    const p = await open();
    p.$('pvPath').value = 'self';
    quoteProve(p, 10n ** 18n);                   // one ether to prove one settle
    await unlock(p);
    await deposit(p);
    p.chain.relay.status = { status: 'proven', publicValues: '0x' + F.depositId.slice(2), proof: '0x' + 'ab'.repeat(32) };
    poke(p);
    await p.waitFor(() => !!p.$('pvList').querySelector('button[data-a="wrapsend"]'), { label: 'the settle button', timeout: 20000 });
    p.click(p.$('pvList').querySelector('button[data-a="wrapsend"]'));
    await p.waitFor(() => p.chain.sentTo(SFWD).length === 1, { label: 'the tipped settle', timeout: 20000 });
    assert.equal(BigInt(p.chain.sentTo(SFWD)[0].value), 300000000000000n, 'clamped to the absolute ceiling');
    p.close();
  });

  test('a self-settled deposit pays for its proof through the forwarder', async () => {
    const p = await open();
    p.$('pvPath').value = 'self';
    quoteProve(p, 90000000000000n);
    await unlock(p);
    await deposit(p);
    p.chain.relay.status = { status: 'proven', publicValues: '0x' + F.depositId.slice(2), proof: '0x' + 'ab'.repeat(32) };
    poke(p);
    await p.waitFor(() => !!p.$('pvList').querySelector('button[data-a="wrapsend"]'), { label: 'the settle button', timeout: 20000 });
    p.click(p.$('pvList').querySelector('button[data-a="wrapsend"]'));
    await p.waitFor(() => p.chain.sentTo(SFWD).length === 1, { label: 'the tipped settle', timeout: 20000 });
    const tx = p.chain.sentTo(SFWD)[0];
    assert.equal(tx.data.slice(2, 10), '70b16a7d', 'settleWithTip(bytes,bytes,bytes[],address)');
    assert.equal(BigInt(tx.value), 90000000000000n,
      'the whole value is the tip: settle has no amount leg, and a prove tip is not bounded by gas');
    assert.equal(BigInt('0x' + tx.data.slice(10, 74)), 128n, 'four head words before the first bytes');
    assert.match(tx.data.slice(10 + 3 * 64).toLowerCase(), new RegExp('^0{24}' + '68575b073de49a94e3e3acf6f3a0d6e3b66267c7'), 'the relay is named as recipient');
    assert.equal(p.chain.sentTo(POOL).length, 1, 'only the deposit itself went to the pool');
    p.close();
  });

  test('no prove figure quoted sends the settle straight to the pool', async () => {
    const p = await open();
    p.$('pvPath').value = 'self';
    Object.defineProperty(p.chain.lanes, RELAY + '/confidential/quote', {
      configurable: true, enumerable: true,
      get: () => ({ ticker: 'cETH', relayFeeEligible: true }),   // no prove figure
    });
    await unlock(p);
    await deposit(p);
    p.chain.relay.status = { status: 'proven', publicValues: '0x' + F.depositId.slice(2), proof: '0x' + 'ab'.repeat(32) };
    poke(p);
    await p.waitFor(() => !!p.$('pvList').querySelector('button[data-a="wrapsend"]'), { label: 'the settle button', timeout: 20000 });
    p.click(p.$('pvList').querySelector('button[data-a="wrapsend"]'));
    await p.waitFor(() => p.chain.sentTo(POOL).length === 2, { label: 'the plain settle', timeout: 20000 });
    assert.equal(p.chain.sentTo(SFWD).length, 0, 'no forwarder call without a quoted prove tip');
    p.close();
  });
});

describe('the points a wallet has been credited', () => {
  const PTS = 'tacit-points.onrender.com';
  const serve = (p, host, body) => {
    Object.defineProperty(p.chain.lanes, host + '/points/', {
      configurable: true, enumerable: true, get: () => body,
    });
  };

  const DIST = '0x000000c918e44a3a443937fa7594ea4f7c95d6b9';
  const PROOF = ['0x' + '11'.repeat(32), '0x' + '22'.repeat(32)];
  // The distributor answers its own pre-flight; without that the page declines
  // to send, which is 'a claim the chain would refuse is not offered'.
  const claiming = (p, host, body) => {
    Object.defineProperty(p.chain.lanes, host + '/claim/', {
      configurable: true, enumerable: true, get: () => body,
    });
    p.chain.answer(DIST, '2f52ebb7', '0x');
  };

  test('offers the TAC the points earned, and claims it with its proof', async () => {
    const p = await open();
    serve(p, RELAY, { address: A.ACCOUNT.toLowerCase(), points: 5, deposit_count: 1 });
    claiming(p, RELAY, { address: A.ACCOUNT.toLowerCase(), distributor: DIST,
      cumulativeAmount: '926845047264463185251', claimedWei: '0',
      unclaimedWei: '926845047264463185251', proof: PROOF });
    await unlock(p);
    await p.waitFor(() => !!p.$('pvKey').querySelector('button[data-a="ptsclaim"]'), { label: 'the claim button', ...SLOW });
    assert.match(p.text('pvKey'), /claim 926\.845/);
    p.click(p.$('pvKey').querySelector('button[data-a="ptsclaim"]'));
    await p.waitFor(() => p.chain.sentTo(DIST).length === 1, { label: 'the claim to be sent', ...SLOW });
    const tx = p.chain.sentTo(DIST)[0];
    assert.equal(tx.data.slice(2, 10), '2f52ebb7', 'claim(uint256,bytes32[])');
    assert.equal(BigInt('0x' + tx.data.slice(10, 74)), 926845047264463185251n, 'the cumulative amount, not the unclaimed one');
    assert.equal(BigInt('0x' + tx.data.slice(138, 202)), 2n, 'both proof elements');
    assert.equal('0x' + tx.data.slice(202, 266), PROOF[0]);
    p.close();
  });

  test('nothing to claim offers no button', async () => {
    const p = await open();
    serve(p, RELAY, { address: A.ACCOUNT.toLowerCase(), points: 5, deposit_count: 1 });
    claiming(p, RELAY, { address: A.ACCOUNT.toLowerCase(), distributor: DIST,
      cumulativeAmount: '0', claimedWei: '0', unclaimedWei: '0', proof: null });
    await unlock(p);
    await p.waitFor(() => /counted/.test(p.text('pvKey')), { label: 'the points row', ...SLOW });
    assert.equal(p.$('pvKey').querySelector('button[data-a="ptsclaim"]'), null);
    p.close();
  });

  test('a proof that is not a proof is refused', async () => {
    const p = await open();
    serve(p, RELAY, { address: A.ACCOUNT.toLowerCase(), points: 5, deposit_count: 1 });
    claiming(p, RELAY, { address: A.ACCOUNT.toLowerCase(), distributor: DIST,
      cumulativeAmount: '1000', claimedWei: '0', unclaimedWei: '1000', proof: ['not-a-hash'] });
    await unlock(p);
    await p.waitFor(() => /counted/.test(p.text('pvKey')), { label: 'the points row', ...SLOW });
    assert.equal(p.$('pvKey').querySelector('button[data-a="ptsclaim"]'), null, 'no claim built on markup');
    p.close();
  });

  test('a wallet that never wrapped shows no points row at all', async () => {
    const p = await open();
    serve(p, RELAY, { address: A.ACCOUNT.toLowerCase(), points: 0, deposit_count: 0, amount_wei: '0', deposits: [] });
    await unlock(p);
    await p.waitFor(() => /Key unlocked/.test(p.text('pvKey')), { label: 'the key row' });
    await p.settle();
    assert.doesNotMatch(p.text('pvKey'), /Points/, 'a zeroed row is not worth a line');
    p.close();
  });

  test("names a share of today's pot once the day has points to divide by", async () => {
    const p = await open();
    serve(p, RELAY, { address: A.ACCOUNT.toLowerCase(), points: 5, deposit_count: 1,
      today: { points: 3, totalPoints: 14, dayBudgetWei: '1111111111111111111111' } });
    await unlock(p);
    await p.waitFor(() => /Points/.test(p.text('pvKey')), { label: 'the points row', ...SLOW });
    // 3/14 of 1111.11 = 238.09, and it must read as an estimate that moves
    assert.match(p.text('pvKey'), /your 3 of today's 14 points — about 238\.09[0-9]* TAC at the current split/, p.text('pvKey'));
    p.close();
  });

  test('a day with no points yet divides by nothing and says so', async () => {
    const p = await open();
    serve(p, RELAY, { address: A.ACCOUNT.toLowerCase(), points: 5, deposit_count: 1,
      today: { points: 0, totalPoints: 0, dayBudgetWei: '1111111111111111111111' } });
    await unlock(p);
    await p.waitFor(() => /Points/.test(p.text('pvKey')), { label: 'the points row', ...SLOW });
    assert.match(p.text('pvKey'), /none today of 1111\.11 TAC shared/);
    assert.doesNotMatch(p.text('pvKey'), /NaN|Infinity|current split/);
    p.close();
  });

  test("names today's whole budget, and never a share of it", async () => {
    const p = await open();
    serve(p, RELAY, { address: A.ACCOUNT.toLowerCase(), points: 5, deposit_count: 1,
      today: { points: 0, dayBudgetWei: '1111111111111111111111' } });
    await unlock(p);
    await p.waitFor(() => /Points/.test(p.text('pvKey')), { label: 'the points row', ...SLOW });
    assert.match(p.text('pvKey'), /none today of 1111\.11 TAC shared/, p.text('pvKey'));
    // the day's TOTAL points are not published, so no per-point value may be implied
    assert.doesNotMatch(p.text('pvKey'), /worth|per point|you will (get|earn)/i);
    p.close();
  });

  test('a budget it cannot read is simply not mentioned', async () => {
    const p = await open();
    serve(p, RELAY, { address: A.ACCOUNT.toLowerCase(), points: 5, deposit_count: 1,
      today: { points: 2, dayBudgetWei: 'soon' } });
    await unlock(p);
    await p.waitFor(() => /counted/.test(p.text('pvKey')), { label: 'the points row', ...SLOW });
    assert.doesNotMatch(p.text('pvKey'), /today/, 'no half-formed claim about today');
    p.close();
  });

  test('names the deposits a Privacy Pools withdrawal boosted', async () => {
    const p = await open();
    serve(p, RELAY, { address: A.ACCOUNT.toLowerCase(), points: 11, deposit_count: 3,
      deposits: [{ pp_boosted: true }, { pp_boosted: false }, { pp_boosted: true }] });
    await unlock(p);
    await p.waitFor(() => /counted/.test(p.text('pvKey')), { label: 'the points row', ...SLOW });
    assert.match(p.text('pvKey'), /11 from 3 deposits counted, 2 at 1\.2\u00d7/, p.text('pvKey'));
    p.close();
  });

  test('a wallet boosted on every deposit says all of them, not a count', async () => {
    const p = await open();
    serve(p, RELAY, { address: A.ACCOUNT.toLowerCase(), points: 6, deposit_count: 1,
      deposits: [{ pp_boosted: true }] });
    await unlock(p);
    await p.waitFor(() => /counted/.test(p.text('pvKey')), { label: 'the points row', ...SLOW });
    assert.match(p.text('pvKey'), /1 deposit counted, all at 1\.2\u00d7/, p.text('pvKey'));
    p.close();
  });

  // An endpoint that predates the multiplier sends no `pp_boosted` at all, and
  // one that sends no `deposits` array is the shape every other test here uses.
  test('an endpoint that does not publish the boost claims no boost', async () => {
    const p = await open();
    serve(p, RELAY, { address: A.ACCOUNT.toLowerCase(), points: 5, deposit_count: 2,
      deposits: [{ tx_hash: '0x' + 'ab'.repeat(32) }, { pp_boosted: 'yes' }] });
    await unlock(p);
    await p.waitFor(() => /counted/.test(p.text('pvKey')), { label: 'the points row', ...SLOW });
    assert.match(p.text('pvKey'), /5 from 2 deposits counted/);
    assert.doesNotMatch(p.text('pvKey'), /1\.2|boost/i, 'a truthy string is not the flag');
    p.close();
  });

  test('shows before the Tacit key is unlocked: points follow the wallet, not the key', async () => {
    const p = await open();
    serve(p, RELAY, { address: A.ACCOUNT.toLowerCase(), points: 5, deposit_count: 1 });
    await p.waitFor(() => /Points/.test(p.text('pvKey')), { label: 'the points row before unlock', ...SLOW });
    assert.match(p.text('pvKey'), /Sign once to unlock/, 'still asking for the key');
    assert.match(p.text('pvKey'), /5 from 1 deposit counted/, 'and already showing what the wallet earned');
    p.close();
  });

  test('shows what the program counted, from the relay host', async () => {
    const p = await open();
    serve(p, RELAY, { address: A.ACCOUNT.toLowerCase(), points: 5, deposit_count: 1 });
    await unlock(p);
    await p.waitFor(() => /Points/.test(p.text('pvKey')), { label: 'the points row', ...SLOW });
    assert.match(p.text('pvKey'), /5 from 1 deposit counted/);
    p.close();
  });

  test('falls back to the indexer host when the relay does not serve it', async () => {
    const p = await open();
    serve(p, PTS, { address: A.ACCOUNT.toLowerCase(), points: 12.5, deposit_count: 3 });
    await unlock(p);
    await p.waitFor(() => /Points/.test(p.text('pvKey')), { label: 'the points row via fallback', ...SLOW });
    assert.match(p.text('pvKey'), /12\.5 from 3 deposits counted/);
    p.close();
  });

  test('says nothing at all when neither host answers', async () => {
    const p = await open();                       // no lane for either host
    await unlock(p);
    await p.waitFor(() => /Key unlocked/.test(p.text('pvKey')), { label: 'the key row' });
    await p.settle();
    assert.doesNotMatch(p.text('pvKey'), /Points/, 'no row rather than a zero');
    assert.doesNotMatch(p.text('pvKey'), /0 from 0/);
    p.close();
  });

  test('refuses a row that belongs to another address', async () => {
    const p = await open();
    serve(p, RELAY, { address: A.OTHER.toLowerCase(), points: 999, deposit_count: 9 });
    await unlock(p);
    await p.settle();
    assert.doesNotMatch(p.text('pvKey'), /999/, 'a row for someone else is not this wallet\'s total');
    p.close();
  });

  test('refuses a total it cannot read', async () => {
    const p = await open();
    serve(p, RELAY, { address: A.ACCOUNT.toLowerCase(), points: 'lots', deposit_count: 1 });
    await unlock(p);
    await p.settle();
    assert.doesNotMatch(p.text('pvKey'), /Points/);
    p.close();
  });
});

describe('a pool history that will not load', () => {
  // Every route the page has to the log history: the wallet RPC that cfgRead
  // uses, and each CP_LOGS fallback it reaches for over fetch.
  // Returns a restore(). Patching the page's transport without putting it back
  // leaks in-flight work into teardown, where the window's globals are gone.
  const noHistory = (p) => {
    const req = p.chain.request.bind(p.chain), inner = p.window.fetch, now = p.window.Date.now;
    p.chain.request = async (a) => {
      if (a && a.method === 'eth_getLogs') throw Error('node unavailable');
      return req(a);
    };
    p.window.fetch = async (u, init) => {
      if (init && init.body && String(init.body).includes('eth_getLogs')) throw new p.window.TypeError('failed to fetch');
      return inner(u, init);
    };
    return async () => { p.chain.request = req; p.window.fetch = inner; p.window.Date.now = now; await p.settle(); };
  };

  test('says it has not been read, rather than reporting the notes as missing', async () => {
    const p = await open();
    const restore = noHistory(p);          // before anything syncs, so cpPool is never populated
    await unlock(p);
    await deposit(p);
    // Past the ten minutes that used to turn an unseen deposit into "deposit not seen".
    const real = p.window.Date.now;
    p.window.Date.now = () => real() + 700 * 1000;
    poke(p);
    await p.waitFor(() => /Reading the pool/.test(p.text('pvList')), { label: 'the unread-pool state', ...SLOW });
    const list = p.text('pvList');
    assert.doesNotMatch(list, /deposit not seen/, 'a failed read is not a missing deposit');
    assert.doesNotMatch(list, /Shielded/, 'and it does not claim a balance it could not read');
    assert.equal(p.$('pvList').querySelector('button[data-a="forget"]'), null,
      'nothing offers to discard a record the page could not check');
    await restore();
    p.close();
  });

  test('the note comes back as itself once the history loads', async () => {
    const p = await open();
    const restore = noHistory(p);
    await unlock(p);
    await deposit(p);
    poke(p);
    await p.waitFor(() => /Reading the pool/.test(p.text('pvList')), { label: 'the unread state', ...SLOW });
    // Restore the history and let it settle: the same note must read as ready.
    await restore();
    settleDeposit(p);
    poke(p);
    await p.waitFor(() => !!p.$('pvList').querySelector('button[data-a="exit"]'), { label: 'the note to come back', timeout: 20000 });
    assert.doesNotMatch(p.text('pvList'), /Reading the pool/);
    p.close();
  });
});

describe('tipping the relay for a deposit', () => {
  const TIPFWD = '0x000000d218b03db5837943b0b05dea2965ae956e';
  const TIPTO = '0x68575b073de49a94e3e3acf6f3a0d6e3b66267c7';
  const SEL_WTIP = 'fc24c435';
  // The relay quotes a tip, and the forwarder answers its pre-flight. Without the
  // second half the page falls back to the plain wrap — which is the behaviour
  // 'a quote the relay will not answer' covers deliberately.
  const quoting = (p, tipWei) => {
    Object.defineProperty(p.chain.lanes, RELAY + '/confidential/quote', {
      configurable: true, enumerable: true,
      get: () => ({ ticker: 'cETH', assetId: F.ethAssetId, relayFeeEligible: true, recommendedWrapTipWei: String(tipWei) }),
    });
    p.chain.answer(TIPFWD, SEL_WTIP, '0x');
  };

  // A tip names ONE payee, and the page hardcodes Tacit's relay key. Whoever
  // pins a relay of their own would therefore quote a tip from that relay and
  // pay it to Tacit's - the wrong party for work the pinned relay did. So a tip
  // is only ever built for a relay the page itself lists.
  test('a self-pinned relay is settled with, not tipped', async () => {
    const p = await open({ storage: { 'zswap:cprelay': 'https://relay.example.com' } });
    quoting(p, 115000000000000n);
    Object.defineProperty(p.chain.lanes, 'relay.example.com/confidential/quote', {
      configurable: true, enumerable: true,
      get: () => ({ ticker: 'cETH', assetId: F.ethAssetId, relayFeeEligible: true, recommendedWrapTipWei: '115000000000000' }),
    });
    await unlock(p);
    p.type('pvAmt', '0.01');
    await p.waitFor(() => /0\.01/.test(p.text('pvPrev')), { label: 'the preview', ...SLOW });
    await p.settle();
    assert.doesNotMatch(p.text('pvPrev'), /Relay tip/, p.text('pvPrev'));
    assert.ok(p.$('pvTipL').classList.contains('hide'), 'nothing to tick when a tip can reach nobody');
    p.click('pvGo');
    await p.waitFor(() => p.chain.sentTo(POOL).length === 1, { label: 'the deposit to be sent', ...SLOW });
    assert.equal(p.chain.sentTo(TIPFWD).length, 0, 'no forwarder leg');
    assert.equal(BigInt(p.chain.sentTo(POOL)[0].value), 10000000000000000n, 'the deposit, and not a wei more');
    p.close();
  });

  test('pinning a relay says a tip no longer applies', async () => {
    const p = await open();
    await unlock(p);
    p.window.prompt = () => 'https://relay.example.com';
    p.click(p.$('pvKey').querySelector('button[data-a="more"]'));
    await p.settle();
    p.click(p.$('pvKey').querySelector('button[data-a="relay"]'));
    await p.waitFor(() => /relay\.example\.com/.test(p.text('stat')), { label: 'the relay status', ...SLOW });
    assert.match(p.text('stat'), /pinned, with no fallback and no tip/, p.text('stat'));
    p.close();
  });

  // Clearing the pin puts the tick back, and with the preference it had before.
  test('going back to a listed relay restores the tip', async () => {
    const p = await open({ storage: { 'zswap:cprelay': 'https://relay.example.com' } });
    quoting(p, 115000000000000n);
    await unlock(p);
    await p.settle();
    assert.ok(p.$('pvTipL').classList.contains('hide'));
    p.window.prompt = () => '';
    p.click(p.$('pvKey').querySelector('button[data-a="more"]'));
    await p.settle();
    p.click(p.$('pvKey').querySelector('button[data-a="relay"]'));
    await p.settle();
    p.type('pvAmt', '0.01');
    await p.waitFor(() => /Relay tip/.test(p.text('pvPrev')), { label: 'the tip to come back', ...SLOW });
    assert.equal(p.$('pvTipL').classList.contains('hide'), false);
    p.close();
  });

  // The payee is compiled in; the quote merely agrees with it. A quote that
  // names someone else is a redirect attempt, and the answer is not to tip.
  test('a quote that names a different payee is not tipped', async () => {
    const p = await open();
    Object.defineProperty(p.chain.lanes, RELAY + '/confidential/quote', {
      configurable: true, enumerable: true,
      get: () => ({ ticker: 'cETH', assetId: F.ethAssetId, relayFeeEligible: true,
        recommendedWrapTipWei: '115000000000000', recommendedTipRecipient: '0x' + 'ee'.repeat(20) }),
    });
    p.chain.answer(TIPFWD, SEL_WTIP, '0x');
    await unlock(p);
    p.type('pvAmt', '0.01');
    await p.waitFor(() => /0\.01/.test(p.text('pvPrev')), { label: 'the preview', ...SLOW });
    await p.settle();
    assert.doesNotMatch(p.text('pvPrev'), /Relay tip/, p.text('pvPrev'));
    p.click('pvGo');
    await p.waitFor(() => p.chain.sentTo(POOL).length === 1, { label: 'the deposit to be sent', ...SLOW });
    assert.equal(p.chain.sentTo(TIPFWD).length, 0, 'no forwarder leg');
    p.close();
  });

  test('a quote that names the payee it is paid to is tipped as usual', async () => {
    const p = await open();
    Object.defineProperty(p.chain.lanes, RELAY + '/confidential/quote', {
      configurable: true, enumerable: true,
      get: () => ({ ticker: 'cETH', assetId: F.ethAssetId, relayFeeEligible: true,
        recommendedWrapTipWei: '115000000000000', recommendedTipRecipient: TIPTO.toUpperCase().replace('0X', '0x') }),
    });
    p.chain.answer(TIPFWD, SEL_WTIP, '0x');
    await unlock(p);
    p.type('pvAmt', '0.01');
    await p.waitFor(() => /Relay tip/.test(p.text('pvPrev')), { label: 'the tip', ...SLOW });
    p.close();
  });

  test('a tip that does cover the settle says so', async () => {
    const p = await open();
    quoting(p, 115000000000000n);         // the relay's flat floor, 0.000115 ETH
    await unlock(p);
    p.type('pvAmt', '0.01');
    await p.waitFor(() => /Relay tip/.test(p.text('pvPrev')), { label: 'the tip', ...SLOW });
    assert.match(p.text('pvPrev'), /Relay tip 0\.000115 ETH \(1\.15%\), which covers the settle/, p.text('pvPrev'));
    p.close();
  });

  test('with no gas price to judge by, no tip is taken and nothing is claimed', async () => {
    // cpTipFor clamps the tip by gas x 1.4M, so an unreadable price clamps it to
    // nothing: the unknown is handled by not charging, not by a hopeful sentence.
    const p = await open();
    quoting(p, 115000000000000n);
    p.chain.gasPrice = 0n;
    p.window.eval('gpC[CHAIN_ID]=null');  // gasNow caches per chain
    await unlock(p);
    p.type('pvAmt', '0.01');
    await p.waitFor(() => /Settling costs you nothing/.test(p.text('pvPrev')), { label: 'the untipped preview', ...SLOW });
    assert.doesNotMatch(p.text('pvPrev'), /Relay tip/);
    assert.doesNotMatch(p.text('pvPrev'), /covers the settle/);
    p.close();
  });

  test('the deposit rides the forwarder, amount to the pool and the tip on top', async () => {
    const p = await open();
    quoting(p, 30000000000000n);          // 0.00003 ETH, 3% of a 0.001 deposit
    await unlock(p);
    p.type('pvAmt', '0.001');
    await p.waitFor(() => /Relay tip/.test(p.text('pvPrev')), { label: 'the tip in the preview', ...SLOW });
    // The tip is min(the relay's floor, 3% of the deposit), so on a small deposit
    // it is a fraction of the settle - about 540k gas, 0.000054 ETH at this price.
    // The line says which it is rather than claiming cover it has not established.
    assert.match(p.text('pvPrev'), /Relay tip 0\.00003 ETH \(3\.00%\), part of what the settle costs/);
    assert.match(p.text('pvPrev'), /untick Tip the relay to skip it/);
    p.click('pvGo');
    await p.waitFor(() => p.chain.sent.length === 1, { label: 'the deposit to be sent', ...SLOW });
    const tx = p.chain.sent[0];
    assert.equal(String(tx.to).toLowerCase(), TIPFWD, 'through the forwarder, not straight at the pool');
    assert.equal(BigInt(tx.value), 10n ** 15n + 30000000000000n, 'amount plus tip');
    assert.equal(tx.data.slice(2, 10), SEL_WTIP, 'wrapWithTip(bytes32,uint256,address)');
    assert.equal(BigInt('0x' + tx.data.slice(74, 138)), 10n ** 15n, 'the wrap amount, tip excluded');
    assert.match(tx.data.slice(138).toLowerCase(), new RegExp(TIPTO.slice(2) + '$'), 'the relay wallet is paid');
    p.close();
  });

  test('unticking it sends the plain wrap this page has always sent', async () => {
    const p = await open();
    quoting(p, 30000000000000n);
    await unlock(p);
    p.type('pvAmt', '0.001');
    await p.waitFor(() => /Relay tip/.test(p.text('pvPrev')), { label: 'the tip', ...SLOW });
    p.$('pvTip').checked = false;
    p.$('pvTip').dispatchEvent(new p.window.Event('change', { bubbles: true }));
    await p.waitFor(() => /Settling costs you nothing/.test(p.text('pvPrev')), { label: 'the tip to go' });
    p.click('pvGo');
    await p.waitFor(() => p.chain.sent.length === 1, { label: 'the deposit', ...SLOW });
    const tx = p.chain.sent[0];
    assert.equal(String(tx.to).toLowerCase(), POOL.toLowerCase(), 'straight at the pool');
    assert.equal(BigInt(tx.value), 10n ** 15n, 'no tip on top');
    assert.equal(p.window.localStorage['zswap:cptip'], '0', 'the refusal is remembered');
    p.close();
  });

  test('a relay that quotes an absurd tip is bounded to 3% of the deposit', async () => {
    const p = await open();
    quoting(p, 10n ** 18n);               // one whole ether, for a 0.001 deposit
    await unlock(p);
    p.type('pvAmt', '0.001');
    await p.waitFor(() => /Relay tip/.test(p.text('pvPrev')), { label: 'the bounded tip', ...SLOW });
    assert.match(p.text('pvPrev'), /\(3\.00%\)/, 'the page clamps what the relay asks for');
    p.click('pvGo');
    await p.waitFor(() => p.chain.sent.length === 1, { label: 'the deposit', ...SLOW });
    assert.equal(BigInt(p.chain.sent[0].value), 10n ** 15n + 30000000000000n,
      'a relay cannot decide how much ether leaves this wallet');
    p.close();
  });

  test('max leaves room for the tip, so the whole balance still goes through', async () => {
    const p = await open();
    quoting(p, 30000000000000n);
    await unlock(p);
    p.click('pvMax');
    await p.waitFor(() => !!p.$('pvAmt').value, { label: 'max to fill in', ...SLOW });
    const amt = BigInt(Math.round(parseFloat(p.$('pvAmt').value) * 1e18));
    p.click('pvGo');
    await p.waitFor(() => p.chain.sent.length === 1, { label: 'the deposit', ...SLOW });
    const tx = p.chain.sent[0];
    assert.equal(String(tx.to).toLowerCase(), TIPFWD, 'max still takes the tipped path');
    assert.ok(BigInt(tx.value) > amt, 'value carries a tip on top of the amount');
    assert.ok(BigInt(tx.value) <= p.chain.native.get(A.ACCOUNT.toLowerCase()), 'and still fits the wallet');
    p.close();
  });

  test('a quote the relay will not answer leaves the deposit exactly as it was', async () => {
    const p = await open();                // no quote lane at all: the endpoint 404s
    await unlock(p);
    p.type('pvAmt', '0.001');
    await p.waitFor(() => /you'll hold/.test(p.text('pvPrev')), { label: 'the preview', ...SLOW });
    assert.doesNotMatch(p.text('pvPrev'), /Relay tip/);
    p.click('pvGo');
    await p.waitFor(() => p.chain.sent.length === 1, { label: 'the deposit', ...SLOW });
    assert.equal(String(p.chain.sent[0].to).toLowerCase(), POOL.toLowerCase(), 'no tip path, no new failure');
    assert.equal(BigInt(p.chain.sent[0].value), 10n ** 15n);
    p.close();
  });

  test('settling from this wallet is never tipped', async () => {
    const p = await open();
    quoting(p, 30000000000000n);
    await unlock(p);
    p.select('pvPath', 'self');
    p.type('pvAmt', '0.001');
    await p.waitFor(() => /You settle it from this wallet/.test(p.text('pvPrev')), { label: 'the self-settle preview', ...SLOW });
    assert.ok(p.$('pvTipL').classList.contains('hide'));
    assert.doesNotMatch(p.text('pvPrev'), /Relay tip/);
    p.close();
  });
});

describe('the private form tells you before you press', () => {
  test('a deposit previews the wallet balance, what you will hold, and how long settling takes', async () => {
    const p = await open();
    await unlock(p);
    p.type('pvAmt', '0.01');
    await p.waitFor(() => /you'll hold 0\.01 tETH/.test(p.text('pvPrev')), { label: 'the deposit preview' });
    assert.match(p.text('pvPrev'), /10 ETH in this wallet/);
    assert.match(p.text('pvPrev'), /Settling costs you nothing\./,
      'no tip quoted, so the deposit is free to the depositor');
    assert.match(p.text('pvPrev'), /settles 1–3 min after the deposit confirms/);
    p.type('pvAmt', '11');
    await p.waitFor(() => /more than this wallet holds/.test(p.text('pvPrev')), { label: 'the over-balance note' });
    p.close();
  });

  test('a withdrawal to an L2 previews the fee, what arrives, the timing, and warns when it goes back to this wallet', async () => {
    const p = await open();
    await unlock(p);
    p.select('pvAct', 'out');
    p.select('pvChain', '8453');
    p.type('pvAmt', '0.01');
    await p.waitFor(() => /arrives on Base, usually 4–8 min/.test(p.text('pvPrev')), { label: 'the withdrawal preview' });
    assert.match(p.text('pvPrev'), /Relay fee [\d.]+ tETH · ≈[\d.]+ ETH arrives on Base/);
    assert.match(p.text('pvPrev'), /links it to your deposit/);
    p.type('pvTo', A.OTHER);
    await p.waitFor(() => !/links it to your deposit/.test(p.text('pvPrev')), { label: 'the note to go for a fresh recipient' });
    p.select('pvChain', '4663');
    await p.waitFor(() => /arrives on Robinhood, usually 8–15 min/.test(p.text('pvPrev')), { label: 'Robinhood timing' });
    p.close();
  });

  test('an amount past eight decimals is rounded down to what the pool keeps', async () => {
    const p = await open();
    await unlock(p);
    p.type('pvAmt', '0.0123456789123');
    p.$('pvAmt').dispatchEvent(new p.window.Event('change', { bubbles: true }));
    assert.equal(p.$('pvAmt').value, '0.01234567');
    p.close();
  });

  test('max fills the wallet ETH less gas for a deposit, on the pool grid', async () => {
    const p = await open();
    await unlock(p);
    p.click('pvMax');
    await p.waitFor(() => p.$('pvAmt').value !== '', { label: 'max to fill the amount' });
    const v = p.$('pvAmt').value;
    assert.ok(Number(v) > 9.9 && Number(v) < 10, 'the balance, less a gas reserve: ' + v);
    assert.ok(!/\.\d{9,}/.test(v), 'no more than eight decimals');
    p.close();
  });
});

describe('a payment request opened from a link', () => {
  const REQ = { v: 1, chainBinding: F.wrapOp.chainBinding, assetId: F.ethAssetId, underlying: A.ZERO, ticker: 'cETH',
    amount: F.amountWei, value: F.note.value, cx: F.note.cx, cy: F.note.cy, owner: F.note.owner,
    commit: F.commit, depositId: F.depositId, leaf: F.leaf, memo: F.memo, witness: F.wrapOp };
  const linked = async (req, confirm) => {
    const chain = withPool(new MockChain(), {});
    const p = await loadPage({ chain, hash: 'tacit-invoice=' + Buffer.from(JSON.stringify(req)).toString('base64url') });
    const inner = p.window.fetch;
    p.window.__relayPosts = [];
    p.window.fetch = async (url, init) => {
      if (String(url).includes('/confidential/') && init && init.body) p.window.__relayPosts.push(JSON.parse(init.body));
      return inner(url, init);
    };
    await p.settle();
    assert.equal(p.window.location.hash, '', 'the request leaves the address bar at once');
    assert.match(p.text('stat'), /payment request is waiting/);
    await p.connect();
    if (!p.$('pv').classList.contains('on')) p.click('pv');
    await p.settle();
    p.queueConfirm(confirm);
    p.click('pvGo');
    await p.waitFor(() => /Key unlocked/.test(p.text('pvKey')), { label: 'the key to unlock' });
    return p;
  };

  test('it opens the pay confirmation once the key is unlocked, and pays only on yes', async () => {
    const p = await linked(REQ, true);
    await p.waitFor(() => p.chain.sentTo(POOL).length === 1, { label: 'the payment', timeout: 15000 });
    assert.match(p.asked.confirm.at(-1), /^Pay 0\.01 ETH into this private request/);
    assert.equal(p.chain.sentTo(POOL)[0].data, F.wrapCalldata);
    p.close();
  });

  test('declining the confirmation sends nothing', async () => {
    const p = await linked(REQ, false);
    await p.waitFor(() => /Payment cancelled/.test(p.text('stat')), { label: 'the decline', timeout: 15000 });
    assert.equal(p.chain.sentTo(POOL).length, 0);
    p.close();
  });

  test('a link to a request for another pool is refused before anything is paid', async () => {
    const p = await linked({ ...REQ, chainBinding: '0x' + '12'.repeat(32) }, true);
    await p.waitFor(() => /another pool/.test(p.text('stat')), { label: 'the refusal', timeout: 15000 });
    assert.equal(p.chain.sentTo(POOL).length, 0);
    p.close();
  });
});
