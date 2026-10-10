// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "./venue/PoolId.sol";

/// @notice The one question every guarded contract asks the guardian.
/// @dev A separate declaration so the guarded contracts depend on the QUESTION
///      and not on the guardian's implementation: a reader of `FeastHook` sees
///      the whole of what the guardian can do to it in two lines.
interface IFeastGuardian {

    /// @notice Is everything frozen right now? Asked by paths that belong to no
    ///         single pool, and by `FeastFactory.create`.
    /// @notice Is the brake down? One answer for the whole system: v1.6.17
    ///         removed the pool-scoped freeze, so there is no `isFrozen(poolId)`
    ///         and no scope to ask about.
    function isFrozenAll() external view returns (bool);

    /// @notice Has the one-way creation stop been pulled?
    function creationStopped() external view returns (bool);

    /// @notice The address that may pull either brake — the team multisig.
    /// @dev Read by `FeastGenesisGrants` so the partner-assignment window and
    ///      the brake are the SAME key by construction rather than by two
    ///      constructor arguments that could disagree.
    function guardian() external view returns (address);

    /// @notice Seconds this guardian has held the brake down, over its whole
    ///         life, including any freeze live right now. Every deadline a
    ///         freeze can eat is measured against it.
    function frozenSeconds() external view returns (uint64);

    /// @notice The instant trading last became possible again after an ALL-scope
    ///         freeze — or, while one is live, the moving instant it would.
    function allUnfrozenAt() external view returns (uint64);

    /// @notice Seconds this guardian had held the brake down by the instant `t`:
    ///         the freeze live or lapsed at `t` counts up to `t`, and so does an
    ///         ended one `t` falls inside (v1.6.27). Read by `FeastEmissions` so
    ///         a freeze that ended before a week closed cannot stretch that
    ///         week's grace — `frozenSeconds() - frozenSecondsAt(closesAt)` is
    ///         exactly the frozen time after the close.
    function frozenSecondsAt(uint64 t) external view returns (uint64);

    /// @notice Has genesis happened? Until it has there is no deadline, and
    ///         everything that reads one must wait.
    function clockStarted() external view returns (bool);

    /// @notice Start the ninety-day clock. The factory, from genesis, once.
    function startClock() external;

    /// @notice When the guardian's freeze power ends: genesis plus 90 days.
    /// @dev Read by `FeastGenesisGrants` for its own 90-day window, so there is
    ///      one number in the system and not two that drift.
    function sunsetAt() external view returns (uint64);
}
