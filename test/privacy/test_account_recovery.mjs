#!/usr/bin/env node
//
// Privacy account recovery parity tests.
//
// Covers the SDK-v1.2.0-aligned account reconstruction paths that are easy to
// regress in the app because they are rebuilt manually in the browser:
//
//   - legacy -> safe migration detection
//   - zero-value migration slot counting
//   - ragequit handling for loaded pool accounts
//   - pending detection against inserted leaves
//   - mixed legacy/safe ordering in the Pool Accounts list
//
// Usage: node test/privacy/test_account_recovery.mjs
//
import { strict as assert } from 'node:assert';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const ROOT = path.resolve(__dirname, '../..');

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

function ppHashHex(value) {
  return '0x' + BigInt(value).toString(16).padStart(64, '0');
}

function ppCompareLoadedAccounts(a, b) {
  const assetOrder = { ETH: 0, BOLD: 1, wstETH: 2 };
  const assetDelta = (assetOrder[a.asset] ?? 99) - (assetOrder[b.asset] ?? 99);
  if (assetDelta !== 0) return assetDelta;

  const aDepositBlock = a.depositBlockNumber == null ? Number.MAX_SAFE_INTEGER : Number(a.depositBlockNumber);
  const bDepositBlock = b.depositBlockNumber == null ? Number.MAX_SAFE_INTEGER : Number(b.depositBlockNumber);
  if (aDepositBlock !== bDepositBlock) return aDepositBlock - bDepositBlock;

  const aDepositIdx = a.depositIndex == null ? Number.MAX_SAFE_INTEGER : Number(a.depositIndex);
  const bDepositIdx = b.depositIndex == null ? Number.MAX_SAFE_INTEGER : Number(b.depositIndex);
  if (aDepositIdx !== bDepositIdx) return aDepositIdx - bDepositIdx;

  const aBlock = a.blockNumber == null ? Number.MAX_SAFE_INTEGER : Number(a.blockNumber);
  const bBlock = b.blockNumber == null ? Number.MAX_SAFE_INTEGER : Number(b.blockNumber);
  if (aBlock !== bBlock) return aBlock - bBlock;

  return String(a.txHash || '').localeCompare(String(b.txHash || ''));
}

const PP_REVIEW_STATUS = {
  PENDING: 'pending',
  APPROVED: 'approved',
  DECLINED: 'declined',
  EXITED: 'exited',
  SPENT: 'spent',
  POI_REQUIRED: 'poi_required',
};

function ppNormalizeReviewStatus(status) {
  switch (String(status || '').toLowerCase()) {
    case PP_REVIEW_STATUS.APPROVED:
      return PP_REVIEW_STATUS.APPROVED;
    case PP_REVIEW_STATUS.DECLINED:
      return PP_REVIEW_STATUS.DECLINED;
    case PP_REVIEW_STATUS.EXITED:
      return PP_REVIEW_STATUS.EXITED;
    case PP_REVIEW_STATUS.SPENT:
      return PP_REVIEW_STATUS.SPENT;
    case PP_REVIEW_STATUS.POI_REQUIRED:
      return PP_REVIEW_STATUS.POI_REQUIRED;
    case PP_REVIEW_STATUS.PENDING:
    default:
      return PP_REVIEW_STATUS.PENDING;
  }
}

function ppLoadedAccountLabelKey(label) {
  return label == null ? null : BigInt(label).toString();
}

function ppApplyLoadedAccountReviewStatuses(rows, aspLeaves, depositsByLabel, { statusFetchFailed = false } = {}) {
  const aspLeafSet = new Set((Array.isArray(aspLeaves) ? aspLeaves : []).map((leaf) => BigInt(leaf).toString()));
  const depositMap = new Map();
  for (const deposit of Array.isArray(depositsByLabel) ? depositsByLabel : []) {
    if (deposit?.label == null) continue;
    depositMap.set(String(deposit.label), deposit);
  }

  const missingLabels = new Set();
  const nextRows = (Array.isArray(rows) ? rows : []).map((row) => {
    const labelKey = ppLoadedAccountLabelKey(row.label);
    const deposit = labelKey ? depositMap.get(labelKey) : null;
    const timestamp = deposit?.timestamp ?? null;

    if (row.ragequit) {
      return {
        ...row,
        pending: false,
        reviewStatus: PP_REVIEW_STATUS.EXITED,
        isValid: false,
        isWithdrawable: false,
        timestamp,
      };
    }

    if (row.source === 'spent') {
      return {
        ...row,
        pending: false,
        reviewStatus: PP_REVIEW_STATUS.SPENT,
        isValid: false,
        isWithdrawable: false,
        timestamp,
      };
    }

    let reviewStatus = PP_REVIEW_STATUS.PENDING;
    if (row.currentCommitmentInserted !== true) {
      reviewStatus = PP_REVIEW_STATUS.PENDING;
    } else if (statusFetchFailed) {
      reviewStatus = PP_REVIEW_STATUS.PENDING;
    } else if (!deposit) {
      if (labelKey) missingLabels.add(labelKey);
      reviewStatus = PP_REVIEW_STATUS.PENDING;
    } else {
      reviewStatus = ppNormalizeReviewStatus(deposit.reviewStatus);
      if (reviewStatus === PP_REVIEW_STATUS.APPROVED && (!labelKey || !aspLeafSet.has(labelKey))) {
        reviewStatus = PP_REVIEW_STATUS.PENDING;
      }
    }

    const amount = row.value != null ? BigInt(row.value) : 0n;
    const isValid = reviewStatus === PP_REVIEW_STATUS.APPROVED;
    return {
      ...row,
      pending: reviewStatus === PP_REVIEW_STATUS.PENDING,
      reviewStatus,
      isValid,
      isWithdrawable: isValid && amount > 0n,
      timestamp,
    };
  });

  return { rows: nextRows, missingLabels: Array.from(missingLabels) };
}

