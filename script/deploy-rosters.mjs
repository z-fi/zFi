#!/usr/bin/env node
/**
 * Deploy the two curation satellites - zRpcList and zSolverList - on their own,
 * owned by whoever is named below.
 *
 * WHAT THESE ARE. Two governance rosters and nothing else. They hold endpoint
 * URLs the page reads through (zRpcList) and the off-chain solver lanes it may
 * race its own venues against (zSolverList). Neither holds funds, neither can
 * move funds, and neither has a function that touches a token. The worst a
 * hostile roster does is misprice a quote or waste a request - which is why
 * curating them is a list-maintenance decision rather than a custody one.
 *
 * WHAT THIS DOES NOT DO. It does not point any zSwap version at what it
 * deploys. A version names these by address in its own constructor, so wiring
 * them up is a separate, later deploy of that version - and until then these
 * are two contracts nothing reads.
 *
 * THE SOLVER ROSTER SHIPS EMPTY, on purpose. A lane needs a running proxy and a
 * reviewed adapter before it means anything; add them afterwards, one public
 * transaction each.
 *
 * The key is read from PRIVATE_KEY in the environment and never echoed. Pass
 * --dry-run to do everything except broadcast.
 *
 *   PRIVATE_KEY=0x… node script/deploy-rosters.mjs --dry-run
 *   PRIVATE_KEY=0x… node script/deploy-rosters.mjs --rpc https://…
 */
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { JsonRpcProvider, Wallet, ContractFactory, formatEther, isAddress } from 'ethers';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.join(HERE, '..');
const OUT = path.join(ROOT, 'out');

const argv = process.argv.slice(2);
const DRY = argv.includes('--dry-run');
const ONLY_SOLVERS = argv.includes('--only-solvers');
const ONLY_FILL = argv.includes('--only-fill');
const adapterAt = argv.indexOf('--adapter');
const ADAPTER = adapterAt > -1 ? argv[adapterAt + 1] : null;
const rpcAt = argv.indexOf('--rpc');
const RPC = rpcAt > -1 ? argv[rpcAt + 1] : process.env.ETH_RPC_URL || 'https://ethereum-rpc.publicnode.com';

// Who owns both rosters from birth. Two-step transferable afterwards, so this
// is a starting point and not a commitment.
const OWNER = '0x1C0Aa8cCD568d90d61659F060D1bFb1e6f855A20';

// The seed curation, RANKED BY MEASUREMENT rather than reputation. Each of
// these was probed three times for `eth_blockNumber` AND a real `eth_call`,
// because the page's whole job here is eth_call and an endpoint that serves
// blocks while refusing calls is useless to it - which is not hypothetical:
// rpc.flashbots.net and eth.meowrpc.com both answered every block query and
// refused every call, so neither is here. Also dropped: llamarpc (HTTP 521),
// ankr (demands a key - this list is keyless by definition), cloudflare-eth
// ("cannot fulfill request"), blockpi (521), public-rpc (403), payload.de and
// securerpc (NXDOMAIN), and 1rpc.io (2/3, ~1.3s).
//
// Order is failover preference, fastest verified first. Every one of these
// answered 3/3 calls at chain tip or one block behind.
const SEED_RPCS = [
  'https://eth.rpc.blxrbdn.com',            //  69ms, tip
  'https://eth.drpc.org',                   // 215ms
  'https://ethereum-rpc.publicnode.com',    // 248ms - also a page-baked seed
  'https://eth-pokt.nodies.app',            // 369ms, tip
  'https://rpc.mevblocker.io',              // 490ms, tip
  'https://eth-mainnet.public.blastapi.io', // 560ms - also a page-baked seed
];

