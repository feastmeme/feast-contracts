// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {FeastGuardian} from "../../../src/FeastGuardian.sol";
import {PoolId} from "../../../src/venue/PoolId.sol";
import {PoolKey} from "../../../src/venue/PoolKey.sol";
import {UnitFixture} from "../../utils/UnitFixture.sol";

/// The owner's two rulings of 2026-09-22, each with the finding that asked for
/// it and the control that stops the test being a test of nothing.
contract ScopedFreezeAndMinimumChargePoC is UnitFixture {
    address internal taker = address(0x7A4E5);
    PoolId internal constant ALL = PoolId.wrap(bytes32(0));

    // --- ruling 2 was superseded: there is one scope ----------------------
    //
    // Owner ruling 2 of 2026-09-22 split frozen-time accounting by scope, so
    // that a freeze on one coin's pool could not hold the price of every lot in
    // the sink. Four tests lived here and passed.
    //
    // The owner removed the pool-scoped freeze entirely on the same day, after
    // the v1.6.16 round showed that the surgical freeze was the instrument
    // every defeat of the opening purchase cap needed. With one scope there is
    // no accounting to split, no overlap to prevent and no per-pool counter to
    // read, so those four tests are gone rather than rewritten into assertions
    // about a thing that does not exist. What replaced them:
    //
    //   - `FeastGuardianTest.test_aFreezeStopsEveryPoolBecauseThereIsNoOtherKind`
    //   - `V1616RoundFindingsPoC` — the guardian cannot clear a room it must
    //     also stay out of
    //   - `FreezeRunsTheSettlementClocksPoC` — the grace and the aging rule
    //     read one instant and agree

    // --- ruling 5: a minimum charge per pull -------------------------------

    /// A freeze lifted in the second it was placed refunded its whole grant and
    /// folded zero, so a freeze/unfreeze pair per block refused every guarded
    /// call ordered between them at no cost — and the 168-hour lifetime bound,
    /// whose whole job is to bound the brake, did not bind it (`P17-claude`
    /// MEDIUM).
    function test_aFreezeLiftedInItsOwnSecondStillCostsAnHour() public {
        _launch(10e18);
        uint64 spentBefore = guardian.spent();

        vm.prank(multisig);
        guardian.freeze();
        vm.prank(multisig);
        guardian.unfreeze();

        assertEq(guardian.spent() - spentBefore, guardian.MIN_FREEZE_CHARGE(), "the pull cost the minimum");
        assertEq(guardian.frozenSeconds(), 0, "and moved no other clock by more than it was frozen");
    }

    /// The count is bounded, which is what the minimum buys. `FREEZE_BUDGET` is
    /// 168 hours and the minimum is one, so 168 pulls exhaust it exactly and the
    /// next is refused.
    function test_theLifetimeBudgetAllowsExactlyOneHundredAndSixtyEightPulls() public {
        _launch(10e18);
        uint256 pulls = guardian.FREEZE_BUDGET() / guardian.MIN_FREEZE_CHARGE();
        for (uint256 i = 0; i < pulls; i++) {
            vm.prank(multisig);
            guardian.freeze();
            vm.prank(multisig);
            guardian.unfreeze();
            _advance(1);
        }
        assertEq(guardian.budgetLeft(), 0, "one hundred and sixty-eight pulls is the whole budget");

        // The expected data is built FIRST: an external call between
        // `vm.prank`/`vm.expectRevert` and the call under test consumes the
        // cheatcode, and the test then passes on the wrong revert or on none.
        uint64 budget = guardian.FREEZE_BUDGET();
        bytes memory expected =
            abi.encodeWithSelector(FeastGuardian.FreezeBudgetSpent.selector, budget, budget);
        vm.prank(multisig);
        vm.expectRevert(expected);
        guardian.freeze();
    }

    /// The minimum binds SHORT pulls and nothing else: an ordinary freeze held
    /// past the minimum is charged exactly what it was before, to the second.
    function test_anOrdinaryFreezeIsChargedExactlyAsBefore() public {
        _launch(10e18);
        uint64 spentBefore = guardian.spent();

        vm.prank(multisig);
        guardian.freeze();
        _advance(12 hours);
        vm.prank(multisig);
        guardian.unfreeze();

        assertEq(guardian.spent() - spentBefore, 12 hours, "held for twelve hours, charged twelve hours");
        assertEq(guardian.frozenSeconds(), 12 hours, "and the clocks saw all of it");
    }
}
