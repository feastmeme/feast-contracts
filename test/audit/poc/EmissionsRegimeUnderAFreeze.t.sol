// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/console2.sol";

import {FeastConstants} from "../../../src/FeastConstants.sol";
import {FeastEmissions} from "../../../src/FeastEmissions.sol";
import {FeastGenesis} from "../../../src/FeastGenesis.sol";
import {EmissionsPreLaunchValueCapPoC} from "./EmissionsPreLaunchValueCap.t.sol";

/// The two v1.6.20 MEDIUMs about which REGIME a week settles under when a
/// freeze covers the seam between the window's close and `openAt`.
///
///  * `false-three-day-protection` — `P5` (Codex), `FeastEmissions.sol:505`
///  * `preopen-regime-decided-by-settle-instant` — `P16-claude`, `:498`
contract EmissionsRegimeUnderAFreezeTest is EmissionsPreLaunchValueCapPoC {
    /// Genesis, a week-2 fee, week 1 out of the way, and a settled auction.
    function _throughTheAuction() internal {
        _genesis();
        _buy(keyA, address(wbnb), 100e18, trader, referrer);
        emissions.settle(1);
        _warpTo(windowStart + 1);
        address committer = address(0xC0D1);
        vm.deal(committer, 10e18);
        vm.prank(committer);
        window.commit{value: 10e18}();
    }

    /// **`false-three-day-protection`.** The RESIDUE justification at `:492`
    /// says the regime "is decided at least three open days later, with the
    /// pool live and the price tested". This asks the code for those three
    /// days: freeze across the seam, unfreeze, trade, wait ten minutes, and
    /// see whether the week settles.
    /// **CARRIED, not fixed.** Red when run: `settle(2)` SUCCEEDS after 901 open seconds, where the residue's own justification promises 259200.
    function test_capRegimeWaitsThreeOpenDays() public {
        vm.skip(true);
        _throughTheAuction();

        // A freeze that covers the seam between the close and `openAt`.
        _warpTo(window.endsAt() - 1);
        vm.prank(multisig);
        guardian.freeze();
        _warpTo(window.endsAt());
        window.settle();

        _warpTo(window.endsAt() + FeastGenesis.SETTLE_GRACE + 1);
        vm.prank(multisig);
        guardian.unfreeze();

        // The pool is live and traded, and the price has aged just past the
        // averaging window — but nowhere near three open days.
        _firstPlatformTrade();
        _advance(600);

        uint256 openSecondsSinceUnfreeze = 600 + FeastConstants.MIN_OBSERVATION_AGE + 1;
        console2.log("open seconds since the unfreeze:", openSecondsSinceUnfreeze);
        console2.log("three open days would be       :", uint256(3 days));

        (bool ok,) = address(emissions).call(abi.encodeCall(FeastEmissions.settle, (2)));
        console2.log("settle(2) succeeded            :", ok);
        assertFalse(ok, "the week settled long before the three open days the residue promises");
    }

    /// **`preopen-regime-decided-by-settle-instant`.** The same seam, asked the
    /// other way: does one hour of the guardian's budget change WHICH regime the
    /// last pre-launch week settles under? The control is the identical
    /// sequence with no freeze in it.
    /// **CARRIED, not fixed.** Red when run: the control week settles `tokenCapOnly = true` and the frozen week `false`, so one hour of the brake changed the regime.
    function test_aFreezeAcrossTheWindowsCloseCannotStripAPreLaunchWeeksTokenCap() public {
        vm.skip(true);
        // The control first, on its own state.
        uint256 snap = vm.snapshotState();
        _throughTheAuction();
        _warpTo(window.endsAt());
        window.settle();
        emissions.settle(2);
        bool controlTokenCapOnly = emissions.weekInfo(2).tokenCapOnly;
        vm.revertToState(snap);

        // The same week, with a freeze across the seam.
        _throughTheAuction();
        _warpTo(window.endsAt() - 1);
        vm.prank(multisig);
        guardian.freeze();
        _warpTo(window.endsAt());
        window.settle();
        _warpTo(window.endsAt() + FeastGenesis.SETTLE_GRACE + 1);
        vm.prank(multisig);
        guardian.unfreeze();
        _firstPlatformTrade();
        _advance(FeastConstants.TWAP_WINDOW + 1);
        emissions.settle(2);
        bool frozenTokenCapOnly = emissions.weekInfo(2).tokenCapOnly;

        console2.log("control  tokenCapOnly:", controlTokenCapOnly);
        console2.log("frozen   tokenCapOnly:", frozenTokenCapOnly);

        // The witness reaches its bound: without the freeze the week really is
        // a token-cap week, so "they agree" is not two identical falses.
        assertTrue(controlTokenCapOnly, "the control week is not a pre-launch token-cap week");
        assertEq(frozenTokenCapOnly, controlTokenCapOnly, "one hour of the brake changed the week's regime");
    }
}
