# v1.6.21 → v1.6.22 — genesis asserts the full set, once

Changelog for branch `feat/v1.6.22-genesis-trust`, cut from `feat/audit-pack-v1621`
at `ec83ad3`. The predecessor tag is `v1.6.21-audit` (tag object `5d663a6`, commit
`e5c0a77`). The owner cuts `v1.6.22-audit` after the review card
(`plans/audit/656-review-card.md`); this branch does not tag. The previous
release's receipt is `docs/audit-briefs/v1621-three-questions.md`.

## The one sentence

The Codex appendix proved two more cases of the shape v1.6.21 had closed
one site at a time. The shape: **genesis checks some properties of a contract it
is about to trust with value, and not the rest.** The owner ruled that it is
closed once (2026-09-25 22:3x).

- Every recipient genesis names now goes through one path, which asks every
  question in one 18-row table, before anything is paid or recorded.
- Separately, the emissions pricing grace now moves only by frozen seconds.

## 1. The shape, and every site it has had

| release | recipient | property genesis took on trust | finding |
|---|---|---|---|
| v1.6.10 | team vesting | its `start()` | CA-8ea162587a |
| v1.6.21 | window | its `poolKey()` | `P4-claude` |
| v1.6.21 | team vesting | its `guardian()` | `P8-claude` |
| v1.6.21 | sink (if coded) | its arming, `opensAt()` | `P12-claude` |
| **v1.6.22** | grants | its `guardian()` (none at all: 8,000,000e18 funded, then inoperable) | `genesis-grants-guardian-unchecked`, Codex appendix, **HIGH** |
| **v1.6.22** | window | its `factory()` (600,000,000e18 funded, `settle()` reverts) | `genesis-window-wiring`, Codex appendix, **HIGH** |
| **v1.6.22** | emissions, sink | their `guardian()` | CA-9abd1b1a68 (r1.2, LOW) |
| **v1.6.22** | emissions | its `platformPoolId()` and `hook()` | CA-c03b8b2ead (r1.2, LOW) |
| **v1.6.22** | grants | its `emissions()` | CA-c03b8b2ead (r1.2, LOW) |
| **v1.6.22** | sink | having code at all | CA-8f254aa78e (r1.2, LOW) |
| **v1.6.22** | window, emissions, team vesting, grants | the rest of each one's set: the window's `hook`, `poolManager` and `wrappedNative`; emissions' `ledger` and `budget`; the vesting `duration`; the grants' `grant` | swept, not found: these are the rows no finding had reached yet |

## 2. What genesis asks now

There is **one path**, `_requireTrusted` (`src/FeastFactory.sol:763`). It runs the
existing prologue (code, role, coin), then every row of `_questions(role)`
(`src/FeastFactory.sol:663`). Genesis calls it exactly five times:
`:441` for the window, `:506-508` for the team vesting, emissions and grants, and
`:518` for the sink.

**How the set was drawn.** From each recipient's exits (the functions that move
its allocation out), and everything those exits call, wait on or hold:

- every collaborator an exit calls must be the platform's own;
- every clock an exit waits on must be the one genesis derives;
- every amount a recipient believes it holds must be the amount genesis sends;

wherever the factory has ground truth.

| recipient | getter | must equal | refusal | |
|---|---|---|---|---|
| window | `poolKey()` | the platform pool's id | `WindowPoolKeyMismatch` | v1.6.21 |
| window | `factory()` | this factory | `WindowFactoryMismatch` | new |
| window | `hook()` | the hook | `WindowHookMismatch` | new |
| window | `poolManager()` | the pool manager | `WindowPoolManagerMismatch` | new |
| window | `wrappedNative()` | wrapped native | `WindowWrappedNativeMismatch` | new |
| team vesting | `start()` | the window's close | `TeamVestingStartNotWindowClose` | v1.6.10 |
| team vesting | `guardian()` | the guardian | `TeamVestingGuardianMismatch` | v1.6.21 |
| team vesting | `duration()` | 36 months (94,672,800 s) | `TeamVestingDurationMismatch` | new |
| emissions | `guardian()` | the guardian | `EmissionsGuardianMismatch` | new |
| emissions | `hook()` | the hook | `EmissionsHookMismatch` | new |
| emissions | `platformPoolId()` | the platform pool's id | `EmissionsPoolMismatch` | new |
| emissions | `ledger()` | the hook's ledger | `EmissionsLedgerMismatch` | new |
| emissions | `budget()` | the 14.2% it is sent | `EmissionsBudgetMismatch` | new |
| grants | `guardian()` | the guardian | `GrantsGuardianMismatch` | new |
| grants | `emissions()` | the emissions genesis funds | `GrantsEmissionsMismatch` | new |
| grants | `grant()` | ⅛ of the 0.8% it is sent | `GrantsGrantMismatch` | new |
| sink | `opensAt()` | the window's close | `SinkNotArmed` | v1.6.21, now unconditional |
| sink | `guardian()` | the guardian | `SinkGuardianMismatch` | new |

