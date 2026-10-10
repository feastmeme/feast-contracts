# Site census

Keyed by **invariant**, not by what an audit round happened to find.

Version 1 was derived from rounds 1 and 2, so it covered five mechanisms and
missed nine. Round 3's coverage lens was asked, verbatim, "is there a guarded
behaviour that has no `### mechanism:` section at all?" and named most of what is
now below. It also observed that the v1 checker passed only because it
*discovered* sites by grepping particular spellings — so it could not see the
realised-spend sites whose settlement happened through a conversion rather than
an assignment. A guard that finds only what it knows how to spell is not a guard.

**Nine of the fourteen invariants below had zero sites in v1.** That number is the
honest measure of how weak the old census was.

`tools/check-census.py` now has a different job: the invariant list in that file
is the authority, and the check is that every invariant has a section, every
section lists sites, and every site names a test that exists. The spelling scan
survives under `--scan` as a warning that can never pass or fail the run.

**Round 4 added `--self-test`, because the checker could not fail.** Its row
pattern required the closing backtick to sit against the column separator, so
four of the then sixty-five rows were skipped along with every test obligation
they carried — and both audit lenses proved it independently by replacing those
rows' test names with names that do not exist and watching the checker still
return zero. A gate that cannot fail is not a gate. The probe is now part of it:
every row a reader would count is a row the parser counts, that number matches
the count the census declares of itself, and **every single row is damaged in
turn to confirm the checker notices**.

Round 4 also added the five obligations at the end, which both lenses named when
asked the second question. Fourteen sections had shown that fourteen *names*
were covered, not that fourteen *obligations* were.

**The v1 cut (2026-09-09) shrank this from 112 rows to 87**, and round 6's
withdrawal of the interval-plus-floor pacing replaced two mechanisms with one
(`spending-rate`), leaving 88. The platform
conversion and buy-back buttons are not in this tree — they are preserved on
branch `v1.1/platform-buttons` — so every row that guarded them is gone rather
than left pointing at code nobody can reach. Two invariants went with them and
are marked *retired for v1* below: `reward-precision` and `governance-authority`
describe the pot and the vote over its split, and an invariant with no reachable
code is not an invariant. Both return with the buttons.

**v1.6 package 1 (2026-09-11) took it from 99 rows to 117.** `epoch-attribution`
became `fee-attribution` (the weekly three-track ledger), `open-gate` and
`genesis-once` are new, and the platform exit `releasePlatformFees` joined
`bounded-settlement`, `realised-spend` and `pool-isolation` — the settlement
enumeration found it by itself before any row was written, which is the check
doing its job.

```
python3 tools/check-census.py              # completeness against the invariant list
python3 tools/check-census.py --self-test  # and prove the checker can fail
python3 tools/check-census.py --scan       # plus the secondary spelling warning
```

---

### mechanism: fee-conservation

*Every wei taken is banked in exactly one bucket, and no bucket total ever decreases.*

| Site | Predicate | Test |
|---|---|---|
| `src/FeastHook.sol::_bank` | The four shares are computed from this accrual and the creator takes its remainder, so they sum to it exactly; every total is monotone. | `testFuzz_everyWeiTakenIsBankedInExactlyOneBucket`, `testFuzz_entitlementNeverDecreasesAcrossInterleavedClaims` |
| `src/FeastHook.sol::_accrue` | Mints the claim that backs what `_bank` records, and records the payer. | `test_theLedgerIsActuallyConnected` |
| `src/FeastHook.sol::_bank` (bound referrer) | A bound wallet's trade splits exactly as a named trade always has: the binding decides WHO is paid and never how much, and `_bank` is not modified for it. | `testFuzz_theFourSharesStillSumToWhatWasTakenForABoundWallet`, `test_aBoundWalletsUnnamedTradeIsSplitAsAReferredTrade` |
| `src/FeastHook.sol::_beforeSwap` | The specified-leg fee, or zero. | `test_exactInputBuy_takesOnePercentOfTheQuoteEnteringThePool` |
| `src/FeastHook.sol::_afterSwap` | The unspecified-leg fee from realised deltas, or a refusal. | `testFuzz_aPartialFillIsEitherRefusedOrChargedOnWhatFilled` |
| `src/FeastHook.sol::_specifiedLegFee` | One definition of the corrected rate, shared by the branch that charges it and the one that checks it. | `testFuzz_exactInAndExactOutAgreeOnPrice` |
| `src/FeastHook.sol::collectLpFees` | LP income is banked by the same rule, minus the pot. | `test_theLockedPositionsFeesAreCollectableIntoTheSameBuckets` |
| `src/FeastHook.sol::registerPool` | The share bands are validated once, at creation, which is what makes `_bank`'s remainder subtraction unable to underflow later. Round 4 (r4a answer 1). | `test_registrationRefusesSharesOutsideTheirBands`, `test_registrationAcceptsBothSharesAtTheirMaximum` |
| `src/FeastHook.sol::registerPool` (the caps themselves) | v1.6.2 (H3): the self-burn cap is half the fee and the referrer cap three tenths of it, pinned as numbers rather than as symbols, so moving a constant fails a test. | `test_theSelfBurnCapIsHalfTheFeeAndTheReferrerCapIsThirtyPercent` |

### mechanism: opening-caps

*A wallet may buy at most its slice while the window is open; sales are never capped.*

| Site | Predicate | Test |
|---|---|---|
| `src/FeastHook.sol::_afterSwap` | Purchases only, per `tx.origin`, only before `capEndBlock`. | `test_aWalletCannotTakeMoreThanItsSliceInTheOpeningBlocks`, `test_sellingIsNeverCapped` |
| `src/FeastHook.sol::registerPool` | The cap is derived from supply once, with no setter. | `test_theCapWindowAndSizeAreVisibleOnChain` |
| `src/FeastHook.sol::_onPoolInitialized` | The window opens at creation and closes by block number. | `test_theCapIsGoneOnceTheOpeningBlocksHavePassed` |
| `src/FeastHook.sol::isExempt` | Nobody is exempt, and nothing can add anyone. | `test_theExemptionListIsEmptyAndCannotBeAddedTo` |

### mechanism: principal-locking

*Seeded liquidity can never be removed; only a zero-delta fee collection is reachable.*

| Site | Predicate | Test |
|---|---|---|
| `src/FeastHook.sol::seedLiquidity` | Factory-only, once, and the only positive-delta call. | `test_seedingIsTheFactorysAloneAndHappensOnce` |
| `src/FeastHook.sol::_lockAcquired` | The two `modifyLiquidity` calls are `+liquidity` at seed and exactly `0` at collection; no path passes a negative. | `test_noWithdrawalPathExistsOnTheHook`, `test_collectingFeesLeavesThePositionIntact` |
| `src/FeastFactory.sol::create` | Seeds once and burns only a rounding remainder. | `test_oneTransactionProducesACoinAPoolAndLockedLiquidity` |
| `src/FeastHook.sol::collectLpFees` | The public entry point: the only liquidity operation any caller can reach, and it is a zero-delta collection. Round 4 (r4a answer 1) — the callback branch was listed and the door to it was not. | `test_collectingFeesLeavesThePositionIntact`, `test_noWithdrawalPathExistsOnTheHook` |
| `src/FeastFactory.sol::_seed` | v1.6: the one seeding sequence, shared by `create` and `genesis` — a positive delta only, and only a rounding remainder burned. | `test_oneTransactionProducesACoinAPoolAndLockedLiquidity`, `test_theSplitIsSixtyTwentyFiveFifteenToTheUnit` |
| `src/FeastFactory.sol::_seed` (sizing) | v1.6.1, rounds 8-11: the constraint is the factory's, and no formula for it is published (four were broken). A position that leaves more than 1% of the allocation unused is refused by name; a liquidity found by simulating `create()` is accepted at any opening price, at either usable edge and with a creator allocation taken out; some configurations admit none, and the simulation says so. | `test_aPositionThatLeavesMoreThanOnePercentIsRefusedByName`, `test_simulatingFindsAnAcceptedLaunchAtAUnitPrice`, `test_simulatingFindsAnAcceptedLaunchAtTheUsableEdge`, `test_simulatingFindsAnAcceptedLaunchWithAPrebuy`, `test_someConfigurationsAdmitNoLiquidityAndTheSimulationSaysSo` |
| `src/FeastFactory.sol::genesis` (seed) | The platform coin's 60% is seeded through `_seed` like any coin; nothing in genesis can pass a negative liquidity delta. | `test_theSplitIsSixtyTwentyFiveFifteenToTheUnit`, `test_noWithdrawalPathExistsOnTheHook` |

### mechanism: vesting-entitlement

*An allocation pays only its recorded recipient, linearly, never more than its total.*

| Site | Predicate | Test |
|---|---|---|
| `src/FeastVesting.sol::createAllocation` | Factory-only, once per coin, recipient fixed. | `test_zeroAllocationMeansNoVestingAtAll` |
| `src/FeastVesting.sol::claim` | Anyone may press; only the recipient is paid; never more than `total`. | `test_vestingAccruesLinearlyAndOnlyEverPaysTheFixedRecipient` |
| `src/FeastVesting.sol::_vested` | Linear between start and end, monotone. | `test_vestingAccruesLinearlyAndOnlyEverPaysTheFixedRecipient` |
| `src/FeastFactory.sol::create` | A zero recipient is refused before an allocation can exist. | `test_aZeroAddressCreatorIsRefused` |
| `src/FeastVesting.sol::claimable` | Subtracts what has already been claimed from what has vested, so the two reads cannot disagree with the payment. Round 4 (r4a answer 1). | `test_vestingAccruesLinearlyAndOnlyEverPaysTheFixedRecipient` |

### mechanism: oracle-write

*Every swap that moves a feast pool's price records the tick it left behind.*

| Site | Predicate | Test |
|---|---|---|
| `src/FeastHook.sol::_observePrice` | The one implementation: post-swap tick, written once. | `test_theOracleReportsThePriceThatActuallyPrevailed` |
| `src/FeastHook.sol::_afterSwap` | Observes after every ordinary swap. | `test_theOracleReportsThePriceThatActuallyPrevailed` |
| `src/FeastHook.sol::_lockAcquired` (`Action.Buyback`) | The hook's own swap is not called back, so it observes explicitly. | `test_aButtonsOwnSwapIsObservedByTheOracle` |
| `src/FeastOracle.sol::write` | Last write in a second wins; the cumulative is unchanged for zero elapsed time. | `test_twoSwapsInOneSecondKeepTheLaterTick` |

### mechanism: realised-spend

*A bucket is debited by what was actually spent, and no path leaves value outside a claim.*

**Withdrawn under Rule 8** — see `docs/plan.md` boundaries. The remainder class
is gone rather than handled: the converter is all-or-nothing, so "spent" and
"requested" are the same number by construction, and the sites below have
nothing left to reconcile.

