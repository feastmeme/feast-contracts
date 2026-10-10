// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FeastConstants} from "../src/FeastConstants.sol";
import {FeastFeeLedger} from "../src/FeastFeeLedger.sol";
import {FeastPlatformTokenDeployer} from "../src/FeastPlatformTokenDeployer.sol";
import {FeastFactory} from "../src/FeastFactory.sol";
import {FeastHook} from "../src/FeastHook.sol";
import {FeastReferrals} from "../src/FeastReferrals.sol";
import {FeastOracle} from "../src/FeastOracle.sol";
import {FeastVesting} from "../src/FeastVesting.sol";
import {Currency} from "../src/venue/Currency.sol";
import {PoolId, PoolIdLibrary} from "../src/venue/PoolId.sol";
import {PoolKey} from "../src/venue/PoolKey.sol";

import {Vault} from "infinity-core/src/Vault.sol";
import {CLPoolManager} from "infinity-core/src/pool-cl/CLPoolManager.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";

import {FeastConverter} from "../src/FeastConverter.sol";
import {MockERC20} from "./utils/MockERC20.sol";
import {CapWarm} from "./utils/CapWarm.sol";
import {MockV3Factory, MockV3Pool} from "./utils/MockV3Pool.sol";
import {PoolRouter} from "./utils/PoolRouter.sol";
import {VenueBridge} from "./utils/VenueBridge.sol";

