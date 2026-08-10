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
export const HTML_PATH = path.join(ROOT, 'zSwap.html');

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
  ZQUOTER: '0x0000002d9a651b729e3aFBE57Fc84FFDa4a98a13',
  ZROUTER: '0x000000000000FB114709235f1ccBFfb925F600e4',
  PERMIT2: '0x000000000022D473030F116dDEE9F6B43aC78BA3',
  MC3: '0xcA11bde05977b3631167028862bE2a173976CA11',
  SLOW: '0x000000000000888741B254d37e1b27128AfEAaBC',
  SB2: '0x000000dA7bb4B2A9E3e80e9A4D4157E26CA6189b',
  SB1: '0x000000fF3D7A2d373615141d7489Ca66683DbecF',
  SBVIEW: '0x000000E0b25449F32f7D9259aC449bA88E78dFCE',
  SWAPBOL: '0x0000003069053df109F47acac630e03C77804AD8',
  DUTCH: '0x000000a213b430D14Bae6062c176289B05e04489',
  ORDERBOL: '0x000000fADa565c5608570a4F66Fb5E0bD08ef91B',
  PPFACTORY: '0x0000000000000000000000000000000000000000',
  POOL: '0x5555555555555555555555555555555555555555',
  ENSREG: '0x00000000000C2E074eC69A0dFb2997BA6C7d2e1e',
  WNS: '0x0000000000696760E15f265e828DB644A0c242EB',
  GNS: '0x9D51D507BC7264d4fE8Ad1cf7Fe191933A0a81d6',
  ACCOUNT: '0x1111111111111111111111111111111111111111',
  OTHER: '0x2222222222222222222222222222222222222222',
};

export const SEL = {
  BALANCEOF: '70a08231', ALLOWANCE: 'dd62ed3e', APPROVE: '095ea7b3', TRANSFER: 'a9059cbb',
  SYMBOL: '95d89b41', DECIMALS: '313ce567', NAME: '06fdde03',
  DS: '3644e515', NONCES: '7ecebe00',
  MULTICALL: 'ac9650d8', SNWAP: '5f3bd1c8', SWEEP: 'cb019b84', CHECKPOINT: 'a972985e',
  FILLPLAN: 'c277f67c', FILLPLAN_SWAP: '9090c8e5',
  RPERMIT: '7ac2ff7b', P2TF: '09d31579',
  AGG3: '82ad56cb',
  QUOTE: 'e453166e', QUOTE_MULTI: '4c464f59', SPLIT_A: '892af013', SPLIT_B: '85f86a90',
  ORDER_FIXED: 'bcdb7936', ORDER_DUTCH: 'fb910431',
  CANDS: '5f452988', DUTCH_CANDS: 'eb33e466', RECENT: '6a9849c1', RECENT_DUTCH: '98035c9a',
  NEXTID: '2a58b330', CANCELORD: '514fcac7', CANCEL_UNWRAP: '21dd76f9',
  DUTCH_CANCEL: '40e58ee5', DUTCH_CANCEL_UNWRAP: '8382de65',
  FILL1: 'c37dfc5b', FILL2: '8ab3bfc9', FILL2_UNWRAP: '402ad677', FILL2_ETH: '13092239',
  DUTCH_FILL: 'ae7a8260', DUTCH_LISTING: 'de74e57b',
  POOLS_PAIR: '84cc5873', TAPE: '29a65241', MARKETS: '29c21083',
  NS_CID: 'fb021939', NS_RES: '4f896d4f', NS_REV: '9af8b7aa',
  ENS_RSLV: '0178b8bf', ENS_EADDR: '3b3b57de', ENS_ENAME: '691f3431',
  DEPOSITTO: '94eeaec9', CLAIM: '379607f5', REVERSE: '97d15425', WITHDRAWFROM: 'd4fdc309',
  OUT: 'd40d4bc6', IN: 'e3993ee7', PENDING: '6577b86a',
  WETH_DEPOSIT: 'd0e30db0', WETH_WITHDRAW: '2e1a7d4d',
};

