// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Vault} from "infinity-core/src/Vault.sol";
import {ILockCallback} from "infinity-core/src/interfaces/ILockCallback.sol";
import {CLPoolManager} from "infinity-core/src/pool-cl/CLPoolManager.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {BalanceDelta} from "infinity-core/src/types/BalanceDelta.sol";
import {Currency} from "infinity-core/src/types/Currency.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";

/// @dev A minimal lock-taking router, for tests only. It funds itself from its
///      own balance, so a test measures the router's token balances to see what
///      a swapper actually paid or received.
///
///      Deliberately *not* a feast contract: feast ships no router, and swaps
///      arrive through third-party ones. Using a separate contract here also
///      keeps the tests honest about the hook seeing a router as `sender`
///      rather than the trader.
contract PoolRouter is ILockCallback {
    Vault public immutable vault;
    CLPoolManager public immutable poolManager;

    enum Action {
        Swap,
        ModifyLiquidity
    }

    constructor(Vault vault_, CLPoolManager pm_) {
        vault = vault_;
        poolManager = pm_;
    }

    function swap(PoolKey memory key, ICLPoolManager.SwapParams memory params, bytes memory hookData)
        external
        returns (BalanceDelta delta)
    {
        bytes memory ret = vault.lock(abi.encode(Action.Swap, abi.encode(key, params, hookData)));
        delta = abi.decode(ret, (BalanceDelta));
    }

    function modifyLiquidity(PoolKey memory key, ICLPoolManager.ModifyLiquidityParams memory params)
        external
        returns (BalanceDelta delta)
    {
        bytes memory ret = vault.lock(abi.encode(Action.ModifyLiquidity, abi.encode(key, params)));
        delta = abi.decode(ret, (BalanceDelta));
    }

    function lockAcquired(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(vault), "not vault");
        (Action action, bytes memory payload) = abi.decode(data, (Action, bytes));

        PoolKey memory key;
        BalanceDelta delta;
        if (action == Action.Swap) {
            (PoolKey memory k, ICLPoolManager.SwapParams memory p, bytes memory hookData) =
                abi.decode(payload, (PoolKey, ICLPoolManager.SwapParams, bytes));
            key = k;
            delta = poolManager.swap(k, p, hookData);
        } else {
            (PoolKey memory k, ICLPoolManager.ModifyLiquidityParams memory p) =
                abi.decode(payload, (PoolKey, ICLPoolManager.ModifyLiquidityParams));
            key = k;
            (delta,) = poolManager.modifyLiquidity(k, p, "");
        }

        _settle(key.currency0, delta.amount0());
        _settle(key.currency1, delta.amount1());
        return abi.encode(delta);
    }

    function _settle(Currency currency, int128 amount) internal {
        if (amount < 0) {
            vault.sync(currency);
            IERC20(Currency.unwrap(currency)).transfer(address(vault), uint128(-amount));
            vault.settle();
        } else if (amount > 0) {
            vault.take(currency, address(this), uint128(amount));
        }
    }
}
