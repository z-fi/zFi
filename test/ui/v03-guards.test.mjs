/**
 * Behaviour the v0.3 page must keep, across the swap, send, launch, token list
 * and private bridge surfaces. Each test drives the page the way a user would
 * and asserts on what reaches the wallet or the screen.
 */
import { test, describe, after } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { AbiCoder, keccak256, concat } from 'ethers';
import {
  A, SEL, MockChain, loadPage, closeAllPages, fixedRateQuoter, encodeSingleHop, word, wordAddr,
} from './harness.mjs';

after(closeAllPages);

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..');
const F = JSON.parse(fs.readFileSync(path.join(ROOT, 'test', 'fixtures', 'confidential.json'), 'utf8'));
const coder = AbiCoder.defaultAbiCoder();
const ETH = 10n ** 18n;
const BASE = '0x2105';
const u256 = v => BigInt(v).toString(16).padStart(64, '0');
const addrWord = a => a.replace(/^0x/, '').toLowerCase().padStart(64, '0');
const wait = (p, ms) => new Promise(r => p.window.setTimeout(r, ms));
const sentTxs = chain => chain.log.filter(r => r.method === 'eth_sendTransaction');

// ---------------------------------------------------------------- fixtures
const registryRow = (s, a, o = {}) => ({
  i: '1', c: 1, k: 'eip155', p: 'ERC-20', x: true, o: false, f: false,
  a, n: `${s} Token`, s, d: 18, t: '#888', r: 1, u: '', au: '', l: '', desc: '', e: [], v: true, ...o,
});

// The confidential pool, as the private-bridge suite serves it.
const POOL = F.pool, ROUTER = F.router, IMPL = F.executorImpl;
const PV = {
  IMPL: '93228617', ASSETS: '9fda5b66', NEXT: '0be4f422', DEPOSIT: '7da9874f', WRAP: '859a9cee',
  OTHER: '7f46ddb2', BRIDGE: 'e78cea92', ESCROW: '2bf0cda2', ACTIVATE: '1699fd5b', RECLAIM: '02edf635',
  EXIT: 'acad0634', SUBFEE: 'a66b327d', SETTLE: '717fd7f2',
};
const T_LEAVES = keccak256(Buffer.from('LeavesInserted(uint256,bytes32[],bytes[])'));
const T_WRAP = keccak256(Buffer.from('Wrap(bytes32,bytes32,uint256)'));
const BASE_BRIDGE = '0x3154Cf16ccdb4C6d922629664174b904d80F2C35';
const RH_INBOX = '0x1A07cc4BD17E0118BdB54D70990D2158AbAD7a2D';
const RELAY = 'api.tacit.finance';
const INIT_HASH = keccak256('0x602d5f8160095f39f35f5f365f5f37365f73' + IMPL.slice(2).toLowerCase()
  + '5af43d5f5f3e6029573d5ffd5b3d5ff3');
// escrowAddressFor(recipe) takes the recipe alone, so its salt is the hash of the call's arguments.
const escrowForCall = data => '0x' + keccak256(concat(['0xff', ROUTER, keccak256('0x' + data.slice(10)), INIT_HASH])).slice(26);

