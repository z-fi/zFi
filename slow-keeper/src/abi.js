// Minimal ABI slices for the SLOW keeper. Only the members the bot actually
// touches -- full source: https://sourcify.dev (mainnet, SLOW.sol).

export const GATE_ABI = [
  {
    type: "event",
    name: "TipPosted",
    inputs: [
      { name: "transferId", type: "uint256", indexed: true },
      { name: "amount", type: "uint96", indexed: false },
      { name: "sender", type: "address", indexed: true },
      { name: "to", type: "address", indexed: true },
    ],
  },
  {
    type: "function",
    name: "claim",
    stateMutability: "nonpayable",
    inputs: [{ name: "transferId", type: "uint256" }],
    outputs: [],
  },
  {
    type: "function",
    name: "claimMany",
    stateMutability: "nonpayable",
    inputs: [{ name: "transferIds", type: "uint256[]" }],
    outputs: [],
  },
  {
    type: "function",
    name: "tips",
    stateMutability: "view",
    inputs: [{ name: "transferId", type: "uint256" }],
    outputs: [
      { name: "amount", type: "uint96" },
      { name: "sender", type: "address" },
    ],
  },
];

export const SLOW_ABI = [
  {
    type: "function",
    name: "pendingTransfers",
    stateMutability: "view",
    inputs: [{ name: "transferId", type: "uint256" }],
    outputs: [
      { name: "timestamp", type: "uint96" },
      { name: "from", type: "address" },
      { name: "to", type: "address" },
      { name: "id", type: "uint256" },
      { name: "amount", type: "uint256" },
    ],
  },
  {
    type: "function",
    name: "guardians",
    stateMutability: "view",
    inputs: [{ name: "user", type: "address" }],
    outputs: [{ name: "", type: "address" }],
  },
  {
    type: "function",
    name: "gate",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "", type: "address" }],
  },
];
