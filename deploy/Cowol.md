# Cowol

CoW Protocol adapter for zFi. Holds the sell-side tokens while a CoW
batch-auction order is live and implements ERC-1271 so GPv2Settlement can verify
the order on-chain.

It is the only forwarder in this repo that **custodies** anything. Every other
one settles inside the user's own transaction, so zRouter's `amountOutMin`
postcondition is the whole security argument. CoW is asynchronous, the dapp
therefore calls snwap with `amountOutMin = 0`, and there is no postcondition —
so this contract's own accounting has to be right.

## Addresses

| | |
|---|---|
| deployer | SafeSummoner `0x00000000004473e1f31C8266612e7FD5504e6f2a` |
| Cowol | `0x0000003B59007E8aa43B0e508AfF8a304438333B` |
| salt | `0x0000000000000000000000000000000000000000000000000000000002d24d3c` |
| initcode hash | `0x86188466952b7540326836105c39365e4bbf3f0864c07f67d0f2f08481912003` |
| creation size | 3,038 B (~676k deploy gas) |
| runtime size | 3,012 B |
| optimizer runs | 9,999,999 (unpinned) |

No constructor arguments. `SAFE_EXECUTOR`, `VAULT_RELAYER` and the CoW domain
separator are all compile-time constants.

Predicted address reproduced by deploying the exact `.initcode.bin` bytes through
the real factory on a mainnet fork — `test/CowolDeploy.t.sol`, checked against
four independent RPCs.

## What changed

Custody is per-order:

- `orders[digest]` — an exact `(sellToken, receiver, validTo, amount)`.
- `committed[token]` — sum of live reservations. A deposit is measured against
  `balance - committed`, so a new order can never be written over tokens an
  existing order already holds.
- `recover(bytes32 digest)` replaces `recover(address token)` and pays that
  order's amount to that order's receiver. It also **deletes the digest**, so
  returning a deposit revokes the ERC-1271 signature a solver could still have
  filled against it.
- `receiver != address(0)`, `validTo` strictly in the future, and a duplicate
  live-order guard.

### Two deliberate trade-offs

**Back-to-back orders on one token serialize.** CoW pulls the sell tokens through
VaultRelayer without notifying this contract, so from in here a settled order and
a live one are indistinguishable from a live order plus a smaller fresh deposit.
Guessing permissively is exactly what caused the original bug, so a reservation
stands until its `validTo` passes — after which anyone may `recover` it, which
pays nothing (the balance already left) and frees the token. Bounded at twenty
minutes by `MAX_EXPIRY`. Covered by `test_swap_second_order`.

**An unregistered deposit would be unowned.** snwap transfers and registers in
one transaction, so a refused `swap` unwinds the transfer with it. A deposit that
somehow rested here unregistered would be absorbed by the next expiring order:
balance-based custody cannot attribute tokens no order ever claimed.

## Deployed

Live at `0x0000003B59007E8aa43B0e508AfF8a304438333B` as of 2026-08-09, block
25,718,077, via SafeSummoner. Etherscan-verified.

Confirmed before `COWOL_LIVE` was turned on in the dapp:

- runtime bytecode byte-identical to the local build (3,012 B), against three
  independent RPCs;
- `orders(bytes32)` and `committed(address)` present, so it is the order-keyed
  revision;
- `expiry(address)` and `recipient(address)` revert, so no token-keyed
  accessor survives;
- `isValidSignature` on an unregistered digest returns `0xffffffff`.

The gate matters because snwap transfers the sell tokens to `COWOL_ADDRESS`
before calling it: routing to a codeless address sends them nowhere recoverable.
If this address ever changes, set `COWOL_LIVE = false` until the new one is
confirmed on-chain.
