// ---- Send Tab ----
const ERC20_TRANSFER_ABI = [
  "function transfer(address to, uint256 amount) returns (bool)",
  "function approve(address spender, uint256 amount) returns (bool)",
  "function allowance(address owner, address spender) view returns (uint256)",
  "function balanceOf(address) view returns (uint256)",
  "function decimals() view returns (uint8)",
  "function symbol() view returns (string)"
];
// SLOW protocol — time-delayed transfers with reverse / clawback / optional keeper tip.
// Verified source: 0x000000000000888741B254d37e1b27128AfEAaBC
const SLOW_ADDRESS = "0x000000000000888741B254d37e1b27128AfEAaBC";
const SLOW_ABI = [
  "function gate() view returns (address)",
  "function depositTo(address token, address to, uint256 amount, uint96 delay, bytes data) payable returns (uint256)",
  "function depositToWithTip(address token, address to, uint256 amount, uint96 delay, uint256 tip, bytes data) payable returns (uint256)",
  "function getOutboundTransfers(address user) view returns (uint256[])",
  "function getInboundTransfers(address user) view returns (uint256[])",
  "function outboundTransferCount(address user) view returns (uint256)",
  "function inboundTransferCount(address user) view returns (uint256)",
  "function pendingTransfers(uint256) view returns (uint96 timestamp, address from, address to, uint256 id, uint256 amount)",
  "function guardians(address) view returns (address)",
  "function predictTransferId(address from, address to, uint256 id, uint256 amount) view returns (uint256)",
  "function decodeId(uint256 id) pure returns (address token, uint256 delay)",
  "function claim(uint256 transferId)",
  "function unlock(uint256 transferId)",
  "function reverse(uint256 transferId)",
  "function clawback(uint256 transferId)",
  "function withdrawFrom(address from, address to, uint256 id, uint256 amount)",
  "function balanceOf(address account, uint256 id) view returns (uint256)",
  "function multicall(bytes[] data) returns (bytes[])",
  "event TransferPending(uint256 indexed transferId, uint256 indexed delay)",
  "event TransferClaimed(uint256 indexed transferId)",
  "event TransferReversed(uint256 indexed transferId)",
  "event TransferClawedBack(uint256 indexed transferId)"
];
const SLOW_GATE_ABI = [
  "function tips(uint256) view returns (uint96 amount, address sender)",
  "function claim(uint256 transferId)",
  "function claimMany(uint256[] transferIds)",
  "function refundTip(uint256 transferId)"
];
const SLOW_CLAWBACK_GRACE = 30 * 86400; // sender clawback unlocks at expiry + 30d

let _sendToken = 'ETH';
let _sendResolvedAddr = null;
let _sendResolveSeq = 0;
let _sendDebounce = null;
let _sendTokenBal = null;
let _sendTokenDec = 18;

// SLOW delay state
let _sendDelaySecs = 0;
let _sendAutoClaim = false;
let _sendTipWei = 0n;
let _slowGateAddr = null;
let _slowHasGuardian = false; // refreshed on sendLoadSlowTransfers
let _slowFocusTransferId = null; // deep-link target — set via ?xfer=, cleared after first highlight
const _slowTokenMetaCache = new Map();
let _slowLoadSeq = 0;        // stale-response guard for concurrent list loads
let _slowRefreshTimer = null; // periodic refresh so PENDING rows flip to CLAIMABLE on their own
let _slowBusy = 0;           // in-flight claim/reverse/clawback count — suppresses auto-refresh
let _sendTxInFlight = false; // guards against double-submitting a send

// User-rejected-in-wallet, as opposed to an on-chain/RPC failure.
function _sendIsUserReject(e) {
  return e && (e.code === 'ACTION_REJECTED' || e.code === 4001 || e.info?.error?.code === 4001);
}

function sendUpdateTokenDisplay() {
  const t = tokens[_sendToken];
  if (!t) return;
  setHTML('sendTokenIcon', iconForSymbol(_sendToken));
  setText('sendTokenSymbol', t.symbol || _sendToken);
}

async function sendUpdateBalance() {
  const balEl = $('sendBalanceText');
  if (!_connectedAddress) { balEl.textContent = 'Balance: --'; return; }
  const sym = _sendToken;
  const t = tokens[sym];
  if (!t) { balEl.textContent = 'Balance: --'; return; }
  try {
    const rpc = await quoteRPC.call(r => r);
    if (t.address === ZERO_ADDRESS) {
      const bal = await rpc.getBalance(_connectedAddress);
      _sendTokenBal = bal;
      _sendTokenDec = 18;
      balEl.textContent = 'Balance: ' + (+ethers.formatEther(bal)).toFixed(5) + ' ' + sym;
    } else {
      const c = new ethers.Contract(t.address, ERC20_TRANSFER_ABI, rpc);
      const [bal, dec] = await Promise.all([c.balanceOf(_connectedAddress), c.decimals().catch(() => t.decimals || 18)]);
      _sendTokenBal = bal;
      _sendTokenDec = Number(dec);
      balEl.textContent = 'Balance: ' + (+ethers.formatUnits(bal, _sendTokenDec)).toFixed(5) + ' ' + sym;
    }
  } catch {
    balEl.textContent = 'Balance: --';
  }
  sendUpdateButton();
}

