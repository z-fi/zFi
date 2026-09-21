import { parseGwei } from "viem";

import { CHAINS, SUPPORTED_CHAIN_IDS } from "./chains.js";

function num(name, fallback, env) {
  const v = env[name];
  return v === undefined || v === "" ? fallback : Number(v);
}

/**
 * Per-chain settings are read from `NAME_<chainId>` first.
 *
 * Two fallback rules, and which one a setting uses is a property of the
 * setting, not a preference:
 *
 * `scoped` is for values that are about one specific chain -- an endpoint, a
 * deploy block, a gas price. An unsuffixed `SEND_RPC_URL` means Flashbots
 * Protect, which does not exist on an L2; an unsuffixed `MAX_FEE_GWEI` of 50
 * is four orders of magnitude off an L2 base fee. Carrying either sideways is
 * how an L2 keeper misprices or fails to send, so an unsuffixed value here
 * applies to chain 1 alone and every other chain falls through to its own
 * built-in default. That is also what makes the existing mainnet deployment
 * behave verbatim: its unsuffixed vars still land exactly where they did.
 *
 * `shared` is for values that mean the same thing everywhere -- a profit
 * ratio, a batch size, a contract address. An unsuffixed value applies to every
 * chain, and a suffixed one still overrides per chain.
 */
function scoped(name, chainId, env) {
  const s = env[`${name}_${chainId}`];
  if (s !== undefined && s !== "") return s;
  if (chainId === 1) {
    const u = env[name];
    if (u !== undefined && u !== "") return u;
  }
  return undefined;
}

function shared(name, chainId, env) {
  const s = env[`${name}_${chainId}`];
  if (s !== undefined && s !== "") return s;
  const u = env[name];
  return u !== undefined && u !== "" ? u : undefined;
}

/** First non-empty of `names` under the given resolver, split on commas. */
function list(resolve, names, chainId, env) {
  for (const n of names) {
    const v = resolve(n, chainId, env);
    if (v) return v.split(",").map((s) => s.trim()).filter(Boolean);
  }
  return [];
}

/**
 * Which chains this process watches. Default `1` alone, so a deployment that
 * never sets the var keeps doing exactly what it did before this was
 * multichain. Ids are validated here rather than at first use: a typo should
 * fail at boot with the list of what is supported, not hours later as a
 * confusing RPC error.
 */
export function resolveChainIds(env = process.env) {
  const raw = env.CHAINS;
  if (!raw || !raw.trim()) return [1];
  const ids = raw.split(",").map((s) => s.trim()).filter(Boolean).map(Number);
  const seen = new Set();
  const out = [];
  for (const id of ids) {
    if (!Number.isInteger(id) || !CHAINS[id]) {
      throw new Error(
        `CHAINS lists unsupported chain ${id}; supported: ${SUPPORTED_CHAIN_IDS.join(", ")}`,
      );
    }
    if (!seen.has(id)) {
      seen.add(id);
      out.push(id);
    }
  }
  return out;
}

/**
 * Resolve one chain's settings. Takes `env` explicitly so the resolution rules
 * above are testable without mutating the process environment.
 */
