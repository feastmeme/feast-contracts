# v1.6.16 — count what was served, gate every average

Receipt for the release handed to AstraSec. Predecessor:
`v1615-scope-and-cost.md`; the round that found this release's work is
`v1615-round-findings.md`. Earlier tags are never moved.

## READ THIS FIRST: the evidence behind this release is single-family

The v1.6.15 round that produced everything below was **Claude-family only, 8 of
8**. All **eight Codex units are `UNMEASURED: usage-limit`** — the provider's
credits ran out on 2026-09-22 and reset on 2026-09-25, after this pack's
deadline. Four units died on the usage-limit error and four were launch-refused
behind them. It is not a content filter and no retry helps.

**This lane's own history says the two families do not find the same things.**
The clearest case is `P17` in the v1.6.14 round: Claude found the zero-cost
freeze on the very lines Codex read and returned NOTHING-FOUND on, and Codex's
reasoning was true and still permitted the defect. Ruling 5 of this release
exists because of that single-family finding.

So: the findings below rest on one family, and this pack is weaker than
v1.6.12–v1.6.14 for that reason alone. **The coordinator will run the Codex half
against this same sealed tag as a dated addendum pack after the reset.** The
auditor should read this pack as complete in its own terms and incomplete in its
coverage, and should expect the addendum.

## The one sentence

v1.6.15 fixed three clocks and the round that followed found a defect in each of
them, including one that retracted a boundary v1.6.15 had written down hours
earlier. v1.6.16 stops correcting the clocks and **removes the quantities a
freeze could spend**: the opening cap counts blocks the pool actually served,
and every read of an oracle average waits for open time — at all three sites,
with a census that fails if a fourth appears.

## 1. The opening cap counts SERVED blocks — ruling 1

`P6-claude` MEDIUM, `P16-claude` MEDIUM. `src/FeastHook.sol`.

The window was a height. A height passes whether or not anybody may trade, so a
freeze spent it. Three releases tried to fix that:

| | what it did | what the next round found |
|---|---|---|
| v1.6.13 | corrected three clocks by report | two more of the same shape |
| v1.6.14 | a frozen-BLOCK counter, to correct the height | a contract cannot observe its chain's block rate; the estimate was short by four on BSC and spent the whole window |
| v1.6.15 | anchored the height at the pool's first SERVED swap | the guardian arms the window with its OWN first trade and freezes in the same block |
| **v1.6.16** | **counts the distinct blocks the pool SERVED** | — |

A frozen block serves no trade, so it does not count. **There is no quantity
left for a freeze to spend.** The code measures the promise — every wallet
capped over a pool's first blocks of trading — instead of a proxy for it.

`Pool.servedBlocks` and `Pool.lastServedBlock` share the slot the height
occupied. Several trades in one block count once. Counting stops at
`CAP_BLOCKS + 1`, so an ordinary trade past the window pays the one SLOAD the
check needs and no SSTORE — the same cost the height had. The creator's pre-buy
counts as no block.

**The retracted boundary is retired, not deleted.** v1.6.15 claimed the excluded
adversary was a guardian that *predicts* a pool's first trade. It does not have
to predict: it makes the trade. The retraction stands in the sweep as the record
of what was claimed and disproved; the claim is no longer load-bearing because
the mechanism it was about is gone.

Byte cost: `FeastHook` 23,955 → 24,409, **margin 621 → 167.**

## 2. The resume instant has a per-pool twin — ruling 2

`P16-claude` MEDIUM, `P5-claude` MEDIUM. `src/FeastGuardian.sol`,
`src/FeastEmissions.sol`.

v1.6.15 stopped settlement trusting a platform price that aged into `Ok` across
frozen time, by requiring a full `TWAP_WINDOW` of OPEN time since
`allUnfrozenAt()`. That instant counts ALL-scope freezes only — the shape owner
ruling 2 introduced the same day — and **a freeze scoped to the platform pool
stops exactly the observations that pool's average is built from.** The defect
came back through the other scope within hours.

`unfrozenAtFor(poolId)` is the per-pool twin, beside `frozenSecondsFor(poolId)`,
and the aging rule reads it.

**The grace still reads `allUnfrozenAt()`**, and that is the point rather than an
oversight: a clock subtracts the scopes that refuse the calls *it* protects, and
nothing but an all-scope freeze refuses `settle`. The two rules on that page
protect different calls and read different instruments. Choosing wrongly between
them is the defect this pair exists to prevent, so the two are named for what
they cover rather than for their scope.

## 3. Every average waits for open time — ruling 3, at all three sites

`P16-claude` LOW as reported. It is the one I would put first.

`FeastHook._requireSpotNearAverage` (the button) and `_spotIsNearAverage` (the
internal fill) read `oracle.twapTick(poolId)` against spot. A freeze writes no
observations, so the average drifts onto the pinned spot with no trade at all,
and a price the bound REFUSED becomes one it accepts while the corrective trades
are prohibited — and the protocol then spends its own bucket into a price nobody
could move.

`FeastEmissions` was given exactly this rule at v1.6.15 and these two sites were
not. **That was the fourth time in this lane a fix went to the site a lens named
rather than to the shape.**

So the shape is enumerated rather than remembered. **`audit/guardian-reads.allow`**
lists every read of a guardian counter or an oracle average in `src/` with its
decision:

