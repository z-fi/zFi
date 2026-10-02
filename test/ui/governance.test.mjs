// The governance panel: the zFi DAO's recent proposals read straight from the
// DAO, voted and executed from the page, and - for a badge holder - proposed
// from it, in the same chat-tagged form the zFi dapp writes and reads.
import { test, describe, after } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { AbiCoder, Interface, keccak256, getCreate2Address, getAddress } from 'ethers';
import { MockChain, loadPage, closeAllPages, A } from './harness.mjs';

after(closeAllPages);

const DAO = '0x5E58BA0e06ED0F5558f83bE732a4b899a674053E';
const RESOLVER = '0x000000E7DAD6128683D1fb415e80B30c23dAb7AC';
const BADGES = '0x2809A7EB62D5a50e40153080F548c306Db01c221';
const V1 = '0x00000095643CFfA7D9fae407a84dfCB6406456c6';
const V2 = '0xe686952842627A2cf81DF42CCaD54ef98046DB8D';
const REAL = JSON.parse(fs.readFileSync(new URL('../fixtures/zfi-dao-proposal-21.json', import.meta.url), 'utf8'));
const abi = AbiCoder.defaultAbiCoder();
const moloch = new Interface([
  'function castVote(uint256 id, uint8 support)',
  'function executeByVotes(uint8 op, address to, uint256 value, bytes data, bytes32 nonce)',
  'function multicall(bytes[] data)',
  'function chat(string message)',
  'function openProposal(uint256 id)',
]);
const zswap = new Interface(['function deployNext(bytes initcode, bytes32 salt)']);
const idOf = (d, config = 0n) => BigInt(keccak256(abi.encode(
  ['address', 'uint8', 'address', 'uint256', 'bytes32', 'bytes32', 'uint256'],
  [DAO, d.op, d.to, BigInt(d.value), keccak256(d.data), d.nonce, config])));
const tag = d => `<<<PROPOSAL_DATA\n${JSON.stringify(d, null, 2)}\nPROPOSAL_DATA>>>`;
const u = v => abi.encode(['uint256'], [v]);

// A DAO whose recent proposals are `props` (oldest first) and whose chat is `msgs`.
const NOW = Math.floor(Date.now() / 1000), DAY = 86400;
const find = (props, d) => props.find(p => p.id === BigInt('0x' + d.slice(10, 74)));
function dao(chain, { props, msgs, badge = 0n, config = 0n, versions = [V1, V2], current = V2, born = 0n, quorumBps = 1000n }) {
  chain.answer(DAO, 'c08cc02d', u(props.length))
    .answer(DAO, '31933916', u(msgs.length))
    .answer(DAO, '79502c55', u(config))
    .answer(DAO, '9b644a23', d => u(props[Number(BigInt('0x' + d.slice(10)))].id))
    .answer(DAO, '0d80fefd', d => abi.encode(['string'], [msgs[Number(BigInt('0x' + d.slice(10)))]]))
    .answer(DAO, '3e4f49e6', d => u(props.find(p => p.id === BigInt('0x' + d.slice(10))).state))
    .answer(DAO, '1a32b237', d => { const p = props.find(p => p.id === BigInt('0x' + d.slice(10))); return abi.encode(['uint96', 'uint96', 'uint96'], [p.yes, p.no, 0n]); })
    .answer(RESOLVER, 'f8b1cb3c', abi.encode(['address[]'], [versions]))
    .answer(RESOLVER, '9fa6a6e3', abi.encode(['address'], [current]))
    .answer(versions.at(-2), '451aae60', u(born))
    .answer(DAO, '9ac498de', d => u(find(props, d).queued ?? 0n))
    .answer(DAO, '50a1676e', d => u(find(props, d).created ?? 1n))
    .answer(DAO, 'ab38c38a', d => u(find(props, d).supply ?? 0n))
    .answer(DAO, '083ce0cf', d => abi.encode(['address'], [find(props, d).by ?? A.ACCOUNT]))
    .answer(DAO, '43859632', d => u(d.slice(-40).toLowerCase() === A.ACCOUNT.slice(2).toLowerCase() ? find(props, d).mine ?? 0n : 0n))
    .answer(DAO, '59a342d6', u(DAY))
    .answer(DAO, 'eef09bad', u(DAY))
    .answer(DAO, 'cd2ddd0c', u(quorumBps))
    .answer(BADGES, '70a08231', d => u(d.slice(-40).toLowerCase() === A.ACCOUNT.slice(2).toLowerCase() ? badge : 0n));
  for (const s of ['56781388', 'ee5b2895', 'ac9650d8']) chain.answer(DAO, s, '0x');
  return chain;
}

