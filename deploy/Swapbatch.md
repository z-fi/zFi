# Swapbatch

Fill several Swapboard orders in one transaction, paying native ETH.

## Deployed

| | |
|---|---|
| address | `0x000000Fbde0567d1966FCa91eF2A1ddCCD1fedbd` |
| deploy tx | `0x7dd330109c2d85ab244817aa29029d4415f0e84a18960efb72e06c83e5c07caf` |
| block | 25,739,014 |
| salt | `0x0000000000000000000000000000000000000000000000000000000001638c0c` |
| initcode hash | `0x16fe36430feffcbfc73f542ca239a4145ad299e855480caad5d264b6bbd9483f` |
| constructor | `(WETH, 0x000000fF3D…DbecF, 0x000000dA7b…6189b)` |
| runtime | 7,205 bytes |
| cost | 1,614,257 gas @ 0.141 gwei = 0.000228 ETH |

Verified on Etherscan. The settings are load-bearing: solc 0.8.36, via_ir, the
repo default 9,999,999 optimizer runs, evm prague. See `Swapbatch.verify.sh`.

### It replaces an earlier deployment

`0x0000005471EEF58dD16Aeccda21C37758E36a0b6` is still on chain and still works
for the current Swapboard, but its `legacyBoard` is the ZERO ADDRESS - the
constructor permits that so long as a modern board is set - so its entire legacy
path was unreachable and v1 could not be batched at all. `legacyBoard` is
immutable, so binding v1 needed a new deployment rather than a setter.

The old instance also carried a decoder for a different board's Order struct
(seven words, the outdated Swapboard at `0x…85B831`), which would have
misdecoded v1 by one word had it ever been pointed at it. Nothing was at risk in
practice, because the zero binding meant the path could not be entered.

## Why it exists

Swapboard inherits Solady's `Multicallable`, whose `multicall` refuses any
non-zero `msg.value` — deliberately, because every delegatecall in a multicall
observes the SAME `msg.value`, and `fillOrderWithEth` both treats it as the
amount paid and wraps it out of the CONTRACT's balance. One `msg.value` could
then settle N orders, underwritten by any ETH resting in the board. So the value
accounting lives in a helper instead, where `msg.value` is counted exactly once
against the sum of the legs.

## Which boards it binds, and why only two

`Swapbol` forwards to four boards. `Swapbatch` binds two of them, and the other
two are omitted because a helper there would have nothing to help with:

| Board | Address | Bound | Why |
|---|---|---|---|
| v1 | `0x000000fF3D7A2d373615141d7489Ca66683DbecF` | yes | No batch fill, no `multicall`. Batching it is impossible without this. |
| Swapboard (current) | `0x000000dA7bb4B2A9E3e80e9A4D4157E26CA6189b` | yes | Has a batch fill, but no payable one. |
| Dutchboard | `0x000000a213b430D14Bae6062c176289B05e04489` | no | `fillMany`/`tryFillMany` are ALREADY payable and take a `to`. Native. |
| Floorboard | `0x00000080198137F790DA4C52bb902cf87c276748` | no | `tryHitMany` is not payable. Hitting a bid runs the other way: the taker DELIVERS the asset and receives proceeds. There is no ETH leg to wrap. |

A fifth address exists and is deliberately NOT bound:
`0x00000000CC3915a0f5F98CBdC558Ac1a8e85B831`, an outdated version of our own
Swapboard. The dapp excludes it, `Swapbol` refuses it by name
(`test_rejectsDeprecatedOrUnknownBoard`), and `Swapbatch` cannot reach it —
`fillOrdersWithEth` rejects any board that is not one of the two bound above.

## The v1 shape, which is the thing to get right

Three boards exist and all three Order structs differ. They are told apart by
deployment date, not by name, which is what makes this easy to get wrong — a
missing field does not fail to decode, it slides every field after it one word
left, so `tokenA` reads a bool and `amountA` reads an address as a number.
Nothing reverts; the batch settles against nonsense.

| Board | Struct words |
|---|---|
| v1 | 6 |
| the outdated one | 7 (`partialFill`) |
| current | 11 |

v1 is six words, verified by decoding a real order rather than by counting
fields: `getOrders([5])` returns maker, `active=1`, tokenA=WETH,
amountA=0.02e18, tokenB=USDC, amountB=100e6. Addresses land in the address slots
and amounts in the amount slots, which they would not under any other ordering.

v1 is also what "legacy" means everywhere else: `Swapbol.boardV1()` returns it,
the dapp lists it as its legacy board, and it holds the history worth batching —
139 orders against the outdated board's 3.

## How v1 is driven

v1 has no `fillOrders`, no `tryFillOrders` and no `multicall`. It has only
`fillOrder(uint256 orderId, uint256 deadline)` — note the second argument is a
DEADLINE, not an amount. So `Swapbatch` drives it one order at a time, and three
properties follow, each pinned by a test:

- **All or nothing.** There is nowhere to put a fill amount, so the caller's
  `fillAmountsB[i]` is an assertion about what the order costs, not a request. A
  mismatch reverts `PartialFillUnsupported` BEFORE any value is wrapped.
- **WETH-quoted only.** A leg whose `tokenB` is not WETH cannot be paid from
  `msg.value`, and is refused rather than reaching the board with an allowance it
  never spends.
- **Dead legs stay skippable.** A cancelled order reads back as all zeros, so
  both checks above are gated on `active`. Without that gate `skipFailures` would
  abort on exactly the leg it exists to skip. Caught by the live-board test, not
  by a mock.

v1 also takes no recipient and pays tokenA to its `msg.sender` — this contract.
So on v1 the `tokensOut` sweep is not a safety net, it is the DELIVERY PATH, and
omitting a bought asset from it would strand the purchase permanently.

## Tests

`test/Swapbatch.t.sol` (mocks), `test/SwapbatchWethLegProbe.t.sol` (the WETH-out
leg the main mock never builds), and `test/SwapbatchFork.t.sol`, which binds the
REAL v1 board and fills REAL orders. That last one is the only suite that can
catch a struct mismatch: a mock built to the interface's shape agrees with the
interface no matter what mainnet says. This has been wrong in both directions —
once omitting a field the board has, once carrying one it does not — and the unit
tests passed both times.
