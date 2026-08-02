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
import { createPoseidonContext, createKeyDerivation, createTestRunner, loadPrivacyTestApi } from './_app_source_utils.mjs';

const { poseidon1, poseidon2, poseidon3 } = createPoseidonContext();
const { ppDeriveDepositKeys, ppDeriveWithdrawalKeys } = createKeyDerivation(poseidon2, poseidon3);
const { test, done } = createTestRunner();
const TEST_CONSOLE = { log() {}, warn() {}, error() {} };

const { api } = loadPrivacyTestApi();

function createPrivacyTestContext({ globals = {}, statePatch = null } = {}) {
  return loadPrivacyTestApi({
    globals: {
      console: TEST_CONSOLE,
      ...globals,
    },
    statePatch,
  });
}

const { ppHashHex } = api.shared;
const {
  ppBuildWalletSeedVersionOrder,
  ppShouldRetryWalletSeedVersion,
} = api.wallet;
const {
  ppCompareLoadedAccounts,
  ppGetRecoveredSafeDepositIndex,
  ppTraceLoadedAccountChain,
  ppNormalizePendingDepositReservations,
  ppResolveReservedSafeDepositIndex,
} = api.load;

const CONNECTED_ADDRESS = '0x1111111111111111111111111111111111111111';
const ROUTER_ADDRESS = '0x9999999999999999999999999999999999999999';

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

function ppNormalizeAddressLower(address) {
  return String(address || '').trim().toLowerCase();
}

function ppApplyLoadedAccountReviewStatuses(rows, aspLeaves, depositsByLabel, { statusFetchFailed = false, aspRootVerified = true, connectedAddress = CONNECTED_ADDRESS } = {}) {
  const aspLeafSet = new Set((Array.isArray(aspLeaves) ? aspLeaves : []).map((leaf) => BigInt(leaf).toString()));
  const depositMap = new Map();
  for (const deposit of Array.isArray(depositsByLabel) ? depositsByLabel : []) {
    if (deposit?.label == null) continue;
    depositMap.set(String(deposit.label), deposit);
  }

  const missingLabels = new Set();
  const nextRows = (Array.isArray(rows) ? rows : []).map((row) => {
    const labelKey = ppLoadedAccountLabelKey(row.label);
    const deposit = labelKey != null ? depositMap.get(labelKey) : null;
    const timestamp = deposit?.timestamp ?? null;
    const amount = row.value != null ? BigInt(row.value) : 0n;
    const depositor = row?.depositor ? ppNormalizeAddressLower(row.depositor) : '';
    const normalizedConnected = connectedAddress ? ppNormalizeAddressLower(connectedAddress) : '';
    const isOriginalDepositor = !!(depositor && normalizedConnected && depositor === normalizedConnected);

    if (row.ragequit) {
      return {
        ...row,
        pending: false,
        reviewStatus: PP_REVIEW_STATUS.EXITED,
        isValid: false,
        isWithdrawable: false,
        isOriginalDepositor,
        isRagequittable: false,
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
        isOriginalDepositor,
        isRagequittable: false,
        timestamp,
      };
    }

    let reviewStatus = PP_REVIEW_STATUS.PENDING;
    if (row.currentCommitmentInserted !== true) {
      reviewStatus = PP_REVIEW_STATUS.PENDING;
    } else if (statusFetchFailed || !aspRootVerified) {
      reviewStatus = PP_REVIEW_STATUS.PENDING;
    } else if (!deposit) {
      if (labelKey != null) missingLabels.add(labelKey);
      reviewStatus = PP_REVIEW_STATUS.PENDING;
    } else {
      reviewStatus = ppNormalizeReviewStatus(deposit.reviewStatus);
      if (reviewStatus === PP_REVIEW_STATUS.APPROVED && (labelKey == null || !aspLeafSet.has(labelKey))) {
        reviewStatus = PP_REVIEW_STATUS.PENDING;
      }
    }

    const isValid = reviewStatus === PP_REVIEW_STATUS.APPROVED;
    return {
      ...row,
      pending: reviewStatus === PP_REVIEW_STATUS.PENDING,
      reviewStatus,
      isValid,
      isWithdrawable: isValid && amount > 0n,
      isOriginalDepositor,
      isRagequittable: amount > 0n && isOriginalDepositor,
      timestamp,
    };
  });

  return { rows: nextRows, missingLabels: Array.from(missingLabels) };
}


