import { test, describe } from 'node:test';
import assert from 'node:assert/strict';
import { A, MockChain, loadPage, fixedRateQuoter, closeAllPages } from './harness.mjs';

const ETH = 10n ** 18n;
const COIN = '0x00000000000000000000000000000000000c0a01';

const row = (s, a, o = {}) => ({
  i: '1', c: 1, k: 'eip155', p: 'ERC-20', x: true, o: false, f: false,
  a, n: `${s} Token`, s, d: 18, t: '#888', r: 1, u: '', au: '', l: '', desc: '', e: [], v: true, ...o,
});

/**
 * Fees a launched coin has earned but nobody has swept.
 *
 * They accrue in the pool and stay there until somebody calls `collectFees`,
 * and for the first nineteen markets nobody ever did - half an ether sat
 * unclaimed, one creator owed 0.41 of it, with nothing anywhere telling them
 * the money existed. The contract side worked perfectly the whole time. This
 * is the missing half.
 */
async function open_({ owed = 500n * ETH / 1000n, connect = true, launched = true } = {}) {
  const rows = [row('ETH', A.ZERO, { p: 'Native' }), row('ZCAT', COIN), row('USDC', A.USDC, { d: 6 })];
  const chain = new MockChain();
  chain.registry = rows;
  chain.conviction = [1, 2, 3];
  chain.setNative(A.ACCOUNT, 10n * ETH);
  chain.quoteHandler = fixedRateQuoter({ rate: 3000n * ETH });
  if (launched) chain.setLaunchFees({ [COIN]: { owed0: owed, owed1: 1000n * ETH } });
  const p = await loadPage({ chain, hash: null });
  if (connect) await p.connect({ pin: false });
  p.$('toSel').value = String([...p.$('toSel').options].findIndex(o => o.textContent === 'ZCAT'));
  p.$('toSel').dispatchEvent(new p.window.Event('change'));
  await p.settle();
  return p;
}

const COIN2 = '0x00000000000000000000000000000000000c0a02';
const POOL1 = '0x00000000000000000000000000000000000b0001';
const POOL2 = '0x00000000000000000000000000000000000b0002';

/* The creator path: the wallet is connected, the coin is NOT selected, and the
 * page has to volunteer the information. */
async function openMine({ many = false, creator = A.ACCOUNT } = {}) {
  const rows = [row('ETH', A.ZERO, { p: 'Native' }), row('USDC', A.USDC, { d: 6 })];
  const chain = new MockChain();
  chain.registry = rows;
  chain.conviction = [1, 2];
  chain.setNative(A.ACCOUNT, 10n * ETH);
  chain.quoteHandler = fixedRateQuoter({ rate: 3000n * ETH });
  chain.setToken(COIN, { symbol: 'ZCAT', decimals: 18, name: 'Zero Cat' });
  chain.setToken(COIN2, { symbol: 'BORGZ', decimals: 18, name: 'borgz' });
  const pools = [{ pool: POOL1, token: COIN }];
  const fees = { [COIN]: { owed0: 512407000000000000n, pool: POOL1 } };
  if (many) {
    pools.push({ pool: POOL2, token: COIN2 });
    fees[COIN2] = { owed0: 100000000000000000n, pool: POOL2 };
  }
  chain.setLaunched(pools);
  chain.setLaunchFees(fees);
  chain.creatorOfAnswer = creator;
  const p = await loadPage({ chain, hash: null });
  await p.connect({ pin: false });
  await p.settle();
  return p;
}

const line = p => p.$('fcEl');
const shown = p => !line(p).classList.contains('hide');

