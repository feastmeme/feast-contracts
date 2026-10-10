// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {FeastGenesisGrants} from "../../../src/FeastGenesisGrants.sol";
import {FeastGuardian} from "../../../src/FeastGuardian.sol";
import {UnitFixture} from "../../utils/UnitFixture.sol";

/// **`pre-genesis-frozen-time-credits-the-partner-window`** — `CA-e6c52f8b45`,
/// `P16-claude` LOW, v1.6.20 round, at `src/FeastGuardian.sol:462`.
///
/// The claim: `freeze()` is live before genesis (`:222-225` checks the sunset
/// only once the clock has started), and every second it holds enters
/// `frozenSeconds()` through `_fold`. `sunsetAt()` then adds the WHOLE of
/// `frozenSeconds()` to genesis + 90 days — so seconds spent before the window
/// existed lengthen it, and delay `burnUnfilledSlot` by as much as the lifetime
/// budget, `FREEZE_BUDGET = 168 hours`.
///
/// The sibling of `CA-7dca95d8e3` (`GuardianWindowExtension.t.sol`), which
/// measures 72 hours of it against `sunsetAt()`. This witness spends the WHOLE
/// budget before genesis and asks the question the row is about: whether an
/// unfilled slot can still be burned the moment the ninety days are over.
///
/// Measured at `v1.6.21-audit` (`e5c0a77`): the whole 604800 seconds of budget
/// are spent before genesis, `sunsetAt()` reads `g0 + 90 days + 604800`, and
/// `burnUnfilledSlot(6)` at `g0 + 90 days + 1` reverts
/// `AssignmentWindowOpen(g0 + 90 days + 604800)` — the burn is a week late.
contract PreGenesisFreezeSlotBurnTest is UnitFixture {
    function _sixOfEight() internal pure returns (address[8] memory six) {
        for (uint256 i = 0; i < 6; i++) six[i] = address(uint160(0xBB00 + i));
    }

    /// Freeze, let it lapse, settle the lapse, and go again, until the budget
    /// is gone. Each settle stamps its block, so the next freeze is a block on.
    function _spendTheWholeBudgetBeforeGenesis() internal {
        while (guardian.budgetLeft() != 0) {
            uint64 grant = guardian.budgetLeft() < guardian.FREEZE_MAX() ? guardian.budgetLeft() : guardian.FREEZE_MAX();
            vm.prank(multisig);
            guardian.freeze();
            _advance(grant);
            guardian.settleLapsed();
            _advance(1);
        }
    }

    function test_theWholeBudgetSpentBeforeGenesisPostponesNoUnfilledSlotBurn() public {
        // RED on v1.6.21-audit and on v1.6.22 (measured): `burnUnfilledSlot(6)` at g0 + 90 days + 1 reverts AssignmentWindowOpen(g0 + 90 days + 604800), because `sunsetAt()` counts pre-genesis frozen seconds — the guardian clock, not genesis trust; skipped for the owner's separate decision (coordinator 2026-09-25 23:5x)
        vm.skip(true);
        _spendTheWholeBudgetBeforeGenesis();
        assertFalse(guardian.clockStarted(), "all of it before genesis");
        assertEq(guardian.frozenSeconds(), guardian.FREEZE_BUDGET(), "the whole budget, frozen");

        _genesis();
        uint64 g0 = guardian.genesisStartedAt();

        // A grants contract with two empty slots, funded the way genesis funds
        // the real one, so a burn has something real to burn.
        FeastGenesisGrants g =
            new FeastGenesisGrants(feast, address(emissions), TARGET, _sixOfEight(), address(guardian));
        uint256 endowment = g.grant() * 8;
        vm.prank(address(grants));
        IERC20(feast).transfer(address(g), endowment);

        console2.log("sunsetAt     :", guardian.sunsetAt());
        console2.log("g0 + 90 days :", uint256(g0) + 90 days);

        // The ninety days are over. An empty slot burns now, not a week from now.
        _warpTo(uint256(g0) + 90 days + 1);
        g.burnUnfilledSlot(6);
        assertTrue(g.slotBurned(6), "the empty slot burned the moment the ninety days ended");
        assertEq(IERC20(feast).balanceOf(address(g)), endowment - g.grant(), "and its grant is gone");

        // And the window those frozen seconds would have extended is shut.
        vm.prank(multisig);
        vm.expectRevert(abi.encodeWithSelector(FeastGenesisGrants.AssignmentWindowClosed.selector, uint64(g0 + 90 days)));
        g.assignPartner(7, address(0x1A7E));
    }
}
