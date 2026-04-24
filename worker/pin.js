// Cloudflare Worker: IPFS pinning proxy for Pinata + 0x/1inch/OKX swap API proxies
// Deploy: wrangler deploy
// Secrets: wrangler secret put PINATA_KEY / PINATA_SECRET / OX_API_KEY / INCH_API_KEY / OKX_API_KEY / OKX_SECRET_KEY / OKX_PASSPHRASE

const PINATA = 'https://api.pinata.cloud';
const OX_API = 'https://api.0x.org';
const INCH_API = 'https://api.1inch.dev';
const OKX_API = 'https://web3.okx.com';
const MAX_IMAGE = 5 * 1024 * 1024; // 5MB
const MAX_JSON = 64 * 1024; // 64KB

const ALLOWED_ORIGINS = ['https://zfi.wei.is', 'http://localhost:8080', 'http://localhost:3000'];

function cors(request) {
  const origin = request.headers.get('Origin') || '';
  return {
    'Access-Control-Allow-Origin': ALLOWED_ORIGINS.includes(origin) ? origin : '',
    'Access-Control-Allow-Methods': 'GET, POST, PATCH, DELETE, OPTIONS',
    'Access-Control-Allow-Headers': 'Content-Type, Prefer',
  };
}

function json(request, data, status = 200) {
  return new Response(JSON.stringify(data), { status, headers: { ...cors(request), 'Content-Type': 'application/json' } });
}

function pinHeaders(env) {
  return { pinata_api_key: env.PINATA_KEY, pinata_secret_api_key: env.PINATA_SECRET };
}

