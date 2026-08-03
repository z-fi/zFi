import { parseGwei } from "viem";

function req(name) {
  const v = process.env[name];
  if (!v) throw new Error(`missing required env var ${name}`);
  return v;
}

function num(name, fallback) {
  const v = process.env[name];
  return v === undefined || v === "" ? fallback : Number(v);
}

export const config = {
  // Log-capable mainnet endpoint. Public RPCs that cap eth_getLogs at a 10-block
  // range cannot backfill -- use Alchemy/QuickNode/drpc.
  rpcUrl: req("RPC_URL"),

  // Send-only endpoint. Flashbots Protect keeps claims out of the public mempool
  // (no frontrunning) and drops reverting txs without charging gas, which is what
  // makes a lost race free rather than a wasted fee.
  sendRpcUrl: process.env.SEND_RPC_URL || "https://rpc.flashbots.net/fast",

  privateKey: req("PRIVATE_KEY"),

  slow: (process.env.SLOW_ADDRESS ||
    "0x000000000000888741b254d37e1b27128afeaabc").toLowerCase(),
  gate: (process.env.GATE_ADDRESS ||
    "0xb8B546b93a82f4Aa6f0345142dF5679B659ef3D4").toLowerCase(),

  // SLOW's deploy block; the gate is created in its constructor, same block.
  startBlock: BigInt(process.env.START_BLOCK || "24986598"),
  logChunk: BigInt(process.env.LOG_CHUNK || "10000"),

  pollMs: num("POLL_MS", 12_000),
  maxBatch: num("MAX_BATCH", 10),

  // Claim only when tip >= gasCost * marginMultiple. 1.0 breaks even on paper;
  // above 1 leaves room for the basefee moving between simulation and inclusion.
  marginMultiple: num("MARGIN_MULTIPLE", 1.25),

  priorityFee: parseGwei(process.env.PRIORITY_GWEI || "0.05"),
  // Ceiling on what we will ever bid, independent of the margin check.
  maxFeeCapGwei: parseGwei(process.env.MAX_FEE_GWEI || "50"),

  receiptTimeoutMs: num("RECEIPT_TIMEOUT_MS", 180_000),

  dryRun: process.env.DRY_RUN === "true",
};
