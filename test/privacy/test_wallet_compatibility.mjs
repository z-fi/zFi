#!/usr/bin/env node
//
// Privacy wallet and My Pools journey tests.
//
// Exercises the live Privacy Pools wallet-compatibility, recovery-phrase,
// lifecycle-hook, and My Pools load seams through the gated runtime API.
//
// Usage: node test/privacy/test_wallet_compatibility.mjs
//
import { strict as assert } from 'node:assert';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';
import { createElement, createHarness as createPrivacyHarness, createTestRunner, flushMicrotasks } from './_app_source_utils.mjs';

const TEST_CONSOLE = { log() {}, warn() {}, error() {} };
const CONNECTED_ADDRESS = '0x1111111111111111111111111111111111111111';
const OTHER_ADDRESS = '0x2222222222222222222222222222222222222222';
const WALLET_JS_SOURCE = readFileSync(new URL('../../dapp/wallet.js', import.meta.url), 'utf8');

const { test, done } = createTestRunner();

function createStorageStub() {
  const store = new Map();
  return {
    getItem(key) {
      return store.has(key) ? store.get(key) : null;
    },
    setItem(key, value) {
      store.set(String(key), String(value));
    },
    removeItem(key) {
      store.delete(String(key));
    },
    clear() {
      store.clear();
    },
  };
}

function createClassListStub() {
  return {
    add() {},
    remove() {},
    contains() { return false; },
  };
}

function createWalletDomElement(initial = {}) {
  return {
    textContent: '',
    innerHTML: '',
    style: {},
    dataset: {},
    classList: createClassListStub(),
    addEventListener() {},
    removeEventListener() {},
    appendChild() {},
    prepend() {},
    remove() {},
    querySelector() { return null; },
    querySelectorAll() { return []; },
    ...initial,
  };
}

function loadWalletScript(context) {
  context.__WALLET_ENABLE_TEST_API__ = true;
  vm.createContext(context);
  vm.runInContext(WALLET_JS_SOURCE, context);
  const walletApi = context.__WALLET_TEST_API__;
  assert.ok(walletApi?.connectWithWallet, 'wallet test API exposes connectWithWallet');
  return walletApi;
}

function createWalletBridgeHarness({
  localStorage = createStorageStub(),
  walletName = 'Safe Wallet',
} = {}) {
  const walletBtn = createWalletDomElement();
  const walletModal = createWalletDomElement();
  const walletOptions = createWalletDomElement();
  const documentStub = {
    body: {
      style: {},
      classList: createClassListStub(),
      appendChild() {},
      prepend() {},
    },
    head: {
      appendChild() {},
    },
    createElement() {
      return createWalletDomElement();
    },
    getElementById(id) {
      if (id === 'walletBtn') return walletBtn;
      if (id === 'walletModal') return walletModal;
      if (id === 'walletOptions') return walletOptions;
      return null;
    },
  };
  const provider = {
    async request({ method }) {
      if (method === 'eth_requestAccounts') return [CONNECTED_ADDRESS];
      if (method === 'eth_chainId') return '0x1';
      if (method === 'wallet_getCapabilities') {
        return {
          '0x1': {
            atomic: { status: 'unsupported' },
          },
        };
      }
      return null;
    },
    on() {},
    removeListener() {},
  };
  const context = {
    console: TEST_CONSOLE,
    Map,
    Event: class {
      constructor(type, init = {}) {
        this.type = type;
        Object.assign(this, init);
      }
    },
    document: documentStub,
    localStorage,
    location: { origin: 'https://zfi.test' },
    setTimeout,
    clearTimeout,
    ethers: {
      BrowserProvider: class {
        constructor(walletProvider) {
          this.walletProvider = walletProvider;
        }

        async getSigner() {
          return {
            getAddress: async () => CONNECTED_ADDRESS,
          };
        }
      },
      JsonRpcProvider: class {},
      Contract: class {
        reverseResolve() {
          return Promise.reject(new Error('reverse resolve unavailable in wallet bridge tests'));
        }
      },
    },
    addEventListener() {},
    dispatchEvent() {},
  };
  context.window = context;
  context.globalThis = context;
  const walletApi = loadWalletScript(context);
  context.eip6963Providers.set('safe-demo', {
    info: { name: walletName },
    provider,
  });
  return {
    context,
    localStorage,
    walletBtn,
    connectWithWallet: walletApi.connectWithWallet,
    disconnectWallet: context.disconnectWallet,
  };
}

function createPendingBackup(address = CONNECTED_ADDRESS, version = 'v2', patch = {}) {
  const key = `${address.toLowerCase()}:${version}`;
  return {
    key,
    prompt: {
      address,
      version,
      phrase: 'test test test test test test test test test test test ball',
      derivedKeys: {
        safe: { masterNullifier: 11n, masterSecret: 22n },
        legacy: { masterNullifier: 33n, masterSecret: 44n },
      },
      downloaded: false,
      acknowledged: false,
      ...patch,
    },
  };
}