function ppGetRecoveredSafeDepositIndex(migratedCount, safeRows) {
  let nextIndex = Number.isFinite(Number(migratedCount)) ? Number(migratedCount) : 0;
  for (const row of Array.isArray(safeRows) ? safeRows : []) {
    const depositIndex = Number(row?.depositIndex);
    if (Number.isInteger(depositIndex) && depositIndex >= nextIndex) {
      nextIndex = depositIndex + 1;
    }
  }
  return nextIndex;
}

function ppGetLoadedAccountStatus(row) {
  if (row?.ragequit) return PP_REVIEW_STATUS.EXITED;
  if (row?.source === 'spent') return PP_REVIEW_STATUS.SPENT;
  if (row?.reviewStatus) return ppNormalizeReviewStatus(row.reviewStatus);
  return row?.pending ? PP_REVIEW_STATUS.PENDING : PP_REVIEW_STATUS.APPROVED;
}

const PP_PENDING_DEPOSIT_RESERVATION_TTL_MS = 7 * 24 * 60 * 60 * 1000;
const PP_ACCOUNT_SCAN_MAX_CONSECUTIVE_MISSES = 25;

function ppNormalizePendingDepositReservations(entries, minDepositIndex = 0, now = Date.now()) {
  const seen = new Set();
  return (Array.isArray(entries) ? entries : [])
    .map(entry => ({
      depositIndex: Number(entry?.depositIndex),
      txHash: entry?.txHash ? String(entry.txHash) : null,
      createdAt: Number(entry?.createdAt),
      status: entry?.status === 'confirmed' ? 'confirmed' : 'pending',
    }))
    .filter(entry => Number.isInteger(entry.depositIndex) && entry.depositIndex >= minDepositIndex)
    .filter(entry => Number.isFinite(entry.createdAt) && (now - entry.createdAt) < PP_PENDING_DEPOSIT_RESERVATION_TTL_MS)
    .sort((a, b) => a.depositIndex - b.depositIndex || b.createdAt - a.createdAt)
    .filter(entry => {
      const key = String(entry.depositIndex);
      if (seen.has(key)) return false;
      seen.add(key);
      return true;
    });
}

function ppResolveReservedSafeDepositIndex(recoveredIndex, reservations) {
  const byIndex = new Map((Array.isArray(reservations) ? reservations : []).map(entry => [Number(entry.depositIndex), entry]));
  let nextIndex = recoveredIndex;
  while (true) {
    const reservation = byIndex.get(nextIndex);
    if (!reservation) return { nextIndex, pendingIndex: null };
    nextIndex++;
  }
}

function ppTraceLoadedAccountChain(initial, withdrawnMap, legacyKeys, safeKeys) {
  const depositTxHash = initial.depositTxHash;
  const depositBlockNumber = initial.depositBlockNumber;
  const initialValue = initial.value;
  let current = initial;
  let migrated = false;

  while (current && current.source !== 'spent') {
    const nullHashHex = ppHashHex(poseidon1([current.nullifier]));
    const w = withdrawnMap.get(nullHashHex);
    if (!w) break;

    const changeValue = BigInt(current.value) - BigInt(w.value);
    if (changeValue <= 0n) {
      if (changeValue === 0n && current.derivation === 'legacy') {
        const migratedKeys = ppDeriveWithdrawalKeys(
          safeKeys.masterNullifier,
          safeKeys.masterSecret,
          BigInt(current.label),
          0,
        );
        const expectedMigratedCommitment = poseidon3([changeValue, BigInt(current.label), migratedKeys.precommitment]);
        if (w.newCommitment && expectedMigratedCommitment === BigInt(w.newCommitment)) {
          migrated = true;
        }
      }
      current = {
        value: '0',
        source: 'spent',
        depositTxHash,
        depositBlockNumber,
        originalValue: initialValue,
        derivation: current.derivation,
      };
      break;
    }

    const nextIndex = current.withdrawalIndex == null ? 0 : Number(current.withdrawalIndex) + 1;
    const keyset = current.derivation === 'legacy' ? legacyKeys : safeKeys;
    const changeKeys = ppDeriveWithdrawalKeys(
      keyset.masterNullifier,
      keyset.masterSecret,
      BigInt(current.label),
      nextIndex,
    );
    const expectedCommitment = poseidon3([changeValue, BigInt(current.label), changeKeys.precommitment]);
    if (w.newCommitment && expectedCommitment === BigInt(w.newCommitment)) {
      current = {
        nullifier: changeKeys.nullifier,
        secret: changeKeys.secret,
        precommitment: changeKeys.precommitment,
        value: changeValue.toString(),
        label: current.label,
        commitment: ppHashHex(expectedCommitment),
        txHash: w.txHash,
        blockNumber: w.blockNumber,
        depositTxHash,
        depositBlockNumber,
        withdrawalIndex: nextIndex,
        source: 'change',
        derivation: current.derivation,
      };
      continue;
    }

    if (current.derivation === 'legacy') {
      const migratedIndex = 0;
      const migratedKeys = ppDeriveWithdrawalKeys(
        safeKeys.masterNullifier,
        safeKeys.masterSecret,
        BigInt(current.label),
        migratedIndex,
      );
      const expectedMigratedCommitment = poseidon3([changeValue, BigInt(current.label), migratedKeys.precommitment]);
      if (w.newCommitment && expectedMigratedCommitment === BigInt(w.newCommitment)) {
        migrated = true;
        current = {
          nullifier: migratedKeys.nullifier,
          secret: migratedKeys.secret,
          precommitment: migratedKeys.precommitment,
          value: changeValue.toString(),
          label: current.label,
          commitment: ppHashHex(expectedMigratedCommitment),
          txHash: w.txHash,
          blockNumber: w.blockNumber,
          depositTxHash,
          depositBlockNumber,
          withdrawalIndex: migratedIndex,
          source: 'change',
          derivation: 'safe',
          migratedFrom: 'legacy',
        };
        continue;
      }
    }

    current = null;
  }

  return { current, migrated };
}

