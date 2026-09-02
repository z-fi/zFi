import { test, describe, after } from 'node:test';
import assert from 'node:assert/strict';
import { A, MockChain, loadPage, fixedRateQuoter, closeAllPages } from './harness.mjs';

after(closeAllPages);

const ETH = 10n ** 18n;
const USDC = 10n ** 6n;

async function setup() {
  const chain = new MockChain();
  chain.setNative(A.ACCOUNT, 100n * ETH);
  chain.setErc20(A.USDC, A.ACCOUNT, 500_000n * USDC);
  chain.setErc20(A.USDT, A.ACCOUNT, 500_000n * USDC);
  chain.quoteHandler = fixedRateQuoter({ rate: 3000n * ETH });
  const page = await loadPage({ chain });
  await page.connect();
  return page;
}

const count = (chain, method, addr) => chain.log.filter(
  e => e.method === method
    && (!addr || String(e.params?.[0] || '').toLowerCase() === addr.toLowerCase()),
).length;

describe('a quote does not re-ask what it already knows', () => {
  test('the block number is read once, not once per pair', async () => {
    const p = await setup();
    const { chain } = p;

    p.pickToken('fromSel', 'ETH');
    p.pickToken('toSel', 'USDC');
    await p.typeAmount('amt', '1');
    const afterFirst = count(chain, 'eth_blockNumber');
    assert.ok(afterFirst >= 1, 'the first quote must pin a block');

    p.pickToken('toSel', 'USDT');
    await p.typeAmount('amt', '2');
    await p.settle();

    assert.equal(count(chain, 'eth_blockNumber'), afterFirst,
      'changing the pair must not re-read a number that is not about the pair');
    p.close();
  });

  test('the orderbook contracts are proved deployed once, not per quote', async () => {
    const p = await setup();
    const { chain } = p;

    p.pickToken('fromSel', 'ETH');
    p.pickToken('toSel', 'USDC');
    await p.typeAmount('amt', '1');

    const view = count(chain, 'eth_getCode', A.SBVIEW);
    const exec = count(chain, 'eth_getCode', A.SWAPBOL);
    const dutch = count(chain, 'eth_getCode', A.DUTCH);
    assert.ok(view >= 1 && exec >= 1, 'the first quote must establish the book is real');

    p.pickToken('toSel', 'USDT');
    await p.typeAmount('amt', '2');
    await p.typeAmount('amt', '3');
    await p.settle();

    assert.equal(count(chain, 'eth_getCode', A.SBVIEW), view, 'lens re-read');
    assert.equal(count(chain, 'eth_getCode', A.SWAPBOL), exec, 'executor re-read');
    assert.equal(count(chain, 'eth_getCode', A.DUTCH), dutch, 'Dutch board re-read');
    p.close();
  });

  test('a contract that is NOT there yet is asked about again', async () => {
    const p = await setup();
    const { chain } = p;
    chain.code.delete(A.SWAPBOL.toLowerCase());

    p.pickToken('fromSel', 'ETH');
    p.pickToken('toSel', 'USDC');
    await p.typeAmount('amt', '1');
    const first = count(chain, 'eth_getCode', A.SWAPBOL);
    assert.ok(first >= 1);

    // A MISS IS CACHED, BUT ONLY BRIEFLY. Re-asking on every quote is how a
    // dead address costs a round trip per keystroke; never re-asking is how a
    // contract deployed later stays invisible for the life of the session. The
    // page holds a miss for CODE_MISS_TTL, so the clock is what this asserts
    // against - a second quote inside the window must NOT re-ask, and one past
    // it must.
    p.pickToken('toSel', 'USDT');
    await p.typeAmount('amt', '2');
    await p.settle();
    assert.equal(count(chain, 'eth_getCode', A.SWAPBOL), first,
      'a miss re-asked inside its TTL - that is a round trip per keystroke');

    const real = p.window.Date.now;
    p.window.Date.now = () => real.call(Date) + 61_000;
    try {
      p.pickToken('toSel', 'USDC');
      await p.typeAmount('amt', '3');
      await p.settle();
      assert.ok(count(chain, 'eth_getCode', A.SWAPBOL) > first,
        'an absent contract must be re-checked, or a later deploy is invisible');
    } finally {
      p.window.Date.now = real;
    }
    p.close();
  });
});
