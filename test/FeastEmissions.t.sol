// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

import {FeastConstants} from "../src/FeastConstants.sol";
import {FeastEmissions} from "../src/FeastEmissions.sol";
import {FeastFactory} from "../src/FeastFactory.sol";
import {FeastFeeLedger} from "../src/FeastFeeLedger.sol";
import {FeastGenesis} from "../src/FeastGenesis.sol";
import {FeastPricer} from "../src/FeastPricer.sol";
import {PoolId} from "../src/venue/PoolId.sol";
import {PoolKey} from "../src/venue/PoolKey.sol";

import {UnitFixture} from "./utils/UnitFixture.sol";

/// The first year's emissions.
///
/// What is held here is what a payout would silently inherit: a week settles
/// once, in order, after it closes; it emits the smaller of its value cap, its
/// token cap and what is left; before the platform coin has a price it settles
/// under the token cap alone; its pots follow the week's weights and an empty
/// track emits nothing; claims wait until the platform coin's pool opens and
/// never exceed a week's pots; the three levers answer only to the timelock,
/// stay inside their bands at the callee and never touch a settled week; and
/// whatever nobody is owed burns at the end.
/// A pricer module that prices exactly as the real one does and then goes dark:
/// its `quotes()` reverts from the moment anyone flips it. Nothing here is a
/// call to emissions or to the timelock — the module mutates itself, which is
/// the whole shape of `CA-7e9b1e15be`.
contract DarkeningPricer {
    FeastPricer public immutable inner;
    bool public dark;

    error TheModuleIsDark();

    constructor(FeastPricer inner_) {
        inner = inner_;
    }

    function goDark() external {
        dark = true;
    }

    function quotes() external view returns (address[] memory) {
        if (dark) revert TheModuleIsDark();
        return inner.quotes();
    }

    function routeOf(address quote) external view returns (address[] memory) {
        return inner.routeOf(quote);
    }

    function priceQ128(address quote) external view returns (FeastPricer.Status, uint256) {
        if (dark) revert TheModuleIsDark();
        return inner.priceQ128(quote);
    }

    function platformPerNativeQ128() external view returns (FeastPricer.Status, uint256) {
        return inner.platformPerNativeQ128();
    }
}

/// A pricer module whose quote list carries every entry twice — at settlement,
/// not after it. An accepted module could do this; so could an honest one by
/// accident.
contract DuplicatingPricer {
    FeastPricer public immutable inner;

    constructor(FeastPricer inner_) {
        inner = inner_;
    }

    function quotes() external view returns (address[] memory qs) {
        address[] memory base = inner.quotes();
        qs = new address[](base.length * 2);
        for (uint256 i = 0; i < base.length; i++) {
            qs[2 * i] = base[i];
            qs[2 * i + 1] = base[i];
        }
    }

    function routeOf(address quote) external view returns (address[] memory) {
        return inner.routeOf(quote);
    }

    function priceQ128(address quote) external view returns (FeastPricer.Status, uint256) {
        return inner.priceQ128(quote);
    }

    function platformPerNativeQ128() external view returns (FeastPricer.Status, uint256) {
        return inner.platformPerNativeQ128();
    }
}

