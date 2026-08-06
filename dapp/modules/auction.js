// ==================== NFT DUTCH AUCTION ====================
// Third tab of the coin launch page. Lists a single ERC721 NFT as a
// Dutch auction (linear price decay in ETH) via the deployed DutchAuction.
// There is no off-chain index, so buyers always see the NFT's native tokenURI —
// the gallery and detail page both read it straight from the token contract.

const DUTCH_AUCTION = '0x0000000003635fd3852E772C6E09Ce2aF25d7133';

const DUTCH_AUCTION_ABI = [
  'function listNFT(address token, uint256[] ids, uint128 startPrice, uint128 endPrice, uint40 startTime, uint40 duration) returns (uint256)',
  'event Created(uint256 indexed id, address indexed seller, address indexed token)'
];

const ERC721_ABI = [
  'function tokenURI(uint256 tokenId) view returns (string)',
  'function name() view returns (string)',
  'function symbol() view returns (string)',
  'function approve(address to, uint256 tokenId)',
  'function getApproved(uint256 tokenId) view returns (address)',
  'function ownerOf(uint256 tokenId) view returns (address)'
];

const ERC721_IFACE = new ethers.Interface(ERC721_ABI);

// Curated list of popular ERC-721 collections, shown as a searchable dropdown
// below the NFT Contract input. Each name/symbol was verified on-chain against
// the deployed contract so they match what `nft.name()` / `nft.symbol()` return.
// Typing a raw 0x address or .eth/.wei name still works unchanged.
const POPULAR_NFT_COLLECTIONS = [
  { name: 'Wrapped CryptoPunks',    symbol: 'WPUNKS',   address: '0xb7F7F6C52F2e2fdb1963Eab30438024864c313F6' },
  { name: 'Milady Maker',           symbol: 'MIL',      address: '0x5Af0D9827E0c53E4799BB226655A1de152A425a5' },
  { name: 'Bored Ape Yacht Club',   symbol: 'BAYC',     address: '0xBC4CA0EdA7647A8aB7C2061c2E118A18a936f13D' },
  { name: 'Mutant Ape Yacht Club',  symbol: 'MAYC',     address: '0x60E4d786628Fea6478F785A6d7e704777c86a7c6' },
  { name: 'Azuki',                  symbol: 'AZUKI',    address: '0xED5AF388653567Af2F388E6224dC7C4b3241C544' },
  { name: 'Pudgy Penguins',         symbol: 'PPG',      address: '0xBd3531dA5CF5857e7CfAA92426877b022e612cf8' },
  { name: 'Moonbirds',              symbol: 'MOONBIRD', address: '0x23581767a106ae21c074b2276D25e5C3e136a68b' },
  { name: 'Doodles',                symbol: 'DOODLE',   address: '0x8a90CAb2b38dba80c64b7734e58Ee1dB38B8992e' },
  { name: 'CloneX',                 symbol: 'CloneX',   address: '0x49cF6f5d44E70224e2E23fDcdd2C053F30aDA28B' },
  { name: 'Cool Cats',              symbol: 'COOL',     address: '0x1A92f7381B9F03921564a437210bB9396471050C' },
  { name: 'Meebits',                symbol: 'MEEBIT',   address: '0x7Bd29408f11D2bFC23c34f18275bBf23bB716Bc7' },
  { name: 'MoonCats (Acclimated)',  symbol: 'MCAT',     address: '0xc3f733ca98E0daD0386979Eb96fb1722A1A05E69' },
  { name: 'Nouns',                  symbol: 'NOUN',     address: '0x9C8fF314C9Bc7F6e59A9d9225Fb22946427eDC03' },
  { name: 'Otherdeeds',             symbol: 'OTHR',     address: '0x34d85c9CDeB23FA97cb08333b511ac86E1C4E258' },
  { name: 'mfers',                  symbol: 'MFER',     address: '0x79FCDEF22feeD20eDDacbB2587640e45491b757f' },
  { name: 'Cryptoadz',              symbol: 'TOADZ',    address: '0x1CB1A5e65610AEFF2551A50f76a87a7d3fB649C6' },
  { name: 'Art Blocks',             symbol: 'BLOCKS',   address: '0x059EDD72Cd353dF5106D2B9cC5ab83a52287aC3a' }
];

