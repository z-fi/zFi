// Cloudflare Worker: zFi On-Chain DEX Aggregator API
// Deploy: cd worker/api && wrangler deploy

const ZQUOTER = '0x9909861aa515afbce9d36c532eae7e0ebf804034';
const ZROUTER = '0x000000000000FB114709235f1ccBFfb925F600e4';
const MC3 = '0xcA11bde05977b3631167028862bE2a173976CA11';
const ZERO = '0x0000000000000000000000000000000000000000';
const WETH = '0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2';

const NATIVE = '0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE'; // common native ETH sentinel

// External aggregator APIs
const BEBOP_API = 'https://api.bebop.xyz/router/ethereum/v1/quote';
const ENSO_API = 'https://api.enso.build/api/v1/shortcuts/route';
const OX_API = 'https://api.0x.org';
const INCH_API = 'https://api.1inch.dev';
const OKX_API = 'https://web3.okx.com';
const KYBER_API = 'https://aggregator-api.kyberswap.com/ethereum/api/v1';
const ODOS_API = 'https://api.odos.xyz';
const PARASWAP_API = 'https://api.paraswap.io';
const BITGET_API = 'https://bopenapi.bgwapi.io';
const OPENOCEAN_API = 'https://open-api.openocean.finance';

// Approval targets (must match wrapper contracts)
const APPROVAL_TARGETS = {
  '0x': '0x0000000000001fF3684f28c67538d4D072C22734',         // AllowanceHolder
  '1inch': '0x111111125421cA6dc452d289314280a0f8842A65',       // AggregationRouterV6
  'OKX': '0x40aA958dd87FC8305b97f2BA922CDdCa374bcD7f',         // OKX TokenApprove
  'KyberSwap': '0x6131B5fae19EA4f9D964eAc0408E4408b66337b5',   // Meta Aggregation Router v2
  'Odos': '0x0D05a7D3448512B78fa8A9e46c4872C88C4a0D05',        // V3 SOR Router
  'Paraswap': '0x6A000F20005980200259B80c5102003040001068',     // Augustus v6.2
  'Enso': '0xF75584eF6673aD213a685a1B58Cc0330B8eA22Cf',        // Enso Router
  'Bitget': '0xd1ca1f4dbb645710f5d5a9917aa984a47524f49a',       // BKSwapRouter v2
  'OpenOcean': '0x6352a56caadC4F1E25CD6c75970Fa768A3304e64',     // Exchange V2
};

const RPCS = [
  'https://ethereum.publicnode.com',
  'https://1rpc.io/eth',
  'https://eth.drpc.org',
  'https://eth.llamarpc.com',
];

const AMM_NAMES = {
  0: 'Uniswap V2', 1: 'SushiSwap', 2: 'zAMM',
  3: 'Uniswap V3', 4: 'Uniswap V4', 5: 'Curve',
  6: 'Lido', 7: 'WETH Wrap', 8: 'V4 Hooked',
};

// --- Minimal ABI encoding/decoding (no dependencies) ---

function pad32(hex) { return hex.padStart(64, '0'); }
function encAddr(a) { return pad32(a.slice(2).toLowerCase()); }
function encUint(v) { return pad32(BigInt(v).toString(16)); }
function encBool(b) { return pad32(b ? '1' : '0'); }
function encInt24(v) {
  const n = Number(v);
  return pad32((n < 0 ? (BigInt(1) << 64n) + BigInt(n) : BigInt(n)).toString(16));
}

// Encode bytes value with offset pointer
function encBytes(hex) {
  const data = hex.startsWith('0x') ? hex.slice(2) : hex;
  const len = data.length / 2;
  return encUint(len) + data + '0'.repeat((32 - (len % 32)) % 32 * 2);
}

// Decode a uint256 from hex at byte offset
function decUint(hex, byteOff) {
  return BigInt('0x' + hex.slice(byteOff * 2, byteOff * 2 + 64));
}
function decAddr(hex, byteOff) {
  return '0x' + hex.slice(byteOff * 2 + 24, byteOff * 2 + 64);
}
function decBool(hex, byteOff) {
  return decUint(hex, byteOff) !== 0n;
}

// Decode a Quote struct (source, feeBps, amountIn, amountOut) = 4 slots
function decQuote(hex, byteOff) {
  return {
    source: Number(decUint(hex, byteOff)),
    feeBps: decUint(hex, byteOff + 32),
    amountIn: decUint(hex, byteOff + 64),
    amountOut: decUint(hex, byteOff + 96),
  };
}

// Decode dynamic bytes at an offset pointer
function decDynBytes(hex, baseOff, ptrOff) {
  const ptr = Number(decUint(hex, baseOff + ptrOff));
  const len = Number(decUint(hex, baseOff + ptr));
  return '0x' + hex.slice((baseOff + ptr + 32) * 2, (baseOff + ptr + 32 + len) * 2);
}

// --- Function selectors ---
// aggregate3(tuple(address,bool,bytes)[])
const SEL_AGGREGATE3 = '82ad56cb';
// buildBestSwapViaETHMulticall(address,address,bool,address,address,uint256,uint256,uint256,uint24,int24,address)
const SEL_BUILD_BEST = '19ce4350';
// buildSplitSwap(address,address,address,uint256,uint256,uint256)
const SEL_SPLIT = '892af013';
// buildHybridSplit(address,address,address,uint256,uint256,uint256)
const SEL_HYBRID = '85f86a90';
// getQuotes(bool,address,address,uint256)
const SEL_GET_QUOTES = 'e1fd10bc';
// quoteCurve(bool,address,address,uint256,uint256)
const SEL_QUOTE_CURVE = 'fdfd58fb';
// build3HopMulticall(address,address,address,uint256,uint256,uint256)
const SEL_3HOP = 'bd7f84ff';

