# Planned swap: ZorgReceiptArt + ZorgConvictionRenderer

Not urgent, and nothing here is a correctness bug. Every item is copy that a
holder will read wrong, on contracts that are already live. Both are swappable
by Moloch proposal — `setReceiptArt` and `setRenderer` are `onlyDAO`, both
require the target to have code, and `tokenURI`/`html()` delegate live — so
this needs no governor redeploy and applies retroactively to every existing
receipt.

## Why now-ish rather than never

The system is being explained in public. Five of the fifteen traits on a live
receipt are actively misleading, and #9953 — the first bond, the one people will
click — has four of them showing `0` for four different reasons.

## ZorgReceiptArt

| trait | today | problem | proposed |
| --- | --- | --- | --- |
| `ETH principal` | `0 wei` on eternal | reads as "lost" or "never paid". It was donated. | `donated to treasury` when `eternalBonds`, else the amount |
| `ETH maturity` | `1786651823` | a raw unix timestamp in a wallet trait list | an ISO date; `none (eternal)` when the bond is eternal |
| `ETH loyalty accrued` | `0 wei` | wei on a value that is almost always sub-milli-ETH | ETH with enough decimals to be readable |
| `Early exit tax` | `2000 bps` on eternal | there is no exit; the trait implies one exists at 20% | suppress both tax traits when eternal |
| `Treasury tax share` | `5000 bps` on eternal | same | same |
| `Bonded` / `Allocated` / `Effective active support` | raw wei | 10000000000000000000000 | whole zOrg |
| `Bond age` | `86652 seconds` | recomputed per read, so marketplace caches always disagree, and it is meaningless in a rarity table | days, or drop it |

Deliberately NOT changed: `Lock tier 0` / `Support boost 10000 bps` on #9953.
That is real state in an immutable governor and the art must not flatter it.

## ZorgConvictionRenderer

The onchain page. Same two-clock problem the zList wizard had (fixed there in
`0a9a4a6`, worth porting):

- Distinguish the ETH maturity from the lock tier wherever both appear. Maturity
  decides whether an exit is **taxed**; the tier decides whether it is
  **permitted**. A tier-3 bond is locked ~358 days past its own maturity.
- The eternalize control should state that the ETH principal is donated, not
  held. It currently reads as if the deposit survives the transition.
- Show the loyalty split as what it is — a claim on other people's early exits,
  pro-rata on RAW weight — so nobody expects the 1.50x boost to apply to it.

## Sequencing

`setReceiptArt` and `setRenderer` are independent; neither depends on the other,
and both are pure read surfaces. Worth checking first whether the Moloch's
`multicall` composes with `queue`/`executeByVotes`, because if it does these ride
in one proposal instead of two — with `timelockDelay` and `proposalTTL` both at
86400, two proposals means two separate 24-hour execution windows to hit.

## Cost of getting it wrong

Low. A bad art contract degrades metadata; it cannot touch escrow, and
`setReceiptArt` can be called again. The one hard rule is that it must never
revert for a receipt that exists — `test/ZorgReceiptArtAdversarial.t.sol` is the
guard, and any replacement should be run against it before proposing.
