/**
 * The liquidity panel behind the droplet.
 *
 * This is the only part of zSwap that sends a transaction to something other
 * than a board, the router or a token — it calls a PrecisionPool directly. So
 * the things worth pinning are the ones that cost money if they are wrong:
 * which contract the transaction goes to, that the factory vouched for it
 * first, and that the minimums it carries are bounded rather than exact.
 *
 * The last one is not a style preference. Both entry points derive their
 * minimums from a preview read at one block and execute at a later one, so an
 * exact minimum reverts on any pool with traffic — which is every pool worth
 * depositing into.
 */
import { test, describe, after } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import {
  A, SEL, MockChain, loadPage, fixedRateQuoter, closeAllPages, word, wordAddr,
} from './harness.mjs';

after(closeAllPages);

const ETH = 10n ** 18n;
const USDC = 10n ** 6n;
const LENS = '0x4444444444444444444444444444444444444444';
const POOL_A = '0x7777777777777777777777777777777777777777';
const POOL_B = '0x8888888888888888888888888888888888888888';

/** Repoint PPLENS by shape, so a redeploy of the real lens cannot unpatch us. */
const CUR_PPLENS = (() => {
  const html = readFileSync(new URL('../../zSwap.html', import.meta.url), 'utf8');
  const m = html.match(/const PPLENS="(0x[0-9a-fA-F]{40})"/);
  if (!m) throw Error('zSwap.html no longer declares PPLENS');
  return m[0];
})();
const patchLens = [[CUR_PPLENS, `const PPLENS="${LENS}"`]];

/**
 * Bands are stored as RAW sqrt prices: sqrt(price x 10^(d1-d0)) x 1e18, with
 * token decimals NOT normalised. Building fixtures the real way is what puts
 * the page's decimal adjustment under test instead of trivially satisfying it.
 */
const sqrtRaw = (price, d0 = 18, d1 = 6) =>
  BigInt(Math.floor(Math.sqrt(price * 10 ** (d1 - d0)) * 1e18));

// A live ETH/USDC band around 3000, and a stale one far below it. Reserves and
// supply are consistent, so every previewed amount below is real arithmetic.
const BAND_A = {
  pool: POOL_A, fee: 3000n, liquidity: 10n ** 21n,
  reserve0: 100n * ETH, reserve1: 300000n * USDC,
  sqrtLow: sqrtRaw(2000), sqrtHigh: sqrtRaw(4000), sqrtNow: sqrtRaw(3000),
};
const BAND_B = {
  pool: POOL_B, fee: 500n, liquidity: 10n ** 20n,
  reserve0: 5n * ETH, reserve1: 500n * USDC,
  sqrtLow: sqrtRaw(80), sqrtHigh: sqrtRaw(120), sqrtNow: sqrtRaw(3000),
};

async function setup({ bands = [BAND_A, BAND_B], shares = 10n ** 20n, open = true } = {}) {
  const chain = new MockChain();
  chain.setNative(A.ACCOUNT, 50n * ETH);
  chain.setErc20(A.USDC, A.ACCOUNT, 100000n * USDC);
  chain.quoteHandler = fixedRateQuoter({ rate: 3000n * ETH });
  chain.setCode(LENS, '0x60006000');
  chain.setPools(A.ZERO, A.USDC, bands);
  // An LP position is an LP-token balance, read off the pool itself.
  if (shares) chain.setErc20(POOL_A, A.ACCOUNT, shares);

  const page = await loadPage({ chain, patch: patchLens });
  await page.connect();
  if (open) {
    page.click('lq');
    await page.settle();
  }
  return page;
}

const rows = p => [...p.$('lqList').querySelectorAll('.lqrow')];
const btn = (p, act) => p.$('lqList').querySelector(`[data-act="${act}"]`);
const typeInto = (p, el, v) => {
  el.value = v;
  el.dispatchEvent(new p.window.Event('input', { bubbles: true }));
};

