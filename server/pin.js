// IPFS pinning proxy for Filebase + 0x/1inch/OKX swap API proxies + metadata proxy.
// Ported from a Cloudflare Worker to run under Node (see ./index.js). Uses only
// Web-standard APIs (fetch, FormData, crypto.subtle), so the handler is unchanged.
// Secrets are read from process.env: FILEBASE_KEY / FILEBASE_SECRET / FILEBASE_BUCKET
// / OX_API_KEY / INCH_API_KEY / OKX_API_KEY / OKX_SECRET_KEY / OKX_PASSPHRASE
// / ENSO_API_KEY.

const FILEBASE_S3 = 's3.filebase.com';
const FILEBASE_REGION = 'us-east-1';
const OX_API = 'https://api.0x.org';
const INCH_API = 'https://api.1inch.dev';
const OKX_API = 'https://web3.okx.com';
const ENSO_API = 'https://api.enso.build';
const MAX_IMAGE = 5 * 1024 * 1024; // 5MB
const MAX_JSON = 64 * 1024; // 64KB

// Base allowlist plus any origins supplied via the ALLOWED_ORIGINS env var
// (comma-separated) — e.g. a *.onrender.com preview URL while testing before
// the zfi.wei.is DNS cutover. `process` is guarded so this stays portable.
const ALLOWED_ORIGINS = [
  'https://zfi.wei.is', 'http://localhost:8080', 'http://localhost:3000',
  ...(globalThis.process?.env?.ALLOWED_ORIGINS?.split(',').map((s) => s.trim()).filter(Boolean) || []),
];

// A CONTRACT-SERVED PAGE HAS NO FIXED HOSTNAME. zSwap is served from its own
// address, so its origin is `https://0x<address>.<gateway>` - a different host
// for every version, decided by a CREATE2 address nobody knows until the deploy
// happens. An exact allowlist cannot name it in advance, and pinning one after
// the fact would mean editing this service every time a version ships.
//
// So the gateway SUFFIXES are allowed, and only for a host that is an address
// subdomain of one. What that widens is small and worth being honest about:
// `Origin` is enforced by browsers and set freely by anything else, so this
// list never stopped a determined caller - `curl -H "Origin: https://zfi.wei.is"`
// has always worked. It stops other people's SITES from spending these keys,
// and that property is unchanged: an attacker's page still cannot forge an
// origin, and still cannot get an address subdomain on these gateways without
// deploying a contract that serves their own page, at which point they are
// paying for their own bytes.
const ORIGIN_SUFFIXES = ['.w4eth.io', '.w3link.io', '.eth.limo', '.wei.limo', '.wei.is'];
const ADDR_HOST = /^0x[0-9a-fA-F]{40}(\.\d+)?\./;

function originAllowed(origin) {
  if (ALLOWED_ORIGINS.includes(origin)) return true;
  let u;
  try { u = new URL(origin); } catch { return false; }
  if (u.protocol !== 'https:') return false;
  if (!ORIGIN_SUFFIXES.some((sfx) => u.hostname.endsWith(sfx))) return false;
  // Only an address-shaped subdomain, so a suffix match cannot hand the keys to
  // an unrelated host that merely lives on the same gateway.
  return ADDR_HOST.test(u.hostname) || u.hostname === 'zswap.wei.limo'
    || u.hostname === 'new.zswap.wei.limo';
}

function cors(request) {
  const origin = request.headers.get('Origin') || '';
  return {
    'Access-Control-Allow-Origin': originAllowed(origin) ? origin : '',
    'Access-Control-Allow-Methods': 'GET, POST, PATCH, DELETE, OPTIONS',
    'Access-Control-Allow-Headers': 'Content-Type, Prefer',
  };
}

function json(request, data, status = 200) {
  return new Response(JSON.stringify(data), { status, headers: { ...cors(request), 'Content-Type': 'application/json' } });
}

// --- Filebase (S3-compatible IPFS pinning) -------------------------------
// Uploading an object to an IPFS-enabled Filebase bucket pins it and returns the
// CID in the `x-amz-meta-cid` response header. Auth is AWS SigV4, implemented
// here with crypto.subtle so this file stays Worker/Node portable.

const _enc = new TextEncoder();
const _hex = (buf) => [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, '0')).join('');

async function sha256Hex(data) {
  return _hex(await crypto.subtle.digest('SHA-256', typeof data === 'string' ? _enc.encode(data) : data));
}

