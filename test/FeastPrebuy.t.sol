// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {CustomRevert} from "infinity-core/src/libraries/CustomRevert.sol";
import {Hooks} from "infinity-core/src/libraries/Hooks.sol";

import {IFeastCLHooks} from "../src/venue/IFeastCLHooks.sol";

import {FeastConstants} from "../src/FeastConstants.sol";
import {FeastFactory} from "../src/FeastFactory.sol";
import {FeastHook} from "../src/FeastHook.sol";
import {FeastToken} from "../src/FeastToken.sol";
import {Currency} from "../src/venue/Currency.sol";
import {PoolId, PoolIdLibrary} from "../src/venue/PoolId.sol";
import {PoolKey} from "../src/venue/PoolKey.sol";
import {MockERC20} from "./utils/MockERC20.sol";
import {UnitFixture} from "./utils/UnitFixture.sol";
import {VenueBridge} from "./utils/VenueBridge.sol";

/// The creator's stake is a PAID PRE-BUY at creation, not a free allocation
/// (owner, 2026-09-19; design at `plans/audit/prebuy-design.md`).
///
/// The creator spends quote in the `create` transaction, the quote stays in the
/// pool's permanently locked liquidity, the coins bought vest on a schedule the
/// creator chooses, and everything is public from block one. The pre-buy is an
/// ordinary trade for the fee and is exempt from the per-wallet opening cap —
/// bounded instead by `MAX_PREBUY_BPS_OF_SUPPLY` and by its own price impact.
contract FeastPrebuyTest is UnitFixture {
    using PoolIdLibrary for PoolKey;
    using VenueBridge for PoolKey;

    uint256 internal constant PREBUY = 5_000e18;
    /// `FeastFactory.MIN_PREBUY_VESTING`, read as a constant so no prank is spent on a view.
    uint64 internal constant MIN_VEST = 7 days;

    function _fund(uint256 amount) internal {
        MockERC20(address(wbnb)).mint(creator, amount);
        vm.prank(creator);
        MockERC20(address(wbnb)).approve(address(factory), type(uint256).max);
    }

    /// The venue wraps a hook revert, so the cap arrives as
    /// `WrappedError(hook, afterSwap.selector, PurchaseCapExceeded(), …)`.
    /// Matching on the inner selector is what makes this a witness for the cap
    /// rather than for "the swap failed somehow".
    function _expectCapExceeded() internal {
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

    function _params(uint256 prebuyQuoteIn, uint256 minCoinsOut, uint64 vestingDuration, bytes32 salt)
        internal
        view
        returns (FeastFactory.CreateParams memory)
    {
        return FeastFactory.CreateParams({
            name: "Coin",
            symbol: "COIN",
            supply: 1_000_000_000e18,
            quote: address(wbnb),
            creator: creator,
            selfBurnBps: 2_000,
            referrerBps: 1_000,
            prebuyQuoteIn: prebuyQuoteIn,
            minCoinsOut: minCoinsOut,
            vestingDuration: vestingDuration,
            sqrtPriceX96: SQRT_PRICE_1_1,
            startTick: 0,
            liquidity: uint128(1_000_000_000e18 * 999 / 1_000),
            salt: salt,
            metadataHash: bytes32(0)
        });
    }

    // --- the bound ----------------------------------------------------------

    /// The public's bound, measured in COINS RECEIVED: a share, not a price.
    function test_aPrebuyAboveTheMaximumIsRefusedByName() public {
        uint256 supply = 1_000_000_000e18;
        uint256 max = supply * factory.MAX_PREBUY_BPS_OF_SUPPLY() / FeastConstants.BPS;
        // Enough quote to buy far more than 20% of a 1:1 pool.
        _fund(600_000_000e18);
        FeastFactory.CreateParams memory p = _params(600_000_000e18, 0, MIN_VEST, bytes32("over"));
        vm.expectPartialRevert(FeastFactory.PrebuyTooLarge.selector);
        vm.prank(creator);
        factory.create(p);
        max;
    }

    function test_aPrebuyBelowTheCreatorsOwnBoundIsRefused() public {
        _fund(PREBUY);
        // Ask for more coins than a 1:1 pool can give for this quote.
        FeastFactory.CreateParams memory p = _params(PREBUY, 1_000_000e18, MIN_VEST, bytes32("slip"));
        vm.expectPartialRevert(FeastFactory.PrebuyBelowMinimum.selector);
        vm.prank(creator);
        factory.create(p);
    }

    function test_aSlippageBoundWithNothingToSpendIsRefused() public {
        FeastFactory.CreateParams memory p = _params(0, 1, 0, bytes32("halffilled"));
        vm.expectRevert(FeastFactory.PrebuyNeedsAQuoteAmount.selector);
        vm.prank(creator);
        factory.create(p);
    }

    // --- what the creator gets ----------------------------------------------

    function test_thePrebuysCoinsLandInVestingWithTheChosenEnd() public {
        _fund(PREBUY);
        vm.prank(creator);
        (address coin,) = factory.create(_params(PREBUY, 0, 180 days, bytes32("vest")));

        (, uint256 coinsOut, uint64 vestingEnd) = factory.prebuyOf(coin);
        assertGt(coinsOut, 0, "the pre-buy bought coins");
        assertEq(FeastToken(coin).balanceOf(address(vesting)), coinsOut, "they are in vesting, not the wallet");
        assertEq(FeastToken(coin).balanceOf(creator), 0, "no premine anywhere");
        assertEq(vesting.allocation(coin).total, coinsOut, "the allocation is exactly what was bought");
        assertEq(vesting.allocation(coin).recipient, creator, "and it is the creator's");
        assertEq(vestingEnd, uint64(block.timestamp) + 180 days, "the end the creator chose");
        assertEq(vesting.allocation(coin).endsAt, vestingEnd, "and vesting agrees with the view");
    }

    /// AstraSec I-5 (v1.6.24). This test was `test_aZeroVestingDurationIsSellableImmediately`
    /// and pinned the opposite: a pre-buy of up to 20% of supply could vest
    /// over zero seconds and be sold into the first public buyers. Zero is
    /// refused now, by name, before anything is deployed or paid.
    function test_aZeroVestingDurationIsRefused() public {
        _fund(PREBUY);
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(FeastFactory.PrebuyVestingTooShort.selector, uint64(0), MIN_VEST));
        factory.create(_params(PREBUY, 0, 0, bytes32("now")));
        assertEq(MockERC20(address(wbnb)).balanceOf(creator), PREBUY, "and the creator's quote never moved");
    }

    /// The floor from both sides, to the second: one second short of a week is
    /// refused; a week is accepted, linear from the first second and never a
    /// cliff — nothing at the start, a seventh after a day, all of it at the end.
    function test_theShortestPrebuyVestingIsSevenDaysToTheSecond() public {
        assertEq(factory.MIN_PREBUY_VESTING(), MIN_VEST, "the floor is a week");
        _fund(PREBUY);
        vm.prank(creator);
        vm.expectRevert(
            abi.encodeWithSelector(FeastFactory.PrebuyVestingTooShort.selector, MIN_VEST - 1, MIN_VEST)
        );
        factory.create(_params(PREBUY, 0, MIN_VEST - 1, bytes32("short")));

        uint256 t0 = block.timestamp;
        vm.prank(creator);
        (address coin,) = factory.create(_params(PREBUY, 0, MIN_VEST, bytes32("week")));
        (, uint256 coinsOut, uint64 vestingEnd) = factory.prebuyOf(coin);
        assertEq(vestingEnd, uint64(t0) + MIN_VEST, "a week from the creating block");
        assertEq(vesting.claimable(coin), 0, "nothing at the start");
        vm.warp(t0 + 1 days);
        assertEq(vesting.claimable(coin), coinsOut / 7, "a seventh after a day");
        vm.warp(t0 + MIN_VEST);
        assertEq(vesting.claimable(coin), coinsOut, "all of it at the end");
    }

    function test_thePoolsQuoteBalanceRisesByTheNetInput() public {
        _fund(PREBUY);
        uint256 vaultBefore = MockERC20(address(wbnb)).balanceOf(address(vault));
        vm.prank(creator);
        factory.create(_params(PREBUY, 0, MIN_VEST, bytes32("quote")));
        assertEq(
            MockERC20(address(wbnb)).balanceOf(address(vault)) - vaultBefore,
            PREBUY,
            "every wei the creator paid went into the vault and stays there"
        );
        assertEq(MockERC20(address(wbnb)).balanceOf(creator), 0, "and none of it came back");
        assertEq(MockERC20(address(wbnb)).balanceOf(address(factory)), 0, "the factory keeps nothing");
    }

    // --- the fee ------------------------------------------------------------

    function test_thePrebuyPaysTheOnePercentLikeAnyTrade() public {
        _fund(PREBUY);
        vm.prank(creator);
        (address coin, PoolKey memory key) = factory.create(_params(PREBUY, 0, MIN_VEST, bytes32("fee")));
        coin;
        // The creator's own 50% share of the fee on their own coin, like any
        // other trade of it. Non-zero is the claim: the trade was charged.
        assertGt(hook.claimable(key, creator), 0, "the pre-buy paid the fee and the creator's share accrued");
    }

    function test_aBoundCreatorsReferrerEarnsNothingOnThePrebuy() public {
        // The creator binds a referrer, through the registry since v1.6.26, and
        // trades an unrelated pool with it first.
        (, PoolKey memory other) = _create(address(wbnb), bytes32("bindhere"));
        address freeloader = address(0xF2EE);
        vm.prank(creator);
        referrals.bind(freeloader);
        MockERC20(address(wbnb)).mint(address(router), 1_000e18);
        bool zeroForOne = Currency.unwrap(other.currency0) == address(wbnb);
        vm.prank(creator, creator);
        router.swap(
            other.up(),
            ICLPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(1_000e18),
                sqrtPriceLimitX96: zeroForOne ? MIN_SQRT : MAX_SQRT
            }),
            ""
        );
        assertEq(referrals.referrerOf(creator), freeloader, "the creator is bound");
        assertGt(hook.claimable(other, freeloader), 0, "and the binding pays on a trade that names nobody");

        _fund(PREBUY);
        vm.prank(creator);
        (, PoolKey memory key) = factory.create(_params(PREBUY, 0, MIN_VEST, bytes32("noref")));
        assertEq(
            hook.claimable(key, freeloader), 0, "a factory-initiated pre-buy introduces nobody and pays nobody"
        );
    }

    // --- the opening cap ----------------------------------------------------

    function test_thePrebuyIsNotCountedAsAnOpeningPurchase() public {
        _fund(PREBUY);
        vm.prank(creator);
        (, PoolKey memory key) = factory.create(_params(PREBUY, 0, MIN_VEST, bytes32("cap")));
        assertEq(
            hook.purchasedDuringOpening(key.toId(), creator),
            0,
            "the pre-buy is the creation of the position, not an opening purchase by a wallet"
        );
    }

    function test_theCreatorsOwnNextBuyIsStillCapped() public {
        _fund(PREBUY);
        vm.prank(creator);
        (address coin, PoolKey memory key) = factory.create(_params(PREBUY, 0, MIN_VEST, bytes32("still")));
        uint256 cap = hook.perWalletCap(key.toId());
        assertGt(cap, 0, "the pool has a cap");
        // Still inside the opening blocks. The creator buys from their own
        // wallet, through the router, for far more than the cap.
        MockERC20(address(wbnb)).mint(address(router), 400_000_000e18);
        bool zeroForOne = Currency.unwrap(key.currency0) == address(wbnb);
        // Named, not a bare `expectRevert`: the swap could fail for a dozen
        // reasons and only one of them is the cap doing its job.
        _expectCapExceeded();
        vm.prank(creator, creator);
        router.swap(
            key.up(),
            ICLPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(400_000_000e18),
                sqrtPriceLimitX96: zeroForOne ? MIN_SQRT : MAX_SQRT
            }),
            ""
        );
        coin;
    }

    function test_noOneElseCanReachThePrebuyExemption() public {
        _fund(PREBUY);
        vm.prank(creator);
        (, PoolKey memory key) = factory.create(_params(PREBUY, 0, MIN_VEST, bytes32("nobody")));
        // Same block, same opening window, a different wallet: capped.
        address sniper = address(0x5417E);
        MockERC20(address(wbnb)).mint(address(router), 400_000_000e18);
        bool zeroForOne = Currency.unwrap(key.currency0) == address(wbnb);
        _expectCapExceeded();
        vm.prank(sniper, sniper);
        router.swap(
            key.up(),
            ICLPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(400_000_000e18),
                sqrtPriceLimitX96: zeroForOne ? MIN_SQRT : MAX_SQRT
            }),
            ""
        );
    }

    // --- the disclosure -----------------------------------------------------

    function test_theDisclosureViewAgreesWithTheVestingAllocation() public {
        _fund(PREBUY);
        vm.recordLogs();
        vm.prank(creator);
        (address coin,) = factory.create(_params(PREBUY, 0, 90 days, bytes32("show")));
        (uint256 quoteIn, uint256 coinsOut, uint64 vestingEnd) = factory.prebuyOf(coin);
        assertEq(quoteIn, PREBUY, "the quote the creator paid");
        assertEq(coinsOut, vesting.allocation(coin).total, "the coins agree with vesting");
        assertEq(vestingEnd, vesting.allocation(coin).endsAt, "and so does the end");
    }

    function test_aCoinWithNoPrebuyIsTheOldBehaviourExactly() public {
        vm.prank(creator);
        (address coin,) = factory.create(_params(0, 0, 0, bytes32("inert")));
        (uint256 quoteIn, uint256 coinsOut, uint64 vestingEnd) = factory.prebuyOf(coin);
        assertEq(quoteIn, 0, "no quote");
        assertEq(coinsOut, 0, "no coins");
        assertEq(vestingEnd, 0, "no vesting end");
        assertEq(vesting.allocation(coin).recipient, address(0), "no allocation at all");
        assertEq(FeastToken(coin).balanceOf(address(vesting)), 0, "nothing in vesting");
        assertEq(FeastToken(coin).balanceOf(address(factory)), 0, "the factory keeps nothing");
    }

    // --- the bound, fuzzed --------------------------------------------------

    function testFuzz_theCoinsOutNeverExceedTheBound(uint96 quoteIn) public {
        vm.assume(quoteIn > 1e15);
        _fund(quoteIn);
        uint256 supply = 1_000_000_000e18;
        uint256 max = supply * factory.MAX_PREBUY_BPS_OF_SUPPLY() / FeastConstants.BPS;
        vm.prank(creator);
        try factory.create(_params(quoteIn, 0, MIN_VEST, bytes32("fuzz"))) returns (address coin, PoolKey memory) {
            (, uint256 coinsOut,) = factory.prebuyOf(coin);
            assertLe(coinsOut, max, "the bound holds for every quote amount that is accepted at all");
        } catch {
            // Refused is the other correct answer.
        }
    }

    // --- what the feature costs ---------------------------------------------

    /// The cost of the feature, recorded the way every other gas claim in this
    /// repository is: measured here, printed, and asserted only as a bound so
    /// the number in the docs can be checked against a run.
    function test_gas_createWithAndWithoutAPrebuy() public {
        uint256 before_ = gasleft();
        vm.prank(creator);
        factory.create(_params(0, 0, 0, bytes32("gas-plain")));
        uint256 plain = before_ - gasleft();

        _fund(PREBUY);
        before_ = gasleft();
        vm.prank(creator);
        factory.create(_params(PREBUY, 0, 30 days, bytes32("gas-prebuy")));
        uint256 withPrebuy = before_ - gasleft();

        emit log_named_uint("create, no pre-buy   ", plain);
        emit log_named_uint("create, with pre-buy ", withPrebuy);
        emit log_named_uint("the pre-buy          ", withPrebuy - plain);
        assertGt(withPrebuy, plain, "a real swap and a vesting allocation are not free");
    }
}
