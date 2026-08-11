/**
 * The price-tape drawer under the swap tile.
 *
 * The chart reads PrecisionPool storage directly, so the things worth pinning
 * are: it stays out of the way until asked for, it costs one batched call, it
 * charts the pool that actually traded, and it says so plainly when there is
 * nothing to show.
 */
import { test, describe, after } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import {
  A, SEL, MockChain, loadPage, fixedRateQuoter, closeAllPages, word,
} from './harness.mjs';

after(closeAllPages);

const ETH = 10n ** 18n;
const USDC = 10n ** 6n;
const LENS = '0x4444444444444444444444444444444444444444';
const POOL_A = '0x5555555555555555555555555555555555555555';
const POOL_B = '0x6666666666666666666666666666666666666666';

/**
 * Point the page's PPLENS at the mock lens.
 *
 * Matched by SHAPE rather than by a literal address. This used to hardcode the
 * zero placeholder the page shipped before the lens was deployed; the moment a
 * real address landed in zSwap.html every test in this file failed on a missed
 * patch target. The harness throwing on a miss is what made that loud instead
 * of silently testing an unpatched page - but the fix is to not depend on which
 * address happens to be canonical today.
 */
const CUR_PPLENS = (() => {
  const html = readFileSync(new URL('../../zSwap.html', import.meta.url), 'utf8');
  const m = html.match(/const PPLENS="(0x[0-9a-fA-F]{40})"/);
  if (!m) throw Error('zSwap.html no longer declares PPLENS');
  return m[0];
})();
const patchFactory = (addr = LENS) => [[CUR_PPLENS, `const PPLENS="${addr}"`]];

/**
 * The pool stores RAW prices: token1 per token0, 1e18-scaled, decimals NOT
 * normalised. For ETH(18)/USDC(6) that is human x 10^(18 + 6 - 18) = x1e6.
 * Fixtures use the real convention so the client's unscaling is under test.
 */
const RAW_ETH_USDC = 1e6;

/** `n` five-minute bars ending now, drifting upward, with one idle bucket. */
function bars(n, { start = 3000, pool = 1 } = {}) {
  const bucket = Math.floor(Date.now() / 1000 / 300);
  const out = [];
  let p = start;
  for (let i = 0; i < n; i++) {
    const o = p;
    p = p * 1.004;
    out.push(i === 2 ? null : {
      bucket: bucket - i,
      open: o * RAW_ETH_USDC, high: p * 1.002 * RAW_ETH_USDC,
      low: o * 0.998 * RAW_ETH_USDC, close: p * RAW_ETH_USDC,
      volume: 10 * pool * 1e18, count: 3,
    });
  }
  return out; // newest first, matching the contract
}

async function setup({ deployed = true, pools = [POOL_A], tapes = null, open = true } = {}) {
  const chain = new MockChain();
  chain.setNative(A.ACCOUNT, 10n * ETH);
  chain.setErc20(A.USDC, A.ACCOUNT, 5000n * USDC);
  chain.quoteHandler = fixedRateQuoter({ rate: 3000n * ETH });
  chain.setCode(LENS, deployed ? '0x60006000' : '0x');
  chain.setPools(A.ZERO, A.USDC, pools);
  for (const [pool, b] of Object.entries(tapes || { [POOL_A]: bars(24) })) chain.setTape(pool, b);

  const page = await loadPage({
    chain,
    patch: patchFactory(),
    storage: open ? { ch: '1' } : {},
  });
  await page.connect();
  return page;
}

const svg = p => p.$('chArt').querySelector('svg');

