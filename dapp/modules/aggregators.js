// ---- External API price cache (15s TTL, LRU eviction, prevents re-fetch on rapid re-quotes) ----
const _extPriceCache = new Map();
const _extPriceInflight = new Map();
const _extPriceTTL = 15_000;
const _extPriceMaxSize = 100;
// How long the quote will keep waiting on external aggregator prices once the
// on-chain route is already decoded. See settleWithin below.
const EXT_PRICE_DEADLINE_MS = 1500;

// ---- Provider circuit breaker ----
// An aggregator that answers 401/403/429 is not rate-limiting one request, it is
// refusing this origin — OpenOcean's v4 endpoint began 403ing every call, and each
// quote paid for a request that could never return a route while the console filled
// with failures. Three consecutive refusals and the provider is left alone for the
// rest of the session; anything that recovers on its own gets its counter reset by
// the first response that is not a refusal.
const _providerStrikes = new Map();
const PROVIDER_STRIKE_LIMIT = 3;
function providerIsDown(name) {
  return (_providerStrikes.get(name) || 0) >= PROVIDER_STRIKE_LIMIT;
}
// A refusal is about the caller, not the pair: 404/422 usually mean "no route for
// this pair", which is a normal answer and must not count against the provider.
function noteProviderResponse(name, status) {
  if (status === 401 || status === 403 || status === 429) {
    const n = (_providerStrikes.get(name) || 0) + 1;
    _providerStrikes.set(name, n);
    if (n === PROVIDER_STRIKE_LIMIT) {
      console.info(`[aggregators] ${name} refused ${n} times (last ${status}); skipping it this session.`);
    }
  } else {
    _providerStrikes.delete(name);
  }
}
function cachedFetch(key, fetchFn) {
  const cached = _extPriceCache.get(key);
  if (cached && Date.now() - cached.t < _extPriceTTL) {
    // LRU: move to end on access
    _extPriceCache.delete(key);
    _extPriceCache.set(key, cached);
    return Promise.resolve(cached.v);
  }
  // Deduplicate in-flight requests for the same key
  const inflight = _extPriceInflight.get(key);
  if (inflight) return inflight;
  const p = fetchFn().then(v => {
    _extPriceInflight.delete(key);
    _extPriceCache.set(key, { v, t: Date.now() });
    // Evict oldest (least recently used) entries when over limit
    if (_extPriceCache.size > _extPriceMaxSize) {
      const oldest = _extPriceCache.keys().next().value;
      _extPriceCache.delete(oldest);
    }
    return v;
  }, err => {
    _extPriceInflight.delete(key);
    throw err;
  });
  _extPriceInflight.set(key, p);
  return p;
}

// Resolve a fan-out, but stop waiting after `ms` and report whatever has landed
// (unfinished slots come back as null). The external aggregators each self-abort
// on their own schedule, so a single slow API used to hold the entire quote —
// the on-chain route could be decoded in 400ms and still sit behind a 4s API.
// Nothing is wasted by cutting them off: the in-flight requests still settle
// into _extPriceCache, so the next refresh serves them instantly from cache.
function settleWithin(ms, promises) {
  let tid;
  const deadline = new Promise(r => { tid = setTimeout(() => r(null), ms); });
  return Promise.all(promises.map(p => Promise.race([Promise.resolve(p).catch(() => null), deadline])))
    .finally(() => clearTimeout(tid));
}

// ---- 0x / Matcha API helpers ----
function ox0xToken(addr) {
  return addr === ZERO_ADDRESS ? OX_ETH_SENTINEL : addr;
}
async function get0xPrice(sellToken, buyToken, sellAmount) {
  if (MATCHA_ADDRESS === ZERO_ADDRESS) return null;
  const ac = new AbortController();
  const tid = setTimeout(() => ac.abort(), 3000);
  try {
    const params = new URLSearchParams({
      chainId: String(OX_CHAIN_ID),
      sellToken: ox0xToken(sellToken),
      buyToken: ox0xToken(buyToken),
      taker: MATCHA_ADDRESS,
      sellAmount: sellAmount.toString(),
    });
    const resp = await fetch(`${OX_API_BASE}/swap/allowance-holder/price?${params}`, { signal: ac.signal });
    if (!resp.ok) return null;
    return resp.json();
  } finally { clearTimeout(tid); }
}
async function get0xQuote(sellToken, buyToken, sellAmount, slippageBps) {
  if (MATCHA_ADDRESS === ZERO_ADDRESS) return null;
  const ac = new AbortController();
  const tid = setTimeout(() => ac.abort(), 8000);
  try {
    const params = new URLSearchParams({
      chainId: String(OX_CHAIN_ID),
      sellToken: ox0xToken(sellToken),
      buyToken: ox0xToken(buyToken),
      taker: MATCHA_ADDRESS,
      slippageBps: String(slippageBps),
      sellAmount: sellAmount.toString(),
    });
    const resp = await fetch(`${OX_API_BASE}/swap/allowance-holder/quote?${params}`, { signal: ac.signal });
    if (!resp.ok) return null;
    return resp.json();
  } catch (_) { return null; } finally { clearTimeout(tid); }
}

