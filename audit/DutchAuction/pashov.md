# 🔐 Security Review — DutchAuction

_Audit generated via the Pashov `solidity-auditor` skill (8 parallel agents: vector-scan, math-precision, access-control, economic-security, execution-trace, invariant, periphery, first-principles). Findings deduplicated, gate-evaluated, and reported per `judging.md`._

---

## Scope

|                                  |                                                        |
| -------------------------------- | ------------------------------------------------------ |
| **Mode**                         | filename (`src/DutchAuction.sol`)                      |
| **Files reviewed**               | `src/DutchAuction.sol`                                 |
| **Confidence threshold (1-100)** | 80                                                     |
| **Scan timestamp**               | 2026-04-22 21:58 UTC                                   |

---

## Findings

[75] **1. `listNFT` accepts any token address without proving ERC721 support, enabling silent fake-NFT listings**

`DutchAuction.listNFT` · Confidence: 75

**Description**
`listNFT` calls `IERC721(token).transferFrom(msg.sender, address(this), ids[i])` with no post-transfer ownership check and no interface probe. Solidity's implicit `extcodesize > 0` check catches pure EOAs (verified by `testListNFTRevertsEOAToken`), but a seller-deployed shell contract with a permissive fallback (or any non-ERC721 contract whose 4-byte selector `0x23b872dd` resolves to a no-op) passes silently because `IERC721.transferFrom` is declared with no return value — so the compiler emits no return-data decoding and no shape validation. Listing creation succeeds without escrowing anything; the subsequent `fill` repeats the silent no-op `transferFrom(address(this) → buyer)` and then unconditionally forwards buyer ETH to the seller via `safeTransferETH(seller, price)`. Six of eight audit agents independently flagged this surface, and the only guard killing the attack (extcodesize) blocks the EOA variant but not a code-bearing shell. The same exposure applies on the `cancel` path, but the attacker's goal there is moot.

> **Response:** Acknowledged. Not patched. Open-marketplace caveat emptor — no contract-level check is actually effective against a shell contract with a lying `ownerOf`/`transferFrom`, and an allowlist/curation model is a much larger design shift out of scope for a minimal primitive. The same trust assumption applies to every open NFT marketplace (OpenSea/Blur/LooksRare all rely on frontend collection verification). Frontends integrating `getAuction()` should vet `token` against a known-good registry before rendering a lot.

---

## Leads

_Vulnerability trails with concrete code smells where the full exploit path could not be completed in one analysis pass. These are not false positives — they are high-signal leads for manual review. Not scored._

- **Seller contract that rejects ETH bricks its own listing** — `DutchAuction.fill` — Code smells: push-payment via `safeTransferETH(seller, price)` inside the fill path, no pull-payment escape hatch — A seller whose `receive/fallback` reverts can DoS every `fill` call against their listing. Seller can still `cancel()` to reclaim escrow, so no third-party fund loss. Rejected as self-harm per Gate 4, but worth flagging as a documented UX tradeoff and previously-discussed design call.

  > **Response:** Acknowledged. By design. Push-payment was chosen explicitly over a pull-payment/withdraw pattern after review — the UX tax on the 99%-case payable seller outweighs the defensive win for the unpayable-seller edge. A seller who picks an address that can't receive ETH self-bricks their listing and can `cancel()` to recover escrow; no leverage over other users.

- **Buyer contract without `receive` cannot overpay** — `DutchAuction.fill` — Code smells: `safeTransferETH(msg.sender, msg.value - price)` refund forwards all gas and reverts on failure — Smart-wallet buyers that overpay to race the decay curve must be payable or the whole fill reverts. Self-harm, not exploitable.

  > **Response:** Acknowledged. By design, symmetric with the seller-side decision above. Buyers racing the decay curve should either send exact `costOf(id, take)` or buy from a payable wallet.

- **No lower bound on `startTime` vs `block.timestamp`** — `DutchAuction.listNFT` / `DutchAuction.listERC20` — Code smells: `startTime` accepted verbatim when non-zero, no sanity check against current block — Misconfigured `startTime` in the past combined with a short `duration` can land an immediate-end-price listing. With `endPrice == 0`, first MEV searcher drains the lot. Self-inflicted seller footgun.

  > **Response:** Acknowledged. Not patched. Backdating `startTime` is a legitimate pattern (e.g. to model an auction that has "been running") and adding a `startTime >= block.timestamp` guard would break it. Seller parameter choice.

