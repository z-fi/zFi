/**
 * UI test harness for zSwap.html.
 *
 * zSwap ships as IMMUTABLE contract code: whatever the page does on deploy day
 * it does forever. script/check-zSwap.mjs pins the pure helpers (decQ, the
 * planners, the encoders). This harness covers the other half — the parts a
 * human would have to click to discover:
 *
 *   - what the widgets say and enable at each moment (render/setTab/applyLink)
 *   - which RPCs the page makes, in what order, against which block
 *   - the EXACT transaction it hands the wallet: target, calldata, msg.value
 *
 * That last one is the point. A quote that displays correctly but sends the
 * wrong msg.value is the failure mode that costs money, and it is invisible to
 * any assertion that only reads the DOM.
 *
 * The chain is a deterministic mock, not a fork: every balance, allowance,
 * quote and book page is fixture data the test sets up front. No network, no
 * wall-clock dependence beyond debounce, no flakiness.
 */
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { JSDOM, VirtualConsole } from 'jsdom';
import { AbiCoder, keccak256, toUtf8Bytes } from 'ethers';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..');
export const HTML_PATH = path.join(ROOT, process.env.ZSWAP_HTML || 'zSwap.html');

const coder = AbiCoder.defaultAbiCoder();

// ---------------------------------------------------------------- addresses
// Kept in sync with the page by assertAddressesMatchPage() below, so a
// redeployed contract cannot leave these fixtures quietly testing nothing.
export const A = {
  ZERO: '0x0000000000000000000000000000000000000000',
  V4PORT: '0x000000dfb53Fa7f1c486470034741d5BCBE14BE9',
  V4LENS: '0x000000c3aE1692983941495162A4AAB40660E65F',
  WETH: '0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2',
  USDC: '0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48',
  USDT: '0xdAC17F958D2ee523a2206206994597C13D831ec7',
  WBTC: '0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599',
  ZQUOTER: '0x000000bd2db80567c23e353ca95a251c573cbf9b',
  ZROUTER: '0x000000000000FB114709235f1ccBFfb925F600e4',
  PERMIT2: '0x000000000022D473030F116dDEE9F6B43aC78BA3',
  MC3: '0xcA11bde05977b3631167028862bE2a173976CA11',
  // Whatever a simulated safeSummonDAICO answers. The page never reads it.
  CAUSE_DAO: '0x00000000000000000000000000000000da0da0da',
  // ShareOffering — where a cause is bought, as the page pins it.
  OFFERING: '0x000000A4Ad929C9E108aD2B1D2fBeDe0C2Ae57e1',
  // TapVest — the singleton that releases a cause's vested ether.
  TAPVEST: '0x0000000060cdD33cbE020fAE696E70E7507bF56D',
  SLOW: '0x000000000000888741B254d37e1b27128AfEAaBC',
  SLOW_GATE: '0xb8B546b93a82f4Aa6f0345142dF5679B659ef3D4',
  SB2: '0x000000dA7bb4B2A9E3e80e9A4D4157E26CA6189b',
  SB1: '0x000000fF3D7A2d373615141d7489Ca66683DbecF',
  SBVIEW: '0x000000E0b25449F32f7D9259aC449bA88E78dFCE',
  SWAPBOL: '0x00000087A6dc5071779Ed1F8274A39230768B976',
  DUTCH: '0x000000a213b430D14Bae6062c176289B05e04489',
  ORDERBOL: '0x000000e6c7a12C80525ee74e7434aAb919447D95',
  FLOOR: '0x00000080198137F790DA4C52bb902cf87c276748',
  FLOORVIEW: '0x0000004E376e9dB5D9EC28E6711E1a64997C6ba7',
  TOKENLIST: '0x0000006013dF75A31678B786061C2B54bf531524',
  ZLISTLENS: '0x000000cEa3AB048d59473F3fb116A8D7F1abd247',
  // Precision pools. PPLENS is patched per-test (the chart and liquidity suites
  // rewrite it by shape), but the factory and the liquidity lens are used at
  // their real addresses, so those two are pinned against the page below.
  PFACTORY: '0x000000Eb27B557aB426d9E99cFd54EC455799e81',
  PLQLENS: '0x000000956bf20A41C54BaE4a4b6F5C8A166DAB4E',
  // The executor target of a one-sided deposit. Pinned too: the zap names it
  // as snwap's `executor`, and a wrong address there is a transaction that
  // hands the router's value to nothing.
  PROUTE: '0x0000007Be74558A1F8c9045301c6F44C8eD0c9eB',
  PPOLICY: '0x00000045fc7b570Be4d71F67219508ebD295EC6D',
  POOL: '0x5555555555555555555555555555555555555555',
  ENSREG: '0x00000000000C2E074eC69A0dFb2997BA6C7d2e1e',
  ENSRESOLVER: '0x00000000000000000000000000000000000e5e50',
  WNS: '0x0000000000696760E15f265e828DB644A0c242EB',
  GNS: '0x9D51D507BC7264d4fE8Ad1cf7Fe191933A0a81d6',
  ACCOUNT: '0x1111111111111111111111111111111111111111',
  OTHER: '0x2222222222222222222222222222222222222222',
};

export const SEL = {
  BALANCEOF: '70a08231', ALLOWANCE: 'dd62ed3e', APPROVE: '095ea7b3', TRANSFER: 'a9059cbb',
  SYMBOL: '95d89b41', DECIMALS: '313ce567', NAME: '06fdde03',
  DS: '3644e515', NONCES: '7ecebe00', PERMIT_TH: '30adf81f',
  MULTICALL: 'ac9650d8', SNWAP: '5f3bd1c8', SWEEP: 'cb019b84', CHECKPOINT: 'a972985e',
  FILLPLAN: 'c277f67c', FILLPLAN_SWAP: '9090c8e5', QUOTEFILL: 'f325beda',
  RPERMIT: '7ac2ff7b', P2TF: '09d31579',
  AGG3: '82ad56cb',
  QUOTE: 'e453166e', QUOTE_MULTI: '4c464f59', SPLIT_A: '892af013', SPLIT_B: '85f86a90',
  QUOTE_ONE: 'e7798987',
  // `placeDutch` grew a `uint40 expiry` between `duration` and `deadline`, so
  // the selector moved from fb910431. The adapter used to hardcode the board's
  // expiry to zero, leaving every Dutch lot resting at its floor forever.
  ORDER_FIXED: 'bcdb7936', ORDER_DUTCH: 'bbd94e1a',
  CANDS: '5f452988', DUTCH_CANDS: 'eb33e466', RECENT: '6a9849c1', RECENT_DUTCH: '98035c9a',
  FLOOR_CANDS: 'c587d927', RECENT_FLOOR: 'a5edd13d', COLL_BIDS: '16bb24eb',
  GETORDERS: '03652027', BIDS: '4423c5f1',
  INITIAL_B: '878ea250', TOKENURI: 'c87b56dd', LOGOOF: '6ce273ac',
  FLOOR_HIT: '309ce4ce', ORDER_FLOOR: '23e93357', BOL_FLOOR: 'b732d224',
  NEXTID: '2a58b330', NEXTID2: '61b8ce8c', CANCELORD: '514fcac7', CANCEL_UNWRAP: '21dd76f9',
  DUTCH_CANCEL: '40e58ee5', DUTCH_CANCEL_UNWRAP: '8382de65',
  // The fill entry points carry `fillAmountB` and `minAmountA`: a taker states
  // what it pays and the floor it accepts. The three-and-four-argument
  // ancestors (8ab3bfc9 / 402ad677 / 13092239) had neither.
  FILL1: 'c37dfc5b', FILL2: '9d136c7f', FILL2_UNWRAP: '3987baf4', FILL2_ETH: '6f608bab',
  DUTCH_FILL: 'ae7a8260', DUTCH_LISTING: 'de74e57b',
  POOLS_PAIR: '84cc5873', TAPE: '29a65241', MARKETS: '29c21083',
  ISPOOL: '5b16ebb7', PREVIEW_REMOVE: 'a2eaee07', PREVIEW_ADD: 'e03ec807',
  PREVIEW_ZAP: 'e7cddab0', ZAPIN: 'c98c2c0b',
  POOLFOR: '83bd1387', PREVIEW_SEED: '1d355417', CREATE_SEED: '7163352a',
  TOTALSUPPLY: '18160ddd',
  QUOTE_BEST: '2adaa389', PSWAP: 'a6220b66', POOL_FEE: 'ddca3f43', EFF_FEE: 'ef66de32',
  // PrecisionRoute.route(address[],address,address,uint256,uint256,address)
  PROUTE_ROUTE: '5d6498e1',
  QUOTE_ALL: '89941805', ROUTABLE_BATCH: '9662c498',
  BY_CREATOR: '7d78be2b', TOKEN1: 'd21220a7', BY_CREATOR_N: 'aa5e6b5b', RESERVE0: '443cb4bc',
  PAIR_COUNT: '355da246',
  REMOVE: 'e39b0eb5', REMOVE_LOSSY: '0cc55f06', ADDEXACT: 'cc0025e4',
  RANKEDIDS: 'df7ca268', LISTJSON: '74e18e96', FLOOR_BID: '3d8d260b',
  NS_CID: 'fb021939', NS_RES: '4f896d4f', NS_REV: '9af8b7aa',
  ENS_RSLV: '0178b8bf', ENS_EADDR: '3b3b57de', ENS_ENAME: '691f3431',
  ENS_RESOLVE: '9061b923', ENS_SUPPORTS: '01ffc9a7',
  DEPOSITTO: '94eeaec9', CLAIM: '379607f5', REVERSE: '97d15425', WITHDRAWFROM: 'd4fdc309',
  DEPOSITTIP: '75f92e42', TIPS: 'a5c68c59', REFUNDTIP: 'd27e1e72',
  OUT: 'd40d4bc6', IN: 'e3993ee7', PENDING: '6577b86a',
  GUARDIAN: '0633b14a', UNLOCK: '6198e339', CLAWBACK: 'fcc36bc9',
  WETH_DEPOSIT: 'd0e30db0', WETH_WITHDRAW: '2e1a7d4d',
  LATEST: '52bfe789', PREVIOUS: '247dfaa8', SUCCEEDED_AT: '451aae60',
};

// -------------------------------------------------------------- abi helpers
const strip = h => (h || '').replace(/^0x/, '');
const ZERO_ADDR = '0x' + '0'.repeat(40);
export const word = (hex, i) => BigInt('0x' + strip(hex).slice(i * 64, (i + 1) * 64));
export const wordAddr = (hex, i) => '0x' + strip(hex).slice(i * 64 + 24, (i + 1) * 64);
const u256 = v => BigInt(v).toString(16).padStart(64, '0');
const addrWord = a => strip(a).toLowerCase().padStart(64, '0');
const PLAUNCH = '0x0000002fc8e77585a008aa45d78a71ad36293aee';
const FEE_POOL = '0x' + 'fe'.repeat(20);
const LAUNCHED_TOPIC = keccak256(toUtf8Bytes(
  'Launched(address,address,address,uint256,uint256,uint256)'));
export const selectorOf = data => strip(data).slice(0, 8);

/** ABI-encode a dynamic `bytes` tail (length word + right-padded body). */
const bytesTail = data => {
  const d = strip(data);
  return u256(d.length / 2) + d.padEnd(Math.ceil(d.length / 64) * 64, '0');
};

/**
 * Encode a zQuoter return in the exact shape decQ reads by hard-coded offsets.
 *
 * Head is (u/4 + 1) legs of {source, feeBps, amountIn, amountOut}, then an
 * offset to a hops array, then an offset to the executable callData, then
 * msgValue — verified against the recorded mainnet returns in
 * test/fixtures/quoter.json (see the word dumps in that file's tests).
 *
 * Populating only the FIRST leg yields the single-hop shape (decQ reads
 * amountOut from word 3); populating the last leg yields the multihop shape
 * (decQ reads it from word u+3). Both are exercised by the suite.
 */
export function encodeQuote({ u = 4, legs, callData = '0x', msgValue = 0n, hops = 1 }) {
  const nLegs = u / 4 + 1;
  const padded = Array.from({ length: nLegs }, (_, i) => legs[i] || null);
  const headWords = 4 * nLegs + 3;
  const arrOff = headWords * 32;
  const bytesOff = arrOff + 32 + hops * 32;

  let head = '';
  for (const leg of padded) {
    head += u256(leg ? leg.source : 0) + u256(leg ? leg.feeBps || 0 : 0) +
      u256(leg ? leg.amountIn : 0) + u256(leg ? leg.amountOut : 0);
  }
  head += u256(arrOff) + u256(bytesOff) + u256(msgValue);

  let arr = u256(hops);
  for (let i = 0; i < hops; i++) arr += u256(1);

  return '0x' + head + arr + bytesTail(callData);
}

/**
 * buildBestSwap's return: (Quote, bytes callData, uint256 amountLimit, uint256 msgValue).
 *
 * One word longer than the multicall builders, because amountLimit sits between
 * the bytes offset and msgValue. That word is the whole reason the page passes
 * decQ an explicit msgValue index for this builder — read it as v+1 and the
 * msg.value of every ETH swap becomes the slippage bound instead.
 */
export function encodeSingleHop({ source = 3, feeBps = 30n, amountIn, amountOut, amountLimit, msgValue = 0n, callData = '0x' }) {
  const d = callData.replace(/^0x/, '');
  return '0x' + u256(source) + u256(feeBps) + u256(amountIn) + u256(amountOut)
    + u256(7 * 32) + u256(amountLimit) + u256(msgValue)
    + u256(d.length / 2) + d.padEnd(Math.ceil(d.length / 64) * 64, '0');
}

/** The 16-field SwapboardView.OrderView tuple, as decViewPage decodes it. */
const ROW_TUPLE =
  'tuple(uint256,address,bool,uint64,bool,bool,address,address,uint256,string,uint8,address,uint256,string,uint8,address)[]';

export function encodeViewPage(rows, next = 0n) {
  const encoded = rows.map(r => [
    BigInt(r.id), r.maker || A.OTHER, !!r.pf, BigInt(r.exp || 0),
    !!r.nA, !!r.nB, r.cp || A.ZERO,
    r.tA, BigInt(r.aA), r.symA || 'OUT', r.decA ?? 18,
    r.tB, BigInt(r.aB), r.symB || 'PAY', r.decB ?? 18,
    r.board,
  ]);
  return coder.encode([ROW_TUPLE, 'uint256'], [encoded, BigInt(next)]);
}

