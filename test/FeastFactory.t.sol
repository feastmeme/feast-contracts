// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {FeastConstants} from "../src/FeastConstants.sol";
import {FeastFeeLedger} from "../src/FeastFeeLedger.sol";
import {FeastOracle} from "../src/FeastOracle.sol";
import {FeastPlatformTokenDeployer} from "../src/FeastPlatformTokenDeployer.sol";
import {FeastFactory} from "../src/FeastFactory.sol";
import {FeastCLHookBase} from "../src/FeastCLHookBase.sol";
import {FeastHook} from "../src/FeastHook.sol";
import {FeastReferrals} from "../src/FeastReferrals.sol";
import {FeastToken} from "../src/FeastToken.sol";
import {FeastVesting} from "../src/FeastVesting.sol";
import {Currency} from "../src/venue/Currency.sol";
import {PoolId, PoolIdLibrary} from "../src/venue/PoolId.sol";
import {IFeastCLPoolManager} from "../src/venue/IFeastCLPoolManager.sol";
import {PoolKey} from "../src/venue/PoolKey.sol";

import {Vault} from "infinity-core/src/Vault.sol";
import {CLPoolManager} from "infinity-core/src/pool-cl/CLPoolManager.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";

import {MockERC20} from "./utils/MockERC20.sol";
import {PoolRouter} from "./utils/PoolRouter.sol";
import {VenueBridge} from "./utils/VenueBridge.sol";

