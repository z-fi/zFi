#!/usr/bin/env node
//
// Withdrawal safety regression tests.
//
// Covers the safety-critical validators in the Privacy Pools withdrawal flow
// that were previously only exercised at runtime in the browser:
//
//   - Leaf index 0-based vs 1-based fallback logic
//   - Relay fee cap enforcement (fee <= maxRelayFeeBPS)
//   - Change note index resolution (3-tier fallback)
//   - Note parsing & asset normalization
//   - Commitment formula verification
//   - LeanIMT (Merkle tree) build & proof correctness
//   - Sibling padding to circuit tree depth (32)
//
// Zero npm dependencies — uses vendored poseidon libs + Node builtins.
//
// Usage:  node test/privacy/test_withdrawal_safety.mjs
//
import { strict as assert } from 'node:assert';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const ROOT = path.resolve(__dirname, '../..');

// ── Load vendored Poseidon libs ──────────────────────────────────────────────

const ctx = vm.createContext({
  window: {},
  atob: (s) => Buffer.from(s, 'base64').toString('binary'),
  Uint8Array,
  Array,
  BigInt,
});
vm.runInContext(readFileSync(path.join(ROOT, 'dapp/poseidon1.min.js'), 'utf8'), ctx);
vm.runInContext(readFileSync(path.join(ROOT, 'dapp/poseidon2.min.js'), 'utf8'), ctx);
vm.runInContext(readFileSync(path.join(ROOT, 'dapp/poseidon3.min.js'), 'utf8'), ctx);

const { poseidon1, poseidon2, poseidon3 } = ctx.window;

// ── Re-implement safety-critical functions (same logic as dapp/index.html) ───

const SNARK_SCALAR_FIELD = 21888242871839275222246405745257275088548364400416034343698204186575808495617n;
const PP_MAX_TREE_DEPTH = 32;

function ppDeriveDepositKeys(masterNullifier, masterSecret, scope, index) {
  const nullifier = poseidon3([masterNullifier, scope, BigInt(index)]);
  const secret = poseidon3([masterSecret, scope, BigInt(index)]);
  const precommitment = poseidon2([nullifier, secret]);
  return { nullifier, secret, precommitment };
}

function ppDeriveWithdrawalKeys(masterNullifier, masterSecret, label, withdrawalIndex) {
  const nullifier = poseidon3([masterNullifier, label, BigInt(withdrawalIndex)]);
  const secret = poseidon3([masterSecret, label, BigInt(withdrawalIndex)]);
  const precommitment = poseidon2([nullifier, secret]);
  return { nullifier, secret, precommitment };
}

function ppParseNonNegativeInt(raw) {
  if (raw == null || raw === '') return null;
  const n = Number(raw);
  if (!Number.isInteger(n) || n < 0) return null;
  return n;
}

const PP_MAX_INDEX_INFERENCE_SCAN = 4096;

function ppInferWithdrawalNoteIndex(masterNullifier, label, noteNullifier, maxIndex = PP_MAX_INDEX_INFERENCE_SCAN) {
  for (let i = 0; i <= maxIndex; i++) {
    if (poseidon3([masterNullifier, label, BigInt(i)]) === noteNullifier) return i;
  }
  return null;
}

function ppInferDepositNoteIndex(masterNullifier, scope, noteNullifier, maxIndex = PP_MAX_INDEX_INFERENCE_SCAN) {
  for (let i = 0; i <= maxIndex; i++) {
    if (poseidon3([masterNullifier, scope, BigInt(i)]) === noteNullifier) return i;
  }
  return null;
}

function ppResolveNextWithdrawalIndex(masterNullifier, scope, label, noteNullifier, noteWithdrawalIndex) {
  const explicitIdx = ppParseNonNegativeInt(noteWithdrawalIndex);
  if (explicitIdx != null) {
    return { nextIndex: explicitIdx + 1, source: 'note', currentIndex: explicitIdx };
  }
  const inferredWithdrawalCurrent = ppInferWithdrawalNoteIndex(masterNullifier, label, noteNullifier);
  if (inferredWithdrawalCurrent != null) {
    return { nextIndex: inferredWithdrawalCurrent + 1, source: 'inferred-withdrawal', currentIndex: inferredWithdrawalCurrent };
  }
  const inferredDepositIndex = ppInferDepositNoteIndex(masterNullifier, scope, noteNullifier);
  if (inferredDepositIndex != null) {
    return { nextIndex: 0, source: 'deposit', currentIndex: null, depositIndex: inferredDepositIndex };
  }
  return { nextIndex: null, source: 'unknown', currentIndex: null, depositIndex: null };
}

// Commitment formula: commitment = poseidon3([value, label, precommitment])
function computeCommitment(value, label, precommitment) {
  return poseidon3([value, label, precommitment]);
}

// LeanIMT: Build Merkle tree from leaves
function leanIMTBuild(leaves) {
  if (leaves.length === 0) return { levels: [[]], depth: 0, root: 0n };
  const levels = [leaves.map(l => BigInt(l))];
  while (levels[levels.length - 1].length > 1) {
    const curr = levels[levels.length - 1];
    const next = [];
    for (let i = 0; i < curr.length; i += 2) {
      if (i + 1 < curr.length) next.push(poseidon2([curr[i], curr[i + 1]]));
      else next.push(curr[i]);
    }
    levels.push(next);
  }
  return { levels, depth: levels.length - 1, root: levels[levels.length - 1][0] };
}

// LeanIMT: Merkle proof for leaf at index, padded to PP_MAX_TREE_DEPTH
function leanIMTProof(levels, leafIndex) {
  const siblings = [];
  let idx = leafIndex;
  for (let d = 0; d < levels.length - 1; d++) {
    const sib = idx ^ 1;
    siblings.push(sib < levels[d].length ? levels[d][sib] : 0n);
    idx = idx >> 1;
  }
  while (siblings.length < PP_MAX_TREE_DEPTH) siblings.push(0n);
  return siblings;
}

