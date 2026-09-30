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
      if (sel === '2e7ba6ef' || sel === '4f54d47c' || sel === 'ad8b9781') return '0x';
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
test('a shielded claim the wallet sent but then errored on keeps its note', async () => {
  const p = await open();
  await p.waitFor(() => /TAC airdrop · until/.test(card(p)), { label: 'the card' });
  const TAC_AS = '0xf0bbe868af10c6c67652a99709bf32048d1aa7194efe3e9a1ef1bde43f94762b';
  p.chain.answer('0x000000000ed1eabd231be41d93b719056f7febfc', '7da9874f', '0x' + '0'.repeat(64));
  p.window.eval(`cpUse(${JSON.stringify('0x' + '11'.repeat(32))});cpAssets=[{id:"${TAC_AS}",tok:"${TAC}",sym:"cTAC",pub:"TAC",dec:18,scale:10n**10n,icon:""}]`);
  const d = p.chain.dispatch.bind(p.chain);
  p.chain.dispatch = async (m, a) => {
    if (m === 'eth_getTransactionCount') return '0x' + p.chain.sent.length.toString(16);
    if (m === 'eth_sendTransaction') { await d(m, a); throw Object.assign(new Error('RPC Internal error'), { code: -32603 }); }
    return d(m, a);
  };
  p.click(p.$('adEl').querySelector('button[data-ad="sh"]'));
  await p.waitFor(() => /pending/.test(p.text('stat')), { label: 'the warning', timeout: 20000 });
  console.log('STAT:', p.text('stat'), '| sent:', p.chain.sentTo(TACAD).length);
  const n = JSON.parse(p.window.eval(`JSON.stringify(cpNotes.filter(n=>n.a==="${TAC_AS}"))`));
  assert.equal(n.length, 1, 'the claim went out, so its note is kept');
  p.close();
});
