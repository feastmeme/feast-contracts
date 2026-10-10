# v1.6.19 — the seventh iteration, and the descent's curve

Receipt for the release handed to AstraSec. Predecessor:
`v1617-one-scope.md` and the v1.6.18 guard; the round that produced this release
is `v1618-round-findings.md`. Earlier tags are never moved.

## The one sentence

The owner read the v1.6.18 pack and ruled that **both carried MEDIUMs are fixed
before the auditor sees anything**: a freeze that lapses can no longer be used
to bracket a block, and a sale raises the descent's curve instead of restarting
it. The round on this release runs with **both families**.

## 1. A lapsed freeze gets a transaction of its own

`P6-claude` (`lapse-opens-the-bracket`) and `P16-claude`
(`lapsed-freeze-closes-its-own-block`), independently, in the v1.6.18 round.

v1.6.18 refused a `freeze` in the block an `unfreeze` cleared, reading a stamp
`unfreeze` was the only writer of. `expire()` did not stamp; a freeze that
**lapses** stamps nothing at all. So the guardian could let one run out and then
`trade, freeze` in one transaction in the block the lapse opened, serving a
block nobody else could reach — the seventh way through the opening cap.

The stamp moves into `_clear()`, which `unfreeze` and `expire` both pass
through.

> **A lapse passes through neither, and the ruling's wording assumed it did.**
> A freeze that runs out has no transaction in it at all, so there is nothing to
> stamp: moving the stamp into `_clear()` alone would have left the finding
> exactly where it was. Said here rather than shipped quietly.

So a lapse gets a transaction: **`settleLapsed()`, permissionless**, and
`freeze()` refuses with `LapsedFreezeNotSettled` until it has happened. The
guardian must settle in one block and freeze in a later one.

Permissionless on purpose: if only the guardian could settle, it could decline
to, and `freeze` would be blocked on it — a lockout of its own brake.

**The bound that remains.** The guardian can still *trade* in the block a lapse
opens. What it cannot do is close the bracket behind itself, so that block is
open to every stranger, and taking it needs the guardian ordered ahead of every
other transaction in it — **block-builder collusion**, the same residue the
same-block bracket leaves. The PoC asserts the positive form: a stranger reaches
the very block the guardian served, and is capped.

**The operational cost, stated:** every lapsed freeze now needs a settling
transaction before the guardian can freeze again.
`test_theCumulativeBudgetIsOneWeek` carries it.

## 2. A sale raises the curve; it does not restart it

`HK19-claude` MEDIUM, v1.6.16 round. Launch-relevant, because `/burn` gives
anyone the button.

`take` now multiplies the stored `anchor` by `1 + amountOut/held` and **leaves
the clock alone**, so from that instant the price is the price it would have
been, times the share the sale took. The descent is **memoryless**: a take at
any moment leaves the lot on the same curve, and a take of nothing changes
nothing.

Why it had to change. The curve is exponential by halvings and **linear inside
each one**, and a chord lies *above* the exponential it spans. Re-anchoring
reset the clock, putting the price back at the top of a fresh chord, so a drip
of takes never reached the cheap end of one:

```
continuing:  anchor · 2^(-T/H)            = anchor · e^(-0.693 T/H)
restarting:  anchor · (1 − δ/2H)^(T/δ)  →  anchor · e^(-0.5 T/H)
```

a ratio of `e^(0.193 T/H)` — about 3.2× over six hours in the limit, and
**2.03× measured** with a take every thirty minutes.

**The guard tried at v1.6.17 and rejected stays recorded in the source.**
Skipping the re-anchor when the sale's own value floors to zero — the rule the
floor has had since v1.6.3 — does not bite: one raw unit of a 100e18 lot at a
Q128 price is worth about 5e16, so the value is nonzero and the clock reset
anyway. The defect was never dust being rounded away; it was the clock.

Four boundary rows, and all 39 existing sink tests unchanged:

| row | what it pins |
|---|---|
| the drip | 2.03× before; within one part in a thousand of honest after |
| a quarter of the lot | raises the price by a quarter — round 1 H1 preserved |
| a take on a half-life edge | moves nothing, and the next half-life still halves |
| 99%, then the last unit | 99% raises by 99%; an emptied lot reads the start price, which is `_price`'s documented rule and is asserted so it does not look like a bug |

Two of those first panicked at two hours, where the price is near `1 << 192` and
a 25e18 take costs more than anyone can hold. The counterfactual said they panic
at HEAD too, so it is the fixture's regime and not this change; they run at 150
hours.

## Sizes and gates

| | v1.6.18 | v1.6.19 | |
|---|---|---|---|
| `FeastHook` | 24,330 | **24,330** | margin **246**, unchanged — neither fix touched it |
| `FeastGuardian` | 3,611 | 3,804 | +193 |
| `FeastPlatformSink` | 6,151 | 6,097 | **−54** |

| gate | result |
|---|---|
| suite | **716 passed, 0 failed, 0 skipped** with the fork row |
| mutation (release) | inherited 253 · re-ran 4 · new 3 · **caught 6/6** (two more re-targeted by these fixes) |
| census | ok (31) |
| boundaries | ok, **nine** checks |
| invariants | all **205** named witnesses resolve |

`settleLapsed` is classified in the guarded-surface table: *anyone, once a
freeze has run out; it must happen before the next freeze*, moving no value.

## What is still open

| finding | severity | bound |
|---|---|---|
| the bracket's builder-collusion residue | MEDIUM | needs the guardian ordered ahead of every other transaction in the block it serves; two `MIN_FREEZE_CHARGE` pulls per block, or a whole grant per block through a lapse |
| `pull-restarts-the-grace` | MEDIUM | 168 pulls is the whole budget, so at most ~504 days of **delay**; settling late forfeits nothing |
| `prelaunch-regime-by-settle-instant` | MEDIUM | **accepted** by the owner with the bound stated — option 2 of the sweep. Stays RESIDUE with the argument attached |
| `lp-income-platform-share` | LOW | pre-existing since round 1 |
| `sunset-view-misnamed` | LOW | a view names an instant at which `freeze()` already reverts |
