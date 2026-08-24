// ==================== COIN TAB ====================
const COIN_SUMMONER = '0x0000000000330B8df9E3bc5E553074DA58eE9138';
const COIN_RENDERER = '0x000000000011C799980827F52d3137b4abD6E654';
const COIN_IMPLS = {
  moloch: '0x643A45B599D81be3f3A68F37EB3De55fF10673C1',
  shares: '0x71E9b38d301b5A58cb998C1295045FE276Acf600',
  loot: '0x6f1f2aF76a3aDD953277e9F369242697C87bc6A5'
};
const COIN_CLONE_PREFIX = '0x602d5f8160095f39f35f5f365f5f37365f73';
const COIN_CLONE_SUFFIX = '0x5af43d5f5f3e6029573d5ffd5b3d5ff3';

const COIN_SUPPLY = 1_000_000_000n;
const COIN_SEC_PER_MONTH = 2_629_746n;
// "Fast" tap: seconds of accrual to withdraw the whole raise. Also fixes the
// smallest claimable treasury at raise / COIN_TAP_FAST_SEC — see the tap branch
// of coinLaunch() for why the two are the same number.
const COIN_TAP_FAST_SEC = 3600n;
// Ongoing causes have no goal to scale from, so the fast rate is absolute:
// ~86 ETH/day, claimable from 0.001 ETH in the treasury.
const COIN_TAP_FAST_ONGOING_RATE = 10n ** 15n;
const COIN_SHARE_BURNER = '0x000000000040084694F7B6fb2846D067B4c3Aa9f';

const COIN_PIN_URL = 'https://api.zfi.wei.is';

// PrecisionLauncher — the launch format zSwap uses. One transaction, no ether:
// the supply is minted, the creator's allocation is paid out, and the rest seeds a
// one-sided ETH pool that is a live market from the first block. This REPLACED the
// ClassicalCurveSale bonding-curve launch, which had a graduation step and is no
// longer offered here.
const PRECISION_LAUNCHER = '0x0000002fC8E77585A008Aa45d78A71ad36293aEe';
const PRECISION_LAUNCHER_LENS = '0x00000041201F1542EE49F9722b2590DEDFE4296B';
const PRECISION_LAUNCH_ABI = [
  'function launch(string name,string symbol,string uri,uint256 supply,uint256 allocBps,uint256 startMcapWei,address owner) returns (address token,address pool)',
  'function launchWithArt(string name,string symbol,string uri,uint256 supply,uint256 allocBps,uint256 startMcapWei,address owner,bytes image,uint8 mime) returns (address token,address pool)',
  'event Launched(address indexed token,address indexed pool,address indexed creator,uint256 supply,uint256 allocBps,uint256 startMcapWei)'
];
// On-chain art. The launcher stores the image as contract code, so a launched coin
// carries its own logo with no pinning service to keep paying and no gateway to go
// dark — which is why the coin path does not touch IPFS at all any more.
//
// IMPORTANT: with an image stored, the token's contractURI() assembles its own JSON
// document and uses the stored `uri` string as the DESCRIPTION. So the coin path
// passes the description there, not a metadata pointer. See PrecisionLauncher.
const COIN_MIME = { 'image/png': 0, 'image/webp': 1, 'image/svg+xml': 2, 'image/gif': 3, 'image/jpeg': 4 };
const COIN_MIME_NAME = ['image/png', 'image/webp', 'image/svg+xml', 'image/gif', 'image/jpeg', 'image/avif'];
// The contract's own ceiling is one SSTORE2 write; the budget is what we compress
// toward, since calldata is 16 gas a byte and nobody wants a 24 KB launch.
const COIN_MAX_ART = 24575;
const COIN_ART_BUDGET = 8192;

// Mirrors the launcher's own guards, so the form rejects what the contract would.
const COIN_MAX_ALLOC_BPS = 2000n;      // 20%
const COIN_MIN_MCAP_WEI = 1000000000000n;
const COIN_MIN_POOLED = 2000000000000n;

const SAFE_SUMMONER = '0x00000000004473e1f31C8266612e7FD5504e6f2a';
// ShareSale meters a sale with allowance alone, and allowance is spent at mint and not
// restored at burn — so on a refundable raise every redemption permanently shrinks the
// sale. CELL lost 1,891,891 shares of capacity that way. ShareOffering reads the ceiling
// off live supply instead, so redeemed shares return their room.
//
// Kept here because causes launched before the switch are still read through it.
const SHARE_SALE = '0x0000000021ea5069B532CeE09058aB9e02EA60f9';
const SHARE_OFFERING = '0x000000A4Ad929C9E108aD2B1D2fBeDe0C2Ae57e1';
const SHARE_OFFERING_ABI = [
  'function configure(address token, address payToken, uint256 price, uint40 deadline, uint256 cap)'
];
const MOLOCH_ALLOWANCE_ABI = ['function setAllowance(address spender, address token, uint256 amount)'];
// ShareOffering keys a sale to a mint sentinel: the DAO's own address mints shares,
// address(1007) mints loot. Loot carries the same ragequit claim on the treasury and no
// vote, so a cause can raise without handing governance to whoever shows up with ETH.
const LOOT_SENTINEL = '0x00000000000000000000000000000000000003EF';
const TAP_VEST = '0x0000000060cdD33cbE020fAE696E70E7507bF56D';

// DUNABrandRenderer — composes the on-chain Wyoming DUNA covenant with a DAO's own
// branding so a cause carries both through the single contractURI() slot.
//
// Moloch.contractURI() returns `_orgURI` when it is set and only reaches the renderer
// when it is empty, so pinning metadata into orgURI (what this file did before, and
// still does when this address is blank) displaces the covenant entirely. The composed
// path instead summons with an EMPTY orgURI and registers the same pinned document on
// the renderer, which re-renders the covenant against live DAO state on every read.
//
// LEAVE THIS EMPTY UNTIL THE CONTRACT IS DEPLOYED. A non-empty address with no code
// would be stored as the DAO's renderer and contractURI() would then decode empty
// returndata — every cause page would break. `coinCauseUsesDUNA()` is the single gate;
// with it false the launch is byte-identical to the pinned-orgURI path it replaces.
// Contract: src/dao/DUNABrandRenderer.sol · tests: test/DUNABrandRenderer.t.sol
const DUNA_RENDERER = '';
const DUNA_RENDERER_ABI = ['function setBranding(string metadata, string image, string launchType)'];

function coinCauseUsesDUNA() {
  return !!DUNA_RENDERER && ethers.isAddress(DUNA_RENDERER) && DUNA_RENDERER !== ZERO_ADDRESS;
}

const SAFE_SUMMONER_ABI = [{
  inputs: [
    { type: 'string', name: 'orgName' },
    { type: 'string', name: 'orgSymbol' },
    { type: 'string', name: 'orgURI' },
    { type: 'uint16', name: 'quorumBps' },
    { type: 'bool', name: 'ragequittable' },
    { type: 'address', name: 'renderer' },
    { type: 'bytes32', name: 'salt' },
    { type: 'address[]', name: 'initHolders' },
    { type: 'uint256[]', name: 'initShares' },
    { type: 'uint256[]', name: 'initLoot' },
    { components: [
      { type: 'uint96', name: 'proposalThreshold' },
      { type: 'uint64', name: 'proposalTTL' },
      { type: 'uint64', name: 'timelockDelay' },
      { type: 'uint96', name: 'quorumAbsolute' },
      { type: 'uint96', name: 'minYesVotes' },
      { type: 'bool', name: 'lockShares' },
      { type: 'bool', name: 'lockLoot' },
      { type: 'uint256', name: 'autoFutarchyParam' },
      { type: 'uint256', name: 'autoFutarchyCap' },
      { type: 'address', name: 'futarchyRewardToken' },
      { type: 'bool', name: 'saleActive' },
      { type: 'address', name: 'salePayToken' },
      { type: 'uint256', name: 'salePricePerShare' },
      { type: 'uint256', name: 'saleCap' },
      { type: 'bool', name: 'saleMinting' },
      { type: 'bool', name: 'saleIsLoot' },
      { type: 'address', name: 'burnSingleton' },
      { type: 'uint256', name: 'saleBurnDeadline' },
      { type: 'address', name: 'rollbackGuardian' },
      { type: 'address', name: 'rollbackSingleton' },
      { type: 'uint40', name: 'rollbackExpiry' }
    ], type: 'tuple', name: 'config' },
    { components: [
      { type: 'address', name: 'singleton' },
      { type: 'address', name: 'payToken' },
      { type: 'uint40', name: 'deadline' },
      { type: 'uint256', name: 'price' },
      { type: 'uint256', name: 'cap' },
      { type: 'bool', name: 'sellLoot' },
      { type: 'bool', name: 'minting' }
    ], type: 'tuple', name: 'sale' },
    { components: [
      { type: 'address', name: 'singleton' },
      { type: 'address', name: 'token' },
      { type: 'uint256', name: 'budget' },
      { type: 'address', name: 'beneficiary' },
      { type: 'uint128', name: 'ratePerSec' }
    ], type: 'tuple', name: 'tap' },
    { components: [
      { type: 'address', name: 'singleton' },
      { type: 'address', name: 'tokenA' },
      { type: 'uint128', name: 'amountA' },
      { type: 'address', name: 'tokenB' },
      { type: 'uint128', name: 'amountB' },
      { type: 'uint40', name: 'deadline' },
      { type: 'bool', name: 'gateBySale' },
      { type: 'uint128', name: 'minSupply' }
    ], type: 'tuple', name: 'seed' },
    { type: 'tuple[]', name: 'extraCalls', components: [
      { type: 'address', name: 'target' },
      { type: 'uint256', name: 'value' },
      { type: 'bytes', name: 'data' }
    ]}
  ],
  name: 'safeSummonDAICO',
  outputs: [{ type: 'address' }],
  stateMutability: 'payable',
  type: 'function'
}];