function ppCollectWalletAccountsForDerivation({
  asset,
  scope,
  poolAddress,
  depositEvents,
  withdrawnMap,
  ragequitMap,
  insertedLeaves,
  derivation,
  keyset,
  legacyKeys,
  safeKeys,
  startIndex = 0,
}) {
  const results = [];
  let migratedCount = 0;
  let consecutiveMisses = 0;

  for (let index = startIndex; consecutiveMisses < PP_ACCOUNT_SCAN_MAX_CONSECUTIVE_MISSES; index++) {
    const dk = ppDeriveDepositKeys(keyset.masterNullifier, keyset.masterSecret, scope, index);
    const pch = ppHashHex(dk.precommitment);
    const ev = depositEvents.get(pch);

    if (!ev) {
      consecutiveMisses++;
      continue;
    }
    consecutiveMisses = 0;

    const initial = {
      nullifier: dk.nullifier,
      secret: dk.secret,
      precommitment: dk.precommitment,
      value: ev.value,
      label: ev.label,
      commitment: ev.commitment,
      txHash: ev.txHash,
      blockNumber: ev.blockNumber,
      depositTxHash: ev.txHash,
      depositBlockNumber: ev.blockNumber,
      withdrawalIndex: null,
      source: 'deposit',
      derivation,
    };

    const traced = ppTraceLoadedAccountChain(initial, withdrawnMap, legacyKeys, safeKeys);
    if (traced.migrated) migratedCount++;
    if (!traced.current) continue;

    const current = traced.current;
    const ragequitLabel = current.label != null ? current.label : initial.label;
    const ragequit = ragequitMap?.get(ppHashHex(ragequitLabel));
    if (ragequit) {
      const originalValue = current.source === 'spent'
        ? (current.originalValue ?? initial.value)
        : current.value;
      results.push({
        asset,
        depositIndex: index,
        poolAddress,
        pending: false,
        value: '0',
        label: ragequitLabel,
        txHash: ragequit.txHash,
        blockNumber: ragequit.blockNumber,
        depositTxHash: initial.depositTxHash,
        depositBlockNumber: initial.depositBlockNumber,
        originalValue: String(originalValue),
        source: 'spent',
        derivation: current.derivation,
        ragequit: true,
      });
      continue;
    }

    const currentCommitment = current.commitment == null
      ? null
      : (typeof current.commitment === 'string' ? current.commitment : ppHashHex(current.commitment));
    const currentCommitmentInserted = !!currentCommitment && insertedLeaves.has(currentCommitment);
    const pending = current.source !== 'spent' && currentCommitment && !currentCommitmentInserted;
    results.push({
      asset,
      depositIndex: index,
      poolAddress,
      currentCommitment,
      currentCommitmentInserted,
      pending,
      ...current,
    });
  }

  return { results, migratedCount };
}

function ppAggregatePoolAccountTotals(rows) {
  const totals = {};
  const pendingTotals = {};
  for (const row of rows) {
    const status = ppGetLoadedAccountStatus(row);
    if (row.value && row.source !== 'spent') {
      const amount = BigInt(row.value);
      if (status === PP_REVIEW_STATUS.PENDING) pendingTotals[row.asset] = (pendingTotals[row.asset] || 0n) + amount;
      else if (status === PP_REVIEW_STATUS.APPROVED) totals[row.asset] = (totals[row.asset] || 0n) + amount;
    }
  }
  return { totals, pendingTotals };
}

function ppRowShowsWithdrawButton(row) {
  return row?.isWithdrawable === true || (
    row?.source !== 'spent' &&
    ppGetLoadedAccountStatus(row) === PP_REVIEW_STATUS.APPROVED &&
    BigInt(row?.value || 0) > 0n
  );
}

function makeDepositEvent(keys, scope, index, label, value, blockNumber, txHash) {
  const dk = ppDeriveDepositKeys(keys.masterNullifier, keys.masterSecret, scope, index);
  return {
    dk,
    event: {
      commitment: ppHashHex(poseidon3([value, label, dk.precommitment])),
      label,
      value,
      txHash,
      blockNumber,
    },
  };
}

function makeWithdrawalEvent(currentNullifier, withdrawn, newCommitment, blockNumber, txHash) {
  return {
    key: ppHashHex(poseidon1([currentNullifier])),
    event: {
      value: withdrawn,
      newCommitment,
      txHash,
      blockNumber,
    },
  };
}

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

const SCOPE = 0xF241d57C6DebAe225c0F2e6eA1529373C9A9C9fBn;
const SAFE_KEYS = {
  masterNullifier: poseidon1([111n]),
  masterSecret: poseidon1([222n]),
};
const LEGACY_KEYS = {
  masterNullifier: poseidon1([333n]),
  masterSecret: poseidon1([444n]),
};

console.log('\n── Account recovery parity ──');