async function open(chain) {
  const p = await loadPage({ chain });
  await p.connect();
  await p.settle();
  p.click('footGov');
  await p.waitFor(() => /versions/.test(p.text('gvList')), { label: 'the proposals' });
  await p.settle();
  return p;
}
const rows = p => [...p.$('gvList').querySelectorAll('.p')];
const title = row => row.querySelector('b').textContent;
const said = row => row.querySelector('span i').textContent;
const head = p => p.$('gvList').querySelector('p').textContent;
const button = (row, label) => [...row.querySelectorAll('button')].find(b => b.textContent === label);

const real = JSON.parse(REAL.message.match(/<<<PROPOSAL_DATA\n([\s\S]*?)\nPROPOSAL_DATA>>>/)[1]);

describe('the governance panel', () => {
  test('recomputes a real proposal id from its chat record, as the DAO does', () => {
    assert.equal(idOf(real), BigInt(REAL.id), 'the fixture is the real #21 and its real id');
  });

  test('lists recent proposals newest first, numbered, described only by records whose hash is theirs', async () => {
    const other = { type: 'PROPOSAL', op: 0, to: A.ACCOUNT, value: '0', data: '0x', nonce: '0x' + '11'.repeat(32), description: 'Pay a contributor\nwith the details below' };
    const spoof = { ...other, nonce: '0x' + '22'.repeat(32), description: 'Totally harmless' };
    const props = [
      { id: BigInt(REAL.id), state: 6, yes: 1606200n * 10n ** 18n, no: 0n },
      { id: idOf(other), state: 1, yes: 5n * 10n ** 18n, no: 2n * 10n ** 18n, created: BigInt(NOW - 3000), supply: 100n * 10n ** 18n },
      { id: 123456789n, state: 4, yes: 0n, no: 0n },
    ];
    const p = await open(dao(new MockChain(), { props, msgs: [REAL.message, tag(other), tag({ ...spoof, to: A.ACCOUNT })] }));
    const r = rows(p);
    assert.equal(r.length, 3);
    assert.equal(title(r[0]), '#3 no record in DAO chat');
    assert.equal(said(r[0]), 'Defeated · 0 Z for · 0 against');
    assert.equal(title(r[1]), '▸ #2 Pay a contributor');
    assert.equal(said(r[1]), 'Voting · ends in 23h · 5 Z for · 2 against · quorum 70%', '7 of the 10 Z quorum');
    assert.match(title(r[2]), /^▸ #1 ↑ v0\.2 deployment of zSwap/, 'a deployNext on the lineage is marked');
    assert.equal(said(r[2]), 'Executed · 1,606,200 Z for · 0 against');
    assert.ok(!p.text('gvList').includes('Totally harmless'), 'a record whose hash matches no proposal is never shown');
    assert.ok(!p.visible('gvNew'), 'no badge, no proposing');
    p.close();
  });

  test('a title opens the whole proposal: the rest of its text, who proposed it, and the call word by word', async () => {
    const pay = { type: 'PROPOSAL', op: 0, to: A.ACCOUNT, value: '1500000000000000000', data: '0xa9059cbb' + '11'.repeat(32) + '22'.repeat(32), nonce: '0x' + '12'.repeat(32), description: 'Pay a contributor\nfor the audit' };
    const by = getAddress('0x1c0aa8ccd568d90d61659f060d1bfb1e6f855a20');
    const p = await open(dao(new MockChain(), { props: [{ id: idOf(pay), state: 6, yes: 1n, no: 0n, by }], msgs: [tag(pay)] }));
    const r = rows(p)[0], more = r.querySelector('i.dlgm');
    assert.ok(more.classList.contains('hide'));
    assert.equal(title(r), '▸ #1 Pay a contributor');
    p.click(r.querySelector('b'));
    assert.ok(!more.classList.contains('hide'));
    assert.equal(title(r), '▾ #1 Pay a contributor');
    const links = [...more.querySelectorAll('a')].map(a => [a.textContent, a.href]);
    const to = getAddress(A.ACCOUNT);
    assert.deepEqual(links, [[to, `https://etherscan.io/address/${to}`], [by, `https://etherscan.io/address/${by}`]]);
    assert.equal(more.querySelector('code').textContent, ['0xa9059cbb', '11'.repeat(32), '22'.repeat(32)].join('\n'), 'the calldata, one ABI word a line');
    assert.equal(more.textContent, `for the audit\n→ ${to} · 1.5 ETH\nproposed by ${by}` + more.querySelector('code').textContent, 'the title is not repeated');
    p.click(r.querySelector('b'));
    assert.ok(more.classList.contains('hide'));
    p.close();
  });

  test('votes while the window is open, even once it is passing, and queues and executes by the DAO\'s own calls', async () => {
    const mk = (n, description) => ({ type: 'PROPOSAL', op: 0, to: A.ACCOUNT, value: '1000', data: '0xabcdef', nonce: '0x' + n.repeat(32), description });
    const ready = mk('55', 'Ready thing'), pass = mk('33', 'Passed thing'), passing = mk('88', 'Passing thing'), vote = mk('44', 'Open thing'), lock = mk('99', 'Locked thing');
    const chain = dao(new MockChain(), {
      props: [
        { id: idOf(lock), state: 2, yes: 9n, no: 0n, queued: BigInt(NOW - 3000) },
        { id: idOf(ready), state: 3, yes: 9n, no: 0n, queued: BigInt(NOW - 2 * DAY) },
        { id: idOf(pass), state: 3, yes: 9n, no: 0n },
        { id: idOf(passing), state: 3, yes: 9n, no: 0n, created: BigInt(NOW - 60), mine: 2n },
        { id: idOf(vote), state: 1, yes: 0n, no: 0n, created: BigInt(NOW - 60) },
      ],
      msgs: [tag(lock), tag(ready), tag(pass), tag(passing), tag(vote)],
    });
    const p = await open(chain);
    const [open1, passing1, passed, readied, locked] = rows(p);
    assert.match(said(passing1), /^Passing · ends in 23h · .* · you voted for$/);
    assert.ok(button(passing1, 'For') && button(passing1, 'Against') && button(passing1, 'Queue'), 'passing but still open: vote, or queue it');
    assert.equal(said(passed).split(' · ')[0], 'Passed');
    assert.ok(!button(passed, 'For') && button(passed, 'Queue') && !button(passed, 'Execute'), 'the first press only starts the timelock, and says so');
    assert.equal(said(readied).split(' · ')[0], 'Ready');
    assert.ok(button(readied, 'Execute'));
    assert.match(said(locked), /^Timelock · ready in 23h · /);
    assert.equal(locked.querySelectorAll('button').length, 0);
    const against = button(open1, 'Against');
    p.click(against);
    assert.ok(against.disabled, 'held while the vote is out');
    await p.waitFor(() => chain.sentTo(DAO).length === 1, { label: 'the vote' });
    assert.equal(chain.lastSent.data, moloch.encodeFunctionData('castVote', [idOf(vote), 0]));
    await p.settle();
    assert.equal(rows(p).length, 5, 'the list stays up while it refreshes');
    assert.ok(!/Reading/.test(p.text('gvList')));
    p.click(button(rows(p)[2], 'Queue'));
    await p.waitFor(() => chain.sentTo(DAO).length === 2, { label: 'the queueing' });
    assert.equal(chain.lastSent.data, moloch.encodeFunctionData('executeByVotes', [0, pass.to, 1000n, pass.data, pass.nonce]));
    await p.settle();
    p.click(button(rows(p)[3], 'Execute'));
    await p.waitFor(() => chain.sentTo(DAO).length === 3, { label: 'the execution' });
    assert.equal(chain.lastSent.data, moloch.encodeFunctionData('executeByVotes', [0, ready.to, 1000n, ready.data, ready.nonce]));
    p.close();
  });

  test('a badge holder proposes as the zFi dapp does: the tagged record and the opening, in one multicall', async () => {
    const chain = dao(new MockChain(), { props: [], msgs: [], badge: 1n, config: 3n });
    const p = await open(chain);
    assert.ok(p.visible('gvNew'));
    assert.match(head(p), /no proposals yet$/);
    p.type('gvTo', A.ACCOUNT); p.type('gvVal', '0.5'); p.type('gvData', '0x1234'); p.type('gvDesc', 'Fund the thing\nwith detail');
    p.click('gvGo');
    await p.waitFor(() => chain.sentTo(DAO).length === 1, { label: 'the proposal' });
    const [calls] = moloch.decodeFunctionData('multicall', chain.lastSent.data);
    const [msg] = moloch.decodeFunctionData('chat', calls[0]);
    const d = JSON.parse(msg.match(/^<<<PROPOSAL_DATA\n([\s\S]*)\nPROPOSAL_DATA>>>$/)[1]);
    assert.deepEqual(Object.keys(d), ['type', 'op', 'to', 'value', 'data', 'nonce', 'description'], 'the zFi dapp\'s field order');
    assert.deepEqual([d.op, d.to, d.value, d.data, d.description], [0, A.ACCOUNT, '500000000000000000', '0x1234', 'Fund the thing\nwith detail']);
    assert.match(d.nonce, /^0x[0-9a-f]{64}$/);
    assert.equal(calls[1], moloch.encodeFunctionData('openProposal', [idOf(d, 3n)]), 'opens the id of exactly that record, under the live config');
    await p.settle();
    assert.deepEqual(['gvDesc', 'gvTo', 'gvVal', 'gvData'].map(i => p.$(i).value), ['', '', '', ''], 'a sent proposal clears the form');
    p.close();
  });

  test('the advanced link turns initcode into the tip\'s deployNext, dry-runs it as the DAO, and never wraps twice', async () => {
    const ic = '0x6080604052' + 'ab'.repeat(40);
    const next = getCreate2Address(V2, '0x' + '00'.repeat(32), keccak256(ic));
    const chain = dao(new MockChain(), { props: [], msgs: [], badge: 1n });
    chain.answer(V2, '48215787', abi.encode(['address'], [next]));
    const p = await open(chain);
    assert.equal(p.$('gvNb').tagName, 'A', 'a quiet link, not a second primary button');
    p.click('gvNb');
    assert.match(p.text('gvS'), /initcode into Calldata first/);
    p.type('gvData', ic);
    p.click('gvNb');
    const wrapped = zswap.encodeFunctionData('deployNext', [ic, '0x' + '00'.repeat(32)]);
    assert.equal(p.$('gvTo').value.toLowerCase(), V2.toLowerCase(), 'the tip the resolver lists last');
    assert.equal(p.$('gvData').value, wrapped);
    assert.equal(p.$('gvDesc').value.toLowerCase(), `next zswap: deploynext on ${V2}, creating ${next}`.toLowerCase());
    await p.waitFor(() => /As the DAO/.test(p.text('gvS')), { label: 'the dry run' });
    assert.equal(p.text('gvS'), `As the DAO, this would create ${next.slice(0, 6)}…${next.slice(-4)}`, 'tried as the DAO before anyone proposes it');
    p.click('gvNb');
    assert.equal(p.$('gvData').value, wrapped, 'a second press does not wrap the call again');
    assert.match(p.text('gvS'), /initcode into Calldata first/);
    p.close();
  });

  test('actions refuse off Ethereum, where the DAO does not live', async () => {
    const chain = dao(new MockChain({ chainId: '0x2105' }), {
      props: [{ id: idOf(real), state: 1, yes: 0n, no: 0n, created: BigInt(NOW - 60) }], msgs: [REAL.message],
    });
    const p = await loadPage({ chain });
    await p.settle();
    p.click('footGov');
    await p.waitFor(() => rows(p).length === 1, { label: 'read from Ethereum all the same' });
    p.click(button(rows(p)[0], 'For'));
    await p.waitFor(() => /Ethereum/.test(p.text('gvS')), { label: 'the refusal' });
    assert.equal(chain.sentTo(DAO).length, 0);
    p.close();
  });

  test('connecting with the panel open offers a badge holder the form', async () => {
    const chain = dao(new MockChain(), { props: [], msgs: [], badge: 1n });
    const p = await loadPage({ chain });
    await p.settle();
    p.click('footGov');
    await p.waitFor(() => /no proposals yet$/.test(p.text('gvList')), { label: 'the proposals' });
    assert.ok(!p.visible('gvNew'), 'nobody to check a badge for yet');
    await p.connect();
    await p.waitFor(() => p.visible('gvNew'), { label: 'the form' });
    p.close();
  });

  test('says how many versions exist, which one the name serves, and when a newer one takes over', async () => {
    const p = await open(dao(new MockChain(), { props: [], msgs: [] }));
    assert.equal(head(p), '2 versions · the name serves 0xe686…DB8D · no proposals yet');
    assert.equal(p.$('gvList').querySelector('p a').href, `https://etherscan.io/address/${V2}#code`, 'the served version links to its code');
    p.close();
    const V3 = getAddress('0x53859d60b1c4e122286861705032bca545a0e274');
    const q = await open(dao(new MockChain(), { props: [], msgs: [], versions: [V1, V2, V3], born: 1_800_000_000n }));
    const when = new Date((1_800_000_000 + 259200) * 1e3).toLocaleDateString();
    assert.equal(head(q), `3 versions · the name serves 0xe686…DB8D · ${V3.slice(0, 6)}…${V3.slice(-4)} from ${when} · no proposals yet`);
    q.close();
  });

  test('an upgrade still in play is dry-run as the DAO: what it would create, or why it would fail', async () => {
    const up = { type: 'PROPOSAL', op: 0, to: V2, value: '0', data: '0x48215787' + '00'.repeat(96), nonce: '0x' + '66'.repeat(32), description: 'Next zSwap' };
    const V3 = getAddress('0x53859d60b1c4e122286861705032bca545a0e274');
    const props = [{ id: idOf(up), state: 1, yes: 0n, no: 0n, created: BigInt(NOW - 60) }];
    const chain = dao(new MockChain(), { props, msgs: [tag(up)] });
    chain.answer(V2, '48215787', abi.encode(['address'], [V3]));
    const p = await open(chain);
    await p.waitFor(() => /would/.test(said(rows(p)[0])), { label: 'the dry run' });
    assert.equal(said(rows(p)[0]), `Voting · ends in 23h · 0 Z for · 0 against · would create ${V3.slice(0, 6)}…${V3.slice(-4)}`);
    assert.ok(chain.calls.some(c => c.to === V2.toLowerCase() && c.selector === '48215787'), 'asked the tip itself');
    p.close();
    const bad = dao(new MockChain(), { props, msgs: [tag(up)] });
    bad.revertOn(V2, '48215787', { data: '0xa5c84399' });
    const q = await open(bad);
    await q.waitFor(() => /would/.test(said(rows(q)[0])), { label: 'the dry run' });
    assert.match(said(rows(q)[0]), /would fail: not a successor of that version$/);
    q.close();
  });

  test('a refusal from the DAO is said in its own words', async () => {
    const vote = { type: 'PROPOSAL', op: 0, to: A.ACCOUNT, value: '0', data: '0x', nonce: '0x' + '77'.repeat(32), description: 'Open thing' };
    const chain = dao(new MockChain(), { props: [{ id: idOf(vote), state: 1, yes: 0n, no: 0n, created: BigInt(NOW - 60) }], msgs: [tag(vote)] });
    chain.answers.delete(DAO.toLowerCase() + ':56781388');
    chain.revertOn(DAO, '56781388', { data: '0x7c9a1cf9' });
    const p = await open(chain);
    p.click(button(rows(p)[0], 'For'));
    await p.waitFor(() => p.text('gvS'), { label: 'the refusal' });
    assert.equal(p.text('gvS'), 'Already voted.');
    assert.equal(chain.sentTo(DAO).length, 0);
    p.close();
  });

  test('hides from its own top, and shares the space with how it works rather than stacking under it', async () => {
    const p = await open(dao(new MockChain(), { props: [], msgs: [] }));
    p.click('gvX');
    assert.ok(!p.visible('gvPanel'));
    assert.equal(p.text('footGov'), 'governance');
    p.click('footDoc');
    assert.ok(p.visible('docPanel'));
    p.click('footGov');
    assert.ok(p.visible('gvPanel') && !p.visible('docPanel'), 'governance closes the docs');
    assert.equal(p.text('footDoc'), 'how it works');
    p.click('footDoc');
    assert.ok(p.visible('docPanel') && !p.visible('gvPanel'), 'and the docs close governance');
    assert.equal(p.text('footGov'), 'governance');
    await p.settle();
    p.close();
  });

  test('the corner menu opens the panel in the page', async () => {
    const p = await open(dao(new MockChain(), { props: [], msgs: [] }));
    p.click('footGov');
    assert.ok(!p.visible('gvPanel'));
    assert.equal(p.text('footGov'), 'governance');
    p.click('logoLink');
    await p.waitFor(() => p.visible('wkWrap'), { label: 'the menu' });
    p.click([...p.$('wkList').querySelectorAll('button.tkr')].find(b => b.textContent.startsWith('zFi DAO')));
    await p.waitFor(() => p.visible('gvPanel'), { label: 'the panel' });
    assert.equal(p.text('footGov'), 'hide');
    p.close();
  });
});
