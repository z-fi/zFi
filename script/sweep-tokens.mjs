#!/usr/bin/env node
// Round-trip sweep of token-list.json against the DEPLOYED zQuoter.
//
// WHY THIS SHAPE
// A fork test needs the whole pool set warmed into foundry's cache, which is why
// the forge sweep kept timing out. Plain eth_call against the live contract needs
// no cache at all - but 158 tokens x 2 directions is 316 round-trips. Multicall3
// collapses that to ~26, all pinned to ONE block so the sweep is internally
// consistent and reproducible.
//
// WHAT IT CHECKS, WITHOUT AN ORACLE
// Quote ETH -> token for a fixed ETH size, then feed that exact output back as
// token -> ETH. A correct quoter must return slightly LESS than it started with:
// you crossed two spreads. So
//
//   retention = ethBack / ethIn
//
// is a self-consistency test needing no price feed. Reading it:
//   ~0.94-1.00  healthy - two lots of fees and a little impact
//   < 0.90      thin, or a quote that does not survive the return leg
//   > 1.00      only a BUG if both legs used the SAME venue - then the quoter
//               disagrees with itself. Across DIFFERENT venues it is ordinary
//               cross-venue arb: ETH->USDT on UniV3 and USDT->ETH on Curve
//               really does net ~8bps on-chain, and the quoter is right to
//               pick the best of each side.
//
// PAIRS MODE (PAIRS=n): the ETH sweep only proves each token's ETH legs. A
// token->token trade can also go through build3HopMulticall, which may pick a
// NON-ETH intermediary - a path the ETH round-trip never touches. So after the
// ETH sweep, take the healthiest tokens and round-trip them against each other
// with the 3-hop builder, applying the same same-venue contract.
//
// Usage: node script/sweep-tokens.mjs [ethSize] [rpc]      PAIRS=n for 3-hop

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import crypto from 'node:crypto';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
// A pool, not one endpoint. Public nodes rate-limit per host, so rotating turns
// "429, back off, retry" into "ask someone else". Failures rotate rather than
// sleep, and only a full lap around the pool counts as a real failure.
const RPCS = (process.argv[3] || process.env.ETH_RPC_URL || [
  'https://gateway.tenderly.co/public/mainnet',
  'https://ethereum-rpc.publicnode.com',
  'https://eth.llamarpc.com',
  'https://eth.drpc.org',
  'https://rpc.ankr.com/eth',
].join(',')).split(',').map(x => x.trim()).filter(Boolean);
// Pin a block (BLOCK=0x… or decimal) and every answer is immutable, so it can be
// cached forever. First run pays the RPC; every run after is offline and gives
// byte-identical results - which is what makes this usable in CI.
const CACHE = path.join(ROOT, 'cache', 'rpc-sweep');
const ETH_SIZE = BigInt(Math.round((Number(process.argv[2]) || 1) * 1e18));

const QUOTER = '0xc7a03f9ed2be5feea18ce93e12f4f05c98287c16';
const MC3 = '0xcA11bde05977b3631167028862bE2a173976CA11';
// buildBestSwapViaETHMulticall(address,address,bool,address,address,uint256,uint256,uint256)
// NOT getQuotes: that is the SINGLE-HOP quoter, so every token without a direct
// ETH pool (GHO, USDe, crvUSD, PYUSD - the stables that pair against USDC) reads
// as "no route" when the dapp would happily route it via ETH. This is the
// builder zSwap actually calls, so this is what users actually get.
const SELQ = 'e453166e';
const SEL3 = '4c464f59'; // build3HopMulticall(address,bool,address,address,uint256,uint256,uint256)
const ETH = '0x0000000000000000000000000000000000000000';
const WETH = '0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2';
const BATCH = Number(process.env.BATCH) || 6; // tuned: bigger starves its own tail on gas // heavy multi-pool calls; keep each eth_call inside node gas caps

const strip0x = h => (h.startsWith('0x') ? h.slice(2) : h);
const pad32 = h => strip0x(h).padStart(64, '0');
const encUint = v => pad32(BigInt(v).toString(16));
const encAddr = a => pad32(a.toLowerCase());
const encBool = b => pad32(b ? '1' : '0');

