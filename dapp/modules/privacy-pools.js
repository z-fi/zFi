// ==================== PRIVACY POOLS RUNTIME START ====================
// Privacy Pools integrates through these hook functions from the surrounding
// single-file app. Keep them as the supported PP lifecycle seam.
function ppHandlePrivacyTabSelected() {
  loadPPConfig();
  if (_connectedAddress && _signer) ppRefreshWalletCompatibility();
  else ppRenderWalletCompatibilityNotice(null);
  ppUpdateDepositCta();
  if (_ppwHasResolvedLoadState && Array.isArray(_ppwLoadResults) && _ppwLoadResults.length) ppwRenderPoolAccounts();
  ppwUpdateLoadButton();
  ppwRenderIdleState();
}

function ppHandlePrivacyWalletConnected() {
  ppResetWalletCompatibility();
  ppRenderWalletSeedBackupNotice();
  if ($('privacyTab')?.style.display !== 'none') {
    ppRefreshWalletCompatibility();
    ppUpdateDepositCta();
  }
  if ($('ppwRecipient')) ppwUpdateRecipientHint();
  if ($('ppwWithdrawBtn')) ppwSyncWithdrawActionState();
  if (_ppwHasResolvedLoadState && Array.isArray(_ppwLoadResults) && _ppwLoadResults.length) ppwRenderPoolAccounts();
  ppUpdateDescriptions(true);
  // Show connected My Pools UI without auto-starting recovery or signatures.
  setShown('ppwLoadDisconnected', true);
  setShown('ppwLoadConnected', true);
  ppwUpdateLoadButton();
  if ($('privacyTab')?.style.display !== 'none') ppwRenderIdleState();
  ppwSyncBackgroundRefreshLoop();
}

function ppHandlePrivacyWalletDisconnected() {
  ppResetWalletCompatibility();
  ppClearPendingWalletSeedBackups();
  ppRenderWalletSeedBackupNotice();
  ppScrubMasterKeyStore(_ppMasterKeys);
  _ppMasterKeys = null;
  _ppDepositBalanceRefreshState = { key: null, promise: null, lastFailedKey: null, lastFailedAt: 0 };
  _ppObservedDepositBalanceRefreshPromise = null;
  _ppwLoadAfterBackup = false;
  _ppwEventCache = {};
  for (const k in _ppBlockTimestampCache) delete _ppBlockTimestampCache[k];
  ppTerminateProofProgressWorker();
  _ppConfigCache = null; _ppConfigCacheTs = 0;
  // Close any open withdrawal form and clear selected account
  ppwCloseWithdrawForm();
  if ($('ppwRecipient')) ppwUpdateRecipientHint();
  if ($('ppwWithdrawBtn')) ppwSyncWithdrawActionState();
  ppUpdateDepositCta();
  setText('ppBalance', 'Balance: --');
  ppUpdateDescriptions(false);
  // Reset My Pools to disconnected state
  if (_ppwLoadAbort) { _ppwLoadAbort.abort(); _ppwLoadAbort = null; }
  _ppwLoadResults = [];
  _ppwLoadWarnings = [];
  _ppwActivityHistory = [];
  _ppwHasResolvedLoadState = false;
  setShown('ppwLoadConnected', false);
  setShown('ppwLoadDisconnected', true);
  ppwUpdateLoadButton();
  const sr = $('ppwLoadResults');
  if (sr) sr.innerHTML = '';
  const ar = $('ppwActivitySection');
  if (ar) {
    ar.innerHTML = '';
    setShown(ar, false);
  }
  setShown('ppwLoadRefresh', false);
  ppwStopBackgroundRefreshLoop();
}

const PP_ENTRYPOINT = "0x6818809eefce719e480a7526d76bd3e561526b46";
const PP_ENTRYPOINT_ABI = [
  "function deposit(uint256) payable returns (uint256)",
  "function deposit(address,uint256,uint256) returns (uint256)",
  "function assetConfig(address) view returns (address pool, uint256 minimumDepositAmount, uint256 vettingFeeBPS, uint256 maxRelayFeeBPS)",
  "function latestRoot() view returns (uint256)",
  "function usedPrecommitments(uint256) view returns (bool)",
  "function relay(tuple(address,bytes),tuple(uint256[2],uint256[2][2],uint256[2],uint256[8]),uint256)"
];

const PP_RELAYER_HOST = 'https://fastrelay.xyz';
function ppGetRelayerHost() {
  return PP_RELAYER_HOST;
}
const PP_POOL_EVENTS = new ethers.Interface([
  "event Deposited(address indexed _depositor, uint256 _commitment, uint256 _label, uint256 _value, uint256 _precommitmentHash)",
  "event LeafInserted(uint256 _index, uint256 _leaf, uint256 _root)",
  "event Ragequit(address indexed _ragequitter, uint256 _commitment, uint256 _label, uint256 _value)",
  "event Withdrawn(address indexed _processooor, uint256 _value, uint256 _spentNullifier, uint256 _newCommitment)"
]);
const SNARK_FIELD = 21888242871839275222246405745257275088548364400416034343698204186575808495617n;
const PP_DEPLOYMENT_BLOCKS = { ETH: 22153707, BOLD: 24433029, wstETH: 23039970 };

let _ppMasterKeys = null; // { address, activeVersion, versions: { v1?: { safe, legacy }, v2?: { safe, legacy } } }
const PP_WALLET_SEED_VERSION_STORAGE_KEY = 'zfi_pp_wallet_seed_versions';
const PP_WALLET_SEED_BACKUP_STORAGE_KEY = 'zfi_pp_wallet_seed_backups_v1';
const PP_ALLOWED_WALLETCONNECT_WALLETS = ['metamask', 'rabby', 'rainbow', 'family'];
let _ppWalletCompatibilityState = { key: null, status: 'idle', result: null, promise: null };
let _ppPendingWalletSeedBackups = {};
let _ppActiveWalletSeedBackupKey = null;
let _ppwLoadAfterBackup = false;

function ppReadWalletStorage(key) {
  try {
    return localStorage.getItem(key);
  } catch (_) {
    return null;
  }
}

function ppNormalizeWalletName(name) {
  return String(name || '').trim().toLowerCase();
}

function ppNormalizeWalletSeedBackupKey(address, version) {
  const normalizedAddress = String(address || '').toLowerCase();
  const normalizedVersion = version === 'v1' ? 'v1' : (version === 'v2' ? 'v2' : null);
  if (!normalizedAddress || !normalizedVersion) return null;
  return normalizedAddress + ':' + normalizedVersion;
}

function ppReadWalletBackupRegistry() {
  try {
    const raw = localStorage.getItem(PP_WALLET_SEED_BACKUP_STORAGE_KEY);
    return raw ? (JSON.parse(raw) || {}) : {};
  } catch (_) {
    return {};
  }
}

function ppHasWalletSeedBackup(address, version) {
  const key = ppNormalizeWalletSeedBackupKey(address, version);
  if (!key) return false;
  const entry = ppReadWalletBackupRegistry()[key];
  return !!(entry?.downloaded || entry?.acknowledged);
}

function ppRememberWalletSeedBackup(address, version, patch = {}) {
  const key = ppNormalizeWalletSeedBackupKey(address, version);
  if (!key) return;
  try {
    const registry = ppReadWalletBackupRegistry();
    const current = registry[key] || {};
    registry[key] = {
      downloaded: !!(patch.downloaded ?? current.downloaded),
      acknowledged: !!(patch.acknowledged ?? current.acknowledged),
      updatedAt: Date.now(),
    };
    localStorage.setItem(PP_WALLET_SEED_BACKUP_STORAGE_KEY, JSON.stringify(registry));
  } catch (_) {}
}

function ppGetPendingWalletSeedBackup(address = _connectedAddress, version = null) {
  if (version) {
    const key = ppNormalizeWalletSeedBackupKey(address, version);
    return key ? (_ppPendingWalletSeedBackups[key] || null) : null;
  }
  const activePrompt = _ppActiveWalletSeedBackupKey ? _ppPendingWalletSeedBackups[_ppActiveWalletSeedBackupKey] : null;
  if (activePrompt && (!address || String(activePrompt.address || '').toLowerCase() === String(address || '').toLowerCase())) {
    return activePrompt;
  }
  return null;
}

function ppHasActiveWalletSeedBackupPrompt(address = _connectedAddress) {
  return !!ppGetPendingWalletSeedBackup(address);
}

function ppSetActiveWalletSeedBackupPrompt(address, version) {
  const key = ppNormalizeWalletSeedBackupKey(address, version);
  _ppActiveWalletSeedBackupKey = key && _ppPendingWalletSeedBackups[key] ? key : null;
}

function ppCloneWalletSeedKeyset(keyset) {
  if (!keyset || typeof keyset !== 'object') return null;
  return {
    masterNullifier: keyset.masterNullifier != null ? BigInt(keyset.masterNullifier) : null,
    masterSecret: keyset.masterSecret != null ? BigInt(keyset.masterSecret) : null,
  };
}

function ppCloneWalletSeedDerivedKeys(derivedKeys) {
  if (!derivedKeys || typeof derivedKeys !== 'object') return null;
  const next = {};
  const safeKeys = ppCloneWalletSeedKeyset(derivedKeys.safe);
  const legacyKeys = ppCloneWalletSeedKeyset(derivedKeys.legacy);
  if (safeKeys) next.safe = safeKeys;
  if (legacyKeys) next.legacy = legacyKeys;
  return Object.keys(next).length ? next : null;
}

function ppScrubWalletSeedDerivedKeys(derivedKeys) {
  if (!derivedKeys || typeof derivedKeys !== 'object') return;
  for (const keyset of Object.values(derivedKeys)) {
    if (!keyset || typeof keyset !== 'object') continue;
    if ('masterNullifier' in keyset) keyset.masterNullifier = 0n;
    if ('masterSecret' in keyset) keyset.masterSecret = 0n;
  }
}

function ppScrubWalletSeedBackupPrompt(prompt) {
  if (!prompt || typeof prompt !== 'object') return;
  if (typeof prompt.phrase === 'string') prompt.phrase = '';
  ppScrubWalletSeedDerivedKeys(prompt.derivedKeys);
  prompt.derivedKeys = null;
}

function ppClearPendingWalletSeedBackups(address = null, keepVersion = null) {
  const normalizedAddress = address ? String(address).toLowerCase() : null;
  const next = {};
  for (const [key, prompt] of Object.entries(_ppPendingWalletSeedBackups)) {
    const promptAddress = String(prompt?.address || '').toLowerCase();
    const promptVersion = prompt?.version || null;
    const shouldKeep = (!normalizedAddress || promptAddress === normalizedAddress) && keepVersion && promptVersion === keepVersion;
    if (shouldKeep) {
      next[key] = prompt;
      continue;
    }
    if (normalizedAddress && promptAddress !== normalizedAddress) {
      next[key] = prompt;
      continue;
    }
    ppScrubWalletSeedBackupPrompt(prompt);
  }
  _ppPendingWalletSeedBackups = next;
  const activePrompt = _ppActiveWalletSeedBackupKey ? _ppPendingWalletSeedBackups[_ppActiveWalletSeedBackupKey] : null;
  _ppActiveWalletSeedBackupKey = activePrompt ? _ppActiveWalletSeedBackupKey : null;
}

function ppWalletSeedBackupRequiredError() {
  const err = new Error('Save your recovery phrase before continuing.');
  err.code = 'PP_WALLET_SEED_BACKUP_REQUIRED';
  return err;
}

function ppBuildWalletSeedBackupNoticeState(pending, connectedAddress = _connectedAddress) {
  const pendingAddress = String(pending?.address || '').toLowerCase();
  const normalizedAddress = String(connectedAddress || '').toLowerCase();
  const show = !!pending && !!normalizedAddress && (!pendingAddress || pendingAddress === normalizedAddress);
  const downloaded = !!pending?.downloaded;
  const acknowledged = !!pending?.acknowledged;
  return {
    show,
    downloaded,
    acknowledged,
    canContinue: downloaded || acknowledged,
    downloadLabel: downloaded ? 'Recovery Phrase Downloaded' : 'Download Recovery Phrase',
    acknowledgementLabel: 'I\'ve already downloaded or saved this Recovery Phrase',
    titleHtml: '<b>Save your recovery phrase.</b>',
    bodyText: 'If your wallet provider changes its signing method, this phrase is the only way to recover your deposits. Never share it.',
  };
}

function ppRenderWalletSeedBackupNotice() {
  const pending = ppGetPendingWalletSeedBackup();
  for (const noticeId of ['ppWalletSeedBackupNotice', 'ppSwapWalletSeedBackupNotice']) {
    const el = $(noticeId);
    if (!el) continue;
    const state = ppBuildWalletSeedBackupNoticeState(pending, _connectedAddress);
    if (!state.show) {
      if (el.innerHTML && el.dataset.dismissing !== '1') {
        el.dataset.dismissing = '1';
        el.innerHTML = '<b>\u2713 Recovery phrase saved.</b>';
        el.style.transition = 'opacity 0.3s ease';
        setTimeout(() => { el.style.opacity = '0'; }, 800);
        setTimeout(() => {
          el.innerHTML = '';
          el.style.display = 'none';
          el.style.opacity = '';
          el.style.transition = '';
          delete el.dataset.dismissing;
        }, 1100);
        continue;
      }
      if (el.dataset.dismissing === '1') continue;
      el.innerHTML = '';
      setShown(el, false);
      continue;
    }
    const ackChecked = state.acknowledged ? 'checked' : '';
    el.innerHTML = state.titleHtml + ' ' + escText(state.bodyText) +
      '<div style="display:flex;gap:8px;flex-wrap:wrap;margin-top:8px">' +
        '<button class="swap-btn" type="button" onclick="ppDownloadWalletSeedBackup()" style="padding:4px 12px;font-size:11px;width:auto">' + escText(state.downloadLabel) + '</button>' +
      '</div>' +
      '<label style="display:flex;align-items:flex-start;gap:6px;margin-top:8px;color:var(--fg-muted);text-transform:none;letter-spacing:normal">' +
        '<input type="checkbox" onchange="ppAcknowledgeAndContinueBackup(this.checked)" ' + ackChecked + '>' +
        '<span>' + escText(state.acknowledgementLabel) + '</span>' +
      '</label>';
    setShown(el, true);
  }
  if ($('ppDepositBtn')) ppUpdateDepositCta();
  if ($('ppwLoadBtn')) ppwUpdateLoadButton();
  if ($('ppwWithdrawBtn')) ppwSyncWithdrawActionState();
}

function ppSetPendingWalletSeedBackup(prompt, { active = true } = {}) {
  const key = ppNormalizeWalletSeedBackupKey(prompt?.address, prompt?.version);
  if (!key) return;
  const derivedKeys = ppCloneWalletSeedDerivedKeys(prompt?.derivedKeys);
  if (!derivedKeys) {
    console.warn('Privacy: missing derived keys for wallet seed backup prompt');
    return;
  }
  _ppPendingWalletSeedBackups[key] = {
    address: prompt.address,
    version: prompt.version,
    phrase: String(prompt.phrase || ''),
    derivedKeys,
    downloaded: !!prompt.downloaded,
    acknowledged: !!prompt.acknowledged,
  };
  if (active) _ppActiveWalletSeedBackupKey = key;
  ppRenderWalletSeedBackupNotice();
}

function ppSetWalletSeedBackupAcknowledged(acknowledged) {
  const pending = ppGetPendingWalletSeedBackup();
  if (!pending) return;
  pending.acknowledged = !!acknowledged;
  ppRenderWalletSeedBackupNotice();
}

function ppAcknowledgeAndContinueBackup(checked) {
  ppSetWalletSeedBackupAcknowledged(checked);
  if (checked) ppContinueWalletSeedBackup();
}

async function ppResolveWalletSeedBackupPhrase(pending) {
  if (!pending) throw new Error('No Privacy Pools backup is pending.');
  if (pending.phrase) return pending.phrase;
  const pendingAddress = String(pending.address || '').toLowerCase();
  if (!_signer || !_connectedAddress || String(_connectedAddress || '').toLowerCase() !== pendingAddress) {
    throw new Error('Reconnect the same wallet and sign again to download your recovery phrase.');
  }
  await ppEnsureWalletCompatibility();
  const mnemonic = await ppDeriveWalletSeed(_signer, _connectedAddress, pending.version, (msg) => {
    showStatus(msg, '');
  });
  try {
    return mnemonic.phrase;
  } finally {
    try { if (mnemonic.entropy) mnemonic.entropy.fill(0); } catch (_) {}
  }
}

async function ppDownloadWalletSeedBackup() {
  const pending = ppGetPendingWalletSeedBackup();
  if (!pending) return;
  let phrase = '';
  try {
    phrase = await ppResolveWalletSeedBackupPhrase(pending);
  } catch (err) {
    showStatus('Could not download your recovery phrase. Please try again.', 'error');
    console.warn('Privacy: seedphrase download failed', err);
    return;
  }
  const blob = new Blob([phrase], { type: 'text/plain' });
  const url = URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.href = url;
  a.download = `privacy-pools-recovery-phrase-${String(pending.address || '').slice(0, 8)}.txt`;
  document.body.appendChild(a);
  a.click();
  document.body.removeChild(a);
  URL.revokeObjectURL(url);
  pending.downloaded = true;
  pending.acknowledged = true;
  pending.phrase = '';
  ppRenderWalletSeedBackupNotice();
  showStatus('Recovery phrase downloaded.', 'success');
  ppContinueWalletSeedBackup();
}

function ppContinueWalletSeedBackup() {
  const pending = ppGetPendingWalletSeedBackup();
  if (!pending) return;
  if (!pending.downloaded && !pending.acknowledged) {
    showStatus('Save your recovery phrase before continuing.', 'error');
    return;
  }
  const restoredDerivedKeys = ppCloneWalletSeedDerivedKeys(pending.derivedKeys);
  if (!restoredDerivedKeys) {
    showStatus('Could not restore your Privacy Pools keys from the pending backup. Reconnect the same wallet and try again.', 'error');
    return;
  }
  const masterKeyStore = ppGetOrCreateMasterKeyStore(pending.address);
  masterKeyStore.versions[pending.version] = restoredDerivedKeys;
  masterKeyStore.activeVersion = pending.version;
  ppRememberWalletSeedVersion(pending.address, pending.version);
  ppRememberWalletSeedBackup(pending.address, pending.version, {
    downloaded: pending.downloaded,
    acknowledged: pending.acknowledged,
  });
  ppClearPendingWalletSeedBackups(pending.address);
  ppRenderWalletSeedBackupNotice();
  ppUpdateDepositCta();
  if ($('ppwLoadBtn')) ppwUpdateLoadButton();
  if ($('ppwWithdrawBtn')) ppwSyncWithdrawActionState();
  const shouldResumeMyPoolsLoad = _ppwLoadAfterBackup
    && $('privacyTab')?.style.display !== 'none'
    && !!_connectedAddress
    && !!_signer
    && !_ppwLoadAbort;
  _ppwLoadAfterBackup = false;
  if (shouldResumeMyPoolsLoad) {
    ppwLoadDeposits();
    return;
  }
  showStatus(
    'Recovery phrase saved.',
    'success'
  );
}

function ppGetWalletConnectPeerName() {
  return ppNormalizeWalletName(_connectedWalletProvider?.session?.peer?.metadata?.name);
}

function ppGetSavedWalletKey() {
  return String(ppReadWalletStorage('zfi_wallet') || '');
}

function ppGetSavedWalletName() {
  const walletKey = ppGetSavedWalletKey();
  if (walletKey !== 'walletconnect' && !walletKey.startsWith('eip6963_')) return '';
  return ppNormalizeWalletName(ppReadWalletStorage('zfi_wallet_name'));
}

function ppGetWalletConnectWalletName() {
  if (!_isWalletConnect) return '';
  if (ppGetSavedWalletKey() === 'walletconnect') {
    const savedWalletName = ppGetSavedWalletName();
    if (savedWalletName) return savedWalletName;
  }
  return ppGetWalletConnectPeerName();
}

function ppGetWalletCompatibilityCacheKey() {
  return [
    String(_connectedAddress || '').toLowerCase(),
    _isWalletConnect ? 'walletconnect' : 'direct',
    ppGetSavedWalletKey(),
    ppGetSavedWalletName(),
    ppGetWalletConnectWalletName(),
    _connectedWalletProvider?.isCoinbaseWallet ? 'coinbase' : '',
    _connectedWalletProvider?.isMetaMask ? 'metamask' : '',
  ].join('|');
}

function ppGetWalletCompatibilitySnapshot() {
  if (!_connectedAddress || !_signer) return { status: 'idle', result: null };
  const cacheKey = ppGetWalletCompatibilityCacheKey();
  if (_ppWalletCompatibilityState.key !== cacheKey) {
    return { status: 'idle', result: null };
  }
  return {
    status: _ppWalletCompatibilityState.status || 'idle',
    result: _ppWalletCompatibilityState.result || null,
  };
}

function ppGetWalletCompatibilityMessage(kind) {
  const ALT = ' Use privacypools.com for manual seed phrase setup with this wallet.';
  if (kind === 'walletconnect_blocked') {
    return 'This WalletConnect wallet is not supported here. Try MetaMask, Rabby, Rainbow, or Family instead.' + ALT;
  }
  if (kind === 'coinbase') {
    return 'Coinbase Wallet is not supported here.' + ALT;
  }
  if (kind === 'safe_wallet') {
    return 'Safe wallets are not supported here.' + ALT;
  }
  if (kind === 'smart_wallet') {
    return 'Smart contract wallets are not supported here.' + ALT;
  }
  if (kind === 'check_failed') {
    return 'Could not verify wallet compatibility. Please try reconnecting.';
  }
  return 'This wallet is not supported here.' + ALT;
}

function ppRenderWalletCompatibilityNotice(result = null) {
  for (const noticeId of ['ppWalletCompatDepositNotice', 'ppWalletCompatNotice']) {
    const el = $(noticeId);
    if (!el) continue;
    if (!_connectedAddress || !result || result.supported) {
      el.innerHTML = '';
      setShown(el, false);
      continue;
    }
    el.innerHTML = '<b>&#9888; Wallet support.</b> ' + escText(result.message);
    setShown(el, true);
  }
  if ($('ppwLoadBtn')) ppwUpdateLoadButton();
  if ($('ppwLoadResults')) ppwRenderIdleState();
}

function ppRenderUnsupportedWalletLoadState(result) {
  const resultsEl = $('ppwLoadResults');
  if (!resultsEl || !result || result.supported) return;
  resultsEl.innerHTML = '<div class="pp-notice-muted" style="display:block">' + escText(result.message) + '</div>';
  setShown(resultsEl, true);
  setShown('ppwParsed', false);
  setShown('ppwParsedCard', false);
}

function ppResetWalletCompatibility() {
  _ppWalletCompatibilityState = { key: null, status: 'idle', result: null, promise: null };
  ppRenderWalletCompatibilityNotice(null);
}

function ppGetWalletCompatibilityContext() {
  return {
    address: _connectedAddress,
    isWalletConnect: !!_isWalletConnect,
    savedWalletKey: ppGetSavedWalletKey(),
    savedWalletName: ppGetSavedWalletName(),
    walletConnectPeerName: ppGetWalletConnectPeerName(),
    walletConnectWalletName: ppGetWalletConnectWalletName(),
    isCoinbaseWallet: !!_connectedWalletProvider?.isCoinbaseWallet,
  };
}

function ppIsSafeWalletSession(context) {
  const walletNames = [context.savedWalletName, context.walletConnectPeerName].filter(Boolean);
  if (context.savedWalletKey === 'walletconnect' && walletNames.some(name => name.includes('safe'))) {
    return true;
  }
  return walletNames.some(name => name === 'safe wallet' || name === 'safe app' || name.includes('safe{'));
}

function ppClassifyWalletCompatibilitySession(context) {
  if (context.isWalletConnect) {
    const isWhitelisted = PP_ALLOWED_WALLETCONNECT_WALLETS.some((name) => context.walletConnectWalletName.includes(name));
    if (!isWhitelisted) {
      return {
        supported: false,
        kind: 'walletconnect_blocked',
        message: ppGetWalletCompatibilityMessage('walletconnect_blocked'),
      };
    }
  }

  const isCoinbaseWallet = context.savedWalletKey === 'coinbase'
    || context.isCoinbaseWallet
    || context.savedWalletName.includes('coinbase');
  if (isCoinbaseWallet) {
    return {
      supported: false,
      kind: 'coinbase',
      message: ppGetWalletCompatibilityMessage('coinbase'),
    };
  }

  if (ppIsSafeWalletSession(context)) {
    return {
      supported: false,
      kind: 'safe_wallet',
      message: ppGetWalletCompatibilityMessage('safe_wallet'),
    };
  }

  return null;
}

async function ppGetWalletBytecode(address) {
  if (!address) return '';
  try {
    const code = await ppReadWithRpc((rpc) => rpc.getCode(address));
    return (code && code !== '0x') ? code : '';
  } catch (err) {
    console.warn('Privacy: bytecode check failed', err);
    throw err;
  }
}

function ppClassifyWalletBytecode(bytecode) {
  const hasBytecode = !!bytecode;
  // zFi intentionally uses bytecode-based EIP-7702 detection here, not
  // wallet_getCapabilities, so wallet compatibility stays consistent across
  // deposit, My Pools, and withdraw flows.
  if (hasBytecode && bytecode.startsWith('0xef01')) {
    return { supported: true, kind: 'eoa_7702', message: '' };
  }

  if (hasBytecode) {
    return {
      supported: false,
      kind: 'smart_wallet',
      message: ppGetWalletCompatibilityMessage('smart_wallet'),
    };
  }

  return { supported: true, kind: 'eoa', message: '' };
}

async function ppDetectWalletCompatibility() {
  const context = ppGetWalletCompatibilityContext();
  const sessionResult = ppClassifyWalletCompatibilitySession(context);
  if (sessionResult) return sessionResult;
  const bytecode = await ppGetWalletBytecode(context.address);
  return ppClassifyWalletBytecode(bytecode);
}

async function ppRefreshWalletCompatibility(force = false) {
  if (!_connectedAddress || !_signer) {
    ppResetWalletCompatibility();
    return null;
  }

  const cacheKey = ppGetWalletCompatibilityCacheKey();
  if (!force && _ppWalletCompatibilityState.key === cacheKey && _ppWalletCompatibilityState.result) {
    ppRenderWalletCompatibilityNotice(_ppWalletCompatibilityState.result);
    return _ppWalletCompatibilityState.result;
  }
  if (!force && _ppWalletCompatibilityState.key === cacheKey && _ppWalletCompatibilityState.promise) {
    return _ppWalletCompatibilityState.promise;
  }

  _ppWalletCompatibilityState = {
    key: cacheKey,
    status: 'checking',
    result: null,
    promise: null,
  };
  ppRenderWalletCompatibilityNotice(null);
  ppUpdateDepositCta();
  if ($('ppwWithdrawBtn')) ppwSyncWithdrawActionState();

  const promise = (async () => {
    try {
      const result = await ppDetectWalletCompatibility();
      if (_ppWalletCompatibilityState.key === cacheKey) {
        _ppWalletCompatibilityState.status = 'ready';
        _ppWalletCompatibilityState.result = result;
        _ppWalletCompatibilityState.promise = null;
        ppRenderWalletCompatibilityNotice(result);
        ppUpdateDepositCta();
        if ($('ppwWithdrawBtn')) ppwSyncWithdrawActionState();
      }
      return result;
    } catch (err) {
      console.warn('Privacy: wallet compatibility check failed closed', err);
      const result = {
        supported: false,
        kind: 'check_failed',
        message: ppGetWalletCompatibilityMessage('check_failed'),
      };
      if (_ppWalletCompatibilityState.key === cacheKey) {
        _ppWalletCompatibilityState.status = 'ready';
        _ppWalletCompatibilityState.result = result;
        _ppWalletCompatibilityState.promise = null;
        ppRenderWalletCompatibilityNotice(result);
        ppUpdateDepositCta();
        if ($('ppwWithdrawBtn')) ppwSyncWithdrawActionState();
      }
      return result;
    }
  })();

  _ppWalletCompatibilityState.promise = promise;
  return promise;
}

async function ppEnsureWalletCompatibility() {
  if (!_signer || !_connectedAddress) {
    throw new Error('Connect wallet and sign to access your Privacy Pools account.');
  }
  const result = await ppRefreshWalletCompatibility();
  if (result && !result.supported) {
    throw new Error(result.message);
  }
  return result;
}

function ppEnsureMasterKeySession(options = {}) {
  if (!_signer || !_connectedAddress) {
    throw new Error('Connect wallet and sign to access your Privacy Pools account.');
  }
  if (!options.skipCompatibilityCheck) {
    if (typeof options.onProgress === 'function') options.onProgress('Checking wallet compatibility…');
    return ppEnsureWalletCompatibility();
  }
  return Promise.resolve();
}

function ppGetOrCreateMasterKeyStore(address = _connectedAddress) {
  const normalizedAddress = String(address || '').toLowerCase();
  if (_ppMasterKeys && String(_ppMasterKeys.address || '').toLowerCase() !== normalizedAddress) {
    ppScrubMasterKeyStore(_ppMasterKeys);
    _ppMasterKeys = null;
  }
  if (!_ppMasterKeys || String(_ppMasterKeys.address || '').toLowerCase() !== normalizedAddress) {
    _ppMasterKeys = {
      address,
      activeVersion: null,
      versions: {},
    };
  }
  return _ppMasterKeys;
}

function ppScrubMasterKeyStore(masterKeyStore) {
  if (!masterKeyStore || typeof masterKeyStore !== 'object') return;
  for (const versionKeys of Object.values(masterKeyStore.versions || {})) {
    ppScrubWalletSeedDerivedKeys(versionKeys);
  }
  masterKeyStore.address = null;
  masterKeyStore.activeVersion = null;
  masterKeyStore.versions = {};
}

function ppGetPreferredWalletSeedVersion(address = _connectedAddress, preferredVersion = null) {
  return ppGetWalletSeedVersionCandidates(address, preferredVersion)[0] || 'v2';
}

function ppGetCachedMasterKeys(masterKeyStore = _ppMasterKeys, address = _connectedAddress, walletSeedVersion = null) {
  const keyStore = masterKeyStore || _ppMasterKeys;
  const resolvedVersion = walletSeedVersion || keyStore?.activeVersion || ppGetPreferredWalletSeedVersion(address, walletSeedVersion);
  const cachedKeys = keyStore?.versions?.[resolvedVersion];
  if (!cachedKeys) return null;
  keyStore.activeVersion = resolvedVersion;
  return { ...cachedKeys, address, walletSeedVersion: resolvedVersion };
}

function ppRequireWalletSeedBackupSaved(address, walletSeedVersion) {
  const pendingBackup = ppGetPendingWalletSeedBackup(address, walletSeedVersion);
  if (!pendingBackup) return;
  ppSetActiveWalletSeedBackupPrompt(address, walletSeedVersion);
  ppRenderWalletSeedBackupNotice();
  throw ppWalletSeedBackupRequiredError();
}

function ppFinalizeDerivedMasterKeys(masterKeyStore, address, walletSeedVersion, mnemonic, onProgress = null) {
  const derivedKeys = ppDeriveWalletSeedKeys(mnemonic, onProgress);
  if (!ppHasWalletSeedBackup(address, walletSeedVersion)) {
    ppSetPendingWalletSeedBackup({
      address,
      version: walletSeedVersion,
      phrase: mnemonic.phrase,
      derivedKeys,
      downloaded: false,
      acknowledged: false,
    });
    throw ppWalletSeedBackupRequiredError();
  }
  masterKeyStore.versions[walletSeedVersion] = derivedKeys;
  masterKeyStore.activeVersion = walletSeedVersion;
  return { ...derivedKeys, address, walletSeedVersion };
}

function ppNormalizeWalletSeedVersion(version) {
  return version === 'v1' ? 'v1' : (version === 'v2' ? 'v2' : null);
}

function ppWalletSeedContext(version = 'v2') {
  return 'privacy-pools/wallet-seed:' + (ppNormalizeWalletSeedVersion(version) || version);
}

function ppWalletSeedEntropyBits(version = 'v2') {
  return version === 'v1' ? 128 : 256;
}

function ppBuildWalletSeedVersionOrder(preferredVersion = null, activeVersion = null, storedVersion = null) {
  const versions = [];
  const push = (version) => {
    const normalizedVersion = ppNormalizeWalletSeedVersion(version);
    if (normalizedVersion && !versions.includes(normalizedVersion)) {
      versions.push(normalizedVersion);
    }
  };
  push(preferredVersion);
  push(activeVersion);
  push(storedVersion);
  push('v2');
  push('v1');
  return versions;
}

function ppGetStoredWalletSeedVersion(address) {
  const normalizedAddress = String(address || '').toLowerCase();
  if (!normalizedAddress) return null;
  try {
    const raw = localStorage.getItem(PP_WALLET_SEED_VERSION_STORAGE_KEY);
    const parsed = raw ? JSON.parse(raw) : {};
    return ppNormalizeWalletSeedVersion(parsed?.[normalizedAddress]);
  } catch (_) {
    return null;
  }
}

function ppRememberWalletSeedVersion(address, version) {
  const normalizedAddress = String(address || '').toLowerCase();
  const normalizedVersion = ppNormalizeWalletSeedVersion(version);
  if (!normalizedAddress || !normalizedVersion) return;
  try {
    const raw = localStorage.getItem(PP_WALLET_SEED_VERSION_STORAGE_KEY);
    const parsed = raw ? JSON.parse(raw) : {};
    parsed[normalizedAddress] = normalizedVersion;
    localStorage.setItem(PP_WALLET_SEED_VERSION_STORAGE_KEY, JSON.stringify(parsed));
  } catch (_) {}
  if (_ppMasterKeys && String(_ppMasterKeys.address || '').toLowerCase() === normalizedAddress) {
    _ppMasterKeys.activeVersion = normalizedVersion;
  }
}

function ppGetWalletSeedVersionCandidates(address, preferredVersion = null) {
  const normalizedAddress = String(address || '').toLowerCase();
  const activeVersion = (_ppMasterKeys && String(_ppMasterKeys.address || '').toLowerCase() === normalizedAddress)
    ? _ppMasterKeys.activeVersion
    : null;
  const storedVersion = ppGetStoredWalletSeedVersion(address);
  return ppBuildWalletSeedVersionOrder(preferredVersion, activeVersion, storedVersion);
}

function ppShouldRetryWalletSeedVersion(scanResult, hasAlternateVersion = false) {
  if (!hasAlternateVersion) return false;
  const results = Array.isArray(scanResult?.results) ? scanResult.results : [];
  const warnings = Array.isArray(scanResult?.warnings) ? scanResult.warnings : [];
  return results.length === 0 && warnings.length === 0;
}

function ppBuildDepositedEventFilter(poolAddress, fromBlock, toBlock) {
  return { address: poolAddress, topics: [PP_POOL_EVENTS.getEvent('Deposited').topicHash], fromBlock, toBlock };
}

function ppGetCachedPoolEventLogs(asset, includeLeaves = false) {
  const cached = _ppwEventCache[asset];
  if (!cached) return null;
  return {
    depositLogs: cached.depositLogs || [],
    withdrawnLogs: cached.withdrawnLogs || [],
    ragequitLogs: cached.ragequitLogs || [],
    leafLogs: includeLeaves ? (cached.leafLogs || []) : [],
  };
}

// Privacy Pools uses this EIP-712 payload only for local, deterministic
// wallet-seed derivation. We never persist or transmit the signature.
function ppBuildWalletSeedTypedData(address, version = 'v2') {
  const normalizedVersion = ppNormalizeWalletSeedVersion(version) || 'v2';
  const domain = { name: 'Privacy Pools', version: '1' };
  const types = {
    DeriveSeed: [
      { name: 'action', type: 'string' },
      { name: 'context', type: 'string' },
      { name: 'addressHash', type: 'bytes32' },
    ],
  };
  const message = {
    action: 'Derive Account Seed',
    context: ppWalletSeedContext(normalizedVersion),
    addressHash: ethers.keccak256(ethers.getBytes(address)),
  };
  return { domain, types, primaryType: 'DeriveSeed', message };
}

function ppAssertWalletSeedSignatureDeterminism(signature1, signature2) {
  if (signature1 !== signature2) {
    throw new Error('Your wallet produces non-deterministic signatures and cannot be used for Privacy Pools. Please use a different wallet.');
  }
  return signature1;
}

async function ppDeriveWalletSeedSignature(_signer, address, version = 'v2', onProgress = null) {
  const { domain, types, message } = ppBuildWalletSeedTypedData(address, version);
  if (typeof onProgress === 'function') onProgress('Sign to access your Privacy Pools account (1/2)…');
  const signature1 = await _signer.signTypedData(domain, types, message);
  if (typeof onProgress === 'function') onProgress('Confirm account signature (2/2)…');
  const signature2 = await _signer.signTypedData(domain, types, message);
  return ppAssertWalletSeedSignatureDeterminism(signature1, signature2);
}

async function ppDeriveWalletSeedMnemonicFromSignature(signature, address, version = 'v2') {
  const normalizedVersion = ppNormalizeWalletSeedVersion(version) || 'v2';
  const seedContext = ppWalletSeedContext(normalizedVersion);
  const sigBytes = ethers.getBytes(signature);
  if (sigBytes.length < 65) {
    throw new Error('Invalid signature length');
  }
  const r = sigBytes.slice(0, 32);
  let entropy = null;
  try {
    // HKDF-SHA256: IKM=r, salt=address bytes, info binds the wallet-seed version.
    const ikm = await crypto.subtle.importKey('raw', r, 'HKDF', false, ['deriveBits']);
    const hkdfBits = await crypto.subtle.deriveBits(
      { name: 'HKDF', hash: 'SHA-256', salt: ethers.getBytes(address), info: new TextEncoder().encode(seedContext) },
      ikm,
      ppWalletSeedEntropyBits(normalizedVersion)
    );
    entropy = new Uint8Array(hkdfBits);
    return ethers.Mnemonic.fromEntropy(entropy);
  } finally {
    // Zero sensitive keying material after use (mirrors PP website security practice)
    r.fill(0);
    sigBytes.fill(0);
    try { if (entropy) entropy.fill(0); } catch (_) {}
  }
}

async function ppDeriveWalletSeed(_signer, address, version = 'v2', onProgress = null) {
  const signature = await ppDeriveWalletSeedSignature(_signer, address, version, onProgress);
  return ppDeriveWalletSeedMnemonicFromSignature(signature, address, version);
}

function ppGetHdPrivateKey(mnemonic, accountIndex) {
  return ethers.HDNodeWallet.fromMnemonic(mnemonic, `m/44'/60'/${accountIndex}'/0/0`).privateKey;
}

function ppLegacyBytesToNumberSeed(hexKey) {
  return BigInt(Number(BigInt(hexKey)));
}

// Privacy Pools SDK v1.2.0 derives new accounts with full-width bigint seeds.
// The legacy bytesToNumber path is retained only for backward-compatible
// account recovery and partial withdrawals on pre-fix notes.
function ppDeriveMasterKeys(mnemonic, derivation = 'safe') {
  const key1 = ppGetHdPrivateKey(mnemonic, 0);
  const key2 = ppGetHdPrivateKey(mnemonic, 1);
  const toSeed = derivation === 'legacy'
    ? ppLegacyBytesToNumberSeed
    : (hexKey) => BigInt(hexKey);
  const masterNullifier = poseidon1([toSeed(key1)]);
  const masterSecret = poseidon1([toSeed(key2)]);
  return { masterNullifier, masterSecret };
}

function ppDeriveWalletSeedKeys(mnemonic, onProgress = null) {
  if (typeof onProgress === 'function') onProgress('Deriving account…');
  return {
    safe: ppDeriveMasterKeys(mnemonic, 'safe'),
    legacy: ppDeriveMasterKeys(mnemonic, 'legacy'),
  };
}

function ppGetKeysetForDerivation(keys, derivation = 'safe') {
  return derivation === 'legacy' ? keys.legacy : keys.safe;
}

function ppDeriveDepositKeys(masterNullifier, masterSecret, scope, index) {
  const nullifier = poseidon3([masterNullifier, scope, BigInt(index)]);
  const secret = poseidon3([masterSecret, scope, BigInt(index)]);
  const precommitment = poseidon2([nullifier, secret]);
  return { nullifier, secret, precommitment };
}

const PP_UNUSED_INDEX_SEARCH_LIMIT = 50;
const PP_UNUSED_INDEX_BATCH_SIZE = 10;
const PP_ENTRYPOINT_IFACE = new ethers.Interface(PP_ENTRYPOINT_ABI);

async function ppFindUnusedDepositIndex(masterNullifier, masterSecret, scope, startIndex) {
  // Batch usedPrecommitments checks via Multicall3 instead of N serial RPC calls.
  // Pre-derive all candidate keys (synchronous poseidon hashes), then check a batch
  // at a time until we find the first unused index.
  let idx = startIndex;
  for (let batchStart = 0; batchStart < PP_UNUSED_INDEX_SEARCH_LIMIT; batchStart += PP_UNUSED_INDEX_BATCH_SIZE) {
    const batchSize = Math.min(PP_UNUSED_INDEX_BATCH_SIZE, PP_UNUSED_INDEX_SEARCH_LIMIT - batchStart);
    const candidates = [];
    for (let i = 0; i < batchSize; i++) {
      candidates.push(ppDeriveDepositKeys(masterNullifier, masterSecret, scope, idx + i));
    }
    const entries = candidates.map(keys => ({
      target: PP_ENTRYPOINT,
      data: PP_ENTRYPOINT_IFACE.encodeFunctionData('usedPrecommitments', [keys.precommitment]),
    }));
    const results = await ppReadWithRpc((rpc) => mc3ViewBatch(rpc, entries));
    for (let i = 0; i < candidates.length; i++) {
      if (!results[i]?.success) continue; // treat failed calls as "used" — safe default
      const used = PP_ENTRYPOINT_IFACE.decodeFunctionResult('usedPrecommitments', results[i].returnData)[0];
      if (!used) return idx + i;
    }
    idx += batchSize;
  }
  throw new Error('Could not find unused deposit index after ' + PP_UNUSED_INDEX_SEARCH_LIMIT + ' attempts');
}

// Label-based withdrawal key derivation (SDK-compatible for change commitments)
function ppDeriveWithdrawalKeys(masterNullifier, masterSecret, label, withdrawalIndex) {
  const nullifier = poseidon3([masterNullifier, label, BigInt(withdrawalIndex)]);
  const secret = poseidon3([masterSecret, label, BigInt(withdrawalIndex)]);
  const precommitment = poseidon2([nullifier, secret]);
  return { nullifier, secret, precommitment };
}

function ppHashHex(value) {
  return '0x' + BigInt(value).toString(16).padStart(64, '0');
}

// Keep this comfortably above sparse-account gaps so recovery does not stop
// before reaching later safe deposits or post-withdraw change notes.
// Local pending-reservation history or other clients can legitimately push the
// first live note well past index 0, and migrated legacy histories can shift
// the safe scan start index before the first live safe note appears.
const PP_ROOT_HISTORY_SIZE = 64;
const PP_ACCOUNT_SCAN_MAX_CONSECUTIVE_MISSES = 128;
const PP_PENDING_DEPOSIT_STORAGE_KEY = 'zfi_pp_pending_privacy_deposits_v1';
const PP_PENDING_DEPOSIT_RESERVATION_TTL_MS = 7 * 24 * 60 * 60 * 1000;
const PP_PENDING_DEPOSIT_UNKNOWN_TTL_MS = 2 * 60 * 60 * 1000;
const PP_PENDING_DEPOSIT_UNSIGNED_TTL_MS = 20 * 60 * 1000;

const PP_ASSET_SORT_ORDER = { ETH: 0, BOLD: 1, wstETH: 2 };
function ppCompareLoadedAccounts(a, b) {
  const assetDelta = (PP_ASSET_SORT_ORDER[a.asset] ?? 99) - (PP_ASSET_SORT_ORDER[b.asset] ?? 99);
  if (assetDelta !== 0) return assetDelta;

  const aDepositBlock = a.depositBlockNumber == null ? Number.MAX_SAFE_INTEGER : Number(a.depositBlockNumber);
  const bDepositBlock = b.depositBlockNumber == null ? Number.MAX_SAFE_INTEGER : Number(b.depositBlockNumber);
  if (aDepositBlock !== bDepositBlock) return aDepositBlock - bDepositBlock;

  const aDepositIdx = a.depositIndex == null ? Number.MAX_SAFE_INTEGER : Number(a.depositIndex);
  const bDepositIdx = b.depositIndex == null ? Number.MAX_SAFE_INTEGER : Number(b.depositIndex);
  if (aDepositIdx !== bDepositIdx) return aDepositIdx - bDepositIdx;

  const aBlock = a.blockNumber == null ? Number.MAX_SAFE_INTEGER : Number(a.blockNumber);
  const bBlock = b.blockNumber == null ? Number.MAX_SAFE_INTEGER : Number(b.blockNumber);
  if (aBlock !== bBlock) return aBlock - bBlock;

  return String(a.txHash || '').localeCompare(String(b.txHash || ''));
}

function ppPendingDepositCacheKey(address, scope) {
  return String(address || '').toLowerCase() + ':' + String(scope);
}

async function ppWithPendingDepositLock(address, scope, fn) {
  const lockKey = 'zfi-pp-deposit-lock:' + ppPendingDepositCacheKey(address, scope);
  const lockApi = typeof navigator !== 'undefined' ? navigator.locks : null;
  if (!lockApi?.request || !address) return await fn();
  return await lockApi.request(lockKey, { mode: 'exclusive' }, fn);
}

function ppLoadPendingDepositReservationsStore() {
  try {
    const raw = JSON.parse(localStorage.getItem(PP_PENDING_DEPOSIT_STORAGE_KEY) || '{}');
    return raw && typeof raw === 'object' ? raw : {};
  } catch {
    return {};
  }
}

function ppSavePendingDepositReservationsStore(store) {
  try {
    localStorage.setItem(PP_PENDING_DEPOSIT_STORAGE_KEY, JSON.stringify(store));
  } catch {}
}

function ppNormalizePendingDepositReservations(entries, minDepositIndex = 0, now = Date.now()) {
  const seen = new Set();
  return (Array.isArray(entries) ? entries : [])
    .map(entry => ({
      depositIndex: Number(entry?.depositIndex),
      txHash: entry?.txHash ? String(entry.txHash) : null,
      createdAt: Number(entry?.createdAt),
      status: entry?.status === 'confirmed' ? 'confirmed' : 'pending',
    }))
    .filter(entry => Number.isInteger(entry.depositIndex) && entry.depositIndex >= minDepositIndex)
    .filter(entry => Number.isFinite(entry.createdAt) && (now - entry.createdAt) < PP_PENDING_DEPOSIT_RESERVATION_TTL_MS)
    .sort((a, b) => a.depositIndex - b.depositIndex || b.createdAt - a.createdAt)
    .filter(entry => {
      const key = String(entry.depositIndex);
      if (seen.has(key)) return false;
      seen.add(key);
      return true;
    });
}

function ppReadPendingDepositReservations(address, scope, minDepositIndex = 0) {
  if (!address) return [];
  const key = ppPendingDepositCacheKey(address, scope);
  const store = ppLoadPendingDepositReservationsStore();
  const rawEntries = Array.isArray(store[key]) ? store[key] : [];
  const normalized = ppNormalizePendingDepositReservations(rawEntries, minDepositIndex);
  if (rawEntries.length !== normalized.length) {
    if (normalized.length) store[key] = normalized;
    else delete store[key];
    ppSavePendingDepositReservationsStore(store);
  }
  return normalized;
}

function ppWritePendingDepositReservations(address, scope, entries, minDepositIndex = 0) {
  if (!address) return [];
  const key = ppPendingDepositCacheKey(address, scope);
  const store = ppLoadPendingDepositReservationsStore();
  const normalized = ppNormalizePendingDepositReservations(entries, minDepositIndex);
  if (normalized.length) store[key] = normalized;
  else delete store[key];
  ppSavePendingDepositReservationsStore(store);
  return normalized;
}

function ppReservePendingDepositIndex(address, scope, depositIndex, txHash) {
  if (!address) return;
  const existing = ppReadPendingDepositReservations(address, scope);
  const createdAt = Date.now();
  const nextEntries = existing.filter(entry => entry.depositIndex !== depositIndex);
  nextEntries.push({ depositIndex, txHash, createdAt, status: 'pending' });
  ppWritePendingDepositReservations(address, scope, nextEntries);
}

function ppConfirmPendingDepositIndex(address, scope, depositIndex, txHash) {
  if (!address) return;
  const existing = ppReadPendingDepositReservations(address, scope);
  const current = existing.find(entry => entry.depositIndex === depositIndex);
  const nextEntries = existing.filter(entry => entry.depositIndex !== depositIndex);
  nextEntries.push({
    depositIndex,
    txHash: txHash || current?.txHash || null,
    createdAt: current?.createdAt || Date.now(),
    status: 'confirmed',
  });
  ppWritePendingDepositReservations(address, scope, nextEntries);
}

function ppClearPendingDepositIndex(address, scope, depositIndex) {
  if (!address) return;
  const existing = ppReadPendingDepositReservations(address, scope);
  ppWritePendingDepositReservations(
    address,
    scope,
    existing.filter(entry => entry.depositIndex !== depositIndex)
  );
}

function ppIsFinalFailedDepositError(err) {
  const msg = String(err?.message || err?.reason || err || '').toLowerCase();
  return (
    msg.includes('revert') ||
    msg.includes('status 0') ||
    msg.includes('call exception') ||
    msg.includes('transaction failed')
  );
}

function ppResolveReservedSafeDepositIndex(recoveredIndex, reservations) {
  const byIndex = new Map((Array.isArray(reservations) ? reservations : []).map(entry => [Number(entry.depositIndex), entry]));
  let nextIndex = recoveredIndex;
  while (true) {
    const reservation = byIndex.get(nextIndex);
    if (!reservation) return { nextIndex };
    nextIndex++;
  }
}

async function ppResolvePendingDepositReservations(address, scope, recoveredIndex) {
  if (!address) return { nextIndex: recoveredIndex };

  const reservations = ppReadPendingDepositReservations(address, scope, recoveredIndex);
  if (!reservations.length) return { nextIndex: recoveredIndex };

  const now = Date.now();
  const updated = [];
  for (const reservation of reservations) {
    let status = reservation.status === 'confirmed' ? 'confirmed' : 'pending';

    if (!reservation.txHash) {
      if ((now - reservation.createdAt) > PP_PENDING_DEPOSIT_UNSIGNED_TTL_MS) continue;
    } else {
      try {
        const receipt = await ppReadWithRpc((rpc) => rpc.getTransactionReceipt(reservation.txHash));
        if (receipt) {
          if (receipt.status === 1) status = 'confirmed';
          else continue;
        } else if (status !== 'confirmed') {
          const tx = await ppReadWithRpc((rpc) => rpc.getTransaction(reservation.txHash)).catch(() => null);
          if (!tx && (now - reservation.createdAt) > PP_PENDING_DEPOSIT_UNKNOWN_TTL_MS) continue;
        }
      } catch (err) {
        console.warn('Privacy: could not verify pending deposit reservation', reservation.txHash, err);
      }
    }

    updated.push({ ...reservation, status });
  }

  const persisted = ppWritePendingDepositReservations(address, scope, updated, recoveredIndex);
  return ppResolveReservedSafeDepositIndex(recoveredIndex, persisted);
}

function ppGetRecoveredSafeDepositIndex(migratedCount, safeRows) {
  let nextIndex = Number.isFinite(Number(migratedCount)) ? Number(migratedCount) : 0;
  for (const row of Array.isArray(safeRows) ? safeRows : []) {
    const depositIndex = Number(row?.depositIndex);
    if (Number.isInteger(depositIndex) && depositIndex >= nextIndex) {
      nextIndex = depositIndex + 1;
    }
  }
  return nextIndex;
}

function ppTraceLoadedAccountChain(initial, withdrawnMap, legacyKeys, safeKeys) {
  const depositTxHash = initial.depositTxHash;
  const depositBlockNumber = initial.depositBlockNumber;
  const initialValue = initial.value;
  let current = initial;
  let migrated = false;
  const withdrawalSteps = [];

  while (current && current.source !== 'spent') {
    const nullHashHex = ppHashHex(poseidon1([current.nullifier]));
    const w = withdrawnMap.get(nullHashHex);
    if (!w) break;

    withdrawalSteps.push({ value: w.value, txHash: w.txHash, blockNumber: w.blockNumber });
    const changeValue = BigInt(current.value) - BigInt(w.value);
    if (changeValue <= 0n) {
      if (changeValue === 0n && current.derivation === 'legacy') {
        const migratedKeys = ppDeriveWithdrawalKeys(
          safeKeys.masterNullifier,
          safeKeys.masterSecret,
          BigInt(current.label),
          0
        );
        const expectedMigratedCommitment = poseidon3([changeValue, BigInt(current.label), migratedKeys.precommitment]);
        if (w.newCommitment != null && expectedMigratedCommitment === BigInt(w.newCommitment)) {
          migrated = true;
        }
      }
      current = {
        value: '0',
        source: 'spent',
        txHash: w.txHash,
        blockNumber: w.blockNumber,
        depositTxHash,
        depositBlockNumber,
        originalValue: initialValue,
        derivation: current.derivation,
      };
      break;
    }

    const nextIndex = current.withdrawalIndex == null ? 0 : Number(current.withdrawalIndex) + 1;
    const keyset = current.derivation === 'legacy' ? legacyKeys : safeKeys;
    const changeKeys = ppDeriveWithdrawalKeys(
      keyset.masterNullifier,
      keyset.masterSecret,
      BigInt(current.label),
      nextIndex
    );
    const expectedCommitment = poseidon3([changeValue, BigInt(current.label), changeKeys.precommitment]);
    if (w.newCommitment != null && expectedCommitment === BigInt(w.newCommitment)) {
      current = {
        nullifier: changeKeys.nullifier,
        secret: changeKeys.secret,
        precommitment: changeKeys.precommitment,
        value: changeValue.toString(),
        label: current.label,
        commitment: ppHashHex(expectedCommitment),
        txHash: w.txHash,
        blockNumber: w.blockNumber,
        depositTxHash,
        depositBlockNumber,
        withdrawalIndex: nextIndex,
        source: 'change',
        derivation: current.derivation,
      };
      continue;
    }

    if (current.derivation === 'legacy') {
      const migratedIndex = 0;
      const migratedKeys = ppDeriveWithdrawalKeys(
        safeKeys.masterNullifier,
        safeKeys.masterSecret,
        BigInt(current.label),
        migratedIndex
      );
      const expectedMigratedCommitment = poseidon3([changeValue, BigInt(current.label), migratedKeys.precommitment]);
      if (w.newCommitment != null && expectedMigratedCommitment === BigInt(w.newCommitment)) {
        migrated = true;
        current = {
          nullifier: migratedKeys.nullifier,
          secret: migratedKeys.secret,
          precommitment: migratedKeys.precommitment,
          value: changeValue.toString(),
          label: current.label,
          commitment: ppHashHex(expectedMigratedCommitment),
          txHash: w.txHash,
          blockNumber: w.blockNumber,
          depositTxHash,
          depositBlockNumber,
          withdrawalIndex: migratedIndex,
          source: 'change',
          derivation: 'safe',
          migratedFrom: 'legacy',
        };
        continue;
      }
    }

    console.warn(
      'Load: change commitment mismatch for ' + current.derivation +
      ' derivation at withdrawal index ' + nextIndex + '. Skipping chain.'
    );
    current = null;
  }

  return { current, migrated, withdrawalSteps };
}

function ppCollectWalletAccountsForDerivation({
  asset,
  scope,
  poolAddress,
  depositEvents,
  withdrawnMap,
  ragequitMap,
  insertedLeaves,
  derivation,
  keyset,
  legacyKeys,
  safeKeys,
  walletSeedVersion = null,
  startIndex = 0,
  abortSignal = null,
}) {
  const results = [];
  let migratedCount = 0;
  let consecutiveMisses = 0;

  for (let index = startIndex; consecutiveMisses < PP_ACCOUNT_SCAN_MAX_CONSECUTIVE_MISSES; index++) {
    if (abortSignal?.aborted) break;
    const dk = ppDeriveDepositKeys(keyset.masterNullifier, keyset.masterSecret, scope, index);
    const pch = ppHashHex(dk.precommitment);
    const ev = depositEvents.get(pch);

    if (!ev) {
      consecutiveMisses++;
      continue;
    }
    consecutiveMisses = 0;

    const initial = {
      nullifier: dk.nullifier,
      secret: dk.secret,
      precommitment: dk.precommitment,
      value: ev.value,
      label: ev.label,
      commitment: ev.commitment,
      depositor: ev.depositor,
      txHash: ev.txHash,
      blockNumber: ev.blockNumber,
      depositTxHash: ev.txHash,
      depositBlockNumber: ev.blockNumber,
      withdrawalIndex: null,
      source: 'deposit',
      derivation,
    };

    const traced = ppTraceLoadedAccountChain(initial, withdrawnMap, legacyKeys, safeKeys);
    if (traced.migrated) migratedCount++;
    if (!traced.current) continue;

    const current = traced.current;
    const ragequitLabel = current.label != null ? current.label : initial.label;
    const ragequit = ragequitMap?.get(ppHashHex(ragequitLabel));
    if (ragequit) {
      const originalValue = current.source === 'spent'
        ? (current.originalValue ?? initial.value)
        : current.value;
      results.push({
        asset,
        depositIndex: index,
        poolAddress,
        scope,
        walletSeedVersion,
        pending: false,
        value: '0',
        label: ragequitLabel,
        txHash: ragequit.txHash,
        blockNumber: ragequit.blockNumber,
        depositTxHash: initial.depositTxHash,
        depositBlockNumber: initial.depositBlockNumber,
        originalValue: String(originalValue),
        source: 'spent',
        depositor: initial.depositor,
        derivation: current.derivation,
        ragequit: true,
      });
      continue;
    }

    const currentCommitment = current.commitment == null
      ? null
      : (typeof current.commitment === 'string' ? current.commitment : ppHashHex(current.commitment));
    const currentCommitmentInserted = !!currentCommitment && insertedLeaves.has(currentCommitment);
    const pending = current.source !== 'spent' && currentCommitment && !currentCommitmentInserted;
    results.push({
      asset,
      depositIndex: index,
      poolAddress,
      scope,
      walletSeedVersion,
      currentCommitment,
      currentCommitmentInserted,
      pending,
      depositor: initial.depositor,
      ...current,
      withdrawalSteps: traced.withdrawalSteps.length > 0 ? traced.withdrawalSteps : undefined,
    });
  }

  return { results, migratedCount };
}

function ppBuildEventMap(logs, eventName, keyFn, valueFn) {
  const map = new Map();
  for (const log of logs || []) {
    try {
      const parsed = PP_POOL_EVENTS.parseLog({ topics: log.topics, data: log.data });
      if (parsed.name === eventName) {
        map.set(keyFn(parsed.args), { ...valueFn(parsed.args), txHash: log.transactionHash, blockNumber: log.blockNumber });
      }
    } catch (err) {
      console.warn('Privacy: failed to parse ' + eventName + ' event log', err);
    }
  }
  return map;
}

function ppBuildDepositEventsMap(logs) {
  return ppBuildEventMap(logs, 'Deposited',
    (a) => ppHashHex(a._precommitmentHash),
    (a) => ({
      commitment: ppHashHex(a._commitment),
      depositor: a._depositor,
      label: a._label,
      value: a._value,
    }));
}

function ppBuildWithdrawnEventsMap(logs) {
  return ppBuildEventMap(logs, 'Withdrawn',
    (a) => ppHashHex(a._spentNullifier),
    (a) => ({ value: a._value, newCommitment: a._newCommitment }));
}

function ppBuildRagequitEventsMap(logs) {
  return ppBuildEventMap(logs, 'Ragequit',
    (a) => ppHashHex(a._label),
    (a) => ({ value: a._value }));
}

const PP_EVENT_CACHE_STORAGE_PREFIX = 'pp-events-v2-';
const PP_EVENT_CACHE_MAX_BYTES = 1_500_000; // 1.5 MB per asset

// Event logs from past blocks are immutable on-chain; safe to persist indefinitely.
function ppLoadCachedEventLogs(asset) {
  try {
    const raw = localStorage.getItem(PP_EVENT_CACHE_STORAGE_PREFIX + asset);
    if (!raw) return null;
    const parsed = JSON.parse(raw);
    if (!Array.isArray(parsed.depositLogs) || typeof parsed.upToBlock !== 'number') return null;
    // Validate every persisted bucket has the expected shape
    if (parsed.withdrawnLogs !== undefined && !Array.isArray(parsed.withdrawnLogs)) return null;
    if (parsed.ragequitLogs !== undefined && !Array.isArray(parsed.ragequitLogs)) return null;
    if (parsed.leafLogs !== undefined && !Array.isArray(parsed.leafLogs)) return null;
    if (parsed.leafUpToBlock !== undefined && typeof parsed.leafUpToBlock !== 'number') return null;
    return parsed;
  } catch { return null; }
}

function ppSlimLogEntry(l) { return { topics: l.topics, data: l.data, transactionHash: l.transactionHash, blockNumber: l.blockNumber, logIndex: l.index ?? l.logIndex ?? null }; }

function ppDropCachedEventLogs(asset) {
  // Drop caches for the asset key and all known pool-specific compound keys
  const keys = [asset];
  for (const { pool } of ppGetKnownPools(asset)) {
    keys.push(asset + ':' + pool.toLowerCase());
  }
  for (const k of keys) {
    try { localStorage.removeItem(PP_EVENT_CACHE_STORAGE_PREFIX + k); } catch {}
    try { delete _ppwEventCache[k]; } catch {}
  }
}

function ppSaveCachedEventLogs(asset, entry) {
  try {
    const slim = {
      depositLogs: (entry.depositLogs || []).map(ppSlimLogEntry),
      withdrawnLogs: (entry.withdrawnLogs || []).map(ppSlimLogEntry),
      ragequitLogs: (entry.ragequitLogs || []).map(ppSlimLogEntry),
      leafLogs: (entry.leafLogs || []).map(ppSlimLogEntry),
      upToBlock: entry.upToBlock,
      leafUpToBlock: entry.leafUpToBlock ?? null,
    };
    const json = JSON.stringify(slim);
    if (json.length > PP_EVENT_CACHE_MAX_BYTES) {
      console.warn('Privacy Pools event cache is too large for ' + asset + '; dropping cache so the next load refetches full history.');
      ppDropCachedEventLogs(asset);
      return;
    }
    localStorage.setItem(PP_EVENT_CACHE_STORAGE_PREFIX + asset, json);
  } catch {}
}

async function ppFetchPoolEventLogs(asset, includeLeaves = false, { poolAddress: explicitPool, deployBlock: explicitDeployBlock } = {}) {
  const latestBlock = await ppReadWithRpc((rpc) => rpc.getBlockNumber());
  const poolAddress = explicitPool || ppGetPoolAddress(asset);
  const deployBlock = explicitDeployBlock || PP_DEPLOYMENT_BLOCKS[asset] || PP_DEPLOYMENT_BLOCKS.ETH;
  const cacheKey = explicitPool ? (asset + ':' + explicitPool.toLowerCase()) : asset;
  if (!_ppwEventCache[cacheKey]) _ppwEventCache[cacheKey] = ppLoadCachedEventLogs(cacheKey);
  const cached = _ppwEventCache[cacheKey] || null;
  const baseUpToBlock = cached?.upToBlock;
  const baseFromBlock = baseUpToBlock != null ? baseUpToBlock + 1 : deployBlock;
  const leafUpToBlock = cached?.leafUpToBlock;
  const leafFromBlock = includeLeaves
    ? (leafUpToBlock != null ? leafUpToBlock + 1 : deployBlock)
    : null;

  const needsBaseFetch = baseUpToBlock == null || baseFromBlock <= latestBlock;
  const needsLeafFetch = includeLeaves && (leafFromBlock == null || leafFromBlock <= latestBlock);

  if (cached && !needsBaseFetch && !needsLeafFetch) {
    return ppGetCachedPoolEventLogs(cacheKey, includeLeaves);
  }

  const depositPromise = needsBaseFetch
    ? (() => {
        const dFilter = ppBuildDepositedEventFilter(poolAddress, baseFromBlock, latestBlock);
        return ppGetLogsChunked(dFilter, baseFromBlock, latestBlock);
      })()
    : Promise.resolve([]);

  const basePromises = needsBaseFetch
    ? (() => {
        const wFilter = { address: poolAddress, topics: [PP_POOL_EVENTS.getEvent('Withdrawn').topicHash], fromBlock: baseFromBlock, toBlock: latestBlock };
        const rFilter = { address: poolAddress, topics: [PP_POOL_EVENTS.getEvent('Ragequit').topicHash], fromBlock: baseFromBlock, toBlock: latestBlock };
        return [
          ppGetLogsChunked(wFilter, baseFromBlock, latestBlock),
          ppGetLogsChunked(rFilter, baseFromBlock, latestBlock),
        ];
      })()
    : [Promise.resolve([]), Promise.resolve([])];

  const leafPromise = needsLeafFetch
    ? (() => {
        const lFilter = { address: poolAddress, topics: [PP_POOL_EVENTS.getEvent('LeafInserted').topicHash], fromBlock: leafFromBlock, toBlock: latestBlock };
        return ppGetLogsChunked(lFilter, leafFromBlock, latestBlock);
      })()
    : Promise.resolve([]);

  const [newDLogs, newWLogs, newRLogs, newLLogs] = await Promise.all([depositPromise, ...basePromises, leafPromise]);
  // Re-read cache after await so concurrent loads do not stomp each other's
  // shared event snapshots. Dedup by txHash to handle multi-tab races.
  const live = _ppwEventCache[cacheKey] || null;
  function dedupLogs(existing, incoming) {
    const merged = existing.concat(incoming);
    const seen = new Set();
    return merged.filter(l => {
      const key = (l.transactionHash || '') + ':' + (l.topics?.[0] || '') + ':' + (l.blockNumber || 0) + ':' + (l.index ?? l.logIndex ?? '');
      if (seen.has(key)) return false;
      seen.add(key);
      return true;
    });
  }
  const depositLogs = dedupLogs(live?.depositLogs || cached?.depositLogs || [], newDLogs);
  const withdrawnLogs = dedupLogs(live?.withdrawnLogs || cached?.withdrawnLogs || [], newWLogs);
  const ragequitLogs = dedupLogs(live?.ragequitLogs || cached?.ragequitLogs || [], newRLogs);
  const leafLogs = includeLeaves
    ? dedupLogs(live?.leafLogs || cached?.leafLogs || [], newLLogs)
    : (live?.leafLogs || cached?.leafLogs || []);

  _ppwEventCache[cacheKey] = {
    depositLogs,
    withdrawnLogs,
    ragequitLogs,
    leafLogs,
    upToBlock: needsBaseFetch
      ? latestBlock
      : (live?.upToBlock ?? cached?.upToBlock ?? latestBlock),
    leafUpToBlock: includeLeaves
      ? (needsLeafFetch ? latestBlock : (live?.leafUpToBlock ?? leafUpToBlock ?? latestBlock))
      : (live?.leafUpToBlock ?? leafUpToBlock ?? null),
  };
  ppSaveCachedEventLogs(cacheKey, _ppwEventCache[cacheKey]);
  return { depositLogs, withdrawnLogs, ragequitLogs, leafLogs: includeLeaves ? leafLogs : [] };
}

async function ppResolveNextSafeDepositIndex(address, asset, scope, keys) {
  // Always derive the next safe slot from recovered account history.
  // Local cached indices can drift across browsers, migrations, or other clients.
  try {
    const { depositLogs, withdrawnLogs, ragequitLogs } = await ppFetchPoolEventLogs(asset, false);
    const depositEvents = ppBuildDepositEventsMap(depositLogs);
    const withdrawnMap = ppBuildWithdrawnEventsMap(withdrawnLogs);
    const ragequitMap = ppBuildRagequitEventsMap(ragequitLogs);
    const legacyScan = ppCollectWalletAccountsForDerivation({
      asset,
      scope,
      poolAddress: ppGetPoolAddress(asset),
      depositEvents,
      withdrawnMap,
      ragequitMap,
      insertedLeaves: new Set(),
      derivation: 'legacy',
      keyset: keys.legacy,
      legacyKeys: keys.legacy,
      safeKeys: keys.safe,
    });
    const safeScan = ppCollectWalletAccountsForDerivation({
      asset,
      scope,
      poolAddress: ppGetPoolAddress(asset),
      depositEvents,
      withdrawnMap,
      ragequitMap,
      insertedLeaves: new Set(),
      derivation: 'safe',
      keyset: keys.safe,
      legacyKeys: keys.legacy,
      safeKeys: keys.safe,
      startIndex: legacyScan.migratedCount,
    });
    const recoveredIndex = ppGetRecoveredSafeDepositIndex(legacyScan.migratedCount, safeScan.results);
    const reservationState = await ppResolvePendingDepositReservations(address, scope, recoveredIndex);
    return reservationState.nextIndex;
  } catch (err) {
    console.warn('Privacy: failed to recover safe deposit index', err);
    throw new Error('Could not load Privacy Pools account');
  }
}

function ppParseNonNegativeInt(raw) {
  if (raw == null || raw === '') return null;
  const n = Number(raw);
  if (!Number.isInteger(n) || n < 0) return null;
  return n;
}

const PP_MAX_INDEX_INFERENCE_SCAN = 4096;

function ppInferWithdrawalNoteIndex(masterNullifier, label, noteNullifier, maxIndex = PP_MAX_INDEX_INFERENCE_SCAN) {
  for (let i = 0; i <= maxIndex; i++) {
    if (poseidon3([masterNullifier, label, BigInt(i)]) === noteNullifier) return i;
  }
  return null;
}

function ppInferDepositNoteIndex(masterNullifier, scope, noteNullifier, maxIndex = PP_MAX_INDEX_INFERENCE_SCAN) {
  for (let i = 0; i <= maxIndex; i++) {
    if (poseidon3([masterNullifier, scope, BigInt(i)]) === noteNullifier) return i;
  }
  return null;
}

function ppResolveNextWithdrawalIndex(masterNullifier, scope, label, noteNullifier, noteWithdrawalIndex, noteDepositIndex = null) {
  const explicitIdx = ppParseNonNegativeInt(noteWithdrawalIndex);
  if (explicitIdx != null) {
    return { nextIndex: explicitIdx + 1, source: 'note', currentIndex: explicitIdx };
  }
  const explicitDepositIdx = ppParseNonNegativeInt(noteDepositIndex);
  if (explicitDepositIdx != null) {
    return { nextIndex: 0, source: 'loaded-deposit', currentIndex: null, depositIndex: explicitDepositIdx };
  }
  const inferredWithdrawalCurrent = ppInferWithdrawalNoteIndex(masterNullifier, label, noteNullifier);
  if (inferredWithdrawalCurrent != null) {
    return { nextIndex: inferredWithdrawalCurrent + 1, source: 'inferred-withdrawal', currentIndex: inferredWithdrawalCurrent };
  }
  const inferredDepositIndex = ppInferDepositNoteIndex(masterNullifier, scope, noteNullifier);
  if (inferredDepositIndex != null) {
    return { nextIndex: 0, source: 'deposit', currentIndex: null, depositIndex: inferredDepositIndex };
  }
  return { nextIndex: null, source: 'unknown', currentIndex: null, depositIndex: null };
}

async function ppEnsureMasterKeys(preferredVersion = null, options = {}) {
  // This is the single wallet-derived key entrypoint and must stay fail-closed.
  await ppEnsureMasterKeySession(options);
  const address = _connectedAddress;
  const masterKeyStore = ppGetOrCreateMasterKeyStore(address);
  const walletSeedVersion = ppGetPreferredWalletSeedVersion(address, preferredVersion);
  const cachedKeys = ppGetCachedMasterKeys(masterKeyStore, address, walletSeedVersion);
  if (cachedKeys) return cachedKeys;
  ppRequireWalletSeedBackupSaved(address, walletSeedVersion);
  const mnemonic = await ppDeriveWalletSeed(_signer, address, walletSeedVersion, options.onProgress);
  try {
    return ppFinalizeDerivedMasterKeys(masterKeyStore, address, walletSeedVersion, mnemonic, options.onProgress);
  } finally {
    // Scrub mnemonic from memory after key derivation
    try { if (mnemonic.entropy) mnemonic.entropy.fill(0); } catch (_) {}
  }
}

const PP_ETH_POOL = '0xF241d57C6DebAe225c0F2e6eA1529373C9A9C9fB';
const PP_ETH_ASSET = '0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE';
const PP_BOLD_POOL = '0xb4b5Fd38Fd4788071d7287e3cB52948e0d10b23E';
const PP_WSTETH_POOL = '0x1A604E9DFa0EFDC7FFda378AF16Cb81243b61633';

// All known pools per asset. Recovery scans every pool so historical notes
// remain discoverable even after a pool rotation. The last entry per asset
// is treated as the current pool (used for new deposits).
const PP_KNOWN_POOLS = {
  ETH:    [{ pool: PP_ETH_POOL,    deployBlock: 22153707 }],
  BOLD:   [{ pool: PP_BOLD_POOL,   deployBlock: 24433029 }],
  wstETH: [{ pool: PP_WSTETH_POOL, deployBlock: 23039970 }],
};

function ppGetKnownPools(asset) {
  const staticPools = PP_KNOWN_POOLS[asset] || [];
  // Merge the live current pool (which may come from _ppConfig at runtime)
  // so a config-driven pool rotation is picked up without a code change.
  const currentPool = ppGetPoolAddress(asset);
  const seen = new Set(staticPools.map(p => p.pool.toLowerCase()));
  if (!seen.has(currentPool.toLowerCase())) {
    return [...staticPools, { pool: currentPool, deployBlock: PP_DEPLOYMENT_BLOCKS[asset] || PP_DEPLOYMENT_BLOCKS.ETH }];
  }
  return staticPools.length ? staticPools : [{ pool: currentPool, deployBlock: PP_DEPLOYMENT_BLOCKS[asset] || PP_DEPLOYMENT_BLOCKS.ETH }];
}

function ppGetPoolAddress(asset) {
  if (asset === 'wstETH') return _ppConfigWstETH?.pool || PP_WSTETH_POOL;
  if (asset === 'BOLD') return _ppConfigBold?.pool || PP_BOLD_POOL;
  return _ppConfig?.pool || PP_ETH_POOL;
}

function ppComputeScope(asset) {
  return ppComputeScopeForPool(ppGetPoolAddress(asset), asset);
}

function ppComputeScopeForPool(poolAddress, asset) {
  const isETH = (!asset || asset === 'ETH');
  const isWSTETH = (asset === 'wstETH');
  const assetAddress = isWSTETH ? WSTETH_ADDRESS : (isETH ? PP_ETH_ASSET : BOLD_ADDRESS);
  return BigInt(ethers.keccak256('0x' +
    poolAddress.slice(2).toLowerCase() +
    '0000000000000000000000000000000000000000000000000000000000000001' +
    assetAddress.slice(2).toLowerCase()
  )) % SNARK_FIELD;
}

function ppIsTransientRpcError(err) {
  const msg = String(err?.message || err || '').toLowerCase();
  return (
    msg.includes('timeout') ||
    msg.includes('429') ||
    msg.includes('rate') ||
    msg.includes('network') ||
    msg.includes('socket') ||
    msg.includes('fetch') ||
    msg.includes('temporar') ||
    msg.includes('503') ||
    msg.includes('502') ||
    msg.includes('connection')
  );
}

function ppReadWithRpc(work) {
  return quoteRPC.call(work);
}

function ppReadEntrypoint(fn) {
  return ppReadWithRpc((rpc) => {
    const ep = new ethers.Contract(PP_ENTRYPOINT, PP_ENTRYPOINT_ABI, rpc);
    return fn(ep);
  });
}

const PP_LOG_CHUNK_MAX_DEPTH = 12;

async function ppProviderGetLogsWithRetry(request, attempts = 3) {
  for (let attempt = 0; attempt < attempts; attempt++) {
    try {
      return await ppReadWithRpc((rpc) => rpc.getLogs(request));
    } catch (err) {
      if (attempt >= attempts - 1 || !ppIsTransientRpcError(err)) throw err;
      await ppDelay(200 * (attempt + 1));
    }
  }
}

function ppIsRangeLimitedLogsError(err) {
  const msg = String(err?.message || err || '').toLowerCase();
  return (
    msg.includes('block range') ||
      msg.includes('maximum block range') ||
      msg.includes('max block range') ||
    msg.includes('query exceeds') ||
    msg.includes('exceeded max allowed range') ||
    msg.includes('too many results') ||
    /limited to 0\s*-\s*\d+\s*blocks range/.test(msg) ||
    /ranges? over \d+.*not supported/.test(msg)
  );
}

async function ppGetLogsChunked(filter, fromBlock, toBlock, chunkSize = 1250000, depth = 0) {
  try {
    return await ppProviderGetLogsWithRetry({ ...filter, fromBlock, toBlock });
  } catch (e) {
    if (!ppIsRangeLimitedLogsError(e)) throw e;
    if (fromBlock >= toBlock) throw e;
    if (depth >= PP_LOG_CHUNK_MAX_DEPTH) {
      throw new Error('RPC log range limit persisted after maximum subdivision: ' + String(e?.message || e || 'unknown error'));
    }
    const logs = [];
    const span = toBlock - fromBlock + 1;
    const nextChunkSize = Math.max(1, Math.floor(Math.min(chunkSize, span - 1) / 2));
    if (nextChunkSize >= span) throw e;
    for (let start = fromBlock; start <= toBlock; start += nextChunkSize) {
      const end = Math.min(start + nextChunkSize - 1, toBlock);
      logs.push(...await ppGetLogsChunked(filter, start, end, nextChunkSize, depth + 1));
    }
    return logs;
  }
}

let _ppConfig = null; // { pool, minimumDepositAmount, vettingFeeBPS }
let _ppConfigBold = null; // { pool, minimumDepositAmount, vettingFeeBPS }
let _ppConfigWstETH = null; // { pool, minimumDepositAmount, vettingFeeBPS }
let _ppSelectedAsset = 'ETH'; // 'ETH', 'BOLD', or 'wstETH'
let _ppZapMode = false; // ETH → wstETH → PP zap on privacy tab
let _ppSwapEnabled = false;
let _ppSavedToToken = null; // saved toToken before PP lock

function ppGetAssetDecimals(asset) {
  const t = tokens && tokens[asset];
  return t && Number.isFinite(Number(t.decimals)) ? Number(t.decimals) : 18;
}

function ppFormatAmountWei(valueWei, asset) {
  return ethers.formatUnits(valueWei, ppGetAssetDecimals(asset));
}

function ppParseAmountToWei(valueRaw, asset) {
  return ethers.parseUnits(valueRaw, ppGetAssetDecimals(asset));
}

function ppNormalizeAmountText(amountStr) {
  const s = String(amountStr || '0');
  if (!s.includes('.')) return s;
  return s
    .replace(/(\.\d*?[1-9])0+$/, '$1')
    .replace(/\.0+$/, '')
    .replace(/\.$/, '');
}

function ppGetDynamicRoundingStepWeis(amountWei, asset) {
  try { amountWei = BigInt(amountWei); } catch { return []; }
  if (amountWei <= 0n) return [];
  const decimals = ppGetAssetDecimals(asset);
  const amountStr = ppFormatAmountWei(amountWei, asset);
  const parts = amountStr.split('.');
  const whole = (parts[0] || '0').replace(/^0+/, '');
  const frac = parts[1] || '';
  let magnitude = null;
  if (whole.length > 0) magnitude = whole.length - 1;
  else {
    const firstNonZero = frac.search(/[1-9]/);
    if (firstNonZero !== -1) magnitude = -(firstNonZero + 1);
  }
  if (magnitude == null) return [];

  const exponents = magnitude >= 0
    ? [magnitude - 2, magnitude - 1, magnitude]
    : [magnitude - 1, magnitude];
  const multipliers = [1n, 2n, 5n];
  const steps = [];
  const seen = new Set();
  for (const exp of exponents) {
    const weiPow = exp + decimals;
    if (weiPow < 0) continue;
    const base = 10n ** BigInt(weiPow);
    for (const m of multipliers) {
      const stepWei = m * base;
      if (stepWei <= 0n) continue;
      const k = stepWei.toString();
      if (seen.has(k)) continue;
      seen.add(k);
      steps.push(stepWei);
    }
  }
  steps.sort((a, b) => a < b ? -1 : a > b ? 1 : 0);
  return steps;
}

function ppGetPreferredRoundingDecimals(asset, amountWei) {
  const decimals = ppGetAssetDecimals(asset);
  const symRaw = (tokens && tokens[asset] && tokens[asset].symbol) ? tokens[asset].symbol : (asset || '');
  const sym = String(symRaw).toUpperCase();
  const stableLike =
    sym.includes('USD') ||
    ['BOLD', 'DAI', 'USDC', 'USDT', 'LUSD', 'USDE', 'PYUSD', 'FDUSD', 'FRAX', 'TUSD', 'USDP', 'GUSD', 'SUSD', 'CRVUSD', 'MIM'].includes(sym);
  const ethLike = ['ETH', 'WETH', 'STETH', 'WSTETH', 'RETH', 'CBETH', 'WEETH'].includes(sym);

  const unit = 10n ** BigInt(decimals);
  const tenth = unit >= 10n ? unit / 10n : 1n;

  if (stableLike) {
    let amt = null;
    try { if (amountWei != null) amt = BigInt(amountWei); } catch {}
    if (amt != null) {
      if (amt >= unit) return 0;
      if (amt >= tenth) return 1;
      return 2;
    }
    return 0;
  }

  if (ethLike) return 3;

  const cfg = ppGetAssetConfig(asset);
  const min = (cfg && cfg.minimumDepositAmount != null) ? BigInt(cfg.minimumDepositAmount) : null;
  if (min != null && min > 0n) {
    const hundredth = unit >= 100n ? unit / 100n : 1n;
    if (min >= 10n * unit) return 0;
    if (min >= unit) return 1;
    if (min >= tenth) return 2;
    if (min >= hundredth) return 3;
    return 4;
  }

  return decimals >= 18 ? 3 : 2;
}

function ppFilterStepWeisByPreferredDecimals(stepWeis, asset, amountWei) {
  const preferred = ppGetPreferredRoundingDecimals(asset, amountWei);
  const filtered = stepWeis.filter(sw => {
    const txt = ppNormalizeAmountText(ppFormatAmountWei(sw, asset));
    const frac = (txt.split('.')[1] || '');
    return frac.length <= preferred;
  });
  return filtered.length ? filtered : stepWeis;
}

function ppGetAssetConfig(asset) {
  if (asset === 'wstETH') return _ppConfigWstETH;
  if (asset === 'BOLD') return _ppConfigBold;
  return _ppConfig;
}

function ppUseSuggestedDepositAmount(amountStr) {
  const inp = $('ppAmount');
  if (!inp) return;
  inp.value = amountStr;
  inp.dispatchEvent(new Event('input'));
}

function ppRenderDepositRoundedSuggestions() {
  const wrap = $('ppDepositSuggestWrap');
  const btns = $('ppDepositSuggestBtns');
  if (!wrap || !btns) return;

  const raw = ($('ppAmount')?.value || '').trim();
  if (!raw) {
    setShown(wrap, false);
    btns.innerHTML = '';
    return;
  }

  const inputAsset = _ppZapMode ? 'ETH' : _ppSelectedAsset;
  let amountWei;
  try { amountWei = ppParseAmountToWei(raw, inputAsset); } catch { setShown(wrap, false); btns.innerHTML = ''; return; }
  if (amountWei <= 0n) { setShown(wrap, false); btns.innerHTML = ''; return; }
  // Don't suggest rounded amounts if below the minimum deposit
  const cfg = ppGetAssetConfig(_ppSelectedAsset);
  if (cfg && amountWei < cfg.minimumDepositAmount) { setShown(wrap, false); btns.innerHTML = ''; return; }

  let stepWeis = ppGetDynamicRoundingStepWeis(amountWei, inputAsset);
  stepWeis = ppFilterStepWeisByPreferredDecimals(stepWeis, inputAsset, amountWei);
  if (!stepWeis.length) { setShown(wrap, false); btns.innerHTML = ''; return; }
  // If amount is already aligned to any configured rounded step, hide suggestions.
  if (stepWeis.some(sw => amountWei % sw === 0n)) {
    setShown(wrap, false);
    btns.innerHTML = '';
    return;
  }

  const maxSuggestedWei = (_ppBalanceRaw != null && _ppBalanceRaw > 0n) ? _ppBalanceRaw : null;
  const enforceBalanceCap = (maxSuggestedWei != null && amountWei <= maxSuggestedWei);
  const ranked = [];
  const seen = new Set();
  const pushCandidate = (candidateWei) => {
    if (candidateWei <= 0n || candidateWei === amountWei) return;
    if (enforceBalanceCap && candidateWei > maxSuggestedWei) return;
    const txt = ppNormalizeAmountText(ppFormatAmountWei(candidateWei, inputAsset));
    if (seen.has(txt)) return;
    seen.add(txt);
    const dist = candidateWei > amountWei ? candidateWei - amountWei : amountWei - candidateWei;
    const isUp = candidateWei > amountWei ? 1 : 0;
    ranked.push({ txt, candidateWei, dist, isUp });
  };

  for (const stepWei of stepWeis) {
    if (stepWei <= 0n) continue;
    const lower = (amountWei / stepWei) * stepWei;
    const upper = lower + stepWei;
    pushCandidate(lower);
    pushCandidate(upper);
  }

  ranked.sort((a, b) => {
    if (a.dist === b.dist) {
      if (a.isUp !== b.isUp) return b.isUp - a.isUp; // prefer upward rounding on ties
      if (a.candidateWei === b.candidateWei) return 0;
      return a.candidateWei > b.candidateWei ? -1 : 1; // then prefer larger amount
    }
    return a.dist < b.dist ? -1 : 1;
  });

  const suggestions = ranked.slice(0, 3).map(r => r.txt);

  if (!suggestions.length) {
    setShown(wrap, false);
    btns.innerHTML = '';
    return;
  }

  btns.innerHTML = suggestions
    .map(s => `<button type="button" onclick="ppUseSuggestedDepositAmount('${escAttr(s)}')" style="font-size:11px;padding:3px 8px;cursor:pointer;background:var(--surface);color:var(--fg-muted);border:1px solid var(--border-muted);border-radius:0;transition:color 0.15s,border-color 0.15s">${escText(s)}</button>`)
    .join('');
  setShown(wrap, true);
}

const PP_DEPOSIT_IFACE = new ethers.Interface([
  "function deposit(uint256) payable returns (uint256)",
  "function deposit(address,uint256,uint256) returns (uint256)"
]);
const PP_ZAP_ROUTER_IFACE = globalThis.ROUTER_IFACE || new ethers.Interface([
  "function multicall(bytes[]) payable returns (bytes[])",
  "function exactETHToWSTETH(address to) payable returns (uint256 wstOut)",
]);

function ppSyncAssetUI(asset) {
  // Privacy tab buttons
  const ppBtns = [
    { el: $('ppAssetETH'), key: 'ETH' },
    { el: $('ppAssetBOLD'), key: 'BOLD' },
    { el: $('ppAssetWSTETH'), key: 'wstETH' },
  ];
  for (const b of ppBtns) {
    if (!b.el) continue;
    const active = asset === b.key;
    b.el.style.background = active ? 'var(--btn-bg)' : 'var(--surface)';
    b.el.style.color = active ? 'var(--btn-fg)' : 'var(--fg-muted)';
    b.el.style.borderColor = active ? 'var(--btn-bg)' : 'transparent';
    b.el.setAttribute('aria-pressed', String(active));
  }
  // Swap tab buttons — disable the one matching fromToken (same-token swap+deposit is just a direct deposit)
  const swapBtns = [
    { el: $('ppSwapAssetETH'), key: 'ETH' },
    { el: $('ppSwapAssetBOLD'), key: 'BOLD' },
    { el: $('ppSwapAssetWSTETH'), key: 'wstETH' },
  ];
  for (const b of swapBtns) {
    if (!b.el) continue;
    const active = asset === b.key;
    const disabled = fromToken === b.key;
    b.el.disabled = disabled;
    b.el.style.background = active ? 'var(--btn-bg)' : 'var(--surface)';
    b.el.style.color = disabled ? 'var(--fg-dim)' : (active ? 'var(--btn-fg)' : 'var(--fg-muted)');
    b.el.style.borderColor = active ? 'var(--btn-bg)' : 'transparent';
    b.el.style.opacity = disabled ? '0.4' : '1';
    b.el.style.cursor = disabled ? 'not-allowed' : 'pointer';
  }
  setText('ppAmountLabel', _ppZapMode ? 'Amount (ETH \u2192 wstETH)' : `Amount (${asset})`);
  setText('ppMinUnit', asset);
}

function ppSelectAsset(asset) {
  if (_ppZapMode) ppSetZap(false);
  _ppSelectedAsset = asset;
  ppSyncAssetUI(asset);
  loadPPConfig();
  ppUpdateDepositCta();
  syncPrivacyURL();
  if (_ppSwapEnabled) {
    if (toToken !== asset) { toToken = asset; updateTokenDisplay(); }
    handleAmountChange();
  }
}

function ppToggleZap() {
  ppSetZap(!_ppZapMode);
}

function ppSetZap(on) {
  _ppZapMode = on;
  const zapBtn = $('ppZapBtn');
  if (zapBtn) {
    zapBtn.style.background = on ? 'var(--btn-bg)' : 'var(--surface)';
    zapBtn.style.color = on ? 'var(--btn-fg)' : 'var(--fg-muted)';
    zapBtn.style.borderColor = on ? 'var(--btn-bg)' : 'transparent';
  }
  setShown('ppZapInfo', on);
  if (on) {
    _ppSelectedAsset = 'wstETH';
    ppSyncAssetUI('wstETH');
    loadPPConfig();
    ppRequestZapEstimate();
  } else {
    ppClearZapEstimate();
    ppSyncAssetUI(_ppSelectedAsset);
  }
  ppUpdateDepositCta();
  syncPrivacyURL();
}

function ppSwapSelectAsset(asset) {
  if (asset === fromToken) return;
  _ppSelectedAsset = asset;
  ppSyncAssetUI(asset);
  if (toToken !== asset) { toToken = asset; updateTokenDisplay(); }
  handleAmountChange();
  loadPPConfig();
}

function togglePPSwap() {
  const w = $('ppSwapWrap');
  const open = w.style.maxHeight === '0px';
  w.style.maxHeight = open ? '200px' : '0px';
  w.style.opacity = open ? '1' : '0';
  $('ppSwapChevron').textContent = open ? '\u25BC' : '\u25B6';
}

const PP_ASSETS = ['ETH', 'BOLD', 'wstETH'];
function _isPPAsset(t) { return PP_ASSETS.includes(t); }

function onPPSwapToggle() {
  _ppSwapEnabled = $('ppSwapToggle').checked;
  setShown('ppSwapAssetWrap', _ppSwapEnabled);
  if (_ppSwapEnabled) {
    // Pick a PP deposit asset that differs from fromToken
    let target;
    if (_isPPAsset(toToken)) {
      target = toToken;
    } else {
      target = _ppSelectedAsset;
    }
    if (target === fromToken) target = PP_ASSETS.find(a => a !== fromToken) || 'ETH';
    _ppSelectedAsset = target;
    ppSyncAssetUI(target);
    if (toToken !== target) { _ppSavedToToken = toToken; toToken = target; updateTokenDisplay(); }
    handleAmountChange();
    loadPPConfig();
  } else {
    // Restore previous token
    if (_ppSavedToToken && _ppSavedToToken !== toToken) { toToken = _ppSavedToToken; updateTokenDisplay(); }
    _ppSavedToToken = null;
    handleAmountChange();
  }
}


let _ppConfigCache = null, _ppConfigCacheTs = 0;

function ppApplyConfigUI() {
  const cfg = ppGetAssetConfig(_ppSelectedAsset);
  if (cfg) {
    const feePct = (Number(cfg.vettingFeeBPS) / 100).toFixed(1);
    setText('ppFeeLabel', feePct + '%');
    setText('ppMinDeposit', fmt(ppFormatAmountWei(cfg.minimumDepositAmount, _ppSelectedAsset)));
    setText('ppMinUnit', _ppSelectedAsset);
    setShown('ppFeeInfo', true);
    ppUpdateDepositFeePreview();
  } else {
    setShown('ppFeeInfo', false);
    setShown('ppFeeAmtRow', false);
    setShown('ppNetDepositRow', false);
  }
  ppRenderDepositRoundedSuggestions();
}

function ppUpdateDepositFeePreview() {
  const cfg = ppGetAssetConfig(_ppSelectedAsset);
  const amountStr = ($('ppAmount')?.value || '').trim();
  if (!cfg || !amountStr || !(Number(amountStr) > 0)) {
    setShown('ppFeeAmtRow', false);
    setShown('ppNetDepositRow', false);
    return;
  }
  try {
    const amountWei = ethers.parseUnits(amountStr, 18);
    // Hide fee rows if below minimum — the CTA already shows "Min X ASSET"
    if (amountWei < cfg.minimumDepositAmount) {
      setShown('ppFeeAmtRow', false);
      setShown('ppNetDepositRow', false);
      return;
    }
    const feeWei = (amountWei * BigInt(cfg.vettingFeeBPS)) / 10000n;
    const netWei = amountWei - feeWei;
    setText('ppFeeAmt', fmt(ppFormatAmountWei(feeWei, _ppSelectedAsset)) + ' ' + _ppSelectedAsset);
    setText('ppNetDeposit', fmt(ppFormatAmountWei(netWei, _ppSelectedAsset)) + ' ' + _ppSelectedAsset);
    const feeAmtEl = $('ppFeeAmtRow'); if (feeAmtEl) feeAmtEl.style.display = 'flex';
    const netDepEl = $('ppNetDepositRow'); if (netDepEl) netDepEl.style.display = 'flex';
  } catch {
    setShown('ppFeeAmtRow', false);
    setShown('ppNetDepositRow', false);
  }
}

async function loadPPConfig() {
  try {
    if (_ppConfigCache && Date.now() - _ppConfigCacheTs < 60000) {
      _ppConfig = _ppConfigCache.eth;
      _ppConfigBold = _ppConfigCache.bold;
      _ppConfigWstETH = _ppConfigCache.wsteth;
      ppApplyConfigUI();
      return;
    }
    const [ethResult, boldResult, wstethResult] = await Promise.allSettled([
      ppReadEntrypoint((ep) => ep.assetConfig(PP_ETH_ASSET)),
      ppReadEntrypoint((ep) => ep.assetConfig(BOLD_ADDRESS)),
      ppReadEntrypoint((ep) => ep.assetConfig(WSTETH_ADDRESS))
    ]);
    if (ethResult.status === 'fulfilled') { const c = ethResult.value; _ppConfig = { pool: c.pool, minimumDepositAmount: c.minimumDepositAmount, vettingFeeBPS: c.vettingFeeBPS, maxRelayFeeBPS: c.maxRelayFeeBPS }; }
    else console.warn("Failed to load ETH PP config:", ethResult.reason);
    if (boldResult.status === 'fulfilled') { const c = boldResult.value; _ppConfigBold = { pool: c.pool, minimumDepositAmount: c.minimumDepositAmount, vettingFeeBPS: c.vettingFeeBPS, maxRelayFeeBPS: c.maxRelayFeeBPS }; }
    else console.warn("Failed to load BOLD PP config:", boldResult.reason);
    if (wstethResult.status === 'fulfilled') { const c = wstethResult.value; _ppConfigWstETH = { pool: c.pool, minimumDepositAmount: c.minimumDepositAmount, vettingFeeBPS: c.vettingFeeBPS, maxRelayFeeBPS: c.maxRelayFeeBPS }; }
    else { _ppConfigWstETH = null; console.warn("Failed to load wstETH PP config:", wstethResult.reason); }
    _ppConfigCache = { eth: _ppConfig, bold: _ppConfigBold, wsteth: _ppConfigWstETH };
    _ppConfigCacheTs = Date.now();
    ppApplyConfigUI();
  } catch (e) {
    console.warn("Failed to load PP config:", e);
    ppRenderDepositRoundedSuggestions();
  }
}

let _ppBalanceRaw = null;
const PP_DEPOSIT_BALANCE_REFRESH_RETRY_MS = 5_000;
let _ppDepositBalanceRefreshState = { key: null, promise: null, lastFailedKey: null, lastFailedAt: 0 };
let _ppDepositEthBalanceRefreshState = { key: null, promise: null, lastFailedKey: null, lastFailedAt: 0 };
const PP_ERC20_BALANCE_IFACE = new ethers.Interface(['function balanceOf(address) view returns (uint256)']);
const PP_ERC20_ALLOWANCE_IFACE = new ethers.Interface(['function allowance(address,address) view returns (uint256)']);
const PP_ERC20_APPROVE_ABI = ['function approve(address,uint256) returns (bool)'];
const PP_ERC20_APPROVE_IFACE = new ethers.Interface(PP_ERC20_APPROVE_ABI);
const PP_DEPOSIT_GAS_BUFFER_BPS = 15000n; // 50% safety buffer
const PP_DEPOSIT_NATIVE_DUST_BUFFER = 1_000000000000000n; // 0.001 ETH
const PP_DEPOSIT_NATIVE_FALLBACK_GAS_RESERVE = 15_000000000000000n; // 0.015 ETH
const PP_DEPOSIT_ERC20_FALLBACK_GAS_RESERVE = 15_000000000000000n; // 0.015 ETH
const PP_DEPOSIT_ZAP_FALLBACK_GAS_RESERVE = 20_000000000000000n; // 0.02 ETH

function ppGetDepositInputAsset() {
  return _ppZapMode ? 'ETH' : _ppSelectedAsset;
}

function ppGetDepositInputTokenAddress(asset = ppGetDepositInputAsset()) {
  return asset === 'wstETH' ? WSTETH_ADDRESS : (asset === 'BOLD' ? BOLD_ADDRESS : ZERO_ADDRESS);
}

function ppGetDepositBalanceRefreshKey() {
  if (!_connectedAddress) return null;
  return String(_connectedAddress).toLowerCase() + ':' + ppGetDepositInputAsset();
}

function ppIsDepositBalanceRefreshPending() {
  const key = ppGetDepositBalanceRefreshKey();
  return !!(key && _ppDepositBalanceRefreshState.key === key && _ppDepositBalanceRefreshState.promise);
}

function ppSyncDepositValidationHint(message = '', tone = 'muted') {
  const el = $('ppDepositValidationHint');
  if (!el) return;
  if (!message) {
    setText(el, '');
    setShown(el, false);
    el.style.color = 'var(--fg-muted)';
    return;
  }
  setText(el, message);
  el.style.color = tone === 'error' ? 'var(--error)' : 'var(--fg-muted)';
  setShown(el, true);
}

let _ppObservedDepositBalanceRefreshPromise = null;
let _ppObservedDepositEthBalanceRefreshPromise = null;

function ppRequestDepositBalanceRefresh(force = false) {
  if (!_connectedAddress) return null;
  const asset = ppGetDepositInputAsset();
  const tokenAddr = ppGetDepositInputTokenAddress(asset);
  const cacheKey = ppGetDepositBalanceRefreshKey();
  if (!cacheKey) return null;
  if (!force) {
    const cached = getCachedBalance(tokenAddr);
    if (cached != null) return null;
    const lastFailedAt = _ppDepositBalanceRefreshState.lastFailedKey === cacheKey
      ? _ppDepositBalanceRefreshState.lastFailedAt
      : 0;
    if (lastFailedAt && (Date.now() - lastFailedAt) < PP_DEPOSIT_BALANCE_REFRESH_RETRY_MS) {
      return null;
    }
  }
  if (_ppDepositBalanceRefreshState.promise && _ppDepositBalanceRefreshState.key === cacheKey) {
    return _ppDepositBalanceRefreshState.promise;
  }

  let refreshPromise = null;
  refreshPromise = (async () => {
    try {
      let balance;
      if (asset === 'ETH') {
        balance = await ppReadWithRpc((rpc) => rpc.getBalance(_connectedAddress));
      } else {
        const tokenAddrSnapshot = tokenAddr;
        const balRes = await ppReadWithRpc((rpc) => rpc.call({
          to: tokenAddrSnapshot,
          data: PP_ERC20_BALANCE_IFACE.encodeFunctionData('balanceOf', [_connectedAddress]),
        }));
        balance = PP_ERC20_BALANCE_IFACE.decodeFunctionResult('balanceOf', balRes)[0];
      }
      setCachedBalance(tokenAddr, balance);
      _ppDepositBalanceRefreshState.lastFailedKey = null;
      _ppDepositBalanceRefreshState.lastFailedAt = 0;
      return balance;
    } catch (_) {
      _ppDepositBalanceRefreshState.lastFailedKey = cacheKey;
      _ppDepositBalanceRefreshState.lastFailedAt = Date.now();
      return null;
    } finally {
      if (_ppDepositBalanceRefreshState.promise === refreshPromise) {
        _ppDepositBalanceRefreshState.key = null;
        _ppDepositBalanceRefreshState.promise = null;
      }
    }
  })();

  _ppDepositBalanceRefreshState.key = cacheKey;
  _ppDepositBalanceRefreshState.promise = refreshPromise;
  return refreshPromise;
}

function ppGetDepositEthBalanceRefreshKey() {
  if (!_connectedAddress) return null;
  return String(_connectedAddress).toLowerCase() + ':eth-gas';
}

function ppIsDepositEthBalanceRefreshPending() {
  const key = ppGetDepositEthBalanceRefreshKey();
  return !!(key && _ppDepositEthBalanceRefreshState.key === key && _ppDepositEthBalanceRefreshState.promise);
}

function ppRequestDepositEthBalanceRefresh(force = false) {
  if (!_connectedAddress) return null;
  const cacheKey = ppGetDepositEthBalanceRefreshKey();
  if (!cacheKey) return null;
  if (!force) {
    const cached = getCachedBalance(ZERO_ADDRESS);
    if (cached != null) return null;
    const lastFailedAt = _ppDepositEthBalanceRefreshState.lastFailedKey === cacheKey
      ? _ppDepositEthBalanceRefreshState.lastFailedAt
      : 0;
    if (lastFailedAt && (Date.now() - lastFailedAt) < PP_DEPOSIT_BALANCE_REFRESH_RETRY_MS) {
      return null;
    }
  }
  if (_ppDepositEthBalanceRefreshState.promise && _ppDepositEthBalanceRefreshState.key === cacheKey) {
    return _ppDepositEthBalanceRefreshState.promise;
  }

  let refreshPromise = null;
  refreshPromise = (async () => {
    try {
      const balance = await ppReadWithRpc((rpc) => rpc.getBalance(_connectedAddress));
      setCachedBalance(ZERO_ADDRESS, balance);
      _ppDepositEthBalanceRefreshState.lastFailedKey = null;
      _ppDepositEthBalanceRefreshState.lastFailedAt = 0;
      return balance;
    } catch (_) {
      _ppDepositEthBalanceRefreshState.lastFailedKey = cacheKey;
      _ppDepositEthBalanceRefreshState.lastFailedAt = Date.now();
      return null;
    } finally {
      if (_ppDepositEthBalanceRefreshState.promise === refreshPromise) {
        _ppDepositEthBalanceRefreshState.key = null;
        _ppDepositEthBalanceRefreshState.promise = null;
      }
    }
  })();

  _ppDepositEthBalanceRefreshState.key = cacheKey;
  _ppDepositEthBalanceRefreshState.promise = refreshPromise;
  return refreshPromise;
}

function ppRequiresSeparateEthGasBalance(intent) {
  return !!(intent && !intent.error && intent.isERC20PP);
}

function ppGetDepositFallbackGasReserve(intent) {
  if (!intent || intent.error) return 0n;
  if (intent.isZap) return PP_DEPOSIT_ZAP_FALLBACK_GAS_RESERVE;
  if (intent.isERC20PP) return PP_DEPOSIT_ERC20_FALLBACK_GAS_RESERVE;
  return PP_DEPOSIT_NATIVE_FALLBACK_GAS_RESERVE;
}

function ppGetDepositCtaGasGuard(ctx) {
  const intent = ctx?.intent;
  if (!intent || intent.error) return null;
  const gasReserve = ppGetDepositFallbackGasReserve(intent);
  if (gasReserve <= 0n) return null;

  if (ppRequiresSeparateEthGasBalance(intent)) {
    if (ctx.ethBalanceRaw == null) {
      if (ctx.ethBalanceRefreshPending) {
        return {
          pending: true,
          buttonLabel: 'Checking balance...',
          hintMessage: 'Checking ETH for gas...',
          hintTone: 'muted',
        };
      }
      return null;
    }
    if (ctx.ethBalanceRaw < gasReserve) {
      return {
        buttonLabel: 'Insufficient ETH for gas',
        hintMessage: `Keep about ${fmt(ethers.formatEther(gasReserve))} ETH for approval and deposit`,
        hintTone: 'error',
      };
    }
    return null;
  }

  if (ctx.balanceRaw == null) return null;
  if (ctx.balanceRaw < (intent.amount + gasReserve)) {
    return {
      buttonLabel: intent.isZap ? 'Keep ETH for both steps' : 'Keep ETH for gas',
      hintMessage: intent.isZap
        ? `Keep about ${fmt(ethers.formatEther(gasReserve))} ETH for both gas steps`
        : `Keep about ${fmt(ethers.formatEther(gasReserve))} ETH for gas`,
      hintTone: 'error',
    };
  }
  return null;
}

function ppGetDepositBalanceDisplayState(ctx) {
  if (!ctx.connected) {
    return { balanceRaw: null, balanceText: 'Balance: --' };
  }
  if (ctx.balanceRaw != null) {
    return {
      balanceRaw: ctx.balanceRaw,
      balanceText: `Balance: ${fmt(ppFormatAmountWei(ctx.balanceRaw, ctx.inputAsset))} ${ctx.inputAsset}`,
    };
  }
  return { balanceRaw: null, balanceText: 'Balance: ...' };
}

function ppGetDepositCtaMinimumButtonLabel(ctx) {
  if (!ctx.intent || ctx.intent.error) return null;
  if (ctx.intent.isZap) {
    if (ctx.zapConfig && ctx.zapEstimate != null && ctx.zapEstimate < ctx.zapConfig.minimumDepositAmount) {
      return `Est. below min ${fmt(ppFormatAmountWei(ctx.zapConfig.minimumDepositAmount, 'wstETH'))} wstETH`;
    }
    return null;
  }
  if (ctx.assetConfig && ctx.intent.amount < ctx.assetConfig.minimumDepositAmount) {
    return `Min ${fmt(ppFormatAmountWei(ctx.assetConfig.minimumDepositAmount, ctx.intent.selectedAsset))} ${ctx.intent.selectedAsset}`;
  }
  return null;
}

function ppBuildDepositCtaContext() {
  const connected = !!(_connectedAddress && _signer);
  const walletCompat = ppGetWalletCompatibilitySnapshot();
  const intent = ppParseDepositIntent($('ppAmount')?.value);
  const inputAsset = intent?.inputAsset || ppGetDepositInputAsset();
  const tokenAddr = ppGetDepositInputTokenAddress(inputAsset);
  const balanceRaw = connected ? getCachedBalance(tokenAddr) : null;
  const ethBalanceRaw = connected ? getCachedBalance(ZERO_ADDRESS) : null;
  const balanceRefreshKey = connected ? ppGetDepositBalanceRefreshKey() : null;
  const ethBalanceRefreshKey = connected ? ppGetDepositEthBalanceRefreshKey() : null;
  const lastFailedAt = balanceRefreshKey && _ppDepositBalanceRefreshState.lastFailedKey === balanceRefreshKey
    ? _ppDepositBalanceRefreshState.lastFailedAt
    : 0;
  const ethLastFailedAt = ethBalanceRefreshKey && _ppDepositEthBalanceRefreshState.lastFailedKey === ethBalanceRefreshKey
    ? _ppDepositEthBalanceRefreshState.lastFailedAt
    : 0;
  return {
    connected,
    walletCompat,
    accessState: connected ? ppGetPrivacyActionAccessButtonState(walletCompat) : null,
    isPrivacyVisible: $('privacyTab')?.style.display !== 'none',
    shouldRefreshWalletCompatibility: connected && $('privacyTab')?.style.display !== 'none' && walletCompat.status === 'idle',
    intent,
    inputAsset,
    selectedAsset: _ppSelectedAsset,
    assetConfig: ppGetAssetConfig(_ppSelectedAsset),
    zapConfig: _ppConfigWstETH,
    zapEstimate: _ppZapEstimate,
    balanceRaw,
    ethBalanceRaw,
    balanceRefreshKey,
    balanceRefreshPending: ppIsDepositBalanceRefreshPending(),
    balanceRefreshBackoffActive: !!(lastFailedAt && (Date.now() - lastFailedAt) < PP_DEPOSIT_BALANCE_REFRESH_RETRY_MS),
    ethBalanceRefreshKey,
    ethBalanceRefreshPending: ppIsDepositEthBalanceRefreshPending(),
    ethBalanceRefreshBackoffActive: !!(ethLastFailedAt && (Date.now() - ethLastFailedAt) < PP_DEPOSIT_BALANCE_REFRESH_RETRY_MS),
  };
}

function ppShouldRequestDepositBalanceRefresh(ctx) {
  if (!ctx?.connected) return false;
  if (ctx.accessState) return false;
  if (ctx.balanceRaw != null) return false;
  if (ctx.balanceRefreshPending || ctx.balanceRefreshBackoffActive) return false;
  return true;
}

function ppShouldRequestDepositEthBalanceRefresh(ctx) {
  if (!ctx?.connected || !ctx.intent || ctx.intent.error) return false;
  if (ctx.accessState) return false;
  if (!ppRequiresSeparateEthGasBalance(ctx.intent)) return false;
  if (ctx.ethBalanceRaw != null) return false;
  if (ctx.ethBalanceRefreshPending || ctx.ethBalanceRefreshBackoffActive) return false;
  return true;
}

function ppGetDepositCtaState(ctx) {
  const balanceState = ppGetDepositBalanceDisplayState(ctx);
  const state = {
    buttonState: null,
    hintMessage: '',
    hintTone: 'muted',
    balanceText: balanceState.balanceText,
    balanceRaw: balanceState.balanceRaw,
    shouldRefreshWalletCompatibility: !!ctx?.shouldRefreshWalletCompatibility,
  };
  if (!ctx.connected) {
    state.buttonState = ppBuildButtonState('Connect Wallet', false, () => connectWallet());
    return state;
  }
  if (ctx.accessState) {
    state.buttonState = ctx.accessState;
    return state;
  }
  if (ctx.intent?.error) {
    state.buttonState = ppBuildButtonState(ctx.intent.error, true);
    return state;
  }
  const minimumLabel = ppGetDepositCtaMinimumButtonLabel(ctx);
  if (minimumLabel) {
    state.buttonState = ppBuildButtonState(minimumLabel, true);
    return state;
  }
  if (ctx.balanceRaw == null && ctx.balanceRefreshPending) {
    state.hintMessage = 'Checking balance...';
    state.buttonState = ppBuildButtonState('Checking balance...', true);
    return state;
  }
  if (ctx.balanceRaw != null && ctx.balanceRaw < ctx.intent.amount) {
    state.hintMessage = `Insufficient ${ctx.inputAsset} balance for this deposit amount`;
    state.hintTone = 'error';
    state.buttonState = ppBuildButtonState(`Insufficient ${ctx.inputAsset} balance`, true);
    return state;
  }
  const gasGuard = ppGetDepositCtaGasGuard(ctx);
  if (gasGuard?.pending) {
    state.hintMessage = gasGuard.hintMessage;
    state.hintTone = gasGuard.hintTone;
    state.buttonState = ppBuildButtonState(gasGuard.buttonLabel, true);
    return state;
  }
  if (gasGuard) {
    state.hintMessage = gasGuard.hintMessage;
    state.hintTone = gasGuard.hintTone;
    state.buttonState = ppBuildButtonState(gasGuard.buttonLabel, true);
    return state;
  }
  if (ctx.balanceRaw != null) {
    state.hintMessage = `Available: ${fmt(ppFormatAmountWei(ctx.balanceRaw, ctx.inputAsset))} ${ctx.inputAsset}`;
  }
  state.buttonState = ppBuildButtonState(ctx.intent.isZap ? '\u26A1 Convert ETH, then deposit' : 'Deposit', false, ppDeposit);
  return state;
}

function ppRenderDepositCtaState(state) {
  const btn = $('ppDepositBtn');
  _ppBalanceRaw = state?.balanceRaw != null ? state.balanceRaw : null;
  setText('ppBalance', state?.balanceText || 'Balance: --');
  ppSyncDepositValidationHint(state?.hintMessage || '', state?.hintTone || 'muted');
  if (!btn || !state?.buttonState) return;
  ppApplyButtonState(btn, state.buttonState);
}

function ppObserveDepositBalanceRefresh(promise) {
  if (!promise || typeof promise.finally !== 'function' || _ppObservedDepositBalanceRefreshPromise === promise) {
    return promise;
  }
  _ppObservedDepositBalanceRefreshPromise = promise;
  promise.finally(() => {
    if (_ppObservedDepositBalanceRefreshPromise === promise) {
      _ppObservedDepositBalanceRefreshPromise = null;
    }
    ppUpdateDepositCta();
  }).catch(() => {});
  return promise;
}

function ppObserveDepositEthBalanceRefresh(promise) {
  if (!promise || typeof promise.finally !== 'function' || _ppObservedDepositEthBalanceRefreshPromise === promise) {
    return promise;
  }
  _ppObservedDepositEthBalanceRefreshPromise = promise;
  promise.finally(() => {
    if (_ppObservedDepositEthBalanceRefreshPromise === promise) {
      _ppObservedDepositEthBalanceRefreshPromise = null;
    }
    ppUpdateDepositCta();
  }).catch(() => {});
  return promise;
}

function ppUpdateDepositBalanceDisplay() {
  const balanceState = ppGetDepositBalanceDisplayState(ppBuildDepositCtaContext());
  _ppBalanceRaw = balanceState.balanceRaw;
  setText('ppBalance', balanceState.balanceText);
}

function setPPPercentBalance(pct) {
  if (!_connectedAddress) { connectWallet(); return; }
  if (_ppBalanceRaw == null) return;
  const balAsset = _ppZapMode ? 'ETH' : _ppSelectedAsset;
  const amount = _ppBalanceRaw * BigInt(pct) / 100n;
  $('ppAmount').value = ppFormatAmountWei(amount, balAsset);
  $('ppAmount').dispatchEvent(new Event('input'));
}

// Zap estimate: debounced Lido quote for ETH → wstETH preview
let _ppZapEstimate = null; // bigint wstETH amount or null
let _ppZapEstTimer = null;
let _ppZapEstSeq = 0;

function ppClearZapEstimate() {
  _ppZapEstimate = null;
  _ppZapEstSeq++;
  if (_ppZapEstTimer) { clearTimeout(_ppZapEstTimer); _ppZapEstTimer = null; }
  setShown('ppZapEstimate', false);
  setText('ppZapEstAmt', '--');
}

function ppRequestZapEstimate() {
  if (!_ppZapMode) { ppClearZapEstimate(); return; }
  const amtStr = $('ppAmount')?.value;
  if (!amtStr || isNaN(+amtStr) || +amtStr <= 0) { ppClearZapEstimate(); return; }
  let wei;
  try { wei = ethers.parseEther(amtStr); } catch { ppClearZapEstimate(); return; }
  if (wei <= 0n) { ppClearZapEstimate(); return; }
  _ppZapEstSeq++;
  const seq = _ppZapEstSeq;
  if (_ppZapEstTimer) clearTimeout(_ppZapEstTimer);
  setText('ppZapEstAmt', '...');
  setShown('ppZapEstimate', true);
  _ppZapEstTimer = setTimeout(async () => {
    try {
      const deadline = BigInt(Math.trunc(Date.now() / 1000) + 300);
      const [lidoResult, dexResult] = await Promise.allSettled([
        quoteRPC.call(async (rpc) => {
          const quoter = getQuoterContract(rpc);
          return quoter.quoteLido(false, WSTETH_ADDRESS, wei, { blockTag: "latest" });
        }),
        quoteRPC.call(async (rpc) => {
          const quoter = getQuoterContract(rpc);
          return quoter.buildBestSwapViaETHMulticall(
            ZROUTER_ADDRESS, _connectedAddress || ZERO_ADDRESS, false,
            ZERO_ADDRESS, WSTETH_ADDRESS,
            wei, 50n, deadline,
            0, 0, ZERO_ADDRESS, { blockTag: "latest" }
          );
        }),
      ]);
      if (seq !== _ppZapEstSeq) return; // stale
      const lidoOut = lidoResult.status === 'fulfilled' ? lidoResult.value.amountOut : 0n;
      const dexQuote = dexResult.status === 'fulfilled' ? dexResult.value : null;
      const dexOut = dexQuote ? (dexQuote.b.amountOut > 0n ? dexQuote.b.amountOut : dexQuote.a.amountOut) : 0n;
      const best = lidoOut >= dexOut ? lidoOut : dexOut;
      if (best <= 0n) { _ppZapEstimate = null; setText('ppZapEstAmt', 'no route'); return; }
      const source = lidoOut >= dexOut ? 'Lido' : 'DEX';
      const afterSlippage = best * 9950n / 10000n; // 0.5% slippage matching deposit flow
      _ppZapEstimate = afterSlippage;
      setText('ppZapEstAmt', '~' + fmt(ppFormatAmountWei(afterSlippage, 'wstETH')) + ' (' + source + ')');
      setShown('ppZapEstimate', true);
      ppUpdateDepositCta(); // re-check min with estimate
    } catch {
      if (seq !== _ppZapEstSeq) return;
      _ppZapEstimate = null;
      setText('ppZapEstAmt', '~err');
    }
  }, 400);
}

function ppUpdateDescriptions(connected) {
  const d = $('ppDepositDesc');
  const m = $('ppMyPoolsDesc');
  if (d) setShown(d, !connected);
  if (m) m.innerHTML = connected
    ? 'You can also view your balances at <a href="https://privacypools.com" target="_blank" rel="noopener">privacypools.com</a> with the same wallet.'
    : 'Connect your wallet to view pool balances, withdraw, or ragequit. You can also view your balances at <a href="https://privacypools.com" target="_blank" rel="noopener">privacypools.com</a> with the same wallet.';
  ppRenderWalletCompatibilityNotice(ppGetWalletCompatibilitySnapshot().result);
  ppRenderWalletSeedBackupNotice();
}


function ppBuildButtonState(label, disabled, action = null) {
  return { label, disabled, action };
}

function ppApplyButtonState(btn, state) {
  if (!btn || !state) return;
  setText(btn, state.label);
  setDisabled(btn, !!state.disabled);
  btn.onclick = state.action || null;
}

function ppBuildWalletRetryButtonState() {
  return ppBuildButtonState('Retry wallet check', false, () => { ppRefreshWalletCompatibility(true); });
}

function ppGetPrivacyActionAccessButtonState(walletCompat) {
  if (walletCompat.status === 'checking') {
    return ppBuildButtonState('Checking wallet...', true);
  }
  if (walletCompat.result && !walletCompat.result.supported) {
    if (walletCompat.result.kind === 'check_failed') {
      return ppBuildWalletRetryButtonState();
    }
    return ppBuildButtonState('Wallet not supported', true);
  }
  if (ppHasActiveWalletSeedBackupPrompt()) {
    return ppBuildButtonState('Save recovery phrase to continue', true);
  }
  return null;
}

function ppGetLoadButtonState(walletCompat) {
  if (!_connectedAddress || !_signer) {
    return {
      show: false,
      button: ppBuildButtonState('Connect Wallet', false, () => connectWallet()),
    };
  }

  const hasRows = Array.isArray(_ppwLoadResults) && _ppwLoadResults.length > 0;
  const shouldShow = !hasRows
    || !!_ppwLoadAbort
    || ppHasActiveWalletSeedBackupPrompt()
    || walletCompat.status !== 'ready'
    || (walletCompat.result && walletCompat.result.supported === false);

  if (_ppwLoadAbort) {
    return { show: shouldShow, button: ppBuildButtonState('Loading...', true) };
  }

  const accessState = ppGetPrivacyActionAccessButtonState(walletCompat);
  if (accessState) {
    return { show: shouldShow, button: accessState };
  }

  return {
    show: shouldShow,
    button: ppBuildButtonState(
      ppwHasReusableMasterKeys() ? 'Reload Pool Balances' : 'Sign to View Pool Balances',
      false,
      () => { ppwLoadDeposits(); }
    ),
  };
}

function ppwUpdateLoadButton() {
  const btn = $('ppwLoadBtn');
  const wrap = $('ppwLoadDisconnected');
  if (!btn || !wrap) return;
  const walletCompat = ppGetWalletCompatibilitySnapshot();
  const state = ppGetLoadButtonState(walletCompat);
  setShown(wrap, state.show);
  ppApplyButtonState(btn, state.button);
}

function ppwRenderIdleState() {
  const resultsEl = $('ppwLoadResults');
  if (!resultsEl) return;
  if (!_connectedAddress || !_signer) {
    resultsEl.innerHTML = '';
    setShown(resultsEl, false);
    return;
  }
  if (_ppwLoadAbort || _ppwLoadResults.length || _ppwLoadWarnings.length || ppwHasReusableMasterKeys()) return;
  const walletCompat = ppGetWalletCompatibilitySnapshot();
  if (walletCompat.result && walletCompat.result.supported === false) {
    resultsEl.innerHTML = '';
    setShown(resultsEl, false);
    return;
  }
  const message = ppHasActiveWalletSeedBackupPrompt()
    ? 'Save your recovery phrase before viewing your pool balances.'
    : 'Click "Sign to View Pool Balances" to access your Privacy Pools account.';
  resultsEl.innerHTML = '<div style="font-size:11px;color:var(--fg-muted);padding:8px;border:1px solid var(--border-muted);background:var(--surface)">' + escText(message) + '</div>';
  setShown(resultsEl, true);
}

function ppUpdateDepositCta() {
  if (!$('ppDepositBtn')) return;
  ppRenderDepositRoundedSuggestions();
  let ctx = ppBuildDepositCtaContext();
  if (ctx.shouldRefreshWalletCompatibility) {
    ppRefreshWalletCompatibility();
    ctx = ppBuildDepositCtaContext();
  }
  if (ppShouldRequestDepositBalanceRefresh(ctx)) {
    const refreshPromise = ppRequestDepositBalanceRefresh();
    ppObserveDepositBalanceRefresh(refreshPromise);
    ctx = ppBuildDepositCtaContext();
  }
  if (ppShouldRequestDepositEthBalanceRefresh(ctx)) {
    const ethRefreshPromise = ppRequestDepositEthBalanceRefresh();
    ppObserveDepositEthBalanceRefresh(ethRefreshPromise);
    ctx = ppBuildDepositCtaContext();
  }
  ppRenderDepositCtaState(ppGetDepositCtaState(ctx));
}

async function ppPrepareDepositKeys(asset, scope, ppKeys, btn) {
  const { masterNullifier, masterSecret } = ppKeys.safe;
  let depositIdx, nullifier, secret, precommitment;
  await ppWithPendingDepositLock(_connectedAddress, scope, async () => {
    const startIdx = await ppResolveNextSafeDepositIndex(_connectedAddress, asset, scope, ppKeys);
    depositIdx = await ppFindUnusedDepositIndex(masterNullifier, masterSecret, scope, startIdx);
    ({ nullifier, secret, precommitment } = ppDeriveDepositKeys(masterNullifier, masterSecret, scope, depositIdx));
    ppReservePendingDepositIndex(_connectedAddress, scope, depositIdx);
  });
  return { depositIdx, nullifier, secret, precommitment };
}

// Privacy Pools deposit helpers
function ppParseDepositIntent(amountRaw) {
  const amountText = String(amountRaw || '').trim();
  if (!amountText) return { error: 'Enter an amount' };
  const numericAmount = Number(amountText);
  if (!Number.isFinite(numericAmount)) return { error: 'Invalid amount' };
  if (numericAmount <= 0) return { error: 'Enter an amount' };
  const selectedAsset = _ppSelectedAsset;
  const inputAsset = _ppZapMode ? 'ETH' : selectedAsset;
  try {
    return {
      amountText,
      amount: ppParseAmountToWei(amountText, inputAsset),
      inputAsset,
      selectedAsset,
      isZap: !!_ppZapMode,
      isBOLD: selectedAsset === 'BOLD',
      isWSTETH: selectedAsset === 'wstETH',
      isERC20PP: selectedAsset === 'BOLD' || selectedAsset === 'wstETH',
    };
  } catch (_) {
    return { error: 'Invalid amount' };
  }
}

function ppCreateDepositExecutionState(intent, btn) {
  return {
    intent,
    btn,
    tx: null,
    depositIdx: null,
    depositScope: null,
    hasPendingDepositReservation: false,
  };
}

async function ppEnsureDepositWalletAccess(state) {
  setText(state.btn, 'Checking wallet...');
  setDisabled(state.btn, true);
  await ppEnsureWalletCompatibility();
  if (!_signer) {
    connectWallet();
    return false;
  }
  return true;
}

function ppGetDepositMinimumError(intent) {
  if (intent.isZap) return null;
  const cfg = ppGetAssetConfig(intent.selectedAsset);
  if (cfg && intent.amount < cfg.minimumDepositAmount) {
    return `Minimum deposit is ${fmt(ppFormatAmountWei(cfg.minimumDepositAmount, intent.selectedAsset))} ${intent.selectedAsset}`;
  }
  return null;
}

function ppGetDepositTokenAddress(intent) {
  if (!intent?.isERC20PP) return ZERO_ADDRESS;
  return intent.isWSTETH ? WSTETH_ADDRESS : BOLD_ADDRESS;
}

async function ppReadDepositEthBalance(connectedAddress = _connectedAddress, { readWithRpc = ppReadWithRpc } = {}) {
  return readWithRpc((rpc) => rpc.getBalance(connectedAddress));
}

async function ppReadDepositTokenBalance(tokenAddr, connectedAddress = _connectedAddress, { readWithRpc = ppReadWithRpc } = {}) {
  const balRes = await readWithRpc((rpc) => rpc.call({
    to: tokenAddr,
    data: PP_ERC20_BALANCE_IFACE.encodeFunctionData('balanceOf', [connectedAddress]),
  }));
  return PP_ERC20_BALANCE_IFACE.decodeFunctionResult('balanceOf', balRes)[0];
}

async function ppReadDepositTokenAllowance(tokenAddr, owner = _connectedAddress, spender = PP_ENTRYPOINT, { readWithRpc = ppReadWithRpc } = {}) {
  const allowanceRes = await readWithRpc((rpc) => rpc.call({
    to: tokenAddr,
    data: PP_ERC20_ALLOWANCE_IFACE.encodeFunctionData('allowance', [owner, spender]),
  }));
  return PP_ERC20_ALLOWANCE_IFACE.decodeFunctionResult('allowance', allowanceRes)[0];
}

async function ppReadDepositGasPrice({ readWithRpc = ppReadWithRpc } = {}) {
  const feeData = await readWithRpc((rpc) => rpc.getFeeData());
  return feeData?.maxFeePerGas ?? feeData?.gasPrice ?? 0n;
}

function ppApplyDepositGasBuffer(gasEstimate) {
  return (BigInt(gasEstimate) * PP_DEPOSIT_GAS_BUFFER_BPS) / 10000n;
}

async function ppEstimateDepositGas(tx, {
  provider = _walletProvider,
  signer = _signer,
} = {}) {
  const estimator = provider && typeof provider.estimateGas === 'function'
    ? provider
    : (signer && typeof signer.estimateGas === 'function' ? signer : null);
  if (!estimator) return null;
  try {
    return await estimator.estimateGas(tx);
  } catch {
    return null;
  }
}

function ppBuildDepositGasReserveFromEstimate(gasEstimate, gasPrice, { includeDust = false } = {}) {
  const total = ppApplyDepositGasBuffer(gasEstimate) * gasPrice;
  return includeDust ? (total + PP_DEPOSIT_NATIVE_DUST_BUFFER) : total;
}

async function ppEstimateNativeDepositGasReserve(intent, {
  connectedAddress = _connectedAddress,
  provider = _walletProvider,
  readWithRpc = ppReadWithRpc,
} = {}) {
  try {
    const gasPrice = await ppReadDepositGasPrice({ readWithRpc });
    const gasEstimate = await ppEstimateDepositGas({
      from: connectedAddress,
      to: PP_ENTRYPOINT,
      value: 1n,
      data: PP_DEPOSIT_IFACE.encodeFunctionData('deposit(uint256)', [1n]),
    }, { provider });
    if (gasEstimate == null || gasPrice <= 0n) return PP_DEPOSIT_NATIVE_FALLBACK_GAS_RESERVE;
    return ppBuildDepositGasReserveFromEstimate(gasEstimate, gasPrice, { includeDust: true });
  } catch {
    return PP_DEPOSIT_NATIVE_FALLBACK_GAS_RESERVE;
  }
}

async function ppEstimateErc20DepositGasReserve(intent, {
  connectedAddress = _connectedAddress,
  provider = _walletProvider,
  readWithRpc = ppReadWithRpc,
  tokenAddr = ppGetDepositTokenAddress(intent),
  depositAmount = intent?.amount || 0n,
  approvalNeeded = null,
} = {}) {
  try {
    // Parallelize gasPrice + allowance reads — they're independent
    const [gasPrice, allowanceResult] = await Promise.all([
      ppReadDepositGasPrice({ readWithRpc }),
      approvalNeeded == null
        ? ppReadDepositTokenAllowance(tokenAddr, connectedAddress, PP_ENTRYPOINT, { readWithRpc })
        : Promise.resolve(null),
    ]);
    if (gasPrice <= 0n) return PP_DEPOSIT_ERC20_FALLBACK_GAS_RESERVE;
    if (approvalNeeded == null) approvalNeeded = allowanceResult < depositAmount;
    let totalGas = 0n;
    if (approvalNeeded) {
      const approveGas = await ppEstimateDepositGas({
        from: connectedAddress,
        to: tokenAddr,
        data: PP_ERC20_APPROVE_IFACE.encodeFunctionData('approve', [PP_ENTRYPOINT, depositAmount]),
      }, { provider });
      if (approveGas == null) return PP_DEPOSIT_ERC20_FALLBACK_GAS_RESERVE;
      totalGas += approveGas;
    }
    const depositGas = await ppEstimateDepositGas({
      from: connectedAddress,
      to: PP_ENTRYPOINT,
      data: PP_DEPOSIT_IFACE.encodeFunctionData('deposit(address,uint256,uint256)', [tokenAddr, depositAmount, 1n]),
    }, { provider });
    if (depositGas == null) return PP_DEPOSIT_ERC20_FALLBACK_GAS_RESERVE;
    totalGas += depositGas;
    return ppBuildDepositGasReserveFromEstimate(totalGas, gasPrice);
  } catch {
    return PP_DEPOSIT_ERC20_FALLBACK_GAS_RESERVE;
  }
}

async function ppEstimateZapGasReserve(intent, plan, {
  connectedAddress = _connectedAddress,
  provider = _walletProvider,
  readWithRpc = ppReadWithRpc,
} = {}) {
  try {
    const gasPrice = await ppReadDepositGasPrice({ readWithRpc });
    if (gasPrice <= 0n) return PP_DEPOSIT_ZAP_FALLBACK_GAS_RESERVE;
    const stepOneGas = await ppEstimateDepositGas({
      from: connectedAddress,
      to: ZROUTER_ADDRESS,
      value: plan.txValue ?? intent.amount,
      data: PP_ZAP_ROUTER_IFACE.encodeFunctionData('multicall', [plan.zapSwapCalls]),
    }, { provider });
    const stepTwoGasReserve = await ppEstimateErc20DepositGasReserve({
      ...intent,
      isERC20PP: true,
      isWSTETH: true,
      isBOLD: false,
      selectedAsset: 'wstETH',
    }, {
      connectedAddress,
      provider,
      readWithRpc,
      tokenAddr: WSTETH_ADDRESS,
      depositAmount: plan.depositAmount,
    });
    if (stepOneGas == null || stepTwoGasReserve === PP_DEPOSIT_ERC20_FALLBACK_GAS_RESERVE) {
      return PP_DEPOSIT_ZAP_FALLBACK_GAS_RESERVE;
    }
    return ppBuildDepositGasReserveFromEstimate(stepOneGas, gasPrice, { includeDust: true }) + stepTwoGasReserve;
  } catch {
    return PP_DEPOSIT_ZAP_FALLBACK_GAS_RESERVE;
  }
}

async function ppGetDepositBalanceError(intent, {
  connectedAddress = _connectedAddress,
  provider = _walletProvider,
  readWithRpc = ppReadWithRpc,
} = {}) {
  try {
    if (intent.isZap) {
      const bal = await ppReadDepositEthBalance(connectedAddress, { readWithRpc });
      if (bal < intent.amount) {
        return 'Insufficient ETH. Need ' + fmt(ethers.formatEther(intent.amount)) + ' ETH';
      }
      const plan = await ppBuildZapDepositPlan(intent, { quiet: true });
      if (!plan) {
        return 'Could not quote ETH \u2192 wstETH right now. Try again shortly.';
      }
      const gasReserve = await ppEstimateZapGasReserve(intent, plan, { connectedAddress, provider, readWithRpc });
      if (bal < (intent.amount + gasReserve)) {
        return 'Insufficient ETH. Keep about ' + fmt(ethers.formatEther(gasReserve)) + ' ETH for both zap confirmations.';
      }
      return null;
    }

    if (!intent.isERC20PP) {
      const bal = await ppReadDepositEthBalance(connectedAddress, { readWithRpc });
      if (bal < intent.amount) {
        return 'Insufficient ETH. Need ' + fmt(ethers.formatEther(intent.amount)) + ' ETH';
      }
      const gasReserve = await ppEstimateNativeDepositGasReserve(intent, { connectedAddress, provider, readWithRpc });
      if (bal < (intent.amount + gasReserve)) {
        return 'Insufficient ETH. Keep about ' + fmt(ethers.formatEther(gasReserve)) + ' ETH for gas.';
      }
      return null;
    }

    const tokenAddr = ppGetDepositTokenAddress(intent);
    // Parallelize token balance + ETH gas balance reads — they're independent
    const [tokenBalance, ethBalance] = await Promise.all([
      ppReadDepositTokenBalance(tokenAddr, connectedAddress, { readWithRpc }),
      ppReadDepositEthBalance(connectedAddress, { readWithRpc }),
    ]);
    if (tokenBalance < intent.amount) {
      return 'Insufficient ' + intent.selectedAsset + ' balance';
    }
    const gasReserve = await ppEstimateErc20DepositGasReserve(intent, { connectedAddress, provider, readWithRpc, tokenAddr });
    if (ethBalance < gasReserve) {
      return 'Insufficient ETH for gas. Keep about ' + fmt(ethers.formatEther(gasReserve)) + ' ETH for approval and deposit.';
    }
  } catch (err) {
    console.warn('Privacy Pools deposit balance check failed', err);
    return 'Could not verify your balance or gas reserve. Retry when RPC connectivity is stable.';
  }
  return null;
}

async function ppEnsurePoolAcceptsDeposits(intent) {
  const poolAddress = ppGetPoolAddress(intent.isZap ? 'wstETH' : intent.selectedAsset);
  try {
    const isDead = await ppReadWithRpc((rpc) => {
      const pool = new ethers.Contract(poolAddress, PP_POOL_ABI, rpc);
      return pool.dead();
    });
    if (isDead) {
      showStatus('This Privacy Pool has been wound down and is no longer accepting deposits.', 'error');
      return false;
    }
    return true;
  } catch (poolDeadErr) {
    console.warn('Privacy: could not verify whether pool accepts deposits', poolDeadErr);
    showStatus('Could not verify whether this Privacy Pool is accepting deposits. Retry when RPC connectivity is stable.', 'error');
    return false;
  }
}

async function ppLoadDepositKeys(state, asset) {
  const ppKeys = await ppEnsureMasterKeys(null, {
    skipCompatibilityCheck: true,
    onProgress: (msg) => setText(state.btn, msg),
  });
  state.depositScope = ppComputeScope(asset);
  const prepared = await ppPrepareDepositKeys(asset, state.depositScope, ppKeys, state.btn);
  state.depositIdx = prepared.depositIdx;
  state.hasPendingDepositReservation = true;
  return prepared;
}

async function ppBuildZapDepositPlan(intent, { quiet = false } = {}) {
  const zapCfg = _ppConfigWstETH;
  const slippageBps = 50; // 0.5% default for staking
  const deadline = BigInt(Math.trunc(Date.now() / 1000) + 300);
  const [lidoResult, dexResult] = await Promise.allSettled([
    withRetry(() => quoteRPC.call(async (rpc) => {
      const quoter = getQuoterContract(rpc);
      return quoter.quoteLido(false, WSTETH_ADDRESS, intent.amount, { blockTag: 'latest' });
    })),
    withRetry(() => quoteRPC.call(async (rpc) => {
      const quoter = getQuoterContract(rpc);
      return quoter.buildBestSwapViaETHMulticall(
        ZROUTER_ADDRESS, _connectedAddress, false,
        ZERO_ADDRESS, WSTETH_ADDRESS,
        intent.amount, BigInt(slippageBps), deadline,
        0, 0, ZERO_ADDRESS, { blockTag: 'latest' }
      );
    })),
  ]);
  const lidoOut = lidoResult.status === 'fulfilled' ? lidoResult.value.amountOut : 0n;
  const dexQuote = dexResult.status === 'fulfilled' ? dexResult.value : null;
  const dexOut = dexQuote ? (dexQuote.b.amountOut > 0n ? dexQuote.b.amountOut : dexQuote.a.amountOut) : 0n;

  let zapSwapCalls;
  let depositAmount;
  let txValue = intent.amount;
  const useLido = lidoOut > 0n && lidoOut >= dexOut;
  if (useLido) {
    zapSwapCalls = [PP_ZAP_ROUTER_IFACE.encodeFunctionData('exactETHToWSTETH', [_connectedAddress])];
    depositAmount = lidoOut * (10000n - BigInt(slippageBps)) / 10000n;
  } else if (dexOut > 0n && dexQuote) {
    zapSwapCalls = dexQuote.calls ? Array.from(dexQuote.calls) : decodeMulticallCalls(dexQuote.multicall);
    depositAmount = dexOut * (10000n - BigInt(slippageBps)) / 10000n;
    txValue = dexQuote.msgValue ?? intent.amount;
  } else {
    if (!quiet) showStatus('No route found for ETH \u2192 wstETH. Try again later.', 'error');
    return null;
  }

  if (zapCfg && depositAmount < zapCfg.minimumDepositAmount) {
    if (!quiet) {
      showStatus(
        `Estimated wstETH output (${fmt(ppFormatAmountWei(depositAmount, 'wstETH'))}) below minimum deposit of ${fmt(ppFormatAmountWei(zapCfg.minimumDepositAmount, 'wstETH'))} wstETH`,
        'error'
      );
    }
    return null;
  }

  return {
    depositAmount,
    routeLabel: useLido ? 'Lido' : 'DEX',
    zapSwapCalls,
    txValue,
  };
}

async function ppResolveErc20DepositPermitPrefix(tokenAddr, tokenLabel, amount, btn) {
  const routerAllowance = await ppReadWithRpc(async (rpc) => {
    const tokenRead = new ethers.Contract(tokenAddr, ['function allowance(address,address) view returns (uint256)'], rpc);
    return tokenRead.allowance(_connectedAddress, ZROUTER_ADDRESS);
  });
  if (routerAllowance >= amount) return [];

  const permitCfg = await getPermitConfig(tokenAddr);
  if (permitCfg) {
    try {
      setText(btn, 'Sign permit...');
      const permitData = await signPermit(permitCfg, tokenAddr);
      return [ROUTER_IFACE.encodeFunctionData('permit', [
        tokenAddr,
        ethers.MaxUint256,
        permitData.deadline,
        permitData.v,
        permitData.r,
        permitData.s,
      ])];
    } catch (e) {
      if (/user rejected|user denied|user cancelled/i.test(String(e?.message))) throw e;
      console.warn(tokenLabel + ' permit failed, trying permit2:', e);
    }
  }

  try {
    const p2Allowance = cacheGetAllowance(tokenAddr, _connectedAddress, PERMIT2_ADDRESS);
    if (p2Allowance == null || p2Allowance < amount) {
      setText(btn, `Approve ${tokenLabel} for Permit2...`);
      const erc20W = new ethers.Contract(tokenAddr, ERC20_APPROVE_ABI, _signer);
      const p2ApproveTx = await wcTransaction(erc20W.approve(PERMIT2_ADDRESS, ethers.MaxUint256), `Approve ${tokenLabel} for Permit2`);
      await waitForTx(p2ApproveTx);
      cacheSetAllowance(tokenAddr, _connectedAddress, PERMIT2_ADDRESS, ethers.MaxUint256);
    }
    setText(btn, 'Sign Permit2...');
    const permit2Data = await signPermit2(tokenAddr, amount);
    return [ROUTER_IFACE.encodeFunctionData('permit2TransferFrom', [
      tokenAddr,
      amount,
      permit2Data.nonce,
      permit2Data.deadline,
      permit2Data.signature,
    ])];
  } catch (e) {
    if (/user rejected|user denied|user cancelled/i.test(String(e?.message))) throw e;
    console.warn(tokenLabel + ' permit2 failed, falling back to approve:', e);
  }

  setText(btn, `Approve ${tokenLabel}...`);
  const tokenW = new ethers.Contract(tokenAddr, ERC20_APPROVE_ABI, _signer);
  const approveTx = await wcTransaction(tokenW.approve(ZROUTER_ADDRESS, ethers.MaxUint256), `Approve ${tokenLabel} spending`);
  await waitForTx(approveTx);
  return [];
}

function ppMarkPendingDepositSubmitted(state, tx, confirmationLabel = 'deposit') {
  state.tx = tx;
  ppReservePendingDepositIndex(_connectedAddress, state.depositScope, state.depositIdx, tx.hash);
  setShown('ppNoteBox', true);
  state.btn.innerHTML = `Confirming ${confirmationLabel}... <a href="https://etherscan.io/tx/${escAttr(tx.hash)}" target="_blank" style="color:inherit;text-decoration:underline;font-weight:400">view tx &#8599;</a>`;
}

async function ppFinalizeDepositTransaction(state, submission) {
  const { tx, successMessage, invalidateAsset } = submission;
  let receipt;
  try {
    receipt = await waitForTx(tx);
  } catch (waitErr) {
    if (ppIsFinalFailedDepositError(waitErr)) {
      ppClearPendingDepositIndex(_connectedAddress, state.depositScope, state.depositIdx);
    }
    throw waitErr;
  }

  if (receipt?.status === 1) {
    ppConfirmPendingDepositIndex(_connectedAddress, state.depositScope, state.depositIdx, tx.hash);
    ppInvalidatePoolViewCaches(invalidateAsset);
    ppwScheduleMutationRefreshes();
    showStatus(successMessage, 'success');
  } else {
    if (receipt?.status === 0) ppClearPendingDepositIndex(_connectedAddress, state.depositScope, state.depositIdx);
    showStatus('Transaction may have failed. Check Etherscan.', 'error');
  }
  ppUpdateDepositBalanceDisplay();
}

async function ppSubmitZapDeposit(state) {
  if (!_signer) {
    connectWallet();
    return null;
  }
  setText(state.btn, 'Quoting ETH \u2192 wstETH...');
  setDisabled(state.btn, true);
  const plan = await ppBuildZapDepositPlan(state.intent);
  if (!plan) return null;
  const { precommitment } = await ppLoadDepositKeys(state, 'wstETH');
  const startingWstEthBalance = await ppReadDepositTokenBalance(WSTETH_ADDRESS, _connectedAddress);
  try {
    setText(state.btn, `Confirm ${plan.routeLabel} conversion...`);
    const swapTx = await wcTransaction(
      _signer.sendTransaction({
        to: ZROUTER_ADDRESS,
        data: PP_ZAP_ROUTER_IFACE.encodeFunctionData('multicall', [plan.zapSwapCalls]),
        value: plan.txValue ?? state.intent.amount,
      }),
      'Confirm ETH \u2192 wstETH conversion'
    );
    state.btn.innerHTML = `Confirming conversion... <a href="https://etherscan.io/tx/${escAttr(swapTx.hash)}" target="_blank" style="color:inherit;text-decoration:underline;font-weight:400">view tx &#8599;</a>`;
    const swapReceipt = await waitForTx(swapTx);
    if (swapReceipt?.status !== 1) {
      throw new Error('ETH to wstETH conversion failed');
    }

    const endingWstEthBalance = await ppReadDepositTokenBalance(WSTETH_ADDRESS, _connectedAddress);
    setCachedBalance(WSTETH_ADDRESS, endingWstEthBalance);
    const receivedAmount = endingWstEthBalance > startingWstEthBalance
      ? endingWstEthBalance - startingWstEthBalance
      : 0n;
    if (receivedAmount <= 0n) {
      ppClearPendingDepositIndex(_connectedAddress, state.depositScope, state.depositIdx);
      showStatus('Your ETH was converted, but the received wstETH amount could not be confirmed. The Privacy Pools deposit was not submitted.', 'error');
      return null;
    }
    if (_ppConfigWstETH && receivedAmount < _ppConfigWstETH.minimumDepositAmount) {
      ppClearPendingDepositIndex(_connectedAddress, state.depositScope, state.depositIdx);
      showStatus(
        `Received ${fmt(ppFormatAmountWei(receivedAmount, 'wstETH'))} wstETH, which is below the minimum Privacy Pools deposit. The converted wstETH remains in your wallet.`,
        'error'
      );
      return null;
    }

    const allowance = await ppReadDepositTokenAllowance(WSTETH_ADDRESS, _connectedAddress, PP_ENTRYPOINT);
    if (allowance < receivedAmount) {
      setText(state.btn, 'Approve wstETH...');
      const tokenW = new ethers.Contract(WSTETH_ADDRESS, PP_ERC20_APPROVE_ABI, _signer);
      const approveTx = await wcTransaction(
        tokenW.approve(PP_ENTRYPOINT, receivedAmount),
        'Approve wstETH for Privacy Pools'
      );
      await waitForTx(approveTx);
    }

    const ep = new ethers.Contract(PP_ENTRYPOINT, PP_ENTRYPOINT_ABI, _signer);
    setText(state.btn, 'Confirm Privacy Pools deposit...');
    const tx = await wcTransaction(
      ep['deposit(address,uint256,uint256)'](WSTETH_ADDRESS, receivedAmount, precommitment),
      'Confirm Privacy Pools deposit'
    );
    ppMarkPendingDepositSubmitted(state, tx, 'deposit');
    return {
      tx,
      successMessage: `Zap complete! ETH converted via ${plan.routeLabel}, then deposited to Privacy Pools.`,
      invalidateAsset: 'wstETH',
    };
  } catch (err) {
    ppClearPendingDepositIndex(_connectedAddress, state.depositScope, state.depositIdx);
    throw err;
  }
}

async function ppSubmitErc20Deposit(state) {
  const tokenAddr = state.intent.isWSTETH ? WSTETH_ADDRESS : BOLD_ADDRESS;
  const tokenLabel = state.intent.isWSTETH ? 'wstETH' : 'BOLD';
  const { precommitment } = await ppLoadDepositKeys(state, state.intent.selectedAsset);
  const allowance = await ppReadDepositTokenAllowance(tokenAddr, _connectedAddress, PP_ENTRYPOINT);
  try {
    if (allowance < state.intent.amount) {
      setText(state.btn, `Approve ${tokenLabel}...`);
      const tokenW = new ethers.Contract(tokenAddr, PP_ERC20_APPROVE_ABI, _signer);
      const approveTx = await wcTransaction(
        tokenW.approve(PP_ENTRYPOINT, state.intent.amount),
        `Approve ${tokenLabel} for Privacy Pools`
      );
      await waitForTx(approveTx);
    }

    const ep = new ethers.Contract(PP_ENTRYPOINT, PP_ENTRYPOINT_ABI, _signer);
    setText(state.btn, 'Confirm in wallet...');
    const tx = await wcTransaction(
      ep['deposit(address,uint256,uint256)'](tokenAddr, state.intent.amount, precommitment),
      `Confirm ${tokenLabel} Privacy Pools deposit`
    );
    ppMarkPendingDepositSubmitted(state, tx, 'deposit');
    return {
      tx,
      successMessage: 'Deposit confirmed!',
      invalidateAsset: state.intent.selectedAsset,
    };
  } catch (err) {
    ppClearPendingDepositIndex(_connectedAddress, state.depositScope, state.depositIdx);
    throw err;
  }
}

async function ppSubmitEthDeposit(state) {
  const ep = new ethers.Contract(PP_ENTRYPOINT, PP_ENTRYPOINT_ABI, _signer);
  const { precommitment } = await ppLoadDepositKeys(state, state.intent.selectedAsset);
  try {
    setText(state.btn, 'Confirm in wallet...');
    const tx = await wcTransaction(
      ep['deposit(uint256)'](precommitment, { value: state.intent.amount }),
      'Confirm Privacy Pools deposit'
    );
    ppMarkPendingDepositSubmitted(state, tx, 'deposit');
    return {
      tx,
      successMessage: 'Deposit confirmed!',
      invalidateAsset: state.intent.selectedAsset,
    };
  } catch (err) {
    ppClearPendingDepositIndex(_connectedAddress, state.depositScope, state.depositIdx);
    throw err;
  }
}

async function ppSubmitStandardDeposit(state) {
  return state.intent.isERC20PP ? ppSubmitErc20Deposit(state) : ppSubmitEthDeposit(state);
}

function ppHandleDepositExecutionError(state, e) {
  if (state?.hasPendingDepositReservation && state.depositScope != null && state.depositIdx != null && !state.tx?.hash) {
    ppClearPendingDepositIndex(_connectedAddress, state.depositScope, state.depositIdx);
  }
  if (e.code === 'PP_WALLET_SEED_BACKUP_REQUIRED') {
    showStatus('Save your recovery phrase to continue.', 'error');
    return;
  }
  const errStr = String(e?.data || e?.message || e?.reason || e || '');
  const inputAsset = state?.intent?.isZap ? 'ETH' : (state?.intent?.selectedAsset || _ppSelectedAsset);
  const ppDepositErrors = {
    INSUFFICIENT_FUNDS: `Insufficient ${inputAsset} balance for this deposit.`,
    'insufficient funds': `Insufficient ${inputAsset} balance for this deposit.`,
    PrecommitmentAlreadyUsed: 'This precommitment has already been used. Try a new deposit.',
    InsufficientAllowance: 'Insufficient token allowance. Please approve spending first.',
    InsufficientBalance: 'Insufficient balance for this deposit amount.',
    PoolIsDead: 'This Privacy Pool has been wound down and is no longer accepting deposits.',
    'Could not load Privacy Pools account': 'Could not load your Privacy Pools account. Try again.',
  };
  for (const [key, msg] of Object.entries(ppDepositErrors)) {
    if (errStr.includes(key)) {
      showStatus(msg, 'error');
      return;
    }
  }
  handleError(e);
}

async function ppDeposit() {
  const btn = $('ppDepositBtn');
  const intent = ppParseDepositIntent($('ppAmount')?.value);
  if (intent.error) {
    showStatus(intent.error, 'error');
    return;
  }
  const state = ppCreateDepositExecutionState(intent, btn);
  try {
    const hasWalletAccess = await ppEnsureDepositWalletAccess(state);
    if (!hasWalletAccess) return;

    const minimumError = ppGetDepositMinimumError(intent);
    if (minimumError) {
      showStatus(minimumError, 'error');
      return;
    }

    const balanceError = await ppGetDepositBalanceError(intent);
    if (balanceError) {
      showStatus(balanceError, 'error');
      return;
    }

    if (!(await ppEnsurePoolAcceptsDeposits(intent))) return;

    const submission = intent.isZap
      ? await ppSubmitZapDeposit(state)
      : await ppSubmitStandardDeposit(state);
    if (!submission) return;

    await ppFinalizeDepositTransaction(state, submission);
  } catch (e) {
    ppHandleDepositExecutionError(state, e);
  } finally {
    ppUpdateDepositCta();
  }
}


// Wire up ppAmount input
document.addEventListener("DOMContentLoaded", () => {
  const ppAmtEl = $("ppAmount");
  if (ppAmtEl) {
    ppAmtEl.addEventListener("input", () => { ppUpdateDepositCta(); ppUpdateDepositFeePreview(); syncPrivacyURL(); ppRequestZapEstimate(); });
    ppAmtEl.addEventListener("blur", () => { if (ppAmtEl.value && !isNaN(ppAmtEl.value)) ppAmtEl.value = +ppAmtEl.value; });
  }
  ppRenderDepositRoundedSuggestions();

  // Populate PP asset selector icons
  document.querySelectorAll('.pp-icon-16[data-icon]').forEach(el => {
    const icon = ICONS[el.dataset.icon];
    if (icon) el.innerHTML = icon;
  });
  document.querySelectorAll('.pp-icon-18[data-icon]').forEach(el => {
    const icon = ICONS[el.dataset.icon];
    if (icon) el.innerHTML = icon;
  });

  // Deeplink: ?tab=privacy or #privacy (skip if already on the right tab via PP deep link)
  const _urlp2 = new URLSearchParams(window.location.search);
  if (_activeTab !== 'privacy' && (_urlp2.get('tab') === 'privacy' || window.location.hash === '#privacy')) switchTab('privacy');
  if (_activeTab !== 'coin' && (_urlp2.get('tab') === 'coin' || window.location.hash === '#coin')) switchTab('coin');

  // Wire up preview updates on withdraw inputs
  const _ppwAmtEl = $('ppwWithdrawAmt');
  if (_ppwAmtEl) _ppwAmtEl.addEventListener('input', ppwUpdatePreview);
  const _ppwRecipientEl = $('ppwRecipient');
  if (_ppwRecipientEl) _ppwRecipientEl.addEventListener('input', ppwOnRecipientInput);
  const _ppwExtraGasEl = $('ppwExtraGas');
  if (_ppwExtraGasEl) _ppwExtraGasEl.addEventListener('change', ppwUpdatePreview);

  // Keep withdrawal mode UI and behavior in sync with relay-first default.
  ppwSetMode(_ppwMode);

});

const PP_POOL_ABI = [
  "function ragequit(tuple(uint256[2],uint256[2][2],uint256[2],uint256[4]))",
  "function withdraw(tuple(address,bytes),tuple(uint256[2],uint256[2][2],uint256[2],uint256[8]))",
  "function SCOPE() view returns (uint256)",
  "function currentRoot() view returns (uint256)",
  "function roots(uint256) view returns (uint256)",
  "function WITHDRAWAL_VERIFIER() view returns (address)",
  "function RAGEQUIT_VERIFIER() view returns (address)",
  "function nullifierHashes(uint256) view returns (bool)",
  "function dead() view returns (bool)"
];
const PP_VERIFIER_ABI = [
  "function verifyProof(uint256[2],uint256[2][2],uint256[2],uint256[8]) returns (bool)"
];
const PP_RAGEQUIT_VERIFIER_ABI = [
  "function verifyProof(uint256[2],uint256[2][2],uint256[2],uint256[4]) returns (bool)"
];
const PP_MAX_TREE_DEPTH = 32;
const PP_SNARKJS_SRC = './vendor/snarkjs.min.js';
const PP_SNARKJS_INTEGRITY = 'sha384-5C3lIE3PUFoPsYZ/bNSvfCiuptqUGqsf0RKUh9iAW3S7c62I3SUONh+JcJ7Bfcir';
// Proving artifacts are fetched from 0xbow's upstream CDN and verified locally
// via SHA-256 before use. Vendoring ~23 MB of circuit binaries into the app
// bundle is impractical for IPFS/ENS-hosted deployments; integrity is enforced
// by the hash check in fetchAndVerify(), not by the fetch origin.
const PP_WITHDRAW_WASM = "https://privacypools.com/artifacts/withdraw.wasm";
const PP_WITHDRAW_ZKEY = "https://privacypools.com/artifacts/withdraw.zkey";
const PP_COMMITMENT_WASM = "https://privacypools.com/artifacts/commitment.wasm";
const PP_COMMITMENT_ZKEY = "https://privacypools.com/artifacts/commitment.zkey";
const PP_ASP_API_BASE = 'https://api.0xbow.io/1/public';
const PP_MT_LEAVES_API = PP_ASP_API_BASE + '/mt-leaves';
const PP_DEPOSITS_BY_LABEL_API = PP_ASP_API_BASE + '/deposits-by-label';
const PP_DEPOSITS_LARGER_THAN_API = PP_ASP_API_BASE + '/deposits-larger-than';
// MT-leaves are append-only; stale data triggers a root-window mismatch (caught by ppReadKnownStateRoots), not an invalid proof.
const PP_MT_LEAVES_CACHE_TTL_MS = 120_000;
const PP_RELAYER_DETAILS_CACHE_TTL_MS = 60_000;
// Review statuses change on the order of hours; this cache is display-only, never used in proof generation.
const PP_DEPOSITS_BY_LABEL_CACHE_TTL_MS = 60_000;
const PP_ASP_FETCH_TIMEOUT_MS = 12_000;
const PP_WITHDRAW_FETCH_TIMEOUT_MS = 20_000;
const PP_REVIEW_STATUS = Object.freeze({
  PENDING: 'pending',
  APPROVED: 'approved',
  DECLINED: 'declined',
  EXITED: 'exited',
  SPENT: 'spent',
  POI_REQUIRED: 'poi_required',
});

let _ppwNote = null;
let _ppwMode = 'relay'; // 'relay' (default) or 'direct' (ragequit-only, internal)
let _ppwActionKind = 'withdraw'; // 'withdraw' or 'ragequit'
let _ppwDraftPhase = 'editing'; // 'editing' | 'review' | 'running'
let _ppwReviewedRelayQuote = null;
let _ppwRelayExpiryTimer = null;
let _ppwDisplayedRelayQuoteKey = null;
let _ppArtifactCache = null; // cached {wasmUrl, zkeyUrl} blob URLs
let _ppArtifactCachePromise = null;
let _ppCommitmentArtifactCache = null; // cached {wasmUrl, zkeyUrl} blob URLs
let _ppCommitmentArtifactCachePromise = null;
let _ppSnarkjsSourceCache = null;
let _ppSnarkjsSourcePromise = null;
let _ppSnarkjsEngineCache = null;
let _ppSnarkjsEnginePromise = null;
let _ppProofProgressWorkerBlobUrl = null;
let _ppProofProgressWorkerBlobUrlPromise = null;
let _ppProofProgressWorker = null;
let _ppwAnonTimer = null;
let _ppwAnonReqId = 0;
let _ppwRelayerMinReqId = 0;
const _ppwRelayerMinByAsset = Object.create(null); // asset -> bigint | null | Promise<bigint|null>
const _ppMtLeavesCache = Object.create(null); // scope -> { data, fetchedAt, pending }
const _ppRelayerDetailsCache = Object.create(null); // chainId:asset -> { data, fetchedAt, pending }
let _ppWithdrawPreloadScheduled = false;
const PP_ASP_ROOT_FETCH_MAX_ATTEMPTS = 3;
const PP_ASP_ROOT_RETRY_DELAY_MS = 1200;
const PPW_PROGRESS_STAGES = Object.freeze({
  validating: { label: 'Validating withdrawal...', progress: 0.08 },
  checkingPoolState: { label: 'Checking pool state...', progress: 0.2 },
  fetchingRelayQuote: { label: 'Fetching relay quote...', progress: 0.32 },
  loadingArtifacts: { label: 'Loading proving artifacts...', progress: 0.44 },
  generatingProof: { label: 'Generating proof...', progress: 0.68 },
  verifyingProof: { label: 'Verifying proof locally...', progress: 0.82 },
  submittingRelay: { label: 'Submitting to relayer...', progress: 0.9 },
  submittingDirect: { label: 'Submitting transaction...', progress: 0.9 },
  waitingConfirmation: { label: 'Waiting for confirmation...', progress: 0.96 },
  complete: { label: 'Withdrawal confirmed.', progress: 1 },
});
let _ppwProgressValue = 0;

function ppwClearAnonymityHint() {
  if (_ppwAnonTimer) { clearTimeout(_ppwAnonTimer); _ppwAnonTimer = null; }
  _ppwAnonReqId++;
  setShown('ppwAnonHint', false);
  setShown('ppwSuggestWrap', false);
  setText('ppwAnonHint', '');
  setText('ppwSuggestBtns', '');
}

function ppScheduleIdle(fn, timeout = 2000) {
  const ric = window.requestIdleCallback;
  if (typeof ric === 'function') {
    return ric(fn, { timeout });
  }
  return setTimeout(fn, Math.min(timeout, 500));
}

function ppCreateTimedAbortContext(timeoutMs = PP_ASP_FETCH_TIMEOUT_MS, abortSignal = null) {
  const controller = new AbortController();
  let didTimeout = false;
  const timeoutId = setTimeout(() => {
    didTimeout = true;
    controller.abort();
  }, timeoutMs);
  const forwardAbort = () => controller.abort();
  if (abortSignal) {
    if (abortSignal.aborted) {
      controller.abort();
    } else {
      abortSignal.addEventListener('abort', forwardAbort, { once: true });
    }
  }
  return {
    signal: controller.signal,
    didTimeout: () => didTimeout,
    cleanup() {
      clearTimeout(timeoutId);
      if (abortSignal) abortSignal.removeEventListener('abort', forwardAbort);
    },
  };
}

async function ppFetchJson(url, { headers = {}, abortSignal = null, timeoutMs = PP_ASP_FETCH_TIMEOUT_MS } = {}) {
  const abortCtx = ppCreateTimedAbortContext(timeoutMs, abortSignal);
  try {
    const resp = await fetch(url, { headers, signal: abortCtx.signal });
    if (!resp.ok) throw new Error('HTTP ' + resp.status);
    return await resp.json();
  } catch (err) {
    if (abortCtx.didTimeout()) {
      throw new Error('Privacy Pools API request timed out');
    }
    throw err;
  } finally {
    abortCtx.cleanup();
  }
}

async function ppFetchMtLeaves(scope, forceRefresh = false) {
  const cacheKey = String(scope);
  const now = Date.now();
  const cached = _ppMtLeavesCache[cacheKey];

  if (!forceRefresh && cached?.data && (now - cached.fetchedAt) < PP_MT_LEAVES_CACHE_TTL_MS) {
    return cached.data;
  }
  if (!forceRefresh && cached?.pending) {
    return cached.pending;
  }

  const pending = (async () => {
    const apiData = await ppFetchJson(PP_MT_LEAVES_API, {
      headers: { 'X-Pool-Scope': cacheKey }
    });
    if (!apiData.aspLeaves || !Array.isArray(apiData.aspLeaves) || apiData.aspLeaves.length === 0) {
      throw new Error('No ASP leaves returned');
    }
    if (!apiData.stateTreeLeaves || !Array.isArray(apiData.stateTreeLeaves) || apiData.stateTreeLeaves.length === 0) {
      throw new Error('No state tree leaves returned');
    }
    const parsed = {
      aspLeaves: apiData.aspLeaves.map(l => BigInt(l)),
      stateTreeLeaves: apiData.stateTreeLeaves.map(l => BigInt(l)),
    };
    _ppMtLeavesCache[cacheKey] = { data: parsed, fetchedAt: Date.now(), pending: null };
    return parsed;
  })();

  _ppMtLeavesCache[cacheKey] = {
    data: cached?.data || null,
    fetchedAt: cached?.fetchedAt || 0,
    pending,
  };

  try {
    return await pending;
  } catch (err) {
    if (cached?.data) {
      _ppMtLeavesCache[cacheKey] = { data: cached.data, fetchedAt: cached.fetchedAt, pending: null };
    } else {
      delete _ppMtLeavesCache[cacheKey];
    }
    throw err;
  }
}

function ppDelay(ms, abortSignal = null) {
  return new Promise((resolve, reject) => {
    if (abortSignal?.aborted) {
      reject(new DOMException('Aborted', 'AbortError'));
      return;
    }
    const timerId = setTimeout(() => {
      if (abortSignal) abortSignal.removeEventListener('abort', onAbort);
      resolve();
    }, Math.max(0, Number(ms) || 0));
    const onAbort = () => {
      clearTimeout(timerId);
      abortSignal?.removeEventListener('abort', onAbort);
      reject(new DOMException('Aborted', 'AbortError'));
    };
    if (abortSignal) abortSignal.addEventListener('abort', onAbort, { once: true });
  });
}

async function ppVerifyAspDataWithRetries(scope, label, {
  initialAspLeaves = null,
  abortSignal = null,
  log = null,
} = {}) {
  let aspLeaves = Array.isArray(initialAspLeaves) ? initialAspLeaves : null;
  let lastResult = null;

  for (let attempt = 1; attempt <= PP_ASP_ROOT_FETCH_MAX_ATTEMPTS; attempt++) {
    if (abortSignal?.aborted) throw new DOMException('Aborted', 'AbortError');

    if (attempt > 1) {
      if (typeof log === 'function') {
        log('Refreshing ASP tree data (attempt ' + attempt + '/' + PP_ASP_ROOT_FETCH_MAX_ATTEMPTS + ')...');
      }
      await ppDelay(PP_ASP_ROOT_RETRY_DELAY_MS * (attempt - 1), abortSignal);
      const mtData = await ppFetchMtLeaves(scope, true);
      aspLeaves = mtData?.aspLeaves || [];
    } else if (!aspLeaves) {
      const mtData = await ppFetchMtLeaves(scope);
      aspLeaves = mtData?.aspLeaves || [];
    }

    const aspIndex = aspLeaves.indexOf(label);
    const aspTree = leanIMTBuild(aspLeaves);
    const onChainASPRoot = await ppReadEntrypoint((ep) => ep.latestRoot());
    lastResult = { aspLeaves, aspIndex, aspTree, onChainASPRoot, attempts: attempt };

    if (aspIndex !== -1 && aspTree.root === onChainASPRoot) {
      return { ...lastResult, status: 'verified' };
    }

    if (attempt < PP_ASP_ROOT_FETCH_MAX_ATTEMPTS && typeof log === 'function') {
      if (aspIndex === -1) {
        log('Label not found in ASP tree yet. Retrying with fresh ASP data...');
      } else {
        log('ASP root is behind latestRoot. Retrying with fresh ASP data...');
      }
    }
  }

  const finalStatus = lastResult?.aspIndex === -1 ? 'missing-label' : 'root-mismatch';
  return { ...(lastResult || { aspLeaves: [], aspIndex: -1, aspTree: leanIMTBuild([]), onChainASPRoot: null, attempts: 0 }), status: finalStatus };
}

const _ppDepositsByLabelCache = Object.create(null); // { [key]: { data, fetchedAt, pending } }

function ppValidateDepositsByLabelRow(row, index) {
  const prefix = `Invalid deposits-by-label response at row ${index}`;
  if (!row || typeof row !== 'object' || Array.isArray(row)) {
    throw new Error(prefix + ': expected object');
  }
  if (typeof row.label !== 'string') {
    throw new Error(prefix + ': label must be a string');
  }
  try {
    BigInt(row.label);
  } catch (_) {
    throw new Error(prefix + ': label must be BigInt-coercible');
  }
  if (typeof row.reviewStatus !== 'string') {
    throw new Error(prefix + ': reviewStatus must be a string');
  }
  if (typeof row.timestamp !== 'number' || !Number.isFinite(row.timestamp)) {
    throw new Error(prefix + ': timestamp must be a finite number');
  }
  return row;
}

function ppValidateDepositsByLabelResponse(apiData) {
  if (!Array.isArray(apiData)) throw new Error('Invalid deposits-by-label response: expected array');
  return apiData.map((row, index) => ppValidateDepositsByLabelRow(row, index));
}

async function ppFetchDepositsByLabel(scope, labels, abortSignal = null) {
  const uniqueLabels = Array.from(new Set((Array.isArray(labels) ? labels : [])
    .filter(label => label != null)
    .map(label => String(label))));
  if (!uniqueLabels.length) return [];

  const cacheKey = String(scope) + ':' + uniqueLabels.slice().sort().join(',');
  const cached = _ppDepositsByLabelCache[cacheKey];
  const now = Date.now();
  if (cached?.data && (now - cached.fetchedAt) < PP_DEPOSITS_BY_LABEL_CACHE_TTL_MS) return cached.data;
  if (cached?.pending) return cached.pending;

  const pending = (async () => {
    const apiData = await ppFetchJson(PP_DEPOSITS_BY_LABEL_API, {
      abortSignal,
      headers: {
        'X-Pool-Scope': String(scope),
        'X-Labels': uniqueLabels.join(','),
      }
    });
    const validatedData = ppValidateDepositsByLabelResponse(apiData);
    _ppDepositsByLabelCache[cacheKey] = { data: validatedData, fetchedAt: Date.now(), pending: null };
    return validatedData;
  })();
  _ppDepositsByLabelCache[cacheKey] = { ...(cached || {}), pending };
  try { return await pending; } catch (err) {
    if (_ppDepositsByLabelCache[cacheKey]?.pending === pending) {
      _ppDepositsByLabelCache[cacheKey] = { ..._ppDepositsByLabelCache[cacheKey], pending: null };
    }
    throw err;
  }
}

const _ppValidReviewStatuses = new Set(Object.values(PP_REVIEW_STATUS));
function ppNormalizeReviewStatus(status) {
  const s = String(status || '').toLowerCase();
  return _ppValidReviewStatuses.has(s) ? s : PP_REVIEW_STATUS.PENDING;
}

function ppLoadedAccountLabelKey(label) {
  return label == null ? null : BigInt(label);
}

function ppNormalizeAddressLower(address) {
  try {
    return ethers.getAddress(address).toLowerCase();
  } catch {
    return String(address || '').trim().toLowerCase();
  }
}

function ppApplyLoadedAccountReviewStatuses(rows, aspLeaves, depositsByLabel, { statusFetchFailed = false, aspRootVerified = true } = {}) {
  const aspLeafSet = new Set((Array.isArray(aspLeaves) ? aspLeaves : []).map(leaf => BigInt(leaf)));
  const depositMap = new Map();
  for (const deposit of Array.isArray(depositsByLabel) ? depositsByLabel : []) {
    if (deposit?.label == null) continue;
    depositMap.set(BigInt(deposit.label), deposit);
  }

  const missingLabels = new Set();
  const nextRows = (Array.isArray(rows) ? rows : []).map((row) => {
    const labelKey = ppLoadedAccountLabelKey(row.label);
    const deposit = labelKey != null ? depositMap.get(labelKey) : null;
    const timestamp = deposit?.timestamp ?? null;
    const amount = row.value != null ? BigInt(row.value) : 0n;
    const depositor = row?.depositor ? ppNormalizeAddressLower(row.depositor) : '';
    const connectedAddressRaw = (typeof _connectedAddress !== 'undefined' && _connectedAddress) ? _connectedAddress : '';
    const connectedAddress = connectedAddressRaw ? ppNormalizeAddressLower(connectedAddressRaw) : '';
    const isOriginalDepositor = !!(depositor && connectedAddress && depositor === connectedAddress);

    if (row.ragequit) {
      return {
        ...row,
        pending: false,
        reviewStatus: PP_REVIEW_STATUS.EXITED,
        isValid: false,
        isWithdrawable: false,
        isOriginalDepositor,
        isRagequittable: false,
        timestamp,
      };
    }

    if (row.source === 'spent') {
      return {
        ...row,
        pending: false,
        reviewStatus: PP_REVIEW_STATUS.SPENT,
        isValid: false,
        isWithdrawable: false,
        isOriginalDepositor,
        isRagequittable: false,
        timestamp,
      };
    }

    let reviewStatus = PP_REVIEW_STATUS.PENDING;
    if (row.currentCommitmentInserted === true && !statusFetchFailed && aspRootVerified) {
      if (!deposit) {
        if (labelKey != null) missingLabels.add(labelKey);
      } else {
        reviewStatus = ppNormalizeReviewStatus(deposit.reviewStatus);
        if (reviewStatus === PP_REVIEW_STATUS.APPROVED && (labelKey == null || !aspLeafSet.has(labelKey))) {
          reviewStatus = PP_REVIEW_STATUS.PENDING;
        }
      }
    }

    const isValid = reviewStatus === PP_REVIEW_STATUS.APPROVED;
    return {
      ...row,
      pending: reviewStatus === PP_REVIEW_STATUS.PENDING,
      reviewStatus,
      isValid,
      isWithdrawable: isValid && amount > 0n,
      isOriginalDepositor,
      isRagequittable: amount > 0n && isOriginalDepositor,
      timestamp,
    };
  });

  return { rows: nextRows, missingLabels: Array.from(missingLabels) };
}

const _ppStatusLabels = { approved: 'Approved', declined: 'Declined', exited: 'Ragequit', spent: 'Spent', poi_required: 'POA Needed' };
function ppGetLoadedAccountStatusLabel(status) {
  return _ppStatusLabels[status] || 'Pending';
}

const _ppStatusColors = { approved: 'var(--green, #22c55e)', declined: 'var(--error)', exited: 'var(--warn)', poi_required: 'var(--error)' };
function ppGetLoadedAccountStatusColor(status) {
  return _ppStatusColors[status] || 'var(--fg-muted)';
}

function ppwIsCurrentWalletOriginalDepositor(note, connectedAddress = _connectedAddress) {
  const depositor = note?.depositor ? ppNormalizeAddressLower(note.depositor) : '';
  const connected = connectedAddress ? ppNormalizeAddressLower(connectedAddress) : '';
  if (depositor && connected) return depositor === connected;
  return note?.isOriginalDepositor === true;
}

function ppwCanRagequitNote(note, connectedAddress = _connectedAddress) {
  if (!note) return false;
  const status = ppNormalizeReviewStatus(note.reviewStatus);
  if (note?.ragequit || status === PP_REVIEW_STATUS.EXITED) return false;
  if (note?.source === 'spent' || status === PP_REVIEW_STATUS.SPENT) return false;
  const value = note?.value != null ? BigInt(note.value) : 0n;
  if (value <= 0n) return false;
  return ppwIsCurrentWalletOriginalDepositor(note, connectedAddress);
}

function ppGetLoadedAccountStatusHintHtml(row) {
  const status = ppNormalizeReviewStatus(row?.reviewStatus);
  const canRagequit = ppwCanRagequitNote(row);
  if (status === PP_REVIEW_STATUS.POI_REQUIRED) {
    return 'Proof of Association required. Continue at <a href="https://tornado.0xbow.io" target="_blank" rel="noopener" style="color:inherit;text-decoration:underline">tornado.0xbow.io</a>.';
  }
  if (status === PP_REVIEW_STATUS.PENDING) {
    if (canRagequit) {
      return row?.currentCommitmentInserted === true
        ? 'Waiting for ASP review / inclusion. You can still Ragequit this Pool Account from the original depositor wallet.'
        : 'Waiting for pool inclusion. You can still Ragequit this Pool Account from the original depositor wallet.';
    }
    return row?.currentCommitmentInserted === true
      ? 'Waiting for ASP review / inclusion.'
      : 'Waiting for pool inclusion.';
  }
  if (status === PP_REVIEW_STATUS.DECLINED) {
    return canRagequit
      ? 'This Pool Account is not withdrawable, but you can Ragequit it from the original depositor wallet.'
      : 'This Pool Account is not withdrawable.';
  }
  if (row?.value != null && BigInt(row.value) > 0n && !canRagequit && row?.depositor) {
    return 'Ragequit is only available from the original depositor wallet.';
  }
  return '';
}

// ── Activity Derivation ──────────────────────────────────────────────
// Derives a personal activity history from the same events already used
// by ppBuildLoadedPoolAccountsFromEvents. Each deposit lineage produces
// a Deposit record; each matched withdrawal produces a Withdrawal record;
// each ragequit produces a Ragequit record.

function ppBuildActivityFromAccountRows(allAssetResults) {
  if (!Array.isArray(allAssetResults) || allAssetResults.length === 0) {
    return [];
  }
  try {
    const activity = [];

    for (const assetResult of allAssetResults) {
      if (!assetResult || typeof assetResult !== 'object') continue;
      const asset = assetResult.asset;
      const rows = Array.isArray(assetResult.rows) ? assetResult.rows : [];
      const withdrawnMap = assetResult.withdrawnMap;
      // Build a set of withdrawal txHashes we've seen from rows, to
      // reconstruct Withdrawal activity records from the chain tracing.
      // We walk the rows and their traced chain data.
      const depositTxSet = new Set();

      for (const row of rows) {
        // --- Deposit record ---
        if (row.depositTxHash && !depositTxSet.has(row.depositTxHash)) {
          depositTxSet.add(row.depositTxHash);
          activity.push({
            action: 'Deposit',
            asset,
            amount: row.originalValue || row.value || '0',
            label: row.label,
            txHash: row.depositTxHash,
            blockNumber: row.depositBlockNumber,
            timestamp: row.timestamp ?? null,
            reviewStatus: row.ragequit
              ? PP_REVIEW_STATUS.EXITED
              : (row.source === 'spent' ? PP_REVIEW_STATUS.SPENT : ppNormalizeReviewStatus(row.reviewStatus)),
          });
        }

        // --- Ragequit record ---
        if (row.ragequit) {
          activity.push({
            action: 'Ragequit',
            asset,
            amount: row.originalValue || '0',
            label: row.label,
            txHash: row.txHash,
            blockNumber: row.blockNumber,
            timestamp: null, // resolved from block timestamp
            reviewStatus: PP_REVIEW_STATUS.APPROVED,
          });
          continue;
        }

        // --- Withdrawal records ---
        // Emit one Withdrawal activity per chain step using withdrawalSteps
        // (accumulated during chain tracing). Falls back to the row's txHash
        // for single-step chains without the array.
        if (row.withdrawalSteps && row.withdrawalSteps.length > 0) {
          for (const step of row.withdrawalSteps) {
            if (step.txHash && step.txHash !== row.depositTxHash) {
              activity.push({
                action: 'Withdrawal',
                asset,
                amount: step.value || '0',
                label: row.label,
                txHash: step.txHash,
                blockNumber: step.blockNumber,
                timestamp: null,
                reviewStatus: PP_REVIEW_STATUS.APPROVED,
              });
            }
          }
        } else if ((row.source === 'spent' || row.source === 'change') && !row.ragequit && row.txHash && row.txHash !== row.depositTxHash) {
          const withdrawnEntry = row.source === 'change' ? ppActivityFindWithdrawnAmount(row, withdrawnMap) : null;
          activity.push({
            action: 'Withdrawal',
            asset,
            amount: withdrawnEntry ?? row.originalValue ?? '0',
            label: row.label,
            txHash: row.txHash,
            blockNumber: row.blockNumber,
            timestamp: null,
            reviewStatus: PP_REVIEW_STATUS.APPROVED,
          });
        }
      }
    }

    return activity;
  } catch (e) {
    console.warn('Activity: derivation failed:', e);
    return [];
  }
}

function ppActivityFindWithdrawnAmount(row, withdrawnMap) {
  // The withdrawnMap is keyed by nullifier hash. We need to find the
  // Withdrawn event that produced this change note. Unfortunately we
  // don't have the *parent* nullifier readily available on a change row,
  // but the txHash matches, so we scan the map for a matching txHash.
  if (!withdrawnMap || !row.txHash) return null;
  for (const [, entry] of withdrawnMap) {
    if (entry.txHash === row.txHash) {
      return entry.value != null ? String(entry.value) : null;
    }
  }
  return null;
}

function ppActivityGetStatus(row) {
  if (row.action === 'Withdrawal' || row.action === 'Ragequit') return 'completed';
  return ppNormalizeReviewStatus(row.reviewStatus);
}

const _ppActivityStatusLabels = {
  completed: 'Confirmed',
  approved: 'Approved',
  pending: 'Pending',
  declined: 'Declined',
  exited: 'Ragequit',
  spent: 'Spent',
  poi_required: 'POA Needed',
};
function ppActivityGetStatusLabel(status) {
  return _ppActivityStatusLabels[status] || 'Pending';
}

const _ppActivityStatusColors = {
  completed: 'var(--green, #22c55e)',
  approved: 'var(--green, #22c55e)',
  declined: 'var(--error)',
  exited: 'var(--warn)',
  poi_required: 'var(--error)',
};
function ppActivityGetStatusColor(status) {
  return _ppActivityStatusColors[status] || 'var(--fg-muted)';
}

// ── Block Timestamp Cache ────────────────────────────────────────────
const _ppBlockTimestampCache = {};

async function ppResolveBlockTimestamp(blockNumber) {
  if (blockNumber == null) return null;
  const key = Number(blockNumber);
  if (_ppBlockTimestampCache[key] != null) return _ppBlockTimestampCache[key];
  try {
    const block = await ppReadWithRpc((rpc) => rpc.getBlock(key));
    if (block && block.timestamp) {
      _ppBlockTimestampCache[key] = Number(block.timestamp);
      return _ppBlockTimestampCache[key];
    }
  } catch (e) {
    console.warn('Activity: failed to resolve block timestamp for block', key, e);
  }
  return null;
}

async function ppResolveActivityTimestamps(activity) {
  if (!Array.isArray(activity) || !activity.length) return;
  const blocksToResolve = new Set();
  for (const row of activity) {
    if (row.timestamp == null && row.blockNumber != null) {
      const key = Number(row.blockNumber);
      if (_ppBlockTimestampCache[key] == null) blocksToResolve.add(key);
    }
  }
  // Resolve unique blocks in parallel (bounded batch)
  const blocks = Array.from(blocksToResolve);
  const BATCH = 6;
  for (let i = 0; i < blocks.length; i += BATCH) {
    await Promise.all(blocks.slice(i, i + BATCH).map(b => ppResolveBlockTimestamp(b)));
  }
  // Apply resolved timestamps to rows
  for (const row of activity) {
    if (row.timestamp == null && row.blockNumber != null) {
      const ts = _ppBlockTimestampCache[Number(row.blockNumber)];
      if (ts != null) row.timestamp = ts;
    }
  }
}

// ── Time Ago Helper ──────────────────────────────────────────────────
function ppGetTimeAgo(timestampSeconds) {
  if (timestampSeconds == null || !Number.isFinite(Number(timestampSeconds)) || Number(timestampSeconds) <= 0) return '\u2013';
  const now = Math.floor(Date.now() / 1000);
  const ts = Number(timestampSeconds);
  // Guard against timestamps in milliseconds (> year 3000 in seconds)
  const diff = now - (ts > 32503680000 ? Math.floor(ts / 1000) : ts);
  if (diff < 0) return '\u2013';
  if (diff < 60) return 'just now';
  if (diff < 3600) {
    const mins = Math.floor(diff / 60);
    return mins === 1 ? '1 minute ago' : mins + ' minutes ago';
  }
  if (diff < 86400) {
    const hours = Math.floor(diff / 3600);
    return hours === 1 ? '1 hour ago' : hours + ' hours ago';
  }
  if (diff < 5184000) { // up to 60 days
    const days = Math.floor(diff / 86400);
    return days === 1 ? '1 day ago' : days + ' days ago';
  }
  if (diff < 31536000) {
    const months = Math.floor(diff / 2592000);
    return months < 2 ? '1 month ago' : months + ' months ago';
  }
  const years = Math.floor(diff / 31536000);
  return years === 1 ? '1 year ago' : years + ' years ago';
}

// ── Activity Sort ────────────────────────────────────────────────────
const _ppActivityActionOrder = { Ragequit: 0, Withdrawal: 1, Deposit: 2 };
function ppCompareActivity(a, b) {
  // Sort newest-first by blockNumber (null to bottom), then txHash, then action type
  const aBlock = a.blockNumber == null ? -1 : Number(a.blockNumber);
  const bBlock = b.blockNumber == null ? -1 : Number(b.blockNumber);
  if (aBlock !== bBlock) return bBlock - aBlock; // descending
  const txCmp = String(b.txHash || '').localeCompare(String(a.txHash || ''));
  if (txCmp !== 0) return txCmp;
  return (_ppActivityActionOrder[a.action] ?? 99) - (_ppActivityActionOrder[b.action] ?? 99);
}

function ppGetLoadedAccountBlockedReason(row, actionKind = 'withdraw') {
  if (actionKind === 'ragequit') {
    if (row?.ragequit || ppNormalizeReviewStatus(row?.reviewStatus) === PP_REVIEW_STATUS.EXITED) {
      return 'This Pool Account has already been ragequit.';
    }
    if (row?.source === 'spent' || ppNormalizeReviewStatus(row?.reviewStatus) === PP_REVIEW_STATUS.SPENT) {
      return 'This Pool Account has already been spent.';
    }
    if (row?.value != null && BigInt(row.value) <= 0n) {
      return 'This Pool Account has no balance left to ragequit.';
    }
    if (!ppwIsCurrentWalletOriginalDepositor(row)) {
      return 'Only the original depositor wallet can ragequit this Pool Account.';
    }
    return 'This Pool Account is not available for ragequit.';
  }
  const status = ppNormalizeReviewStatus(row?.reviewStatus);
  if (status === PP_REVIEW_STATUS.POI_REQUIRED) {
    return 'This Pool Account requires Proof of Association before withdrawal. Visit tornado.0xbow.io to continue.';
  }
  if (status === PP_REVIEW_STATUS.DECLINED) {
    return 'This Pool Account was declined and cannot be withdrawn.';
  }
  if (status === PP_REVIEW_STATUS.PENDING) {
    return row?.currentCommitmentInserted === true
      ? 'This Pool Account is still pending ASP review / inclusion.'
      : 'This Pool Account is still pending pool inclusion.';
  }
  if (status === PP_REVIEW_STATUS.EXITED) {
    return 'This Pool Account has already been ragequit.';
  }
  if (status === PP_REVIEW_STATUS.SPENT) {
    return 'This Pool Account has already been spent.';
  }
  return 'This Pool Account is not available for withdrawal.';
}

function ppSriIntegrityParts(integrity) {
  const normalized = String(integrity || '').trim();
  const dashIndex = normalized.indexOf('-');
  if (dashIndex <= 0 || dashIndex === normalized.length - 1) {
    throw new Error('Unsupported integrity value: ' + normalized);
  }
  const algoRaw = normalized.slice(0, dashIndex).toLowerCase();
  const algorithms = {
    sha256: 'SHA-256',
    sha384: 'SHA-384',
    sha512: 'SHA-512'
  };
  const algorithm = algorithms[algoRaw];
  if (!algorithm) {
    throw new Error('Unsupported integrity algorithm: ' + algoRaw);
  }
  return {
    algorithm,
    digestBase64: normalized.slice(dashIndex + 1)
  };
}

function ppBytesToBase64(bytes) {
  let binary = '';
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary);
}

async function ppVerifyBufferIntegrity(buf, integrity, label) {
  const { algorithm, digestBase64 } = ppSriIntegrityParts(integrity);
  const hashBuf = await crypto.subtle.digest(algorithm, buf);
  const actualDigest = ppBytesToBase64(new Uint8Array(hashBuf));
  if (actualDigest !== digestBase64) {
    throw new Error(label + ' integrity check failed');
  }
}

async function ppFetchTextWithIntegrity(url, integrity, label) {
  const abortCtx = ppCreateTimedAbortContext(PP_WITHDRAW_FETCH_TIMEOUT_MS);
  try {
    const resp = await fetch(url, { credentials: 'omit', signal: abortCtx.signal });
    if (!resp.ok) throw new Error(label + ': HTTP ' + resp.status);
    const buf = await resp.arrayBuffer();
    await ppVerifyBufferIntegrity(buf, integrity, label);
    return new TextDecoder().decode(buf);
  } catch (err) {
    if (abortCtx.didTimeout()) {
      throw new Error(label + ' fetch timed out');
    }
    throw err;
  } finally {
    abortCtx.cleanup();
  }
}

function ppCreateProofBootstrapError(message, cause = null) {
  const err = new Error(message);
  err.ppBootstrapFailure = true;
  if (cause) err.cause = cause;
  return err;
}

async function ppEnsureVerifiedSnarkjsSource() {
  if (_ppSnarkjsSourceCache) return _ppSnarkjsSourceCache;
  if (_ppSnarkjsSourcePromise) return _ppSnarkjsSourcePromise;
  _ppSnarkjsSourcePromise = (async () => {
    const source = await ppFetchTextWithIntegrity(PP_SNARKJS_SRC, PP_SNARKJS_INTEGRITY, 'snarkjs');
    _ppSnarkjsSourceCache = source;
    return source;
  })().catch(err => {
    _ppSnarkjsSourcePromise = null;
    throw ppCreateProofBootstrapError('Failed to fetch verified snarkjs source for withdrawal proving.', err);
  });
  return _ppSnarkjsSourcePromise;
}

async function ppEnsureVerifiedSnarkjsEngine() {
  if (_ppSnarkjsEngineCache) return _ppSnarkjsEngineCache;
  if (_ppSnarkjsEnginePromise) return _ppSnarkjsEnginePromise;
  _ppSnarkjsEnginePromise = (async () => {
    const snarkjsSource = await ppEnsureVerifiedSnarkjsSource();
    let engine = null;
    try {
      // Match upstream Privacy Pools: load verified snarkjs on the main thread so
      // its internal worker manager can use browser concurrency for Groth16 proving.
      engine = Function(`${snarkjsSource}
return (typeof snarkjs !== 'undefined' && snarkjs)
  || (typeof globalThis !== 'undefined' && globalThis.snarkjs)
  || null;`)();
    } catch (err) {
      throw ppCreateProofBootstrapError('Failed to initialize verified snarkjs on the main thread.', err);
    }
    if (!engine || !engine.groth16 || typeof engine.groth16.fullProve !== 'function') {
      throw ppCreateProofBootstrapError('Verified snarkjs proving engine is unavailable on the main thread.');
    }
    _ppSnarkjsEngineCache = engine;
    return _ppSnarkjsEngineCache;
  })().catch(err => {
    _ppSnarkjsEnginePromise = null;
    throw err;
  });
  return _ppSnarkjsEnginePromise;
}

async function ppEnsureWithdrawalProgressWorkerBlobUrl() {
  if (_ppProofProgressWorkerBlobUrl) return _ppProofProgressWorkerBlobUrl;
  if (_ppProofProgressWorkerBlobUrlPromise) return _ppProofProgressWorkerBlobUrlPromise;
  _ppProofProgressWorkerBlobUrlPromise = Promise.resolve().then(() => {
    // This worker is UX-only: it reports coarse progress and must never touch proof material.
    const workerSource = `
;(() => {
  let timerId = null;
  let requestId = null;
  const progressSteps = [
    { delayMs: 60, phase: 'loading_circuits', progress: 0.2 },
    { delayMs: 220, phase: 'generating_proof', progress: 0.25 },
    { delayMs: 700, phase: 'generating_proof', progress: 0.4 },
    { delayMs: 1400, phase: 'generating_proof', progress: 0.58 },
    { delayMs: 2400, phase: 'generating_proof', progress: 0.72 }
  ];
  const clearTimer = () => {
    if (timerId) {
      clearTimeout(timerId);
      timerId = null;
    }
  };
  const post = (type, payload = {}) => {
    if (!requestId) return;
    self.postMessage({ id: requestId, type, ...payload });
  };
  const stop = () => {
    clearTimer();
    requestId = null;
  };
  const scheduleStep = (index) => {
    if (!requestId) return;
    if (index >= progressSteps.length) return;
    const step = progressSteps[index];
    timerId = setTimeout(() => {
      if (!requestId) return;
      post('progress', step);
      scheduleStep(index + 1);
    }, step.delayMs);
  };
  self.onmessage = (event) => {
    const data = event.data || {};
    if (data.type === 'start') {
      stop();
      requestId = data.id;
      scheduleStep(0);
      return;
    }
    if (data.type === 'stop' && data.id === requestId) {
      stop();
    }
  };
})();`;
    _ppProofProgressWorkerBlobUrl = URL.createObjectURL(new Blob([workerSource], { type: 'text/javascript' }));
    return _ppProofProgressWorkerBlobUrl;
  }).catch(err => {
    _ppProofProgressWorkerBlobUrlPromise = null;
    throw ppCreateProofBootstrapError('Failed to build the withdrawal proof progress worker.', err);
  });
  return _ppProofProgressWorkerBlobUrlPromise;
}

function ppMapProofProgress(phase, progress) {
  switch (phase) {
    case 'loading_circuits':
      return 0.56;
    case 'generating_proof': {
      const raw = Math.max(0, Math.min(1, Number(progress) || 0));
      return 0.58 + (raw * 0.16);
    }
    case 'verifying_proof':
      return 0.78;
    default:
      return PPW_PROGRESS_STAGES.generatingProof.progress;
  }
}

function ppTerminateProofProgressWorker() {
  if (_ppProofProgressWorker) { try { _ppProofProgressWorker.terminate(); } catch {} }
  _ppProofProgressWorker = null;
}

async function ppStartWithdrawalProofProgressReporter(onProgress) {
  if (typeof onProgress !== 'function') {
    return { stop() {} };
  }
  const fallbackMessage = 'Live proof progress updates are unavailable. Proving continues on the main thread.';
  const notifyFallback = () => {
    try {
      onProgress({ fallbackMessage });
    } catch {}
  };
  if (typeof Worker !== 'function') {
    notifyFallback();
    return {
      stop(finalPhase = null, finalProgress = null) {
        if (finalPhase) {
          try { onProgress({ phase: finalPhase, progress: finalProgress }); } catch {}
        }
      }
    };
  }

  let worker = null;
  let requestId = null;
  let active = true;
  try {
    const workerUrl = await ppEnsureWithdrawalProgressWorkerBlobUrl();
    worker = new Worker(workerUrl);
    _ppProofProgressWorker = worker;
    requestId = 'pp-proof-progress-' + Date.now().toString(36) + '-' + Math.random().toString(36).slice(2);
    worker.onmessage = (event) => {
      if (!active) return;
      const data = event.data || {};
      if (data.id !== requestId || data.type !== 'progress') return;
      try { onProgress(data); } catch {}
    };
    worker.onerror = () => {
      if (!active) return;
      active = false;
      ppTerminateProofProgressWorker();
      notifyFallback();
    };
    worker.postMessage({ id: requestId, type: 'start' });
  } catch (err) {
    console.warn('Privacy: withdrawal proof progress worker unavailable', err);
    ppTerminateProofProgressWorker();
    notifyFallback();
    return {
      stop(finalPhase = null, finalProgress = null) {
        if (finalPhase) {
          try { onProgress({ phase: finalPhase, progress: finalProgress }); } catch {}
        }
      }
    };
  }

  return {
    stop(finalPhase = null, finalProgress = null) {
      if (!active) {
        if (finalPhase) {
          try { onProgress({ phase: finalPhase, progress: finalProgress }); } catch {}
        }
        return;
      }
      active = false;
      try { worker?.postMessage({ id: requestId, type: 'stop' }); } catch {}
      if (finalPhase) {
        try { onProgress({ phase: finalPhase, progress: finalProgress }); } catch {}
      }
      ppTerminateProofProgressWorker();
    }
  };
}

async function ppRunWithdrawalProof(circuitInputs, wasmUrl, zkeyUrl, onProgress) {
  const engine = await ppEnsureVerifiedSnarkjsEngine();
  const progressReporter = await ppStartWithdrawalProofProgressReporter(onProgress);
  try {
    const result = await engine.groth16.fullProve(circuitInputs, wasmUrl, zkeyUrl);
    if (!result || !result.proof || !Array.isArray(result.publicSignals)) {
      throw new Error('snarkjs returned malformed proof output.');
    }
    progressReporter.stop('verifying_proof', 0.8);
    return { proof: result.proof, publicSignals: result.publicSignals };
  } catch (err) {
    progressReporter.stop();
    throw err;
  }
}

async function ppEnsureWithdrawArtifacts() {
  if (_ppArtifactCache) return _ppArtifactCache;
  if (_ppArtifactCachePromise) return _ppArtifactCachePromise;

  _ppArtifactCachePromise = (async () => {
    const expectedHashes = {
      wasm: '36cda22791def3d520a55c0fc808369cd5849532a75fab65686e666ed3d55c10',
      zkey: '2a893b42174c813566e5c40c715a8b90cd49fc4ecf384e3a6024158c3d6de677'
    };

    async function fetchAndVerify(url, expectedHash, label) {
      const abortCtx = ppCreateTimedAbortContext(PP_WITHDRAW_FETCH_TIMEOUT_MS);
      try {
        const resp = await fetch(url, { signal: abortCtx.signal });
        if (!resp.ok) throw new Error(label + ': HTTP ' + resp.status);
        const buf = await resp.arrayBuffer();
        const hashBuf = await crypto.subtle.digest('SHA-256', buf);
        const hash = Array.from(new Uint8Array(hashBuf)).map(b => b.toString(16).padStart(2, '0')).join('');
        if (hash !== expectedHash) {
          throw new Error(label + ' integrity check failed: expected ' + expectedHash.slice(0, 16) + '... got ' + hash.slice(0, 16) + '...');
        }
        return URL.createObjectURL(new Blob([buf]));
      } catch (err) {
        if (abortCtx.didTimeout()) throw new Error(label + ' fetch timed out');
        throw err;
      } finally {
        abortCtx.cleanup();
      }
    }

    const [wasmUrl, zkeyUrl] = await Promise.all([
      fetchAndVerify(PP_WITHDRAW_WASM, expectedHashes.wasm, 'withdraw.wasm'),
      fetchAndVerify(PP_WITHDRAW_ZKEY, expectedHashes.zkey, 'withdraw.zkey')
    ]);

    _ppArtifactCache = { wasmUrl, zkeyUrl };
    return _ppArtifactCache;
  })().catch(err => {
    _ppArtifactCachePromise = null;
    throw err;
  });

  return _ppArtifactCachePromise;
}

async function ppEnsureCommitmentArtifacts() {
  if (_ppCommitmentArtifactCache) return _ppCommitmentArtifactCache;
  if (_ppCommitmentArtifactCachePromise) return _ppCommitmentArtifactCachePromise;

  _ppCommitmentArtifactCachePromise = (async () => {
    const expectedHashes = {
      wasm: '254d2130607182fd6fd1aee67971526b13cfe178c88e360da96dce92663828d8',
      zkey: '494ae92d64098fda2a5649690ddc5821fcd7449ca5fe8ef99ee7447544d7e1f3',
    };

    async function fetchAndVerify(url, expectedHash, label) {
      const abortCtx = ppCreateTimedAbortContext(PP_WITHDRAW_FETCH_TIMEOUT_MS);
      try {
        const resp = await fetch(url, { signal: abortCtx.signal });
        if (!resp.ok) throw new Error(label + ': HTTP ' + resp.status);
        const buf = await resp.arrayBuffer();
        const hashBuf = await crypto.subtle.digest('SHA-256', buf);
        const hash = Array.from(new Uint8Array(hashBuf)).map(b => b.toString(16).padStart(2, '0')).join('');
        if (hash !== expectedHash) {
          throw new Error(label + ' integrity check failed: expected ' + expectedHash.slice(0, 16) + '... got ' + hash.slice(0, 16) + '...');
        }
        return URL.createObjectURL(new Blob([buf]));
      } catch (err) {
        if (abortCtx.didTimeout()) throw new Error(label + ' fetch timed out');
        throw err;
      } finally {
        abortCtx.cleanup();
      }
    }

    const [wasmUrl, zkeyUrl] = await Promise.all([
      fetchAndVerify(PP_COMMITMENT_WASM, expectedHashes.wasm, 'commitment.wasm'),
      fetchAndVerify(PP_COMMITMENT_ZKEY, expectedHashes.zkey, 'commitment.zkey'),
    ]);

    _ppCommitmentArtifactCache = { wasmUrl, zkeyUrl };
    return _ppCommitmentArtifactCache;
  })().catch(err => {
    _ppCommitmentArtifactCachePromise = null;
    throw err;
  });

  return _ppCommitmentArtifactCachePromise;
}

function ppScheduleWithdrawPreload() {
  if (_ppWithdrawPreloadScheduled) return;
  _ppWithdrawPreloadScheduled = true;
  ppScheduleIdle(() => {
    _ppWithdrawPreloadScheduled = false;
    Promise.all([
      ppEnsureVerifiedSnarkjsEngine(),
      ppEnsureWithdrawArtifacts(),
      ppEnsureCommitmentArtifacts(),
    ]).catch(err => {
      console.warn('Privacy: withdraw dependency preload skipped', err);
    });
  }, 2500);
}

function ppwUpdateAmountSection(value, asset) {
  const lbl = $('ppwWithdrawAmtLabel');
  if (lbl) lbl.textContent = `${ppwGetActionKindLabel()} Amount (${asset})`;
  if (value == null || value <= 0n) {
    setText('ppwWithdrawBalanceHint', 'Balance: --');
    return;
  }
  setText('ppwWithdrawBalanceHint', `Balance: ${fmt(ppFormatAmountWei(value, asset))} ${asset}`);
}

function ppwUseSuggestedAmount(amountStr) {
  if (_ppwDraftPhase !== 'editing') return;
  $('ppwWithdrawAmt').value = amountStr;
  ppwUpdatePreview();
}

function ppwSetWithdrawPercent(pct) {
  if (_ppwDraftPhase !== 'editing') return;
  if (!_ppwNote || !_ppwNote.value) return;
  try {
    const value = _ppwNote.value;
    if (value <= 0n) return;
    const asset = _ppwNote.asset || 'ETH';
    const amt = value * BigInt(pct) / 100n;
    $('ppwWithdrawAmt').value = ppFormatAmountWei(amt, asset);
    ppwUpdatePreview();
  } catch {}
}

function ppwRelayAssetAddress(asset) {
  if (asset === 'BOLD') return BOLD_ADDRESS;
  if (asset === 'wstETH') return WSTETH_ADDRESS;
  return PP_ETH_ASSET;
}

async function ppEnsureAssetConfig(asset, { requireOnchain = false } = {}) {
  const cached = ppGetAssetConfig(asset);
  if (!requireOnchain && cached && cached.maxRelayFeeBPS != null) return cached;
  try {
    const c = await ppReadEntrypoint((ep) => ep.assetConfig(ppwRelayAssetAddress(asset)));
    const cfg = {
      pool: c.pool,
      minimumDepositAmount: c.minimumDepositAmount,
      vettingFeeBPS: c.vettingFeeBPS,
      maxRelayFeeBPS: c.maxRelayFeeBPS
    };
    if (asset === 'wstETH') _ppConfigWstETH = cfg;
    else if (asset === 'BOLD') _ppConfigBold = cfg;
    else _ppConfig = cfg;
    return cfg;
  } catch (err) {
    if (requireOnchain) throw err;
    return cached;
  }
}

function ppwDecodeRelayWithdrawalData(withdrawalData) {
  try {
    const decoded = ethers.AbiCoder.defaultAbiCoder().decode(
      ['address', 'address', 'uint256'],
      withdrawalData
    );
    return { recipient: decoded[0], relayer: decoded[1], feeBps: Number(decoded[2]) };
  } catch {
    return null;
  }
}

async function ppwGetRelayerMinWithdrawAmount(asset) {
  const key = asset || 'ETH';
  const cached = _ppwRelayerMinByAsset[key];
  if (typeof cached === 'bigint' || cached === null) return cached;
  if (cached && typeof cached.then === 'function') return cached;
  const pending = (async () => {
    try {
      const details = await ppwRelayerDetails(1, ppwRelayAssetAddress(asset));
      const minAmount = details?.minWithdrawAmount ? BigInt(details.minWithdrawAmount) : null;
      _ppwRelayerMinByAsset[key] = minAmount;
      return minAmount;
    } catch {
      _ppwRelayerMinByAsset[key] = null;
      return null;
    }
  })();
  _ppwRelayerMinByAsset[key] = pending;
  return pending;
}

function ppwRenderRelayMinWarning(changeValue, asset) {
  const warnEl = $('ppwRelayMinWarning');
  if (!warnEl) return;
  if (_ppwMode !== 'relay' || changeValue <= 0n) {
    setShown(warnEl, false);
    return;
  }

  const key = asset || 'ETH';
  const renderFromMin = (minAmount) => {
    if (typeof minAmount === 'bigint' && changeValue < minAmount) {
      setHTML(warnEl,
        'Remaining change after this partial withdrawal would be <b>' +
        escText(fmt(ppFormatAmountWei(changeValue, asset)) + ' ' + asset) +
        '</b>, which is below the current relayer minimum of <b>' +
        escText(fmt(ppFormatAmountWei(minAmount, asset)) + ' ' + asset) +
        '</b>. You can still withdraw it later via ragequit.'
      );
      setShown(warnEl, true);
    } else {
      setShown(warnEl, false);
    }
  };

  const cached = _ppwRelayerMinByAsset[key];
  if (typeof cached === 'bigint' || cached === null) {
    renderFromMin(cached);
    return;
  }

  const reqId = ++_ppwRelayerMinReqId;
  ppwGetRelayerMinWithdrawAmount(asset).then(minAmount => {
    if (reqId !== _ppwRelayerMinReqId) return;
    renderFromMin(minAmount);
  }).catch(() => {
    if (reqId !== _ppwRelayerMinReqId) return;
    setShown(warnEl, false);
  });
}

function ppwRenderRoundedSuggestions(withdrawnValue, value, asset) {
  const wrap = $('ppwSuggestWrap');
  const btns = $('ppwSuggestBtns');
  if (!wrap || !btns) return;
  let stepWeis = ppGetDynamicRoundingStepWeis(withdrawnValue, asset);
  stepWeis = ppFilterStepWeisByPreferredDecimals(stepWeis, asset, withdrawnValue);
  if (!stepWeis.length) { setShown(wrap, false); btns.innerHTML = ''; return; }
  // If already aligned to a configured rounded step, hide suggestions.
  if (stepWeis.some(sw => withdrawnValue % sw === 0n)) {
    setShown(wrap, false);
    btns.innerHTML = '';
    return;
  }

  const ranked = [];
  const seen = new Set();
  const pushCandidate = (candidateWei) => {
    if (candidateWei <= 0n || candidateWei > value || candidateWei === withdrawnValue) return;
    const txt = ppNormalizeAmountText(ppFormatAmountWei(candidateWei, asset));
    if (seen.has(txt)) return;
    seen.add(txt);
    const dist = candidateWei > withdrawnValue ? candidateWei - withdrawnValue : withdrawnValue - candidateWei;
    const isUp = candidateWei > withdrawnValue ? 1 : 0;
    ranked.push({ txt, candidateWei, dist, isUp });
  };

  for (const stepWei of stepWeis) {
    if (stepWei <= 0n) continue;
    const lower = (withdrawnValue / stepWei) * stepWei;
    const upper = lower + stepWei;
    pushCandidate(lower);
    pushCandidate(upper);
  }

  ranked.sort((a, b) => {
    if (a.dist === b.dist) {
      if (a.isUp !== b.isUp) return b.isUp - a.isUp; // prefer upward rounding on ties
      if (a.candidateWei === b.candidateWei) return 0;
      return a.candidateWei > b.candidateWei ? -1 : 1; // then prefer larger amount
    }
    return a.dist < b.dist ? -1 : 1;
  });

  const suggestions = ranked.slice(0, 3).map(r => r.txt);
  if (!suggestions.length) {
    setShown(wrap, false);
    btns.innerHTML = '';
    return;
  }
  btns.innerHTML = suggestions
    .map(s => `<button type="button" onclick="ppwUseSuggestedAmount('${escAttr(s)}')" style="font-size:11px;padding:3px 8px;cursor:pointer;background:var(--surface);color:var(--fg-muted);border:1px solid var(--border-muted);border-radius:0;transition:color 0.15s,border-color 0.15s">${escText(s)}</button>`)
    .join('');
  setShown(wrap, true);
}

function ppwScheduleAnonymityHint(withdrawnValue, asset) {
  const hint = $('ppwAnonHint');
  if (!hint) return;
  if (_ppwAnonTimer) clearTimeout(_ppwAnonTimer);
  // Anonymity set hint removed from UI to reduce clutter
  setShown(hint, false);
  return;
  const reqId = ++_ppwAnonReqId;
  setText(hint, 'Loading anonymity set...');
  setShown(hint, true);
  _ppwAnonTimer = setTimeout(async () => {
    try {
      const scope = ppComputeScope(asset);
      const data = await ppFetchJson(PP_DEPOSITS_LARGER_THAN_API + '?amount=' + withdrawnValue.toString(), {
        headers: { 'X-Pool-Scope': scope.toString() },
      });
      if (reqId !== _ppwAnonReqId) return;
      if (typeof data.eligibleDeposits === 'number') {
        setText(hint, 'Your anonymity set is ' + data.eligibleDeposits);
        setShown(hint, true);
      } else {
        setShown(hint, false);
      }
    } catch (e) {
      if (reqId !== _ppwAnonReqId) return;
      console.warn('Withdrawal anonymity hint unavailable:', e);
      setText(hint, 'Anonymity set unavailable');
      setShown(hint, true);
    }
  }, 500);
}

function ppwIsRagequitAction(actionKind = _ppwActionKind) {
  return actionKind === 'ragequit';
}

function ppwGetActionKindLabel(actionKind = _ppwActionKind) {
  return ppwIsRagequitAction(actionKind) ? 'Ragequit' : 'Withdraw';
}

function ppwGetActionKindResultLabel(actionKind = _ppwActionKind) {
  return ppwIsRagequitAction(actionKind) ? 'Ragequit Complete' : 'Withdrawal Complete';
}

function ppwGetActionProgressSubLabel(mode = _ppwMode, actionKind = _ppwActionKind) {
  if (ppwIsRagequitAction(actionKind)) return 'Ragequit';
  return 'Relay withdrawal';
}

function ppwSetActionKind(actionKind = 'withdraw') {
  _ppwActionKind = actionKind === 'ragequit' ? 'ragequit' : 'withdraw';
  if (_ppwActionKind === 'ragequit') {
    _ppwReviewedRelayQuote = null;
    _ppwDraftPhase = 'editing';
    ppwSetMode('direct');
  } else {
    ppwSetMode('relay');
  }
  ppwSyncDraftActionUi();
  ppwSyncWithdrawActionState();
  return _ppwActionKind;
}

function ppwUpdateRecipientHint() {
  const inputEl = $('ppwRecipient');
  const labelEl = $('ppwRecipientLabel');
  const relayWrap = $('ppwRelayRecipientWrap');
  const resolvedEl = $('ppwRecipientResolved');
  if (!inputEl) return;
  const isRagequit = ppwIsRagequitAction();
  inputEl.readOnly = false;
  inputEl.style.opacity = '';
  inputEl.placeholder = '0x address, name.wei, or name.eth';
  if (labelEl) setText(labelEl, isRagequit ? 'Deposit Address' : 'Recipient');
  setShown(relayWrap, !isRagequit);
  if (isRagequit) {
    if (resolvedEl) resolvedEl.style.display = 'none';
    ppwUpdatePreview();
    return;
  }
  ppwOnRecipientInput();
}

function ppwGetRecipientAddress() {
  const customRecipient = ($('ppwRecipient')?.value || '').trim();
  if (!customRecipient) return null;
  if (ethers.isAddress(customRecipient) && customRecipient !== ZERO_ADDRESS) return ethers.getAddress(customRecipient);
  return coinGetResolved('ppwRecipient');
}

function ppwOnRecipientInput() {
  if (_ppwDraftPhase !== 'editing') return;
  if (ppwIsRagequitAction()) {
    const resolvedEl = $('ppwRecipientResolved');
    if (resolvedEl) resolvedEl.style.display = 'none';
    ppwUpdatePreview();
    return;
  }
  if (typeof onCoinAddressInput === 'function') {
    onCoinAddressInput('ppwRecipient', 'ppwRecipientResolved', ppwUpdatePreview);
  } else {
    ppwUpdatePreview();
  }
  // Hide redundant resolved echo for raw addresses — only show for name resolution
  const v = ($('ppwRecipient')?.value || '').trim();
  if (ethers.isAddress(v)) $('ppwRecipientResolved').style.display = 'none';
}

function ppwSyncDraftActionUi(phase = _ppwDraftPhase) {
  const isRagequit = ppwIsRagequitAction();
  const noteAsset = _ppwNote?.asset || 'ETH';
  const amountEl = $('ppwWithdrawAmt');
  if ($('ppwWithdrawAmtLabel')) {
    setText('ppwWithdrawAmtLabel', `${ppwGetActionKindLabel()} Amount (${noteAsset})`);
  }
  if (amountEl) {
    amountEl.placeholder = isRagequit ? 'Full balance' : 'Enter amount';
    if (isRagequit && _ppwNote?.value != null) {
      amountEl.value = ppFormatAmountWei(_ppwNote.value, noteAsset);
    }
  }
  setShown('ppwModeSection', !isRagequit);
  setShown('ppwRagequitWarning', isRagequit);
  setShown('ppwBalanceRow', !isRagequit);
  if (isRagequit) {
    ppwResetRelayQuoteDisplay();
    setShown('ppwRelayMinWarning', false);
    setShown('ppwSuggestWrap', false);
  }
  ppwUpdateRecipientHint();
  // Don't rebuild the preview during review — the quote has already updated it
  if (phase !== 'running' && phase !== 'review') {
    ppwUpdatePreview();
  }
}

function ppwCanSubmitWithdrawalState({
  note = _ppwNote,
  mode = _ppwMode,
  actionKind = _ppwActionKind,
  resolvedRecipient = ppwGetRecipientAddress(),
  withdrawalAmountState = ppwGetWithdrawalAmountState(note),
  connectedAddress = _connectedAddress,
  signer = _signer,
  hasActiveBackupPrompt = false,
  isWalletCompatPending = false,
  isWalletCompatBlocked = false,
} = {}) {
  if (!note) return false;
  if (ppwIsRagequitAction(actionKind)) {
    if (!ppwCanRagequitNote(note, connectedAddress)) return false;
    if (hasActiveBackupPrompt) return false;
    if (connectedAddress && signer && isWalletCompatPending) return false;
    if (connectedAddress && signer && isWalletCompatBlocked) return false;
    return !!connectedAddress && !!signer;
  }
  if (note.isWithdrawable !== true || ppNormalizeReviewStatus(note.reviewStatus) !== PP_REVIEW_STATUS.APPROVED) return false;
  if (!withdrawalAmountState?.valid) return false;
  if (hasActiveBackupPrompt) return false;
  if (connectedAddress && signer && isWalletCompatPending) return false;
  if (connectedAddress && signer && isWalletCompatBlocked) return false;
  if (mode === 'relay') return !!resolvedRecipient;
  return !!connectedAddress && !!signer;
}

function ppwCanSubmitWithdrawal() {
  const walletCompat = ppGetWalletCompatibilitySnapshot();
  const hasActiveBackupPrompt = ppHasActiveWalletSeedBackupPrompt();
  const isWalletCompatPending = _connectedAddress && _signer && walletCompat.status !== 'ready';
  const isWalletCompatBlocked = _connectedAddress && _signer && walletCompat.result && !walletCompat.result.supported;
  return ppwCanSubmitWithdrawalState({
    note: _ppwNote,
    mode: _ppwMode,
    actionKind: _ppwActionKind,
    resolvedRecipient: ppwGetRecipientAddress(),
    connectedAddress: _connectedAddress,
    signer: _signer,
    hasActiveBackupPrompt,
    isWalletCompatPending,
    isWalletCompatBlocked,
  });
}

function ppwGetPhaseAwareActionLinkLabel(phase = _ppwDraftPhase, actionKind = _ppwActionKind) {
  if (ppwIsRagequitAction(actionKind)) return '\u00d7 Cancel';
  return phase === 'review' ? '\u2190 Edit' : '\u00d7 Cancel';
}

function ppwGetCurrentDraftAction() {
  if (ppwIsRagequitAction()) return _ppwDraftPhase === 'running' ? 'running' : 'cancel';
  if (_ppwDraftPhase === 'running') return 'running';
  if (_ppwDraftPhase === 'review') return 'edit';
  return 'cancel';
}

function ppwGetQuickWithdrawButtons() {
  return ['ppwWithdrawPct25', 'ppwWithdrawPct50', 'ppwWithdrawPct75', 'ppwWithdrawPct100']
    .map((id) => $(id))
    .filter(Boolean);
}

function ppwSyncWithdrawActionState() {
  const btn = $('ppwWithdrawBtn');
  const link = $('ppwDraftActionLink');
  const phase = _ppwDraftPhase || 'editing';
  if (link) {
    if (phase === 'running') {
      setShown(link, false);
    } else {
      setShown(link, true);
      setText(link, ppwGetPhaseAwareActionLinkLabel(phase, _ppwActionKind));
    }
  }
  if (btn && phase !== 'running') {
    if (ppwIsRagequitAction()) {
      setText(btn, 'Ragequit');
    } else {
      setText(btn, phase === 'review' ? 'Confirm withdrawal' : 'Review quote');
    }
  }
  ppwSyncWithdrawButtonState();
}

function ppwGetDraftPhase() {
  return _ppwDraftPhase;
}

function ppwHasReviewedRelayQuote() {
  return !!_ppwReviewedRelayQuote;
}

function ppwIsRelayQuoteDisplayed() {
  return !!_ppwDisplayedRelayQuoteKey;
}

function ppwSyncWithdrawButtonState() {
  const btn = $('ppwWithdrawBtn');
  if (!btn) return;
  if (_ppwDraftPhase === 'running') {
    setDisabled(btn, true);
    return;
  }
  setDisabled(btn, !ppwCanSubmitWithdrawal());
}

function ppwSetDraftInteractivity(phase = 'editing') {
  _ppwDraftPhase = phase;
  const isEditable = phase === 'editing';
  const isRagequit = ppwIsRagequitAction();
  const amountEl = $('ppwWithdrawAmt');
  if (amountEl) {
    amountEl.disabled = !isEditable || isRagequit;
    amountEl.readOnly = !isEditable || isRagequit;
    amountEl.style.opacity = (isEditable && !isRagequit) ? '' : '0.72';
  }
  const recipientEl = $('ppwRecipient');
  if (recipientEl) {
    recipientEl.disabled = !isEditable || isRagequit;
    recipientEl.readOnly = !isEditable || isRagequit;
    recipientEl.style.opacity = (isEditable && !isRagequit) ? '' : '0.72';
  }
  for (const quickBtn of ppwGetQuickWithdrawButtons()) {
    quickBtn.disabled = !isEditable || isRagequit;
    quickBtn.style.opacity = (isEditable && !isRagequit) ? '' : '0.55';
    quickBtn.style.cursor = (isEditable && !isRagequit) ? '' : 'default';
  }
  const relayBtn = $('ppwModeRelay');
  if (relayBtn) {
    relayBtn.disabled = !isEditable || isRagequit;
    relayBtn.style.cursor = (isEditable && !isRagequit) ? '' : 'default';
  }
  const extraGasEl = $('ppwExtraGas');
  if (extraGasEl) {
    const noteAsset = _ppwNote?.asset || 'ETH';
    extraGasEl.disabled = !isEditable || isRagequit || noteAsset === 'ETH';
  }
  ppwSyncDraftActionUi(phase);
  ppwSyncWithdrawActionState();
}

function ppwCreateReviewedRelayQuote(intent, quoteState) {
  if (!intent?.isRelayMode || !quoteState?.relayQuote) return null;
  const intentKey = ppwBuildRelayQuoteDisplayKey({
    show: true,
    asset: intent.wAsset,
    withdrawnValue: intent.withdrawnValue,
    previewRecipient: intent.resolvedRecipient,
    mode: 'relay',
    extraGas: quoteState.relayExtraGas,
  }, intent.note);
  if (!intentKey) return null;
  return { intentKey, intent, quoteState };
}

function ppwEnterRelayReviewState(reviewedQuote) {
  if (!reviewedQuote?.intentKey || !reviewedQuote?.quoteState?.relayQuote) return null;
  _ppwReviewedRelayQuote = reviewedQuote;
  setShown('ppwVerify', false);
  ppwResetProgressState();
  setText('ppwVerifyStatus', '');
  ppwSetDraftInteractivity('review');
  return reviewedQuote;
}

function ppwExitRelayReviewState({ preserveInputs = true, rerender = false, resetDisplay = true } = {}) {
  _ppwReviewedRelayQuote = null;
  setShown('ppwVerify', false);
  ppwResetProgressState();
  setText('ppwVerifyStatus', '');
  if (resetDisplay) ppwResetRelayQuoteDisplay();
  ppwSetDraftInteractivity('editing');
  if (!preserveInputs) ppwResetDraftState();
  else if (rerender) ppwUpdatePreview();
  return null;
}

function ppwHandleDraftActionLink() {
  const action = ppwGetCurrentDraftAction();
  if (action === 'running') return;
  if (action === 'edit') {
    ppwExitRelayReviewState({ preserveInputs: true, rerender: true });
    return;
  }
  ppwCloseWithdrawForm();
}

function ppwResetRelayQuoteDisplay() {
  _ppwDisplayedRelayQuoteKey = null;
  if (_ppwRelayExpiryTimer) {
    clearInterval(_ppwRelayExpiryTimer);
    _ppwRelayExpiryTimer = null;
  }
  setShown('ppwRelayFeePanel', false);
  setText('ppwRelayFeeBps', '');
  setText('ppwRelayFeeAmt', '');
  setText('ppwRelayNetAmt', '');
  setShown('ppwRelayNetRow', false);
  const expiryEl = $('ppwRelayExpiry');
  if (expiryEl) {
    expiryEl.textContent = '';
    expiryEl.style.color = '';
  }
}

function ppwBuildRelayQuoteDisplayKey(previewState = ppwBuildPreviewState(), note = _ppwNote) {
  const state = previewState || {};
  const mode = state.mode || _ppwMode;
  const withdrawnValue = state.withdrawnValue != null ? state.withdrawnValue : null;
  const previewRecipient = state.previewRecipient || null;
  const extraGas = state.extraGas != null ? !!state.extraGas : !!$('ppwExtraGas')?.checked;
  if (!note || mode !== 'relay' || withdrawnValue == null || !previewRecipient) return null;
  let noteId = note.commitment != null ? String(note.commitment) : '';
  if (!noteId && note.value != null && note.label != null && note.precommitment != null) {
    try {
      noteId = poseidon3([BigInt(note.value), BigInt(note.label), BigInt(note.precommitment)]).toString();
    } catch {}
  }
  if (!noteId) {
    noteId = [
      note.asset || '',
      note.label != null ? String(note.label) : '',
      note.leafIndex != null ? String(note.leafIndex) : '',
      note.depositIndex != null ? String(note.depositIndex) : '',
      note.withdrawalIndex != null ? String(note.withdrawalIndex) : '',
    ].join(':');
  }
  return JSON.stringify({
    noteId,
    asset: state.asset || note.asset || 'ETH',
    withdrawnValue: String(withdrawnValue),
    mode,
    recipient: String(previewRecipient).toLowerCase(),
    extraGas,
  });
}

function ppwSyncRelayQuoteDisplay(previewState) {
  const feePanel = $('ppwRelayFeePanel');
  if (!_ppwDisplayedRelayQuoteKey) {
    if (_ppwDraftPhase === 'review') ppwExitRelayReviewState({ preserveInputs: true, rerender: false, resetDisplay: true });
    else if (feePanel && feePanel.style.display !== 'none') ppwResetRelayQuoteDisplay();
    return;
  }
  const nextKey = ppwBuildRelayQuoteDisplayKey(previewState);
  if (!nextKey || nextKey !== _ppwDisplayedRelayQuoteKey) {
    if (_ppwDraftPhase === 'review') ppwExitRelayReviewState({ preserveInputs: true, rerender: false, resetDisplay: true });
    else ppwResetRelayQuoteDisplay();
  }
}

function ppwSetMode(mode) {
  if (_ppwDraftPhase === 'running') return;
  if (_ppwDraftPhase === 'review') {
    _ppwReviewedRelayQuote = null;
    _ppwDraftPhase = 'editing';
  }
  if (ppwIsRagequitAction()) mode = 'direct'; // ragequit uses direct internally
  _ppwMode = mode;
  const isRagequit = ppwIsRagequitAction();
  ppwUpdateRecipientHint();
  setShown('ppwModeSummary', !isRagequit);
  // Extra gas toggle: only shown for non-ETH relay withdrawals (not ragequit, not native ETH)
  const noteAsset = _ppwNote?.asset || 'ETH';
  const showExtraGas = !isRagequit && noteAsset !== 'ETH';
  setShown('ppwExtraGasWrap', showExtraGas);
  const extraGasEl = $('ppwExtraGas');
  if (extraGasEl) {
    if (!showExtraGas) { extraGasEl.checked = false; extraGasEl.disabled = true; }
    else { extraGasEl.disabled = false; }
  }
  ppwResetRelayQuoteDisplay();
  setShown('ppwRelayMinWarning', false);
  ppwSyncDraftActionUi();
  ppwSyncWithdrawActionState();
}

function ppwGetWithdrawalAmountState(note = _ppwNote, withdrawAmtRaw = null) {
  const asset = note?.asset || 'ETH';
  const value = note?.value != null ? BigInt(note.value) : null;
  if (value == null || value <= 0n) {
    return { asset, value, withdrawnValue: null, valid: false };
  }
  const amountText = withdrawAmtRaw == null
    ? (($('ppwWithdrawAmt')?.value || '').trim())
    : String(withdrawAmtRaw).trim();
  try {
    const withdrawnValue = amountText ? ppParseAmountToWei(amountText, asset) : value;
    return {
      asset,
      value,
      withdrawnValue,
      valid: withdrawnValue > 0n && withdrawnValue <= value,
    };
  } catch {
    return { asset, value, withdrawnValue: null, valid: false };
  }
}

function ppwBuildPreviewState(note = _ppwNote, mode = _ppwMode, connectedAddress = _connectedAddress) {
  const isRagequit = ppwIsRagequitAction();
  const extraGas = mode === 'relay' && !!$('ppwExtraGas')?.checked;
  const emptyState = {
    show: false,
    asset: note?.asset || 'ETH',
    value: note?.value || null,
    mode: isRagequit ? 'direct' : mode,
    actionKind: isRagequit ? 'ragequit' : 'withdraw',
    withdrawnValue: null,
    previewRecipient: (mode === 'relay' && !isRagequit) ? ppwGetRecipientAddress() : connectedAddress,
    extraGas,
  };
  if (!note) return emptyState;
  try {
    if (isRagequit) {
      const asset = note.asset || 'ETH';
      const value = note.value != null ? BigInt(note.value) : null;
      if (value == null || value <= 0n) return { ...emptyState, asset, value };
      const previewRecipient = connectedAddress || null;
      let html = '';
      html += '<div class="quote-row"><span>Amount</span><span>' + fmt(ppFormatAmountWei(value, asset)) + ' ' + escText(asset) + '</span></div>';
      html += '<div class="quote-row"><span>Deposit address</span><span>' + (previewRecipient
        ? '<a href="https://etherscan.io/address/' + escAttr(previewRecipient) + '" target="_blank" rel="noopener" style="color:inherit;text-decoration:underline;text-underline-offset:3px">' + escText(previewRecipient.slice(0, 6) + '\u2026' + previewRecipient.slice(-4)) + '</a>'
        : '<span style="color:var(--fg-muted)">Connect wallet</span>') + '</span></div>';
      return {
        show: true,
        asset,
        value,
        withdrawnValue: value,
        previewRecipient,
        warningText: 'Ragequit returns your full balance publicly to your deposit address. Use Withdraw instead to keep your transaction private.',
        mode: 'direct',
        extraGas: false,
        actionKind: 'ragequit',
        html,
      };
    }
    const amountState = ppwGetWithdrawalAmountState(note);
    const value = amountState.value;
    const asset = amountState.asset;
    const withdrawnValue = amountState.withdrawnValue;
    if (value == null || !amountState.valid || withdrawnValue == null) return { ...emptyState, value, asset };
    const changeValue = value - withdrawnValue;
    const isPartial = changeValue > 0n;
    const relayRecipientInput = ($('ppwRecipient')?.value || '').trim();
    const previewRecipient = mode === 'relay' ? ppwGetRecipientAddress() : connectedAddress;
    // No pre-quote preview — the form already shows all the info.
    // The preview box only appears when the relay quote arrives.
    return {
      show: false,
      asset,
      value,
      withdrawnValue,
      changeValue,
      isPartial,
      relayRecipientInput,
      previewRecipient,
      warningText: isPartial
        ? 'This is a partial withdrawal. Your remaining balance in ' + (_ppwSelectedAccountLabel || 'your Pool Account') + ' will be visible in Pool Balances after the transaction confirms.'
        : '',
      mode,
      extraGas,
      actionKind: 'withdraw',
      html: '',
    };
  } catch {
    return emptyState;
  }
}

function ppwRenderPreviewState(previewState) {
  const previewEl = $('ppwPreview');
  const warningEl = $('ppwChangeWarning');
  const relayMinWarningEl = $('ppwRelayMinWarning');
  const state = previewState || {
    show: false,
    asset: _ppwNote?.asset || 'ETH',
    value: _ppwNote?.value || null,
    mode: ppwIsRagequitAction() ? 'direct' : _ppwMode,
    actionKind: ppwIsRagequitAction() ? 'ragequit' : 'withdraw',
    withdrawnValue: null,
    previewRecipient: (_ppwMode === 'relay' && !ppwIsRagequitAction()) ? ppwGetRecipientAddress() : _connectedAddress,
    extraGas: !ppwIsRagequitAction() && _ppwMode === 'relay' && !!$('ppwExtraGas')?.checked,
  };
  ppwUpdateAmountSection(state.value || null, state.asset || (_ppwNote?.asset || 'ETH'));
  ppwSyncRelayQuoteDisplay(state);
  if (!state.show) {
    setShown(previewEl, false);
    setShown(warningEl, false);
    setShown(relayMinWarningEl, false);
    ppwClearAnonymityHint();
    ppwSyncWithdrawActionState();
    return state;
  }
  setText('ppwPreviewTitle', state.actionKind === 'ragequit' ? 'Ragequit Preview' : 'Withdrawal Preview');
  $('ppwPreviewContent').innerHTML = state.html;
  setShown(previewEl, true);
  if (warningEl) warningEl.textContent = state.warningText || '';
  setShown(warningEl, !!state.isPartial);
  if (state.actionKind === 'ragequit') {
    setShown(relayMinWarningEl, false);
    ppwClearAnonymityHint();
    setShown('ppwSuggestWrap', false);
  } else {
    ppwRenderRelayMinWarning(state.changeValue, state.asset);
    ppwScheduleAnonymityHint(state.withdrawnValue, state.asset);
    ppwRenderRoundedSuggestions(state.withdrawnValue, state.value, state.asset);
  }
  ppwSyncWithdrawActionState();
  return state;
}

function ppwUpdatePreview() {
  ppwRenderPreviewState(ppwBuildPreviewState());
}

function ppwUpdatePreviewWithQuote(intent, feeAmt, feePctLabel, expirationMs) {
  const previewEl = $('ppwPreview');
  const contentEl = $('ppwPreviewContent');
  if (!previewEl || !contentEl) return;
  const asset = intent.wAsset;
  const withdrawnValue = intent.withdrawnValue;
  const value = _ppwNote?.value != null ? BigInt(_ppwNote.value) : withdrawnValue;
  const changeValue = value - withdrawnValue;
  const isPartial = changeValue > 0n;
  const recipient = intent.resolvedRecipient || intent.recipient;
  let html = '';
  if (feeAmt) {
    const feeWei = BigInt(feeAmt);
    const netReceived = withdrawnValue - feeWei;
    html += '<div class="quote-row"><span>Relay Fee</span><span>' + escText(feePctLabel) + ' (' + fmt(ppFormatAmountWei(feeWei, asset)) + ' ' + escText(asset) + ')</span></div>';
    html += '<div class="quote-row"><span style="font-weight:600">You Receive</span><span style="font-weight:600">' + fmt(ppFormatAmountWei(netReceived > 0n ? netReceived : 0n, asset)) + ' ' + escText(asset) + '</span></div>';
  }
  if (isPartial) html += '<div class="quote-row"><span>Remaining in Pool</span><span style="color:var(--warn)">' + fmt(ppFormatAmountWei(changeValue, asset)) + ' ' + escText(asset) + '</span></div>';
  html += '<div class="quote-row" style="color:var(--fg-muted);border-top:1px solid var(--border-muted);padding-top:8px;margin-top:4px"><span>Recipient</span><span>' + (recipient ? '<a href="https://etherscan.io/address/' + escAttr(recipient) + '" target="_blank" rel="noopener" style="color:inherit;text-decoration:underline;text-underline-offset:3px">' + escText(recipient.slice(0, 6) + '\u2026' + recipient.slice(-4)) + '</a>' : '--') + '</span></div>';
  html += '<div class="quote-row" style="color:var(--fg-muted)"><span>Relayer</span><span>Fast Relay</span></div>';
  html += '<div class="quote-row" style="color:var(--fg-muted)"><span>Quote Expires</span><span id="ppwQuoteExpiry">--</span></div>';
  setText('ppwPreviewTitle', 'Withdrawal Quote');
  contentEl.innerHTML = html;
  setShown(previewEl, true);
}

// LeanIMT: build tree from ordered leaves using poseidon2
function leanIMTBuild(leaves) {
  if (leaves.length === 0) return { levels: [[]], depth: 0, root: 0n };
  const levels = [leaves.map(l => BigInt(l))];
  while (levels[levels.length - 1].length > 1) {
    const curr = levels[levels.length - 1];
    const next = [];
    for (let i = 0; i < curr.length; i += 2) {
      if (i + 1 < curr.length) next.push(poseidon2([curr[i], curr[i + 1]]));
      else next.push(curr[i]);
    }
    levels.push(next);
  }
  return { levels, depth: levels.length - 1, root: levels[levels.length - 1][0] };
}

// LeanIMT: Merkle proof for leaf at index, padded to PP_MAX_TREE_DEPTH
function leanIMTProof(levels, leafIndex) {
  const siblings = [];
  let idx = leafIndex;
  for (let d = 0; d < levels.length - 1; d++) {
    const sib = idx ^ 1;
    siblings.push(sib < levels[d].length ? levels[d][sib] : 0n);
    idx = idx >> 1;
  }
  while (siblings.length < PP_MAX_TREE_DEPTH) siblings.push(0n);
  return siblings;
}

// Relayer API helpers
async function ppwRelayerDetails(chainId, assetAddress, forceRefresh = false) {
  const cacheKey = chainId + ':' + String(assetAddress).toLowerCase();
  const now = Date.now();
  const cached = _ppRelayerDetailsCache[cacheKey];
  if (!forceRefresh && cached?.data && (now - cached.fetchedAt) < PP_RELAYER_DETAILS_CACHE_TTL_MS) {
    return cached.data;
  }
  if (!forceRefresh && cached?.pending) {
    return cached.pending;
  }
  const host = ppGetRelayerHost();
  const pending = (async () => {
    const _rdAbort = ppCreateTimedAbortContext(10_000);
    try {
      const resp = await fetch(host + '/relayer/details?chainId=' + chainId + '&assetAddress=' + assetAddress, { signal: _rdAbort.signal });
      if (!resp.ok) throw new Error('Relayer details HTTP ' + resp.status);
      const data = await resp.json();
      _ppRelayerDetailsCache[cacheKey] = { data, fetchedAt: Date.now(), pending: null };
      return data;
    } finally { _rdAbort.cleanup(); }
  })();
  _ppRelayerDetailsCache[cacheKey] = {
    data: cached?.data || null,
    fetchedAt: cached?.fetchedAt || 0,
    pending,
  };
  try {
    return await pending;
  } catch (err) {
    if (cached?.data) {
      _ppRelayerDetailsCache[cacheKey] = { data: cached.data, fetchedAt: cached.fetchedAt, pending: null };
    } else {
      delete _ppRelayerDetailsCache[cacheKey];
    }
    throw err;
  }
}

const PPW_RELAYER_COMMITMENT_TYPES = {
  RelayerCommitment: [
    { name: 'withdrawalData', type: 'bytes' },
    { name: 'asset', type: 'address' },
    { name: 'expiration', type: 'uint256' },
    { name: 'amount', type: 'uint256' },
    { name: 'extraGas', type: 'bool' },
  ],
};

function ppwRelayerCommitmentDomain(chainId) {
  return {
    name: 'Privacy Pools Relayer',
    version: '1',
    chainId: Number(chainId),
  };
}

function ppwRecoverRelayerCommitmentSigner(chainId, feeCommitment) {
  try {
    if (!feeCommitment?.signedRelayerCommitment) return '';
    const signer = ethers.verifyTypedData(
      ppwRelayerCommitmentDomain(chainId),
      PPW_RELAYER_COMMITMENT_TYPES,
      {
        withdrawalData: feeCommitment.withdrawalData,
        asset: feeCommitment.asset,
        expiration: BigInt(feeCommitment.expiration),
        amount: BigInt(feeCommitment.amount),
        extraGas: !!feeCommitment.extraGas,
      },
      feeCommitment.signedRelayerCommitment
    );
    return signer ? ethers.getAddress(signer) : '';
  } catch (err) {
    console.warn('Privacy: failed to verify relayer commitment signature', err);
    return '';
  }
}

function ppwValidateRelayQuoteCommitment(chainId, feeCommitment, nowMs = Date.now()) {
  if (!feeCommitment?.signedRelayerCommitment) {
    throw new Error('Relay quote is missing a signed relayer commitment.');
  }
  const expirationMs = Number(feeCommitment.expiration);
  if (!Number.isFinite(expirationMs) || expirationMs <= 0) {
    throw new Error('Relay quote expiration is invalid.');
  }
  if (nowMs > expirationMs) {
    throw new Error('Relay quote expired before proving started. Refresh and try again.');
  }
  const recoveredSigner = ppwRecoverRelayerCommitmentSigner(chainId, feeCommitment);
  if (!recoveredSigner) {
    throw new Error('Could not verify the relay quote commitment signature.');
  }
  return { recoveredSigner, expirationMs };
}

function ppwResolveAllowedRelayRecipients(chainId, details, feeCommitment, recoveredSigner = '') {
  let feeReceiverAddress = '';
  try {
    feeReceiverAddress = details?.feeReceiverAddress ? ethers.getAddress(details.feeReceiverAddress) : '';
  } catch {}
  if (!feeReceiverAddress) return [];
  if (feeCommitment?.extraGas) {
    const signerAddress = recoveredSigner || ppwRecoverRelayerCommitmentSigner(chainId, feeCommitment);
    try {
      const normalizedSigner = signerAddress ? ethers.getAddress(signerAddress) : '';
      if (normalizedSigner && normalizedSigner.toLowerCase() !== feeReceiverAddress.toLowerCase()) {
        return [normalizedSigner];
      }
    } catch {}
  }
  return [feeReceiverAddress];
}

async function ppwRelayerQuote(chainId, amount, asset, recipient, extraGas) {
  const host = ppGetRelayerHost();
  const abortCtx = ppCreateTimedAbortContext(PP_WITHDRAW_FETCH_TIMEOUT_MS);
  try {
    const resp = await fetch(host + '/relayer/quote', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ chainId, amount: amount.toString(), asset, recipient, extraGas: !!extraGas }),
      signal: abortCtx.signal,
    });
    if (!resp.ok) {
      let errBody = '';
      try {
        const txt = await resp.text();
        try {
          const j = JSON.parse(txt);
          errBody = j.message || j.error || txt;
        } catch {
          errBody = txt;
        }
      } catch {}
      throw new Error('Relayer quote HTTP ' + resp.status + (errBody ? ': ' + errBody : ''));
    }
    return await resp.json();
  } catch (err) {
    if (abortCtx.didTimeout()) {
      throw new Error('Relayer quote request timed out');
    }
    throw err;
  } finally {
    abortCtx.cleanup();
  }
}

async function ppwRelayerRequest(chainId, scope, withdrawal, proof, publicSignals, feeCommitment) {
  const host = ppGetRelayerHost();
  const abortCtx = ppCreateTimedAbortContext(PP_WITHDRAW_FETCH_TIMEOUT_MS);
  try {
    const resp = await fetch(host + '/relayer/request', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        chainId,
        scope: scope.toString(),
        withdrawal,
        proof: { pi_a: proof.pi_a, pi_b: proof.pi_b, pi_c: proof.pi_c },
        publicSignals,
        feeCommitment
      }, (_, v) => typeof v === 'bigint' ? v.toString() : v),
      signal: abortCtx.signal,
    });
    if (!resp.ok) {
      let errBody = '';
      try { const txt = await resp.text(); try { const j = JSON.parse(txt); errBody = j.message || j.error || ''; } catch { errBody = ''; } } catch {}
      throw new Error('Relayer request failed (HTTP ' + resp.status + ')' + (errBody ? '. ' + String(errBody).slice(0, 120) : ''));
    }
    return await resp.json();
  } catch (err) {
    if (abortCtx.didTimeout()) {
      throw new Error('Relayer request timed out');
    }
    throw err;
  } finally {
    abortCtx.cleanup();
  }
}

async function ppReadKnownStateRoots(poolAddress) {
  const iface = new ethers.Interface(PP_POOL_ABI);
  const entries = [{ target: poolAddress, data: iface.encodeFunctionData('currentRoot') }];
  for (let i = 0; i < PP_ROOT_HISTORY_SIZE; i++) {
    entries.push({ target: poolAddress, data: iface.encodeFunctionData('roots', [i]) });
  }
  return ppReadWithRpc(async (rpc) => {
    const results = await mc3ViewBatch(rpc, entries);
    const currentRoot = BigInt(mc3Decode(results, 0, iface, 'currentRoot')[0]);
    const roots = [];
    for (let i = 0; i < PP_ROOT_HISTORY_SIZE; i++) {
      roots.push(BigInt(mc3Decode(results, i + 1, iface, 'roots')[0]));
    }
    return { currentRoot, roots };
  });
}

async function ppEnsureWithdrawalRootsCurrent(poolAddress, stateRoot, aspRoot) {
  try {
    const rootState = await ppReadKnownStateRoots(poolAddress);
    const knownRoots = new Set(rootState.roots);
    knownRoots.add(rootState.currentRoot);
    if (!knownRoots.has(BigInt(stateRoot))) {
      return {
        ok: false,
        reason: 'state-root-stale',
        message: 'State root moved during proof generation. Refresh Pool Balances and retry withdrawal.',
      };
    }
  } catch (err) {
    return {
      ok: false,
      reason: 'state-root-unverified',
      message: 'Could not re-check state root onchain before submission. Retry withdrawal when RPC connectivity is stable.',
    };
  }

  try {
    const latestAspRoot = await ppReadEntrypoint((ep) => ep.latestRoot());
    if (BigInt(aspRoot) !== BigInt(latestAspRoot)) {
      return {
        ok: false,
        reason: 'asp-root-stale',
        message: 'ASP root changed during proof generation. Retry withdrawal to build a fresh proof.',
      };
    }
  } catch (err) {
    return {
      ok: false,
      reason: 'asp-root-unverified',
      message: 'Could not re-check ASP root onchain before submission. Retry withdrawal when RPC connectivity is stable.',
    };
  }

  return { ok: true };
}

function ppwStartExpiryCountdown(expiration) {
  if (_ppwRelayExpiryTimer) clearInterval(_ppwRelayExpiryTimer);
  const expiryEl = $('ppwQuoteExpiry') || $('ppwRelayExpiry');
  function update() {
    const remaining = Math.max(0, Math.floor((expiration - Date.now()) / 1000));
    if (remaining <= 0) {
      expiryEl.textContent = 'EXPIRED';
      expiryEl.style.color = 'var(--error)';
      clearInterval(_ppwRelayExpiryTimer);
      _ppwRelayExpiryTimer = null;
      // Return to editing so the user can request a fresh quote
      if (_ppwDraftPhase === 'review') {
        ppwExitRelayReviewState({ preserveInputs: true, rerender: true, resetDisplay: true });
        ppwSetDraftInteractivity('editing');
        ppwSyncWithdrawActionState();
        showStatus('Relay quote expired. Click "Review quote" to get a fresh quote.', '');
      }
    } else {
      expiryEl.textContent = remaining + 's';
      expiryEl.style.color = remaining <= 15 ? 'orange' : '';
    }
  }
  update();
  _ppwRelayExpiryTimer = setInterval(update, 1000);
}

// ── Load Deposits / My Pools ────────────────────────────────────────
let _ppwLoadAbort = null;
let _ppwLoadResults = [];
let _ppwLoadWarnings = [];
let _ppwActivityHistory = [];
let _ppwHasResolvedLoadState = false;
let _ppwEventCache = {}; // { [asset]: { depositLogs: [], withdrawnLogs: [], ragequitLogs: [], leafLogs: [], upToBlock: number, leafUpToBlock: number|null } }
const PP_POOL_VIEW_REFRESH_INTERVAL_MS = 120_000;
const PP_POOL_VIEW_POST_MUTATION_REFRESH_DELAYS_MS = [3_000, 10_000];
let _ppwRefreshInterval = null;
let _ppwScheduledRefreshes = [];

function ppInvalidatePoolViewCaches(asset, resetEventCache = false) {
  if (!asset) return;
  // Preserve the last event snapshot until a fresh fetch succeeds so transient
  // refresh failures do not blank My Pools after deposits or withdrawals.
  if (resetEventCache) delete _ppwEventCache[asset];
  try {
    const scopeKey = String(ppComputeScope(asset));
    delete _ppMtLeavesCache[scopeKey];
    for (const k of Object.keys(_ppDepositsByLabelCache)) {
      if (k.startsWith(scopeKey + ':')) delete _ppDepositsByLabelCache[k];
    }
  } catch (_) {}
}

function ppwHasReusableMasterKeys() {
  if (!_ppMasterKeys || (_connectedAddress && _ppMasterKeys.address !== _connectedAddress)) return false;
  return Object.keys(_ppMasterKeys.versions || {}).length > 0;
}

function ppwFindSelectedAccountIndex(note = _ppwNote, rows = _ppwLoadResults) {
  if (!note) return -1;
  return (Array.isArray(rows) ? rows : []).findIndex((row) => {
    if (!row) return false;
    if (note.commitment && row.commitment && row.commitment === note.commitment) return true;
    return row.nullifier === note.nullifier && row.secret === note.secret;
  });
}

function ppwReconcileSelectedAccount() {
  if (!_ppwNote) return;
  const selectedIndex = ppwFindSelectedAccountIndex();
  if (selectedIndex < 0) {
    ppwCloseWithdrawForm(false);
    return;
  }
  const row = _ppwLoadResults[selectedIndex];
  _ppwSelectedAccountLabel = 'PA-' + (selectedIndex + 1);
  _ppwNote = { ..._ppwNote, ...ppwNormalizeNoteFields(row, _ppwNote) };
  const noteAsset = _ppwNote.asset;
  const valStr = _ppwNote.value != null ? ppFormatAmountWei(_ppwNote.value, noteAsset) : '';
  setText('ppwSelectedLabel', _ppwSelectedAccountLabel + (valStr ? ' · ' + valStr + ' ' + noteAsset : ''));
  ppwSyncWithdrawActionState();
  ppwUpdatePreview();
}

function ppwCanBackgroundRefresh() {
  const walletCompat = ppGetWalletCompatibilitySnapshot();
  return _activeTab === 'privacy'
    && $('privacyTab')?.style.display !== 'none'
    && !!_connectedAddress
    && !!_signer
    && walletCompat.status === 'ready'
    && walletCompat.result?.supported === true
    && ppwHasReusableMasterKeys();
}

function ppwClearScheduledRefreshes() {
  for (const refreshId of _ppwScheduledRefreshes) clearTimeout(refreshId);
  _ppwScheduledRefreshes = [];
}

function ppwStopBackgroundRefreshLoop() {
  if (_ppwRefreshInterval) {
    clearInterval(_ppwRefreshInterval);
    _ppwRefreshInterval = null;
  }
  ppwClearScheduledRefreshes();
}

function ppwRunBackgroundRefresh() {
  if (!ppwCanBackgroundRefresh() || _ppwLoadAbort) return;
  ppwLoadDeposits();
}

function ppwScheduleMutationRefreshes() {
  ppwClearScheduledRefreshes();
  for (const delayMs of PP_POOL_VIEW_POST_MUTATION_REFRESH_DELAYS_MS) {
    const refreshId = setTimeout(() => {
      _ppwScheduledRefreshes = _ppwScheduledRefreshes.filter((id) => id !== refreshId);
      ppwRunBackgroundRefresh();
    }, delayMs);
    _ppwScheduledRefreshes.push(refreshId);
  }
}

function ppwSyncBackgroundRefreshLoop() {
  if (ppwCanBackgroundRefresh()) {
    if (!_ppwRefreshInterval) {
      _ppwRefreshInterval = setInterval(() => {
        ppwRunBackgroundRefresh();
      }, PP_POOL_VIEW_REFRESH_INTERVAL_MS);
    }
    return;
  }
  ppwStopBackgroundRefreshLoop();
}

async function ppBuildLoadedPoolAccountsFromEvents(allEvents, keys, walletSeedVersion, abortSignal = null, refreshLink = null) {
  const results = [];
  const warnings = allEvents.filter(x => x.loadWarning).map(x => x.loadWarning);
  const allAssetResults = []; // { asset, rows, withdrawnMap }[] for activity derivation
  const safeKeys = keys.safe;
  const legacyKeys = keys.legacy;
  let latestAspRootPromise = null;
  const getLatestAspRoot = async () => {
    if (!latestAspRootPromise) {
      latestAspRootPromise = ppReadEntrypoint((ep) => ep.latestRoot());
    }
    return latestAspRootPromise;
  };

  for (const { asset, depositLogs, withdrawnLogs, ragequitLogs, leafLogs } of allEvents) {
    if (abortSignal?.aborted) break;

    const scope = ppComputeScope(asset);
    const poolAddress = ppGetPoolAddress(asset);

    if (refreshLink) refreshLink.textContent = `Processing ${asset} (${walletSeedVersion})… (Cancel)`;

    const insertedLeaves = new Set();
    for (const log of leafLogs) {
      try {
        const parsed = PP_POOL_EVENTS.parseLog({ topics: log.topics, data: log.data });
        if (parsed.name === 'LeafInserted') {
          insertedLeaves.add('0x' + BigInt(parsed.args._leaf).toString(16).padStart(64, '0'));
        }
      } catch { /* skip unparseable */ }
    }

    const depositEvents = ppBuildDepositEventsMap(depositLogs);
    const withdrawnMap = ppBuildWithdrawnEventsMap(withdrawnLogs);
    const ragequitMap = ppBuildRagequitEventsMap(ragequitLogs);

    if (abortSignal?.aborted) break;

    const legacyScan = ppCollectWalletAccountsForDerivation({
      asset,
      scope,
      poolAddress,
      depositEvents,
      withdrawnMap,
      ragequitMap,
      insertedLeaves,
      derivation: 'legacy',
      keyset: legacyKeys,
      legacyKeys,
      safeKeys,
      walletSeedVersion,
      startIndex: 0,
      abortSignal,
    });
    const safeScan = ppCollectWalletAccountsForDerivation({
      asset,
      scope,
      poolAddress,
      depositEvents,
      withdrawnMap,
      ragequitMap,
      insertedLeaves,
      derivation: 'safe',
      keyset: safeKeys,
      legacyKeys,
      safeKeys,
      walletSeedVersion,
      startIndex: legacyScan.migratedCount,
      abortSignal,
    });

    let assetResults = [...legacyScan.results, ...safeScan.results];
    if (assetResults.length) {
      const labels = Array.from(new Set(assetResults
        .map(row => ppLoadedAccountLabelKey(row.label))
        .filter(label => label != null)));
      let aspLeaves = [];
      let depositsByLabel = [];
      let statusFetchFailed = false;
      let aspRootVerified = false;

      try {
        if (labels.length) {
          const [mtData, depositData, latestAspRoot] = await Promise.all([
            ppFetchMtLeaves(scope),
            ppFetchDepositsByLabel(scope, labels, abortSignal),
            getLatestAspRoot(),
          ]);
          aspLeaves = mtData?.aspLeaves || [];
          depositsByLabel = Array.isArray(depositData) ? depositData : [];
          aspRootVerified = aspLeaves.length > 0 && leanIMTBuild(aspLeaves).root === BigInt(latestAspRoot);
          if (!aspRootVerified) {
            warnings.push({ asset, kind: 'review-status-root' });
            console.warn(`Load: ${asset} ASP root is stale during review-status hydration.`);
          }
        }
      } catch (statusErr) {
        if (statusErr?.name === 'AbortError' && abortSignal?.aborted) throw statusErr;
        statusFetchFailed = true;
        warnings.push({ asset, kind: 'review-status' });
        console.warn(`Load: failed to fetch ${asset} review status data:`, statusErr);
      }

      const statusApplied = ppApplyLoadedAccountReviewStatuses(assetResults, aspLeaves, depositsByLabel, {
        statusFetchFailed,
        aspRootVerified,
      });
      if (!statusFetchFailed && statusApplied.missingLabels.length) {
        warnings.push({ asset, kind: 'review-status-missing' });
        console.warn(`Load: missing ${asset} review status for labels:`, statusApplied.missingLabels);
      }
      assetResults = statusApplied.rows;
    }

    allAssetResults.push({ asset, rows: assetResults, withdrawnMap });
    results.push(...assetResults);
  }

  const activity = ppBuildActivityFromAccountRows(allAssetResults);
  activity.sort(ppCompareActivity);

  return { results, warnings, activity };
}

function ppwReadActivityHistory() {
  if (typeof _ppwActivityHistory !== 'undefined' && Array.isArray(_ppwActivityHistory)) {
    return _ppwActivityHistory;
  }
  if (typeof globalThis !== 'undefined' && Array.isArray(globalThis._ppwActivityHistory)) {
    return globalThis._ppwActivityHistory;
  }
  return [];
}

function ppwWriteActivityHistory(activity) {
  const nextActivity = Array.isArray(activity) ? activity : [];
  if (typeof _ppwActivityHistory !== 'undefined') {
    _ppwActivityHistory = nextActivity;
    return _ppwActivityHistory;
  }
  if (typeof globalThis !== 'undefined') {
    globalThis._ppwActivityHistory = nextActivity;
    return globalThis._ppwActivityHistory;
  }
  return nextActivity;
}

function ppwCreateLoadStateSnapshot() {
  return {
    previousLoadResults: Array.isArray(_ppwLoadResults) ? _ppwLoadResults.slice() : [],
    previousLoadWarnings: Array.isArray(_ppwLoadWarnings) ? _ppwLoadWarnings.slice() : [],
    previousActivityHistory: ppwReadActivityHistory().slice(),
    previousHasResolvedLoadState: !!_ppwHasResolvedLoadState,
  };
}

function ppwRestoreLoadState(snapshot) {
  const previousLoadResults = Array.isArray(snapshot?.previousLoadResults) ? snapshot.previousLoadResults : [];
  const previousLoadWarnings = Array.isArray(snapshot?.previousLoadWarnings) ? snapshot.previousLoadWarnings : [];
  const hadResolvedLoadState = snapshot?.previousHasResolvedLoadState === true;
  if (!previousLoadResults.length && !previousLoadWarnings.length && !hadResolvedLoadState) return false;
  _ppwLoadResults = previousLoadResults;
  _ppwLoadWarnings = previousLoadWarnings;
  ppwWriteActivityHistory(snapshot?.previousActivityHistory || []);
  _ppwHasResolvedLoadState = hadResolvedLoadState;
  ppwReconcileSelectedAccount();
  ppwRenderPoolAccounts();
  if (typeof ppwRenderActivity === 'function') ppwRenderActivity();
  return true;
}

function ppwRequireConnectedWallet() {
  if (!_signer || !_connectedAddress) {
    showStatus('Connect wallet and sign to access your Privacy Pools account.', 'error');
    return false;
  }
  return true;
}

function ppwSetRefreshLinkLoading(refreshLink, label) {
  if (!refreshLink) return;
  refreshLink.textContent = `${label} (Cancel)`;
  refreshLink.onclick = () => {
    if (_ppwLoadAbort) _ppwLoadAbort.abort();
    return false;
  };
}

function ppwResetRefreshLink(refreshLink) {
  if (!refreshLink) return;
  refreshLink.textContent = '\u21bb Refresh';
  refreshLink.onclick = () => {
    ppwLoadDeposits();
    return false;
  };
}

function ppwInitializeLoadAttempt(resultsEl, refreshLink) {
  ppwSetRefreshLinkLoading(refreshLink, 'Checking wallet compatibility\u2026');
  _ppwLoadAbort = new AbortController();
  _ppwLoadResults = [];
  _ppwLoadWarnings = [];
  _ppwLoadAfterBackup = false;
  if (resultsEl && !resultsEl.innerHTML) {
    resultsEl.innerHTML = '<div style="font-size:11px;color:var(--fg-muted);padding:8px">Loading\u2026</div>';
  }
  setShown('ppwLoadRefresh', true);
  ppwUpdateLoadButton();
  return _ppwLoadAbort.signal;
}

function ppwApplyUnsupportedWalletLoadState(walletCompat) {
  _ppwLoadResults = [];
  _ppwLoadWarnings = [];
  ppwCloseWithdrawForm(false);
  ppRenderUnsupportedWalletLoadState(walletCompat);
  return walletCompat.kind === 'check_failed';
}

async function ppwFetchPoolEventsWithCacheFallback(asset) {
  // Scan all known pools for this asset so historical notes are discoverable
  // even after a pool rotation. Results are merged per-asset.
  const knownPools = ppGetKnownPools(asset);
  const poolFetches = knownPools.map(({ pool, deployBlock }) =>
    ppFetchPoolEventLogs(asset, true, { poolAddress: pool, deployBlock }).catch((e) => {
      const cacheKey = knownPools.length > 1 ? (asset + ':' + pool.toLowerCase()) : asset;
      const cached = ppGetCachedPoolEventLogs(cacheKey, true);
      console.warn(`Load: failed to fetch ${asset} events for pool ${pool.slice(0, 10)}...:`, e);
      return {
        depositLogs: cached?.depositLogs || [],
        withdrawnLogs: cached?.withdrawnLogs || [],
        ragequitLogs: cached?.ragequitLogs || [],
        leafLogs: cached?.leafLogs || [],
        _loadWarning: { asset, pool, usedCachedData: !!cached },
      };
    })
  );
  const poolResults = await Promise.all(poolFetches);
  const merged = { depositLogs: [], withdrawnLogs: [], ragequitLogs: [], leafLogs: [] };
  let loadWarning = null;
  for (const r of poolResults) {
    merged.depositLogs.push(...(r.depositLogs || []));
    merged.withdrawnLogs.push(...(r.withdrawnLogs || []));
    merged.ragequitLogs.push(...(r.ragequitLogs || []));
    merged.leafLogs.push(...(r.leafLogs || []));
    if (r._loadWarning) loadWarning = loadWarning || r._loadWarning;
  }
  return { asset, ...merged, loadWarning };
}

function ppwCreateEventLoader(assets, refreshLink, abortSignal) {
  let allEvents = null;
  return async function ensureAllEvents() {
    if (allEvents) return allEvents;
    ppwSetRefreshLinkLoading(refreshLink, 'Loading accounts\u2026');
    allEvents = await Promise.all(assets.map((asset) => ppwFetchPoolEventsWithCacheFallback(asset)));
    if (abortSignal?.aborted) throw new DOMException('Aborted', 'AbortError');
    return allEvents;
  };
}

function ppwCreateLoadProgressLogger(refreshLink) {
  return (msg) => {
    if (refreshLink) refreshLink.textContent = `${msg} (Cancel)`;
  };
}

async function ppwScanWalletSeedVersions(walletSeedVersions, ensureAllEvents, refreshLink, abortSignal) {
  let selectedWalletSeedVersion = walletSeedVersions[0] || 'v2';
  let usedFallbackWalletSeedVersion = false;
  let selectedScan = { results: [], warnings: [], activity: [] };
  const onProgress = ppwCreateLoadProgressLogger(refreshLink);

  // Recover with the preferred version first, then fall back only when a
  // clean empty scan suggests a version mismatch rather than RPC/ASP issues.
  for (let versionIndex = 0; versionIndex < walletSeedVersions.length; versionIndex++) {
    const walletSeedVersion = walletSeedVersions[versionIndex];
    const keys = await ppEnsureMasterKeys(walletSeedVersion, {
      skipCompatibilityCheck: true,
      onProgress,
    });
    if (abortSignal?.aborted) throw new DOMException('Aborted', 'AbortError');

    const versionEvents = await ensureAllEvents();
    const loadWarnings = versionEvents.filter((x) => x.loadWarning).map((x) => x.loadWarning);
    const scan = await ppBuildLoadedPoolAccountsFromEvents(
      versionEvents,
      keys,
      walletSeedVersion,
      abortSignal,
      refreshLink,
    );

    const mergedWarnings = [...loadWarnings, ...scan.warnings];
    selectedScan = {
      results: scan.results,
      warnings: mergedWarnings,
      activity: scan.activity || [],
    };
    selectedWalletSeedVersion = walletSeedVersion;

    if (ppShouldRetryWalletSeedVersion({ results: scan.results, warnings: mergedWarnings }, versionIndex < walletSeedVersions.length - 1)) {
      usedFallbackWalletSeedVersion = true;
      continue;
    }
    break;
  }

  return {
    selectedScan,
    selectedWalletSeedVersion,
    usedFallbackWalletSeedVersion,
  };
}

function ppwApplySelectedLoadScan(selectedScan, {
  selectedWalletSeedVersion,
  usedFallbackWalletSeedVersion,
  storedWalletSeedVersion,
  previousActiveVersion,
}) {
  _ppwLoadResults = Array.isArray(selectedScan?.results) ? selectedScan.results : [];
  _ppwLoadWarnings = Array.isArray(selectedScan?.warnings) ? selectedScan.warnings : [];
  ppwWriteActivityHistory(selectedScan?.activity || []);
  _ppwHasResolvedLoadState = true;
  _ppwLoadResults.sort(ppCompareLoadedAccounts);
  ppClearPendingWalletSeedBackups(_connectedAddress);
  ppRenderWalletSeedBackupNotice();
  ppwReconcileSelectedAccount();

  if (_ppwLoadResults.length > 0) {
    ppRememberWalletSeedVersion(_connectedAddress, selectedWalletSeedVersion);
    if (usedFallbackWalletSeedVersion && selectedWalletSeedVersion === 'v1') {
      showStatus('Loaded your Privacy Pools account using the legacy wallet-seed version.', '');
    }
  } else if (_ppMasterKeys && _ppMasterKeys.address === _connectedAddress) {
    _ppMasterKeys.activeVersion = storedWalletSeedVersion || previousActiveVersion || 'v2';
  }
}

let _ppwLastRenderedLoadHash = null;

function ppwComputeLoadHash() {
  // Lightweight fingerprint of load results + activity to detect changes
  const results = (_ppwLoadResults || []).map(r => (r?.label || '') + ':' + (r?.value || '') + ':' + (r?.reviewStatus || '') + ':' + (r?.source || ''));
  const activity = (ppwReadActivityHistory() || []).map(a => (a?.txHash || '') + ':' + (a?.action || '') + ':' + (a?.timestamp || ''));
  return results.join('|') + '||' + (_ppwLoadWarnings || []).length + '||' + activity.join('|');
}

function ppwRenderResolvedLoadState() {
  const hash = ppwComputeLoadHash();
  if (hash === _ppwLastRenderedLoadHash) return; // skip re-render if unchanged
  _ppwLastRenderedLoadHash = hash;
  ppwRenderPoolAccounts();
  if (typeof ppwRenderActivity === 'function') ppwRenderActivity();
  ppwScheduleActivityTimestampResolution();
}

function ppwHandleLoadDepositsError(e, snapshot) {
  if (e.name === 'AbortError') {
    if (!ppwRestoreLoadState(snapshot)) ppwRenderPoolAccounts();
    return true;
  }
  if (e.code === 'PP_WALLET_SEED_BACKUP_REQUIRED') {
    _ppwLoadAfterBackup = true;
    showStatus('Save your recovery phrase before viewing your pool balances.', 'error');
    if (!ppwRestoreLoadState(snapshot)) ppwRenderIdleState();
    return false;
  }
  if (e.code === 'ACTION_REJECTED' || e.message?.includes('rejected') || e.message?.includes('denied')) {
    showStatus('Signature required to derive deposit keys', 'error');
    if (!ppwRestoreLoadState(snapshot)) ppwRenderIdleState();
    return false;
  }
  console.warn('Privacy: deposit load failed', e);
  showStatus('Failed to load deposits. Please try again.', 'error');
  if (!ppwRestoreLoadState(snapshot)) ppwRenderPoolAccounts();
  return true;
}

async function ppwLoadDeposits() {
  const resultsEl = $('ppwLoadResults');
  const refreshLink = $('ppwRefreshLink');
  let showRefresh = true;
  const snapshot = ppwCreateLoadStateSnapshot();

  if (_ppwLoadAbort) {
    _ppwLoadAbort.abort();
    return;
  }
  if (!ppwRequireConnectedWallet()) return;

  const abortSignal = ppwInitializeLoadAttempt(resultsEl, refreshLink);

  try {
    const walletCompat = await ppRefreshWalletCompatibility();
    if (abortSignal.aborted) throw new DOMException('Aborted', 'AbortError');
    if (walletCompat && !walletCompat.supported) {
      showRefresh = ppwApplyUnsupportedWalletLoadState(walletCompat);
      return;
    }

    const assets = ['ETH', 'BOLD', 'wstETH'];
    const previousActiveVersion = (_ppMasterKeys && _ppMasterKeys.address === _connectedAddress)
      ? _ppMasterKeys.activeVersion
      : null;
    const storedWalletSeedVersion = ppGetStoredWalletSeedVersion(_connectedAddress);
    const walletSeedVersions = ppGetWalletSeedVersionCandidates(_connectedAddress);
    const ensureAllEvents = ppwCreateEventLoader(assets, refreshLink, abortSignal);
    const scanResult = await ppwScanWalletSeedVersions(walletSeedVersions, ensureAllEvents, refreshLink, abortSignal);

    ppwApplySelectedLoadScan(scanResult.selectedScan, {
      selectedWalletSeedVersion: scanResult.selectedWalletSeedVersion,
      usedFallbackWalletSeedVersion: scanResult.usedFallbackWalletSeedVersion,
      storedWalletSeedVersion,
      previousActiveVersion,
    });
    ppwRenderResolvedLoadState();
  } catch (e) {
    showRefresh = ppwHandleLoadDepositsError(e, snapshot);
  } finally {
    _ppwLoadAbort = null;
    ppwResetRefreshLink(refreshLink);
    setShown('ppwLoadRefresh', showRefresh);
    ppwUpdateLoadButton();
    if (typeof ppwRenderActivity === 'function') ppwRenderActivity();
    // A completed load may have derived reusable master keys for this session,
    // so re-evaluate the background refresh loop after every load attempt.
    ppwSyncBackgroundRefreshLoop();
  }
}

function ppwBuildCardHeaderHtml(title, metaHtml = '', metaStyle = 'font-size:10px;color:var(--fg-muted)') {
  let html = '<div style="display:flex;justify-content:space-between;align-items:baseline;margin-bottom:6px">';
  html += '<div style="font-size:12px;font-weight:600">' + escText(title) + '</div>';
  if (metaHtml) html += '<div style="' + metaStyle + '">' + metaHtml + '</div>';
  html += '</div>';
  return html;
}

function ppwBuildPoolAccountsEmptyHtml(hasWarnings) {
  const message = hasWarnings
    ? 'Could not load your Privacy Pools activity. Try again.'
    : 'No deposits found. Make sure you\u2019re using the same wallet and signing setup.';
  return '<div style="font-size:11px;color:var(--fg-muted);padding:8px;border:1px solid var(--border-muted);background:var(--surface)">' + escText(message) + '</div>';
}

function ppwBuildPoolAccountsSummaryMetaHtml(totals, pendingTotals) {
  const totalStr = Object.entries(totals).map(([asset, value]) => escText(fmt(ppFormatAmountWei(value, asset))) + ' ' + escText(asset)).join(', ');
  const pendingStr = Object.entries(pendingTotals).map(([asset, value]) => escText(fmt(ppFormatAmountWei(value, asset))) + ' ' + escText(asset)).join(', ');
  const summaryParts = [];
  if (totalStr) summaryParts.push(totalStr);
  if (pendingStr) summaryParts.push('<span style="color:var(--fg-dim)">' + pendingStr + ' pending</span>');
  return summaryParts.join(' · ');
}

function ppwBuildPoolAccountTxLink(txHash, label = 'deposit tx') {
  if (!txHash) return '';
  return ` <span style="color:var(--fg-dim)">&middot;</span> <a href="https://etherscan.io/tx/${escAttr(txHash)}" target="_blank" rel="noopener" style="font-size:10px">${escText(label)}</a>`;
}

function ppwBuildPoolAccountRowHtml(row, index, totalRows = _ppwLoadResults.length) {
  const paLabel = 'PA-' + (index + 1);
  const status = ppNormalizeReviewStatus(row.reviewStatus);
  const spent = row.source === 'spent';
  const canRagequit = ppwCanRagequitNote(row);
  const txLink = ppwBuildPoolAccountTxLink(row.depositTxHash || row.txHash);
  const border = index < totalRows - 1 ? 'border-bottom:1px solid var(--border-muted);' : '';

  if (spent) {
    const originalAmount = row.originalValue
      ? escText(fmt(ppFormatAmountWei(BigInt(row.originalValue), row.asset))) + ' ' + escText(row.asset)
      : escText(row.asset);
    const spentLabel = ppGetLoadedAccountStatusLabel(status);
    return `<div style="padding:8px 0;opacity:0.5;${border}">
      <div>
        <div style="font-size:12px"><span style="font-weight:600">${escText(paLabel)}</span> <span style="color:var(--fg-dim)">&middot;</span> ${originalAmount}${txLink}</div>
        <div style="font-size:10px;color:${ppGetLoadedAccountStatusColor(status)};font-weight:600;margin-top:2px">${spentLabel}</div>
      </div>
    </div>`;
  }

  const amountStr = row.value ? escText(fmt(ppFormatAmountWei(BigInt(row.value), row.asset))) + ' ' + escText(row.asset) : escText(row.asset);
  const sourceHint = row.source === 'change'
    ? ' <span style="font-size:10px;color:var(--fg-muted)">from partial withdrawal</span>'
    : '';
  const statusLabel = ppGetLoadedAccountStatusLabel(status);
  const statusHint = ppGetLoadedAccountStatusHintHtml(row);
  const actionHint = statusHint
    ? `<div style="font-size:10px;color:var(--fg-muted);margin-top:4px">${statusHint}</div>`
    : '';
  const actionButtons = [];
  if (row.isWithdrawable) {
    actionButtons.push(`<button class="swap-btn" onclick="ppwSelectAccount(${index}, 'withdraw')" style="flex-shrink:0;font-size:11px;padding:4px 12px;margin:0;width:auto">Withdraw</button>`);
  }
  if (canRagequit) {
    actionButtons.push(`<button class="swap-btn" onclick="ppwSelectAccount(${index}, 'ragequit')" style="flex-shrink:0;font-size:11px;padding:4px 12px;margin:0;width:auto;border-color:var(--warn);background:var(--surface);color:var(--warn)">Ragequit</button>`);
  }
  const actionBtn = actionButtons.length
    ? `<div style="display:flex;gap:6px;flex-shrink:0;align-items:center">${actionButtons.join('')}</div>`
    : '';
  return `<div style="padding:8px 0;${border}">
    <div style="display:flex;align-items:center;justify-content:space-between;gap:12px">
      <div style="min-width:0">
        <div style="font-size:12px"><span style="font-weight:600">${escText(paLabel)}</span> <span style="color:var(--fg-dim)">&middot;</span> ${amountStr}${txLink}</div>
        <div style="font-size:10px;color:${ppGetLoadedAccountStatusColor(status)};font-weight:600;margin-top:2px">${statusLabel}${sourceHint}</div>
        ${actionHint}
      </div>
      ${actionBtn}
    </div>
  </div>`;
}

function ppwBuildPoolAccountsWarningHtml(warnings = _ppwLoadWarnings) {
  if (!warnings.length) return '';
  const warningAssets = Array.from(new Set(warnings.map(w => w.asset))).join(', ');
  return '<div class="pp-notice-muted" style="display:block;margin-top:8px">Some pool data could not be loaded (' + escText(warningAssets) + '). Balances and statuses may be incomplete.</div>';
}

function ppwRenderPoolAccounts() {
  const el = $('ppwLoadResults');
  if (!el) return;

  if (_ppwLoadResults.length === 0) {
    el.innerHTML = ppwBuildPoolAccountsEmptyHtml(_ppwLoadWarnings.length > 0);
    setShown(el, true);
    return;
  }

  const totals = {};
  const pendingTotals = {};
  for (const row of _ppwLoadResults) {
    const status = ppNormalizeReviewStatus(row.reviewStatus);
    if (row.value && row.source !== 'spent') {
      const amount = BigInt(row.value);
      if (status === PP_REVIEW_STATUS.PENDING) {
        pendingTotals[row.asset] = (pendingTotals[row.asset] || 0n) + amount;
      } else if (status === PP_REVIEW_STATUS.APPROVED) {
        totals[row.asset] = (totals[row.asset] || 0n) + amount;
      }
    }
  }

  let html = '<div style="border:1px solid var(--border-muted);background:var(--surface);padding:12px">';
  html += ppwBuildCardHeaderHtml('Pool Accounts', ppwBuildPoolAccountsSummaryMetaHtml(totals, pendingTotals), 'font-size:11px;color:var(--fg-muted)');
  for (let i = 0; i < _ppwLoadResults.length; i++) {
    html += ppwBuildPoolAccountRowHtml(_ppwLoadResults[i], i, _ppwLoadResults.length);
  }
  html += '</div>';
  html += ppwBuildPoolAccountsWarningHtml(_ppwLoadWarnings);
  el.innerHTML = html;
  setShown(el, true);

  if (_ppwLoadResults.some(r => r && (r.isWithdrawable || ppwCanRagequitNote(r)))) {
    ppScheduleWithdrawPreload();
  }
}

const PP_ACTIVITY_DEFAULT_VISIBLE = 6;
let _ppwActivityExpanded = false;
let _ppwActivityResolveRequestId = 0;

function ppwGetVisibleActivityRows(history = ppwReadActivityHistory(), expanded = _ppwActivityExpanded) {
  const rows = Array.isArray(history) ? history : [];
  return expanded ? rows.slice() : rows.slice(0, PP_ACTIVITY_DEFAULT_VISIBLE);
}

function ppwScheduleActivityTimestampResolution() {
  const requestId = ++_ppwActivityResolveRequestId;
  if (typeof ppResolveActivityTimestamps !== 'function' || typeof ppwRenderActivity !== 'function') return;
  const visibleRows = ppwGetVisibleActivityRows();
  if (!visibleRows.some(row => row && row.timestamp == null && row.blockNumber != null)) return;
  ppResolveActivityTimestamps(visibleRows)
    .then(() => {
      if (requestId !== _ppwActivityResolveRequestId) return;
      ppwRenderActivity();
    })
    .catch((e) => {
      if (requestId !== _ppwActivityResolveRequestId) return;
      console.warn('Activity: timestamp resolution failed:', e);
    });
}

function ppwBuildActivityEmptyHtml(isInitialLoad) {
  const emptyMessage = isInitialLoad
    ? 'Loading activity...'
    : 'Your activity will appear here when there\'s something to show.';
  let html = '<div style="border:1px solid var(--border-muted);background:var(--surface);padding:12px">';
  html += ppwBuildCardHeaderHtml('Activity', escText(isInitialLoad ? 'Loading' : 'No activity yet'));
  html += '<div style="font-size:11px;color:var(--fg-muted);padding:8px 0;text-align:center">' + escText(emptyMessage) + '</div>';
  html += '</div>';
  return html;
}

function ppwFindActivityPoolAccountBadge(row, loadedRows) {
  if (row?.label == null || !Array.isArray(loadedRows)) return '';
  const labelKey = ppLoadedAccountLabelKey(row.label);
  for (let i = 0; i < loadedRows.length; i++) {
    const loadedRow = loadedRows[i];
    if (loadedRow.asset === row.asset && ppLoadedAccountLabelKey(loadedRow.label) === labelKey) {
      return ' <span style="font-size:10px;color:var(--fg-dim)">PA-' + (i + 1) + '</span>';
    }
  }
  return '';
}

function ppwBuildActivityRowHtml(row, index, totalRows, loadedRows) {
  const border = index < totalRows - 1 ? 'border-bottom:1px solid var(--border-muted);' : '';
  const status = ppActivityGetStatus(row);
  const statusLabel = ppActivityGetStatusLabel(status);
  const statusColor = ppActivityGetStatusColor(status);
  const timeAgo = ppGetTimeAgo(row.timestamp);
  const amountStr = row.amount != null
    ? escText(fmt(ppFormatAmountWei(BigInt(row.amount), row.asset))) + ' ' + escText(row.asset)
    : escText(row.asset);
  const txLink = row.txHash
    ? ' <a href="https://etherscan.io/tx/' + escAttr(row.txHash) + '" target="_blank" rel="noopener" style="font-size:10px;color:var(--fg-muted);text-decoration:none" title="View transaction">\u2197</a>'
    : '';
  const paBadge = ppwFindActivityPoolAccountBadge(row, loadedRows);
  const actionColor = row.action === 'Deposit' ? 'var(--fg)'
    : row.action === 'Withdrawal' ? 'var(--fg)'
    : 'var(--warn)';

  let html = '<div style="padding:8px 0;' + border + '">';
  html += '<div style="display:flex;justify-content:space-between;align-items:baseline;gap:8px">';
  html += '<div style="min-width:0">';
  html += '<div style="font-size:12px"><span style="font-weight:600;color:' + actionColor + '">' + escText(row.action) + '</span>';
  html += ' <span style="color:var(--fg-dim)">&middot;</span> ' + amountStr + paBadge + txLink + '</div>';
  html += '</div>';
  html += '<div style="text-align:right;flex-shrink:0">';
  html += '<div style="font-size:10px;color:var(--fg-muted)">' + escText(timeAgo) + '</div>';
  html += '<div style="font-size:10px;color:' + statusColor + ';font-weight:600">' + escText(statusLabel) + '</div>';
  html += '</div>';
  html += '</div>';
  html += '</div>';
  return html;
}

function ppwBuildActivityToggleHtml(total) {
  if (total <= PP_ACTIVITY_DEFAULT_VISIBLE) return '';
  const toggleLabel = _ppwActivityExpanded ? 'Show less' : 'Show all ' + total;
  let html = '<div style="text-align:center;padding-top:6px;border-top:1px solid var(--border-muted)">';
  html += '<a href="#" onclick="ppwToggleActivityExpanded();return false" style="font-size:10px;color:var(--fg-muted);text-decoration:none">' + escText(toggleLabel) + '</a>';
  html += '</div>';
  return html;
}

function ppwRenderActivity() {
  const el = $('ppwActivitySection');
  if (!el) return;

  const history = Array.isArray(_ppwActivityHistory) ? _ppwActivityHistory : [];
  if (!history.length) {
    const isInitialLoad = !!_ppwLoadAbort && !_ppwHasResolvedLoadState;
    if (!isInitialLoad && !_ppwHasResolvedLoadState) {
      el.innerHTML = '';
      setShown(el, false);
      return;
    }
    el.innerHTML = ppwBuildActivityEmptyHtml(isInitialLoad);
    setShown(el, true);
    return;
  }

  try {
    const loadedRows = Array.isArray(_ppwLoadResults) ? _ppwLoadResults : [];
    const total = history.length;
    const items = ppwGetVisibleActivityRows(history, _ppwActivityExpanded);

    let html = '<div style="border:1px solid var(--border-muted);background:var(--surface);padding:12px">';
    html += ppwBuildCardHeaderHtml('Activity', escText(total) + ' event' + (total !== 1 ? 's' : ''));

    for (let i = 0; i < items.length; i++) {
      html += ppwBuildActivityRowHtml(items[i], i, items.length, loadedRows);
    }

    html += ppwBuildActivityToggleHtml(total);
    html += '</div>';
    el.innerHTML = html;
    setShown(el, true);
  } catch (e) {
    console.warn('Activity: render failed:', e);
    el.innerHTML = '';
    setShown(el, false);
  }
}

function ppwToggleActivityExpanded() {
  _ppwActivityExpanded = !_ppwActivityExpanded;
  ppwRenderActivity();
  ppwScheduleActivityTimestampResolution();
}

let _ppwSelectedAccountLabel = null;
const PPW_DRAFT_HIDDEN_SECTIONS = ['ppwVerify', 'ppwPreview', 'ppwResult', 'ppwChangeWarning', 'ppwRelayFeePanel'];

function ppwSetDraftSectionsShown(sectionIds, shown) {
  for (const id of sectionIds) setShown(id, shown);
}

function ppwBuildProgressState(stageKey, mode = 'relay') {
  const stage = PPW_PROGRESS_STAGES[stageKey] || PPW_PROGRESS_STAGES.validating;
  const actionLabel = ppwGetActionKindLabel();
  return {
    label: stageKey === 'complete' && ppwIsRagequitAction() ? actionLabel + ' confirmed.' : stage.label,
    progress: stage.progress,
    subLabel: ppwGetActionProgressSubLabel(mode)
  };
}

function ppwResetProgressState() {
  _ppwProgressValue = 0;
  setShown('ppwProgressWrap', false);
  setShown('ppwProgressSub', false);
  setText('ppwProgressLabel', '');
  setText('ppwProgressSub', '');
  const bar = $('ppwProgressBar');
  if (bar) { bar.style.width = '0%'; bar.setAttribute('aria-valuenow', '0'); }
}

function ppwSetProgressStage(stageKey, mode = _ppwMode, options = {}) {
  const nextState = ppwBuildProgressState(stageKey, mode);
  const progress = Math.max(
    _ppwProgressValue,
    Math.max(0, Math.min(1, Number(options.progress ?? nextState.progress) || 0))
  );
  _ppwProgressValue = progress;
  setShown('ppwVerify', true);
  setShown('ppwProgressWrap', true);
  setText('ppwProgressLabel', options.label || nextState.label);
  const subLabel = options.subLabel === undefined ? nextState.subLabel : options.subLabel;
  if (subLabel) {
    setText('ppwProgressSub', subLabel);
    setShown('ppwProgressSub', true);
  } else {
    setText('ppwProgressSub', '');
    setShown('ppwProgressSub', false);
  }
  const bar = $('ppwProgressBar');
  if (bar) { bar.style.width = `${Math.round(progress * 100)}%`; bar.setAttribute('aria-valuenow', String(Math.round(progress * 100))); }
}

function ppwSetProgressStoppedState(mode = _ppwMode, label = (ppwIsRagequitAction() ? 'Ragequit not completed.' : 'Withdrawal not completed.')) {
  setShown('ppwVerify', true);
  setShown('ppwProgressWrap', true);
  setText('ppwProgressLabel', label);
  setText('ppwProgressSub', ppwGetActionProgressSubLabel(mode));
  setShown('ppwProgressSub', true);
  const bar = $('ppwProgressBar');
  if (bar) { bar.style.width = `${Math.round(_ppwProgressValue * 100)}%`; bar.setAttribute('aria-valuenow', String(Math.round(_ppwProgressValue * 100))); }
}

function ppwNormalizeNoteFields(row, fallback = null) {
  return {
    nullifier: row.nullifier,
    secret: row.secret,
    precommitment: poseidon2([row.nullifier, row.secret]),
    asset: row.asset || (fallback ? fallback.asset : null) || 'ETH',
    derivation: row.derivation || (fallback ? fallback.derivation : null) || 'safe',
    walletSeedVersion: row.walletSeedVersion || (fallback ? fallback.walletSeedVersion : null) || null,
    depositor: row.depositor || (fallback ? fallback.depositor : null) || null,
    depositIndex: row.depositIndex != null ? Number(row.depositIndex) : (fallback ? fallback.depositIndex : null),
    withdrawalIndex: row.withdrawalIndex ?? (fallback ? fallback.withdrawalIndex : null),
    leafIndex: row.leafIndex != null ? Number(row.leafIndex) : (fallback ? fallback.leafIndex : null),
    value: row.value != null ? BigInt(row.value) : (fallback ? fallback.value : null),
    label: row.label != null ? BigInt(row.label) : (fallback ? fallback.label : null),
    commitment: row.commitment ?? (fallback ? fallback.commitment : null),
    reviewStatus: ppNormalizeReviewStatus(row.reviewStatus),
    isValid: !!row.isValid,
    isWithdrawable: !!row.isWithdrawable,
    isOriginalDepositor: !!row.isOriginalDepositor,
    isRagequittable: !!row.isRagequittable,
    timestamp: row.timestamp ?? null,
  };
}


function ppwResetDraftState() {
  const _amtEl = $('ppwWithdrawAmt'); if (_amtEl) _amtEl.value = '';
  const _rcpEl = $('ppwRecipient'); if (_rcpEl) _rcpEl.value = '';
  setShown('ppwRecipientResolved', false);
  _ppwReviewedRelayQuote = null;
  _ppwDraftPhase = 'editing';
  ppwResetRelayQuoteDisplay();
  ppwSetDraftSectionsShown(PPW_DRAFT_HIDDEN_SECTIONS, false);
  ppwResetProgressState();
  setText('ppwVerifyStatus', '');
  ppwClearAnonymityHint();
  ppwSetDraftInteractivity('editing');
  setText('ppwResultSummary', ppwGetActionKindResultLabel());
}

function ppwSelectAccount(index, actionKind = 'withdraw') {
  const r = _ppwLoadResults[index];
  if (!r) return;
  const isRagequit = actionKind === 'ragequit';
  const isAllowed = isRagequit ? ppwCanRagequitNote(r) : r.isWithdrawable;
  if (!isAllowed) {
    showStatus(ppGetLoadedAccountBlockedReason(r, actionKind), 'error');
    return;
  }
  _ppwSelectedAccountLabel = 'PA-' + (index + 1);
  _ppwNote = ppwNormalizeNoteFields(r);
  ppwSetActionKind(isRagequit ? 'ragequit' : 'withdraw');

  ppwResetDraftState();
  ppwSetMode(isRagequit ? 'direct' : 'relay');

  // Show action form with selected account label
  const noteAsset = _ppwNote.asset || 'ETH';
  const valStr = _ppwNote.value != null ? ppFormatAmountWei(_ppwNote.value, noteAsset) : '';
  setText('ppwSelectedLabel', ppwGetActionKindLabel() + ' ' + _ppwSelectedAccountLabel + (valStr ? ' \u00b7 ' + valStr + ' ' + noteAsset : ''));
  setText('ppwResultSummary', ppwGetActionKindResultLabel());
  setShown('ppwParsedCard', true);
  setShown('ppwParsed', true);
  ppwSetDraftInteractivity('editing');
  // Default to full withdrawal amount (100%)
  if (!isRagequit && _ppwNote?.value != null) {
    const amtEl = $('ppwWithdrawAmt');
    if (amtEl) amtEl.value = ppFormatAmountWei(_ppwNote.value, noteAsset);
  }
  if (_ppwMode === 'relay') {
    const egEl = $('ppwExtraGas');
    const isNativeETH = noteAsset === 'ETH';
    if (isNativeETH) { egEl.checked = false; egEl.disabled = true; }
    else { egEl.disabled = false; }
  }
  ppwUpdatePreview();
  ppScheduleWithdrawPreload();
  // Eagerly prefetch relayer details and MT leaves so they're cached
  // by the time the user clicks "Review quote"
  if (!isRagequit) {
    ppwRelayerDetails(1, ppwRelayAssetAddress(noteAsset)).catch(() => {});
  }
  ppScheduleIdle(() => {
    ppFetchMtLeaves(ppComputeScope(noteAsset)).catch(err => {
      console.warn('Privacy: mt-leaves preload skipped', err);
    });
  }, 1200);

  // Scroll to withdrawal form card
  const form = $('ppwParsedCard');
  if (form) form.scrollIntoView({ behavior: 'smooth', block: 'start' });
}

function ppwCloseWithdrawForm(shouldScroll = true) {
  _ppwSelectedAccountLabel = null;
  _ppwNote = null;
  _ppwActionKind = 'withdraw';
  setShown('ppwParsed', false);
  setShown('ppwParsedCard', false);
  // Clear form state
  ppwResetDraftState();
  ppwSetActionKind('withdraw');
  ppwSetMode('relay');
  setDisabled('ppwWithdrawBtn', true);
  // Scroll to Pool Accounts list
  if (shouldScroll) {
    const el = $('ppwLoadResults') || $('ppwLoadBtn');
    if (el) el.scrollIntoView({ behavior: 'smooth', block: 'start' });
  }
}

function ppwConvertSnarkjsProof(proof, publicSignals) {
  const pA = [BigInt(proof.pi_a[0]), BigInt(proof.pi_a[1])];
  const pB = [
    [BigInt(proof.pi_b[0][1]), BigInt(proof.pi_b[0][0])],
    [BigInt(proof.pi_b[1][1]), BigInt(proof.pi_b[1][0])]
  ];
  const pC = [BigInt(proof.pi_c[0]), BigInt(proof.pi_c[1])];
  const pubSigs = publicSignals.map(s => BigInt(s));
  return { pA, pB, pC, pubSigs };
}

async function ppwCheckNullifierUnspent(poolAddress, nullifier) {
  const nullHash = poseidon1([nullifier]);
  const isSpent = await ppReadWithRpc(async (rpc) => {
    const pool = new ethers.Contract(poolAddress, PP_POOL_ABI, rpc);
    return await pool.nullifierHashes(nullHash);
  });
  return { isSpent, nullHash };
}

async function ppwVerifyProofOnchain(poolAddress, pA, pB, pC, pubSigs) {
  const isValid = await ppReadWithRpc(async (rpc) => {
    const poolRO = new ethers.Contract(poolAddress, PP_POOL_ABI, rpc);
    const verifierAddress = await poolRO.WITHDRAWAL_VERIFIER();
    const verifier = new ethers.Contract(verifierAddress, PP_VERIFIER_ABI, rpc);
    return await verifier.verifyProof.staticCall(pA, pB, pC, pubSigs);
  });
  return isValid;
}

async function ppwVerifyRagequitProofOnchain(poolAddress, pA, pB, pC, pubSigs) {
  const isValid = await ppReadWithRpc(async (rpc) => {
    const poolRO = new ethers.Contract(poolAddress, PP_POOL_ABI, rpc);
    const verifierAddress = await poolRO.RAGEQUIT_VERIFIER();
    const verifier = new ethers.Contract(verifierAddress, PP_RAGEQUIT_VERIFIER_ABI, rpc);
    return await verifier.verifyProof.staticCall(pA, pB, pC, pubSigs);
  });
  return isValid;
}

async function ppwSimulateRagequitOnchain(poolAddress, pA, pB, pC, pubSigs) {
  const poolSigner = new ethers.Contract(poolAddress, PP_POOL_ABI, _signer);
  await poolSigner.ragequit.staticCall([pA, pB, pC, pubSigs]);
  return true;
}

async function ppwParseChangeLeafIndex(receipt, poolAddress, expectedChangeCommitment, scope) {
  for (const rlog of receipt.logs) {
    try {
      if (rlog.address.toLowerCase() !== poolAddress.toLowerCase()) continue;
      const parsed = PP_POOL_EVENTS.parseLog({ topics: rlog.topics, data: rlog.data });
      if (parsed.name === 'LeafInserted' && BigInt(parsed.args._leaf) === expectedChangeCommitment) {
        return { leafIndex: Number(parsed.args._index), commitment: '0x' + expectedChangeCommitment.toString(16).padStart(64, '0') };
      }
    } catch {}
  }
  // Fallback: fetch from stateTreeLeaves API
  try {
    const fbData = await ppFetchMtLeaves(scope, true);
    const idx = fbData.stateTreeLeaves.findIndex(l => BigInt(l) === expectedChangeCommitment);
    if (idx >= 0) {
      return { leafIndex: idx, commitment: '0x' + expectedChangeCommitment.toString(16).padStart(64, '0') };
    }
  } catch {}
  return { leafIndex: null, commitment: '0x' + expectedChangeCommitment.toString(16).padStart(64, '0') };
}

async function ppwFetchAndVerifyTreeData(SCOPE, leafIndex, expectedCommitment, log) {
  log('Fetching tree data from 0xbow API...');
  const apiData = await ppFetchMtLeaves(SCOPE);
  const { aspLeaves, stateTreeLeaves: treeLeaves } = apiData;
  log('Fetched ' + treeLeaves.length + ' state leaves + ' + aspLeaves.length + ' ASP leaves from 0xbow API.');

  let adjustedLeafIndex = leafIndex;
  if (adjustedLeafIndex == null || isNaN(adjustedLeafIndex)) {
    const resolved = treeLeaves.indexOf(expectedCommitment);
    if (resolved >= 0) {
      adjustedLeafIndex = resolved;
      log('Resolved leaf index ' + resolved + ' from state tree.');
    } else {
      throw new Error('Could not find commitment in state tree. The deposit may not be finalized yet. Try again shortly.');
    }
  }

  const treeLeaf = (adjustedLeafIndex >= 0 && adjustedLeafIndex < treeLeaves.length) ? treeLeaves[adjustedLeafIndex] : null;
  if (adjustedLeafIndex < 0 || adjustedLeafIndex >= treeLeaves.length) {
    throw new Error('Leaf index ' + adjustedLeafIndex + ' out of range (tree has ' + treeLeaves.length + ' leaves)');
  }
  if (treeLeaf == null || treeLeaf === 0n) {
    throw new Error('Tree leaf at position ' + adjustedLeafIndex + ' is empty. Verify your leaf index.');
  }
  if (treeLeaf !== expectedCommitment) {
    throw new Error('Commitment mismatch at tree position ' + adjustedLeafIndex + ': expected 0x' + expectedCommitment.toString(16).slice(0, 16) + '... but tree has 0x' + treeLeaf.toString(16).slice(0, 16) + '...');
  }
  log('Commitment verified at tree position ' + adjustedLeafIndex + '.');

  log('Building state Merkle tree...');
  const stateTree = leanIMTBuild(treeLeaves);
  const stateSiblings = leanIMTProof(stateTree.levels, adjustedLeafIndex);
  log('State tree depth=' + stateTree.depth + ' root=0x' + stateTree.root.toString(16).slice(0, 16) + '...');

  return { treeLeaves, aspLeaves, adjustedLeafIndex, stateTree, stateSiblings };
}

const _ppwStatusLogEscMap = { '&': '&amp;', '<': '&lt;', '>': '&gt;' };
function ppwEscapeStatusLogText(value) {
  return String(value).replace(/[&<>]/g, (match) => _ppwStatusLogEscMap[match]);
}

function ppwAppendStatusLogLine(statusEl, html) {
  if (statusEl) statusEl.innerHTML += String(html || '') + '<br>';
}

function ppwCreateWithdrawRun(options = {}) {
  const statusEl = options.statusEl || $('ppwVerifyStatus');
  const statusBox = options.statusBox || $('ppwVerify');
  const btn = options.btn || $('ppwWithdrawBtn');
  let progressStarted = false;
  return {
    statusEl,
    statusBox,
    btn,
    log(msg) {
      if (statusBox) setShown(statusBox, true);
      ppwAppendStatusLogLine(statusEl, ppwEscapeStatusLogText(msg));
    },
    logHtml(html) {
      if (statusBox) setShown(statusBox, true);
      ppwAppendStatusLogLine(statusEl, html);
    },
    setProgressStage(stageKey, mode = _ppwMode, options = {}) {
      progressStarted = true;
      ppwSetProgressStage(stageKey, mode, options);
    },
    reset() {
      ppwSetDraftInteractivity('running');
      if (btn) setDisabled(btn, true);
      if (btn) setText(btn, 'Working...');
      if (statusEl) statusEl.innerHTML = '';
      ppwResetProgressState();
    },
    setButtonText(label) {
      if (btn) setText(btn, label);
    },
    stopIfNeeded(successful = false, mode = _ppwMode) {
      if (progressStarted && !successful) {
        ppwSetProgressStoppedState(mode);
      }
      if (_ppwDraftPhase === 'running') {
        const nextPhase = !successful && mode === 'relay' && _ppwReviewedRelayQuote ? 'review' : 'editing';
        ppwSetDraftInteractivity(nextPhase);
      } else {
        ppwSyncWithdrawActionState();
      }
    },
  };
}

function ppwDecodeWithdrawalError(error) {
  const errStr = String(error?.data || error?.message || error?.reason || error || '');
  const ppErrors = {
    'PrecommitmentAlreadyUsed': 'This deposit has already been used.',
    'InvalidProcessooor': 'Recipient address mismatch. Ensure you are using the correct withdrawal mode.',
    'ExpiredCommitment': 'Relay fee commitment expired. Re-quote and try again.',
    'IncorrectASPRoot': 'Pool data is temporarily out of sync. Wait a few minutes and retry.',
    'NullifierAlreadySpent': 'This deposit has already been withdrawn.',
    'InvalidProof': 'Proof verification failed. Please retry your withdrawal.',
    'InvalidCommitment': 'Invalid withdrawal data. Please retry.',
    'OnlyOriginalDepositor': 'Only the original depositor wallet can ragequit this Pool Account.',
    'ScopeMismatch': 'Pool mismatch. Ensure the correct pool is selected.',
    'ContextMismatch': 'Withdrawal data mismatch. Please retry.',
    'UnknownStateRoot': 'Pool state is temporarily out of sync. Wait a few minutes and retry.',
    'InsufficientBalance': 'Pool has insufficient balance for this withdrawal amount.'
  };
  for (const [key, msg] of Object.entries(ppErrors)) {
    if (errStr.includes(key)) return msg;
  }
  return null;
}

function ppwHandleWithdrawalFailure(resultOrError, run) {
  const actionLabel = ppwGetActionKindLabel();
  const actionLower = ppwIsRagequitAction() ? 'ragequit' : 'withdrawal';
  if (resultOrError && typeof resultOrError === 'object' && ('receipt' in resultOrError || 'txHash' in resultOrError)) {
    const receipt = resultOrError.receipt || null;
    const txHash = resultOrError.txHash || '?';
    if (receipt && receipt.status === 0) {
      run.logHtml('<b>Transaction reverted onchain.</b> tx: ' + ppwEscapeStatusLogText(txHash) + '. This may indicate the deposit was already spent, the proof was invalid, or the fee commitment expired.');
      showStatus(
        ppwIsRagequitAction()
          ? 'Transaction reverted onchain. The Pool Account may have been already spent or the proof may no longer be valid.'
          : 'Transaction reverted onchain. The deposit may have been already spent or the relay quote may have expired.',
        'error'
      );
      return;
    }
    if (!receipt) {
      run.logHtml('<b>Transaction not confirmed</b> within polling window. tx: ' + ppwEscapeStatusLogText(txHash));
      showStatus('Transaction submitted but not yet confirmed. Check Etherscan for tx: ' + txHash, 'error');
      return;
    }
    run.logHtml('<b>Transaction may have failed.</b> Check Etherscan.');
    showStatus('Transaction may have failed', 'error');
    return;
  }
  const decodedMessage = ppwDecodeWithdrawalError(resultOrError);
  if (decodedMessage) {
    run.logHtml('<b>Error:</b> ' + ppwEscapeStatusLogText(decodedMessage));
    showStatus(decodedMessage, 'error');
    return;
  }
  run.logHtml('<b>Error:</b> ' + ppwEscapeStatusLogText(actionLabel) + ' failed. Please try again.');
  const msg = String(resultOrError?.message || resultOrError?.reason || resultOrError || '').toLowerCase();
  if (!(msg.includes('user rejected') || msg.includes('user denied') || msg.includes('user cancelled'))) {
    showStatus(actionLabel + ' failed. Please try again.', 'error');
  }
  console.error('Privacy: unmatched ' + actionLower + ' error', resultOrError);
}

async function ppwCollectWithdrawalIntent(run) {
  const note = _ppwNote;
  const isRagequit = ppwIsRagequitAction();
  if (!note) {
    showStatus('Select a Pool Account first', 'error');
    return null;
  }
  if (isRagequit) {
    if (!ppwCanRagequitNote(note)) {
      showStatus(ppGetLoadedAccountBlockedReason(note, 'ragequit'), 'error');
      return null;
    }
  } else if (note.isWithdrawable !== true || ppNormalizeReviewStatus(note.reviewStatus) !== PP_REVIEW_STATUS.APPROVED) {
    showStatus(ppGetLoadedAccountBlockedReason(note, 'withdraw'), 'error');
    return null;
  }
  const value = note.value || 0n;
  const label = note.label != null ? BigInt(note.label) : null;
  const wAsset = note.asset || 'ETH';
  if (value === 0n) {
    showStatus(isRagequit ? 'Pool Account balance required' : 'Deposit value required', 'error');
    return null;
  }
  if (label == null) {
    showStatus('Deposit label required', 'error');
    return null;
  }
  let withdrawnValue;
  if (isRagequit) {
    withdrawnValue = value;
  } else {
    const withdrawAmtRaw = $('ppwWithdrawAmt')?.value.trim() || '';
    try {
      withdrawnValue = withdrawAmtRaw ? ppParseAmountToWei(withdrawAmtRaw, wAsset) : value;
    } catch {
      showStatus(`Invalid withdraw amount. Enter a valid ${wAsset} amount.`, 'error');
      return null;
    }
    if (withdrawnValue > value) {
      showStatus('Withdraw amount exceeds deposit value', 'error');
      return null;
    }
    if (withdrawnValue === 0n) {
      showStatus('Withdraw amount must be > 0', 'error');
      return null;
    }
  }
  if (_signer && _connectedAddress) {
    run.log('Checking wallet compatibility...');
    try {
      await ppEnsureWalletCompatibility();
    } catch (compatErr) {
      showStatus(String(compatErr?.message || compatErr || 'Could not verify whether this wallet supports Privacy Pools right now.'), 'error');
      return null;
    }
  }
  const canDeriveDeterministicKeys = (_ppMasterKeys && (!_connectedAddress || _ppMasterKeys.address === _connectedAddress)) || (_signer && _connectedAddress);
  if (!canDeriveDeterministicKeys) {
    showStatus('Connect wallet and sign to access your Privacy Pools account.', 'error');
    return null;
  }

  const customRecipient = $('ppwRecipient')?.value.trim() || '';
  const resolvedRecipient = ppwGetRecipientAddress();
  const isRelayMode = !isRagequit && _ppwMode === 'relay';
  if (isRelayMode && (!customRecipient || !resolvedRecipient)) {
    showStatus('Enter a recipient address, name.wei, or name.eth for relay withdrawal.', 'error');
    return null;
  }
  const recipient = _connectedAddress && (isRagequit || !isRelayMode) ? _connectedAddress : (isRelayMode ? resolvedRecipient : _connectedAddress);
  if (!recipient) {
    showStatus(isRelayMode ? 'Enter a recipient address or connect wallet for relay withdrawal.' : 'Connect wallet first', 'error');
    return null;
  }
  if (!isRelayMode && !_signer) {
    connectWallet();
    return null;
  }

  run.setProgressStage('validating', _ppwMode);
  run.log('Validating inputs...');
  const wIsBOLD = wAsset === 'BOLD';
  const wIsWSTETH = wAsset === 'wstETH';
  // Use the note's original pool identity when available so historical
  // notes resolve correctly even if the asset's pool address changes.
  const poolAddress = note.poolAddress || ppGetPoolAddress(wAsset);
  const scope = note.scope ?? ppComputeScope(wAsset);
  run.log('Asset: ' + wAsset + ' Pool: ' + poolAddress.slice(0, 10) + '... SCOPE: ' + scope.toString().slice(0, 16) + '...');
  if (!isRagequit) run.setProgressStage('checkingPoolState', _ppwMode);
  return {
    note,
    leafIndex: note.leafIndex,
    value,
    label,
    wAsset,
    withdrawnValue,
    customRecipient,
    resolvedRecipient,
    isRelayMode,
    recipient,
    wIsBOLD,
    wIsWSTETH,
    poolAddress,
    scope,
    actionKind: isRagequit ? 'ragequit' : 'withdraw',
  };
}

async function ppwLoadWithdrawalState(intent, run) {
  try {
    const { isSpent, nullHash } = await ppwCheckNullifierUnspent(intent.poolAddress, intent.note.nullifier);
    if (isSpent) {
      showStatus('This deposit has already been withdrawn (nullifier spent onchain).', 'error');
      run.logHtml('<b>Already spent.</b> Nullifier hash 0x' + ppwEscapeStatusLogText(nullHash.toString(16).slice(0, 16)) + '... is marked as used.');
      return null;
    }
    run.log('Nullifier not yet spent. Deposit is valid.');
  } catch (spentErr) {
    console.warn('Privacy: could not verify spent status', spentErr);
    run.logHtml('<b>Error:</b> Could not verify whether this deposit has already been withdrawn.');
    showStatus('Could not verify whether this deposit has already been withdrawn. Retry when RPC connectivity is stable.', 'error');
    return null;
  }

  const expectedCommitment = poseidon3([intent.value, intent.label, intent.note.precommitment]);
  let aspLeaves, adjustedLeafIndex, stateTree, stateSiblings;
  try {
    ({ aspLeaves, adjustedLeafIndex, stateTree, stateSiblings } =
      await ppwFetchAndVerifyTreeData(intent.scope, intent.leafIndex, expectedCommitment, (msg) => run.log(msg)));
  } catch (treeErr) {
    showStatus('Could not fetch pool state. Please try again.', 'error');
    console.warn('Privacy: tree fetch failed', treeErr);
    return null;
  }

  try {
    const rootState = await ppReadKnownStateRoots(intent.poolAddress);
    const knownRoots = new Set(rootState.roots);
    knownRoots.add(rootState.currentRoot);
    if (stateTree.root !== rootState.currentRoot) {
      if (!knownRoots.has(stateTree.root)) {
        run.logHtml('<b>Error:</b> State tree root is not in the onchain recent-root window.');
        showStatus('State root is too stale for this pool. Refresh Pool Balances and try again.', 'error');
        return null;
      }
      run.logHtml('<b>Warning:</b> State tree root differs from onchain currentRoot (local 0x' + ppwEscapeStatusLogText(stateTree.root.toString(16).slice(0, 16)) + '... vs onchain 0x' + ppwEscapeStatusLogText(rootState.currentRoot.toString(16).slice(0, 16)) + '...) but is still within the recent root window.');
      showStatus('State root slightly behind onchain. This is normal and the withdrawal will likely succeed. If not, retry in a few minutes.', '');
    } else {
      run.log('State root verified against onchain pool.currentRoot().');
    }
  } catch (stateRootErr) {
    console.warn('Privacy: state root verification failed', stateRootErr);
    run.logHtml('<b>Error:</b> Could not verify state root onchain.');
    showStatus('Could not verify state root onchain. Retry withdrawal when RPC connectivity is stable.', 'error');
    return null;
  }

  run.log('Verifying ASP root against onchain latestRoot...');
  let aspIndex;
  let aspTree;
  let aspSiblings;
  try {
    const aspVerification = await ppVerifyAspDataWithRetries(intent.scope, intent.label, {
      initialAspLeaves: aspLeaves,
      log: (msg) => run.log(msg),
    });
    aspLeaves = aspVerification.aspLeaves;
    aspIndex = aspVerification.aspIndex;
    aspTree = aspVerification.aspTree;
    if (aspVerification.status === 'missing-label') {
      showStatus('Your deposit label is not yet in the ASP association set. This can take up to 7 days after deposit. If you know it should already be approved, the API may still be catching up. Try again shortly.', 'error');
      return null;
    }
    if (aspVerification.status === 'root-mismatch') {
      showStatus(
        'ASP root mismatch after refetching: local 0x' + aspTree.root.toString(16).slice(0, 16) +
        '... vs onchain 0x' + aspVerification.onChainASPRoot.toString(16).slice(0, 16) +
        '... The API is still stale. Retry in a few minutes.',
        'error'
      );
      return null;
    }
    run.log('Label found in ASP set at index ' + aspIndex + '.');
    run.log('ASP tree depth=' + aspTree.depth + ' root=0x' + aspTree.root.toString(16).slice(0, 16) + '...');
    if (aspVerification.attempts > 1) {
      run.log('ASP root verified against onchain after ' + aspVerification.attempts + ' attempts.');
    } else {
      run.log('ASP root verified against onchain.');
    }
    aspSiblings = leanIMTProof(aspTree.levels, aspIndex);
  } catch (aspRootErr) {
    console.warn('Privacy: ASP root verification failed', aspRootErr);
    run.logHtml('<b>Error:</b> Could not verify ASP root onchain.');
    showStatus('Could not verify ASP root onchain. Retry withdrawal when RPC connectivity is stable.', 'error');
    return null;
  }

  return {
    expectedCommitment,
    adjustedLeafIndex,
    stateTree,
    stateSiblings,
    aspTree,
    aspSiblings,
    aspIndex,
  };
}

function ppwCreateRelayQuoteState(intent) {
  const relayChainId = 1;
  const relayAssetAddr = intent.wIsWSTETH ? WSTETH_ADDRESS : (intent.wIsBOLD ? BOLD_ADDRESS : PP_ETH_ASSET);
  const relayIsNativeETH = !intent.wIsBOLD && !intent.wIsWSTETH;
  return {
    isRelayMode: intent.isRelayMode,
    relayQuote: null,
    quotedFeeBPS: null,
    relayChainId,
    relayAssetAddr,
    relayIsNativeETH,
    relayExtraGas: !relayIsNativeETH && !!$('ppwExtraGas')?.checked,
    relayPreflightDone: false,
    details: null,
  };
}

async function ppwRefreshRelayQuote(quoteState, intent, run, runPreflight = false) {
  let details = quoteState.details;
  if (runPreflight && !quoteState.relayPreflightDone) {
    details = await ppwRelayerDetails(quoteState.relayChainId, quoteState.relayAssetAddr);
    if (!details || details.error) throw new Error(details?.error || 'Relayer does not support this asset');
    const minWithdrawAmount = details.minWithdrawAmount ? BigInt(details.minWithdrawAmount) : null;
    _ppwRelayerMinByAsset[intent.wAsset] = minWithdrawAmount;
    if (minWithdrawAmount && intent.withdrawnValue < minWithdrawAmount) {
      throw new Error('Withdraw amount below relayer minimum (' + fmt(ppFormatAmountWei(minWithdrawAmount, intent.wAsset)) + ' ' + intent.wAsset + ').');
    }
    const remainingChange = intent.value - intent.withdrawnValue;
    if (minWithdrawAmount && remainingChange > 0n && remainingChange < minWithdrawAmount) {
      run.logHtml('<b>Warning:</b> Remaining change would be ' + ppwEscapeStatusLogText(fmt(ppFormatAmountWei(remainingChange, intent.wAsset))) + ' ' + ppwEscapeStatusLogText(intent.wAsset) + ', below relayer minimum (' + ppwEscapeStatusLogText(fmt(ppFormatAmountWei(minWithdrawAmount, intent.wAsset))) + ' ' + ppwEscapeStatusLogText(intent.wAsset) + ').');
      run.log('Remainder can still be withdrawn later via ragequit.');
    }
    quoteState.relayPreflightDone = true;
    run.log('Relayer supports ' + intent.wAsset + ' on chain=' + quoteState.relayChainId + '.');
  }
  if (!details) {
    details = await ppwRelayerDetails(quoteState.relayChainId, quoteState.relayAssetAddr);
  }

  const requestRelayQuote = async (extraGas) => ppwRelayerQuote(
    quoteState.relayChainId,
    intent.withdrawnValue,
    quoteState.relayAssetAddr,
    intent.recipient,
    extraGas
  );

  // Fire assetConfig fetch in parallel with the relay quote — they're independent.
  // Use cached config for preview; only the submission path needs requireOnchain: true.
  const assetConfigPromise = ppEnsureAssetConfig(intent.wAsset, { requireOnchain: false });

  let quote;
  try {
    quote = await requestRelayQuote(quoteState.relayExtraGas);
  } catch (quoteErr) {
    const quoteErrMsg = quoteErr instanceof Error ? quoteErr.message : String(quoteErr || '');
    if (!quoteState.relayExtraGas || !quoteErrMsg.includes('UNSUPPORTED_FEATURE')) throw quoteErr;
    quote = await requestRelayQuote(false);
    quoteState.relayExtraGas = false;
    const extraGasEl = $('ppwExtraGas');
    if (extraGasEl) extraGasEl.checked = false;
    const fallbackMessage = 'Extra gas is not available for this quote. Continuing without it.';
    showStatus(fallbackMessage, '');
    if (run && typeof run.logHtml === 'function') {
      run.logHtml('<b>Warning:</b> ' + ppwEscapeStatusLogText(fallbackMessage));
    }
  }
  if (!quote || !quote.feeCommitment) throw new Error('Invalid quote response');
  const feeCommitment = quote.feeCommitment;
  const { recoveredSigner, expirationMs } = ppwValidateRelayQuoteCommitment(quoteState.relayChainId, feeCommitment);
  if (String(feeCommitment.asset || '').toLowerCase() !== quoteState.relayAssetAddr.toLowerCase()) {
    throw new Error('Relay quote asset mismatch.');
  }
  if (BigInt(feeCommitment.amount) !== intent.withdrawnValue) {
    throw new Error('Relay quote amount mismatch.');
  }
  if (!!feeCommitment.extraGas !== quoteState.relayExtraGas) {
    throw new Error('Relay quote extra-gas flag mismatch.');
  }

  const decoded = ppwDecodeRelayWithdrawalData(feeCommitment.withdrawalData);
  if (!decoded) {
    throw new Error('Could not decode relay withdrawalData.');
  }
  if (decoded.recipient.toLowerCase() !== intent.recipient.toLowerCase()) {
    throw new Error('Relay withdrawalData recipient mismatch: expected ' + intent.recipient.slice(0, 10) + '... but got ' + decoded.recipient.slice(0, 10) + '.... Aborting for safety.');
  }
  const decodedFeeBps = decoded.feeBps;
  const advertisedFeeBps = quote.feeBPS ?? quote.feeCommitment?.feeBPS;
  if (!Number.isFinite(decodedFeeBps) || decodedFeeBps < 0) {
    throw new Error('Invalid fee in relay withdrawalData.');
  }
  const allowedRelayerRecipients = ppwResolveAllowedRelayRecipients(quoteState.relayChainId, details, feeCommitment, recoveredSigner);
  if (!allowedRelayerRecipients.length) {
    throw new Error('Relayer details missing a verifiable fee recipient.');
  }
  const matchesAllowedRelayer = allowedRelayerRecipients.some((candidate) => decoded.relayer.toLowerCase() === candidate.toLowerCase());
  if (!matchesAllowedRelayer) {
    throw new Error('Relay withdrawalData relayer mismatch: expected one of ' + allowedRelayerRecipients.map((candidate) => candidate.slice(0, 10) + '...').join(', ') + ' but got ' + decoded.relayer.slice(0, 10) + '.... Aborting for safety.');
  }
  if (advertisedFeeBps != null && Number(advertisedFeeBps) !== decodedFeeBps) {
    throw new Error('Relay fee mismatch: advertised ' + advertisedFeeBps + ' bps but withdrawalData encodes ' + decodedFeeBps + ' bps. Aborting.');
  }

  const wConfig = await assetConfigPromise;
  if (!wConfig || wConfig.maxRelayFeeBPS == null) {
    throw new Error('Could not load onchain max relay fee for this asset. Aborting relay withdrawal for safety.');
  }
  const maxRelayFeeBpsNum = Number(wConfig.maxRelayFeeBPS);
  if (!Number.isFinite(maxRelayFeeBpsNum) || maxRelayFeeBpsNum < 0) {
    throw new Error('Invalid onchain max relay fee configuration.');
  }
  if (decodedFeeBps > maxRelayFeeBpsNum) {
    throw new Error('Relay fee (' + decodedFeeBps + ' bps) exceeds onchain max (' + maxRelayFeeBpsNum + ' bps). Try a larger withdrawal amount or disable Extra gas.');
  }

  const hasQuotedFeeBps = Number.isFinite(decodedFeeBps);
  quoteState.relayQuote = quote;
  quoteState.quotedFeeBPS = hasQuotedFeeBps ? decodedFeeBps : null;
  quoteState.details = details;

  let feeAmt = quote.feeCommitment?.fee || quote.fee;
  if (!feeAmt && hasQuotedFeeBps) feeAmt = (intent.withdrawnValue * BigInt(decodedFeeBps) / 10000n).toString();
  const feePctLabel = hasQuotedFeeBps ? ((decodedFeeBps / 100).toFixed(1) + '%') : '--';
  setText('ppwRelayFeeBps', feePctLabel);
  setText('ppwRelayFeeAmt', feeAmt ? fmt(ppFormatAmountWei(BigInt(feeAmt), intent.wAsset)) + ' ' + intent.wAsset : '--');
  if (feeAmt && intent.withdrawnValue) {
    const netReceived = intent.withdrawnValue - BigInt(feeAmt);
    setText('ppwRelayNetAmt', fmt(ppFormatAmountWei(netReceived > 0n ? netReceived : 0n, intent.wAsset)) + ' ' + intent.wAsset);
    const netRowEl = $('ppwRelayNetRow'); if (netRowEl) netRowEl.style.display = 'flex';
  } else {
    setShown('ppwRelayNetRow', false);
  }
  // Merge quote into the Withdrawal Preview instead of showing a separate panel
  setShown('ppwRelayFeePanel', false);
  ppwUpdatePreviewWithQuote(intent, feeAmt, feePctLabel, expirationMs);
  ppwStartExpiryCountdown(expirationMs);
  _ppwDisplayedRelayQuoteKey = ppwBuildRelayQuoteDisplayKey({
    show: true,
    asset: intent.wAsset,
    withdrawnValue: intent.withdrawnValue,
    previewRecipient: intent.resolvedRecipient,
    mode: intent.isRelayMode ? 'relay' : 'direct',
    extraGas: quoteState.relayExtraGas,
  }, intent.note);

  return quoteState;
}

async function ppwPrepareRelayQuote(intent, state, run) {
  const quoteState = ppwCreateRelayQuoteState(intent);
  if (!intent.isRelayMode) return quoteState;
  run.setProgressStage('fetchingRelayQuote', _ppwMode);
  run.log('Fetching relay quote...');
  try {
    await ppwRefreshRelayQuote(quoteState, intent, run, true);
  } catch (quoteErr) {
    console.warn('Privacy: relay quote failed', quoteErr);
    const detail = quoteErr?.message ? ': ' + String(quoteErr.message).slice(0, 120) : '';
    showStatus('Could not fetch relay quote' + detail + '. Please try again.', 'error');
    return null;
  }
  run.log('Relay quote received: fee=' + (quoteState.quotedFeeBPS ?? '?') + 'bps, expires=' + (quoteState.relayQuote?.feeCommitment?.expiration || '?'));
  return quoteState;
}

async function ppwRequestRelayQuoteReview() {
  if (_ppwMode !== 'relay' || _ppwDraftPhase === 'running') return null;
  const btn = $('ppwWithdrawBtn');
  _ppwReviewedRelayQuote = null;
  if (_ppwDraftPhase !== 'running') _ppwDraftPhase = 'editing';
  ppwResetRelayQuoteDisplay();
  const run = {
    log() {},
    setProgressStage() {},
    setButtonText(label) {
      if (btn) setText(btn, label);
    },
  };
  if (btn) {
    setDisabled(btn, true);
    setText(btn, 'Reviewing...');
  }
  try {
    const intent = await ppwCollectWithdrawalIntent(run);
    if (!intent) return null;
    const quoteState = await ppwPrepareRelayQuote(intent, null, run);
    if (!quoteState) return null;
    return ppwEnterRelayReviewState(ppwCreateReviewedRelayQuote(intent, quoteState));
  } finally {
    ppwSyncWithdrawActionState();
  }
}

async function ppwPrepareProofJob(intent, state, quoteState, run) {
  run.log('Preparing circuit inputs...');
  const isPartial = intent.withdrawnValue < intent.value;
  const changeValue = intent.value - intent.withdrawnValue;
  let mk;
  try {
    mk = await ppEnsureMasterKeys(intent.note.walletSeedVersion || null, {
      skipCompatibilityCheck: true,
      onProgress: (msg) => run.log(msg),
    });
  } catch (masterKeyErr) {
    if (masterKeyErr?.code === 'PP_WALLET_SEED_BACKUP_REQUIRED') {
      showStatus('Save your recovery phrase before continuing.', 'error');
      return null;
    }
    throw masterKeyErr;
  }
  const activeKeys = ppGetKeysetForDerivation(mk, intent.note.derivation);
  const idxResolution = ppResolveNextWithdrawalIndex(
    activeKeys.masterNullifier,
    intent.scope,
    intent.label,
    intent.note.nullifier,
    intent.note.withdrawalIndex,
    intent.note.depositIndex
  );
  if (idxResolution.nextIndex == null) {
    console.error('Privacy: loaded account is missing withdraw lineage metadata', {
      asset: intent.note?.asset,
      source: intent.note?.source,
      depositIndex: intent.note?.depositIndex,
      idxResolution,
    });
    showStatus('Could not prepare withdrawal. Refresh Pool Balances and try again.', 'error');
    return null;
  }
  const changeIdx = idxResolution.nextIndex;
  const changeKeys = ppDeriveWithdrawalKeys(activeKeys.masterNullifier, activeKeys.masterSecret, intent.label, changeIdx);
  if (idxResolution.source === 'note') {
    run.log('Using withdrawalIndex=' + idxResolution.currentIndex + ' → next change index=' + changeIdx + '.');
  } else if (idxResolution.source === 'inferred-withdrawal') {
    run.log('Inferred current withdrawal index=' + idxResolution.currentIndex + ' → next change index=' + changeIdx + '.');
  } else {
    run.log('Detected original deposit (deposit index=' + idxResolution.depositIndex + '). Using first change index=0.');
  }
  const assetUnit = intent.wAsset;
  if (isPartial) {
    run.log('Partial withdrawal: ' + fmt(ppFormatAmountWei(intent.withdrawnValue, intent.wAsset)) + ' ' + assetUnit + ' (change: ' + fmt(ppFormatAmountWei(changeValue, intent.wAsset)) + ' ' + assetUnit + ')');
  } else {
    run.log('Full withdrawal: reserving zero-value change commitment at index=' + changeIdx + '.');
  }

  const circuitInputsBase = {
    withdrawnValue: intent.withdrawnValue.toString(),
    stateRoot: state.stateTree.root.toString(),
    stateTreeDepth: '32',
    ASPRoot: state.aspTree.root.toString(),
    ASPTreeDepth: '32',
    label: intent.label.toString(),
    existingValue: intent.value.toString(),
    existingNullifier: intent.note.nullifier.toString(),
    existingSecret: intent.note.secret.toString(),
    newNullifier: changeKeys.nullifier.toString(),
    newSecret: changeKeys.secret.toString(),
    stateSiblings: state.stateSiblings.map(s => s.toString()),
    stateIndex: state.adjustedLeafIndex.toString(),
    ASPSiblings: state.aspSiblings.map(s => s.toString()),
    ASPIndex: state.aspIndex.toString()
  };

  let wasmUrl, zkeyUrl;
  run.setProgressStage('loadingArtifacts', _ppwMode);
  if (_ppArtifactCache) {
    run.log('Using cached proving artifacts.');
    wasmUrl = _ppArtifactCache.wasmUrl;
    zkeyUrl = _ppArtifactCache.zkeyUrl;
  } else {
    run.log('Downloading & verifying proving artifacts...');
    ({ wasmUrl, zkeyUrl } = await ppEnsureWithdrawArtifacts());
    run.log('Artifacts verified & cached.');
  }

  return {
    intent,
    state,
    quoteState,
    isPartial,
    changeValue,
    changeIdx,
    newNullifier: changeKeys.nullifier,
    newSecret: changeKeys.secret,
    assetUnit,
    circuitInputsBase,
    wasmUrl,
    zkeyUrl,
  };
}

function ppwBuildProofAttempt(job, quoteState) {
  let withdrawalProcessooor, withdrawalData;
  if (job.intent.isRelayMode) {
    withdrawalProcessooor = PP_ENTRYPOINT;
    withdrawalData = quoteState.relayQuote.feeCommitment.withdrawalData;
  } else {
    withdrawalProcessooor = job.intent.recipient;
    withdrawalData = '0x';
  }
  const encoded = ethers.AbiCoder.defaultAbiCoder().encode(
    ['tuple(address,bytes)', 'uint256'],
    [[withdrawalProcessooor, withdrawalData], job.intent.scope]
  );
  const context = BigInt(ethers.keccak256(encoded)) % SNARK_FIELD;
  return {
    withdrawalProcessooor,
    withdrawalData,
    context,
    circuitInputs: { ...job.circuitInputsBase, context: context.toString() },
  };
}

async function ppwGenerateAndVerifyProof(job, quoteState, run) {
  const proofAttempt = ppwBuildProofAttempt(job, quoteState);
  run.log('Generating ZK proof (30-120s proving)...');
  run.setProgressStage('generatingProof', _ppwMode);
  const { proof, publicSignals } = await ppRunWithdrawalProof(
    proofAttempt.circuitInputs,
    job.wasmUrl,
    job.zkeyUrl,
    ({ phase, progress, fallbackMessage }) => {
      if (fallbackMessage) run.log(fallbackMessage);
      run.setProgressStage('generatingProof', _ppwMode, {
        progress: ppMapProofProgress(phase, progress),
      });
    }
  );
  run.log('Proof generated!');

  if (job.intent.isRelayMode) {
    const expMs = Number(quoteState.relayQuote?.feeCommitment?.expiration || 0);
    if (expMs && Date.now() > expMs) {
      run.setProgressStage('fetchingRelayQuote', _ppwMode);
      run.log('Relay quote expired during proving. Fetching a fresh quote for review...');
      try {
        await ppwRefreshRelayQuote(quoteState, job.intent, run, false);
        ppwEnterRelayReviewState(ppwCreateReviewedRelayQuote(job.intent, quoteState));
      } catch (refreshErr) {
        console.warn('Privacy: relay quote refresh failed', refreshErr);
        showStatus('Relay quote refresh failed. Please retry withdrawal.', 'error');
        return null;
      }
      showStatus('Relay quote expired during proving. Review the refreshed quote and retry withdrawal.', 'error');
      return null;
    }
  }

  const { pA, pB, pC, pubSigs } = ppwConvertSnarkjsProof(proof, publicSignals);
  if (pubSigs.length !== 8) {
    showStatus('Unexpected proof output (invalid public signal length).', 'error');
    return null;
  }
  if (!ppwWithdrawalPublicSignalsMatch(job, proofAttempt, pubSigs)) {
    run.logHtml('<b>Error:</b> Withdrawal proof signals do not match the intended withdrawal parameters.');
    showStatus('Generated proof does not match the intended withdrawal. Refresh Pool Balances and retry.', 'error');
    return null;
  }
  run.log('Proof public signals match the intended withdrawal parameters.');

  run.setProgressStage('verifyingProof', _ppwMode);
  run.log('Verifying proof locally against pool verifier...');
  try {
    const isProofValid = await ppwVerifyProofOnchain(job.intent.poolAddress, pA, pB, pC, pubSigs);
    if (!isProofValid) {
      showStatus('Proof failed local verifier check. Retry withdrawal.', 'error');
      return null;
    }
    run.log('Local verifier check passed.');
  } catch (verifyErr) {
    const verifyMsg = String(verifyErr?.message || verifyErr || '');
    const verifyMsgLc = verifyMsg.toLowerCase();
    const likelyVerifierRevert = verifyMsgLc.includes('execution reverted')
      || verifyMsgLc.includes('revert')
      || verifyMsgLc.includes('call exception');
    console.warn('Privacy: local verifier check failed', verifyErr);
    if (likelyVerifierRevert) {
      run.logHtml('<b>Error:</b> Local verifier call reverted.');
      showStatus('Proof failed local verifier check. Retry withdrawal.', 'error');
      return null;
    }
    run.logHtml('<b>Warning:</b> Could not run local verifier check due to a network issue.');
    showStatus('Could not run local proof verification. Retry withdrawal when RPC connectivity is stable.', 'error');
    return null;
  }

  return {
    ...proofAttempt,
    proof,
    publicSignals,
    pA,
    pB,
    pC,
    pubSigs,
  };
}

async function ppwRevalidateBeforeSubmit(job, proofState, quoteState, run) {
  run.log('Re-checking onchain roots before submission...');
  const rootCheck = await ppEnsureWithdrawalRootsCurrent(job.intent.poolAddress, job.state.stateTree.root, job.state.aspTree.root);
  if (!rootCheck.ok) {
    run.logHtml('<b>Error:</b> ' + ppwEscapeStatusLogText(rootCheck.message));
    showStatus(rootCheck.message, 'error');
    return null;
  }
  run.log('Onchain roots still accept this withdrawal.');
  if (job.intent.isRelayMode && quoteState.relayQuote?.feeCommitment?.expiration && Date.now() > Number(quoteState.relayQuote.feeCommitment.expiration)) {
    run.setProgressStage('fetchingRelayQuote', _ppwMode);
    run.log('Relay quote expired before submission. Refreshing quote...');
    try {
      await ppwRefreshRelayQuote(quoteState, job.intent, run, false);
      ppwEnterRelayReviewState(ppwCreateReviewedRelayQuote(job.intent, quoteState));
    } catch (refreshErr) {
      console.warn('Privacy: relay quote refresh failed', refreshErr);
      showStatus('Relay quote refresh failed. Please retry withdrawal.', 'error');
      return null;
    }
    showStatus('Relay quote expired before submission. Review the refreshed quote and retry withdrawal.', 'error');
    return null;
  }
  return { ok: true };
}

async function ppwSubmitWithdrawal(job, proofState, quoteState, run) {
  if (job.intent.isRelayMode) {
    run.setProgressStage('submittingRelay', _ppwMode);
    run.log('Submitting to relayer...');
    run.setButtonText('Submitting to relayer...');
    let relayResult;
    try {
      relayResult = await ppwRelayerRequest(
        quoteState.relayChainId,
        job.intent.scope,
        { processooor: proofState.withdrawalProcessooor, data: proofState.withdrawalData },
        proofState.proof,
        proofState.publicSignals,
        quoteState.relayQuote.feeCommitment
      );
    } catch (relayErr) {
      console.warn('Privacy: relayer submission failed', relayErr);
      run.logHtml('<b>Relayer submission failed.</b> Your withdrawal was not submitted. Retry the relay flow in a few minutes.');
      showStatus('Relayer submission failed before submission. Your withdrawal was not submitted. Retry the relay flow in a few minutes.', 'error');
      return null;
    }
    const txHash = relayResult?.txHash || relayResult?.hash || relayResult?.transactionHash;
    if (!txHash) {
      console.warn('Privacy: relayer returned unexpected response format', relayResult);
      run.logHtml('<b>Relayer returned an unexpected response.</b> Your withdrawal was not submitted. Retry the relay flow.');
      showStatus('Relayer did not confirm submission. Your withdrawal was not submitted. Retry the relay flow.', 'error');
      return null;
    }
    run.log('Relayer accepted! Transaction: ' + escText(txHash));
    run.setButtonText('Waiting for confirmation...');
    run.setProgressStage('waitingConfirmation', _ppwMode);
    let receipt = null;
    for (let poll = 0; poll < 150; poll++) {
      receipt = await ppReadWithRpc((rpc) => rpc.getTransactionReceipt(txHash)).catch(() => null);
      if (receipt) break;
      await new Promise((resolve) => setTimeout(resolve, 2000));
    }
    return { txHash, receipt, relayResult };
  }

  run.setProgressStage('submittingDirect', _ppwMode);
  try {
    const currentAddr = await _signer.getAddress();
    if (currentAddr.toLowerCase() !== _connectedAddress.toLowerCase()) {
      showStatus('Wallet changed during withdrawal. Please reconnect and retry.', 'error');
      return null;
    }
  } catch {
    showStatus('Wallet disconnected. Please reconnect and retry.', 'error');
    return null;
  }
  run.log('Submitting withdrawal transaction...');
  const poolSigner = new ethers.Contract(job.intent.poolAddress, PP_POOL_ABI, _signer);
  const tx = await wcTransaction(
    poolSigner.withdraw([job.intent.recipient, proofState.withdrawalData], [proofState.pA, proofState.pB, proofState.pC, proofState.pubSigs]),
    'Confirm Privacy Pools withdrawal'
  );
  const txHash = tx.hash;
  run.log('Transaction submitted: ' + escText(txHash));
  run.setButtonText('Waiting for confirmation...');
  run.setProgressStage('waitingConfirmation', _ppwMode);
  const receipt = await waitForTx(tx, 300_000);
  return { txHash, receipt, tx };
}

async function ppwFinalizeWithdrawalSuccess(receipt, job, proofState, submission, run) {
  run.setProgressStage('complete', _ppwMode);
  run.logHtml('<b>Withdrawal confirmed!</b> ' + ppwEscapeStatusLogText(fmt(ppFormatAmountWei(job.intent.withdrawnValue, job.intent.wAsset))) + ' ' + ppwEscapeStatusLogText(job.assetUnit) + ' sent to ' + ppwEscapeStatusLogText(job.intent.recipient.slice(0, 10)) + '...' + (job.intent.isRelayMode ? ' (via relay)' : ' (direct, no privacy benefit)'));
  _ppwReviewedRelayQuote = null;
  ppwSetDraftInteractivity('editing');
  if (job.isPartial) {
    const newPrecom = poseidon2([job.newNullifier, job.newSecret]);
    const expectedChangeCommitment = poseidon3([job.changeValue, job.intent.label, newPrecom]);
    const { leafIndex: changeLeafIndex } = await ppwParseChangeLeafIndex(
      receipt,
      job.intent.poolAddress,
      expectedChangeCommitment,
      job.intent.scope
    );
    if (changeLeafIndex != null) {
      run.log('Resolved change leafIndex=' + changeLeafIndex + ' from receipt/API.');
    } else {
      run.log('Change commitment not yet indexed. Leaf index will be resolved on next load.');
    }
    const paLabel = _ppwSelectedAccountLabel || 'your Pool Account';
    run.logHtml('<b style="color:var(--green, #22c55e)">Partial withdrawal complete.</b> ' + ppwEscapeStatusLogText(fmt(ppFormatAmountWei(job.changeValue, job.intent.wAsset))) + ' ' + ppwEscapeStatusLogText(job.assetUnit) + ' remaining in ' + ppwEscapeStatusLogText(paLabel) + '.');
    const txLink = submission.txHash ? ' <a href="https://etherscan.io/tx/' + escAttr(submission.txHash) + '" target="_blank" rel="noopener" style="font-size:11px">view tx</a>' : '';
    $('ppwResultSummary').innerHTML = 'Withdrew ' + escText(fmt(ppFormatAmountWei(job.intent.withdrawnValue, job.intent.wAsset))) + ' ' + escText(job.assetUnit) + '. ' + escText(fmt(ppFormatAmountWei(job.changeValue, job.intent.wAsset))) + ' ' + escText(job.assetUnit) + ' remaining in ' + escText(paLabel) + '.' + txLink;
    setShown('ppwResult', true);
    setShown('ppwResultBackWrap', true);
  } else {
    const txLink = submission.txHash ? ' <a href="https://etherscan.io/tx/' + escAttr(submission.txHash) + '" target="_blank" rel="noopener" style="font-size:11px">view tx</a>' : '';
    $('ppwResultSummary').innerHTML = 'Withdrew ' + escText(fmt(ppFormatAmountWei(job.intent.withdrawnValue, job.intent.wAsset))) + ' ' + escText(job.assetUnit) + ' successfully.' + txLink;
    setShown('ppwResult', true);
    setShown('ppwResultBackWrap', true);
  }
  ppInvalidatePoolViewCaches(job.intent.wAsset);
  ppwScheduleMutationRefreshes();
  showStatus('Withdrawal successful!', 'success');
}

async function ppwPrepareRagequitJob(intent, run) {
  run.log('Preparing ragequit proof inputs...');
  run.setProgressStage('loadingArtifacts', 'direct');
  let wasmUrl, zkeyUrl;
  if (_ppCommitmentArtifactCache) {
    run.log('Using cached proving artifacts.');
    wasmUrl = _ppCommitmentArtifactCache.wasmUrl;
    zkeyUrl = _ppCommitmentArtifactCache.zkeyUrl;
  } else {
    run.log('Downloading & verifying ragequit artifacts...');
    ({ wasmUrl, zkeyUrl } = await ppEnsureCommitmentArtifacts());
    run.log('Artifacts verified & cached.');
  }
  const expectedCommitmentHash = poseidon3([intent.value, intent.label, intent.note.precommitment]);
  const expectedNullifierHash = poseidon1([intent.note.nullifier]);
  return {
    intent,
    assetUnit: intent.wAsset,
    wasmUrl,
    zkeyUrl,
    expectedPublicSignals: [
      expectedCommitmentHash,
      expectedNullifierHash,
      intent.value,
      intent.label,
    ],
    circuitInputs: {
      value: intent.value.toString(),
      label: intent.label.toString(),
      nullifier: intent.note.nullifier.toString(),
      secret: intent.note.secret.toString(),
    },
  };
}

function ppwWithdrawalPublicSignalsMatch(job, proofAttempt, pubSigs) {
  // Withdrawal circuit public signals per ProofLib.sol:
  //   [0] newCommitmentHash  [1] existingNullifierHash  [2] withdrawnValue
  //   [3] stateRoot          [4] stateTreeDepth         [5] ASPRoot
  //   [6] ASPTreeDepth       [7] context
  if (!Array.isArray(pubSigs) || pubSigs.length !== 8) return false;
  try {
    const expectedNullifierHash = poseidon1([job.intent.note.nullifier]);
    const newPrecommitment = poseidon2([job.newNullifier, job.newSecret]);
    const expectedNewCommitment = poseidon3([job.changeValue, job.intent.label, newPrecommitment]);
    const checks = [
      [0, expectedNewCommitment, 'newCommitmentHash'],
      [1, expectedNullifierHash, 'existingNullifierHash'],
      [2, job.intent.withdrawnValue, 'withdrawnValue'],
      [3, BigInt(job.circuitInputsBase.stateRoot), 'stateRoot'],
      [4, BigInt(job.circuitInputsBase.stateTreeDepth), 'stateTreeDepth'],
      [5, BigInt(job.circuitInputsBase.ASPRoot), 'ASPRoot'],
      [6, BigInt(job.circuitInputsBase.ASPTreeDepth), 'ASPTreeDepth'],
      [7, proofAttempt.context, 'context'],
    ];
    for (const [idx, expected, label] of checks) {
      if (BigInt(pubSigs[idx]) !== BigInt(expected)) {
        console.warn('Privacy: withdrawal public signal mismatch at index ' + idx + ' (' + label + '): expected ' + expected.toString().slice(0, 20) + '... got ' + pubSigs[idx].toString().slice(0, 20) + '...');
        return false;
      }
    }
    return true;
  } catch (err) {
    console.warn('Privacy: withdrawal public signal check error', err);
    return false;
  }
}

function ppwRagequitPublicSignalsMatch(job, pubSigs) {
  const expectedSignals = Array.isArray(job?.expectedPublicSignals) ? job.expectedPublicSignals : null;
  if (!expectedSignals || !Array.isArray(pubSigs) || pubSigs.length !== 4 || expectedSignals.length !== 4) return false;
  for (let i = 0; i < 4; i++) {
    if (BigInt(pubSigs[i]) !== BigInt(expectedSignals[i])) return false;
  }
  return true;
}

async function ppwGenerateAndVerifyRagequitProof(job, run) {
  run.log('Generating ZK proof (30-120s proving)...');
  run.setProgressStage('generatingProof', 'direct');
  const { proof, publicSignals } = await ppRunWithdrawalProof(
    job.circuitInputs,
    job.wasmUrl,
    job.zkeyUrl,
    ({ phase, progress, fallbackMessage }) => {
      if (fallbackMessage) run.log(fallbackMessage);
      run.setProgressStage('generatingProof', 'direct', {
        progress: ppMapProofProgress(phase, progress),
      });
    }
  );
  run.log('Proof generated!');

  const { pA, pB, pC, pubSigs } = ppwConvertSnarkjsProof(proof, publicSignals);
  if (pubSigs.length !== 4) {
    showStatus('Unexpected ragequit proof output (invalid public signal length).', 'error');
    return null;
  }
  if (!ppwRagequitPublicSignalsMatch(job, pubSigs)) {
    run.logHtml('<b>Error:</b> Ragequit proof signals do not match the selected Pool Account.');
    showStatus('Generated ragequit proof does not match the selected Pool Account. Refresh Pool Balances and retry.', 'error');
    return null;
  }
  run.log('Proof public signals match the selected Pool Account.');

  run.setProgressStage('verifyingProof', 'direct');
  run.log('Verifying ragequit proof locally against pool verifier...');
  try {
    const isProofValid = await ppwVerifyRagequitProofOnchain(job.intent.poolAddress, pA, pB, pC, pubSigs);
    if (!isProofValid) {
      showStatus('Proof failed local verifier check. Retry ragequit.', 'error');
      return null;
    }
    run.log('Local verifier check passed.');
  } catch (verifyErr) {
    const verifyMsg = String(verifyErr?.message || verifyErr || '').toLowerCase();
    const likelyVerifierRevert = verifyMsg.includes('execution reverted')
      || verifyMsg.includes('revert')
      || verifyMsg.includes('call exception');
    console.warn('Privacy: local ragequit verifier check failed', verifyErr);
    if (likelyVerifierRevert) {
      run.logHtml('<b>Error:</b> Local verifier call reverted.');
      showStatus('Proof failed local verifier check. Retry ragequit.', 'error');
      return null;
    }
    run.logHtml('<b>Warning:</b> Could not run local verifier check due to a network issue.');
    showStatus('Could not run local proof verification. Retry ragequit when RPC connectivity is stable.', 'error');
    return null;
  }

  return {
    proof,
    publicSignals,
    pA,
    pB,
    pC,
    pubSigs,
  };
}

async function ppwSubmitRagequit(job, proofState, run) {
  run.setProgressStage('submittingDirect', 'direct');
  try {
    const currentAddr = await _signer.getAddress();
    if (currentAddr.toLowerCase() !== _connectedAddress.toLowerCase()) {
      showStatus('Wallet changed during ragequit. Please reconnect and retry.', 'error');
      return null;
    }
  } catch {
    showStatus('Wallet disconnected. Please reconnect and retry.', 'error');
    return null;
  }
  run.log('Simulating ragequit transaction onchain...');
  try {
    await ppwSimulateRagequitOnchain(job.intent.poolAddress, proofState.pA, proofState.pB, proofState.pC, proofState.pubSigs);
    run.log('Preflight simulation passed.');
  } catch (simulateErr) {
    console.warn('Privacy: ragequit simulation failed', simulateErr);
    const decodedMessage = ppwDecodeWithdrawalError(simulateErr);
    if (decodedMessage) {
      run.logHtml('<b>Error:</b> ' + ppwEscapeStatusLogText(decodedMessage));
      showStatus(decodedMessage, 'error');
      return null;
    }
    run.logHtml('<b>Error:</b> Could not simulate ragequit onchain before wallet confirmation.');
    showStatus('Could not simulate ragequit onchain. Retry when RPC connectivity is stable.', 'error');
    return null;
  }
  run.log('Submitting ragequit transaction...');
  const poolSigner = new ethers.Contract(job.intent.poolAddress, PP_POOL_ABI, _signer);
  const tx = await wcTransaction(
    poolSigner.ragequit([proofState.pA, proofState.pB, proofState.pC, proofState.pubSigs]),
    'Confirm Privacy Pools ragequit'
  );
  const txHash = tx.hash;
  run.log('Transaction submitted: ' + escText(txHash));
  run.setButtonText('Waiting for confirmation...');
  run.setProgressStage('waitingConfirmation', 'direct');
  const receipt = await waitForTx(tx, 300_000);
  return { txHash, receipt, tx };
}

async function ppwFinalizeRagequitSuccess(receipt, job, submission, run) {
  run.setProgressStage('complete', 'direct');
  run.logHtml('<b>Ragequit confirmed!</b> ' + ppwEscapeStatusLogText(fmt(ppFormatAmountWei(job.intent.value, job.intent.wAsset))) + ' ' + ppwEscapeStatusLogText(job.assetUnit) + ' returned publicly to your deposit address.');
  _ppwReviewedRelayQuote = null;
  ppwSetDraftInteractivity('editing');
  const txLink = submission.txHash ? ' <a href="https://etherscan.io/tx/' + escAttr(submission.txHash) + '" target="_blank" rel="noopener" style="font-size:11px">view tx</a>' : '';
  $('ppwResultSummary').innerHTML = 'Ragequit ' + escText(fmt(ppFormatAmountWei(job.intent.value, job.intent.wAsset))) + ' ' + escText(job.assetUnit) + ' successfully.' + txLink;
  setShown('ppwResult', true);
  setShown('ppwResultBackWrap', true);
  ppInvalidatePoolViewCaches(job.intent.wAsset);
  ppwScheduleMutationRefreshes();
  showStatus('Ragequit successful!', 'success');
}

async function ppwRagequit() {
  const run = ppwCreateWithdrawRun();
  let ragequitSucceeded = false;
  try {
    run.reset();
    const intent = await ppwCollectWithdrawalIntent(run);
    if (!intent) return;
    try {
      const { isSpent, nullHash } = await ppwCheckNullifierUnspent(intent.poolAddress, intent.note.nullifier);
      if (isSpent) {
        showStatus('This Pool Account has already been spent onchain.', 'error');
        run.logHtml('<b>Already spent.</b> Nullifier hash 0x' + ppwEscapeStatusLogText(nullHash.toString(16).slice(0, 16)) + '... is marked as used.');
        return;
      }
      run.log('Nullifier not yet spent. Pool Account is valid for ragequit.');
    } catch (spentErr) {
      console.warn('Privacy: could not verify ragequit spent status', spentErr);
      run.logHtml('<b>Error:</b> Could not verify whether this Pool Account has already been spent.');
      showStatus('Could not verify whether this Pool Account has already been spent. Retry when RPC connectivity is stable.', 'error');
      return;
    }
    const job = await ppwPrepareRagequitJob(intent, run);
    if (!job) return;
    const proofState = await ppwGenerateAndVerifyRagequitProof(job, run);
    if (!proofState) return;
    const submission = await ppwSubmitRagequit(job, proofState, run);
    if (!submission) return;
    if (submission.receipt && submission.receipt.status === 1) {
      await ppwFinalizeRagequitSuccess(submission.receipt, job, submission, run);
      ragequitSucceeded = true;
      return;
    }
    ppwHandleWithdrawalFailure(submission, run);
  } catch (e) {
    ppwHandleWithdrawalFailure(e, run);
  } finally {
    run.stopIfNeeded(ragequitSucceeded, 'direct');
  }
}

async function ppwHandleWithdrawPrimaryAction() {
  if (_ppwDraftPhase === 'running') return;
  if (ppwIsRagequitAction()) {
    await ppwRagequit();
    return;
  }
  if (_ppwMode !== 'relay') {
    await ppwWithdraw();
    return;
  }
  if (_ppwDraftPhase !== 'review') {
    await ppwRequestRelayQuoteReview();
    return;
  }

  const previewState = ppwBuildPreviewState();
  const currentIntentKey = ppwBuildRelayQuoteDisplayKey(previewState);
  const reviewed = _ppwReviewedRelayQuote;
  const reviewedExpirationMs = Number(reviewed?.quoteState?.relayQuote?.feeCommitment?.expiration || 0);
  const hasValidReviewedQuote = !!reviewed?.intentKey
    && reviewed.intentKey === currentIntentKey
    && !!reviewed?.quoteState?.relayQuote
    && (!reviewedExpirationMs || Date.now() <= reviewedExpirationMs);

  if (!hasValidReviewedQuote) {
    const refreshed = await ppwRequestRelayQuoteReview();
    if (refreshed) showStatus('Review the refreshed quote and retry withdrawal.', 'error');
    return;
  }

  await ppwWithdraw({ reviewedRelayQuote: reviewed });
}

async function ppwWithdraw({ reviewedRelayQuote = _ppwReviewedRelayQuote } = {}) {
  const run = ppwCreateWithdrawRun();
  let withdrawalSucceeded = false;
  try {
    run.reset();
    const intent = await ppwCollectWithdrawalIntent(run);
    if (!intent) return;
    const state = await ppwLoadWithdrawalState(intent, run);
    if (!state) return;
    let quoteState;
    if (intent.isRelayMode) {
      const currentIntentKey = ppwBuildRelayQuoteDisplayKey(ppwBuildPreviewState(intent.note, 'relay', _connectedAddress), intent.note);
      if (!reviewedRelayQuote?.quoteState?.relayQuote || reviewedRelayQuote.intentKey !== currentIntentKey) {
        const refreshed = await ppwRequestRelayQuoteReview();
        if (refreshed) showStatus('Review the refreshed quote and retry withdrawal.', 'error');
        return;
      }
      quoteState = reviewedRelayQuote.quoteState;
    } else {
      quoteState = await ppwPrepareRelayQuote(intent, state, run);
    }
    if (!quoteState) return;
    const job = await ppwPrepareProofJob(intent, state, quoteState, run);
    if (!job) return;
    const proofState = await ppwGenerateAndVerifyProof(job, quoteState, run);
    if (!proofState) return;
    const submitReady = await ppwRevalidateBeforeSubmit(job, proofState, quoteState, run);
    if (!submitReady) return;
    const submission = await ppwSubmitWithdrawal(job, proofState, quoteState, run);
    if (!submission) return;
    if (submission.receipt && submission.receipt.status === 1) {
      await ppwFinalizeWithdrawalSuccess(submission.receipt, job, proofState, submission, run);
      withdrawalSucceeded = true;
      return;
    }
    ppwHandleWithdrawalFailure(submission, run);
  } catch (e) {
    ppwHandleWithdrawalFailure(e, run);
  } finally {
    run.stopIfNeeded(withdrawalSucceeded, _ppwMode);
  }
}

function ppDeepFreezeTestApiValue(value) {
  if (!value || (typeof value !== 'object' && typeof value !== 'function') || Object.isFrozen(value)) return value;
  Object.freeze(value);
  for (const child of Object.values(value)) ppDeepFreezeTestApiValue(child);
  return value;
}

// __PP_TEST_API__ is a gated test-only contract for the privacy suite.
// Runtime behavior must never depend on it.
function ppRegisterInternalTestApi() {
  if (globalThis.__PP_ENABLE_TEST_API__ !== true) return;
  globalThis.__PP_TEST_API__ = ppDeepFreezeTestApiValue({
    version: 12,
    constants: {
      allowedWalletConnectWallets: PP_ALLOWED_WALLETCONNECT_WALLETS.slice(),
      supportedAssets: PP_ASSETS.slice(),
      reviewStatus: { ...PP_REVIEW_STATUS },
      addresses: {
        entrypoint: PP_ENTRYPOINT,
        router: typeof ZROUTER_ADDRESS !== 'undefined' ? ZROUTER_ADDRESS : null,
        bold: typeof BOLD_ADDRESS !== 'undefined' ? BOLD_ADDRESS : null,
        wstETH: typeof WSTETH_ADDRESS !== 'undefined' ? WSTETH_ADDRESS : null,
      },
      proof: {
        snarkjsSrc: PP_SNARKJS_SRC,
        snarkjsIntegrity: PP_SNARKJS_INTEGRITY,
        withdrawWasm: PP_WITHDRAW_WASM,
        withdrawZkey: PP_WITHDRAW_ZKEY,
        commitmentWasm: PP_COMMITMENT_WASM,
        commitmentZkey: PP_COMMITMENT_ZKEY,
        aspApiBase: PP_ASP_API_BASE,
        aspFetchTimeoutMs: PP_ASP_FETCH_TIMEOUT_MS,
        withdrawFetchTimeoutMs: PP_WITHDRAW_FETCH_TIMEOUT_MS,
      },
      dom: {
        privacyTabId: 'privacyTab',
        loadResultsId: 'ppwLoadResults',
        activitySectionId: 'ppwActivitySection',
        draftHiddenSections: PPW_DRAFT_HIDDEN_SECTIONS.slice(),
        ragequitWarningId: 'ppwRagequitWarning',
        progressIds: ['ppwProgressWrap', 'ppwProgressBar', 'ppwProgressLabel', 'ppwProgressSub'],
      },
      messages: {
        relayQuoteRetryRequired: 'Review the refreshed quote and retry withdrawal.',
        withdrawalStopped: 'Withdrawal not completed.',
      },
    },
    hooks: {
      ppHandlePrivacyTabSelected,
      ppHandlePrivacyWalletConnected,
      ppHandlePrivacyWalletDisconnected,
    },
    shared: {
      ppHashHex,
      ppNormalizeReviewStatus,
      ppLoadedAccountLabelKey,
    },
    wallet: {
      ppNormalizeWalletName,
      ppGetWalletCompatibilityMessage,
      ppGetWalletCompatibilitySnapshot,
      ppResetWalletCompatibility,
      ppDetectWalletCompatibility,
      ppRefreshWalletCompatibility,
      ppEnsureWalletCompatibility,
      ppBuildWalletSeedTypedData,
      ppDeriveWalletSeedSignature,
      ppDeriveWalletSeedMnemonicFromSignature,
      ppDeriveWalletSeed,
      ppEnsureMasterKeySession,
      ppGetOrCreateMasterKeyStore,
      ppGetPreferredWalletSeedVersion,
      ppGetCachedMasterKeys,
      ppRequireWalletSeedBackupSaved,
      ppFinalizeDerivedMasterKeys,
      ppBuildWalletSeedVersionOrder,
      ppShouldRetryWalletSeedVersion,
      ppEnsureMasterKeys,
      ppContinueWalletSeedBackup,
      ppGetPendingWalletSeedBackup,
      ppClearPendingWalletSeedBackups,
      ppBuildWalletSeedBackupNoticeState,
      ppBuildButtonState,
      ppBuildWalletRetryButtonState,
      ppGetPrivacyActionAccessButtonState,
      ppGetLoadButtonState,
      ppGetActiveWalletSeedBackupKey: () => _ppActiveWalletSeedBackupKey,
    },
    load: {
      ppCompareLoadedAccounts,
      ppNormalizePendingDepositReservations,
      ppResolveReservedSafeDepositIndex,
      ppGetRecoveredSafeDepositIndex,
      ppTraceLoadedAccountChain,
      ppBuildDepositEventsMap,
      ppLoadCachedEventLogs,
      ppSaveCachedEventLogs,
      ppApplyLoadedAccountReviewStatuses,
      ppFetchDepositsByLabel,
      ppBuildLoadedPoolAccountsFromEvents,
      ppwReadActivityHistory,
      ppwWriteActivityHistory,
      ppwCreateLoadStateSnapshot,
      ppwRestoreLoadState,
      ppwInitializeLoadAttempt,
      ppwCreateEventLoader,
      ppwScanWalletSeedVersions,
      ppwApplySelectedLoadScan,
      ppwRenderResolvedLoadState,
      ppwHandleLoadDepositsError,
      ppwLoadDeposits,
      ppwGetLoadRuntimeState: () => ({
        loadAfterBackup: !!_ppwLoadAfterBackup,
        loadResults: Array.isArray(_ppwLoadResults) ? _ppwLoadResults.slice() : [],
        loadWarnings: Array.isArray(_ppwLoadWarnings) ? _ppwLoadWarnings.slice() : [],
        activityHistory: Array.isArray(_ppwActivityHistory) ? _ppwActivityHistory.slice() : [],
        hasResolvedLoadState: !!_ppwHasResolvedLoadState,
        actionKind: _ppwActionKind,
      }),
    },
    deposit: {
      ppBuildDepositCtaContext,
      ppShouldRequestDepositBalanceRefresh,
      ppGetDepositCtaState,
      ppRenderDepositCtaState,
      ppRequestDepositBalanceRefresh,
      ppRequestDepositEthBalanceRefresh,
      ppUpdateDepositCta,
      ppUpdateDepositBalanceDisplay,
      ppGetDepositFallbackGasReserve,
      ppEstimateNativeDepositGasReserve,
      ppEstimateErc20DepositGasReserve,
      ppEstimateZapGasReserve,
      ppBuildZapDepositPlan,
      ppGetDepositBalanceError,
      ppEnsurePoolAcceptsDeposits,
      ppSubmitZapDeposit,
      ppSubmitErc20Deposit,
      ppDeposit,
      ppSelectAsset,
      ppSetZap,
      ppEnsureAssetConfig,
    },
    withdrawal: {
      ppParseNonNegativeInt,
      ppInferWithdrawalNoteIndex,
      ppInferDepositNoteIndex,
      ppResolveNextWithdrawalIndex,
      leanIMTBuild,
      leanIMTProof,
      ppCreateTimedAbortContext,
      ppFetchTextWithIntegrity,
      ppCreateProofBootstrapError,
      ppEnsureVerifiedSnarkjsSource,
      ppEnsureVerifiedSnarkjsEngine,
      ppEnsureWithdrawalProgressWorkerBlobUrl,
      ppMapProofProgress,
      ppStartWithdrawalProofProgressReporter,
      ppRunWithdrawalProof,
      ppEnsureWithdrawArtifacts,
      ppEnsureCommitmentArtifacts,
      ppScheduleWithdrawPreload,
      ppwRelayerCommitmentDomain,
      ppwRelayerQuote,
      ppwRelayerRequest,
      ppwRecoverRelayerCommitmentSigner,
      ppwValidateRelayQuoteCommitment,
      ppwResolveAllowedRelayRecipients,
      ppwDecodeRelayWithdrawalData,
      ppEnsureWithdrawalRootsCurrent,
      ppwCanSubmitWithdrawalState,
      ppwCanSubmitWithdrawal,
      ppwSetActionKind,
      ppwSetMode,
      ppwGetDraftPhase,
      ppwHasReviewedRelayQuote,
      ppwIsRelayQuoteDisplayed,
      ppwBuildRelayQuoteDisplayKey,
      ppwResetRelayQuoteDisplay,
      ppwSyncRelayQuoteDisplay,
      ppwHandleDraftActionLink,
      ppwBuildPreviewState,
      ppwRenderPreviewState,
      ppwUpdatePreview,
      ppwSetDraftSectionsShown,
      ppwResetDraftState,
      ppwResetProgressState,
      ppwBuildProgressState,
      ppwSetProgressStage,
      ppwSetProgressStoppedState,
      ppwNormalizeNoteFields,
      ppwCreateWithdrawRun,
      ppwDecodeWithdrawalError,
      ppwHandleWithdrawalFailure,
      ppwCollectWithdrawalIntent,
      ppwLoadWithdrawalState,
      ppwCreateRelayQuoteState,
      ppwRefreshRelayQuote,
      ppwPrepareRelayQuote,
      ppwHandleWithdrawPrimaryAction,
      ppwRequestRelayQuoteReview,
      ppwEnterRelayReviewState,
      ppwExitRelayReviewState,
      ppwSetDraftInteractivity,
      ppwSyncWithdrawActionState,
      ppwPrepareProofJob,
      ppwBuildProofAttempt,
      ppwGenerateAndVerifyProof,
      ppwPrepareRagequitJob,
      ppwGenerateAndVerifyRagequitProof,
      ppwSimulateRagequitOnchain,
      ppwRevalidateBeforeSubmit,
      ppwSubmitWithdrawal,
      ppwFinalizeWithdrawalSuccess,
      ppwSubmitRagequit,
      ppwFinalizeRagequitSuccess,
      ppwVerifyRagequitProofOnchain,
      ppwRagequit,
      ppwWithdraw,
      ppwGetMode: () => _ppwMode,
      ppwGetActionKind: () => _ppwActionKind,
    },
    activity: {
      ppBuildActivityFromAccountRows,
      ppActivityFindWithdrawnAmount,
      ppActivityGetStatus,
      ppActivityGetStatusLabel,
      ppActivityGetStatusColor,
      ppResolveActivityTimestamps,
      ppGetTimeAgo,
      ppCompareActivity,
      ppwGetVisibleActivityRows,
      ppwScheduleActivityTimestampResolution,
      ppwReadActivityHistory,
      ppwWriteActivityHistory,
      ppwRenderActivity,
      ppwToggleActivityExpanded,
    },
  });
}

ppRegisterInternalTestApi();

// Test-only state patching — lives in the runtime so variable references
// stay co-located with their declarations. The harness discovers patchable
// keys from __ppTestPatchableKeys__ instead of maintaining a duplicate list.
if (globalThis.__PP_ENABLE_TEST_API__ === true) {
  const _patchSetters = {
    _ppMasterKeys: (v) => { _ppMasterKeys = v; },
    _ppWalletCompatibilityState: (v) => { _ppWalletCompatibilityState = v; },
    _ppPendingWalletSeedBackups: (v) => { _ppPendingWalletSeedBackups = v; },
    _ppActiveWalletSeedBackupKey: (v) => { _ppActiveWalletSeedBackupKey = v; },
    _ppwLoadAfterBackup: (v) => { _ppwLoadAfterBackup = v; },
    _ppwLoadAbort: (v) => { _ppwLoadAbort = v; },
    _ppwLoadResults: (v) => { _ppwLoadResults = v; },
    _ppwLoadWarnings: (v) => { _ppwLoadWarnings = v; },
    _ppwActivityHistory: (v) => { _ppwActivityHistory = v; },
    _ppwActivityExpanded: (v) => { _ppwActivityExpanded = v; },
    _ppwActivityResolveRequestId: (v) => { _ppwActivityResolveRequestId = v; },
    _ppwHasResolvedLoadState: (v) => { _ppwHasResolvedLoadState = v; },
    _ppwMode: (v) => { _ppwMode = v; },
    _ppwNote: (v) => { _ppwNote = v; },
    _ppwProgressValue: (v) => { _ppwProgressValue = v; },
    _ppSelectedAsset: (v) => { _ppSelectedAsset = v; },
    _ppZapMode: (v) => { _ppZapMode = v; },
    _ppConfig: (v) => { _ppConfig = v; },
    _ppConfigBold: (v) => { _ppConfigBold = v; },
    _ppConfigWstETH: (v) => { _ppConfigWstETH = v; },
    _ppBalanceRaw: (v) => { _ppBalanceRaw = v; },
    _ppZapEstimate: (v) => { _ppZapEstimate = v; },
    _ppDepositBalanceRefreshState: (v) => { _ppDepositBalanceRefreshState = v; },
    _ppDepositEthBalanceRefreshState: (v) => { _ppDepositEthBalanceRefreshState = v; },
    _ppwActionKind: (v) => { _ppwActionKind = v; },
  };
  globalThis.__ppTestPatchableKeys__ = Object.freeze(Object.keys(_patchSetters));
  globalThis.__ppTestApplyStatePatch__ = function(patch) {
    if (!patch || typeof patch !== 'object') return;
    for (const key of Object.keys(patch)) {
      const setter = _patchSetters[key];
      if (!setter) throw new Error('Unsupported privacy test statePatch key: ' + key);
      setter(patch[key]);
    }
  };
}

// ==================== PRIVACY POOLS RUNTIME END ====================