import {FeastGuardian} from "../../../src/FeastGuardian.sol";
/// One transaction has to produce a coin, a pool, liquidity nobody can ever
/// remove, and a vesting schedule nobody can redirect. These tests are mostly
/// about the "nobody can" half: the interesting assertions are the absences.
contract FeastFactoryTest is Test {
    using PoolIdLibrary for PoolKey;
    using VenueBridge for PoolKey;

    uint160 internal constant SQRT_PRICE_1_1 = 79_228_162_514_264_337_593_543_950_336;
    uint160 internal constant MIN_SQRT = 4_295_128_740;
    uint160 internal constant MAX_SQRT = 1_461_446_703_485_210_103_287_273_052_203_988_822_378_723_970_341;
    uint256 internal constant SUPPLY = 1_000_000_000e18;

    address internal creator = address(0xC0FFEE);

    Vault internal vault;
    CLPoolManager internal pm;
    PoolRouter internal router;
    FeastGuardian internal guardian;
    FeastHook internal hook;
    FeastReferrals internal referrals;
    FeastVesting internal vesting;
    FeastFactory internal factory;
    MockERC20 internal quote;

    function setUp() public {
        vault = new Vault();
        pm = new CLPoolManager(vault);
        vault.registerApp(address(pm));
        router = new PoolRouter(vault, pm);
        quote = new MockERC20("Quote", "Q", 18);

        // The referral registry (v1.6.26) has no constructor and no immutables, so
        // its deployed code is the whole of it: etched, it spends none of this
        // contract's nonce — under `isolate` even `deployCodeTo`'s constructor call
        // is a transaction that moves it — and every address below, the tokens' and
        // the platform coin's CREATE2 draw included, is the one it was before.
        referrals = FeastReferrals(address(uint160(uint256(keccak256("feast.referrals")))));
        vm.etch(address(referrals), vm.getDeployedCode("FeastReferrals.sol:FeastReferrals"));
        // The three singletons know each other's addresses at construction and
        // nothing can point them anywhere else afterwards.
        // A real ledger, never address(0): testing rule 2.
        address predictedFactory = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 6);
        // The guardian is deployed FIRST of the contracts whose addresses are
        // predicted above, so the offsets there already count it; it takes the
        // factory's predicted address because only the factory may start its clock.
        guardian = new FeastGuardian(address(0x3517), predictedFactory);
        address predictedHook = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 2);
        FeastOracle oracle = new FeastOracle(predictedHook);
        FeastFeeLedger ledger = new FeastFeeLedger(predictedHook);
        hook = new FeastHook(address(pm), address(vault), predictedFactory, address(oracle), address(ledger), address(0),
            address(guardian), address(referrals), new FeastHook.TipFloor[](0));
        vesting = new FeastVesting(predictedFactory, address(guardian));
        FeastPlatformTokenDeployer deployer = new FeastPlatformTokenDeployer(predictedFactory);
        factory = new FeastFactory(
            address(pm), address(vault), address(hook), address(vesting), address(deployer), address(0xB4B), address(this)
        );
        assertEq(address(factory), predictedFactory, "the wiring is fixed at construction");

        // v1.6.10: the creator's stake is BOUGHT at creation, so the creator
        // holds quote and has approved the factory for it. This is the one new
        // step in the launch flow and the app lane carries it too.
        vm.prank(creator);
        quote.approve(address(factory), type(uint256).max);
    }

    /// A pre-buy big enough to leave a visible allocation and small enough not
    /// to move a 1:1 pool far.
    uint256 internal constant PREBUY = 1_000e18;

    function _params(uint256 prebuyQuoteIn, uint64 vestingDuration)
        internal
        view
        returns (FeastFactory.CreateParams memory)
    {
        // A single-sided position running from the start tick to the far edge
        // takes almost exactly `amount` of the coin per unit of liquidity, so
        // the liquidity a creator asks for is essentially the coin they are
        // putting in. A hair under, so the remainder stays inside the 1% the
        // factory is willing to burn.
        // The WHOLE supply seeds the pool from v1.6.10: the creator's stake is
        // bought out of the pool afterwards, not carved out of it before.
        uint256 poolAmount = SUPPLY;
        return FeastFactory.CreateParams({
            name: "Coin",
            symbol: "COIN",
            supply: SUPPLY,
            quote: address(quote),
            creator: creator,
            selfBurnBps: FeastConstants.DEFAULT_SELF_BURN_BPS,
            referrerBps: FeastConstants.DEFAULT_REFERRER_BPS,
            prebuyQuoteIn: prebuyQuoteIn,
            minCoinsOut: 0,
            vestingDuration: vestingDuration,
            sqrtPriceX96: SQRT_PRICE_1_1,
            startTick: 0,
            liquidity: uint128(poolAmount * 999 / 1_000),
            salt: bytes32(uint256(1)),
            metadataHash: bytes32(0)
        });
    }

    /// The ordinary creation: no pre-buy, so the pool opens at exactly the
    /// price the creator asked for and nothing has traded yet.
    function _create() internal returns (address coin, PoolKey memory key) {
        (coin, key) = factory.create(_params(0, 0));
    }

    /// Creation WITH the creator's pre-buy, which is a real trade: it moves the
    /// price and leaves a vesting allocation.
    function _createWithPrebuy() internal returns (address coin, PoolKey memory key) {
        quote.mint(creator, PREBUY);
        // v1.6.12: a pre-buy spends the creator's own approval, so only the
        // creator may ask for one (`PrebuyNeedsTheCreator`).
        vm.prank(creator);
        (coin, key) = factory.create(_params(PREBUY, 30 days));
    }

    // --- v1.6 (Q23): the metadata digest, on chain at launch ----------------

    /// The app keeps nothing off chain: a coin's image and metadata live on
    /// IPFS, and the digest of their CID is written here, in the creating
    /// transaction, and announced — so an indexer rebuilds the site from the
    /// chain and IPFS alone. Kills: storing or emitting anything but the argument.
    function test_theMetadataHashIsStoredAndAnnounced() public {
        FeastFactory.CreateParams memory p = _params(0, 0);
        p.metadataHash = keccak256("ipfs digest of a coin's metadata");
        address predicted = factory.predictCoin(p.salt, p.name, p.symbol, p.supply);
        vm.recordLogs();
        (address coin,) = factory.create(p);
        assertEq(coin, predicted, "the coin");
        assertEq(factory.getCoin(coin).metadataHash, p.metadataHash, "stored with the coin's record");

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool seen;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(factory) && logs[i].topics[0] == FeastFactory.CoinCreated.selector) {
                (, , , , bytes32 announced) = abi.decode(logs[i].data, (PoolId, uint256, uint16, uint16, bytes32));
                assertEq(announced, p.metadataHash, "and announced in the launch event");
                seen = true;
            }
        }
        assertTrue(seen, "the launch event was emitted");
    }

    /// Zero is a coin with no metadata — accepted, as an explicit choice.
    function test_aZeroMetadataHashIsAccepted() public {
        FeastFactory.CreateParams memory p = _params(0, 0);
        p.metadataHash = bytes32(0);
        (address coin,) = factory.create(p);
        assertEq(factory.getCoin(coin).metadataHash, bytes32(0), "recorded as none");
    }

    // --- one transaction --------------------------------------------------

    function test_oneTransactionProducesACoinAPoolAndLockedLiquidity() public {
        (address coin, PoolKey memory key) = _create();

        // Minted once, at `SUPPLY`. Since v1.6.24 (AstraSec I-8) the sliver the
        // opening position did not place is BURNED rather than parked at
        // 0xdEaD, so what exists is `SUPPLY` less that sliver — within the
        // factory's 1% tolerance — and the dead address holds nothing.
        uint256 burned = SUPPLY - FeastToken(coin).totalSupply();
        assertLe(burned, SUPPLY / 100, "fixed supply, less only the unplaced sliver, burned");
        assertEq(FeastToken(coin).balanceOf(FeastConstants.BURN_ADDRESS), 0, "none of it parked at 0xdEaD");
        assertEq(factory.coinCount(), 1, "listed for the app");
        assertEq(factory.coinAt(0), coin, "listCoins");

        (uint160 sqrtPriceX96,,,) = IFeastCLPoolManager(address(pm)).getSlot0(key.toId());
        assertEq(sqrtPriceX96, SQRT_PRICE_1_1, "the pool exists at the asked-for price");
        assertGt(IFeastCLPoolManager(address(pm)).getLiquidity(key.toId()), 0, "and it has liquidity");

        // Nothing is carved out of supply any more: with no pre-buy the whole
        // supply is in the pool and nobody holds a premine.
        assertEq(FeastToken(coin).balanceOf(creator), 0, "no premine lands on the creator");
        assertEq(FeastToken(coin).balanceOf(address(vesting)), 0, "and nothing is vested without a pre-buy");
        assertEq(FeastToken(coin).balanceOf(address(factory)), 0, "the factory keeps nothing");
    }

    /// The same transaction WITH the creator's pre-buy: their stake is bought
    /// from the pool at the pool's own price and lands in vesting, and the
    /// price moves because it was a real trade.
    function test_theSameTransactionWithAPrebuyBuysTheCreatorsStake() public {
        (address coin, PoolKey memory key) = _createWithPrebuy();

        (uint256 quoteIn, uint256 coinsOut, uint64 vestingEnd) = factory.prebuyOf(coin);
        assertEq(quoteIn, PREBUY, "the quote the creator paid");
        assertGt(coinsOut, 0, "and the coins it bought");
        assertEq(vestingEnd, uint64(block.timestamp) + 30 days, "vesting ends where the creator asked");

        assertEq(FeastToken(coin).balanceOf(creator), 0, "still no premine in the wallet");
        assertEq(FeastToken(coin).balanceOf(address(vesting)), coinsOut, "the coins it bought are vesting");
        assertEq(vesting.allocation(coin).total, coinsOut, "and the allocation agrees with the view");
        assertEq(quote.balanceOf(creator), 0, "the creator's quote went into the pool");

        (uint160 sqrtPriceX96,,,) = IFeastCLPoolManager(address(pm)).getSlot0(key.toId());
        assertTrue(sqrtPriceX96 != SQRT_PRICE_1_1, "a real trade moved the price");
    }

    /// The pool trades immediately, and the fee lands in the buckets.
    function test_theNewPoolTradesAndTakesItsFee() public {
        (address coin, PoolKey memory key) = _create();
        quote.mint(address(router), 1_000_000e18);
        MockERC20(coin); // silence unused

        bool zeroForOne = Currency.unwrap(key.currency0) == address(quote);
        router.swap(
            key.up(),
            ICLPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -1_000e18,
                sqrtPriceLimitX96: zeroForOne ? MIN_SQRT : MAX_SQRT
            }),
            ""
        );
        assertGt(hook.poolInfo(key.toId()).accruedQuote, 0, "the fee is being taken on a real pool");
    }

    // --- I5: the lock is an absence ---------------------------------------

    /// Not a timelock. There is no function anywhere that can pass a negative
    /// liquidity delta, so this asserts on the bytecode rather than on a
    /// modifier: any of these resolving would be a withdrawal path.
    function test_noWithdrawalPathExistsOnTheHook() public {
        _create();
        string[8] memory sigs = [
            "removeLiquidity(bytes32,uint128)",
            "withdraw(address,uint256)",
            "withdrawETH()",
            "withdrawERC20(address,uint256)",
            "sweep(address)",
            "rescue(address,uint256)",
            "emergencyWithdraw()",
            "modifyLiquidity(bytes32,int256)"
        ];
        for (uint256 i = 0; i < sigs.length; i++) {
            (bool ok,) = address(hook).call(abi.encodeWithSignature(sigs[i], address(this), uint256(1)));
            assertFalse(ok, sigs[i]);
        }
    }

    /// Seeding is the factory's alone, and happens once. A second call would be
    /// a way to move the hook's token balance into a pool of the caller's
    /// choosing.
    function test_seedingIsTheFactorysAloneAndHappensOnce() public {
        (, PoolKey memory key) = _create();
        vm.expectRevert(FeastCLHookBase.NotFactory.selector);
        hook.seedLiquidity(key, -887_200, 887_200, 1);

        vm.prank(address(factory));
        vm.expectRevert(FeastHook.AlreadySeeded.selector);
        hook.seedLiquidity(key, -887_200, 887_200, 1);
    }

    /// The liquidity is really the hook's, and really still there after trading.
    function test_liquidityStaysAfterTrading() public {
        (, PoolKey memory key) = _create();
        uint128 before_ = IFeastCLPoolManager(address(pm)).getLiquidity(key.toId());
        quote.mint(address(router), 10_000e18);
        bool zeroForOne = Currency.unwrap(key.currency0) == address(quote);
        router.swap(
            key.up(),
            ICLPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -1_000e18,
                sqrtPriceLimitX96: zeroForOne ? MIN_SQRT : MAX_SQRT
            }),
            ""
        );
        assertEq(IFeastCLPoolManager(address(pm)).getLiquidity(key.toId()), before_, "trading never removes the position");
    }

    /// A launch is single-sided: the creator supplies the coin and nothing
    /// else. A range that straddles the opening price would demand quote nobody
    /// put up, and the refusal has to name that rather than surfacing as an
    /// opaque balance error from whichever token was asked for first.
    function test_aRangeStraddlingTheOpeningPriceIsRefusedByName() public {
        FeastFactory.CreateParams memory p = _params(0, 0);
        p.salt = bytes32(uint256(99));

        // Which side the coin sorts to decides which way the range runs, so the
        // straddle has to be derived rather than assumed — the coin's address is
        // an accident of the salt and the factory's own address.
        address predicted = factory.predictCoin(p.salt, p.name, p.symbol, p.supply);
        bool coinIsCurrency0 = predicted < address(quote);
        // The pool opens at tick 0. Coin first means the range runs upward from
        // startTick, so start below the price; coin second means it runs
        // downward, so start above. Either way the opening price ends up inside
        // the range, which needs both tokens.
        p.startTick = coinIsCurrency0 ? int24(-400) : int24(400);
        vm.expectRevert(FeastHook.SeedWouldNeedQuote.selector);
        factory.create(p);
    }

    /// Round 1. A zero creator strands both the vesting allocation and the
    /// creator's fee share for good: the coin refuses a transfer to zero and
    /// there is no recipient setter by design. Only the burn address gets the
    /// routing that makes an unclaimable share meaningful.
    function test_aZeroAddressCreatorIsRefused() public {
        FeastFactory.CreateParams memory p = _params(0, 0);
        p.salt = bytes32(uint256(1234));
        p.creator = address(0);
        vm.expectRevert(FeastFactory.ZeroCreator.selector);
        factory.create(p);
    }

    // --- vesting ----------------------------------------------------------

    function test_vestingAccruesLinearlyAndOnlyEverPaysTheFixedRecipient() public {
        (address coin,) = _createWithPrebuy();
        // v1.6.10: the total is what the pre-buy BOUGHT, not a share of supply
        // the factory handed over. Read it rather than recompute it — the point
        // of the change is that this number comes from a trade.
        uint256 total = vesting.allocation(coin).total;
        assertGt(total, 0, "the pre-buy really bought something to vest");
        // Absolute timestamps: the optimizer treats `block.timestamp` as
        // constant within a call frame and will happily reuse a stale read
        // across two warps.
        uint256 t0 = block.timestamp;

        assertEq(vesting.claimable(coin), 0, "nothing at the start");

        vm.warp(t0 + 15 days);
        assertApproxEqRel(vesting.claimable(coin), total / 2, 1e12, "half way through, half of it");

        // Anyone may press claim; the proceeds always go to the recipient.
        vm.prank(address(0xBEEF));
        vesting.claim(coin);
        assertApproxEqRel(FeastToken(coin).balanceOf(creator), total / 2, 1e12, "paid to the creator, not the caller");
        assertEq(FeastToken(coin).balanceOf(address(0xBEEF)), 0, "the caller gets nothing");

        vm.warp(t0 + 30 days);
        vesting.claim(coin);
        assertEq(FeastToken(coin).balanceOf(creator), total, "fully vested at the end");

        vesting.claim(coin);
        assertEq(FeastToken(coin).balanceOf(creator), total, "and never more than that");
    }

    /// The reference lets the vesting recipient be reassigned. For a product
    /// whose promise is "fixed at creation", that is the whole promise.
    function test_noRecipientSetterExists() public {
        (address coin,) = _create();
        string[3] memory sigs = ["editAllocationAdmin(address,address)", "setRecipient(address,address)", "transferAllocation(address,address)"];
        for (uint256 i = 0; i < sigs.length; i++) {
            (bool ok,) = address(vesting).call(abi.encodeWithSignature(sigs[i], coin, address(this)));
            assertFalse(ok, sigs[i]);
        }
    }

    function test_zeroAllocationMeansNoVestingAtAll() public {
        (address coin,) = factory.create(_params(0, 0));
        assertEq(FeastToken(coin).balanceOf(address(vesting)), 0, "nothing vested");
        assertEq(vesting.claimable(coin), 0, "and nothing claimable");
    }

    // --- determinism ------------------------------------------------------

    function test_theCoinAddressIsDeterministicAndTheSaltCannotBeReused() public {
        (address coin,) = _create();
        assertEq(coin, factory.predictCoin(bytes32(uint256(1)), "Coin", "COIN", SUPPLY), "predicted address");

        vm.expectRevert();
        _create();
    }

    // --- claims -----------------------------------------------------------

    function test_theCreatorCanClaimAndTheClaimAlwaysPaysTheCreator() public {
        (, PoolKey memory key) = _create();
        quote.mint(address(router), 1_000_000e18);
        bool zeroForOne = Currency.unwrap(key.currency0) == address(quote);
        router.swap(
            key.up(),
            ICLPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -100_000e18,
                sqrtPriceLimitX96: zeroForOne ? MIN_SQRT : MAX_SQRT
            }),
            ""
        );

        PoolId id = key.toId();
        uint256 owed = hook.creatorPending(id);
        assertGt(owed, 0, "the creator is owed something");

        // Pressed by a stranger; paid to the creator. A lost creator key
        // strands that creator's bucket and nothing else.
        vm.prank(address(0xBEEF));
        hook.claimCreator(key);
        assertEq(quote.balanceOf(creator), owed, "paid in full to the creator");
        assertEq(hook.creatorPending(id), 0, "and not owed twice");

        hook.claimCreator(key);
        assertEq(quote.balanceOf(creator), owed, "a second claim pays nothing");
    }

    function test_aReferrerCanClaimTheirOwnCommission() public {
        (, PoolKey memory key) = _create();
        address referrer = address(0xEE);
        quote.mint(address(router), 1_000_000e18);
        bool zeroForOne = Currency.unwrap(key.currency0) == address(quote);
        router.swap(
            key.up(),
            ICLPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -100_000e18,
                sqrtPriceLimitX96: zeroForOne ? MIN_SQRT : MAX_SQRT
            }),
            abi.encode(referrer)
        );

        uint256 owed = hook.referrerPending(key.toId(), referrer);
        assertGt(owed, 0, "the referrer earned a commission");
        hook.claimReferrer(key, referrer);
        assertEq(quote.balanceOf(referrer), owed, "paid to the referrer");
        assertEq(hook.referrerPending(key.toId(), referrer), 0, "not owed twice");
    }
}
