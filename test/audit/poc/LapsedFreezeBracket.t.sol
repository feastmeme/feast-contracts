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

/// **The seventh iteration.** `P6-claude` (`lapse-opens-the-bracket`) and
/// `P16-claude` (`lapsed-freeze-closes-its-own-block`), independently, in the
/// v1.6.18 round.
///
/// v1.6.18 refuses a `freeze` in the block an `unfreeze` cleared, which closes
/// the same-block bracket. It reads `lastUnfrozenBlock`, which `unfreeze` is
/// the only writer of — so a freeze that **lapses** by itself stamps nothing,
/// and neither did `expire()`. The guardian could let a freeze run out and then
/// `trade, freeze` in one transaction in the block the lapse opened: the
/// bracket again, through a door the guard did not watch.
contract LapsedFreezeBracketPoC is UnitFixture {
    using VenueBridge for PoolKey;

    function test_theGuardianCannotBracketABlockThroughALapsedFreeze() public {
        (address coin, PoolKey memory k) = factory.create(
            FeastFactory.CreateParams({
                name: "Coin", symbol: "COIN", supply: 1_000_000_000e18, quote: address(wbnb),
                creator: creator, selfBurnBps: 2_000, referrerBps: 1_000,
                prebuyQuoteIn: 0, minCoinsOut: 0, vestingDuration: 0,
                sqrtPriceX96: SQRT_PRICE_1_1, startTick: 0,
                liquidity: uint128(1_000_000_000e18 * 999 / 1_000),
                salt: bytes32(uint256(0xCB7)), metadataHash: bytes32(0)
            })
        );
        PoolId id = PoolId.wrap(keccak256(abi.encode(k)));
        uint256 cap = hook.perWalletCap(id);

        // Block one: the guardian serves it and closes the door behind itself.
        _buy(k, address(wbnb), 1, multisig, address(0));
        assertEq(uint256(hook.servedBlocks(id)), 1, "the guardian served block one");
        vm.prank(multisig);
        guardian.freeze();

        // It lets the freeze LAPSE rather than lifting it. Nobody calls
        // anything, so nothing is stamped and nothing is folded.
        _advance(72 hours);
        assertFalse(guardian.isFrozenAll(), "the freeze lapsed by itself");

        // The block the lapse opened. The guardian trades in it — that much it
        // can always do — and then tries to close the bracket behind itself.
        _buy(k, address(wbnb), 1, multisig, address(0));
        assertEq(uint256(hook.servedBlocks(id)), 2, "the guardian served block two");

        // **v1.6.19 refuses the close.** A lapse is the one ending with no
        // transaction in it, so it gets one, and `freeze` will not run until it
        // has happened. Read into a local first: an external call between
        // `vm.prank` and the call under test consumes the cheatcode.
        bytes memory notSettled =
            abi.encodeWithSelector(FeastGuardian.LapsedFreezeNotSettled.selector, guardian.frozenUntil());
        vm.prank(multisig);
        vm.expectRevert(notSettled);
        guardian.freeze();

        // Settling stamps the block, so the re-freeze cannot happen in it
        // either.
        guardian.settleLapsed();
        bytes memory thisBlock = abi.encodeWithSelector(
            FeastGuardian.UnfrozenThisBlock.selector, uint64(vm.getBlockNumber())
        );
        vm.prank(multisig);
        vm.expectRevert(thisBlock);
        guardian.freeze();

        // **So the block stayed open, and that is the whole of the fix.** A
        // stranger reaches the very block the guardian served, in the same
        // block, and is capped — which is what P6 promises and what the
        // bracket used to take away. Before v1.6.19 the guardian's own
        // `freeze` in this block would have refused this trade outright.
        uint256 cap2 = hook.perWalletCap(id);
        assertEq(cap2, cap, "the cap is the pool's own, unchanged");
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
