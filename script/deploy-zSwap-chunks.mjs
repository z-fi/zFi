#!/usr/bin/env node
/**
 * Deploy the zSwap page chunks, one transaction each.
 *
 * RESUMABLE ON PURPOSE. This spends real money for ~80M gas, and a run that
 * dies on chunk 11 must not redeploy the ten that already landed. Every
 * confirmed address is written to out/zSwap.chunks.deployed.json immediately,
 * and a re-run skips any entry whose on-chain code already matches its
 * expected payload byte-for-byte.
 *
 * VERIFIED, NOT ASSUMED. A receipt says a contract exists, not that it holds
 * the right bytes. Each chunk's runtime code is read back and compared to the
 * payload it was built from; a mismatch stops the run rather than letting a
 * corrupt chunk reach the wrapper's constructor, where it would be baked into
 * an immutable address list.
 *
 * Usage: PRIVATE_KEY=0x.. ETH_RPC_URL=https://.. node script/deploy-zSwap-chunks.mjs [--dry-run] [--min-tip-gwei 0.5] [--max-base-gwei 0.1]
 *
 * --max-base-gwei waits, before each chunk, until the base fee is at or under the cap, so a run can be
 * left going and spends only at the price chosen. Each chunk's gas limit is its own estimate plus 10%.
 */
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { JsonRpcProvider, Wallet, formatEther } from 'ethers';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
// The wrapper's constructor arity is the one count that cannot be changed after the
// chunks are paid for, so read it rather than restate it.
const ARITY = fs.readFileSync(path.join(ROOT, 'src', 'zSwap.sol'), 'utf8')
  .match(/constructor\(address dao, address previous, address\[(\d+)\] memory d\)/);
if (!ARITY) throw new Error("could not read zSwap.sol's constructor arity");
const N = Number(ARITY[1]);
const DRY = process.argv.includes('--dry-run');
const tipAt = process.argv.indexOf('--min-tip-gwei');
const FLOOR = BigInt(Math.round(Number(tipAt > -1 ? process.argv[tipAt + 1] : '0.5') * 1e9));
const capAt = process.argv.indexOf('--max-base-gwei');
const CAP = capAt > -1 ? BigInt(Math.round(Number(process.argv[capAt + 1]) * 1e9)) : null;
const REC = path.join(ROOT, 'out', 'zSwap.chunks.deployed.json');

const RPC = process.env.ETH_RPC_URL || 'https://ethereum-rpc.publicnode.com';
const key = process.env.PRIVATE_KEY;
if (!key && !DRY) throw new Error('set PRIVATE_KEY');

const provider = new JsonRpcProvider(RPC);
const wallet = key ? new Wallet(key, provider) : null;

// The payload each chunk must end up holding: its slice of the page. The
// creation file is the stub plus that payload, so the payload is the tail.
const page = fs.readFileSync(path.join(ROOT, 'zSwap.html'));
const per = Math.ceil(page.length / N);
const slices = [];
for (let i = 0; i < N; i++) slices.push(page.subarray(i * per, Math.min((i + 1) * per, page.length)));

const creations = [];
for (let i = 1; i <= N; i++) {
  const p = path.join(ROOT, 'out', `zSwap.chunk${i}.creation.txt`);
  creations.push(fs.readFileSync(p, 'utf8').trim());
}
if (!Buffer.concat(creations.map(c => Buffer.from(c.replace(/^0x/, '').slice(20), 'hex'))).equals(page)) {
  throw new Error('the chunks in out/ do not reassemble to zSwap.html - run: node script/build-zSwap-chunks.mjs');
}

let rec = {};
if (fs.existsSync(REC)) rec = JSON.parse(fs.readFileSync(REC, 'utf8'));

const hexOf = buf => '0x' + buf.toString('hex');

