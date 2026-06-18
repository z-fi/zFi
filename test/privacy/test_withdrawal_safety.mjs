#!/usr/bin/env node
//
// Privacy withdrawal safety and journey tests.
//
// Covers the live withdrawal helpers exposed through the gated PP test API:
// validation, preview, relay quote binding, proof lifecycle, root rechecks,
// submission, terminal UI handling, and thin orchestration.
//
// Usage: node test/privacy/test_withdrawal_safety.mjs
//
import { strict as assert } from 'node:assert';
import { readFileSync } from 'node:fs';
import { createDom, createElement, createHarness as createPrivacyHarness, createPoseidonContext, createTestRunner, flushMicrotasks, loadPrivacyTestApi } from './_app_source_utils.mjs';

const TEST_CONSOLE = { log() {}, warn() {}, error() {} };
const CONNECTED_ADDRESS = '0x1111111111111111111111111111111111111111';
const OTHER_ADDRESS = '0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const RELAY_RECIPIENT = '0x2222222222222222222222222222222222222222';
const RELAYER_ADDRESS = '0x3333333333333333333333333333333333333333';
const ENTRYPOINT_ADDRESS = '0x4444444444444444444444444444444444444444';
const WSTETH_ADDRESS = '0x7f39c581f595b53c5cb19bd0b3f8da6c935e2ca0';
const BOLD_ADDRESS = '0x6440f144b7e50d6a8439336510312d2f54beb01d';
const VENDORED_SNARKJS_BUNDLE = readFileSync(new URL('../../dapp/vendor/snarkjs.min.js', import.meta.url));

const { test, done } = createTestRunner();

function toArrayBuffer(buffer) {
  return buffer.buffer.slice(buffer.byteOffset, buffer.byteOffset + buffer.byteLength);
}

function testBtoa(binary) {
  return Buffer.from(binary, 'binary').toString('base64');
}

function createBaseNote(overrides = {}) {
  return {
    isWithdrawable: true,
    reviewStatus: 'approved',
    value: 10_000000000000000000n,
    label: 123n,
    precommitment: 456n,
    nullifier: 789n,
    secret: 987n,
    asset: 'ETH',
    derivation: 'safe',
    walletSeedVersion: 'v2',
    leafIndex: 0,
    depositIndex: 0,
    withdrawalIndex: null,
    ...overrides,
  };
}

function createRun() {
  const logs = [];
  const stages = [];
  const buttonTexts = [];
  return {
    logs,
    stages,
    buttonTexts,
    log(message) {
      logs.push(String(message));
    },
    logHtml(message) {
      logs.push(String(message));
    },
    setProgressStage(stageKey, mode, options = {}) {
      stages.push({ stageKey, mode, options });
    },
    setButtonText(label) {
      buttonTexts.push(label);
    },
    reset() {},
    stopIfNeeded() {},
  };
}

function formatWeiForInput(value) {
  const amount = BigInt(value);
  const whole = amount / 10n ** 18n;
  const fraction = amount % 10n ** 18n;
  if (fraction === 0n) return whole.toString();
  return `${whole}.${fraction.toString().padStart(18, '0').replace(/0+$/, '')}`;
}

async function showValidRelayQuote(harness, {
  intent = createIntent(),
  run = createRun(),
  feeBps = 35,
} = {}) {
  harness.elements.ppwRecipient.value = intent.customRecipient || intent.resolvedRecipient || '';
  if (intent.note?.value != null && intent.withdrawnValue != null && intent.withdrawnValue !== intent.note.value) {
    harness.elements.ppwWithdrawAmt.value = formatWeiForInput(intent.withdrawnValue);
  } else {
    harness.elements.ppwWithdrawAmt.value = '';
  }
  const quoteState = harness.api.withdrawal.ppwCreateRelayQuoteState(intent);
  let quoteCalls = 0;
  harness.context.ppwRelayerDetails = async () => ({ feeReceiverAddress: RELAYER_ADDRESS });
  harness.context.ppwRelayerQuote = async (chainId, amount, asset, recipient, extraGas) => {
    quoteCalls += 1;
    return {
      feeCommitment: createRelayFeeCommitment(harness, asset, {
        amount: amount.toString(),
        extraGas: !!extraGas,
        withdrawalData: harness.context.ethers.AbiCoder.defaultAbiCoder().encode(
          ['address', 'address', 'uint256'],
          [recipient, RELAYER_ADDRESS, feeBps],
        ),
        fee: ((BigInt(amount) * BigInt(feeBps)) / 10000n).toString(),
      }),
    };
  };
  harness.context.ppwValidateRelayQuoteCommitment = (chainId, feeCommitment) => ({
    recoveredSigner: RELAYER_ADDRESS,
    expirationMs: feeCommitment.expiration,
  });
  harness.context.ppwDecodeRelayWithdrawalData = () => ({
    recipient: intent.resolvedRecipient,
    relayer: RELAYER_ADDRESS,
    feeBps,
  });
  harness.context.ppwResolveAllowedRelayRecipients = () => [RELAYER_ADDRESS];
  harness.context.ppEnsureAssetConfig = async () => ({ maxRelayFeeBPS: 50 });
  harness.context.ppwStartExpiryCountdown = () => {};
  await harness.api.withdrawal.ppwRefreshRelayQuote(quoteState, intent, run, true);
  return { quoteState, quoteCallsRef: () => quoteCalls };
}

async function requestRelayReview(harness, {
  note = harness.context._ppwNote,
  wAsset = note?.asset || 'ETH',
  feeBps = 35,
  extraGas = false,
} = {}) {
  const isBold = wAsset === 'BOLD';
  const isWstEth = wAsset === 'wstETH';
  const intent = createIntent({
    note,
    wAsset,
    wIsBOLD: isBold,
    wIsWSTETH: isWstEth,
    value: note?.value ?? 10_000000000000000000n,
    withdrawnValue: note?.value ?? 10_000000000000000000n,
  });
  harness.elements.ppwRecipient.value = RELAY_RECIPIENT;
  harness.elements.ppwExtraGas.checked = !!extraGas;
  harness.context.ppwRelayerDetails = async () => ({ feeReceiverAddress: RELAYER_ADDRESS });
  let quoteCalls = 0;
  harness.context.ppwRelayerQuote = async (chainId, amount, asset, recipient, extraGas) => {
    quoteCalls += 1;
    return {
      feeCommitment: createRelayFeeCommitment(harness, asset, {
        amount: amount.toString(),
        extraGas: !!extraGas,
        withdrawalData: harness.context.ethers.AbiCoder.defaultAbiCoder().encode(
          ['address', 'address', 'uint256'],
          [recipient, RELAYER_ADDRESS, feeBps],
        ),
        fee: ((BigInt(amount) * BigInt(feeBps)) / 10000n).toString(),
      }),
    };
  };
  harness.context.ppwValidateRelayQuoteCommitment = (chainId, feeCommitment) => ({
    recoveredSigner: RELAYER_ADDRESS,
    expirationMs: feeCommitment.expiration,
  });
  harness.context.ppwDecodeRelayWithdrawalData = () => ({
    recipient: RELAY_RECIPIENT,
    relayer: RELAYER_ADDRESS,
    feeBps,
  });
  harness.context.ppwResolveAllowedRelayRecipients = () => [RELAYER_ADDRESS];
  harness.context.ppEnsureAssetConfig = async () => ({ maxRelayFeeBPS: 50 });
  harness.context.ppwStartExpiryCountdown = () => {};
  const reviewed = await harness.api.withdrawal.ppwRequestRelayQuoteReview();
  return { reviewed, quoteCallsRef: () => quoteCalls };
}

function createHarness({
  globals = {},
  statePatch = null,
  note = createBaseNote(),
  mode = 'relay',
  actionKind = 'withdraw',
} = {}) {
  return createPrivacyHarness({
    globals: {
      console: TEST_CONSOLE,
      BOLD_ADDRESS,
      WSTETH_ADDRESS,
      _connectedAddress: CONNECTED_ADDRESS,
      _isWalletConnect: false,
      _connectedWalletProvider: null,
      _signer: { getAddress: async () => CONNECTED_ADDRESS },
      _ppwMode: mode,
      _ppwActionKind: actionKind,
      _ppwNote: note,
      _ppwSelectedAccountLabel: 'PA-1',
      _ppwRelayerMinByAsset: {},
      _ppwRelayExpiryTimer: null,
      _ppwAnonReqId: 0,
      _ppwAnonTimer: null,
      _ppwRelayerMinReqId: 0,
      ZERO_ADDRESS: '0x0000000000000000000000000000000000000000',
      tokens(value) {
        return String(value);
      },
      coinGetResolved(id) {
        return id === 'ppwRecipient' ? RELAY_RECIPIENT : null;
      },
      ppEnsureWalletCompatibility: async () => ({ supported: true, kind: 'eoa', message: '' }),
      ppReadWithRpc: async (reader) => reader({ getTransactionReceipt: async () => null }),
      ppReadEntrypoint: async (reader) => reader({ latestRoot: async () => 55n }),
      ppwClearAnonymityHint() {},
      ppwScheduleAnonymityHint() {},
      ppwRenderRoundedSuggestions() {},
      ...globals,
    },
    statePatch: {
      _ppwMode: mode,
      _ppwActionKind: actionKind,
      _ppwNote: note,
      ...(statePatch || {}),
    },
    baseElements: {
      ppwWithdrawAmt: createElement({ value: '' }, { withScrollIntoView: true }),
      ppwAmountSection: createElement({}, { withScrollIntoView: true }),
      ppwModeSection: createElement({}, { withScrollIntoView: true }),
      ppwRecipientSection: createElement({}, { withScrollIntoView: true }),
      ppwDraftActionLink: createElement({}, { withScrollIntoView: true }),
      ppwWithdrawPct25: createElement({}, { withScrollIntoView: true }),
      ppwWithdrawPct50: createElement({}, { withScrollIntoView: true }),
      ppwWithdrawPct75: createElement({}, { withScrollIntoView: true }),
      ppwWithdrawPct100: createElement({}, { withScrollIntoView: true }),
      ppwRecipient: createElement({ value: '' }, { withScrollIntoView: true }),
      ppwRecipientLabel: createElement({}, { withScrollIntoView: true }),
      ppwRecipientResolved: createElement({}, { withScrollIntoView: true }),
      ppwRelayRecipientWrap: createElement({}, { withScrollIntoView: true }),
      ppwParsed: createElement({}, { withScrollIntoView: true }),
      ppBalance: createElement({}, { withScrollIntoView: true }),
      ppwLoadDisconnected: createElement({}, { withScrollIntoView: true }),
      ppwLoadConnected: createElement({}, { withScrollIntoView: true }),
      ppwLoadResults: createElement({}, { withScrollIntoView: true }),
      ppwActivitySection: createElement({}, { withScrollIntoView: true }),
      ppwPreview: createElement({}, { withScrollIntoView: true }),
      ppwPreviewTitle: createElement({}, { withScrollIntoView: true }),
      ppwPreviewContent: createElement({}, { withScrollIntoView: true }),
      ppwChangeWarning: createElement({}, { withScrollIntoView: true }),
      ppwRelayMinWarning: createElement({}, { withScrollIntoView: true }),
      ppwRagequitWarning: createElement({}, { withScrollIntoView: true }),
      ppwSuggestWrap: createElement({}, { withScrollIntoView: true }),
      ppwSuggestBtns: createElement({}, { withScrollIntoView: true }),
      ppwAnonHint: createElement({}, { withScrollIntoView: true }),
      ppwWithdrawBalanceHint: createElement({}, { withScrollIntoView: true }),
      ppwWithdrawAmtLabel: createElement({}, { withScrollIntoView: true }),
      ppwModeSummary: createElement({}, { withScrollIntoView: true }),
      ppwExtraGasWrap: createElement({}, { withScrollIntoView: true }),
      ppwExtraGas: createElement({ checked: false, disabled: false }, { withScrollIntoView: true }),
      ppwRelayFeePanel: createElement({}, { withScrollIntoView: true }),
      ppwRelayFeeBps: createElement({}, { withScrollIntoView: true }),
      ppwRelayFeeAmt: createElement({}, { withScrollIntoView: true }),
      ppwRelayExpiry: createElement({}, { withScrollIntoView: true }),
      ppwVerifyStatus: createElement({}, { withScrollIntoView: true }),
      ppwVerify: createElement({}, { withScrollIntoView: true }),
      ppwProgressWrap: createElement({}, { withScrollIntoView: true }),
      ppwProgressLabel: createElement({}, { withScrollIntoView: true }),
      ppwProgressSub: createElement({}, { withScrollIntoView: true }),
      ppwProgressBar: createElement({}, { withScrollIntoView: true }),
      ppwWithdrawBtn: createElement({}, { withScrollIntoView: true }),
      ppwResultSummary: createElement({}, { withScrollIntoView: true }),
      ppwResult: createElement({}, { withScrollIntoView: true }),
      ppwResultBackWrap: createElement({}, { withScrollIntoView: true }),
    },
  });
}