async function hmac(key, data) {
  const k = await crypto.subtle.importKey(
    'raw', typeof key === 'string' ? _enc.encode(key) : key,
    { name: 'HMAC', hash: 'SHA-256' }, false, ['sign'],
  );
  return new Uint8Array(await crypto.subtle.sign('HMAC', k, _enc.encode(data)));
}

// PUT `body` into the Filebase bucket under `key`; resolves to the pinned CID.
async function filebasePut(env, key, body, contentType) {
  const bucket = env.FILEBASE_BUCKET || 'zfi';
  const amzDate = new Date().toISOString().replace(/[:-]|\.\d{3}/g, ''); // YYYYMMDDTHHMMSSZ
  const date = amzDate.slice(0, 8);
  const payloadHash = await sha256Hex(body);
  const canonicalUri = `/${bucket}/${key.split('/').map(encodeURIComponent).join('/')}`;
  const signedHeaders = 'content-type;host;x-amz-content-sha256;x-amz-date';
  const canonicalRequest = [
    'PUT', canonicalUri, '',
    `content-type:${contentType}`,
    `host:${FILEBASE_S3}`,
    `x-amz-content-sha256:${payloadHash}`,
    `x-amz-date:${amzDate}`,
    '', signedHeaders, payloadHash,
  ].join('\n');

  const scope = `${date}/${FILEBASE_REGION}/s3/aws4_request`;
  const stringToSign = ['AWS4-HMAC-SHA256', amzDate, scope, await sha256Hex(canonicalRequest)].join('\n');

  let signingKey = await hmac(`AWS4${env.FILEBASE_SECRET}`, date);
  signingKey = await hmac(signingKey, FILEBASE_REGION);
  signingKey = await hmac(signingKey, 's3');
  signingKey = await hmac(signingKey, 'aws4_request');
  const signature = _hex(await hmac(signingKey, stringToSign));

  const res = await fetch(`https://${FILEBASE_S3}${canonicalUri}`, {
    method: 'PUT',
    headers: {
      'Content-Type': contentType,
      'x-amz-content-sha256': payloadHash,
      'x-amz-date': amzDate,
      Authorization: `AWS4-HMAC-SHA256 Credential=${env.FILEBASE_KEY}/${scope}, SignedHeaders=${signedHeaders}, Signature=${signature}`,
    },
    body,
  });
  if (!res.ok) throw new Error(`filebase ${res.status}: ${(await res.text()).slice(0, 200)}`);

  const cid = res.headers.get('x-amz-meta-cid');
  if (!cid) throw new Error('no CID returned (is the bucket IPFS-enabled?)');
  return cid;
}

// ---------------------------------------------------------------------------
// Upstream cache for the aggregator proxies.
//
// WHY THIS IS WORTH MORE HERE THAN IN THE PAGE. zSwap asks every lane to pay
// its adapter's executor, so `taker` is a constant rather than the user's
// address - which means two people quoting the same pair for the same amount
// send a byte-identical upstream request. A cache in the page can only ever
// help that one person; this one is shared by everybody, and by the dapp,
// which spends the same API keys.
//
// The TTL is deliberately short. These responses carry executable calldata
// with a deadline, and the point is to collapse a burst of identical asks,
// not to serve an old route. In-flight dedup matters as much as the TTL: a
// dozen people typing at once should cost one upstream call, not a dozen.
//
// Failures are never cached. A 429 or a 500 held for even ten seconds turns
// one upstream hiccup into a lane that looks dead to everyone.
const UP_TTL = 10_000;
const UP_MAX = 400;
const _up = new Map();
const _upWait = new Map();

async function cachedUpstream(key, go) {
  const hit = _up.get(key);
  if (hit && Date.now() - hit.t < UP_TTL) {
    _up.delete(key);
    _up.set(key, hit); // LRU touch
    return { body: hit.body, status: 200, cached: true };
  }
  const inflight = _upWait.get(key);
  if (inflight) return { ...(await inflight), cached: true };

  const p = (async () => {
    const res = await go();
    const body = Buffer.from(await res.arrayBuffer());
    // Only successes are held. A cached 429 turns one upstream hiccup into a
    // lane that looks dead to every caller for the length of the TTL.
    if (res.ok) {
      _up.set(key, { body, t: Date.now() });
      if (_up.size > UP_MAX) _up.delete(_up.keys().next().value);
    }
    return { body, status: res.status };
  })();
  _upWait.set(key, p);
  try {
    return await p;
  } finally {
    _upWait.delete(key);
  }
}