function createHarness({
  globals = {},
  statePatch = null,
  extraElements = {},
  localStorage = null,
} = {}) {
  return createPrivacyHarness({
    globals: {
      console: TEST_CONSOLE,
      _connectedAddress: CONNECTED_ADDRESS,
      _signer: { signTypedData: async () => '0x' },
      _connectedWalletProvider: null,
      _isWalletConnect: false,
      _ppwEventCache: {},
      _ppBlockTimestampCache: {},
      onCoinAddressInput() {},
      ppReadWithRpc: async (reader) => reader({ getCode: async () => '0x' }),
      ppUpdateDepositBalanceDisplay() {},
      ppUpdateDepositCta() {},
      ppRequestDepositBalanceRefresh() {},
      ppUpdateDescriptions() {},
      ppwUpdateLoadButton() {},
      ppwRenderIdleState() {},
      ppwSyncBackgroundRefreshLoop() {},
      ppwStopBackgroundRefreshLoop() {},
      ppwCloseWithdrawForm() {},
      ppTerminateProofWorker() {},
      ...globals,
    },
    localStorage,
    statePatch,
    baseElements: {
      privacyTab: createElement({ style: { display: '' } }),
      ppWalletSeedBackupNotice: createElement(),
      ppSwapWalletSeedBackupNotice: createElement(),
      ppWalletCompatDepositNotice: createElement(),
      ppWalletCompatNotice: createElement(),
      ppDepositBtn: createElement(),
      ppwLoadBtn: createElement(),
      ppwLoadDisconnected: createElement(),
      ppwLoadConnected: createElement(),
      ppwLoadResults: createElement(),
      ppwLoadRefresh: createElement(),
      ppwRefreshLink: createElement({ textContent: '\u21bb Refresh' }),
      ppwParsed: createElement(),
      ppwActivitySection: createElement(),
      ppwRecipient: createElement(),
      ppwWithdrawBtn: createElement(),
      ppBalance: createElement(),
    },
    extraElements,
  });
}

console.log('\n-- Wallet compatibility --');

test('walletconnect allowlist stays on the exported policy contract', () => {
  const { api } = createHarness();
  assert.deepEqual(
    [...api.constants.allowedWalletConnectWallets],
    ['metamask', 'rabby', 'rainbow', 'family'],
  );
});

test('non-allowlisted walletconnect wallets are blocked fail-closed', async () => {
  const harness = createHarness({
    globals: {
      _isWalletConnect: true,
      _connectedWalletProvider: { request: async () => ({}) },
    },
  });
  harness.context.localStorage.setItem('zfi_wallet', 'walletconnect');
  harness.context.localStorage.setItem('zfi_wallet_name', 'ledger live');

  const result = await harness.api.wallet.ppDetectWalletCompatibility();
  assert.equal(result.supported, false);
  assert.equal(result.kind, 'walletconnect_blocked');
  assert.equal(
    result.message,
    harness.api.wallet.ppGetWalletCompatibilityMessage('walletconnect_blocked'),
  );
});

test('coinbase wallet sessions stay blocked', async () => {
  const harness = createHarness({
    globals: {
      _connectedWalletProvider: { isCoinbaseWallet: true, request: async () => ({}) },
    },
  });

  const result = await harness.api.wallet.ppDetectWalletCompatibility();
  assert.equal(result.supported, false);
  assert.equal(result.kind, 'coinbase');
});

test('safe wallet sessions stay blocked across direct provider sessions', async () => {
  const harness = createHarness({
    globals: {
      _connectedWalletProvider: { request: async () => ({}) },
    },
  });
  harness.context.localStorage.setItem('zfi_wallet', 'eip6963_safe');
  harness.context.localStorage.setItem('zfi_wallet_name', 'safe wallet');

  const result = await harness.api.wallet.ppDetectWalletCompatibility();
  assert.equal(result.supported, false);
  assert.equal(result.kind, 'safe_wallet');
});

test('privacy wallet compatibility honors the wallet.js storage contract end to end', async () => {
  const sharedStorage = createStorageStub();
  const walletBridge = createWalletBridgeHarness({
    localStorage: sharedStorage,
    walletName: 'Safe Wallet',
  });

  await walletBridge.connectWithWallet('eip6963_safe-demo');

  assert.equal(sharedStorage.getItem('zfi_wallet'), 'eip6963_safe-demo');
  assert.equal(sharedStorage.getItem('zfi_wallet_name'), 'Safe Wallet');
  assert.equal(walletBridge.walletBtn.textContent, '0x1111...1111');

  const harness = createHarness({
    localStorage: sharedStorage,
    globals: {
      _connectedWalletProvider: { request: async () => ({}) },
    },
  });

  const result = await harness.api.wallet.ppDetectWalletCompatibility();
  assert.equal(result.supported, false);
  assert.equal(result.kind, 'safe_wallet');

  walletBridge.disconnectWallet();
  assert.equal(sharedStorage.getItem('zfi_wallet'), null);
  assert.equal(sharedStorage.getItem('zfi_wallet_name'), null);
});

