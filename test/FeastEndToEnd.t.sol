// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {FeastConstants} from "../src/FeastConstants.sol";
import {FeastConverter} from "../src/FeastConverter.sol";
import {FeastFeeLedger} from "../src/FeastFeeLedger.sol";
import {FeastPlatformTokenDeployer} from "../src/FeastPlatformTokenDeployer.sol";
import {FeastFactory} from "../src/FeastFactory.sol";
import {FeastHook} from "../src/FeastHook.sol";
import {FeastReferrals} from "../src/FeastReferrals.sol";
import {FeastOracle} from "../src/FeastOracle.sol";
import {FeastToken} from "../src/FeastToken.sol";
import {FeastVesting} from "../src/FeastVesting.sol";
import {Currency} from "../src/venue/Currency.sol";
import {PoolId, PoolIdLibrary} from "../src/venue/PoolId.sol";
import {PoolKey} from "../src/venue/PoolKey.sol";

import {CLPoolManager} from "infinity-core/src/pool-cl/CLPoolManager.sol";
import {Vault} from "infinity-core/src/Vault.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";

import {PoolRouter} from "./utils/PoolRouter.sol";
import {VenueBridge} from "./utils/VenueBridge.sol";

import {FeastGuardian} from "../../../src/FeastGuardian.sol";
/// The whole product, once, on the real chain.
///
/// Everything else in this suite tests one thing well. This tests that the
/// things fit together against real contracts and real liquidity: create a coin
/// against a real tokenised stock, trade it referred and unreferred, claim both
/// ways, and press the coin's own burn button.
///
/// The platform conversion and buy-back buttons are not in v1 (branch
/// `v1.1/platform-buttons`), so neither is the vote over the split between
/// burning and rewarding that only those buttons read.
///
/// **The quote addresses below are PROVISIONAL.** They come from
/// `tools/discover_quotes.py`, which found them by symbol and verified each one
/// on chain at the pinned block; the owner confirms them separately. A
/// confirmation changes these constants and nothing else.
contract FeastEndToEndForkTest is Test {
    using PoolIdLibrary for PoolKey;
    using VenueBridge for PoolKey;

    // The real deployment.
    address internal constant CL_POOL_MANAGER = 0xa0FfB9c1CE1Fe56963B0321B32E7A0302114058b;
    address internal constant VAULT = 0x238a358808379702088667322f80aC48bAd5e6c4;
    address internal constant V3_FACTORY = 0x0BFbCF9fa4f9C56B0F40a671Ad40E0805A091865;
    address internal constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address internal constant USDT = 0x55d398326f99059fF775485246999027B3197955;

    // PROVISIONAL canonical quote set, pending the owner's confirmation.
    address internal constant AAPLB = 0x431a3BEE82E2ca41e49895CbECE5bB0F76A89b7A;
    address internal constant AAPLB_HOLDER = 0xe9b9998B2EC5430D2246c7f1F8D9f298c97D7365;
    uint24 internal constant AAPLB_USDT_FEE = 2500;

    uint256 internal constant FORK_BLOCK = 120_721_477;
    uint160 internal constant SQRT_PRICE_1_1 = 79_228_162_514_264_337_593_543_950_336;
    uint160 internal constant MIN_SQRT = 4_295_128_740;
    uint160 internal constant MAX_SQRT = 1_461_446_703_485_210_103_287_273_052_203_988_822_378_723_970_341;
    uint256 internal constant SUPPLY = 1_000_000_000e18;

    address internal creator = address(0xC0FFEE);
    address internal referrer = address(0xEE01);
    address internal trader = address(0x7EADE1);
    address internal presser = address(0xBEEF01);

    Vault internal vault;
    CLPoolManager internal pm;
    PoolRouter internal router;
    FeastOracle internal oracle;
    FeastConverter internal converter;
    FeastFeeLedger internal ledger;
    FeastGuardian internal guardian;
    FeastHook internal hook;
    FeastReferrals internal referrals;
    FeastVesting internal vesting;
    FeastFactory internal factory;

    address internal coin;
    PoolKey internal key;

    uint256 internal clock;

    function _forked() internal returns (bool) {
        string memory url = vm.envOr("BSC_RPC_URL", string(""));
        if (bytes(url).length == 0) {
            vm.skip(true);
            return false;
        }
        vm.createSelectFork(url, FORK_BLOCK);
        _deploy();
        return true;
    }

    function _deploy() internal {
        clock = block.timestamp;
        vault = Vault(VAULT);
        pm = CLPoolManager(CL_POOL_MANAGER);
        router = new PoolRouter(vault, pm);

        // The referral registry (v1.6.26) has no constructor and no immutables, so
        // its deployed code is the whole of it: etched, it spends none of this
        // contract's nonce — under `isolate` even `deployCodeTo`'s constructor call
        // is a transaction that moves it — and every address below, the tokens' and
        // the platform coin's CREATE2 draw included, is the one it was before.
        referrals = FeastReferrals(address(uint160(uint256(keccak256("feast.referrals")))));
        vm.etch(address(referrals), vm.getDeployedCode("FeastReferrals.sol:FeastReferrals"));
        // The deployment order the recipe prescribes: each address is an
        // immutable argument of the next, so the later ones are predicted.
        uint64 n = vm.getNonce(address(this));
        address predictedHook = vm.computeCreateAddress(address(this), n + 4);
        address predictedFactory = vm.computeCreateAddress(address(this), n + 7);
        // The guardian is deployed FIRST of the contracts whose addresses are
        // predicted above, so the offsets there already count it; it takes the
        // factory's predicted address because only the factory may start its clock.
        guardian = new FeastGuardian(address(0x3517), predictedFactory);

        oracle = new FeastOracle(predictedHook);
        converter = new FeastConverter(V3_FACTORY, WBNB, predictedHook);
        // A real ledger, never address(0): testing rule 2. The attribution
        // ledger is what v1 ships of the reward system, so a fixture that
        // disabled it would let the recording call be deleted unnoticed.
        ledger = new FeastFeeLedger(predictedHook);
        hook = new FeastHook(
            CL_POOL_MANAGER, VAULT, predictedFactory, address(oracle), address(ledger), address(converter),
            address(guardian), address(referrals), new FeastHook.TipFloor[](0)
        );
        vesting = new FeastVesting(predictedFactory, address(guardian));
        FeastPlatformTokenDeployer deployer = new FeastPlatformTokenDeployer(predictedFactory);
        factory = new FeastFactory(CL_POOL_MANAGER, VAULT, address(hook), address(vesting), address(deployer), WBNB, address(this));
        assertEq(address(hook), predictedHook, "hook wiring");
        assertEq(address(factory), predictedFactory, "factory wiring");
    }

    function _advance(uint32 s) internal {
        clock += s;
        vm.warp(clock);
        vm.roll(vm.getBlockNumber() + 1);
    }

    function _borrow(address token, address holder, address to, uint256 amount) internal {
        vm.prank(holder);
        IERC20(token).transfer(to, amount);
    }

    function _create(address quote, bytes32 salt, address creator_, uint16 selfBurnBps, uint16 referrerBps)
        internal
        returns (address c, PoolKey memory k)
    {
        address predicted = factory.predictCoin(salt, "Coin", "COIN", SUPPLY);
        bool coinIsCurrency0 = predicted < quote;
        (c, k) = factory.create(
            FeastFactory.CreateParams({
                name: "Coin",
                symbol: "COIN",
                supply: SUPPLY,
                quote: quote,
                creator: creator_,
                selfBurnBps: selfBurnBps,
                referrerBps: referrerBps,
                prebuyQuoteIn: 0,
                minCoinsOut: 0,
                vestingDuration: 0,
                sqrtPriceX96: SQRT_PRICE_1_1,
                startTick: coinIsCurrency0 ? int24(0) : int24(0),
                liquidity: uint128(SUPPLY * 999 / 1_000),
                salt: salt,
                metadataHash: bytes32(0)
            })
        );
    }

    function _createWithPrebuy(address quote, bytes32 salt, address creator_, uint256 prebuyQuoteIn)
        internal
        returns (address c, PoolKey memory k)
    {
        // v1.6.12: a pre-buy spends the creator's own approval, so only the
        // creator may ask for one (`PrebuyNeedsTheCreator`).
        if (prebuyQuoteIn != 0) vm.prank(creator_);
        (c, k) = factory.create(
            FeastFactory.CreateParams({
                name: "Coin",
                symbol: "COIN",
                supply: SUPPLY,
                quote: quote,
                creator: creator_,
                selfBurnBps: 0,
                referrerBps: 0,
                prebuyQuoteIn: prebuyQuoteIn,
                minCoinsOut: 0,
                vestingDuration: 7 days, // v1.6.24 I-5: a pre-buy vests a week at least
                sqrtPriceX96: SQRT_PRICE_1_1,
                startTick: 0,
                liquidity: uint128(SUPPLY * 999 / 1_000),
                salt: salt,
                metadataHash: bytes32(0)
            })
        );
    }

    function _buy(PoolKey memory k, address quote, int256 amount, bytes memory hookData) internal {
        bool zeroForOne = Currency.unwrap(k.currency0) == quote;
        vm.prank(trader, trader);
        router.swap(
            k.up(),
            ICLPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amount,
                sqrtPriceLimitX96: zeroForOne ? MIN_SQRT : MAX_SQRT
            }),
            hookData
        );
    }

    function _route() internal pure returns (FeastConverter.Hop[] memory r) {
        r = new FeastConverter.Hop[](2);
        r[0] = FeastConverter.Hop({tokenOut: USDT, fee: AAPLB_USDT_FEE});
        r[1] = FeastConverter.Hop({tokenOut: WBNB, fee: 500});
    }

    // =====================================================================

    /// Create, trade both ways, and see the split land where it should.
    function test_fork_createAndTradeAgainstARealStockToken() public {
        if (!_forked()) return;
        (coin, key) = _create(AAPLB, bytes32(uint256(1)), creator, 2_000, 1_000);

        _borrow(AAPLB, AAPLB_HOLDER, address(router), 200e18);
        vm.roll(vm.getBlockNumber() + FeastConstants.CAP_BLOCKS);

        _buy(key, AAPLB, -20e18, "");
        _buy(key, AAPLB, -20e18, abi.encode(referrer));

        PoolId id = key.toId();
        uint256 total = hook.poolInfo(id).accruedQuote;
        assertGt(total, 0, "the pool earned");
        assertGt(hook.referrerPending(id, referrer), 0, "the referred trade paid a commission");
        assertEq(
            hook.selfBurnPending(id) + hook.platformPending(id) + hook.creatorPending(id)
                + hook.referrerPending(id, referrer),
            total,
            "and the four shares are the whole of it"
        );
        assertEq(IERC20(AAPLB).balanceOf(address(hook)), 0, "held as claims, not as tokens");
    }

    /// Both claim paths, against the real token and the real route.
    function test_fork_claimInQuoteAndClaimAsNative() public {
        if (!_forked()) return;
        (coin, key) = _create(AAPLB, bytes32(uint256(2)), creator, 2_000, 1_000);

        _borrow(AAPLB, AAPLB_HOLDER, address(router), 200e18);
        vm.roll(vm.getBlockNumber() + FeastConstants.CAP_BLOCKS);
        _buy(key, AAPLB, -50e18, abi.encode(referrer));

        // The floor: pays the quote token, needs nothing from anyone.
        uint256 owedReferrer = hook.claimable(key, referrer);
        assertGt(owedReferrer, 0, "the referrer is owed");
        hook.claim(key, referrer);
        assertEq(IERC20(AAPLB).balanceOf(referrer), owedReferrer, "paid in the stock token");

        // The convenience: claims and converts in one call, along a real route.
        uint256 owedCreator = hook.claimable(key, creator);
        assertGt(owedCreator, 0, "the creator is owed");
        // The claimant chooses their own route; nobody may choose it for them.
        vm.prank(creator);
        uint256 out = hook.claimAsBnb(key, creator, _route(), 0);
        assertGt(out, 0, "converted to the chain's own asset");
        assertEq(IERC20(WBNB).balanceOf(creator), out, "and delivered");
        assertEq(hook.claimable(key, creator), 0, "and settled exactly once");
    }

    /// The coin's own burn button, on the real venue.
    ///
    /// This was called `bothButtonsAndAnEpochClaim` until round 4's coverage
    /// lens pointed out it only ever pressed one button and claimed no pot.
    /// The other button is not in v1, so the name is now the truth.
    function test_fork_theCoinBuysItselfBackAndBurnsIt() public {
        if (!_forked()) return;

        (coin, key) = _create(AAPLB, bytes32(uint256(3)), creator, 2_000, 0);
        _borrow(AAPLB, AAPLB_HOLDER, address(router), 400e18);
        vm.roll(vm.getBlockNumber() + FeastConstants.CAP_BLOCKS);

        // Trade across several blocks so both pools have a time-weighted price.
        for (uint256 i = 0; i < 6; i++) {
            _advance(120);
            _buy(key, AAPLB, -60e18, "");
        }

        // Button one: the coin buys itself back and burns it.
        PoolId id = key.toId();
        uint256 supplyBefore = FeastToken(coin).totalSupply();
        uint256 pendingBefore = hook.selfBurnPending(id);
        // Press what the allowance actually permits. Asking for more is
        // clamped, not refused, so a fixed fraction would silently test the
        // clamp rather than the press.
        uint256 spend = hook.spendingAllowance(id);
        assertGt(spend, 0, "there is something to spend");
        vm.prank(presser);
        hook.buyBackAndBurn(key, spend);

        uint256 burned = supplyBefore - FeastToken(coin).totalSupply();
        uint256 tip = FeastToken(coin).balanceOf(presser);
        assertGt(burned, 0, "the coin bought itself back and burned it");
        // Everything the press bought went to exactly two places, and the tip
        // is the smaller of them by a wide margin.
        assertGt(tip, 0, "the presser was paid");
        assertLt(tip * 20, burned, "and the burn dwarfs the tip");
        assertEq(FeastToken(coin).balanceOf(address(hook)), 0, "the hook keeps none of it");
        assertEq(hook.selfBurnPending(id), pendingBefore - spend, "the bucket was debited by exactly what was spent");
    }

    /// A frozen quote token stops that pool's swaps and its quote-denominated
    /// claims, corrupts nothing, and stops nothing else. Run with the
    /// placeholder token, whose pauser is real and reachable on the fork.
    function test_fork_aPausedQuoteTokenCorruptsNothing() public {
        if (!_forked()) return;
        address placeholder = 0x8aD3c73F833d3F9A523aB01476625F269aEB7Cf0;
        address placeholderHolder = 0x5E12d6EdB2b7D5330e474ea2D2694A3b3E35d492;

        (coin, key) = _create(placeholder, bytes32(uint256(4)), creator, 2_000, 0);
        (address coinB, PoolKey memory keyB) = _create(AAPLB, bytes32(uint256(5)), creator, 2_000, 0);
        coinB;

        _borrow(placeholder, placeholderHolder, address(router), 0.01e18);
        _borrow(AAPLB, AAPLB_HOLDER, address(router), 100e18);
        vm.roll(vm.getBlockNumber() + FeastConstants.CAP_BLOCKS);

        _buy(key, placeholder, -0.005e18, "");
        PoolId id = key.toId();
        uint256 accrued = hook.poolInfo(id).accruedQuote;
        assertGt(accrued, 0, "the frozen-to-be pool earned first");

        // The SAME sender, transferring before and after, or the probe proves
        // nothing. Round 12 (r12a M2): this used to fund `placeholderHolder`
        // and then probe from `AAPLB_HOLDER`, so an insufficient-balance
        // rejection satisfied the "it is frozen" assertion without any freeze.
        vm.prank(placeholderHolder);
        (bool movedBefore,) = placeholder.call(abi.encodeWithSignature("transfer(address,uint256)", address(0xDEAD), 1));
        assertTrue(movedBefore, "the probe account can move the token BEFORE the freeze");

        // Freeze it, using the token's own pauser.
        address pauser = address(uint160(uint256(vm.load(placeholder, bytes32(uint256(0))))));
        (bool ok, bytes memory ret) = placeholder.staticcall(abi.encodeWithSignature("pauser()"));
        require(ok, "pauser()");
        pauser = abi.decode(ret, (address));
        vm.prank(pauser);
        (ok,) = placeholder.call(abi.encodeWithSignature("setPause(bool)", true));
        if (!ok) {
            (ok,) = placeholder.call(abi.encodeWithSignature("pause()"));
        }
        vm.stopPrank();

        // Round 10 (r10b M2): this used to say "whether or not the freeze took",
        // which made the witness unable to fail — a token that never froze
        // still passed. The freeze is the premise of the test, so it is now
        // asserted operationally: a transfer that would otherwise succeed must
        // now revert. If the admin surface changes and the freeze stops
        // working, this test fails rather than quietly proving nothing.
        vm.prank(placeholderHolder);
        (bool moved,) = placeholder.call(abi.encodeWithSignature("transfer(address,uint256)", address(0xDEAD), 1));
        assertFalse(moved, "and cannot move it after: the freeze, not a balance, is what stopped it");

        assertEq(hook.poolInfo(id).accruedQuote, accrued, "the ledger is exactly as it was");

        // A claim in the frozen quote refuses, and the entitlement survives it.
        uint256 owedWhileFrozen = hook.claimable(key, creator);
        assertGt(owedWhileFrozen, 0, "the creator is owed something");
        (bool claimed,) = address(hook).call(abi.encodeWithSelector(FeastHook.claimCreator.selector, key));
        assertFalse(claimed, "a claim in a frozen quote refuses");
        assertEq(hook.claimable(key, creator), owedWhileFrozen, "and the entitlement is exactly as it was");

        // Unfreeze, and the same claim now pays — the recovery half.
        vm.prank(pauser);
        (ok,) = placeholder.call(abi.encodeWithSignature("setPause(bool)", false));
        if (!ok) {
            vm.prank(pauser);
            (ok,) = placeholder.call(abi.encodeWithSignature("unpause()"));
        }
        assertTrue(ok, "the token unfroze");
        hook.claimCreator(key);
        assertEq(IERC20(placeholder).balanceOf(creator), owedWhileFrozen, "value stuck, never lost");
        assertEq(hook.claimable(key, creator), 0, "and settled exactly once");

        uint256 before_ = hook.poolInfo(keyB.toId()).accruedQuote;
        _buy(keyB, AAPLB, -20e18, "");
        assertGt(hook.poolInfo(keyB.toId()).accruedQuote, before_, "and every other pool keeps earning");
    }


    /// v1.6.10: the creator's pre-buy, on the real venue at the pinned block.
    /// The one path that matters here is the factory's own lock callback —
    /// everything else is exercised off-fork — so this asserts that a real
    /// PancakeSwap Infinity vault accepts it and that the coins land in vesting.
    function test_fork_theCreatorsPrebuyRunsOnTheRealVenue() public {
        if (!_forked()) return;

        uint256 prebuy = 1e18;
        deal(WBNB, creator, prebuy);
        vm.prank(creator);
        IERC20(WBNB).approve(address(factory), type(uint256).max);

        (address coin,) = _createWithPrebuy(WBNB, bytes32("fork-prebuy"), creator, prebuy);

        (uint256 quoteIn, uint256 coinsOut, uint64 vestingEnd) = factory.prebuyOf(coin);
        assertEq(quoteIn, prebuy, "the quote the creator paid, on the real vault");
        assertGt(coinsOut, 0, "and the coins the real pool gave for it");
        assertEq(vesting.allocation(coin).total, coinsOut, "which are vesting");
        assertEq(vestingEnd, vesting.allocation(coin).endsAt, "with the end the view reports");
    }
}
