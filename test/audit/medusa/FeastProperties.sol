// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FeastSystem} from "../invariants/FeastSystem.sol";

/// @notice The same v1.6 system and actions as the Foundry invariants, as Medusa properties
///         (contract-audit dynamic layer, task 444, second leg).
contract FeastProperties is FeastSystem {
    function property_conservation() public view returns (bool ok) {
        (ok,) = checkConservation();
    }

    function property_solvency() public view returns (bool ok) {
        (ok,) = checkSolvency();
    }

    function property_filledCoinBacked() public view returns (bool ok) {
        (ok,) = checkFilledCoinBacked();
    }

    function property_referrerLedger() public view returns (bool ok) {
        (ok,) = checkReferrerLedger();
    }

    function property_nothingStrandsAndPlatformIsUnspent() public view returns (bool ok) {
        (ok,) = checkNothingStrandsAndPlatformIsUnspent();
    }

    function property_ghosts() public view returns (bool ok) {
        (ok,) = checkGhosts();
    }
}
