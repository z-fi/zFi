#!/usr/bin/env node
/**
 * Mine a CREATE2 salt so the v0.3 wrapper lands on a vanity address.
 *
 * `deployNext` does `create2(0, initcode, salt)` FROM THE TIP, so the address
 * is keccak(0xff ++ tip ++ salt ++ keccak(initcode))[12:]. Only `salt` is free:
 * the tip is the live v0.2 contract and the initcode is fixed by the sixteen
 * chunk addresses baked into the constructor args. So this must run AFTER the
 * chunks are deployed - mine against a different initcode and the salt is
 * worthless, silently, because it still produces *an* address, just not one
 * with the prefix.
 *
 * The house style is three leading zero BYTES (0x000000...), matching zSwap,
 * zSwapResolver, TokenList and Swapboard. That is one in 16^6 ~ 16.8M, which
 * is seconds of work, not hours - there is no reason to accept fewer.
 *
 * Usage:
 *   node script/mine-zSwapNext-salt.mjs                     # uses out/zSwapNext.initcode.txt
 *   node script/mine-zSwapNext-salt.mjs --prefix 000000 --initcode 0x60..
 */
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { keccak_256 } from '@noble/hashes/sha3';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const argv = process.argv.slice(2);
const arg = (k, d) => { const i = argv.indexOf(k); return i > -1 ? argv[i + 1] : d; };

const TIP = arg('--tip', '0x00000095643CFfA7D9fae407a84dfCB6406456c6');
const PREFIX = arg('--prefix', '000000').toLowerCase().replace(/^0x/, '');
if (!/^[0-9a-f]*$/.test(PREFIX)) throw new Error('prefix must be hex');

let initcode = arg('--initcode', '');
if (!initcode) {
  const p = path.join(ROOT, 'out', 'zSwapNext.initcode.txt');
  if (!fs.existsSync(p)) {
    console.error('no initcode: run script/build-zSwapNext.mjs first (it needs the 16 deployed chunk addresses)');
    process.exit(1);
  }
  initcode = fs.readFileSync(p, 'utf8').trim();
}
const hex = s => Uint8Array.from((s.replace(/^0x/, '').match(/../g) || []).map(b => parseInt(b, 16)));

// keccak(initcode) is CONSTANT across every attempt, so hash it once. The inner
// loop then hashes exactly 85 bytes and nothing else.
const initHash = keccak_256(hex(initcode));
const tip = hex(TIP);
if (tip.length !== 20) throw new Error('tip must be a 20-byte address');

const buf = new Uint8Array(85);
buf[0] = 0xff;
buf.set(tip, 1);
buf.set(initHash, 53);

const t0 = Date.now();
let tries = 0;
const salt = new Uint8Array(32);
// A random high half keeps two people mining the same initcode off each other's
// salts; the low 8 bytes are the counter.
crypto.getRandomValues(salt.subarray(0, 24));

const toHex = b => [...b].map(x => x.toString(16).padStart(2, '0')).join('');

// Split the prefix into whole bytes plus an optional trailing nibble, so the
// inner loop never touches a string.
const wholeBytes = PREFIX.length >> 1;
const prefixBytes = hex(PREFIX.slice(0, wholeBytes * 2));
const halfNibble = PREFIX.length % 2 ? parseInt(PREFIX[PREFIX.length - 1], 16) : -1;

for (;;) {
  /* CARRY BY READING THE ARRAY BACK, NOT THE ++ EXPRESSION. On a Uint8Array,
     `++salt[i]` evaluates to the UNTRUNCATED value - 255 stores 0 but the
     expression is 256 - so `!== 0` was always true, the carry never propagated
     past the last byte, and the whole search ran over 256 distinct salts
     forever. It still "worked" for a one-nibble prefix, which is exactly the
     kind of pass that hides this. */
  for (let i = 31; i >= 24; i--) { salt[i] = (salt[i] + 1) & 0xff; if (salt[i] !== 0) break; }
  buf.set(salt, 21);
  const h = keccak_256(buf);
  tries++;
  // COMPARE BYTES, NOT A STRING. Rendering the address to hex on every attempt
  // allocates an array, a map and a join per try and costs about four times the
  // hash itself - the one operation this loop exists to repeat.
  let hit = true;
  for (let k = 0; k < wholeBytes; k++) if (h[12 + k] !== prefixBytes[k]) { hit = false; break; }
  if (hit && halfNibble >= 0 && (h[12 + wholeBytes] >> 4) !== halfNibble) hit = false;
  if (hit) {
    const addr = toHex(h.subarray(12));
    const secs = (Date.now() - t0) / 1000;
    const out = {
      tip: TIP,
      salt: '0x' + toHex(salt),
      address: '0x' + addr,
      initcodeHash: '0x' + toHex(initHash),
      prefix: PREFIX,
      tries,
      seconds: +secs.toFixed(1),
    };
    fs.mkdirSync(path.join(ROOT, 'out'), { recursive: true });
    fs.writeFileSync(path.join(ROOT, 'out', 'zSwapNext.salt.json'), JSON.stringify(out, null, 2) + '\n');
    console.log(`found after ${tries.toLocaleString('en-US')} tries in ${secs.toFixed(1)}s`);
    console.log('salt   ', out.salt);
    console.log('address', out.address);
    console.log('wrote  out/zSwapNext.salt.json');
    break;
  }
  if (tries % 2_000_000 === 0) {
    console.log(`  ${(tries / 1e6).toFixed(0)}M tries, ${(tries / ((Date.now() - t0) / 1000) / 1e3).toFixed(0)}k/s`);
  }
}