const encodeString = s => coder.encode(['string'], [s]);
export const wordHex = (hex, i) => '0x' + strip(hex).slice(i * 64, (i + 1) * 64);
/** namehash, computed independently of the page so the test is not the code. */
export const ensNamehash = name => {
  let node = '0x' + '0'.repeat(64);
  if (name) for (const label of name.split('.').reverse())
    node = keccak256(node + strip(keccak256(toUtf8Bytes(label))));
  return node;
};
/** DNS wire format back to a dotted name. */
const dnsDecode = hex => {
  const h = strip(hex); const out = []; let i = 0;
  for (;;) {
    const len = parseInt(h.slice(i, i + 2), 16);
    if (!len) break;
    out.push(Buffer.from(h.slice(i + 2, i + 2 + len * 2), 'hex').toString('utf8'));
    i += 2 + len * 2;
  }
  return out.join('.');
};

/**
 * The 17-field FloorboardView.BidRow tuple.
 *
 * Three of its members are dynamic (`ids`, and both symbols), so each ELEMENT
 * of the array is offset-encoded — the array head holds pointers to rows, not
 * rows. That indirection is the thing the page's decoder has to get right, and
 * encoding it here through a real ABI coder is what makes the test able to
 * catch a decoder that reads a pointer as an address.
 *
 * `tokenDecimals`/`quoteDecimals` carry the board's `decimals + 1` convention,
 * with 0 meaning "never snapshotted". Fixtures state the TRUE decimals and the
 * bias is applied here, so a test never has to remember it.
 */
const BID_TUPLE =
  'tuple(uint256,address,address,address,bool,bool,uint256[],uint128,uint128,' +
  'uint256,uint256,uint40,uint40,uint8,uint8,string,string)[]';

export function encodeBidPage(rows, next = 0n) {
  const encoded = rows.map(r => [
    BigInt(r.id), r.bidder || A.OTHER, r.token, r.quote,
    !!r.isNFT, r.anyId ?? !!r.isNFT, (r.ids || []).map(BigInt),
    BigInt(r.remaining), BigInt(r.initial ?? r.remaining),
    BigInt(r.price), BigInt(r.proceeds),
    BigInt(r.startTime || 0), BigInt(r.expiry ?? 0),
    r.tokenDecimals == null ? 0 : r.tokenDecimals + 1,
    r.quoteDecimals == null ? 0 : r.quoteDecimals + 1,
    r.tokenSymbol || 'ASSET', r.quoteSymbol || 'QUOTE',
  ]);
  return coder.encode([BID_TUPLE, 'uint256'], [encoded, BigInt(next)]);
}

/**
 * PrecisionPoolLens.PoolInfo[] — all static, so the array is flat words and the
 * FIELD COUNT IS THE ROW STRIDE. It was 18 until `clampable` was added; at the
 * wrong width every row after the first decodes as garbage with nothing thrown,
 * which presents as "the second pool vanished" rather than as an error. Keep in
 * step with PI_WORDS in zSwap.html and with the preview builder.
 */
const POOL_INFO = 'tuple(address,address,address,uint256,uint256,uint256,uint256,uint256,' +
  'uint256,uint256,address,address,uint256,uint256,uint256,uint256,uint256,uint256,uint256)[]';

/** Pack a value the way PriceTape.pack does: 24-bit mantissa, 8-bit exponent. */
export function packTapeFloat(v) {
  v = BigInt(Math.floor(Number(v)));
  if (v <= 0n) return 0n;
  let msb = BigInt(v.toString(2).length - 1);
  if (msb < 24n) return v;
  const shift = msb - 23n;
  return (shift << 24n) | (v >> shift);
}

/** Build one packed bar word, matching PriceTape's slot layout. */
export function encodeTapeBar({ bucket, open, high, low, close, volume, count = 1 }) {
  const f = x => packTapeFloat(x);
  return BigInt(bucket)
    | (f(open) << 32n) | (f(high) << 64n) | (f(low) << 96n)
    | (f(close) << 128n) | (f(volume) << 160n) | (BigInt(count) << 192n);
}

// ------------------------------------------------------------- chain mock
/**
 * A deterministic EIP-1193 provider. Everything it returns comes from state the
 * test set; anything unhandled throws loudly rather than returning zero, so a
 * silently-wrong fixture surfaces as a failure instead of an empty balance.
 */
// Moloch's side of a cause: the loot token names its DAO, and the DAO names
// the loot and shares back, which is the only way to tell cause loot from any
// other contract that happens to publish a DAO() getter.
// Moloch's mint sentinel for loot: address(1007).
export const LOOT_SENTINEL = '0x00000000000000000000000000000000000003ef';

const SEL_CAUSE = {
  DAO: '98fabd3a', LOOT: '9b7b2ab0', SHARES: '03314efa',
  RAGEQUIT: '29f64d1a',
};

export class MockChain {
  constructor(opts = {}) {
    this.chainId = opts.chainId ?? '0x1';
    this.accounts = opts.accounts ?? [A.ACCOUNT];
    this.autoConnected = opts.autoConnected ?? false;
    this.blockNumber = opts.blockNumber ?? '0x1200000';
    // A block has a time, and anything counting from a commitment has to read
    // it from here rather than from the local clock: the chain measures a
    // commitment's age from the block that mined it, not from the click.
    this.blockTime = opts.blockTime ?? Math.floor(Date.now() / 1000);
    this.gasPrice = opts.gasPrice ?? 10n ** 9n; // 1 gwei
    this.native = new Map();       // address -> wei
    this.erc20 = new Map();        // `${token}:${holder}` -> units
    this.allow = new Map();        // `${token}:${owner}:${spender}` -> units
    this.meta = new Map();         // token -> {symbol, decimals, name, domainSeparator}
    this.code = new Map();         // address -> code
    this.candidates = [];          // rows returned by the candidate lens
    this.recent = [];              // rows returned by the recent-orders lens
    this.dutchListings = new Map();
    // Price tape: pools per canonical pair, and bars per pool.
    this.pools = new Map();        // `${token0}:${token1}` -> [{pool,hook,liquidity}]
    // Pools a lens reports but the factory disclaims — an impersonator, which
    // is the case the write paths' isPool check exists to catch.
    this.disowned = new Set();
    this.tapes = new Map();        // `${pool}:${period}` -> [bar | null], newest first
    // Name services. `names` resolves forward (name -> address) for .wei/.gwei
    // via the WNS/GNS registries; `reverse` drives the header's display name.
    this.names = new Map();
    this.reverse = new Map();
    this.ensResolver = A.ZERO;   // non-zero enables the .eth path
    this.ensResolvers = new Map();  // node -> resolver, for the ENSIP-10 walk
    this.ensNames = new Map();      // .eth name -> address, read by addr()/resolve()
    this.ensRevNames = new Map();   // address -> the name its reverse record claims
    this.ensWildcard = false;       // does the resolver admit to ENSIP-10?
    this.ensOffchain = false;       // resolve() reverts OffchainLookup, as a CCIP resolver does
    this.slowOut = [];
    this.slowIn = [];
    this.slowPending = new Map();
    // transferId -> tip in wei, as the gate holds it. Absent means no tip was
    // posted, which is what a plain depositTo leaves behind.
    this.slowTips = new Map();
    // A guardian on the account changes which calls SLOW will accept: claim
    // becomes unlock, and withdrawFrom needs the guardian's co-signature.
    this.slowGuardian = A.ZERO;
    this.quoteHandler = null;      // ({selector, params}) => hex | null
    this.capabilities = null;      // wallet_getCapabilities response
    this.sent = [];                // eth_sendTransaction payloads
    this.calls = [];               // every eth_call {to, data, block}
    this.log = [];                 // every request {method, params}
    this.signed = [];              // eth_signTypedData_v4 payloads
    this.batches = [];             // wallet_sendCalls payloads
    // Recovery id the mock wallet puts in the last byte of a signature. Real
    // wallets disagree: most answer 27/28, some answer the raw 0/1 form, and a
    // signature that reaches Permit2 with 0/1 recovers address(0) and reverts.
    this.sigV = 0x1b;
    // wallet_getCallsStatus answer, as ({id}) => status object. Null means the
    // default: one receipt, confirmed. Set it to exercise partial failure, a
    // per-call receipt list, or a status code that is not 200.
    this.callsStatusHandler = null;
    this.reverts = new Map();      // `${to}:${selector}` -> message, for eth_call
    this.batchLimit = Infinity;    // max aggregate3 calls before the node balks
    this.failEveryCall = false;    // batch returns, but every call inside it failed
    // zTokenlist rows, IN CONVICTION ORDER, as rankedIds() returns them. Null
    // means the registry is unreachable and the page uses its built-in list,
    // which is what most suites want; set it to exercise curation.
    this.registry = null;
    // Conviction order as ZorgTokenListLens.rankedIds() returns it: registry
    // ids, re-sorted by live support. Null means the lens is unreachable,
    // which is the case the page must survive by falling back to the
    // registry's own listing order.
    this.conviction = null;
    this.nftOwner = new Map();     // `${collection}:${id}` -> holder
    // loot token -> {dao, shares, sharesSupply, lootSupply}, via setCause().
    this.causes = new Map();
    // zSwap address -> what its `latest()` answers. Unset means the address is
    // its own tip: no successor, so the page has nothing to announce.
    this.lineage = new Map();
    // version -> its predecessor, and predecessor -> when it recorded that
    // successor. The page refuses to point anyone at a version younger than
    // the maturity delay, so a lineage fixture needs a clock as well as a
    // shape. Unset reads as zero, which the page treats as "no clock, no
    // delay" - the pre-field chain case.
    this.previousOf = new Map();
    this.succeededAt = new Map();
    // Band a seed preview answers for: {low, high} sqrt prices, and optional
    // used0/used1 when the seed should consume less than it was offered.
    this.seedBand = null;
    this.seedDeployed = false;     // was the market already created, unseeded?
    // Widest band the fixture will accept, as hi/lo in sqrt space. Null lets
    // every width through.
    this.rejectWiderThan = null;
    // What PrecisionPoolLens.quoteBestFor answers: {pool, out, fee}. Null is a
    // pair with no Precision band, which is most pairs. An ARRAY is several
    // markets, each with its own `pair` - which is what a hub hop needs, since
    // it asks about two pairs that share a token and must get a different pool
    // and a different size from each.
    this.precisionQuote = null;
    // Override for poolsForPairCount, to model a pair stuffed with bands.
    this.pairCount = null;
    // Pools PrecisionPoolPolicy declines, and whether it can be read at all.
    this.blocked = new Set();
    this.policyUnreadable = false;
    this.rejectNext = null;        // make the next signature/tx a user rejection
    this.failNextReceipt = false;  // accept the next tx, then mine it reverted
    this.receiptPending = false;   // a tx the node has not mined yet: receipt is null
    this.commitAt = Math.floor(Date.now() / 1000); // what commitments() reports
    this.commitBlocked = false;    // make the commitments() read fail
    this.garbleNextTxHash = false; // a wallet that answers a send with nonsense
    this.nextOrderId = 0;          // Swapboard's counter, via nextOrderId()
    // Raw logs eth_getLogs answers, filtered by address and topic0. The
    // private bridge rebuilds the confidential pool's leaf tree from these.
    this.logs = [];
    this.estimateGas = 0x5208n;    // what eth_estimateGas answers
    // personal_sign: what the wallet answers, and what it was asked to sign.
    // Deterministic on purpose - the private bridge derives its note key from
    // this, so a fixed signature is what makes its calldata pinnable.
    this.personalSig = '0x' + '33'.repeat(64) + '1b';
    this.personalSigned = [];
    // Other chains the page reads over plain HTTP, keyed by a URL fragment:
    // the fetch mock routes a JSON-RPC POST whose URL contains the key to that
    // MockChain instead of this one.
    this.remotes = {};
    this.nextBoardId = 0;          // Dutchboard/Floorboard's counter, via nextId()
    this.answers = new Map();      // `${to}:${selector}` -> returndata, for read-only contracts
    this.inFlight = 0;
    this.nonce = 0;
    this.floorBids = [];           // FloorboardView.BidRow fixtures
    this.cards = {};               // `${board}:${id}` -> tokenURI JSON object
    this.logos = {};               // token -> logoOf() string
    this.initialAmountB = {};      // `${board}:${id}` -> original amountB
    this.swapbolFloorboard = null; // null => the executor knows A.FLOOR

    // Every zSwap-relevant contract is deployed by default; tests that care
    // about "not deployed yet" branches clear these explicitly.
    for (const a of [A.SB2, A.SB1, A.SBVIEW, A.SWAPBOL, A.DUTCH, A.ORDERBOL,
      A.FLOOR, A.FLOORVIEW, A.TOKENLIST,
      A.ZROUTER, A.ZQUOTER, A.SLOW, A.MC3, A.PERMIT2, A.WETH, A.USDC, A.USDT, A.WBTC]) {
      this.code.set(a.toLowerCase(), '0x60006000');
    }
    this.setToken(A.USDC, { symbol: 'USDC', decimals: 6, name: 'USD Coin' });
    this.setToken(A.USDT, { symbol: 'USDT', decimals: 6, name: 'Tether USD' });
    this.setToken(A.WETH, { symbol: 'WETH', decimals: 18, name: 'Wrapped Ether' });
    this.setToken(A.WBTC, { symbol: 'WBTC', decimals: 8, name: 'Wrapped BTC' });
  }

  // -- state setters -------------------------------------------------------
  /**
   * A cause DAO and the loot token that claims against it.
   *
   * Registered by the LOOT address, because that is the only address the page
   * ever starts from: a cause token arrives in the list like any other ERC20
   * and has to identify itself. The DAO answers loot() and shares() so the
   * page can confirm the claim runs both ways before it prices a burn.
   */
  setCause(loot, { dao, shares, sharesSupply = 0n, lootSupply = 0n, treasury = 0n,
                   price = 0n, deadline = 0n, remaining = 0n,
                   ratePerSec = 0n, lastClaim = 0n, tapBudget = 0n, beneficiary = A.ACCOUNT,
                   /* What the sale actually SELLS and takes payment in. These
                      default to the loot-for-ether shape the launcher makes,
                      but a DAO may configure either differently — and hardcoding
                      them here is exactly why the suite could not see a sale
                      that mints shares being priced as if it minted loot. */
                   saleToken = LOOT_SENTINEL, salePayToken = A.ZERO,
                   cap = 9_999_999n * 10n ** 18n }) {
    this.causes.set(loot.toLowerCase(), {
      dao: dao.toLowerCase(), shares: shares.toLowerCase(),
      sharesSupply: BigInt(sharesSupply), lootSupply: BigInt(lootSupply),
      // The live sale, as ShareOffering holds it. `price` of 0 means no sale
      // was ever configured, which is how a closed or unconfigured cause reads.
      price: BigInt(price), deadline: BigInt(deadline), remaining: BigInt(remaining),
      saleToken, salePayToken, cap: BigInt(cap),
      // The tap: a rate, when it last paid out, and what the DAO still allows it.
      ratePerSec: BigInt(ratePerSec), lastClaim: BigInt(lastClaim),
      tapBudget: BigInt(tapBudget), beneficiary,
    });
    this.setNative(dao, treasury);
    return this;
  }

