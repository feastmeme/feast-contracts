// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm, VmSafe} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {FeastConstants} from "../src/FeastConstants.sol";
import {FeastEmissions} from "../src/FeastEmissions.sol";
import {FeastGenesis} from "../src/FeastGenesis.sol";
import {FeastGenesisGrants} from "../src/FeastGenesisGrants.sol";
import {FeastHook} from "../src/FeastHook.sol";
import {FeastLaunchWindow} from "../src/FeastLaunchWindow.sol";
import {FeastPlatformSink} from "../src/FeastPlatformSink.sol";
import {FeastPlatformToken} from "../src/FeastPlatformToken.sol";
import {FeastPricer} from "../src/FeastPricer.sol";
import {FeastTeamVesting} from "../src/FeastTeamVesting.sol";
import {PoolKey} from "../src/venue/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "../src/venue/PoolId.sol";

import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {Vault} from "infinity-core/src/Vault.sol";
import {CustomRevert} from "infinity-core/src/libraries/CustomRevert.sol";
import {CLPool} from "infinity-core/src/pool-cl/libraries/CLPool.sol";
import {Hooks} from "infinity-core/src/libraries/Hooks.sol";
import {IFeastCLHooks} from "../src/venue/IFeastCLHooks.sol";

import {Genesis} from "../script/Genesis.s.sol";

import {MockERC20} from "./utils/MockERC20.sol";
import {MockV3Pool} from "./utils/MockV3Pool.sol";
import {RingV3Pool} from "./utils/RingV3Pool.sol";
import {UnitFixture} from "./utils/UnitFixture.sol";
import {VenueBridge} from "./utils/VenueBridge.sol";

/// The pricer: what a quote is worth in wrapped native, and when it refuses to
/// say. It never reverts on a price it cannot vouch for; it reports why.
contract FeastPricerTest is UnitFixture {
    uint256 internal constant ONE = 1 << 128;

    function test_wrappedNativeIsWorthOne() public view {
        (FeastPricer.Status s, uint256 p) = pricer.priceQ128(address(wbnb));
        assertEq(uint8(s), uint8(FeastPricer.Status.Ok));
        assertEq(p, ONE, "one");
    }

    /// Kills: an inverted hop.
    function test_aHopIsPricedFromTheSpotSquareRootPriceInTheRightDirection() public {
        // Four: the stock is worth two, or a half, depending on its side.
        stockPool.setSqrtPrice(uint160(2 * 0x1000000000000000000000000));
        (FeastPricer.Status s, uint256 p) = pricer.priceQ128(address(stock));
        assertEq(uint8(s), uint8(FeastPricer.Status.Ok));
        bool stockIs0 = stockPool.token0() == address(stock);
        assertEq(p, stockIs0 ? 4 * ONE : ONE / 4, "token1 per token0 is the square of the square-root price");
    }

    function test_aPoolThatCannotVouchIsUnpriceableNotReverted() public {
        stockPool.setCardinality(1);
        (FeastPricer.Status s, uint256 p) = pricer.priceQ128(address(stock));
        assertEq(uint8(s), uint8(FeastPricer.Status.Unpriceable), "one observation is no average");
        assertEq(p, 0);
        // A ring the pricer reads (v1.6.25: at least `MIN_RING_CARDINALITY`),
        // so what refuses below is the history and nothing else.
        stockPool.setCardinality(FeastConstants.MIN_RING_CARDINALITY);
        stockPool.setOldestTimestamp(uint32(block.timestamp - 10));
        (s,) = pricer.priceQ128(address(stock));
        assertEq(uint8(s), uint8(FeastPricer.Status.Unpriceable), "ten seconds of history is not enough");
    }

    /// v1.6.27 (`CA-0d9ade0259`): **a pool is read over the whole window or
    /// not at all.** History short of `TWAP_WINDOW` is `Unpriceable` to the
    /// second, however deep the ring; until v1.6.27 anything from
    /// `MIN_OBSERVATION_AGE` up was averaged over the history it had. Kills:
    /// the old floor; a floor one second either side of the window.
    function test_aPoolIsReadOverTheWholeWindowOrNotAtAll() public {
        stockPool.setOldestTimestamp(uint32(block.timestamp - FeastConstants.MIN_OBSERVATION_AGE));
        (FeastPricer.Status s,) = pricer.priceQ128(address(stock));
        assertEq(uint8(s), uint8(FeastPricer.Status.Unpriceable), "five minutes of history is half a window");
        stockPool.setOldestTimestamp(uint32(block.timestamp - (FeastConstants.TWAP_WINDOW - 1)));
        (s,) = pricer.priceQ128(address(stock));
        assertEq(uint8(s), uint8(FeastPricer.Status.Unpriceable), "a second short of the window is short");
        stockPool.setOldestTimestamp(uint32(block.timestamp - FeastConstants.TWAP_WINDOW));
        (s,) = pricer.priceQ128(address(stock));
        assertEq(uint8(s), uint8(FeastPricer.Status.Ok), "the whole window is a price");
    }

    /// v1.6.27 (`CA-0d9ade0259`): **a ring that has just grown is deep and not
    /// full.** Widened to `MIN_RING_CARDINALITY` and grown by its next write,
    /// its new slots are empty and its oldest observation is slot 0, so its
    /// history is the time since that write. The pricer waits until that is a
    /// whole window, then reads it over exactly the window. The audit PoC
    /// `test/audit/poc/PricerWarmupShortensTheWindow.t.sol` is the 301-second
    /// instant of this walk.
    function test_aRingThatHasJustGrownIsReadOnlyOnceItsHistoryCoversTheWindow() public {
        RingV3Pool ring = new RingV3Pool(address(stock), address(wbnb), SQRT_PRICE_1_1, 0);
        ring.increaseObservationCardinalityNext(FeastConstants.MIN_RING_CARDINALITY);
        _advance(1);
        ring.poke(); // reaches the end of the ring of one: it grows to 601
        (,,, uint16 cardinality,,,) = ring.slot0();
        assertEq(cardinality, FeastConstants.MIN_RING_CARDINALITY, "precondition: the live ring is the minimum");
        uint256 oldest = block.timestamp - ring.oldestAge(); // slot 0's write

        FeastPricer.Route[] memory r = new FeastPricer.Route[](1);
        r[0].quote = address(stock);
        r[0].pools = new address[](1);
        r[0].pools[0] = address(ring);
        FeastPricer p = new FeastPricer(address(wbnb), address(oracle), address(pm), feast, feastPoolId, r);

        _warpTo(oldest + FeastConstants.MIN_OBSERVATION_AGE + 1);
        (FeastPricer.Status s,) = p.priceQ128(address(stock));
        assertEq(uint8(s), uint8(FeastPricer.Status.Unpriceable), "301 seconds of history is not the window");
        _warpTo(oldest + FeastConstants.TWAP_WINDOW - 1);
        assertEq(ring.oldestAge(), FeastConstants.TWAP_WINDOW - 1, "precondition: one second short");
        (s,) = p.priceQ128(address(stock));
        assertEq(uint8(s), uint8(FeastPricer.Status.Unpriceable), "nor is 599");
        _warpTo(oldest + FeastConstants.TWAP_WINDOW);
        assertEq(ring.oldestAge(), FeastConstants.TWAP_WINDOW, "precondition: the history is the window");
        (s,) = p.priceQ128(address(stock));
        assertEq(uint8(s), uint8(FeastPricer.Status.Ok), "the window, read over the window");
    }

    function test_aMovedSpotIsReportedAsMoved() public {
        stockPool.setTicks(0, 301);
        (FeastPricer.Status s,) = pricer.priceQ128(address(stock));
        assertEq(uint8(s), uint8(FeastPricer.Status.Moved), "spot pushed past the bound");
        stockPool.setTicks(0, 300);
        (s,) = pricer.priceQ128(address(stock));
        assertEq(uint8(s), uint8(FeastPricer.Status.Ok), "at the bound it answers");
    }

    /// Round 4 L2: two hops, each representable (2^208 in 128.128), whose
    /// product (2^288) is not. Unpriceable, not a revert; and a product that
    /// fits is still priced exactly. Kills: an unguarded composition; refusing
    /// every two-hop route.
    function test_aRoutePriceTooLargeToHoldIsUnpriceableNotReverted() public {
        (FeastPricer tall, address quote) = _twoHopPricer(uint160(1 << 136));
        (FeastPricer.Status s, uint256 p) = tall.priceQ128(quote);
        assertEq(uint8(s), uint8(FeastPricer.Status.Unpriceable), "a price no word can hold");
        assertEq(p, 0);

        (FeastPricer fits, address q2) = _twoHopPricer(uint160(1 << 100));
        (s, p) = fits.priceQ128(q2);
        assertEq(uint8(s), uint8(FeastPricer.Status.Ok), "a product that fits is a price");
        assertEq(p, uint256(1) << 144, "2^136 twice, in 128.128: 2^144");
    }

    /// Round 4 L1: every quote the protocol prices is an 18-decimal token (the
    /// census of the planned list at the pinned block found no other), so the
    /// pricer refuses any other at construction. The factory stays open (Q2).
    /// Kills: listing a six-decimal quote.
    function test_aPricedQuoteMustHaveEighteenDecimals() public {
        MockERC20 six = new MockERC20("Six", "SIX", 6);
        MockV3Pool p6 = new MockV3Pool(address(six), address(wbnb));
        FeastPricer.Route[] memory r = new FeastPricer.Route[](1);
        r[0].quote = address(six);
        r[0].pools = new address[](1);
        r[0].pools[0] = address(p6);
        vm.expectRevert(abi.encodeWithSelector(FeastPricer.QuoteNotEighteenDecimals.selector, address(six)));
        new FeastPricer(address(wbnb), address(oracle), address(pm), feast, feastPoolId, r);

        MockERC20 eighteen = new MockERC20("Eighteen", "E18", 18);
        r[0].quote = address(eighteen);
        r[0].pools[0] = address(new MockV3Pool(address(eighteen), address(wbnb)));
        new FeastPricer(address(wbnb), address(oracle), address(pm), feast, feastPoolId, r);
    }

    /// v1.6.1 (CA-e2ba62d849): the same truncated-timestamp arithmetic reads a
    /// route pool's history here. Past the rollover it must still answer rather
    /// than revert, or a week could never be settled again.
    function test_aRoutePoolIsStillPriceableAcrossTheTwentyOneOhSixRollover() public {
        uint256 rollover = uint256(type(uint32).max) + 1;
        stockPool.setOldestTimestamp(uint32(rollover - 3_600));
        vm.warp(rollover + 600);
        (FeastPricer.Status s, uint256 price) = pricer.priceQ128(address(stock));
        assertEq(uint8(s), uint8(FeastPricer.Status.Ok), "still priced across the rollover");
        assertGt(price, 0);
    }

    function test_anUnlistedQuoteIsUnpriceable() public view {
        (FeastPricer.Status s,) = pricer.priceQ128(address(0xBAD));
        assertEq(uint8(s), uint8(FeastPricer.Status.Unpriceable));
    }

    function test_aRouteMustConnectAndEndInWrappedNative() public {
        MockERC20 other = new MockERC20("Other", "O", 18);
        MockV3Pool wrong = new MockV3Pool(address(other), address(stock));
        FeastPricer.Route[] memory r = new FeastPricer.Route[](1);
        r[0].quote = address(stock);
        r[0].pools = new address[](1);
        r[0].pools[0] = address(wrong);
        vm.expectRevert(abi.encodeWithSelector(FeastPricer.RouteDoesNotEndInNative.selector, address(stock)));
        new FeastPricer(address(wbnb), address(oracle), address(pm), feast, feastPoolId, r);
        r[0].quote = address(0xBAD);
        vm.expectRevert(abi.encodeWithSelector(FeastPricer.RouteDoesNotConnect.selector, address(0xBAD), address(wrong)));
        new FeastPricer(address(wbnb), address(oracle), address(pm), feast, feastPoolId, r);
    }

    /// Before genesis the platform coin has no pool: the first-week rule.
    function test_thePlatformCoinIsUnpriceableUntilItHasHistory() public {
        (FeastPricer.Status s,) = pricer.platformPerNativeQ128();
        assertEq(uint8(s), uint8(FeastPricer.Status.Unpriceable), "no pool yet");
        _launch(10e18);
        // v1.6.11: settling is an auction, not a swap, so it writes no oracle
        // observation. The pool now has a price and no HISTORY, and the pricer
        // says so — which is the honest answer, because nothing has traded.
        (s,) = pricer.platformPerNativeQ128();
        assertEq(uint8(s), uint8(FeastPricer.Status.Unpriceable), "opened, but nothing has traded");
        _firstPlatformTrade();
        (s,) = pricer.platformPerNativeQ128();
        assertEq(uint8(s), uint8(FeastPricer.Status.Ok), "a price once the pool has traded and aged");
    }
}

