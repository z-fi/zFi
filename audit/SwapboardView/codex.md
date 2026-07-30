# SwapboardView correctness and integration audit

Date: 2026-07-30

Scope: `src/SwapboardView.sol`, its Swapboard and Dutchboard readers, hybrid
planner, `zSwap.html`, and the Swapboard execution fixtures.

## Executive summary

The lens correctly decodes the original six-field Swapboard and the current
eleven-field extension, filters expired/private/NFT rows for fungible planning,
preserves paging cursors, and converts Dutchboard ERC-20 listings into executable
planner rows. Three correctness/availability defects found during this review
were fixed and covered by regressions.

The contract is deployable under its dedicated 200-run compiler profile. Its
frozen runtime is 24,030 bytes, leaving 546 bytes below EIP-170.

The integration gaps are now closed in source. `zSwap.html` uses bounded,
newest-first lens pages when the deterministic lens address has code, supports
current Swapboard, legacy v1, and Dutchboard rows, and safely falls back to its
old direct reader before deployment. Exact-in and exact-out quotes compose book
fills with a re-quoted AMM remainder for native ETH and ERC-20 inputs. A single
protected `snwap` partitions ordinary/permit-funded routes. Permit2 uses one
outer multicall to checkpoint Swapbol, sweep the exact nonzero book budget from
zRouter into it, execute a zero-input protected book snwap, run the optional AMM
remainder, and finally refund any token input still held by zRouter.

| ID | Severity | Finding | Status |
| --- | --- | --- | --- |
| SBV-01 | Medium | Exact-out overdelivery could make an equal-cost fill report `worthwhile = true` | Fixed |
| SBV-02 | Medium | 256 oversized AON orders could crowd all usable liquidity out of a capped plan | Fixed |
| SBV-03 | Medium | One hostile token metadata method could exhaust or inflate the entire page call | Fixed |
| SBV-04 | Integration | `zSwap.html` bypasses the lens and only scans the newest 40 ids per board | Fixed |
| SBV-05 | Integration | The seven-field Swapboard generation is not decoded | Closed — generation deprecated |
| SBV-06 | Integration | No production adapter consumes `Fill[]` across mixed Swapboard/Dutchboard legs | Fixed |

## Fixed findings

### SBV-01 — Exact-out `worthwhile` used delivered output instead of actual target cost

An exact-out partial fill rounds its payment up. With a coarse base-unit ratio,
paying one input unit can deliver two output units for a one-unit target. The
old predicate normalized the one-unit payment over both delivered units and
reported it cheaper than a one-unit AMM baseline, even though the user spent
exactly the same amount.

The verdict now compares the plan's actual input plus its scored AMM remainder
against `baselineIn`. Once the target is fully covered, this reduces to the
required direct comparison `bookIn < baselineIn`.

Regression:
`test_exactOutOverdeliveryDoesNotMakeAnEqualCostFillWorthwhile`.

### SBV-02 — Oversized all-or-nothing rows could occupy the whole candidate cap

Discovery retains at most 256 candidates before the quadratic matcher runs.
Previously retention was based only on unit rate. A set of newer, better-rate
AON orders, each one larger than the user's entire budget/target, could fill all
256 slots and evict an older partial order that fit and beat the AMM. Planning
then returned no book route even though one was available.

Planning discovery now drops AON rows that cannot fit the current exact-in
budget or exact-out target before applying the 256-row retention cap. The
amount-independent public `candidates()` endpoint remains unfiltered.

Regression:
`test_oversizedAonOrdersCannotCrowdAUsableCandidateOutOfAPlan`.

### SBV-03 — Untrusted metadata could deny service to display endpoints

Any maker chooses both token contracts. High-level `symbol()` and `decimals()`
calls allowed one listed token to consume the outer call's gas or return an
unbounded blob that Solidity would copy before the `try/catch` could help.

Metadata calls now receive 50,000 gas each, copy at most 128 bytes for `symbol`
and 32 bytes for `decimals`, validate ABI shape before decoding, and fall back
to a blank symbol / 18 decimals. Broken presentation metadata no longer hides
otherwise valid order rows.

Regression: `test_hostileMetadataCannotTakeDownTheOrderPage`.

## Closed integration findings

### SBV-04 — zSwap now consumes paged lens reads

The page now calls `getRecentOrdersFrom` for current Swapboard and legacy v1,
and `getRecentDutchListings` for Dutchboard. It validates every ABI offset and
bounded string before using a returned row, walks independent cursors, and uses
the lens-provided bounded metadata. The direct 40-id reader remains only as a
pre-deployment availability fallback.

Deterministic deployment target:
`0x000000B95ee642F1A216ef85b54BF77C127b1F50`.

This is a frozen CREATE2 target, not a claim that the contract is deployed.

### SBV-05 — deprecated intermediate board is explicitly excluded

The supported Swapboards are:

- replacement current
  `0x0000006c0fBc8CBAe822c41C9DC00956D0941e23`;
- legacy v1 `0x000000fF3D7A2d373615141d7489Ca66683DbecF`.

Per the project decision during this audit, the intermediate seven-field
`0x00000000CC...85B831` generation is deprecated. It is absent from the lens
client, from `Swapbol.fillPlan`'s allowed board set, and from the UI constants.
This turns the old ambiguous boolean-decoder concern into an explicit rejected
scope rather than a silent decoding hazard.

### SBV-06 — typed mixed-plan execution is implemented

`Swapbol.fillPlan` accepts the exact ABI shape of `SwapboardView.Fill[]` and
builds settlement calldata internally:

- legacy v1: `fillOrder(id, deadline)`;
- current: `fillOrder(id, deadline, payIn, recipient)`;
- Dutchboard: `fill(id, uint128(getOut), recipient, payIn)`.

