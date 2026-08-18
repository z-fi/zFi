#!/usr/bin/env node
/**
 * Emit the successor deployment for zSwap v0.2.
 *
 * The page is already on chain by the time this runs: it lives in twelve data
 * contracts whose addresses are the only thing the successor needs. This turns
 * those twelve addresses into the two payloads the deploy actually consumes -
 * the successor's initcode, and the DAO calldata that hands it to the root's
 * `deployNext`. Nothing here signs or sends.
 *
 * Usage: node script/build-zSwapNext.mjs <12 chunk addresses> [--salt 0x..]
 */
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { AbiCoder, Interface, getAddress, keccak256, concat } from 'ethers';

const ROOT = '0x00000095643CFfA7D9fae407a84dfCB6406456c6';
const DAO = '0x5E58BA0e06ED0F5558f83bE732a4b899a674053E';
const HERE = path.dirname(fileURLToPath(import.meta.url));
const OUT = path.join(HERE, '..', 'out');

const args = process.argv.slice(2);
const si = args.indexOf('--salt');
const salt = si > -1 ? args[si + 1] : '0x' + '00'.repeat(32);
const chunks = args.filter((a, i) => a.startsWith('0x') && a.length === 42 && (si < 0 || i !== si + 1));

if (chunks.length !== 12) {
  console.error(`need exactly 12 chunk addresses, got ${chunks.length}`);
  console.error('usage: node script/build-zSwapNext.mjs 0xC1 0xC2 ... 0xC12 [--salt 0x..]');
  process.exit(1);
}
const seen = new Set(chunks.map(c => c.toLowerCase()));
if (seen.size !== 12) { console.error('duplicate chunk address — the constructor reverts InvalidData'); process.exit(1); }

const art = JSON.parse(fs.readFileSync(path.join(OUT, 'zSwap.sol', 'zSwap.json'), 'utf8'));
const creation = art.bytecode.object.startsWith('0x') ? art.bytecode.object : '0x' + art.bytecode.object;

// previous MUST be the root: deployNext staticcalls PREVIOUS() on the result
// and reverts NotASuccessor unless it equals the caller.
const ctorArgs = AbiCoder.defaultAbiCoder().encode(
  ['address', 'address', 'address[12]'], [DAO, ROOT, chunks.map(getAddress)]);
const initcode = concat([creation, ctorArgs]);

const predicted = '0x' + keccak256(concat(['0xff', ROOT, salt, keccak256(initcode)])).slice(-40);
const deployNext = new Interface(['function deployNext(bytes initcode, bytes32 salt) returns (address)'])
  .encodeFunctionData('deployNext', [initcode, salt]);

fs.writeFileSync(path.join(OUT, 'zSwapNext.initcode.txt'), initcode);
fs.writeFileSync(path.join(OUT, 'zSwapNext.deployNext.calldata.txt'), deployNext);

console.log('root (target)      ', ROOT);
console.log('DAO (must call)    ', DAO);
console.log('salt               ', salt);
console.log('initcode           ', (initcode.length / 2 - 1).toLocaleString('en-US'), 'B  -> out/zSwapNext.initcode.txt');
console.log('deployNext calldata', (deployNext.length / 2 - 1).toLocaleString('en-US'), 'B  -> out/zSwapNext.deployNext.calldata.txt');
console.log('successor address  ', getAddress(predicted), '(CREATE2, checkable before the vote)');
