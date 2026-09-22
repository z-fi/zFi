#!/usr/bin/env node
// Payloads for Tacit's gov multisig to fund PrecisionFarm so its window ends
// with the confidential TAC/cETH farm's round.
//
// The multisig queues every execute for `delay` seconds, and the farm's
// window starts when the queued call RUNS, so the amount is sized for that
// moment: (END - executeAt) * rate. Executing later than `executeAt` pushes
// the finish past END by the same lag; executing earlier is impossible.
//
// Usage:
//   node script/build-farm-fund-calldata.mjs [executeAt=now+delay+600] [nonce=live]

import {Interface, JsonRpcProvider, TypedDataEncoder, formatUnits} from "ethers";

const RPC = process.env.ETH_RPC_URL || "https://ethereum-rpc.publicnode.com";
const GOV = "0x006cd14f36f65ecbb29b2519ccbe63a0dc8549f2";
const TAC = "0xA1313eb9f3A445606D9583bcAc3ebeB56a858279";
const FARM = "0x0000003bF4BA0B21f5e0d35119b337F4d4CF82E0";
const END = 1797712559n; // Tacit farm epoch periodFinish

const p = new JsonRpcProvider(RPC);
const ms = new Interface([
  "function execute(address target,uint256 value,bytes data,bytes sigs)",
  "function executeQueued(address target,uint256 value,bytes data,uint32 nonce)",
  "function batch(address[] targets,uint256[] values,bytes[] datas)",
  "function approve(bytes32 hash,bool ok)",
  "function getTransactionHash(address target,uint256 value,bytes data,uint32 nonce) view returns (bytes32)",
  "function nonce() view returns (uint32)",
  "function delay() view returns (uint32)",
]);
const erc20 = new Interface(["function approve(address,uint256)", "function balanceOf(address) view returns (uint256)"]);
const farm = new Interface(["function fund(uint256)", "function rewardRate() view returns (uint256)"]);
const call = async (to, iface, fn, args = []) =>
  iface.decodeFunctionResult(fn, await p.call({to, data: iface.encodeFunctionData(fn, args)}))[0];

const [rate, delay, liveNonce, bal, block] = await Promise.all([
  call(FARM, farm, "rewardRate"),
  call(GOV, ms, "delay"),
  call(GOV, ms, "nonce"),
  call(TAC, erc20, "balanceOf", [GOV]),
  p.getBlock("latest"),
]);
const executeAt = BigInt(process.argv[2] || BigInt(block.timestamp) + BigInt(delay) + 600n);
const nonce = Number(process.argv[3] ?? liveNonce);
if (executeAt >= END) throw Error("executeAt is past the end of Tacit's round");
const amount = (END - executeAt) * rate;
if (amount > bal) throw Error(`gov holds ${formatUnits(bal, 18)} TAC, needs ${formatUnits(amount, 18)}`);

const approveData = erc20.encodeFunctionData("approve", [FARM, amount]);
const fundData = farm.encodeFunctionData("fund", [amount]);
const batchData = ms.encodeFunctionData("batch", [[TAC, FARM], [0, 0], [approveData, fundData]]);
const txHash = await call(GOV, ms, "getTransactionHash", [GOV, 0, batchData, nonce]);

// The same digest, rebuilt locally, so a mismatch with the contract fails loudly.
const typed = {
  domain: {name: "Multisig", version: "1", chainId: 1, verifyingContract: GOV},
  types: {Execute: [
    {name: "target", type: "address"},
    {name: "value", type: "uint256"},
    {name: "data", type: "bytes"},
    {name: "nonce", type: "uint32"},
  ]},
  message: {target: GOV, value: "0", data: batchData, nonce},
};
if (TypedDataEncoder.hash(typed.domain, typed.types, typed.message) !== txHash) throw Error("EIP-712 digest mismatch");

// Dry run: the batch exactly as the multisig itself would make it.
await p.call({from: GOV, to: GOV, data: batchData});

const iso = (t) => new Date(Number(t) * 1000).toISOString();
console.log(JSON.stringify({
  multisig: GOV,
  nonce,
  executeAt: `${executeAt} (${iso(executeAt)})`,
  finish: `${END} (${iso(END)})`,
  amountWei: amount.toString(),
  amountTAC: formatUnits(amount, 18),
  calls: [
    {to: TAC, fn: "approve(farm, amount)", data: approveData},
    {to: FARM, fn: "fund(amount)", data: fundData},
  ],
  batchData,
  txHash,
  eip712: typed,
  approveHashCalldata: ms.encodeFunctionData("approve", [txHash, true]),
  executeCalldataTemplate: ms.encodeFunctionData("execute", [GOV, 0, batchData, "0x"]) + "  <- replace sigs",
  executeQueuedCalldata: ms.encodeFunctionData("executeQueued", [GOV, 0, batchData, nonce]),
}, null, 2));