function sendSetMax() {
  if (_sendTokenBal != null && _sendTokenBal > 0n) {
    $('sendAmount').value = ethers.formatUnits(_sendTokenBal, _sendTokenDec);
  }
}

function sendUpdateButton() {
  const btn = $('sendBtn');
  if (!btn) return;
  if (_sendTxInFlight) { btn.disabled = true; return; }
  if (!_connectedAddress) { btn.disabled = false; btn.textContent = 'Connect Wallet'; return; }
  btn.disabled = false;
  if (_sendDelaySecs > 0) btn.textContent = _sendAutoClaim ? 'Send via SLOW (auto-claim)' : 'Send via SLOW';
  else btn.textContent = 'Send';
}

// Toggle the Delay option panel.
function sendToggleOption(which) {
  const wrap = $('sendDelayWrap');
  const chev = $('sendDelayChevron');
  if (!wrap) return;
  const opening = wrap.style.maxHeight === '0px' || wrap.style.maxHeight === '';
  wrap.style.maxHeight = opening ? '260px' : '0px';
  wrap.style.opacity = opening ? '1' : '0';
  if (chev) chev.innerHTML = opening ? '&#9660;' : '&#9654;';
  if (!opening) sendClearDelaySelection();
  sendUpdateButton();
}

function sendClearDelaySelection() {
  _sendDelaySecs = 0;
  _sendAutoClaim = false;
  _sendTipWei = 0n;
  document.querySelectorAll('#sendDelayChips .delay-chip').forEach(b => b.classList.remove('active'));
  const c = $('sendDelayCustom'); if (c) c.value = '';
  const ac = $('sendAutoClaim'); if (ac) ac.checked = false;
  const r = $('sendDelayResolved'); if (r) r.textContent = '';
  const tp = $('sendTipPreview'); if (tp) tp.textContent = '';
}

// Parse "10m", "2h", "1d", "30s", "90", "1.5h" → seconds (integer, >0). Returns 0 if invalid.
function sendParseDelay(input) {
  if (!input) return 0;
  const s = String(input).trim().toLowerCase().replace(/\s+/g, '');
  const m = s.match(/^(\d+(?:\.\d+)?)([smhdw])?$/);
  if (!m) return 0;
  const n = parseFloat(m[1]);
  if (!isFinite(n) || n <= 0) return 0;
  const mult = { s: 1, m: 60, h: 3600, d: 86400, w: 604800 }[m[2] || 's'];
  return Math.floor(n * mult);
}

function sendFormatDelay(secs) {
  if (secs >= 604800 && secs % 604800 === 0) { const n = secs / 604800; return n + (n === 1 ? ' week' : ' weeks'); }
  if (secs >= 86400) { const n = Math.round(secs / 86400 * 10) / 10; return n + (n === 1 ? ' day' : ' days'); }
  if (secs >= 3600) { const n = Math.round(secs / 3600 * 10) / 10; return n + (n === 1 ? ' hour' : ' hours'); }
  if (secs >= 60) { const n = Math.round(secs / 60 * 10) / 10; return n + (n === 1 ? ' minute' : ' minutes'); }
  return secs + (secs === 1 ? ' second' : ' seconds');
}

function sendApplyDelay(secs) {
  _sendDelaySecs = secs;
  const r = $('sendDelayResolved');
  if (r) {
    if (secs > 0) {
      const matures = new Date(Date.now() + secs * 1000);
      r.innerHTML = 'Recipient can claim after <strong style="color:var(--fg)">' + esc(matures.toLocaleString()) + '</strong> &middot; reversible until then';
    } else {
      r.textContent = '';
    }
  }
  sendUpdateTipPreview();
  sendUpdateButton();
  if (typeof syncSendURL === 'function') syncSendURL();
}

// Setter for the deep-link transfer focus target. Used by the URL parser in
// index.html, which lives in a different script tag and can't write to send.js's
// top-level `let` directly.
function sendSetFocusTransferId(id) {
  _slowFocusTransferId = (id == null) ? null : String(id);
}

// Apply a SLOW delay spec from a deep-link or external caller. Accepts either a
// human shorthand ("10m", "1h", "1.5d") or raw integer seconds. Opens the Delay
// panel, selects a matching chip if one exists, otherwise fills the custom input.
function sendApplyDeepLinkDelay(spec, autoClaim) {
  const secs = sendParseDelay(spec);
  if (secs <= 0) return;
  // Open the Delay panel if it isn't open. sendToggleOption toggles, so only call
  // when currently closed.
  const wrap = $('sendDelayWrap');
  if (wrap && (wrap.style.maxHeight === '0px' || wrap.style.maxHeight === '')) {
    sendToggleOption('Delay');
  }
  // Match a chip by data-secs. If a chip matches, activate it; otherwise fill custom.
  let matched = null;
  document.querySelectorAll('#sendDelayChips .delay-chip').forEach(b => {
    b.classList.remove('active');
    if (parseInt(b.dataset.secs, 10) === secs) matched = b;
  });
  const cust = $('sendDelayCustom');
  if (matched) {
    matched.classList.add('active');
    if (cust) cust.value = '';
  } else if (cust) {
    cust.value = String(spec).trim();
  }
  sendApplyDelay(secs);
  if (autoClaim) {
    const ac = $('sendAutoClaim');
    if (ac && !ac.checked) { ac.checked = true; ac.dispatchEvent(new Event('change')); }
  }
}

