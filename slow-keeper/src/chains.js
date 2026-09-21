import { base, mainnet, robinhood } from "viem/chains";

/**
 * Everything that differs between the chains SLOW is deployed on. Adding a
 * fourth chain means adding one entry here and nothing else.
 *
 * SLOW and SLOWGate are at the same addresses everywhere -- identical runtime,
 * identical selectors -- so the ABI, the claim logic and the economics are
 * shared. What is not shared is where the history starts, what a block costs,
 * where a signed claim is allowed to go, and how the L1 data component of an
 * L2 transaction gets priced. Those four are the entries below.
 *
 * `label` prefixes every log line the chain's keeper emits. Keep them short and
 * distinct: on the hosted log stream they are the only thing separating three
 * interleaved keepers.
 */

/**
 * Deploy blocks were established by binary-searching `eth_getCode` at the SLOW
 * address over the full block height, against an archive endpoint, and are
 * pinned by the block below each one returning `0x`:
 *
 *   chain      block      timestamp              archive source used
 *   1          25913818   (pre-existing)         --
 *   8453       50927361   2026-09-05T21:34:29Z   mainnet.base.org / base.gateway.tenderly.co
 *   4663       55448611   2026-09-05T21:39:27Z   robinhood.drpc.org
 *
 * On 4663 the gate's own code appears in the same block, which is expected:
 * SLOW creates it in its constructor. The first SLOW log on that chain is at
 * 55908519, comfortably inside the scanned range.
 */

/**
 * How a claim's L1 data cost has to be priced.
 *
 *   "none"     -- L1. There is no data component; `gas * gasPrice` is the whole bill.
 *   "op-stack" -- Base. `eth_estimateGas` returns L2 execution gas only; the L1
 *                 batch cost is charged separately and has to be read from the
 *                 GasPriceOracle predeploy and added on.
 *   "nitro"    -- Robinhood. Nitro prices the batch-posting cost as extra gas
 *                 units inside the estimate itself (a plain send estimates at
 *                 21225, not 21000), so `gas * gasPrice` already contains it and
 *                 adding an oracle reading on top would double-count.
 */

const MAINNET_LOG_SOURCES = [
  // Wide-range, keyless. These three are what make a no-provider deployment
  // possible: any one of them can carry the whole boot backfill alone.
  { url: "https://rpc.mevblocker.io", maxRange: null },
  { url: "https://eth.api.onfinality.io/public", maxRange: null },
  { url: "https://gateway.tenderly.co/public/mainnet", maxRange: null },
  { url: "https://rpc.mevblocker.io/fast", maxRange: null },
  // Narrow, but fine for steady state: a pass advances far fewer blocks than
  // even the tightest cap here, so these still carry incremental discovery.
  { url: "https://eth.drpc.org", maxRange: 10_000n },
  { url: "https://eth-pokt.nodies.app", maxRange: 50n },
  { url: "https://1rpc.io/eth", maxRange: 50n },
  { url: "https://eth.blockrazor.xyz", maxRange: 25n },
  { url: "https://eth-mainnet.public.blastapi.io", maxRange: 10n },
];

const MAINNET_STATE_URLS = [
  "https://rpc.mevblocker.io",
  "https://eth.api.onfinality.io/public",
  "https://gateway.tenderly.co/public/mainnet",
  "https://ethereum-rpc.publicnode.com",
  "https://eth.rpc.blxrbdn.com",
  "https://eth-mainnet.public.blastapi.io",
  "https://eth.drpc.org",
  "https://1rpc.io/eth",
];

/**
 * Base, probed 2026-09-19 against this exact workload. Every width below is the
 * measured one -- the largest inclusive span the endpoint actually served, not
 * the number its error text quotes. drpc is the reason that distinction is
 * written down: it advertises a 10,000-block limit in the rejection and serves
 * about 70.
 *
 * No endpoint here serves an unlimited range, so the widest real cap sets the
 * backfill cadence: ~590k blocks of history at 2,000 per window is a few
 * hundred requests, which is a cold boot of about a minute and nothing at all
 * in steady state, where a pass advances a few hundred blocks.
 *
 *   endpoint                             getLogs range   eth_call / multicall
 *   mainnet.base.org                          2_000      ok (archive)
 *   developer-access-mainnet.base.org         2_000      ok (archive)
 *   base.gateway.tenderly.co                  1_000      ok (archive)
 *   base.drpc.org                                50      ok (archive)
 *   base-pokt.nodies.app                         50      ok
 *   1rpc.io/base                                 50      ok (throttles hard)
 *   base-mainnet.public.blastapi.io              10      ok
 *   base-rpc.publicnode.com                  archive-gated   ok
 *
 * Rejected as unusable: base.llamarpc.com, base.blockpi.network,
 * base.rpc.subquery.network, endpoints.omniatech.io, base.lava.build,
 * rpc.therpc.io, public.stackup.sh (dead or serving HTML), base.meowrpc.com
 * (answers "Too Many Requests" in plain text, not JSON), base.rpc.thirdweb.com
 * and base-mainnet.gateway.tatum.io (1,000 and 100 blocks respectively, which
 * buys nothing over the endpoints already listed).
 */