export default {
  async fetch(request, env) {
    if (request.method === 'OPTIONS') return new Response(null, { headers: cors(request) });

    // Reject requests from non-allowlisted origins (CORS is browser-only; this blocks curl/scripts too)
    const origin = request.headers.get('Origin') || '';
    if (!originAllowed(origin)) {
      return new Response(JSON.stringify({ error: 'forbidden' }), {
        status: 403,
        headers: { 'Content-Type': 'application/json' },
      });
    }

    const url = new URL(request.url);

    // GET /0x/*  — proxy to 0x Swap API (hides API key, bypasses CORS)
    if (url.pathname.startsWith('/0x/')) {
      if (request.method !== 'GET') return json(request, { error: 'GET only' }, 405);
      const oxPath = url.pathname.slice(3); // strip "/0x" prefix
      if (!oxPath.startsWith('/swap/allowance-holder/')) return json(request, { error: 'forbidden path' }, 403);
      const oxUrl = `${OX_API}${oxPath}?${url.searchParams}`;
      const r = await cachedUpstream(`0x|${oxUrl}`, () => fetch(oxUrl, {
        headers: { '0x-api-key': env.OX_API_KEY, '0x-version': 'v2' },
      }));
      return new Response(r.body, {
        status: r.status,
        headers: { ...cors(request), 'Content-Type': 'application/json', 'X-Cache': r.cached ? 'HIT' : 'MISS' },
      });
    }

    // GET /1inch/*  — proxy to 1inch Swap API (hides API key, bypasses CORS)
    if (url.pathname.startsWith('/1inch/')) {
      if (request.method !== 'GET') return json(request, { error: 'GET only' }, 405);
      const inchPath = url.pathname.slice(6); // strip "/1inch" prefix
      if (!inchPath.startsWith('/swap/')) return json(request, { error: 'forbidden path' }, 403);
      const inchUrl = `${INCH_API}${inchPath}?${url.searchParams}`;
      const r = await cachedUpstream(`1inch|${inchUrl}`, () => fetch(inchUrl, {
        headers: { 'Authorization': `Bearer ${env.INCH_API_KEY}` },
      }));
      return new Response(r.body, {
        status: r.status,
        headers: { ...cors(request), 'Content-Type': 'application/json', 'X-Cache': r.cached ? 'HIT' : 'MISS' },
      });
    }

    // GET /okx/*  — proxy to OKX DEX Aggregator API (HMAC-signed, hides credentials)
    if (url.pathname.startsWith('/okx/')) {
      if (request.method !== 'GET') return json(request, { error: 'GET only' }, 405);
      const okxPath = url.pathname.slice(4); // strip "/okx" prefix
      if (!okxPath.startsWith('/dex/')) return json(request, { error: 'forbidden path' }, 403);
      const requestPath = `/api/v6${okxPath}`;
      const qs = url.searchParams.toString();
      const timestamp = new Date().toISOString();
      const stringToSign = timestamp + 'GET' + requestPath + (qs ? '?' + qs : '');
      const key = await crypto.subtle.importKey(
        'raw', new TextEncoder().encode(env.OKX_SECRET_KEY),
        { name: 'HMAC', hash: 'SHA-256' }, false, ['sign'],
      );
      const sig = btoa(String.fromCharCode(...new Uint8Array(
        await crypto.subtle.sign('HMAC', key, new TextEncoder().encode(stringToSign)),
      )));
      const okxUrl = `${OKX_API}${requestPath}${qs ? '?' + qs : ''}`;
      const r = await cachedUpstream(`okx|${okxUrl}`, () => fetch(okxUrl, {
        headers: {
          'OK-ACCESS-KEY': env.OKX_API_KEY,
          'OK-ACCESS-SIGN': sig,
          'OK-ACCESS-TIMESTAMP': timestamp,
          'OK-ACCESS-PASSPHRASE': env.OKX_PASSPHRASE,
        },
      }));
      return new Response(r.body, {
        status: r.status,
        headers: { ...cors(request), 'Content-Type': 'application/json', 'X-Cache': r.cached ? 'HIT' : 'MISS' },
      });
    }

    // GET /enso/*  — proxy to the Enso shortcuts API (attaches the API key that
    // its route endpoint now requires; unauthenticated calls get a 403).
    if (url.pathname.startsWith('/enso/')) {
      if (request.method !== 'GET') return json(request, { error: 'GET only' }, 405);
      const ensoPath = url.pathname.slice(5); // strip "/enso" prefix
      if (!ensoPath.startsWith('/api/v1/shortcuts/')) return json(request, { error: 'forbidden path' }, 403);
      const headers = { 'Accept': 'application/json' };
      if (env.ENSO_API_KEY) headers['Authorization'] = `Bearer ${env.ENSO_API_KEY}`;
      const ensoUrl = `${ENSO_API}${ensoPath}?${url.searchParams}`;
      const r = await cachedUpstream(`enso|${ensoUrl}`, () => fetch(ensoUrl, { headers }));
      return new Response(r.body, {
        status: r.status,
        headers: { ...cors(request), 'Content-Type': 'application/json', 'X-Cache': r.cached ? 'HIT' : 'MISS' },
      });
    }

    // GET /proxy-metadata?url=<https-url>  — fetch NFT tokenURI JSON from servers
    // that don't set CORS (e.g. Milady's nginx). Image URLs inside the returned JSON
    // load directly via <img> tags (no CORS required for display), so the proxy is
    // only ever used for the one metadata JSON roundtrip.
    if (url.pathname === '/proxy-metadata') {
      if (request.method !== 'GET') return json(request, { error: 'GET only' }, 405);
      const target = url.searchParams.get('url');
      if (!target) return json(request, { error: 'missing url' }, 400);
      if (!target.startsWith('https://')) return json(request, { error: 'https only' }, 400);
      try {
        const upstream = await fetch(target, { cf: { cacheTtl: 300, cacheEverything: true } });
        // NFT metadata is small; anything larger is abuse/misuse.
        const MAX_META = 256 * 1024;
        const cl = parseInt(upstream.headers.get('content-length') || '0', 10);
        if (cl > MAX_META) return json(request, { error: 'too large' }, 413);
        const text = await upstream.text();
        if (text.length > MAX_META) return json(request, { error: 'too large' }, 413);
        return new Response(text, {
          status: upstream.status,
          headers: {
            ...cors(request),
            'Content-Type': upstream.headers.get('content-type') || 'application/json',
            'Cache-Control': 'public, max-age=300',
          },
        });
      } catch (e) {
        return json(request, { error: 'fetch failed: ' + (e.message || 'unknown') }, 502);
      }
    }

    if (request.method !== 'POST') return json(request, { error: 'method not allowed' }, 405);

    // POST /pin-image  — multipart image upload → pinned to IPFS via Filebase
    if (url.pathname === '/pin-image') {
      const ct = request.headers.get('content-type') || '';
      if (!ct.includes('multipart/form-data')) return json(request, { error: 'multipart/form-data required' }, 400);

      const form = await request.formData();
      const file = form.get('file');
      if (!file || !file.size) return json(request, { error: 'no file' }, 400);
      if (file.size > MAX_IMAGE) return json(request, { error: 'file too large (5MB max)' }, 400);

      const bytes = new Uint8Array(await file.arrayBuffer());
      // Content-addressed object key so re-uploading identical bytes is idempotent.
      const key = `images/${await sha256Hex(bytes)}`;
      try {
        return json(request, { cid: await filebasePut(env, key, bytes, file.type || 'application/octet-stream') });
      } catch (e) {
        return json(request, { error: 'pin failed: ' + (e.message || 'unknown') }, 502);
      }
    }

    // POST /pin-json  — JSON metadata → pinned to IPFS via Filebase
    if (url.pathname === '/pin-json') {
      const body = await request.text();
      if (body.length > MAX_JSON) return json(request, { error: 'payload too large' }, 400);

      let metadata;
      try { metadata = JSON.parse(body); } catch { return json(request, { error: 'invalid JSON' }, 400); }

      // Re-serialize the parsed value so the pinned bytes are exactly what we validated.
      const canonical = _enc.encode(JSON.stringify(metadata));
      const key = `json/${await sha256Hex(canonical)}.json`;
      try {
        return json(request, { cid: await filebasePut(env, key, canonical, 'application/json') });
      } catch (e) {
        return json(request, { error: 'pin failed: ' + (e.message || 'unknown') }, 502);
      }
    }

    return json(request, { error: 'not found' }, 404);
  },
};
