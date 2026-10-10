# v1.6.22 → v1.6.23 — the buy-back tip gets a floor, and the bucket sets its rate

Changelog for task 675.

| | |
|---|---|
| branch | `todo/59b1e957f13152ac` |
| cut from | `feat/v1.6.22-genesis-trust` at `a2c0bae` |
| predecessor tag | `v1.6.22-audit`: tag object `bbb7a6a`, commit `a2c0bae` |
| design | `plans/675/design.md` |
| ruling | `plans/675/ruling.md` |
| note for the auditor | `docs/audit/v1.6.23-diff.md` |
| break-even arithmetic | `docs/button-economics.md` (按钮经济) |

Everything below is this branch; the tag commit is its base. The owner cuts `v1.6.23`. This branch
does not tag.

## The one sentence

- **Before:** a press of the buy-back button was tipped 0.25% of what it bought. That made no
  bucket under about \$1,040 worth pressing.
- **Now:** it is tipped `max(0.25%, min(floor ÷ largest, 10%))`.
  - `floor` is worth 0.0005 BNB, in the pool's quote.
  - `largest` is the largest press the bucket allows.
- **So:**
  - a bucket of about \$26 covers its own gas;
  - a big bucket is tipped exactly as before;
  - splitting a press earns nothing.

## 1. The rule

`tip = coinOut × max(TIP_BPS, min(floor ÷ largest, TIP_CEILING_BPS))`

**The terms:**
- **`largest`:** `ALLOWANCE_CAP_BPS` (5%) of the bucket before the press.
- **`floor`:** the quote's row in a table the hook is built with. Every row is worth the same:
  - the WBNB row is `TIP_FLOOR_NATIVE`, 0.0005 ether;
  - each listed stock's row is the amount of that stock worth 0.0005 BNB at deploy.

  A quote nobody listed has no row, and its tip is 0.25%, as before.
- **`TIP_CEILING_BPS`:** 1,000. It holds every tip to a tenth of what was bought, so
  `burned ≥ 90%` of every print, and `coinBurned + tip == coinOut` as before.

**The pacing is unchanged:**
- 5% per press;
- 15% refilled per hour;
- 20% in any hour.

The floor moves the split of what a press bought. It does not move what a press may spend.

**The table:**
- **Where it lives:** `FeastHook`'s constructor takes `TipFloor[] tipFloors` and writes them to
  `_tipFloorOf`. It is internal, declared after every audited variable, and written nowhere else.
- **How it is read:** there is no getter (66 bytes the hook cannot spare). The site and the census
  read `TipFloorListed(quote, floor)`, which the constructor emits once per row.
- **What it refuses:** by name, a zero floor, a floor over 128 bits, and a quote listed twice.
- **Where the rows come from:** `DeployPackage1` lists wrapped native, then the stock rows of
  `FeastGenesis.tipFloors()`. That placeholder is empty until the owner fills it from task 570's
  sheet.
- **How the press reads it:** the Buyback lock callback already holds the quote, so it returns the
  floor as a fourth word.

## 2. Why the bucket, and not the press

The rule was first written as "convert the floor at the price the press itself paid". That divides
the floor by **this** press. But the presser chooses the press size, and nothing bounds how small or
how often a press may be, because round 6 removed the interval. So the best press is `10 × floor`,
where the ceiling meets the floor.

On a \$10,000 bucket that is about 500 presses an hour:
- each press is tipped 10%;
- the tips total \$150/h, against \$3.75/h before;
- each print burns 90% instead of 99.75%.

This is R6 again (`docs/plan.md`, "farming the tip by splitting one conversion into many"). It would
have broken the property that closed R6 once the interval went: no flat component.

Divided by the largest press, the rate is set by the bucket, so there is still **no flat component
per press**. The largest press gets the owner's numbers exactly.

Two witnesses in `test/FeastTipFloor.t.sol` go red when the tip site is mutated to divide by
`quoteSpent`. The mutation was applied by hand and reverted.

| witness | measured under the rule as written | bound under the ruled rule |
|---|---|---|
| ten presses of a tenth | 9.9× one press | ≤ 1.06× |
| half a press | tipped 2.02% | the full press's 1.01% |

## 3. What it costs

| | v1.6.22 | v1.6.23 |
|---|---:|---:|
| FeastHook runtime (margin to EIP-170) | 24,330 (246) | **24,437 (139)** |
| a press, `buyBackAndBurn` median (FeastBuyback, deterministic) | 226,573 | 228,831 (+2,258) |
| the same press when the quote is listed and the floor binds | — | +302 more |
| FeastHook deployment, empty table | 5,319,612 | 5,350,272 (+30,660) |

