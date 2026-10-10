// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {FeastSystem} from "./FeastSystem.sol";

/// @notice Stateful whole-system invariants over v1.6's day-one surface (task 444, second leg).
contract FeastInvariants is Test {
    FeastSystem internal sys;

    function setUp() public {
        sys = new FeastSystem();
        targetContract(address(sys));
        bytes4[] memory selectors = new bytes4[](7);
        selectors[0] = FeastSystem.swap.selector;
        selectors[1] = FeastSystem.claim.selector;
        selectors[2] = FeastSystem.buyBack.selector;
        selectors[3] = FeastSystem.collect.selector;
        selectors[4] = FeastSystem.elapse.selector;
        selectors[5] = FeastSystem.freeze.selector;
        selectors[6] = FeastSystem.burnFilled.selector;
        targetSelector(FuzzSelector({addr: address(sys), selectors: selectors}));
    }

    /// forge-config: default.invariant.runs = 32
    /// forge-config: default.invariant.depth = 40
    /// forge-config: ci.invariant.runs = 512
    /// forge-config: ci.invariant.depth = 128
    function invariant_conservation() public view {
        (bool ok, string memory why) = sys.checkConservation();
        assertTrue(ok, why);
    }

    /// forge-config: default.invariant.runs = 32
    /// forge-config: default.invariant.depth = 40
    /// forge-config: ci.invariant.runs = 512
    /// forge-config: ci.invariant.depth = 128
    function invariant_solvency() public view {
        (bool ok, string memory why) = sys.checkSolvency();
        assertTrue(ok, why);
    }

    /// forge-config: default.invariant.runs = 32
    /// forge-config: default.invariant.depth = 40
    /// forge-config: ci.invariant.runs = 512
    /// forge-config: ci.invariant.depth = 128
    function invariant_filledCoinBacked() public view {
        (bool ok, string memory why) = sys.checkFilledCoinBacked();
        assertTrue(ok, why);
    }

    /// forge-config: default.invariant.runs = 32
    /// forge-config: default.invariant.depth = 40
    /// forge-config: ci.invariant.runs = 512
    /// forge-config: ci.invariant.depth = 128
    function invariant_referrerLedger() public view {
        (bool ok, string memory why) = sys.checkReferrerLedger();
        assertTrue(ok, why);
    }

    /// forge-config: default.invariant.runs = 32
    /// forge-config: default.invariant.depth = 40
    /// forge-config: ci.invariant.runs = 512
    /// forge-config: ci.invariant.depth = 128
    function invariant_nothingStrandsAndPlatformIsUnspent() public view {
        (bool ok, string memory why) = sys.checkNothingStrandsAndPlatformIsUnspent();
        assertTrue(ok, why);
    }

    /// forge-config: default.invariant.runs = 32
    /// forge-config: default.invariant.depth = 40
    /// forge-config: ci.invariant.runs = 512
    /// forge-config: ci.invariant.depth = 128
    function invariant_ghosts() public view {
        (bool ok, string memory why) = sys.checkGhosts();
        assertTrue(ok, why);
    }

    /// Every action lands at least once, so a green run is not green because nothing happened.
    function test_everyActionLandsInAScriptedSequence() public {
        sys.swap(0, true, true, 16, 4);
        sys.swap(1, true, true, 16, 4);
        sys.swap(2, true, false, 15, 0);
        sys.elapse(400);
        sys.swap(0, true, true, 15, 4);
        sys.elapse(400);
        sys.swap(0, false, true, 15, 0);
        sys.elapse(1_500);
        sys.swap(0, true, true, 13, 0);
        assertEq(sys.ghostSwapsLanded(), 6, "all six swaps landed");

        sys.buyBack(0, 15);
        assertEq(sys.ghostBuybacksLanded(), 1, "the buy-back landed");
        sys.claim(0, 0);
        assertEq(sys.ghostClaimsPaid(), 1, "the claim paid");
        sys.collect(0);
        assertEq(sys.ghostCollectsBanked(), 1, "LP fees were banked");
        sys.burnFilled(0);
        sys.freeze(true);
        vm.expectRevert();
        sys.claim(2, 2);
        sys.freeze(false);
        sys.claim(2, 2);
        assertEq(sys.ghostClaimsPaid(), 2, "the delayed claim paid after the thaw");

        (bool ok, string memory why) = sys.checkSolvency();
        assertTrue(ok, why);
        (ok, why) = sys.checkConservation();
        assertTrue(ok, why);
        (ok, why) = sys.checkFilledCoinBacked();
        assertTrue(ok, why);
    }
}