// --- Searchable dropdown over POPULAR_NFT_COLLECTIONS ---
function _nftCollectionsFor(query) {
  const q = (query || '').trim().toLowerCase();
  if (!q) return POPULAR_NFT_COLLECTIONS;
  // If the user already typed a valid address (matches none of our list),
  // return empty — the dropdown stays hidden and resolution proceeds normally.
  return POPULAR_NFT_COLLECTIONS.filter(c =>
    c.name.toLowerCase().includes(q) ||
    c.symbol.toLowerCase().includes(q) ||
    c.address.toLowerCase().startsWith(q)
  );
}
function _nftRenderCollectionDropdown(query) {
  const dd = $('nftCollectionDropdown');
  if (!dd) return;
  const results = _nftCollectionsFor(query);
  if (results.length === 0) { dd.style.display = 'none'; return; }
  dd.innerHTML = results.map(c =>
    `<div class="nft-dd-row" onmousedown="event.preventDefault()" onclick="_nftPickCollection('${c.address}')">
       <div><div class="nft-dd-name">${escText(c.name)}</div><div class="nft-dd-sym">${escText(c.symbol)}</div></div>
       <div class="nft-dd-addr">${c.address.slice(0,6)}…${c.address.slice(-4)}</div>
     </div>`
  ).join('');
  dd.style.display = 'block';
}
function _nftPickCollection(address) {
  const el = $('nftContract');
  if (!el) return;
  el.value = address;
  const dd = $('nftCollectionDropdown'); if (dd) dd.style.display = 'none';
  if (typeof onCoinAddressInput === 'function') {
    onCoinAddressInput('nftContract', 'nftContractResolved', auctionOnNftChange);
  }
  // Move focus to the token id field to nudge the next input.
  const idEl = $('nftTokenId'); if (idEl) idEl.focus();
}
function _nftContractInput() {
  const val = $('nftContract')?.value || '';
  _nftRenderCollectionDropdown(val);
  if (typeof onCoinAddressInput === 'function') {
    onCoinAddressInput('nftContract', 'nftContractResolved', auctionOnNftChange);
  }
}
function _nftContractFocus() {
  _nftRenderCollectionDropdown($('nftContract')?.value || '');
}
function _nftContractBlur() {
  // Delay so onmousedown on a dropdown row has a chance to register the pick.
  setTimeout(() => { const dd = $('nftCollectionDropdown'); if (dd) dd.style.display = 'none'; }, 180);
}

// Mutable form state for the NFT tab
let _auctionNftMeta = null;      // resolved NFT (name, description, image, collectionName, collectionSymbol, owner)
let _auctionFloorPct = 1;        // floor as % of start price (0..100)
let _auctionDurationDays = 3;    // Dutch auction "lindy" default
let _auctionFetchSeq = 0;        // race guard for tokenURI lookups
let _auctionOwnerOk = false;     // connected wallet owns the resolved token
let _auctionBlockMsg = '';       // why listing is blocked, if it is

// Resolve a tokenURI/metadata URI to an HTTP(S) URL the browser can fetch.
// Covers the three non-HTTP forms NFTs use in the wild: ipfs://, ar://, and
// plain http/https/data which pass through untouched.
function _auctionIpfsToHttp(uri) {
  if (!uri) return '';
  if (uri.startsWith('ipfs://')) return IPFS_GATEWAYS[0] + uri.slice(7);
  if (uri.startsWith('ar://'))   return 'https://arweave.net/' + uri.slice(5);
  return uri;
}