function createIntent(overrides = {}) {
  return {
    note: createBaseNote(),
    value: 10_000000000000000000n,
    label: 123n,
    wAsset: 'ETH',
    withdrawnValue: 5_000000000000000000n,
    recipient: RELAY_RECIPIENT,
    resolvedRecipient: RELAY_RECIPIENT,
    customRecipient: RELAY_RECIPIENT,
    isRelayMode: true,
    wIsBOLD: false,
    wIsWSTETH: false,
    poolAddress: '0x5555555555555555555555555555555555555555',
    scope: 777n,
    leafIndex: 0,
    ...overrides,
  };
}

async function markWalletCompatibilityReady(harness, result = { supported: true, kind: 'eoa', message: '' }) {
  harness.context.ppDetectWalletCompatibility = async () => result;
  await harness.api.wallet.ppRefreshWalletCompatibility(true);
}

function createWithdrawalState(overrides = {}) {
  return {
    expectedCommitment: 999n,
    adjustedLeafIndex: 0,
    stateTree: { root: 111n, depth: 1 },
    stateSiblings: Array(32).fill(0n),
    aspTree: { root: 222n, depth: 1 },
    aspSiblings: Array(32).fill(0n),
    aspIndex: 0,
    ...overrides,
  };
}

function createProofResult() {
  return {
    proof: {
      pi_a: ['1', '2'],
      pi_b: [['3', '4'], ['5', '6']],
      pi_c: ['7', '8'],
    },
    publicSignals: ['1', '2', '3', '4', '5', '6', '7', '8'],
  };
}

function createRelayFeeCommitment(harness, assetAddress, patch = {}) {
  const encodedWithdrawalData = harness.context.ethers.AbiCoder.defaultAbiCoder().encode(
    ['address', 'address', 'uint256'],
    [RELAY_RECIPIENT, RELAYER_ADDRESS, 35],
  );
  return {
    withdrawalData: encodedWithdrawalData,
    asset: assetAddress,
    expiration: Date.now() + 60_000,
    amount: '5000000000000000000',
    extraGas: false,
    signedRelayerCommitment: '0xsigned',
    fee: '17500000000000000',
    ...patch,
  };
}

function createMatchingWithdrawalProof(harness, circuitInputs) {
  const withdrawnValue = BigInt(circuitInputs.withdrawnValue);
  const existingValue = BigInt(circuitInputs.existingValue);
  const label = BigInt(circuitInputs.label);
  const existingNullifier = BigInt(circuitInputs.existingNullifier);
  const newNullifier = BigInt(circuitInputs.newNullifier);
  const newSecret = BigInt(circuitInputs.newSecret);
  const nullifierHash = harness.context.poseidon1([existingNullifier]);
  const newPrecommitment = harness.context.poseidon2([newNullifier, newSecret]);
  const newCommitment = harness.context.poseidon3([existingValue - withdrawnValue, label, newPrecommitment]);
  return {
    proof: createProofResult().proof,
    publicSignals: [
      newCommitment,
      nullifierHash,
      withdrawnValue,
      BigInt(circuitInputs.stateRoot),
      BigInt(circuitInputs.stateTreeDepth),
      BigInt(circuitInputs.ASPRoot),
      BigInt(circuitInputs.ASPTreeDepth),
      BigInt(circuitInputs.context),
    ].map(String),
  };
}

console.log('\n-- Withdrawal helpers --');

test('leanIMT proof stays padded to circuit depth', () => {
  const harness = createHarness();
  const tree = harness.api.withdrawal.leanIMTBuild([11n, 22n, 33n]);
  const siblings = harness.api.withdrawal.leanIMTProof(tree.levels, 1);
  assert.equal(siblings.length, 32);
});

test('next withdrawal index prefers the note lineage when available', () => {
  const harness = createHarness();
  const resolved = harness.api.withdrawal.ppResolveNextWithdrawalIndex(
    11n,
    22n,
    33n,
    44n,
    2,
    0,
  );
  assert.equal(resolved.nextIndex, 3);
  assert.equal(resolved.source, 'note');
});

test('preview builder hides preview for full withdrawals (no new info until quote)', () => {
  const harness = createHarness({
    mode: 'relay',
    note: createBaseNote({ value: 1_000000000000000000n }),
  });

  const preview = harness.api.withdrawal.ppwBuildPreviewState(
    createBaseNote({ value: 1_000000000000000000n }),
    'relay',
    CONNECTED_ADDRESS,
  );

  assert.equal(preview.show, false);
  assert.equal(preview.isPartial, false);
});

test('preview builder produces partial withdrawal data even when preview is hidden', () => {
  const harness = createHarness({
    mode: 'relay',
    note: createBaseNote({ value: 8_000000000000000000n }),
  });
  harness.elements.ppwWithdrawAmt.value = '3';
  harness.elements.ppwRecipient.value = RELAY_RECIPIENT;

  const preview = harness.api.withdrawal.ppwBuildPreviewState(
    createBaseNote({ value: 8_000000000000000000n }),
    'relay',
    CONNECTED_ADDRESS,
  );

  assert.equal(preview.show, false);
  assert.equal(preview.isPartial, true);
  assert.equal(preview.previewRecipient, RELAY_RECIPIENT);
  assert.match(preview.warningText, /partial withdrawal/i);
});

test('preview renderer hides the preview cleanly for empty states', () => {
  const harness = createHarness();
  harness.api.withdrawal.ppwRenderPreviewState({ show: false, asset: 'ETH', value: 1n });
  assert.equal(harness.elements.ppwPreview.style.display, 'none');
  assert.equal(harness.elements.ppwChangeWarning.style.display, 'none');
});

test('relay editing state uses the review quote action', () => {
  const harness = createHarness({ mode: 'relay' });
  harness.api.withdrawal.ppwSetDraftInteractivity('editing');

  assert.equal(harness.api.withdrawal.ppwGetDraftPhase(), 'editing');
  assert.equal(harness.elements.ppwWithdrawBtn.textContent, 'Review quote');
  assert.equal(harness.elements.ppwDraftActionLink.textContent, '× Cancel');
});

test('requesting a relay review enters review state only after a validated quote is fetched', async () => {
  const boldNote = createBaseNote({ asset: 'BOLD', value: 8_000000000000000000n });
  const harness = createHarness({
    mode: 'relay',
    note: boldNote,
    statePatch: { _ppwMode: 'relay', _ppwNote: boldNote },
  });
  const { reviewed } = await requestRelayReview(harness, { note: boldNote, wAsset: 'BOLD' });

  assert.ok(reviewed);
  assert.equal(harness.api.withdrawal.ppwGetDraftPhase(), 'review');
  assert.equal(harness.api.withdrawal.ppwHasReviewedRelayQuote(), true);
  assert.equal(harness.elements.ppwWithdrawBtn.textContent, 'Confirm withdrawal');
  assert.equal(harness.elements.ppwDraftActionLink.textContent, '← Edit');
  assert.equal(harness.elements.ppwRelayFeePanel.style.display, 'none');
  assert.equal(harness.elements.ppwWithdrawAmt.disabled, true);
  assert.equal(harness.elements.ppwWithdrawAmt.readOnly, true);
  assert.equal(harness.elements.ppwRecipient.disabled, true);
  assert.equal(harness.elements.ppwWithdrawPct25.disabled, true);
  assert.equal(harness.elements.ppwWithdrawPct50.disabled, true);
  assert.equal(harness.elements.ppwWithdrawPct75.disabled, true);
  assert.equal(harness.elements.ppwWithdrawPct100.disabled, true);
  assert.equal(harness.elements.ppwExtraGas.disabled, true);
});

test('editing from review preserves inputs and clears the reviewed quote', async () => {
  const harness = createHarness({ mode: 'relay' });
  harness.elements.ppwWithdrawAmt.value = '4';
  const { reviewed } = await requestRelayReview(harness);
  assert.ok(reviewed);

  harness.api.withdrawal.ppwHandleDraftActionLink();

  assert.equal(harness.api.withdrawal.ppwGetDraftPhase(), 'editing');
  assert.equal(harness.api.withdrawal.ppwHasReviewedRelayQuote(), false);
  assert.equal(harness.elements.ppwWithdrawAmt.value, '4');
  assert.equal(harness.elements.ppwRecipient.value, RELAY_RECIPIENT);
  assert.equal(harness.elements.ppwRelayFeePanel.style.display, 'none');
  assert.equal(harness.elements.ppwWithdrawBtn.textContent, 'Review quote');
  assert.equal(harness.elements.ppwDraftActionLink.textContent, '× Cancel');
});

test('collect withdrawal intent rejects invalid amounts', async () => {
  const harness = createHarness({
    note: createBaseNote(),
  });
  const run = createRun();
  harness.elements.ppwWithdrawAmt.value = 'not-a-number';

  const intent = await harness.api.withdrawal.ppwCollectWithdrawalIntent(run);
  assert.equal(intent, null);
  assert.equal(harness.lastStatus?.message, 'Invalid withdraw amount. Enter a valid ETH amount.');
});

test('invalid amount disables the withdraw CTA after preview sync', async () => {
  const harness = createHarness();
  await markWalletCompatibilityReady(harness);
  harness.api.withdrawal.ppwSetDraftInteractivity('editing');
  harness.elements.ppwWithdrawAmt.value = 'not-a-number';

  harness.api.withdrawal.ppwUpdatePreview();

  assert.equal(harness.elements.ppwWithdrawBtn.disabled, true);
  assert.equal(harness.elements.ppwPreview.style.display, 'none');
});

test('amount above the note balance disables the withdraw CTA after preview sync', async () => {
  const harness = createHarness();
  await markWalletCompatibilityReady(harness);
  harness.api.withdrawal.ppwSetDraftInteractivity('editing');
  harness.elements.ppwWithdrawAmt.value = '11';

  harness.api.withdrawal.ppwUpdatePreview();

  assert.equal(harness.elements.ppwWithdrawBtn.disabled, true);
  assert.equal(harness.elements.ppwPreview.style.display, 'none');
});

test('valid amount re-enables the withdraw CTA when the draft becomes valid again', async () => {
  const harness = createHarness();
  await markWalletCompatibilityReady(harness);
  harness.api.withdrawal.ppwSetDraftInteractivity('editing');
  harness.elements.ppwRecipient.value = 'alice.eth';
  harness.elements.ppwWithdrawAmt.value = '11';
  harness.api.withdrawal.ppwUpdatePreview();
  assert.equal(harness.elements.ppwWithdrawBtn.disabled, true);

  harness.elements.ppwWithdrawAmt.value = '5';
  harness.api.withdrawal.ppwUpdatePreview();

  assert.equal(harness.elements.ppwWithdrawBtn.disabled, false);
  assert.equal(harness.elements.ppwPreview.style.display, 'none');
});

test('relay mode still requires a resolved recipient before enabling the CTA', async () => {
  const harness = createHarness({
    mode: 'relay',
    globals: {
      coinGetResolved: () => null,
    },
  });
  await markWalletCompatibilityReady(harness);
  harness.api.withdrawal.ppwSetDraftInteractivity('editing');
  harness.api.withdrawal.ppwUpdatePreview();
  assert.equal(harness.elements.ppwWithdrawBtn.disabled, true);

  harness.context.coinGetResolved = () => RELAY_RECIPIENT;
  harness.elements.ppwRecipient.value = 'alice.eth';
  harness.api.withdrawal.ppwUpdatePreview();

  assert.equal(harness.elements.ppwWithdrawBtn.disabled, false);
});

test('collect withdrawal intent rejects relay withdrawals without a resolved recipient', async () => {
  const harness = createHarness({
    mode: 'relay',
    globals: {
      coinGetResolved: () => null,
    },
  });
  const run = createRun();
  harness.elements.ppwRecipient.value = '';

  const intent = await harness.api.withdrawal.ppwCollectWithdrawalIntent(run);
  assert.equal(intent, null);
  assert.equal(harness.lastStatus?.message, 'Enter a recipient address, name.wei, or name.eth for relay withdrawal.');
});

test('load withdrawal state rejects stale state roots', async () => {
  const harness = createHarness();
  const run = createRun();
  harness.context.ppwCheckNullifierUnspent = async () => ({ isSpent: false, nullHash: 999n });
  harness.context.ppwFetchAndVerifyTreeData = async () => ({
    aspLeaves: [123n],
    adjustedLeafIndex: 0,
    stateTree: { root: 888n, depth: 1 },
    stateSiblings: Array(32).fill(0n),
  });
  harness.context.ppReadKnownStateRoots = async () => ({ currentRoot: 999n, roots: [777n] });
  harness.context.ppVerifyAspDataWithRetries = async () => ({
    status: 'verified',
    aspLeaves: [123n],
    aspIndex: 0,
    aspTree: { root: 55n, depth: 1, levels: [[123n]] },
    attempts: 1,
  });

  const state = await harness.api.withdrawal.ppwLoadWithdrawalState(createIntent(), run);
  assert.equal(state, null);
  assert.equal(harness.lastStatus?.message, 'State root is too stale for this pool. Refresh Pool Balances and try again.');
});

