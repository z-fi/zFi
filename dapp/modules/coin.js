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

const COIN_PIN_URL = 'https://zfi-pin.rosscampbell9.workers.dev';

// DB proxy — writes go through the worker which holds the Supabase service_role key
// and enforces origin checks + source tagging server-side
const COIN_DB_URL = COIN_PIN_URL; // same worker, /db/ routes

async function coinDbInsert(table, row) {
  if (!COIN_DB_URL) return;
  try {
    await fetch(`${COIN_DB_URL}/db/${table}`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(row)
    });
  } catch (e) {
    console.warn('DB insert failed:', table, e);
  }
}

async function coinDbUpdate(table, match, updates) {
  if (!COIN_DB_URL) return;
  try {
    const params = Object.entries(match).map(([k,v]) => `${k}=eq.${encodeURIComponent(v)}`).join('&');
    await fetch(`${COIN_DB_URL}/db/${table}?${params}`, {
      method: 'PATCH',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(updates)
    });
  } catch (e) {
    console.warn('DB update failed:', table, e);
  }
}

async function coinDbFetch(table, params) {
  if (!COIN_DB_URL) return [];
  try {
    const res = await fetch(`${COIN_DB_URL}/db/${table}?${params}`);
    return await res.json();
  } catch (e) {
    console.warn('DB fetch failed:', table, e);
    return [];
  }
}

function coinGenId() {
  return crypto.randomUUID().slice(0, 12);
}

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
let _coinImageCID = null;
let _coinImageFile = null;
let _coinBannerCID = null;
let _coinBannerFile = null;

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
  const label = type === 'coin' ? 'just trade it' : 'just fund it';
  const svg = type === 'coin'
    ? `<svg viewBox="0 0 48 48" fill="none" xmlns="http://www.w3.org/2000/svg">
        <path class="curve-line" d="M4 42 C14 40, 18 36, 24 30 C30 24, 34 18, 44 14" stroke="var(--fg)" stroke-width="1.5" fill="none" stroke-linecap="round"/>
      </svg>`
    : `<svg viewBox="0 0 48 48" fill="none" xmlns="http://www.w3.org/2000/svg">
        <rect x="4" y="20" width="40" height="8" rx="2" fill="var(--fg)" opacity="0.15"/>
        <rect class="cause-bar" x="4" y="20" width="32" height="8" rx="2" fill="var(--fg)"/>
      </svg>`;
  return `<span class="coin-launch-anim-label">${label}</span>${svg}`;
}

function coinSetLaunchType(type) {
  _coinLaunchType = type;
  const btns = document.querySelectorAll('#coinTab > .swap-card > .coin-tpl-toggle > .coin-tpl-btn');
  btns.forEach((b, i) => b.classList.toggle('active', i === (type === 'coin' ? 0 : 1)));
  const isCoin = type === 'coin';
  $('coinCauseWrap').style.display = isCoin ? 'none' : '';
  $('coinCurvePreviewWrap').style.display = 'none';
  $('coinCausePreviewWrap').style.display = 'none';
  $('coinSocialsWrap').style.display = '';
  setDisabled('coinLaunchBtn', true);
  _coinTemplate = isCoin ? null : 'cause';
  // Animate type icon
  const anim = $('coinLaunchAnim');
  if (anim) { anim.innerHTML = _coinAnimSVG(type); }
  coinUpdatePreview();
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
  coinUpdatePreview();
}

function causeTapToggle() {
  $('causeTapFields').style.display = $('causeTapEnabled').checked ? '' : 'none';
  coinUpdatePreview();
}

function causeTapInstantToggle() {
  const instant = $('causeTapInstant').checked;
  $('causeTapRateFields').style.display = instant ? 'none' : '';
  if (!instant) {
    // Restore correct inner field based on ongoing mode
    $('causeTapMonthsWrap').style.display = _causeOngoing ? 'none' : '';
    $('causeTapEthRateWrap').style.display = _causeOngoing ? '' : 'none';
  }
  coinUpdatePreview();
}

