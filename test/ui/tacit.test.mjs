/**
 * Tacit beyond ether: the shielded assets the token list names, and Tacit's
 * public AMM as a swap venue.
 *
 * The private bridge's asset picker is built from the list's TACIT rows, each
 * one kept only if the pool has it registered and - for anything but native
 * ether - its canonical ERC-20 is the very token the pool mints and burns. So
 * a card that merely looks paired never becomes a deposit target. A pool-minted
 * token is burned by `pool.wrap` itself, which is why depositing one needs no
 * approval; it withdraws to Ethereum as the public token, with the relay taking
 * its fee in that asset.
 *
 * On the swap side, `TacitPublicAmm` trades the same reserves the confidential
 * pool does. It quotes exact-in only, in the pool's eight-decimal units, and
 * pulls an ERC-20 with `transferFrom` - so a sell approves the AMM, not zRouter.
 */
import { test, describe, after } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { AbiCoder, keccak256, toUtf8Bytes } from 'ethers';
import { A, MockChain, loadPage, closeAllPages, fixedRateQuoter, word, wordAddr, selectorOf, CP_BLOCK } from './harness.mjs';

after(closeAllPages);

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..');
const F = JSON.parse(fs.readFileSync(path.join(ROOT, 'test', 'fixtures', 'confidential.json'), 'utf8'));
const coder = AbiCoder.defaultAbiCoder();
const ETH = 10n ** 18n;
const B0 = CP_BLOCK + 0x100;
const u256 = v => BigInt(v).toString(16).padStart(64, '0');
const addrWord = a => a.replace(/^0x/, '').toLowerCase().padStart(64, '0');

const POOL = F.pool, ROUTER = F.router;
const AMM = '0x00000000E36C7EC997CC59DCda9E03673B448119';
const ETH_ID = F.ethAssetId, TAC_ID = F.tac.assetId;
const TAC = '0xd7d7976367d171d105722f1ce1afa61602d97a4d';
const FAKE_ID = '0x' + 'fa'.repeat(32), FAKE = '0x' + 'fa'.repeat(20);
const SEL = { ASSETS: '9fda5b66', CANON: '0f65304b', NEXT: '0be4f422', DEPOSIT: '7da9874f', WRAP: '8be3ad21',
  SETTLE: '717fd7f2', IMPL: '93228617', ESCROW: '2bf0cda2', QUOTE: '3bc1414a', SWAP: 'cfdf9dcc' };
const T = {
  LEAVES: keccak256(toUtf8Bytes('LeavesInserted(uint256,bytes32[],bytes[])')),
  WRAP: keccak256(toUtf8Bytes('Wrap(bytes32,bytes32,uint256)')),
};
const RELAY = 'api.tacit.finance';

const row = (s, a, o = {}) => ({ i: '1', c: 1, k: 'eip155', p: 'ERC-20', x: true, o: false, f: false,
  a, n: `${s} Token`, s, d: 18, t: '#888', r: 1, u: '', au: '', l: '', desc: '', e: [], v: true, ...o });
const LOGO = 'data:image/svg+xml;base64,' + Buffer.from('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 2 2"><circle cx="1" cy="1" r="1"/></svg>').toString('base64');
const tacitRow = (s, id) => row(s, id, { c: 0, k: 'raw', p: 'Tacit', d: 8, l: LOGO });
const REGISTRY = [row('ETH', A.ZERO, { p: 'Native' }), row('USDC', A.USDC, { d: 6 }), row('TAC', TAC),
  tacitRow('tETH', ETH_ID), tacitRow('TAC', TAC_ID), tacitRow('cFAKE', FAKE_ID)];

// assets(id) -> (registered, underlying, unitScale, crossChainLink, poolMinted, decimals), as the pool answers.
const ASSET = {
  [ETH_ID]: [1, A.ZERO, 10n ** 10n, ETH_ID, 0, 18],
  [TAC_ID]: [1, TAC, 10n ** 10n, TAC_ID, 1, 18],
  [FAKE_ID]: [1, FAKE, 10n ** 10n, FAKE_ID, 1, 18],
};
// canonicalTokenFor: the fake card's token is NOT what the pool mints for it.
const CANON = { [ETH_ID]: A.ZERO, [TAC_ID]: TAC, [FAKE_ID]: A.OTHER };
const idArg = data => '0x' + data.slice(10, 74).toLowerCase();