/// The genesis partners' grants.
contract FeastGenesisGrantsTest is UnitFixture {
    using VenueBridge for PoolKey;

    PoolKey internal keyA;

    function setUp() public override {
        super.setUp();
        (, keyA) = _create(address(wbnb), bytes32(uint256(1)));
    }

    function _week(uint256 n) internal {
        uint256 end = ledger.weekStart(emissions.ledgerWeekOf(n) + 1);
        if (clock < end) _warpTo(end);
        emissions.settle(n);
    }

    /// @dev A grants contract with `n` of its eight slots named, so the
    ///      assignment tests are about slots rather than about the fixture's own
    ///      eight. It is wired to the same emissions and the same guardian, so
    ///      the deadline and the key are the real ones.
    function _grantsWithEmptySlots(uint256 named) internal returns (FeastGenesisGrants g) {
        // v1.6.13: the assignment window starts at GENESIS, not at the
        // guardian's deploy, so these tests need one. Before genesis the window
        // is not open and neither `assignPartner` nor `burnUnfilledSlot` may act
        // — the safe direction, and its own test in FeastGuardian.t.sol.
        if (!guardian.clockStarted()) _genesis();
        address[8] memory some;
        for (uint256 i = 0; i < named; i++) some[i] = partnerList[i];
        g = new FeastGenesisGrants(feast, address(emissions), TARGET, some, address(guardian));
    }

    // --- v1.6.12: an empty slot may be filled once, within 90 days ------------

    /// The owner's problem: before v1.6.12 eight partners had to exist before
    /// genesis or their slots burned. A slot left empty can now be filled — once,
    /// by the team multisig, inside the guardian's own 90-day window.
    function test_theTeamMultisigMayFillAnEmptySlotOnce() public {
        FeastGenesisGrants g = _grantsWithEmptySlots(6);
        address late = address(0x1A7E);

        assertEq(g.partners()[6], address(0), "the slot starts empty");
        assertFalse(g.isPartner(late), "and nobody holds it");

        vm.prank(multisig);
        g.assignPartner(6, late);

        assertEq(g.partners()[6], late, "filled");
        assertTrue(g.isPartner(late), "and they are a partner now");
        assertEq(g.assignedAt(late), uint64(block.timestamp), "with the instant recorded");

        // The key and the deadline are the guardian's own, not a second copy.
        assertEq(guardian.guardian(), multisig, "one key");
        assertEq(g.partners()[0], partnerList[0], "and the genesis-named slots are untouched");
    }

    function test_aStrangerCannotFillASlot() public {
        FeastGenesisGrants g = _grantsWithEmptySlots(6);
        address stranger = address(0x5174A9E);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(FeastGenesisGrants.NotTheTeamMultisig.selector, stranger));
        g.assignPartner(6, address(0x1A7E));

        // Not even a partner, and not the guardian contract itself.
        vm.prank(partnerList[0]);
        vm.expectRevert(abi.encodeWithSelector(FeastGenesisGrants.NotTheTeamMultisig.selector, partnerList[0]));
        g.assignPartner(6, address(0x1A7E));
    }

    /// **Filled is immutable**, whichever way it was filled. The multisig cannot
    /// replace, remove or reassign anybody — which is the whole difference
    /// between filling a blank and holding a key to the grants.
    function test_aFilledSlotIsImmutable() public {
        FeastGenesisGrants g = _grantsWithEmptySlots(6);

        // Filled at genesis.
        vm.prank(multisig);
        vm.expectRevert(
            abi.encodeWithSelector(FeastGenesisGrants.SlotAlreadyFilled.selector, uint8(0), partnerList[0])
        );
        g.assignPartner(0, address(0x1A7E));

        // Filled since.
        address late = address(0x1A7E);
        vm.prank(multisig);
        g.assignPartner(6, late);
        vm.prank(multisig);
        vm.expectRevert(abi.encodeWithSelector(FeastGenesisGrants.SlotAlreadyFilled.selector, uint8(6), late));
        g.assignPartner(6, address(0x2A7E));

        // And an address cannot hold two slots.
        vm.prank(multisig);
        vm.expectRevert(abi.encodeWithSelector(FeastGenesisGrants.PartnerMisconfigured.selector, late));
        g.assignPartner(7, late);
    }

    function test_afterDayNinetyNoSlotCanBeFilled() public {
        FeastGenesisGrants g = _grantsWithEmptySlots(6);
        uint64 until = guardian.sunsetAt();

        _warpTo(until);
        vm.prank(multisig);
        g.assignPartner(6, address(0x1A7E)); // the last second is still inside

        _warpTo(until + 1);
        vm.expectRevert(abi.encodeWithSelector(FeastGenesisGrants.AssignmentWindowClosed.selector, until));
        vm.prank(multisig);
        g.assignPartner(7, address(0x2A7E));
    }

    /// **A late partner gets a late start, not a backdated one.** The address in
    /// an assigned slot may have been referring fees all along as an ordinary
    /// referrer; weeks that had already CLOSED when the slot was filled count
    /// zero. The six-month clock runs from genesis and is not restarted.
    function test_anAssignedPartnerEarnsFromReferralsMadeAfterAssignment() public {
        address late = address(0x1A7E);

        // A launched, traded platform coin first, so settlement can price the
        // week. THEN `late` refers fees as an ordinary referrer, and that week
        // is closed and settled before anybody names them.
        _launch(10e18);
        _firstPlatformTrade();
        FeastGenesisGrants g = _grantsWithEmptySlots(6);
        _buy(keyA, address(wbnb), 1_000e18, trader, late);

        // Close the week the buy landed in, then settle everything up to it.
        _warpTo(ledger.weekStart(ledger.currentWeek() + 1));
        uint256 n = emissions.settledCount() + 1;
        while (emissions.ledgerWeekOf(n) < ledger.currentWeek()) {
            _week(n);
            n++;
        }
        // Find the settled week that actually carries their referrals rather
        // than assuming it is the last one.
        uint256 before_;
        for (uint256 i = 1; i <= emissions.settledCount(); i++) {
            if (emissions.referredValue(i, late) > 0) {
                before_ = i;
                break;
            }
        }
        assertGt(before_, 0, "some settled week carries them");
        // **The witness has to reach its bound.** Asserting "zero" proves
        // nothing unless the week ACTUALLY HAS referred value to refuse. An
        // earlier draft of this test settled a week the buy had never reached,
        // so it asserted zero against zero and the mutation that counts closed
        // weeks walked straight past it.
        assertGt(emissions.referredValue(before_, late), 0, "the closed week really did carry their referrals");

        // Now they are given the slot.
        vm.prank(multisig);
        g.assignPartner(6, late);

        g.checkpoint(late, before_);
        assertEq(g.referredNative(late), 0, "the closed week before the assignment counts nothing");
        assertEq(g.unlocked(late), 0, "so nothing unlocked from it");

        // And the weeks after it count in full.
        _buy(keyA, address(wbnb), 1_000e18, trader2, late);
        uint256 after_ = before_ + 1;
        _week(after_);
        g.checkpoint(late, after_);
        assertGt(g.referredNative(late), 0, "the weeks after the assignment count in full");
        assertGt(g.unlocked(late), 0, "which unlocks the grant the ordinary way");

        // The earlier week stays counted at zero for ever.
        g.checkpoint(late, before_);
        uint256 held = g.referredNative(late);
        g.checkpoint(late, before_);
        assertEq(g.referredNative(late), held, "and it can never be picked up later");
    }

    /// A slot nobody filled burns once the window to fill it has closed.
    ///
    /// @dev **This needed a new entry point and the commit says why**:
    ///      `burnUnearned` takes a partner ADDRESS and an empty slot has none,
    ///      so without something that addresses the SLOT the grant would sit
    ///      here for ever (I14).
    function test_anUnfilledSlotBurnsAtTheDeadline() public {
        // Genesis first, then the standalone contract is funded the way genesis
        // funds the real one — eight grants — out of the real one's own holding.
        // A burn needs tokens to burn, and a test that burned from an empty
        // contract would prove nothing about the rule.
        _genesis();
        FeastGenesisGrants g = _grantsWithEmptySlots(6);
        uint256 endowment = g.grant() * 8;
        vm.prank(address(grants));
        IERC20(feast).transfer(address(g), endowment);

        uint64 until = guardian.sunsetAt();
        uint256 held = IERC20(feast).balanceOf(address(g));
        assertEq(held, endowment, "funded like the real one");

        // Not while it can still be filled.
        vm.expectRevert(abi.encodeWithSelector(FeastGenesisGrants.AssignmentWindowOpen.selector, until));
        g.burnUnfilledSlot(6);

        _warpTo(until + 1);
        g.burnUnfilledSlot(6);
        assertEq(IERC20(feast).balanceOf(address(g)), held - g.grant(), "the slot's grant is gone");
        assertTrue(g.slotBurned(6), "and recorded");

        // Once, and never for a slot somebody holds.
        vm.expectRevert(abi.encodeWithSelector(FeastGenesisGrants.SlotAlreadyBurned.selector, uint8(6)));
        g.burnUnfilledSlot(6);
        vm.expectRevert(
            abi.encodeWithSelector(FeastGenesisGrants.SlotIsFilled.selector, uint8(0), partnerList[0])
        );
        g.burnUnfilledSlot(0);
    }

    function test_eightDistinctPartnersAndATargetAreRequired() public {
        address[8] memory dup = partnerList;
        dup[3] = dup[2];
        vm.expectRevert(abi.encodeWithSelector(FeastGenesisGrants.PartnerMisconfigured.selector, dup[2]));
        new FeastGenesisGrants(feast, address(emissions), TARGET, dup, address(guardian));
        vm.expectRevert(FeastGenesisGrants.ZeroTarget.selector);
        new FeastGenesisGrants(feast, address(emissions), 0, partnerList, address(guardian));
    }

    /// unlocked = min(grant, grant × referred / TARGET), from the same ledger
    /// and prices as the referral pots. Kills: a second ledger; an uncapped
    /// unlock.
    function test_aGrantUnlocksByTheFeesItsPartnersLinksBring() public {
        address partner = partnerList[0];
        _buy(keyA, address(wbnb), 1_000e18, trader, partner); // 10 WBNB of fees referred
        _week(1);
        _launch(1e18);
        grants.checkpointAll(partner);
        uint256 referred = emissions.referredValue(1, partner);
        assertGt(referred, 0, "the partner referred fees");
        assertEq(grants.referredNative(partner), referred, "counted once, from the emissions ledger");
        uint256 expect = grants.grant() * referred / TARGET;
        assertEq(grants.unlocked(partner), expect, "pro rata to the target");
        grants.claim(partner);
        assertEq(IERC20(feast).balanceOf(partner), expect, "and paid to the partner");
        grants.checkpoint(partner, 1);
        assertEq(grants.referredNative(partner), referred, "a week is never counted twice");
    }

    /// Round 6 (L1): each unlocked unit is paid once. A repeated claim pays
    /// nothing while the other partners' grants are funded, and a later unlock
    /// pays only its increment. Kills: paying without recording it.
    function test_aRepeatedGrantClaimPaysOnlyWhatIsNew() public {
        address partner = partnerList[0];
        _buy(keyA, address(wbnb), 1_000e18, trader, partner);
        _week(1);
        _launch(1e18);
        _firstPlatformTrade();
        uint256 first = grants.claim(partner);
        assertGt(first, 0, "a first payment");
        assertEq(grants.claim(partner), 0, "nothing new, nothing paid");
        assertEq(IERC20(feast).balanceOf(partner), first, "the partner holds the first payment only");

        _buy(keyA, address(wbnb), 1_000e18, trader, partner); // more referrals, after launch
        uint256 target = ledger.currentWeek(); // the week those referrals fell in
        uint256 n = emissions.settledCount() + 1;
        while (emissions.ledgerWeekOf(n) <= target) _week(n++);
        uint256 second = grants.claim(partner);
        assertGt(second, 0, "the new unlock is paid");
        assertEq(first + second, grants.unlocked(partner), "and in all, exactly what has unlocked");
        assertEq(IERC20(feast).balanceOf(partner), grants.unlocked(partner));
    }

    function test_aGrantNeverUnlocksMoreThanItself() public {
        address partner = partnerList[1];
        _buy(keyA, address(wbnb), 100_000e18, trader, partner); // far past the target
        _week(1);
        _launch(1e18);
        grants.claim(partner);
        assertEq(IERC20(feast).balanceOf(partner), grants.grant(), "capped at the grant");
    }

    function test_nothingIsPaidOrBurnedBeforeClaimsOpen() public {
        vm.expectRevert(FeastGenesisGrants.ClaimsNotOpen.selector);
        grants.claim(partnerList[0]);
        vm.expectRevert(abi.encodeWithSelector(FeastGenesisGrants.NotAPartner.selector, trader));
        grants.claim(trader);
    }

    /// After the 26-week horizon the unearned part burns — and only then.
    function test_theUnearnedPartBurnsOnlyAfterTheHorizon() public {
        address partner = partnerList[2];
        _buy(keyA, address(wbnb), 1_000e18, trader, partner);
        _launch(1e18);
        _firstPlatformTrade();
        for (uint256 n = 1; n < 26; n++) _week(n);
        vm.expectRevert(FeastGenesisGrants.HorizonNotReached.selector);
        grants.burnUnearned(partner);
        _week(26);
        uint256 supply = IERC20(feast).totalSupply();
        grants.burnUnearned(partner);
        uint256 unearned = grants.grant() - grants.unlocked(partner);
        assertEq(supply - IERC20(feast).totalSupply(), unearned, "exactly the unearned part");
        vm.expectRevert(abi.encodeWithSelector(FeastGenesisGrants.AlreadyBurned.selector, partner));
        grants.burnUnearned(partner);
        grants.claim(partner);
        assertEq(IERC20(feast).balanceOf(partner), grants.unlocked(partner), "the earned part stays claimable");
    }
}

