# v1.6.20 — the round's two HIGHs, and what a sale is a share of

Receipt for the release handed to AstraSec. Predecessor: `v1619-two-fixes.md`.
Earlier tags are never moved.

## The one sentence

The v1.6.19 double-family round found **two HIGHs** — one of them inside
v1.6.19's own fix 2, the fifth consecutive release with a defect in its own fix
— and the owner ruled both fixed before the auditor sees anything, together with
the residual the first fix would otherwise have carried.

## 1. `HK19` — a bound argued from one call is not a bound over a sequence

Codex family, against `FeastPlatformSink.sol:499`: the line v1.6.19's fix 2 had
just added.

Fix 2 made the descent memoryless by growing the anchor by the share a sale
took, `lot.anchor += mulDiv(lot.anchor, amountOut, held)`, and the comment above
it bounded that growth: `amountOut <= held` is enforced, so the sum is at most
double, *"and doubling it needs a take of the WHOLE remaining lot, and that take
ends the lot."*

Both halves are true of the **call**. Neither is true of the **lot**. `held` is
not stored — `take` re-reads `balanceOf(address(this))` live — and
`_pricesThisLot` keeps the same descent over a band that `lot.offered` only
ratchets down and widens. A take followed by a refill never ends the lot; `open`
keeps answering `AlreadyOpened`.

Measured at `v1.6.19-audit`:

| | |
|---|---|
| rounds of refill-and-take before the panic | **154** |
| platform coin spent | **154 wei** |
| asset spent | **0** — the stake comes straight back out each round |
| of the lot still sellable afterwards | **6.01 %** |
| of the lot beyond every buyer | **93.99 %**, with `open` still refusing |

> **Where the verdict overstated, recorded so nobody re-derives it.** It asserts
> `take(asset, 1, 1)` reverts afterwards. It does not: one unit of a 100e18 lot
> adds `anchor / 1e20`, which still fits. The strand is a **ceiling**, not a
> brick — and the greedy 6% slice is what pushes the anchor to the top of the
> word so that nothing at all can be taken after it.

**The obvious repair was also wrong.** The first draft enforced exactly what the
comment claimed — at most double the price `open` anchors at — and broke
`test_aRefillIsPricedFromTheTopButNeverUnderTheFloor` (v1.6.2), which takes half
the lot twelve times with **no refill anywhere** and asserts ~129×, because the
growth compounds down a shrinking lot. In the limit of small takes the product
approaches the lot's raw unit count, so for an 18-decimal asset no ceiling drawn
from the sale arithmetic is both above every honest sequence and below a word.

So the bound comes from the **money**, using a measurement already in `take`:
the coin's entire `1e27` supply buys 54 210 108 raw units at the opening price,
so at `2^32` times that price the whole supply buys about a hundredth of one raw
unit. `ANCHOR_CEILING = SINK_START_PRICE_Q128 << 32`, clamped with `Math.min`.
No overflow, by induction in one line: `open` sets `anchor = 2^192 <= CEILING`,
the clamp restores it, and `amountOut <= held` makes the added term at most
`anchor`, so the pre-clamp sum is at most `2^225`.

PoC `test/audit/poc/SinkAnchorGrowthOverflow.t.sol`, red at `4c49475`.

## 2. `P12` — genesis at the closing second revives a refunding window

Codex family, against `FeastFactory.sol:380`.

`refund` clears `committed[account]` and leaves `total` standing — sound exactly
as long as a refunded window can never settle again. Before genesis the gate has
no opener, so from `endsAt` onward `_refundable()` is true and commits start
leaving. Genesis then registers `opener = window` and `openAt = endsAt +
SETTLE_GRACE`, which makes `_canSettle()` true again.

The revived auction divides its tranche by a denominator that still counts
weight which has left, the `claimedWeight == total` remainder path can never
fire, and the difference is coin nobody can claim: **150 000 000 FEAST of a
300 000 000 tranche, measured.**

The fix is one operator: the window's close must be **strictly** ahead of the
genesis call. Genesis before the close is safe — the gate is already set at
`endsAt`, so `_canSettle()` holds and refunds never open — and genesis after it
was already refused. That one second was the whole gap, and the control test
`test_oneSecondLaterGenesisIsRefused` passes on both trees to prove it.