describe('the panel', () => {
  test('lists every band for the pair, deepest and owned first', async () => {
    const p = await setup();
    await p.waitFor(() => rows(p).length, { label: 'bands' });
    const r = rows(p);
    assert.equal(r.length, 2);
    assert.equal(r[0].dataset.pool.toLowerCase(), POOL_A.toLowerCase(),
      'the band the account is in comes first');
    assert.match(p.text('lqSub'), /ETH \/ USDC/);
    p.close();
  });

  test('reads the band in human units and flags one that is out of range', async () => {
    const p = await setup();
    await p.waitFor(() => rows(p).length, { label: 'bands' });
    const [a, b] = rows(p);
    // 2000-4000, not the raw sqrt words: the page undoes the 1e18 scaling and
    // the 12 decimals between ETH and USDC.
    assert.match(a.textContent, /2,000\s*–\s*4,000/);
    assert.match(a.textContent, /0\.30%/, 'fee is basis-of-a-million, shown as a percent');
    assert.equal(a.classList.contains('out'), false, 'price 3000 sits inside 2000-4000');
    assert.equal(b.classList.contains('out'), true, 'price 3000 is far above 80-120');
    assert.match(b.textContent, /out of range/);
    p.close();
  });

  test('shows the holding from the pool balance, not from a paged position list', async () => {
    const p = await setup();
    await p.waitFor(() => btn(p, 'w'), { label: 'withdraw button' });
    // 10% of supply, so 10% of both reserves.
    assert.match(rows(p)[0].textContent, /yours: 10 ETH \+ 30,?000 USDC|yours: 10 ETH \+ 30000 USDC/);
    // The old path asked the lens for a page of the factory's GLOBAL pool list;
    // a holding outside page one was invisible with nothing to say so.
    assert.equal(p.chain.calls.some(c => c.selector === 'dc9d54ef'), false,
      'positionsOf must not be on the hot path');
    const asked = p.chain.calls.filter(c =>
      c.selector === SEL.BALANCEOF && c.to === POOL_A.toLowerCase());
    assert.ok(asked.length, 'the pool itself is asked for the LP balance');
    p.close();
  });

  test('offers no withdraw where nothing is held', async () => {
    const p = await setup({ shares: 0n });
    await p.waitFor(() => rows(p).length, { label: 'bands' });
    assert.equal(btn(p, 'w'), null);
    assert.ok(btn(p, 'a'), 'but adding is always on offer');
    p.close();
  });

  test('says so plainly when the pair has no band at all', async () => {
    const p = await setup({ bands: [], shares: 0n });
    await p.waitFor(() => /No Precision band/.test(p.text('lqList')), { label: 'empty state' });
    p.close();
  });
});

describe('withdrawing', () => {
  test('calls the pool directly, with minimums below the preview', async () => {
    const p = await setup();
    await p.waitFor(() => btn(p, 'w'), { label: 'withdraw button' });
    p.click(btn(p, 'w'));
    await p.waitFor(() => p.chain.sent.length, { label: 'withdraw tx' });
    await p.settle();

    const tx = p.chain.sent.at(-1);
    assert.equal(tx.to.toLowerCase(), POOL_A.toLowerCase(), 'the pool, not the router');
    const body = '0x' + tx.data.replace(/^0x/, '').slice(8);
    assert.equal(tx.data.replace(/^0x/, '').slice(0, 8), SEL.REMOVE);
    assert.equal(word(body, 0), 10n ** 20n, 'the whole position');
    // previewRemove says 10 ETH / 30000 USDC; the default 0.5% slippage is what
    // stands between this and a revert on any pool that trades.
    assert.equal(word(body, 1), 10n * ETH * 9950n / 10000n);
    assert.equal(word(body, 2), 30000n * USDC * 9950n / 10000n);
    assert.equal(wordAddr(body, 3).toLowerCase(), A.ACCOUNT.toLowerCase());
    assert.equal(BigInt(tx.value || '0x0'), 0n);
    p.close();
  });

  test('follows the slippage control the swap tile already has', async () => {
    const p = await setup();
    await p.waitFor(() => btn(p, 'w'), { label: 'withdraw button' });
    p.type('slip', '2');
    p.click(btn(p, 'w'));
    await p.waitFor(() => p.chain.sent.length, { label: 'withdraw tx' });
    const body = '0x' + p.chain.sent.at(-1).data.replace(/^0x/, '').slice(8);
    assert.equal(word(body, 1), 10n * ETH * 9800n / 10000n);
    p.close();
  });

  test('refuses to send to a pool the factory disclaims', async () => {
    const p = await setup();
    p.chain.disownPool(POOL_A);
    await p.waitFor(() => btn(p, 'w'), { label: 'withdraw button' });
    p.click(btn(p, 'w'));
    await p.waitFor(() => /Not a Precision pool/.test(p.text('stat')), { label: 'refusal' });
    assert.equal(p.chain.sent.length, 0, 'nothing may be sent to an impersonator');
    p.close();
  });
});