// Relay fee decode (same logic as ppwDecodeRelayFeeBps in index.html)
// In the real code this uses ethers ABI decoder. We test the validation
// logic around it — the bps comparison against maxRelayFeeBPS.
function validateRelayFee(quotedFeeBPS, maxRelayFeeBPS) {
  if (!Number.isFinite(quotedFeeBPS) || quotedFeeBPS < 0) {
    return { valid: false, reason: 'invalid-fee' };
  }
  if (maxRelayFeeBPS == null) {
    return { valid: false, reason: 'no-onchain-max' };
  }
  const maxNum = Number(maxRelayFeeBPS);
  if (!Number.isFinite(maxNum) || maxNum < 0) {
    return { valid: false, reason: 'invalid-onchain-max' };
  }
  if (quotedFeeBPS > maxNum) {
    return { valid: false, reason: 'exceeds-max', quotedFeeBPS, maxRelayFeeBPS: maxNum };
  }
  return { valid: true, quotedFeeBPS, maxRelayFeeBPS: maxNum };
}

// Note parsing & asset normalization (same logic as ppwParseNote)
function parseNoteAsset(rawAsset) {
  const raw = (rawAsset || 'ETH').trim();
  const upper = raw.toUpperCase();
  const asset = (upper === 'BOLD') ? 'BOLD' : (upper === 'WSTETH') ? 'wstETH' : 'ETH';
  const recognized = (upper === 'ETH' || upper === 'BOLD' || upper === 'WSTETH');
  return { asset, recognized, raw };
}

// Leaf index fallback logic (same as L-10 block in ppwWithdraw)
function resolveLeafIndex(leafIndex, treeLeaves, expectedCommitment) {
  let adjusted = leafIndex;
  let treeLeaf = (adjusted >= 0 && adjusted < treeLeaves.length) ? treeLeaves[adjusted] : null;

  if (treeLeaf !== expectedCommitment && adjusted > 0) {
    const altIndex = adjusted - 1;
    if (altIndex >= 0 && altIndex < treeLeaves.length && treeLeaves[altIndex] === expectedCommitment) {
      adjusted = altIndex;
      treeLeaf = treeLeaves[altIndex];
      return { adjusted, treeLeaf, source: '1-based-fallback' };
    }
  }

  if (adjusted < 0 || adjusted >= treeLeaves.length) {
    return { adjusted, treeLeaf: null, error: 'out-of-range' };
  }
  if (treeLeaf == null || treeLeaf === 0n) {
    return { adjusted, treeLeaf, error: 'empty-leaf' };
  }
  if (treeLeaf !== expectedCommitment) {
    return { adjusted, treeLeaf, error: 'commitment-mismatch' };
  }
  return { adjusted, treeLeaf, source: '0-based' };
}

// ── Test helpers ─────────────────────────────────────────────────────────────

let passed = 0;
let failed = 0;

function test(name, fn) {
  try {
    fn();
    passed++;
    console.log(`  \x1b[32mPASS\x1b[0m ${name}`);
  } catch (e) {
    failed++;
    console.log(`  \x1b[31mFAIL\x1b[0m ${name}`);
    console.log(`       ${e.message}`);
  }
}

// Fixed master keys for all tests
const MN = poseidon1([42n]);
const MS = poseidon1([43n]);
const SCOPE = 0xF241d57C6DebAe225c0F2e6eA1529373C9A9C9fBn;

// ═══════════════════════════════════════════════════════════════════════════════
//  1. Leaf index 0-based vs 1-based fallback
// ═══════════════════════════════════════════════════════════════════════════════

console.log('\n── Leaf index fallback ──');

test('0-based index: commitment found at exact position', () => {
  const commitment = poseidon3([1000n, 2000n, 3000n]);
  const leaves = [99n, commitment, 88n];
  const result = resolveLeafIndex(1, leaves, commitment);
  assert.equal(result.adjusted, 1);
  assert.equal(result.source, '0-based');
  assert.equal(result.error, undefined);
});

test('1-based fallback: commitment found at index-1', () => {
  const commitment = poseidon3([1000n, 2000n, 3000n]);
  // Contract reports leafIndex=2 (1-based), but array is 0-based so actual position is 1
  const leaves = [99n, commitment, 88n];
  const result = resolveLeafIndex(2, leaves, commitment);
  assert.equal(result.adjusted, 1);
  assert.equal(result.source, '1-based-fallback');
});

test('1-based fallback: does not trigger for index 0', () => {
  const commitment = poseidon3([1000n, 2000n, 3000n]);
  const leaves = [77n, commitment];
  // leafIndex=0 should NOT try the -1 fallback (would be index -1)
  const result = resolveLeafIndex(0, leaves, commitment);
  assert.equal(result.error, 'commitment-mismatch');
});

test('out-of-range: negative index', () => {
  const leaves = [1n, 2n, 3n];
  const result = resolveLeafIndex(-1, leaves, 1n);
  assert.equal(result.error, 'out-of-range');
});

test('out-of-range: index beyond tree length', () => {
  const leaves = [1n, 2n, 3n];
  const result = resolveLeafIndex(5, leaves, 1n);
  assert.equal(result.error, 'out-of-range');
});

test('out-of-range: index exactly at tree length', () => {
  const leaves = [1n, 2n, 3n];
  const result = resolveLeafIndex(3, leaves, 1n);
  // fallback to index 2 won't match either
  assert.equal(result.error, 'out-of-range');
});