> **The Claude `P12` unit's NOTHING-FOUND is not contradicted.** It reports that
> settle and refund are exclusive at every second. That is true, before the fix
> and after it: `_canSettle` and `_refundable` are exact complements. What moves
> is not the predicate but the **gate underneath it**, and only genesis can move
> that. The unit read the pair and not its input.

PoC `test/audit/poc/RefundedWeightRevival.t.sol`, red at `4c49475`.

## 3. A sale moves the curve by what it took out of the lot

The ceiling in §1 stops the pump from overflowing the anchor. It does not stop
the pump: 78 rounds and 78 wei still walk the anchor to `2^224` (measured), and
the descent needs 32 half-lives — 32 hours — to bring it back, with nobody able
to buy at a sane price meanwhile and the sequence renewable. The owner ruled it
closed by design rather than carried.

`amountOut / held` is the share of the **balance** a sale carried away, and the
balance is not the lot. Units a caller puts in and takes straight back out are
not a sale of anything — the platform ends up holding exactly what it held.
`priced - remaining` is what the **lot** lost, so recycled inventory now scores
exactly zero: 100 rounds leave the anchor precisely where `open` set it.

> **This is deliberately not the change the v1.6.19 anchor proposed**, and the
> reason is in the source. That one was to tighten `_pricesThisLot`'s band so a
> lot which grew at all stopped being priced by its descent. It is worse: the
> band's upper tolerance is exactly what stops a **one wei** donation from
> making `_price` fall back to the start price. Tightening it to equality would
> have traded a 78-round pump for an instant one-wei price reset anybody could
> repeat — a cheaper attack than the one being closed, and on the published
> price rather than on the anchor. The band is unchanged.

Nothing on the honest path changes: inside the band the sink's own writes leave
`held == offered`, so `priced - remaining` **is** `amountOut`. It differs only
when `held > offered`, and only ever downward. Every existing sink witness is
green as written.

**The bound that remains.** A sale can raise the curve only by consuming the
lot, and that compounds down a shrinking lot the way v1.6.2 documented: **899
takes of 2.5% reach `ANCHOR_CEILING` with no refill anywhere**. The ceiling
stays as the overflow backstop, because that sequence is still permitted and a
large enough lot in small enough slices would otherwise reach a word.

> **The ceiling's witness had to be rewritten to keep reaching its bound.** With
> the pump dead, the old trajectory test asserted a ceiling it could no longer
> approach — a test that passes because the curve never moves. It is replaced by
> `test_honestCompoundingStopsAtTheCeilingInsteadOfAWord`, the 899-take drain,
> which reaches `2^224` exactly.

PoC `test/audit/poc/RecycledInventoryCannotMoveTheCurve.t.sol`, red before.

## 4. What the release gate says

| check | result |
|---|---|
| suite | **726 passed, 0 failed, 0 skipped** with the fork row |
| boundaries | 9 of 9 |
| census | every row resolves |
| sizes | hook **24,330** (margin **246**), factory 21,355 (3,221), sink 6,139 (18,437) |

## 5. Two things the gate itself got wrong, and now does not

**A mutant that was never applied.** `let a freeze be extended by refreezing
(v1.6.12)` anchors on a line that v1.6.19's own `settleLapsed` made a second
copy of. `mutate.py` refuses an ambiguous anchor — so that mutation was never
run during the v1.6.19 sweep, and its reported **256 of 257 was 255 actually
exercised**. Six more sink anchors were moved by this release's own edits; a
stale anchor is reported `SKIP` and counted as a survivor. All 260 are now
re-validated to match exactly once.

**A tool that swept on a typo.** `mutate.py` ignored unrecognised arguments, so
`--help` ran the full sweep and `--name-from` swept all 260 instead of the 51
meant. An unknown flag is now a refusal. The guard is a pure function because
**the first draft of its own self-test shelled out with `--slice 1/4`, started a
real sweep over the operator's worktree, and was killed mid-mutation by its own
timeout** — the accident the guard exists to prevent, committed by the test for
the guard.
