// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FeastGenesis} from "./FeastGenesis.sol";
import {FeastPlatformToken} from "./FeastPlatformToken.sol";

/// @title Where the platform coin is minted
/// @notice Creates FEAST, once, for the factory, at an address fixed from the
///         day this contract is deployed.
///
/// @dev This exists only because of a size limit. The platform coin's creation
///      code is about twelve kilobytes, and inside the factory it left 1,039
///      bytes of the 24,576 a contract may occupy — before the genesis path
///      that uses it. Moving the creation here keeps the coin's code in the
///      audited package and its address predictable, and changes nothing else:
///      the whole supply is still minted to the factory in the coin's
///      constructor, and the factory still checks that it holds all of it.
///
///      No state and no owner. Only the factory may call, so there is exactly
///      one contract anywhere that this address ever minted.
contract FeastPlatformTokenDeployer {
    error NotFactory();

    address public immutable factory;

    constructor(address factory_) {
        factory = factory_;
    }

    /// @notice Mint the platform coin to the factory. A second call reverts,
    ///         because CREATE2 cannot occupy the same address twice.
    function deploy() external returns (address) {
        if (msg.sender != factory) revert NotFactory();
        return address(
            new FeastPlatformToken{salt: FeastGenesis.PLATFORM_SALT}(
                FeastGenesis.PLATFORM_NAME, FeastGenesis.PLATFORM_SYMBOL, FeastGenesis.PLATFORM_SUPPLY, factory
            )
        );
    }

    /// @notice Where the platform coin is, or will be.
    function predict() external view returns (address) {
        bytes32 initCodeHash = keccak256(
            abi.encodePacked(
                type(FeastPlatformToken).creationCode,
                abi.encode(
                    FeastGenesis.PLATFORM_NAME, FeastGenesis.PLATFORM_SYMBOL, FeastGenesis.PLATFORM_SUPPLY, factory
                )
            )
        );
        return address(
            uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), FeastGenesis.PLATFORM_SALT, initCodeHash))))
        );
    }
}