// Every configured gateway for an ipfs:// URI, best-first. Non-IPFS URIs have no
// alternates, so the caller gets a single candidate.
function _auctionIpfsCandidates(uri) {
  if (!uri) return [];
  if (uri.startsWith('ipfs://')) return IPFS_GATEWAYS.map(g => g + uri.slice(7));
  return [_auctionIpfsToHttp(uri)];
}

// <img> onerror hook — walk to the next gateway, false when all are exhausted.
function _auctionImgNextGateway(img) {
  const src = img.getAttribute('src') || '';
  const i = IPFS_GATEWAYS.findIndex(g => src.startsWith(g));
  if (i === -1 || i + 1 >= IPFS_GATEWAYS.length) return false;
  img.src = IPFS_GATEWAYS[i + 1] + src.slice(IPFS_GATEWAYS[i].length);
  return true;
}

// Parse a tokenURI value (http, ipfs, or data:) into a metadata object.
// Fast path fetches directly (works for IPFS gateway + CORS-friendly servers);
// falls back to the worker proxy for CORS-blocked servers like Milady's nginx.
// Images themselves don't need the proxy — <img> tags ignore CORS for display.
async function _auctionFetchMetadata(tokenURI) {
  if (!tokenURI) return {};
  if (tokenURI.startsWith('data:application/json')) {
    const comma = tokenURI.indexOf(',');
    const body = tokenURI.slice(comma + 1);
    const isB64 = tokenURI.slice(5, comma).includes('base64');
    const decoded = isB64 ? atob(body) : decodeURIComponent(body);
    try { return JSON.parse(decoded); } catch { return {}; }
  }
  // Try each gateway before the proxy — one dead host shouldn't cost the seller
  // the NFT preview and the name/description autofill.
  for (const candidate of _auctionIpfsCandidates(tokenURI)) {
    try {
      const r = await fetch(candidate);
      if (r.ok) return await r.json();
    } catch {} // likely CORS or network — try the next gateway, then the proxy
  }
  const url = _auctionIpfsToHttp(tokenURI);
  try {
    const r = await fetch(`${COIN_PIN_URL}/proxy-metadata?url=${encodeURIComponent(url)}`);
    if (r.ok) return await r.json();
  } catch {}
  return {};
}

