# v1.6.17 — one scope

Receipt for the release handed to AstraSec. Predecessor:
`v1616-count-what-was-served.md`; the round that produced this release is
`v1616-round-findings.md`. Earlier tags are never moved.

## READ THIS FIRST: the evidence behind this release is single-family

The v1.6.15 and v1.6.16 rounds both ran **Claude-only, 8 of 8**. All sixteen
Codex units are `UNMEASURED: usage-limit` — the provider's credits ran out on
2026-09-22 and reset on 2026-09-25, after this pack's deadline.

**This lane's own record is that the two families do not find the same things.**
In the v1.6.14 round Claude found a zero-cost freeze on the very lines Codex read
and returned NOTHING-FOUND on, and Codex's reasoning was true and still permitted
the defect. One of the owner rulings shipped in v1.6.15 exists because of that
single finding. The Codex half is scheduled against the sealed tag as a dated
addendum.

## The one sentence

**The pool-scoped freeze is gone.** Five releases redesigned the opening
purchase cap against one shape, and every defeat needed a freeze the guardian
was outside of. A freeze that covers everything refuses the guardian's own
trades too, so it cannot be used to clear a room. ~~The class ends when the
instrument does.~~

> **RETRACTED 2026-09-22, the same day, by the v1.6.17 round.** `P6-claude`
> MEDIUM and `P16-claude` MEDIUM, independently. **The class did not end.** The
> reasoning above was right about scope and wrong about TIME: a freeze may be
> placed in the very block an `unfreeze` cleared, so the guardian does not need
> to be outside a freeze — it only needs to be between two of them. One
> transaction of `unfreeze, trade, freeze` serves an opening block no stranger
> can reach, and the window is spent as before.
>
> RED PoC:
> `test/audit/poc/V1617RoundFindings.t.sol::test_aStrangerCanReachAnOpeningBlockTheGuardianDidNotBracket`.
> Measured cost: one `MIN_FREEZE_CHARGE` per bracketed block — two hours of a
> 168-hour lifetime budget for `CAP_BLOCKS = 2`, every pull on chain.
>
> **CLOSED BY v1.6.18**, ruled the same evening. `freeze` is refused in the block
> an `unfreeze` cleared, so the bracket cannot close in the block it opened: the
> guardian's trade and its re-freeze must fall in different blocks, which leaves
> the block open to every stranger whose transaction lands after the guardian's.
>
> **The bound that remains**: defeating it needs BLOCK-BUILDER COLLUSION, so that
> no stranger is ordered after the guardian in the blocks it serves — and it
> costs twice as much, two `MIN_FREEZE_CHARGE` pulls per bracketed block, so
> `CAP_BLOCKS = 2` costs four hours of a 168-hour lifetime budget.
>
> A guard on the instrument, not a seventh redesign of the cap. The PoC above is
> green and stays as the regression;
> `test_aFreezeIsRefusedInTheBlockAnUnfreezeCleared` is the guard's own test.

## Why, as a table rather than an argument

| release | the cap window was | how it was defeated |
|---|---|---|
| ≤ v1.6.12 | a block height armed at creation | a freeze spent it |
| v1.6.14 | a height in OPEN blocks | a contract cannot observe its chain's block rate; the estimate was short by 4× on BSC |
| v1.6.15 | a height armed at the pool's first served swap | the guardian armed it with its own trade, then froze the pool |
| v1.6.16 | a count of the blocks the pool SERVED | the guardian served them, one wei at a time, freezing between each |
| v1.6.17 | the same count, and **no scoped freeze** | the guardian brackets each block with `unfreeze, trade, freeze` in one transaction |
| **v1.6.18** | as above, plus **no freeze in the block an unfreeze cleared** | — the bracket cannot close in the block it opened |

Each row was found by the round on the release above it. Four corrections in
four releases, each sound in its own terms, each beaten by the same instrument.

## What was removed

`frozenPool`, `_poolFrozenTotal`, `_poolUnfrozenAt`, `frozenSecondsFor(poolId)`,
`unfrozenAtFor(poolId)`, `isFrozen(poolId)`, `allFrozen`, the `all` and `poolId`
arguments of `freeze`, the pool field of `Frozen`, and the overlap rules — there
is nothing left to overlap. `freeze()` takes no arguments.

This **supersedes** owner ruling 2 of 2026-09-22 morning (per-scope accounting)
and the `unfrozenAtFor(poolId)` twin of the coordinator's ruling 2 the same day.
Both were correct for a guardian with two scopes. They are deleted rather than
kept, and the invariants carry dated retirement notes rather than quiet edits.

Every consumer now reads `frozenSeconds()` and `allUnfrozenAt()`. The sink's
descent and floor, settlement's grace, the emission claim grace, the ninety-day
windows and all three open-time-gated oracle reads are refused by the same one
thing, so they may read the same one instant.

## What was kept, exactly