// -------------------------------------------------------------- abi helpers
const strip = h => (h || '').replace(/^0x/, '');
export const word = (hex, i) => BigInt('0x' + strip(hex).slice(i * 64, (i + 1) * 64));
export const wordAddr = (hex, i) => '0x' + strip(hex).slice(i * 64 + 24, (i + 1) * 64);
const u256 = v => BigInt(v).toString(16).padStart(64, '0');
const addrWord = a => strip(a).toLowerCase().padStart(64, '0');
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

/** PrecisionPoolLens.PoolInfo[] — 18 static fields, so 18 flat words per row. */
const POOL_INFO = 'tuple(address,address,address,uint256,uint256,uint256,uint256,uint256,' +
  'uint256,uint256,address,address,uint256,uint256,uint256,uint256,uint256,uint256)[]';

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
export class MockChain {
  constructor(opts = {}) {
    this.chainId = opts.chainId ?? '0x1';
    this.accounts = opts.accounts ?? [A.ACCOUNT];
    this.autoConnected = opts.autoConnected ?? false;
    this.blockNumber = opts.blockNumber ?? '0x1200000';
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
    this.tapes = new Map();        // `${pool}:${period}` -> [bar | null], newest first
    // Name services. `names` resolves forward (name -> address) for .wei/.gwei
    // via the WNS/GNS registries; `reverse` drives the header's display name.
    this.names = new Map();
    this.reverse = new Map();
    this.ensResolver = A.ZERO;   // non-zero enables the .eth path
    this.slowOut = [];
    this.slowIn = [];
    this.slowPending = new Map();
    this.quoteHandler = null;      // ({selector, params}) => hex | null
    this.capabilities = null;      // wallet_getCapabilities response
    this.sent = [];                // eth_sendTransaction payloads
    this.calls = [];               // every eth_call {to, data, block}
    this.log = [];                 // every request {method, params}
    this.signed = [];              // eth_signTypedData_v4 payloads
    this.batches = [];             // wallet_sendCalls payloads
    this.reverts = new Map();      // `${to}:${selector}` -> message, for eth_call
    this.rejectNext = null;        // make the next signature/tx a user rejection
    this.inFlight = 0;
    this.nonce = 0;

    // Every zSwap-relevant contract is deployed by default; tests that care
    // about "not deployed yet" branches clear these explicitly.
    for (const a of [A.SB2, A.SB1, A.SBVIEW, A.SWAPBOL, A.DUTCH, A.ORDERBOL,
      A.ZROUTER, A.ZQUOTER, A.SLOW, A.MC3, A.PERMIT2, A.WETH, A.USDC, A.USDT, A.WBTC]) {
      this.code.set(a.toLowerCase(), '0x60006000');
    }
    this.setToken(A.USDC, { symbol: 'USDC', decimals: 6, name: 'USD Coin' });
    this.setToken(A.USDT, { symbol: 'USDT', decimals: 6, name: 'Tether USD' });
    this.setToken(A.WETH, { symbol: 'WETH', decimals: 18, name: 'Wrapped Ether' });
    this.setToken(A.WBTC, { symbol: 'WBTC', decimals: 8, name: 'Wrapped BTC' });
  }