function ppwHasReusableMasterKeys(masterKeys, connectedAddress = null) {
  if (!masterKeys || (connectedAddress && masterKeys.address !== connectedAddress)) return false;
  return Object.keys(masterKeys.versions || {}).length > 0;
}

function ppwFindSelectedAccountIndex(note, rows) {
  if (!note) return -1;
  return (Array.isArray(rows) ? rows : []).findIndex((row) => {
    if (!row) return false;
    if (note.commitment && row.commitment && row.commitment === note.commitment) return true;
    return row.nullifier === note.nullifier && row.secret === note.secret;
  });
}

function ppwReconcileSelectedAccount(note, rows) {
  const selectedIndex = ppwFindSelectedAccountIndex(note, rows);
  if (selectedIndex < 0) {
    return { selectedIndex, label: null, note: null };
  }
  const row = rows[selectedIndex];
  const asset = row.asset || note.asset || 'ETH';
  return {
    selectedIndex,
    label: 'PA-' + (selectedIndex + 1),
    note: {
      ...note,
      asset,
      derivation: row.derivation || note.derivation || 'safe',
      walletSeedVersion: row.walletSeedVersion || note.walletSeedVersion || null,
      depositIndex: row.depositIndex != null ? Number(row.depositIndex) : note.depositIndex,
      withdrawalIndex: row.withdrawalIndex ?? note.withdrawalIndex,
      leafIndex: row.leafIndex != null ? Number(row.leafIndex) : note.leafIndex,
      value: row.value != null ? BigInt(row.value) : note.value,
      label: row.label != null ? BigInt(row.label) : note.label,
      commitment: row.commitment ?? note.commitment,
      reviewStatus: ppNormalizeReviewStatus(row.reviewStatus),
      isValid: !!row.isValid,
      isWithdrawable: !!row.isWithdrawable,
      timestamp: row.timestamp ?? null,
    },
  };
}

function ppGetLoadedAccountStatus(row) {
  if (row?.ragequit) return PP_REVIEW_STATUS.EXITED;
  if (row?.source === 'spent') return PP_REVIEW_STATUS.SPENT;
  if (row?.reviewStatus) return ppNormalizeReviewStatus(row.reviewStatus);
  return row?.pending ? PP_REVIEW_STATUS.PENDING : PP_REVIEW_STATUS.APPROVED;
}

const PP_PENDING_DEPOSIT_RESERVATION_TTL_MS = 7 * 24 * 60 * 60 * 1000;
const PP_ACCOUNT_SCAN_MAX_CONSECUTIVE_MISSES = 128;

function ppResolvePendingDepositReservations(address, scope, recoveredIndex, reservationsByScope = new Map()) {
  if (!address) return { nextIndex: recoveredIndex };
  const reservations = reservationsByScope.get(String(scope)) || [];
  return ppResolveReservedSafeDepositIndex(recoveredIndex, reservations);
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
  walletSeedVersion = null,
  startIndex = 0,
  maxConsecutiveMisses = PP_ACCOUNT_SCAN_MAX_CONSECUTIVE_MISSES,
}) {
  const results = [];
  let migratedCount = 0;
  let consecutiveMisses = 0;

  for (let index = startIndex; consecutiveMisses <= maxConsecutiveMisses; index++) {
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
      depositor: ev.depositor,
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
        walletSeedVersion,
        pending: false,
        value: '0',
        label: ragequitLabel,
        txHash: ragequit.txHash,
        blockNumber: ragequit.blockNumber,
        depositTxHash: initial.depositTxHash,
        depositBlockNumber: initial.depositBlockNumber,
        originalValue: String(originalValue),
        source: 'spent',
        depositor: initial.depositor,
        derivation: current.derivation,
        ragequit: true,
      });
      continue;
    }

    const currentCommitment = current.commitment == null
      ? null
      : (typeof current.commitment === 'string' ? current.commitment : ppHashHex(current.commitment));
    const currentCommitmentInserted = currentCommitment != null && insertedLeaves.has(currentCommitment);
    const pending = current.source !== 'spent' && currentCommitment != null && !currentCommitmentInserted;
    results.push({
      asset,
      depositIndex: index,
      poolAddress,
      walletSeedVersion,
      currentCommitment,
      currentCommitmentInserted,
      pending,
      depositor: initial.depositor,
      ...current,
    });
  }

  return { results, migratedCount };
}

