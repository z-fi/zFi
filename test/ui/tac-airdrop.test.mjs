/**
 * The Tacit TAC airdrop, offered to a connected wallet that is in it.
 *
 * Proofs come from a commit-pinned shard (one file per leading address byte),
 * and nothing in a shard is trusted: the page recomputes the leaf and the path
 * and compares them with the root the contract holds. Only then, and only
 * while the window is open, the contract is unpaused, holds enough TAC and
 * has not seen the claim, does it offer to claim.
 */
import { test, describe, after } from 'node:test';
import assert from 'node:assert/strict';
import { AbiCoder, keccak256, concat } from 'ethers';
import { A, MockChain, loadPage, closeAllPages } from './harness.mjs';

after(closeAllPages);
const coder = AbiCoder.defaultAbiCoder();
const TACAD = '0x4b4cb98d0c836c2783ac46f0078b904dab533ae8';
const TAC = '0xa1313eb9f3a445606d9583bcac3ebeb56a858279';
const ME = A.ACCOUNT.toLowerCase(), AMT = 1234560000000000000n;

const leaf = (i, a, v) => keccak256(keccak256(coder.encode(['uint256', 'address', 'uint256'], [i, a, v])));
const pair = (x, y) => BigInt(x) < BigInt(y) ? keccak256(concat([x, y])) : keccak256(concat([y, x]));
function tree(rows) {
  const leaves = rows.map(([i, a, v]) => leaf(i, a, v));
  const levels = [leaves];
  while (levels.at(-1).length > 1) {
    const l = levels.at(-1), n = [];
    for (let i = 0; i < l.length; i += 2) n.push(i + 1 < l.length ? pair(l[i], l[i + 1]) : l[i]);
    levels.push(n);
  }
  const proof = k => { const p = []; for (let d = 0, i = k; d < levels.length - 1; d++, i >>= 1) { const s = i ^ 1; if (s < levels[d].length) p.push(levels[d][s]); } return p; };
  return { root: levels.at(-1)[0], proof };
}
const ROWS = [[0, '0x' + '11'.repeat(20), 5n], [7, ME, AMT], [2, '0x' + '12'.repeat(20), 9n]];
const T = tree(ROWS);

function chainOf({ claimed = false, deadline = Math.floor(Date.now() / 1e3) + 86400 * 30, paused = false, root = T.root, proof = T.proof(1), chainId } = {}) {
  const chain = new MockChain(chainId ? { chainId } : {});
  chain.setNative(A.ACCOUNT, 10n ** 18n);
  chain.setErc20(TAC, TACAD, 10n ** 24n);
  chain.lanes = { [`/proofs/${ME.slice(2, 4)}.json`]: { root, claims: { [ME]: { index: 7, amount: AMT.toString(), proof } } } };
  const ethCall = chain.ethCall.bind(chain);
  chain.ethCall = (tx, block) => {
    if ((tx.to || '').toLowerCase() === TACAD) {
      const sel = tx.data.slice(2, 10);
      if (sel === '51e75e8b') return root;
      if (sel === '42f81580') return coder.encode(['uint256'], [deadline]);
      if (sel === '5c975abb') return coder.encode(['bool'], [paused]);
      if (sel === '9e34070f') return coder.encode(['bool'], [claimed]);
      if (sel === '2e7ba6ef' || sel === '4f54d47c') return '0x';
    }
    return ethCall(tx, block);
  };
  return chain;
}
const card = p => (p.$('adEl').classList.contains('hide') ? '' : p.text('adEl'));
const open = async (opts, page = {}) => {
  const p = await loadPage({ chain: chainOf(opts), hash: null, ...page });
  await p.connect();
  await p.settle();
  return p;
};