// Suggest a sensible default keeper tip based on current gas price. Tip is paid in ETH
// regardless of token. Heuristic: ~120k gas at current gasPrice × 1.5 buffer.
async function sendUpdateTipPreview() {
  const tp = $('sendTipPreview');
  if (!tp) return;
  if (_sendDelaySecs === 0 || !_sendAutoClaim) { tp.textContent = ''; _sendTipWei = 0n; return; }
  tp.textContent = 'Estimating keeper tip...';
  try {
    const rpc = await quoteRPC.call(r => r);
    const fee = await rpc.getFeeData();
    const gp = fee.maxFeePerGas || fee.gasPrice || 2_000_000_000n;
    // 120k gas × 1.5 (keeper margin) = effective 180k
    const tipWei = gp * 180_000n;
    _sendTipWei = tipWei;
    tp.textContent = 'Keeper tip ≈ ' + (+ethers.formatEther(tipWei)).toFixed(6) + ' ETH (refundable if you/recipient settle directly)';
  } catch {
    _sendTipWei = ethers.parseEther('0.0005');
    tp.textContent = 'Keeper tip ≈ ' + (+ethers.formatEther(_sendTipWei)).toFixed(6) + ' ETH (estimate; refundable if not used)';
  }
}

// Recipient resolution
document.addEventListener("DOMContentLoaded", () => {
  const el = $('sendTo');
  if (!el) return;
  el.addEventListener('input', () => {
    const v = el.value.trim();
    _sendResolvedAddr = null;
    $('sendToResolved').style.display = 'none';
    if (ethers.isAddress(v)) {
      _sendResolvedAddr = ethers.getAddress(v);
    } else if (v.endsWith('.wei') || v.endsWith('.eth')) {
      clearTimeout(_sendDebounce);
      _sendDebounce = setTimeout(() => sendResolveName(v), 350);
    }
    syncSendURL();
  });
  const sa = $('sendAmount');
  if (sa) {
    sa.addEventListener('input', debounce(syncSendURL, 400));
    sa.addEventListener("blur", () => { if (sa.value && !isNaN(sa.value)) sa.value = +sa.value; });
  }
  // SLOW delay UI bindings
  document.querySelectorAll('#sendDelayChips .delay-chip').forEach(btn => {
    btn.addEventListener('click', () => {
      const secs = parseInt(btn.dataset.secs, 10);
      document.querySelectorAll('#sendDelayChips .delay-chip').forEach(b => b.classList.remove('active'));
      btn.classList.add('active');
      const cust = $('sendDelayCustom'); if (cust) cust.value = '';
      sendApplyDelay(secs);
    });
  });
  const dCustom = $('sendDelayCustom');
  if (dCustom) {
    dCustom.addEventListener('input', () => {
      document.querySelectorAll('#sendDelayChips .delay-chip').forEach(b => b.classList.remove('active'));
      const secs = sendParseDelay(dCustom.value);
      sendApplyDelay(secs);
    });
  }
  const ac = $('sendAutoClaim');
  if (ac) {
    ac.addEventListener('change', () => {
      _sendAutoClaim = ac.checked;
      sendUpdateTipPreview();
      sendUpdateButton();
      if (typeof syncSendURL === 'function') syncSendURL();
    });
  }
});

async function sendResolveName(name) {
  const seq = ++_sendResolveSeq;
  const el = $('sendToResolved');
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
      resolved = await quoteRPC.call(async (rpc) => rpc.resolveName(name));
    }
    if (seq !== _sendResolveSeq) return;
    if (resolved && resolved !== ZERO_ADDRESS) {
      _sendResolvedAddr = resolved;
      el.style.display = 'block';
      el.style.color = 'var(--fg-muted)';
      el.textContent = resolved;
    } else {
      el.style.display = 'block';
      el.style.color = 'var(--error)';
      el.textContent = 'Name not found';
    }
  } catch {
    if (seq !== _sendResolveSeq) return;
    el.style.display = 'block';
    el.style.color = 'var(--error)';
    el.textContent = 'Failed to resolve';
  }
}

