// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {FeastGenesis} from "../../../src/FeastGenesis.sol";
import {FeastPlatformSink} from "../../../src/FeastPlatformSink.sol";
import {UnitFixture} from "../../utils/UnitFixture.sol";

/// **The residual `HK19`'s ceiling left, closed.** v1.6.20's `ANCHOR_CEILING`
/// stops the refill-and-take pump from overflowing the anchor and stranding the
/// lot, but it does not stop the pump: 78 rounds and 78 wei still walk the
/// anchor to `2^224` (measured), and the descent needs 32 half-lives — 32 hours
/// — to bring it back down. Nobody can buy the sink's inventory at a sane price
/// meanwhile, and the sequence is renewable.
///
/// The rule this asserts: **a sale moves the curve by what it took OUT OF THE
/// LOT THE DESCENT PRICED, and by nothing else.** Units a caller puts in and
/// takes straight back out are not a sale of anything; they leave the platform
/// holding exactly what it held, so they must leave the curve exactly where it
/// was.
contract RecycledInventoryCannotMoveTheCurveTest is UnitFixture {
    address internal attacker = address(0xA77AC);

    uint256 internal constant STAKE = 50e18;
    uint256 internal constant LOT = 100e18;

    function _recycleOnce() internal returns (bool ok) {
        uint256 snap = vm.snapshotState();
        vm.startPrank(attacker);
        IERC20(address(stock)).transfer(address(sink), STAKE);
        IERC20(feast).approve(address(sink), type(uint256).max);
        (ok,) = address(sink).call(
            abi.encodeCall(FeastPlatformSink.take, (address(stock), STAKE, type(uint256).max))
        );
        vm.stopPrank();
        if (!ok) vm.revertToState(snap);
    }

    function _openTheLot() internal {
        _launch(10e18);
        stock.mint(address(sink), LOT);
        sink.open(address(stock));
        stock.mint(attacker, STAKE);
        deal(feast, attacker, 1e30);
        _advance(256 hours);
    }

    /// **The property.** A hundred rounds of putting the stake in and taking the
    /// same units back leave the platform holding what it held — so they must
    /// leave the descent where it was.
    function test_recycledInventoryLeavesTheCurveWhereItWas() public {
        _openTheLot();
        uint256 anchorBefore = sink.lot(address(stock)).anchor;
        uint256 offeredBefore = sink.lot(address(stock)).offered;

        uint256 rounds;
        while (rounds < 100 && _recycleOnce()) rounds++;
        assertGt(rounds, 0, "the recycle loop never got started");

        uint256 anchorAfter = sink.lot(address(stock)).anchor;
        console2.log("rounds          :", rounds);
        console2.log("anchor before   :", anchorBefore);
        console2.log("anchor after    :", anchorAfter);

        // The platform holds exactly what it held...
        assertEq(IERC20(address(stock)).balanceOf(address(sink)), LOT, "the lot is untouched");
        assertEq(sink.lot(address(stock)).offered, offeredBefore, "and so is the size the descent prices");
        // ...so the curve is exactly where it was.
        assertEq(anchorAfter, anchorBefore, "recycled inventory moved the curve");
    }

    /// The other half of the same rule, and the control that keeps it honest: a
    /// sale that really does take the platform's units still raises the curve by
    /// the share it took. Without this the rule above could be satisfied by a
    /// curve that never moves at all.
    function test_aSaleThatReallyTakesTheLotStillRaisesTheCurve() public {
        _openTheLot();
        uint256 before_ = sink.lot(address(stock)).anchor;

        // A quarter of the lot, with no refill anywhere.
        vm.startPrank(attacker);
        IERC20(feast).approve(address(sink), type(uint256).max);
        sink.take(address(stock), LOT / 4, type(uint256).max);
        vm.stopPrank();

        assertEq(
            sink.lot(address(stock)).anchor,
            before_ + before_ / 4,
            "a quarter of the lot must still raise the curve by a quarter"
        );
        assertEq(sink.lot(address(stock)).offered, LOT - LOT / 4, "and the descent now prices what is left");
    }

    /// And the mixed case, which is the one an arithmetic that only looked at
    /// `amountOut` would get wrong in the other direction: a refill of 50 and a
    /// take of 70 consumes 20 of the platform's own units, so the curve rises by
    /// a fifth — not by 70/150, and not by 70/100.
    function test_aSaleThroughARefillCountsOnlyWhatItConsumed() public {
        _openTheLot();
        uint256 before_ = sink.lot(address(stock)).anchor;

        vm.startPrank(attacker);
        IERC20(address(stock)).transfer(address(sink), STAKE); // 150e18 held, 100e18 priced
        IERC20(feast).approve(address(sink), type(uint256).max);
        sink.take(address(stock), 70e18, type(uint256).max); // 80e18 left: 20e18 of the lot went
        vm.stopPrank();

        assertEq(sink.lot(address(stock)).offered, 80e18, "the descent prices what is left of the lot");
        assertEq(
            sink.lot(address(stock)).anchor,
            before_ + Math.mulDiv(before_, 20e18, 100e18),
            "the curve rises by the fifth of the lot the sale actually consumed"
        );
    }
}