const BASE_LOG_SOURCES = [
  { url: "https://mainnet.base.org", maxRange: 2_000n },
  { url: "https://developer-access-mainnet.base.org", maxRange: 2_000n },
  { url: "https://base.gateway.tenderly.co", maxRange: 1_000n },
  { url: "https://base.drpc.org", maxRange: 50n },
  { url: "https://base-pokt.nodies.app", maxRange: 50n },
  { url: "https://1rpc.io/base", maxRange: 50n },
  { url: "https://base-mainnet.public.blastapi.io", maxRange: 10n },
];

const BASE_STATE_URLS = [
  "https://mainnet.base.org",
  "https://base.gateway.tenderly.co",
  "https://base-rpc.publicnode.com",
  "https://base.drpc.org",
  "https://base-mainnet.public.blastapi.io",
  "https://1rpc.io/base",
];

/**
 * Robinhood, probed 2026-09-19. The public endpoint list is short -- this is a
 * young chain -- but the official RPC serves an unbounded `getLogs` range, so
 * the entire history comes back in a single request and the narrow tier that
 * mainnet needs has no job here.
 *
 *   endpoint                          getLogs range   state reads
 *   rpc.mainnet.chain.robinhood.com   unlimited       latest only (no archive)
 *   robinhood.drpc.org                unavailable     ok (archive)
 *
 * `robinhood-rpc.publicnode.com` answers every historical read with "Archive
 * requests require a personal token" and is therefore left out entirely; it
 * cannot serve a backfill and it cannot serve a state read at a past block.
 * drpc rejects `getLogs` on this chain at any width, so it is a state-only
 * backstop -- which is also the only archive source, and the one the deploy
 * block above was established against.
 */
const ROBINHOOD_LOG_SOURCES = [
  { url: "https://rpc.mainnet.chain.robinhood.com", maxRange: null },
];

const ROBINHOOD_STATE_URLS = [
  "https://rpc.mainnet.chain.robinhood.com",
  "https://robinhood.drpc.org",
];

export const CHAINS = {
  1: {
    chain: mainnet,
    label: "eth",
    startBlock: 25913818n,
    // Flashbots Protect keeps claims out of the public mempool (no
    // frontrunning) and drops reverting txs without charging gas, which is what
    // makes a lost race free rather than a wasted fee.
    sendRpcUrl: "https://rpc.flashbots.net/fast",
    maxFeeGwei: "50",
    priorityGwei: "0.05",
    l1FeeModel: "none",
    logSources: MAINNET_LOG_SOURCES,
    stateUrls: MAINNET_STATE_URLS,
  },
  8453: {
    chain: base,
    label: "base",
    startBlock: 50927361n,
    // No Protect-equivalent here, so a claim goes through an ordinary endpoint
    // and sits in the public mempool. That makes a lost race a paid revert
    // rather than a free drop -- which is why the pre-send simulation matters
    // more on an L2 than it does on mainnet, and why it stays immediately
    // before signing.
    sendRpcUrl: "https://mainnet.base.org",
    // Base's base fee sits around 0.006 gwei. Half a gwei is ~80x that: high
    // enough that the ceiling never binds during an ordinary spike, low enough
    // that a broken fee reading cannot quietly spend a mainnet-sized fee.
    maxFeeGwei: "0.5",
    priorityGwei: "0.001",
    l1FeeModel: "op-stack",
    logSources: BASE_LOG_SOURCES,
    stateUrls: BASE_STATE_URLS,
  },
  4663: {
    chain: robinhood,
    label: "rh",
    startBlock: 55448611n,
    sendRpcUrl: "https://rpc.mainnet.chain.robinhood.com",
    // Observed gas price is ~0.062 gwei. One gwei is ~16x that.
    maxFeeGwei: "1",
    // Nitro's sequencer orders by arrival, not by bid, so a priority fee buys
    // nothing here. Bidding zero is the honest price.
    priorityGwei: "0",
    l1FeeModel: "nitro",
    logSources: ROBINHOOD_LOG_SOURCES,
    stateUrls: ROBINHOOD_STATE_URLS,
  },
};

export const SUPPORTED_CHAIN_IDS = Object.keys(CHAINS).map(Number);