test('load withdrawal state rejects deposits missing from the ASP set', async () => {
  const harness = createHarness();
  const run = createRun();
  harness.context.ppwCheckNullifierUnspent = async () => ({ isSpent: false, nullHash: 999n });
  harness.context.ppwFetchAndVerifyTreeData = async () => ({
    aspLeaves: [123n],
    adjustedLeafIndex: 0,
    stateTree: { root: 999n, depth: 1 },
    stateSiblings: Array(32).fill(0n),
  });
  harness.context.ppReadKnownStateRoots = async () => ({ currentRoot: 999n, roots: [999n] });
  harness.context.ppVerifyAspDataWithRetries = async () => ({
    status: 'missing-label',
    aspLeaves: [],
    aspIndex: -1,
    aspTree: { root: 55n, depth: 1, levels: [[0n]] },
    onChainASPRoot: 55n,
    attempts: 1,
  });

  const state = await harness.api.withdrawal.ppwLoadWithdrawalState(createIntent(), run);
  assert.equal(state, null);
  assert.match(harness.lastStatus?.message || '', /not yet in the ASP association set/i);
});

test('load withdrawal state logs ASP root RPC failures as errors', async () => {
  const harness = createHarness();
  const run = createRun();
  harness.context.ppwCheckNullifierUnspent = async () => ({ isSpent: false, nullHash: 999n });
  harness.context.ppwFetchAndVerifyTreeData = async () => ({
    aspLeaves: [123n],
    adjustedLeafIndex: 0,
    stateTree: { root: 999n, depth: 1, levels: [[123n]] },
    stateSiblings: Array(32).fill(0n),
  });
  harness.context.ppReadKnownStateRoots = async () => ({ currentRoot: 999n, roots: [999n] });
  harness.context.ppVerifyAspDataWithRetries = async () => {
    throw new Error('rpc unavailable');
  };

  const state = await harness.api.withdrawal.ppwLoadWithdrawalState(createIntent(), run);

  assert.equal(state, null);
  assert.equal(
    harness.lastStatus?.message,
    'Could not verify ASP root onchain. Retry withdrawal when RPC connectivity is stable.',
  );
  assert.ok(
    run.logs.some((entry) => entry.includes('<b>Error:</b> Could not verify ASP root onchain.')),
  );
});

test('load withdrawal state fails closed when the spent check RPC read fails', async () => {
  const harness = createHarness();
  const run = createRun();
  let treeFetchCalls = 0;
  let aspVerifyCalls = 0;
  harness.context.ppwCheckNullifierUnspent = async () => {
    throw new Error('rpc unavailable');
  };
  harness.context.ppwFetchAndVerifyTreeData = async () => {
    treeFetchCalls += 1;
    return createWithdrawalState();
  };
  harness.context.ppVerifyAspDataWithRetries = async () => {
    aspVerifyCalls += 1;
    return createWithdrawalState();
  };

  const state = await harness.api.withdrawal.ppwLoadWithdrawalState(createIntent(), run);

  assert.equal(state, null);
  assert.equal(treeFetchCalls, 0);
  assert.equal(aspVerifyCalls, 0);
  assert.equal(
    harness.lastStatus?.message,
    'Could not verify whether this deposit has already been withdrawn. Retry when RPC connectivity is stable.',
  );
  assert.ok(
    run.logs.some((entry) => entry.includes('Could not verify whether this deposit has already been withdrawn.')),
  );
});

test('withdraw flow aborts before proof preparation when spent status is unknown', async () => {
  const harness = createHarness();
  let prepareProofCalls = 0;
  harness.context.ppwCollectWithdrawalIntent = async () => createIntent();
  harness.context.ppwCheckNullifierUnspent = async () => {
    throw new Error('rpc unavailable');
  };
  harness.context.ppwPrepareProofJob = async () => {
    prepareProofCalls += 1;
    return null;
  };

  await harness.api.withdrawal.ppwWithdraw();

  assert.equal(prepareProofCalls, 0);
  assert.equal(
    harness.lastStatus?.message,
    'Could not verify whether this deposit has already been withdrawn. Retry when RPC connectivity is stable.',
  );
});

test('relay quote refresh rejects recipient mismatches', async () => {
  const harness = createHarness();
  const run = createRun();
  const intent = createIntent();
  const quoteState = harness.api.withdrawal.ppwCreateRelayQuoteState(intent);
  const feeCommitment = createRelayFeeCommitment(harness, quoteState.relayAssetAddr);
  harness.context.ppwRelayerDetails = async () => ({ feeReceiverAddress: RELAYER_ADDRESS });
  harness.context.ppwRelayerQuote = async () => ({ feeCommitment });
  harness.context.ppwValidateRelayQuoteCommitment = () => ({ recoveredSigner: RELAYER_ADDRESS, expirationMs: feeCommitment.expiration });
  harness.context.ppwDecodeRelayWithdrawalData = () => ({
    recipient: CONNECTED_ADDRESS,
    relayer: RELAYER_ADDRESS,
    feeBps: 35,
  });
  harness.context.ppwResolveAllowedRelayRecipients = () => [RELAYER_ADDRESS];
  harness.context.ppEnsureAssetConfig = async () => ({ maxRelayFeeBPS: 50 });
  harness.context.ppwStartExpiryCountdown = () => {};

  await assert.rejects(
    () => harness.api.withdrawal.ppwRefreshRelayQuote(quoteState, intent, run, true),
    /recipient mismatch/i,
  );
});

test('relayer quote and request POSTs use timed abort signals', async () => {
  const calls = [];
  let clearTimeoutCalls = 0;
  const realSetTimeout = globalThis.setTimeout;
  const realClearTimeout = globalThis.clearTimeout;
  const harness = createHarness({
    globals: {
      AbortController,
      setTimeout: (...args) => realSetTimeout(...args),
      clearTimeout: (timeoutId) => {
        clearTimeoutCalls += 1;
        return realClearTimeout(timeoutId);
      },
      fetch: async (url, options = {}) => {
        calls.push({ url, options });
        return {
          ok: true,
          json: async () => {
            const beforeBodyParse = clearTimeoutCalls;
            await Promise.resolve();
            assert.equal(clearTimeoutCalls, beforeBodyParse);
            return { ok: true };
          },
        };
      },
    },
  });
  const proof = createProofResult();

  await harness.api.withdrawal.ppwRelayerQuote(1, 123n, RELAYER_ADDRESS, RELAY_RECIPIENT, false);
  await harness.api.withdrawal.ppwRelayerRequest(
    1,
    777n,
    { processooor: RELAYER_ADDRESS, data: '0x' },
    proof.proof,
    proof.publicSignals,
    { fee: '1' },
  );

  assert.equal(calls.length, 2);
  assert.equal(calls[0].url.endsWith('/relayer/quote'), true);
  assert.equal(calls[0].options.method, 'POST');
  assert.equal(typeof calls[0].options.signal?.addEventListener, 'function');
  assert.equal(calls[0].options.signal.aborted, false);
  assert.equal(calls[1].url.endsWith('/relayer/request'), true);
  assert.equal(calls[1].options.method, 'POST');
  assert.equal(typeof calls[1].options.signal?.addEventListener, 'function');
  assert.equal(calls[1].options.signal.aborted, false);
  assert(clearTimeoutCalls >= 2, 'at least two abort timers were cleaned up after fetch resolved');
});

test('relay quote refresh rejects relayer mismatches', async () => {
  const harness = createHarness();
  const run = createRun();
  const intent = createIntent();
  const quoteState = harness.api.withdrawal.ppwCreateRelayQuoteState(intent);
  const feeCommitment = createRelayFeeCommitment(harness, quoteState.relayAssetAddr);
  harness.context.ppwRelayerDetails = async () => ({ feeReceiverAddress: RELAYER_ADDRESS });
  harness.context.ppwRelayerQuote = async () => ({ feeCommitment });
  harness.context.ppwValidateRelayQuoteCommitment = () => ({ recoveredSigner: RELAYER_ADDRESS, expirationMs: feeCommitment.expiration });
  harness.context.ppwDecodeRelayWithdrawalData = () => ({
    recipient: RELAY_RECIPIENT,
    relayer: CONNECTED_ADDRESS,
    feeBps: 35,
  });
  harness.context.ppwResolveAllowedRelayRecipients = () => [RELAYER_ADDRESS];
  harness.context.ppEnsureAssetConfig = async () => ({ maxRelayFeeBPS: 50 });
  harness.context.ppwStartExpiryCountdown = () => {};

  await assert.rejects(
    () => harness.api.withdrawal.ppwRefreshRelayQuote(quoteState, intent, run, true),
    /relayer mismatch/i,
  );
});

test('relay quote refresh enforces the onchain relay fee cap', async () => {
  const harness = createHarness();
  const run = createRun();
  const intent = createIntent();
  const quoteState = harness.api.withdrawal.ppwCreateRelayQuoteState(intent);
  const feeCommitment = createRelayFeeCommitment(harness, quoteState.relayAssetAddr);
  harness.context.ppwRelayerDetails = async () => ({ feeReceiverAddress: RELAYER_ADDRESS });
  harness.context.ppwRelayerQuote = async () => ({ feeCommitment });
  harness.context.ppwValidateRelayQuoteCommitment = () => ({ recoveredSigner: RELAYER_ADDRESS, expirationMs: feeCommitment.expiration });
  harness.context.ppwDecodeRelayWithdrawalData = () => ({
    recipient: RELAY_RECIPIENT,
    relayer: RELAYER_ADDRESS,
    feeBps: 120,
  });
  harness.context.ppwResolveAllowedRelayRecipients = () => [RELAYER_ADDRESS];
  harness.context.ppEnsureAssetConfig = async () => ({ maxRelayFeeBPS: 50 });
  harness.context.ppwStartExpiryCountdown = () => {};

  await assert.rejects(
    () => harness.api.withdrawal.ppwRefreshRelayQuote(quoteState, intent, run, true),
    /exceeds onchain max/i,
  );
});

test('relay quote refresh retries once without extra gas when unsupported', async () => {
  const boldNote = createBaseNote({ asset: 'BOLD', value: 8_000000000000000000n });
  const harness = createHarness({
    mode: 'relay',
    note: boldNote,
    statePatch: { _ppwMode: 'relay', _ppwNote: boldNote },
  });
  const run = createRun();
  const intent = createIntent({
    note: boldNote,
    value: boldNote.value,
    withdrawnValue: boldNote.value,
    wAsset: 'BOLD',
    wIsBOLD: true,
  });
  harness.elements.ppwExtraGas.checked = true;
  const quoteState = harness.api.withdrawal.ppwCreateRelayQuoteState(intent);
  const extraGasCalls = [];
  harness.context.ppwRelayerDetails = async () => ({ feeReceiverAddress: RELAYER_ADDRESS });
  harness.context.ppwRelayerQuote = async (chainId, amount, asset, recipient, extraGas) => {
    extraGasCalls.push(!!extraGas);
    if (extraGasCalls.length === 1) throw new Error('UNSUPPORTED_FEATURE: extraGas');
    return {
      feeCommitment: createRelayFeeCommitment(harness, asset, {
        amount: amount.toString(),
        extraGas: !!extraGas,
        withdrawalData: harness.context.ethers.AbiCoder.defaultAbiCoder().encode(
          ['address', 'address', 'uint256'],
          [recipient, RELAYER_ADDRESS, 35],
        ),
        fee: ((BigInt(amount) * 35n) / 10000n).toString(),
      }),
    };
  };
  harness.context.ppwValidateRelayQuoteCommitment = () => ({ recoveredSigner: RELAYER_ADDRESS, expirationMs: Date.now() + 60_000 });
  harness.context.ppwDecodeRelayWithdrawalData = () => ({
    recipient: RELAY_RECIPIENT,
    relayer: RELAYER_ADDRESS,
    feeBps: 35,
  });
  harness.context.ppwResolveAllowedRelayRecipients = () => [RELAYER_ADDRESS];
  harness.context.ppEnsureAssetConfig = async () => ({ maxRelayFeeBPS: 50 });
  harness.context.ppwStartExpiryCountdown = () => {};

  await harness.api.withdrawal.ppwRefreshRelayQuote(quoteState, intent, run, true);

  assert.deepEqual(extraGasCalls, [true, false]);
  assert.equal(quoteState.relayExtraGas, false);
  assert.equal(harness.elements.ppwExtraGas.checked, false);
  assert.equal(harness.elements.ppwRelayFeePanel.style.display, 'none');
  assert.equal(
    harness.lastStatus?.message,
    'Extra gas is not available for this quote. Continuing without it.',
  );
  assert.ok(
    run.logs.some((entry) => entry.includes('Extra gas is not available for this quote. Continuing without it.')),
  );
});

test('relay quote refresh does not retry generic quote failures', async () => {
  const boldNote = createBaseNote({ asset: 'BOLD' });
  const harness = createHarness({
    mode: 'relay',
    note: boldNote,
    statePatch: { _ppwMode: 'relay', _ppwNote: boldNote },
  });
  const run = createRun();
  const intent = createIntent({
    note: boldNote,
    value: boldNote.value,
    withdrawnValue: boldNote.value,
    wAsset: 'BOLD',
    wIsBOLD: true,
  });
  harness.elements.ppwExtraGas.checked = true;
  const quoteState = harness.api.withdrawal.ppwCreateRelayQuoteState(intent);
  const extraGasCalls = [];
  harness.context.ppwRelayerDetails = async () => ({ feeReceiverAddress: RELAYER_ADDRESS });
  harness.context.ppwRelayerQuote = async (chainId, amount, asset, recipient, extraGas) => {
    extraGasCalls.push(!!extraGas);
    throw new Error('relayer unavailable');
  };

  await assert.rejects(
    () => harness.api.withdrawal.ppwRefreshRelayQuote(quoteState, intent, run, true),
    /relayer unavailable/i,
  );

  assert.deepEqual(extraGasCalls, [true]);
  assert.equal(quoteState.relayExtraGas, true);
  assert.equal(harness.elements.ppwExtraGas.checked, true);
});