// Called on contract/token-id input change and when the NFT tab is activated.
async function auctionOnNftChange() {
  if (_coinLaunchType !== 'nft') return;

  const contract = coinGetResolved('nftContract');
  const idRaw = ($('nftTokenId').value || '').trim();
  const preview = $('nftPreview');

  _auctionNftMeta = null;
  _auctionOwnerOk = false;
  _auctionBlockMsg = '';
  setDisabled('coinLaunchBtn', true);
  // Any prior error ("not the owner", "could not read token", etc.) should
  // clear the moment the user edits the inputs — otherwise it looks stuck.
  _coinLaunched = false;
  coinShowStatus('');
  const _btn = $('coinLaunchBtn');
  if (_btn) _btn.textContent = coinLaunchBtnLabel();

  if (!contract || !idRaw) {
    preview.style.display = 'none';
    auctionUpdatePreview();
    if (typeof syncCoinURL === 'function') syncCoinURL();
    return;
  }

  let tokenId;
  try { tokenId = BigInt(idRaw); } catch { preview.style.display = 'none'; return; }

  const seq = ++_auctionFetchSeq;
  preview.style.display = 'block';
  preview.innerHTML = '<div style="font-size:12px;color:var(--fg-muted)">Loading NFT…</div>';

  try {
    // Single eth_call via Multicall3 aggregate3 — collapses the 4 reads into
    // one RPC round-trip. Earlier we used Promise.all with ethers JSON-RPC
    // batching, but publicnode.com rate-limits those batches and returns
    // SERVER_ERROR for every call, which .catch() would swallow.
    const resolved = await quoteRPC.call(async (rpc) => {
      const entries = [
        { target: contract, data: ERC721_IFACE.encodeFunctionData('tokenURI', [tokenId]) },
        { target: contract, data: ERC721_IFACE.encodeFunctionData('name') },
        { target: contract, data: ERC721_IFACE.encodeFunctionData('symbol') },
        { target: contract, data: ERC721_IFACE.encodeFunctionData('ownerOf', [tokenId]) },
      ];
      const mc3 = await mc3ViewBatch(rpc, entries);
      const tokenURI = mc3Decode(mc3, 0, ERC721_IFACE, 'tokenURI')?.[0] || '';
      const collName = mc3Decode(mc3, 1, ERC721_IFACE, 'name')?.[0] || '';
      const collSym  = mc3Decode(mc3, 2, ERC721_IFACE, 'symbol')?.[0] || '';
      const owner    = mc3Decode(mc3, 3, ERC721_IFACE, 'ownerOf')?.[0] || null;
      return { tokenURI, collName, collSym, owner };
    });
    if (seq !== _auctionFetchSeq) return; // superseded

    const metadata = await _auctionFetchMetadata(resolved.tokenURI);
    if (seq !== _auctionFetchSeq) return;

    const imageRaw = metadata.image || '';
    const image = _auctionIpfsToHttp(imageRaw);
    const fallbackName = `${resolved.collSym || resolved.collName || 'NFT'} #${tokenId}`;
    _auctionNftMeta = {
      name: metadata.name || fallbackName,
      description: metadata.description || '',
      image,         // gateway form — used for <img> preview in the form
      imageRaw,      // original form (ipfs:// or http) — used when pinning our metadata
      collectionName: resolved.collName || '',
      collectionSymbol: resolved.collSym || '',
      owner: resolved.owner || null,
      contract,
      tokenId
    };

    const ownerShort = resolved.owner
      ? resolved.owner.slice(0, 6) + '…' + resolved.owner.slice(-4)
      : '—';
    preview.innerHTML = `
      <div style="display:flex;gap:12px;align-items:center">
        ${image ? `<img src="${escAttr(image)}" style="width:56px;height:56px;object-fit:cover;border:1px solid var(--border-muted)" onerror="if(!_auctionImgNextGateway(this))this.style.display='none'">` : `<div style="width:56px;height:56px;border:1px solid var(--border-muted);display:flex;align-items:center;justify-content:center;font-size:10px;color:var(--fg-muted)">no image</div>`}
        <div style="min-width:0;flex:1">
          <div style="font-weight:600;font-size:13px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap">${escText(_auctionNftMeta.name)}</div>
          <div style="font-size:11px;color:var(--fg-muted);font-family:ui-monospace,Menlo,monospace;margin-top:2px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap">${escText(resolved.collName || '')}${resolved.collSym ? ' · ' + escText(resolved.collSym) : ''}</div>
          <div style="font-size:11px;color:var(--fg-muted);font-family:ui-monospace,Menlo,monospace;margin-top:2px">owner: ${ownerShort}</div>
        </div>
      </div>
    `;

    // Require that the connected wallet actually owns this token before enabling list.
    // resolved.owner == null means ownerOf reverted — usually a non-ERC-721 contract
    // or a non-existent token id. Block the launch up front with a clear message
    // instead of letting the user hit a raw revert later.
    let canList = true;
    let blockMsg = '';
    if (resolved.owner === null) {
      canList = false;
      blockMsg = 'Could not read token owner — is this an ERC-721 contract, and does this token id exist?';
    } else if (_signer) {
      try {
        const me = (await _signer.getAddress()).toLowerCase();
        if (resolved.owner.toLowerCase() !== me) {
          canList = false;
          blockMsg = 'Connected wallet is not the current owner of this token';
        }
      } catch {}
    }
    _auctionOwnerOk = canList;
    _auctionBlockMsg = blockMsg;
    auctionApplyGating();

    auctionUpdatePreview();
    if (typeof syncCoinURL === 'function') syncCoinURL();
  } catch (e) {
    if (seq !== _auctionFetchSeq) return;
    preview.innerHTML = `<div style="font-size:12px;color:var(--error)">Could not load NFT: ${escText(e.shortMessage || e.message || String(e))}</div>`;
  }
}

