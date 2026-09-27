// The governance panel: the zFi DAO's recent proposals read straight from the
// DAO, voted and executed from the page, and - for a badge holder - proposed
// from it, in the same chat-tagged form the zFi dapp writes and reads.
import { test, describe, after } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { AbiCoder, Interface, keccak256, getCreate2Address } from 'ethers';
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
function dao(chain, { props, msgs, badge = 0n, config = 0n }) {
  chain.answer(DAO, 'c08cc02d', u(props.length))
    .answer(DAO, '31933916', u(msgs.length))
    .answer(DAO, '79502c55', u(config))
    .answer(DAO, '9b644a23', d => u(props[Number(BigInt('0x' + d.slice(10)))].id))
    .answer(DAO, '0d80fefd', d => abi.encode(['string'], [msgs[Number(BigInt('0x' + d.slice(10)))]]))
    .answer(DAO, '3e4f49e6', d => u(props.find(p => p.id === BigInt('0x' + d.slice(10))).state))
    .answer(DAO, '1a32b237', d => { const p = props.find(p => p.id === BigInt('0x' + d.slice(10))); return abi.encode(['uint96', 'uint96', 'uint96'], [p.yes, p.no, 0n]); })
    .answer(RESOLVER, 'f8b1cb3c', abi.encode(['address[]'], [[V1, V2]]))
    .answer(DAO, '9ac498de', d => u(props.find(p => p.id === BigInt('0x' + d.slice(10))).queued ?? 0n))
    .answer(BADGES, '70a08231', d => u(d.slice(-40).toLowerCase() === A.ACCOUNT.slice(2).toLowerCase() ? badge : 0n));
  for (const s of ['56781388', 'ee5b2895', 'ac9650d8']) chain.answer(DAO, s, '0x');
  return chain;
}

async function open(chain) {
  const p = await loadPage({ chain });
  await p.connect();
  await p.settle();
  p.click('footGov');
  await p.waitFor(() => !/Reading/.test(p.text('gvList')), { label: 'the proposals' });
  await p.settle();
  return p;
}
const rows = p => [...p.$('gvList').querySelectorAll('.p')];
const said = row => row.querySelector('span').textContent;
const button = (row, label) => [...row.querySelectorAll('button')].find(b => b.textContent === label);

const real = JSON.parse(REAL.message.match(/<<<PROPOSAL_DATA\n([\s\S]*?)\nPROPOSAL_DATA>>>/)[1]);

