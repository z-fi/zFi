// The env-resolution rules are the part of the multichain layer that a mistake
// makes silent: a mainnet gas number leaking onto Base does not crash, it just
// mismatches the fee ceiling by four orders of magnitude, and a send endpoint
// leaking onto an L2 points claims at a relay that chain has never heard of.
// These pin both directions.
import assert from "node:assert/strict";
import test from "node:test";
import { parseGwei } from "viem";

import { CHAINS, SUPPORTED_CHAIN_IDS } from "../src/chains.js";
import { loadChainConfig, resolveChainIds } from "../src/config.js";

test("CHAINS defaults to mainnet alone, so an unset var changes nothing", () => {
  assert.deepEqual(resolveChainIds({}), [1]);
  assert.deepEqual(resolveChainIds({ CHAINS: "" }), [1]);
  assert.deepEqual(resolveChainIds({ CHAINS: "   " }), [1]);
});

test("CHAINS parses, trims and de-duplicates", () => {
  assert.deepEqual(resolveChainIds({ CHAINS: "1,8453,4663" }), [1, 8453, 4663]);
  assert.deepEqual(resolveChainIds({ CHAINS: " 8453 , 1 " }), [8453, 1]);
  assert.deepEqual(resolveChainIds({ CHAINS: "1,1,8453" }), [1, 8453]);
});

test("an unsupported chain id fails at boot, not at first use", () => {
  assert.throws(() => resolveChainIds({ CHAINS: "1,10" }), /unsupported chain 10/);
  assert.throws(() => resolveChainIds({ CHAINS: "mainnet" }), /unsupported chain/);
});

test("every supported chain resolves with no env at all", () => {
  for (const id of SUPPORTED_CHAIN_IDS) {
    const cfg = loadChainConfig(id, {});
    assert.equal(cfg.chainId, id);
    assert.equal(cfg.chain.id, id);
    assert.equal(cfg.slow, "0x000000006513b7821171c8447ec7ecdfa3b956fd");
    assert.equal(cfg.gate, "0x76d1956b3be7c0d09a16de00dce9b6f54ef28d34");
    assert.equal(cfg.startBlock, CHAINS[id].startBlock);
    assert.equal(cfg.sendRpcUrl, CHAINS[id].sendRpcUrl);
    assert.ok(cfg.startBlock > 0n, "a start block is pinned per chain");
    assert.ok(cfg.defaultStateUrls.length > 0);
    assert.ok(cfg.defaultLogSources.length > 0);
    assert.ok(cfg.maxFeeCapGwei > 0n);
  }
});

test("mainnet's resolved defaults are unchanged from the single-chain keeper", () => {
  const cfg = loadChainConfig(1, {});
  assert.equal(cfg.startBlock, 25913818n);
  assert.equal(cfg.sendRpcUrl, "https://rpc.flashbots.net/fast");
  assert.equal(cfg.maxFeeCapGwei, parseGwei("50"));
  assert.equal(cfg.priorityFee, parseGwei("0.05"));
  assert.equal(cfg.marginMultiple, 1.25);
  assert.equal(cfg.maxBatch, 10);
  assert.equal(cfg.logChunk, 250000n);
  assert.equal(cfg.l1FeeModel, "none");
  assert.equal(cfg.l1FeePad, 1);
});

test("the existing deployment's unsuffixed vars still land on mainnet", () => {
  const env = {
    SEND_RPC_URL: "https://rpc.flashbots.net/fast",
    MARGIN_MULTIPLE: "1.25",
    PRIORITY_GWEI: "0.05",
    MAX_FEE_GWEI: "50",
    MAX_BATCH: "10",
    RPC_URL: "https://example.invalid/primary",
  };
  const cfg = loadChainConfig(1, env);
  assert.equal(cfg.sendRpcUrl, "https://rpc.flashbots.net/fast");
  assert.equal(cfg.maxFeeCapGwei, parseGwei("50"));
  assert.equal(cfg.priorityFee, parseGwei("0.05"));
  assert.equal(cfg.rpcUrl, "https://example.invalid/primary");
});