describe('adding', () => {
  const openAdd = async p => {
    await p.waitFor(() => btn(p, 'a'), { label: 'add button' });
    p.click(btn(p, 'a'));
    const box = rows(p)[0].querySelector('.lqadd');
    await p.waitFor(() => !box.classList.contains('hide'), { label: 'add form' });
    return box;
  };

  test('fills the other side from the pool\'s own ratio', async () => {
    // Adding to a live band is not a free choice of two numbers: the pool
    // takes them in the proportion its reserves are already in and returns the
    // rest. The band is 100 ETH to 300000 USDC, so 2 ETH is 6000 USDC - which
    // the page can work out, and used to make the user work out.
    const p = await setup();
    const box = await openAdd(p);
    const [i0, i1] = box.querySelectorAll('.lqin');
    typeInto(p, i0, '2');
    assert.equal(i1.value, '6000', 'the counterpart follows the reserves');

    await p.waitFor(() => /deposits/.test(box.querySelector('.lqpv').textContent),
      { label: 'preview', timeout: 6000 });
    const txt = box.querySelector('.lqpv').textContent;
    assert.match(txt, /deposits 2 ETH \+ 6,?000 USDC/);
    assert.ok(!/refunds/.test(txt), 'on ratio, so there is nothing to hand back');
    p.close();
  });

  test('mirrors whichever side was typed in', async () => {
    const p = await setup();
    const box = await openAdd(p);
    const [i0, i1] = box.querySelectorAll('.lqin');
    typeInto(p, i1, '3000');
    assert.equal(i0.value, '1', 'and back the other way');
    p.close();
  });

  test('still refuses when a side is emptied', async () => {
    // Clearing one clears both - the pool has no one-sided entry, and the zap
    // that does is a different call through a different contract.
    const p = await setup();
    const box = await openAdd(p);
    const [i0, i1] = box.querySelectorAll('.lqin');
    typeInto(p, i0, '2');
    typeInto(p, i1, '');
    await p.waitFor(() => /both amounts/.test(box.querySelector('.lqpv').textContent),
      { label: 'one-sided refusal', timeout: 6000 });
    assert.equal(box.querySelector('[data-act="ac"]').disabled, true);
    p.close();
  });


  test('approves the full amount offered, then adds with minLP below the preview', async () => {
    const p = await setup();
    const box = await openAdd(p);
    const [i0, i1] = box.querySelectorAll('.lqin');
    typeInto(p, i0, '1');
    typeInto(p, i1, '3000');
    await p.waitFor(() => box.querySelector('[data-act="ac"]').disabled === false,
      { label: 'preview', timeout: 6000 });
    p.click(box.querySelector('[data-act="ac"]'));
    await p.waitFor(() => p.chain.sent.length >= 2, { label: 'approve + add', timeout: 6000 });
    await p.settle();

    const [ap, add] = p.chain.sent.slice(-2);
    // The allowance covers what the pool MAY pull - the amount passed - not the
    // amount the preview expects it to use.
    assert.equal(ap.to.toLowerCase(), A.USDC.toLowerCase());
    const apBody = '0x' + ap.data.replace(/^0x/, '').slice(8);
    assert.equal(wordAddr(apBody, 0).toLowerCase(), POOL_A.toLowerCase());
    assert.equal(word(apBody, 1), 3000n * USDC);

    assert.equal(add.to.toLowerCase(), POOL_A.toLowerCase());
    const body = '0x' + add.data.replace(/^0x/, '').slice(8);
    assert.equal(add.data.replace(/^0x/, '').slice(0, 8), SEL.ADDEXACT);
    assert.equal(word(body, 0), 0n, 'an existing band has no opening price to set');
    assert.equal(word(body, 1), 1n * ETH);
    assert.equal(word(body, 2), 3000n * USDC);
    // previewAdd mints 1e19; the bound is that less the 0.5% default.
    assert.equal(word(body, 3), 10n ** 19n * 9950n / 10000n);
    assert.equal(wordAddr(body, 4).toLowerCase(), A.ACCOUNT.toLowerCase());
    // token0 is native here, so it rides along as value rather than an approval.
    assert.equal(BigInt(add.value), 1n * ETH);
    p.close();
  });

  test('refuses to send to a pool the factory disclaims', async () => {
    const p = await setup();
    const box = await openAdd(p);
    p.chain.disownPool(POOL_A);
    const [i0, i1] = box.querySelectorAll('.lqin');
    typeInto(p, i0, '1');
    typeInto(p, i1, '3000');
    await p.waitFor(() => box.querySelector('[data-act="ac"]').disabled === false,
      { label: 'preview', timeout: 6000 });
    p.click(box.querySelector('[data-act="ac"]'));
    await p.waitFor(() => /Not a Precision pool/.test(p.text('stat')), { label: 'refusal' });
    assert.equal(p.chain.sent.length, 0);
    p.close();
  });
});