function tacitChain({ quote } = {}) {
  const chain = new MockChain();
  chain.registry = REGISTRY;
  chain.gasPrice = 10n ** 8n;
  chain.blockNumber = '0x' + (B0 + 0x8).toString(16);
  chain.setNative(A.ACCOUNT, 10n * ETH);
  chain.quoteHandler = quote ?? (() => null);
  chain.answer(POOL, SEL.ASSETS, data => {
    const a = ASSET[idArg(data)];
    return a ? '0x' + u256(a[0]) + addrWord(a[1]) + u256(a[2]) + a[3].slice(2) + u256(a[4]) + u256(a[5]) : '0x' + u256(0).repeat(6);
  });
  chain.answer(POOL, SEL.CANON, data => '0x' + addrWord(CANON[idArg(data)] || A.ZERO));
  chain.answer(POOL, SEL.NEXT, () => '0x' + u256(chain.nextLeaf ?? 0));
  chain.answer(POOL, SEL.DEPOSIT, '0x' + u256(0));
  chain.answer(POOL, SEL.WRAP, '0x');
  chain.answer(POOL, SEL.SETTLE, '0x');
  chain.relay = { status: { status: 'pending' } };
  chain.lanes = {};
  Object.defineProperty(chain.lanes, RELAY + '/confidential/submit', {
    enumerable: true, get: () => ({ ok: true, jobId: '0xjob' + Math.random().toString(16).slice(2), status: 'pending' }),
  });
  Object.defineProperty(chain.lanes, RELAY + '/confidential/status', { enumerable: true, get: () => chain.relay.status });
  return chain;
}

const wrapLog = (id, amount, asset) => ({ address: POOL, blockNumber: '0x' + (B0 + 0x4).toString(16), logIndex: '0x0',
  topics: [T.WRAP, id, asset], data: '0x' + u256(amount) });
const leavesLog = (first, leaves, memos) => ({ address: POOL, blockNumber: '0x' + (B0 + 0x5).toString(16), logIndex: '0x0',
  topics: [T.LEAVES, '0x' + u256(first)], data: coder.encode(['bytes32[]', 'bytes[]'], [leaves, memos]) });
const advance = p => { p.chain.blockNumber = '0x' + (BigInt(p.chain.blockNumber) + 5n).toString(16); };
const poke = p => p.doc.dispatchEvent(new p.window.Event('visibilitychange'));
const SLOW = { timeout: 20000 };

async function open({ chain = tacitChain(), storage, pv = true } = {}) {
  const p = await loadPage({ chain, storage });
  const inner = p.window.fetch;
  p.window.__relayPosts = [];
  p.window.fetch = async (url, init) => {
    if (String(url).includes('/confidential/') && init && init.body) p.window.__relayPosts.push(JSON.parse(init.body));
    return inner(url, init);
  };
  await p.connect();
  if (pv) {
    p.click('pv');
    await p.settle();
    await p.waitFor(() => p.$('pvAsset').options.length === 2, { label: 'the asset list to load' });
  }
  return p;
}
async function unlock(p) {
  p.click('pvGo');
  await p.waitFor(() => /Key unlocked/.test(p.text('pvKey')), { label: 'the key to unlock' });
}
async function depositTac(p) {
  p.select('pvAsset', TAC_ID);
  p.type('pvAmt', '100');
  p.click('pvGo');
  await p.waitFor(() => p.chain.sentTo(POOL).length === 1, { label: 'the TAC deposit to be sent' });
  await p.waitFor(() => p.window.__relayPosts.length === 1, { label: 'the wrap to reach the relay' });
}

const FARM = { network: 'mainnet', epoch: { active: true, ratePerDayTac: '1107.7776' }, stale: false, pools: [
  { pid: 0, pair: 'TAC/cETH', idle: false, tacPerDayForPool: '553.8888' },
  { pid: 1, pair: 'cETH/cUSD', idle: false, tacPerDayForPool: '332.33328' },
  { pid: 2, pair: 'cETH/cBTC', idle: false, tacPerDayForPool: '221.55552' }] };

