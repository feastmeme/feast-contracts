// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {VestingWallet} from "@openzeppelin/contracts/finance/VestingWallet.sol";

import {FeastGenesis} from "./FeastGenesis.sol";
import {IFeastGuardian} from "./IFeastGuardian.sol";

/// @title The team's 25%
/// @notice OpenZeppelin's `VestingWallet`: linear over 36 months from the launch
///         window's close, no cliff (owner, 2026-09-11). Anyone may call
///         `release` and it always pays the beneficiary.
///
/// @dev Two properties are what matter, and one line holds each:
///
///      - **It never votes.** Platform-coin voting power exists only once a
///        holder delegates, and this contract has no function that delegates.
///      - **It cannot strand.** The beneficiary may hand the wallet to a new key
///        (key rotation is the team's own business), but giving it up entirely
///        would leave every future release paying the zero address, which the
///        token refuses — so the 25% would sit here for ever. That one call is
///        disabled.
contract FeastTeamVesting is VestingWallet {
    error RenounceDisabled();

    /// @notice The platform coin this wallet vests — for genesis to check; the
    ///         wallet itself releases whatever token it is asked to.
    address public immutable platformCoin;

    constructor(address beneficiary, uint64 start, address platformCoin_, address guardian_)
        VestingWallet(beneficiary, start, FeastGenesis.TEAM_VESTING_DURATION)
    {
        platformCoin = platformCoin_;
        guardian = IFeastGuardian(guardian_);
    }

    /// @notice The brake. It can pause this contract's outflows for at most 72
    ///         hours at a time and can do nothing else here. See `FeastGuardian`.
    IFeastGuardian public immutable guardian;

    error Frozen();

    /// @dev This contract belongs to no single pool, so it asks the whole-system
    ///      question. A per-pool freeze is for a pool's trading and its own fee
    ///      claims; anything that spans coins is `ALL` or nothing.
    function _requireUnfrozen() internal view {
        if (guardian.isFrozenAll()) revert Frozen();
    }


    /// @notice The team's 25% leaving. Both arities are overridden, not just the
    ///         one this wallet actually uses: an unguarded sibling on the same
    ///         contract is exactly the gap the enumeration test exists to catch.
    function release() public override {
        _requireUnfrozen();
        super.release();
    }

    function release(address token) public override {
        _requireUnfrozen();
        super.release(token);
    }

    /// @notice What genesis asks every contract it names.
    function genesisRole() external pure returns (bytes32) {
        return FeastGenesis.ROLE_TEAM_VESTING;
    }

    function renounceOwnership() public pure override {
        revert RenounceDisabled();
    }
}