  setNative(who, wei) { this.native.set(who.toLowerCase(), BigInt(wei)); return this; }
  setErc20(token, holder, units) {
    this.erc20.set(`${token.toLowerCase()}:${holder.toLowerCase()}`, BigInt(units)); return this;
  }
  setAllowance(token, owner, spender, units) {
    this.allow.set(`${token.toLowerCase()}:${owner.toLowerCase()}:${spender.toLowerCase()}`, BigInt(units));
    return this;
  }
  /**
   * Register a token's metadata.
   *
   * Also registers code at the address, because a token WITHOUT code is not a
   * thing that exists - and the page now checks, so a fixture that declares a
   * token at an empty address is describing something impossible.
   *
   * `erc721: true` makes it answer ERC-165 for the NFT interface and refuse
   * decimals(), which is how a real collection behaves and how the page tells
   * the two apart.
   */
  setToken(token, m) {
    this.meta.set(token.toLowerCase(), m);
    if (!this.code.has(token.toLowerCase())) this.code.set(token.toLowerCase(), '0x60006000f3');
    return this;
  }
  /**
   * Register pools for a pair. Entries may be a bare address or
   * {pool, hook, liquidity} — the lens reports hook and liquidity, and the
   * chart uses both to decide which pools may speak for the pair's price.
   *
   * The band fields (fee, reserves, and the three raw sqrt prices) default to
   * zero because the chart does not read them. The liquidity panel does, and
   * so do the previews below, which compute against `liquidity` as the LP
   * supply and `reserve0/1` as the reserves — the same arithmetic the real
   * lens performs, so a test asserting on a previewed amount is asserting on
   * something, not on a constant.
   */
  /**
   * Markets the LAUNCHER created, as the factory's creator index reports them.
   * `pools` is [{pool, token}] - the page reads the pool list, then `token1()`
   * on each, because token0 is always the native asset on a launch.
   */
  /**
   * Fees a launched coin has accrued but nobody has swept. `fees` is
   * {token: {owed0, owed1, pool}} - owed0 is the ether side, which is what the
   * page offers to collect.
   */
  setLaunchFees(fees) {
    this.launchFees = {};
    for (const [t, v] of Object.entries(fees)) {
      const e = typeof v === 'bigint' ? { owed0: v } : v;
      this.launchFees[t.toLowerCase()] = e;
      this.code.set((e.pool || FEE_POOL).toLowerCase(), '0x60006000');
    }
    return this;
  }
  /**
   * Pools that EXIST and answer like pools, but are not in the launcher's
   * index - the factory never made them, or another creator did. Nothing
   * discovers these; a test reaches them by putting one in the carried list,
   * which is the only path by which an address the launcher never made can
   * reach the launched cohort.
   */
  setForeignPools(pools) {
    this.foreign = pools;
    for (const {pool} of pools) if (!this.code.has(pool.toLowerCase())) this.code.set(pool.toLowerCase(), '0x60006000');
    return this;
  }
  /** Every pool a fixture has described, launched here or not. */
  anyPool(to) {
    return (this.launched || []).find(x => x.pool.toLowerCase() === to)
      || (this.foreign || []).find(x => x.pool.toLowerCase() === to);
  }
  setLaunched(pools) {
    this.launched = pools;
    for (const {pool} of pools) if (!this.code.has(pool.toLowerCase())) this.code.set(pool.toLowerCase(), '0x60006000');
    return this;
  }
  /** `precisionQuote` as a list, whether the fixture set one market or several. */
  precisionList() {
    if (!this.precisionQuote) return [];
    return Array.isArray(this.precisionQuote) ? this.precisionQuote : [this.precisionQuote];
  }
  /**
   * What one market answers at `amt`.
   *
   * `perIn` prices whatever it is handed, which is what makes a second hop's
   * quote depend on the first. `small` is the flat alternative for impact: the
   * page quotes a hundredth of the trade and compares the marginal price to the
   * executed one, so a fixture returning the same number for both sizes makes
   * every trade look impact-free.
   */
  precisionOut(q, amt) {
    if (q.perIn) return q.perIn(amt);
    if (q.small !== undefined && amt < BigInt(q.amountIn ?? 10n ** 18n)) return BigInt(q.small);
    return BigInt(q.out);
  }
  /** The market at `pool`, for the reads that name a pool rather than a pair. */
  precisionAt(pool) {
    if (!pool) return null;
    const want = String(pool).toLowerCase();
    return this.precisionList().find(q => q.pool.toLowerCase() === want) || null;
  }
  /** Make the policy decline `pool`, the way a hooked or Blocked one reads. */
  blockPool(pool) { this.blocked.add(pool.toLowerCase()); return this; }
  setPools(a, b, pools) {
    const [t0, t1] = a.toLowerCase() < b.toLowerCase() ? [a, b] : [b, a];
    const rows = pools.map(p => (typeof p === 'string' ? { pool: p } : p))
      .map(r => ({
        hook: A.ZERO, liquidity: 10n ** 21n,
        fee: 0n, reserve0: 0n, reserve1: 0n, sqrtLow: 0n, sqrtHigh: 0n, sqrtNow: 0n,
        ...r,
      }));
    this.pools.set(`${t0.toLowerCase()}:${t1.toLowerCase()}`, rows);
    for (const r of rows) this.code.set(r.pool.toLowerCase(), '0x60006000');
    return this;
  }
  /** Bars for one pool at one bar width. The page reads a fine and a coarse tape. */
  setTape(pool, bars, period = 300) {
    this.tapes.set(`${pool.toLowerCase()}:${period}`, bars);
    return this;
  }
  /** Give `holder` token `id` of `collection`, so ownerOf answers for it. */
  setNftOwner(collection, id, holder) {
    this.nftOwner.set(`${collection.toLowerCase()}:${BigInt(id)}`, holder);
    return this;
  }
  setCode(addr, code) { this.code.set(addr.toLowerCase(), code); return this; }

  /**
   * Answer one `(contract, selector)` with fixed returndata.
   *
   * The mock models the contracts the page trades through in real depth,
   * because their arithmetic is what the page gets wrong. For a contract the
   * page only READS - a name registry quoting a fee, a lottery reporting its
   * round - that depth buys nothing: the test cares what the page DOES with
   * the answer, not that the mock could have derived it. `answer` gives those
   * a value without a model.
   *
   * `hex` may be a FUNCTION of the calldata, for a selector whose reply
   * depends on its arguments - `isAvailable` over two different labels is one
   * selector asked twice. It is consulted before every built-in, so it can
   * also override one.
   */
  answer(to, selector, hex) {
    this.answers.set(`${to.toLowerCase()}:${strip(selector)}`, hex); return this;
  }
  undeploy(addr) { this.code.set(addr.toLowerCase(), '0x'); return this; }
  /**
   * Make an `eth_call` fail.
   *
   * `msg` may be a FUNCTION of the calldata, for the case where one selector
   * has to fail selectively: a pool whose degraded exit reverts when asked for
   * both sides and succeeds when asked for one is a single selector called
   * twice with different arguments, and a flat map cannot tell those apart.
   * Return a message to revert, or a falsy value to let the call through.
   */
  revertOn(to, selector, msg = 'execution reverted') {
    this.reverts.set(`${to.toLowerCase()}:${selector}`, msg); return this;
  }

  /** Make the factory disclaim a pool the lens still describes. */
  disownPool(pool) { this.disowned.add(pool.toLowerCase()); return this; }

  /** The sorted pair a pool was registered under, or null. */
  poolPair(pool) {
    const want = pool.toLowerCase();
    for (const [key, rows] of this.pools) {
      if (rows.some(r => r.pool.toLowerCase() === want)) return key.split(':');
    }
    return null;
  }

  /** The registered pool row for an address, across every pair. */
  poolRow(pool) {
    const want = pool.toLowerCase();
    for (const rows of this.pools.values()) {
      const hit = rows.find(r => r.pool.toLowerCase() === want);
      if (hit) return hit;
    }
    return null;
  }

  balanceOf(token, holder) {
    return token.toLowerCase() === A.ZERO
      ? this.native.get(holder.toLowerCase()) ?? 0n
      : this.erc20.get(`${token.toLowerCase()}:${holder.toLowerCase()}`) ?? 0n;
  }
  allowanceOf(token, owner, spender) {
    return this.allow.get(`${token.toLowerCase()}:${owner.toLowerCase()}:${spender.toLowerCase()}`) ?? 0n;
  }

  /** Transactions sent to a given contract, newest last. */
  sentTo(addr) { return this.sent.filter(t => (t.to || '').toLowerCase() === addr.toLowerCase()); }
  get lastSent() { return this.sent[this.sent.length - 1]; }

  // -- provider ------------------------------------------------------------
  async request({ method, params }) {
    this.inFlight++;
    try {
      this.log.push({ method, params });
      return await this.dispatch(method, params || []);
    } finally {
      this.inFlight--;
    }
  }

  async dispatch(method, params) {
    switch (method) {
      case 'eth_chainId': return this.chainId;
      case 'eth_accounts': return this.autoConnected ? this.accounts : [];
      case 'eth_requestAccounts': {
        if (this.rejectNext) { const e = this.rejectNext; this.rejectNext = null; throw e; }
        this.autoConnected = true;
        return this.accounts;
      }
      case 'eth_blockNumber': return this.blockNumber;
      case 'eth_gasPrice': return '0x' + this.gasPrice.toString(16);
      case 'eth_getBalance': return '0x' + this.balanceOf(A.ZERO, params[0]).toString(16);
      case 'eth_getCode': return this.code.get((params[0] || '').toLowerCase()) ?? '0x';
      case 'eth_getLogs': {
        const f = params[0] || {};
        const addr = (f.address || '').toLowerCase();
        const t0 = f.topics && f.topics[0];
        const want = t0 ? (Array.isArray(t0) ? t0 : [t0]).map(t => t.toLowerCase()) : null;
        return this.logs.filter(l => (!addr || (l.address || '').toLowerCase() === addr)
          && (!want || want.includes((l.topics[0] || '').toLowerCase())));
      }
      case 'eth_estimateGas': return '0x' + BigInt(this.estimateGas).toString(16);
      case 'personal_sign': {
        if (this.rejectNext) { const e = this.rejectNext; this.rejectNext = null; throw e; }
        this.personalSigned.push({ message: params[0], account: params[1] });
        return this.personalSig;
      }
      case 'eth_call': return this.ethCall(params[0], params[1]);
      case 'eth_sendTransaction': {
        if (this.rejectNext) { const e = this.rejectNext; this.rejectNext = null; throw e; }
        this.sent.push({ ...params[0] });
        this.applyTx(params[0]);
        // A transaction that WAS accepted, reported back in a shape the page
        // cannot follow. Everything downstream of the send fails, but the send
        // itself happened — so anything the page threw away on that failure is
        // thrown away wrongly.
        if (this.garbleNextTxHash) { this.garbleNextTxHash = false; return '0xnot-a-hash'; }
        return '0x' + (++this.nonce).toString(16).padStart(64, '0');
      }
      case 'eth_getBlockByNumber':
        return { number: params[0] === 'latest' ? this.blockNumber : params[0],
                 timestamp: '0x' + BigInt(this.blockTime).toString(16) };
      case 'eth_getTransactionReceipt': {
        // A node that has accepted a transaction but not yet mined it answers
        // null, not an error. Anything that reads a mined block's data has to
        // survive that rather than treat it as a failure.
        if (this.receiptPending) return null;
        // A transaction the wallet accepted and the chain then threw out. The
        // page only learns this here, one poll after it already told the user
        // "Sent" - so it is the only place a test can exercise what happens on
        // the far side of acceptance.
        if (this.failNextReceipt) { this.failNextReceipt = false; return { status: '0x0', transactionHash: params[0], blockNumber: this.blockNumber, logs: [] }; }
        const r = { status: '0x1', transactionHash: params[0], blockNumber: this.blockNumber };
        // `thinReceipts` drops the array entirely rather than emptying it,
        // because that is the shape the wallet RPCs which do this actually
        // return - and `receipt.logs || []` has to survive both.
        if (!this.thinReceipts) r.logs = this.lastLogs || [];
        return r;
      }
      case 'eth_signTypedData_v4': {
        if (this.rejectNext) { const e = this.rejectNext; this.rejectNext = null; throw e; }
        this.signed.push({ owner: params[0], typedData: JSON.parse(params[1]) });
        return '0x' + '11'.repeat(32) + '22'.repeat(32) + this.sigV.toString(16).padStart(2, '0');
      }
      case 'wallet_switchEthereumChain': this.chainId = params[0].chainId; return null;
      case 'wallet_revokePermissions': return null;
      case 'wallet_getCapabilities':
        if (!this.capabilities) throw Error('method not supported');
        return this.capabilities;
      case 'wallet_sendCalls': {
        if (this.rejectNext) { const e = this.rejectNext; this.rejectNext = null; throw e; }
        this.batches.push(params[0]);
        for (const c of params[0].calls) {
          const tx = { from: params[0].from, ...c, batched: true };
          this.sent.push(tx);
          this.applyTx(tx);
        }
        return { id: '0xbatch' + this.batches.length };
      }
      case 'wallet_getCallsStatus':
        if (this.callsStatusHandler) return this.callsStatusHandler({ id: params[0] });
        return { status: 200, receipts: [{ status: '0x1', transactionHash: '0x' + 'ab'.repeat(32) }] };
      default:
        throw Error(`MockChain: unhandled method ${method}`);
    }
  }

