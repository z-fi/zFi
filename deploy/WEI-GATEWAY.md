# Serving zSwap from wei.limo

What the gateway has to do, and why each rule is the way it is. The contracts
are written against these assumptions; if the gateway does something else, say
so here and the contracts can move instead.

Today wei.limo resolves IPNS and IPFS contenthashes. zSwap has neither. It is a
contract whose runtime bytecode IS the page, so serving it means calling it.

## The shape of the thing being served

Two surfaces, deliberately different, and the gateway should expose both:

| URL | serves | changes? |
|---|---|---|
| `zswap.wei.limo` | `zSwapResolver` → whatever version is current | yes, on each DAO upgrade |
| `0x<address>.wei.limo` | that exact version | never |

That split is the entire design. A version's bytes cannot change - it is nine
data contracts and a wrapper, and there is no admin key, no proxy and no setter
anywhere in it. What changes is only *which* version a name points at.

So a reader who wants the moving target uses the name, and a reader who audited
a build uses its address and keeps it. Neither can be turned into the other by
anybody, including the DAO.

## Rule 1 - resolve a name to a contract, then ask the contract

After the existing WNS resolution (`name → id → address`), if the resolved
address has code:

1. Call `resolveMode()`. If it returns `bytes32("5219")`, call
   `request([], [])` and serve the returned `body` with the returned
   `statusCode`, `Content-Type` and `Cache-Control`.
2. Otherwise call `html()`. If it answers, serve the string as `text/html`.
3. Otherwise fall through to contenthash / IPNS exactly as today.

Three `eth_call`s worst case, and nothing zSwap-specific: any contract exposing
`html()` is a page under ERC-8244, and any contract answering `"5219"` is one
under ERC-4804/5219. Both zSwap versions and the resolver implement both.

Measured cost for the real page: **214,391 bytes, 3.16M gas** to relay through
the resolver (`test_relayingTheRealPageStaysWithinAnEthCallBudget`). Any
ordinary `eth_call` cap covers it. Budget for the response size, not the gas.

## Rule 2 - hex labels, which the page already expects

Support `0x<40 hex>.wei.limo` as "serve this contract directly", skipping WNS.

This costs one regex and it switches on machinery the page already has. zSwap
reads its own address from the first hostname label when that label is an
address and the second is not a chain number - so on `0x….wei.limo` the page:

- names the exact build in its footer and links Etherscan,
- calls `latest()` on itself, and
- if the chain has moved on to a version that has stood for three days (see
  below), shows a `newer →` link built from *the same hostname*, i.e. pointing
  back at `0x<successor>.wei.limo`.

A reader pinned to an audited version therefore learns that a newer one exists,
without being moved to it, and without ever leaving your gateway. Nothing in the
page needs to change for this; it works against the bytes as deployed.

## Rule 3 - take the cache policy from the contract, not from a config

This is the one rule that matters most, because both answers are correct and
they are opposites:

- **A version** answers `Cache-Control: public, max-age=31536000, immutable`.
  It means it. The bytes at that address cannot change, ever, so cache as hard
  as you like - forever is fine.
- **The resolver** answers `Cache-Control: public, max-age=300`. It *can*
  change, the moment the DAO's next `deployNext` lands. Cached as permanent it
  would serve a superseded version long after the chain moved, which is exactly
  the failure the resolver exists to prevent.

Honor the header and you never have to know which address is which. There is a
test asserting the resolver never says `immutable` and that the version it
relays always does.

Corollary: **do not serve stale on RPC failure** for the resolver path. A 502 is
honest. A cached copy of a superseded version is a lie with a UI. The 300s
max-age already bounds how wrong the gateway can be.

## The delay, so the gateway does not implement its own

Both the name and the served page wait **three days** before pointing anyone at
a newly deployed version. The chain records an upgrade instantly and it is
auditable instantly - only the automatic promotion waits.

The reason is the one failure this whole arrangement would otherwise make
worse: derived-from-chain means a stolen governance key repoints the name, and
every old page's footer link, in a single transaction. A version that must
stand unchallenged for three days is one anybody can look at first, and a delay
is the thing the DAO cannot buy back after the fact.

Where it lives:

