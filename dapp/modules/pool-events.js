// ---- On-chain zAMM pool activity ----
// Replaces the retired coinchan indexer's /api/events feed by reading Swap/Mint/Burn
// logs straight from the two zAMM singletons. Dependency-free (raw JSON-RPC over
// fetch) so pages that don't bundle ethers can use it.
//
// Public RPCs cap eth_getLogs ranges, so history is walked backwards in chunks and
// is necessarily shallow compared to an indexer: `load()` scans a bounded window and
// returns a cursor to continue from. Callers should treat an empty result as "no
// recent activity", not "no activity ever".
(function () {
  const SINGLETONS = [
    "0x000000000000040470635EB91b7CE4D132D616eD", // ZAMM (hooked / current)
    "0x00000000000008882D72EfA6cCE4B6a40b24C860"  // ZAMM V0 (legacy hookless)
  ];

  // event Swap(uint256 indexed poolId, address indexed sender, uint256 amount0In,
  //            uint256 amount1In, uint256 amount0Out, uint256 amount1Out, address indexed to)
  const T_SWAP = "0xf51245804459075de3f63c42324c8ba2021175781c7477a5d8f4f08fb5584a56";
  // event Mint(uint256 indexed poolId, address indexed sender, uint256 amount0, uint256 amount1)
  const T_MINT = "0x5a3e96f397e68b20a43c25f664b628805b877334dadfcc925c6c1a3ad4340458";
  // event Burn(uint256 indexed poolId, address indexed sender, uint256 amount0,
  //            uint256 amount1, address indexed to)
  const T_BURN = "0xd72b7803f66104fa4755cf48b28b9408682e97a0b000dd97c8ee3219aa8454ec";

  // Ordered by usable eth_getLogs range: nodes with tight caps still serve
  // eth_blockNumber/eth_getBlockByNumber, so they stay in the list as fallbacks.
  // Ranked by the eth_getLogs block range each one actually serves for free.
  // cloudflare-eth.com was dropped 2026-08-03: Cloudflare wound the public
  // gateway down, and it now answers every eth_getLogs with
  // {"code":-32046,"message":"Cannot fulfill request"} — even at the 800-block
  // range it was listed for — so it was a guaranteed-failing entry in the
  // fallback chain. gateway.tenderly.co replaces it, measured serving a
  // 100k-block getLogs from a browser origin with Access-Control-Allow-Origin: *.
  const RPCS = [
    { url: "https://rpc.mevblocker.io", span: 200000 },
    { url: "https://rpc.flashbots.net", span: 100000 },
    { url: "https://mainnet.gateway.tenderly.co", span: 100000 },
    { url: "https://eth.drpc.org", span: 9000 }
  ];

  const DEFAULT_CHUNKS = 6;    // ~1.2M blocks ≈ 5 months on the widest node
  // ZAMM V0 (the older of the two singletons) was deployed here, so no pool event
  // can predate it. Scans stop at this floor instead of walking back to genesis.
  const MIN_BLOCK = 22361603;
  const _down = new Map();     // url -> timestamp until which it is skipped

  function healthy(node) {
    const until = _down.get(node.url) || 0;
    return until <= Date.now();
  }

  async function rpc(node, method, params, timeoutMs) {
    const ctrl = new AbortController();
    const t = setTimeout(() => ctrl.abort(), timeoutMs || 12000);
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

  // Run `fn` against the first node that answers; park failing nodes briefly.
  async function anyNode(fn, filter) {
    let lastErr;
    const nodes = RPCS.filter(n => (!filter || filter(n)));
    for (const n of nodes.filter(healthy).concat(nodes.filter(n => !healthy(n)))) {
      try { return await fn(n); }
      catch (e) { lastErr = e; _down.set(n.url, Date.now() + 30000); }
    }
    throw lastErr || new Error("all RPCs failed");
  }

  const hex = n => "0x" + BigInt(n).toString(16);
  const word = (data, i) => BigInt("0x" + data.slice(2 + i * 64, 2 + (i + 1) * 64));
  const addrFromTopic = t => "0x" + t.slice(26);

  function decodeLog(log) {
    const topic0 = log.topics[0];
    const poolId = BigInt(log.topics[1]).toString();
    const sender = log.topics[2] ? addrFromTopic(log.topics[2]) : null;
    const base = {
      poolId,
      maker: sender,
      txhash: log.transactionHash,
      blockNumber: parseInt(log.blockNumber, 16),
      logIndex: parseInt(log.logIndex, 16),
      timestamp: log.blockTimestamp ? parseInt(log.blockTimestamp, 16) : null,
      amount0_in: "0", amount1_in: "0", amount0_out: "0", amount1_out: "0"
    };
    if (topic0 === T_SWAP) {
      const a0in = word(log.data, 0), a1in = word(log.data, 1);
      const a0out = word(log.data, 2), a1out = word(log.data, 3);
      // token0 in → the pool's token1 is being bought
      return Object.assign(base, {
        type: a0in > 0n ? "BUY" : "SELL",
        category: "SWAP",
        amount0_in: a0in.toString(), amount1_in: a1in.toString(),
        amount0_out: a0out.toString(), amount1_out: a1out.toString()
      });
    }
    if (topic0 === T_MINT) {
      return Object.assign(base, {
        type: "LIQADD", category: "LIQ",
        amount0_in: word(log.data, 0).toString(),
        amount1_in: word(log.data, 1).toString()
      });
    }
    if (topic0 === T_BURN) {
      return Object.assign(base, {
        type: "LIQREM", category: "LIQ",
        amount0_out: word(log.data, 0).toString(),
        amount1_out: word(log.data, 1).toString()
      });
    }
    return null;
  }

  async function headBlock() {
    return await anyNode(async n => parseInt(await rpc(n, "eth_blockNumber", []), 16));
  }

  // Fill in timestamps for logs whose RPC omitted blockTimestamp.
  async function fillTimestamps(events) {
    const missing = [...new Set(events.filter(e => !e.timestamp).map(e => e.blockNumber))].slice(0, 60);
    if (!missing.length) return;
    const byBlock = new Map();
    await Promise.all(missing.map(async bn => {
      try {
        const b = await anyNode(n => rpc(n, "eth_getBlockByNumber", [hex(bn), false], 8000));
        if (b && b.timestamp) byBlock.set(bn, parseInt(b.timestamp, 16));
      } catch {}
    }));
    for (const e of events) {
      if (!e.timestamp && byBlock.has(e.blockNumber)) e.timestamp = byBlock.get(e.blockNumber);
    }
  }

  // Walk backwards from `before` (or chain head) collecting this pool's events.
  // Returns { events (newest first), nextCursor, scannedTo }.
  async function load(poolId, opts) {
    const o = opts || {};
    const limit = o.limit || 30;
    const maxChunks = o.maxChunks || DEFAULT_CHUNKS;
    const topicPool = "0x" + BigInt(poolId).toString(16).padStart(64, "0");
    const topics = [[T_SWAP, T_MINT, T_BURN], topicPool];

    let to = o.before != null ? Number(o.before) : await headBlock();
    if (!(to > MIN_BLOCK)) return { events: [], nextCursor: null };

    const out = [];
    let chunks = 0, failures = 0;
    while (chunks < maxChunks && to > MIN_BLOCK && out.length < limit) {
      let got = null;
      let span = 0;
      try {
        got = await anyNode(async n => {
          span = n.span;
          const from = Math.max(MIN_BLOCK, to - n.span);
          return await rpc(n, "eth_getLogs", [{
            address: SINGLETONS, fromBlock: hex(from), toBlock: hex(to), topics
          }], 20000);
        }, n => n.span >= 500);   // skip nodes whose range cap makes scanning hopeless
        failures = 0;
      } catch (e) {
        // Every node refused this window. Retry it once — `to` is unchanged, so a
        // caller resuming from the returned cursor picks up exactly here.
        console.warn("pool-events: getLogs failed", e);
        if (++failures >= 2) break;
        continue;
      }
      for (const log of got) {
        const ev = decodeLog(log);
        if (ev && ev.poolId === String(poolId)) out.push(ev);
      }
      to = Math.max(MIN_BLOCK - 1, to - span) - 1;
      chunks++;
    }

    out.sort((a, b) => b.blockNumber - a.blockNumber || b.logIndex - a.logIndex);
    const page = out.slice(0, limit);
    await fillTimestamps(page);
    // More history may exist below the scanned window; hand back where to resume.
    const nextCursor = to > MIN_BLOCK ? String(to) : null;
    return { events: page, nextCursor, scannedTo: to };
  }

  // Convenience: deep scan in chronological order (oldest first), used for charts.
  async function history(poolId, opts) {
    const o = opts || {};
    const all = [];
    let cursor = null;
    const rounds = o.rounds || 4;   // bounded further by MIN_BLOCK
    for (let i = 0; i < rounds; i++) {
      const { events, nextCursor } = await load(poolId, {
        limit: o.limit || 500, before: cursor, maxChunks: o.maxChunks || 16
      });
      all.push(...events);
      if (!nextCursor) break;
      cursor = nextCursor;
    }
    all.sort((a, b) => a.blockNumber - b.blockNumber || a.logIndex - b.logIndex);
    return all;
  }

  window.poolEvents = { load, history, TOPICS: { swap: T_SWAP, mint: T_MINT, burn: T_BURN } };
})();
