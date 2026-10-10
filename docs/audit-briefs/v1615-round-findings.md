# v1.6.15 focused re-round — what it found

Tree: `v1.6.15-audit` at `c4bd7707560867d0f08ea846f3c73684dcca1a97`.
Workdir: `.runs/lens-v1615`. Date: 2026-09-22.

## The round, and what is missing from it

Eight classes, sized by the changed surface (`.runs/lens-v1615/class-surface.md`
maps each class to the surface it audits, and lists the twelve promise classes
and twenty-two hook classes **not re-run because their surface has not moved
since `f599310`**).

| | |
|---|---|
| Claude | **8 of 8** — P3, P5, P6, P14, P16, P17, P19, HK11 |
| Codex | **0 of 8 — `UNMEASURED: usage-limit`** |

**The Codex family is out of credits until 2026-09-25 20:11**, which is past this
pack's deadline. Four units died on the provider's usage-limit error and four
were launch-refused behind them. This is not a content filter and no rephrasing
or retry helps.

**State that plainly rather than in a footnote: every finding below rests on one
family.** The v1.6.12–v1.6.14 history is that the two families do not find the
same things. The clearest case is `P17` in the v1.6.14 round, where Claude found
the zero-cost freeze on the very lines Codex read and returned NOTHING-FOUND on
— and Codex's reasoning was true and still permitted the defect. A single-family
round is a weaker instrument and this one should be re-run against Codex before
the pack is treated as complete.

## What it found

**All three of the findings that matter are in work this release did.** That is
now the fourth consecutive round where the previous release's fix created the
next round's finding.

### 1. The cap window's stated boundary is not a boundary — PROVEN

`P6-claude` MEDIUM (`guardian-spends-opening-cap`), `P16-claude` MEDIUM
(`guardian-arms-then-freezes-cap-window`). Independently, same day.

v1.6.15 anchored the opening cap on a pool's first SERVED swap and wrote the
remaining boundary down: once armed the window is wall blocks, so a freeze inside
it still passes — but the excluded adversary was "a guardian that both predicts a
pool's first public trade and lands a freeze in the next block", on the ground
that it cannot schedule that.

**It does not have to predict anything. It makes the first trade itself.** It
arms the window with its own swap and freezes the pool in the same block.

Verified:
`test/audit/poc/V1615RoundFindings.t.sol::test_theGuardianCannotSpendAPoolsCapWindowWithItsOwnFirstTrade`
is RED — the cap-exceeding buy that should revert succeeds.

Retracted in the sweep, in P6, and in the v1.6.15 brief, each with a dated note.
What bounds it is owner ruling 5: `MIN_FREEZE_CHARGE` per pool, so at most 168
pools and every one visible on chain. The freeze-proof form — counting SERVED
blocks — is what coordinator ruling 1 said to note and not build, anticipating
"if the re-round shows it exploitable in practice". It has.

### 2. The new scope instrument has the old problem — PROVEN

`P16-claude` MEDIUM, `P5-claude` MEDIUM (`scoped-freeze-ages-platform-price`).

v1.6.15 stopped settlement trusting a platform price that aged into `Ok` across
frozen time, by requiring a full `TWAP_WINDOW` of OPEN time since
`guardian.allUnfrozenAt()`. That instant counts **ALL-scope freezes only** — the
shape owner ruling 2 introduced the same day — and a **pool-scoped freeze on the
platform pool** stops exactly the observations the average is built from.

Verified:
`test/audit/poc/V1615RoundFindings.t.sol::test_aPlatformPoolFreezeIsInvisibleToTheOpenTimeRule`
is RED — such a freeze moves `allUnfrozenAt()` by zero while every trade in that
pool is refused.

Needs `unfrozenAtFor(poolId)`, the resume instant's per-pool twin, and the
emissions rule reading `max(allUnfrozenAt(), unfrozenAtFor(platformPoolId))`.

### 3. The same average is read at two more sites that were not corrected

`P16-claude` LOW (`button-bound-ages-onto-frozen-spot`). Confirmed by reading:
`FeastHook._requireSpotNearAverage` at `:1717`, used by the buy-back button, and
the internal fill at `:851`, both read `oracle.twapTick(poolId)` with no
open-time condition — the identical construction `FeastEmissions:413` now
refuses to trust after a freeze.

A freeze pins the spot, the average catches it with no trade, and the button
then spends the self-burn bucket into a price nobody could move. **This is the
fourth time in this lane a fix has gone to the site a lens named rather than to
the shape.** It should be fixed at all three sites at once or at none. I would
put this first of the three.

## Everything else

| finding | class | note |
|---|---|---|
| `prelaunch-week-regime-by-settlement-instant` `FeastEmissions:456` MEDIUM | `P5-claude` | the RESIDUE this release documented and could not close; the round agrees it is real |
| `own-brake-extends-own-window` `FeastGuardian:410` MEDIUM | `P19-claude` | no freeze refuses `assignPartner`, and its only caller is the key that freezes, so the multisig lengthens its own window. Carried from v1.6.14, now MEDIUM |
| `sunset-unanchored-prefreeze` `FeastGuardian:410` MEDIUM | `P19-claude` | frozen seconds spent BEFORE genesis extend the partner window; `startClock` snapshots nothing. Carried |
| `sunset-view-misnamed` `FeastGuardian:410` LOW | `P17-claude` | `sunsetAt()` names an instant at which `freeze()` already reverts. Carried |
| `feeless-unpriceable-quote-holds-week` `FeastEmissions:367` LOW | `P5-claude` | an unpriceable quote holds its week through the grace even carrying no fees, while the `Moved` branch exempts that case |
| `window-fee-to-codeless-sink` `FeastLaunchWindow:319` LOW | `P3-claude` | the pot's 1% goes to whatever genesis named, with no code check |
| `genesis-does-not-ask-grants-which-guardian` `FeastFactory:415` LOW | `P19-claude` | genesis checks a grants contract's role and coin but not the guardian it reads |
| `lp-income-platform-share` `FeastHook:1791` LOW | `P3-claude` | pre-existing since round 1 |

## Classes that held

`HK11` and `P14` returned **NOTHING-FOUND** with citations — no finding lines at
all. `P6` returned six NOTHING-FOUND rows beside its one finding, including the
pre-buy's bound and the cap exemption's structural pair. `P3` found nothing above
LOW.

## The gates at this tree

| gate | result |
|---|---|
| suite | 677 passed, 0 failed, 0 skipped with the fork row — **before** the two round PoCs, which are deliberately red |
| mutation | inherited 234 · re-ran 16 · new 6 · caught 16/16 · `KNOWN_UNKILLED` 1 |
| census | ok |
| boundaries | ok, all eight checks |
| sizes | `FeastHook` 23,955 of 24,576 — margin 621 |