import {FeastGuardian} from "../../../src/FeastGuardian.sol";
/// An entitlement larger than the venue can settle in one go.
///
/// Round 10 (r10a H1). The ledger counts entitlement in `uint256`, but a payout
/// settles through the venue's signed 128-bit delta — so a bucket that grew past
/// `type(int128).max` reverted every claim from then on, permanently, with no
/// smaller withdrawal available anywhere. The quote token here has 36 decimals,
/// which the plan's "at least six" assumption admits, and the threshold is then
/// only about 170 whole tokens.
contract FeastClaimBoundTest is Test {
    using PoolIdLibrary for PoolKey;
    using VenueBridge for PoolKey;

    uint160 internal constant SQRT_PRICE_1_1 = 79_228_162_514_264_337_593_543_950_336;
    uint160 internal constant MAX_SQRT = 1_461_446_703_485_210_103_287_273_052_203_988_822_378_723_970_341;
    uint256 internal constant SUPPLY = 1e33;

    address internal creator = address(0xC0FFEE);
    address internal trader = address(0x7EADE1);

    Vault internal vault;
    CLPoolManager internal pm;
    PoolRouter internal router;
    FeastGuardian internal guardian;
    FeastHook internal hook;
    FeastReferrals internal referrals;
    FeastOracle internal oracle;
    FeastFeeLedger internal ledger;
    FeastVesting internal vesting;
    FeastFactory internal factory;
    MockERC20 internal quote;
    MockERC20 internal wbnb;
    FeastConverter internal converter;
    MockV3Factory internal v3Factory;
    MockV3Pool internal routePool;
    address internal coin;
    PoolKey internal key;

    function setUp() public {
        vm.warp(1_000_000);
        vault = new Vault();
        pm = new CLPoolManager(vault);
        vault.registerApp(address(pm));
        router = new PoolRouter(vault, pm);
        quote = new MockERC20("Deep", "DEEP", 36);
        wbnb = new MockERC20("Wrapped", "WBNB", 18);

        // The referral registry (v1.6.26) has no constructor and no immutables, so
        // its deployed code is the whole of it: etched, it spends none of this
        // contract's nonce — under `isolate` even `deployCodeTo`'s constructor call
        // is a transaction that moves it — and every address below, the tokens' and
        // the platform coin's CREATE2 draw included, is the one it was before.
        referrals = FeastReferrals(address(uint160(uint256(keccak256("feast.referrals")))));
        vm.etch(address(referrals), vm.getDeployedCode("FeastReferrals.sol:FeastReferrals"));
        uint64 n = vm.getNonce(address(this));
        address predictedHook = vm.computeCreateAddress(address(this), n + 6);
        address predictedFactory = vm.computeCreateAddress(address(this), n + 9);
        // The guardian is deployed FIRST of the contracts whose addresses are
        // predicted above, so the offsets there already count it; it takes the
        // factory's predicted address because only the factory may start its clock.
        guardian = new FeastGuardian(address(0x3517), predictedFactory);
        // A real converter, so `_claimTo` — where the two claim components share
        // ONE settlement budget — is reachable at all. Round 12 (r12b M1): the
        // arithmetic was right and nothing could tell if it stopped being.
        v3Factory = new MockV3Factory();
        routePool = new MockV3Pool(address(quote), address(wbnb));
        oracle = new FeastOracle(predictedHook);
        converter = new FeastConverter(address(v3Factory), address(wbnb), predictedHook);
        ledger = new FeastFeeLedger(predictedHook);
        hook = new FeastHook(
            address(pm), address(vault), predictedFactory, address(oracle), address(ledger), address(converter),
            address(guardian), address(referrals), new FeastHook.TipFloor[](0)
        );
        vesting = new FeastVesting(predictedFactory, address(guardian));
        FeastPlatformTokenDeployer deployer = new FeastPlatformTokenDeployer(predictedFactory);
        factory = new FeastFactory(
            address(pm), address(vault), address(hook), address(vesting), address(deployer), address(wbnb), address(this)
        );

        (coin, key) = factory.create(
            FeastFactory.CreateParams({
                name: "Coin",
                symbol: "COIN",
                supply: SUPPLY,
                quote: address(quote),
                creator: creator,
                selfBurnBps: 0,
                referrerBps: 3_000,
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
        quote.mint(address(router), 1e44);
        v3Factory.set(address(quote), address(wbnb), 500, address(routePool));
        routePool.setOldestTimestamp(uint32(block.timestamp - 3_600));
        routePool.setTicks(0, 0);
        routePool.setOutputBps(10_000);
        wbnb.mint(address(routePool), 1e42);
        // v1.6.15: the opening cap window opens at a pool's first SERVED
        // swap, so rolling past CAP_BLOCKS only clears a window that exists.
        CapWarm.arm(router, key.up(), address(quote), Currency.unwrap(key.currency0) == address(quote));
        vm.roll(vm.getBlockNumber() + FeastConstants.CAP_BLOCKS);
    }

    address internal referrer = address(0x1EFE11A1);

    function _buy(int256 amount) internal {
        _buyReferred(amount, "");
    }

    function _buyReferred(int256 amount, bytes memory hookData) internal {
        bool zeroForOne = Currency.unwrap(key.currency0) == address(quote);
        vm.prank(trader, trader);
        router.swap(
            key.up(),
            ICLPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amount,
                sqrtPriceLimitX96: zeroForOne ? 4_295_128_740 : MAX_SQRT
            }),
            hookData
        );
    }

    function test_anEntitlementLargerThanOneSettlementIsStillClaimable() public {
        PoolId id = key.toId();
        for (uint256 i = 0; i < 220 && hook.creatorPending(id) <= FeastConstants.MAX_SETTLEMENT; i++) {
            _buy(-1e38);
        }
        uint256 owed = hook.creatorPending(id);
        assertGt(owed, FeastConstants.MAX_SETTLEMENT, "the ledger really did outgrow one settlement");

        // The claim pays what the venue can settle and leaves the rest owed,
        // rather than reverting for ever.
        hook.claimCreator(key);
        assertEq(quote.balanceOf(creator), FeastConstants.MAX_SETTLEMENT, "paid one full settlement");
        assertEq(hook.creatorPending(id), owed - FeastConstants.MAX_SETTLEMENT, "and the remainder is still owed");

        // And the remainder comes out on the next call.
        hook.claimCreator(key);
        assertEq(quote.balanceOf(creator), owed, "the whole entitlement is recoverable, in pieces");
        assertEq(hook.creatorPending(id), 0, "with nothing left behind");
    }

    /// Round 11 (r11a H1 / r11b H1), found by both lenses independently, and a
    /// sibling of the fix that round 10 asked for.
    ///
    /// `claimReferrer` capped the payment at one settlement — and then zeroed
    /// the WHOLE pending entry, paying the capped amount and destroying the
    /// rest. That is strictly worse than the defect being fixed: a claim that
    /// reverts keeps the money, a claim that silently deletes it does not. And
    /// the path is permissionless, so a stranger could trigger someone else's
    /// loss.
    function test_aBoundedReferrerClaimNeverDestroysTheRemainder() public {
        PoolId id = key.toId();
        bytes memory data = abi.encode(referrer);
        for (uint256 i = 0; i < 700 && hook.referrerPending(id, referrer) <= FeastConstants.MAX_SETTLEMENT; i++) {
            _buyReferred(-1e38, data);
        }
        uint256 owed = hook.referrerPending(id, referrer);
        assertGt(owed, FeastConstants.MAX_SETTLEMENT, "the commission outgrew one settlement");

        // Anyone may press it — that is the point of a pull payment.
        vm.prank(address(0xBADBAD));
        hook.claimReferrer(key, referrer);

        assertEq(quote.balanceOf(referrer), FeastConstants.MAX_SETTLEMENT, "paid one full settlement");
        assertEq(
            hook.referrerPending(id, referrer),
            owed - FeastConstants.MAX_SETTLEMENT,
            "and the unpaid remainder is still owed, not deleted"
        );

        hook.claimReferrer(key, referrer);
        assertEq(quote.balanceOf(referrer), owed, "the whole commission is recoverable, in pieces");
    }

    /// Round 12 (r12b M1). `_claimTo` pays a creator component and a referral
    /// component out of ONE settlement budget. Nothing distinguished that from
    /// two independent budgets, or from clearing the referral entry outright —
    /// the round-11 defect at its sibling site.
    ///
    /// The construction the lens asked for: let the creator component alone
    /// exhaust the budget, with a referral entitlement still outstanding. Then
    /// a correct implementation pays exactly one settlement and leaves the
    /// referral untouched; giving each component its own budget would try to
    /// settle more than the venue allows and revert; and clearing the entry
    /// would destroy the referral.
    function test_theTwoClaimComponentsShareOneSettlementBudget() public {
        PoolId id = key.toId();
        // The claimant is both creator and referrer, which is what makes the
        // two components meet in one call.
        bytes memory data = abi.encode(creator);
        for (uint256 i = 0; i < 700 && hook.creatorPending(id) <= FeastConstants.MAX_SETTLEMENT; i++) {
            _buyReferred(-1e38, data);
        }
        uint256 owedCreator = hook.creatorPending(id);
        uint256 owedReferral = hook.referrerPending(id, creator);
        assertGt(owedCreator, FeastConstants.MAX_SETTLEMENT, "the creator component alone exhausts the budget");
        assertGt(owedReferral, 0, "and there is a referral component behind it");

        FeastConverter.Hop[] memory route = new FeastConverter.Hop[](1);
        route[0] = FeastConverter.Hop({tokenOut: address(wbnb), fee: 500});
        vm.prank(creator);
        hook.claimAsBnb(key, creator, route, 0);

        assertEq(
            hook.creatorPending(id),
            owedCreator - FeastConstants.MAX_SETTLEMENT,
            "the creator component was paid exactly one settlement"
        );
        assertEq(
            hook.referrerPending(id, creator),
            owedReferral,
            "and the referral component is untouched: no budget of its own, and not cleared"
        );
    }

    /// The other half of the same budget, and the case that distinguishes
    /// "debit what was paid" from "clear the entry": the creator component
    /// takes PART of the budget, so the referral component is paid only what is
    /// left and must keep the rest. With the creator exhausting the budget the
    /// referral is capped to zero, and clearing an entry by zero looks exactly
    /// like subtracting zero.
    function test_aPartlyPaidReferralComponentKeepsItsRemainder() public {
        PoolId id = key.toId();
        bytes memory data = abi.encode(creator);
        // Stop while the creator alone is still under the budget but the two
        // together are over it.
        for (uint256 i = 0; i < 700; i++) {
            _buyReferred(-1e38, data);
            uint256 c = hook.creatorPending(id);
            if (c + hook.referrerPending(id, creator) > FeastConstants.MAX_SETTLEMENT) break;
        }
        uint256 owedCreator = hook.creatorPending(id);
        uint256 owedReferral = hook.referrerPending(id, creator);
        assertLt(owedCreator, FeastConstants.MAX_SETTLEMENT, "the creator alone fits inside one settlement");
        assertGt(owedCreator + owedReferral, FeastConstants.MAX_SETTLEMENT, "but the two together do not");

        FeastConverter.Hop[] memory route = new FeastConverter.Hop[](1);
        route[0] = FeastConverter.Hop({tokenOut: address(wbnb), fee: 500});
        vm.prank(creator);
        hook.claimAsBnb(key, creator, route, 0);

        uint256 paidReferral = FeastConstants.MAX_SETTLEMENT - owedCreator;
        assertEq(hook.creatorPending(id), 0, "the creator component was paid in full");
        assertEq(
            hook.referrerPending(id, creator),
            owedReferral - paidReferral,
            "and the referral kept exactly what the budget could not pay"
        );
    }
}