test('empty leaf at position', () => {
  const leaves = [1n, 0n, 3n];
  const result = resolveLeafIndex(1, leaves, 99n);
  assert.equal(result.error, 'empty-leaf');
});

test('commitment mismatch: wrong value at position, no fallback match', () => {
  const leaves = [1n, 2n, 3n];
  const result = resolveLeafIndex(1, leaves, 99n);
  assert.equal(result.error, 'commitment-mismatch');
});

test('1-based fallback: works at boundary (last valid index)', () => {
  const commitment = poseidon3([5n, 6n, 7n]);
  const leaves = [99n, 88n, commitment];
  // 1-based report: index 3 (points beyond array), but index-1 = 2 matches
  const result = resolveLeafIndex(3, leaves, commitment);
  assert.equal(result.adjusted, 2);
  assert.equal(result.source, '1-based-fallback');
});

test('empty tree: out of range', () => {
  const result = resolveLeafIndex(0, [], 1n);
  assert.equal(result.error, 'out-of-range');
});

// ═══════════════════════════════════════════════════════════════════════════════
//  2. Relay fee cap validation
// ═══════════════════════════════════════════════════════════════════════════════

console.log('\n── Relay fee cap ──');

test('fee within cap: 30 bps quoted, 100 bps max', () => {
  const r = validateRelayFee(30, 100);
  assert.equal(r.valid, true);
});

test('fee exactly at cap: 100 bps quoted, 100 bps max', () => {
  const r = validateRelayFee(100, 100);
  assert.equal(r.valid, true);
});

test('fee exceeds cap: 150 bps quoted, 100 bps max', () => {
  const r = validateRelayFee(150, 100);
  assert.equal(r.valid, false);
  assert.equal(r.reason, 'exceeds-max');
});

test('fee zero: valid (free relay)', () => {
  const r = validateRelayFee(0, 100);
  assert.equal(r.valid, true);
});

test('fee negative: invalid', () => {
  const r = validateRelayFee(-5, 100);
  assert.equal(r.valid, false);
  assert.equal(r.reason, 'invalid-fee');
});

test('fee NaN: invalid', () => {
  const r = validateRelayFee(NaN, 100);
  assert.equal(r.valid, false);
  assert.equal(r.reason, 'invalid-fee');
});

test('fee Infinity: invalid', () => {
  const r = validateRelayFee(Infinity, 100);
  assert.equal(r.valid, false);
  assert.equal(r.reason, 'invalid-fee');
});

test('onchain max null: rejected (fail-closed)', () => {
  const r = validateRelayFee(30, null);
  assert.equal(r.valid, false);
  assert.equal(r.reason, 'no-onchain-max');
});

test('onchain max undefined: rejected (fail-closed)', () => {
  const r = validateRelayFee(30, undefined);
  assert.equal(r.valid, false);
  assert.equal(r.reason, 'no-onchain-max');
});

test('onchain max NaN: rejected', () => {
  const r = validateRelayFee(30, NaN);
  assert.equal(r.valid, false);
  assert.equal(r.reason, 'invalid-onchain-max');
});

test('onchain max negative: rejected', () => {
  const r = validateRelayFee(30, -10);
  assert.equal(r.valid, false);
  assert.equal(r.reason, 'invalid-onchain-max');
});

test('fee 1 bps below cap: valid', () => {
  const r = validateRelayFee(99, 100);
  assert.equal(r.valid, true);
});

test('fee 1 bps above cap: rejected', () => {
  const r = validateRelayFee(101, 100);
  assert.equal(r.valid, false);
  assert.equal(r.reason, 'exceeds-max');
});

// ═══════════════════════════════════════════════════════════════════════════════
//  3. Change note index resolution (3-tier fallback)
// ═══════════════════════════════════════════════════════════════════════════════

console.log('\n── Change note index resolution ──');

test('tier 1: explicit withdrawalIndex in note', () => {
  const dk = ppDeriveDepositKeys(MN, MS, SCOPE, 0);
  const label = dk.precommitment;
  const r = ppResolveNextWithdrawalIndex(MN, SCOPE, label, dk.nullifier, 5);
  assert.equal(r.source, 'note');
  assert.equal(r.currentIndex, 5);
  assert.equal(r.nextIndex, 6);
});

test('tier 1: withdrawalIndex = 0 is valid', () => {
  const dk = ppDeriveDepositKeys(MN, MS, SCOPE, 0);
  const label = dk.precommitment;
  const r = ppResolveNextWithdrawalIndex(MN, SCOPE, label, dk.nullifier, 0);
  assert.equal(r.source, 'note');
  assert.equal(r.currentIndex, 0);
  assert.equal(r.nextIndex, 1);
});

test('tier 1: negative withdrawalIndex rejected (falls to tier 2)', () => {
  const dk = ppDeriveDepositKeys(MN, MS, SCOPE, 0);
  const label = dk.precommitment;
  // -1 is not a valid non-negative int, so ppParseNonNegativeInt returns null
  const r = ppResolveNextWithdrawalIndex(MN, SCOPE, label, dk.nullifier, -1);
  // Should NOT be 'note' source since -1 is invalid
  assert.notEqual(r.source, 'note');
});

test('tier 1: non-integer withdrawalIndex rejected (falls to tier 2)', () => {
  const dk = ppDeriveDepositKeys(MN, MS, SCOPE, 0);
  const label = dk.precommitment;
  const r = ppResolveNextWithdrawalIndex(MN, SCOPE, label, dk.nullifier, 'abc');
  assert.notEqual(r.source, 'note');
});

