// The profit gate is only as honest as the cost it compares against, and on an
// L2 the cost has two halves. These pin which chain pays which half where, so a
// future chain cannot be added in a way that silently prices L1 posting at zero
// or charges for it twice.
import assert from "node:assert/strict";
import test from "node:test";

import { loadChainConfig } from "../src/config.js";
import { l1DataFee } from "../src/l1fee.js";

/** Records what it was asked and answers a fixed fee. */
function oracleStub(fee) {
  const calls = [];
  return {
    calls,
    async readContract(args) {
      calls.push(args);
      return fee;
    },
  };
}

test("mainnet pays no data fee and does not go looking for one", async () => {
  const pub = oracleStub(999n);
  assert.equal(await l1DataFee(loadChainConfig(1, {}), pub, "0xdeadbeef"), 0n);
  assert.equal(pub.calls.length, 0);
});

test("Nitro's estimate already contains the posting cost, so nothing is added", async () => {
  // A plain value send estimates at 21225 rather than 21000 on Robinhood: the
  // 225 extra units are the batch-posting cost. Reading the oracle as well
  // would charge it a second time and decline profitable claims.
  const pub = oracleStub(999n);
  assert.equal(await l1DataFee(loadChainConfig(4663, {}), pub, "0xdeadbeef"), 0n);
  assert.equal(pub.calls.length, 0);
});

test("OP-stack reads the oracle and applies the headroom multiple", async () => {
  const pub = oracleStub(1_000_000n);
  const cfg = loadChainConfig(8453, {});
  assert.equal(cfg.l1FeePad, 2);
  assert.equal(await l1DataFee(cfg, pub, "0xdeadbeef"), 2_000_000n);

  assert.equal(pub.calls.length, 1);
  const [call] = pub.calls;
  assert.equal(call.address, "0x420000000000000000000000000000000000000F");
  assert.equal(call.functionName, "getL1Fee");
  // The oracle prices the bytes it is handed, and a signed claim carries an
  // envelope the calldata does not: nonce, both fee fields, gas limit,
  // destination, chain id and a 65-byte signature.
  const priced = call.args[0];
  assert.ok(priced.startsWith("0xdeadbeef"));
  assert.ok((priced.length - 2) / 2 >= 4 + 160, "the envelope is priced too");
  assert.ok(/^(0x)(?:[0-9a-f]{2})+$/.test(priced));
});

test("the headroom multiple is tunable and never falls below 1", async () => {
  const pub = oracleStub(1_000_000n);
  assert.equal(await l1DataFee(loadChainConfig(8453, { L1_FEE_PAD: "1.5" }), pub, "0x"), 1_500_000n);
  assert.equal(await l1DataFee(loadChainConfig(8453, { L1_FEE_PAD: "1" }), pub, "0x"), 1_000_000n);
  assert.equal(await l1DataFee(loadChainConfig(8453, { L1_FEE_PAD: "0" }), pub, "0x"), 1_000_000n);
});

test("an unreadable oracle throws rather than reporting the fee as zero", async () => {
  const pub = {
    async readContract() {
      throw new Error("fetch failed");
    },
  };
  await assert.rejects(() => l1DataFee(loadChainConfig(8453, {}), pub, "0xdeadbeef"), /fetch failed/);
});