describe('collecting a launched coin\'s fees', () => {
  test('the page says how much is waiting', async () => {
    const p = await open_({ owed: 512407000000000000n }); // what ZCAT actually held
    assert.ok(shown(p), 'a coin with half an ether of fees showed nothing');
    // 80% of the pool's ether side is the creator's; the rest is treasury and tithe.
    assert.match(line(p).textContent, /0\.4099/, `wrong amount: ${line(p).textContent}`);
    p.close();
  });

  test('a coin that was never launched here shows nothing', async () => {
    const p = await open_({ launched: false });
    assert.ok(!shown(p), 'offered to collect fees from an unrelated token');
    p.close();
  });

  test('dust is not offered', async () => {
    // Less than the gas to sweep it. An offer to collect 0.000001 ETH reads as
    // broken rather than as precise.
    const p = await open_({ owed: 1000n });
    assert.ok(!shown(p), 'offered to collect dust');
    p.close();
  });

  test('collecting sends collectFees for that token', async () => {
    const p = await open_();
    p.$('fcGo').click();
    await p.settle();
    const sent = p.chain.lastSent;
    assert.ok(sent, 'nothing was sent');
    assert.equal(sent.to.toLowerCase(), '0x0000002fc8e77585a008aa45d78a71ad36293aee');
    assert.ok(sent.data.startsWith('0xa480ca79'), `wrong function: ${sent.data.slice(0, 10)}`);
    assert.ok(sent.data.toLowerCase().includes(COIN.slice(2)), 'swept the wrong token');
    assert.equal(BigInt(sent.value || '0x0'), 0n, 'sent ether with a collect');
    p.close();
  });

  /* A creator opening the dapp to swap something else must still find out.
   * Selection-driven only, they never would - which is how half an ether sat
   * unswept across nineteen markets. */
  test('a creator is told without selecting their own coin', async () => {
    const p = await openMine();
    assert.ok(shown(p), 'a creator saw nothing on a plain ETH/USDC screen');
    assert.match(line(p).textContent, /ZCAT/, `did not name the coin: ${line(p).textContent}`);
    assert.match(line(p).textContent, /0\.4099/, line(p).textContent);
    p.close();
  });

  test('several coins aggregate into one sweep', async () => {
    // A few creators here run four or five markets. One line and one
    // transaction beats four of each, and collectFeesMany is cheaper too.
    const p = await openMine({ many: true });
    assert.match(line(p).textContent, /2 of your coins/, line(p).textContent);
    assert.equal(p.$('fcGo').textContent, 'Collect all');
    p.$('fcGo').click();
    await p.settle();
    const sent = p.chain.lastSent;
    assert.ok(sent.data.startsWith('0xc296057e'), `not collectFeesMany: ${sent.data.slice(0, 10)}`);
    assert.ok(sent.data.toLowerCase().includes(COIN.slice(2)), 'first coin missing');
    assert.ok(sent.data.toLowerCase().includes(COIN2.slice(2)), 'second coin missing');
    p.close();
  });

  test('someone else\'s launches are not offered as yours', async () => {
    const p = await openMine({ creator: '0x00000000000000000000000000000000deadbeef' });
    assert.ok(!shown(p), "claimed another wallet's fees as the visitor's own");
    p.close();
  });

  test('a visitor with no wallet is asked to connect, not silently ignored', async () => {
    const p = await open_({ connect: false });
    assert.ok(shown(p), 'the amount is public information and should show unconnected');
    p.close();
  });

  test('a failed collect does not leave the button dead', async () => {
    const p = await open_();
    p.chain.collectReverts = true;
    p.$('fcGo').click();
    await p.settle();
    assert.equal(p.$('fcGo').disabled, false, 'the button stayed disabled after a failure');
    assert.equal(p.$('fcGo').textContent, 'Collect');
    p.close();
  });

  /* The line shows whenever a launched coin is merely SELECTED, so most of the
   * time the reader is not the creator - and "in creator fees" next to a
   * Collect button reads as an offer of their own money. */
  test("names the beneficiary when the money is not the reader's", async () => {
    const p = await open_();
    p.chain.creatorOfAnswer = '0x00000000000000000000000000000000deadbeef';
    await p.settle();
    p.$('toSel').dispatchEvent(new p.window.Event('change'));
    await p.settle();
    assert.match(line(p).textContent, /fees for this coin's creator/, line(p).textContent);
    p.close();
  });

  test('and says plainly it is yours when it is', async () => {
    const p = await open_();
    p.chain.creatorOfAnswer = A.ACCOUNT;
    await p.settle();
    p.$('toSel').dispatchEvent(new p.window.Event('change'));
    await p.settle();
    const t = line(p).textContent;
    assert.ok(/in creator fees/.test(t) && !/for this coin's creator/.test(t), t);
    p.close();
  });
});