let _coinTemplate = null;
let _coinLaunchType = 'coin';
let _coinLaunching = false;
let _coinLaunched = false;   // set after a successful deploy — keeps the CTA locked
let _coinImageCID = null;
let _coinImageFile = null;
let _coinBannerCID = null;
let _coinBannerFile = null;

const COIN_MIN_RAISE_WEI = 10n ** 14n; // 0.0001 ETH

// ---- Input parsing ----
// parseFloat -> String -> parseEther round-trips through a double and can emit
// exponent notation ("1e-7") that parseEther rejects, surfacing as a generic
// "Launch failed". Parse the raw string instead so the value the user typed is
// the value that gets deployed, and invalid input fails validation up front.
function coinParseEth(v) {
  const s = String(v == null ? '' : v).trim().replace(/,/g, '');
  if (!s || s === '.' || !/^\d*\.?\d*$/.test(s)) return null;
  try { return ethers.parseEther(s); } catch { return null; }
}

function coinParseCount(v) {
  const s = String(v == null ? '' : v).trim();
  if (!/^\d+$/.test(s)) return null;
  const n = parseInt(s, 10);
  return Number.isSafeInteger(n) ? n : null;
}

// Supply is a whole-token count that can exceed Number.MAX_SAFE_INTEGER, so it
// parses to a bigint rather than going through coinParseCount(). Commas are
// tolerated because the field ships with a comma-grouped default.
function coinParseSupply(v) {
  const s = String(v == null ? '' : v).trim().replace(/,/g, '');
  if (!/^\d+$/.test(s)) return null;
  const n = BigInt(s);
  return n > 0n ? n : null;
}

// A percentage with up to two decimals -> bps, exactly. Parsed as a string for
// the same reason coinParseEth() is: 12.34 * 100 is 1233.9999999999998.
function coinParseAllocBps(v) {
  const s = String(v == null ? '' : v).trim().replace(/,/g, '');
  if (!s) return 0n;
  const m = /^(\d*)(?:\.(\d{0,2})\d*)?$/.exec(s);
  if (!m || (!m[1] && !m[2])) return null;
  return BigInt(m[1] || '0') * 100n + BigInt((m[2] || '').padEnd(2, '0'));
}

function coinAbbrevCount(n) {
  const v = BigInt(n);
  if (v >= 10n ** 12n) return (Number(v / 10n ** 9n) / 1000).toString() + 'T';
  if (v >= 10n ** 9n) return (Number(v / 10n ** 6n) / 1000).toString() + 'B';
  if (v >= 10n ** 6n) return (Number(v / 1000n) / 1000).toString() + 'M';
  if (v >= 1000n) return (Number(v) / 1000).toString() + 'K';
  return v.toString();
}

// Live input sanitizers so the numeric fields can't hold characters that would
// only fail later at submit time.
function coinNumInput(el, decimal) {
  const before = el.value;
  let v = before.replace(decimal ? /[^0-9.]/g : /[^0-9]/g, '');
  if (decimal) {
    const i = v.indexOf('.');
    if (i !== -1) v = v.slice(0, i + 1) + v.slice(i + 1).replace(/\./g, '');
  }
  if (v !== before) {
    const pos = Math.max(0, el.selectionStart - (before.length - v.length));
    el.value = v;
    try { el.setSelectionRange(pos, pos); } catch {}
  }
  coinFormChanged();
}

// Seed a numeric field from a deeplink through the same filter a keystroke gets.
// Deliberately does NOT call coinFormChanged(): the deeplink applies several fields
// and then updates the preview once, and re-entering it per field would also rewrite
// the URL mid-parse from a half-applied form.
function coinSetNumFromURL(id, raw, decimal) {
  const el = $(id);
  if (!el) return;
  let v = String(raw == null ? '' : raw).replace(decimal ? /[^0-9.]/g : /[^0-9]/g, '');
  if (decimal) {
    const i = v.indexOf('.');
    if (i !== -1) v = v.slice(0, i + 1) + v.slice(i + 1).replace(/\./g, '');
  }
  if (v) el.value = v;
}

// Symbols are tickers — uppercase, no whitespace or punctuation.
function coinSymbolInput(el) {
  const before = el.value;
  // 10 chars, matching what the deeplink parser already enforces on a shared link —
  // without this the two disagree and a typed symbol can be longer than a linked one.
  const v = before.toUpperCase().replace(/[^A-Z0-9]/g, '').slice(0, 10);
  if (v !== before) {
    const pos = Math.max(0, el.selectionStart - (before.length - v.length));
    el.value = v;
    try { el.setSelectionRange(pos, pos); } catch {}
  }
  coinFormChanged();
}

// Single entry point for "the user edited the form": clears a finished launch,
// re-runs gating, and keeps the shareable URL in sync.
function coinFormChanged() {
  if (_coinLaunched) { _coinLaunched = false; coinShowStatus(''); }
  coinUpdatePreview();
  syncCoinURL();
}

// Returns a human-readable reason the form can't be submitted, or null if ready.
// Mirrors exactly what coinLaunch() enforces so the CTA and the submit path can
// never disagree.
function coinValidateForm() {
  if (_coinLaunchType === 'nft') return null; // auction.js owns NFT gating
  const name = ($('coinName')?.value || '').trim();
  const symbol = ($('coinSymbol')?.value || '').trim();
  if (name.length < 2) return 'Enter a name (at least 2 characters)';
  if (!symbol) return 'Enter a symbol';

  if (_coinLaunchType === 'coin') {
    const supply = coinParseSupply($('coinSupply').value);
    if (supply === null) return 'Enter a supply';
    const alloc = coinParseAllocBps($('coinAlloc').value);
    if (alloc === null) return 'Enter a valid creator percentage';
    if (alloc > COIN_MAX_ALLOC_BPS) return 'Creator keeps is capped at 20%';
    const mcap = coinParseEth($('coinMcap').value);
    if (mcap === null || mcap < COIN_MIN_MCAP_WEI) return 'Starting market cap is too small to price';
    // The launcher prices the pool off the POOLED supply, so an allocation that
    // leaves too little behind fails there rather than here unless it is caught.
    const pooledWei = supply * 10n ** 18n - (supply * 10n ** 18n * alloc) / 10000n;
    if (pooledWei < COIN_MIN_POOLED) return 'Too little supply reaches the pool to price a market';
    return null;
  }
  if (_coinLaunchType !== 'cause') return null;

  if (!_causeOngoing) {
    const raise = coinParseEth($('causeRaise').value);
    if (raise === null || raise < COIN_MIN_RAISE_WEI) return 'Raise must be at least 0.0001 ETH';
    const days = coinParseCount($('causeDeadline').value);
    if (days === null || days < 1) return 'Deadline must be at least 1 day';
    if (days > 3650) return 'Deadline must be 3650 days or less';
  }
  if (!$('causeTapEnabled').checked) return null;

  const benInput = ($('causeTapBeneficiary')?.value || '').trim();
  if (benInput && !coinGetResolved('causeTapBeneficiary')) return 'Waiting for the beneficiary address to resolve';
  if ($('causeTapInstant').checked) return null;
  if (_causeOngoing) {
    const rate = coinParseEth($('causeTapEthRate').value);
    if (rate === null || rate === 0n) return 'Enter a valid ETH/month rate';
  } else {
    const months = coinParseCount($('causeTapMonths').value);
    if (months === null || months < 1) return 'Vesting duration must be at least 1 month';
    if (months > 1200) return 'Vesting duration must be 1200 months or less';
  }
  return null;
}