function withPool(chain) {
  chain.blockNumber = '0x18b64a3';
  chain.gasPrice = 10n ** 8n;
  chain.setNative(A.ACCOUNT, 10n * ETH);
  chain.answer(ROUTER, PV.IMPL, '0x' + addrWord(IMPL));
  chain.answer(POOL, PV.ASSETS, '0x' + u256(1) + u256(0) + u256(10n ** 10n) + F.ethAssetId.slice(2) + u256(0) + u256(18));
  chain.answer(POOL, PV.NEXT, () => '0x' + u256(chain.nextLeaf ?? 0));
  chain.answer(POOL, PV.DEPOSIT, '0x' + u256(0));
  for (const s of [PV.WRAP, PV.ACTIVATE, PV.RECLAIM, PV.EXIT]) chain.answer(ROUTER, s, '0x');
  chain.answer(POOL, PV.SETTLE, '0x');
  chain.answer(BASE_BRIDGE, PV.OTHER, '0x' + addrWord('0x4200000000000000000000000000000000000010'));
  chain.answer(RH_INBOX, PV.BRIDGE, '0x' + addrWord('0xDf8755334ce7A73cCF6b581C02eA649AE3E864b3'));
  chain.answer(RH_INBOX, PV.SUBFEE, '0x' + u256(F.robinhood.sub));
  chain.answer(ROUTER, PV.ESCROW, data => '0x' + addrWord(escrowForCall(data)));
  chain.relay = { status: { status: 'pending' } };
  chain.lanes = {};
  Object.defineProperty(chain.lanes, RELAY + '/confidential/submit', {
    enumerable: true, get: () => ({ ok: true, jobId: '0xjob' + Date.now(), status: 'pending' }),
  });
  Object.defineProperty(chain.lanes, RELAY + '/confidential/status', {
    enumerable: true, get: () => chain.relay.status,
  });
  return chain;
}

const wrapLog = (id, amount) => ({
  address: POOL, blockNumber: '0x18b649f', logIndex: '0x0',
  topics: [T_WRAP, id, F.ethAssetId], data: '0x' + u256(amount),
});
const leavesLog = (first, leaves, memos) => ({
  address: POOL, blockNumber: '0x18b64a0', logIndex: '0x0',
  topics: [T_LEAVES, '0x' + u256(first)],
  data: coder.encode(['bytes32[]', 'bytes[]'], [leaves, memos]),
});
const advance = p => { p.chain.blockNumber = '0x' + (BigInt(p.chain.blockNumber) + 5n).toString(16); };
const poke = p => p.doc.dispatchEvent(new p.window.Event('visibilitychange'));

async function pvOpen({ storage, prep } = {}) {
  const chain = withPool(new MockChain());
  const p = await loadPage({ chain, storage });
  const inner = p.window.fetch;
  p.window.__relayPosts = [];
  p.window.fetch = async (url, init) => {
    if (String(url).includes('/confidential/') && init && init.body) p.window.__relayPosts.push(JSON.parse(init.body));
    return inner(url, init);
  };
  await p.connect();
  if (prep) await prep(p);
  p.click('pv');
  await p.settle();
  return p;
}
async function pvUnlock(p) {
  p.click('pvGo');
  await p.waitFor(() => /Key unlocked/.test(p.text('pvKey')), { label: 'the key to unlock' });
}
async function pvDeposit(p) {
  p.type('pvAmt', '0.01');
  p.click('pvGo');
  await p.waitFor(() => p.chain.sentTo(ROUTER).length === 1, { label: 'the deposit to be sent' });
  await p.waitFor(() => p.window.__relayPosts.length === 1, { label: 'the wrap to reach the relay' });
}
function pvSettle(p) {
  p.chain.relay.status = { status: 'settled', txHash: '0x' + 'aa'.repeat(32) };
  p.chain.logs.push(wrapLog(F.depositId, F.amountWei));
  p.chain.logs.push(leavesLog(0, [F.leaf, F.otherLeaf], [F.memo, '0x' + '11'.repeat(169)]));
  p.chain.nextLeaf = 2;
  advance(p);
}
const notesKey = store => Object.keys(store).find(k => k.startsWith('zswap:cpn:'));