test('7702 delegated EOAs are supported regardless of wallet', async () => {
  const harness = createHarness({
    globals: {
      ppReadWithRpc: async (fn) => {
        // Return EIP-7702 delegation designator
        return '0xef0100aabbccdd';
      },
    },
  });

  const result = await harness.api.wallet.ppDetectWalletCompatibility();
  assert.equal(result.supported, true);
  assert.equal(result.kind, 'eoa_7702');
  assert.equal(result.message, '');
});

test('wallet compatibility ignores provider capabilities for eoas', async () => {
  let requestCalls = 0;
  const harness = createHarness({
    globals: {
      _connectedWalletProvider: {
        request: async () => {
          requestCalls += 1;
          return {
            '0x1': {
              atomic: { status: 'supported' },
            },
          };
        },
      },
    },
  });
  harness.context.localStorage.setItem('zfi_wallet', 'rabby');
  harness.context.localStorage.setItem('zfi_wallet_name', 'rabby');

  const result = await harness.api.wallet.ppDetectWalletCompatibility();
  assert.equal(result.supported, true);
  assert.equal(result.kind, 'eoa');
  assert.equal(result.message, '');
  assert.equal(requestCalls, 0);
});

test('wallet compatibility ignores provider capabilities when bytecode marks smart wallets', async () => {
  let requestCalls = 0;
  const harness = createHarness({
    globals: {
      _connectedWalletProvider: {
        request: async () => {
          requestCalls += 1;
          return {
            '0x1': {
              atomic: { status: 'supported' },
            },
          };
        },
      },
      ppReadWithRpc: async (reader) => reader({ getCode: async () => '0x1234' }),
    },
  });
  harness.context.localStorage.setItem('zfi_wallet', 'rabby');
  harness.context.localStorage.setItem('zfi_wallet_name', 'rabby');

  const result = await harness.api.wallet.ppDetectWalletCompatibility();
  assert.equal(result.supported, false);
  assert.equal(result.kind, 'smart_wallet');
  assert.equal(requestCalls, 0);
});

test('bytecode RPC failure blocks the wallet compatibility check fail-closed', async () => {
  const harness = createHarness({
    globals: {
      _connectedWalletProvider: {
        request: async () => ({ '0x1': { atomic: { status: 'unsupported' } } }),
      },
      ppReadWithRpc: async () => {
        throw new Error('rpc unavailable');
      },
    },
  });

  const result = await harness.api.wallet.ppRefreshWalletCompatibility(true);
  assert.equal(result.supported, false);
  assert.equal(result.kind, 'check_failed');
  assert.equal(
    result.message,
    harness.api.wallet.ppGetWalletCompatibilityMessage('check_failed'),
  );
});

console.log('\n-- Recovery phrase --');

test('backup notice state enables continue after download or explicit acknowledgement', () => {
  const harness = createHarness();
  const initial = harness.api.wallet.ppBuildWalletSeedBackupNoticeState(
    createPendingBackup().prompt,
    CONNECTED_ADDRESS,
  );
  assert.equal(initial.show, true);
  assert.equal(initial.canContinue, false);
  assert.equal(initial.downloadLabel, 'Download Recovery Phrase');
  assert.equal(initial.acknowledgementLabel, 'I\'ve already downloaded or saved this Recovery Phrase');

  const downloaded = harness.api.wallet.ppBuildWalletSeedBackupNoticeState(
    createPendingBackup(CONNECTED_ADDRESS, 'v2', { downloaded: true }).prompt,
    CONNECTED_ADDRESS,
  );
  assert.equal(downloaded.canContinue, true);
  assert.equal(downloaded.downloadLabel, 'Recovery Phrase Downloaded');

  const acknowledged = harness.api.wallet.ppBuildWalletSeedBackupNoticeState(
    createPendingBackup(CONNECTED_ADDRESS, 'v2', { acknowledged: true }).prompt,
    CONNECTED_ADDRESS,
  );
  assert.equal(acknowledged.canContinue, true);
});

test('backup notice leaves the acknowledgement checkbox available before download', () => {
  const pending = createPendingBackup();
  const harness = createHarness({
    statePatch: {
      _ppPendingWalletSeedBackups: { [pending.key]: pending.prompt },
      _ppActiveWalletSeedBackupKey: pending.key,
    },
  });

  harness.context.ppRenderWalletSeedBackupNotice();
  assert.doesNotMatch(harness.elements.ppWalletSeedBackupNotice.innerHTML, /type="checkbox"[^>]*disabled/);
});