// Debounced variant for keystroke-driven callers (oninput on nftTokenId).
// Programmatic callers (tab switch, dropdown pick, deeplink restore) stay on
// the direct function so they respond immediately.
const auctionOnNftChangeDebounced = debounce(auctionOnNftChange, 350);

// Each chip handler only deactivates siblings within its own chip row so the
// two rows (floor / duration) don't wipe each other. When `btn` is null
// (programmatic call from a deeplink restore), we fall back to matching by
// the row's position and the chip's numeric text content.
function _nftChipRow(i) {
  return document.querySelectorAll('#coinNftWrap .nft-chip-row')[i] || null;
}
function _activateChipByNumber(row, n) {
  if (!row) return;
  row.querySelectorAll('.nft-chip').forEach(b => {
    b.classList.toggle('active', parseInt(b.textContent, 10) === n);
  });
}
// The chips only ever pass values the contract accepts, but ?mode=nft deeplinks
// call these with whatever was in the URL. DutchAuction.listNFT rejects
// duration == 0 and endPrice > startPrice, and a negative reaches ethers as an
// out-of-range uint40/uint128 — so an unclamped link builds a form that can only
// fail, after the wallet prompt, with a raw revert. Clamp at the setter so every
// caller is covered rather than just the deeplink path.
function _auctionClampFloor(pct) {
  const n = Math.round(Number(pct));
  if (!Number.isFinite(n)) return 1;
  return Math.min(100, Math.max(0, n));
}

function _auctionClampDuration(days) {
  const n = Math.round(Number(days));
  if (!Number.isFinite(n)) return 3;
  // uint40 seconds is far larger than any useful auction; a year is the practical cap.
  return Math.min(365, Math.max(1, n));
}

function auctionSetFloor(pct, btn) {
  _auctionFloorPct = _auctionClampFloor(pct);
  if (btn) btn.parentElement.querySelectorAll('.nft-chip').forEach(b => b.classList.toggle('active', b === btn));
  else _activateChipByNumber(_nftChipRow(0), _auctionFloorPct);
  auctionUpdatePreview();
  if (typeof syncCoinURL === 'function') syncCoinURL();
}

function auctionSetDuration(days, btn) {
  _auctionDurationDays = _auctionClampDuration(days);
  if (btn) btn.parentElement.querySelectorAll('.nft-chip').forEach(b => b.classList.toggle('active', b === btn));
  else _activateChipByNumber(_nftChipRow(1), _auctionDurationDays);
  auctionUpdatePreview();
  if (typeof syncCoinURL === 'function') syncCoinURL();
}

// Renders a monospace sparkline for the price decay plus the marker prices
// at 25 / 50 / 75 / 100% elapsed. Hidden while inputs aren't valid.
// Ownership is resolved asynchronously; the start price is typed. Both have to
// hold before listing, so they are tracked separately and combined here — the
// curve and cause tabs gate their CTA the same way through coinApplyValidation,
// and without this the button stayed live with an empty price field and only
// failed on click.
function auctionApplyGating() {
  if (_coinLaunchType !== 'nft') return;
  const startPrice = coinParseEth(($('nftStartPrice')?.value || ''));
  const priceOk = startPrice !== null && startPrice > 0n;
  const ok = _auctionOwnerOk && !!_auctionNftMeta && priceOk;
  setDisabled('coinLaunchBtn', !ok);
  // _coinLaunched means the success banner is on screen for a listing that just
  // went through; the form is empty by design at that point, so leave it alone.
  if (!_coinLaunched) {
    if (!_auctionOwnerOk && _auctionBlockMsg) coinShowStatus(_auctionBlockMsg, true);
    else coinShowStatus('');
  }
  const hint = $('coinFormHint');
  if (hint) {
    const msg = (_auctionOwnerOk && _auctionNftMeta && !priceOk) ? 'Enter a start price greater than 0' : '';
    hint.textContent = msg;
    hint.style.display = msg ? '' : 'none';
  }
}

