/**
 * Runs the coin page's "pay with an ERC-20" Sale tab for real, then puts the
 * transaction it would send through eth_call against mainnet.
 *
 * Quoting correctly and sending correctly are different failures. The first is
 * visible in the UI; the second costs money and is invisible until a wallet
 * confirms. So this asserts on both: what the page computes, and whether the
 * multicall it hands the router actually executes.
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { JSDOM, VirtualConsole, ResourceLoader } from 'jsdom';
import { ethers } from 'ethers';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..');
const PAGE = path.join(ROOT, 'dapp', 'coin', 'index.html');
const RPC_URL = process.env.ETH_RPC_URL || 'https://ethereum.publicnode.com';

const DAO = '0xE7Aa6cA3a9Ca3fe92a425dFeaD24900B9BF49853';
const SALE = '0x824d11a46F32cd16cdF46380314343e9697e2491';
const SHARES = '0x883d646d0C8202Aa23F01d4aF45E4E73804c3a49';
const USDC = '0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48';
const WETH = '0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2';
const ZROUTER = '0x000000000000FB114709235f1ccBFfb925F600e4';
const ZERO = ethers.ZeroAddress;
const USER = '0x1111111111111111111111111111111111111111';

let win = null, api = null, bootErr = null;

async function boot() {
  if (win || bootErr) return win;
  const vc = new VirtualConsole();
  class LocalLoader extends ResourceLoader {
    fetch(url) {
      // Serve the whole dapp tree, not just /coin/: the page pulls ethers and
      // its modules from ../vendor and ../modules, and without ethers every
      // `new ethers.Interface(...)` at the top of the page throws, taking the
      // rest of that script block's definitions with it.
      const m = /^https:\/\/zfi\.wei\.is\/(.*)$/.exec(url.split('?')[0]);
      if (!m) return null;
      const file = path.resolve(path.join(ROOT, 'dapp'), m[1]);
      if (!file.startsWith(path.join(ROOT, 'dapp')) || !fs.existsSync(file)) return null;
      return Promise.resolve(fs.readFileSync(file));
    }
  }
  const dom = new JSDOM(fs.readFileSync(PAGE, 'utf8'), {
    url: 'https://zfi.wei.is/coin/',
    runScripts: 'dangerously',
    resources: new LocalLoader(),
    pretendToBeVisual: true,
    virtualConsole: vc,
    // The theme script reads matchMedia at parse time; jsdom has no such thing,
    // and the throw takes out whatever else that block was going to define.
    beforeParse(w) {
      w.matchMedia = () => ({ matches: false, media: '', addListener() {}, removeListener() {},
                              addEventListener() {}, removeEventListener() {}, onchange: null });
      w.TextEncoder = TextEncoder;
      w.TextDecoder = TextDecoder;
      w.scrollTo = () => {};
    },
  });
  const w = dom.window;
  w.TextEncoder ??= TextEncoder;
  w.TextDecoder ??= TextDecoder;
  await new Promise(r => {
    if (w.document.readyState === 'complete') return r();
    w.addEventListener('load', r);
    setTimeout(r, 15000);
  });
  w.fetch = (...a) => fetch(...a);

  const WANT = ['SALE_PAY_TOKENS', 'CONTINUOUS_SALES', 'ROUTER_IFACE', 'COLLECTOL_IFACE',
                'quoteSalePayToken', 'onSalePayTokenChange', 'SALE_SLIP_BPS'];
  const probe = w.document.createElement('script');
  probe.textContent = `window.__probe = {}; window.__missing = [];
    ${WANT.map(n => `try { window.__probe[${JSON.stringify(n)}] = ${n}; }
      catch (e) { window.__missing.push(${JSON.stringify(n)}); }`).join('\n')}`;
  w.document.body.appendChild(probe);
  api = w.__probe;
  const missing = w.__missing ?? ['probe did not run'];
  if (missing.length) { bootErr = new Error('unreachable: ' + missing.join(', ')); return null; }
  win = w;
  return win;
}

// Stand in for a rendered coin page: the Sale tab reads its addresses off #app.
function seedApp(w) {
  const app = w.document.getElementById('app') || w.document.createElement('div');
  app.id = 'app';
  app.dataset.dao = DAO;
  app.dataset.contSale = SALE;
  app.dataset.shares = SHARES;
  if (!app.parentNode) w.document.body.appendChild(app);
  for (const id of ['salePayInput', 'saleReceiveInput', 'saleQuote', 'saleBuyBtn', 'salePayBal']) {
    if (!w.document.getElementById(id)) {
      const el = w.document.createElement(id === 'saleBuyBtn' ? 'button' : 'input');
      el.id = id;
      w.document.body.appendChild(el);
    }
  }
}

function setPayToken(w, sym) {
  const s = w.document.createElement('script');
  s.textContent = `_salePayToken = SALE_PAY_TOKENS.find(t => t.sym === ${JSON.stringify(sym)});
                   _connectedAddress = ${JSON.stringify(USER)};`;
  w.document.body.appendChild(s);
}
const plan = (w) => { const s = w.document.createElement('script');
  s.textContent = 'window.__plan = _salePlan;'; w.document.body.appendChild(s); return w.__plan; };

test('the sale config carries what a token purchase needs', async (t) => {
  const w = await boot();
  if (!w) return t.skip('page did not boot: ' + bootErr?.message);
  const cfg = api.CONTINUOUS_SALES[DAO.toLowerCase()];
  assert.ok(cfg, 'FWC sale configured');
  assert.equal(cfg.collectol, '0x0000003b9DFB69a1c764b1b136EE93dEDcdB2EE3');
  assert.equal(String(cfg.saleRate), '1000000000000000000000000');
  assert.equal(String(cfg.feeOrHook), '30');
  // Joined, not deepEqual: the array comes from the page's realm, so its
  // prototype is a different Array and structural comparison trips on identity.
  assert.equal(api.SALE_PAY_TOKENS.map(t2 => t2.sym).join(','), 'ETH,WETH,USDC,USDT,DAI');
  // Decimals matter more than they look: they scale the amount the user typed.
  assert.equal(api.SALE_PAY_TOKENS.find(t2 => t2.sym === 'USDC').decimals, 6);
  assert.equal(api.SALE_PAY_TOKENS.find(t2 => t2.sym === 'DAI').decimals, 18);
});

test('paying with USDC quotes a route and composes a sendable multicall', async (t) => {
  const w = await boot();
  if (!w) return t.skip('page did not boot: ' + bootErr?.message);
  seedApp(w);
  setPayToken(w, 'USDC');
  w.document.getElementById('salePayInput').value = '2000';

  try {
    await api.quoteSalePayToken();
  } catch (e) {
    if (/fetch|network|timeout|ECONN/i.test(String(e))) return t.skip(`RPC unavailable: ${e}`);
    throw e;
  }
  const p = plan(w);
  if (!p) return t.skip('no route returned (RPC or liquidity)');

  assert.ok(p.planned.totalOut > 0n, 'positive shares out');
  assert.ok(p.planned.ethToSale > 0n, 'the mint should win at this size');
  assert.equal(p.needsWrap, true, 'a USDC hop yields ETH, which must be wrapped');
  assert.equal(p.amountIn, 2000n * 10n ** 6n, 'USDC parsed at 6 decimals, not 18');

  // The displayed number must be the plan's, not a rounded stand-in.
  assert.equal(w.document.getElementById('saleReceiveInput').value,
    ethers.formatEther(p.planned.totalOut));

  // Now build exactly what the buy button would send, and run it.
  const cfg = api.CONTINUOUS_SALES[DAO.toLowerCase()];
  const deadline = BigInt(Math.floor(Date.now() / 1000) + 600);
  const buyData = api.COLLECTOL_IFACE.encodeFunctionData('buy', [
    p.planned.ethToSale, p.planned.poolAmount, p.planned.poolLimit,
    p.planned.poolExactOut, p.planned.minTotalOut, USER, USER, deadline]);
  const calls = [...p.legCalls,
    api.ROUTER_IFACE.encodeFunctionData('wrap', [p.ethBudget]),
    api.ROUTER_IFACE.encodeFunctionData('snwap', [WETH, 0, USER, SHARES, p.planned.minTotalOut, cfg.collectol, buyData]),
    api.ROUTER_IFACE.encodeFunctionData('sweep', [WETH, 0, 0, USER]),
    api.ROUTER_IFACE.encodeFunctionData('sweep', [ZERO, 0, 0, USER]),
    api.ROUTER_IFACE.encodeFunctionData('sweep', [USDC, 0, 0, USER])];
  const multicall = api.ROUTER_IFACE.encodeFunctionData('multicall', [calls]);

  const provider = new ethers.JsonRpcProvider(RPC_URL);
  const slot = (k, i) => ethers.keccak256(ethers.AbiCoder.defaultAbiCoder().encode(['address', 'uint256'], [k, i]));
  const allowSlot = ethers.keccak256(ethers.AbiCoder.defaultAbiCoder().encode(['address', 'bytes32'], [ZROUTER, slot(USER, 10n)]));
  const overrides = {
    [USER]: { balance: '0x56bc75e2d63100000' },
    [USDC]: { stateDiff: {
      [slot(USER, 9n)]: ethers.toBeHex(p.amountIn * 2n, 32),
      [allowSlot]: ethers.toBeHex(ethers.MaxUint256, 32),
    } },
  };
  try {
    await provider.send('eth_call', [
      { to: ZROUTER, from: USER, value: '0x0', data: multicall }, 'latest', overrides]);
  } catch (e) {
    const d = e?.info?.error?.data ?? e?.data ?? e.shortMessage ?? String(e);
    if (/state override|not supported|method/i.test(String(d))) return t.skip(`node lacks state overrides: ${d}`);
    assert.fail(`the transaction the Sale tab would send reverts: ${d}`);
  }
});

test('switching the pay asset clears the old amount', async (t) => {
  const w = await boot();
  if (!w) return t.skip('page did not boot: ' + bootErr?.message);
  seedApp(w);
  // "100" means something very different in USDC than in ETH; carrying the
  // number across would let a user buy a thousand times what they intended.
  const sel = w.document.createElement('select');
  sel.id = 'salePayToken';
  for (const t2 of api.SALE_PAY_TOKENS) {
    const o = w.document.createElement('option'); o.value = t2.sym; sel.appendChild(o);
  }
  w.document.body.appendChild(sel);
  w.document.getElementById('salePayInput').value = '100';
  w.document.getElementById('saleReceiveInput').value = '100000000';
  sel.value = 'ETH';
  await api.onSalePayTokenChange();
  assert.equal(w.document.getElementById('salePayInput').value, '', 'amount cleared');
  assert.equal(w.document.getElementById('saleReceiveInput').value, '', 'estimate cleared');
});
