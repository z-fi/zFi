/**
 * How a swap gets the right to move a token when the easy path breaks.
 *
 * The page prefers a gasless permit, then Permit2, then an atomic batch, then
 * plain approvals. Each of the first three can be offered and then fail, and
 * each used to be a dead end: the next method was never tried, so the same
 * doomed path came back on every retry.
 */
import { test, describe, after } from 'node:test';
import assert from 'node:assert/strict';
import {
  A, SEL, MockChain, loadPage, fixedRateQuoter, domainSeparator, selectorOf, closeAllPages,
} from './harness.mjs';

after(closeAllPages);

const ETH = 10n ** 18n;
const USDC = 10n ** 6n;
const SUPPORTED = { '0x1': { atomic: { status: 'supported' } } };

async function erc20Swap(prep = () => {}) {
  const chain = new MockChain();
  chain.setNative(A.ACCOUNT, ETH);
  chain.setErc20(A.USDC, A.ACCOUNT, 50_000n * USDC);
  chain.quoteHandler = fixedRateQuoter({ rate: ETH / 3000n, decIn: 6, decOut: 18 });
  prep(chain);
  const p = await loadPage({ chain });
  await p.connect();
  p.click('flip');
  await p.settle();
  await p.typeAmount('amt', '3000');
  return p;
}

const withPermit = c => c.setToken(A.USDC, {
  symbol: 'USDC', decimals: 6, name: 'USD Coin', domainSeparator: domainSeparator('USD Coin', '1', A.USDC),
});

// The wallet or chain answers `m` with `fn`, everything else as before.
const intercept = (c, fn) => {
  const d = c.dispatch.bind(c);
  c.dispatch = async (m, a) => { const r = await fn(m, a, d); return r === undefined ? d(m, a) : r; };
};

const isApprove = t => selectorOf(t.data || '0x') === SEL.APPROVE;

describe('a permit that will not execute', () => {
  test('falls through to an approval instead of failing every retry', async () => {
    const p = await erc20Swap(c => {
      withPermit(c);
      // A contract wallet, or a token whose permit is paused, signs happily and
      // then reverts inside the router.
      intercept(c, (m, a) => {
        if (m === 'eth_call' && (a[0].to || '').toLowerCase() === A.ZROUTER.toLowerCase()
          && selectorOf(a[0].data) === SEL.RPERMIT) throw Object.assign(Error('execution reverted'), { code: 3 });
      });
    });
    p.click('swap');
    await p.waitFor(() => /Done/.test(p.text('stat')), { label: 'settled', timeout: 20000 });
    assert.equal(p.chain.signed.length, 1, 'the permit was tried');
    assert.ok(p.chain.sent.some(isApprove), 'then a plain approval');
    assert.ok(!p.chain.lastSent.data.includes('11'.repeat(32)), 'the swap carries no dead permit');
    p.close();
  });

  test('a contract account is not asked for a permit it cannot honour', async () => {
    const p = await erc20Swap(c => { withPermit(c); c.code.set(A.ACCOUNT.toLowerCase(), '0x6080604052'); });
    p.click('swap');
    await p.waitFor(() => /Done/.test(p.text('stat')), { label: 'settled', timeout: 20000 });
    assert.equal(p.chain.signed.length, 0, 'no signature prompt');
    assert.ok(p.chain.sent.some(isApprove));
    p.close();
  });

  test('an EIP-7702 account still gets its permit', async () => {
    const p = await erc20Swap(c => { withPermit(c); c.code.set(A.ACCOUNT.toLowerCase(), '0xef0100' + '11'.repeat(20)); });
    p.click('swap');
    await p.waitFor(() => p.chain.sent.length > 0, { label: 'swap tx' });
    assert.equal(p.chain.signed[0]?.typedData.primaryType, 'Permit');
    p.close();
  });
});

describe('a batch the wallet will not run', () => {
  test('an unsupported batch is sent as steps, and batching is not offered again', async () => {
    const p = await erc20Swap(c => {
      c.capabilities = SUPPORTED;
      intercept(c, m => { if (m === 'wallet_sendCalls') throw Object.assign(Error('Unsupported non-optional capability'), { code: 5700 }); });
    });
    p.click('swap');
    await p.waitFor(() => /Done/.test(p.text('stat')), { label: 'settled', timeout: 20000 });
    assert.equal(p.chain.batches.length, 0);
    assert.ok(p.chain.sent.some(isApprove), 'the approval went on its own');
    assert.equal(p.chain.lastSent.to.toLowerCase(), A.ZROUTER.toLowerCase(), 'then the swap');
    assert.equal(p.window.eval('noBatch'), 1);
    p.close();
  });

  test('declining the smart-account upgrade is remembered for the session', async () => {
    const p = await erc20Swap(c => {
      c.capabilities = { '0x1': { atomic: { status: 'ready' } } };
      intercept(c, m => { if (m === 'wallet_sendCalls') throw Object.assign(Error('User rejected the request'), { code: 4001 }); });
    });
    p.click('swap');
    await p.settle();
    assert.equal(p.text('stat'), '', 'a decline is not an error');
    assert.equal(p.window.eval('noBatch'), 1, 'and the upgrade is not pushed again');
    p.close();
  });

  test('a plain decline of a batch keeps batching on offer', async () => {
    const p = await erc20Swap(c => {
      c.capabilities = SUPPORTED;
      intercept(c, m => { if (m === 'wallet_sendCalls') throw Object.assign(Error('User rejected the request'), { code: 4001 }); });
    });
    p.click('swap');
    await p.settle();
    assert.equal(p.window.eval('noBatch'), 0);
    p.close();
  });

  test('a 600 (partial revert) is a failure, not a wait', async () => {
    const p = await erc20Swap(c => {
      c.capabilities = SUPPORTED;
      c.callsStatusHandler = () => ({ status: 600, receipts: [] });
    });
    p.click('swap');
    await p.waitFor(() => /batch failed/.test(p.text('stat')), { label: 'failure surfaced' });
    p.close();
  });

  test('a wallet that cannot report the batch stops being asked', async () => {
    const p = await erc20Swap(c => {
      c.capabilities = SUPPORTED;
      c.callsStatusHandler = () => { throw Object.assign(Error('Unknown bundle id'), { code: 5730 }); };
    });
    p.click('swap');
    await p.waitFor(() => /cannot report its status/.test(p.text('stat')), { label: 'gave up', timeout: 20000 });
    p.close();
  });

  test('capabilities are asked once per account and chain', async () => {
    const p = await erc20Swap(c => { c.capabilities = SUPPORTED; });
    p.click('swap');
    await p.waitFor(() => /Done/.test(p.text('stat')), { label: 'settled', timeout: 20000 });
    await p.window.eval('canBatch(account)');
    assert.equal(p.chain.log.filter(r => r.method === 'wallet_getCapabilities').length, 1);
    p.close();
  });
});