const encAgg3 = cs => {
  const n = cs.length; let head = '', tail = '', off = n * 32;
  for (const c of cs) {
    const d = strip0x(c.data), len = d.length / 2;
    const body = encAddr(c.to) + encBool(true) + encUint(96) + encUint(len)
      + d.padEnd(Math.ceil(d.length / 64) * 64, '0');
    head += encUint(off); tail += body; off += body.length / 2;
  }
  return '0x82ad56cb' + pad32('20') + encUint(n) + head + tail;
};
const decAgg3 = hex => {
  const h = strip0x(hex), at = i => h.slice(i * 64, (i + 1) * 64);
  const n = Number(BigInt('0x' + at(1))), out = [];
  for (let i = 0; i < n; i++) {
    const rel = Number(BigInt('0x' + at(2 + i))) / 32, w = 2 + rel;
    const ok = BigInt('0x' + at(w)) === 1n;
    const bo = Number(BigInt('0x' + at(w + 1))) / 32, lw = w + bo;
    const len = Number(BigInt('0x' + at(lw)));
    out.push(ok ? '0x' + h.slice((lw + 1) * 64, (lw + 1) * 64 + len * 2) : null);
  }
  return out;
};

let rpcCalls = 0, cacheHits = 0, rpcIdx = 0;
fs.mkdirSync(CACHE, { recursive: true });
const ckey = (blk, o) => crypto.createHash('sha256')
  .update(String(blk) + '|' + (o.to || '') + '|' + (o.data || '')).digest('hex').slice(0, 40);
// Retry with backoff. Without this a transient rate-limit is swallowed by the
// caller's catch and reported as "no route" - which made USDC and DAI look dead
// on one run and healthy on the next. A sweep you cannot trust twice is worse
// than no sweep.
const rpc = async (method, params, tries = 8) => {
  // eth_call at a pinned block is deterministic: cache it on disk forever.
  const cacheable = method === 'eth_call' && params[1] && params[1] !== 'latest';
  const cf = cacheable ? path.join(CACHE, ckey(params[1], params[0]) + '.json') : null;
  if (cf && fs.existsSync(cf)) {
    cacheHits++;
    const c = JSON.parse(fs.readFileSync(cf, 'utf8'));
    // Failures are deterministic at a pinned block too: a batch that exhausted
    // the node's gas budget will exhaust it every time. Remembering that skips
    // straight to the per-call retry instead of re-buying the same timeout.
    if (c.e) throw new Error(c.e);
    return c.r;
  }
  for (let i = 0; ; i++) {
    rpcCalls++;
    const url = RPCS[rpcIdx++ % RPCS.length]; // rotate on every call and every retry
    try {
      const r = await fetch(url, {
        method: 'POST', headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ jsonrpc: '2.0', id: 1, method, params }),
      });
      const j = await r.json();
      if (j.error) throw new Error(JSON.stringify(j.error));
      if (cf) fs.writeFileSync(cf, JSON.stringify({ r: j.result }));
      return j.result;
    } catch (e) {
      if (i >= tries - 1) { if (cf) fs.writeFileSync(cf, JSON.stringify({ e: String(e.message || e) })); throw e; }
      // only sleep once we have tried every endpoint; otherwise just move on
      if ((i + 1) % RPCS.length === 0) await new Promise(res => setTimeout(res, 200 * 2 ** ((i + 1) / RPCS.length)));
    }
  }
};

// slippage 0 so later legs report the true estimate, not a floor.
const quoteData = (tIn, tOut, amt) =>
  '0x' + SELQ + encAddr(MC3) + encAddr(MC3) + encBool(false)
  + encAddr(tIn) + encAddr(tOut) + encUint(amt) + encUint(0) + encUint(2n ** 40n);
