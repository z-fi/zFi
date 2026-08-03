import { createPublicClient, fallback, http } from "viem";
import { mainnet } from "viem/chains";

import { config } from "./config.js";

const log = (...a) => console.log(new Date().toISOString(), ...a);

/**
 * Endpoints are NOT interchangeable, so they are pooled by role rather than
 * round-robined as one list. Probed 2026-08-03 against this workload:
 *
 *   endpoint                          getLogs range   eth_call / multicall
 *   mainnet.gateway.tenderly.co       unlimited       ok
 *   rpc.mevblocker.io                 unlimited       ok
 *   eth.drpc.org                      10_000          ok (rate-limits estimateGas)
 *   eth-pokt.nodies.app                    50         ok
 *   1rpc.io/eth                            50         ok
 *   eth.blockrazor.xyz                     25         ok
 *   eth-mainnet.public.blastapi.io         10         ok
 *   ethereum-rpc.publicnode.com       archive-gated   ok
 *   eth.rpc.blxrbdn.com               unavailable     ok
 *
 * Only the first two can serve the boot backfill. The rest are still useful:
 * steady-state polling advances ~1 block per tick, which fits inside even a
 * 10-block cap, and every one of them can serve state reads.
 */
const DEFAULT_LOG_SOURCES = [
  { url: "https://mainnet.gateway.tenderly.co", maxRange: null },
  { url: "https://rpc.mevblocker.io", maxRange: null },
  { url: "https://eth.drpc.org", maxRange: 10_000n },
  { url: "https://eth-pokt.nodies.app", maxRange: 50n },
  { url: "https://1rpc.io/eth", maxRange: 50n },
  { url: "https://eth.blockrazor.xyz", maxRange: 25n },
  { url: "https://eth-mainnet.public.blastapi.io", maxRange: 10n },
];

const DEFAULT_STATE_URLS = [
  "https://mainnet.gateway.tenderly.co",
  "https://rpc.mevblocker.io",
  "https://ethereum-rpc.publicnode.com",
  "https://eth.rpc.blxrbdn.com",
  "https://eth-mainnet.public.blastapi.io",
  "https://eth.drpc.org",
  "https://1rpc.io/eth",
];

const COOLDOWN_MS = 60_000;

function dedupe(urls) {
  const seen = new Set();
  return urls.filter((u) => u && !seen.has(u) && seen.add(u));
}

// -- state reads -------------------------------------------------------------

/**
 * eth_call / multicall / estimateGas / getBalance / receipts. viem's fallback
 * transport tries endpoints in order and moves to the next on transport error,
 * so index 0 stays the primary and the rest are pure backstop. Ranking is left
 * off deliberately: it would background-ping every endpoint on a timer, which
 * is real request volume for a bot that is idle most of the time.
 */
export function makeStateClient() {
  const urls = dedupe([config.rpcUrl, ...config.extraStateUrls, ...DEFAULT_STATE_URLS]);
  log(`state pool: ${urls.length} endpoint(s), primary ${urls[0]}`);
  return createPublicClient({
    chain: mainnet,
    transport: fallback(
      urls.map((u) => http(u, { timeout: 15_000, retryCount: 1 })),
      { retryCount: 0 },
    ),
  });
}

// -- log discovery -----------------------------------------------------------

function parseMaxRange(message) {
  const m = String(message).toLowerCase();
  if (!m.includes("block") && !m.includes("range")) return null;
  // "up to a 10 block range", "maximum allowed is 50 blocks",
  // "must not exceed 25 blocks", "limited to 0 - 50 blocks range",
  // "ranges over 10000 blocks are not supported"
  const nums = [...m.matchAll(/(\d[\d_]*)\s*(?:-\s*(\d+)\s*)?block/g)].map((x) =>
    BigInt((x[2] ?? x[1]).replace(/_/g, "")),
  );
  if (!nums.length) return null;
  return nums.reduce((a, b) => (b > a ? b : a));
}

/**
 * A range error must name blocks. Every real one does -- "up to a 10 block
 * range", "maximum allowed is 50 blocks", "must not exceed 25 blocks",
 * "ranges over 10000 blocks are not supported". Matching bare "exceed" or
 * "limit" instead swallows rate-limit messages and permanently shrinks a
 * perfectly capable endpoint's window because it was briefly throttled.
 */
function isRangeError(message) {
  const m = String(message).toLowerCase();
  if (isRateLimit(m)) return false;
  if (!m.includes("block")) return false;
  return (
    m.includes("range") ||
    m.includes("exceed") ||
    m.includes("limited to") ||
    m.includes("too large") ||
    m.includes("maximum") ||
    m.includes("max ")
  );
}

function isRateLimit(message) {
  const m = String(message).toLowerCase();
  return (
    m.includes("rate limit") ||
    m.includes("ratelimit") ||
    m.includes("too many requests") ||
    m.includes("429") ||
    m.includes("capacity") ||
    m.includes("throttl")
  );
}

