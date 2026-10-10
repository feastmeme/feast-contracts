// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "../../src/venue/PoolKey.sol";
import {Currency} from "../../src/venue/Currency.sol";

import {IHooks as UpHooks} from "infinity-core/src/interfaces/IHooks.sol";
import {IPoolManager as UpPoolManager} from "infinity-core/src/interfaces/IPoolManager.sol";
import {Currency as UpCurrency} from "infinity-core/src/types/Currency.sol";
import {PoolKey as UpPoolKey} from "infinity-core/src/types/PoolKey.sol";

/// @dev Tests drive the venue through its own (GPL) types while the shipped
///      contracts use feast's own declarations. This converts between them.
///      `test/venue/VenueAbi.t.sol` is what proves the conversion is a no-op on
///      the wire; this library exists only so tests can call upstream functions
///      that take the upstream struct.
library VenueBridge {
    function up(PoolKey memory k) internal pure returns (UpPoolKey memory) {
        return UpPoolKey({
            currency0: UpCurrency.wrap(Currency.unwrap(k.currency0)),
            currency1: UpCurrency.wrap(Currency.unwrap(k.currency1)),
            hooks: UpHooks(k.hooks),
            poolManager: UpPoolManager(k.poolManager),
            fee: k.fee,
            parameters: k.parameters
        });
    }
}