// ------------------------------------------------------------------- tests
describe('the wallet is checked where a transaction leaves the page', () => {
  test('a send waits for the wallet to be on the page\'s chain, whatever path it takes', async () => {
    const COIN = '0x00000000000000000000000000000000000c0a01';
    const chain = new MockChain();
    chain.registry = [registryRow('ETH', A.ZERO, { p: 'Native' }), registryRow('ZCAT', COIN), registryRow('USDC', A.USDC, { d: 6 })];
    chain.conviction = [1, 2, 3];
    chain.setNative(A.ACCOUNT, 10n * ETH);
    chain.quoteHandler = fixedRateQuoter({ rate: 3000n * ETH });
    chain.setLaunchFees({ [COIN]: { owed0: ETH / 2n, owed1: 1000n * ETH } });
    const p = await loadPage({ chain, hash: null });
    await p.connect({ pin: false });
    p.select('toSel', String([...p.$('toSel').options].findIndex(o => o.textContent === 'ZCAT')));
    await p.settle();
    assert.ok(!p.$('fcEl').classList.contains('hide'), 'the fee line is offered');
    // The wallet answers for Base from here on; the page is still on Ethereum.
    chain.chainId = BASE;
    p.$('fcGo').click();
    await p.waitFor(() => /Switch your wallet|Fees sent|Error/.test(p.text('stat')) || sentTxs(chain).length,
      { label: 'the collect to finish' });
    await p.settle();
    assert.equal(sentTxs(chain).length, 0, 'nothing reaches eth_sendTransaction while the wallet is on another chain');
    assert.match(p.text('stat'), /Switch your wallet to Ethereum/);
    p.close();
  });
});

describe('the launch creator is held to the recipient rules', () => {
  for (const [kind, name] of [['a lookalike letter', 'vit\u0430lik.eth'], ['a zero-width character', 'vita\u200blik.eth']]) {
    test(`a creator name with ${kind} is refused, and nothing is sent`, async () => {
      const chain = new MockChain();
      chain.setNative(A.ACCOUNT, 10n ** 19n);
      chain.ensResolver = A.ENSRESOLVER;
      chain.ensNames.set(name, A.OTHER);
      const p = await loadPage({ chain });
      await p.connect();
      p.click('ln');
      p.type('lnName', 'A');
      p.type('lnSym', 'X');
      p.type('lnSupply', '1000000000');
      p.type('rc', name);
      p.click('lnGo');
      await p.waitFor(() => /cannot resolve|not registered|is live|Error/.test(p.text('stat')) || p.chain.sent.length,
        { label: 'the launch to finish' });
      await p.settle();
      assert.equal(p.chain.sent.length, 0, 'no launch is sent for a name the page cannot resolve safely');
      assert.match(p.text('stat'), /characters this page cannot resolve/, 'the refusal matches the Send tab');
      p.close();
    });
  }
});

describe('tokens that are not on zList say so', () => {
  const MOON = '0x7777777777777777777777777777777777777777';

  test('a token imported by a deep link is listed under an Imported heading', async () => {
    const chain = new MockChain();
    chain.setToken(MOON, { symbol: 'MOON', decimals: 18, name: 'Moon' });
    const p = await loadPage({ chain, hash: `token=ETH&out=${MOON}` });
    await p.waitFor(() => [...p.$('toSel').options].some(o => o.textContent === 'MOON'), { label: 'the import' });
    await p.settle();
    for (const which of ['fromSel', 'toSel']) {
      const opt = [...p.$(which).options].find(o => o.textContent === 'MOON');
      assert.equal(opt.parentElement.tagName, 'OPTGROUP', `${which}: an imported token sits in a group of its own`);
      assert.equal(opt.parentElement.label, 'Imported — not on zList');
    }
    p.close();
  });

  test('a book order in an imported token carries the unverified tag', async () => {
    const chain = new MockChain();
    chain.setNative(A.ACCOUNT, 100n * ETH);
    chain.quoteHandler = fixedRateQuoter({ rate: 3000n * ETH });
    chain.setToken(MOON, { symbol: 'MOON', decimals: 18, name: 'Moon' });
    chain.recent = [{
      id: 1, maker: A.OTHER, board: A.SB2, exp: 0,
      tA: MOON, aA: ETH, symA: 'MOON', decA: 18,
      tB: A.USDC, aB: 1000n * 10n ** 6n, symB: 'USDC', decB: 6,
    }];
    const p = await loadPage({ chain, hash: `token=ETH&out=${MOON}` });
    await p.connect({ pin: false });
    p.click('tabBook');
    await p.settle();
    await p.waitFor(() => p.$('book').querySelector('[data-bf="0"]'), { label: 'filter chips' });
    p.click(p.$('book').querySelector('[data-bf="0"]'));
    await p.settle();
    await p.waitFor(() => p.$('book').querySelectorAll('.o').length >= 1, { label: 'the order row' });
    const warn = p.$('book').querySelector('.o .tg.w');
    assert.ok(warn, 'an imported token is not presented as vetted');
    assert.equal(warn.textContent, 'unverified');
    p.close();
  });
});

