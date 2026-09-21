import { createWalletClient, encodeFunctionData, formatEther, formatGwei, http } from "viem";

import { GATE_ABI, SLOW_ABI } from "./abi.js";
import { config } from "./config.js";
import { l1DataFee } from "./l1fee.js";
import { chainLogger } from "./log.js";
import { LogPool, makeStateClient, redact } from "./rpc.js";

const ZERO_ADDRESS = "0x0000000000000000000000000000000000000000";

// How many poll passes between full re-reads of every tracked tip.
const REHYDRATE_EVERY = 25;

export function shortErr(err) {
  return (err?.shortMessage || err?.message || String(err)).split("\n")[0];
}

/**
 * One chain's keeper: its own tip book, its own block high-water mark, its own
 * endpoint pools and its own wallet client.
 *
 * Nothing is shared between instances except the signing account, and that is
 * safe because nonces are per chain -- two keepers signing at the same instant
 * are signing against two independent nonce sequences. Everything else being
 * instance state is what makes one chain's failure local: a Robinhood endpoint
 * going dark drops requests inside that instance's pools and leaves the
 * mainnet instance's book, cursor and loop untouched.
 */
export class Keeper {
  constructor(cfg, account) {
    this.cfg = cfg;
    this.account = account;
    this.log = chainLogger(cfg.label);

    this.pub = makeStateClient(cfg);
    this.logPool = new LogPool(cfg);

    // State reads rotate across a pool automatically. Claims deliberately do
    // NOT fall back: they go to the chain's single configured send endpoint.
    // On mainnet that is Flashbots Protect, and a public-mempool fallback
    // would silently change the economics -- lost races would land as paid
    // reverts instead of being dropped -- so if Protect is unreachable the bot
    // waits.
    this.sender = createWalletClient({
      account,
      chain: cfg.chain,
      transport: http(cfg.sendRpcUrl),
    });

    /**
     * transferId -> { tip, to, readyAt }
     *
     * Rebuilt from TipPosted logs on every boot, so the worker needs no
     * persistent disk. Entries leave only when the underlying pending transfer
     * clears (claimed by us or anyone else, reversed, or clawed back).
     */
    this.tips = new Map();
    this.lastScanned = cfg.startBlock - 1n;

    this.ticks = 0;
    this.verified = false;
  }

  // -- preflight -------------------------------------------------------------

  /**
   * Confirm this chain's SLOW really points at the gate we are about to sign
   * claims for, once per process. Deferred to the first pass rather than run at
   * construction so an endpoint that is briefly down at boot costs one pass
   * instead of retiring the chain for the lifetime of the worker.
   */
  async verify() {
    if (this.verified) return;
    const gate = await this.pub.readContract({
      address: this.cfg.slow,
      abi: SLOW_ABI,
      functionName: "gate",
    });
    if (gate.toLowerCase() !== this.cfg.gate) {
      throw new Error(`gate mismatch: SLOW reports ${gate}, config has ${this.cfg.gate}`);
    }
    const balance = await this.pub.getBalance({ address: this.account.address });
    this.log(`verified, gas balance ${formatEther(balance)} ETH`);
    if (balance === 0n) this.log("WARNING: zero balance, every claim will fail to send");
    this.log(`backfilling TipPosted from block ${this.cfg.startBlock}...`);
    this.verified = true;
  }

  announce() {
    this.log(
      `chain ${this.cfg.chainId} (${this.cfg.chain.name}), slow ${this.cfg.slow}, gate ${this.cfg.gate}`,
    );
    this.log(
      `send via ${redact(this.cfg.sendRpcUrl)}, max fee ${formatGwei(this.cfg.maxFeeCapGwei)} gwei, ` +
        `l1 fee model ${this.cfg.l1FeeModel}${config.dryRun ? " (DRY RUN)" : ""}`,
    );
  }

  // -- discovery -------------------------------------------------------------

  async scanLogs(toBlock) {
    if (this.lastScanned >= toBlock) return [];
    const found = [];

    // Tips are recorded and `lastScanned` advances per window, so a source
    // dying partway through a long backfill costs only the unscanned remainder
    // -- the next attempt resumes there instead of restarting.
    await this.logPool.scan(
      { address: this.cfg.gate, abi: GATE_ABI, eventName: "TipPosted" },
      this.lastScanned + 1n,
      toBlock,
      (logs, covered) => {
        for (const l of logs) {
          const { transferId, amount, to: recipient } = l.args;
          // A transferId is unique per deposit, so a repeat log cannot occur;
          // guard anyway so a re-org replay never doubles an entry.
          if (!this.tips.has(transferId)) {
            found.push(transferId);
            this.tips.set(transferId, { tip: amount, to: recipient, readyAt: null });
          }
        }
        this.lastScanned = covered;
      },
    );

    return found;
  }

