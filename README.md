# feast-contracts

A creator mints a plain fixed-supply ERC-20, it is paired with a chosen
tokenised-stock quote token in a concentrated-liquidity pool in one transaction,
the liquidity is locked permanently, and a hook takes 1% of every swap on the
quote leg and splits it into buckets fixed at creation.

**There is no owner, no admin and no upgrade path. Nobody can move funds.**
Every economic parameter of a coin is fixed in its creating transaction and can
never change.

*(v1.6.12.)* There is one bounded exception and it is worth stating in the same
breath: a **guardian** — the team multisig — can stop new coin creation
permanently, and can pause outflows for at most **72 hours** at a time and
**168 hours** in total. That power ends **90 days** after genesis, after which
anyone may clear a freeze left standing and the guardian can do exactly one
thing: stop new coin creation. The launch window is never freezable, because its
refunds run on a clock. The guardian cannot move a balance, change a share or a
price, prevent a refund, extend its own life, or outlive day 90 —
`plans/audit/guardian-design.md` is the design and `P27` is the invariant, pinned
by a fuzz over every external function with the guardian as the caller.

**The creator buys their own stake, they are not given one.** *(v1.6.10.)* In
the opening blocks every wallet is capped at 0.5% of supply and nobody is
exempt. Before the pool opens, the creator may have bought a disclosed amount of
their own coin at creation, paid for in quote at the pool's own price, bounded
by a constant — 20% of supply — and shown on the coin page from block one,
together with the schedule it vests on (which may be none, and then it says so).

## v1.6 — the platform coin and its first year

v1.6 (branch `feat/v1.6-tokenomics`; spec `docs/tokenomics-v1.6.md`, plan
`plans/v16/plan.md`) fixes how the platform coin, FEAST, is distributed:
**60%** into its own permanently locked pool, sold through a 24-hour
uniform-price launch window; **25%** to the team, vesting linearly over 36
months from the window's close; **15%** as a one-year bootstrap — 14.2% paid
weekly to traders, creators and referrers by the fees they actually paid,
earned and brought, and 0.8% to eight genesis partners, unlocking by the fees
their links bring. The platform's 20% of every fee is bought back and burned in
full. Three levers on the emissions contract are governed — the value ratio
(5%–20%), a redirect of up to half of new weeks to a bridge escrow, and the
pricer — through a three-day timelock proposed by the team multisig after
Snapshot votes; there are no proxies anywhere. The guardian above sits BESIDE
that timelock, not through it: three days is not a brake, so the two are
different powers on the same key with different physics.

It is built, sealed and audited as **one unit** (owner ruling Q28), and deploys
in three steps, because the hook is immutable and is deployed with the factory:

| Step | Deployed | Contents |
|---|---|---|
| **1** | with the factory | the weekly fee ledger (`FeastFeeLedger`); the hook's `openAt` gate, its one referral rule, its platform-fee exit, the internal fill and one `Trade` event per swap; the factory's one-shot `genesis` and a metadata digest on every coin; the FEAST token and its deployer |
| **opening** | soon after the factory opens | the timelock, the pricer, emissions, the genesis grants, the platform sink |
| **TGE** | when the owner decides | the launch window, the team's vesting wallet, and the one genesis call |

Package 1 carries no package-2 address in its bytecode: the one-shot genesis
call names them. Its only privileged entry point is that call — by one key, once,
and it disables itself before doing anything else.

**What v1.6 retires from v1.1** (branch `v1.1/platform-buttons`, never merged):
the platform conversion and buy-back buttons, the reward pot and its funding,
`burnShareBps` and its vote. The platform share now leaves the hook as the asset
it accrued in, to the package-2 sink, with no route chosen by anybody.

**Status:** package 1 is audited on its own rounds and frozen before the external
audit; package 2 follows. A package is declared when an audit round returns
HIGH 0 / MEDIUM 0 on its tree — not on a date.