function ppResolveNextSafeDepositIndex({
  address,
  asset,
  scope,
  keys,
  depositEvents,
  withdrawnMap,
  ragequitMap,
  reservationsByScope = new Map(),
}) {
  const legacyScan = ppCollectWalletAccountsForDerivation({
    asset,
    scope,
    poolAddress: '0xpool',
    depositEvents,
    withdrawnMap,
    ragequitMap,
    insertedLeaves: new Set(),
    derivation: 'legacy',
    keyset: keys.legacy,
    legacyKeys: keys.legacy,
    safeKeys: keys.safe,
  });
  const safeScan = ppCollectWalletAccountsForDerivation({
    asset,
    scope,
    poolAddress: '0xpool',
    depositEvents,
    withdrawnMap,
    ragequitMap,
    insertedLeaves: new Set(),
    derivation: 'safe',
    keyset: keys.safe,
    legacyKeys: keys.legacy,
    safeKeys: keys.safe,
    startIndex: legacyScan.migratedCount,
  });
  const recoveredIndex = ppGetRecoveredSafeDepositIndex(legacyScan.migratedCount, safeScan.results);
  const reservationState = ppResolvePendingDepositReservations(address, scope, recoveredIndex, reservationsByScope);
  return reservationState.nextIndex;
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

function makeDepositEvent(keys, scope, index, label, value, blockNumber, txHash, depositor = CONNECTED_ADDRESS) {
  const dk = ppDeriveDepositKeys(keys.masterNullifier, keys.masterSecret, scope, index);
  return {
    dk,
    event: {
      commitment: ppHashHex(poseidon3([value, label, dk.precommitment])),
      depositor,
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

test('zero label accounts still hydrate review status and become withdrawable', () => {
  const zeroLabel = 0n;
  const { dk, event } = makeDepositEvent(SAFE_KEYS, SCOPE, 5, zeroLabel, 8n, 125n, '0xdep-zero-label');
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
    startIndex: 5,
  });

  const applied = ppApplyLoadedAccountReviewStatuses(results, [zeroLabel], [
    { label: zeroLabel.toString(), reviewStatus: PP_REVIEW_STATUS.APPROVED, timestamp: 777 },
  ]).rows;
  assert.equal(applied[0].label, zeroLabel);
  assert.equal(applied[0].reviewStatus, PP_REVIEW_STATUS.APPROVED);
  assert.equal(applied[0].isWithdrawable, true);
  assert.equal(applied[0].timestamp, 777);
});

test('approved account stays pending when the ASP root is stale', () => {
  const label = poseidon2([13n, 99n]);
  const { dk, event } = makeDepositEvent(SAFE_KEYS, SCOPE, 4, label, 8n, 126n, '0xdep-stale-root');
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
    startIndex: 4,
  });

  const applied = ppApplyLoadedAccountReviewStatuses(results, [label], [
    { label: label.toString(), reviewStatus: PP_REVIEW_STATUS.APPROVED, timestamp: 112 },
  ], { aspRootVerified: false }).rows;
  assert.equal(applied[0].reviewStatus, PP_REVIEW_STATUS.PENDING);
  assert.equal(applied[0].isWithdrawable, false);
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

test('zero change-commitment hashes still reconstruct zero-value change chains', () => {
  const label = poseidon2([41n, 42n]);
  const { dk, event } = makeDepositEvent(SAFE_KEYS, SCOPE, 6, label, 5n, 135n, '0xdep-zero-change');
  const { key, event: withdrawalEvent } = makeWithdrawalEvent(dk.nullifier, 5n, 0n, 136n, '0xwd-zero-change');

  const { results } = ppCollectWalletAccountsForDerivation({
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
    startIndex: 6,
  });

  assert.equal(results.length, 1);
  assert.equal(results[0].source, 'spent');
  assert.equal(results[0].originalValue, 5n);
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

test('deposits-by-label validation rejects non-object rows', async () => {
  const { api: scopedApi, context } = createPrivacyTestContext();
  context.ppFetchJson = async () => ['not-an-object'];

  await assert.rejects(
    scopedApi.load.ppFetchDepositsByLabel('scope-non-object', ['101']),
    /row 0: expected object/,
  );
});

test('deposits-by-label validation rejects non-BigInt labels', async () => {
  const { api: scopedApi, context } = createPrivacyTestContext();
  context.ppFetchJson = async () => [{
    label: 'not-a-bigint',
    reviewStatus: PP_REVIEW_STATUS.APPROVED,
    timestamp: 1700000000,
  }];

  await assert.rejects(
    scopedApi.load.ppFetchDepositsByLabel('scope-bad-label', ['102']),
    /label must be BigInt-coercible/,
  );
});

test('deposits-by-label validation rejects invalid reviewStatus fields', async () => {
  const { api: scopedApi, context } = createPrivacyTestContext();
  context.ppFetchJson = async () => [{
    label: '103',
    reviewStatus: null,
    timestamp: 1700000000,
  }];

  await assert.rejects(
    scopedApi.load.ppFetchDepositsByLabel('scope-bad-status', ['103']),
    /reviewStatus must be a string/,
  );
});

test('deposits-by-label validation rejects invalid timestamps', async () => {
  const { api: scopedApi, context } = createPrivacyTestContext();
  context.ppFetchJson = async () => [{
    label: '104',
    reviewStatus: PP_REVIEW_STATUS.APPROVED,
    timestamp: '1700000000',
  }];

  await assert.rejects(
    scopedApi.load.ppFetchDepositsByLabel('scope-bad-timestamp', ['104']),
    /timestamp must be a finite number/,
  );
});

test('malformed deposits-by-label responses keep loaded accounts fail-closed', async () => {
  const { api: scopedApi, context } = createPrivacyTestContext({
    globals: {
      _ppConfig: {
        pool: '0x1111111111111111111111111111111111111111',
        minimumDepositAmount: 1n,
        vettingFeeBPS: 0n,
        maxRelayFeeBPS: 50n,
      },
    },
  });
  const label = poseidon2([60n, 61n]);
  const baseRow = {
    asset: 'ETH',
    label,
    value: '1000000000000000000',
    source: 'deposit',
    pending: false,
    currentCommitmentInserted: true,
    reviewStatus: PP_REVIEW_STATUS.PENDING,
    isWithdrawable: false,
    isValid: false,
  };
  context.ppCollectWalletAccountsForDerivation = ({ derivation }) => ({
    migratedCount: 0,
    results: derivation === 'safe' ? [baseRow] : [],
  });
  context.ppFetchMtLeaves = async () => ({
    aspLeaves: [label.toString()],
    stateTreeLeaves: [],
  });
  context.ppFetchJson = async () => [{
    label: label.toString(),
    reviewStatus: PP_REVIEW_STATUS.APPROVED,
    timestamp: 'invalid',
  }];
  context.ppReadEntrypoint = async (reader) => reader({
    latestRoot: async () => 0n,
  });

  const result = await scopedApi.load.ppBuildLoadedPoolAccountsFromEvents([
    {
      asset: 'ETH',
      depositLogs: [],
      withdrawnLogs: [],
      ragequitLogs: [],
      leafLogs: [],
    },
  ], { safe: {}, legacy: {} }, 'v2');

  assert.equal(result.results.length, 1);
  assert.equal(result.results[0].reviewStatus, PP_REVIEW_STATUS.PENDING);
  assert.equal(result.results[0].isWithdrawable, false);
  assert.equal(result.results[0].pending, true);
  assert.equal(result.warnings.length, 1);
  assert.equal(result.warnings[0].asset, 'ETH');
  assert.equal(result.warnings[0].kind, 'review-status');
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

test('account recovery includes deposits at the miss-limit boundary', () => {
  const label = poseidon2([50n, 51n]);
  const boundaryIndex = PP_ACCOUNT_SCAN_MAX_CONSECUTIVE_MISSES;
  const { dk, event } = makeDepositEvent(SAFE_KEYS, SCOPE, boundaryIndex, label, 7n, 156n, '0xdep-boundary');
  const { results } = ppCollectWalletAccountsForDerivation({
    asset: 'BOLD',
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
  assert.equal(results[0].depositIndex, boundaryIndex);
});

test('migrated safe recovery reaches the first live note after 25 migrated slots', () => {
  const label = poseidon2([54n, 55n]);
  const migratedCount = 25;
  const firstRecoverableIndex = 50;
  const { dk, event } = makeDepositEvent(SAFE_KEYS, SCOPE, firstRecoverableIndex, label, 50n, 156n, '0xdep-main-gap');
  const depositEvents = new Map([[ppHashHex(dk.precommitment), event]]);
  const baseArgs = {
    asset: 'BOLD',
    scope: SCOPE,
    poolAddress: '0xpool',
    depositEvents,
    withdrawnMap: new Map(),
    ragequitMap: new Map(),
    insertedLeaves: new Set([event.commitment]),
    derivation: 'safe',
    keyset: SAFE_KEYS,
    legacyKeys: LEGACY_KEYS,
    safeKeys: SAFE_KEYS,
    startIndex: migratedCount,
  };

  const mainScan = ppCollectWalletAccountsForDerivation({
    ...baseArgs,
    maxConsecutiveMisses: 24,
  });
  const currentScan = ppCollectWalletAccountsForDerivation(baseArgs);

  assert.equal(mainScan.results.length, 0, 'main branch stops before the first post-migration safe note');
  assert.equal(currentScan.results.length, 1, 'current recovery still reaches the first post-migration safe note');
  assert.equal(currentScan.results[0].depositIndex, firstRecoverableIndex);
  assert.equal(BigInt(currentScan.results[0].value), 50n);
});

test('wallet seed version order prefers explicit, active, then stored values', () => {
  assert.deepEqual(
    Array.from(ppBuildWalletSeedVersionOrder('v1', 'v2', 'v2')),
    ['v1', 'v2'],
  );
  assert.deepEqual(
    Array.from(ppBuildWalletSeedVersionOrder(null, 'v2', 'v1')),
    ['v2', 'v1'],
  );
});

test('wallet seed version fallback only retries after a clean empty scan', () => {
  assert.equal(
    ppShouldRetryWalletSeedVersion({ results: [], warnings: [] }, true),
    true,
  );
  assert.equal(
    ppShouldRetryWalletSeedVersion({ results: [], warnings: [{ asset: 'BOLD' }] }, true),
    false,
  );
  assert.equal(
    ppShouldRetryWalletSeedVersion({ results: [{}], warnings: [] }, true),
    false,
  );
});

test('recovered rows retain wallet seed version for later withdrawals', () => {
  const label = poseidon2([52n, 53n]);
  const { dk, event } = makeDepositEvent(SAFE_KEYS, SCOPE, 3, label, 9n, 157n, '0xdep-version');
  const { results } = ppCollectWalletAccountsForDerivation({
    asset: 'BOLD',
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
    walletSeedVersion: 'v1',
    startIndex: 3,
  });

  assert.equal(results.length, 1);
  assert.equal(results[0].walletSeedVersion, 'v1');
});


test('router-mediated deposits still recover by derived commitment', () => {
  const label = poseidon2([61n, 62n]);
  const { dk, event } = makeDepositEvent(SAFE_KEYS, SCOPE, 12, label, 50n, 200n, '0xdep-router', ROUTER_ADDRESS);
  const { results } = ppCollectWalletAccountsForDerivation({
    asset: 'BOLD',
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
    startIndex: 12,
  });

  assert.equal(results.length, 1);
  assert.equal(results[0].depositIndex, 12);
  assert.equal(BigInt(results[0].value), 50n);
  assert.equal(results[0].depositor, ROUTER_ADDRESS);
});

test('router-mediated deposits are recoverable but not ragequittable from the wallet', () => {
  const label = poseidon2([71n, 72n]);
  const { dk, event } = makeDepositEvent(SAFE_KEYS, SCOPE, 13, label, 25n, 205n, '0xdep-router-rq', ROUTER_ADDRESS);
  const { results } = ppCollectWalletAccountsForDerivation({
    asset: 'wstETH',
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
    startIndex: 13,
  });
  const { api: runtimeApi } = createPrivacyTestContext({
    globals: { _connectedAddress: CONNECTED_ADDRESS },
  });
  const applied = runtimeApi.load.ppApplyLoadedAccountReviewStatuses(results, [label], [
    { label: String(label), reviewStatus: 'approved', timestamp: 123 },
  ]).rows;

  assert.equal(applied.length, 1);
  assert.equal(applied[0].isWithdrawable, true);
  assert.equal(applied[0].isOriginalDepositor, false);
  assert.equal(applied[0].isRagequittable, false);
});

test('declined accounts stay ragequittable for the original depositor wallet', () => {
  const label = poseidon2([81n, 82n]);
  const { dk, event } = makeDepositEvent(SAFE_KEYS, SCOPE, 14, label, 18n, 206n, '0xdep-declined-rq', CONNECTED_ADDRESS);
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
    startIndex: 14,
  });
  const { api: runtimeApi } = createPrivacyTestContext({
    globals: { _connectedAddress: CONNECTED_ADDRESS },
  });
  const applied = runtimeApi.load.ppApplyLoadedAccountReviewStatuses(results, [label], [
    { label: String(label), reviewStatus: 'declined', timestamp: 321 },
  ]).rows;

  assert.equal(applied.length, 1);
  assert.equal(applied[0].reviewStatus, PP_REVIEW_STATUS.DECLINED);
  assert.equal(applied[0].isWithdrawable, false);
  assert.equal(applied[0].isOriginalDepositor, true);
  assert.equal(applied[0].isRagequittable, true);
});


test('oversized event caches are dropped instead of truncating history', () => {
  const { api: runtimeApi, context } = createPrivacyTestContext();
  const oversizedEntry = {
    depositLogs: [{
      topics: ['0xaaa'],
      data: '0x' + 'a'.repeat(1_600_000),
      transactionHash: '0xdeposit',
      blockNumber: 10,
    }],
    withdrawnLogs: [],
    ragequitLogs: [],
    leafLogs: [],
    upToBlock: 100,
    leafUpToBlock: null,
  };

  runtimeApi.load.ppSaveCachedEventLogs('ETH', oversizedEntry);

  assert.equal(context.localStorage.getItem('pp-events-v2-ETH'), null);
  assert.equal(runtimeApi.load.ppLoadCachedEventLogs('ETH'), null);
});

test('background refresh only starts after master keys are actually cached', () => {
  assert.equal(
    ppwHasReusableMasterKeys({ address: '0xabc', activeVersion: null, versions: {} }, '0xabc'),
    false,
  );
  assert.equal(
    ppwHasReusableMasterKeys({ address: '0xabc', activeVersion: 'v2', versions: { v2: { safe: {}, legacy: {} } } }, '0xabc'),
    true,
  );
  assert.equal(
    ppwHasReusableMasterKeys({ address: '0xabc', activeVersion: 'v2', versions: { v2: { safe: {}, legacy: {} } } }, '0xdef'),
    false,
  );
});

test('selected pool account is reconciled by commitment after refresh reorders rows', () => {
  const selectedNote = {
    asset: 'BOLD',
    derivation: 'safe',
    walletSeedVersion: 'v2',
    nullifier: 11n,
    secret: 12n,
    commitment: '0xabc',
    reviewStatus: PP_REVIEW_STATUS.APPROVED,
    isValid: true,
    isWithdrawable: true,
    value: 50n,
  };
  const rows = [
    {
      asset: 'ETH',
      nullifier: 1n,
      secret: 2n,
      commitment: '0xeth',
      reviewStatus: PP_REVIEW_STATUS.APPROVED,
      isValid: true,
      isWithdrawable: true,
      value: 1n,
    },
    {
      asset: 'BOLD',
      derivation: 'safe',
      walletSeedVersion: 'v2',
      nullifier: 11n,
      secret: 12n,
      commitment: '0xabc',
      reviewStatus: PP_REVIEW_STATUS.PENDING,
      isValid: false,
      isWithdrawable: false,
      value: 50n,
      label: 77n,
      depositIndex: 3,
      withdrawalIndex: 0,
      leafIndex: 9,
      timestamp: 1234,
    },
  ];

  const reconciled = ppwReconcileSelectedAccount(selectedNote, rows);
  assert.equal(reconciled.selectedIndex, 1);
  assert.equal(reconciled.label, 'PA-2');
  assert.equal(reconciled.note.asset, 'BOLD');
  assert.equal(reconciled.note.reviewStatus, PP_REVIEW_STATUS.PENDING);
  assert.equal(reconciled.note.isWithdrawable, false);
  assert.equal(reconciled.note.depositIndex, 3);
  assert.equal(reconciled.note.leafIndex, 9);
});

test('selected pool account closes when refresh no longer returns it', () => {
  const selectedNote = {
    asset: 'BOLD',
    nullifier: 11n,
    secret: 12n,
    commitment: '0xmissing',
  };

  const reconciled = ppwReconcileSelectedAccount(selectedNote, []);
  assert.equal(reconciled.selectedIndex, -1);
  assert.equal(reconciled.label, null);
  assert.equal(reconciled.note, null);
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

test('next safe deposit index applies reservations for the connected wallet', () => {
  const label = poseidon2([70n, 71n]);
  const { dk, event } = makeDepositEvent(SAFE_KEYS, SCOPE, 0, label, 10n, 210n, '0xdep-safe');
  const nextIndex = ppResolveNextSafeDepositIndex({
    address: '0xabc',
    asset: 'ETH',
    scope: SCOPE,
    keys: { legacy: LEGACY_KEYS, safe: SAFE_KEYS },
    depositEvents: new Map([[ppHashHex(dk.precommitment), event]]),
    withdrawnMap: new Map(),
    ragequitMap: new Map(),
    reservationsByScope: new Map([[String(SCOPE), [{ depositIndex: 1, status: 'pending', createdAt: Date.now() }]]]),
  });

  assert.equal(nextIndex, 2);
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
  assert.equal(resolved.pendingIndex, undefined);
});

test('unconfirmed pending-deposit reservations still advance the next safe slot', () => {
  const resolved = ppResolveReservedSafeDepositIndex(2, [
    { depositIndex: 2, status: 'pending', createdAt: 10 },
    { depositIndex: 3, status: 'confirmed', createdAt: 20 },
  ]);

  assert.equal(resolved.nextIndex, 4);
  assert.equal(resolved.pendingIndex, undefined);
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

// ── On-chain reinstatement of falsely-spent accounts ─────────────────
// A note is only spent if the pool says so. Event tracing is a claim; if it is
// wrong the note must come back, otherwise withdrawable funds are stranded.

function createSpentRow(overrides = {}) {
  return {
    asset: 'ETH',
    depositIndex: 3,
    source: 'spent',
    value: '0',
    originalValue: '99500000000000000',
    label: 42n,
    depositTxHash: '0xdep',
    depositBlockNumber: 100,
    txHash: '0xwithdraw',
    blockNumber: 200,
    spentByTxHash: '0xwithdraw',
    withdrawalSteps: [{ value: 1n, txHash: '0xwithdraw', blockNumber: 200 }],
    preSpend: {
      nullifier: 7n,
      secret: 8n,
      precommitment: 9n,
      commitment: '0x' + 'ab'.padStart(64, '0'),
      value: '99500000000000000',
      label: 42n,
      withdrawalIndex: null,
      source: 'deposit',
      derivation: 'safe',
      blockNumber: 100,
      txHash: '0xdep',
    },
    ...overrides,
  };
}

const { ethers: realEthers } = createPoseidonContext({ withEthers: true });

function loadReinstateApi(nullifierHashesImpl) {
  // Keep the real ethers (the runtime builds Interfaces at load time) and swap
  // only the Contract constructor so the pool read is scripted.
  const stubbedEthers = Object.create(realEthers);
  stubbedEthers.Contract = class {
    constructor() {
      this.nullifierHashes = nullifierHashesImpl;
    }
  };
  const { api } = createPrivacyTestContext({
    globals: {
      poseidon1: (inputs) => inputs[0],
      ethers: stubbedEthers,
      // The runtime declares ppReadWithRpc itself, so a global of that name is
      // shadowed; stub the provider it delegates to instead.
      quoteRPC: { call: async (work) => work({}) },
    },
  });
  return api.load.ppReinstateFalselySpentAccounts;
}

test('a note the pool reports as unspent is reinstated as live and withdrawable', async () => {
  const reinstate = loadReinstateApi(async () => false);
  const row = createSpentRow();
  const inserted = new Set([row.preSpend.commitment]);

  const [next] = await reinstate([row], '0xpool', inserted);

  assert.equal(next.source, 'deposit');
  assert.equal(next.value, '99500000000000000');
  assert.equal(next.nullifier, 7n);
  assert.equal(next.secret, 8n);
  assert.equal(next.currentCommitment, row.preSpend.commitment);
  assert.equal(next.currentCommitmentInserted, true);
  assert.equal(next.pending, false);
  assert.equal(next.spentTraceReinstated, true);
  assert.equal(next.withdrawalSteps, undefined);
});

test('a note the pool reports as spent stays spent', async () => {
  const reinstate = loadReinstateApi(async () => true);
  const row = createSpentRow();

  const [next] = await reinstate([row], '0xpool', new Set());

  assert.equal(next, row);
  assert.equal(next.source, 'spent');
});

test('an unverifiable spent check leaves the conservative verdict in place', async () => {
  const reinstate = loadReinstateApi(async () => { throw new Error('rpc down'); });
  const row = createSpentRow();

  const [next] = await reinstate([row], '0xpool', new Set());

  assert.equal(next.source, 'spent');
});

test('ragequit rows and rows without pre-spend state are never reinstated', async () => {
  const reinstate = loadReinstateApi(async () => false);
  const ragequitRow = createSpentRow({ ragequit: true });
  const noSnapshot = createSpentRow({ preSpend: undefined });

  const rows = await reinstate([ragequitRow, noSnapshot], '0xpool', new Set());

  assert.equal(rows[0], ragequitRow);
  assert.equal(rows[1], noSnapshot);
});

test('a reinstated note whose commitment is not yet in the tree reads as pending', async () => {
  const reinstate = loadReinstateApi(async () => false);
  const row = createSpentRow();

  const [next] = await reinstate([row], '0xpool', new Set());

  assert.equal(next.currentCommitmentInserted, false);
  assert.equal(next.pending, true);
});

// ── Saved-note recovery ──────────────────────────────────────────────

const { ppwParseRecoveryNoteInput } = api.load;

test('note parsing accepts hex and decimal fields', () => {
  const [note] = ppwParseRecoveryNoteInput(JSON.stringify({
    nullifier: '0x07',
    secret: '8',
    label: '42',
    value: '99500000000000000',
  }));

  assert.equal(note.nullifier, 7n);
  assert.equal(note.secret, 8n);
  assert.equal(note.label, 42n);
  assert.equal(note.value, 99500000000000000n);
});

test('note parsing unwraps nested and array shapes', () => {
  const wrapped = ppwParseRecoveryNoteInput(JSON.stringify({ note: { nullifier: '1', secret: '2' } }));
  assert.equal(wrapped.length, 1);
  assert.equal(wrapped[0].nullifier, 1n);

  const list = ppwParseRecoveryNoteInput(JSON.stringify([
    { nullifier: '1', secret: '2' },
    { nullifier: '3', secret: '4' },
  ]));
  assert.equal(list.length, 2);
  assert.equal(list[1].secret, 4n);
});

test('note parsing reads alternate field names and asset hints', () => {
  const [note] = ppwParseRecoveryNoteInput(JSON.stringify({
    Nullifier: '1',
    Secret: '2',
    amount: '5',
    symbol: 'wstETH',
    depositIndex: 3,
  }));

  assert.equal(note.value, 5n);
  assert.equal(note.asset, 'wstETH');
  assert.equal(note.depositIndex, 3);
});

test('note parsing rejects unusable input with actionable messages', () => {
  assert.throws(() => ppwParseRecoveryNoteInput(''), /Paste your note JSON/);
  assert.throws(() => ppwParseRecoveryNoteInput('not json'), /does not look like JSON/);
  assert.throws(() => ppwParseRecoveryNoteInput('{"nullifier":"1"}'), /nullifier.*secret/);
  assert.throws(() => ppwParseRecoveryNoteInput('{"nullifier":"-1","secret":"2"}'), /nullifier.*secret/);
});

test('a recovery phrase is detected and note JSON is not mistaken for one', () => {
  const { ppwExtractRecoveryPhrase } = api.load;
  const twelve = 'abandon ability able about above absent absorb abstract absurd abuse access accident';

  assert.equal(ppwExtractRecoveryPhrase(twelve), twelve);
  assert.equal(ppwExtractRecoveryPhrase('  ' + twelve.toUpperCase() + '  '), twelve);
  assert.equal(ppwExtractRecoveryPhrase('{"nullifier":"1","secret":"2"}'), null);
  assert.equal(ppwExtractRecoveryPhrase('abandon ability able'), null, 'too few words');
  assert.equal(ppwExtractRecoveryPhrase(twelve + ' 0x1234'), null, 'non-word tokens');
});


await done();
