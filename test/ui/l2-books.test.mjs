/**
 * The book, the route and the launcher are per-chain.
 *
 * Mainnet's boards were placed by SafeSummoner CREATE2 with mainnet's WETH in
 * their initcode, so a mirror on Base or Robinhood cannot share their address.
 * The L2 builds sit at one CREATE3 address on both L2s, and the page carries
 * that table as `L2B`, rebinding SB2/SWAPBOL/DUTCH/ORDERBOL/FLOOR/PROUTE in
 * setChain. Two things have no mirror at all and must read as absent there:
 * the legacy v1 board, and the cause-coin launcher (mainnet-only by decision).
 */
import { test, after } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { A, MockChain, loadPage, closeAllPages } from './harness.mjs';

after(closeAllPages);

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..');
const MANIFEST = JSON.parse(fs.readFileSync(path.join(ROOT, 'deploy', 'l2', 'manifest.json'), 'utf8'));
const c3 = name => MANIFEST.create3[name].address.toLowerCase();
const lower = s => String(s).toLowerCase();

const settle = () => new Promise(r => setTimeout(r, 400));

test('mainnet binds the mainnet book, both board generations and the launcher', async () => {
  const p = await loadPage();
  await settle();
  const w = p.window;
  assert.equal(w.eval('CHAIN_ID'), 1);
  assert.equal(lower(w.eval('SB2')), lower(A.SB2));
  assert.equal(lower(w.eval('SB1')), lower(A.SB1));
  assert.equal(lower(w.eval('SWAPBOL')), lower(A.SWAPBOL));
  assert.equal(lower(w.eval('ORDERBOL')), lower(A.ORDERBOL));
  assert.equal(lower(w.eval('FLOOR')), lower(A.FLOOR));
  assert.equal(lower(w.eval('PROUTE')), lower(A.PROUTE));
  assert.notEqual(lower(w.eval('PLAUNCH')), A.ZERO);
  assert.equal(w.eval('BOARDS().length'), 2, 'v1 is scanned on mainnet');
  assert.equal(w.document.getElementById('ln').classList.contains('hide'), false, 'launch mode offered');
});

test('Base binds the shared L2 book table, has no v1 board, and launches coins but not causes', async () => {
  const chain = new MockChain({ chainId: '0x2105' });
  const p = await loadPage({ chain });
  await settle();
  const w = p.window;
  assert.equal(w.eval('CHAIN_ID'), 8453);
  assert.equal(lower(w.eval('SB2')), c3('Swapboard'));
  assert.equal(lower(w.eval('DUTCH')), c3('Dutchboard'));
  assert.equal(lower(w.eval('FLOOR')), c3('Floorboard'));
  assert.equal(lower(w.eval('SWAPBOL')), c3('SwapbolL2'));
  assert.equal(lower(w.eval('ORDERBOL')), c3('OrderbolL2'));
  assert.equal(lower(w.eval('PROUTE')), c3('PrecisionRouteL2'));
  assert.equal(lower(w.eval('SB1')), A.ZERO, 'no legacy board on Base');
  // The launcher is a replay too, so coins launch through one address everywhere.
  assert.equal(lower(w.eval('PLAUNCH')), lower(w.eval('MB.la')), 'the mainnet launcher address');
  assert.equal(w.eval('BOARDS().length'), 1, 'only the current board is scanned');
  assert.equal(w.document.getElementById('ln').classList.contains('hide'), false, 'launch mode offered');
  assert.equal(w.eval(`lnKind.querySelector('option[value="cause"]').disabled`), true, 'causes are Ethereum-only');
  // The views and the pool suite are byte-identical replays at the mainnet
  // vanity addresses, so those names do not move.
  assert.equal(lower(w.eval('SBVIEW')), lower(A.SBVIEW));
  assert.equal(lower(w.eval('PFACTORY')), lower(A.PFACTORY));
});

test('Robinhood shares the Base table', async () => {
  const chain = new MockChain({ chainId: '0x1237' });
  const p = await loadPage({ chain });
  await settle();
  const w = p.window;
  assert.equal(w.eval('CHAIN_ID'), 4663);
  assert.equal(lower(w.eval('SB2')), c3('Swapboard'));
  assert.equal(lower(w.eval('SWAPBOL')), c3('SwapbolL2'));
  assert.equal(lower(w.eval('PROUTE')), c3('PrecisionRouteL2'));
  assert.equal(lower(w.eval('PLAUNCH')), lower(w.eval('MB.la')));
  assert.equal(w.eval(`lnKind.querySelector('option[value="cause"]').disabled`), true);
});

test('a coin launched on Base is sent to the launcher, on Base', async () => {
  const chain = new MockChain({ chainId: '0x2105' });
  chain.setNative(A.ACCOUNT, 10n ** 19n);
  const p = await loadPage({ chain });
  await p.connect();
  p.click('ln');
  p.type('lnName', 'Layer Cat');
  p.type('lnSym', 'LCAT');
  p.type('lnSupply', '1000000000');
  p.type('lnMcap', '3');
  p.click('lnGo');
  await p.waitFor(() => chain.sent.length > 0, { label: 'the launch call' });
  await p.settle();
  assert.equal(chain.chainId, '0x2105', 'still on Base');
  assert.equal(lower(chain.sent[0].to), lower(p.window.eval('MB.la')), 'sent to the launcher');
});
