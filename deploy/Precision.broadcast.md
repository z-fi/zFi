# Precision — broadcast sheet

> **EXECUTED 2026-08-11. Do not re-run.** All six are live and verified; see
> `deploy/Precision.md` for addresses, transaction hashes and the post-deploy
> checks that were actually performed. Re-sending any of these would revert
> `Create2Failed()` at the summoner, since the addresses are occupied — but the
> factory transaction alone is ~6.3M gas to discover that.
>
> Kept as the record of what was broadcast, and as the template for a future
> redeploy. A redeploy needs new salts: the addresses below are bound to this
> exact bytecode.

Everything below is frozen and reproduces from source
(`node script/check-create2-artifacts.mjs`, 21/21 ok). Send these six
transactions, in this order, to the SafeSummoner CREATE2 factory:

**`0x00000000004473e1f31C8266612e7FD5504e6f2a`**

Each `deploy.calldata.txt` is a complete, pre-encoded
`create2Deploy(bytes creationCode, bytes32 salt)` call. Value is zero on all six.

## Order — this is not cosmetic

The factory's address is a constructor argument to the other five, so it must
land first. The rest are independent of each other and can go in any order or
in parallel.

| # | contract | expected address |
|---|---|---|
| 1 | `PrecisionPoolFactory` | `0x000000Eb27B557aB426d9E99cFd54EC455799e81` |
| 2 | `PrecisionRoute` | `0x000000384711c65f633Aa4487b968ecb7956DB0F` |
| 3 | `PrecisionZap` | `0x000000d193680877a83D3C6bCA73D8726D120c67` |
| 4 | `PrecisionPoolLens` | `0x000000Bad3a2fa57ed74fa06000573ccddF6B7fB` |
| 5 | `ConstantSurchargeHook` | `0x000000Aee5a5acCFe16088A29A555D93eE42ec03` |
| 6 | `PrecisionPoolPolicy` | `0x00000045fc7b570Be4d71F67219508ebD295EC6D` |

```sh
for n in PrecisionPoolFactory PrecisionRoute PrecisionZap \
         PrecisionPoolLens ConstantSurchargeHook PrecisionPoolPolicy; do
  cast send 0x00000000004473e1f31C8266612e7FD5504e6f2a \
    "$(cat deploy/$n.deploy.calldata.txt)" \
    --rpc-url "$RPC" --private-key "$PK"
  # confirm before continuing, especially after the factory
  cast code "$(cat deploy/$n.address.txt)" --rpc-url "$RPC" | head -c 20
done
```

The factory transaction is ~29 KB of calldata. Budget for it and check the gas
estimate before sending; the others are small.

## Immediately after — three checks worth thirty seconds

```sh
FAC=0x000000Eb27B557aB426d9E99cFd54EC455799e81

# 1. The factory holds the pool blob we mined against, not some other build.
cast call $FAC "poolInitCodeHash()(bytes32)" --rpc-url "$RPC"
#    must equal 0x897b0181f6b0a84c801ae9934c3e8219c68bd65d46d2d534068ae4cda61cbf10

# 2. Every dependent points at the factory that actually landed.
for n in PrecisionRoute PrecisionZap PrecisionPoolLens; do
  cast call "$(cat deploy/$n.address.txt)" "factory()(address)" --rpc-url "$RPC"
done

# 3. The policy's owner is the intended one.
cast call 0x00000045fc7b570Be4d71F67219508ebD295EC6D "owner()(address)" --rpc-url "$RPC"
#    must equal 0x006CD14F36F65eCbB29b2519cCBe63A0DC8549F2
```

If `poolInitCodeHash` does not match, **stop and do not seed anything**. It
would mean the factory went out over a different pool build, and every market
address it produces is not the one this repo describes.

## Then — and this is the part that actually carries risk

Deploying costs nothing and risks nothing: these contracts hold no funds until
someone seeds a market. Getting that wrong is recoverable by deploying a fresh
set and never seeding the old one. What is NOT recoverable is TVL in an
immutable pool. There is no pause, no upgrade, and no sweep — deliberately.

So treat these as separate decisions:

1. **Seed one market yourself, small.** Named (`feeRecipient != 0`), so only you
   can initialise it. Swap through it, add, remove, route a hop, zap in and out.
   Nothing in this repo has ever executed against a real chain, and today alone
   turned up three behaviours that exist only outside the test EVM — forge does
   not enforce EIP-170, `forge inspect` ignores `compilation_restrictions`, and
   a forked address can arrive pre-funded.
2. **Watch it.** A day of real blocks, real MEV, real tokens.
3. **Then open the frontend**, with a TVL cap while it is young.
4. **Then a bounty**, before the cap comes off.

## Two things the frontend must do from day one

- **Verify `pool.factory()`**, or read pools through the lens, which returns
  nothing for a pool its factory did not create. The pool constructor is public
  and every LP token is named `Precision LP` / `pLP`, so a hostile pool is
  visually identical in a wallet.
- **Screen hooked pools out of `routeUpTo` paths.** `PoolInfo.clampable` and
  `PrecisionPoolLens.routeClampable` exist for this. The route now enforces it
  itself (`HookedNoClamp`), so this is about giving users a clean message
  instead of a revert.

## Ship named markets

`feeRecipient != 0` is the only thing that stops a stranger initialising a
market at a price of their choosing. Unnamed markets are permissionless to seed
by design, and `seed` now refuses to silently convert a lost race into a
proportional deposit — but refusing is not the same as protecting.