test('legacy partial migration is recovered as a safe change note at index 0', () => {
  const label = poseidon2([1n, 2n]);
  const { dk, event } = makeDepositEvent(LEGACY_KEYS, SCOPE, 0, label, 10n, 100n, '0xdep1');
  const migratedKeys = ppDeriveWithdrawalKeys(SAFE_KEYS.masterNullifier, SAFE_KEYS.masterSecret, label, 0);
  const remainingValue = 7n;
  const { key, event: withdrawalEvent } = makeWithdrawalEvent(
    dk.nullifier,
    3n,
    ppHashHex(poseidon3([remainingValue, label, migratedKeys.precommitment])),
    101n,
    '0xwd1',
  );

  const { results, migratedCount } = ppCollectWalletAccountsForDerivation({
    asset: 'ETH',
    scope: SCOPE,
    poolAddress: '0xpool',
    depositEvents: new Map([[ppHashHex(dk.precommitment), event]]),
    withdrawnMap: new Map([[key, withdrawalEvent]]),
    ragequitMap: new Map(),
    insertedLeaves: new Set(),
    derivation: 'legacy',
    keyset: LEGACY_KEYS,
    legacyKeys: LEGACY_KEYS,
    safeKeys: SAFE_KEYS,
  });

  assert.equal(migratedCount, 1);
  assert.equal(results.length, 1);
  assert.equal(results[0].source, 'change');
  assert.equal(results[0].derivation, 'safe');
  assert.equal(results[0].withdrawalIndex, 0);
  assert.equal(results[0].value, '7');
});

test('zero-value legacy migration still counts as a migrated slot', () => {
  const label = poseidon2([3n, 4n]);
  const { dk, event } = makeDepositEvent(LEGACY_KEYS, SCOPE, 0, label, 5n, 110n, '0xdep2');
  const migratedKeys = ppDeriveWithdrawalKeys(SAFE_KEYS.masterNullifier, SAFE_KEYS.masterSecret, label, 0);
  const { key, event: withdrawalEvent } = makeWithdrawalEvent(
    dk.nullifier,
    5n,
    ppHashHex(poseidon3([0n, label, migratedKeys.precommitment])),
    111n,
    '0xwd2',
  );

  const { results, migratedCount } = ppCollectWalletAccountsForDerivation({
    asset: 'ETH',
    scope: SCOPE,
    poolAddress: '0xpool',
    depositEvents: new Map([[ppHashHex(dk.precommitment), event]]),
    withdrawnMap: new Map([[key, withdrawalEvent]]),
    ragequitMap: new Map(),
    insertedLeaves: new Set(),
    derivation: 'legacy',
    keyset: LEGACY_KEYS,
    legacyKeys: LEGACY_KEYS,
    safeKeys: SAFE_KEYS,
  });

  assert.equal(migratedCount, 1);
  assert.equal(results.length, 1);
  assert.equal(results[0].source, 'spent');
  assert.equal(results[0].originalValue, 5n);
});

test('ragequit marks a loaded account as spent and non-withdrawable', () => {
  const label = poseidon2([5n, 6n]);
  const { dk, event } = makeDepositEvent(SAFE_KEYS, SCOPE, 1, label, 9n, 120n, '0xdep3');
  const ragequitMap = new Map([[
    ppHashHex(label),
    { value: 9n, txHash: '0xrq1', blockNumber: 121n },
  ]]);

  const { results } = ppCollectWalletAccountsForDerivation({
    asset: 'ETH',
    scope: SCOPE,
    poolAddress: '0xpool',
    depositEvents: new Map([[ppHashHex(dk.precommitment), event]]),
    withdrawnMap: new Map(),
    ragequitMap,
    insertedLeaves: new Set([event.commitment]),
    derivation: 'safe',
    keyset: SAFE_KEYS,
    legacyKeys: LEGACY_KEYS,
    safeKeys: SAFE_KEYS,
    startIndex: 1,
  });

  const applied = ppApplyLoadedAccountReviewStatuses(results, [], []);
  assert.equal(applied.rows.length, 1);
  assert.equal(applied.rows[0].source, 'spent');
  assert.equal(applied.rows[0].ragequit, true);
  assert.equal(applied.rows[0].originalValue, '9');
  assert.equal(applied.rows[0].reviewStatus, PP_REVIEW_STATUS.EXITED);
  assert.equal(applied.rows[0].isWithdrawable, false);
});

test('approved account requires ASP leaf before becoming withdrawable', () => {
  const label = poseidon2([13n, 14n]);
  const { dk, event } = makeDepositEvent(SAFE_KEYS, SCOPE, 3, label, 8n, 125n, '0xdep-approved');
  const { results } = ppCollectWalletAccountsForDerivation({
    asset: 'ETH',
    scope: SCOPE,
    poolAddress: '0xpool',
    depositEvents: new Map([[ppHashHex(dk.precommitment), event]]),
    withdrawnMap: new Map(),
    ragequitMap: new Map(),
    insertedLeaves: new Set([event.commitment]),
    derivation: 'safe',
    keyset: SAFE_KEYS,
    legacyKeys: LEGACY_KEYS,
    safeKeys: SAFE_KEYS,
    startIndex: 3,
  });

  const pendingRows = ppApplyLoadedAccountReviewStatuses(results, [], [
    { label: label.toString(), reviewStatus: PP_REVIEW_STATUS.APPROVED, timestamp: 111 },
  ]).rows;
  assert.equal(pendingRows[0].reviewStatus, PP_REVIEW_STATUS.PENDING);
  assert.equal(pendingRows[0].isWithdrawable, false);

  const approvedRows = ppApplyLoadedAccountReviewStatuses(results, [label], [
    { label: label.toString(), reviewStatus: PP_REVIEW_STATUS.APPROVED, timestamp: 111 },
  ]).rows;
  assert.equal(approvedRows[0].reviewStatus, PP_REVIEW_STATUS.APPROVED);
  assert.equal(approvedRows[0].isValid, true);
  assert.equal(approvedRows[0].isWithdrawable, true);
  assert.equal(approvedRows[0].timestamp, 111);
});

