// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Currency} from "../../../src/venue/Currency.sol";
import {Hooks} from "infinity-core/src/libraries/Hooks.sol";
import {CustomRevert} from "infinity-core/src/libraries/CustomRevert.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";

import {FeastConstants} from "../../../src/FeastConstants.sol";
import {FeastFactory} from "../../../src/FeastFactory.sol";
import {FeastGuardian} from "../../../src/FeastGuardian.sol";
import {FeastHook} from "../../../src/FeastHook.sol";
import {IFeastCLHooks} from "../../../src/venue/IFeastCLHooks.sol";
import {PoolId} from "../../../src/venue/PoolId.sol";
import {PoolKey} from "../../../src/venue/PoolKey.sol";
import {UnitFixture} from "../../utils/UnitFixture.sol";
import {VenueBridge} from "../../utils/VenueBridge.sol";

/// **The sixth iteration — CLOSED BY v1.6.18**, and kept as the regression.
/// `P6-claude` MEDIUM
/// (`guardian-brackets-the-served-blocks`) and `P16-claude` MEDIUM
/// (`atomic-brake-serves-the-window`), independently, on the release that was
/// supposed to end this class.
///
/// v1.6.17 removed the pool-scoped freeze because every previous defeat of the
/// opening cap needed a freeze the guardian was OUTSIDE of. That reasoning was
/// right about scope and wrong about time: a freeze may be placed in the very
/// block an `unfreeze` cleared, so the guardian does not need to be outside the
/// freeze — it only needs to be between two of them.
///
/// One transaction: `unfreeze`, trade, `freeze`. The block is served, and no
/// stranger could reach it. The brief for v1.6.17 said "the class ends when the
/// instrument does"; this was that claim being wrong, and it is corrected there.
///
/// v1.6.18 refuses a `freeze` in the block an `unfreeze` cleared, so the
/// bracket cannot close in the block it opened. The loop below now reverts at
/// its second `freeze`, which is the fix doing its work.
contract V1617RoundFindingsPoC is UnitFixture {
    using VenueBridge for PoolKey;

    /// Red-first for the guard itself: a freeze in the unfreeze's own block is
    /// refused by name, and one in the next block is not.
    function test_aFreezeIsRefusedInTheBlockAnUnfreezeCleared() public {
        vm.prank(multisig);
        guardian.freeze();
        _advance(1 hours);
        vm.prank(multisig);
        guardian.unfreeze();

        uint64 here = uint64(vm.getBlockNumber());
        vm.prank(multisig);
        vm.expectRevert(abi.encodeWithSelector(FeastGuardian.UnfrozenThisBlock.selector, here));
        guardian.freeze();

        // And the block after is fine: this is a one-block guard, not a cooldown.
        vm.roll(vm.getBlockNumber() + 1);
        vm.prank(multisig);
        guardian.freeze();
        assertTrue(guardian.isFrozenAll(), "the next block may freeze again");
    }

    function test_aStrangerCanReachAnOpeningBlockTheGuardianDidNotBracket() public {
        (address coin, PoolKey memory k) = factory.create(
            FeastFactory.CreateParams({
                name: "Coin", symbol: "COIN", supply: 1_000_000_000e18, quote: address(wbnb),
                creator: creator, selfBurnBps: 2_000, referrerBps: 1_000,
                prebuyQuoteIn: 0, minCoinsOut: 0, vestingDuration: 0,
                sqrtPriceX96: SQRT_PRICE_1_1, startTick: 0,
                liquidity: uint128(1_000_000_000e18 * 999 / 1_000),
                salt: bytes32(uint256(0xCB1)), metadataHash: bytes32(0)
            })
        );
        PoolId id = PoolId.wrap(keccak256(abi.encode(k)));
        uint256 cap = hook.perWalletCap(id);

        // Block one, as one Safe batch: serve it, then close the door behind.
        _buy(k, address(wbnb), 1, multisig, address(0));
        vm.prank(multisig);
        guardian.freeze();
        assertEq(uint256(hook.servedBlocks(id)), 1, "the guardian served block one");

        // Every block of the window after that, as one batch each: open the
        // door, step through, close it. The guardian is never outside a freeze
        // for a block it does not itself serve.
        for (uint256 i = 1; i < FeastConstants.CAP_BLOCKS; i++) {
            _advance(1);
            vm.prank(multisig);
            guardian.unfreeze();
            _buy(k, address(wbnb), 1, multisig, address(0));
            // **This is the line v1.6.18 refuses.** The bracket cannot close in
            // the block it opened, so the guardian must leave the block open
            // to everyone until the next one.
            vm.prank(multisig);
            vm.expectRevert(
                abi.encodeWithSelector(FeastGuardian.UnfrozenThisBlock.selector, uint64(vm.getBlockNumber()))
            );
            guardian.freeze();
        }

        // The pool is open from here — the guardian could not re-freeze it —
        // so a stranger reaches a block of the window, and is capped. That is
        // the whole of what P6 promises.
        wbnb.mint(address(router), (cap + 1e18) * 4);
        _expectCapRefusal();
        _buyExactCoin(k, coin, address(0xB0B), cap + 1e18);
    }

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
