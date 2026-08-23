/**
 * The Market tile's numbers.
 *
 * Three different "prices" are reachable from a Precision pool and they do not
 * agree, which is not a bug in any of them:
 *
 *   - the reserve ratio, which is spot and what a deposit must arrive at;
 *   - the lens PI_PX word, which is a sqrt and not directly comparable;
 *   - the tape, which records the EXECUTED price of each trade, fee and
 *     slippage included, so a bar close is what someone actually paid.
 *
 * The live CELL pool showed all three at once — 9,245.6 gwei spot against a
 * 1,627 gwei tape close — because a buyer moved the price during the bar. The
 * fixtures below are that pool's real on-chain words, so if the packing or the
 * inversion ever drifts, the numbers stop matching a trade that really happened.
 *
 * PriceTape.sol is explicit that the tape is cheap to poison and must not be
 * priced against; it is charted here and nowhere else. Spot comes from reserves.
 */
import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { ethers } from 'ethers';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..');
const html = fs.readFileSync(path.join(ROOT, 'dapp/coin/index.html'), 'utf8');
const grab = re => { const m = html.match(re); assert.ok(m, 'not found: ' + re); return m[0]; };

const M = new Function('ethers', [
  "const ZERO='0x0000000000000000000000000000000000000000';",
  "const LQ_WAD=10n**18n;",
  "const fmtPriceWei=v=>String(v);",
  "const BigIntRound=v=>BigInt(Math.round(v));",
  grab(/function causeSortedPair[\s\S]*?\n}/),
  grab(/function causeSpotPrice[\s\S]*?\n}/),
  grab(/function causePoolPrice[\s\S]*?\n}/),
  grab(/const _unf = [^\n]*/),
  grab(/function causeTapeBars[\s\S]*?\n}/),
  grab(/function causeTimeChart[\s\S]*?\n}\n/),
  grab(/function causeChart[\s\S]*?\n}\n/),
  'return { causeSortedPair, causeSpotPrice, causePoolPrice, causeTapeBars, causeChart, causeTimeChart };',
].join('\n'))(ethers);

const CELL = '0xf142CfA6Ca3DFa4A131f12aACEF4890e390d70D6';

test('spot price comes from reserves, matching what the pool takes on a deposit', () => {
  // Real reserves of pool 0xaf9f2e88…, ETH sorts first so it is token0.
  const pool = { r0: 25020744727485219n, r1: 2706218041194631472538n };
  const spot = M.causePoolPrice(pool, CELL);
  // previewAdd on the live pool takes 1 ETH per 108,158.97 CELL — the same ratio.
  assert.equal(Number(spot) / 1e9 > 9245 && Number(spot) / 1e9 < 9246, true,
    `expected ~9245.6 gwei/share, got ${Number(spot) / 1e9}`);
});

test('ETH is token0 for this pair, so tape prices need inverting', () => {
  const [t0] = M.causeSortedPair(CELL);
  assert.equal(t0, '0x0000000000000000000000000000000000000000');
});

test('tape decodes to the price a buyer actually paid', () => {
  // The pool's real packed word, read straight off 0xaf9f2e88… — 3 trades, the
  // seed then the buy. Hand-built fixtures here are worthless: the whole point is
  // that this is a word the chain actually produced.
  const bar = 0x320f8993538822a5c37d96a3938822a5c37d96a39005aea3fn;
  const raw = '0x' + '0'.repeat(64)
    + BigInt(1).toString(16).padStart(64, '0')
    + bar.toString(16).padStart(64, '0');
  const bars = M.causeTapeBars(raw, true);
  assert.equal(bars.length, 1);
  assert.equal(bars[0].n, 3);
  const closeGwei = bars[0].c / 1e9;
  // The buyer took 12,293.78 CELL for 0.020026 ETH — an average near 1,628 gwei.
  assert.ok(closeGwei > 1600 && closeGwei < 1660, `close ${closeGwei} gwei off the real fill`);
  // And it is emphatically NOT the 9,245.6 spot the same pool shows.
  assert.ok(closeGwei < 5000, 'tape close should not be reading as spot');
});

