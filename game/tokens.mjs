/**
 * The invaders' faces, read from chain — the same two sources the page uses.
 *
 * 1. zList (`0x0000006013…`) is the curated list: `rankedIds()` for the order
 *    conviction staking put them in, then `json(id)` per row, whose `l` field
 *    is the logo the DAO curated. Usually a `data:` URI, occasionally a URL.
 *
 * 2. Launched coins come from the pool factory: the pools PLAUNCH created,
 *    deepest first, then `token1()` for the coin and `contractURI()` for its
 *    art — which the launcher stores as a base64 JSON blob with the image
 *    inline, so the artwork is on chain rather than pinned somewhere.
 *
 * Dev-only. When the game is inlined for v0.4 it will not need any of this:
 * the page already holds these icons in TOKENS, and passing them costs nothing.
 * This exists so the harness shows the REAL roster instead of stand-ins.
 */

export const RPCS = ['https://ethereum-rpc.publicnode.com', 'https://eth-mainnet.public.blastapi.io'];
const TOKENLIST = '0x0000006013dF75A31678B786061C2B54bf531524';
const PFACTORY = '0x000000Eb27B557aB426d9E99cFd54EC455799e81';
const PLAUNCH = '0x0000002fC8E77585A008Aa45d78A71ad36293aEe';
const MC3 = '0xcA11bde05977b3631167028862bE2a173976CA11';

const SEL = {
  RANKEDIDS: 'df7ca268', JSON: '74e18e96', BYCREATOR_N: 'aa5e6b5b', BYCREATOR: '7d78be2b',
  RESERVE0: '443cb4bc', TOKEN1: 'd21220a7', SYMBOL: '95d89b41', CONTRACTURI: 'e8a3d485',
  AGG3: '82ad56cb',
};

const strip = h => (h || '').replace(/^0x/, '');
const u256 = v => BigInt(v).toString(16).padStart(64, '0');
const addr32 = a => strip(a).toLowerCase().padStart(64, '0');

let rpcAt = 0;
async function call(to, data) {
  let last;
  for (let i = 0; i < RPCS.length; i++) {
    const url = RPCS[(rpcAt + i) % RPCS.length];
    try {
      const r = await fetch(url, { method: 'POST', headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ id: 1, jsonrpc: '2.0', method: 'eth_call', params: [{ to, data }, 'latest'] }) });
      const j = await r.json();
      if (j.error) throw Error(j.error.message);
      rpcAt = (rpcAt + i) % RPCS.length;
      return j.result;
    } catch (e) { last = e; }
  }
  throw last;
}

/** aggregate3 with allowFailure, so one dead token cannot sink the batch. */
async function batch(calls) {
  if (!calls.length) return [];
  let head = '', tail = '', off = calls.length * 32;
  for (const c of calls) {
    const d = strip(c.data), len = d.length / 2;
    const body = addr32(c.to) + u256(1) + u256(96) + u256(len) + d.padEnd(Math.ceil(d.length / 64) * 64, '0');
    head += u256(off); tail += body; off += body.length / 2;
  }
  const raw = await call(MC3, '0x' + SEL.AGG3 + u256(32) + u256(calls.length) + head + tail);
  const h = strip(raw), at = i => h.slice(i * 64, (i + 1) * 64), out = [];
  const n = Number(BigInt('0x' + at(1)));
  for (let i = 0; i < n; i++) {
    const rel = Number(BigInt('0x' + at(2 + i))) / 32, w = 2 + rel;
    const ok = BigInt('0x' + at(w)) === 1n, bo = Number(BigInt('0x' + at(w + 1))) / 32, lw = w + bo;
    const len = Number(BigInt('0x' + at(lw)));
    out.push(ok ? '0x' + h.slice((lw + 1) * 64, (lw + 1) * 64 + len * 2) : null);
  }
  return out;
}

const decodeString = hex => {
  const h = strip(hex);
  if (h.length < 128) return '';
  const off = Number(BigInt('0x' + h.slice(0, 64))) * 2;
  const len = Number(BigInt('0x' + h.slice(off, off + 64)));
  const body = h.slice(off + 64, off + 64 + len * 2);
  return new TextDecoder().decode(Uint8Array.from(body.match(/../g) || [], b => parseInt(b, 16)));
};

