#!/usr/bin/env node
/**
 * Build a self-contained, runnable preview of zSwap.html.
 *
 * This is NOT a mockup. It takes the real page, byte for byte, and injects a
 * simulated EIP-1193 provider ahead of it — the same idea as test/ui/harness.mjs,
 * but in the browser. Everything you click is the shipped code path; only the
 * chain underneath is fixture data. If the preview looks right, the dapp is
 * right, because there is no second implementation to drift.
 *
 * The one edit to the page is PPLENS, which ships as the zero address until the
 * lens is deployed. The preview points it at the simulated lens so the price
 * tape has something to read.
 *
 * Usage: node script/build-zSwap-preview.mjs [out.html]
 */
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const OUT = process.argv[2] || path.join(ROOT, 'dapp', 'preview', 'index.html');

const LENS = '0x4444444444444444444444444444444444444444';

let page = fs.readFileSync(path.join(ROOT, 'zSwap.html'), 'utf8');

// The real zList registry, captured from mainnet into script/fixtures. It is
// emitted as its own JSON script block rather than embedded in the mock, and
// that is deliberate: the mock is a template literal, so a backtick or a
// dollar-brace anywhere inside a logo data URI would close it and break the
// build somewhere unrelated. JSON in a script tag only has to avoid `</script`.
const REGISTRY = fs.readFileSync(path.join(ROOT, 'script', 'fixtures', 'tokenlist.json'), 'utf8')
  .replace(/<\/script/gi, '<\\/script');

// Strip the document-level tags: the preview supplies its own shell.
page = page
  .replace(/<!doctype html>\s*/i, '')
  .replace(/<meta[^>]*>\s*/gi, '')
  .replace(/<title>[\s\S]*?<\/title>\s*/i, '')
  .replace(/<link rel="icon"[^>]*>\s*/i, '');

// The fixture has to answer for whatever board the page actually asks about.
// It used to hardcode one address, and that address was the pre-deploy
// PREDICTION - so once the page was repointed at the real Swapboard the book
// lens fell through to emptyBook() and the Orders tab rendered blank, which
// reads as "no liquidity" rather than "the preview is stale". Read the
// constants out of the page so the two cannot drift again.
function pageConst(name) {
  const m = page.match(new RegExp(name + '="(0x[0-9a-fA-F]{40})"'));
  if (!m) throw Error(`preview cannot find ${name} in zSwap.html`);
  return m[1].toLowerCase();
}
const SB2_ADDR = pageConst('SB2');
const DUTCH_ADDR = pageConst('DUTCH');

const before = page;
page = page.replace(
  'const PPLENS="0x0000000000000000000000000000000000000000"',
  `const PPLENS="${LENS}"`,
);
if (page === before) throw Error('PPLENS constant not found — the preview would show no chart');

// Point every provider reference at the simulation. A wallet extension installs
// window.ethereum as a non-writable property, so simply assigning our own is
// silently ignored and the preview ends up driving the visitor's real wallet
// against mainnet. Rebinding the name is the only reliable way to win.
const providerRefs = (page.match(/window\.ethereum/g) || []).length;
if (providerRefs === 0) throw Error('no window.ethereum references — provider rebinding is stale');
page = page.split('window.ethereum').join('window.__PREVIEW');
console.log(`rebound ${providerRefs} provider reference(s) to the simulation`);