// ParaSwap API helpers
function psToken(addr) {
  return addr === ZERO_ADDRESS ? PS_ETH_SENTINEL : addr;
}
async function getParaswapPrice(sellToken, buyToken, amount, srcDecimals, destDecimals, exactOut = false) {
  if (PARASOL_ADDRESS === ZERO_ADDRESS) return null;
  const ac = new AbortController();
  const tid = setTimeout(() => ac.abort(), 3000);
  try {
    const side = exactOut ? "BUY" : "SELL";
    const params = new URLSearchParams({
      srcToken: psToken(sellToken),
      destToken: psToken(buyToken),
      amount: amount.toString(),
      srcDecimals: String(srcDecimals),
      destDecimals: String(destDecimals),
      side,
      network: "1",
      version: "6.2",
    });
    const resp = await fetch(`${PS_API}/prices?${params}`, { signal: ac.signal });
    if (!resp.ok) return null;
    const json = await resp.json();
    return json.priceRoute || null;
  } finally { clearTimeout(tid); }
}
async function getParaswapQuote(priceRoute, sellToken, buyToken, slippageBps) {
  if (PARASOL_ADDRESS === ZERO_ADDRESS) return null;
  const ac = new AbortController();
  const tid = setTimeout(() => ac.abort(), 8000);
  try {
    const body = {
      srcToken: psToken(sellToken),
      destToken: psToken(buyToken),
      srcDecimals: priceRoute.srcDecimals,
      destDecimals: priceRoute.destDecimals,
      priceRoute,
      userAddress: PARASOL_ADDRESS,
      partner: "zFi",
      slippage: slippageBps,
    };
    const resp = await fetch(`${PS_API}/transactions/1?ignoreChecks=true`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body),
      signal: ac.signal,
    });
    if (!resp.ok) return null;
    return resp.json();
  } catch (_) { return null; } finally { clearTimeout(tid); }
}

// KyberSwap API helpers
function ksToken(addr) {
  return addr === ZERO_ADDRESS ? KS_ETH_SENTINEL : addr;
}
async function getKyberPrice(sellToken, buyToken, sellAmount) {
  if (KYBEROL_ADDRESS === ZERO_ADDRESS) return null;
  const ac = new AbortController();
  const tid = setTimeout(() => ac.abort(), 3000);
  try {
    const params = new URLSearchParams({
      tokenIn: ksToken(sellToken),
      tokenOut: ksToken(buyToken),
      amountIn: sellAmount.toString(),
    });
    const resp = await fetch(`${KS_API}/ethereum/api/v1/routes?${params}`, { signal: ac.signal });
    if (!resp.ok) return null;
    const json = await resp.json();
    return json.data?.routeSummary || null;
  } finally { clearTimeout(tid); }
}
async function getKyberQuote(routeSummary, slippageBps) {
  if (KYBEROL_ADDRESS === ZERO_ADDRESS) return null;
  const ac = new AbortController();
  const tid = setTimeout(() => ac.abort(), 8000);
  try {
    const resp = await fetch(`${KS_API}/ethereum/api/v1/route/build`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        routeSummary,
        sender: KYBEROL_ADDRESS,
        recipient: KYBEROL_ADDRESS,
        slippageTolerance: slippageBps,
      }),
      signal: ac.signal,
    });
    if (!resp.ok) return null;
    const json = await resp.json();
    return json.data || null;
  } catch (_) { return null; } finally { clearTimeout(tid); }
}

