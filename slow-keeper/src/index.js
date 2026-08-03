import { createWalletClient, encodeFunctionData, formatEther, http } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { mainnet } from "viem/chains";

import { config } from "./config.js";
import { GATE_ABI, SLOW_ABI } from "./abi.js";
import { LogPool, makeStateClient } from "./rpc.js";

const log = (...a) => console.log(new Date().toISOString(), ...a);

const account = privateKeyToAccount(
  config.privateKey.startsWith("0x") ? config.privateKey : `0x${config.privateKey}`,
);

// State reads rotate across a pool automatically. Claims deliberately do NOT
// fall back: they go to Flashbots Protect only. A public-mempool fallback would
// silently change the economics -- lost races would land as paid reverts
// instead of being dropped -- so if Protect is unreachable the bot waits.
const pub = makeStateClient();
const logPool = new LogPool();
const sender = createWalletClient({
  account,
  chain: mainnet,
  transport: http(config.sendRpcUrl),
});

/**
 * transferId -> { tip, to, readyAt }
 *
 * Rebuilt from TipPosted logs on every boot, so the worker needs no persistent
 * disk. Entries leave only when the underlying pending transfer clears (claimed
 * by us or anyone else, reversed, or clawed back).
 */
const tips = new Map();
let lastScanned = config.startBlock - 1n;

// How many poll passes between full re-reads of every tracked tip.
const REHYDRATE_EVERY = 25;

// -- discovery ---------------------------------------------------------------

async function scanLogs(toBlock) {
  if (lastScanned >= toBlock) return [];
  const found = [];

  // Tips are recorded and `lastScanned` advances per window, so a source dying
  // partway through a long backfill costs only the unscanned remainder -- the
  // next attempt resumes there instead of restarting.
  await logPool.scan(
    { address: config.gate, abi: GATE_ABI, eventName: "TipPosted" },
    lastScanned + 1n,
    toBlock,
    (logs, covered) => {
      for (const l of logs) {
        const { transferId, amount, to: recipient } = l.args;
        // A transferId is unique per deposit, so a repeat log cannot occur;
        // guard anyway so a re-org replay never doubles an entry.
        if (!tips.has(transferId)) {
          found.push(transferId);
          tips.set(transferId, { tip: amount, to: recipient, readyAt: null });
        }
      }
      lastScanned = covered;
    },
  );

  return found;
}

/**
 * Fill in readyAt from on-chain state and drop anything already settled.
 * pendingTransfers is deleted on every settlement path, so timestamp == 0 means
 * the tip is either already ours, already paid to another keeper, or refundable
 * by the depositor -- nothing left for us either way.
 */
async function hydrate(ids) {
  if (!ids.length) return;
  const results = await pub.multicall({
    contracts: ids.map((id) => ({
      address: config.slow,
      abi: SLOW_ABI,
      functionName: "pendingTransfers",
      args: [id],
    })),
    allowFailure: true,
  });

  let dropped = 0;
  results.forEach((r, i) => {
    const id = ids[i];
    if (r.status !== "success") return; // retry on a later pass
    const [timestamp, , to, tokenId] = r.result;
    if (timestamp === 0n) {
      tips.delete(id);
      dropped++;
      return;
    }
    const entry = tips.get(id);
    if (!entry) return;
    entry.to = to;
    entry.readyAt = timestamp + (tokenId >> 160n); // delay is packed above the token address
  });
  if (dropped) log(`dropped ${dropped} already-settled tip(s)`);
}

// -- eligibility -------------------------------------------------------------

/**
 * A due tip is only claimable if the recipient has no guardian: _doClaim reverts
 * ClaimBlockedByGuardian otherwise. Recipients can set a guardian after the tip
 * was posted (and remove it again), so this is re-checked every pass rather than
 * cached.
 */
async function filterClaimable(ids) {
  if (!ids.length) return [];
  const uniqueRecipients = [...new Set(ids.map((id) => tips.get(id).to))];
  const guardianResults = await pub.multicall({
    contracts: uniqueRecipients.map((addr) => ({
      address: config.slow,
      abi: SLOW_ABI,
      functionName: "guardians",
      args: [addr],
    })),
    allowFailure: true,
  });

  const blocked = new Set();
  guardianResults.forEach((r, i) => {
    if (r.status !== "success") blocked.add(uniqueRecipients[i]);
    else if (r.result !== "0x0000000000000000000000000000000000000000") {
      blocked.add(uniqueRecipients[i]);
    }
  });

  return ids.filter((id) => !blocked.has(tips.get(id).to));
}