// Approve `spender` for at least `amount`. Handles USDT-style tokens that revert on
// a non-zero → non-zero allowance change by zeroing first. Waits via waitForTx so a
// dropped/replaced approval surfaces instead of silently continuing.
async function _sendEnsureAllowance(erc20, spender, amount, statusEl) {
  const allowance = await erc20.allowance(_connectedAddress, spender);
  if (allowance >= amount) return;
  statusEl.textContent = 'Approving token...'; statusEl.className = 'status show';
  try {
    await waitForTx(await erc20.approve(spender, ethers.MaxUint256));
  } catch (e) {
    if (_sendIsUserReject(e) || allowance === 0n) throw e;
    // Non-zero stale allowance: reset to 0, then approve.
    statusEl.textContent = 'Resetting approval...'; statusEl.className = 'status show';
    await waitForTx(await erc20.approve(spender, 0n));
    statusEl.textContent = 'Approving token...'; statusEl.className = 'status show';
    await waitForTx(await erc20.approve(spender, ethers.MaxUint256));
  }
}

async function doSendOrLock() {
  if (!_connectedAddress) { connectWallet(); return; }
  if (_sendTxInFlight) return;
  const sym = _sendToken;
  const amtStr = $('sendAmount').value;
  const toRaw = $('sendTo').value.trim();
  const statusEl = $('sendStatus');

  if (!amtStr || Number(amtStr) <= 0) { statusEl.textContent = 'Enter an amount'; statusEl.className = 'status show error'; return; }

  // Resolve recipient
  let toAddr = _sendResolvedAddr;
  if (!toAddr && ethers.isAddress(toRaw)) toAddr = ethers.getAddress(toRaw);
  if (!toAddr) { statusEl.textContent = 'Enter a valid recipient'; statusEl.className = 'status show error'; return; }

  const t = tokens[sym];
  if (!t) { statusEl.textContent = 'Unknown token'; statusEl.className = 'status error'; return; }
  const tokenAddr = t.address;
  const isETH = tokenAddr === ZERO_ADDRESS;
  const dec = _sendTokenDec;
  let amount;
  try { amount = ethers.parseUnits(amtStr, dec); } catch { statusEl.textContent = 'Invalid amount'; statusEl.className = 'status show error'; return; }
  if (_sendTokenBal != null && amount > _sendTokenBal) { statusEl.textContent = 'Insufficient ' + sym + ' balance'; statusEl.className = 'status show error'; return; }
  const isDelayed = _sendDelaySecs > 0;

  _sendTxInFlight = true;
  sendUpdateButton();
  try {
    if (isDelayed) {
      const delay = _sendDelaySecs;
      // Re-estimate the keeper tip at submit time — gas may have moved a lot since the
      // checkbox was ticked, and an underfunded tip means nobody claims.
      if (_sendAutoClaim) await sendUpdateTipPreview();
      const useTip = _sendAutoClaim && _sendTipWei > 0n;
      // For ETH the tip rides along in msg.value, so it must fit in the balance too.
      if (useTip && isETH && _sendTokenBal != null && amount + _sendTipWei > _sendTokenBal) {
        statusEl.textContent = 'Insufficient ETH for amount + keeper tip'; statusEl.className = 'status show error'; return;
      }
      const slow = new ethers.Contract(SLOW_ADDRESS, SLOW_ABI, _signer);

      // Approve ERC20 to SLOW if needed
      if (!isETH) {
        statusEl.textContent = 'Checking approval...'; statusEl.className = 'status show';
        const erc20 = new ethers.Contract(tokenAddr, ERC20_TRANSFER_ABI, _signer);
        await _sendEnsureAllowance(erc20, SLOW_ADDRESS, amount, statusEl);
      }

      statusEl.textContent = useTip ? 'Creating delayed transfer (with keeper tip)...' : 'Creating delayed transfer...';
      statusEl.className = 'status show';
      let tx;
      if (useTip) {
        // ETH: msg.value = amount + tip; ERC20: msg.value = tip
        const value = isETH ? (amount + _sendTipWei) : _sendTipWei;
        tx = await slow.depositToWithTip(
          isETH ? ZERO_ADDRESS : tokenAddr,
          toAddr, amount, delay, _sendTipWei, '0x',
          { value }
        );
      } else {
        // SLOW.depositTo: for ETH, must pass amount=0 — contract sets amount := msg.value.
        // For ERC20, pass amount and msg.value=0; contract pulls amount via safeTransferFrom.
        tx = await slow.depositTo(
          isETH ? ZERO_ADDRESS : tokenAddr,
          toAddr,
          isETH ? 0n : amount,
          delay,
          '0x',
          { value: isETH ? amount : 0n }
        );
      }
      statusEl.innerHTML = 'Confirming... <a href="https://etherscan.io/tx/' + escAttr(tx.hash) + '" target="_blank" style="color:inherit;text-decoration:underline">view tx &#8599;</a>'; statusEl.className = 'status show';
      await waitForTx(tx);
      const matures = new Date(Date.now() + delay * 1000).toLocaleString();
      statusEl.innerHTML = 'Delayed transfer created &middot; matures ' + esc(matures) + ' <a href="https://etherscan.io/tx/' + escAttr(tx.hash) + '" target="_blank" style="color:inherit;text-decoration:underline">view tx &#8599;</a>';
      statusEl.className = 'status show success';
      $('sendAmount').value = '';
      sendClearDelaySelection();
      sendUpdateBalance();
      sendLoadSlowTransfers({ quiet: true });
      setTimeout(() => sendLoadSlowTransfers({ quiet: true }), 5000);
    } else {
      // Direct send
      statusEl.textContent = 'Sending...';
      statusEl.className = 'status show';
      let tx;
      if (isETH) {
        tx = await _signer.sendTransaction({ to: toAddr, value: amount });
      } else {
        const erc20 = new ethers.Contract(tokenAddr, ERC20_TRANSFER_ABI, _signer);
        tx = await erc20.transfer(toAddr, amount);
      }
      statusEl.innerHTML = 'Confirming... <a href="https://etherscan.io/tx/' + escAttr(tx.hash) + '" target="_blank" style="color:inherit;text-decoration:underline">view tx &#8599;</a>'; statusEl.className = 'status show';
      await waitForTx(tx);
      statusEl.innerHTML = 'Sent! <a href="https://etherscan.io/tx/' + escAttr(tx.hash) + '" target="_blank" style="color:inherit;text-decoration:underline">view tx &#8599;</a>';
      statusEl.className = 'status show success';
      $('sendAmount').value = '';
      sendUpdateBalance();
    }
  } catch (e) {
    console.error(e);
    statusEl.textContent = _sendIsUserReject(e)
      ? 'Rejected in wallet'
      : (e.reason || e.shortMessage || e.message || 'Transaction failed');
    statusEl.className = 'status show error';
  } finally {
    _sendTxInFlight = false;
    sendUpdateButton();
  }
}

