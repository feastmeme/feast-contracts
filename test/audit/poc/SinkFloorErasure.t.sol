// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FeastGenesis} from "../../../src/FeastGenesis.sol";
import {FeastPlatformSink} from "../../../src/FeastPlatformSink.sol";
import {UnitFixture} from "../../utils/UnitFixture.sol";

/// PoC for the round-r1 MEDIUM `floor-erasure` (`CA-b229a31396`), reported by BOTH claude units
/// independently — `r1a-claude` as `floor-erasure` at `src/FeastPlatformSink.sol:315-316` and
/// `r1h-claude` as `floor-reset` at `:315` — and folded into one record. No codex unit reported
/// it. Both units are of one family, so this is corroboration within a family, not across them.
///
/// The claim: `take` treats EVERY purchase as "the last sale". It overwrites `lot.floorBase` with
/// this sale's share-weighted price and restarts `lot.lastSaleAt`:
///
///     lot.floorBase  = Math.mulDiv(price, amountOut, held);
///     lot.lastSaleAt = uint64(block.timestamp);
///
/// The share weighting was added at round 4 so that one raw unit bought at the start price could
/// not seed a floor far above parity. It is one-directional: it stops dust RAISING a floor, and
/// does nothing to stop dust ERASING one. For one raw unit out of a lot of 5e19 the weighted price
/// rounds to a value some seventy binary orders below the standing floor, so the floor a real sale
/// set is gone — and because the same call re-anchors the descent and restarts its clock, the
/// remainder resumes halving hourly rather than resting on the floor's 24-hour clock.
///
/// What it costs to do: one wei of platform coin. What it buys: the rest of the lot, cheaper.
///
/// The invariant this contradicts is P19 in `audit/invariants.yaml` — after a sale the price never
/// falls below that sale's share-weighted price, halved `SINK_FLOOR_HALVINGS` times, on the
/// floor's own clock. The assertion below is exactly that sentence, with the floor recomputed by
/// the contract's own formula rather than by a hardcoded number.
///
/// The fix shape both units named is the same: take the greater of the new weighted floor and the
/// standing decayed one, so dust can neither raise a floor nor erase one.
contract SinkFloorErasurePoC is UnitFixture {
    uint256 internal constant ONE = 1 << 128;
    address internal taker = address(0x7A7E);
    address internal duster = address(0xD057);

    function test_aDustTakeDoesNotEraseTheFloorARealSaleSet() public {
        _launch(10e18);

        // A lot of 100e18, opened, left to descend to a price anyone would call fair.
        stock.mint(address(sink), 100e18);
        sink.open(address(stock));
        _advance(uint256(FeastGenesis.SINK_HALF_LIFE) * 70);

        // A real sale: half the lot, at the published price.
        uint256 salePrice = sink.priceQ128(address(stock));
        uint256 saleCost = (50e18 * salePrice + ONE - 1) / ONE;
        deal(feast, taker, saleCost);
        vm.prank(taker);
        IERC20(feast).approve(address(sink), type(uint256).max);
        vm.prank(taker);
        sink.take(address(stock), 50e18, saleCost);

        // That sale's evidence, as the contract records it: the price it fetched, weighted by the
        // half of the lot it took, halved SINK_FLOOR_HALVINGS times. This is the floor P19 promises.
        uint256 floorBase = (salePrice * 50e18) / 100e18;
        uint256 floorAtSale = floorBase >> FeastGenesis.SINK_FLOOR_HALVINGS;
        assertGt(floorAtSale, 0, "a real sale seeds a real floor");

        // Ten hours later the descent has fallen through that floor, so the floor is what holds
        // the price up — which is the whole reason it exists.
        _advance(uint256(FeastGenesis.SINK_HALF_LIFE) * 10);
        assertEq(sink.priceQ128(address(stock)), _decayedFloor(floorAtSale, 10 hours), "the floor is holding the price");

        // One raw unit, for one wei of platform coin. Anyone may do this; it needs no stake in the
        // lot, no privilege, and nothing the asset itself does.
        deal(feast, duster, 1);
        vm.prank(duster);
        IERC20(feast).approve(address(sink), type(uint256).max);
        vm.prank(duster);
        uint256 dustCost = sink.take(address(stock), 1, 1);
        assertEq(dustCost, 1, "the erasure costs one wei");

        // Ten hours after that — twenty hours after the real sale — P19 says the price is still at
        // least that sale's floor on the floor's own 24-hour clock.
        _advance(uint256(FeastGenesis.SINK_HALF_LIFE) * 10);
        assertGe(
            sink.priceQ128(address(stock)),
            _decayedFloor(floorAtSale, 20 hours),
            "a one-wei take erased the floor a real sale set, and the remainder resumed halving hourly"
        );
    }

    /// @dev `_atLeastTheFloor`'s own decay, restated: halvings of SINK_FLOOR_HALF_LIFE, then linear
    ///      within the half-life in progress.
    function _decayedFloor(uint256 floor_, uint256 since) private pure returns (uint256) {
        uint256 halvings = since / FeastGenesis.SINK_FLOOR_HALF_LIFE;
        floor_ = halvings >= 255 ? 0 : floor_ >> halvings;
        uint256 into = since % FeastGenesis.SINK_FLOOR_HALF_LIFE;
        return floor_ - floor_ * into / (2 * FeastGenesis.SINK_FLOOR_HALF_LIFE);
    }
}