- **Deployment:** each table row adds a cold SSTORE and one event to the hook's deployment. That is
  roughly +24k gas per row, an estimate, not measured.
- **Unchanged:** every other deterministic row of FeastFeeTake's and FeastBuyback's gas reports is
  identical on both trees (30 rows compared), including the swaps, the hook's callbacks and `create`.
- **Other contracts:** every contract but FeastHook is byte-identical; their pins are unchanged.

**Bytes: how the rule is spelled matters.** Each spelling was measured on a clean build of the hook
(`plans/675/design.md` §3):

| spelling | Δ runtime |
|---|---:|
| first spellings (`mulDiv`): the table, the table with a getter, WBNB-only through the converter | +277 / +343 / +437, all over EIP-170 |
| the table, looked up at the tip line, checked | +212 |
| the table, looked up in the lock callback (the first commit) | +135 |
| **the same, declared after every audited variable (shipped)** | **+107** |

The shipped version is smaller because declaring the table first moved `_pools` from slot 0 to
slot 1. That cost PUSH1 where PUSH0 had been, and it broke a test (§5).

## 4. The files

**Contracts and script**
- **`src/FeastHook.sol`:** the struct, the table, the event, two errors, the constructor loop, the
  callback's fourth word, and the tip site.
- **`src/FeastConstants.sol`:**
  - `TIP_CEILING_BPS = 1_000`;
  - `TIP_FLOOR_NATIVE = 0.0005 ether`;
  - `TIP_BPS`'s docblock: the rule, the rows, the break-even, the farmer.
- **`src/FeastGenesis.sol`:** the `tipFloors()` placeholder, empty.
- **`script/DeployPackage1.s.sol`:** the hook's table, built by `tipFloors()`.

**Tests**
- **The 15 fixtures that build the hook:** each passes an empty table, which is today's rule, so no
  expectation moved.
- **`test/FeastBytecodePin.t.sol`:** FeastHook is re-pinned.
- **`test/FeastTipFloor.t.sol`:** new, 15 tests, one of them a fuzz.

**Docs**
- **`docs/abi/FeastHook.json`:** regenerated. It only gains: the constructor input, the event and
  the two errors.
- **`docs/interface.md` and `docs/site-census.md`:** the three sentences that called the tip
  "0.25%" or "a fixed fraction" now state "no flat component per press — the rate is set by the
  bucket, not the press".
- **`docs/button-economics.md`:** new.

## 5. The gate

| check | result |
|---|---|
| suite | **798 passed, 0 failed, 33 skipped** (831 total). The 33 are the 25 fork tests, since this lane has no RPC, and the 8 PoCs v1.6.22 carried skipped. v1.6.22 passed 808 of 816 with the fork line. Less the 25 fork tests that cannot run here, plus the 15 new, that is 798: every non-fork test that passed there passes here. The fork line did not run. |
| the storage slot | The first full run failed in exactly one test: `FeastPlatformExit`'s `test_aBucketLargerThanOneSettlementLeavesInPieces`, which writes `_pools`' slot directly. The table had moved `_pools` to slot 1. It is now declared last, and the test passes unedited. |
| sizes | FeastHook 24,437 (margin 139); FeastFactory 23,585 (margin 991, unchanged); every other contract byte-identical (pins) |
| gas | §3 |
| `check-census` | passes |
| `check-boundaries` | passes, except the 14 identity findings in `audit-pack-appendix-codex/lens/` that were already there |
| fork | **not run.** The tests read only `BSC_RPC_URL`, which is unset in this lane. |
| mutation | `tools/mutate.py` was not run. Its "flat tip" mutation still anchors on the unchanged `TIP_BPS` line. The rule's own mutation (§2) was run by hand. |

## 6. Residues

- **No fork press.** No press on the sandbox or the pinned fork has been observed emitting a floored
  tip. `test_fork_theRecipeWiresPackageOneOnTheRealVenue` will exercise the script's table once an
  RPC is set.
- **The stock rows are empty.** Until the owner fills `FeastGenesis.tipFloors()`, a deployment
  floors WBNB only. The script does not refuse an empty table.
- **A stock row drifts.** It is fixed in stock units, so its BNB value moves with the stock. At
  1 gwei the floor is about 2.2× the gas of a press, so it stays above gas unless the stock falls
  more than about 55% against BNB.
- **The stateful harness does not exercise the floor.** `FeastSystem` and the other fixtures run
  with an empty table. The floor's properties are held by `FeastTipFloor`'s unit and fuzz tests, not
  by the invariant run.
- **Stale tip wording off the card:**
  - `src/FeastConverter.sol:130` still speaks of "the interval and the tip". Round 6 removed the
    interval.
  - `docs/plan.md:1103` records the v1.6 plan's 0.25% tip.

  Neither was edited.