// ---- SLOW: Delayed Transfers ----

async function _slowTokenMeta(rpc, tokenAddr) {
  const key = (tokenAddr || ZERO_ADDRESS).toLowerCase();
  if (key === ZERO_ADDRESS.toLowerCase()) return { symbol: 'ETH', decimals: 18 };
  if (_slowTokenMetaCache.has(key)) return _slowTokenMetaCache.get(key);
  // Fast path: registered token
  for (const sym of Object.keys(tokens)) {
    const t = tokens[sym];
    if (t.address && t.address.toLowerCase() === key) {
      const meta = { symbol: t.symbol || sym, decimals: t.decimals != null ? Number(t.decimals) : 18 };
      _slowTokenMetaCache.set(key, meta);
      return meta;
    }
  }
  try {
    const c = new ethers.Contract(tokenAddr, ERC20_TRANSFER_ABI, rpc);
    const [sym, dec] = await Promise.all([
      c.symbol().catch(() => 'TKN'),
      c.decimals().catch(() => 18n)
    ]);
    const meta = { symbol: String(sym), decimals: Number(dec) };
    _slowTokenMetaCache.set(key, meta);
    return meta;
  } catch {
    const meta = { symbol: 'TKN', decimals: 18 };
    _slowTokenMetaCache.set(key, meta);
    return meta;
  }
}

function _slowFormatRelative(secs) {
  const abs = Math.abs(secs);
  if (abs < 60) return secs >= 0 ? `in ${secs}s` : `${abs}s ago`;
  if (abs < 3600) { const m = Math.round(abs / 60); return secs >= 0 ? `in ${m}m` : `${m}m ago`; }
  if (abs < 86400) { const h = Math.round(abs / 3600 * 10) / 10; return secs >= 0 ? `in ${h}h` : `${h}h ago`; }
  const d = Math.round(abs / 86400 * 10) / 10;
  return secs >= 0 ? `in ${d}d` : `${d}d ago`;
}

// Refresh the delayed-transfer list on a timer so PENDING rows become CLAIMABLE (and
// CLAIMABLE rows become clawback-ready) without a manual reload. Skipped while the tab
// is hidden, while an action is mid-flight, or while disconnected.
function sendStartSlowRefresh() {
  if (_slowRefreshTimer) return;
  _slowRefreshTimer = setInterval(() => {
    if (document.hidden) return;
    if (_slowBusy > 0 || _sendTxInFlight) return;
    if (!_connectedAddress) return;
    if ($('sendTab')?.style.display === 'none') return;
    sendLoadSlowTransfers({ quiet: true });
  }, 30000);
}

