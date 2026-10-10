// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface IFeastLockCallback {
    function lockAcquired(bytes calldata data) external returns (bytes memory);
}
