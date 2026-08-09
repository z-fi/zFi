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

## Superseded — DO NOT WIRE

`0xb3a0fEB849ABdd207d315A2d0a487E711504fe95` was the first deployment. **It is
drainable.** It keyed recovery by token rather than by order:

```solidity
expiry[tokenIn]    = validTo;      // last writer wins
recipient[tokenIn] = receiver;     // last writer wins
require(sellAmount + feeAmount == balanceOf(tokenIn));   // the WHOLE balance
```

`swap` is reachable by anyone through the public `zRouter.snwap -> SafeExecutor`
path and `recover` was permissionless, so while a deposit rested there an
attacker could add one wei of the same token, name themselves that token's
recipient with an immediate expiry, and recover the entire balance — the
victim's deposit included. No solver, no race with settlement. Proof:
`test/CowolRecoverHijack.t.sol`.

Second defect in the same code: `expiry` defaults to zero, so `recover` on any
token that was never deposited passed `block.timestamp > 0` and swept the
balance to `recipient[token]` — `address(0)`.

It has no owner and no pause, so it cannot be stopped on-chain. It was taken out
of the dapp by removing CoW from the quote race; `COWOL_LIVE` now gates that
entry. Its balance was zero when the issue was found.

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

## Deploying

```
cast send 0x00000000004473e1f31C8266612e7FD5504e6f2a \
  $(cat deploy/Cowol.deploy.calldata.txt) \
  --account <keystore> --rpc-url <rpc>
```

Then set `COWOL_LIVE = true` in `dapp/index.html`. Not before — snwap transfers
the sell tokens to `COWOL_ADDRESS` before calling it, so routing to a codeless
address sends them nowhere recoverable.
