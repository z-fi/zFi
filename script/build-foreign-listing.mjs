#!/usr/bin/env node
// List a Base or Robinhood token on the canonical TokenList (mainnet,
// token.list.wei.limo) as a foreign eip155 listing, from the registry owner's
// multisig. Emits ONE `multicall(bytes[])` calldata file per run, so a listing
// is never briefly visible half-built, plus a record the Safe UI can be filled
// from.
//
// WHY THIS SHAPE. zSwap's dropdown on a chain is whatever the mainnet registry
// lists for that chain id (`loadTokenListRun` keeps rows with `k=eip155` and
// `c=CHAIN_ID`), falling back to the page's built-in list only when the registry
// has nothing swappable there. So the way to iterate the Base or Robinhood list
// is to list, rank, re-art or delist here - never to edit the page.
//
// A foreign listing has no on-chain source the registry can read, so name,
// symbol and decimals are typed by the owner. This script reads them from the
// token ON ITS OWN CHAIN and refuses to guess, and the page verifies `decimals`
// against the chain again when it renders, so a typo cannot mis-scale amounts.
//
// Usage:
//   node script/build-foreign-listing.mjs --chain 8453 --token 0x8335…2913 \
//     --like 0xA0b8…eB48            # copy logo, colour and rank from this mainnet listing
//     [--logo path.svg] [--color 2775ca] [--rank 995000] [--url …] [--desc …]
//     [--extra origin=bitcoin]      # any bytes32-keyed note, repeatable
//     [--token 0x… --like 0x… …]    # more tokens: one multicall lists them all
//     [--out deploy/USDC-8453-list]
//
// `--like` also records the equivalence as an extra (`eq` = eip155:1:<address>),
// so a consumer can tell that Base USDC is the same asset as mainnet USDC.

import fs from "node:fs";
import path from "node:path";
import {fileURLToPath} from "node:url";
import {AbiCoder, Interface, JsonRpcProvider, getAddress, keccak256, toBeHex, zeroPadValue} from "ethers";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const REGISTRY = "0x0000006013dF75A31678B786061C2B54bf531524";
const OWNER = "0x006CD14F36F65eCbB29b2519cCBe63A0DC8549F2";
const MAINNET = "https://ethereum-rpc.publicnode.com";
const CHAINS = {
  8453: {name: "Base", rpc: "https://mainnet.base.org"},
  4663: {name: "Robinhood", rpc: "https://rpc.mainnet.chain.robinhood.com"},
};
const FOREIGN_FLAG = 1n << 255n;
const KIND_EVM = 0;
const STANDARD_ERC20 = 2;

const registry = new Interface([
  "function listForeign(uint8 kind,uint64 chainId,bytes32 account,string name_,string symbol_,uint8 decimals_,uint24 color,uint32 rank,string logo) returns (uint256)",
  "function setStandard(uint256 id,uint8 standard_)",
  "function setArt(uint256 id,uint24 color,uint32 rank,string logo,string url_,string description_)",
  "function setLogoSVG(uint256 id,string svg)",
  "function setExtra(uint256 id,bytes32 key,string value)",
  "function multicall(bytes[] data) payable returns (bytes[])",
  "function isListed(uint256 id) view returns (bool)",
  "function json(uint256 id) view returns (string)",
]);
const erc20 = new Interface([
  "function name() view returns (string)",
  "function symbol() view returns (string)",
  "function decimals() view returns (uint8)",
]);

// ------------------------------------------------------------------ arguments