function coinApplyValidation() {
  const hint = $('coinFormHint');
  if (_coinLaunching) return;
  if (_coinLaunched) {
    setDisabled('coinLaunchBtn', true);
    if (hint) hint.style.display = 'none';
    return;
  }
  const err = coinValidateForm();
  setDisabled('coinLaunchBtn', !!err);
  if (hint) {
    hint.textContent = err || '';
    hint.style.display = err ? '' : 'none';
  }
}

function coinLaunchBtnLabel() {
  if (_coinLaunched) return 'Launched';
  return _coinLaunchType === 'nft' ? 'List Auction' : 'Launch Coin';
}

// Clear a picked logo/banner without having to re-open the file dialog.
function coinClearImage(kind, ev) {
  if (ev) { ev.preventDefault(); ev.stopPropagation(); }
  const inputId = kind === 'banner' ? 'coinBannerInput' : 'coinImageInput';
  const input = $(inputId);
  if (input) input.value = '';
  if (kind === 'banner') { _coinBannerFile = null; _coinBannerCID = null; }
  else { _coinImageFile = null; _coinImageCID = null; }
  const label = document.querySelector(`label[for="${inputId}"]`);
  const img = label?.querySelector('img');
  if (img) img.remove();
  coinFormChanged();
}

// ---- Generic address/name resolver ----
const _coinResolvers = {};
function _coinResolver(key) {
  if (!_coinResolvers[key]) _coinResolvers[key] = { resolved: null, seq: 0, debounce: null };
  return _coinResolvers[key];
}

function coinGetResolved(inputId) {
  const v = ($(inputId)?.value || '').trim();
  if (!v) return null;
  if (ethers.isAddress(v) && v !== ZERO_ADDRESS) return ethers.getAddress(v);
  const r = _coinResolver(inputId);
  if (r.resolved && r.resolved.input === v && r.resolved.address) return r.resolved.address;
  return null;
}

function onCoinAddressInput(inputId, resolvedId, onResolved) {
  const r = _coinResolver(inputId);
  clearTimeout(r.debounce);
  const v = ($(inputId)?.value || '').trim();
  const el = $(resolvedId);
  r.resolved = null;
  if (!v) {
    el.style.display = 'none';
    if (typeof onResolved === 'function') onResolved();
    return;
  }
  if (ethers.isAddress(v)) {
    el.style.display = 'block';
    el.style.color = 'var(--fg-muted)';
    el.textContent = ethers.getAddress(v);
    r.resolved = { input: v, address: ethers.getAddress(v) };
    if (typeof onResolved === 'function') onResolved();
    return;
  }
  if (v.endsWith('.wei') || v.endsWith('.eth')) {
    el.style.display = 'block';
    el.style.color = 'var(--fg-muted)';
    el.textContent = 'Resolving ' + v + '...';
    r.debounce = setTimeout(() => coinResolveName(inputId, resolvedId, v, onResolved), 350);
  } else {
    el.style.display = 'block';
    el.style.color = 'var(--error)';
    el.textContent = 'Enter 0x address, name.wei, or name.eth';
    if (typeof onResolved === 'function') onResolved();
  }
}

async function coinResolveName(inputId, resolvedId, name, onResolved) {
  const r = _coinResolver(inputId);
  const seq = ++r.seq;
  const el = $(resolvedId);
  try {
    let resolved = null;
    if (name.endsWith('.wei')) {
      resolved = await quoteRPC.call(async (rpc) => {
        const ns = getWeinsContract(rpc);
        const tokenId = await ns.computeId(name);
        const owner = await ns.ownerOf(tokenId).catch(() => null);
        if (!owner || owner === ZERO_ADDRESS) return null;
        return ethers.getAddress(owner);
      });
    } else if (name.endsWith('.eth')) {
      resolved = await quoteRPC.call(async (rpc) => {
        return await rpc.resolveName(name);
      });
    }
    if (seq !== r.seq) return;
    if (resolved && resolved !== ZERO_ADDRESS) {
      r.resolved = { input: name, address: resolved };
      el.style.color = 'var(--fg-muted)';
      el.textContent = resolved;
    } else {
      r.resolved = null;
      el.style.color = 'var(--error)';
      el.textContent = 'Name not found';
    }
    if (typeof onResolved === 'function') onResolved();
  } catch (e) {
    if (seq !== r.seq) return;
    r.resolved = null;
    el.style.color = 'var(--error)';
    el.textContent = 'Failed to resolve ' + name;
    if (typeof onResolved === 'function') onResolved();
  }
}

function _coinAnimSVG(type) {
  // Labels were dropped because they crowded the info tooltip in the top-right
  // corner of the launch card — the icon itself is enough visual context.
  if (type === 'coin') {
    return `<svg viewBox="0 0 48 48" fill="none" xmlns="http://www.w3.org/2000/svg">
        <path class="curve-line" d="M4 42 C14 40, 18 36, 24 30 C30 24, 34 18, 44 14" stroke="var(--fg)" stroke-width="1.5" fill="none" stroke-linecap="round"/>
      </svg>`;
  }
  if (type === 'cause') {
    return `<svg viewBox="0 0 48 48" fill="none" xmlns="http://www.w3.org/2000/svg">
        <rect x="4" y="20" width="40" height="8" rx="2" fill="var(--fg)" opacity="0.15"/>
        <rect class="cause-bar" x="4" y="20" width="32" height="8" rx="2" fill="var(--fg)"/>
      </svg>`;
  }
  // NFT: downward-sloping line (Dutch decay) with a midpoint "current price" dot.
  // Classes match the draw-in animations in index.html (.nft-line, .nft-dot).
  return `<svg viewBox="0 0 48 48" fill="none" xmlns="http://www.w3.org/2000/svg">
      <path class="nft-line" d="M4 10 L44 38" stroke="var(--fg)" stroke-width="1.5" stroke-linecap="round"/>
      <circle class="nft-dot" cx="24" cy="24" r="2.5" fill="var(--fg)"/>
    </svg>`;
}

function coinSetLaunchType(type) {
  _coinLaunchType = type;
  const btns = document.querySelectorAll('#coinTab > .swap-card > .coin-tpl-toggle > .coin-tpl-btn');
  const idx = type === 'coin' ? 0 : (type === 'cause' ? 1 : 2);
  btns.forEach((b, i) => b.classList.toggle('active', i === idx));
  const isCoin = type === 'coin';
  const isNft = type === 'nft';
  const isCause = type === 'cause';
  $('coinCauseWrap').style.display = isCause ? '' : 'none';
  const coinWrap = $('coinCoinWrap'); if (coinWrap) coinWrap.style.display = isCoin ? '' : 'none';
  const nftWrap = $('coinNftWrap'); if (nftWrap) nftWrap.style.display = isNft ? '' : 'none';
  $('coinSimplePreviewWrap').style.display = 'none';
  $('coinCausePreviewWrap').style.display = 'none';
  // Socials have nowhere to live on a coin: its metadata is the document the token
  // assembles itself, which carries a name, a symbol, a description and an image and
  // nothing else. Rather than collect links that would be silently dropped, hide them —
  // same reasoning as NFT mode, different cause.
  $('coinSocialsWrap').style.display = (isNft || isCoin) ? 'none' : '';
  // Banner likewise: on-chain art is the logo only.
  const bannerLabel = document.querySelector('label[for="coinBannerInput"]');
  if (bannerLabel) bannerLabel.style.display = isCoin ? 'none' : '';
  const symWrap = document.querySelector('#coinTab .coin-name-row > .section:nth-child(2)');
  if (symWrap) symWrap.style.display = isNft ? 'none' : '';

  // Buyers see an auction's native tokenURI, so seller-supplied name/description/
  // logo/banner have nowhere to surface — hide the shared display fields in NFT
  // mode rather than collecting input that can never be shown.
  const nameRow = $('coinNameRow');
  const descWrap = $('coinDescWrap');
  const uploadRow = $('coinUploadRow');
  for (const el of [nameRow, descWrap, uploadRow]) {
    if (el) el.style.display = isNft ? 'none' : '';
  }
  // NFT launch button stays disabled until a valid NFT is resolved.
  setDisabled('coinLaunchBtn', true);
  // A success/error banner from the previous mode is meaningless here. Same for
  // the validation hint — NFT mode never re-runs coinApplyValidation, so a stale
  // "Enter a symbol" would otherwise sit under a form that has no symbol field.
  _coinLaunched = false;
  coinShowStatus('');
  const hint = $('coinFormHint');
  if (hint) { hint.textContent = ''; hint.style.display = 'none'; }
  // CTA label should match the selected mode so users know what they're confirming.
  const launchBtn = $('coinLaunchBtn');
  if (launchBtn) launchBtn.textContent = coinLaunchBtnLabel();
  _coinTemplate = isCoin ? null : (isCause ? 'cause' : 'nft-auction');
  // Animate type icon
  const anim = $('coinLaunchAnim');
  if (anim) { anim.innerHTML = _coinAnimSVG(type); }
  if (isNft) { if (typeof auctionOnNftChange === 'function') auctionOnNftChange(); }
  else coinUpdatePreview();
  syncCoinURL();
}


