// ---- zAMM pool registry (indexer-free) ----
// Pool IDs are keccak hashes of the PoolKey, so they cannot be inverted. This module
// rebuilds keys deterministically from on-chain launcher state (DAICO scan, curve
// sales), a hardcoded legacy pool, and user-saved keys, then verifies every candidate
// against on-chain reserves. Token metadata is read from the chain as well.
// Consumers: liquidity, orderbook. Requires ethers.
(function () {
// ---- Constants ----
const ZAMM_V0 = "0x00000000000008882D72EfA6cCE4B6a40b24C860";
const ZAMM_V1 = "0x000000000000040470635EB91b7CE4D132D616eD";
const COINS   = "0x0000000000009710cd229bF635c4500029651eE8";
const ZERO    = "0x0000000000000000000000000000000000000000";
const RPCS    = ["https://ethereum.publicnode.com", "https://1rpc.io/eth", "https://eth.drpc.org", "https://eth.llamarpc.com"];
const PAMM    = "0x000000000044bfe6c2BBFeD8862973E0612f07C0";
const ZORG_TOKEN = "0x0000000000009710cd229bf635c4500029651ee8";
const ZORG_ID = 1334160193485309697971829933264346612480800613613n;

// Pool discovery sources (all deterministic / on-chain)
const MC3 = "0xcA11bde05977b3631167028862bE2a173976CA11";
const MC3_ABI = [
  "function aggregate3(tuple(address target, bool allowFailure, bytes callData)[] calls) view returns (tuple(bool success, bytes returnData)[])"
];
const VIEW_HELPER = "0x00000000006631040967E58e3430e4B77921a2db";
const SCAN_ABI = [
  "function scanDAICOs(uint256 daoStart, uint256 daoCount, address[] tribTokens) view returns (tuple(address dao, tuple(string name, string symbol, string contractURI, address sharesToken, address lootToken, address badgesToken, address renderer) meta, tuple(address tribTkn, uint256 tribAmt, uint256 forAmt, address forTkn, uint40 deadline, uint256 remainingSupply, uint256 totalSupply, uint256 treasuryBalance, uint256 allowance, uint16 lpBps, uint16 maxSlipBps, uint256 feeOrHook)[] sales, tuple(address ops, address tribTkn, uint128 ratePerSec, uint64 lastClaim, uint256 claimable, uint256 pending, uint256 treasuryBalance, uint256 tapAllowance) tap)[])"
];
const CURVE_SALE = "0x000000005d9b18764E12E5aeefD6dA73110F85eb";
const CURVE_SALE_ABI = [
  "function curves(address token) view returns (address creator, uint256 cap, uint256 sold, uint256 virtualReserve, uint256 startPrice, uint256 endPrice, uint16 feeBps, uint16 poolFeeBps, uint256 raisedETH, uint256 graduationTarget, uint256 lpTokens, address lpRecipient, bool graduated, bool seeded, uint16 sniperFeeBps, uint16 sniperDuration, uint16 maxBuyBps, uint40 launchTime)"
];
// V1 (ZAMM Hooked) PoolKey: uint256 feeOrHook
const V1_ABI = [
  "function addLiquidity(tuple(uint256 id0, uint256 id1, address token0, address token1, uint256 feeOrHook) key, uint256 amount0Desired, uint256 amount1Desired, uint256 amount0Min, uint256 amount1Min, address to, uint256 deadline) payable returns (uint256 amount0, uint256 amount1, uint256 liquidity)",
  "function removeLiquidity(tuple(uint256 id0, uint256 id1, address token0, address token1, uint256 feeOrHook) key, uint256 liquidity, uint256 amount0Min, uint256 amount1Min, address to, uint256 deadline) returns (uint256 amount0, uint256 amount1)",
  "function pools(uint256) view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast, uint256 price0CumulativeLast, uint256 price1CumulativeLast, uint256 kLast, uint256 supply)",
  "function balanceOf(address, uint256) view returns (uint256)",
  "function setOperator(address operator, bool approved) returns (bool)",
  "function isOperator(address owner, address spender) view returns (bool)"
];

// V0 (ZAMM Hookless) PoolKey: uint96 swapFee
const V0_ABI = [
  "function addLiquidity(tuple(uint256 id0, uint256 id1, address token0, address token1, uint96 swapFee) key, uint256 amount0Desired, uint256 amount1Desired, uint256 amount0Min, uint256 amount1Min, address to, uint256 deadline) payable returns (uint256 amount0, uint256 amount1, uint256 liquidity)",
  "function removeLiquidity(tuple(uint256 id0, uint256 id1, address token0, address token1, uint96 swapFee) key, uint256 liquidity, uint256 amount0Min, uint256 amount1Min, address to, uint256 deadline) returns (uint256 amount0, uint256 amount1)",
  "function pools(uint256) view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast, uint256 price0CumulativeLast, uint256 price1CumulativeLast, uint256 kLast, uint256 supply)",
  "function balanceOf(address, uint256) view returns (uint256)",
  "function setOperator(address operator, bool approved) returns (bool)",
  "function isOperator(address owner, address spender) view returns (bool)"
];

const COINS_ABI = [
  "function setOperator(address operator, bool approved) returns (bool)",
  "function isOperator(address owner, address spender) view returns (bool)",
  "function name(uint256) view returns (string)",
  "function symbol(uint256) view returns (string)"
];

const ERC20_ABI = [
  "function approve(address, uint256) returns (bool)",
  "function allowance(address, address) view returns (uint256)",
  "function balanceOf(address) view returns (uint256)",
  "function name() view returns (string)",
  "function symbol() view returns (string)",
  "function decimals() view returns (uint8)"
];

// ---- RPC helper (fallback provider, same as swap page) ----
function makeWalletReader() {
  try {
    if (!window.ethereum) return null;
    return new ethers.BrowserProvider(window.ethereum, 1);
  } catch { return null; }
}

function makeFallbackProvider(urls) {
  const network = { chainId: 1, name: "mainnet" };
  const nodes = urls.map(u => ({
    url: u,
    p: new ethers.JsonRpcProvider(u, network, { staticNetwork: true, batchMaxCount: 10 }),
    downUntil: 0,
    ok: true,
  }));

  const walletReader = makeWalletReader();
  if (walletReader) {
    nodes.push({ url: "wallet", p: walletReader, downUntil: 0, ok: true });
  }

  const withTimeout = (ms, work) =>
    Promise.race([
      work(),
      new Promise((_, rej) => setTimeout(() => rej(new Error("timeout")), ms)),
    ]);

  const isInfraErr = (e) => {
    const s = String(e?.message || "");
    return /server response 400\b/i.test(s) ||
      /502|503|504|ECONNRESET|ENETUNREACH|EAI_AGAIN|Failed to fetch/i.test(s) ||
      /failed to detect network|timeout|timed out|ETIMEDOUT/i.test(s);
  };
  const isAuthErr = (e) => /Unauthorized|invalid api key|403|401/i.test(String(e?.message || ""));

  return {
    async call(fn, timeoutMs) {
      const now = Date.now();
      let lastErr;
      const candidates = nodes
        .filter(n => n.ok && n.downUntil <= now)
        .concat(nodes.filter(n => n.ok && n.downUntil > now));
      for (const n of candidates) {
        try {
          const res = await withTimeout(timeoutMs || 3500, () => fn(n.p));
          n.downUntil = 0;
          return res;
        } catch (e) {
          lastErr = e;
          if (isAuthErr(e)) n.ok = false;
          else if (isInfraErr(e)) n.downUntil = Date.now() + 30_000;
        }
      }
      throw lastErr || new Error("All RPCs failed");
    },
  };
}

const rpc = makeFallbackProvider(RPCS);

// ---- Multicall3 batch reader ----
// calls: [{ target, iface, fn, args }] -> [decoded result | null]
async function batchRead(calls) {
  if (!calls.length) return [];
  const encoded = calls.map(c => ({
    target: c.target,
    allowFailure: true,
    callData: c.iface.encodeFunctionData(c.fn, c.args || [])
  }));
  const CHUNK = 100;
  const out = [];
  for (let i = 0; i < encoded.length; i += CHUNK) {
    const slice = encoded.slice(i, i + CHUNK);
    const res = await rpc.call(p =>
      new ethers.Contract(MC3, MC3_ABI, p).aggregate3.staticCall(slice), 12000);
    for (let j = 0; j < res.length; j++) {
      const c = calls[i + j];
      if (!res[j].success || res[j].returnData === '0x') { out.push(null); continue; }
      try { out.push(c.iface.decodeFunctionResult(c.fn, res[j].returnData)); }
      catch { out.push(null); }
    }
  }
  return out;
}

// ---- Pool key math ----
// PoolKey is canonically ordered by token address; ids follow their token.
function orderKey(tokenA, tokenB, idA, idB) {
  const a = tokenA.toLowerCase(), b = tokenB.toLowerCase();
  return a < b || (a === b && BigInt(idA) <= BigInt(idB))
    ? { token0: tokenA, token1: tokenB, id0: BigInt(idA), id1: BigInt(idB) }
    : { token0: tokenB, token1: tokenA, id0: BigInt(idB), id1: BigInt(idA) };
}

function computePoolId(key) {
  return BigInt(ethers.keccak256(ethers.AbiCoder.defaultAbiCoder().encode(
    ["uint256", "uint256", "address", "address", "uint256"],
    [key.id0, key.id1, key.token0, key.token1, key.fee]
  ))).toString();
}

function makeEntry(tokenA, tokenB, idA, idB, fee, isV0) {
  const k = orderKey(tokenA, tokenB, idA, idB);
  const entry = { ...k, fee: BigInt(fee), isV0: !!isV0 };
  entry.id = computePoolId(entry);
  return entry;
}

// ---- Pool registry (deterministic discovery + user-saved keys) ----
const CUSTOM_POOLS_KEY = 'zfi_lp_custom_pools';
const _registry = new Map();   // poolId -> entry
let _discovering = null;

function registerEntry(entry) {
  const existing = _registry.get(entry.id);
  if (existing) return existing;
  _registry.set(entry.id, entry);
  return entry;
}

// The one legacy V0 pool that still matters: zAMM/ETH on the hookless singleton.
function legacyEntry() {
  return makeEntry(ZERO, ZORG_TOKEN, 0n, ZORG_ID, 100n, true);
}

function loadCustomPools() {
  try {
    const raw = JSON.parse(localStorage.getItem(CUSTOM_POOLS_KEY) || '[]');
    if (!Array.isArray(raw)) return [];
    return raw.map(r => {
      try { return makeEntry(r.token0, r.token1, r.id0, r.id1, r.fee, r.isV0); }
      catch { return null; }
    }).filter(Boolean);
  } catch { return []; }
}

function saveCustomPool(entry) {
  try {
    const raw = JSON.parse(localStorage.getItem(CUSTOM_POOLS_KEY) || '[]');
    const arr = Array.isArray(raw) ? raw : [];
    if (arr.some(r => {
      try { return makeEntry(r.token0, r.token1, r.id0, r.id1, r.fee, r.isV0).id === entry.id; }
      catch { return false; }
    })) return;
    arr.push({
      token0: entry.token0, token1: entry.token1,
      id0: entry.id0.toString(), id1: entry.id1.toString(),
      fee: entry.fee.toString(), isV0: entry.isV0
    });
    localStorage.setItem(CUSTOM_POOLS_KEY, JSON.stringify(arr.slice(-100)));
  } catch {}
}

// DAICO coins: pool key is (ETH, sharesToken, 0, 0, sale.feeOrHook) on V1
async function discoverDaicoPools() {
  try {
    const daicos = await rpc.call(p =>
      new ethers.Contract(VIEW_HELPER, SCAN_ABI, p).scanDAICOs(0, 500, [ZERO]), 15000);
    const out = [];
    for (const d of (daicos || [])) {
      const shares = d.meta && d.meta.sharesToken;
      if (!shares || shares === ZERO) continue;
      const fee = d.sales && d.sales.length ? BigInt(d.sales[0].feeOrHook) : 30n;
      out.push(makeEntry(ZERO, shares, 0n, 0n, fee, false));
    }
    return out;
  } catch (e) {
    console.warn("discoverDaicoPools:", e);
    return [];
  }
}

// Curve-launched coins: pool key is (ETH, token, 0, 0, curve.poolFeeBps) on V1.
// Tokens come from the sale contract's launch logs; every pool derived from them
// is then verified against on-chain reserves before it is shown.
async function discoverCurvePools() {
  // Launch registry from the sale contract's own logs (dapp/modules/curve-registry.js).
  const addrs = window.curveRegistry ? await window.curveRegistry.tokens() : [];
  if (!addrs.length) return [];
  try {
    const iface = new ethers.Interface(CURVE_SALE_ABI);
    const results = await batchRead(addrs.map(a => ({ target: CURVE_SALE, iface, fn: 'curves', args: [a] })));
    const out = [];
    for (let i = 0; i < addrs.length; i++) {
      const c = results[i];
      if (!c) continue;
      const fee = BigInt(c.poolFeeBps ?? 0);
      if (fee === 0n) continue;
      out.push(makeEntry(ZERO, ethers.getAddress(addrs[i]), 0n, 0n, fee, false));
    }
    return out;
  } catch (e) {
    console.warn("discoverCurvePools:", e);
    return [];
  }
}

// Build the registry, then verify each candidate against on-chain reserves.
async function discoverPools() {
  if (_discovering) return _discovering;
  _discovering = (async () => {
    const seeds = [legacyEntry(), ...loadCustomPools()];
    const [daico, curve] = await Promise.all([discoverDaicoPools(), discoverCurvePools()]);
    for (const e of [...seeds, ...daico, ...curve]) registerEntry(e);

    const entries = [...new Set(_registry.values())];
    const v0i = new ethers.Interface(V0_ABI);
    const reserves = await batchRead(entries.map(e => ({
      target: e.isV0 ? ZAMM_V0 : ZAMM_V1, iface: v0i, fn: 'pools', args: [BigInt(e.id)]
    })));
    const live = [];
    for (let i = 0; i < entries.length; i++) {
      const r = reserves[i];
      if (!r) continue;
      entries[i].reserve0 = BigInt(r[0]);
      entries[i].reserve1 = BigInt(r[1]);
      entries[i].supply = BigInt(r[6]);
      if (entries[i].supply > 0n) live.push(entries[i]);
    }
    await resolveEntriesMeta(live);
    return live;
  })();
  return _discovering;
}

// ---- On-chain token metadata ----
const _metaCache = new Map();   // `${token}:${id}` -> { symbol, name, decimals }

function metaKey(token, id) { return token.toLowerCase() + ':' + BigInt(id || 0).toString(); }

function metaCalls(token, id) {
  const cid = BigInt(id || 0);
  if (token === ZERO || token.toLowerCase() === ZERO) return null;
  const ta = token.toLowerCase();
  if (ta === PAMM.toLowerCase()) return null;          // synthesized YES/NO
  if (cid > 0n) {
    // ERC6909 coin held by a singleton (COINS or ZAMM V1): per-id name/symbol
    const iface = new ethers.Interface(COINS_ABI);
    return { erc6909: true, iface, target: token };
  }
  const iface = new ethers.Interface(ERC20_ABI);
  return { erc6909: false, iface, target: token };
}

// Resolve metadata for many (token,id) pairs in one multicall round.
async function resolveMetaBatch(pairs) {
  const todo = [];
  for (const { token, id } of pairs) {
    const k = metaKey(token, id);
    if (_metaCache.has(k)) continue;
    const spec = metaCalls(token, id);
    if (!spec) { _metaCache.set(k, fallbackMeta(token, id)); continue; }
    todo.push({ k, token, id: BigInt(id || 0), spec });
  }
  if (!todo.length) return;
  const calls = [];
  for (const t of todo) {
    if (t.spec.erc6909) {
      calls.push({ target: t.spec.target, iface: t.spec.iface, fn: 'symbol', args: [t.id] });
      calls.push({ target: t.spec.target, iface: t.spec.iface, fn: 'name', args: [t.id] });
      calls.push(null); // decimals: ERC6909 coins are 18
    } else {
      calls.push({ target: t.spec.target, iface: t.spec.iface, fn: 'symbol', args: [] });
      calls.push({ target: t.spec.target, iface: t.spec.iface, fn: 'name', args: [] });
      calls.push({ target: t.spec.target, iface: t.spec.iface, fn: 'decimals', args: [] });
    }
  }
  const real = calls.filter(Boolean);
  let results;
  try { results = await batchRead(real); }
  catch (e) { console.warn("resolveMetaBatch:", e); results = real.map(() => null); }
  // Re-align results with the (possibly null-padded) call list
  const aligned = [];
  let ri = 0;
  for (const c of calls) aligned.push(c ? results[ri++] : null);

  for (let i = 0; i < todo.length; i++) {
    const t = todo[i];
    const sym = aligned[i * 3], nm = aligned[i * 3 + 1], dec = aligned[i * 3 + 2];
    const fb = fallbackMeta(t.token, t.id);
    _metaCache.set(t.k, {
      symbol: (sym && sym[0]) ? String(sym[0]) : fb.symbol,
      name: (nm && nm[0]) ? String(nm[0]) : fb.name,
      decimals: dec && dec[0] != null ? Number(dec[0]) : 18
    });
  }
}

function fallbackMeta(token, id) {
  const cid = BigInt(id || 0);
  if (!token || token.toLowerCase() === ZERO) return { symbol: 'ETH', name: 'Ethereum', decimals: 18 };
  if (token.toLowerCase() === PAMM.toLowerCase()) return { symbol: 'Shares', name: 'Prediction shares', decimals: 18 };
  if (cid > 0n) return { symbol: 'Coin #' + cid.toString().slice(0, 6), name: 'Coin ' + cid.toString(), decimals: 18 };
  return { symbol: token.slice(0, 6) + '…' + token.slice(-4), name: token, decimals: 18 };
}

function getMeta(token, id) {
  return _metaCache.get(metaKey(token, id)) || fallbackMeta(token, id);
}

async function resolveEntriesMeta(entries) {
  const pairs = [];
  for (const e of entries) {
    pairs.push({ token: e.token0, id: e.id0 });
    pairs.push({ token: e.token1, id: e.id1 });
  }
  await resolveMetaBatch(pairs);
  for (const e of entries) {
    e.isPM = e.token0.toLowerCase() === PAMM.toLowerCase() && e.token1.toLowerCase() === PAMM.toLowerCase();
    e.meta0 = { ...getMeta(e.token0, e.id0) };
    e.meta1 = { ...getMeta(e.token1, e.id1) };
    if (e.isPM) { e.meta0.symbol = 'YES'; e.meta1.symbol = 'NO'; }
  }
}

// ---- Format helpers ----
function fmtWei(val, decimals) {
  if (val === null || val === undefined) return "0";
  const d = decimals || 18;
  const n = BigInt(val);
  if (n === 0n) return "0";
  const neg = n < 0n;
  const abs = neg ? -n : n;
  const divisor = 10n ** BigInt(d);
  const whole = abs / divisor;
  const frac = abs % divisor;
  const fracStr = frac.toString().padStart(d, '0').slice(0, 6).replace(/0+$/, '');
  return (neg ? '-' : '') + whole.toString() + (fracStr ? '.' + fracStr : '');
}

function poolFeePct(entry) {
  const fee = BigInt(entry.fee);
  if (fee > 10000n) return 'hooked';
  return (Number(fee) / 100).toFixed(2) + '%';
}

function poolVersionLabel(entry) {
  if (entry.isV0) return 'ZAMM legacy';
  if (entry.isPM) return 'Prediction Market';
  return 'ZAMM';
}

async function fetchTokenBalance(tokenAddr, coinId, userAddr) {
  if (tokenAddr === ZERO || tokenAddr.toLowerCase() === ZERO) {
    return await rpc.call(p => p.getBalance(userAddr));
  }
  const cid = BigInt(coinId || 0);
  const erc6909Bal = ["function balanceOf(address,uint256) view returns (uint256)"];
  // A non-zero id always means an ERC6909 held by the token address itself
  // (COINS, ZAMM V1 hooked coins, PAMM shares) — never an ERC20.
  if (cid > 0n) {
    return await rpc.call(p => new ethers.Contract(tokenAddr, erc6909Bal, p).balanceOf(userAddr, cid));
  }
  return await rpc.call(p => new ethers.Contract(tokenAddr, ERC20_ABI, p).balanceOf(userAddr));
}


// Resolve a pool ID to a verified entry with metadata, or null if the key is unknown.
async function resolvePool(poolId) {
  const cached = _registry.get(String(poolId));
  if (cached && cached.meta0) return cached;
  const pools = await discoverPools();
  const found = pools.find(p => p.id === String(poolId)) || _registry.get(String(poolId));
  if (found && !found.meta0) await resolveEntriesMeta([found]);
  return found || null;
}

window.zammPools = {
  ZAMM_V0, ZAMM_V1, COINS, PAMM, ZERO, ZORG_TOKEN, ZORG_ID,
  V0_ABI, V1_ABI, ERC20_ABI, COINS_ABI, RPCS,
  rpc, batchRead, orderKey, computePoolId, makeEntry, registerEntry,
  saveCustomPool, loadCustomPools, legacyEntry, discoverPools, resolvePool,
  resolveEntriesMeta, resolveMetaBatch, getMeta, fallbackMeta,
  poolFeePct, poolVersionLabel, fmtWei, fetchTokenBalance,
  registry: _registry
};
})();
