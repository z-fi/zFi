#!/usr/bin/env node
//
// Privacy Pools note doctor.
//
// Derives your Privacy Pools notes from your recovery phrase LOCALLY and
// reports what the chain says about each one. The phrase never leaves this
// machine: it is read from a file or stdin, used only for local hashing, and
// never printed, logged, or sent anywhere. Only public facts are printed
// (indices, amounts, tx hashes, on-chain booleans) so the output is safe to
// share when asking for help.
//
// Usage:
//   node script/pp-note-doctor.mjs --phrase-file ~/Downloads/zfi-recovery-phrase.txt
//   cat phrase.txt | node script/pp-note-doctor.mjs
//   node script/pp-note-doctor.mjs --phrase-file phrase.txt --asset ETH --indices 32
//
import { readFileSync } from 'node:fs';
import { webcrypto } from 'node:crypto';
import path from 'node:path';
import vm from 'node:vm';
import { fileURLToPath } from 'node:url';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const RPCS = [
  'https://mainnet.gateway.tenderly.co',
  'https://gateway.tenderly.co/public/mainnet',
];

const POOLS = {
  ETH: { pool: '0xF241d57C6DebAe225c0F2e6eA1529373C9A9C9fB', asset: '0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE', deployBlock: 22153707 },
  BOLD: { pool: '0xb4b5Fd38Fd4788071d7287e3cB52948e0d10b23E', asset: '0x6440f144b7e50d6a8439336510312d2f54beb01d', deployBlock: 24433029 },
  wstETH: { pool: '0x1A604E9DFa0EFDC7FFda378AF16Cb81243b61633', asset: '0x7f39c581f595b53c5cb19bd0b3f8da6c935e2ca0', deployBlock: 23039970 },
};

const SNARK_FIELD = 21888242871839275222246405745257275088548364400416034343698204186575808495617n;
const TOPICS = {
  Deposited: '0xe3b53cd1a44fbf11535e145d80b8ef1ed6d57a73bf5daa7e939b6b01657d6549',
  Withdrawn: '0x75e161b3e824b114fc1a33274bd7091918dd4e639cede50b78b15a4eea956a21',
  LeafInserted: '0xcb249c8292372bd11f567786635483fca9e635030baafca55ff1a8940141d221',
  Ragequit: '0xd2b3e868ae101106371f2bd93abc8d5a4de488b9fe47ed122c23625aa7172f13',
};

function parseArgs(argv) {
  const args = { asset: null, indices: 24, phraseFile: null };
  for (let i = 2; i < argv.length; i++) {
    const arg = argv[i];
    if (arg === '--phrase-file') args.phraseFile = argv[++i];
    else if (arg === '--asset') args.asset = argv[++i];
    else if (arg === '--indices') args.indices = Number(argv[++i]);
    else if (arg === '--help' || arg === '-h') args.help = true;
  }
  return args;
}

function loadRuntimeLibs() {
  const ctx = vm.createContext({
    window: {}, globalThis: {}, Uint8Array, Array, BigInt, TextEncoder, TextDecoder,
    crypto: webcrypto,
    atob: (s) => Buffer.from(s, 'base64').toString('binary'),
    btoa: (s) => Buffer.from(s, 'binary').toString('base64'),
  });
  for (const file of ['poseidon1.min.js', 'poseidon2.min.js', 'poseidon3.min.js', 'ethers.min.js']) {
    vm.runInContext(readFileSync(path.join(ROOT, 'dapp/vendor', file), 'utf8'), ctx);
  }
  return {
    poseidon1: ctx.window.poseidon1,
    poseidon2: ctx.window.poseidon2,
    poseidon3: ctx.window.poseidon3,
    ethers: ctx.globalThis.ethers,
  };
}

