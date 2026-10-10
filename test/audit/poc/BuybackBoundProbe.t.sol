// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FeastConstants} from "../../../src/FeastConstants.sol";
import {FeastFactory} from "../../../src/FeastFactory.sol";
import {FeastMath} from "../../../src/FeastMath.sol";
import {Currency} from "../../../src/venue/Currency.sol";
import {PoolId, PoolIdLibrary} from "../../../src/venue/PoolId.sol";
import {PoolKey} from "../../../src/venue/PoolKey.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {IFeastCLPoolManager} from "../../../src/venue/IFeastCLPoolManager.sol";
import {FullMath} from "infinity-core/src/pool-cl/libraries/FullMath.sol";
import {TickMath} from "infinity-core/src/pool-cl/libraries/TickMath.sol";
import {MockERC20} from "../../utils/MockERC20.sol";
import {CapWarm} from "../../utils/CapWarm.sol";
import {UnitFixture} from "../../utils/UnitFixture.sol";
import {VenueBridge} from "../../utils/VenueBridge.sol";

/// @notice MEASUREMENT, not a proof, for the v1 finding CA-42c2a8d368 (execution-price), re-run on
///         v1.6. Both constructions below PASS: the press lands inside the documented 3%, so the
///         finding stays unproven and these numbers are the evidence for why.
/// @dev `docs/plan.md` STATED the bound as "300 ticks ~ 3%, the same tolerance
///      `MAX_SLIPPAGE_BPS` states in basis points ... Same safety property". The two checks
///      compose instead: the press is admitted while spot sits up to 300 ticks from the
///      time-weighted tick, and its own swap may then walk the square-root price a further 3%.
///      This test measures what the press actually receives against the TWAP-implied amount.
contract BuybackBoundProbe is UnitFixture {
    using PoolIdLibrary for PoolKey;
    using VenueBridge for PoolKey;

    address internal coin;
    PoolKey internal key;
    PoolId internal id;
    bool internal coinIs0;

    function setUp() public override {
        super.setUp();
        (coin, key) = _create(address(stock), bytes32(uint256(21)));
        id = key.toId();
        coinIs0 = Currency.unwrap(key.currency0) == coin;
    }

    /// Push spot to `target` by swapping into the price limit at that tick.
    function _moveTo(int24 target) internal {
        bool zeroForOne = coinIs0 ? false : true; // raise the coin's price in quote terms
        uint160 limit = TickMath.getSqrtRatioAtTick(target);
        uint256 huge = 400_000_000e18; // exact-OUTPUT coin: the quote leg is unspecified, so a partial fill is allowed (R18 only binds the specified quote leg)
        MockERC20(address(stock)).mint(address(router), huge);
        vm.prank(trader, trader);
        router.swap(
            key.up(),
            ICLPoolManager.SwapParams({zeroForOne: zeroForOne, amountSpecified: int256(huge), sqrtPriceLimitX96: limit}),
            ""
        );
    }

    function test_aPressExecutesWithinTheDocumentedThreePercentOfTheTimeWeightedPrice() public {
        // Fees, so the buy-and-burn bucket has something, and observations for the oracle.
        for (uint256 i; i < 6; ++i) {
            _buy(key, address(stock), 20_000_000e18, trader, address(0));
            _advance(400);
        }
        _advance(3_600); // let the allowance accrue to its cap

        // With no trade for an hour the time-weighted tick equals the spot tick, so the move
        // below is exactly the deviation the check measures.
        (, int24 spot0,,) = IFeastCLPoolManager(address(pm)).getSlot0(id);
        int24 twapBefore = oracle.twapTick(id);
        int24 target = coinIs0 ? spot0 + 299 : spot0 - 299;
        _moveTo(target);

        (, int24 spot,,) = IFeastCLPoolManager(address(pm)).getSlot0(id);
        int24 dev = spot > twapBefore ? spot - twapBefore : twapBefore - spot;
        assertLe(uint256(uint24(dev)), uint256(uint24(FeastConstants.MAX_TICK_DEVIATION)), "precondition: the press is admitted");

        uint256 usedBefore = hook.poolInfo(id).selfBurnUsed;
        uint256 supplyBefore = MockERC20(coin).totalSupply();
        uint256 tipBefore = MockERC20(coin).balanceOf(address(this));

        hook.buyBackAndBurn(key, type(uint128).max);

        uint256 quoteSpent = hook.poolInfo(id).selfBurnUsed - usedBefore;
        uint256 coinOut = (supplyBefore - MockERC20(coin).totalSupply())
            + (MockERC20(coin).balanceOf(address(this)) - tipBefore);
        assertGt(quoteSpent, 0, "precondition: the press spent something");

        // What that quote would have bought at the time-weighted price the check vouched for.
        uint160 sqrtTwap = TickMath.getSqrtRatioAtTick(twapBefore);
        uint256 ratioX128 = FullMath.mulDiv(uint256(sqrtTwap), uint256(sqrtTwap), 1 << 64); // (sqrtP^2)/2^128 scaled
        uint256 implied = coinIs0
            ? FullMath.mulDiv(quoteSpent, 1 << 128, ratioX128) // coin = token0: divide by price
            : FullMath.mulDiv(quoteSpent, ratioX128, 1 << 128); // coin = token1: multiply
        assertGt(implied, 0, "precondition: the implied amount is computable");

        emit log_named_uint("quote spent", quoteSpent);
        emit log_named_uint("coin received", coinOut);
        emit log_named_uint("TWAP-implied coin", implied);
        emit log_named_uint("received per 10000 implied", coinOut * 10_000 / implied);

        // The promise: the press executes within the documented 3% of the time-weighted price.
        assertGe(coinOut * 10_000, implied * 9_700, "the press executed worse than the documented 3% of TWAP");
    }

    /// A shallow pool, so the allowance-capped press is large against the depth and its own swap
    /// walks the price into the 3% square-root limit. This is the composition the finding names:
    /// the deviation the check admits, plus the walk the limit allows, on one press.
    function test_aPressOnAShallowPoolStaysWithinTheDocumentedThreePercent() public {
        uint256 supply = 1_000e18;
        (address c2, PoolKey memory k2) = factory.create(
            FeastFactory.CreateParams({
                name: "Thin",
                symbol: "THIN",
                supply: supply,
                quote: address(stock),
                creator: creator,
                selfBurnBps: 2_000,
                referrerBps: 1_000,
                prebuyQuoteIn: 0,
                minCoinsOut: 0,
                vestingDuration: 0,
                sqrtPriceX96: SQRT_PRICE_1_1,
                startTick: 0,
                liquidity: uint128(supply * 999 / 1_000),
                salt: bytes32(uint256(77)),
                metadataHash: bytes32(0)
            })
        );
        bool c2Is0 = Currency.unwrap(k2.currency0) == c2;
        // v1.6.15: the opening cap window opens at a pool's first SERVED
        // swap, so rolling past CAP_BLOCKS only clears a window that exists.
        CapWarm.arm(router, k2.up(), address(stock), !c2Is0);
        vm.roll(vm.getBlockNumber() + FeastConstants.CAP_BLOCKS);
        PoolId id2 = k2.toId();

        // Volume both ways, so the bucket grows while the price returns near its start.
        for (uint256 i; i < 40; ++i) {
            _buy(k2, address(stock), 60e18, trader, address(0));
            uint256 coinHeld = MockERC20(c2).balanceOf(address(router));
            if (coinHeld > 0) {
                bool sellZeroForOne = c2Is0 ? true : false;
                vm.prank(trader, trader);
                router.swap(
                    k2.up(),
                    ICLPoolManager.SwapParams({
                        zeroForOne: sellZeroForOne,
                        amountSpecified: int256(50e18), // exact-output quote: bypasses the internal fill
                        sqrtPriceLimitX96: sellZeroForOne ? MIN_SQRT : MAX_SQRT
                    }),
                    ""
                );
            }
            _advance(120);
        }
        _advance(3_600);

        (, int24 spot0,,) = IFeastCLPoolManager(address(pm)).getSlot0(id2);
        int24 twapBefore = oracle.twapTick(id2);
        int24 target = c2Is0 ? spot0 + 299 : spot0 - 299;
        {
            bool zeroForOne = c2Is0 ? false : true;
            uint160 limit = TickMath.getSqrtRatioAtTick(target);
            MockERC20(address(stock)).mint(address(router), 1_000e18);
            vm.prank(trader, trader);
            router.swap(
                k2.up(),
                ICLPoolManager.SwapParams({zeroForOne: zeroForOne, amountSpecified: int256(200e18), sqrtPriceLimitX96: limit}),
                ""
            );
        }

        (, int24 spot,,) = IFeastCLPoolManager(address(pm)).getSlot0(id2);
        int24 dev = spot > twapBefore ? spot - twapBefore : twapBefore - spot;
        assertLe(uint256(uint24(dev)), uint256(uint24(FeastConstants.MAX_TICK_DEVIATION)), "precondition: the press is admitted");

        uint256 usedBefore = hook.poolInfo(id2).selfBurnUsed;
        uint256 supplyBefore = MockERC20(c2).totalSupply();
        uint256 tipBefore = MockERC20(c2).balanceOf(address(this));
        emit log_named_uint("bucket pending", hook.selfBurnPending(id2));
        emit log_named_uint("allowance", hook.spendingAllowance(id2));

        hook.buyBackAndBurn(k2, type(uint128).max);

        uint256 quoteSpent = hook.poolInfo(id2).selfBurnUsed - usedBefore;
        uint256 coinOut = (supplyBefore - MockERC20(c2).totalSupply())
            + (MockERC20(c2).balanceOf(address(this)) - tipBefore);
        assertGt(quoteSpent, 0, "precondition: the press spent something");

        uint160 sqrtTwap = TickMath.getSqrtRatioAtTick(twapBefore);
        uint256 ratioX128 = FullMath.mulDiv(uint256(sqrtTwap), uint256(sqrtTwap), 1 << 64);
        uint256 implied = c2Is0
            ? FullMath.mulDiv(quoteSpent, 1 << 128, ratioX128)
            : FullMath.mulDiv(quoteSpent, ratioX128, 1 << 128);

        emit log_named_uint("quote spent", quoteSpent);
        emit log_named_uint("coin received", coinOut);
        emit log_named_uint("TWAP-implied coin", implied);
        emit log_named_uint("received per 10000 implied", coinOut * 10_000 / implied);

        assertGe(coinOut * 10_000, implied * 9_700, "the press executed worse than the documented 3% of TWAP");
    }

    // --- v1.6.4 r1: fixtures that REACH the limit -------------------------
    //
    // The claude lens recorded that neither fixture above reaches the price
    // limit — both land inside the tolerance on their own, so the probe was
    // reporting a bound it never touched. "A witness that cannot reach the
    // bound it is testing does not test it" is the same lesson `docs/plan.md`
    // section 6d records against v1.6.3's P19 witness.
    //
    // **What reaching it actually takes, measured.** A press cannot reach its
    // own limit under the allowance ration: the budget is 5% of the self-burn
    // bucket per window, and on every pool this fixture can build, the press
    // exhausts that budget long before the price moves 3%. That is the
    // rationing working as designed, and it is recorded in `plans/v164/plan.md`
    // rather than worked around here — a fixture contorted until the button
    // reaches its limit would be testing the contortion.
    //
    // So the limit's own contract is witnessed directly: a swap handed exactly
    // the limit the hook computes, sized so the LIMIT stops it rather than the
    // amount, must come to rest ON that limit and inside the documented
    // tolerance. Both directions, so both sides of `FeastMath.sqrtPriceLimit`
    // are exercised at a price a real pool actually holds.

    /// Round `v1.6.4` r2 (r2h): measured in whole basis points this FLOORS, so a
    /// limit permitting 300.2201 bps reads 300 and passes "at most 300". Measured
    /// at 1e12 instead, which resolves the difference.
    uint256 internal constant PRICE_SCALE = 1e12;

    function _movedScaled(uint160 limit, uint160 spot) internal pure returns (uint256) {
        return FullMath.mulDiv(FullMath.mulDiv(limit, limit, spot), PRICE_SCALE, spot);
    }

    function _moveBps(uint160 limit, uint160 spot) internal pure returns (uint256) {
        uint256 r = FullMath.mulDiv(FullMath.mulDiv(limit, limit, spot), FeastConstants.BPS, spot);
        return r >= FeastConstants.BPS ? r - FeastConstants.BPS : FeastConstants.BPS - r;
    }

    /// @param up true to walk the price up (zeroForOne false), false to walk it down
    function _swapIntoTheLimit(bool up) internal {
        // A freshly seeded feast pool is single-sided by construction: it holds
        // the coin and no quote, so the price can only be walked UP until
        // someone has bought, and the router holds no coin until it has bought
        // either. A warm-up buy fixes both.
        //
        // **Which direction needs it depends on the SORT ORDER, not on `up`.**
        // This used to key off `!up`, which was right only while the coin
        // happened to sort second; v1.6.12's extra deployment moved every
        // address and the rising direction became the coin-paying one, so the
        // test failed on its own precondition with nothing to sell. Keyed off
        // the asset actually being spent, it holds whichever way the pair sorts.
        bool zeroForOne = !up;
        address pay = zeroForOne ? Currency.unwrap(key.currency0) : Currency.unwrap(key.currency1);
        if (!up || pay == coin) {
            _buy(key, address(stock), 50_000_000e18, trader, address(0));
            _advance(60);
        }

        (uint160 before,,,) = IFeastCLPoolManager(address(pm)).getSlot0(id);
        uint160 limit =
            FeastMath.sqrtPriceLimit(before, FeastConstants.MAX_SLIPPAGE_BPS, FeastConstants.BPS, up);

        if (up) assertGt(limit, before, "a rising limit is above spot");
        else assertLt(limit, before, "a falling limit is below spot");

        // Enough to walk clean through the limit, so the LIMIT is what stops it.
        int256 amount;
        if (pay == coin) {
            // The coin is a fixed-supply `FeastToken` and cannot be minted, so
            // the falling side spends what the warm-up buy actually bought.
            amount = -int256(MockERC20(coin).balanceOf(address(router)));
            assertLt(amount, 0, "precondition: the warm-up buy left coin to sell");
        } else {
            // Exact-OUTPUT on the rising side: the quote leg is unspecified, so a
            // partial fill is allowed and the purchase cap is measured on what
            // the limit actually lets through (R18 binds only the specified leg).
            MockERC20(pay).mint(address(router), 500_000_000e18);
            amount = int256(400_000_000e18);
        }
        vm.prank(trader, trader);
        router.swap(
            key.up(),
            ICLPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amount,
                sqrtPriceLimitX96: limit
            }),
            ""
        );

        (uint160 after_,,,) = IFeastCLPoolManager(address(pm)).getSlot0(id);
        emit log_named_uint(up ? "rising: spot before" : "falling: spot before", before);
        emit log_named_uint("        limit        ", limit);
        emit log_named_uint("        spot after   ", after_);
        emit log_named_uint("        move, bps    ", _moveBps(limit, before));

        assertEq(after_, limit, "the pool came to rest exactly on the limit");

        // Exact, at 1e12, so the assertion can actually fail: see `_movedScaled`.
        uint256 moved = _movedScaled(limit, before);
        if (up) {
            assertLe(
                moved,
                PRICE_SCALE * (uint256(FeastConstants.BPS) + FeastConstants.MAX_SLIPPAGE_BPS) / FeastConstants.BPS,
                "the limit it stopped on is inside the documented tolerance, in PRICE"
            );
        } else {
            assertGe(
                moved,
                PRICE_SCALE * (uint256(FeastConstants.BPS) - FeastConstants.MAX_SLIPPAGE_BPS) / FeastConstants.BPS,
                "the limit it stopped on is inside the documented tolerance, in PRICE"
            );
        }
        // Not vacuous: the limit is close to the tolerance, not far inside it.
        assertGe(_moveBps(limit, before), 290, "the bound is reached to within 10 basis points");
    }

    function test_aSwapStoppedByTheRisingLimitRestsOnItAndInsideTheTolerance() public {
        _swapIntoTheLimit(true);
    }

    function test_aSwapStoppedByTheFallingLimitRestsOnItAndInsideTheTolerance() public {
        _swapIntoTheLimit(false);
    }
}
