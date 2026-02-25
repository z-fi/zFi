// Cloudflare Worker: zFi On-Chain DEX Aggregator API
// Deploy: cd worker/api && wrangler deploy

const ZQUOTER = '0x9909861aa515afbce9d36c532eae7e0ebf804034';
const ZROUTER = '0x000000000000FB114709235f1ccBFfb925F600e4';
const MC3 = '0xcA11bde05977b3631167028862bE2a173976CA11';
const ZERO = '0x0000000000000000000000000000000000000000';

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
      });
      const json = await res.json();
      if (json.error) { lastErr = json.error.message || JSON.stringify(json.error); continue; }
      if (!json.result || json.result === '0x') { lastErr = 'empty result'; continue; }
      return json.result;
    } catch (e) { lastErr = e.message; }
  }
  throw new Error('All RPCs failed: ' + lastErr);
}

// --- Main quote logic ---

async function getQuote(params) {
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

  // Batch into two Multicall3 aggregate3 calls, fire in parallel
  const [lightRaw, heavyRaw] = await Promise.all([
    rpcCall(MC3, encAggregate3(lightCalls)),
    rpcCall(MC3, encAggregate3(heavyCalls)),
  ]);

  const lightMc3 = decAggregate3(lightRaw);
  const heavyMc3 = decAggregate3(heavyRaw);

  // Decode heavy: buildBest (idx 0), split (1), hybrid (2), 3hop (3)
  let bestRoute = null, bestOutput = 0n, bestMulticall = null, bestMsgValue = 0n;
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

  if (!bestMulticall || bestOutput === 0n) {
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

  // Sort allQuotes by amountOut descending
  allQuotes.sort((a, b) => (BigInt(b.amountOut) > BigInt(a.amountOut) ? 1 : -1));

  // Determine ETH value to attach
  const isETHInput = tokenIn.toLowerCase() === ZERO.toLowerCase();

  return {
    bestRoute: {
      expectedOutput: bestOutput.toString(),
      source: bestSource,
      isTwoHop: bestIsTwoHop,
      isSplit: bestIsSplit,
    },
    tx: {
      to: ZROUTER,
      data: bestMulticall,
      value: isETHInput ? bestMsgValue.toString() : '0',
    },
    allQuotes,
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
  async fetch(request) {
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
        const result = await getQuote({ tokenIn, tokenOut, amount: amountBn, to, slippage, exactOut });
        return jsonResponse(result);
      } catch (e) {
        return jsonResponse({ error: e.message }, 502);
      }
    }

    return jsonResponse({ error: 'not found' }, 404);
  },
};