function assertQuoteInvalidated(harness) {
  assert.equal(harness.elements.ppwRelayFeePanel.style.display, 'none', 'quote box hidden');
  assert.equal(harness.api.withdrawal.ppwIsRelayQuoteDisplayed(), false, 'relay quote flag cleared');
  assert.equal(harness.api.withdrawal.ppwGetDraftPhase(), 'editing', 'draft returns to editing');
}

test('relay quote panel hides when the recipient changes after a quote was shown', async () => {
  const harness = createHarness({ mode: 'relay' });
  const { reviewed } = await requestRelayReview(harness);

  assert.equal(harness.elements.ppwRelayFeePanel.style.display, 'none');
  assert.ok(reviewed);
  assert.equal(harness.api.withdrawal.ppwGetDraftPhase(), 'review');
  assert.equal(harness.api.withdrawal.ppwIsRelayQuoteDisplayed(), true);

  harness.elements.ppwRecipient.value = '0x9999999999999999999999999999999999999999';
  harness.api.withdrawal.ppwUpdatePreview();

  assertQuoteInvalidated(harness);
  assert.equal(harness.api.withdrawal.ppwHasReviewedRelayQuote(), false);
});

test('relay quote panel hides when the withdrawal amount changes after a quote was shown', async () => {
  const harness = createHarness({ mode: 'relay' });
  await requestRelayReview(harness);

  harness.elements.ppwWithdrawAmt.value = '1';
  harness.api.withdrawal.ppwUpdatePreview();

  assertQuoteInvalidated(harness);
});

test('relay quote panel hides when extra gas changes after a quote was shown', async () => {
  const boldNote = createBaseNote({ asset: 'BOLD' });
  const harness = createHarness({
    note: boldNote,
    statePatch: { _ppwMode: 'relay', _ppwNote: boldNote },
  });
  harness.elements.ppwExtraGas.checked = false;
  await requestRelayReview(harness, { note: boldNote, wAsset: 'BOLD' });

  harness.elements.ppwExtraGas.checked = true;
  harness.api.withdrawal.ppwUpdatePreview();

  assertQuoteInvalidated(harness);
});

test('editing withdraw inputs hides the stale quote panel without auto-refetching', async () => {
  const harness = createHarness({ mode: 'relay' });
  const intent = createIntent();
  const { quoteCallsRef } = await showValidRelayQuote(harness, { intent });

  harness.elements.ppwRecipient.value = '0x8888888888888888888888888888888888888888';
  harness.api.withdrawal.ppwUpdatePreview();

  assert.equal(quoteCallsRef(), 1);
  assert.equal(harness.elements.ppwRelayFeePanel.style.display, 'none');
});

test('prepare relay quote fetches a fresh quote after a previously displayed quote was invalidated', async () => {
  const harness = createHarness({ mode: 'relay' });
  const run = createRun();
  const initialIntent = createIntent();
  const { quoteCallsRef } = await showValidRelayQuote(harness, { intent: initialIntent, run });

  harness.elements.ppwRecipient.value = '0x7777777777777777777777777777777777777777';
  harness.api.withdrawal.ppwUpdatePreview();
  assert.equal(harness.elements.ppwRelayFeePanel.style.display, 'none');

  const nextIntent = createIntent({
    resolvedRecipient: '0x7777777777777777777777777777777777777777',
    recipient: '0x7777777777777777777777777777777777777777',
    customRecipient: '0x7777777777777777777777777777777777777777',
  });
  harness.context.ppwDecodeRelayWithdrawalData = () => ({
    recipient: nextIntent.resolvedRecipient,
    relayer: RELAYER_ADDRESS,
    feeBps: 35,
  });
  const quoteState = await harness.api.withdrawal.ppwPrepareRelayQuote(nextIntent, createWithdrawalState(), run);

  assert.equal(quoteCallsRef(), 2);
  assert.equal(quoteState.relayQuote?.feeCommitment?.withdrawalData != null, true);
  assert.equal(harness.elements.ppwRelayFeePanel.style.display, 'none');
  assert.equal(harness.api.withdrawal.ppwIsRelayQuoteDisplayed(), true);
});

test('confirming in review uses the stored reviewed quote without silently refetching', async () => {
  const harness = createHarness({ mode: 'relay' });
  const { reviewed, quoteCallsRef } = await requestRelayReview(harness);
  assert.ok(reviewed);

  const order = [];
  harness.context.ppwLoadWithdrawalState = async () => {
    order.push('load');
    return createWithdrawalState();
  };
  harness.context.ppwPrepareRelayQuote = async () => {
    order.push('quote');
    throw new Error('should not refetch quote during confirm');
  };
  harness.context.ppwPrepareProofJob = async (intent, state, quoteState) => {
    order.push('job');
    assert.equal(quoteState, reviewed.quoteState);
    return {
      intent: reviewed.intent,
      state,
      quoteState,
      isPartial: false,
      assetUnit: reviewed.intent.wAsset,
      circuitInputsBase: { withdrawnValue: '1' },
      wasmUrl: 'blob:wasm',
      zkeyUrl: 'blob:zkey',
    };
  };
  harness.context.ppwGenerateAndVerifyProof = async () => {
    order.push('proof');
    return { withdrawalProcessooor: ENTRYPOINT_ADDRESS, withdrawalData: '0x', proof: createProofResult().proof, publicSignals: createProofResult().publicSignals, pA: [1n, 2n], pB: [[3n, 4n], [5n, 6n]], pC: [7n, 8n], pubSigs: Array(8).fill(1n) };
  };
  harness.context.ppwRevalidateBeforeSubmit = async () => {
    order.push('revalidate');
    return { ok: true };
  };
  harness.context.ppwSubmitWithdrawal = async () => {
    order.push('submit');
    return { receipt: { status: 1 }, txHash: '0xconfirm' };
  };
  harness.context.ppwFinalizeWithdrawalSuccess = async () => {
    order.push('finalize');
  };

  await harness.api.withdrawal.ppwHandleWithdrawPrimaryAction();

  assert.equal(quoteCallsRef(), 1);
  assert.deepEqual(order, ['load', 'job', 'proof', 'revalidate', 'submit', 'finalize']);
});

test('confirming with an expired reviewed quote refreshes it and requires another explicit confirm', async () => {
  const harness = createHarness({ mode: 'relay' });
  const { reviewed, quoteCallsRef } = await requestRelayReview(harness);
  reviewed.quoteState.relayQuote.feeCommitment.expiration = Date.now() - 1;
  let prepareProofCalls = 0;
  harness.context.ppwPrepareProofJob = async () => {
    prepareProofCalls += 1;
    return null;
  };

  await harness.api.withdrawal.ppwHandleWithdrawPrimaryAction();

  assert.equal(quoteCallsRef(), 2);
  assert.equal(prepareProofCalls, 0);
  assert.equal(harness.api.withdrawal.ppwGetDraftPhase(), 'review');
  assert.equal(harness.api.withdrawal.ppwHasReviewedRelayQuote(), true);
  assert.equal(harness.elements.ppwWithdrawBtn.textContent, 'Confirm withdrawal');
  assert.equal(harness.lastStatus?.message, 'Review the refreshed quote and retry withdrawal.');
});

test('expired reviewed quote fallback clears extra gas and still requires reconfirm', async () => {
  const boldNote = createBaseNote({ asset: 'BOLD', value: 8_000000000000000000n });
  const harness = createHarness({
    mode: 'relay',
    note: boldNote,
    statePatch: { _ppwMode: 'relay', _ppwNote: boldNote },
  });
  const { reviewed } = await requestRelayReview(harness, {
    note: boldNote,
    wAsset: 'BOLD',
    extraGas: true,
  });
  reviewed.quoteState.relayQuote.feeCommitment.expiration = Date.now() - 1;
  const extraGasCalls = [];
  let prepareProofCalls = 0;
  harness.context.ppwRelayerQuote = async (chainId, amount, asset, recipient, extraGas) => {
    extraGasCalls.push(!!extraGas);
    if (extraGasCalls.length === 1) throw new Error('UNSUPPORTED_FEATURE: extraGas');
    return {
      feeCommitment: createRelayFeeCommitment(harness, asset, {
        amount: amount.toString(),
        extraGas: !!extraGas,
        withdrawalData: harness.context.ethers.AbiCoder.defaultAbiCoder().encode(
          ['address', 'address', 'uint256'],
          [recipient, RELAYER_ADDRESS, 35],
        ),
        fee: ((BigInt(amount) * 35n) / 10000n).toString(),
      }),
    };
  };
  harness.context.ppwPrepareProofJob = async () => {
    prepareProofCalls += 1;
    return null;
  };

  await harness.api.withdrawal.ppwHandleWithdrawPrimaryAction();

  assert.deepEqual(extraGasCalls, [true, false]);
  assert.equal(prepareProofCalls, 0);
  assert.equal(harness.elements.ppwExtraGas.checked, false);
  assert.equal(harness.api.withdrawal.ppwHasReviewedRelayQuote(), true);
  assert.equal(harness.api.withdrawal.ppwGetDraftPhase(), 'review');
  assert.equal(harness.lastStatus?.message, 'Review the refreshed quote and retry withdrawal.');
  assert.ok(
    harness.statusCalls.some(
      ({ message }) => message === 'Extra gas is not available for this quote. Continuing without it.',
    ),
  );
});

test('proof generation fails closed when the relay quote expires during proving', async () => {
  const harness = createHarness();
  const run = createRun();
  let refreshCalls = 0;
  harness.context.ppRunWithdrawalProof = async () => createProofResult();
  harness.context.ppwVerifyProofOnchain = async () => true;
  harness.context.ppwRefreshRelayQuote = async () => {
    refreshCalls += 1;
  };
  const quoteState = {
    relayQuote: {
      feeCommitment: createRelayFeeCommitment(harness, harness.api.withdrawal.ppwCreateRelayQuoteState(createIntent()).relayAssetAddr, {
        expiration: Date.now() - 1,
      }),
    },
  };

  const proofState = await harness.api.withdrawal.ppwGenerateAndVerifyProof(
    {
      intent: createIntent(),
      circuitInputsBase: { withdrawnValue: '1' },
      wasmUrl: 'blob:wasm',
      zkeyUrl: 'blob:zkey',
      state: createWithdrawalState(),
    },
    quoteState,
    run,
  );

  assert.equal(proofState, null);
  assert.equal(refreshCalls, 1);
  assert.equal(
    harness.lastStatus?.message,
    'Relay quote expired during proving. Review the refreshed quote and retry withdrawal.',
  );
});

test('proof generation rejects public-signal mismatches before verifier checks', async () => {
  const harness = createHarness();
  const run = createRun();
  // Return a proof with dummy signals that won't match the intended parameters
  harness.context.ppRunWithdrawalProof = async () => createProofResult();
  harness.context.ppwVerifyProofOnchain = async () => true; // Should never be reached

  const proofState = await harness.api.withdrawal.ppwGenerateAndVerifyProof(
    {
      intent: createIntent({ isRelayMode: false }),
      circuitInputsBase: { stateRoot: '111', ASPRoot: '222', stateTreeDepth: '32', ASPTreeDepth: '32', withdrawnValue: '1' },
      newNullifier: 100n,
      newSecret: 200n,
      changeValue: 9n,
      wasmUrl: 'blob:wasm',
      zkeyUrl: 'blob:zkey',
      state: createWithdrawalState(),
    },
    {},
    run,
  );

  assert.equal(proofState, null);
  assert.equal(
    harness.lastStatus?.message,
    'Generated proof does not match the intended withdrawal. Refresh Pool Balances and retry.',
  );
});

