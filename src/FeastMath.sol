// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice Checked narrowing casts, and the square-root price limit both
///         buy-back paths share.
/// @dev The venue's own equivalent is GPL-licensed, so this is written rather
///      than imported. It matters more than it looks: the fee is computed in
///      `beforeSwap`, which runs *before* the venue has cast the swap amount
///      down to 128 bits. An unchecked narrowing there would let an absurdly
///      large `amountSpecified` wrap the fee to a small or negative number.
///      Such a swap cannot succeed anyway — the venue rejects it moments later
///      — so reverting here costs nothing real and settles the question rather
///      than leaving it to be reasoned about.
library FeastMath {
    error Int128Overflow();
    error Uint128Overflow();

    /// @notice The venue's own usable square-root price bounds, exclusive.
    /// @dev Written out rather than imported for the same reason as the casts
    ///      below: the venue's `TickMath` is GPL-licensed. These are the square
    ///      roots at the extreme ticks, and a swap whose limit is not strictly
    ///      between them is rejected by the venue.
    uint160 internal constant MIN_SQRT_RATIO = 4_295_128_739;
    uint160 internal constant MAX_SQRT_RATIO = 1_461_446_703_485_210_103_287_273_052_203_988_822_378_723_970_342;

    /// @notice The square-root price a swap may be walked to, for a tolerance
    ///         stated as a move in PRICE.
    /// @param sqrtPriceX96 the pool's current square-root price
    /// @param toleranceBps the widest move from that price, in basis points
    /// @param up true when the swap raises the price, false when it lowers it
    ///
    /// @dev Round `v1.6.4` G3 (`CA-7e39484115`): both the hook's buy-back button
    ///      and the converter scaled the SQUARE-ROOT price by `(BPS ± tolerance)
    ///      / BPS`. A ratio applied to a square root is SQUARED in the price it
    ///      bounds, so a documented 3% permitted 1.03² = 6.09% — twice the
    ///      tolerance `MAX_SLIPPAGE_BPS` names and twice what the tick check
    ///      beside it admits. Taking the square root of the ratio first makes
    ///      the limit mean, in price, what the constant says.
    ///
    ///      **Rounding.** Both limits are rounded TOWARDS the current price, so
    ///      neither can ever be looser than the tolerance:
    ///
    ///        - raising: the permitted price is `limit²`, so flooring `limit`
    ///          lowers it. `floor(sqrt(103_000_000)) = 10148` gives
    ///          `(10148/10000)² = 1.02982`, a permitted rise of 298 bps.
    ///          Rounding up would give 10149 and 300.2 bps — outside.
    ///        - lowering: a SMALLER limit permits a DEEPER fall, so the radicand
    ///          is rounded up instead. `ceil(sqrt(97_000_000)) = 9849` gives
    ///          `(9849/10000)² = 0.97003`, a permitted fall of 299.7 bps.
    ///          Flooring would give 9848 and 301.7 bps — outside.
    ///
    ///      `mulDiv` floors, which tightens the raising side further and, on the
    ///      lowering side, would loosen by at most one unit in the last place of
    ///      a Q96 price — far inside the 0.3 bp of headroom the ceiling buys.
    ///      The fuzz witness asserts the bound directly rather than by argument.
    ///
    ///      **The result is clamped into the venue's own bounds** (round `v1.6.4`
    ///      r1, both lenses). A rising limit is `≈ 1.0148 x` spot, and spot may
    ///      sit just under `2**160`, so the product can exceed what a `uint160`
    ///      holds; the narrowing is unchecked and would wrap it to a small
    ///      number — a "limit" on the WRONG SIDE of spot. The inline expressions
    ///      this replaced had the same endpoint, which is why it is stated here
    ///      once rather than reasoned about at two call sites. Clamping is the
    ///      right answer rather than reverting: a limit at the venue's extreme
    ///      is exactly "as far as this pool can go", which is what a tolerance
    ///      wider than the remaining range means.
    function sqrtPriceLimit(uint160 sqrtPriceX96, uint256 toleranceBps, uint256 bps, bool up)
        internal
        pure
        returns (uint160)
    {
        uint256 radicand = (up ? bps + toleranceBps : bps - toleranceBps) * bps;
        uint256 root = Math.sqrt(radicand, up ? Math.Rounding.Floor : Math.Rounding.Ceil);
        uint256 limit = Math.mulDiv(sqrtPriceX96, root, bps);
        if (up) return limit >= MAX_SQRT_RATIO ? MAX_SQRT_RATIO - 1 : uint160(limit);
        return limit <= MIN_SQRT_RATIO ? MIN_SQRT_RATIO + 1 : uint160(limit);
    }

    function toInt128(int256 value) internal pure returns (int128) {
        if (value < type(int128).min || value > type(int128).max) revert Int128Overflow();
        return int128(value);
    }

    function toUint128(uint256 value) internal pure returns (uint128) {
        if (value > type(uint128).max) revert Uint128Overflow();
        return uint128(value);
    }
}