contract FeastEmissionsTest is UnitFixture {
    PoolKey internal keyA; // a coin quoted in wrapped native
    PoolKey internal keyB; // a coin quoted in a tokenised stock
    address internal coinA;
    address internal coinB;

    function setUp() public override {
        super.setUp();
        (coinA, keyA) = _create(address(wbnb), bytes32(uint256(1)));
        (coinB, keyB) = _create(address(stock), bytes32(uint256(2)));
        // Week 1: a referred buy in A, an unreferred buy in B.
        _buy(keyA, address(wbnb), 100e18, trader, referrer);
        _advance(60);
        _buy(keyB, address(stock), 50e18, trader2, address(0));
    }

    function _closeWeek(uint256 n) internal {
        uint256 end = ledger.weekStart(emissions.ledgerWeekOf(n) + 1);
        if (clock < end) _warpTo(end);
    }

    function _pots(uint256 n) internal view returns (uint256[3] memory) {
        return emissions.weekInfo(n).pot;
    }

    // --- settlement ----------------------------------------------------------

    function test_aWeekSettlesOnlyAfterItClosesInOrderAndOnce() public {
        uint256 end = ledger.weekStart(emissions.ledgerWeekOf(1) + 1);
        vm.expectRevert(abi.encodeWithSelector(FeastEmissions.WeekNotClosed.selector, 1, end));
        emissions.settle(1);
        _closeWeek(2);
        vm.expectRevert(abi.encodeWithSelector(FeastEmissions.NotInOrder.selector, 1));
        emissions.settle(2);
        emissions.settle(1);
        vm.expectRevert(abi.encodeWithSelector(FeastEmissions.NotInOrder.selector, 2));
        emissions.settle(1);
        vm.expectRevert(abi.encodeWithSelector(FeastEmissions.WeekOutOfRange.selector, 53));
        emissions.settle(53);
    }

    /// Kills: a curve that rises, is flat, or sums past the budget.
    function test_theTokenCapFallsLinearlyAndSumsToTheBudget() public view {
        uint256 budget = emissions.budget();
        assertEq(budget, SUPPLY * 1_420 / 10_000, "14.2% of the supply");
        assertEq(emissions.tokenCap(1), budget * 52 / 1_378, "week 1 is the largest");
        assertEq(emissions.tokenCap(52), budget / 1_378, "week 52 the smallest");
        uint256 sum;
        for (uint256 n = 1; n <= 52; n++) {
            if (n > 1) assertLt(emissions.tokenCap(n), emissions.tokenCap(n - 1), "strictly falling");
            sum += emissions.tokenCap(n);
        }
        assertLe(sum, budget, "never more than the budget");
        assertLt(budget - sum, 52, "and short only by rounding");
    }

    /// Q8 + Q25: a week before the platform coin exists settles under the
    /// written first-week rule — the token cap alone, never a guessed price —
    /// and its pots follow weeks 1-8's weights. Kills: guessing a price;
    /// swapping the weight tables.
    function test_aPreLaunchWeekSettlesUnderTheTokenCapAlone() public {
        _closeWeek(1);
        emissions.settle(1);
        FeastEmissions.Week memory w = emissions.weekInfo(1);
        uint256 cap = emissions.tokenCap(1);
        assertTrue(w.tokenCapOnly, "no platform price yet");
        assertEq(w.pot[0], cap * 4_000 / 10_000, "referrers 40%");
        assertEq(w.pot[1], cap * 4_500 / 10_000, "traders 45%");
        assertEq(w.pot[2], cap * 1_500 / 10_000, "creators 15%");
        assertEq(emissions.remaining(), emissions.budget() - (w.pot[0] + w.pot[1] + w.pot[2]), "out of what is left");
        assertEq(emissions.liabilities(), w.pot[0] + w.pot[1] + w.pot[2], "owed, before a single token exists");
    }

    function test_fromWeekNineTheWeightsChange() public view {
        uint16[3] memory early = emissions.weights(8);
        uint16[3] memory late = emissions.weights(9);
        assertEq(early[0], 4_000);
        assertEq(early[1], 4_500);
        assertEq(early[2], 1_500);
        assertEq(late[0], 2_000);
        assertEq(late[1], 6_500);
        assertEq(late[2], 1_500);
    }

    function test_aWeekWithNoFeesEmitsNothing() public {
        _closeWeek(1);
        emissions.settle(1);
        _closeWeek(2);
        uint256 remainingBefore = emissions.remaining();
        emissions.settle(2);
        assertEq(emissions.remaining(), remainingBefore, "nothing to reward, nothing emitted");
    }

    /// Q7: a track with no fees emits nothing that week; its share stays in
    /// what is left and burns after week 52.
    function test_anEmptyTrackEmitsNothingThatWeek() public {
        _closeWeek(1);
        emissions.settle(1);
        _buy(keyB, address(stock), 10e18, trader2, address(0)); // week 2: no referral at all
        _closeWeek(2);
        emissions.settle(2);
        uint256[3] memory pots = _pots(2);
        assertEq(pots[0], 0, "no referrals, no referral pot");
        assertGt(pots[1], 0, "traders still earn");
    }

    // --- claims ------------------------------------------------------------------

    function test_claimsWaitUntilThePlatformCoinsPoolOpens() public {
        _closeWeek(1);
        emissions.settle(1);
        vm.expectRevert(FeastEmissions.ClaimsNotOpen.selector);
        emissions.claim(1, trader);
        _launch(10e18);
        uint256 owed = emissions.owed(1, trader);
        assertGt(owed, 0, "the trader is owed");
        emissions.claim(1, trader);
        assertEq(IERC20(feast).balanceOf(trader), owed, "and is paid it, in the platform coin");
        vm.expectRevert(abi.encodeWithSelector(FeastEmissions.AlreadyClaimed.selector, 1, trader));
        emissions.claim(1, trader);
    }

    /// The account's share of each pot is its priced fees in that track over
    /// the track's priced total. Kills: dividing by the wrong track; pricing a
    /// quote at settlement and another price at claim.
    function test_owedIsTheShareOfEachPotByPricedFees() public {
        _closeWeek(1);
        emissions.settle(1);
        FeastEmissions.Week memory w = emissions.weekInfo(1);
        uint256 w1 = emissions.ledgerWeekOf(1);
        uint256 pA = emissions.priceOf(1, address(wbnb));
        uint256 pB = emissions.priceOf(1, address(stock));
        assertEq(pA, 1 << 128, "wrapped native is one");
        assertGt(pB, 0, "the stock was priced");
        uint256 paidA = ledger.credit(w1, address(wbnb), trader).paid;
        uint256 expected = w.pot[1] * (paidA * pA >> 128) / w.value[1];
        assertEq(emissions.owed(1, trader), expected, "trader's share of the trader pot");
        uint256 referred = ledger.credit(w1, address(wbnb), referrer).referred;
        assertEq(emissions.owed(1, referrer), w.pot[0] * (referred * pA >> 128) / w.value[0], "referrer's share");
        assertEq(emissions.referredValue(1, referrer), referred * pA >> 128, "what the grants count");
    }

    /// The invariant a payout rests on: the claims of a week never exceed its
    /// pots, over any spread of payers and quotes.
    function testFuzz_theClaimsOfAWeekNeverExceedItsPots(uint64[6] calldata amounts) public {
        address[6] memory who;
        for (uint256 i = 0; i < 6; i++) {
            who[i] = address(uint160(0x5000 + i));
            uint256 amt = bound(uint256(amounts[i]), 1e15, 1_000e18);
            _buy(i % 2 == 0 ? keyA : keyB, i % 2 == 0 ? address(wbnb) : address(stock), amt, who[i], i % 3 == 0 ? referrer : address(0));
        }
        _closeWeek(1);
        emissions.settle(1);
        _launch(1e18);
        FeastEmissions.Week memory w = emissions.weekInfo(1);
        uint256 paid;
        for (uint256 i = 0; i < 6; i++) paid += emissions.claim(1, who[i]);
        paid += emissions.claim(1, trader) + emissions.claim(1, trader2) + emissions.claim(1, referrer) + emissions.claim(1, creator);
        assertLe(paid, w.pot[0] + w.pot[1] + w.pot[2], "claims never exceed the pots");
    }

    /// Once the platform coin has a price its value cap binds: emissions are at
    /// most `valueRatioBps` of the week's fees, in platform coin at its price.
    function test_theValueCapBindsOnceThePlatformCoinHasAPrice() public {
        _launch(10e18);
        _firstPlatformTrade();
        // Trade the platform coin so its oracle has history, then a small week.
        _advance(10 minutes);
        uint256 nSettle = emissions.settledCount();
        while (emissions.ledgerWeekOf(nSettle + 1) < ledger.currentWeek()) {
            emissions.settle(nSettle + 1);
            nSettle++;
        }
        _buy(keyA, address(wbnb), 1e18, trader, address(0));
        _buy(feastKey, address(wbnb), 1e15, trader2, address(0));
        _advance(10 minutes);
        uint256 n = nSettle + 1;
        _closeWeek(n);
        // Keep the platform coin's price answerable at settlement.
        _buy(feastKey, address(wbnb), 1e12, trader2, address(0));
        _advance(6 minutes);
        (FeastPricer.Status ps, uint256 perNative) = pricer.platformPerNativeQ128();
        assertEq(uint8(ps), uint8(FeastPricer.Status.Ok), "the platform coin has a price");
        emissions.settle(n);
        FeastEmissions.Week memory w = emissions.weekInfo(n);
        assertFalse(w.tokenCapOnly, "priced this time");
        // The value cap, computed independently: the ratio of the week's fees, in
        // platform coin at its own price. Kills: ignoring it.
        uint256 valueCap = (w.value[1] * emissions.valueRatioAt(emissions.ledgerWeekOf(n)) / 10_000) * perNative >> 128;
        assertLt(valueCap, emissions.tokenCap(n), "a week small enough for the value cap to bind");
        uint16[3] memory wt = emissions.weights(n);
        uint256 share;
        for (uint256 k = 0; k < 3; k++) if (w.value[k] != 0) share += wt[k];
        uint256 emitted = w.pot[0] + w.pot[1] + w.pot[2];
        assertLe(emitted, valueCap, "never more than the value cap");
        assertApproxEqAbs(emitted, valueCap * share / 10_000, 3, "and exactly the value cap across the tracks that earned");
    }

    /// @dev Settle every closed week, in order; the next unsettled week.
    function _settleClosedWeeks() internal returns (uint256 n) {
        n = emissions.settledCount() + 1;
        while (emissions.ledgerWeekOf(n) < ledger.currentWeek()) {
            emissions.settle(n);
            n++;
        }
    }

    /// Round 4 H1: after launch the value cap always binds, so a platform price
    /// the oracle will not vouch for refuses settlement — past the grace too.
    /// The auditor's construction: a closed week, the grace waited out, the
    /// platform coin's spot pushed past the bound in the settling transaction.
    /// Kills: letting a moved price, once the grace is over, drop the value cap
    /// (the token cap alone emitted ~4.4M where the value cap allowed ~150).
    function test_afterLaunchAMovedPlatformPriceRefusesSettlementPastTheGrace() public {
        _launch(10e18);
        _firstPlatformTrade();
        _advance(10 minutes);
        uint256 n = _settleClosedWeeks();
        _buy(keyA, address(wbnb), 1e18, trader, address(0));
        _buy(feastKey, address(wbnb), 1e15, trader2, address(0));
        _closeWeek(n);
        _advance(FeastGenesis.PRICING_GRACE + 1 hours);

        // The push: a one-sided buy far larger than the pool's depth near spot.
        _buy(feastKey, address(wbnb), 30_000_000e18, trader2, address(0));
        (FeastPricer.Status ps,) = pricer.platformPerNativeQ128();
        assertEq(uint8(ps), uint8(FeastPricer.Status.Moved), "the fixture really moved the price");
        vm.expectRevert(FeastEmissions.PlatformPriceMoved.selector);
        emissions.settle(n);
        assertEq(emissions.settledCount(), n - 1, "nothing settled, nothing emitted");
    }

    /// Round 4 H1, the other refusal: after launch a platform price that cannot
    /// be read at all waits, with no timeout, until the timelocked pricer lever
    /// replaces the pricer — halting is the safe side. Kills: an unpriceable
    /// platform coin after launch settling under the token cap alone.
    function test_afterLaunchAnUnpriceablePlatformPriceWaitsForTheLever() public {
        _launch(10e18);
        FeastPricer.Route[] memory none = new FeastPricer.Route[](0);
        // A pricer pointed at a pool that does not exist reads no platform price.
        FeastPricer blind =
            new FeastPricer(address(wbnb), address(oracle), address(pm), feast, PoolId.wrap(bytes32(uint256(1))), none);
        _viaTimelock(abi.encodeCall(FeastEmissions.setPricer, (address(blind))));
        _advance(FeastGenesis.PRICING_GRACE + 10 weeks);
        vm.expectRevert(FeastEmissions.PlatformUnpriceable.selector);
        emissions.settle(1); // week 1 earned fees before launch; it settles after
        assertEq(emissions.settledCount(), 0, "still waiting, however long");

        _buy(feastKey, address(wbnb), 1e15, trader2, address(0));
        _advance(10 minutes);
        _viaTimelock(abi.encodeCall(FeastEmissions.setPricer, (address(pricer))));
        emissions.settle(1);
        assertFalse(emissions.weekInfo(1).tokenCapOnly, "and then it settles under the value cap");
    }

    /// Round 4 L2: two hops can each be representable while their product is
    /// not. That is an unpriceable route, not a revert: it blocks its week
    /// through the grace like any other, then counts as zero. Kills: a
    /// composition overflow that blocks every later week for ever.
    function test_aRoutePriceTooLargeToHoldBlocksItsWeekOnlyForTheGrace() public {
        (FeastPricer tall, address quote) = _twoHopPricer(uint160(1 << 136));
        vm.prank(address(timelock));
        emissions.setPricer(address(tall));
        _closeWeek(1);
        vm.expectRevert(abi.encodeWithSelector(FeastEmissions.QuoteUnpriceable.selector, quote));
        emissions.settle(1);
        _advance(FeastGenesis.PRICING_GRACE);
        emissions.settle(1);
        assertEq(emissions.priceOf(1, quote), 0, "counted as zero");
        assertEq(emissions.settledCount(), 1, "and the week settled");
    }

    /// Q11: a listed quote that cannot be priced blocks its week for three days
    /// after it closes, then counts as zero. Kills: guessing its price; waiting
    /// for ever.
    function test_anUnpriceableQuoteBlocksItsWeekThenCountsAsZero() public {
        stockPool.setCardinality(1);
        _closeWeek(1);
        vm.expectRevert(abi.encodeWithSelector(FeastEmissions.QuoteUnpriceable.selector, address(stock)));
        emissions.settle(1);
        _advance(FeastGenesis.PRICING_GRACE);
        emissions.settle(1);
        assertEq(emissions.priceOf(1, address(stock)), 0, "counted as zero");
        assertEq(emissions.owed(1, trader2), 0, "so its fees earn nothing that week");
    }

    /// v1.6.5 F2 (`CA-81659c1034`): a listed quote whose spot has merely MOVED
    /// from its own average is refused and waited on — inside the grace and
    /// past it alike — as the platform coin's identical status is
    /// (`test_afterLaunchAMovedPlatformPriceRefusesSettlementPastTheGrace`
    /// above). The grace exists for a price that may never come; this one is
    /// measured against a ten-minute window and CAN come, which is the most
    /// that is true of it — a spot that keeps moving holds `Moved` for as long
    /// as it keeps moving, and the escape is then the pricer lever.
    ///
    /// Kills: collapsing every non-`Ok` status into price zero past the grace,
    /// which erased a whole week's fees in that quote from the value tracks,
    /// from every claim, and from every genesis partner's `referredValue`.
    function test_aMovedQuoteIsRefusedInsideTheGraceAndPastIt() public {
        _closeWeek(1);
        stockPool.setTicks(FeastConstants.MAX_TICK_DEVIATION + 1, 0);
        (FeastPricer.Status s,) = pricer.priceQ128(address(stock));
        assertEq(uint8(s), uint8(FeastPricer.Status.Moved), "the fixture really moved the quote");

        // Inside the grace: refused, and refused BY NAME — not as `Unpriceable`,
        // which is the status this contract may count as zero.
        vm.expectRevert(abi.encodeWithSelector(FeastEmissions.QuotePriceMoved.selector, address(stock)));
        emissions.settle(1);

        // Past the grace: the same refusal. This is the line the finding is about.
        _advance(FeastGenesis.PRICING_GRACE + 1);
        vm.expectRevert(abi.encodeWithSelector(FeastEmissions.QuotePriceMoved.selector, address(stock)));
        emissions.settle(1);
        assertEq(emissions.settledCount(), 0, "nothing settled, so the week can still be retried");
    }

    /// The other half of "refuse and wait": the waiting CAN end, and when it
    /// does the week settles at a real price and the payers in that quote are
    /// owed what they paid for — precisely what the old rule took from them.
    ///
    /// What this measures, exactly (v1.6.5 round 1, r1v): the deviation closing
    /// is supplied here rather than waited out, because the fixture's pool
    /// carries its average as a settable field and no amount of `_advance`
    /// moves it. So this is a witness that recovery WORKS once the spot is back
    /// inside the bound — not that it is automatic. A pool whose spot keeps
    /// moving against its own average holds `Moved` for as long as it keeps
    /// moving, and the escape then is the timelocked pricer lever, exactly as
    /// it is for the platform coin. That residue is recorded, not tested away.
    ///
    /// Without this witness the closure is only half measured: a refusal that
    /// could never resolve would pass the test above and brick every later week.
    function test_aMovedQuoteSettlesOnceItsSpotIsBackInsideTheBound() public {
        _closeWeek(1);
        _advance(FeastGenesis.PRICING_GRACE + 1);
        stockPool.setTicks(FeastConstants.MAX_TICK_DEVIATION + 1, 0);
        vm.expectRevert(abi.encodeWithSelector(FeastEmissions.QuotePriceMoved.selector, address(stock)));
        emissions.settle(1);

        // The spot comes back inside the bound. The fixture sets the pair
        // directly, so this is the correction SUPPLIED, not an average
        // observed catching up: what it measures is that recovery works
        // once the deviation closes, not that the deviation must close.
        stockPool.setTicks(FeastConstants.MAX_TICK_DEVIATION - 1, 0);
        emissions.settle(1);

        assertEq(emissions.settledCount(), 1, "the week settles on the retry");
        assertGt(emissions.priceOf(1, address(stock)), 0, "and the quote carries a real price");
        assertGt(emissions.owed(1, trader2), 0, "so its payer is owed what the old rule erased");
    }

    /// v1.6.5 round 1 (r1v): the refusal reaches only as far as the platform
    /// coin's does. A listed quote that carries NO fees in the week cannot move
    /// any number that week settles at, so a price the oracle will not vouch
    /// for is not worth holding the week for — and the platform coin's own
    /// price is consulted only when the week has fees at all. Week 2 here has
    /// fees in `wbnb` alone; the stock quote is listed, moved, and empty.
    ///
    /// Kills: refusing on a moved quote without asking whether it carries
    /// anything, which would let any listed pool hold up a week it has no part
    /// in — a reach the branch this fix mirrors does not have.
    function test_aMovedQuoteWithNoFeesThatWeekDoesNotHoldTheWeekUp() public {
        _closeWeek(1);
        emissions.settle(1);

        // Week 2: one buy, in wbnb, so the stock quote is listed and empty.
        _buy(keyA, address(wbnb), 1e18, trader, address(0));
        _closeWeek(2);
        FeastFeeLedger.Credit memory none = ledger.totals(emissions.ledgerWeekOf(2), address(stock));
        assertTrue(none.paid == 0 && none.earned == 0 && none.referred == 0, "the stock quote is empty");

        stockPool.setTicks(FeastConstants.MAX_TICK_DEVIATION + 1, 0);
        (FeastPricer.Status s,) = pricer.priceQ128(address(stock));
        assertEq(uint8(s), uint8(FeastPricer.Status.Moved), "and it really is moved");

        emissions.settle(2);
        assertEq(emissions.settledCount(), 2, "the week settles anyway");
        assertEq(emissions.priceOf(2, address(stock)), 0, "the empty quote carries no price");
        assertGt(emissions.weekInfo(2).pot[emissions.TRADER()], 0, "and the week that had fees paid them");
    }

    /// Round 6 (L1): each account's priced credit is floored before it divides
    /// a pot, so at a fractional price the claims still fit it. At a quarter of
    /// a WBNB per unit, two payers of a few units are worth one unit together
    /// and nothing apiece. Kills: rounding an account's valuation up (each would
    /// be owed the whole pot).
    function test_atAFractionalPriceTheClaimsStillFitThePot() public {
        _closeWeek(1);
        emissions.settle(1);
        bool stockIs0 = stockPool.token0() == address(stock);
        stockPool.setSqrtPrice(uint160(stockIs0 ? uint256(1) << 95 : uint256(1) << 97)); // a quarter
        _buy(keyB, address(stock), 300, trader, address(0));
        _buy(keyB, address(stock), 300, trader2, address(0));
        uint256 w2 = emissions.ledgerWeekOf(2);
        uint256 a = ledger.credit(w2, address(stock), trader).paid;
        uint256 b = ledger.credit(w2, address(stock), trader2).paid;
        assertTrue(a < 4 && b < 4 && a + b >= 4, "worth nothing apiece, something together");
        _closeWeek(2);
        emissions.settle(2);
        assertEq(emissions.priceOf(2, address(stock)), uint256(1) << 126, "a quarter");
        FeastEmissions.Week memory w = emissions.weekInfo(2);
        assertEq(w.value[1], (a + b) / 4, "the track's value, floored once");
        assertLe(emissions.owed(2, trader) + emissions.owed(2, trader2), w.pot[1], "never more than the pot");
    }

    /// @dev Once the platform coin has arrived, the contract holds exactly what
    ///      it has not emitted plus what it still owes.
    function _books(string memory when) internal view {
        assertEq(IERC20(feast).balanceOf(address(emissions)), emissions.remaining() + emissions.liabilities(), when);
    }

    /// Round 6 (L1): every exit retires exactly what it pays or burns — the
    /// balance, counted independently, equals what is left plus what is owed
    /// after a claim, a released redirect and an expired burn. Kills: an exit
    /// that moves tokens without retiring its liability.
    function test_everyExitRetiresExactlyWhatItPaysOrBurns() public {
        _closeWeek(1);
        emissions.settle(1);
        vm.prank(address(timelock));
        emissions.setRedirect(5_000, address(0xE5C0)); // from week 3
        _buy(keyA, address(wbnb), 100e18, trader, referrer);
        _launch(1e18);
        _firstPlatformTrade(); // during week 3's opening hours
        _closeWeek(2);
        emissions.settle(2);
        _buy(keyA, address(wbnb), 100e18, trader, referrer);
        _closeWeek(3);
        emissions.settle(3);
        _books("settled, funded at genesis");

        assertGt(emissions.claim(1, trader), 0);
        _books("after a claim");
        emissions.releaseRedirect(3);
        _books("after a redirect is released");
        _warpTo(emissions.expiryOf(2) + 1);
        emissions.burnExpired(2);
        _books("after an expired week burns");
    }

    // --- the three levers, through the real timelock --------------------------

    function _viaTimelock(bytes memory data) internal {
        vm.prank(multisig);
        timelock.schedule(address(emissions), 0, data, bytes32(0), bytes32(0), FeastGenesis.TIMELOCK_DELAY);
        _advance(FeastGenesis.TIMELOCK_DELAY);
        vm.prank(address(0xE1EC)); // anyone may execute a matured operation
        timelock.execute(address(emissions), 0, data, bytes32(0), bytes32(0));
    }

    function test_onlyTheTimelockPullsALever() public {
        vm.expectRevert(FeastEmissions.NotTimelock.selector);
        emissions.setValueRatioBps(1_000);
        vm.expectRevert(FeastEmissions.NotTimelock.selector);
        emissions.setRedirect(1_000, address(0xE5C0));
        vm.expectRevert(FeastEmissions.NotTimelock.selector);
        emissions.setPricer(address(pricer));
    }

    /// Q27: the multisig proposes, anyone executes after three days, and the
    /// timelock has no admin but itself.
    function test_theTimelockIsWiredAsRuled() public {
        assertTrue(timelock.hasRole(timelock.PROPOSER_ROLE(), multisig), "the multisig proposes");
        assertFalse(timelock.hasRole(timelock.PROPOSER_ROLE(), address(this)), "nobody else");
        assertTrue(timelock.hasRole(timelock.EXECUTOR_ROLE(), address(0)), "anyone executes");
        assertFalse(timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), multisig), "the multisig is no admin");
        assertTrue(timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), address(timelock)), "its only admin is itself");
        assertEq(timelock.getMinDelay(), 3 days, "three days");
        _viaTimelock(abi.encodeCall(FeastEmissions.setValueRatioBps, (1_000)));
        assertEq(emissions.valueRatioAt(ledger.currentWeek() + 1), 1_000, "a matured proposal took effect");
    }

    /// The bands are properties of the contract being changed, so even the
    /// timelock cannot leave them. Kills: a widened band.
    function test_theBandsHoldAtTheCallee() public {
        vm.startPrank(address(timelock));
        vm.expectRevert(abi.encodeWithSelector(FeastEmissions.RatioOutOfBand.selector, 499));
        emissions.setValueRatioBps(499);
        vm.expectRevert(abi.encodeWithSelector(FeastEmissions.RatioOutOfBand.selector, 2_001));
        emissions.setValueRatioBps(2_001);
        emissions.setValueRatioBps(500);
        emissions.setValueRatioBps(2_000);
        vm.expectRevert(abi.encodeWithSelector(FeastEmissions.RedirectOutOfBand.selector, 5_001, address(0xE5C0)));
        emissions.setRedirect(5_001, address(0xE5C0));
        vm.expectRevert(abi.encodeWithSelector(FeastEmissions.RedirectOutOfBand.selector, 1_000, address(0)));
        emissions.setRedirect(1_000, address(0));
        vm.expectRevert(abi.encodeWithSelector(FeastEmissions.PricerHasNoCode.selector, address(0xDEAD1)));
        emissions.setPricer(address(0xDEAD1));
        vm.stopPrank();
    }

    /// A lever takes effect from the next ledger week, so the week being earned
    /// keeps the rules it began with.
    function test_aLeverTakesEffectFromTheNextLedgerWeek() public {
        uint256 now_ = ledger.currentWeek();
        vm.prank(address(timelock));
        emissions.setValueRatioBps(700);
        assertEq(emissions.valueRatioAt(now_), FeastGenesis.DEFAULT_VALUE_RATIO_BPS, "this week unchanged");
        assertEq(emissions.valueRatioAt(now_ + 1), 700, "from the next");
    }

    /// Q26 (a): a redirect sends a share of each NEW week's emission to the
    /// escrow; a week already settled is never touched.
    function test_aRedirectTakesAShareOfNewWeeksAndNeverASettledOne() public {
        _closeWeek(1);
        emissions.settle(1);
        FeastEmissions.Week memory before = emissions.weekInfo(1);

        // Set during week 2, so it applies from week 3: week 2 keeps its rules.
        vm.prank(address(timelock));
        emissions.setRedirect(5_000, address(0xE5C0));
        _buy(keyA, address(wbnb), 100e18, trader, referrer);
        _launch(1e18);
        _firstPlatformTrade(); // the platform coin launches during week 3's opening hours
        _closeWeek(2);
        emissions.settle(2);
        assertEq(emissions.weekInfo(2).redirected, 0, "the week being earned is not redirected");

        _buy(keyA, address(wbnb), 100e18, trader, referrer);
        _closeWeek(3);
        emissions.settle(3);
        FeastEmissions.Week memory w3 = emissions.weekInfo(3);
        uint256 pots = w3.pot[0] + w3.pot[1] + w3.pot[2];
        assertGt(w3.redirected, 0, "week 3 is redirected");
        assertApproxEqAbs(w3.redirected, pots, 3, "half of what week 3 emits");
        assertEq(w3.escrow, address(0xE5C0), "to the escrow");
        FeastEmissions.Week memory after_ = emissions.weekInfo(1);
        assertEq(after_.pot[1], before.pot[1], "week 1 untouched");
        assertEq(after_.redirected, 0, "week 1 redirected nothing");

        emissions.releaseRedirect(3);
        assertEq(IERC20(feast).balanceOf(address(0xE5C0)), w3.redirected, "released to the escrow");
        vm.expectRevert(abi.encodeWithSelector(FeastEmissions.AlreadyDone.selector, 3));
        emissions.releaseRedirect(3);
    }

    /// Round 4 M1: the redirect is a share of what a week actually emits. In a
    /// week where only traders earned, only the trader track emits, and the
    /// escrow takes the redirect's share of that and no more. Kills: taking
    /// the share of the cap before empty tracks are skipped (69% to the escrow
    /// at a 50% redirect).
    function test_aRedirectIsAShareOfWhatTheWeekActuallyEmits() public {
        _closeWeek(1);
        emissions.settle(1);
        vm.prank(address(timelock));
        emissions.setRedirect(5_000, address(0xE5C0)); // set in week 2, so from week 3
        // A coin whose creator is the burn address: its fees have no creator track.
        FeastFactory.CreateParams memory cp = FeastFactory.CreateParams({
            name: "Coin",
            symbol: "COIN",
            supply: 1_000_000_000e18,
            quote: address(wbnb),
            creator: FeastConstants.BURN_ADDRESS,
            selfBurnBps: 2_000,
            referrerBps: 1_000,
            prebuyQuoteIn: 0,
            minCoinsOut: 0,
            vestingDuration: 0,
            sqrtPriceX96: SQRT_PRICE_1_1,
            startTick: 0,
            liquidity: uint128(1_000_000_000e18 * 999 / 1_000),
            salt: bytes32(uint256(3)),
            metadataHash: bytes32(0)
        });
        (, PoolKey memory keyC) = factory.create(cp);
        vm.roll(vm.getBlockNumber() + FeastConstants.CAP_BLOCKS);
        _closeWeek(2);
        emissions.settle(2);

        _buy(keyC, address(wbnb), 100e18, trader, address(0)); // unreferred: traders only
        _closeWeek(3);
        emissions.settle(3);
        FeastEmissions.Week memory w = emissions.weekInfo(3);
        assertEq(w.pot[0] + w.pot[2], 0, "no referrer, no creator: those tracks emit nothing");
        assertGt(w.pot[1], 0, "traders earn");
        uint256 emitted = w.pot[1] + w.redirected;
        assertLe(w.redirected * 2, emitted, "the escrow takes at most half of what the week emits");
        assertApproxEqAbs(w.redirected, w.pot[1], 1, "and half, to the unit");
        assertEq(emissions.budget() - emissions.remaining(), emissions.liabilities(), "every token emitted is owed");
    }

    /// Q26 (b): a new pricer prices the next settlement; a settled week keeps
    /// the prices it was settled at.
    function test_aNewPricerPricesTheNextSettlement() public {
        _closeWeek(1);
        emissions.settle(1);
        uint256 settledPrice = emissions.priceOf(1, address(stock));
        FeastPricer.Route[] memory none = new FeastPricer.Route[](0);
        FeastPricer p2 = new FeastPricer(address(wbnb), address(oracle), address(pm), feast, feastPoolId, none);
        vm.prank(address(timelock));
        emissions.setPricer(address(p2));
        _buy(keyB, address(stock), 10e18, trader2, address(0));
        _closeWeek(2);
        emissions.settle(2);
        assertEq(emissions.priceOf(2, address(stock)), 0, "the new pricer does not list the stock");
        assertEq(emissions.priceOf(1, address(stock)), settledPrice, "week 1 keeps its price");
    }

    // --- v1.6.3 F2: a settled week's quote list is settled too ----------------

    /// `CA-7e9b1e15be`. Settlement snapshots the quote list it priced, and the
    /// owed/claim path makes no external call at all — so a module that goes
    /// dark after it has settled a week changes nothing about that week. Before
    /// v1.6.3 `_priced` re-read the list from the module on every `owed`, every
    /// `claim` and every genesis grant.
    ///
    /// Kills: reading the list live at claim time.
    function test_aPricerThatRevertsAfterSettlementChangesNoEntitlement() public {
        DarkeningPricer dp = new DarkeningPricer(pricer);
        vm.prank(address(timelock));
        emissions.setPricer(address(dp));

        _closeWeek(1);
        emissions.settle(1);
        _launch(1e18);

        uint256 owedBefore = emissions.owed(1, trader);
        uint256 referredBefore = emissions.referredValue(1, referrer);
        assertGt(owedBefore, 0, "the trader has a settled entitlement to protect");

        // The module goes dark. No call is made to emissions or to the timelock.
        dp.goDark();
        vm.expectRevert(DarkeningPricer.TheModuleIsDark.selector);
        dp.quotes();

        assertEq(emissions.owed(1, trader), owedBefore, "a dark module changes no settled entitlement");
        assertEq(emissions.referredValue(1, referrer), referredBefore, "nor what the genesis grants count");
        assertEq(emissions.claim(1, trader), owedBefore, "and the claim pays exactly it");
    }

    /// A duplicate present AT settlement is counted ONCE, not refused. Refusing
    /// would brick settlement for good — it runs strictly in order, so week `n`
    /// reverting blocks every week after it, and the only way out would be the
    /// same lever under suspicion. Counting once keeps the two halves of a
    /// claim's fraction consistent: the denominator `value[t]` accumulates per
    /// distinct quote, and `_priced` iterates that same distinct list.
    ///
    /// Kills: pushing a quote to the snapshot twice; accumulating `value[t]`
    /// twice; reverting on a duplicate.
    function test_aDuplicateQuoteAtSettlementIsCountedOnce() public {
        DuplicatingPricer dp = new DuplicatingPricer(pricer);
        vm.prank(address(timelock));
        emissions.setPricer(address(dp));
        assertEq(dp.quotes().length, pricer.quotes().length * 2, "the module really does list each quote twice");

        _closeWeek(1);
        emissions.settle(1); // not refused

        address[] memory snapshot = emissions.settledQuotes(1);
        for (uint256 i = 0; i < snapshot.length; i++) {
            for (uint256 j = 0; j < i; j++) {
                assertTrue(snapshot[i] != snapshot[j], "no quote appears twice in the snapshot");
            }
        }

        // The denominator is the single count, quote by quote, from the ledger.
        uint256 w1 = emissions.ledgerWeekOf(1);
        address[] memory honest = pricer.quotes();
        uint256[3] memory value;
        uint256 priced;
        for (uint256 i = 0; i < honest.length; i++) {
            uint256 price = emissions.priceOf(1, honest[i]);
            if (price == 0) continue;
            priced++;
            FeastFeeLedger.Credit memory t = ledger.totals(w1, honest[i]);
            value[0] += t.referred * price >> 128;
            value[1] += t.paid * price >> 128;
            value[2] += t.earned * price >> 128;
        }
        assertEq(snapshot.length, priced, "the snapshot is exactly the quotes this week priced, once each");
        FeastEmissions.Week memory w = emissions.weekInfo(1);
        for (uint256 t = 0; t < 3; t++) {
            assertEq(w.value[t], value[t], "each track's value counts each quote once");
        }

        // And the numerators agree with it: the pots are never oversubscribed.
        _launch(1e18);
        uint256 sum = emissions.owed(1, trader) + emissions.owed(1, trader2) + emissions.owed(1, referrer)
            + emissions.owed(1, creator);
        assertGt(sum, 0, "somebody is owed something");
        assertLe(sum, w.pot[0] + w.pot[1] + w.pot[2], "and the sum of entitlements agrees with the pots");
    }

    // --- the ends of things ------------------------------------------------------

    function test_anUnclaimedWeekBurnsAfterItsGrace() public {
        _closeWeek(1);
        emissions.settle(1);
        _launch(1e18);
        vm.expectRevert(abi.encodeWithSelector(FeastEmissions.NotExpired.selector, 1));
        emissions.burnExpired(1);
        emissions.claim(1, trader);
        _warpTo(emissions.expiryOf(1) + 1);
        vm.expectRevert(abi.encodeWithSelector(FeastEmissions.Expired.selector, 1));
        emissions.claim(1, trader2);
        FeastEmissions.Week memory w = emissions.weekInfo(1);
        uint256 supplyBefore = IERC20(feast).totalSupply();
        emissions.burnExpired(1);
        assertEq(supplyBefore - IERC20(feast).totalSupply(), w.pot[0] + w.pot[1] + w.pot[2] - w.claimed, "the unclaimed rest burns");
    }

    /// A pre-launch week cannot expire before anyone could claim it.
    function test_aPreLaunchWeekExpiresTwelveWeeksAfterClaimsOpen() public {
        _closeWeek(1);
        emissions.settle(1);
        assertEq(emissions.expiryOf(1), type(uint256).max, "no expiry while claims are closed");
        _launch(1e18);
        assertEq(emissions.expiryOf(1), window.endsAt() + FeastGenesis.SETTLE_GRACE + 12 weeks, "twelve weeks from the opening");
    }

    function test_afterWeekFiftyTwoWhatNobodyIsOwedBurns() public {
        _launch(1e18);
        _firstPlatformTrade();
        for (uint256 n = 1; n <= 52; n++) {
            _closeWeek(n);
            if (n > emissions.settledCount()) emissions.settle(n);
        }
        uint256 held = IERC20(feast).balanceOf(address(emissions));
        uint256 owedTotal = emissions.liabilities();
        emissions.burnRemainder();
        assertEq(IERC20(feast).balanceOf(address(emissions)), owedTotal, "only what is owed remains");
        assertGt(held, owedTotal, "and the rest was burned");
    }
}
