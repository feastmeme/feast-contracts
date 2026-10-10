# v1.6.16 focused re-round — what it found

Tree: `v1.6.16-audit` at `d1971e8d96ea71285c3bed5dc3b596b5d9139e1c`.
Workdir: `.runs/lens-v1616`. Date: 2026-09-22.

## The round, and what is missing from it

Eight classes, sized by the changed surface
(`.runs/lens-v1616/class-surface.md` maps each class to the surface it audits
and lists the classes **not re-run because their surface has not moved since
`c4bd770`**).

| | |
|---|---|
| Claude | **8 of 8** — P3, P5, P6, P14, P16, P17, HK11, HK19 |
| Codex | **0 of 8 — `UNMEASURED: usage-limit`**, reset 2026-09-25 |

**Single-family, and it matters here more than the count suggests.** This lane's
own record is that the families do not find the same things: in the v1.6.14
round Claude found the zero-cost freeze on the very lines Codex read and cleared,
and Codex's reasoning was true and still permitted the defect. Owner ruling 5
exists because of that one finding. Every finding below rests on one family.

## HIGH = 0

No finding in this round is HIGH. Two are MEDIUM and **verified with red PoCs**;
the rest are MEDIUM or LOW and are carried or known.

## 1. The fifth iteration — `guardian-serves-the-window-alone`, MEDIUM, PROVEN

`P6-claude`. `src/FeastHook.sol:687`.

Counting SERVED blocks removed the last quantity a freeze could spend. It did
not remove the guardian's ability to be the one who **serves** them: a one-wei
trade of its own in each block, with a pool-scoped freeze between them so no
stranger can reach one, spends the whole window before anybody else may trade.

Verified:
`test/audit/poc/V1616RoundFindings.t.sol::test_aStrangersFirstTradeIsStillCappedWhenTheGuardianServedEveryOpeningBlock`
is RED — the stranger's first trade fills uncapped. Its control,
`test_aStrangerInTheWindowIsCapped`, passes, so the test is not vacuous.

**The opening cap has now been redesigned five times against one shape:**

| release | the window was | how it was defeated |
|---|---|---|
| ≤ v1.6.12 | a block height armed at creation | a freeze spent it |
| v1.6.14 | a height in OPEN blocks | a contract cannot observe its chain's block rate |
| v1.6.15 | a height armed at the first served swap | the guardian armed it with its own trade |
| v1.6.16 | a count of SERVED blocks | the guardian serves them with its own trades |

What bounds it today is owner ruling 5: `MIN_FREEZE_CHARGE` per block of the
window — two hours of a 168-hour lifetime budget — and every pull visible on
chain.

**This is the finding the coordinator's signalled simplification ruling is for.**
Every defeat in that table needs a *pool-scoped* freeze the guardian can
interleave with its own trades. Removing pool-scoped freezes entirely would end
the class rather than patch it a sixth time.

## 2. A claim this release wrote down, disproved — `grace-blind-to-platform-pool-freeze`, MEDIUM, PROVEN

`P16-claude`. `src/FeastEmissions.sol:290`.

v1.6.16 says, in the source and in the brief, that the pricing grace may read
`allUnfrozenAt()` because *"nothing but an all-scope freeze refuses `settle`"*.
**The aging rule added in the same release makes that false.** A freeze scoped to
the platform pool turns an `Ok` price into `Moved`, and a `Moved` price refuses
`settle` — so a scoped freeze refuses settlement for its whole duration plus an
averaging window, while the grace it is consuming cannot see it.

The cost is exactly what the grace exists to prevent: the first settlement that
can complete values an unpriceable listed quote at **zero, for ever**.

Verified:
`test/audit/poc/FreezeRunsTheSettlementClocks.t.sol::test_aPlatformPoolFreezeDoesNotConsumeTheSettlementPricingGrace`
is RED — the week settles and the quote is zeroed.

The coupling was created by my own fix, one paragraph away from the comment
asserting it could not exist. Same shape as finding 1: the instrument was right
and the reasoning about what could reach it was not.

## 3. `pull-restarts-the-grace` — MEDIUM

`P17-claude`. `src/FeastEmissions.sol:291`. A same-block freeze/unfreeze that
freezes nothing still moves `allUnfrozenAt()`, restarting settlement's three-day
strict window from the pull's instant — for one hour of budget. 168 pulls buy
about 504 days of delay. Not verified here; the mechanism is the one finding 2
turns on and is visible in the same lines.

## Everything else

| finding | class | note |
|---|---|---|
| `prelaunch-regime-by-settle-instant` `FeastEmissions:475` MEDIUM | `P5-claude` | the RESIDUE this lane has carried since v1.6.15 and documented rather than closed |
| `sink-dust-take-restarts-descent` `FeastPlatformSink:463` MEDIUM | `HK19-claude` | a one-unit take rewrites `anchoredAt`, so crumbs slow the descent and pin it flat. Adjacent to the known `sink-dust-pins-decay`, and the same adversary as the v1.6.14 floor finding |
| `lp-income-platform-share` `FeastHook:1863` LOW | `P3-claude` | pre-existing since round 1 |
| `sunset-view-misnamed` `FeastGuardian:464` LOW | `P17-claude` | carried since v1.6.14 |

## Classes that held

`HK11` and `P14` returned **NOTHING-FOUND** with citations and no finding lines
— the hook's new guardian call on the fill path, and all three reads of an
oracle average, were both answered clean. `P6` returned several NOTHING-FOUND
rows beside its finding, including that the cap is measured on the pool's own
coin delta and that the pre-buy exemption cannot be reached by any later trade.

## The gates at this tree

| gate | result |
|---|---|
| suite | **712 passed, 0 failed, 0 skipped** with the fork row — before the round's two PoCs, which are deliberately red |
| mutation | inherited 245 · re-ran 10 · new 5 · **caught 10/10** · `KNOWN_UNKILLED` 1 |
| census | ok (31) |
| boundaries | ok, all **nine** checks |
| sizes | `FeastHook` 24,409 of 24,576 — margin 167 |
| invariants | all **200** named witnesses resolve |

## A note on the round's mechanics

The previous round's launcher overwrote the operator's `.runs/awaiting.json`
with its own terminal state while reporting that it had done nothing, destroying
a station boundary. It writes `.runs/codex-awaiting.json` as of v1.6.16 and the
rule is in the contract-audit skill.
