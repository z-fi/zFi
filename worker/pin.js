// Cloudflare Worker: IPFS pinning proxy for Pinata
// Deploy: wrangler deploy
// Secrets: wrangler secret put PINATA_KEY / PINATA_SECRET

const PINATA = 'https://api.pinata.cloud';
const MAX_IMAGE = 5 * 1024 * 1024; // 5MB
const MAX_JSON = 64 * 1024; // 64KB

const ALLOWED_ORIGINS = ['https://zfi.wei.is', 'http://localhost:8888'];

function cors(request) {
  const origin = request.headers.get('Origin') || '';
  return {
    'Access-Control-Allow-Origin': ALLOWED_ORIGINS.includes(origin) ? origin : '',
    'Access-Control-Allow-Methods': 'POST, OPTIONS',
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
    if (request.method !== 'POST') return json(request, { error: 'POST only' }, 405);

    const url = new URL(request.url);

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