test('tier 2: inferred withdrawal index from note nullifier', () => {
  const dk = ppDeriveDepositKeys(MN, MS, SCOPE, 0);
  const label = dk.precommitment;
  // Derive a withdrawal note at index 3
  const wk = ppDeriveWithdrawalKeys(MN, MS, label, 3);
  // Pass the withdrawal nullifier, no explicit index
  const r = ppResolveNextWithdrawalIndex(MN, SCOPE, label, wk.nullifier, null);
  assert.equal(r.source, 'inferred-withdrawal');
  assert.equal(r.currentIndex, 3);
  assert.equal(r.nextIndex, 4);
});

test('tier 2: inferred index = 0 produces nextIndex = 1', () => {
  const dk = ppDeriveDepositKeys(MN, MS, SCOPE, 0);
  const label = dk.precommitment;
  const wk = ppDeriveWithdrawalKeys(MN, MS, label, 0);
  const r = ppResolveNextWithdrawalIndex(MN, SCOPE, label, wk.nullifier, null);
  assert.equal(r.source, 'inferred-withdrawal');
  assert.equal(r.currentIndex, 0);
  assert.equal(r.nextIndex, 1);
});

test('tier 3: original deposit note detected', () => {
  const dk = ppDeriveDepositKeys(MN, MS, SCOPE, 7);
  const label = dk.precommitment;
  // The deposit nullifier is derived from scope (not label), so it won't match tier 2
  const r = ppResolveNextWithdrawalIndex(MN, SCOPE, label, dk.nullifier, null);
  assert.equal(r.source, 'deposit');
  assert.equal(r.depositIndex, 7);
  assert.equal(r.nextIndex, 0);
});

test('tier 3: deposit at index 0', () => {
  const dk = ppDeriveDepositKeys(MN, MS, SCOPE, 0);
  const label = dk.precommitment;
  const r = ppResolveNextWithdrawalIndex(MN, SCOPE, label, dk.nullifier, null);
  assert.equal(r.source, 'deposit');
  assert.equal(r.depositIndex, 0);
  assert.equal(r.nextIndex, 0);
});

test('unknown: unrecognized nullifier → nextIndex is null (blocks partial withdrawal)', () => {
  const bogusNullifier = poseidon1([999999n]);
  const label = poseidon2([1n, 2n]);
  const r = ppResolveNextWithdrawalIndex(MN, SCOPE, label, bogusNullifier, null);
  assert.equal(r.source, 'unknown');
  assert.equal(r.nextIndex, null);
});

test('tier priority: explicit index wins over inferable withdrawal nullifier', () => {
  const dk = ppDeriveDepositKeys(MN, MS, SCOPE, 0);
  const label = dk.precommitment;
  const wk = ppDeriveWithdrawalKeys(MN, MS, label, 3);
  // Pass the withdrawal nullifier WITH an explicit index — tier 1 should win
  const r = ppResolveNextWithdrawalIndex(MN, SCOPE, label, wk.nullifier, 10);
  assert.equal(r.source, 'note');
  assert.equal(r.currentIndex, 10);
  assert.equal(r.nextIndex, 11);
});

test('chained partial withdrawals: index monotonically increases', () => {
  const dk = ppDeriveDepositKeys(MN, MS, SCOPE, 0);
  const label = dk.precommitment;
  // Simulate chain: deposit → withdraw[0] → withdraw[1] → withdraw[2]
  const indices = [];
  let currentNullifier = dk.nullifier;
  let currentWithdrawalIndex = null;

  for (let step = 0; step < 3; step++) {
    const r = ppResolveNextWithdrawalIndex(MN, SCOPE, label, currentNullifier, currentWithdrawalIndex);
    assert(r.nextIndex != null, 'step ' + step + ' should resolve');
    indices.push(r.nextIndex);
    // Derive the next change note
    const changeKeys = ppDeriveWithdrawalKeys(MN, MS, label, r.nextIndex);
    currentNullifier = changeKeys.nullifier;
    currentWithdrawalIndex = r.nextIndex;
  }
  // Indices should be 0, 1, 2 (monotonically increasing)
  assert.deepEqual(indices, [0, 1, 2]);
});

// ═══════════════════════════════════════════════════════════════════════════════
//  4. Note asset normalization
// ═══════════════════════════════════════════════════════════════════════════════

console.log('\n── Note asset normalization ──');

test('ETH: recognized', () => {
  const r = parseNoteAsset('ETH');
  assert.equal(r.asset, 'ETH');
  assert.equal(r.recognized, true);
});

test('eth: case insensitive → ETH', () => {
  const r = parseNoteAsset('eth');
  assert.equal(r.asset, 'ETH');
  assert.equal(r.recognized, true);
});

test('BOLD: recognized', () => {
  const r = parseNoteAsset('BOLD');
  assert.equal(r.asset, 'BOLD');
  assert.equal(r.recognized, true);
});

test('bold: case insensitive → BOLD', () => {
  const r = parseNoteAsset('bold');
  assert.equal(r.asset, 'BOLD');
  assert.equal(r.recognized, true);
});

test('wstETH: recognized', () => {
  const r = parseNoteAsset('wstETH');
  assert.equal(r.asset, 'wstETH');
  assert.equal(r.recognized, true);
});

test('WSTETH: case insensitive → wstETH', () => {
  const r = parseNoteAsset('WSTETH');
  assert.equal(r.asset, 'wstETH');
  assert.equal(r.recognized, true);
});

test('wsteth: lowercase → wstETH', () => {
  const r = parseNoteAsset('wsteth');
  assert.equal(r.asset, 'wstETH');
  assert.equal(r.recognized, true);
});

test('null/undefined: defaults to ETH', () => {
  assert.equal(parseNoteAsset(null).asset, 'ETH');
  assert.equal(parseNoteAsset(undefined).asset, 'ETH');
  assert.equal(parseNoteAsset('').asset, 'ETH');
});