Each leg gets an exact, call-scoped allowance that is revoked immediately.
Unknown/deprecated boards, empty plans, zero recipients, insufficient input,
and oversized Dutch takes revert. The router's `snwap` measures aggregate
recipient output. For ordinary and native funding, `fillPlanAndSwap` partitions
the book and AMM budgets inside that single protected call; the Permit2 prepared
sequence uses one outer `zRouter.multicall` to preserve the same atomicity.

`zSwap.html` uses the executor address as the candidate `taker`, so it cannot
quote private orders reserved for the end-user EOA that the proxy would be
unable to fill. It re-quotes the actual remainder for up to two planning rounds
and uses the hybrid only when its expected total beats the pure-AMM quote.

`Swapbol.fillPlanAndSwap` executes the book and zQuoter-built AMM remainder
inside one snwap. This avoids `multicall`'s shared-`msg.value` trap for native
input and refunds unused exact-out input. Native routes explicitly prepare
`deposit(address(0), 0, amount) -> snwap`. EIP-2612 and wallet-batched approval
use direct funding. Permit2 is deliberately book-first: its outer multicall
checkpoints Swapbol, sweeps the exact book budget to it, invokes a zero-input
book-only snwap, then executes the optional AMM calldata and refunds the
remaining maximum input to `refundTo`. This prevents an exact-out AMM from
sweeping or refunding the book allocation before the book executor is funded;
no second wallet pull or retained one-unit dust is required.

Frozen deterministic deployment targets:

- replacement `Swapboard`:
  `0x0000006c0fBc8CBAe822c41C9DC00956D0941e23`;
- `Swapbol`: `0x00000040Ba80f8dc500d10ea6cF889b518592756`;
- `Dutchboard`: `0x000000b87444cAd0beb79545dcaE8b4508d48179`.

Creation code, salts, expected addresses, and SafeSummoner calldata are in
`deploy/`. All three remain **NOT DEPLOYED** in this repository record. The UI
feature-gates each target with `eth_getCode`, so preparing these artifacts does
not falsely assume deployment; vacancy and exact factory simulation must still
be checked at deployment time.

## Verification

- `SwapboardViewV2Test`: 26 passed.
- `SwapboardPlanTest`: 25 passed, including 256 fuzz cases.
- `SwapboardViewDutchTest`: 14 passed.
- `SwapboardScaleTest`: 5 passed.
- The three focused Swapbol suites: 40 passed, including native deposit,
  WETH-quoted and native-quoted Dutch legs, exact-out refunds, Permit2 funding,
  and atomic AMM-failure rollback.
- `zSwapDeployTest`: 7 passed, including payload round-trip and route-builder wiring.
- Final focused offline matrix: 149 passed, 0 failed across 12 suites.
- `forge inspect SwapboardView deployedBytecode`: 24,030-byte runtime
  (24,056-byte creation payload).
- `forge inspect Swapbol deployedBytecode`: 6,877-byte runtime
  (7,412-byte constructor-bound creation payload).
- `forge inspect Dutchboard deployedBytecode`: 12,040-byte runtime
  (12,066-byte creation payload).
- `script/check-zSwap.mjs`: all checks passed; 96,632-byte page across four
  chunks with 1,672 bytes of aggregate EIP-170 headroom.
- `git diff --check`: clean for the reviewed source and tests.

The live legacy-v1 fork decoder was not rerun in the final offline matrix. The
default fork path hit the local Foundry/macOS `system-configuration` proxy
crash during initialization. Its decoder was unchanged by these fixes, but this
environmental failure is recorded as a verification gap rather than a pass.

## Current-tree planner and presentation addendum

The production page now treats planner completeness as a user-visible
property. SwapboardView considers at most 256 candidates and discards
all-or-nothing rows that cannot fit the current exact-in budget or exact-out
target before they can occupy that cap. Its pure matcher compares rate-greedy
execution with plans seeded by one AON row. The in-page planner adds every
single-AON seed and every pair among the first 24 AON candidates, caps the
result at 32 book legs, and re-quotes the actual AMM remainder for up to two
rounds. It is a bounded heuristic, not a proof of the global knapsack optimum.
The UI appends `Planner heuristic/capped` when candidate, leg, or higher-order
AON limits can matter, and separately reports `Book scan capped` when paging
did not exhaust the configured scan.

Dutch rows whose decayed price is zero are valid liquidity rather than a
division error. Exact-in planning can take a complete free remainder without
spending input, while exact-out can take only the required partial amount.
Same-token markets remain rejected.

Metadata has two independent containment layers. The lens gives each
`symbol()` / `decimals()` staticcall a fixed gas budget, copies no more than
128 / 32 bytes, accepts only canonical ABI shape, caps symbols at 64 bytes, and
falls back to blank / 18 on failure. The browser then validates all dynamic ABI
offsets and lengths and removes markup-sensitive characters before composing
the orderbook HTML. A maker-controlled metadata contract cannot allocate an
unbounded response, consume the whole page call, or inject markup through a
symbol.

Native composition is normalized at execution rather than by hiding WETH
rows. Swapboard legs consume WETH, Dutch legs with a native quote consume ETH,
and WETH-quoted Dutch legs consume freshly wrapped per-leg WETH. When the user
requests native output, WETH book proceeds are routed to Swapbol and only the
current call's WETH delta is unwrapped. This lets the same planner compare and
compose ETH and WETH-denominated book liquidity without exposing wrapper
details in the UI.

The final focused matrix passed 26 SwapboardView v2 tests, 14 Dutch-view tests,
and 40 tests across the three Swapbol suites. The addresses and sizes above are
the frozen CREATE2 artifacts; they remain deployment targets, not live-contract
claims.
