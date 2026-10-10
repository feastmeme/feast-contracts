# Mutation checks

Every entry is a deliberate break, applied to the real source, run against the
real suite, and reverted. `tools/mutate.py` performs them; it exits non-zero if
any mutation goes unnoticed, because **a mutation that survives is not a passing
mutation, it is a missing test**.

```
python3 tools/mutate.py
```

Last full run: 2026-09-12, the sealed v1.6.1 unit (`v1.6.1-internal`) —
baseline green, **145 of 145 caught**, exit 0, `KNOWN_UNKILLED` empty. (Before it: 136 of 136 on
the sealed v1.6 unit, `v1.6-internal`.) (Before it: 125 of
125 at `163e003`; the eleven added since — rounds 5 and 6, and the seal's
bytecode-pin mutation — are below.) The authoritative list is
`tools/mutate.py`; the table below is the v1 ledger as it stood after round 1,
and the v1.6 sections at the end list what the unit added.

(2026-09-11, v1.6 package 1: 64 of 65 caught; the one survivor was an
equivalent mutant, below, replaced by a real one that its new witness kills.)

Eight of these were added after round 1, one per HIGH class it found. They are
the point of the fix program: a fix without the mutation that proves it is a
claim, not a change.

The mutations are not a random sample. Each one is a mistake that is easy to
make in a port and silent when made: the arithmetic that makes the four fee
branches agree, the two guards on attacker-supplied referral data, the direction
of the purchase cap, and the subtraction that makes the shares add up.

