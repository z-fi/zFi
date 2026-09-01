/**
 * Regressions for the bugs found in the bug/performance scan of this page.
 */
import { test, describe, it, after } from 'node:test';
import assert from 'node:assert/strict';
import { A, MockChain, loadPage, fixedRateQuoter, closeAllPages } from './harness.mjs';

after(closeAllPages);

const ETH = 10n ** 18n;
const USDC = 10n ** 6n;

const listRow = (s, a, o = {}) => ({
  i: '1', c: 1, k: 'eip155', p: 'ERC-20', x: true, o: false, f: false,
  a, n: `${s} Token`, s, d: 18, t: '#888', r: 1, u: '', au: '', l: '', desc: '', e: [], v: true, ...o,
});

// rankedIds() — one eth_call per loadTokenList run.
const RANKED = 'df7ca268';
const countRanked = chain => chain.log.filter(r =>
  r.method === 'eth_call' && String(r.params?.[0]?.data || '').slice(2, 10) === RANKED).length;

const listChain = (rows, autoConnected = true) => {
  // Authorised by default, so wireWallet's auto-reconnect path runs at load —
  // which is exactly the case where the second loader used to fire.
  const chain = new MockChain({ autoConnected });
  chain.registry = rows;
  chain.conviction = rows.map((_, i) => i + 1);
  chain.setNative(A.ACCOUNT, 10n * ETH);
  chain.quoteHandler = fixedRateQuoter({ rate: 3000n * ETH });
  return chain;
};

describe('the token list loads once per page', () => {
  it('does not load twice when a wallet reconnects on its own', async () => {
    // wireWallet's auto-reconnect awaits loadTokenList, and so does the
    // unconditional call at the bottom of the page. Both start at load, and
    // `listLive` is not set until the first finishes — so the guard that was
    // meant to stop the second never fired, and the whole list (ranked ids, 64
    // tokenJSON reads, the launched-pool scan) was fetched twice.
    const chain = listChain([listRow('ETH', A.ZERO, { p: 'Native' }), listRow('USDC', A.USDC, { d: 6 })]);
    const p = await loadPage({ chain, hash: null });
    await p.connect();
    await p.settle();
    const n = countRanked(chain);
    assert.equal(n, 1, `rankedIds asked ${n} times — the list is loading more than once`);
  });

  it('still retries after a load that found nothing', async () => {
    // The job is only kept once it has actually populated the list; a soft
    // failure has to stay retryable or a connect can never recover the list.
    const chain = listChain([], false);
    const p = await loadPage({ chain, hash: null });
    await p.settle();
    const before = countRanked(chain);
    await p.connect({ pin: false });
    await p.settle();
    assert.ok(countRanked(chain) > before,
      'an unsuccessful load was cached forever and never retried');
  });
});

describe('the orderbook repaint', () => {
  const order = (over = {}) => ({
    id: 5n, board: A.SB2, v2: 1, pf: true, exp: 0n,
    nA: false, nB: false, cp: A.ZERO, maker: A.OTHER,
    tA: A.USDC, aA: 3000n * USDC, symA: 'USDC', decA: 6,
    tB: A.WETH, aB: 1n * ETH, symB: 'WETH', decB: 18,
    ...over,
  });
  const CARD = {
    name: 'Swapboard Position #5',
    image: 'data:image/svg+xml;base64,PHN2Zy8+',
    attributes: [{ trait_type: 'Board', value: 'Swapboard' }],
  };

  it('keeps an expanded receipt open when the book is repainted', async () => {
    // paintBook rewrites book.innerHTML, and it runs on the 30s poll and on
    // every filter click — so an opened receipt was destroyed underneath the
    // reader. The card is already in cardCache, so restoring it costs nothing.
    const chain = new MockChain();
    chain.setNative(A.ACCOUNT, 100n * ETH);
    chain.setErc20(A.WETH, A.ACCOUNT, 100n * ETH);
    chain.setErc20(A.USDC, A.ACCOUNT, 500_000n * USDC);
    chain.quoteHandler = fixedRateQuoter({ rate: 3000n * ETH });
    chain.recent = [order()];
    chain.cards[`${A.SB2.toLowerCase()}:5`] = CARD;

    const p = await loadPage({ chain });
    await p.connect();
    p.click('tabBook');
    await p.waitFor(() => p.$('book').querySelector('[data-bf="0"]'), { label: 'filter chips' });
    p.click(p.$('book').querySelector('[data-bf="0"]'));
    await p.waitFor(() => p.$('book').querySelectorAll('.o.ins').length >= 1, { label: 'rows' });

    p.click(p.$('book').querySelector('.o.ins'));
    await p.waitFor(() => p.$('book').querySelector('.ic').innerHTML.includes('Swapboard'),
      { label: 'receipt to open' });

    // Repaint exactly as the poll and the filter chips do.
    p.click(p.$('book').querySelector('[data-bt="limit"]'));
    await p.settle();

    const box = p.$('book').querySelector('.ic');
    assert.ok(box && box.innerHTML.includes('Swapboard'),
      'the repaint threw away the receipt the reader had open');
    assert.equal(p.$('book').querySelector('.o.ins').getAttribute('aria-expanded'), 'true',
      'the row still claims to be collapsed');
  });
});