// --- Encode zQuoter call data ---

function encGetQuotes(exactOut, tokenIn, tokenOut, amount) {
  return SEL_GET_QUOTES + encBool(exactOut) + encAddr(tokenIn) + encAddr(tokenOut) + encUint(amount);
}

function encQuoteCurve(exactOut, tokenIn, tokenOut, amount, maxCandidates) {
  return SEL_QUOTE_CURVE + encBool(exactOut) + encAddr(tokenIn) + encAddr(tokenOut) + encUint(amount) + encUint(maxCandidates);
}

function encBuildBest(to, refundTo, exactOut, tokenIn, tokenOut, amount, slippage, deadline) {
  return SEL_BUILD_BEST + encAddr(to) + encAddr(refundTo) + encBool(exactOut) +
    encAddr(tokenIn) + encAddr(tokenOut) + encUint(amount) + encUint(slippage) +
    encUint(deadline) + encUint(0) + encInt24(0) + encAddr(ZERO);
}

function encSplitSwap(to, tokenIn, tokenOut, amount, slippage, deadline) {
  return SEL_SPLIT + encAddr(to) + encAddr(tokenIn) + encAddr(tokenOut) +
    encUint(amount) + encUint(slippage) + encUint(deadline);
}

function encHybridSplit(to, tokenIn, tokenOut, amount, slippage, deadline) {
  return SEL_HYBRID + encAddr(to) + encAddr(tokenIn) + encAddr(tokenOut) +
    encUint(amount) + encUint(slippage) + encUint(deadline);
}

function enc3Hop(to, tokenIn, tokenOut, amount, slippage, deadline) {
  return SEL_3HOP + encAddr(to) + encAddr(tokenIn) + encAddr(tokenOut) +
    encUint(amount) + encUint(slippage) + encUint(deadline);
}

// --- Encode Multicall3 aggregate3 ---

function encAggregate3(calls) {
  // aggregate3(tuple(address target, bool allowFailure, bytes callData)[])
  // Dynamic array: offset to array, then length, then each tuple
  // Each tuple is (address, bool, bytes) where bytes is dynamic → each element has an offset
  const n = calls.length;
  // Header: selector + offset to array data
  let result = SEL_AGGREGATE3 + pad32('20'); // offset to array = 32 bytes

  // Array: length + offsets to each element
  result += encUint(n);

  // Each element needs an offset pointer (relative to start of array data after length)
  // We'll build element encodings first to calculate offsets
  const elements = [];
  for (const c of calls) {
    const cd = c.data.startsWith('0x') ? c.data.slice(2) : c.data;
    const cdLen = cd.length / 2;
    const cdPadded = cd + '0'.repeat((32 - (cdLen % 32)) % 32 * 2);
    // Element: address (32) + bool (32) + offset to bytes (32) + bytes length (32) + bytes data (padded)
    const elem = encAddr(c.target) + encBool(true) + pad32('60') + // offset to callData = 96 (3 * 32)
      encUint(cdLen) + cdPadded;
    elements.push(elem);
  }

  // Offset to each element (relative to start of elements section)
  let offset = n * 32; // skip past offset array
  for (const elem of elements) {
    result += pad32(offset.toString(16));
    offset += elem.length / 2;
  }

  // Element data
  for (const elem of elements) {
    result += elem;
  }

  return '0x' + result;
}

// --- Decode Multicall3 aggregate3 result ---

function decAggregate3(hex) {
  // Returns: tuple(bool success, bytes returnData)[]
  const d = hex.startsWith('0x') ? hex.slice(2) : hex;
  // First word: offset to array
  const arrOff = Number(BigInt('0x' + d.slice(0, 64)));
  const arrStart = arrOff * 2;
  const n = Number(BigInt('0x' + d.slice(arrStart, arrStart + 64)));
  const results = [];
  // Offset pointers to each element
  for (let i = 0; i < n; i++) {
    const ptrHex = d.slice(arrStart + 64 + i * 64, arrStart + 128 + i * 64);
    const elemOff = Number(BigInt('0x' + ptrHex));
    const elemStart = arrStart + 64 + elemOff * 2;
    const success = BigInt('0x' + d.slice(elemStart, elemStart + 64)) !== 0n;
    // returnData: offset, then length, then data
    const rdOff = Number(BigInt('0x' + d.slice(elemStart + 64, elemStart + 128)));
    const rdStart = elemStart + rdOff * 2;
    const rdLen = Number(BigInt('0x' + d.slice(rdStart, rdStart + 64)));
    const returnData = d.slice(rdStart + 64, rdStart + 64 + rdLen * 2);
    results.push({ success, returnData });
  }
  return results;
}

// --- Decode zQuoter return data ---

// buildBestSwapViaETHMulticall → (Quote a, Quote b, bytes[] calls, bytes multicall, uint256 msgValue)
function decBuildBest(hex) {
  // a: slots 0-3, b: slots 4-7 (static), then dynamic: calls offset, multicall offset, msgValue
  const a = decQuote(hex, 0);
  const b = decQuote(hex, 128);
  // slot 8: offset to calls array (bytes[])
  // slot 9: offset to multicall (bytes)
  // slot 10: msgValue
  const msgValue = decUint(hex, 320); // slot 10 = 10*32 = 320
  const multicall = decDynBytes(hex, 0, 288); // slot 9 ptr
  return { a, b, multicall, msgValue };
}

// buildSplitSwap / buildHybridSplit → (Quote[2] legs, bytes multicall, uint256 msgValue)
function decSplit(hex) {
  // Quote[2] is static: 8 slots (2 * 4)
  const leg0 = decQuote(hex, 0);
  const leg1 = decQuote(hex, 128);
  // slot 8: offset to multicall, slot 9: msgValue
  const msgValue = decUint(hex, 288); // slot 9
  const multicall = decDynBytes(hex, 0, 256); // slot 8 ptr
  return { legs: [leg0, leg1], multicall, msgValue };
}

