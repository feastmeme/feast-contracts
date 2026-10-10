// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from "./PoolKey.sol";

type PoolId is bytes32;

/// @dev The id is the hash of the ABI-encoded key. It must agree with the
///      venue's own derivation to the bit, or every per-pool mapping in feast
///      would be keyed differently from the pool it describes — a failure that
///      would not revert, just quietly account against the wrong pool.
library PoolIdLibrary {
    function toId(PoolKey memory key) internal pure returns (PoolId poolId) {
        assembly ("memory-safe") {
            // 0xc0 = six 32-byte words, one per field. All six are value types,
            // so the struct's memory image is also its ABI encoding — which is
            // what the test compares against, independently of this assembly.
            poolId := keccak256(key, 0xc0)
        }
    }
}
