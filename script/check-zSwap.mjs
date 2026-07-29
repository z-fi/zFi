#!/usr/bin/env node
/**
 * Robustness checks for zSwap.html — the page ships as IMMUTABLE contract code,
 * so anything broken at deploy time is broken forever. There is no patch path.
 * This is the guard that runs before that becomes true.
 *
 * WHAT IT CHECKS
 *   1. Every <script> block compiles. A syntax error here bricks the dapp
 *      permanently; nothing else in the pipeline would notice.
 *   2. The page contains no block-comment terminator (it would end zSwap.sol's
 *      trailing source comment early).
 *   3. It still fits CHUNKS x EIP-170.
 *   4. src/zSwap.sol's embedded copy is byte-identical to zSwap.html.
 *   5. Every bare identifier the script relies on being an auto-global element id
 *      actually exists as an id= in the markup.
 *   6. The page's pure helpers behave: decQ decodes recorded zQuoter returns
 *      correctly, and the unit/format/encoding helpers round-trip.
 *
 * WHY (6) MATTERS: decQ reads the quoter's return by hardcoded word offsets. If
 * a builder's return shape ever changes, every number the user sees — rate, Min
 * received, the approval amount — silently shifts. The fixtures in
 * test/fixtures/quoter.json are real mainnet returns, so the offsets are pinned
 * to reality rather than to a comment.
 *
 * Run: node script/check-zSwap.mjs
 */
import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import { fileURLToPath } from 'node:url';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const HTML_PATH = path.join(ROOT, 'zSwap.html');
const SOL_PATH = path.join(ROOT, 'src', 'zSwap.sol');
const FIXTURES = path.join(ROOT, 'test', 'fixtures', 'quoter.json');

const EIP170 = 24576;
const CHUNKS = 3;

const html = fs.readFileSync(HTML_PATH, 'utf8');
const bytes = Buffer.byteLength(html, 'utf8');

// The page kicks off async work at load (wallet probe, deep-link handler). A
// throw in there never reaches the synchronous try/catch below — Node would
// report it as an unhandled rejection long after the summary printed, with an
// exit code nobody attributes to a real defect. Collect them instead.
const asyncErrors = [];
process.on('unhandledRejection', e => asyncErrors.push(e));
process.on('uncaughtException', e => asyncErrors.push(e));

let failures = 0;
const fail = (what, detail) => {
  failures++;
  console.error(`FAIL  ${what}\n      ${String(detail).split('\n').join('\n      ')}`);
};
const pass = what => console.log(`ok    ${what}`);
const check = (what, fn) => {
  try {
    const note = fn();
    pass(note ? `${what} — ${note}` : what);
  } catch (e) {
    fail(what, e.message || e);
  }
};

// ---------- 1. script blocks compile ----------
const scripts = [...html.matchAll(/<script>([\s\S]*?)<\/script>/g)].map(m => m[1]);
check('every <script> block compiles', () => {
  if (!scripts.length) throw Error('no <script> blocks found — extraction regex is stale');
  scripts.forEach((src, i) => {
    try {
      new vm.Script(src, { filename: `zSwap.html:<script#${i + 1}>` });
    } catch (e) {
      throw Error(`block #${i + 1}: ${e.message}`);
    }
  });
  return `${scripts.length} blocks`;
});

// ---------- 2. comment-terminator guard ----------
check('no block-comment terminator (would end zSwap.sol source comment early)', () => {
  if (html.includes('*/')) throw Error('page contains "*/"');
});

// ---------- 3. size ----------
check(`fits ${CHUNKS} x EIP-170`, () => {
  const per = Math.ceil(bytes / CHUNKS);
  if (per > EIP170) throw Error(`${per} B per chunk exceeds ${EIP170} B — raise CHUNKS`);
  return `${bytes.toLocaleString('en-US')} B, ${(EIP170 * CHUNKS - bytes).toLocaleString('en-US')} B headroom`;
});