describe('the drawer', () => {
  test('is hidden until a wallet is connected', async () => {
    const chain = new MockChain();
    chain.quoteHandler = fixedRateQuoter({ rate: 3000n * ETH });
    chain.setCode(LENS, '0x60006000');
    const p = await loadPage({ chain, patch: patchFactory() });
    assert.equal(p.visible('chTog'), false, 'nothing to chart without an account');
    p.close();
  });

  test('stays closed by default, and draws nothing until opened', async () => {
    const p = await setup({ open: false });
    await p.settle();
    assert.equal(p.visible('chBox'), false);
    assert.equal(p.$('chTog').getAttribute('aria-expanded'), 'false');
    assert.equal(svg(p), null, 'a closed drawer must not render');
    // Hiding the control when a pair has no data means the page has to look:
    // one batched lens read per pair, cached, is the price of not showing a
    // dead control.
    assert.equal(p.chain.calls.filter(c => c.selector === SEL.MARKETS).length, 1);
    p.close();
  });

  test('opens on click, remembers that, and reads the pair', async () => {
    const p = await setup({ open: false });
    p.click('chTog');
    await p.waitFor(() => svg(p), { label: 'chart' });
    assert.equal(p.$('chTog').getAttribute('aria-expanded'), 'true');
    assert.equal(p.window.localStorage.getItem('ch'), '1', 'the choice must survive a reload');
    p.close();
  });

  test('hides itself entirely when no factory is deployed', async () => {
    const p = await setup({ deployed: false });
    await p.settle();
    assert.equal(p.visible('chTog'), false,
      'an undeployed factory must not leave a dead control on the page');
    p.close();
  });

  test('is absent on the send and orders tabs', async () => {
    const p = await setup();
    await p.waitFor(() => svg(p), { label: 'chart' });
    p.click('tabSend');
    await p.settle();
    assert.equal(p.visible('chTog'), false, 'a transfer has no pair to chart');
    p.click('tabSwap');
    await p.settle();
    assert.equal(p.visible('chTog'), true);
    p.close();
  });
});