`MIN_FREEZE_CHARGE = 1 hour` (owner ruling 5), the 72-hour grant, the 168-hour
lifetime budget, the served-block count for the opening cap (run-30 ruling 1),
and the open-time condition on every read of an oracle average (run-30
ruling 3).

## Two consequences, both found by tests rather than by reasoning

**1. A freeze now halts coin creation.** `FeastFactory` has always asked
`isFrozenAll`; what changed is that the only freeze answers yes. A pool-scoped
freeze named a pool that already existed and had nothing to say about making a
new one, so the test asserting that had to be rewritten — it now asserts the
opposite, and this is recorded as a **widening of what the brake reaches**, not
slipped in.

**2. An unused parameter cost 1,056 bytes of hook.** Leaving `_requireUnfrozen`'s
`poolId` in place but ignored let the optimiser inline the body at all nine call
sites once it no longer depended on anything, pushing `FeastHook` 889 bytes over
EIP-170. Dropping the parameter brought it back. Measured before and after, not
reasoned about.

## The cost of this change, stated plainly

A defect in one coin's pool can now only be answered by **pausing outflows
everywhere**, and for as long as that lasts no coin can be created either. That
is a real loss of precision. It is the price of the brake being unable to single
anybody out — including in the guardian's own favour.

## Sizes and gas

| | v1.6.16 | v1.6.17 | |
|---|---|---|---|
| `FeastHook` | 24,409 | **24,330** | margin 167 → **246** |
| `FeastGuardian` | 4,275 | **3,430** | −845 |
| `FeastEmissions` | 13,802 | **13,679** | −123 |
| `FeastPlatformSink` | 6,151 | 6,151 | unchanged |

The hook gained only 79 bytes of margin: most of what was deleted lived in the
guardian, and the hook's share was one cold mapping read.

## Gates

| gate | result |
|---|---|
| suite | **709 passed, 0 failed, 0 skipped** with the fork row |
| mutation | inherited 248 · re-ran 5 · new 1 · **caught 5/5** · 3 retired with the code they attacked · `KNOWN_UNKILLED` 1 |
| census | ok (31) |
| boundaries | ok, **nine** checks |
| sizes | `FeastHook` 24,330 of 24,576 — margin **246** |
| invariants | all **198** named witnesses resolve |

The new mutant — *let the guardian trade through its own freeze* — is the whole
ruling in one line: exempting the guardian from the brake it placed restores the
attack exactly, and `V1616RoundFindingsPoC` catches it. Its first draft keyed on
`msg.sender`, which on the swap path is the router, so it survived for the wrong
reason; keyed on `tx.origin` it is caught.

## Two findings carried, with their bounds

Both were reported by the v1.6.16 round and neither is closed here. Each is
recorded at its own site in the source, including the fix that was tried and
did not work.

**`pull-restarts-the-grace`** (`FeastEmissions`, `P17-claude` MEDIUM). A
same-block freeze/unfreeze after the grace has expired re-imposes three more
days, for one hour of budget. The local fix would restart the grace only from a
freeze that actually overlapped the window — which needs the freeze's START as
well as its end, and `frozenFrom` is zeroed by the fold. **Bound:** 168 pulls is
the whole lifetime budget, so the most this buys is about 504 days of DELAY, and
settling late forfeits nothing — `check-boundaries.py settlement-deadline` pins
that there is no upper bound on when a week may be settled. The harm is delay,
not loss.

**`sink-dust-take-restarts-descent`** (`FeastPlatformSink`, `HK19-claude`
MEDIUM). A one-unit take re-anchors the descent, and because the curve is
exponential by halvings and LINEAR inside each one, restarting the clock puts
the price back at the top of a chord and it decays more slowly.
**Measured: 2.03× the honest price after six hours of takes every thirty
minutes.** Launch-relevant, because `/burn` gives anyone the button.

The obvious guard — skip the re-anchor when the sale's own value floors to zero,
the rule the FLOOR has had since v1.6.3 — **was tried and does not bite**: at a
lot of 100e18 units and a Q128 price, one raw unit is still worth about 5e16, so
the value is nonzero and the clock resets anyway. Making the descent memoryless
under re-anchoring means changing how `_price` interpolates inside a half-life,
which is arithmetic three rounds have already audited. **It needs a ruling, not
a patch at the end of a release.** The attempt is recorded in the source so
nobody repeats it.

## Everything else still open

`prelaunch-regime-by-settle-instant` (the RESIDUE carried since v1.6.15, with
its two options in the sweep), `hop-rounding-amplification`,
`stranger-binds-nontrader`, `lp-income-platform-share`, `sunset-view-misnamed`,
`window-fee-to-codeless-sink`, `genesis-does-not-ask-grants-which-guardian`,
`feeless-unpriceable-quote-holds-week` — all LOW or carried, listed with their
classes in the v1.6.15 and v1.6.16 round records.
