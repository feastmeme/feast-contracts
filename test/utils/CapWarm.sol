// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";

import {PoolKey as UpPoolKey} from "infinity-core/src/types/PoolKey.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";

import {MockERC20} from "./MockERC20.sol";
import {PoolRouter} from "./PoolRouter.sol";

/// @dev **v1.6.15: a pool's opening cap window opens at its first SERVED swap**,
///      not at its creation block, so `vm.roll(vm.getBlockNumber() + CAP_BLOCKS)` after
///      a creation no longer leaves a pool out of its opening blocks — nothing
///      has been served yet, and the first real trade arms the window under the
///      test's feet.
///
///      Every `setUp` that creates a pool and then rolls past `CAP_BLOCKS` arms
///      it here first. One wei of quote is the whole purchase: one per cent of
///      one wei floors to zero, so the arming buy accrues no fee to any bucket,
///      records no referral and credits no ledger track. No test that counts
///      fees can see it. What it does move is the pool price, by one wei, and
///      the oracle's observation — both below anything the suite asserts on.
///
///      The buyer is an address no test asserts on, so the coin-wei it receives
///      and the entry it makes in the hook's opening-purchase map belong to
///      nobody the assertions know about.
library CapWarm {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    /// @dev The wallet that arms every pool's opening cap window in a `setUp`.
    address internal constant WARMER = address(0xCA9CA9);

    /// @dev Mirrors `FeastConstants.CAP_BLOCKS`; this library is test-only and
    ///      importing the constants file here would pull the whole of it in.
    uint256 private constant CAP_BLOCKS = 2;

    uint160 private constant MIN_SQRT = 4295128740;
    uint160 private constant MAX_SQRT = 1461446703485210103287273052203988822378723970341;

    /// @param quoteIsCurrency0 whether the pool's `currency0` is the quote.
    ///
    /// @dev **v1.6.16: the window is a COUNT of distinct SERVED blocks**, so
    ///      rolling forward does not leave it — a mined block that serves no
    ///      trade does not count, which is the whole point of the change. To
    ///      put a pool out of its opening blocks the fixture has to serve
    ///      `CAP_BLOCKS + 1` of them, one per block.
    function arm(PoolRouter router, UpPoolKey memory key, address quote, bool quoteIsCurrency0) internal {
        for (uint256 i = 0; i <= CAP_BLOCKS; i++) {
            MockERC20(quote).mint(address(router), 1);
            vm.prank(WARMER, WARMER);
            router.swap(
                key,
                ICLPoolManager.SwapParams({
                    zeroForOne: quoteIsCurrency0,
                    amountSpecified: -1,
                    sqrtPriceLimitX96: quoteIsCurrency0 ? MIN_SQRT : MAX_SQRT
                }),
                ""
            );
            vm.roll(vm.getBlockNumber() + 1);
        }
    }
}
