#!/usr/bin/env node
/**
 * Deploy the sixteen zSwap page chunks, one transaction each.
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
 * Usage: PRIVATE_KEY=0x.. ETH_RPC_URL=https://.. node script/deploy-zSwap-chunks.mjs [--dry-run]
 */
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { JsonRpcProvider, Wallet, formatEther } from 'ethers';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const N = 18;
const DRY = process.argv.includes('--dry-run');
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

let rec = {};
if (fs.existsSync(REC)) rec = JSON.parse(fs.readFileSync(REC, 'utf8'));

const hexOf = buf => '0x' + buf.toString('hex');

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

    if (DRY) {
      const gas = await provider.estimateGas({ data: creations[i], from: wallet ? wallet.address : undefined });
      console.log(`chunk${n}  ~${gas.toLocaleString('en-US')} gas (dry run)`);
      continue;
    }

    const tx = await wallet.sendTransaction({ data: creations[i] });
    const rc = await tx.wait();
    const addr = rc.contractAddress;
    const code = await provider.getCode(addr);
    if (code.toLowerCase() !== want.toLowerCase()) {
      throw new Error(`chunk${n} at ${addr} holds ${(code.length - 2) / 2} B, expected ${slices[i].length} B — STOPPING`);
    }
    rec[`chunk${n}`] = addr;
    fs.writeFileSync(REC, JSON.stringify(rec, null, 2) + '\n');
    console.log(`chunk${n}  ${addr}  ${slices[i].length.toLocaleString('en-US')} B verified  (gas ${rc.gasUsed.toLocaleString('en-US')})`);
  }

  if (DRY) return;
  const all = Array.from({ length: N }, (_, i) => rec[`chunk${i + 1}`]);
  if (all.every(Boolean)) {
    // Distinctness is a constructor precondition (InvalidData otherwise), and
    // duplicate slices would silently produce duplicate addresses.
    if (new Set(all.map(a => a.toLowerCase())).size !== N) throw new Error('duplicate chunk addresses');
    console.log(`\nall ${N} chunks deployed and verified:\n${all.join(' ')}`);
  }
}
main().catch(e => { console.error('\n' + e.message); process.exit(1); });