/// The 24-hour uniform-price launch window.
contract FeastLaunchWindowTest is UnitFixture {
    using PoolIdLibrary for PoolKey;
    using VenueBridge for PoolKey;

    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);

    function setUp() public override {
        super.setUp();
        _genesis();
        vm.deal(alice, 100e18);
        vm.deal(bob, 100e18);
    }

    function test_commitsOpenAtTheStartAndCloseAtTheEnd() public {
        vm.prank(alice);
        vm.expectRevert(FeastLaunchWindow.NotOpenForCommits.selector);
        window.commit{value: 1e18}();
        _warpTo(windowStart);
        vm.prank(alice);
        window.commit{value: 1e18}();
        _warpTo(window.endsAt());
        vm.prank(alice);
        vm.expectRevert(FeastLaunchWindow.NotOpenForCommits.selector);
        window.commit{value: 1e18}();
    }

    /// Ruling 3: withdrawable at any time except the last hour.
    function test_aCommitCanBeTakenBackUntilTheLastHour() public {
        _warpTo(windowStart);
        vm.prank(alice);
        window.commit{value: 5e18}();
        _warpTo(window.lockAt() - 1);
        vm.prank(alice);
        window.withdraw(2e18);
        assertEq(alice.balance, 97e18, "taken back in native");
        assertEq(window.committed(alice), 3e18, "the rest stays");
        _warpTo(window.lockAt());
        vm.prank(alice);
        vm.expectRevert(FeastLaunchWindow.NotOpenForWithdrawals.selector);
        window.withdraw(1e18);
    }

    /// One settlement, once, in the exclusive hour; everyone the same price;
    /// every unit paid. Kills: a second settlement; a dropped remainder.
    ///
    /// @dev The amounts are deliberately awkward. This test used to commit 3
    ///      and 1 of a pot of 4, and against v1.6.11's FIXED tranche of 3e26 —
    ///      which 4 divides exactly — there is no remainder left to drop, so
    ///      the mutation "drop the last claimant's remainder" walked straight
    ///      past it. Before the auction the claimable quantity was whatever a
    ///      swap happened to buy and had a remainder by accident. A round
    ///      number is what made the witness vacuous, and 3e18+1 wei against
    ///      1e18 is what un-rounds it.
    function test_theWholePotBuysOnceAndEveryoneGetsTheSamePrice() public {
        _warpTo(windowStart);
        vm.prank(alice);
        window.commit{value: 3e18 + 1}();
        vm.prank(bob);
        window.commit{value: 1e18}();
        vm.expectRevert(FeastLaunchWindow.CannotSettle.selector);
        window.settle();
        _warpTo(window.endsAt());
        window.settle();
        vm.expectRevert(FeastLaunchWindow.AlreadySettled.selector);
        window.settle();
        uint256 bought = window.tranche();
        assertGt(bought, 0, "the pot bought the platform coin");
        uint256 a = window.claim(alice);
        uint256 b = window.claim(bob);
        assertEq(a + b, bought, "every unit paid");
        // Cross-multiplied, so there is no division to round: each claim is
        // within one unit of coin of its share, which is `wa + wb` once the
        // two are multiplied out.
        uint256 wa = 3e18 + 1;
        uint256 wb = 1e18;
        assertApproxEqAbs(a * wb, b * wa, wa + wb, "the same commit ratio, the same coin ratio: one price");
        assertEq(IERC20(feast).balanceOf(address(window)), 0, "nothing strands in the window");
    }

    /// Before `openAt` nobody but the window trades the pool — the pot cannot
    /// be front-run. From v1.6.11 that holds in two layers, and this test walks
    /// both: before settlement the pool does not EXIST (genesis no longer
    /// initialises it, because the price it must open at is the auction's
    /// clearing price and nobody knows that until the window closes), so the
    /// venue refuses before the hook is ever consulted; after settlement the
    /// pool exists and holds the seed, and the hook's gate refuses instead.
    /// Kills: initialising at genesis; opening the gate at settlement.
    function test_nobodyElseTradesThePoolBeforeItOpens() public {
        wbnb.mint(address(router), 2e18);
        bool zeroForOne = address(wbnb) < feast;

        _warpTo(windowStart);
        vm.prank(alice);
        window.commit{value: 4e18}();
        _warpTo(window.endsAt());

        vm.expectRevert(CLPool.PoolNotInitialized.selector);
        router.swap(
            feastKey.up(),
            ICLPoolManager.SwapParams({zeroForOne: zeroForOne, amountSpecified: -1e15, sqrtPriceLimitX96: zeroForOne ? MIN_SQRT : MAX_SQRT}),
            ""
        );

        window.settle();

        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IFeastCLHooks.beforeSwap.selector,
                abi.encodeWithSelector(FeastHook.PoolNotOpenYet.selector, uint64(window.endsAt() + FeastGenesis.SETTLE_GRACE)),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        router.swap(
            feastKey.up(),
            ICLPoolManager.SwapParams({zeroForOne: zeroForOne, amountSpecified: -1e15, sqrtPriceLimitX96: zeroForOne ? MIN_SQRT : MAX_SQRT}),
            ""
        );

        _warpTo(window.endsAt() + FeastGenesis.SETTLE_GRACE);
        router.swap(
            feastKey.up(),
            ICLPoolManager.SwapParams({zeroForOne: zeroForOne, amountSpecified: -1e15, sqrtPriceLimitX96: zeroForOne ? MIN_SQRT : MAX_SQRT}),
            ""
        );
        assertGt(IERC20(feast).balanceOf(address(router)), 0, "and after openAt, anyone");
    }

    function test_withNoCommitsTheWindowSettlesAndBuysNothing() public {
        _warpTo(window.endsAt());
        window.settle();
        assertEq(window.tranche(), 0, "nothing to buy with");
    }

    // v1.6.11: `test_onlyTheVaultMayCallTheWindowsSwapPath` and its
    // `WindowCallbackProbe` lived here. They pinned the vault-only check on the
    // window's swap callback — that a caller holding its own vault lock could
    // not make the window buy outside `settle`, early, or twice. **The window
    // no longer has a swap, a lock callback, or a vault lock of any kind**: the
    // auction clears arithmetically and seeds through the factory. The surface
    // those tests guarded is gone rather than moved, which is why they are
    // deleted rather than repointed.

    /// Round 5 (L1): a committer claims once. With two equal commits, a second
    /// claim by one would take the other's half. Kills: dropping the
    /// claim-once check.
    function test_eachCommitterClaimsOnce() public {
        _warpTo(windowStart);
        vm.prank(alice);
        window.commit{value: 2e18}();
        vm.prank(bob);
        window.commit{value: 2e18}();
        _warpTo(window.endsAt());
        window.settle();
        uint256 a = window.claim(alice);
        vm.expectRevert(abi.encodeWithSelector(FeastLaunchWindow.AlreadyClaimed.selector, alice));
        window.claim(alice);
        uint256 b = window.claim(bob);
        assertEq(a + b, window.tranche(), "every unit paid");
        assertApproxEqAbs(a, b, 1, "half each");
    }

    /// If nobody settles before the auction is abandoned, every commit comes
    /// back in full. v1.6.24 (AstraSec M-2): that point is `abandonAt`, a week
    /// after the close, not the end of the one-hour grace — and at the end of
    /// the hour `settle` is still open, where it used to be refused for ever.
    function test_anUnsettledWindowRefundsEveryCommitInFull() public {
        _warpTo(windowStart);
        vm.prank(alice);
        window.commit{value: 4e18}();
        _warpTo(window.endsAt());
        vm.expectRevert(FeastLaunchWindow.NotRefundable.selector);
        window.refund(alice);
        _warpTo(window.endsAt() + FeastGenesis.SETTLE_GRACE);
        vm.expectRevert(FeastLaunchWindow.NotRefundable.selector);
        window.refund(alice);
        _warpTo(window.abandonAt());
        window.refund(alice);
        assertEq(wbnb.balanceOf(alice), 4e18, "in full, in wrapped native");
        assertEq(window.total(), 0, "and the pot no longer counts it");
        vm.expectRevert(FeastLaunchWindow.NothingCommitted.selector);
        window.refund(alice);
    }

    /// The window's pot pays the fee like any trade, and is nobody's trade:
    /// recorded on no ledger track.
    function test_thePotPaysTheFeeAndIsRecordedNowhere() public {
        _warpTo(windowStart);
        vm.prank(alice);
        window.commit{value: 10e18}();
        _warpTo(window.endsAt());
        uint256 week = ledger.currentWeek();
        uint256 sinkBefore = wbnb.balanceOf(address(sink));
        window.settle();
        // v1.6.11: there is no swap, so there is no swap fee. The pot still pays
        // the 1% — taken in `settle` and sent to the sink genesis named, which
        // is the destination `releasePlatformFees` reaches anyway, and spent on
        // buy-and-burn like every other platform fee.
        assertEq(wbnb.balanceOf(address(sink)) - sinkBefore, 10e18 / 100, "the pot paid the 1% to the sink");
        assertEq(hook.poolInfo(feastPoolId).accruedQuote, 0, "and no bucket in the hook moved");
        assertEq(ledger.totals(week, address(wbnb)).paid, 0, "and it is credited to nobody");
    }
}

/// The team's 25%.
contract FeastTeamVestingTest is UnitFixture {
    function test_itVestsLinearlyForThirtySixMonthsFromTheWindowsClose() public {
        _launch(1e18);
        uint256 total = SUPPLY * 2_500 / 10_000;
        assertEq(IERC20(feast).balanceOf(address(teamVesting)), total, "the team's 25%");
        assertEq(teamVesting.start(), window.endsAt(), "from the window's close");
        assertEq(teamVesting.duration(), 94_672_800, "36 months of 30.4375 days");
        _warpTo(window.endsAt() + 94_672_800 / 2);
        teamVesting.release(feast);
        assertApproxEqAbs(IERC20(feast).balanceOf(beneficiary), total / 2, 1e18, "half at half time - no cliff");
        _warpTo(window.endsAt() + 94_672_800);
        teamVesting.release(feast);
        assertEq(IERC20(feast).balanceOf(beneficiary), total, "all at the end");
    }

    function test_itCannotBeRenouncedAndNeverVotes() public {
        _launch(1e18);
        vm.prank(beneficiary);
        vm.expectRevert(FeastTeamVesting.RenounceDisabled.selector);
        teamVesting.renounceOwnership();
        assertEq(FeastPlatformToken(feast).getVotes(address(teamVesting)), 0, "no votes while it holds them");
        (bool ok,) = address(teamVesting).call(abi.encodeWithSignature("delegate(address)", beneficiary));
        assertFalse(ok, "and no way to delegate them");
    }
}

