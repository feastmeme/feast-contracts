// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {FeastConstants} from "../src/FeastConstants.sol";
import {FeastFactory} from "../src/FeastFactory.sol";
import {FeastGenesis} from "../src/FeastGenesis.sol";
import {FeastGenesisGrants} from "../src/FeastGenesisGrants.sol";
import {FeastMath} from "../src/FeastMath.sol";
import {FeastPlatformSink} from "../src/FeastPlatformSink.sol";
import {Currency} from "../src/venue/Currency.sol";
import {PoolKey} from "../src/venue/PoolKey.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {VenueBridge} from "./utils/VenueBridge.sol";

import {MockERC20} from "./utils/MockERC20.sol";
import {UnitFixture} from "./utils/UnitFixture.sol";

/// The v1.6.4 pre-audit pass's own witnesses, for the three findings the v1.6.3
/// dual-family pack proved and for the sweep that G1's closure pulled behind it.
///
/// The three proofs of concept live under `test/audit/poc/` and assert the
/// findings themselves. These assert the *bounds* — the properties the closures
/// are supposed to establish, at the extremes where they are weakest, which is
/// the place `docs/plan.md` section 6d records the v1.6.3 pass for not testing.
contract FeastV164BoundsTest is UnitFixture {
    using VenueBridge for PoolKey;

    // --- G1: the grant's quotient ----------------------------------------

    /// Built against a stub emissions contract so `referredNative` can be driven
    /// to any value through the contract's OWN path — `checkpoint` reads the
    /// emissions contract and writes what it is told, exactly as in production.
    /// Nothing is forced into storage.
    function _grants(uint256 target, uint256 referred)
        internal
        returns (FeastGenesisGrants g, MockERC20 coin)
    {
        address[8] memory ps;
        for (uint256 i = 0; i < 8; i++) {
            ps[i] = address(uint160(0xBB00 + i));
        }
        coin = new MockERC20("Feast", "FEAST", 18);
        g = new FeastGenesisGrants(address(coin), address(new V164StubEmissions(referred)), target, ps, address(guardian));
        g.checkpoint(address(0xBB00), 1);
    }

    /// The bound G1 establishes: `unlocked` is total. No `referredNative` makes
    /// it revert, and none makes it exceed the grant — which is what `claim` and
    /// `burnUnearned` need in order to be reachable at all.
    function testFuzz_unlockedIsTotalAndNeverExceedsTheGrant(uint256 referred, uint256 target) public {
        // The whole range the finding is about, up to 2**255, against a target
        // small enough that the quotient is enormous.
        referred = bound(referred, 0, type(uint256).max >> 1);
        target = bound(target, 1, 1e18);

        address partner = address(0xBB00);
        (FeastGenesisGrants g,) = _grants(target, referred);
        assertEq(g.referredNative(partner), referred, "the referral is in place");

        uint256 u = g.unlocked(partner); // must not panic
        assertLe(u, g.grant(), "never more than the grant");

        // And it is the published rule, wherever the rule can still be evaluated
        // in a word: min(grant, grant * referred / target).
        if (referred == 0 || g.grant() <= type(uint256).max / referred) {
            uint256 exact = g.grant() * referred / target;
            assertEq(u, exact > g.grant() ? g.grant() : exact, "the published rule, unchanged");
        }
    }

    /// A fully earned grant pays in full, at the extreme the PoC names.
    function test_aGrantEarnedManyTimesOverPaysExactlyTheGrant() public {
        address partner = address(0xBB00);
        (FeastGenesisGrants g, MockERC20 coin) = _grants(100e18, 2e53);
        assertEq(g.unlocked(partner), g.grant(), "clamped at the grant, not overflowed");

        // And it is payable: `claim` routes through `unlocked`, which is what the
        // overflow made unreachable.
        coin.mint(address(g), g.grant());
        g.claim(partner);
        assertEq(coin.balanceOf(partner), g.grant(), "a fully earned grant is paid in full");
    }

    // --- G1's sweep: the supply cap --------------------------------------

    function _createWithSupply(uint256 supply) internal returns (bool ok, bytes memory err) {
        MockERC20 q = new MockERC20("Q", "Q", 18);
        try factory.create(
            FeastFactory.CreateParams({
                name: "S",
                symbol: "S",
                supply: supply,
                quote: address(q),
                creator: creator,
                selfBurnBps: 2_000,
                referrerBps: 1_000,
                prebuyQuoteIn: 0,
                minCoinsOut: 0,
                vestingDuration: 0,
                sqrtPriceX96: SQRT_PRICE_1_1,
                startTick: 0,
                liquidity: uint128(1_000_000_000e18 * 999 / 1_000),
                salt: bytes32(supply),
                metadataHash: bytes32(0)
            })
        ) returns (address, PoolKey memory) {
            return (true, "");
        } catch (bytes memory e) {
            return (false, e);
        }
    }

    /// The refusal is by name, and it is the FIRST thing a large supply meets —
    /// before the hook's `supply * CAP_BPS_OF_SUPPLY / BPS`, which panicked.
    function test_createRefusesASupplyAboveTheCapByName() public {
        (bool ok, bytes memory err) = _createWithSupply(FeastConstants.MAX_SUPPLY + 1);
        assertFalse(ok, "refused");
        assertEq(
            err,
            abi.encodeWithSelector(FeastFactory.SupplyTooLarge.selector, FeastConstants.MAX_SUPPLY + 1),
            "refused by name, with the supply that broke the bound"
        );

        // And the panic is no longer reachable through `create` at any supply:
        // the two thresholds the measurement found both sit above the cap.
        (bool ok2, bytes memory e2) = _createWithSupply(type(uint256).max / 50 + 1);
        assertFalse(ok2, "refused");
        assertEq(bytes4(e2), FeastFactory.SupplyTooLarge.selector, "named, not panic 0x11");
        (bool ok3, bytes memory e3) = _createWithSupply(type(uint256).max);
        assertFalse(ok3, "refused");
        assertEq(bytes4(e3), FeastFactory.SupplyTooLarge.selector, "named, not panic 0x11");
    }

    /// The cap itself admits everything at or below it: a supply exactly at the
    /// cap is not refused BY THE CAP. (It is refused later, for depth — a uint128
    /// liquidity cannot seed that much coin — which is the venue's own bound and
    /// the reason this number was chosen.)
    function test_theCapItselfAdmitsASupplyExactlyAtIt() public {
        (bool ok, bytes memory err) = _createWithSupply(FeastConstants.MAX_SUPPLY);
        assertFalse(ok, "still refused, but not by the cap");
        assertTrue(bytes4(err) != FeastFactory.SupplyTooLarge.selector, "the cap admitted it");
    }

    /// And the cap refuses nothing anyone would launch.
    function test_theCapIsGenerousAgainstTheSupplyTheProtocolItselfUses() public pure {
        assertLt(FeastGenesis.PLATFORM_SUPPLY, FeastConstants.MAX_SUPPLY, "the platform coin fits");
        assertLt(
            FeastConstants.MAX_SUPPLY * uint256(FeastConstants.BPS),
            type(uint256).max,
            "every supply * bps product is bounded by construction"
        );
    }

    // --- G1's sweep: the rewrites move no number --------------------------

    /// Every row the sweep rewrote with `mulDiv` must agree with the expression
    /// it replaced everywhere the old one did not panic. One property, checked
    /// over the shape rather than site by site.
    function testFuzz_mulDivAgreesWithTheExpressionItReplaced(uint256 x, uint256 y, uint256 z) public pure {
        z = bound(z, 1, type(uint256).max);
        if (y != 0 && x > type(uint256).max / y) return; // the old spelling panicked here
        assertEq(Math.mulDiv(x, y, z), x * y / z, "no published number moves");
    }

    /// Round `v1.6.4` r1 (r1v): the sweep's completeness claim had missed the
    /// signed fee formulas, which multiplied the caller's `amountSpecified` by
    /// `FEE_PIPS` BEFORE narrowing it — and `toInt128` bounds the result, not the
    /// intermediate. An absurd swap amount panicked `0x11` on the product
    /// instead of being refused by the name the library exists to give it.
    /// Narrowing first bounds every product below by `2**127 x 10**4`.
    function test_anAbsurdSwapAmountIsRefusedByNameNotByPanic() public {
        (, PoolKey memory k) = _create(address(stock), bytes32(uint256(0xB1)));
        bool zeroForOne = Currency.unwrap(k.currency0) == address(stock);
        MockERC20(address(stock)).mint(address(router), 1e24);

        vm.prank(trader, trader);
        try router.swap(
            k.up(),
            ICLPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -(type(int256).max),
                sqrtPriceLimitX96: zeroForOne ? MIN_SQRT : MAX_SQRT
            }),
            ""
        ) {
            assertTrue(false, "an absurd swap amount must be refused");
        } catch (bytes memory err) {
            // The venue wraps the hook's revert, so the selector is looked for
            // inside the payload rather than at its head.
            assertTrue(_contains(err, FeastMath.Int128Overflow.selector), "refused by name");
            assertFalse(_contains(err, bytes4(0x4e487b71)), "and not by an arithmetic panic");
        }
    }

    function _contains(bytes memory haystack, bytes4 needle) internal pure returns (bool) {
        if (haystack.length < 4) return false;
        for (uint256 i = 0; i + 4 <= haystack.length; i++) {
            if (
                haystack[i] == needle[0] && haystack[i + 1] == needle[1] && haystack[i + 2] == needle[2]
                    && haystack[i + 3] == needle[3]
            ) return true;
        }
        return false;
    }

    // --- G2: the sink's schedule bound -----------------------------------

    function _sink() internal returns (FeastPlatformSink s, MockERC20 coin) {
        coin = new MockERC20("Feast", "FEAST", 18);
        s = new FeastPlatformSink(address(coin), genesisKey, address(guardian));
    }

    function test_aWindowClosingExactlyAtTheBoundIsAccepted() public {
        (FeastPlatformSink s, MockERC20 coin) = _sink();
        uint64 closes = uint64(block.timestamp + FeastGenesis.MAX_GATE_DURATION);
        V164StubWindow w = new V164StubWindow(address(coin), closes);
        vm.prank(genesisKey);
        s.schedule(address(w));
        assertEq(s.opensAt(), closes, "exactly at the bound is inside it");
    }

    function test_aWindowOneSecondPastTheBoundIsRefused() public {
        (FeastPlatformSink s, MockERC20 coin) = _sink();
        uint64 bound_ = uint64(block.timestamp + FeastGenesis.MAX_GATE_DURATION);
        V164StubWindow w = new V164StubWindow(address(coin), bound_ + 1);
        vm.prank(genesisKey);
        vm.expectRevert(
            abi.encodeWithSelector(FeastPlatformSink.WindowTooFarOut.selector, bound_ + 1, bound_)
        );
        s.schedule(address(w));
    }

    function test_anAlreadyClosedWindowIsRefused() public {
        (FeastPlatformSink s, MockERC20 coin) = _sink();
        uint64 closes = uint64(block.timestamp - 1);
        V164StubWindow w = new V164StubWindow(address(coin), closes);
        vm.prank(genesisKey);
        vm.expectRevert(abi.encodeWithSelector(FeastPlatformSink.WindowAlreadyClosed.selector, closes));
        s.schedule(address(w));
    }

    /// The bound is `<=`, matching the hook's own gate check: a window closing
    /// at this very second has already closed.
    function test_aWindowClosingThisSecondIsRefused() public {
        (FeastPlatformSink s, MockERC20 coin) = _sink();
        uint64 closes = uint64(block.timestamp);
        V164StubWindow w = new V164StubWindow(address(coin), closes);
        vm.prank(genesisKey);
        vm.expectRevert(abi.encodeWithSelector(FeastPlatformSink.WindowAlreadyClosed.selector, closes));
        s.schedule(address(w));
    }

    /// The sink accepts exactly the window closes inside its own two-ended
    /// bound, over the whole `uint64` range.
    ///
    /// Round `v1.6.4`, Claude lens: this was called
    /// `theSinkAcceptsExactlyWhatTheHookWouldGate`, and the plan said the two
    /// "refuse the same set". **They do not, and cannot.** The hook bounds
    /// `openAt`, which the genesis script sets to the window's close PLUS an
    /// hour of grace; the sink bounds the close itself. They are the same
    /// predicate on two quantities an hour apart, so a window closing inside the
    /// hour before genesis is admitted by one and refused by the other. The test
    /// re-implemented the predicate inline against the close, so it could not
    /// have seen the offset — it was named for a claim it was structurally
    /// unable to check. Renamed to what it does test.
    function testFuzz_theSinkAcceptsExactlyItsOwnTwoEndedBound(uint64 closes) public {
        (FeastPlatformSink s, MockERC20 coin) = _sink();
        V164StubWindow w = new V164StubWindow(address(coin), closes);
        bool insideTheBound =
            closes > block.timestamp && closes <= block.timestamp + FeastGenesis.MAX_GATE_DURATION;

        vm.prank(genesisKey);
        if (insideTheBound) {
            s.schedule(address(w));
            assertEq(s.opensAt(), closes, "accepted, and copied through");
        } else {
            vm.expectRevert();
            s.schedule(address(w));
        }
    }

    // --- G3: the slippage bound ------------------------------------------

    /// The property `MAX_SLIPPAGE_BPS` actually claims: squaring the limit lands
    /// within the tolerance of the spot price, on both sides, at every price the
    /// venue can hold.
    ///
    /// Round `v1.6.4` r1, both lenses: this used to fuzz only `[2^64, 2^128)`,
    /// the hook's fill domain, while `FeastMath`'s docstring and
    /// `plans/v164/plan.md` both advertised the whole `uint160` range — and the
    /// excluded top of the range was exactly where the unchecked narrowing could
    /// wrap a rising limit to a value BELOW spot. The helper now clamps into the
    /// venue's own bounds and this fuzzes the whole of them.
    function testFuzz_thePermittedMoveNeverExceedsTheTolerance(uint160 sqrtPriceX96, bool up) public pure {
        sqrtPriceX96 = uint160(
            bound(uint256(sqrtPriceX96), FeastMath.MIN_SQRT_RATIO + 1, FeastMath.MAX_SQRT_RATIO - 1)
        );

        uint160 limit =
            FeastMath.sqrtPriceLimit(sqrtPriceX96, FeastConstants.MAX_SLIPPAGE_BPS, FeastConstants.BPS, up);

        // Always inside the venue's own bounds — never zero, never wrapped past
        // an endpoint, never on the far side of the range. NOT the same as "the
        // venue will accept it": see `test_atAnExhaustedRangeTheLimitEqualsSpot`.
        assertGt(limit, FeastMath.MIN_SQRT_RATIO, "above the venue's floor");
        assertLt(limit, FeastMath.MAX_SQRT_RATIO, "below the venue's ceiling");

        // Never on the WRONG side of spot. Equality is reachable only where the
        // clamp bites — a pool already at the end of its range has no room left
        // to move, and a limit that permits nothing is the tight direction.
        if (up) assertGe(limit, sqrtPriceX96, "a rising limit is never below spot");
        else assertLe(limit, sqrtPriceX96, "a falling limit is never above spot");

        _assertWithinTolerance(sqrtPriceX96, limit, up);
    }

    /// One basis point is far too coarse a unit to assert this bound in. Round
    /// `v1.6.4` r2 (r2h): measuring the move in whole basis points FLOORS it, so
    /// a rising limit that permits 300.2201 bps measures 300 and passes an
    /// assertion of "at most 300". The assertion could not fail in the direction
    /// that matters — the same shape as a witness bounded away from its own
    /// claim, which is what this pass keeps finding.
    ///
    /// So the comparison is made at 1e12 rather than 1e4, which resolves the
    /// 2.2e-4 bps that separates the correct rounding from the incorrect one:
    /// rising floor gives 1_029_819_040_000 against a bound of 1_030_000_000_000
    /// and passes; rising ceiling gives 1_030_022_010_000 and fails.
    uint256 internal constant PRICE_SCALE = 1e12;

    function _assertWithinTolerance(uint160 spot, uint160 limit, bool up) internal pure {
        // Nested, so the measurement never forms `limit * limit`: at the top of
        // the domain that is 2**256 and would panic in the TEST, not the code.
        uint256 moved = Math.mulDiv(Math.mulDiv(limit, limit, spot), PRICE_SCALE, spot);
        if (up) {
            uint256 ceiling =
                PRICE_SCALE * (uint256(FeastConstants.BPS) + FeastConstants.MAX_SLIPPAGE_BPS) / FeastConstants.BPS;
            assertLe(moved, ceiling, "a rising limit permits no more than the documented tolerance");
        } else {
            uint256 floor_ =
                PRICE_SCALE * (uint256(FeastConstants.BPS) - FeastConstants.MAX_SLIPPAGE_BPS) / FeastConstants.BPS;
            assertGe(moved, floor_, "a falling limit permits no more than the documented tolerance");
        }
    }

    /// The clamp itself: at the very top of the venue's range a rising limit has
    /// nowhere to go, and must come back inside the range rather than wrapping.
    function test_theLimitIsClampedIntoTheVenuesRangeAtBothEnds() public pure {
        uint160 high = FeastMath.MAX_SQRT_RATIO - 1;
        uint160 up_ = FeastMath.sqrtPriceLimit(high, FeastConstants.MAX_SLIPPAGE_BPS, FeastConstants.BPS, true);
        assertEq(up_, FeastMath.MAX_SQRT_RATIO - 1, "clamped to the venue's ceiling, not wrapped");
        assertGt(up_, 0, "and emphatically not zero");

        uint160 low = FeastMath.MIN_SQRT_RATIO + 1;
        uint160 down = FeastMath.sqrtPriceLimit(low, FeastConstants.MAX_SLIPPAGE_BPS, FeastConstants.BPS, false);
        assertEq(down, FeastMath.MIN_SQRT_RATIO + 1, "clamped to the venue's floor");
    }

    /// And what that clamp MEANS at the endpoint, stated rather than implied.
    ///
    /// Round `v1.6.4` r2, found by both units: a pool whose price has reached the
    /// end of the venue's range gets a limit EQUAL to its own spot, and the venue
    /// rejects a limit equal to spot (`CLPool` requires strict inequality). So the
    /// swap is REFUSED, not executed. That is the correct outcome — there is no
    /// price left to move to on that side — but the plan had claimed the clamp
    /// always yields "a limit the venue will accept", which is not the same
    /// sentence. The refusal is asserted here so the guarantee is the tested one.
    function test_atAnExhaustedRangeTheLimitEqualsSpotAndTheSwapIsRefused() public pure {
        uint160 top = FeastMath.MAX_SQRT_RATIO - 1;
        assertEq(
            FeastMath.sqrtPriceLimit(top, FeastConstants.MAX_SLIPPAGE_BPS, FeastConstants.BPS, true),
            top,
            "at the top of the range a rising limit is spot itself, so the venue refuses the swap"
        );

        uint160 bottom = FeastMath.MIN_SQRT_RATIO + 1;
        assertEq(
            FeastMath.sqrtPriceLimit(bottom, FeastConstants.MAX_SLIPPAGE_BPS, FeastConstants.BPS, false),
            bottom,
            "at the bottom of the range a falling limit is spot itself, so the venue refuses the swap"
        );

        // One tick of room in from the end and the limit moves again, so the
        // equality above is the endpoint and not the whole neighbourhood.
        uint160 nearTop = FeastMath.MAX_SQRT_RATIO / 2;
        assertGt(
            FeastMath.sqrtPriceLimit(nearTop, FeastConstants.MAX_SLIPPAGE_BPS, FeastConstants.BPS, true),
            nearTop,
            "away from the endpoint a rising limit is strictly above spot"
        );
    }

    /// And the bound is not vacuous: it is close to the tolerance, not far
    /// inside it. A limit of "no move at all" would satisfy the test above.
    function test_thePermittedMoveIsCloseToTheToleranceNotFarInsideIt() public pure {
        uint160 spot = uint160(1 << 96);
        for (uint256 i = 0; i < 2; i++) {
            bool up = i == 0;
            uint160 limit =
                FeastMath.sqrtPriceLimit(spot, FeastConstants.MAX_SLIPPAGE_BPS, FeastConstants.BPS, up);
            uint256 movedBps = Math.mulDiv(uint256(limit) * limit, FeastConstants.BPS, uint256(spot) * spot);
            uint256 moveBps = up ? movedBps - FeastConstants.BPS : FeastConstants.BPS - movedBps;
            assertGe(moveBps, 295, "the bound is reached to within 5 basis points");
            assertLe(moveBps, FeastConstants.MAX_SLIPPAGE_BPS, "and never exceeds it");
        }
    }

    /// The defect itself, recorded: the expression that was there permitted
    /// twice the tolerance, and the one that replaced it does not.
    function test_theOldLinearScalingPermittedTwiceTheTolerance() public pure {
        uint256 spot = 1 << 96;
        uint256 old = spot * (uint256(FeastConstants.BPS) + FeastConstants.MAX_SLIPPAGE_BPS) / FeastConstants.BPS;
        uint256 oldMove = Math.mulDiv(old * old, FeastConstants.BPS, spot * spot) - FeastConstants.BPS;
        assertEq(oldMove, 608, "what v1.6.3 shipped");
        assertGt(oldMove, 2 * uint256(FeastConstants.MAX_SLIPPAGE_BPS) - 10, "about twice the tolerance");
    }
}

/// The three things `FeastGenesisGrants` asks of the emissions contract.
contract V164StubEmissions {
    uint256 internal immutable referred;

    constructor(uint256 referred_) {
        referred = referred_;
    }

    function settledCount() external pure returns (uint256) {
        return 1;
    }

    function claimsOpen() external pure returns (bool) {
        return true;
    }

    function referredValue(uint256, address) external view returns (uint256) {
        return referred;
    }
}

/// A contract that answers the three questions `schedule` asks, honestly.
contract V164StubWindow {
    address internal immutable coin;
    uint64 internal immutable closes;

    constructor(address coin_, uint64 closes_) {
        coin = coin_;
        closes = closes_;
    }

    function genesisRole() external pure returns (bytes32) {
        return keccak256("feast.genesis.launch-window");
    }

    function platformCoin() external view returns (address) {
        return coin;
    }

    function endsAt() external view returns (uint64) {
        return closes;
    }
}