function auctionUpdatePreview() {
  if (_coinLaunchType !== 'nft') return;
  auctionApplyGating();
  const el = $('nftDecayPreview');
  if (!el) return;
  const start = parseFloat($('nftStartPrice').value) || 0;
  const end = start * (_auctionFloorPct / 100);
  const days = _auctionDurationDays;
  const durationSec = days * 86400;

  if (!start || start <= 0) {
    el.style.display = 'none';
    return;
  }
  el.style.display = 'block';

  const W = 38, H = 6;
  const rows = [];
  for (let y = 0; y < H; y++) rows.push(new Array(W).fill(' '));
  for (let x = 0; x < W; x++) {
    const frac = W === 1 ? 0 : x / (W - 1);
    const price = start - (start - end) * frac;
    const norm = (start === end) ? 1 : (price - end) / (start - end);
    const row = Math.round((1 - norm) * (H - 1));
    for (let y = row; y < H; y++) rows[y][x] = (y === row) ? '█' : '▓';
  }
  const curve = rows.map(r => r.join('')).join('\n');

  const fmtE = v => v >= 10 ? v.toFixed(2) : (v >= 0.01 ? v.toFixed(4) : v.toFixed(6));
  const fmtT = frac => {
    const hours = Math.floor(frac * durationSec / 3600);
    if (hours >= 24) {
      const d = Math.floor(hours / 24);
      const h = hours % 24;
      return h > 0 ? `${d}d ${h}h` : `${d}d`;
    }
    return `${hours}h`;
  };
  const marks = [0.25, 0.5, 0.75, 1.0].map(f => ({
    t: fmtT(f),
    p: fmtE(start - (start - end) * f)
  }));

  el.innerHTML = `
    <div style="font-size:10px;font-weight:600;letter-spacing:0.14em;text-transform:uppercase;color:var(--fg-muted);margin-bottom:6px">Decay Preview</div>
    <pre style="line-height:1;font-size:12px;color:var(--fg);margin:0 0 8px;white-space:pre">${curve}</pre>
    <div style="display:grid;grid-template-columns:1fr 1fr;gap:4px 12px;font-size:11px;color:var(--fg-muted);font-family:ui-monospace,Menlo,monospace">
      ${marks.map(m => `<div>${m.t} → <span style="color:var(--fg);font-weight:600">${m.p} Ξ</span></div>`).join('')}
    </div>
  `;
}

