// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Checkpoints} from "@openzeppelin/contracts/utils/structs/Checkpoints.sol";

import {FeastConstants} from "./FeastConstants.sol";
import {FeastFeeLedger} from "./FeastFeeLedger.sol";
import {FeastGenesis} from "./FeastGenesis.sol";
import {FeastHook} from "./FeastHook.sol";
import {FeastPricer} from "./FeastPricer.sol";
import {PoolId} from "./venue/PoolId.sol";
import {IFeastGuardian} from "./IFeastGuardian.sol";

interface IFeastBurnableToken {
    function burn(uint256 amount) external;
}

/// @title The first year's emissions
/// @notice 14.2% of the platform coin, paid weekly for 52 weeks to traders,
///         creators and referrers by the fees they actually paid, earned and
///         brought — read from the hook's own ledger, never from a Merkle root.
///
/// @dev **Settling before the tokens exist.** Week 1 is the ledger week the
///      factory opens in (owner ruling Q8), and the platform coin may be minted
///      weeks later (Q25). A settled week's pots are *accounting*: liabilities
///      recorded against a budget that can never be overspent — every pot comes
///      out of `remaining`, which starts at the 14.2% genesis will deliver — so
///      when the tokens arrive every settled pot is fully funded. Until the
///      platform coin's pool opens, nobody can claim, nothing can expire and
///      nothing can be burned; a pre-launch week settles under the written
///      first-week rule (the token cap alone — no price is ever guessed) at the
///      full weekly cap (Q25). That rule is keyed on the launch state, never on
///      price availability (round 4 H1): once the pool has opened, a platform
///      price the oracle will not vouch for refuses settlement until it will.
///      A LISTED QUOTE is read the same way and for the same reason (v1.6.5):
///      a quote whose spot has merely moved from its own average refuses and
///      waits, because that resolves; a quote that cannot be priced at all
///      blocks its week through the grace and is then counted as zero, because
///      that need not. The two statuses mean different things and the code
///      branches on them.
///
///      **Per week:** fees are priced per quote by the pricer at settlement
///      (never summed raw across quotes); `emitted = min(value cap, token cap,
///      remaining)`, where the value cap is `valueRatioBps` of the week's fees
///      in platform coin at its own average price and the token cap falls
///      linearly over the 52 weeks; it splits by the week's weights into three
///      track pots, a track with no fees emitting nothing that week, and a
///      share of each pot may be redirected to a bridge escrow — a share of
///      what is actually emitted (round 4 M1). A claim is the
///      account's share of each pot by its priced fees in that track; floors
///      everywhere, so the claims of a week can never exceed its pots.
///
///      **Three levers, and only three** (owner ruling Q26): the value ratio
///      (5%–20%), a redirect of up to half of each *new* week's emission to a
///      bridge escrow, and the pricer. Each is callable only by the timelock,
///      bounded here at the callee, and effective from the next ledger week
///      (the pricer from the next settlement). A settled week is never touched.
contract FeastEmissions {
    using SafeERC20 for IERC20;
    using Checkpoints for Checkpoints.Trace208;

    error NotTimelock();
    error RatioOutOfBand(uint16 bps);
    error RedirectOutOfBand(uint16 bps, address escrow);
    error PricerHasNoCode(address pricer);
    error WeekOutOfRange(uint256 week);
    error NotInOrder(uint256 next);
    error WeekNotClosed(uint256 week, uint256 closesAt);
    error QuoteUnpriceable(address quote);
    error QuotePriceMoved(address quote);
    error PlatformPriceMoved();
    error PlatformUnpriceable();
    error ClaimsNotOpen();
    error NotSettled(uint256 week);
    error AlreadyClaimed(uint256 week, address account);
    error Expired(uint256 week);
    error NotExpired(uint256 week);
    error AlreadyDone(uint256 week);
    error NotFinished();

    event ValueRatioScheduled(uint16 bps, uint256 fromLedgerWeek);
    event RedirectScheduled(uint16 bps, address escrow, uint256 fromLedgerWeek);
    event PricerReplaced(address pricer);
    event WeekSettled(
        uint256 indexed week, uint256 feesNative, uint256 emitted, uint256 redirected, uint256[3] pots, bool tokenCapOnly
    );
    event Claimed(uint256 indexed week, address indexed account, uint256 amount);
    event ExpiredBurned(uint256 indexed week, uint256 amount);
    event RedirectReleased(uint256 indexed week, address escrow, uint256 amount);
    event RemainderBurned(uint256 amount);

    /// @notice Tracks, in this order everywhere: referrer, trader, creator.
    uint256 public constant REFERRER = 0;
    uint256 public constant TRADER = 1;
    uint256 public constant CREATOR = 2;

    uint256 internal constant ONE = 1 << 128;

    struct Week {
        uint64 settledAt;
        /// @dev What `guardian.frozenSeconds()` read at settlement. The claim
        ///      grace is extended by whatever the brake has held down since, so
        ///      a freeze cannot eat a claimant's deadline — see `expiryOf`. From
        ///      v1.6.22 to v1.6.26 it was also where the next week's pricing
        ///      grace counted frozen seconds from; since v1.6.27 that grace reads
        ///      the guardian's own count at its close — see `settle`.
        uint64 frozenAtSettle;
        bool tokenCapOnly;
        bool redirectReleased;
        bool expiredBurned;
        address pricer;
        address escrow;
        uint256 redirected;
        uint256 claimed;
        uint256[3] pot;
        uint256[3] value;
    }

    FeastFeeLedger public immutable ledger;
    FeastHook public immutable hook;
    IERC20 public immutable platformCoin;
    PoolId public immutable platformPoolId;
    address public immutable timelock;
    /// @notice Ledger week of emission week 1: the factory's opening week.
    uint256 public immutable firstWeek;
    /// @notice The whole emissions budget, in platform coin.
    uint256 public immutable budget;

    FeastPricer public pricer;
    uint256 public settledCount;
    uint256 public remaining;
    /// @notice What is owed and not yet paid, burned or released.
    uint256 public liabilities;

    Checkpoints.Trace208 internal _ratio;
    Checkpoints.Trace208 internal _redirect;
    mapping(uint256 week => Week) internal _weeks;
    /// @dev The quote list a week was SETTLED over, snapshotted once, in the
    ///      order `settle` priced it and with each distinct quote appearing
    ///      once. The owed/claim path reads this and never the pricer
    ///      (v1.6.3, `CA-7e9b1e15be`).
    ///
    ///      Kept beside `Week` rather than on it, deliberately: a member added
    ///      to `Week` would reshape the tuple `weekInfo` already returns — a
    ///      silent break for every consumer decoding it — and `weekInfo`
    ///      returns `Week memory`, so the list would be copied out of storage
    ///      on every call that only wanted the pots.
    mapping(uint256 week => address[]) internal _weekQuotes;
    mapping(uint256 week => mapping(address quote => uint256)) public priceOf;
    mapping(uint256 week => mapping(address account => bool)) public claimed;

    constructor(
        address ledger_,
        address hook_,
        address platformCoin_,
        PoolId platformPoolId_,
        address timelock_,
        address pricer_,
        uint256 firstWeek_,
        address guardian_
    ) {
        guardian = IFeastGuardian(guardian_);
        ledger = FeastFeeLedger(ledger_);
        hook = FeastHook(hook_);
        platformCoin = IERC20(platformCoin_);
        platformPoolId = platformPoolId_;
        timelock = timelock_;
        pricer = FeastPricer(pricer_);
        firstWeek = firstWeek_;
        budget = FeastGenesis.PLATFORM_SUPPLY * FeastGenesis.EMISSIONS_BPS / FeastGenesis.BPS;
        remaining = budget;
        _ratio.push(0, FeastGenesis.DEFAULT_VALUE_RATIO_BPS);
        _redirect.push(0, 0);
    }

    // --- the three levers ------------------------------------------------------


    /// @notice The brake. It can pause this contract's outflows for at most 72
    ///         hours at a time and can do nothing else here. See `FeastGuardian`.
    IFeastGuardian public immutable guardian;

    error Frozen();

    /// @dev This contract belongs to no single pool, so it asks the whole-system
    ///      question. A per-pool freeze is for a pool's trading and its own fee
    ///      claims; anything that spans coins is `ALL` or nothing.
    function _requireUnfrozen() internal view {
        if (guardian.isFrozenAll()) revert Frozen();
    }

    /// @notice What genesis asks every contract it names.
    function genesisRole() external pure returns (bytes32) {
        return FeastGenesis.ROLE_EMISSIONS;
    }


    modifier onlyTimelock() {
        if (msg.sender != timelock) revert NotTimelock();
        _;
    }

    /// @notice The value cap's ratio, from the next ledger week.
    function setValueRatioBps(uint16 bps) external onlyTimelock {
        if (bps < FeastGenesis.MIN_VALUE_RATIO_BPS || bps > FeastGenesis.MAX_VALUE_RATIO_BPS) {
            revert RatioOutOfBand(bps);
        }
        uint256 from = ledger.currentWeek() + 1;
        _ratio.push(uint48(from), bps);
        emit ValueRatioScheduled(bps, from);
    }

    /// @notice Send `bps` of each new week's emission to `escrow`, from the
    ///         next ledger week. `(0, 0)` stops it. Settled weeks are untouched.
    function setRedirect(uint16 bps, address escrow) external onlyTimelock {
        if (bps > FeastGenesis.MAX_REDIRECT_BPS || (bps == 0) != (escrow == address(0))) {
            revert RedirectOutOfBand(bps, escrow);
        }
        uint256 from = ledger.currentWeek() + 1;
        _redirect.push(uint48(from), uint208(bps) | (uint208(uint160(escrow)) << 16));
        emit RedirectScheduled(bps, escrow, from);
    }

    /// @notice Price the next settlements with a new pricer (new routes).
    function setPricer(address pricer_) external onlyTimelock {
        if (pricer_.code.length == 0) revert PricerHasNoCode(pricer_);
        pricer = FeastPricer(pricer_);
        emit PricerReplaced(pricer_);
    }

    function valueRatioAt(uint256 ledgerWeek) public view returns (uint16) {
        return uint16(_ratio.upperLookup(uint48(ledgerWeek)));
    }

    function redirectAt(uint256 ledgerWeek) public view returns (uint16 bps, address escrow) {
        uint208 v = _redirect.upperLookup(uint48(ledgerWeek));
        bps = uint16(v);
        escrow = address(uint160(v >> 16));
    }

    // --- the curve and the weights -------------------------------------------

    /// @notice Most platform coin week `n` may emit: linear, week 1 largest,
    ///         week 52 smallest, summing to the budget (less rounding, which
    ///         stays in `remaining` and burns at the end).
    function tokenCap(uint256 n) public view returns (uint256) {
        return budget * (FeastGenesis.EMISSION_WEEKS + 1 - n) / FeastGenesis.CURVE_DENOMINATOR;
    }

    function weights(uint256 n) public pure returns (uint16[3] memory w) {
        if (n <= FeastGenesis.EARLY_WEEKS) {
            w = [FeastGenesis.EARLY_REFERRER_BPS, FeastGenesis.EARLY_TRADER_BPS, FeastGenesis.EARLY_CREATOR_BPS];
        } else {
            w = [FeastGenesis.LATE_REFERRER_BPS, FeastGenesis.LATE_TRADER_BPS, FeastGenesis.LATE_CREATOR_BPS];
        }
    }

    function ledgerWeekOf(uint256 n) public view returns (uint256) {
        return firstWeek + n - 1;
    }

    // --- settlement ------------------------------------------------------------

    /// @notice Settle emission week `n`: in order, once, after it closes.
    ///         Permissionless.
    function settle(uint256 n) external {
        _requireUnfrozen();
        if (n == 0 || n > FeastGenesis.EMISSION_WEEKS) revert WeekOutOfRange(n);
        if (n != settledCount + 1) revert NotInOrder(settledCount + 1);
        uint256 w = ledgerWeekOf(n);
        uint256 closesAt = ledger.weekStart(w + 1);
        if (block.timestamp < closesAt) revert WeekNotClosed(n, closesAt);
        // **The pricing grace is three days of OPEN time after the week closes,
        // and its end moves only by frozen seconds** (v1.6.15 coordinator ruling
        // 4; v1.6.22). `settle` is refused under a freeze, so a freeze straddling
        // the grace consumed it with nobody able to price anything, and the week
        // then settled past the grace — which permits an irreversible zero
        // valuation (`P5b` HIGH, `P16b` HIGH). So the grace is extended by the
        // frozen time: its end is the close, plus three days, plus every second
        // the brake has been down since.
        //
        // **v1.6.15 to v1.6.21 extended it by RESTARTING it** from
        // `allUnfrozenAt()`, the instant the last freeze ended. That instant
        // moves on any unfreeze, so a freeze taken and lifted in the same second
        // — no frozen time at all — handed a grace that had already expired
        // three fresh days, as often as the budget allowed
        // (`pull-restarts-the-grace`, `P17-claude` MEDIUM, v1.6.16; proven HIGH
        // as `pricing-grace-restart` by the Codex appendix on v1.6.21-audit, PoC
        // `test/audit/poc/PricingGraceRestart.t.sol`). Counting SECONDS instead
        // of restarting on an EVENT closes it by construction: a freeze of zero
        // seconds adds zero.
        //
        // **"Since the close" means since the close** (v1.6.27,
        // `CA-6b91a230c6`). It needs the guardian's frozen seconds AT the close,
        // and a close is not a transaction, so from v1.6.22 to v1.6.26 this
        // counted from the nearest record it had — the previous week's
        // `frozenAtSettle` when that came before the close, else zero. Frozen
        // seconds that ENDED before the close, which blocked no settlement,
        // lengthened the grace too: by up to the whole budget, and for the week
        // before the seam past `openAt`, where it settled under the value cap
        // instead of the token cap a pre-launch week is written to get (PoC
        // `test/audit/poc/PreCloseFreezesCarryAWeekPastTheSeam.t.sol`). The
        // guardian now keeps the freezes that have ended and answers for the
        // close itself, so a freeze that ended before the close extends
        // nothing, and one running across it extends the grace by its part
        // after the close only. No rule on the guardian's latest fold alone
        // could do that: a freeze folded after the close made the history
        // unreadable, and the grace reopened (`docs/audit/v1.6.27-changes.md`).
        //
        // Two properties, each pinned by a fuzz test in `FeastPricingGrace.t.sol`:
        //
        //   - **never early**: the frozen seconds since the close are counted
        //     exactly, so whenever the grace is over, three days of open time
        //     have passed since the close — and as soon as they have, it is;
        //   - **never again**: frozen seconds grow no faster than the clock, so
        //     once the grace is over it is over at every later instant — no
        //     freeze, of any length, reopens it.
        //
        // Frozen seconds after the close still delay the week, by exactly
        // themselves, and `FREEZE_BUDGET` bounds that at 168 hours. That is the
        // direction this contract already chose: settling late forfeits nothing,
        // which `check-boundaries.py settlement-deadline` pins by refusing any
        // upper bound on when a week may be settled. Delay beats zero-counting.
        uint64 frozenNow = guardian.frozenSeconds();
        bool graceOver;
        {
            uint64 atClose = guardian.frozenSecondsAt(uint64(closesAt));
            graceOver = block.timestamp >= closesAt + FeastGenesis.PRICING_GRACE + (frozenNow - atClose);
        }

        Week storage wk = _weeks[n];
        FeastPricer pr = pricer;
        wk.pricer = address(pr);

        // Price every listed quote once, for this week, for good — and record
        // WHICH quotes those were, because "once, for good" has to cover the
        // list as well as the prices. Before v1.6.3 the list was re-read from
        // the pricer at claim time, so an accepted module that returned a
        // longer list afterwards revalued a settled week's entitlements with no
        // bytecode change and no second privileged call (`CA-7e9b1e15be`).
        uint256 feesNative;
        {
            address[] memory qs = pr.quotes();
            address[] storage snapshot = _weekQuotes[n];
            for (uint256 i = 0; i < qs.length; i++) {
                // A quote this week has already priced is counted ONCE, not
                // refused. Refusing would hand any accepted module — or an
                // honest one with an accidental duplicate — a way to brick
                // settlement for good: settlement is strictly in order, so week
                // `n` reverting blocks every week after it, and the only way
                // out would be the same lever that is under suspicion. Counting
                // once keeps the two halves of a claim's fraction consistent:
                // `wk.value[t]` below accumulates per distinct quote, and
                // `_priced` iterates this same distinct list.
                if (priceOf[n][qs[i]] != 0) continue;
                (FeastPricer.Status s, uint256 price) = pr.priceQ128(qs[i]);
                if (s != FeastPricer.Status.Ok) {
                    // The written rule, BY STATUS — and the two halves of this
                    // function now agree, which is all of `CA-81659c1034`
                    // (v1.6.5 F2). Every non-`Ok` status used to collapse into
                    // price zero past the grace, while the platform coin's
                    // identical `Moved` thirty lines below refused and waited.
                    //
                    // `Moved` is a price the pool HAS and the oracle will not
                    // vouch for: spot sits more than `MAX_TICK_DEVIATION` from
                    // its own ten-minute average (`FeastPricer.sol:190-191`).
                    // The pricer calls that "retry, never guess"
                    // (`FeastPricer.sol:155-157`), settlement is permissionless
                    // and can be retried in any later block, and zero is a
                    // guess. So this contract waits, inside the grace and past
                    // it alike.
                    //
                    // **The wait is not guaranteed to end**, and the comment
                    // that said the average "catches up by itself" claimed more
                    // than the pricer's arithmetic keeps (v1.6.5 round 1, r1v):
                    // a pool whose spot keeps moving against its own average
                    // holds `Moved` for as long as it keeps moving — ticks
                    // alternating either side of the window's mean never
                    // converge. The escape is the platform branch's escape, the
                    // timelock's pricer lever, and the trade is the platform
                    // branch's trade.
                    //
                    // It is taken only for a quote that CARRIES FEES this week.
                    // A listed quote with no credits cannot move any number
                    // this week settles at, so holding the week for its price
                    // would buy nothing — and it would reach further than the
                    // platform coin's own refusal, which is consulted only when
                    // the week has fees at all (`cap != 0` below). Reading the
                    // totals costs one ledger call, on the refusal path only.
                    if (s == FeastPricer.Status.Moved) {
                        FeastFeeLedger.Credit memory moved = ledger.totals(w, qs[i]);
                        if (moved.paid != 0 || moved.earned != 0 || moved.referred != 0) {
                            revert QuotePriceMoved(qs[i]);
                        }
                        continue;
                    }
                    // `Unpriceable` is the other thing, and it is what Q11's
                    // rule was written for: no route, too little history, an
                    // oracle that will not answer, or a composed price no word
                    // can hold — none of which need EVER resolve
                    // (`FeastPricer.sol:129,182-184,193,141-142`). Wait out the
                    // grace, then count it as zero, and never wait for ever on
                    // a price that may never arrive.
                    if (!graceOver) revert QuoteUnpriceable(qs[i]);
                    price = 0;
                }
                if (price == 0) continue;
                priceOf[n][qs[i]] = price;
                snapshot.push(qs[i]);
                FeastFeeLedger.Credit memory t = ledger.totals(w, qs[i]);
                wk.value[REFERRER] += Math.mulDiv(t.referred, price, ONE);
                wk.value[TRADER] += Math.mulDiv(t.paid, price, ONE);
                wk.value[CREATOR] += Math.mulDiv(t.earned, price, ONE);
            }
            // Every fee has exactly one payer, so the trader track is the fees.
            feesNative = wk.value[TRADER];
        }

        uint256 cap = feesNative == 0 ? 0 : tokenCap(n);
        if (cap != 0) {
            (FeastPricer.Status ps, uint256 perNative) = pr.platformPerNativeQ128();
            // **A TWAP measured across frozen time is not a price anyone could
            // correct** (v1.6.15, coordinator ruling 3). `Moved` means spot has
            // been pushed away from the average; the remedy is to wait and let
            // trading bring them back together. A freeze writes no observations,
            // so the average drifts toward the stale spot with no trade
            // happening at all, and a price this contract REFUSED ages into one
            // it accepts while the corrective trades are prohibited (`P16b`
            // MEDIUM, reported at `FeastOracle:168`).
            //
            // The aging must therefore measure OPEN time, and over the window
            // the average is actually taken across: `TWAP_WINDOW`, not the
            // shorter `MIN_OBSERVATION_AGE`. Until a full averaging window of
            // open time has passed since trading resumed, this reads as `Moved`
            // — the status the same price already had — and the grace it must
            // then wait out is itself measured in open time (above), so the two
            // compose rather than race.
            //
            // What this does and does not buy, stated: ten open minutes with no
            // trade leaves the average exactly where the freeze left it. What
            // changes is that for those ten minutes anyone COULD have traded it
            // back, which is the whole content of "open time" — and the grace
            // holds the week until three open days have passed since its close,
            // in which the pool is live and the price is genuinely tested.
            //
            // The correction is here and not in `FeastPricer` because the pricer
            // holds no guardian reference; giving it one would move every
            // predicted address in the deployment. The consumer that can see
            // both the price and the brake is this one.
            //
            // **One instant, because there is one scope** (v1.6.17). v1.6.16
            // read a per-pool resume instant here, because a freeze scoped to
            // the platform pool stopped exactly the swaps its average was built
            // from while the all-scope instant did not move. The owner removed
            // the pool-scoped freeze, so `max(allUnfrozenAt(), unfrozenAtFor(p))`
            // collapses to `allUnfrozenAt()`. It is the right instrument HERE —
            // the question is how long the market has been open since it last
            // reopened — and the wrong one for the grace above, which read it
            // too until v1.6.22: an instant moves on a freeze of no seconds at
            // all, and a deadline must move only by frozen time.
            // Zero means no freeze has ever ended for this pool, so there is
            // nothing to wait out; without the guard the condition is a claim
            // about the age of the CHAIN rather than about open time.
            uint256 pricedFrom = guardian.allUnfrozenAt();
            if (
                ps == FeastPricer.Status.Ok && pricedFrom != 0
                    && block.timestamp < pricedFrom + FeastConstants.TWAP_WINDOW
            ) {
                ps = FeastPricer.Status.Moved;
            }
            // v1.6.7 (the v1.6.6 pack's MEDIUM, Claude family): **the first-week
            // rule is keyed on the LAUNCH STATE**, which is what this contract's
            // docstring at `:33-35` has said since round 4 H1 and what this
            // branch did not do. It asked whether a price EXISTED, and one
            // exists before the pool opens: the launch window's own settling
            // swap writes the platform pool's first oracle observation, and
            // `MIN_OBSERVATION_AGE` (300 s) is far inside `SETTLE_GRACE` (an
            // hour). So for 55 minutes a week could be settled either way, and
            // which one it got was decided by whoever called `settle` first —
            // measured at 0.149 against 5 255 443 platform coin for one week.
            //
            // The order of the two questions is the fix: the launch state comes
            // first, and the price is consulted only once it can mean what the
            // value cap needs it to mean. Nothing after launch changes.
            // The v1.6.14 sweep classified the `openAt` gate `RUNS`. At this
            // site it is not admitting anyone — it chooses between two award
            // formulas — so it is a deadline wearing a gate's clothes, and a
            // freeze straddling `openAt` takes away the window in which a
            // settler could have had the token cap (`P16b` HIGH, `P5b` MEDIUM,
            // `P5-claude` MEDIUM).
            //
            // **Not fixed here, and the reason is written down rather than
            // dressed up.** Correcting it needs the frozen seconds AS OF
            // `openAt`, and nothing runs at `openAt` to stamp them: the nearest
            // writable instant is the first transaction after it, which is the
            // settle this would gate. `max(openAt, allUnfrozenAt())` — the
            // deferred-open stamp the run-26 ruling proposed — was written,
            // measured and removed: `settle` is refused throughout a live ALL
            // freeze and the stamp folds to the freeze's end, so the comparison
            // flips true in the same block the brake lifts and no reachable
            // outcome changes. Shipping it would have been dead code described
            // as a fix.
            //
            // What DOES bite is above: the grace holds a moved price until three
            // OPEN days have passed since the week closed — its end moves by
            // every frozen second and, since v1.6.22, by nothing else — and a
            // price may not be trusted until a full averaging window of open
            // time has passed since trading resumed. The residue is the lost
            // PRE-OPEN settlement window, which is bounded by
            // `openAt - closesAt` and is put to the coordinator.
            if (!claimsOpen()) {
                // Before the pool opens: the token cap alone, whatever the
                // oracle happens to be able to say. `Moved` still waits out the
                // grace — a price that has moved is not a reason to settle
                // early, and that refusal predates this and is unchanged.
                if (ps == FeastPricer.Status.Moved && !graceOver) revert PlatformPriceMoved();
                wk.tokenCapOnly = true;
            } else if (ps == FeastPricer.Status.Ok) {
                // v1.6.5 F1 (`CA-5203dcf236`): **the minimum is established before
                // anything is multiplied out.** `Math.mulDiv` carries its
                // intermediate at 512 bits and panics when its RESULT exceeds 256
                // bits, so this site used to revert on the size of the side the
                // comparison DISCARDS — a week whose cap is the token cap, a
                // number under `2^93` that never needed the value cap to compute.
                // Settlement is strictly in order (`:239`), so that week took every
                // later week with it.
                //
                // v1.6.4's sweep rewrote the INNER product here and recorded the
                // row closed. A `mulDiv` is not a bound: it moves the failure from
                // the intermediate to the result and leaves the result unasked.
                //
                // The inner product cannot overflow at all — `valueRatioAt` is at
                // most `MAX_VALUE_RATIO_BPS` (2 000) against a divisor of `BPS`
                // (10 000), so `inner <= feesNative / 5`.
                uint256 inner = Math.mulDiv(feesNative, valueRatioAt(w), FeastGenesis.BPS);
                // `high` is the top word of `inner * perNative`, and the value cap
                // is that product over `ONE = 2^128`. So
                //
                //     valueCap < 2^256  <=>  inner * perNative < 2^384  <=>  high < ONE,
                //
                // which is EXACTLY when the `mulDiv` below does not panic, not a
                // conservative approximation of it. And when `high >= ONE` the
                // comparison's answer is already known: `valueCap >= 2^256` while
                // `cap <= tokenCap(n) <= budget < 2^93`, so the token cap is the
                // minimum and the larger side is never needed. This is the pricer's
                // own idiom (`FeastPricer.sol:141-143`), where a composed price no
                // word can hold is answered rather than reverted.
                (uint256 high,) = Math.mul512(inner, perNative);
                if (high < ONE) {
                    uint256 valueCap = Math.mulDiv(inner, perNative, ONE);
                    if (valueCap < cap) cap = valueCap;
                }
            } else {
                // Round 4 H1: once the platform coin's pool has opened, the value
                // cap always binds. A price the oracle will not vouch for refuses
                // settlement and waits — for ever if need be, until the pricer
                // lever replaces the pricer. Halting is the safe side.
                if (ps == FeastPricer.Status.Moved) revert PlatformPriceMoved();
                revert PlatformUnpriceable();
            }
        }
        if (cap > remaining) cap = remaining;

        uint256 emitted;
        if (cap != 0) {
            (uint16 rBps, address escrow) = redirectAt(w);
            uint16[3] memory wt = weights(n);
            uint256 redirected;
            for (uint256 t = 0; t < 3; t++) {
                if (wk.value[t] == 0) continue; // an empty track emits nothing
                uint256 share = cap * wt[t] / FeastGenesis.BPS;
                // Round 4 M1: the redirect is a share of what is emitted, taken
                // track by track, so empty tracks cannot inflate it.
                uint256 away = share * rBps / FeastGenesis.BPS;
                wk.pot[t] = share - away;
                redirected += away;
                emitted += share;
            }
            if (redirected != 0) {
                wk.redirected = redirected;
                wk.escrow = escrow;
            }
        }

        wk.settledAt = uint64(block.timestamp);
        // Read once, above, for the grace: nothing in this call can move it.
        wk.frozenAtSettle = frozenNow;
        settledCount = n;
        remaining -= emitted;
        liabilities += emitted;
        emit WeekSettled(n, feesNative, emitted, wk.redirected, wk.pot, wk.tokenCapOnly);
    }

    // --- claims ------------------------------------------------------------------

    /// @notice Whether claims are open: the platform coin exists and its pool's
    ///         gate has passed.
    /// @dev It used to add "(the launch window has settled or been voided)",
    ///      which was true while the window could settle only before `openAt`.
    ///      Since v1.6.24 it may settle after it (AstraSec M-2); until it does,
    ///      the pool is uninitialised and the platform price is `Unpriceable`,
    ///      the same state a window that never settled always produced here.
    function claimsOpen() public view returns (bool) {
        FeastHook.Pool memory p = hook.poolInfo(platformPoolId);
        return p.coin != address(0) && block.timestamp >= p.openAt;
    }

    /// @notice Last second a settled week may be claimed: twelve weeks after the
    ///         later of its settlement and the opening of claims.
    function expiryOf(uint256 n) public view returns (uint256) {
        Week storage wk = _weeks[n];
        if (wk.settledAt == 0 || !claimsOpen()) return type(uint256).max;
        uint256 openedAt = hook.poolInfo(platformPoolId).openAt;
        uint256 from = wk.settledAt > openedAt ? wk.settledAt : openedAt;
        // **A freeze must not eat a claimant's deadline.** `claim` is frozen and
        // this clock is not, so a 72-hour pull of the brake placed before an
        // expiry stopped a claimant claiming and let `burnExpired` destroy the
        // entitlement. Two units of the v1.6.12 round found it, one in each
        // family; `test/audit/poc/FreezeExpiresAClaim.t.sol` is the PoC.
        //
        // It is the argument the launch window already won — a deadline on a
        // clock must never be pushed past itself — which I applied there and not
        // here. The grace is now extended by every second the brake has been
        // down since this week settled.
        //
        // Measured from SETTLEMENT even when the window opens later, so frozen
        // time between the two is added as well. That only ever LENGTHENS a
        // claimant's window, which is the safe direction, and it costs one
        // comparison rather than a second checkpoint.
        return from + FeastGenesis.CLAIM_GRACE + (guardian.frozenSeconds() - wk.frozenAtSettle);
    }

    /// @notice What `account` is owed for week `n` (zero if unsettled).
    function owed(uint256 n, address account) public view returns (uint256 amount) {
        Week storage wk = _weeks[n];
        if (wk.settledAt == 0) return 0;
        uint256[3] memory mine = _priced(n, account);
        for (uint256 t = 0; t < 3; t++) {
            if (wk.value[t] != 0) amount += Math.mulDiv(wk.pot[t], mine[t], wk.value[t]);
        }
    }

    /// @notice An account's referred fees in week `n`, priced — what the genesis
    ///         grants count. The same ledger and the same prices as the pots.
    function referredValue(uint256 n, address account) external view returns (uint256) {
        if (_weeks[n].settledAt == 0) return 0;
        return _priced(n, account)[REFERRER];
    }

    function claim(uint256 n, address account) public returns (uint256 amount) {
        _requireUnfrozen();
        if (!claimsOpen()) revert ClaimsNotOpen();
        Week storage wk = _weeks[n];
        if (wk.settledAt == 0) revert NotSettled(n);
        if (block.timestamp > expiryOf(n)) revert Expired(n);
        if (claimed[n][account]) revert AlreadyClaimed(n, account);
        claimed[n][account] = true;
        amount = owed(n, account);
        if (amount == 0) return 0;
        wk.claimed += amount;
        liabilities -= amount;
        emit Claimed(n, account, amount);
        platformCoin.safeTransfer(account, amount);
    }

    function claimMany(uint256[] calldata ns, address account) external returns (uint256 total) {
        _requireUnfrozen();
        for (uint256 i = 0; i < ns.length; i++) {
            total += claim(ns[i], account);
        }
    }

    // --- the ends of things ------------------------------------------------------

    /// @notice Burn what a week's claimants left unclaimed past its expiry.
    function burnExpired(uint256 n) external {
        _requireUnfrozen();
        Week storage wk = _weeks[n];
        if (wk.settledAt == 0) revert NotSettled(n);
        if (block.timestamp <= expiryOf(n)) revert NotExpired(n);
        if (wk.expiredBurned) revert AlreadyDone(n);
        wk.expiredBurned = true;
        uint256 amount = wk.pot[0] + wk.pot[1] + wk.pot[2] - wk.claimed;
        liabilities -= amount;
        emit ExpiredBurned(n, amount);
        if (amount != 0) IFeastBurnableToken(address(platformCoin)).burn(amount);
    }

    /// @notice Pay a week's redirected share to the escrow it was redirected to.
    function releaseRedirect(uint256 n) external {
        _requireUnfrozen();
        if (!claimsOpen()) revert ClaimsNotOpen();
        Week storage wk = _weeks[n];
        if (wk.settledAt == 0) revert NotSettled(n);
        if (wk.redirectReleased || wk.redirected == 0) revert AlreadyDone(n);
        wk.redirectReleased = true;
        liabilities -= wk.redirected;
        emit RedirectReleased(n, wk.escrow, wk.redirected);
        platformCoin.safeTransfer(wk.escrow, wk.redirected);
    }

    /// @notice After week 52, burn everything held that nobody is owed: the
    ///         never-emitted remainder, rounding, and any stray balance.
    function burnRemainder() external {
        _requireUnfrozen();
        if (settledCount != FeastGenesis.EMISSION_WEEKS || !claimsOpen()) revert NotFinished();
        uint256 held = platformCoin.balanceOf(address(this));
        uint256 amount = held > liabilities ? held - liabilities : 0;
        remaining = 0;
        emit RemainderBurned(amount);
        if (amount != 0) IFeastBurnableToken(address(platformCoin)).burn(amount);
    }

    // --- views ------------------------------------------------------------------

    function weekInfo(uint256 n) external view returns (Week memory) {
        return _weeks[n];
    }

    /// @notice The quote list week `n` was settled over — what every claim for
    ///         that week is computed from, fixed at settlement (v1.6.3).
    function settledQuotes(uint256 n) external view returns (address[] memory) {
        return _weekQuotes[n];
    }

    /// @dev An account's fees in each track of week `n`, priced with the prices
    ///      that week was settled at, over the quote list that week was settled
    ///      over. Per quote, floored — so the sum over every account of a track
    ///      never exceeds the track's settled value.
    ///
    ///      **Nothing on this path asks the pricer anything**, which is the
    ///      whole property (v1.6.3, `CA-7e9b1e15be`). Not "no external call":
    ///      `ledger.credit` below is one, `claim` reads the hook through
    ///      `claimsOpen()`, and `claim` transfers the platform coin. All three
    ///      are immutable addresses fixed in the constructor, replaceable by no
    ///      lever and by nobody. The pricer is
    ///      the one thing here a timelock call can swap, and it is the one thing
    ///      this path no longer consults. `settle` stored the pricer's address and
    ///      every quote's price, and both are immutable afterwards — but what
    ///      that address SAYS is not, and this function used to ask it. A module
    ///      returning a longer list after settlement counted a quote twice into
    ///      an account's numerator while the denominator `wk.value[t]`, frozen
    ///      at settlement, stayed as it was: a settled week's entitlement
    ///      doubled, above that week's own pot, from nothing but the clock.
    ///      `wk.pricer` is still the record of which module settled the week;
    ///      nothing reads it here or anywhere else on a priced path.
    function _priced(uint256 n, address account) internal view returns (uint256[3] memory mine) {
        uint256 w = ledgerWeekOf(n);
        address[] memory qs = _weekQuotes[n];
        for (uint256 i = 0; i < qs.length; i++) {
            uint256 price = priceOf[n][qs[i]];
            if (price == 0) continue;
            FeastFeeLedger.Credit memory c = ledger.credit(w, qs[i], account);
            mine[REFERRER] += Math.mulDiv(c.referred, price, ONE);
            mine[TRADER] += Math.mulDiv(c.paid, price, ONE);
            mine[CREATOR] += Math.mulDiv(c.earned, price, ONE);
        }
    }
}