let _causeOngoing = false;
function causeSetOngoing(on) {
  _causeOngoing = on;
  $('causeRaiseWrap').style.display = on ? 'none' : '';
  $('causeDeadlineWrap').style.display = on ? 'none' : '';
  $('causeOngoingWrap').style.display = on ? '' : 'none';
  // Swap rate fields: ongoing uses ETH/month input, fixed uses vesting months
  const instant = $('causeTapInstant').checked;
  $('causeTapMonthsWrap').style.display = (!on && !instant) ? '' : 'none';
  $('causeTapEthRateWrap').style.display = (on && !instant) ? '' : 'none';
  coinFormChanged();
}

function causeTapToggle() {
  $('causeTapFields').style.display = $('causeTapEnabled').checked ? '' : 'none';
  coinFormChanged();
}

function causeTapInstantToggle() {
  const instant = $('causeTapInstant').checked;
  $('causeTapRateFields').style.display = instant ? 'none' : '';
  if (!instant) {
    // Restore correct inner field based on ongoing mode
    $('causeTapMonthsWrap').style.display = _causeOngoing ? 'none' : '';
    $('causeTapEthRateWrap').style.display = _causeOngoing ? '' : 'none';
  }
  coinFormChanged();
}

function coinUpdatePreview() {
  // NFT mode owns its own preview + button gating (auction.js). Falling through
  // here would hit the unconditional setDisabled(false) at the bottom and enable
  // "List Auction" before an NFT is resolved — switchTab('coin') and the
  // ?mode=nft deeplink both call this after coinSetLaunchType('nft').
  if (_coinLaunchType === 'nft') {
    if (typeof auctionUpdatePreview === 'function') auctionUpdatePreview();
    return;
  }

  const ethMini = ETH_ICON.replace('width="24" height="24"', 'width="12" height="12"');

  if (_coinLaunchType === 'cause') {
    const ongoing = _causeOngoing;
    // Fall back to the placeholder defaults while a field is mid-edit so the
    // preview keeps rendering; coinApplyValidation() is what blocks submission.
    const raiseWei = (ongoing ? null : coinParseEth($('causeRaise').value)) ?? ethers.parseEther('10');
    const days = coinParseCount($('causeDeadline').value) ?? 30;
    const totalShares = ongoing ? 'unlimited' : '10M';
    const sellLoot = !!$('causeSellLoot')?.checked;
    const unit = sellLoot ? 'loot' : 'shares';
    const tapOn = $('causeTapEnabled').checked;
    const tapInstant = $('causeTapInstant').checked;
    const tapMonths = coinParseCount($('causeTapMonths').value) ?? 12;
    const tapRateWei = coinParseEth($('causeTapEthRate').value) ?? ethers.parseEther('1');

    // Every figure below is computed from the same bigints coinLaunch() sends,
    // so the preview can't drift from what actually gets deployed.
    const priceWei = ongoing ? ethers.parseEther('0.000001') : raiseWei / 10_000_000n;
    const perDay = (ratePerSec) => {
      const wei = ratePerSec * 86400n;
      const eth = Number(wei) / 1e18;
      return eth < 0.0001 ? eth.toPrecision(2) : eth.toFixed(4);
    };

    let tapDesc = '';
    if (tapOn) {
      if (tapInstant) {
        tapDesc = '<b>Fast</b> <span style="color:var(--fg-dim)">(no vesting; full raise withdrawable in ~1h)</span>';
      } else if (ongoing) {
        const rateWei = tapRateWei / COIN_SEC_PER_MONTH;
        tapDesc = `~<b>${perDay(rateWei)}</b> ${ethMini}/day <span style="color:var(--fg-dim)">(~${ethers.formatEther(tapRateWei)} ${ethMini}/mo)</span>`;
      } else {
        const totalSec = BigInt(tapMonths) * COIN_SEC_PER_MONTH;
        const rateWei = totalSec > 0n ? raiseWei / totalSec : 0n;
        tapDesc = `~<b>${perDay(rateWei)}</b> ${ethMini}/day over ${tapMonths}mo`;
      }
    }

    // Price per 1M shares — priceWei is per whole (1e18) share.
    const perMil = Number(priceWei * 1_000_000n) / 1e18;
    const perMilStr = perMil < 0.0001 ? perMil.toPrecision(2) : perMil >= 1 ? perMil.toFixed(2) : perMil.toFixed(4);
    const p = $('coinCausePreview');
    p.innerHTML =
      `<dl class="coin-summary">` +
      (ongoing
        ? `<dt>Mode</dt><dd><b>Ongoing</b> <span style="color:var(--fg-dim)">(no cap, no deadline)</span></dd>`
        : `<dt>Raise</dt><dd><b>${ethers.formatEther(raiseWei)}</b> ${ethMini}</dd>`) +
      `<dt>${sellLoot ? 'Loot' : 'Shares'}</dt><dd><b>${totalShares}</b> <span style="color:var(--fg-dim)">(proportional to ETH contributed)</span></dd>` +
      `<dt>Price</dt><dd><b>${perMilStr}</b> ${ethMini} per 1M ${unit}</dd>` +
      (ongoing ? '' : `<dt>Deadline</dt><dd><b>${days}</b> days</dd>`) +
      (tapOn ? `<dt>Tap</dt><dd>${tapDesc}</dd>` : '') +
      // The creator buys their own single share at launch, so the tx carries
      // value. Surfacing it avoids a surprise in the wallet confirm dialog.
      `<dt>You pay now</dt><dd><b>${ethers.formatEther(priceWei)}</b> ${ethMini} <span style="color:var(--fg-dim)">(your 1 share) + gas</span></dd>` +
      `</dl>` +
      `<div style="margin-top:8px;font-size:11px;color:var(--fg-muted)">10% quorum &middot; 7d voting &middot; 2d timelock &middot; ragequit &middot; transferable ${unit}</div>` +
      (sellLoot ? `<div style="margin-top:4px;font-size:11px;color:var(--fg-muted)">Your founding share is the whole electorate &mdash; only shares vote and only shares count toward quorum, so you carry every proposal alone. Backers fund the treasury and can ragequit out of it; they cannot govern it.</div>` : '') +
      // Ragequit reaches the treasury, not money already out of it. A fast tap empties
      // the treasury in about an hour, so the two together leave a backer with the least
      // of any combination this form can produce — which is worth saying at the moment
      // both boxes are ticked, not in a doc nobody opens.
      (sellLoot && tapOn && tapInstant
        ? `<div style="margin-top:4px;font-size:11px;color:var(--fg-muted)">With a fast tap, the raise reaches the beneficiary in about an hour, and ragequit only reaches what is still in the treasury.</div>`
        : '') +
      // Say which legal wrapper the DAO launches under, and be honest about where
      // it lives: composed into contractURI itself, or declared in the metadata
      // while contractURI carries the pin.
      `<div style="margin-top:4px;font-size:11px;color:var(--fg-muted)">Wyoming DUNA covenant &middot; ${coinCauseUsesDUNA() ? 'rendered on-chain alongside your branding' : 'declared in metadata'}</div>`;
    $('coinCausePreviewWrap').style.display = '';
    $('coinSimplePreviewWrap').style.display = 'none';
    coinApplyValidation();
    return;
  }

  if (_coinLaunchType === 'coin') {
    // Every figure here is derived from the same bigints coinLaunch() sends, so
    // the preview cannot drift from what actually gets deployed.
    const supply = coinParseSupply($('coinSupply').value) ?? 1_000_000_000n;
    const allocBps = coinParseAllocBps($('coinAlloc').value) ?? 0n;
    const mcapWei = coinParseEth($('coinMcap').value) ?? ethers.parseEther('30');
    const supplyWei = supply * 10n ** 18n;
    const allocWei = (supplyWei * allocBps) / 10000n;
    const pooledWei = supplyWei - allocWei;

    // The pool opens one-sided: `mcapWei` is its virtual ETH reserve against
    // `pooledWei` of token, so the marginal opening price is their ratio, and a
    // buy of `x` ether takes x/(mcap+x) of the pooled supply.
    const priceWei = pooledWei > 0n ? (mcapWei * 10n ** 18n) / pooledWei : 0n;
    // Net of the 1% swap fee, which the pool takes off the input — quoting this
    // gross would overstate the first buy by a percent and make the preview a
    // slightly optimistic number rather than a true one.
    const oneEth = (10n ** 18n * 99n) / 100n;
    const firstEth = pooledWei > 0n ? (pooledWei * oneEth) / (mcapWei + oneEth) : 0n;
    const firstPct = pooledWei > 0n ? (Number(firstEth * 10000n / pooledWei) / 100) : 0;
    const fmtTok = (wei) => coinAbbrevCount(wei / 10n ** 18n);
    const priceStr = priceWei === 0n ? '0'
      : Number(priceWei) / 1e18 < 0.00000001 ? Number(priceWei / 1n).toExponential(2) + ' wei'
      : (Number(priceWei) / 1e18).toPrecision(3);
    const allocPct = Number(allocBps) / 100;

    const p = $('coinSimplePreview');
    p.innerHTML =
      `<dl class="coin-summary">` +
      `<dt>Supply</dt><dd><b>${coinAbbrevCount(supply)}</b> tokens <span style="color:var(--fg-dim)">(18 decimals)</span></dd>` +
      `<dt>Into the pool</dt><dd><b>${fmtTok(pooledWei)}</b> <span style="color:var(--fg-dim)">(${(100 - allocPct)}% of supply, one-sided)</span></dd>` +
      (allocBps ? `<dt>You keep</dt><dd><b>${fmtTok(allocWei)}</b> <span style="color:var(--fg-dim)">(${allocPct}%, unlocked, at launch)</span></dd>` : '') +
      `<dt>Opening price</dt><dd><b>${priceStr}</b> ${ethMini} per token</dd>` +
      // `startMcapWei` values the POOLED supply, so with an allocation the fully
      // diluted number is higher by supply/(supply-alloc). Saying only the one you
      // typed would understate the dilution by exactly what you kept.
      (allocBps ? `<dt>Fully diluted</dt><dd><b>${(Number(ethers.formatEther(mcapWei)) * Number(supplyWei) / Number(pooledWei)).toFixed(2)}</b> ${ethMini} <span style="color:var(--fg-dim)">(your ${allocPct}% included)</span></dd>` : '') +
      `<dt>First ${ethMini}1 buys</dt><dd><b>${fmtTok(firstEth)}</b> <span style="color:var(--fg-dim)">(${firstPct < 0.01 ? '<0.01' : firstPct.toFixed(2)}% of the pool)</span></dd>` +
      `<dt>Swap fee</dt><dd><b>1%</b> <span style="color:var(--fg-dim)">(half retained as reserves, raising the floor)</span></dd>` +
      `<dt>You pay now</dt><dd><b>0</b> ${ethMini} <span style="color:var(--fg-dim)">(gas only)</span></dd>` +
      `</dl>` +
      `<div style="margin-top:8px;font-size:11px;color:var(--fg-muted)">Full-range pool on zFi&rsquo;s AMM &middot; liquidity locked in the launcher &middot; collectable fees split 80% creator / 10% protocol / 10% burned to Ethereum</div>` +
      `<div style="margin-top:4px;font-size:11px;color:var(--fg-muted)">Holders can always burn back to the launcher for their share of the pool&rsquo;s ether.</div>` +
      `<div style="margin-top:4px;font-size:11px;color:var(--fg-muted)">Name, symbol, description and logo are stored on the token as contract code &mdash; no IPFS, nothing to pin, no gateway to go dark. All editable later.</div>`;
    $('coinSimplePreviewWrap').style.display = '';
    $('coinCausePreviewWrap').style.display = 'none';
  }
  coinApplyValidation();
}