  /**
   * Apply the state a sent transaction would produce.
   *
   * Only approvals matter to the page: after approving it re-reads the
   * allowance and aborts with "approval failed" if it did not take. A mock that
   * records transactions without applying them makes that guard fire on every
   * legacy-wallet path, which looks like a page bug and is not one.
   */
  applyTx(tx) {
    const data = strip(tx.data || '');
    const sel = data.slice(0, 8);
    /* A real launch emits `Launched`, and the page reads the token out of it.
       A mock whose receipts carried no logs would leave that path untravelled
       while every launch test still passed - which is exactly how a wrong
       topic hash shipped. `owner` is head word 6 in both entry points. */
    if ((sel === '6a648dc6' || sel === '72cf7bd8') && tx.to?.toLowerCase() === PLAUNCH) {
      this.lastLogs = [{
        address: PLAUNCH,
        topics: [
          LAUNCHED_TOPIC,
          // Separate from `launchToken`, which is what the PREFLIGHT predicts.
          // They differ only under a nonce race, and a fixture that could not
          // express that could not test which of the two the page believes.
          '0x' + addrWord(this.launchLogToken || this.launchToken || '0x' + '11'.repeat(20)),
          '0x' + addrWord(this.launchPool || '0x' + '22'.repeat(20)),
          '0x' + data.slice(8 + 6 * 64, 8 + 7 * 64),
        ],
        data: '0x' + u256(0).repeat(3),
      }];
      return;
    }
    // WETH deposit actually moves the balance, because the page now funds a
    // fill out of the result: it wraps a shortfall and then pays in WETH. A
    // mock that took the wrap and left the balances alone would fail the very
    // step the wrap exists to enable.
    if (sel === SEL.WETH_DEPOSIT && tx.to?.toLowerCase() === A.WETH.toLowerCase()) {
      const v = BigInt(tx.value || 0);
      const holder = tx.from.toLowerCase();
      this.setErc20(A.WETH, holder, this.balanceOf(A.WETH.toLowerCase(), holder) + v);
      this.setNative(holder, (this.native.get(holder) ?? 0n) - v);
      return;
    }
    if (sel !== SEL.APPROVE) return;
    const body = '0x' + data.slice(8);
    this.setAllowance(tx.to, tx.from, wordAddr(body, 0), word(body, 1));
  }