describe('the TAC airdrop card', () => {
  test('offers the claim, and claims to the connected wallet with the exact proof', async () => {
    const p = await open();
    await p.waitFor(() => /1\.23456 TAC airdrop · until/.test(card(p)), { label: 'the card' });
    p.click(p.$('adEl').querySelector('button[data-ad="me"]'));
    await p.waitFor(() => p.chain.sentTo(TACAD).length > 0, { label: 'the claim' });
    const tx = p.chain.sentTo(TACAD).at(-1);
    assert.equal(tx.data.slice(2, 10), '2e7ba6ef', 'claim(uint256,address,uint256,bytes32[])');
    const [i, a, v, pr] = coder.decode(['uint256', 'address', 'uint256', 'bytes32[]'], '0x' + tx.data.slice(10));
    assert.equal(i, 7n); assert.equal(a.toLowerCase(), ME); assert.equal(v, AMT);
    assert.deepEqual([...pr], T.proof(1));
    p.close();
  });

  test('a claim that lands is accepted, then celebrated', async () => {
    const p = await open({}, { chime: true });
    await p.waitFor(() => /TAC airdrop · until/.test(card(p)), { label: 'the card' });
    const quiet = p.window.__chime.voices.length;
    p.click(p.$('adEl').querySelector('button[data-ad="me"]'));
    await p.waitFor(() => p.window.__chime.voices.length >= quiet + 2, { label: 'the claim to sound' });
    assert.deepEqual(p.window.__chime.voices.slice(quiet), [[392, 587.33], [392, 493.88, 587.33, 783.99]]);
    p.close();
  });

  test('claim to… sends to another address through claimTo', async () => {
    const p = await open();
    await p.waitFor(() => /TAC airdrop · until/.test(card(p)), { label: 'the card' });
    p.queuePrompt(A.OTHER);
    p.click(p.$('adEl').querySelector('button[data-ad="to"]'));
    await p.waitFor(() => p.chain.sentTo(TACAD).length > 0, { label: 'the claimTo' });
    const tx = p.chain.sentTo(TACAD).at(-1);
    assert.equal(tx.data.slice(2, 10), '4f54d47c', 'claimTo(uint256,uint256,bytes32[],address)');
    const [i, v, pr, to] = coder.decode(['uint256', 'uint256', 'bytes32[]', 'address'], '0x' + tx.data.slice(10));
    assert.equal(i, 7n); assert.equal(v, AMT); assert.deepEqual([...pr], T.proof(1));
    assert.equal(to.toLowerCase(), A.OTHER.toLowerCase());
    p.close();
  });

  for (const name of ['bob.wei', 'bob.gwei', 'bob.eth']) test(`claim to… takes ${name}, shows where it points, and sends there`, async () => {
    const p = await open();
    if (name.endsWith('.eth')) { p.chain.ensResolver = A.ENSRESOLVER; p.chain.ensNames.set(name, A.OTHER); }
    else p.chain.names.set(name, A.OTHER);
    await p.waitFor(() => /TAC airdrop · until/.test(card(p)), { label: 'the card' });
    p.queuePrompt(name);
    p.queueConfirm(true);
    p.click(p.$('adEl').querySelector('button[data-ad="to"]'));
    await p.waitFor(() => p.chain.sentTo(TACAD).length > 0, { label: 'the claimTo' });
    assert.match(p.asked.confirm.at(-1), new RegExp(name.replace('.', '\\.') + ' → 0x2222'), 'the resolved address is shown first');
    const tx = p.chain.sentTo(TACAD).at(-1);
    assert.equal(tx.data.slice(2, 10), '4f54d47c');
    const [, , , to] = coder.decode(['uint256', 'uint256', 'bytes32[]', 'address'], '0x' + tx.data.slice(10));
    assert.equal(to.toLowerCase(), A.OTHER.toLowerCase(), 'the TAC goes to the name\'s address');
    p.close();
  });

  test('declining the name check sends nothing', async () => {
    const p = await open();
    p.chain.names.set('bob.wei', A.OTHER);
    await p.waitFor(() => /TAC airdrop · until/.test(card(p)), { label: 'the card' });
    p.queuePrompt('bob.wei');
    p.queueConfirm(false);
    p.click(p.$('adEl').querySelector('button[data-ad="to"]'));
    await new Promise(r => setTimeout(r, 400)); await p.settle();
    assert.equal(p.chain.sentTo(TACAD).length, 0);
    p.close();
  });

  test('a name that resolves to nothing is refused', async () => {
    const p = await open();
    await p.waitFor(() => /TAC airdrop · until/.test(card(p)), { label: 'the card' });
    p.queuePrompt('nobody.wei');
    p.click(p.$('adEl').querySelector('button[data-ad="to"]'));
    await p.waitFor(() => /not an address or a registered name/.test(p.text('stat')), { label: 'the refusal' });
    assert.equal(p.chain.sentTo(TACAD).length, 0);
    p.close();
  });

  test('shows on the swap view only, like the other cards', async () => {
    const p = await open();
    await p.waitFor(() => /TAC airdrop · until/.test(card(p)), { label: 'the card' });
    p.click('pv');
    await p.settle();
    assert.equal(card(p), '', 'not over the private panel');
    p.click('pv');
    await p.settle();
    assert.match(card(p), /TAC airdrop · until/, 'back on the swap view');
    p.close();
  });

  test('a shard that does not prove against the contract root is ignored', async () => {
    const p = await open({ proof: T.proof(0) });
    await new Promise(r => setTimeout(r, 400)); await p.settle();
    assert.equal(card(p), '', 'nothing offered on an unproven entry');
    p.close();
  });

  test('an allocation already claimed, by anyone, says so and offers nothing', async () => {
    const p = await open({ claimed: true });
    await p.waitFor(() => /Tacit airdrop claimed/.test(card(p)), { label: 'claimed' });
    assert.equal(p.$('adEl').querySelectorAll('button').length, 0);
    p.close();
  });

  test('after the deadline the proofs are not even fetched', async () => {
    const p = await open({ deadline: Math.floor(Date.now() / 1e3) - 60 });
    await new Promise(r => setTimeout(r, 400)); await p.settle();
    assert.equal(card(p), '');
    assert.ok(!(p.chain.httpLog || []).some(r => /\/proofs\//.test(r.url)), 'no shard request');
    p.close();
  });

  test('is Ethereum only', async () => {
    const p = await open({ chainId: '0x2105' });
    await new Promise(r => setTimeout(r, 400)); await p.settle();
    assert.equal(card(p), '');
    p.close();
  });
});
