import { readFileSync } from 'node:fs';
import { webcrypto } from 'node:crypto';
import vm from 'node:vm';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const PRIVACY_RUNTIME_START_MARKER = '// ==================== PRIVACY POOLS RUNTIME START ====================';
const PRIVACY_RUNTIME_END_MARKER = '// ==================== PRIVACY POOLS RUNTIME END ====================';

let _appSourceCache = null;
let _privacyModuleSourceCache = null;
let _privacyRuntimeSourceCache = null;
let _privacyRuntimeLibs = null;

// Patchable state keys are discovered from the runtime via
// __ppTestPatchableKeys__ — no hardcoded allowlist needed here.

function getAppSource() {
  if (!_appSourceCache) _appSourceCache = readFileSync(path.join(ROOT, 'dapp/index.html'), 'utf8');
  return _appSourceCache;
}

// The privacy runtime lives in its own module; dapp/index.html only loads it.
function getPrivacyModuleSource() {
  if (!_privacyModuleSourceCache) {
    _privacyModuleSourceCache = readFileSync(path.join(ROOT, 'dapp/modules/privacy-pools.js'), 'utf8');
  }
  return _privacyModuleSourceCache;
}

function getPrivacyRuntimeSource() {
  if (!_privacyRuntimeSourceCache) {
    _privacyRuntimeSourceCache = sliceSourceByMarkers(
      getPrivacyModuleSource(),
      PRIVACY_RUNTIME_START_MARKER,
      PRIVACY_RUNTIME_END_MARKER,
    );
  }
  return _privacyRuntimeSourceCache;
}

function validateStatePatchKeys(statePatch, ctx) {
  if (!statePatch || typeof statePatch !== 'object') return;
  const allowed = ctx?.__ppTestPatchableKeys__;
  if (!allowed) throw new Error('Runtime did not expose __ppTestPatchableKeys__');
  const allowedSet = new Set(allowed);
  for (const key of Object.keys(statePatch)) {
    if (!allowedSet.has(key)) {
      throw new Error(`Unsupported privacy test statePatch key: ${key}`);
    }
  }
}

export function loadPrivacyMarkupSource() {
  // Markup lives in dapp/index.html, the runtime copy lives in the privacy
  // module; contract tests assert over both.
  return getAppSource() + '\n' + getPrivacyModuleSource();
}

function sliceSourceByMarkers(source, startMarker, endMarker) {
  const start = source.indexOf(startMarker);
  if (start === -1) {
    throw new Error(`Missing source marker: ${startMarker}`);
  }
  const end = endMarker ? source.indexOf(endMarker, start) : source.length;
  if (end === -1) {
    throw new Error(`Missing source marker: ${endMarker}`);
  }
  return source.slice(start, end);
}

function createStorageStub(seed = {}) {
  const data = new Map(Object.entries(seed || {}).map(([key, value]) => [key, String(value)]));
  return {
    getItem(key) {
      return data.has(key) ? data.get(key) : null;
    },
    setItem(key, value) {
      data.set(String(key), String(value));
    },
    removeItem(key) {
      data.delete(String(key));
    },
    clear() {
      data.clear();
    },
  };
}

// Minimal document stub — only implements methods the privacy runtime
// actually calls during test execution. Methods like createElement,
// getElementById, etc. are intentionally absent so that any new runtime
// code touching unimplemented DOM APIs will throw (ReferenceError on the
// missing method) rather than silently returning null.
function createDocumentStub() {
  return {
    title: '',
    addEventListener() {},
    querySelector() { return null; },
    querySelectorAll() { return []; },
  };
}

function createHistoryStub() {
  return {
    replaceState() {},
  };
}

function createLocationStub() {
  return {
    hash: '',
    pathname: '/',
    search: '',
    origin: 'https://zfi.test',
  };
}

export function createElement(initial = {}, options = {}) {
  const {
    trackListeners = false,
    styleDefaults = {},
    withSetAttribute = true,
    withScrollIntoView = false,
  } = options;
  const listeners = trackListeners ? new Map() : null;
  const defaultStyle = {
    display: '',
    color: '',
    opacity: '',
    borderColor: '',
    background: '',
    cursor: '',
    ...styleDefaults,
  };
  return {
    textContent: '',
    innerHTML: '',
    disabled: false,
    onclick: null,
    dataset: {},
    checked: false,
    value: '',
    readOnly: false,
    addEventListener(type, handler) {
      if (listeners) listeners.set(type, handler);
    },
    dispatchEvent(event) {
      const handler = listeners?.get(event?.type);
      if (handler) return handler(event);
      return undefined;
    },
    getListener(type) {
      return listeners?.get(type) || null;
    },
    setAttribute(name, value) {
      if (!withSetAttribute) return;
      this[name] = String(value);
    },
    scrollIntoView() {
      if (!withScrollIntoView) return;
    },
    ...initial,
    style: {
      ...defaultStyle,
      ...(initial.style || {}),
    },
  };
}