  ethCall(tx, block) {
    const to = (tx.to || '').toLowerCase();
    const data = strip(tx.data || '');
    const sel = data.slice(0, 8);
    this.calls.push({ to, data: '0x' + data, block, selector: sel });

    const canned = this.answers.get(`${to}:${sel}`);
    if (canned !== undefined) {
      const v = typeof canned === 'function' ? canned('0x' + data) : canned;
      if (v !== undefined && v !== null) return v;
    }

    const rv = this.reverts.get(`${to}:${sel}`);
    if (rv) {
      const msg = typeof rv === 'function' ? rv('0x' + data) : rv;
      /* An object models a provider that returns REVERT DATA rather than only a
         string. Which of the two a wallet gives you is not something the page
         can choose, and telling a missed bound apart from a short pool depends
         on reading the selector out of whichever one arrived. */
      if (msg && typeof msg === 'object') {
        throw Object.assign(Error(msg.message || 'execution reverted'), { data: msg.data });
      }
      if (msg) throw Error(msg);
    }

    // zSwap.latest() — the tip of the successor chain, which the page reads on
    // ITSELF. Keyed by the address called so a test can serve a chain whose
    // tip is a third contract, or leave it unset for the common case: no
    // successor, and the page therefore says nothing.
    if (sel === SEL.LATEST) {
      const tip = this.lineage.get(to) ?? to;
      return '0x' + addrWord(tip);
    }
    if (sel === SEL.PREVIOUS) return '0x' + addrWord(this.previousOf.get(to) || ZERO_ADDR);
    if (sel === SEL.SUCCEEDED_AT) return '0x' + u256(this.succeededAt.get(to) || 0);

    // A plain value transfer pre-flights as a call with no calldata at all.
    if (!data) return '0x';

    if (to === A.MC3.toLowerCase() && sel === SEL.AGG3) return this.aggregate3(data, block);
    if (to === A.ZQUOTER.toLowerCase()) return this.quote(sel, data);
    if (to === A.SBVIEW.toLowerCase()) return this.lens(sel, data);
    if (to === A.FLOORVIEW.toLowerCase()) return this.floorLens(sel, data);
    // The board's OWN storage, which the page reads back before sending as a
    // last-moment staleness check. Served from the same fixtures as the lens,
    // so a test never has to state a row twice.
    if (to === A.FLOOR.toLowerCase() && sel === SEL.BIDS) return this.floorBid(data);
    // Dutchboard and Floorboard are the mirror of a Swapboard here: they count
    // with nextId() and revert on nextOrderId(). Getting this backwards is
    // silent in the page - the scan's own try/catch eats it and the feature
    // just renders nothing - so the mock has to be strict about which is which.
    if (to === A.FLOOR.toLowerCase() || to === A.DUTCH.toLowerCase()) {
      if (sel === SEL.NEXTID2) return '0x' + u256(this.nextBoardId ?? 0);
      if (sel === SEL.NEXTID) throw Error('execution reverted');
    }
    // cancel / cancelUnwrap, which Floorboard shares with Dutchboard. Both
    // boards return nothing; what matters is that the page reaches the right
    // one with the right selector, since a cancel is how escrow comes back.
    if ((to === A.FLOOR.toLowerCase() || to === A.DUTCH.toLowerCase())
      && (sel === SEL.DUTCH_CANCEL || sel === SEL.DUTCH_CANCEL_UNWRAP)) return '0x';
    // bid(Terms) — a collection bid, placed at the board directly because the
    // routed adapter hardcodes isNFT false and cannot express one.
    if (to === A.FLOOR.toLowerCase() && sel === SEL.FLOOR_BID) return '0x' + u256(1);
    // TokenList.logoOf(address) REVERTS for an unlisted token rather than
    // returning empty, which is what the page's allow-failure batch relies on.
    if (to === A.ZLISTLENS.toLowerCase() && sel === SEL.RANKEDIDS) {
      if (!this.conviction) throw Error('conviction lens unreachable');
      const ids = this.conviction.map(i => u256(i));
      return '0x' + u256(32) + u256(ids.length) + ids.join('');
    }
    if (to === A.TOKENLIST.toLowerCase() && sel === SEL.RANKEDIDS) {
      if (!this.registry) throw Error('no registry');
      const ids = this.registry.map((_, i) => u256(i + 1));
      return '0x' + u256(32) + u256(ids.length) + ids.join('');
    }
    if (to === A.TOKENLIST.toLowerCase() && sel === SEL.LISTJSON) {
      if (!this.registry) throw Error('no registry');
      const row = this.registry[Number(word('0x' + data.slice(8), 0)) - 1];
      if (!row) throw Error('no such id');
      const body = Buffer.from(JSON.stringify(row), 'utf8').toString('hex');
      return '0x' + u256(32) + u256(body.length / 2) + body.padEnd(Math.ceil(body.length / 64) * 64, '0');
    }
    if (to === A.TOKENLIST.toLowerCase() && sel === SEL.LOGOOF) {
      const logo = this.logos[wordAddr('0x' + data.slice(8), 0).toLowerCase()];
      if (!logo) throw Error('not listed');
      return encodeString(logo);
    }
    if (sel === SEL.TOKENURI) {
      const c = this.cards[`${to}:${word('0x' + data.slice(8), 0)}`];
      if (!c) throw Error('no card');
      return encodeString('data:application/json;base64,' +
        Buffer.from(JSON.stringify(c)).toString('base64'));
    }
    if (sel === SEL.INITIAL_B) {
      const v = this.initialAmountB[`${to}:${word('0x' + data.slice(8), 0)}`];
      return '0x' + u256(v ?? 0);
    }
    if ((to === A.SB2.toLowerCase() || to === A.SB1.toLowerCase()) && sel === SEL.GETORDERS) {
      return this.boardOrders(to, data);
    }
    // Swapbol.floorboard(). The page probes this before it will plan a bid leg,
    // because the page and the executor ship separately: an executor without
    // the binding rejects the leg after the user has already signed.
    if (to === A.SWAPBOL.toLowerCase() && sel === SEL.BOL_FLOOR) {
      return '0x' + addrWord(this.swapbolFloorboard ?? A.FLOOR);
    }
    if (to === A.DUTCH.toLowerCase() && sel === SEL.DUTCH_LISTING) return this.dutchListing(data);
    if (to === A.SLOW.toLowerCase()) return this.slow(sel, data, tx);
    // SLOW's tip gate: `tips(transferId) -> (uint96 amount, address sender)`.
    // refundTip is state-changing and only pre-flighted, so it answers empty.
    if (to === A.SLOW_GATE.toLowerCase()) {
      if (sel === SEL.TIPS) {
        const t = this.slowTips.get(word('0x' + data.slice(8), 0).toString());
        return '0x' + u256(t ?? 0) + addrWord(t ? this.accounts[0] : A.ZERO);
      }
      return '0x';
    }
    if (to === A.ZROUTER.toLowerCase()) return '0x';          // pre-flight eth_call
    // The same, for a write sent straight at a Precision pool. doRemove/doAdd
    // bypass the router, and the page simulates them before asking for a
    // signature - a node answers that call, so the fixture has to as well or
    // the pre-flight reads as a revert and no transaction is ever sent.
    // The degraded exit is the same shape: pre-flighted at the pool, answered
    // by a node. A test that wants it to FAIL says so with `revertOn`, whose
    // message may be a function of the calldata - `take0`/`take1` are arguments
    // to one selector, so a pool that can only pay one side is not something a
    // flat selector map can express.
    if ((sel === SEL.REMOVE || sel === SEL.ADDEXACT || sel === SEL.REMOVE_LOSSY)
      && this.poolRow(to)) return '0x';
    // V4QuoteLens.quoteV4Hooked(bool,address,address,uint24,int24,address,uint256)
    // Returns (amountIn, amountOut); zero means "no route", never "free".
    if (to === A.V4LENS.toLowerCase()) {
      const body = '0x' + data.slice(8);
      const q = this.v4Quote && this.v4Quote({
        tokenIn: wordAddr(body, 1), tokenOut: wordAddr(body, 2),
        fee: Number(word(body, 3)), ts: Number(word(body, 4)),
        hooks: wordAddr(body, 5), amountIn: word(body, 6),
      });
      return coder.encode(['uint256', 'uint256'], [q ? word(body, 6) : 0n, q || 0n]);
    }
    if (to === A.V4PORT.toLowerCase()) return '0x';           // pre-flight eth_call
    if (to === A.SB2.toLowerCase() || to === A.SB1.toLowerCase()) return this.board(sel, data);
    if (sel === SEL.MARKETS) {
      const body = '0x' + data.slice(8);
      const rows = this.pools.get(`${wordAddr(body, 0)}:${wordAddr(body, 1)}`) || [];
      // PoolInfo is a static struct, so the array is 19 flat words per row.
      return coder.encode([POOL_INFO], [rows.map(r => [
        r.pool, A.ZERO, A.ZERO, BigInt(r.sqrtLow), BigInt(r.sqrtHigh), BigInt(r.fee),
        BigInt(r.reserve0), BigInt(r.reserve1), BigInt(r.sqrtNow), BigInt(r.liquidity),
        r.hook, A.ZERO, BigInt(r.creatorFeeBps ?? 0n), 0n,
        r.hook === A.ZERO ? 1n : 0n, 0n, 0n, 0n, 0n,
      ])]);
    }
    // PrecisionPoolFactory.isPool — the trust anchor the liquidity write paths
    // ask before granting an allowance or sending value. Only pools this
    // fixture registered are its own.
    // poolFor(Market) — the address is CREATE2-derived, so the page can ask
    // what a band WOULD be before anything is deployed. The fixture only has
    // to be deterministic in the market, which is what the real one is.
    if (to === A.PFACTORY.toLowerCase() && sel === SEL.POOLFOR) {
      const body = data.slice(8);           // Market is static: encoded inline
      const key = keccak256('0x' + body).slice(0, 42);
      this.__predicted ||= new Map();
      this.__predicted.set(key.toLowerCase(), '0x' + body);
      // `seedDeployed` models the case the factory documents: the market was
      // created and left unseeded, so the lens CAN answer for it.
      if (this.seedDeployed && !this.code.has(key.toLowerCase())) {
        this.code.set(key.toLowerCase(), '0x60006000f3');
      }
      return '0x' + addrWord(key);
    }
    // createAndSeed. The preflight is where the page discovers how wide a band
    // this deposit can back, so the fixture has to be able to REFUSE one:
    // width is bought with capital, and the pool reverts InsufficientLiquidity
    // when the virtual reserves would fall below MIN_RESOLUTION.
    if (to === A.PFACTORY.toLowerCase() && sel === SEL.CREATE_SEED) {
      if (this.rejectWiderThan != null) {
        const body = '0x' + data.slice(8);
        const lo = word(body, 2), hi = word(body, 3);
        // Widths are compared in sqrt space, where a band of n times each way
        // spans sqrt(n) either side - so hi/lo is n, not n squared.
        const width = lo === 0n ? Infinity : Number((hi * 1000n) / lo) / 1000;
        if (width > this.rejectWiderThan) throw Error('InsufficientLiquidity');
      }
      return '0x' + '00'.repeat(128);
    }
    // poolsForPairCount — how many bands the pair has, which the page reads
    // before deciding how wide a window to ask for. `_byPair` is append-only,
    // so a fixed window hides anything created after it.
    /* PrecisionPoolPolicy.isRoutableBatch. `blocked` is what the owner has
       declined; `policyUnreadable` is the OTHER answer the page has to handle,
       because an unreadable policy must allow rather than disable the venue. */
    if (to === A.PPOLICY.toLowerCase() && sel === SEL.ROUTABLE_BATCH) {
      if (this.policyUnreadable) throw Error('policy unreachable');
      const [pools] = coder.decode(['address[]'], '0x' + data.slice(8));
      return coder.encode(['bool[]'],
        [pools.map(p => !this.blocked.has(p.toLowerCase()))]);
    }
    if (to === A.PFACTORY.toLowerCase() && sel === SEL.PAIR_COUNT) {
      const body = '0x' + data.slice(8);
      const rows = this.pools.get(`${wordAddr(body, 0)}:${wordAddr(body, 1)}`) || [];
      return '0x' + u256(this.pairCount ?? rows.length);
    }
    /* SafeSummoner.safeSummonDAICO, simulated. The page pre-flights the launch
       with an eth_call so a summon the chain would refuse costs nothing;
       without an answer here that preflight throws and no cause is ever sent.
       The page predicts the DAO address itself rather than reading this, so
       what comes back only has to be well-formed. */
    if (sel === '4e1e3b11') return '0x' + addrWord(A.CAUSE_DAO);
    /* ShareOffering, which is where a cause is BOUGHT. Keyed by DAO, so the
       fixture is found through the cause whose dao matches the argument. */
    if (to === A.OFFERING.toLowerCase() && (sel === 'c6b9f06a' || sel === 'b399b0bc' || sel === 'cce7ec13')) {
      if (sel === 'cce7ec13') return '0x';   // buy() is state-changing; this is the pre-flight
      const dao = wordAddr('0x' + data.slice(8), 0).toLowerCase();
      const c = [...this.causes.values()].find(x => x.dao === dao);
      if (!c) return '0x' + u256(0);
      if (sel === 'b399b0bc') return '0x' + u256(c.remaining);
      // sales(dao) -> (token, payToken, deadline, price, cap)
      return '0x' + addrWord(c.saleToken) + addrWord(c.salePayToken)
        + u256(c.deadline) + u256(c.price) + u256(c.cap);
    }
    /* TapVest. The tap accrues but never moves on its own, so the page reads
       `taps` and the DAO's allowance to work out what a claim would actually
       pay - and reproduces TapVest's whole-second flooring while doing it. */
    if (to === A.TAPVEST.toLowerCase()) {
      if (sel === '1e83409a') return '0x' + u256(0);   // claim(dao) — pre-flight
      if (sel === '6144452a') {                        // taps(dao)
        const c = [...this.causes.values()].find(x => x.dao === wordAddr('0x' + data.slice(8), 0).toLowerCase());
        if (!c) return '0x' + u256(0).repeat(4);
        // (token, beneficiary, ratePerSec, lastClaim)
        return '0x' + addrWord(A.ZERO) + addrWord(c.beneficiary ?? A.ACCOUNT)
          + u256(c.ratePerSec ?? 0n) + u256(c.lastClaim ?? 0n);
      }
    }
    /* A cause DAO and its loot, which have to be answered ahead of the pool
       and ERC20 paths below: a loot token's totalSupply is neither a pool's
       liquidity nor a seeded supply, and an address with no fixture code
       answers '0x' down there, which the page would read as no cause at all. */
    const asLoot = this.causes.get(to);
    if (asLoot && sel === SEL_CAUSE.DAO) return '0x' + addrWord(asLoot.dao);
    const asDao = [...this.causes.values()].find(c => c.dao === to);
    if (asDao) {
      if (sel === SEL_CAUSE.LOOT) {
        return '0x' + addrWord([...this.causes.entries()].find(([, c]) => c === asDao)[0]);
      }
      if (sel === SEL_CAUSE.SHARES) return '0x' + addrWord(asDao.shares);
      // Moloch's allowance[token][spender] — the tap's remaining budget.
      if (sel === SEL.ALLOWANCE) return '0x' + u256(asDao.tapBudget ?? 0n);
      // ragequit is state-changing; the page pre-flights it before signing.
      if (sel === SEL_CAUSE.RAGEQUIT) return '0x';
    }
    if (sel === SEL.TOTALSUPPLY) {
      const byLoot = this.causes.get(to);
      if (byLoot) return '0x' + u256(byLoot.lootSupply);
      const byShares = [...this.causes.values()].find(c => c.shares === to);
      if (byShares) return '0x' + u256(byShares.sharesSupply);
    }
    // totalSupply on a pool. The create form asks the PREDICTED address, and a
    // CREATE2 address with no code answers an eth_call with EMPTY returndata
    // rather than failing - which is not the same as answering zero, and the
    // page has to tell the two apart. So an undeployed address returns '0x'
    // here, exactly as a node would.
    if (sel === SEL.TOTALSUPPLY) {
      const row = this.poolRow(to);
      if (row) return '0x' + u256(row.liquidity);
      if (!this.code.has(to) || this.code.get(to) === '0x') return '0x';
      return '0x' + u256(this.seedSupply ?? 0n);
    }
    if (to === A.PFACTORY.toLowerCase() && sel === SEL.BY_CREATOR_N) {
      return '0x' + u256((this.launched || []).length);
    }
    /* Honours `start`/`count`, because the page's whole reason for asking the
       COUNT first is to request the tail rather than the head - a mock that
       ignored the window would pass either way and prove nothing. */
    if (to === A.PFACTORY.toLowerCase() && sel === SEL.BY_CREATOR) {
      const l = this.launched || [];
      const start = Number(BigInt('0x' + data.slice(8 + 64, 8 + 128)));
      const count = Number(BigInt('0x' + data.slice(8 + 128, 8 + 192)));
      return coder.encode(['address[]'], [l.slice(start, start + count).map(x => x.pool)]);
    }
    /* PrecisionPool.creatorFeeBps - an IMMUTABLE, zero on an ordinary pool and
       nonzero on one a launcher created, which is how the page tells how much
       of the headline fee actually reaches LPs. A row opts in with
       `creatorFeeBps` in setPools. */
    /* Chainlink ETH/USD `latestRoundData`. Absent a fixture the page gets
       nothing and simply shows no dollar figure, which is the honest default -
       a wrong price is worse than none. `ethUsd` opts a test in, `ethUsdAge`
       drives the staleness refusal. */
    if (sel === 'feaf968c' && to === '0x5f4ec3df9cbd43714fe2740f5e3616155c5b8419') {
      if (this.ethUsd === undefined) throw Error('no feed');
      const now = Math.floor(Date.now() / 1000) - (this.ethUsdAge ?? 0);
      return '0x' + u256(1) + u256(BigInt(Math.round(this.ethUsd * 1e8)))
        + u256(now) + u256(now) + u256(1);
    }
    if (sel === '17773ebb') {
      const r = this.poolRow(to);
      return '0x' + u256(r?.creatorFeeBps ?? 0n);
    }
    /* PrecisionPool.hook - also an IMMUTABLE, and zero on every pool the
       launcher makes. The page refuses to ZAP into a hooked pool, because a
       hook makes previewZap model a different sender and a different reserve
       transition than the route actually executes. A row opts in with `hook`
       in setPools; the default of zero is what a plain pool reports. */
    if (sel === '7f5a7c7b') {
      const r = this.poolRow(to);
      return '0x' + addrWord(r?.hook || ZERO_ADDR);
    }
    /* PrecisionPool.feeRecipient - an IMMUTABLE that holds the LAUNCHER on a
       pool the launcher made, and something else (or nothing) on any other
       pool. The page carries pools forward from a previous visit through
       localStorage, which is a store the page itself wrote and so is only as
       trustworthy as the browser; this is what it checks them against before
       pricing them as launches. A row opts out with `feeRecipient` in
       setLaunched. */
    /* WNS ownerOf / text(id,"score") for a name the score card is asked about.
       A fixture opts in with `scoreName = {owner, record}`; owner ZERO means the
       name was never minted. */
    if (this.scoreName && to === A.WNS.toLowerCase() && (sel === '6352211e' || sel === '308e3386')) {
      if (sel === '6352211e') {
        if (!this.scoreName.owner || this.scoreName.owner === ZERO_ADDR) throw Error('nonexistent token');
        return '0x' + addrWord(this.scoreName.owner);
      }
      const v = this.scoreName.record || '';
      const hex = Buffer.from(v, 'utf8').toString('hex');
      return '0x' + u256(0x20) + u256(v.length) + hex.padEnd(Math.ceil(hex.length / 64) * 64, '0');
    }
    if (sel === '46904840') {
      const hit = this.anyPool(to);
      if (!hit) return '0x' + addrWord(ZERO_ADDR);
      return '0x' + addrWord(hit.feeRecipient || PLAUNCH);
    }
    if (sel === SEL.RESERVE0) {
      const hit = this.anyPool(to);
      return '0x' + u256(hit?.reserve0 ?? 0n);
    }
    if (sel === SEL.TOKEN1) {
      const hit = this.anyPool(to);
      if (hit) return '0x' + addrWord(hit.token);
    }
    if (to === A.PFACTORY.toLowerCase() && sel === SEL.ISPOOL) {
      const who = wordAddr('0x' + data.slice(8), 0);
      return coder.encode(['bool'],
        [!!this.poolRow(who) && !this.disowned.has(who.toLowerCase())]);
    }
    // PrecisionPoolLens.quoteBestFor — the pair's own bands as a quote source.
    // zQuoter predates Precision and cannot see these pools at all, so a market
    // can be live, funded and quotable and still be invisible to the router.
    if (sel === SEL.QUOTE_BEST) {
      /**
       * THE PAIR IS PART OF THE QUESTION, and the mock has to say so.
       *
       * The factory pages pools by the SORTED pair, and a native market is
       * stored under address(0) because the pool holds ether. Answering
       * regardless of which pair was asked for made this mock agree with any
       * lookup, including a wrong one - so a page that asked for (ZORG, WETH)
       * when the market is (ETH, ZORG) got a quote here and "no route" on
       * chain. Exactly the shape that let a Swapbatch struct mismatch live
       * behind twenty passing tests. Matching on it is also what lets several
       * markets coexist, which a hub hop needs.
       */
      const body0 = '0x' + data.slice(8);
      const askedPair = [wordAddr(body0, 0).toLowerCase(), wordAddr(body0, 1).toLowerCase()].sort();
      const rows = this.precisionList()
        .filter(x => (x.pair || [A.ZERO, A.USDC]).map(a => a.toLowerCase()).sort().join()
          === askedPair.join());
      if (!rows.length) return coder.encode(['address', 'uint256'], [A.ZERO, 0n]);
      /* THE BEST of them, not the first. Several pools may share a pair — that
         is the case where the policy screen has somewhere to send the page when
         it declines one — and `quoteBestFor` is defined as the maximum. A mock
         that answered with whichever was declared first would let a page that
         re-picked wrongly still look right. */
      let best = null;
      for (const q of rows) {
        const out = this.precisionOut(q, word('0x' + data.slice(8), 4));
        if (!best || out > best.out) best = { pool: q.pool, out };
      }
      return coder.encode(['address', 'uint256'], [best.pool, best.out]);
    }
    /* `quoteAllFor` — every pool in the pair, not just the winner. The page
       falls back to it when the policy declines the winner, so that one refused
       pool cannot take a whole pair down with it. */
    if (sel === SEL.QUOTE_ALL) {
      const body = '0x' + data.slice(8);
      const asked = [wordAddr(body, 0).toLowerCase(), wordAddr(body, 1).toLowerCase()].sort();
      const amt = word(body, 4);
      const rows = this.precisionList().filter(x =>
        (x.pair || [A.ZERO, A.USDC]).map(a => a.toLowerCase()).sort().join() === asked.join());
      return coder.encode(['tuple(address,uint256,uint256)[]'],
        [rows.map(q => [q.pool, this.precisionOut(q, amt), BigInt(q.fee ?? 3000)])]);
    }
    if (sel === SEL.POOL_FEE && this.precisionQuote) {
      return '0x' + u256(this.precisionAt(to)?.fee ?? 3000);
    }
    /* `effectiveFee` on the lens. The page stopped reading the pool's own
       `fee()` because that is only the BASE rate - a hooked pool charges more,
       so reading it off the pool understates what the trade actually pays.
       Without an answer here the read falls into its `catch`, the fee comes
       back zero, and the rate line silently drops the tier: "Precision"
       instead of "Precision 0.3%". */
    if (sel === SEL.EFF_FEE && this.precisionQuote) {
      // Asked ABOUT A POOL, so answer about that one: a two-hop route composes
      // the two rates, and a mock that returns the same number for both cannot
      // tell a correct composition from a doubled first hop.
      const q = this.precisionAt(wordAddr('0x' + data.slice(8), 0));
      return '0x' + u256(q?.effFee ?? q?.fee ?? 3000);
    }
    // swapExactIn on the pool itself. The page preflights every send with
    // eth_call, so a pool that cannot answer this reads as a broken route
    // rather than as a thin fixture.
    if (sel === SEL.PSWAP && this.precisionAt(to)) {
      return '0x' + u256(this.precisionAt(to).out);
    }
    if (to === A.PLQLENS.toLowerCase()) {
      const body = '0x' + data.slice(8);
      const row = this.poolRow(wordAddr(body, 0));
      if (sel === SEL.PREVIEW_REMOVE) {
        const shares = word(body, 1), supply = row ? BigInt(row.liquidity) : 0n;
        if (!row || shares === 0n || supply === 0n || shares > supply) {
          return coder.encode(['bool', 'uint256', 'uint256'], [false, 0n, 0n]);
        }
        const a0 = shares * BigInt(row.reserve0) / supply;
        const a1 = shares * BigInt(row.reserve1) / supply;
        return coder.encode(['bool', 'uint256', 'uint256'],
          [a0 !== 0n || a1 !== 0n, a0, a1]);
      }
      // previewSeed(pool, sqrtPriceInit, amount0, amount1). An unseeded band is
      // the ONLY case here, so this models the shape the page depends on: `ok`
      // false when the opening price sits outside the band, and amounts that
      // may be less than offered because a seed takes the ratio it needs.
      if (sel === SEL.PREVIEW_SEED) {
        const out = ['bool', 'uint256', 'uint256', 'uint256'];
        const sp = word(body, 1), a0 = word(body, 2), a1 = word(body, 3);
        const band = this.seedBand;
        // The lens reads the band OFF THE POOL, so against an address with no
        // code it reverts rather than answering false. That is the ordinary
        // case when creating - the pool does not exist yet - and modelling it
        // as a polite `false` is what let a page ship that could never have
        // previewed anything on mainnet.
        if (!this.code.has(wordAddr(body, 0).toLowerCase())) throw Error('no pool at that address');
        if (!band || sp < band.low || sp > band.high || (a0 === 0n && a1 === 0n)) {
          return coder.encode(out, [false, 0n, 0n, 0n]);
        }
        // Enough to exercise the page: both sides are used in full unless the
        // fixture says otherwise, and lp is their sum.
        const used0 = band.used0 ?? a0, used1 = band.used1 ?? a1;
        return coder.encode(out, [true, used0 + used1, used0, used1]);
      }
      // previewZap(pool, tokenIn, amountIn) -> (ok, swapPortion, expectedLp).
      // The real lens BISECTS for the split against the pool's own quoter; the
      // page treats both numbers as opaque, so what has to be modelled is the
      // contract of the answer, not its arithmetic: refused when the band has
      // no supply or the token is not in the pair, and a portion strictly
      // inside the input otherwise (`zapIn` reverts on portion == amountIn).
      if (sel === SEL.PREVIEW_ZAP) {
        const out = ['bool', 'uint256', 'uint256'];
        const tokenIn = wordAddr(body, 1).toLowerCase(), amountIn = word(body, 2);
        const supply = row ? BigInt(row.liquidity) : 0n;
        const known = (this.poolPair(wordAddr(body, 0)) || []).includes(tokenIn);
        if (!row || supply === 0n || !known || amountIn < 2n) {
          return coder.encode(out, [false, 0n, 0n]);
        }
        const portion = this.zapPortion ?? amountIn / 2n;
        const lp = this.zapLp ?? amountIn / 4n;
        return coder.encode(out, [true, portion, lp]);
      }
      if (sel === SEL.PREVIEW_ADD) {
        const off = ['bool', 'uint256', 'uint256', 'uint256', 'uint256', 'uint256'];
        const a0 = word(body, 1), a1 = word(body, 2);
        const supply = row ? BigInt(row.liquidity) : 0n;
        const r0 = row ? BigInt(row.reserve0) : 0n, r1 = row ? BigInt(row.reserve1) : 0n;
        if (!row || supply === 0n || r0 === 0n || r1 === 0n) {
          return coder.encode(off, [false, 0n, 0n, 0n, 0n, 0n]);
        }
        // min of each side's proportional share, then ceil back the amounts
        // that share actually consumes — the lens formula exactly.
        const lp = (x => (x < a1 * supply / r1 ? x : a1 * supply / r1))(a0 * supply / r0);
        const ceil = (n, d) => (n + d - 1n) / d;
        const used0 = ceil(lp * r0, supply), used1 = ceil(lp * r1, supply);
        if (lp === 0n || used0 > a0 || used1 > a1) {
          return coder.encode(off, [false, 0n, 0n, 0n, 0n, 0n]);
        }
        return coder.encode(off, [true, lp, used0, used1, a0 - used0, a1 - used1]);
      }
    }
    if (sel === SEL.TAPE) {
      const body = '0x' + data.slice(8);
      const bars = this.tapes.get(`${to}:${Number(word(body, 0))}`) || [];
      const count = Number(word(body, 1));
      return coder.encode(['uint256[]'],
        /* A bar may be given already PACKED - a bigint or decimal string, as
           `tape()` returns it on chain. That lets a fixture replay a tape a
           real pool actually wrote, rather than one hand-assembled here, where
           the volume need not agree with the price move it sits under. */
        [bars.slice(0, count).map(b =>
          b === null ? 0n
          : (typeof b === 'bigint' || typeof b === 'string') ? BigInt(b)
          : encodeTapeBar(b))]);
    }
    if (to === A.WNS.toLowerCase() || to === A.GNS.toLowerCase()) return this.ns(sel, data);
    if (to === A.ENSREG.toLowerCase()) {
      if (sel === SEL.ENS_RSLV) {
        // A resolver pinned to one node beats the flat default, so a test can
        // give an ANCESTOR one while the exact node has none — the shape the
        // ENSIP-10 walk exists for, and the one a single flat field cannot say.
        const node = '0x' + strip(data).slice(8, 72);
        if (this.ensResolvers.has(node)) return '0x' + addrWord(this.ensResolvers.get(node));
        return '0x' + addrWord(this.ensResolver);
      }
      throw Error(`MockChain: unhandled ENS registry selector ${sel}`);
    }
    if (to === A.ENSRESOLVER.toLowerCase()) return this.ensResolve(sel, data);
    return this.erc20Call(to, sel, data, tx);
  }

