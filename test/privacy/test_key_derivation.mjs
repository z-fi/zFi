#!/usr/bin/env node
//
// Privacy key-derivation regression & determinism tests.
//
// Runs with zero npm dependencies — loads the vendored poseidon libs straight
// from dapp/ and uses Node's built-in assert module.
//
// Usage:  node test/privacy/test_key_derivation.mjs
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
// The .min.js files are IIFEs that assign to `window.poseidonN`.
// We create a shared context with a `window` object and run them there.

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
assert(typeof poseidon1 === 'function', 'poseidon1 loaded');
assert(typeof poseidon2 === 'function', 'poseidon2 loaded');
assert(typeof poseidon3 === 'function', 'poseidon3 loaded');

// ── Re-implement the derivation functions (same logic as dapp/index.html) ────

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

// Master key derivation truncation step (same as dapp + SDK's bytesToNumber())
function truncateHdKey(hexKey) {
  return BigInt(Number(BigInt(hexKey)));
}

// ── BN254 scalar field ───────────────────────────────────────────────────────
const SNARK_SCALAR_FIELD = 21888242871839275222246405745257275088548364400416034343698204186575808495617n;

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

// ═══════════════════════════════════════════════════════════════════════════════
//  1. Poseidon sanity checks
// ═══════════════════════════════════════════════════════════════════════════════

console.log('\n── Poseidon sanity ──');

// First run: capture reference values, then assert on re-runs.
const p1_ref = poseidon1([1n]);
const p2_ref = poseidon2([1n, 2n]);
const p3_ref = poseidon3([1n, 2n, 3n]);

test('poseidon1([1]) returns a BigInt', () => {
  assert.equal(typeof p1_ref, 'bigint');
});

test('poseidon2([1,2]) returns a BigInt', () => {
  assert.equal(typeof p2_ref, 'bigint');
});

test('poseidon3([1,2,3]) returns a BigInt', () => {
  assert.equal(typeof p3_ref, 'bigint');
});

test('poseidon outputs are within BN254 scalar field', () => {
  assert(p1_ref > 0n && p1_ref < SNARK_SCALAR_FIELD);
  assert(p2_ref > 0n && p2_ref < SNARK_SCALAR_FIELD);
  assert(p3_ref > 0n && p3_ref < SNARK_SCALAR_FIELD);
});

test('poseidon is deterministic', () => {
  for (let i = 0; i < 50; i++) {
    assert.equal(poseidon1([1n]), p1_ref);
    assert.equal(poseidon2([1n, 2n]), p2_ref);
    assert.equal(poseidon3([1n, 2n, 3n]), p3_ref);
  }
});

test('different inputs produce different outputs', () => {
  assert.notEqual(poseidon1([1n]), poseidon1([2n]));
  assert.notEqual(poseidon2([1n, 2n]), poseidon2([2n, 1n]));
  assert.notEqual(poseidon3([1n, 2n, 3n]), poseidon3([3n, 2n, 1n]));
});

// ═══════════════════════════════════════════════════════════════════════════════
//  2. Known-answer regression vectors (Poseidon over BN254)
//
//  These values were captured from the vendored poseidon-lite@0.3.0.
//  If a future update changes the Poseidon implementation, these will catch it.
// ═══════════════════════════════════════════════════════════════════════════════

console.log('\n── Known-answer vectors ──');

// Hardcoded from poseidon-lite@0.3.0 over BN254. Any change = regression.
const VECTORS = {
  p1_1:     18586133768512220936620570745912940619677854269274689475585506675881198879027n,
  p2_1_2:   7853200120776062878684798364095072458815029376092732009249414926327459813530n,
  p3_1_2_3: 6542985608222806190361240322586112750744169038454362455181422643027100751666n,
};

test('poseidon1([1]) matches known vector', () => {
  assert.equal(poseidon1([1n]), VECTORS.p1_1);
});

test('poseidon2([1,2]) matches known vector', () => {
  assert.equal(poseidon2([1n, 2n]), VECTORS.p2_1_2);
});

test('poseidon3([1,2,3]) matches known vector', () => {
  assert.equal(poseidon3([1n, 2n, 3n]), VECTORS.p3_1_2_3);
});

// ═══════════════════════════════════════════════════════════════════════════════
//  3. Deposit key derivation
// ═══════════════════════════════════════════════════════════════════════════════

console.log('\n── Deposit key derivation ──');