test('the chart is a price ruler: floor left, spot right, fills where they landed', () => {
  const floor = 328522781932n, sale = 333000000000n, spot = 7879700000000n;
  const bars = [{ b: 1, o: 1.948e12, c: 1.627e12, hi: 1.948e12, lo: 1.627e12, n: 3 }];
  const out = M.causeChart(bars, floor, sale, spot);

  assert.match(out, /<svg/);
  assert.match(out, /floor/);
  assert.match(out, /now/);
  assert.match(out, /3 fills/);

  // Everything drawn stays inside the 300-wide viewBox.
  const xs = [...out.matchAll(/(?:x1|x2|cx)="([\d.]+)"/g)].map(m => parseFloat(m[1]));
  assert.ok(xs.length > 0, 'nothing was drawn');
  for (const x of xs) assert.ok(x >= 0 && x <= 300, `x=${x} escapes the viewBox`);

  // The fill at 1,627 gwei sits between the 328 floor and the 7,880 spot, and the log
  // spacing has to keep it there — on a linear axis it would collapse onto the floor.
  const fill = parseFloat(out.match(/<circle cx="([\d.]+)"/)[1]);
  const ticks = [...out.matchAll(/<line x1="([\d.]+)" y1="\d+"/g)].map(m => parseFloat(m[1]));
  const floorX = Math.min(...ticks), spotX = Math.max(...ticks);
  assert.ok(fill > floorX && fill < spotX, `fill at ${fill} should sit between ${floorX} and ${spotX}`);
  assert.ok(fill > 300 * 0.3, 'a log axis should not crush the fill against the floor');
});

test('with no pool and no trades there is nothing to draw', () => {
  assert.equal(M.causeChart([], 0n, 0n, 0n), '');
});

test('the price is the marginal one, not the reserve ratio', () => {
  // Real words from pool 0xaf9f2e88…: the sqrt and the reserves disagree by 17%,
  // which is normal for a concentrated position and was briefly shipped as a bug —
  // quotes compared against the reserve ratio made a buy look 11% BELOW spot when a
  // buy can only ever fill at or above it.
  const pool = {
    sqrtP: 356242404745870914368n,
    r0: 25020744727485219n,
    r1: 2706218041194631472538n,
  };
  const spot = Number(M.causeSpotPrice(pool, CELL)) / 1e9;
  const ratio = Number(M.causePoolPrice(pool, CELL)) / 1e9;

  // Shrinking a real quote converged on 7,903.7 gwei, which is spot plus the 0.3% fee.
  assert.ok(spot > 7870 && spot < 7890, `spot ${spot} should be ~7880 gwei`);
  assert.ok(ratio > 9240 && ratio < 9250, `deposit ratio ${ratio} should be ~9245.6 gwei`);
  assert.ok(ratio > spot, 'the two must not be conflated');

  // A 0.001 ETH buy filled at 8,216.3 gwei. Against spot that is a cost, not a discount.
  assert.ok((8216.3 - spot) / spot > 0, 'a buy must never price below spot');
});

test('the chart switches to a time axis only once there is a shape to draw', () => {
  const floor = 328522781932n, sale = 333000000000n, spot = 7879700000000n;
  const bar = c => ({ b: 1, o: c, c, hi: c, lo: c, n: 1 });

  // One or two prints on a time axis is a dot and a lot of whitespace — the exact thing
  // that makes a lone candle useless. Stay on the ruler.
  const thin = M.causeChart([bar(1.6e12), bar(1.9e12)], floor, sale, spot);
  assert.match(thin, /floor/);
  assert.doesNotMatch(thin, /<polyline/, 'two bars should not pretend to be a time series');

  // Three is where a line starts carrying information the ruler cannot.
  const rich = M.causeChart([bar(1.6e12), bar(1.9e12), bar(4.2e12), bar(7.1e12)], floor, sale, spot);
  assert.match(rich, /<polyline/, 'four bars should plot over time');
  assert.match(rich, /4 fills/);

  // Both modes must keep every drawn coordinate inside their own viewBox.
  for (const [svg, h] of [[thin, 34], [rich, 74]]) {
    const box = svg.match(/viewBox="0 0 300 (\d+)"/);
    assert.equal(Number(box[1]), h);
    for (const m of svg.matchAll(/(?:cy|y1|y2)="([\d.]+)"/g))
      assert.ok(+m[1] >= 0 && +m[1] <= h, `y=${m[1]} escapes the ${h}px box`);
  }
});