  aggregate3(data, block) {
    // aggregate3((address target,bool allowFailure,bytes callData)[])
    const [calls] = coder.decode(['tuple(address,bool,bytes)[]'], '0x' + data.slice(8));
    // Every provider caps eth_call, at its own undocumented value, and refuses
    // the whole request rather than returning partial results. `batchLimit`
    // reproduces that: allowFailure cannot help, because the batch never runs.
    if (calls.length > this.batchLimit) throw Error('out of gas');
    // A node whose per-call budget cannot cover the read fails EVERY call while
    // the batch itself returns fine. That is not the same as `batchLimit`, which
    // kills the whole request - here allowFailure works exactly as designed and
    // hands back a full set of failures, which look identical to "no liquidity".
    // Seen for real: an exact-out quote against a fork whose eth_call gas cap is
    // below what the heaviest probe needs.
    if (this.failEveryCall) {
      return coder.encode(['tuple(bool,bytes)[]'], [calls.map(() => [false, '0x'])]);
    }
    const results = calls.map(([target, , callData]) => {
      try {
        return [true, this.ethCall({ to: target, data: callData }, block)];
      } catch {
        return [false, '0x'];
      }
    });
    return coder.encode(['tuple(bool,bytes)[]'], [results]);
  }

  quote(sel, data) {
    if (!this.quoteHandler) throw Error('MockChain: no quoteHandler installed');
    const out = this.quoteHandler({ selector: sel, data: '0x' + data, chain: this });
    if (out == null) throw Error('no route');
    return out;
  }

  /**
   * The lens is asked once per board (Swapboard v2, v1, Dutch). Every request
   * names its board in the first argument, so rows must be filtered by it —
   * returning the whole set to each board makes the page render duplicates and
   * quietly doubles any book-vs-AMM comparison.
   */
  lens(sel, data) {
    const board = wordAddr('0x' + data.slice(8), 0).toLowerCase();
    const pick = (rows, dutch) => encodeViewPage(
      rows.filter(r => !!r.dutch === dutch && r.board.toLowerCase() === board), 0n);
    if (sel === SEL.CANDS) return pick(this.candidates, false);
    if (sel === SEL.DUTCH_CANDS) return pick(this.candidates, true);
    if (sel === SEL.RECENT) return pick(this.recent, false);
    if (sel === SEL.RECENT_DUTCH) return pick(this.recent, true);
    throw Error(`MockChain: unhandled lens selector ${sel}`);
  }

  /**
   * FloorboardView. `floorCandidatesFrom` is asked with the taker's own
   * (tokenIn, tokenOut) and must answer with bids that BUY tokenIn — the
   * mirror of an ask — so the filter here is deliberately written the same way
   * round as the real lens rather than passing everything through.
   */
  floorLens(sel, data) {
    const body = '0x' + data.slice(8);
    if (sel === SEL.FLOOR_CANDS) {
      const tokenIn = wordAddr(body, 1).toLowerCase();
      const tokenOut = wordAddr(body, 2).toLowerCase();
      return encodeBidPage(this.floorBids.filter(b =>
        !b.isNFT
        && b.token.toLowerCase() === tokenIn
        && b.quote.toLowerCase() === tokenOut), 0n);
    }
    if (sel === SEL.RECENT_FLOOR) return encodeBidPage(this.floorBids, 0n);
    if (sel === SEL.COLL_BIDS) {
      const collection = wordAddr(body, 1).toLowerCase();
      return encodeBidPage(this.floorBids.filter(b =>
        b.isNFT && b.token.toLowerCase() === collection), 0n);
    }
    throw Error(`MockChain: unhandled floor lens selector ${sel}`);
  }

  /**
   * `Floorboard.bids(id)` — the generated mapping getter, which DROPS the
   * struct's trailing dynamic `ids`, so it is eleven flat words.
   */
  floorBid(data) {
    const id = word('0x' + data.slice(8), 0);
    const b = this.floorBids.find(x => BigInt(x.id) === id);
    // A slot that never existed answers with a zero bidder rather than
    // reverting — that is what the real getter does, and the page treats it
    // as "closed".
    if (!b) return '0x' + '0'.repeat(64 * 11);
    return '0x' + [
      addrWord(b.bidder || A.OTHER), u256(b.isNFT ? 1 : 0),
      // Word three is the bid's DURATION, not its expiry: the window is stated
      // as a length and the lens is what adds it to `startTime`. Start and end
      // price are distinct on a climbing bid, and default to the flat `price`.
      u256(b.startTime || 0), u256(b.duration ?? 0),
      addrWord(b.token), u256(b.startPrice ?? b.price),
      addrWord(b.quote), u256(b.endPrice ?? b.price),
      u256(b.price), u256(b.initial ?? b.remaining), u256(b.remaining),
    ].join('');
  }

  /**
   * `Swapboard.getOrders(uint256[])`. The struct is static, so it inlines: six
   * words on the legacy board, eleven on the current one. Offset, length, body.
   */
  boardOrders(board, data) {
    const body = '0x' + data.slice(8);
    // (offset, length, id...) — the page asks for exactly one.
    const id = word(body, 2);
    const rows = [...this.recent, ...this.candidates];
    const o = rows.find(r => BigInt(r.id) === id && r.board.toLowerCase() === board);
    const v2 = board === A.SB2.toLowerCase();
    const words = o
      ? (v2
        ? [addrWord(o.maker || A.OTHER), u256(1), u256(o.pf ? 1 : 0), u256(o.exp || 0),
           u256(o.nA ? 1 : 0), u256(o.nB ? 1 : 0), addrWord(o.cp || A.ZERO),
           addrWord(o.tA), u256(o.aA), addrWord(o.tB), u256(o.aB)]
        : [addrWord(o.maker || A.OTHER), u256(1),
           addrWord(o.tA), u256(o.aA), addrWord(o.tB), u256(o.aB)])
      // `active = 0` is how the real board reports a filled or cancelled id.
      : new Array(v2 ? 11 : 6).fill(u256(0));
    return '0x' + u256(32) + u256(1) + words.join('');
  }

  dutchListing(data) {
    const id = word('0x' + data.slice(8), 0).toString();
    const l = this.dutchListings.get(id);
    if (!l) throw Error('no listing');
    // decViewPage-independent: loadBook reads words 2,3,5,7,8,9 of a >=20-word blob
    const w = new Array(20).fill(0n);
    w[2] = BigInt(l.start); w[3] = BigInt(l.duration);
    w[5] = BigInt(l.startPrice); w[7] = BigInt(l.endPrice);
    w[8] = BigInt(l.initial); w[9] = BigInt(l.remaining);
    return '0x' + w.map(u256).join('');
  }

  /**
   * WNS/GNS name registry. nameToId hashes the label off-chain in the page, so
   * the mock just needs a stable name <-> id round-trip: id is the index of the
   * name in an interning table, and ownerOf(id) returns the mapped address.
   */
  ns(sel, data) {
    const body = '0x' + data.slice(8);
    if (sel === SEL.NS_CID) {
      const [name] = coder.decode(['string'], body);
      this.__nsNames ||= [];
      let i = this.__nsNames.indexOf(name.toLowerCase());
      if (i < 0) i = this.__nsNames.push(name.toLowerCase()) - 1;
      return '0x' + u256(i + 1);
    }
    if (sel === SEL.NS_RES) {
      const name = (this.__nsNames || [])[Number(word(body, 0)) - 1];
      const a = name && this.names.get(name);
      if (!a) return '0x' + addrWord(A.ZERO);
      return '0x' + addrWord(a);
    }
    if (sel === SEL.NS_REV) {
      const n = this.reverse.get(wordAddr(body, 0).toLowerCase());
      if (!n) throw Error('no reverse record');
      return encodeString(n);
    }
    throw Error(`MockChain: unhandled name-service selector ${sel}`);
  }

  /**
   * An ENS resolver, keyed by NAME rather than node.
   *
   * The page reaches a name two ways — addr(node) when the exact node owns the
   * resolver, resolve(dnsName, addr(node)) when an ancestor does — and the whole
   * point of the second path is that the node alone no longer identifies the
   * name. So the mock indexes `ensNames` by name and namehashes it on the way
   * in, which lets one map answer both paths and keeps a test from having to
   * know which one the page will choose.
   */
  ensResolve(sel, data) {
    const body = '0x' + data.slice(8);
    if (sel === SEL.ENS_SUPPORTS) {
      const id = strip(data).slice(8, 16);
      return '0x' + u256(id === SEL.ENS_RESOLVE && this.ensWildcard ? 1 : 0);
    }
    const byNode = node => {
      for (const [name, addr] of this.ensNames)
        if (ensNamehash(name) === node) return addr;
      return null;
    };
    if (sel === SEL.ENS_EADDR) return '0x' + addrWord(byNode(wordHex(body, 0)) || A.ZERO);
    if (sel === SEL.ENS_ENAME) {
      for (const [addr, name] of this.ensRevNames)
        if (ensNamehash(strip(addr).toLowerCase() + '.addr.reverse') === wordHex(body, 0))
          return encodeString(name);
      return encodeString('');
    }
    if (sel === SEL.ENS_RESOLVE) {
      // A CCIP resolver answers a plain call with a revert, not a value.
      if (this.ensOffchain) { const e = Error('execution reverted'); e.data = '0x556f1830'; throw e; }
      const [dns, inner] = coder.decode(['bytes', 'bytes'], body);
      const name = dnsDecode(dns);
      const a = this.ensNames.get(name) || A.ZERO;
      if (strip(inner).slice(0, 8) !== SEL.ENS_EADDR) return coder.encode(['bytes'], ['0x']);
      return coder.encode(['bytes'], ['0x' + addrWord(a)]);
    }
    throw Error(`MockChain: unhandled ENS resolver selector ${sel}`);
  }

  board(sel, data) {
    // A Swapboard counts with nextOrderId() and has no nextId() at all; the
    // real contract has no fallback, so asking for the wrong one reverts.
    if (sel === SEL.NEXTID) return '0x' + u256(this.nextOrderId ?? 0);
    if (sel === SEL.NEXTID2) throw Error('execution reverted');
    /**
     * `quoteFill(orderId, fillAmountB) -> (outA, paidB)`.
     *
     * The board answering the question a partial fill will later ask it. The
     * page deliberately does NOT compute this itself: `_computeFill` floors
     * with `fullMulDiv` in the maker's favour, and a page that re-derived it
     * would disagree by a wei sooner or later and revert on its own floor. So
     * the mock rounds the same way the board does, or it would be testing an
     * agreement that does not exist on chain.
     */
    if (sel === SEL.QUOTEFILL) {
      const body = '0x' + data.slice(8);
      const id = word(body, 0).toString();
      const pay = word(body, 1);
      const o = [...this.recent, ...this.candidates].find(x => String(x.id) === id);
      if (!o) return '0x' + u256(0) + u256(0);
      if (pay >= o.aB) return '0x' + u256(o.aA) + u256(o.aB);
      return '0x' + u256((pay * o.aA) / o.aB) + u256(pay);   // floors, as the board does
    }
    return '0x'; // fill/cancel are pre-flighted with eth_call before signing
  }

  slow(sel, data, tx = {}) {
    const arr = ids => coder.encode(['uint256[]'], [ids.map(BigInt)]);
    /**
     * The tipped deposit splits msg.value into amount and tip and insists the
     * two add up exactly — unlike depositTo, which reads a native amount out
     * of msg.value and accepts a zero argument. Both rules are enforced by the
     * real contract (InvalidAmount / a value mismatch), so they are enforced
     * here: a page that encodes the deposit like the untipped one reverts on
     * chain, and this is where that has to be caught.
     */
    if (sel === SEL.DEPOSITTIP) {
      const body = '0x' + data.slice(8);
      const native = wordAddr(body, 0) === A.ZERO;
      const amount = word(body, 2), tip = word(body, 4);
      const value = BigInt(tx.value ?? 0);
      if (amount === 0n) throw Error('SLOW: InvalidAmount — a tipped deposit must state its amount');
      if (tip === 0n) throw Error('SLOW: a tipped deposit with no tip');
      if (value !== (native ? amount + tip : tip)) {
        throw Error(`SLOW: msg.value ${value} does not equal ${native ? 'amount + tip' : 'tip'}`);
      }
      return '0x' + u256(1);
    }
    if (sel === SEL.GUARDIAN) return '0x' + addrWord(this.slowGuardian);
    if (sel === SEL.OUT) return arr(this.slowOut);
    if (sel === SEL.IN) return arr(this.slowIn);
    if (sel === SEL.PENDING) {
      const id = word('0x' + data.slice(8), 0).toString();
      const p = this.slowPending.get(id);
      if (!p) return '0x' + u256(0).repeat(5);
      return '0x' + [p.timestamp, 0, 0, p.id, p.amount].map(u256).join('');
    }
    // depositTo / claim / reverse+withdraw are state-changing; the page
    // pre-flights each one with eth_call before asking the wallet to sign.
    return '0x';
  }