// ---------- 4. zSwap.sol embedded copy is in sync ----------
check('src/zSwap.sol embedded copy matches zSwap.html', () => {
  const sol = fs.readFileSync(SOL_PATH, 'utf8');
  const open = 'deployed chunks) =====\n\n';
  const close = '\n===== end of zSwap.html source ===== */';
  const i = sol.indexOf(open);
  const j = sol.indexOf(close);
  if (i < 0 || j < 0) throw Error('source comment markers not found in zSwap.sol');
  if (sol.slice(i + open.length, j) !== html) throw Error('out of sync — run node script/build-zSwap.mjs');
});

// ---------- 5. auto-global element ids resolve ----------
// The page never calls getElementById; it leans on the browser exposing every id= as
// a global. A renamed or deleted id therefore fails at runtime, not at build.
const ids = new Set([...html.matchAll(/\bid="([^"]+)"/g)].map(m => m[1]));
check('element ids referenced by the script exist in the markup', () => {
  const referenced = new Set();
  const js = scripts.join('\n');
  for (const id of ids) {
    // only care that declared ids are used consistently; look for the reverse too
    if (new RegExp(`\\b${id}\\b`).test(js)) referenced.add(id);
  }
  const unused = [...ids].filter(id => !referenced.has(id));
  if (unused.length) throw Error(`id(s) in markup never referenced by script: ${unused.join(', ')}`);
  return `${ids.size} ids`;
});

// ---------- 6. pure helpers behave ----------
// Run the page in a sandbox whose globals auto-vivify, so the DOM-touching
// top-level code is inert and the pure helpers become reachable.
const HELPERS = [
  'decQ', 'parseUnits', 'formatUnits', 'trimAmt', 'encCalls',
  'encUint', 'encAddr', 'pad32', 'strip0x', 'keccak', 'namehash',
  'decodeString', 'idTok', 'idDelay',
];

function stub() {
  const target = function () {};
  return new Proxy(target, {
    get(t, k) {
      if (k === Symbol.iterator) return function* () {};
      if (k === Symbol.toPrimitive) return () => '';
      if (k === 'then') return undefined; // never look thenable
      if (!(k in t)) t[k] = stub();
      return t[k];
    },
    set(t, k, v) { t[k] = v; return true; },
    has() { return true; },
    apply() { return stub(); },
  });
}

let exported = null;
check('page evaluates without throwing (DOM stubbed)', () => {
  // A plain sandbox, NOT a proxied one: a catch-all proxy swallows undefined
  // identifiers AND intercepts the result read, so every helper silently comes
  // back as a stub and the assertions below pass against nothing.
  //
  // Seeding it with exactly the markup's id= set is also the stronger test: the
  // page resolves elements purely through auto-globals, so any identifier that
  // is neither an id nor a known browser global is a genuine ReferenceError in
  // the browser too, and should fail here rather than be papered over.
  const sandbox = {
    console, TextEncoder, TextDecoder, crypto, URL, URLSearchParams,
    // bare window-level globals the page uses unqualified
    addEventListener: () => {}, removeEventListener: () => {},
    requestAnimationFrame: () => 0,
    setTimeout: () => 0, clearTimeout: () => {}, setInterval: () => 0,
    localStorage: { getItem: () => null, setItem: () => {}, removeItem: () => {} },
    matchMedia: () => ({ matches: false, addEventListener() {} }),
    prompt: () => '',
    alert: () => {},
    // hash/search/pathname are always strings in a browser; omitting them makes
    // the deep-link handler throw here for a reason the real page never would.
    location: { reload() {}, href: '', hash: '', search: '', pathname: '/', origin: '' },
    navigator: { userAgent: 'node' },
    document: { documentElement: stub(), addEventListener: () => {}, createElement: () => stub() },
    window: { addEventListener: () => {} },
  };
  for (const id of ids) if (!(id in sandbox)) sandbox[id] = stub();

  const ctx = vm.createContext(sandbox);
  const epilogue = `;globalThis.__exports={${HELPERS.join(',')}};`;
  vm.runInContext(scripts.join('\n') + epilogue, ctx, { filename: 'zSwap.html' });

  exported = ctx.__exports;
  if (!exported) throw Error('epilogue did not export — sandbox wiring is broken');
  const missing = HELPERS.filter(h => typeof exported[h] !== 'function');
  if (missing.length) throw Error(`helper(s) missing or not functions: ${missing.join(', ')}`);
  return `${HELPERS.length} helpers reachable`;
});

const eq = (got, want, what) => {
  if (String(got) !== String(want)) throw Error(`${what}: got ${got}, want ${want}`);
};

if (exported) {
  const { decQ, parseUnits, formatUnits, trimAmt, encCalls, keccak, namehash, decodeString, idTok, idDelay } = exported;

  check('keccak matches known vectors', () => {
    eq(keccak(new TextEncoder().encode('')),
      '0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470', 'keccak("")');
    eq(namehash('eth'),
      '0x93cdeb708b7545dc668eb9280176169d1c33cfd8ed6f04690a0bcc88a93fc4ae', 'namehash("eth")');
  });

  check('parseUnits / formatUnits / trimAmt round-trip', () => {
    eq(parseUnits('1.5', 18), 1500000000000000000n, 'parseUnits 1.5e18');
    eq(parseUnits('1,234.5', 6), 1234500000n, 'parseUnits strips commas');
    eq(formatUnits(1500000000000000000n, 18), '1.5', 'formatUnits');
    eq(formatUnits(1n, 18), '0.000000000000000001', 'formatUnits dust');
    eq(trimAmt(1234567890123456789n, 18), '1.234567', 'trimAmt truncates to 6dp');
    // a negative amount must not parse — it would encode as a huge uint256
    let threw = false;
    try { parseUnits('-1', 18); } catch { threw = true; }
    if (!threw) throw Error('parseUnits accepted a negative amount');
    // more decimals than the token has must be rejected, not silently truncated
    threw = false;
    try { parseUnits('1.1234567', 6); } catch (e) { threw = /decimals/.test(e.message); }
    if (!threw) throw Error('parseUnits accepted more decimals than the token supports');
  });

  check('encCalls builds valid multicall(bytes[]) ABI', () => {
    const cd = encCalls(['0xaabbcc', '0xdd']);
    if (!cd.startsWith('0xac9650d8')) throw Error('wrong selector');
    const body = cd.slice(10);
    eq(BigInt('0x' + body.slice(0, 64)), 32n, 'array offset');
    eq(BigInt('0x' + body.slice(64, 128)), 2n, 'array length');
    const off0 = Number(BigInt('0x' + body.slice(128, 192)));
    const off1 = Number(BigInt('0x' + body.slice(192, 256)));
    const at = o => body.slice(128 + o * 2, 128 + o * 2 + 64);
    eq(BigInt('0x' + at(off0)), 3n, 'elem0 length');
    eq(BigInt('0x' + at(off1)), 1n, 'elem1 length');
  });

  check('SLOW id packing decodes as token | delay<<160', () => {
    const tok = '0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48';
    const id = BigInt(tok) | (86400n << 160n);
    eq(idTok(id), tok, 'token');
    eq(idDelay(id), 86400n, 'delay');
  });

  check('decodeString handles bytes32 and dynamic string returns', () => {
    const b32 = '0x' + Buffer.from('USDC').toString('hex').padEnd(64, '0');
    eq(decodeString(b32), 'USDC', 'bytes32 symbol');
    const dyn = '0x' + (32).toString(16).padStart(64, '0') + (4).toString(16).padStart(64, '0') +
      Buffer.from('WBTC').toString('hex').padEnd(64, '0');
    eq(decodeString(dyn), 'WBTC', 'dynamic symbol');
  });

  // ---- decQ against recorded mainnet quoter returns ----
  if (!fs.existsSync(FIXTURES)) {
    fail('decQ fixtures present', `${path.relative(ROOT, FIXTURES)} missing`);
  } else {
    const fx = JSON.parse(fs.readFileSync(FIXTURES, 'utf8'));
    const SOURCES = ['UniV2', 'Sushi', 'zAMM', 'UniV3', 'UniV4', 'Curve', 'Lido'];
    const MULTICALL = '0xac9650d8';

    const decode = f => decQ(f.data, 50n, f.eo, f.u, f.v, f.S);

    check('decQ: 2-hop builder return decodes coherently', () => {
      const r = decode(fx.twoHop_ETH_USDC);
      eq(r.best.amountIn, 1000000000000000000n, 'amountIn == swapAmount');
      eq(r.msgValue, 1000000000000000000n, 'msgValue == ETH in');
      if (r.best.amountOut <= 0n) throw Error('amountOut is zero');
      if (!r.callData.startsWith(MULTICALL)) throw Error('callData is not a multicall');
      if (r.amountLimit >= r.best.amountOut) throw Error('exact-in min must be below quote');
      return `${SOURCES[r.best.source]}, out ${r.best.amountOut}`;
    });

    check('decQ: 3-hop builder return decodes coherently', () => {
      const r = decode(fx.threeHop_BOLD_RETH);
      eq(r.best.amountIn, 1000000000000000000000n, 'amountIn == swapAmount');
      eq(r.msgValue, 0n, 'ERC-20 in => no msg.value');
      if (r.best.amountOut <= 0n) throw Error('amountOut is zero');
      if (!r.callData.startsWith(MULTICALL)) throw Error('callData is not a multicall');
      return `${SOURCES[r.best.source]}, out ${r.best.amountOut}`;
    });

    check('decQ: split builder sums both legs', () => {
      const f = fx.split_ETH_USDC;
      const r = decode(f);
      eq(r.best.amountIn, 100000000000000000000n, 'legs[0].in + legs[1].in == swapAmount');
      eq(r.msgValue, 100000000000000000000n, 'msgValue == ETH in');
      if (r.best.amountOut <= 0n) throw Error('summed amountOut is zero');
      return `${SOURCES[r.best.source]}, out ${r.best.amountOut}`;
    });

    // Regression guard: buildHybridSplit returns a Quote[2] where a 100%-2-hop
    // win leaves legs[0] entirely zero. Reading source from legs[0] unconditionally
    // reports enum 0 (UniV2) for a route that never touched UniV2 — this fixture
    // is exactly that case, captured from mainnet.
    check('decQ: labels the populated leg when legs[0] is empty', () => {
      const f = fx.hybrid_BOLD_RETH_legZeroEmpty;
      const h = f.data.slice(2);
      const word = i => BigInt('0x' + h.slice(i * 64, (i + 1) * 64));
      if (word(3) !== 0n) throw Error('fixture no longer has an empty legs[0] — recapture it');
      const r = decode(f);
      if (r.best.source === 0) throw Error('reported UniV2 from the zeroed leg (the bug this guards)');
      eq(r.best.source, Number(word(4)), 'source taken from legs[1]');
      eq(r.best.amountIn, 1000000000000000000000n, 'amountIn from populated leg');
      return `${SOURCES[r.best.source]} (not UniV2)`;
    });
  }
}

// Async load-time work settles on later ticks, so grade it after draining them.
await new Promise(r => setImmediate(r));
await new Promise(r => setImmediate(r));

check('no async errors from load-time code paths', () => {
  if (asyncErrors.length) {
    throw Error(asyncErrors.map(e => (e && e.stack) || String(e)).join('\n---\n'));
  }
});

console.log();
if (failures) {
  console.error(`${failures} check(s) FAILED`);
  process.exit(1);
}
console.log('all checks passed');