**Deliberately not asked, with the reason:**

- the window's `vault()`: read by no function;
- the window's `startsAt()`/`lockAt()`: derived from its close in the constructor, and they gate only the
  committers' own funds;
- the vesting beneficiary: no ground truth; OpenZeppelin refuses a zero owner,
  and renounce is disabled;
- emissions' `timelock()` and `firstWeek()`: no ground truth in the factory;
- emissions' `pricer()`: the timelock can replace it; a bad one delays settlement
  and cannot strand anything;
- the grants' `targetNative()` and `partners()`: no ground truth; the
  constructor refuses a zero target and duplicate partners;
- the sink's `genesisKey()`: its one power is spent, which `opensAt` proves.

**The engine.** Each question is a static call to a getter with no arguments.

- A one-word answer is compared as that word.
- A longer answer is compared by its `keccak256`. For a pool key's six words that
  is exactly its `PoolId`.
- A call that fails, or answers in less than a word, answered nothing, and is
  refused as though it had named zero.

A refusal is `refusal(named, expected)`: the error's selector and two words. That
is the ABI encoding of every error in the table, so the r1.2 witnesses'
`abi.encodeWithSignature(...)` bytes match exactly.

**Order.** Checks run in this order: window, then the calendar block (the
close's range and the gate checksum), then team vesting, emissions, grants,
sink, then mint and transfers. The team vesting is now asked *after* the calendar
block rather than before, because its `start` question needs the close. No test
in the suite depended on the old order.

**The ceremony.** A sink with no code is now refused (ruling R2). The ceremony
must **deploy and arm the sink before genesis**. `script/Genesis.s.sol:106`
already schedules it before the genesis call, so no script step changes. The
owner carries this line into the genesis parameter table (task 570).

## 3. A defect the byte-exact engine test caught

The coordinator required a byte-exact test of the engine: for one row, every
answer shape must produce `selector ++ named ++ expected` exactly. It failed on
the first build.

- **The cause.** Yul evaluates a call's arguments right to left. So
  `and(staticcall(...), gt(returndatasize(), 31))` read the length of the
  **previous** call's answer, not this one's.
- **The observed result.** An empty answer was refused naming `0x452a9320…` (the
  getter's own selector, left in memory) instead of zero.
- **Why the honest path was unaffected.** Every answer before an honest
  question is at least one word. Even so, a length could in principle have been
  misread.

The fix makes the `staticcall` its own statement, and it is now what the test
checks (`test_theEngineReadsAnAnswerByItsLengthToTheBit`, all five answer
shapes). It was written twice:

| formulation | FeastFactory | against the 23,600 gate |
|---|---:|---|
| as first written (with the defect) | 23,588 | under |
| first correct formulation (a `size` variable) | 23,649 | **49 over** |
| the same fix as the minimal diff: the call its own statement, `returndatasize()` read after it | **23,585** | under by 15 (**adopted**) |

The logic is identical in the last two rows, and nothing was trimmed.

## 4. The pricing grace (FeastEmissions)

**Before.** `graceFrom = max(closesAt, guardian.allUnfrozenAt())`. That instant
moves on *any* unfreeze, so a freeze taken and lifted in the same second restarted
a grace that had already expired: `pricing-grace-restart`, Codex appendix, HIGH.
It had been recorded as open since v1.6.16 as `pull-restarts-the-grace`.

**Now** (`src/FeastEmissions.sol:321-327`):

    graceEnd = closesAt + PRICING_GRACE + (guardian.frozenSeconds() − anchor)
    anchor   = the frozen seconds stamped at the previous week's settlement,
               if it settled at or before this week's close; otherwise 0

This follows the guardian's own rule for such clocks: record the cumulative
number when the clock starts, and subtract. A week's close is not a
transaction, so the nearest recorded instant before it stands in. It needs no
guardian change and no new storage.

The rule has four properties, fuzzed in `test/FeastPricingGrace.t.sol` against
the test's **own** record of frozen time, not the guardian's counters:

1. **Never early**: the week settles only once three days of open time have
   passed since its close.
2. **Never before `closesAt + PRICING_GRACE`.**
3. **Never later than the close plus the grace plus the frozen seconds since the
   anchor**, and so never more than `FREEZE_BUDGET` (168 h) late. That is ruling
   R4's bound, and a pinned test reaches it exactly.
4. **Never again**: once over, the grace stays over. No freeze reopens it.

The approximation has a cost: frozen seconds between the anchor and the close
lengthen the grace too. That is at most 168 h of delay, never a zero valuation.

The platform price's open-time aging still reads `allUnfrozenAt()`, where the
question really is "how long since the market reopened". `audit/guardian-reads.allow`
is unchanged: FeastEmissions reads `frozenSeconds` twice and `allUnfrozenAt` once.

## 5. PoC and witness states

| test | on `v1.6.21-audit` | on v1.6.22 |
|---|---|---|
| `GenesisGrantsGuardian` (appendix) | red (skipped with its figure) | **green**, unedited except the skip line |
| `GenesisWindowWiring` (appendix) | red (skipped with its figure) | **green**, unedited except the skip line |
| `PricingGraceRestart` (appendix) | red (skipped with its figure) | **green**, unedited except the skip line |
| `GenesisRecipientGuardian` ×3 (r1.2) | red | **green**, exact errors |
| `GenesisRecipientPool` ×3 (r1.2) | red | **green**, exact errors |
| `WindowFeeCodelessSink` (r1.2) | red | **green**: `RecipientHasNoCode(0x51CC)` |
| `PreGenesisFreezeSlotBurn` (r1.2) | red | red, measured: `AssignmentWindowOpen(g0 + 90 days + 604800)`. This is the guardian's clock, not genesis trust; it is skipped with that measurement, and the owner decides the fix |
| `UnfreezeIsNotAFirstTake` (r1.2) | red | red, measured: the guardian's same-second take succeeds. This is sink/guardian ordering; it is skipped with that measurement, and the owner decides the fix |

## 6. Disputes left MEDIUM, untouched

`guardian-window-extension` and `freeze-cap-regime` (appendix severity disputes)
stay MEDIUM and out of scope. Their PoCs (`GuardianWindowExtension`,
`EmissionsRegimeUnderAFreeze`) stay skipped exactly as the appendix left them.

## 7. The gate

| check | result |
|---|---|
| suite, with the fork line | **808 passed, 0 failed, 8 skipped** (816). See the skip breakdown below. The fork suites ran for real, including `test_fork_theWholeRecipeRunsEndToEnd`, which drives the real deploy and genesis scripts through all 18 questions. |
| sizes | FeastFactory 22,571 → **23,585** (gate 23,600; EIP-170 margin **991**); FeastEmissions 13,679 → 13,813 (margin 10,763). Every other contract is byte-identical, FeastHook (24,330, margin 246) and FeastGuardian included, as their unchanged pins prove. |
| gas, same unchanged test files on both trees | `FeastEmissions.settle` +2,232 median/max. `genesis` +16,155, once per deployment. `create`, `seedWindowPool` and emissions `claim` unchanged. Window `settle` and swaps are unchanged on every deterministic test; with the fuzz tests included their averages moved by +227 and +738, so that movement is confined to fuzz runs. |
| deterministic layer (Slither, Aderyn, Semgrep; no lens units, no Codex, no mutation) | 0 engine failures; 301 deduplicated rows (v1.6.21: 299). Added: 5 LOW code-quality rows, all in the new engine (1 `assembly`, 4 `Literal Instead of Constant`). Removed: 3 (FeastVesting `Missing Inheritance`, FeastEmissions `incorrect-equality` and `timestamp`). Nothing added above LOW. |
| `check-census` | passes |
| `check-boundaries` | passes, except the pre-existing `identity` failure: 14 lines in `audit-pack-appendix-codex/lens/`, which this branch does not touch |
| `audit-pack/`, `audit-pack-appendix-codex/` | both verify against their manifests with 0 problems; neither is touched |
| mutation | not run (ruling R3) |

**Skipped tests, all eight:**

- `PreGenesisFreezeSlotBurn` and `UnfreezeIsNotAFirstTake` (§5).
- The two disputes' four PoCs:
  - `EmissionsRegimeUnderAFreeze` ×2;
  - `GuardianWindowExtension` ×2.
- `SharedOriginCapture` and `FloorSalePriceRise`, carried from v1.6.21 as they were.

## 8. Residues

- **The trace test's blind spot.** It derives the trusted set from what genesis
  pays, calls, or stores as a word value. An address genesis hands to another
  contract that neither pays nor calls it, and stores it only inside a mapping
  key or transformed, would be invisible to it.
- **The grace's over-count.** It is bounded by `FREEZE_BUDGET` and is delay only.
- **The exclusions in §2.** Each has its reason stated beside it.
- **Stale mutation anchors.** `tools/mutate.py` was not run and not edited
  (ruling R3). Six of its 256 mutations now anchor on text that no longer exists:
  five on the genesis sites the shared path replaced, one on the old grace line.
  Their names are listed in the review card.
- **The size estimate was wrong.** The plan estimated FeastFactory at about
  23,050 bytes; it measured 23,585. The cause of the gap was not measured.