function isCapabilityError(message) {
  const m = String(message).toLowerCase();
  return (
    m.includes("method not found") ||
    m.includes("method not available") ||
    m.includes("not supported") ||
    m.includes("archive request") ||
    m.includes("personal token") ||
    m.includes("api key") ||
    m.includes("unauthorized")
  );
}

/** Exposed for tests; not part of the runtime surface. */
export const __classify = { isRangeError, isRateLimit, isCapabilityError, parseMaxRange };

export class LogPool {
  constructor() {
    const configured = dedupe([config.rpcUrl, ...config.extraLogUrls]).map((url) => ({
      url,
      maxRange: null,
    }));
    const defaults = DEFAULT_LOG_SOURCES.filter(
      (d) => !configured.some((c) => c.url === d.url),
    ).map((d) => ({ ...d }));

    this.sources = [...configured, ...defaults].map((s) => ({
      ...s,
      cooldownUntil: 0,
      capable: true,
    }));
    log(`log pool: ${this.sources.length} endpoint(s), primary ${this.sources[0]?.url}`);
  }

  available() {
    const now = Date.now();
    return this.sources.filter((s) => s.capable && s.cooldownUntil <= now);
  }

  /** Largest window any currently-usable source will accept. */
  bestRange() {
    const usable = this.available();
    if (!usable.length) return config.logChunk;
    let best = 0n;
    for (const s of usable) {
      const r = s.maxRange ?? config.logChunk;
      if (r > best) best = r;
    }
    return best;
  }

  /**
   * Classify one failure. A source that reports a range limit is never
   * discarded -- its learned `maxRange` is recorded so later windows shrink to
   * fit, which is what keeps a 10-block-capped endpoint useful for
   * steady-state polling. Only a missing/gated `eth_getLogs` retires a source.
   */
  _demote(source, msg, attempted) {
    const learned = parseMaxRange(msg);
    if (isRangeError(msg)) {
      const halved = (source.maxRange ?? attempted) / 2n;
      source.maxRange = learned ?? (halved > 0n ? halved : 1n);
      log(`log source ${source.url}: max range now ${source.maxRange} (${msg.slice(0, 80)})`);
    } else if (isRateLimit(msg)) {
      // Throttling says nothing about capability -- rest the source, keep its range.
      source.cooldownUntil = Date.now() + COOLDOWN_MS;
      log(`log source ${source.url}: rate limited, cooling down 60s (${msg.slice(0, 80)})`);
    } else if (isCapabilityError(msg)) {
      source.capable = false;
      log(`log source ${source.url}: cannot serve getLogs, dropped (${msg.slice(0, 80)})`);
    } else {
      source.cooldownUntil = Date.now() + COOLDOWN_MS;
      log(`log source ${source.url}: error, cooling down 60s (${msg.slice(0, 80)})`);
    }
  }

  clientFor(url) {
    if (!this._clients) this._clients = new Map();
    if (!this._clients.has(url)) {
      this._clients.set(
        url,
        createPublicClient({
          chain: mainnet,
          transport: http(url, { timeout: 20_000, retryCount: 0 }),
        }),
      );
    }
    return this._clients.get(url);
  }

  /**
   * Scan [from, to] in windows, rotating sources per window.
   *
   * `onWindow(logs, windowEnd)` fires after each window succeeds, and is the
   * only way results escape. Accumulating internally and returning at the end
   * would be wrong: a throw partway through would discard logs the caller had
   * already been told were covered, silently losing tips. Consuming per window
   * keeps the caller's high-water mark and its data in lockstep.
   */
  async scan(params, from, to, onWindow) {
    let cursor = from;
    // A cold backfill is tens of seconds of silence otherwise, which reads as a
    // hang. Only announced when the span is large enough to actually take time.
    const noisy = to - from > 50_000n;
    let nextReport = Date.now() + 10_000;
    while (cursor <= to) {
      const window = this.bestRange();
      const chunk = window < config.logChunk ? window : config.logChunk;
      let end = cursor + chunk - 1n;
      if (end > to) end = to;

      let served = false;
      let lastErr;
      for (const source of this.available()) {
        const cap = source.maxRange;
        let windowEnd = end;
        if (cap !== null && windowEnd - cursor + 1n > cap) windowEnd = cursor + cap - 1n;
        if (windowEnd > to) windowEnd = to;
        try {
          const logs = await this.clientFor(source.url).getContractEvents({
            ...params,
            fromBlock: cursor,
            toBlock: windowEnd,
          });
          onWindow(logs, windowEnd);
          cursor = windowEnd + 1n;
          served = true;
          if (noisy && Date.now() >= nextReport) {
            const pct = Number(((windowEnd - from) * 100n) / (to - from));
            log(`  backfill ${pct}% (block ${windowEnd} of ${to})`);
            nextReport = Date.now() + 10_000;
          }
          break;
        } catch (err) {
          const msg = err?.details || err?.shortMessage || err?.message || String(err);
          lastErr = msg;
          this._demote(source, msg, windowEnd - cursor + 1n);
        }
      }

      if (!served) throw new Error(`no log source could serve ${cursor}-${end}: ${lastErr}`);
    }
  }
}
