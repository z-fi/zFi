# PM

Parimutuel YES/NO markets: one singleton for any collateral (ETH as `address(0)`,
or an ERC20 that holds its units: wstETH, BOLD, tacUSD, ...). Bets mint ERC6909
shares, and the winning side splits the pot pro rata, less a resolver fee fixed
at creation. Two optional per-market taxes are also fixed at creation, and both
stay in the pot:

- `exitBps`: sell shares back before close at par, less the greater of
  `exitBps` and the current late tax. 0 makes bets final.
- `lateBps`: a bet mints fewer shares the later it lands, ramping linearly
  from 0 at creation to `lateBps` at close.

## Addresses

| | |
|---|---|
| deployer | SafeSummoner `0x00000000004473e1f31C8266612e7FD5504e6f2a` |
| PM | `0x0000003b32cDD39bc950e56093df98aF220aB5C5` |
| salt | `0x0000000000000000000000000000000000000000000000000000000000cb5e06` |
| initcode hash | `0xd17fd2a7e6f05f978626c6f0f101c00fc8d89256c1003daaa044691add47cecd` |
| creation / runtime | 15,690 B / 15,664 B |
| compiler | solc 0.8.37, via_ir, optimizer 9,999,999 runs, evm prague |

There are no constructor arguments. `WSTETH`, `ZROUTER`
(`0x000000000000FB114709235f1ccBFfb925F600e4`) and `PERMIT2` are compile-time
constants.

## Build

PM ships from `solc 0.8.37`, which fixes two via-IR codegen bugs on paths PM
uses. The rest of the repo stays on 0.8.36. Only this profile produces the
deployable artifact:

```sh
FOUNDRY_PROFILE=pm forge build src/PM.sol --skip test --skip script
node script/check-create2-artifacts.mjs      # PM pinned to 0.8.37 and 9,999,999 runs
```

A default `forge build` compiles PM with 0.8.36. That is fine for tests, but the
artifact scripts refuse it.

`test/PMDeploy.t.sol` deploys the exact `PM.initcode.bin` through the real
factory on a mainnet fork. It checks the mined address and then runs a
lifecycle on the deployed instance: create a market, stake ETH to wstETH through
zRouter, resolve, claim, and withdraw fees.

## Security model

- **Resolvers are trusted.** A resolver picks the outcome and can void at any
  time. It must resolve within `RESOLVE_WINDOW` (30 days) after close; after
  that, anyone can void. A void splits the pot equally per share (at least par).
  Because early shares carry the late taxes, a resolver who bets early and then
  voids captures those taxes. This is within the trust model.
- **Market ids include the creator,** so nobody can squat or spam another
  address's markets. `getMarketsBy(creator)` lists them.
- **Solvency.** Every share is minted against at least one unit of collateral,
  and an exit pays at most one. So the pot always covers the shares
  outstanding. Taxes round up and payouts round down.
- **Collateral must hold its units.** Markets on the same asset share PM's
  balance of it. A rebasing, lying or fee-on-send token can move value between
  markets on that token only, never other assets. The UI should offer an
  allowlist.
- **`betETH` routes through zRouter's public functions.** PM grants the router
  no allowance, so a route can only spend the ETH it was sent. The global
  transient lock blocks reentry mid-route. Unspent ETH is refunded as a balance
  delta, which never touches ETH-market pots.
- **The Permit2 signature is bound to `msg.sender`.** Relayed bets would need a
  witness covering the market, side and recipient.

## Audit record

Three internal passes: design review, then minimalism and economics, then a
three-lens security audit. The audit found no critical, high or medium issues.
The proof suites are committed:

| Suite | Lens |
|---|---|
| `test/PM.t.sol` | unit + mainnet-fork behaviour (37 tests) |
| `test/PMAuditInvariant.t.sol` | handler invariants: solvency per asset, pot ≥ shares, state machine, supply, claims (audited at 128 × 300) |
| `test/PMAuditAdversarial.t.sol` | timing, ids, arithmetic bounds, griefing |
| `test/PMAuditRoute.t.sol` | every zRouter entry point as a route (fork) |
| `test/PMAuditTokens.t.sol` | no-return, false-return, fee-on-transfer, rebasing, hooks, blacklist, garbage decimals |
| `test/PMAuditPermit.t.sol` | EIP-2612 front-run, WETH-fallback permit, Permit2 binding (fork) |

An external review of `31cbbf6` found one low: resolver fees used 256-bit
`pot * feeBps`, so a fee-bearing pot above `max / feeBps` could not resolve. That
case is now full precision (`test_hugePotWithFee_resolvesAndQuotes`).

Findings that were fixed:
- Exit could dodge the late tax.
- Both taxes rounded down.
- A market could be created in a resolver's name ahead of it.
- `quote` gave misleading values outside trading.
- The token bet paths had no slippage floor.
- A 256-bit overflow on huge-supply tokens (now `fullMulDiv`).
- A zero-value route could credit router dust.
- Views returned wrong values for odd ids.
- `decimals` truncated out-of-range values.

Accepted as design:
- Resolver trust, including the void described above.
- Shares sent to `address(0)` are lost.
- A dust bet on an empty side turns a void into a live market.
- Forced ETH and rounding dust stay in the contract.

## UI notes

- Escape `description`: it is up to 1,024 arbitrary bytes.
- Page `getMarkets` at 50 or fewer (about 100k gas per market cold).
- A resolver should send `closeMarket` and `resolve` together.