describe('reading the tape', () => {
  test('finds the pool then reads its bars, batched', async () => {
    const p = await setup();
    await p.waitFor(() => svg(p), { label: 'chart' });

    const pairReads = p.chain.calls.filter(c => c.selector === SEL.MARKETS);
    const tapeReads = p.chain.calls.filter(c => c.selector === SEL.TAPE);
    assert.equal(pairReads.length, 1, 'one pool lookup');
    // Two tapes per pool: the fine ring spans ~21h, the coarse one weeks.
    assert.equal(tapeReads.length, 2, 'fine and coarse, in the same batch');
    const periods = tapeReads.map(c => Number(word('0x' + c.data.slice(10), 0))).sort((a, b) => a - b);
    assert.deepEqual(periods, [300, 14400], 'both bar widths are requested');
    // Both went through aggregate3 rather than as loose calls.
    assert.ok(p.chain.calls.some(c => c.selector === SEL.AGG3), 'reads must be batched');
    p.close();
  });

  test('asks for the pair in canonical order, not selection order', async () => {
    const p = await setup();
    await p.waitFor(() => svg(p), { label: 'chart' });
    const call = p.chain.calls.find(c => c.selector === SEL.MARKETS);
    const body = '0x' + call.data.slice(10);
    // ETH is the zero address, so it sorts first whichever way the form faces.
    assert.match(body.slice(2, 66), /^0{64}$/, 'token0 is the lower address');
    p.close();
  });

  test('shows human prices, not the raw 1e18 units the pool stores', async () => {
    // The regression this guards: the decoder masked the price field to 24
    // bits, dropping the float's exponent, and every candle read as its
    // mantissa. It looked plausible and was off by orders of magnitude.
    const bucket = Math.floor(Date.now() / 1000 / 300);
    const flat = [{ bucket, open: 3000 * RAW_ETH_USDC, high: 3000 * RAW_ETH_USDC,
      low: 3000 * RAW_ETH_USDC, close: 3000 * RAW_ETH_USDC, volume: 5e18, count: 1 }];
    const p = await setup({ tapes: { [POOL_A]: flat } });
    await p.waitFor(() => svg(p), { label: 'chart' });
    const shown = Number(p.$('chArt').querySelector('.hd b').textContent.replace(/,/g, ''));
    assert.ok(Math.abs(shown - 3000) / 3000 < 0.001,
      `a pool printing 3000 USDC per ETH must chart near 3000, got ${shown}`);
    p.close();
  });

  test('runs oldest to newest, and reports the latest close', async () => {
    // The regression this guards: the tape is stored newest-first and was drawn
    // in that order, so time ran right-to-left, the headline price was the
    // OLDEST close, and the change percentage carried the wrong sign.
    const bucket = Math.floor(Date.now() / 1000 / 300);
    const at = (i, px) => ({ bucket: bucket - i, open: px * RAW_ETH_USDC, high: px * RAW_ETH_USDC,
      low: px * RAW_ETH_USDC, close: px * RAW_ETH_USDC, volume: 5e18, count: 1 });
    const p = await setup({ tapes: { [POOL_A]: [at(0, 3000), at(1, 2000), at(2, 1000)] } });
    await p.waitFor(() => svg(p), { label: 'chart' });

    const hud = p.$('chArt').querySelector('.hd').textContent;
    assert.match(hud, /3,000/, 'the headline is the newest close, not the oldest');
    assert.match(hud, /\+200/, 'a market that tripled must not read as a fall');
    p.close();
  });

  test('caps how many bars it draws, so candles stay legible', async () => {
    const p = await setup({ tapes: { [POOL_A]: bars(250) } });
    await p.waitFor(() => svg(p), { label: 'chart' });
    // 250 bars in ~300px is a smear; the drawer keeps the most recent that fit.
    const wicks = svg(p).querySelectorAll('line').length - 4;   // minus gridlines
    assert.ok(wicks < 130, `drew ${wicks} candles, which cannot resolve at this width`);
    assert.match(p.text('chNote'), /last /, 'and says the window was clipped');
    p.close();
  });

  test('offers a line chart, and remembers the choice', async () => {
    const p = await setup();
    await p.waitFor(() => svg(p), { label: 'chart' });
    const btn = [...p.$('chTf').children].find(b => b.className === 'chk');
    assert.equal(btn.textContent, 'Line', 'the button names the action, not the state');
    assert.equal(svg(p).querySelector('path'), null, 'candles by default');

    p.click(btn);
    assert.ok(svg(p).querySelector('path'), 'a line is drawn');
    assert.equal(btn.textContent, 'Candle');
    assert.equal(p.window.localStorage.getItem('ck'), 'line');
    p.close();

    const p2 = await setup();
    p2.window.localStorage.setItem('ck', 'line');
    p2.close();
  });

  test('draws candles and a volume track', async () => {
    const p = await setup();
    await p.waitFor(() => svg(p), { label: 'chart' });
    const s = svg(p);
    assert.ok(s.querySelectorAll('rect').length > 20, 'candle bodies and volume bars');
    assert.ok(s.querySelectorAll('line').length > 20, 'wicks and gridlines');
    assert.match(p.$('chArt').querySelector('.hd').textContent, /%/, 'shows the period change');
    p.close();
  });

  test('labels the price orientation and how many pools it aggregated', async () => {
    const p = await setup();
    await p.waitFor(() => p.text('chNote') !== '', { label: 'note' });
    assert.match(p.text('chNote'), /USDC per ETH/, 'a chart must say which way round it is');
    assert.match(p.text('chNote'), /1 pool\b/);
    p.close();
  });

  test('aggregates every eligible pool for the pair', async () => {
    const p = await setup({
      pools: [POOL_A, POOL_B],
      tapes: { [POOL_A]: bars(24, { pool: 1 }), [POOL_B]: bars(24, { pool: 9 }) },
    });
    await p.waitFor(() => p.text('chNote') !== '', { label: 'note' });
    assert.match(p.text('chNote'), /2 pools/, 'both pools feed one series');
    const reads = p.chain.calls.filter(c => c.selector === SEL.TAPE);
    assert.equal(reads.length, 4, 'two pools x two bar widths, in one batch');
    p.close();
  });

  test('excludes hooked pools, which can price trades arbitrarily', async () => {
    const p = await setup({
      pools: [POOL_A, { pool: POOL_B, hook: '0x9999999999999999999999999999999999999999' }],
      tapes: { [POOL_A]: bars(24), [POOL_B]: bars(24) },
    });
    await p.waitFor(() => p.text('chNote') !== '', { label: 'note' });
    assert.match(p.text('chNote'), /1 pool\b/, 'a surcharge hook disqualifies a pool');
    const read = p.chain.calls.filter(c => c.selector === SEL.TAPE);
    assert.equal(read.length, 2, 'only the eligible pool is read, at both widths');
    p.close();
  });

  test('excludes empty pools, which have no price to contribute', async () => {
    const p = await setup({
      pools: [POOL_A, { pool: POOL_B, liquidity: 0n }],
      tapes: { [POOL_A]: bars(24), [POOL_B]: bars(24) },
    });
    await p.waitFor(() => p.text('chNote') !== '', { label: 'note' });
    assert.match(p.text('chNote'), /1 pool\b/);
    p.close();
  });

  test('volume-weights the aggregate so a thin pool cannot move the print', async () => {
    // Same buckets, wildly different prices; the deep pool holds 99% of volume.
    const bucket = Math.floor(Date.now() / 1000 / 300);
    const at = (px, v) => [{ bucket, open: px * RAW_ETH_USDC, high: px * RAW_ETH_USDC,
      low: px * RAW_ETH_USDC, close: px * RAW_ETH_USDC, volume: v, count: 1 }];
    const one = v => at(100, v);
    const thin = at(1, 1e18);
    const p = await setup({
      pools: [POOL_A, POOL_B],
      tapes: { [POOL_A]: one(99e18), [POOL_B]: thin },
    });
    await p.waitFor(() => svg(p), { label: 'chart' });
    var shown = Number(p.$('chArt').querySelector('.hd b').textContent.replace(/,/g, ''));
    assert.ok(shown > 90, `volume-weighted close ${shown} must sit near the deep pool's 100`);
    p.close();
  });

  test('re-reads when the pair changes', async () => {
    const p = await setup();
    await p.waitFor(() => svg(p), { label: 'chart' });
    const before = p.chain.calls.filter(c => c.selector === SEL.MARKETS).length;
    p.pickToken('toSel', 'WBTC');
    await p.waitFor(
      () => p.chain.calls.filter(c => c.selector === SEL.MARKETS).length > before,
      { label: 're-read' });
    p.close();
  });

  test('flipping the form does not re-read: the pair is the same market', async () => {
    const p = await setup();
    await p.waitFor(() => svg(p), { label: 'chart' });
    const before = p.chain.calls.filter(c => c.selector === SEL.MARKETS).length;
    p.click('flip');
    await p.settle();
    assert.equal(p.chain.calls.filter(c => c.selector === SEL.MARKETS).length, before,
      'ETH/USDC and USDC/ETH are one market, and the chart is quoted canonically');
    assert.ok(svg(p), 'and the chart stays up');
    p.close();
  });

  test('caches a pair, so flipping back and forth is free', async () => {
    const p = await setup();
    await p.waitFor(() => svg(p), { label: 'chart' });
    const before = p.chain.calls.filter(c => c.selector === SEL.TAPE).length;
    p.pickToken('toSel', 'WBTC');
    await p.settle();
    p.pickToken('toSel', 'USDC');
    await p.settle();
    assert.equal(p.chain.calls.filter(c => c.selector === SEL.TAPE).length, before,
      'returning to a pair read moments ago must not re-read it');
    p.close();
  });
});