describe('Tacit farms', () => {
  test('the live program shows as TAC per day per pool, with a link out to add liquidity', async () => {
    const chain = tacitChain();
    chain.lanes[RELAY + '/farm/program'] = FARM;
    const p = await open({ chain });
    await p.waitFor(() => !p.$('pvFarm').classList.contains('hide'), { label: 'the farm line' });
    const chips = [...p.$('pvFarm').querySelectorAll('.fmc')];
    assert.deepEqual(chips.map(c => c.textContent), ['TAC/tETH 554 TAC/day', 'tETH/cUSD 332 TAC/day', 'tETH/cBTC 222 TAC/day'], 'cETH reads as tETH, as everywhere else on the page');
    assert.equal(chips[0].querySelectorAll('img').length, 2, 'a listed pair shows both logos');
    assert.equal(p.$('pvFarm').querySelector('a').getAttribute('href'), 'https://tacit.finance');
    p.close();
  });

  test('each farm shows its APR for a 1 ETH entry, priced off the pools themselves', async () => {
    const enc = AbiCoder.defaultAbiCoder();
    const pid = (a, b) => { const [x, y] = BigInt(a) < BigInt(b) ? [a, b] : [b, a]; return keccak256(enc.encode(['bytes32', 'bytes32', 'uint32'], [x, y, 30])); };
    const lpOf = P => keccak256(P + '6c70');
    const P0 = pid(TAC_ID, ETH_ID);
    const [a0, b0] = BigInt(TAC_ID) < BigInt(ETH_ID) ? [TAC_ID, ETH_ID] : [ETH_ID, TAC_ID];
    const rE = 51101n, rT = 729864783n, sh = 6106393n, staked = 5873947;
    const chain = tacitChain();
    chain.lanes[RELAY + '/farm/program'] = { ...FARM, epoch: { ...FARM.epoch, periodFinish: 4102444800 },
      pools: [{ ...FARM.pools[0], lpAsset: lpOf(P0), totalShares: String(staked) }, FARM.pools[1]] };
    chain.answer(POOL, 'b5217bb4', data => '0x' + (('0x' + data.slice(10, 74)).toLowerCase() === P0.toLowerCase()
      ? u256(1) + a0.slice(2) + b0.slice(2) + u256(a0 === ETH_ID ? rE : rT) + u256(a0 === ETH_ID ? rT : rE) + u256(30) + u256(sh)
      : u256(0).repeat(7)));
    const p = await open({ chain });
    await p.waitFor(() => /APR/.test(p.text('pvFarm')), { label: 'the APR' });
    const px = Number(rE) / Number(rT), st = 2 * Number(rE) / 1e8 * staked / Number(sh);
    const apr = Math.round(553.8888 * 365 * px / (st + 1) * 100).toLocaleString();
    const chips = [...p.$('pvFarm').querySelectorAll('.fmc')];
    assert.equal(chips[0].textContent, `TAC/tETH 554 TAC/day · ~${apr}% APR on 1 ETH`);
    assert.match(chips[0].title, /TAC\/tETH pool price/);
    assert.equal(chips[1].textContent, 'tETH/cUSD 332 TAC/day', 'a pool the page cannot match to its LP asset shows no APR');
    assert.match(p.text('pvFarm'), /until /, 'the stream end is named');
    p.close();
  });

  test('the APR uses the reserves the program now carries, with no extra pool read', async () => {
    const enc = AbiCoder.defaultAbiCoder();
    const [x, y] = BigInt(TAC_ID) < BigInt(ETH_ID) ? [TAC_ID, ETH_ID] : [ETH_ID, TAC_ID];
    const P0 = keccak256(enc.encode(['bytes32', 'bytes32', 'uint32'], [x, y, 30]));
    const rE = 51101, rT = 729864783, sh = 6106393, staked = 5873947;
    const chain = tacitChain();
    chain.lanes[RELAY + '/farm/program'] = { ...FARM, pools: [{ ...FARM.pools[0], poolId: P0, lpAsset: keccak256(P0 + '6c70'), totalShares: String(staked),
      reserves: { assetA: x, assetB: y, reserveA: String(x === ETH_ID ? rE : rT), reserveB: String(x === ETH_ID ? rT : rE), lpTotalShares: String(sh) } }] };
    let poolReads = 0;
    chain.answer(POOL, 'b5217bb4', () => { poolReads++; return '0x' + u256(0).repeat(7); });
    const p = await open({ chain });
    await p.waitFor(() => /APR/.test(p.text('pvFarm')), { label: 'the APR' });
    const apr = Math.round(553.8888 * 365 * (rE / rT) / (2 * rE / 1e8 * staked / sh + 1) * 100).toLocaleString();
    assert.equal(p.$('pvFarm').querySelector('.fmc').textContent, `TAC/tETH 554 TAC/day · ~${apr}% APR on 1 ETH`);
    assert.equal(poolReads, 0, 'the reserves came with the program');
    p.close();
  });

  test('a stale, ended or odd program shows nothing', async () => {
    for (const bad of [{ ...FARM, stale: true }, { ...FARM, epoch: { active: false } }, { ...FARM, epoch: { ...FARM.epoch, periodFinish: 1 } },
      { ...FARM, pools: [{ pair: '<img src=x>', tacPerDayForPool: '5' }] }, { ...FARM, pools: [{ pair: 'TAC/cETH', tacPerDayForPool: 'Infinity' }] }]) {
      const chain = tacitChain();
      chain.lanes[RELAY + '/farm/program'] = bad;
      const p = await open({ chain });
      await p.settle();
      assert.ok(p.$('pvFarm').classList.contains('hide'));
      p.close();
    }
  });
});