// 1inch API helpers
function inchToken(addr) {
  return addr === ZERO_ADDRESS ? INCH_ETH_SENTINEL : addr;
}
async function get1inchPrice(sellToken, buyToken, sellAmount) {
  if (ONEINCHOL_ADDRESS === ZERO_ADDRESS) return null;
  const ac = new AbortController();
  const tid = setTimeout(() => ac.abort(), 3000);
  try {
    const params = new URLSearchParams({
      src: inchToken(sellToken),
      dst: inchToken(buyToken),
      amount: sellAmount.toString(),
      includeGas: 'true',
    });
    const resp = await fetch(`${INCH_API_BASE}/swap/v6.0/1/quote?${params}`, { signal: ac.signal });
    if (!resp.ok) return null;
    return resp.json();
  } finally { clearTimeout(tid); }
}
async function get1inchQuote(sellToken, buyToken, sellAmount, slippageBps) {
  if (ONEINCHOL_ADDRESS === ZERO_ADDRESS) return null;
  const ac = new AbortController();
  const tid = setTimeout(() => ac.abort(), 8000);
  try {
    const params = new URLSearchParams({
      src: inchToken(sellToken),
      dst: inchToken(buyToken),
      amount: sellAmount.toString(),
      from: ONEINCHOL_ADDRESS,
      slippage: (Number(slippageBps) / 100).toString(),
      disableEstimate: 'true',
    });
    const resp = await fetch(`${INCH_API_BASE}/swap/v6.0/1/swap?${params}`, { signal: ac.signal });
    if (!resp.ok) return null;
    return resp.json();
  } catch (_) { return null; } finally { clearTimeout(tid); }
}

// Odos API helpers
function odosToken(addr) {
  return addr === ZERO_ADDRESS ? ODOS_ETH_SENTINEL : addr;
}
async function getOdosPrice(sellToken, buyToken, sellAmount) {
  if (ODOSOL_ADDRESS === ZERO_ADDRESS) return null;
  const ac = new AbortController();
  const tid = setTimeout(() => ac.abort(), 3000);
  try {
    const resp = await fetch(`${ODOS_API}/sor/quote/v2`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      signal: ac.signal,
      body: JSON.stringify({
        chainId: 1,
        inputTokens: [{ tokenAddress: odosToken(sellToken), amount: sellAmount.toString() }],
        outputTokens: [{ tokenAddress: odosToken(buyToken), proportion: 1 }],
        userAddr: ODOSOL_ADDRESS,
        slippageLimitPercent: 1,
        compact: true,
        simple: true,
        disableRFQs: false,
      }),
    });
    if (!resp.ok) return null;
    return resp.json();
  } finally { clearTimeout(tid); }
}
async function getOdosQuote(pathId, slippageBps) {
  if (ODOSOL_ADDRESS === ZERO_ADDRESS) return null;
  const ac = new AbortController();
  const tid = setTimeout(() => ac.abort(), 8000);
  try {
    const resp = await fetch(`${ODOS_API}/sor/assemble`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        userAddr: ODOSOL_ADDRESS,
        pathId,
        simulate: false,
      }),
      signal: ac.signal,
    });
    if (!resp.ok) return null;
    return resp.json();
  } catch (_) { return null; } finally { clearTimeout(tid); }
}

// OKX DEX API helpers
function okxToken(addr) {
  return addr === ZERO_ADDRESS ? OKX_ETH_SENTINEL : addr;
}
async function getOkxPrice(sellToken, buyToken, sellAmount) {
  if (OKXOL_ADDRESS === ZERO_ADDRESS) return null;
  const ac = new AbortController();
  const tid = setTimeout(() => ac.abort(), 3000);
  try {
    const params = new URLSearchParams({
      chainIndex: '1',
      fromTokenAddress: okxToken(sellToken),
      toTokenAddress: okxToken(buyToken),
      amount: sellAmount.toString(),
      swapMode: 'exactIn',
    });
    const resp = await fetch(`${OKX_API_BASE}/dex/aggregator/quote?${params}`, { signal: ac.signal });
    if (!resp.ok) return null;
    const json = await resp.json();
    if (json.code !== '0' || !json.data || !json.data[0]) return null;
    return json.data[0];
  } finally { clearTimeout(tid); }
}
async function getOkxQuote(sellToken, buyToken, sellAmount, slippageBps) {
  if (OKXOL_ADDRESS === ZERO_ADDRESS) return null;
  const ac = new AbortController();
  const tid = setTimeout(() => ac.abort(), 8000);
  try {
    const params = new URLSearchParams({
      chainIndex: '1',
      fromTokenAddress: okxToken(sellToken),
      toTokenAddress: okxToken(buyToken),
      amount: sellAmount.toString(),
      slippagePercent: (Number(slippageBps) / 100).toString(),
      userWalletAddress: OKXOL_ADDRESS,
      swapMode: 'exactIn',
    });
    const resp = await fetch(`${OKX_API_BASE}/dex/aggregator/swap?${params}`, { signal: ac.signal });
    if (!resp.ok) return null;
    const json = await resp.json();
    if (json.code !== '0' || !json.data || !json.data[0]) return null;
    return json.data[0];
  } catch (_) { return null; } finally { clearTimeout(tid); }
}

