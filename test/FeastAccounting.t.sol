// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {FeastConstants} from "../src/FeastConstants.sol";
import {FeastFeeLedger} from "../src/FeastFeeLedger.sol";
import {FeastPlatformTokenDeployer} from "../src/FeastPlatformTokenDeployer.sol";
import {FeastFactory} from "../src/FeastFactory.sol";
import {FeastHook} from "../src/FeastHook.sol";
import {FeastReferrals} from "../src/FeastReferrals.sol";
import {FeastConverter} from "../src/FeastConverter.sol";
import {FeastOracle} from "../src/FeastOracle.sol";
import {FeastToken} from "../src/FeastToken.sol";
import {FeastVesting} from "../src/FeastVesting.sol";
import {Currency} from "../src/venue/Currency.sol";
import {PoolId, PoolIdLibrary} from "../src/venue/PoolId.sol";
import {PoolKey} from "../src/venue/PoolKey.sol";

import {Vault} from "infinity-core/src/Vault.sol";
import {CLPoolManager} from "infinity-core/src/pool-cl/CLPoolManager.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";

import {MockERC20} from "./utils/MockERC20.sol";
import {CapWarm} from "./utils/CapWarm.sol";
import {MockV3Factory, MockV3Pool} from "./utils/MockV3Pool.sol";
import {PoolRouter} from "./utils/PoolRouter.sol";
import {VenueBridge} from "./utils/VenueBridge.sol";

