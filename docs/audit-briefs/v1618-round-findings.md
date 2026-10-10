# v1.6.18 guardian re-round — what it found

Tree: `v1.6.18-audit` at `7440f67`. Workdir: `.runs/lens-v1618`. 2026-09-22.

## The round

Three classes, the guardian surface only, sized by a one-file diff
(`src/FeastGuardian.sol`): **P6**, **P16**, **P17**. Claude family, **3 of 3**.

**Codex: `UNMEASURED: usage-limit`** across this and the two rounds before it —
credits reset 2026-09-25 20:11 SGT, after this pack's deadline. This lane's own
record is that the families do not find the same things: in the v1.6.14 round
Claude found a zero-cost freeze on the very lines Codex read and cleared, and
Codex's reasoning was true and still permitted the defect. Three releases of
single-family evidence is the weakest part of this pack and it is said first.

**HIGH = 0.** The owner's closing rule fires only on a HIGH in the freeze
family, so the pack proceeds and nothing below HIGH is patched tonight.

### A false start worth recording

The first two launches of this round were **VOIDED** —
`tree: the worktree changed under the unit`. The cause was mine and it is
mechanical: `contract-audit.yaml` lists `mutate` among `project_checks`, so the
pack's `run_layer.py project-checks` runs the **full mutation sweep**, which
rewrites files under `src/` for hours. A lens round and that layer can never
overlap. They are sequenced now, and the rule belongs next to the read-only rule
in the skill.

The same killed sweep left two source files mutated and its
`.runs/mutation-inflight.orig` matched **neither** HEAD nor the mutant — so
restoring from it would have corrupted them, as it did once before in this lane.
Both were restored from `git show HEAD:<path>` and verified by digest, and the
stale journals are quarantined outside the worktree.

## The finding: the guard does not cover a lapse — MEDIUM, carried

`P6-claude` (`lapse-opens-the-bracket`) and `P16-claude`
(`lapsed-freeze-closes-its-own-block`), independently, both at
`src/FeastGuardian.sol:246`.

v1.6.18 refuses a `freeze` in the block an `unfreeze` cleared, which closes the
same-block bracket. **`lastUnfrozenBlock` is written only inside `unfreeze`**
(line 275, and nowhere else). A freeze that **lapses** by itself stamps nothing,
and neither does `expire()`. So the guardian can let a freeze run out and then
`trade, freeze` in one transaction in the block the lapse opened — the bracket
again, through a door the guard does not watch.

Confirmed by reading: `grep -n lastUnfrozenBlock src/FeastGuardian.sol` returns
its declaration, the guard at `:246`, and one write at `:275`.

**The bound, and it is the point.** A lapse is not free the way an `unfreeze`
is. `unfreeze` refunds the tail above `MIN_FREEZE_CHARGE`, so a bracket built
from unfreezes cost **one hour** per block. A lapse refunds nothing: the
guardian pays the **whole grant**, up to `FREEZE_MAX = 72 hours`. With
`FREEZE_BUDGET = 168 hours`, that is at most two 72-hour lapses and one of 24 —
**three bracketed blocks over the guardian's entire life**, after which the
brake is spent for ever and every pull of it is on chain.

`CAP_BLOCKS` is 2, so one pool can still be taken this way, once, at the cost of
the entire brake. That is a different economic object from the same-block
bracket it replaced, which cost two hours and was repeatable.

**Not fixed tonight, by ruling.** The coordinator's instruction was explicit:
below HIGH is carried with its bound, and there is no v1.6.19 tonight. The
candidate fix is the obvious one — stamp `lastUnfrozenBlock` wherever a freeze
ends, which means `_clear()` rather than `unfreeze`, covering `expire()` and the
fold of a lapsed freeze alike.

## Also found

**`preopen-regime-decided-by-settle-instant`** (`P16-claude` MEDIUM,
`src/FeastEmissions.sol:498`) — the RESIDUE this lane has carried since v1.6.15
under the name `prelaunch-regime-by-settle-instant`. Unchanged, and its two
options are in `plans/audit/freeze-clock-sweep.md`.

**P17 returned NOTHING-FOUND** on the brake's bounds: `MIN_FREEZE_CHARGE`, the
72-hour grant, the 168-hour lifetime budget and `unfreeze`'s refund were all
answered clean at this tree.

## The gates at this tree

| gate | result |
|---|---|
| suite | **711 passed, 0 failed, 0 skipped** with the fork row |
| mutation (release gate) | inherited 253 · re-ran 1 · new 1 · **caught 1/1** |
| census | ok (31) |
| boundaries | ok, **nine** checks |
| sizes | `FeastHook` 24,330 of 24,576 — margin **246** |
