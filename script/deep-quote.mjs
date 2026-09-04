// Quote Deepstate's orderbook without modelling it.
//
// Deepstate exposes no quote view, and its radix tree lives in raw storage. So
// rather than re-implementing the book — and re-breaking every time they change
// it — this asks the chain what a fill would actually do: `eth_call` our own
// `swapDeep` with state overrides, and read back the (amountIn, amountOut) it
// returns. The router pulls `amountInMax`, fills whatever rests, and refunds the
// rest, so a single call with an unbounded order quantity yields the true fill.
//
// Nothing here is deployed and nothing is signed.

import { readFileSync } from 'node:fs';
import { keccak256, toUtf8Bytes } from 'ethers';

const kHex = (hexNo0x) => keccak256('0x' + hexNo0x).slice(2);
const sel = (sig) => keccak256(toUtf8Bytes(sig)).slice(2, 10);

export const RPC = 'https://rpc.mainnet.chain.robinhood.com';
export const ZROUTER = '0x000000000000FB114709235f1ccBFfb925F600e4';
export const DEEPSTATE = '0x6cf19308C22FC82ea620Fa0B3E94948d20f27B96';

const SEL_SWAP_DEEP = '0xad33b1d0';
// A throwaway taker. Never holds anything for real — the overrides give it a
// balance and an allowance for the duration of one eth_call.
const TAKER = '0x00000000000000000000000000000000DeeB0000';

let id = 0;
export async function rpc(method, params, tries = 5) {
  const r = await fetch(RPC, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ jsonrpc: '2.0', id: ++id, method, params }),
  });
  const t = await r.text();
  let j;
  try {
    j = JSON.parse(t);
  } catch {
    // A Cloudflare interstitial, not JSON. Transient; retry.
    if (tries > 0) return backoff(method, params, tries);
    throw new Error(`non-JSON from RPC (${r.status}): ${t.slice(0, 120)}`);
  }
  if (j.error) {
    if (tries > 0 && /Too Many Requests|rate/i.test(j.error.message)) {
      return backoff(method, params, tries);
    }
    throw new Error(`${method}: ${j.error.message}`);
  }
  return j.result;
}

function backoff(method, params, tries) {
  return new Promise((r) => setTimeout(r, (6 - tries) * 400)).then(() => rpc(method, params, tries - 1));
}

const hex = (n, w = 64) => BigInt(n).toString(16).padStart(w, '0');
const word = (v) => hex(v, 64);
const addrWord = (a) => a.toLowerCase().replace(/^0x/, '').padStart(64, '0');
const MAX_U256 = (1n << 256n) - 1n;

// keccak(abi.encode(key, slot)) — where solidity puts mapping[key] at `slot`.
function mapSlot(keyWord, slot) {
  return '0x' + kHex(keyWord + word(slot));
}

/// Find which storage slot holds a token's balance mapping by writing a probe
/// value into each candidate and asking `balanceOf` whether it took. Solidity
/// and Vyper lay these out differently and no token declares it, so probing is
/// the only portable way.
// OpenZeppelin v5 puts ERC20 state at an ERC-7201 namespaced base rather than a
// low slot index — `_balances` at base+0, `_allowances` at base+1. Upgradeable
// tokens (every tokenized equity on 4663) use it, so probe it alongside 0..39.
const OZ_ERC20_BASE = 0x52c63247e1f47db19d5ce0460030c497f067ca4cebf71ba98eeadabe20bace00n;
const CANDIDATES = [OZ_ERC20_BASE, OZ_ERC20_BASE + 1n, ...Array(40).keys()];

const slotCache = new Map();

export async function findBalanceSlot(token, holder) {
  const ck = `b:${token}:${holder}`;
  if (slotCache.has(ck)) return slotCache.get(ck);
  const probe = 0x1234567n;
  for (const i of CANDIDATES) {
    const slot = mapSlot(addrWord(holder), i);
    const got = await rpc('eth_call', [
      { to: token, data: '0x70a08231' + addrWord(holder) },
      'latest',
      { [token]: { stateDiff: { [slot]: '0x' + word(probe) } } },
    ]);
    if (BigInt(got) === probe) {
      slotCache.set(ck, i);
      return i;
    }
  }
  throw new Error(`no balance slot found for ${token}`);
}

/// Same idea for allowance, which is a mapping of a mapping.
export async function findAllowanceSlot(token, owner, spender) {
  const ck = `a:${token}:${owner}:${spender}`;
  if (slotCache.has(ck)) return slotCache.get(ck);
  const probe = 0x7654321n;
  for (const i of CANDIDATES) {
    const inner = mapSlot(addrWord(owner), i).slice(2);
    const slot = mapSlot(addrWord(spender), '0x' + inner);
    const got = await rpc('eth_call', [
      { to: token, data: '0xdd62ed3e' + addrWord(owner) + addrWord(spender) },
      'latest',
      { [token]: { stateDiff: { [slot]: '0x' + word(probe) } } },
    ]);
    if (BigInt(got) === probe) {
      slotCache.set(ck, i);
      return i;
    }
  }
  throw new Error(`no allowance slot found for ${token}`);
}

// mapSlot takes a hex slot for the nested case; normalise both forms.
function slotOf(keyWord, slot) {
  const s = typeof slot === 'string' ? slot.replace(/^0x/, '') : word(slot);
  return '0x' + kHex(keyWord + s);
}