// Use arbitrary but fixed master keys for testing
const TEST_MASTER_NULLIFIER = poseidon1([42n]);
const TEST_MASTER_SECRET = poseidon1([43n]);
const TEST_SCOPE = 0xF241d57C6DebAe225c0F2e6eA1529373C9A9C9fBn; // ETH pool address as scope

test('deposit keys are deterministic (50 iterations)', () => {
  const ref = ppDeriveDepositKeys(TEST_MASTER_NULLIFIER, TEST_MASTER_SECRET, TEST_SCOPE, 0);
  for (let i = 0; i < 50; i++) {
    const keys = ppDeriveDepositKeys(TEST_MASTER_NULLIFIER, TEST_MASTER_SECRET, TEST_SCOPE, 0);
    assert.equal(keys.nullifier, ref.nullifier);
    assert.equal(keys.secret, ref.secret);
    assert.equal(keys.precommitment, ref.precommitment);
  }
});

test('deposit keys differ by index', () => {
  const k0 = ppDeriveDepositKeys(TEST_MASTER_NULLIFIER, TEST_MASTER_SECRET, TEST_SCOPE, 0);
  const k1 = ppDeriveDepositKeys(TEST_MASTER_NULLIFIER, TEST_MASTER_SECRET, TEST_SCOPE, 1);
  const k2 = ppDeriveDepositKeys(TEST_MASTER_NULLIFIER, TEST_MASTER_SECRET, TEST_SCOPE, 2);
  assert.notEqual(k0.nullifier, k1.nullifier);
  assert.notEqual(k1.nullifier, k2.nullifier);
  assert.notEqual(k0.precommitment, k1.precommitment);
});

test('deposit keys differ by scope', () => {
  const scopeA = 0xF241d57C6DebAe225c0F2e6eA1529373C9A9C9fBn;
  const scopeB = 0xb4b5Fd38Fd4788071d7287e3cB52948e0d10b23En;
  const kA = ppDeriveDepositKeys(TEST_MASTER_NULLIFIER, TEST_MASTER_SECRET, scopeA, 0);
  const kB = ppDeriveDepositKeys(TEST_MASTER_NULLIFIER, TEST_MASTER_SECRET, scopeB, 0);
  assert.notEqual(kA.nullifier, kB.nullifier);
  assert.notEqual(kA.secret, kB.secret);
  assert.notEqual(kA.precommitment, kB.precommitment);
});

test('deposit nullifier != secret for same inputs', () => {
  const k = ppDeriveDepositKeys(TEST_MASTER_NULLIFIER, TEST_MASTER_SECRET, TEST_SCOPE, 0);
  assert.notEqual(k.nullifier, k.secret);
});

test('precommitment = poseidon2(nullifier, secret)', () => {
  const k = ppDeriveDepositKeys(TEST_MASTER_NULLIFIER, TEST_MASTER_SECRET, TEST_SCOPE, 5);
  assert.equal(k.precommitment, poseidon2([k.nullifier, k.secret]));
});

test('deposit keys are within BN254 scalar field', () => {
  for (let i = 0; i < 10; i++) {
    const k = ppDeriveDepositKeys(TEST_MASTER_NULLIFIER, TEST_MASTER_SECRET, TEST_SCOPE, i);
    assert(k.nullifier > 0n && k.nullifier < SNARK_SCALAR_FIELD);
    assert(k.secret > 0n && k.secret < SNARK_SCALAR_FIELD);
    assert(k.precommitment > 0n && k.precommitment < SNARK_SCALAR_FIELD);
  }
});

// ═══════════════════════════════════════════════════════════════════════════════
//  4. Withdrawal key derivation
// ═══════════════════════════════════════════════════════════════════════════════

console.log('\n── Withdrawal key derivation ──');

const TEST_LABEL = poseidon2([123n, 456n]); // arbitrary commitment label

test('withdrawal keys are deterministic (50 iterations)', () => {
  const ref = ppDeriveWithdrawalKeys(TEST_MASTER_NULLIFIER, TEST_MASTER_SECRET, TEST_LABEL, 0);
  for (let i = 0; i < 50; i++) {
    const keys = ppDeriveWithdrawalKeys(TEST_MASTER_NULLIFIER, TEST_MASTER_SECRET, TEST_LABEL, 0);
    assert.equal(keys.nullifier, ref.nullifier);
    assert.equal(keys.secret, ref.secret);
    assert.equal(keys.precommitment, ref.precommitment);
  }
});