test('missing ASP deposit metadata is surfaced for inserted accounts', () => {
  const label = poseidon2([46n, 47n]);
  const { dk, event } = makeDepositEvent(SAFE_KEYS, SCOPE, 11, label, 3n, 128n, '0xdep-missing');
  const { results } = ppCollectWalletAccountsForDerivation({
    asset: 'ETH',
    scope: SCOPE,
    poolAddress: '0xpool',
    depositEvents: new Map([[ppHashHex(dk.precommitment), event]]),
    withdrawnMap: new Map(),
    ragequitMap: new Map(),
    insertedLeaves: new Set([event.commitment]),
    derivation: 'safe',
    keyset: SAFE_KEYS,
    legacyKeys: LEGACY_KEYS,
    safeKeys: SAFE_KEYS,
    startIndex: 11,
  });

  const applied = ppApplyLoadedAccountReviewStatuses(results, [label], []);
  assert.deepEqual(applied.missingLabels, [label.toString()]);
  assert.equal(applied.rows[0].reviewStatus, PP_REVIEW_STATUS.PENDING);
});

test('declined and poi-required accounts stay non-withdrawable', () => {
  const declinedLabel = poseidon2([15n, 16n]);
  const poiLabel = poseidon2([17n, 18n]);
  const { dk: declinedDk, event: declinedEvent } = makeDepositEvent(SAFE_KEYS, SCOPE, 8, declinedLabel, 6n, 126n, '0xdep-declined');
  const { dk: poiDk, event: poiEvent } = makeDepositEvent(SAFE_KEYS, SCOPE, 9, poiLabel, 7n, 127n, '0xdep-poi');
  const depositEvents = new Map([
    [ppHashHex(declinedDk.precommitment), declinedEvent],
    [ppHashHex(poiDk.precommitment), poiEvent],
  ]);

  const { results } = ppCollectWalletAccountsForDerivation({
    asset: 'ETH',
    scope: SCOPE,
    poolAddress: '0xpool',
    depositEvents,
    withdrawnMap: new Map(),
    ragequitMap: new Map(),
    insertedLeaves: new Set([declinedEvent.commitment, poiEvent.commitment]),
    derivation: 'safe',
    keyset: SAFE_KEYS,
    legacyKeys: LEGACY_KEYS,
    safeKeys: SAFE_KEYS,
    startIndex: 8,
  });

  const applied = ppApplyLoadedAccountReviewStatuses(results, [declinedLabel, poiLabel], [
    { label: declinedLabel.toString(), reviewStatus: PP_REVIEW_STATUS.DECLINED, timestamp: 222 },
    { label: poiLabel.toString(), reviewStatus: PP_REVIEW_STATUS.POI_REQUIRED, timestamp: 333 },
  ]).rows;

  assert.equal(applied[0].reviewStatus, PP_REVIEW_STATUS.DECLINED);
  assert.equal(applied[0].isWithdrawable, false);
  assert.equal(applied[1].reviewStatus, PP_REVIEW_STATUS.POI_REQUIRED);
  assert.equal(applied[1].isWithdrawable, false);
  const totals = ppAggregatePoolAccountTotals(applied);
  assert.equal(totals.totals.ETH || 0n, 0n);
  assert.equal(totals.pendingTotals.ETH || 0n, 0n);
});

test('pending detection compares normalized commitment hex values', () => {
  const label = poseidon2([7n, 8n]);
  const { dk, event } = makeDepositEvent(SAFE_KEYS, SCOPE, 2, label, 4n, 130n, '0xdep4');

  const available = ppCollectWalletAccountsForDerivation({
    asset: 'ETH',
    scope: SCOPE,
    poolAddress: '0xpool',
    depositEvents: new Map([[ppHashHex(dk.precommitment), event]]),
    withdrawnMap: new Map(),
    ragequitMap: new Map(),
    insertedLeaves: new Set([event.commitment]),
    derivation: 'safe',
    keyset: SAFE_KEYS,
    legacyKeys: LEGACY_KEYS,
    safeKeys: SAFE_KEYS,
    startIndex: 2,
  });
  const pending = ppCollectWalletAccountsForDerivation({
    asset: 'ETH',
    scope: SCOPE,
    poolAddress: '0xpool',
    depositEvents: new Map([[ppHashHex(dk.precommitment), event]]),
    withdrawnMap: new Map(),
    ragequitMap: new Map(),
    insertedLeaves: new Set(),
    derivation: 'safe',
    keyset: SAFE_KEYS,
    legacyKeys: LEGACY_KEYS,
    safeKeys: SAFE_KEYS,
    startIndex: 2,
  });

  assert.equal(available.results[0].pending, false);
  assert.equal(pending.results[0].pending, true);
});

test('loaded deposit accounts retain depositIndex for partial withdrawals', () => {
  const label = poseidon2([20n, 21n]);
  const { dk, event } = makeDepositEvent(SAFE_KEYS, SCOPE, 7, label, 9n, 131n, '0xdep7');

  const { results } = ppCollectWalletAccountsForDerivation({
    asset: 'ETH',
    scope: SCOPE,
    poolAddress: '0xpool',
    depositEvents: new Map([[ppHashHex(dk.precommitment), event]]),
    withdrawnMap: new Map(),
    ragequitMap: new Map(),
    insertedLeaves: new Set([event.commitment]),
    derivation: 'safe',
    keyset: SAFE_KEYS,
    legacyKeys: LEGACY_KEYS,
    safeKeys: SAFE_KEYS,
    startIndex: 7,
  });

  assert.equal(results.length, 1);
  assert.equal(results[0].source, 'deposit');
  assert.equal(results[0].depositIndex, 7);
  assert.equal(results[0].withdrawalIndex, null);
});