export default {
  async fetch(request, env) {
    if (request.method === 'OPTIONS') return new Response(null, { headers: cors(request) });

    // Reject requests from non-allowlisted origins (CORS is browser-only; this blocks curl/scripts too)
    const origin = request.headers.get('Origin') || '';
    if (!ALLOWED_ORIGINS.includes(origin)) {
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
      const res = await fetch(oxUrl, {
        headers: { '0x-api-key': env.OX_API_KEY, '0x-version': 'v2' },
      });
      return new Response(res.body, {
        status: res.status,
        headers: { ...cors(request), 'Content-Type': 'application/json' },
      });
    }

    // GET /1inch/*  — proxy to 1inch Swap API (hides API key, bypasses CORS)
    if (url.pathname.startsWith('/1inch/')) {
      if (request.method !== 'GET') return json(request, { error: 'GET only' }, 405);
      const inchPath = url.pathname.slice(6); // strip "/1inch" prefix
      if (!inchPath.startsWith('/swap/')) return json(request, { error: 'forbidden path' }, 403);
      const inchUrl = `${INCH_API}${inchPath}?${url.searchParams}`;
      const res = await fetch(inchUrl, {
        headers: { 'Authorization': `Bearer ${env.INCH_API_KEY}` },
      });
      return new Response(res.body, {
        status: res.status,
        headers: { ...cors(request), 'Content-Type': 'application/json' },
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
      const res = await fetch(okxUrl, {
        headers: {
          'OK-ACCESS-KEY': env.OKX_API_KEY,
          'OK-ACCESS-SIGN': sig,
          'OK-ACCESS-TIMESTAMP': timestamp,
          'OK-ACCESS-PASSPHRASE': env.OKX_PASSPHRASE,
        },
      });
      return new Response(res.body, {
        status: res.status,
        headers: { ...cors(request), 'Content-Type': 'application/json' },
      });
    }

    // POST /db/:table  — Supabase insert proxy (hides credentials, enforces origin + source)
    // GET  /db/:table  — Supabase read proxy
    // PATCH /db/:table — Supabase update proxy
    // DELETE /db/:table — Supabase delete proxy
    if (url.pathname.startsWith('/db/')) {
      const table = url.pathname.slice(4).split('?')[0]; // e.g. "launched_tokens"
      const ALLOWED_TABLES = ['launched_tokens', 'token_trades', 'gated_rooms', 'gated_room_members', 'gated_room_messages'];
      if (!ALLOWED_TABLES.includes(table)) return json(request, { error: 'invalid table' }, 400);

      const supabaseUrl = env.SUPABASE_URL;    // e.g. https://xyz.supabase.co
      const supabaseKey = env.SUPABASE_KEY;     // service_role key (server-side only)
      if (!supabaseUrl || !supabaseKey) return json(request, { error: 'db not configured' }, 500);

      const SOURCE = 'zfi';
      const qs = url.search || '';
      const target = `${supabaseUrl}/rest/v1/${table}${qs}`;
      const headers = {
        'apikey': supabaseKey,
        'Authorization': `Bearer ${supabaseKey}`,
        'Content-Type': 'application/json',
        'Prefer': request.headers.get('Prefer') || 'return=minimal',
      };

      if (request.method === 'GET') {
        const res = await fetch(target, { headers });
        return new Response(res.body, {
          status: res.status,
          headers: { ...cors(request), 'Content-Type': 'application/json' },
        });
      }

      if (request.method === 'POST') {
        const body = await request.text();
        if (body.length > MAX_JSON) return json(request, { error: 'payload too large' }, 400);
        let row;
        try { row = JSON.parse(body); } catch { return json(request, { error: 'invalid JSON' }, 400); }
        // Force source tag
        row.source = SOURCE;
        const res = await fetch(target, { method: 'POST', headers, body: JSON.stringify(row) });
        return new Response(res.body, {
          status: res.status,
          headers: { ...cors(request), 'Content-Type': 'application/json' },
        });
      }

      if (request.method === 'PATCH') {
        const body = await request.text();
        if (body.length > MAX_JSON) return json(request, { error: 'payload too large' }, 400);
        // Only allow updating own-source rows
        const patchTarget = target.includes('source=eq.') ? target : `${target}${qs ? '&' : '?'}source=eq.${SOURCE}`;
        const res = await fetch(patchTarget, { method: 'PATCH', headers, body });
        return new Response(res.body, {
          status: res.status,
          headers: { ...cors(request), 'Content-Type': 'application/json' },
        });
      }

      if (request.method === 'DELETE') {
        // Only allow deleting own-source rows
        const delTarget = target.includes('source=eq.') ? target : `${target}${qs ? '&' : '?'}source=eq.${SOURCE}`;
        const res = await fetch(delTarget, { method: 'DELETE', headers });
        return new Response(res.body, {
          status: res.status,
          headers: { ...cors(request), 'Content-Type': 'application/json' },
        });
      }

      return json(request, { error: 'method not allowed' }, 405);
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

    // POST /pin-image  — multipart image upload → pinFileToIPFS
    if (url.pathname === '/pin-image') {
      const ct = request.headers.get('content-type') || '';
      if (!ct.includes('multipart/form-data')) return json(request, { error: 'multipart/form-data required' }, 400);

      const form = await request.formData();
      const file = form.get('file');
      if (!file || !file.size) return json(request, { error: 'no file' }, 400);
      if (file.size > MAX_IMAGE) return json(request, { error: 'file too large (5MB max)' }, 400);

      const pinForm = new FormData();
      pinForm.append('file', file, file.name || 'image');

      const res = await fetch(`${PINATA}/pinning/pinFileToIPFS`, {
        method: 'POST',
        headers: pinHeaders(env),
        body: pinForm,
      });
      const data = await res.json();
      if (!res.ok) return json(request, { error: data.error || 'pin failed' }, 502);
      return json(request, { cid: data.IpfsHash });
    }

    // POST /pin-json  — JSON metadata → pinJSONToIPFS
    if (url.pathname === '/pin-json') {
      const body = await request.text();
      if (body.length > MAX_JSON) return json(request, { error: 'payload too large' }, 400);

      let metadata;
      try { metadata = JSON.parse(body); } catch { return json(request, { error: 'invalid JSON' }, 400); }

      const res = await fetch(`${PINATA}/pinning/pinJSONToIPFS`, {
        method: 'POST',
        headers: { ...pinHeaders(env), 'Content-Type': 'application/json' },
        body: JSON.stringify({ pinataContent: metadata }),
      });
      const data = await res.json();
      if (!res.ok) return json(request, { error: data.error || 'pin failed' }, 502);
      return json(request, { cid: data.IpfsHash });
    }

    return json(request, { error: 'not found' }, 404);
  },
};