// build3HopMulticall → (Quote a, Quote b, Quote c, bytes[] calls, bytes multicall, uint256 msgValue)
function dec3Hop(hex) {
  const a = decQuote(hex, 0);
  const b = decQuote(hex, 128);
  const c = decQuote(hex, 256);
  // slot 12: offset to calls, slot 13: offset to multicall, slot 14: msgValue
  const msgValue = decUint(hex, 448); // slot 14
  const multicall = decDynBytes(hex, 0, 416); // slot 13 ptr
  return { a, b, c, multicall, msgValue };
}

// getQuotes → (Quote best, Quote[] quotes)
function decGetQuotes(hex) {
  const best = decQuote(hex, 0);
  // slot 4: offset to dynamic Quote[] array
  const arrPtr = Number(decUint(hex, 128));
  const arrLen = Number(decUint(hex, arrPtr));
  const quotes = [];
  for (let i = 0; i < arrLen; i++) {
    quotes.push(decQuote(hex, arrPtr + 32 + i * 128));
  }
  return { best, quotes };
}

// quoteCurve → (uint256 amountIn, uint256 amountOut, address bestPool, bool, bool, uint8, uint8)
function decQuoteCurve(hex) {
  return {
    amountIn: decUint(hex, 0),
    amountOut: decUint(hex, 32),
  };
}

// --- RPC call with fallback ---

async function rpcCall(to, data) {
  const body = JSON.stringify({
    jsonrpc: '2.0', id: 1, method: 'eth_call',
    params: [{ to, data }, 'latest'],
  });
  let lastErr;
  for (const url of RPCS) {
    try {
      const res = await fetch(url, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body,
        signal: AbortSignal.timeout(3000),
      });
      const json = await res.json();
      if (json.error) { lastErr = json.error.message || JSON.stringify(json.error); continue; }
      if (!json.result || json.result === '0x') { lastErr = 'empty result'; continue; }
      return json.result;
    } catch (e) { lastErr = e.message; }
  }
  throw new Error('All RPCs failed: ' + lastErr);
}

// --- Bebop quote fetcher ---

async function fetchBebopQuote(tokenIn, tokenOut, amount, taker) {
  // Bebop uses WETH address for native ETH
  const sellToken = tokenIn.toLowerCase() === ZERO.toLowerCase() ? WETH : tokenIn;
  const buyToken = tokenOut.toLowerCase() === ZERO.toLowerCase() ? WETH : tokenOut;
  // Skip pure WETH wrap/unwrap
  if (sellToken.toLowerCase() === buyToken.toLowerCase()) return null;

  const params = new URLSearchParams({
    sell_tokens: sellToken,
    buy_tokens: buyToken,
    sell_amounts: amount.toString(),
    taker_address: taker || '0x0000000000000000000000000000000000000001',
    gasless: 'false',
    approval_type: 'Standard',
  });

  try {
    const res = await fetch(`${BEBOP_API}?${params}`, {
      headers: { 'Accept': 'application/json' },
      signal: AbortSignal.timeout(4000),
    });
    if (!res.ok) return null;
    const data = await res.json();
    if (!data.routes?.length) return null;

    // Router API returns routes[] with bestPrice indicating the winner
    const bestType = data.bestPrice;
    const route = data.routes.find(r => r.type === bestType) || data.routes[0];
    const q = route.quote;
    if (!q?.buyTokens || !q?.tx) return null;

    // Extract output amount from buyTokens map
    const buyInfo = Object.values(q.buyTokens)[0];
    if (!buyInfo?.amount) return null;

    return {
      amountOut: BigInt(buyInfo.amount),
      tx: { to: q.tx.to, data: q.tx.data, value: BigInt(q.tx.value || 0).toString() },
      settlementAddress: q.settlementAddress,
      approvalTarget: q.approvalTarget,
    };
  } catch {
    return null;
  }
}

// --- Enso quote fetcher ---

async function fetchEnsoQuote(tokenIn, tokenOut, amount, taker, env) {
  // Enso uses 0xeeee...eeee for native ETH
  const sellToken = tokenIn.toLowerCase() === ZERO.toLowerCase() ? NATIVE : tokenIn;
  const buyToken = tokenOut.toLowerCase() === ZERO.toLowerCase() ? NATIVE : tokenOut;
  if (sellToken.toLowerCase() === buyToken.toLowerCase()) return null;

  // Enso rejects null/precompile addresses — use a real dummy if no taker
  const from = taker || '0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045';

  const params = new URLSearchParams({
    chainId: '1',
    fromAddress: from,
    tokenIn: sellToken,
    tokenOut: buyToken,
    amountIn: amount.toString(),
    slippage: '50',
    routingStrategy: 'router',
  });

  const headers = { 'Accept': 'application/json' };
  if (env?.ENSO_API_KEY) headers['Authorization'] = `Bearer ${env.ENSO_API_KEY}`;

  try {
    const res = await fetch(`${ENSO_API}?${params}`, {
      headers,
      signal: AbortSignal.timeout(4000),
    });
    if (!res.ok) return null;
    const data = await res.json();
    if (!data.amountOut || !data.tx) return null;

    return {
      amountOut: BigInt(data.amountOut),
      tx: { to: data.tx.to, data: data.tx.data, value: BigInt(data.tx.value || 0).toString() },
    };
  } catch {
    return null;
  }
}

// --- 0x (Matcha) quote fetcher ---