  erc20Call(to, sel, data, tx) {
    const m = this.meta.get(to);
    switch (sel) {
      case SEL.BALANCEOF: return '0x' + u256(this.balanceOf(to, wordAddr('0x' + data.slice(8), 0)));
      case SEL.ALLOWANCE: {
        const body = '0x' + data.slice(8);
        return '0x' + u256(this.allowanceOf(to, wordAddr(body, 0), wordAddr(body, 1)));
      }
      case SEL.SYMBOL:
        if (!m) throw Error('no symbol');
        return encodeString(m.symbol);
      case SEL.NAME:
        if (!m) throw Error('no name');
        return encodeString(m.name ?? m.symbol);
      case SEL.DECIMALS:
        // A collection has no decimals, and reverting is the answer that says so.
        if (!m || m.erc721) throw Error('no decimals');
        return '0x' + u256(m.decimals);
      case SEL.DS:
        if (!m?.domainSeparator) throw Error('no DOMAIN_SEPARATOR');
        return m.domainSeparator;
      // Most EIP-2612 tokens publish this; DAI-style ones publish a DIFFERENT
      // one for a permit the router cannot call. A fixture that sets neither
      // reverts, which is also what plenty of real 2612 tokens do.
      case SEL.PERMIT_TH:
        if (!m?.permitTypehash) throw Error('no PERMIT_TYPEHASH');
        return m.permitTypehash;
      case SEL.NONCES: return '0x' + u256(m?.nonce ?? 0);
      case SEL.APPROVE: case SEL.TRANSFER: return '0x' + u256(1);
      // WETH deposit/withdraw return nothing; the page pre-flights the unwrap
      // with eth_call, so this has to succeed rather than look like a revert.
      case SEL.WETH_WITHDRAW: case SEL.WETH_DEPOSIT: return '0x';
      default:
        // 0x081812fc = getApproved(uint256)
        if (sel === '081812fc') return '0x' + u256(0);
        // ownerOf(uint256), for a collection the fixture set up with setNftOwner.
        if (sel === '6352211e' && m?.erc721) {
          const owner = this.nftOwner.get(`${to}:${word('0x' + data.slice(8), 0)}`);
          if (!owner) throw Error('nonexistent token');
          return '0x' + addrWord(owner);
        }
        // safeTransferFrom(address,address,uint256,bytes) - how an NFT is
        // listed: the token IS the order, so there is nothing to return.
        if (sel === 'b88d4fde') return '0x';
        // supportsInterface(bytes4). An ERC-20 has no such function at all, so
        // the miss below - a revert - is the correct answer for one.
        if (sel === '01ffc9a7') {
          const id = data.slice(8, 16);
          if (m?.erc721 && id === '80ac58cd') return '0x' + u256(1);
          if (m?.erc1155 && id === 'd9b67a26') return '0x' + u256(1);
          if (m?.erc721 || m?.erc1155) return '0x' + u256(0);
        }
        /* PrecisionLauncher.launch / launchWithArt, simulated. The page runs an
           `eth_call` before signing so a launch the chain would refuse costs
           nothing; without an answer here that preflight throws and no launch
           is ever sent. Returns the (token, pool) pair the real one does.
           `launchReverts` lets a test drive the refusal path. */
        /* ERC-7572 `contractURI()`. Almost no ERC-20 has one, and the page
           treats absence as "no art" - so answering with a revert here is the
           realistic case, not a gap. A fixture wanting art sets `contractURIs`. */
        if (sel === '56ea33ee' || sel === '3ad57b72') {
          const e = Object.values(this.launchFees || {})
            .find(x => (x.pool || FEE_POOL).toLowerCase() === to.toLowerCase());
          if (!e) return '0x' + u256(0);
          return '0x' + u256(sel === '56ea33ee' ? (e.owed0 ?? 0n) : (e.owed1 ?? 0n));
        }
        if (sel === 'e8a3d485') {
          const u = this.contractURIs?.[to.toLowerCase()];
          if (!u) throw Error('no contractURI');
          const b = Buffer.from(u, 'utf8');
          return '0x' + u256(32) + u256(b.length) + b.toString('hex').padEnd(Math.ceil(b.length / 32) * 64, '0');
        }
        /* PrecisionLauncher.poolOf and the pool's `creatorOwed0` - what the
           page reads to decide whether a coin has uncollected fees. Absent a
           fixture every token answers zero, which is the honest default: most
           tokens were not launched here. `setLaunchFees` opts a test in. */
        if (sel === '988b1fa7') {
          const t = '0x' + data.slice(8 + 24, 8 + 64).toLowerCase();
          const f = this.launchFees?.[t];
          return '0x' + addrWord(f ? (f.pool || FEE_POOL) : A.ZERO);
        }
        if (sel === 'a480ca79' || sel === 'c296057e') {
          if (this.collectReverts) throw Error('execution reverted');
          return '0x' + u256(0).repeat(6);
        }
        if (sel === '6a648dc6' || sel === '72cf7bd8') {
          if (this.launchReverts) throw Error('execution reverted');
          return '0x' + addrWord(this.launchToken || '0x' + '11'.repeat(20))
            + addrWord(this.launchPool || '0x' + '22'.repeat(20));
        }
        /* PrecisionLauncher.creatorOf - the one call the page spends when a
           receipt arrives without logs, to decide whether the address its
           preflight predicted is really the coin it just launched. Zero for
           anything this launcher did not launch, which is the real contract's
           behaviour and the whole basis of the fallback being sound.
           `creatorOfAnswer` lets a test drive the nonce race, where the
           predicted address is a REAL token belonging to somebody else. */
        /* PrecisionLauncher.quoteRedeem - the ether backing an amount of a
           launched coin. Zero unless a fixture opts in, which matches the real
           contract: it returns zero for anything it did not launch. */
        if (sel === '385e4465') {
          return '0x' + u256(this.redeemQuote ?? 0n);
        }
        /* PrecisionLauncher.floorPrice - `quoteRedeem` of ONE whole token. The
           page reads this once per token and scales, since redemption is linear
           in the amount, so a fixture's `redeemQuote` has to be expressed per
           token here or the two disagree. */
        if (sel === '2aad9987') {
          const per = this.floorPrice ?? this.redeemQuote ?? 0n;
          return '0x' + u256(per);
        }
        if (sel === 'dea5c2e0') {
          if (this.creatorOfAnswer !== undefined) return '0x' + addrWord(this.creatorOfAnswer);
          /* A token this fixture launched via `setLaunchFees` answers with its
             creator - that is what the page filters on to decide whose fees
             these are. */
          const t = '0x' + data.slice(8 + 24, 8 + 64).toLowerCase();
          if (this.launchFees?.[t]) {
            return '0x' + addrWord(this.launchFees[t].creator || A.ACCOUNT);
          }
          const asked = '0x' + data.slice(8 + 24, 8 + 64);
          const mine = (this.launchToken || '0x' + '11'.repeat(20)).toLowerCase();
          return '0x' + addrWord(asked === mine ? (this.launchCreator || A.ACCOUNT) : ZERO_ADDR);
        }
        throw Error(`MockChain: unhandled call ${sel} to ${to}`);
    }
  }
}

// ------------------------------------------------------------------ loader
/**
 * Boot zSwap.html in jsdom against a mock chain.
 *
 * jsdom parses and runs the page's scripts synchronously during construction,
 * so the provider and every browser API the page touches has to be installed in
 * beforeParse — after construction is already too late.
 */
// The page installs 5s and 30s intervals. A test that fails before close()
// would otherwise leave those timers holding the process open forever, turning
// one assertion failure into a hung run with no output at all.
const openPages = new Set();
export function closeAllPages() {
  for (const dom of openPages) { try { dom.window.close(); } catch {} }
  openPages.clear();
}

/**
 * The pair tests exercise unless they say otherwise.
 *
 * The landing pair is on-chain data now - the page adopts the top of the
 * registry's conviction ranking - so a test that leans on it is really
 * asserting today's ranking, and a re-rank would rewrite dozens of unrelated
 * expectations. Pinning it through the page's OWN deep link does that before
 * the registry loads, so the page settles on one pair for its whole life
 * rather than transitioning and re-reading the chart for a pair no one asked
 * to see. Tests that pass a hash override this; ranked-default tests pass
 * `hash: null` to watch the page choose for itself.
 */
const PINNED_PAIR = 'token=ETH&out=USDC';