test('require backup saved reactivates the prompt and throws the expected error', () => {
  const pending = createPendingBackup();
  const harness = createHarness({
    statePatch: {
      _ppPendingWalletSeedBackups: { [pending.key]: pending.prompt },
      _ppActiveWalletSeedBackupKey: null,
    },
  });

  assert.throws(
    () => harness.api.wallet.ppRequireWalletSeedBackupSaved(CONNECTED_ADDRESS, 'v2'),
    /Save your recovery phrase before continuing\./,
  );
  assert.equal(harness.api.wallet.ppGetActiveWalletSeedBackupKey(), pending.key);
});

test('persisted recovery backups accept explicit acknowledgement for later sessions', () => {
  const harness = createHarness();
  const masterKeyStore = { address: CONNECTED_ADDRESS, activeVersion: null, versions: {} };
  const mnemonic = harness.context.ethers.Mnemonic.fromPhrase(
    'test test test test test test test test test test test ball',
  );
  harness.context.localStorage.setItem(
    'zfi_pp_wallet_seed_backups_v1',
    JSON.stringify({
      [`${CONNECTED_ADDRESS.toLowerCase()}:v2`]: {
        downloaded: false,
        acknowledged: true,
      },
    }),
  );

  const derived = harness.api.wallet.ppFinalizeDerivedMasterKeys(masterKeyStore, CONNECTED_ADDRESS, 'v2', mnemonic);
  assert.equal(derived.address, CONNECTED_ADDRESS);
  assert.equal(derived.walletSeedVersion, 'v2');
  assert.equal(harness.api.wallet.ppGetPendingWalletSeedBackup(CONNECTED_ADDRESS), null);
});

test('continue backup stores derived keys and resumes My Pools when flagged', async () => {
  let loadCalls = 0;
  const pending = createPendingBackup(CONNECTED_ADDRESS, 'v2', {
    downloaded: true,
  });
  const harness = createHarness({
    globals: {
      ppwLoadDeposits() {
        loadCalls += 1;
      },
    },
    statePatch: {
      _ppPendingWalletSeedBackups: { [pending.key]: pending.prompt },
      _ppActiveWalletSeedBackupKey: pending.key,
      _ppwLoadAfterBackup: true,
    },
  });

  await harness.api.wallet.ppContinueWalletSeedBackup();

  const loadState = harness.api.load.ppwGetLoadRuntimeState();
  const cachedKeys = harness.api.wallet.ppGetCachedMasterKeys(undefined, CONNECTED_ADDRESS, 'v2');
  assert.equal(loadState.loadAfterBackup, false);
  assert.equal(loadCalls, 1);
  assert.equal(cachedKeys.address, CONNECTED_ADDRESS);
  assert.equal(cachedKeys.walletSeedVersion, 'v2');
  assert.equal(harness.api.wallet.ppGetPendingWalletSeedBackup(CONNECTED_ADDRESS), null);
});

test('acknowledging before download unlocks the convenience backup flow', async () => {
  const pending = createPendingBackup();
  const harness = createHarness({
    statePatch: {
      _ppPendingWalletSeedBackups: { [pending.key]: pending.prompt },
      _ppActiveWalletSeedBackupKey: pending.key,
    },
  });

  harness.context.ppAcknowledgeAndContinueBackup(true);
  assert.equal(harness.api.wallet.ppGetPendingWalletSeedBackup(CONNECTED_ADDRESS), null);
  const cachedKeys = harness.api.wallet.ppGetCachedMasterKeys(undefined, CONNECTED_ADDRESS, 'v2');
  assert.equal(cachedKeys.address, CONNECTED_ADDRESS);
  assert.equal(cachedKeys.walletSeedVersion, 'v2');
  const registry = JSON.parse(harness.context.localStorage.getItem('zfi_pp_wallet_seed_backups_v1'));
  assert.equal(registry[`${CONNECTED_ADDRESS.toLowerCase()}:v2`].acknowledged, true);
  assert.equal(registry[`${CONNECTED_ADDRESS.toLowerCase()}:v2`].downloaded, false);
  assert.equal(harness.lastStatus?.message, 'Recovery phrase saved.');
});

test('wallet-compatibility renderer escapes untrusted messages with the live runtime helpers', () => {
  const harness = createHarness();

  harness.context.ppRenderWalletCompatibilityNotice({
    supported: false,
    kind: 'smart_wallet',
    message: '<img src=x onerror=alert(1)>',
  });

  assert.match(
    harness.elements.ppWalletCompatNotice.innerHTML,
    /&lt;img src=x onerror=alert\(1\)&gt;/,
  );
});

