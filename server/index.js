// Combined Node service that hosts BOTH former Cloudflare Workers behind one
// HTTP server via @hono/node-server. This replaces:
//   - zfi-pin.rosscampbell9.workers.dev  (IPFS pin / proxy-metadata / db / swap-key proxies)
//   - api.zfi.wei.is                     (zQuoter on-chain DEX aggregator)
//
// The two Worker handlers are ported verbatim (they already take an `env`
// object and use only Web-standard APIs). Dispatch is by pathname — the two
// route sets do not collide.
import { serve } from '@hono/node-server';
import { webcrypto } from 'node:crypto';
import pin from './pin.js';
import quote from './quote.js';

// OKX / Bitget request signing uses crypto.subtle (Web Crypto). Guarantee the
// global exists across every supported Node version.
if (!globalThis.crypto) globalThis.crypto = webcrypto;

// Paths owned by the quote service; everything else falls through to pin.
const QUOTE_PATHS = new Set(['/', '/health', '/quote', '/simulate']);

async function handler(request) {
  let pathname;
  try {
    pathname = new URL(request.url).pathname;
  } catch {
    return new Response('bad request', { status: 400 });
  }
  const mod = QUOTE_PATHS.has(pathname) ? quote : pin;
  // Cloudflare Workers receive (request, env); we pass process.env.
  return mod.fetch(request, process.env);
}

const port = Number(process.env.PORT) || 8080;
serve({ fetch: handler, port }, (info) => {
  console.log(`zfi-api listening on :${info.port}`);
});