// legA words 0-3, legB words 4-7. The builder collapses to one call when a
// direct route wins, leaving legB zeroed - then legA carries the whole trade.
const word = (hex, i) => BigInt('0x' + strip0x(hex).slice(i * 64, (i + 1) * 64));
const amountOut = hex => {
  if (!hex || strip0x(hex).length < 11 * 64) return 0n;
  const b = word(hex, 7);
  return b !== 0n ? b : word(hex, 3);
};
// Fingerprint of the WHOLE route: (venue, feeBps) per populated leg. The venue
// enum alone is far too coarse - UniV3 has several fee tiers, so ETH->USDC->USDe
// and its reverse are both "UNI_V3" while touching entirely different pools.
// A round-trip only indicts the quoter if the return path is the exact MIRROR of
// the outbound one; anything else is ordinary cross-pool spread.
const routeOf = (hex, nLegs = 2) => {
  if (!hex || strip0x(hex).length < (nLegs * 4 + 3) * 64) return null;
  const legs = [];
  for (let i = 0; i < nLegs; i++) {
    const out = word(hex, i * 4 + 3);
    if (out !== 0n) legs.push(`${Number(word(hex, i * 4))}:${word(hex, i * 4 + 1)}`);
  }
  return legs.length ? legs : null;
};
const isMirror = (a, b) => !!a && !!b && a.length === b.length
  && a.every((v, i) => v === b[b.length - 1 - i]);
const venueOf = hex => {
  if (!hex || strip0x(hex).length < 11 * 64) return -1;
  return Number(word(hex, 7) !== 0n ? word(hex, 4) : word(hex, 0));
};
const VENUES = ['UNI_V2', 'SUSHI', 'ZAMM', 'UNI_V3', 'UNI_V4', 'CURVE', 'LIDO', 'WETH_WRAP'];

/// Run every call in one pinned block, batched, with bounded concurrency.
///
/// allowFailure makes an OUT-OF-GAS sub-call look exactly like "no route", and
/// this builder is heavy enough that a fat batch starves its own tail: at 12 per
/// call only 1 of 157 tokens survived, at 2 it was 112. Batch for speed, then
/// re-probe every failure on its own - a token that still fails alone genuinely
/// has no route. Fast for the many, exact for the few.
async function batchQuotes(calls, block, per = BATCH) {
  const groups = [];
  for (let i = 0; i < calls.length; i += per) groups.push(calls.slice(i, i + per));
  const out = [];
  const LANES = 6;
  for (let i = 0; i < groups.length; i += LANES) {
    const slice = groups.slice(i, i + LANES);
    const res = await Promise.all(slice.map(g =>
      rpc('eth_call', [{ to: MC3, data: encAgg3(g)}, block])
        .then(decAgg3)
        .catch(() => g.map(() => null))));
    for (const r of res) out.push(...r);
  }
  // Second pass: anything null might be OOG rather than routeless.
  const retry = [];
  for (let i = 0; i < out.length; i++) if (out[i] === null) retry.push(i);
  for (let i = 0; i < retry.length; i += 8) {
    const slice = retry.slice(i, i + 8);
    const res = await Promise.all(slice.map(idx =>
      rpc('eth_call', [{ to: calls[idx].to, data: calls[idx].data}, block])
        .catch(() => null)));
    res.forEach((r, k) => { if (r) out[retry[k + i]] = r; });
  }
  if (retry.length) console.log(`  (re-probed ${retry.length} batch failures individually)`);
  return out;
}

const list = JSON.parse(fs.readFileSync(path.join(ROOT, 'token-list.json'), 'utf8'));
const toks = (Array.isArray(list) ? list : list.tokens || Object.values(list).find(Array.isArray))
  .filter(t => (t.address || t.addr) && (t.address || t.addr).toLowerCase() !== WETH.toLowerCase());

const block = process.env.BLOCK
  ? (process.env.BLOCK.startsWith('0x') ? process.env.BLOCK : '0x' + BigInt(process.env.BLOCK).toString(16))
  : await rpc('eth_blockNumber', []);
console.log(`zQuoter round-trip sweep — ${toks.length} tokens, ${Number(ETH_SIZE) / 1e18} ETH, block ${BigInt(block)}\n`);

// Leg 1: ETH -> token
const fwdRaw = await batchQuotes(toks.map(t => ({ to: QUOTER, data: quoteData(ETH, t.address || t.addr, ETH_SIZE) })), block);
const outs = fwdRaw.map(amountOut);

