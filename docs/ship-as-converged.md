# Ship as converged — a cut proposal for internal v1

**Status: proposal. Nothing here is done. It needs ratification before any code moves.**

Written 2026-09-09, after round 5, under the convergence cap: *if round 5 does
not bring both lenses to HIGH ≤ 2 with no new family, do not start round 6 —
write a cut proposal and stop.*

Round 5 returned **HIGH=4** (coverage) and **HIGH=4** (endorsement). Four is
more than two. **The cap fired.**

---

## 1. Where five rounds actually got to

| Round | Coverage | Endorsement | What moved |
|---|---|---|---|
| 1 | HIGH=10 | HIGH=7 | endorsement refused; twelve HIGH classes |
| 2 | HIGH=7 | HIGH=6 | six classes closed structurally, six only patched |
| 3 | HIGH=6 | HIGH=5 | Rule 8 fired on the partial-fill remainder |
| 4 | HIGH=6 | HIGH=6 | reentrancy closed; the round-3 fix had introduced two defects of its own |
| 5 | HIGH=4 | HIGH=4 | remainder class and donation brick both closed structurally |

Round 5 is the best round of the five: two classes closed at once, both lenses
agree on the same remaining four, and **no new HIGH family appeared**. The two
items marked "Fresh" are a MEDIUM and a LOW.

It is still not two consecutive clean rounds, and the trend does not obviously
reach there: the four that remain are the four that have survived every round
since round 2. They are not oversights. Each is a genuine design question that a
fix would have to answer, and three of them concern one subsystem.

## 2. The four remaining HIGHs, and where they live

Both lenses name the same four, in the same order.

| # | Finding | Lives in |
|---|---|---|
| H1 | Permissionless conversion accepts attacker-selected routes: an attacker supplying genuine, mature Q/X and X/WBNB pools can take valuable quote and leave negligible native, passing every per-hop check because the expectation is built from *their own* pools' prices | `FeastConverter`, reached with **protocol money** only through `convertPlatformQuote` |
| H2 | A WBNB-denominated platform bucket has no spending path at all: an empty route is refused, a non-empty route must end in WBNB, and no hop may revisit the input token — mutually exclusive for WBNB input | `convertPlatformQuote` |
| H3 | Positive dust occupies the hourly interval: a press producing a few raw units succeeds, consumes the hour, and blocks the productive press behind it, repeatable at every expiry | **all three buttons**, including the self-burn one |
| H4 | Finalisation can erase a whole funded pot: `floor(accrued × 1e27 / totalFees)` is zero when fees are large and funding is small, and the funding is cleared regardless | `FeastEpochRewards.finalise` |

## 3. The proposed cut

**Ships in internal v1**

- `FeastFactory` — one transaction: coin, pool, permanently locked liquidity
- `FeastToken` — fixed supply, no owner, no mint path
- `FeastHook` — the 1% take on the quote leg, the four-way split, the opening
  caps, the oracle, the permanent lock
- Creator-side entitlement in full: creator, referrer and vesting claims, **in
  the quote token**
- `collectLpFees`
- `buyBackAndBurn` — the self-burn button
- `FeastEpochRewards` — **as a recording ledger only.** See §4.
- Governance over `burnShareBps`

**Behind a declared boundary until v1.1**

- `convertPlatformQuote`
- `platformBuyBack`
- `claimAsBnb` — see §5, this one is a judgement call

The platform share still accrues. The 20% is taken, banked, and visible in
`platformPending`; it simply has no button to spend it until v1.1. Nothing is
lost and nothing is stranded — the entitlement is recorded and monotone, and the
v1.1 buttons spend exactly what v1 accumulated.

## 4. What the cut actually removes — and what it does not

This is the part that matters, and it is not as clean as "cut the buttons, get a
clean core".

| # | Removed by the cut? | Why |
|---|---|---|
| H1 | **Yes**, for protocol money | The only path that spends *the protocol's* funds through a caller-chosen route is `convertPlatformQuote`. Cut it and no permissionless caller can route protocol money anywhere. |
| H2 | **Yes** | The contradiction is inside `convertPlatformQuote`. With no conversion, a WBNB-quoted platform bucket simply accrues, which is now the declared design rather than an accident. |
| H3 | **NO — this one survives** | It affects `buyBackAndBurn`, which ships. See §6. |
| H4 | **Yes, by construction** | `creditPot` has exactly one caller in the entire tree: `platformBuyBack` (`src/FeastHook.sol:966`). `creditPotClosed` has none. With both buttons cut, **no pot can ever be funded**, so no pot can ever be truncated. |

