// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {FeastConstants} from "../src/FeastConstants.sol";
import {FeastHook} from "../src/FeastHook.sol";
import {PoolId, PoolIdLibrary} from "../src/venue/PoolId.sol";
import {PoolKey} from "../src/venue/PoolKey.sol";
import {IFeastCLPoolManager} from "../src/venue/IFeastCLPoolManager.sol";

import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {BalanceDelta} from "infinity-core/src/types/BalanceDelta.sol";

import {HookFixture} from "./utils/HookFixture.sol";
import {FlashSellRouter} from "./utils/FlashSellRouter.sol";
import {ClaimSettleRouter, SyncFirstRouter} from "./utils/SettlementOrderRouters.sol";
import {MockERC20, PausableMockERC20} from "./utils/MockERC20.sol";
import {Currency as UpCurrency} from "infinity-core/src/types/Currency.sol";
import {VenueBridge} from "./utils/VenueBridge.sol";

/// The internal fill (owner ruling Q15; the v1.1 three-layer floor, layer 2).
///
/// When a seller arrives with an exact-input sale, the hook takes part of their
/// coin in exchange for the pool's accrued buy-and-burn quote, at the pool's own
/// price, before the sale reaches the pool — and burns the coin. It buys from a
/// real seller, moves the price nothing and creates no swap to sandwich. What is
/// held here: the price is spot; the fee is 1% of the whole sale, filled or not;
/// the fill shares ONE spending allowance with `buyBackAndBurn`, so the round-7
/// bound (no more than 20% of the bucket in any hour) holds across both; the
/// fill never refuses a trade; and it never happens when the oracle cannot
/// vouch for the price, when the pool is gated, or for any other kind of trade.
contract FeastInternalFillTest is HookFixture {
    using PoolIdLibrary for PoolKey;
    using VenueBridge for PoolKey;

    uint256 internal constant Q96 = 0x1000000000000000000000000;

    struct Fill {
        uint256 count;
        uint256 coinBurned;
        uint256 quotePaid;
    }

    function setUp() public override {
        super.setUp();
        _pool(creator, 2_000, 1_000, 0, address(0));
        // A bucket, a price history, and an hour of allowance.
        for (uint256 i = 0; i < 6; i++) {
            _branch(router, 0, trader, "");
            _advance(60);
            _branch(router, 2, trader, "");
            _advance(60);
        }
        _advance(1 hours);
    }

    // --- helpers -----------------------------------------------------------

    function _spot() internal view returns (uint160 sqrtP) {
        (sqrtP,,,) = IFeastCLPoolManager(address(pm)).getSlot0(key.toId());
    }

    /// Quote for `coinAmount` at `sqrtP`, rounded down ONCE, from the exact
    /// rational price (round 3, L2: the witness used to copy the contract's
    /// double rounding and so could not see it). Near a price of one the square
    /// of the square-root price fits in 256 bits, so no intermediate floor.
    function _quoteFor(uint256 coinAmount, uint160 sqrtP) internal view returns (uint256) {
        uint256 p2 = uint256(sqrtP) * uint256(sqrtP);
        return coinIsCurrency0 ? Math.mulDiv(coinAmount, p2, 1 << 192) : Math.mulDiv(coinAmount, 1 << 192, p2);
    }

    function _fills(Vm.Log[] memory logs) internal view returns (Fill memory f) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != address(hook) || logs[i].topics[0] != FeastHook.InternalFill.selector) continue;
            f.count++;
            (f.coinBurned, f.quotePaid) = abi.decode(logs[i].data, (uint256, uint256));
        }
    }

    function _sell(uint256 coinIn) internal returns (BalanceDelta d, Fill memory f) {
        vm.recordLogs();
        vm.prank(trader, trader);
        d = router.swap(
            key.up(),
            ICLPoolManager.SwapParams({
                zeroForOne: !_buyDirection(),
                amountSpecified: -int256(coinIn),
                sqrtPriceLimitX96: !_buyDirection() ? MIN_SQRT : MAX_SQRT
            }),
            ""
        );
        f = _fills(vm.getRecordedLogs());
    }

    // --- the fill ------------------------------------------------------------

    /// Kills: pricing the fill anywhere but spot; not burning the coin; not
    /// debiting the bucket by what was paid.
    function test_anExactInputSaleIsPartlyFilledFromTheBucketAtSpot() public {
        PoolId id = key.toId();
        uint160 sqrtBefore = _spot();
        uint256 usedBefore = hook.poolInfo(id).selfBurnUsed;
        uint256 supplyBefore = coin.totalSupply();
        uint256 pendingBefore = hook.filledCoinPending(id); // the set-up's own sales were filled too

        (, Fill memory f) = _sell(1_000e18);

        assertEq(f.count, 1, "one fill");
        assertGt(f.coinBurned, 0, "coin was taken");
        assertEq(f.quotePaid, _quoteFor(f.coinBurned, sqrtBefore), "at the pool's own price, rounded down");
        assertEq(hook.poolInfo(id).selfBurnUsed - usedBefore, f.quotePaid, "the bucket is debited by what was paid");
        // Round 3 (M1): the fill holds the coin as a vault claim — nothing
        // physical moves on the swap path — and a separate call burns it.
        assertEq(coin.totalSupply(), supplyBefore, "not burned inside the swap");
        assertEq(hook.filledCoinPending(id) - pendingBefore, f.coinBurned, "held as a claim, owed to the burn");
        hook.burnFilledCoin(key);
        assertEq(supplyBefore - coin.totalSupply(), pendingBefore + f.coinBurned, "and burned for real, by anyone, afterwards");
        assertEq(hook.filledCoinPending(id), 0, "nothing left owed");
    }

    /// The fill moves no price: only the part that reaches the pool does.
    function test_theFilledPartMovesThePriceNothing() public {
        uint160 sqrtBefore = _spot();
        uint256 allowance = hook.spendingAllowance(key.toId());
        // A sale small enough to be filled entirely but for the last unit.
        uint256 coinIn = allowance / 4;
        (, Fill memory f) = _sell(coinIn);
        assertEq(f.coinBurned, coinIn - 1, "all but the last unit filled");
        // One unit into the pool moves its price by at most the rounding of one unit.
        (uint160 sqrtAfter,,,) = IFeastCLPoolManager(address(pm)).getSlot0(key.toId());
        assertApproxEqAbs(uint256(sqrtAfter), uint256(sqrtBefore), 1e10, "the price barely stirs");
    }

    /// Kills: charging the fee on the pool's part only. A filled sale pays 1% of
    /// everything the seller sold into, exactly as an unfilled sale does.
    function test_theFeeOnAFilledSaleIsOnePercentOfTheWholeSale() public {
        PoolId id = key.toId();
        uint256 accruedBefore = hook.poolInfo(id).accruedQuote;
        (BalanceDelta d, Fill memory f) = _sell(1_000e18);
        assertGt(f.quotePaid, 0, "the sale was filled");
        uint256 fee = hook.poolInfo(id).accruedQuote - accruedBefore;
        uint256 received = uint256(uint128(coinIsCurrency0 ? d.amount1() : d.amount0()));
        uint256 gross = received + fee;
        assertApproxEqAbs(fee, gross * FeastConstants.FEE_PIPS / FeastConstants.FEE_DENOMINATOR, 1, "1% of the whole sale");
    }

    /// Kills: a fill that spends outside the button's allowance.
    function test_theFillAndTheButtonShareOneAllowance() public {
        PoolId id = key.toId();
        uint256 before = hook.spendingAllowance(id);
        (, Fill memory f) = _sell(1_000_000e18);
        assertLe(f.quotePaid, before, "a fill spends no more than the allowance");
        // All of it but the rounding of quote -> coin -> quote at spot, which
        // only ever leaves the protocol a unit or two better off.
        assertLe(before - f.quotePaid, 2, "a large sale took the whole allowance");
        assertLe(hook.spendingAllowance(id), before - f.quotePaid, "and the button sees only what is left");
    }

    function test_afterAPressTheFillHasOnlyWhatIsLeft() public {
        PoolId id = key.toId();
        uint256 before = hook.spendingAllowance(id);
        hook.buyBackAndBurn(key, before / 2);
        uint256 left = hook.spendingAllowance(id);
        (, Fill memory f) = _sell(1_000_000e18);
        assertLe(f.quotePaid, left, "the fill spends at most what the press left");
    }

    /// The round-7 bound, re-run across both legs: pressing and selling every
    /// minute for an hour spends no more than 20% of the bucket.
    function test_atMostTwentyPercentLeavesInAnyHourAcrossFillsAndPresses() public {
        PoolId id = key.toId();
        uint256 usedAtStart = hook.poolInfo(id).selfBurnUsed;
        uint256 peak = hook.selfBurnPending(id);
        for (uint256 i = 0; i < 60; i++) {
            // A sale (filled as far as the allowance allows), a buy that puts the
            // price back where it was, and a press — every minute, for an hour.
            _sell(200_000e18);
            _branch(router, 0, trader, "");
            try hook.buyBackAndBurn(key, type(uint128).max) {} catch {}
            uint256 pending = hook.selfBurnPending(id) + (hook.poolInfo(id).selfBurnUsed - usedAtStart);
            if (pending > peak) peak = pending;
            _advance(60);
        }
        uint256 spent = hook.poolInfo(id).selfBurnUsed - usedAtStart;
        assertGt(spent, 0, "both legs did spend");
        assertLe(spent, peak * FeastConstants.MAX_HOURLY_SPEND_BPS / FeastConstants.BPS, "20% of the bucket per hour");
    }

    /// Q24 across the fill: a filled sale's `Trade` reports what the seller
    /// actually sold and received — the filled part included — not the pool's
    /// share of it. Kills: `Trade` amounts that omit the fill.
    function test_aFilledSaleReportsTheSellersOwnAmounts() public {
        vm.recordLogs();
        vm.prank(trader, trader);
        BalanceDelta d = router.swap(
            key.up(),
            ICLPoolManager.SwapParams({
                zeroForOne: !_buyDirection(),
                amountSpecified: -int256(1_000e18),
                sqrtPriceLimitX96: !_buyDirection() ? MIN_SQRT : MAX_SQRT
            }),
            ""
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 coinAmount;
        uint256 quoteAmount;
        bool filled;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != address(hook)) continue;
            if (logs[i].topics[0] == FeastHook.InternalFill.selector) filled = true;
            if (logs[i].topics[0] == FeastHook.Trade.selector) {
                (, coinAmount, quoteAmount,,) = abi.decode(logs[i].data, (bool, uint256, uint256, uint160, uint256));
            }
        }
        assertTrue(filled, "the sale was filled");
        int128 dc = coinIsCurrency0 ? d.amount0() : d.amount1();
        int128 dq = coinIsCurrency0 ? d.amount1() : d.amount0();
        assertEq(coinAmount, uint256(uint128(-dc)), "the whole sale's coin");
        assertEq(quoteAmount, uint256(uint128(dq)), "and the whole of what the seller received");
    }

    /// Round 2 (M2): the fill takes real coin out of the vault before the seller
    /// has paid in. A router that has borrowed the vault's whole balance of the
    /// coin inside its lock — legal, since deltas only net out at the end —
    /// would have its sale reverted by the fill. The fill is bounded by the
    /// coin the vault actually holds. Kills: a fill that ignores custody.
    function test_aSaleIsNotRefusedWhenTheVaultsCoinIsBorrowed() public {
        FlashSellRouter flash = new FlashSellRouter(vault, pm);
        coin.mint(address(flash), 10_000e18);
        assertGt(hook.spendingAllowance(key.toId()), 0, "a fill would otherwise happen");
        vm.recordLogs();
        vm.prank(trader, trader);
        flash.drainThenSell(
            key.up(),
            UpCurrency.wrap(address(coin)),
            1_000e18,
            !_buyDirection(),
            !_buyDirection() ? MIN_SQRT : MAX_SQRT
        );
        // Round 3: the fill holds a claim and moves no coin, so borrowed custody
        // no longer matters — the sale settles either way.
        assertLe(_fills(vm.getRecordedLogs()).count, 1, "the sale settled");
    }

    /// Round 2 (L1): a buy-back is a trade in the pool, so it emits one `Trade`
    /// — paid by the hook itself, with no feast fee.
    function test_aBuyBackEmitsOneTrade() public {
        PoolId id = key.toId();
        vm.recordLogs();
        hook.buyBackAndBurn(key, 1e18);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 trades;
        uint256 quoteSpent;
        uint256 coinBurned;
        uint256 tip;
        bool buy;
        uint256 coinAmount;
        uint256 quoteAmount;
        uint160 sqrtAfter;
        address payer;
        uint256 fee;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != address(hook)) continue;
            if (logs[i].topics[0] == FeastHook.Trade.selector) {
                trades++;
                payer = address(uint160(uint256(logs[i].topics[3])));
                (buy, coinAmount, quoteAmount, sqrtAfter, fee) =
                    abi.decode(logs[i].data, (bool, uint256, uint256, uint160, uint256));
            }
            if (logs[i].topics[0] == FeastHook.BoughtBackAndBurned.selector) {
                (quoteSpent, coinBurned, tip) = abi.decode(logs[i].data, (uint256, uint256, uint256));
            }
        }
        assertEq(trades, 1, "one Trade for the buy-back");
        assertTrue(buy, "a buy");
        assertEq(payer, address(hook), "paid by the hook itself");
        assertEq(fee, 0, "with no feast fee");
        assertEq(quoteAmount, quoteSpent, "the quote the press spent");
        assertEq(coinAmount, coinBurned + tip, "the coin it bought, before the tip and the burn");
        assertEq(sqrtAfter, _spot(), "at the pool's price after the swap");
        id;
    }

    /// Round 3 (M1): a router that snapshots the vault's coin balance and pays
    /// the coin in BEFORE the swap is refused by any fill that moves the
    /// vault's coin mid-swap. The fill moves nothing physical. Kills: a fill
    /// that takes or burns the coin on the swap path.
    function test_aRouterThatPaysInBeforeTheSwapIsNeverRefused() public {
        SyncFirstRouter r = new SyncFirstRouter(vault, pm);
        coin.mint(address(r), 1_000e18);
        vm.recordLogs();
        vm.prank(trader, trader);
        r.sell(key.up(), UpCurrency.wrap(address(coin)), 1_000e18, !_buyDirection(), !_buyDirection() ? MIN_SQRT : MAX_SQRT);
        assertEq(_fills(vm.getRecordedLogs()).count, 1, "filled, and settled");
    }

    /// Round 3 (L3): with the quote token frozen, a sale whose proceeds are
    /// taken as claims still completes, fill included — so nothing on the swap
    /// path, the fill least of all, calls the quote token.
    function test_aFrozenQuoteDoesNotStopAFilledSale() public {
        address pauser = address(0x9A05E);
        PausableMockERC20 frozen = new PausableMockERC20("Frozen", "FRZ", 18, pauser);
        _poolAgainst(frozen, creator, 2_000, 1_000, 0, address(0));
        for (uint256 i = 0; i < 6; i++) {
            _branch(router, 0, trader, "");
            _advance(60);
            _branch(router, 2, trader, "");
            _advance(60);
        }
        _advance(1 hours);
        ClaimSettleRouter r = new ClaimSettleRouter(vault, pm);
        coin.mint(address(r), 1_000e18);
        vm.prank(pauser);
        frozen.setPaused(true);
        vm.recordLogs();
        vm.prank(trader, trader);
        r.sell(key.up(), UpCurrency.wrap(address(coin)), 1_000e18, !_buyDirection(), !_buyDirection() ? MIN_SQRT : MAX_SQRT);
        assertEq(_fills(vm.getRecordedLogs()).count, 1, "filled while the quote is frozen");
    }

    /// Round 3 (L1): the largest signed request, bounded by a price limit, is a
    /// valid partial sale on the venue; the fill must not panic negating it.
    function test_theLargestSignedRequestIsNotRefusedByTheFill() public {
        coin.mint(address(router), 1_000_000e18);
        uint160 sqrtNow = _spot();
        uint160 limit = !_buyDirection() ? uint160(uint256(sqrtNow) * 999 / 1_000) : uint160(uint256(sqrtNow) * 1_001 / 1_000);
        vm.prank(trader, trader);
        router.swap(
            key.up(),
            ICLPoolManager.SwapParams({zeroForOne: !_buyDirection(), amountSpecified: type(int256).min, sqrtPriceLimitX96: limit}),
            ""
        );
    }

    /// The deferred burn is a settlement site: permissionless, debited by what
    /// it burns, a no-op when nothing is owed.
    function test_theFilledCoinBurnsInASeparatePermissionlessCall() public {
        PoolId id = key.toId();
        hook.burnFilledCoin(key); // clears what the set-up's fills bought
        hook.burnFilledCoin(key); // nothing owed now: a no-op, not a revert
        (, Fill memory f) = _sell(1_000e18);
        uint256 supply = coin.totalSupply();
        vm.prank(address(0x5712A));
        hook.burnFilledCoin(key);
        assertEq(supply - coin.totalSupply(), f.coinBurned, "exactly the coin the fill bought");
        assertEq(hook.filledCoinPending(id), 0, "debited by what was burned");
    }

    /// Round 3 (L2): the fill's price is rounded once, from the exact ratio. At
    /// a price of 2.25 quote per coin a one-unit fill must pay 2, not the 1 that
    /// flooring after each square-root multiplication gives. Kills: the double
    /// floor.
    function test_aTinyFillIsPricedWithOneRoundingNotTwo() public {
        MockERC20 q = new MockERC20("Quote", "Q", 18);
        _poolAt(q, creator, 2_000, 1_000, 0, address(0), uint160(3 * (uint256(1) << 95))); // sqrt(2.25) = 1.5
        for (uint256 i = 0; i < 6; i++) {
            _branch(router, 0, trader, "");
            _advance(60);
            _branch(router, 2, trader, "");
            _advance(60);
        }
        _advance(1 hours);
        coin.mint(address(router), 10);
        (, Fill memory f) = _sell(2);
        assertEq(f.coinBurned, 1, "one unit filled, one to the pool");
        assertEq(f.quotePaid, 2, "floor(1 x 2.25) = 2, rounded once");
    }

    // --- when it does not fill (and never refuses the trade) ------------------

    function _exactIn(bool buy, uint256 amount) internal {
        bool zeroForOne = buy ? _buyDirection() : !_buyDirection();
        vm.prank(trader, trader);
        router.swap(
            key.up(),
            ICLPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amount),
                sqrtPriceLimitX96: zeroForOne ? MIN_SQRT : MAX_SQRT
            }),
            ""
        );
    }

    /// Round 4 L1, the declared boundary: a coin worth a millionth of a dollar
    /// quoted in a six-decimal token worth a hundred has a raw price of 1e-20,
    /// outside the fill's exact domain. Such a pool trades normally and is
    /// simply never filled — with a bucket, an allowance and a mature oracle,
    /// so the domain is the only reason. (Every quote the protocol prices is
    /// 18-decimal; the factory stays open, Q2.)
    function test_aSixDecimalQuoteTradesNormallyButIsNeverFilled() public {
        MockERC20 six = new MockERC20("Six", "SIX", 6);
        // sqrt(1e-20) * 2^96, below 2^64; a $1,000 pool: 5e26 coin, 5 SIX.
        _poolAt(six, creator, 2_000, 1_000, 0, address(0), 7_922_816_251_426_433_759, 5e16);
        for (uint256 i = 0; i < 6; i++) {
            _exactIn(true, 10_000); // a cent of SIX
            _advance(60);
            _exactIn(false, 1e24); // about the same back
            _advance(60);
        }
        _advance(1 hours);
        PoolId id = key.toId();
        assertGt(hook.spendingAllowance(id), 0, "a bucket with an allowance");
        assertGe(oracle.historySeconds(id), FeastConstants.MIN_OBSERVATION_AGE, "an oracle that can vouch");
        uint160 sqrtP = _spot();
        assertTrue(uint256(sqrtP) < 1 << 64 || uint256(sqrtP) >= 1 << 128, "a price outside the domain");

        (BalanceDelta d, Fill memory f) = _sell(1e24);
        assertEq(f.count, 0, "never filled");
        int128 coinLeg = coinIsCurrency0 ? d.amount0() : d.amount1();
        int128 quoteLeg = coinIsCurrency0 ? d.amount1() : d.amount0();
        assertEq(coinLeg, -1e24, "the whole sale went to the pool");
        assertGt(quoteLeg, 0, "and the seller was paid");
    }

    function test_noFillWhileTheOracleIsYoung() public {
        _pool(creator, 2_000, 1_000, 0, address(0));
        _branch(router, 0, trader, "");
        _advance(60); // a bucket, but under five minutes of history
        (, Fill memory f) = _sell(1_000e18);
        assertEq(f.count, 0, "no fill against a price the oracle cannot vouch for");
    }

    function test_noFillWhenSpotHasBeenMovedFromTheAverage() public {
        // A buy large enough to push spot well past the tick bound, then sell at once.
        vm.prank(trader, trader);
        router.swap(
            key.up(),
            ICLPoolManager.SwapParams({
                zeroForOne: _buyDirection(),
                amountSpecified: -int256(20_000_000e18),
                sqrtPriceLimitX96: _buyDirection() ? MIN_SQRT : MAX_SQRT
            }),
            ""
        );
        (, Fill memory f) = _sell(1_000e18);
        assertEq(f.count, 0, "no fill into a price somebody just moved");
    }

    function test_noFillForAnyOtherKindOfTrade() public {
        PoolId id = key.toId();
        uint256 used = hook.poolInfo(id).selfBurnUsed;
        for (uint256 b = 0; b < 4; b++) {
            if (b == 2) continue; // the exact-input sale is the one that fills
            vm.recordLogs();
            _branch(router, b, trader, "");
            assertEq(_fills(vm.getRecordedLogs()).count, 0, "buys and exact-output sales go to the pool");
        }
        // A dust buy whose fee rounds to zero reaches the same early branch as
        // an exact-input sale; it must not be mistaken for one.
        vm.recordLogs();
        vm.prank(trader, trader);
        router.swap(
            key.up(),
            ICLPoolManager.SwapParams({
                zeroForOne: _buyDirection(),
                amountSpecified: -int256(50),
                sqrtPriceLimitX96: _buyDirection() ? MIN_SQRT : MAX_SQRT
            }),
            ""
        );
        assertEq(_fills(vm.getRecordedLogs()).count, 0, "a dust buy is not a sale");
        assertEq(hook.poolInfo(id).selfBurnUsed, used, "and spend nothing from the bucket");
    }

    function test_noFillWhileThePoolIsGated() public {
        _pool(creator, 2_000, 1_000, uint64(clock + 1 days), address(openerRouter));
        _branch(openerRouter, 0, trader, "");
        _advance(1 hours);
        vm.recordLogs();
        _branch(openerRouter, 2, trader, "");
        assertEq(_fills(vm.getRecordedLogs()).count, 0, "only the opener trades, and it is never filled");
    }

    /// I1: no sale size is refused because of the fill, and a fill never takes
    /// the whole sale — the pool always swaps something.
    function testFuzz_noSaleSizeIsRefusedByTheFill(uint96 raw) public {
        uint256 coinIn = bound(uint256(raw), 1, 50_000_000e18);
        (, Fill memory f) = _sell(coinIn);
        if (f.count != 0) assertLt(f.coinBurned, coinIn, "the pool always swaps something");
    }

    /// A frozen quote cannot stop a sale being filled: the fill pays in vault
    /// claims and never calls the quote token.
    function test_aFillNeverTouchesTheQuoteToken() public {
        (, Fill memory f) = _sell(1_000e18);
        assertGt(f.count, 0, "filled");
        // The router's quote balance rose by exactly the venue's delta; the hook's
        // own quote-token balance never moved (it holds claims, not tokens).
        assertEq(quote.balanceOf(address(hook)), 0, "no quote token held or moved by the hook");
    }
}

