// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Currency} from "../../../src/venue/Currency.sol";
import {Hooks} from "infinity-core/src/libraries/Hooks.sol";
import {CustomRevert} from "infinity-core/src/libraries/CustomRevert.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";

import {FeastConstants} from "../../../src/FeastConstants.sol";
import {FeastFactory} from "../../../src/FeastFactory.sol";
import {FeastHook} from "../../../src/FeastHook.sol";
import {IFeastCLHooks} from "../../../src/venue/IFeastCLHooks.sol";
import {PoolId} from "../../../src/venue/PoolId.sol";
import {PoolKey} from "../../../src/venue/PoolKey.sol";
import {UnitFixture} from "../../utils/UnitFixture.sol";
import {VenueBridge} from "../../utils/VenueBridge.sol";

/// The v1.6.15 round's findings, verified rather than taken on the lens's word.
///
/// Both of the ones that matter attack claims THIS release wrote down, which is
/// the fourth time in this lane that a fix has created a new member of the
/// population the sweep enumerates.
contract V1615RoundFindingsPoC is UnitFixture {
    using VenueBridge for PoolKey;

    /// **`guardian-spends-opening-cap`** — `P6-claude` MEDIUM, and
    /// `P16-claude` MEDIUM under the name `guardian-arms-then-freezes-cap-window`.
    ///
    /// v1.6.15 anchored the opening cap on a pool's first SERVED swap and wrote
    /// down the boundary that remains: once armed the window is wall blocks, so
    /// a freeze landed inside it still passes. The excluded adversary was
    /// stated as "a guardian that both predicts a pool's first public trade and
    /// lands a freeze in the next block", on the ground that it cannot schedule
    /// that.
    ///
    /// **It does not have to predict anything. It can make the first trade
    /// itself.** The guardian arms the window with its own swap and freezes the
    /// pool, and the window lapses with nobody able to trade. The boundary as
    /// written is not a boundary, and this test is the demonstration.
    ///
    /// What it costs the attacker, after owner ruling 5: `MIN_FREEZE_CHARGE`,
    /// one hour of a 168-hour lifetime budget, per pool treated this way.
    function test_theGuardianCannotSpendAPoolsCapWindowWithItsOwnFirstTrade() public {
        (address coin, PoolKey memory k) = factory.create(
            FeastFactory.CreateParams({
                name: "Coin", symbol: "COIN", supply: 1_000_000_000e18, quote: address(wbnb),
                creator: creator, selfBurnBps: 2_000, referrerBps: 1_000,
                prebuyQuoteIn: 0, minCoinsOut: 0, vestingDuration: 0,
                sqrtPriceX96: SQRT_PRICE_1_1, startTick: 0,
                liquidity: uint128(1_000_000_000e18 * 999 / 1_000),
                salt: bytes32(uint256(0xCAB)), metadataHash: bytes32(0)
            })
        );
        PoolId id = PoolId.wrap(keccak256(abi.encode(k)));
        uint256 armedAt = vm.getBlockNumber();

        // The guardian's own trade is the pool's first served swap, so it is the
        // guardian that arms the window.
        _buy(k, address(wbnb), 1e18, multisig, address(0));
        assertEq(uint256(hook.servedBlocks(id)), 1, "the guardian's own trade is the pool's first served block");

        // And in the same block it freezes — v1.6.17 has one scope, so this
        // stops the guardian's own trading as much as anybody's.
        vm.prank(multisig);
        guardian.freeze();

        // The window passes with the pool frozen. ONE block has ever served a
        // trade on this pool; `CAP_BLOCKS` is 2.
        vm.roll(armedAt + uint256(FeastConstants.CAP_BLOCKS));
        _advance(1);
        vm.prank(multisig);
        guardian.unfreeze();

        uint256 cap = hook.perWalletCap(id);
        assertGt(cap, 0, "the pool has a cap to exceed");
        wbnb.mint(address(router), (cap + 1e18) * 4);
        _expectCapRefusal();
        _buyExactCoin(k, coin, address(0xB0B), cap + 1e18);
    }

    // **`scoped-freeze-ages-platform-price` is closed by construction**
    // (v1.6.15 round, `P16-claude` MEDIUM, `P5-claude` MEDIUM). v1.6.16 fixed
    // it with a per-pool resume instant; v1.6.17 removed the pool-scoped freeze
    // that made one necessary, so `unfrozenAtFor(poolId)` is gone and its two
    // tests with it. The property they asserted — that a freeze stopping a
    // pool's swaps is visible to every rule measuring that pool's average — is
    // now true because there is exactly one freeze and one instant.
    //
    // The regression lives in `FreezeRunsTheSettlementClocksPoC`, which proves
    // the grace and the aging rule read that one instant and agree.

    function _expectCapRefusal() internal {
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IFeastCLHooks.afterSwap.selector,
                abi.encodeWithSelector(FeastHook.PurchaseCapExceeded.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
    }

    /// @dev The caller funds the router first: an external call between
    ///      `vm.expectRevert` and the call under test consumes the cheatcode.
    function _buyExactCoin(PoolKey memory k, address coin, address who, uint256 coinOut) internal {
        bool zeroForOne = Currency.unwrap(k.currency0) != coin;
        vm.prank(who, who);
        router.swap(
            k.up(),
            ICLPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: int256(coinOut),
                sqrtPriceLimitX96: zeroForOne ? MIN_SQRT : MAX_SQRT
            }),
            ""
        );
    }
}
