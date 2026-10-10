// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {FeastEmissions} from "../../../src/FeastEmissions.sol";
import {FeastGenesis} from "../../../src/FeastGenesis.sol";
import {PoolId} from "../../../src/venue/PoolId.sol";
import {PoolKey} from "../../../src/venue/PoolKey.sol";
import {UnitFixture} from "../../utils/UnitFixture.sol";

/// PoC for the v1.6.12 round's HIGH `guardian-expires-emissions` /
/// `claim-window-runs-through-freeze`, reported by `P16` and `P16-claude` — one
/// unit in each family — at `src/FeastEmissions.sol:467-473` and `:497`.
///
///     expiryOf(n) = max(settledAt, openAt) + CLAIM_GRACE      // twelve weeks
///
/// A freeze blocks `claim`. It does not stop that clock. A 72-hour freeze placed
/// before an expiry stops a claimant claiming, and `burnExpired` then destroys
/// the entitlement for ever.
///
/// **It is the argument I used to exempt the launch window, not applied here.**
/// The window is not freezable because its refunds run on a clock and a freeze
/// could only push them past their own hour. An emission claim runs on a clock
/// too. I exempted the one and not the other, and the round found it.
contract FreezeExpiresAClaimPoC is UnitFixture {
    uint256 internal week;

    function setUp() public override {
        super.setUp();
        // Week 1: a real trade by `trader`, exactly as FeastEmissions.t.sol
        // builds one, so the entitlement this PoC is about is an ordinary one.
        (, PoolKey memory keyA) = _create(address(wbnb), bytes32(uint256(1)));
        _buy(keyA, address(wbnb), 100e18, trader, referrer);

        uint256 end = ledger.weekStart(emissions.ledgerWeekOf(1) + 1);
        if (clock < end) _warpTo(end);
        emissions.settle(1);
        _launch(10e18);

        week = 1;
        require(emissions.owed(week, trader) > 0, "the fixture must leave the trader something to lose");
    }

    /// The control: with nobody touching the brake, a claimant who waits until
    /// the last hour of the grace is still paid.
    function test_aClaimantPaidOnTheLastDayOfTheGrace() public {
        uint256 owed = emissions.owed(week, trader);
        _warpTo(emissions.expiryOf(week) - 1 hours);
        emissions.claim(week, trader);
        assertEq(IERC20(feast).balanceOf(trader), owed, "paid, with an hour to spare");
    }

    /// The finding: the same claimant, with the brake pulled over that hour.
    function test_aFreezeCannotEatAClaimsOwnDeadline() public {
        uint256 owed = emissions.owed(week, trader);
        assertGt(owed, 0, "there is an entitlement to lose");

        // Frozen with a day of the grace left, for the full 72 hours.
        _warpTo(emissions.expiryOf(week) - 24 hours);
        vm.prank(multisig);
        guardian.freeze();
        _advance(72 hours);

        // The freeze has lapsed by itself and the claimant comes back.
        assertFalse(guardian.isFrozenAll(), "the brake let go on its own");
        emissions.claim(week, trader);
        assertEq(
            IERC20(feast).balanceOf(trader),
            owed,
            "the freeze ate the last day of this claim's grace and the entitlement with it"
        );
    }

    /// And the burn must not be able to fire on what the freeze locked away.
    function test_burnExpiredCannotFireOnAFrozenClaimWindow() public {
        uint256 owed = emissions.owed(week, trader);

        _warpTo(emissions.expiryOf(week) - 24 hours);
        vm.prank(multisig);
        guardian.freeze();
        _advance(72 hours);

        // The burn must be REFUSED: the window it would burn against has been
        // extended by exactly the time the brake was down.
        vm.expectRevert(abi.encodeWithSelector(FeastEmissions.NotExpired.selector, week));
        emissions.burnExpired(week);

        emissions.claim(week, trader);
        assertEq(IERC20(feast).balanceOf(trader), owed, "and the claimant who was locked out is paid");

        // And once the extended window really has closed, the burn works again:
        // the fix moves the deadline, it does not remove it.
        _warpTo(emissions.expiryOf(week) + 1);
        emissions.burnExpired(week);
    }
}