function coinUpdatePreview() {
  const ethMini = ETH_ICON.replace('width="24" height="24"', 'width="12" height="12"');

  if (_coinLaunchType === 'cause') {
    const raise = parseFloat($('causeRaise').value) || 10;
    const days = parseInt($('causeDeadline').value) || 30;
    const ongoing = _causeOngoing;
    const totalShares = ongoing ? 'unlimited' : '10M';
    const tapOn = $('causeTapEnabled').checked;
    const tapInstant = $('causeTapInstant').checked;
    const tapMonths = parseInt($('causeTapMonths').value) || 12;
    const tapEthRate = parseFloat($('causeTapEthRate').value) || 1;
    let tapDesc = '';
    if (tapOn) {
      if (tapInstant) {
        tapDesc = 'Instant (all funds to beneficiary)';
      } else if (ongoing) {
        // Match contract: rate = parseEther(ethPerMonth) / COIN_SEC_PER_MONTH, display as rate * 86400
        const rateWei = ethers.parseEther(String(tapEthRate)) / COIN_SEC_PER_MONTH;
        const ratePerDay = Number(rateWei) * 86400 / 1e18;
        const rateStr = ratePerDay < 0.0001 ? ratePerDay.toPrecision(2) : ratePerDay.toFixed(4);
        tapDesc = `~${rateStr} ${ethMini}/day (~${tapEthRate} ${ethMini}/mo)`;
      } else {
        // Match contract: budget = parseEther(raise), rate = budget / (months * SEC_PER_MONTH)
        const budgetWei = ethers.parseEther(String(raise));
        const totalSec = BigInt(tapMonths) * COIN_SEC_PER_MONTH;
        const rateWei = totalSec > 0n ? budgetWei / totalSec : 0n;
        const ratePerDay = Number(rateWei) * 86400 / 1e18;
        const rateStr = ratePerDay < 0.0001 ? ratePerDay.toPrecision(2) : ratePerDay.toFixed(4);
        tapDesc = `~${rateStr} ${ethMini}/day over ${tapMonths}mo`;
      }
    }
    // Pricing info for capped sales
    let priceLine = '';
    if (!ongoing) {
      const pricePerShare = raise / 10_000_000;
      const ethPerMil = pricePerShare * 1_000_000;
      const ethPerMilStr = ethPerMil < 0.0001 ? ethPerMil.toPrecision(2) : ethPerMil >= 1 ? ethPerMil.toFixed(2) : ethPerMil.toFixed(4);
      priceLine = `<dt>Price</dt><dd>${ethPerMilStr} ${ethMini} per 1M shares</dd>`;
    }
    const p = $('coinCausePreview');
    p.innerHTML =
      `<dl class="coin-summary">` +
      (ongoing
        ? `<dt>Mode</dt><dd>Ongoing (no cap, no deadline)</dd>`
        : `<dt>Raise</dt><dd>${raise} ${ethMini}</dd>`) +
      `<dt>Shares</dt><dd>${totalShares} (proportional to ETH contributed)</dd>` +
      priceLine +
      (ongoing ? '' : `<dt>Deadline</dt><dd>${days} days</dd>`) +
      (tapOn ? `<dt>Tap</dt><dd>${tapDesc}</dd>` : '') +
      `</dl>` +
      `<div style="margin-top:8px;font-size:11px;color:var(--fg-muted)">10% quorum &middot; 7d voting &middot; 2d timelock &middot; ragequit &middot; transferable shares</div>`;
    $('coinCausePreviewWrap').style.display = '';
    $('coinCurvePreviewWrap').style.display = 'none';
    setDisabled('coinLaunchBtn', false);
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
      `</dl>` +
      `<div style="margin-top:8px;font-size:11px;color:var(--fg-muted)">LP tokens burned (permanent liquidity) &middot; 0.25% pool fee post-graduation &middot; 0.05% creator fee post-graduation</div>`;
    $('coinCurvePreviewWrap').style.display = '';
    $('coinCausePreviewWrap').style.display = 'none';
  }
  setDisabled('coinLaunchBtn', false);
}