describe('living beside the swap tile', () => {
  test('keeps the token pickers, so the pair can still be changed', async () => {
    const p = await setup();
    await p.waitFor(() => rows(p).length, { label: 'bands' });
    // Hiding the panels wholesale took the pickers with them and froze the list.
    // The amount fields STAY: in this mode they are the deposit, and the ratio
    // between them is the opening price of a band being created.
    assert.equal(p.visible('amtRow'), true, 'the amounts are the deposit here');
    assert.equal(p.visible('outRow'), true);
    assert.equal(p.visible('swap'), false, 'but there is nothing to swap');
    assert.ok(p.$('fromSel').offsetParent !== undefined);
    assert.equal(p.$('fromSel').closest('.panel').classList.contains('hide'), false,
      'the pair filter stays on screen');
    p.close();
  });

  test('re-reads the bands when the pair changes', async () => {
    const p = await setup();
    await p.waitFor(() => rows(p).length, { label: 'bands' });
    const before = p.chain.calls.filter(c => c.selector === SEL.MARKETS).length;
    p.pickToken('toSel', 'USDT');
    await p.settle();
    assert.ok(p.chain.calls.filter(c => c.selector === SEL.MARKETS).length > before,
      'a new pair is a new question for the lens');
    await p.waitFor(() => /No Precision band/.test(p.text('lqList')), { label: 'empty pair' });
    p.close();
  });

  test('turns itself off when the tab changes, restoring the form it borrowed', async () => {
    const p = await setup();
    await p.waitFor(() => rows(p).length, { label: 'bands' });
    p.click('tabBook');
    await p.settle();
    assert.equal(p.visible('lqPanel'), false, 'the band list belongs to the swap tile');
    assert.equal(p.visible('lq'), false, 'and so does the control that opens it');
    // The tab switch re-shows these; leaving the mode on would stack them over
    // the band list with no action button underneath.
    assert.equal(p.visible('amtRow'), true);
    assert.equal(p.$('lq').getAttribute('aria-pressed'), 'false');
    p.click('tabSwap');
    await p.settle();
    assert.equal(p.visible('lq'), true);
    assert.equal(p.visible('swap'), true, 'the swap button came back with it');
    p.close();
  });

  // The cut is the point, so it has to be COUNTED, not just announced. The
  // notice and the list are produced by different lines and drifted apart once
  // already: the window was widened to 128 while the decode loop stayed at 24,
  // so a 40-band pair dropped 16 of them and said nothing, and a 900-band pair
  // claimed to be showing 128 while drawing 24.
  test('draws every band it found, up to the display budget', async () => {
    const many = Array.from({ length: 40 }, (_, i) => ({
      ...BAND_A,
      pool: '0x' + (i + 1).toString(16).padStart(40, '0'),
      // Distinct depths, so "deepest first" is a real ordering and the 24 that
      // survive the cut are the 24 deepest rather than the first 24 returned.
      liquidity: 10n ** 21n + BigInt(i),
    }));
    const p = await setup({ bands: many, shares: 0n });
    await p.waitFor(() => rows(p).length, { label: 'bands' });
    assert.equal(rows(p).length, 24, 'the display budget, not the old decode cap');
    assert.equal(rows(p)[0].dataset.pool.toLowerCase(),
      many[39].pool.toLowerCase(), 'the deepest band leads');
    assert.match(p.text('lqSub'), /showing 24 of 40/,
      'a list shorter than the pair says so');
    assert.doesNotMatch(p.text('lqSub'), /scanned/,
      'the scan covered the pair, so it claims nothing about scanning');
    p.close();
  });

  test('says when a pair has more bands than it is showing', async () => {
    // `_byPair` is append-only and index 0 is the OLDEST pool, so a fixed
    // window is not neutral: on a NEW pair somebody can create junk bands
    // first and push a later real one outside it. Creation costs ~4.6M gas
    // apiece, so that is expensive rather than impossible - which makes it
    // worth bounding LOUDLY. A truncated list that looks complete is the
    // failure that matters, not the truncation itself.
    const p = await setup();
    p.chain.pairCount = 900;
    p.pickToken('toSel', 'USDT');
    await p.settle();
    p.pickToken('toSel', 'USDC');
    await p.waitFor(() => /showing/.test(p.$('lqSub').textContent), { label: 'the notice' });
    // Two separate facts: how many of the pair are on screen, and that the scan
    // itself stopped short - without which "24 of 900" implies these were the
    // best 24 of all 900, when they are the best 24 of the first 128.
    assert.match(p.$('lqSub').textContent, /showing 2 of 900 \(first 128 scanned\)/);
    p.close();
  });
});
