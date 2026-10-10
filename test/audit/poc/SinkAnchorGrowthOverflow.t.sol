// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/console2.sol";
import {stdError} from "forge-std/StdError.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {FeastGenesis} from "../../../src/FeastGenesis.sol";
import {FeastPlatformSink} from "../../../src/FeastPlatformSink.sol";
import {UnitFixture} from "../../utils/UnitFixture.sol";

/// **`sink-anchor-growth-overflow`** — `HK19` HIGH, v1.6.19 round, Codex family,
/// against `src/FeastPlatformSink.sol:499` — the line v1.6.19 fix 2 added.
///
/// Fix 2 made the descent memoryless: instead of re-anchoring to the decayed
/// price on every sale, a take now GROWS the anchor by the share it took,
///
///     lot.anchor += mulDiv(lot.anchor, amountOut, held)
///
/// and the comment above it bounds that growth by: `amountOut <= held` is
/// enforced, so the sum is at most double, "and doubling it needs a take of the
/// WHOLE remaining lot, and that take ends the lot."
///
/// Both halves are true of the CALL. Neither is true of the LOT.
///
///  * `held` is not stored. `take` re-reads `balanceOf(address(this))` live
///    (`:404`), so anyone can put the asset back and make `held` whatever they
///    like before the next take.
///  * `_pricesThisLot` (`:332`) keeps the SAME descent over a band —
///    `offered <= held < 2 * offered` — and `lot.offered = min(offered, held -
///    amountOut)` only ever ratchets DOWN, which widens the band. A take that
///    is followed by a refill therefore never "ends the lot": `open` keeps
///    answering `AlreadyOpened`.
///
/// So the bound is not over a sequence. Refill by half and take the half back:
/// `amountOut/held = 1/3` and the anchor grows by 4/3 **per round, for ever**,
/// until `lot.anchor +=` overflows a word and panics. From there every take
/// reverts on that line and `open` still refuses, so the inventory sitting in
/// the sink can never be sold — the sink is bricked for that asset.
///
/// The attacker needs the asset ONCE (it comes straight back out in the same
/// round) and no platform coin at all: run the loop far enough down the descent
/// that the price reads zero and every take is free. The growth term is applied
/// whatever the sale was worth.
contract SinkAnchorGrowthOverflowTest is UnitFixture {
    address internal attacker = address(0xA77AC);

    /// The stake is RECYCLED, not spent: each round hands it to the sink and
    /// takes the same units straight back.
    uint256 internal constant STAKE = 50e18;
    uint256 internal constant LOT = 100e18;

    /// @dev One round of the attack. Returns false once the sink stops taking.
    function _recycle() internal returns (bool ok) {
        // An attacker simulates the round before paying for it, so a round that
        // would revert costs nothing and leaves no stake behind.
        uint256 snap = vm.snapshotState();
        vm.startPrank(attacker);
        IERC20(address(stock)).transfer(address(sink), STAKE);
        IERC20(feast).approve(address(sink), 1);
        (ok,) = address(sink).call(abi.encodeCall(FeastPlatformSink.take, (address(stock), STAKE, 1)));
        vm.stopPrank();
        if (!ok) vm.revertToState(snap);
    }

    /// @dev The largest single take the sink will still serve, to the nearest
    ///      part in 2^20 of what it holds. Measured, not argued.
    function _largestServableTake() internal returns (uint256 best) {
        // Funded, so that what is measured is the sink's refusal and never the
        // buyer's empty pocket.
        deal(feast, attacker, 1e30);
        uint256 held = IERC20(address(stock)).balanceOf(address(sink));
        uint256 lo;
        uint256 hi = held;
        for (uint256 i = 0; i < 20; i++) {
            uint256 mid = (lo + hi + 1) / 2;
            if (mid == 0) break;
            uint256 snap = vm.snapshotState();
            vm.startPrank(attacker);
            IERC20(feast).approve(address(sink), type(uint256).max);
            (bool ok,) = address(sink).call(abi.encodeCall(FeastPlatformSink.take, (address(stock), mid, type(uint256).max)));
            vm.stopPrank();
            vm.revertToState(snap);
            if (ok) lo = mid; else hi = mid - 1;
        }
        best = lo;
    }

    function _openTheLotAtAZeroPrice() internal {
        _launch(10e18);
        stock.mint(address(sink), LOT);
        sink.open(address(stock));
        stock.mint(attacker, STAKE);

        // 256 halvings is past `_price`'s `halvings >= 255` cut-off, so the
        // published price is the floor's own minimum of ONE Q128 unit — and a
        // whole 50e18-unit take at that price costs `ceil(50e18 / 2^128)` = **1
        // wei** of platform coin. `maxCoinIn = 1` is the real cap, met exactly.
        // This is the cheap corner, not the only one: the growth term below
        // does not read the price at all.
        _advance(256 hours);
        assertEq(sink.priceQ128(address(stock)), 1, "the price is at its floor of one Q128 unit");

        // The attacker's entire coin budget: one wei a round. Four hundred is
        // more than the loop can ever use.
        deal(feast, attacker, 400);
    }

    /// **The property.** An opened lot the sink still holds can always be
    /// bought from; nothing a caller does may put it beyond reach.
    function test_recycledInventoryCannotStrandAnOpenedLot() public {
        _openTheLotAtAZeroPrice();

        uint256 rounds;
        while (rounds < 400 && _recycle()) rounds++;

        // The witness reaches its bound: the loop really ran. It does NOT have
        // to stop — under a fix it runs to the ceiling of this loop and that is
        // the point.
        assertGt(rounds, 0, "the recycle loop never got started");
        console2.log("rounds served        :", rounds);

        // The sink still holds the platform's whole inventory either way...
        uint256 held = IERC20(address(stock)).balanceOf(address(sink));
        assertEq(held, LOT, "the inventory is still here");

        // ...and almost none of it can ever be sold. NOTE: the verdict's own
        // assertion — that `take(asset, 1, 1)` reverts — does NOT reproduce. A
        // one-unit take still succeeds here, because one unit of a 100e18 lot
        // adds `anchor / 1e20` and that still fits. The strand is not total; it
        // is a CEILING, and the ceiling is what has to be asserted.
        //
        // Drained greedily, over as many calls as anyone cares to make: every
        // slice raises the anchor again and lowers the ceiling on the next, so
        // the sum is bounded by `ln(2^256 / anchor)` of the lot however it is
        // sliced — about 6%.
        uint256 drained;
        deal(feast, attacker, 1e30);
        for (uint256 i = 0; i < 60; i++) {
            uint256 slice = _largestServableTake();
            if (slice == 0) break;
            deal(feast, attacker, 1e30);
            vm.startPrank(attacker);
            IERC20(feast).approve(address(sink), type(uint256).max);
            sink.take(address(stock), slice, type(uint256).max);
            vm.stopPrank();
            drained += slice;
        }
        assertGe(drained, held - held / 100, "an opened lot the sink still holds was put beyond every buyer's reach");
    }

    /// ...and it cannot be re-opened either, so there is no way back. Split out
    /// so the strand is recorded even while the assert above is red.
    function test_theStrandedLotCannotBeReopenedEither() public {
        _openTheLotAtAZeroPrice();
        uint256 rounds;
        while (rounds < 400 && _recycle()) rounds++;
        assertGt(rounds, 0, "the recycle loop never got started");

        vm.expectRevert(abi.encodeWithSelector(FeastPlatformSink.AlreadyOpened.selector, address(stock)));
        sink.open(address(stock));
    }

    /// **The decisive number.** A one-unit take still succeeds after the
    /// attack, so the lot is not bricked in the absolute sense the verdict
    /// states. The question that decides the severity is whether the platform
    /// can still get its inventory OUT — in slices, over as many calls as it
    /// likes. Every slice raises the anchor again, so the ceiling on the next
    /// slice falls; this drains greedily and measures where it stops.
    function test_howMuchOfTheLotCanEverBeSoldAfterTheAttack() public {
        _openTheLotAtAZeroPrice();
        uint256 rounds;
        while (rounds < 400 && _recycle()) rounds++;
        console2.log("rounds served        :", rounds);

        uint256 held0 = IERC20(address(stock)).balanceOf(address(sink));
        uint256 drained;
        uint256 calls;
        deal(feast, attacker, 1e24);
        for (uint256 i = 0; i < 60; i++) {
            uint256 slice = _largestServableTake();
            if (slice == 0) break;
            vm.startPrank(attacker);
            IERC20(feast).approve(address(sink), type(uint256).max);
            sink.take(address(stock), slice, type(uint256).max);
            vm.stopPrank();
            drained += slice;
            calls++;
            if (i < 8 || i % 10 == 0) console2.log("  slice", i, slice);
        }
        console2.log("calls spent          :", calls);
        console2.log("drained, raw         :", drained);
        console2.log("of the lot, ppm      :", drained * 1_000_000 / held0);
        console2.log("still in the sink    :", IERC20(address(stock)).balanceOf(address(sink)));
    }

    /// **The ceiling's own witness, and it has to reach its bound.**
    ///
    /// v1.6.20 closed the refill pump at source — a sale now scores by what it
    /// took out of the LOT, so recycled inventory moves the curve by exactly
    /// zero (`RecycledInventoryCannotMoveTheCurve`). That makes the sequence
    /// this file was written around harmless, and it would leave the ceiling
    /// asserted by a test that can no longer reach it.
    ///
    /// So the witness is the sequence the consumed-share rule still PERMITS:
    /// no refill anywhere, just partial takes down a shrinking lot, which is
    /// the compounding `test_aRefillIsPricedFromTheTopButNeverUnderTheFloor`
    /// has asserted since v1.6.2. 899 takes of 2.5% each reach `2^224` exactly
    /// (measured). Without the clamp this keeps climbing, and with a large
    /// enough lot and enough takes it reaches a word — which is why the ceiling
    /// stays whatever else changes.
    function test_honestCompoundingStopsAtTheCeilingInsteadOfAWord() public {
        _openTheLotAtAZeroPrice();
        uint256 ceiling = FeastGenesis.SINK_START_PRICE_Q128 << 32;
        deal(feast, attacker, 1e30);

        uint256 takes;
        for (uint256 i = 0; i < 4_000; i++) {
            uint256 held = IERC20(address(stock)).balanceOf(address(sink));
            uint256 slice = held / 40;
            if (slice == 0) break;
            vm.startPrank(attacker);
            IERC20(feast).approve(address(sink), type(uint256).max);
            sink.take(address(stock), slice, type(uint256).max);
            vm.stopPrank();
            takes++;
            if (sink.lot(address(stock)).anchor >= ceiling) break;
        }

        console2.log("takes to the ceiling :", takes);
        console2.log("anchor               :", sink.lot(address(stock)).anchor);

        // The witness REACHES the bound: without this the assertion below would
        // be true of a curve that never moved.
        assertEq(sink.lot(address(stock)).anchor, ceiling, "the drain did not reach the ceiling");
        // And it stops there rather than climbing toward a word.
        assertLe(sink.lot(address(stock)).anchor, ceiling, "the anchor climbed past every price anyone could pay");

        // Still sellable, which is the whole point of the clamp.
        uint256 left = IERC20(address(stock)).balanceOf(address(sink));
        vm.startPrank(attacker);
        IERC20(feast).approve(address(sink), type(uint256).max);
        sink.take(address(stock), left, type(uint256).max);
        vm.stopPrank();
        assertEq(IERC20(address(stock)).balanceOf(address(sink)), 0, "the lot still goes in one call");
    }
}
