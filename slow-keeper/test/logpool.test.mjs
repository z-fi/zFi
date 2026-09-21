// The log pool is per chain now, and the chains disagree about what a window
// may be: mainnet has three sources that serve the whole history in one
// request, Base's widest real window is 2,000 blocks, and Robinhood has exactly
// one usable source. These pin the parts of that which a wrong answer makes
// quiet rather than loud -- a pool that never converges on a source's real
// limit just retries the same refused width until the backfill gives up.
import assert from "node:assert/strict";
import test from "node:test";

import { CHAINS } from "../src/chains.js";
import { loadChainConfig } from "../src/config.js";
import { LogPool } from "../src/rpc.js";

function poolFor(chainId, env = {}) {
  return new LogPool(loadChainConfig(chainId, env));
}

test("each chain's pool is built from that chain's own endpoints", () => {
  for (const id of [1, 8453, 4663]) {
    const pool = poolFor(id);
    assert.equal(pool.sources.length, CHAINS[id].logSources.length);
    assert.deepEqual(
      pool.sources.map((s) => s.url),
      CHAINS[id].logSources.map((s) => s.url),
    );
  }
});

test("a configured endpoint goes in front of the built-in defaults", () => {
  const pool = poolFor(8453, { RPC_URL_8453: "https://example.invalid/base" });
  assert.equal(pool.sources[0].url, "https://example.invalid/base");
  assert.equal(pool.sources[0].maxRange, null, "an operator's own endpoint is assumed unlimited");
  assert.equal(pool.sources.length, CHAINS[8453].logSources.length + 1);
});

test("the widest window offered is the chain's, not mainnet's", () => {
  assert.equal(poolFor(1).bestRange(), loadChainConfig(1, {}).logChunk);
  assert.equal(poolFor(8453).bestRange(), 2_000n);
  assert.equal(poolFor(4663).bestRange(), loadChainConfig(4663, {}).logChunk);
});

test("a quoted limit wider than the refused window walks the source down", () => {
  // drpc refuses a 9,998-block window with "ranges over 10000 blocks are not
  // supported". Adopting 10,000 would retry the same width indefinitely.
  const pool = poolFor(8453);
  const source = { url: "https://example.invalid", maxRange: 10_000n, cooldownUntil: 0, capable: true };
  pool._demote(source, "ranges over 10000 blocks are not supported on free plan", 9_998n);
  assert.ok(source.maxRange < 9_998n, "must narrow below what was just refused");
  const first = source.maxRange;
  pool._demote(source, "ranges over 10000 blocks are not supported on free plan", first);
  assert.ok(source.maxRange < first, "and keep narrowing on each refusal");
});

test("a quoted limit narrower than the refused window is taken at its word", () => {
  const pool = poolFor(8453);
  const source = { url: "https://example.invalid", maxRange: 2_000n, cooldownUntil: 0, capable: true };
  pool._demote(source, "You can make eth_getLogs requests with up to a 10 block range.", 2_000n);
  assert.equal(source.maxRange, 10n);
});

test("throttling rests a source without shrinking its window", () => {
  const pool = poolFor(8453);
  const source = { url: "https://example.invalid", maxRange: 2_000n, cooldownUntil: 0, capable: true };
  pool._demote(source, "429 Too Many Requests", 2_000n);
  assert.equal(source.maxRange, 2_000n);
  assert.ok(source.cooldownUntil > Date.now());
  assert.equal(source.capable, true);
});

test("a gated archive endpoint is retired rather than rested", () => {
  const pool = poolFor(4663);
  const source = { url: "https://example.invalid", maxRange: null, cooldownUntil: 0, capable: true };
  pool._demote(source, "Archive requests require a personal token. Get one at: https://…", 250_000n);
  assert.equal(source.capable, false);
  assert.equal(pool.available().some((s) => s.url === "https://example.invalid"), false);
});