- `zSwapResolver.MATURITY` (3 days) - the name serves the newest MATURE
  version, walking back over anything younger.
- `MATURITY` in the page (259200 s) - the `newer →` link does the same, using
  the reader's own clock. `check-zSwap.mjs` fails if the two numbers drift.
- `zSwap.succeededAt` - the timestamp both read, written by the predecessor in
  the same transaction that sets `successor`, so it cannot be backdated.

**The gateway needs no delay logic of its own.** Serving `current()` already
respects it. Do not add a second one - two delays compose into a longer one
nobody chose.

A version reached by its own address is never delayed. `0x….wei.limo` serves
that contract immediately, which is what makes an urgent fix reachable while
the name waits.

## What a reader on the NAME can see (and what is still missing)

Served from `zswap.wei.limo`, the page gets the current version's bytes - but it
cannot tell which version it is, because the hostname carries a name rather than
an address. In v0.1 that means the footer shows no address and no links at all;
the `newer →` notice only appears on the `0x….wei.limo` path.

`zSwapResolver.versions()` is the primitive that closes this, in one call:
every version oldest-first, root to tip. A future page can pair it with
`current()` and render a picker - "live · v0.4 · older: v0.3, v0.2, v0.1", each
linking `0x<address>.wei.limo`, each of those an immutable build that still
serves its own bytes.

Note the two answers differ on purpose. `versions()` lists what EXISTS,
including a tip too young for the name to serve; `current()` says what is being
SERVED. A picker should show both - hiding a version the name is waiting on
would be the same silence the delay exists to make visible.

This needs a page change, so it lands in v0.2 or later. The contract side is
ready now, which is why `versions()` exists before anything uses it.

## Rule 4 - whitelist the headers you pass through

Take `Content-Type` and `Cache-Control` from the `request()` response. Drop
everything else.

The header array is contract-authored, which in the general case means
attacker-authored - anyone can deploy a contract and get a name. A page must not
be able to set its own CSP, hand out cookies, or emit redirects through your
gateway. zSwap returns exactly the two headers above; treat that as the ceiling,
not as a reason to trust the array.

## Operator note: the Public Suffix List

If `wei.limo` is not on the [PSL](https://publicsuffix.org/), add it before
serving contract-authored HTML on subdomains.

Subdomains give you origin separation for localStorage and the DOM, but cookies
follow the *registrable domain* rule: without a PSL entry, `evil.wei.limo` can
set a cookie scoped to `.wei.limo` that `zswap.wei.limo` will send. The PSL
entry is what makes each name a separate site rather than a separate host.

This is unrelated to zSwap and more important than anything else in this file.

## On pinning to IPFS

Worth keeping, as a mirror. Not as the source of truth.

A CID names bytes, so a pin is inherently per-version: "pin the latest" means
re-pinning and re-writing a record on every release. That second write is the
step this design removes - the resolver derives the current version from the
chain, so the DAO's upgrade transaction is the only write, and the name cannot
lag behind it.

If a version's pin should be discoverable on chain, the natural home is a
DAO-set `version → CID` map on the resolver, written once when a version ships.
It is not built; it is a small addition if you want it.

## What the contracts guarantee, so the gateway does not have to

- `html()` and `request()` on a version are pure reads of immutable bytecode.
  No state, no admin, no path to change them.
- `zSwapResolver.current()` never reverts: a failed walk falls back to the last
  version that answered, and the root always answers - the resolver could not
  have been deployed against one that did not.
- The resolver's `ROOT` is a constructor argument and immutable, so the lineage
  a name follows is fixed by bytes anyone can read - there is no transaction
  that can point it at a different one.
- `deployNext` refuses any successor that cannot be walked in both directions,
  so `latest()` cannot be bricked for a predecessor by a bad upgrade.

## Addresses

| what | address |
|---|---|
| WNS (`.wei` registry) | `0x0000000000696760E15f265e828DB644A0c242EB` |
| zSwapResolver | not yet deployed - takes zSwap v0.1 as its constructor argument, so it is deployed after the root |
| zSwap v0.1 | not yet deployed |
| DAO (may upgrade, may `manage` the name) | `0x5E58BA0e06ED0F5558f83bE732a4b899a674053E` |
