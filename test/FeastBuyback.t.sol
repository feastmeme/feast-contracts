// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FeastConstants} from "../src/FeastConstants.sol";
import {FeastFactory} from "../src/FeastFactory.sol";
import {FeastHook} from "../src/FeastHook.sol";
import {FeastReferrals} from "../src/FeastReferrals.sol";
import {FeastFeeLedger} from "../src/FeastFeeLedger.sol";
import {FeastPlatformTokenDeployer} from "../src/FeastPlatformTokenDeployer.sol";
import {FeastOracle} from "../src/FeastOracle.sol";
import {FeastToken} from "../src/FeastToken.sol";
import {FeastVesting} from "../src/FeastVesting.sol";
import {Currency} from "../src/venue/Currency.sol";
import {IFeastCLPoolManager} from "../src/venue/IFeastCLPoolManager.sol";
import {PoolId, PoolIdLibrary} from "../src/venue/PoolId.sol";
import {PoolKey} from "../src/venue/PoolKey.sol";

import {Vault} from "infinity-core/src/Vault.sol";
import {CLPoolManager} from "infinity-core/src/pool-cl/CLPoolManager.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {Currency as UpCurrency} from "infinity-core/src/types/Currency.sol";

import {MockERC20, PausableMockERC20} from "./utils/MockERC20.sol";
import {PoolRouter} from "./utils/PoolRouter.sol";
import {VenueBridge} from "./utils/VenueBridge.sol";
import {CapWarm} from "./utils/CapWarm.sol";

