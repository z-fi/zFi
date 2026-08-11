/**
 * The landing pair follows the registry's conviction ranking.
 *
 * zSwap opened on ETH -> USDC because two array indices said so. The curated
 * list is ranked on chain - `rankedIds()` returns strictly descending - and the
 * page already honoured that ranking for the ORDER of the dropdown while
 * ignoring it for the pair it actually landed on. So curation could reorder the
 * whole picker and the page would still open on the same hardcoded pair.
 *
 * Now the default is the top of the ranking, which means re-ranking on chain
 * moves the dapp with no redeploy. That is the property worth pinning, and it
 * is the one a constant cannot express - so these tests re-rank the registry
 * and require the landing pair to follow.
 *
 * Run: node --test test/ui/
 */
import { test, describe, after } from 'node:test';
import assert from 'node:assert/strict';
import { A, MockChain, loadPage, fixedRateQuoter, closeAllPages } from './harness.mjs';

after(closeAllPages);

const ETH = 10n ** 18n;

/** A registry row in the shape zTokenlist serves. */
const row = (sym, addr, dec = 18, p = 'ERC-20') => ({
  i: '1', c: 1, k: 'eip155', p, x: true, o: false, f: false,
  a: addr, n: sym, s: sym, d: dec, t: '#888', r: 1, u: '', au: '', l: '', desc: '', e: [], v: true,
});
const ETH_ROW = row('ETH', A.ZERO, 18, 'Native');
const WETH_ROW = row('WETH', A.WETH);
const USDC_ROW = row('USDC', A.USDC, 6);
const WBTC_ROW = row('WBTC', A.WBTC, 8);
const USDT_ROW = row('USDT', A.USDT, 6);

/** Load with a registry in the given conviction order, and let the page choose. */
async function landOn(registry) {
  const chain = new MockChain();
  chain.registry = registry;
  chain.setNative(A.ACCOUNT, 10n * ETH);
  chain.quoteHandler = fixedRateQuoter({ rate: 3000n * ETH });
  // hash: null opts out of the harness's pinned pair - the whole point here is
  // to watch the page pick for itself.
  const page = await loadPage({ chain, hash: null });
  await page.connect({ pin: false });
  const sym = which => {
    const el = page.$(which);
    return [...el.options].find(o => o.value === el.value)?.textContent;
  };
  return { page, from: sym('fromSel'), to: sym('toSel') };
}

describe('the landing pair', () => {
  test('is the top of the conviction ranking, not a hardcoded pair', async () => {
    const { page, from, to } = await landOn([ETH_ROW, USDC_ROW, WBTC_ROW]);
    assert.equal(from, 'ETH');
    assert.equal(to, 'USDC', 'the second-ranked asset should be the output');
    page.close();
  });

  test('follows a re-ranking, with no change to the page', async () => {
    // Same page, same code, different curation: WBTC promoted over USDC.
    const { page, from, to } = await landOn([ETH_ROW, WBTC_ROW, USDC_ROW]);
    assert.equal(from, 'ETH');
    assert.equal(to, 'WBTC', 're-ranking on chain must move the landing pair');
    page.close();
  });

  test('moves the input side too when something outranks ETH', async () => {
    const { page, from, to } = await landOn([WBTC_ROW, USDT_ROW, ETH_ROW]);
    assert.equal(from, 'WBTC', 'the top of the ranking is the input, whatever it is');
    assert.equal(to, 'USDT');
    page.close();
  });

  test('skips a wrapped twin, which is a wrap and not a market', async () => {
    // WETH ranks second, but ETH -> WETH is the same asset: opening there would
    // show a 1:1 wrap where a market should be. The next distinct asset wins.
    const { page, from, to } = await landOn([ETH_ROW, WETH_ROW, USDC_ROW]);
    assert.equal(from, 'ETH');
    assert.equal(to, 'USDC', 'WETH should be skipped as the wrapped twin of ETH');
    page.close();
  });

  test('leaves a pair the user picked alone when the registry lands', async () => {
    // The registry resolves after first paint, so adopting the ranking must not
    // overwrite a choice made while it was still loading.
    const chain = new MockChain();
    chain.registry = [ETH_ROW, WBTC_ROW, USDC_ROW];
    chain.setNative(A.ACCOUNT, 10n * ETH);
    chain.quoteHandler = fixedRateQuoter({ rate: 3000n * ETH });
    const page = await loadPage({ chain, hash: null });

    page.pickToken('toSel', 'USDC');
    await page.connect({ pin: false });

    const el = page.$('toSel');
    assert.equal([...el.options].find(o => o.value === el.value)?.textContent, 'USDC',
      'a deliberate pick must survive the ranking arriving');
    page.close();
  });

  test('falls back to the ranking when the pick is not in the registry', async () => {
    // The pre-registry list is the built-in fallback, which carries tokens the
    // curated list may not. Such a pick cannot be honoured - the token is gone
    // from the picker - so the ranking takes over rather than leaving the form
    // pointing at nothing.
    const chain = new MockChain();
    chain.registry = [ETH_ROW, WBTC_ROW, USDC_ROW];
    chain.setNative(A.ACCOUNT, 10n * ETH);
    chain.quoteHandler = fixedRateQuoter({ rate: 3000n * ETH });
    const page = await loadPage({ chain, hash: null });

    page.pickToken('toSel', 'USDT');            // absent from the registry above
    await page.connect({ pin: false });

    const el = page.$('toSel');
    const sym = [...el.options].find(o => o.value === el.value)?.textContent;
    assert.ok(sym && sym !== 'USDT', 'a token the registry dropped cannot stay selected');
    assert.ok([...el.options].every(o => o.textContent !== 'USDT'), 'and it is gone from the picker');
    page.close();
  });

  test('a link still wins over the ranking', async () => {
    const chain = new MockChain();
    chain.registry = [ETH_ROW, WBTC_ROW, USDC_ROW];
    chain.setNative(A.ACCOUNT, 10n * ETH);
    chain.quoteHandler = fixedRateQuoter({ rate: 3000n * ETH });
    const page = await loadPage({ chain, hash: 'token=ETH&out=USDC' });
    await page.connect({ pin: false });

    const el = page.$('toSel');
    assert.equal([...el.options].find(o => o.value === el.value)?.textContent, 'USDC',
      'a shared link names the pair and must not be second-guessed');
    page.close();
  });
});