- **NFT bundle locked if any single id becomes non-transferable** — `DutchAuction.cancel` / `DutchAuction.fill` — Code smells: loop of `IERC721.transferFrom` with no per-id fault isolation — One id that the underlying ERC721 refuses to transfer (pause, blocklist, soulbound post-listing) reverts both cancel and fill, stranding the entire bundle. Requires pathological token behavior chosen by the seller.

  > **Response:** Acknowledged. The seller chose the token and the bundle composition. Per-id try/catch would let partially-compromised bundles leak assets to buyers who only paid for part of the lot, which is worse than the current all-or-nothing.

- **Partial-fill ceiling division can drive aggregate revenue above `startPrice`** — `DutchAuction.fill` (ERC20 branch) — Code smells: `cost = (price * take + initial - 1) / initial` rounds up per fill, accumulating dust across N partial buys — At extreme `initial >> startPrice` ratios, the sum of per-fill costs can exceed the "total ETH for full initial lot" framing in the NatSpec. Documented by the in-code comment; favors seller; rejected as a safe protocol-favoring rounding pattern but worth documenting explicitly in the NatSpec if tighter aggregate bounds are ever promised.

  > **Response:** Acknowledged. Documented in the code comment on the cost computation. Ceiling-up is deliberate to prevent zero-cost extraction when `initial >> price`; the extreme-ratio aggregate drift is a buyer-self-tax for fragmenting purchases and doesn't harm the seller.

- **Zero-`endPrice` post-expiry listings are free-drainable** — `DutchAuction.fill` — Code smells: `priceOf` returns `a.endPrice` (possibly 0) for any call past `startTime + duration`, no auto-cancel — Forgotten listings with `endPrice == 0` become free-take for the first filler. Documented Dutch-auction semantics; seller-chosen parameter; not exploitable against other users.

  > **Response:** Acknowledged. Documented in the contract NatSpec ("`endPrice` may be 0"). This is the defined semantics of a Dutch auction that decays to zero; sellers who don't want a free-at-end outcome set a non-zero `endPrice`.

- **`costOf` returns 0 for both "non-fillable" and "legitimately free" listings** — `DutchAuction.costOf` — Code smells: overloaded zero return value conflates `seller == 0` / bad `take` with genuine `endPrice == 0` free-fill cases — Frontend integrations must disambiguate via `seller != address(0) && getAuction(id).startPrice != 0` etc. Spec smell rather than an exploit path.

  > **Response:** Acknowledged. NatSpec documents "Returns 0 for anything the UI should treat as non-fillable". Frontends that need the "legitimately free" distinction should cross-check `getAuction(id).seller != 0`.

- **Fee-on-transfer / rebasing tokens are scoped out but not enforced** — `DutchAuction.listERC20` — Code smells: `a.initial` / `a.remaining` are set from the requested parameter, not measured from balance delta around `safeTransferFrom` — Explicitly out of scope per NatSpec, but the contract accepts any ERC20 address, so a token whose fee is enabled mid-listing (historical USDT scenario) would price against nominal initial and eventually fail the last fills. Low risk given the disclaimer; no enforcement.

  > **Response:** Acknowledged. Documented as out of scope in the `listERC20` NatSpec. Balance-delta accounting would add gas to every listing for a use case the contract explicitly does not support.

- **Selector overlap between ERC721 and ERC20 `transferFrom`** — `DutchAuction.listNFT` — Code smells: both interfaces share `transferFrom(address,address,uint256)` → `0x23b872dd` — A seller can pass an ERC20 address to `listNFT`, escrowing an `ids[i]`-amount of tokens and having `getAuction(id).isNFT == true`. Frontends relying on `isNFT` to render the lot would misrepresent it. Primarily a UX/UI concern; no new fund-theft path beyond the main finding above.

  > **Response:** Acknowledged. Same class as the main finding (seller-chosen token misrepresentation); frontend due diligence applies. No contract-level defense is possible without an ERC165 probe, which a malicious token can lie on.

---

> ⚠️ This review was performed by an AI assistant. AI analysis can never verify the complete absence of vulnerabilities and no guarantee of security is given. Team security reviews, bug bounty programs, and on-chain monitoring are strongly recommended. For a consultation regarding your projects' security, visit [https://www.pashov.com](https://www.pashov.com)