test('disconnect cleanup clears recovery prompts and load resume state', () => {
  const pending = createPendingBackup();
  const harness = createHarness({
    statePatch: {
      _ppPendingWalletSeedBackups: { [pending.key]: pending.prompt },
      _ppActiveWalletSeedBackupKey: pending.key,
      _ppwLoadAfterBackup: true,
      _ppwLoadResults: [{ asset: 'ETH' }],
      _ppwLoadWarnings: [{ asset: 'BOLD' }],
      _ppwActivityHistory: [{ action: 'Deposit' }],
    },
  });

  harness.api.hooks.ppHandlePrivacyWalletDisconnected();

  const loadState = harness.api.load.ppwGetLoadRuntimeState();
  assert.equal(harness.api.wallet.ppGetPendingWalletSeedBackup(CONNECTED_ADDRESS), null);
  assert.equal(harness.api.wallet.ppGetActiveWalletSeedBackupKey(), null);
  assert.equal(loadState.loadAfterBackup, false);
  assert.equal(loadState.loadResults.length, 0);
  assert.equal(loadState.loadWarnings.length, 0);
  assert.equal(loadState.activityHistory.length, 0);
});

console.log('\n-- Lifecycle hooks --');

test('wallet connected hook refreshes privacy surfaces only when the tab is visible', () => {
  const calls = [];
  const harness = createHarness({
    globals: {
      ppRefreshWalletCompatibility() { calls.push('compat'); },
      ppUpdateDepositCta() { calls.push('deposit-cta'); },
      ppUpdateDescriptions(connected) { calls.push(`descriptions:${connected}`); },
      ppwUpdateLoadButton() { calls.push('load-btn'); },
      ppwRenderIdleState() { calls.push('idle'); },
      ppwSyncBackgroundRefreshLoop() { calls.push('bg'); },
    },
  });

  harness.api.hooks.ppHandlePrivacyWalletConnected();
  for (const label of ['compat', 'deposit-cta', 'descriptions:true', 'load-btn', 'idle', 'bg']) {
    assert(calls.includes(label), `missing connected-hook call: ${label}`);
  }
  assert(calls.indexOf('compat') < calls.lastIndexOf('deposit-cta'));

  calls.length = 0;
  harness.elements.privacyTab.style.display = 'none';
  harness.api.hooks.ppHandlePrivacyWalletConnected();
  assert(calls.includes('descriptions:true'));
  assert(calls.includes('load-btn'));
  assert(calls.includes('bg'));
  assert(calls.includes('deposit-cta'), 'backup notice should still rerender the deposit CTA');
  assert(!calls.includes('compat'));
});

test('privacy tab hook remains the supported runtime seam for PP refreshes', () => {
  const calls = [];
  const harness = createHarness({
    globals: {
      loadPPConfig() { calls.push('config'); },
      ppRefreshWalletCompatibility() { calls.push('compat'); },
      ppUpdateDepositCta() { calls.push('deposit-cta'); },
      ppwUpdateLoadButton() { calls.push('load-btn'); },
      ppwRenderIdleState() { calls.push('idle'); },
    },
  });

  harness.api.hooks.ppHandlePrivacyTabSelected();
  assert.deepEqual(calls, [
    'config',
    'compat',
    'deposit-cta',
    'load-btn',
    'idle',
  ]);
});

console.log('\n-- My Pools load journey --');

test('load button state reflects backup-required and unsupported-wallet gates', () => {
  const pending = createPendingBackup();
  const harness = createHarness({
    statePatch: {
      _ppPendingWalletSeedBackups: { [pending.key]: pending.prompt },
      _ppActiveWalletSeedBackupKey: pending.key,
    },
  });

  const backupState = harness.api.wallet.ppGetLoadButtonState({
    status: 'ready',
    result: { supported: true, kind: 'eoa' },
  });
  assert.equal(backupState.button.label, 'Save recovery phrase to continue');
  assert.equal(backupState.button.disabled, true);

  const blockedState = harness.api.wallet.ppGetLoadButtonState({
    status: 'ready',
    result: { supported: false, kind: 'safe_wallet' },
  });
  assert.equal(blockedState.button.label, 'Wallet not supported');
  assert.equal(blockedState.button.disabled, true);
});

test('load deposits blocks unsupported wallets with the rendered notice', async () => {
  const harness = createHarness();
  harness.context.ppRefreshWalletCompatibility = async () => ({
    supported: false,
    kind: 'walletconnect_blocked',
    message: 'Wallet not supported for Privacy Pools.',
  });
  harness.context.ppwSyncBackgroundRefreshLoop = () => {};

  await harness.api.load.ppwLoadDeposits();

  assert.match(harness.elements.ppwLoadResults.innerHTML, /Wallet not supported for Privacy Pools\./);
  assert.equal(harness.elements.ppwLoadResults.style.display, '');
});