import {FeastGuardian} from "../../../src/FeastGuardian.sol";
/// Anyone may press this, and pressing it buys the coin with fees the coin
/// itself earned and burns what it buys. The interesting assertions are the
/// bounds — a permissionless button with a tip attached is a standing invitation
/// unless it refuses at the right moments.
contract FeastBuybackTest is Test {
    using PoolIdLibrary for PoolKey;
    using VenueBridge for PoolKey;

    uint160 internal constant SQRT_PRICE_1_1 = 79_228_162_514_264_337_593_543_950_336;
    uint160 internal constant MIN_SQRT = 4_295_128_740;
    uint160 internal constant MAX_SQRT = 1_461_446_703_485_210_103_287_273_052_203_988_822_378_723_970_341;
    uint256 internal constant SUPPLY = 1_000_000_000e18;

    address internal creator = address(0xC0FFEE);
    address internal presser = address(0xBEEF01);
    address internal pauser = address(0xBADBAD);

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
    PausableMockERC20 internal quote;
    address internal coin;
    PoolKey internal key;

    uint256 internal clock;

    function setUp() public {
        clock = 1_000_000;
        vm.warp(clock);
        vault = new Vault();
        pm = new CLPoolManager(vault);
        vault.registerApp(address(pm));
        router = new PoolRouter(vault, pm);
        quote = new PausableMockERC20("Stock", "STKx", 18, pauser);

        // Before the nonce is read: every CREATE after this point shifts by one.
        guardian = new FeastGuardian(address(0x3517), address(this));
        // The referral registry (v1.6.26) has no constructor and no immutables, so
        // its deployed code is the whole of it: etched, it spends none of this
        // contract's nonce — under `isolate` even `deployCodeTo`'s constructor call
        // is a transaction that moves it — and every address below, the tokens' and
        // the platform coin's CREATE2 draw included, is the one it was before.
        referrals = FeastReferrals(address(uint160(uint256(keccak256("feast.referrals")))));
        vm.etch(address(referrals), vm.getDeployedCode("FeastReferrals.sol:FeastReferrals"));
        uint64 n = vm.getNonce(address(this));
        address predictedHook = vm.computeCreateAddress(address(this), n + 2);
        address predicted = vm.computeCreateAddress(address(this), n + 5);
        oracle = new FeastOracle(predictedHook);
        // A real ledger, never address(0): testing rule 2. It is written on
        // every accrual here, so a stub would let the recording call be
        // deleted unnoticed. (The converter stays unset: no test in this suite
        // reaches a conversion path, and `FeastAccountingTest` wires a real one
        // for the only path that does.)
        ledger = new FeastFeeLedger(predictedHook);
        hook = new FeastHook(address(pm), address(vault), predicted, address(oracle), address(ledger), address(0),
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
                referrerBps: 0,
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
        quote.mint(address(router), 100_000_000e18);
        // v1.6.15: the opening cap window opens at a pool's first SERVED
        // swap, so rolling past CAP_BLOCKS only clears a window that exists.
        CapWarm.arm(router, key.up(), address(quote), Currency.unwrap(key.currency0) == address(quote));
        vm.roll(vm.getBlockNumber() + FeastConstants.CAP_BLOCKS);
    }

    function _advance(uint32 s) internal {
        clock += s;
        vm.warp(clock);
    }

    function _trade(int256 amount) internal {
        bool zeroForOne = Currency.unwrap(key.currency0) == address(quote);
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

    /// `quoteIn` true buys the coin with quote; false sells the coin back.
    function _tradeOn(PoolKey memory k, int256 amount, bool quoteIn) internal {
        bool quoteIsCurrency0 = Currency.unwrap(k.currency0) == address(quote);
        bool zeroForOne = quoteIn ? quoteIsCurrency0 : !quoteIsCurrency0;
        router.swap(
            k.up(),
            ICLPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amount,
                sqrtPriceLimitX96: zeroForOne ? MIN_SQRT : MAX_SQRT
            }),
            ""
        );
    }

    /// A pool shallow enough that a permitted press cannot fill.
    ///
    /// Every other fixture here seeds from a billion-token supply, so a press
    /// worth a fraction of a percent of depth always fills whole and
    /// `quoteSpent` always equals what was offered. That made the distinction
    /// between offered and realised untestable — which is exactly the
    /// distinction round 6's H1 turned on. This coin has a thousand tokens, and
    /// the bucket is built by ROUND TRIPS so the fees accumulate without the
    /// price ending up anywhere but where it started.
    function _shallowPool() internal returns (address c, PoolKey memory k) {
        (c, k) = factory.create(
            FeastFactory.CreateParams({
                name: "Thin",
                symbol: "THIN",
                supply: 25e16,
                quote: address(quote),
                creator: creator,
                selfBurnBps: FeastConstants.DEFAULT_SELF_BURN_BPS,
                referrerBps: 0,
                prebuyQuoteIn: 0,
                minCoinsOut: 0,
                vestingDuration: 0,
                sqrtPriceX96: SQRT_PRICE_1_1,
                startTick: 0,
                liquidity: uint128(uint256(25e16) * 999 / 1_000),
                salt: bytes32(uint256(7)),
                metadataHash: bytes32(0)
            })
        );
        // v1.6.15: the opening cap window opens at a pool's first SERVED
        // swap, so rolling past CAP_BLOCKS only clears a window that exists.
        CapWarm.arm(router, k.up(), address(quote), Currency.unwrap(k.currency0) == address(quote));
        vm.roll(vm.getBlockNumber() + FeastConstants.CAP_BLOCKS);
        // Enough round-trip volume that the accrued bucket is large relative
        // to what this pool can fill in one press. The button's price limit is
        // 3% on the SQUARE-ROOT price — about 6% on price — so the allowance
        // has to exceed roughly 3% of the seeded liquidity before the venue
        // stops filling it whole.
        for (uint256 i = 0; i < 160; i++) {
            _advance(60);
            _tradeOn(k, -3e17, true);
            _advance(60);
            // Sell back from what the router actually holds: the buy paid a 1%
            // fee and the price drifts, so a fixed round number runs it dry.
            uint256 held = FeastToken(c).balanceOf(address(router));
            if (held > 1e12) _tradeOn(k, -int256(held * 9 / 10), false);
        }
        // Settle: let the time-weighted price catch up to where trading left
        // spot, so the button's own bound is not what refuses the press.
        for (uint256 i = 0; i < 6; i++) {
            _advance(300);
            _tradeOn(k, -1e12, true);
        }
    }

    /// Build up fees and enough oracle history for the bound to be readable.
    function _warmUp() internal {
        for (uint256 i = 0; i < 8; i++) {
            _advance(120);
            _trade(-100_000e18);
        }
    }

    // --- R2: a freeze is an idle hour, and nothing more --------------------

    /// **The fee allowance accrues through a freeze, and that is correct**
    /// (v1.6.15, coordinator ruling 4, accepting the residue with a proof
    /// rather than a severity judgement; `P16b` MEDIUM).
    ///
    /// `_accruedScaled` reads `block.timestamp - allowanceUpdatedAt`, wall time,
    /// and every path that SPENDS the allowance is frozen. So a freeze looks
    /// like it "replenishes spending capacity while every spending path is
    /// stopped" — the shape of every other finding in this release.
    ///
    /// It is not one, and the reason is an equivalence rather than an argument
    /// about severity: **a frozen hour and an idle hour are the same state.** No
    /// swap runs in either, so `selfBurnEarned` and `selfBurnUsed` do not move,
    /// so `pending` is the same number, so `min(cap, rate x elapsed)` is the
    /// same number. The freeze creates no state an idle pool cannot reach on its
    /// own, and the rate limiter's promise — that no bucket can be drained in
    /// one sandwichable swap — is exactly as strong after a freeze as after
    /// idleness.
    ///
    /// This pins the equivalence instead of arguing it: the same seventy-two
    /// hours, once frozen and once merely quiet, must leave the identical
    /// allowance and the identical first press.
    ///
    /// @dev What is NOT equivalent, and should not be: after a freeze the
    ///      button waits a full `TWAP_WINDOW` of OPEN time before it will read
    ///      the pool's average at all (v1.6.16). Both worlds here wait the same
    ///      window so the allowance comparison stays a comparison; the waiting
    ///      itself is asserted in the freeze-clock PoCs, not here.
    function test_aFrozenHourAndAnIdleHourLeaveTheSameAllowance() public {
        _warmUp();
        PoolId id = key.toId();

        uint256 snap = vm.snapshotState();

        // World A: seventy-two quiet hours. Nobody trades, nobody presses.
        // The extra averaging window is here so the two worlds see the SAME
        // elapsed time: world B has to wait one out after its freeze lifts,
        // because v1.6.16 will not let the button read an average that a freeze
        // rather than the market brought onto the spot.
        _advance(72 hours + FeastConstants.TWAP_WINDOW + 1);
        uint256 idleAllowance = hook.spendingAllowance(id);
        uint256 idlePending = hook.selfBurnPending(id);
        vm.prank(address(0xBEEF));
        hook.buyBackAndBurn(key, idleAllowance);
        uint256 idleSpent = idlePending - hook.selfBurnPending(id);

        vm.revertToState(snap);

        // World B: the same seventy-two hours with the brake down.
        vm.prank(address(0x3517));
        guardian.freeze();
        _advance(72 hours - 1);
        vm.prank(address(0x3517));
        guardian.unfreeze();
        _advance(1 + FeastConstants.TWAP_WINDOW + 1);
        uint256 frozenAllowance = hook.spendingAllowance(id);
        uint256 frozenPending = hook.selfBurnPending(id);
        vm.prank(address(0xBEEF));
        hook.buyBackAndBurn(key, frozenAllowance);
        uint256 frozenSpent = frozenPending - hook.selfBurnPending(id);

        // **The witness reaches its bound.** An allowance of zero, or a press
        // that spends nothing, would make both halves trivially equal.
        assertGt(idleAllowance, 0, "the idle world really accrued an allowance");
        assertGt(idleSpent, 0, "and the press really spent from the bucket");

        assertEq(frozenAllowance, idleAllowance, "a frozen hour accrued more than an idle one");
        assertEq(frozenPending, idlePending, "a frozen hour moved the bucket");
        assertEq(frozenSpent, idleSpent, "a frozen hour bought a larger first press");
    }

    // --- the happy path ---------------------------------------------------

    function test_pressingTheButtonBuysTheCoinAndBurnsIt() public {
        _warmUp();
        PoolId id = key.toId();
        uint256 pending = hook.selfBurnPending(id);
        assertGt(pending, 0, "there is something to spend");

        uint256 supplyBefore = FeastToken(coin).totalSupply();
        uint256 amount = hook.spendingAllowance(key.toId());

        vm.prank(presser);
        hook.buyBackAndBurn(key, amount);

        assertLt(FeastToken(coin).totalSupply(), supplyBefore, "supply really went down");
        assertEq(hook.selfBurnPending(id), pending - amount, "the bucket was debited by exactly what was spent");
        assertGt(FeastToken(coin).balanceOf(presser), 0, "the presser was tipped");
        assertEq(FeastToken(coin).balanceOf(address(hook)), 0, "the hook keeps none of the coin");
    }

    /// The tip is bounded by what the press produced, so it can never cost more
    /// than it creates.
    function test_theTipIsASliceOfWhatWasBoughtAndNoMore() public {
        _warmUp();
        uint256 supplyBefore = FeastToken(coin).totalSupply();
        uint256 amount = hook.selfBurnPending(key.toId()) / 10;

        vm.prank(presser);
        hook.buyBackAndBurn(key, amount);

        uint256 burned = supplyBefore - FeastToken(coin).totalSupply();
        uint256 tip = FeastToken(coin).balanceOf(presser);
        uint256 bought = burned + tip;
        assertEq(tip, bought * FeastConstants.TIP_BPS / FeastConstants.BPS, "the tip is its stated share of the buy");
        assertLt(tip, burned, "and the burn is the overwhelming majority of it");
    }

    /// I2 again, in the place it matters most: the buy-back settles its debt by
    /// burning vault claims, so it works even while the quote token is frozen.
    function test_aFrozenQuoteTokenDoesNotStopACoinBuyingItselfBack() public {
        _warmUp();
        uint256 amount = hook.selfBurnPending(key.toId()) / 10;

        vm.prank(pauser);
        quote.setPaused(true);

        uint256 supplyBefore = FeastToken(coin).totalSupply();
        vm.prank(presser);
        hook.buyBackAndBurn(key, amount);
        assertLt(FeastToken(coin).totalSupply(), supplyBefore, "the burn happened anyway");
    }

    /// The venue does not call a hook's callbacks when the hook is the swapper,
    /// so the buy-back pays no feast fee. Asserted rather than assumed, because
    /// the whole economics would be circular if it did.
    function test_theButtonsOwnSwapPaysNoFee() public {
        _warmUp();
        PoolId id = key.toId();
        uint256 accruedBefore = hook.poolInfo(id).accruedQuote;

        vm.prank(presser);
        hook.buyBackAndBurn(key, hook.selfBurnPending(id) / 10);

        assertEq(hook.poolInfo(id).accruedQuote, accruedBefore, "the buy-back did not charge itself a fee");
    }

    /// Round 1 H9. A press that buys nothing must not consume the hour. The
    /// venue's own fee rounding can swallow a one-wei input whole and return no
    /// coin at all; without this refusal that press succeeds, burns nothing, and
    /// locks out the honest press behind it — repeatable at every expiry for
    /// the price of gas.
    /// A press that buys nothing reverts, so it costs its sender gas and the
    /// protocol nothing: no allowance consumed, no bucket debited. Under the
    /// withdrawn design this mattered because such a press could occupy the
    /// hour; under an allowance it matters only that the protocol never pays
    /// quote for zero coin.
    function test_aPressThatBuysNothingIsRefusedAndCostsTheProtocolNothing() public {
        _warmUp();
        PoolId id = key.toId();
        uint256 allowanceBefore = hook.spendingAllowance(id);
        uint256 pendingBefore = hook.selfBurnPending(id);

        vm.expectRevert(FeastHook.BoughtNothing.selector);
        vm.prank(address(0xBAD));
        hook.buyBackAndBurn(key, 1);

        assertEq(hook.spendingAllowance(id), allowanceBefore, "no allowance was consumed");
        assertEq(hook.selfBurnPending(id), pendingBefore, "and no bucket was debited");

        // The hour was never started, so an honest press still works.
        uint256 amount = hook.selfBurnPending(key.toId()) / 10;
        vm.prank(presser);
        hook.buyBackAndBurn(key, amount);
        assertGt(FeastToken(coin).balanceOf(presser), 0, "the honest press went through");
    }

    /// Round 1 H6. A press stopped early by its own price limit must retire from
    /// the bucket exactly what the venue took, not what was asked for —
    /// otherwise the difference stays in vault claims that no bucket can reach.
    function test_aPartiallyFilledPressDebitsOnlyWhatItSpent() public {
        _warmUp();
        PoolId id = key.toId();
        uint256 pendingBefore = hook.selfBurnPending(id);
        uint256 request = pendingBefore / 10;

        uint256 claimsBefore = vault.balanceOf(address(hook), _upQuote());
        vm.prank(presser);
        hook.buyBackAndBurn(key, request);
        uint256 claimsSpent = claimsBefore - vault.balanceOf(address(hook), _upQuote());

        // Whatever the venue actually took is exactly what left the bucket.
        assertEq(pendingBefore - hook.selfBurnPending(id), claimsSpent, "bucket debit equals claims burned");
        assertLe(claimsSpent, request, "and never more than was asked for");
    }

    function _upQuote() internal view returns (UpCurrency) {
        return UpCurrency.wrap(address(quote));
    }

    /// The hook's own swap moves the price, and the venue does not call a
    /// hook's callbacks when the hook is the swapper — so unless the button
    /// observes explicitly, the move is invisible to the oracle and the next
    /// reader sees an average that skips it.
    function test_aButtonsOwnSwapIsObservedByTheOracle() public {
        _warmUp();
        PoolId id = key.toId();
        uint256 before_ = oracle.observationCount(id);

        _advance(60);
        vm.prank(presser);
        hook.buyBackAndBurn(key, hook.selfBurnPending(id) / 10);

        assertGt(oracle.observationCount(id), before_, "the press left an observation behind");
        (, int24 spot,,) = IFeastCLPoolManager(address(pm)).getSlot0(id);
        _advance(600);
        int24 avg = oracle.twapTick(id);
        int24 drift = avg > spot ? avg - spot : spot - avg;
        assertLt(drift, 50, "and the average reflects where the press left the price");
    }

    // --- what it refuses ---------------------------------------------------

    function test_pressingAnEmptyBucketIsRefused() public {
        vm.expectRevert(FeastHook.NothingToBuyBackWith.selector);
        vm.prank(presser);
        hook.buyBackAndBurn(key, 1);
    }

    /// The bound. Somebody moves the pool's price, then presses the button
    /// hoping the protocol will buy at their price. It will not.
    function test_aMovedSpotPriceStopsTheButton() public {
        _warmUp();

        // A large one-sided trade drags spot away from the average.
        _trade(-40_000_000e18);

        // Sized AFTER the trade, and comfortably above the progress floor, so
        // the oracle bound is what refuses this press and not the size rules.
        uint256 amount = hook.selfBurnPending(key.toId()) / 10;

        (, int24 spotTick,,) = IFeastCLPoolManager(address(pm)).getSlot0(key.toId());
        int24 avg = oracle.twapTick(key.toId());
        int24 dev = spotTick > avg ? spotTick - avg : avg - spotTick;
        assertGt(dev, FeastConstants.MAX_TICK_DEVIATION, "the fixture really moved the price");

        vm.expectRevert(abi.encodeWithSelector(FeastHook.SpotTooFarFromAverage.selector, spotTick, avg));
        vm.prank(presser);
        hook.buyBackAndBurn(key, amount);
    }

    /// A pool too young to have a time-weighted price has no bound to offer, so
    /// the button waits rather than guessing.
    ///
    /// Round 10 (r10b M2): this used to accept *any* revert, and a young pool
    /// has an empty allowance — so it was passing on `NothingToBuyBackWith`
    /// without ever reaching the oracle. It now presses an amount the allowance
    /// really permits and names the refusal it expects, so removing the age
    /// protection specifically for young pools could not leave it green.
    function test_aPoolWithNoPriceHistoryRefusesTheButton() public {
        _advance(10);
        _trade(-1_000_000e18);
        _advance(30); // enough for a positive allowance, nowhere near the oracle's floor

        PoolId id = key.toId();
        uint256 amount = hook.spendingAllowance(id);
        assertGt(amount, 0, "past the allowance gate, so the oracle is what refuses");
        assertLt(oracle.historySeconds(id), FeastConstants.MIN_OBSERVATION_AGE, "and the oracle really is too young");

        vm.prank(presser);
        (bool ok, bytes memory err) =
            address(hook).call(abi.encodeWithSelector(FeastHook.buyBackAndBurn.selector, key, amount));
        assertFalse(ok, "the press is refused");
        assertEq(bytes4(err), FeastOracle.OracleTooYoung.selector, "and refused by the oracle, by name");
    }

    // --- round 5 H3/M1: meaningful progress, and dust that can still be spent ---

    // --- the spending allowance (round 6: interval + floor withdrawn) ------

    /// The round-6 finding, and the reason the whole shape was withdrawn.
    ///
    /// Under interval-plus-floor, a press that cleared the floor but filled as
    /// dust still started the hour, so the productive press behind it was
    /// blocked — jamming for the price of gas. Under an allowance there is no
    /// hour to occupy: a dust press deducts dust, and the next press proceeds
    /// in the same block.
    function test_aDustPressDoesNotBlockTheProductivePressBehindIt() public {
        _warmUp();
        PoolId id = key.toId();
        uint256 allowanceBefore = hook.spendingAllowance(id);

        // A deliberately tiny press: it succeeds and costs its presser gas.
        vm.prank(address(0xBAD));
        hook.buyBackAndBurn(key, allowanceBefore / 10_000);

        // In the SAME block, the productive press goes through. Under the old
        // design this reverted with `TooSoonSinceLastBuyback`.
        uint256 burnedBefore = FeastToken(coin).totalSupply();
        // Hoisted: `vm.prank` binds to the next CALL, and a view call left in
        // the argument list would consume it — the press would then come from
        // this contract rather than from `presser`.
        uint256 rest = hook.spendingAllowance(id);
        vm.prank(presser);
        hook.buyBackAndBurn(key, rest);
        assertLt(FeastToken(coin).totalSupply(), burnedBefore, "the productive press was never blocked");
    }

    /// Nothing is "occupied", so a griefer cannot repeat the block at expiry
    /// either: what a dust press consumes is exactly what it spent.
    function test_aDustPressConsumesOnlyWhatItSpent() public {
        _warmUp();
        PoolId id = key.toId();
        uint256 allowanceBefore = hook.spendingAllowance(id);
        uint256 pendingBefore = hook.selfBurnPending(id);

        vm.prank(address(0xBAD));
        hook.buyBackAndBurn(key, allowanceBefore / 1_000);

        uint256 spent = pendingBefore - hook.selfBurnPending(id);
        assertGt(spent, 0, "it did spend something");
        assertApproxEqAbs(
            hook.spendingAllowance(id), allowanceBefore - spent, 1, "the allowance fell by exactly the realised spend"
        );
    }

    /// The allowance refills continuously rather than in a step at an hour
    /// boundary, and it is capped at one hour's worth.
    function test_theAllowanceRefillsContinuouslyAndIsCapped() public {
        _warmUp();
        PoolId id = key.toId();

        // Spend the whole of it.
        uint256 all = hook.spendingAllowance(id);
        vm.prank(presser);
        hook.buyBackAndBurn(key, all);
        assertLe(hook.spendingAllowance(id), 1, "spent down to nothing");

        uint256 cap = hook.selfBurnPending(id) * FeastConstants.ALLOWANCE_CAP_BPS / FeastConstants.BPS;

        // A quarter hour restores a quarter of an hour's ACCRUAL, which is not
        // a quarter of the cap: the rate (15%/h) and the cap (5%) are different
        // numbers on purpose, and their sum is the hourly bound.
        _advance(uint32(1 hours) / 4);
        uint256 perHour = hook.selfBurnPending(id) * FeastConstants.ALLOWANCE_BPS_PER_HOUR / FeastConstants.BPS;
        uint256 expected = perHour / 4 > cap ? cap : perHour / 4;
        assertApproxEqRel(hook.spendingAllowance(id), expected, 0.02e18, "a quarter hour restores a quarter of an hour");

        _advance(uint32(4 hours));
        assertApproxEqAbs(hook.spendingAllowance(id), cap, 1, "and it never exceeds one hour's worth");
    }

    /// The cap is what stops an idle pool banking allowance. A pool that
    /// pressed only a sliver and then sat still for days must not wake up able
    /// to spend days' worth in one print.
    function test_anIdlePoolDoesNotBankUnlimitedAllowance() public {
        _warmUp();
        PoolId id = key.toId();

        // Press a sliver, so most of the allowance is still unspent...
        uint256 sliver = hook.spendingAllowance(id) / 100;
        vm.prank(presser);
        hook.buyBackAndBurn(key, sliver);

        // ...then let a very long time pass on top of it.
        _advance(uint32(30 days));

        uint256 cap = hook.selfBurnPending(id) * FeastConstants.ALLOWANCE_CAP_BPS / FeastConstants.BPS;
        assertApproxEqAbs(hook.spendingAllowance(id), cap, 1, "unspent allowance plus accrual is still capped");
    }

    /// Tip farming: the tip is a fixed fraction of what the press actually
    /// bought, so a dust press earns dust. There is no flat component to farm.
    function test_dustPressesEarnDustAndCannotBeFarmed() public {
        _warmUp();
        PoolId id = key.toId();
        address farmer = address(0xFA47);

        uint256 big = hook.spendingAllowance(id);
        for (uint256 i = 0; i < 20; i++) {
            vm.prank(farmer);
            hook.buyBackAndBurn(key, big / 10_000);
        }
        uint256 farmed = FeastToken(coin).balanceOf(farmer);

        // One honest press of the remaining allowance, by someone else.
        uint256 rest = hook.spendingAllowance(id);
        vm.prank(presser);
        hook.buyBackAndBurn(key, rest);
        uint256 honest = FeastToken(coin).balanceOf(presser);

        assertGt(honest, farmed * 10, "twenty dust presses earn a small fraction of one real one");
    }

    /// Edge arithmetic. A bucket too small for the proportional allowance to
    /// round to anything is not rationed at all — the round-5 M1 shape, which
    /// the allowance must not reintroduce. Built deterministically from one
    /// tiny trade rather than arrived at by a loop, so the assertion always
    /// runs.
    function test_aBucketBelowOneUnitOfAllowanceIsNotRationed() public {
        PoolId id = key.toId();
        _advance(120);
        // 1% of this is the fee; half of that is the self-burn bucket.
        _trade(-2_000_000);

        uint256 pending = hook.selfBurnPending(id);
        assertGt(pending, 0, "a bucket exists");
        assertLe(pending, FeastConstants.MIN_RATIONED_BUCKET, "and it is below the rationing floor");

        _advance(uint32(1 hours));
        assertEq(hook.spendingAllowance(id), pending, "so the whole of it becomes available at once");
        uint256 rationed = pending * FeastConstants.ALLOWANCE_CAP_BPS / FeastConstants.BPS;
        assertLt(rationed, pending, "which is strictly more than the proportional share would allow");
    }

    function test_anEmptyBucketHasNoAllowanceAndIsRefused() public {
        PoolId id = key.toId();
        assertEq(hook.selfBurnPending(id), 0, "nothing has accrued yet");
        assertEq(hook.spendingAllowance(id), 0, "so there is nothing to spend");

        vm.expectRevert(FeastHook.NothingToBuyBackWith.selector);
        vm.prank(presser);
        hook.buyBackAndBurn(key, 1e18);
    }

    /// A request larger than the allowance is CLAMPED, not refused: the caller
    /// asks for what they want and gets what the allowance permits.
    function test_anOversizedRequestIsClampedToTheAllowance() public {
        _warmUp();
        PoolId id = key.toId();
        uint256 allowance = hook.spendingAllowance(id);
        uint256 pendingBefore = hook.selfBurnPending(id);

        vm.prank(presser);
        hook.buyBackAndBurn(key, pendingBefore);

        uint256 spent = pendingBefore - hook.selfBurnPending(id);
        assertLe(spent, allowance, "never more than the allowance");
        assertApproxEqRel(spent, allowance, 0.01e18, "and it did spend the allowance");
    }

    /// Round 6's H1, in the form only a shallow pool can show: the difference
    /// between what a press OFFERS and what it actually SPENDS.
    ///
    /// The withdrawn predicate checked the request and then settled the
    /// realised amount, so a press that cleared the floor and filled as dust
    /// still consumed the hour. The allowance must deduct the realised spend
    /// and nothing else — otherwise the same defect returns wearing a
    /// different mechanism.
    function test_aPartialFillConsumesOnlyWhatItActuallySpent() public {
        (, PoolKey memory k) = _shallowPool();
        PoolId id = k.toId();

        uint256 allowance = hook.spendingAllowance(id);
        uint256 pendingBefore = hook.selfBurnPending(id);
        assertGt(allowance, 0, "there is something to spend");

        vm.prank(presser);
        hook.buyBackAndBurn(k, allowance);

        uint256 spent = pendingBefore - hook.selfBurnPending(id);
        assertGt(spent, 0, "it spent something");
        assertLt(spent, allowance, "but the pool could not fill the whole offer");
        assertApproxEqAbs(
            hook.spendingAllowance(id), allowance - spent, 1, "and the allowance fell by the REALISED spend only"
        );
    }

    /// The stranding half of the same fixture. A realised-spend FLOOR — the
    /// repair round 6 proposed and this design rejected — would refuse every
    /// press here forever, because no press can fill its minimum. The allowance
    /// has no floor, so the bucket drains over time instead.
    function test_aShallowPoolsBucketStillDrainsOverTime() public {
        (, PoolKey memory k) = _shallowPool();
        PoolId id = k.toId();
        uint256 start = hook.selfBurnPending(id);

        for (uint256 i = 0; i < 12; i++) {
            uint256 a = hook.spendingAllowance(id);
            if (a == 0) break;
            vm.prank(presser);
            try hook.buyBackAndBurn(k, a) {} catch { break; }
            _advance(uint32(1 hours));
        }

        assertLt(hook.selfBurnPending(id), start, "the bucket is being spent, not stranded");
    }

    // --- round 7: the sliding-hour envelope --------------------------------

    /// Greedily press for a whole hour and measure what actually leaves.
    function _greedyHour(PoolKey memory k, uint32 step) internal returns (uint256 spent, uint256 startPending) {
        PoolId id = k.toId();
        startPending = hook.selfBurnPending(id);
        uint32 elapsed;
        while (elapsed < 3_600) {
            uint256 a = hook.spendingAllowance(id);
            if (a != 0) {
                uint256 before_ = hook.selfBurnPending(id);
                vm.prank(presser);
                try hook.buyBackAndBurn(k, a) {
                    spent += before_ - hook.selfBurnPending(id);
                } catch {}
            }
            _advance(step);
            elapsed += step;
        }
    }

    /// Round 7 (r7a H1 / r7b H1). Capping the AVAILABLE allowance never capped
    /// CUMULATIVE spending: a token bucket permits a burst AND a refill, which
    /// is what a token bucket is for. The withdrawn interval allowed at most
    /// one press per hour, so a half-open hour could carry 20% of the bucket
    /// and no more. That is the bound this must restore.
    ///
    /// It restores it by making the burst and the rate add up to it, rather
    /// than each being the whole of it: `ALLOWANCE_CAP_BPS + ALLOWANCE_BPS_PER_HOUR
    /// <= 20%`. Starting a fresh pool empty is necessary but nowhere near
    /// sufficient — an idled pool's allowance is full again within the hour.
    function test_atMostTwentyPercentLeavesInAnySlidingHour() public {
        _warmUp();
        _advance(uint32(2 hours)); // idle, so the allowance is as full as it ever gets

        (uint256 spent, uint256 start) = _greedyHour(key, 60);

        assertGt(spent, 0, "the button does work");
        assertLe(spent * 10_000 / start, 2_000, "no more than 20% of the bucket leaves in one hour");
    }

    /// The lenses' own thirty-minute construction: 200 then 80 on a bucket of
    /// 1,000 was 28%, where the withdrawn design allowed 20%.
    function test_theThirtyMinuteConstructionStaysUnderTheBound() public {
        _warmUp();
        _advance(uint32(2 hours));
        PoolId id = key.toId();
        uint256 start = hook.selfBurnPending(id);

        uint256 first = hook.spendingAllowance(id);
        vm.prank(presser);
        hook.buyBackAndBurn(key, first);

        _advance(1_800);
        uint256 second = hook.spendingAllowance(id);
        if (second != 0) {
            vm.prank(presser);
            hook.buyBackAndBurn(key, second);
        }

        uint256 spent = start - hook.selfBurnPending(id);
        assertLe(spent * 10_000 / start, 2_000, "half an hour cannot carry more than the hourly bound");
    }

    /// Option C: a fresh pool starts with nothing to press, and becomes usable
    /// as its allowance accrues.
    function test_aNewPoolHasNothingToPressUntilItsAllowanceAccrues() public {
        // Accrue a bucket without letting much time pass.
        _advance(60);
        _trade(-100_000e18);
        PoolId id = key.toId();
        assertGt(hook.selfBurnPending(id), 0, "there are fees");

        uint256 early = hook.spendingAllowance(id);
        uint256 cap = hook.selfBurnPending(id) * FeastConstants.ALLOWANCE_CAP_BPS / FeastConstants.BPS;
        assertLt(early, cap, "a new pool does not start with a full allowance");

        _advance(uint32(2 hours));
        assertApproxEqAbs(hook.spendingAllowance(id), cap, 2, "and it fills up as time passes");
    }

    /// Fees banked a moment before a press must not receive allowance for time
    /// during which they did not exist. Round 7's second defect: `_bank` moved
    /// the bucket without checkpointing, and accrual is computed against the
    /// CURRENT bucket, so new principal was credited retroactively.
    function test_feesBankedLaterDoNotReceiveRetroactiveAllowance() public {
        _warmUp();
        _advance(uint32(2 hours));
        PoolId id = key.toId();

        // Spend the allowance down, then idle nearly an hour on a small bucket.
        uint256 all = hook.spendingAllowance(id);
        vm.prank(presser);
        hook.buyBackAndBurn(key, all);
        _advance(3_599);

        uint256 beforeBank = hook.spendingAllowance(id);
        // Now bank a great deal more, in one trade, immediately before reading.
        _trade(-20_000_000e18);
        uint256 afterBank = hook.spendingAllowance(id);

        // The new principal has existed for zero seconds, so it may add
        // essentially nothing to the allowance.
        assertApproxEqAbs(afterBank, beforeBank, beforeBank / 100 + 1, "new fees accrue from now, not retroactively");
    }

    // --- round 8 -----------------------------------------------------------

    /// The bound is a named constant, and the two knobs that keep it must be
    /// checked against it rather than merely described in a comment. Round 8's
    /// queued item: `MAX_HOURLY_SPEND_BPS` existed only in prose, so either
    /// knob could be raised tomorrow without a single test objecting.
    function test_theBurstAndTheRateSumToTheHourlyBound() public pure {
        assertLe(
            uint256(FeastConstants.ALLOWANCE_CAP_BPS) + uint256(FeastConstants.ALLOWANCE_BPS_PER_HOUR),
            uint256(FeastConstants.MAX_HOURLY_SPEND_BPS),
            "a token bucket carries its capacity PLUS a window's refill, so the two must sum to the bound"
        );
    }

    /// Round 8 L2. Every checkpoint used to floor the accrual into whole quote
    /// units and reset the clock, so a stream of tiny fee credits could hold the
    /// allowance at zero for an hour, one rounded-away second at a time. The
    /// allowance is accumulated in fixed point now, so nothing is discarded.
    /// The same property at the scale where flooring actually bites: a bucket
    /// just above the rationing threshold accrues well under one raw unit per
    /// second, so whole-unit accumulation rounds every checkpoint to nothing.
    function test_aSmallBucketStillAccruesWhenBankedEverySecond() public {
        PoolId id = key.toId();
        _advance(120);
        _trade(-6_000_000); // a bucket just above MIN_RATIONED_BUCKET
        uint256 pending = hook.selfBurnPending(id);
        assertGt(pending, FeastConstants.MIN_RATIONED_BUCKET, "above the dust exemption, so it is rationed");

        // 505 units, not 200: at 200 the fee is one unit and its 20% self-burn
        // share rounds to ZERO, so `_bank` never checkpoints and the loop tests
        // nothing. Round 9 (M8) handed back this number after I had written the
        // fixture off as impossible — the diagnosis was right and the
        // conclusion was one step early.
        uint256 lastPending = hook.selfBurnPending(id);
        for (uint256 i = 0; i < 400; i++) {
            _advance(1);
            _trade(-505);
            uint256 nowPending = hook.selfBurnPending(id);
            assertGt(nowPending, lastPending, "each buy really does credit the bucket, forcing a checkpoint");
            lastPending = nowPending;
        }
        assertLe(lastPending, 24_000, "still below the size at which whole-unit per-second accrual is nonzero");

        assertGt(hook.spendingAllowance(id), 0, "four hundred seconds of accrual is not rounded away");
    }

    function test_frequentBankingDoesNotSuppressAccrual() public {
        _warmUp();
        PoolId id = key.toId();
        _advance(uint32(2 hours));
        uint256 all = hook.spendingAllowance(id);
        vm.prank(presser);
        hook.buyBackAndBurn(key, all);
        assertLe(hook.spendingAllowance(id), 1, "spent down to nothing");

        // An hour passes, but a small fee is banked every few seconds
        // throughout it — each one a checkpoint.
        for (uint256 i = 0; i < 600; i++) {
            _advance(6);
            _trade(-1_000);
        }

        uint256 cap = hook.selfBurnPending(id) * FeastConstants.ALLOWANCE_CAP_BPS / FeastConstants.BPS;
        assertApproxEqRel(
            hook.spendingAllowance(id), cap, 0.05e18, "an hour of accrual survives being checkpointed constantly"
        );
    }
}
