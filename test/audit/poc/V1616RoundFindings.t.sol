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

/// The v1.6.16 round's finding on the opening cap, verified rather than taken
/// on the lens's word.
///
/// **This is the fifth iteration of one shape.** The opening cap has been a
/// height (spent by a freeze), a height in open blocks (the counter could not
/// be written), a height armed at the first served swap (the guardian armed it
/// itself), and now a count of served blocks — and the count can be SERVED by
/// the guardian too, one wei at a time, with a scoped freeze between each so
/// nobody else can reach a block of it.
contract V1616RoundFindingsPoC is UnitFixture {
    using VenueBridge for PoolKey;

    /// `P6-claude` MEDIUM, `guardian-serves-the-window-alone`. **Closed by
    /// construction in v1.6.17**, and kept as the regression test for why.
    ///
    /// The attack was: a one-wei trade of the guardian's own in each block of
    /// the window, with a POOL-SCOPED freeze between them so no stranger could
    /// reach one. The window was spent before anybody else could trade, and the
    /// first stranger's trade was uncapped.
    ///
    /// The owner removed the pool-scoped freeze. What is left is a freeze that
    /// covers everything, and **a block the guardian can trade in is a block
    /// anybody can trade in** — it cannot clear a room it must also stay out
    /// of. So the guardian may still serve the window's blocks, and it no
    /// longer serves them ALONE: a stranger reaching any of them is capped,
    /// which is the whole of what P6 promises.
    function test_theGuardianCannotServeTheWindowAlone() public {
        (address coin, PoolKey memory k) = factory.create(
            FeastFactory.CreateParams({
                name: "Coin", symbol: "COIN", supply: 1_000_000_000e18, quote: address(wbnb),
                creator: creator, selfBurnBps: 2_000, referrerBps: 1_000,
                prebuyQuoteIn: 0, minCoinsOut: 0, vestingDuration: 0,
                sqrtPriceX96: SQRT_PRICE_1_1, startTick: 0,
                liquidity: uint128(1_000_000_000e18 * 999 / 1_000),
                salt: bytes32(uint256(0xCAC)), metadataHash: bytes32(0)
            })
        );
        PoolId id = PoolId.wrap(keccak256(abi.encode(k)));
        uint256 cap = hook.perWalletCap(id);
        assertGt(cap, 0, "the pool has a cap to exceed");

        // The guardian opens the window with a trade of its own, and freezes.
        _buy(k, address(wbnb), 1, multisig, address(0));
        assertEq(uint256(hook.servedBlocks(id)), 1, "the guardian's dust served block one");
        vm.prank(multisig);
        guardian.freeze();

        // **It cannot trade through its own freeze.** This is the line the
        // whole ruling turns on: under the old pool-scoped freeze the guardian
        // was outside the freeze it placed, and could keep serving blocks
        // nobody else could reach.
        // Funded and routed FIRST: `_buy` mints before it swaps, and an
        // external call between `vm.expectRevert` and the call under test
        // consumes the cheatcode.
        wbnb.mint(address(router), 1_000);
        bool zeroForOne = Currency.unwrap(k.currency0) == address(wbnb);
        vm.prank(multisig, multisig);
        vm.expectRevert();
        router.swap(
            k.up(),
            ICLPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -1,
                sqrtPriceLimitX96: zeroForOne ? MIN_SQRT : MAX_SQRT
            }),
            ""
        );

        // So the window only advances in blocks that are open to everyone, and
        // a stranger reaching one is capped — the promise, doing its work.
        _advance(1);
        vm.prank(multisig);
        guardian.unfreeze();
        _buy(k, address(wbnb), 1, multisig, address(0));
        assertEq(uint256(hook.servedBlocks(id)), 2, "block two was served in the open");

        wbnb.mint(address(router), (cap + 1e18) * 4);
        _expectCapRefusal();
        _buyExactCoin(k, coin, address(0xB0B), cap + 1e18);
    }

    /// The control that stops the above being a test of the cap's ordinary end:
    /// a stranger who reaches the pool's SECOND served block is still capped, so
    /// the window works when the guardian is not the one filling it.
    function test_aStrangerInTheWindowIsCapped() public {
        (address coin, PoolKey memory k) = factory.create(
            FeastFactory.CreateParams({
                name: "Coin", symbol: "COIN", supply: 1_000_000_000e18, quote: address(wbnb),
                creator: creator, selfBurnBps: 2_000, referrerBps: 1_000,
                prebuyQuoteIn: 0, minCoinsOut: 0, vestingDuration: 0,
                sqrtPriceX96: SQRT_PRICE_1_1, startTick: 0,
                liquidity: uint128(1_000_000_000e18 * 999 / 1_000),
                salt: bytes32(uint256(0xCAD)), metadataHash: bytes32(0)
            })
        );
        PoolId id = PoolId.wrap(keccak256(abi.encode(k)));

        _buy(k, address(wbnb), 1, multisig, address(0));
        _advance(1);

        uint256 cap = hook.perWalletCap(id);
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
