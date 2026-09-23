/**
 * The TAC/ETH farm: a PrecisionFarm streaming TAC to stakers of one Precision
 * band. The page advertises it under the swap form while it pays, and folds
 * its controls into that band's row in the liquidity panel.
 *
 * What is pinned is what costs money if it is wrong: every staking write goes
 * to the farm (not the pool), carries a minimum taken from a preview rather
 * than an exact figure, and asks for a permit made out to the farm. And a farm
 * that has stopped paying is not advertised, while a stake left in it still is.
 */
import { test, describe, after } from 'node:test';
import assert from 'node:assert/strict';
import { A, MockChain, loadPage, fixedRateQuoter, closeAllPages, domainSeparator, word } from './harness.mjs';

after(closeAllPages);

const ETH = 10n ** 18n;
const TAC = '0xA1313eb9f3A445606D9583bcAc3ebeB56a858279';
const FARM = '0x0000003bF4BA0B21f5e0d35119b337F4d4CF82E0';
const POOL = '0x0155358241411dB868BA714aE7c83A27087e3D6E';
const RATE = 6410750000000000n; // 553.8888 TAC/day
const u = v => BigInt(v).toString(16).padStart(64, '0');
const row = (s, a, o = {}) => ({
  i: '1', c: 1, k: 'eip155', p: 'ERC-20', x: true, o: false, f: false,
  a, n: `${s} Token`, s, d: 18, t: '#888', r: 1, u: '', au: '', l: '', desc: '', e: [], v: true, ...o,
});
const sel = d => d.slice(2, 10);
const args = d => '0x' + d.slice(10);
const floorOk = (min, exact) => min < exact && min >= exact * 99n / 100n;

async function open({ fin = Math.floor(Date.now() / 1e3) + 30 * 86400, staked = 0n, earned = 0n, lp = 0n, sims = {}, hash = 'token=ETH&out=TAC' } = {}) {
  const chain = new MockChain();
  chain.registry = [row('ETH', A.ZERO, { p: 'Native' }), row('TAC', TAC), row('USDC', A.USDC, { d: 6 })];
  chain.conviction = [1, 2, 3];
  chain.setNative(A.ACCOUNT, 10n * ETH);
  chain.setErc20(TAC, A.ACCOUNT, 1000n * ETH);
  chain.setToken(TAC, { symbol: 'TAC', decimals: 18, name: 'TAC', domainSeparator: domainSeparator('TAC', '1', TAC) });
  chain.quoteHandler = fixedRateQuoter({ rate: 14000n * ETH, decOut: 18 });
  chain.setPools(A.ZERO, TAC, [{
    pool: POOL, fee: 3000n, liquidity: 2160175009930805825n,
    reserve0: 17503584633155263n, reserve1: 250n * ETH,
    sqrtLow: 3779257685557097674n, sqrtHigh: 3779257685557097674402n, sqrtNow: 119510621510568635147n,
  }]);
  if (lp) chain.setErc20(POOL, A.ACCOUNT, lp);
  chain.zapLp = 10n ** 17n;
  chain.setCode(FARM, '0x6000');
  chain.answer(POOL, '18160ddd', '0x' + u(2160175009930805825n));
  chain.answer(POOL, '443cb4bc', '0x' + u(17503584633155263n));
  chain.answer(POOL, '5a76f25e', '0x' + u(250n * ETH));
  chain.answer(POOL, '2af1f249', '0x' + u(119510621510568635147n));
  const reads = { '7b0a47ee': u(RATE), 'ebe2b12b': u(fin), '817b1cd2': u(staked), '98807d84': u(staked), '008cc262': u(earned),
    // Simulations of the writes; a floor-free exit reports what it would pay.
    '8703a0d8': u(10n ** 17n), '51291e77': u(10n ** 17n), '9376f34e': u(10n ** 17n), '6d15c09b': u(10n ** 17n), 'ddd9f3fb': u(10n ** 17n),
    '4e71d92d': '', 'e9fad8ee': '', 'a694fc3a': '', 'ecd9ba82': '', '2e1a7d4d': '', ...sims };
  for (const [s, v] of Object.entries(reads)) chain.answer(FARM, s, '0x' + v);
  const p = await loadPage({ chain, hash });
  await p.connect({ pin: false });
  await p.settle();
  return p;
}
const farmTx = p => p.chain.sentTo(FARM).at(-1);
const bandRow = p => [...p.$('lqList').querySelectorAll('.lqrow')].find(r => r.dataset.pool.toLowerCase() === POOL.toLowerCase());
async function openBand(p) {
  p.click(p.$('pfEl').querySelector('[data-pf="go"]'));
  await p.waitFor(() => bandRow(p)?.querySelector('.pfb'), { label: 'the farm block on the band' });
  return bandRow(p);
}
async function addForm(p, r, { zap = false, eth = '', tac = '' }) {
  p.click(r.querySelector('[data-act="a"]'));
  const box = r.querySelector('.lqadd');
  if (zap) { box.querySelector('.lqz').checked = true; box.querySelector('.lqz').dispatchEvent(new p.window.Event('change', { bubbles: true })); }
  const [i0, i1] = box.querySelectorAll('.lqin');
  for (const [el, v] of [[i0, eth], [i1, tac]]) if (v) { el.value = v; el.dispatchEvent(new p.window.Event('input', { bubbles: true })); }
  await p.settle();
  return box;
}