async function fetchOxQuote(tokenIn, tokenOut, amount, taker, env) {
  if (!env?.OX_API_KEY) return null;
  const sellToken = tokenIn.toLowerCase() === ZERO.toLowerCase() ? NATIVE : tokenIn;
  const buyToken = tokenOut.toLowerCase() === ZERO.toLowerCase() ? NATIVE : tokenOut;
  if (sellToken.toLowerCase() === buyToken.toLowerCase()) return null;

  const params = new URLSearchParams({
    chainId: '1',
    sellToken,
    buyToken,
    sellAmount: amount.toString(),
    taker: taker || '0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045',
    slippageBps: '50',
  });

  try {
    const res = await fetch(`${OX_API}/swap/allowance-holder/quote?${params}`, {
      headers: { '0x-api-key': env.OX_API_KEY, '0x-version': 'v2' },
      signal: AbortSignal.timeout(4000),
    });
    if (!res.ok) return null;
    const data = await res.json();
    if (!data.buyAmount || !data.transaction) return null;

    return {
      amountOut: BigInt(data.buyAmount),
      tx: { to: data.transaction.to, data: data.transaction.data, value: String(data.transaction.value || '0') },
      approvalTarget: APPROVAL_TARGETS['0x'],
    };
  } catch {
    return null;
  }
}

// --- 1inch quote fetcher ---

async function fetchInchQuote(tokenIn, tokenOut, amount, taker, env) {
  if (!env?.INCH_API_KEY) return null;
  const src = tokenIn.toLowerCase() === ZERO.toLowerCase() ? NATIVE : tokenIn;
  const dst = tokenOut.toLowerCase() === ZERO.toLowerCase() ? NATIVE : tokenOut;
  if (src.toLowerCase() === dst.toLowerCase()) return null;

  const from = taker || '0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045';
  const params = new URLSearchParams({
    src, dst, amount: amount.toString(), from,
    slippage: '0.5', disableEstimate: 'true',
  });

  try {
    const res = await fetch(`${INCH_API}/swap/v6.0/1/swap?${params}`, {
      headers: { 'Authorization': `Bearer ${env.INCH_API_KEY}` },
      signal: AbortSignal.timeout(4000),
    });
    if (!res.ok) return null;
    const data = await res.json();
    if (!data.dstAmount || !data.tx) return null;

    return {
      amountOut: BigInt(data.dstAmount),
      tx: { to: data.tx.to, data: data.tx.data, value: String(data.tx.value || '0') },
      approvalTarget: APPROVAL_TARGETS['1inch'],
    };
  } catch {
    return null;
  }
}

// --- OKX quote fetcher ---

async function fetchOkxQuote(tokenIn, tokenOut, amount, taker, env) {
  if (!env?.OKX_API_KEY || !env?.OKX_SECRET_KEY || !env?.OKX_PASSPHRASE) return null;
  const fromToken = tokenIn.toLowerCase() === ZERO.toLowerCase() ? NATIVE : tokenIn;
  const toToken = tokenOut.toLowerCase() === ZERO.toLowerCase() ? NATIVE : tokenOut;
  if (fromToken.toLowerCase() === toToken.toLowerCase()) return null;

  const userAddr = taker || '0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045';
  const qs = new URLSearchParams({
    chainId: '1', fromTokenAddress: fromToken, toTokenAddress: toToken,
    amount: amount.toString(), userWalletAddress: userAddr, slippage: '0.005',
  }).toString();

  const requestPath = '/api/v6/dex/aggregator/swap';
  const timestamp = new Date().toISOString();
  const stringToSign = timestamp + 'GET' + requestPath + '?' + qs;

  try {
    const key = await crypto.subtle.importKey(
      'raw', new TextEncoder().encode(env.OKX_SECRET_KEY),
      { name: 'HMAC', hash: 'SHA-256' }, false, ['sign'],
    );
    const sig = btoa(String.fromCharCode(...new Uint8Array(
      await crypto.subtle.sign('HMAC', key, new TextEncoder().encode(stringToSign)),
    )));

    const res = await fetch(`${OKX_API}${requestPath}?${qs}`, {
      headers: {
        'OK-ACCESS-KEY': env.OKX_API_KEY,
        'OK-ACCESS-SIGN': sig,
        'OK-ACCESS-TIMESTAMP': timestamp,
        'OK-ACCESS-PASSPHRASE': env.OKX_PASSPHRASE,
      },
      signal: AbortSignal.timeout(4000),
    });
    if (!res.ok) return null;
    const data = await res.json();
    const route = data?.data?.[0];
    if (!route?.routerResult?.toTokenAmount || !route?.tx) return null;

    return {
      amountOut: BigInt(route.routerResult.toTokenAmount),
      tx: { to: route.tx.to, data: route.tx.data, value: String(route.tx.value || '0') },
      approvalTarget: APPROVAL_TARGETS['OKX'],
    };
  } catch {
    return null;
  }
}

// --- KyberSwap quote fetcher (two-step: routes → build) ---

