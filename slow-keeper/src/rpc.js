import { createPublicClient, fallback, http } from "viem";

import {
  isCapabilityError,
  isRangeError,
  isRateLimit,
  parseMaxRange,
} from "./classify.js";
import { chainLogger } from "./log.js";

/**
 * Never log an endpoint verbatim. Provider URLs carry the API key in the path
 * or query (`.../v2/<key>`, `?apikey=`), and anything printed here lands in the
 * host's log store and in any transcript pasted for debugging. Host plus a
 * short fingerprint is enough to tell endpoints apart without disclosing one.
 */
export function redact(url) {
  try {
    const u = new URL(url);
    const secretish = u.pathname.replace(/^\/+/, "") + u.search;
    if (!secretish) return u.host;
    // Keep well-known public path suffixes readable; they are not credentials.
    if (/^(public|eth|base|v1\/rpc\/public|public\/mainnet|public\/base|fast|noreverts)$/i.test(secretish)) {
      return `${u.host}/${secretish}`;
    }
    return `${u.host}/…${secretish.slice(-4)}`;
  } catch {
    return "<malformed url>";
  }
}

/**
 * Endpoints are NOT interchangeable, so they are pooled by role rather than
 * round-robined as one list, and each chain brings its own pools -- see
 * `chains.js` for the per-chain tables and what each was probed to do. Every
 * default entry is keyless: no account, no quota to blow through, nothing to
 * pay. Only the wide-range tier can serve a cold backfill; the narrow ones
 * still carry steady state, because a pass advances far fewer blocks than even
 * a 10-block cap.
 */

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
export function makeStateClient(cfg) {
  const log = chainLogger(cfg.label);
  const urls = dedupe([cfg.rpcUrl, ...cfg.extraStateUrls, ...cfg.defaultStateUrls]);
  log(`state pool: ${urls.length} endpoint(s), primary ${redact(urls[0])}`);
  return createPublicClient({
    chain: cfg.chain,
    transport: fallback(
      urls.map((u) => http(u, { timeout: 15_000, retryCount: 1 })),
      { retryCount: 0 },
    ),
  });
}

// -- log discovery -----------------------------------------------------------

export class LogPool {
  constructor(cfg) {
    this.cfg = cfg;
    this.log = chainLogger(cfg.label);

    const configured = dedupe([cfg.rpcUrl, ...cfg.extraLogUrls]).map((url) => ({
      url,
      maxRange: null,
    }));
    const defaults = cfg.defaultLogSources.filter(
      (d) => !configured.some((c) => c.url === d.url),
    ).map((d) => ({ ...d }));

    this.sources = [...configured, ...defaults].map((s) => ({
      ...s,
      cooldownUntil: 0,
      capable: true,
    }));
    this.log(`log pool: ${this.sources.length} endpoint(s), primary ${redact(this.sources[0]?.url ?? "")}`);
  }

  available() {
    const now = Date.now();
    return this.sources.filter((s) => s.capable && s.cooldownUntil <= now);
  }

  /** Largest window any currently-usable source will accept. */
  bestRange() {
    const usable = this.available();
    if (!usable.length) return this.cfg.logChunk;
    let best = 0n;
    for (const s of usable) {
      const r = s.maxRange ?? this.cfg.logChunk;
      if (r > best) best = r;
    }
    return best;
  }

  /**
   * Classify one failure. A source that reports a range limit is never
   * discarded -- its learned `maxRange` is recorded so later windows shrink to
   * fit, which is what keeps a 10-block-capped endpoint useful for
   * steady-state polling. Only a missing/gated `eth_getLogs` retires a source.
   *
   * The learned figure is only adopted when it is strictly narrower than the
   * window that was just refused. Endpoints quote a limit they do not honour --
   * drpc rejects a 9,998-block window with "ranges over 10000 blocks are not
   * supported" -- and taking that number at face value would leave the source
   * retrying the same width forever. Halving instead walks it down to whatever
   * the endpoint really serves.
   */
  _demote(source, msg, attempted) {
    const quoted = parseMaxRange(msg);
    const learned = quoted !== null && quoted < attempted ? quoted : null;
    if (isRangeError(msg)) {
      const halved = (source.maxRange ?? attempted) / 2n;
      source.maxRange = learned ?? (halved > 0n ? halved : 1n);
      this.log(`log source ${redact(source.url)}: max range now ${source.maxRange} (${msg.slice(0, 80)})`);
    } else if (isRateLimit(msg)) {
      // Throttling says nothing about capability -- rest the source, keep its range.
      source.cooldownUntil = Date.now() + COOLDOWN_MS;
      this.log(`log source ${redact(source.url)}: rate limited, cooling down 60s (${msg.slice(0, 80)})`);
    } else if (isCapabilityError(msg)) {
      source.capable = false;
      this.log(`log source ${redact(source.url)}: cannot serve getLogs, dropped (${msg.slice(0, 80)})`);
    } else {
      source.cooldownUntil = Date.now() + COOLDOWN_MS;
      this.log(`log source ${redact(source.url)}: error, cooling down 60s (${msg.slice(0, 80)})`);
    }
  }

  clientFor(url) {
    if (!this._clients) this._clients = new Map();
    if (!this._clients.has(url)) {
      this._clients.set(
        url,
        createPublicClient({
          chain: this.cfg.chain,
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
      const chunk = window < this.cfg.logChunk ? window : this.cfg.logChunk;
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
            this.log(`  backfill ${pct}% (block ${windowEnd} of ${to})`);
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