  // -- state setters -------------------------------------------------------
  setNative(who, wei) { this.native.set(who.toLowerCase(), BigInt(wei)); return this; }
  setErc20(token, holder, units) {
    this.erc20.set(`${token.toLowerCase()}:${holder.toLowerCase()}`, BigInt(units)); return this;
  }
  setAllowance(token, owner, spender, units) {
    this.allow.set(`${token.toLowerCase()}:${owner.toLowerCase()}:${spender.toLowerCase()}`, BigInt(units));
    return this;
  }
  setToken(token, m) { this.meta.set(token.toLowerCase(), m); return this; }
  /**
   * Register pools for a pair. Entries may be a bare address or
   * {pool, hook, liquidity} — the lens reports hook and liquidity, and the
   * chart uses both to decide which pools may speak for the pair's price.
   */
  setPools(a, b, pools) {
    const [t0, t1] = a.toLowerCase() < b.toLowerCase() ? [a, b] : [b, a];
    const rows = pools.map(p => (typeof p === 'string' ? { pool: p } : p))
      .map(r => ({ hook: A.ZERO, liquidity: 10n ** 21n, ...r }));
    this.pools.set(`${t0.toLowerCase()}:${t1.toLowerCase()}`, rows);
    for (const r of rows) this.code.set(r.pool.toLowerCase(), '0x60006000');
    return this;
  }
  /** Bars for one pool at one bar width. The page reads a fine and a coarse tape. */
  setTape(pool, bars, period = 300) {
    this.tapes.set(`${pool.toLowerCase()}:${period}`, bars);
    return this;
  }
  setCode(addr, code) { this.code.set(addr.toLowerCase(), code); return this; }
  undeploy(addr) { this.code.set(addr.toLowerCase(), '0x'); return this; }
  revertOn(to, selector, msg = 'execution reverted') {
    this.reverts.set(`${to.toLowerCase()}:${selector}`, msg); return this;
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
      case 'eth_call': return this.ethCall(params[0], params[1]);
      case 'eth_sendTransaction': {
        if (this.rejectNext) { const e = this.rejectNext; this.rejectNext = null; throw e; }
        this.sent.push({ ...params[0] });
        this.applyTx(params[0]);
        return '0x' + (++this.nonce).toString(16).padStart(64, '0');
      }
      case 'eth_getTransactionReceipt':
        return { status: '0x1', transactionHash: params[0], blockNumber: this.blockNumber };
      case 'eth_signTypedData_v4': {
        if (this.rejectNext) { const e = this.rejectNext; this.rejectNext = null; throw e; }
        this.signed.push({ owner: params[0], typedData: JSON.parse(params[1]) });
        return '0x' + '11'.repeat(32) + '22'.repeat(32) + '1b';
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
    if (data.slice(0, 8) !== SEL.APPROVE) return;
    const body = '0x' + data.slice(8);
    this.setAllowance(tx.to, tx.from, wordAddr(body, 0), word(body, 1));
  }

  ethCall(tx, block) {
    const to = (tx.to || '').toLowerCase();
    const data = strip(tx.data || '');
    const sel = data.slice(0, 8);
    this.calls.push({ to, data: '0x' + data, block, selector: sel });

    const rv = this.reverts.get(`${to}:${sel}`);
    if (rv) throw Error(rv);

    // A plain value transfer pre-flights as a call with no calldata at all.
    if (!data) return '0x';

    if (to === A.MC3.toLowerCase() && sel === SEL.AGG3) return this.aggregate3(data, block);
    if (to === A.ZQUOTER.toLowerCase()) return this.quote(sel, data);
    if (to === A.SBVIEW.toLowerCase()) return this.lens(sel, data);
    if (to === A.DUTCH.toLowerCase() && sel === SEL.DUTCH_LISTING) return this.dutchListing(data);
    if (to === A.SLOW.toLowerCase()) return this.slow(sel, data);
    if (to === A.ZROUTER.toLowerCase()) return '0x';          // pre-flight eth_call
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
      // PoolInfo is a static struct, so the array is 18 flat words per row.
      return coder.encode([POOL_INFO], [rows.map(r => [
        r.pool, A.ZERO, A.ZERO, 0n, 0n, 0n, 0n, 0n, 0n, BigInt(r.liquidity),
        r.hook, A.ZERO, 0n, 0n, 0n, 0n, 0n, 0n,
      ])]);
    }
    if (sel === SEL.TAPE) {
      const body = '0x' + data.slice(8);
      const bars = this.tapes.get(`${to}:${Number(word(body, 0))}`) || [];
      const count = Number(word(body, 1));
      return coder.encode(['uint256[]'],
        [bars.slice(0, count).map(b => (b === null ? 0n : encodeTapeBar(b)))]);
    }
    if (to === A.WNS.toLowerCase() || to === A.GNS.toLowerCase()) return this.ns(sel, data);
    if (to === A.ENSREG.toLowerCase()) {
      if (sel === SEL.ENS_RSLV) return '0x' + addrWord(this.ensResolver);
      throw Error(`MockChain: unhandled ENS registry selector ${sel}`);
    }
    return this.erc20Call(to, sel, data, tx);
  }