| # | Mutation | Caught by | What it would have cost |
|---|---|---|---|
| 1 | Divide by `FEE_DENOMINATOR` instead of `FEE_DENOMINATOR + FEE_PIPS` in the exact-in branch | `FeastFeeTakeTest` | Exact-in prices differently from exact-out; the gap between the two routes is free money for whoever notices |
| 2 | The same, in the exact-out branch | `FeastFeeTakeTest` | As above, in the other direction |
| 3 | Use the reference's referral-data check (`length == 0` instead of `!= 32`) | `FeastBucketsTest` | A blob shorter than a word is right-padded when read; a 13-byte one pads into a plausible address, so a truncated referral tag silently pays a commission to an address nobody chose |
| 4 | `abi.decode` the referrer instead of masking it | `FeastBucketsTest` | Decoding an address reverts on dirty upper bits — so a full-width word of garbage reverts **the swap**, which is the exact thing the guard exists to prevent |
| 5 | Compute the creator's remainder by multiplication rather than subtraction | `FeastBucketsTest` | Rounding dust from three independent floor divisions stops being owned by anyone; the four shares no longer sum to the fee |
| 6 | Stop routing a burn-address creator's share into the burn bucket | `FeastBucketsTest` | The platform coin strands ~70% of its own fee at a dead address while the pitch says its fees burn entirely (I14) |
| 7 | Apply the purchase cap to sales as well as purchases | `FeastCapsTest` | Early buyers are trapped in a coin they are not allowed to leave — the opposite of what a fair open is for |
| 8 | Drop the factory-only check in `beforeInitialize` | `FeastHookScaffoldTest` | A stranger creates a pool bearing this hook with a quote token and tick spacing of their choosing, and writes the hook's per-pool state (R1) |
| 9 | Put someone on the exemption list | `FeastCapsTest` | The empty, publicly readable exemption list stops being empty. (v1.6.10: the creator's pre-buy is NOT on this list — `isExempt` is still a constant `false`. It is recognised structurally inside `create` and witnessed by `FeastPrebuyTest`.) |
| 10 | Allow a seed that needs quote nobody supplied | `FeastFactoryTest` | A range straddling the opening price fails with an opaque balance error instead of a named refusal |
| 11 | Trust a route pool that holds one observation | `FeastConverterBoundsTest` | A pool whose "average" *is* its spot price gets priced against as though it were a bound — the state the sample quote token's pool is in on chain today |
| 12 | Drop the spot-versus-average check | `FeastConverterBoundsTest` | The converter trades into whatever price somebody has just made |
| 13 | Swap without a price limit, as the reference does | `FeastConverterBoundsTest` | The conversion may walk the price as far as its own size takes it |
| 14 | Take the caller's tokens before validating the route | `FeastConverterBoundsTest` | A route that could never be priced blames the caller's allowance instead of the pool |
| 15 | Read a window longer than the oracle's history | `FeastOracleTest` | Observations that do not exist are averaged in |
| 16 | Let the oracle answer without enough history | `FeastOracleTest` | A young pool returns a spot price dressed as an average |
| 17 | Let the burn share leave its band | `FeastGovernanceTest` | Governance capture, or a bug in the governor, moves the split anywhere it likes |
| 18 | Apply a governed change immediately | `FeastGovernanceTest` | An epoch's rules change while it is already being earned |
| 19 | Let anyone change the split | `FeastGovernanceTest` | The vote and the three-day delay are bypassed entirely |
| 20 | Measure quorum against the wrapper instead of the coin | `FeastGovernanceTest` | One wrapped token is the whole electorate |
| 21 | Let an open epoch be claimed | `FeastEpochRewardsTest` | A payer claims their share and keeps trading into the same denominator |
| 22 | Let a pot be claimed twice | `FeastEpochRewardsTest` | The pot is drained by repeated claims |
| 23 | Pool every quote token into one ledger | `FeastEpochRewardsTest` | Fees in different stock tokens are summed nominally, handing the pot to whoever traded the priciest |

## The four that survived first time

Recorded because the point of mutation testing is the ones that get through, and
both were real gaps rather than bookkeeping.

**#3, the referral-data length check.** It survived because the masking guard
(#4) independently prevents the revert, so the only remaining consequence was
invisible to every test: a *short* blob being read as a referrer. Fixed by
`test_aShortBlobIsNeverReadAsAReferrer`, which builds a 13-byte blob that pads
into a valid, non-zero address and asserts no commission is invented. Without
it, the exact-length check looked redundant; it is not.

**#10, the single-sided seed refusal.** It survived because no test ever asked
for a range that straddles the opening price. Fixed by
`test_aRangeStraddlingTheOpeningPriceIsRefusedByName`.

**#13, the price limit.** The assertion checked the limit's exact value in one
of the two token orderings and only its direction in the other, so a limit of
the right sign and the wrong size slipped through whenever the fixture's tokens
sorted the other way. Now exact in both branches.

**#14, validating before pulling funds.** This one was more useful than a
missing test: it showed a comment overstating its own property. The original
claim was that validating first means a refused conversion "never touches the
caller's balance" — but the whole call reverts either way, so the transfer rolls
back regardless and no test could ever tell the difference. What the ordering
actually buys is a legible failure: a caller on an unpriceable route is told the
pool's oracle is unusable rather than that their allowance is short. The comment
now says that, and `test_aRefusedRouteBlamesTheRouteAndNotTheAllowance` holds it.

## Knowingly outstanding

One mutation is not killed and is listed in `KNOWN_UNKILLED` rather than
deleted, because a survivor nobody can see is worse than one everybody can.

**"Debit the buy-back bucket by the request, not the spend."** The fix is in
place — the hook debits the realised spend — but no fixture yet makes the
venue's price limit bind *during* a buy-back. That needs a pool shallow enough
that a press of 20% of the accrued bucket moves the price 3%, and in every
fixture built so far the bucket is a small fraction of a percent of pool depth,
so the press always fills whole and the mutation is indistinguishable from the
fix. What is missing is the proof, not the change.

## Not yet covered

Mutations for the modules that do not exist yet — the oracle's minimum
observation age, the button size and interval bounds, the epoch pot's
denominator, and the governance band — are listed in `docs/plan.md` §5 and will
be added with those modules. In particular the plan calls for a mutation that
moves the fee claim back onto the swap path and asserts the paused-quote test
goes red; that one needs the real quote token on the fork, which is still
outstanding.

## v1.6 package 1 (2026-09-11)

Nineteen mutations over the weekly ledger, the gate, the referral rule, the
platform exit and genesis, plus two v1 anchors re-pointed at the code that
replaced theirs (the referrer decode, and "pool every quote token into one
ledger", now against `FeastFeeLedger`). Each names the suite that must notice.

| Mutation | Caught by | What it would have cost |
|---|---|---|
| Drop the referrer-is-the-payer rule | `FeastAttributionTest` | A trader names themselves and collects both the commission and the referral track on their own fees |
| Compare the referrer with the caller instead of the payer | `FeastAttributionTest` | The rule compares against an address no trader names, so it refuses nothing |
| Drop the open gate | `FeastGateTest` | Anyone buys the bottom of the platform coin's curve ahead of the launch window |
| Place the gate below the fee's early return | `FeastGateTest` | The two branches whose fee is taken in `afterSwap` walk through the gate |
| Lift the gate one second early | `FeastGateTest` | A sniper trades in the last second the window owns |
| Widen the gate's bound | `FeastGateTest` | A mistaken genesis key closes the pool for four weeks instead of two |
| Record the launch window's own settlement swap | `FeastGateTest` | Whoever calls `settle` is credited with 1% of the whole pot |
| Credit the burn address with a creator track | `FeastAttributionTest` | A share of the creator track goes to an address nobody controls |
| Release the platform share without debiting it | `FeastPlatformExitTest` | The same share leaves again and again |
| Release the platform share unbounded | `FeastPlatformExitTest` | Round 10's class at the new site: an oversized bucket reverts its exit for ever |
| Accept a code-less sink | `FeastPlatformExitTest` | The platform share leaves to an address no contract occupies |
| Let genesis run twice | `FeastGenesisTest` | The platform coin is minted again |
| Accept a code-less emissions recipient | `FeastGenesisTest` | 14.2% of the supply strands at an empty address |
| Move one basis point of the split | `FeastGenesisTest` | The published 60 / 25 / 15 is not what the supply receives |
| Move one basis point of the pool's share | `FeastGenesisTest` | v1.6.9. No `supply * POOL_BPS / BPS` is written anywhere — the pool takes the remainder — but that remainder collapses to exactly it, so the share reaches the pool's tokens AND, through the derived `EMISSIONS_BPS`, the emissions tokens: 6_001 gives 600.1m and 141.9m, and the published 14.2% is false. The balance assertion already caught that, so this is a second witness at the declared constant rather than the first one at the site |
| Let anyone mint through the platform coin's deployer | `FeastGenesisTest` | An impostor with the platform coin's code appears at a trusted deployer |
| Saturate only the total, not the account | `FeastFeeLedgerTest` | Accounts sum past their total, so a division against it pays more than its pot |
| Treat a zero creator as an account | `FeastFeeLedgerTest` | The zero address holds a creator track |
| Credit a creator who is also the payer twice | `FeastFeeLedgerTest` | Self-trading creators are double-credited |
| Turn the ledger week on Tuesday | `FeastFeeLedgerTest` | The published weekly boundary is not the ledger's |

**The survivor, and why it was a mistake in the mutation, not the code.** The
first "saturate only the total" mutant changed `paid` to `amount` inside the
payer's write — but that write runs only when the paid track fits, where `paid`
already *is* `amount`. An equivalent mutant: it cannot be killed because it
changes nothing. The real hazard is an account credited on a track whose total
was skipped, which needs one track full while another still has room — a state
no test built, because the only saturation test filled all three at once and so
returned before any account was written. `test_aSaturatedTrackSkipsOnlyItselfAndOnBothSides`
builds it; the mutation now credits the referrer's account regardless of its
track, and both that test and the totals fuzz kill it.

## v1.6 internal rounds 4–6 (2026-09-12)

Each mutation reintroduces what a round found, or deletes a guard a round found
unchallenged; each was run against the named suite and caught.

| Mutation | Caught by | What it would have cost |
|---|---|---|
| Fall back to the token cap after launch (r4 H1) | `FeastEmissionsTest` | A moved platform price past the grace drops the value cap; a week emits its whole token cap |
| Refuse only a moved platform price after launch (r4 H1) | `FeastEmissionsTest` | An unreadable platform price after launch settles under the token cap alone |
| Take the redirect from the cap, not from the tracks that emit (r4 M1) | `FeastEmissionsTest` | The escrow's share stops following what the week emits |
| Compose route hops unguarded (r4 L2) | `FeastPricerTest` | An unholdable route price reverts and blocks its week and every later one |
| List a quote of any decimals (r4 L1) | `FeastPricerTest` | A six-decimal quote is priced although the fill's domain is sized for eighteen |
| Let anyone call the window's swap path (r5) | `FeastLaunchWindowTest` | A caller holding its own vault lock spends the pot outside `settle` |
| Let a committer claim twice (r5) | `FeastLaunchWindowTest` | A second claim takes another committer's share |
| Let the sink's price reach zero (r5) | `FeastPlatformSinkTest` | A lot unsold for 193 hours goes for nothing |
| Drop the sink's post-sale floor (r5) | `FeastPlatformSinkTest` | After a sale the price halves towards zero |
| Claim without retiring the liability (r6) | `FeastEmissionsTest` | The books owe more than is held; the final burn keeps what nobody is owed |
| Burn an expired week without retiring its liability (r6) | `FeastEmissionsTest` | Burned tokens stay on the books as owed |
| Release a redirect without retiring its liability (r6) | `FeastEmissionsTest` | Tokens paid to the escrow stay on the books as owed |
| Round an account's priced credit up (r6) | `FeastEmissionsTest` | At a fractional price each account is owed the whole pot |
| Pay a grant without recording it (r6) | `FeastGenesisGrantsTest` | A partner is paid the same grant again, out of the others' |
| Burn nothing in `burnStray` (r6) | `FeastPlatformSinkTest` | Platform coin sent to the sink never burns |
| Change one byte of a sealed contract (seal) | `FeastBytecodePinTest` | A contract changed after the seal deploys bytes the auditor never read |

## v1.6.1, the pre-audit pass (2026-09-12)

| Mutation | Caught by | What it would have cost |
|---|---|---|
| Let the fill serve a sale larger than the venue's delta (CA-ece82bf971) | `FeastFillDeltaBoundTest` | Fill plus the pool's own take exceeds the trader's specified leg and the venue refuses the sale |
| Let the fill serve a sale worth more than the venue's delta (CA-ece82bf971) | `FeastFillDeltaBoundTest` | Fill plus pool proceeds exceeds the quote leg, so an otherwise executable sale reverts |
| Truncate the clock before subtracting it (CA-e2ba62d849) | `FeastOracleTest` | Every observation write and every average reverts for a pool whose history crosses 2106 |
| Subtract two truncated stamps directly (CA-e2ba62d849) | `FeastOracleTest` | Interpolating a cumulative across the rollover reverts instead of measuring the gap |
| Order the ring by raw stamps (CA-e2ba62d849) | `FeastOracleTest` | The search picks the wrong observation once part of the ring is the far side of the rollover |
| Truncate the clock before a pool's stamp, converter (CA-e2ba62d849) | `FeastConverterBoundsTest` | Every conversion through a pool whose history crosses 2106 reverts |
| Truncate the clock before a pool's stamp, pricer (CA-e2ba62d849) | `FeastPricerTest` | A route pool whose history crosses 2106 reverts settlement instead of pricing |
| Deliver the whole entitlement on a taxed quote (B7) | `FeastTaxedQuoteBoundaryTest` | The declared boundary stops being what the tree actually does |

Round 4's M2 (the genesis script deploying a 42 KB script contract) has no
one-line mutant that compiles; its fail-first evidence is the red commit
`eb4c97b`, where the state-diff test saw the 42,166-byte creation.
