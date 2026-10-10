// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {FeastConstants} from "../src/FeastConstants.sol";
import {FeastOracle} from "../src/FeastOracle.sol";
import {PoolId} from "../src/venue/PoolId.sol";

/// I13, and the reason it is an invariant rather than a nicety.
///
/// A time-weighted price that quietly shortens its own window until it is a spot
/// reading is worse than no oracle at all, because the caller acts as though it
/// is protected. The venue's own v3 pool for the sample quote token does exactly
/// this today — cardinality one, so its ten-minute "average" equals its spot
/// tick to the integer. Feast refuses instead.
contract FeastOracleTest is Test {
    FeastOracle internal oracle;
    address internal hook = address(0xB00C);
    PoolId internal id = PoolId.wrap(bytes32(uint256(1)));

    /// The clock is tracked in storage rather than read back from
    /// `block.timestamp`. The optimizer treats the timestamp opcode as constant
    /// within a call frame and will happily hoist it out of a loop, so
    /// `warp(block.timestamp + n)` repeated in a loop warps to the same instant
    /// every time — which looks exactly like an oracle bug and is not one.
    uint256 internal clock;

    function setUp() public {
        oracle = new FeastOracle(hook);
        clock = 1_000_000;
        vm.warp(clock);
    }

    function _write(int24 tick) internal {
        vm.prank(hook);
        oracle.write(id, tick);
    }

    function _advance(uint32 seconds_) internal {
        clock += seconds_;
        vm.warp(clock);
    }

    // --- who may write ----------------------------------------------------

    function test_onlyTheHookMayRecordObservations() public {
        vm.expectRevert(FeastOracle.NotWriter.selector);
        oracle.write(id, 100);
    }

    // --- the refusal ------------------------------------------------------

    function test_anEmptyOracleRefusesRatherThanGuessing() public {
        vm.expectRevert(FeastOracle.NoObservations.selector);
        oracle.twapTick(id);
    }

    /// The whole point. A young pool must not answer — not at the floor, and
    /// (v1.6.24, AstraSec L-2) not for any window longer than its history: the
    /// refusal names the window that was asked for, so `twapTick` reports 600.
    function test_aYoungOracleRefusesRatherThanReturningSpot() public {
        _write(100);
        _advance(FeastConstants.MIN_OBSERVATION_AGE - 1);
        _write(100);

        vm.expectRevert(
            abi.encodeWithSelector(
                FeastOracle.OracleTooYoung.selector,
                FeastConstants.MIN_OBSERVATION_AGE - 1,
                FeastConstants.MIN_OBSERVATION_AGE
            )
        );
        oracle.consult(id, 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                FeastOracle.OracleTooYoung.selector, FeastConstants.MIN_OBSERVATION_AGE - 1, FeastConstants.TWAP_WINDOW
            )
        );
        oracle.twapTick(id);
    }

    /// At exactly a whole window of history `twapTick` answers, and one second
    /// short of it it refuses. Until v1.6.24 the bound was the floor, 300.
    function test_itAnswersOnceItHasEnoughHistory() public {
        _write(100);
        _advance(FeastConstants.TWAP_WINDOW - 1);
        _write(100);
        vm.expectRevert(
            abi.encodeWithSelector(
                FeastOracle.OracleTooYoung.selector, FeastConstants.TWAP_WINDOW - 1, FeastConstants.TWAP_WINDOW
            )
        );
        oracle.twapTick(id);
        _advance(1);
        assertEq(oracle.twapTick(id), 100, "a constant tick averages to itself");
    }

    // --- what it computes -------------------------------------------------

    function test_theAverageIsTimeWeightedNotObservationWeighted() public {
        // 500 seconds at tick 0, then 100 seconds at tick 600.
        _write(0);
        _advance(500);
        _write(600);
        _advance(100);
        _write(600);

        // Over the last 600s: (500*0 + 100*600) / 600 = 100.
        assertEq(oracle.consult(id, 600), 100, "weighted by time, not by count");
    }

    /// I13 in its operational form: one block of extreme price must barely move
    /// a ten-minute average, or the bound it feeds is not a bound.
    function test_aSingleBlockSpikeBarelyMovesTheAverage() public {
        _write(0);
        for (uint256 i = 0; i < 60; i++) {
            _advance(10);
            _write(0);
        }
        int24 calm = oracle.twapTick(id);
        assertEq(calm, 0, "quiet market");

        // One block, one enormous print.
        _advance(1);
        _write(800_000);
        _advance(1);
        _write(0);

        int24 spiked = oracle.twapTick(id);
        assertLt(spiked, 2_000, "a one-second spike cannot drag a ten-minute average with it");
        assertGt(spiked, 0, "though it is not ignored either");
    }

    // --- mechanics --------------------------------------------------------

    function test_secondWriteInTheSameBlockIsANoOp() public {
        _write(100);
        _write(999);
        assertEq(oracle.observationCount(id), 1, "one observation per block");
    }

    /// Ruling 1. Two writes in one second: no time has elapsed so the
    /// cumulative is unchanged, but the tick that will prevail from here is the
    /// later one. Round 2: dropping the second write kept the earlier tick and
    /// extrapolated it forward for as long as the pool stayed quiet.
    function test_twoSwapsInOneSecondKeepTheLaterTick() public {
        _write(0);
        _advance(600);
        _write(100);
        _write(900); // same second

        assertEq(oracle.observationCount(id), 2, "still one observation for that second");

        // The following interval is priced at the LATER tick, not the earlier.
        _advance(600);
        assertEq(oracle.consult(id, 600), 900, "the second write is what prevailed");
    }

    function test_historyIsReportedHonestly() public {
        _write(0);
        _advance(1_234);
        assertEq(oracle.historySeconds(id), 1_234, "age of the oldest observation");
    }

    /// Past the ring's capacity the oldest entries are overwritten, and the
    /// window must follow rather than reaching back into a slot that has been
    /// reused. Fuzzing over interval lengths is what catches an off-by-one in
    /// the wrap.
    /// v1.6.1 (CA-e2ba62d849): the clock passes 2^32 in 2106. Observations are
    /// stored truncated to `uint32`, so every elapsed time must be taken from
    /// the full-width clock and truncated after — and observations either side
    /// of the rollover must still be ordered and interpolated by the gap
    /// between them, not by their raw stored values. The oracle sits on the
    /// swap path and must never revert a trade (I1).
    function test_itKeepsWritingAndAnsweringAcrossTheTwentyOneOhSixRollover() public {
        uint256 rollover = uint256(type(uint32).max) + 1;
        clock = rollover - 600;
        vm.warp(clock);
        _write(0);
        _advance(300);
        _write(600); // the tick that prevails from here
        _advance(400); // and now the clock is past 2^32, history entirely behind it
        assertGt(block.timestamp, rollover, "the clock has passed the rollover");

        // Answering with every observation on the far side of the rollover: the
        // window covers 200s at tick 0 and 400s at tick 600.
        assertEq(oracle.consult(id, 600), 400, "the average straddles the rollover correctly");

        // And writing across it, then answering again from both sides.
        _write(0);
        assertEq(oracle.historySeconds(id), 700, "history is measured across the rollover");
        assertEq(oracle.consult(id, 600), 400, "the same average, now with an observation after it");
        _advance(600);
        _write(0);
        assertEq(oracle.consult(id, 600), 0, "and once the window is entirely after it, the later tick");
    }

    function testFuzz_theRingStaysCorrectPastItsCapacity(uint8 rawInterval) public {
        uint32 interval = uint32(bound(uint256(rawInterval), 1, 60));
        _write(42);
        for (uint256 i = 0; i < oracle.CARDINALITY() + 50; i++) {
            _advance(interval);
            _write(42);
        }
        assertEq(oracle.consult(id, 600), 42, "a constant tick still averages to itself after wrapping");
        assertGt(oracle.observationCount(id), oracle.CARDINALITY(), "the ring really did wrap");
    }

    function testFuzz_theAverageIsAlwaysBetweenTheExtremesObserved(int16 a, int16 b) public {
        _write(int24(a));
        _advance(300);
        _write(int24(b));
        _advance(300);
        _write(int24(b));

        int24 mean = oracle.consult(id, 600);
        int24 lo = a < b ? int24(a) : int24(b);
        int24 hi = a < b ? int24(b) : int24(a);
        assertGe(mean, lo, "no lower than the lowest");
        assertLe(mean, hi, "no higher than the highest");
    }

    /// A window longer than the history is REFUSED, never shortened and never
    /// padded (v1.6.24, AstraSec L-2 — this test pinned the shortening until
    /// then). A caller who wants what exists asks for it by its length.
    function test_aLongWindowIsRefusedRatherThanShortenedToTheHistory() public {
        _write(10);
        _advance(400);
        _write(10);
        vm.expectRevert(abi.encodeWithSelector(FeastOracle.OracleTooYoung.selector, uint32(400), uint32(10_000)));
        oracle.consult(id, 10_000);
        assertEq(oracle.consult(id, 400), 10, "the window the history does cover is answered over exactly that");
    }
}
