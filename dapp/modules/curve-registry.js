// ---- ClassicalCurveSale launch registry (indexer-free) ----
// Curve launches announce themselves on-chain, so the token list is rebuilt from
// the sale contract's own logs instead of an off-chain database:
//   event Configured(address indexed creator, address indexed token, uint256 cap,
//                    uint256 startPrice, uint256 endPrice,
//                    uint256 graduationTarget, uint256 lpTokens)
//
// Covering all history needs ~17 chunked eth_getLogs calls on the widest public
// node, so the result is cached in sessionStorage and shared across pages.
// Dependency-free (raw JSON-RPC over fetch) so pages that don't bundle ethers can use it.
(function () {
  const CURVE_SALE = "0x000000005d9b18764E12E5aeefD6dA73110F85eb";
  const CONFIGURED = "0x5caa2dd84b26b59fc617597b5c3e8f0a3fd2a777d517c3b46488a5a232305e6e";
  // ClassicalCurveSale deployment — no launch log can predate it.
  const MIN_BLOCK = 22361603;

  // Ranked by the eth_getLogs block range each node actually serves for free.
  // Narrow-range nodes are useless for a full-history walk, so they are excluded
  // rather than listed as fallbacks.
  const NODES = [
    { url: "https://rpc.mevblocker.io", span: 200000 },
    { url: "https://gateway.tenderly.co/public/mainnet", span: 200000 },
    { url: "https://eth.drpc.org", span: 10000 },
  ];
  // Falling back to the narrower node doubles its request count, so keep the
  // in-flight window count low enough that it doesn't start returning 504s.
  const CONCURRENCY = 3;

  const CACHE_KEY = "zfi_curve_tokens_v1";
  const CACHE_TTL = 5 * 60 * 1000;

  // Addresses this browser just launched. Two things would otherwise hide a fresh
  // coin from the list: the 5-minute sessionStorage cache, and the public RPCs
  // lagging a block or two behind the launch tx. Both resolve on their own, so
  // entries here are only a bridge and expire once a scan would have caught up.
  const RECENT_KEY = "zfi_curve_recent_v1";
  const RECENT_TTL = 60 * 60 * 1000;

  function readRecent() {
    try {
      const list = JSON.parse(sessionStorage.getItem(RECENT_KEY) || "[]");
      if (!Array.isArray(list)) return [];
      return list.filter(e => e && typeof e.addr === "string" && Date.now() - (e.at || 0) < RECENT_TTL);
    } catch { return []; }
  }

  // Record a launch so it shows up in the list immediately. Safe to call twice.
  function note(addr) {
    if (typeof addr !== "string" || !/^0x[0-9a-fA-F]{40}$/.test(addr)) return;
    const a = addr.toLowerCase();
    try {
      const list = readRecent().filter(e => e.addr !== a);
      list.unshift({ addr: a, at: Date.now() });
      sessionStorage.setItem(RECENT_KEY, JSON.stringify(list.slice(0, 50)));
    } catch {}
  }

  // Newest-first, recent launches ahead of the scanned set, no duplicates.
  function withRecent(tokens) {
    const seen = new Set(tokens);
    const head = readRecent().map(e => e.addr).filter(a => !seen.has(a));
    return head.length ? head.concat(tokens) : tokens;
  }

  let _inflight = null;

  async function rpc(node, method, params, timeoutMs) {
    const ctrl = new AbortController();
    const t = setTimeout(() => ctrl.abort(), timeoutMs || 15000);
    try {
      const res = await fetch(node.url, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }),
        signal: ctrl.signal
      });
      const json = await res.json();
      if (json.error) throw new Error(json.error.message || "rpc error");
      return json.result;
    } finally { clearTimeout(t); }
  }

  const hex = n => "0x" + Number(n).toString(16);

  function readCache() {
    try {
      const raw = sessionStorage.getItem(CACHE_KEY);
      if (!raw) return null;
      const c = JSON.parse(raw);
      if (!c || !Array.isArray(c.tokens)) return null;
      if (Date.now() - (c.at || 0) > CACHE_TTL) return null;
      return c.tokens;
    } catch { return null; }
  }

  function writeCache(tokens) {
    try { sessionStorage.setItem(CACHE_KEY, JSON.stringify({ at: Date.now(), tokens })); } catch {}
  }

  // Fetch one [from, to] window, trying each node in rank order. Narrower nodes
  // serve the window as several sub-requests. A window no node will serve yields
  // null rather than aborting the whole scan.
  async function chunkLogs(from, to) {
    // Two passes: a transient 504 under load shouldn't silently drop a window's
    // worth of launches, which would look like "this coin doesn't exist".
    for (let attempt = 0; attempt < 2; attempt++) {
      for (const n of NODES) {
        try {
          const out = [];
          for (let lo = from; lo <= to; lo += n.span + 1) {
            const hi = Math.min(to, lo + n.span);
            const logs = await rpc(n, "eth_getLogs", [{
              address: CURVE_SALE, fromBlock: hex(lo), toBlock: hex(hi), topics: [CONFIGURED]
            }]);
            out.push(...logs);
          }
          return out;
        } catch {}
      }
      await new Promise(r => setTimeout(r, 400 * (attempt + 1)));
    }
    return null;
  }

  // Cover [MIN_BLOCK, head] in fixed windows sized to the widest node, newest first.
  // Windows are independent, so they run a few at a time instead of serially.
  async function scan() {
    let head = null;
    for (const n of NODES) {
      try { head = parseInt(await rpc(n, "eth_blockNumber", [], 8000), 16); break; } catch {}
    }
    if (!head) throw new Error("no RPC reachable");

    const span = NODES[0].span;
    const windows = [];
    for (let to = head; to > MIN_BLOCK; ) {
      const from = Math.max(MIN_BLOCK, to - span);
      windows.push([from, to]);
      to = from - 1;
    }

    const results = new Array(windows.length);
    let next = 0;
    await Promise.all(Array.from({ length: Math.min(CONCURRENCY, windows.length) }, async () => {
      while (next < windows.length) {
        const i = next++;
        results[i] = await chunkLogs(windows[i][0], windows[i][1]);
      }
    }));

    // windows[] is newest-first; within a window later blocks are newer.
    const out = [];
    const seen = new Set();
    for (const logs of results) {
      if (!logs) continue;
      for (let i = logs.length - 1; i >= 0; i--) {
        const t = logs[i].topics[2];
        if (!t) continue;
        const addr = "0x" + t.slice(26).toLowerCase();
        if (seen.has(addr)) continue;
        seen.add(addr);
        out.push(addr);
      }
    }
    return out;
  }

  // Newest-first lowercase token addresses. Concurrent callers share one scan;
  // repeat calls within CACHE_TTL are served from sessionStorage.
  async function tokens(opts) {
    if (!(opts && opts.force)) {
      const cached = readCache();
      if (cached) return withRecent(cached);
    }
    if (_inflight) return _inflight;
    _inflight = (async () => {
      try {
        const list = await scan();
        writeCache(list);
        return withRecent(list);
      } catch (e) {
        console.warn("curve-registry: scan failed", e);
        return withRecent([]);
      } finally { _inflight = null; }
    })();
    return _inflight;
  }

  window.curveRegistry = { tokens, note, CURVE_SALE, CONFIGURED_TOPIC: CONFIGURED, MIN_BLOCK };
})();