### History: the v1 cut

Internal v1 (tag `v1-internal`) was deliberately smaller than the full
mechanism: five audit rounds took the HIGH count from 10/7 to 4/4, three of the
four that remained lived in the platform buttons, and that subsystem was cut
rather than patched a fifth time (`docs/ship-as-converged.md`, `docs/plan.md`
§6c B3). v1.6 does not bring those buttons back; it replaces what they were for.

## The promises, and how each is checked

Prose is cheap, so each of these is a test or a script rather than a paragraph.

| Promise | What holds it |
|---|---|
| No address can change any economic parameter after creation | `tools/check-boundaries.py` (authority scan) + `test_noShareSetterExists`, `test_noRecipientSetterExists` — asserted against deployed bytecode, not against modifiers |
| Seeded liquidity can never be removed | `test_noWithdrawalPathExistsOnTheHook`: eight plausible withdrawal signatures, all required to fail to resolve. The lock is an absence, not a timelock |
| Supply is fixed | `test_noMintEntrypointExists` |
| A hostile quote token cannot brick other pools, or corrupt this one | `FeastIsolationTest`, and `test_aFrozenQuoteTokenDoesNotStopACoinBuyingItselfBack` |
| The four fee branches price identically | `testFuzz_exactInAndExactOutAgreeOnPrice` |
| The four shares always sum to the fee taken | `testFuzz_theFourSharesAlwaysSumToWhatWasTaken` |
| Nothing strands at a dead address | `test_aBurnAddressCreatorSendsItsShareToTheBurnBucketInstead` |
| No trade is refused by fee accounting, with one declared exception: a specified-quote trade the venue stops early is refused rather than mischarged | `testFuzz_noSwapSizeReverts`, `testFuzz_anyHookDataIsSurvivable`, `testFuzz_aPartialFillIsEitherRefusedOrChargedOnWhatFilled` |
| A time-weighted price is never a spot price in disguise | `FeastOracleTest`, the converter's cardinality refusal, and `test_theOracleReportsThePriceThatActuallyPrevailed` for the hook/oracle integration |
| A bucket's entitlement never decreases, and a claim is never lost — though a frozen quote token can make a claim *revert*, leaving the entitlement intact to claim later | `testFuzz_entitlementNeverDecreasesAcrossInterleavedClaims`, `test_theInterleavedSequenceThatBrokeRoundOne`, `test_freezingTheQuoteTokenDelaysAClaimButNeverChangesIt` |
| Nobody is charged a fee on a trade that did not happen | `testFuzz_aPartialFillIsEitherRefusedOrChargedOnWhatFilled` |
| Every fee is attributed to its quote token and its week, and never crosses either | `test_eachQuoteKeepsItsOwnLedger`, `test_aWeekIsClosedWhenTheNextBegins` |
| Pressing the button occupies nothing, so a dust press cannot block a productive one | `test_aDustPressDoesNotBlockTheProductivePressBehindIt`, `test_aPartialFillConsumesOnlyWhatItActuallySpent` |
| No more than 20% of an accrued bucket leaves in any one hour (except a dust bucket, which may be spent in full) | `test_atMostTwentyPercentLeavesInAnySlidingHour` (greedy, pressing every sixty seconds across an hour), `test_theThirtyMinuteConstructionStaysUnderTheBound` |
| Fees banked a moment ago do not receive allowance for time in which they did not exist | `test_feesBankedLaterDoNotReceiveRetroactiveAllowance` |
| *v1.6:* every fee is credited whole to its payer, creator and referrer, in its week and quote, and a week's total is exactly the sum of its accounts | `test_eachBranchCreditsTheWholeFeeToPayerCreatorAndReferrer`, `testFuzz_eachTotalIsExactlyTheSumOfItsAccounts` |
| *v1.6:* a referrer who is the payer is no referral — no commission, no credit | `test_aSelfReferralIsNoReferralOnAnyBranch`, `testFuzz_aReferrerEqualToThePayerNeverCredits` |
| *v1.6.8, authenticated since v1.6.26:* a wallet's referrer is written once, by the wallet itself — its own call or its own signature, never a trade — and can never be changed, by anyone, including us | `test_aWalletBindsItselfByItsOwnCall`, `test_anEoaBindsBySignatureAndAnyoneMayRelayIt`, `test_theFirstBindingWinsByEitherEntry`, `test_noTradeBindsAWalletWhateverItsShape`, `test_aBoundWalletCanNeverBeReboundByAnyLaterTrade`, `test_noReferrerSetterExists`. The other side of the same coin: a wallet's first binding decides it for life, with no remedy — `docs/referrer-binding.md` §5 |
| *v1.6:* before `openAt` only the launch window trades the platform coin's pool, on every branch — and from v1.6.11 there is no pool at all until the window's auction creates it | `test_beforeOpenAtAStrangerCannotTradeOnAnyBranch`, `test_nobodyTradesThePlatformPoolBeforeTheWindowOpensIt`, `test_nobodyElseTradesThePoolBeforeItOpens` |
| *v1.6.11:* every commit clears at one price and the pool opens AT that price, so selling at the open costs the fee and your own impact and nothing else | `test_aCommitterWhoSellsAtTheOpenLosesOnlyTheFee`, `test_theOpeningSpotEqualsTheClearingPrice`, `test_fork_theAuctionSettlesOnTheRealVenue` |
| *v1.6:* the platform share leaves only to the genesis-named sink, bounded per call, debited by what was paid | `test_aBucketLargerThanOneSettlementLeavesInPieces`, `test_anyoneMovesExactlyThePlatformShareToTheSink` |
| *v1.6:* genesis runs once, by one key, and routes 60 / 25 / 14.2 / 0.8 to the unit | `test_itRunsOnceAndThenNothingIsPrivileged`, `test_theSplitIsSixtyTwentyFiveFifteenToTheUnit`, `test_theFourSharesAreThePublishedOnesAndSumToTheWhole` |
| *v1.6:* an exact-input sale is filled from the coin's own buy-and-burn bucket at spot, inside the TWAP bound and the button's allowance, and the coin it buys is burned; no sale is refused by it | `test_anExactInputSaleIsPartlyFilledFromTheBucketAtSpot`, `test_atMostTwentyPercentLeavesInAnyHourAcrossFillsAndPresses`, `testFuzz_noSaleSizeIsRefusedByTheFill` |
| *v1.6:* every open swap emits exactly one `Trade` with the trader's own amounts | `test_eachBranchEmitsOneTradeWithTheTradersOwnAmounts`, `test_aFilledSaleReportsTheSellersOwnAmounts` |
| *v1.6:* a coin's metadata digest is written and announced in its creating transaction | `test_theMetadataHashIsStoredAndAnnounced` |

