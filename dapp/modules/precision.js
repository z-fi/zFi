// Precision pool protocol: the addresses and selectors, in one place.
//
// These were written out three times — zSwap.html, dapp/index.html and
// dapp/coin/index.html — because each page grew its own copy of the encoders alongside
// them. zSwap ships as immutable page code and cannot import this, so its copy stays and
// test/ui/precision-constants.test.mjs cross-checks it. The two dapp pages can share,
// and do, from here.
//
// Nothing in this file touches the DOM or holds state: it is constants and pure
// encoding, loaded as a classic script so both pages see it as globals.

// ---- contracts -------------------------------------------------------------
const PRECISION_LENS = '0x000000Bad3a2fa57ed74fa06000573ccddF6B7fB';   // pool lens
const PRECISION_LQ_LENS = '0x000000956bf20A41C54BaE4a4b6F5C8A166DAB4E'; // liquidity lens
const PRECISION_ROUTE = '0x0000007Be74558A1F8c9045301c6F44C8eD0c9eB';   // route executor
const PRECISION_FACTORY = '0x000000Eb27B557aB426d9E99cFd54EC455799e81';

// ---- selectors -------------------------------------------------------------
const PSEL = {
  quoteBest:   '0x2adaa389',
  route:       '0x5d6498e1',
  checkpoint:  '0x0b7c6c6c',
  markets:     '0x29c21083',
  tape:        '0x29a65241',
  previewAdd:  '0xe03ec807',
  addExact:    '0xcc0025e4',
  zapIn:       '0xc98c2c0b',
  previewZap:  '0xe7cddab0',
  isPool:      '0x5b16ebb7',
  poolFor:     '0x83bd1387',
  pairCount:   '0x355da246',
  createSeed:  '0x7163352a',
};

// ---- encoding --------------------------------------------------------------
// A 32-byte word, left-padded, with the 0x stripped: these are concatenated into
// hand-built calldata, never passed to an ABI coder.
const PZERO = '0x0000000000000000000000000000000000000000';
const pAddr = a => ethers.zeroPadValue((a || PZERO).toLowerCase(), 32).slice(2);
const pWord = v => ethers.zeroPadValue(ethers.toBeHex(BigInt(v)), 32).slice(2);

// ---- market struct layout (PrecisionPoolLens.markets) -----------------------
// Word offsets inside one returned pool tuple.
const PI = { WORDS: 19, POOL: 0, SL: 3, SH: 4, FEE: 5, R0: 6, R1: 7, PX: 8, LIQ: 9, HOOK: 10 };

// The pair as the factory orders it: native ETH sorts as the zero address.
function precisionSortedPair(a, b) {
  return a.toLowerCase() < b.toLowerCase() ? [a, b] : [b, a];
}

// PrecisionRoute.route calldata. Pools are walked in order; minOut is enforced at the end.
function precisionRouteData(pools, tokenIn, tokenOut, amountIn, minOut, to) {
  return PSEL.route + pWord(192) + pAddr(tokenIn) + pAddr(tokenOut)
       + pWord(amountIn) + pWord(minOut) + pAddr(to)
       + pWord(pools.length) + pools.map(pAddr).join('');
}

// PrecisionRoute.zapIn calldata: one side in, the executor sells `portion` and deposits both.
function precisionZapData(pool, tokenIn, amountIn, portion, minLp, to, account) {
  return PSEL.zapIn + pAddr(pool) + pAddr(tokenIn) + pWord(amountIn)
       + pWord(portion) + pWord(minLp) + pAddr(to) + pAddr(account);
}

// Binds a prefunded pull to one exact route, so a funded router cannot be spent by
// a different one. The intent is the hash of the calldata it guards.
function precisionCheckpointData(tokenIn, guardedCalldata, account) {
  return PSEL.checkpoint + pAddr(tokenIn)
       + ethers.keccak256(guardedCalldata).slice(2) + pAddr(account);
}

// Decode one 32-byte word out of a returndata blob.
const pDec = (hex, i) => BigInt('0x' + hex.slice(2).slice(i * 64, (i + 1) * 64));
