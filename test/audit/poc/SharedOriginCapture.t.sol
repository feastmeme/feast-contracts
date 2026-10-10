// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/console2.sol";

import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {PoolKey} from "../../../src/venue/PoolKey.sol";
import {PoolIdLibrary} from "../../../src/venue/PoolId.sol";
import {VenueBridge} from "../../utils/VenueBridge.sol";
import {FeastReferrerBindingTest} from "../../FeastReferrerBinding.t.sol";

/// **`shared-origin-capture`** — `HK23-claude` MEDIUM, v1.6.20 round, at
/// `src/FeastHook.sol:615-619`.
///
/// The binding form believes the wallet word because it equals `tx.origin`.
/// A bundler, a relayer or a 7702 sponsor IS a `tx.origin` whose calldata its
/// users write — so one user operation can name the bundler as the wallet,
/// bind that origin for life, and every later trade submitted through it pays
/// the stranger instead of the per-trade referrer.
contract SharedOriginCaptureTest is FeastReferrerBindingTest {
    using PoolIdLibrary for PoolKey;
    using VenueBridge for PoolKey;

    /// @dev A swap whose msg.sender and tx.origin differ, which is what a
    ///      bundler actually looks like: the account contract calls the router,
    ///      the bundler signed the transaction.
    function _buyFromAccount(address account, address origin, bytes memory hookData) internal {
        bool zeroForOne = !coinIsCurrency0;
        ICLPoolManager.SwapParams memory params = ICLPoolManager.SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: -1_000e18,
            sqrtPriceLimitX96: zeroForOne ? MIN_SQRT : MAX_SQRT
        });
        vm.prank(account, origin);
        router.swap(key.up(), params, hookData);
    }

    /// **Fixed in v1.6.26 (AstraSec M-4), and run again from v1.6.27.** It was
    /// carried skipped while the defect stood, so the release gate stayed
    /// honest; the red run then measured `referrerOf(bundler)` reading the
    /// attacker `0x...a77Ac` where an uncaptured origin reads zero. Since
    /// v1.6.26 no trade binds — a wallet binds only by its own call or
    /// signature to `FeastReferrals` — and this passes as written.
    function test_aUserOpCannotBindTheBundlerThatSubmittedIt() public {
        address bundler = address(0xB0D1E);
        address attacker = address(0xA77AC);
        address kol = address(0x604);
        address account1 = address(0xACC1);
        address account2 = address(0xACC2);

        // The user operation: account1 calls, the BUNDLER signed, and the
        // calldata names the bundler as the wallet to bind.
        _buyFromAccount(account1, bundler, _binding(attacker, bundler));
        console2.log("referrerOf(bundler):", referrals.referrerOf(bundler));
        assertEq(referrals.referrerOf(bundler), address(0), "a user operation bound the bundler that submitted it");

        // And the consequence: a later, unrelated user through the same bundler
        // naming their own referrer pays the attacker instead.
        _buyFromAccount(account2, bundler, _binding(kol, account2));
        assertGt(hook.referrerPending(key.toId(), kol), 0, "the second user's own referrer was paid nothing");
    }
}