const argv = process.argv.slice(2);
const flag = (k) => { const i = argv.indexOf(k); return i > -1 ? argv[i + 1] : undefined; };
const chainId = Number(flag("--chain"));
if (!CHAINS[chainId]) { console.error("usage: --chain 8453|4663 --token 0x… [--like 0x…] …"); process.exit(1); }
// Tokens are grouped with whatever `--like/--logo/--color/--rank/--url/--desc/--extra`
// follow them, up to the next `--token`.
const jobs = [];
for (let i = 0; i < argv.length; i++) {
  if (argv[i] === "--token") jobs.push({token: getAddress(argv[++i]), extras: []});
  else if (argv[i] === "--like" && jobs.length) jobs.at(-1).like = getAddress(argv[++i]);
  else if (argv[i] === "--logo" && jobs.length) jobs.at(-1).logo = argv[++i];
  else if (argv[i] === "--color" && jobs.length) jobs.at(-1).color = argv[++i];
  else if (argv[i] === "--rank" && jobs.length) jobs.at(-1).rank = Number(argv[++i]);
  else if (argv[i] === "--url" && jobs.length) jobs.at(-1).url = argv[++i];
  else if (argv[i] === "--desc" && jobs.length) jobs.at(-1).desc = argv[++i];
  else if (argv[i] === "--extra" && jobs.length) jobs.at(-1).extras.push(argv[++i]);
}
if (!jobs.length) { console.error("at least one --token is required"); process.exit(1); }
const outBase = flag("--out");

// ------------------------------------------------------------------ helpers

const l2 = new JsonRpcProvider(CHAINS[chainId].rpc, chainId, {staticNetwork: true});
const l1 = new JsonRpcProvider(MAINNET, 1, {staticNetwork: true});
const call = async (p, to, iface, fn, args = []) => iface.decodeFunctionResult(fn, await p.call({to, data: iface.encodeFunctionData(fn, args)}));
const foreignId = (id, account) =>
  (BigInt(keccak256(AbiCoder.defaultAbiCoder().encode(["uint8", "uint64", "bytes32"], [KIND_EVM, id, account]))) | FOREIGN_FLAG);
const label = (s) => {
  const b = Buffer.from(s, "utf8");
  if (!b.length || b.length > 32) throw Error(`extra key must be 1-32 bytes: ${s}`);
  return "0x" + b.toString("hex").padEnd(64, "0");
};
const svgFromDataUrl = (u) => {
  const m = /^data:image\/svg\+xml;base64,(.+)$/.exec(u || "");
  return m ? Buffer.from(m[1], "base64").toString("utf8") : null;
};

// ------------------------------------------------------------------ build

const calls = [];
const record = [];
for (const j of jobs) {
  const code = await l2.getCode(j.token);
  if (code.length <= 2) throw Error(`${j.token} has no code on ${CHAINS[chainId].name}`);
  const [name] = await call(l2, j.token, erc20, "name");
  const [symbol] = await call(l2, j.token, erc20, "symbol");
  const [decimals] = await call(l2, j.token, erc20, "decimals");
  if (name.length > 40 || symbol.length > 12) throw Error(`${symbol}: name ≤ 40 and symbol ≤ 12 characters on the registry`);
  const account = zeroPadValue(j.token, 32);
  const id = foreignId(chainId, account);
  const [listed] = await call(l1, REGISTRY, registry, "isListed", [id]);
  if (listed) throw Error(`${symbol} on ${chainId} is already listed as id ${toBeHex(id)}`);

  // The mainnet equivalent, if any: its logo, colour and rank carry over so the
  // L2 list reads like the mainnet one, and the equivalence is written down.
  let like = null;
  if (j.like) {
    const [js] = await call(l1, REGISTRY, registry, "json", [BigInt(j.like)]);
    like = JSON.parse(js);
    if (like.k !== "eip155" || Number(like.c) !== 1) throw Error(`--like must name a mainnet listing, got ${like.k}:${like.c}`);
  }
  const color = parseInt((j.color || (like && like.t ? like.t.replace("#", "") : "627eea")), 16);
  const rank = j.rank ?? (like ? Number(like.r) : 900_000);
  const svg = j.logo ? fs.readFileSync(path.resolve(j.logo), "utf8") : like ? svgFromDataUrl(like.l) : null;
  if (svg && !svg.includes("http://www.w3.org/2000/svg")) throw Error(`${symbol}: the logo must be SVG markup carrying the svg namespace`);
  const url = j.url ?? (like ? like.u || "" : "");
  const desc = j.desc ?? (like ? `${like.n || symbol} on ${CHAINS[chainId].name}` : "");
  const extras = j.extras.map((e) => { const i = e.indexOf("="); return [e.slice(0, i), e.slice(i + 1)]; });
  if (like) extras.unshift(["eq", `eip155:1:${j.like.toLowerCase()}`]);

  const mine = [];
  mine.push(registry.encodeFunctionData("listForeign", [KIND_EVM, chainId, account, name, symbol, decimals, color, rank, ""]));
  mine.push(registry.encodeFunctionData("setStandard", [id, STANDARD_ERC20]));
  if (url || desc) mine.push(registry.encodeFunctionData("setArt", [id, color, rank, "", url, desc]));
  if (svg) mine.push(registry.encodeFunctionData("setLogoSVG", [id, svg]));
  for (const [k, v] of extras) mine.push(registry.encodeFunctionData("setExtra", [id, label(k), v]));
  calls.push(...mine);
  record.push({symbol, name, decimals: Number(decimals), token: j.token, id: toBeHex(id, 32), rank, color: color.toString(16).padStart(6, "0"), logo: !!svg, like: j.like || null, extras, calls: mine.length});
  console.log(`${symbol.padEnd(8)} ${j.token}  dec=${decimals}  rank=${rank}  logo=${svg ? "yes" : "no"}  id=${toBeHex(id, 32)}  (${mine.length} calls)`);
}

