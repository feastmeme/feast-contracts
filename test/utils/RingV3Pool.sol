// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @dev A v3 pool's observation ring and nothing else of the pool: the venue's
///      `Oracle` library restated rule for rule (`write`, `grow`, `observe`), so
///      what a reader gets from it is what it would get on chain. `MockV3Pool`
///      answers the same calls from one settable "oldest" timestamp and one
///      settable average, which can say any two things at once; this one can
///      only say what a ring of its size, written when it was written, can say.
///      Written for AstraSec Q-3 (v1.6.25), whose question is exactly that.
///
///      The rules kept, each the venue's own:
///        - **at most one observation per block timestamp.** A write in a second
///          that already has one does nothing (`Oracle.write`'s early return),
///          and timestamps are whole seconds — so a full ring of `n` slots spans
///          at least `n - 1` seconds, however often anyone writes;
///        - **a ring grows only when asked, and only from its end.**
///          `increaseObservationCardinalityNext` raises the target; the ring
///          takes it at the first write that finds the index on its last slot,
///          so the new slots fill in order and the old ones keep their history
///          until the index comes round to them;
///        - **the oldest observation is the slot after the newest**, or slot 0
///          while that slot has never been written;
///        - **`observe` interpolates** between the two observations around a
///          target, extrapolates the newest at the current tick, and refuses a
///          target older than the oldest observation (the venue's `'OLD'`).
///
///      `poke` stands in for an in-range mint or burn: one observation at the
///      current tick, which it does not move. `swapTo` is a swap that moves the
///      tick, and writes the observation for the tick it leaves, as a v3 swap
///      does. The timestamps a test uses are far from 2106, so the venue's
///      wrap-safe comparisons are plain ones here.
contract RingV3Pool {
    struct Observation {
        uint32 blockTimestamp;
        int56 tickCumulative;
        uint160 secondsPerLiquidityCumulativeX128;
        bool initialized;
    }

    error OLD();

    address public immutable token0;
    address public immutable token1;
    uint160 public sqrtPriceX96;
    int24 public tick;
    uint16 public observationIndex;
    uint16 public observationCardinality;
    uint16 public observationCardinalityNext;
    Observation[65_535] public observations;

    constructor(address a, address b, uint160 sqrtPriceX96_, int24 tick_) {
        (token0, token1) = a < b ? (a, b) : (b, a);
        sqrtPriceX96 = sqrtPriceX96_;
        tick = tick_;
        observations[0] = Observation(uint32(block.timestamp), 0, 0, true);
        observationCardinality = 1;
        observationCardinalityNext = 1;
    }

    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint32, bool) {
        return (sqrtPriceX96, tick, observationIndex, observationCardinality, observationCardinalityNext, 0, true);
    }

    function liquidity() external pure returns (uint128) {
        return 1e24;
    }

    /// @dev `Oracle.grow`: the new slots are pre-paid, never initialised.
    function increaseObservationCardinalityNext(uint16 next) external {
        uint16 current = observationCardinalityNext;
        if (next <= current) return;
        for (uint16 i = current; i < next; i++) {
            observations[i].blockTimestamp = 1;
        }
        observationCardinalityNext = next;
    }

    /// @dev An in-range mint or burn: it writes, and it does not move the tick.
    function poke() external {
        _write();
    }

    /// @dev A swap that moves the price: the observation it writes is for the
    ///      tick the swap STARTS at, which is what was in force until now.
    function swapTo(uint160 sqrtPriceX96_, int24 tick_) external {
        if (tick_ != tick) _write();
        sqrtPriceX96 = sqrtPriceX96_;
        tick = tick_;
    }

    /// @dev Seconds since the oldest observation the ring still holds, read the
    ///      way the venue finds it — for a test to state what the ring spans.
    function oldestAge() external view returns (uint32) {
        (uint16 start,) = _ring();
        return uint32(block.timestamp) - observations[start].blockTimestamp;
    }

    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s)
    {
        tickCumulatives = new int56[](secondsAgos.length);
        secondsPerLiquidityCumulativeX128s = new uint160[](secondsAgos.length);
        for (uint256 i = 0; i < secondsAgos.length; i++) {
            tickCumulatives[i] = _cumulativeAt(uint32(block.timestamp) - secondsAgos[i]);
        }
    }

    // --- the library ---------------------------------------------------------

    /// @dev `Oracle.write`, with the pool's own bookkeeping of index and size.
    function _write() internal {
        uint32 now_ = uint32(block.timestamp);
        Observation memory last = observations[observationIndex];
        if (last.blockTimestamp == now_) return;
        uint16 size = observationCardinality;
        if (observationCardinalityNext > size && observationIndex == size - 1) size = observationCardinalityNext;
        uint16 next = uint16((uint256(observationIndex) + 1) % size);
        observations[next] = _transform(last, now_);
        observationIndex = next;
        observationCardinality = size;
    }

    /// @dev `Oracle.transform`, carrying the tick cumulative only.
    function _transform(Observation memory last, uint32 at) internal view returns (Observation memory) {
        int56 delta = int56(uint56(at - last.blockTimestamp));
        return Observation(at, last.tickCumulative + int56(tick) * delta, 0, true);
    }

    /// @dev The oldest slot, and how many slots hold history, in time order.
    function _ring() internal view returns (uint16 start, uint16 count) {
        uint16 size = observationCardinality;
        uint16 afterNewest = uint16((uint256(observationIndex) + 1) % size);
        if (observations[afterNewest].initialized) return (afterNewest, size);
        return (0, observationIndex + 1);
    }

    /// @dev `Oracle.observeSingle`: a linear walk in place of the venue's binary
    ///      search, which finds the same two observations.
    function _cumulativeAt(uint32 target) internal view returns (int56) {
        Observation memory newest = observations[observationIndex];
        if (newest.blockTimestamp <= target) {
            return newest.blockTimestamp == target ? newest.tickCumulative : _transform(newest, target).tickCumulative;
        }
        (uint16 start, uint16 count) = _ring();
        Observation memory before_ = observations[start];
        if (before_.blockTimestamp > target) revert OLD();
        for (uint16 k = 1; k < count; k++) {
            Observation memory after_ = observations[uint16((uint256(start) + k) % observationCardinality)];
            if (after_.blockTimestamp >= target) {
                if (before_.blockTimestamp == target) return before_.tickCumulative;
                if (after_.blockTimestamp == target) return after_.tickCumulative;
                int56 span = int56(uint56(after_.blockTimestamp - before_.blockTimestamp));
                int56 into = int56(uint56(target - before_.blockTimestamp));
                return before_.tickCumulative + ((after_.tickCumulative - before_.tickCumulative) / span) * into;
            }
            before_ = after_;
        }
        revert OLD(); // unreachable: the newest is after the target, so the walk ends on it
    }
}
