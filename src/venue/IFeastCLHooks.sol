// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BalanceDelta} from "./BalanceDelta.sol";
import {BeforeSwapDelta} from "./BeforeSwapDelta.sol";
import {IFeastCLPoolManager} from "./IFeastCLPoolManager.sol";
import {PoolKey} from "./PoolKey.sol";

/// @notice The three callbacks feast registers, plus the one view function this
///         venue requires of every hook.
/// @dev Only registered callbacks are ever invoked — the venue reads the bitmap
///        and calls nothing else — so the unregistered seven are omitted rather
///        than stubbed. Permissions live in `poolKey.parameters`, not in the
///        hook's address, which is why feast needs no salt mining.
/// @dev The venue's own copy of this interface still carries a doc comment
///      claiming permissions are read from the leading bits of the hook's
///      address. That comment is inherited from a different ecosystem and is
///      wrong here; do not design against it.
interface IFeastCLHooks {
    function getHooksRegistrationBitmap() external view returns (uint16);

    function beforeInitialize(address sender, PoolKey calldata key, uint160 sqrtPriceX96) external returns (bytes4);

    function beforeSwap(
        address sender,
        PoolKey calldata key,
        IFeastCLPoolManager.SwapParams calldata params,
        bytes calldata hookData
    ) external returns (bytes4, BeforeSwapDelta, uint24);

    function afterSwap(
        address sender,
        PoolKey calldata key,
        IFeastCLPoolManager.SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) external returns (bytes4, int128);
}
