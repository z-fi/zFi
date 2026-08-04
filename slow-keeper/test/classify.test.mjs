// Classifier checks against the exact error strings the 2026-08-03 probe
// returned from real endpoints, plus the rate-limit shapes that must NOT be
// mistaken for range limits.
import assert from "node:assert/strict";
import test from "node:test";

import {
  isCapabilityError,
  isRangeError,
  isRateLimit,
  parseMaxRange,
} from "../src/classify.js";

test("real range errors are recognised and their limit parsed", () => {
  const cases = [
    ["You can make eth_getLogs requests with up to a 10 block range.", 10n],
    ["ranges over 10000 blocks are not supported on free plan", 10000n],
    ["Block range too large: maximum allowed is 50 blocks on your plan", 50n],
    ["eth_getLogs is limited to 0 - 50 blocks range", 50n],
    ["log query range must not exceed 25 blocks", 25n],
  ];
  for (const [msg, expected] of cases) {
    assert.equal(isRangeError(msg), true, `should be a range error: ${msg}`);
    assert.equal(parseMaxRange(msg), expected, `wrong limit parsed from: ${msg}`);
  }
});

test("rate limits are never treated as range limits", () => {
  const cases = [
    "You reached Public endpoint rate limit, please upgrade to paid plan",
    "429 Too Many Requests",
    "request capacity exceeded for this block range window",
    "throttled: slow down",
  ];
  for (const msg of cases) {
    assert.equal(isRateLimit(msg), true, `should be rate limit: ${msg}`);
    assert.equal(isRangeError(msg), false, `must not shrink range for: ${msg}`);
  }
});

test("capability failures retire the source", () => {
  const cases = [
    "Method not found",
    "method not available",
    "Archive requests require a personal token. Get one at: https://...",
    "Unauthorized: You must authenticate your request with an API key",
  ];
  for (const msg of cases) {
    assert.equal(isCapabilityError(msg), true, `should be capability error: ${msg}`);
  }
});

test("transport noise is neither range nor capability", () => {
  for (const msg of ["fetch failed", "socket hang up", "timeout"]) {
    assert.equal(isRangeError(msg), false);
    assert.equal(isCapabilityError(msg), false);
    assert.equal(isRateLimit(msg), false);
  }
});