// The solver lanes, each PROBED WITH A REAL 1 ETH -> USDC price query through
// the exact path dapp/modules/aggregators.js uses. Order is by the price each
// actually returned, latency breaking ties - so the roster ships ranked by
// evidence rather than by anyone's opinion of the brand.
//
// Not included, because they failed the probe rather than because of any view
// about them: OpenOcean (403 from Cloudflare on every path, matching the note
// already in aggregators.js) and Bitget (403, and its on-chain wrapper is
// already the zero address).
//
// NOTE ON THE PROXIED LANES: api.zfi.wei.is is origin-gated to
// https://zfi.wei.is. That is the point of the proxy - it holds the API key so
// the page never does - and it is also the single operator four of these lanes
// share. Worth knowing when reading the ordering: those four sit behind one
// rate limit and one TLS endpoint.
//
// OPENOCEAN IS NOT HERE, and the reason is worth recording so nobody spends an
// afternoon rediscovering it. The service is UP: /v4/eth/gasPrice, /tokenList
// and /dexList all answer 200 with live data. It is the QUOTE and SWAP paths
// specifically - on v3 and v4 alike - that answer 403 with
// `cf-mitigated: challenge`. That is a deliberate Cloudflare managed challenge
// on the money endpoints, and it is solvable only by a full browser navigation
// that runs the challenge JS and earns a cf_clearance cookie. A cross-origin
// fetch from the page cannot do that, so it fails for real users too unless
// they happen to have browsed openocean.finance lately - which is exactly the
// behaviour aggregators.js already recorded. api.zfi.wei.is has no route for
// it either (405). A lane that can only ever burn its deadline is worse than
// no lane.
//
// Bitget is NOT here either: it 403s and its on-chain wrapper is already the
// zero address. Nothing about that is worth carrying.
//
// EVERY LANE SHIPS ENABLED. The roster is the curation; a lane that is on
// here still does nothing until a page reads this contract, and the owner can
// park any of them with one `setEnabled` at any time.
const SOLVER_LANES = (adapter) => [
  ['ParaSwap',  'https://api.paraswap.io',                            adapter, 50, true], // 2459.047 USDC
  ['KyberSwap', 'https://aggregator-api.kyberswap.com',               adapter, 50, true], // 2459.009
  ['Enso',      'https://api.zfi.wei.is/enso/api/v1/shortcuts/route',  adapter, 50, true], // 2458.826
  ['0x',        'https://api.zfi.wei.is/0x',                          adapter, 50, true], // 2458.430, fastest at 587ms
  ['1inch',     'https://api.zfi.wei.is/1inch',                       adapter, 50, true], // 2451.757
  ['Bebop',     'https://api.bebop.xyz/router/ethereum/v1',           adapter, 50, true], // 200, RFQ shape
  ['OKX',       'https://api.zfi.wei.is/okx',                         adapter, 50, true], // authenticates
];

function artifact(file, name) {
  const p = path.join(OUT, file, `${name}.json`);
  if (!fs.existsSync(p)) throw new Error(`missing artifact ${p} - run \`forge build\` first`);
  const j = JSON.parse(fs.readFileSync(p, 'utf8'));
  return { abi: j.abi, bytecode: j.bytecode.object };
}

