// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {FeastEmissions} from "./FeastEmissions.sol";
import {FeastGenesis} from "./FeastGenesis.sol";
import {IFeastGuardian} from "./IFeastGuardian.sol";

interface IFeastBurnableGrant {
    function burn(uint256 amount) external;
}

/// @title The genesis partners' grants
/// @notice Eight addresses, fixed at construction, each granted 0.1% of the
///         platform coin, unlocking by the fees their referrals bring in the
///         first 26 emission weeks. What is not unlocked by then is burned.
///
/// @dev **An empty slot may be filled once, within 90 days** (owner,
///      2026-09-20 18:5x). The eight addresses no longer have to exist before
///      genesis: a slot left at zero can be assigned exactly once by the team
///      multisig — the same key the guardian holds, read from the guardian so
///      the two cannot be different addresses — and only while the guardian's
///      own 90-day window is open, so there is one deadline in the system and
///      not two. A slot filled at genesis, or filled since, is immutable: the
///      multisig cannot replace, remove or reassign anybody, and nothing here
///      moves value.
///
///      **A partner assigned late gets a late start, not a backdated one.** The
///      six-month unlock clock runs from genesis and is not restarted, and weeks
///      that had already CLOSED when the assignment happened do not count toward
///      the slot — see `checkpoint`. An address that was already referring fees
///      as an ordinary referrer does not arrive with a head start.
///
/// @dev **No second ledger.** A partner's referred fees are read from the
///      emissions contract, which reads the hook's own weekly ledger and prices
///      each week once, at settlement — the same numbers the referral pots are
///      divided by. `unlocked = min(grant, grant × referred / TARGET_NATIVE)`.
///
///      A grant is not transferable and not replaceable: a wrong address can
///      only be burned, never corrected — which is the public evidence that no
///      one's hand is on it. Claims and burns wait until the platform coin's
///      pool has opened, because that is when the tokens exist.
contract FeastGenesisGrants {
    using SafeERC20 for IERC20;

    error NotAPartner(address account);
    error ZeroTarget();
    error PartnerMisconfigured(address partner);
    error WeekOutOfRange(uint256 week);
    error NotSettled(uint256 week);
    error ClaimsNotOpen();
    error HorizonNotReached();
    error AlreadyBurned(address partner);
    error NotTheTeamMultisig(address caller);
    error SlotOutOfRange(uint8 slot);
    error SlotAlreadyFilled(uint8 slot, address partner);
    error SlotIsFilled(uint8 slot, address partner);
    error AssignmentWindowOpen(uint64 until);
    error AssignmentWindowClosed(uint64 until);
    error SlotAlreadyBurned(uint8 slot);
    error AssignmentWindowNotOpen();

    event WeekCounted(address indexed partner, uint256 indexed week, uint256 referredNative);
    event Claimed(address indexed partner, uint256 amount);
    event UnearnedBurned(address indexed partner, uint256 amount);
    event PartnerAssigned(uint8 indexed slot, address indexed partner);
    event UnfilledSlotBurned(uint8 indexed slot, uint256 amount);

    IERC20 public immutable platformCoin;
    FeastEmissions public immutable emissions;
    uint256 public immutable targetNative;
    uint256 public immutable grant;

    address[8] internal _partners;
    mapping(address => bool) public isPartner;
    mapping(address => uint256) public referredNative;
    mapping(address => uint256) internal _counted; // bit n set: week n counted
    mapping(address => uint256) public claimed;
    mapping(address => bool) public unearnedBurned;
    /// @notice When an assigned partner's slot was filled. Zero for the eight
    ///         named at genesis, and the instant before which no week counts for
    ///         anybody assigned later.
    mapping(address => uint64) public assignedAt;
    /// @notice Which empty slots have had their grant burned.
    mapping(uint8 => bool) public slotBurned;

    constructor(
        address platformCoin_,
        address emissions_,
        uint256 targetNative_,
        address[8] memory partners_,
        address guardian_
    ) {
        guardian = IFeastGuardian(guardian_);
        if (targetNative_ == 0) revert ZeroTarget();
        platformCoin = IERC20(platformCoin_);
        emissions = FeastEmissions(emissions_);
        targetNative = targetNative_;
        grant = FeastGenesis.PLATFORM_SUPPLY * FeastGenesis.GRANT_BPS_EACH / FeastGenesis.BPS;
        // v1.6.12: a ZERO slot is now allowed and means "not yet named". It can
        // be filled once, by the multisig, inside the 90-day window — see
        // `assignPartner`. A non-zero address must still be distinct, because
        // two slots pointing at one address would pay it twice.
        for (uint256 i = 0; i < FeastGenesis.PARTNERS; i++) {
            address p = partners_[i];
            if (p != address(0)) {
                if (isPartner[p]) revert PartnerMisconfigured(p);
                isPartner[p] = true;
            }
            _partners[i] = p;
        }
    }

    function partners() external view returns (address[8] memory) {
        return _partners;
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

    /// @notice What genesis asks every contract it names.
    function genesisRole() external pure returns (bytes32) {
        return FeastGenesis.ROLE_GRANTS;
    }

    /// @notice Fill an empty partner slot. The team multisig, once per slot,
    ///         inside the guardian's own 90-day window.
    ///
    /// @dev The owner's problem this solves: before v1.6.12 the eight addresses
    ///      were fixed at genesis with no setter, so eight partners had to exist
    ///      before launch or the slots burned. They may now be found afterwards.
    ///
    ///      **What this power is not.** It cannot replace, remove or reassign
    ///      anybody — `_partners[slot] != address(0)` refuses a filled slot
    ///      whether it was filled at genesis or filled last week — and it moves
    ///      no value: the grant was already in this contract and unlocks only by
    ///      the fees the partner's own referrals bring.
    ///
    ///      **One key and one deadline, both read from the guardian.** The
    ///      caller must be `guardian.guardian()` — the same multisig that holds
    ///      the brake — and the window is `guardian.sunsetAt()`, the same
    ///      instant the freeze power ends. Neither is a constructor argument
    ///      here, so neither can disagree with the guardian's.
    function assignPartner(uint8 slot, address partner) external {
        address multisig = guardian.guardian();
        if (msg.sender != multisig) revert NotTheTeamMultisig(msg.sender);
        // Before genesis there is no window yet. Refusing is the safe
        // direction: a slot cannot be filled against a deadline nobody has set.
        if (!guardian.clockStarted()) revert AssignmentWindowNotOpen();
        uint64 until = guardian.sunsetAt();
        if (block.timestamp > until) revert AssignmentWindowClosed(until);
        if (slot >= FeastGenesis.PARTNERS) revert SlotOutOfRange(slot);
        address held = _partners[slot];
        if (held != address(0)) revert SlotAlreadyFilled(slot, held);
        if (partner == address(0) || isPartner[partner]) revert PartnerMisconfigured(partner);
        if (slotBurned[slot]) revert SlotAlreadyBurned(slot);

        _partners[slot] = partner;
        isPartner[partner] = true;
        // The instant before which no week counts for them. See `checkpoint`.
        assignedAt[partner] = uint64(block.timestamp);
        emit PartnerAssigned(slot, partner);
    }

    /// @notice Burn the grant of a slot nobody ever filled, once the window to
    ///         fill it has closed. Anyone may call.
    ///
    /// @dev **This is a new entry point, and it has to be.** The ruling asked for
    ///      the existing rule with no new path, and `burnUnearned` cannot reach
    ///      here: it takes a partner ADDRESS and an empty slot has none. Without
    ///      something that addresses the SLOT, a grant for a partner who was
    ///      never named would sit in this contract for ever with no way out,
    ///      which is exactly the stranding I14 forbids.
    ///
    ///      It is the same rule, not a new one: what a slot did not earn is
    ///      burned. An empty slot earned nothing and can no longer be filled, so
    ///      it waits for the assignment window rather than for the 26-week
    ///      horizon — the horizon exists to give a partner time to earn, and a
    ///      slot with no partner has nobody to give it to. It is guarded like
    ///      every other irreversible destruction.
    function burnUnfilledSlot(uint8 slot) external {
        _requireUnfrozen();
        if (slot >= FeastGenesis.PARTNERS) revert SlotOutOfRange(slot);
        // And a slot cannot be BURNED against a deadline nobody has set either
        // — that direction is the one that destroys value.
        if (!guardian.clockStarted()) revert AssignmentWindowNotOpen();
        uint64 until = guardian.sunsetAt();
        if (block.timestamp <= until) revert AssignmentWindowOpen(until);
        address held = _partners[slot];
        if (held != address(0)) revert SlotIsFilled(slot, held);
        if (slotBurned[slot]) revert SlotAlreadyBurned(slot);
        slotBurned[slot] = true;
        emit UnfilledSlotBurned(slot, grant);
        IFeastBurnableGrant(address(platformCoin)).burn(grant);
    }

    /// @notice Add emission week `n`'s referred fees to `partner`'s count, once.
    function checkpoint(address partner, uint256 n) public {
        if (!isPartner[partner]) revert NotAPartner(partner);
        if (n == 0 || n > FeastGenesis.GRANT_WEEKS) revert WeekOutOfRange(n);
        if (emissions.settledCount() < n) revert NotSettled(n);
        uint256 bit = 1 << n;
        if (_counted[partner] & bit != 0) return;
        _counted[partner] |= bit;

        // **A partner assigned late does not arrive with a head start.** The
        // address in an assigned slot may have been referring fees all along as
        // an ordinary referrer, and `emissions.referredValue` would hand every
        // one of those weeks to the grant. A week that had already CLOSED when
        // the slot was filled counts zero — and is still marked counted, so it
        // can never be picked up later.
        //
        // A week still open at the moment of assignment counts in FULL, which is
        // at most one week of head start and is stated rather than hidden: the
        // alternative is apportioning a week's fees by the hour, which the
        // weekly ledger cannot do and which no other number in this system does.
        //
        // `assignedAt` is zero for the eight named at genesis, and a week's
        // close is always positive, so the eight take the same branch and lose
        // nothing.
        uint64 from = assignedAt[partner];
        uint256 value;
        if (from == 0 || emissions.ledger().weekStart(emissions.ledgerWeekOf(n) + 1) > from) {
            value = emissions.referredValue(n, partner);
            referredNative[partner] += value;
        }
        emit WeekCounted(partner, n, value);
    }

    /// @notice Count every settled week of the horizon not yet counted.
    function checkpointAll(address partner) public {
        uint256 last = emissions.settledCount();
        if (last > FeastGenesis.GRANT_WEEKS) last = FeastGenesis.GRANT_WEEKS;
        for (uint256 n = 1; n <= last; n++) {
            checkpoint(partner, n);
        }
    }

    /// @dev Round `v1.6.4` G1 (`CA-5ba81ae0e6`). This read
    ///
    ///          uint256 u = grant * referredNative[partner] / targetNative;
    ///          return u > grant ? grant : u;
    ///
    ///      — the numerator formed first, in checked arithmetic, at 256 bits, and
    ///      the clamp that would have made it harmless applied only afterwards.
    ///      The partner who referred the MOST, who had most earned the grant, was
    ///      the one whose numerator overflowed. `claim` and `burnUnearned` both
    ///      route through here, so the grant stranded and its remainder could not
    ///      be burned.
    ///
    ///      **The minimum is established BEFORE anything is multiplied.** Widening
    ///      the product to 512 bits is not enough on its own: `Math.mulDiv` panics
    ///      when its RESULT exceeds 256 bits, which `grant * referred / target`
    ///      does once `referred / target` passes `2**256 / grant` — so a
    ///      multiply-then-clamp spelling reintroduces this very finding in a
    ///      narrower range, which is the shape of the finding one level up.
    ///      Measured, not reasoned: see `plans/v164/plan.md`.
    ///
    ///      Once `referred >= target` the published rule
    ///      `min(grant, grant x referred / target)` is `grant` by inspection, so
    ///      it is returned without dividing. Below the target the quotient is
    ///      strictly less than `grant` and cannot overflow at all. Total for every
    ///      input, and every number published for a partner under the target is
    ///      exactly what it was.
    function unlocked(address partner) public view returns (uint256) {
        uint256 referred = referredNative[partner];
        if (referred >= targetNative) return grant;
        return Math.mulDiv(grant, referred, targetNative);
    }

    /// @notice Pay `partner` what has unlocked and not been paid. Anyone may call.
    function claim(address partner) external returns (uint256 amount) {
        _requireUnfrozen();
        if (!isPartner[partner]) revert NotAPartner(partner);
        if (!emissions.claimsOpen()) revert ClaimsNotOpen();
        checkpointAll(partner);
        amount = unlocked(partner) - claimed[partner];
        if (amount == 0) return 0;
        claimed[partner] += amount;
        emit Claimed(partner, amount);
        platformCoin.safeTransfer(partner, amount);
    }

    /// @dev **The six-month unlock horizon is left alone, and here is why.** It
    ///      is counted in SETTLED WEEKS (`emissions.settledCount() >=
    ///      GRANT_WEEKS`), not in seconds, and a freeze cannot make a week
    ///      settle — `settle` is itself frozen, so the horizon simply arrives
    ///      later by however long the brake was down. The deadline moves with
    ///      the thing it measures, which is what the other three needed a
    ///      subtraction to achieve. Stated rather than silently skipped, per the
    ///      coordinator's ruling of 2026-09-21 09:0x.
    ///
    /// @notice After the 26-week horizon, burn what `partner` did not earn.
    function burnUnearned(address partner) external {
        _requireUnfrozen();
        if (!isPartner[partner]) revert NotAPartner(partner);
        if (!emissions.claimsOpen()) revert ClaimsNotOpen();
        if (emissions.settledCount() < FeastGenesis.GRANT_WEEKS) revert HorizonNotReached();
        if (unearnedBurned[partner]) revert AlreadyBurned(partner);
        checkpointAll(partner);
        unearnedBurned[partner] = true;
        uint256 amount = grant - unlocked(partner);
        emit UnearnedBurned(partner, amount);
        if (amount != 0) IFeastBurnableGrant(address(platformCoin)).burn(amount);
    }
}