// Bebop API helpers
function bebopToken(addr) {
  return addr === ZERO_ADDRESS ? WETH_ADDRESS : addr;
}
async function getBebopPrice(sellToken, buyToken, sellAmount) {
  if (BEBOPOL_ADDRESS === ZERO_ADDRESS) return null;
  const sell = bebopToken(sellToken);
  const buy = bebopToken(buyToken);
  if (sell.toLowerCase() === buy.toLowerCase()) return null;
  const ac = new AbortController();
  const tid = setTimeout(() => ac.abort(), 4000);
  try {
    const params = new URLSearchParams({
      sell_tokens: sell, buy_tokens: buy,
      sell_amounts: sellAmount.toString(),
      taker_address: BEBOPOL_ADDRESS,
      gasless: 'false', approval_type: 'Standard',
    });
    const resp = await fetch(`${BEBOP_API}/quote?${params}`, {
      headers: { 'Accept': 'application/json' },
      signal: ac.signal,
    });
    if (!resp.ok) return null;
    const data = await resp.json();
    if (!data.routes?.length) return null;
    const bestType = data.bestPrice;
    const route = data.routes.find(r => r.type === bestType) || data.routes[0];
    const q = route.quote;
    if (!q?.buyTokens || !q?.tx) return null;
    const buyInfo = Object.values(q.buyTokens)[0];
    if (!buyInfo?.amount) return null;
    return { buyAmount: buyInfo.amount, tx: q.tx };
  } finally { clearTimeout(tid); }
}
async function getBebopQuote(sellToken, buyToken, sellAmount, slippageBps) {
  // Bebop quote endpoint returns ready-to-use tx data (same as price but with taker)
  return getBebopPrice(sellToken, buyToken, sellAmount);
}

// Enso API helpers
function ensoToken(addr) {
  return addr === ZERO_ADDRESS ? ENSO_ETH_SENTINEL : addr;
}
async function _ensoFetch(sellToken, buyToken, sellAmount, slippageBps) {
  if (ENSOL_ADDRESS === ZERO_ADDRESS) return null;
  const ac = new AbortController();
  const tid = setTimeout(() => ac.abort(), 4000);
  try {
    const params = new URLSearchParams({
      chainId: '1', fromAddress: ENSOL_ADDRESS,
      tokenIn: ensoToken(sellToken), tokenOut: ensoToken(buyToken),
      amountIn: sellAmount.toString(), slippage: String(slippageBps || 50),
      routingStrategy: 'router',
    });
    const resp = await fetch(`${ENSO_API}?${params}`, {
      headers: { 'Accept': 'application/json' },
      signal: ac.signal,
    });
    if (!resp.ok) return null;
    const data = await resp.json();
    if (!data.amountOut || !data.tx) return null;
    return { amountOut: data.amountOut, tx: data.tx };
  } finally { clearTimeout(tid); }
}
async function getEnsoPrice(sellToken, buyToken, sellAmount) {
  return _ensoFetch(sellToken, buyToken, sellAmount, 50);
}
async function getEnsoQuote(sellToken, buyToken, sellAmount, slippageBps) {
  return _ensoFetch(sellToken, buyToken, sellAmount, slippageBps);
}

// OpenOcean API helpers
function ooToken(addr) {
  return addr === ZERO_ADDRESS ? OO_ETH_SENTINEL : addr;
}
async function getOpenOceanPrice(sellToken, buyToken, sellAmount) {
  if (OPENOCEANOL_ADDRESS === ZERO_ADDRESS) return null;
  if (providerIsDown('openocean')) return null;
  const ac = new AbortController();
  const tid = setTimeout(() => ac.abort(), 4000);
  try {
    const params = new URLSearchParams({
      inTokenAddress: ooToken(sellToken), outTokenAddress: ooToken(buyToken),
      amountDecimals: sellAmount.toString(), gasPriceDecimals: '20000000000',
      slippage: '0.5', account: OPENOCEANOL_ADDRESS,
    });
    const resp = await fetch(`${OPENOCEAN_API}/v4/eth/swap?${params}`, { signal: ac.signal });
    noteProviderResponse('openocean', resp.status);
    if (!resp.ok) return null;
    const json = await resp.json();
    const d = json?.data;
    if (!d?.outAmount || !d?.to || !d?.data) return null;
    return { outAmount: d.outAmount, tx: { to: d.to, data: d.data, value: d.value || '0' } };
  } finally { clearTimeout(tid); }
}
async function getOpenOceanQuote(sellToken, buyToken, sellAmount, slippageBps) {
  if (OPENOCEANOL_ADDRESS === ZERO_ADDRESS) return null;
  if (providerIsDown('openocean')) return null;
  const ac = new AbortController();
  const tid = setTimeout(() => ac.abort(), 5000);
  try {
    const params = new URLSearchParams({
      inTokenAddress: ooToken(sellToken), outTokenAddress: ooToken(buyToken),
      amountDecimals: sellAmount.toString(), gasPriceDecimals: '20000000000',
      slippage: (Number(slippageBps) / 100).toString(),
      account: OPENOCEANOL_ADDRESS,
    });
    const resp = await fetch(`${OPENOCEAN_API}/v4/eth/swap?${params}`, { signal: ac.signal });
    noteProviderResponse('openocean', resp.status);
    if (!resp.ok) return null;
    const json = await resp.json();
    const d = json?.data;
    if (!d?.outAmount || !d?.to || !d?.data) return null;
    return { outAmount: d.outAmount, tx: { to: d.to, data: d.data, value: d.value || '0' } };
  } finally { clearTimeout(tid); }
}