async function fetchKyberQuote(tokenIn, tokenOut, amount, taker) {
  const sellToken = tokenIn.toLowerCase() === ZERO.toLowerCase() ? NATIVE : tokenIn;
  const buyToken = tokenOut.toLowerCase() === ZERO.toLowerCase() ? NATIVE : tokenOut;
  if (sellToken.toLowerCase() === buyToken.toLowerCase()) return null;

  const from = taker || '0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045';

  try {
    // Step 1: get route
    const routeParams = new URLSearchParams({
      tokenIn: sellToken, tokenOut: buyToken, amountIn: amount.toString(), saveGas: 'false',
    });
    const routeRes = await fetch(`${KYBER_API}/routes?${routeParams}`, {
      headers: { 'x-client-id': 'zfi' },
      signal: AbortSignal.timeout(2500),
    });
    if (!routeRes.ok) return null;
    const routeData = await routeRes.json();
    const routeSummary = routeData?.data?.routeSummary;
    if (!routeSummary?.amountOut) return null;

    // Step 2: build tx
    const buildRes = await fetch(`${KYBER_API}/route/build`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'x-client-id': 'zfi' },
      body: JSON.stringify({ routeSummary, sender: from, recipient: from, slippageTolerance: 50 }),
      signal: AbortSignal.timeout(2500),
    });
    if (!buildRes.ok) return null;
    const buildData = await buildRes.json();
    const bd = buildData?.data;
    if (!bd?.data || !bd?.routerAddress) return null;

    const isEthIn = tokenIn.toLowerCase() === ZERO.toLowerCase();
    return {
      amountOut: BigInt(routeSummary.amountOut),
      tx: { to: bd.routerAddress, data: bd.data, value: isEthIn ? amount.toString() : '0' },
      approvalTarget: APPROVAL_TARGETS['KyberSwap'],
    };
  } catch {
    return null;
  }
}

// --- Odos quote fetcher (two-step: quote → assemble) ---

async function fetchOdosQuote(tokenIn, tokenOut, amount, taker) {
  // Odos uses zero address for native ETH
  const sellToken = tokenIn.toLowerCase() === ZERO.toLowerCase() ? ZERO : tokenIn;
  const buyToken = tokenOut.toLowerCase() === ZERO.toLowerCase() ? ZERO : tokenOut;
  if (sellToken.toLowerCase() === buyToken.toLowerCase()) return null;

  const userAddr = taker || '0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045';

  try {
    // Step 1: quote
    const quoteRes = await fetch(`${ODOS_API}/sor/quote/v2`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        chainId: 1,
        inputTokens: [{ tokenAddress: sellToken, amount: amount.toString() }],
        outputTokens: [{ tokenAddress: buyToken, proportion: 1 }],
        slippageLimitPercent: 0.5,
        userAddr,
      }),
      signal: AbortSignal.timeout(2500),
    });
    if (!quoteRes.ok) return null;
    const quoteData = await quoteRes.json();
    if (!quoteData.pathId || !quoteData.outAmounts?.[0]) return null;
    const outAmount = BigInt(quoteData.outAmounts[0]);

    // Step 2: assemble
    const asmRes = await fetch(`${ODOS_API}/sor/assemble`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ userAddr, pathId: quoteData.pathId }),
      signal: AbortSignal.timeout(2500),
    });
    if (!asmRes.ok) return null;
    const asmData = await asmRes.json();
    if (!asmData.transaction?.to || !asmData.transaction?.data) return null;

    return {
      amountOut: outAmount,
      tx: { to: asmData.transaction.to, data: asmData.transaction.data, value: String(asmData.transaction.value || '0') },
      approvalTarget: APPROVAL_TARGETS['Odos'],
    };
  } catch {
    return null;
  }
}

// --- Paraswap quote fetcher (two-step: prices → transactions) ---

async function fetchParaswapQuote(tokenIn, tokenOut, amount, taker) {
  const srcToken = tokenIn.toLowerCase() === ZERO.toLowerCase() ? NATIVE : tokenIn;
  const destToken = tokenOut.toLowerCase() === ZERO.toLowerCase() ? NATIVE : tokenOut;
  if (srcToken.toLowerCase() === destToken.toLowerCase()) return null;

  const userAddr = taker || '0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045';

  try {
    // Step 1: price quote
    const priceParams = new URLSearchParams({
      srcToken, destToken, amount: amount.toString(), network: '1', side: 'SELL',
    });
    const priceRes = await fetch(`${PARASWAP_API}/prices?${priceParams}`, {
      signal: AbortSignal.timeout(2500),
    });
    if (!priceRes.ok) return null;
    const priceData = await priceRes.json();
    const priceRoute = priceData?.priceRoute;
    if (!priceRoute?.destAmount) return null;
    const destAmount = BigInt(priceRoute.destAmount);

    // Step 2: build tx
    const txRes = await fetch(`${PARASWAP_API}/transactions/1?ignoreChecks=true`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        srcToken: priceRoute.srcToken, destToken: priceRoute.destToken,
        srcAmount: priceRoute.srcAmount, slippage: 50,
        priceRoute, userAddress: userAddr, txOrigin: userAddr,
      }),
      signal: AbortSignal.timeout(2500),
    });
    if (!txRes.ok) return null;
    const txData = await txRes.json();
    if (!txData.to || !txData.data) return null;

    return {
      amountOut: destAmount,
      tx: { to: txData.to, data: txData.data, value: String(txData.value || '0') },
      approvalTarget: APPROVAL_TARGETS['Paraswap'],
    };
  } catch {
    return null;
  }
}

// --- Bitget quote fetcher (two-step: quote → swap, HMAC-SHA256 auth) ---

async function bitgetSign(apiPath, bodyStr, env) {
  const timestamp = Date.now().toString();
  const content = { apiPath, body: bodyStr, 'x-api-key': env.BITGET_API_KEY, 'x-api-timestamp': timestamp };
  const sorted = Object.fromEntries(Object.keys(content).sort().map(k => [k, content[k]]));
  const key = await crypto.subtle.importKey(
    'raw', new TextEncoder().encode(env.BITGET_SECRET_KEY),
    { name: 'HMAC', hash: 'SHA-256' }, false, ['sign'],
  );
  const sig = btoa(String.fromCharCode(...new Uint8Array(
    await crypto.subtle.sign('HMAC', key, new TextEncoder().encode(JSON.stringify(sorted))),
  )));
  return {
    'x-api-key': env.BITGET_API_KEY,
    'x-api-timestamp': timestamp,
    'x-api-signature': sig,
    'Content-Type': 'application/json',
  };
}