const MOCK = ((SB2, DUTCH) => String.raw`
<script>
/**
 * Simulated chain for the zSwap preview.
 *
 * Answers the same JSON-RPC the page asks a wallet for, out of fixture state.
 * No network, no keys, nothing to install.
 */
(function () {
  "use strict";
  var ZERO = "0x" + "0".repeat(40);
  var A = {
    ACCOUNT: "0x1111111111111111111111111111111111111111",
    MC3: "0xca11bde05977b3631167028862be2a173976ca11",
    ZQUOTER: "0x0000002d9a651b729e3afbe57fc84ffda4a98a13",
    ZROUTER: "0x000000000000fb114709235f1ccbffb925f600e4",
    LENS: "${LENS}",
    SLOW: "0x000000000000888741b254d37e1b27128afeaabc",
    WETH: "0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2",
    USDC: "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48",
    USDT: "0xdac17f958d2ee523a2206206994597c13d831ec7",
    WBTC: "0x2260fac5e5542a773aa44fbcfedf7c193bc2c599",
    WSTETH: "0x7f39c581f595b53c5cb19bd0b3f8da6c935e2ca0"
  };

  /* ---- abi helpers ---- */
  function pad(h) { h = h.replace(/^0x/, ""); return "0".repeat(64 - h.length) + h; }
  function u256(v) { return pad(BigInt(v).toString(16)); }
  function addrw(a) { return pad(a.toLowerCase().replace(/^0x/, "")); }
  function word(h, i) { return BigInt("0x" + h.slice(i * 64, (i + 1) * 64)); }
  function wordAddr(h, i) { return "0x" + h.slice(i * 64 + 24, (i + 1) * 64); }
  function strip(h) { return (h || "").replace(/^0x/, ""); }
  function bytesTail(d) {
    d = strip(d);
    return u256(d.length / 2) + d + "0".repeat(Math.ceil(d.length / 64) * 64 - d.length);
  }

  /* ---- token universe ---- */
  var TOK = {};
  TOK[A.USDC] = { sym: "USDC", dec: 6 };
  TOK[A.USDT] = { sym: "USDT", dec: 6 };
  TOK[A.WBTC] = { sym: "WBTC", dec: 8 };
  TOK[A.WETH] = { sym: "WETH", dec: 18 };
  TOK[A.WSTETH] = { sym: "wstETH", dec: 18 };

  // USD reference prices, used to price every route consistently.
  var USD = {};
  USD[ZERO] = 3120; USD[A.WETH] = 3120; USD[A.WSTETH] = 3690;
  USD[A.WBTC] = 96500; USD[A.USDC] = 1; USD[A.USDT] = 1;

  var BAL = {};
  BAL[ZERO] = 12.418e18;
  BAL[A.USDC] = 24500e6;
  BAL[A.WBTC] = 0.352e8;
  BAL[A.WSTETH] = 3.2e18;
  BAL[A.WETH] = 0.75e18;

  function decOf(a) { return a === ZERO ? 18 : (TOK[a] ? TOK[a].dec : 18); }

  /* ---- price tape fixtures ---- */
  function packFloat(v) {
    if (!(v > 0)) return 0n;
    var b = BigInt(Math.floor(v));
    var msb = BigInt(b.toString(2).length - 1);
    if (msb < 24n) return b;
    var sh = msb - 23n;
    return (sh << 24n) | (b >> sh);
  }
  function encodeBar(b) {
    if (!b) return 0n;
    return BigInt(b.bucket) | (packFloat(b.o) << 32n) | (packFloat(b.h) << 64n) |
      (packFloat(b.l) << 96n) | (packFloat(b.c) << 128n) | (packFloat(b.v) << 160n) |
      (BigInt(b.n) << 192n);
  }
  /**
   * A plausible session: a random walk with occasional idle buckets, in the
   * pool's raw token1-per-token0 units and scaled by 1e18, exactly as the
   * contract stores it.
   */
  function makeTape(seedPrice, n, seed, volScale, dec0, dec1, period) {
    period = period || 300;
    var bucket = Math.floor(Date.now() / 1000 / period), out = [], p = seedPrice;
    var s = seed;
    function rnd() { s = (s * 1103515245 + 12345) & 0x7fffffff; return s / 0x7fffffff; }
    var series = [];
    for (var i = 0; i < n; i++) {
      var o = p, drift = (rnd() - 0.487) * 0.0075;
      p = Math.max(1e-9, p * (1 + drift));
      var wick = Math.abs(drift) * (0.7 + rnd()) + 0.0012;
      series.push(rnd() < 0.14 ? null : {
        bucket: bucket - (n - 1 - i),
        // raw price = decimal-adjusted ratio, scaled 1e18
        o: o * 1e18 * Math.pow(10, dec1 - dec0),
        h: Math.max(o, p) * (1 + wick * rnd()) * 1e18 * Math.pow(10, dec1 - dec0),
        l: Math.min(o, p) * (1 - wick * rnd()) * 1e18 * Math.pow(10, dec1 - dec0),
        c: p * 1e18 * Math.pow(10, dec1 - dec0),
        v: (volScale * (0.35 + rnd())) * Math.pow(10, dec0),
        n: 1 + Math.floor(rnd() * 26)
      });
    }
    return series.reverse(); // newest first
  }

  // Pools keyed by canonical pair. Each entry: {pool, hook, liquidity, tape}.
  var POOLS = {};
  function pair(t0, t1) { return t0.toLowerCase() < t1.toLowerCase() ? [t0, t1] : [t1, t0]; }
  function addPool(t0, t1, cfg) {
    var p = pair(t0, t1), key = p[0] + ":" + p[1];
    (POOLS[key] = POOLS[key] || []).push(cfg);
  }

  // ETH/USDC: two fee tiers, both live — the chart aggregates them.
  addPool(ZERO, A.USDC, { pool: "0xaa01" + "0".repeat(36), hook: ZERO, liq: 8.2e24,
    tape: makeTape(3120, 180, 11, 40, 18, 6), seed: 3120, d0: 18, d1: 6 });
  addPool(ZERO, A.USDC, { pool: "0xaa02" + "0".repeat(36), hook: ZERO, liq: 2.1e24,
    tape: makeTape(3121, 180, 29, 11, 18, 6), seed: 3121, d0: 18, d1: 6 });
  // A hooked pool on the same pair: discovered, then deliberately excluded.
  addPool(ZERO, A.USDC, { pool: "0xaa03" + "0".repeat(36),
    hook: "0x9999999999999999999999999999999999999999", liq: 5e23,
    tape: makeTape(2980, 180, 77, 9, 18, 6), seed: 2980, d0: 18, d1: 6 });

  addPool(A.WBTC, A.USDC, { pool: "0xbb01" + "0".repeat(36), hook: ZERO, liq: 4.4e23,
    tape: makeTape(96500, 180, 5, 0.6, 8, 6), seed: 96500, d0: 8, d1: 6 });
  addPool(ZERO, A.WSTETH, { pool: "0xcc01" + "0".repeat(36), hook: ZERO, liq: 3.1e24,
    tape: makeTape(0.846, 180, 91, 30, 18, 18), seed: 0.846, d0: 18, d1: 18 });
  addPool(ZERO, A.WETH, { pool: "0xdd01" + "0".repeat(36), hook: ZERO, liq: 9e23,
    tape: makeTape(1, 180, 3, 25, 18, 18), seed: 1, d0: 18, d1: 18 });
  // A pair with a pool but no trades: the drawer must not appear.
  addPool(A.USDC, A.USDT, { pool: "0xee01" + "0".repeat(36), hook: ZERO, liq: 6e23, tape: [] });

  var TAPE_BY_POOL = {}, COARSE_BY_POOL = {};
  Object.keys(POOLS).forEach(function (k) {
    POOLS[k].forEach(function (p, i) {
      TAPE_BY_POOL[p.pool.toLowerCase()] = p.tape;
      // The four-hour ring holds weeks the five-minute ring never could, so the
      // preview gives it its own longer history rather than a rolled-up stub.
      COARSE_BY_POOL[p.pool.toLowerCase()] = p.tape.length
        ? makeTape(p.seed || 3000, 120, 700 + i, 48, p.d0 || 18, p.d1 || 6, 14400)
        : [];
    });
  });

  /* ---- quoter ---- */
  // Head is (u/4 + 1) legs of {source,feeBps,amountIn,amountOut}, then an offset
  // to a hops array, an offset to callData, then msgValue.
  function encodeQuote(u, legs, callData, msgValue) {
    var nLegs = u / 4 + 1, headWords = 4 * nLegs + 3;
    var arrOff = headWords * 32, bytesOff = arrOff + 32 + 32, head = "";
    for (var i = 0; i < nLegs; i++) {
      var l = legs[i];
      head += u256(l ? l.source : 0) + u256(l ? l.fee : 0) +
        u256(l ? l.amountIn : 0) + u256(l ? l.amountOut : 0);
    }
    head += u256(arrOff) + u256(bytesOff) + u256(msgValue);
    return "0x" + head + u256(1) + u256(1) + bytesTail(callData);
  }
  function quote(sel, data) {
    if (sel !== "e453166e" && sel !== "4c464f59") return null;   // split builders "revert"
    var u = sel === "e453166e" ? 4 : 8, base = sel === "e453166e" ? 2 : 1;
    var h = strip(data).slice(8);
    var exactOut = word(h, base) === 1n;
    var tIn = wordAddr(h, base + 1), tOut = wordAddr(h, base + 2);
    var amount = word(h, base + 3);
    if (amount === 0n) return null;
    var pin = USD[tIn], pout = USD[tOut];
    if (!pin || !pout) return null;
    var din = decOf(tIn), dout = decOf(tOut);
    var human = Number(amount) / Math.pow(10, exactOut ? dout : din);
    // A gentle concave impact so large sizes visibly cost more.
    var notional = human * (exactOut ? pout : pin);
    var slip = 1 - Math.min(0.35, notional / 90e6);
    var aIn, aOut;
    if (exactOut) {
      aOut = amount;
      aIn = BigInt(Math.floor((human * pout / pin / slip) * Math.pow(10, din)));
    } else {
      aIn = amount;
      aOut = BigInt(Math.floor((human * pin / pout * slip) * Math.pow(10, dout)));
    }
    if (aIn <= 0n || aOut <= 0n) return null;
    return encodeQuote(u, [{ source: 3, fee: 30n, amountIn: aIn, amountOut: aOut }],
      "0xac9650d8" + u256(32) + u256(0), tIn === ZERO ? aIn : 0n);
  }

  /* ---- call routing ---- */
  function ethCall(tx) {
    var to = (tx.to || "").toLowerCase(), data = strip(tx.data || ""), sel = data.slice(0, 8);
    if (!data) return "0x";
    if (to === A.MC3 && sel === "82ad56cb") return aggregate3(data);
    if (to === A.ZQUOTER) { var q = quote(sel, tx.data); if (!q) throw Error("no route"); return q; }
    if (to === A.LENS.toLowerCase() && sel === "29c21083") return markets(data);
    if (sel === "29a65241") return tape(to, data);
    if (to === A.ZROUTER) return "0x";
    if (to === A.SLOW) return slow(sel, data);
    // Recent-orders lens for the current Swapboard: the book the Orders tab lists.
    if (sel === "6a9849c1") {
      var board = wordAddr(data.slice(8), 0);
      return board === "${SB2}" ? bookPage(BOOK, board) : emptyBook();
    }
    if (sel === "5f452988" || sel === "eb33e466" || sel === "98035c9a") return emptyBook();
    // The curated list, served exactly as mainnet returns it - real symbols,
    // real logos, and the two real ERC-721 collections. Falling through instead
    // would make loadTokenList fail and the page would show its built-in list,
    // which has no collections in it at all.
    if (sel === "df7ca268") {
      var body = u256(32) + u256(REG.length);
      REG.forEach(function (r) { body += u256(BigInt(r.id)); });
      return "0x" + body;
    }
    if (sel === "74e18e96") {
      var want = BigInt("0x" + data.slice(8, 72)).toString();
      var hit = REG.filter(function (r) { return r.id === want; })[0];
      return encStr(hit ? hit.json : "");
    }
    // One collection-wide floor bid: anyId true, empty ids. This is the row
    // a blank Token ID resolves to, and the only kind SwapboardView could not
    // have represented.
    if (sel === "16bb24eb") return collectionBid();
    if (sel === "2a58b330") return "0x" + u256(0);
    // Name services: nothing is registered here, so every lookup resolves to
    // the zero address and the page falls back to the hex address.
    if (sel === "0178b8bf" || sel === "3b3b57de" || sel === "4f896d4f") return "0x" + addrw(ZERO);
    if (sel === "fb021939") return "0x" + u256(0);
    if (sel === "9af8b7aa" || sel === "691f3431") return encStr("");
    return erc20(to, sel, data);
  }
  function aggregate3(data) {
    var h = data.slice(8), n = Number(word(h, 1)), out = [];
    for (var i = 0; i < n; i++) {
      var off = Number(word(h, 2 + i)) / 32;
      var target = wordAddr(h, 2 + off);
      var dOff = Number(word(h, 2 + off + 2)) / 32;
      var dLen = Number(word(h, 2 + off + dOff));
      var payload = "0x" + h.slice((2 + off + dOff + 1) * 64, (2 + off + dOff + 1) * 64 + dLen * 2);
      var ok = true, ret = "0x";
      try { ret = ethCall({ to: target, data: payload }); } catch (e) { ok = false; ret = "0x"; }
      out.push({ ok: ok, ret: ret });
    }
    var head = "", tail = "", cursor = n * 32;
    out.forEach(function (r) {
      var body = u256(r.ok ? 1 : 0) + u256(64) + bytesTail(r.ret);
      head += u256(cursor); tail += body; cursor += body.length / 2;
    });
    return "0x" + u256(32) + u256(n) + head + tail;
  }
  function markets(data) {
    var h = data.slice(8);
    var key = wordAddr(h, 0) + ":" + wordAddr(h, 1);
    var rows = POOLS[key] || [];
    var head = "", W = 18;
    rows.forEach(function (r) {
      var w = new Array(W).fill(null).map(function () { return u256(0); });
      w[0] = addrw(r.pool); w[9] = u256(BigInt(Math.floor(r.liq))); w[10] = addrw(r.hook);
      head += w.join("");
    });
    return "0x" + u256(32) + u256(rows.length) + head;
  }
  function tape(pool, data) {
    var period = Number(word(data.slice(8), 0));
    var bars = period === 300 ? (TAPE_BY_POOL[pool] || []) : (COARSE_BY_POOL[pool] || []);
    var count = Number(word(data.slice(8), 1));
    var take = bars.slice(0, count);
    return "0x" + u256(32) + u256(take.length) +
      take.map(function (b) { return u256(encodeBar(b)); }).join("");
  }
  // An orderbook page: [offset][next cursor][array]. Empty is a different thing
  // from "books offline", so this must encode properly rather than revert.
  function emptyBook() { return "0x" + u256(64) + u256(0) + u256(0); }

  // A handful of resting limit orders, so the Orders tab has something to show.
  // OrderView is 16 fields with two dynamic strings, so each row is encoded as
  // a tail the page's decViewPage walks by offset.
  var BOOK = [
    { id: 41, maker: "0x2222222222222222222222222222222222222222", pf: true,
      tA: A.USDC, aA: 5200e6, sA: "USDC", dA: 6, tB: ZERO, aB: 1.6e18, sB: "WETH", dB: 18 },
    { id: 38, maker: "0x3333333333333333333333333333333333333333", pf: false,
      tA: A.USDC, aA: 12500e6, sA: "USDC", dA: 6, tB: ZERO, aB: 4e18, sB: "WETH", dB: 18 },
    { id: 31, maker: "0x1111111111111111111111111111111111111111", pf: true,
      tA: ZERO, aA: 2.5e18, sA: "WETH", dA: 18, tB: A.USDC, aB: 7900e6, sB: "USDC", dB: 6 },
    { id: 27, maker: "0x4444444444444444444444444444444444444444", pf: true,
      tA: A.WBTC, aA: 0.12e8, sA: "WBTC", dA: 8, tB: A.USDC, aB: 11600e6, sB: "USDC", dB: 6 }
  ];
  function encStrTail(s) {
    var hex = "";
    for (var i = 0; i < s.length; i++) hex += s.charCodeAt(i).toString(16).padStart(2, "0");
    return u256(s.length) + (hex + "0".repeat(Math.ceil(hex.length / 64) * 64 - hex.length));
  }
  var REG = (function () {
    try { return JSON.parse(document.getElementById("pv-registry").textContent); }
    catch (e) { return []; }
  })();

  // zOrgz, a REAL ERC-721 in the registry - not an invented collection.
  var NFTCOL = "0x00000000008835cef3e0d2333695f288ee6b63a6";

  // (BidRow[] rows, uint256 nextCursor). BidRow holds dynamic members, so the
  // array element is itself offset-encoded: the head is a POINTER to the row.
  function collectionBid() {
    var row = ""
      + u256(1)                       // bidId
      + addrw(A.ACCOUNT)              // bidder
      + addrw(NFTCOL)                 // token  - what a seller delivers
      + addrw(A.USDC)                 // quote  - what a seller receives
      + u256(1)                       // isNFT
      + u256(1)                       // anyId  <- the point
      + u256(17 * 32)                 // ids offset, relative to the row
      + u256(2)                       // remaining (a COUNT on an NFT bid)
      + u256(2)                       // initial
      + u256(4000000000n)             // price, 4000 USDC for both
      + u256(4000000000n)             // proceedsForRemaining
      + u256(0) + u256(0)             // startTime, expiry
      + u256(0) + u256(7)             // tokenDecimals, quoteDecimals (6 + 1)
      + u256(17 * 32 + 32)            // tokenSymbol offset
      + u256(17 * 32 + 32 + 64)       // quoteSymbol offset
      + u256(0)                       // ids: empty = ANY id
      + u256(3) + "7a7a7a".padEnd(64, "0")     // "zzz" (zOrgz)
      + u256(4) + "55534443".padEnd(64, "0");  // "USDC"
    return "0x" + u256(64) + u256(0) + u256(1) + u256(32) + row;
  }

  function bookPage(rows, board) {
    // Each row: 16 head words (two of them offsets to the symbol strings).
    var heads = [], tails = [];
    rows.forEach(function (r) {
      var sA = encStrTail(r.sA), sB = encStrTail(r.sB);
      var offA = 16 * 32, offB = offA + sA.length / 2;
      var h = u256(r.id) + addrw(r.maker) + u256(r.pf ? 1 : 0) + u256(0) +
        u256(0) + u256(0) + addrw(ZERO) +
        addrw(r.tA) + u256(BigInt(Math.floor(r.aA))) + u256(offA) + u256(r.dA) +
        addrw(r.tB) + u256(BigInt(Math.floor(r.aB))) + u256(offB) + u256(r.dB) +
        addrw(board);
      heads.push(h + sA + sB);
    });
    var n = heads.length, off = n * 32, arrHead = "", arrTail = "";
    heads.forEach(function (h) { arrHead += u256(off); arrTail += h; off += h.length / 2; });
    var arr = u256(n) + arrHead + arrTail;
    return "0x" + u256(64) + u256(0) + arr;
  }
  function slow(sel, data) {
    if (sel === "d40d4bc6" || sel === "e3993ee7") return "0x" + u256(32) + u256(0);
    return "0x";
  }
  function encStr(s) {
    var hex = "";
    for (var i = 0; i < s.length; i++) hex += s.charCodeAt(i).toString(16).padStart(2, "0");
    return "0x" + u256(32) + u256(s.length) + hex + "0".repeat(Math.ceil(hex.length / 64) * 64 - hex.length);
  }
  function erc20(to, sel, data) {
    var t = TOK[to];
    if (sel === "70a08231") return "0x" + u256(BigInt(Math.floor(BAL[to] || 0)));
    if (sel === "dd62ed3e") return "0x" + u256(BigInt("0x" + "f".repeat(60)));  // pre-approved
    if (sel === "95d89b41") { if (!t) throw Error("no symbol"); return encStr(t.sym); }
    if (sel === "313ce567") { if (!t) throw Error("no decimals"); return "0x" + u256(t.dec); }
    if (sel === "06fdde03") { if (!t) throw Error("no name"); return encStr(t.sym); }
    if (sel === "3644e515") throw Error("no permit");
    if (sel === "7ecebe00") return "0x" + u256(0);
    throw Error("unhandled " + sel);
  }

  /* ---- provider ---- */
  var connected = true, txn = 0;   // preview boots connected, so the UI is populated
  var listeners = {};
  var provider = {
    isPreview: true,
    on: function (ev, cb) { listeners[ev] = cb; },
    request: function (a) {
      var m = a.method, p = a.params || [];
      return new Promise(function (resolve, reject) {
        setTimeout(function () {
          try {
            switch (m) {
              case "eth_chainId": return resolve("0x1");
              case "eth_accounts": return resolve(connected ? [A.ACCOUNT] : []);
              case "eth_requestAccounts": connected = true; return resolve([A.ACCOUNT]);
              case "eth_blockNumber": return resolve("0x14a1b2c");
              case "eth_gasPrice": return resolve("0x" + (8e9).toString(16));
              case "eth_getBalance": return resolve("0x" + BigInt(Math.floor(BAL[ZERO])).toString(16));
              case "eth_getCode":
                // Everything the page probes for exists in this simulation.
                return resolve("0x60006000");
              case "eth_call": return resolve(ethCall(p[0]));
              case "eth_sendTransaction":
                return resolve("0x" + (++txn).toString(16).padStart(64, "0"));
              case "eth_getTransactionReceipt":
                return resolve({ status: "0x1", transactionHash: p[0] });
              case "eth_signTypedData_v4":
                return resolve("0x" + "11".repeat(32) + "22".repeat(32) + "1b");
              case "wallet_getCapabilities": return reject(new Error("unsupported"));
              case "wallet_switchEthereumChain": return resolve(null);
              default: return reject(new Error("preview: unhandled " + m));
            }
          } catch (e) { reject(e); }
        }, 40);   // a little latency, so loading states are real
      });
    }
  };

  // The page is built to read window.__PREVIEW, so an installed wallet cannot
  // take the preview over. Setting window.ethereum too is best-effort only.
  window.__PREVIEW = provider;
  try {
    Object.defineProperty(window, "ethereum", {
      value: provider, writable: true, configurable: true
    });
  } catch (e) { /* a locked wallet property is fine: nothing reads it here */ }

  // Open the chart by default, and clear any "disconnected" flag so the preview
  // always boots in its populated state.
  try { localStorage.setItem("ch", "1"); sessionStorage.removeItem("dc"); } catch (e) {}
})();
</script>
`)(SB2_ADDR, DUTCH_ADDR);

