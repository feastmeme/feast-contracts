// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolKey} from "../../../src/venue/PoolKey.sol";
import {PoolIdLibrary} from "../../../src/venue/PoolId.sol";

import {FeastFactory} from "../../../src/FeastFactory.sol";
import {FeastGenesis} from "../../../src/FeastGenesis.sol";
import {FeastLaunchWindow} from "../../../src/FeastLaunchWindow.sol";
import {FeastTeamVesting} from "../../../src/FeastTeamVesting.sol";
import {UnitFixture} from "../../utils/UnitFixture.sol";

/// The three MEDIUMs of the v1.6.20 round that are all the same shape: genesis
/// interrogates a named contract about some of what it must be, and not about
/// the rest. Each is a question genesis does not ask, and each leaves value in
/// a contract with no function that can move it again.
///
///  * `genesis-window-key-unchecked` — `P4-claude`, `FeastFactory.sol:360`
///  * `team-wallet-guardian-unchecked` — `P8-claude`, `FeastFactory.sol:428-434`
///  * `sink-arming-unenforced` — `P12-claude`, `FeastPlatformSink.sol:244`
contract GenesisTimeChecksTest is UnitFixture {
    using PoolIdLibrary for PoolKey;

    /// **`genesis-window-key-unchecked`.** Genesis asks the window its role,
    /// its coin, its close and its opening liquidity — and never its
    /// `poolKey()`. A window keyed to a pool genesis does not register takes
    /// the whole auction tranche and can never place it.
    function test_genesisRefusesAWindowBuiltOnAnotherPoolKey() public {
        _warpTo(windowStart - 1 days);

        // The same window in every respect the factory asks about, keyed to a
        // pool at a different fee tier.
        PoolKey memory wrongKey = feastKey;
        wrongKey.fee = 500;
        window = new FeastLaunchWindow(
            address(wbnb), feast, address(vault), address(pm), address(hook), address(factory),
            wrongKey, uint64(windowStart)
        );

        // Arm the sink against THIS window, so that the only question left
        // unanswered is the key. Without this the sink's own check fires first
        // and the test passes for the wrong reason — which is exactly what the
        // mutation sweep caught when this was a bare `expectRevert`.
        vm.prank(genesisKey);
        sink.schedule(address(window));

        FeastFactory.GenesisParams memory p = _genesisParams();
        vm.expectRevert(
            abi.encodeWithSelector(
                FeastFactory.WindowPoolKeyMismatch.selector,
                window.poolKey().toId(),
                factory.platformPoolKey().toId()
            )
        );
        vm.prank(genesisKey);
        factory.genesis(p);
    }

    /// **`team-wallet-guardian-unchecked`.** Genesis asks the team wallet when
    /// it starts but not which guardian it obeys. A wallet built against an
    /// address with no code answers every question genesis does ask, and then
    /// every release reverts inside `guardian.isFrozenAll()` for ever.
    function test_genesisRefusesATeamWalletThatAnswersToTheWrongGuardian() public {
        _warpTo(windowStart - 1 days);
        FeastTeamVesting rogue =
            new FeastTeamVesting(beneficiary, uint64(window.endsAt()), feast, address(0xBAD));
        vm.prank(genesisKey);
        sink.schedule(address(window));

        FeastFactory.GenesisParams memory p = _genesisParams();
        p.teamVesting = address(rogue);
        vm.expectRevert(
            abi.encodeWithSelector(
                FeastFactory.TeamVestingGuardianMismatch.selector, address(0xBAD), address(guardian)
            )
        );
        vm.prank(genesisKey);
        factory.genesis(p);
    }

    /// The consequence, asserted separately so the strand is on the record even
    /// while the refusal above is red: the team's whole allocation becomes
    /// unreachable.
    function test_aTeamWalletOnTheWrongGuardianStrandsItsAllocation() public {
        _warpTo(windowStart - 1 days);
        FeastTeamVesting rogue =
            new FeastTeamVesting(beneficiary, uint64(window.endsAt()), feast, address(0xBAD));
        FeastFactory.GenesisParams memory p = _genesisParams();
        p.teamVesting = address(rogue);
        vm.prank(genesisKey);
        try factory.genesis(p) {
            // genesis admitted it — so the wallet now holds the allocation
            _warpTo(window.endsAt() + 30 days);
            vm.prank(beneficiary);
            (bool ok,) = address(rogue).call(abi.encodeWithSignature("release(address)", feast));
            assertTrue(ok, "the team allocation cannot be released and nothing can move it");
        } catch {
            // genesis refused: the fix is in and there is nothing to strand
            assertTrue(true);
        }
    }

    /// **`sink-arming-unenforced`.** Nothing checks that the named sink is
    /// armed. `schedule` refuses a window that has already closed, so a sink
    /// nobody armed before the close can never be armed — and the pot's 1%,
    /// already transferred to it by `settle`, has no function that can move it.
    function test_aSinkTheFeeReachesCanStillBeArmed() public {
        // Genesis WITHOUT the fixture's `sink.schedule` half.
        _warpTo(windowStart - 1 days);
        FeastFactory.GenesisParams memory p = _genesisParams();
        vm.prank(genesisKey);
        try factory.genesis(p) {
            // Admitted. Run the window to its close and let the fee land.
            _warpTo(windowStart + 1);
            address committer = address(0xC0D1);
            vm.deal(committer, 10 ether);
            vm.prank(committer);
            window.commit{value: 10 ether}();
            _warpTo(window.endsAt());
            window.settle();
            assertEq(IERC20(address(wbnb)).balanceOf(address(sink)), 0.1 ether, "the fee reached the sink");

            // The sink must still be armable, or that fee is stranded for ever.
            vm.prank(genesisKey);
            sink.schedule(address(window));
            assertEq(sink.opensAt(), window.endsAt(), "the sink is armed at the window's close");
        } catch {
            // Genesis refused an unarmed sink: the fix is in, and the fee never
            // reaches a sink that cannot open.
            assertTrue(true);
        }
    }
}
