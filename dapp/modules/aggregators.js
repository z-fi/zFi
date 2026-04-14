// ---- External API price cache (15s TTL, LRU eviction, prevents re-fetch on rapid re-quotes) ----
const _extPriceCache = new Map();
const _extPriceInflight = new Map();
const _extPriceTTL = 15_000;
const _extPriceMaxSize = 100;
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

// Bitget API helpers (HMAC-SHA256 signed requests)
async function _bitgetSign(apiPath, body) {
  const ts = String(Date.now());
  const payload = JSON.stringify(Object.fromEntries(
    Object.entries({ apiPath, body: JSON.stringify(body), "x-api-key": BITGET_API_KEY, "x-api-timestamp": ts })
      .sort(([a], [b]) => a.localeCompare(b))
  ));
  const key = await crypto.subtle.importKey('raw', new TextEncoder().encode(BITGET_API_SECRET), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  const sig = await crypto.subtle.sign('HMAC', key, new TextEncoder().encode(payload));
  return { 'x-api-key': BITGET_API_KEY, 'x-api-timestamp': ts, 'x-api-signature': btoa(String.fromCharCode(...new Uint8Array(sig))), 'Content-Type': 'application/json' };
}
function bitgetToken(addr) {
  return addr === ZERO_ADDRESS ? "" : addr;
}
async function getBitgetPrice(sellToken, buyToken, sellAmount) {
  if (BITGETOL_ADDRESS === ZERO_ADDRESS) return null;
  const ac = new AbortController();
  const tid = setTimeout(() => ac.abort(), 3000);
  try {
    const body = { fromChain: "eth", toChain: "eth", fromContract: bitgetToken(sellToken), toContract: bitgetToken(buyToken), fromAmount: sellAmount.toString() };
    const headers = await _bitgetSign('/bgw-pro/swapx/pro/quote', body);
    const resp = await fetch(`${BITGET_API}/bgw-pro/swapx/pro/quote`, { method: 'POST', headers, body: JSON.stringify(body), signal: ac.signal });
    if (!resp.ok) return null;
    const json = await resp.json();
    if (json.status !== 0 || !json.data) return null;
    return json.data;
  } catch (_) { return null; } finally { clearTimeout(tid); }
}
async function getBitgetQuote(sellToken, buyToken, sellAmount, slippageBps) {
  if (BITGETOL_ADDRESS === ZERO_ADDRESS) return null;
  try {
    const priceBody = { fromChain: "eth", toChain: "eth", fromContract: bitgetToken(sellToken), toContract: bitgetToken(buyToken), fromAmount: sellAmount.toString() };
    const priceHeaders = await _bitgetSign('/bgw-pro/swapx/pro/quote', priceBody);
    const priceResp = await fetch(`${BITGET_API}/bgw-pro/swapx/pro/quote`, { method: 'POST', headers: priceHeaders, body: JSON.stringify(priceBody) });
    if (!priceResp.ok) return null;
    const priceJson = await priceResp.json();
    if (priceJson.status !== 0 || !priceJson.data) return null;
    const market = priceJson.data.market;
    const body = { fromChain: "eth", toChain: "eth", fromContract: bitgetToken(sellToken), toContract: bitgetToken(buyToken), fromAmount: sellAmount.toString(), fromAddress: BITGETOL_ADDRESS, toAddress: BITGETOL_ADDRESS, market, slippage: (Number(slippageBps) / 10000).toString() };
    const headers = await _bitgetSign('/bgw-pro/swapx/pro/swap', body);
    const resp = await fetch(`${BITGET_API}/bgw-pro/swapx/pro/swap`, { method: 'POST', headers, body: JSON.stringify(body) });
    if (!resp.ok) return null;
    const json = await resp.json();
    if (json.status !== 0 || !json.data) return null;
    return { tx: { to: json.data.contract, data: json.data.calldata }, toAmount: priceJson.data.toAmount };
  } catch (_) { return null; }
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
  const ac = new AbortController();
  const tid = setTimeout(() => ac.abort(), 4000);
  try {
    const params = new URLSearchParams({
      inTokenAddress: ooToken(sellToken), outTokenAddress: ooToken(buyToken),
      amountDecimals: sellAmount.toString(), gasPriceDecimals: '20000000000',
      slippage: '0.5', account: OPENOCEANOL_ADDRESS,
    });
    const resp = await fetch(`${OPENOCEAN_API}/v4/eth/swap?${params}`, { signal: ac.signal });
    if (!resp.ok) return null;
    const json = await resp.json();
    const d = json?.data;
    if (!d?.outAmount || !d?.to || !d?.data) return null;
    return { outAmount: d.outAmount, tx: { to: d.to, data: d.data, value: d.value || '0' } };
  } finally { clearTimeout(tid); }
}
async function getOpenOceanQuote(sellToken, buyToken, sellAmount, slippageBps) {
  if (OPENOCEANOL_ADDRESS === ZERO_ADDRESS) return null;
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