/** The launcher stores art as base64 JSON with the image inline. */
function imgFromContractURI(raw) {
  const P = 'data:application/json;base64,';
  const s = String(raw || '').trim();
  if (!s.startsWith(P) || s.length > 400000) return '';
  try {
    const j = JSON.parse(atob(s.slice(P.length)));
    const img = j.image || j.image_data || '';
    return /^(data:image\/|https:\/\/)/.test(img) ? img : '';
  } catch { return ''; }
}

const iconOf = (sym, logo) => logo
  ? `<img width="20" height="20" style="border-radius:50%;object-fit:cover" src="${logo}" alt="">`
  : `<svg width="20" height="20" viewBox="0 0 32 32"><circle cx="16" cy="16" r="16" fill="#666"/>`
    + `<text x="16" y="21" text-anchor="middle" fill="#fff" font-size="12" font-weight="600"`
    + ` font-family="system-ui">${(sym[0] || '?').toUpperCase()}</text></svg>`;

/** The curated list, in conviction order. */
export async function zListTokens() {
  const raw = await call(TOKENLIST, '0x' + SEL.RANKEDIDS);
  const h = strip(raw), n = Number(BigInt('0x' + h.slice(64, 128)));
  const ids = [];
  for (let i = 0; i < n; i++) {
    const id = BigInt('0x' + h.slice(128 + i * 64, 128 + (i + 1) * 64));
    if (id) ids.push(id);
  }
  const rows = await batch(ids.map(id => ({ to: TOKENLIST, data: '0x' + SEL.JSON + u256(id) })));
  const out = [];
  for (const r of rows) {
    if (!r) continue;
    try {
      const t = JSON.parse(decodeString(r));
      if (t.k !== 'eip155' || !t.s) continue;
      out.push({ sym: String(t.s).slice(0, 12), html: iconOf(String(t.s), t.l), src: 'zList' });
    } catch {}
  }
  return out;
}

/** Coins launched through PLAUNCH, deepest pools first. */
export async function launchedTokens(show = 24) {
  const cnt = Number(BigInt(await call(PFACTORY, '0x' + SEL.BYCREATOR_N + addr32(PLAUNCH)) || '0x0'));
  if (!cnt) return [];
  const take = Math.min(cnt, 256);
  const raw = await call(PFACTORY,
    '0x' + SEL.BYCREATOR + addr32(PLAUNCH) + u256(cnt - take) + u256(take));
  const h = strip(raw), n = h.length >= 128 ? Number(BigInt('0x' + h.slice(64, 128))) : 0;
  let pools = [];
  for (let i = 0; i < n && i < take; i++) pools.push('0x' + h.slice(128 + i * 64 + 24, 128 + (i + 1) * 64));
  if (!pools.length) return [];

  const depth = await batch(pools.map(a => ({ to: a, data: '0x' + SEL.RESERVE0 })));
  pools = pools.map((p, i) => { let d = 0n; try { d = BigInt(depth[i] || '0x0'); } catch {} return { p, d }; })
    .sort((x, y) => (x.d === y.d ? 0 : x.d < y.d ? 1 : -1)).slice(0, show).map(x => x.p);

  const t1 = await batch(pools.map(a => ({ to: a, data: '0x' + SEL.TOKEN1 })));
  const toks = t1.map(x => (x ? ('0x' + strip(x).slice(24)).toLowerCase() : ''))
    .filter(a => /^0x[0-9a-f]{40}$/.test(a));
  if (!toks.length) return [];

  const info = await batch(toks.flatMap(a => [
    { to: a, data: '0x' + SEL.SYMBOL }, { to: a, data: '0x' + SEL.CONTRACTURI }]));
  const out = [];
  toks.forEach((a, i) => {
    let sym = ''; try { sym = decodeString(info[i * 2] || '0x').trim().slice(0, 12); } catch {}
    if (!sym) return;
    let art = ''; try { art = imgFromContractURI(decodeString(info[i * 2 + 1] || '0x')); } catch {}
    out.push({ sym, html: iconOf(sym, art), src: 'launched', art: !!art });
  });
  return out;
}

/** Both sources, curated first — the roster the page itself would show. */
export async function liveTokens() {
  const [listed, born] = await Promise.all([
    zListTokens().catch(() => []),
    launchedTokens().catch(() => []),
  ]);
  const seen = new Set();
  return [...listed, ...born].filter(t => {
    const k = t.sym.toLowerCase();
    if (seen.has(k)) return false;
    seen.add(k); return true;
  });
}