export async function loadPage(opts = {}) {
  let { chain = new MockChain(), hash = '', storage = {}, session = {}, patch = [], prefersDark = false } = opts;
  if (hash === '') hash = PINNED_PAIR;
  else if (hash === null) hash = '';
  // Tests that exercise the price tape or the liquidity panel repoint PPLENS
  // at a mock address through `patch`, matched by shape rather than by literal
  // so a redeploy of the real lens does not silently unpatch them.
  let html = fs.readFileSync(HTML_PATH, 'utf8');
  for (const [from, to] of patch) {
    if (!html.includes(from)) throw Error(`patch target not found: ${from}`);
    html = html.split(from).join(to);
  }
  const virtualConsole = new VirtualConsole();
  const consoleErrors = [];
  // location.reload() is a no-op in jsdom that reports itself as unimplemented
  // navigation. The page reloads on chainChanged/accountsChanged/disconnect, so
  // that report is a signal to assert on, not an error to fail on.
  const navigations = [];
  virtualConsole.on('jsdomError', e => {
    if (/Not implemented: navigation/i.test(e.message || '')) navigations.push(e.message);
    else consoleErrors.push(e);
  });

  const prompts = [];   // queued prompt() answers
  const confirms = [];  // queued confirm() answers
  const asked = { prompt: [], confirm: [] };

  const dom = new JSDOM(html, {
    // `url` is overridable because the page reads its own contract address off a
    // web3:// gateway hostname - `<address>.<chain>.w3link.io` - and that is the
    // only way to exercise it, a root build having no way to carry its own address.
    url: (opts.url || 'https://zswap.test/') + (hash ? '#' + hash.replace(/^#/, '') : ''),
    runScripts: 'dangerously',
    pretendToBeVisual: true,
    virtualConsole,
    beforeParse(window) {
      for (const [k, v] of Object.entries(storage)) window.localStorage.setItem(k, v);
      // `dc` lives in sessionStorage: a deliberate disconnect lasts the tab, not forever.
      for (const [k, v] of Object.entries(session)) window.sessionStorage.setItem(k, v);

      // The walletless read layer speaks raw JSON-RPC over HTTP, and jsdom has
      // no fetch — so the same MockChain serves it here. A POST body is
      // answered exactly as the provider would answer it, which is what makes
      // walletless tests exercise the real read path: nodeRead, its failover
      // and the curated-list adoption all run for real against this stub.
      // chain.httpLog records the endpoint each call used; chain.fetchMode
      // ('ok' | 'http429' | 'down') fails every call at the named layer;
      // chain.failNext fails exactly that many calls before the pool recovers.
      window.fetch = async (url, init) => {
        // Not every fetch is JSON-RPC. The solver lanes are plain GETs to an
        // aggregator, so they arrive with no body at all; `chain.lanes` maps a
        // URL substring to a canned response (or a status number to refuse
        // with), and anything unmapped 404s the way an unreachable lane would.
        const laneHit = Object.entries(chain.lanes || {}).find(([frag]) => String(url).includes(frag));
        if (laneHit || !init || !init.body) {
          (chain.httpLog ||= []).push({ url: String(url), method: init && init.method ? init.method : 'GET' });
          if (!laneHit) return { ok: false, status: 404, json: async () => ({}) };
          const res = laneHit[1];
          if (typeof res === 'number') return { ok: false, status: res, json: async () => ({}) };
          return { ok: true, status: 200, json: async () => res };
        }
        const body = JSON.parse(init.body);
        (chain.httpLog ||= []).push({ url: String(url), method: body.method });
        const mode = chain.fetchMode || 'ok';
        const fail = mode !== 'ok' || (chain.failNext > 0 && (chain.failNext--, true));
        if (fail) {
          if (mode === 'http429') return { ok: false, status: 429, json: async () => ({}) };
          throw new Error('connection refused');
        }
        let result, error = null;
        const remote = Object.entries(chain.remotes || {}).find(([frag]) => String(url).includes(frag));
        const target = remote ? remote[1] : chain;
        try { result = await target.request({ method: body.method, params: body.params || [] }); }
        catch (e) { error = { code: e && e.code !== undefined ? e.code : -32000, message: e.message || 'failed' }; }
        return {
          ok: true, status: 200,
          json: async () => error
            ? { jsonrpc: '2.0', id: body.id, error }
            : { jsonrpc: '2.0', id: body.id, result: result === undefined ? null : result },
        };
      };

      if (!opts.walletless) {
        window.ethereum = {
          isMock: true,
          request: args => chain.request(args),
          on: (ev, cb) => { (window.__ethListeners ||= {})[ev] = cb; },
        };
      }

      /* EIP-6963 wallets, which announce themselves on request rather than
         sitting on `window.ethereum`. A browser with two wallets installed has
         exactly one of them on `window.ethereum` and the rest reachable only
         this way, which is why "reconnect on refresh" cannot just rebind the
         injected one. `wallets` is [{rdns, name, chain}]. */
      if (opts.wallets) {
        window.addEventListener('eip6963:requestProvider', () => {
          for (const w of opts.wallets) {
            const provider = {
              isMock: true, rdns: w.rdns,
              request: args => (w.chain || chain).request(args),
              on: () => {},
            };
            window.dispatchEvent(new window.CustomEvent('eip6963:announceProvider', {
              detail: { info: { uuid: w.rdns, name: w.name || w.rdns, rdns: w.rdns, icon: '' }, provider },
            }));
          }
        });
      }

      // The interaction chime speaks WebAudio, which jsdom has none of. This
      // stub counts what the page asked the audio system to do — one context
      // per session, two oscillators per chime, one resume if a chime landed
      // before a gesture — so tests can pin the sound without hearing it.
      // Installed only when opts.chime: every other page runs with no
      // AudioContext at all, which is the silent path the try/catch exists for.
      if (opts.chime) {
        window.__chime = { ctx: 0, osc: 0, resumes: 0, notes: [], voices: [] };
        window.AudioContext = class {
          constructor() {
            this.currentTime = 0;
            this.state = 'running';
            this.destination = {};
            window.__chime.ctx++;
          }
          resume() { window.__chime.resumes++; this.state = 'running'; return Promise.resolve(); }
          createOscillator() {
            // Notes are grouped into VOICES so a test can say "one item-get,
            // four notes" instead of counting oscillators and hoping. The
            // boundary is the schedule, not the call stack: within one voice
            // every note is scheduled strictly later than the one before, so a
            // start time that fails to advance is the next voice beginning.
            // Grouping by microtask instead would merge two clicks that land
            // in the same tick - which is exactly what back-to-back UI clicks
            // do.
            const ctx = this;
            return {
              type: '', frequency: { value: 0 },
              connect() {},
              start(when) {
                if (ctx._at === undefined || !(when > ctx._at)) window.__chime.voices.push([]);
                ctx._at = when;
                const voice = window.__chime.voices[window.__chime.voices.length - 1];
                window.__chime.osc++;
                window.__chime.notes.push(this.frequency.value);
                voice.push(this.frequency.value);
              },
              stop() {},
            };
          }
          createGain() {
            return {
              gain: { setValueAtTime() {}, linearRampToValueAtTime() {}, exponentialRampToValueAtTime() {} },
              connect() {},
            };
          }
        };
      }

      // jsdom implements these as "not implemented" throwers.
      // The default value a prompt is opened with is recorded too: the private
      // bridge hands a payment request to the user that way, and a test has to
      // read it back to pay it.
      window.prompt = (q, d) => { asked.prompt.push(q); (window.__promptDefaults ||= []).push(d); return prompts.length ? prompts.shift() : null; };
      window.confirm = q => { asked.confirm.push(q); return confirms.length ? confirms.shift() : false; };
      window.alert = () => {};

      const copied = [];
      Object.defineProperty(window.navigator, 'clipboard', {
        configurable: true,
        value: { writeText: async t => { copied.push(t); } },
      });
      window.__copied = copied;

      // Present in every browser; jsdom does not expose them on the window.
      if (!window.TextEncoder) window.TextEncoder = TextEncoder;
      if (!window.TextDecoder) window.TextDecoder = TextDecoder;

      // Without this the page's very first statement throws, the theme block is
      // skipped, and every "defaults to light" assertion passes for the wrong
      // reason. Real browsers always have it.
      if (!window.matchMedia) {
        window.matchMedia = q => ({
          media: q,
          matches: prefersDark && /prefers-color-scheme:\s*dark/.test(q),
          addEventListener() {}, removeEventListener() {},
          addListener() {}, removeListener() {},
        });
      }

      /* jsdom supplies a REAL getRandomValues, so this stub normally never
         installs and anything salted is different on every run — which is
         correct for the page and fatal for a fixture that has to be compared
         byte for byte. `fixedRandom` forces the deterministic one in, so a
         caller that needs reproducible calldata can have it. */
      if (opts.fixedRandom || !window.crypto?.getRandomValues) {
        const fixed = a => { for (let i = 0; i < a.length; i++) a[i] = (i * 7 + 13) & 0xff; return a; };
        /* `window.crypto` is a read-only accessor in jsdom, so a plain
           assignment silently does nothing and the page keeps the real one —
           which is how this stub appeared to work while changing nothing. */
        if (window.crypto) Object.defineProperty(window.crypto, 'getRandomValues', {
          value: fixed, configurable: true, writable: true,
        });
        else Object.defineProperty(window, 'crypto', {
          value: { getRandomValues: fixed }, configurable: true, writable: true,
        });
      }
    },
  });

  const { window } = dom;
  const page = {
    dom, window, chain, consoleErrors,
    doc: window.document,
    $: id => window.document.getElementById(id),
    queuePrompt: (...vals) => prompts.push(...vals),
    queueConfirm: (...vals) => confirms.push(...vals),
    asked,
    copied: () => window.__copied,
    reloads: () => navigations.length,
    emit: (ev, ...args) => window.__ethListeners?.[ev]?.(...args),
    close: () => { openPages.delete(dom); dom.window.close(); },
  };
  openPages.add(dom);

  // ---- driving helpers ---------------------------------------------------
  page.text = id => (page.$(id)?.textContent ?? '').trim();
  page.value = id => page.$(id)?.value;
  page.visible = id => !page.$(id)?.classList.contains('hide');
  page.disabled = id => !!page.$(id)?.disabled;

  page.type = (id, v) => {
    const el = page.$(id);
    el.value = v;
    el.dispatchEvent(new window.Event('input', { bubbles: true }));
  };
  page.select = (id, v) => {
    const el = page.$(id);
    el.value = String(v);
    el.dispatchEvent(new window.Event('change', { bubbles: true }));
  };
  page.click = idOrEl => {
    const el = typeof idOrEl === 'string' ? page.$(idOrEl) : idOrEl;
    el.dispatchEvent(new window.MouseEvent('click', { bubbles: true, cancelable: true }));
  };
  /**
   * Pick a token by symbol in either select, the way a user would — including
   * refusing a disabled option. Setting .value directly would happily select
   * the token already chosen on the other side, producing a pair state no user
   * can reach and assertions that prove nothing.
   */
  page.pickToken = (which, sym) => {
    const el = page.$(which);
    const opt = [...el.options].find(o => o.textContent === sym);
    if (!opt) throw Error(`no ${sym} option in ${which} (have: ${[...el.options].map(o => o.textContent)})`);
    if (opt.disabled) throw Error(`${sym} is disabled in ${which} — it is selected on the other side`);
    page.select(which, opt.value);
  };

  const tick = () => new Promise(r => window.setTimeout(r, 0));
  /** Wait until `fn()` is truthy. Polls; never sleeps a fixed duration. */
  page.waitFor = async (fn, { timeout = 4000, label = 'condition' } = {}) => {
    const end = Date.now() + timeout;
    let lastErr;
    while (Date.now() < end) {
      try { const v = fn(); if (v) return v; lastErr = null; } catch (e) { lastErr = e; }
      await new Promise(r => window.setTimeout(r, 5));
    }
    throw Error(`waitFor timed out (${timeout}ms): ${label}${lastErr ? ` — last error: ${lastErr.message}` : ''}`);
  };
  /** Wait for the page to go quiet: no in-flight RPC and no pending microtasks. */
  page.settle = async () => {
    for (let i = 0; i < 400; i++) {
      await tick();
      if (chain.inFlight === 0) { await tick(); if (chain.inFlight === 0) return; }
    }
    throw Error(`settle timed out with ${chain.inFlight} request(s) in flight`);
  };
  /**
   * Type an amount and wait for the resulting quote to land.
   *
   * The page debounces input by 250ms, so a wait keyed only on DOM state
   * returns before the quote has even started. Clear the debounce first, then
   * drain the RPCs, then require the opposite field to have left its "..."
   * placeholder — that is the only state that means the quote actually
   * resolved rather than never having run.
   */
  page.typeAmount = async (id, v) => {
    const other = page.$(id === 'amt' ? 'outAmt' : 'amt');
    page.type(id, v);
    await new Promise(r => window.setTimeout(r, 320));
    await page.settle();
    await page.waitFor(() => other.value !== '...', { label: 'quote to resolve' });
    await page.settle();
  };
  /**
   * Connect, then pin the pair to ETH -> USDC.
   *
   * The landing pair is no longer a constant: the page adopts the top of the
   * registry's conviction ranking once it loads, so curation moves the default
   * without a redeploy. A test that leans on whatever that happens to be today
   * is really asserting the current ranking, and every re-rank would rewrite
   * dozens of unrelated expectations. So tests state the pair they exercise.
   *
   * Pass `{ pin: false }` to observe the default the page actually chose -
   * that is what the ranked-default tests do.
   */
  page.connect = async ({ pin = true } = {}) => {
    page.click('swap');
    await page.waitFor(() => page.text('addr') !== 'Not connected', { label: 'connect' });
    await page.settle();
    if (!pin) return;
    // Selecting through the real control, so the page marks the pair chosen
    // exactly as it would for a user - no back door into its state.
    const has = (which, sym) => [...page.$(which).options].some(o => o.textContent === sym);
    if (has('fromSel', 'ETH') && has('toSel', 'USDC')) {
      page.pickToken('fromSel', 'ETH');
      page.pickToken('toSel', 'USDC');
      await page.settle();
    }
  };

  await page.settle();
  return page;
}

/**
 * The fixtures above hardcode addresses the page also hardcodes. If a contract
 * is ever redeployed, this fails loudly instead of letting every routing test
 * quietly assert against an address the page no longer uses.
 */
export function assertAddressesMatchPage(assert) {
  const html = fs.readFileSync(HTML_PATH, 'utf8');
  const pinned = {
    ZQUOTER: 'ZQUOTER', ZROUTER: 'ZROUTER', PERMIT2: 'PERMIT2', SLOW: 'SLOW',
    SLOW_GATE: 'SLOW_GATE',
    SB2: 'SB2', SB1: 'SB1', SBVIEW: 'SBVIEW', SWAPBOL: 'SWAPBOL', DUTCH: 'DUTCH',
    ORDERBOL: 'ORDERBOL', WETH: 'WETH', FLOOR: 'FLOOR', FLOORVIEW: 'FLOORVIEW',
    // Not patched by any suite, so the fixtures answer at the real addresses
    // and a redeploy has to update both.
    PFACTORY: 'PFACTORY', PLQLENS: 'PLQLENS', PROUTE: 'PROUTE',
    TOKENLIST: 'TOKENLIST', ZLISTLENS: 'ZLISTLENS',
  };
  // The book, the route and the launcher are per-chain: the page keeps their
  // mainnet addresses in the `MB` table and rebinds the names in setChain.
  const MB = { SB2: 'sb', SB1: 's1', SWAPBOL: 'sw', DUTCH: 'du', ORDERBOL: 'ob', FLOOR: 'fl', PROUTE: 'pr' };
  for (const [key, name] of Object.entries(pinned)) {
    const m = MB[name]
      ? html.match(new RegExp(`const MB=\\{[^;]*\\b${MB[name]}:"(0x[0-9a-fA-F]{40})"`))
      : html.match(new RegExp(`(?:const|let) ${name}="(0x[0-9a-fA-F]{40})"`));
    assert.ok(m, `page still declares ${name}`);
    assert.equal(m[1].toLowerCase(), A[key].toLowerCase(), `${name} fixture matches the page`);
  }
  const mc3 = html.match(/const MC3="(0x[0-9a-fA-F]{40})"/);
  assert.equal(mc3[1].toLowerCase(), A.MC3.toLowerCase(), 'MC3 fixture matches the page');
}

/**
 * Decode the common prefix of a zQuoter request into the fields that decide a
 * quote. Both builders end with the same tail; only the recipient/refund head
 * differs, so `base` is where the shared part starts.
 */
export function decodeQuoteRequest(selector, data) {
  const body = '0x' + strip(data).slice(8);
  const base = selector === SEL.QUOTE ? 2 : 1;
  return {
    u: selector === SEL.QUOTE ? 4 : 8,
    recipient: wordAddr(body, 0),
    exactOut: word(body, base) === 1n,
    tokenIn: wordAddr(body, base + 1),
    tokenOut: wordAddr(body, base + 2),
    amount: word(body, base + 3),
    slipBps: word(body, base + 4),
    deadline: word(body, base + 5),
  };
}

/**
 * A constant-product pool quoter. Unlike a fixed rate this produces REAL price
 * impact, so the page's impact tiers (display / warn / confirm / type-to-accept)
 * are driven by the same arithmetic a live pool would produce rather than by a
 * number the test asserts into existence.
 */
export function cpammQuoter({ reserveIn, reserveOut, source = 0, feeBps = 30n } = {}) {
  return ({ selector, data }) => {
    if (selector !== SEL.QUOTE && selector !== SEL.QUOTE_MULTI) return null;
    const q = decodeQuoteRequest(selector, data);
    if (q.amount === 0n) return null;
    let amountIn, amountOut;
    if (q.exactOut) {
      amountOut = q.amount;
      if (amountOut >= reserveOut) return null;
      amountIn = (reserveIn * amountOut) / (reserveOut - amountOut) + 1n;
    } else {
      amountIn = q.amount;
      amountOut = (reserveOut * amountIn) / (reserveIn + amountIn);
    }
    if (amountIn <= 0n || amountOut <= 0n) return null;
    return encodeQuote({
      u: q.u,
      legs: [{ source, feeBps, amountIn, amountOut }],
      callData: '0x' + SEL.MULTICALL + u256(32) + u256(0),
      msgValue: q.tokenIn.toLowerCase() === A.ZERO ? amountIn : 0n,
    });
  };
}

/** The EIP-2612 domain separator the page computes, so permit paths can match. */
export function domainSeparator(name, version, token, chainId = 1n) {
  const typeHash = keccak256(toUtf8Bytes(
    'EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)'));
  return keccak256('0x' + strip(typeHash) +
    strip(keccak256(toUtf8Bytes(name))) + strip(keccak256(toUtf8Bytes(version))) +
    u256(chainId) + addrWord(token));
}

/** A quote handler that prices every pair at a fixed rate, AMM-only. */
export function fixedRateQuoter({ rate, decIn = 18, decOut = 6, source = 3, feeBps = 30n } = {}) {
  return ({ selector, data }) => {
    // Only the single and multihop builders answer; split builders "revert",
    // which is the common mainnet case and keeps the expected route unambiguous.
    if (selector !== SEL.QUOTE && selector !== SEL.QUOTE_MULTI) return null;
    const u = selector === SEL.QUOTE ? 4 : 8;
    // Layout: [recipient][refundTo?][exactOut][tokenIn][tokenOut][amount][slipBps][deadline]
    const body = '0x' + strip(data).slice(8);
    const base = selector === SEL.QUOTE ? 2 : 1; // QUOTE has recipient+refundTo
    const exactOut = word(body, base) === 1n;
    const tokenIn = wordAddr(body, base + 1);
    const amount = word(body, base + 3);
    if (amount === 0n) return null;

    const scale = (a, from, to) => (a * 10n ** BigInt(to)) / 10n ** BigInt(from);
    let amountIn, amountOut;
    if (exactOut) {
      amountOut = amount;
      amountIn = scale(amountOut, decOut, decIn) * 10n ** 18n / rate;
    } else {
      amountIn = amount;
      amountOut = scale(amountIn * rate / 10n ** 18n, decIn, decOut);
    }
    if (amountOut === 0n || amountIn === 0n) return null;
    const isNative = tokenIn.toLowerCase() === A.ZERO;
    return encodeQuote({
      u,
      legs: [{ source, feeBps, amountIn, amountOut }],
      callData: '0x' + SEL.MULTICALL + u256(32) + u256(0),
      msgValue: isNative ? amountIn : 0n,
    });
  };
}
