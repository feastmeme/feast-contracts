# v1.6.15 — what a freeze reaches, and what a pull costs

Receipt for the release handed to AstraSec. Predecessor:
`v1614-freeze-clock-sweep.md`; the round that found this release's work is
`v1614-round-findings.md`.

`v1.6.14-audit` stays where it is. Tags are never moved.

## The one sentence

v1.6.14 asserted that every clock or block window a freeze can reach measures
open time or open blocks. The round that followed found a defect in **all three**
of the corrections that principle authorised. v1.6.15 fixes them, **withdraws
the block half of the principle** because it cannot be implemented, and adds the
two dimensions the principle never had: **which scope** of freeze a clock
subtracts, and **what a pull costs** the guardian who makes it.

## 1. The floor's clock gets a checkpoint of its own — HIGH, proven

`P3` HIGH, `P16b` HIGH, `P3-claude` MEDIUM. `src/FeastPlatformSink.sol`.

v1.6.14 made `_floorNow` subtract frozen time, and read the floor's clock
(`lastSaleAt`) against the **descent's** checkpoint (`frozenAtAnchor`). Every
take writes the second; only a take that RAISES the floor writes the first. So
after any dust take the pair no longer named the same instant and the frozen
time between the last raising sale and that take was charged to the floor as
open time.

Measured: the floor stood at 5,726,623,062; after one 72-hour freeze and a
purchase of **one raw unit** it read 626,355,612 where 4,294,967,296 was owed.
Anyone may buy one raw unit, so the whole discount v1.6.14 removed was for sale.

`Lot` gains `frozenAtSale`, written inside the same branch as `lastSaleAt` and
cleared with it by `open`. Two docstrings that claimed the pair was written
together — `_floorNow`'s, and the one thirty lines below it — are corrected.

## 2. The block domain is deleted, not estimated — HIGH, proven

`P16-claude` HIGH, `P6-claude` HIGH on the short direction; `P16-claude` LOW,
`P16b` MEDIUM, `HK11b` MEDIUM on the long one. Five units, both families.

`frozenBlocks()` did not count blocks. It estimated them at
`granted / SECONDS_PER_BLOCK` with `SECONDS_PER_BLOCK = 3`. **A contract cannot
observe its chain's block rate.** Measured at BSC's real rate: 86,400 blocks
credited for a freeze that actually stopped 345,598 — short by a factor of four.
`CAP_BLOCKS` is **2**, so at any rate faster than one block per three seconds a
freeze of any length at all spent the entire opening cap window. The v1.6.14
hook fix did not work on the chain it ships to.

The coordinator's ruling withdraws the block half of the v1.6.14 principle:

> A clock a freeze can reach measures **open time** only, and that holds for
> seconds, which are observable on chain. A **block** window must instead be
> anchored on an event a freeze cannot spend.

So the opening cap is armed at a pool's **first served public swap** — one site
for both gated and ungated pools, in `_beforeSwap` — and checked against
ordinary `block.number`. There is no clock between the arming and the check.

Deleted: `frozenBlocks`, `frozenBlockTotal`, `frozenFromBlock`,
`frozenUntilBlock`, `SECONDS_PER_BLOCK`, the block half of `_fold`,
`FeastHook._openBlock`/`openBlock`, and **the guardian call the cap path made on
every trade**.

This also closes the mixed-coordinate defect (`FeastHook:635` armed in wall
blocks while `:890` checked open blocks — five units, both families), because
there is no longer a coordinate to align.

### The meaning change, and the boundary that remains

An ungated pool's cap window now starts at its first served trade rather than at
its creation block. A pool that has not traded has not opened, so this is closer
to P6 as written. The creator's pre-buy does not arm it — it is the creation of
the position, not a public trade.

**Stated rather than left implicit:** once armed the window is wall blocks, so a
freeze placed AFTER the arming and INSIDE the window lets those blocks pass
while swaps are refused.

