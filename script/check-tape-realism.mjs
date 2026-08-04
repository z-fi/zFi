#!/usr/bin/env node
/**
 * Does the on-chain tape hold enough to draw the chart the dapp draws?
 *
 * Takes the raw `tape()` returns captured from a real PrecisionPool after a
 * simulated day of trading (test/TapeRealism.t.sol) and runs them through the
 * SHIPPED client decoder — the one lifted out of zSwap.html, not a copy — then
 * reports what each timeframe would actually render.
 *
 * The question this answers is not "does it decode" but "is there enough of it":
 * a tape that decodes perfectly and yields four bars is not a chart.
 *
 * Usage: node script/check-tape-realism.mjs <fine.hex> <coarse.hex> <nowUnix>
 */
import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import { fileURLToPath } from 'node:url';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const [fineFile, coarseFile, nowArg] = process.argv.slice(2);
if (!fineFile || !coarseFile || !nowArg) {
  console.error('usage: check-tape-realism.mjs <fine.hex> <coarse.hex> <nowUnix>');
  process.exit(2);
}

const html = fs.readFileSync(path.join(ROOT, 'zSwap.html'), 'utf8');
const scripts = [...html.matchAll(/<script>([\s\S]*?)<\/script>/g)].map(m => m[1]);
const ids = new Set([...html.matchAll(/\bid="([^"]+)"/g)].map(m => m[1]));

function stub() {
  const target = function () {};
  return new Proxy(target, {
    get(t, k) {
      if (k === Symbol.iterator) return function* () {};
      if (k === Symbol.toPrimitive) return () => '';
      if (k === 'then') return undefined;
      if (!(k in t)) t[k] = stub();
      return t[k];
    },
    set(t, k, v) { t[k] = v; return true; },
    has() { return true; },
    apply() { return stub(); },
  });
}

const sandbox = {
  console, TextEncoder, TextDecoder, crypto, URL, URLSearchParams,
  addEventListener: () => {}, removeEventListener: () => {},
  setTimeout: () => 0, clearTimeout: () => {}, setInterval: () => 0,
  localStorage: { getItem: () => null, setItem: () => {}, removeItem: () => {} },
  matchMedia: () => ({ matches: false, addEventListener() {} }),
  prompt: () => '', alert: () => {},
  location: { reload() {}, href: '', hash: '', search: '', pathname: '/', origin: '' },
  navigator: { userAgent: 'node' },
  document: { documentElement: stub(), addEventListener: () => {}, createElement: () => stub() },
  window: { addEventListener: () => {} },
};
for (const id of ids) if (!(id in sandbox)) sandbox[id] = stub();
const ctx = vm.createContext(sandbox);
vm.runInContext(scripts.join('\n') + ';globalThis.__x={decBar,rollUp,mergeTapes,FINE,COARSE};',
  ctx, { filename: 'zSwap.html' });
const { decBar, rollUp, mergeTapes, FINE, COARSE } = ctx.__x;

/** abi.encode(uint256[]) -> packed bar words */
function decodeTape(hex) {
  const h = hex.trim().replace(/^0x/, '');
  const at = i => BigInt('0x' + h.slice(i * 64, (i + 1) * 64));
  const n = Number(at(1));
  const out = [];
  for (let i = 0; i < n; i++) out.push(decBar(at(2 + i)));
  return out;
}

const now = Number(nowArg);
const fine = decodeTape(fs.readFileSync(fineFile, 'utf8'));
const coarse = decodeTape(fs.readFileSync(coarseFile, 'utf8'));

// Both tokens are 18 decimals in the fixture, so raw -> human is just /1e18.
const scale = bars => bars.map(b => (b ? { ...b, o: b.o / 1e18, h: b.h / 1e18, l: b.l / 1e18, c: b.c / 1e18, v: b.v / 1e18 } : null));
const fineH = mergeTapes([scale(fine)]);
const coarseH = mergeTapes([scale(coarse)]);

const stats = (bars, period, label) => {
  const live = bars.filter(Boolean);
  if (!live.length) return `${label.padEnd(6)} EMPTY`;
  const lo = Math.min(...live.map(b => b.l));
  const hi = Math.max(...live.map(b => b.h));
  const vol = live.reduce((s, b) => s + b.v, 0);
  const trades = live.reduce((s, b) => s + b.n, 0);
  const span = (live[0].b - live[live.length - 1].b + 1) * period;
  return `${label.padEnd(6)} ${String(live.length).padStart(3)} bars  ` +
    `span ${(span / 3600).toFixed(1)}h  ` +
    `px ${lo.toFixed(4)}–${hi.toFixed(4)}  vol ${vol.toFixed(0)}  ${trades} trades`;
};

console.log('RAW TAPE (what the contract returned)');
console.log('  fine slots returned :', fine.length, ' non-empty:', fine.filter(Boolean).length);
console.log('  coarse slots returned:', coarse.length, ' non-empty:', coarse.filter(Boolean).length);
console.log();
console.log('WHAT EACH TIMEFRAME RENDERS');
console.log(' ', stats(fineH, FINE, '5m'));
console.log(' ', stats(rollUp(fineH, FINE, 3600), 3600, '1h'));
console.log(' ', stats(coarseH, COARSE, '4h'));
console.log(' ', stats(rollUp(coarseH, COARSE, 86400), 86400, '1d'));
console.log();

// The drawer keeps only what its width can resolve; anything above that is a
// full chart regardless of how much more the ring holds.
const DRAWABLE = Math.floor((340 - 2 - 42) / 3);
const fineDrawn = Math.min(fineH.filter(Boolean).length, DRAWABLE);
console.log(`DRAWER (caps at ${DRAWABLE} bars)`);
console.log(`  5m would draw ${fineDrawn} candles` +
  (fineDrawn >= DRAWABLE ? ' (full, clipped)' : ' (all it has)'));

const ok = fineH.filter(Boolean).length >= 40 && coarseH.filter(Boolean).length >= 3;
console.log();
console.log(ok ? 'VERDICT: the tape populates a real chart.'
              : 'VERDICT: too sparse to chart — investigate.');
process.exit(ok ? 0 : 1);
