// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/console2.sol";

import {PoolKey} from "../../../src/venue/PoolKey.sol";
import {PoolIdLibrary} from "../../../src/venue/PoolId.sol";
import {UnitFixture} from "../../utils/UnitFixture.sol";

/// **`lp-income-platform-share`** — `P3` MEDIUM (Codex) and `P3-claude` LOW
/// (Fable), v1.6.20 round, at `src/FeastHook.sol:1869`.
///
/// The claim: collected LP income redirects its platform share into the coin's
/// self-burn instead of the platform's own burn, so `platformPending` does not
/// move when `collectLpFees` runs.
///
/// **The behaviour is real and it is DECLARED.** The three lines above the site
/// say so in as many words: LP fees have no discoverable earning epoch and the
/// venue reports only a total, so rather than invent an attribution their
/// platform share is withdrawn from the pot and buys and burns instead. This
/// PoC pins the declared behaviour rather than asserting the lens's expectation,
/// so that a future change to it fails here.
contract LpIncomePlatformShareTest is UnitFixture {
    using PoolIdLibrary for PoolKey;

    function test_theLpShareGoesToTheSelfBurnAndNotToPlatformPending() public {
        _genesis();
        (, PoolKey memory key) = _create(address(stock), keccak256("P3"));
        address trader = address(0x7AAD);
        for (uint256 i = 0; i < 4; i++) _buy(key, address(stock), 2_000_000e18, trader, address(0));

        uint256 platformBefore = hook.platformPending(key.toId());
        uint256 accruedBefore = hook.poolInfo(key.toId()).accruedQuote;

        hook.collectLpFees(key);

        uint256 collected = hook.poolInfo(key.toId()).accruedQuote - accruedBefore;
        uint256 platformDelta = hook.platformPending(key.toId()) - platformBefore;
        console2.log("LP income collected :", collected);
        console2.log("platformPending +   :", platformDelta);

        // The witness reaches its bound: LP income really was collected, so
        // "nothing moved" is not the reason the platform share did not.
        assertGt(collected, 0, "no LP income was collected, so this proves nothing");

        // Declared: the platform's share of LP income does NOT join the pot.
        assertEq(platformDelta, 0, "the LP platform share joined the pot; the declared redirection is gone");
    }
}