> ~~With `CAP_BLOCKS = 2` that is a one-block target, and the excluded adversary
> is a guardian that both predicts a pool's first public trade and lands a freeze
> in the next block — it cannot schedule that.~~
>
> **RETRACTED 2026-09-22, the same day, by the v1.6.15 round.** `P6-claude`
> MEDIUM and `P16-claude` MEDIUM, independently. **The guardian does not have to
> predict anything: it makes the first trade itself**, arming the window with its
> own swap and freezing the pool in the same block. RED PoC in
> `test/audit/poc/V1615RoundFindings.t.sol`. What bounds it is owner ruling 5 —
> `MIN_FREEZE_CHARGE` per pool, so at most 168 pools, every one visible on chain.
> The freeze-proof form (counting SERVED blocks) is awaiting a ruling.

This is the ordinary failure of an argument from "it cannot schedule that": the
scheduling was the easy part and the assumption never examined who would make the
first trade.

## 3. Two settlement clocks measure open time, and one cannot

**The pricing grace** (`FeastEmissions:290`, `P5b` HIGH, `P16b` HIGH) runs from
`max(closesAt, guardian.allUnfrozenAt())`. Checkpoint-free: the only freeze that
reaches `settle` is an ALL freeze, and the instant one ends is a single number.
It can only LENGTHEN the strict window, never shorten it, and settling late
forfeits nothing — `check-boundaries.py settlement-deadline` pins that there is
no upper bound. Delay beats zero-counting.

What the grace protects, precisely: a listed quote the oracle cannot price
blocks its week for three days and then **counts as zero, for ever**. That is
the irreversible valuation, and the three days are the whole protection.

**The platform price's aging** (`FeastEmissions:404`, reported at
`FeastOracle:168`, `P16b` MEDIUM). `Moved` means spot has been pushed from the
average and the remedy is to let trading bring them back. A freeze writes no
observations, so the average drifts onto the stale spot with no trade at all and
a price settlement REFUSED ages into one it accepts while the corrective trades
are prohibited. An `Ok` is not trusted until a full `TWAP_WINDOW` of OPEN time
has passed since trading resumed. Corrected at the consumer: `FeastPricer` holds
no guardian reference and giving it one would move every predicted address in
the deployment.

**The cap regime is NOT fixed** (`FeastEmissions:379`, `P16b` HIGH, `P5b`
MEDIUM, `P5-claude` MEDIUM), and the ruling's own prescription was written,
measured and **removed** rather than shipped. Reading the regime against
`max(openAt, allUnfrozenAt())` changes no reachable outcome: `settle` is refused
throughout a live ALL freeze and the stamp folds to the freeze's end, so the
comparison flips true in the same block the brake lifts. That would have been
dead code described as a fix. The correct fix needs the frozen seconds **as of**
`openAt` and nothing runs at `openAt` to stamp them. The row stays RESIDUE in
the sweep with the analysis and two options for the coordinator; what does hold
is the grace plus the aging rule, which keep the regime from being decided
inside a freeze's shadow.

**The fee allowance is ACCEPTED as correct** (`FeastHook:1578`, `P16b` MEDIUM),
with an equivalence rather than a severity judgement: a frozen hour and an idle
hour are the same state — no swap runs in either, `pending` does not move, so
`min(cap, rate × elapsed)` is the same number. The freeze creates no state an
idle pool cannot reach. Pinned by
`test_aFrozenHourAndAnIdleHourLeaveTheSameAllowance`, which asserts identical
allowance, identical bucket and identical first press across the two worlds. No
hook bytes spent.

## 4. A scoped freeze keeps its own clock — owner ruling 2

`P16b` HIGH against P27; `P16-claude` MEDIUM and LOW, `P6-claude` MEDIUM,
`HK11b` MEDIUM, `HK11-claude` LOW. Five units, both families.

Every clock in the system subtracted one global counter, and `take` and `settle`
are refused **only** under an ALL freeze. So a freeze on one coin's pool held
the price of every lot in the sink and stopped clocks in pools that were trading
normally: the guardian moving a price, which is exactly what P27 forbids.

`frozenTotal` is fed by ALL-scope freezes only; `_poolFrozenTotal[poolId]` by
scoped ones; `frozenSecondsFor(poolId)` reads both, for a pool-keyed clock. The
rule is a table in the sweep: **a clock subtracts exactly the scopes that refuse
the calls it protects.**

