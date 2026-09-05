import { test, describe, after } from 'node:test';
import assert from 'node:assert/strict';
import {
  A, SEL, MockChain, loadPage, fixedRateQuoter, closeAllPages,
} from './harness.mjs';

after(closeAllPages);

const ETH = 10n ** 18n;
const USDC = 10n ** 6n;
const POOL = '0xc37f8c7e9afe897893952aba7fd91e0ab947837d';
const FUTURE = Math.floor(Date.now() / 1e3) + 86400;
const V4POOL_KEY = '0x95a932c205571d4d1ca72715c642a2eca21dde79ffc28ff11509681f9383385f';

const listRow = (s, a, o = {}) => ({
  i: '1', c: 1, k: 'eip155', p: 'ERC-20', x: true, o: false, f: false,
  a, n: `${s} Token`, s, d: 18, t: '#888', r: 1, u: '', au: '', l: '',
  desc: '', e: [], v: true, ...o,
});

const ask = (id, pays, gets) => ({
  id, board: A.SB2, maker: A.OTHER, pf: true, exp: FUTURE,
  nA: false, nB: false, cp: A.ZERO,
  tA: A.USDC, aA: gets, symA: 'USDC', decA: 6,
  tB: A.WETH, aB: pays, symB: 'WETH', decB: 18,
});

async function setup({ aggregator = true, precision = null, book = [] } = {}) {
  const chain = new MockChain();
  chain.setNative(A.ACCOUNT, 100n * ETH);
  chain.setErc20(A.USDC, A.ACCOUNT, 500_000n * USDC);
  chain.quoteHandler = aggregator
    ? fixedRateQuoter({ rate: 3000n * ETH })
    : () => { throw Error('no route'); };
  chain.precisionQuote = precision;
  if (precision) {
    chain.setPools(A.ZERO, A.USDC, [{ pool: precision.pool, hook: A.ZERO, liquidity: 10n ** 20n }]);
  }
  chain.candidates = book;
  const page = await loadPage({ chain });
  await page.connect();
  page.pickToken('fromSel', 'ETH');
  page.pickToken('toSel', 'USDC');
  return page;
}

describe('the book competes against a standalone venue', () => {
  test('control: with an aggregator route, a better book wins', async () => {
    const p = await setup({ book: [ask(1n, 1n * ETH, 3200n * USDC)] });
    await p.typeAmount('amt', '1');
    assert.match(p.text('rate'), /\u00b7 Orderbook \u00b7/,
      `the book beats 3000, got ${p.text('rate')}`);
    p.close();
  });

  test('with only a Precision route, the book is still asked', async () => {
    const p = await setup({
      aggregator: false,
      precision: { pool: POOL, out: 3100n * USDC, small: 31n * USDC, fee: 3000 },
      book: [ask(1n, 1n * ETH, 3200n * USDC)],
    });
    await p.typeAmount('amt', '1');
    assert.ok(Number(p.value('outAmt')) > 3100,
      `the book pays 3200 against the pool's 3100, got ${p.value('outAmt')}`);
    p.close();
  });

  test('a winning plan is addressed to the router, not to the venue it beat', async () => {
    const p = await setup({
      aggregator: false,
      precision: { pool: POOL, out: 3100n * USDC, small: 31n * USDC, fee: 3000 },
      book: [ask(1n, 1n * ETH, 3200n * USDC)],
    });
    await p.typeAmount('amt', '1');
    await p.click('swap');
    await p.settle();

    const tx = p.chain.lastSent;
    assert.ok(tx, 'the swap should have produced a transaction');
    assert.notEqual((tx.to || '').toLowerCase(), A.V4PORT.toLowerCase(),
      'a router multicall must not be addressed to the V4 port');
    assert.equal((tx.to || '').toLowerCase(), A.ZROUTER.toLowerCase(),
      `a book plan settles through zRouter, got ${tx.to}`);
    p.close();
  });

  test('a plan that beats a V4 pool is not addressed to the V4 port', async () => {
    const chain = new MockChain();
    chain.setNative(A.ACCOUNT, 100n * ETH);
    chain.setErc20(A.USDC, A.ACCOUNT, 500_000n * USDC);
    chain.quoteHandler = () => { throw Error('no route'); };
    chain.registry = [
      listRow('ETH', A.ZERO, { p: 'Native' }),
      listRow('USDC', A.USDC, {
        d: 6,
        e: [{ k: V4POOL_KEY, v: `v1:${A.ZERO}:500:10:${A.ZERO}` }],
      }),
    ];
    chain.conviction = [1, 2];
    chain.v4Quote = ({ amountIn }) => amountIn * 3100n * USDC / ETH;
    chain.candidates = [ask(1n, 1n * ETH, 3200n * USDC)];
    const p = await loadPage({ chain });
    await p.connect();
    p.pickToken('fromSel', 'ETH');
    p.pickToken('toSel', 'USDC');
    await p.typeAmount('amt', '1');

    assert.match(p.text('rate'), /\u00b7 Orderbook \u00b7/,
      `the book pays 3200 against V4's 3100, got ${p.text('rate')}`);
    await p.click('swap');
    await p.settle();

    const tx = p.chain.lastSent;
    assert.ok(tx, `the swap should have produced a transaction — ${p.text('stat')}`);
    assert.equal((tx.to || '').toLowerCase(), A.ZROUTER.toLowerCase(),
      `a router multicall must not go to the V4 port, got ${tx.to}`);
    p.close();
  });
});
