// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FeastConstants} from "./FeastConstants.sol";
import {PoolId} from "./venue/PoolId.sol";

/// @title Time-weighted price for feast pools
/// @notice A tick oracle the buy-back button can price against, because the
///         venue keeps no observations of its own.
///
/// @dev Modelled on the well-known cumulative-tick ring buffer, and on the MIT
///      reference in `reference/flaunch/Oracle.sol`, with two deliberate
///      differences.
///
///      **It refuses instead of degrading.** The reference clamps the requested
///      window to the age of its oldest observation and, when there is nothing
///      to average, returns the current tick. A pool thirty seconds old
///      therefore hands back a thirty-second "average", and a brand-new pool
///      hands back the spot price — while the caller believes it is holding a
///      manipulation-resistant bound. That is a fail-open default in the one
///      place a fail-open default is unaffordable, and this is not a
///      hypothetical: the venue's own v3 pool for the sample quote token has an
///      observation cardinality of one, so its published ten-minute average is,
///      to the tick, its spot price. Feast reverts rather than answering over
///      less history than the window asked for — and, until v1.6.24, it only
///      half did: it refused below `MIN_OBSERVATION_AGE` and quietly shortened
///      any longer window to the history it had (AstraSec L-2). See `consult`.
///
///      **The search is over a monotonic counter, not a wrapped ring.** Because
///      writes are counted, a logical index maps to a slot by one modulo and the
///      binary search never has to reason about wrap-around — the fiddliest part
///      of the original, deleted rather than ported.
contract FeastOracle {
    error NotWriter();
    error OracleTooYoung(uint32 age, uint32 required);
    error NoObservations();

    /// @dev Timestamp, the tick that prevailed from it, and the cumulative up to
    ///      it. 32 + 24 + 56 bits: one slot, one write per block.
    struct Observation {
        uint32 timestamp;
        int24 tick;
        int56 tickCumulative;
    }

    /// @notice Ring size. At one observation per block this is far more history
    ///         than the window needs; slots cost nothing until they are used.
    uint256 public constant CARDINALITY = 1024;

    /// @notice The only address that may record observations.
    address public immutable writer;

    mapping(PoolId => mapping(uint256 => Observation)) internal _observations;
    mapping(PoolId => uint256) internal _count;

    constructor(address writer_) {
        writer = writer_;
    }

    /// @notice Record the tick prevailing now. At most one per block; a second
    ///         call in the same block is a no-op rather than an error, because
    ///         it sits on the swap path and must never revert a trade (I1).
    function write(PoolId poolId, int24 tick) external {
        if (msg.sender != writer) revert NotWriter();
        uint256 n = _count[poolId];

        if (n == 0) {
            _observations[poolId][0] = Observation(uint32(block.timestamp), tick, 0);
            _count[poolId] = 1;
            return;
        }

        Observation memory last = _observations[poolId][(n - 1) % CARDINALITY];
        if (last.timestamp == uint32(block.timestamp)) {
            // Two swaps in one second. No time has elapsed, so the cumulative is
            // unchanged — but the tick that will prevail from here is the LATER
            // one, and dropping the write kept the earlier. Round 2 found that:
            // a pair of swaps in one block recorded the price before the first
            // rather than after the second, and the oracle then extrapolated
            // the wrong one forward for as long as the pool stayed quiet.
            _observations[poolId][(n - 1) % CARDINALITY] =
                Observation(last.timestamp, tick, last.tickCumulative);
            return;
        }

        int56 cumulative =
            last.tickCumulative + int56(last.tick) * int56(uint56(_elapsedSince(last.timestamp)));
        _observations[poolId][n % CARDINALITY] = Observation(uint32(block.timestamp), tick, cumulative);
        _count[poolId] = n + 1;
    }

    function observationCount(PoolId poolId) external view returns (uint256) {
        return _count[poolId];
    }

    /// @notice How much history this pool actually has, in seconds.
    function historySeconds(PoolId poolId) public view returns (uint32) {
        uint256 n = _count[poolId];
        if (n == 0) return 0;
        return _elapsedSince(_oldest(poolId, n).timestamp);
    }

    /// @notice The time-weighted average tick over `window` seconds — over
    ///         exactly that window, never a shorter one.
    /// @dev Reverts `OracleTooYoung(age, required)` unless the pool has at least
    ///      `required` seconds of history, where `required` is `window` clamped
    ///      up to `MIN_OBSERVATION_AGE`. The average is always taken over
    ///      `required`: the caller gets the window it asked for or a refusal
    ///      that names both numbers, and never an answer over less.
    ///
    ///      **v1.6.24 (AstraSec L-2).** Until now a pool with more than the
    ///      floor but less than `window` of history was answered over what
    ///      existed, so a ten-minute `twapTick` on a pool six minutes old was a
    ///      six-minute average returned as a bare `int24` — the caller could not
    ///      tell from the answer that the window it relied on had been shortened.
    ///      It refuses now, which is the rule this contract's header already
    ///      claimed for it. Every shipped reader handles the refusal: the
    ///      internal fill asks with `try` and fills nothing, the buy-back button
    ///      refuses the press, and `FeastPricer` checks `historySeconds` against
    ///      the full `TWAP_WINDOW` first and says `Unpriceable`. History never
    ///      runs short once a pool is older than the window: one observation per
    ///      second at most, so the ring holds at least `CARDINALITY` seconds.
    function consult(PoolId poolId, uint32 window) public view returns (int24) {
        uint256 n = _count[poolId];
        if (n == 0) revert NoObservations();

        uint32 nowTs = uint32(block.timestamp);
        Observation memory oldest = _oldest(poolId, n);
        uint32 age = _elapsedSince(oldest.timestamp);

        // v1.6.7 (the v1.6.6 pack, both codex units): a caller could ask for a
        // one-second average of a pool with hours of history and get one,
        // entirely determined by the last second. No shipped path did: the hook
        // and the pricer both read `twapTick`, whose window is the fixed 600.
        // But this function is public, so the window is clamped UP to the floor
        // before anything else is decided.
        uint32 effective = window < FeastConstants.MIN_OBSERVATION_AGE ? FeastConstants.MIN_OBSERVATION_AGE : window;
        if (age < effective) revert OracleTooYoung(age, effective);
        uint32 target = uint32(block.timestamp - effective);

        int56 cumulativeAtTarget = _cumulativeAt(poolId, n, target);
        int56 cumulativeNow = _cumulativeAt(poolId, n, nowTs);
        return int24((cumulativeNow - cumulativeAtTarget) / int56(uint56(effective)));
    }

    function twapTick(PoolId poolId) external view returns (int24) {
        return consult(poolId, FeastConstants.TWAP_WINDOW);
    }

    // --- internals --------------------------------------------------------

    /// @dev Seconds from a stored timestamp to now. Observations are stored
    ///      truncated to `uint32`; the clock passes 2^32 in 2106, and after that
    ///      a stored value from before the rollover is *larger* than the
    ///      truncated clock. So the subtraction is done on the full-width clock,
    ///      which re-attaches the epoch the stored value lost, and truncated
    ///      after — the same answer before the rollover, and no underflow across
    ///      it (v1.6.1, CA-e2ba62d849). The oracle is on the swap path: it must
    ///      not revert a trade (I1).
    function _elapsedSince(uint32 stored) internal view returns (uint32) {
        return uint32(block.timestamp - uint256(stored));
    }

    /// @dev Seconds from `from` to `to`, both truncated, modulo 2^32 — right
    ///      even when one of them lies on the far side of the rollover.
    function _secondsBetween(uint32 from, uint32 to) internal pure returns (uint32) {
        return uint32(uint256(to) + (uint256(1) << 32) - uint256(from));
    }

    function _oldest(PoolId poolId, uint256 n) internal view returns (Observation memory) {
        uint256 index = n > CARDINALITY ? n - CARDINALITY : 0;
        return _observations[poolId][index % CARDINALITY];
    }

    /// @dev The cumulative tick at `when`, interpolated from the latest
    ///      observation at or before it using the tick that prevailed there.
    function _cumulativeAt(PoolId poolId, uint256 n, uint32 when) internal view returns (int56) {
        Observation memory o = _observations[poolId][_searchAtOrBefore(poolId, n, when)];
        return o.tickCumulative + int56(o.tick) * int56(uint56(_secondsBetween(o.timestamp, when)));
    }

    /// @dev Binary search over logical indices. Because writes are counted, the
    ///      logical order is monotonic and a slot is one modulo away — so this
    ///      never has to reason about where the ring wrapped.
    function _searchAtOrBefore(PoolId poolId, uint256 n, uint32 when) internal view returns (uint256) {
        uint256 low = n > CARDINALITY ? n - CARDINALITY : 0;
        uint256 high = n - 1;
        while (low < high) {
            uint256 mid = (low + high + 1) / 2;
            // At or before `when`, compared as ages measured from one clock
            // reading, so the order holds across the 2106 rollover too.
            if (_elapsedSince(_observations[poolId][mid % CARDINALITY].timestamp) >= _elapsedSince(when)) {
                low = mid;
            } else {
                high = mid - 1;
            }
        }
        return low % CARDINALITY;
    }
}
