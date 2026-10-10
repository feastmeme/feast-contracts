// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FeastFactory} from "../../../src/FeastFactory.sol";
import {FeastTeamVesting} from "../../../src/FeastTeamVesting.sol";
import {UnitFixture} from "../../utils/UnitFixture.sol";

/// PoC for the v1.6.9 pack's MEDIUM `vesting-start-unenforced`, reported by the
/// economic-promise hunter unit `P8-claude` at `src/FeastFactory.sol:253`.
///
/// The promise (README, `docs/plan.md` Q27, and the site's mechanism sentence): **the team's
/// 25% vests linearly over 36 months FROM THE WINDOW'S CLOSE.**
///
/// `genesis` asks each recipient for the right answer rather than checking it against a list —
/// `_requireRecipient(g.teamVesting, ROLE_TEAM_VESTING, coinToBe)` — and that question is only
/// "are you a team vesting wallet, and is this your platform coin?". The wallet's vesting START
/// is a constructor argument nobody checks. The duration is fixed in code
/// (`FeastGenesis.TEAM_VESTING_DURATION`), so the "36 months" half of the promise is a
/// mechanism; "from the window's close" is a timestamp the genesis key types.
///
/// This is a one-shot privileged call and the factory's own docstring calls what it names
/// "deployment decisions". The distinction this test draws is narrower than that: the START is
/// the one deployment decision the promise makes a GUARANTEE about, and it is the one genesis
/// does not ask about. A wallet whose start is zero passes every check genesis makes and is
/// fully releasable before the window has even opened.
///
/// Fails today at the first assertion: genesis accepts it.
contract TeamVestingStartPoC is UnitFixture {
    function test_genesisRefusesATeamWalletThatDoesNotVestFromTheWindowsClose() public {
        _warpTo(windowStart - 1 days);

        // Same beneficiary, same coin, same role, same duration — only the start differs.
        FeastTeamVesting rogue = new FeastTeamVesting(beneficiary, 0, feast, address(guardian));

        FeastFactory.GenesisParams memory p = _genesisParams();
        p.teamVesting = address(rogue);

        vm.prank(genesisKey);
        try factory.genesis(p) {
            // It was accepted. Show what that buys, so the failure below is not abstract.
            assertEq(
                rogue.start(),
                window.endsAt(),
                "genesis accepted a team wallet whose vesting does not start at the window's close"
            );
        } catch {
            // A refusal is the behaviour the promise implies; nothing to prove.
            return;
        }
    }

    /// The test above is the PoC and is left exactly as it was written while the defect was
    /// open, so that "red before, green after" means the same bytes both times. Its `catch` is
    /// bare, though, so on its own it would go green on ANY revert — which the v1.6.10 diff
    /// round's `r2a-claude` lens reported as LOW `poc-bare-catch`: "the fix-3 witness passes on
    /// any revert; no test names TeamVestingStartNotWindowClose". These two name it.
    ///
    /// Note the cheatcode order. `vm.prank` followed by `vm.expectRevert` is consumed by the
    /// cheatcode rather than by `genesis`, and the call then reverts `NotGenesisKey()` — which
    /// is a passing test that proves nothing about this fix. `expectRevert` first, `prank`
    /// second, call third.
    function test_theRefusalNamesTheStartAndTheCloseItWanted() public {
        _warpTo(windowStart - 1 days);
        FeastTeamVesting rogue = new FeastTeamVesting(beneficiary, 0, feast, address(guardian));
        FeastFactory.GenesisParams memory p = _genesisParams();
        p.teamVesting = address(rogue);

        vm.expectRevert(
            abi.encodeWithSelector(FeastFactory.TeamVestingStartNotWindowClose.selector, 0, window.endsAt())
        );
        vm.prank(genesisKey);
        factory.genesis(p);
    }

    /// One second is enough; the check is equality, not a bound.
    function test_aWalletStartingOneSecondAfterTheCloseIsRefused() public {
        _warpTo(windowStart - 1 days);
        FeastTeamVesting late_ = new FeastTeamVesting(beneficiary, uint64(window.endsAt()) + 1, feast, address(guardian));
        FeastFactory.GenesisParams memory p = _genesisParams();
        p.teamVesting = address(late_);

        vm.expectRevert(
            abi.encodeWithSelector(
                FeastFactory.TeamVestingStartNotWindowClose.selector, window.endsAt() + 1, window.endsAt()
            )
        );
        vm.prank(genesisKey);
        factory.genesis(p);
    }

    /// And the real wallet, whose start IS the window's close, still passes.
    function test_theRealTeamWalletStillPasses() public {
        _genesis();
        assertTrue(factory.genesisDone(), "genesis still runs for a correctly started wallet");
    }
}