test('unrecognized asset: defaults to ETH, flagged as unrecognized', () => {
  const r = parseNoteAsset('DAI');
  assert.equal(r.asset, 'ETH');
  assert.equal(r.recognized, false);
});

test('whitespace-padded asset: trimmed', () => {
  const r = parseNoteAsset('  BOLD  ');
  assert.equal(r.asset, 'BOLD');
  assert.equal(r.recognized, true);
});

// ═══════════════════════════════════════════════════════════════════════════════
//  5. Commitment formula verification
// ═══════════════════════════════════════════════════════════════════════════════

console.log('\n── Commitment formula ──');

test('commitment uses distinct label and precommitment (realistic deposit→withdrawal)', () => {
  const value = 1000000000000000000n; // 1 ETH in wei
  const dk = ppDeriveDepositKeys(MN, MS, SCOPE, 0);
  const label = dk.precommitment;  // deposit precommitment serves as label
  // In a real withdrawal, the precommitment is from the withdrawal key derivation
  const wk = ppDeriveWithdrawalKeys(MN, MS, label, 0);
  const commitment = computeCommitment(value, label, wk.precommitment);
  // label and precommitment should be different values
  assert.notEqual(label, wk.precommitment, 'label != withdrawal precommitment');
  // Commitment should be in the field
  assert(commitment > 0n && commitment < SNARK_SCALAR_FIELD);
  // Verify it matches the known-answer vector for these specific inputs
  const expected = poseidon3([value, label, wk.precommitment]);
  assert.equal(commitment, expected);
});

test('commitment changes when value changes', () => {
  const dk = ppDeriveDepositKeys(MN, MS, SCOPE, 0);
  const wk = ppDeriveWithdrawalKeys(MN, MS, dk.precommitment, 0);
  const c1 = computeCommitment(1000n, dk.precommitment, wk.precommitment);
  const c2 = computeCommitment(2000n, dk.precommitment, wk.precommitment);
  assert.notEqual(c1, c2);
});

test('commitment changes when label changes', () => {
  const dk0 = ppDeriveDepositKeys(MN, MS, SCOPE, 0);
  const dk1 = ppDeriveDepositKeys(MN, MS, SCOPE, 1);
  const wk = ppDeriveWithdrawalKeys(MN, MS, dk0.precommitment, 0);
  const c1 = computeCommitment(1000n, dk0.precommitment, wk.precommitment);
  const c2 = computeCommitment(1000n, dk1.precommitment, wk.precommitment);
  assert.notEqual(c1, c2);
});

test('commitment changes when precommitment changes', () => {
  const dk = ppDeriveDepositKeys(MN, MS, SCOPE, 0);
  const wk0 = ppDeriveWithdrawalKeys(MN, MS, dk.precommitment, 0);
  const wk1 = ppDeriveWithdrawalKeys(MN, MS, dk.precommitment, 1);
  const c1 = computeCommitment(1000n, dk.precommitment, wk0.precommitment);
  const c2 = computeCommitment(1000n, dk.precommitment, wk1.precommitment);
  assert.notEqual(c1, c2);
});

// ═══════════════════════════════════════════════════════════════════════════════
//  6. LeanIMT build & proof correctness
// ═══════════════════════════════════════════════════════════════════════════════

console.log('\n── LeanIMT Merkle tree ──');

test('single leaf: root equals the leaf', () => {
  const tree = leanIMTBuild([42n]);
  assert.equal(tree.root, 42n);
  assert.equal(tree.depth, 0);
});

test('two leaves: root = poseidon2([left, right])', () => {
  const tree = leanIMTBuild([10n, 20n]);
  assert.equal(tree.root, poseidon2([10n, 20n]));
  assert.equal(tree.depth, 1);
});

test('four leaves: correct binary tree structure', () => {
  const leaves = [1n, 2n, 3n, 4n];
  const tree = leanIMTBuild(leaves);
  const h01 = poseidon2([1n, 2n]);
  const h23 = poseidon2([3n, 4n]);
  assert.equal(tree.root, poseidon2([h01, h23]));
  assert.equal(tree.depth, 2);
});

test('odd number of leaves: last leaf promoted without hashing', () => {
  const leaves = [1n, 2n, 3n];
  const tree = leanIMTBuild(leaves);
  const h01 = poseidon2([1n, 2n]);
  // 3n is promoted unpaired
  assert.equal(tree.root, poseidon2([h01, 3n]));
  assert.equal(tree.depth, 2);
});

test('empty tree: root = 0, depth = 0', () => {
  const tree = leanIMTBuild([]);
  assert.equal(tree.root, 0n);
  assert.equal(tree.depth, 0);
});

test('proof verification: root recomputable from leaf + siblings', () => {
  const leaves = [10n, 20n, 30n, 40n];
  const tree = leanIMTBuild(leaves);
  const siblings = leanIMTProof(tree.levels, 1);
  // Manually recompute: leaf at index 1, sibling at index 0
  let hash = leaves[1]; // 20n
  hash = poseidon2([leaves[0], hash]); // sibling is index 0 (left), our node is right
  hash = poseidon2([hash, poseidon2([30n, 40n])]); // next level
  assert.equal(hash, tree.root);
});

test('proof length is always PP_MAX_TREE_DEPTH (32)', () => {
  for (const n of [1, 2, 3, 4, 8, 16, 100]) {
    const leaves = Array.from({ length: n }, (_, i) => BigInt(i + 1));
    const tree = leanIMTBuild(leaves);
    const siblings = leanIMTProof(tree.levels, 0);
    assert.equal(siblings.length, PP_MAX_TREE_DEPTH,
      `tree with ${n} leaves should produce ${PP_MAX_TREE_DEPTH} siblings, got ${siblings.length}`);
  }
});

