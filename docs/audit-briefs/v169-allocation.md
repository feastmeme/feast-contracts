# The token allocation at `v1.6.9-internal` — 60 / 25 / 14.2 / 0.8

One page, for the external auditor, on the last change before the freeze.

## What changed

Two constants in `src/FeastGenesis.sol`:

| constant | was | is | who reads it |
|---|---|---|---|
| `POOL_BPS` | 6_500 | **6_000** | `FeastFactory.genesis`, indirectly — see below |
| `TEAM_BPS` | 2_000 | **2_500** | `FeastFactory.genesis` |
| `GRANTS_BPS` | 80 | 80 (unchanged) | `FeastFactory.genesis` |
| `EMISSIONS_BPS` | 1_420 | 1_420 (unchanged) | `FeastFactory.genesis`, `FeastEmissions` |

`EMISSIONS_BPS` is not declared; it is `BPS - POOL_BPS - TEAM_BPS - GRANTS_BPS`.
The two shares that moved moved by five points in opposite directions, so the
derivation lands on the same 1_420 it always has. That is the whole of the
change:

```
6_000 + 2_500 + 1_420 + 80 = 10_000
```

**Nothing else under `src/` changed, and nothing else had to.** Every figure the
unit derives from a share already read the constant rather than a copy of it:
the factory's team, grants and emissions amounts (`supply * BPS_x / BPS`),
`FeastEmissions.budget` (`PLATFORM_SUPPLY * EMISSIONS_BPS / BPS`),
`FeastGenesisGrants`' per-partner grant (`PLATFORM_SUPPLY * GRANT_BPS_EACH /
BPS`), and the pool amount — which is not a fifth division at all. One copied
number did exist, in the sandbox recipe's opening liquidity
(`test/FeastRecipe.t.sol`), and it now reads `POOL_BPS` too.

`script/Genesis.s.sol` takes the opening liquidity as an argument computed off
chain from the owner's tick, so it carries no share.

## The pool takes the remainder, and what that does and does not mean

**This section is on its third spelling.** The r1b endorsement round refused the
first (it claimed `POOL_BPS` "reaches no runtime byte" and that a wrong
`POOL_BPS` is "invisible in every token balance"); r2b refused the second (which
attributed both changed operands to `TEAM_BPS`, and over-generalised "no
basis-point constant reaches runtime code"). The corrections are kept visible
rather than quietly applied, because the seal receipt cites this page.

`FeastFactory.genesis` computes the team, grants and emissions amounts and then
gives the pool **the remainder**:

```solidity
uint256 poolAmount = supply - teamAmount - grantsAmount - emissionsAmount;
```

Three things follow:

1. **The remainder is what makes the tokens sum to the supply exactly**, at any
   values of the other three — conservation does not depend on the shares being
   the published ones. This is the one claim that was right the first time.

2. **`POOL_BPS` drives the pool's amount directly, not incidentally.**
   Substituting the derived `EMISSIONS_BPS` into that subtraction collapses it:

   ```
   poolAmount = supply − supply·TEAM/BPS − supply·GRANTS/BPS
                       − supply·(BPS−POOL−TEAM−GRANTS)/BPS
              = supply · POOL_BPS / BPS          (exactly, at this supply)
   ```

   So although no `supply * POOL_BPS / BPS` is written anywhere, that is what
   the factory computes.

3. **A wrong `POOL_BPS` is visible in a token balance, and the pre-existing test
   sees it.** Setting `POOL_BPS = 6_001` and running
   `test_theSplitIsSixtyTwentyFiveFifteenToTheUnit` alone gives:

   ```
   FAIL: 14.2% to emissions: 141900000000000000000000000 != 142000000000000000000000000
   ```

   The site was never unwitnessed; the new bps-level test is an additional
   direct witness, not the first one.

### The two operands that moved, and why only one contract did

`FeastFactory` is 16,088 bytes before and after, with a different hash. The
genesis allocation *ratios* are not in runtime code — `via_ir` folds each into
the token amount it produces. Two of those amounts changed, each with its own
cause:

| operand | width | was | is | moved by |
|---|---|---|---|---|
| the team's amount | `PUSH11` | 200_000_000e18 | 250_000_000e18 | `TEAM_BPS` |
| the pool's amount | `PUSH12` | 650_000_000e18 | 600_000_000e18 | `POOL_BPS` |

What the *paired* change buys is the third amount standing still:

| | pool | team | emissions | `EMISSIONS_BPS` |
|---|---:|---:|---:|---:|
| 6_500 / 2_000 — v1.6.8 | 650m | 200m | 142m | 1_420 |
| 6_500 / 2_500 — team only | 650m | 250m | **92m** | 920 |
| 6_000 / 2_000 — pool only | 600m | 200m | **192m** | 1_920 |
| 6_000 / 2_500 — **shipped** | 600m | 250m | 142m | 1_420 |

Either share moved alone would have taken emissions off the published 14.2%.
Moved together they cancel in `EMISSIONS_BPS`, which is why the grants and
emissions operands are byte-identical and why fifteen of the sixteen contracts
did not notice. The size is unchanged because both changed operands keep their
widths.

One narrowing, because the second spelling over-generalised: the folding claim
is about the four *allocation* shares only. Other basis-point constants in the
same contract do survive as operands, because they are passed on or compared
rather than divided by:

| operand | occurrences | which constant |
|---|---:|---|
| `PUSH2 0x03e8` | 2 | `PLATFORM_REFERRER_BPS` — the `registerPool` argument, and the `CoinCreated` field |
| `PUSH2 0x07d0` | 2 | `PLATFORM_SELF_BURN_BPS` — the same two places |
| `PUSH2 0x07d0` | 2 | `MAX_CREATOR_ALLOCATION_BPS` — it is `public`, so it has a getter, and `create` compares against it |

The last row is a correction from r3b: the second spelling counted four
`0x07d0`s and attributed them all to `PLATFORM_SELF_BURN_BPS`. Both constants
are 2_000, and an operand value is not a consumer.

## Why — the rulings

- **2026-09-16, the owner.** The allocation is **60 / 25 / 14.2 / 0.8**: public
  window 60%, team 25% (36-month linear vesting from the launch window's close,
  the strategic pocket included), users 14.2%, eight genesis partners 0.8%. The
  website's signed copy was published on that ruling. The contracts were not
  changed at the time and continued to route 65 / 20 / 14.2 / 0.8.
- **2026-09-18, the owner.** Change the contracts to match, and re-seal. This is
  the last change before the tree is frozen for the external audit.

The team's vesting *shape* is untouched by both rulings: `TEAM_VESTING_DURATION`
is still 94_672_800 seconds (36 months of 30.4375 days), still linear, still no
cliff, still measured from the window's close. Only the amount it holds moved.

**A reserve-allotment / matching-funding parameter for investors was considered
and refused (owner, 2026-09-18): investors subscribe off chain from the team's
25%, so the contracts gain no optional parameter, no second vesting schedule and
no new branch — the strategic pocket is inside the team's share and is
indistinguishable from it on chain.**

## What holds it

| what | where |
|---|---|
| The four shares are the published ones, in basis points, and sum to `BPS` | `test_theFourSharesAreThePublishedOnesAndSumToTheWhole` |
| A real genesis routes 60 / 25 / 14.2 / 0.8 to the unit, factory empty, every unit accounted for | `test_theSplitIsSixtyTwentyFiveFifteenToTheUnit` |
| The team's vesting wallet holds 25% and releases it linearly over 36 months from the window's close | `test_itVestsLinearlyForThirtySixMonthsFromTheWindowsClose` |
| One basis point off the team's share is caught | `move one basis point of the split` (`tools/mutate.py`) |
| One basis point off the pool's share is caught | `move one basis point of the pool's share` (`tools/mutate.py`, new at v1.6.9) |

