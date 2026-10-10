// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {ERC20Votes} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import {Nonces} from "@openzeppelin/contracts/utils/Nonces.sol";
import {Time} from "@openzeppelin/contracts/utils/types/Time.sol";

/// @title The platform coin
/// @notice FEAST: fixed supply, burnable, and carrying the checkpointed votes
///         its one governed parameter is decided with.
///
/// @dev Every other coin is a `FeastToken`, which deleted checkpointed votes on
///      purpose so that no meme coin pays a checkpoint write per transfer. The
///      platform coin is the one coin that is voted with, so it is a second
///      token type, minted exactly once, by the factory's genesis path. Apart
///      from the votes it makes the same promises by the same absences: the
///      whole supply is minted in the constructor, there is no mint entrypoint,
///      no admin and no setter.
///
///      Voting power only counts once a holder delegates, so a contract that
///      never calls `delegate` — the team's vesting wallet, the emissions
///      reserve, the venue's vault — holds tokens that never vote.
contract FeastPlatformToken is ERC20, ERC20Burnable, ERC20Permit, ERC20Votes {
    error ZeroSupply();
    error ZeroRecipient();

    constructor(string memory name_, string memory symbol_, uint256 supply_, address recipient_)
        ERC20(name_, symbol_)
        ERC20Permit(name_)
    {
        if (supply_ == 0) revert ZeroSupply();
        if (recipient_ == address(0)) revert ZeroRecipient();
        _mint(recipient_, supply_);
    }

    /// @dev Governance counts in seconds, not blocks. Block numbers would
    ///      silently turn a one-day voting delay into a block count, and this
    ///      chain has changed its block time before.
    function clock() public view override returns (uint48) {
        return Time.timestamp();
    }

    // solhint-disable-next-line func-name-mixedcase
    function CLOCK_MODE() public pure override returns (string memory) {
        return "mode=timestamp";
    }

    function _update(address from, address to, uint256 value) internal override(ERC20, ERC20Votes) {
        super._update(from, to, value);
    }

    function nonces(address owner) public view override(ERC20Permit, Nonces) returns (uint256) {
        return super.nonces(owner);
    }
}