  aggregate3(data, block) {
    // aggregate3((address target,bool allowFailure,bytes callData)[])
    const [calls] = coder.decode(['tuple(address,bool,bytes)[]'], '0x' + data.slice(8));
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

  board(sel, data) {
    if (sel === SEL.NEXTID) return '0x' + u256(0);
    return '0x'; // fill/cancel are pre-flighted with eth_call before signing
  }

  slow(sel, data) {
    const arr = ids => coder.encode(['uint256[]'], [ids.map(BigInt)]);
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
        if (!m) throw Error('no decimals');
        return '0x' + u256(m.decimals);
      case SEL.DS:
        if (!m?.domainSeparator) throw Error('no DOMAIN_SEPARATOR');
        return m.domainSeparator;
      case SEL.NONCES: return '0x' + u256(m?.nonce ?? 0);
      case SEL.APPROVE: case SEL.TRANSFER: return '0x' + u256(1);
      // WETH deposit/withdraw return nothing; the page pre-flights the unwrap
      // with eth_call, so this has to succeed rather than look like a revert.
      case SEL.WETH_WITHDRAW: case SEL.WETH_DEPOSIT: return '0x';
      default:
        // 0x081812fc = getApproved(uint256)
        if (sel === '081812fc') return '0x' + u256(0);
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

export async function loadPage({ chain = new MockChain(), hash = '', storage = {}, patch = [], prefersDark = false } = {}) {
  // The shipped page leaves PPFACTORY at the zero address until deployment, so
  // the chart stays off. Tests inject an address here rather than the page
  // carrying a guessed one that would be immutable once deployed.
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
    url: 'https://zswap.test/' + (hash ? '#' + hash.replace(/^#/, '') : ''),
    runScripts: 'dangerously',
    pretendToBeVisual: true,
    virtualConsole,
    beforeParse(window) {
      for (const [k, v] of Object.entries(storage)) window.localStorage.setItem(k, v);

      window.ethereum = {
        isMock: true,
        request: args => chain.request(args),
        on: (ev, cb) => { (window.__ethListeners ||= {})[ev] = cb; },
      };

      // jsdom implements these as "not implemented" throwers.
      window.prompt = q => { asked.prompt.push(q); return prompts.length ? prompts.shift() : null; };
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

      if (!window.crypto?.getRandomValues) {
        window.crypto = {
          getRandomValues: a => { for (let i = 0; i < a.length; i++) a[i] = (i * 7 + 13) & 0xff; return a; },
        };
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
  page.connect = async () => {
    page.click('swap');
    await page.waitFor(() => page.text('addr') !== 'Not connected', { label: 'connect' });
    await page.settle();
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
    SB2: 'SB2', SB1: 'SB1', SBVIEW: 'SBVIEW', SWAPBOL: 'SWAPBOL', DUTCH: 'DUTCH',
    ORDERBOL: 'ORDERBOL', WETH: 'WETH',
  };
  for (const [key, name] of Object.entries(pinned)) {
    const m = html.match(new RegExp(`const ${name}="(0x[0-9a-fA-F]{40})"`));
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
