// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Currency} from "./Currency.sol";

/// @notice The slice of the venue's `Vault` that feast calls.
/// @dev This venue splits custody from pool logic: the vault holds the tokens
///      and is the ERC-6909, while the pool managers are registered apps on top
///      of it. Every `poolManager.take/mint/burn/settle` in code ported from
///      elsewhere becomes a vault call here.
interface IFeastVault {
    /// @notice Take the lock and receive a `lockAcquired` callback.
    function lock(bytes calldata data) external returns (bytes memory);

    /// @notice Pull real tokens out. Touches the token contract, so it must
    ///         never sit on the swap path — see `FeastHook`.
    function take(Currency currency, address to, uint256 amount) external;

    /// @notice Snapshot the vault's balance of `currency` before paying it in.
    function sync(Currency currency) external;

    /// @notice Settle what was transferred in since `sync`.
    function settle() external payable returns (uint256 paid);

    /// @notice Credit `to` with an ERC-6909 claim and debit the caller's delta.
    /// @dev This is feast's accrual primitive. It touches no token contract, so
    ///      a quote token that pauses, blacklists or sanctions cannot make it
    ///      revert — which is the whole reason fees accrue as claims.
    function mint(address to, Currency currency, uint256 amount) external;

    /// @notice Burn a claim and credit the caller's delta.
    /// @dev The mirror of `mint`: it lets feast pay a swap debt from accrued
    ///      claims without an ERC-20 transfer, so the buyback keeps working even
    ///      while the quote token is paused.
    function burn(address from, Currency currency, uint256 amount) external;

    function balanceOf(address owner, Currency currency) external view returns (uint256);
}