// CoW Protocol API helpers (ERC-20 only — no native ETH)
function cowToken(addr) {
  // CoW is ERC-20 only — substitute WETH for native ETH on sell side
  return addr === ZERO_ADDRESS ? WETH_ADDRESS : addr;
}
async function getCowPrice(sellToken, buyToken, sellAmount) {
  if (COWOL_ADDRESS === ZERO_ADDRESS) return null;
  // CoW cannot deliver native ETH (async settlement) — skip ETH buy side
  if (buyToken === ZERO_ADDRESS) return null;
  const ac = new AbortController();
  const tid = setTimeout(() => ac.abort(), 3000);
  try {
    const resp = await fetch(`${COW_API}/quote`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      signal: ac.signal,
      body: JSON.stringify({
        sellToken: cowToken(sellToken),
        buyToken,
        sellAmountBeforeFee: sellAmount.toString(),
        from: COWOL_ADDRESS,
        receiver: COWOL_ADDRESS,
        kind: "sell",
        signingScheme: "eip1271",
        appData: ethers.ZeroHash,
        partiallyFillable: false,
        sellTokenBalance: "erc20",
        buyTokenBalance: "erc20",
      }),
    });
    if (!resp.ok) return null;
    return resp.json();
  } finally { clearTimeout(tid); }
}
async function getCowQuote(sellToken, buyToken, sellAmount, receiver) {
  if (COWOL_ADDRESS === ZERO_ADDRESS) return null;
  const ac = new AbortController();
  const tid = setTimeout(() => ac.abort(), 8000);
  try {
    const resp = await fetch(`${COW_API}/quote`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        sellToken: cowToken(sellToken),
        buyToken,
        sellAmountBeforeFee: sellAmount.toString(),
        from: COWOL_ADDRESS,
        receiver,
        kind: "sell",
        signingScheme: "eip1271",
        appData: ethers.ZeroHash,
        partiallyFillable: false,
        sellTokenBalance: "erc20",
        buyTokenBalance: "erc20",
      }),
      signal: ac.signal,
    });
    if (!resp.ok) return null;
    return resp.json();
  } catch (_) { return null; } finally { clearTimeout(tid); }
}
function cowOrderData(q) {
  // abi.encode(buyToken, receiver, sellAmount, buyAmount, validTo, appData, feeAmount)
  return ethers.AbiCoder.defaultAbiCoder().encode(
    ["address", "address", "uint256", "uint256", "uint32", "bytes32", "uint256"],
    [q.buyToken, q.receiver, q.sellAmount, q.buyAmount, q.validTo, q.appData, q.feeAmount]
  );
}
async function postCowOrder(q) {
  const resp = await fetch(`${COW_API}/orders`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      sellToken: q.sellToken,
      buyToken: q.buyToken,
      receiver: q.receiver,
      sellAmount: q.sellAmount,
      buyAmount: q.buyAmount,
      validTo: q.validTo,
      appData: q.appData,
      feeAmount: q.feeAmount,
      kind: q.kind,
      partiallyFillable: q.partiallyFillable,
      sellTokenBalance: q.sellTokenBalance,
      buyTokenBalance: q.buyTokenBalance,
      from: COWOL_ADDRESS,
      signingScheme: "eip1271",
      signature: "0x",
    }),
  });
  if (!resp.ok) {
    const err = await resp.text().catch(() => "");
    throw new Error("CoW order failed: " + err);
  }
  return resp.json(); // returns orderUid string
}