function coinFilePicked(input, type) {
  const file = input.files[0];
  if (!file) return;
  if (file.size > 5 * 1024 * 1024) { alert('Too large (5MB max)'); input.value = ''; return; }
  if (type === 'banner') { _coinBannerFile = file; _coinBannerCID = null; }
  else { _coinImageFile = file; _coinImageCID = null; }
  const btn = input.previousElementSibling.tagName === 'LABEL' ? input.previousElementSibling : input.nextElementSibling;
  const reader = new FileReader();
  reader.onload = () => {
    let img = btn.querySelector('img');
    if (!img) { img = document.createElement('img'); btn.textContent = ''; btn.appendChild(img); }
    img.src = reader.result;
  };
  reader.readAsDataURL(file);
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

async function coinPinMetadata(metadata) {
  if (!COIN_PIN_URL) return 'data:application/json;utf8,' + JSON.stringify(metadata);
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

  const name = $('coinName').value.trim();
  const symbol = $('coinSymbol').value.trim();
  const desc = $('coinDescription').value.trim();
  if (!name || name.length < 2) { coinShowStatus('Enter a name (at least 2 characters)', true); return; }
  if (!symbol || symbol.length < 1) { coinShowStatus('Enter a symbol', true); return; }

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
        metadata.image = 'data:image/svg+xml;base64,' + btoa(logoSvg);
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
        metadata.banner = 'data:image/svg+xml;base64,' + btoa(bannerSvg);
      }
    }
    coinShowStatus('Pinning metadata...');
    const orgURI = await coinPinMetadata(metadata);

    const salt = ethers.hexlify(ethers.randomBytes(32));

    // --- Cause DAICO path (SafeSummoner.safeSummonDAICO) ---
    if (_coinLaunchType === 'cause') {
      const raiseRaw = parseFloat($('causeRaise').value);
      const daysRaw = parseInt($('causeDeadline').value);
      const ongoing = _causeOngoing;
      const raise = ongoing ? 0 : raiseRaw;
      const days = ongoing ? 0 : daysRaw;
      if (!ongoing && (isNaN(raise) || raise < 0.0001)) {
        coinShowStatus('Raise must be at least 0.0001 ETH', true);
        _coinLaunching = false; setDisabled('coinLaunchBtn', false); $('coinLaunchProgress').classList.remove('active'); return;
      }
      if (!ongoing && (isNaN(days) || days <= 0)) {
        coinShowStatus('Enter a valid deadline (at least 1 day)', true);
        _coinLaunching = false; setDisabled('coinLaunchBtn', false); $('coinLaunchProgress').classList.remove('active'); return;
      }

      let priceWei, capShares, deadline;
      if (ongoing) {
        // Ongoing: 1 ETH = 1M shares, no cap, no deadline
        priceWei = ethers.parseEther('0.000001'); // 1e-6 ETH per share
        capShares = ethers.MaxUint256;
        deadline = 0n;
      } else {
        // Fixed 10M shares, price derived from raise
        // Cap is 9,999,999 because creator's 1 share is minted at deploy (total supply = 10M)
        const totalShares = 10_000_000;
        priceWei = ethers.parseEther(String(raise)) / BigInt(totalShares);
        capShares = ethers.parseEther(String(totalShares - 1));
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
        if (!beneficiary) {
          coinShowStatus('Beneficiary address is not yet resolved — wait for it to resolve or enter a 0x address', true);
          _coinLaunching = false; setDisabled('coinLaunchBtn', false); $('coinLaunchProgress').classList.remove('active'); return;
        }
        let budgetWei, rate;
        if (tapInstant) {
          // All funds flow directly to beneficiary — use raise/sec rate so entire
          // treasury drains in 1 second. TapVest requires advance = claimed/rate >= 1,
          // so rate must be <= expected treasury to avoid NothingToClaim revert.
          budgetWei = ongoing ? ethers.MaxUint256 : ethers.parseEther(String(raise));
          rate = ongoing ? ethers.parseEther('1000') : ethers.parseEther(String(raise)); // raise ETH/sec
        } else if (ongoing) {
          // Ongoing: user-specified ETH/month rate, unlimited budget
          const ethPerMonth = parseFloat($('causeTapEthRate').value);
          if (isNaN(ethPerMonth) || ethPerMonth <= 0) {
            coinShowStatus('Enter a valid ETH/month rate', true);
            _coinLaunching = false; setDisabled('coinLaunchBtn', false); $('coinLaunchProgress').classList.remove('active'); return;
          }
          budgetWei = ethers.MaxUint256;
          rate = ethers.parseEther(String(ethPerMonth)) / COIN_SEC_PER_MONTH;
          if (rate === 0n) rate = 1n;
        } else {
          // Fixed: budget = raise, rate = budget / months
          const tapMonths = parseInt($('causeTapMonths').value);
          if (isNaN(tapMonths) || tapMonths <= 0) {
            coinShowStatus('Enter a valid vesting duration (at least 1 month)', true);
            _coinLaunching = false; setDisabled('coinLaunchBtn', false); $('coinLaunchProgress').classList.remove('active'); return;
          }
          budgetWei = ethers.parseEther(String(raise));
          const totalSec = BigInt(tapMonths) * COIN_SEC_PER_MONTH;
          rate = budgetWei / totalSec;
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

      // Register in Supabase
      if (daoAddress && COIN_DB_URL) {
        const now = new Date().toISOString();
        const tokenId = coinGenId();
        const roomId = coinGenId();
        (async () => {
          try {
            await coinDbInsert('gated_rooms', {
              id: roomId, name: '$' + symbol.toUpperCase(),
              creator: address.toLowerCase(),
              token_address: predicted.shares.toLowerCase(),
              token_type: 'ERC20', min_balance: ethers.parseEther('1').toString(),
              avatar: metadata.image || null, description: desc || null,
              created_at: now
            });
            await coinDbInsert('gated_room_members', {
              room_id: roomId, user_name: address.toLowerCase(),
              wallet_address: address.toLowerCase(), joined_at: now
            });
            await coinDbInsert('launched_tokens', {
              id: tokenId, creator: address.toLowerCase(),
              token_address: daoAddress.toLowerCase(),
              name: name.slice(0, 50), symbol: symbol.toUpperCase().slice(0, 10),
              image: metadata.image || null, room_id: roomId,
              description: desc ? desc.slice(0, 280) : null,
              launch_type: 'cause', metadata_uri: orgURI || null,
              tx_hash: tx.hash, created_at: now
            });
          } catch (e) { console.warn('Supabase registration failed:', e); }
        })();
      }

      let tapSummary = '';
      if (tapEnabled) {
        if (tapInstant) {
          tapSummary = 'Tap: Instant (all funds to beneficiary)<br>';
        } else if (ongoing) {
          const ethPerMonth = parseFloat($('causeTapEthRate').value) || 1;
          tapSummary = `Tap: ~${(ethPerMonth / 30.44).toFixed(4)} ETH/day (~${ethPerMonth} ETH/mo)<br>`;
        } else {
          tapSummary = `Tap: ~${(raise / (parseInt($('causeTapMonths').value) * 30.44)).toFixed(4)} ETH/day<br>`;
        }
      }
      coinShowStatus(
        `<strong>Launched!</strong> <strong>${escText(name)}</strong> ($${escText(symbol)})<br><br>` +
        `DAO: <a href="https://etherscan.io/address/${daoAddress}" target="_blank">${daoAddress}</a><br>` +
        (ongoing
          ? `Sale: Ongoing &middot; 1 ETH = 1M shares<br>`
          : `Sale: ${raise} ETH &middot; 10M shares &middot; ${days}d<br>`) +
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

      // Register in Supabase for discoverability
      if (tokenAddress && COIN_DB_URL) {
        const now = new Date().toISOString();
        const tokenId = coinGenId();
        const roomId = coinGenId();
        // Fire-and-forget: don't block success display on DB writes
        (async () => {
          try {
            // 1. Create gated room
            await coinDbInsert('gated_rooms', {
              id: roomId,
              name: '$' + symbol.toUpperCase(),
              creator: address.toLowerCase(),
              token_address: tokenAddress.toLowerCase(),
              token_type: 'ERC20',
              min_balance: '1000000000000000000', // 1 token (18 decimals)
              avatar: metadata.image || null,
              description: desc || null,
              created_at: now
            });
            // 2. Add creator as first room member
            await coinDbInsert('gated_room_members', {
              room_id: roomId,
              user_name: address.toLowerCase(),
              wallet_address: address.toLowerCase(),
              joined_at: now
            });
            // 3. Insert token record with tx_hash (confirmed)
            await coinDbInsert('launched_tokens', {
              id: tokenId,
              creator: address.toLowerCase(),
              token_address: tokenAddress.toLowerCase(),
              name: name.slice(0, 50),
              symbol: symbol.toUpperCase().slice(0, 10),
              image: metadata.image || null,
              room_id: roomId,
              description: desc ? desc.slice(0, 280) : null,
              launch_type: 'curve', metadata_uri: orgURI || null,
              tx_hash: tx.hash,
              created_at: now
            });
          } catch (e) {
            console.warn('Supabase registration failed:', e);
          }
        })();
      }

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
    setDisabled('coinLaunchBtn', false);
    $('coinLaunchProgress').classList.remove('active');
  }
}

// end COIN TAB