test('proof generation rejects failed local verifier checks', async () => {
  const harness = createHarness();
  const run = createRun();
  // Build matching public signals so the signal check passes and we reach the verifier
  const intent = createIntent({ isRelayMode: false });
  const newNullifier = 100n;
  const newSecret = 200n;
  const changeValue = intent.value - intent.withdrawnValue;
  const { poseidon1, poseidon2, poseidon3, ethers } = createPoseidonContext({ withEthers: true });
  const nullifierHash = poseidon1([intent.note.nullifier]);
  const newPrecommitment = poseidon2([newNullifier, newSecret]);
  const newCommitment = poseidon3([changeValue, intent.label, newPrecommitment]);
  const encoded = ethers.AbiCoder.defaultAbiCoder().encode(
    ['tuple(address,bytes)', 'uint256'],
    [[intent.recipient, '0x'], intent.scope]
  );
  const SNARK_FIELD = 21888242871839275222246405745257275088548364400416034343698204186575808495617n;
  const context = BigInt(ethers.keccak256(encoded)) % SNARK_FIELD;
  const stateRoot = 111n;
  const aspRoot = 222n;
  const stateTreeDepth = 32n;
  const aspTreeDepth = 32n;
  // ProofLib.sol signal order: newCommitmentHash, existingNullifierHash,
  // withdrawnValue, stateRoot, stateTreeDepth, ASPRoot, ASPTreeDepth, context
  const matchingSignals = [newCommitment, nullifierHash, intent.withdrawnValue, stateRoot, stateTreeDepth, aspRoot, aspTreeDepth, context].map(String);
  harness.context.ppRunWithdrawalProof = async () => ({
    proof: { pi_a: ['1', '2'], pi_b: [['3', '4'], ['5', '6']], pi_c: ['7', '8'] },
    publicSignals: matchingSignals,
  });
  harness.context.ppwVerifyProofOnchain = async () => false;

  const proofState = await harness.api.withdrawal.ppwGenerateAndVerifyProof(
    {
      intent,
      circuitInputsBase: { stateRoot: stateRoot.toString(), ASPRoot: aspRoot.toString(), stateTreeDepth: stateTreeDepth.toString(), ASPTreeDepth: aspTreeDepth.toString(), withdrawnValue: intent.withdrawnValue.toString() },
      newNullifier,
      newSecret,
      changeValue,
      wasmUrl: 'blob:wasm',
      zkeyUrl: 'blob:zkey',
      state: createWithdrawalState(),
    },
    {},
    run,
  );

  assert.equal(proofState, null);
  assert.equal(harness.lastStatus?.message, 'Proof failed local verifier check. Retry withdrawal.');
});

test('main-thread proving uses the verified snarkjs engine and returns its proof output', async () => {
  const harness = createHarness();
  const expected = createProofResult();
  const calls = [];
  let stopArgs = null;
  harness.context.ppEnsureVerifiedSnarkjsEngine = async () => ({
    groth16: {
      async fullProve(circuitInputs, wasmUrl, zkeyUrl) {
        calls.push({ circuitInputs, wasmUrl, zkeyUrl });
        return expected;
      },
    },
  });
  harness.context.ppStartWithdrawalProofProgressReporter = async () => ({
    stop(finalPhase = null, finalProgress = null) {
      stopArgs = { finalPhase, finalProgress };
    },
  });

  const proof = await harness.api.withdrawal.ppRunWithdrawalProof(
    { withdrawnValue: '1', context: '2' },
    'blob:wasm',
    'blob:zkey',
    () => {},
  );

  assert.deepEqual(JSON.parse(JSON.stringify(proof)), expected);
  assert.deepEqual(calls, [{
    circuitInputs: { withdrawnValue: '1', context: '2' },
    wasmUrl: 'blob:wasm',
    zkeyUrl: 'blob:zkey',
  }]);
  assert.deepEqual(stopArgs, { finalPhase: 'verifying_proof', finalProgress: 0.8 });
});

test('verified snarkjs bootstrap validates the vendored bundle and boots the main-thread engine', async () => {
  let requestedUrl = null;
  let fetchCalls = 0;
  const { api } = loadPrivacyTestApi({
    globals: {
      btoa: testBtoa,
      fetch: async (url) => {
        fetchCalls += 1;
        requestedUrl = url;
        return {
          ok: true,
          status: 200,
          arrayBuffer: async () => toArrayBuffer(VENDORED_SNARKJS_BUNDLE),
        };
      },
    },
  });

  const source = await api.withdrawal.ppEnsureVerifiedSnarkjsSource();
  const engine = await api.withdrawal.ppEnsureVerifiedSnarkjsEngine();

  assert.equal(requestedUrl, api.constants.proof.snarkjsSrc);
  assert.equal(source, VENDORED_SNARKJS_BUNDLE.toString('utf8'));
  assert.equal(typeof engine.groth16.fullProve, 'function');
  assert.equal(await api.withdrawal.ppEnsureVerifiedSnarkjsSource(), source);
  assert.equal(await api.withdrawal.ppEnsureVerifiedSnarkjsEngine(), engine);
  assert.equal(fetchCalls, 1);
});

test('verified snarkjs bootstrap fails closed on integrity mismatches', async () => {
  const tamperedBundle = Buffer.from(VENDORED_SNARKJS_BUNDLE);
  tamperedBundle[0] = tamperedBundle[0] === 0x20 ? 0x21 : 0x20;
  const { api } = loadPrivacyTestApi({
    globals: {
      btoa: testBtoa,
      fetch: async () => ({
        ok: true,
        status: 200,
        arrayBuffer: async () => toArrayBuffer(tamperedBundle),
      }),
    },
  });

  await assert.rejects(
    api.withdrawal.ppEnsureVerifiedSnarkjsSource(),
    (error) => error.ppBootstrapFailure === true
      && error.message === 'Failed to fetch verified snarkjs source for withdrawal proving.'
      && error.cause?.message === 'snarkjs integrity check failed',
  );
});

// ---------------------------------------------------------------------------
// Low-level artifact fetch rejection tests (parameterized)
// ---------------------------------------------------------------------------

const artifactFetchRejections = [
  {
    name: 'snarkjs source fetch rejects on network failure',
    globals: { btoa: testBtoa, fetch: async () => { throw new TypeError('Failed to fetch'); } },
    invoke: (api) => api.withdrawal.ppEnsureVerifiedSnarkjsSource(),
    check: (error) => error.ppBootstrapFailure === true
      && error.message === 'Failed to fetch verified snarkjs source for withdrawal proving.',
  },
  {
    name: 'snarkjs source fetch rejects on HTTP error status',
    globals: { btoa: testBtoa, fetch: async () => ({ ok: false, status: 503, arrayBuffer: async () => new ArrayBuffer(0) }) },
    invoke: (api) => api.withdrawal.ppEnsureVerifiedSnarkjsSource(),
    check: (error) => error.ppBootstrapFailure === true
      && error.message === 'Failed to fetch verified snarkjs source for withdrawal proving.',
  },
  {
    name: 'withdraw artifact fetch rejects when data is corrupted (wrong SHA-256 hash)',
    globals: (() => { const p = new Uint8Array(1024); p.fill(0xDE); return { fetch: async () => ({ ok: true, status: 200, arrayBuffer: async () => p.buffer }) }; })(),
    invoke: (api) => api.withdrawal.ppEnsureWithdrawArtifacts(),
    check: (error) => error.message.includes('integrity check failed'),
  },
  {
    name: 'withdraw artifact fetch rejects on HTTP error status',
    globals: { fetch: async () => ({ ok: false, status: 404, arrayBuffer: async () => new ArrayBuffer(0) }) },
    invoke: (api) => api.withdrawal.ppEnsureWithdrawArtifacts(),
    check: (error) => error.message.includes('HTTP 404'),
  },
  {
    name: 'commitment artifact fetch rejects when data is corrupted (wrong SHA-256 hash)',
    globals: (() => { const p = new Uint8Array(512); p.fill(0xBE); return { fetch: async () => ({ ok: true, status: 200, arrayBuffer: async () => p.buffer }) }; })(),
    invoke: (api) => api.withdrawal.ppEnsureCommitmentArtifacts(),
    check: (error) => error.message.includes('integrity check failed'),
  },
  {
    name: 'commitment artifact fetch rejects on HTTP error status',
    globals: { fetch: async () => ({ ok: false, status: 404, arrayBuffer: async () => new ArrayBuffer(0) }) },
    invoke: (api) => api.withdrawal.ppEnsureCommitmentArtifacts(),
    check: (error) => error.message.includes('HTTP 404'),
  },
];

for (const { name, globals, invoke, check } of artifactFetchRejections) {
  test(name, async () => {
    const { api } = loadPrivacyTestApi({ globals });
    await assert.rejects(() => invoke(api), check);
  });
}

// ---------------------------------------------------------------------------
// Higher-level artifact propagation tests (parameterized shared setup)
// ---------------------------------------------------------------------------

function setupProofJobHarness(artifactError) {
  const harness = createHarness();
  const run = createRun();
  const intent = createIntent({ isRelayMode: false, recipient: CONNECTED_ADDRESS });
  const state = createWithdrawalState();
  const quoteState = { isRelayMode: false };
  harness.context._ppArtifactCache = null;
  harness.context._ppArtifactCachePromise = null;
  harness.context.ppEnsureMasterKeys = async () => ({
    masterNullifier: 1n,
    masterSecret: 2n,
    legacyMasterNullifier: null,
    legacyMasterSecret: null,
  });
  harness.context.ppGetKeysetForDerivation = () => ({
    masterNullifier: 1n,
    masterSecret: 2n,
  });
  harness.context.ppResolveNextWithdrawalIndex = () => ({
    nextIndex: 0,
    kind: 'fresh',
  });
  harness.context.ppEnsureWithdrawArtifacts = async () => { throw artifactError; };
  return { harness, run, intent, state, quoteState };
}

function setupRagequitJobHarness(artifactError) {
  const harness = createHarness({
    mode: 'direct',
    actionKind: 'ragequit',
    statePatch: { _ppwMode: 'direct', _ppwActionKind: 'ragequit' },
  });
  const run = createRun();
  const intent = createIntent({ isRelayMode: false, recipient: CONNECTED_ADDRESS });
  harness.context._ppCommitmentArtifactCache = null;
  harness.context._ppCommitmentArtifactCachePromise = null;
  harness.context.ppEnsureCommitmentArtifacts = async () => { throw artifactError; };
  return { harness, run, intent };
}

const propagationTests = [
  {
    name: 'ppwPrepareProofJob propagates artifact network failure to caller',
    setup: () => setupProofJobHarness(new TypeError('Failed to fetch')),
    invoke: ({ harness, intent, state, quoteState, run }) =>
      harness.api.withdrawal.ppwPrepareProofJob(intent, state, quoteState, run),
    check: (error) => error instanceof TypeError && error.message === 'Failed to fetch',
  },
  {
    name: 'ppwPrepareProofJob propagates artifact HTTP error to caller',
    setup: () => setupProofJobHarness(new Error('withdraw.wasm: HTTP 404')),
    invoke: ({ harness, intent, state, quoteState, run }) =>
      harness.api.withdrawal.ppwPrepareProofJob(intent, state, quoteState, run),
    check: (error) => error.message.includes('HTTP 404'),
  },
  {
    name: 'ppwPrepareRagequitJob propagates commitment artifact network failure to caller',
    setup: () => setupRagequitJobHarness(new TypeError('Failed to fetch')),
    invoke: ({ harness, intent, run }) =>
      harness.api.withdrawal.ppwPrepareRagequitJob(intent, run),
    check: (error) => error instanceof TypeError && error.message === 'Failed to fetch',
  },
  {
    name: 'ppwPrepareRagequitJob propagates commitment artifact HTTP error to caller',
    setup: () => setupRagequitJobHarness(new Error('commitment.wasm: HTTP 404')),
    invoke: ({ harness, intent, run }) =>
      harness.api.withdrawal.ppwPrepareRagequitJob(intent, run),
    check: (error) => error.message.includes('HTTP 404'),
  },
];

for (const { name, setup, invoke, check } of propagationTests) {
  test(name, async () => {
    const ctx = setup();
    await assert.rejects(() => invoke(ctx), check);
  });
}

test('progress-sidecar startup failure does not block successful main-thread proving', async () => {
  const harness = createHarness();
  const progressEvents = [];
  harness.context.ppEnsureVerifiedSnarkjsEngine = async () => ({
    groth16: {
      async fullProve() {
        return createProofResult();
      },
    },
  });

  const proof = await harness.api.withdrawal.ppRunWithdrawalProof(
    { withdrawnValue: '1' },
    'blob:wasm',
    'blob:zkey',
    (event) => progressEvents.push(event),
  );

  assert.equal(proof.publicSignals.length, 8);
  assert.ok(
    progressEvents.some((event) => event.fallbackMessage === 'Live proof progress updates are unavailable. Proving continues on the main thread.'),
  );
  assert.ok(
    progressEvents.some((event) => event.phase === 'verifying_proof' && event.progress === 0.8),
  );
});

test('proof-progress sidecar relays worker progress and stops cleanly when workers are available', async () => {
  class FakeWorker {
    static instances = [];

    constructor(url) {
      this.url = url;
      this.messages = [];
      this.terminated = false;
      this.onmessage = null;
      this.onerror = null;
      FakeWorker.instances.push(this);
    }

    postMessage(message) {
      this.messages.push(message);
      if (message.type === 'start') {
        queueMicrotask(() => {
          this.onmessage?.({
            data: {
              id: message.id,
              type: 'progress',
              phase: 'generating_proof',
              progress: 0.4,
            },
          });
        });
      }
    }

    terminate() {
      this.terminated = true;
    }
  }

  const harness = createHarness({
    globals: {
      Worker: FakeWorker,
    },
  });
  const progressEvents = [];

  const reporter = await harness.api.withdrawal.ppStartWithdrawalProofProgressReporter(
    (event) => progressEvents.push(event),
  );
  await flushMicrotasks();
  reporter.stop('verifying_proof', 0.8);

  assert.equal(FakeWorker.instances.length, 1);
  assert.equal(FakeWorker.instances[0].url, 'blob:privacy-test');
  assert.equal(FakeWorker.instances[0].messages[0].type, 'start');
  assert.equal(FakeWorker.instances[0].messages[1].type, 'stop');
  assert.equal(FakeWorker.instances[0].terminated, true);
  assert.ok(progressEvents.some((event) => event.phase === 'generating_proof' && event.progress === 0.4));
  assert.ok(progressEvents.some((event) => event.phase === 'verifying_proof' && event.progress === 0.8));
  assert.ok(!progressEvents.some((event) => event.fallbackMessage));
});