describe('the shielded assets come from the token list', () => {
  test('the picker offers what the list names and the pool backs, and nothing else', async () => {
    const p = await open();
    const opts = [...p.$('pvAsset').options].map(o => o.textContent);
    assert.deepEqual(opts, ['tETH', 'TAC'], 'a card whose token the pool does not mint is left out');
    assert.equal(p.text('pvUnit'), 'ETH');
    p.select('pvAsset', TAC_ID);
    assert.equal(p.text('pvUnit'), 'TAC', 'the amount is in the public token you give up');
    const chains = [...p.$('pvChain').options];
    assert.ok(chains.filter(o => o.value !== '1').every(o => o.disabled), 'a token cannot exit to an L2');
    assert.equal(p.$('pvChain').value, '1');
    p.select('pvAsset', ETH_ID);
    assert.equal(p.text('pvUnit'), 'ETH');
    assert.ok(chains.every(o => !o.disabled), 'ether can again');
    p.close();
  });

  test('the asset button shows each asset with its list logo and switches the asset', async () => {
    const p = await open();
    assert.equal(p.text('pvAssetB'), 'tETH');
    assert.ok(p.$('pvAssetB').querySelector('img'), 'the current asset carries its logo');
    p.click('pvAssetB');
    await p.waitFor(() => !p.$('wkWrap').classList.contains('hide'), { label: 'the asset chooser' });
    const rows = [...p.$('wkList').querySelectorAll('button.tkr')];
    assert.deepEqual(rows.map(b => [b.firstChild.nextSibling.textContent, b.querySelector('.wks').textContent]), [['tETH', 'private ETH'], ['TAC', 'private TAC']]);
    assert.ok(rows.every(b => b.querySelector('img')), 'every row carries its logo');
    rows[1].click();
    await p.waitFor(() => p.$('pvAsset').value === TAC_ID, { label: 'TAC to be chosen' });
    assert.equal(p.text('pvAssetB'), 'TAC');
    assert.equal(p.text('pvUnit'), 'TAC');
    assert.equal(p.$('pvChain').value, '1', 'a token withdraws on Ethereum');
    assert.match(p.text('pvHint'), /withdraw it as TAC to any 0x on Ethereum/);
    p.select('pvAct', 'send');
    assert.match(p.text('pvHint'), /stay hidden/);
    p.close();
  });
});

