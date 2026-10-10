# v1.6.14 — every clock a freeze can reach

Task 567. Supersedes `v1613-round-findings.md`, which was never handed over.
`v1.6.13-audit` stays where it is; tags are not moved.

**What happened, in one paragraph.** v1.6.12 added a guardian. The round on it
found that a freeze stopped the sink's buyers without stopping the sink's
descent, so seventy-two hours of brake halved the price seventy-two times and the
guardian could buy at the number its own pause produced. v1.6.13 fixed that and
two clocks beside it — the ones the ruling named. The round on **that** found two
more of exactly the same shape, in the same two contracts, because the fix had
gone to the sites that were reported rather than to the shape. v1.6.14 fixes
those two and, more importantly, **enumerates every clock in the tree** so there
cannot be a fourth round of this.

## The two findings

### HIGH — the sink's floor decayed through a freeze

`P3` (HIGH), `P16-claude` (HIGH), `P16b` (HIGH), `P3-claude` (MEDIUM) — four
units, both families. `_floorNow` read `block.timestamp - lot.lastSaleAt`. `take`
is frozen; the floor was not. **Measured: the floor fell from 5,726,623,062 to
715,834,097 across one 72-hour freeze — a factor of eight.** It is the discount
the descent gave before v1.6.13, arriving through the other half of the price.

Fixed by subtracting the same checkpoint the descent uses. `take` and `open`
write `lastSaleAt` and `frozenAtAnchor` together, so one checkpoint serves both
clocks and there is no state in which the floor has a clock the descent does not.
The 2026-09-13 ruling — the floor declines slowly and is never pushed down by a
take — is untouched.

### HIGH — a freeze spent the opening cap's block window

`P6` (HIGH), `P16b` (HIGH), `P6-claude` (MEDIUM) — three units, both families.
The cap is a window of BLOCKS armed when a pool opens; the chain keeps mining
while every swap is refused, so a freeze spanning the opening blocks spent it and
the first buyer afterwards was uncapped. A GATED pool was never exposed — the
v1.6.10 fix arms its cap at its first public swap — which is why the PoC uses an
ordinary coin.

Fixed by counting **open blocks**. The guardian gains `frozenBlocks()`, the
block-domain twin of `frozenSeconds()`; the ruling is explicit that each
mechanism keeps its unit and has its clock corrected rather than converted.

**`frozenBlocks()` estimates its tail, deliberately.** A live freeze's end is
known in seconds and how many blocks that is depends on how fast the chain runs.
A freeze that LAPSES is credited the blocks BSC's fixed target implies, capped at
the blocks actually mined; an early `unfreeze` needs no estimate at all. If the
chain runs slower than target the credit is slightly low — which *shortens* the
cap window, the safe direction for the mechanism it protects.

## The sweep, which is the real deliverable

`plans/audit/freeze-clock-sweep.md` classifies all **72** reads of
`block.timestamp` / `block.number` under `src/` by mechanism: INVARIANT (a freeze
cannot reach it, with the reason), FIXED-1613, FIXED-NOW, RUNS (deliberately,
with the promise that allows it). `tools/check-boundaries.py freeze-clocks`
counts them per file against `audit/freeze-clocks.allow` and fails when the count
moves, so a clock cannot be added without being classified.

**Two residues are named there and are not fixed**, because each needs a
decision rather than a patch:

- **settlement's three-day pricing grace** — a freeze spanning it moves a week
  from the strict branch to the tolerant one, lowering that week's emissions. The
  correction needs a checkpoint at the instant the week closed, and no
  transaction happens then.
- **the fee allowance accrual** — a rate limiter that accrues while every path
  that spends it is frozen, so a 72-hour freeze becomes spendable at once. Its
  own cap bounds the damage, which is an argument about severity rather than a
  classification.

## The hook did not fit, and nothing was cut

The first encoding — a wall-block number plus a per-pool checkpoint — put
`FeastHook` at **24,705, over EIP-170 by 129 bytes**. Storing the window in
open-block coordinates instead is one storage field and one subtraction cheaper
and identical in behaviour: **24,223, margin 353** (it was 642). `capEndBlock()`
returns that coordinate and `openBlock()` is exposed beside it so a reader
compares like with like.

Per-trade gas for the brake: **5,374 → 8,430**, because `_afterSwap` asks the
guardian a second question. The account is warm by then, so the second read costs
less than the first. 3.6% of a plain trade, reported rather than optimised away.

| Contract | Bytes | Δ | margin |
|---|---:|---:|---:|
| `FeastHook` | 24,223 | +289 | **353** |
| `FeastGuardian` | 3,900 | +606 | 20,676 |
| `FeastPlatformSink` | 6,113 | +190 | 18,463 |