describe('links that name a trade', () => {
  test('a trade link with no chain opens on Ethereum, even with the wallet on Base', async () => {
    const chain = new MockChain({ chainId: BASE, autoConnected: true });
    chain.setNative(A.ACCOUNT, 10n * ETH);
    const p = await loadPage({ chain, hash: 'token=ETH&out=USDC&amount=1' });
    await p.settle();
    await p.waitFor(() => p.window.eval('CHAIN_ID') === 1, { label: 'the page on Ethereum', timeout: 3000 }).catch(() => {});
    assert.equal(p.window.eval('CHAIN_ID'), 1, 'a chain-less trade link is an Ethereum link');
    assert.equal(p.window.eval('TOKENS[toSel.value].addr').toLowerCase(), A.USDC.toLowerCase(),
      'and its symbols resolve to Ethereum\'s tokens');
    p.close();
  });
});

describe('the token list arriving after a pick', () => {
  test('keeps the token the user picked, by address', async () => {
    const chain = new MockChain();
    const USDT = '0xdac17f958d2ee523a2206206994597c13d831ec7';
    // Same tokens as the built-ins, in another order, so every index moves.
    chain.registry = [
      registryRow('ETH', A.ZERO, { p: 'Native' }), registryRow('USDC', A.USDC, { d: 6 }),
      registryRow('WBTC', A.WBTC, { d: 8 }), registryRow('WETH', A.WETH), registryRow('USDT', USDT, { d: 6 }),
      registryRow('wstETH', '0x7f39c581f595b53c5cb19bd0b3f8da6c935e2ca0'),
      registryRow('rETH', '0xae78736cd615f374d3085123a210448e74fc6393'),
    ];
    chain.quoteHandler = fixedRateQuoter({ rate: 3000n * ETH });
    // Hold every registry read until the user has picked.
    const reg = [A.TOKENLIST, A.ZLISTLENS].map(a => a.slice(2).toLowerCase());
    const held = [];
    let open = false;
    const request = chain.request.bind(chain);
    chain.request = async args => {
      if (!open && args.method === 'eth_call' && reg.some(r => JSON.stringify(args.params).toLowerCase().includes(r))) {
        await new Promise(r => held.push(r));
      }
      return request(args);
    };
    const p = await loadPage({ chain, hash: null });
    assert.equal(p.window.eval('listLive'), false, 'the registry has not landed yet');
    p.pickToken('toSel', 'USDT');
    await p.settle();
    assert.equal(p.window.eval('TOKENS[toSel.value].addr').toLowerCase(), USDT);
    open = true;
    held.splice(0).forEach(r => r());
    await p.waitFor(() => p.window.eval('listLive'), { label: 'the registry list to land' });
    await p.settle();
    const sel = p.$('toSel');
    assert.equal(p.window.eval('TOKENS[toSel.value].addr').toLowerCase(), USDT,
      `the picked token survives the list changing, got ${[...sel.options].find(o => o.value === sel.value)?.textContent}`);
    p.close();
  });
});

