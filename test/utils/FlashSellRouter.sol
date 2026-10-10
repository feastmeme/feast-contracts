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

/// @dev Round 2 (M2): a router that borrows the vault's whole balance of the coin
///      inside its lock, sells, and only then pays everything back — a legal
///      sequence on the venue, because deltas only have to net out when the lock
///      ends. The internal fill must not turn it into a revert.
contract FlashSellRouter is ILockCallback {
    Vault public immutable vault;
    CLPoolManager public immutable poolManager;

    constructor(Vault vault_, CLPoolManager pm_) {
        vault = vault_;
        poolManager = pm_;
    }

    function drainThenSell(PoolKey memory key, Currency coin, uint256 coinIn, bool zeroForOne, uint160 limit)
        external
        returns (BalanceDelta delta)
    {
        delta = abi.decode(vault.lock(abi.encode(key, coin, coinIn, zeroForOne, limit)), (BalanceDelta));
    }

    function lockAcquired(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(vault), "not vault");
        (PoolKey memory key, Currency coin, uint256 coinIn, bool zeroForOne, uint160 limit) =
            abi.decode(data, (PoolKey, Currency, uint256, bool, uint160));
        IERC20 c = IERC20(Currency.unwrap(coin));

        uint256 borrowed = c.balanceOf(address(vault));
        vault.take(coin, address(this), borrowed);

        BalanceDelta d = poolManager.swap(
            key, ICLPoolManager.SwapParams({zeroForOne: zeroForOne, amountSpecified: -int256(coinIn), sqrtPriceLimitX96: limit}), ""
        );

        // Pay back what was borrowed plus what the sale owes, and collect the quote.
        (int128 d0, int128 d1) = (d.amount0(), d.amount1());
        bool coinIs0 = Currency.unwrap(key.currency0) == Currency.unwrap(coin);
        int128 coinOwed = coinIs0 ? d0 : d1;
        int128 quoteOut = coinIs0 ? d1 : d0;
        vault.sync(coin);
        c.transfer(address(vault), borrowed + uint256(uint128(-coinOwed)));
        vault.settle();
        Currency quote = coinIs0 ? key.currency1 : key.currency0;
        if (quoteOut > 0) vault.take(quote, address(this), uint256(uint128(quoteOut)));
        return abi.encode(d);
    }
}
