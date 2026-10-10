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

/// @dev Round 3 (M1): a router that snapshots the vault's coin balance, pays the
///      coin in, and only then swaps and settles — legal on the venue, where a
///      payment is the balance increase since `sync`. Anything that moves the
///      vault's coin in between would leave it owing.
contract SyncFirstRouter is ILockCallback {
    Vault public immutable vault;
    CLPoolManager public immutable poolManager;

    constructor(Vault vault_, CLPoolManager pm_) {
        vault = vault_;
        poolManager = pm_;
    }

    function sell(PoolKey memory key, Currency coin, uint256 coinIn, bool zeroForOne, uint160 limit) external {
        vault.lock(abi.encode(key, coin, coinIn, zeroForOne, limit));
    }

    function lockAcquired(bytes calldata data) external returns (bytes memory) {
        (PoolKey memory key, Currency coin, uint256 coinIn, bool zeroForOne, uint160 limit) =
            abi.decode(data, (PoolKey, Currency, uint256, bool, uint160));
        vault.sync(coin);
        IERC20(Currency.unwrap(coin)).transfer(address(vault), coinIn);
        BalanceDelta d = poolManager.swap(
            key, ICLPoolManager.SwapParams({zeroForOne: zeroForOne, amountSpecified: -int256(coinIn), sqrtPriceLimitX96: limit}), ""
        );
        vault.settle();
        bool coinIs0 = Currency.unwrap(key.currency0) == Currency.unwrap(coin);
        int128 quoteOut = coinIs0 ? d.amount1() : d.amount0();
        Currency quote = coinIs0 ? key.currency1 : key.currency0;
        if (quoteOut > 0) vault.take(quote, address(this), uint256(uint128(quoteOut)));
        return "";
    }
}

/// @dev Round 3 (L3): a router that takes its proceeds as vault claims rather
///      than tokens, so a sale can complete while the quote token is frozen —
///      which is only possible if nothing on the swap path calls that token.
contract ClaimSettleRouter is ILockCallback {
    Vault public immutable vault;
    CLPoolManager public immutable poolManager;

    constructor(Vault vault_, CLPoolManager pm_) {
        vault = vault_;
        poolManager = pm_;
    }

    function sell(PoolKey memory key, Currency coin, uint256 coinIn, bool zeroForOne, uint160 limit) external {
        vault.lock(abi.encode(key, coin, coinIn, zeroForOne, limit));
    }

    function lockAcquired(bytes calldata data) external returns (bytes memory) {
        (PoolKey memory key, Currency coin, uint256 coinIn, bool zeroForOne, uint160 limit) =
            abi.decode(data, (PoolKey, Currency, uint256, bool, uint160));
        BalanceDelta d = poolManager.swap(
            key, ICLPoolManager.SwapParams({zeroForOne: zeroForOne, amountSpecified: -int256(coinIn), sqrtPriceLimitX96: limit}), ""
        );
        bool coinIs0 = Currency.unwrap(key.currency0) == Currency.unwrap(coin);
        (int128 coinLeg, int128 quoteLeg) = coinIs0 ? (d.amount0(), d.amount1()) : (d.amount1(), d.amount0());
        vault.sync(coin);
        IERC20(Currency.unwrap(coin)).transfer(address(vault), uint256(uint128(-coinLeg)));
        vault.settle();
        Currency quote = coinIs0 ? key.currency1 : key.currency0;
        if (quoteLeg > 0) vault.mint(address(this), quote, uint256(uint128(quoteLeg)));
        return "";
    }
}
