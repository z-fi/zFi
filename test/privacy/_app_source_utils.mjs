import { existsSync, readFileSync } from 'node:fs';
import { webcrypto } from 'node:crypto';
import vm from 'node:vm';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const PRIVACY_RUNTIME_START_MARKER = '// ==================== PRIVACY POOLS RUNTIME START ====================';
const PRIVACY_RUNTIME_END_MARKER = '// ==================== PRIVACY POOLS RUNTIME END ====================';
const PRIVACY_RUNTIME_PATHS = [
  path.join(ROOT, 'dapp/modules/privacy-pools.js'),
  path.join(ROOT, 'dapp/privacy-pools.js'),
];
const POSEIDON_SCRIPT_PATHS = [
  ['dapp/vendor/poseidon1.min.js', 'dapp/vendor/poseidon2.min.js', 'dapp/vendor/poseidon3.min.js'],
  ['dapp/poseidon1.min.js', 'dapp/poseidon2.min.js', 'dapp/poseidon3.min.js'],
];
const ETHERS_SCRIPT_PATHS = [
  'dapp/vendor/ethers.min.js',
  'dapp/ethers.min.js',
];

let _appSourceCache = null;
let _privacyRuntimeSourceCache = null;
let _privacyRuntimeLibs = null;

// Patchable state keys are discovered from the runtime via
// __ppTestPatchableKeys__ — no hardcoded allowlist needed here.

function getAppSource() {
  if (!_appSourceCache) _appSourceCache = readFileSync(path.join(ROOT, 'dapp/index.html'), 'utf8');
  return _appSourceCache;
}