describe('reading a single bar', () => {
  /** Pointer at a fraction across the chart, in element coordinates. */
  function pointAt(p, frac) {
    const el = p.$('chArt');
    el.getBoundingClientRect = () => ({ left: 0, width: 340, top: 0, height: 150 });
    el.dispatchEvent(new p.window.MouseEvent('pointermove',
      { bubbles: true, clientX: 340 * frac, clientY: 40 }));
  }

  test('pointing at the chart spells out that bar', async () => {
    const p = await setup({ tapes: { [POOL_A]: bars(40) } });
    await p.waitFor(() => svg(p), { label: 'chart' });
    const resting = p.$('chArt').querySelector('.hd').textContent;

    pointAt(p, 0.25);
    const hd = p.$('chArt').querySelector('.hd');
    assert.match(hd.textContent, /H .* L /, 'high and low are named, not guessed from pixels');
    assert.match(hd.textContent, /trade/, 'and how many trades made the bar');
    assert.notEqual(hd.textContent, resting, 'the readout follows the pointer');
    assert.ok(svg(p).querySelector('.cross'), 'a crosshair marks which bar');
    p.close();
  });

  test('leaving the chart restores the latest price', async () => {
    const p = await setup({ tapes: { [POOL_A]: bars(40) } });
    await p.waitFor(() => svg(p), { label: 'chart' });
    const resting = p.$('chArt').querySelector('.hd').textContent;

    pointAt(p, 0.5);
    p.$('chArt').dispatchEvent(new p.window.MouseEvent('pointerleave', { bubbles: true }));
    assert.equal(p.$('chArt').querySelector('.hd').textContent, resting);
    assert.equal(svg(p).querySelector('.cross'), null, 'the crosshair goes with it');
    p.close();
  });

  test('the chart describes itself to a screen reader', async () => {
    const p = await setup();
    await p.waitFor(() => svg(p), { label: 'chart' });
    const label = svg(p).getAttribute('aria-label');
    assert.match(label, /USDC per ETH/, 'which pair');
    assert.match(label, /now/, 'and where it stands');
    assert.match(label, /range/, 'and the range it covers');
    p.close();
  });
});