const GALLERY = String.raw`
<h2 class="pv-h2">Precision pool charts</h2>
<div class="pv-gallery" id="pvGallery"></div>
<script>
/**
 * Renders the drawer for several pairs and captures each one, so the design can
 * be seen across markets at a glance. It drives the page's real controls and
 * copies the page's real output — there is no second renderer to drift.
 */
(function () {
  // The fourth field is the note the drawer writes once THIS pair has loaded.
  // Capturing on "an svg exists" would photograph the previous pair, because the
  // re-read is asynchronous and the old chart stays up until it lands.
  var PAIRS = [
    ["ETH", "USDC", "Deep market, two pools aggregated", "USDC per ETH"],
    ["WBTC", "USDC", "Higher unit price, wider candles", "USDC per WBTC"],
    ["ETH", "wstETH", "Correlated pair, tight range", "wstETH per ETH"]
  ];
  function wait(fn, ms) {
    return new Promise(function (res) {
      var t = Date.now();
      (function loop() {
        try { if (fn()) return res(true); } catch (e) {}
        if (Date.now() - t > ms) return res(false);
        setTimeout(loop, 30);
      })();
    });
  }
  function pick(sel, sym) {
    var o = null;
    for (var i = 0; i < sel.options.length; i++) {
      if (sel.options[i].textContent === sym) { o = sel.options[i]; break; }
    }
    if (!o || o.disabled) return false;
    sel.value = o.value;
    sel.dispatchEvent(new Event("change", { bubbles: true }));
    return true;
  }
  function card(a, b, note, svg, caption) {
    var d = document.createElement("figure");
    d.className = "pv-card";
    d.innerHTML = '<figcaption><b>' + a + " / " + b + "</b><span>" + caption + "</span></figcaption>" +
      '<div class="pv-chart">' + svg + "</div>" +
      '<div class="pv-note-line">' + note + "</div>";
    return d;
  }
  (async function () {
    var g = document.getElementById("pvGallery");
    await wait(function () { return document.getElementById("chArt"); }, 8000);
    try { chOpen = true; } catch (e) {}          // in case storage is unavailable
    await wait(function () { return typeof account !== "undefined" && account; }, 8000);

    for (var i = 0; i < PAIRS.length; i++) {
      var a = PAIRS[i][0], b = PAIRS[i][1], caption = PAIRS[i][2], expect = PAIRS[i][3];
      // Set the side that is free first, so the pair never collides.
      pick(document.getElementById("toSel"), b) || pick(document.getElementById("fromSel"), a);
      pick(document.getElementById("fromSel"), a);
      pick(document.getElementById("toSel"), b);
      var ok = await wait(function () {
        var el = document.getElementById("chArt");
        var note = document.getElementById("chNote").textContent;
        return el && el.querySelector("svg") && note.indexOf(expect) === 0;
      }, 8000);
      var art = document.getElementById("chArt");
      g.appendChild(card(a, b, document.getElementById("chNote").textContent,
        ok ? art.innerHTML : '<div style="padding:2em;text-align:center;opacity:.6">no data</div>',
        caption));
    }
    // Leave the live tile on the pair it started with.
    pick(document.getElementById("fromSel"), "ETH");
    pick(document.getElementById("toSel"), "USDC");
  })();
})();
</script>
`;

