// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {FeastConstants} from "../../../src/FeastConstants.sol";
import {UnitFixture} from "../../utils/UnitFixture.sol";

/// PoC for the v1.6.9 pack's HIGH `gated-pool-cap-dead`, reported by the economic-promise
/// hunter unit `P6-claude` at `src/FeastHook.sol:328`, and corroborated by the hook-checklist
/// triage unit `r1h-claude` as LOW `fair-open` at `src/FeastHook.sol:324-329`.
///
/// The promise (README, the site's card 2, and `docs/plan.md:428`): **a per-wallet cap applies
/// in the opening blocks of every pool**, and the opening purchases are public and readable
/// from the chain.
///
/// The cap and the gate run on two different clocks.
///
///     // src/FeastHook.sol:324-329, at pool initialization
///     p.capEndBlock = uint64(block.number) + FeastConstants.CAP_BLOCKS;   // a BLOCK window (v1.6.9; a COUNT of served blocks since v1.6.16)
///
///     // src/FeastHook.sol:517, on every swap
///     if (block.timestamp < p.openAt && sender != p.opener) revert PoolNotOpenYet(p.openAt);
///                                                                    // a TIMESTAMP gate
///
/// For an ordinary coin the two never meet: there is no gate, and trading starts in the
/// creation block, so the two-block window is exactly the opening blocks. The platform coin is
/// the one pool that carries both. Genesis registers it with the launch window as `opener` and
/// an `openAt` the genesis key names; the recipe sets that to the window's close plus the
/// one-hour grace (`script/Genesis.s.sol:69-76`), so the public may first trade at least 25
/// hours after genesis. On BSC that is on the order of 120,000 blocks. By the first block in
/// which anyone but the window may trade, `block.number` is long past that height, so the
/// branch at `src/FeastHook.sol:745` is never entered: the cap is not exceeded, it is never
/// consulted, `_purchased` is never written, and `purchasedDuringOpening` answers zero for
/// every wallet for ever.
///
/// This test asserts the promise behaviourally — that the cap OBSERVES the first public
/// purchase — rather than asserting a revert at a size that would need the pool's curve to be
/// solved. It fails today at the first assertion.
contract GatedPoolOpeningCapPoC is UnitFixture {
    function test_theOpeningCapCoversTheFirstPublicBlockOfTheGatedPool() public {
        _launch(1 ether);

        // The day of chain the calendar above puts between genesis and `openAt`. The fixture's
        // `_warpTo` rolls one block per warp, so without this the pool opens four blocks after
        // genesis and the defect is a one-block miss; on the real chain it is five figures.
        // Either way the branch is closed, and rolling makes the test say which world it is in.
        vm.roll(vm.getBlockNumber() + 120_000);

        uint256 cap = hook.perWalletCap(feastPoolId);
        assertGt(cap, 0, "the platform pool has a per-wallet cap at all");

        // v1.6.11: the pool now opens at the auction's clearing price, which is set by the
        // one-ether pot above, so the platform coin is cheap and the 50 ether this test used to
        // spend buys far past the 0.5%-of-supply cap — it reverts `PurchaseCapExceeded`, which
        // is the FIXED behaviour and not what this test measures. Stay under the cap: the claim
        // here is that the cap OBSERVES the first public purchase, not that it bites on it.
        address trader = address(0xBEEF);
        uint256 before = IERC20(feast).balanceOf(address(router));
        _buy(feastKey, address(wbnb), 0.01 ether, trader, address(0));
        uint256 bought = IERC20(feast).balanceOf(address(router)) - before;
        assertLe(bought, cap, "the witness stays under the cap, so an observation is possible");

        // The witness has to reach its bound. Without this the first assertion below would
        // also fail for a trade that bought NOTHING, and the test would "prove" the defect
        // while measuring a no-op.
        assertGt(bought, 0, "the trade bought no platform coin, so this test witnesses nothing");

        assertGt(
            hook.purchasedDuringOpening(feastPoolId, trader),
            0,
            "the opening cap never observed the first public purchase of the platform pool"
        );
        assertTrue(
            hook.capBinds(feastPoolId),
            "the opening-cap window closed before the gated pool opened to the public"
        );
    }
}