async function fetchBitgetQuote(tokenIn, tokenOut, amount, taker, env) {
  if (!env?.BITGET_API_KEY || !env?.BITGET_SECRET_KEY) return null;
  // Bitget uses empty string for native ETH
  const fromContract = tokenIn.toLowerCase() === ZERO.toLowerCase() ? '' : tokenIn;
  const toContract = tokenOut.toLowerCase() === ZERO.toLowerCase() ? '' : tokenOut;
  if (fromContract === toContract) return null;

  const userAddr = taker || '0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045';

  try {
    // Step 1: quote
    const quotePath = '/bgw-pro/swapx/pro/quote';
    const quoteBodyStr = JSON.stringify({
      fromContract, toContract, fromAmount: amount.toString(),
      fromChain: 'ETH', toChain: 'ETH',
    });
    const quoteHeaders = await bitgetSign(quotePath, quoteBodyStr, env);
    const quoteRes = await fetch(`${BITGET_API}${quotePath}`, {
      method: 'POST', headers: quoteHeaders,
      body: quoteBodyStr,
      signal: AbortSignal.timeout(3000),
    });
    if (!quoteRes.ok) return null;
    const quoteData = await quoteRes.json();
    const qd = quoteData?.data;
    if (!qd?.toAmount) return null;
    const outAmount = BigInt(qd.toAmount);
    const market = qd.market;

    // Step 2: build tx
    const swapPath = '/bgw-pro/swapx/pro/swap';
    const swapBodyStr = JSON.stringify({
      fromContract, toContract, fromAmount: amount.toString(),
      fromChain: 'ETH', toChain: 'ETH',
      fromAddress: userAddr, toAddress: userAddr,
      market, slippage: '0.5',
    });
    const swapHeaders = await bitgetSign(swapPath, swapBodyStr, env);
    const swapRes = await fetch(`${BITGET_API}${swapPath}`, {
      method: 'POST', headers: swapHeaders,
      body: swapBodyStr,
      signal: AbortSignal.timeout(3000),
    });
    if (!swapRes.ok) return null;
    const swapData = await swapRes.json();
    const sd = swapData?.data;
    if (!sd?.calldata || !sd?.contract) return null;

    const isEthIn = tokenIn.toLowerCase() === ZERO.toLowerCase();
    return {
      amountOut: outAmount,
      tx: { to: sd.contract, data: sd.calldata, value: isEthIn ? amount.toString() : '0' },
      approvalTarget: sd.contract,
    };
  } catch {
    return null;
  }
}

// --- OpenOcean quote fetcher (one-step GET, no auth) ---

async function fetchOpenOceanQuote(tokenIn, tokenOut, amount, taker) {
  const sellToken = tokenIn.toLowerCase() === ZERO.toLowerCase() ? NATIVE : tokenIn;
  const buyToken = tokenOut.toLowerCase() === ZERO.toLowerCase() ? NATIVE : tokenOut;
  if (sellToken.toLowerCase() === buyToken.toLowerCase()) return null;

  const userAddr = taker || '0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045';
  const params = new URLSearchParams({
    inTokenAddress: sellToken,
    outTokenAddress: buyToken,
    amountDecimals: amount.toString(),
    gasPriceDecimals: '20000000000',
    slippage: '0.5',
    account: userAddr,
  });

  try {
    const res = await fetch(`${OPENOCEAN_API}/v4/eth/swap?${params}`, {
      signal: AbortSignal.timeout(4000),
    });
    if (!res.ok) return null;
    const json = await res.json();
    const d = json?.data;
    if (!d?.outAmount || !d?.to || !d?.data) return null;

    return {
      amountOut: BigInt(d.outAmount),
      tx: { to: d.to, data: d.data, value: String(d.value || '0') },
      approvalTarget: APPROVAL_TARGETS['OpenOcean'],
    };
  } catch {
    return null;
  }
}

// --- Main quote logic ---