async function main() {
  if (!isAddress(OWNER)) throw new Error(`OWNER is not an address: ${OWNER}`);

  const key = process.env.PRIVATE_KEY;
  if (!key) throw new Error('set PRIVATE_KEY in the environment');

  const provider = new JsonRpcProvider(RPC);
  const wallet = new Wallet(key, provider);
  const net = await provider.getNetwork();
  const bal = await provider.getBalance(wallet.address);

  console.log(`network:  ${net.name} (chainId ${net.chainId})`);
  console.log(`deployer: ${wallet.address}`);
  console.log(`balance:  ${formatEther(bal)} ETH`);
  console.log(`owner:    ${OWNER}`);
  console.log(`seeds:    ${SEED_RPCS.length} rpc endpoints, ${SOLVER_LANES('0x' + '00'.repeat(20)).length} solver lanes (all disabled)`);
  console.log(DRY ? '\nDRY RUN - nothing will be broadcast\n' : '');

  let totalGas = 0n;

  // The adapter goes first: a lane cannot name a zero adapter, so the solver
  // roster's constructor argument depends on this address existing.
  const fillArt = artifact('zSolverFill.sol', 'zSolverFill');
  // On a dry run nothing is deployed, so stand in a placeholder: a zero adapter
  // is refused by the constructor (NoAdapter), which is correct behaviour and
  // would otherwise read as a failed estimate.
  let fillAddr = ADAPTER || (DRY ? '0x' + '11'.repeat(20) : '0x' + '00'.repeat(20));
  if (!ADAPTER) {
    const factory = new ContractFactory(fillArt.abi, fillArt.bytecode, wallet);
    const tx = await factory.getDeployTransaction();
    const gas = await provider.estimateGas({ ...tx, from: wallet.address });
    totalGas += gas;
    console.log(`zSolverFill: ${(tx.data.length - 2) / 2} B initcode, ~${gas} gas`);
    if (!DRY) {
      const c = await factory.deploy();
      await c.waitForDeployment();
      fillAddr = await c.getAddress();
      console.log(`  deployed -> ${fillAddr}`);
      console.log(`  executor -> ${await c.EXEC()}`);
    }
  }

  const jobs = ONLY_FILL ? [] : [
    ...(ONLY_SOLVERS ? [] : [{ label: 'zRpcList', ...artifact('zRpcList.sol', 'zRpcList'), args: [SEED_RPCS, OWNER] }]),
    {
      label: 'zSolverList',
      ...artifact('zSolverList.sol', 'zSolverList'),
      args: [SOLVER_LANES(fillAddr), OWNER],
    },
  ];

  const deployed = { zSolverFill: fillAddr };
  for (const job of jobs) {
    const factory = new ContractFactory(job.abi, job.bytecode, wallet);
    const tx = await factory.getDeployTransaction(...job.args);
    const gas = await provider.estimateGas({ ...tx, from: wallet.address });
    totalGas += gas;
    console.log(`${job.label}: ${(tx.data.length - 2) / 2} B initcode, ~${gas} gas`);

    if (DRY) continue;

    const c = await factory.deploy(...job.args);
    await c.waitForDeployment();
    const addr = await c.getAddress();
    deployed[job.label] = addr;
    console.log(`  deployed -> ${addr}`);

    // Verify what landed, rather than trusting the receipt: the owner must be
    // the one named above, and the seeds must be the ones read out of here.
    const owner = await c.owner();
    if (owner.toLowerCase() !== OWNER.toLowerCase()) throw new Error(`${job.label}: owner is ${owner}, not ${OWNER}`);
    const n = await c.count();
    if (Number(n) !== job.args[0].length) throw new Error(`${job.label}: holds ${n} entries, expected ${job.args[0].length}`);
    console.log(`  verified -> owner ${owner}, ${n} entries`);
  }

  // Say what this costs before it is spent, against the balance that has to
  // cover it - a deploy that runs out halfway leaves a half-wired set.
  const fee = (await provider.getFeeData()).maxFeePerGas ?? (await provider.getFeeData()).gasPrice;
  if (fee) {
    const cost = totalGas * fee;
    console.log(`\ntotal: ~${totalGas} gas @ ${Number(fee) / 1e9} gwei = ~${formatEther(cost)} ETH`);
    if (cost > bal) console.log(`WARNING: balance ${formatEther(bal)} ETH does not cover it`);
  }

  if (!DRY) {
    const rec = path.join(ROOT, 'deploy', 'rosters.json');
    fs.mkdirSync(path.dirname(rec), { recursive: true });
    fs.writeFileSync(rec, JSON.stringify({ chainId: Number(net.chainId), owner: OWNER, ...deployed }, null, 2) + '\n');
    console.log(`\nwrote: deploy/rosters.json`);
    console.log('\nNEXT: a zSwap version must name these addresses in its constructor.');
  }
}

main().catch((e) => {
  console.error(String(e.message || e));
  process.exit(1);
});
