// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {FeastConstants} from "../src/FeastConstants.sol";
import {FeastFeeLedger} from "../src/FeastFeeLedger.sol";
import {FeastOracle} from "../src/FeastOracle.sol";
import {FeastPlatformTokenDeployer} from "../src/FeastPlatformTokenDeployer.sol";
import {FeastFactory} from "../src/FeastFactory.sol";
import {FeastHook} from "../src/FeastHook.sol";
import {FeastReferrals} from "../src/FeastReferrals.sol";
import {FeastToken} from "../src/FeastToken.sol";
import {FeastVesting} from "../src/FeastVesting.sol";
import {Currency} from "../src/venue/Currency.sol";
import {PoolId, PoolIdLibrary} from "../src/venue/PoolId.sol";
import {PoolKey} from "../src/venue/PoolKey.sol";

import {Vault} from "infinity-core/src/Vault.sol";
import {CLPoolManager} from "infinity-core/src/pool-cl/CLPoolManager.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";

import {CustomRevert} from "infinity-core/src/libraries/CustomRevert.sol";
import {Hooks} from "infinity-core/src/libraries/Hooks.sol";
import {IFeastCLHooks} from "../src/venue/IFeastCLHooks.sol";

import {MockERC20} from "./utils/MockERC20.sol";
import {PoolRouter} from "./utils/PoolRouter.sol";
import {VenueBridge} from "./utils/VenueBridge.sol";