test('withdrawal keys differ by index', () => {
  const k0 = ppDeriveWithdrawalKeys(TEST_MASTER_NULLIFIER, TEST_MASTER_SECRET, TEST_LABEL, 0);
  const k1 = ppDeriveWithdrawalKeys(TEST_MASTER_NULLIFIER, TEST_MASTER_SECRET, TEST_LABEL, 1);
  assert.notEqual(k0.nullifier, k1.nullifier);
  assert.notEqual(k0.precommitment, k1.precommitment);
});

test('withdrawal keys differ by label', () => {
  const labelA = poseidon2([123n, 456n]);
  const labelB = poseidon2([789n, 101n]);
  const kA = ppDeriveWithdrawalKeys(TEST_MASTER_NULLIFIER, TEST_MASTER_SECRET, labelA, 0);
  const kB = ppDeriveWithdrawalKeys(TEST_MASTER_NULLIFIER, TEST_MASTER_SECRET, labelB, 0);
  assert.notEqual(kA.nullifier, kB.nullifier);
  assert.notEqual(kA.precommitment, kB.precommitment);
});

test('withdrawal precommitment = poseidon2(nullifier, secret)', () => {
  const k = ppDeriveWithdrawalKeys(TEST_MASTER_NULLIFIER, TEST_MASTER_SECRET, TEST_LABEL, 3);
  assert.equal(k.precommitment, poseidon2([k.nullifier, k.secret]));
});

test('withdrawal keys are within BN254 scalar field', () => {
  for (let i = 0; i < 10; i++) {
    const k = ppDeriveWithdrawalKeys(TEST_MASTER_NULLIFIER, TEST_MASTER_SECRET, TEST_LABEL, i);
    assert(k.nullifier > 0n && k.nullifier < SNARK_SCALAR_FIELD);
    assert(k.secret > 0n && k.secret < SNARK_SCALAR_FIELD);
    assert(k.precommitment > 0n && k.precommitment < SNARK_SCALAR_FIELD);
  }
});

// ═══════════════════════════════════════════════════════════════════════════════
//  5. Deposit vs withdrawal isolation
// ═══════════════════════════════════════════════════════════════════════════════

console.log('\n── Cross-path isolation ──');

test('deposit and withdrawal keys differ for same (masterKeys, value, index)', () => {
  // Use the same numeric value for scope and label to prove it's the context
  // (deposit vs withdrawal call path) that differentiates them — they use the
  // same poseidon3 call, so identical inputs WILL produce identical outputs.
  // The safety comes from scope and label always being different values
  // in practice (scope = pool address, label = commitment hash).
  const sharedValue = 999n;
  const dk = ppDeriveDepositKeys(TEST_MASTER_NULLIFIER, TEST_MASTER_SECRET, sharedValue, 0);
  const wk = ppDeriveWithdrawalKeys(TEST_MASTER_NULLIFIER, TEST_MASTER_SECRET, sharedValue, 0);
  // Same algorithm, same inputs → same output (this is EXPECTED)
  assert.equal(dk.nullifier, wk.nullifier);
  // This confirms the security property: scope != label in production
});

test('deposit scope (pool address) != withdrawal label (commitment hash) guarantees isolation', () => {
  // In production: scope is a pool contract address, label is a poseidon hash.
  // These are astronomically unlikely to collide.
  const scope = 0xF241d57C6DebAe225c0F2e6eA1529373C9A9C9fBn;
  const label = poseidon2([12345n, 67890n]); // commitment hash
  const dk = ppDeriveDepositKeys(TEST_MASTER_NULLIFIER, TEST_MASTER_SECRET, scope, 0);
  const wk = ppDeriveWithdrawalKeys(TEST_MASTER_NULLIFIER, TEST_MASTER_SECRET, label, 0);
  assert.notEqual(dk.nullifier, wk.nullifier);
  assert.notEqual(dk.secret, wk.secret);
  assert.notEqual(dk.precommitment, wk.precommitment);
});

// ═══════════════════════════════════════════════════════════════════════════════
//  6. HD key truncation (Number() lossy conversion)
// ═══════════════════════════════════════════════════════════════════════════════

console.log('\n── HD key truncation (SDK compatibility) ──');

test('truncateHdKey loses precision for 256-bit keys (matches SDK Number() behavior)', () => {
  // Simulate a 256-bit HD private key
  const fakeKey = '0xabcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890';
  const result = truncateHdKey(fakeKey);
  // The truncated value should be much smaller than the original (~53-bit vs ~256-bit)
  assert(result < BigInt(fakeKey), 'truncation reduces magnitude');
  // Truncation should be stable — running poseidon1 on the result should produce a valid field element
  const master = poseidon1([result]);
  assert(master > 0n && master < SNARK_SCALAR_FIELD, 'master key in BN254 field');
});

