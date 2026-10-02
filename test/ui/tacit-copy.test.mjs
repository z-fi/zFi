/**
 * What the page tells a Tacit user, and where it sends them. The points
 * paragraph in the docs says who a deposit earns for and names the early and
 * TAC holder boosts. A points history row carries the TAC holder multiplier the
 * relay credited, and a cBTC mint reads as a bond. The farm teaser links to
 * tacit.finance's farm page, in a new tab with no referrer. Claiming the airdrop privately
 * first says the private route is untested on mainnet, and declining sends
 * nothing. Each case failed on the page before it.
 */
import { test, describe, after } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { keccak256, AbiCoder, concat } from 'ethers';
import { A, MockChain, loadPage, closeAllPages, CP_BLOCK } from './harness.mjs';

after(closeAllPages);

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..');
const F = JSON.parse(fs.readFileSync(path.join(ROOT, 'test', 'fixtures', 'confidential.json'), 'utf8'));
const coder = AbiCoder.defaultAbiCoder();
const ETH = 10n ** 18n;
const u256 = v => BigInt(v).toString(16).padStart(64, '0');
const SLOW = { timeout: 15000 };
const RELAY = 'api.tacit.finance';
const ME = A.ACCOUNT.toLowerCase();

describe('the points paragraph in the docs', () => {
  test('says a deposit earns its sender, and names the early and TAC holder boosts', async () => {
    const p = await loadPage({ chain: new MockChain() });
    const para = [...p.$('docPanel').querySelectorAll('p')].find(x => /Tacit’s points count/.test(x.textContent));
    assert.ok(para, 'the points paragraph');
    const t = para.textContent;
    assert.match(t, /earns its sender 1,000 points per ETH/);
    assert.match(t, /Early activity earns up to 5×/);
    assert.match(t, /100, 1,000 or 10,000 public TAC held at the sender all the previous day boosts points 1\.25×, 1\.5× or 2×/);
    p.close();
  });
});

// ---- the confidential pool, as the mock chain serves it ----
const SEL_CP = { IMPL: '93228617', ASSETS: '9fda5b66', NEXT: '0be4f422', DEPOSIT: '7da9874f' };
const B0 = CP_BLOCK + 0x100;

function poolChain() {
  const chain = new MockChain();
  chain.blockNumber = '0x' + (B0 + 0x100).toString(16);
  chain.gasPrice = 10n ** 8n;
  chain.setNative(A.ACCOUNT, 10n * ETH);
  chain.answer(F.router, SEL_CP.IMPL, '0x' + F.executorImpl.slice(2).toLowerCase().padStart(64, '0'));
  chain.answer(F.pool, SEL_CP.ASSETS, '0x' + u256(1) + u256(0) + u256(10n ** 10n) + F.ethAssetId.slice(2) + u256(0) + u256(18));
  chain.answer(F.pool, SEL_CP.NEXT, () => '0x' + u256(chain.nextLeaf ?? 0));
  chain.answer(F.pool, SEL_CP.DEPOSIT, '0x' + u256(0));
  chain.lanes = {};
  return chain;
}
const serve = (chain, route, body) => Object.defineProperty(chain.lanes, RELAY + route, {
  configurable: true, enumerable: true, get: () => body,
});
const roster = { 'zswap:ep4': JSON.stringify({ t: Date.now(), v: [[], [], [], ['https://' + RELAY], [], [], [], [], [], [], [], []] }) };

async function unlocked(chain) {
  const p = await loadPage({ chain, storage: roster });
  await p.connect();
  p.click('pv');
  await p.settle();
  p.click('pvGo');
  await p.waitFor(() => /Key unlocked/.test(p.text('pvKey')), { label: 'the key to unlock', ...SLOW });
  await p.waitFor(() => p.window.eval('!!cpPool') && /No deposits yet|Shielded/.test(p.text('pvList')), { label: 'the pool to load', ...SLOW });
  await p.settle();
  return p;
}

