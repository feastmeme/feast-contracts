# v1.6.14 focused re-round — what it found

Tree: `v1.6.14-audit` at `f5993101a4feeaf620291ae6e4d0c96c2ddca105`.
Workdir: `.runs/lens-v1614`. Date: 2026-09-22.

Ten classes, two families, **19 of 20 verdicts**. Codex `P6` died to the
provider's content filter twice — the original header and one rephrasing — and
per the standing rule there was no third attempt: it is recorded
`UNMEASURED: provider-content-filter`. Codex `P5`, `P16` and `HK11` died the
same way on the first header and were recovered on the rephrased one as `P5b`,
`P16b` and `HK11b`; those three units read different bytes from their Claude
counterparts and the divergence is stated here and in the pack.

| class | codex | claude |
|---|---|---|
| P3 sink / no house bag | DONE | DONE |
| P5 emissions | DONE (as `P5b`) | DONE |
| P6 opening cap / pre-buy | **UNMEASURED: provider-content-filter** | DONE |
| P13 fee accounting | DONE | DONE |
| P16 the guardian moves nothing | DONE (as `P16b`) | DONE |
| P17 the brake is bounded | DONE | DONE |
| P19 partner slots | DONE | DONE |
| HK11 reverts in peripheral hook logic | DONE (as `HK11b`) | DONE |
| HK19 rounding / precision | DONE | DONE |
| HK23 router parameters | DONE | DONE |

## What it is about

**All three of the changes v1.6.14 made are defective**, and the round found
each of them independently in both families. This is the third consecutive
round in which a freeze-clock fix was found to be incomplete, and it is the
first in which the defects are *in the corrections themselves* rather than at
sites the previous fix did not reach.

`test/audit/poc/FreezeClockFixesLeftThreeGaps.t.sol` holds the three PoCs. All
three are RED at `16b609e` and `src/` is untouched.

### 1. The sink's floor loses its frozen credit to a dust take — PROVEN, HIGH

`P3` HIGH, `P16b` HIGH, `P3-claude` MEDIUM — three units, both families.

`take` writes `lot.frozenAtAnchor` unconditionally at `FeastPlatformSink.sol:444`.
It writes `lot.lastSaleAt` only inside the `if` at `:498-500`, because a sale
that does not raise the floor must not restart the floor's clock — the v1.6.3
rule, and it is right. The v1.6.14 floor fix reads the floor's clock
(`lastSaleAt`) against the descent's frozen checkpoint (`frozenAtAnchor`), so
after any take that does not raise the floor those two no longer name the same
instant, and every freeze between the last raising sale and that take is
thereafter charged to the floor as open time.

The docstring I wrote on `_floorNow` at `:352-354` asserts the opposite — that
`lastSaleAt` and `frozenAtAnchor` "are written together by `take`". The comment
thirty lines further down at `:456-466` says plainly that a non-raising sale
touches "neither the base nor the clock". Both are mine. The second is the code.

Measured: the floor stood at 5,726,623,062; after one 72-hour freeze and a
purchase of **one raw unit** it read 626,355,612 where 4,294,967,296 was owed.
Anyone may buy one raw unit, so the whole discount v1.6.14 removed is for sale.

### 2. A gated pool's cap is armed in wall blocks and checked in open blocks — PROVEN

`P16-claude`, `P6-claude`, `HK11-claude`, `HK11b`, `P16b` — five units, both
families, all MEDIUM.

`FeastHook.sol:391` (ungated arming) and `:890` (the check) were moved into
open-block coordinates. `:635`, where a **gated** pool arms its cap at its first
public swap, still reads `uint64(block.number)`. The window is therefore
`CAP_BLOCKS` plus every block the guardian has ever frozen, in the pool's whole
history. The comment above the check at `:887-889` says the two kinds "are armed
through the same two lines so that the two kinds cannot drift apart". They are
not and they have.

Measured: a 1,003-block window where `CAP_BLOCKS` is 2, after a freeze that
ended before the pool ever traded; and an ordinary buy refused by
`PurchaseCapExceeded` after the window should have closed.

### 3. `frozenBlocks()` does not count blocks, it estimates them — PROVEN, HIGH

`P16-claude` HIGH and `P6-claude` HIGH on the short direction; `P16-claude` LOW,
`P16b` MEDIUM and `HK11b` MEDIUM on the long one. Five units, both families.

`FeastGuardian.sol:171` sets `frozenUntilBlock = block.number + granted / SECONDS_PER_BLOCK`
with `SECONDS_PER_BLOCK = 3`. BSC does not mine one block per three seconds.
Every block past the estimate is counted as OPEN while every swap is refused,
and `CAP_BLOCKS` is **2** — so at any rate faster than one block per three
seconds a freeze of any length at all spends the entire opening cap window.

Measured at BSC's real rate: 86,400 blocks credited for a freeze that actually
stopped 345,598. **The v1.6.14 hook fix does not work on the chain it ships to.**

The error runs the other way too: a freeze that LAPSES without anyone calling
`unfreeze` keeps being credited blocks until `frozenUntilBlock` is reached, so
on a slower chain the cap stays in force after trading has reopened.