function coinFilePicked(input, type) {
  const file = input.files[0];
  if (!file) return;
  const label = type === 'banner' ? 'Banner' : 'Logo';
  if (!/^image\//.test(file.type)) {
    coinShowStatus(`${label} must be an image file`, true);
    input.value = '';
    return;
  }
  if (file.size > 5 * 1024 * 1024) {
    coinShowStatus(`${label} is ${(file.size / 1048576).toFixed(1)}MB — 5MB max`, true);
    input.value = '';
    return;
  }
  if (type === 'banner') { _coinBannerFile = file; _coinBannerCID = null; }
  else { _coinImageFile = file; _coinImageCID = null; }
  // Look the label up by `for` rather than walking siblings — the upload row gets
  // relocated into the NFT drawer, and the old sibling guess broke on reorder.
  const btn = document.querySelector(`label[for="${input.id}"]`) || input.previousElementSibling;
  const reader = new FileReader();
  reader.onload = () => {
    if (!btn) return;
    // Append rather than clearing textContent, which would also delete the
    // "remove" button and the placeholder label. CSS hides the label via :has(img).
    let img = btn.querySelector('img');
    if (!img) { img = document.createElement('img'); img.alt = ''; btn.appendChild(img); }
    img.src = reader.result;
  };
  reader.readAsDataURL(file);
  coinFormChanged();
}