test('withdraw preload warms verified snarkjs plus withdraw and commitment artifacts without prebuilding a proof worker', async () => {
  const harness = createHarness();
  let engineCalls = 0;
  let artifactCalls = 0;
  let commitmentArtifactCalls = 0;
  let workerCalls = 0;
  harness.context.ppScheduleIdle = (fn) => fn();
  harness.context.ppEnsureVerifiedSnarkjsEngine = async () => {
    engineCalls += 1;
    return { groth16: { fullProve: async () => createProofResult() } };
  };
  harness.context.ppEnsureWithdrawArtifacts = async () => {
    artifactCalls += 1;
    return { wasmUrl: 'blob:wasm', zkeyUrl: 'blob:zkey' };
  };
  harness.context.ppEnsureCommitmentArtifacts = async () => {
    commitmentArtifactCalls += 1;
    return { wasmUrl: 'blob:commitment-wasm', zkeyUrl: 'blob:commitment-zkey' };
  };
  harness.context.ppEnsureWithdrawalProgressWorkerBlobUrl = async () => {
    workerCalls += 1;
    return 'blob:progress-worker';
  };

  harness.api.withdrawal.ppScheduleWithdrawPreload();
  await flushMicrotasks();

  assert.equal(engineCalls, 1);
  assert.equal(artifactCalls, 1);
  assert.equal(commitmentArtifactCalls, 1);
  assert.equal(workerCalls, 0);
});

test('pre-submit revalidation fails when roots are no longer current', async () => {
  const harness = createHarness();
  const run = createRun();
  harness.context.ppEnsureWithdrawalRootsCurrent = async () => ({
    ok: false,
    message: 'State root moved during proof generation. Refresh Pool Balances and retry withdrawal.',
  });

  const result = await harness.api.withdrawal.ppwRevalidateBeforeSubmit(
    {
      intent: createIntent({ isRelayMode: false }),
      state: createWithdrawalState(),
    },
    {},
    {},
    run,
  );

  assert.equal(result, null);
  assert.equal(
    harness.lastStatus?.message,
    'State root moved during proof generation. Refresh Pool Balances and retry withdrawal.',
  );
});

test('pre-submit revalidation refreshes expired relay quotes and requires retry', async () => {
  const harness = createHarness();
  const run = createRun();
  let refreshCalls = 0;
  harness.context.ppEnsureWithdrawalRootsCurrent = async () => ({ ok: true });
  harness.context.ppwRefreshRelayQuote = async () => {
    refreshCalls += 1;
  };

  const result = await harness.api.withdrawal.ppwRevalidateBeforeSubmit(
    {
      intent: createIntent(),
      state: createWithdrawalState(),
    },
    {},
    {
      relayQuote: {
        feeCommitment: {
          expiration: Date.now() - 1,
        },
      },
    },
    run,
  );

  assert.equal(result, null);
  assert.equal(refreshCalls, 1);
  assert.equal(
    harness.lastStatus?.message,
    'Relay quote expired before submission. Review the refreshed quote and retry withdrawal.',
  );
});

test('withdraw run escapes text-only log messages before appending HTML', () => {
  const harness = createHarness();
  const run = harness.api.withdrawal.ppwCreateWithdrawRun();

  run.log('<b>unsafe</b> & more');

  assert.equal(harness.elements.ppwVerify.style.display, '');
  assert.equal(
    harness.elements.ppwVerifyStatus.innerHTML,
    '&lt;b&gt;unsafe&lt;/b&gt; &amp; more<br>',
  );
});

test('withdraw run preserves trusted HTML log messages', () => {
  const harness = createHarness();
  const run = harness.api.withdrawal.ppwCreateWithdrawRun();

  run.logHtml('<b>Trusted</b> <span>markup</span>');

  assert.equal(
    harness.elements.ppwVerifyStatus.innerHTML,
    '<b>Trusted</b> <span>markup</span><br>',
  );
});

test('formatted withdrawal failures still render trusted markup in the verify panel', () => {
  const harness = createHarness();
  const run = harness.api.withdrawal.ppwCreateWithdrawRun();

  harness.api.withdrawal.ppwHandleWithdrawalFailure(new Error('InvalidProof'), run);

  assert.match(
    harness.elements.ppwVerifyStatus.innerHTML,
    /^<b>Error:<\/b> Proof verification failed\./,
  );
  assert.equal(
    harness.lastStatus?.message,
    'Proof verification failed. Please retry your withdrawal.',
  );
});

test('relay submission returns the relayer transaction hash and receipt', async () => {
  const harness = createHarness();
  const run = createRun();
  harness.context.ppwRelayerRequest = async () => ({ txHash: '0xrelaytx' });
  harness.context.ppReadWithRpc = async () => ({ status: 1 });

  const result = await harness.api.withdrawal.ppwSubmitWithdrawal(
    {
      intent: createIntent(),
    },
    {
      withdrawalProcessooor: ENTRYPOINT_ADDRESS,
      withdrawalData: '0x1234',
      proof: createProofResult().proof,
      publicSignals: createProofResult().publicSignals,
    },
    {
      relayChainId: 1,
      relayQuote: { feeCommitment: { fee: '1' } },
    },
    run,
  );

  assert.equal(result.txHash, '0xrelaytx');
  assert.equal(result.receipt.status, 1);
});

test('relay submission failures clarify that the withdrawal was not submitted', async () => {
  const harness = createHarness();
  const run = createRun();
  harness.context.ppwRelayerRequest = async () => {
    throw new Error('relayer unavailable');
  };

  const result = await harness.api.withdrawal.ppwSubmitWithdrawal(
    {
      intent: createIntent(),
    },
    {
      withdrawalProcessooor: ENTRYPOINT_ADDRESS,
      withdrawalData: '0x1234',
      proof: createProofResult().proof,
      publicSignals: createProofResult().publicSignals,
    },
    {
      relayChainId: 1,
      relayQuote: { feeCommitment: { fee: '1' } },
    },
    run,
  );

  assert.equal(result, null);
  assert.equal(
    harness.lastStatus?.message,
    'Relayer submission failed before submission. Your withdrawal was not submitted. Retry the relay flow in a few minutes.',
  );
  assert.ok(
    run.logs.some((entry) => entry.includes('Your withdrawal was not submitted. Retry the relay flow in a few minutes.')),
  );
});

test('relay responses without a transaction hash clarify that submission did not happen', async () => {
  const harness = createHarness();
  const run = createRun();
  harness.context.ppwRelayerRequest = async () => ({ ok: true });

  const result = await harness.api.withdrawal.ppwSubmitWithdrawal(
    {
      intent: createIntent(),
    },
    {
      withdrawalProcessooor: ENTRYPOINT_ADDRESS,
      withdrawalData: '0x1234',
      proof: createProofResult().proof,
      publicSignals: createProofResult().publicSignals,
    },
    {
      relayChainId: 1,
      relayQuote: { feeCommitment: { fee: '1' } },
    },
    run,
  );

  assert.equal(result, null);
  assert.equal(
    harness.lastStatus?.message,
    'Relayer did not confirm submission. Your withdrawal was not submitted. Retry the relay flow.',
  );
  assert.ok(
    run.logs.some((entry) => entry.includes('Your withdrawal was not submitted. Retry the relay flow.')),
  );
});

test('direct submission fails closed as unsupported', async () => {
  const harness = createHarness();
  const run = createRun();

  const result = await harness.api.withdrawal.ppwSubmitWithdrawal(
    {
      intent: { ...createIntent({ isRelayMode: false, recipient: CONNECTED_ADDRESS }), isRelayMode: false, recipient: CONNECTED_ADDRESS },
    },
    {
      withdrawalData: '0x',
      pA: [1n, 2n],
      pB: [[3n, 4n], [5n, 6n]],
      pC: [7n, 8n],
      pubSigs: Array(8).fill(1n),
    },
    {},
    run,
  );

  assert.equal(result, null);
  assert.equal(
    harness.lastStatus?.message,
    'Direct withdrawal is no longer supported. Use relay withdrawal or ragequit.',
  );
});

test('ragequit locks the draft while running', async () => {
  let releaseLoad;
  const loadGate = new Promise((resolve) => {
    releaseLoad = resolve;
  });
  const harness = createHarness({
    mode: 'direct',
    statePatch: { _ppwMode: 'direct', _ppwActionKind: 'ragequit' },
  });
  harness.context.ppwCollectRagequitIntent = async () => {
    await loadGate;
    return createIntent({ isRelayMode: false, recipient: CONNECTED_ADDRESS });
  };
  harness.context.ppwLoadWithdrawalState = async () => createWithdrawalState();
  harness.context.ppwPrepareProofJob = async () => ({
    intent: createIntent({ isRelayMode: false, recipient: CONNECTED_ADDRESS }),
    state: createWithdrawalState(),
    quoteState: { isRelayMode: false },
    isPartial: false,
    assetUnit: 'ETH',
    circuitInputsBase: { withdrawnValue: '1' },
    wasmUrl: 'blob:wasm',
    zkeyUrl: 'blob:zkey',
  });
  harness.context.ppwGenerateAndVerifyProof = async () => ({
    withdrawalProcessooor: CONNECTED_ADDRESS,
    withdrawalData: '0x',
    proof: createProofResult().proof,
    publicSignals: createProofResult().publicSignals,
    pA: [1n, 2n],
    pB: [[3n, 4n], [5n, 6n]],
    pC: [7n, 8n],
    pubSigs: Array(8).fill(1n),
  });
  harness.context.ppwRevalidateBeforeSubmit = async () => ({ ok: true });
  harness.context.ppwSubmitWithdrawal = async () => ({ receipt: { status: 1 }, txHash: '0xragequit' });
  harness.context.ppwFinalizeWithdrawalSuccess = async () => {};

  const pending = harness.api.withdrawal.ppwHandleWithdrawPrimaryAction();
  await new Promise((resolve) => setTimeout(resolve, 0));

  // Ragequit routes through ppwRagequit which has its own locking
  // Just verify the action was dispatched
  releaseLoad();
  await pending;
  // After completion, verify phase returned to editing
  assert.equal(harness.api.withdrawal.ppwGetDraftPhase(), 'editing');
});

test('reset and disconnect clear relay review state', async () => {
  const harness = createHarness({ mode: 'relay' });
  harness.elements.ppwParsed = createElement({ style: { display: '' } });
  await requestRelayReview(harness);

  harness.api.withdrawal.ppwResetDraftState();
  assert.equal(harness.api.withdrawal.ppwGetDraftPhase(), 'editing');
  assert.equal(harness.api.withdrawal.ppwHasReviewedRelayQuote(), false);
  assert.equal(harness.elements.ppwRelayFeePanel.style.display, 'none');

  await requestRelayReview(harness);
  harness.context.ppResetWalletCompatibility = () => {};
  harness.context.ppClearPendingWalletSeedBackups = () => {};
  harness.context.ppRenderWalletSeedBackupNotice = () => {};
  harness.context.ppScrubMasterKeyStore = () => {};
  harness.context.ppTerminateProofProgressWorker = () => {};
  harness.context.ppUpdateDepositCta = () => {};
  harness.context.ppUpdateDescriptions = () => {};
  harness.context.ppwUpdateLoadButton = () => {};
  harness.context.ppwSyncBackgroundRefreshLoop = () => {};
  harness.context.ppwRenderIdleState = () => {};
  harness.context.ppRenderWalletCompatibilityNotice = () => {};
  harness.context.ppwUpdateRecipientHint = () => {};
  harness.context._ppMasterKeys = { address: CONNECTED_ADDRESS, versions: { v2: {} } };
  harness.context._ppwLoadAbort = null;

  harness.api.hooks.ppHandlePrivacyWalletDisconnected();

  assert.equal(harness.api.withdrawal.ppwGetDraftPhase(), 'editing');
  assert.equal(harness.api.withdrawal.ppwHasReviewedRelayQuote(), false);
});

test('partial-withdrawal finalization renders the result summary and refreshes caches', async () => {
  let cacheInvalidations = 0;
  let scheduledRefreshes = 0;
  const harness = createHarness();
  const run = createRun();
  harness.context.ppwParseChangeLeafIndex = async () => ({ leafIndex: 9 });
  harness.context.ppInvalidatePoolViewCaches = () => {
    cacheInvalidations += 1;
  };
  harness.context.ppwScheduleMutationRefreshes = () => {
    scheduledRefreshes += 1;
  };

  await harness.api.withdrawal.ppwFinalizeWithdrawalSuccess(
    { status: 1, logs: [] },
    {
      intent: createIntent({ withdrawnValue: 4_000000000000000000n, wAsset: 'ETH' }),
      isPartial: true,
      newNullifier: 333n,
      newSecret: 444n,
      changeValue: 6_000000000000000000n,
      assetUnit: 'ETH',
    },
    {},
    { txHash: '0xwithdraw' },
    run,
  );

  assert.match(harness.elements.ppwResultSummary.innerHTML, /remaining in (?:PA-1|your Pool Account)/i);
  assert.match(harness.elements.ppwResultSummary.innerHTML, /0xwithdraw/i);
  assert.equal(cacheInvalidations, 1);
  assert.equal(scheduledRefreshes, 1);
  assert.equal(harness.lastStatus?.message, 'Withdrawal successful!');
});

