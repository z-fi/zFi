// Pure error-message classification for RPC endpoints. Deliberately free of
// config/network imports so it can be tested on its own.

/**
 * Extract the block-range limit an endpoint just told us about.
 * Handles "up to a 10 block range", "maximum allowed is 50 blocks",
 * "must not exceed 25 blocks", "limited to 0 - 50 blocks range",
 * "ranges over 10000 blocks are not supported".
 */
export function parseMaxRange(message) {
  const m = String(message).toLowerCase();
  if (!m.includes("block") && !m.includes("range")) return null;
  const nums = [...m.matchAll(/(\d[\d_]*)\s*(?:-\s*(\d+)\s*)?block/g)].map((x) =>
    BigInt((x[2] ?? x[1]).replace(/_/g, "")),
  );
  if (!nums.length) return null;
  return nums.reduce((a, b) => (b > a ? b : a));
}

export function isRateLimit(message) {
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

/**
 * A range error must name blocks. Every real one does. Matching bare "exceed"
 * or "limit" instead swallows rate-limit messages and permanently shrinks a
 * perfectly capable endpoint's window because it was briefly throttled.
 */
export function isRangeError(message) {
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

/** Endpoint cannot serve eth_getLogs at all, or needs credentials we lack. */
export function isCapabilityError(message) {
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