function coinSvgEsc(s) { return s.replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;'); }

function coinGenerateLogo(text) {
  const t = coinSvgEsc(text.slice(0, 12));
  return `<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024"><rect width="1024" height="1024" fill="#000"/><text x="512" y="512" text-anchor="middle" dominant-baseline="central" font-family="Helvetica, Arial, Liberation Sans, sans-serif" font-size="${Math.min(300, Math.floor(900 / text.slice(0,12).length))}" font-weight="400" fill="#fff">${t}</text></svg>`;
}

function coinGenerateBanner(text) {
  const raw = text.slice(0, 12) + ' coin';
  const t = coinSvgEsc(raw);
  return `<svg xmlns="http://www.w3.org/2000/svg" width="1500" height="500" viewBox="0 0 1500 500"><rect width="1500" height="500" fill="#000"/><text x="750" y="250" text-anchor="middle" dominant-baseline="central" font-family="Helvetica, Arial, Liberation Sans, sans-serif" font-size="${Math.min(200, Math.floor(1300 / raw.length))}" font-weight="400" fill="#fff">${t}</text></svg>`;
}

function coinSvgToFile(svg, filename) {
  return new File([svg], filename, { type: 'image/svg+xml' });
}

// ---- On-chain art ----
// Squeeze an image down to something worth putting in calldata. Ported from the
// zSwap launcher form so a coin launched from either page compresses identically.
// Tries progressively smaller sides and lossier encodings, returns the first that
// fits the budget, and falls back to the smallest that at least fits the contract.
const _coinBlobText = b => b.text ? b.text() : new Promise((res, rej) => {
  const r = new FileReader(); r.onload = () => res(String(r.result)); r.onerror = () => rej(r.error); r.readAsText(b);
});
const _coinBlobBytes = async b => b.arrayBuffer ? new Uint8Array(await b.arrayBuffer()) : await new Promise((res, rej) => {
  const r = new FileReader(); r.onload = () => res(new Uint8Array(r.result)); r.onerror = () => rej(r.error); r.readAsArrayBuffer(b);
});

async function coinPrepareArt(file) {
  // SVG is already the smallest form of a flat mark — strip the parts a renderer
  // does not need rather than rasterising something that was never a bitmap.
  if (/svg/.test(file.type)) {
    const bytes = new TextEncoder().encode((await _coinBlobText(file))
      .replace(/<\?xml[^>]*\?>/g, '').replace(/<!--[\s\S]*?-->/g, '').replace(/<!DOCTYPE[^>]*>/gi, '')
      .replace(/>\s+</g, '><').trim());
    if (bytes.length > COIN_MAX_ART) {
      throw new Error(`That SVG is ${(bytes.length / 1024).toFixed(1)} KB and the on-chain limit is 24 KB.`);
    }
    return { bytes, mime: COIN_MIME['image/svg+xml'] };
  }
  const bmp = await createImageBitmap(file);
  let smallest = null;
  for (const side of [512, 384, 256, 192, 128, 96, 64]) {
    for (const [type, q] of [['image/webp', 1], ['image/png', undefined], ['image/webp', 0.85], ['image/webp', 0.6]]) {
      const sc = Math.min(1, side / Math.max(bmp.width, bmp.height));
      const cv = document.createElement('canvas');
      cv.width = Math.max(1, Math.round(bmp.width * sc));
      cv.height = Math.max(1, Math.round(bmp.height * sc));
      const cx = cv.getContext('2d');
      cx.imageSmoothingQuality = 'high';
      cx.drawImage(bmp, 0, 0, cv.width, cv.height);
      const blob = await new Promise(r => cv.toBlob(r, type, q));
      // A browser that cannot encode the requested type hands back a PNG under the
      // wrong label, which would be stored with a mime that does not match its bytes.
      if (!blob || blob.type !== type) continue;
      const bytes = await _coinBlobBytes(blob);
      if (!smallest || bytes.length < smallest.bytes.length) smallest = { bytes, mime: COIN_MIME[type] };
      if (bytes.length <= COIN_ART_BUDGET) return { bytes, mime: COIN_MIME[type] };
    }
  }
  if (smallest && smallest.bytes.length <= COIN_MAX_ART) return smallest;
  throw new Error('That image will not compress small enough. Flat colours and simple shapes do far better than photographs.');
}

async function coinPinFile(file, cachedCID) {
  if (!file) return null;
  if (cachedCID) return cachedCID;
  if (!COIN_PIN_URL) throw new Error('Pin service not configured (set COIN_PIN_URL)');
  const form = new FormData();
  form.append('file', file, file.name);
  const res = await fetch(COIN_PIN_URL + '/pin-image', { method: 'POST', body: form });
  const data = await res.json();
  if (!res.ok) throw new Error(data.error || 'Image pin failed');
  if (!data.cid) throw new Error('Pin service returned no CID');
  return data.cid;
}

// Inline fallbacks for when no pin service is configured. Both percent-encode.
// The JSON one carries free text (name, description, socials), so it can't be
// pasted raw into a URI — one space, quote, or `#` and the URI is truncated or
// invalid. The SVG one only carries the sanitized symbol today, but it went
// through btoa(), which throws on the first non-Latin1 character it is ever
// handed. Encoding both the same way removes both edges.
function coinDataUriJson(obj) {
  return 'data:application/json;charset=utf-8,' + encodeURIComponent(JSON.stringify(obj));
}

function coinDataUriSvg(svg) {
  return 'data:image/svg+xml;charset=utf-8,' + encodeURIComponent(svg);
}

async function coinPinMetadata(metadata) {
  if (!COIN_PIN_URL) return coinDataUriJson(metadata);
  const res = await fetch(COIN_PIN_URL + '/pin-json', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(metadata),
  });
  const data = await res.json();
  if (!res.ok) throw new Error(data.error || 'Metadata pin failed');
  if (!data.cid) throw new Error('Metadata pin returned no CID');
  return 'ipfs://' + data.cid;
}

function coinMinimalProxy(impl) {
  return ethers.concat([COIN_CLONE_PREFIX, impl.toLowerCase(), COIN_CLONE_SUFFIX]);
}

function coinCreate2(deployer, salt, impl) {
  const hash = ethers.keccak256(ethers.solidityPacked(
    ['bytes1','address','bytes32','bytes32'],
    ['0xff', deployer, salt, ethers.keccak256(coinMinimalProxy(impl))]
  ));
  return ethers.getAddress('0x' + hash.slice(-40));
}

function coinPredict(initHolders, initShares, salt) {
  const abiCoder = new ethers.AbiCoder();
  const summonerSalt = ethers.keccak256(abiCoder.encode(['address[]','uint256[]','bytes32'], [initHolders, initShares, salt]));
  const dao = coinCreate2(COIN_SUMMONER, summonerSalt, COIN_IMPLS.moloch);
  const childSalt = '0x' + dao.toLowerCase().replace('0x','') + '000000000000000000000000';
  const shares = coinCreate2(dao, childSalt, COIN_IMPLS.shares);
  const loot = coinCreate2(dao, childSalt, COIN_IMPLS.loot);
  return { dao, shares, loot };
}

function coinShowStatus(msg, isError) {
  const el = $('coinStatus');
  const cls = isError ? 'status-message error' : msg.includes('Launched') ? 'status-message success' : 'status-message';
  const spinner = msg.includes('...') && !isError && !msg.includes('Launch') ? zfiLoadingSVG(14) : '';
  el.innerHTML = `<div class="${cls}">${spinner}${msg}</div>`;
}