`python3 tools/mutate.py` breaks 23 of these on purpose and requires the suite to
notice every one. See `docs/mutations.md`.

## What feast does not control

The plan requires this to be said here, not only in the interface document.

- **The venue can be paused by its own operator.** feast has no admin; the
  exchange it builds on does. A pause stops trading in every pool on it,
  feast's included.
- **The venue takes a share of the LP fee, at a rate its operator sets.** That
  rate can change without feast's involvement, and feast's locked position pays
  it like any other.
- **A quote token can pause, blacklist or sanction.** feast holds accrued value
  as a claim rather than a token so that this cannot brick swaps or corrupt
  accounting — but a claim in a frozen quote cannot be *paid out* until the
  freeze lifts. The entitlement survives; the payment waits.

None of these are defects in feast, and none of them are things feast can fix.
They are the terms of building on someone else's exchange against someone else's
token, and a user is entitled to know them.

## Running it

```sh
foundryup                                   # forge 1.6.0-nightly or later
forge build
forge test                                  # fork tests skip themselves without an RPC
BSC_RPC_URL=https://bsc-mainnet.public.blastapi.io forge test    # with the fork
python3 tools/check-boundaries.py           # licence / authority / identity
python3 tools/mutate.py                     # every mutation must be caught
python3 tools/check-census.py                # every call site of a mechanism is in the census
python3 tools/discover_quotes.py            # which quote tokens are usable, and why
```