describe('the governance panel', () => {
  test('recomputes a real proposal id from its chat record, as the DAO does', () => {
    assert.equal(idOf(real), BigInt(REAL.id), 'the fixture is the real #21 and its real id');
  });

  test('lists recent proposals newest first, described only by records whose hash is theirs', async () => {
    const other = { type: 'PROPOSAL', op: 0, to: A.ACCOUNT, value: '0', data: '0x', nonce: '0x' + '11'.repeat(32), description: 'Pay a contributor' };
    const spoof = { ...other, nonce: '0x' + '22'.repeat(32), description: 'Totally harmless' };
    const props = [
      { id: BigInt(REAL.id), state: 6, yes: 1606200n * 10n ** 18n, no: 0n },
      { id: idOf(other), state: 1, yes: 5n * 10n ** 18n, no: 2n * 10n ** 18n },
      { id: 123456789n, state: 4, yes: 0n, no: 0n },
    ];
    const p = await open(dao(new MockChain(), { props, msgs: [REAL.message, tag(other), tag({ ...spoof, to: A.ACCOUNT })] }));
    const r = rows(p);
    assert.equal(r.length, 3);
    assert.equal(said(r[0]), '#123456789Defeated · 0 Z for · 0 against', 'no record, so no description');
    assert.equal(said(r[1]), 'Pay a contributorVoting · 5 Z for · 2 against');
    assert.match(said(r[2]), /^↑ v0\.2 deployment of zSwap.*Executed · 1,606,200 Z for · 0 against$/, 'a deployNext on the lineage is marked');
    assert.ok(!p.text('gvList').includes('Totally harmless'), 'a record whose hash matches no proposal is never shown');
    assert.ok(!p.visible('gvNew'), 'no badge, no proposing');
    p.close();
  });

  test('votes, queues and executes by the DAO\'s own calls, one press at a time', async () => {
    const pass = { type: 'PROPOSAL', op: 0, to: A.ACCOUNT, value: '1000', data: '0xabcdef', nonce: '0x' + '33'.repeat(32), description: 'Passed thing' };
    const ready = { ...pass, nonce: '0x' + '55'.repeat(32), description: 'Ready thing' };
    const vote = { ...pass, nonce: '0x' + '44'.repeat(32), description: 'Open thing' };
    const chain = dao(new MockChain(), {
      props: [
        { id: idOf(ready), state: 3, yes: 9n, no: 0n, queued: 1n },
        { id: idOf(pass), state: 3, yes: 9n, no: 0n },
        { id: idOf(vote), state: 1, yes: 0n, no: 0n },
      ],
      msgs: [tag(ready), tag(pass), tag(vote)],
    });
    const p = await open(chain);
    const [open1, passed, readied] = rows(p);
    assert.match(said(passed), /Passed/);
    assert.match(said(readied), /^Ready thingReady/, 'passed and past its timelock');
    assert.ok(!button(passed, 'For') && button(open1, 'For') && button(open1, 'Against'));
    assert.ok(button(passed, 'Queue') && !button(passed, 'Execute'), 'the first press only starts the timelock, and says so');
    assert.ok(button(readied, 'Execute'));
    const against = button(open1, 'Against');
    p.click(against);
    assert.ok(against.disabled, 'held while the vote is out');
    await p.waitFor(() => chain.sentTo(DAO).length === 1, { label: 'the vote' });
    assert.equal(chain.lastSent.data, moloch.encodeFunctionData('castVote', [idOf(vote), 0]));
    await p.settle();
    p.click(button(rows(p)[1], 'Queue'));
    await p.waitFor(() => chain.sentTo(DAO).length === 2, { label: 'the queueing' });
    assert.equal(chain.lastSent.data, moloch.encodeFunctionData('executeByVotes', [0, pass.to, 1000n, pass.data, pass.nonce]));
    await p.settle();
    p.click(button(rows(p)[2], 'Execute'));
    await p.waitFor(() => chain.sentTo(DAO).length === 3, { label: 'the execution' });
    assert.equal(chain.lastSent.data, moloch.encodeFunctionData('executeByVotes', [0, ready.to, 1000n, ready.data, ready.nonce]));
    p.close();
  });

  test('a badge holder proposes as the zFi dapp does: the tagged record and the opening, in one multicall', async () => {
    const chain = dao(new MockChain(), { props: [], msgs: [], badge: 1n, config: 3n });
    const p = await open(chain);
    assert.ok(p.visible('gvNew'));
    assert.equal(p.text('gvList'), 'No proposals yet.');
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

  test('deployNext wraps an initcode for the current tip and names the address it will create', async () => {
    const p = await open(dao(new MockChain(), { props: [], msgs: [], badge: 1n }));
    const ic = '0x6080604052' + 'ab'.repeat(40);
    p.type('gvData', ic);
    p.click('gvNb');
    assert.equal(p.$('gvTo').value.toLowerCase(), V2.toLowerCase(), 'the tip the resolver lists last');
    assert.equal(p.$('gvData').value, zswap.encodeFunctionData('deployNext', [ic, '0x' + '00'.repeat(32)]));
    assert.equal(p.$('gvDesc').value.toLowerCase(), `next zswap: deploynext on ${V2}, creating ${getCreate2Address(V2, '0x' + '00'.repeat(32), keccak256(ic))}`.toLowerCase());
    p.close();
  });

  test('actions refuse off Ethereum, where the DAO does not live', async () => {
    const chain = dao(new MockChain({ chainId: '0x2105' }), {
      props: [{ id: idOf(real), state: 1, yes: 0n, no: 0n }], msgs: [REAL.message],
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
    await p.waitFor(() => p.text('gvList') === 'No proposals yet.', { label: 'the proposals' });
    assert.ok(!p.visible('gvNew'), 'nobody to check a badge for yet');
    await p.connect();
    await p.waitFor(() => p.visible('gvNew'), { label: 'the form' });
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