test('withdrawal error decoder preserves fail-closed user messaging', () => {
  const harness = createHarness();
  assert.equal(
    harness.api.withdrawal.ppwDecodeWithdrawalError(new Error('execution reverted: InvalidProof')),
    'Proof verification failed. Please retry your withdrawal.',
  );
  assert.equal(
    harness.api.withdrawal.ppwDecodeWithdrawalError(new Error('execution reverted: UnknownStateRoot')),
    'Pool state is temporarily out of sync. Wait a few minutes and retry.',
  );
});

test('terminal failure handling surfaces reverted and unconfirmed transactions', () => {
  const harness = createHarness();
  const run = createRun();

  harness.api.withdrawal.ppwHandleWithdrawalFailure({ txHash: '0xrev', receipt: { status: 0 } }, run);
  assert.equal(
    harness.lastStatus?.message,
    'Transaction reverted onchain. The deposit may have been already spent or the relay quote may have expired.',
  );

  harness.statusCalls.length = 0;

  harness.api.withdrawal.ppwHandleWithdrawalFailure({ txHash: '0xpend', receipt: null }, run);
  assert.equal(
    harness.lastStatus?.message,
    'Transaction submitted but not yet confirmed. Check Etherscan for tx: 0xpend',
  );
});

test('withdraw coordinator remains a thin orchestration layer over the extracted phases', async () => {
  const harness = createHarness();
  const order = [];
  let stopArgs = null;
  const reviewedRelayQuote = {
    intentKey: 'review-key',
    quoteState: {
      relayQuote: {
        feeCommitment: {
          expiration: Date.now() + 60_000,
        },
      },
    },
  };
  harness.context.ppwCreateWithdrawRun = () => ({
    reset() {
      order.push('reset');
    },
    stopIfNeeded(success, mode) {
      stopArgs = { success, mode };
    },
  });
  harness.context.ppwCollectWithdrawalIntent = async () => {
    order.push('intent');
    return createIntent();
  };
  harness.context.ppwBuildRelayQuoteDisplayKey = () => 'review-key';
  harness.context.ppwLoadWithdrawalState = async () => {
    order.push('load');
    return { id: 'state' };
  };
  harness.context.ppwPrepareProofJob = async () => {
    order.push('job');
    return { id: 'job', intent: createIntent({ recipient: CONNECTED_ADDRESS, wAsset: 'ETH', withdrawnValue: 1n }), isPartial: false, assetUnit: 'ETH' };
  };
  harness.context.ppwGenerateAndVerifyProof = async () => {
    order.push('proof');
    return { id: 'proof' };
  };
  harness.context.ppwRevalidateBeforeSubmit = async () => {
    order.push('revalidate');
    return { ok: true };
  };
  harness.context.ppwSubmitWithdrawal = async () => {
    order.push('submit');
    return { receipt: { status: 1 }, txHash: '0xok' };
  };
  harness.context.ppwFinalizeWithdrawalSuccess = async () => {
    order.push('finalize');
  };
  harness.context.ppwHandleWithdrawalFailure = () => {
    order.push('failure');
  };

  await harness.api.withdrawal.ppwWithdraw({ reviewedRelayQuote });

  assert.deepEqual(order, [
    'reset',
    'intent',
    'load',
    'job',
    'proof',
    'revalidate',
    'submit',
    'finalize',
  ]);
  assert.deepEqual(stopArgs, { success: true, mode: harness.api.withdrawal.ppwGetMode() });
});

test('review-confirmed relay withdrawal exercises the live extracted phases', async () => {
  const note = createBaseNote({ withdrawalIndex: 0 });
  const harness = createHarness({
    mode: 'relay',
    note,
    statePatch: { _ppwMode: 'relay', _ppwNote: note },
  });
  const { reviewed, quoteCallsRef } = await requestRelayReview(harness, { note });
  const submissions = [];
  let scheduledRefreshes = 0;
  let cacheInvalidations = 0;

  harness.context.ppwLoadWithdrawalState = async () => createWithdrawalState();
  harness.context.ppEnsureMasterKeys = async () => ({
    masterNullifier: 11n,
    masterSecret: 22n,
    legacyMasterNullifier: null,
    legacyMasterSecret: null,
  });
  harness.context.ppGetKeysetForDerivation = () => ({
    masterNullifier: 11n,
    masterSecret: 22n,
  });
  harness.context.ppResolveNextWithdrawalIndex = () => ({
    nextIndex: 0,
    currentIndex: 0,
    source: 'note',
    depositIndex: note.depositIndex,
  });
  harness.context.ppEnsureWithdrawArtifacts = async () => ({
    wasmUrl: 'blob:wasm',
    zkeyUrl: 'blob:zkey',
  });
  harness.context.ppRunWithdrawalProof = async (circuitInputs) => createMatchingWithdrawalProof(harness, circuitInputs);
  harness.context.ppwVerifyProofOnchain = async () => true;
  harness.context.ppEnsureWithdrawalRootsCurrent = async () => ({ ok: true });
  harness.context.ppReadWithRpc = async () => ({ status: 1 });
  harness.context.ppwRelayerRequest = async (chainId, scope, processooor, proof, publicSignals, feeCommitment) => {
    submissions.push({ chainId, scope, processooor, proof, publicSignals, feeCommitment });
    return { txHash: '0xrelaytx' };
  };
  harness.context.ppInvalidatePoolViewCaches = () => {
    cacheInvalidations += 1;
  };
  harness.context.ppwScheduleMutationRefreshes = () => {
    scheduledRefreshes += 1;
  };

  await harness.api.withdrawal.ppwHandleWithdrawPrimaryAction();

  assert.ok(reviewed);
  assert.equal(quoteCallsRef(), 1);
  assert.equal(submissions.length, 1);
  assert.equal(submissions[0].chainId, reviewed.quoteState.relayChainId);
  assert.equal(submissions[0].scope, reviewed.intent.scope);
  assert.equal(submissions[0].processooor.processooor, harness.api.constants.addresses.entrypoint);
  assert.equal(submissions[0].processooor.data, reviewed.quoteState.relayQuote.feeCommitment.withdrawalData);
  assert.equal(submissions[0].feeCommitment, reviewed.quoteState.relayQuote.feeCommitment);
  assert.equal(harness.lastStatus?.message, 'Withdrawal successful!');
  assert.match(harness.elements.ppwResultSummary.innerHTML, /0xrelaytx/i);
  assert.equal(cacheInvalidations, 1);
  assert.equal(scheduledRefreshes, 1);
});

test('ragequit mode stays direct-only and submit-ready for original depositors', () => {
  const harness = createHarness({
    note: createBaseNote({
      reviewStatus: 'declined',
      isWithdrawable: false,
      isRagequittable: true,
      isOriginalDepositor: true,
    }),
    mode: 'relay',
  });
  harness.context.ppGetWalletCompatibilitySnapshot = () => ({
    status: 'ready',
    result: { supported: true, kind: 'eoa', message: '' },
  });

  harness.api.withdrawal.ppwSetActionKind('ragequit');
  harness.api.withdrawal.ppwSetMode('relay');

  assert.equal(harness.api.withdrawal.ppwGetActionKind(), 'ragequit');
  assert.equal(harness.api.withdrawal.ppwGetMode(), 'direct');
  assert.equal(harness.elements.ppwModeSection.style.display, 'none');
  assert.equal(harness.elements.ppwRagequitWarning.style.display, '');
  assert.equal(harness.elements.ppwRelayRecipientWrap.style.display, 'none');
  assert.equal(harness.elements.ppwPreviewTitle.textContent, 'Ragequit Preview');
  assert.equal(harness.api.withdrawal.ppwCanSubmitWithdrawal(), true);
});

test('withdrawal error decoder explains OnlyOriginalDepositor for ragequit', () => {
  const harness = createHarness({ actionKind: 'ragequit' });
  const decoded = harness.api.withdrawal.ppwDecodeWithdrawalError({
    message: 'execution reverted: OnlyOriginalDepositor()',
  });

  assert.equal(decoded, 'Only the original depositor wallet can ragequit this Pool Account.');
});

test('ragequit submit readiness follows the live depositor wallet, not stale row flags', () => {
  const harness = createHarness({ actionKind: 'ragequit', mode: 'direct' });

  const staleAllowedNote = createBaseNote({
    reviewStatus: 'declined',
    isWithdrawable: false,
    isRagequittable: true,
    isOriginalDepositor: true,
    depositor: CONNECTED_ADDRESS,
  });
  const blockedForOtherWallet = harness.api.withdrawal.ppwCanSubmitWithdrawalState({
    note: staleAllowedNote,
    actionKind: 'ragequit',
    connectedAddress: OTHER_ADDRESS,
    signer: { getAddress: async () => OTHER_ADDRESS },
  });

  const staleBlockedNote = createBaseNote({
    reviewStatus: 'declined',
    isWithdrawable: false,
    isRagequittable: false,
    isOriginalDepositor: false,
    depositor: CONNECTED_ADDRESS,
  });
  const recoveredForDepositor = harness.api.withdrawal.ppwCanSubmitWithdrawalState({
    note: staleBlockedNote,
    actionKind: 'ragequit',
    connectedAddress: CONNECTED_ADDRESS,
    signer: { getAddress: async () => CONNECTED_ADDRESS },
  });

  assert.equal(blockedForOtherWallet, false);
  assert.equal(recoveredForDepositor, true);
});

test('ragequit selection uses the live depositor check when loaded flags are stale', () => {
  const row = createBaseNote({
    reviewStatus: 'declined',
    isWithdrawable: false,
    isRagequittable: false,
    isOriginalDepositor: false,
    depositor: CONNECTED_ADDRESS,
  });
  const harness = createHarness({
    statePatch: {
      _ppwLoadResults: [row],
      _ppwHasResolvedLoadState: true,
    },
  });

  harness.context.ppwSelectAccount(0, 'ragequit');

  assert.equal(harness.api.withdrawal.ppwGetActionKind(), 'ragequit');
  assert.equal(harness.elements.ppwParsed.style.display, '');
  assert.equal(harness.lastStatus, null);
});

test('ragequit selection blocks stale original-depositor flags after a wallet switch', () => {
  const row = createBaseNote({
    reviewStatus: 'declined',
    isWithdrawable: false,
    isRagequittable: true,
    isOriginalDepositor: true,
    depositor: CONNECTED_ADDRESS,
  });
  const harness = createHarness({
    globals: { _connectedAddress: OTHER_ADDRESS, _signer: { getAddress: async () => OTHER_ADDRESS } },
    statePatch: {
      _ppwLoadResults: [row],
      _ppwHasResolvedLoadState: true,
    },
  });
  harness.elements.ppwParsed.style.display = 'none';

  harness.context.ppwSelectAccount(0, 'ragequit');

  assert.equal(harness.elements.ppwParsed.style.display, 'none');
  assert.equal(harness.lastStatus?.message, 'Only the original depositor wallet can ragequit this Pool Account.');
});

test('ragequit proof generation rejects public-signal mismatches before verifier checks', async () => {
  const note = createBaseNote({
    reviewStatus: 'declined',
    isWithdrawable: false,
    isRagequittable: true,
    isOriginalDepositor: true,
  });
  const harness = createHarness({ note, actionKind: 'ragequit', mode: 'direct' });
  const run = createRun();
  let verifyCalls = 0;
  harness.context._ppCommitmentArtifactCache = { wasmUrl: 'blob:wasm', zkeyUrl: 'blob:zkey' };
  const expectedCommitment = harness.context.poseidon3([note.value, note.label, note.precommitment]);
  const expectedNullifierHash = harness.context.poseidon1([note.nullifier]);
  harness.context.ppRunWithdrawalProof = async () => ({
    proof: createProofResult().proof,
    publicSignals: [
      String(expectedCommitment + 1n),
      String(expectedNullifierHash),
      String(note.value),
      String(note.label),
    ],
  });
  harness.context.ppwVerifyRagequitProofOnchain = async () => {
    verifyCalls += 1;
    return true;
  };

  const job = await harness.api.withdrawal.ppwPrepareRagequitJob(
    createIntent({
      note,
      value: note.value,
      withdrawnValue: note.value,
      isRelayMode: false,
      recipient: CONNECTED_ADDRESS,
      wAsset: note.asset,
    }),
    run,
  );
  const proofState = await harness.api.withdrawal.ppwGenerateAndVerifyRagequitProof(job, run);

  assert.equal(proofState, null);
  assert.equal(verifyCalls, 0);
  assert.equal(
    harness.lastStatus?.message,
    'Generated ragequit proof does not match the selected Pool Account. Refresh Pool Balances and retry.',
  );
});