describe('shielding TAC', () => {
  test('a deposit burns the public token through pool.wrap, with no approval', async () => {
    const chain = tacitChain();
    chain.setErc20(TAC, A.ACCOUNT, 500n * ETH);
    const p = await open({ chain });
    await unlock(p);
    await depositTac(p);
    const tx = p.chain.sentTo(POOL)[0];
    assert.equal(BigInt(tx.value || 0), 0n, 'no ether rides along');
    assert.equal(tx.data, F.tac.wrapCalldata, 'pool.wrap(TAC, 100e18, commit), as Tacit builds it');
    assert.equal(p.chain.sentTo(TAC).length, 0, 'nothing is sent to the token: the pool burns it as its minter');
    assert.deepEqual(p.window.__relayPosts[0].op, F.tac.wrapOp, 'the wrap witness is Tacit\'s');
    assert.match(p.text('pvList'), /100 TAC/);
    p.close();
  });

  test('more than the wallet holds is refused before anything is sent', async () => {
    const chain = tacitChain();
    chain.setErc20(TAC, A.ACCOUNT, 10n * ETH);
    const p = await open({ chain });
    await unlock(p);
    p.select('pvAsset', TAC_ID);
    p.type('pvAmt', '100');
    p.click('pvGo');
    await p.waitFor(() => /Not enough TAC/.test(p.text('stat')), { label: 'the refusal' });
    assert.equal(p.chain.sentTo(POOL).length, 0);
    p.close();
  });

  test('a TAC note withdraws on Ethereum through the relay, paying its fee in TAC', async () => {
    const chain = tacitChain();
    chain.setErc20(TAC, A.ACCOUNT, 500n * ETH);
    const p = await open({ chain });
    await unlock(p);
    await depositTac(p);
    p.select('pvAsset', ETH_ID);
    p.select('pvChain', '8453');
    p.chain.relay.status = { status: 'settled' };
    p.chain.logs.push(wrapLog(F.tac.depositId, F.tac.amountWei, TAC_ID));
    p.chain.logs.push(leavesLog(0, [F.tac.leaf, F.otherLeaf], [F.tac.memo, '0x' + '11'.repeat(169)]));
    p.chain.nextLeaf = 2;
    advance(p);
    poke(p);
    await p.waitFor(() => p.$('pvList').querySelector('button[data-a="exit"]'), { label: 'the note to settle', ...SLOW });
    assert.match(p.text('pvList'), /Shielded 100 TAC/, 'the TAC note counts in the shielded balance');
    p.select('pvAct', 'out');
    p.click(p.$('pvList').querySelector('button[data-a="exit"]'));
    await p.waitFor(() => p.window.__relayPosts.length === 2, { label: 'the unwrap to reach the relay', ...SLOW });
    const op = p.window.__relayPosts[1].op;
    assert.equal(op.asset, TAC_ID);
    assert.equal(op.fee, F.tac.fee, 'the relay\'s 2 TAC floor, as Tacit quotes it');
    assert.equal(op.recipient, A.ACCOUNT.toLowerCase(), 'paid to the wallet on Ethereum even with Base chosen for ether');
    assert.equal(op.spendRoot, F.tac.root);
    assert.deepEqual(op.path, F.tac.path);
    assert.equal(op.value, F.tac.note.value);
    assert.equal(op.nk, F.tac.note.secret);
    assert.equal(p.chain.calls.filter(c => c.selector === SEL.ESCROW).length, 0, 'no bridge recipe');
    p.close();
  });

  test('recovery finds a TAC deposit by the asset its Wrap event names', async () => {
    const p = await open({ storage: { ['zswap:cpk:' + A.ACCOUNT.toLowerCase()]: F.seed } });
    p.chain.logs.push(wrapLog(F.tac.depositId, F.tac.amountWei, TAC_ID));
    advance(p);
    p.click(p.$('pvKey').querySelector('button[data-a="recover"]'));
    await p.waitFor(() => /Recovered 1 deposit/.test(p.text('stat')), { label: 'the recovery', ...SLOW });
    assert.match(p.text('pvList'), /100 TAC/);
    p.close();
  });

  test('a TAC request names the token, and paying it is a pool.wrap of the token', async () => {
    const r = await open();
    await unlock(r);
    r.select('pvAsset', TAC_ID);
    r.type('pvAmt', '100');
    r.click(r.$('pvKey').querySelector('button[data-a="request"]'));
    await r.waitFor(() => r.asked.prompt.length === 1, { label: 'the request prompt', ...SLOW });
    const inv = JSON.parse(Buffer.from(r.window.__promptDefaults[0].split('#tacit-invoice=')[1], 'base64url').toString('utf8'));
    assert.equal(inv.assetId, TAC_ID);
    assert.equal(inv.underlying, TAC);
    assert.equal(inv.ticker, 'cTAC', 'Tacit\'s own ticker, so its dapp can pay it too');
    assert.equal(inv.amount, F.tac.amountWei);
    assert.deepEqual(inv.witness, F.tac.wrapOp);
    r.close();

    const chain = tacitChain();
    chain.setErc20(TAC, A.ACCOUNT, 500n * ETH);
    const q = await open({ chain });
    await unlock(q);
    q.queuePrompt(JSON.stringify(inv));
    q.queueConfirm(true);
    q.click(q.$('pvKey').querySelector('button[data-a="pay"]'));
    await q.waitFor(() => q.chain.sentTo(POOL).length === 1, { label: 'the payment', ...SLOW });
    assert.match(q.asked.confirm.at(-1), /^Pay 100 TAC into this private request/, 'pasted JSON still works, and still asks first');
    const tx = q.chain.sentTo(POOL)[0];
    assert.equal(tx.data, F.tac.wrapCalldata);
    assert.equal(BigInt(tx.value || 0), 0n);
    await q.waitFor(() => /100 TAC paid/.test(q.text('pvList')), { label: 'the paid row' });
    q.close();
  });
});

