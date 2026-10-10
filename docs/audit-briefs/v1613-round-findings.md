# v1.6.13 — the four findings the v1.6.12 round proved, fixed

Task 567. This is the receipt for the commit handed to AstraSec, and it
**supersedes `v1612-fixes-and-guardian.md`**, which was never handed over: the
round on `v1.6.12-audit` found four HIGH-shaped defects, three of them in the
guardian that release had just added, and one that **overturns a disproof
published in that very brief**.

Round coverage on `v1.6.12-audit`: 42 classes, both families.

| family | done | unmeasured |
|---|---:|---|
| Claude (`fable`/`max`) | **42** | — |
| Codex (`gpt-6-astra`/`ultra`) | **38** | 4 — `HK14`, `HK16`, `HK17`, `HK18`, each refused twice by OpenAI's content filter (original header and a rephrased one). No third attempt, per the rule. **Those four classes have Claude-family coverage only.** |

Triage found no HIGH or MEDIUM beyond the four below. The units that landed last
corroborated them rather than adding to them.

---

## 1. HIGH — the sink's descent ran through a freeze

Three units, one in each family and one twice: `P3-claude`, `P16`, `P16-claude`.

The sink's price is a pure function of elapsed time. A freeze stopped `take` and
did not stop the clock. `SINK_HALF_LIFE` is **one hour** and a freeze may run
**72**, so one pull of the brake halved the price of everything the sink held
seventy-two times while every buyer was locked out — and the guardian, the only
address that knew when it would end, could unfreeze and take in the same
transaction. Measured in the PoC: a factor of **2^72**.

**This is exactly what `P27` forbids, reached the one way that invariant's own
witness cannot see.** `testFuzz_theGuardianCannotMoveAWei` calls one function and
checks balances; this needs four — freeze, wait, unfreeze, take — and no single
call in it moves a wei that was not paid for. The invariant's wording is now
"can never move funds **or move a price**".

**Fix.** The guardian counts its own downtime: `frozenSeconds()` is the seconds
it has held the brake down over its whole life, including a live freeze and one
that *lapsed* without anybody calling `unfreeze`. A lot records that number when
its descent is anchored and `_price` subtracts the difference, so the descent
measures OPEN time. `take` stays freezable — a defect in the sink itself has to
be stoppable; what must not happen is the price moving while it is.

**Divergence from the ruling's letter, stated.** It named
`frozenSecondsSince(uint64 t)`. Answering that exactly for an arbitrary instant
needs the whole freeze history, whose length is bounded only by the budget's
duration and not its count — a guardian spending its 168 hours in one-second
pulls would put unbounded gas on the sink's hottest read. A consumer recording
the cumulative number when its own clock starts is exact, O(1), and costs one
field per record.

PoC: `test/audit/poc/FreezeRunsTheDescentClock.t.sol`.

## 2. HIGH — a freeze could eat a claimant's deadline

Two units, one in each family: `P16`, `P16-claude`.

`expiryOf(n)` is `max(settledAt, openAt) + CLAIM_GRACE`. `claim` is frozen and
that clock was not, so a 72-hour freeze placed before an expiry stopped a
claimant claiming and `burnExpired` then destroyed the entitlement for ever.

**It is the argument the launch window already won, not applied here.** The
window is exempt from freezing because its refunds run on a hard hour. An
emission claim runs on a twelve-week clock, so the answer is to pause the clock
rather than exempt the call, and `claim`/`claimMany` stay frozen.

**Fix.** The grace is extended by every second the brake has been down since the
week settled — measured from settlement even when the window opens later, which
only ever lengthens a claimant's window.

**This finding was hidden by finding 3.** Before the clock was fixed, the
guardian's sunset fell eight days *before* any claim expiry, so no freeze could
be placed late enough to reach one.

PoC: `test/audit/poc/FreezeExpiresAClaim.t.sol`.

## 3. HIGH — the guardian's ninety days started at the wrong instant

Four units across both families: `P17`, `P19b`, `P17-claude`, `P19-claude`.

