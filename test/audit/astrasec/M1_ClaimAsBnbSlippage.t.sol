// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TickMath} from "uniswap-v4-core/src/libraries/TickMath.sol";

import {FeastConstants} from "../../../src/FeastConstants.sol";
import {FeastConverter} from "../../../src/FeastConverter.sol";
import {FeastHook} from "../../../src/FeastHook.sol";

import {MockERC20} from "../../utils/MockERC20.sol";
import {MockV3Factory, MockV3Pool} from "../../utils/MockV3Pool.sol";
import {PoolKey} from "../../../src/venue/PoolKey.sol";
import {UnitFixture} from "../../utils/UnitFixture.sol";

/// AstraSec M-1, "Potential sandwich attack on `FeastHook::claimAsBnb()`".
///
/// The finding: `claimAsBnb` converts a beneficiary's fee earnings to wrapped
/// native along a route the beneficiary supplies, and at e5c0a77 NEITHER
/// `FeastHook.claimAsBnb` nor `FeastConverter.convert` took a caller-supplied
/// `minOut`. The only two protections were
///
///   (1) per-hop ADMISSION: `FeastConverter._validateHop` refuses a hop whose
///       spot tick is more than `MAX_TICK_DEVIATION = 300` ticks from that
///       pool's own time-weighted tick (`1.0001^300` = +3.045% / -2.955%);
///
///   (2) a route-level floor: the realised output must be at least
///       `(10_000 - 300)/10_000` of `expectedOut`;
///
/// and `expectedOut` is built from the square-root prices read INSIDE the
/// admission check, so the 3% floor is a floor under an already-deflated
/// number and the two protections MULTIPLY: 88.65% of the clean quote over
/// three hops, every check satisfied.
///
/// **Fixed in v1.6.24**: `claimAsBnb(key, account, route, minOut)` forwards the
/// claimant's bound to `convert(tokenIn, amountIn, route, recipient, minOut)`,
/// which checks it LAST, after the route floor, and reverts
/// `BelowMinOut(got, minOut)`. Zero is "no bound of my own" and leaves exactly
/// the old protection — the route floor is kept, and checked first. Every
/// attack scenario below is kept: each now shows the sandwich refused by a
/// claimant's bound, and each also records what zero still permits, so the
/// meaning of zero is pinned rather than described.
///
/// The harness is the repo's own `MockV3Pool`, whose swap executes at exactly
/// `sqrtPriceX96` with an `outputBps` dial standing in for execution shortfall;
/// that is the abstraction `test/FeastConverterBounds.t.sol` already uses for
/// every other bound in this contract. A real pool would be WORSE, not better:
/// the victim's own swap walks the price further down from the edge the
/// attacker parked it at — which is exactly what a bound fixed before sending
/// absorbs and an anchor read at execution does not.
contract M1RouteFloorIsAnchoredToManipulatedSpot is Test {
    FeastConverter internal converter;
    MockV3Factory internal v3Factory;
    MockV3Pool internal pool;
    MockERC20 internal quote;
    MockERC20 internal wbnb;

    uint24 internal constant FEE = 500;
    uint256 internal constant AMOUNT = 10e18;
    /// The tolerance a claimant's app applies to the quote it showed them.
    uint256 internal constant TOLERANCE_BPS = 50;

    function setUp() public {
        vm.warp(1_000_000);
        quote = new MockERC20("Quote", "Q", 18);
        wbnb = new MockERC20("Wrapped", "W", 18);
        v3Factory = new MockV3Factory();
        pool = new MockV3Pool(address(quote), address(wbnb));
        v3Factory.set(address(quote), address(wbnb), FEE, address(pool));
        converter = new FeastConverter(address(v3Factory), address(wbnb), address(this));

        pool.setOldestTimestamp(uint32(block.timestamp - 3_600));
        pool.setTicks(0, 0);
        pool.setOutputBps(10_000);
        wbnb.mint(address(pool), 1_000_000e18);
        quote.mint(address(this), 1_000_000e18);
        quote.approve(address(converter), type(uint256).max);
    }

    // --- helpers ----------------------------------------------------------

    /// @dev Park `p`'s spot at the far edge of the admitted band, in whichever
    ///      direction DEFLATES the output of a hop whose input is `tokenIn`:
    ///      `_expectedAfterHop` multiplies by `(sqrtP/2^96)^2` when the input is
    ///      token0 and by its inverse otherwise. Spot tick, average tick and
    ///      square-root price are all set consistently, so `_validateHop` sees
    ///      a deviation of exactly `MAX_TICK_DEVIATION` — admitted, since the
    ///      comparison is `>`.
    function _parkAtBandEdge(MockV3Pool p, address tokenIn) internal {
        int24 edge = FeastConstants.MAX_TICK_DEVIATION;
        bool zeroForOne = tokenIn == p.token0();
        int24 spot = zeroForOne ? -edge : edge;
        p.setTicks(spot, 0);
        p.setSqrtPrice(TickMath.getSqrtPriceAtTick(spot));
    }

    function _oneHop() internal view returns (FeastConverter.Hop[] memory r) {
        r = new FeastConverter.Hop[](1);
        r[0] = FeastConverter.Hop({tokenOut: address(wbnb), fee: FEE});
    }

    /// @dev What a claimant's app would pass: the clean quote it showed them,
    ///      less the tolerance they chose.
    function _bound(uint256 clean) internal pure returns (uint256) {
        return clean * (10_000 - TOLERANCE_BPS) / 10_000;
    }

    // --- (a) the claimant's bound is on the path --------------------------

    /// At e5c0a77 this proved there was NO output bound in either signature.
    /// It is the same assertion against the fixed signatures: the bound is the
    /// last argument of both, so it is the caller's, end to end.
    function test_theClaimantsBoundIsOnTheClaimAsBnbPath() public pure {
        assertEq(
            FeastHook.claimAsBnb.selector,
            bytes4(
                keccak256(
                    "claimAsBnb((address,address,address,address,uint24,bytes32),address,(address,uint24)[],uint256)"
                )
            ),
            "claimAsBnb takes a key, an account, a route and the claimant's minOut"
        );
        assertEq(
            FeastConverter.convert.selector,
            bytes4(keccak256("convert(address,uint256,(address,uint24)[],address,uint256)")),
            "convert takes tokenIn, amountIn, route, recipient and minOut"
        );
    }

    // --- (b) the measured attacks, now refused ----------------------------

    /// The band alone. Spot parked at the admitted edge and execution exactly
    /// at that spot paid 97.04% of the pre-manipulation quote, with no revert.
    /// A claimant who bounds at 99.5% of the quote they were shown is refused
    /// by name; one who passes zero still gets the old 97.04%.
    function test_oneHop_theAdmittedBandAloneIsRefusedByTheClaimantsBound() public {
        uint256 clean = converter.convert(address(quote), AMOUNT, _oneHop(), address(this), 0);

        _parkAtBandEdge(pool, address(quote));
        uint256 snap = vm.snapshotState();
        uint256 dirty = converter.convert(address(quote), AMOUNT, _oneHop(), address(this), 0);
        // 1.0001^-300 = 0.9704466 -> 9704 bps, i.e. 2.96% lost — what zero still permits.
        assertApproxEqAbs(dirty * 10_000 / clean, 9_704, 2, "zero keeps exactly the old protection");

        vm.revertToState(snap);
        vm.expectRevert(abi.encodeWithSelector(FeastConverter.BelowMinOut.selector, dirty, _bound(clean)));
        converter.convert(address(quote), AMOUNT, _oneHop(), address(this), _bound(clean));
    }

    /// Band and floor COMPOSE: on top of the parked spot the execution lands at
    /// the route floor the deflated expectation implies — 94.13%, still inside
    /// the floor, because the floor is measured against the manipulated
    /// expectation. The claimant's bound refuses it.
    function test_oneHop_theBandAndTheRouteFloorTogetherAreRefusedByTheClaimantsBound() public {
        uint256 clean = converter.convert(address(quote), AMOUNT, _oneHop(), address(this), 0);

        _parkAtBandEdge(pool, address(quote));
        pool.setOutputBps(FeastConstants.BPS - converter.MAX_ROUTE_DEVIATION_BPS());
        uint256 snap = vm.snapshotState();
        uint256 dirty = converter.convert(address(quote), AMOUNT, _oneHop(), address(this), 0);
        // 0.9704466 * 0.97 = 0.941333 -> 9413 bps, i.e. 5.87% lost.
        assertApproxEqAbs(dirty * 10_000 / clean, 9_413, 3, "zero: band x floor, as before");

        vm.revertToState(snap);
        vm.expectRevert(abi.encodeWithSelector(FeastConverter.BelowMinOut.selector, dirty, _bound(clean)));
        converter.convert(address(quote), AMOUNT, _oneHop(), address(this), _bound(clean));
    }

    /// The auditor's worst case, at the full `MAX_HOPS = 3`: each pool's spot
    /// parked at its own admitted edge, the single route floor spent once.
    /// 8865 bps of the clean quote with zero — the `0.97045^3 * 0.97` the
    /// finding states — and refused outright by the claimant's bound.
    function test_threeHops_theWorstCaseIsRefusedByTheClaimantsBound() public {
        (MockERC20 midA, MockERC20 midB, MockV3Pool p1, MockV3Pool p2, MockV3Pool p3) = _threeHopRoute();
        FeastConverter.Hop[] memory route = new FeastConverter.Hop[](3);
        route[0] = FeastConverter.Hop({tokenOut: address(midA), fee: FEE});
        route[1] = FeastConverter.Hop({tokenOut: address(midB), fee: FEE});
        route[2] = FeastConverter.Hop({tokenOut: address(wbnb), fee: FEE});

        uint256 clean = converter.convert(address(quote), AMOUNT, route, address(this), 0);

        _parkAtBandEdge(p1, address(quote));
        _parkAtBandEdge(p2, address(midA));
        _parkAtBandEdge(p3, address(midB));
        // The route floor is one check over the whole route, so it is spent once.
        p3.setOutputBps(FeastConstants.BPS - converter.MAX_ROUTE_DEVIATION_BPS());

        uint256 snap = vm.snapshotState();
        uint256 dirty = converter.convert(address(quote), AMOUNT, route, address(this), 0);
        uint256 bps = dirty * 10_000 / clean;
        emit log_named_uint("three hops, worst case, minOut 0: realised bps of the clean quote", bps);
        assertApproxEqAbs(bps, 8_865, 5, "zero: three hops at the edge still cost ~11.35%");

        vm.revertToState(snap);
        vm.expectRevert(abi.encodeWithSelector(FeastConverter.BelowMinOut.selector, dirty, _bound(clean)));
        converter.convert(address(quote), AMOUNT, route, address(this), _bound(clean));
    }

    /// The bound reaches exactly the realised amount: equal passes, one wei
    /// more refuses, with both numbers in the refusal. A witness that only
    /// tested a bound far above the output would pass a check of `<=` as well
    /// as one of `<`.
    function test_theBoundBindsAtExactlyTheRealisedAmount() public {
        _parkAtBandEdge(pool, address(quote));
        uint256 snap = vm.snapshotState();
        uint256 realised = converter.convert(address(quote), AMOUNT, _oneHop(), address(this), 0);

        vm.revertToState(snap);
        assertEq(
            converter.convert(address(quote), AMOUNT, _oneHop(), address(this), realised), realised, "equal passes"
        );

        vm.revertToState(snap);
        vm.expectRevert(abi.encodeWithSelector(FeastConverter.BelowMinOut.selector, realised, realised + 1));
        converter.convert(address(quote), AMOUNT, _oneHop(), address(this), realised + 1);
    }

    /// The order of the two checks is the meaning of zero: the floor is asked
    /// first, so an execution under the floor reports the floor's refusal
    /// whatever bound the caller passed beneath it.
    function test_theRouteFloorIsStillCheckedFirst() public {
        pool.setOutputBps(9_000); // below any floor
        vm.expectPartialRevert(FeastConverter.RouteReturnedTooLittle.selector);
        converter.convert(address(quote), AMOUNT, _oneHop(), address(this), 1);
    }

    /// The load-bearing half of the finding, isolated, and still TRUE — the
    /// fix does not move it: the 3% route floor is computed FROM the
    /// manipulated expectation. Forcing a revert in both states and reading
    /// `RouteReturnedTooLittle(got, expected, floor)` shows `expected` and
    /// `floor` both shrink by the band factor once spot is parked. This is why
    /// the outcome needed a bound fixed before sending, and why the converter's
    /// docstrings no longer call the floor the bound on the outcome.
    function test_theRouteFloorIsComputedFromAManipulatedExpectation() public {
        pool.setOutputBps(9_000); // below any floor, so the revert carries the numbers

        (, uint256 expectedClean, uint256 floorClean) = _revertNumbers();

        _parkAtBandEdge(pool, address(quote));
        (, uint256 expectedDirty, uint256 floorDirty) = _revertNumbers();

        emit log_named_uint("expectedOut, clean spot", expectedClean);
        emit log_named_uint("expectedOut, spot parked at the band edge", expectedDirty);
        assertLt(expectedDirty, expectedClean, "the expectation itself moved with spot");
        assertApproxEqAbs(expectedDirty * 10_000 / expectedClean, 9_704, 2, "it moved by exactly the band");
        assertApproxEqAbs(floorDirty * 10_000 / floorClean, 9_704, 2, "and so did the floor built from it");
    }

    function _revertNumbers() internal returns (uint256 got, uint256 expected, uint256 floor_) {
        try converter.convert(address(quote), AMOUNT, _oneHop(), address(this), 0) {
            revert("expected RouteReturnedTooLittle");
        } catch (bytes memory reason) {
            assertEq(bytes4(reason), FeastConverter.RouteReturnedTooLittle.selector, "the expected refusal");
            bytes memory args = new bytes(reason.length - 4);
            for (uint256 i = 0; i < args.length; i++) {
                args[i] = reason[i + 4];
            }
            (got, expected, floor_) = abi.decode(args, (uint256, uint256, uint256));
        }
    }

    function _threeHopRoute()
        internal
        returns (MockERC20 midA, MockERC20 midB, MockV3Pool p1, MockV3Pool p2, MockV3Pool p3)
    {
        midA = new MockERC20("MidA", "MA", 18);
        midB = new MockERC20("MidB", "MB", 18);
        p1 = new MockV3Pool(address(quote), address(midA));
        p2 = new MockV3Pool(address(midA), address(midB));
        p3 = new MockV3Pool(address(midB), address(wbnb));
        v3Factory.set(address(quote), address(midA), FEE, address(p1));
        v3Factory.set(address(midA), address(midB), FEE, address(p2));
        v3Factory.set(address(midB), address(wbnb), FEE, address(p3));
        MockV3Pool[3] memory ps = [p1, p2, p3];
        for (uint256 i = 0; i < 3; i++) {
            ps[i].setOldestTimestamp(uint32(block.timestamp - 3_600));
            ps[i].setTicks(0, 0);
            ps[i].setOutputBps(10_000);
        }
        midA.mint(address(p1), 1_000_000e18);
        midB.mint(address(p2), 1_000_000e18);
        wbnb.mint(address(p3), 1_000_000e18);
    }
}

