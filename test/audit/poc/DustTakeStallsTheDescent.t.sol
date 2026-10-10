// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {FeastGenesis} from "../../../src/FeastGenesis.sol";
import {UnitFixture} from "../../utils/UnitFixture.sol";

/// **`sink-dust-take-restarts-descent`** — `HK19-claude` MEDIUM, v1.6.16 round,
/// and launch-relevant because `/burn` gives anyone the button.
///
/// `take` re-anchored the descent on every sale and reset its clock. The curve
/// is exponential by halvings and LINEAR inside each one, so restarting put the
/// price back at the top of a chord — and a chord lies ABOVE the exponential it
/// spans. Restarting it repeatedly holds the price up:
///
///   continuing:  anchor · 2^(-T/H)              = anchor · e^(-0.693 T/H)
///   restarting:  anchor · (1 − δ/2H)^(T/δ)  →  anchor · e^(-0.5 T/H) as δ → 0
///
/// so the ratio grows as `e^(0.193 T/H)` — about 3.2× over six hours in the
/// limit, and **2.03× measured** with a take every thirty minutes. The platform
/// holds its assets above what the schedule says they are worth, and anyone can
/// keep them there for the price of one raw unit at a time.
contract DustTakeStallsTheDescentPoC is UnitFixture {
    address internal taker = address(0x7A4E5);

    function test_aDripOfDustTakesDoesNotHoldTheDescentUp() public {
        _launch(10e18);
        stock.mint(address(sink), 100e18);
        sink.open(address(stock));

        // The control: six hours in which nobody touches the lot.
        uint256 snap = vm.snapshotState();
        _advance(6 hours);
        uint256 honest = sink.priceQ128(address(stock));
        vm.revertToState(snap);

        // The same six hours, with one raw unit taken every thirty minutes.
        for (uint256 i = 0; i < 12; i++) {
            _advance(30 minutes);
            _take(1);
        }
        uint256 dripped = sink.priceQ128(address(stock));

        // **The witness reaches its bound**: the descent really moves over six
        // hours, so this is not two identical stationary numbers.
        assertLt(honest, FeastGenesis.SINK_START_PRICE_Q128 / 32, "six hours of descent really happened");

        // Each take is worth `mulDiv(price, 1, 100e18)` of the lot, which is
        // about 1e-20 of it — so twelve of them may raise the curve by a part
        // in 1e19, and by nothing else. One part in a thousand is a bound with
        // nineteen orders of magnitude of room, and it is what a memoryless
        // curve gives.
        assertLe(dripped, honest + honest / 1_000, "a drip of dust takes held the platform's assets above their schedule");
    }

    /// The control that keeps the rule honest: a take big enough to say
    /// something about the lot still raises the price by the share it took —
    /// the round-1 H1 behaviour, which this must not undo.
    function test_aRealTakeStillRaisesThePriceByTheShareItTook() public {
        _launch(10e18);
        stock.mint(address(sink), 100e18);
        sink.open(address(stock));
        // 150 hours in, where the price has decayed to something a buyer can
        // actually pay for a quarter of the lot. At two hours the price is
        // still near `1 << 192` and the cost of 25e18 units overflows what
        // anybody could hold — true before this change and after it.
        _advance(150 hours);

        uint256 before = sink.priceQ128(address(stock));
        _take(25e18);
        uint256 after_ = sink.priceQ128(address(stock));

        // 25 of 100 units: the sale is a quarter of the lot, so the price goes
        // up by a quarter. Read off the contract, compared to the arithmetic
        // the docstring promises, within one raw unit of rounding.
        uint256 expected = before + Math.mulDiv(before, 25e18, 100e18);
        assertApproxEqRel(after_, expected, 1e12, "a quarter of the lot raises the price by a quarter");
    }

    /// The boundary the new arithmetic needs: a take exactly on a half-life
    /// edge leaves the curve continuous, and the next half-life still halves.
    function test_aTakeOnAHalfLifeEdgeKeepsTheCurveContinuous() public {
        _launch(10e18);
        stock.mint(address(sink), 100e18);
        sink.open(address(stock));
        _advance(FeastGenesis.SINK_HALF_LIFE);

        uint256 atEdge = sink.priceQ128(address(stock));
        _take(1);
        // One unit of a 100e18 lot raises the curve by 1e-20 of itself; the
        // tolerance is a part in 1e6, which is fourteen orders of margin.
        assertApproxEqRel(sink.priceQ128(address(stock)), atEdge, 1e12, "one unit on the edge moves nothing");

        _advance(FeastGenesis.SINK_HALF_LIFE);
        assertApproxEqRel(
            sink.priceQ128(address(stock)), atEdge / 2, 1e12, "and the next half-life still halves"
        );
    }

    /// And the other end of the range. A take of almost the whole lot doubles
    /// the curve; a take of ALL of it leaves no lot for a descent to price, and
    /// the reading falls back to the start price by the rule at `_price`'s top.
    /// Both are asserted, because the second is the boundary the first walks up
    /// to and it would otherwise look like a bug.
    function test_aWholeLotTakeDoublesThePriceAndThenLeavesNoDescent() public {
        _launch(10e18);
        stock.mint(address(sink), 100e18);
        sink.open(address(stock));
        _advance(150 hours);

        uint256 before = sink.priceQ128(address(stock));

        // 99 of 100 units: the curve rises by 99%, and there is still a lot.
        _take(99e18);
        assertApproxEqRel(
            sink.priceQ128(address(stock)),
            before + Math.mulDiv(before, 99e18, 100e18),
            1e12,
            "ninety-nine per cent of the lot raises the price by ninety-nine per cent"
        );

        // The last unit empties it, and an empty lot has no descent to price —
        // the reading is the start price, floored, exactly as `_price` says.
        _take(1e18);
        assertEq(
            sink.priceQ128(address(stock)),
            FeastGenesis.SINK_START_PRICE_Q128,
            "an emptied lot reads the start price, because no descent prices it"
        );
    }

    function _take(uint256 amountOut) internal {
        uint256 price = sink.priceQ128(address(stock));
        uint256 cost = Math.mulDiv(amountOut, price, 1 << 128, Math.Rounding.Ceil);
        if (cost == 0) cost = 1;
        deal(feast, taker, cost);
        vm.prank(taker);
        IERC20(feast).approve(address(sink), cost);
        vm.prank(taker);
        sink.take(address(stock), amountOut, cost);
    }
}