describe('the TAC/ETH farm line', () => {
  test('a paying farm shows its daily TAC, its APR for a 1 ETH entry and its end', async () => {
    const p = await open();
    await p.waitFor(() => p.visible('pfEl'), { label: 'the farm line' });
    const t = p.text('pfEl');
    assert.match(t, /TAC\/ETH farm · 554 TAC\/day/);
    // Nothing staked yet: 553.8888 x 365 x (ETH per TAC) on a 1 ETH entry.
    const apr = Math.round(553.8888 * 365 * (1 / (119510621510568635147 / 1e18) ** 2) * 100).toLocaleString();
    // A percentage means nothing without the entry it assumes, and a phone has no
    // tooltip to reveal it, so the basis rides on the line itself.
    assert.ok(t.includes(`~${apr}% APR on 1 ETH`), t);
    const tip = p.$('pfEl').title;
    assert.ok(tip.includes(`~${apr}% APR on 1 ETH`) && /until \w+/.test(tip), tip);
    assert.equal(p.$('pfEl').querySelector('[data-pf="go"]').textContent, 'Farm');
    assert.ok(p.$('pfEl').querySelector('svg.adic'), 'the pair shows its ETH logo beside TAC');
    p.close();
  });

  test('a farm that has stopped paying is not advertised', async () => {
    const p = await open({ fin: Math.floor(Date.now() / 1e3) - 60 });
    await p.settle();
    assert.ok(!p.visible('pfEl'));
    p.close();
  });

  test('an ended farm still surfaces a stake left in it, with its earnings', async () => {
    const p = await open({ fin: Math.floor(Date.now() / 1e3) - 60, staked: ETH, earned: 12n * ETH });
    await p.waitFor(() => p.visible('pfEl'), { label: 'the ended line' });
    assert.match(p.text('pfEl'), /ended · your stake is still here · earned 12 TAC/);
    assert.ok(p.$('pfEl').querySelector('[data-pf="cl"]'));
    p.close();
  });

  test('claim from the line calls the farm', async () => {
    const p = await open({ staked: ETH, earned: 3n * ETH });
    await p.waitFor(() => p.$('pfEl').querySelector('[data-pf="cl"]'), { label: 'the claim button' });
    p.click(p.$('pfEl').querySelector('[data-pf="cl"]'));
    await p.waitFor(() => farmTx(p), { label: 'the claim' });
    assert.equal(sel(farmTx(p).data), '4e71d92d');
    p.close();
  });
});

