// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FeastGenesis} from "../src/FeastGenesis.sol";

/// @notice The one checker every deploy script calls before it deploys: any
///         placeholder in `src/FeastGenesis.sol` still unset is a refusal, named.
library FeastScriptChecks {
    error Placeholder(string name);
    error WindowMustEndOnAMonday(uint256 windowEnd);
    error PartnersMustBeDistinct(address partner);

    function requirePackage2() internal pure {
        if (FeastGenesis.PACKAGE1_FACTORY == address(0)) revert Placeholder("PACKAGE1_FACTORY");
        if (FeastGenesis.TEAM_MULTISIG == address(0)) revert Placeholder("TEAM_MULTISIG");
        if (FeastGenesis.TARGET_NATIVE == 0) revert Placeholder("TARGET_NATIVE");
        if (FeastGenesis.FACTORY_OPENING == 0) revert Placeholder("FACTORY_OPENING");
        if (!FeastGenesis.PRICED_ROUTES_CONFIRMED) revert Placeholder("PRICED_ROUTES_CONFIRMED");
        // v1.6.12: a genesis naming FEWER than eight partners is valid. An empty
        // slot is no longer a placeholder somebody forgot to fill — it is a slot
        // the team multisig may fill once, inside the guardian's 90-day window,
        // and which burns if they do not. Distinctness still binds, because two
        // slots pointing at one address would pay it twice.
        address[8] memory partners = FeastGenesis.partners();
        for (uint256 i = 0; i < 8; i++) {
            if (partners[i] == address(0)) continue;
            for (uint256 j = 0; j < i; j++) {
                if (partners[j] == partners[i]) revert PartnersMustBeDistinct(partners[i]);
            }
        }
    }

    function requireGenesis() internal pure {
        requirePackage2();
        if (FeastGenesis.PACKAGE2_EMISSIONS == address(0)) revert Placeholder("PACKAGE2_EMISSIONS");
        if (FeastGenesis.PACKAGE2_GRANTS == address(0)) revert Placeholder("PACKAGE2_GRANTS");
        if (FeastGenesis.PACKAGE2_SINK == address(0)) revert Placeholder("PACKAGE2_SINK");
        if (FeastGenesis.TEAM_BENEFICIARY == address(0)) revert Placeholder("TEAM_BENEFICIARY");
        if (FeastGenesis.WINDOW_START == 0) revert Placeholder("WINDOW_START");
        if (!FeastGenesis.PLATFORM_OPENING_TICK_SET) revert Placeholder("PLATFORM_OPENING_TICK");
        if (FeastGenesis.PLATFORM_METADATA_HASH == bytes32(0)) revert Placeholder("PLATFORM_METADATA_HASH");
        uint256 windowEnd = FeastGenesis.WINDOW_START + FeastGenesis.WINDOW_DURATION;
        // Emission weeks and the window's close line up: the window closes as a
        // ledger week turns (Monday 00:00 UTC).
        if ((windowEnd + FeastGenesis.WEEK_ALIGNMENT) % FeastGenesis.WEEK_LENGTH != 0) {
            revert WindowMustEndOnAMonday(windowEnd);
        }
    }
}
