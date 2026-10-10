// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "./PoolId.sol";
import {PoolKey} from "./PoolKey.sol";

/// @notice The slice of the venue's concentrated-liquidity pool manager that
///         feast calls. Struct layouts and selectors are asserted against the
///         venue's own interface in `test/venue/VenueAbi.t.sol`.
interface IFeastCLPoolManager {
    struct ModifyLiquidityParams {
        int24 tickLower;
        int24 tickUpper;
        int256 liquidityDelta;
        bytes32 salt;
    }

    struct SwapParams {
        bool zeroForOne;
        int256 amountSpecified;
        uint160 sqrtPriceLimitX96;
    }

    function initialize(PoolKey memory key, uint160 sqrtPriceX96) external returns (int24 tick);

    function modifyLiquidity(PoolKey memory key, ModifyLiquidityParams memory params, bytes calldata hookData)
        external
        returns (int256 delta, int256 feeDelta);

    function swap(PoolKey memory key, SwapParams memory params, bytes calldata hookData)
        external
        returns (int256 delta);

    function getSlot0(PoolId id)
        external
        view
        returns (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee);

    function getLiquidity(PoolId id) external view returns (uint128 liquidity);

    function vault() external view returns (address);
}