export function createDom(elements, options = {}) {
  const resolveElement = options.resolveElement || ((idOrEl) => (
    typeof idOrEl === 'string' ? elements[idOrEl] || null : idOrEl || null
  ));
  return {
    $: (id) => resolveElement(id),
    setText(idOrEl, value) {
      const el = resolveElement(idOrEl);
      if (el) el.textContent = String(value);
    },
    setHTML(idOrEl, value) {
      const el = resolveElement(idOrEl);
      if (el) el.innerHTML = String(value);
    },
    setShown(idOrEl, shown) {
      const el = resolveElement(idOrEl);
      if (el) el.style.display = shown ? '' : 'none';
    },
    setDisabled(idOrEl, disabled) {
      const el = resolveElement(idOrEl);
      if (el) el.disabled = !!disabled;
    },
  };
}

export async function flushMicrotasks(options = {}) {
  const strategy = options.strategy || 'double-promise';
  if (strategy === 'set-immediate') {
    await new Promise((resolve) => setImmediate(resolve));
    return;
  }
  await Promise.resolve();
  await Promise.resolve();
}

const ESC_TEXT_MAP = Object.freeze({ '&': '&amp;', '<': '&lt;', '>': '&gt;' });

function escapeTextLikeApp(value) {
  return String(value).replace(/[&<>]/g, (match) => ESC_TEXT_MAP[match]);
}