const data = registry.encodeFunctionData("multicall", [calls]);
// Simulate the whole batch from the owner before writing anything.
try {
  await l1.call({from: OWNER, to: REGISTRY, data});
} catch (e) {
  console.error("the batch would revert from the owner:", e.shortMessage || e.message);
  process.exit(1);
}
const base = outBase || path.join("deploy", `${record.map((r) => r.symbol).join("+")}-${chainId}-list`);
fs.writeFileSync(path.join(ROOT, base + ".calldata.txt"), data + "\n");
const rows = record.map((r) => `| ${r.symbol} | \`${r.token}\` | ${r.decimals} | ${r.rank} | ${r.logo ? "yes" : "no"} | ${r.like ? "`" + r.like + "`" : "—"} | ${r.calls} |`).join("\n");
fs.writeFileSync(path.join(ROOT, base + ".md"), `# List ${record.map((r) => r.symbol).join(", ")} on ${CHAINS[chainId].name} — registry owner tx

One transaction: a \`multicall\` of ${calls.length} owner calls, atomic. Generated by
\`script/build-foreign-listing.mjs\`; name, symbol and decimals were read from each
token on chain ${chainId}, and the batch simulated cleanly from the owner.

## Transaction

| field | value |
| --- | --- |
| to | \`${REGISTRY}\` (TokenList registry, mainnet) |
| value | \`0\` |
| data | contents of [\`${path.basename(base)}.calldata.txt\`](./${path.basename(base)}.calldata.txt) |
| from | \`${OWNER}\` (registry owner) |
| operation | CALL (not delegatecall) |

${(data.length - 2) / 2} bytes, selector \`0xac9650d8\` (\`multicall(bytes[])\`).

## Listings

| symbol | token on ${chainId} | dec | rank | logo | mainnet equivalent | calls |
|---|---|---|---|---|---|---|
${rows}

Each listing is \`listForeign\` (EVM, ${chainId}) → \`setStandard(ERC20)\` → \`setArt\` (url,
description) → \`setLogoSVG\` → \`setExtra\` per note. Ids are hashes of
(kind, chainId, account), so delisting and re-listing yields the same id.

Verify before sending: \`FOREIGN_LISTING=${base}.calldata.txt forge test --match-path test/ForeignListingTx.t.sol\`
replays this exact calldata against a mainnet fork as the owner and reads every
field back.
`);
console.log(`\nwrote ${base}.calldata.txt (${(data.length - 2) / 2} bytes, ${calls.length} calls) and ${base}.md`);
