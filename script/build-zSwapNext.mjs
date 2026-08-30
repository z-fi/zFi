#!/usr/bin/env node
/**
 * Emit the successor deployment for the current zSwap tip.
 *
 * The page is already on chain by the time this runs: it lives in thirteen data
 * contracts whose addresses are the only thing the successor needs. This turns
 * those thirteen addresses into the two payloads the deploy actually consumes -
 * the successor's initcode, and the DAO calldata that hands it to the tip's
 * `deployNext`. Nothing here signs or sends; it does READ the chain, to verify
 * the chunk list before anything is emitted.
 *
 * Usage: ETH_RPC_URL=https://… node script/build-zSwapNext.mjs <15 chunk addresses> [--salt 0x..]
 */
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { AbiCoder, Interface, JsonRpcProvider, getAddress, getBytes, keccak256, concat } from 'ethers';

// The version whose `deployNext` will run - the CURRENT tip, not the lineage
// root. Repoint this every succession. The successor's constructor reverts
// unless `previous == msg.sender`, and `deployNext`'s create2 makes that
// msg.sender the contract executing the deploy, so encoding anything but the
// executing version here mints a successor the chain refuses as NotASuccessor -
// after `AlreadySucceeded` has burned the only successor slot on it.
const TIP = '0xe686952842627A2cf81DF42CCaD54ef98046DB8D'; // zSwap v0.2
const DAO = '0x5E58BA0e06ED0F5558f83bE732a4b899a674053E';
const HERE = path.dirname(fileURLToPath(import.meta.url));
const OUT = path.join(HERE, '..', 'out');

const args = process.argv.slice(2);
const si = args.indexOf('--salt');
const salt = si > -1 ? args[si + 1] : '0x' + '00'.repeat(32);
// The wrapper's arity. The slice divisor and the loop bound must both come
// from here: they were 14 and 15 respectively, so the verification could
// never pass for any correctly built chunk set.
const CHUNKS = 16;
const chunks = args.filter((a, i) => a.startsWith('0x') && a.length === 42 && (si < 0 || i !== si + 1));

if (chunks.length !== CHUNKS) {
  console.error(`need exactly ${CHUNKS} chunk addresses, got ${chunks.length}`);
  console.error('usage: node script/build-zSwapNext.mjs 0xC1 0xC2 ... 0xC12 [--salt 0x..]');
  process.exit(1);
}
const seen = new Set(chunks.map(c => c.toLowerCase()));
if (seen.size !== CHUNKS) { console.error('duplicate chunk address — the constructor reverts InvalidData'); process.exit(1); }

// THE ONLY CHECK THAT MATTERS, MADE HERE. The initcode bakes the thirteen
// addresses in forever, and the constructor checks nothing but non-empty and
// pairwise-distinct — so a stale list (deploy/ still holds the v0.2
// succession's, which reassembles to the OLD page) or two addresses pasted
// swapped emits calldata that passes the constructor, passes both deployNext
// checks, and serves a wrong — or scrambled — page permanently, while every
// test stays green: the rehearsal suites deploy their own chunks from the
// tree, not the proposal payload's. So verify against the chain: each
// address's code must be EXACTLY its slice of zSwap.html.
const RPC = process.env.ETH_RPC_URL || process.env.MAINNET_RPC_URL;
if (!RPC) {
  console.error('ETH_RPC_URL is required — the chunk list is verified against the chain before anything is emitted');
  process.exit(1);
}
const provider = new JsonRpcProvider(RPC);
if ((await provider.getNetwork()).chainId !== 1n) {
  console.error(`connected to chain ${(await provider.getNetwork()).chainId}, expected mainnet (1) — refusing to emit against the wrong state`);
  process.exit(1);
}
const page = fs.readFileSync(path.join(HERE, '..', 'zSwap.html'));
const per = Math.ceil(page.length / CHUNKS);
for (let i = 0; i < CHUNKS; i++) {
  const code = Buffer.from(getBytes(await provider.getCode(getAddress(chunks[i]))));
  const want = page.subarray(i * per, Math.min((i + 1) * per, page.length));
  if (!code.equals(want)) {
    console.error(`chunk ${i + 1} (${chunks[i]}) is not its slice of zSwap.html: ${code.length} B on chain vs ${want.length} B expected`);
    console.error('stale or wrong chunk list — deploy the current page with deploy-zSwapNext.mjs first');
    process.exit(1);
  }
}
console.log(`verified: ${CHUNKS} chunk addresses reassemble to zSwap.html byte-for-byte (${page.length.toLocaleString('en-US')} B)`);

const art = JSON.parse(fs.readFileSync(path.join(OUT, 'zSwap.sol', 'zSwap.json'), 'utf8'));
const creation = art.bytecode.object.startsWith('0x') ? art.bytecode.object : '0x' + art.bytecode.object;

// previous MUST be the version executing the deploy: deployNext staticcalls
// PREVIOUS() on the result and reverts NotASuccessor unless it equals itself.
const ctorArgs = AbiCoder.defaultAbiCoder().encode(
  ['address', 'address', 'address[16]'], [DAO, TIP, chunks.map(getAddress)]);
const initcode = concat([creation, ctorArgs]);

const predicted = '0x' + keccak256(concat(['0xff', TIP, salt, keccak256(initcode)])).slice(-40);
const deployNext = new Interface(['function deployNext(bytes initcode, bytes32 salt) returns (address)'])
  .encodeFunctionData('deployNext', [initcode, salt]);

fs.writeFileSync(path.join(OUT, 'zSwapNext.initcode.txt'), initcode);
fs.writeFileSync(path.join(OUT, 'zSwapNext.deployNext.calldata.txt'), deployNext);

console.log('tip (deployNext)   ', TIP);
console.log('DAO (must call)    ', DAO);
console.log('salt               ', salt);
console.log('initcode           ', (initcode.length / 2 - 1).toLocaleString('en-US'), 'B  -> out/zSwapNext.initcode.txt');
console.log('deployNext calldata', (deployNext.length / 2 - 1).toLocaleString('en-US'), 'B  -> out/zSwapNext.deployNext.calldata.txt');
console.log('successor address  ', getAddress(predicted), '(CREATE2, checkable before the vote)');