describe('the shield link on the swap form', () => {
  test('paying with a shieldable token offers to shield it, and opens the bridge on it', async () => {
    const chain = tacitChain();
    chain.setErc20(TAC, A.ACCOUNT, 500n * ETH);
    const p = await open({ chain, pv: false });
    assert.ok(!p.visible('shieldGo'), 'not for ether');
    p.pickToken('fromSel', 'TAC');
    await p.settle();
    await p.waitFor(() => p.visible('shieldGo'), { label: 'the shield link' });
    p.click('shieldGo');
    await p.settle();
    assert.ok(p.visible('pvPanel'), 'the private bridge opens');
    assert.equal(p.$('pvAsset').value, TAC_ID, 'on TAC');
    assert.equal(p.text('pvUnit'), 'TAC');
    assert.ok(!p.visible('shieldGo'), 'and the link steps aside');
    p.close();
  });
});

describe('the public tokens say what they are to Tacit', () => {
  // The tag is the only place the public and confidential faces of one asset
  // meet in the swap surface, so it carries the shielded balance too. What is
  // pinned here is the gate, not the formatting: a balance clause must never
  // appear for value the holder does not actually have settled and spendable.
  // A deposit that has only reached the relay is not that, and neither is a
  // locked key. (The positive rendering wants a settled TAC note in the pool's
  // leaves, which this file's fixture does not build -- tETH cannot stand in
  // for it either, since it has no ERC-20 leg and so never carries a tag.)
  test('the tag claims no shielded balance until one is really held', async () => {
    const chain = tacitChain();
    chain.setErc20(TAC, A.ACCOUNT, 500n * ETH);
    const p = await open({ chain });
    await unlock(p);
    await depositTac(p);
    p.click('pv');                 // leave the bridge so the picker is reachable
    await p.settle();
    p.click('fromPick');
    await p.settle();
    const rows = [...p.$('tkList').querySelectorAll('.tkr')];
    const tag = rows.find(r => r.querySelector('b')?.textContent === 'TAC')?.textContent || '';
    assert.match(tag, /shields into the confidential pool as TAC/, 'the tag itself still renders');
    assert.doesNotMatch(tag, /you hold/,
      'a deposit that has only reached the relay is not settled, so it is not a balance');
    p.close();
  });

  test('the picker tags a token the pool mints with the asset it shields into', async () => {
    const p = await open({ pv: false });
    p.click('fromPick');
    await p.settle();
    const rows = [...p.$('tkList').querySelectorAll('.tkr')];
    const row = sym => rows.find(r => r.querySelector('b')?.textContent === sym);
    assert.match(row('TAC').textContent, /shields into the confidential pool as TAC/);
    assert.doesNotMatch(row('USDC').textContent, /Tacit/, 'nothing on a token Tacit does not back');
    p.close();
  });
});