/// A Deepstate order is `price << 224 | quantity << 64`. For a quote we want the
/// book to be the only limit, so price is pushed to the extreme the side accepts
/// and quantity is left effectively unbounded — `amountInMax` does the bounding.
function order(isBid, quantity) {
  const price = isBid ? 0x7fffffffn : 0x80000000n; // int32 max / min
  return '0x' + hex((price << 224n) | (BigInt(quantity) << 64n), 64);
}

let routerCode;
function routerRuntime() {
  if (!routerCode) {
    const a = JSON.parse(readFileSync(new URL('../out/zRouterLiteRobinhood.sol/zRouterLiteRobinhood.json', import.meta.url)));
    routerCode = a.deployedBytecode.object;
  }
  return routerCode;
}

export async function poolEpoch(token0, token1) {
  const pid = await rpc('eth_call', [
    { to: DEEPSTATE, data: '0x' + sel('poolId(address,address)') + addrWord(token0) + addrWord(token1) },
    'latest',
  ]);
  const ep = await rpc('eth_call', [
    { to: DEEPSTATE, data: '0x' + sel('poolEpoch(bytes32)') + pid.replace(/^0x/, '') },
    'latest',
  ]);
  return BigInt(ep);
}

/**
 * What the book would really give for `amountIn` of `tokenIn`.
 * token0/token1 must be sorted, as Deepstate requires. Returns wei amounts;
 * {amountIn: 0n, amountOut: 0n} means the book had nothing to fill.
 */
/**
 * What the book would really give for `amountIn` of `tokenIn`.
 *
 * `order.quantity` is denominated in token0 and must not exceed what rests, so
 * this searches for the largest quantity that still fills: grow until it stops
 * filling, then bisect. A fill that would cost more than `amountIn` trips the
 * router's own `amountInMax` and reverts, so the search lands on the best
 * output the budget can buy — without this ever knowing the book's shape.
 *
 * token0/token1 must be sorted, as Deepstate requires. Returns wei amounts;
 * `empty` means nothing rested that the budget could reach.
 */
export async function quoteDeep({ token0, token1, isBid, amountIn, epoch, maxProbes = 24 }) {
  const tokenIn = isBid ? token1 : token0;
  if (epoch === undefined) epoch = await poolEpoch(token0, token1);

  const bSlot = await findBalanceSlot(tokenIn, TAKER);
  const aSlot = await findAllowanceSlot(tokenIn, TAKER, ZROUTER);

  const overrides = {
    // The router need not be deployed on a chain to be asked a question.
    [ZROUTER]: { code: routerRuntime() },
    [tokenIn]: {
      stateDiff: {
        [slotOf(addrWord(TAKER), bSlot)]: '0x' + word(amountIn),
        [slotOf(addrWord(ZROUTER), slotOf(addrWord(TAKER), aSlot).slice(2))]: '0x' + word(MAX_U256),
      },
    },
  };

  const attempt = async (quantity) => {
    const data =
      SEL_SWAP_DEEP +
      addrWord(TAKER) +
      addrWord(token0) +
      addrWord(token1) +
      word(epoch) +
      order(isBid, quantity).slice(2) +
      word(isBid ? 1 : 0) +
      word(amountIn) + // amountInMax — the budget, and the real bound
      word(0) + // amountOutMin: a quote asserts nothing
      word(MAX_U256); // deadline
    try {
      const ret = await rpc('eth_call', [{ from: TAKER, to: ZROUTER, data, value: '0x0' }, 'latest', overrides]);
      const b = ret.replace(/^0x/, '');
      if (b.length < 128) return null;
      const out = { amountIn: BigInt('0x' + b.slice(0, 64)), amountOut: BigInt('0x' + b.slice(64, 128)) };
      return out.amountOut === 0n ? null : out;
    } catch {
      // Past the depth the budget can reach, or past what rests. Either way,
      // too far — the bisection treats both the same.
      return null;
    }
  };

  // Grow until it stops filling, keeping the last that did.
  let lo = 0n, hi = 0n, best = null, probes = 0;
  for (let q = 1000n; probes < maxProbes; q *= 4n) {
    const r = await attempt(q);
    probes++;
    if (r) { best = r; lo = q; } else { hi = q; break; }
  }
  if (!best) return { amountIn: 0n, amountOut: 0n, empty: true };
  if (hi === 0n) return { ...best, saturated: true }; // never stopped filling

  // Bisect the gap for the largest quantity that still fills.
  while (hi - lo > 1n && probes < maxProbes) {
    const mid = lo + (hi - lo) / 2n;
    const r = await attempt(mid);
    probes++;
    if (r) { best = r; lo = mid; } else hi = mid;
  }
  return { ...best, probes };
}

// CLI: node script/deep-quote.mjs <token0> <token1> <bid|ask> <amountInWei>
if (import.meta.url === `file://${process.argv[1]}`) {
  const [t0, t1, side, amt] = process.argv.slice(2);
  if (!t0 || !t1 || !side || !amt) {
    console.error('usage: deep-quote.mjs <token0> <token1> <bid|ask> <amountInWei>');
    console.error('  token0/token1 must be sorted ascending, as Deepstate requires.');
    process.exit(1);
  }
  const q = await quoteDeep({ token0: t0, token1: t1, isBid: side === 'bid', amountIn: BigInt(amt) });
  console.log(JSON.stringify(
    { amountIn: q.amountIn.toString(), amountOut: q.amountOut.toString(), empty: !!q.empty, probes: q.probes ?? null },
    null, 2,
  ));
}