// `quiet` suppresses the "Loading..." flash so periodic refreshes don't blank the list.
async function sendLoadSlowTransfers(opts) {
  const quiet = !!(opts && opts.quiet);
  const el = $('slowList');
  if (!el) return;
  if (!_connectedAddress) { el.textContent = 'Connect wallet to view delayed transfers'; return; }
  sendStartSlowRefresh();
  const seq = ++_slowLoadSeq;
  const forAddress = _connectedAddress;
  const stale = () => seq !== _slowLoadSeq || forAddress !== _connectedAddress;
  if (!quiet) el.innerHTML = '<div style="color:var(--fg-dim);font-size:12px">Loading...</div>';
  try {
    const rpc = await quoteRPC.call(r => r);
    const slow = new ethers.Contract(SLOW_ADDRESS, SLOW_ABI, rpc);
    if (!_slowGateAddr) { try { _slowGateAddr = await slow.gate(); } catch {} }
    // A failed index read must not be mistaken for "no transfers" — track it and say so.
    let readFailed = false;
    const [outIds, inIds, guardian] = await Promise.all([
      slow.getOutboundTransfers(forAddress).catch(() => { readFailed = true; return []; }),
      slow.getInboundTransfers(forAddress).catch(() => { readFailed = true; return []; }),
      slow.guardians(forAddress).catch(() => { readFailed = true; return ZERO_ADDRESS; })
    ]);
    if (stale()) return;
    if (readFailed && outIds.length === 0 && inIds.length === 0) {
      el.textContent = 'Failed to load delayed transfers — retrying shortly';
      return;
    }
    _slowHasGuardian = guardian && guardian !== ZERO_ADDRESS;
    // Dedupe (a self-send would appear in both); preserve direction info
    const idMap = new Map(); // id(string) → { sent, received }
    for (const id of outIds) { idMap.set(id.toString(), { sent: true, received: false }); }
    for (const id of inIds) {
      const k = id.toString();
      if (idMap.has(k)) idMap.get(k).received = true;
      else idMap.set(k, { sent: false, received: true });
    }
    if (idMap.size === 0) { el.textContent = 'No delayed transfers'; return; }

    const ids = [...idMap.keys()];
    let unreadable = 0;
    const transfers = await Promise.all(
      ids.map(id => slow.pendingTransfers(id).then(p => ({ id, p })).catch(() => { unreadable++; return null; }))
    );
    if (stale()) return;
    const tipsByTransfer = {};
    if (_slowGateAddr && _slowGateAddr !== ZERO_ADDRESS) {
      const gate = new ethers.Contract(_slowGateAddr, SLOW_GATE_ABI, rpc);
      await Promise.all(ids.map(async (id) => {
        try {
          const t = await gate.tips(id);
          if (t.amount && t.amount > 0n) tipsByTransfer[id] = { amount: t.amount, sender: t.sender };
        } catch {}
      }));
    }

    // Filter live transfers (timestamp != 0). Build rows.
    const live = [];
    for (const r of transfers) {
      if (!r) continue;
      const { id, p } = r;
      const ts = Number(p.timestamp);
      if (ts === 0) continue; // settled / reversed / cleared
      const direction = idMap.get(id);
      // SLOW id encoding: low 160 = token, high 96 = delay
      const idBig = BigInt(p.id);
      const tokenAddr = ethers.getAddress('0x' + (idBig & ((1n << 160n) - 1n)).toString(16).padStart(40, '0'));
      const delay = Number(idBig >> 160n);
      const expiry = ts + delay;
      live.push({ transferId: id, ts, delay, expiry, tokenAddr, from: p.from, to: p.to, slot: p.id, amount: BigInt(p.amount), direction });
    }
    live.sort((a, b) => b.ts - a.ts);
    if (live.length === 0) {
      el.textContent = unreadable > 0
        ? unreadable + ' transfer(s) could not be read — retrying shortly'
        : 'No delayed transfers';
      return;
    }

    const metas = await Promise.all(live.map(t => _slowTokenMeta(rpc, t.tokenAddr)));
    if (stale()) return;
    const now = Math.floor(Date.now() / 1000);
    const focusId = _slowFocusTransferId;
    let html = '';
    let focusRow = null;
    for (let i = 0; i < live.length; i++) {
      const t = live[i];
      const meta = metas[i];
      const fmtAmt = (+ethers.formatUnits(t.amount, meta.decimals)).toFixed(5);
      const tilExpiry = t.expiry - now;
      const tilClawback = (t.expiry + SLOW_CLAWBACK_GRACE) - now;
      let status, label, hint;
      if (tilExpiry > 0) {
        status = 'pending'; label = 'PENDING';
        hint = 'Matures ' + _slowFormatRelative(tilExpiry) + ' &middot; ' + new Date(t.expiry * 1000).toLocaleString();
      } else if (tilClawback > 0) {
        status = 'matured'; label = 'CLAIMABLE';
        hint = 'Matured ' + _slowFormatRelative(tilExpiry) + ' &middot; sender can clawback ' + _slowFormatRelative(tilClawback);
      } else {
        status = 'clawback-ready'; label = 'CLAWBACK READY';
        hint = 'Past grace &middot; sender may clawback';
      }
      const dirParts = [];
      if (t.direction.sent) dirParts.push('sent &middot; to ' + t.to.slice(0, 6) + '...' + t.to.slice(-4));
      if (t.direction.received) dirParts.push('inbound &middot; from ' + t.from.slice(0, 6) + '...' + t.from.slice(-4));
      const dirStr = dirParts.join(' / ');
      const delayLbl = sendFormatDelay(t.delay);
      const tipInfo = tipsByTransfer[t.transferId];
      const tipNote = tipInfo ? ` &middot; <span style="color:var(--fg-dim)">keeper tip ${(+ethers.formatEther(tipInfo.amount)).toFixed(5)} ETH</span>` : '';

      let actions = '';
      const tid = escAttr(t.transferId);
      const slotStr = escAttr(t.slot.toString());
      const amtStr = escAttr(t.amount.toString());
      const tippedFlag = tipInfo ? '1' : '0';
      if (t.direction.received && status !== 'pending') {
        actions += `<button onclick="slowClaim('${tid}','${slotStr}','${amtStr}','${tippedFlag}',this)">Claim</button>`;
      }
      if (t.direction.sent && status === 'pending') {
        actions += `<button class="danger" onclick="slowReverse('${tid}','${slotStr}','${amtStr}','${tippedFlag}',this)">Reverse</button>`;
      }
      if (t.direction.sent && status === 'clawback-ready') {
        actions += `<button class="secondary" onclick="slowClawback('${tid}','${slotStr}','${amtStr}','${tippedFlag}',this)">Clawback</button>`;
      }
      // Refund tip is available to original tip-payer once transfer cleared — not shown here
      // because the entry must be gone for refund to succeed; we surface it after clear instead.

      const isFocus = focusId && focusId === t.transferId;
      const rowId = `slowRow-${tid}`;
      if (isFocus) focusRow = rowId;
      html += `<div id="${rowId}" class="xfer-item${isFocus ? ' slow-focus' : ''}">
        <div class="xfer-head">
          <span class="xfer-amount">${fmtAmt} <span style="font-weight:400;font-size:12px;letter-spacing:0.04em">${esc(meta.symbol)}</span></span>
          <span class="xfer-status ${status}">${label}</span>
        </div>
        <div class="xfer-meta">
          ${esc(delayLbl)} delay &middot; ${dirStr}${tipNote}
        </div>
        <div class="xfer-countdown">${hint}</div>
        ${actions ? `<div class="xfer-claim">${actions}</div>` : ''}
      </div>`;
    }
    if (unreadable > 0) {
      html += `<div class="xfer-countdown" style="padding:8px 0">${unreadable} transfer(s) could not be read — retrying shortly</div>`;
    }
    el.innerHTML = html;
    if (focusId) {
      if (focusRow) {
        const node = document.getElementById(focusRow);
        if (node) node.scrollIntoView({ behavior: 'smooth', block: 'center' });
      }
      _slowFocusTransferId = null; // one-shot — clear whether or not the row was present
    }
  } catch (e) {
    console.error(e);
    // A background refresh that fails leaves the last good rows in place rather than
    // replacing them with an error — the next tick retries.
    if (!quiet && !stale()) el.textContent = 'Failed to load delayed transfers';
  }
}

