import { test, describe, after } from 'node:test';
import assert from 'node:assert/strict';
import { A, MockChain, loadPage, fixedRateQuoter, closeAllPages } from './harness.mjs';

after(closeAllPages);

const ETH = 10n ** 18n;
const DEEP = '0x1010101010101010101010101010101010101010';
const MID = '0x2020202020202020202020202020202020202020';
const THIN = '0x3030303030303030303030303030303030303030';
const COIN_DEEP = '0xaaaa0000000000000000000000000000000000aa';
const COIN_MID = '0xbbbb0000000000000000000000000000000000bb';
const COIN_THIN = '0xcccc0000000000000000000000000000000000cc';

const row = (s, a, o = {}) => ({
  i: '1', c: 1, k: 'eip155', p: 'ERC-20', x: true, o: false, f: false,
  a, n: `${s} Token`, s, d: 18, t: '#888', r: 1, u: '', au: '', l: '',
  desc: '', e: [], v: true, ...o,
});

const descOf = (p, sym) => {
  const opt = [...p.$('toSel').options].find(o => o.textContent.trim() === sym);
  if (!opt) throw Error(`no ${sym} option — have ${[...p.$('toSel').options].map(o => o.textContent)}`);
  const r = [...p.$('tkList').querySelectorAll('.tkr')].find(x => (x.textContent || '').includes(sym));
  return (r ? r.textContent : '').replace(/\s+/g, ' ');
};

describe('a launched coin keeps its own pool', () => {
  test('a pool whose token1 cannot be read does not shift every coin after it', async () => {
    // The middle pool answers nothing for token1(). The list of coins is built
    // by compacting that gap away, but liquidity and the pool binding are read
    // from the UNCOMPACTED pool list — so one unreadable pool used to slide
    // every later coin onto its neighbour's pool and its neighbour's depth.
    //
    // Depths are set so the sort order is known: 30 > 20 > 10. The thin coin
    // must report its own 10 ETH, not the dead middle pool's 20.
    const chain = new MockChain();
    const rows = [row('ETH', A.ZERO, { p: 'Native' }), row('USDC', A.USDC, { d: 6 })];
    chain.registry = rows;
    chain.conviction = rows.map((_, i) => i + 1);
    chain.setToken(COIN_DEEP, { symbol: 'DEEPC', decimals: 18, name: 'Deep' });
    chain.setToken(COIN_THIN, { symbol: 'THINC', decimals: 18, name: 'Thin' });
    chain.setNative(A.ACCOUNT, 10n * ETH);
    chain.quoteHandler = fixedRateQuoter({ rate: 3000n * ETH });
    chain.setLaunched([
      { pool: DEEP, token: COIN_DEEP, reserve0: 30n * ETH },
      { pool: MID, token: COIN_MID, reserve0: 20n * ETH },
      { pool: THIN, token: COIN_THIN, reserve0: 10n * ETH },
    ]);

    // The middle pool exists and is enumerated, but will not answer token1().
    // That is the production condition: aggregate3 runs with allowFailure, so
    // one reverting member comes back null while its neighbours succeed.
    chain.reverts.set(`${MID.toLowerCase()}:d21220a7`, 'no token1');

    const p = await loadPage({ chain, hash: null });
    await p.settle();
    p.click('toPick');

    assert.match(descOf(p, 'DEEPC'), /30\.000 ETH liquidity/,
      'the deepest coin should report its own depth');
    assert.match(descOf(p, 'THINC'), /10\.000 ETH liquidity/,
      `the thin coin must report ITS depth, not the dead pool's 20 — got "${descOf(p, 'THINC')}"`);
    assert.doesNotMatch(descOf(p, 'THINC'), /20\.000 ETH liquidity/,
      'the thin coin inherited the unreadable pool\'s liquidity');
    p.close();
  });

  test('with every pool readable, nothing shifts', async () => {
    const chain = new MockChain();
    const rows = [row('ETH', A.ZERO, { p: 'Native' }), row('USDC', A.USDC, { d: 6 })];
    chain.registry = rows;
    chain.conviction = rows.map((_, i) => i + 1);
    chain.setToken(COIN_DEEP, { symbol: 'DEEPC', decimals: 18, name: 'Deep' });
    chain.setToken(COIN_THIN, { symbol: 'THINC', decimals: 18, name: 'Thin' });
    chain.setNative(A.ACCOUNT, 10n * ETH);
    chain.quoteHandler = fixedRateQuoter({ rate: 3000n * ETH });
    chain.setLaunched([
      { pool: DEEP, token: COIN_DEEP, reserve0: 30n * ETH },
      { pool: THIN, token: COIN_THIN, reserve0: 10n * ETH },
    ]);

    // The middle pool exists and is enumerated, but will not answer token1().
    // That is the production condition: aggregate3 runs with allowFailure, so
    // one reverting member comes back null while its neighbours succeed.
    chain.reverts.set(`${MID.toLowerCase()}:d21220a7`, 'no token1');

    const p = await loadPage({ chain, hash: null });
    await p.settle();
    p.click('toPick');

    assert.match(descOf(p, 'DEEPC'), /30\.000 ETH liquidity/);
    assert.match(descOf(p, 'THINC'), /10\.000 ETH liquidity/);
    p.close();
  });
});