| decision | what it asserts |
|---|---|
| `ALL-only` | the calls this protects are refused only by an all-scope freeze |
| `ALL+pool` | refused by an all-scope freeze or by one scoped to its pool |
| `open-time-gated` | an average, read only after a full `TWAP_WINDOW` of open time in that pool |
| `gated-by-consumer` | an average read by a contract holding no guardian; the gate is where it is consumed |
| `external-venue` | an average on a venue this system cannot freeze |

`tools/check-boundaries.py guardian-reads` goes red on an added site, a removed
site, a moved site or an unknown decision. Grep-derived, comments stripped,
negative-controlled three ways. It is the ninth boundary check.

**This is the sweep for the reads a FIX creates.** `freeze-clocks.allow` counts
raw `block.timestamp`/`block.number` and could not have caught either v1.6.15
finding: both were reads of an instrument that already existed, in a place that
needed a different one.

### What it costs, measured

| | |
|---|---|
| plain BUY (does not reach the fill) | **+120 gas** |
| exact-input SELL that reaches the fill | **+3,771 gas**, 1.6% of a 233,465-gas trade |

Counterfactual rather than narrated: removing the fill's gate alone moves
`FeastInternalFillTest.test_aFillNeverTouchesTheQuoteToken` from 370,022 to
366,251 and `test_aFilledSaleReportsTheSellersOwnAmounts` from 363,145 to
359,374 — the same 3,771 in both, which is what one gated fill costs.

The guardian's `allFrozen`, `frozenUntil`, `frozenFrom` and `allUnfrozenTotal`
now share **one slot**, so the gate's question is a warm read of the slot
`isFrozen` already paid for on every trade. The per-pool instant is a mapping
and cannot be packed; that read stays cold.

Per-trade brake: 5,556 → **5,676** on a plain trade.

## A zero resume instant is guarded

`unfrozenAtFor` returns zero when no freeze has ever ended for a pool. Without a
guard, `block.timestamp >= 0 + TWAP_WINDOW` is a claim about the **age of the
chain**, not about open time — true by accident on a live chain and false on a
fresh one. Both gates check for zero explicitly.

## What the fixtures had to change, and why it matters

Rolling blocks no longer leaves a pool's opening window: a mined block that
serves no trade does not count, which is the whole point. `UnitFixture._create`
and `test/utils/CapWarm.sol` serve `CAP_BLOCKS + 1` blocks instead.

That also **restored the gas baseline**, which had silently been measured
*inside* the opening window and read 16,123 against v1.6.7. The real number is
8,432. A fixture that stops meaning what it says is how a gas figure becomes
fiction.

## The mutation gate found three gaps in the tests written for this release

All three the same kind: **a view can be read for a window's length; only a
refusal proves the check uses it.**

- Counting mined blocks instead of served ones makes the window never END, and
  every test asserted that it BEGINS.
- Shortening the check to one served block left every view-based assertion
  passing, because the view was not mutated.
- Reading the all-scope instant for an average was invisible to a PoC that
  asserted on the guardian rather than on settlement.

Closed with `test_theLastBlockOfTheWindowIsStillCapped`, a both-ends walk of the
window, and an end-to-end platform-pool-scoped freeze through settlement.

## Gates

| gate | result |
|---|---|
| suite | **712 passed, 0 failed, 0 skipped** with the fork row (677 at `c4bd770`; 35 added, none removed) |
| mutation | inherited 245 from `c4bd770` · re-ran 10 (changed lines) · new 5 · **caught 10/10** · `KNOWN_UNKILLED` 1 |
| census | ok (31) |
| boundaries | ok, all **nine** checks |
| sizes | `FeastHook` 24,409 of 24,576 — **margin 167** |
| invariants | all **200** named witnesses resolve in `forge test --list` |

## What is still open

1. **`FeastEmissions:379`, the emission cap regime** — RESIDUE. Correcting it
   needs the frozen seconds as of `openAt` and nothing runs at `openAt` to stamp
   them. Two options and a recommendation are in
   `plans/audit/freeze-clock-sweep.md`.
2. **`sink-dust-pins-decay`** (`FeastPlatformSink:300`, `HK19` MEDIUM).
3. **`hop-rounding-amplification`** (`FeastPricer:141`, `HK19` MEDIUM).
4. **`own-brake-extends-own-window`** and **`sunset-unanchored-prefreeze`**
   (`FeastGuardian`, `P19`/`P19-claude` MEDIUM).
5. **`stranger-binds-nontrader`** (`FeastHook:547`, `HK23-claude` LOW),
   **`window-fee-to-codeless-sink`**, **`genesis-does-not-ask-grants-which-guardian`**,
   **`feeless-unpriceable-quote-holds-week`**, **`lp-income-platform-share`**,
   **`sunset-view-misnamed`** — all LOW.
6. **The Codex half of the v1.6.15 round**, scheduled against this tag.

## Two hazards worth the auditor's time

**`via_ir` and `block.number`.** The optimiser reads `NUMBER` once per call
frame — sound on a real chain, wrong under `vm.roll`. Two reads in one function
with a roll between them see one value, silently, with nothing in a `-vvvv`
trace. Every `vm.roll` in `test/` reads through `vm.getBlockNumber()`.
`docs/test-conventions.md` records it.

**A launcher must not write the operator's anchor.** `codex-loop`'s launcher
wrote `state=audit-terminal` over a live `running` anchor while reporting that it
had done nothing, destroying a station boundary. It writes
`.runs/codex-awaiting.json` now.