const SHELL = `<title>zSwap — live preview</title>
<style>
.pv-note{
  max-width:22em;margin:0 auto 1em;padding:.7em .85em;
  border:1px solid var(--e);border-radius:.5em;background:var(--c);
  font:600 .65em/1.6 system-ui,sans-serif;letter-spacing:.06em;text-transform:uppercase;
  color:var(--n);text-align:center;box-sizing:border-box;
}
.pv-note b{display:block;color:var(--f);font-size:1.15em;letter-spacing:.08em;margin-bottom:.2em}
.pv-note span{display:block;text-transform:none;letter-spacing:0;font-weight:400;font-size:1.05em;margin-top:.4em}
.pv-h2{max-width:46em;margin:2.4em auto .9em;font:700 .68em/1 system-ui,sans-serif;
  letter-spacing:.16em;text-transform:uppercase;color:var(--n);
  border-bottom:1px solid var(--e);padding-bottom:.7em}
.pv-gallery{max-width:46em;margin:0 auto;display:grid;gap:1em;
  grid-template-columns:repeat(auto-fit,minmax(19em,1fr))}
.pv-card{margin:0;border:1px solid var(--e);border-radius:.5em;background:var(--c);
  padding:.8em;box-shadow:var(--s)}
.pv-card figcaption{display:flex;flex-direction:column;gap:.15em;margin-bottom:.6em}
.pv-card figcaption b{font:600 .82em/1.3 system-ui,sans-serif;color:var(--f);letter-spacing:.02em}
.pv-card figcaption span{font:400 .68em/1.4 system-ui,sans-serif;color:var(--m)}
.pv-chart{position:relative;border:1px solid var(--e);border-radius:.45em;overflow:hidden;background:var(--p)}
.pv-chart svg{display:block;width:100%;height:auto}
.pv-chart .hd{position:absolute;top:.4em;left:.55em;font:400 .7em/1.4 system-ui,sans-serif;
  color:var(--m);font-variant-numeric:tabular-nums;pointer-events:none}
.pv-chart .hd b{color:var(--f);font-size:1.25em;font-weight:600}
.pv-note-line{font:400 .65em/1.5 system-ui,sans-serif;color:var(--m);
  margin-top:.4em;text-align:right;font-variant-numeric:tabular-nums}
</style>
<div class="pv-note">
  <b>Simulated</b>
  The real zSwap page, running against a fake chain.
  <span>Balances, routes and candles are fixtures — no wallet, no network. Connect, quote, switch tabs and open the chart as you would on mainnet.</span>
</div>
<script type="application/json" id="pv-registry">${REGISTRY}</script>
${MOCK}
${page}
${GALLERY}`;

fs.mkdirSync(path.dirname(OUT), { recursive: true });
fs.writeFileSync(OUT, SHELL);
console.log(`preview -> ${path.relative(ROOT, OUT)} (${SHELL.length.toLocaleString('en-US')} B)`);
