// Cloudflare Worker: IPFS pinning proxy for Pinata + 0x swap API proxy + 1inch proxy
// Deploy: wrangler deploy
// Secrets: wrangler secret put PINATA_KEY / PINATA_SECRET / OX_API_KEY / ONEINCH_API_KEY

const PINATA = 'https://api.pinata.cloud';
const OX_API = 'https://api.0x.org';
const ONEINCH_API = 'https://api.1inch.dev';
const MAX_IMAGE = 5 * 1024 * 1024; // 5MB
const MAX_JSON = 64 * 1024; // 64KB

const ALLOWED_ORIGINS = ['https://zfi.wei.is'];

function cors(request) {
  const origin = request.headers.get('Origin') || '';
  return {
    'Access-Control-Allow-Origin': ALLOWED_ORIGINS.includes(origin) ? origin : '',
    'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
    'Access-Control-Allow-Headers': 'Content-Type',
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

    // GET /1inch/*  — proxy to 1inch Swap API
    if (url.pathname.startsWith('/1inch/')) {
      if (request.method !== 'GET') return json(request, { error: 'GET only' }, 405);
      const inchPath = url.pathname.slice(6); // strip "/1inch" prefix
      if (!inchPath.startsWith('/swap/v6.0/')) return json(request, { error: 'forbidden path' }, 403);
      const inchUrl = `${ONEINCH_API}${inchPath}?${url.searchParams}`;
      const res = await fetch(inchUrl, {
        headers: { 'Authorization': `Bearer ${env.ONEINCH_API_KEY}` },
      });
      return new Response(res.body, {
        status: res.status,
        headers: { ...cors(request), 'Content-Type': 'application/json' },
      });
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
