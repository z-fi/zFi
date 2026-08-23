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
  grab(/function causeSortedPair[\s\S]*?\n}/),
  grab(/function causePoolPrice[\s\S]*?\n}/),
  grab(/const _unf = [^\n]*/),
  grab(/function causeTapeBars[\s\S]*?\n}/),
  grab(/function causeSpark[\s\S]*?\n}/),
  'return { causeSortedPair, causePoolPrice, causeTapeBars, causeSpark };',
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

test('a lone bar renders as a sentence, not a flat line pretending to be a chart', () => {
  const one = M.causeSpark([{ b: 1, o: 1e12, c: 1.6e12, hi: 1.6e12, lo: 1e12, n: 3 }]);
  assert.match(one, /3 trades/);
  assert.doesNotMatch(one, /<polyline/);
  assert.equal(M.causeSpark([]), '');
  const many = M.causeSpark([
    { b: 1, o: 1e12, c: 1e12, hi: 1e12, lo: 1e12, n: 1 },
    { b: 2, o: 1e12, c: 2e12, hi: 2e12, lo: 1e12, n: 2 },
  ]);
  assert.match(many, /<polyline/);
  assert.match(many, /3 trades/);
});