test('load error handler restores the snapshot and flags resume after backup', () => {
  const harness = createHarness({
    globals: {
      ppwRenderPoolAccounts() {},
      ppwRenderActivity() {},
      ppwRenderIdleState() {},
    },
  });
  const snapshot = {
    previousLoadResults: [{ asset: 'ETH', value: '1' }],
    previousLoadWarnings: [{ asset: 'BOLD', usedCachedData: true }],
    previousActivityHistory: [{ action: 'Deposit' }],
  };

  const showRefresh = harness.api.load.ppwHandleLoadDepositsError(
    Object.assign(new Error('backup required'), { code: 'PP_WALLET_SEED_BACKUP_REQUIRED' }),
    snapshot,
  );

  assert.equal(showRefresh, false);
  const loadState = harness.api.load.ppwGetLoadRuntimeState();
  assert.equal(loadState.loadAfterBackup, true);
  assert.deepEqual(loadState.loadResults, snapshot.previousLoadResults);
  assert.deepEqual(loadState.loadWarnings, snapshot.previousLoadWarnings);
  assert.deepEqual(loadState.activityHistory, snapshot.previousActivityHistory);
  assert.equal(harness.lastStatus?.message, 'Save your recovery phrase before viewing your pool balances.');
});

test('wallet-seed scanning falls back only after a clean empty scan', async () => {
  const harness = createHarness();
  const ensureCalls = [];
  const scanCalls = [];
  const events = [{ asset: 'ETH', depositLogs: [], withdrawnLogs: [], ragequitLogs: [], leafLogs: [], loadWarning: null }];
  harness.context.ppEnsureMasterKeys = async (version) => {
    ensureCalls.push(version);
    return { version };
  };
  harness.context.ppBuildLoadedPoolAccountsFromEvents = async (_events, keys) => {
    scanCalls.push(keys.version);
    if (keys.version === 'v2') return { results: [], warnings: [], activity: [] };
    return { results: [{ asset: 'ETH', txHash: '0xdep' }], warnings: [], activity: [] };
  };

  const result = await harness.api.load.ppwScanWalletSeedVersions(
    ['v2', 'v1'],
    async () => events,
    harness.elements.ppwRefreshLink,
    null,
  );

  assert.deepEqual(ensureCalls, ['v2', 'v1']);
  assert.deepEqual(scanCalls, ['v2', 'v1']);
  assert.equal(result.selectedWalletSeedVersion, 'v1');
  assert.equal(result.usedFallbackWalletSeedVersion, true);
  assert.equal(result.selectedScan.results.length, 1);
});

test('resolved load state renders immediately and refreshes timestamps when activity exists', async () => {
  const calls = [];
  const harness = createHarness({
    statePatch: {
      _ppwActivityHistory: [{ action: 'Deposit', timestamp: null, blockNumber: 100 }],
    },
  });
  harness.context.ppwRenderPoolAccounts = () => { calls.push('render-pools'); };
  harness.context.ppwRenderActivity = () => { calls.push('render-activity'); };
  harness.context.ppResolveActivityTimestamps = async () => { calls.push('resolve-timestamps'); };

  harness.api.load.ppwRenderResolvedLoadState();
  await flushMicrotasks();

  assert.deepEqual(calls, [
    'render-pools',
    'render-activity',
    'resolve-timestamps',
    'render-activity',
  ]);
});

// ---- Account/chain change event handler tests ----

function createWalletEventHarness({
  connectedAddress = CONNECTED_ADDRESS,
  switchedAddress = OTHER_ADDRESS,
} = {}) {
  const localStorage = createStorageStub();
  const timers = createTimerController();
  const walletBtn = createWalletDomElement();
  const walletModal = createWalletDomElement();
  const walletOptions = createWalletDomElement();
  const documentStub = {
    body: { style: {}, classList: createClassListStub(), appendChild() {}, prepend() {} },
    head: { appendChild() {} },
    createElement() { return createWalletDomElement(); },
    getElementById(id) {
      if (id === 'walletBtn') return walletBtn;
      if (id === 'walletModal') return walletModal;
      if (id === 'walletOptions') return walletOptions;
      return null;
    },
  };
  const eventHandlers = {};
  let currentAddress = connectedAddress;
  let providerAccounts = currentAddress ? [currentAddress] : [];
  const provider = {
    async request({ method }) {
      if (method === 'eth_requestAccounts') return providerAccounts;
      if (method === 'eth_accounts') return providerAccounts;
      if (method === 'eth_chainId') return '0x1';
      if (method === 'wallet_getCapabilities') return {};
      return null;
    },
    on(event, handler) { eventHandlers[event] = handler; },
    removeListener() {},
  };
  const context = {
    console: TEST_CONSOLE,
    Map,
    Event: class { constructor(type) { this.type = type; } },
    document: documentStub,
    localStorage,
    location: { origin: 'https://zfi.test', reload() {} },
    setTimeout: timers.setTimeout.bind(timers),
    clearTimeout: timers.clearTimeout.bind(timers),
    ethers: {
      BrowserProvider: class {
        constructor() {}
        async getSigner() {
          return { getAddress: async () => currentAddress };
        }
      },
      JsonRpcProvider: class {},
      Contract: class {
        reverseResolve() { return Promise.reject(new Error('stub')); }
      },
    },
    addEventListener() {},
    dispatchEvent() {},
  };
  context.window = context;
  context.globalThis = context;
  const walletApi = loadWalletScript(context);
  context.eip6963Providers.set('test-wallet', {
    info: { name: 'Test Wallet' },
    provider,
  });

  return {
    context,
    walletBtn,
    eventHandlers,
    provider,
    timers,
    switchAddress(addr) {
      currentAddress = addr;
      providerAccounts = currentAddress ? [currentAddress] : [];
    },
    setProviderAccounts(accounts) {
      providerAccounts = [...accounts];
    },
    async connect() {
      await walletApi.connectWithWallet('eip6963_test-wallet');
    },
  };
}