test('loaded change accounts retain depositIndex and withdrawalIndex', () => {
  const label = poseidon2([30n, 31n]);
  const { dk, event } = makeDepositEvent(SAFE_KEYS, SCOPE, 4, label, 11n, 132n, '0xdep8');
  const changeKeys = ppDeriveWithdrawalKeys(SAFE_KEYS.masterNullifier, SAFE_KEYS.masterSecret, label, 0);
  const remainingValue = 6n;
  const changeCommitment = ppHashHex(poseidon3([remainingValue, label, changeKeys.precommitment]));
  const { key, event: withdrawalEvent } = makeWithdrawalEvent(dk.nullifier, 5n, changeCommitment, 133n, '0xwd8');

  const { results } = ppCollectWalletAccountsForDerivation({
    asset: 'ETH',
    scope: SCOPE,
    poolAddress: '0xpool',
    depositEvents: new Map([[ppHashHex(dk.precommitment), event]]),
    withdrawnMap: new Map([[key, withdrawalEvent]]),
    ragequitMap: new Map(),
    insertedLeaves: new Set([changeCommitment]),
    derivation: 'safe',
    keyset: SAFE_KEYS,
    legacyKeys: LEGACY_KEYS,
    safeKeys: SAFE_KEYS,
    startIndex: 4,
  });

  assert.equal(results.length, 1);
  assert.equal(results[0].source, 'change');
  assert.equal(results[0].depositIndex, 4);
  assert.equal(results[0].withdrawalIndex, 0);
});

test('partial-withdrawal change notes stay pending until the new leaf is inserted', () => {
  const label = poseidon2([40n, 41n]);
  const { dk, event } = makeDepositEvent(SAFE_KEYS, SCOPE, 5, label, 10n, 150n, '0xdep9');
  const changeKeys = ppDeriveWithdrawalKeys(SAFE_KEYS.masterNullifier, SAFE_KEYS.masterSecret, label, 0);
  const remainingValue = 5n;
  const changeCommitment = ppHashHex(poseidon3([remainingValue, label, changeKeys.precommitment]));
  const { key, event: withdrawalEvent } = makeWithdrawalEvent(dk.nullifier, 5n, changeCommitment, 151n, '0xwd9');

  const pendingScan = ppCollectWalletAccountsForDerivation({
    asset: 'ETH',
    scope: SCOPE,
    poolAddress: '0xpool',
    depositEvents: new Map([[ppHashHex(dk.precommitment), event]]),
    withdrawnMap: new Map([[key, withdrawalEvent]]),
    ragequitMap: new Map(),
    insertedLeaves: new Set(),
    derivation: 'safe',
    keyset: SAFE_KEYS,
    legacyKeys: LEGACY_KEYS,
    safeKeys: SAFE_KEYS,
    startIndex: 5,
  });

  const pendingRows = ppApplyLoadedAccountReviewStatuses(pendingScan.results, [label], [
    { label: label.toString(), reviewStatus: PP_REVIEW_STATUS.APPROVED, timestamp: 444 },
  ]).rows;

  assert.equal(pendingRows.length, 1);
  assert.equal(pendingRows[0].source, 'change');
  assert.equal(pendingRows[0].pending, true);
  assert.equal(pendingRows[0].reviewStatus, PP_REVIEW_STATUS.PENDING);
  assert.equal(ppRowShowsWithdrawButton(pendingRows[0]), false);

  const totals = ppAggregatePoolAccountTotals(pendingRows);
  assert.equal(totals.totals.ETH || 0n, 0n);
  assert.equal(totals.pendingTotals.ETH, 5n);
});

test('inserted partial-withdrawal change notes become available again', () => {
  const label = poseidon2([42n, 43n]);
  const { dk, event } = makeDepositEvent(SAFE_KEYS, SCOPE, 6, label, 10n, 152n, '0xdep10');
  const changeKeys = ppDeriveWithdrawalKeys(SAFE_KEYS.masterNullifier, SAFE_KEYS.masterSecret, label, 0);
  const remainingValue = 5n;
  const changeCommitment = ppHashHex(poseidon3([remainingValue, label, changeKeys.precommitment]));
  const { key, event: withdrawalEvent } = makeWithdrawalEvent(dk.nullifier, 5n, changeCommitment, 153n, '0xwd10');

  const availableScan = ppCollectWalletAccountsForDerivation({
    asset: 'ETH',
    scope: SCOPE,
    poolAddress: '0xpool',
    depositEvents: new Map([[ppHashHex(dk.precommitment), event]]),
    withdrawnMap: new Map([[key, withdrawalEvent]]),
    ragequitMap: new Map(),
    insertedLeaves: new Set([changeCommitment]),
    derivation: 'safe',
    keyset: SAFE_KEYS,
    legacyKeys: LEGACY_KEYS,
    safeKeys: SAFE_KEYS,
    startIndex: 6,
  });

  const availableRows = ppApplyLoadedAccountReviewStatuses(availableScan.results, [label], [
    { label: label.toString(), reviewStatus: PP_REVIEW_STATUS.APPROVED, timestamp: 555 },
  ]).rows;

  assert.equal(availableRows.length, 1);
  assert.equal(availableRows[0].source, 'change');
  assert.equal(availableRows[0].pending, false);
  assert.equal(availableRows[0].reviewStatus, PP_REVIEW_STATUS.APPROVED);
  assert.equal(ppRowShowsWithdrawButton(availableRows[0]), true);

  const totals = ppAggregatePoolAccountTotals(availableRows);
  assert.equal(totals.totals.ETH, 5n);
  assert.equal(totals.pendingTotals.ETH || 0n, 0n);
});