// Two-step launch: approve the NFT for DutchAuction, then listNFT.
async function auctionLaunch() {
  if (!_signer) { connectWallet(); return; }
  if (!_auctionNftMeta) { coinShowStatus('Enter NFT contract and token id first', true); return; }

  const contract = _auctionNftMeta.contract;
  const tokenId = _auctionNftMeta.tokenId;
  const startPrice = coinParseEth($('nftStartPrice').value);
  if (startPrice === null) { coinShowStatus('Invalid start price', true); return; }
  if (startPrice === 0n) { coinShowStatus('Start price must be greater than 0', true); return; }
  const endPrice = startPrice * BigInt(_auctionFloorPct) / 100n;
  // A 0% floor means the NFT can decay all the way to 0 Ξ — anyone paying gas
  // can claim it free at the end of the auction. Make sure the seller knows
  // what they're agreeing to before we sign txs.
  if (_auctionFloorPct === 0) {
    const ok = confirm(
      'Your floor is 0% — this NFT will decay all the way to 0 Ξ over ' +
      _auctionDurationDays + ' day(s).\n\n' +
      'Anyone watching can claim it for roughly gas cost at the end of the auction. ' +
      'Continue?'
    );
    if (!ok) return;
  }
  const duration = BigInt(_auctionDurationDays * 86400);

  let launched = false;
  _coinLaunching = true;
  setDisabled('coinLaunchBtn', true);
  const _pg = $('coinLaunchProgress');
  _pg.classList.remove('active');
  void _pg.offsetWidth;
  _pg.classList.add('active');

  try {
    const seller = await _signer.getAddress();

    // Ownership sanity — _auctionNftMeta.owner came from an earlier RPC, so re-check fresh.
    const nft = new ethers.Contract(contract, ERC721_ABI, _signer);
    const currentOwner = await nft.ownerOf(tokenId);
    if (currentOwner.toLowerCase() !== seller.toLowerCase()) {
      throw new Error('You are not the current owner of this token');
    }

    // --- Step 1: approve (if not already) ---
    coinShowStatus('Checking approval...');
    const approved = await nft.getApproved(tokenId);
    if (approved.toLowerCase() !== DUTCH_AUCTION.toLowerCase()) {
      coinShowStatus('Approving NFT transfer (1/2)...');
      const atx = await nft.approve(DUTCH_AUCTION, tokenId);
      await atx.wait();
    }

    // --- Step 2: listNFT ---
    coinShowStatus('Listing on auction (2/2)...');
    const auction = new ethers.Contract(DUTCH_AUCTION, DUTCH_AUCTION_ABI, _signer);
    const tx = await auction.listNFT(contract, [tokenId], startPrice, endPrice, 0, duration);
    const receipt = await tx.wait();

    // Extract auction id from the Created event in the listNFT receipt.
    let auctionId = null;
    for (const log of receipt.logs) {
      if (log.address.toLowerCase() !== DUTCH_AUCTION.toLowerCase()) continue;
      try {
        const parsed = auction.interface.parseLog(log);
        if (parsed && parsed.name === 'Created') { auctionId = parsed.args.id.toString(); break; }
      } catch {}
    }

    // Success summary — parity with curve/cause launches: headline, terms,
    // verification tx link, and a direct link to the auction detail page.
    const displayName = (_auctionNftMeta.name || 'NFT').slice(0, 80);
    const startEth = ethers.formatEther(startPrice);
    const endEth = ethers.formatEther(endPrice);
    const durTxt = _auctionDurationDays === 1 ? '1 day' : `${_auctionDurationDays} days`;
    const idTxt = auctionId ? ` &middot; Auction #${auctionId}` : '';
    const href = auctionId ? `./auction/?id=${auctionId}` : './auction/';
    launched = true;
    coinShowStatus(
      `<strong>Launched!</strong> <strong>${escText(displayName)}</strong>${idTxt}<br><br>` +
      `Start: ${startEth} Ξ &rarr; Floor: ${endEth} Ξ over ${durTxt}<br>` +
      `Collection: <a href="https://etherscan.io/address/${contract}" target="_blank" rel="noopener">${contract.slice(0,6)}…${contract.slice(-4)}</a> &middot; ` +
      `Token #${tokenId.toString()}<br><br>` +
      `<a href="https://etherscan.io/tx/${tx.hash}" target="_blank" rel="noopener">View tx</a>` +
      (auctionId ? ` &middot; <a href="${href}">View auction &rarr;</a>` : '')
    );
  } catch (e) {
    const rejected = (e.message || '').toLowerCase().includes('user rejected') || e.code === 'ACTION_REJECTED';
    coinShowStatus(rejected ? 'Listing cancelled' : escText(e.shortMessage || e.reason || e.message || 'Launch failed'), !rejected);
  } finally {
    _coinLaunching = false;
    // After a successful listing the seller no longer owns the token, so keep
    // the CTA locked rather than letting a second click revert on-chain.
    _coinLaunched = launched;
    if (launched) {
      _auctionNftMeta = null;
      setDisabled('coinLaunchBtn', true);
      const btn = $('coinLaunchBtn');
      if (btn) btn.textContent = coinLaunchBtnLabel();
    } else {
      setDisabled('coinLaunchBtn', false);
    }
    $('coinLaunchProgress').classList.remove('active');
  }
}