describe('the points history', () => {
  test('names the TAC holder boost on the deposit it was paid on, and a cBTC mint as a bond', async () => {
    const chain = poolChain();
    serve(chain, '/points/', { address: ME, points: 4.94, deposit_count: 3, deposits: [
      { tx_hash: '0x' + '41'.repeat(32), block_time: 1790500000, amount_wei: '1000000000000000', points: 1.5, activity: 'wrap', tac_boost: 1.5 },
      { tx_hash: '0x' + '42'.repeat(32), block_time: 1790400000, amount_wei: '2000000000000000', points: 2, activity: 'wrap', tac_boost: 1 },
      { tx_hash: '0x' + '43'.repeat(32), block_time: 1790300000, amount_wei: '289294547313003', points: 1.44, activity: 'cbtcmint' },
    ] });
    const p = await unlocked(chain);
    await p.waitFor(() => /counted/.test(p.text('pvKey')), { label: 'the points row', ...SLOW });
    p.click(p.$('pvKey').querySelector('button[data-a="ptshist"]'));
    await p.waitFor(() => !!p.$('pvKey').querySelector('.pvkh'), { label: 'the history to open', ...SLOW });
    const rows = [...p.$('pvKey').querySelectorAll('.pvkd')];
    assert.equal(rows.length, 3);
    const badges = r => [...r.querySelectorAll('span')].map(s => s.textContent);
    assert.match(rows[0].textContent, /0\.001 ETH/);
    assert.ok(badges(rows[0]).includes('1.5× TAC'), 'the boosted deposit says 1.5× TAC: ' + rows[0].textContent);
    assert.match(rows[1].textContent, /0\.002 ETH/);
    assert.doesNotMatch(rows[1].textContent, /TAC/, 'a 1× boost is no boost, so no badge');
    assert.ok(badges(rows[2]).includes('cBTC bond'), 'the cBTC mint is a bond: ' + rows[2].textContent);
    assert.doesNotMatch(rows[2].textContent, /cBTC lock|TAC/);
    assert.match(p.text('pvKey'), /3 actions counted, 2 wraps and 1 cBTC bond/, 'and so is the summary');
    p.close();
  });

  test('a day a bond stayed posted reads as a bond day, with no amount and no link', async () => {
    const chain = poolChain();
    serve(chain, '/points/', { address: ME, points: 501.5, deposit_count: 2, deposits: [
      { tx_hash: '0x' + 'ab'.repeat(32), block_time: 1790600000, amount_wei: '0', points: 500, activity: 'cbtchold' },
      { tx_hash: '0x' + '41'.repeat(32), block_time: 1790500000, amount_wei: '1000000000000000', points: 1.5, activity: 'wrap' },
    ] });
    const p = await unlocked(chain);
    await p.waitFor(() => /counted/.test(p.text('pvKey')), { label: 'the points row', ...SLOW });
    p.click(p.$('pvKey').querySelector('button[data-a="ptshist"]'));
    await p.waitFor(() => !!p.$('pvKey').querySelector('.pvkh'), { label: 'the history to open', ...SLOW });
    const rows = [...p.$('pvKey').querySelectorAll('.pvkd')];
    assert.equal(rows.length, 2);
    assert.ok([...rows[0].querySelectorAll('span')].some(s => s.textContent === 'bond day'), 'the daily bond credit is named: ' + rows[0].textContent);
    assert.match(rows[0].textContent, /500 points/);
    assert.doesNotMatch(rows[0].textContent, /ETH|wstETH|other/, 'it moved no funds, so it shows no amount');
    assert.equal(rows[0].querySelector('a'), null, 'its hash is not a transaction, so nothing links to an explorer');
    assert.ok(rows[1].querySelector('a'), 'a real deposit still links its transaction');
    p.close();
  });
});

describe('links out to tacit.finance', () => {
  const FARM = { network: 'mainnet', epoch: { active: true, ratePerDayTac: '1107.7776' }, stale: false, pools: [
    { pid: 0, pair: 'TAC/cETH', idle: false, tacPerDayForPool: '553.8888' },
    { pid: 1, pair: 'cETH/cUSD', idle: false, tacPerDayForPool: '332.33328' }] };

  test('the farm teaser sends liquidity to the farm page', async () => {
    const chain = poolChain();
    serve(chain, '/farm/program', FARM);
    const p = await loadPage({ chain, storage: roster });
    await p.connect();
    p.click('pv');
    await p.waitFor(() => !p.$('pvFarm').classList.contains('hide'), { label: 'the farm line', ...SLOW });
    const a = p.$('pvFarm').querySelector('a');
    assert.equal(a.textContent, 'add liquidity on tacit.finance');
    assert.equal(a.getAttribute('href'), 'https://tacit.finance/weld/#farm');
    assert.equal(a.getAttribute('target'), '_blank');
    assert.equal(a.getAttribute('rel'), 'noreferrer');
    p.close();
  });
});

