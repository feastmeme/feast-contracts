// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Two `int128`s packed into one `int256`: amount0 in the upper half,
///         amount1 in the lower. Positive means the account is owed, negative
///         means it owes.
/// @dev A user-defined value type over `int256`, so it is ABI-identical to the
///      venue's own and to a plain `int256` on the wire.
type BalanceDelta is int256;

using BalanceDeltaLibrary for BalanceDelta global;

library BalanceDeltaLibrary {
    function amount0(BalanceDelta delta) internal pure returns (int128 a0) {
        assembly ("memory-safe") {
            a0 := sar(128, delta)
        }
    }

    function amount1(BalanceDelta delta) internal pure returns (int128 a1) {
        assembly ("memory-safe") {
            a1 := signextend(15, delta)
        }
    }
}