function createTimerController() {
  const queue = [];
  return {
    setTimeout(fn) {
      queue.push(fn);
      return queue.length;
    },
    clearTimeout() {},
    async flushNext() {
      const fn = queue.shift();
      if (!fn) return false;
      fn();
      await flushMicrotasks();
      return true;
    },
    async flushAll() {
      while (await this.flushNext()) {}
    },
  };
}

function createWalletConnectAutoConnectHarness() {
  const localStorage = createStorageStub();
  const timers = createTimerController();
  const walletBtn = createWalletDomElement();
  const walletModal = createWalletDomElement();
  const walletOptions = createWalletDomElement();
  let initCalls = 0;
  const providers = [];

  function createWalletConnectProvider() {
    const provider = {
      session: {
        connected: true,
        peer: { metadata: { name: 'MetaMask' } },
      },
      disconnectCalls: 0,
      async enable() {
        return [CONNECTED_ADDRESS];
      },
      async request({ method }) {
        if (method === 'eth_chainId') return '0x1';
        if (method === 'wallet_getCapabilities') return {};
        return null;
      },
      on() {},
      removeListener() {},
      async disconnect() {
        this.disconnectCalls += 1;
        this.session.connected = false;
      },
    };
    providers.push(provider);
    return provider;
  }

  const documentStub = {
    body: {
      style: {},
      classList: createClassListStub(),
      appendChild() {},
      prepend() {},
    },
    head: {
      appendChild() {},
    },
    createElement() {
      return createWalletDomElement();
    },
    getElementById(id) {
      if (id === 'walletBtn') return walletBtn;
      if (id === 'walletModal') return walletModal;
      if (id === 'walletOptions') return walletOptions;
      return null;
    },
  };

  const context = {
    console: TEST_CONSOLE,
    Map,
    Event: class {
      constructor(type, init = {}) {
        this.type = type;
        Object.assign(this, init);
      }
    },
    document: documentStub,
    localStorage,
    location: { origin: 'https://zfi.test' },
    setTimeout: timers.setTimeout.bind(timers),
    clearTimeout: timers.clearTimeout.bind(timers),
    ethers: {
      BrowserProvider: class {
        constructor(walletProvider) {
          this.walletProvider = walletProvider;
        }

        async getSigner() {
          return {
            getAddress: async () => CONNECTED_ADDRESS,
          };
        }
      },
      JsonRpcProvider: class {},
      Contract: class {
        reverseResolve() {
          return Promise.reject(new Error('reverse resolve unavailable in wallet bridge tests'));
        }
      },
    },
    addEventListener() {},
    dispatchEvent() {},
    '@walletconnect/ethereum-provider': {
      EthereumProvider: {
        async init() {
          initCalls += 1;
          return createWalletConnectProvider();
        },
      },
    },
  };
  context.window = context;
  context.globalThis = context;
  const walletApi = loadWalletScript(context);

  return {
    context,
    connectWithWallet: walletApi.connectWithWallet,
    localStorage,
    timers,
    walletBtn,
    get initCalls() {
      return initCalls;
    },
    get providers() {
      return providers;
    },
  };
}