**No clock is in the pool-keyed row today.** Once the opening cap was anchored
on a pool's first served swap, the hook kept no clock a freeze can reach. The
counter exists so that a scoped freeze's time is recorded somewhere P27 can be
checked against on chain, and so the next pool-keyed clock finds the right
instrument instead of reaching for the global one. That it has no consumer is
written beside the field.

**Overlap is prevented, not apportioned.** `freeze` already refuses while
another freeze is live, in either direction, so no second of downtime can be
counted against two scopes. The fold-and-refund path the ruling described for
concurrent pool freezes was **not built**: the single-live-freeze invariant means
that state cannot exist. Both directions are pinned instead.

## 5. A pull costs an hour — owner ruling 5

`P17-claude` MEDIUM. Codex `P17` read the same lines and returned
NOTHING-FOUND; its reasoning — that only the unused tail is refunded — is true
and still permits this. A real divergence between the families, and the edge is
the same second.

`unfreeze` refunded the whole unused tail, so a freeze lifted in the second it
was placed cost nothing and folded nothing — and a freeze/unfreeze pair per
block refused every guarded call ordered between them for ever, with the
168-hour lifetime bound not binding the one thing it exists to bound.

`MIN_FREEZE_CHARGE = 1 hour` is charged whatever happens. The budget now bounds
the **count** as well as the duration: **at most 168 pulls** over the guardian's
life.

The minimum binds the **budget**, never the clocks. `_fold` still counts the
seconds actually frozen, so a one-second freeze delays every deadline by one
second and not by an hour. Those are different quantities and they are kept
apart deliberately.

**Operational consequence, recorded because the owner asked for it:** the brake
is an emergency instrument and every pull costs an hour of budget. Any automated
caller must expect that. Checked before the constant landed — there is no
`freeze` call anywhere in `src/`, `script/` or this repository's documents
outside the tests, so no existing caller's economics changed silently.

## What this release cost, measured

| | v1.6.14 | v1.6.15 | |
|---|---|---|---|
| `FeastHook` runtime | 24,223 | **23,955** | margin 353 → **621** |
| `FeastGuardian` | 3,900 | 3,990 | +90 net: −606 block domain, +458 scope and charge, +238 `allUnfrozenAt` |
| `FeastPlatformSink` | 6,113 | 6,151 | +38, the floor's own checkpoint |
| `FeastEmissions` | 13,425 | 13,644 | +219, the grace bound and the aging rule |
| per-trade brake | 8,430 gas | **5,556** | 2.4% of a 233,345-gas plain trade |

The 182 gas above v1.6.13's 5,374 is **not attributed**. The counterfactual was
run rather than narrated: short-circuiting the new arming branch so its
`capEndBlock` read cannot happen measures 8,337 against 8,312 with the branch
live — 25 gas MORE, and in the wrong direction. The branch costs nothing
measurable on an ordinary trade. Whatever the 182 is, it is not that read, and
this table does not guess.

## Gates

| gate | result |
|---|---|
| suite | **677 passed, 0 failed, 0 skipped** with the fork row (630 at `f599310`; 47 added, none removed) |
| mutation | inherited 234 from `f599310` · re-ran 16 (changed lines) · new 6 · **caught 16/16** · `KNOWN_UNKILLED` 1 |
| census | ok |
| boundaries | ok, all **eight** checks |
| sizes | `FeastHook` 23,955 of 24,576 — **margin 621** |
| invariants | all 186 named test witnesses resolve in `forge test --list`; the 6 `invariant_*` entries are present as invariant functions |

The mutation gate is **incremental** by coordinator lever. Every mutant whose
anchor overlaps a changed line of `f599310..HEAD` under `src/` was re-run, plus
every new one; the rest inherit their baseline verdict. The inheritance argument
is stated so it can be checked: the test set only **grew**, and the inherited
mutants' code lines did not move. `tools/mutate.py --names-from` is the selector,
and a name matching no mutation is an error rather than a silent skip.

