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

  test('says what the price is in, and that the two amounts are a holding', async () => {
    // "price 73,700 · 0.010199 ETH / 750.801782 ZORG" was three numbers with
    // no units on any of them, and a slash between two token amounts reads as
    // a ratio - which, since dividing the reserves lands near the price, was a
    // misreading that confirmed itself.
    const p = await setup();
    await p.waitFor(() => rows(p).length, { label: 'bands' });
    const meta = rows(p)[0].querySelector('.lqmeta').textContent;
    assert.match(meta, /3,000 USDC per ETH/, 'the price carries its units');
    assert.match(meta, /pool 100 ETH \+ 300000 USDC/, 'and the reserves are named as the pool\'s');
    assert.ok(!/ETH \/ /.test(meta), 'no slash between two token amounts');
    p.close();
  });

  test('flags the widest band rather than making the reader divide its edges', async () => {
    // 1 to 1,000,000: the span the create form calls "Full range", where the
    // useful fact is that price effectively never leaves it.
    const WIDE = {
      pool: '0x9999999999999999999999999999999999999999', fee: 3000n, liquidity: 10n ** 21n,
      reserve0: 100n * ETH, reserve1: 300000n * USDC,
      sqrtLow: sqrtRaw(1), sqrtHigh: sqrtRaw(1e6), sqrtNow: sqrtRaw(3000),
    };
    const p = await setup({ bands: [WIDE, BAND_A], shares: 0n });
    await p.waitFor(() => rows(p).length === 2, { label: 'bands' });
    const wide = rows(p).find(r => r.dataset.pool.toLowerCase() === WIDE.pool.toLowerCase());
    const narrow = rows(p).find(r => r.dataset.pool.toLowerCase() === POOL_A.toLowerCase());
    assert.match(wide.textContent, /full range/);
    assert.ok(!/full range/.test(narrow.textContent), '2000-4000 is an ordinary band');
    p.close();
  });

  test('shows the holding from the pool balance, not from a paged position list', async () => {
    const p = await setup();
    await p.waitFor(() => btn(p, 'w'), { label: 'withdraw button' });
    // 10% of supply, so 10% of both reserves.
    assert.match(rows(p)[0].textContent, /yours 10 ETH \+ 30,?000 USDC/,
      'the holding is read off the pool balance');
    // The old path asked the lens for a page of the factory's GLOBAL pool list;
    // a holding outside page one was invisible with nothing to say so.
    assert.equal(p.chain.calls.some(c => c.selector === 'dc9d54ef'), false,
      'positionsOf must not be on the hot path');
    const asked = p.chain.calls.filter(c =>
      c.selector === SEL.BALANCEOF && c.to === POOL_A.toLowerCase());
    assert.ok(asked.length, 'the pool itself is asked for the LP balance');
    p.close();
  });

  test('the sole LP is not told the same numbers twice', async () => {
    // Own the whole band and "pool holds X + Y" and "yours X + Y" are the same
    // two numbers on consecutive lines. The row was five lines deep with the
    // middle one carrying nothing, which is most of why the panel read as
    // dense. The pool's side is worth saying only when it differs from yours.
    const p = await setup({ shares: BAND_A.liquidity });
    await p.waitFor(() => btn(p, 'w'), { label: 'withdraw button' });
    const row = rows(p)[0].textContent;
    assert.match(row, /yours 100 ETH \+ 300000 USDC/, 'the holding is still stated');
    assert.ok(!/pool 100 ETH/.test(row), 'the pool reserves are repeated back at the sole LP');
    assert.match(row, /now 3,000 USDC per ETH/, 'the price still carries its units');
    p.close();
  });

  test('a partial LP is still shown what the pool holds', async () => {
    const p = await setup({ shares: BAND_A.liquidity / 10n });
    await p.waitFor(() => btn(p, 'w'), { label: 'withdraw button' });
    const row = rows(p)[0].textContent;
    assert.match(row, /pool 100 ETH \+ 300000 USDC/, 'the pool side went missing when it matters');
    assert.match(row, /yours 10 ETH \+ 30000 USDC/, 'and the holding alongside it');
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

  /**
   * Every other write on this page simulates before it asks for a signature —
   * swaps, orders, sends and fills all do `eth_call` then
   * `eth_sendTransaction`. The three Precision liquidity writes did not. The
   * preview beforehand is a DIFFERENT call: it prices the position through the
   * lens, it does not run the write, so it cannot see the lessSlip bounds
   * broken by a block landing in between, or anything the pool itself would
   * reject. Without the pre-flight the user signs and pays gas for a revert the
   * node would have named for free.
   */
  test('simulates the withdrawal before asking for a signature', async () => {
    const p = await setup();
    await p.waitFor(() => btn(p, 'w'), { label: 'withdraw button' });
    const isRemove = c => (c.to || '').toLowerCase() === POOL_A.toLowerCase()
      && (c.data || '').replace(/^0x/, '').slice(0, 8) === SEL.REMOVE;
    const before = p.chain.calls.filter(isRemove).length;
    p.click(btn(p, 'w'));
    await p.waitFor(() => p.chain.sent.length, { label: 'withdraw tx' });
    await p.settle();
    assert.ok(p.chain.calls.filter(isRemove).length > before,
      'the exact removal must be eth_call-ed before it is signed');
    p.close();
  });

  /**
   * THE ESCAPE HATCH.
   *
   * `removeLiquidity` demands exact movement on both sides, so one token that
   * pauses, blacklists the holder, or starts taking a transfer fee takes the
   * whole withdrawal down with it — the healthy side included. The pool carries
   * `removeLiquidityLossy` for precisely that and the page could not reach it:
   * an LP whose USDC leg reverted had no way out with their ETH.
   *
   * It is reached ONLY after the strict exit has been refused by an `eth_call`,
   * which is what stops it from silently downgrading a withdrawal that would
   * have settled in full.
   */
  const lossySent = p => p.chain.sent.filter(
    t => (t.data || '').replace(/^0x/, '').slice(0, 8) === SEL.REMOVE_LOSSY);

  test('never reaches for the degraded exit while the strict one works', async () => {
    const p = await setup();
    await p.waitFor(() => btn(p, 'w'), { label: 'withdraw button' });
    p.click(btn(p, 'w'));
    await p.waitFor(() => p.chain.sent.length, { label: 'withdraw tx' });
    await p.settle();
    assert.equal(lossySent(p).length, 0);
    assert.equal(p.asked.confirm.length, 0, 'and nothing was asked of the user');
    p.close();
  });

  test('offers the degraded exit when the strict one is refused', async () => {
    const p = await setup();
    p.chain.revertOn(POOL_A, SEL.REMOVE, 'execution reverted');
    p.queueConfirm(true);
    await p.waitFor(() => btn(p, 'w'), { label: 'withdraw button' });
    p.click(btn(p, 'w'));
    await p.waitFor(() => lossySent(p).length, { label: 'lossy withdrawal' });
    await p.settle();

    const tx = lossySent(p).at(-1);
    assert.equal(tx.to.toLowerCase(), POOL_A.toLowerCase());
    const body = '0x' + tx.data.replace(/^0x/, '').slice(8);
    assert.equal(word(body, 0), 10n ** 20n, 'the whole position');
    // Minimums of zero, deliberately: the lossy path bounds what LEAVES the
    // pool, which on a short pool is below the pro-rata claim, so carrying the
    // strict path's bound here would revert on exactly the pools this escapes.
    assert.equal(word(body, 1), 0n);
    assert.equal(word(body, 2), 0n);
    assert.equal(wordAddr(body, 3).toLowerCase(), A.ACCOUNT.toLowerCase());
    assert.equal(word(body, 4), 1n, 'both sides attempted first');
    assert.equal(word(body, 5), 1n);
    assert.match(p.asked.confirm.at(-1), /cannot pay out in full|short/i);
    p.close();
  });

  test('abandons one side only when taking both still fails', async () => {
    const p = await setup();
    p.chain.revertOn(POOL_A, SEL.REMOVE, 'execution reverted');
    // A pool whose token1 leg cannot move at all: any attempt that takes side 1
    // reverts, and only the token0-alone exit succeeds.
    p.chain.revertOn(POOL_A, SEL.REMOVE_LOSSY, data => {
      const body = '0x' + data.replace(/^0x/, '').slice(8);
      return word(body, 5) === 1n ? 'token1 transfer failed' : null;
    });
    p.queueConfirm(true);
    await p.waitFor(() => btn(p, 'w'), { label: 'withdraw button' });
    p.click(btn(p, 'w'));
    await p.waitFor(() => lossySent(p).length, { label: 'one-sided withdrawal' });
    await p.settle();

    const body = '0x' + lossySent(p).at(-1).data.replace(/^0x/, '').slice(8);
    assert.equal(word(body, 4), 1n, 'leaves through ETH');
    assert.equal(word(body, 5), 0n, 'and gives up the USDC claim');
    // Forfeiting a claim to the remaining holders is a real loss, so the
    // question has to name it rather than ask a bland "continue?".
    assert.match(p.asked.confirm.at(-1), /GIVES UP your USDC claim/);
    p.close();
  });

  test('sends nothing when the degraded exit is declined', async () => {
    const p = await setup();
    p.chain.revertOn(POOL_A, SEL.REMOVE, 'execution reverted');
    p.queueConfirm(false);
    await p.waitFor(() => btn(p, 'w'), { label: 'withdraw button' });
    p.click(btn(p, 'w'));
    await p.waitFor(() => /cancelled/i.test(p.text('stat')), { label: 'cancellation' });
    assert.equal(p.chain.sent.length, 0);
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

  test('deposits the shares to a named recipient', async () => {
    const p = await setup();
    const box = await openAdd(p);
    p.type('rc', A.OTHER);
    const [i0, i1] = box.querySelectorAll('.lqin');
    typeInto(p, i0, '1');
    typeInto(p, i1, '3000');
    await p.waitFor(() => box.querySelector('[data-act="ac"]').disabled === false,
      { label: 'preview', timeout: 6000 });
    p.click(box.querySelector('[data-act="ac"]'));
    await p.waitFor(() => p.chain.sent.length >= 2, { label: 'approve + add', timeout: 6000 });
    await p.settle();
    const body = '0x' + p.chain.sent.at(-1).data.replace(/^0x/, '').slice(8);
    assert.equal(wordAddr(body, 4).toLowerCase(), A.OTHER.toLowerCase());
    p.close();
  });

  test('a bad recipient is refused before any approval is granted', async () => {
    // Order matters: an allowance already granted cannot be taken back by
    // aborting, so the cheap check has to come first.
    const p = await setup();
    const box = await openAdd(p);
    p.type('rc', 'not-an-address');
    const [i0, i1] = box.querySelectorAll('.lqin');
    typeInto(p, i0, '1');
    typeInto(p, i1, '3000');
    await p.waitFor(() => box.querySelector('[data-act="ac"]').disabled === false,
      { label: 'preview', timeout: 6000 });
    p.click(box.querySelector('[data-act="ac"]'));
    await p.waitFor(() => /resolves/.test(p.text('stat')), { label: 'refusal' });
    assert.equal(p.chain.sent.length, 0, 'not even the approval');
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

/**
 * ONE-SIDED DEPOSIT.
 *
 * The one path here that does NOT call the pool directly: `zapIn` answers only
 * to the trusted executor, so this rides zRouter.snwap -> SafeExecutor ->
 * PrecisionRoute. Three hops means three places to name the wrong address, and
 * the value travels with the call, so every field of that encoding is pinned.
 *
 * `minLP` is the whole of the slippage guard - `zapIn` swaps at minOut = 0 -
 * which is why it is asserted twice: once as snwap's own out-minimum measured
 * in LP shares at the depositor, and once inside the executor payload.
 */
describe('zapping in from one side', () => {
  const openAdd = async p => {
    await p.waitFor(() => btn(p, 'a'), { label: 'add button' });
    p.click(btn(p, 'a'));
    const box = rows(p)[0].querySelector('.lqadd');
    await p.waitFor(() => !box.classList.contains('hide'), { label: 'add form' });
    return box;
  };
  const goZap = async p => {
    const box = await openAdd(p);
    const z = box.querySelector('.lqz');
    z.checked = true;
    z.dispatchEvent(new p.window.Event('change', { bubbles: true }));
    return box;
  };

  test('is offered on any seeded band, not only the native ones', async () => {
    // `zapIn` takes an ERC-20 as readily as ether - it just wants the route
    // opened with a checkpoint first. Gating the control on a native token0
    // hid the feature from every pair that has no ETH side at all.
    const p = await setup();
    await p.waitFor(() => rows(p).length, { label: 'bands' });
    assert.ok(rows(p)[0].querySelector('.lqz'), 'a seeded band offers it');
    p.close();
  });

  test('does not mirror the counterpart — the swap leg produces it', async () => {
    const p = await setup();
    const box = await goZap(p);
    const [i0, i1] = box.querySelectorAll('.lqin');
    typeInto(p, i0, '2');
    // Empty, but still ON SCREEN: it is how the depositor says they meant the
    // OTHER side. Hiding it is what pinned the old zap to token0.
    assert.equal(i1.value, '', 'the counterpart is not the depositor\'s to state');
    assert.equal(i1.classList.contains('hide'), false, 'the other side stays reachable');
    assert.equal(box.querySelector('[data-act="ac"]').textContent, 'Zap in');
    p.close();
  });

  test('reads the side off whichever field was filled', async () => {
    const p = await setup();
    const box = await goZap(p);
    typeInto(p, box.querySelectorAll('.lqin')[1], '3000');
    await p.waitFor(() => /swaps/.test(box.querySelector('.lqpv').textContent),
      { label: 'token-side zap preview', timeout: 6000 });
    assert.match(box.querySelector('.lqpv').textContent, /swaps 1,?500 of 3,?000 USDC/,
      'the preview should be denominated in the side actually being deposited');
    p.close();
  });

  test('refuses to guess when both sides are filled', async () => {
    const p = await setup();
    const box = await goZap(p);
    typeInto(p, box.querySelectorAll('.lqin')[0], '2');
    typeInto(p, box.querySelectorAll('.lqin')[1], '3000');
    await p.waitFor(() => /One side only/.test(box.querySelector('.lqpv').textContent),
      { label: 'the ambiguity to be named', timeout: 6000 });
    assert.equal(box.querySelector('[data-act="ac"]').disabled, true,
      'an ambiguous deposit must not be sendable');
    p.close();
  });

  test('an ERC-20 zap opens the route with a checkpoint, and approves first', async () => {
    // The token arrives BEFORE the call that spends it, so `zapIn` demands an
    // open route - exactly as the routed swap does. Ether needs neither.
    const p = await setup();
    const box = await goZap(p);
    typeInto(p, box.querySelectorAll('.lqin')[1], '3000');
    await p.waitFor(() => box.querySelector('[data-act="ac"]').disabled === false,
      { label: 'zap preview', timeout: 6000 });
    p.click(box.querySelector('[data-act="ac"]'));
    await p.waitFor(() => p.chain.sent.length >= 2, { label: 'approve + zap', timeout: 6000 });
    await p.settle();

    const appr = p.chain.sent.at(-2), tx = p.chain.sent.at(-1);
    assert.equal(appr.to.toLowerCase(), A.USDC.toLowerCase(), 'the token is approved');
    assert.equal(tx.to.toLowerCase(), A.ZROUTER.toLowerCase());
    assert.equal(BigInt(tx.value || 0), 0n, 'nothing rides as value for a token zap');
    const raw = tx.data.replace(/^0x/, '');
    assert.equal(raw.slice(0, 8), SEL.MULTICALL, 'checkpoint and settle in one call');
    assert.ok(raw.includes(SEL.ZAPIN), 'the zap itself is in there');
    assert.ok(raw.includes('0b7c6c6c'), 'and so is the checkpoint that opens the route');
    p.close();
  });

  test('previews the swap as well as the mint', async () => {
    const p = await setup();
    const box = await goZap(p);
    typeInto(p, box.querySelectorAll('.lqin')[0], '2');
    await p.waitFor(() => /swaps/.test(box.querySelector('.lqpv').textContent),
      { label: 'zap preview', timeout: 6000 });
    // A depositor does not expect the word "deposit" to trade half their input
    // at the pool's fee. Naming it is the point of the line.
    assert.match(box.querySelector('.lqpv').textContent, /swaps 1 of 2 ETH for USDC/);
    p.close();
  });

  test('routes through zRouter with minLP bounding both hops', async () => {
    const p = await setup();
    const box = await goZap(p);
    typeInto(p, box.querySelectorAll('.lqin')[0], '2');
    await p.waitFor(() => box.querySelector('[data-act="ac"]').disabled === false,
      { label: 'zap preview', timeout: 6000 });
    p.click(box.querySelector('[data-act="ac"]'));
    await p.waitFor(() => p.chain.sent.length, { label: 'zap tx', timeout: 6000 });
    await p.settle();

    // ONE transaction: native input needs no approval and no checkpoint.
    assert.equal(p.chain.sent.length, 1, 'ETH in is a single call');
    const tx = p.chain.sent.at(-1);
    assert.equal(tx.to.toLowerCase(), A.ZROUTER.toLowerCase(), 'the router, not the pool');
    assert.equal(BigInt(tx.value), 2n * ETH, 'the deposit rides as value');

    const raw = tx.data.replace(/^0x/, '');
    assert.equal(raw.slice(0, 8), SEL.SNWAP);
    const body = '0x' + raw.slice(8);
    // previewZap mints amountIn/4 in the mock; the bound is that less 0.5%.
    const minLp = (2n * ETH / 4n) * 9950n / 10000n;
    assert.equal(wordAddr(body, 0), A.ZERO, 'native in');
    assert.equal(word(body, 1), 2n * ETH);
    assert.equal(wordAddr(body, 2).toLowerCase(), A.ACCOUNT.toLowerCase(), 'shares to the depositor');
    assert.equal(wordAddr(body, 3).toLowerCase(), POOL_A.toLowerCase(),
      'tokenOut is the POOL, so the router measures LP shares that actually land');
    assert.equal(word(body, 4), minLp, 'the router\'s own guard is the same bound');
    assert.equal(wordAddr(body, 5).toLowerCase(), A.PROUTE.toLowerCase(), 'PrecisionRoute executes');

    // The executor payload, unwrapped from snwap's trailing bytes argument.
    const inner = body.slice(2 + 7 * 64).replace(/^.{64}/, '');
    assert.equal(inner.slice(0, 8), SEL.ZAPIN);
    const z = '0x' + inner.slice(8);
    assert.equal(wordAddr(z, 0).toLowerCase(), POOL_A.toLowerCase());
    assert.equal(wordAddr(z, 1), A.ZERO, 'native in, so no checkpoint path');
    assert.equal(word(z, 2), 2n * ETH);
    assert.equal(word(z, 3), 1n * ETH, 'the split the lens bisected, not one invented here');
    assert.equal(word(z, 4), minLp);
    assert.equal(wordAddr(z, 5).toLowerCase(), A.ACCOUNT.toLowerCase(), 'shares');
    assert.equal(wordAddr(z, 6).toLowerCase(), A.ACCOUNT.toLowerCase(), 'and the leftovers');
    p.close();
  });

  test('shares can go to someone else; the change comes back to the depositor', async () => {
    const p = await setup();
    p.chain.names.set('alice.wei', A.OTHER);
    const box = await goZap(p);
    p.type('rc', 'alice.wei');
    typeInto(p, box.querySelectorAll('.lqin')[0], '2');
    await p.waitFor(() => box.querySelector('[data-act="ac"]').disabled === false,
      { label: 'zap preview', timeout: 6000 });
    p.click(box.querySelector('[data-act="ac"]'));
    await p.waitFor(() => p.chain.sent.length, { label: 'zap tx', timeout: 6000 });
    await p.settle();

    const body = '0x' + p.chain.sent.at(-1).data.replace(/^0x/, '').slice(8);
    // The router measures the LP balance that moved AT ITS RECIPIENT, so this
    // has to be the share recipient or the guard watches an account that gains
    // nothing - reverting every honest gift and bounding nothing that matters.
    assert.equal(wordAddr(body, 2).toLowerCase(), A.OTHER.toLowerCase(),
      'snwap measures where the shares actually land');
    const inner = body.slice(2 + 7 * 64).replace(/^.{64}/, '');
    const z = '0x' + inner.slice(8);
    assert.equal(wordAddr(z, 5).toLowerCase(), A.OTHER.toLowerCase(), 'shares to them');
    // Leftovers are change, and change goes back to whoever paid. Sweeping them
    // to the recipient also reverts the whole zap when that address cannot
    // receive ether - after the swap and deposit have already run.
    assert.equal(wordAddr(z, 6).toLowerCase(), A.ACCOUNT.toLowerCase(), 'refunds to the payer');
    p.close();
  });

  test('a name that does not resolve sends nothing at all', async () => {
    const p = await setup();
    const box = await goZap(p);
    p.type('rc', 'nobody.wei');
    typeInto(p, box.querySelectorAll('.lqin')[0], '2');
    await p.waitFor(() => box.querySelector('[data-act="ac"]').disabled === false,
      { label: 'zap preview', timeout: 6000 });
    p.click(box.querySelector('[data-act="ac"]'));
    await p.waitFor(() => /resolves/.test(p.text('stat')), { label: 'refusal' });
    // Never a silent fallback to the depositor: that looks like success until
    // the other party asks where their position is.
    assert.equal(p.chain.sent.length, 0, 'no value moves on an unresolved name');
    p.close();
  });

  test('refuses to send to a pool the factory disclaims', async () => {
    const p = await setup();
    const box = await goZap(p);
    p.chain.disownPool(POOL_A);
    typeInto(p, box.querySelectorAll('.lqin')[0], '2');
    await p.waitFor(() => box.querySelector('[data-act="ac"]').disabled === false,
      { label: 'zap preview', timeout: 6000 });
    p.click(box.querySelector('[data-act="ac"]'));
    await p.waitFor(() => /Not a Precision pool/.test(p.text('stat')), { label: 'refusal' });
    assert.equal(p.chain.sent.length, 0, 'value must never leave for an impersonator');
    p.close();
  });

  test('turning the mode off restores the two-sided form', async () => {
    const p = await setup();
    const box = await goZap(p);
    const [i0, i1] = box.querySelectorAll('.lqin');
    typeInto(p, i0, '2');
    const z = box.querySelector('.lqz');
    z.checked = false;
    z.dispatchEvent(new p.window.Event('change', { bubbles: true }));
    assert.equal(i1.classList.contains('hide'), false);
    // Re-derived rather than left blank: 2 ETH against a 100/300000 band.
    assert.equal(i1.value, '6000', 'the counterpart comes back from the reserves');
    assert.equal(box.querySelector('[data-act="ac"]').textContent, 'Add liquidity');
    p.close();
  });
});

describe('living beside the swap tile', () => {
  test('the recipient field stays, and says what it means here', async () => {
    const p = await setup();
    await p.waitFor(() => rows(p).length, { label: 'bands' });
    assert.equal(p.visible('rc'), true, 'it names the share recipient in this mode');
    assert.match(p.$('rc').placeholder, /LP shares to/);
    // The order-type sync rewrites this class on every keystroke, so a mode it
    // did not know about could hide the field mid-typing.
    p.type('amt', '1');
    await p.settle();
    assert.equal(p.visible('rc'), true, 'and it survives a keystroke');
    p.close();
  });

  test('a recipient typed for a swap cannot survive into a deposit', async () => {
    // Both directions. A field carried across a mode change is read as an
    // answer to a question that was never asked in the new mode - here, the
    // owner of a position.
    const p = await setup({ open: false });
    p.$('rc').value = '0x3333333333333333333333333333333333333333';
    p.click('lq');
    await p.settle();
    assert.equal(p.$('rc').value, '', 'cleared entering liquidity mode');
    p.$('rc').value = '0x4444444444444444444444444444444444444444';
    p.click('lq');
    await p.settle();
    assert.equal(p.$('rc').value, '', 'and cleared on the way back out');
    p.close();
  });

  test('offers a NEW band on a pair that already has one', async () => {
    /**
     * A PAIR IS NOT A POOL, which is the whole argument for this panel being a
     * list: ETH/USDC at [1800,2400] and at [1000,4000] are different positions.
     * Creation was reachable only from the empty state, so that choice existed
     * exactly until somebody made it once - and the tile's two amount fields,
     * which are the deposit for a band being created, sat visible and inert on
     * every pair that had one.
     */
    const p = await setup();
    await p.waitFor(() => rows(p).length, { label: 'bands' });
    assert.equal(!!p.$('lqList').querySelector('.lqnew'), false,
      'the form stays out of the way until it is asked for');
    const tog = p.$('lqNewTog');
    assert.ok(tog, 'a pair with bands must still offer a new one');

    tog.click();
    await p.settle();
    assert.ok(p.$('lqList').querySelector('.lqnew'), 'the create form opens in place');
    assert.ok(rows(p).length, 'without discarding the bands already listed');

    // And it is the same form: the tile amounts drive it, ratio as the price.
    // They are hidden while this form is collapsed - there they would feed
    // nothing - so they appear with it.
    assert.equal(p.visible('amtRow'), true, 'the amounts come back with the form');
    p.type('amt', '1');
    p.type('outAmt', '3000');
    await new Promise(r => p.window.setTimeout(r, 420));
    await p.settle();
    assert.match(p.$('lqRangeOut').textContent, /opens at 3,?000 USDC per ETH/,
      'the deposit ratio sets the opening price, as in the empty state');
    p.close();
  });

  test('keeps the token pickers, so the pair can still be changed', async () => {
    const p = await setup();
    await p.waitFor(() => rows(p).length, { label: 'bands' });
    // Hiding the panels wholesale took the pickers with them and froze the list.
    // The pickers stay; the AMOUNT ROWS do not. In this mode the tile is a pair
    // picker and nothing else - the deposit amounts belong to the form that
    // spends them, whether that is a row's add or the create form.
    // With bands listed and the create form collapsed, the amounts have nothing
    // to feed - so they are not on screen pretending otherwise.
    assert.equal(p.visible('amtRow'), false, 'inert amounts must not be shown');
    assert.equal(p.visible('outRow'), false);
    assert.equal(p.visible('swap'), false, 'but there is nothing to swap');
    assert.ok(p.$('fromSel').offsetParent !== undefined);
    assert.equal(p.$('fromSel').closest('.panel').classList.contains('hide'), false,
      'the pair filter stays on screen');
    p.close();
  });

  test('re-reads the RECEIVE balance when that token changes', async () => {
    // Liquidity mode is the only mode that reads a balance off both selects -
    // the second amount is a deposit, not an output - and only the pay side was
    // refreshed on a change. So swapping the receive token left the balance
    // line, and the Max link that fills from it, pinned to the token that had
    // just been replaced: clicking Max offered someone their USDC balance as an
    // amount of USDT.
    const p = await setup();
    await p.waitFor(() => /Balance/.test(p.text('bal1')), { label: 'the receive balance' });
    p.chain.setErc20(A.USDT, A.ACCOUNT, 7n * USDC);
    p.pickToken('toSel', 'USDT');
    await p.waitFor(() => /Balance: 7\b/.test(p.text('bal1')), { label: 'the new token balance' });

    // ETH/USDT has no bands, so the create form is open and the amounts are on
    // screen - which is the only state where Max has anywhere to put a number.
    await p.waitFor(() => p.$('lqList').querySelector('.lqnew'), { label: 'the create form' });
    p.$('bal1').querySelector('a').dispatchEvent(
      new p.window.MouseEvent('click', { bubbles: true, cancelable: true }));
    await p.settle();
    assert.equal(p.value('outAmt'), '7', 'and Max fills from the token now selected');
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

/**
 * The other half of the seed pin.
 *
 * `previewSeed` reads the band OFF THE POOL, so it cannot answer for a band
 * that has not been deployed - which is every band the create form makes. The
 * page therefore mirrors the seed itself, in BigInt, and a mirror is only worth
 * having while something holds it to the original. Neither side gets to be the
 * reference: test/PrecisionSeedPreviewFixture.t.sol asserts the LENS still
 * produces test/fixtures/seed-preview.json, and this asserts the PAGE
 * reproduces the same file. Move the math on either side and exactly one of the
 * two fails, which names the side that moved.
 *
 * Regenerate with `forge script script/PrecisionSeedFixture.s.sol`.
 */
describe('the page\'s seed mirror', () => {
  const cases = JSON.parse(readFileSync(new URL('../fixtures/seed-preview.json', import.meta.url), 'utf8'));

  test('reproduces every case the lens produced', async () => {
    const p = await setup({ open: false });
    assert.ok(cases.length, 'empty fixture');
    for (const c of cases) {
      const got = p.window.lqSeedQuote(BigInt(c.sl), BigInt(c.sh), BigInt(c.s), BigInt(c.a0), BigInt(c.a1));
      assert.equal(got.ok, c.ok, `ok: ${c.desc}`);
      assert.equal(got.lp, BigInt(c.lp), `lp: ${c.desc}`);
      assert.equal(got.used0, BigInt(c.used0), `used0: ${c.desc}`);
      assert.equal(got.used1, BigInt(c.used1), `used1: ${c.desc}`);
    }
    p.close();
  });

  test('refuses a band wider than the factory will build', async () => {
    // sqrtPHigh > 1e36 reverts Bad() in the factory, and a mirror that answered
    // for it would be previewing a market that cannot exist.
    const p = await setup({ open: false });
    const over = 10n ** 36n + 1n;
    assert.equal(p.window.lqSeedQuote(10n ** 18n, over, 10n ** 27n, 10n ** 20n, 10n ** 20n).ok, false);
    p.close();
  });
});

/**
 * The refusals the mirror does NOT carry.
 *
 * `lqSeedQuote` mirrors the LENS, and the lens stops where `previewSeed` stops:
 * it models `_seed`'s arithmetic and the seed price tolerance, but not the
 * uint128 reserve bound, not `_priceInRange`, and not `_tradeable`. All three
 * live in `_addLiquidity`, all three refuse a seed, and the page used to print
 * "Seeds X + Y" for every one of them and let the wallet deliver the revert.
 *
 * `lqSeedAdmits` is that missing layer, kept OUT of the mirror so the fixture
 * pin above still means what it says.
 *
 * ONLY THE uint128 BOUND IS KNOWN TO BITE. A randomised sweep of ~600k seeds
 * across the whole band and amount space found no case where the price and
 * tradeability checks refused something the tolerance test had already
 * admitted; they are carried because the pool carries them and the search is
 * not a proof, not because a case is known. The test below pins the one that
 * does, and the one after it guards the far more likely failure of the other
 * two - refusing a band that is perfectly fine.
 */
describe('the seed refusals the lens does not model', () => {
  test('refuses a seed whose reserves would not fit uint128', async () => {
    const p = await setup({ open: false });
    // A band opened at its ceiling by a token1 amount past 2^128. The mirror
    // admits it: every figure it checks is in range, and `used1 <= amount1`
    // holds. `_seed` does not - it bounds both requirements by uint128 before
    // it corrects them, because `_setReserves` could not hold the result.
    const sl = 10n ** 6n, sh = 10n ** 24n, s = sh;
    const a0 = 10n ** 45n, a1 = 10n ** 42n;
    const q = p.window.lqSeedQuote(sl, sh, s, a0, a1);
    assert.equal(q.ok, true, 'the mirror admits it, which is the point');
    assert.ok(q.used1 > (1n << 128n) - 1n, 'and the amount it asks for is past uint128');
    assert.equal(p.window.lqSeedAdmits(sl, sh, s, 3000n, q), false);
    p.close();
  });

  test('admits every seed the lens fixture accepts', async () => {
    // The layer's real risk is not missing a refusal, it is inventing one: a
    // band the pool would open, refused by the page with no way to tell. Every
    // accepted fixture case has to survive it, at all three fee tiers.
    const p = await setup({ open: false });
    const cases = JSON.parse(readFileSync(new URL('../fixtures/seed-preview.json', import.meta.url), 'utf8'));
    let checked = 0;
    for (const c of cases.filter(x => x.ok)) {
      const q = p.window.lqSeedQuote(BigInt(c.sl), BigInt(c.sh), BigInt(c.s), BigInt(c.a0), BigInt(c.a1));
      for (const fee of [500n, 3000n, 10000n]) {
        assert.equal(p.window.lqSeedAdmits(BigInt(c.sl), BigInt(c.sh), BigInt(c.s), fee, q), true,
          `${c.desc} at ${fee} pips`);
        checked++;
      }
    }
    assert.ok(checked > 0, 'the fixture has accepted cases to check');
    p.close();
  });

  test('says so in the form instead of sending the seed', async () => {
    // A USDC-only seed at the top of a band running from 1e-6 to 1e24. Every
    // figure the LENS checks is in range and `used1 <= amount1` holds, so the
    // mirror admits it - but the amount it asks the pool to hold is past
    // uint128, and `_seed` refuses on exactly that.
    const p = await setup({ bands: [], shares: 0n });
    await p.waitFor(() => p.$('lqCreate'), { label: 'create form' });
    typeInto(p, p.$('lqRange'), 'custom');
    p.$('lqRange').dispatchEvent(new p.window.Event('change', { bubbles: true }));
    await p.settle();
    typeInto(p, p.$('lqLo'), '0.000001');
    typeInto(p, p.$('lqHi'), '1e24');
    typeInto(p, p.$('lqPx'), '1e24');     // a one-sided seed opens at the ceiling
    // Spelled out: `parseUnits` reads digits, not exponents. Typed last, so the
    // amount is what the final preview run reacts to.
    typeInto(p, p.$('outAmt'), '1' + '0'.repeat(36));   // USDC, token1, alone
    await new Promise(r => p.window.setTimeout(r, 420));
    await p.settle();

    assert.match(p.text('lqPv'), /could not be traded once opened/);
    assert.equal(p.$('lqCreate').disabled, true, 'and the button stays shut');
    assert.equal(p.chain.sent.length, 0, 'nothing was sent');
    p.close();
  });
});

/**
 * What an LP actually keeps.
 *
 * A launcher pool charges 1% and hands HALF to the creator before the rest
 * reaches reserves - so "1.00%" on the panel reads as LP yield when only half
 * of it is. `creatorFeeBps` is an immutable on the pool, zero everywhere else,
 * so this is a read rather than a guess about where a pool came from.
 */
describe('the fee a pool shows an LP', () => {
  const LAUNCHED = {
    pool: POOL_A, fee: 10000n, creatorFeeBps: 5000n, liquidity: 10n ** 21n,
    reserve0: 100n * ETH, reserve1: 300000n * USDC,
    sqrtLow: sqrtRaw(2000), sqrtHigh: sqrtRaw(4000), sqrtNow: sqrtRaw(3000),
  };

  test('names the LP share when a slice goes to a creator', async () => {
    const p = await setup({ bands: [LAUNCHED] });
    const t = p.$('lqList').textContent;
    assert.match(t, /1\.00%/, `headline fee missing: ${t.slice(0, 200)}`);
    assert.match(t, /0\.50% to LPs/, `LP share not named: ${t.slice(0, 200)}`);
    p.close();
  });

  test('an ordinary pool renders exactly as it always did', async () => {
    // The whole design constraint: no second code path, and no new noise on
    // the pools that make up almost all of them.
    const p = await setup({ bands: [BAND_A] });
    const t = p.$('lqList').textContent;
    assert.match(t, /0\.30%/);
    assert.ok(!/to LPs/.test(t), `an ordinary pool grew a fee split: ${t.slice(0, 200)}`);
    p.close();
  });
});

/**
 * A MISSED BOUND IS NOT A SHORT POOL.
 *
 * The strict exit is preflighted with an `eth_call`, and ANY refusal used to
 * send the page to the degraded one. But `removeLiquidity` reverts
 * `InsufficientOutput` whenever the price moved between the preview and the
 * send — the most ordinary thing that can happen to a pool with traffic, and it
 * says nothing at all about whether the pool can pay.
 *
 * So an LP in a perfectly healthy pool was told one of its tokens was short,
 * and offered an exit carrying minimums of ZERO as the remedy. The two causes
 * are distinguishable by selector and now are.
 */
describe('telling a moved price from a short pool', () => {
  const MINOUT = '0xbb2875c3';  // PrecisionPool.InsufficientOutput()
  const DEFICIT = '0xa9e4150c'; // PrecisionPool.BalanceDeficit()
  const strictSent = p => p.chain.sent.filter(
    t => (t.data || '').replace(/^0x/, '').slice(0, 8) === SEL.REMOVE);
  const lossySent2 = p => p.chain.sent.filter(
    t => (t.data || '').replace(/^0x/, '').slice(0, 8) === SEL.REMOVE_LOSSY);

  /** Refuse the first preflight with `err`, then behave. */
  const failOnce = (p, err) => {
    let n = 0;
    p.chain.revertOn(POOL_A, SEL.REMOVE, () => (n++ === 0 ? err : null));
  };

  for (const [shape, err] of [
    ['revert data', { data: MINOUT }],
    ['the message', `execution reverted: ${MINOUT}`],
  ]) {
    test(`re-quotes instead of degrading, when the bound missed (${shape})`, async () => {
      const p = await setup();
      failOnce(p, err);
      await p.waitFor(() => btn(p, 'w'), { label: 'withdraw button' });
      p.click(btn(p, 'w'));
      await p.waitFor(() => strictSent(p).length, { label: 'a second strict attempt' });
      await p.settle();
      assert.equal(lossySent2(p).length, 0, 'the degraded exit is not for a moved price');
      assert.equal(p.asked.confirm.length, 0,
        'and the user must not be asked to accept a loss that is not happening');
      p.close();
    });
  }

  test('keeps a real bound on the retry rather than dropping to zero', async () => {
    // The whole harm of the old path was swapping a bounded withdrawal for an
    // unbounded one. A retry that carried zeros would be the same bug wearing a
    // different message.
    const p = await setup();
    failOnce(p, { data: MINOUT });
    await p.waitFor(() => btn(p, 'w'), { label: 'withdraw button' });
    p.click(btn(p, 'w'));
    await p.waitFor(() => strictSent(p).length, { label: 'a second strict attempt' });
    await p.settle();
    const body = '0x' + strictSent(p).at(-1).data.replace(/^0x/, '').slice(8);
    assert.ok(word(body, 1) > 0n, 'min0 must still bound the withdrawal');
    assert.ok(word(body, 2) > 0n, 'and min1 too');
    p.close();
  });

  test('still reaches the degraded exit for a pool that really is short', async () => {
    const p = await setup();
    p.chain.revertOn(POOL_A, SEL.REMOVE, { data: DEFICIT });
    p.queueConfirm(true);
    await p.waitFor(() => btn(p, 'w'), { label: 'withdraw button' });
    p.click(btn(p, 'w'));
    await p.waitFor(() => lossySent2(p).length, { label: 'lossy withdrawal' });
    await p.settle();
    assert.match(p.asked.confirm.at(-1), /cannot pay out in full|short/i);
    p.close();
  });

  test('sends nothing when the price keeps moving', async () => {
    // Two misses in a row is a moving market, not a broken pool. Saying so and
    // stopping is the honest answer; reaching for the degraded exit here would
    // spend the LP's slippage protection on a problem it cannot solve.
    const p = await setup();
    p.chain.revertOn(POOL_A, SEL.REMOVE, { data: MINOUT });
    await p.waitFor(() => btn(p, 'w'), { label: 'withdraw button' });
    p.click(btn(p, 'w'));
    await p.waitFor(() => /moved while this was quoted/i.test(p.text('stat')),
      { label: 'the explanation' });
    assert.equal(p.chain.sent.length, 0, 'and nothing may go out');
    assert.equal(p.asked.confirm.length, 0);
    p.close();
  });
});

/**
 * A ZAP NAMES THE TOKEN IT IS BUYING, AND KEEPS THE SIDE THE DEPOSITOR CHOSE.
 *
 * Both halves of this were the same mistake in two places: the form treats the
 * two boxes symmetrically until something has to say which one is the deposit.
 *
 * The preview line was written for token0 and hard-coded token1 as the thing
 * bought, so a token1 zap read "swaps 1,500 of 3,000 USDC for USDC" - a line
 * that describes no trade at all, on the screen whose entire job is to say
 * that half the deposit gets traded at the pool's fee.
 *
 * The toggle had the mirror image of it. Below the checkbox the two boxes are a
 * RATIO and the page fills the counterpart in as you type; above it they are
 * one deposit and a filled counterpart is an ambiguity. Turning one-sided on
 * therefore refused the very state the form had just written itself, and told
 * the depositor to clear a field they never typed.
 */
describe('a one-sided deposit', () => {
  const openAdd = async p => {
    await p.waitFor(() => btn(p, 'a'), { label: 'add button' });
    p.click(btn(p, 'a'));
    const box = rows(p)[0].querySelector('.lqadd');
    await p.waitFor(() => !box.classList.contains('hide'), { label: 'add form' });
    return box;
  };
  const toggle = async (p, box, on) => {
    const z = box.querySelector('.lqz');
    z.checked = on;
    z.dispatchEvent(new p.window.Event('change', { bubbles: true }));
    await p.settle();
  };

  test('names the other token as what the swap leg buys', async () => {
    const p = await setup();
    const box = await openAdd(p);
    await toggle(p, box, true);
    typeInto(p, box.querySelectorAll('.lqin')[1], '3000');
    await p.waitFor(() => /swaps/.test(box.querySelector('.lqpv').textContent),
      { label: 'token-side zap preview', timeout: 6000 });
    const line = box.querySelector('.lqpv').textContent;
    assert.match(line, /USDC for ETH/, 'a USDC zap buys the other side, not itself');
    assert.doesNotMatch(line, /USDC for USDC/, 'no deposit ever trades a token for itself');
    p.close();
  });

  test('drops the mirrored counterpart instead of asking for it back', async () => {
    // Type ONE side with the checkbox off: the page mirrors the other. Turning
    // it on must keep the typed side and discard the page's own arithmetic.
    const p = await setup();
    const box = await openAdd(p);
    const [i0, i1] = box.querySelectorAll('.lqin');
    typeInto(p, i0, '2');
    await p.waitFor(() => i1.value !== '', { label: 'the mirror to fill' });
    await toggle(p, box, true);
    assert.equal(i0.value, '2', 'the side the depositor typed survives');
    assert.equal(i1.value, '', 'the side the page wrote does not');
    await p.waitFor(() => /swaps/.test(box.querySelector('.lqpv').textContent),
      { label: 'the zap preview', timeout: 6000 });
    assert.doesNotMatch(box.querySelector('.lqpv').textContent, /One side only/,
      'the form must not refuse a state it wrote itself');
    p.close();
  });

  test('still refuses two sides the depositor actually typed', async () => {
    const p = await setup();
    const box = await openAdd(p);
    await toggle(p, box, true);
    const [i0, i1] = box.querySelectorAll('.lqin');
    typeInto(p, i0, '2');
    typeInto(p, i1, '3000');
    await p.waitFor(() => /One side only/.test(box.querySelector('.lqpv').textContent),
      { label: 'the ambiguity to be named', timeout: 6000 });
    assert.equal(box.querySelector('[data-act="ac"]').disabled, true);
    p.close();
  });
});