**The cut removes three of the four HIGHs by removing the code they live in.**
That is a real result and also a modest one: it is a reduction in scope, not a
proof of correctness. The subsystem being deferred is the one that has produced
most of the findings in every round since round 2, which is the honest argument
*for* deferring it.

## 5. Two consequences to say out loud rather than bury

**(a) The epoch pot ships as a ledger that pays nothing.** `epochRewards.record`
still runs on every fee (`src/FeastHook.sol:1035`), so v1 accumulates a complete,
per-epoch, per-quote record of who paid what. But the only thing that ever puts
*value* into a pot is the buy-back button, which is cut. So in v1 the pot is
attribution without payout: correct, useful as the substrate v1.1 pays out
against, and **not a working rewards feature**. If the internal v1 is meant to
demonstrate rewards paying out, this cut does not deliver that, and the plan
should say so in those words rather than listing "epoch pot" as shipped.

**(b) `claimAsBnb` is a judgement call, not an obvious cut.** It is the other
caller of the converter (`src/FeastHook.sol:743`), so H1's machinery is reachable
through it. But the difference is the one the `route-authority` invariant exists
to capture: **the claimant picks the route and the claimant eats the loss**. No
one can route another person's claim (`test_onlyTheClaimantMayChooseTheirOwnConversionRoute`),
and claiming in the quote token always works and is the default. H2 also touches
it, narrowly, for a WBNB-quoted pool.

My recommendation is to **keep `claimAsBnb`** and declare the boundary: it is a
convenience whose only victim is the person who chose it, and removing it costs a
real feature to close nothing that route-authority does not already close. If
you would rather ship the smallest possible surface, cutting it is defensible and
costs creators only the convenience of being paid in BNB rather than in stock.

## 6. The one decision I need from you

**H3 survives the cut, on `buyBackAndBurn`.** A caller can front-run a productive
press with one that buys a few raw units, succeed, consume the hour, and repeat
at every expiry — suppressing the self-burn indefinitely for the price of gas.

It cannot steal anything. Nothing is lost, mis-recorded, or made unreachable; the
bucket keeps growing and the burn is delayed, not cancelled. It is a
denial-of-service on a button, by someone paying gas to achieve nothing but
delay.

Two ways to go, and I do not think this is mine to pick:

- **(a) Accept and declare it.** Ship with H3 written into the boundaries section
  as a known, bounded nuisance with no path to loss. Fastest; internal v1 is for
  learning whether the mechanism works, and a griefer delaying burns does not
  stop that.
- **(b) Fix it first — one bounded change.** Require meaningful progress before
  the interval is consumed: a press must produce output worth at least some
  fraction of what it spent, rather than merely non-zero. One predicate, applied
  at all three buttons, in the shape the census already has a section for
  (`button-progress`). It also closes r5a's fresh **M1**, where a bucket of a few
  raw units becomes permanently unspendable because the 20% ceiling rounds to one
  and a one-unit swap returns zero.

I lean to **(b)**: it is a single predicate at a site the census already tracks,
it closes a HIGH and a fresh MEDIUM together, and "the burn button can be jammed
by anyone for the price of gas" is an awkward property to explain about a product
whose headline is that it burns. But it is one more change on a tree that has
twice now been made worse by a fix, so shipping (a) and fixing it in v1.1 with a
proper fixture is a legitimate call.

## 7. What this proposal does not touch

- **The human verification gate stands.** Nothing here is done, and none of it is
  `/done`. Ratification is yours; archiving is the owner's.
- **No mainnet, no keys, no deployment.** Internal v1 means the tree and its
  tests, on the pinned fork.
- **No weakening of any invariant.** The cut removes *reachable surface*; every
  invariant that survives applies exactly as before, and `tools/check-census.py`
  still requires all nineteen mechanisms to be enumerated and tested.
- **The deferred code is not deleted.** It stays in the tree, tested, behind a
  documented boundary, so v1.1 resumes from round 5's position rather than from
  scratch.

## 8. If you would rather not cut

The alternative is a round-6 fix pass at the four remaining classes. My honest
estimate: H3 and H4 are each a bounded change (a progress predicate; full-precision
cumulative entitlement instead of a truncating index). **H1 is not** — "bound
protocol spending against a valuation the router does not control" is a design
question with no cheap answer, and it is the class that has survived four rounds
of attempts. H2 is easy in isolation and only exists because of H1's subsystem.

That is the case for the cut: three of the four go away by deferring one
subsystem, and the one that stays is the cheapest of the four to fix.