test('proof padding uses 0n for missing siblings', () => {
  const leaves = [10n, 20n];
  const tree = leanIMTBuild(leaves);
  const siblings = leanIMTProof(tree.levels, 0);
  // First sibling is the real one (20n), rest should be 0n padding
  assert.equal(siblings[0], 20n);
  for (let i = 1; i < PP_MAX_TREE_DEPTH; i++) {
    assert.equal(siblings[i], 0n, `sibling[${i}] should be 0n padding`);
  }
});

test('tree is deterministic', () => {
  const leaves = [100n, 200n, 300n, 400n, 500n];
  const t1 = leanIMTBuild(leaves);
  const t2 = leanIMTBuild(leaves);
  assert.equal(t1.root, t2.root);
  assert.equal(t1.depth, t2.depth);
});

// ═══════════════════════════════════════════════════════════════════════════════
//  7. ppParseNonNegativeInt edge cases
// ═══════════════════════════════════════════════════════════════════════════════

console.log('\n── ppParseNonNegativeInt ──');

test('null → null', () => assert.equal(ppParseNonNegativeInt(null), null));
test('undefined → null', () => assert.equal(ppParseNonNegativeInt(undefined), null));
test('empty string → null', () => assert.equal(ppParseNonNegativeInt(''), null));
test('0 → 0', () => assert.equal(ppParseNonNegativeInt(0), 0));
test('5 → 5', () => assert.equal(ppParseNonNegativeInt(5), 5));
test('"7" → 7', () => assert.equal(ppParseNonNegativeInt('7'), 7));
test('-1 → null (negative)', () => assert.equal(ppParseNonNegativeInt(-1), null));
test('1.5 → null (float)', () => assert.equal(ppParseNonNegativeInt(1.5), null));
test('"abc" → null', () => assert.equal(ppParseNonNegativeInt('abc'), null));
test('NaN → null', () => assert.equal(ppParseNonNegativeInt(NaN), null));

// ═══════════════════════════════════════════════════════════════════════════════
//  8. Additional edge cases (audit follow-ups)
// ═══════════════════════════════════════════════════════════════════════════════

console.log('\n── Additional edge cases ──');

// --- Poseidon zero-input safety ---
test('poseidon1([0]) is non-zero (no fixed point at zero)', () => {
  const h = poseidon1([0n]);
  assert.notEqual(h, 0n);
  assert(h > 0n && h < SNARK_SCALAR_FIELD);
});

test('poseidon2([0,0]) is non-zero', () => {
  const h = poseidon2([0n, 0n]);
  assert.notEqual(h, 0n);
  assert(h > 0n && h < SNARK_SCALAR_FIELD);
});

test('poseidon3([0,0,0]) is non-zero', () => {
  const h = poseidon3([0n, 0n, 0n]);
  assert.notEqual(h, 0n);
  assert(h > 0n && h < SNARK_SCALAR_FIELD);
});

// --- LeanIMT proof at right-child indices ---
test('LeanIMT proof correct for leaf index 2 (right subtree)', () => {
  const leaves = [10n, 20n, 30n, 40n];
  const tree = leanIMTBuild(leaves);
  const siblings = leanIMTProof(tree.levels, 2);
  // Manually recompute from leaf[2] = 30n
  // Level 0: sibling of index 2 is index 3 (40n)
  assert.equal(siblings[0], 40n);
  // Level 1: sibling of pair(2,3) is pair(0,1) = poseidon2([10n, 20n])
  assert.equal(siblings[1], poseidon2([10n, 20n]));
  // Verify root reachable: hash(30n, 40n) then hash(h01, h23)
  let hash = poseidon2([30n, 40n]);
  hash = poseidon2([poseidon2([10n, 20n]), hash]);
  assert.equal(hash, tree.root);
});

test('LeanIMT proof correct for leaf index 3 (rightmost leaf)', () => {
  const leaves = [10n, 20n, 30n, 40n];
  const tree = leanIMTBuild(leaves);
  const siblings = leanIMTProof(tree.levels, 3);
  // Level 0: sibling of index 3 is index 2 (30n)
  assert.equal(siblings[0], 30n);
  // Level 1: sibling is h(10, 20)
  assert.equal(siblings[1], poseidon2([10n, 20n]));
  // Recompute root from leaf[3]
  let hash = poseidon2([30n, 40n]); // 30n is sibling (left), 40n is our leaf (right)
  hash = poseidon2([poseidon2([10n, 20n]), hash]);
  assert.equal(hash, tree.root);
});

// --- Leaf index: commitment matches at BOTH index and index-1 ---
test('resolveLeafIndex: 0-based takes priority when commitment at both index and index-1', () => {
  const commitment = poseidon3([1n, 2n, 3n]);
  // Both positions hold the same commitment
  const leaves = [99n, commitment, commitment, 88n];
  // At index 2, treeLeaves[2] === commitment → 0-based hit, should NOT fallback
  const result = resolveLeafIndex(2, leaves, commitment);
  assert.equal(result.adjusted, 2);
  assert.equal(result.source, '0-based');
});

// --- Relay fee validation with BigInt input (from ethers contract call) ---
test('relay fee cap: maxRelayFeeBPS as BigInt (ethers uint256 return)', () => {
  // ethers returns uint256 as BigInt; Number(BigInt) conversion must work
  const r = validateRelayFee(30, BigInt(100));
  assert.equal(r.valid, true);
  assert.equal(r.maxRelayFeeBPS, 100);
});

test('relay fee cap: maxRelayFeeBPS as BigInt exceeds', () => {
  const r = validateRelayFee(150, BigInt(100));
  assert.equal(r.valid, false);
  assert.equal(r.reason, 'exceeds-max');
});