async function readPhrase(phraseFile) {
  const raw = phraseFile
    ? readFileSync(phraseFile, 'utf8')
    : await new Promise((resolve, reject) => {
        let buf = '';
        process.stdin.setEncoding('utf8');
        process.stdin.on('data', (chunk) => { buf += chunk; });
        process.stdin.on('end', () => resolve(buf));
        process.stdin.on('error', reject);
      });
  // Accept a bare phrase, a JSON wrapper, or a phrase surrounded by headings,
  // numbering or quotes: take the first checksum-valid BIP-39 run of words.
  const text = raw.trim();
  if (text.startsWith('{')) {
    const parsed = JSON.parse(text);
    for (const key of ['mnemonic', 'phrase', 'recoveryPhrase', 'seed']) {
      if (typeof parsed?.[key] === 'string' && parsed[key].trim()) return parsed[key].trim();
    }
  }
  return text;
}

function extractValidPhrase(ethers, text) {
  const words = (String(text || '').toLowerCase().match(/[a-z]+/g) || []);
  for (const length of [24, 21, 18, 15, 12]) {
    for (let start = 0; start + length <= words.length; start++) {
      const candidate = words.slice(start, start + length).join(' ');
      try {
        if (ethers.Mnemonic.isValidMnemonic(candidate)) return candidate;
      } catch { /* keep scanning */ }
    }
  }
  return null;
}

let rpcCursor = 0;
async function rpc(method, params) {
  let lastErr;
  for (let attempt = 0; attempt < RPCS.length * 2; attempt++) {
    const url = RPCS[rpcCursor % RPCS.length];
    rpcCursor++;
    try {
      const res = await fetch(url, {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ jsonrpc: '2.0', id: 1, method, params }),
        signal: AbortSignal.timeout(30000),
      });
      const json = await res.json();
      if (json.error) throw new Error(json.error.message);
      return json.result;
    } catch (err) {
      lastErr = err;
      await new Promise(r => setTimeout(r, 500 * (attempt + 1)));
    }
  }
  throw lastErr;
}

function hex32(value) {
  return '0x' + BigInt(value).toString(16).padStart(64, '0');
}