The fork pins block 120,721,477, because quote tokens are upgradeable proxies and
an unpinned fork silently tracks upgrades. Most public endpoints for this chain
are **not archive nodes** and cannot serve that block — including the one in most
documentation. Two operational notes worth having before they cost an hour:

- The archive endpoint rate-limits hard, so a fork test that crosses many
  initialised ticks is thousands of round trips. Deterministic mocks belong
  there instead; the fork is for the real deployment's configuration and for
  real token behaviour.
- `via_ir` treats `block.timestamp` as constant within a call frame, so
  `vm.warp(block.timestamp + n)` repeated in a loop warps to the same instant.
  Tests keep their clock in a storage variable. This has looked like a contract
  bug twice.

## Quote tokens

The factory accepts any ERC-20 as a quote. Whether a given one is *usable* turns
on two facts that are not guessable, and `tools/discover_quotes.py` reports both:
is there a pool with liquidity, and does that pool's oracle hold more than one
observation. A pool with a cardinality of one reports its spot tick as its
time-weighted tick, so a bound priced against it is not a bound —
`FeastConverter` refuses such a hop by name.

At the pinned block the tool finds every B-suffix stock token with at least one
priceable pool, and two of them (QQQB, SPCXB) with a *direct* pool against
wrapped native, so those convert in a single hop. It also finds impostor tokens
answering to the same symbols; they are distinguishable by having no liquidity
anywhere, which is exactly what the converter refuses on. **Symbol is not
identity** — always confirm an address, and confirm it against this tool's
output rather than against a listing.

## Deployment recipe

Never executed against mainnet from this repository. Two packages and one call.
Every number and placeholder lives in `src/FeastGenesis.sol`; the scripts read
only that file and **refuse to run while any placeholder is unset**.

### Before either package

1. **Confirm the quote tokens.** Run `python3 tools/discover_quotes.py --json quotes.json`
   and have the owner confirm the addresses by symbol *and* address. Do not take
   a symbol as identity.
2. **Grow the observation ring of every pool a conversion or a valuation will
   route through**, for any pool the tool reports as `NOT PRICEABLE (cardinality 1)`.
   Call `increaseObservationCardinalityNext(N)` on the pool — permissionless —
   with `N` large enough to cover the averaging window (a few hundred is ample).
   **The request takes effect on the pool's next write**, so the pool must then
   trade at least once and accumulate `MIN_OBSERVATION_AGE` of history. Re-run
   the tool to confirm it reports `priceable`. Until then, conversions through
   that pool revert with `OracleUnusable` — and quote-denominated `claim` keeps
   working, which is why nobody's money is trapped meanwhile.

### Package 1 — with the factory (`script/DeployPackage1.s.sol`)

3. **Deploy, in this order**, each address an immutable argument of the next;
   the hook and the factory are predicted with `vm.computeCreateAddress` from the
   deployer's nonce and asserted after deployment:

   ```
   FeastOracle(hook*) → FeastConverter(v3Factory, WBNB, hook*) → FeastFeeLedger(hook*)
     → FeastHook(poolManager, vault, factory*, oracle, ledger, converter)
     → FeastVesting(factory*) → FeastPlatformTokenDeployer(factory*)
     → FeastFactory(poolManager, vault, hook, vesting, deployer, WBNB, GENESIS_KEY)
   ```

   Refused while `GENESIS_KEY` is unset. From this moment the factory creates
   ordinary coins, the ledger records every fee, and the platform coin's address
   is already known: `factory.predictPlatformCoin()`. The platform share of every
   pool accrues in the hook; `releasePlatformFees` refuses until genesis names a
   sink with code.

