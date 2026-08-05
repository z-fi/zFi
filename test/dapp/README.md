# dapp/tokenlist tests

Node suites for `dapp/tokenlist/page.html`. They run the page's **real** script against
registry answers frozen from mainnet — no network, no browser, no RPC key.

```sh
node test/dapp/security.mjs    # url/logo scheme gates, untrusted-input bounds
node test/dapp/decode.mjs      # multicall decode, links, exports, chunking
node test/dapp/taxonomy.mjs    # filters and badges for listing kinds that do not exist yet
node test/dapp/fuzz.mjs        # 4000 random UI operations, 7 invariants after each
BARE=1 node test/dapp/fuzz.mjs # same, without synthetic listings — exercises zero-count paths
```

All four exit non-zero on failure.

## Why these exist

The page is deployed onchain and is not meant to be redeployed often, so it is tested
the way a contract is: against real data, adversarially, before it ships.

`fuzz.mjs` is the important one. It drives random sequences of search / filter / sort /
open / mid-load / export and checks after **every** step that:

1. every visible card maps to a real row
2. the visible set matches an independently computed filter
3. the count text agrees with what is on screen
4. `order` is a permutation of `0..n-1`
5. the empty state shows exactly when nothing matches
6. the sub-row belongs to the group owning the active filter
7. no chip claims a count it cannot honour

The seed is fixed, so a failure reproduces. It has caught real defects — a crash when
typing during the first load, a filter branch that silently matched nothing, and a
sub-row that reverted to the wrong group on a zero-count category.

**Mutation-test it before trusting it.** A green suite proves nothing until it can fail.
Revert a fix in `page.html`, confirm the suite goes red, then restore. The sub-row
invariant only exists because an earlier version of this fuzzer missed that bug.

## Fixtures

`page.harness.js` and `preview.html` are generated and committed so the suites run from
a clean checkout. Regenerate only when the registry's listings change or the page
changes which calls it makes:

```sh
node test/dapp/fixtures.mjs
```

That hits mainnet over public endpoints. `preview.html` is the page with the same
frozen answers inlined — open it in a browser to look at the dapp without a network.
It says `frozen snapshot` where the live page names its RPC, because it has not earned
that label.

## What is not covered here

The RPC failover ladder and the live decode path against a *changing* registry are only
exercised by the real page. The Solidity side is covered by `test/TokenListPage.t.sol`
and `test/TokenListPageJson.t.sol`.