// Leg 2: token -> ETH, using exactly what leg 1 said you would receive
const backCalls = toks.map((t, i) => ({
  to: QUOTER,
  data: quoteData(t.address || t.addr, ETH, outs[i] || 0n),
}));
const backRaw = await batchQuotes(backCalls, block);
const backs = backRaw.map(amountOut);

const rows = [], noRoute = [], suspicious = [], thin = [], arb = [];
for (let i = 0; i < toks.length; i++) {
  const sym = toks[i].symbol || toks[i].sym || '?';
  if (outs[i] === 0n) { noRoute.push(sym); continue; }
  if (backs[i] === 0n) { noRoute.push(sym + '(rev)'); continue; }
  const ret = Number(backs[i] * 10000n / ETH_SIZE) / 10000;
  const vf = venueOf(fwdRaw[i]), vb = venueOf(backRaw[i]);
  rows.push({ sym, ret });
  if (ret > 1.0) {
    const tag = `${sym} ${(ret * 100).toFixed(2)}% (${VENUES[vf]}->${VENUES[vb]})`;
    if (isMirror(routeOf(fwdRaw[i]), routeOf(backRaw[i]))) suspicious.push(tag); else arb.push(tag);
  } else if (ret < 0.90) thin.push(`${sym} ${(ret * 100).toFixed(2)}%`);
}
rows.sort((a, b) => a.ret - b.ret);

console.log('worst 12 round-trips:');
for (const r of rows.slice(0, 12)) console.log(`  ${r.sym.padEnd(10)} ${(r.ret * 100).toFixed(2)}%`);
console.log('\nbest 5:');
for (const r of rows.slice(-5).reverse()) console.log(`  ${r.sym.padEnd(10)} ${(r.ret * 100).toFixed(2)}%`);

const healthy = rows.filter(r => r.ret >= 0.90 && r.ret <= 1.0).length;
console.log(`\n  round-tripped        : ${rows.length}`);
console.log(`  healthy (90-100%)    : ${healthy}`);
console.log(`  thin (<90%)          : ${thin.length}${thin.length ? '  ' + thin.slice(0, 8).join(', ') : ''}`);
console.log(`  cross-venue arb      : ${arb.length}${arb.length ? '  ' + arb.slice(0, 6).join(', ') : ''}`);
console.log(`  SAME-VENUE >100% (BUG): ${suspicious.length}${suspicious.length ? '  ' + suspicious.join(', ') : ''}`);
console.log(`  no route             : ${noRoute.length}${noRoute.length ? '  ' + noRoute.slice(0, 10).join(', ') : ''}`);
console.log(`\n  rpc requests         : ${rpcCalls}   cache hits: ${cacheHits}   endpoints: ${RPCS.length}`);
if (suspicious.length) { console.log('\nFAIL: a round-trip beat itself on the SAME venue - the quoter disagrees with itself.'); process.exit(1); }
// ------------------------------------------------------------ edge amounts
// Was a forge fork suite; it never once ran to completion, because a cold pool
// set costs ~10min per path. Same assertions here run in seconds against the
// deployed contract. Contract: a quote is either REFUSED (0) or executable -
// never a non-zero quote for a route that cannot exist.
if (process.env.EDGE) {
  const GUSD = '0x056Fd409E1d7A124BD7017459dFEa2F387b6d5Cd'; // 2 decimals
  const USDC = '0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48';
  const cases = [
    ['1 wei ETH -> USDC', ETH, USDC, 1n],
    ['1 unit USDC -> ETH', USDC, ETH, 1n],
    ['1 GUSD (2dp) -> ETH', GUSD, ETH, 100n],
    ['zero ETH -> USDC', ETH, USDC, 0n],
    ['100k ETH -> USDC', ETH, USDC, 100000n * 10n ** 18n],
    ['1M ETH -> USDC', ETH, USDC, 1000000n * 10n ** 18n],
  ];
  console.log('\nedge amounts:');
  const res = await batchQuotes(cases.map(([, a, b, v]) => ({ to: QUOTER, data: quoteData(a, b, v) })), block, 1);
  let prev = 0n;
  for (let i = 0; i < cases.length; i++) {
    const o = amountOut(res[i]);
    console.log(`  ${cases[i][0].padEnd(22)} ${o === 0n ? 'REFUSED' : o.toString()}`);
    if (cases[i][0] === 'zero ETH -> USDC' && o !== 0n) { console.log('FAIL: zero input quoted non-zero'); process.exit(1); }
    if (cases[i][0].endsWith('ETH -> USDC') && cases[i][3] >= 100000n * 10n ** 18n) {
      if (o < prev) { console.log('FAIL: more input returned less output'); process.exit(1); }
      prev = o;
    }
  }
}