This is not a bug in the implementation of the ruling. It is the ruling's
prescription — "add `frozenBlocks()` as the block-domain twin of
`frozenSeconds()`" — meeting the fact that a contract cannot know a chain's
block rate. It is put to the coordinator below.

### 4. A scoped freeze stops every pool's clock and holds every sink price

`P16b` HIGH, `P16-claude` MEDIUM and LOW, `P6-claude` MEDIUM, `HK11b` MEDIUM,
`HK11-claude` LOW — five units, both families.

`freeze(false, poolId)` freezes one pool, but the seconds and blocks it spends
are folded into the one global `frozenSeconds()` / `frozenBlocks()` that every
contract subtracts. So a freeze on pool A stops the opening-cap clock of pools
that are trading normally, and holds the price of every lot in the sink although
`take` refuses only under an ALL freeze.

`P16b` calls it HIGH against P27 directly: the guardian may never move a price,
and a pool-scoped freeze moves every sink price. Not proven here; it wants a
design ruling, not a patch.

## Clocks the sweep classified and got wrong

The v1.6.14 sweep (`plans/audit/freeze-clock-sweep.md`) was supposed to end this
shape by enumeration. Two of its rows are contested with citations:

- **`FeastEmissions:379`** — `P16b` HIGH, `P5b` MEDIUM, `P5-claude` MEDIUM. The
  sweep classifies the `openAt` gate `RUNS`, on the reasoning that it "only ever
  OPENS" and forfeits nothing. At `:379` the same gate also decides which cap
  regime a CLOSED week takes — token cap before launch, value cap after — so a
  freeze across the gate hour reduces a closed week's award. That is a deadline
  wearing a gate's clothes, and the sweep's justification does not cover it.
- **`FeastOracle:168`** — `P16b` MEDIUM. The sweep classifies the oracle `RUNS`
  because a freeze writes no observations and the pricer therefore becomes more
  conservative or refuses. At this site frozen time does the opposite: it ages a
  REJECTED platform price into an ACCEPTED one, while the trades that would
  correct it are prohibited.

Both of these are the sweep's own claims failing, which is what the sweep says a
reader should do with it: "the sweep is a claim, not a proof."

## The two residues, now carrying verdicts

Both were named in `plans/audit/freeze-clock-sweep.md` and put to the
coordinator before this round ran. The round agrees they are real:

- **settlement's pricing grace**, `FeastEmissions:272` — `P5b` HIGH, `P16b` HIGH.
- **the fee allowance accrual**, `FeastHook:1605` — `P16b` MEDIUM.

## Other findings

| finding | units | note |
|---|---|---|
| `zero-cost-freeze` `FeastGuardian:183` | `P17-claude` MEDIUM | a freeze lifted in the second it was placed refunds its whole grant and folds zero, so a per-block freeze/unfreeze pair refuses every guarded call ordered between them at no budget cost. Codex `P17` read the same lines and returned NOTHING-FOUND on them; its statement ("only the unused tail is refunded") is true and still permits this. A real divergence, and the edge is the same second |
| `sunset-unanchored-prefreeze` / `pre-genesis-freeze-extends-partner-window` `FeastGuardian:320` | `P19`, `P19-claude` MEDIUM | carried from v1.6.13, where it was recorded as an artefact of the v1.6.13 fix. Two families now |
| `own-brake-extends-own-window` `FeastGenesisGrants:164` | `P19-claude` LOW | the multisig's own freeze lengthens the multisig's own assignment window |
| `sunset-view-misnamed` `FeastGuardian:320` | `P17-claude` LOW | `sunsetAt()` names an instant at which `freeze()` already reverts |
| `sink-dust-pins-decay` `FeastPlatformSink:300` | `HK19` MEDIUM | NEW and not a freeze clock: repeated dust purchases discard fractional decay and hold the descent flat |
| `hop-rounding-amplification` `FeastPricer:141` | `HK19` MEDIUM | pre-existing; reported as `HK19` in the v1.6.13 round too and still open |
| `stranger-binds-nontrader` `FeastHook:547` | `HK23-claude` LOW | a contract an EOA calls for an unrelated reason can bind that EOA's lifetime referrer through a dust swap |
| `lp-income-platform-share` `FeastHook:1767` | `P3-claude` LOW | pre-existing since round 1; the platform's share of LP income buys the meme coin rather than reaching the sink |

## Classes that held

`P13` (fee accounting) returned NOTHING-FOUND in both families across eleven and
six cited sites respectively. `HK19-claude` returned NOTHING-FOUND across
eighteen. `HK23` returned NOTHING-FOUND in Codex across eight. `P17` in Codex
found nothing on the 72 h / 168 h / day-90 bounds themselves.

## A test-harness hazard found while writing the PoCs

Under `via_ir = true` the optimiser common-subexpression-eliminates the `NUMBER`
opcode across a call frame — correct on a real chain, where the height cannot
move mid-transaction, and wrong under `vm.roll`. A test that reads
`block.number` twice around a `vm.roll` sees one value for both, silently. The
PoC reads through `vm.getBlockNumber()` instead. Any block-window test in this
repository that brackets a `vm.roll` with two `block.number` reads is suspect.