### At the opening (`script/DeployPackage2.s.sol`)

4. **Deploy package 2 against the predicted platform coin and its pool key**
   (FEAST, WBNB, hook, pool manager, fee, parameters — all known from package 1):
   OpenZeppelin's `TimelockController` (three days; the team multisig its only
   proposer, anyone the executor, no admin but itself), the pricer with its
   confirmed list of priced quotes, emissions (week 1 = the factory's opening
   week), the genesis grants and the platform sink. Deployable at the opening,
   independent of the TGE. Refused while any placeholder is unset: the package-1
   factory, the multisig, `TARGET_NATIVE`, the opening time, the eight partners,
   the confirmed routes.

### Genesis — one call (`script/Genesis.s.sol`)

5. **At the TGE the genesis key deploys the launch window and the team's vesting
   wallet (from the window's close) and calls `factory.genesis(...)` once**,
   naming the window as the pool's opener with `openAt` one hour after the window
   closes, the three token recipients, the platform sink and the opening curve.
   Every recipient must report its role and the platform coin it serves. The
   factory mints FEAST, hands the pool's 60% to the WINDOW rather than seeding
   it — from v1.6.11 the pool is neither initialised nor seeded at genesis,
   because the price it must open at is the price the window's auction has not
   cleared yet — sends 25% / 14.2% / 0.8%, and disables `genesis` for ever. Refused by the script unless the window closes
   on a Monday 00:00 UTC boundary and `openAt` lies within the hook's 14-day
   bound.
6. **Verify sources**, and confirm on the explorer that the deployed bytecode
   carries no owner surface. `tools/check-boundaries.py` is the same check
   applied to the source; the package-1 audit brief pins the runtime bytecode
   hashes.

## Layout

| Path | What |
|---|---|
| `src/` | the shipped contracts |
| `src/venue/` | MIT re-declarations of the exchange interfaces feast calls |
| `test/` | the suite; fork tests skip themselves without an RPC |
| `lib/` | vendored dependencies, pinned; `lib/MANIFEST.md` records commits and the licence boundary |
| `reference/` | MIT sources the modules port from, pinned; never compiled |
| `docs/plan.md` | modules, invariants, refusal ledger, boundaries, open questions |
| `docs/ship-as-converged.md` | the v1 cut: what it removes, what it does not, and why |
| `docs/interface.md` | what the app lane needs, plus `docs/abi/*.json` |
| `docs/tokenomics-v1.6.md` | the v1.6 spec, and the measured per-swap gas against `v1-internal` |
| `plans/v16/plan.md` | the v1.6 plan and its ruling |
| `docs/mutations.md` | the mutation ledger |
| `docs/site-census.md` | every call site of every guarded mechanism, checked against the source |

## The three mechanical checks

`tools/check-boundaries.py` is the enforcement arm of three claims that are
otherwise just prose:

- **licence** — walks the import graph from `src/` and fails on any
  non-permissive licence it can reach, printing the provenance chain. Not
  decorative: an MIT-headered interface in the exchange's own repository reaches
  16 GPL-2.0-or-later files through its imports, which is why `src/venue/`
  exists.
- **authority** — fails on `onlyOwner`, `onlyRole`, `Ownable`, `AccessControl`,
  `initializer`, `upgradeTo`, `delegatecall` or `selfdestruct` in a shipped
  file. The product's central claim is that no address can change any economic
  parameter after creation; this is the grep that makes it checkable.
- **identity** — fails on operator identity strings anywhere in the tree.

`bash tools/vendor.sh` re-fetches every dependency at its pinned commit. There
are no git submodules and no remotes: the repository is self-contained, so a
reviewer reads the same bytes the compiler does.

## License

MIT (see `LICENSE`); every Solidity file carries the matching SPDX header.