| Site | Predicate | Test |
|---|---|---|
| `src/FeastHook.sol::buyBackAndBurn` | Debits the realised quote returned from the lock. | `test_aPartiallyFilledPressDebitsOnlyWhatItSpent` |
| `src/FeastHook.sol::claimCreator` | Pays exactly the pending amount. | `test_theCreatorCanClaimAndTheClaimAlwaysPaysTheCreator` |
| `src/FeastHook.sol::claimReferrer` | Zeroes the entry it pays. | `test_aReferrerCanClaimTheirOwnCommission` |
| `src/FeastHook.sol::_claimTo` | Shared arithmetic for both of the above. | `test_theCreatorCanClaimAndTheClaimAlwaysPaysTheCreator` |
| `src/FeastHook.sol::claimAsBnb` | Claims to itself, converts all of it, delivers all of it. | `test_onlyTheClaimantMayChooseTheirOwnConversionRoute` |
| `src/FeastConverter.sol::_hop` | Each hop consumes the whole amount offered to it, measured from the venue's own signed return rather than from a balance. This is where the round-3 withdrawal is actually enforced; round 4 found it enforced once, at the outer edge, and blind to every hop after the first. | `test_aMiddleHopThatPartFillsRefusesTheWholeRoute`, `test_aFirstHopThatPartFillsRefusesTheWholeRoute` |
| `src/FeastHook.sol::_lockAcquired` (`Action.Buyback`) | Reports realised spend; the self-burn bucket is debited by that and never by the request. | `test_aPartiallyFilledPressDebitsOnlyWhatItSpent` |
| `src/FeastConverter.sol::convert` | Custody: a refused route leaves nothing of the input behind, and a stray balance can never change what a conversion costs. Boundary B2. | `test_aRefusedRouteStrandsNothingInTheConverter`, `test_aDonatedUnitDoesNotBrickConversion` |
| `src/FeastHook.sol::releasePlatformFees` | v1.6: the platform bucket is debited by exactly what reached the sink, and no other bucket moves. | `test_anyoneMovesExactlyThePlatformShareToTheSink`, `test_theExitTouchesNoOtherBucket`, `test_theBucketRefillsAndLeavesAgain` |
| `src/FeastHook.sol::_fill` | v1.6: the self-burn bucket is debited by exactly the quote paid to the seller, and the coin received is burned. | `test_anExactInputSaleIsPartlyFilledFromTheBucketAtSpot` |

### mechanism: fee-attribution

*Every fee is credited whole to its payer, its coin's creator and its referrer, in the week and quote token it was paid in; a week's total is exactly the sum of its accounts. (v1.6: replaces v1's `epoch-attribution`, the daily payer-only ledger.)*

| Site | Predicate | Test |
|---|---|---|
| `src/FeastFeeLedger.sol::record` | A fee is credited whole to each of its three roles, in its own week and quote, and to nobody else. | `test_eachTrackCreditsTheWholeFeeToItsOwnRole`, `test_aWeekIsClosedWhenTheNextBegins`, `test_eachQuoteKeepsItsOwnLedger` |
| `src/FeastFeeLedger.sol::record` (totals) | A total is exactly the sum of its accounts, over any interleaving of roles including coinciding ones; a track with no headroom is skipped on both sides, never reverted. | `testFuzz_eachTotalIsExactlyTheSumOfItsAccounts`, `test_aTrackWithNoHeadroomSkipsBothSidesAndTheSwapStillRecords`, `test_aFeeLargerThanATrackIsIgnoredNotReverted` |
| `src/FeastFeeLedger.sol::record` (roles) | One address in two roles is credited in both; a zero role is not an account; only the hook writes. | `test_oneAddressInTwoRolesIsCreditedInBoth`, `test_theCreatorMayAlsoBeTheReferrer`, `test_aZeroRoleIsNotAnAccount`, `test_onlyTheHookMayRecord` |
| `src/FeastFeeLedger.sol::record` (monotone) | A recorded figure never decreases, which is what makes it safe to pay against. | `testFuzz_aRecordNeverDecreasesAnything` |
| `src/FeastFeeLedger.sol::weekOf` | Weeks turn at Monday 00:00 UTC. | `test_weeksTurnAtMondayMidnightUtc` |
| `src/FeastFeeLedger.sol::weekStart` | A week begins on its Monday; `weekStart(weekOf(t)) ≤ t`. | `test_weeksTurnAtMondayMidnightUtc` |
| `src/FeastFeeLedger.sol::_fits` | The headroom predicate: a zero or oversized fee fits nowhere, and no field can carry into the next. | `test_aSaturatedTrackSkipsOnlyItselfAndOnBothSides`, `test_aFeeLargerThanATrackIsIgnoredNotReverted`, `test_aZeroFeeRecordsNothing` |
| `src/FeastFeeLedger.sol::_decode` | The views decode exactly what was packed, field by field. | `test_eachTrackCreditsTheWholeFeeToItsOwnRole`, `testFuzz_eachTotalIsExactlyTheSumOfItsAccounts` |
| `src/FeastHook.sol::_accrue` | Supplies the payer (`tx.origin`), the creator (none for a burn-address creator) and the resolved referrer, on every fee branch; records nothing while the pool is gated. | `test_eachBranchCreditsTheWholeFeeToPayerCreatorAndReferrer`, `test_thePayerIsTheOriginNotTheRouter`, `test_aBurnAddressCreatorEarnsNoCreatorTrack`, `test_theOpenersTradeIsChargedButRecordedNowhere`, `test_theLedgerIsActuallyConnected` |
| `src/FeastHook.sol::_referrerFrom` (payer) | A referrer equal to the payer is no referral at all — no commission and no referral credit — decided here once; a referral on a coin with no commission still counts. | `test_aSelfReferralIsNoReferralOnAnyBranch`, `testFuzz_aReferrerEqualToThePayerNeverCredits`, `test_naming_theRouterIsAnOrdinaryReferral`, `test_aReferralOnACoinWithNoCommissionStillEarnsTheTrack` |
| `src/FeastHook.sol::collectLpFees` | LP income has no payer, so it is recorded on no track. | `test_lpFeesNeverEnterAnEpochPot` |
| `src/FeastHook.sol::_bank` | LP income's platform share buys and burns instead (unchanged from v1). | `test_lpFeesNeverEnterAnEpochPot` |
| `src/FeastHook.sol::claimAsBnb` (native quote) | v1.6.7 (the v1.6.6 pack, BOTH families): a pool quoted in wrapped native is paid directly, because the converter accepts no route for that input — an empty route is refused, every route must end in wrapped native, and no hop may return to the input token. The platform coin's own pool is quoted in wrapped native. | `test_claimAsBnbPaysAnAlreadyWrappedNativeClaim`, `test_andTheOneHopRouteACallerWouldTryIsPaidTheSameWay` |

### mechanism: open-gate

*Before `openAt`, only the pool's opener may trade it, on every fee branch; the gate lifts at `openAt` exactly; it is bounded at registration; and a pool without one is untouched by it.*

| Site | Predicate | Test |
|---|---|---|
| `src/FeastHook.sol::_beforeSwap` (gate) | A stranger is refused before `openAt` on all four branches — including the exact-in sell, whose fee is taken only in `afterSwap` — and one second before is still closed. | `test_beforeOpenAtAStrangerCannotTradeOnAnyBranch`, `test_oneSecondBeforeOpenAtIsStillClosed` |
| `src/FeastHook.sol::_beforeSwap` (opener) | The opener trades before `openAt`; everyone trades from `openAt`. | `test_theOpenerTradesBeforeOpenAtOnEveryBranch`, `test_atOpenAtEveryoneTrades`, `test_afterOpenAtTradesAreRecordedAgain` |
| `src/FeastHook.sol::_beforeSwap` (no gate) | A pool registered with no gate trades for everyone from its first block. | `test_aPoolWithNoGateTradesAtOnceForEveryone` |
| `src/FeastHook.sol::buyBackAndBurn` (gate) | Round 1 (M1): the hook's own swap skips its callbacks, so the button carries the gate itself; it works once the pool opens. | `test_theBuyBackButtonIsClosedWhileThePoolIsGated`, `test_theBuyBackButtonWorksOnceThePoolOpens` |
| `src/FeastHook.sol::registerPool` (bound) | A gate needs an opener and an opener needs a gate; `openAt` lies in the future and no more than `MAX_GATE_DURATION` away. | `test_aGateWithNoOpenerIsRefused`, `test_anOpenerWithNoGateIsRefused`, `test_aGateAlreadyInThePastIsRefused`, `test_aGateLongerThanTheBoundIsRefusedAndTheBoundItselfIsAccepted` |
| `FeastGenesis.MAX_GATE_DURATION` | Round 1 (L1): fourteen days, asserted literally. | `test_theGateBoundIsFourteenDaysLiterally` |
| `src/FeastFactory.sol::genesis` (gate) | The platform coin's pool carries the gate genesis named, and the bound holds through genesis too. | `test_nobodyTradesThePlatformPoolBeforeTheWindowOpensIt`, `test_theGateCannotBePushedOutOfBoundsThroughGenesis` |

### mechanism: genesis-once

*The platform coin is minted once, by the factory, through one call by one key; its supply is routed 60 / 25 / 14.2 / 0.8 to the unit; afterwards nothing in package 1 has a privileged caller.*

| Site | Predicate | Test |
|---|---|---|
| `src/FeastFactory.sol::genesis` (authority) | Only the genesis key, and only once; afterwards the key, like any stranger, is refused by every restricted entry point in package 1. | `test_onlyTheGenesisKeyMayCallIt`, `test_itRunsOnceAndThenNothingIsPrivileged`, `test_afterGenesisTheGenesisKeyHoldsNoPower`, `test_aStrangerHoldsNoPowerEither` |
| `src/FeastFactory.sol::genesis` (split) | Every unit of the supply is accounted for, in exactly the published shares — 60 / 25 / 14.2 / 0.8 since the owner's ruling of 2026-09-16, applied to the contracts at v1.6.9. The shares are also asserted one level up, in basis points, so a typo in a declared share fails without a genesis having to be run. | `test_theSplitIsSixtyTwentyFiveFifteenToTheUnit`, `test_theFourSharesAreThePublishedOnesAndSumToTheWhole` |
| `src/FeastFactory.sol::genesis` (recipients) | Every recipient must have code — the sink included since v1.6.22: it used to be allowed to await its code, and the window's 1% then stranded in it (`CA-8f254aa78e`). A zero sink is refused. | `test_aRecipientWithNoCodeIsRefused`, `test_theSinkMustHaveCodeLikeEveryRecipient`, `test_aZeroSinkIsRefused`, `test_theWindowsFeeNeverLeavesForAnAddressThatCanNeverSellIt` |
| `src/FeastFactory.sol::_requireRecipient` | Rounds 1 and 2 (M2, M1): every contract genesis names must exist, report its own role (`IFeastGenesisRecipient.genesisRole`) and serve this platform coin — so no allocation reaches the factory, the hook, the oracle, the ledger, the pool manager or any contract that cannot spend it, and five roles mean five contracts. The sink, which must now exist, must be a sink. | `test_aContractThatDoesNotSayWhatItIsIsRefused`, `test_aRecipientThatIsAPackageOneContractIsRefused`, `test_theThreeRecipientsMustBeDistinct`, `test_aRecipientServingAnotherCoinIsRefused`, `test_aSinkWithCodeMustSayItIsTheSink` |
| `src/FeastFactory.sol::_requireTrusted` / `_questions` | v1.6.22, the owner's ruling of 2026-09-25: every recipient genesis names passes ONE path, before it is paid or recorded, that asks the whole of an 18-row table drawn from its exits — every collaborator an exit calls is the platform's own, every clock it waits on is the one genesis derives, every amount it holds is the amount genesis sends. Any other answer, or none, is refused by that question's own error, naming both answers; the set genesis trusts is derived from a trace of what it pays, calls and stores. | `test_theTableIsTheReviewedTable`, `test_theQuestionsAreTheRecipientsOwnSelectors`, `test_everyQuestionAnsweredWronglyIsRefusedByName`, `test_everyQuestionLeftUnansweredIsRefusedByName`, `test_theEngineReadsAnAnswerByItsLengthToTheBit`, `test_everyContractGenesisPaysCallsOrStoresWasAskedFirst`, `test_genesisRefusesGrantsWithNoGuardian`, `test_genesisRefusesAWindowWiredToAnotherFactory` |
| `src/FeastFactory.sol::genesis` (terms) | The platform coin's pool: burn-address creator, 20% self-burn, 10% referral, paired with wrapped native. | `test_thePlatformCoinsPoolHasItsOwnTermsAndItsGate` |
| `src/FeastPlatformTokenDeployer.sol::deploy` | Only the factory mints the platform coin, at the address predicted from day one. | `test_onlyTheFactoryMayMintThePlatformCoin`, `test_theCoinIsWhereItWasPredictedFromDayOne` |
| `src/FeastPlatformToken.sol` (no mint entry point) | Fixed supply by absence; votes exist only once delegated. | `test_thePlatformCoinHasNoMintEntrypoint`, `test_heldTokensHaveNoVotesUntilDelegated` |
| `src/FeastHook.sol::releasePlatformFees` (sink) | The platform share leaves only to the sink genesis bound, and waits while it is unbound or has no code. | `test_theExitPaysTheSinkGenesisNamed`, `test_beforeGenesisNamesASinkTheExitRefuses`, `test_aSinkWithNoCodeYetIsRefusedAndTheBucketIsUntouched` |
| `src/FeastHook.sol::_isThePlatformSink` | Round 2 (M1): the exit pays only a contract that reports the sink's role for this platform coin — genesis could not question a sink that did not exist yet. | `test_aSinkThatIsNotTheSinkIsRefusedAtTheExit` |

### mechanism: internal-fill

*An exact-input sale is offered to the pool's own buy-and-burn bucket first, at spot, within the TWAP bound, inside one allowance shared with the button and one settlement; the coin bought is burned; the fee is 1% of the whole sale; the fill never refuses a trade. (v1.6, owner ruling Q15: the v1.1 floor's layer 2.)*

