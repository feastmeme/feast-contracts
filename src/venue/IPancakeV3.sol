// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice The slice of the chain's concentrated-liquidity v3 deployment that
///         the conversion route uses. Re-declared for the same reason as the
///         Infinity declarations next door: the originals are GPL-licensed and
///         the shipped tree stays permissive.
interface IPancakeV3Factory {
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address);
}

interface IPancakeV3Pool {
    function slot0()
        external
        view
        returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            uint32 feeProtocol,
            bool unlocked
        );

    /// @notice Cumulative ticks at each of `secondsAgos`, newest first.
    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s);

    function observations(uint256 index)
        external
        view
        returns (uint32 blockTimestamp, int56 tickCumulative, uint160 secondsPerLiquidityCumulativeX128, bool initialized);

    function token0() external view returns (address);
    function token1() external view returns (address);
    function liquidity() external view returns (uint128);

    /// @notice Grow the pool's observation ring. Permissionless by design, and
    ///         the reason an unpriceable pool is a deployment step rather than a
    ///         dead end.
    function increaseObservationCardinalityNext(uint16 observationCardinalityNext) external;

    function swap(
        address recipient,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata data
    ) external returns (int256 amount0, int256 amount1);
}
