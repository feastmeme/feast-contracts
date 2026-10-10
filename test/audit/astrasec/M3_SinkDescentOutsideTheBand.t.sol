// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {FeastGenesis} from "../../../src/FeastGenesis.sol";
import {FeastPlatformSink} from "../../../src/FeastPlatformSink.sol";
import {MockERC20} from "../../utils/MockERC20.sol";
import {UnitFixture} from "../../utils/UnitFixture.sol";

/// AstraSec M-3 (report of 2026-10-02, scope `e5c0a77`): **the sink kept the
/// descent curve running while it published the start price.** Reproduced on
/// v1.6.24 (`2ebf5ef`), where the lines were:
///
///   - `src/FeastPlatformSink.sol:315`, the reading of a lot no descent prices:
///         if (!_pricesThisLot(lot, held)) return _atLeastTheFloor(lot, FeastGenesis.SINK_START_PRICE_Q128);
///   - `:358-360`, the band: `offered <= held < 2 * offered`;
///   - `:602-605`, `take`'s only write to the curve, the share it took out of
///     the lot — zero when the lot did not shrink;
///   - `:288-290`, `open`, the only writer of `anchoredAt` and `frozenAtAnchor`.
///
/// So a lot pushed out of the band read at the top while its clock ran on, and
/// a lot brought back was quoted, and sold, on a curve nobody could see. The
/// PoC commit before the fix asserted that, with the coordinator's measured
/// numbers; each scenario is kept here asserting the outcome now.
///
/// **Fixed in v1.6.25.** A take that finds the lot outside the band restarts
/// its curve where the quote already is — the start price, now, at the
/// guardian's frozen seconds now — before it prices. It keeps the floor, and
/// it never raises the size the descent prices. What it cannot reach is a lot
/// that leaves the band and returns with no take in between, which only an
/// asset that shrinks a holder's balance can do: B9's declared limit, kept
/// below as the boundary it is.
contract M3SinkDescentOutsideTheBand is UnitFixture {
    uint256 internal constant START = FeastGenesis.SINK_START_PRICE_Q128;
    uint256 internal constant ONE = 1 << 128;
    uint256 internal constant LOT = 100e18;
    uint256 internal constant WAIT = 80 hours;
    /// What the base charged for the rest of the lot after the one-unit take,
    /// measured by the coordinator and by this file's PoC commit.
    uint256 internal constant BASE_SWEEP = 288_230_376_151_711_744;

    address internal attacker = address(0xA77AC3);
    address internal taker = address(0x7A7E3);

    function setUp() public override {
        super.setUp();
        _launch(10e18);
    }

    /// @dev A hundred million FEAST: enough for fifty thousand raw units at the
    ///      start price twice over, and a tenth of the supply, so a burn never
    ///      outruns it.
    function _fundAndApprove(address who) internal {
        deal(feast, who, 1e26);
        vm.prank(who);
        IERC20(feast).approve(address(sink), type(uint256).max);
    }

    function _takeAs(address who, address asset, uint256 amount, uint256 limit) internal returns (uint256 cost) {
        _fundAndApprove(who);
        vm.prank(who);
        cost = sink.take(asset, amount, limit);
    }

    function _doubledLot() internal returns (uint256 openedAt) {
        stock.mint(address(sink), LOT);
        sink.open(address(stock));
        openedAt = clock;
        stock.mint(attacker, LOT);
        vm.prank(attacker);
        stock.transfer(address(sink), LOT);
    }

    /// The control: the same lot, the same eighty hours, nobody interfering.
    /// Eighty halvings in the open, and the whole lot for 0.00153 FEAST. The
    /// fix leaves this path alone, to the wei.
    function test_theControl_aLotLeftAloneDescendsInTheOpen() public {
        stock.mint(address(sink), LOT);
        sink.open(address(stock));
        _advance(WAIT);
        assertEq(sink.priceQ128(address(stock)), START >> 80, "eighty halvings, published all the way down");
        uint256 cost = _takeAs(taker, address(stock), LOT, type(uint256).max);
        assertEq(cost, 1_525_878_906_250_000, "the whole lot for 0.00153 FEAST");
    }

    /// **Scenario 1, the upper side.** Double the lot, wait eighty hours, take
    /// one raw unit at the top. The take still costs exactly what the quote said
    /// — 2^64 wei — but it restarts the curve there, so the lot it puts back in
    /// the band is priced from the top and the sweep the base sold for 0.288
    /// FEAST is refused at that price.
    function test_upperSide_oneUnitAtTheTopRestartsTheCurveThere() public {
        uint256 openedAt = _doubledLot();
        assertEq(sink.priceQ128(address(stock)), START, "a doubled lot reads at the top");
        _advance(WAIT);
        assertEq(sink.priceQ128(address(stock)), START, "and still does eighty hours later");

        uint256 entry = _takeAs(attacker, address(stock), 1, type(uint256).max);
        assertEq(entry, uint256(1) << 64, "one unit at the top: 2^64 wei, as quoted");

        FeastPlatformSink.Lot memory after_ = sink.lot(address(stock));
        assertEq(after_.anchoredAt, uint64(clock), "the curve restarted at the take");
        assertGt(after_.anchoredAt, uint64(openedAt), "not the clock open() started eighty hours ago");
        assertEq(after_.anchor, START, "at the start price");
        assertEq(after_.offered, LOT, "over the size open() set: the take did not raise it");
        assertEq(sink.priceQ128(address(stock)), START, "so the lot back in the band is quoted from the top");

        _fundAndApprove(attacker);
        bytes memory refused = abi.encodeWithSelector(
            FeastPlatformSink.CostAboveLimit.selector, Math.mulDiv(2 * LOT - 1, START, ONE, Math.Rounding.Ceil), BASE_SWEEP
        );
        vm.expectRevert(refused);
        vm.prank(attacker);
        sink.take(address(stock), 2 * LOT - 1, BASE_SWEEP);

        // And the curve then descends in the open, from the take.
        _advance(1 hours);
        assertEq(sink.priceQ128(address(stock)), START / 2, "halving from the take, published");
    }

    /// **The lower side, through a take.** The same shape on a lot an issuer
    /// shrank: one unit at the top used to lower the size to what it left —
    /// back in the band — onto the curve that ran unseen. It restarts the curve
    /// first now, over what is actually here.
    function test_lowerSide_oneUnitAtTheTopRestartsTheCurveOverWhatIsHere() public {
        ShrinkingAsset asset = new ShrinkingAsset();
        asset.mint(address(sink), LOT);
        sink.open(address(asset));
        asset.shrink(address(sink), 1);
        _advance(WAIT);
        assertEq(sink.priceQ128(address(asset)), START, "the shrunken lot reads at the top");

        uint256 entry = _takeAs(attacker, address(asset), 1, type(uint256).max);
        assertEq(entry, uint256(1) << 64, "one unit at the top, as quoted");

        FeastPlatformSink.Lot memory after_ = sink.lot(address(asset));
        assertEq(after_.anchoredAt, uint64(clock), "the curve restarted at the take");
        assertEq(after_.offered, LOT - 2, "over what was here, less the unit taken");
        uint256 regrown = START + Math.mulDiv(START, 1, LOT - 1);
        assertEq(after_.anchor, regrown, "and raised by the one unit's share of what was here");
        assertEq(sink.priceQ128(address(asset)), regrown, "so the lot is quoted from the top");

        uint256 baseSweep = Math.mulDiv(
            LOT - 2, Math.mulDiv(START, 1, LOT - 1) >> FeastGenesis.SINK_FLOOR_HALVINGS, ONE, Math.Rounding.Ceil
        );
        _fundAndApprove(attacker);
        bytes memory refused = abi.encodeWithSelector(
            FeastPlatformSink.CostAboveLimit.selector, Math.mulDiv(LOT - 2, regrown, ONE, Math.Rounding.Ceil), baseSweep
        );
        vm.expectRevert(refused);
        vm.prank(attacker);
        sink.take(address(asset), LOT - 2, baseSweep);
    }

    /// **The lower side, through an arrival: B9's declared limit, unchanged.**
    /// An issuer shrinks the lot by one wei, it reads at the top for eighty
    /// hours, and one wei sent back brings it into the band with no call to the
    /// sink in between — so there is no write at which the sink could see that
    /// the lot left. The revived curve is the one the lot would have been on
    /// had it never shrunk, to the wei: what the eighty hours cost is that the
    /// quote said the top while it ran. `docs/plan.md` B9 declares it and names
    /// the mitigation, a keeper that opens a lot the moment it holds less than
    /// its descent priced; `test_theDeclaredLimitOfWhatAShrunkenLotCanBeToldFrom`
    /// is its witness. Asserted here so the limit is measured, not implied.
    function test_lowerSide_anArrivalWithNoTakeIsStillB9sDeclaredLimit() public {
        ShrinkingAsset asset = new ShrinkingAsset();
        asset.mint(address(sink), LOT);
        sink.open(address(asset));
        asset.shrink(address(sink), 1);
        assertEq(sink.priceQ128(address(asset)), START, "a lot below what its descent priced reads at the top");
        _advance(WAIT);
        assertEq(sink.priceQ128(address(asset)), START, "and still does eighty hours later");

        asset.mint(attacker, 1);
        vm.prank(attacker);
        asset.transfer(address(sink), 1);
        assertEq(sink.priceQ128(address(asset)), START >> 80, "one wei back: the eighty-hour curve, quoted");
        uint256 cost = _takeAs(attacker, address(asset), LOT, type(uint256).max);
        assertEq(cost, 1_525_878_906_250_000, "and sold at, exactly as if the lot had descended in the open");
    }

    /// **The property behind both sides.** A take on a lot the view reads from
    /// the top leaves it priced from the top: never below the start price at
    /// the instant of that take, however far the lot left the band, on which
    /// side, for how long, and however much the take takes. Fuzzed with the
    /// take sized to bring the lot back into the band, which is where the base
    /// handed over the hidden curve.
    function testFuzz_aTakeOnALotReadFromTheTopLeavesItPricedFromTheTop(uint256 seed, uint256 wait, uint256 amount)
        public
    {
        ShrinkingAsset asset = new ShrinkingAsset();
        asset.mint(address(sink), LOT);
        sink.open(address(asset));
        bool lower = seed % 2 == 0;
        uint256 extra;
        if (lower) {
            asset.shrink(address(sink), bound(seed >> 1, 1, LOT - 1));
        } else {
            extra = bound(seed >> 1, 0, 1e6);
            asset.mint(address(sink), LOT + extra);
        }
        _advance(bound(wait, 1 hours, 300 hours));
        uint256 held = asset.balanceOf(address(sink));
        assertEq(sink.priceQ128(address(asset)), START, "precondition: the lot reads from the top");

        // A take that ends inside the band: on the lower side any size leaves it
        // there, on the upper side it has to take the excess over twice the lot.
        amount = lower ? bound(amount, 1, held < 50_000 ? held : 50_000) : bound(amount, extra + 1, extra + 50_000);
        uint256 cost = _takeAs(attacker, address(asset), amount, type(uint256).max);
        assertEq(cost, Math.mulDiv(amount, START, ONE, Math.Rounding.Ceil), "the take pays the quote it was shown");

        assertEq(sink.lot(address(asset)).anchoredAt, uint64(clock), "the curve restarted at the take");
        if (held > amount) {
            assertGe(sink.priceQ128(address(asset)), START, "and what is left is priced from the top");
        }
    }

    /// The restarted descent runs on OPEN time from the take that restarted it:
    /// frozen seconds before the take are not held against it. Kills:
    /// restarting the clock without its frozen checkpoint, which would hold the
    /// new curve at the top for as long as the earlier freeze lasted.
    function test_theRestartedDescentRunsOnOpenTimeFromTheTake() public {
        _doubledLot();
        vm.prank(multisig);
        guardian.freeze();
        _advance(10 hours);
        vm.prank(multisig);
        guardian.unfreeze();
        _advance(1 hours);

        _takeAs(taker, address(stock), 1, type(uint256).max);
        assertEq(sink.priceQ128(address(stock)), START, "the restarted descent starts at the top");
        _advance(1 hours);
        assertEq(sink.priceQ128(address(stock)), START / 2, "and halves in its first open hour");
    }

    /// **What the restart does not write: the size.** An emptied lot that a
    /// release refills reads at the top, under the floor its last sale left. A
    /// one-unit take there restarts the curve and leaves the size at zero, so
    /// the refill still reads at the top and the keeper's `open` — the one call
    /// that clears a carried floor (round 5) — is still accepted. Writing
    /// `offered = held` here, as `open` does, puts the refill back in the band
    /// under the carried floor, and that `open` reverts `AlreadyOpened`.
    /// Kills: raising the size on a take.
    function test_aRestartingTakeLeavesTheSizeAndTheKeepersOpen() public {
        MockERC20 asset = new MockERC20("A", "A", 18);
        asset.mint(address(sink), 1);
        sink.open(address(asset));
        _takeAs(taker, address(asset), 1, type(uint256).max); // the whole one-unit lot, at the top
        uint256 carried = sink.lot(address(asset)).floorBase;
        assertEq(carried, START, "a whole-lot sale at the top seeds the whole start price");

        asset.mint(address(sink), 1e24); // the release
        _advance(1 hours);
        _takeAs(attacker, address(asset), 1, type(uint256).max);
        FeastPlatformSink.Lot memory after_ = sink.lot(address(asset));
        assertEq(after_.anchoredAt, uint64(clock), "the curve restarted at the take");
        assertEq(after_.offered, 0, "the size did not move");
        assertEq(after_.floorBase, carried, "nor did the floor");
        assertEq(sink.priceQ128(address(asset)), START, "so the refill still reads at the top");

        sink.open(address(asset));
        assertEq(sink.lot(address(asset)).floorBase, 0, "and the keeper's open clears the carried floor");
    }

    /// **What the restart does not write: the floor.** Outside the band the view
    /// publishes the start price or the floor, whichever is higher, and a lot
    /// bought in halves can leave a floor ABOVE the start price (round 1 H2). A
    /// take of its refill is charged that floor, to the unit, and the floor
    /// stands. Kills: clearing the floor on the restart, which would sell under
    /// the quote the view had just published.
    function test_aRestartingTakeIsChargedTheQuoteTheViewPublished() public {
        MockERC20 asset = new MockERC20("A", "A", 18);
        asset.mint(address(sink), 8_192);
        sink.open(address(asset));
        deal(feast, taker, 1e24);
        vm.startPrank(taker);
        IERC20(feast).approve(address(sink), type(uint256).max);
        for (uint256 i = 0; i < 12; ++i) {
            sink.take(address(asset), asset.balanceOf(address(sink)) / 2, type(uint256).max);
        }
        sink.take(address(asset), asset.balanceOf(address(sink)), type(uint256).max);
        vm.stopPrank();
        uint256 floorBase = sink.lot(address(asset)).floorBase;
        assertGt(floorBase >> FeastGenesis.SINK_FLOOR_HALVINGS, START, "this lot's floor is above the start price");

        asset.mint(address(sink), 2); // a refill of the emptied lot: it reads at the floor
        uint256 quoted = sink.priceQ128(address(asset));
        assertEq(quoted, floorBase >> FeastGenesis.SINK_FLOOR_HALVINGS, "the view publishes the floor");

        uint256 cost = _takeAs(attacker, address(asset), 1, Math.mulDiv(1, quoted, ONE, Math.Rounding.Ceil));
        assertEq(cost, Math.mulDiv(1, quoted, ONE, Math.Rounding.Ceil), "the take pays exactly that");
        assertEq(sink.lot(address(asset)).floorBase, floorBase, "and the floor stands");
    }
}

/// An asset whose issuer can take a holder's balance away — a clawback, a
/// downward rebase, a burn on the holder. The only way the sink's balance can
/// fall below what its descent priced without a take.
contract ShrinkingAsset is MockERC20 {
    constructor() MockERC20("Shrinking", "SHRK", 18) {}

    function shrink(address from, uint256 amount) external {
        _burn(from, amount);
    }
}