function escapeAttrLikeApp(value) {
  return escapeTextLikeApp(value).replace(/"/g, '&quot;').replace(/'/g, '&#39;');
}

function fmtLikeApp(value, max = 6) {
  if (value == null) return '--';
  const numeric = Number(value);
  if (!Number.isFinite(numeric) || Math.abs(numeric) >= 1e21) {
    const stringValue = String(value);
    return stringValue.includes('.')
      ? stringValue.replace(new RegExp(`(\\.\\d{0,${max}}).*$`), '$1').replace(/\\.?0+$/, '')
      : stringValue;
  }
  return numeric.toLocaleString(undefined, { maximumFractionDigits: max });
}

export function createHarness({
  globals = {},
  statePatch = null,
  baseElements = {},
  extraElements = {},
  console: harnessConsole = { log() {}, warn() {}, error() {} },
  document: documentOverride = null,
  window: windowOverride = null,
  history: historyOverride = null,
  localStorage: localStorageOverride = null,
  decorateRuntimeGlobals = null,
  postLoadGlobals = null,
  decorateHarness = null,
} = {}) {
  const elements = {
    ...baseElements,
    ...extraElements,
  };
  const dom = createDom(elements);
  const harnessState = {
    statusCalls: [],
    connectWalletCalls: 0,
    balanceCache: new Map(),
    domReadyHandler: null,
  };
  const documentStub = {
    title: '',
    body: {
      appendChild() {},
      removeChild() {},
      ...(documentOverride?.body || {}),
    },
    querySelector() { return null; },
    querySelectorAll() { return []; },
    ...documentOverride,
    addEventListener(type, handler, ...rest) {
      if (type === 'DOMContentLoaded') harnessState.domReadyHandler = handler;
      if (typeof documentOverride?.addEventListener === 'function') {
        return documentOverride.addEventListener.call(this, type, handler, ...rest);
      }
      return undefined;
    },
  };
  const runtimeGlobals = {
    console: harnessConsole,
    document: documentStub,
    window: {
      location: { search: '', hash: '', pathname: '/', origin: 'https://zfi.test' },
      requestIdleCallback: null,
      setTimeout,
      clearTimeout,
      ...(windowOverride || {}),
    },
    history: {
      replaceState() {},
      ...(historyOverride || {}),
    },
    localStorage: localStorageOverride || createStorageStub(),
    showStatus(message, type = '') {
      harnessState.statusCalls.push({ message, type });
    },
    connectWallet() {
      harnessState.connectWalletCalls += 1;
    },
    getCachedBalance(tokenAddr) {
      const key = String(tokenAddr || '').toLowerCase();
      return harnessState.balanceCache.has(key) ? harnessState.balanceCache.get(key) : null;
    },
    setCachedBalance(tokenAddr, balance) {
      harnessState.balanceCache.set(String(tokenAddr || '').toLowerCase(), BigInt(balance));
    },
    escText: escapeTextLikeApp,
    escAttr: escapeAttrLikeApp,
    fmt: fmtLikeApp,
    ...dom,
    ...globals,
  };
  if (typeof decorateRuntimeGlobals === 'function') {
    const overrides = decorateRuntimeGlobals(runtimeGlobals, harnessState, elements, dom);
    if (overrides && typeof overrides === 'object') Object.assign(runtimeGlobals, overrides);
  }
  const loaded = loadPrivacyTestApi({
    globals: runtimeGlobals,
    statePatch,
  });
  const protectedRuntimeKeys = new Set(['escText', 'escAttr', 'fmt']);
  for (const [key, value] of Object.entries(runtimeGlobals)) {
    if (protectedRuntimeKeys.has(key)) continue;
    if (Object.prototype.hasOwnProperty.call(globals, key) || !(key in loaded.context)) {
      loaded.context[key] = value;
    }
  }
  if (typeof postLoadGlobals === 'function') {
    const overrides = postLoadGlobals(loaded.context, harnessState, elements, dom);
    if (overrides && typeof overrides === 'object') Object.assign(loaded.context, overrides);
  }
  const harness = {
    ...loaded,
    elements,
    dom,
    runtimeGlobals,
    statusCalls: harnessState.statusCalls,
    balanceCache: harnessState.balanceCache,
    get lastStatus() {
      return harnessState.statusCalls[harnessState.statusCalls.length - 1] || null;
    },
    get connectWalletCalls() {
      return harnessState.connectWalletCalls;
    },
    get domReadyHandler() {
      return harnessState.domReadyHandler;
    },
    setCachedBalance(tokenAddr, balance) {
      harnessState.balanceCache.set(String(tokenAddr || '').toLowerCase(), BigInt(balance));
    },
  };
  if (typeof decorateHarness === 'function') {
    const decorated = decorateHarness(harness, harnessState, elements, dom);
    if (decorated) return decorated;
  }
  return harness;
}

function createUrlWithBlobHelpers() {
  const BaseURL = globalThis.URL;
  class URLWithBlobHelpers extends BaseURL {}
  URLWithBlobHelpers.createObjectURL = () => 'blob:privacy-test';
  URLWithBlobHelpers.revokeObjectURL = () => {};
  return URLWithBlobHelpers;
}

function getPrivacyRuntimeLibs() {
  if (!_privacyRuntimeLibs) {
    _privacyRuntimeLibs = createPoseidonContext({ withEthers: true });
  }
  return _privacyRuntimeLibs;
}

export function loadPrivacyTestApi({ globals = {}, statePatch = null } = {}) {
  const { poseidon1, poseidon2, poseidon3, ethers } = getPrivacyRuntimeLibs();
  const defaultConsole = { log() {}, warn() {}, error() {} };
  const defaultLocation = createLocationStub();
  const defaultWindow = {
    location: defaultLocation,
    requestIdleCallback: null,
    setTimeout,
    clearTimeout,
  };

  const contextGlobals = {
    __PP_ENABLE_TEST_API__: true,
    console: defaultConsole,
    Array,
    BigInt,
    Blob,
    Boolean,
    Date,
    DOMException,
    Map,
    Math,
    Number,
    Object,
    Promise,
    Set,
    String,
    TextDecoder,
    TextEncoder,
    Uint8Array,
    URL: createUrlWithBlobHelpers(),
    URLSearchParams,
    AbortController,
    AbortSignal,
    clearInterval,
    clearTimeout,
    crypto: webcrypto,
    document: createDocumentStub(),
    ethers,
    fetch: typeof fetch === 'function' ? fetch : async () => { throw new Error('fetch not available'); },
    globalThis: null,
    history: createHistoryStub(),
    localStorage: createStorageStub(),
    poseidon1,
    poseidon2,
    poseidon3,
    queueMicrotask,
    setInterval,
    setTimeout,
    window: defaultWindow,
    Worker: class {
      constructor() {
        throw new Error('Worker is not stubbed for this privacy test context.');
      }
    },
    $: () => null,
    setDisabled() {},
    setShown() {},
    setText() {},
  };

  Object.assign(contextGlobals, globals);
  if (!contextGlobals.window) contextGlobals.window = defaultWindow;
  if (!contextGlobals.window.location) contextGlobals.window.location = defaultLocation;
  if (!contextGlobals.history) contextGlobals.history = createHistoryStub();
  if (!contextGlobals.document) contextGlobals.document = createDocumentStub();
  if (!contextGlobals.localStorage) contextGlobals.localStorage = createStorageStub();
  if (typeof contextGlobals.$ !== 'function') contextGlobals.$ = () => null;
  if (typeof contextGlobals.setShown !== 'function') contextGlobals.setShown = () => {};
  if (typeof contextGlobals.setText !== 'function') contextGlobals.setText = () => {};
  if (typeof contextGlobals.setDisabled !== 'function') contextGlobals.setDisabled = () => {};

  const ctx = vm.createContext(contextGlobals);
  ctx.globalThis = ctx;
  if (ctx.window && typeof ctx.window === 'object') {
    if (!('globalThis' in ctx.window)) ctx.window.globalThis = ctx;
    if (!('document' in ctx.window)) ctx.window.document = ctx.document;
    if (!('history' in ctx.window)) ctx.window.history = ctx.history;
  }
  vm.runInContext(getPrivacyRuntimeSource(), ctx);
  if (statePatch && typeof statePatch === 'object') {
    validateStatePatchKeys(statePatch, ctx);
    ctx.__ppTestApplyStatePatch__(statePatch);
  }
  if (!ctx.__PP_TEST_API__) {
    throw new Error('Privacy test API was not registered by the runtime.');
  }
  return {
    api: ctx.__PP_TEST_API__,
    context: ctx,
  };
}

export function createPoseidonContext({ withEthers = false } = {}) {
  const globals = { window: {}, atob: (s) => Buffer.from(s, 'base64').toString('binary'), Uint8Array, Array, BigInt };
  if (withEthers) {
    Object.assign(globals, { globalThis: {}, btoa: (s) => Buffer.from(s, 'binary').toString('base64'), crypto: webcrypto, TextEncoder, TextDecoder });
  }
  const ctx = vm.createContext(globals);
  vm.runInContext(readFileSync(path.join(ROOT, 'dapp/vendor/poseidon1.min.js'), 'utf8'), ctx);
  vm.runInContext(readFileSync(path.join(ROOT, 'dapp/vendor/poseidon2.min.js'), 'utf8'), ctx);
  vm.runInContext(readFileSync(path.join(ROOT, 'dapp/vendor/poseidon3.min.js'), 'utf8'), ctx);
  if (withEthers) {
    vm.runInContext(readFileSync(path.join(ROOT, 'dapp/vendor/ethers.min.js'), 'utf8'), ctx);
  }
  const result = { poseidon1: ctx.window.poseidon1, poseidon2: ctx.window.poseidon2, poseidon3: ctx.window.poseidon3 };
  if (withEthers) result.ethers = ctx.globalThis.ethers;
  return result;
}

export function createKeyDerivation(poseidon2, poseidon3) {
  return {
    ppDeriveDepositKeys(masterNullifier, masterSecret, scope, index) {
      const nullifier = poseidon3([masterNullifier, scope, BigInt(index)]);
      const secret = poseidon3([masterSecret, scope, BigInt(index)]);
      const precommitment = poseidon2([nullifier, secret]);
      return { nullifier, secret, precommitment };
    },
    ppDeriveWithdrawalKeys(masterNullifier, masterSecret, label, withdrawalIndex) {
      const nullifier = poseidon3([masterNullifier, label, BigInt(withdrawalIndex)]);
      const secret = poseidon3([masterSecret, label, BigInt(withdrawalIndex)]);
      const precommitment = poseidon2([nullifier, secret]);
      return { nullifier, secret, precommitment };
    },
  };
}

export function createTestRunner() {
  let passed = 0;
  let failed = 0;
  const pending = [];

  function test(name, fn) {
    const p = (async () => {
      try {
        await fn();
        passed++;
        console.log(`  \x1b[32mPASS\x1b[0m ${name}`);
      } catch (e) {
        failed++;
        console.log(`  \x1b[31mFAIL\x1b[0m ${name}`);
        console.log(`       ${e.message}`);
      }
    })();
    pending.push(p);
    return p;
  }

  async function done() {
    await Promise.all(pending);
    console.log(`\n${'═'.repeat(60)}`);
    if (failed === 0) {
      console.log(`\x1b[32m  All ${passed} tests passed.\x1b[0m\n`);
      process.exit(0);
    } else {
      console.log(`\x1b[31m  ${failed} failed, ${passed} passed.\x1b[0m\n`);
      process.exit(1);
    }
  }

  return { test, done };
}