describe('Tacit\'s public AMM as a venue', () => {
  const quoting = out => chain => chain.answer(AMM, SEL.QUOTE, data => (word('0x' + data.slice(10), 2) === 30n ? '0x' + u256(out(data)) : undefined));
  const ammChain = ({ out, quote } = {}) => {
    const chain = tacitChain({ quote });
    chain.setErc20(TAC, A.ACCOUNT, 5000n * ETH);
    quoting(out)(chain);
    chain.answer(AMM, SEL.SWAP, '0x' + u256(1));
    return chain;
  };

  test('ETH -> TAC is quoted from the AMM and sent as swapPublic with the ether as value', async () => {
    const p = await open({ chain: ammChain({ out: () => 1000n * ETH }), pv: false });
    p.pickToken('toSel', 'TAC');
    await p.settle();
    await p.typeAmount('amt', '1');
    assert.match(p.text('rate'), /Tacit.0\.3%/, 'the venue and its fee tier are named');
    p.queueConfirm(true);
    p.click('swap');
    await p.settle();
    const tx = p.chain.lastSent;
    assert.equal(tx.to.toLowerCase(), AMM.toLowerCase(), 'straight to the AMM');
    assert.equal(selectorOf(tx.data), SEL.SWAP);
    assert.equal(BigInt(tx.value), ETH, 'the ether is the input');
    const body = '0x' + tx.data.slice(10);
    assert.equal('0x' + body.slice(2, 66), ETH_ID, 'asset in');
    assert.equal('0x' + body.slice(66, 130), TAC_ID, 'asset out');
    assert.equal(word(body, 2), 30n, 'the tier that quoted');
    assert.equal(word(body, 3), ETH, 'amount in');
    const min = word(body, 4);
    assert.ok(min < 1000n * ETH && min >= 990n * ETH, 'a slippage floor under the quote');
    assert.ok(word(body, 5) > 0n, 'a deadline');
    assert.equal(wordAddr(body, 6).toLowerCase(), A.ACCOUNT.toLowerCase(), 'to the wallet');
    p.close();
  });

  test('selling TAC approves the AMM, not the router', async () => {
    const p = await open({ chain: ammChain({ out: () => ETH / 2n }), pv: false });
    p.pickToken('fromSel', 'TAC');
    await p.settle();
    p.pickToken('toSel', 'ETH');
    await p.settle();
    await p.typeAmount('amt', '1000');
    p.queueConfirm(true);
    p.click('swap');
    await p.settle();
    const approvals = p.chain.sentTo(TAC);
    assert.ok(approvals.length >= 1, 'an approval was sent');
    assert.equal(wordAddr('0x' + approvals.at(-1).data.slice(10), 0).toLowerCase(), AMM.toLowerCase(), 'to the AMM, which pulls with transferFrom');
    assert.equal(p.chain.lastSent.to.toLowerCase(), AMM.toLowerCase());
    assert.equal(BigInt(p.chain.lastSent.value || 0), 0n);
    p.close();
  });

  test('exact-out on a pair only Tacit trades points the user to exact-in', async () => {
    const p = await open({ chain: ammChain({ out: () => 1000n * ETH }), pv: false });
    p.pickToken('toSel', 'TAC');
    await p.settle();
    p.type('outAmt', '1000');
    await p.waitFor(() => /exact-output is unavailable/.test(p.text('stat')), { label: 'the exact-out refusal' });
    p.close();
  });

  test('it competes: the better of Tacit and the aggregator wins', async () => {
    const rate = 3000n * ETH;
    const lose = await open({ chain: ammChain({ out: () => 1000n * ETH, quote: fixedRateQuoter({ rate, decOut: 18 }) }), pv: false });
    lose.pickToken('toSel', 'TAC');
    await lose.settle();
    await lose.typeAmount('amt', '1');
    assert.doesNotMatch(lose.text('rate'), /Tacit/, 'a thinner Tacit quote loses');
    lose.close();
    const win = await open({ chain: ammChain({ out: () => 5000n * ETH, quote: fixedRateQuoter({ rate, decOut: 18 }) }), pv: false });
    win.pickToken('toSel', 'TAC');
    await win.settle();
    await win.typeAmount('amt', '1');
    assert.match(win.text('rate'), /Tacit/, 'a better one wins');
    assert.equal(win.window.eval('last.to').toLowerCase(), AMM.toLowerCase());
    win.close();
  });

  test('an amount finer than the pool\'s eight decimals is not quoted', async () => {
    const p = await open({ chain: ammChain({ out: () => 1000n * ETH }), pv: false });
    p.pickToken('toSel', 'TAC');
    await p.settle();
    assert.equal(await p.window.eval('tacitQuote(TOKENS[fromSel.value],TOKENS[toSel.value],100000000n)'), null);
    const q = await p.window.eval('tacitQuote(TOKENS[fromSel.value],TOKENS[toSel.value],10n**18n)');
    assert.equal(q && q.fee, 30);
    p.close();
  });
});