test("chain-specific vars do not leak from mainnet onto an L2", () => {
  const env = {
    SEND_RPC_URL: "https://rpc.flashbots.net/fast",
    PRIORITY_GWEI: "0.05",
    MAX_FEE_GWEI: "50",
    START_BLOCK: "25913818",
    RPC_URL: "https://example.invalid/mainnet-only",
  };
  for (const id of [8453, 4663]) {
    const cfg = loadChainConfig(id, env);
    assert.notEqual(cfg.sendRpcUrl, "https://rpc.flashbots.net/fast");
    assert.equal(cfg.sendRpcUrl, CHAINS[id].sendRpcUrl);
    assert.equal(cfg.maxFeeCapGwei, parseGwei(CHAINS[id].maxFeeGwei));
    assert.ok(cfg.maxFeeCapGwei < parseGwei("50"), "an L2 ceiling is far under mainnet's");
    assert.equal(cfg.startBlock, CHAINS[id].startBlock);
    assert.equal(cfg.rpcUrl, "");
  }
});

test("suffixed vars override per chain", () => {
  const env = {
    MAX_FEE_GWEI: "50",
    MAX_FEE_GWEI_8453: "0.2",
    SEND_RPC_URL_8453: "https://example.invalid/base-send",
    START_BLOCK_4663: "60000000",
    PRIORITY_GWEI_4663: "0.5",
    RPC_URLS_8453: "https://a.invalid, https://b.invalid",
    RPC_URLS_LOGS_4663: "https://logs.invalid",
  };
  const base = loadChainConfig(8453, env);
  assert.equal(base.maxFeeCapGwei, parseGwei("0.2"));
  assert.equal(base.sendRpcUrl, "https://example.invalid/base-send");
  assert.deepEqual(base.extraStateUrls, ["https://a.invalid", "https://b.invalid"]);
  assert.deepEqual(base.extraLogUrls, ["https://a.invalid", "https://b.invalid"]);

  const rh = loadChainConfig(4663, env);
  assert.equal(rh.startBlock, 60000000n);
  assert.equal(rh.priorityFee, parseGwei("0.5"));
  assert.deepEqual(rh.extraLogUrls, ["https://logs.invalid"]);
  assert.deepEqual(rh.extraStateUrls, []);

  // mainnet keeps the unsuffixed value the L2 overrode
  assert.equal(loadChainConfig(1, env).maxFeeCapGwei, parseGwei("50"));
});

test("chain-agnostic policy vars apply everywhere and still take a suffix", () => {
  const env = { MARGIN_MULTIPLE: "1.5", MAX_BATCH: "4", MARGIN_MULTIPLE_4663: "2" };
  assert.equal(loadChainConfig(1, env).marginMultiple, 1.5);
  assert.equal(loadChainConfig(8453, env).marginMultiple, 1.5);
  assert.equal(loadChainConfig(4663, env).marginMultiple, 2);
  for (const id of SUPPORTED_CHAIN_IDS) assert.equal(loadChainConfig(id, env).maxBatch, 4);
});

test("the L1 data component is charged where the estimate omits it", () => {
  // Base bills L2 execution and L1 posting separately, so the oracle reading
  // has to be added on and is padded for L1 base-fee movement. Nitro folds the
  // posting cost into the gas estimate, so a second reading would double it.
  assert.equal(loadChainConfig(8453, {}).l1FeeModel, "op-stack");
  assert.equal(loadChainConfig(8453, {}).l1FeePad, 2);
  assert.equal(loadChainConfig(4663, {}).l1FeeModel, "nitro");
  assert.equal(loadChainConfig(4663, {}).l1FeePad, 1);
  assert.equal(loadChainConfig(1, {}).l1FeeModel, "none");
  assert.equal(loadChainConfig(8453, { L1_FEE_PAD_8453: "3" }).l1FeePad, 3);
});

test("labels are unique, so an interleaved log stream stays readable", () => {
  const labels = SUPPORTED_CHAIN_IDS.map((id) => CHAINS[id].label);
  assert.equal(new Set(labels).size, labels.length);
});