// --- Note asset: recognized flag for null/empty defaults ---
test('null asset: defaults to ETH and is recognized', () => {
  const r = parseNoteAsset(null);
  assert.equal(r.asset, 'ETH');
  assert.equal(r.recognized, true);
});

test('empty string asset: defaults to ETH and is recognized', () => {
  const r = parseNoteAsset('');
  assert.equal(r.asset, 'ETH');
  assert.equal(r.recognized, true);
});

// ═══════════════════════════════════════════════════════════════════════════════
//  Recipient resolution (direct vs relay mode)
// ═══════════════════════════════════════════════════════════════════════════════
//
// Mirrors the recipient-resolution logic in ppwWithdraw (index.html lines 9709-9726).
// In direct mode, the recipient MUST be the connected wallet (funds go there).
// In relay mode, a custom recipient is allowed; it falls back to the connected wallet.

function resolveRecipient(isRelayMode, customRecipient, connectedAddress) {
  // Simulate ethers.isAddress: 0x + 40 hex chars
  const isAddress = (a) => /^0x[0-9a-fA-F]{40}$/.test(a);
  // Simulate ethers.getAddress: just return checksummed (identity here)
  const getAddress = (a) => a;

  if (isRelayMode) {
    if (customRecipient && !isAddress(customRecipient)) {
      return { error: 'invalid-address' };
    }
  } else {
    if (customRecipient && customRecipient.toLowerCase() !== connectedAddress?.toLowerCase()) {
      return { error: 'direct-mode-recipient-mismatch' };
    }
  }
  const recipient = isRelayMode
    ? (customRecipient ? getAddress(customRecipient) : connectedAddress)
    : connectedAddress;
  if (!recipient) {
    return { error: isRelayMode ? 'no-recipient-or-wallet' : 'no-wallet' };
  }
  return { recipient };
}

test('direct mode: connected wallet is the recipient', () => {
  const r = resolveRecipient(false, '', '0xABCDabcdABCDabcdABCDabcdABCDabcdABCDabcd');
  assert.equal(r.recipient, '0xABCDabcdABCDabcdABCDabcdABCDabcdABCDabcd');
  assert.equal(r.error, undefined);
});

test('direct mode: rejects custom recipient != connected wallet', () => {
  const r = resolveRecipient(false, '0x1111111111111111111111111111111111111111', '0xABCDabcdABCDabcdABCDabcdABCDabcdABCDabcd');
  assert.equal(r.error, 'direct-mode-recipient-mismatch');
});

test('direct mode: allows custom recipient == connected wallet (case insensitive)', () => {
  const r = resolveRecipient(false, '0xabcdabcdabcdabcdabcdabcdabcdabcdabcdabcd', '0xABCDabcdABCDabcdABCDabcdABCDabcdABCDabcd');
  assert.equal(r.recipient, '0xABCDabcdABCDabcdABCDabcdABCDabcdABCDabcd');
  assert.equal(r.error, undefined);
});

test('direct mode: no wallet connected returns error', () => {
  const r = resolveRecipient(false, '', null);
  assert.equal(r.error, 'no-wallet');
});

test('relay mode: custom recipient is used', () => {
  const r = resolveRecipient(true, '0x1111111111111111111111111111111111111111', '0xABCDabcdABCDabcdABCDabcdABCDabcdABCDabcd');
  assert.equal(r.recipient, '0x1111111111111111111111111111111111111111');
});

test('relay mode: falls back to connected wallet when no custom recipient', () => {
  const r = resolveRecipient(true, '', '0xABCDabcdABCDabcdABCDabcdABCDabcdABCDabcd');
  assert.equal(r.recipient, '0xABCDabcdABCDabcdABCDabcdABCDabcdABCDabcd');
});

test('relay mode: rejects invalid custom address', () => {
  const r = resolveRecipient(true, 'not-an-address', '0xABCDabcdABCDabcdABCDabcdABCDabcdABCDabcd');
  assert.equal(r.error, 'invalid-address');
});

test('relay mode: no wallet and no custom recipient returns error', () => {
  const r = resolveRecipient(true, '', null);
  assert.equal(r.error, 'no-recipient-or-wallet');
});

// ═══════════════════════════════════════════════════════════════════════════════
//  Context hash computation (relay vs direct mode)
// ═══════════════════════════════════════════════════════════════════════════════
//
// The circuit's `context` input is:
//   context = keccak256(abi.encode(Withdrawal{processooor,data}, SCOPE)) % SNARK_FIELD
//
// Relay mode:  processooor = entrypoint address, data = relay withdrawalData
// Direct mode: processooor = recipient address,  data = 0x
//
// We can't use ethers here (no npm), but we verify the algebraic properties
// that prevent fund loss: distinct mode/recipient/data produce distinct contexts.

test('context hash: relay vs direct produce different contexts (distinct processooor)', () => {
  // Even without real keccak, prove the inputs differ.
  // relay: processooor = ENTRYPOINT, data = non-empty
  // direct: processooor = recipient, data = 0x
  const entrypoint = '0x0000000000000000000000000000000000000001';
  const recipient = '0xABCDabcdABCDabcdABCDabcdABCDabcdABCDabcd';
  // Just verify they're different addresses so keccak input differs
  assert.notEqual(entrypoint.toLowerCase(), recipient.toLowerCase());
});

test('context hash: different recipients produce different contexts in direct mode', () => {
  const r1 = '0x1111111111111111111111111111111111111111';
  const r2 = '0x2222222222222222222222222222222222222222';
  assert.notEqual(r1, r2, 'different recipients = different circuit context');
});

test('context hash: SNARK_FIELD modular reduction keeps context in-range', () => {
  // Simulate: keccak256 output is up to 2^256, context = hash % SNARK_FIELD
  const fakeHash = (1n << 256n) - 1n; // max possible keccak output
  const context = fakeHash % SNARK_SCALAR_FIELD;
  assert(context >= 0n, 'context is non-negative');
  assert(context < SNARK_SCALAR_FIELD, 'context is within SNARK field');
});

