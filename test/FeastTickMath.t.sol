// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

// The vendored MIT copy that `src/` uses.
import {TickMath as MitTickMath} from "uniswap-v4-core/src/libraries/TickMath.sol";
// The venue's own GPL copy. A TEST may import it; `src/` may not, which is the
// whole reason the MIT one is vendored.
import {TickMath as VenueTickMath} from "infinity-core/src/pool-cl/libraries/TickMath.sol";
import {Tick} from "infinity-core/src/pool-cl/libraries/Tick.sol";

import {FeastConstants} from "../src/FeastConstants.sol";

/// The vendored tick math is a LICENCE swap, not a new implementation, and this
/// is where that claim is checked rather than asserted.
///
/// `src/` is MIT and the venue's `TickMath` is GPL-2.0-or-later — which is why
/// `FeastMath` writes the extreme square roots out by hand and why `FeastPricer`
/// declines to call `getTickAtSqrtRatio`. The auction's two-sided seed needs the
/// square-root price at a boundary tick to turn an amount into a
/// `liquidityDelta`, so `lib/uniswap-v4-core` carries Uniswap's MIT copy of the
/// same mathematics. If the two ever disagreed, every position the window seeds
/// would be sized against a price the venue does not hold.
contract FeastTickMathTest is Test {
    /// The constants `FeastMath` carries by hand must be the vendored ones.
    function test_theConstantsAreTheOnesFeastMathWritesOut() public pure {
        assertEq(MitTickMath.MIN_TICK, -887_272, "MIN_TICK");
        assertEq(MitTickMath.MAX_TICK, 887_272, "MAX_TICK");
        assertEq(uint256(MitTickMath.MIN_SQRT_PRICE), 4_295_128_739, "MIN_SQRT_PRICE");
        assertEq(
            uint256(MitTickMath.MAX_SQRT_PRICE),
            1_461_446_703_485_210_103_287_273_052_203_988_822_378_723_970_342,
            "MAX_SQRT_PRICE"
        );
    }

    /// Both directions, at the extremes and everywhere the auction can land.
    function test_theVendoredTickMathAgreesWithTheVenueAcrossTheUsableRange() public pure {
        int24[8] memory corners = [
            MitTickMath.MIN_TICK,
            MitTickMath.MIN_TICK + 1,
            int24(-500_000),
            int24(-1),
            int24(0),
            int24(1),
            int24(500_000),
            MitTickMath.MAX_TICK - 1
        ];
        for (uint256 i = 0; i < corners.length; i++) {
            _agreeAt(corners[i]);
        }
        // A hundred spread across the range, deterministically chosen so a
        // failure is reproducible.
        for (uint256 i = 0; i < 100; i++) {
            int256 t = int256(uint256(keccak256(abi.encode(i)))) % (2 * int256(MitTickMath.MAX_TICK));
            _agreeAt(int24(t - int256(MitTickMath.MAX_TICK) + 1));
        }
    }

    function _agreeAt(int24 tick) internal pure {
        if (tick < MitTickMath.MIN_TICK) tick = MitTickMath.MIN_TICK;
        if (tick > MitTickMath.MAX_TICK) tick = MitTickMath.MAX_TICK;
        uint160 mine = MitTickMath.getSqrtPriceAtTick(tick);
        uint160 theirs = VenueTickMath.getSqrtRatioAtTick(tick);
        assertEq(mine, theirs, "getSqrtPriceAtTick disagrees with the venue");

        // And back. The venue's own inverse is the one the pool manager calls,
        // so this is the direction that decides which tick a price lands in.
        if (mine >= MitTickMath.MIN_SQRT_PRICE && mine < MitTickMath.MAX_SQRT_PRICE) {
            assertEq(
                MitTickMath.getTickAtSqrtPrice(mine),
                VenueTickMath.getTickAtSqrtRatio(mine),
                "getTickAtSqrtPrice disagrees with the venue"
            );
        }
    }

    /// Fuzzed over the sqrt-price domain rather than the tick domain, because
    /// that is the direction `initialize` takes and the auction feeds it a
    /// price computed from the pot.
    function testFuzz_bothDirectionsAgreeOnAnyUsablePrice(uint160 sqrtPriceX96) public pure {
        sqrtPriceX96 = uint160(
            bound(
                uint256(sqrtPriceX96),
                uint256(MitTickMath.MIN_SQRT_PRICE),
                uint256(MitTickMath.MAX_SQRT_PRICE) - 1
            )
        );
        int24 mine = MitTickMath.getTickAtSqrtPrice(sqrtPriceX96);
        assertEq(mine, VenueTickMath.getTickAtSqrtRatio(sqrtPriceX96), "the inverse disagrees");
        assertEq(
            MitTickMath.getSqrtPriceAtTick(mine),
            VenueTickMath.getSqrtRatioAtTick(mine),
            "and the round trip disagrees"
        );
    }

    /// The window's own liquidity ceiling is the VENUE's, written out rather
    /// than imported for the same licence reason as everything else here. The
    /// window refuses above it by name so a signer learns which number was
    /// wrong; if these two ever drifted apart, the window would either refuse a
    /// position the venue would have taken or wave through one it will not.
    function test_theWindowsLiquidityCeilingIsTheVenuesOwn() public pure {
        int24 spacing = FeastConstants.POOL_TICK_SPACING;
        uint128 venue = Tick.tickSpacingToMaxLiquidityPerTick(spacing);

        // The same arithmetic `FeastLaunchWindow._maxLiquidity` performs.
        int24 minTick = MitTickMath.MIN_TICK / spacing;
        if (MitTickMath.MIN_TICK % spacing != 0) minTick--;
        int24 maxTick = MitTickMath.MAX_TICK / spacing;
        uint256 numTicks = uint256(uint24(maxTick - minTick)) + 1;
        uint256 ours = uint256(type(uint128).max) / numTicks;

        assertEq(ours, uint256(venue), "the per-tick cap agrees with the venue's");
        assertLt(ours, uint256(uint128(type(int128).max)), "and it is the tighter of the two ceilings");
    }
}
