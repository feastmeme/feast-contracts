// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/console2.sol";

import {FeastEmissions} from "../../../src/FeastEmissions.sol";
import {FeastGenesis} from "../../../src/FeastGenesis.sol";
import {EmissionsMovedQuoteZeroedPoC} from "./EmissionsMovedQuoteZeroed.t.sol";

/// **`pricing-grace-restart`** — HIGH, Codex family, appendix round on
/// `v1.6.21-audit`, at `src/FeastEmissions.sol:316`.
///
/// The pricing grace runs from `max(closesAt, allUnfrozenAt())`. `allUnfrozenAt()`
/// moves on ANY unfreeze, so a freeze taken and lifted in the same second —
/// after the original three days have already expired — grants a fresh three
/// days. A week that could be settled a moment ago reverts `QuoteUnpriceable`,
/// and the guardian can repeat it for as long as it holds the brake.
contract PricingGraceRestartTest is EmissionsMovedQuoteZeroedPoC {
    function test_aZeroDurationFreezeDoesNotRestartAnExpiredPricingGrace() public {
        _closeWeek(1);
        _advance(FeastGenesis.PRICING_GRACE + 1);

        // The listed stock quote has no history to read: `Unpriceable`, the
        // status the grace exists for.
        stockPool.setCardinality(1);

        // **The control.** Past the grace, an unpriceable quote counts as zero
        // and the week settles. Without this the assertion below could pass on
        // a week that was never settleable at all.
        uint256 snap = vm.snapshotState();
        (bool control,) = address(emissions).call(abi.encodeCall(FeastEmissions.settle, (1)));
        console2.log("control settle(1) succeeded :", control);
        assertTrue(control, "the week was not settleable even before the freeze; the witness proves nothing");
        vm.revertToState(snap);

        // The same instant, with a freeze taken and lifted without any time
        // passing at all. No frozen seconds are spent.
        vm.prank(multisig);
        guardian.freeze();
        vm.prank(multisig);
        guardian.unfreeze();

        (bool after_, bytes memory err) = address(emissions).call(abi.encodeCall(FeastEmissions.settle, (1)));
        console2.log("after zero-duration freeze  :", after_);
        if (!after_ && err.length >= 4) console2.logBytes4(bytes4(err));

        assertTrue(after_, "a freeze of zero duration restarted a pricing grace that had already expired");
    }
}
