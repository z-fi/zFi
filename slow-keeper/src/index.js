import { privateKeyToAccount } from "viem/accounts";

import { config, loadChainConfig } from "./config.js";
import { Keeper, shortErr } from "./keeper.js";
import { log } from "./log.js";

if (!config.privateKey) throw new Error("missing required env var PRIVATE_KEY");

const account = privateKeyToAccount(
  config.privateKey.startsWith("0x") ? config.privateKey : `0x${config.privateKey}`,
);

/**
 * One process, one key, one keeper per chain in CHAINS.
 *
 * The chains do not coordinate and deliberately never await each other. SLOW's
 * books are entirely separate per chain -- a transferId on Base means nothing
 * on mainnet -- so there is no shared state to protect, and the only resource
 * they have in common is the signing account, whose nonce sequences are already
 * per chain. That leaves failure isolation as the whole job: every loop carries
 * its own error boundary so an endpoint outage on one chain cannot stall the
 * others' claims.
 */
async function main() {
  log(`keeper ${account.address}`);
  log(`chains: ${config.chainIds.join(", ")}`);

  const keepers = config.chainIds.map((id) => new Keeper(loadChainConfig(id), account));
  for (const k of keepers) k.announce();

  if (config.oneShot) return runOnce(keepers);

  // Nothing here resolves: each worker loops for the life of the process.
  await Promise.all(keepers.map((k) => k.runWorker()));
}

/**
 * Cron mode across every configured chain. Each chain runs its pass regardless
 * of what the others did, and the failures are collected rather than thrown as
 * they happen: a Robinhood endpoint being down must not cost mainnet its hourly
 * settlement, and it must still turn the run red so the scheduler's history
 * shows it.
 */
async function runOnce(keepers) {
  const outcomes = await Promise.all(
    keepers.map((k) =>
      k
        .runOnce()
        .then(() => null)
        .catch((err) => {
          k.log(`pass failed: ${shortErr(err)}`);
          return k.cfg.chainId;
        }),
    ),
  );

  const failed = outcomes.filter((x) => x !== null);
  if (failed.length) throw new Error(`chain(s) ${failed.join(", ")} failed this pass`);
  log(`one-shot complete across ${keepers.length} chain(s)`);
}

main()
  .then(() => {
    if (config.oneShot) process.exit(0);
  })
  .catch((err) => {
    log("fatal:", shortErr(err));
    process.exit(1);
  });
