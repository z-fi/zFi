import { test, describe } from 'node:test';
import assert from 'node:assert/strict';
import { A, MockChain, loadPage, fixedRateQuoter, closeAllPages } from './harness.mjs';

const ETH = 10n ** 18n;
const KEEP = 'zswap:deep';

/**
 * The launcher's creator index only grows, so the page reads a WINDOW of it -
 * the newest LAUNCH_SCAN pools - and ranks by liquidity inside that window.
 *
 * Which means depth alone was never the whole rule. A coin that launched early,
 * found real liquidity, and then watched a few hundred newer coins arrive would
 * fall out of the window and out of discovery entirely, while shallower but
 * younger markets kept their places. The deepest market on the whole launcher
 * could become address-only purely by ageing.
 *
 * So the pools that ranked last time are carried forward and re-priced next to
 * the fresh ones. Nothing is pinned: a carried pool that has since drained
 * loses its slot to a newcomer like anything else. Age just stops being the
 * thing that decides.
 */
const row = (s, a, o = {}) => ({
  i: '1', c: 1, k: 'eip155', p: 'ERC-20', x: true, o: false, f: false,
  a, n: `${s} Token`, s, d: 18, t: '#888', r: 1, u: '', au: '', l: '', desc: '', e: [], v: true, ...o,
});

const pad = (n, tag) => '0x' + tag + String(n).padStart(40 - tag.length, '0');
const POOL = n => pad(n, 'b');
const COIN = n => pad(n, 'c');

/** The oldest pool is the deepest; everything after it is shallow and newer. */
function fixture(total) {
  const chain = new MockChain();
  const rows = [row('ETH', A.ZERO, { p: 'Native' })];
  chain.registry = rows;
  chain.conviction = rows.map((_, i) => i + 1);
  chain.setNative(A.ACCOUNT, 10n * ETH);
  chain.quoteHandler = fixedRateQuoter({ rate: 3000n * ETH });

  const launched = [];
  for (let i = 0; i < total; i++) {
    // Index 0 is both the oldest and by far the deepest.
    const deep = i === 0;
    chain.setToken(COIN(i), { symbol: deep ? 'ELDER' : `NEW${i}`, decimals: 18, name: '' });
    launched.push({ pool: POOL(i), token: COIN(i), reserve0: deep ? 500n * ETH : 1n * ETH });
  }
  chain.setLaunched(launched);
  return chain;
}

const syms = p => [...p.$('toSel').options].map(o => o.textContent);

describe('a deep market does not age out of discovery', () => {
  test('inside the scan window, depth alone is enough', async () => {
    const p = await loadPage({ chain: fixture(10), hash: null });
    await p.settle();
    assert.ok(syms(p).includes('ELDER'), 'the deepest pool should be shown');
    p.close();
  });

  test('past the window it is lost, unless it was carried forward', async () => {
    // 260 launches puts index 0 four places behind the 256-pool tail.
    const lost = await loadPage({ chain: fixture(260), hash: null });
    await lost.settle();
    assert.ok(!syms(lost).includes('ELDER'),
      'this test is vacuous unless the window really does drop the oldest pool');
    lost.close();

    const kept = await loadPage({
      chain: fixture(260), hash: null,
      storage: { [KEEP]: JSON.stringify([POOL(0)]) },
    });
    await kept.settle();
    assert.ok(syms(kept).includes('ELDER'),
      'a pool that ranked before must be re-priced alongside the fresh window');
    kept.close();
  });

  test('what ranked is remembered, so the next load can carry it', async () => {
    const p = await loadPage({ chain: fixture(10), hash: null });
    await p.settle();
    const keep = JSON.parse(p.window.localStorage.getItem(KEEP) || '[]');
    assert.ok(keep.length, 'the ranked pools should be recorded');
    assert.equal(keep[0].toLowerCase(), POOL(0), 'deepest first');
    assert.ok(keep.length <= 24, 'no more than the shown cohort is carried');
    p.close();
  });

  test('a carried pool that has drained does not hold its slot', async () => {
    // POOL(9) is remembered but empty; it must not displace a funded newcomer.
    const chain = fixture(10);
    chain.launched[9].reserve0 = 0n;
    const p = await loadPage({
      chain, hash: null, storage: { [KEEP]: JSON.stringify([POOL(9)]) },
    });
    await p.settle();
    const keep = JSON.parse(p.window.localStorage.getItem(KEEP) || '[]');
    assert.ok(!keep.map(x => x.toLowerCase()).includes(POOL(9)),
      'an empty pool should not be carried forward again');
    p.close();
  });

  /**
   * The carried list lives in localStorage, which the page wrote but does not
   * control - anything with access to the browser can put an address there.
   * A pool from the fresh window is proven by provenance: it came out of the
   * factory\'s index under the launcher. A carried one has no such proof, so it
   * is asked directly, and only a pool whose feeRecipient IS the launcher gets
   * priced and shown as a launch.
   */
  test('a carried pool must prove the launcher made it', async () => {
    const chain = fixture(260);
    // An impostor with real liquidity, carried forward, but not a launch.
    chain.setForeignPools([{
      pool: POOL(900), token: COIN(900), reserve0: 900n * ETH,
      feeRecipient: '0x00000000000000000000000000000000deadbeef',
    }]);
    chain.setToken(COIN(900), { symbol: 'FAKE', decimals: 18, name: '' });
    const p = await loadPage({
      chain, hash: null,
      storage: { [KEEP]: JSON.stringify([POOL(900), POOL(0)]) },
    });
    await p.settle();
    assert.ok(!syms(p).includes('FAKE'),
      'a carried pool the launcher did not make must not be shown as a launch');
    assert.ok(syms(p).includes('ELDER'),
      'and rejecting it must not cost the genuine carried pool its place');
    p.close();
  });

  test('a bad stored value is ignored rather than breaking the list', async () => {
    for (const bad of ['not json', '{}', '["nope"]', '']) {
      const p = await loadPage({ chain: fixture(10), hash: null, storage: { [KEEP]: bad } });
      await p.settle();
      assert.ok(syms(p).includes('ELDER'), `the list should survive ${JSON.stringify(bad)}`);
      p.close();
    }
  });

  test.after(() => closeAllPages());
});
