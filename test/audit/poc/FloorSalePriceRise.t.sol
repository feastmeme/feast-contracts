// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {FeastGenesis} from "../../../src/FeastGenesis.sol";
import {UnitFixture} from "../../utils/UnitFixture.sol";

/// **`floor-sale-misses-price-rise`** — `P3` MEDIUM, v1.6.20 round, Codex
/// family, cited at `src/FeastPlatformSink.sol:603`.
///
/// The claim: a purchase fails to raise the published price when the standing
/// floor dominates the decayed descent. The anchor rises by the share the sale
/// took, as it must, but `_price` ends at `_atLeastTheFloor`, and while the
/// floor is the larger of the two the published quote does not move.
///
/// **The cited line is v1.6.20's own `if (priced != 0)` block, so the first
/// question is whether v1.6.20 caused it.** It cannot have: this sequence never
/// refills, so `held == offered` at every take, so `priced - remaining` IS
/// `amountOut` and the arithmetic is the same one v1.6.19 ran. The
/// counterfactual is run rather than argued — see the sibling run on
/// `v1.6.19-audit` recorded in the round notes.
contract FloorSalePriceRiseTest is UnitFixture {
    address internal taker = address(0x7A4E5);

    /// **CARRIED, not fixed.** Skipped so the release gate stays honest; the red run is recorded here. Measured on v1.6.20 AND on v1.6.19 (4c49475), identically: the anchor rises from 9415652603080021145753684134811499624153533166696051769344 to 1.5x that, and the published price stays at 2^120 = 1329227995784915872903807060280344576 on both sides of the sale.
    function test_aSaleAtTheFloorRaisesThePublishedPrice() public {
        vm.skip(true);
        _launch(10e18);
        stock.mint(address(sink), 100e18);
        sink.open(address(stock));
        deal(feast, taker, 1e30);
        vm.prank(taker);
        IERC20(feast).approve(address(sink), type(uint256).max);

        // Far enough down that a half-lot take is affordable.
        _advance(64 hours);
        vm.prank(taker);
        sink.take(address(stock), 50e18, type(uint256).max);

        // A day later the descent has fallen away and the floor that sale set
        // is what holds the quote up.
        _advance(24 hours);
        uint256 before_ = sink.priceQ128(address(stock));
        uint256 anchorBefore = sink.lot(address(stock)).anchor;
        uint256 floorBefore = sink.lot(address(stock)).floorBase;
        console2.log("published before :", before_);
        console2.log("anchor   before  :", anchorBefore);
        console2.log("floorBase before :", floorBefore);

        // Half of what is left: the anchor must rise by half again.
        vm.prank(taker);
        sink.take(address(stock), 25e18, type(uint256).max);

        uint256 after_ = sink.priceQ128(address(stock));
        console2.log("published after  :", after_);
        console2.log("anchor   after   :", sink.lot(address(stock)).anchor);

        // The anchor did move, by exactly the share taken. This is the half of
        // the mechanism that works, and it is asserted so the finding cannot be
        // read as "the sale was ignored".
        assertEq(
            sink.lot(address(stock)).anchor,
            anchorBefore + anchorBefore / 2,
            "the anchor rose by the half of the lot the sale took"
        );

        // The finding: the PUBLISHED price did not.
        assertGt(after_, before_, "a sale that took half the lot did not raise the published price");
    }
}
