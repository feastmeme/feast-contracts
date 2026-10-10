// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FeastConstants} from "../src/FeastConstants.sol";
import {FeastFactory} from "../src/FeastFactory.sol";
import {FeastHook} from "../src/FeastHook.sol";
import {Currency} from "../src/venue/Currency.sol";
import {PoolKey} from "../src/venue/PoolKey.sol";

/// @notice The platform coin's pool key, from package 1 alone — shared by the
///         package-2 and genesis scripts as an internal library, so no script
///         ever deploys another script to compute it (round 4 M2).
library FeastPlatformPool {
    function key(FeastFactory factory) internal view returns (PoolKey memory) {
        address coin = factory.predictPlatformCoin();
        address quote = factory.wrappedNative();
        (address c0, address c1) = coin < quote ? (coin, quote) : (quote, coin);
        FeastHook hook = factory.hook();
        return PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            hooks: address(hook),
            poolManager: hook.poolManager(),
            fee: FeastConstants.POOL_LP_FEE,
            parameters: hook.poolParameters()
        });
    }
}