// ---- the TAC airdrop, as tac-airdrop.test.mjs serves it ----
const TACAD = '0x4b4cb98d0c836c2783ac46f0078b904dab533ae8';
const TAC = '0xa1313eb9f3a445606d9583bcac3ebeb56a858279';
const TAC_AS = '0xf0bbe868af10c6c67652a99709bf32048d1aa7194efe3e9a1ef1bde43f94762b';
const AMT = 1234560000000000000n;
const leaf = (i, a, v) => keccak256(keccak256(coder.encode(['uint256', 'address', 'uint256'], [i, a, v])));
const pair = (x, y) => BigInt(x) < BigInt(y) ? keccak256(concat([x, y])) : keccak256(concat([y, x]));
const L0 = leaf(0, '0x' + '11'.repeat(20), 5n), L1 = leaf(7, ME, AMT), L2 = leaf(2, '0x' + '12'.repeat(20), 9n);
const ROOT_AD = pair(pair(L0, L1), L2), PROOF_AD = [L0, L2];

function airdropChain() {
  const chain = new MockChain();
  chain.setNative(A.ACCOUNT, 10n ** 18n);
  chain.setErc20(TAC, TACAD, 10n ** 24n);
  chain.lanes = { [`/proofs/${ME.slice(2, 4)}.json`]: { root: ROOT_AD, claims: { [ME]: { index: 7, amount: AMT.toString(), proof: PROOF_AD } } } };
  const ethCall = chain.ethCall.bind(chain);
  chain.ethCall = (tx, block) => {
    if ((tx.to || '').toLowerCase() === TACAD) {
      const sel = tx.data.slice(2, 10);
      if (sel === '51e75e8b') return ROOT_AD;
      if (sel === '42f81580') return coder.encode(['uint256'], [Math.floor(Date.now() / 1e3) + 86400 * 30]);
      if (sel === '5c975abb') return coder.encode(['bool'], [false]);
      if (sel === '9e34070f') return coder.encode(['bool'], [false]);
      if (sel === '2e7ba6ef' || sel === '4f54d47c' || sel === 'ad8b9781') return '0x';
    }
    return ethCall(tx, block);
  };
  return chain;
}
const card = p => (p.$('adEl').classList.contains('hide') ? '' : p.text('adEl'));

describe('claiming the TAC airdrop privately', () => {
  test('asks first, saying the private route is untested on mainnet, and declining sends nothing', async () => {
    const p = await loadPage({ chain: airdropChain(), hash: null });
    await p.connect();
    await p.settle();
    await p.waitFor(() => /TAC airdrop · until/.test(card(p)), { label: 'the card', ...SLOW });
    // Everything a private claim needs is in place, so only the answer stops it.
    p.chain.answer('0x000000000ed1eabd231be41d93b719056f7febfc', '7da9874f', '0x' + '0'.repeat(64));
    p.window.eval(`cpUse(${JSON.stringify('0x' + '11'.repeat(32))});cpAssets=[{id:"${TAC_AS}",tok:"${TAC}",sym:"cTAC",pub:"TAC",dec:18,scale:10n**10n,icon:""}]`);
    const toAirdrop = () => p.chain.sent.filter(t => (t.to || '').toLowerCase() === TACAD);
    p.queueConfirm(false);
    p.click(p.$('adEl').querySelector('button[data-ad="sh"]'));
    await p.waitFor(() => p.asked.confirm.length > 0 || toAirdrop().length > 0, { label: 'the question or the claim', ...SLOW });
    assert.equal(p.asked.confirm.length, 1, 'one question before anything is built');
    assert.match(p.asked.confirm[0], /Private claims are untested on mainnet/);
    assert.match(p.asked.confirm[0], /Claim privately\?/);
    await p.waitFor(() => /Not claimed\./.test(p.text('stat')), { label: 'the refusal', ...SLOW });
    await p.settle();
    assert.equal(toAirdrop().length, 0, 'nothing reached the airdrop contract');
    assert.equal(p.window.eval(`cpNotes.filter(n=>n.a==="${TAC_AS}").length`), 0, 'and no note was kept for it');
    p.close();
  });
});
