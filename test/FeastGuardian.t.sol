// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {FeastConstants} from "../src/FeastConstants.sol";
import {FeastEmissions} from "../src/FeastEmissions.sol";
import {FeastFactory} from "../src/FeastFactory.sol";
import {FeastGenesis} from "../src/FeastGenesis.sol";
import {FeastGenesisGrants} from "../src/FeastGenesisGrants.sol";
import {FeastGuardian} from "../src/FeastGuardian.sol";
import {FeastHook} from "../src/FeastHook.sol";
import {FeastLaunchWindow} from "../src/FeastLaunchWindow.sol";
import {FeastPlatformSink} from "../src/FeastPlatformSink.sol";
import {FeastTeamVesting} from "../src/FeastTeamVesting.sol";
import {FeastVesting} from "../src/FeastVesting.sol";
import {Currency} from "../src/venue/Currency.sol";
import {PoolId, PoolIdLibrary} from "../src/venue/PoolId.sol";
import {PoolKey} from "../src/venue/PoolKey.sol";

import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";

import {MockERC20} from "./utils/MockERC20.sol";
import {UnitFixture} from "./utils/UnitFixture.sol";
import {VenueBridge} from "./utils/VenueBridge.sol";

/// The guardian: a brake that can never touch the money.
///
/// Design and every ruling: `plans/audit/guardian-design.md`. feast has no
/// owner and this is the one exception, so the whole of this file is about
/// keeping that sentence honest — what the brake can stop, for how long, and
/// the fact that it can move nothing.
contract FeastGuardianTest is UnitFixture {
    using PoolIdLibrary for PoolKey;
    using VenueBridge for PoolKey;

    address internal stranger = address(0x5174A9E);
    PoolId internal anyPool = PoolId.wrap(bytes32(uint256(1)));

    /// @dev `_buy` mints to the router before it swaps, and a mint between
    ///      `vm.expectRevert` and the call under test consumes the cheatcode.
    ///      Everything that is not the swap happens first.
    function _expectFrozenBuy(PoolKey memory key, address quote) internal {
        MockERC20(quote).mint(address(router), 1e15);
        bool zeroForOne = Currency.unwrap(key.currency0) == quote;
        vm.expectRevert();
        vm.prank(trader, trader);
        router.swap(
            key.up(),
            ICLPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -1e15,
                sqrtPriceLimitX96: zeroForOne ? MIN_SQRT : MAX_SQRT
            }),
            ""
        );
    }

    // --- who may pull it ------------------------------------------------------

    function test_onlyTheGuardianFreezes() public {
        vm.prank(multisig);
        guardian.freeze();
        assertTrue(guardian.isFrozenAll(), "the guardian froze it");

        vm.prank(multisig);
        guardian.unfreeze();
        assertFalse(guardian.isFrozenAll(), "and lifted it");
    }

    function test_aStrangerIsRefused() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(FeastGuardian.NotTheGuardian.selector, stranger));
        guardian.freeze();

        vm.prank(multisig);
        guardian.freeze();

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(FeastGuardian.NotTheGuardian.selector, stranger));
        guardian.unfreeze();

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(FeastGuardian.NotTheGuardian.selector, stranger));
        guardian.stopCreation();
    }

    // --- how long it can last -------------------------------------------------

    /// It ends by itself. `unfreeze` is a courtesy, not a requirement — nobody
    /// has to trust the guardian to release it.
    function test_aFreezeExpiresByItselfAfterSeventyTwoHours() public {
        vm.prank(multisig);
        guardian.freeze();
        assertTrue(guardian.isFrozenAll(), "frozen");

        _advance(72 hours - 1);
        assertTrue(guardian.isFrozenAll(), "still frozen a second before");
        _advance(1);
        assertFalse(guardian.isFrozenAll(), "and gone with nobody touching it");
    }

    /// **A freeze cannot be extended by freezing again.** Without this the
    /// budget still caps the total at 168 hours, but a SINGLE continuous freeze
    /// could run the whole week — and "at most 72 hours at a stretch" is the
    /// promise, not "168 hours in pieces of any length". Found by the mutation
    /// `let a freeze be extended by refreezing`, which nothing here noticed.
    function test_aFreezeCannotBeExtendedByRefreezing() public {
        vm.prank(multisig);
        guardian.freeze();
        uint64 until = guardian.frozenUntil();

        _advance(1 hours);
        vm.expectRevert(abi.encodeWithSelector(FeastGuardian.AlreadyFrozen.selector, until));
        vm.prank(multisig);
        guardian.freeze();

        // A second later than the first would have ended, and not before.
        _advance(71 hours - 1);
        assertTrue(guardian.isFrozenAll(), "still the first freeze");
        _advance(1);
        assertFalse(guardian.isFrozenAll(), "which ended on its own schedule");
        assertEq(guardian.frozenUntil(), until, "never pushed out");
    }

    /// Lifting early gives the unused time back, so a cautious guardian is not
    /// punished for releasing the brake.
    function test_theGuardianMayUnfreezeEarly() public {
        vm.prank(multisig);
        guardian.freeze();
        assertEq(guardian.budgetLeft(), 168 hours - 72 hours, "the whole grant is charged up front");

        _advance(1 hours);
        vm.prank(multisig);
        guardian.unfreeze();
        assertEq(guardian.budgetLeft(), 168 hours - 1 hours, "and the unused tail comes back");
        assertFalse(guardian.isFrozenAll(), "lifted");
    }

    /// A long pause cannot be assembled out of short ones.
    function test_theCumulativeBudgetIsOneWeek() public {
        for (uint256 i = 0; i < 2; i++) {
            vm.prank(multisig);
            guardian.freeze();
            _advance(72 hours);
            // **v1.6.19: a lapse is settled before the next pull.** A freeze
            // that runs out has no transaction in it, so it gets one, and
            // `freeze` refuses until it has happened — that is what stops the
            // guardian bracketing the block a lapse opens. Permissionless, so
            // anybody can clear the way; the test does it as nobody in
            // particular.
            guardian.settleLapsed();
            vm.roll(vm.getBlockNumber() + 1);
        }
        assertEq(guardian.budgetLeft(), 24 hours, "two full pulls of the week");

        // The third is granted only what is left, and then there is nothing.
        vm.prank(multisig);
        guardian.freeze();
        assertEq(guardian.budgetLeft(), 0, "the last day");
        _advance(24 hours);
        assertFalse(guardian.isFrozenAll(), "and it lifts");
        guardian.settleLapsed();
        vm.roll(vm.getBlockNumber() + 1);

        vm.prank(multisig);
        vm.expectRevert(abi.encodeWithSelector(FeastGuardian.FreezeBudgetSpent.selector, 168 hours, 168 hours));
        guardian.freeze();
    }

    // --- and when it stops existing -------------------------------------------

    function test_afterDayNinetyFreezeRevertsForEver() public {
        // v1.6.13: the ninety days start at GENESIS, so there has to be one.
        // Before it, `sunsetAt()` is `type(uint64).max` and the brake is fully
        // live — which is the safe direction and its own test below.
        _genesis();
        // Read into a local FIRST: an external call between `vm.prank` and the
        // call being pranked consumes the prank, and `guardian.genesisStartedAt()` is
        // an external call.
        uint64 sunset = guardian.sunsetAt();
        _warpTo(sunset);
        vm.expectRevert(abi.encodeWithSelector(FeastGuardian.FreezePowerExpired.selector, sunset));
        vm.prank(multisig);
        guardian.freeze();

        // And a decade later, the same.
        _advance(3650 days);
        vm.expectRevert(abi.encodeWithSelector(FeastGuardian.FreezePowerExpired.selector, sunset));
        vm.prank(multisig);
        guardian.freeze();
    }

    /// A freeze placed on the last day can outlive the power that placed it.
    /// This is how it ends without the guardian.
    function test_anyoneMayExpireALingeringFreeze() public {
        _genesis();
        _warpTo(guardian.sunsetAt() - 1 hours);
        vm.prank(multisig);
        guardian.freeze();
        assertTrue(guardian.isFrozenAll(), "frozen on the last day");

        _advance(1 hours);
        assertTrue(guardian.isFrozenAll(), "and still frozen past the sunset");

        vm.prank(stranger);
        guardian.expire();
        assertFalse(guardian.isFrozenAll(), "a stranger ended it");
    }

    /// Before genesis the clock has not started: the brake is fully live and
    /// nothing that reads the deadline may act. A guardian whose genesis never
    /// comes keeps its brake, which is the safe direction.
    function test_beforeGenesisTheBrakeIsLiveAndTheDeadlineIsNotSet() public {
        assertFalse(guardian.clockStarted(), "no genesis, no clock");
        assertEq(guardian.sunsetAt(), type(uint64).max, "and no deadline");
        vm.prank(multisig);
        guardian.freeze();
        assertTrue(guardian.isFrozenAll(), "the brake works before genesis");
    }

    /// Nothing that reads the ninety-day deadline may act before genesis has
    /// set one. Both directions: a slot cannot be FILLED against a deadline
    /// nobody has set, and — the direction that destroys value — it cannot be
    /// BURNED against one either.
    function test_noSlotIsFilledOrBurnedBeforeGenesis() public {
        address[8] memory some;
        for (uint256 i = 0; i < 6; i++) some[i] = partnerList[i];
        FeastGenesisGrants g = new FeastGenesisGrants(feast, address(emissions), TARGET, some, address(guardian));

        assertFalse(guardian.clockStarted(), "no genesis yet");

        vm.prank(multisig);
        vm.expectRevert(FeastGenesisGrants.AssignmentWindowNotOpen.selector);
        g.assignPartner(6, address(0x1A7E));

        vm.expectRevert(FeastGenesisGrants.AssignmentWindowNotOpen.selector);
        g.burnUnfilledSlot(6);
    }

    /// And only the factory starts it, once.
    function test_onlyTheFactoryStartsTheClockAndOnlyOnce() public {
        vm.prank(multisig);
        vm.expectRevert(abi.encodeWithSelector(FeastGuardian.NotTheFactory.selector, multisig));
        guardian.startClock();

        _genesis();
        assertTrue(guardian.clockStarted(), "genesis started it");
        // Read into a local BEFORE the prank: an external call between
        // `vm.prank` and the call being pranked consumes the prank.
        uint64 startedAt = guardian.genesisStartedAt();
        vm.expectRevert(abi.encodeWithSelector(FeastGuardian.ClockAlreadyStarted.selector, startedAt));
        vm.prank(address(factory));
        guardian.startClock();
    }

    function test_expireIsRefusedBeforeTheSunset() public {
        vm.prank(multisig);
        guardian.freeze();
        vm.expectRevert(
            abi.encodeWithSelector(FeastGuardian.NotYetExpired.selector, guardian.sunsetAt())
        );
        guardian.expire();
    }

    // --- the one-way switch ---------------------------------------------------

    /// Deliberately NOT sunset: after day 90 it is the guardian's only power,
    /// and it cannot move a balance or touch a pool that exists.
    function test_stopCreationIsOneWay() public {
        vm.prank(multisig);
        guardian.stopCreation();
        assertTrue(guardian.creationStopped(), "stopped");

        vm.prank(multisig);
        vm.expectRevert(FeastGuardian.CreationAlreadyStopped.selector);
        guardian.stopCreation();

        vm.expectRevert(FeastFactory.CreationStopped.selector);
        _create(address(wbnb), bytes32(uint256(9)));
    }

    function test_stopCreationOutlivesTheSunset() public {
        _warpTo(guardian.genesisStartedAt() + 91 days);
        vm.prank(multisig);
        guardian.stopCreation();
        assertTrue(guardian.creationStopped(), "the only power that outlives day 90");
    }

    // --- what a freeze reaches ------------------------------------------------

    /// Every guarded path refuses while frozen and works after. The list is the
    /// design's §2 table; `test_theEveryExternalFunctionGuardEnumeration` is
    /// what keeps the two agreeing.
    function test_everyGuardedPathRevertsWhileFrozenAndWorksAfter() public {
        _launch(10e18);
        _firstPlatformTrade();

        vm.prank(multisig);
        guardian.freeze();

        // the hook
        _expectFrozenBuy(feastKey, address(wbnb));
        vm.expectRevert(FeastHook.Frozen.selector);
        hook.collectLpFees(feastKey);
        vm.expectRevert(FeastHook.Frozen.selector);
        hook.releasePlatformFees(feastKey);
        vm.expectRevert(FeastHook.Frozen.selector);
        hook.claimCreator(feastKey);

        // the sink, emissions, the vestings and the grants
        vm.expectRevert(FeastPlatformSink.Frozen.selector);
        sink.burnStray();
        vm.expectRevert(FeastEmissions.Frozen.selector);
        emissions.settle(1);
        vm.expectRevert(FeastVesting.Frozen.selector);
        vesting.claim(feast);
        vm.expectRevert(FeastTeamVesting.Frozen.selector);
        teamVesting.release(feast);
        vm.expectRevert(FeastGenesisGrants.Frozen.selector);
        grants.claim(partnerList[0]);

        // and an `ALL` freeze reaches the factory's door
        vm.expectRevert(FeastFactory.Frozen.selector);
        _create(address(wbnb), bytes32(uint256(11)));

        // After it lifts, every one of them works again — or fails for its own
        // reasons, which is not this test's business. The two that are
        // unambiguous are asserted; the rest are asserted by no longer saying
        // `Frozen`.
        _advance(72 hours);
        hook.collectLpFees(feastKey);
        sink.burnStray();
        _create(address(wbnb), bytes32(uint256(12)));
    }

    /// **A freeze stops EVERY pool, and there is no other kind** (v1.6.17).
    ///
    /// This test used to be `test_aPerPoolFreezeLeavesEveryOtherPoolTrading`,
    /// and it passed: a per-pool freeze was surgical, one pool stopping while
    /// every other kept trading. The owner removed that power on 2026-09-22.
    /// The surgical freeze was the instrument every defeat of the opening
    /// purchase cap needed — five redesigns, each beaten by a guardian that
    /// could stop everyone else in one pool while still trading there itself.
    /// A freeze that covers everything refuses the guardian's own trades too.
    ///
    /// What it costs is written down rather than glossed: a defect in one
    /// coin's pool can now only be answered by pausing outflows everywhere.
    function test_aFreezeStopsEveryPoolBecauseThereIsNoOtherKind() public {
        (, PoolKey memory other) = _create(address(wbnb), bytes32(uint256(3)));
        _launch(10e18);

        vm.prank(multisig);
        guardian.freeze();

        _expectFrozenBuy(feastKey, address(wbnb));
        _expectFrozenBuy(other, address(wbnb));

        // **And creation stops too, which a pool-scoped freeze never did.**
        // `FeastFactory.create` has always asked `isFrozenAll`; what changed is
        // that the only freeze there is now answers yes. A scoped freeze named
        // a pool that already existed and had nothing to say about making a new
        // one, so this line used to assert the opposite. Recorded as a widening
        // of what the brake reaches, not slipped in: pausing outflows now also
        // pauses the factory's door for as long as it lasts.
        vm.expectRevert(FeastFactory.Frozen.selector);
        factory.create(
            FeastFactory.CreateParams({
                name: "Coin", symbol: "COIN", supply: 1_000_000_000e18, quote: address(wbnb),
                creator: creator, selfBurnBps: 2_000, referrerBps: 1_000,
                prebuyQuoteIn: 0, minCoinsOut: 0, vestingDuration: 0,
                sqrtPriceX96: SQRT_PRICE_1_1, startTick: 0,
                liquidity: uint128(1_000_000_000e18 * 999 / 1_000),
                salt: bytes32(uint256(4)), metadataHash: bytes32(0)
            })
        );
    }

    /// **The brake holds the window's settlement, and nothing else of the
    /// window's** (v1.6.24, AstraSec M-2). Until v1.6.24 the window was not
    /// freezable at all, and that was a decision: its refunds ran on a one-hour
    /// clock, and a freeze could only have pushed them past it. With no
    /// deadline for `settle`, holding it costs nothing but time, and it is the
    /// one irreversible act here — it fixes the price for ever. `commit`,
    /// `withdraw`, `claim` and `refund` move the committers' own money and stay
    /// open: the money in the window is still the one money in the system that
    /// is theirs.
    function test_theWindowSettlesAndRefundsDuringAFreeze() public {
        _genesis();
        // Frozen BEFORE the window even opens.
        vm.prank(multisig);
        guardian.freeze();

        _warpTo(windowStart + 1);
        address committer = address(0xC0D1);
        vm.deal(committer, 4e18);
        vm.prank(committer);
        window.commit{value: 4e18}();
        assertEq(window.total(), 4e18, "a freeze does not reach a commit");

        _warpTo(window.endsAt());
        vm.expectRevert(FeastLaunchWindow.Frozen.selector);
        window.settle();

        vm.prank(multisig);
        guardian.unfreeze();
        _advance(1);
        window.settle();
        assertTrue(window.settled(), "and settles once the brake is off");

        vm.prank(multisig);
        guardian.freeze();
        assertGt(window.claim(committer), 0, "a freeze does not reach its claims");
    }

    function test_anUnsettledWindowStillRefundsDuringAFreeze() public {
        _genesis();
        _warpTo(windowStart + 1);
        address committer = address(0xC0D2);
        vm.deal(committer, 4e18);
        vm.prank(committer);
        window.commit{value: 4e18}();

        // Nobody settles before the auction is abandoned, and then the brake is
        // pulled: the refund is the committers' own escape hatch, and a freeze
        // must never block it. (A freeze BEFORE `abandonAt` moves `abandonAt`
        // by every frozen second; one after it cannot move it back.)
        _warpTo(window.abandonAt());
        vm.prank(multisig);
        guardian.freeze();
        _advance(1 hours);
        assertTrue(guardian.isFrozenAll(), "frozen");
        window.refund(committer);
        assertEq(wbnb.balanceOf(committer), 4e18, "in full, in wrapped native, while frozen");
    }

    // --- and what it can never do ---------------------------------------------

    /// **The sentence the whole design exists to keep true.** Every external
    /// function of every contract, called by the guardian itself, with every
    /// tracked balance measured before and after. The guardian's own two powers
    /// are excluded because they are the subject, not the violation.
    function testFuzz_theGuardianCannotMoveAWei(uint256 selector, uint256 amount) public {
        _launch(10e18);
        _firstPlatformTrade();
        amount = bound(amount, 0, 1e24);

        address[6] memory holders =
            [address(vault), address(hook), address(sink), address(emissions), address(vesting), address(window)];
        uint256[6] memory before;
        for (uint256 i = 0; i < 6; i++) before[i] = IERC20(feast).balanceOf(holders[i]);
        uint256 guardianBefore = IERC20(feast).balanceOf(multisig);

        address[7] memory targets = [
            address(hook), address(factory), address(sink), address(emissions),
            address(vesting), address(grants), address(teamVesting)
        ];
        address target = targets[selector % 7];

        // A blind four-byte poke with the guardian's own hands. Whatever it
        // reaches — a real function, a fallback, nothing — no balance may move.
        vm.prank(multisig);
        (bool ok,) = target.call(abi.encodePacked(bytes4(uint32(selector)), amount, uint256(0), uint256(0)));
        ok; // the outcome is not the claim; the balances are

        for (uint256 i = 0; i < 6; i++) {
            assertEq(IERC20(feast).balanceOf(holders[i]), before[i], "a balance moved under the guardian's hand");
        }
        assertEq(IERC20(feast).balanceOf(multisig), guardianBefore, "and the guardian gained nothing");
    }

    // --- the history (v1.6.27, `CA-6b91a230c6`) ------------------------------------

    /// @dev Every stretch of time this test held the brake down, as it counted it.
    uint256[] internal heldFrom;
    uint256[] internal heldTo;

    /// @dev Hold the brake for `d` seconds from now: lifted early when `d` is
    ///      short of the grant, lapsed and settled when it is not.
    function _hold(uint256 d) internal {
        uint256 from = clock;
        vm.prank(multisig);
        guardian.freeze();
        uint256 granted = uint256(guardian.frozenUntil()) - from;
        if (d >= granted) {
            _advance(granted);
            guardian.settleLapsed();
            d = granted;
        } else {
            if (d != 0) _advance(d);
            vm.prank(multisig);
            guardian.unfreeze();
        }
        heldFrom.push(from);
        heldTo.push(from + d);
    }

    /// @dev Frozen seconds up to `t`, from the test's own record.
    function _model(uint256 t) internal view returns (uint256 s) {
        for (uint256 i = 0; i < heldFrom.length; i++) {
            uint256 hi = heldTo[i] < t ? heldTo[i] : t;
            if (hi > heldFrom[i]) s += hi - heldFrom[i];
        }
    }

    function _at(uint256 t) internal view returns (uint256) {
        return guardian.frozenSecondsAt(uint64(t));
    }

    /// **The frozen seconds at any past instant, exactly** — before, inside and
    /// after a freeze lifted early, one that lapsed, and the one still live;
    /// and a lapsed freeze nobody has settled counts to its end, as
    /// `frozenSeconds()` does. An instant not yet reached reads as now.
    function test_frozenSecondsAtReadsEveryPastInstantExactly() public {
        uint256 start = clock;
        _advance(1 hours);
        _hold(10 hours); // lifted early
        _advance(5 hours);
        _hold(100 hours); // granted 72 h: lapses, and is settled
        _advance(2 hours);
        uint256 live = clock;
        vm.prank(multisig);
        guardian.freeze();
        _advance(30 minutes);

        assertEq(_at(start), 0, "nothing before the first freeze");
        assertEq(_at(heldFrom[0]), 0, "nothing at its first second");
        assertEq(_at(heldFrom[0] + 1), 1, "one second into it");
        assertEq(_at(heldTo[0]), 10 hours, "all of it at its end");
        assertEq(_at(heldTo[0] + 4 hours), 10 hours, "and nothing more between freezes");
        assertEq(_at(heldFrom[1] + 1 hours), 11 hours, "an hour into the lapsed one");
        assertEq(_at(heldTo[1]), 82 hours, "the lapsed one counts its whole grant");
        assertEq(_at(live), 82 hours, "the live one has not started at its first second");
        assertEq(_at(live + 10 minutes), 82 hours + 10 minutes, "ten minutes into the live one");
        assertEq(_at(clock), guardian.frozenSeconds(), "now is frozenSeconds()");
        assertEq(_at(clock + 1 days), guardian.frozenSeconds(), "and so is any instant not yet reached");

        // The live freeze lapses with nobody settling it: it still counts to its end.
        _warpTo(live + 80 hours);
        assertEq(guardian.frozenFrom(), live, "precondition: lapsed, not folded");
        assertEq(_at(live + 75 hours), 82 hours + 72 hours, "a lapsed freeze counts to where it lapsed");
        assertEq(_at(live + 1 hours), 83 hours, "and inside it, to the instant");
    }

    /// The same, against a history the test keeps itself: up to eight pulls at
    /// random gaps, a quarter of them holding nothing and the rest up to 80
    /// hours (so some lapse), read at 32 random past instants and at every
    /// freeze's two ends.
    function testFuzz_frozenSecondsAtIsTheHistoryAtEveryInstant(uint256 seed) public {
        uint256 start = clock;
        for (uint256 i = 0; i < 8; i++) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            _advance(1 + r % 2 days);
            if (guardian.budgetLeft() == 0) break;
            _hold((r >> 32) % 4 == 0 ? 0 : (r >> 64) % 80 hours);
        }
        _advance(1);
        for (uint256 i = 0; i < heldFrom.length; i++) {
            assertEq(_at(heldFrom[i]), _model(heldFrom[i]), "at a freeze's start");
            assertEq(_at(heldTo[i]), _model(heldTo[i]), "at a freeze's end");
        }
        for (uint256 j = 0; j < 32; j++) {
            uint256 t = start + uint256(keccak256(abi.encode(seed, "t", j))) % (clock - start);
            assertEq(_at(t), _model(t), "frozenSecondsAt is not the history");
        }
        assertEq(_at(clock), _model(clock), "and now");
        assertEq(guardian.frozenSeconds(), _model(clock), "which is frozenSeconds()");
    }
}