**The gate earned its keep this release.** One of the 16 survived: my first
witness for the pricing grace asserted the refusal through a MOVED platform
price, which after launch refuses settlement past the grace anyway — so the
revert came from that rule and not from the grace, and the test could not see
the mutation at all. `graceOver` binds in exactly two places and the one that
loses value is the unpriceable quote. Rewritten onto that path; re-run; caught.

## What the v1.6.15 round found — read this before the list below

The round ran on this tree (`c4bd770`) after everything above was written, and it
found **two of this release's own claims**, both verified with red PoCs:

1. **The cap window's stated boundary is not a boundary** (above). Retracted the
   same day it was written.
2. **`allUnfrozenAt()` counts ALL-scope freezes only, and a pool-scoped freeze on
   the PLATFORM pool stops exactly the observations the platform price's average
   is built from** (`P16-claude` MEDIUM, `P5-claude` MEDIUM). So §3's aging rule
   — written this release to stop a freeze ageing a refused price into an
   accepted one — is reachable again through the scope owner ruling 2 introduced
   on the same day. It needs `unfrozenAtFor(poolId)`, the resume instant's
   per-pool twin. RED PoC.
3. And, by reading: `FeastHook._requireSpotNearAverage` at `:1717`, used by the
   buy-back button and the internal fill, reads **the same extrapolated average**
   that `FeastEmissions:413` now refuses to trust after a freeze, and was not
   corrected (`P16-claude` LOW). **This is the fourth time in this lane that a fix
   has gone to the site a lens named rather than to the shape.** It should be
   fixed at all three sites at once or at none.

The round was **CLAUDE-FAMILY ONLY, 8 of 8**. The Codex family is out of credits
until 2026-09-25, which is past this pack's deadline; all eight Codex units are
`UNMEASURED: usage-limit`. That is a real weakening of this release's evidence
and it is stated here rather than in a footnote: every finding above rests on one
family, and the v1.6.12–v1.6.14 history shows the two families do not find the
same things — `P17` is the clearest case, where Claude found the zero-cost freeze
on lines Codex read and cleared.

## What is still open

0. **The three above**, of which two are proven and none is fixed.
1. **`FeastEmissions:379`, the cap regime** — RESIDUE, with the analysis and two
   options in `plans/audit/freeze-clock-sweep.md`. My recommendation is to
   accept it with the bound stated rather than add a permissionless `markOpen()`
   poke, because the poke buys exactness at the price of a liveness assumption
   this codebase has otherwise avoided.
2. **`sink-dust-pins-decay`** (`FeastPlatformSink:300`, `HK19` MEDIUM) — new in
   the v1.6.14 round and not a freeze clock: repeated dust purchases discard
   fractional decay and hold the descent flat. Same adversary as §1.
3. **`hop-rounding-amplification`** (`FeastPricer:141`, `HK19` MEDIUM) —
   pre-existing, reported in the v1.6.13 round too.
4. **`stranger-binds-nontrader`** (`FeastHook:547`, `HK23-claude` LOW).
5. **`lp-income-platform-share`** (`FeastHook:1767`, `P3-claude` LOW) —
   pre-existing since round 1.
6. **`sunset-unanchored-prefreeze`** (`FeastGuardian:320`, `P19` and
   `P19-claude` MEDIUM) — frozen seconds spent before genesis extend the
   partner window. An artefact of the v1.6.13 fix, carried.

## A test-harness hazard, for the auditor

Under `via_ir = true` the optimiser common-subexpression-eliminates the `NUMBER`
opcode across a call frame — sound on a real chain, where the height cannot move
inside a transaction, and wrong under `vm.roll`. Two reads of `block.number` in
one function with a `vm.roll` between them see **one** value, silently, with no
warning and nothing visible in a `-vvvv` trace; two consecutive
`vm.roll(block.number + n)` calls therefore roll to the same height and the
second is a no-op. Every `vm.roll` in `test/` now reads through
`vm.getBlockNumber()`. `docs/test-conventions.md` records it. This is a test
hazard, not a contract defect, and it is named here because it could equally
have made one of ours pass while the property was false.