// Drop per-account SLOW state so a disconnect or account switch can't leave stale rows
// (or a stale guardian flag, which decides claim-vs-unlock) on screen.
function sendHandleDisconnect() {
  _slowLoadSeq++;
  _slowHasGuardian = false;
  _slowFocusTransferId = null;
  _sendTokenBal = null;
  const el = $('slowList');
  if (el) el.textContent = 'Connect wallet to view delayed transfers';
  const bal = $('sendBalanceText');
  if (bal) bal.textContent = 'Balance: --';
}

// Best-effort tip refund after a sender-side settlement (reverse / clawback).
// Reverts silently if no tip exists or the entry is still pending.
async function _slowRefundTipBestEffort(transferId) {
  if (!_slowGateAddr || _slowGateAddr === ZERO_ADDRESS) return false;
  try {
    const gate = new ethers.Contract(_slowGateAddr, SLOW_GATE_ABI, _signer);
    const tx = await gate.refundTip(BigInt(transferId));
    await waitForTx(tx);
    return true;
  } catch { return false; }
}

async function slowClaim(transferId, idStr, amtStr, tippedFlag, btn) {
  if (!_signer) { connectWallet(); return; }
  if (btn.disabled) return;
  btn.disabled = true;
  const orig = btn.textContent;
  _slowBusy++;
  try {
    const slow = new ethers.Contract(SLOW_ADDRESS, SLOW_ABI, _signer);
    // Mirror canonical SLOW dapp: when recipient has a guardian, claim is blocked —
    // call unlock instead. The wrapper stays at recipient; redeeming requires the
    // guardian to co-sign withdrawFrom (out of scope here).
    btn.textContent = _slowHasGuardian ? 'Unlocking...' : 'Claiming...';
    const tx = _slowHasGuardian
      ? await slow.unlock(BigInt(transferId))
      : await slow.claim(BigInt(transferId));
    btn.innerHTML = 'Confirming... <a href="https://etherscan.io/tx/' + escAttr(tx.hash) + '" target="_blank" style="color:inherit;text-decoration:underline;font-size:11px">tx &#8599;</a>';
    await waitForTx(tx);
    btn.innerHTML = (_slowHasGuardian
      ? 'Unlocked &middot; coordinate withdrawal with guardian'
      : 'Claimed!') + ' <a href="https://etherscan.io/tx/' + escAttr(tx.hash) + '" target="_blank" style="color:inherit;text-decoration:underline;font-size:11px">tx &#8599;</a>';
    sendUpdateBalance();
    setTimeout(() => sendLoadSlowTransfers({ quiet: true }), 2000);
  } catch (e) {
    console.error(e);
    btn.disabled = false;
    btn.textContent = orig || 'Claim';
    if (!_sendIsUserReject(e)) alert('Claim failed: ' + (e.reason || e.shortMessage || e.message));
  } finally {
    _slowBusy--;
  }
}

