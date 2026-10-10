// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IFeastGuardian} from "./IFeastGuardian.sol";

/// @title Creator vesting
/// @notice Releases a creator's own allocation linearly. One allocation per
///         coin, written once, payable only to the address named at creation.
///
/// @dev Trimmed from a twice-audited reference. Two deletions carry the weight:
///
///      - No `editAllocationAdmin`. The reference lets the recipient be
///        reassigned, which for a product whose promise is "fixed at creation"
///        would be the whole promise. Another comparable product takes the
///        opposite view deliberately, because its creators are account
///        abstractions that need key rotation. Feast's creators are anonymous;
///        the address is fixed.
///
///      - No minimum lock-up. The reference enforces a seven-day cliff, which
///        would block the "vest linearly from the first second" schedule the
///        product actually specifies. Vesting starts immediately and a duration
///        of zero means "already fully vested". Since v1.6.24 the factory, the
///        only caller, refuses a pre-buy that vests for less than seven days
///        (`FeastFactory.MIN_PREBUY_VESTING`, AstraSec I-5) — still linear from
///        the first second, never a cliff — so zero no longer reaches here.
///
///      `claim` is callable by anyone and always pays the recipient — the
///      standard pull-payment shape. It means a creator who loses their key
///      strands only their own allocation, and that nobody needs the creator's
///      cooperation to keep the accounting current.
contract FeastVesting {
    using SafeERC20 for IERC20;

    error NotFactory();
    error AlreadyAllocated();

    event AllocationCreated(address indexed coin, address indexed recipient, uint256 amount, uint64 endsAt);
    event Claimed(address indexed coin, address indexed recipient, uint256 amount);

    struct Allocation {
        address recipient;
        uint64 startedAt;
        uint64 endsAt;
        uint256 total;
        uint256 claimed;
    }

    address public immutable factory;
    mapping(address coin => Allocation) internal _allocations;

    constructor(address factory_, address guardian_) {
        factory = factory_;
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


    /// @dev The factory has already transferred `amount` of the coin here.
    function createAllocation(address coin, address recipient, uint256 amount, uint64 duration) external {
        if (msg.sender != factory) revert NotFactory();
        Allocation storage a = _allocations[coin];
        if (a.recipient != address(0)) revert AlreadyAllocated();

        a.recipient = recipient;
        a.startedAt = uint64(block.timestamp);
        a.endsAt = uint64(block.timestamp) + duration;
        a.total = amount;
        emit AllocationCreated(coin, recipient, amount, a.endsAt);
    }

    function allocation(address coin) external view returns (Allocation memory) {
        return _allocations[coin];
    }

    function claimable(address coin) public view returns (uint256) {
        Allocation storage a = _allocations[coin];
        if (a.total == 0) return 0;
        return _vested(a) - a.claimed;
    }

    /// @notice Callable by anyone; always pays the recipient.
    function claim(address coin) external {
        _requireUnfrozen();
        Allocation storage a = _allocations[coin];
        uint256 amount = claimable(coin);
        if (amount == 0) return;
        a.claimed += amount;
        IERC20(coin).safeTransfer(a.recipient, amount);
        emit Claimed(coin, a.recipient, amount);
    }

    /// @dev Plain linear vesting, copied from the reference because it is
    ///      correct and boring: total * elapsed / duration, minus what has
    ///      already been taken.
    function _vested(Allocation storage a) private view returns (uint256) {
        if (block.timestamp >= a.endsAt) return a.total;
        uint256 elapsed = block.timestamp - a.startedAt;
        uint256 duration = a.endsAt - a.startedAt;
        return a.total * elapsed / duration;
    }
}
