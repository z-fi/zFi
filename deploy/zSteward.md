# zSteward

`0x0000005F38594Af514e65e7d1e4EddE773bcF886`, Ethereum only. NOT DEPLOYED. Optional: zSwap works the same with or without it.

Source: `src/utils/zSteward.sol`. Tests: `test/zSteward.t.sol` runs it against real instances of all four lists. `test/ui/steward-admin.test.mjs` covers the admin tooling.

## What it is

zSwap reads four lists from chain: `zRpcList` (Ethereum read nodes), `zEndpoints` (L2 nodes, logs nodes, the Tacit relay, Bitcoin APIs, WalletConnect, airdrop mirrors, pool keepers), `zSolverList` (aggregator lanes) and `zSwapFlags` (lane switches). One EOA owns all four today (`0x1C0Aa8cC…55A20`, with an EIP-7702 delegation). It can add an entry in one block, and every copy of the page uses that entry on its next read.

zSteward is an owner those lists can be handed to. For a list it holds:

- **Additions wait in public.** Adding, replacing, reordering, re-enabling, switching a lane ON, handing ownership on, and changing a role are all `queue`d first. Each one emits `Queued` with the full calldata. Anyone can `execute` it from `DELAY` (3 days) after queueing until `GRACE` (14 days) after that. Until then the steward or the guardian can `cancel` it.
- **Removals apply at once.** `narrow` accepts exactly these calls: `remove`/`pop` on any list, `setEnabled(i, false)` on zSolverList, and `set(name, chain, 2)` (OFF) on zSwapFlags. The page keeps its built-in values behind every list, so these calls can only leave it with entries already listed or with those values.
- **Receiving is immediate.** The list's owner calls `transferOwnership(zSteward)`, and then anyone calls `zSteward.accept(list)`. A list leaves zSteward only through the queue.

Roles: steward `0x1C0Aa8cC…55A20` (today's curator) queues, narrows and cancels. Guardian `0x5E58BA0e…053E` (the zFi DAO) cancels, narrows, and can replace the steward at once. The DAO votes within a day and executes after its one-day timelock, so a 3-day delay leaves it time to cancel.

## What the page does

zSwap reads the lists directly, wherever they are held, so it behaves the same before zSteward exists, after it is deployed, and after it holds some or all of the lists. The page:

- reads the lists only from `L1_SEED`, the Ethereum and logs nodes built into its own bytes, never from a node a list added, so no node can vouch for the list that named it. check-zSwap pins this;
- names zSteward (`STW`) only to label a list it holds: the "What this page is" docs explain what zSteward means, and "See who holds each list and what the page uses now" reads each list's `owner()` on click and shows either "zSteward, additions wait three days" or the owner's address with "changes apply at once".

## Deploy (any time after the page chunks)

The page pins this address, so it is fixed once the chunks are deployed. Deploy exactly the committed payload:

```
to:   0x00000000004473e1f31C8266612e7FD5504e6f2a   (SafeSummoner)
data: deploy/zSteward.deploy.calldata.txt
salt: 0x33c5615e4a720d597caf6a0ed678fb00a3401984bcba0daae26a99b39863cdc2
ctor: (0x1C0Aa8cCD568d90d61659F060D1bFb1e6f855A20, 0x5E58BA0e06ED0F5558f83bE732a4b899a674053E, 259200)
```

Anyone can send it; the deployer key does not matter. `node script/check-create2-artifacts.mjs` rebuilds the initcode from source and confirms the address. After the page ships, do not edit `src/utils/zSteward.sol` (comments included) or the constructor arguments: either moves the address away from the one the page names.

## Handover, whenever wanted

For each list, from its current owner: `transferOwnership(0x0000005F38594Af514e65e7d1e4EddE773bcF886)`. Then anyone presses Accept on `dapp/steward-queue.html` (`zSteward.accept(list)`). Lists can move one at a time.

Once zSteward holds a list, the admin pages (`endpoints-admin`, `flags-admin`, `solver-admin`, `steward`) route each write through it on their own (`dapp/steward-route.js`). Removals go through `narrow`, and everything else is queued. `dapp/steward-queue.html` lists every queued change, its status and its decoded call, and lands or cancels it.