/// The platform sink: descending-price redemption.
contract FeastPlatformSinkTest is UnitFixture {
    uint256 internal constant ONE = 1 << 128;
    /// @dev P19's absolute slack, in raw Q128 price units: two readings of the
    ///      floor's decay, each truncating twice. Measured maximum shortfall
    ///      over the whole domain is 2; the clause states 4.
    uint256 internal constant CHORD_SLACK = 4;
    /// @dev How far below the old curve's continuation a RAISING write can leave
    ///      the floor, in raw Q128 price units. One, measured over three million
    ///      cases from base 1 to 2^128 and ages to forty half-lives (v1.6.3
    ///      round 2, `r2h`).
    uint256 internal constant RAISE_DEFICIT = 1;
    address internal taker = address(0x7A7E);

    function setUp() public override {
        super.setUp();
        _launch(10e18);
        stock.mint(address(sink), 100e18);
        // The taker holds some platform coin (bought in its now-open pool).
        wbnb.mint(address(router), 10e18);
    }

    function test_aLotStartsHighAndHalvesEveryHour() public {
        sink.open(address(stock));
        uint256 p0 = sink.priceQ128(address(stock));
        assertEq(p0, FeastGenesis.SINK_START_PRICE_Q128, "starts at the fixed high price");
        _advance(1 hours);
        assertEq(sink.priceQ128(address(stock)), p0 / 2, "halves in an hour");
        _advance(30 minutes);
        assertEq(sink.priceQ128(address(stock)), p0 / 2 - (p0 / 2) * 1_800 / 7_200, "linear inside a half-life");
        vm.expectRevert(abi.encodeWithSelector(FeastPlatformSink.AlreadyOpened.selector, address(stock)));
        sink.open(address(stock));
    }

    /// A take burns the platform coin it pays and re-anchors the price by the
    /// share of the lot taken. Kills: a take that does not burn; a flat
    /// re-anchor a dust take could abuse.
    function test_aTakeBurnsItsPaymentAndReanchorsByTheShareTaken() public {
        sink.open(address(stock));
        _advance(150 hours); // descend to something affordable
        uint256 price = sink.priceQ128(address(stock));
        uint256 cost = (25e18 * price + ONE - 1) / ONE;
        deal(feast, taker, cost);
        vm.prank(taker);
        IERC20(feast).approve(address(sink), cost);
        uint256 supply = IERC20(feast).totalSupply();
        vm.prank(taker);
        sink.take(address(stock), 25e18, cost);
        assertEq(stock.balanceOf(taker), 25e18, "the asset, delivered");
        assertEq(supply - IERC20(feast).totalSupply(), cost, "the payment, burned");
        assertEq(sink.priceQ128(address(stock)), price * 125 / 100, "a quarter of the lot lifts the price by a quarter");
    }

    /// Round 5 (L1): a lot never becomes free. Unsold for 200 hours — past the
    /// 193 halvings that empty the start price — it still costs at least one
    /// unit, so a take always burns something. Kills: dropping the clamp.
    function test_anUnsoldLotNeverBecomesFree() public {
        sink.open(address(stock));
        _advance(200 hours);
        assertEq(sink.priceQ128(address(stock)), 1, "one, the least a price can be");
        deal(feast, taker, 1);
        vm.prank(taker);
        IERC20(feast).approve(address(sink), 1);
        vm.prank(taker);
        uint256 cost = sink.take(address(stock), 100e18, 1);
        assertEq(cost, 1, "the whole lot, for one unit burned - never for nothing");
    }

    /// Round 5 (L1): after a sale the price stops at the sale's price halved six
    /// times. v1.6.2 (H2) adds the floor's own clock: that level is where the
    /// descent stops *at the moment of the sale*, and the floor then halves
    /// every `SINK_FLOOR_HALF_LIFE` since that sale. Kills: dropping the floor.
    function test_afterASaleThePriceStopsAtItsFloor() public {
        sink.open(address(stock));
        _advance(150 hours);
        uint256 price = sink.priceQ128(address(stock));
        _take(25e18, type(uint256).max); // a quarter of the lot, so a quarter of the price

        // Far enough down the descent that the floor is what is holding the price,
        // and still inside the floor's first half-life.
        _advance(12 hours);
        uint256 held = (price / 4) >> 6;
        held -= held * 12 hours / (2 * FeastGenesis.SINK_FLOOR_HALF_LIFE);
        assertEq(sink.priceQ128(address(stock)), held, "the sale's price by its share, halved six times, then its own clock");
    }

    /// H2: a lot the market has left behind comes back within reach. The floor
    /// is the last sale's price halved six times *at that sale*, and it halves
    /// every 24 hours thereafter — so a lot pinned above what anyone will pay
    /// unpins in days rather than never. Kills: a floor that never decays.
    function test_aLotPinnedAtItsFloorUnsticksAsTheFloorDecays() public {
        sink.open(address(stock));
        _advance(70 hours); // down to a price at which the lot is worth whole tokens
        uint256 price = sink.priceQ128(address(stock));
        _take(25e18, type(uint256).max); // 75e18 left, the floor's base is price >> 6

        // The descent runs out; the floor is all that holds the price up.
        _advance(200 hours);
        uint256 pinned = sink.priceQ128(address(stock));
        assertGt(pinned, 0, "the floor is holding it");

        // What the market will pay for the rest of the lot: a hundredth of that.
        uint256 market = pinned / 100;
        uint256 offer = (75e18 * market + ONE - 1) / ONE;
        deal(feast, taker, offer);
        vm.prank(taker);
        IERC20(feast).approve(address(sink), type(uint256).max);
        vm.prank(taker);
        vm.expectRevert();
        sink.take(address(stock), 75e18, offer); // refused today: the floor is above the market

        // Seven more days of the floor's own halving brings it within reach.
        _advance(7 days);
        assertLt(sink.priceQ128(address(stock)), market, "the floor has come down to the market");
        vm.prank(taker);
        uint256 cost = sink.take(address(stock), 75e18, offer);
        assertLe(cost, offer, "and the lot sells at what the market pays");
        assertEq(stock.balanceOf(taker), 100e18, "the whole lot, in the end");
    }

    /// H2, as v1.6.3 enforces it: a take that RAISES the floor resets the floor's
    /// base *and* its clock, and the 24-hour halving runs from that sale rather
    /// than from the first one. The other half of the rule — a take that does
    /// not raise it touches neither — is `test_aTakeThatDoesNotRaiseTheFloorLeavesItAndItsClockExactlyWhereTheyWere`.
    ///
    /// Before v1.6.3 this test's second take was a SMALLER one after four floor
    /// half-lives, which under the old unconditional write reset the floor
    /// downwards; that is the defect `CA-b229a31396`, and the dust version of it
    /// is `test/audit/poc/SinkFloorErasure.t.sol`. The take here is one hour
    /// later and four fifths of what is left, so it genuinely says more about
    /// the lot than the first sale did.
    ///
    /// Kills: not resetting `lastSaleAt` on a raising take.
    function test_aRaisingTakeResetsTheFloorsLevelAndItsClock() public {
        sink.open(address(stock));
        _advance(150 hours);
        uint256 first = sink.priceQ128(address(stock));
        _take(50e18, type(uint256).max); // half the lot, so half the price
        assertEq(sink.lot(address(stock)).floorBase, first / 2, "the first sale sets the level");

        // One hour on, the descent is still far above the floor — which sits
        // SINK_FLOOR_HALVINGS under the sale that set it — so a large take now
        // says more about the lot than that first sale did, and raises it.
        _advance(1 hours);
        uint256 priceNow = sink.priceQ128(address(stock));
        _take(40e18, type(uint256).max); // four fifths of what is left
        assertEq(
            sink.lot(address(stock)).floorBase,
            Math.mulDiv(priceNow, 40e18, 50e18),
            "the level: this sale's price by its share"
        );
        assertEq(sink.lot(address(stock)).lastSaleAt, uint64(block.timestamp), "and the clock restarts at this sale");

        _advance(24 hours);
        uint256 afterOneHalfLife = sink.priceQ128(address(stock));
        _advance(24 hours);
        assertApproxEqRel(
            sink.priceQ128(address(stock)) * 2,
            afterOneHalfLife,
            0.02e18,
            "and the clock: halving every 24 hours from that sale, not from the first one"
        );
    }

    /// The other half of v1.6.3's maximum rule, and the generalisation of the
    /// pack's PoC: a take whose own share-weighted floor does not beat the
    /// standing one writes NOTHING — not the base, not the clock — so the curve
    /// the earlier sale started continues undisturbed.
    ///
    /// Kills: writing the base unconditionally, and writing the clock
    /// unconditionally (each on its own — the two assertions are separate).
    function test_aTakeThatDoesNotRaiseTheFloorLeavesItAndItsClockExactlyWhereTheyWere() public {
        sink.open(address(stock));
        _advance(150 hours);
        _take(50e18, type(uint256).max); // a real sale: half the lot
        FeastPlatformSink.Lot memory set = sink.lot(address(stock));
        assertGt(set.floorBase, 0, "a real sale seeds a real floor");

        // Ten hours on the descent has fallen through that floor, so the floor
        // is what holds the price up. One raw unit now says almost nothing.
        _advance(10 hours);
        uint256 heldUp = sink.priceQ128(address(stock));
        _take(1, type(uint256).max);

        FeastPlatformSink.Lot memory after_ = sink.lot(address(stock));
        assertEq(after_.floorBase, set.floorBase, "the base a real sale set is untouched");
        assertEq(after_.lastSaleAt, set.lastSaleAt, "and so is the clock it started");
        assertEq(sink.priceQ128(address(stock)), heldUp, "so the floor still holds the price exactly where it did");
    }

    /// r4 (hunter lens). The floor is what a sale says the asset is worth, so it
    /// has to be weighted by how much of the lot that sale actually took. Before
    /// this, one raw unit bought from a refilled lot at the start price — about
    /// 18 FEAST — seeded a floor 2^58 above parity, and the floor's own daily
    /// halving then needed fifty-eight days to bring it back down. The declared
    /// cold start of about 64 hours became two months for the price of a coffee.
    /// Kills: dropping the weighting, or the shift.
    function test_aDustTakeSeedsAFloorOfDustAndLeavesTheColdStartAlone() public {
        MockERC20 asset = new MockERC20("A", "A", 18);
        // The platform's release, with a descent opened over it: from the top,
        // with nothing under it (round 5 — a new descent carries no floor).
        //
        // v1.6.3 changed this test's SETUP and not its subject. It used to reach
        // the top price by buying a one-unit lot whole and letting the refill
        // read from the top unopened — but a whole-lot sale seeds the whole
        // start price as a floor, and the assertion below only held because the
        // dust take then ERASED it. That erasure is the defect `CA-b229a31396`.
        // Under the maximum rule nothing but `open` clears a floor, so the
        // scaffolding would have dominated the measurement; the descent is
        // opened here instead, which is round 4's stated case — one raw unit
        // bought from a large lot at the start price — with no carried floor in
        // the way. What the old setup pinned is pinned by
        // `test_aCarriedFloorIsClearedByOpeningAndNotByASale`.
        asset.mint(address(sink), 1e24);
        sink.open(address(asset));
        assertEq(sink.priceQ128(address(asset)), FeastGenesis.SINK_START_PRICE_Q128, "from the top");
        _take2(asset, 1, type(uint256).max); // one raw unit of 10^24, at the top

        assertLt(
            sink.lot(address(asset)).floorBase >> FeastGenesis.SINK_FLOOR_HALVINGS,
            uint256(1) << 128,
            "one unit of a million tokens seeds a floor far below parity"
        );

        // And the cold start is the declared one: 64 halvings from the top to
        // parity, with nothing holding it up.
        _advance(64 hours);
        assertApproxEqRel(sink.priceQ128(address(asset)), uint256(1) << 128, 0.01e18, "at parity after 64 hours");
    }

    /// What v1.6.3's maximum rule costs, stated rather than left to be found: a
    /// floor can be cleared by `open` and by nothing else. A sale used to be
    /// able to clear one — which is exactly the erasure `CA-b229a31396` — so a
    /// floor carried by an emptied lot into a refill now stands until a keeper
    /// opens a descent over that refill.
    ///
    /// It stands in the SAFE direction: an unopened lot reads at the start price
    /// or the floor, whichever is higher, so a carried floor can only make the
    /// sink refuse to sell cheaply. `open` is permissionless, and B9 already
    /// names the keeper.
    ///
    /// Kills: clearing the floor on a take; not clearing it on `open`.
    function test_aCarriedFloorIsClearedByOpeningAndNotByASale() public {
        MockERC20 asset = new MockERC20("A", "A", 18);
        asset.mint(address(sink), 1); // a lot of one unit
        sink.open(address(asset));
        _take2(asset, 1, type(uint256).max); // bought whole, at the top: it seeds the whole start price
        assertEq(
            sink.lot(address(asset)).floorBase,
            FeastGenesis.SINK_START_PRICE_Q128,
            "a whole-lot sale says the whole price"
        );

        // The release lands in the emptied lot. Nobody has opened a descent over
        // it, so it reads at the start price or the carried floor, whichever is
        // higher — and a dust sale no longer buys that floor away.
        asset.mint(address(sink), 1e24);
        _take2(asset, 1, type(uint256).max);
        assertEq(
            sink.lot(address(asset)).floorBase,
            FeastGenesis.SINK_START_PRICE_Q128,
            "one raw unit cannot buy away the floor the sale before it set"
        );

        // The keeper opens the refilled lot and the floor goes with the descent
        // that earned it.
        sink.open(address(asset));
        assertEq(sink.lot(address(asset)).floorBase, 0, "opening a new descent clears it");
        _advance(64 hours);
        assertApproxEqRel(sink.priceQ128(address(asset)), uint256(1) << 128, 0.01e18, "at parity after 64 hours");
    }

    /// r5 (both lenses). The weight is a share of the lot, so it cannot tell one
    /// raw unit that WAS the whole lot from one raw unit of a million: buying a
    /// single donated unit at the start price, for about 18 FEAST, seeded the
    /// whole start price as a floor and then bounded a lot a million times
    /// larger for the fifty-eight days its own halving needed. A floor is what a
    /// sale says about the lot its descent priced, so a new descent carries none
    /// of it. Kills: keeping the floor across `open`.
    function test_aNewDescentCarriesNoFloorFromTheLotBeforeIt() public {
        MockERC20 asset = new MockERC20("A", "A", 18);
        asset.mint(address(sink), 1);
        sink.open(address(asset));
        _take2(asset, 1, type(uint256).max); // the whole of a one-unit lot, at the top
        assertEq(
            sink.lot(address(asset)).floorBase,
            FeastGenesis.SINK_START_PRICE_Q128,
            "that sale did seed the whole start price - it sold the whole lot"
        );

        // The platform's release arrives and the keeper opens a descent over it.
        // It starts from the top with nothing under it, so the declared cold
        // start is the real one: 64 halvings to parity, and a take at parity.
        asset.mint(address(sink), 1e24);
        sink.open(address(asset));
        assertEq(sink.lot(address(asset)).floorBase, 0, "the new descent carries no floor");
        _advance(64 hours);
        assertEq(sink.priceQ128(address(asset)), uint256(1) << 128, "parity after the declared 64 hours");

        // A sale inside THIS descent seeds the weighted floor, and H2's clock
        // runs from that sale.
        _take2(asset, 5e23, type(uint256).max); // half the lot
        assertEq(sink.lot(address(asset)).floorBase, (uint256(1) << 128) / 2, "half the lot, half the price");
        _advance(200 hours);
        uint256 floorNow = sink.priceQ128(address(asset));
        _advance(24 hours);
        assertApproxEqRel(sink.priceQ128(address(asset)) * 2, floorNow, 0.02e18, "and it halves daily from there");
    }

    /// The weighting, as a property: a sale can never say the asset is worth
    /// more per unit than the sale itself paid.
    function testFuzz_theFloorsBaseNeverExceedsThePriceTheSalePaid(uint256 share, uint256 hours_) public {
        sink.open(address(stock));
        // From parity downwards, so the whole lot stays payable in a coin whose
        // supply is finite; the weighting is the same arithmetic all the way up.
        _advance(bound(hours_, 64, 200) * 1 hours);
        uint256 price = sink.priceQ128(address(stock));
        uint256 amount = bound(share, 1, 100e18);
        _take(amount, type(uint256).max);

        uint256 base = sink.lot(address(stock)).floorBase;
        uint256 sale = Math.mulDiv(price, amount, 100e18);
        assertLe(base, price, "the floor's base never exceeds the price the sale paid");
        // v1.6.3: the sale writes its own weighted base exactly when that base
        // RAISES the standing floor. This descent is fresh, so the standing
        // floor is zero and every sale whose own floor is positive writes it. A
        // sale whose own floor rounds away under the SINK_FLOOR_HALVINGS shift
        // writes nothing, which is the same floor it would have written.
        if ((sale >> FeastGenesis.SINK_FLOOR_HALVINGS) > 0) {
            assertEq(base, sale, "and it is that price by the share the sale took");
        } else {
            assertEq(base, 0, "a sale whose own floor rounds to nothing sets no floor");
        }
    }

    function _take2(MockERC20 asset, uint256 amountOut, uint256 limit) private returns (uint256 cost) {
        cost = Math.mulDiv(amountOut, sink.priceQ128(address(asset)), ONE, Math.Rounding.Ceil);
        deal(feast, taker, cost);
        vm.prank(taker);
        IERC20(feast).approve(address(sink), type(uint256).max);
        vm.prank(taker);
        sink.take(address(asset), amountOut, limit);
    }

    /// Round 6 (L1): platform coin that reaches the sink directly is never for
    /// sale; anyone may burn it. Kills: a `burnStray` that burns nothing.
    function test_platformCoinSentToTheSinkBurns() public {
        deal(feast, taker, 5e18);
        vm.prank(taker);
        IERC20(feast).transfer(address(sink), 5e18);
        uint256 supply = IERC20(feast).totalSupply();
        sink.burnStray();
        assertEq(supply - IERC20(feast).totalSupply(), 5e18, "burned, every unit");
        assertEq(IERC20(feast).balanceOf(address(sink)), 0, "nothing left in the sink");
    }

    function test_theSinkRefusesToSellThePlatformCoinOrMoreThanItHolds() public {
        vm.expectRevert(abi.encodeWithSelector(FeastPlatformSink.NotForSale.selector, feast));
        sink.open(feast);
        sink.open(address(stock));
        vm.expectRevert(abi.encodeWithSelector(FeastPlatformSink.MoreThanHeld.selector, 101e18, 100e18));
        sink.take(address(stock), 101e18, type(uint256).max);
    }

    // --- v1.6.2: a descent prices the lot it was opened over ----------------

    /// The clock never starts on a lot with nothing to sell. Before v1.6.2
    /// anyone could open every asset on day one and let the price run to its
    /// clamp weeks before the first fee release arrived (`CA-fb2e051555`).
    /// Kills: dropping `open`'s inventory requirement.
    function test_aLotCannotBeOpenedBeforeItHoldsAnything() public {
        MockERC20 fresh = new MockERC20("Fresh", "FRSH", 18);
        vm.expectRevert(abi.encodeWithSelector(FeastPlatformSink.NothingToOffer.selector, address(fresh)));
        sink.open(address(fresh));

        // One raw unit is enough: what is refused is an empty lot, not a small one.
        fresh.mint(address(sink), 1);
        sink.open(address(fresh));
        assertEq(sink.priceQ128(address(fresh)), FeastGenesis.SINK_START_PRICE_Q128, "the descent starts at the top");
    }

    /// The heart of the v1.6.2 fix. A lot is taken to empty, a week passes, and
    /// the platform's next fee release lands: the elapsed week is not evidence
    /// about a lot that was not there, so the refill is priced from the top —
    /// not at the emptied lot's re-anchor, and never at the clamp of one.
    /// Kills: dropping the doubled-lot branch; leaving `offered` alone on a take.
    function test_aRefillIntoAnEmptyLotIsPricedFromTheTop() public {
        sink.open(address(stock));
        _advance(150 hours);
        uint256 price = sink.priceQ128(address(stock));
        _take(100e18, type(uint256).max); // the whole lot: the sink now holds nothing

        _advance(7 days);
        stock.mint(address(sink), 1_000_000e18);
        assertEq(
            sink.priceQ128(address(stock)),
            FeastGenesis.SINK_START_PRICE_Q128,
            "a refill into an emptied lot is priced from the top"
        );
        assertGt(sink.priceQ128(address(stock)), price, "and never below what the lot last sold for");

        // A taker cannot have it at the old price either: the take prices
        // through the same branch, so a refill is never given away.
        uint256 atTheOldPrice = (1_000_000e18 * price + ONE - 1) / ONE;
        deal(feast, taker, atTheOldPrice);
        vm.prank(taker);
        IERC20(feast).approve(address(sink), atTheOldPrice);
        vm.prank(taker);
        vm.expectRevert();
        sink.take(address(stock), 1_000_000e18, atTheOldPrice);

        // The descent over the refilled lot starts when someone opens it.
        sink.open(address(stock));
        _advance(1 hours);
        assertEq(
            sink.priceQ128(address(stock)),
            FeastGenesis.SINK_START_PRICE_Q128 / 2,
            "and then descends from the top, at the published half-life"
        );
    }

    /// Between "empty" and "unchanged" sits the lot that merely grew. A lot that
    /// has at least doubled since its descent began is a different lot and reads
    /// at the top until someone opens it; opening it is what starts the clock.
    /// Kills: dropping the doubled-lot branch.
    function test_aLotThatHasDoubledIsPricedFromTheTopUntilItIsOpenedAgain() public {
        sink.open(address(stock)); // over the 100e18 the fixture holds
        _advance(100 hours);
        uint256 descended = sink.priceQ128(address(stock));
        assertLt(descended, FeastGenesis.SINK_START_PRICE_Q128, "precondition: the descent has run");

        stock.mint(address(sink), 100e18); // the lot doubles
        assertEq(
            sink.priceQ128(address(stock)),
            FeastGenesis.SINK_START_PRICE_Q128,
            "the doubled lot is priced from the top"
        );

        _advance(50 hours);
        assertEq(
            sink.priceQ128(address(stock)),
            FeastGenesis.SINK_START_PRICE_Q128,
            "and stays there while nobody opens it - waiting is not a descent"
        );

        sink.open(address(stock));
        _advance(1 hours);
        assertEq(sink.priceQ128(address(stock)), FeastGenesis.SINK_START_PRICE_Q128 / 2, "the new descent runs");
    }

    /// The other side of the same rule, and the reason the threshold is a
    /// doubling rather than any growth at all: a dust donation cannot reset a
    /// live descent, or one wei an hour would hold the price at the top for
    /// ever. Kills: dropping `open`'s `AlreadyOpened` guard.
    function test_aDustDonationCannotRestartALiveDescent() public {
        sink.open(address(stock));
        _advance(100 hours);
        uint256 descended = sink.priceQ128(address(stock));

        stock.mint(address(sink), 1); // a griefer's one wei
        vm.expectRevert(abi.encodeWithSelector(FeastPlatformSink.AlreadyOpened.selector, address(stock)));
        sink.open(address(stock));
        assertEq(sink.priceQ128(address(stock)), descended, "the live descent is untouched");

        // Resetting it costs a doubling, every time, and what it costs stays here.
        stock.mint(address(sink), 100e18);
        sink.open(address(stock));
        assertEq(sink.priceQ128(address(stock)), FeastGenesis.SINK_START_PRICE_Q128, "a doubling does reset it");
        assertEq(stock.balanceOf(address(sink)), 200e18 + 1, "and every unit of it stays in the sink");
    }

    /// B9, declared: a refill smaller than the lot it lands in does not restart
    /// the descent, and is sold at the price that descent has reached. That is
    /// what the threshold buys, and it is what an attacker can still use: leave
    /// at least as much of the asset here as the next release will bring, run
    /// the descent down, and take both cheaply. The stake is on offer at the
    /// same published price for the whole descent - anyone may take it from
    /// them - so the attacker's downside is the platform's upside.
    function test_aRefillSmallerThanTheLotDoesNotRestartTheDescent() public {
        sink.open(address(stock)); // over 100e18
        _advance(100 hours);
        uint256 descended = sink.priceQ128(address(stock));

        stock.mint(address(sink), 99e18); // a release just under a doubling
        assertEq(sink.priceQ128(address(stock)), descended, "the descent stands, and prices the whole lot");

        // And the stake that bought that price is takeable by anyone, at it.
        _take(199e18, type(uint256).max);
        assertEq(stock.balanceOf(taker), 199e18, "including the attacker's own stake");
    }

    /// The boundary of "empty", pinned on the dust side: a lot drained to
    /// nothing and refilled with one wei is a new lot - priced from the top and
    /// needing its own `open` - while one wei into a lot that is still
    /// descending is the griefer's donation above, which changes nothing.
    function test_aDrainedLotRefilledWithDustIsANewLotNotALiveDescent() public {
        sink.open(address(stock));
        _advance(150 hours);
        _take(100e18, type(uint256).max); // drained: offered is now zero
        assertEq(sink.lot(address(stock)).offered, 0, "no descent runs over an empty lot");

        stock.mint(address(sink), 1);
        assertEq(
            sink.priceQ128(address(stock)),
            FeastGenesis.SINK_START_PRICE_Q128,
            "one wei into an emptied lot is a new lot, priced from the top"
        );
        sink.open(address(stock)); // permitted: a drained lot is not a live descent
        assertEq(sink.lot(address(stock)).offered, 1, "and the new descent is over what is actually here");
    }

    // --- v1.6.3 F1: the re-anchor, and what bounds the arithmetic around it ---

    /// `CA-fad351f89b`. The re-anchor writes the same number it always wrote, in
    /// a form whose intermediate cannot overflow: `⌊p(h+a)/h⌋ = p + ⌊pa/h⌋`,
    /// because `p` is an integer and comes out of the floor exactly. Fuzzed over
    /// every `held ≥ amountOut ≥ 1` and every `price` for which the OLD form did
    /// not overflow — the case where it did is `test/audit/poc/SinkAnchorOverflow.t.sol`.
    ///
    /// Kills: any re-anchor that is not this number (a flat one, an unweighted
    /// one, one that rounds the other way).
    function testFuzz_theReanchorIsTheSameNumberWrittenSafely(uint256 price, uint256 held, uint256 amountOut)
        public
        pure
    {
        // The old form's own preconditions, and only those: the sum it formed
        // had to fit a word, and so did the quotient it produced (at most 2p).
        held = bound(held, 1, type(uint256).max / 2);
        amountOut = bound(amountOut, 1, held);
        price = bound(price, 0, type(uint256).max / 2);

        assertEq(
            price + Math.mulDiv(price, amountOut, held),
            Math.mulDiv(price, held + amountOut, held),
            "the safe form is the same number the overflowing one computed"
        );
    }

    /// The edge the old form could not reach at all: a lot holding an entire
    /// supply. `held + amountOut` overflows for every positive take, while the
    /// value being computed moves the anchor by nothing at all.
    function test_theReanchorAtTheEdgeTheOldFormCouldNotReach() public pure {
        uint256 held = type(uint256).max;
        uint256 price = FeastGenesis.SINK_START_PRICE_Q128;
        assertEq(price + Math.mulDiv(price, 1, held), price, "one unit out of an entire supply moves it by nothing");
        assertEq(price + Math.mulDiv(price, held, held), 2 * price, "and the whole lot doubles it, as it always did");
    }

    /// The anchor's own growth is a BOUND, not a defect, and this is the witness
    /// for the arithmetic `plans/v163/plan.md` states. A take of the fraction `f`
    /// re-anchors at `price·(1+f)`, so one take at most doubles the anchor — but
    /// a ratchet has to use partial takes, and they pay for themselves: half a
    /// lot at `p` costs `pL/2` and lifts the anchor to `1.5p`, half of THAT
    /// costs `1.5p·L/4 = 0.75·(pL/2)`, and every further step costs 0.75 of the
    /// one before it. So the whole chain costs at most `4×` its first take
    /// **plus one wei per take**, however long it runs, while lifting the anchor
    /// by only 1.5× a step. The `+1 wei` is the ceiling in `cost`, and at the
    /// `price == 1` clamp it is the whole story: every take costs exactly one wei
    /// and the re-anchor stays at 1, so the geometric argument says nothing there
    /// (round 3, `r3v`, which found the unqualified sentence false — the
    /// assertion below had carried the `+ steps` term from the start).
    ///
    /// That is what keeps `price * into` in `_price` and `floor_ * into` in
    /// `_floorNow` inside a word: both need the price under `2^244`, and
    /// reaching that from the `2^192` start price needs ~89 such steps whose
    /// total spend is bounded by four times the first.
    function testFuzz_aChainOfHalfLotTakesCostsAtMostFourTimesItsFirstTake(uint256 size, uint8 steps_) public {
        uint256 lotSize = bound(size, 1 << 50, 1 << 70);
        uint256 steps = bound(uint256(steps_), 2, 20);

        MockERC20 asset = new MockERC20("A", "A", 18);
        asset.mint(address(sink), lotSize);
        sink.open(address(asset));
        _advance(66 hours); // the descent, down to somewhere payable

        uint256 held = lotSize;
        uint256 firstCost;
        uint256 total;
        for (uint256 i = 0; i < steps; i++) {
            uint256 amount = held / 2;
            if (amount == 0) break;
            uint256 cost = _take2(asset, amount, type(uint256).max);
            if (i == 0) firstCost = cost;
            total += cost;
            held -= amount;
        }

        assertGt(firstCost, 0, "the first take cost something");
        // `+ steps` is the ceiling rounding of one wei per take, nothing more.
        assertLe(total, 4 * firstCost + steps, "the whole chain costs at most four times its first take");
        assertLt(
            sink.lot(address(asset)).anchor,
            uint256(1) << 244,
            "and the anchor stays far inside what the two decay sites need"
        );
    }

    // --- v1.6.3 F3: the floor's maximum rule, and what it costs ---------------

    /// P19's second clause, **as an integer statement** (v1.6.3 round 1, r1v).
    ///
    /// The chord-gap derivation is right in the reals: the floor decays linearly
    /// inside each half-life, so `d(a+b) <= d(a).d(b)`, and the single clock the
    /// contract keeps is never worse than 8/9 of a restarted one, the worst case
    /// being `a = b = H/2` where `d(a)d(b) = 9/16` against `d(a+b) = 1/2`.
    ///
    /// The contract does not evaluate that in the reals. `_floorNow` shifts down
    /// and then floors one linear step, and the promise is read the same way, so
    /// two readings truncate twice each and the real bound can be missed by a
    /// few raw units. The clause therefore promises the relative bound **less an
    /// absolute slack of `CHORD_SLACK` raw price units**, and at magnitudes
    /// where four units matter the relative half says nothing and the slack is
    /// the whole promise. Four units is NOT economically zero on a large lot: a
    /// take pays `amountOut × price / 2^128`, so four units over `N` raw units
    /// is up to `4N / 2^128` platform coin — thousands of FEAST for the largest
    /// lots (round 3, `r3v`). It is the price of reading a decaying floor with
    /// integer arithmetic.
    ///
    /// Kills: lowering the slack below what the truncations need.
    function testFuzz_theChordGapIsNeverWorseThanEightNinthsLessItsSlack(
        uint256 base,
        uint256 magnitude,
        uint256 a,
        uint256 t
    ) public pure {
        // Log-uniform over the WHOLE domain. A uniform draw from `[1, 2^192]`
        // is a draw from the top few bits and would never visit the small
        // magnitudes where this claim is weakest — which is exactly how the
        // first version of this witness came to be unable to fail.
        uint256 f = bound(base, 1, uint256(1) << bound(magnitude, 0, 192));
        uint256 ageA = bound(a, 0, 30 days);
        uint256 ageT = bound(t, 0, 30 days);

        uint256 promised = _decayed(_decayed(f, ageA), ageT); // two clocks
        uint256 held = _decayed(f, ageA + ageT); // one clock: what the contract keeps

        // held >= (8/9).promised - CHORD_SLACK, in integers.
        assertLe(
            promised * 8,
            held * 9 + 9 * CHORD_SLACK,
            "the floor held is below the chord gap plus its truncation slack"
        );
    }

    /// What the measurement says that the derivation did not: **the slack is not
    /// a small-number artefact.** At `a = t` of exactly half a half-life the real
    /// inequality is tight — the ratio IS 9/8 — so the two truncations push it
    /// over at every magnitude, not only at small ones. This is the fixed
    /// counterexample, with a floor of ten thousand raw units, where the
    /// relative bound alone is false by one part in nine thousand.
    ///
    /// It replaces an assertion the coordinator's ruling asked for — that above
    /// `2^64` the relative bound holds with slack 0 — which measurement
    /// falsified. There is no magnitude above which it holds.
    function test_theChordGapNeedsItsAbsoluteSlackAtEveryMagnitude() public pure {
        uint256 f = 19_998;
        uint256 half = uint256(FeastGenesis.SINK_FLOOR_HALF_LIFE) / 2;

        uint256 promised = _decayed(_decayed(f, half), half);
        uint256 held = _decayed(f, 2 * half);
        assertEq(held, 9_999, "a floor of ten thousand raw units, not a handful");

        assertGt(promised * 8, held * 9, "the relative bound ALONE is false here, at any magnitude");
        assertLe(promised * 8, held * 9 + 9 * CHORD_SLACK, "and the slack is what carries the clause");

        // And the WORST point measured anywhere in the domain, which is what the
        // slack has to cover and therefore what makes the constant load-bearing
        // rather than padding. An exhaustive sweep of small bases on a one-hour
        // grid, plus a wide random search, puts the maximum shortfall at two
        // raw units; the clause states four, so it carries two units of
        // headroom and no more. A slack of 1 fails right here.
        uint256 gap = _shortfall(13, 39_360, 47_040);
        assertEq(gap, 18, "the measured worst case: 8.promise - 9.held, so a shortfall of exactly 2 units");
        assertLe(gap, 9 * CHORD_SLACK, "and the stated slack covers it");
    }

    /// Round 2's hunter (`r2h`) found this before the provider's content filter
    /// stopped it, and it is the chord gap's twin: "a take may raise the
    /// standing floor, **never lower it**" is exact at the instant of the sale
    /// and is NOT exact afterwards. A raising write replaces the standing
    /// curve's continuation with a fresh curve from a higher base, and the two
    /// truncations can leave the fresh one a unit below what the old one would
    /// have given — for the same reason the chord gap needs its slack.
    ///
    /// The unit's own counterexample, reproduced: a standing base of 755,285
    /// aged 489,419 s stands at 15,760; a sale raises it by the smallest
    /// possible amount, to 15,761; 1,141,207 s later the old curve would say 2
    /// and the new one says 1.
    ///
    /// The deficit is at most ONE raw price unit — measured over three million
    /// cases spanning bases from 1 to 2^128 and ages to forty half-lives — so
    /// the clause carries that qualifier and no more.
    ///
    /// Kills: claiming an unqualified "never lower".
    function test_aRaisingTakeIsExactAtTheSaleAndWithinOneUnitAfterIt() public pure {
        uint256 f = 755_285;
        uint256 a = 489_419;
        uint256 standing = _decayed(f, a);
        assertEq(standing, 15_760, "the standing floor at the sale");

        uint256 raised = standing + 1; // the smallest raise there is
        assertGe(raised, standing, "and at the sale itself it is exactly not lower");

        uint256 b = 1_141_207;
        uint256 oldCurve = _decayed(f, a + b);
        uint256 newCurve = _decayed(raised, b);
        assertEq(oldCurve, 2, "what leaving it alone would have given");
        assertEq(newCurve, 1, "what the raising write gives");
        assertLt(newCurve, oldCurve, "so a RAISING take did leave the floor lower, later");
        assertLe(oldCurve - newCurve, RAISE_DEFICIT, "by no more than the stated unit");
    }

    /// The same, as a property over the whole domain.
    function testFuzz_aRaisingTakeNeverCostsMoreThanOneUnitLaterOn(
        uint256 base,
        uint256 magnitude,
        uint256 a,
        uint256 raise_,
        uint256 b
    ) public pure {
        uint256 f = bound(base, 1, uint256(1) << bound(magnitude, 0, 192));
        uint256 ageA = bound(a, 0, 40 days);
        uint256 standing = _decayed(f, ageA);
        vm.assume(standing != 0);
        // Any write that RAISES: the rule's own precondition.
        uint256 raised = bound(raise_, standing, standing + (uint256(1) << 192));
        uint256 ageB = bound(b, 0, 40 days);

        uint256 oldCurve = _decayed(f, ageA + ageB);
        uint256 newCurve = _decayed(raised, ageB);
        if (oldCurve > newCurve) {
            assertLe(oldCurve - newCurve, RAISE_DEFICIT, "a raising take cost more than one unit later on");
        }
    }

    /// @dev `8 * promise - 9 * held` at one point: how far below the relative
    ///      bound the floor the contract keeps falls, in ninths of a raw unit.
    function _shortfall(uint256 f, uint256 ageA, uint256 ageT) private pure returns (uint256) {
        uint256 promised = _decayed(_decayed(f, ageA), ageT);
        uint256 held = _decayed(f, ageA + ageT);
        return promised * 8 - held * 9;
    }

    /// Round 1's HIGH (`r1v`), as a fixed test: the lens's own sequence, in the
    /// contract's own arithmetic. A lot of `2^200` opened and left 172 hours, a
    /// take of `3 x 2^186` seeding an effective floor of 3, then twelve hours on
    /// a half-lot take whose own floor is 2 — which does not beat 3, so nothing
    /// is written, correctly. Twelve hours after that the descent has decayed
    /// away, the floor the contract keeps is 1, and the lower sale's own-clock
    /// floor is 2: a ratio of one half, not 8/9.
    ///
    /// It passes under the restated clause and fails under the old one, which is
    /// the whole point of restating it.
    function test_theLensSequenceHoldsUnderTheRestatedClauseAndNotTheOldOne() public {
        MockERC20 asset = new MockERC20("A", "A", 18);
        asset.mint(address(sink), 2 ** 200);
        sink.open(address(asset));
        _advance(172 hours);

        uint256 first = sink.priceQ128(address(asset));
        _take2(asset, 3 * 2 ** 186, type(uint256).max);
        uint256 standing = sink.lot(address(asset)).floorBase >> FeastGenesis.SINK_FLOOR_HALVINGS;
        assertEq(standing, 3, "the first sale's effective floor");

        _advance(12 hours);
        uint256 price = sink.priceQ128(address(asset));
        uint256 held = IERC20(address(asset)).balanceOf(address(sink));
        uint256 lower = Math.mulDiv(price, held / 2, held) >> FeastGenesis.SINK_FLOOR_HALVINGS;
        _take2(asset, held / 2, type(uint256).max);
        assertEq(
            sink.lot(address(asset)).floorBase >> FeastGenesis.SINK_FLOOR_HALVINGS,
            standing,
            "the lower sale writes nothing, which is the maximum rule working"
        );

        _advance(12 hours);
        uint256 published = sink.priceQ128(address(asset));
        uint256 promised = _decayed(lower, 12 hours);

        // The old clause, as v1.6.3 first wrote it: the relative bound alone.
        assertGt(promised * 8, published * 9, "the OLD clause is false here - this is round 1's HIGH");
        // The restated one.
        assertLe(promised * 8, published * 9 + 9 * CHORD_SLACK, "the restated clause holds");
    }

    /// `_floorNow`'s decay, restated here so the bound above is measured against
    /// the contract's own arithmetic rather than against a model of it.
    function _decayed(uint256 floor_, uint256 since) private pure returns (uint256) {
        uint256 halvings = since / FeastGenesis.SINK_FLOOR_HALF_LIFE;
        floor_ = halvings >= 255 ? 0 : floor_ >> halvings;
        uint256 into = since % FeastGenesis.SINK_FLOOR_HALF_LIFE;
        return floor_ - floor_ * into / (2 * FeastGenesis.SINK_FLOOR_HALF_LIFE);
    }

    function _take(uint256 amountOut, uint256 limit) private {
        uint256 cost = Math.mulDiv(amountOut, sink.priceQ128(address(stock)), ONE, Math.Rounding.Ceil);
        deal(feast, taker, cost);
        vm.prank(taker);
        IERC20(feast).approve(address(sink), cost);
        vm.prank(taker);
        sink.take(address(stock), amountOut, limit);
    }

    // --- round 1 of the v1.6.2 lens: what the first shape of the rule missed -

    /// r1 H1 (both lenses). The first shape of this rule let a take RAISE the
    /// size a descent prices. That was enough to rebuild the giveaway: run a
    /// three-unit lot down to the clamp, then, inside one transaction nobody can
    /// interleave with, donate almost the whole lot and buy a single unit for
    /// one wei — each round doubling the recorded size while the price stays at
    /// one — until the recorded size exceeds the fee release that is coming.
    /// The release then lands in a lot that reads as "already descending" and
    /// sells for one more wei, and the donations come back out with it.
    ///
    /// Only `open` sets that size now; a take may lower it and never raise it,
    /// so the ratchet stalls on its first turn. Kills: `lot.offered = held -
    /// amountOut` without the min.
    function test_aTakeNeverRaisesTheSizeADescentPrices() public {
        MockERC20 asset = new MockERC20("A", "A", 18);
        asset.mint(address(sink), 3); // three raw units, and a descent over them
        sink.open(address(asset));
        _advance(200 hours);
        assertEq(sink.priceQ128(address(asset)), 1, "the three-unit lot is at the clamp");

        // One turn of the ratchet: donate two, buy one for one wei.
        asset.mint(address(sink), 2);
        deal(feast, taker, 2);
        vm.prank(taker);
        IERC20(feast).approve(address(sink), type(uint256).max);
        vm.prank(taker);
        sink.take(address(asset), 1, 1);
        assertEq(sink.lot(address(asset)).offered, 3, "the take did not enlarge the descent");

        // The next turn cannot happen: the lot now holds more than twice what
        // the descent priced, so it reads from the top instead of from one.
        asset.mint(address(sink), 3);
        assertEq(
            sink.priceQ128(address(asset)),
            FeastGenesis.SINK_START_PRICE_Q128,
            "the ratchet stalls: a lot twice the descent's size is priced from the top"
        );

        // And the fee release it was aimed at is not for sale at one wei.
        asset.mint(address(sink), 1e24);
        vm.prank(taker);
        vm.expectRevert();
        sink.take(address(asset), 1e24, 1);
    }

    /// r1 H2 (both lenses). A sale can leave the price ABOVE the start price —
    /// each take re-anchors at `price × (1 + f)`, so a lot bought in halves
    /// climbs — and then the post-sale floor is above the start price too. The
    /// refill branch returned the start price flat, which sold under that floor
    /// and let `open` RAISE a quote by applying the floor the branch had
    /// skipped. Both readings are floored now. Kills: the unfloored early
    /// return.
    function test_aRefillIsPricedFromTheTopButNeverUnderTheFloor() public {
        MockERC20 asset = new MockERC20("A", "A", 18);
        asset.mint(address(sink), 8_192);
        sink.open(address(asset));
        deal(feast, taker, 4e23 + 5e21);
        vm.prank(taker);
        IERC20(feast).approve(address(sink), type(uint256).max);

        // Twelve takes of half the lot each, all in the same second: the price
        // climbs by half again at every one. Then the last two units go in one
        // take, so that sale's share of the lot is the whole of it and the floor
        // it seeds is its full price (v1.6.2 round 4).
        for (uint256 i = 0; i < 12; ++i) {
            uint256 half = asset.balanceOf(address(sink)) / 2;
            vm.prank(taker);
            sink.take(address(asset), half, type(uint256).max);
        }
        uint256 lastPrice = sink.priceQ128(address(asset));
        uint256 rest = asset.balanceOf(address(sink)); // read first: vm.prank covers one call
        vm.prank(taker);
        sink.take(address(asset), rest, type(uint256).max);

        uint256 floor_ = sink.lot(address(asset)).floorBase >> FeastGenesis.SINK_FLOOR_HALVINGS;
        assertEq(sink.lot(address(asset)).floorBase, lastPrice, "a whole-lot take seeds the whole price");
        assertGt(floor_, FeastGenesis.SINK_START_PRICE_Q128, "this lot's floor is above the start price");

        // A refill big enough to reprice from the top: the top is not below the
        // floor the last sale set.
        asset.mint(address(sink), 2);
        assertEq(sink.priceQ128(address(asset)), floor_, "the refill is priced at the floor, not under it");

        // And opening a descent over it never raises the quote. It lowers this
        // one, because a new descent starts with no floor at all: the floor
        // belonged to the lot the sale came from (round 5).
        uint256 before_ = sink.priceQ128(address(asset));
        sink.open(address(asset));
        assertLe(sink.priceQ128(address(asset)), before_, "open never raises a quote");
        assertEq(sink.lot(address(asset)).floorBase, 0, "and the new descent carries no floor");
        assertEq(sink.priceQ128(address(asset)), FeastGenesis.SINK_START_PRICE_Q128, "it starts at the top");
    }

    /// r2 (verifier lens, recovered from a unit the provider's content filter
    /// killed before it could return a verdict). `take` is guarded against
    /// re-entry; `open` was not. An asset that calls back while the sink is
    /// sending it could therefore open a descent in the middle of a take —
    /// seeing the balance the take has not yet moved and the reference size it
    /// has already zeroed — and leave a descent recorded over a lot of 10^24
    /// units that the take then empties. The clock would run on that empty lot
    /// exactly as it did before this pass, and the next fee release would sell
    /// for one wei. `open` is `nonReentrant` now. Kills: dropping that guard.
    function test_anAssetThatCallsBackCannotOpenADescentMidTake() public {
        ReopeningToken hooked = new ReopeningToken();
        hooked.mint(address(sink), 1e24);
        sink.open(address(hooked));
        _advance(60 hours);

        uint256 price = sink.priceQ128(address(hooked));
        uint256 cost = (1e24 * price + ONE - 1) / ONE;
        deal(feast, taker, cost);
        vm.prank(taker);
        IERC20(feast).approve(address(sink), type(uint256).max);

        hooked.armAgainst(sink);
        vm.prank(taker);
        vm.expectRevert(); // the callback's open is refused, and it takes the take with it
        sink.take(address(hooked), 1e24, cost);

        // Unarmed, the same take goes through and leaves no descent behind.
        hooked.disarm();
        vm.prank(taker);
        sink.take(address(hooked), 1e24, cost);
        assertEq(sink.lot(address(hooked)).offered, 0, "an emptied lot records no descent");
    }

    /// r2, the same stale state reached without any callback: an asset that can
    /// shrink a holder's balance — a rebase, a clawback, a burn on the holder —
    /// leaves `offered` recording a lot that is no longer here. While the lot is
    /// below what its descent priced, that descent does not price it: the
    /// elapsed time is not evidence about a lot this size. Kills: dropping the
    /// `held < lot.offered` arm.
    ///
    /// What this does NOT reach is an issuer who burns the sink's balance and
    /// then mints it back to exactly the same size: the contract cannot tell
    /// that from a lot nobody touched, and no view can. That is declared — an
    /// issuer with that power over the quote can freeze or seize the whole lot
    /// instead, which is worse and is already `VENUE` in `README.md` and B9 in
    /// `docs/plan.md`.
    function test_aLotThatShrankIsNotTheLotItsDescentPriced() public {
        ClawbackToken clawed = new ClawbackToken();
        clawed.mint(address(sink), 1e24);
        sink.open(address(clawed));
        _advance(1 hours);
        assertEq(sink.priceQ128(address(clawed)), FeastGenesis.SINK_START_PRICE_Q128 / 2, "a descent is running");

        clawed.clawback(address(sink), 4e23); // the issuer takes part of the lot back
        _advance(200 hours); // the time that used to be credited as a descent

        assertEq(
            sink.priceQ128(address(clawed)),
            FeastGenesis.SINK_START_PRICE_Q128,
            "a lot below what its descent priced is not priced by it"
        );

        // And it can be reopened by anyone, which is what keeps a shrunken lot
        // from being stuck: neither priced by its old descent nor able to start
        // a new one (round 3, both lenses).
        sink.open(address(clawed));
        assertEq(sink.lot(address(clawed)).offered, 6e23, "the new descent is over what is actually here");
        _advance(1 hours);
        assertEq(
            sink.priceQ128(address(clawed)),
            FeastGenesis.SINK_START_PRICE_Q128 / 2,
            "and it descends from the top, over the smaller lot"
        );
    }

    /// The limit of what the contract can see, asserted rather than implied: if
    /// nobody reopens a shrunken lot, a release that refills it to between once
    /// and twice the recorded size revives the descent that priced the larger
    /// lot, elapsed time and all. Only an asset that shrinks a holder's balance
    /// can reach this state; B9 declares it, and the mitigation is a keeper that
    /// opens a lot the moment it holds less than its descent priced.
    function test_theDeclaredLimitOfWhatAShrunkenLotCanBeToldFrom() public {
        ClawbackToken clawed = new ClawbackToken();
        clawed.mint(address(sink), 1e24);
        sink.open(address(clawed));
        clawed.clawback(address(sink), 4e23);
        _advance(200 hours); // nobody reopens it in all that time

        clawed.mint(address(sink), 1e24); // 1.6e24: neither arm of the predicate fires
        assertEq(sink.priceQ128(address(clawed)), 1, "the stale descent resumes - the declared limit");
    }

    /// The equivalence the two readers are built on, as a property rather than a
    /// sentence: for every lot, a descent prices it exactly when opening it is
    /// refused. Whenever `priceQ128` reads from the top, `open` is accepted;
    /// whenever it reads a descent, `open` reverts `AlreadyOpened`. Kills: any
    /// drift between the two predicates.
    function testFuzz_aDescentPricesALotExactlyWhenOpeningItIsRefused(uint256 held) public {
        uint256 offered = 1_000e18;
        held = bound(held, 1, 4 * offered);

        ClawbackToken asset = new ClawbackToken();
        asset.mint(address(sink), offered);
        sink.open(address(asset));
        _advance(1 hours); // so a live descent reads half the start price, never the top

        if (held > offered) asset.mint(address(sink), held - offered);
        if (held < offered) asset.clawback(address(sink), offered - held);

        bool readsFromTheTop = sink.priceQ128(address(asset)) == FeastGenesis.SINK_START_PRICE_Q128;
        try sink.open(address(asset)) {
            assertTrue(readsFromTheTop, "opened a lot its own descent was pricing");
        } catch (bytes memory reason) {
            assertEq(
                bytes4(reason),
                FeastPlatformSink.AlreadyOpened.selector,
                "refused for some other reason than a descent already pricing it"
            );
            assertFalse(readsFromTheTop, "refused to open a lot no descent was pricing");
        }
    }

    /// The one state outside that equivalence, named rather than left implied:
    /// an empty lot is priced by no descent and cannot be opened either, because
    /// there is nothing to offer.
    function test_anEmptyLotIsNeitherPricedNorOpenable() public {
        ClawbackToken asset = new ClawbackToken();
        asset.mint(address(sink), 100e18);
        sink.open(address(asset));
        asset.clawback(address(sink), 100e18);

        assertEq(sink.priceQ128(address(asset)), FeastGenesis.SINK_START_PRICE_Q128, "no descent prices nothing");
        vm.expectRevert(abi.encodeWithSelector(FeastPlatformSink.NothingToOffer.selector, address(asset)));
        sink.open(address(asset));
    }

    /// r4 (hunter lens). Package 2 deploys the sink against the platform coin's
    /// *predicted* address, and genesis creates the coin later — so there is a
    /// window, every asset's first weeks, in which every take would revert for
    /// want of a coin to pay in. A descent in that window is not a market, it is
    /// a timer: a party could donate a stake, open it, let the price run to its
    /// clamp while nobody on earth could outbid them, and then buy their stake
    /// back together with the platform's first fee release for one wei. B9 does
    /// not cover it — B9 rests on the stake being takeable by anyone throughout
    /// the descent, which before genesis is false for everyone.
    ///
    /// No descent starts before the coin exists. Kills: dropping that check.
    function test_noDescentStartsBeforeThePlatformCoinExists() public {
        address predicted = address(0xC01FEA57);
        FeastPlatformSink early = new FeastPlatformSink(predicted, address(this), address(guardian));
        MockERC20 asset = new MockERC20("A", "A", 18);
        asset.mint(address(early), 26e18); // a stake, deposited before genesis

        assertEq(predicted.code.length, 0, "precondition: the coin does not exist yet");
        vm.expectRevert(abi.encodeWithSelector(FeastPlatformSink.PlatformCoinNotLive.selector, predicted));
        early.open(address(asset));

        // The clock cannot have run: with no descent open there is no price.
        _advance(287 hours);
        vm.expectRevert(abi.encodeWithSelector(FeastPlatformSink.NotOpened.selector, address(asset)));
        early.priceQ128(address(asset));

        // Genesis creates the coin — and schedules the sink for the moment the
        // launch window closes, because until then the coin exists but sits in
        // a gated pool and an unsettled window, in nobody's hands (round 5).
        vm.etch(predicted, address(stock).code);
        FeastLaunchWindow itsWindow = new FeastLaunchWindow(
            address(wbnb), predicted, address(vault), address(pm), address(hook), address(factory), feastKey, uint64(block.timestamp + 13 days - FeastGenesis.WINDOW_DURATION)
        );
        early.schedule(address(itsWindow));
        uint64 closes2 = itsWindow.endsAt();
        vm.expectRevert(abi.encodeWithSelector(FeastPlatformSink.NotOpenYet.selector, closes2));
        early.open(address(asset));
        _warpTo(closes2 - 1);
        vm.expectRevert(abi.encodeWithSelector(FeastPlatformSink.NotOpenYet.selector, closes2));
        early.open(address(asset));

        // At the opening, and not before, the descent starts from the top.
        _warpTo(closes2);
        early.open(address(asset));
        assertEq(early.priceQ128(address(asset)), FeastGenesis.SINK_START_PRICE_Q128, "from the top, at genesis");

        // So the platform's first release is priced from the top too.
        asset.mint(address(early), 25e18);
        _advance(1 hours);
        assertGt(
            early.priceQ128(address(asset)),
            FeastGenesis.SINK_START_PRICE_Q128 / 4,
            "and one hour of descent is all that has happened to it"
        );
    }

    /// r5 (hunter lens). The round-4 gate asked whether the coin had code, which
    /// is not the same question as whether anyone can hold any. After genesis
    /// FEAST exists and its whole supply is out of reach: the pool is gated, the
    /// launch window has not settled, team vesting has not started, emissions
    /// and grants are shut. The window may legitimately close up to
    /// `MAX_GATE_DURATION` after genesis, which is long enough for a descent to
    /// reach its clamp with nobody on earth able to outbid the party who opened
    /// it. The sink therefore opens when the window closes, and genesis says so
    /// once. Kills: dropping the `opensAt` check.
    function test_theSinkOpensWhenTheWindowCloses() public {
        // The sink this fixture launched was scheduled at genesis for exactly
        // that moment, which is the wiring the deploy script performs.
        assertEq(sink.opensAt(), window.endsAt(), "scheduled for the moment the coin can be held");

        // The hunter's schedule, on a sink of its own: a window closing thirteen
        // days out, inside the fourteen the hook accepts.
        FeastPlatformSink late = new FeastPlatformSink(feast, genesisKey, address(guardian));
        FeastLaunchWindow thirteen = new FeastLaunchWindow(
            address(wbnb), feast, address(vault), address(pm), address(hook), address(factory), feastKey, uint64(block.timestamp + 13 days - FeastGenesis.WINDOW_DURATION)
        );
        uint64 closes = thirteen.endsAt();
        vm.prank(genesisKey);
        late.schedule(address(thirteen));

        MockERC20 asset = new MockERC20("A", "A", 18);
        asset.mint(address(late), 26e18); // the stake, deposited as early as you like

        vm.expectRevert(abi.encodeWithSelector(FeastPlatformSink.NotOpenYet.selector, closes));
        late.open(address(asset));
        _warpTo(closes - 1);
        vm.expectRevert(abi.encodeWithSelector(FeastPlatformSink.NotOpenYet.selector, closes));
        late.open(address(asset));

        // Property: before the opening there is no descent at all, so there is
        // no price — not a low one.
        vm.expectRevert(abi.encodeWithSelector(FeastPlatformSink.NotOpened.selector, address(asset)));
        late.priceQ128(address(asset));

        // At the opening the descent starts from the top, and the clock that
        // matters starts with it — so the platform's first release, whenever it
        // lands, meets a price that has descended only since anyone could pay.
        _warpTo(closes);
        late.open(address(asset));
        assertEq(late.priceQ128(address(asset)), FeastGenesis.SINK_START_PRICE_Q128, "from the top, at the opening");
        _advance(1 hours);
        assertEq(late.priceQ128(address(asset)), FeastGenesis.SINK_START_PRICE_Q128 / 2, "an hour is an hour");

        asset.mint(address(late), 25e18); // the platform's release: 51e18 held now
        assertGt(
            Math.mulDiv(51e18, late.priceQ128(address(asset)), ONE),
            1e18,
            "and the stake-plus-release sequence recovers nothing for one wei"
        );
    }

    /// r6 (both lenses). A time the key chooses is a promise: it could be brought
    /// forward to the start of the very period the opening exists to exclude. A
    /// window the key names is a mechanism — there is no time to bring forward,
    /// and the only discretion left is which window, which is the identity claim
    /// genesis already trusts the key for and which the sink checks the way the
    /// factory does. Kills: dropping either identity check, or taking the time
    /// from anywhere but the window.
    function test_theSinkIsScheduledOnceByNamingTheWindow() public {
        // v1.6.4 G2. `schedule` now refuses a window that has already closed, and
        // one closing further out than the hook's `MAX_GATE_DURATION`. In
        // production the call happens at genesis, before the window closes —
        // which is what the docstring has always said and what the deploy-script
        // witness exercises. This test builds a FRESH sink at the fixture's
        // post-genesis clock, so it has to stand where the real call stands.
        vm.warp(uint256(window.endsAt()) - 1 hours);
        FeastPlatformSink fresh = new FeastPlatformSink(feast, genesisKey, address(guardian));
        assertEq(fresh.opensAt(), 0, "unscheduled at deployment, so nothing opens");

        vm.expectRevert(FeastPlatformSink.NotGenesisKey.selector);
        fresh.schedule(address(window));

        // Not a window at all: something with the wrong role.
        address notAWindow = address(emissions);
        vm.prank(genesisKey);
        vm.expectRevert(abi.encodeWithSelector(FeastPlatformSink.NotTheLaunchWindow.selector, notAWindow));
        fresh.schedule(notAWindow);

        // A window, but another coin's.
        FeastLaunchWindow foreign = new FeastLaunchWindow(
            address(wbnb), address(stock), address(vault), address(pm), address(hook), address(factory), _keyFor(address(stock), address(wbnb)), uint64(block.timestamp + 1 days)
        );
        vm.prank(genesisKey);
        vm.expectRevert(abi.encodeWithSelector(FeastPlatformSink.WindowServesAnotherCoin.selector, address(foreign)));
        fresh.schedule(address(foreign));

        // The real one, once.
        vm.prank(genesisKey);
        fresh.schedule(address(window));
        assertEq(fresh.opensAt(), window.endsAt(), "the opening is the window's close, read from the window");

        uint64 set = fresh.opensAt(); // read first: vm.prank covers one call
        vm.prank(genesisKey);
        vm.expectRevert(abi.encodeWithSelector(FeastPlatformSink.AlreadyScheduled.selector, set));
        fresh.schedule(address(window));
    }

    /// And it fails closed: a window that will not say when it closes schedules
    /// nothing, and a sink that was never scheduled opens nothing.
    function test_aWindowThatWillNotSayWhenItClosesSchedulesNothing() public {
        FeastPlatformSink fresh = new FeastPlatformSink(feast, genesisKey, address(guardian));
        MuteWindow mute = new MuteWindow(feast);

        vm.prank(genesisKey);
        vm.expectRevert();
        fresh.schedule(address(mute));
        assertEq(fresh.opensAt(), 0, "nothing was scheduled");

        stock.mint(address(fresh), 1e24);
        vm.expectRevert(abi.encodeWithSelector(FeastPlatformSink.NotOpenYet.selector, uint64(0)));
        fresh.open(address(stock));
    }

    /// The whole path: the hook's exit sends a pool's platform share here, as
    /// the asset, to the contract that says it is the sink.
    function test_theExitDeliversThePlatformShareHere() public {
        (, PoolKey memory k) = _create(address(stock), bytes32(uint256(9)));
        _buy(k, address(stock), 100e18, trader, address(0));
        uint256 pending = hook.platformPending(PoolIdLibrary.toId(k));
        uint256 before = stock.balanceOf(address(sink));
        hook.releasePlatformFees(k);
        assertEq(stock.balanceOf(address(sink)) - before, pending, "delivered to the sink");
    }
}