| Site | Predicate | Test |
|---|---|---|
| `src/FeastHook.sol::_fill` (price) | The bucket pays spot, rounded down: never more than the pool would, never less than the curve gives the seller. | `test_anExactInputSaleIsPartlyFilledFromTheBucketAtSpot` |
| `src/FeastHook.sol::_quoteForCoin` | Round 3 (L2): one exact rounding from the rational price, only inside the domain where the price's square fits a word; outside it, no fill. | `test_aTinyFillIsPricedWithOneRoundingNotTwo`, `test_anExactInputSaleIsPartlyFilledFromTheBucketAtSpot` |
| `src/FeastHook.sol::_fill` (venue delta) | v1.6.1 (CA-ece82bf971): the fill serves only a sale whose coin amount, and whose value at spot, each fit the venue's `int128` delta, so fill plus pool proceeds can never overflow the trader's merged leg; a larger sale is not refused, it goes to the pool unfilled. | `test_aSaleWorthMoreThanTheVenuesDeltaIsNotFilled`, `test_aSaleLargerThanTheVenuesDeltaIsNotFilled`, `test_aSaleJustInsideTheVenuesDeltaIsStillFilled` |
| `src/FeastHook.sol::_fill` (domain) | Round 4 (L1), a declared boundary: a pool whose raw price falls outside the domain (a six-decimal quote at 1e-20) trades normally and is never filled — with a bucket, an allowance and a mature oracle. | `test_aSixDecimalQuoteTradesNormallyButIsNeverFilled` |
| `src/FeastHook.sol::_beforeSwap` (largest request) | Round 3 (L1): `type(int256).min` has no positive counterpart and is never filled, so a price-limited sale of that size is not refused. | `test_theLargestSignedRequestIsNotRefusedByTheFill` |
| `src/FeastHook.sol::_fill` (burn) | The coin taken is burned for real and the bucket is debited by exactly the quote paid. | `test_anExactInputSaleIsPartlyFilledFromTheBucketAtSpot` |
| `src/FeastHook.sol::_fill` (size) | At most one unit short of the sale, so the pool always swaps something; the filled part moves no price. | `test_theFilledPartMovesThePriceNothing`, `testFuzz_noSaleSizeIsRefusedByTheFill` |
| `src/FeastHook.sol::_fill` (claims) | Rounds 2 and 3 (M2, M1): nothing physical moves on the swap path — the fill pays in quote claims and is paid in coin claims — so neither borrowed custody nor a router that pays in before the swap can be refused, and a frozen quote cannot refuse a fill. | `test_aSaleIsNotRefusedWhenTheVaultsCoinIsBorrowed`, `test_aRouterThatPaysInBeforeTheSwapIsNeverRefused`, `test_aFrozenQuoteDoesNotStopAFilledSale` |
| `src/FeastHook.sol::_fill` (refusals) | No fill on a gated pool, with no allowance, or for any trade but an exact-input sale — including a dust buy whose fee rounds to zero. | `test_noFillWhileThePoolIsGated`, `test_noFillForAnyOtherKindOfTrade` |
| `src/FeastHook.sol::_spotIsNearAverage` | No fill into a moved spot, and a young oracle means no fill rather than a revert. | `test_noFillWhenSpotHasBeenMovedFromTheAverage`, `test_noFillWhileTheOracleIsYoung` |
| `src/FeastHook.sol::_takeFill` | `afterSwap` charges the fee on the whole sale and reports the seller's own amounts, fill included. | `test_theFeeOnAFilledSaleIsOnePercentOfTheWholeSale`, `test_aFilledSaleReportsTheSellersOwnAmounts` |
| `src/FeastHook.sol::_beforeSwap` (fill branch) | Only the fee-free early branch can fill, and only for an exact-input sale. | `test_noFillForAnyOtherKindOfTrade` |

### mechanism: trade-record

*Every ungated swap emits exactly one `Trade` with the trader's own amounts, the pool's post-swap price, the payer and the fee; nothing else emits one. (v1.6, owner ruling Q24: the chart is built from events alone.)*

| Site | Predicate | Test |
|---|---|---|
| `src/FeastHook.sol::_afterSwap` (specified leg) | The fee taken in `beforeSwap` is subtracted from the pool's quote, so the amount is the trader's. | `test_eachBranchEmitsOneTradeWithTheTradersOwnAmounts` |
| `src/FeastHook.sol::_afterSwap` (unspecified leg) | The fee taken in `afterSwap` likewise; one event whether or not a fee rounds to zero. | `test_eachBranchEmitsOneTradeWithTheTradersOwnAmounts` |
| `src/FeastHook.sol::_emitTrade` | Nothing for a gated swap. | `test_theLaunchWindowsGatedSwapEmitsNoTrade` |
| `src/FeastHook.sol::buyBackAndBurn` (Trade) | Round 2 (L1): the button's swap is a trade in the pool — one `Trade`, bought by the hook, no feast fee, the coin bought before the tip and the burn. | `test_aBuyBackEmitsOneTrade` |
| `src/FeastHook.sol::_observePrice` | The reported price is the pool's own post-swap `sqrtPriceX96`, from the read the oracle write already makes. | `test_eachBranchEmitsOneTradeWithTheTradersOwnAmounts` |
| `src/FeastHook.sol::collectLpFees` | An LP collection is not a trade. | `test_lpFeesNeverEnterAnEpochPot` |

### mechanism: priced-quotes

*A quote is priced only through its pinned route, from pools that can vouch for their price; otherwise the pricer says why and never reverts.*

| Site | Predicate | Test |
|---|---|---|
| `src/FeastPricer.sol::constructor` | A route connects, ends in wrapped native, lists each quote once, and has at most two hops. | `test_aRouteMustConnectAndEndInWrappedNative` |
| `src/FeastPricer.sol::_requireEighteenDecimals` | Round 4 (L1): every listed quote, wrapped native included, is an 18-decimal token; any other is refused at construction. | `test_aPricedQuoteMustHaveEighteenDecimals` |
| `src/FeastPricer.sol::_vouch` | A pool with one observation or under five minutes of history is unpriceable; spot pushed past the tick bound is `Moved`; neither reverts. | `test_aPoolThatCannotVouchIsUnpriceableNotReverted`, `test_aMovedSpotIsReportedAsMoved` |
| `src/FeastPricer.sol::_ratioQ128` | A hop is priced from the spot square-root price in the right direction. | `test_aHopIsPricedFromTheSpotSquareRootPriceInTheRightDirection` |
| `src/FeastPricer.sol::_inVenueRange` | v1.6.6 (Q2): a square-root price outside the venue's own `MIN_SQRT_RATIO..MAX_SQRT_RATIO`, zero included, is `Unpriceable` in BOTH readers — never a panic, because `settle` reads this in a loop and a panic there blocks every emission week. | `test_atTheVenuesFloorTheQuoteIsPricedAndOneBelowItIsRefused`, `test_atTheVenuesCeilingTheQuoteIsUnpriceableAndOneBelowItPrices`, `test_belowTheWordBoundaryThePricerStillAnswers`, `test_thePlatformPriceIsUnpriceableOutsideTheVenuesRangeToo` |
| `src/FeastPricer.sol::priceQ128` | Wrapped native is one; an unlisted quote is unpriceable. | `test_wrappedNativeIsWorthOne`, `test_anUnlistedQuoteIsUnpriceable` |
| `src/FeastPricer.sol::priceQ128` (composition) | Round 4 (L2): a route price no word can hold is unpriceable, never a revert; a product that fits is exact. | `test_aRoutePriceTooLargeToHoldIsUnpriceableNotReverted` |
| `src/FeastPricer.sol::platformPerNativeQ128` | The platform coin has no price before its pool exists and has history. | `test_thePlatformCoinIsUnpriceableUntilItHasHistory` |

### mechanism: emission-settlement

*A week settles once, in order, after it closes; it emits the smaller of its value cap, its token cap and what is left, by the week's weights; nothing ever settled exceeds the budget.*