// -- settlement --------------------------------------------------------------

function calldataFor(ids) {
  return ids.length === 1
    ? encodeFunctionData({ abi: GATE_ABI, functionName: "claim", args: [ids[0]] })
    : encodeFunctionData({ abi: GATE_ABI, functionName: "claimMany", args: [ids] });
}

/**
 * claimMany is atomic -- one stale id reverts the whole batch. Simulate, and on
 * failure fall back to per-id simulation so a single bad entry cannot block the
 * rest of the batch.
 */
async function simulate(ids) {
  try {
    const gas = await pub.estimateGas({
      account,
      to: config.gate,
      data: calldataFor(ids),
    });
    return { ids, gas };
  } catch (err) {
    if (ids.length === 1) {
      log(`id ${ids[0]} not claimable: ${shortErr(err)}`);
      return null;
    }
    log(`batch of ${ids.length} failed simulation, splitting`);
    const good = [];
    for (const id of ids) {
      const single = await simulate([id]);
      if (single) good.push(id);
    }
    return good.length ? simulate(good) : null;
  }
}

/** Returns true if a claim was actually broadcast (or would be, in a dry run). */
async function settle(ids) {
  const sim = await simulate(ids);
  if (!sim) return false;

  const block = await pub.getBlock({ blockTag: "latest" });
  const baseFee = block.baseFeePerGas ?? 0n;
  let maxFee = baseFee * 2n + config.priorityFee;
  if (maxFee > config.maxFeeCapGwei) maxFee = config.maxFeeCapGwei;

  // Price against the fee we actually expect to pay for inclusion in the next
  // block, not the ceiling we are willing to bid.
  const expectedGasPrice = baseFee + config.priorityFee;
  const cost = sim.gas * expectedGasPrice;
  const revenue = sim.ids.reduce((acc, id) => acc + tips.get(id).tip, 0n);

  // Integer margin check: revenue * 100 >= cost * margin * 100.
  const marginBps = BigInt(Math.round(config.marginMultiple * 100));
  if (revenue * 100n < cost * marginBps) {
    log(
      `skip ${sim.ids.length} id(s): tip ${formatEther(revenue)} ETH < ` +
        `cost ${formatEther(cost)} ETH x ${config.marginMultiple}`,
    );
    return false;
  }

  log(
    `claiming ${sim.ids.length} id(s): tip ${formatEther(revenue)} ETH, ` +
      `est cost ${formatEther(cost)} ETH, gas ${sim.gas}`,
  );

  if (config.dryRun) {
    log("DRY_RUN set, not sending");
    return true;
  }

  const nonce = await pub.getTransactionCount({ address: account.address, blockTag: "pending" });
  const serialized = await account.signTransaction({
    chainId: mainnet.id,
    to: config.gate,
    data: calldataFor(sim.ids),
    gas: (sim.gas * 12n) / 10n,
    maxFeePerGas: maxFee,
    maxPriorityFeePerGas: config.priorityFee,
    nonce,
    type: "eip1559",
  });

  const hash = await sender.sendRawTransaction({ serializedTransaction: serialized });
  log(`submitted ${hash}`);

  try {
    const receipt = await pub.waitForTransactionReceipt({
      hash,
      timeout: config.receiptTimeoutMs,
    });
    log(`tx ${hash} ${receipt.status} in block ${receipt.blockNumber}`);
    if (receipt.status === "success") for (const id of sim.ids) tips.delete(id);
  } catch {
    // Flashbots Protect drops txs it cannot include rather than landing a revert,
    // so a timeout means "not included" -- the ids stay queued for the next pass.
    log(`tx ${hash} not included within timeout, requeuing ids`);
  }
  return true;
}

// -- main loop ---------------------------------------------------------------

function shortErr(err) {
  return (err?.shortMessage || err?.message || String(err)).split("\n")[0];
}

let ticks = 0;

