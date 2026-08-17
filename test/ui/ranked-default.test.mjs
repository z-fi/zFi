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
import { A, SEL, MockChain, loadPage, fixedRateQuoter, closeAllPages } from './harness.mjs';

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

/** Load with a registry in the given order, and let the page choose. */
async function landOn(registry, conviction) {
  const chain = new MockChain();
  chain.registry = registry;
  if (conviction) chain.conviction = conviction;
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
  test('remembers the pair the ranking settled on, so it need not guess twice', async () => {
  // The ETH->USDC flash: two array indices paint a pair, the registry's ranking
  // arrives a moment later and moves it, and you watch the page correct itself.
  // The ranking cannot be known before the network answers, so the flash cannot
  // be removed outright - but guessing when we already know the answer can.
  const rows = [ETH_ROW, WBTC_ROW, USDC_ROW];
  const mk = () => {
    const c = new MockChain();
    c.registry = rows;
    c.conviction = rows.map((_, i) => i + 1);
    c.setNative(A.ACCOUNT, 10n * ETH);
    c.quoteHandler = fixedRateQuoter({ rate: 3000n * ETH });
    return c;
  };

  const first = await loadPage({ chain: mk(), hash: null });
  await first.connect({ pin: false });
  await first.settle();
  // By ADDRESS, not by select index: the index depends on list order, and the
  // whole point is that the second visit seats the pair BEFORE the registry
  // reorders anything. Comparing indices would compare two different lists.
  const addrs = p => [p.$('fromSel').dataset.addr, p.$('toSel').dataset.addr];
  const settled = addrs(first);
  const remembered = first.window.localStorage.getItem('zswap:pair');
  assert.ok(remembered, 'the settled pair should be remembered');
  first.close();

  // Second visit, same storage: seated before any ranking is fetched.
  const second = await loadPage({ chain: mk(), hash: null, storage: { 'zswap:pair': remembered } });
  assert.deepEqual(addrs(second), settled,
    'the remembered pair should be seated immediately, with nothing to correct');
  second.close();
});

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
    // The built-in fallback carries tokens the curated list may not, and a link
    // can name one. Such a pick cannot be honoured once the registry lands -
    // the token is gone from the picker - so the ranking takes over rather than
    // leaving the form pointing at nothing.
    const chain = new MockChain();
    chain.registry = [ETH_ROW, WBTC_ROW, USDC_ROW];
    chain.setNative(A.ACCOUNT, 10n * ETH);
    chain.quoteHandler = fixedRateQuoter({ rate: 3000n * ETH });
    // Selected through the URL, because there is no longer a window in which to
    // click it: the registry loads at BOOT now, so the built-in list is gone
    // before a test could reach into the picker. The hash is applied first, off
    // the built-ins, which is exactly the situation this guards - a pick the
    // registry then turns out not to carry.
    const page = await loadPage({ chain, hash: '#token=ETH&out=USDT' });
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

/**
 * Which ranking the picker obeys.
 *
 * Two contracts answer `rankedIds()`. The registry sorts by the `rank` its
 * owner assigns - curation. ZorgTokenListLens re-sorts the same ids by live
 * `supportOf`, the conviction bonded behind each listing - earned. The picker
 * was reading the first, so the order it showed was the one an owner wrote
 * rather than the one people had put weight behind, and bonding moved nothing.
 *
 * Membership is a separate question and stays with the registry: conviction
 * decides what RANKS, never what EXISTS. Gating on it would hide every listing
 * nobody has bonded to yet, which is a different rule and not a stricter one.
 */
describe('conviction ranking', () => {
  // Registry order: ETH, WBTC, USDC. Conviction (ids are 1-based) puts USDC
  // above WBTC, so the two rankings genuinely disagree.
  const REG = [ETH_ROW, WBTC_ROW, USDC_ROW];

  test('is preferred over the listing order the registry assigns', async () => {
    const { page, from, to } = await landOn(REG, [1, 3, 2]);
    assert.equal(from, 'ETH');
    assert.equal(to, 'USDC', 'bonded support should outrank the listing order');
    const opts = [...page.$('toSel').options].map(o => o.textContent);
    assert.deepEqual(opts.slice(0, 3), ['ETH', 'USDC', 'WBTC'], 'the whole picker follows it');
    page.close();
  });

  test('bonding reorders the picker with no change to the page', async () => {
    const { page, to } = await landOn(REG, [2, 1, 3]);
    assert.equal(to, 'ETH', 'WBTC now carries the most conviction, so ETH is the output');
    const opts = [...page.$('toSel').options].map(o => o.textContent);
    assert.deepEqual(opts.slice(0, 3), ['WBTC', 'ETH', 'USDC']);
    page.close();
  });

  test('still lists a token nobody has bonded to', async () => {
    // Only ETH carries support here. The other two must remain in the picker:
    // conviction ranks, it does not admit.
    const { page } = await landOn(REG, [1, 2, 3]);
    const opts = [...page.$('toSel').options].map(o => o.textContent);
    for (const sym of ['ETH', 'WBTC', 'USDC']) {
      assert.ok(opts.includes(sym), `${sym} was dropped from the picker`);
    }
    page.close();
  });

  test('falls back to the listing order, and says so, when the lens is unreachable', async () => {
    // conviction left null: the harness makes the lens throw.
    const { page, to } = await landOn(REG);
    assert.equal(to, 'WBTC', 'the registry order stands in');
    const note = page.$('listNote');
    assert.match(note.textContent, /conviction unavailable/i,
      'a different order than the one promised must not be shown silently');
    assert.ok(!/Built-in/i.test(note.textContent),
      'the curated list DID load - only its ranking fell back');
    page.close();
  });

  test('reads every listing in one batch, not one call per token', async () => {
    const chain = new MockChain();
    chain.registry = [ETH_ROW, WBTC_ROW, USDC_ROW, USDT_ROW, WETH_ROW];
    chain.conviction = [1, 2, 3, 4, 5];
    chain.setNative(A.ACCOUNT, 10n * ETH);
    chain.quoteHandler = fixedRateQuoter({ rate: 3000n * ETH });
    const page = await loadPage({ chain, hash: null });
    await page.connect({ pin: false });

    // chain.calls records the batch's INNER calls identically to direct ones,
    // so it cannot tell the two apart. chain.log records actual requests.
    const requests = chain.log.filter(r => r.method === 'eth_call'
      && r.params?.[0]?.to?.toLowerCase() === A.TOKENLIST.toLowerCase()
      && (r.params[0].data || '').slice(2, 10) === SEL.LISTJSON);
    assert.equal(requests.length, 0,
      'metadata must ride the batcher, not one eth_call per listing');
    // And it did actually read them: five listings, all present.
    assert.equal([...page.$('toSel').options].filter(o => o.value !== '__custom').length, 5);
    page.close();
  });
});

/**
 * The pair can never be the same asset twice.
 *
 * The picker disables whichever option the other side holds - but rebuild()
 * re-creates the <option> nodes and drops every disabled flag, so that
 * protection only exists if something puts it back. `connect` did.
 * The boot path for a wallet that is ALREADY authorised - a returning visitor,
 * the commonest case there is - did not, and neither did any test, because
 * every test connects by clicking.
 *
 * So the picker let ETH be chosen against ETH and the form dead-ended on "Pick
 * different tokens" with no way to see why.
 */
describe('a pair of one asset', () => {
  const REG = [ETH_ROW, WBTC_ROW, USDC_ROW];

  /** A wallet already authorised: the page connects itself, without a click. */
  async function returning() {
    const chain = new MockChain();
    chain.registry = REG;
    chain.conviction = [1, 2, 3];
    chain.autoConnected = true;
    chain.setNative(A.ACCOUNT, 10n * ETH);
    chain.quoteHandler = fixedRateQuoter({ rate: 3000n * ETH });
    const page = await loadPage({ chain, hash: null });
    await page.waitFor(() => page.text('addr') !== 'Not connected', { label: 'auto-connect' });
    await page.settle();
    return page;
  }

  test('is impossible to select for a returning wallet, not only a fresh one', async () => {
    const p = await returning();
    const from = p.$('fromSel').value;
    const dupe = [...p.$('toSel').options].find(o => o.value === from);
    assert.equal(dupe.disabled, true,
      'the token on the pay side must stay disabled on the receive side');

    // And through the panel, which is built from those same flags.
    p.click('toPick');
    await p.settle();
    const row = [...p.$('tkList').querySelectorAll('.tkr')].find(r => r.dataset.value === from);
    assert.equal(row.getAttribute('aria-disabled'), 'true');
    p.close();
  });

  test('is corrected rather than displayed, whatever put it there', async () => {
    // Reaching past the controls, the way a code path that forgot to sync
    // would: the invariant lives where the flags are written, so it holds.
    const p = await returning();
    p.$('toSel').value = p.$('fromSel').value;
    p.$('toSel').dispatchEvent(new p.window.Event('change', { bubbles: true }));
    await p.settle();

    assert.notEqual(p.$('toSel').value, p.$('fromSel').value,
      'the page should move a side, not sit on a pair it refuses to quote');
    assert.ok(!/Pick different tokens/i.test(p.text('stat')),
      'and that message should be unreachable now');
    p.close();
  });
});