/// The TGE script, run as the genesis key runs it.
contract FeastGenesisScriptTest is UnitFixture {
    /// Round 4 M2: everything the genesis script deploys must be deployable
    /// on the chain — the window, the team's vesting wallet and (through the
    /// factory) the platform coin, each within EIP-170's 24,576 bytes, and
    /// nothing else. Kills: deploying a script contract (42 KB) inside the
    /// broadcast just to compute a pool key.
    function test_theGenesisScriptDeploysOnlyWhatTheChainAccepts() public {
        vm.etch(genesisKey, address(new Genesis()).code);
        _warpTo(windowStart - 1 days);
        vm.startStateDiffRecording();
        Genesis.Launched memory l = Genesis(genesisKey).launch(
            Genesis.Inputs({
                factory: factory,
                emissions: address(emissions),
                grants: address(grants),
                sink: address(sink),
                beneficiary: beneficiary,
                windowStart: uint64(windowStart),
                sqrtPriceX96: SQRT_PRICE_1_1,
                metadataHash: keccak256("feast.metadata")
            })
        );
        Vm.AccountAccess[] memory accesses = vm.stopAndReturnStateDiff();
        uint256 created;
        for (uint256 i = 0; i < accesses.length; i++) {
            if (accesses[i].kind != VmSafe.AccountAccessKind.Create) continue;
            created++;
            address a = accesses[i].account;
            assertLe(a.code.length, 24_576, "within EIP-170");
            assertTrue(
                a == address(l.window) || a == address(l.teamVesting) || a == l.platformCoin,
                "the window, the team's vesting or the platform coin"
            );
        }
        assertEq(created, 3, "three contracts, no more");
    }

    /// r6 (both lenses). The sink's opening is part of genesis, and the script
    /// is what performs genesis. Round 5 wired the fixture and left the script
    /// alone, which is exactly the kind of gap a fixture hides: on the
    /// documented deployment path `opensAt` would have stayed zero and every
    /// `open` would have reverted for ever, until an extra privileged
    /// transaction nobody had written down. This runs the real script and
    /// checks the sink it leaves behind. Kills: a script that does not schedule.
    function test_theGenesisScriptLeavesTheSinkOpeningAtTheWindowsClose() public {
        vm.etch(genesisKey, address(new Genesis()).code);
        _warpTo(windowStart - 1 days);
        Genesis.Launched memory l = Genesis(genesisKey).launch(
            Genesis.Inputs({
                factory: factory,
                emissions: address(emissions),
                grants: address(grants),
                sink: address(sink),
                beneficiary: beneficiary,
                windowStart: uint64(windowStart),
                sqrtPriceX96: SQRT_PRICE_1_1,
                metadataHash: keccak256("feast.metadata")
            })
        );

        assertEq(sink.opensAt(), l.window.endsAt(), "the script scheduled the sink at the window's close");

        // Refused before that moment, accepted at it — on the deployment the
        // documentation describes, with nothing else done by hand.
        stock.mint(address(sink), 1e24);
        vm.expectRevert(abi.encodeWithSelector(FeastPlatformSink.NotOpenYet.selector, sink.opensAt()));
        sink.open(address(stock));
        _warpTo(l.window.endsAt());
        sink.open(address(stock));
        assertEq(sink.priceQ128(address(stock)), FeastGenesis.SINK_START_PRICE_Q128, "and it starts at the top");
    }

    /// r7 (both lenses). A script broadcasts each call separately, so the
    /// scheduling is its own transaction and not part of the one that creates
    /// the coin — the claim this pass had made, and corrected. What the script
    /// can do is refuse to call the launch finished while the sink is not
    /// scheduled, so an omission is loud rather than a sink that is quietly shut
    /// for ever. Kills: dropping that post-condition.
    function test_theScriptRefusesALaunchThatLeavesTheSinkUnscheduled() public {
        vm.etch(genesisKey, address(new Genesis()).code);
        _warpTo(windowStart - 1 days);
        // A sink that takes the scheduling call and reports no opening: whatever
        // the cause — a wrong address, a transaction that never landed — the
        // launch is not finished.
        vm.mockCall(address(sink), abi.encodeWithSignature("opensAt()"), abi.encode(uint64(0)));

        vm.expectRevert(
            abi.encodeWithSelector(
                Genesis.SinkNotScheduled.selector, address(sink), uint64(windowStart + FeastGenesis.WINDOW_DURATION)
            )
        );
        Genesis(genesisKey).launch(
            Genesis.Inputs({
                factory: factory,
                emissions: address(emissions),
                grants: address(grants),
                sink: address(sink),
                beneficiary: beneficiary,
                windowStart: uint64(windowStart),
                sqrtPriceX96: SQRT_PRICE_1_1,
                metadataHash: keccak256("feast.metadata")
            })
        );
    }
}