`genesisAt` was `block.timestamp` in the **constructor**, which is package-1
deploy time. Genesis is a separate, later act — the README's own table puts
package 1 "with the factory" and genesis at "TGE, when the owner decides". Both
ninety-day windows were short by however long the owner waited (twelve days on
the unit fixture's own calendar), and `burnUnfilledSlot` opened that much
earlier. The field was **named** `genesisAt`, which is what kept it invisible.

**Fix.** The factory tells the guardian when genesis happened: `startClock()`,
factory-only, one-way. The field is `genesisStartedAt`. Before the clock starts
there is no deadline: `sunsetAt()` is `type(uint64).max`, the brake is fully
live, and `assignPartner` and `burnUnfilledSlot` both refuse. A guardian whose
genesis never comes keeps its brake; a slot whose window never opened cannot be
burned out from under anybody.

PoC: `test/audit/poc/GuardianClockStartsAtGenesis.t.sol`.

## 4. HIGH — the pre-buy's signed cast, and a **retraction**

Reported by `P6b`.

`int256(type(uint256).max)` is `-1`, and negating `-1` is `1`. The venue reads a
positive `amountSpecified` as an exact-**output** swap — for a single unit of the
coin — and almost all the creator's quote, already transferred in, strands in
the factory. `SafeCast.toInt256` closes it in one line.

### The retraction, dated 2026-09-21

**`docs/audit-briefs/v1612-fixes-and-guardian.md` §1 states that this shape was
DISPROVED. That statement is wrong and is withdrawn.** So is the same claim in
the message of commit `0059ac0` and in `test/audit/poc/PrebuySignedCast.t.sol`
as it stood at `v1.6.11-audit`.

What the v1.6.11 PoC did: it tested `2^255`, where the language's checked
negation panics, and `2^255 + 1`, where the venue's own `SafeCast` refuses —
the two **edges** of the gap — and concluded that no reachable value
reinterprets the cast. Between those edges lies the whole top half of the
`uint256` range, where neither guard fires. The witness did not reach its bound,
and the conclusion drawn from it was asserted in a commit message and in an
audit brief.

What was done differently this time: the new test was run as a **negative
control** before being trusted — with `SafeCast` removed the create *succeeds*,
which is the finding. That check is the one the v1.6.11 PoC never performed.

PoC: `test/audit/poc/PrebuySignedCast.t.sol`, now covering `type(uint256).max`.

---

## The gates on this commit

| gate | result |
|---|---|
| suite | 603 passed, 0 failed, 25 skipped; **628 with the fork row** at block 120,721,477 |
| mutation | **240 of 241 caught, 1 knowingly outstanding, 0 survivors.** Six mutations are new — one per fix, plus the frozen-time counter itself and the factory-only clock start |
| census | ok |
| boundaries | ok — licence, authority, identity, surface, abi, guarded, settlement-deadline |
| bytecode pin | seventeen runtime hashes; five moved |

**The mutation run found four survivors first, and none was a defect in `src/`.**
Two were anchors my own fixes invalidated (`stretch the claim grace`, `let a
freeze outlive the day-90 sunset`) and are re-anchored. Two were tests that had
stopped testing:

- `fill a partner slot before genesis has happened` was filtered at a suite whose
  fixture runs genesis, so the guard it removed could not matter there;
  `test_noSlotIsFilledOrBurnedBeforeGenesis` is the witness that can see it.
- `backdate an assigned partner's referrals` was caught at v1.6.12 and stopped
  being caught when I added a `_genesis()` to its fixture: the warp moved the
  clock past the week the test checked, so it asserted zero against zero. It now
  searches for the settled week that actually carries the referrals and asserts
  that week has value to refuse **before** asserting the grant refuses it.

That is the second green test this release that was measuring nothing — the
first is the v1.6.11 disproof retracted in §4. Both had the same shape: an
assertion that would have held whatever the code did.

## Sizes

`FeastHook` is **untouched at 23,934 of 24,576 — margin 642**. None of the four
fixes reaches it.

| Contract | Bytes | Δ vs v1.6.12 |
|---|---:|---:|
| `FeastGuardian` | 3,294 | +812 |
| `FeastPlatformSink` | 5,923 | +619 |
| `FeastEmissions` | 13,425 | +417 |
| `FeastFactory` | 21,354 | +227 |
| `FeastGenesisGrants` | 6,034 | +179 |

## How to reproduce

```
forge test                                          # with FORK_URL set
forge test --match-path 'test/audit/poc/*'          # the round's findings
python3 tools/mutate.py
python3 tools/check-census.py
python3 tools/check-boundaries.py
```