describe('the farm on its band', () => {
  test('Farm opens the band with the farm block and staking ticked', async () => {
    const p = await open();
    const r = await openBand(p);
    assert.match(r.querySelector('.pfb').textContent, /Farm · 554 TAC\/day/);
    assert.ok(r.querySelector('.lqadd .pfk').checked);
    p.close();
  });

  test('a one-sided ETH deposit zaps through the farm with a bounded minimum', async () => {
    const p = await open();
    const r = await openBand(p);
    await addForm(p, r, { zap: true, eth: '0.01' });
    p.click(r.querySelector('[data-act="ac"]'));
    await p.waitFor(() => farmTx(p), { label: 'the zap' });
    const tx = farmTx(p);
    assert.equal(sel(tx.data), '8703a0d8');
    assert.equal(BigInt(tx.value), 10n ** 16n);
    assert.ok(floorOk(word(args(tx.data), 1), 10n ** 17n), 'minShares comes from the preview, less slippage');
    assert.equal(p.chain.sentTo(POOL).length, 0, 'nothing goes to the pool directly');
    p.close();
  });

  test('a one-sided TAC deposit signs a permit made out to the farm', async () => {
    const p = await open();
    const r = await openBand(p);
    await addForm(p, r, { zap: true, tac: '50' });
    p.click(r.querySelector('[data-act="ac"]'));
    await p.waitFor(() => farmTx(p), { label: 'the zap' });
    assert.equal(p.chain.signed.length, 1);
    assert.equal(p.chain.signed[0].typedData.message.spender.toLowerCase(), FARM.toLowerCase());
    assert.equal(p.chain.signed[0].typedData.message.value, String(50n * ETH));
    const tx = farmTx(p);
    assert.equal(sel(tx.data), '51291e77');
    assert.equal(word(args(tx.data), 0), 50n * ETH);
    assert.ok(floorOk(word(args(tx.data), 2), 10n ** 17n));
    p.close();
  });

  test('a two-sided deposit stakes both through the farm, ETH as value', async () => {
    const p = await open();
    const r = await openBand(p);
    // Typing one side fills the other at the pool's ratio.
    const box = await addForm(p, r, { eth: '0.01' });
    const tac = box.querySelectorAll('.lqin')[1];
    await p.waitFor(() => tac.value, { label: 'the mirrored TAC amount' });
    p.click(r.querySelector('[data-act="ac"]'));
    await p.waitFor(() => farmTx(p), { label: 'the add' });
    const tx = farmTx(p);
    assert.equal(sel(tx.data), 'ddd9f3fb', 'TAC is permitted rather than approved');
    assert.equal(BigInt(tx.value), 10n ** 16n);
    const [w, f = ''] = tac.value.split('.');
    assert.equal(word(args(tx.data), 0), BigInt(w + f.padEnd(18, '0')));
    p.close();
  });

  test('unticking the farm leaves a plain deposit to the pool', async () => {
    const p = await open();
    const r = await openBand(p);
    const box = await addForm(p, r, { eth: '0.01', tac: '142.8' });
    box.querySelector('.pfk').checked = false;
    p.click(r.querySelector('[data-act="ac"]'));
    await p.waitFor(() => p.chain.sentTo(POOL).length, { label: 'the plain add' });
    assert.equal(p.chain.sentTo(FARM).length, 0);
    p.close();
  });

  test('wallet LP is staked with a permit to the farm', async () => {
    const p = await open({ lp: 5n * 10n ** 17n });
    p.chain.setToken(POOL, { symbol: 'pLP', decimals: 18, name: 'Precision LP', domainSeparator: domainSeparator('Precision LP', '1', POOL) });
    const r = await openBand(p);
    await p.waitFor(() => r.querySelector('[data-pf="st"]'), { label: 'the stake button' });
    p.click(r.querySelector('[data-pf="st"]'));
    await p.waitFor(() => farmTx(p), { label: 'the stake' });
    assert.equal(sel(farmTx(p).data), 'ecd9ba82');
    assert.equal(word(args(farmTx(p).data), 0), 5n * 10n ** 17n);
    p.close();
  });

  test('part of a wallet LP balance can be staked, like part of a stake can be withdrawn', async () => {
    const p = await open({ lp: 5n * 10n ** 17n });
    const r = await openBand(p);
    await p.waitFor(() => r.querySelector('.pfsp'), { label: 'the stake amount picker' });
    r.querySelector('.pfsp').value = '25';
    r.querySelector('.pfsp').dispatchEvent(new p.window.Event('change'));
    assert.match(r.querySelector('[data-pf="st"]').textContent, /Stake 0\.125 LP/, 'the button says what it will stake');
    p.click(r.querySelector('[data-pf="st"]'));
    await p.waitFor(() => farmTx(p), { label: 'the stake' });
    assert.equal(sel(farmTx(p).data), 'a694fc3a', 'a plain stake, no permit is set up here');
    assert.equal(word(args(farmTx(p).data), 0), 125n * 10n ** 15n, 'a quarter of the balance');
    p.close();
  });

  test('withdrawing as ETH simulates the exit and sends it with a floor', async () => {
    const p = await open({ staked: ETH, earned: ETH, sims: { '6ae36ea7': u(3n * 10n ** 16n) } });
    const r = await openBand(p);
    await p.waitFor(() => r.querySelector('.pfo'), { label: 'the withdraw controls' });
    assert.match(r.querySelector('.pfb').textContent, /staked .* ETH \+ .* TAC · earned 1 TAC/);
    r.querySelector('.pfo').value = 'eth';
    p.click(r.querySelector('[data-pf="wd"]'));
    await p.waitFor(() => farmTx(p), { label: 'the exit' });
    const d = args(farmTx(p).data);
    assert.equal(sel(farmTx(p).data), '6ae36ea7');
    assert.equal(word(d, 0), 1n, 'toETH');
    assert.ok(floorOk(word(d, 1), 3n * 10n ** 16n));
    p.close();
  });

  test('withdrawing as both assets floors each side', async () => {
    const p = await open({ staked: ETH, sims: { bccbe38a: u(2n * 10n ** 16n) + u(280n * ETH) } });
    const r = await openBand(p);
    await p.waitFor(() => r.querySelector('.pfo'), { label: 'the withdraw controls' });
    p.click(r.querySelector('[data-pf="wd"]'));
    await p.waitFor(() => farmTx(p), { label: 'the exit' });
    const d = args(farmTx(p).data);
    assert.equal(sel(farmTx(p).data), 'bccbe38a');
    assert.ok(floorOk(word(d, 0), 2n * 10n ** 16n) && floorOk(word(d, 1), 280n * ETH));
    p.close();
  });

  test('a staked add refuses a recipient, since the farm credits the sender', async () => {
    const p = await open();
    const r = await openBand(p);
    p.type('rc', '0x' + '12'.repeat(20));
    await addForm(p, r, { zap: true, eth: '0.01' });
    p.click(r.querySelector('[data-act="ac"]'));
    await p.waitFor(() => /credited to your own wallet/.test(p.text('stat')), { label: 'the refusal' });
    await p.settle();
    assert.equal(p.chain.sentTo(FARM).length, 0);
    p.close();
  });

  test('Farm from another pair moves the pickers to ETH / TAC as well as the panel', async () => {
    const p = await open({ hash: 'token=ETH&out=USDC' });
    await p.waitFor(() => p.visible('pfEl'), { label: 'the farm line' });
    await openBand(p);
    assert.match(p.text('toPick'), /TAC/);
    assert.match(p.text('fromPick'), /ETH/);
    p.close();
  });

  test('#farm links straight to the band', async () => {
    const p = await open({ hash: 'farm' });
    await p.waitFor(() => bandRow(p)?.querySelector('.pfb'), { label: 'the farm block from the link' });
    assert.match(p.text('toPick'), /TAC/);
    assert.ok(bandRow(p).querySelector('.lqadd .pfk'));
    p.close();
  });

  test('half the stake withdraws as ETH through withdrawTo, leaving the rest staked', async () => {
    const p = await open({ staked: ETH, earned: ETH, sims: { '47d1eebd': u(15n * 10n ** 15n) } });
    const r = await openBand(p);
    await p.waitFor(() => r.querySelector('.pfp'), { label: 'the amount picker' });
    r.querySelector('.pfp').value = '50';
    r.querySelector('.pfo').value = 'eth';
    p.click(r.querySelector('[data-pf="wd"]'));
    await p.waitFor(() => farmTx(p), { label: 'the partial exit' });
    const d = args(farmTx(p).data);
    assert.equal(sel(farmTx(p).data), '47d1eebd');
    assert.equal(word(d, 0), 1n, 'toETH');
    assert.equal(word(d, 1), ETH / 2n, 'half the stake');
    assert.ok(floorOk(word(d, 2), 15n * 10n ** 15n));
    p.close();
  });

  test('a quarter of the stake comes back as LP with plain withdraw', async () => {
    const p = await open({ staked: ETH });
    const r = await openBand(p);
    await p.waitFor(() => r.querySelector('.pfp'), { label: 'the amount picker' });
    r.querySelector('.pfp').value = '25';
    r.querySelector('.pfo').value = 'lp';
    p.click(r.querySelector('[data-pf="wd"]'));
    await p.waitFor(() => farmTx(p), { label: 'the unstake' });
    assert.equal(sel(farmTx(p).data), '2e1a7d4d');
    assert.equal(word(args(farmTx(p).data), 0), ETH / 4n);
    p.close();
  });

  test('a partial exit to both assets floors each side of withdrawAndRemove', async () => {
    const p = await open({ staked: ETH, sims: { bd8196a9: u(10n ** 16n) + u(140n * ETH) } });
    const r = await openBand(p);
    await p.waitFor(() => r.querySelector('.pfp'), { label: 'the amount picker' });
    r.querySelector('.pfp').value = '75';
    p.click(r.querySelector('[data-pf="wd"]'));
    await p.waitFor(() => farmTx(p), { label: 'the partial exit' });
    const d = args(farmTx(p).data);
    assert.equal(sel(farmTx(p).data), 'bd8196a9');
    assert.equal(word(d, 0), ETH * 3n / 4n);
    assert.ok(floorOk(word(d, 1), 10n ** 16n) && floorOk(word(d, 2), 140n * ETH));
    p.close();
  });

  test('an ended farm offers no staking on its band', async () => {
    const p = await open({ fin: Math.floor(Date.now() / 1e3) - 60, staked: ETH });
    p.click(p.$('pfEl').querySelector('[data-pf="go"]'));
    await p.waitFor(() => bandRow(p)?.querySelector('.pfb'), { label: 'the farm block' });
    const r = bandRow(p);
    assert.match(r.querySelector('.pfb').textContent, /Farm ended/);
    assert.ok(!r.querySelector('.pfk'), 'no stake box once it has stopped paying');
    assert.ok(r.querySelector('[data-pf="wd"]'), 'the stake can still come out');
    p.close();
  });
});