async function tick() {
  const head = await pub.getBlockNumber();
  const fresh = await scanLogs(head);
  if (fresh.length) log(`found ${fresh.length} new tip(s)`);

  // Hydrate new entries. Every REHYDRATE_EVERY passes, re-read the whole set
  // instead: transfers settled by other keepers (or reversed by the sender)
  // emit nothing we watch, so a periodic sweep is what evicts them.
  const full = ticks++ % REHYDRATE_EVERY === 0;
  const needsHydration = [...tips.entries()]
    .filter(([, e]) => full || e.readyAt === null)
    .map(([id]) => id);
  await hydrate(needsHydration);

  const now = BigInt(Math.floor(Date.now() / 1000));
  const due = [...tips.entries()]
    .filter(([, e]) => e.readyAt !== null && now >= e.readyAt)
    .sort((a, b) => (b[1].tip > a[1].tip ? 1 : -1)) // richest first
    .map(([id]) => id);

  if (!due.length) return { due: 0, claimable: 0, sent: false };

  const claimable = await filterClaimable(due);
  if (!claimable.length) {
    log(`${due.length} due but all blocked by recipient guardians`);
    return { due: due.length, claimable: 0, sent: false };
  }

  const sent = await settle(claimable.slice(0, config.maxBatch));
  return { due: due.length, claimable: claimable.length, sent };
}

/**
 * Proof of life. Tips arrive rarely enough that "nothing happening" is the
 * normal state, which makes a wedged worker indistinguishable from a healthy
 * idle one. This prints the shape of the queue so the log answers the
 * difference at a glance.
 */
async function heartbeat() {
  const now = BigInt(Math.floor(Date.now() / 1000));
  const pending = [...tips.values()];
  const waiting = pending.filter((e) => e.readyAt !== null && e.readyAt > now);
  let soonest = null;
  for (const e of waiting) if (soonest === null || e.readyAt < soonest) soonest = e.readyAt;

  let balance = "unknown";
  try {
    balance = `${formatEther(await pub.getBalance({ address: account.address }))} ETH`;
  } catch {
    /* a heartbeat must never be the thing that kills the loop */
  }

  const next =
    soonest === null
      ? "none scheduled"
      : `next in ${Math.round(Number(soonest - now) / 60)} min`;
  log(`heartbeat: tracking ${tips.size} tip(s), ${waiting.length} awaiting expiry, ${next}, gas ${balance}`);
}

async function main() {
  log(`keeper ${account.address}`);
  log(`slow ${config.slow} gate ${config.gate}`);
  log(`send via ${config.sendRpcUrl}${config.dryRun ? " (DRY RUN)" : ""}`);

  const gate = await pub.readContract({
    address: config.slow,
    abi: SLOW_ABI,
    functionName: "gate",
  });
  if (gate.toLowerCase() !== config.gate) {
    throw new Error(`gate mismatch: SLOW reports ${gate}, config has ${config.gate}`);
  }

  const balance = await pub.getBalance({ address: account.address });
  log(`gas balance ${formatEther(balance)} ETH`);
  if (balance === 0n) log("WARNING: zero balance, every claim will fail to send");

  log(`backfilling TipPosted from block ${config.startBlock}...`);

  if (config.oneShot) return runOnce();

  for (;;) {
    try {
      await tick();
      if (config.heartbeatEvery > 0 && ticks % config.heartbeatEvery === 0) await heartbeat();
    } catch (err) {
      log(`tick error: ${shortErr(err)}`);
    }
    await new Promise((r) => setTimeout(r, config.pollMs));
  }
}

/**
 * Cron mode. Keeps settling while passes are still producing claims, so a
 * backlog larger than one batch clears in a single run rather than waiting for
 * the next schedule. Errors propagate: a non-zero exit is what makes a broken
 * run visible in the scheduler's history.
 */
async function runOnce() {
  let total = 0;
  for (let pass = 0; pass < 10; pass++) {
    const result = await tick();
    if (!result.sent) {
      if (pass === 0) log(`nothing to claim (${result.due} due, ${result.claimable} claimable)`);
      break;
    }
    total++;
  }
  await heartbeat();
  log(`one-shot complete, ${total} batch(es) claimed`);
}

main()
  .then(() => {
    if (config.oneShot) process.exit(0);
  })
  .catch((err) => {
    log("fatal:", shortErr(err));
    process.exit(1);
  });
