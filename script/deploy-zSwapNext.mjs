#!/usr/bin/env node
/**
 * Deploy the next zSwap generation: the fourteen data chunks, then the calldata
 * the DAO needs.
 *
 * WHAT THIS DOES AND DOES NOT DO. The chunks are plain data contracts - no
 * owner, no authority, nothing but bytes - so whoever pays the gas is
 * irrelevant to what the page becomes. This script sends those thirteen, checks
 * each one's deployed code against the payload byte for byte, and stops.
 *
 * It CANNOT deploy the successor. `deployNext` reverts `NotDAO` for anyone but
 * the DAO, so the last step is a governance vote, not a transaction anyone here
 * can send. What this prints at the end is the calldata that proposal carries.
 *
 * The key is read from PRIVATE_KEY in the environment and never echoed. Pass
 * --dry-run to do everything except broadcast.
 *
 * Usage:
 *   PRIVATE_KEY=0x… node script/deploy-zSwapNext.mjs --dry-run
 *   PRIVATE_KEY=0x… node script/deploy-zSwapNext.mjs --rpc https://…
 */
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { JsonRpcProvider, Wallet, formatEther } from 'ethers';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const ROOT_DIR = path.join(HERE, '..');
const OUT = path.join(ROOT_DIR, 'out');
const CHUNKS = 16;

const argv = process.argv.slice(2);
const DRY = argv.includes('--dry-run');
const rpcAt = argv.indexOf('--rpc');
const RPC = rpcAt > -1 ? argv[rpcAt + 1] : process.env.ETH_RPC_URL || 'https://ethereum.publicnode.com';

const die = (m) => { console.error(`\n  ${m}\n`); process.exit(1); };

// The page these chunks must reassemble to. Checked here rather than trusted:
// a stale out/ directory would deploy a different dapp than the one that was
// reviewed, and the chunks are immutable once sent.
const page = fs.readFileSync(path.join(ROOT_DIR, 'zSwap.html'));
const payloads = [];
for (let i = 1; i <= CHUNKS; i++) {
  const f = path.join(OUT, `zSwap.chunk${i}.creation.txt`);
  if (!fs.existsSync(f)) die(`${path.relative(ROOT_DIR, f)} is missing — run: node script/build-zSwap-chunks.mjs`);
  const hex = fs.readFileSync(f, 'utf8').trim().replace(/^0x/, '');
  payloads.push('0x' + hex);
}
// Each chunk's initcode is the data-contract stub; the runtime it returns is
// the payload after the 10-byte prologue.
const rebuilt = Buffer.concat(payloads.map(p => Buffer.from(p.slice(2 + 20), 'hex')));
if (!rebuilt.equals(page)) {
  die(`the chunks in out/ do not reassemble to zSwap.html (${rebuilt.length} B vs ${page.length} B)\n  run: node script/build-zSwap-chunks.mjs`);
}
console.log(`chunks verified: ${CHUNKS} payloads reassemble to zSwap.html (${page.length.toLocaleString('en-US')} B)`);

const pk = process.env.PRIVATE_KEY;
if (!pk) die('PRIVATE_KEY is not set. Export it in your shell; it is never read from anywhere else.');

const provider = new JsonRpcProvider(RPC);
const wallet = new Wallet(pk, provider);
const net = await provider.getNetwork();
if (net.chainId !== 1n) die(`connected to chain ${net.chainId}, expected mainnet (1)`);

const bal = await provider.getBalance(wallet.address);
const feeData = await provider.getFeeData();
const gasPrice = feeData.maxFeePerGas ?? feeData.gasPrice ?? 0n;
const estimate = 5_300_000n * BigInt(CHUNKS) * gasPrice;

console.log(`deployer     ${wallet.address}`);
console.log(`balance      ${formatEther(bal)} ETH`);
console.log(`gas price    ${Number(gasPrice) / 1e9} gwei`);
console.log(`est. cost    ~${formatEther(estimate)} ETH for ${CHUNKS} chunks`);
if (bal < estimate) die(`balance is below the estimate — fund ${wallet.address} first`);

if (DRY) { console.log('\n--dry-run: nothing broadcast.\n'); process.exit(0); }

const deployed = [];
for (let i = 0; i < CHUNKS; i++) {
  process.stdout.write(`chunk${i + 1}/${CHUNKS} … `);
  const tx = await wallet.sendTransaction({ data: payloads[i] });
  const rc = await tx.wait();
  if (!rc || rc.status !== 1) die(`chunk${i + 1} reverted (tx ${tx.hash})`);
  const addr = rc.contractAddress;
  // Byte-for-byte, because a truncated chunk serves a broken page forever.
  const code = await provider.getCode(addr);
  const want = '0x' + payloads[i].slice(2 + 20);
  if (code.toLowerCase() !== want.toLowerCase()) die(`chunk${i + 1} at ${addr} does not match its payload`);
  deployed.push(addr);
  console.log(`${addr}  (${tx.hash})`);
}

fs.writeFileSync(path.join(OUT, 'zSwapNext.chunks.txt'), deployed.join('\n') + '\n');
console.log(`\nall ${CHUNKS} chunks deployed and verified -> out/zSwapNext.chunks.txt`);
console.log(`\nnext, build the proposal payload:\n  node script/build-zSwapNext.mjs ${deployed.join(' ')}`);
console.log(`\nthen the DAO calls deployNext on the CURRENT TIP - the contract the emitted calldata targets,`);
console.log(`not the lineage root. No key here can do that step.`);