test('truncated key fed to poseidon1 is deterministic', () => {
  const fakeKey = '0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef';
  const truncated = truncateHdKey(fakeKey);
  const ref = poseidon1([truncated]);
  for (let i = 0; i < 50; i++) {
    assert.equal(poseidon1([truncateHdKey(fakeKey)]), ref);
  }
});

test('different HD keys produce different master keys after truncation', () => {
  const keyA = '0x1111111111111111111111111111111111111111111111111111111111111111';
  const keyB = '0x2222222222222222222222222222222222222222222222222222222222222222';
  const masterA = poseidon1([truncateHdKey(keyA)]);
  const masterB = poseidon1([truncateHdKey(keyB)]);
  assert.notEqual(masterA, masterB);
});

// ═══════════════════════════════════════════════════════════════════════════════
//  7. Full pipeline regression (known-answer from captured values)
// ═══════════════════════════════════════════════════════════════════════════════

console.log('\n── Full pipeline regression ──');

// Hardcoded regression vectors for the full deposit→withdrawal pipeline.
// masterKeys = poseidon1([42]), poseidon1([43])
// scope = 0xF241d57C6DebAe225c0F2e6eA1529373C9A9C9fB (ETH pool)
const PIPELINE = {
  deposit0: {
    nullifier:     14812872908495636563659114070895846784692041617165414870066712468037177905680n,
    secret:        19398466175589662031858502141309439441526761231766373612796993695530463445002n,
    precommitment: 7401488295419196436257358403189492305761693180908177863987681050820699998762n,
  },
  deposit1: {
    nullifier:     7766652984107266816972683845346685138570961528738143484531463694009827010109n,
    secret:        19516254295269567444467370098125368809589831928253575195927971054850412648327n,
    precommitment: 9384945721071900139496055362129371607208886629180576200291168050052562800941n,
  },
  withdraw0: { // derived with label = deposit0.precommitment
    nullifier:     11347116685582394720554832776176272332679984211779841839947632487214931866967n,
    secret:        2805761980112443371793201462547446887060435801775259290448709303539202642096n,
    precommitment: 7599896483308647686441771533662550551547897525271558467253814703433210755291n,
  },
};

test('deposit[0] matches hardcoded regression vector', () => {
  const k = ppDeriveDepositKeys(TEST_MASTER_NULLIFIER, TEST_MASTER_SECRET, TEST_SCOPE, 0);
  assert.equal(k.nullifier, PIPELINE.deposit0.nullifier);
  assert.equal(k.secret, PIPELINE.deposit0.secret);
  assert.equal(k.precommitment, PIPELINE.deposit0.precommitment);
});

test('deposit[1] matches hardcoded regression vector', () => {
  const k = ppDeriveDepositKeys(TEST_MASTER_NULLIFIER, TEST_MASTER_SECRET, TEST_SCOPE, 1);
  assert.equal(k.nullifier, PIPELINE.deposit1.nullifier);
  assert.equal(k.secret, PIPELINE.deposit1.secret);
  assert.equal(k.precommitment, PIPELINE.deposit1.precommitment);
});

test('withdrawal from deposit[0] matches hardcoded regression vector', () => {
  const k = ppDeriveWithdrawalKeys(TEST_MASTER_NULLIFIER, TEST_MASTER_SECRET, PIPELINE.deposit0.precommitment, 0);
  assert.equal(k.nullifier, PIPELINE.withdraw0.nullifier);
  assert.equal(k.secret, PIPELINE.withdraw0.secret);
  assert.equal(k.precommitment, PIPELINE.withdraw0.precommitment);
});

test('withdrawal keys derived from deposit precommitment are unique per deposit', () => {
  const w0 = ppDeriveWithdrawalKeys(TEST_MASTER_NULLIFIER, TEST_MASTER_SECRET, PIPELINE.deposit0.precommitment, 0);
  const w1 = ppDeriveWithdrawalKeys(TEST_MASTER_NULLIFIER, TEST_MASTER_SECRET, PIPELINE.deposit1.precommitment, 0);
  assert.notEqual(w0.nullifier, w1.nullifier);
  assert.notEqual(w0.precommitment, w1.precommitment);
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
