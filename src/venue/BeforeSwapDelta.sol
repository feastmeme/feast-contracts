// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice The return type of `beforeSwap`: the specified-currency delta in the
///         upper 128 bits, the unspecified-currency delta in the lower.
/// @dev The specified half is the lever that lets a hook take a fee on a *named*
///      currency. The venue adds it to the amount actually swapped and reverts
///      if it flips the swap's sign — which is why `FeastHook` skips the fee on
///      dust rather than letting a rounded-up fee revert someone's trade.
type BeforeSwapDelta is int256;

BeforeSwapDelta constant ZERO_BEFORE_SWAP_DELTA = BeforeSwapDelta.wrap(0);

function toBeforeSwapDelta(int128 deltaSpecified, int128 deltaUnspecified)
    pure
    returns (BeforeSwapDelta beforeSwapDelta)
{
    assembly ("memory-safe") {
        beforeSwapDelta := or(shl(128, deltaSpecified), and(sub(shl(128, 1), 1), deltaUnspecified))
    }
}