The first is deliberately not the tautology it resembles. "The four sum to
`BPS`" **cannot fail** while one of them is the derived remainder, so on its own
it witnesses nothing. What can fail is each *declared* share being the published
figure, and the remainder landing on 1_420 — which it does only while the other
three sum to 8_580. Those are the assertions; the sum is the last line and is
labelled in the test as the tautology it is, kept because it is the sentence the
README makes.

The second writes its figures out as literals rather than reading
`FeastGenesis`, on purpose: a test that divides by the same constant the factory
divides by restates the code instead of witnessing it.

## The documents

`README.md` (the v1.6 paragraph, the invariant table, the genesis recipe),
`docs/interface.md` (`genesis`, for an integrator) and `docs/site-census.md` (the
`genesis-once` mechanism sentence, the seed row, the split row) stated the
routing as a fact about the tree and now state the new one.

Left as they are, because they are dated records and not claims about this tree:
`docs/tokenomics-v1.6.md` (the 2026-09-11 spec input), `plans/**` (the build
plans), and `docs/audit/v16/round*.txt` (round transcripts, which quote the old
test name because that is the name those rounds read). Rewriting them would
forge the record of what earlier rounds saw.

## Four statements this lane could not reach, and four it could

The r1b endorsement round (L1) enumerated every *current* statement of the
allocation still carrying the old figures — a wider set than the first version
of this section listed. Four of them were inside this lane's write surface and
are fixed; four are outside it and are not.

**Fixed here:**

| location | what it said |
|---|---|
| `docs/site-census.md` | the `team-vesting` mechanism sentence, "the team's 20%" |
| `tools/check-census.py` | the `genesis-once` statement, "routed 65/20/14.2/0.8" |
| `tools/check-census.py` | the `team-vesting` statement, "the team's 20%" |
| `tools/mutate.py` | the renunciation mutation's cost, "the team's 20% can be stranded" |