let dryGas = 0n;
async function main() {
  const net = await provider.getNetwork();
  console.log(`network  ${net.name} (${net.chainId})`);
  if (wallet) {
    console.log(`deployer ${wallet.address}`);
    console.log(`balance  ${formatEther(await provider.getBalance(wallet.address))} ETH`);
  }
  console.log(`page     ${page.length.toLocaleString('en-US')} B across ${N} chunks\n`);

  for (let i = 0; i < N; i++) {
    const n = i + 1, want = hexOf(slices[i]);

    // Already done? Only if the chain agrees, not just the record.
    const known = rec[`chunk${n}`];
    if (known) {
      const code = await provider.getCode(known);
      if (code.toLowerCase() === want.toLowerCase()) { console.log(`chunk${n}  ${known}  (already deployed, verified)`); continue; }
      console.log(`chunk${n}  ${known} recorded but its code does not match — redeploying`);
    }

    const est = await provider.estimateGas({ data: creations[i], from: wallet ? wallet.address : undefined });
    if (DRY) {
      dryGas += est;
      console.log(`chunk${n}  ~${est.toLocaleString('en-US')} gas (dry run)`);
      continue;
    }

    if (CAP != null) {
      for (;;) {
        const base = (await provider.getBlock('latest')).baseFeePerGas;
        if (base <= CAP) break;
        console.log(`chunk${n}  waiting: base fee ${(Number(base) / 1e9).toFixed(4)} gwei is above the ${(Number(CAP) / 1e9).toFixed(4)} cap`);
        await new Promise(r => setTimeout(r, 60000));
      }
    }

    // A real tip and an explicit pending nonce: this key is shared with other senders, and a
    // transaction that idles in the mempool has its nonce taken from under it. Mine promptly, and
    // if the nonce is taken anyway, stop with a clear message - the run is resumable.
    for (let w = 0; ; w++) {
      const [lat, pen] = await Promise.all([provider.getTransactionCount(wallet.address, 'latest'), provider.getTransactionCount(wallet.address, 'pending')]);
      if (lat === pen) break;
      if (w % 4 === 0) console.log(`chunk${n}  waiting: another sender from this key has a transaction in flight (nonce ${lat} -> ${pen})`);
      await new Promise(r => setTimeout(r, 15000));
    }
    const fd = await provider.getFeeData();
    const tip = (fd.maxPriorityFeePerGas || 0n) > FLOOR ? fd.maxPriorityFeePerGas : FLOOR;
    const nonce = await provider.getTransactionCount(wallet.address, 'pending');
    const tx = await wallet.sendTransaction({ data: creations[i], nonce, gasLimit: est * 110n / 100n, maxPriorityFeePerGas: tip, maxFeePerGas: ((fd.maxFeePerGas || 0n) - (fd.maxPriorityFeePerGas || 0n)) + tip });
    // Another sender on this key may submit privately, so the public pending nonce cannot see it and
    // it can take this nonce first. Poll for the receipt, and stop as soon as the nonce is spent by
    // someone else, instead of waiting on a hash that can never land.
    let rc = null;
    for (const end = Date.now() + 10 * 60 * 1000; !rc && Date.now() < end;) {
      await new Promise(r => setTimeout(r, 15000));
      rc = await provider.getTransactionReceipt(tx.hash);
      if (!rc && (await provider.getTransactionCount(wallet.address, 'latest')) > nonce) {
        rc = await provider.getTransactionReceipt(tx.hash);
        if (!rc) throw new Error(`chunk${n}: nonce ${nonce} was used by another sender from this key before ${tx.hash} landed; re-run to resume`);
      }
    }
    if (!rc) throw new Error(`chunk${n}: tx ${tx.hash} not mined within 10 minutes; re-run to resume`);
    if (rc.status !== 1) throw new Error(`chunk${n}: tx ${tx.hash} reverted; re-run to resume`);
    const addr = rc.contractAddress;
    const code = await provider.getCode(addr);
    if (code.toLowerCase() !== want.toLowerCase()) {
      throw new Error(`chunk${n} at ${addr} holds ${(code.length - 2) / 2} B, expected ${slices[i].length} B — STOPPING`);
    }
    rec[`chunk${n}`] = addr;
    fs.writeFileSync(REC, JSON.stringify(rec, null, 2) + '\n');
    console.log(`chunk${n}  ${addr}  ${slices[i].length.toLocaleString('en-US')} B verified  (gas ${rc.gasUsed.toLocaleString('en-US')})`);
  }

  if (DRY) {
    const base = (await provider.getBlock('latest')).baseFeePerGas;
    const at = g => `${(Number(dryGas) * g / 1e9).toFixed(4)} ETH at ${g} gwei`;
    console.log(`\ntotal ~${dryGas.toLocaleString('en-US')} gas: ${at(+(Number(base) / 1e9 + Number(FLOOR) / 1e9).toFixed(3))} now, ${at(0.1)}, ${at(0.06)}`);
    return;
  }
  const all = Array.from({ length: N }, (_, i) => rec[`chunk${i + 1}`]);
  if (all.every(Boolean)) {
    // Distinctness is a constructor precondition (InvalidData otherwise), and
    // duplicate slices would silently produce duplicate addresses.
    if (new Set(all.map(a => a.toLowerCase())).size !== N) throw new Error('duplicate chunk addresses');
    console.log(`\nall ${N} chunks deployed and verified:\n${all.join(' ')}`);
  }
}
main().catch(e => { console.error('\n' + e.message); process.exit(1); });