async function coinLaunch() {
  if (_coinLaunching) return;
  if (!_signer) { connectWallet(); return; }
  // NFT auction path is owned by auction.js — dispatch early.
  if (_coinLaunchType === 'nft') { return auctionLaunch(); }

  const name = $('coinName').value.trim();
  const symbol = $('coinSymbol').value.trim();
  const desc = $('coinDescription').value.trim();
  // Backstop for the CTA gating — same rules, so the two can't disagree.
  const invalid = coinValidateForm();
  if (invalid) { coinShowStatus(invalid, true); return; }

  let launched = false;
  _coinLaunching = true;
  setDisabled('coinLaunchBtn', true);
  const _pg = $('coinLaunchProgress');
  _pg.classList.remove('active');
  // Force reflow to restart animation
  void _pg.offsetWidth;
  _pg.classList.add('active');

  try {
    const address = await _signer.getAddress();
    coinShowStatus('Preparing coin launch...');

    // --- PrecisionLauncher path: nothing off-chain ---
    // No pin, no CID, no gateway. The launcher stores the image as contract code and
    // assembles the whole ERC-7572 document on read, so the coin describes itself with
    // no external dependency — which is also why this path returns before the IPFS
    // block below that the cause path still needs.
    if (_coinLaunchType === 'coin') {
      const supply = coinParseSupply($('coinSupply').value) ?? 0n;
      const supplyWei = supply * 10n ** 18n;
      const mcapWei = coinParseEth($('coinMcap').value) ?? 0n;
      const allocBps = coinParseAllocBps($('coinAlloc').value) ?? 0n;

      // A launch always carries a mark. With no upload the generated SVG goes
      // on-chain too — it is a few hundred bytes and it means no coin ever renders
      // as a broken image.
      coinShowStatus(_coinImageFile ? 'Compressing logo\u2026' : 'Generating logo\u2026');
      const art = await coinPrepareArt(_coinImageFile
        || coinSvgToFile(coinGenerateLogo(symbol), 'logo.svg'));

      const launchIface = new ethers.Interface(PRECISION_LAUNCH_ABI);
      const data = launchIface.encodeFunctionData('launchWithArt', [
        name,                       // token name
        symbol,                     // token symbol
        desc,                       // becomes the document's `description`
        supplyWei,                  // total supply, 18 decimals
        allocBps,                   // creator allocation, bps of supply
        mcapWei,                    // opening valuation of the POOLED supply, in wei
        address,                    // owner: metadata rights, creator fees, allocation
        '0x' + Array.from(art.bytes, b => b.toString(16).padStart(2, '0')).join(''),
        art.mime
      ]);

      coinShowStatus('Please confirm the transaction in your wallet...');
      const tx = await _signer.sendTransaction({ to: PRECISION_LAUNCHER, data });
      coinShowStatus(`Transaction submitted. <a href="https://etherscan.io/tx/${tx.hash}" target="_blank">${tx.hash.slice(0,10)}...</a> Waiting for confirmation...`);
      const receipt = await tx.wait();

      // The token address is CREATE-derived from the launcher's nonce, so unlike the
      // CREATE2 path this replaced it cannot be predicted before the tx — the event
      // is the only source.
      let tokenAddress = null, poolAddress = null;
      const launchedTopic = ethers.id('Launched(address,address,address,uint256,uint256,uint256)');
      for (const log of receipt.logs) {
        if (log.topics[0] === launchedTopic && log.address.toLowerCase() === PRECISION_LAUNCHER.toLowerCase()) {
          tokenAddress = ethers.getAddress('0x' + log.topics[1].slice(26));
          poolAddress = ethers.getAddress('0x' + log.topics[2].slice(26));
          break;
        }
      }

      // The coin list is enumerated from the launcher and cached, so without this a
      // creator who just launched would not find their own coin on the list they get
      // sent to.
      if (tokenAddress) window.launchRegistry?.note(tokenAddress);

      const allocPct = Number(allocBps) / 100;
      launched = true;
      coinShowStatus(
        `<strong>Launched!</strong> <strong>${escText(name)}</strong> ($${escText(symbol)})<br><br>` +
        (tokenAddress ? `Token: <a href="https://etherscan.io/address/${tokenAddress}" target="_blank">${tokenAddress}</a><br>` : '') +
        `Supply: ${coinAbbrevCount(supply)} &middot; Pooled: ${allocBps ? (100 - allocPct) + '%' : '100%'}` +
        (allocBps ? ` &middot; You keep: ${allocPct}%` : '') + `<br>` +
        `Opening market cap: ${ethers.formatEther(mcapWei)} ETH &middot; 1% swap fee<br>` +
        `<span style="font-size:11px;color:var(--fg-dim)">Name, symbol, description and logo all live on the token itself</span><br><br>` +
        `<a href="https://etherscan.io/tx/${tx.hash}" target="_blank">View tx</a>` +
        (tokenAddress ? ` &middot; <a href="./coin/#${tokenAddress}">View Coin</a>` : '') +
        (poolAddress ? ` &middot; <a href="https://etherscan.io/address/${poolAddress}" target="_blank">Pool</a>` : '')
      );
      return;
    }

    // Pin images + metadata to IPFS (or fallback to data URI). Cause only — the coin
    // path returned above with everything on-chain.
    const metadata = { name, symbol };
    if (desc) metadata.description = desc;
    const twitter = $('coinTwitter').value.trim().replace(/^@/,'');
    const telegram = $('coinTelegram').value.trim().replace(/^@/,'');
    const discord = $('coinDiscord').value.trim();
    if (twitter) metadata.twitter = twitter;
    if (telegram) metadata.telegram = telegram;
    if (discord) metadata.discord = discord;
    if (_coinTemplate) metadata.template = _coinTemplate;
    metadata.launchType = 'cause';
    metadata.creatorWallet = address;
    // Which token the sale mints. The chain says the same thing through the offering's
    // `token` sentinel; recording it here lets a reader label the raise before any
    // contract read lands.
    if ($('causeSellLoot')?.checked) metadata.saleToken = 'loot';
    // Declare the charter in the pinned document too, not only in the composed
    // renderer output. On the composed path this is belt-and-braces; on the pinned
    // path it is the only record, and it still points a reader at a renderer that
    // regenerates this DAO's covenant against live state.
    metadata.charter = 'duna';
    metadata.charterSource = 'eip155:1:' + (coinCauseUsesDUNA() ? DUNA_RENDERER : COIN_RENDERER);
    if (_coinImageFile) {
      coinShowStatus('Uploading logo to IPFS...');
      _coinImageCID = await coinPinFile(_coinImageFile, _coinImageCID);
      metadata.image = 'ipfs://' + _coinImageCID;
    } else {
      const logoSvg = coinGenerateLogo(symbol);
      if (COIN_PIN_URL) {
        coinShowStatus('Generating logo...');
        const logoCID = await coinPinFile(coinSvgToFile(logoSvg, 'logo.svg'), null);
        metadata.image = 'ipfs://' + logoCID;
      } else {
        metadata.image = coinDataUriSvg(logoSvg);
      }
    }
    if (_coinBannerFile) {
      coinShowStatus('Uploading banner to IPFS...');
      _coinBannerCID = await coinPinFile(_coinBannerFile, _coinBannerCID);
      metadata.banner = 'ipfs://' + _coinBannerCID;
    } else {
      const bannerSvg = coinGenerateBanner(symbol);
      if (COIN_PIN_URL) {
        coinShowStatus('Generating banner...');
        const bannerCID = await coinPinFile(coinSvgToFile(bannerSvg, 'banner.svg'), null);
        metadata.banner = 'ipfs://' + bannerCID;
      } else {
        metadata.banner = coinDataUriSvg(bannerSvg);
      }
    }
    coinShowStatus('Pinning metadata...');
    const orgURI = await coinPinMetadata(metadata);

    const salt = ethers.hexlify(ethers.randomBytes(32));

    // --- Cause DAICO path (SafeSummoner.safeSummonDAICO) ---
    if (_coinLaunchType === 'cause') {
      const ongoing = _causeOngoing;
      // Sell loot rather than shares: same ragequit claim on the treasury, no vote. The
      // founder's single share is minted either way, so a loot raise leaves governance
      // with the creator instead of handing it to whoever buys in.
      const sellLoot = !!$('causeSellLoot')?.checked;
      // coinValidateForm() already rejected unparseable input; `?? 0n` only keeps
      // the ongoing branch (where these fields are hidden) from reading null.
      const raiseWei = ongoing ? 0n : (coinParseEth($('causeRaise').value) ?? 0n);
      const days = ongoing ? 0 : (coinParseCount($('causeDeadline').value) ?? 0);

      let priceWei, capShares, deadline;
      if (ongoing) {
        // Ongoing: 1 ETH = 1M shares, no cap, no deadline
        priceWei = ethers.parseEther('0.000001'); // 1e-6 ETH per share
        capShares = ethers.MaxUint256;
        deadline = 0n;
      } else {
        // Fixed 10M shares, price derived from raise
        // Cap is 9,999,999 because creator's 1 share is minted at deploy (total supply = 10M)
        const totalShares = 10_000_000n;
        priceWei = raiseWei / totalShares;
        // Integer division can floor to 0 for dust raises, which would make the
        // sale free and mint the whole cap to the first caller.
        if (priceWei === 0n) throw new Error('Raise is too small — increase it so each share costs at least 1 wei');
        capShares = ethers.parseEther(String(totalShares - 1n));
        deadline = BigInt(Math.floor(Date.now() / 1000)) + BigInt(days) * 86400n;
      }

      const tapEnabled = $('causeTapEnabled').checked;
      const tapInstant = $('causeTapInstant').checked;
      const MAX_UINT128 = (1n << 128n) - 1n;
      let tapModule = {
        singleton: ZERO_ADDRESS, token: ZERO_ADDRESS, budget: 0n,
        beneficiary: ZERO_ADDRESS, ratePerSec: 0n
      };
      if (tapEnabled) {
        const benInput = ($('causeTapBeneficiary')?.value || '').trim();
        const beneficiary = coinGetResolved('causeTapBeneficiary') || (benInput ? null : address);
        if (!beneficiary) throw new Error('Beneficiary address is not yet resolved — wait for it, or paste a 0x address');
        let budgetWei, rate;
        if (tapInstant) {
          // TapVest pays out min(ratePerSec * elapsed, budget, treasury) and needs
          // that to come to at least one whole second of vesting, so the treasury has
          // to hold >= ratePerSec before any of it is claimable. ratePerSec therefore
          // sets both the drain speed and the smallest claimable treasury, and the two
          // trade off directly: a rate equal to the full raise only unlocks once the
          // sale has filled completely.
          //
          // COIN_TAP_FAST_SEC drains the whole raise over an hour of accrual and keeps
          // any treasury above 1/3600th of the goal claimable, so a partly-filled
          // sale still reaches its beneficiary. test/CauseLaunchSim.t.sol pins both
          // the gate and this arithmetic.
          budgetWei = ongoing ? ethers.MaxUint256 : raiseWei;
          rate = ongoing ? COIN_TAP_FAST_ONGOING_RATE : raiseWei / COIN_TAP_FAST_SEC;
          if (rate === 0n) rate = 1n;
        } else if (ongoing) {
          // Ongoing: user-specified ETH/month rate, unlimited budget
          budgetWei = ethers.MaxUint256;
          rate = (coinParseEth($('causeTapEthRate').value) ?? 0n) / COIN_SEC_PER_MONTH;
          if (rate === 0n) rate = 1n;
        } else {
          // Fixed: budget = raise, rate = budget / months
          const tapMonths = coinParseCount($('causeTapMonths').value) ?? 0;
          budgetWei = raiseWei;
          const totalSec = BigInt(tapMonths) * COIN_SEC_PER_MONTH;
          rate = totalSec > 0n ? budgetWei / totalSec : 0n;
          if (rate === 0n && budgetWei > 0n) rate = 1n;
        }
        if (rate > MAX_UINT128) rate = MAX_UINT128;
        tapModule = {
          singleton: TAP_VEST, token: ZERO_ADDRESS, budget: budgetWei,
          beneficiary, ratePerSec: rate
        };
      }

      // The sale is wired by hand below rather than through SafeSummoner's SaleModule,
      // which can only emit ShareSale's four-argument configure. Leaving the module empty
      // keeps SafeSummoner from granting an allowance to a singleton nothing will use.
      const saleModule = {
        singleton: ZERO_ADDRESS, payToken: ZERO_ADDRESS, deadline: 0n,
        price: 0n, cap: 0n, sellLoot: false, minting: false
      };
      const seedModule = {
        singleton: ZERO_ADDRESS, tokenA: ZERO_ADDRESS, amountA: 0n,
        tokenB: ZERO_ADDRESS, amountB: 0n, deadline: 0n,
        gateBySale: false, minSupply: 0n
      };

      const initHolders = [address];
      const initShares = [ethers.parseEther('1')]; // creator gets 1 share

      // SafeConfig: standard DAICO governance with quorumAbsolute for minting sale (KF#2)
      const PROPOSAL_THRESHOLD = ethers.parseEther('1'); // 1 share minimum to propose
      const safeConfig = {
        proposalThreshold: PROPOSAL_THRESHOLD,
        proposalTTL: BigInt(7 * 86400), // 7 days
        timelockDelay: BigInt(2 * 86400), // 2 days
        quorumAbsolute: PROPOSAL_THRESHOLD, // floor for minting sale safety
        minYesVotes: 0n,
        lockShares: false,
        lockLoot: false,
        autoFutarchyParam: 0n,
        autoFutarchyCap: 0n,
        futarchyRewardToken: ZERO_ADDRESS,
        saleActive: false,
        salePayToken: ZERO_ADDRESS,
        salePricePerShare: 0n,
        saleCap: 0n,
        saleMinting: false,
        saleIsLoot: false,
        burnSingleton: ZERO_ADDRESS,
        saleBurnDeadline: 0n,
        rollbackGuardian: ZERO_ADDRESS,
        rollbackSingleton: ZERO_ADDRESS,
        rollbackExpiry: 0n
      };

      // Covenant + branding, or branding alone. The composed path hands Moloch an
      // empty orgURI so contractURI() falls through to DUNABrandRenderer, and seeds
      // the branding through extraCalls — those execute from the DAO's own context
      // during init, so this costs no extra transaction and no extra signature.
      const useDUNA = coinCauseUsesDUNA();
      const summonURI = useDUNA ? '' : orgURI;
      const renderer = useDUNA ? DUNA_RENDERER : COIN_RENDERER;
      const extraCalls = useDUNA
        ? [[
            DUNA_RENDERER,
            0n,
            new ethers.Interface(DUNA_RENDERER_ABI).encodeFunctionData('setBranding', [orgURI, metadata.image, 'cause'])
          ]]
        : [];

      // Wire the sale to ShareOffering. Both calls run from the DAO's own context during
      // init: setAllowance is onlyDAO, and configure keys the sale to msg.sender, so the
      // DAO has to be the one making them. The address is predicted rather than known
      // because none of this exists until the summon returns.
      const predictedDao = coinPredict(initHolders, initShares, salt).dao;
      // The ceiling is a target SUPPLY, so the founder's single share counts toward it.
      // Everything else the offering may mint is sold.
      // Shares and loot are counted separately, and the founder's share only lands in the
      // shares supply — so the loot ceiling is the sellable amount outright, while the
      // shares ceiling has to carry that one founding share on top of it. Either way
      // 9,999,999 units are for sale and the raise comes to the number on the form.
      const supplyCap = ongoing ? ethers.MaxUint256
        : ethers.parseEther(sellLoot ? '9999999' : '10000000');
      // Allowance is the outer bound on everything this contract may ever mint; the cap
      // is the live one. It has to exceed the cap or it becomes the binding number again
      // and refunds start shrinking the sale exactly as they did before.
      // Both the allowance and the sale are keyed to the same mint sentinel, or the
      // offering holds permission to mint one token and terms describing the other.
      const saleToken = sellLoot ? LOOT_SENTINEL : predictedDao;
      extraCalls.push(
        [predictedDao, 0n, new ethers.Interface(MOLOCH_ALLOWANCE_ABI)
          .encodeFunctionData('setAllowance', [SHARE_OFFERING, saleToken, ethers.MaxUint256])],
        [SHARE_OFFERING, 0n, new ethers.Interface(SHARE_OFFERING_ABI)
          .encodeFunctionData('configure', [saleToken, ZERO_ADDRESS, priceWei, deadline, supplyCap])]
      );

      coinShowStatus('Please confirm the transaction in your wallet...');
      const safeSummoner = new ethers.Contract(SAFE_SUMMONER, SAFE_SUMMONER_ABI, _signer);
      const tx = await safeSummoner.safeSummonDAICO(
        name, symbol, summonURI,
        1000, // quorumBps: 10%
        true, // ragequittable
        renderer,
        salt,
        initHolders, initShares,
        [], // initLoot
        safeConfig,
        saleModule, tapModule, seedModule,
        extraCalls,
        { value: priceWei } // creator pays for their 1 share — full ragequit symmetry
      );

      coinShowStatus(`Transaction submitted. <a href="https://etherscan.io/tx/${tx.hash}" target="_blank">${tx.hash.slice(0,10)}...</a> Waiting for confirmation...`);
      const receipt = await tx.wait();

      const predicted = coinPredict(initHolders, initShares, salt);
      const daoAddress = predicted.dao; // === predictedDao, recomputed for shares/loot

      // Report the rate actually encoded in tapModule rather than recomputing
      // from the form, so the receipt can't disagree with the deployed vest.
      let tapSummary = '';
      if (tapEnabled) {
        if (tapInstant) {
          tapSummary = 'Tap: Fast &middot; no vesting, full raise withdrawable in ~1h<br>';
        } else {
          const perDayEth = Number(tapModule.ratePerSec * 86400n) / 1e18;
          const perMoEth = Number(tapModule.ratePerSec * COIN_SEC_PER_MONTH) / 1e18;
          tapSummary = `Tap: ~${perDayEth.toFixed(4)} ETH/day (~${perMoEth.toFixed(4)} ETH/mo)<br>`;
        }
      }
      launched = true;
      coinShowStatus(
        `<strong>Launched!</strong> <strong>${escText(name)}</strong> ($${escText(symbol)})<br><br>` +
        `DAO: <a href="https://etherscan.io/address/${daoAddress}" target="_blank">${daoAddress}</a><br>` +
        (ongoing
          ? `Sale: Ongoing &middot; 1 ETH = 1M ${sellLoot ? 'loot' : 'shares'}<br>`
          : `Sale: ${ethers.formatEther(raiseWei)} ETH &middot; 10M ${sellLoot ? 'loot' : 'shares'} &middot; ${days}d<br>`) +
        (sellLoot ? `Backers hold non-voting loot &middot; you keep the vote<br>` : '') +
        tapSummary +
        `<br><a href="https://etherscan.io/tx/${tx.hash}" target="_blank">View tx</a>` +
        ` &middot; <a href="./coin/#${daoAddress}">View Coin</a>` +
        ` &middot; <a href="./dao/#/dao/1/${daoAddress}">Manage DAO</a>` +
        (useDUNA ? `<br><span style="font-size:11px;color:var(--fg-dim)">Operating under the Wyoming DUNA covenant, rendered on-chain</span>` : '')
      );
      return;
    }

  } catch (e) {
    if ((e.message || '').toLowerCase().includes('user rejected') || e.code === 'ACTION_REJECTED') {
      coinShowStatus('Launch cancelled', false);
    } else {
      const msg = e.shortMessage || e.reason || (e.message || '').split('\n')[0];
      coinShowStatus(escText(msg.length < 120 ? msg : 'Launch failed'), true);
    }
  } finally {
    _coinLaunching = false;
    // Leave the CTA locked after a success: the form still describes a coin that
    // now exists, and a second click would deploy a duplicate. Editing any field
    // (coinFormChanged) or switching mode clears the lock.
    _coinLaunched = launched;
    const btn = $('coinLaunchBtn');
    if (btn) btn.textContent = coinLaunchBtnLabel();
    coinApplyValidation();
    $('coinLaunchProgress').classList.remove('active');
  }
}

// end COIN TAB