// ------------------------------------------------------------- 3-hop pairs
const PAIRS = Number(process.env.PAIRS) || 0;
if (PAIRS) {
  const hop3Data = (tIn, tOut, amt) =>
    '0x' + SEL3 + encAddr(MC3) + encBool(false) + encAddr(tIn) + encAddr(tOut)
    + encUint(amt) + encUint(0) + encUint(2n ** 40n);
  // legs a/b/c at words 0-3, 4-7, 8-11; the last populated one carries the trade
  const out3 = h => {
    if (!h || strip0x(h).length < 15 * 64) return 0n;
    return word(h, 11) || word(h, 7) || word(h, 3);
  };
  const ven3 = h => {
    if (!h || strip0x(h).length < 15 * 64) return -1;
    return Number(word(h, 11) ? word(h, 8) : word(h, 7) ? word(h, 4) : word(h, 0));
  };

  // healthiest tokens first: they have the liquidity for a meaningful hop
  const pool = rows.filter(r => r.ret >= 0.97).map(r => r.sym);
  const byS = Object.fromEntries(toks.map(t => [t.symbol || t.sym, t.address || t.addr]));
  const pairs = [];
  for (let i = 0; i < pool.length && pairs.length < PAIRS; i++)
    for (let j = 0; j < pool.length && pairs.length < PAIRS; j++)
      if (i !== j) pairs.push([pool[i], pool[j]]);

  console.log(`\n3-hop token<->token round-trips: ${pairs.length} pairs from ${pool.length} liquid tokens`);
  // size each trade as "what 0.05 ETH bought of A", so it is meaningful per token
  const seed = pairs.map(([A]) => outs[toks.findIndex(t => (t.symbol || t.sym) === A)] / 20n);
  // per=1: the 3-hop builder prices three legs across every venue and encodes a
  // multicall, which reliably exhausts a shared eth_call budget. Batching it only
  // bought 120 wasted calls before the retry pass redid them one at a time.
  const fwd3 = await batchQuotes(pairs.map(([A, B], k) =>
    ({ to: QUOTER, data: hop3Data(byS[A], byS[B], seed[k]) })), block, 1);
  const back3 = await batchQuotes(pairs.map(([A, B], k) =>
    ({ to: QUOTER, data: hop3Data(byS[B], byS[A], out3(fwd3[k])) })), block, 1);

  let ok3 = 0, dead3 = 0; const bug3 = [], arb3 = [];
  for (let k = 0; k < pairs.length; k++) {
    const back = out3(back3[k]);
    if (!seed[k] || !out3(fwd3[k]) || !back) { dead3++; continue; }
    const ret = Number(back * 10000n / seed[k]) / 10000;
    const vf = ven3(fwd3[k]), vb = ven3(back3[k]);
    const tag = `${pairs[k][0]}->${pairs[k][1]} ${(ret * 100).toFixed(2)}%`;
    if (ret > 1.0) (isMirror(routeOf(fwd3[k], 3), routeOf(back3[k], 3)) ? bug3 : arb3)
      .push(tag + ` (${VENUES[vf]}/${VENUES[vb]})`);
    else ok3++;
  }
  console.log(`  round-tripped        : ${ok3}`);
  console.log(`  no route             : ${dead3}`);
  console.log(`  cross-venue arb      : ${arb3.length}${arb3.length ? '  ' + arb3.slice(0, 5).join(', ') : ''}`);
  console.log(`  SAME-VENUE >100% (BUG): ${bug3.length}${bug3.length ? '  ' + bug3.slice(0, 5).join(', ') : ''}`);
  if (bug3.length) { console.log('\nFAIL: a 3-hop pair beat itself on the same venue.'); process.exit(1); }
}

console.log('\nOK: no same-venue disagreement.');