async function getQuote(params, env) {
  const { tokenIn, tokenOut, amount, to, slippage, exactOut } = params;
  const receiver = to || ZERO;
  const refundTo = to || ZERO;
  const slippageBps = slippage || 50;
  const splitSlip = Math.min(Math.max(slippageBps * 3, 150), 500);
  const deadline = BigInt(Math.trunc(Date.now() / 1000) + 300);

  // Build all zQuoter calls
  const lightCalls = [
    { target: ZQUOTER, data: '0x' + encGetQuotes(!!exactOut, tokenIn, tokenOut, amount) },
    { target: ZQUOTER, data: '0x' + encQuoteCurve(!!exactOut, tokenIn, tokenOut, amount, 8) },
  ];
  const heavyCalls = [
    { target: ZQUOTER, data: '0x' + encBuildBest(receiver, refundTo, !!exactOut, tokenIn, tokenOut, amount, slippageBps, deadline) },
    { target: ZQUOTER, data: '0x' + encSplitSwap(receiver, tokenIn, tokenOut, amount, splitSlip, deadline) },
    { target: ZQUOTER, data: '0x' + encHybridSplit(receiver, tokenIn, tokenOut, amount, splitSlip, deadline) },
    { target: ZQUOTER, data: '0x' + enc3Hop(receiver, tokenIn, tokenOut, amount, splitSlip, deadline) },
  ];

  // Batch zQuoter multicalls + all external APIs in parallel
  const skip = exactOut ? Promise.resolve(null) : undefined;
  const [lightRaw, heavyRaw, ...extQuotes] = await Promise.all([
    rpcCall(MC3, encAggregate3(lightCalls)),
    rpcCall(MC3, encAggregate3(heavyCalls)),
    skip || fetchBebopQuote(tokenIn, tokenOut, amount, to),
    skip || fetchEnsoQuote(tokenIn, tokenOut, amount, to, env),
    skip || fetchOxQuote(tokenIn, tokenOut, amount, to, env),
    skip || fetchInchQuote(tokenIn, tokenOut, amount, to, env),
    skip || fetchOkxQuote(tokenIn, tokenOut, amount, to, env),
    skip || fetchKyberQuote(tokenIn, tokenOut, amount, to),
    skip || fetchOdosQuote(tokenIn, tokenOut, amount, to),
    skip || fetchParaswapQuote(tokenIn, tokenOut, amount, to),
    skip || fetchBitgetQuote(tokenIn, tokenOut, amount, to, env),
    skip || fetchOpenOceanQuote(tokenIn, tokenOut, amount, to),
  ]);
  const extNames = ['Bebop', 'Enso', '0x', '1inch', 'OKX', 'KyberSwap', 'Odos', 'Paraswap', 'Bitget', 'OpenOcean'];

  const lightMc3 = decAggregate3(lightRaw);
  const heavyMc3 = decAggregate3(heavyRaw);

  // Decode heavy: buildBest (idx 0), split (1), hybrid (2), 3hop (3)
  let bestOutput = 0n, bestMulticall = null, bestMsgValue = 0n;
  let bestSource = 'Unknown', bestIsTwoHop = false, bestIsSplit = false;

  // 1. buildBestSwapViaETHMulticall
  if (heavyMc3[0]?.success) {
    try {
      const r = decBuildBest(heavyMc3[0].returnData);
      const isTwoHop = r.b.amountOut > 0n;
      const output = isTwoHop ? r.b.amountOut : r.a.amountOut;
      if (output > bestOutput) {
        bestOutput = output;
        bestMulticall = r.multicall;
        bestMsgValue = r.msgValue;
        bestIsTwoHop = isTwoHop;
        bestIsSplit = false;
        bestSource = AMM_NAMES[r.a.source] || 'Unknown';
        if (isTwoHop) bestSource += ' → ' + (AMM_NAMES[r.b.source] || 'Unknown');
      }
    } catch (_) {}
  }

  // 2. buildSplitSwap
  if (heavyMc3[1]?.success) {
    try {
      const s = decSplit(heavyMc3[1].returnData);
      const splitTotal = s.legs[0].amountOut + s.legs[1].amountOut;
      const bothActive = s.legs[0].amountOut > 0n && s.legs[1].amountOut > 0n;
      // Skip if Curve leg with native ETH input (known issue with swapCurve calldata)
      const hasCurve = tokenIn.toLowerCase() === ZERO.toLowerCase() && (s.legs[0].source === 5 || s.legs[1].source === 5);
      if (splitTotal > bestOutput && bothActive && !hasCurve) {
        bestOutput = splitTotal;
        bestMulticall = s.multicall;
        bestMsgValue = s.msgValue;
        bestIsTwoHop = false;
        bestIsSplit = true;
        bestSource = (AMM_NAMES[s.legs[0].source] || '?') + ' + ' + (AMM_NAMES[s.legs[1].source] || '?');
      }
    } catch (_) {}
  }

  // 3. buildHybridSplit
  if (heavyMc3[2]?.success) {
    try {
      const hs = decSplit(heavyMc3[2].returnData);
      const hsTotal = hs.legs[0].amountOut + hs.legs[1].amountOut;
      const hasCurve = tokenIn.toLowerCase() === ZERO.toLowerCase() && (hs.legs[0].source === 5 || hs.legs[1].source === 5);
      if (hsTotal > bestOutput && hsTotal > 0n && !hasCurve) {
        bestOutput = hsTotal;
        bestMulticall = hs.multicall;
        bestMsgValue = hs.msgValue;
        const isTrueSplit = hs.legs[0].amountOut > 0n && hs.legs[1].amountOut > 0n;
        bestIsSplit = isTrueSplit;
        bestIsTwoHop = !isTrueSplit && hs.legs[1].amountOut > 0n;
        if (isTrueSplit) {
          bestSource = (AMM_NAMES[hs.legs[0].source] || '?') + ' + ' + (AMM_NAMES[hs.legs[1].source] || '?') + ' (hybrid)';
        } else {
          const active = hs.legs[0].amountOut > 0n ? hs.legs[0] : hs.legs[1];
          bestSource = AMM_NAMES[active.source] || 'Unknown';
        }
      }
    } catch (_) {}
  }

  // 4. build3HopMulticall
  if (heavyMc3[3]?.success) {
    try {
      const h3 = dec3Hop(heavyMc3[3].returnData);
      const h3Output = h3.c.amountOut;
      const hasCurve = tokenIn.toLowerCase() === ZERO.toLowerCase() && (h3.a.source === 5 || h3.b.source === 5 || h3.c.source === 5);
      if (h3Output > bestOutput && h3Output > 0n && !hasCurve) {
        bestOutput = h3Output;
        bestMulticall = h3.multicall;
        bestMsgValue = h3.msgValue;
        bestIsTwoHop = true;
        bestIsSplit = false;
        bestSource = (AMM_NAMES[h3.a.source] || '?') + ' → ' + (AMM_NAMES[h3.b.source] || '?') + ' → ' + (AMM_NAMES[h3.c.source] || '?');
      }
    } catch (_) {}
  }

  // 5. External aggregators
  let bestExternal = null;
  for (let i = 0; i < extQuotes.length; i++) {
    const eq = extQuotes[i];
    if (!eq || !eq.amountOut || eq.amountOut <= 0n) continue;
    if (eq.amountOut > bestOutput) {
      bestOutput = eq.amountOut;
      bestMulticall = null;
      bestMsgValue = 0n;
      bestIsTwoHop = false;
      bestIsSplit = false;
      bestSource = extNames[i];
      bestExternal = eq;
    }
  }

  const hasAnyExternal = extQuotes.some(q => q && q.amountOut > 0n);
  if (!bestMulticall && !hasAnyExternal) {
    throw new Error('No viable route found');
  }

  // Build allQuotes from light calls
  const allQuotes = [];
  if (lightMc3[0]?.success) {
    try {
      const q = decGetQuotes(lightMc3[0].returnData);
      for (const qt of q.quotes) {
        if (qt.amountOut > 0n) {
          allQuotes.push({
            source: AMM_NAMES[qt.source] || `AMM #${qt.source}`,
            amountOut: qt.amountOut.toString(),
          });
        }
      }
    } catch (_) {}
  }
  if (lightMc3[1]?.success) {
    try {
      const c = decQuoteCurve(lightMc3[1].returnData);
      if (c.amountOut > 0n) {
        allQuotes.push({ source: 'Curve', amountOut: c.amountOut.toString() });
      }
    } catch (_) {}
  }

  // Add all external aggregator quotes
  for (let i = 0; i < extQuotes.length; i++) {
    const eq = extQuotes[i];
    if (eq && eq.amountOut > 0n) {
      allQuotes.push({ source: extNames[i], amountOut: eq.amountOut.toString() });
    }
  }

  // Add zQuoter composite route (split/hybrid/3hop) if it won over individual AMM quotes
  if (!bestExternal && bestOutput > 0n) {
    const already = allQuotes.some(q => q.amountOut === bestOutput.toString());
    if (!already) {
      allQuotes.push({ source: bestSource, amountOut: bestOutput.toString() });
    }
  }

  // Sort allQuotes by amountOut descending
  allQuotes.sort((a, b) => (BigInt(b.amountOut) > BigInt(a.amountOut) ? 1 : -1));

  // Determine ETH value to attach
  const isETHInput = tokenIn.toLowerCase() === ZERO.toLowerCase();

  // Build tx object — external aggregators return their own tx, zQuoter routes through zRouter
  let tx;
  if (bestExternal) {
    tx = {
      to: bestExternal.tx.to,
      data: bestExternal.tx.data,
      value: String(bestExternal.tx.value || '0'),
    };
  } else {
    tx = {
      to: ZROUTER,
      data: bestMulticall,
      value: isETHInput ? bestMsgValue.toString() : '0',
    };
  }

  return {
    bestRoute: {
      expectedOutput: bestOutput.toString(),
      source: bestSource,
      isTwoHop: bestIsTwoHop,
      isSplit: bestIsSplit,
    },
    tx,
    allQuotes,
    approvalTarget: bestExternal
      ? (bestExternal.approvalTarget || APPROVAL_TARGETS[bestSource] || bestExternal.tx.to)
      : ZROUTER,
    ...(bestExternal?.settlementAddress ? { settlementAddress: bestExternal.settlementAddress } : {}),
  };
}

