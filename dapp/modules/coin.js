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
const COIN_SHARE_BURNER = '0x000000000040084694F7B6fb2846D067B4c3Aa9f';

const COIN_PIN_URL = 'https://api.zfi.wei.is';

// ClassicalCurveSale deployment
const CLASSICAL_CURVE_SALE = '0x000000005d9b18764E12E5aeefD6dA73110F85eb';
const CLASSICAL_TOKEN_IMPL = '0xC54843C7419B3B7813d4C1065dA7f88104cdb047';
const CLASSICAL_LAUNCH_ABI = [
  'function launch(address,string,string,string,uint256,bytes32,uint256,uint256,uint256,uint16,uint256,uint256,address,uint16,uint16,uint16,uint16,tuple(address,uint16,uint16,bool,bool),uint40,uint40) returns (address)'
];

const SAFE_SUMMONER = '0x00000000004473e1f31C8266612e7FD5504e6f2a';
const SHARE_SALE = '0x0000000021ea5069B532CeE09058aB9e02EA60f9';
const TAP_VEST = '0x0000000060cdD33cbE020fAE696E70E7507bF56D';
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

// Symbols are tickers — uppercase, no whitespace or punctuation.
function coinSymbolInput(el) {
  const before = el.value;
  const v = before.toUpperCase().replace(/[^A-Z0-9]/g, '');
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
  const nftWrap = $('coinNftWrap'); if (nftWrap) nftWrap.style.display = isNft ? '' : 'none';
  $('coinCurvePreviewWrap').style.display = 'none';
  $('coinCausePreviewWrap').style.display = 'none';
  // Socials irrelevant for NFT auctions; symbol field too (single asset, no ticker).
  $('coinSocialsWrap').style.display = isNft ? 'none' : '';
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
        tapDesc = 'Instant (all funds to beneficiary)';
      } else if (ongoing) {
        const rateWei = tapRateWei / COIN_SEC_PER_MONTH;
        tapDesc = `~${perDay(rateWei)} ${ethMini}/day (~${ethers.formatEther(tapRateWei)} ${ethMini}/mo)`;
      } else {
        const totalSec = BigInt(tapMonths) * COIN_SEC_PER_MONTH;
        const rateWei = totalSec > 0n ? raiseWei / totalSec : 0n;
        tapDesc = `~${perDay(rateWei)} ${ethMini}/day over ${tapMonths}mo`;
      }
    }

    // Price per 1M shares — priceWei is per whole (1e18) share.
    const perMil = Number(priceWei * 1_000_000n) / 1e18;
    const perMilStr = perMil < 0.0001 ? perMil.toPrecision(2) : perMil >= 1 ? perMil.toFixed(2) : perMil.toFixed(4);
    const p = $('coinCausePreview');
    p.innerHTML =
      `<dl class="coin-summary">` +
      (ongoing
        ? `<dt>Mode</dt><dd>Ongoing (no cap, no deadline)</dd>`
        : `<dt>Raise</dt><dd>${ethers.formatEther(raiseWei)} ${ethMini}</dd>`) +
      `<dt>Shares</dt><dd>${totalShares} (proportional to ETH contributed)</dd>` +
      `<dt>Price</dt><dd>${perMilStr} ${ethMini} per 1M shares</dd>` +
      (ongoing ? '' : `<dt>Deadline</dt><dd>${days} days</dd>`) +
      (tapOn ? `<dt>Tap</dt><dd>${tapDesc}</dd>` : '') +
      // The creator buys their own single share at launch, so the tx carries
      // value. Surfacing it avoids a surprise in the wallet confirm dialog.
      `<dt>You pay now</dt><dd>${ethers.formatEther(priceWei)} ${ethMini} <span style="color:var(--fg-dim)">(your 1 share) + gas</span></dd>` +
      `</dl>` +
      `<div style="margin-top:8px;font-size:11px;color:var(--fg-muted)">10% quorum &middot; 7d voting &middot; 2d timelock &middot; ragequit &middot; transferable shares</div>`;
    $('coinCausePreviewWrap').style.display = '';
    $('coinCurvePreviewWrap').style.display = 'none';
    coinApplyValidation();
    return;
  }

  if (_coinLaunchType === 'coin') {
    const p = $('coinCurvePreview');
    p.innerHTML =
      `<dl class="coin-summary">` +
      `<dt>Supply</dt><dd>1B tokens (18 decimals)</dd>` +
      `<dt>Curve</dt><dd>800M on bonding curve</dd>` +
      `<dt>LP Seed</dt><dd>200M tokens at graduation</dd>` +
      `<dt>Graduation</dt><dd>~5.33 ${ethMini} raised &rarr; LP seeded</dd>` +
      `<dt>Price Range</dt><dd>16x from start to graduation</dd>` +
      `<dt>Trade Fee</dt><dd>1% &rarr; creator</dd>` +
      `<dt>Sniper Fee</dt><dd>5% first 5 min (decays to 1%)</dd>` +
      `<dt>Max Buy</dt><dd>10% per tx</dd>` +
      `<dt>You pay now</dt><dd>0 ${ethMini} <span style="color:var(--fg-dim)">(gas only)</span></dd>` +
      `</dl>` +
      `<div style="margin-top:8px;font-size:11px;color:var(--fg-muted)">LP tokens burned (permanent liquidity) &middot; 0.25% pool fee post-graduation &middot; 0.05% creator fee post-graduation</div>`;
    $('coinCurvePreviewWrap').style.display = '';
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

    // Pin images + metadata to IPFS (or fallback to data URI)
    const metadata = { name, symbol };
    if (desc) metadata.description = desc;
    const twitter = $('coinTwitter').value.trim().replace(/^@/,'');
    const telegram = $('coinTelegram').value.trim().replace(/^@/,'');
    const discord = $('coinDiscord').value.trim();
    if (twitter) metadata.twitter = twitter;
    if (telegram) metadata.telegram = telegram;
    if (discord) metadata.discord = discord;
    if (_coinTemplate) metadata.template = _coinTemplate;
    if (_coinLaunchType === 'coin') {
      metadata.launchType = 'curve';
      metadata.creator = '';
      metadata.creatorWallet = address;
    } else {
      metadata.launchType = 'cause';
      metadata.creatorWallet = address;
    }
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
          // All funds flow directly to beneficiary — use raise/sec rate so entire
          // treasury drains in 1 second. TapVest requires advance = claimed/rate >= 1,
          // so rate must be <= expected treasury to avoid NothingToClaim revert.
          budgetWei = ongoing ? ethers.MaxUint256 : raiseWei;
          rate = ongoing ? ethers.parseEther('1000') : raiseWei; // raise ETH/sec
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

      const saleModule = {
        singleton: SHARE_SALE, payToken: ZERO_ADDRESS, deadline,
        price: priceWei, cap: capShares, sellLoot: false, minting: true
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

      coinShowStatus('Please confirm the transaction in your wallet...');
      const safeSummoner = new ethers.Contract(SAFE_SUMMONER, SAFE_SUMMONER_ABI, _signer);
      const tx = await safeSummoner.safeSummonDAICO(
        name, symbol, orgURI,
        1000, // quorumBps: 10%
        true, // ragequittable
        '0x000000000011C799980827F52d3137b4abD6E654', // RENDERER
        salt,
        initHolders, initShares,
        [], // initLoot
        safeConfig,
        saleModule, tapModule, seedModule,
        [], // extraCalls
        { value: priceWei } // creator pays for their 1 share — full ragequit symmetry
      );

      coinShowStatus(`Transaction submitted. <a href="https://etherscan.io/tx/${tx.hash}" target="_blank">${tx.hash.slice(0,10)}...</a> Waiting for confirmation...`);
      const receipt = await tx.wait();

      const predicted = coinPredict(initHolders, initShares, salt);
      const daoAddress = predicted.dao;

      // Report the rate actually encoded in tapModule rather than recomputing
      // from the form, so the receipt can't disagree with the deployed vest.
      let tapSummary = '';
      if (tapEnabled) {
        if (tapInstant) {
          tapSummary = 'Tap: Instant (all funds to beneficiary)<br>';
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
          ? `Sale: Ongoing &middot; 1 ETH = 1M shares<br>`
          : `Sale: ${ethers.formatEther(raiseWei)} ETH &middot; 10M shares &middot; ${days}d<br>`) +
        tapSummary +
        `<br><a href="https://etherscan.io/tx/${tx.hash}" target="_blank">View tx</a>` +
        ` &middot; <a href="./coin/#${daoAddress}">View Coin</a>` +
        ` &middot; <a href="./dao/#/dao/1/${daoAddress}">Manage DAO</a>`
      );
      return;
    }

    // --- ClassicalCurveSale path ---
    if (_coinLaunchType === 'coin') {
      // onchain contractURI = IPFS pointer or data URI with full metadata
      const metadataUri = orgURI;

      const launchIface = new ethers.Interface(CLASSICAL_LAUNCH_ABI);

      // CREATE2 prediction: salt = keccak256(abi.encode(sender, name, symbol, salt))
      // Init code = PUSH0 minimal proxy (same pattern as coinMinimalProxy)
      const abiCoder = new ethers.AbiCoder();

      // Mine for vanity address starting with 0x00 (~2000 attempts, ~99.96% chance)
      // Yield every 200 iterations to keep UI responsive
      coinShowStatus('Mining vanity address...');
      let bestSalt = salt;
      let bestAddr = null;
      const VANITY_ATTEMPTS = 2000;
      for (let i = 0; i < VANITY_ATTEMPTS; i++) {
        if (i > 0 && i % 200 === 0) await new Promise(r => setTimeout(r, 0));
        const trySalt = ethers.hexlify(ethers.randomBytes(32));
        const create2Salt = ethers.keccak256(abiCoder.encode(
          ['address', 'string', 'string', 'bytes32'],
          [address, name, symbol, trySalt]
        ));
        const addr = coinCreate2(CLASSICAL_CURVE_SALE, create2Salt, CLASSICAL_TOKEN_IMPL);
        if (addr.startsWith('0x00')) {
          bestSalt = trySalt;
          bestAddr = addr;
          break;
        }
        bestSalt = trySalt;
        bestAddr = addr;
      }

      coinShowStatus('Please confirm the transaction in your wallet...');
      const data = launchIface.encodeFunctionData('launch', [
        address,                                    // creator
        name,                                       // name
        symbol,                                     // symbol
        metadataUri,                                // uri (IPFS pointer or inline JSON fallback)
        '1000000000000000000000000000',             // supply: 1B tokens
        bestSalt,                                   // salt
        '800000000000000000000000000',              // cap: 800M
        '1666666667',                               // startPrice
        '26666666672',                              // endPrice
        100,                                        // feeBps: 1%
        '0',                                        // graduationTarget: sell full cap
        '200000000000000000000000000',              // lpTokens: 200M
        ethers.ZeroAddress,                         // lpRecipient: burn (permanent LP)
        25,                                         // poolFeeBps: 0.25%
        500,                                        // sniperFeeBps: 5%
        300,                                        // sniperDuration: 5 min
        1000,                                       // maxBuyBps: 10%
        [address, 5, 5, true, false],               // creatorFee tuple
        0,                                          // vestCliff
        0                                           // vestDuration
      ]);

      const tx = await _signer.sendTransaction({ to: CLASSICAL_CURVE_SALE, data });
      coinShowStatus(`Transaction submitted. <a href="https://etherscan.io/tx/${tx.hash}" target="_blank">${tx.hash.slice(0,10)}...</a> Waiting for confirmation...`);
      const receipt = await tx.wait();

      // Token address: use predicted address or parse from TokenCreated event
      let tokenAddress = bestAddr;
      const tokenCreatedTopic = ethers.id('TokenCreated(address,address)');
      for (const log of receipt.logs) {
        if (log.topics[0] === tokenCreatedTopic && log.address.toLowerCase() === CLASSICAL_CURVE_SALE.toLowerCase()) {
          tokenAddress = ethers.getAddress('0x' + log.topics[2].slice(26));
          break;
        }
      }

      // The coin list is rebuilt from the sale's launch logs and cached for five
      // minutes, so without this a creator who just launched would not find their
      // own coin on the list they get sent to.
      if (tokenAddress) window.curveRegistry?.note(tokenAddress);

      launched = true;
      coinShowStatus(
        `<strong>Launched!</strong> <strong>${escText(name)}</strong> ($${escText(symbol)})<br><br>` +
        (tokenAddress ? `Token: <a href="https://etherscan.io/address/${tokenAddress}" target="_blank">${tokenAddress}</a><br>` : '') +
        `Supply: 1B &middot; Curve: 800M &middot; LP: 200M<br>` +
        `16x price range &middot; ~5.33 ETH graduation<br><br>` +
        `<a href="https://etherscan.io/tx/${tx.hash}" target="_blank">View tx</a>` +
        (tokenAddress ? ` &middot; <a href="./coin/#${tokenAddress}">View Coin</a>` : '')
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