test('failed ASP status fetch keeps inserted accounts fail-closed as pending', () => {
  const label = poseidon2([44n, 45n]);
  const { dk, event } = makeDepositEvent(SAFE_KEYS, SCOPE, 10, label, 12n, 154n, '0xdep11');
  const { results } = ppCollectWalletAccountsForDerivation({
    asset: 'ETH',
    scope: SCOPE,
    poolAddress: '0xpool',
    depositEvents: new Map([[ppHashHex(dk.precommitment), event]]),
    withdrawnMap: new Map(),
    ragequitMap: new Map(),
    insertedLeaves: new Set([event.commitment]),
    derivation: 'safe',
    keyset: SAFE_KEYS,
    legacyKeys: LEGACY_KEYS,
    safeKeys: SAFE_KEYS,
    startIndex: 10,
  });

  const applied = ppApplyLoadedAccountReviewStatuses(results, [label], [], { statusFetchFailed: true }).rows;
  assert.equal(applied[0].reviewStatus, PP_REVIEW_STATUS.PENDING);
  assert.equal(applied[0].isWithdrawable, false);
  assert.equal(ppRowShowsWithdrawButton(applied[0]), false);
});

test('account recovery tolerates sparse gaps before later deposits', () => {
  const label = poseidon2([48n, 49n]);
  const { dk, event } = makeDepositEvent(SAFE_KEYS, SCOPE, 24, label, 4n, 155n, '0xdep-gap');
  const { results } = ppCollectWalletAccountsForDerivation({
    asset: 'ETH',
    scope: SCOPE,
    poolAddress: '0xpool',
    depositEvents: new Map([[ppHashHex(dk.precommitment), event]]),
    withdrawnMap: new Map(),
    ragequitMap: new Map(),
    insertedLeaves: new Set([event.commitment]),
    derivation: 'safe',
    keyset: SAFE_KEYS,
    legacyKeys: LEGACY_KEYS,
    safeKeys: SAFE_KEYS,
  });

  assert.equal(results.length, 1);
  assert.equal(results[0].depositIndex, 24);
});

test('next safe deposit index still counts ragequitted safe slots after legacy migration', () => {
  const legacyLabel = poseidon2([9n, 10n]);
  const safeLabel = poseidon2([11n, 12n]);

  const { dk: legacyDk, event: legacyEvent } = makeDepositEvent(LEGACY_KEYS, SCOPE, 0, legacyLabel, 6n, 140n, '0xdep5');
  const migratedKeys = ppDeriveWithdrawalKeys(SAFE_KEYS.masterNullifier, SAFE_KEYS.masterSecret, legacyLabel, 0);
  const { key: legacyWithdrawalKey, event: legacyWithdrawalEvent } = makeWithdrawalEvent(
    legacyDk.nullifier,
    6n,
    ppHashHex(poseidon3([0n, legacyLabel, migratedKeys.precommitment])),
    141n,
    '0xwd5',
  );

  const { dk: safeDk, event: safeEvent } = makeDepositEvent(SAFE_KEYS, SCOPE, 1, safeLabel, 8n, 142n, '0xdep6');
  const ragequitMap = new Map([[
    ppHashHex(safeLabel),
    { value: 8n, txHash: '0xrq2', blockNumber: 143n },
  ]]);

  const legacyScan = ppCollectWalletAccountsForDerivation({
    asset: 'ETH',
    scope: SCOPE,
    poolAddress: '0xpool',
    depositEvents: new Map([[ppHashHex(legacyDk.precommitment), legacyEvent]]),
    withdrawnMap: new Map([[legacyWithdrawalKey, legacyWithdrawalEvent]]),
    ragequitMap: new Map(),
    insertedLeaves: new Set(),
    derivation: 'legacy',
    keyset: LEGACY_KEYS,
    legacyKeys: LEGACY_KEYS,
    safeKeys: SAFE_KEYS,
  });

  const safeScan = ppCollectWalletAccountsForDerivation({
    asset: 'ETH',
    scope: SCOPE,
    poolAddress: '0xpool',
    depositEvents: new Map([[ppHashHex(safeDk.precommitment), safeEvent]]),
    withdrawnMap: new Map(),
    ragequitMap,
    insertedLeaves: new Set([safeEvent.commitment]),
    derivation: 'safe',
    keyset: SAFE_KEYS,
    legacyKeys: LEGACY_KEYS,
    safeKeys: SAFE_KEYS,
    startIndex: legacyScan.migratedCount,
  });

  assert.equal(legacyScan.migratedCount, 1);
  assert.equal(safeScan.results.length, 1);
  assert.equal(ppGetRecoveredSafeDepositIndex(legacyScan.migratedCount, safeScan.results), 2);
});

test('next safe deposit index uses the highest recovered safe slot', () => {
  const nextIndex = ppGetRecoveredSafeDepositIndex(2, [
    { depositIndex: 2 },
    { depositIndex: 5 },
  ]);
  assert.equal(nextIndex, 6);
});

test('mixed legacy and safe accounts stay ordered by deposit chronology, not derivation', () => {
  const rows = [
    {
      asset: 'ETH',
      derivation: 'safe',
      depositIndex: 1,
      depositBlockNumber: 201n,
      blockNumber: 201n,
      txHash: '0xbbb',
    },
    {
      asset: 'ETH',
      derivation: 'legacy',
      depositIndex: 0,
      depositBlockNumber: 200n,
      blockNumber: 200n,
      txHash: '0xaaa',
    },
  ];

  rows.sort(ppCompareLoadedAccounts);
  assert.equal(rows[0].derivation, 'legacy');
  assert.equal(rows[1].derivation, 'safe');
});

