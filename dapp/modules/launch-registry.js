// ---- PrecisionLauncher launch registry (indexer-free) ----
// Every coin launched through /coin is enumerable from the launcher itself, so
// the token list is one `eth_call` rather than a log scan:
//
//   PrecisionLauncherLens.launches(start, count) -> LaunchInfo[]
//
// This REPLACED curve-registry.js, which had to walk ~17 chunked `eth_getLogs`
// windows across three ranked nodes because ClassicalCurveSale kept no index.
// The launcher's factory does, so none of that machinery is needed here.
//
// LaunchInfo arrives with names, symbols, supplies and both prices already in
// it, so a gallery needs no follow-up reads. `contractURI` is the one field the
// enumerating views leave empty — deliberately, since an on-chain image makes it
// a ~44 KB inline document and one creator could price a whole page out of being
// callable. Read it per token with `infoFor` on a detail view.
//
// Dependency-free (raw JSON-RPC over fetch) so pages that don't bundle ethers
// can use it.
(function () {
  const LAUNCHER = "0x0000002fC8E77585A008Aa45d78A71ad36293aEe";
  const LENS = "0x00000041201F1542EE49F9722b2590DEDFE4296B";

  const SEL_COUNT = "0x27cca59f";      // launchCount()
  const SEL_LAUNCHES = "0x90166851";   // launches(uint256,uint256)
  const SEL_INFO_FOR = "0xd7455eb6";   // infoFor(address)

  // Newest-first, and capped: a page shows a grid, not an archive.
  const PAGE = 50;
  const MAX = 300;

  const NODES = [
    "https://rpc.mevblocker.io",
    "https://gateway.tenderly.co/public/mainnet",
    "https://eth.drpc.org"
  ];

  const CACHE_KEY = "zfi_launches_v1";
  const CACHE_TTL = 60 * 1000;

  // Addresses this browser just launched. Two things would otherwise hide a
  // fresh coin: the cache, and public RPCs lagging a block behind the launch tx.
  // Both resolve on their own, so entries here are a bridge and expire.
  const RECENT_KEY = "zfi_launches_recent_v1";
  const RECENT_TTL = 60 * 60 * 1000;

  async function rpc(method, params) {
    let lastErr;
    for (const url of NODES) {
      const ctrl = new AbortController();
      const t = setTimeout(() => ctrl.abort(), 15000);
      try {
        const res = await fetch(url, {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }),
          signal: ctrl.signal
        });
        const json = await res.json();
        if (json.error) throw new Error(json.error.message || "rpc error");
        return json.result;
      } catch (e) { lastErr = e; } finally { clearTimeout(t); }
    }
    throw lastErr || new Error("no RPC reachable");
  }

  const call = (to, data) => rpc("eth_call", [{ to, data }, "latest"]);
  const strip = h => (h || "").replace(/^0x/, "");
  const word = (h, i) => h.slice(i * 64, i * 64 + 64);
  const num = w => BigInt("0x" + (w || "0"));
  const addr = w => "0x" + (w || "").slice(24).toLowerCase();
  const enc = n => BigInt(n).toString(16).padStart(64, "0");

  // ABI string at byte offset `off` within `h`.
  function str(h, off) {
    const i = Number(off) * 2;
    const len = Number(num(h.slice(i, i + 64)));
    const bytes = h.slice(i + 64, i + 64 + len * 2);
    let s = "";
    for (let k = 0; k < bytes.length; k += 2) s += "%" + bytes.slice(k, k + 2);
    try { return decodeURIComponent(s); } catch { return ""; }
  }

  // LaunchInfo, in declaration order. The four addresses and the three string
  // offsets come first, then twelve uint256s — see PrecisionLauncherLens.
  function decodeInfo(h, base) {
    const w = i => word(h, base + i);
    const o = i => base * 32 + Number(num(w(i)));
    return {
      token: addr(w(0)),
      pool: addr(w(1)),
      creator: addr(w(2)),
      owner: addr(w(3)),
      name: str(h, o(4)),
      symbol: str(h, o(5)),
      contractURI: str(h, o(6)),
      totalSupply: num(w(7)),
      circulating: num(w(8)),
      backingEth: num(w(9)),
      floorPrice: num(w(10)),
      marketPrice: num(w(11)),
      reserve0: num(w(12)),
      reserve1: num(w(13)),
      lpHeld: num(w(14)),
      allocBps: num(w(15)),
      fullyDilutedWei: num(w(16)),
      pendingFeeEth: num(w(17)),
      pendingBurn: num(w(18))
    };
  }

  // Decode `LaunchInfo[]`, oldest-first as the lens returns it.
  function decodeArray(raw) {
    const h = strip(raw);
    if (h.length < 128) return [];
    const arrAt = Number(num(word(h, 0))) * 2;
    const n = Number(num(h.slice(arrAt, arrAt + 64)));
    const headAt = arrAt / 64 + 1;
    const out = [];
    for (let i = 0; i < n; i++) {
      const elemOff = Number(num(word(h, headAt + i)));
      out.push(decodeInfo(h, headAt + elemOff / 32));
    }
    return out;
  }

  function readRecent() {
    try {
      const list = JSON.parse(sessionStorage.getItem(RECENT_KEY) || "[]");
      if (!Array.isArray(list)) return [];
      return list.filter(e => e && typeof e.addr === "string" && Date.now() - (e.at || 0) < RECENT_TTL);
    } catch { return []; }
  }

  // Record a launch so it shows up immediately. Safe to call twice.
  function note(a) {
    if (typeof a !== "string" || !/^0x[0-9a-fA-F]{40}$/.test(a)) return;
    const low = a.toLowerCase();
    try {
      const list = readRecent().filter(e => e.addr !== low);
      list.unshift({ addr: low, at: Date.now() });
      sessionStorage.setItem(RECENT_KEY, JSON.stringify(list.slice(0, 50)));
    } catch {}
  }

  function readCache() {
    try {
      const c = JSON.parse(sessionStorage.getItem(CACHE_KEY) || "null");
      if (!c || !Array.isArray(c.rows)) return null;
      if (Date.now() - (c.at || 0) > CACHE_TTL) return null;
      // Bigints don't survive JSON, so they are cached as decimal strings.
      return c.rows.map(r => {
        const o = { ...r };
        for (const k in o) if (typeof o[k] === "string" && /^\d+$/.test(o[k]) && k !== "name" && k !== "symbol") o[k] = BigInt(o[k]);
        return o;
      });
    } catch { return null; }
  }

  function writeCache(rows) {
    try {
      const plain = rows.map(r => {
        const o = {};
        for (const k in r) o[k] = typeof r[k] === "bigint" ? r[k].toString() : r[k];
        return o;
      });
      sessionStorage.setItem(CACHE_KEY, JSON.stringify({ at: Date.now(), rows: plain }));
    } catch {}
  }

  let _inflight = null;

  async function scan() {
    const total = Number(num(strip(await call(LENS, SEL_COUNT))));
    if (!total) return [];
    const want = Math.min(total, MAX);
    const rows = [];
    // Newest first: walk backwards from the end of the launcher's list.
    for (let end = total; end > total - want; ) {
      const count = Math.min(PAGE, end - (total - want));
      const start = end - count;
      const page = decodeArray(await call(LENS, SEL_LAUNCHES + enc(start) + enc(count)));
      rows.push(...page.reverse());
      end = start;
    }
    return rows;
  }

  // Newest-first LaunchInfo rows. Concurrent callers share one scan; repeat
  // calls within CACHE_TTL are served from sessionStorage.
  async function launches(opts) {
    if (!(opts && opts.force)) {
      const cached = readCache();
      if (cached) return cached;
    }
    if (_inflight) return _inflight;
    _inflight = (async () => {
      try {
        const rows = await scan();
        writeCache(rows);
        return rows;
      } catch (e) {
        console.warn("launch-registry: scan failed", e);
        return [];
      } finally { _inflight = null; }
    })();
    return _inflight;
  }

  // Newest-first lowercase token addresses, freshly launched ones first.
  async function tokens(opts) {
    const list = (await launches(opts)).map(r => r.token);
    const seen = new Set(list);
    const head = readRecent().map(e => e.addr).filter(a => !seen.has(a));
    return head.length ? head.concat(list) : list;
  }

  // One launch, with `contractURI` populated — the detail-view read.
  async function infoFor(token) {
    if (!/^0x[0-9a-fA-F]{40}$/.test(token || "")) return null;
    try {
      const h = strip(await call(LENS, SEL_INFO_FOR + enc(BigInt(token))));
      if (h.length < 64) return null;
      const at = Number(num(word(h, 0))) / 32;
      const info = decodeInfo(h, at);
      return /^0x0{40}$/.test(info.token) ? null : info;
    } catch { return null; }
  }

  window.launchRegistry = { launches, tokens, infoFor, note, LAUNCHER, LENS };
})();