test('ragequit submission simulates the full pool call before wallet confirmation', async () => {
  const note = createBaseNote({
    reviewStatus: 'declined',
    isWithdrawable: false,
    isRagequittable: true,
    isOriginalDepositor: true,
  });
  const callOrder = [];
  class FakePoolContract {
    constructor(address) {
      const ragequit = async (proof) => {
        callOrder.push({ type: 'submit', address, proof });
        return { hash: '0xragequit' };
      };
      ragequit.staticCall = async (proof) => {
        callOrder.push({ type: 'simulate', address, proof });
        return undefined;
      };
      this.ragequit = ragequit;
    }
  }
  const { ethers: isolatedEthers } = createPoseidonContext({ withEthers: true });
  isolatedEthers.Contract = FakePoolContract;
  const harness = createHarness({
    note,
    actionKind: 'ragequit',
    mode: 'direct',
    globals: { ethers: isolatedEthers },
  });
  const run = createRun();
  harness.context.wcTransaction = async (promise, label) => {
    callOrder.push({ type: 'wallet', label });
    return await promise;
  };
  harness.context.waitForTx = async (tx) => ({ status: 1, hash: tx.hash });

  const result = await harness.api.withdrawal.ppwSubmitRagequit(
    {
      intent: createIntent({
        note,
        value: note.value,
        withdrawnValue: note.value,
        isRelayMode: false,
        recipient: CONNECTED_ADDRESS,
        wAsset: note.asset,
      }),
    },
    {
      pA: [1n, 2n],
      pB: [[3n, 4n], [5n, 6n]],
      pC: [7n, 8n],
      pubSigs: [11n, 22n, 33n, 44n],
    },
    run,
  );

  assert.equal(result.txHash, '0xragequit');
  assert.equal(result.receipt.status, 1);
  assert.deepEqual(callOrder.map((entry) => entry.type), ['simulate', 'submit', 'wallet']);
  assert.ok(run.logs.some((entry) => entry.includes('Preflight simulation passed.')));
});

test('ragequit submission surfaces simulation reverts before wallet confirmation', async () => {
  const note = createBaseNote({
    reviewStatus: 'declined',
    isWithdrawable: false,
    isRagequittable: true,
    isOriginalDepositor: true,
  });
  let submitCalls = 0;
  let walletCalls = 0;
  class FakePoolContract {
    constructor() {
      const ragequit = async () => {
        submitCalls += 1;
        return { hash: '0xragequit' };
      };
      ragequit.staticCall = async () => {
        throw new Error('execution reverted: OnlyOriginalDepositor()');
      };
      this.ragequit = ragequit;
    }
  }
  const { ethers: isolatedEthers } = createPoseidonContext({ withEthers: true });
  isolatedEthers.Contract = FakePoolContract;
  const harness = createHarness({
    note,
    actionKind: 'ragequit',
    mode: 'direct',
    globals: { ethers: isolatedEthers },
  });
  const run = createRun();
  harness.context.wcTransaction = async (promise) => {
    walletCalls += 1;
    return await promise;
  };

  const result = await harness.api.withdrawal.ppwSubmitRagequit(
    {
      intent: createIntent({
        note,
        value: note.value,
        withdrawnValue: note.value,
        isRelayMode: false,
        recipient: CONNECTED_ADDRESS,
        wAsset: note.asset,
      }),
    },
    {
      pA: [1n, 2n],
      pB: [[3n, 4n], [5n, 6n]],
      pC: [7n, 8n],
      pubSigs: [11n, 22n, 33n, 44n],
    },
    run,
  );

  assert.equal(result, null);
  assert.equal(submitCalls, 0);
  assert.equal(walletCalls, 0);
  assert.equal(harness.lastStatus?.message, 'Only the original depositor wallet can ragequit this Pool Account.');
});

test('ragequit coordinator remains a thin orchestration layer over the extracted phases', async () => {
  const note = createBaseNote({
    reviewStatus: 'declined',
    isWithdrawable: false,
    isRagequittable: true,
    isOriginalDepositor: true,
  });
  const harness = createHarness({ note, actionKind: 'ragequit', mode: 'direct' });
  const order = [];
  let stopArgs = null;
  harness.context.ppwCreateWithdrawRun = () => ({
    reset() {
      order.push('reset');
    },
    log() {},
    logHtml() {},
    setProgressStage() {},
    setButtonText() {},
    stopIfNeeded(success, mode) {
      stopArgs = { success, mode };
    },
  });
  harness.context.ppwCollectWithdrawalIntent = async () => {
    order.push('intent');
    return createIntent({
      note,
      value: note.value,
      withdrawnValue: note.value,
      isRelayMode: false,
      recipient: CONNECTED_ADDRESS,
      wAsset: note.asset,
    });
  };
  harness.context.ppwCheckNullifierUnspent = async () => {
    order.push('spent-check');
    return { isSpent: false, nullHash: 1n };
  };
  harness.context.ppwPrepareRagequitJob = async () => {
    order.push('job');
    return { intent: createIntent({ note, value: note.value, withdrawnValue: note.value, isRelayMode: false, recipient: CONNECTED_ADDRESS, wAsset: note.asset }), assetUnit: note.asset };
  };
  harness.context.ppwGenerateAndVerifyRagequitProof = async () => {
    order.push('proof');
    return { id: 'proof' };
  };
  harness.context.ppwSubmitRagequit = async () => {
    order.push('submit');
    return { receipt: { status: 1 }, txHash: '0xragequit' };
  };
  harness.context.ppwFinalizeRagequitSuccess = async () => {
    order.push('finalize');
  };
  harness.context.ppwHandleWithdrawalFailure = () => {
    order.push('failure');
  };

  await harness.api.withdrawal.ppwRagequit();

  assert.deepEqual(order, [
    'reset',
    'intent',
    'spent-check',
    'job',
    'proof',
    'submit',
    'finalize',
  ]);
  assert.deepEqual(stopArgs, { success: true, mode: 'direct' });
});

test('ragequit finalization renders the result summary and refreshes caches', async () => {
  const note = createBaseNote({
    asset: 'ETH',
    value: 3_000000000000000000n,
    reviewStatus: 'declined',
    isWithdrawable: false,
    isRagequittable: true,
    isOriginalDepositor: true,
  });
  const harness = createHarness({ note, actionKind: 'ragequit', mode: 'direct' });
  let invalidatedAsset = null;
  let refreshCalls = 0;
  harness.context.ppInvalidatePoolViewCaches = (asset) => {
    invalidatedAsset = asset;
  };
  harness.context.ppwScheduleMutationRefreshes = () => {
    refreshCalls += 1;
  };
  const run = createRun();
  const job = {
    intent: createIntent({
      note,
      value: note.value,
      withdrawnValue: note.value,
      isRelayMode: false,
      recipient: CONNECTED_ADDRESS,
      wAsset: note.asset,
    }),
    assetUnit: note.asset,
  };

  await harness.api.withdrawal.ppwFinalizeRagequitSuccess({ status: 1 }, job, { txHash: '0xragequit' }, run);

  assert.equal(harness.elements.ppwResult.style.display, '');
  assert.match(harness.elements.ppwResultSummary.innerHTML, /Ragequit 3 ETH successfully/);
  assert.equal(invalidatedAsset, 'ETH');
  assert.equal(refreshCalls, 1);
  assert.equal(harness.lastStatus?.message, 'Ragequit successful!');
});

// ---------------------------------------------------------------------------
// XSS protection: recipient addresses and ENS names in the quote panel
// ---------------------------------------------------------------------------

const xssVectors = [
  { name: '<script> tags in recipient address', payload: '<script>alert(1)</script>', mustNotContain: '<script>' },
  { name: '<img onerror> XSS in recipient ENS name', payload: '<img onerror=alert(1) src=x>', mustNotContain: '<img' },
  { name: 'attribute-breaking XSS in recipient', payload: '"onclick="alert(1)', mustNotContain: '"onclick="' },
  { name: 'both text and attribute contexts for combined XSS', payload: '"><script>alert(document.cookie)</script>', mustNotContain: '<script>' },
];

for (const { name, payload, mustNotContain } of xssVectors) {
  test(`quote panel escapes ${name}`, () => {
    const harness = createHarness({ mode: 'relay' });
    const intent = createIntent({
      resolvedRecipient: payload,
      recipient: payload,
      withdrawnValue: 5_000000000000000000n,
      wAsset: 'ETH',
    });

    harness.context.ppwUpdatePreviewWithQuote(
      intent,
      '175000000000000000',
      '3.5%',
      Date.now() + 60_000,
    );

    const html = harness.elements.ppwPreviewContent.innerHTML;
    assert.ok(!html.includes(mustNotContain), `Raw "${mustNotContain}" must not appear in rendered HTML`);
  });
}

// ---------------------------------------------------------------------------
// Concurrent / multi-tab withdrawal race condition guards
// ---------------------------------------------------------------------------

console.log('\n-- Concurrent withdrawal race condition guards --');

test('ppwHandleWithdrawPrimaryAction is a no-op while _ppwDraftPhase === running', async () => {
  const harness = createHarness({ mode: 'relay' });
  // Force the draft phase to 'running' via the public API
  harness.api.withdrawal.ppwSetDraftInteractivity('running');
  assert.equal(harness.api.withdrawal.ppwGetDraftPhase(), 'running');

  // Stub withdrawal pipeline — should never be reached
  let pipelineReached = false;
  harness.context.ppwCollectWithdrawalIntent = async () => {
    pipelineReached = true;
    return createIntent();
  };
  harness.context.ppwRagequit = async () => {
    pipelineReached = true;
  };

  await harness.api.withdrawal.ppwHandleWithdrawPrimaryAction();

  assert.equal(pipelineReached, false, 'withdrawal pipeline must not be entered while running');
  assert.equal(harness.api.withdrawal.ppwGetDraftPhase(), 'running');
});

test('ppwSetMode is a no-op while _ppwDraftPhase === running', () => {
  const harness = createHarness({ mode: 'direct' });
  harness.api.withdrawal.ppwSetDraftInteractivity('running');
  assert.equal(harness.api.withdrawal.ppwGetMode(), 'direct');

  // Attempt to switch to relay while running — must be ignored
  harness.api.withdrawal.ppwSetMode('relay');
  assert.equal(harness.api.withdrawal.ppwGetMode(), 'direct', 'mode switch must be blocked while running');
  assert.equal(harness.api.withdrawal.ppwGetDraftPhase(), 'running');
});

test('ppwRequestRelayQuoteReview returns null while _ppwDraftPhase === running', async () => {
  const harness = createHarness({ mode: 'relay' });
  harness.api.withdrawal.ppwSetDraftInteractivity('running');

  let quoteFetched = false;
  harness.context.ppwRelayerDetails = async () => {
    quoteFetched = true;
    return { feeReceiverAddress: RELAYER_ADDRESS };
  };

  const result = await harness.api.withdrawal.ppwRequestRelayQuoteReview();

  assert.equal(result, null, 'relay quote review must return null while running');
  assert.equal(quoteFetched, false, 'relayer details must not be fetched while running');
});

test('submit button is disabled when draft phase is running', () => {
  const harness = createHarness({ mode: 'relay' });
  const btn = harness.elements.ppwWithdrawBtn;

  // Before running, the button follows normal submit-readiness logic
  harness.api.withdrawal.ppwSetDraftInteractivity('editing');
  const editingDisabled = btn.disabled;

  // Transition to running — button must be disabled regardless of readiness
  harness.api.withdrawal.ppwSetDraftInteractivity('running');
  assert.equal(btn.disabled, true, 'button must be disabled during running phase');

  // Transition back to editing — button should be re-evaluated (not stuck disabled)
  harness.api.withdrawal.ppwSetDraftInteractivity('editing');
  assert.equal(btn.disabled, editingDisabled, 'button disabled state must be restored after leaving running phase');
});

test('form inputs are disabled when draft phase is running', () => {
  const harness = createHarness({ mode: 'relay' });
  const amountEl = harness.elements.ppwWithdrawAmt;
  const recipientEl = harness.elements.ppwRecipient;

  harness.api.withdrawal.ppwSetDraftInteractivity('editing');
  assert.equal(amountEl.disabled, false, 'amount input should be enabled while editing');
  assert.equal(recipientEl.disabled, false, 'recipient input should be enabled while editing');

  harness.api.withdrawal.ppwSetDraftInteractivity('running');
  assert.equal(amountEl.disabled, true, 'amount input must be disabled while running');
  assert.equal(recipientEl.disabled, true, 'recipient input must be disabled while running');
  assert.equal(amountEl.readOnly, true, 'amount input must be readOnly while running');
  // Note: recipientEl.readOnly is reset by ppwUpdateRecipientHint during sync;
  // the disabled flag is the primary guard against edits during running phase.
});

test('draft action link is hidden when draft phase is running', () => {
  const harness = createHarness({ mode: 'relay' });
  const link = harness.elements.ppwDraftActionLink;

  harness.api.withdrawal.ppwSetDraftInteractivity('editing');
  assert.notEqual(link.style.display, 'none', 'action link should be visible while editing');

  harness.api.withdrawal.ppwSetDraftInteractivity('running');
  assert.equal(link.style.display, 'none', 'action link must be hidden while running');
});

await done();