test('confirmed pending-deposit reservations advance the next safe slot', () => {
  const resolved = ppResolveReservedSafeDepositIndex(2, [
    { depositIndex: 2, status: 'confirmed', createdAt: 10 },
    { depositIndex: 3, status: 'confirmed', createdAt: 20 },
  ]);

  assert.equal(resolved.nextIndex, 4);
  assert.equal(resolved.pendingIndex, null);
});

test('unconfirmed pending-deposit reservations still advance the next safe slot', () => {
  const resolved = ppResolveReservedSafeDepositIndex(2, [
    { depositIndex: 2, status: 'pending', createdAt: 10 },
    { depositIndex: 3, status: 'confirmed', createdAt: 20 },
  ]);

  assert.equal(resolved.nextIndex, 4);
  assert.equal(resolved.pendingIndex, null);
});

test('pending-deposit reservation normalization prunes stale and superseded entries', () => {
  const now = 50_000;
  const normalized = ppNormalizePendingDepositReservations([
    { depositIndex: 0, status: 'pending', createdAt: now - 1000 },
    { depositIndex: 2, status: 'pending', createdAt: now - 5000 },
    { depositIndex: 2, status: 'confirmed', createdAt: now - 100 },
    { depositIndex: 4, status: 'pending', createdAt: now - PP_PENDING_DEPOSIT_RESERVATION_TTL_MS - 1 },
    { depositIndex: 'bad', status: 'pending', createdAt: now - 100 },
  ], 1, now);

  assert.deepEqual(
    normalized.map(entry => ({ depositIndex: entry.depositIndex, status: entry.status })),
    [
      { depositIndex: 2, status: 'confirmed' },
    ],
  );
});

// ═══════════════════════════════════════════════════════════════════════════════
//  Event cache concurrency: leafLogs not overwritten by non-leaf call
// ═══════════════════════════════════════════════════════════════════════════════

console.log('\n── Event cache leaf preservation ──');

test('non-leaf fetch preserves existing leafLogs in cache', () => {
  // Simulates the cache merge logic from ppFetchPoolEventLogs after the await.
  // A call with includeLeaves=false must NOT overwrite leafLogs written by a prior includeLeaves=true call.
  const cache = {};

  // First call: includeLeaves=true populates leafLogs
  const leafLogs1 = [{ topics: ['0xleaf1'], data: '0x01' }, { topics: ['0xleaf2'], data: '0x02' }];
  cache['ETH'] = {
    depositLogs: [{ topics: ['0xdep'], data: '0x' }],
    withdrawnLogs: [],
    ragequitLogs: [],
    leafLogs: leafLogs1,
    upToBlock: 100,
    leafUpToBlock: 100,
  };

  // Second call: includeLeaves=false. Re-reads live cache and must preserve leafLogs.
  const live = cache['ETH'];
  const includeLeaves = false;
  const newDLogs = [{ topics: ['0xdep2'], data: '0x' }];
  const depositLogs = (live ? live.depositLogs : []).concat(newDLogs);
  // This is the critical line: leafLogs must come from live cache, not be reset to []
  const leafLogs = includeLeaves
    ? (live?.leafLogs || []).concat([])
    : (live?.leafLogs || []);
  cache['ETH'] = { ...cache['ETH'], depositLogs, leafLogs, upToBlock: 200 };

  assert.equal(cache['ETH'].leafLogs.length, 2, 'leafLogs must not be wiped by non-leaf call');
  assert.deepEqual(cache['ETH'].leafLogs, leafLogs1);
  assert.equal(cache['ETH'].depositLogs.length, 2, 'deposit logs should be merged');
});

test('concurrent non-leaf call does not overwrite leaf data from parallel leaf call', () => {
  // Simulates the race: two calls snapshot the cache, do async work, then write back.
  // Call A: includeLeaves=true, Call B: includeLeaves=false (from ppResolveNextSafeDepositIndex)
  // With the fix: Call B re-reads the live cache after await, preserving A's leafLogs.
  const cache = {};

  // Both calls start with empty cache
  const snapshotA = cache['ETH']; // undefined
  const snapshotB = cache['ETH']; // undefined

  // Call A finishes first (includeLeaves=true), writes leaf data
  const leafData = [{ topics: ['0xleaf'], data: '0xAA' }];
  cache['ETH'] = {
    depositLogs: [{ topics: ['0xd1'], data: '0x' }],
    withdrawnLogs: [],
    ragequitLogs: [],
    leafLogs: leafData,
    upToBlock: 100,
    leafUpToBlock: 100,
  };

  // Call B finishes second (includeLeaves=false). With fix, re-reads live cache.
  const live = cache['ETH']; // now has leaf data from A
  const includeLeaves = false;
  const mergedLeafLogs = includeLeaves
    ? (live?.leafLogs || snapshotB?.leafLogs || []).concat([])
    : (live?.leafLogs || snapshotB?.leafLogs || []);
  cache['ETH'] = {
    depositLogs: (live || snapshotB || { depositLogs: [] }).depositLogs.concat([]),
    withdrawnLogs: [],
    ragequitLogs: [],
    leafLogs: mergedLeafLogs,
    upToBlock: live?.upToBlock ?? 100,
    leafUpToBlock: live?.leafUpToBlock ?? null,
  };

  assert.equal(cache['ETH'].leafLogs.length, 1, 'leaf data from call A must survive call B');
  assert.deepEqual(cache['ETH'].leafLogs, leafData);
});

console.log(`\n${'═'.repeat(60)}`);
if (failed === 0) {
  console.log(`\x1b[32m  All ${passed} tests passed.\x1b[0m\n`);
  process.exit(0);
} else {
  console.log(`\x1b[31m  ${failed} failed, ${passed} passed.\x1b[0m\n`);
  process.exit(1);
}