import {FeastGuardian} from "../../../src/FeastGuardian.sol";
/// The accounting class from audit round 1, tested as sequences.
///
/// Round 1's lesson was that a single-state assertion is evidence about a single
/// state. The conservation fuzz here checked one swap's derived identity and
/// stayed green while the creator's entitlement could fall below what had
/// already been paid — a defect that only exists across accrue → claim →
/// accrue. Every test in this file is a sequence or a property, and the epoch
/// ledger is really wired up rather than stubbed with a zero address.
contract FeastAccountingTest is Test {
    using PoolIdLibrary for PoolKey;
    using VenueBridge for PoolKey;

    uint160 internal constant SQRT_PRICE_1_1 = 79_228_162_514_264_337_593_543_950_336;
    uint160 internal constant MIN_SQRT = 4_295_128_740;
    uint160 internal constant MAX_SQRT = 1_461_446_703_485_210_103_287_273_052_203_988_822_378_723_970_341;
    uint256 internal constant SUPPLY = 1_000_000_000e18;

    address internal creator = address(0xC0FFEE);
    address internal referrer = address(0xEE01);
    address internal trader = address(0x7EADE1);

    Vault internal vault;
    CLPoolManager internal pm;
    PoolRouter internal router;
    FeastOracle internal oracle;
    FeastFeeLedger internal ledger;
    FeastGuardian internal guardian;
    FeastHook internal hook;
    FeastReferrals internal referrals;
    FeastVesting internal vesting;
    FeastFactory internal factory;
    MockERC20 internal quote;
    MockERC20 internal wbnb;
    FeastConverter internal converter;
    MockV3Factory internal v3Factory;
    MockV3Pool internal routePool;
    address internal coin;
    PoolKey internal key;

    uint256 internal clock;
    uint256 internal _saltNonce;

    function setUp() public {
        clock = 10 * FeastConstants.EPOCH_LENGTH;
        vm.warp(clock);

        vault = new Vault();
        pm = new CLPoolManager(vault);
        vault.registerApp(address(pm));
        router = new PoolRouter(vault, pm);
        quote = new MockERC20("Stock", "STK", 18);
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

        // A real converter, never address(0): testing rule 2. `claimAsBnb` is
        // the only converter path that ships in v1, so a fixture that stubbed
        // it out would let its route-authority refusal be deleted unnoticed.
        v3Factory = new MockV3Factory();
        routePool = new MockV3Pool(address(quote), address(wbnb));
        oracle = new FeastOracle(predictedHook);
        converter = new FeastConverter(address(v3Factory), address(wbnb), predictedHook);
        // Really wired too, for the same reason: with the ledger stubbed out,
        // deleting the recording call would leave this green.
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
        assertEq(address(hook), predictedHook, "hook wiring");
        assertEq(address(factory), predictedFactory, "factory wiring");

        v3Factory.set(address(quote), address(wbnb), 500, address(routePool));
        routePool.setOldestTimestamp(uint32(block.timestamp - 3_600));
        routePool.setTicks(0, 0);
        routePool.setOutputBps(10_000);
        wbnb.mint(address(routePool), 1_000_000e18);

        _create(FeastConstants.DEFAULT_SELF_BURN_BPS, FeastConstants.DEFAULT_REFERRER_BPS);
    }

    function _create(uint16 selfBurnBps, uint16 referrerBps) internal {
        (coin, key) = factory.create(
            FeastFactory.CreateParams({
                name: "Coin",
                symbol: "COIN",
                supply: SUPPLY,
                quote: address(quote),
                creator: creator,
                selfBurnBps: selfBurnBps,
                referrerBps: referrerBps,
                prebuyQuoteIn: 0,
                minCoinsOut: 0,
                vestingDuration: 0,
                sqrtPriceX96: SQRT_PRICE_1_1,
                startTick: 0,
                liquidity: uint128(SUPPLY * 999 / 1_000),
                // A per-call nonce, or two fuzz runs drawing the same share pair
                // collide on CREATE2 — a latent flake, since fuzz state persists
                // across runs and the seed changes every invocation.
                salt: keccak256(abi.encode(selfBurnBps, referrerBps, _saltNonce++)),
                metadataHash: bytes32(0)
            })
        );
        quote.mint(address(router), 500_000_000e18);
        // v1.6.15: the opening cap window opens at a pool's first SERVED
        // swap, so rolling past CAP_BLOCKS only clears a window that exists.
        CapWarm.arm(router, key.up(), address(quote), Currency.unwrap(key.currency0) == address(quote));
        vm.roll(vm.getBlockNumber() + FeastConstants.CAP_BLOCKS);
    }

    function _buy(int256 amount, bytes memory hookData) internal {
        bool zeroForOne = Currency.unwrap(key.currency0) == address(quote);
        vm.prank(trader, trader);
        router.swap(
            key.up(),
            ICLPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amount,
                sqrtPriceLimitX96: zeroForOne ? MIN_SQRT : MAX_SQRT
            }),
            hookData
        );
    }

    function _totalBuckets(PoolId id) internal view returns (uint256) {
        FeastHook.Pool memory p = hook.poolInfo(id);
        return p.selfBurnEarned + p.platformEarned + p.creatorEarned + p.referrerEarned;
    }

    // --- the sequence that broke round 1 ---------------------------------

    /// Four raw units accrue: the self-burn and platform shares each floor to
    /// zero, so the creator is owed all four. Claim them. One more unit
    /// accrues: under the old derived arithmetic the creator's *cumulative*
    /// entitlement fell to three, three minus four underflowed, and every
    /// future claim reverted for good.
    function test_theInterleavedSequenceThatBrokeRoundOne() public {
        _buy(-404, "");
        PoolId id = key.toId();
        uint256 owed = hook.creatorPending(id);
        assertGt(owed, 0, "the creator is owed the dust");

        hook.claimCreator(key);
        assertEq(hook.creatorPending(id), 0, "and takes it");

        _buy(-101, "");
        // The claim below is the one that used to revert permanently.
        uint256 after_ = hook.creatorPending(id);
        hook.claimCreator(key);
        assertGe(after_, 0, "entitlement stayed reachable");
        assertEq(hook.creatorPending(id), 0, "and settles again");
    }

    /// The general property: a bucket's earned total only ever grows, so
    /// `earned - paid` cannot underflow however accrual and withdrawal
    /// interleave.
    function testFuzz_entitlementNeverDecreasesAcrossInterleavedClaims(uint16[8] calldata raw) public {
        PoolId id = key.toId();
        uint256 lastCreatorEarned;
        uint256 lastSelfBurnEarned;

        for (uint256 i = 0; i < raw.length; i++) {
            uint256 size = bound(uint256(raw[i]), 101, 60_000);
            _buy(-int256(size), i % 3 == 0 ? abi.encode(referrer) : bytes(""));

            FeastHook.Pool memory p = hook.poolInfo(id);
            assertGe(p.creatorEarned, lastCreatorEarned, "creator earned never falls");
            assertGe(p.selfBurnEarned, lastSelfBurnEarned, "self-burn earned never falls");
            lastCreatorEarned = p.creatorEarned;
            lastSelfBurnEarned = p.selfBurnEarned;

            // Claiming mid-sequence is the part the old snapshot test never did.
            if (i % 2 == 1) {
                hook.claimCreator(key);
                assertEq(hook.creatorPending(id), 0, "a claim always settles to zero");
            }
        }
    }

    /// Conservation, across a whole sequence rather than at one instant: every
    /// wei taken as a fee is banked in exactly one bucket.
    function testFuzz_everyWeiTakenIsBankedInExactlyOneBucket(uint16[6] calldata raw, uint16 x, uint16 y) public {
        _create(uint16(bound(x, 0, FeastConstants.MAX_SELF_BURN_BPS)), uint16(bound(y, 0, FeastConstants.MAX_REFERRER_BPS)));
        PoolId id = key.toId();

        for (uint256 i = 0; i < raw.length; i++) {
            _buy(-int256(bound(uint256(raw[i]), 101, 90_000)), i % 2 == 0 ? abi.encode(referrer) : bytes(""));
            assertEq(_totalBuckets(id), hook.poolInfo(id).accruedQuote, "buckets are the whole fee, at every step");
        }
    }

    // --- realised amounts, not requested ---------------------------------

    /// R18. With a binding price limit the venue fills only part of the trade.
    /// Where the quote is the specified currency the fee could only have been
    /// computed on the request, so the trade is refused rather than mispriced;
    /// where it is unspecified the fee comes from realised deltas and the trade
    /// proceeds. Either way, nobody is charged for a trade that did not happen.
    function testFuzz_aPartialFillIsEitherRefusedOrChargedOnWhatFilled(uint96 rawSize, bool exactIn) public {
        uint256 size = bound(uint256(rawSize), 1e18, 5_000_000e18);
        PoolId id = key.toId();
        uint256 before_ = hook.poolInfo(id).accruedQuote;

        bool zeroForOne = Currency.unwrap(key.currency0) == address(quote);
        // A limit close to spot, so the venue stops early on any size.
        (uint160 spot,,,) = _slot0(id);
        uint160 limit = zeroForOne
            ? uint160(uint256(spot) * 9_999 / 10_000)
            : uint160(uint256(spot) * 10_001 / 10_000);

        uint256 quoteBefore = quote.balanceOf(address(router));
        vm.prank(trader, trader);
        try router.swap(
            key.up(),
            ICLPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: exactIn ? -int256(size) : int256(size),
                sqrtPriceLimitX96: limit
            }),
            ""
        ) {
            uint256 fee = hook.poolInfo(id).accruedQuote - before_;
            uint256 quoteMoved = quoteBefore > quote.balanceOf(address(router))
                ? quoteBefore - quote.balanceOf(address(router))
                : quote.balanceOf(address(router)) - quoteBefore;
            // Whatever filled, the fee is a hair over 1% of the quote that
            // actually moved — never a fraction of a request that did not.
            assertLe(fee * 50, quoteMoved + 1, "fee is at most ~2% of the quote that actually moved");
        } catch {
            // Refused. Nothing was banked for a trade that did not happen.
            assertEq(hook.poolInfo(id).accruedQuote, before_, "a refused trade accrues nothing");
        }
    }

    // --- the locked position's own fees ----------------------------------

    /// Q8 ruled this and round 1 found it absent: the position that can never
    /// be withdrawn was also earning trading fees nobody could reach. A
    /// zero-delta liquidity change collects them without touching principal.
    function test_theLockedPositionsFeesAreCollectableIntoTheSameBuckets() public {
        PoolId id = key.toId();
        for (uint256 i = 0; i < 4; i++) {
            clock += 60;
            vm.warp(clock);
            _buy(-2_000_000e18, "");
        }

        uint256 accruedBefore = hook.poolInfo(id).accruedQuote;
        uint256 bucketsBefore = _totalBuckets(id);

        // Anyone may press it.
        vm.prank(address(0xBEEF01));
        hook.collectLpFees(key);

        uint256 collected = hook.poolInfo(id).accruedQuote - accruedBefore;
        assertGt(collected, 0, "the position had earned something and it came back");
        assertEq(_totalBuckets(id), bucketsBefore + collected, "split by the same rule as a swap fee");
        assertEq(_totalBuckets(id), hook.poolInfo(id).accruedQuote, "and conservation still holds");
    }

    /// Ruling: LP fees are earned continuously and the venue reports only a
    /// total at collection, so there is no epoch to tag them with. Round 2:
    /// tagging them with the epoch of *collection* let anyone wait for a day on
    /// which they were the only fee payer and take a share funded by everybody
    /// else. So the platform share of LP fees is withdrawn from the pot and
    /// buys and burns instead — a stated boundary rather than a guessed
    /// attribution.
    function test_lpFeesNeverEnterAnEpochPot() public {
        PoolId id = key.toId();
        for (uint256 i = 0; i < 4; i++) {
            clock += 60;
            vm.warp(clock);
            _buy(-2_000_000e18, "");
        }

        uint256 week = ledger.currentWeek();
        FeastFeeLedger.Credit memory before = ledger.totals(week, address(quote));
        uint256 platformBefore = hook.platformPending(id);
        uint256 burnBefore = hook.selfBurnPending(id);
        vm.recordLogs();
        hook.collectLpFees(key);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            // v1.6 (Q24): a collection is not a trade.
            assertTrue(logs[i].topics.length == 0 || logs[i].topics[0] != FeastHook.Trade.selector, "no Trade event");
        }

        assertEq(hook.platformPending(id), platformBefore, "no LP fee reached the platform bucket");
        assertGt(hook.selfBurnPending(id), burnBefore, "it went to buy-and-burn instead");
        // v1.6: nor does an LP fee reach the weekly ledger — it has no payer.
        FeastFeeLedger.Credit memory after_ = ledger.totals(week, address(quote));
        assertEq(after_.paid, before.paid, "no payer is credited with an LP fee");
        assertEq(after_.earned, before.earned, "nor any creator");
    }

    /// Collecting must never remove principal — the lock is the product's
    /// central promise and this is the one liquidity call left open.
    function test_collectingFeesLeavesThePositionIntact() public {
        PoolId id = key.toId();
        clock += 60;
        vm.warp(clock);
        _buy(-2_000_000e18, "");

        uint128 before_ = IFeastCLPoolManagerLike2(address(pm)).getLiquidity(id);
        hook.collectLpFees(key);
        assertEq(IFeastCLPoolManagerLike2(address(pm)).getLiquidity(id), before_, "principal untouched");
    }

    function test_collectingBeforeAnythingIsSeededIsRefused() public {
        MockERC20 q = new MockERC20("Other", "OTH", 18);
        PoolKey memory unseeded = PoolKey({
            currency0: Currency.wrap(address(q)),
            currency1: Currency.wrap(address(uint160(address(q)) + 1)),
            hooks: address(hook),
            poolManager: address(pm),
            fee: FeastConstants.POOL_LP_FEE,
            parameters: hook.poolParameters()
        });
        vm.expectRevert(FeastHook.NothingSeeded.selector);
        hook.collectLpFees(unseeded);
    }

    // --- the oracle, fed by the hook ------------------------------------

    /// Round 1 M5/H3. The oracle attributes each recorded tick FORWARD, to the
    /// interval until the next write, so what it must be handed is the tick
    /// that prevails from that moment — the post-swap one. Fed the pre-swap
    /// tick instead, it reports a price the market left behind, for a window in
    /// which it did not hold.
    ///
    /// The oracle's own tests hand it correctly-timed ticks by construction, so
    /// they cannot see this. Only the integration can.
    function test_theOracleReportsThePriceThatActuallyPrevailed() public {
        PoolId id = key.toId();

        // Settle at a price, then move it decisively and stop trading.
        _buy(-1_000e18, "");
        clock += 60;
        vm.warp(clock);
        _buy(-40_000_000e18, "");

        (, int24 tickAfterTheMove,,) = _slot0(id);
        assertTrue(tickAfterTheMove != 0, "the fixture really moved the price");

        // Ten quiet minutes at that price.
        clock += 600;
        vm.warp(clock);

        // The average over those ten minutes is the price the market was
        // actually at, not the one it left.
        int24 average = oracle.twapTick(id);
        int24 drift = average > tickAfterTheMove ? average - tickAfterTheMove : tickAfterTheMove - average;
        assertLt(drift, 50, "the average is the price that prevailed, not the one before it");
    }

    function _slot0(PoolId id) internal view returns (uint160, int24, uint24, uint24) {
        return IFeastCLPoolManagerLike(address(pm)).getSlot0(id);
    }

    // --- the weekly ledger, really wired ---------------------------------

    /// Fees are recorded against the week that paid them. Round 1's lesson,
    /// carried into v1.6: crediting any later moment would let a later trader
    /// take an earlier week's emission.
    function test_feesAreRecordedAgainstTheWeekThatPaidThem() public {
        uint256 week = ledger.currentWeek();
        _buy(-100_000e18, "");

        uint256 paid = ledger.credit(week, address(quote), trader).paid;
        assertGt(paid, 0, "the trader is on the ledger for this week");
        assertEq(ledger.totals(week, address(quote)).paid, paid, "and is its whole denominator");
        assertGt(hook.platformPending(key.toId()), 0, "the platform share was banked");

        clock += 7 days;
        vm.warp(clock);
        assertEq(ledger.totals(ledger.currentWeek(), address(quote)).paid, 0, "and the next week starts empty");
    }

    /// Deleting the hook's recording call must not leave this suite green —
    /// which it would have, in every fixture that stubbed the ledger out.
    function test_theLedgerIsActuallyConnected() public {
        assertEq(address(hook.ledger()), address(ledger), "not a zero address");
        uint256 week = ledger.currentWeek();
        _buy(-50_000e18, "");
        assertGt(ledger.totals(week, address(quote)).paid, 0, "and the hook writes to it");
    }

    // --- round 8: the checkpoint must cover EVERY credit to the bucket -----

    /// Round 8 M1, both lenses: a surviving piece of round 7's second defect.
    ///
    /// `_bank` decided whether to checkpoint by looking at its local `selfBurn`
    /// share alone — but LP income redirects the PLATFORM share into the same
    /// bucket a few lines later. A pool with `selfBurnBps = 0` therefore grew
    /// its self-burn bucket with no checkpoint at all, and the allowance was
    /// then computed against elapsed time the new principal had never lived
    /// through. The decision has to be made on the COMPLETE credit.
    function test_lpIncomeRedirectedIntoTheBucketDoesNotArriveWithAllowance() public {
        // A pool that takes no self-burn share from swaps, so the only thing
        // that ever credits its self-burn bucket is redirected LP income.
        _create(0, 0);
        PoolId id = key.toId();

        for (uint256 i = 0; i < 4; i++) {
            clock += 60;
            vm.warp(clock);
            _buy(-2_000_000e18, "");
        }
        assertEq(hook.selfBurnPending(id), 0, "swaps credit this pool's self-burn bucket with nothing");

        // A long idle period, during which the bucket is still empty.
        clock += 3_599;
        vm.warp(clock);

        vm.prank(address(0xBEEF01));
        hook.collectLpFees(key);

        assertGt(hook.selfBurnPending(id), 0, "LP income did land in the self-burn bucket");
        assertEq(
            hook.spendingAllowance(id),
            0,
            "and it arrives with no allowance: it has existed for zero seconds"
        );
    }

    /// The same principal, an hour later, is spendable — the checkpoint must
    /// start the clock, not stop it.
    function test_redirectedLpIncomeAccruesAllowanceFromWhenItArrives() public {
        _create(0, 0);
        PoolId id = key.toId();
        for (uint256 i = 0; i < 4; i++) {
            clock += 60;
            vm.warp(clock);
            _buy(-2_000_000e18, "");
        }
        vm.prank(address(0xBEEF01));
        hook.collectLpFees(key);

        uint256 pending = hook.selfBurnPending(id);
        clock += 3_600;
        vm.warp(clock);

        uint256 cap = pending * FeastConstants.ALLOWANCE_CAP_BPS / FeastConstants.BPS;
        assertApproxEqAbs(hook.spendingAllowance(id), cap, 2, "an hour later it is fully accrued");
    }

    // --- the one converter path that ships in v1 --------------------------

    /// The route belongs to whoever bears the loss from it.
    ///
    /// This is why `claimAsBnb` survives the v1 cut while the platform buttons
    /// do not. Round 5's H1 — an attacker supplying their own mature pools to
    /// take valuable quote and leave negligible native — is a finding about
    /// spending the PROTOCOL's money along a route the protocol did not choose.
    /// Here the person choosing the route is the person whose claim it is, and
    /// nobody else may choose for them. See `docs/plan.md` §3, I15.
    function test_onlyTheClaimantMayChooseTheirOwnConversionRoute() public {
        _buy(-50_000e18, "");
        FeastConverter.Hop[] memory route = new FeastConverter.Hop[](1);
        route[0] = FeastConverter.Hop({tokenOut: address(wbnb), fee: 500});

        vm.prank(address(0xBADBAD));
        vm.expectRevert(abi.encodeWithSelector(FeastHook.RouteIsTheClaimantsToChoose.selector, creator));
        hook.claimAsBnb(key, creator, route, 0);
    }

    /// And the claimant's own call goes through, delivering to the claimant.
    function test_aClaimantMayTakeTheirOwnClaimInTheChainsAsset() public {
        _buy(-50_000e18, "");
        FeastConverter.Hop[] memory route = new FeastConverter.Hop[](1);
        route[0] = FeastConverter.Hop({tokenOut: address(wbnb), fee: 500});

        uint256 owed = hook.claimable(key, creator);
        assertGt(owed, 0, "the creator is owed something to convert");

        vm.prank(creator);
        uint256 out = hook.claimAsBnb(key, creator, route, 0);

        assertGt(out, 0, "converted");
        assertEq(wbnb.balanceOf(creator), out, "and delivered to the claimant, not the caller");
        assertEq(hook.claimable(key, creator), 0, "settled exactly once");
    }
}

interface IFeastCLPoolManagerLike2 {
    function getLiquidity(PoolId id) external view returns (uint128);
}

interface IFeastCLPoolManagerLike {
    function getSlot0(PoolId id) external view returns (uint160, int24, uint24, uint24);
}
