/**
 * Edge cases from the final v0.3 review. Each case failed on the page before its fix.
 */
import { test, describe, after } from 'node:test';
import assert from 'node:assert/strict';
import { A, MockChain, loadPage, fixedRateQuoter, closeAllPages } from './harness.mjs';

after(closeAllPages);

const ETH = 10n ** 18n;

describe('a decimal comma is never read as a thousands separator', () => {
  test('flipping an amount typed as 1,5 carries 1.5 across, not 15', async () => {
    const chain = new MockChain();
    chain.setNative(A.ACCOUNT, 10n * ETH);
    chain.quoteHandler = fixedRateQuoter({ rate: 3000n * ETH });
    const p = await loadPage({ chain });
    await p.connect();
    p.window.eval('outAmt.value="1,5"');
    p.click('flip');
    await p.settle();
    assert.equal(p.value('amt'), '1,5', 'the text is carried as typed');
    assert.equal(p.window.eval('pU(amt.value,18)'), 15n * 10n ** 17n, 'and read as 1.5');
    p.close();
  });

  test('a cause goal typed as 1,500 is refused rather than read as 1500 or 1.5', async () => {
    const chain = new MockChain();
    chain.setNative(A.ACCOUNT, 10n ** 19n);
    const p = await loadPage({ chain });
    await p.connect();
    p.click('ln');
    p.select('lnKind', 'cause');
    await p.settle();
    p.type('lnName', 'Clean Water');
    p.type('lnSym', 'WATER');
    p.type('lnGoal', '1,500');
    p.type('lnDays', '30');
    await p.settle();
    p.click('lnGo');
    await p.settle();
    assert.equal(p.chain.sent.length, 0, 'nothing is launched');
    p.close();
  });
});

describe('deadlines follow the chain clock', () => {
  test('a device clock an hour slow is corrected from the chain, once', async () => {
    const real = Math.floor(Date.now() / 1000);
    const chain = new MockChain({ blockTime: real + 3600 });
    const p = await loadPage({ chain, walletless: true });
    await p.waitFor(() => p.window.eval('tSk') !== 0, { label: 'the clock anchor', timeout: 8000 });
    const now = p.window.eval('nowS()');
    assert.ok(Math.abs(now - (real + 3600)) < 30, `nowS ${now} follows the chain, not the device`);
    p.close();
  });

  test('a device clock within 90 seconds is left alone', async () => {
    const chain = new MockChain({ blockTime: Math.floor(Date.now() / 1000) + 20 });
    const p = await loadPage({ chain, walletless: true });
    await new Promise(r => setTimeout(r, 3000));
    assert.equal(p.window.eval('tSk'), 0);
    p.close();
  });
});

describe('swap and send links on every chain', () => {
  const open = async hash => {
    const p = await loadPage({ chain: new MockChain({ autoConnected: true }), hash });
    await p.settle();
    await new Promise(r => setTimeout(r, 1200));
    await p.settle();
    return p;
  };
  const snap = p => JSON.parse(p.window.eval('JSON.stringify({chain:CHAIN_ID,tab,from:TOKENS[fromSel.value]?.sym,to:TOKENS[toSel.value]?.sym,amt:amt.value,out:outAmt.value,rc:rc.value,dly:dly.value})'));
  for (const [chain, stable] of [[1, 'USDC'], [8453, 'USDC'], [4663, 'USDG']]) {
    test(`a swap link lands on chain ${chain}`, async () => {
      const p = await open(`chain=${chain}&token=ETH&out=${stable}&amount=0.5`);
      const s = snap(p);
      assert.deepEqual([s.chain, s.tab, s.from, s.to, s.amt], [chain, 'swap', 'ETH', stable, '0.5']);
      p.close();
    });
    test(`an exact-out swap link lands on chain ${chain}`, async () => {
      const p = await open(`chain=${chain}&token=ETH&out=${stable}&amount=100&exactOut=1`);
      const s = snap(p);
      assert.deepEqual([s.chain, s.from, s.to, s.out, s.amt], [chain, 'ETH', stable, '100', '']);
      p.close();
    });
    test(`a send link lands on chain ${chain}`, async () => {
      const p = await open(`chain=${chain}&tab=send&token=${stable}&to=${A.OTHER}&amount=5&lock=1d`);
      const s = snap(p);
      assert.deepEqual([s.chain, s.tab, s.from, s.amt, s.rc.toLowerCase(), s.dly], [chain, 'send', stable, '5', A.OTHER.toLowerCase(), '86400']);
      p.close();
    });
  }
});
