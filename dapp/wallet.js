(function() {
'use strict';

const RPCS = [
  'https://ethereum.publicnode.com',
  'https://1rpc.io/eth',
  'https://eth.drpc.org',
  'https://eth.llamarpc.com'
];
const WEINS = '0x0000000000696760E15f265e828DB644A0c242EB';
const WEINS_ABI = ['function reverseResolve(address) view returns (string)'];
const WC_PROJECT_ID = '1e8390ef1c1d8a185e035912a1409749';

const _escMap = { '&': '&amp;', '<': '&lt;', '>': '&gt;' };
function _esc(s) { return String(s).replace(/[&<>]/g, m => _escMap[m]); }
function _escA(s) { return _esc(s).replace(/"/g, '&quot;').replace(/'/g, '&#39;'); }

// --- State ---
window._walletProvider = null;
window._signer = null;
window._connectedAddress = null;
window._isWalletConnect = false;
window._wcDeepLink = null;
window.eip6963Providers = new Map();

window._connectedWalletProvider = null;
let _walletConnectProvider = null;
let _isConnecting = false;
let _walletEventHandlers = null;
let _onConnectCallbacks = [];
let _onDisconnectCallbacks = [];
let _appName = 'zFi';

// --- EIP-6963 ---
window.addEventListener('eip6963:announceProvider', (event) => {
  try {
    const { info, provider } = event.detail || {};
    if (info?.uuid && provider) eip6963Providers.set(info.uuid, { info, provider });
  } catch (e) {}
});
window.dispatchEvent(new Event('eip6963:requestProvider'));

// --- Provider detection ---
function findProvider(checkFn) {
  if (window.ethereum?.providers?.length) {
    for (const p of window.ethereum.providers) { if (checkFn(p)) return p; }
  }
  if (window.ethereum && checkFn(window.ethereum)) return window.ethereum;
  return null;
}

const WALLET_CONFIG = {
  metamask: { name: 'MetaMask', icon: '🦊', detect: () => findProvider(p => p.isMetaMask), getProvider: () => findProvider(p => p.isMetaMask) },
  coinbase: { name: 'Coinbase', icon: '🔵', detect: () => findProvider(p => p.isCoinbaseWallet), getProvider: () => findProvider(p => p.isCoinbaseWallet) },
  rabby: { name: 'Rabby', icon: '🐰', detect: () => findProvider(p => p.isRabby), getProvider: () => findProvider(p => p.isRabby) },
  rainbow: { name: 'Rainbow', icon: '🌈', detect: () => findProvider(p => p.isRainbow), getProvider: () => findProvider(p => p.isRainbow) },
  walletconnect: { name: 'WalletConnect', icon: '📱' }
};

function detectWallets() {
  const detected = [];
  const seenNames = new Set();
  for (const [uuid, { info, provider }] of eip6963Providers.entries()) {
    const name = info?.name || 'Unknown';
    if (!seenNames.has(name.toLowerCase())) {
      const iconUrl = info.icon && (info.icon.startsWith('data:image/') || info.icon.startsWith('https://')) ? info.icon : null;
      const safeIconUrl = iconUrl ? iconUrl.replace(/[<>&"']/g, c => ({'<':'&lt;','>':'&gt;','&':'&amp;','"':'&quot;',"'":'&#39;'}[c])) : null;
      detected.push({ key: `eip6963_${uuid}`, name, icon: safeIconUrl ? `<img src="${safeIconUrl}" style="width:1.5rem;height:1.5rem;border-radius:4px;">` : '🔌', getProvider: () => provider });
      seenNames.add(name.toLowerCase());
    }
  }
  if (window.ethereum?.providers?.length) {
    for (let i = 0; i < window.ethereum.providers.length; i++) {
      const p = window.ethereum.providers[i];
      const name = p.isMetaMask ? 'MetaMask' : p.isCoinbaseWallet ? 'Coinbase' : p.isRabby ? 'Rabby' : p.isRainbow ? 'Rainbow' : null;
      if (name && !seenNames.has(name.toLowerCase())) { detected.push({ key: `provider_${i}`, name, icon: '🔗', getProvider: () => p }); seenNames.add(name.toLowerCase()); }
    }
  }
  for (const [key, config] of Object.entries(WALLET_CONFIG)) {
    if (key === 'walletconnect') continue;
    try { if (config.detect && config.detect() && !seenNames.has(config.name.toLowerCase())) { detected.push({ key, ...config }); seenNames.add(config.name.toLowerCase()); } } catch (e) {}
  }
  if (detected.length === 0 && window.ethereum) detected.push({ key: 'injected', name: 'Browser Wallet', icon: '🔗', getProvider: () => window.ethereum });
  const wcModule = globalThis['@walletconnect/ethereum-provider'];
  if (wcModule?.EthereumProvider) detected.push({ key: 'walletconnect', name: 'WalletConnect', icon: '📱' });
  return detected;
}

// --- DOM injection ---
function injectWalletDOM() {
  if (document.getElementById('walletBtn')) return;
  // Button
  const walletDiv = document.createElement('div');
  walletDiv.className = 'wallet';
  walletDiv.innerHTML = '<button id="walletBtn" onclick="toggleWallet()">connect</button>';
  document.body.appendChild(walletDiv);
  // Modal
  const overlay = document.createElement('div');
  overlay.className = 'wallet-modal-overlay';
  overlay.id = 'walletModal';
  overlay.onclick = function(e) { if (e.target === this) closeWalletModal(); };
  overlay.innerHTML = '<div class="wallet-modal"><div class="wallet-modal-header"><div class="wallet-modal-title">Connect Wallet</div><button class="wallet-modal-close" onclick="closeWalletModal()">&times;</button></div><div class="wallet-modal-body" id="walletOptions"></div></div>';
  document.body.appendChild(overlay);
}

// --- Modal ---
function showWalletModal() {
  document.getElementById('walletModal').classList.add('active');
  document.body.classList.add('modal-open');
  document.getElementById('walletOptions').innerHTML = '<div style="padding:12px;text-align:center;">Detecting wallets...</div>';
  window.dispatchEvent(new Event('eip6963:requestProvider'));
  const doDetect = (attempt = 1) => {
    const wallets = detectWallets();
    if (!wallets.some(w => w.key !== 'walletconnect') && attempt < 2) setTimeout(() => doDetect(attempt + 1), 250);
    else renderWalletModal(wallets);
  };
  setTimeout(() => doDetect(), 150);
}

function renderWalletModal(wallets) {
  const container = document.getElementById('walletOptions');
  if (_connectedAddress) {
    const displayName = document.getElementById('walletBtn').textContent;
    const showName = displayName && displayName !== 'connect' && !displayName.startsWith('0x');
    container.innerHTML = `<div style="padding:12px;border:1px solid currentColor;margin-bottom:12px;"><div style="font-weight:600;margin-bottom:6px;">Connected</div>${showName ? `<div style="font-size:16px;margin-bottom:4px;">${_esc(displayName)}</div>` : ''}<div style="font-size:12px;word-break:break-all;opacity:0.6;">${_esc(_connectedAddress)}</div></div><div class="wallet-option disconnect" onclick="disconnectWallet()"><span class="wallet-option-name">Disconnect</span></div>`;
  } else {
    container.innerHTML = wallets.length > 0 ? wallets.map(w => `<div class="wallet-option" data-wallet-key="${_escA(w.key)}"><span class="wallet-option-icon">${w.icon}</span><span class="wallet-option-name">${_esc(w.name)}</span></div>`).join('') : '<div style="padding:12px;text-align:center;">No wallets detected.</div>';
    container.querySelectorAll('[data-wallet-key]').forEach(el => { el.addEventListener('click', () => connectWithWallet(el.dataset.walletKey)); });
  }
}

window.closeWalletModal = function() {
  document.getElementById('walletModal').classList.remove('active');
  document.body.classList.remove('modal-open');
};

window.toggleWallet = function() { showWalletModal(); };
window.showWalletModal = showWalletModal;

// --- Connect ---
async function connectWithWallet(walletKey) {
  if (_isConnecting) return;
  _isConnecting = true;
  try {
    closeWalletModal();
    let walletProvider;
    if (walletKey === 'walletconnect') {
      const wcModule = globalThis['@walletconnect/ethereum-provider'];
      const WCProvider = wcModule?.EthereumProvider;
      if (!WCProvider?.init) throw new Error('WalletConnect not available');
      if (_walletConnectProvider) { try { await _walletConnectProvider.disconnect?.(); } catch (e) {} _walletConnectProvider = null; }
      _walletConnectProvider = await WCProvider.init({ projectId: WC_PROJECT_ID, chains: [1], showQrModal: true, rpcMap: { 1: 'https://1rpc.io/eth' }, metadata: { name: _appName, description: _appName, url: window.location.origin, icons: [] } });
      _walletConnectProvider.on('display_uri', () => { try { const s = _walletConnectProvider.session?.peer?.metadata; if (s?.redirect?.native && /^https?:\/\//i.test(s.redirect.native)) _wcDeepLink = s.redirect.native; else if (s?.redirect?.universal && /^https?:\/\//i.test(s.redirect.universal)) _wcDeepLink = s.redirect.universal; } catch (e) {} });
      await _walletConnectProvider.enable();
      walletProvider = _walletConnectProvider;
      _isWalletConnect = true;
      try { const s = _walletConnectProvider.session?.peer?.metadata; if (s?.redirect?.native && /^https?:\/\//i.test(s.redirect.native)) _wcDeepLink = s.redirect.native; else if (s?.redirect?.universal && /^https?:\/\//i.test(s.redirect.universal)) _wcDeepLink = s.redirect.universal; } catch (e) {}
    } else if (walletKey.startsWith('eip6963_')) {
      const uuid = walletKey.replace('eip6963_', '');
      walletProvider = eip6963Providers.get(uuid)?.provider;
      if (!walletProvider) { const savedName = localStorage.getItem('zfi_wallet_name')?.toLowerCase(); if (savedName) { for (const [, { info, provider }] of eip6963Providers) { if (info?.name?.toLowerCase() === savedName) { walletProvider = provider; break; } } } }
      _isWalletConnect = false; _wcDeepLink = null;
    } else {
      walletProvider = WALLET_CONFIG[walletKey]?.getProvider() || window.ethereum;
      _isWalletConnect = false; _wcDeepLink = null;
    }
    if (!walletProvider) throw new Error('Wallet not found');
    if (walletKey !== 'walletconnect') await walletProvider.request({ method: 'eth_requestAccounts' });
    const chainId = await walletProvider.request({ method: 'eth_chainId' });
    if (BigInt(chainId) !== 1n) {
      try { await walletProvider.request({ method: 'wallet_switchEthereumChain', params: [{ chainId: '0x1' }] }); const nc = await walletProvider.request({ method: 'eth_chainId' }); if (BigInt(nc) !== 1n) throw new Error('Chain switch failed'); }
      catch (switchErr) { console.error('Chain switch failed:', switchErr); document.getElementById('walletBtn').textContent = 'connect'; if (walletKey === 'walletconnect') { try { _walletConnectProvider?.disconnect(); } catch (e) {} _walletConnectProvider = null; } _isWalletConnect = false; _wcDeepLink = null; return; }
    }
    _walletProvider = new ethers.BrowserProvider(walletProvider);
    _signer = await _walletProvider.getSigner();
    _connectedAddress = await _signer.getAddress();
    const oldWP = _connectedWalletProvider;
    _connectedWalletProvider = walletProvider;
    document.getElementById('walletBtn').textContent = _connectedAddress.slice(0, 6) + '...' + _connectedAddress.slice(-4);
    document.getElementById('walletBtn').classList.add('connected');
    resolveWeiName(_connectedAddress);
    updateWcBanner();
    if (oldWP && _walletEventHandlers) { try { oldWP.removeListener('accountsChanged', _walletEventHandlers.accountsChanged); oldWP.removeListener('chainChanged', _walletEventHandlers.chainChanged); } catch (e) {} }
    _walletEventHandlers = { accountsChanged: () => window.location.reload(), chainChanged: () => window.location.reload() };
    walletProvider.on('accountsChanged', _walletEventHandlers.accountsChanged);
    walletProvider.on('chainChanged', _walletEventHandlers.chainChanged);
    try { localStorage.setItem('zfi_wallet', walletKey); if (walletKey.startsWith('eip6963_')) { const uuid = walletKey.replace('eip6963_', ''); const name = eip6963Providers.get(uuid)?.info?.name; if (name) localStorage.setItem('zfi_wallet_name', name); } } catch (e) {}
    for (const fn of _onConnectCallbacks) { try { fn(); } catch (e) { console.error('onConnect callback error:', e); } }
  } catch (error) {
    console.error('Wallet connect error:', error);
    document.getElementById('walletBtn').textContent = 'connect';
  } finally { _isConnecting = false; }
}

window.disconnectWallet = function() {
  if (_connectedWalletProvider && _walletEventHandlers) { try { _connectedWalletProvider.removeListener('accountsChanged', _walletEventHandlers.accountsChanged); _connectedWalletProvider.removeListener('chainChanged', _walletEventHandlers.chainChanged); } catch (e) {} }
  _walletEventHandlers = null;
  if (_walletConnectProvider) { try { _walletConnectProvider.disconnect(); } catch (e) {} _walletConnectProvider = null; }
  _walletProvider = null; _signer = null; _connectedAddress = null; _connectedWalletProvider = null; _isWalletConnect = false; _wcDeepLink = null;
  document.getElementById('walletBtn').textContent = 'connect';
  document.getElementById('walletBtn').classList.remove('connected');
  updateWcBanner();
  closeWalletModal();
  try { localStorage.removeItem('zfi_wallet'); localStorage.removeItem('zfi_wallet_name'); } catch (e) {}
  for (const fn of _onDisconnectCallbacks) { try { fn(); } catch (e) { console.error('onDisconnect callback error:', e); } }
};

window.connectWallet = async function() {
  if (_signer) return _signer;
  showWalletModal();
  return null;
};

function resolveWeiName(addr) {
  try {
    const rpc = new ethers.JsonRpcProvider(RPCS[0], 1, { staticNetwork: true });
    const ns = new ethers.Contract(WEINS, WEINS_ABI, rpc);
    ns.reverseResolve(addr).then(name => { if (name && _connectedAddress === addr) document.getElementById('walletBtn').textContent = name.toLowerCase(); }).catch(() => {});
  } catch (e) {}
}
window.resolveWeiName = resolveWeiName;

function updateWcBanner() {
  const existing = document.getElementById('wcBanner');
  if (existing) existing.remove();
  if (_isWalletConnect && _connectedAddress) {
    const banner = document.createElement('div');
    banner.id = 'wcBanner';
    banner.style.cssText = 'position:fixed;top:0;left:0;right:0;background:#1a1a2e;color:#fff;padding:10px 16px;display:flex;justify-content:space-between;align-items:center;z-index:9000;font-size:13px;';
    banner.innerHTML = '<span>📱 Connected via WalletConnect</span><button onclick="disconnectWallet()" style="background:#fff;color:#000;border:none;padding:6px 12px;border-radius:0;cursor:pointer;font-size:12px;">Disconnect</button>';
    document.body.prepend(banner);
    document.body.style.paddingTop = '54px';
  } else {
    document.body.style.paddingTop = '';
  }
}
window.updateWcBanner = updateWcBanner;

async function tryAutoConnect() {
  const savedWallet = localStorage.getItem('zfi_wallet');
  if (!savedWallet) return;
  document.getElementById('walletBtn').textContent = '...';
  setTimeout(async () => {
    try {
      window.dispatchEvent(new Event('eip6963:requestProvider'));
      await new Promise(r => setTimeout(r, 300));
      let probe;
      if (savedWallet.startsWith('eip6963_')) {
        const uuid = savedWallet.replace('eip6963_', '');
        probe = eip6963Providers.get(uuid)?.provider;
        if (!probe) {
          const savedName = localStorage.getItem('zfi_wallet_name')?.toLowerCase();
          if (savedName) {
            for (const [, { info, provider }] of eip6963Providers) {
              if (info?.name?.toLowerCase() === savedName) { probe = provider; break; }
            }
          }
        }
      } else if (savedWallet !== 'walletconnect') {
        probe = WALLET_CONFIG[savedWallet]?.getProvider() || window.ethereum;
      }
      if (probe) {
        const accts = await probe.request({ method: 'eth_accounts' });
        if (!accts || accts.length === 0) {
          document.getElementById('walletBtn').textContent = 'connect';
          return;
        }
      }
      await connectWithWallet(savedWallet);
    } catch (e) {
      console.error('Auto-reconnect failed:', e);
      document.getElementById('walletBtn').textContent = 'connect';
    }
  }, 100);
}

// --- Public init ---
window.walletInit = function(opts) {
  _appName = opts.appName || 'zFi';
  _onConnectCallbacks = Array.isArray(opts.onConnect) ? opts.onConnect : (opts.onConnect ? [opts.onConnect] : []);
  _onDisconnectCallbacks = Array.isArray(opts.onDisconnect) ? opts.onDisconnect : (opts.onDisconnect ? [opts.onDisconnect] : []);
  injectWalletDOM();
  tryAutoConnect();
};

})();
