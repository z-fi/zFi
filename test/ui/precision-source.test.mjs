/**
 * Precision pools as a zFi swap source.
 *
 * zQuoter covers Uniswap, Sushi, Curve, zAMM and Lido; the external aggregators cover
 * whatever their indexers hold. Precision pools are in neither. Asked for ETH -> CELL,
 * a coin whose only market is a precision band, zQuoter returns amountOut 0 on all
 * fourteen of its sources, so the page reported no route while a funded pool sat there.
 *
 * The calldata here is checked against what the live pool actually paid on a fork:
 * 0.001 ETH in returned 120.768363385720399579 CELL, and the built multicall executed
 * for exactly that. This test pins the encoding that produced it — selector, argument
 * order, the checkpoint leg, and which side carries msg.value — because every one of
 * those is silent when wrong and only shows up as a revert or a drained approval.
 */
import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { ethers } from 'ethers';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..');
const html = fs.readFileSync(path.join(ROOT, 'dapp/index.html'), 'utf8');
const grab = re => { const m = html.match(re); assert.ok(m, 'not found: ' + re); return m[0]; };

const ROUTER_IFACE = new ethers.Interface([
  'function multicall(bytes[]) payable returns (bytes[])',
  'function snwap(address tokenIn,uint256 amountIn,address recipient,address tokenOut,uint256 amountOutMin,address executor,bytes executorData) payable returns (uint256)',
]);
const M = new Function('ethers', 'ROUTER_IFACE', [
  "const ZERO_ADDRESS='0x0000000000000000000000000000000000000000';",
  grab(/const PPLENS_ADDRESS = [\s\S]*?const _pw = [^\n]*/),
  grab(/function buildPrecisionMulticall[\s\S]*?\n}/),
  'return { buildPrecisionMulticall, PROUTE_ADDRESS, PPLENS_ADDRESS };',
].join('\n'))(ethers, ROUTER_IFACE);

const ZERO = '0x0000000000000000000000000000000000000000';
const CELL = '0xf142CfA6Ca3DFa4A131f12aACEF4890e390d70D6';
const POOL = '0xaf9f2e884798e4b63abc9fc6879cd74bd21c8157';
const ME = '0x1C0Aa8cCD568d90d61659F060D1bFb1e6f855A20';

test('buying with ETH is a single funded leg', () => {
  const amt = ethers.parseEther('0.001');
  const b = M.buildPrecisionMulticall(ZERO, CELL, amt, 1n, ME, POOL);
  const calls = ROUTER_IFACE.decodeFunctionData('multicall', b.multicall)[0];
  assert.equal(calls.length, 1, 'native in needs no checkpoint: nothing is pulled');
  // The router is funded by the call itself, so the value must ride along.
  assert.equal(b.msgValue, amt);

  const [tokenIn, amountIn, , tokenOut, , executor] =
    ROUTER_IFACE.decodeFunctionData('snwap', calls[0]);
  assert.equal(tokenIn, ZERO);
  assert.equal(tokenOut, CELL);
  assert.equal(amountIn, amt, 'PROUTE reads the amount from the leg, not from the value');
  assert.equal(executor.toLowerCase(), M.PROUTE_ADDRESS.toLowerCase());
});

test('selling a token pulls, so it carries a checkpoint and no value', () => {
  const amt = ethers.parseEther('500');
  const b = M.buildPrecisionMulticall(CELL, ZERO, amt, 1n, ME, POOL);
  const calls = ROUTER_IFACE.decodeFunctionData('multicall', b.multicall)[0];
  assert.equal(calls.length, 2, 'a pull without its checkpoint is spendable by another route');
  assert.equal(b.msgValue, 0n, 'nothing is being sent: the router pulls');

  const [cpIn, cpAmt, , , , cpExec, cpData] = ROUTER_IFACE.decodeFunctionData('snwap', calls[0]);
  assert.equal(cpIn, ZERO);
  assert.equal(cpAmt, 0n, 'the checkpoint moves nothing, it only binds');
  assert.equal(cpExec.toLowerCase(), M.PROUTE_ADDRESS.toLowerCase());

  // The checkpoint must commit to the hash of the route it guards, not some other route.
  const [, , , , , , routeData] = ROUTER_IFACE.decodeFunctionData('snwap', calls[1]);
  assert.ok(cpData.toLowerCase().includes(ethers.keccak256(routeData).slice(2).toLowerCase()),
    'checkpoint does not bind the route it precedes');
});

test('the route names the pool it was quoted against', () => {
  const b = M.buildPrecisionMulticall(ZERO, CELL, 1000n, 1n, ME, POOL);
  const calls = ROUTER_IFACE.decodeFunctionData('multicall', b.multicall)[0];
  const [, , , , , , routeData] = ROUTER_IFACE.decodeFunctionData('snwap', calls[0]);
  assert.ok(routeData.toLowerCase().includes(POOL.slice(2).toLowerCase()),
    'a route that does not name its pool can be filled anywhere');
});

test('the page still declares the source it races', () => {
  // Losing any of these silently reverts zFi to "no route" for precision-only coins.
  for (const needed of ['quotePrecisionBest', 'addPrecisionCandidate', '_racePrecision'])
    assert.match(html, new RegExp('function ' + needed + '\\b'), `${needed} went missing`);
  assert.match(html, /_racePrecision\(q, args\)/, 'the race must stay wired into _runQuote');
  assert.match(html, /r\.isPrecision = false/, 'isPrecision must clear with the other winner flags');
});