function getPrivacyRuntimeSource() {
  if (!_privacyRuntimeSourceCache) {
    const runtimePath = PRIVACY_RUNTIME_PATHS.find((candidate) => existsSync(candidate));
    _privacyRuntimeSourceCache = runtimePath
      ? readFileSync(runtimePath, 'utf8')
      : sliceSourceByMarkers(
          getAppSource(),
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
  return getAppSource();
}

export function loadPrivacyRuntimeSource() {
  return getPrivacyRuntimeSource();
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

function createEventTarget() {
  const listeners = new Map();
  return {
    addEventListener(type, handler) {
      if (!type || typeof handler !== 'function') return;
      if (!listeners.has(type)) listeners.set(type, new Set());
      listeners.get(type).add(handler);
    },
    removeEventListener(type, handler) {
      listeners.get(type)?.delete(handler);
    },
    dispatchEvent(event) {
      if (!event?.type) throw new Error('Event object must include a type.');
      if (!('target' in event)) event.target = this;
      event.currentTarget = this;
      for (const handler of [...(listeners.get(event.type) || [])]) {
        handler.call(this, event);
      }
      return !event.defaultPrevented;
    },
  };
}

function createClassList(seed = []) {
  const classes = new Set(seed.filter(Boolean));
  return {
    add(...names) {
      for (const name of names) if (name) classes.add(name);
    },
    remove(...names) {
      for (const name of names) classes.delete(name);
    },
    contains(name) {
      return classes.has(name);
    },
    toggle(name, force) {
      if (force === true) {
        classes.add(name);
        return true;
      }
      if (force === false) {
        classes.delete(name);
        return false;
      }
      if (classes.has(name)) {
        classes.delete(name);
        return false;
      }
      classes.add(name);
      return true;
    },
    toString() {
      return [...classes].join(' ');
    },
    values() {
      return [...classes];
    },
  };
}

function createFakeTimerApi() {
  let nextId = 1;
  const pending = new Map();
  function schedule(kind, fn, args) {
    const id = nextId++;
    pending.set(id, { kind, fn, args });
    return id;
  }
  return {
    setTimeout(fn, _delay = 0, ...args) {
      if (typeof fn !== 'function') return schedule('timeout', () => {}, []);
      return schedule('timeout', fn, args);
    },
    clearTimeout(id) {
      pending.delete(id);
    },
    setInterval(fn, _delay = 0, ...args) {
      if (typeof fn !== 'function') return schedule('interval', () => {}, []);
      return schedule('interval', fn, args);
    },
    clearInterval(id) {
      pending.delete(id);
    },
  };
}

function dataAttrToDatasetKey(name) {
  return String(name).replace(/-([a-z])/g, (_, ch) => ch.toUpperCase());
}

function parseHtmlAttrs(rawAttrs = '') {
  const attrs = {};
  for (const match of rawAttrs.matchAll(/([^\s=]+)(?:="([^"]*)")?/g)) {
    attrs[match[1]] = match[2] ?? '';
  }
  return attrs;
}

function createStaticShellDocument(markup, locationState) {
  const documentEvents = createEventTarget();
  const allElements = [];
  const elementsById = new Map();

  function matchesSelector(el, selector) {
    if (!selector || !el) return false;
    const attrNames = [...selector.matchAll(/\[([^\]=]+)(?:=[^\]]+)?\]/g)].map((match) => match[1]);
    const classNames = [...selector.matchAll(/\.([A-Za-z0-9_-]+)/g)].map((match) => match[1]);
    const idMatch = selector.match(/#([A-Za-z0-9_-]+)/);
    if (idMatch && el.id !== idMatch[1]) return false;
    if (classNames.some((className) => !el.classList.contains(className))) return false;
    for (const attrName of attrNames) {
      if (attrName.startsWith('data-')) {
        const key = dataAttrToDatasetKey(attrName.slice(5));
        if (!(key in el.dataset)) return false;
      } else if (!(attrName in el) && !el.attributes?.has(attrName)) {
        return false;
      }
    }
    const selectorSansClasses = selector.replace(/[#.][A-Za-z0-9_-]+/g, '').replace(/\[[^\]]+\]/g, '').trim();
    if (selectorSansClasses && selectorSansClasses !== '*' && selectorSansClasses.toLowerCase() !== el.tagName.toLowerCase()) {
      return false;
    }
    return true;
  }

  function registerElement(el) {
    if (!allElements.includes(el)) allElements.push(el);
    if (el.id) elementsById.set(el.id, el);
    return el;
  }

  function createShellElement(descriptor = {}, parentElement = null) {
    const eventTarget = createEventTarget();
    const classList = createClassList(descriptor.classes || []);
    const attributes = new Map(Object.entries(descriptor.attributes || {}));
    let innerHTML = descriptor.innerHTML || '';
    let outerHTML = '';
    const element = createElement({
      tagName: String(descriptor.tagName || 'div').toUpperCase(),
      dataset: { ...(descriptor.dataset || {}) },
      parentElement,
      children: [],
      classList,
      attributes,
      closest(selector) {
        let node = this;
        while (node) {
          if (matchesSelector(node, selector)) return node;
          node = node.parentElement || null;
        }
        return null;
      },
      appendChild(child) {
        if (!child) return child;
        child.parentElement = this;
        this.children.push(child);
        registerElement(child);
        return child;
      },
      prepend(child) {
        if (!child) return child;
        child.parentElement = this;
        this.children.unshift(child);
        registerElement(child);
        return child;
      },
      removeChild(child) {
        const idx = this.children.indexOf(child);
        if (idx !== -1) this.children.splice(idx, 1);
        if (child) child.parentElement = null;
        return child;
      },
      remove() {
        this.parentElement?.removeChild(this);
      },
      querySelector(selector) {
        return this.querySelectorAll(selector)[0] || null;
      },
      querySelectorAll(selector) {
        return allElements.filter((candidate) => matchesSelector(candidate, selector));
      },
      addEventListener: eventTarget.addEventListener,
      removeEventListener: eventTarget.removeEventListener,
      dispatchEvent(event) {
        return eventTarget.dispatchEvent.call(this, event);
      },
      setAttribute(name, value) {
        const nextValue = String(value);
        attributes.set(name, nextValue);
        if (name === 'id') {
          this.id = nextValue;
          elementsById.set(nextValue, this);
          return;
        }
        if (name === 'class') {
          this.className = nextValue;
          return;
        }
        if (name.startsWith('data-')) {
          this.dataset[dataAttrToDatasetKey(name.slice(5))] = nextValue;
          return;
        }
        this[name] = nextValue;
      },
      getAttribute(name) {
        if (name === 'id') return this.id || null;
        if (name === 'class') return this.className;
        if (name.startsWith('data-')) return this.dataset[dataAttrToDatasetKey(name.slice(5))] ?? null;
        return attributes.get(name) ?? null;
      },
      style: {
        display: '',
        color: '',
        opacity: '',
        borderColor: '',
        background: '',
        cursor: '',
        paddingTop: '',
        ...(descriptor.style || {}),
      },
    }, { trackListeners: false, withScrollIntoView: true });

    Object.defineProperties(element, {
      id: {
        get() {
          return this._id || '';
        },
        set(value) {
          this._id = value ? String(value) : '';
          if (this._id) elementsById.set(this._id, this);
        },
      },
      className: {
        get() {
          return classList.toString();
        },
        set(value) {
          classList.values().forEach((className) => classList.remove(className));
          String(value || '').split(/\s+/).filter(Boolean).forEach((className) => classList.add(className));
        },
      },
      innerHTML: {
        get() {
          return innerHTML;
        },
        set(value) {
          innerHTML = String(value ?? '');
          registerMarkupFragment(innerHTML, this);
        },
      },
      outerHTML: {
        get() {
          return outerHTML;
        },
        set(value) {
          outerHTML = String(value ?? '');
          registerMarkupFragment(outerHTML, this.parentElement || body);
        },
      },
    });

    if (descriptor.id) element.id = descriptor.id;
    if (descriptor.value != null) element.value = descriptor.value;
    if (descriptor.checked != null) element.checked = !!descriptor.checked;
    return registerElement(element);
  }

  function registerMarkupFragment(fragment, parentElement = null) {
    const created = [];
    for (const match of fragment.matchAll(/<([a-zA-Z][\w:-]*)([^>]*)>/g)) {
      const tagName = match[1].toLowerCase();
      if (tagName === 'script') continue;
      const attrs = parseHtmlAttrs(match[2] || '');
      const id = attrs.id || '';
      const classes = (attrs.class || '').split(/\s+/).filter(Boolean);
      const dataset = Object.fromEntries(
        Object.entries(attrs)
          .filter(([name]) => name.startsWith('data-'))
          .map(([name, value]) => [dataAttrToDatasetKey(name.slice(5)), value]),
      );
      if (!id && classes.length === 0 && Object.keys(dataset).length === 0) continue;
      const existing = id ? elementsById.get(id) : null;
      const element = existing || createShellElement({
        tagName,
        id,
        classes,
        dataset,
        attributes: attrs,
        value: attrs.value || '',
      }, parentElement || body);
      if (existing) {
        element.className = classes.join(' ');
        Object.assign(element.dataset, dataset);
      }
      if (!created.includes(element)) created.push(element);
    }
    return created;
  }

  const documentElement = createShellElement({ tagName: 'html' });
  const body = createShellElement({ tagName: 'body' }, documentElement);
  body.parentElement = documentElement;
  documentElement.children.push(body);

  registerMarkupFragment(markup, body);

  const document = {
    title: '',
    readyState: 'loading',
    documentElement,
    body,
    getElementById(id) {
      return elementsById.get(String(id)) || null;
    },
    createElement(tagName) {
      return createShellElement({ tagName }, body);
    },
    querySelector(selector) {
      return this.querySelectorAll(selector)[0] || null;
    },
    querySelectorAll(selector) {
      return allElements.filter((candidate) => matchesSelector(candidate, selector));
    },
    addEventListener: documentEvents.addEventListener,
    removeEventListener: documentEvents.removeEventListener,
    dispatchEvent(event) {
      return documentEvents.dispatchEvent.call(this, event);
    },
  };

  return {
    document,
    elementsById,
    dispatchDomReady() {
      document.readyState = 'interactive';
      document.dispatchEvent({
        type: 'DOMContentLoaded',
        defaultPrevented: false,
        preventDefault() {
          this.defaultPrevented = true;
        },
      });
      document.readyState = 'complete';
    },
    createHistory(windowRef) {
      return {
        replaceState(_state, _title, nextUrl = '') {
          if (!nextUrl) return;
          const current = `${locationState.origin}${locationState.pathname}${locationState.search}${locationState.hash}`;
          const resolved = new URL(String(nextUrl), current);
          locationState.pathname = resolved.pathname;
          locationState.search = resolved.search;
          locationState.hash = resolved.hash;
          if (windowRef?.location) {
            windowRef.location.pathname = resolved.pathname;
            windowRef.location.search = resolved.search;
            windowRef.location.hash = resolved.hash;
          }
        },
      };
    },
  };
}

function getStaticShellScriptPlan() {
  const scripts = [];
  for (const match of getAppSource().matchAll(/<script([^>]*)>([\s\S]*?)<\/script>/g)) {
    const attrs = parseHtmlAttrs(match[1] || '');
    scripts.push({
      src: attrs.src || null,
      defer: Object.prototype.hasOwnProperty.call(attrs, 'defer'),
      content: match[2] || '',
    });
  }
  const startIndex = scripts.findIndex((script) => (
    script.src === './vendor/ethers.min.js' || script.src === './ethers.min.js'
  ));
  const endIndex = scripts.findIndex((script) => !script.src && script.content.includes('function switchTab(tab)'));
  if (startIndex === -1 || endIndex === -1 || endIndex < startIndex) {
    throw new Error('Could not resolve the static privacy shell boot scripts from index.html.');
  }
  return scripts
    .slice(startIndex, endIndex + 1)
    .filter((script) => script.src !== './walletconnect.min.js' && script.src !== './vendor/walletconnect.min.js');
}

function readDappScriptSource(src) {
  return readFileSync(path.join(ROOT, 'dapp', src.replace(/^\.\//, '')), 'utf8');
}

export function bootPrivacyStaticShell({
  hash = '#privacy',
  search = '',
  pathname = '/dapp/index.html',
  console: shellConsole = { log() {}, warn() {}, error() {} },
} = {}) {
  const timers = createFakeTimerApi();
  const location = createLocationStub();
  location.hash = hash;
  location.search = search;
  location.pathname = pathname;
  const localStorage = createStorageStub();
  const windowEvents = createEventTarget();
  const { document, elementsById, dispatchDomReady, createHistory } = createStaticShellDocument(getAppSource(), location);
  const window = {
    location,
    document,
    localStorage,
    requestIdleCallback: null,
    matchMedia() {
      return {
        matches: false,
        addEventListener() {},
        removeEventListener() {},
      };
    },
    navigator: { userAgent: 'privacy-static-shell-test' },
    addEventListener: windowEvents.addEventListener,
    removeEventListener: windowEvents.removeEventListener,
    dispatchEvent(event) {
      return windowEvents.dispatchEvent.call(this, event);
    },
  };
  const history = createHistory(window);

  const contextGlobals = {
    __PP_ENABLE_TEST_API__: true,
    console: shellConsole,
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
    Event: class {
      constructor(type, init = {}) {
        this.type = type;
        Object.assign(this, init);
      }
    },
    CustomEvent: class {
      constructor(type, init = {}) {
        this.type = type;
        this.detail = init.detail;
      }
    },
    atob: (s) => Buffer.from(s, 'base64').toString('binary'),
    btoa: (s) => Buffer.from(s, 'binary').toString('base64'),
    clearInterval: timers.clearInterval,
    clearTimeout: timers.clearTimeout,
    crypto: webcrypto,
    document,
    fetch: async () => {
      throw new Error('fetch is disabled in the static privacy shell smoke test');
    },
    globalThis: null,
    history,
    localStorage,
    location,
    navigator: window.navigator,
    performance: { now: () => 0 },
    queueMicrotask,
    requestAnimationFrame(fn) {
      return timers.setTimeout(() => fn(0), 16);
    },
    cancelAnimationFrame(id) {
      timers.clearTimeout(id);
    },
    setInterval: timers.setInterval,
    setTimeout: timers.setTimeout,
    window,
    Worker: class {
      constructor() {
        throw new Error('Worker is not available in the static privacy shell smoke test.');
      }
    },
  };

  const ctx = vm.createContext(contextGlobals);
  ctx.globalThis = ctx;
  ctx.window.globalThis = ctx;
  ctx.window.window = ctx.window;
  ctx.window.history = history;
  ctx.window.location = location;
  ctx.window.document = document;
  ctx.window.localStorage = localStorage;
  ctx.window.setTimeout = timers.setTimeout;
  ctx.window.clearTimeout = timers.clearTimeout;
  ctx.window.setInterval = timers.setInterval;
  ctx.window.clearInterval = timers.clearInterval;
  ctx.window.requestAnimationFrame = ctx.requestAnimationFrame;
  ctx.window.cancelAnimationFrame = ctx.cancelAnimationFrame;

  function syncWindowGlobals() {
    for (const [key, value] of Object.entries(ctx.window)) {
      if (!(key in ctx)) ctx[key] = value;
    }
  }

  syncWindowGlobals();

  const deferredScripts = [];
  for (const script of getStaticShellScriptPlan()) {
    const source = script.src ? readDappScriptSource(script.src) : script.content;
    if (script.defer) {
      deferredScripts.push({ source, filename: script.src || 'dapp/index.html:inline' });
      continue;
    }
    vm.runInContext(source, ctx, { filename: script.src || 'dapp/index.html:inline' });
    syncWindowGlobals();
  }
  for (const script of deferredScripts) {
    vm.runInContext(script.source, ctx, { filename: script.filename });
    syncWindowGlobals();
  }

  // Keep the smoke test scoped to the shipped privacy boot path, not unrelated
  // swap/send initialization side work that would otherwise fan out into
  // network requests and large DOM fixtures.
  for (const fnName of ['updateTokenDisplay', 'initTokenListClick', 'initTokenSearch', 'loadWeiLists', 'sendUpdateTokenDisplay', 'sendUpdateBalance', 'sendLoadTimelocks', 'coinUpdatePreview']) {
    if (typeof ctx[fnName] === 'function') ctx[fnName] = () => {};
  }

  dispatchDomReady();

  return {
    api: ctx.__PP_TEST_API__ || null,
    context: ctx,
    document,
    window: ctx.window,
    history,
    location,
    elements: new Proxy({}, {
      get(_target, key) {
        return elementsById.get(String(key)) || null;
      },
    }),
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
  const poseidonPaths = POSEIDON_SCRIPT_PATHS
    .map((candidates) => candidates.map((candidate) => path.join(ROOT, candidate)))
    .find((candidates) => candidates.every((candidate) => existsSync(candidate)));
  if (!poseidonPaths) {
    throw new Error('Could not resolve vendored poseidon bundles for privacy tests.');
  }
  vm.runInContext(readFileSync(poseidonPaths[0], 'utf8'), ctx);
  vm.runInContext(readFileSync(poseidonPaths[1], 'utf8'), ctx);
  vm.runInContext(readFileSync(poseidonPaths[2], 'utf8'), ctx);
  if (withEthers) {
    const ethersPath = ETHERS_SCRIPT_PATHS
      .map((candidate) => path.join(ROOT, candidate))
      .find((candidate) => existsSync(candidate));
    if (!ethersPath) {
      throw new Error('Could not resolve vendored ethers bundle for privacy tests.');
    }
    vm.runInContext(readFileSync(ethersPath, 'utf8'), ctx);
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
      return;
    } else {
      console.log(`\x1b[31m  ${failed} failed, ${passed} passed.\x1b[0m\n`);
      process.exitCode = 1;
      throw new Error(`${failed} failed, ${passed} passed.`);
    }
  }

  return { test, done };
}