**Not fixed, and outside the surface:**

| location | what it says | what is true |
|---|---|---|
| `audit/invariants.yaml:49` | invariant **P9**: "routed 65/20/14.2/0.8" | 60/25/14.2/0.8 |
| `src/FeastFactory.sol:219-222` | `@notice` "65% into its own pool, 20% to the team's vesting" | 60% / 25% |
| `src/FeastTeamVesting.sol:8` | `@title The team's 20%` | 25% |
| `src/FeastTeamVesting.sol:20` | "so the 20% would sit here for ever" | 25% |

**`audit/invariants.yaml:49` is the one to fix first.** It is not a comment: it
is the active invariant list an external reviewer is handed, and P9 is the
invariant *about this allocation*. It states the old routing as the tree's
current guarantee.

The three `src/` lines are comments. This build sets `bytecode_hash = "none"`
and `cbor_metadata = false`, so none of them reaches a runtime byte and no
bytecode claim in this seal depends on them. They are wrong all the same, and
they are the `@title` of the contract that *holds* the team's share and the
`@notice` of the function that *routes* it.

None of the four is fixed here because this lane's write surface under `src/` is
`FeastGenesis.sol` and `FeastConstants.sol` only, and `audit/` is not in it at
all; widening it was not this lane's call to make. Recorded rather than closed —
here, in the seal receipt, and in commit messages — so the next lane changes
four lines rather than rediscovering them.

**A ninth statement, found by the pipeline the closure was meant to feed.**
The r1a lens of the v1.6.9 pre-audit round reported `docs/audit-briefs/v16-unit.md:116`
as LOW `stale-allocation`: "P9 in the table the invariant list names as its
source still publishes 65/20/14.2/0.8". It was right, and the enumeration above
— which claims to list *every* current statement — missed it, as did the sweep
that closed the other four. `audit/invariants.yaml` declares
`source: "docs/audit-briefs/v16-unit.md, Invariants to break"`, so fixing P9 in
the yaml and not in the document the yaml cites did not leave the old figure
standing: it made the invariant list disagree with its own named source, which
is worse than either state alone. `:37` carried it too. Both now read 60 / 25
with the v1.6-seal figure kept visible beside them.

The lesson is the one this section already teaches, applied to itself: the
sweep enumerated the *sites that state the split* and missed the site that
*defines where the statement comes from*. A document named as a source is a
current statement however historical the rest of it reads.

**Closed at `v1.6.9-audit` (task 567, 2026-09-19).** The next lane was the
pre-audit lane, and its write surface did name those four lines. All four are
now fixed: P9 reads 60/25/14.2/0.8, and the three `src/` comments read 60% /
25% / 25%. `test/FeastBytecodePin.t.sol` passes unchanged at that commit, which
is the evidence that the three comment edits moved no runtime byte — the claim
this section makes above, now measured rather than argued. Two *superseded*
documents still state the old split and are deliberately left alone:
`plans/v16/plan.md:347` (the v1.6 plan, a historical record) and
`docs/tokenomics-v1.6.md:37,103` (the v1.6 tokenomics note, which states an even
older 65/20/15). Neither is a current statement of the guarantee; the audit
pack's notes tell AstraSec so by name.

## How they were found, which is the part worth keeping

Not by grep. `20%` appears in this repository as at least four different
quantities:

| the 20% | what it is | did it move |
|---|---|---|
| `TEAM_BPS` | the team's share of the supply | **yes → 25%** |
| `PLATFORM_SELF_BURN_BPS` / `DEFAULT_SELF_BURN_BPS` | a pool's self-burn share of each fee | no |
| `PLATFORM_BPS` | the platform's share of each fee | no |
| `MAX_HOURLY_SPEND_BPS` | the most of a bucket that may leave in a sliding hour | no |

and a fifth, the creator allocation cap, in `FeastConstants`' prose. The two
header paragraphs fixed in this change each contain a team 20% *and* a fee 20%
*in the same sentence*, so a reader scanning for the figure meets a decoy first.
Enumerating the shares by reading for them — as basis points, as percentages in
prose, as absolute amounts, as derived figures, and as test names — is what
found them; a search for the number is what missed them.

## What this change does not touch

The 15% bootstrap bucket and its split (14.2% / 0.8%); the emissions curve and
its 52 weeks; the eight partners and their 0.1% each; the platform coin's own
pool terms (burn-address creator, 20% self-burn, 10% referral — the 20% there is
a *fee* share and has nothing to do with the team's); the platform's 20% of every
fee; the hook's 20%-per-hour spending bound. Each of those is a different 20%,
and none of them moved.