// --- HTTP handler ---

function corsHeaders() {
  return {
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Methods': 'GET, OPTIONS',
    'Access-Control-Allow-Headers': 'Content-Type',
  };
}

function jsonResponse(data, status = 200) {
  return new Response(JSON.stringify(data), {
    status,
    headers: { ...corsHeaders(), 'Content-Type': 'application/json' },
  });
}

function isAddress(s) {
  return typeof s === 'string' && /^0x[0-9a-fA-F]{40}$/.test(s);
}

export default {
  async fetch(request, env) {
    if (request.method === 'OPTIONS') {
      return new Response(null, { headers: corsHeaders() });
    }

    const url = new URL(request.url);

    // GET / → redirect to docs
    if (url.pathname === '/') {
      return Response.redirect('https://zfi.wei.is/api/', 302);
    }

    // GET /health
    if (url.pathname === '/health') {
      return jsonResponse({ status: 'ok' });
    }

    // GET /quote
    if (url.pathname === '/quote') {
      if (request.method !== 'GET') return jsonResponse({ error: 'GET only' }, 405);

      const tokenIn = url.searchParams.get('tokenIn');
      const tokenOut = url.searchParams.get('tokenOut');
      const amount = url.searchParams.get('amount');

      if (!tokenIn || !tokenOut || !amount) {
        return jsonResponse({ error: 'Missing required params: tokenIn, tokenOut, amount' }, 400);
      }
      if (!isAddress(tokenIn)) return jsonResponse({ error: 'Invalid tokenIn address' }, 400);
      if (!isAddress(tokenOut)) return jsonResponse({ error: 'Invalid tokenOut address' }, 400);

      let amountBn;
      try { amountBn = BigInt(amount); } catch { return jsonResponse({ error: 'Invalid amount (must be integer)' }, 400); }
      if (amountBn <= 0n) return jsonResponse({ error: 'Amount must be positive' }, 400);

      const to = url.searchParams.get('to') || undefined;
      if (to && !isAddress(to)) return jsonResponse({ error: 'Invalid to address' }, 400);

      const slippageStr = url.searchParams.get('slippage');
      let slippage = 50;
      if (slippageStr) {
        slippage = parseInt(slippageStr, 10);
        if (isNaN(slippage) || slippage < 1 || slippage > 5000) {
          return jsonResponse({ error: 'slippage must be 1-5000 basis points' }, 400);
        }
      }

      const exactOut = url.searchParams.get('exactOut') === 'true';

      try {
        const result = await getQuote({ tokenIn, tokenOut, amount: amountBn, to, slippage, exactOut }, env);
        return jsonResponse(result);
      } catch (e) {
        return jsonResponse({ error: e.message }, 502);
      }
    }

    return jsonResponse({ error: 'not found' }, 404);
  },
};
