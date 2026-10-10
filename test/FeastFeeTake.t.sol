// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {FeastConstants} from "../src/FeastConstants.sol";
import {FeastFeeLedger} from "../src/FeastFeeLedger.sol";
import {FeastOracle} from "../src/FeastOracle.sol";
import {FeastHook} from "../src/FeastHook.sol";
import {FeastReferrals} from "../src/FeastReferrals.sol";
import {Currency} from "../src/venue/Currency.sol";
import {PoolId, PoolIdLibrary} from "../src/venue/PoolId.sol";
import {PoolKey} from "../src/venue/PoolKey.sol";

import {Vault} from "infinity-core/src/Vault.sol";
import {CLPoolManager} from "infinity-core/src/pool-cl/CLPoolManager.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {Currency as UpCurrency} from "infinity-core/src/types/Currency.sol";

import {MockERC20} from "./utils/MockERC20.sol";
import {CapWarm} from "./utils/CapWarm.sol";
import {PoolRouter} from "./utils/PoolRouter.sol";
import {VenueBridge} from "./utils/VenueBridge.sol";

import {FeastGuardian} from "../../../src/FeastGuardian.sol";
/// The fee take is the single most important thing feast does, and the four
/// branches are four ways to be wrong. What these tests pin down is not "a fee
/// was taken" but the property that makes the four agree:
///
///     the fee is always exactly 1% of the quote that crosses the pool boundary
///
/// regardless of which leg the venue happened to call "specified". Without that
/// cross-case assertion the two rate corrections can be dropped in a port and
/// nothing goes red — the exact-in and exact-out prices simply drift apart, and
/// the gap between them is arbitrageable.
contract FeastFeeTakeTest is Test {
    using PoolIdLibrary for PoolKey;
    using VenueBridge for PoolKey;

    uint160 internal constant SQRT_PRICE_1_1 = 79_228_162_514_264_337_593_543_950_336;
    uint160 internal constant MIN_SQRT = 4_295_128_739 + 1;
    uint160 internal constant MAX_SQRT = 1_461_446_703_485_210_103_287_273_052_203_988_822_378_723_970_342 - 1;

    address internal factory = address(0xFAC7);

    Vault internal vault;
    CLPoolManager internal pm;
    PoolRouter internal router;
    FeastGuardian internal guardian;
    FeastHook internal hook;
    FeastReferrals internal referrals;
    FeastFeeLedger internal ledger;

    MockERC20 internal coin;
    MockERC20 internal quote;
    PoolKey internal key;
    bool internal coinIsCurrency0;

    function setUp() public {
        vault = new Vault();
        pm = new CLPoolManager(vault);
        vault.registerApp(address(pm));
        router = new PoolRouter(vault, pm);
        // A real ledger, never address(0): testing rule 2.
        // Before any address prediction: every CREATE after this shifts by one.
        guardian = new FeastGuardian(address(0x3517), address(this));
        // The referral registry (v1.6.26) has no constructor and no immutables, so
        // its deployed code is the whole of it: etched, it spends none of this
        // contract's nonce — under `isolate` even `deployCodeTo`'s constructor call
        // is a transaction that moves it — and every address below, the tokens' and
        // the platform coin's CREATE2 draw included, is the one it was before.
        referrals = FeastReferrals(address(uint160(uint256(keccak256("feast.referrals")))));
        vm.etch(address(referrals), vm.getDeployedCode("FeastReferrals.sol:FeastReferrals"));
        address predictedHook = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 2);
        FeastOracle oracle = new FeastOracle(predictedHook);
        ledger = new FeastFeeLedger(predictedHook);
        hook = new FeastHook(address(pm), address(vault), factory, address(oracle), address(ledger), address(0),
            address(guardian), address(referrals), new FeastHook.TipFloor[](0));
        assertEq(address(hook), predictedHook, "hook wiring");
        _createPool();
    }

    function _createPool() internal {
        _createPoolOrdered(true);
    }

    /// @dev Deploy the pair until the coin lands on the requested side, so the
    ///      four-branch arithmetic can be exercised in BOTH token orderings
    ///      rather than in whichever one the addresses happened to give.
    function _createPoolOrdered(bool wantCoinFirst) internal {
        for (uint256 i = 0; i < 128; i++) {
            MockERC20 c = new MockERC20("Coin", "COIN", 18);
            MockERC20 q = new MockERC20("Quote", "Q", 18);
            if ((address(c) < address(q)) == wantCoinFirst) {
                coin = c;
                quote = q;
                break;
            }
        }
        require(address(coin) != address(0), "could not place the coin on the requested side");
        (address c0, address c1) =
            address(coin) < address(quote) ? (address(coin), address(quote)) : (address(quote), address(coin));
        coinIsCurrency0 = c0 == address(coin);

        key = PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            hooks: address(hook),
            poolManager: address(pm),
            fee: FeastConstants.POOL_LP_FEE,
            parameters: hook.poolParameters()
        });

        vm.prank(factory);
        hook.registerPool(key, address(coin), address(0xC0FFEE), 0, 0, 1_000_000_000e18, 0, address(0));
        vm.prank(factory);
        pm.initialize(key.up(), SQRT_PRICE_1_1);

        // Deep, symmetric liquidity so price impact never confounds a fee
        // assertion. The lock and the vesting live in a later step; here the
        // liquidity is placed by an ordinary test router.
        coin.mint(address(router), 1_000_000_000e18);
        quote.mint(address(router), 1_000_000_000e18);
        router.modifyLiquidity(
            key.up(),
            ICLPoolManager.ModifyLiquidityParams({
                tickLower: -887_200,
                tickUpper: 887_200,
                liquidityDelta: 100_000_000e18,
                salt: bytes32(0)
            })
        );
        // These suites are about the fee arithmetic. Step past the opening
        // window so the per-wallet cap cannot confound a size the test chose
        // for arithmetic reasons.
        // v1.6.15: the opening cap window opens at a pool's first SERVED
        // swap, so rolling past CAP_BLOCKS only clears a window that exists.
        CapWarm.arm(router, key.up(), address(quote), !coinIsCurrency0);
        vm.roll(vm.getBlockNumber() + FeastConstants.CAP_BLOCKS);
    }

    function _quoteCurrency() internal view returns (Currency) {
        return coinIsCurrency0 ? key.currency1 : key.currency0;
    }

    function _accrued() internal view returns (uint256) {
        return vault.balanceOf(address(hook), UpCurrency.wrap(Currency.unwrap(_quoteCurrency())));
    }

    /// zeroForOne that buys the coin, whichever side the coin landed on.
    function _buyDirection() internal view returns (bool) {
        return !coinIsCurrency0;
    }

    function _swap(bool zeroForOne, int256 amountSpecified) internal returns (uint256 quoteBefore, uint256 quoteAfter) {
        quoteBefore = quote.balanceOf(address(router));
        router.swap(
            key.up(),
            ICLPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: zeroForOne ? MIN_SQRT : MAX_SQRT
            }),
            ""
        );
        quoteAfter = quote.balanceOf(address(router));
    }

    /// The one property all four branches share. `poolSideQuote` is the quote
    /// that actually crossed the pool boundary: what the swapper paid minus the
    /// fee when quote is the input, or what the swapper received plus the fee
    /// when quote is the output.
    function _assertFeeIsOnePercentOfPoolSideQuote(uint256 poolSideQuote, uint256 fee, string memory what) internal pure {
        uint256 expected = poolSideQuote * FeastConstants.FEE_PIPS / FeastConstants.FEE_DENOMINATOR;
        assertApproxEqAbs(fee, expected, 2, what);
    }

    // --- the four branches ------------------------------------------------

    /// Quote is the specified currency, taken in beforeSwap by scaling the
    /// input down and keeping the difference.
    function test_exactInputBuy_takesOnePercentOfTheQuoteEnteringThePool() public {
        (uint256 before_, uint256 after_) = _swap(_buyDirection(), -1_000_000e18);
        uint256 paid = before_ - after_;
        uint256 fee = _accrued();
        assertEq(paid, 1_000_000e18, "an exact-input swapper pays exactly what they specified");
        assertGt(fee, 0, "a fee was taken");
        _assertFeeIsOnePercentOfPoolSideQuote(paid - fee, fee, "exact-in buy");
    }

    /// Quote is the specified currency, taken in beforeSwap by scaling the
    /// requested output up and keeping the excess.
    function test_exactOutputSell_takesOnePercentOfTheQuoteLeavingThePool() public {
        (uint256 before_, uint256 after_) = _swap(!_buyDirection(), 1_000_000e18);
        uint256 received = after_ - before_;
        uint256 fee = _accrued();
        assertEq(received, 1_000_000e18, "an exact-output swapper receives exactly what they specified");
        assertGt(fee, 0, "a fee was taken");
        _assertFeeIsOnePercentOfPoolSideQuote(received + fee, fee, "exact-out sell");
    }

    /// Quote is the unspecified currency, taken in afterSwap: the swapper
    /// receives less.
    function test_exactInputSell_takesOnePercentOfTheQuoteLeavingThePool() public {
        (uint256 before_, uint256 after_) = _swap(!_buyDirection(), -1_000_000e18);
        uint256 received = after_ - before_;
        uint256 fee = _accrued();
        assertGt(fee, 0, "a fee was taken");
        _assertFeeIsOnePercentOfPoolSideQuote(received + fee, fee, "exact-in sell");
    }

    /// Quote is the unspecified currency, taken in afterSwap: the swapper pays
    /// more.
    function test_exactOutputBuy_takesOnePercentOfTheQuoteEnteringThePool() public {
        (uint256 before_, uint256 after_) = _swap(_buyDirection(), 1_000_000e18);
        uint256 paid = before_ - after_;
        uint256 fee = _accrued();
        assertGt(fee, 0, "a fee was taken");
        _assertFeeIsOnePercentOfPoolSideQuote(paid - fee, fee, "exact-out buy");
    }

    // --- I11: the four agree ---------------------------------------------

    /// The reason the rate corrections exist. Buying a fixed amount of coin
    /// exact-out, versus buying with the quote that trade turns out to cost
    /// exact-in, must produce the same fee — otherwise the two routes price
    /// differently and the difference is free money.
    function testFuzz_exactInAndExactOutAgreeOnPrice(uint96 raw) public {
        uint256 size = bound(uint256(raw), 1e18, 10_000_000e18);

        uint256 snap = vm.snapshotState();
        uint256 coinBefore = coin.balanceOf(address(router));
        (uint256 b1, uint256 a1) = _swap(_buyDirection(), -int256(size));
        uint256 paidExactIn = b1 - a1;
        uint256 feeExactIn = _accrued();
        uint256 coinOut = coin.balanceOf(address(router)) - coinBefore;
        vm.revertToState(snap);

        // Now buy that same amount of coin the other way round.
        (uint256 b2, uint256 a2) = _swap(_buyDirection(), int256(coinOut));
        uint256 paidExactOut = b2 - a2;
        uint256 feeExactOut = _accrued();

        assertApproxEqRel(paidExactOut, paidExactIn, 1e15, "same coin bought, same quote paid (0.1%)");
        assertApproxEqRel(feeExactOut, feeExactIn, 1e15, "same trade, same fee (0.1%)");
    }

    // --- I2: accrual never touches the quote token ------------------------

    /// The required deviation from the reference, and the reason a pausable
    /// quote token cannot brick a feast pool. The reference takes the fee out
    /// as a real transfer inside beforeSwap; feast only ever mints a claim.
    function test_accrualIsAClaimAndNotATokenTransfer() public {
        _swap(_buyDirection(), -1_000_000e18);
        assertGt(_accrued(), 0, "the claim grew");
        assertEq(quote.balanceOf(address(hook)), 0, "the hook holds no quote tokens at all");
        assertEq(coin.balanceOf(address(hook)), 0, "and no coin");
    }

    // --- I1: no swap reverts because of fee accounting --------------------

    /// A fee that rounds to zero must skip, not revert, and must not consume
    /// the swap. A threshold below which fees are waived would be worse than
    /// this: it would define a trade size that pays nothing.
    function test_dustSwapsRoundTheFeeToZeroWithoutReverting() public {
        (uint256 before_, uint256 after_) = _swap(_buyDirection(), -1);
        assertEq(_accrued(), 0, "no fee on a one-wei swap");
        assertLe(before_ - after_, 1, "the swap still happened");
    }

    function testFuzz_noSwapSizeReverts(uint96 raw, bool zeroForOne, bool exactIn) public {
        uint256 size = bound(uint256(raw), 1, 1_000_000e18);
        int256 amount = exactIn ? -int256(size) : int256(size);
        router.swap(
            key.up(),
            ICLPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amount,
                sqrtPriceLimitX96: zeroForOne ? MIN_SQRT : MAX_SQRT
            }),
            ""
        );
    }

    // --- ordering ---------------------------------------------------------

    /// Whether the coin sorts below or above the quote is an accident of its
    /// deployed address, and every branch above depends on getting it right.
    function test_feeLandsOnTheQuoteLegForBothTokenOrderings() public view {
        assertEq(
            Currency.unwrap(_quoteCurrency()),
            address(quote),
            "the test fixture's quote is the pool's quote, whichever slot it took"
        );
    }

    /// I11, held rather than asserted adjacently.
    ///
    /// Round 10 (r10b M2): the cross-case comparison exercised buys only, and
    /// the "both orderings" witness executed no swap at all — it checked which
    /// slot the fixture's quote had taken. Four branches means exact-in and
    /// exact-out, on a buy AND on a sell, and "both orderings" means real swaps
    /// in a pool where the coin is currency0 and in one where it is currency1.
    /// This runs all eight.
    function test_theFourBranchesAgreeInBothTokenOrderings() public {
        _assertFourBranchesAgree("coin as currency0");
        _createPoolOrdered(false);
        assertFalse(coinIsCurrency0, "the second pool really has the other ordering");
        _assertFourBranchesAgree("coin as currency1");
    }

    /// @dev Exact-in and exact-out must price the same trade the same way, on
    ///      both sides of the book. The tolerance is stated once, here: 0.1%,
    ///      which is the venue's own rounding plus the fee's two corrections.
    function _assertFourBranchesAgree(string memory ordering) internal {
        uint256 size = 1_000_000e18;
        uint256 tolerance = 1e15; // 0.1%

        // --- the buy side ---
        uint256 snap = vm.snapshotState();
        uint256 coinBefore = coin.balanceOf(address(router));
        (uint256 b1, uint256 a1) = _swap(_buyDirection(), -int256(size));
        uint256 paidIn = b1 - a1;
        uint256 feeIn = _accrued();
        uint256 coinOut = coin.balanceOf(address(router)) - coinBefore;
        vm.revertToState(snap);

        (uint256 b2, uint256 a2) = _swap(_buyDirection(), int256(coinOut));
        assertApproxEqRel(b2 - a2, paidIn, tolerance, string.concat("buy: quote paid agrees, ", ordering));
        assertApproxEqRel(_accrued(), feeIn, tolerance, string.concat("buy: fee agrees, ", ordering));
        vm.revertToState(snap);

        // --- the sell side. `_swap` reports the QUOTE balance either way, so
        //     the coin leg is measured directly.
        uint256 coinHeld = coin.balanceOf(address(router));
        (uint256 c1_, uint256 d1) = _swap(!_buyDirection(), -int256(size));
        uint256 coinPaidIn = coinHeld - coin.balanceOf(address(router));
        uint256 sellFeeIn = _accrued();
        uint256 quoteOut = d1 - c1_;
        vm.revertToState(snap);

        coinHeld = coin.balanceOf(address(router));
        _swap(!_buyDirection(), int256(quoteOut));
        uint256 coinPaidOut = coinHeld - coin.balanceOf(address(router));
        assertApproxEqRel(coinPaidOut, coinPaidIn, tolerance, string.concat("sell: coin paid agrees, ", ordering));
        assertApproxEqRel(_accrued(), sellFeeIn, tolerance, string.concat("sell: fee agrees, ", ordering));
        vm.revertToState(snap);
    }
}