test('accountsChanged fires disconnect callbacks before reconnect callbacks', async () => {
  const harness = createWalletEventHarness();
  const callbackOrder = [];
  harness.context.walletInit({
    appName: 'zFi',
    onConnect: [() => callbackOrder.push('connect:' + harness.context._connectedAddress)],
    onDisconnect: [() => callbackOrder.push('disconnect')],
  });
  await harness.connect();
  assert.equal(harness.context._connectedAddress, CONNECTED_ADDRESS);
  callbackOrder.length = 0;

  // Switch to a different account
  harness.switchAddress(OTHER_ADDRESS);
  harness.eventHandlers.accountsChanged([OTHER_ADDRESS]);
  // The handler runs an async IIFE with multiple awaits; flush enough cycles
  for (let i = 0; i < 6; i++) await flushMicrotasks();

  assert.equal(callbackOrder[0], 'disconnect', 'disconnect fires first');
  assert.ok(callbackOrder[1]?.startsWith('connect:'), 'connect fires after disconnect');
  assert.equal(harness.context._connectedAddress, OTHER_ADDRESS);
});

test('accountsChanged with empty accounts array disconnects wallet', async () => {
  const harness = createWalletEventHarness();
  const disconnectCalls = [];
  harness.context.walletInit({
    appName: 'zFi',
    onConnect: [],
    onDisconnect: [() => disconnectCalls.push('disconnected')],
  });
  await harness.connect();
  assert.equal(harness.context._connectedAddress, CONNECTED_ADDRESS);

  harness.setProviderAccounts([]);
  harness.eventHandlers.accountsChanged([]);
  await flushMicrotasks();

  assert.equal(harness.context._connectedAddress, CONNECTED_ADDRESS, 'transient empty event does not disconnect immediately');

  await harness.timers.flushAll();

  assert.equal(harness.context._connectedAddress, null, 'address cleared');
  assert.equal(harness.context._signer, null, 'signer cleared');
  assert.ok(disconnectCalls.length > 0, 'disconnect callback fired');
});

test('chainChanged to non-mainnet disconnects cleanly', async () => {
  const harness = createWalletEventHarness();
  const disconnectCalls = [];
  harness.context.walletInit({
    appName: 'zFi',
    onConnect: [],
    onDisconnect: [() => disconnectCalls.push('disconnected')],
  });
  await harness.connect();
  assert.equal(harness.context._connectedAddress, CONNECTED_ADDRESS);

  harness.eventHandlers.chainChanged('0x5'); // Goerli
  await flushMicrotasks();

  assert.equal(harness.context._connectedAddress, null, 'address cleared after chain switch');
  assert.equal(harness.context._signer, null, 'signer cleared after chain switch');
  assert.ok(disconnectCalls.length > 0, 'disconnect callback fired on chain switch');
});

test('chainChanged to mainnet does not disconnect', async () => {
  const harness = createWalletEventHarness();
  const disconnectCalls = [];
  harness.context.walletInit({
    appName: 'zFi',
    onConnect: [],
    onDisconnect: [() => disconnectCalls.push('disconnected')],
  });
  await harness.connect();
  assert.equal(harness.context._connectedAddress, CONNECTED_ADDRESS);

  harness.eventHandlers.chainChanged('0x1'); // mainnet
  await flushMicrotasks();

  assert.equal(harness.context._connectedAddress, CONNECTED_ADDRESS, 'still connected');
  assert.equal(disconnectCalls.length, 0, 'no disconnect on mainnet');
});

test('accountsChanged updates wallet button text to new address', async () => {
  const harness = createWalletEventHarness();
  harness.context.walletInit({ appName: 'zFi', onConnect: [], onDisconnect: [] });
  await harness.connect();
  assert.ok(harness.walletBtn.textContent.includes(CONNECTED_ADDRESS.slice(0, 6)));

  harness.switchAddress(OTHER_ADDRESS);
  harness.eventHandlers.accountsChanged([OTHER_ADDRESS]);
  for (let i = 0; i < 6; i++) await flushMicrotasks();

  assert.ok(harness.walletBtn.textContent.includes(OTHER_ADDRESS.slice(0, 6)), 'button shows new address');
});

test('walletconnect auto-connect does not reconnect over a live manual session', async () => {
  const harness = createWalletConnectAutoConnectHarness();
  harness.localStorage.setItem('zfi_wallet', 'walletconnect');
  harness.localStorage.setItem('zfi_wallet_name', 'MetaMask');

  harness.context.walletInit({ appName: 'zFi', onConnect: [], onDisconnect: [] });
  await harness.connectWithWallet('walletconnect');

  assert.equal(harness.context._connectedAddress, CONNECTED_ADDRESS, 'manual connect completed');
  assert.equal(harness.initCalls, 1, 'manual connect created one WalletConnect provider');

  await harness.timers.flushAll();

  assert.equal(harness.initCalls, 1, 'auto-connect did not create a second provider');
  assert.equal(harness.providers[0]?.disconnectCalls || 0, 0, 'live provider was not disconnected');
  assert.equal(harness.context._connectedAddress, CONNECTED_ADDRESS, 'wallet stayed connected');
  assert.equal(harness.localStorage.getItem('zfi_wallet'), 'walletconnect', 'saved wallet preserved');
});

await done();