describe('private bridge notes', () => {
  test('recover lists two deposits that share an index but differ in value', async () => {
    const p = await pvOpen();
    await pvUnlock(p);
    const id1 = p.window.eval('cpNoteOf({i:0,v:"1000000"}).dep');
    const id2 = p.window.eval('cpNoteOf({i:0,v:"2000000"}).dep');
    assert.notEqual(id1, id2);
    p.chain.logs.push(wrapLog(id1, ETH / 100n), wrapLog(id2, ETH / 50n));
    advance(p);
    p.click(p.$('pvKey').querySelector('button[data-a="recover"]'));
    await p.waitFor(() => /Recovered/.test(p.text('stat')), { label: 'the recovery' });
    await p.settle();
    const list = p.text('pvList');
    assert.match(list, /0\.01 ETH/, 'the first deposit is listed');
    assert.match(list, /0\.02 ETH/, 'and so is the second, at the same index');
    p.close();
  });

  test('a save in one tab keeps the exit recipe another tab stored', async () => {
    const a = await pvOpen();
    await pvUnlock(a);
    await pvDeposit(a);
    pvSettle(a);
    poke(a);
    await a.waitFor(() => a.$('pvList').querySelector('button[data-a="exit"]'), { label: 'the note to settle', timeout: 15000 });
    const store = a.window.localStorage;

    // Tab B opens on the same notes, then shares tab A's storage from here on.
    const b = await pvOpen({ storage: { ...store } });
    await b.waitFor(() => /0\.01 ETH/.test(b.text('pvList')), { label: 'tab B to list the note' });
    b.window.__shared = store;
    b.window.eval('LS=window.__shared');

    a.click(a.$('pvList').querySelector('button[data-a="exit"]'));
    await a.waitFor(() => a.window.__relayPosts.length === 2, { label: 'the exit to reach the relay', timeout: 15000 });
    await a.settle();
    const key = notesKey(store);
    const exitOf = () => JSON.parse(store[key]).find(n => n.i === 0 && !n.p)?.ex;
    assert.ok(exitOf(), 'tab A stored the exit recipe');
    a.close();

    b.queuePrompt(JSON.stringify([{ i: 7, v: '1000000', at: 0 }]));
    b.click(b.$('pvKey').querySelector('button[data-a="import"]'));
    await b.waitFor(() => /Imported 1 note/.test(b.text('stat')), { label: 'the import in tab B' });
    await b.settle();
    assert.ok(JSON.parse(store[key]).some(n => n.i === 7), 'tab B saved');
    assert.ok(exitOf(), 'the exit recipe tab A stored is still there');
    b.close();
  });

  test('a deposit is not refused for the balance of the swap form\'s token', async () => {
    const p = await pvOpen({
      prep: async q => {
        q.pickToken('toSel', 'WETH');
        q.pickToken('fromSel', 'USDC');
        await q.settle();
      },
    });
    assert.equal(p.window.eval('TOKENS[fromSel.value].sym'), 'USDC', 'the swap form is on a token the wallet lacks');
    await pvUnlock(p);
    p.type('pvAmt', '0.01');
    p.click('pvGo');
    await p.waitFor(() => p.chain.sentTo(ROUTER).length === 1 || /Error/.test(p.text('stat')), { label: 'the deposit' });
    assert.doesNotMatch(p.text('stat'), /Not enough ETH/);
    assert.equal(p.chain.sentTo(ROUTER).length, 1, 'the deposit is sent from an ETH balance that covers it');
    assert.equal(BigInt(p.chain.sentTo(ROUTER)[0].value), ETH / 100n);
    p.close();
  });
});