/// The fill's own bound on the venue's int128 delta (v1.6.1, CA-ece82bf971).
///
/// The venue narrows the trader's merged delta to `int128` on both legs when it
/// subtracts the hook's delta from the pool's. The fill adds to the quote leg
/// what the pool would otherwise not have paid, at a better price than the pool
/// would give, so a fill can push a sale that the pool alone could serve past
/// that limit. The fill therefore serves only sales whose own size and whose
/// spot value each fit `int128`; a larger sale simply goes to the pool unfilled.
contract FeastFillDeltaBoundTest is HookFixture {
    using PoolIdLibrary for PoolKey;
    using VenueBridge for PoolKey;

    uint256 internal constant MAX_DELTA = uint256(uint128(type(int128).max));

    /// A pool priced at 2^20 quote per coin, warm, with a bucket and an hour of
    /// allowance: everything a fill needs except a sale inside the bound.
    function _highPricedPool() internal {
        MockERC20 q = new MockERC20("Quote", "Q", 18);
        _poolAt(q, creator, 2_000, 1_000, 0, address(0), uint160(uint256(1) << 106), 5e23);
        for (uint256 i = 0; i < 6; i++) {
            _exactIn(true, 1e24);
            _advance(60);
            _exactIn(false, 1e18);
            _advance(60);
        }
        _advance(1 hours);
    }

    function _exactIn(bool buy, uint256 amount) internal {
        bool zeroForOne = buy ? _buyDirection() : !_buyDirection();
        vm.prank(trader, trader);
        router.swap(
            key.up(),
            ICLPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amount),
                sqrtPriceLimitX96: zeroForOne ? MIN_SQRT : MAX_SQRT
            }),
            ""
        );
    }

    /// The coin amount worth `quoteAmount` at the pool's current price — the
    /// same one exact rounding the fill prices with.
    function _coinWorth(uint256 quoteAmount) internal view returns (uint256) {
        (uint160 sqrtP,,,) = IFeastCLPoolManager(address(pm)).getSlot0(key.toId());
        uint256 p2 = uint256(sqrtP) * uint256(sqrtP);
        return coinIsCurrency0 ? Math.mulDiv(quoteAmount, 1 << 192, p2) : Math.mulDiv(quoteAmount, p2, 1 << 192);
    }

    /// What `coinAmount` is worth at the pool's current price.
    function _quoteFor(uint256 coinAmount) internal view returns (uint256) {
        (uint160 sqrtP,,,) = IFeastCLPoolManager(address(pm)).getSlot0(key.toId());
        uint256 p2 = uint256(sqrtP) * uint256(sqrtP);
        return coinIsCurrency0 ? Math.mulDiv(coinAmount, p2, 1 << 192) : Math.mulDiv(coinAmount, 1 << 192, p2);
    }

    function _sellFor(uint256 coinIn) internal returns (Fill memory f) {
        coin.mint(address(router), coinIn);
        vm.recordLogs();
        vm.prank(trader, trader);
        router.swap(
            key.up(),
            ICLPoolManager.SwapParams({
                zeroForOne: !_buyDirection(),
                amountSpecified: -int256(coinIn),
                sqrtPriceLimitX96: !_buyDirection() ? MIN_SQRT : MAX_SQRT
            }),
            ""
        );
        f = _fills(vm.getRecordedLogs());
    }

    struct Fill {
        uint256 count;
        uint256 coinBurned;
        uint256 quotePaid;
    }

    function _fills(Vm.Log[] memory logs) internal view returns (Fill memory f) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != address(hook) || logs[i].topics[0] != FeastHook.InternalFill.selector) continue;
            f.count++;
            (f.coinBurned, f.quotePaid) = abi.decode(logs[i].data, (uint256, uint256));
        }
    }

    /// A sale worth more at spot than the venue's quote delta can hold is not
    /// filled: the fill would pay at spot on top of what the pool pays, and the
    /// venue narrows the sum. The sale itself still goes through, unfilled.
    function test_aSaleWorthMoreThanTheVenuesDeltaIsNotFilled() public {
        _highPricedPool();
        PoolId id = key.toId();
        assertGt(hook.spendingAllowance(id), 0, "precondition: a bucket with an allowance");

        uint256 over = _coinWorth(MAX_DELTA) * 101 / 100; // worth more at spot than the delta holds
        uint256 pendingBefore = hook.filledCoinPending(id);
        Fill memory f = _sellFor(over);
        assertEq(f.count, 0, "not filled: the venue could not hold fill plus pool proceeds");
        assertEq(hook.filledCoinPending(id), pendingBefore, "and nothing was taken into the burn");
    }

    /// The other half of the same bound: a sale whose coin amount alone exceeds
    /// what the venue's specified leg can hold is not filled either, however
    /// little it is worth. Here the price is 2^-60 quote per coin, so the sale's
    /// value is small and only its size is out of range.
    function test_aSaleLargerThanTheVenuesDeltaIsNotFilled() public {
        MockERC20 q = new MockERC20("Quote", "Q", 18);
        _poolAt(q, creator, 2_000, 1_000, 0, address(0), uint160(uint256(1) << 66), 9e17);
        for (uint256 i = 0; i < 6; i++) {
            _exactIn(true, 1e6);
            _advance(60);
            _exactIn(false, 1e24);
            _advance(60);
        }
        _advance(1 hours);
        PoolId id = key.toId();
        assertGt(hook.spendingAllowance(id), 0, "precondition: a bucket with an allowance");
        uint256 huge = MAX_DELTA + 1; // one unit past the venue's specified leg
        assertLt(_quoteFor(huge), MAX_DELTA, "precondition: worth little; only its size is out of range");

        Fill memory f = _sellFor(huge);
        assertEq(f.count, 0, "not filled: the venue could not hold fill plus the pool's own take");
    }

    /// The bound is a bound, not a refusal of everything large: the same sale a
    /// hair inside it is filled as before.
    function test_aSaleJustInsideTheVenuesDeltaIsStillFilled() public {
        _highPricedPool();
        uint256 under = _coinWorth(MAX_DELTA) * 99 / 100;
        Fill memory f = _sellFor(under);
        assertEq(f.count, 1, "filled");
        assertGt(f.quotePaid, 0, "and paid for");
    }
}
