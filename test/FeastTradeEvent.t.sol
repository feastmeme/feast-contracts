// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Test.sol";

import {FeastHook} from "../src/FeastHook.sol";
import {PoolId, PoolIdLibrary} from "../src/venue/PoolId.sol";
import {PoolKey} from "../src/venue/PoolKey.sol";
import {IFeastCLPoolManager} from "../src/venue/IFeastCLPoolManager.sol";

import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {BalanceDelta} from "infinity-core/src/types/BalanceDelta.sol";

import {HookFixture} from "./utils/HookFixture.sol";
import {PoolRouter} from "./utils/PoolRouter.sol";
import {VenueBridge} from "./utils/VenueBridge.sol";

/// One self-describing `Trade` event per swap (owner ruling Q24).
///
/// The coin page's chart is built in the browser from chain events alone, so
/// the event must be complete and exact: the trader's own amounts — what the
/// venue actually moved for them, the fee on whichever side it was charged —
/// the pool's price after the swap, and who paid. One per swap, on all four fee
/// branches; none for LP-fee collection; none while a pool is gated.
contract FeastTradeEventTest is HookFixture {
    using PoolIdLibrary for PoolKey;
    using VenueBridge for PoolKey;

    struct Seen {
        uint256 count;
        address coin;
        address quote;
        bool buy;
        uint256 coinAmount;
        uint256 quoteAmount;
        uint160 sqrtPriceX96After;
        address payer;
        uint256 fee;
    }

    function setUp() public override {
        super.setUp();
        _pool(creator, 2_000, 1_000, 0, address(0));
    }

    function _trades(Vm.Log[] memory logs) internal view returns (Seen memory s) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != address(hook) || logs[i].topics[0] != FeastHook.Trade.selector) continue;
            s.count++;
            s.coin = address(uint160(uint256(logs[i].topics[1])));
            s.quote = address(uint160(uint256(logs[i].topics[2])));
            s.payer = address(uint160(uint256(logs[i].topics[3])));
            (s.buy, s.coinAmount, s.quoteAmount, s.sqrtPriceX96After, s.fee) =
                abi.decode(logs[i].data, (bool, uint256, uint256, uint160, uint256));
        }
    }

    function _abs(int128 x) internal pure returns (uint256) {
        return x < 0 ? uint256(uint128(-x)) : uint256(uint128(x));
    }

    /// Kills: a missing event on any branch; amounts from the pool's delta
    /// rather than the trader's (off by the fee); a stale price; the router as
    /// payer.
    function test_eachBranchEmitsOneTradeWithTheTradersOwnAmounts() public {
        for (uint256 b = 0; b < 4; b++) {
            bool buy = b < 2;
            bool exactIn = b % 2 == 0;
            bool zeroForOne = buy ? _buyDirection() : !_buyDirection();
            uint256 accruedBefore = hook.poolInfo(key.toId()).accruedQuote;

            vm.recordLogs();
            vm.prank(trader, trader);
            BalanceDelta d = router.swap(
                key.up(),
                ICLPoolManager.SwapParams({
                    zeroForOne: zeroForOne,
                    amountSpecified: exactIn ? -int256(1_000e18) : int256(900e18),
                    sqrtPriceLimitX96: zeroForOne ? MIN_SQRT : MAX_SQRT
                }),
                ""
            );
            Seen memory s = _trades(vm.getRecordedLogs());
            (uint160 sqrtNow,,,) = IFeastCLPoolManager(address(pm)).getSlot0(key.toId());

            assertEq(s.count, 1, "exactly one Trade per swap");
            assertEq(s.coin, address(coin), "the coin");
            assertEq(s.quote, address(quote), "the quote");
            assertEq(s.buy, buy, "the side");
            assertEq(s.payer, trader, "the payer is the origin, not the router");
            assertEq(s.coinAmount, _abs(coinIsCurrency0 ? d.amount0() : d.amount1()), "coin the trader moved");
            assertEq(s.quoteAmount, _abs(coinIsCurrency0 ? d.amount1() : d.amount0()), "quote the trader moved");
            assertEq(s.sqrtPriceX96After, sqrtNow, "the pool's price after the swap");
            assertEq(s.fee, hook.poolInfo(key.toId()).accruedQuote - accruedBefore, "the fee this swap paid");
        }
    }

    function test_theLaunchWindowsGatedSwapEmitsNoTrade() public {
        _pool(creator, 2_000, 1_000, uint64(clock + 1 days), address(openerRouter));
        vm.recordLogs();
        _branch(openerRouter, 0, trader, "");
        assertEq(_trades(vm.getRecordedLogs()).count, 0, "the window reports its own settlement");
    }
}