describe('quoting', () => {
  test('no Multicall3 batch sent while quoting carries more than one zQuoter call', async () => {
    const chain = new MockChain();
    chain.setNative(A.ACCOUNT, 10n * ETH);
    chain.quoteHandler = fixedRateQuoter({ rate: 3000n * ETH });
    const p = await loadPage({ chain });
    await p.connect();
    const from = chain.calls.length;
    await p.typeAmount('amt', '1');
    assert.equal(p.value('outAmt'), '3000', 'the quote lands');
    const zq = A.ZQUOTER.toLowerCase();
    const batches = chain.calls.slice(from)
      .filter(c => c.to === A.MC3.toLowerCase() && c.selector === SEL.AGG3)
      .map(c => coder.decode(['tuple(address,bool,bytes)[]'], '0x' + c.data.slice(10))[0]
        .filter(([t]) => t.toLowerCase() === zq).length);
    assert.ok(chain.calls.slice(from).some(c => c.to === zq), 'zQuoter was asked');
    assert.ok(batches.every(n => n <= 1), `zQuoter calls per batch: ${batches.filter(n => n).join(',')}`);
    p.close();
  });

  describe('an ETH to WETH wrap paid to another address', () => {
    // buildBestSwap's wrap leg, as the deployed quoter answers it: 1:1, limit and value both the amount.
    const wrapQuoter = ({ selector, data }) => {
      if (selector !== SEL.QUOTE_ONE) return null;
      const body = '0x' + data.replace(/^0x/, '').slice(8);
      const tin = wordAddr(body, 2).toLowerCase(), tout = wordAddr(body, 3).toLowerCase();
      const pair = [tin, tout].sort().join();
      if (pair !== [A.ZERO, A.WETH.toLowerCase()].sort().join()) return null;
      const amount = word(body, 4);
      if (!amount) return null;
      return encodeSingleHop({
        source: 7, feeBps: 0n, amountIn: amount, amountOut: amount, amountLimit: amount,
        msgValue: tin === A.ZERO ? amount : 0n, callData: '0x' + SEL.MULTICALL + '00'.repeat(28),
      });
    };
    const openWrap = async () => {
      const chain = new MockChain();
      chain.setNative(A.ACCOUNT, 10n * ETH);
      chain.quoteHandler = wrapQuoter;
      const p = await loadPage({ chain, hash: 'token=ETH&out=WETH' });
      await p.connect({ pin: false });
      p.type('rc', A.OTHER);
      await wait(p, 320);
      await p.settle();
      return p;
    };

    test('quotes a minimum equal to the amount', async () => {
      const p = await openWrap();
      await p.typeAmount('amt', '1');
      assert.equal(p.value('outAmt'), '1');
      assert.match(p.text('rate'), /Min 1 WETH/, `rate line: ${p.text('rate')}`);
      p.close();
    });

    test('exact-out sends the wrap with the amount as its value', async () => {
      const p = await openWrap();
      await p.typeAmount('outAmt', '1');
      p.queueConfirm(true, true);
      p.click('swap');
      await p.waitFor(() => p.chain.sent.length > 0 || /Error/.test(p.text('stat')), { label: 'the swap' });
      await p.settle();
      assert.doesNotMatch(p.text('stat'), /bad value/);
      assert.equal(p.chain.sent.length, 1, 'the wrap is sent');
      assert.equal(BigInt(p.chain.lastSent.value), ETH, 'carrying exactly the ether wrapped');
      p.close();
    });
  });
});

describe('sending to another chain', () => {
  test('a contract here with no code on the destination asks first, and declining sends nothing', async () => {
    const chain = new MockChain();
    chain.setNative(A.ACCOUNT, 10n * ETH);
    // Every Base node the page may ask answers from one Base chain, where OTHER has no code.
    const base = new MockChain({ chainId: BASE });
    chain.remotes['base-rpc'] = base;
    chain.remotes['base.org'] = base;
    chain.remotes['robinhood'] = new MockChain({ chainId: '0x1237' });
    chain.code.set(A.OTHER.toLowerCase(), '0x6000');
    const p = await loadPage({ chain });
    await p.connect();
    p.click('tabSend');
    await p.settle();
    await p.typeAmount('amt', '2');
    p.type('rc', A.OTHER);
    await wait(p, 320);
    await p.settle();
    p.select('sdChain', '8453');
    await p.settle();
    await p.waitFor(() => !p.disabled('swap'), { label: 'a send the page will make' });
    p.queueConfirm(false);
    p.click('swap');
    await p.waitFor(() => p.asked.confirm.length > 0 || p.chain.sent.length > 0 || /Error/.test(p.text('stat')),
      { label: 'the send to be decided' });
    await p.settle();
    assert.ok(p.asked.confirm.some(q => /contract here and has no code on Base/.test(q)),
      `the user is asked before ether lands where nobody may control it (asked: ${JSON.stringify(p.asked.confirm)})`);
    assert.equal(p.chain.sent.length, 0, 'declining sends nothing');
    p.close();
  });
});