| Site | Predicate | Test |
|---|---|---|
| `src/FeastEmissions.sol::settle` (order) | In order, once, only after the week closes, within the 52 weeks. | `test_aWeekSettlesOnlyAfterItClosesInOrderAndOnce` |
| `src/FeastEmissions.sol::tokenCap` | Linear, week 1 largest, week 52 smallest, summing to the budget less rounding. | `test_theTokenCapFallsLinearlyAndSumsToTheBudget` |
| `src/FeastEmissions.sol::settle` (first-week rule) | Before launch only (the platform coin's pool not yet open), while it has no price the oracle will vouch for, the token cap alone — never a guessed price; pots are liabilities against the budget before any token exists. | `test_aPreLaunchWeekSettlesUnderTheTokenCapAlone` |
| `src/FeastEmissions.sol::settle` (after launch) | Round 4 (H1): once the pool has opened, a moved or unpriceable platform price refuses settlement, with no timeout, until the pricer lever fixes it; never the token cap alone. | `test_afterLaunchAMovedPlatformPriceRefusesSettlementPastTheGrace`, `test_afterLaunchAnUnpriceablePlatformPriceWaitsForTheLever` |
| `src/FeastEmissions.sol::settle` (value cap) | Once priced, never more than the value ratio of the week's fees in platform coin at its price. | `test_theValueCapBindsOnceThePlatformCoinHasAPrice` |
| `src/FeastEmissions.sol::settle` (value cap, size) | v1.6.5 (F1, `CA-5203dcf236`): the minimum is established BEFORE the value cap is multiplied out, so no fee, quote price or platform price can make a week revert on the size of a cap it was going to discard. Exactly at the word boundary the token cap is taken. | `test_aWeekWhoseCapIsTheTokenCapCanSettle`, `test_atTheExactWordBoundaryTheTokenCapIsTaken`, `test_oneUnitBelowTheWordBoundaryTheValueCapIsComputed`, `testFuzz_settleNeverRevertsOnTheSizeOfItsCap` |
| `src/FeastEmissions.sol::settle` (value cap, rounding) | Every division on the value-cap path floors: the inner quotient, the outer quotient and the track share. Measured where each has a remainder, because the binding-cap witness beside it divides exactly and could not have told floor from ceiling. | `test_theValueCapsFloorsAreVisibleWhereTheyRound` |
| `src/FeastEmissions.sol::weights` | 40/45/15 through week 8, 20/65/15 from week 9. | `test_fromWeekNineTheWeightsChange`, `test_aPreLaunchWeekSettlesUnderTheTokenCapAlone` |
| `src/FeastEmissions.sol::settle` (empty) | A week with no fees emits nothing; a track with no fees emits nothing that week. | `test_aWeekWithNoFeesEmitsNothing`, `test_anEmptyTrackEmitsNothingThatWeek` |
| `src/FeastEmissions.sol::settle` (pricing grace) | An UNPRICEABLE listed quote — a route price no word can hold included — blocks its week for three days of OPEN time after the close, then counts as zero, because that status need never resolve. Since v1.6.22 the grace's end moves only by frozen seconds counted from the previous settlement's stamp, never more than `FREEZE_BUDGET` late, and once over it is over: a freeze of any length, none included, reopens nothing (`pricing-grace-restart`). | `test_anUnpriceableQuoteBlocksItsWeekThenCountsAsZero`, `test_aRoutePriceTooLargeToHoldBlocksItsWeekOnlyForTheGrace`, `test_aZeroDurationFreezeDoesNotRestartAnExpiredPricingGrace`, `testFuzz_theGraceNeverEndsEarlyNorReopens_weekOne`, `testFuzz_theGraceNeverEndsEarlyNorReopens_afterASettledWeek`, `test_theWholeFreezeBudgetIsTheMostTheGraceCanBeHeld` |
| `src/FeastEmissions.sol::settle` (moved quote) | v1.6.5 (F2, `CA-81659c1034`): a listed quote whose spot has MOVED from its own average refuses settlement and waits — inside the grace and past it — as the platform coin's identical status does, because that status CAN resolve where `Unpriceable` need not. Zero is a guess. The wait is not guaranteed to end, and the escape is the platform branch's escape. | `test_aMovedQuoteIsRefusedPastTheGraceAsTheMovedPlatformPriceIs`, `test_aMovedQuoteIsRefusedInsideTheGraceAndPastIt`, `test_aMovedQuoteSettlesOnceItsSpotIsBackInsideTheBound` |
| `src/FeastEmissions.sol::settle` (moved quote, reach) | v1.6.5 round 1: the refusal reaches only as far as the platform coin's — a listed quote with no fees in the week cannot move any number that week settles at, and is passed over rather than held for. | `test_aMovedQuoteWithNoFeesThatWeekDoesNotHoldTheWeekUp` |
| `src/FeastEmissions.sol::settle` (redirect) | Round 4 (M1): the redirect is its share of what the week actually emits, track by track; empty tracks cannot inflate it. | `test_aRedirectIsAShareOfWhatTheWeekActuallyEmits`, `test_aRedirectTakesAShareOfNewWeeksAndNeverASettledOne` |

### mechanism: emission-claims

*Claims open only when the platform coin's pool opens, never exceed a week's pots, and expire and burn only after their grace.*

| Site | Predicate | Test |
|---|---|---|
| `src/FeastEmissions.sol::claim` | Only once claims are open; once per week per account; paid to the account. | `test_claimsWaitUntilThePlatformCoinsPoolOpens` |
| `src/FeastEmissions.sol` (books) | Round 6 (L1): once funded, the balance, counted independently, equals `remaining + liabilities` after every claim, released redirect and expired burn. | `test_everyExitRetiresExactlyWhatItPaysOrBurns` |
| `src/FeastEmissions.sol::_priced` | Each account's share of each pot by its priced fees, at the prices the week settled at; floors per quote, so the sum over accounts never exceeds the track — at a fractional price too (round 6). | `test_owedIsTheShareOfEachPotByPricedFees`, `testFuzz_theClaimsOfAWeekNeverExceedItsPots`, `test_atAFractionalPriceTheClaimsStillFitThePot` |
| `src/FeastEmissions.sol::_priced` (the settled list) | v1.6.3 (`CA-7e9b1e15be`): nothing on the owed/claim path asks the pricer anything after settlement. Settlement snapshots the quote list it priced, each distinct quote once, and every claim and every genesis grant reads only that list and the prices stored beside it; the ledger and the hook it still calls are immutable and replaceable by no lever. | `test_aPricerThatRevertsAfterSettlementChangesNoEntitlement`, `test_aDuplicateQuoteAtSettlementIsCountedOnce`, `test_aSettledEntitlementDoesNotChangeAfterItsWeekIsSettled` |
| `src/FeastEmissions.sol::expiryOf` | Twelve weeks from the later of settlement and claims opening; no expiry while claims are closed. | `test_aPreLaunchWeekExpiresTwelveWeeksAfterClaimsOpen` |
| `src/FeastEmissions.sol::burnExpired` | Only after the grace, exactly what was unclaimed, once. | `test_anUnclaimedWeekBurnsAfterItsGrace` |
| `src/FeastEmissions.sol::burnRemainder` | After week 52, only what nobody is owed. | `test_afterWeekFiftyTwoWhatNobodyIsOwedBurns` |
| `src/FeastEmissions.sol::releaseRedirect` | A redirected share is paid once, to the escrow it was redirected to. | `test_aRedirectTakesAShareOfNewWeeksAndNeverASettledOne` |

### mechanism: governed-levers

*Only the timelock pulls a lever; each is bounded at the callee and applies from the next ledger week (the pricer from the next settlement); a settled week never changes.*

| Site | Predicate | Test |
|---|---|---|
| `src/FeastEmissions.sol::setValueRatioBps` | Timelock only; 5%–20% at the callee; from the next ledger week. | `test_onlyTheTimelockPullsALever`, `test_theBandsHoldAtTheCallee`, `test_aLeverTakesEffectFromTheNextLedgerWeek` |
| `src/FeastEmissions.sol::setRedirect` | Timelock only; at most 50%, with an escrow exactly when non-zero; new weeks only. | `test_theBandsHoldAtTheCallee`, `test_aRedirectTakesAShareOfNewWeeksAndNeverASettledOne` |
| `src/FeastEmissions.sol::setPricer` | Timelock only; a contract; applies to the next settlement, never a settled week. | `test_theBandsHoldAtTheCallee`, `test_aNewPricerPricesTheNextSettlement` |
| `script/DeployPackage2.s.sol::deployPackage2` (timelock) | Three days; the multisig its only proposer; anyone executes; its only admin is itself. | `test_theTimelockIsWiredAsRuled` |

### mechanism: genesis-grants

*A partner's grant unlocks by referred fees from the emissions ledger, capped, counted once per week; the unearned part burns after week 26.*

| Site | Predicate | Test |
|---|---|---|
| `src/FeastGenesisGrants.sol::constructor` | Eight distinct non-zero partners and a non-zero target. | `test_eightDistinctPartnersAndATargetAreRequired` |
| `src/FeastGenesisGrants.sol::checkpoint` | Only settled weeks 1–26, each once, from `FeastEmissions.referredValue`. | `test_aGrantUnlocksByTheFeesItsPartnersLinksBring` |
| `src/FeastGenesisGrants.sol::unlocked` | Pro rata to the target, capped at the grant. | `test_aGrantUnlocksByTheFeesItsPartnersLinksBring`, `test_aGrantNeverUnlocksMoreThanItself` |
| `src/FeastGenesisGrants.sol::claim` | Only once claims are open; pays the partner each unlocked unit once — a repeated claim pays nothing, a later unlock only its increment (round 6). | `test_nothingIsPaidOrBurnedBeforeClaimsOpen`, `test_aRepeatedGrantClaimPaysOnlyWhatIsNew` |
| `src/FeastGenesisGrants.sol::burnUnearned` | Only after week 26, once, exactly the unearned part; the earned part stays claimable. | `test_theUnearnedPartBurnsOnlyAfterTheHorizon` |
| `src/FeastGenesisGrants.sol::assignPartner` | v1.6.12: an EMPTY slot, once, by the team multisig (the guardian's own key), inside the guardian's own 90-day window. A filled slot — at genesis or since — is immutable, and nothing moves. | `test_theTeamMultisigMayFillAnEmptySlotOnce`, `test_aStrangerCannotFillASlot`, `test_aFilledSlotIsImmutable`, `test_afterDayNinetyNoSlotCanBeFilled` |
| `src/FeastGenesisGrants.sol::checkpoint` (assigned) | A week that had already closed when a slot was filled counts zero for it, and stays counted so it cannot be picked up later. | `test_anAssignedPartnerEarnsFromReferralsMadeAfterAssignment` |
| `src/FeastGenesisGrants.sol::burnUnfilledSlot` | A slot nobody filled burns once the window to fill it has closed; once, and never for a slot somebody holds. | `test_anUnfilledSlotBurnsAtTheDeadline` |

### mechanism: launch-window

*The window clears a uniform-price auction exactly once, in its exclusive hour, and the pool is CREATED by that settlement at the price it cleared; every committer pays the same price and every unit is paid; a window that cannot settle refunds in full and leaves no half-built pool behind it.*

| Site | Predicate | Test |
|---|---|---|
| `src/FeastLaunchWindow.sol::commit` | Only during the 24 hours. | `test_commitsOpenAtTheStartAndCloseAtTheEnd` |
| `src/FeastLaunchWindow.sol::withdraw` | Until the last hour, never in it (ruling 3). | `test_aCommitCanBeTakenBackUntilTheLastHour` |
| `src/FeastLaunchWindow.sol::settle` | Once, as the opener, in `[endsAt, openAt)`; with no commits it opens the pool single-sided at the price the genesis key named and buys nothing. | `test_theWholePotBuysOnceAndEveryoneGetsTheSamePrice`, `test_noCommitsOpensTheWholeSixtyPercentByTime` |
| `src/FeastLaunchWindow.sol::settle` (the price) | `p* = (total - total/100) / tranche`, and the pool opens AT it — aligned to the usable tick that is cheaper in coin, never dearer. | `test_theClearingPriceIsThePotOverTheTranche`, `test_theOpeningSpotEqualsTheClearingPrice`, `test_theClearingPriceRoundsAgainstTheCommitter` |
| `src/FeastLaunchWindow.sol::settle` (the seed) | Both sides placed around the clearing tick: the unsold supply above, the whole net pot below; correct in either currency slot. | `test_theWholePotIsInThePoolAsBidLiquidity`, `test_theRemainingSupplyIsTheAskSide`, `FeastWindowAuctionInvertedTest.test_theFixtureReallyIsInverted` |
| `src/FeastLaunchWindow.sol::settle` (the fee) | The 1% goes to the platform sink as wrapped native, by transfer, on no ledger track. | `test_thePotPaysTheOnePercentToThePlatformPath`, `test_thePotPaysTheFeeAndIsRecordedNowhere` |
| `src/FeastLaunchWindow.sol::settle` (failure) | `settled` written only after both positions are placed; a pot too small to price is refused by name, not by panic. | `test_aFailedSeedLeavesTheWindowUnsettledAndRefundable`, `test_aPotTooSmallToPriceIsRefusedByName` |
| `src/FeastLaunchWindow.sol::clearingPrice` | Zero until settled and on the no-commit path; quote per coin in either currency slot. | `test_theClearingPriceIsThePotOverTheTranche`, `test_noCommitsOpensTheWholeSixtyPercentByTime` |
| `src/FeastLaunchWindow.sol::claim` | Pro rata of the tranche; the last claimant takes the exact remainder, so nothing strands. | `test_everyUnitOfTheTrancheIsClaimed`, `test_theWholePotBuysOnceAndEveryoneGetsTheSamePrice` |
| `src/FeastLaunchWindow.sol::claim` (once) | Round 5 (L1): each committer claims once; a second claim cannot take another's share. | `test_eachCommitterClaimsOnce` |
| `src/FeastLaunchWindow.sol::refund` | Only when the window can no longer settle; in full. | `test_anUnsettledWindowRefundsEveryCommitInFull`, `test_settleNotCalledInTheGraceOpensRefunds` |
| `src/FeastFactory.sol::seedWindowPool` | Only the window genesis named; whatever the positions did not take is burned, not left in the hook (I14). | `test_noCommitsOpensTheWholeSixtyPercentByTime` |
| `src/FeastHook.sol::_mayInitialize` | The factory, or a gated pool's registered opener — and nobody else, on either kind of pool. | `test_nobodyButTheWindowCanInitialiseTheGatedPool`, `test_nobodyTradesThePlatformPoolBeforeTheWindowOpensIt` |

### mechanism: team-vesting

*The team's 25% vests linearly for 36 months from the window's close, cannot be renounced into the void, and never votes.*

| Site | Predicate | Test |
|---|---|---|
| `src/FeastTeamVesting.sol::constructor` | Start = the window's close, duration = 36 × 30.4375 days, no cliff. | `test_itVestsLinearlyForThirtySixMonthsFromTheWindowsClose` |
| `src/FeastTeamVesting.sol::renounceOwnership` | Disabled; and there is no function that delegates votes. | `test_itCannotBeRenouncedAndNeverVotes` |

### mechanism: platform-sink

*The sink sells any asset but the platform coin at a descending price, never zero, and burns everything it is paid. A descent prices the lot it was opened over.*

| Site | Predicate | Test |
|---|---|---|
| `src/FeastPlatformSink.sol::open` | Over a lot that holds something, never the platform coin, at the fixed high start; once per descent. | `test_aLotStartsHighAndHalvesEveryHour`, `test_theSinkRefusesToSellThePlatformCoinOrMoreThanItHolds` |
| `src/FeastPlatformSink.sol::schedule` | v1.6.2 rounds 5 and 6: the genesis key names the launch window once; the sink checks its role and its coin and reads its close as the opening. A time the key could choose would be a promise - there is no time to name. | `test_theSinkIsScheduledOnceByNamingTheWindow`, `test_theSinksOpeningIsTheGenesisKeysAndIsSpentByUsingIt` |
| `src/FeastPlatformSink.sol::schedule` (fails closed) | v1.6.2 round 6: a window that will not say when it closes schedules nothing, and an unscheduled sink opens nothing. | `test_aWindowThatWillNotSayWhenItClosesSchedulesNothing` |
| `script/Genesis.s.sol::launch` (the sink's opening) | v1.6.2 rounds 6 and 7: the documented deployment schedules the sink and refuses to call the launch finished until that has landed - its own transaction, since a script broadcasts each call separately, and shut rather than early if it does not. | `test_theGenesisScriptLeavesTheSinkOpeningAtTheWindowsClose` |
| `script/Genesis.s.sol::launch` (the post-condition) | v1.6.2 round 7: the launch is not finished while the sink reports no opening, whatever the cause - a wrong address, a transaction that never landed. | `test_theScriptRefusesALaunchThatLeavesTheSinkUnscheduled` |
| `src/FeastPlatformSink.sol::open` (the opening) | v1.6.2 round 5: no descent starts before that moment, because until the window closes the coin exists but its whole supply is out of everyone's reach. | `test_theSinkOpensWhenTheWindowCloses` |
| `src/FeastPlatformSink.sol::open` (the floor) | v1.6.2 round 5: a new descent starts with no floor - a floor is what a sale said about the lot its own descent priced. | `test_aNewDescentCarriesNoFloorFromTheLotBeforeIt` |
| `src/FeastPlatformSink.sol::open` (before genesis) | v1.6.2 round 4: no descent starts while the platform coin has no code — the sink ships before the coin does, and a descent whose takes nobody can pay is a timer, not a market. | `test_noDescentStartsBeforeThePlatformCoinExists` |
| `src/FeastPlatformSink.sol::take` (the floor's level) | v1.6.2 round 4: the floor is seeded by the sale's price weighted by the share of the lot it took, the way the anchor already moves, so a dust purchase seeds a floor of dust. | `test_aDustTakeSeedsAFloorOfDustAndLeavesTheColdStartAlone`, `testFuzz_theFloorsBaseNeverExceedsThePriceTheSalePaid` |
| `src/FeastPlatformSink.sol::open` (inventory) | v1.6.2 (`CA-fb2e051555`): a lot with nothing in it cannot be opened, so the clock never runs on an empty lot. | `test_aLotCannotBeOpenedBeforeItHoldsAnything` |
| `src/FeastPlatformSink.sol::open` (re-open) | v1.6.2: re-opened only over a lot holding at least `SINK_REOPEN_MULTIPLE` times what it held when its descent began, so a dust donation cannot reset a live descent and a reset costs a doubling every time. | `test_aDustDonationCannotRestartALiveDescent`, `test_aLotThatHasDoubledIsPricedFromTheTopUntilItIsOpenedAgain` |
| `src/FeastPlatformSink.sol::_price` (a different lot) | v1.6.2: a lot that has at least doubled since its descent began — every refill into an emptied lot included — is priced from the start price, by the view and by a take alike, until someone opens a descent over it. | `test_aRefillIntoAnEmptyLotIsPricedFromTheTop`, `test_aDrainedLotRefilledWithDustIsANewLotNotALiveDescent`, `test_aRefillOfADecayedLotIsNotGivenAway` |
| `src/FeastPlatformSink.sol::_price` (B9) | Declared: a refill smaller than the lot it lands in does not restart the descent and is sold at the price that descent has reached. | `test_aRefillSmallerThanTheLotDoesNotRestartTheDescent` |
| `src/FeastPlatformSink.sol::priceQ128` | Halves every hour, linearly within the hour. | `test_aLotStartsHighAndHalvesEveryHour` |
| `src/FeastPlatformSink.sol::priceQ128` (floors) | Round 5 (L1): never zero, so a take always burns something; after a sale, not below that sale's price halved six times - exactly in real numbers, and in integers to within the truncation the row below states (v1.6.3). | `test_anUnsoldLotNeverBecomesFree`, `test_afterASaleThePriceStopsAtItsFloor` |
| `src/FeastPlatformSink.sol::_floorNow` / `_atLeastTheFloor` | v1.6.2 (H2): the floor has a clock of its own — it halves every `SINK_FLOOR_HALF_LIFE` since the sale that set it, linearly within each half-life, so one sale cannot pin a lot above the market for ever. | `test_aLotPinnedAtItsFloorUnsticksAsTheFloorDecays`, `test_afterASaleThePriceStopsAtItsFloor` |
| `src/FeastPlatformSink.sol::take` (the floor's clock) | v1.6.2 (H2), as v1.6.3 (`CA-b229a31396`) enforces it: a sale that RAISES the floor resets both its level and its clock; a sale that does not raise it touches neither, so a one-wei purchase cannot buy away what a real sale established. | `test_aRaisingTakeResetsTheFloorsLevelAndItsClock`, `test_aTakeThatDoesNotRaiseTheFloorLeavesItAndItsClockExactlyWhereTheyWere`, `test_aDustTakeDoesNotEraseTheFloorARealSaleSet` |
| `src/FeastPlatformSink.sol::take` (the floor, never downward) | v1.6.3: what the maximum rule costs, and its bound. A floor is cleared by `open` and by nothing else; a later, LOWER sale's own-clock floor is held to within the decay curve's chord gap, never worse than 8/9 of it less an absolute slack of four raw price units - the 8/9 is about real numbers and the floor is read by truncating arithmetic twice over (round 1, r1v). | `test_aCarriedFloorIsClearedByOpeningAndNotByASale`, `testFuzz_theChordGapIsNeverWorseThanEightNinthsLessItsSlack`, `test_theChordGapNeedsItsAbsoluteSlackAtEveryMagnitude`, `test_theLensSequenceHoldsUnderTheRestatedClauseAndNotTheOldOne` |
| `src/FeastPlatformSink.sol::take` (a raising take) | v1.6.3 round 2 (r2h): "never lower" is exact at the sale and within one raw price unit afterwards - a raising write starts a fresh curve from a higher base and the decay truncates. | `test_aRaisingTakeIsExactAtTheSaleAndWithinOneUnitAfterIt`, `testFuzz_aRaisingTakeNeverCostsMoreThanOneUnitLaterOn` |
| `src/FeastPlatformSink.sol::take` (the re-anchor) | v1.6.3 (`CA-fad351f89b`): the re-anchor is written in a form whose intermediate cannot overflow, so a lot holding an asset's entire supply can still be bought from; the anchor's own growth is bounded by what a ratchet costs. | `testFuzz_theReanchorIsTheSameNumberWrittenSafely`, `test_theReanchorAtTheEdgeTheOldFormCouldNotReach`, `test_aLotHoldingAnEntireSupplyCanStillBeBoughtFrom`, `testFuzz_aChainOfHalfLotTakesCostsAtMostFourTimesItsFirstTake` |
| `src/FeastPlatformSink.sol::take` | Pays at least the price (rounded up), burns the payment, delivers the asset, re-anchors by the share taken; never more than held. | `test_aTakeBurnsItsPaymentAndReanchorsByTheShareTaken`, `test_theSinkRefusesToSellThePlatformCoinOrMoreThanItHolds` |
| `src/FeastPlatformSink.sol::take` (the lot it leaves) | v1.6.2: a take records what the lot still holds as the descent's reference size, so emptying it ends the descent. | `test_aRefillIntoAnEmptyLotIsPricedFromTheTop`, `test_aDrainedLotRefilledWithDustIsANewLotNotALiveDescent` |
| `src/FeastPlatformSink.sol::take` (never upward) | v1.6.2 round 1 (H1, both lenses): only `open` sets the size a descent prices; a take may lower it and never raise it, so no sequence of donations and dust takes can manufacture a reference size no descent stood over. | `test_aTakeNeverRaisesTheSizeADescentPrices` |
| `src/FeastPlatformSink.sol::open` (re-entry) | v1.6.2 round 2: `open` is guarded, so an asset that calls back while the sink is sending it cannot start a descent over a balance a take is in the middle of moving. | `test_anAssetThatCallsBackCannotOpenADescentMidTake` |
| `src/FeastPlatformSink.sol::_pricesThisLot` | v1.6.2 round 3: one predicate answers for both readers — a descent prices its lot on `offered <= held < 2 x offered`, and `open` is permitted on exactly the complement, so no lot can be left neither priceable nor openable. | `testFuzz_aDescentPricesALotExactlyWhenOpeningItIsRefused`, `test_anEmptyLotIsNeitherPricedNorOpenable` |
| `src/FeastPlatformSink.sol::_price` (a lot that shrank) | v1.6.2 round 2: a lot holding less than its descent priced is not priced by that descent, and anyone may open a new one over what is actually there; the declared limit is pinned beside it. | `test_aLotThatShrankIsNotTheLotItsDescentPriced`, `test_theDeclaredLimitOfWhatAShrunkenLotCanBeToldFrom` |
| `src/FeastPlatformSink.sol::_price` (floored both ways) | v1.6.2 round 1 (H2, both lenses): the refilled-lot branch is floored like the descent, so a lot whose last sale was above the start price is never sold under its own floor and `open` cannot raise a quote. | `test_aRefillIsPricedFromTheTopButNeverUnderTheFloor` |
| `src/FeastPlatformSink.sol::burnStray` | Round 6 (L1): platform coin that reaches the sink directly burns, every unit. | `test_platformCoinSentToTheSinkBurns` |
| `src/FeastHook.sol::releasePlatformFees` (to the sink) | The platform share reaches the sink as the asset itself. | `test_theExitDeliversThePlatformShareHere`, `test_fork_theWholeRecipeRunsEndToEnd` |
| `src/FeastPlatformSink.sol::take` (cost) | v1.6.6 (Q3): a cost no word can hold is refused by name with `CostAboveLimit`, saturated — guarded on the ROUNDING the cost uses and not only on its floor, since `take` rounds up. Below the threshold nothing moves; the money is the real ceiling, at 54 210 108 raw units for the whole supply. | `test_atTheLargestWritableCostTheTakeIsPricedAndThenUnaffordable`, `test_oneSecondEarlierTheCostCannotBeWrittenDownAndIsRefusedByName`, `test_inTheBandWhereOnlyTheRoundingLeavesTheWordTheRefusalIsStillNamed`, `test_theLargestTakeAnybodyCanPayForGoesThrough` |

### mechanism: route-authority

*Whoever bears the loss from a route chooses it, or the outcome is bounded so nobody can lose.*

| Site | Predicate | Test |
|---|---|---|
| `src/FeastHook.sol::claimAsBnb` | `msg.sender == account`. | `test_onlyTheClaimantMayChooseTheirOwnConversionRoute` |
| `src/FeastConverter.sol::convert` | Hook-only; bounded hops; no token repeats. | `test_onlyTheHookMaySpendThroughIt`, `test_aRouteThatRevisitsAnIntermediateTokenIsRefused` |
| `src/FeastHook.sol::claimAsBnb` | The one converter path in v1. The claimant picks the route and the claimant bears the loss, so nobody may route another's claim — which is precisely why this survives the cut while the platform buttons do not (their route spent the PROTOCOL's money). | `test_onlyTheClaimantMayChooseTheirOwnConversionRoute`, `test_aClaimantMayTakeTheirOwnClaimInTheChainsAsset` |
| `src/FeastConverter.sol::_expectedAfterHop` | v1.6.6 (Q8): each step of a hop's expectation is refused by name with `RouteExpectationTooLarge` when its result needs more than a word. `convert` feeds each hop's expectation into the next, so only the FIRST is bounded by the venue's settlement ceiling. | `test_aCompoundedExpectationTooLargeToHoldIsRefusedByName`, `test_theSameTwoHopRouteAtASanePriceConverts` |

### mechanism: reentrancy

*State is settled before any external call; no entry point is re-entrant into another's bookkeeping.*

Round 3's fresh HIGH, found by both lenses. The answer is structural: the
monolithic button is split so each half settles its own state first, and both
carry a guard.

| Site | Predicate | Test |
|---|---|---|
| `src/FeastHook.sol::_lockAcquired` | Deliberately *not* guarded: it is the vault re-entering during this contract's own lock, which is the normal path, and it is `onlyVault`. | `test_lockCallbackRefusesAnyCallerButTheVault` |
| `src/FeastConverter.sol::pancakeV3SwapCallback` | Only the pool currently being swapped may call it. | `test_theSwapCallbackRefusesEveryoneButTheActivePool` |
| `src/FeastHook.sol::_claimTo` | Burn the claim, then move the token, both inside one lock: a token that refuses reverts the pair and leaves the ledger untouched. | `test_freezingTheQuoteTokenDelaysAClaimButNeverChangesIt` |
| `src/FeastHook.sol::claimAsBnb` | The route belongs to whoever bears the loss, so no caller can route another's claim through pools of their own choosing. | `test_onlyTheClaimantMayChooseTheirOwnConversionRoute` |
| `src/FeastConverter.sol::convert` | Only the hook may spend through it, so the converter has no public surface to re-enter. | `test_onlyTheHookMaySpendThroughIt` |
| `src/FeastConverter.sol::pancakeV3SwapCallback` | Only the pool currently being swapped may call back, so nobody else can make the converter pay out. | `test_theSwapCallbackRefusesEveryoneButTheActivePool` |
| `src/FeastHook.sol::claimAsBnb` | Entitlement is retired before the conversion is attempted, and the payout goes to the claimant rather than the caller. | `test_aClaimantMayTakeTheirOwnClaimInTheChainsAsset` |
| `src/FeastHook.sol::releasePlatformFees` | v1.6: `platformUsed` is debited before the payout lock, so a quote that calls back during its own transfer reads the bucket already spent. Since v1.6.28 a call back into the exit itself is refused by the hook's re-entrancy guard, by name. | `test_aQuoteThatReentersTheExitCannotDoubleThePayout`, `test_releasePlatformFeesCannotBeEnteredFromInsideItsOwnPayout` |
| `src/FeastHook.sol::claimCreator` | v1.6.28: holds the re-entrancy guard while it pays and clears it on the way out, so nothing guarded can be entered from inside its payout; `claim`, which is not guarded, calls it and then `claimReferrer`. | `test_claimCreatorCannotBeEnteredFromInsideItsOwnPayout`, `test_claimPaysBothSharesThroughTheTwoGuardedFunctionsInTurn`, `test_eachPayingFunctionClearsTheFlagOnTheWayOut` |
| `src/FeastHook.sol::claimReferrer` | v1.6.28: the same guard, held while it pays and cleared on the way out. | `test_claimReferrerCannotBeEnteredFromInsideItsOwnPayout`, `test_claimPaysBothSharesThroughTheTwoGuardedFunctionsInTurn`, `test_eachPayingFunctionClearsTheFlagOnTheWayOut` |

### mechanism: execution-value

*An execution is bounded against the prices its own pools report, not against the path chosen.*

| Site | Predicate | Test |
|---|---|---|
| `src/FeastConverter.sol::convert` | Output must reach the product of per-hop prices, each net of that pool's fee, less the deviation band. | `test_aRouteThatReturnsLessThanItsPricesImplyIsRefused`, `test_aRouteWithinTheDeviationBandIsAccepted` |
| `src/FeastConverter.sol::_expectedAfterHop` | The price comes from `sqrtPriceX96`, and the pool's own fee is deducted rather than counted as slippage. | `test_thePoolsOwnFeeIsNotCountedAsSlippage` |
| `src/FeastConverter.sol::convert` (the inbound leg) | v1.6.3 (`CA-58354019a2`): what the route spends is what ARRIVED — measured, balance before against balance after — so a taxed input is converted for what arrived rather than refused, and a stray balance is neither spent nor needed (B2, held by construction). | `test_aTaxedInputWithNoDonationConvertsWhatArrived`, `test_aDonationIsNeitherSpentNorNeededByATaxedConversion`, `test_admissionDoesNotDependOnWhatSomebodyDonated` |
| `src/FeastConverter.sol::_hop` (the intermediate leg) | v1.6.3 round 1 (r1h): a hop hands the NEXT hop what ARRIVED here, measured across the swap, not what the pool reported sending - so an intermediate token that takes a cut of its pool's outbound transfer cannot leave the next hop spending a stray balance. | `test_aTaxedIntermediateNeitherSpendsADonationNorNeedsOne` |
| `src/FeastConverter.sol::_hop` / `pancakeV3SwapCallback` (the outbound leg) | v1.6.3 round 1 (r1v): a hop pays only out of what it brought - the callback refuses an ask above this hop's measured input, and the debit itself is measured after the swap, so a token that charges its sender on top cannot reach a stray balance from the far side of a swap. | `test_anOutboundSurchargeNeverDipsIntoADonation`, `test_anOutboundFeeOnTransferIsRefusedByThePoolsOwnFillCheckEitherWay` |
| `src/FeastConverter.sol::convert` (a non-positive arrival) | v1.6.3 round 1 (r1v): a token that SHRINKS this contract's balance while transferring in is refused by name, not by a checked-subtraction panic whose reachability depended on the size of a donation. | `test_anInboundThatShrinksTheBalanceIsRefusedByNameNotByPanic` |
| `src/FeastConverter.sol::convert` (B2's declared limit) | v1.6.3 rounds 2 and 3: a measurement of what a transfer MOVES cannot cover what it requires of either party's standing balance - before it (a per-holder cap), during it (a transient requirement on the sender), or as a rewrite of balances it was not given (a rebase). Declared rather than fixed: no measurement here reaches inside another contract's transfer. | `test_theDeclaredLimitOfMeasuringAnArrival`, `test_theDeclaredLimitOfMeasuringATransientRequirement`, `test_theDeclaredLimitOfATransferThatReadsTheRecipientsBalance` |
| `src/FeastConverter.sol::convert` (and never more) | v1.6.3: what arrived, clamped at what the hook sent. A token that credits its recipient above the amount asked for would otherwise have the route spend the surplus - balance this contract held rather than balance the hook sent, which is a stray balance spent. | `test_aTokenThatDeliversMoreThanAskedDoesNotHaveTheSurplusSpent` |
| `src/FeastConverter.sol::convert` (the floor's anchor) | v1.6.3: the route floor is built from `received`, at the price `_validateHop` bounded against the pool's average and carried forward — not re-read after a transfer a hostile input could have moved the pool inside. | `test_aTokenThatMovesItsPoolDuringTransferCannotWidenTheRouteFloor` |
| `src/FeastConverter.sol::_validateHop` | Spot within `MAX_TICK_DEVIATION` of the pool's own average; an unusable oracle refuses the hop. | `test_aSpotPriceFarFromTheAverageIsRefused`, `test_aPoolWithOneObservationIsRefused` |
| `src/FeastHook.sol::_requireSpotNearAverage` | The same check for a feast pool, against feast's own oracle. | `test_aMovedSpotPriceStopsTheButton` |
| `src/FeastHook.sol::_lockAcquired` (both purchase branches) | A price limit derived from spot bounds how far the purchase may move it. | `test_theSwapCarriesAPriceLimit` |
| `src/FeastConverter.sol::_averageTick` | The history the bound is priced against; too little of it is a refusal rather than a fallback to spot. | `test_aPoolWithTooLittleHistoryIsRefused`, `test_aPoolWithOneObservationIsRefused` |
| `src/FeastOracle.sol::consult` | The feast-side average, shortened to the history that exists rather than extrapolated past it. | `test_aLongWindowIsShortenedToTheHistoryItActuallyHas` |
| `src/FeastOracle.sol::_elapsedSince` | v1.6.1 (CA-e2ba62d849): every elapsed time is taken from the full-width clock and truncated after, so writing and answering keep working when the clock passes 2^32 in 2106 — the oracle is on the swap path and must not revert a trade. | `test_itKeepsWritingAndAnsweringAcrossTheTwentyOneOhSixRollover` |

### mechanism: asset-backing

*Every retired entitlement corresponds to delivered value, in the custody form the ledger assumes.*

| Site | Predicate | Test |
|---|---|---|
| `src/FeastHook.sol::_accrue` | A bucket credit is backed by a vault claim minted in the same call. | `test_accrualIsAClaimAndNotATokenTransfer` |
| `src/FeastHook.sol::_lockAcquired` (`Action.Payout`) | The claim is burned and the token taken in one lock: the ledger and the custody move together. | `test_theCreatorCanClaimAndTheClaimAlwaysPaysTheCreator` |
| `src/FeastHook.sol::_pay` | A debt to the vault is settled by transferring the token in. | `test_oneTransactionProducesACoinAPoolAndLockedLiquidity` |
| `src/FeastVesting.sol::claim` | Delivery goes to the recorded recipient and nowhere else. | `test_vestingAccruesLinearlyAndOnlyEverPaysTheFixedRecipient` |
| `src/FeastHook.sol::claimAsBnb` | Entitlement is retired only against value actually delivered to the claimant. | `test_aClaimantMayTakeTheirOwnClaimInTheChainsAsset` |
| `src/FeastHook.sol::_lockAcquired` (taxed quote, B7) | v1.6.1, declared: a quote that takes a cut of the vault's outbound transfer delivers less than the claim and the platform exit retire — 74.25 of 75, 24.75 of 25 at a 1% tax. An ordinary quote delivers every unit. | `test_aTaxedQuoteDeliversLessThanTheClaimRetires`, `test_aTaxedQuoteDeliversLessThanThePlatformExitRetires`, `test_anUntaxedQuoteDeliversEveryUnitItRetires` |
| `src/FeastHook.sol::releasePlatformFees` | v1.6: the platform entitlement is retired only against the asset delivered to the sink, in the pool's own quote. | `test_anyoneMovesExactlyThePlatformShareToTheSink`, `test_aFrozenQuoteDelaysTheExitButNeverChangesIt` |

### mechanism: spending-rate

*A button spends at most a continuously accruing allowance, deducted by realised spend, tipping in proportion to it.*

Round 6 replaced `cooldown-consume` and `button-progress`, which both described
the withdrawn interval-plus-floor shape. Under that shape a press *occupied* the
hour, so it needed a progress predicate to decide who had earned the right to
occupy it — and no such predicate exists that is neither gameable with dust nor
stranding for a thin pool. Nothing is occupied now.

| Site | Predicate | Test |
|---|---|---|
| `src/FeastHook.sol::_fill` (allowance) | v1.6: the fill spends the button's own allowance and debits it the same way, so no more than 20% of the bucket leaves in any hour across fills and presses together. | `test_theFillAndTheButtonShareOneAllowance`, `test_afterAPressTheFillHasOnlyWhatIsLeft`, `test_atMostTwentyPercentLeavesInAnyHourAcrossFillsAndPresses` |
| `src/FeastHook.sol::_spendingAllowance` | Accrues linearly at `ALLOWANCE_BPS_PER_HOUR` of the bucket, capped at `ALLOWANCE_CAP_BPS` of it, so an idle pool cannot bank an arbitrarily large print. | `test_theAllowanceRefillsContinuouslyAndIsCapped`, `test_anIdlePoolDoesNotBankUnlimitedAllowance` |
| `src/FeastHook.sol::_spendingAllowance` (hourly bound) | Cap plus rate sum to `MAX_HOURLY_SPEND_BPS`, which is what actually bounds a sliding hour — round 7 found each being the whole bound permitted nearly twice it. | `test_atMostTwentyPercentLeavesInAnySlidingHour`, `test_theThirtyMinuteConstructionStaysUnderTheBound` |
| `src/FeastHook.sol::_spendingAllowance` (empty start) | A pool begins with no allowance and accrues from its first banked fee, so a new pool cannot burst. | `test_aNewPoolHasNothingToPressUntilItsAllowanceAccrues` |
| `src/FeastHook.sol::_checkpointAllowance` | Accrual is settled at the bucket's current size before the bucket changes, so newly banked fees never receive allowance for time in which they did not exist. | `test_feesBankedLaterDoNotReceiveRetroactiveAllowance` |
| `src/FeastHook.sol::_bank` (complete credit) | The checkpoint decision is made on the WHOLE self-burn credit, including redirected LP income — round 8 M1 found it made on the swap share alone, so a pool with `selfBurnBps = 0` grew its bucket unchecked. | `test_lpIncomeRedirectedIntoTheBucketDoesNotArriveWithAllowance`, `test_redirectedLpIncomeAccruesAllowanceFromWhenItArrives` |
| `src/FeastHook.sol::_accruedScaled` | The allowance is accumulated in fixed point, so a checkpoint never floors the accrual away — round 8 L2 found whole-unit accumulation could hold it at zero under a stream of tiny fee credits. | `test_frequentBankingDoesNotSuppressAccrual`, `test_aSmallBucketStillAccruesWhenBankedEverySecond` |
| `src/FeastConstants.sol` (the bound) | Cap plus rate are asserted against `MAX_HOURLY_SPEND_BPS` rather than only described, so neither knob can be raised without the bound objecting. | `test_theBurstAndTheRateSumToTheHourlyBound` |
| `src/FeastHook.sol::_spendingAllowance` (dust) | A bucket below `MIN_RATIONED_BUCKET` is not rationed at all: its proportional share rounds to something no pool will fill, and a print that size cannot be sandwiched. | `test_aBucketBelowOneUnitOfAllowanceIsNotRationed` |
| `src/FeastHook.sol::buyBackAndBurn` (clamp) | A request above the allowance is clamped, not refused. | `test_anOversizedRequestIsClampedToTheAllowance` |
| `src/FeastHook.sol::buyBackAndBurn` (realised) | The allowance and the bucket are both moved by what the venue actually took, never by what was offered — round 6's H1 in the new shape. Proved against a genuine partial fill. | `test_aPartialFillConsumesOnlyWhatItActuallySpent`, `test_aDustPressConsumesOnlyWhatItSpent` |
| `src/FeastHook.sol::buyBackAndBurn` (no occupancy) | A dust press does not block the productive press behind it, in the same block. | `test_aDustPressDoesNotBlockTheProductivePressBehindIt` |
| `src/FeastHook.sol::buyBackAndBurn` (liveness) | A pool too thin to fill a whole press still drains over time, which a realised-spend floor would have made impossible. | `test_aShallowPoolsBucketStillDrainsOverTime` |
| `src/FeastHook.sol::buyBackAndBurn` (tip) | No flat component per press — the rate is set by the bucket, not the press (v1.6.23): 0.25%, lifted to what the quote's listed floor would be on the largest press the bucket allows, never above 10%. Dust presses earn dust and splitting a press earns nothing (R6). The floors are constructor-only and announced by `TipFloorListed`, which is how the site reads them. | `test_dustPressesEarnDustAndCannotBeFarmed`, `test_theTipIsASliceOfWhatWasBoughtAndNoMore`, `test_splittingAPressEarnsNothing`, `test_aSmallerPressIsTippedAtTheSameRate`, `testFuzz_theTipStaysBetweenTheRuleAndTheCeiling`, `test_theTableIsAnnouncedRowByRowWhenTheHookIsBuilt` |
| `src/FeastHook.sol::buyBackAndBurn` (zero) | A press that buys nothing reverts, consuming no allowance and debiting no bucket. | `test_aPressThatBuysNothingIsRefusedAndCostsTheProtocolNothing` |

### mechanism: bounded-settlement

*No settlement exceeds one signed 128-bit delta, and the ledger it draws on is debited by what was PAID.*

**This enumeration is checked against the source.** `tools/check-census.py`
derives every function that reaches `_release` and fails if one is missing here,
so the class boundary is machine-held rather than remembered. Rounds 10 and 11
were the same mistake twice: the bounded-payout fix reached some of these sites
and not the rest, and at the site it missed it silently destroyed the unpaid
remainder.

| Site | Predicate | Test |
|---|---|---|
| `src/FeastHook.sol::claimCreator` | Pays at most one settlement and debits `creatorPaid` by exactly that, so an oversized entitlement drains in pieces rather than reverting for ever. | `test_anEntitlementLargerThanOneSettlementIsStillClaimable` |
| `src/FeastHook.sol::claimReferrer` | The same bound, and the entry is **debited by what was paid rather than cleared** — round 11 found the cap applied here without the debit, which destroyed the remainder on a permissionless call. | `test_aBoundedReferrerClaimNeverDestroysTheRemainder` |
| `src/FeastHook.sol::_claimTo` | One settlement budget shared between the creator and referral components, each debited by its own share of it and no more — not two budgets, and never cleared. | `test_theTwoClaimComponentsShareOneSettlementBudget`, `test_aPartlyPaidReferralComponentKeepsItsRemainder` |
| `src/FeastHook.sol::_release` | The primitive: the one place a payout is settled, and the only path to the vault's signed delta. | `test_anEntitlementLargerThanOneSettlementIsStillClaimable` |
| `src/FeastHook.sol::releasePlatformFees` | v1.6's new settlement site, bounded from its first line: at most one settlement per call, `platformUsed` debited by exactly that, the remainder left to leave next time. | `test_aBucketLargerThanOneSettlementLeavesInPieces`, `test_anyoneMovesExactlyThePlatformShareToTheSink` |
| `src/FeastHook.sol::_fill` | v1.6: a settlement site that does not reach `_release` (it settles inside the swap), so it is listed by hand: the quote paid is capped at `MAX_SETTLEMENT` and the coin at one unit short of the sale. Both caps are defence in depth — the venue refuses any sale whose deltas exceed a signed 128-bit value before either could bind — so neither has a killing mutation. | `test_anExactInputSaleIsPartlyFilledFromTheBucketAtSpot`, `testFuzz_noSaleSizeIsRefusedByTheFill` |
| `src/FeastHook.sol::burnFilledCoin` | Round 3 (M1): the fill's coin claims are burned here, off the swap path — at most one settlement per call, `filledCoinPending` debited by exactly what is burned. | `test_theFilledCoinBurnsInASeparatePermissionlessCall`, `test_anExactInputSaleIsPartlyFilledFromTheBucketAtSpot` |

**Known boundary (§6c B6):** `collectLpFees` is *not* in this enumeration and
cannot be. It does not reach `_release`; it collects through the venue, which
narrows the total to `int128` before returning it, so no amount ever reaches
feast to be bounded.

### retired for v1: reward-precision

*claims never exceed fundings, and no rounding path strands a whole funding.*

Not in this tree. Pot funding, payout and the vote over the burn/reward split all
belong to the platform buttons, which the v1 cut leaves out (branch
`v1.1/platform-buttons`). An invariant with no reachable code is not an
invariant, so this section carries no sites and `tools/check-census.py` no longer
requires any. Both return with the buttons, and their sites are preserved on that
branch.

### retired for v1: governance-authority

*one function on one target is reachable by vote, inside a band enforced at the callee.*

Not in this tree. Pot funding, payout and the vote over the burn/reward split all
belong to the platform buttons, which the v1 cut leaves out (branch
`v1.1/platform-buttons`). An invariant with no reachable code is not an
invariant, so this section carries no sites and `tools/check-census.py` no longer
requires any. Both return with the buttons, and their sites are preserved on that
branch.

### mechanism: launch-identity

*A pool is initialised only by the factory, with configuration fixed in the same transaction, at an address nobody else can occupy first.*

| Site | Predicate | Test |
|---|---|---|
| `src/FeastCLHookBase.sol::beforeInitialize` | Only the factory may bring a pool into existence on this hook. | `test_localPoolRefusesAnyInitialiserButTheFactory` |
| `src/FeastCLHookBase.sol::beforeInitialize` (bitmap) | A key whose declared callbacks disagree with the hook is refused, so no pool can run with a different callback set than the one audited. | `test_localPoolRefusesAKeyWhoseBitmapDisagreesWithTheHook` |
| `src/FeastHook.sol::registerPool` | Configuration is written once, by the factory, and there is no setter for any of it afterwards. | `test_registrationIsOnlyEverTheFactorysAndOnlyOnce`, `test_noShareSetterExists` |
| `src/FeastHook.sol::seedLiquidity` | The opening position is the factory's alone and happens once. | `test_seedingIsTheFactorysAloneAndHappensOnce` |
| `src/FeastFactory.sol::create` | The coin's address is deterministic and its salt cannot be reused. | `test_theCoinAddressIsDeterministicAndTheSaltCannotBeReused` |
| `src/FeastFactory.sol::create` (metadata) | v1.6 (Q23): the metadata digest is written with the coin's record and announced in `CoinCreated`, in the creating transaction; zero is accepted as an explicit choice; genesis records the platform coin's. | `test_theMetadataHashIsStoredAndAnnounced`, `test_aZeroMetadataHashIsAccepted`, `test_thePlatformCoinsMetadataHashIsRecorded` |

**Declared boundary B8 (v1.6.1; was "known open", r4a M3 / r4b M2).** The
predicted address commits to name, symbol, supply and salt but *not* to creator,
quote, shares, allocation or opening configuration, so another caller can occupy
a pending launch's address with different economics. The launch itself is never
blocked — a taken salt is refused and the creator relaunches at another — so what
is lost is the prediction; `docs/interface.md` now tells an app not to rely on
one before its `create()` is mined. A salt-level hardening is proposed to the
coordinator and not taken here (`docs/plan.md` §6c B8).

| Site | Predicate | Test |
|---|---|---|
| `src/FeastFactory.sol::predictCoin` (B8) | A prediction is not a reservation: the same four fields from another caller take the address, and the creator's own launch still succeeds at another salt with its own economics. | `test_aPredictedAddressIsNotAReservationButTheLaunchStillHappens`, `test_aTakenSaltIsRefusedRatherThanOverwritten` |

### mechanism: fixed-supply

*The supply is minted once, in the constructor, and can only ever go down.*

| Site | Predicate | Test |
|---|---|---|
| `src/FeastToken.sol::constructor` | The whole supply goes to the recipient and nowhere else. | `test_wholeSupplyIsMintedToTheRecipientAndNowhereElse` |
| `src/FeastToken.sol` (no mint entry point) | There is no way to mint after construction, checked against the deployed surface rather than taken on trust. | `test_noMintEntrypointExists`, `test_noAdminSurfaceExists` |
| `src/FeastToken.sol::burn` | Burning reduces total supply, which is the one direction it may move. | `test_burnReducesTotalSupply` |
| `src/FeastToken.sol::burnFrom` | A third party may burn only what it has been allowed. | `test_burnFromRespectsAllowance` |
| `src/FeastToken.sol::transfer` | Ordinary movement conserves supply exactly. | `testFuzz_transfersConserveSupply` |
| `src/FeastPlatformToken.sol::constructor` | v1.6: the platform coin's whole supply is minted once, to the factory, through its deployer. | `test_theCoinIsWhereItWasPredictedFromDayOne` |
| `src/FeastPlatformToken.sol` (no mint entry point) | No path mints after construction. | `test_thePlatformCoinHasNoMintEntrypoint` |
| `src/FeastPlatformToken.sol::burn` | Burning is the only direction its supply moves. | `test_burningThePlatformCoinReducesItsSupply` |

### mechanism: pool-isolation

*One pool's misfortune is its own: a hostile or frozen quote token cannot reach any other pool's accounting or funds.*

| Site | Predicate | Test |
|---|---|---|
| `src/FeastHook.sol::_accrue` | Every ledger is keyed by pool, so accrual in one pool writes nothing another pool reads. | `test_aPermanentlyFrozenPoolKeepsItsOwnAccountingToItself` |
| `src/FeastHook.sol::_claimTo` | A quote token that refuses to move reverts its own claim and no one else's. | `test_aFrozenQuoteTokenDoesNotStopAnyOtherPool` |
| `src/FeastHook.sol::buyBackAndBurn` | Settling in vault claims rather than tokens means a paused quote cannot stop a coin buying itself back. | `test_aFrozenQuoteTokenDoesNotStopACoinBuyingItselfBack` |
| `src/FeastHook.sol::releasePlatformFees` (frozen quote) | A frozen quote reverts its own pool's exit with the entitlement intact, and it leaves once the freeze lifts. | `test_aFrozenQuoteDelaysTheExitButNeverChangesIt` |
| `src/FeastHook.sol::_fill` (custody) | v1.6: the fill pays in vault claims and never calls the quote token, so a quote issuer cannot refuse a fill. | `test_aFillNeverTouchesTheQuoteToken` |
| `src/FeastHook.sol::_accrue` (custody form) | Accrued value is held as a claim, not as a token balance, so no external transfer hook sits between accrual and record. | `test_accruedValueLivesAsAClaimNotAsATokenBalance` |
| `src/FeastConverter.sol::convert` | The converter is shared custody, so its behaviour must not depend on balances anyone can change. Boundary B2. | `test_aDonatedUnitDoesNotBrickConversion`, `test_aDonationLargerThanTheRequestDoesNotBrickConversionEither` |
| `src/FeastReferrals.sol::referrerOf` (not pool-keyed) | The one piece of referral state that is global rather than per pool, and the amendment I7 states out loud; since v1.6.26 it lives in the registry, not the hook. It carries no value, no pool's accounting depends on it, and only the wallet itself can write it — every bucket, claim, cap, oracle reading and epoch ledger stays strictly per pool. | `test_theBindingIsNotPerPoolAndReachesACoinNeverTraded`, `testFuzz_theFourSharesStillSumToWhatWasTakenForABoundWallet` |

### mechanism: referral-binding

*A wallet's referrer is written once, by the wallet itself — its own call or its own signature, never a trade (v1.6.26, AstraSec M-4) — and can never be changed; from then on it decides every trade that wallet originates, on every pool, through every router.*

| Site | Predicate | Test |
|---|---|---|
| `src/FeastReferrals.sol::_bind` (the one write) | The only write to the registry, reached from both entries, and only ever from zero: the first binding wins and there is no re-binding. | `test_theFirstBindingWinsByEitherEntry`, `test_aReplayedSignatureIsRefusedOnceItHasBound`, `test_aBoundWalletCanNeverBeReboundByAnyLaterTrade` |
| `src/FeastReferrals.sol::bind` (by its own call) | The caller binds itself; a contract account binds by its own call, as a user operation would. | `test_aWalletBindsItselfByItsOwnCall`, `test_aContractAccountBindsByItsOwnCallToo` |
| `src/FeastReferrals.sol::bindWithSig` (by its own signature) | The wallet's EIP-712 signature of exactly this wallet, referrer and deadline, on this registry and chain — ECDSA or ERC-1271 — relayed by anyone; nothing else binds it. | `test_anEoaBindsBySignatureAndAnyoneMayRelayIt`, `test_aContractAccountBindsBySignatureThroughErc1271`, `test_aSignatureBindsOnlyWhatItSigned`, `test_aSignatureIsBoundToItsChainAndItsRegistry`, `test_theEip712VectorsTheAppSignsAgainst` |
| `src/FeastReferrals.sol::bindWithSig` (the deadline) | A signature binds until its deadline and not a second after. | `test_aSignatureIsGoodUntilItsDeadlineAndNotASecondLonger` |
| `src/FeastReferrals.sol::_bind` (the refusals) | Zero, the wallet itself and the burn address are never bound, by either entry. | `test_eachRefusalByTheCallersOwnEntry`, `test_eachRefusalBySignatureToo` |
| `src/FeastHook.sol::_referrerFor` (no trade binds) | No trade writes a binding, in any form or shape — the 64-byte form naming its signer, a terminal naming itself, a user operation naming its bundler. | `test_theFirstNamedTradeBindsNothing`, `test_aThirdPartyTerminalCannotBindAnUnboundWallet`, `test_noTradeBindsAWalletWhateverItsShape`, `test_aUserOperationCannotBindTheBundlerThatSubmittedIt` |
| `src/FeastHook.sol::_referrerFor` (the subject) | The binding read is `tx.origin`'s, which no calldata can forge, so no router can strip or redirect one; it is read before `hookData` is parsed. | `test_aBoundWalletIgnoresTheReferrerInHookDataInBothForms`, `test_aBoundWalletIsPaidOnATradeThatNamesNobody`, `test_aWalletBindsByItsOwnCallAndIsPaidForOnEveryPoolAndRouter`, `test_aWalletBoundBySignatureIsPaidForLikeOneBoundByItsCall` |
| `src/FeastHook.sol::_referrerFor` (the read) | The registry read is the call Solidity makes, with its decoder's checks: a codeless, short, dirty or reverting answer refuses the trade rather than paying a garbage word. | `test_aRegistryWithNoCodeRefusesTheTradeRatherThanPayingGarbage`, `test_aRegistryAnsweringShortRefusesTheTrade`, `test_aRegistryAnsweringADirtyWordRefusesTheTrade`, `test_aRegistryThatRevertsRefusesTheTrade`, `test_theHookReadsTheRegistryItWasBuiltWith` |
| `src/FeastHook.sol::_referrerFor` (the 64-byte form) | Per trade only: the wallet word feeds only the refusals — zero, the payer, the burn address and the named wallet are paid nothing — and a bundler-shaped trade pays its named referrer. | `test_aBundlerShapedTradeDoesNotBindButStillPaysPerTrade`, `test_aDirtyWalletWordDoesNotBindAndStillPays`, `test_aZeroReferrerNeitherBindsNorPays`, `test_selfReferralIsRefusedInTheWalletForm`, `test_selfReferralIsRefusedForTheNamedWalletToo`, `test_theBurnAddressIsNeverAReferrerInTheWalletForm` |
| `src/FeastHook.sol::_referrerFor` (the legacy form) | The 32-byte form pays per trade and never binds — including its refusal of the payer and its right to name the burn address, both unchanged from v1.6.7. | `test_theLegacyFormPaysPerTradeAndNeverBinds`, `test_theLegacyFormRefusesSelfReferralAsItAlreadyDid`, `test_theLegacyFormMayStillNameTheBurnAddress` |
| `src/FeastHook.sol::_referrerFor` (the declared boundary) | Only `tx.origin` is looked up — a bytecode decision of v1.6.26 — so a smart account's binding is not read on a trade a bundler submits, and a relayer that binds its own key governs the trades it originates. Stated, not discovered. | `test_aSmartAccountsBindingIsNotReadOnATradeABundlerSubmits`, `test_aRelayerThatBindsItsOwnKeyIsPaidOnTheTradesItOriginates` |
| `src/FeastHook.sol::claimReferrer` (a bound referrer) | What a binding earns is claimed by the ordinary path; the binding does not enter the claim paths at all. | `test_aBoundReferrerCanClaimWhatTheBindingEarnedThem` |
| `src/FeastHook.sol`, `src/FeastReferrals.sol` (no setter) | Nothing in the hook writes a binding, and the registry has no setter, clear or owner — checked against both deployed surfaces rather than taken on trust. | `test_noReferrerSetterExists`, `test_thereIsNoSetterNoClearAndNoOwner` |

### mechanism: swap-admission

*An honest trade is never refused by feast's own fee accounting. A refusal that stops honest use is as much a defect as a missing one.*

| Site | Predicate | Test |
|---|---|---|
| `src/FeastHook.sol::_fill` (admission) | v1.6: every reason not to fill returns zero; no sale size is refused because of the fill. | `testFuzz_noSaleSizeIsRefusedByTheFill`, `test_noFillWhileTheOracleIsYoung` |
| `src/FeastHook.sol::_referrerFrom` | Malformed referral data is ignored rather than reverting the trade behind it. | `test_malformedReferralDataIsIgnoredRatherThanReverting`, `testFuzz_anyHookDataIsSurvivable` |
| `src/FeastHook.sol::_referrerFrom` (short blob) | A blob too short to hold an address is never read as one. | `test_aShortBlobIsNeverReadAsAReferrer` |
| `src/FeastHook.sol::_referrerFrom` (two forms) | Two lengths are recognised and every other length is no referrer rather than an error, so widening the encoding cannot refuse a trade that a narrower one accepted. | `test_noLengthOfHookDataRefusesATrade`, `testFuzz_anyHookDataIsStillSurvivableIncludingTheNewLength` |
| `src/FeastHook.sol::_addressFrom` | Both words go through the masking reader, so a dirty wallet word is no authorisation rather than a reverted swap. | `test_aDirtyWalletWordDoesNotBindAndStillPays`, `test_noLengthOfHookDataRefusesATrade` |
| `src/FeastHook.sol::_beforeSwap` (dust) | A fee that rounds to zero is skipped, not charged as zero and not reverted. | `test_dustSwapsRoundTheFeeToZeroWithoutReverting` |
| `src/FeastHook.sol::_beforeSwap` (any size) | No swap size reverts. | `testFuzz_noSwapSizeReverts` |
| `src/FeastHook.sol::_specifiedLegFee` (four branches) | Exact-in and exact-out price the same trade the same way, on a buy and on a sell, in both token orderings — eight real swaps, one stated tolerance. Round 10 M2: the old witness compared buys only, and its "both orderings" case executed no swap at all. | `test_theFourBranchesAgreeInBothTokenOrderings` |
| `src/FeastHook.sol::_afterSwap` | The one deliberate exception: a specified-quote partial fill is refused rather than mischarged, which is a refusal the documents must state rather than deny. | `testFuzz_aPartialFillIsEitherRefusedOrChargedOnWhatFilled` |

<!-- census-rows: 263 -->