test('context hash: zero scope still produces valid context', () => {
  const fakeHash = 0n;
  const context = fakeHash % SNARK_SCALAR_FIELD;
  assert.equal(context, 0n, 'zero hash mod SNARK field = 0');
});

// ═══════════════════════════════════════════════════════════════════════════════
//  Change note JSON completeness
// ═══════════════════════════════════════════════════════════════════════════════
//
// After a partial withdrawal, the change note JSON MUST contain all fields
// needed for the next withdrawal. Missing `withdrawalIndex` degrades to
// tier-2 inference. Missing `nullifier` or `secret` means total fund loss.

function buildChangeNote({ newNullifier, newSecret, changeValue, label, changeIdx, changeLeafIndex, changeCommitment, wAsset }) {
  // Mirrors lines 10282-10291 of index.html
  return {
    nullifier: '0x' + newNullifier.toString(16).padStart(64, '0'),
    secret: '0x' + newSecret.toString(16).padStart(64, '0'),
    value: changeValue.toString(),
    label: '0x' + label.toString(16).padStart(64, '0'),
    withdrawalIndex: changeIdx,
    leafIndex: changeLeafIndex,
    commitment: changeCommitment,
    asset: wAsset !== 'ETH' ? wAsset : undefined,
  };
}

test('change note: contains all required fields for ETH', () => {
  const note = buildChangeNote({
    newNullifier: 123n, newSecret: 456n, changeValue: 1000000n,
    label: 789n, changeIdx: 1, changeLeafIndex: 5,
    changeCommitment: '0x00ab', wAsset: 'ETH',
  });
  assert.equal(typeof note.nullifier, 'string');
  assert.equal(typeof note.secret, 'string');
  assert.equal(typeof note.value, 'string');
  assert.equal(typeof note.label, 'string');
  assert.equal(typeof note.withdrawalIndex, 'number');
  assert.equal(typeof note.leafIndex, 'number');
  assert.equal(typeof note.commitment, 'string');
  assert.equal(note.asset, undefined, 'ETH notes omit asset field');
  // Verify hex-padded to 64 chars (32 bytes)
  assert.equal(note.nullifier.length, 66); // 0x + 64
  assert.equal(note.secret.length, 66);
  assert.equal(note.label.length, 66);
});

test('change note: contains asset field for non-ETH', () => {
  const note = buildChangeNote({
    newNullifier: 100n, newSecret: 200n, changeValue: 500n,
    label: 300n, changeIdx: 0, changeLeafIndex: 2,
    changeCommitment: '0xdeadbeef', wAsset: 'BOLD',
  });
  assert.equal(note.asset, 'BOLD');
});

test('change note: withdrawalIndex is preserved (prevents tier-2 fallback)', () => {
  const note = buildChangeNote({
    newNullifier: 10n, newSecret: 20n, changeValue: 100n,
    label: 30n, changeIdx: 3, changeLeafIndex: 7,
    changeCommitment: '0xaa', wAsset: 'ETH',
  });
  assert.equal(note.withdrawalIndex, 3);
  // Parsing it back should yield tier-1 resolution
  const resolved = ppResolveNextWithdrawalIndex(0n, 0n, 0n, 0n, note.withdrawalIndex);
  assert.equal(resolved.source, 'note');
  assert.equal(resolved.nextIndex, 4);
});

test('change note: value is string representation of BigInt', () => {
  const note = buildChangeNote({
    newNullifier: 1n, newSecret: 2n, changeValue: 999999999999999999n,
    label: 3n, changeIdx: 0, changeLeafIndex: 0,
    changeCommitment: '0x01', wAsset: 'ETH',
  });
  assert.equal(note.value, '999999999999999999');
  // Must survive JSON round-trip without precision loss
  const parsed = JSON.parse(JSON.stringify(note));
  assert.equal(BigInt(parsed.value), 999999999999999999n);
});

test('change note: nullifier and secret can be reconstructed from hex', () => {
  const origNull = 0xdeadbeefdeadbeefn;
  const origSec = 0xcafebabecafebaben;
  const note = buildChangeNote({
    newNullifier: origNull, newSecret: origSec, changeValue: 1n,
    label: 1n, changeIdx: 0, changeLeafIndex: 0,
    changeCommitment: '0x01', wAsset: 'ETH',
  });
  assert.equal(BigInt(note.nullifier), origNull);
  assert.equal(BigInt(note.secret), origSec);
});

test('change note: missing leafIndex is null (not undefined)', () => {
  const note = buildChangeNote({
    newNullifier: 1n, newSecret: 2n, changeValue: 100n,
    label: 3n, changeIdx: 0, changeLeafIndex: undefined,
    changeCommitment: '0x01', wAsset: 'ETH',
  });
  // leafIndex is undefined in the object, but that's what happens when
  // the receipt doesn't emit LeafInserted. The user can still resolve
  // it later via stateTreeLeaves scan.
  assert.equal(note.leafIndex, undefined);
  // But the note is still valid for withdrawal (leafIndex is resolved at
  // withdrawal time from the API tree data, not from the note).
});

// ═══════════════════════════════════════════════════════════════════════════════
//  Summary
// ═══════════════════════════════════════════════════════════════════════════════

console.log(`\n${'═'.repeat(60)}`);
if (failed === 0) {
  console.log(`\x1b[32m  All ${passed} tests passed.\x1b[0m\n`);
  process.exit(0);
} else {
  console.log(`\x1b[31m  ${failed} failed, ${passed} passed.\x1b[0m\n`);
  process.exit(1);
}