import {FeastGuardian} from "../../../src/FeastGuardian.sol";
/// R5. For the first couple of blocks a wallet may buy at most a small slice of
/// supply. This is a cap, not a freeze: the reference this borrows the block
/// window from shuts the pool entirely and auctions the first block, which
/// solves sniping by selling it. Feast would rather everyone can trade a little
/// than one party can trade everything.
///
/// The limitation is stated rather than hidden: the venue hands a hook the
/// router's address, not the trader's, so the cap keys on `tx.origin`. That
/// tracks a human but is bypassable by a fresh contract per swap. An auditor
/// should flag it; the alternative — capping the router — would give one
/// wallet's allowance to every trader sharing an aggregator.
contract FeastCapsTest is Test {
    using PoolIdLibrary for PoolKey;
    using VenueBridge for PoolKey;

    uint160 internal constant SQRT_PRICE_1_1 = 79_228_162_514_264_337_593_543_950_336;
    uint160 internal constant MIN_SQRT = 4_295_128_740;
    uint160 internal constant MAX_SQRT = 1_461_446_703_485_210_103_287_273_052_203_988_822_378_723_970_341;
    uint256 internal constant SUPPLY = 1_000_000_000e18;

    address internal creator = address(0xC0FFEE);
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);

    Vault internal vault;
    CLPoolManager internal pm;
    PoolRouter internal router;
    FeastGuardian internal guardian;
    FeastHook internal hook;
    FeastReferrals internal referrals;
    FeastVesting internal vesting;
    FeastFactory internal factory;
    MockERC20 internal quote;
    address internal coin;
    PoolKey internal key;

    /// 0.5% of supply.
    uint256 internal cap;

    function setUp() public {
        vault = new Vault();
        pm = new CLPoolManager(vault);
        vault.registerApp(address(pm));
        router = new PoolRouter(vault, pm);
        quote = new MockERC20("Quote", "Q", 18);

        // Before any address prediction: every CREATE after this shifts by one.
        guardian = new FeastGuardian(address(0x3517), address(this));
        // The referral registry (v1.6.26) has no constructor and no immutables, so
        // its deployed code is the whole of it: etched, it spends none of this
        // contract's nonce — under `isolate` even `deployCodeTo`'s constructor call
        // is a transaction that moves it — and every address below, the tokens' and
        // the platform coin's CREATE2 draw included, is the one it was before.
        referrals = FeastReferrals(address(uint160(uint256(keccak256("feast.referrals")))));
        vm.etch(address(referrals), vm.getDeployedCode("FeastReferrals.sol:FeastReferrals"));
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 5);
        // A real ledger, never address(0): testing rule 2.
        address predictedHook = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 2);
        FeastOracle oracle = new FeastOracle(predictedHook);
        FeastFeeLedger ledger_ = new FeastFeeLedger(predictedHook);
        hook = new FeastHook(address(pm), address(vault), predicted, address(oracle), address(ledger_), address(0),
            address(guardian), address(referrals), new FeastHook.TipFloor[](0));
        vesting = new FeastVesting(predicted, address(guardian));
        FeastPlatformTokenDeployer deployer = new FeastPlatformTokenDeployer(predicted);
        factory = new FeastFactory(
            address(pm), address(vault), address(hook), address(vesting), address(deployer), address(0xB4B), address(this)
        );

        (coin, key) = factory.create(
            FeastFactory.CreateParams({
                name: "Coin",
                symbol: "COIN",
                supply: SUPPLY,
                quote: address(quote),
                creator: creator,
                selfBurnBps: FeastConstants.DEFAULT_SELF_BURN_BPS,
                referrerBps: FeastConstants.DEFAULT_REFERRER_BPS,
                prebuyQuoteIn: 0,
                minCoinsOut: 0,
                vestingDuration: 0,
                sqrtPriceX96: SQRT_PRICE_1_1,
                startTick: 0,
                liquidity: uint128(SUPPLY * 999 / 1_000),
                salt: bytes32(uint256(1)),
                metadataHash: bytes32(0)
            })
        );
        cap = SUPPLY * FeastConstants.CAP_BPS_OF_SUPPLY / FeastConstants.BPS;
        quote.mint(address(router), 1_000_000_000e18);
    }

    /// Buy an exact amount of coin, as `who`.
    function _buyExactCoin(address who, uint256 coinOut) internal {
        bool zeroForOne = Currency.unwrap(key.currency0) == address(quote);
        vm.prank(who, who);
        router.swap(
            key.up(),
            ICLPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: int256(coinOut),
                sqrtPriceLimitX96: zeroForOne ? MIN_SQRT : MAX_SQRT
            }),
            ""
        );
    }

    function _sellCoin(address who, uint256 coinIn) internal {
        bool zeroForOne = Currency.unwrap(key.currency0) == coin;
        vm.prank(who, who);
        router.swap(
            key.up(),
            ICLPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(coinIn),
                sqrtPriceLimitX96: zeroForOne ? MIN_SQRT : MAX_SQRT
            }),
            ""
        );
    }

    /// The venue wraps anything a hook reverts with. Unwrapping it here keeps
    /// the assertion specific: these tests fail if the trade is refused for any
    /// reason other than the cap.
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

    // --- what the cap refuses ---------------------------------------------

    function test_aWalletCannotTakeMoreThanItsSliceInTheOpeningBlocks() public {
        _expectCapRefusal();
        _buyExactCoin(alice, cap + 1e18);
    }

    function test_thePurchasesOfOneWalletAccumulateAcrossTrades() public {
        _buyExactCoin(alice, cap * 6 / 10);
        _expectCapRefusal();
        _buyExactCoin(alice, cap * 6 / 10);
    }

    // --- what it must not refuse ------------------------------------------

    function test_aBuyWithinTheCapGoesThrough() public {
        _buyExactCoin(alice, cap / 2);
        assertGt(FeastToken(coin).balanceOf(address(router)), 0, "the coin was delivered");
    }

    function test_everyWalletGetsItsOwnSlice() public {
        _buyExactCoin(alice, cap * 9 / 10);
        _buyExactCoin(bob, cap * 9 / 10);
    }

    /// Getting this direction wrong would trap the earliest buyers in a coin
    /// they are not allowed to sell — the exact opposite of the intent.
    function test_sellingIsNeverCapped() public {
        _buyExactCoin(alice, cap / 2);
        // The router holds the coin it bought; selling all of it must be fine
        // even inside the window.
        _sellCoin(alice, FeastToken(coin).balanceOf(address(router)));
    }

    function test_theCapIsGoneOnceTheOpeningBlocksHavePassed() public {
        // v1.6.16: the window is a COUNT of distinct SERVED blocks, so rolling
        // does not leave it — a mined block that serves no trade does not
        // count, which is the whole point. `CAP_BLOCKS + 1` served blocks put
        // the pool out of its opening blocks. One wei accrues no fee and moves
        // nothing this test reads.
        for (uint256 i = 0; i <= FeastConstants.CAP_BLOCKS; i++) {
            _buyExactCoin(bob, 1);
            vm.roll(vm.getBlockNumber() + 1);
        }
        assertFalse(hook.capBinds(key.toId()), "the pool has served its opening blocks");
        _buyExactCoin(alice, cap * 50);
        assertGt(FeastToken(coin).balanceOf(address(router)), cap, "far more than a slice, and allowed");
    }

    /// **The LAST block of the window still binds.** A view can be read for the
    /// window's length; only a refusal proves the check uses it. The mutation
    /// gate caught this gap: shortening the check to one served block left
    /// every view-based assertion here passing.
    function test_theLastBlockOfTheWindowIsStillCapped() public {
        // Block one of the window, spent on a purchase nobody could object to.
        _buyExactCoin(bob, 1);
        assertEq(uint256(hook.servedBlocks(key.toId())), 1, "one block served");

        // Block CAP_BLOCKS — the last one the promise covers — and a wallet
        // reaching past its slice in it must still be refused.
        for (uint256 i = 1; i < FeastConstants.CAP_BLOCKS; i++) {
            vm.roll(vm.getBlockNumber() + 1);
        }
        _expectCapRefusal();
        _buyExactCoin(alice, cap + 1e18);
    }

    /// The window is armed by the first swap the pool SERVES, not by its
    /// creation block, so a pool that has never traded has its whole cap window
    /// still ahead of it however many blocks have been mined (v1.6.15).
    ///
    /// Before this, an ungated pool armed at initialisation and a freeze that
    /// spanned the opening blocks spent the window while every swap was refused
    /// (v1.6.13 round). v1.6.14 tried to correct the block coordinate and could
    /// not: a contract cannot observe its chain's block rate.
    function test_theWindowIsArmedByTheFirstSwapAndNotByTheClock() public {
        PoolId id = key.toId();
        assertEq(hook.servedBlocks(id), 0, "no block served before the pool has traded");

        vm.roll(vm.getBlockNumber() + 10_000);
        assertEq(hook.servedBlocks(id), 0, "ten thousand mined blocks serve no trade, so they neither open the window nor spend it");

        _buyExactCoin(bob, 1);
        assertEq(uint256(hook.servedBlocks(id)), 1, "the first served swap counts exactly one block");
        assertTrue(hook.capBinds(id), "and the cap binds over it");

        // Several trades in ONE block count once.
        _buyExactCoin(bob, 1);
        assertEq(uint256(hook.servedBlocks(id)), 1, "a second trade in the same block counts again");

        // The window is CAP_BLOCKS long, so the last of them still binds and
        // the one after it does not. Both ends are asserted: a window that
        // never ends and a window half the promised length would each pass on
        // one of these alone.
        for (uint256 i = 1; i < FeastConstants.CAP_BLOCKS; i++) {
            vm.roll(vm.getBlockNumber() + 1);
            _buyExactCoin(bob, 1);
            assertEq(uint256(hook.servedBlocks(id)), i + 1, "one count per distinct served block");
            assertTrue(hook.capBinds(id), "every block of the window binds, including its last");
        }
        vm.roll(vm.getBlockNumber() + 1);
        _buyExactCoin(bob, 1);
        assertEq(
            uint256(hook.servedBlocks(id)),
            uint256(FeastConstants.CAP_BLOCKS) + 1,
            "the block after the window is counted too"
        );
        assertFalse(hook.capBinds(id), "and the cap is over");
    }

    /// The exemption list exists so that its emptiness is checkable, and it can
    /// never contain anyone: it is a pure function returning false, not an
    /// owner-managed map that happens to be empty today.
    function test_theExemptionListIsEmptyAndCannotBeAddedTo() public {
        assertFalse(hook.isExempt(alice), "nobody is exempt");
        assertFalse(hook.isExempt(address(factory)), "not even the factory");
        assertFalse(hook.isExempt(FeastConstants.BURN_ADDRESS), "nor the burn address");

        string[3] memory sigs =
            ["setExempt(address,bool)", "addExemption(address)", "setFeeExemption(address,uint256)"];
        for (uint256 i = 0; i < sigs.length; i++) {
            (bool ok,) = address(hook).call(abi.encodeWithSignature(sigs[i], alice, uint256(1)));
            assertFalse(ok, sigs[i]);
        }
    }

    function test_theCapWindowAndSizeAreVisibleOnChain() public view {
        PoolId id = key.toId();
        assertEq(hook.perWalletCap(id), cap, "0.5% of supply");
        // Zero, and readable, until the pool's first served swap arms it: see
        // `test_theWindowIsArmedByTheFirstSwapAndNotByTheClock`.
        assertEq(hook.servedBlocks(id), 0, "no block served until the pool trades");
    }
}