// Reverse a pending transfer. Mirrors canonical SLOW dapp: when sender has no
// guardian, atomically chain reverse + withdrawFrom via multicall so the user
// receives raw underlying in one transaction. With a guardian set, withdrawFrom
// requires guardian co-sign of the predicted withdrawal id — fall back to a
// single reverse() and surface guidance.
async function slowReverse(transferId, idStr, amtStr, tippedFlag, btn) {
  if (!_signer) { connectWallet(); return; }
  if (btn.disabled) return;
  _slowBusy++;
  if (!confirm('Reverse this transfer? Funds will be returned to your wallet (callable only before maturity).')) { _slowBusy--; return; }
  btn.disabled = true;
  const orig = btn.textContent;
  btn.textContent = 'Reversing...';
  try {
    const slow = new ethers.Contract(SLOW_ADDRESS, SLOW_ABI, _signer);
    const iface = slow.interface;
    let tx;
    if (_slowHasGuardian) {
      tx = await slow.reverse(BigInt(transferId));
    } else {
      const reverseData = iface.encodeFunctionData('reverse', [BigInt(transferId)]);
      const withdrawData = iface.encodeFunctionData('withdrawFrom',
        [_connectedAddress, _connectedAddress, BigInt(idStr), BigInt(amtStr)]);
      tx = await slow.multicall([reverseData, withdrawData]);
    }
    btn.innerHTML = 'Confirming... <a href="https://etherscan.io/tx/' + escAttr(tx.hash) + '" target="_blank" style="color:inherit;text-decoration:underline;font-size:11px">tx &#8599;</a>';
    await waitForTx(tx);
    let tipNote = '';
    if (tippedFlag === '1') { if (await _slowRefundTipBestEffort(transferId)) tipNote = ' &middot; tip refunded'; }
    btn.innerHTML = (_slowHasGuardian ? 'Reversed &middot; coordinate withdrawal with guardian' : 'Reversed and returned!') + tipNote +
      ' <a href="https://etherscan.io/tx/' + escAttr(tx.hash) + '" target="_blank" style="color:inherit;text-decoration:underline;font-size:11px">tx &#8599;</a>';
    sendUpdateBalance();
    setTimeout(() => sendLoadSlowTransfers({ quiet: true }), 2000);
  } catch (e) {
    console.error(e);
    btn.disabled = false;
    btn.textContent = orig || 'Reverse';
    if (_sendIsUserReject(e)) return;
    const m = e.reason || e.shortMessage || e.message || '';
    alert('Reverse failed: ' + (m.toLowerCase().includes('timelockexpired') ? 'past maturity — use clawback after grace period' : m));
  } finally {
    _slowBusy--;
  }
}

async function slowClawback(transferId, idStr, amtStr, tippedFlag, btn) {
  if (!_signer) { connectWallet(); return; }
  if (btn.disabled) return;
  _slowBusy++;
  if (!confirm('Clawback unclaimed transfer? Funds will return to your wallet (callable only after maturity + 30 day grace).')) { _slowBusy--; return; }
  btn.disabled = true;
  const orig = btn.textContent;
  btn.textContent = 'Clawing back...';
  try {
    const slow = new ethers.Contract(SLOW_ADDRESS, SLOW_ABI, _signer);
    const iface = slow.interface;
    let tx;
    if (_slowHasGuardian) {
      tx = await slow.clawback(BigInt(transferId));
    } else {
      const clawbackData = iface.encodeFunctionData('clawback', [BigInt(transferId)]);
      const withdrawData = iface.encodeFunctionData('withdrawFrom',
        [_connectedAddress, _connectedAddress, BigInt(idStr), BigInt(amtStr)]);
      tx = await slow.multicall([clawbackData, withdrawData]);
    }
    btn.innerHTML = 'Confirming... <a href="https://etherscan.io/tx/' + escAttr(tx.hash) + '" target="_blank" style="color:inherit;text-decoration:underline;font-size:11px">tx &#8599;</a>';
    await waitForTx(tx);
    let tipNote = '';
    if (tippedFlag === '1') { if (await _slowRefundTipBestEffort(transferId)) tipNote = ' &middot; tip refunded'; }
    btn.innerHTML = (_slowHasGuardian ? 'Recovered &middot; coordinate withdrawal with guardian' : 'Recovered!') + tipNote +
      ' <a href="https://etherscan.io/tx/' + escAttr(tx.hash) + '" target="_blank" style="color:inherit;text-decoration:underline;font-size:11px">tx &#8599;</a>';
    sendUpdateBalance();
    setTimeout(() => sendLoadSlowTransfers({ quiet: true }), 2000);
  } catch (e) {
    console.error(e);
    btn.disabled = false;
    btn.textContent = orig || 'Clawback';
    if (!_sendIsUserReject(e)) alert('Clawback failed: ' + (e.reason || e.shortMessage || e.message));
  } finally {
    _slowBusy--;
  }
}
