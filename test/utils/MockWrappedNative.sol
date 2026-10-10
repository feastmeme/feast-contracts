// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {MockERC20} from "./MockERC20.sol";

/// @dev Wrapped native for in-process tests: deposit mints, withdraw burns and
///      pays native back, like the chain's real one.
contract MockWrappedNative is MockERC20 {
    constructor() MockERC20("Wrapped Native", "WBNB", 18) {}

    function deposit() external payable {
        _mint(msg.sender, msg.value);
    }

    function withdraw(uint256 amount) external {
        _burn(msg.sender, amount);
        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok, "native transfer failed");
    }
}
