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
import { AbiCoder, Interface } from 'ethers';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const HTML_PATH = path.join(ROOT, 'zSwap.html');
const SOL_PATH = path.join(ROOT, 'src', 'zSwap.sol');
const FIXTURES = path.join(ROOT, 'test', 'fixtures', 'quoter.json');
const TAPE_FIXTURES = path.join(ROOT, 'test', 'fixtures', 'tape.json');

const EIP170 = 24576;
const CHUNKS = 5;

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

check('actionable quotes expire after 45 seconds', () => {
  if (!/\bconst QUOTE_TTL=45000;/.test(html)) throw Error('QUOTE_TTL is not 45 seconds');
  const uses = html.match(/exp:Date\.now\(\)\+QUOTE_TTL/g) || [];
  if (uses.length !== 2) throw Error(`expected 2 quote-expiry uses, found ${uses.length}`);
  if (html.includes('Date.now()+1500000')) throw Error('legacy 25-minute quote expiry remains');
});

check('recipient and orderbook metadata guards remain wired', () => {
  if (!/return \/\^0x0\{40\}\$\/i\.test\(v\)\?""\:v/.test(html)) {
    throw Error('literal zero recipient is not rejected by rcvOf');
  }
  if (!html.includes('sA:safeSym(text(b,9))') || !html.includes('sB:safeSym(text(b,13))')) {
    throw Error('lens-provided token symbols bypass safeSym');
  }
  if (!html.includes('o.maker.toLowerCase()===account.toLowerCase()')) {
    throw Error('private maker-owned rows are filtered out');
  }
});