  /**
   * Fill in readyAt from on-chain state and drop anything already settled.
   * pendingTransfers is deleted on every settlement path, so timestamp == 0
   * means the tip is either already ours, already paid to another keeper, or
   * refundable by the depositor -- nothing left for us either way.
   */
  async hydrate(ids) {
    if (!ids.length) return;
    const results = await this.pub.multicall({
      contracts: ids.map((id) => ({
        address: this.cfg.slow,
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
        this.tips.delete(id);
        dropped++;
        return;
      }
      const entry = this.tips.get(id);
      if (!entry) return;
      entry.to = to;
      entry.readyAt = timestamp + (tokenId >> 160n); // delay is packed above the token address
    });
    if (dropped) this.log(`dropped ${dropped} already-settled tip(s)`);
  }

  // -- eligibility -----------------------------------------------------------

  /**
   * A due tip is only claimable if the recipient has no guardian: _doClaim
   * reverts ClaimBlockedByGuardian otherwise. Recipients can set a guardian
   * after the tip was posted (and remove it again), so this is re-checked every
   * pass rather than cached.
   */
  async filterClaimable(ids) {
    if (!ids.length) return [];
    const uniqueRecipients = [...new Set(ids.map((id) => this.tips.get(id).to))];
    const guardianResults = await this.pub.multicall({
      contracts: uniqueRecipients.map((addr) => ({
        address: this.cfg.slow,
        abi: SLOW_ABI,
        functionName: "guardians",
        args: [addr],
      })),
      allowFailure: true,
    });

    const blocked = new Set();
    guardianResults.forEach((r, i) => {
      if (r.status !== "success") blocked.add(uniqueRecipients[i]);
      else if (r.result !== ZERO_ADDRESS) blocked.add(uniqueRecipients[i]);
    });

    return ids.filter((id) => !blocked.has(this.tips.get(id).to));
  }

  // -- settlement ------------------------------------------------------------

  calldataFor(ids) {
    return ids.length === 1
      ? encodeFunctionData({ abi: GATE_ABI, functionName: "claim", args: [ids[0]] })
      : encodeFunctionData({ abi: GATE_ABI, functionName: "claimMany", args: [ids] });
  }

  /**
   * claimMany is atomic -- one stale id reverts the whole batch. Simulate, and
   * on failure fall back to per-id simulation so a single bad entry cannot
   * block the rest of the batch.
   */
  async simulate(ids) {
    try {
      const gas = await this.pub.estimateGas({
        account: this.account,
        to: this.cfg.gate,
        data: this.calldataFor(ids),
      });
      return { ids, gas };
    } catch (err) {
      if (ids.length === 1) {
        await this.explainFailure(ids[0], err);
        return null;
      }
      this.log(`batch of ${ids.length} failed simulation, splitting`);
      const good = [];
      for (const id of ids) {
        const single = await this.simulate([id]);
        if (single) good.push(id);
      }
      return good.length ? this.simulate(good) : null;
    }
  }

  /**
   * Say why a single-id claim would revert, and evict the id when the answer is
   * permanent.
   *
   * The revert itself is useless on its own: `gate.claim` on a cleared transfer
   * bubbles up SLOW's `TransferDoesNotExist`, a custom error viem renders as
   * "reverted for an unknown reason". Reading `pendingTransfers` answers it
   * outright, and evicting keeps a settled id from being re-simulated on every
   * pass forever -- the exact spam a claim landing on one instance while
   * another instance held the same id in memory produced.
   */
  async explainFailure(id, err) {
    const entry = this.tips.get(id);
    try {
      const [timestamp, , to] = await this.pub.readContract({
        address: this.cfg.slow,
        abi: SLOW_ABI,
        functionName: "pendingTransfers",
        args: [id],
      });
      if (timestamp === 0n) {
        this.tips.delete(id);
        this.log(`id ${id} already settled, evicted`);
        return;
      }
      if (entry) {
        const guardian = await this.pub.readContract({
          address: this.cfg.slow,
          abi: SLOW_ABI,
          functionName: "guardians",
          args: [to],
        });
        if (guardian !== ZERO_ADDRESS) {
          this.log(`id ${id} blocked by recipient guardian, will retry if removed`);
          return;
        }
      }
    } catch {
      // Fall through to the raw reason if the follow-up read fails.
    }
    this.log(`id ${id} not claimable: ${shortErr(err)}`);
  }

  /** Returns true if a claim was actually broadcast (or would be, in a dry run). */
  async settle(ids) {
    const sim = await this.simulate(ids);
    if (!sim) return false;

    const block = await this.pub.getBlock({ blockTag: "latest" });
    const baseFee = block.baseFeePerGas ?? 0n;
    let maxFee = baseFee * 2n + this.cfg.priorityFee;
    if (maxFee > this.cfg.maxFeeCapGwei) maxFee = this.cfg.maxFeeCapGwei;

    // Price against the fee we actually expect to pay for inclusion in the next
    // block, not the ceiling we are willing to bid.
    const expectedGasPrice = baseFee + this.cfg.priorityFee;

    // On an L2 the execution gas is only part of the bill; `l1DataFee` supplies
    // the rest, padded, and returns zero on the chains where the estimate
    // already covers it. A chain that charges an L1 component we cannot read is
    // left alone until the next pass rather than priced as if it were free.
    let l1Fee;
    try {
      l1Fee = await l1DataFee(this.cfg, this.pub, this.calldataFor(sim.ids));
    } catch (err) {
      this.log(`skip ${sim.ids.length} id(s): L1 data fee unreadable (${shortErr(err)})`);
      return false;
    }

    const cost = sim.gas * expectedGasPrice + l1Fee;
    const revenue = sim.ids.reduce((acc, id) => acc + this.tips.get(id).tip, 0n);

    // Integer margin check: revenue * 100 >= cost * margin * 100.
    const marginBps = BigInt(Math.round(this.cfg.marginMultiple * 100));
    if (revenue * 100n < cost * marginBps) {
      this.log(
        `skip ${sim.ids.length} id(s): tip ${formatEther(revenue)} ETH < ` +
          `cost ${formatEther(cost)} ETH x ${this.cfg.marginMultiple}` +
          (l1Fee > 0n ? ` (incl ${formatEther(l1Fee)} ETH L1 data)` : ""),
      );
      return false;
    }

    this.log(
      `claiming ${sim.ids.length} id(s): tip ${formatEther(revenue)} ETH, ` +
        `est cost ${formatEther(cost)} ETH, gas ${sim.gas}` +
        (l1Fee > 0n ? `, L1 data ${formatEther(l1Fee)} ETH` : ""),
    );

    if (config.dryRun) {
      this.log("DRY_RUN set, not sending");
      return true;
    }

    const nonce = await this.pub.getTransactionCount({
      address: this.account.address,
      blockTag: "pending",
    });
    const serialized = await this.account.signTransaction({
      chainId: this.cfg.chainId,
      to: this.cfg.gate,
      data: this.calldataFor(sim.ids),
      gas: (sim.gas * 12n) / 10n,
      maxFeePerGas: maxFee,
      maxPriorityFeePerGas: this.cfg.priorityFee,
      nonce,
      type: "eip1559",
    });

    let hash;
    try {
      hash = await this.sender.sendRawTransaction({ serializedTransaction: serialized });
    } catch (err) {
      // A rejected broadcast is an ordinary outcome, not a reason to abort the
      // pass. The common case is a nonce already spent by another claim -- e.g.
      // a second instance of this bot sharing the key, which the relay refuses
      // with "Missing or invalid parameters". Nothing was spent; the ids stay
      // queued and the next pass re-reads the nonce.
      this.log(`send rejected, requeuing ${sim.ids.length} id(s): ${shortErr(err)}`);
      return false;
    }
    this.log(`submitted ${hash}`);

    try {
      const receipt = await this.pub.waitForTransactionReceipt({
        hash,
        timeout: config.receiptTimeoutMs,
      });
      this.log(`tx ${hash} ${receipt.status} in block ${receipt.blockNumber}`);
      if (receipt.status === "success") for (const id of sim.ids) this.tips.delete(id);
    } catch {
      // On mainnet, Protect drops txs it cannot include rather than landing a
      // revert, so a timeout means "not included". On an L2 a timeout means the
      // endpoint has not surfaced the receipt yet. Either way the ids stay
      // queued, and the next pass re-simulates before it would sign again.
      this.log(`tx ${hash} not included within timeout, requeuing ids`);
    }
    return true;
  }

  // -- passes ----------------------------------------------------------------

  async tick() {
    await this.verify();

    const head = await this.pub.getBlockNumber();
    const fresh = await this.scanLogs(head);
    if (fresh.length) this.log(`found ${fresh.length} new tip(s)`);

    // Hydrate new entries. Every REHYDRATE_EVERY passes, re-read the whole set
    // instead: transfers settled by other keepers (or reversed by the sender)
    // emit nothing we watch, so a periodic sweep is what evicts them.
    const full = this.ticks++ % REHYDRATE_EVERY === 0;
    const needsHydration = [...this.tips.entries()]
      .filter(([, e]) => full || e.readyAt === null)
      .map(([id]) => id);
    await this.hydrate(needsHydration);

    const now = BigInt(Math.floor(Date.now() / 1000));
    const due = [...this.tips.entries()]
      .filter(([, e]) => e.readyAt !== null && now >= e.readyAt)
      .sort((a, b) => (b[1].tip > a[1].tip ? 1 : -1)) // richest first
      .map(([id]) => id);

    if (!due.length) return { due: 0, claimable: 0, sent: false };

    const claimable = await this.filterClaimable(due);
    if (!claimable.length) {
      this.log(`${due.length} due but all blocked by recipient guardians`);
      return { due: due.length, claimable: 0, sent: false };
    }

    const sent = await this.settle(claimable.slice(0, this.cfg.maxBatch));
    return { due: due.length, claimable: claimable.length, sent };
  }

  /**
   * Proof of life. Tips arrive rarely enough that "nothing happening" is the
   * normal state, which makes a wedged worker indistinguishable from a healthy
   * idle one. This prints the shape of the queue so the log answers the
   * difference at a glance -- per chain, because a single chain going quiet is
   * exactly the failure the tag is there to expose.
   */
  async heartbeat() {
    const now = BigInt(Math.floor(Date.now() / 1000));
    const pending = [...this.tips.values()];
    const waiting = pending.filter((e) => e.readyAt !== null && e.readyAt > now);
    let soonest = null;
    for (const e of waiting) if (soonest === null || e.readyAt < soonest) soonest = e.readyAt;

    let balance = "unknown";
    try {
      balance = `${formatEther(await this.pub.getBalance({ address: this.account.address }))} ETH`;
    } catch {
      /* a heartbeat must never be the thing that kills the loop */
    }

    const next =
      soonest === null
        ? "none scheduled"
        : `next in ${Math.round(Number(soonest - now) / 60)} min`;
    this.log(
      `heartbeat: tracking ${this.tips.size} tip(s), ${waiting.length} awaiting expiry, ${next}, gas ${balance}`,
    );
  }

  /**
   * Worker mode. Each chain owns its own loop and its own error boundary, so a
   * dead endpoint on one chain costs that chain a pass and nothing anywhere
   * else. Nothing in here is allowed to throw: the loop is the process's
   * lifetime.
   */
  async runWorker() {
    for (;;) {
      try {
        await this.tick();
        if (config.heartbeatEvery > 0 && this.ticks % config.heartbeatEvery === 0) {
          await this.heartbeat();
        }
      } catch (err) {
        this.log(`tick error: ${shortErr(err)}`);
      }
      await new Promise((r) => setTimeout(r, config.pollMs));
    }
  }

  /**
   * Cron mode. Keeps settling while passes are still producing claims, so a
   * backlog larger than one batch clears in a single run rather than waiting
   * for the next schedule. Errors propagate to the caller, which collects them
   * per chain: a non-zero exit is what makes a broken run visible in the
   * scheduler's history, and it must still be reported when the other chains
   * succeeded.
   */
  async runOnce() {
    let total = 0;
    for (let pass = 0; pass < 10; pass++) {
      const result = await this.tick();
      if (!result.sent) {
        if (pass === 0) {
          this.log(`nothing to claim (${result.due} due, ${result.claimable} claimable)`);
        }
        break;
      }
      total++;
    }
    await this.heartbeat();
    this.log(`one-shot complete, ${total} batch(es) claimed`);
  }
}
