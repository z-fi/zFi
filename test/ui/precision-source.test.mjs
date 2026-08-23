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
  grab(/const PPLENS_ADDRESS = [\s\S]*?const _pWord = [^\n]*/),
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

test('precision answers when nothing else does, which is the case it exists for', async () => {
  // getQuote THROWS on a pair no source can route — "Best swap quote failed" — instead of
  // returning an empty result. The race was attached with .then(), which never runs on a
  // rejection, so it stayed silent on exactly the pools it was written to find. zQuoter
  // returns amountOut 0 on all fourteen of its sources for ETH -> CELL.
  const src = fs.readFileSync(path.join(ROOT, 'dapp/index.html'), 'utf8');
  assert.match(src, /_racePrecision\(q, args\), err => _precisionOnly\(args, err\)/,
    'the rejection handler must be wired, not just the fulfilment one');

  const grabf = re => { const m = src.match(re); assert.ok(m, 'not found: ' + re); return m[0]; };
  const ZERO = '0x0000000000000000000000000000000000000000';
  const CELL = '0xf142CfA6Ca3DFa4A131f12aACEF4890e390d70D6';
  const POOL = '0xaf9f2e884798e4b63abc9fc6879cd74bd21c8157';

  // A stub pool: quoteBest answers, so the only thing under test is the rescue itself.
  const RPC = { call: async ({ data }) =>
    data.startsWith('0x2adaa389')
      ? '0x' + POOL.slice(2).padStart(64, '0') + (12345n).toString(16).padStart(64, '0')
      : '0x' };

  const M = new Function('ethers', 'ROUTER_IFACE', 'RPC', [
    `const ZERO_ADDRESS='${ZERO}';`,
    `const tokens={ETH:{address:'${ZERO}',decimals:18},CELL:{address:'${CELL}',decimals:18}};`,
    'const slippageBps=100;',
    `const _connectedAddress='${ZERO}';`,
    `const getReceiver=()=>'${ZERO}';`,
    'const safeParseUnits=(v,d)=>ethers.parseUnits(String(v),d);',
    'const quoteRPC={call:fn=>fn(RPC)};',
    grabf(/const PPLENS_ADDRESS = [\s\S]*?const _pWord = [^\n]*/),
    grabf(/async function quotePrecisionBest[\s\S]*?\n}/),
    grabf(/function buildPrecisionMulticall[\s\S]*?\n}/),
    grabf(/async function _precisionOnly[\s\S]*?\n}/),
    'return { _precisionOnly };',
  ].join('\n'))(ethers, ROUTER_IFACE, RPC);

  const boom = new Error('Best swap quote failed');
  const q = await M._precisionOnly({ fromSnap: 'ETH', toSnap: 'CELL', amtStr: '0.001', exactOut: false }, boom);

  assert.equal(q.sourceA, 'Precision');
  assert.equal(q.expectedOutput, 12345n);
  assert.equal(q.msgValue, ethers.parseEther('0.001'), 'native in must fund the call');
  assert.equal(q.precisionPool.toLowerCase(), POOL.toLowerCase());
  assert.equal(ROUTER_IFACE.decodeFunctionData('multicall', q.multicall)[0].length, 1);
  // The renderer reads these; a quote missing them paints undefined.
  for (const k of ['expectedOutput', 'requiredInput', 'sourceA', 'isTwoHop', 'isSplit', 'allQuotes'])
    assert.ok(k in q, `the renderer reads quote.${k}`);

  // Exact-out has no lens behind it, so it must hand back the original failure untouched
  // rather than invent an answer.
  await assert.rejects(
    () => M._precisionOnly({ fromSnap: 'ETH', toSnap: 'CELL', amtStr: '0.001', exactOut: true }, boom),
    /Best swap quote failed/);
});
