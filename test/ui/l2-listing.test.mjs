/**
 * The token list on an L2 comes from the mainnet registry, filtered by chain.
 *
 * A Base listing is a foreign eip155:8453 entry on the canonical TokenList; the
 * page keeps rows whose namespace and chain match the wallet's chain and drops
 * the rest. Foreign rows are owner-typed - there is no on-chain source for
 * their decimals on mainnet - so the page reads `decimals()` from the token on
 * the chain it is on and refuses a row that disagrees, because a wrong scale
 * would mis-size every amount typed against it. An `origin` extra (a bridged
 * Bitcoin asset, say) is surfaced in the description so a bridged asset is
 * never mistaken for the native one.
 */
import { test, after } from 'node:test';
import assert from 'node:assert/strict';
import { A, MockChain, loadPage, fixedRateQuoter, closeAllPages } from './harness.mjs';

after(closeAllPages);

const ETH = 10n ** 18n;
const LOGO = 'data:image/gif;base64,R0lGODlhAQABAAAAACH5BAEKAAEALAAAAAABAAEAAAICTAEAOw==';
const BASE_USDC = '0x833589fcd6edb6e08f4c7c32d4f71b54bda02913';
const BASE_CBBTC = '0xcbb7c0000ab88b473b1f5afd9ef808440eed33bf';
const BASE_BAD = '0x00000000000000000000000000000000000bad01';

const row = (sym, addr, over = {}) => ({
  i: '1', c: 8453, k: 'eip155', p: 'ERC-20', x: true, o: false, f: false,
  a: addr, n: `${sym} on Base`, s: sym, d: 18, t: '#888', r: 1,
  u: '', au: '', l: LOGO, desc: `${sym} described by the registry.`, e: [], v: true, ...over,
});
const ROWS = [
  row('USDC', BASE_USDC, { d: 6, e: [{ k: 'eq', v: 'eip155:1:' + A.USDC.toLowerCase() }] }),
  row('cbBTC', BASE_CBBTC, { d: 8, e: [{ k: 'origin', v: 'bitcoin' }] }),
  // Typed with the wrong scale: the token itself says 6.
  row('BADSCALE', BASE_BAD, { d: 18 }),
  // A mainnet row must not leak into the Base list.
  row('WBTC', A.WBTC, { c: 1, d: 8 }),
];

async function openBase() {
  const chain = new MockChain({ chainId: '0x2105' });
  chain.registry = ROWS;
  chain.conviction = ROWS.map((_, i) => i + 1);
  chain.setNative(A.ACCOUNT, 10n * ETH);
  chain.quoteHandler = fixedRateQuoter({ rate: 3000n * ETH });
  chain.setToken(BASE_USDC, { symbol: 'USDC', decimals: 6, name: 'USD Coin' });
  chain.setToken(BASE_CBBTC, { symbol: 'cbBTC', decimals: 8, name: 'Coinbase Wrapped BTC' });
  chain.setToken(BASE_BAD, { symbol: 'BADSCALE', decimals: 6, name: 'Mis-typed' });
  const p = await loadPage({ chain, hash: null });
  await p.waitFor(() => p.window.eval('listLive'), { label: 'the registry list to load' });
  return p;
}

test('Base lists the registry rows for 8453 and nothing from mainnet', async () => {
  const p = await openBase();
  const w = p.window;
  assert.equal(w.eval('CHAIN_ID'), 8453);
  const syms = w.eval('TOKENS.map(t=>t.sym)');
  assert.ok(syms.includes('USDC'), `USDC listed: ${syms}`);
  assert.ok(syms.includes('cbBTC'), `cbBTC listed: ${syms}`);
  assert.ok(!syms.includes('WBTC'), `a mainnet row leaked: ${syms}`);
  assert.equal(w.eval('TOKENS.find(t=>t.sym==="USDC").addr'), BASE_USDC);
  assert.equal(w.eval('TOKENS.find(t=>t.sym==="USDC").dec'), 6);
  assert.ok(w.eval('TOKENS.find(t=>t.sym==="USDC").icon').includes(LOGO), 'registry logo used');
  p.close();
});

test('a foreign row whose decimals disagree with the token is dropped, and says so', async () => {
  const p = await openBase();
  const syms = p.window.eval('TOKENS.map(t=>t.sym)');
  assert.ok(!syms.includes('BADSCALE'), `mis-scaled row survived: ${syms}`);
  assert.match(p.text('listNote'), /1 listing dropped: decimals differ on chain/);
  p.close();
});

test('an origin extra is carried into the description', async () => {
  const p = await openBase();
  assert.match(p.window.eval('TOKENS.find(t=>t.sym==="cbBTC").desc'), /bitcoin origin/);
  assert.doesNotMatch(p.window.eval('TOKENS.find(t=>t.sym==="USDC").desc'), /origin/);
  p.close();
});

test('with nothing listed for the chain, the built-in list stays and names the reason', async () => {
  const chain = new MockChain({ chainId: '0x2105' });
  chain.registry = [row('WBTC', A.WBTC, { c: 1, d: 8 })];
  chain.conviction = [1];
  chain.setNative(A.ACCOUNT, 10n * ETH);
  chain.quoteHandler = fixedRateQuoter({ rate: 3000n * ETH });
  const p = await loadPage({ chain, hash: null });
  await p.waitFor(() => /registry returned nothing swappable/.test(p.text('listNote')), { label: 'the fallback note' });
  const syms = p.window.eval('TOKENS.map(t=>t.sym)');
  for (const s of ['ETH', 'WETH', 'USDC', 'USDT', 'wstETH', 'rETH', 'cbBTC', 'DAI']) assert.ok(syms.includes(s), `${s} in the built-in Base list: ${syms}`);
  p.close();
});
