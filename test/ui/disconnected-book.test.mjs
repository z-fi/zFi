import { test, describe, after } from 'node:test';
import assert from 'node:assert/strict';
import { A, MockChain, loadPage, fixedRateQuoter, closeAllPages } from './harness.mjs';

after(closeAllPages);

const ETH = 10n ** 18n;
const USDC = 10n ** 6n;
const FUTURE = Math.floor(Date.now() / 1e3) + 86400;

const order = (id, over = {}) => ({
  id, board: A.SB2, maker: A.OTHER, pf: true, exp: FUTURE,
  nA: false, nB: false, cp: A.ZERO,
  tA: A.USDC, aA: 3000n * USDC, symA: 'USDC', decA: 6,
  tB: A.WETH, aB: 1n * ETH, symB: 'WETH', decB: 18,
  ...over,
});

async function open_({ orders = [order(1n)] } = {}) {
  const chain = new MockChain();
  chain.setNative(A.ACCOUNT, 10n * ETH);
  chain.quoteHandler = fixedRateQuoter({ rate: 3000n * ETH });
  chain.recent = orders;
  // A wallet is present but NOT connected — the state every first-time
  // visitor is in, and the one where `account` is still null.
  chain.autoConnected = false;
  return loadPage({ chain });
}

describe('the orderbook without a connected wallet', () => {
  test('renders instead of throwing on a null account', async () => {
    const p = await open_();
    const errs = [];
    p.window.addEventListener('error', e => errs.push(String(e.error || e.message)));
    p.window.addEventListener('unhandledrejection', e => errs.push(String(e.reason)));

    p.click('tabBook');
    await p.settle();

    assert.deepEqual(errs, [], 'reading the book must not require an account');
    p.close();
  });

  test('an order with a counterparty is still filtered, not crashed on', async () => {
    // The cp/maker comparisons are what dereference `account`. A private
    // order must simply not be shown to a viewer who is nobody.
    const p = await open_({ orders: [order(1n, { cp: A.ACCOUNT }), order(2n)] });
    const errs = [];
    p.window.addEventListener('error', e => errs.push(String(e.error || e.message)));
    p.window.addEventListener('unhandledrejection', e => errs.push(String(e.reason)));

    p.click('tabBook');
    await p.settle();

    assert.deepEqual(errs, [], 'a private order must not crash an anonymous reader');
    p.close();
  });
});