check('manual fills preserve native/WETH routing domains', () => {
  if (!html.includes('const routeIn=nativeIn?ZERO:r.tB')) throw Error('native input is not normalized');
  if (!html.includes('],routeIn,routeOut,account,account,dl)')) throw Error('fillPlan uses raw book tokens');
  if (!html.includes('encSnwap(ZERO,0n,account,routeOut,r.aA,SWAPBOL,fillPlan)')) {
    throw Error('prepared outer snwap does not protect the routed output');
  }
  if (!html.includes('SEL_FILL2_ETH="13092239"')) throw Error('direct native Swapboard fill selector missing');
  if (!html.includes('if(!rv&&f.addr===WETH&&t.addr===ZERO)')) {
    throw Error('WETH -> ETH direct unwrap is not preserved');
  }
  if (!html.includes('tokenIn===ZERO&&tokenOut.toLowerCase()===WETH.toLowerCase()')) {
    throw Error('ETH -> WETH does not enter strict Dutch candidate filtering');
  }
  if (!html.includes('r.dutch&&r.tA.toLowerCase()===WETH.toLowerCase()&&r.tB===ZERO')) {
    throw Error('ETH -> WETH candidates are not limited to native-quoted Dutch WETH');
  }
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
  'decQ', 'parseUnits', 'formatUnits', 'trimAmt', 'maxAmt', 'merge', 'hasAtomicBatch', 'encCalls',
  'encUint', 'encAddr', 'pad32', 'strip0x', 'keccak', 'namehash',
  'decodeString', 'idTok', 'idDelay',
  'decViewPage', 'planBookExactIn', 'planBookExactOut', 'decBar', 'rollUp', 'mergeTapes',
  'encFillPlan', 'encFillPlanAndSwap', 'encSnwap', 'encSweep',
  'encPermit2Hybrid', 'impactBps', 'safeSym',
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
  const {
    decQ, parseUnits, formatUnits, trimAmt, maxAmt, merge, hasAtomicBatch, encCalls, keccak, namehash,
    decodeString, idTok, idDelay, decViewPage, planBookExactIn, planBookExactOut,
    decBar, rollUp, mergeTapes,
    encFillPlan, encFillPlanAndSwap, encSnwap, encSweep,
    encPermit2Hybrid, impactBps, safeSym,
  } = exported;

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
    eq(maxAmt(1000000000000000001n, 18), '1.000001', 'Max rounds up');
    eq(maxAmt(1n, 18), '0.000001', 'dust Max rounds up');
    eq(maxAmt(1234567n, 6), '1.234567', 'Max preserves full token precision through 6dp');
    // a negative amount must not parse — it would encode as a huge uint256
    let threw = false;
    try { parseUnits('-1', 18); } catch { threw = true; }
    if (!threw) throw Error('parseUnits accepted a negative amount');
    // more decimals than the token has must be rejected, not silently truncated
    threw = false;
    try { parseUnits('1.1234567', 6); } catch (e) { threw = /decimals/.test(e.message); }
    if (!threw) throw Error('parseUnits accepted more decimals than the token supports');
  });

  check('safeSym strips markup, controls, and bounds untrusted metadata', () => {
    eq(safeSym('<svg onload="x">&BAD`'), 'svg onload=xBAD', 'markup stripped');
    eq(safeSym('\u0000\u0008'), '?', 'controls collapse to fallback');
    eq(safeSym('ABCDEFGHIJKLMNOPQRST'), 'ABCDEFGHIJKLMNOP', 'symbol length cap');
  });

  check('executable quote retains its real bound and value', () => {
    const est = {best: {amountIn: 100n, amountOut: 200n}, amountLimit: 101n, msgValue: 0n};
    const exe = {
      best: {amountIn: 103n, amountOut: 194n},
      amountLimit: 107n,
      msgValue: 109n,
      callData: '0x1234',
    };
    const q = merge(est, exe);
    eq(q.best.amountIn, 100n, 'zero-bound input estimate retained');
    eq(q.best.amountOut, 200n, 'zero-bound output estimate retained');
    eq(q.amountLimit, 107n, 'executable per-leg bound retained');
    eq(q.msgValue, 109n, 'executable msg.value retained');
    eq(q.callData, '0x1234', 'executable calldata retained');
  });

  check('atomic batching honors mainnet and chain-global capabilities', () => {
    if (!hasAtomicBatch({'0x1': {atomic: {status: 'supported'}}})) {
      throw Error('mainnet atomic capability ignored');
    }
    if (!hasAtomicBatch({'0x0': {atomic: {status: 'ready'}}})) {
      throw Error('chain-global atomic capability ignored');
    }
    if (hasAtomicBatch({'0x0': {atomic: {status: 'unsupported'}}})) {
      throw Error('unsupported global atomic capability accepted');
    }
    if (hasAtomicBatch({
      '0x1': {atomic: {status: 'unsupported'}},
      '0x0': {atomic: {status: 'supported'}},
    })) {
      throw Error('chain-specific unsupported capability did not override global');
    }
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

  check('decViewPage validates and decodes the lens OrderView ABI', () => {
    const coder = AbiCoder.defaultAbiCoder();
    const rowType =
      'tuple(uint256,address,bool,uint64,bool,bool,address,address,uint256,string,uint8,address,uint256,string,uint8,address)[]';
    const row = [
      7n, '0x0000000000000000000000000000000000000011', true, 9n, false, false,
      '0x0000000000000000000000000000000000000022',
      '0x0000000000000000000000000000000000000033', 40n, 'OUT', 18,
      '0x0000000000000000000000000000000000000044', 20n, 'PAY', 6,
      '0x0000000000000000000000000000000000000055',
    ];
    const p = decViewPage(coder.encode([rowType, 'uint256'], [[row], 6n]));
    eq(p.next, 6n, 'cursor');
    eq(p.rows.length, 1, 'row count');
    eq(p.rows[0].id, 7, 'order id');
    eq(p.rows[0].aA, 40n, 'amountA');
    eq(p.rows[0].sB, 'PAY', 'symbolB');
  });

  check('book planner and executor encoders agree on mixed Fill legs', () => {
    const rows = [
      { id: 1, board: '0x0000000000000000000000000000000000000011', pf: false, nA: false, nB: false, aA: 60n, aB: 40n },
      { id: 2, board: '0x0000000000000000000000000000000000000022', pf: true,  nA: false, nB: false, aA: 120n, aB: 80n },
      // Better unit rate but impossible AON: it must not crowd usable rows.
      { id: 3, board: '0x0000000000000000000000000000000000000033', pf: false, nA: false, nB: false, aA: 1000n, aB: 500n },
    ];
    const p = planBookExactIn(rows, 100n, 100n, 100n);
    eq(p.bookIn, 100n, 'book input');
    eq(p.bookOut, 150n, 'book output');
    eq(p.fills.length, 2, 'fill count');
    const fp = encFillPlan(
      p.fills,
      '0x0000000000000000000000000000000000000044',
      '0x0000000000000000000000000000000000000055',
      '0x0000000000000000000000000000000000000066',
      '0x0000000000000000000000000000000000000077',
      99n,
    );
    if (!fp.startsWith('0xc277f67c')) throw Error('wrong fillPlan selector');
    const sn = encSnwap(
      '0x0000000000000000000000000000000000000044', p.bookIn,
      '0x0000000000000000000000000000000000000066',
      '0x0000000000000000000000000000000000000055', p.bookOut,
      '0x0000000000000000000000000000000000000077', fp,
    );
    if (!sn.startsWith('0x5f3bd1c8')) throw Error('wrong snwap selector');

    const po = planBookExactOut(rows, 90n, 100n, 100n);
    eq(po.bookOut, 90n, 'exact-out book output');
    eq(po.bookIn, 60n, 'exact-out book input');
    eq(po.ammOut, 0n, 'exact-out remainder');

    const ammData = '0x12345678aabb';
    const fps = encFillPlanAndSwap(
      p.fills,
      '0x0000000000000000000000000000000000000044',
      '0x0000000000000000000000000000000000000055',
      '0x0000000000000000000000000000000000000066',
      '0x0000000000000000000000000000000000000077',
      99n, 7n, ammData,
    );
    const iface = new Interface([
      'function fillPlanAndSwap(address,address,address,address,uint256,(uint256,address,uint256,uint256,bool)[],uint256,bytes)',
    ]);
    const d = iface.decodeFunctionData('fillPlanAndSwap', fps);
    eq(d[5].length, 2, 'combined fill count');
    eq(d[6], 7n, 'AMM input');
    eq(d[7], ammData, 'AMM calldata');
    const sw = encSweep(
      '0x0000000000000000000000000000000000000044', 7n,
      '0x0000000000000000000000000000000000000077',
    );
    if (!sw.startsWith('0xcb019b84')) throw Error('wrong sweep selector');
    const funded = encPermit2Hybrid(
      '0x12345678', p.fills,
      '0x0000000000000000000000000000000000000044',
      '0x0000000000000000000000000000000000000055',
      '0x0000000000000000000000000000000000000066',
      '0x0000000000000000000000000000000000000077',
      99n, p.bookIn, p.bookOut,
    );
    const mc = new Interface(['function multicall(bytes[])']).decodeFunctionData('multicall', funded)[0];
    eq(mc.length, 5, 'Permit2 prepared call count');
    if (!mc[0].startsWith('0x5f3bd1c8') || !mc[1].startsWith('0xcb019b84') ||
        !mc[2].startsWith('0x5f3bd1c8') || mc[3] !== '0x12345678' ||
        !mc[4].startsWith('0xcb019b84')) throw Error('Permit2 call order');
    const snwapIface = new Interface([
      'function snwap(address,uint256,address,address,uint256,address,bytes)',
    ]);
    const checkpoint = snwapIface.decodeFunctionData('snwap', mc[0]);
    if (!checkpoint[6].startsWith('0xa972985e')) throw Error('missing funding checkpoint');
  });

  check('book planners retain a zero-cost Dutch fill', () => {
    const freeDutch = [{
      id: 41,
      board: '0x00000000000000000000000000000000000000d1',
      // SwapboardView exposes fungible Dutch listings as partially fillable.
      pf: true,
      nA: false,
      nB: false,
      aA: 25n,
      aB: 0n,
      dutch: true,
    }];

    const pi = planBookExactIn(freeDutch, 100n, 100n, 100n);
    if (!pi) throw Error('exact-in discarded the zero-cost Dutch row');
    eq(pi.fills.length, 1, 'exact-in Dutch fill count');
    eq(pi.fills[0].pay, 0n, 'exact-in Dutch payment');
    eq(pi.fills[0].get, 25n, 'exact-in Dutch output');
    eq(pi.bookIn, 0n, 'exact-in Dutch book input');
    eq(pi.bookOut, 25n, 'exact-in Dutch book output');
    eq(pi.ammIn, 100n, 'exact-in AMM remainder');

    const po = planBookExactOut(freeDutch, 10n, 100n, 100n);
    if (!po) throw Error('exact-out discarded the zero-cost Dutch row');
    eq(po.fills.length, 1, 'exact-out Dutch fill count');
    eq(po.fills[0].pay, 0n, 'exact-out Dutch payment');
    eq(po.fills[0].get, 10n, 'exact-out Dutch output');
    eq(po.fills[0].part, true, 'exact-out Dutch partial flag');
    eq(po.bookIn, 0n, 'exact-out Dutch book input');
    eq(po.bookOut, 10n, 'exact-out Dutch book output');
    eq(po.ammOut, 0n, 'exact-out AMM remainder');
  });

  check('paired AON seeding escapes the greedy single-seed trap', () => {
    // X has the best unit rate/cost and therefore follows either single seed,
    // but its smaller lot crowds out the other 12-unit AON. A+B is globally
    // better: exact-in scores 48 vs 47; exact-out costs 48 vs 49.
    const exactInRows = [
      {id: 3, board: '0x0000000000000000000000000000000000000003', pf: false, nA: false, nB: false, aA: 21n, aB: 10n},
      {id: 1, board: '0x0000000000000000000000000000000000000001', pf: false, nA: false, nB: false, aA: 24n, aB: 12n},
      {id: 2, board: '0x0000000000000000000000000000000000000002', pf: false, nA: false, nB: false, aA: 24n, aB: 12n},
    ];
    const pi = planBookExactIn(exactInRows, 24n, 24n, 24n);
    if (!pi) throw Error('exact-in produced no paired-AON plan');
    eq(pi.fills.map(f => f.id).join(','), '1,2', 'exact-in paired AON ids');
    eq(pi.bookIn, 24n, 'exact-in paired AON input');
    eq(pi.bookOut, 48n, 'exact-in paired AON output');
    eq(pi.ammIn, 0n, 'exact-in paired AON remainder');
    eq(pi.bounded, true, 'exact-in AON heuristic disclosure');

    const exactOutRows = [
      {id: 3, board: '0x0000000000000000000000000000000000000003', pf: false, nA: false, nB: false, aA: 10n, aB: 19n},
      {id: 1, board: '0x0000000000000000000000000000000000000001', pf: false, nA: false, nB: false, aA: 12n, aB: 24n},
      {id: 2, board: '0x0000000000000000000000000000000000000002', pf: false, nA: false, nB: false, aA: 12n, aB: 24n},
    ];
    const po = planBookExactOut(exactOutRows, 24n, 3n, 1n);
    if (!po) throw Error('exact-out produced no paired-AON plan');
    eq(po.fills.map(f => f.id).join(','), '1,2', 'exact-out paired AON ids');
    eq(po.bookIn, 48n, 'exact-out paired AON input');
    eq(po.bookOut, 24n, 'exact-out paired AON output');
    eq(po.ammOut, 0n, 'exact-out paired AON remainder');
    eq(po.bounded, true, 'exact-out AON heuristic disclosure');
  });

  check('book planners cap executable plans at 32 legs', () => {
    const rows = Array.from({length: 40}, (_, i) => ({
      id: i + 1,
      board: '0x00000000000000000000000000000000000000c1',
      pf: true,
      nA: false,
      nB: false,
      aA: 2n,
      aB: 1n,
    }));

    const pi = planBookExactIn(rows, 40n, 40n, 40n);
    if (!pi) throw Error('exact-in produced no capped plan');
    eq(pi.fills.length, 32, 'exact-in leg cap');
    eq(pi.bookIn, 32n, 'exact-in capped book input');
    eq(pi.bookOut, 64n, 'exact-in capped book output');
    eq(pi.ammIn, 8n, 'exact-in capped AMM remainder');
    eq(pi.bounded, true, 'exact-in cap disclosure');

    const po = planBookExactOut(rows, 80n, 3n, 1n);
    if (!po) throw Error('exact-out produced no capped plan');
    eq(po.fills.length, 32, 'exact-out leg cap');
    eq(po.bookIn, 32n, 'exact-out capped book input');
    eq(po.bookOut, 64n, 'exact-out capped book output');
    eq(po.ammOut, 16n, 'exact-out capped AMM remainder');
    eq(po.bounded, true, 'exact-out cap disclosure');
  });

  // ---- price impact ----
  // This exists because the bug it guards was found by READING the code, not by
  // running it: impactBps compared one direction for both trade types, so every
  // exactOut quote reported 0% and the confirm gate never fired on that path.
  // Every measurement taken at the time was exactIn, so nothing would have caught
  // it. Direction is the whole point of this helper, so it gets pinned.
  check('impactBps: exactIn reports a shortfall in output', () => {
    // reference priced 1/100th; linear would be 10_000, actual 9_000 => 10%
    eq(impactBps(9000n, 100n, false), 1000n, 'exactIn 10% shortfall');
    eq(impactBps(10000n, 100n, false), 0n, 'exactIn exactly linear');
    eq(impactBps(11000n, 100n, false), 0n, 'exactIn better than linear is not impact');
  });

  check('impactBps: exactOut reports an overspend in input', () => {
    // exactOut is inverted: paying MORE than linear is the impact
    eq(impactBps(11000n, 100n, true), 1000n, 'exactOut 10% overspend');
    eq(impactBps(10000n, 100n, true), 0n, 'exactOut exactly linear');
    eq(impactBps(9000n, 100n, true), 0n, 'exactOut cheaper than linear is not impact');
  });

  check('impactBps: refuses to guess when either side is unknown', () => {
    eq(impactBps(0n, 100n, false), null, 'no amount');
    eq(impactBps(9000n, 0n, false), null, 'no reference');
  });

  check('impactBps: the two directions disagree on the same numbers', () => {
    // the exact confusion that produced the bug - if these ever match again,
    // one of the branches has been collapsed back into the other
    const a = impactBps(11000n, 100n, false), b = impactBps(11000n, 100n, true);
    if (String(a) === String(b)) throw Error(`directions collapsed: both ${a}`);
  });

  check('impact tiers are ordered and match the measured thresholds', () => {
    const m = html.match(/IMPACT_HIDE=(\d+)n,\s*IMPACT_WARN=(\d+)n,\s*IMPACT_CONFIRM=(\d+)n,\s*IMPACT_TYPED=(\d+)n/);
    if (!m) throw Error('impact tier constants not found');
    const [hide, warn, confirm_, typed] = m.slice(1).map(Number);
    if (!(hide < warn && warn < confirm_ && confirm_ < typed)) {
      throw Error(`tiers out of order: ${hide}/${warn}/${confirm_}/${typed}`);
    }
    // measured on mainnet: normal trades read 0-29bps, 10k ETH->USDC read 444.
    // hide must sit above the noise floor and below a real warning.
    if (hide < 30 || hide > 100) throw Error(`hide ${hide}bps outside the measured noise band`);
    if (typed < 2000) throw Error(`typed gate ${typed}bps low enough to fire on legitimate trades`);
    return `${hide}/${warn}/${confirm_}/${typed} bps`;
  });

  check('impact demo panel has not drifted from the page', () => {
    const demo = path.join(ROOT, 'dapp', 'impact', 'index.html');
    if (!fs.existsSync(demo)) return 'no demo panel present';
    const grab = f => {
      const m = fs.readFileSync(f, 'utf8').match(
        /IMPACT_HIDE=(\d+)n,\s*IMPACT_WARN=(\d+)n,\s*IMPACT_CONFIRM=(\d+)n,\s*IMPACT_TYPED=(\d+)n/);
      if (!m) throw Error(`impact tiers not found in ${path.basename(f)}`);
      return m.slice(1).join('/');
    };
    const a = grab(HTML_PATH), b = grab(demo);
    // A preview that certifies a UX nobody ships is worse than no preview.
    if (a !== b) throw Error(`page ${a} vs demo ${b}`);
    // the helper itself must be the same expression, not a lookalike
    const fn = f => (fs.readFileSync(f, 'utf8').match(/const impactBps=\([^;]*;[^;]*;[^;]*;/) || [''])[0].replace(/\s+/g, '');
    if (fn(HTML_PATH) !== fn(demo)) throw Error('impactBps body differs between page and demo');
    return `tiers ${a} match`;
  });

  // ---- the price tape, against bars the CONTRACT packed ----
  // Two independent implementations of one codec drift silently, and both ways
  // it has drifted so far produced a chart that looked plausible and was wrong:
  // a 24-bit mask that dropped the float exponent, and bars drawn newest-first
  // so time ran backwards. This is the guard for both.
  if (!fs.existsSync(TAPE_FIXTURES)) {
    fail('price tape fixtures present', `${path.relative(ROOT, TAPE_FIXTURES)} missing`);
  } else {
    const tf = JSON.parse(fs.readFileSync(TAPE_FIXTURES, 'utf8'));

    check('decBar decodes bars packed by PriceTape.sol', () => {
      for (const want of tf.bars) {
        const got = decBar(BigInt(want.word));
        if (!got) throw Error(`bucket ${want.bucket} decoded as empty`);
        eq(got.b, want.bucket, 'bucket');
        // The float keeps ~7 significant digits, so compare within its bound
        // rather than exactly; a dropped exponent is orders of magnitude out.
        for (const [k, f] of [['open', 'o'], ['high', 'h'], ['low', 'l'], ['close', 'c'], ['volume', 'v']]) {
          const exp = Number(want[k]);
          if (exp === 0) { eq(got[f], 0, k); continue; }
          const rel = Math.abs(got[f] - exp) / exp;
          if (!(rel < 1e-6)) throw Error(`${k}: got ${got[f]}, want ${exp} (rel ${rel})`);
        }
        eq(got.n, want.count, 'count');
      }
      return `${tf.bars.length} bars`;
    });

    check('decBar reads the full 32-bit float field, exponent included', () => {
      // A value large enough to need an exponent: masking to 24 bits returns
      // the mantissa alone and silently divides the price by 2**exp.
      const big = tf.bars.map(b => Number(b.close)).sort((a, b) => b - a)[0];
      if (big < 1 << 24) throw Error('fixtures no longer exercise the exponent — regenerate them');
      const got = decBar(BigInt(tf.bars.find(b => Number(b.close) === big).word));
      if (Math.abs(got.c - big) / big > 1e-6) throw Error(`exponent dropped: ${got.c} vs ${big}`);
    });

    check('rollUp aggregates without reordering or losing volume', () => {
      // The fixture is written oldest-first as the contract printed it; the
      // clients receive tapes newest-first, which is what rollUp expects.
      const bars = tf.bars.map(b => decBar(BigInt(b.word))).filter(Boolean).reverse();
      const up = rollUp(bars, tf.period, tf.period * 4);
      if (!up.length) throw Error('roll-up produced nothing');
      // Newest first in, newest first out: the drawer reverses once, at the end.
      for (let i = 1; i < up.length; i++) {
        if (up[i - 1].b <= up[i].b) throw Error('roll-up is not newest-first');
      }
      const volIn = bars.reduce((a, b) => a + b.v, 0);
      const volOut = up.reduce((a, b) => a + b.v, 0);
      if (Math.abs(volIn - volOut) / volIn > 1e-9) throw Error('roll-up lost volume');
      const hiIn = Math.max(...bars.map(b => b.h)), hiOut = Math.max(...up.map(b => b.h));
      if (hiIn !== hiOut) throw Error('roll-up lost the high');
      return `${bars.length} -> ${up.length} bars`;
    });

    check('mergeTapes volume-weights and keeps the extremes', () => {
      const bucket = 100;
      const bar = (c, v) => ({b: bucket, o: c, h: c, l: c, c, v, n: 1});
      const merged = mergeTapes([[bar(100, 99)], [bar(1, 1)]]);
      eq(merged.length, 1, 'one bucket');
      const m = merged[0];
      if (!(m.c > 90)) throw Error(`thin pool moved the print: close ${m.c}`);
      eq(m.h, 100, 'high is the union');
      eq(m.l, 1, 'low is the union');
      eq(m.v, 100, 'volume sums');
    });
  }

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
