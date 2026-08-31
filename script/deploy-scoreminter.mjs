#!/usr/bin/env node
/**
 * Deploy ScoreMinter, and hand it `arcade.wei`.
 *
 * TWO TRANSACTIONS, IN ORDER, AND THE SECOND IS THE ONE-WAY ONE.
 *
 *   1. Deploy `ScoreMinter(PARENT)`. Harmless on its own: until it holds the
 *      parent it can do nothing at all, which is what `ready()` reports.
 *   2. Transfer `arcade.wei` to the deployed address. THIS IS THE COMMITMENT.
 *      From here only `recoverParent()` — callable solely by RECOVERY, and only
 *      paying RECOVERY — can bring the name back.
 *
 * The script asks before the second one. Read the address it prints first: it
 * is the only thing standing between the name and the wrong contract.
 *
 * Usage:
 *   export PRIVATE_KEY=0x...          # the account that owns arcade.wei
 *   export ETH_RPC_URL=https://...    # optional
 *   node script/deploy-scoreminter.mjs            # dry run: prints, sends nothing
 *   node script/deploy-scoreminter.mjs --send     # actually deploys
 *
 * The key is read from the environment and never written anywhere. It is not
 * logged, not echoed, and not saved to the deploy record.
 */
import fs from 'node:fs';
import path from 'node:path';
import readline from 'node:readline/promises';
import { fileURLToPath } from 'node:url';
import { JsonRpcProvider, Wallet, ContractFactory, Contract, formatEther } from 'ethers';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.join(HERE, '..');

const NAMES = '0x0000000000696760E15f265e828DB644A0c242EB';
const RECOVERY = '0x1C0Aa8cCD568d90d61659F060D1bFb1e6f855A20';
/** `arcade.wei` — namehash, and the constructor argument. */
const PARENT = 50954229446721386169926547816206122353384135962146661543629559682287576011957n;

const SEND = process.argv.includes('--send');
const RPC = process.env.ETH_RPC_URL || 'https://ethereum-rpc.publicnode.com';

const die = m => { console.error(`\n  ✗ ${m}\n`); process.exit(1); };
const ok = m => console.log(`  ✓ ${m}`);

const art = JSON.parse(fs.readFileSync(
  path.join(ROOT, 'out', 'ScoreMinter.sol', 'ScoreMinter.json'), 'utf8'));

const provider = new JsonRpcProvider(RPC);
const names = new Contract(NAMES, [
  'function ownerOf(uint256) view returns (address)',
  'function transferFrom(address,address,uint256)',
  'function expiresAt(uint256) view returns (uint256)',
], provider);

console.log(`\nScoreMinter — deploy${SEND ? '' : ' (DRY RUN, nothing will be sent)'}\n`);

// ---- preflight. Everything checkable, checked, before anything is signed.
const net = await provider.getNetwork();
if (net.chainId !== 1n) die(`connected to chain ${net.chainId}, expected mainnet`);
ok(`mainnet, block ${await provider.getBlockNumber()}`);

if (!process.env.PRIVATE_KEY) die('PRIVATE_KEY is not set');
const wallet = new Wallet(process.env.PRIVATE_KEY, provider);
ok(`deployer ${wallet.address}`);

const bal = await provider.getBalance(wallet.address);
console.log(`    balance ${formatEther(bal)} ETH`);
if (bal === 0n) die('the deployer has no ether');

// The parent must exist, be held by the deployer, and not be about to lapse.
let owner;
try { owner = await names.ownerOf(PARENT); }
catch { die('arcade.wei does not exist — check PARENT'); }
ok(`arcade.wei held by ${owner}`);

const deployerOwnsParent = owner.toLowerCase() === wallet.address.toLowerCase();
if (!deployerOwnsParent) {
  console.log(`\n  ! The deployer does not own arcade.wei.`);
  console.log(`    That is fine for step 1 - nothing in the contract references its`);
  console.log(`    deployer - but this script cannot do step 2. It will deploy and`);
  console.log(`    then print the address for ${owner} to send the name to.`);
}

const expires = Number(await names.expiresAt(PARENT));
const daysLeft = Math.floor((expires - Date.now() / 1000) / 86400);
ok(`arcade.wei expires in ${daysLeft} days (${new Date(expires * 1000).toISOString().slice(0, 10)})`);
if (daysLeft < 30) console.log('    ! renew it soon — a lapsed parent takes the namespace with it');

if (owner.toLowerCase() !== RECOVERY.toLowerCase()) {
  console.log(`\n  ! RECOVERY is ${RECOVERY}`);
  console.log(`    but arcade.wei is held by ${owner}.`);
  console.log(`    Recovery would return the name to RECOVERY, not to the deployer.`);
}

if (!SEND) {
  console.log(`\n  Dry run only. Re-run with --send to deploy.\n`);
  process.exit(0);
}

// ---- 1. deploy
const factory = new ContractFactory(art.abi, art.bytecode.object, wallet);
console.log(`\n  deploying…`);
const minter = await factory.deploy(PARENT);
await minter.waitForDeployment();
const addr = await minter.getAddress();
ok(`ScoreMinter at ${addr}`);
console.log(`    ${(await provider.getTransactionReceipt(minter.deploymentTransaction().hash)).hash}`);

fs.writeFileSync(path.join(ROOT, 'out', 'scoreminter.deploy.json'), JSON.stringify({
  address: addr, parent: PARENT.toString(), parentName: 'arcade.wei',
  recovery: RECOVERY, registry: NAMES, deployer: wallet.address,
  tx: minter.deploymentTransaction().hash, at: new Date().toISOString(),
}, null, 2));
ok('recorded in out/scoreminter.deploy.json');

// ---- 2. the one-way step
if (!deployerOwnsParent) {
  console.log(`\n  Deployed, and inert until it holds the parent.`);
  console.log(`  Finish from ${owner}:`);
  console.log(`\n    cast send ${NAMES} \\`);
  console.log(`      "transferFrom(address,address,uint256)" \\`);
  console.log(`      ${owner} ${addr} ${PARENT} \\`);
  console.log(`      --rpc-url $ETH_RPC_URL --private-key $OWNER_KEY\n`);
  console.log(`  Verify afterwards with: ready() on ${addr}\n`);
  process.exit(0);
}

console.log(`\n  Next: transfer arcade.wei to ${addr}`);
console.log(`  This is IRREVERSIBLE except through recoverParent(), which only`);
console.log(`  ${RECOVERY} can call, and which only pays that address.\n`);

// `--yes` is for a non-interactive run, where there is no terminal to type
// into. It skips the confirmation, not any of the checks above it.
const answer = process.argv.includes('--yes') ? addr : await (async () => {
  const rl = readline.createInterface({ input: process.stdin, output: process.stdout });
  const a = await rl.question(`  Type the contract address to confirm: `);
  rl.close();
  return a;
})();
if (answer.trim().toLowerCase() !== addr.toLowerCase()) {
  console.log(`\n  Not transferred. The contract is deployed but inert.`);
  console.log(`  To finish later, send arcade.wei to ${addr}\n`);
  process.exit(0);
}

const tx = await names.connect(wallet).transferFrom(wallet.address, addr, PARENT);
console.log(`  ${tx.hash}`);
await tx.wait();
ok('arcade.wei transferred');

const held = await names.ownerOf(PARENT);
if (held.toLowerCase() !== addr.toLowerCase()) die(`transfer did not land — parent is at ${held}`);
ok(`ready() is now true — the contract can issue names`);
console.log(`\n  Done. Point the page's SCOREMINTER at ${addr}\n`);
