#!/usr/bin/env node
/**
 * Robustness checks for zSwap.html — the page ships as IMMUTABLE contract code,
 * so anything broken at deploy time is broken forever. There is no patch path.
 * This is the guard that runs before that becomes true.
 *
 * WHAT IT CHECKS
 *   1. Every <script> block compiles. A syntax error here bricks the dapp
 *      permanently; nothing else in the pipeline would notice.
 *   2. It still fits CHUNKS x EIP-170.
 *   3. src/zSwap.sol's chunk arity is exactly CHUNKS - the wrapper, the
 *      builders and this file must agree on one number.
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
import nodecrypto from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { AbiCoder, Interface } from 'ethers';
import { strip } from './strip-zSwap.mjs';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const HTML_PATH = path.join(ROOT, 'zSwap.html');
const SOL_PATH = path.join(ROOT, 'src', 'zSwap.sol');
const FIXTURES = path.join(ROOT, 'test', 'fixtures', 'quoter.json');
const TAPE_FIXTURES = path.join(ROOT, 'test', 'fixtures', 'tape.json');

const EIP170 = 24576;
const CHUNKS = 12;

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

// ---------- 2. size ----------
// zSwap.html IS the deployed artifact: it is stored stripped, and
// build-zSwap-chunks.mjs splits these exact bytes. strip() here is the guard —
// it must be a no-op, so a comment that creeps back in fails the size check
// rather than silently eating headroom.
check(`fits ${CHUNKS} x EIP-170`, () => {
  const deployed = Buffer.byteLength(strip(html), 'utf8');
  if (deployed !== bytes) {
    throw Error(`page is not stripped — ${(bytes - deployed).toLocaleString('en-US')} B of `
      + `comments/indentation; run: node script/strip-zSwap.mjs --write`);
  }
  const per = Math.ceil(bytes / CHUNKS);
  if (per > EIP170) throw Error(`${per} B per chunk exceeds ${EIP170} B — raise CHUNKS`);
  return `${bytes.toLocaleString('en-US')} B, ${per.toLocaleString('en-US')} B/chunk, `
    + `${(EIP170 * CHUNKS - bytes).toLocaleString('en-US')} B headroom`;
});

check('actionable quotes expire after 45 seconds', () => {
  if (!/\bconst QUOTE_TTL=45000;/.test(html)) throw Error('QUOTE_TTL is not 45 seconds');
  // Three: the routed quote, and the two 1:1 wrapped-ether shortcuts. The
  // shortcuts do not consult a venue, but they are still ACTIONABLE - each one
  // arms the button with calldata - so they expire on the same clock as
  // everything else. This read 2 until ETH -> WETH gained its own path.
  const uses = html.match(/exp:Date\.now\(\)\+QUOTE_TTL/g) || [];
  if (uses.length !== 3) throw Error(`expected 3 quote-expiry uses, found ${uses.length}`);
  if (html.includes('Date.now()+1500000')) throw Error('legacy 25-minute quote expiry remains');
});

check('recipient and orderbook metadata guards remain wired', () => {
  // Pinned to the guard, not to one spelling of it: rcvOf has since grown a
  // checksum test and a resolution cache around this line, and matching the
  // whole return expression made the check fail on changes that kept the
  // guard perfectly intact.
  if (!/\/\^0x0\{40\}\$\/i\.test\(v\)/.test(html)) {
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
  if (!html.includes('encSnwap(ZERO,0n,account,routeOut,getA,SWAPBOL,fillPlan)')) {
    // `getA`, not `r.aA`: a partial fill buys less than the whole order, and the
    // floor has to protect what is actually being bought.
    throw Error('prepared outer snwap does not protect the routed output');
  }
  // fillOrderWithEth(uint256,uint256,uint256,address) on the current board. This
  // assertion carried the PREVIOUS selector, from before the fills grew their
  // minAmountA floor, so it pinned an encoding the deployed board does not answer.
  if (!html.includes('SEL_FILL2_ETH="6f608bab"')) throw Error('direct native Swapboard fill selector missing');
  if (!html.includes('if(!rv&&f.addr===WETH&&t.addr===ZERO)')) {
    throw Error('WETH -> ETH direct unwrap is not preserved');
  }
  // The mirror. Only the unwrap half was ever pinned here, and only the unwrap
  // half existed: ETH -> WETH fell through to the router, which has no venue
  // that prices an asset against itself, so the amount sat on "..." until the
  // quote timed out. Both directions are pinned now so neither can go missing.
  if (!html.includes('if(!rv&&f.addr===ZERO&&t.addr===WETH)')) {
    throw Error('ETH -> WETH direct wrap is not preserved');
  }
  if (!html.includes('callData:"0xd0e30db0"')) {
    throw Error('the wrap does not call WETH deposit()');
  }
  if (!html.includes('tokenIn===ZERO&&tokenOut.toLowerCase()===WETH.toLowerCase()')) {
    throw Error('ETH -> WETH does not enter strict Dutch candidate filtering');
  }
  if (!html.includes('r.dutch&&r.tA.toLowerCase()===WETH.toLowerCase()&&r.tB===ZERO')) {
    throw Error('ETH -> WETH candidates are not limited to native-quoted Dutch WETH');
  }
});

// ---------- 3. the wrapper's arity is CHUNKS ----------
//
// This replaces a byte-for-byte comparison against a copy of the page embedded
// in zSwap.sol. That copy went 69 KB stale precisely because it was expensive
// to maintain and its guard aborted the build instead of updating it; the page
// is now pinned by length + keccak in test/zSwap.t.sol, where drift is
// impossible rather than merely detected.
//
// What is left worth checking here is the number every part of the pipeline
// has to agree on. The count is FIXED IN CONSTRUCTOR ARITY and permanent for a
// deployment, so a wrapper that declares thirteen slots while the builders emit
// fourteen is a deploy-time revert at best - and at worst a page served with a
// slice missing, forever.
check(`src/zSwap.sol declares exactly ${CHUNKS} chunks`, () => {
  const sol = fs.readFileSync(SOL_PATH, 'utf8');
  if (sol.includes('===== zSwap.html source')) {
    throw Error('zSwap.sol still carries an embedded page copy — run node script/build-zSwap.mjs');
  }
  const slots = [...sol.matchAll(/address public immutable DATA(\d+);/g)].map(m => Number(m[1]));
  const expected = Array.from({length: CHUNKS}, (_, i) => i + 1);
  if (slots.length !== CHUNKS || slots.some((v, i) => v !== expected[i])) {
    throw Error(`DATA1..DATA${CHUNKS} expected, found ${slots.join(',') || 'none'}`);
  }
  // Every slot must actually be ASSIGNED. A declared-but-unwritten immutable
  // does not compile, but a slot assigned from the wrong index does - and it
  // serves a page with one slice doubled and another dropped.
  for (let i = 0; i < CHUNKS; i++) {
    if (!sol.includes(`DATA${i + 1} = d[${i}];`)) throw Error(`DATA${i + 1} is not assigned from d[${i}]`);
  }
  // The array widths and loop bounds carry the same number separately: the
  // constructor's parameter, the reassembly array in _html, and the three
  // bounds that walk them.
  const widths = [...sol.matchAll(/address\[(\d+)\] memory/g)].map(m => Number(m[1]));
  if (widths.length !== 2 || widths.some(v => v !== CHUNKS)) {
    throw Error(`expected two address[${CHUNKS}] arrays, found ${widths.join(',') || 'none'}`);
  }
  // Scoped to the two bodies that WALK the chunks. A blanket scan over the file
  // also catches `i != 32`, the lineage walk's own bound, which has nothing to
  // do with the chunk count and would make this check a nuisance that gets
  // deleted rather than a guard that gets kept.
  const body = (start, end) => {
    const i = sol.indexOf(start);
    if (i < 0) throw Error(`could not find ${start.trim()} in zSwap.sol`);
    const j = sol.indexOf(end, i);
    return sol.slice(i, j < 0 ? sol.length : j);
  };
  const ctor = body('constructor(address dao', 'function deployNext');
  const reassemble = body('function _html(', '\n}');
  for (const [where, src, re] of [
    ['constructor', ctor, /[ij] != (\d+);/g],
    ['_html', reassemble, /lt\(i, (\d+)\)/g],
  ]) {
    const found = [...src.matchAll(re)];
    if (!found.length) throw Error(`no chunk loop bound found in ${where}`);
    for (const m of found) {
      if (Number(m[1]) !== CHUNKS) throw Error(`${where}: "${m[0].trim()}" disagrees with CHUNKS=${CHUNKS}`);
    }
  }
  return `${CHUNKS} slots, assignments, arrays and loop bounds agree`;
});

// ---------- 4b. the lineage constants the page ships ----------
// ZSWAP_SELF and ZSWAP_PREVIOUS are hand-written: nothing generates them, and
// nothing else in the pipeline would notice a malformed one until the page was
// immutable. ZSWAP_PREVIOUS feeds an href, and ZSWAP_SELF is the address the
// `latest()` read falls back to when the page is not served from a gateway
// hostname - a typo in either is permanent.
//
// ZSWAP_SELF MUST BE EMPTY, IN EVERY BUILD, NOT JUST THE ROOT. It looks like a
// value a successor could carry, because a successor's address is CREATE2 and
// therefore knowable in advance - but knowable from WHAT. The address is
// keccak(0xff, predecessor, salt, keccak(initcode)), the initcode names the
// nine chunk contracts, and the chunks ARE these bytes. Writing the address
// into the page changes the chunks, which changes the initcode, which changes
// the address. Choosing a salt does not escape it: satisfying
// address(salt, bytes(address)) == address is a hash preimage, not a search.
// So the page learns its address from the gateway hostname or not at all, and
// a non-empty ZSWAP_SELF is not a bold claim - it is a wrong one.
//
// ZSWAP_PREVIOUS has no such circularity: the predecessor exists and its
// address does not depend on what the successor says about it.
check('lineage constants are well-formed', () => {
  const one = name => {
    const m = html.match(new RegExp(`const ${name}="([^"]*)";`));
    if (!m) throw Error(`${name} is not declared in the page`);
    if (m[1] !== '' && !/^0x[0-9a-fA-F]{40}$/.test(m[1])) {
      throw Error(`${name}="${m[1]}" is neither empty nor a 20-byte address`);
    }
    return m[1];
  };
  const self = one('ZSWAP_SELF');
  const prev = one('ZSWAP_PREVIOUS');
  if (self) {
    throw Error(`ZSWAP_SELF="${self}" — a page cannot name its own address; the bytes determine it`);
  }
  // The selector the page calls `latest()` with. A wrong four bytes is a call
  // that reverts or, worse, hits some other function of a future successor.
  for (const [name, sig] of [
    ['SEL_LATEST', 'function latest() view returns (address)'],
    ['SEL_PREV', 'function PREVIOUS() view returns (address)'],
    ['SEL_SUCCAT', 'function succeededAt() view returns (uint96)'],
  ]) {
    const sel = html.match(new RegExp(`${name}="([0-9a-f]{8})"`));
    if (!sel) throw Error(`${name} is not declared in the page`);
    const real = new Interface([sig]).getFunction(sig.split(' ')[1].split('(')[0]).selector.slice(2);
    if (sel[1] !== real) throw Error(`${name}=${sel[1]} but the real selector is ${real}`);
  }
  // The page waits out the same delay the resolver does before it points a
  // reader at a newer version. Two numbers, one policy: if they drift, the
  // page and the name disagree about which version is safe to follow, and the
  // page's copy is the one that can never be corrected.
  const mat = html.match(/const MATURITY=(\d+);/);
  if (!mat) throw Error('MATURITY is not declared in the page');
  const solMat = fs.readFileSync(path.join(ROOT, 'src', 'utils', 'zSwapResolver.sol'), 'utf8')
    .match(/uint256 public constant MATURITY = (\d+) days;/);
  if (!solMat) throw Error('zSwapResolver.MATURITY is not a plain "N days" constant');
  const wantSecs = Number(solMat[1]) * 86400;
  if (Number(mat[1]) !== wantSecs) {
    throw Error(`page MATURITY=${mat[1]}s but zSwapResolver says ${solMat[1]} days (${wantSecs}s)`);
  }
  const sol = fs.readFileSync(SOL_PATH, 'utf8');
  if (!/function latest\(\) external view returns \(address tip\)/.test(sol)) {
    throw Error('zSwap.sol no longer exposes latest() with the signature the page calls');
  }
  return prev ? `successor build, prev ${prev}` : 'root build (no predecessor)';
});

// ---------- 5. auto-global element ids resolve ----------
// The page resolves most elements through auto-globals: the browser exposes
// every id= as a global, so a renamed or deleted id fails at runtime, not at
// build. That is the direction that bites - SCRIPT -> MARKUP - and check 6
// below is what actually enforces it, by seeding the sandbox with exactly this
// set and letting any other bare identifier throw a real ReferenceError.
//
// This check used to assert the REVERSE, that every id in the markup is named
// somewhere in the script, and failed on `amtRow` and `outRow`: two <div
// class="row"> layout anchors that exist for CSS and are not supposed to be
// scripted. An id no one reads is not a defect, and a check that calls it one
// gets satisfied by naming the id in a comment - which protects nothing. What
// IS worth pinning is the ids the page addresses by string, since those skip
// the auto-global mechanism and so skip check 6's coverage entirely.
const ids = new Set([...html.matchAll(/\bid="([^"]+)"/g)].map(m => m[1]));
check('element ids addressed by string exist in the markup', () => {
  const js = scripts.join('\n');
  const byName = [...js.matchAll(/getElementById\(["'`]([A-Za-z0-9_-]+)["'`]\)/g)].map(m => m[1]);
  const missing = [...new Set(byName)].filter(id => !ids.has(id));
  if (missing.length) throw Error(`getElementById for id(s) not in the markup: ${missing.join(', ')}`);
  return `${ids.size} ids, ${new Set(byName).size} addressed by string`;
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
  'encPermit2Hybrid', 'impactBps', 'safeSym', 'safeUrl', 'genIcon',
  'wcToWallet', 'wcNode', 'wcHost',
];
// Exported for the same reason as HELPERS, but they are namespaces rather than
// functions: the hand-rolled WalletConnect crypto and the QR encoder. These
// ship on chain and can never be patched, so the vectors below run against the
// PAGE'S copy, not against a scratch one that merely resembles it.
const NAMESPACES = ['WCU', 'QR8'];

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
    // getElementById returns a stub for an id the markup really has, and null
    // for one it does not - which is what the page's own `if (!el) return`
    // guards are written against. Omitting it entirely made this check fail
    // with "document.getElementById is not a function", so the page never
    // evaluated and checks 6+ were asserting against nothing at all.
    document: {
      documentElement: stub(),
      addEventListener: () => {},
      createElement: () => stub(),
      getElementById: (id) => (ids.has(id) ? stub() : null),
    },
    window: { addEventListener: () => {} },
  };
  for (const id of ids) if (!(id in sandbox)) sandbox[id] = stub();

  const ctx = vm.createContext(sandbox);
  const epilogue = `;globalThis.__exports={${HELPERS.concat(NAMESPACES).join(',')}};`;
  vm.runInContext(scripts.join('\n') + epilogue, ctx, { filename: 'zSwap.html' });

  exported = ctx.__exports;
  if (!exported) throw Error('epilogue did not export — sandbox wiring is broken');
  const missing = HELPERS.filter(h => typeof exported[h] !== 'function');
  if (missing.length) throw Error(`helper(s) missing or not functions: ${missing.join(', ')}`);
  const missingNs = NAMESPACES.filter(n => !exported[n] || typeof exported[n] !== 'object');
  if (missingNs.length) throw Error(`namespace(s) missing: ${missingNs.join(', ')}`);
  return `${HELPERS.length} helpers + ${NAMESPACES.length} namespaces reachable`;
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
    encPermit2Hybrid, impactBps, safeSym, safeUrl, genIcon,
  } = exported;

  const { WCU, QR8 } = exported;

  // The one primitive no browser exposes, so the page must carry it. Node's
  // own chacha20-poly1305 is the reference; nothing is vendored to check it.
  // WalletConnect pairs each request tag with a specific response tag. Acking
  // wc_sessionSettle (1102) with 1109 instead of 1103 made a real wallet report
  // itself connected and then ignore every request the page sent, which reads
  // as the dapp hanging. The pairs are pinned so that cannot come back.
  // The read node exists ONLY inside a WalletConnect session, because routing
  // every eth_call to a phone measured at ~5s round trip. Signing must still go
  // to the wallet: a node that could answer eth_sendTransaction would be a very
  // different trust assumption than one that answers eth_call.
  check('WalletConnect routes signing to the wallet and reads to the node', () => {
    const { wcToWallet } = exported;
    const toWallet = ['eth_sendTransaction', 'eth_signTransaction', 'personal_sign', 'eth_sign',
      'eth_signTypedData', 'eth_signTypedData_v3', 'eth_signTypedData_v4',
      'wallet_switchEthereumChain', 'wallet_sendCalls', 'wallet_getCapabilities',
      'wallet_getCallsStatus', 'wallet_revokePermissions'];
    const toNode = ['eth_call', 'eth_getCode', 'eth_gasPrice', 'eth_getBalance',
      'eth_blockNumber', 'eth_getTransactionReceipt'];
    for (const m of toWallet) if (!wcToWallet(m)) throw Error(`${m} would leave the wallet`);
    for (const m of toNode) if (wcToWallet(m)) throw Error(`${m} would go to the wallet, not the node`);
    // Everything the page actually calls must be classified deliberately.
    const used = new Set([...html.matchAll(/rpc\("([a-zA-Z_]+)"/g)].map(m => m[1]));
    for (const m of used) if (!toWallet.includes(m) && !toNode.includes(m)
        && !['eth_accounts', 'eth_requestAccounts'].includes(m))
      throw Error(`${m} is called but not covered by the routing table`);
    return `${toWallet.length} to wallet, ${toNode.length} to node`;
  });

  check('the page makes no network call outside the WalletConnect read path', () => {
    const hits = [...html.matchAll(/\bfetch\s*\(/g)].length;
    if (hits !== 1) throw Error(`expected exactly one fetch(, found ${hits}`);
    const fn = html.match(/async function wcRpc\(method,params\)\{[\s\S]*?\n\}/);
    if (!fn || !/\bfetch\s*\(/.test(fn[0])) throw Error('the only fetch is not the one inside wcRpc');
    if (/XMLHttpRequest|EventSource|navigator\.sendBeacon/.test(html))
      throw Error('another network primitive appeared in the page');
    return 'one fetch, inside wcRpc';
  });

  check('WalletConnect protocol tags match the spec', () => {
    const want = { T_PROPOSE: 1100, T_APPROVE: 1101, T_SETTLE: 1102,
                   T_SETTLE_RES: 1103, T_REQ: 1108, T_RES: 1109 };
    for (const [name, v] of Object.entries(want)) {
      const m = html.match(new RegExp(`${name}=(\\d+)`));
      if (!m) throw Error(`${name} is not declared in the page`);
      if (+m[1] !== v) throw Error(`${name} is ${m[1]}, spec says ${v}`);
    }
    if (!/wc_sessionSettle[\s\S]{0,400}?T_SETTLE_RES/.test(html))
      throw Error('the wc_sessionSettle ack does not publish with T_SETTLE_RES');
    return `${Object.keys(want).length} tags, settle acked with 1103`;
  });

  check('ChaCha20-Poly1305 matches node across message sizes', () => {
    for (const len of [0, 1, 15, 16, 17, 63, 64, 65, 512, 5000]) {
      const key = nodecrypto.randomBytes(32);
      const nonce = nodecrypto.randomBytes(12);
      const msg = nodecrypto.randomBytes(len);
      const c = nodecrypto.createCipheriv('chacha20-poly1305', key, nonce, { authTagLength: 16 });
      const ref = Buffer.concat([c.update(msg), c.final(), c.getAuthTag()]);
      const got = Buffer.from(WCU.seal(key, nonce, msg));
      if (!got.equals(ref)) throw Error(`seal differs from node at ${len} bytes`);
      const back = WCU.open(key, nonce, got);
      if (!back || !Buffer.from(back).equals(msg)) throw Error(`open failed at ${len} bytes`);
    }
    return '10 sizes, sealed and opened';
  });

  check('a tampered envelope never decrypts', () => {
    const key = nodecrypto.randomBytes(32), nonce = nodecrypto.randomBytes(12);
    const sealed = WCU.seal(key, nonce, nodecrypto.randomBytes(64));
    for (const i of [0, 33, sealed.length - 1]) {
      const bad = Uint8Array.from(sealed); bad[i] ^= 1;
      if (WCU.open(key, nonce, bad) !== null) throw Error(`tamper at ${i} was accepted`);
    }
    if (WCU.open(nodecrypto.randomBytes(32), nonce, sealed) !== null) throw Error('wrong key accepted');
    return 'ciphertext, tag and key all rejected';
  });

  // Relay auth is a JWT whose issuer IS the key. A wrong did:key encoding means
  // the relay refuses every connection, so it is pinned to the W3C vector.
  check('did:key matches the W3C Ed25519 vector', () => {
    const pub = Uint8Array.from(Buffer.from(
      '2e6fcce36701dc791488e0d0b1745cc1e33a4c1c9fcc41c63bd343dbbe0970e6', 'hex'));
    const want = 'did:key:z6MkhaXgBZDvotDkL5257faiztiGiC2QtKLGpbnnEGta2doK';
    const got = WCU.didKey(pub);
    if (got !== want) throw Error(`got ${got}`);
    return 'multicodec + base58btc agree with the spec';
  });

  // A WalletConnect pairing URI is always exactly 160 bytes, which is why the
  // encoder can hardcode version 8 / ECC L. The golden hash was taken from an
  // encoder verified module-for-module against the `qrcode` package on 50
  // random URIs; it pins that agreement without vendoring the package.
  check('QR encoder is stable and correctly sized', () => {
    const uri = 'wc:' + 'a'.repeat(64) + '@2?relay-protocol=irn&symKey=' + 'b'.repeat(64);
    if (uri.length !== 160) throw Error(`uri length drifted to ${uri.length}`);
    const q = QR8.build(uri);
    if (q.size !== 49) throw Error(`expected a 49x49 symbol, got ${q.size}`);
    const flat = q.modules.map(r => r.join('')).join('');
    const h = nodecrypto.createHash('sha256').update(flat).digest('hex');
    if (h !== '380ce9a4bf0815c44838b42bc69c815e5e49b33110beb99e918acb19d38c5566') throw Error(`QR modules changed: ${h}`);
    return `49x49, mask ${q.mask}`;
  });

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

  check('safeUrl admits only https and inline images', () => {
    eq(safeUrl('https://x.io/a.png'), 'https://x.io/a.png', 'https passes');
    eq(safeUrl('data:image/svg+xml;base64,QUJD'), 'data:image/svg+xml;base64,QUJD', 'inline image passes');
    eq(safeUrl('javascript:alert(1)'), '', 'javascript scheme refused');
    eq(safeUrl('data:text/html;base64,QUJD'), '', 'non-image data URL refused');
    eq(safeUrl('http://x.io/a.png'), '', 'plaintext http refused');
    eq(safeUrl('https://x.io/a.png" onerror="alert(1)'), '', 'attribute cannot be closed');
    // The cap bounds MARKUP SIZE, not safety - the pattern is what keeps this
    // out of trouble. It was 2048, which was tight enough to behave like a
    // format rule: base64 PNG logos in the registry were silently dropped for a
    // generated letter. Now 32 KB, so this only has to stop something absurd.
    eq(safeUrl('https://x.io/' + 'a'.repeat(4096)), 'https://x.io/' + 'a'.repeat(4096),
      'a real base64 logo is not "too long"');
    eq(safeUrl('https://x.io/' + 'a'.repeat(40000)), '', 'length still bounded');
  });

  // The registry is the one metadata source a list owner writes freely, and both
  // of its rendered fields reach innerHTML. Assert the ingress normalizes them,
  // not just that a normalizer exists somewhere in the file.
  check('registry logo and symbol cannot inject markup', () => {
    const hostile = '"><img src=x onerror=alert(1)>';
    const body = genIcon(hostile).match(/>([^<]*)<\/text>/);
    if (!body) throw Error('genIcon markup shape changed');
    if (body[1] !== 'I') throw Error(`genIcon emitted raw metadata: ${JSON.stringify(body[1])}`);
    const ingress = html.match(/const sym=safeSym\(t\.s\)[\s\S]{0,400}?next\.push\([^\n]*\n/);
    if (!ingress) throw Error('loadTokenList ingress no longer sanitizes via safeSym/safeUrl');
    if (!/const logo=safeUrl\(t\.l\);/.test(ingress[0])) throw Error('registry logo not passed through safeUrl');
    if (/\$\{t\.[sl]\}/.test(ingress[0])) throw Error('raw registry field interpolated into markup');
  });

  /**
   * Curve's exact-out refusal has to hold at BOTH places a route is chosen.
   * The direct route drops it in `pick` (covered end-to-end by
   * test/ui/swap.test.mjs), but the book+AMM planner picks the remainder leg in
   * its own `quoteRem`, and that one had no filter — so the page refused the
   * venue when it was the whole trade and embedded it when it was the tail,
   * building a plan that reverts. That second site is only reachable through a
   * full hybrid fixture, so it is pinned here at the source instead of being
   * left unguarded: a route selector that scores exact-out must consult
   * `sources` for Curve.
   */
  check('the Curve exact-out refusal is applied wherever a route is scored', () => {
    const scorers = [...html.matchAll(/eo\?y\.best\.amountIn:y\.best\.amountOut/g)];
    if (!scorers.length) throw Error('remainder scorer no longer recognizable — retarget this check');
    const remainder = html.match(/const quoteRem=async\(x,eo\)=>\{[\s\S]*?\n\};/);
    if (!remainder) throw Error('quoteRem no longer recognizable — retarget this check');
    if (!/if\(eo&&y\.sources&&y\.sources\.includes\(SRC_CURVE\)\)continue;/.test(remainder[0])) {
      throw Error('quoteRem scores exact-out routes without excluding Curve');
    }
    if (!/exactOutSafe=y=>\{if\(isIn\|\|!y\.sources\|\|!y\.sources\.includes\(SRC_CURVE\)\)/.test(html)) {
      throw Error('the direct route no longer excludes Curve on exact-out');
    }
  });

  /**
   * Both order pre-flights must fail CLOSED. `preflightAsk` always did — an
   * unreadable order throws "refresh and retry". `preflightFills`, the same
   * check for a planned route, swallowed the read failure and returned, so the
   * fill plan went out unvalidated. That is invisible on the ordinary path,
   * where the swap's own eth_call would fail too and block the send, but a
   * batching wallet goes straight to wallet_sendCalls with no simulation at
   * all: an RPC blip and the user pays for a revert. mc3Deep already retries
   * and splits, and reports an unreadable call as null, which the loop below
   * treats as stale — so the read is simply not wrapped in a swallow.
   */
  check('both order pre-flights fail closed on an unreadable order', () => {
    // Bounded by the NEXT declaration, not by a closing brace: the file ships
    // stripped, so every nested `}` also sits at column 0 and `\n}` would end
    // the match inside the first if-block.
    const between = (from, to) => {
      const a = html.indexOf(from);
      const b = html.indexOf(to, a + 1);
      return a < 0 || b < 0 ? null : [html.slice(a, b)];
    };
    const fills = between('async function preflightFills(', 'async function preflightAsk(');
    if (!fills) throw Error('preflightFills no longer recognizable — retarget this check');
    if (/catch\s*\{\s*return\s*\}/.test(fills[0])) {
      throw Error('preflightFills swallows the read failure and validates nothing');
    }
    if (!/await mc3Deep\(reads\)/.test(fills[0])) {
      throw Error('preflightFills no longer reads through the retrying reader');
    }
    const ask = between('async function preflightAsk(', 'const SEL_ORDER_FIXED=');
    if (!ask) throw Error('preflightAsk no longer recognizable — retarget this check');
    if (!/catch\{throw Error\("order could not be read/.test(ask[0])) {
      throw Error('preflightAsk no longer fails closed on an unreadable order');
    }
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

  check('book planners route a floor bid, and drop a degenerate one', () => {
    // A Floorboard row prices with price/initial rather than aA/aB, so the
    // planner divides by both. Anyone can post a bid, so a zero in either
    // field is attacker-supplied: it must drop the row, not raise out of the
    // quote path and take every route on the pair down with it.
    const bid = over => ({
      id: 7,
      board: '0x00000000000000000000000000000000000000f1',
      floor: 1, pf: true, nA: false, nB: false,
      aA: 100n, aB: 50n, price: 100n, initial: 50n,
      ...over,
    });

    const full = planBookExactIn([bid()], 50n, 50n, 50n);
    if (!full) throw Error('exact-in discarded a healthy floor bid');
    eq(full.fills[0].pay, 50n, 'exact-in floor payment');
    eq(full.fills[0].get, 100n, 'exact-in floor output');
    eq(full.ammIn, 0n, 'exact-in floor remainder');

    // A partial hit is the case that actually reaches floorGet.
    const part = planBookExactIn([bid()], 20n, 50n, 50n);
    if (!part) throw Error('exact-in discarded a partial floor hit');
    eq(part.fills[0].pay, 20n, 'exact-in partial floor payment');
    eq(part.fills[0].get, 40n, 'exact-in partial floor output');

    const out = planBookExactOut([bid()], 40n, 100n, 50n);
    if (!out) throw Error('exact-out discarded a healthy floor bid');
    eq(out.fills[0].pay, 20n, 'exact-out floor payment');
    eq(out.fills[0].get, 40n, 'exact-out floor output');
    eq(out.ammOut, 0n, 'exact-out floor remainder');

    for (const [what, bad] of [['initial', bid({ initial: 0n })], ['price', bid({ price: 0n })]]) {
      let pi, po;
      try { pi = planBookExactIn([bad], 20n, 50n, 50n); }
      catch (e) { throw Error(`exact-in raised on a zero-${what} bid: ${e.message}`); }
      try { po = planBookExactOut([bad], 40n, 100n, 50n); }
      catch (e) { throw Error(`exact-out raised on a zero-${what} bid: ${e.message}`); }
      if (pi) throw Error(`exact-in planned a zero-${what} bid`);
      if (po) throw Error(`exact-out planned a zero-${what} bid`);
    }
    return 'full, partial and exact-out route; zero price/initial dropped';
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

    const decode = f => decQ(f.data, 50n, f.eo, f.u, f.v, f.S, f.mv);

    check('decQ: 2-hop builder return decodes coherently', () => {
      const r = decode(fx.twoHop_ETH_USDC);
      eq(r.best.amountIn, 1000000000000000000n, 'amountIn == swapAmount');
      eq(r.msgValue, 1000000000000000000n, 'msgValue == ETH in');
      if (r.best.amountOut <= 0n) throw Error('amountOut is zero');
      // This capture is the via-ETH builder taking its SINGLE-HOP fast path,
      // so leg b comes back `Quote(UNI_V2, 0, 0, 0)`. Both of these guard the
      // same hazard zQuoter names in its own source: the enum's default is
      // UniV2, so a zeroed leg is indistinguishable from a real V2 hop unless
      // the amounts are consulted. Reading the route off that leg reports a
      // venue that never ran; counting it inflates the hop list the exact-out
      // Curve refusal is built on.
      eq(r.best.source, 3, 'labelled by the leg that ran, not the zeroed one');
      eq(r.sources.length, 1, 'the empty leg must not be counted as a UniV2 hop');
      if (!r.callData.startsWith(MULTICALL)) throw Error('callData is not a multicall');
      if (r.amountLimit >= r.best.amountOut) throw Error('exact-in min must be below quote');
      return `${SOURCES[r.best.source]}, out ${r.best.amountOut}`;
    });

    check('decQ: refuses a truncated return rather than decoding rubbish', () => {
      // Providers clip large `eth_call` results at their own undocumented
      // caps, and these builders return kilobytes. A short read that decoded
      // anyway would produce a route with a plausible-looking amount and a
      // callData sliced out of nothing. Throwing is what makes the caller's
      // `catch` treat the venue as unavailable, which is the honest answer.
      const f = fx.twoHop_ETH_USDC;
      for (const words of [0, 4, f.v + 1]) {
        const short = '0x' + f.data.slice(2).slice(0, words * 64);
        let threw = false;
        try { decQ(short, 50n, f.eo, f.u, f.v, f.S, f.mv); } catch { threw = true; }
        if (!threw) throw Error(`decoded a ${words}-word return instead of refusing it`);
      }
      return 'short reads at 0, 4 and v words all refused';
    });

    check('decQ: the via-ETH builder with BOTH legs populated', () => {
      // Every captured 2-hop return in the fixtures is really the via-ETH
      // builder taking its single-hop fast path: leg b comes back
      // `Quote(UNI_V2, 0, 0, 0)` and decQ falls to leg a. That is the common
      // case and it is covered - but it leaves the ACTUAL two-hop shape at
      // u=4 decoded by nothing, and the leg-b branch exercised only at u=8 by
      // the 3-hop fixture. So this one populates leg b on a real return: the
      // route's input is still leg a's, its output is now leg b's, and both
      // venues have to show up in `sources` or the Curve exact-out guard
      // cannot see a hop it needs to refuse.
      const f = fx.twoHop_ETH_USDC;
      const h = f.data.slice(2);
      const w = i => h.slice(i * 64, (i + 1) * 64);
      const u256 = v => v.toString(16).padStart(64, '0');
      if (BigInt('0x' + w(7)) !== 0n) throw Error('fixture leg b is no longer empty — rewrite this');
      const legB = u256(5n) + u256(30n) + w(3) + u256(777n);   // Curve, in = leg a's out
      const data = '0x' + h.slice(0, 4 * 64) + legB + h.slice(8 * 64);
      const r = decQ(data, 50n, f.eo, f.u, f.v, f.S, f.mv);
      eq(r.best.amountIn, 1000000000000000000n, 'input is still the FIRST leg\'s');
      eq(r.best.amountOut, 777n, 'output is the LAST leg\'s');
      eq(r.best.source, 5, 'the route is labelled by the leg that delivered');
      if (!r.sources.includes(3) || !r.sources.includes(5)) {
        throw Error(`both hops must appear in sources, got ${r.sources}`);
      }
      return `${SOURCES[3]} -> ${SOURCES[5]}, out ${r.best.amountOut}`;
    });

    check('decQ: 3-hop builder return decodes coherently', () => {
      const r = decode(fx.threeHop_BOLD_RETH);
      eq(r.best.amountIn, 1000000000000000000000n, 'amountIn == swapAmount');
      eq(r.msgValue, 0n, 'ERC-20 in => no msg.value');
      if (r.best.amountOut <= 0n) throw Error('amountOut is zero');
      if (!r.callData.startsWith(MULTICALL)) throw Error('callData is not a multicall');
      return `${SOURCES[r.best.source]}, out ${r.best.amountOut}`;
    });

    // The cheap single-hop builder. buildBestSwapViaETHMulticall needs ~160M gas
    // on mainnet and buildBestSwap needs ~5M, so on any RPC with the usual 50M
    // eth_call cap this is the ONLY router path that answers at all. Its return
    // puts amountLimit between the bytes offset and msgValue, one word more than
    // the multicall builders - read it as v+1 and every msg.value the page sends
    // for an ETH swap would silently become the slippage bound instead.
    check('decQ: single-hop builder return decodes coherently', () => {
      const f = fx.singleHop_ETH_USDC;
      if (!f) throw Error('singleHop fixture missing');
      const r = decode(f);
      eq(r.best.amountIn, 1000000000000000000n, 'amountIn == swapAmount');
      eq(r.msgValue, 1000000000000000000n, 'msgValue is the ETH in, not amountLimit');
      // The contract computed 1879300193 for this quote at 50 bps; decQ must agree
      // exactly, because this is the number the user is shown as "Min received".
      eq(r.amountLimit, 1879300193n, 'amountLimit matches SlippageLib to the wei');
      if (!r.callData.startsWith('0x')) throw Error('no callData');
      if (r.amountLimit >= r.best.amountOut) throw Error('exact-in min must be below quote');
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

    // ---- properties that must hold for EVERY shape, in BOTH directions ----
    // The per-fixture checks above pin decoded AMOUNTS against real captures.
    // The bound is a different question: amountLimit is what the user is shown
    // as "Min received" and what the approval is sized to, and it is derived
    // rather than captured. These say what it must never do, on every shape at
    // once, so a new builder shape cannot arrive with a bound nobody checked.
    const SHAPES = Object.keys(fx);

    check('decQ: an exact-in bound is never above the quote, and loosens with slippage', () => {
      for (const k of SHAPES) {
        const f = fx[k];
        const at = s => decQ(f.data, s, false, f.u, f.v, f.S, f.mv);
        const [a0, a50, a500] = [0n, 50n, 500n].map(at);
        if (a0.amountLimit !== a0.best.amountOut) {
          throw Error(`${k}: zero slippage must guarantee the quote exactly `
            + `(${a0.amountLimit} vs ${a0.best.amountOut})`);
        }
        if (!(a500.amountLimit < a50.amountLimit && a50.amountLimit < a0.amountLimit)) {
          throw Error(`${k}: bound is not monotonic in slippage `
            + `(${a0.amountLimit} / ${a50.amountLimit} / ${a500.amountLimit})`);
        }
        if (a50.amountLimit > a50.best.amountOut) {
          throw Error(`${k}: min received exceeds the quote — the page would promise more than the route`);
        }
      }
      return `${SHAPES.length} shapes`;
    });

    check('decQ: an exact-out bound is never below the quote, and loosens with slippage', () => {
      for (const k of SHAPES) {
        const f = fx[k];
        const at = s => decQ(f.data, s, true, f.u, f.v, f.S, f.mv);
        const [a0, a50, a500] = [0n, 50n, 500n].map(at);
        if (a0.amountLimit !== a0.best.amountIn) {
          throw Error(`${k}: zero slippage must cost exactly the quote `
            + `(${a0.amountLimit} vs ${a0.best.amountIn})`);
        }
        if (!(a500.amountLimit > a50.amountLimit && a50.amountLimit > a0.amountLimit)) {
          throw Error(`${k}: bound is not monotonic in slippage`);
        }
        if (a50.amountLimit < a50.best.amountIn) {
          throw Error(`${k}: max spend is below the quote — the swap could not fill`);
        }
      }
      return `${SHAPES.length} shapes`;
    });

    check('decQ: the winning source is one of the populated legs', () => {
      for (const k of SHAPES) {
        const f = fx[k];
        const r = decQ(f.data, 50n, false, f.u, f.v, f.S, f.mv);
        if (!r.sources.length) throw Error(`${k}: no populated legs reported`);
        // A split sums BOTH legs, so its label is legitimately one of several.
        if (!f.S && !r.sources.includes(r.best.source)) {
          throw Error(`${k}: labelled ${SOURCES[r.best.source]} but the populated legs are `
            + `${r.sources.map(s => SOURCES[s]).join(', ')} — the rate line names a venue `
            + `that carried none of the trade`);
        }
      }
      return `${SHAPES.length} shapes`;
    });

    check('merge takes the estimate from one quote and the bound from the other', () => {
      // The page quotes each builder TWICE, at zero slippage and at the user's,
      // then merges: amounts from the unslipped quote (the true expectation),
      // everything executable from the slipped one. If merge ever took the
      // bound from `est`, the calldata and the promise would describe different
      // trades — the number shown would be guaranteed by nothing.
      const f = fx.singleHop_ETH_USDC;
      const est = decQ(f.data, 0n, false, f.u, f.v, f.S, f.mv);
      const exe = decQ(f.data, 50n, false, f.u, f.v, f.S, f.mv);
      const m = merge(est, exe);
      eq(m.best.amountOut, est.best.amountOut, 'estimate comes from the unslipped quote');
      eq(m.amountLimit, exe.amountLimit, 'the bound comes from the executable quote');
      eq(m.callData, exe.callData, 'and so does the calldata');
      if (m.amountLimit >= m.best.amountOut) {
        throw Error('merged bound is not below the merged estimate');
      }
      if (merge(null, exe) !== exe) throw Error('a missing estimate must fall back to the executable quote');
      if (merge(est, null) !== null) throw Error('an estimate with no executable quote must not be offered');
    });
  }
}

// Async load-time work settles on later ticks, so grade it after draining them.
await new Promise(r => setImmediate(r));
await new Promise(r => setImmediate(r));

if (exported) {
  const { WCU } = exported;
  const sym = nodecrypto.randomBytes(32);
  const want = nodecrypto.createHash('sha256').update(sym).digest('hex');
  let got = null, topicErr = null;
  try { got = await WCU.topicOf(sym); } catch (e) { topicErr = e; }
  check('a pairing topic is sha256 of its own symKey', () => {
    if (topicErr) throw topicErr;
    if (got !== want) throw Error(`got ${got}, want ${want}`);
    return 'derivation agrees with node';
  });
}

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