/// The same thing through the button the finding is written against, on the
/// whole of v1.6.24 as the recipe deploys it (`test/utils/UnitFixture.sol`).
///
/// The fixture hands `FeastConverter` a v3 factory at the placeholder address
/// `0xF3`, so the repo's own `MockV3Factory` is etched there rather than a
/// second deployment being invented; the fixture's `stockPool` — already a
/// `MockV3Pool(stock, wbnb)` with an hour of history — is registered as the
/// stock -> wrapped-native hop.
contract M1ClaimAsBnbTakesTheClaimantsBound is UnitFixture {
    MockV3Factory internal v3Factory;
    uint24 internal constant FEE = 500;

    function setUp() public override {
        super.setUp();
        deployCodeTo("MockV3Pool.sol:MockV3Factory", "", address(0xF3));
        v3Factory = MockV3Factory(address(0xF3));
        v3Factory.set(address(stock), address(wbnb), FEE, address(stockPool));
        vm.deal(address(this), 1_000 ether);
        wbnb.deposit{value: 1_000 ether}();
        wbnb.transfer(address(stockPool), 1_000 ether);
        stockPool.setTicks(0, 0);
        stockPool.setOutputBps(10_000);
    }

    function _route() internal view returns (FeastConverter.Hop[] memory r) {
        r = new FeastConverter.Hop[](1);
        r[0] = FeastConverter.Hop({tokenOut: address(wbnb), fee: FEE});
    }

    function _parkStockPoolAtTheBandEdge() internal {
        int24 edge = FeastConstants.MAX_TICK_DEVIATION;
        bool zeroForOne = address(stock) == stockPool.token0();
        int24 spot = zeroForOne ? -edge : edge;
        stockPool.setTicks(spot, 0);
        stockPool.setSqrtPrice(TickMath.getSqrtPriceAtTick(spot));
    }

    /// End to end: the creator's accrued stock fees, taken as wrapped native
    /// through `claimAsBnb`. Run from one snapshot — clean, then with the quote
    /// pool's spot parked at the admitted edge. The parked run used to pay
    /// ~2.96% less with no parameter to refuse it. With the claimant's bound it
    /// is refused, the entitlement is untouched, and the claimant can take it
    /// as the quote token instead or try again later. Zero still pays the
    /// parked price, which is what zero means.
    function test_claimAsBnbRefusesAParkedSpotUnderTheClaimantsBound() public {
        (, PoolKey memory key) = _create(address(stock), bytes32(uint256(0xA57A)));
        _buy(key, address(stock), 50_000e18, trader, address(0));
        uint256 owed = hook.claimable(key, creator);
        assertGt(owed, 0, "the creator accrued stock fees");

        uint256 snap = vm.snapshotState();
        vm.prank(creator);
        uint256 clean = hook.claimAsBnb(key, creator, _route(), 0);
        assertGt(clean, 0, "the clean conversion paid something");
        vm.revertToState(snap);

        _parkStockPoolAtTheBandEdge();
        uint256 parked = vm.snapshotState();
        vm.prank(creator);
        uint256 dirty = hook.claimAsBnb(key, creator, _route(), 0);
        assertApproxEqAbs(dirty * 10_000 / clean, 9_704, 3, "zero: the claimant still eats the admitted band");

        vm.revertToState(parked);
        uint256 minOut = clean * 9_950 / 10_000;
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(FeastConverter.BelowMinOut.selector, dirty, minOut));
        hook.claimAsBnb(key, creator, _route(), minOut);
        assertEq(hook.claimable(key, creator), owed, "and a refused conversion leaves the entitlement whole");
    }

    /// The documented exception, pinned: a pool quoted in wrapped native has no
    /// conversion and no price to move, so `minOut` is not consulted there —
    /// exactly as `route` is not.
    function test_aWrappedNativeClaimIsPaidAsIsWhateverTheBound() public {
        (, PoolKey memory key) = _create(address(wbnb), bytes32(uint256(0xB0B)));
        _buy(key, address(wbnb), 100e18, trader, address(0));
        uint256 owed = hook.claimable(key, creator);
        assertGt(owed, 0, "the creator accrued wrapped native");

        uint256 before_ = IERC20(address(wbnb)).balanceOf(creator);
        vm.prank(creator);
        uint256 out = hook.claimAsBnb(key, creator, new FeastConverter.Hop[](0), type(uint256).max);
        assertEq(out, owed, "paid in full");
        assertEq(IERC20(address(wbnb)).balanceOf(creator) - before_, owed, "and it arrives");
    }
}