async function main() {
  const args = parseArgs(process.argv);
  if (args.help) {
    console.log('Usage: node script/pp-note-doctor.mjs --phrase-file <file> [--asset ETH] [--indices 24]');
    return;
  }

  const { poseidon1, poseidon2, poseidon3, ethers } = loadRuntimeLibs();
  const rawPhrase = await readPhrase(args.phraseFile);
  const phrase = extractValidPhrase(ethers, rawPhrase);
  if (!phrase) {
    const wordCount = (String(rawPhrase || '').toLowerCase().match(/[a-z]+/g) || []).length;
    console.error(wordCount >= 12
      ? 'Found words but no valid BIP-39 phrase (checksum failed). Check for a mistyped, missing or out-of-order word.'
      : 'Could not read a recovery phrase. Pass --phrase-file <file> or pipe it on stdin.');
    process.exitCode = 1;
    return;
  }

  const mnemonic = ethers.Mnemonic.fromPhrase(phrase);
  const hdKey = (accountIndex) =>
    ethers.HDNodeWallet.fromMnemonic(mnemonic, `m/44'/60'/${accountIndex}'/0/0`).privateKey;
  const keysets = {
    safe: {
      masterNullifier: poseidon1([BigInt(hdKey(0))]),
      masterSecret: poseidon1([BigInt(hdKey(1))]),
    },
    legacy: {
      masterNullifier: poseidon1([BigInt(Number(BigInt(hdKey(0))))]),
      masterSecret: poseidon1([BigInt(Number(BigInt(hdKey(1))))]),
    },
  };

  const assets = args.asset ? [args.asset] : Object.keys(POOLS);
  const latest = Number(BigInt(await rpc('eth_blockNumber', [])));

  for (const asset of assets) {
    const cfg = POOLS[asset];
    if (!cfg) { console.error(`Unknown asset ${asset}`); continue; }
    const scope = BigInt(ethers.keccak256(
      '0x' + cfg.pool.slice(2).toLowerCase() +
      '0000000000000000000000000000000000000000000000000000000000000001' +
      cfg.asset.slice(2).toLowerCase()
    )) % SNARK_FIELD;

    console.log(`\n=== ${asset} pool ${cfg.pool}`);
    const logs = await rpc('eth_getLogs', [{
      address: cfg.pool,
      topics: [[TOPICS.Deposited, TOPICS.Withdrawn, TOPICS.LeafInserted, TOPICS.Ragequit]],
      fromBlock: '0x' + cfg.deployBlock.toString(16),
      toBlock: '0x' + latest.toString(16),
    }]);

    const deposits = new Map();  // precommitmentHash -> event
    const withdrawn = new Map(); // spentNullifierHash -> event
    const leaves = new Set();
    for (const log of logs) {
      const d = log.data.slice(2);
      const word = (i) => BigInt('0x' + d.slice(i * 64, (i + 1) * 64));
      if (log.topics[0] === TOPICS.Deposited) {
        deposits.set(hex32(word(3)), {
          commitment: hex32(word(0)), label: word(1), value: word(2),
          txHash: log.transactionHash, blockNumber: Number(BigInt(log.blockNumber)),
        });
      } else if (log.topics[0] === TOPICS.Withdrawn) {
        withdrawn.set(hex32(word(1)), {
          value: word(0), newCommitment: word(2),
          txHash: log.transactionHash, blockNumber: Number(BigInt(log.blockNumber)),
        });
      } else if (log.topics[0] === TOPICS.LeafInserted) {
        leaves.add(hex32(word(1)));
      }
    }
    console.log(`    events: ${deposits.size} deposits, ${withdrawn.size} withdrawals, ${leaves.size} leaves`);

    let matched = 0;
    for (const [derivation, keys] of Object.entries(keysets)) {
      for (let index = 0; index < args.indices; index++) {
        const nullifier = poseidon3([keys.masterNullifier, scope, BigInt(index)]);
        const secret = poseidon3([keys.masterSecret, scope, BigInt(index)]);
        const precommitment = poseidon2([nullifier, secret]);
        const deposit = deposits.get(hex32(precommitment));
        if (!deposit) continue;
        matched++;

        const nullHash = poseidon1([nullifier]);
        const spentEvent = withdrawn.get(hex32(nullHash));
        const onChainSpent = await rpc('eth_call', [{
          to: cfg.pool,
          // nullifierHashes(uint256)
          data: '0x' + ethers.id('nullifierHashes(uint256)').slice(2, 10) + hex32(nullHash).slice(2),
        }, 'latest']);
        const spentOnChain = BigInt(onChainSpent) === 1n;
        const inserted = leaves.has(deposit.commitment);

        console.log(
          `    [${derivation} #${index}] ${ethers.formatUnits(deposit.value, 18)} ${asset}` +
          `  deposit=${deposit.txHash}` +
          `  inTree=${inserted}` +
          `  eventSaysSpent=${!!spentEvent}` +
          `  poolSaysSpent=${spentOnChain}`
        );
        if (spentEvent && !spentOnChain) {
          console.log(`        ^ MISMATCH: event history blames tx ${spentEvent.txHash} but the pool says this note is unspent.`);
        }
        if (spentEvent) {
          const change = deposit.value - spentEvent.value;
          console.log(`        withdrawal tx ${spentEvent.txHash} value=${ethers.formatUnits(spentEvent.value, 18)} change=${ethers.formatUnits(change < 0n ? 0n : change, 18)}`);
        }
      }
    }
    if (!matched) {
      console.log(`    no notes for this phrase in the first ${args.indices} indices of either derivation`);
      console.log('    (if you expect notes here, re-run with a larger --indices)');
    }
  }
  console.log('\nDone. The output above contains no secrets and is safe to share.');
}

main().catch((err) => {
  console.error('Failed:', err?.message || err);
  process.exitCode = 1;
});
