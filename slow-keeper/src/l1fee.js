/**
 * Pricing the L1 half of an L2 claim.
 *
 * A claim on Base or Robinhood pays twice: once for L2 execution, and once for
 * the bytes the sequencer posts to Ethereum. The second half is priced off the
 * Ethereum base fee, so it can be the larger of the two when L1 is busy, and
 * ignoring it means the profit gate approves claims that lose money.
 *
 * The two stacks charge it in different places, so they are read differently:
 *
 * Nitro (Robinhood) folds the batch-posting cost into the gas estimate as extra
 * gas units -- a plain value send estimates at 21225 rather than 21000. `gas *
 * gasPrice` therefore already contains it, and adding an oracle reading on top
 * would charge it twice and decline claims that are in fact profitable.
 *
 * OP-stack (Base) returns L2 execution gas only from `eth_estimateGas` and
 * bills the L1 component separately, so it has to be read from the
 * GasPriceOracle predeploy and added to the cost by hand.
 */

// GasPriceOracle, at the same predeploy address on every OP-stack chain.
const OP_GAS_ORACLE = "0x420000000000000000000000000000000000000F";

const GAS_ORACLE_ABI = [
  {
    type: "function",
    name: "getL1Fee",
    stateMutability: "view",
    inputs: [{ name: "_data", type: "bytes" }],
    outputs: [{ name: "", type: "uint256" }],
  },
];

/**
 * The oracle prices whatever bytes it is handed, so the calldata alone
 * under-reports: a signed transaction also carries nonce, both fee fields, gas
 * limit, destination, chain id and a 65-byte signature. 160 bytes covers that
 * envelope with room to spare, and they are sent as non-zero bytes because
 * non-zero is the expensive kind -- the reading comes out an upper bound rather
 * than an optimistic one.
 */
const ENVELOPE_BYTES = 160;

/**
 * Wei of L1 data cost this calldata will add, already padded by `cfg.l1FeePad`.
 *
 * A failed oracle read throws rather than resolving to zero, and the caller
 * declines the claim for that pass. Reporting zero would quietly reduce the
 * profit gate to an L2-execution-only check on exactly the chain where that
 * check is incomplete.
 */
export async function l1DataFee(cfg, pub, calldata) {
  if (cfg.l1FeeModel !== "op-stack") return 0n;

  const probe = calldata + "ff".repeat(ENVELOPE_BYTES);
  const fee = await pub.readContract({
    address: OP_GAS_ORACLE,
    abi: GAS_ORACLE_ABI,
    functionName: "getL1Fee",
    args: [probe],
  });

  // Hundredths, and floored at the oracle's own reading: the pad exists to buy
  // headroom, and a value under 1 would spend it the other way and quote the
  // claim as cheaper than the chain will actually charge.
  const pad = BigInt(Math.max(100, Math.round(cfg.l1FeePad * 100)));
  return (fee * pad) / 100n;
}
