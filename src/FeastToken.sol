// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

/// @title The coin
/// @notice A plain, fixed-supply ERC-20. Nothing else.
///
/// @dev Trimmed hard from a twice-audited reference, and the deletions are the
///      point rather than tidiness — every removed feature is a removed bug
///      class, and this contract can never be upgraded or paused:
///
///      - No mint entrypoint. The whole supply is minted once, in the
///        constructor, to the factory. Fixed supply is enforced by *absence*,
///        which is a property a reader can verify from the source in one pass.
///      - No admin, no metadata setters, no verification flag. The reference
///        keeps a reassignable admin that can rewrite the token's image and
///        metadata; that is an owner function under a friendlier name, and the
///        product promises there are none. Presentation belongs in an off-chain
///        index keyed by the factory's creation event.
///      - No checkpointed votes. Governance exists (over exactly one parameter)
///        but it runs on an opt-in wrapper, so no coin pays a checkpoint write
///        on every transfer and no coin is anything unusual to an aggregator.
///      - No cross-chain mint/burn. Single chain.
///
///      Kept: burnable, because the buyback burns for real rather than sending
///      to a dead address, so supply is reported honestly everywhere; and
///      permit, because it is free and the app wants gasless approvals.
contract FeastToken is ERC20, ERC20Burnable, ERC20Permit {
    error ZeroSupply();
    error ZeroRecipient();

    constructor(string memory name_, string memory symbol_, uint256 supply_, address recipient_)
        ERC20(name_, symbol_)
        ERC20Permit(name_)
    {
        // A zero supply makes a coin whose pool can never be seeded; a zero
        // recipient burns the entire supply at construction. Both are creator
        // mistakes that cost nothing to refuse and are permanent to accept.
        if (supply_ == 0) revert ZeroSupply();
        if (recipient_ == address(0)) revert ZeroRecipient();
        _mint(recipient_, supply_);
    }
}