describe('timeframes', () => {
  test('offers 5m, 1h and 1d', async () => {
    const p = await setup();
    await p.waitFor(() => svg(p), { label: 'chart' });
    const strip = [...p.$('chTf').children];
    assert.deepEqual(strip.filter(b => b.className !== 'chk').map(b => b.textContent),
      ['5m', '1h', '1d']);
    assert.equal(strip[strip.length - 1].className, 'chk', 'chart type sits after the timeframes');
    p.close();
  });

  test('a daily candle is built from the coarse tape, not a stub of the fine one', async () => {
    // The fine ring spans about 21 hours, so rolling it up gives one or two
    // daily bars. The pool also keeps a four-hour tape covering weeks.
    const cb = Math.floor(Date.now() / 1000 / 14400);
    const coarse = [];
    for (let i = 0; i < 30; i++) {
      const px = (3000 + i * 5) * RAW_ETH_USDC;
      coarse.push({ bucket: cb - i, open: px, high: px, low: px, close: px, volume: 9e18, count: 4 });
    }
    const chain = new MockChain();
    chain.setNative(A.ACCOUNT, 10n * ETH);
    chain.quoteHandler = fixedRateQuoter({ rate: 3000n * ETH });
    chain.setCode(LENS, '0x60006000');
    chain.setPools(A.ZERO, A.USDC, [POOL_A]);
    chain.setTape(POOL_A, bars(24), 300);
    chain.setTape(POOL_A, coarse, 14400);
    const p = await loadPage({ chain, patch: patchFactory(), storage: { ch: '1' } });
    await p.connect();
    await p.waitFor(() => svg(p), { label: 'chart' });

    [...p.$('chTf').children].find(b => b.textContent === '1d').dispatchEvent(
      new p.window.MouseEvent('click', { bubbles: true }));
    await p.settle();
    // 30 four-hour bars is five days; the fine tape alone could not reach past one.
    assert.match(p.text('chNote'), /\d+d/, 'the daily view must span days');
    assert.ok(svg(p).querySelectorAll('line').length > 8, 'and draw more than a stub');
    p.close();
  });

  test('rolling up is done locally, with no extra chain read', async () => {
    const p = await setup({ tapes: { [POOL_A]: bars(120) } });
    await p.waitFor(() => svg(p), { label: 'chart' });
    const fine = svg(p).querySelectorAll('rect').length;
    const readsBefore = p.chain.calls.length;

    [...p.$('chTf').children].find(b => b.textContent === '1h').dispatchEvent(
      new p.window.MouseEvent('click', { bubbles: true }));
    await p.settle();

    assert.equal(p.chain.calls.length, readsBefore, 'aggregation must not hit the chain');
    assert.ok(svg(p).querySelectorAll('rect').length < fine, 'an hour bar covers twelve five-minute bars');
    p.close();
  });
});

describe('when there is nothing to show', () => {
  test('shows no control at all when the pair has no pool', async () => {
    const p = await setup({ pools: [] });
    await p.settle();
    assert.equal(p.visible('chTog'), false, 'an empty drawer is worse than no drawer');
    assert.equal(p.visible('chBox'), false);
    p.close();
  });

  test('shows no control when the pools exist but have never traded', async () => {
    const p = await setup({ tapes: { [POOL_A]: [null, null, null] } });
    await p.settle();
    assert.equal(p.visible('chTog'), false);
    p.close();
  });

  test('appears once a pair with data is selected, and goes away again', async () => {
    const p = await setup();
    await p.waitFor(() => p.visible('chTog'), { label: 'drawer' });
    p.pickToken('toSel', 'WBTC');   // no pools registered for ETH/WBTC
    await p.waitFor(() => !p.visible('chTog'), { label: 'drawer hidden' });
    p.close();
  });

  test('survives a failing read without breaking the swap form', async () => {
    const p = await setup();
    await p.waitFor(() => svg(p), { label: 'chart' });
    p.chain.revertOn(A.MC3, SEL.AGG3, 'node error');
    p.pickToken('toSel', 'WBTC');   // a pair that is not cached, so it must read
    await p.settle();
    // The quote path shares aggregate3, so the only promise here is that the
    // page stays usable and the chart degrades to a message.
    assert.equal(p.visible('chTog'), false, 'a failed read hides the chart rather than lying');
    assert.equal(p.consoleErrors.length, 0, 'a chart failure must not throw');
    p.close();
  });
});