export function loadChainConfig(chainId, env = process.env) {
  const spec = CHAINS[chainId];
  if (!spec) throw new Error(`no chain spec for ${chainId}`);

  const extraStateUrls = list(scoped, ["RPC_URLS_STATE", "RPC_URLS"], chainId, env);
  const extraLogUrls = list(scoped, ["RPC_URLS_LOGS", "RPC_URLS"], chainId, env);

  return {
    chainId,
    chain: spec.chain,
    label: spec.label,

    // Optional. When set, tried first for both state reads and log discovery.
    // Not required: the built-in pools are entirely keyless, and the point of
    // this bot is that tips get picked up eventually, not that they get picked
    // up fast -- so there is nothing to pay a provider for.
    rpcUrl: scoped("RPC_URL", chainId, env) || "",

    // Optional extra endpoints, comma-separated, inserted ahead of the built-in
    // public fallbacks. RPC_URLS applies to both roles; the role-specific vars
    // override when an endpoint is only good for one of them.
    extraStateUrls,
    extraLogUrls,

    defaultStateUrls: spec.stateUrls,
    defaultLogSources: spec.logSources,

    // Send-only endpoint. On mainnet this is Flashbots Protect; on an L2 it is
    // that chain's own RPC, because there is nothing else to send through.
    sendRpcUrl: scoped("SEND_RPC_URL", chainId, env) || spec.sendRpcUrl,

    slow: (shared("SLOW_ADDRESS", chainId, env) ||
      "0x000000006513b7821171c8447ec7ecdfa3b956fd").toLowerCase(),
    gate: (shared("GATE_ADDRESS", chainId, env) ||
      "0x76D1956b3BE7c0D09A16dE00DcE9B6f54ef28D34").toLowerCase(),

    // SLOW's deploy block on this chain; the gate is created in its
    // constructor, same block.
    startBlock: BigInt(scoped("START_BLOCK", chainId, env) ?? spec.startBlock),

    // Deliberately large. The wide-range sources serve the whole history in a
    // couple of requests, and being frugal with free endpoints matters more
    // than window size -- a capped source shrinks itself to fit on first
    // contact, so this costs the narrow tier nothing.
    logChunk: BigInt(shared("LOG_CHUNK", chainId, env) ?? "250000"),

    maxBatch: Number(shared("MAX_BATCH", chainId, env) ?? 10),

    // Claim only when tip >= cost * marginMultiple. 1.0 breaks even on paper;
    // above 1 leaves room for the basefee moving between simulation and
    // inclusion.
    marginMultiple: Number(shared("MARGIN_MULTIPLE", chainId, env) ?? 1.25),

    priorityFee: parseGwei(scoped("PRIORITY_GWEI", chainId, env) ?? spec.priorityGwei),
    // Ceiling on what we will ever bid, independent of the margin check.
    maxFeeCapGwei: parseGwei(scoped("MAX_FEE_GWEI", chainId, env) ?? spec.maxFeeGwei),

    l1FeeModel: spec.l1FeeModel,

    // Headroom on the L1 data component of an L2 claim. It is priced off the
    // Ethereum base fee at simulation time, and that number can move a long way
    // before the claim lands -- much further than an L2 base fee does. Doubling
    // it costs nothing when the tip is comfortable and declines exactly the
    // claims whose margin depends on L1 staying cheap.
    l1FeePad: Number(shared("L1_FEE_PAD", chainId, env) ?? (spec.l1FeeModel === "op-stack" ? 2 : 1)),
  };
}

export const config = {
  chainIds: resolveChainIds(),

  // Read, not required, at import: the resolution rules above are exercised by
  // the test suite, which has no key and no business inventing one. The keeper
  // entry point is what insists on a key, immediately before it would sign.
  privateKey: process.env.PRIVATE_KEY || "",

  // Minutes, not seconds. SLOW's delays run hours to days, so claiming a tip
  // three minutes after expiry is indistinguishable from claiming it in twelve
  // seconds -- and it keeps request volume inside what free public endpoints
  // will tolerate indefinitely.
  pollMs: num("POLL_MS", 180_000, process.env),

  receiptTimeoutMs: num("RECEIPT_TIMEOUT_MS", 180_000, process.env),

  // Run a single pass and exit instead of looping. Intended for a scheduled
  // cron run: the delays SLOW deals in are hours to days, so an hourly pass
  // settles just as reliably as a 12-second poll at a fraction of the cost.
  // The exit code is the liveness signal -- a failed run shows up in the
  // scheduler's history, where a wedged worker would just go quiet.
  oneShot: process.env.ONE_SHOT === "true",

  // Passes between heartbeat lines in worker mode. At the default poll
  // interval, 20 passes is roughly an hour.
  heartbeatEvery: num("HEARTBEAT_EVERY", 20, process.env),

  dryRun: process.env.DRY_RUN === "true",
};
