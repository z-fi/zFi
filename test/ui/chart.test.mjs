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

async function setup({ deployed = true, pools = [POOL_A], tapes = null, coarse = null, open = true } = {}) {
  const chain = new MockChain();
  chain.setNative(A.ACCOUNT, 10n * ETH);
  chain.setErc20(A.USDC, A.ACCOUNT, 5000n * USDC);
  chain.quoteHandler = fixedRateQuoter({ rate: 3000n * ETH });
  chain.setCode(LENS, deployed ? '0x60006000' : '0x');
  chain.setPools(A.ZERO, A.USDC, pools);
  for (const [pool, b] of Object.entries(tapes || { [POOL_A]: bars(24) })) chain.setTape(pool, b);
  // The 4h tape, which is where a sparsely traded pool keeps its history.
  for (const [pool, b] of Object.entries(coarse || {})) chain.setTape(pool, b, 14400);

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
    // 250 five-minute bars in ~300px is a smear. The answer is to open a
    // timeframe the history fits in rather than to keep 5m and throw three
    // quarters of it away, so the full 21 hours is still reachable.
    const p = await setup({ tapes: { [POOL_A]: bars(250) } });
    await p.waitFor(() => svg(p), { label: 'chart' });
    const wicks = svg(p).querySelectorAll('line').length - 4;   // minus gridlines
    assert.ok(wicks < 130, `drew ${wicks} candles, which cannot resolve at this width`);
    // Not a literal span: 250 five-minute buckets straddle 21 or 22 hourly ones
    // depending on where the clock sits inside the current bucket. "last" is the
    // word the drawer uses when it had to drop something, so its absence is the
    // claim, and it does not move with the wall clock.
    assert.doesNotMatch(p.text('chNote'), /last /, 'and none of the history is dropped');

    // Forced back down to 5m it cannot show 21 hours, and says which slice it did.
    [...p.$('chTf').children].find(b => b.textContent === '5m').dispatchEvent(
      new p.window.MouseEvent('click', { bubbles: true }));
    await p.settle();
    assert.match(p.text('chNote'), /last \d+h/, 'a clipped window must say so');
    assert.ok(svg(p).querySelectorAll('line').length - 4 < 130);
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

  // `_byPair` is append-only and index 0 is the OLDEST pool, so sampling the
  // front of it is not sampling at random. The chart used to read the first 8
  // entries: fill a new pair with hooked junk and it charted nothing at all,
  // while the swap quote and the liquidity panel — which scan far wider — both
  // saw the real band. Discovery is now as wide as theirs, and the tape budget
  // is spent on the deepest pools rather than the earliest.
  test('finds the real pool behind a wall of junk bands', async () => {
    const junk = Array.from({ length: 30 }, (_, i) => ({
      pool: '0x' + (i + 1).toString(16).padStart(40, '0'),
      hook: '0x9999999999999999999999999999999999999999',
    }));
    const p = await setup({
      pools: [...junk, POOL_A],
      tapes: { [POOL_A]: bars(24) },
    });
    await p.waitFor(() => p.text('chNote') !== '', { label: 'note' });
    assert.match(p.text('chNote'), /1 pool\b/, 'the band buried at index 30 still charts');
    assert.equal(p.chain.calls.filter(c => c.selector === SEL.TAPE).length, 2,
      'and the junk costs no tape reads');
    p.close();
  });

  // The wide scan must not turn into a wide fan-out: tape reads are two calls
  // per pool and the deepest few carry the price, so the budget stays at eight.
  test('spends its tape budget on the deepest pools, not the oldest', async () => {
    const many = Array.from({ length: 20 }, (_, i) => ({
      pool: '0x' + (i + 1).toString(16).padStart(40, '0'),
      liquidity: 10n ** 21n + BigInt(i),
    }));
    const tapes = Object.fromEntries(many.map(m => [m.pool, bars(24)]));
    const p = await setup({ pools: many, tapes });
    await p.waitFor(() => p.text('chNote') !== '', { label: 'note' });
    const read = p.chain.calls.filter(c => c.selector === SEL.TAPE);
    assert.equal(read.length, 16, 'eight pools, both widths');
    const seen = new Set(read.map(c => c.to.toLowerCase()));
    assert.ok(seen.has(many[19].pool.toLowerCase()), 'the deepest pool is read');
    assert.ok(!seen.has(many[0].pool.toLowerCase()), 'the shallowest, oldest one is not');
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

  test('a dust pool cannot own the y-range with one absurd wick', async () => {
    // Volume weighting already kept the thin pool off the LINE, but the wick
    // was a plain min/max across pools, so a pool holding 0.1% of the volume
    // still stretched the axis - and with the 9% padding on top, the real
    // series collapsed into a couple of pixels. Surviving the pool filter
    // takes one wei of liquidity, so this is cheap to do on purpose.
    const bucket = Math.floor(Date.now() / 1000 / 300);
    const at = (px, v, hi) => [{ bucket, open: px * RAW_ETH_USDC, high: (hi || px) * RAW_ETH_USDC,
      low: px * RAW_ETH_USDC, close: px * RAW_ETH_USDC, volume: v, count: 1 }];
    const p = await setup({
      pools: [POOL_A, POOL_B],
      tapes: { [POOL_A]: at(100, 1000e18), [POOL_B]: at(100, 1e18, 100000) },
    });
    await p.waitFor(() => svg(p), { label: 'chart' });
    const label = svg(p).getAttribute('aria-label');
    const top = Number((label.match(/range .* to ([\d,.]+)/) || [])[1].replace(/,/g, ''));
    assert.ok(top < 200, `a 0.1%-volume pool printing 100000 set the top of the axis to ${top}`);
    p.close();
  });

  test('a bar the pool could only print as zero does not break the axis', async () => {
    // `pack(0) == 0` and `_record` floors the price, so a pair below 1e-18 raw
    // per raw prints zeros - and `PriceTape` says a zeroed low then pins the
    // bar for its whole life. Upright that dragged the range to 0 and squashed
    // every real price into the top few pixels.
    const bucket = Math.floor(Date.now() / 1000 / 300);
    const at = (i, px, low) => ({ bucket: bucket - i, open: px * RAW_ETH_USDC,
      high: px * RAW_ETH_USDC, low: low * RAW_ETH_USDC, close: px * RAW_ETH_USDC,
      volume: 5e18, count: 1 });
    const p = await setup({ tapes: { [POOL_A]: [at(0, 3000, 3000), at(1, 3010, 0), at(3, 2990, 2990)] } });
    await p.waitFor(() => svg(p), { label: 'chart' });
    const label = svg(p).getAttribute('aria-label');
    const bottom = Number((label.match(/range ([\d,.]+) to/) || [])[1].replace(/,/g, ''));
    assert.ok(bottom > 1000, `one unprintable low pulled the axis down to ${bottom}`);
    assert.equal(p.consoleErrors.length, 0);
    p.close();
  });

  test('inverting a zeroed low yields no Infinity, and no NaN in the path', async () => {
    // The reciprocal of an unprintable price is not a number, and inverted is
    // the DEFAULT orientation for a token quoted in a stablecoin. This drew a
    // flat line at the axis under gridlines labelled "Infinity", and put NaN
    // into the line chart's `d` attribute.
    const bucket = Math.floor(Date.now() / 1000 / 300);
    const at = (i, px, low) => ({ bucket: bucket - i, open: px * RAW_ETH_USDC,
      high: px * RAW_ETH_USDC, low: low * RAW_ETH_USDC, close: px * RAW_ETH_USDC,
      volume: 5e18, count: 1 });
    const p = await setup({ tapes: { [POOL_A]: [at(0, 3000, 3000), at(1, 3010, 0), at(3, 2990, 2990)] } });
    await p.waitFor(() => svg(p), { label: 'chart' });
    const inv = [...p.$('chTf').querySelectorAll('button')].find(b => b.textContent === '⇅');
    p.click(inv);
    await p.settle();

    const s = svg(p);
    assert.doesNotMatch(s.outerHTML, /Infinity|NaN/, 'no non-number may reach the SVG');
    p.click([...p.$('chTf').children].find(b => b.className === 'chk'));   // line chart
    assert.doesNotMatch(svg(p).outerHTML, /Infinity|NaN/, 'including the line path');
    assert.equal(p.consoleErrors.length, 0);
    p.close();
  });

  test('a quiet stretch is drawn as a gap, not closed up', async () => {
    // `PriceTape.recent` returns an idle bucket as a zero word so a client can
    // tell a quiet market from a flat one. Packing the survivors shoulder to
    // shoulder threw that away: two trades a day ago and two now drew four
    // evenly spaced candles under a note reporting a day.
    const bucket = Math.floor(Date.now() / 1000 / 300);
    const at = i => ({ bucket: bucket - i, open: 3000 * RAW_ETH_USDC, high: 3000 * RAW_ETH_USDC,
      low: 3000 * RAW_ETH_USDC, close: 3000 * RAW_ETH_USDC, volume: 5e18, count: 1 });
    // Four bars, but the newest pair sits 40 buckets from the older pair.
    const p = await setup({ tapes: { [POOL_A]: [at(0), at(1), at(40), at(41)] } });
    await p.waitFor(() => svg(p), { label: 'chart' });
    // Pin 5m: this is about how a GAP is drawn, not about which timeframe a
    // sparse pool opens on - that choice is its own test, and rolling these
    // four bars up would close the very gap under examination.
    [...p.$('chTf').children].find(b => b.textContent === '5m').dispatchEvent(
      new p.window.MouseEvent('click', { bubbles: true }));
    await p.settle();

    const xs = [...svg(p).querySelectorAll('rect')]
      .map(r => Number(r.getAttribute('x'))).sort((a, b) => a - b);
    const gaps = [];
    for (let i = 1; i < xs.length; i++) if (xs[i] - xs[i - 1] > 0.5) gaps.push(xs[i] - xs[i - 1]);
    assert.ok(Math.max(...gaps) > 6 * Math.min(...gaps),
      'the idle stretch must open a real gap, not another candle-width step');
    p.close();
  });

  test('pointing into a gap reads out the nearest real bar', async () => {
    const bucket = Math.floor(Date.now() / 1000 / 300);
    const at = i => ({ bucket: bucket - i, open: 3000 * RAW_ETH_USDC, high: 3000 * RAW_ETH_USDC,
      low: 3000 * RAW_ETH_USDC, close: 3000 * RAW_ETH_USDC, volume: 5e18, count: 1 });
    const p = await setup({ tapes: { [POOL_A]: [at(0), at(1), at(40), at(41)] } });
    await p.waitFor(() => svg(p), { label: 'chart' });
    // Pin 5m: the bucket arithmetic below is written in five-minute slots, and
    // which timeframe a sparse pool opens on is a separate question.
    [...p.$('chTf').children].find(b => b.textContent === '5m').dispatchEvent(
      new p.window.MouseEvent('click', { bubbles: true }));
    await p.settle();
    const el = p.$('chArt');
    el.getBoundingClientRect = () => ({ left: 0, width: 340, top: 0, height: 150 });
    el.dispatchEvent(new p.window.MouseEvent('pointermove',
      { bubbles: true, clientX: 60, clientY: 40 }));
    const hd = el.querySelector('.hd').textContent;
    assert.match(hd, /H .* L /, 'the middle of the gap still names a bar');
    assert.doesNotMatch(hd, /NaN|undefined/);
    // The axis spans 42 buckets, so this lands in the gap a few slots past the
    // older pair and must snap back to the nearer of them. Reading the pointer
    // as an ARRAY INDEX - four bars across the full width, which is what it was
    // before bars sat at their buckets - puts it a whole bar further out.
    const clock = b => new Date(b * 300 * 1e3).toLocaleTimeString(
      'en-US', { hour: '2-digit', minute: '2-digit', hour12: false });
    assert.match(hd, new RegExp(clock(bucket - 40)), 'snaps to the bar nearest the pointer');
    assert.doesNotMatch(hd, new RegExp(clock(bucket - 41)), 'not to the one an index would pick');
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
  test('offers 5m, 1h, 4h and 1d', async () => {
    // The tape publishes exactly two periods and keeps 256 bars of each, so
    // reach is arithmetic rather than taste: 1h is rolled from the fine tape
    // and can never show more than 21 bars, while 4h IS the coarse period -
    // 256 bars, nearly six weeks. It was missing, which left the pool's widest
    // coverage reachable only through the 1d rollup.
    const p = await setup();
    await p.waitFor(() => svg(p), { label: 'chart' });
    const strip = [...p.$('chTf').children];
    assert.deepEqual(strip.filter(b => b.dataset.secs).map(b => b.textContent),
      ['5m', '1h', '4h', '1d']);
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
    // Five hours of bars: dense enough that the drawer opens on 5m, so the
    // click below is a real change of timeframe and not a no-op.
    const p = await setup({ tapes: { [POOL_A]: bars(60) } });
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

  /**
   * Which asset the chart prices.
   *
   * The tape stores token1 per token0, and token0 is whichever address sorts
   * first - so ETH, always, being the zero address. That reads naturally for a
   * stablecoin (USDC per ETH) and upside down for a token being bought:
   * purchases take it out of the pool, so "TOKEN per ETH" FALLS on the trade
   * that made the token dearer, and the candle is red.
   *
   * Both readings are the same fact, so this is a choice rather than a fix.
   */
  test('can price the other side of the pair', async () => {
    const p = await setup({ open: true });
    await p.waitFor(() => svg(p), { label: 'chart' });
    const before = p.text('chNote');
    assert.match(before, /USDC per ETH/);

    const inv = [...p.$('chTf').querySelectorAll('button')].find(b => b.textContent === '⇅');
    assert.ok(inv, 'there should be a way to flip it');
    p.click(inv);
    await p.settle();
    assert.match(p.text('chNote'), /ETH per USDC/, 'the label follows the orientation');
    p.close();
  });

  test('inverting swaps high and low, so candles are not drawn inside out', async () => {
    // The reciprocal of the highest price is the LOWEST one. Miss that and
    // every candle renders upside down while the numbers still look plausible.
    const p = await setup({ open: true });
    await p.waitFor(() => svg(p), { label: 'chart' });
    const inv = [...p.$('chTf').querySelectorAll('button')].find(b => b.textContent === '⇅');
    p.click(inv);
    await p.settle();

    const hud = p.$('chArt').querySelector('.hd');
    const shown = Number((hud.textContent.match(/[\d.]+e?-?\d*/) || ['0'])[0]);
    assert.ok(shown > 0 && shown < 1,
      `an ETH-per-USDC price should be a small fraction, got ${hud.textContent}`);
    p.close();
  });

  test('opens each pair in the orientation that pair is quoted in', async () => {
    // A single sticky preference cannot serve both: flipping for a token pair
    // would bring ETH/USDC back as 0.00033 ETH per USDC. So the default is per
    // pair - dollars quote ether, ether quotes everything else - and the
    // toggle is an override for the pair in front of you.
    const p = await setup({ open: true });
    await p.waitFor(() => svg(p), { label: 'chart' });
    assert.match(p.text('chNote'), /USDC per ETH/, 'a stablecoin does the quoting');

    const inv = [...p.$('chTf').querySelectorAll('button')].find(b => b.textContent === '⇅');
    p.click(inv);
    await p.settle();
    assert.match(p.text('chNote'), /ETH per USDC/, 'the override holds while the pair is up');
    p.close();
  });


  test('opens on a timeframe the pool has data for', async () => {
    // 24 fine bars is two hours of trading: 5m has plenty to draw, so that is
    // where it opens.
    const p = await setup();
    await p.waitFor(() => svg(p), { label: 'chart' });
    const on = [...p.$('chTf').querySelectorAll('button[data-secs]')]
      .find(b => b.classList.contains('on'));
    assert.equal(on?.textContent, '5m', 'a busy pool opens close in');
    p.close();
  });

  test('opens wider when the pool trades rarely', async () => {
    // Three fine bars is not a chart, it is three ticks on a flat line - which
    // reads as "nothing here" rather than "nothing recently". The coarse tape
    // has the history, so that is what to open on.
    const p = await setup({ tapes: { [POOL_A]: bars(3) }, coarse: { [POOL_A]: bars(30) } });
    await p.waitFor(() => svg(p), { label: 'chart' });
    const on = [...p.$('chTf').querySelectorAll('button[data-secs]')]
      .find(b => b.classList.contains('on'));
    assert.ok(on && Number(on.dataset.secs) >= 14400,
      `a sparse pool should open on 4h or 1d, opened on ${on?.textContent}`);
    p.close();
  });

});

/**
 * The chart and the two shapes of ether.
 *
 * A native market is stored under address(0) because the pool holds ether, so
 * `marketsForPair(coin, WETH)` answers zero about a pool that is live, funded,
 * and the one the swap tab is quoting on the same screen. The chart simply
 * hid itself.
 *
 * The dangerous fix is to borrow the native pool's tapes into the SELECTED
 * pair's ordering. Ether sorts first and WETH sorts after most tokens, so for
 * ETH/USDC the two orderings are opposites and the bars come out inverted —
 * a chart that looks like real data while showing the reciprocal price, which
 * is strictly worse than the blank one it replaces. So the whole pair is
 * redrawn as the market that exists instead, and these pin that.
 */
describe('a native market selected as WETH', () => {
  test('draws the native market rather than hiding', async () => {
    // The chart has no empty state — it removes its own control — so the signal
    // is whether the drawer is offered at all. The <svg> element itself stays
    // in the DOM from the previous pair, which is what made a first version of
    // this test pass against the unfixed page.
    const p = await setup();
    await p.waitFor(() => p.visible('chTog'), { label: 'the ETH chart' });
    p.pickToken('fromSel', 'WETH');
    await p.settle();
    await p.waitFor(() => p.visible('chTog'),
      { label: 'the chart, with the same market selected as WETH' });
    p.close();
  });

  test('and draws it the SAME WAY UP, not the reciprocal', async () => {
    // The whole reason the pair is swapped rather than the pools borrowed.
    // Ether sorts first and WETH sorts after USDC, so lifting the native tape
    // into the selected pair's ordering inverts it: 3000 becomes 0.00033, and
    // nothing in the rendering says which one you are looking at.
    const a = await setup();
    await a.waitFor(() => a.visible('chTog'), { label: 'the ETH chart' });
    const ethNote = a.text('chNote'), ethPath = svg(a).innerHTML;
    a.close();

    const b = await setup();
    await b.waitFor(() => b.visible('chTog'), { label: 'the ETH chart' });
    b.pickToken('fromSel', 'WETH');
    await b.settle();
    await b.waitFor(() => b.visible('chTog'), { label: 'the WETH chart' });
    assert.equal(b.text('chNote'), ethNote,
      'the label must name the market being drawn, and it is the ether one');
    assert.equal(svg(b).innerHTML, ethPath, 'and the bars must be identical, not flipped');
    b.close();
  });

  test('leaves a pair that HAS a WETH market alone', async () => {
    // The substitution is a fallback for a pair with nothing, not a rule that
    // ether outranks WETH. A real WETH band must still be its own chart.
    const chain = new MockChain();
    chain.setNative(A.ACCOUNT, 10n * ETH);
    chain.setErc20(A.USDC, A.ACCOUNT, 5000n * USDC);
    chain.setErc20(A.WETH, A.ACCOUNT, 10n * ETH);
    chain.quoteHandler = fixedRateQuoter({ rate: 3000n * ETH });
    chain.setCode(LENS, '0x60006000');
    chain.setPools(A.WETH, A.USDC, [POOL_A]);
    chain.setTape(POOL_A, bars(24));
    const p = await loadPage({ chain, patch: patchFactory(), storage: { ch: '1' } });
    await p.connect();
    p.pickToken('fromSel', 'WETH');
    await p.settle();
    await p.waitFor(() => p.visible('chTog'), { label: 'the WETH chart' });
    assert.match(p.text('chNote'), /WETH/, 'a real WETH band is its own market');
    p.close();
  });
});

/**
 * Which timeframe a pool opens on.
 *
 * The chart draws only the newest CH_SLOTS worth of periods, but the automatic
 * timeframe used to measure its span across the WHOLE tape. One stale bar - a
 * single trade days before the rest - then dragged the opening timeframe wide
 * even though the drawn window would have been perfectly legible close in.
 *
 * The second thing these pin is density. Six bars scattered over ninety-eight
 * slots is not a chart a trader reads; it is six hairlines with white space
 * between them. Bar COUNT alone cannot tell those apart from six adjacent
 * bars, so the fit has to look at how much of the drawn window actually
 * traded.
 */
describe('choosing the opening timeframe', () => {
  // Bars at explicit slot offsets back from now, so a fixture can be sparse
  // or clustered on purpose rather than only contiguous.
  const at = (offsets, { start = 3000, pool = 1, coarse = false } = {}) => {
    const width = coarse ? 14400 : 300;
    const now = Math.floor(Date.now() / 1000 / width);
    let p = start;
    return offsets.map(off => {
      const o = p; p = p * 1.004;
      return {
        bucket: now - off,
        open: o * RAW_ETH_USDC, high: p * 1.002 * RAW_ETH_USDC,
        low: o * 0.998 * RAW_ETH_USDC, close: p * RAW_ETH_USDC,
        volume: 10 * pool * 1e18, count: 3,
      };
    });
  };
  const chosen = p => {
    const on = [...p.$('chTf').querySelectorAll('button[data-secs]')]
      .find(b => b.classList.contains('on'));
    return on ? Number(on.dataset.secs) : null;
  };

  test('says when, not just how much', async () => {
    // Price is labelled down the right edge and the gaps are drawn to scale,
    // but without a time axis the reader has to guess what span is on screen -
    // and a gap is exactly the thing you cannot size by eye.
    const p = await setup({ tapes: { [POOL_A]: at([...Array(24).keys()]) } });
    await p.waitFor(() => svg(p), { label: 'chart' });
    const labels = [...svg(p).querySelectorAll('text')].map(t => t.textContent);
    const clocks = labels.filter(t => /^\d{2}:\d{2}$/.test(t));
    assert.ok(clocks.length >= 2,
      `an intraday chart needs clock times on its axis, got ${JSON.stringify(labels)}`);

    // And they must name real bars, in order, oldest on the left.
    const now = Math.floor(Date.now() / 1000 / 300);
    const clockOf = b => new Date(b * 300 * 1e3).toLocaleTimeString(
      'en-US', { hour: '2-digit', minute: '2-digit', hour12: false });
    assert.equal(clocks[0], clockOf(now - 23), 'the left edge should be the oldest bar drawn');
    assert.equal(clocks[clocks.length - 1], clockOf(now), 'the right edge should be the newest');
    p.close();
  });

  test('dates a multi-day window even when its bars are hours', async () => {
    // Eight four-hour bars across two days were labelled 16:00 / 04:00 /
    // 16:00 - the same clock twice, naming no day. What a label has to say
    // follows the SPAN on screen, not how wide one bar happens to be.
    const p = await setup({ tapes: { [POOL_A]: at([0, 40, 90, 150, 220, 300, 400, 560]) } });
    await p.waitFor(() => svg(p), { label: 'chart' });
    const labels = [...svg(p).querySelectorAll('text')].map(t => t.textContent);
    const stamps = labels.filter(t => /^[A-Z][a-z]{2} \d+$|^\d{2}:\d{2}$/.test(t));
    assert.ok(stamps.length >= 2, `no axis labels at all, got ${JSON.stringify(labels)}`);
    assert.ok(stamps.every(t => /^[A-Z][a-z]{2} \d+$/.test(t)),
      `a two-day window must be dated, not clocked, got ${JSON.stringify(stamps)}`);
    assert.equal(new Set(stamps).size, stamps.length,
      `a repeated label reads as a bug, got ${JSON.stringify(stamps)}`);
    p.close();
  });

  test('dates a daily chart rather than clocking it', async () => {
    // 08:00 on every candle tells a reader nothing when each one is a day.
    const p = await setup({ tapes: { [POOL_A]: at([]) },
      coarse: { [POOL_A]: at([...Array(40).keys()].map(i => i * 6), { coarse: true }) } });
    await p.waitFor(() => svg(p), { label: 'chart' });
    [...p.$('chTf').children].find(b => b.textContent === '1d').dispatchEvent(
      new p.window.MouseEvent('click', { bubbles: true }));
    await p.settle();
    const labels = [...svg(p).querySelectorAll('text')].map(t => t.textContent);
    assert.ok(labels.some(t => /^[A-Z][a-z]{2} \d+$/.test(t)),
      `a daily chart should be dated, got ${JSON.stringify(labels)}`);
    assert.ok(!labels.some(t => /^\d{2}:\d{2}$/.test(t)), 'and not clocked');
    p.close();
  });

  test('a lone stale fine bar cannot outrank a real coarse history', async () => {
    // zCat's actual shape on mainnet: the 5m ring has aged down to ONE bar
    // three days old, while the 4h tape still holds ~37 bars over eleven days.
    // Neither is dense AND long enough to qualify outright, so this lands in
    // the fallback - where "highest fill" is a trap, because one bar alone is
    // 100% full. What matters there is how much chart there is: bars AND
    // density together.
    const p = await setup({
      tapes: { [POOL_A]: at([12]) },
      // Five bars over twenty 4h slots: too few to qualify and too sparse to
      // qualify, so the choice really does fall through to the fallback.
      coarse: { [POOL_A]: at([0, 4, 9, 14, 19], { coarse: true }) },
    });
    await p.waitFor(() => svg(p), { label: 'chart' });
    const on = [...p.$('chTf').querySelectorAll('button[data-secs]')]
      .find(b => b.classList.contains('on'));
    assert.ok(Number(on.dataset.secs) >= 14400,
      `a single stale 5m bar must not win over a real 4h history, opened on ${on?.textContent}`);
    p.close();
  });

  test('one stale bar does not drag a busy pool onto a wide timeframe', async () => {
    // Twenty-four consecutive five-minute bars — two hours of real trading,
    // which is a 5m chart — plus one lone trade three days earlier that the
    // drawn window would never even include.
    const recent = [...Array(24).keys()];
    const p = await setup({ tapes: { [POOL_A]: at([...recent, 900]) } });
    await p.waitFor(() => svg(p), { label: 'chart' });
    assert.equal(chosen(p), 300,
      `two hours of solid trading is a 5m chart, opened on ${chosen(p)}s`);
    p.close();
  });

  test('a scattered pool opens wide enough to look continuous', async () => {
    // Eight trades spread thinly across two days. At 5m that is eight
    // hairlines in a sea of gap; rolled up it becomes a chart.
    const p = await setup({ tapes: { [POOL_A]: at([0, 40, 90, 150, 220, 300, 400, 560]) } });
    await p.waitFor(() => svg(p), { label: 'chart' });
    assert.ok(chosen(p) > 300,
      `a pool that trades every few hours should not open on 5m, opened on ${chosen(p)}s`);
    p.close();
  });
});
