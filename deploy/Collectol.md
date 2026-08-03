# Collectol

zRouter `snwap` forwarder for the FWC collector DAO. Buys shares from the
continuous sale, the zAMM v1 pool, or a split of both in one atomic call — which
is what lets any ERC-20, not just ETH, reach either venue: the caller's ordinary
zQuoter leg converts to ETH first, then this executes.

`CollectolLens` is the read-only planner that solves the split and returns it in
exactly the argument shape `Collectol.buy` takes.

## Addresses

| | |
|---|---|
| deployer | SafeSummoner `0x00000000004473e1f31C8266612e7FD5504e6f2a` |
| Collectol | `0x0000003b9DFB69a1c764b1b136EE93dEDcdB2EE3` |
| Collectol salt | `0x0000000000000000000000000000000000000000000000000000000000541bf8` |
| Collectol initcode hash | `0x9368e8f876015f0778155cf28f8690d357ffd688eee1b41ec1a8fdaa138e194b` |
| Collectol creation size | 3,449 B (~668k deploy gas) |
| CollectolLens | `0x000000eA30dd95Ed6A5734F3Df361b2f4D5acaf6` |
| CollectolLens salt | `0x000000000000000000000000000000000000000000000000000000000040e441` |
| CollectolLens initcode hash | `0x11b7454e061cee0e134e0976ddc647900c582e4197421abcbceee8a2b71cfea9` |
| CollectolLens creation size | 4,682 B (~998k deploy gas) |

Both predicted addresses confirmed by `eth_call` to `predictCreate2` against the
live SafeSummoner, and reproduced by deploying the exact `.initcode.bin` bytes
through the real factory on a mainnet fork (`test/CollectolDeploy.t.sol`).

### Superseded

`0x000000493f3E1138d589083400586d05c5526475` was the first deployment. It is
sound but only fundable from `msg.value`, and that makes it unreachable on the
route this exists for. snwap funds a native-input executor from `msg.value`, and
every delegatecalled entry in a zRouter multicall observes the same `msg.value` -
zero when the user is paying an ERC-20. Its other funding path hands the executor
the router's own *token* balance. So an ERC-20 hop could never deliver ETH to it,
which left only native input, which the coin page's Sale tab already covered.
Nothing was lost by it: it holds no funds and grants no approvals. Do not wire it.

## Constructor bindings

`Collectol(sale, feeOrHook)` — every venue is fixed at construction, so calldata
selects amounts and nothing else.

| arg | value |
|---|---|
| `sale` | `0x824d11a46F32cd16cdF46380314343e9697e2491` (FWC continuous sale) |
| `feeOrHook` | `30` |

`shares` (`0x883d646d0C8202Aa23F01d4aF45E4E73804c3a49`) is read off the sale
rather than passed in, so the two can never disagree. The constructor also
requires the (ETH, shares) pool to be non-empty, so a misconfigured deployment
reverts instead of half-working.

`CollectolLens()` takes no arguments and is bound to nothing — it is a pure
planner and takes the sale, shares and fee per call.

## Deploy

1. `create2Deploy` with `Collectol.deploy.calldata.txt` → `0x0000003b9D…2EE3`
2. `create2Deploy` with `CollectolLens.deploy.calldata.txt` → `0x000000eA30…caf6`

Neither contract has an owner, holds funds between calls, or grants any approval,
so there is no post-deploy setup step.

## Live parameters at time of mining

| | |
|---|---|
| sale rate | 1,000,000 shares / ETH (a bytecode constant with no getter — measured via `probeSaleRate`) |
| DAO allowance left | 8.348e24 shares ≈ 8.35 ETH of mintable sale |
| pool reserves | 0.1896 ETH / 182,198 shares |

The pool is small relative to the sale, so at these levels the optimum is almost
all mint. The split only starts paying once someone sells into the curve: after a
5 ETH buy dumped back into the pool, the solved optimum for a 1 ETH order moves
to 0.820 ETH mint / 0.180 ETH pool.

## Verification

`forge test --match-path 'test/Collectol*.t.sol' --fork-url <mainnet>` — 34 tests
against live state, plus a full-route run on an anvil fork that sends the exact
multicall the dapp builds (USDC in, shares out). Beyond the happy paths they pin the properties the security
argument rests on:

- output is a measured balance delta, so shares donated to the contract are not
  swept to whoever calls next (`testDonatedSharesAreNotSwept`)
- ETH already at the address is likewise not spendable as someone's change
  (`testDonatedEthIsNotSwept`) — the mined address is fresh, but the forge test
  address used during development already held 0.000577 ETH on mainnet, which is
  how this was caught
- `minTotalOut` binds over the two legs combined, not per venue
  (`testMinTotalOutBinds`)
- funding must cover the plan; a pool limit without a pool leg, a zero deadline,
  and `recipient == address(this)` all revert
- the solved split is never worse than either venue alone, across 256 fuzzed
  sizes, and never exceeds the DAO's remaining allowance
- WETH funding buys the same plan native funding does, and leaves no WETH behind
  (`testWethFundingBuysTheSamePlan`)
- leg 1 landing above its quoted floor is refunded rather than spent on a larger
  position than was quoted (`testOvershootIsRefundedNotSpent`)
- underfunding still fails closed (`testUnderfundingReverts`)
- a single donated wei of WETH cannot grief every route
  (`testWethDonationDoesNotGriefRoutes`) — the reason funding is measured as
  "unwrap whatever is here" rather than matched against a declared amount

## How a token route reaches it

Both venues are ETH-priced, and snwap cannot hand a forwarder native value on a
token trade (see Superseded above). So the hop arrives as WETH:

1. leg 1: ERC-20 -> ETH, best on-chain venue, output left in the router
2. `wrap(ethFloor)` - planned on leg 1's *guaranteed floor*, not its estimate
3. `snwap(WETH, 0, user, shares, minTotalOut, Collectol, buyData)` - `amountIn`
   of zero sweeps the router's whole WETH balance into the forwarder
4. Collectol unwraps it and mints / swaps per the plan
5. `sweep` WETH, ETH and the input token back to the user

Native input skips 2 and 3 for a single `snwap(address(0), ethIn, ...)`.

## Known operational edges

- **The sale is all-or-nothing against the DAO's share allowance.** `buy()`
  reverts rather than partially filling, so a sale leg sized past the remaining
  allowance takes the pool leg down with it. `CollectolLens.maxSaleEth` reads that
  ceiling and both plans cap against it. Someone draining the allowance between
  quote and execution costs a failed transaction, not funds.
- **A paused sale reverts the leg.** Pass `saleRate = 0` to the planner and the
  whole order routes through the pool.
- **`swapExactOut` overshoot returns to `refundTo`,** which is deliberately
  independent of `recipient`: on an exact-out route the change belongs to
  whoever funded it, who is not always the payee.
