// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Packs a pool's hook permissions and tick spacing into the single
///         `bytes32` the venue carries on every pool key.
///
/// @dev Layout, fixed by the venue:
///
///        bits [0, 16)   hook registration bitmap
///        bits [16, 40)  tickSpacing, as a 24-bit two's-complement int
///        bits [40, 256) unused — the venue reverts if anything is set here
///
///      This is an original implementation. The venue's own helper is
///      GPL-2.0-or-later, and feast's shipped tree is MIT, so the twenty lines
///      are rewritten rather than imported. Rewritten bit-twiddling is exactly
///      the kind of code that is subtly wrong and compiles fine, so it is fuzzed
///      against the venue's original in `test/FeastHookScaffold.t.sol` instead
///      of being read and believed.
library FeastParameters {
    uint256 internal constant OFFSET_TICK_SPACING = 16;
    uint256 internal constant MASK_UINT24 = 0xffffff;

    function encode(uint16 bitmap, int24 tickSpacing) internal pure returns (bytes32) {
        return bytes32(uint256(bitmap) | ((uint256(uint24(tickSpacing)) & MASK_UINT24) << OFFSET_TICK_SPACING));
    }

    function bitmapOf(bytes32 parameters) internal pure returns (uint16) {
        return uint16(uint256(parameters));
    }

    function tickSpacingOf(bytes32 parameters) internal pure returns (int24) {
        return int24(uint24((uint256(parameters) >> OFFSET_TICK_SPACING) & MASK_UINT24));
    }
}
