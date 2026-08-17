# Orderbol

Stateless zRouter executor for creating funded orders on all three boards
without making the router their owner.

## Addresses

| | |
|---|---|
| deployer | SafeSummoner `0x00000000004473e1f31C8266612e7FD5504e6f2a` |
| Orderbol | [`0x000000c1051acD54A03e967b647112FDe17f518C`](https://etherscan.io/address/0x000000c1051acD54A03e967b647112FDe17f518C) |
| salt | `0x0000000000000000000000000000000000000000000000000000000002eefc34` |
| initcode hash | `0xbddb18cc099e314196a889fbf9f867503221afd48febcdb938541c9214766f28` |
| creation size | 11,803 B |
| runtime size | 11,126 B |
| optimizer runs | 9,999,999 (unpinned) |
| supersedes | `0x000000fADa565c5608570a4F66Fb5E0bD08ef91B` |
| deploy tx | [`0x60765721…755d4a`](https://etherscan.io/tx/0x6076572100588b459d7eeb1bcc6977c628cb31ba1ed19c65d8befa8841755d4a) — block 25,722,179, 2,470,310 gas |

Constructor arguments, in order:

| | |
|---|---|
| `swapboard_` | `0x000000dA7bb4B2A9E3e80e9A4D4157E26CA6189b` |
| `dutchboard_` | `0x000000a213b430D14Bae6062c176289B05e04489` |
| `floorboard_` | `0x00000080198137F790DA4C52bb902cf87c276748` |

## What changed

`placeFloor`, so a Floorboard bid is opened through the same funding waterfall
as the other two placements — permit, Permit2, an existing zRouter allowance,
wallet batching, or a plain approval — instead of being the one book that has to
be funded by a direct wallet approval to the board.

The structural difference it has to respect: a bid escrows the **payment**, not
the lot, and the amount is `endPrice` — the ceiling of the climb, the most the
bid can ever owe. It is not a function of `want`. Sizing the transfer off `want`
or off `startPrice` is the mistake this entry point exists to make impossible
for a caller; the board would revert on the shortfall, but only after the route
had already been funded.

Two smaller inversions relative to `placeDutch`, both of which are just the
schedule running the other way:

- the price check is `endPrice >= startPrice`, and only the **ceiling** has to
  fit `uint96`, because the ceiling is the escrow;
- an ETH-funded bid passes `quote == address(0)` and the **board** wraps it, so
  the escrow is canonical WETH from the moment it opens. `placeDutch` wraps the
  lot here instead, because there the escrow has to arrive as a token.

`bidder` is a gift recipient with the same semantics as `Floorboard.bidFor`: the
caller pays the whole escrow and keeps no claim on it, and the bidder may cancel
in the next block and keep all of it. A frontend must present a `bidder` other
than the payer as "fund a bid for X and hand X the money".

`placeFloor` builds its `Terms` struct first and passes that to the guard and
the verifier rather than the flat parameter list — eleven parameters is one more
than the frame holds alongside the call and its checks.

Covered by `test/OrderbolFloor.t.sol`, which also asserts the placed bid is
actually hittable afterwards: a placement that verifies but cannot be sold into
is not a placement.