/// An asset that calls back into the sink while the sink is sending it, before
/// the balance moves — the shape an ERC-777-style hook token has. Used to show
/// that a descent cannot be opened in the middle of a take.
contract ReopeningToken is MockERC20 {
    FeastPlatformSink internal _sink;
    bool internal _armed;

    constructor() MockERC20("Hooked", "HOOK", 18) {}

    function armAgainst(FeastPlatformSink s) external {
        _sink = s;
        _armed = true;
    }

    function disarm() external {
        _armed = false;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (_armed && from == address(_sink)) {
            _armed = false;
            _sink.open(address(this));
        }
        super._update(from, to, value);
    }
}

/// An asset whose issuer can take a holder's balance back: a clawback, a
/// blacklist burn, a downward rebase. The sink's own balance can fall without a
/// take, which is the one way `offered` can record more than is here.
contract ClawbackToken is MockERC20 {
    constructor() MockERC20("Clawed", "CLAW", 18) {}

    function clawback(address from, uint256 amount) external {
        _burn(from, amount);
    }
}

/// A contract that says it is the launch window for this coin and then will not
/// say when it closes. The sink must schedule nothing rather than guess.
contract MuteWindow {
    bytes32 public constant genesisRole = keccak256("feast.genesis.launch-window");
    address public immutable platformCoin;

    error NotSaying();

    constructor(address platformCoin_) {
        platformCoin = platformCoin_;
    }

    function endsAt() external pure returns (uint64) {
        revert NotSaying();
    }
}
