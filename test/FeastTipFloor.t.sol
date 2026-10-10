// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {FeastConstants} from "../src/FeastConstants.sol";
import {FeastFactory} from "../src/FeastFactory.sol";
import {FeastFeeLedger} from "../src/FeastFeeLedger.sol";
import {FeastGenesis} from "../src/FeastGenesis.sol";
import {FeastGuardian} from "../src/FeastGuardian.sol";
import {FeastHook} from "../src/FeastHook.sol";
import {FeastReferrals} from "../src/FeastReferrals.sol";
import {FeastOracle} from "../src/FeastOracle.sol";
import {FeastPlatformTokenDeployer} from "../src/FeastPlatformTokenDeployer.sol";
import {FeastToken} from "../src/FeastToken.sol";
import {FeastVesting} from "../src/FeastVesting.sol";
import {Currency} from "../src/venue/Currency.sol";
import {PoolId, PoolIdLibrary} from "../src/venue/PoolId.sol";
import {PoolKey} from "../src/venue/PoolKey.sol";
import {DeployPackage1} from "../script/DeployPackage1.s.sol";

import {Vault} from "infinity-core/src/Vault.sol";
import {CLPoolManager} from "infinity-core/src/pool-cl/CLPoolManager.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";

import {CapWarm} from "./utils/CapWarm.sol";
import {MockERC20} from "./utils/MockERC20.sol";
import {PoolRouter} from "./utils/PoolRouter.sol";
import {VenueBridge} from "./utils/VenueBridge.sol";

/// The buy-back button's tip floor (v1.6.23, task 675; `plans/675/ruling.md`).
///
/// A press is tipped `coinOut × max(TIP_BPS, min(floor ÷ largest, TIP_CEILING_BPS))`,
/// where `largest` is `ALLOWANCE_CAP_BPS` of the bucket before the press and
/// `floor` is the quote's row in the table the hook is built with. One hook,
/// three pools: wrapped native (listed at `TIP_FLOOR_NATIVE`), a stock (listed
/// at the amount of it worth 0.0005 BNB) and a quote nobody listed.
///
/// Every bucket here is built by BUYS only, so the internal fill (which spends
/// the same allowance on exact-input sales) never touches it; a buy banks 20% of
/// its 1% fee, 0.2% of the quote it spends. Every press is checked against the
/// event it emits: the event's tip is the coin the presser received, and its
/// burn is the supply that left.
contract FeastTipFloorTest is Test {
    using PoolIdLibrary for PoolKey;
    using VenueBridge for PoolKey;

    uint160 internal constant SQRT_PRICE_1_1 = 79_228_162_514_264_337_593_543_950_336;
    uint160 internal constant MIN_SQRT = 4_295_128_740;
    uint160 internal constant MAX_SQRT = 1_461_446_703_485_210_103_287_273_052_203_988_822_378_723_970_341;
    uint256 internal constant SUPPLY = 1_000_000_000e18;

    /// The wrapped-native row: 0.0005 BNB.
    uint256 internal constant F = FeastConstants.TIP_FLOOR_NATIVE;
    /// The stock row: the amount of the stock worth 0.0005 BNB at deploy. The
    /// fixture prices the stock at 0.25 BNB, so its row is 0.002 of it — four
    /// times the wrapped-native row in raw units, which is what lets the stock
    /// test tell the two rows apart.
    uint256 internal constant STOCK_FLOOR = 0.002e18;

    address internal creator = address(0xC0FFEE);
    address internal presser = address(0xBEEF01);

    Vault internal vault;
    CLPoolManager internal pm;
    PoolRouter internal router;
    FeastGuardian internal guardian;
    FeastOracle internal oracle;
    FeastFeeLedger internal ledger;
    FeastHook internal hook;
    FeastReferrals internal referrals;
    FeastVesting internal vesting;
    FeastFactory internal factory;

    MockERC20 internal wbnb;
    MockERC20 internal stock;
    MockERC20 internal unlisted;

    address internal coinW;
    PoolKey internal keyW;
    address internal coinS;
    PoolKey internal keyS;
    address internal coinU;
    PoolKey internal keyU;

    uint256 internal clock;

    function setUp() public {
        clock = 1_000_000;
        vm.warp(clock);
        vault = new Vault();
        pm = new CLPoolManager(vault);
        vault.registerApp(address(pm));
        router = new PoolRouter(vault, pm);
        wbnb = new MockERC20("Wrapped BNB", "WBNB", 18);
        stock = new MockERC20("Stock", "STKx", 18);
        unlisted = new MockERC20("Unlisted", "UNL", 18);

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
        address predictedFactory = vm.computeCreateAddress(address(this), n + 5);
        oracle = new FeastOracle(predictedHook);
        ledger = new FeastFeeLedger(predictedHook);
        hook = new FeastHook(
            address(pm), address(vault), predictedFactory, address(oracle), address(ledger), address(0),
            address(guardian), address(referrals), _table()
        );
        vesting = new FeastVesting(predictedFactory, address(guardian));
        FeastPlatformTokenDeployer deployer = new FeastPlatformTokenDeployer(predictedFactory);
        factory = new FeastFactory(
            address(pm), address(vault), address(hook), address(vesting), address(deployer), address(wbnb), address(this)
        );
        assertEq(address(factory), predictedFactory, "fixture wiring");

        (coinW, keyW) = _create(address(wbnb), 1);
        (coinS, keyS) = _create(address(stock), 2);
        (coinU, keyU) = _create(address(unlisted), 3);
        vm.roll(vm.getBlockNumber() + FeastConstants.CAP_BLOCKS);
    }

    // --- the table --------------------------------------------------------

    function _table() internal view returns (FeastHook.TipFloor[] memory rows) {
        rows = new FeastHook.TipFloor[](2);
        rows[0] = FeastHook.TipFloor({quote: address(wbnb), floor: F});
        rows[1] = FeastHook.TipFloor({quote: address(stock), floor: STOCK_FLOOR});
    }

    function _deploy(FeastHook.TipFloor[] memory rows) internal returns (FeastHook) {
        return new FeastHook(
            address(pm), address(vault), address(factory), address(oracle), address(ledger), address(0),
            address(guardian), address(referrals), rows
        );
    }

    /// The table has no getter (ruling 5: its 66 bytes are the hook's margin),
    /// so the deploying transaction's events ARE the record: one per row, from
    /// the hook, in order.
    function test_theTableIsAnnouncedRowByRowWhenTheHookIsBuilt() public {
        vm.recordLogs();
        FeastHook h = _deploy(_table());
        Vm.Log[] memory logs = vm.getRecordedLogs();

        uint256 rows;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] != FeastHook.TipFloorListed.selector) continue;
            assertEq(logs[i].emitter, address(h), "the hook announces its own rows");
            address quote = address(uint160(uint256(logs[i].topics[1])));
            uint256 floor = abi.decode(logs[i].data, (uint256));
            if (rows == 0) {
                assertEq(quote, address(wbnb), "row 0 is wrapped native");
                assertEq(floor, F, "at 0.0005 BNB");
            } else {
                assertEq(quote, address(stock), "row 1 is the stock");
                assertEq(floor, STOCK_FLOOR, "at its own row");
            }
            rows++;
        }
        assertEq(rows, 2, "one event per row, no more");
    }

    /// A zero floor lists a quote that is not floored; a floor above 128 bits
    /// could overflow `coinOut * floor` at the tip site and refuse every press of
    /// that quote. Both refused by name, and the largest admitted floor deploys.
    function test_aFloorOfZeroOrOver128BitsIsRefused() public {
        FeastHook.TipFloor[] memory rows = new FeastHook.TipFloor[](1);
        rows[0] = FeastHook.TipFloor({quote: address(wbnb), floor: 0});
        vm.expectRevert(abi.encodeWithSelector(FeastHook.TipFloorOutOfBounds.selector, address(wbnb), 0));
        _deploy(rows);

        uint256 tooBig = uint256(type(uint128).max) + 1;
        rows[0].floor = tooBig;
        vm.expectRevert(abi.encodeWithSelector(FeastHook.TipFloorOutOfBounds.selector, address(wbnb), tooBig));
        _deploy(rows);

        rows[0].floor = type(uint128).max;
        _deploy(rows);
    }

    function test_aQuoteListedTwiceIsRefused() public {
        FeastHook.TipFloor[] memory rows = new FeastHook.TipFloor[](2);
        rows[0] = FeastHook.TipFloor({quote: address(wbnb), floor: F});
        rows[1] = FeastHook.TipFloor({quote: address(wbnb), floor: 2 * F});
        vm.expectRevert(abi.encodeWithSelector(FeastHook.TipFloorListedTwice.selector, address(wbnb)));
        _deploy(rows);
    }

    /// The deploy script lists wrapped native at the native floor, then every
    /// stock row of the genesis table — which is empty until the owner fills it.
    function test_theDeployScriptListsWrappedNativeAtTheNativeFloor() public {
        FeastHook.TipFloor[] memory rows = new DeployPackage1().tipFloors();
        (address[] memory stocks,) = FeastGenesis.tipFloors();
        assertEq(rows.length, stocks.length + 1, "the native row, then the genesis table");
        assertEq(rows[0].quote, FeastGenesis.WRAPPED_NATIVE, "row 0 is wrapped native");
        assertEq(rows[0].floor, 0.0005 ether, "at 0.0005 BNB");
    }

    // --- the constants ------------------------------------------------------

    /// The tip site divides by `BPS / ALLOWANCE_CAP_BPS` and `BPS / TIP_CEILING_BPS`,
    /// which are the rule's quotients only while both divide `BPS`.
    function test_theTipsConstantsAreTheRuledOnes() public pure {
        assertEq(FeastConstants.TIP_BPS, 25, "0.25%, as before");
        assertEq(FeastConstants.TIP_CEILING_BPS, 1_000, "10%");
        assertEq(FeastConstants.TIP_FLOOR_NATIVE, 0.0005 ether, "0.0005 BNB");
        assertEq(uint256(FeastConstants.BPS) % FeastConstants.ALLOWANCE_CAP_BPS, 0, "the largest press is exact");
        assertEq(uint256(FeastConstants.BPS) % FeastConstants.TIP_CEILING_BPS, 0, "the ceiling is exact");
    }

    /// The floor moves only the split of what a press bought. The pacing that
    /// decides how much a press may spend — 5% at once, 15% an hour, 20% in any
    /// hour — does not move.
    function test_thePacingBoundsDoNotMove() public pure {
        assertEq(FeastConstants.ALLOWANCE_CAP_BPS, 500);
        assertEq(FeastConstants.ALLOWANCE_BPS_PER_HOUR, 1_500);
        assertEq(FeastConstants.MAX_HOURLY_SPEND_BPS, 2_000);
    }

    // --- small, medium, big -------------------------------------------------

    /// A bucket under 200 floors (0.1 WBNB here): the floor is more than 10% of
    /// the largest press, so the ceiling binds. Worth 0.5% of the bucket, which
    /// is what makes a bucket of about $26 cover a $0.13 press.
    function test_aSmallBucketsLargestPressIsTippedTheCeiling() public {
        _bank(keyW, address(wbnb), 5e18, 5); // ~0.05 WBNB
        uint256 pending = hook.selfBurnPending(keyW.toId());
        assertLt(pending, 200 * F, "precondition: a small bucket");

        (uint256 spent, uint256 burned, uint256 tip) = _pressLargest(coinW, keyW);
        uint256 coinOut = burned + tip;

        assertEq(tip, coinOut / 10, "tipped exactly the 10% ceiling");
        assertLt(tip * spent / coinOut, F, "which is worth less than the floor");
        assertGe(burned * 10, coinOut * 9, "and 90% of the print is burned");
    }

    /// Between 200 and 8,000 floors (1 WBNB here): the largest press is tipped
    /// the floor itself, valued at the price that press paid.
    function test_aMediumBucketsLargestPressIsTippedTheFloor() public {
        _bank(keyW, address(wbnb), 100e18, 5); // ~1 WBNB
        uint256 pending = hook.selfBurnPending(keyW.toId());
        assertGt(pending, 200 * F, "precondition: above the ceiling's reach");
        assertLt(pending, 8_000 * F, "precondition: below the 0.25% rule's reach");

        (uint256 spent, uint256 burned, uint256 tip) = _pressLargest(coinW, keyW);
        uint256 coinOut = burned + tip;

        assertApproxEqAbs(tip * spent / coinOut, F, 2, "tipped 0.0005 WBNB, at the price the press paid");
        assertGt(tip, coinOut * FeastConstants.TIP_BPS / FeastConstants.BPS, "more than 0.25%");
        assertLt(tip, coinOut / 10, "less than 10%");
    }

    /// Over 8,000 floors (20 WBNB here): 0.25% of the largest press is already
    /// worth more than the floor, so the tip is exactly what it was before.
    function test_aBigBucketIsTippedExactlyAsBefore() public {
        _bank(keyW, address(wbnb), 2_000e18, 5); // ~20 WBNB
        uint256 pending = hook.selfBurnPending(keyW.toId());
        assertGt(pending, 8_000 * F, "precondition: a big bucket");

        (, uint256 burned, uint256 tip) = _pressLargest(coinW, keyW);
        uint256 coinOut = burned + tip;

        assertEq(tip, coinOut * FeastConstants.TIP_BPS / FeastConstants.BPS, "0.25%, as in v1.6.22");
    }

    /// The stock pool reads its own row, in its own units. On this bucket the
    /// stock's floor is 2% of the largest press; the wrapped-native row would
    /// have been 0.5%, and no row at all 0.25%.
    function test_aStockPoolIsTippedItsOwnRowsFloor() public {
        _bank(keyS, address(stock), 200e18, 5); // ~2 stock
        uint256 pending = hook.selfBurnPending(keyS.toId());
        assertGt(pending, 200 * STOCK_FLOOR, "precondition: above the ceiling's reach");
        assertLt(pending, 8_000 * STOCK_FLOOR, "precondition: below the 0.25% rule's reach");

        (uint256 spent, uint256 burned, uint256 tip) = _pressLargest(coinS, keyS);
        uint256 coinOut = burned + tip;

        assertApproxEqAbs(tip * spent / coinOut, STOCK_FLOOR, 2, "tipped the stock row's floor, in the stock");
        assertGt(tip, coinOut / 100, "over 1% of the print: the stock row's 2%, not the native row's 0.5%");
    }

    /// The factory is open to any ERC-20. A quote nobody listed has no row, and
    /// its tip is today's 0.25% on the same bucket that is floored on WBNB.
    function test_anUnlistedQuoteKeepsTodaysRule() public {
        _bank(keyU, address(unlisted), 100e18, 5); // ~1 of it, as the medium WBNB bucket
        (, uint256 burned, uint256 tip) = _pressLargest(coinU, keyU);
        uint256 coinOut = burned + tip;

        assertEq(tip, coinOut * FeastConstants.TIP_BPS / FeastConstants.BPS, "0.25%, no floor");
    }

    // --- the farmer ---------------------------------------------------------

    /// **The split witness.** The rule as first written divided the floor by
    /// THIS press, so ten presses of a tenth were each tipped the 10% ceiling —
    /// ten times what the one press earned. Divided by the largest press, the
    /// rate is set by the bucket, and the ten pieces earn what the one did.
    ///
    /// The only drift is the bucket's own: it shrinks by up to 5% while the
    /// pieces are pressed, which lifts the later pieces' rate by up to 5.3% of
    /// itself. Hence 6%, against the written rule's 900%.
    function test_splittingAPressEarnsNothing() public {
        _bank(keyW, address(wbnb), 100e18, 5); // the medium bucket, where the floor binds
        PoolId id = keyW.toId();
        uint256 largest = hook.spendingAllowance(id);
        assertEq(largest, hook.selfBurnPending(id) / 20, "precondition: the allowance is the largest press");

        uint256 snap = vm.snapshotState();
        (,, uint256 oneTip) = _press(coinW, keyW, largest);

        vm.revertToState(snap);
        uint256 splitTips;
        for (uint256 i = 0; i < 10; i++) {
            (,, uint256 t) = _press(coinW, keyW, largest / 10);
            splitTips += t;
        }

        assertGt(oneTip, 0, "the witness reaches its bound: the one press was tipped");
        assertLe(splitTips, oneTip * 106 / 100, "ten presses of a tenth earned more than one press");
    }

    /// The same property, one press at a time: half the largest press is tipped
    /// at the full press's rate — not at twice it, which is what dividing by
    /// the press would give.
    function test_aSmallerPressIsTippedAtTheSameRate() public {
        _bank(keyW, address(wbnb), 100e18, 5);
        uint256 largest = hook.spendingAllowance(keyW.toId());

        uint256 snap = vm.snapshotState();
        (, uint256 burnedFull, uint256 tipFull) = _press(coinW, keyW, largest);
        vm.revertToState(snap);
        (, uint256 burnedHalf, uint256 tipHalf) = _press(coinW, keyW, largest / 2);

        uint256 rateFull = tipFull * 1e18 / (burnedFull + tipFull);
        uint256 rateHalf = tipHalf * 1e18 / (burnedHalf + tipHalf);
        assertGt(rateFull, 25e14, "precondition: the floor binds (the rate is above 0.25%)");
        assertApproxEqRel(rateHalf, rateFull, 1e14, "half a press is tipped at the same rate");
    }

    // --- the pacing, with the floor on ---------------------------------------

    /// FeastBuyback's greedy hour, on a floored pool: every minute, press the
    /// whole allowance. No press spends more than 5% of the bucket and no more
    /// than 20% of it leaves in the hour — the floor changed the tip, not the
    /// spend.
    function test_thePacingHoldsWithTheFloorOn() public {
        _bank(keyW, address(wbnb), 100e18, 5);
        PoolId id = keyW.toId();
        uint256 start = hook.selfBurnPending(id);

        uint256 spent;
        uint256 tips;
        for (uint32 t = 0; t < 3_600; t += 60) {
            uint256 a = hook.spendingAllowance(id);
            if (a != 0) {
                uint256 before_ = hook.selfBurnPending(id);
                (,, uint256 tip) = _press(coinW, keyW, a);
                uint256 took = before_ - hook.selfBurnPending(id);
                assertLe(took, before_ * FeastConstants.ALLOWANCE_CAP_BPS / FeastConstants.BPS, "a press spent over 5%");
                spent += took;
                tips += tip;
            }
            _advance(60);
        }

        assertGt(tips, 0, "the witness reaches its bound: the presses were tipped");
        assertLe(spent * FeastConstants.BPS / start, FeastConstants.MAX_HOURLY_SPEND_BPS, "over 20% left in an hour");
    }

    // --- every bucket, every press size ---------------------------------------

    /// One buy from 0.001 to 10,000 WBNB builds a bucket anywhere from far below
    /// the ceiling's reach to far above the 0.25% rule's; any press size up to the
    /// allowance. The tip is never below today's rule or above the ceiling, and
    /// at least 90% of every print is burned.
    function testFuzz_theTipStaysBetweenTheRuleAndTheCeiling(uint256 buySeed, uint256 pressSeed) public {
        _bank(keyW, address(wbnb), bound(buySeed, 1e15, 1e22), 1);
        uint256 allowance = hook.spendingAllowance(keyW.toId());
        uint256 amountIn = bound(pressSeed, allowance / 1_000 + 1, allowance);

        (, uint256 burned, uint256 tip) = _press(coinW, keyW, amountIn);
        uint256 coinOut = burned + tip;

        assertLe(tip, coinOut / 10, "above the 10% ceiling");
        assertGe(tip, coinOut * FeastConstants.TIP_BPS / FeastConstants.BPS, "below today's 0.25%");
        assertGe(burned * 10, coinOut * 9, "less than 90% burned");
    }

    // --- helpers ------------------------------------------------------------

    function _create(address quote, uint256 salt) internal returns (address coin, PoolKey memory key) {
        (coin, key) = factory.create(
            FeastFactory.CreateParams({
                name: "Coin",
                symbol: "COIN",
                supply: SUPPLY,
                quote: quote,
                creator: creator,
                selfBurnBps: FeastConstants.DEFAULT_SELF_BURN_BPS,
                referrerBps: 0,
                prebuyQuoteIn: 0,
                minCoinsOut: 0,
                vestingDuration: 0,
                sqrtPriceX96: SQRT_PRICE_1_1,
                startTick: 0,
                liquidity: uint128(SUPPLY * 999 / 1_000),
                salt: bytes32(salt),
                metadataHash: bytes32(0)
            })
        );
        // v1.6.15: the opening cap window opens at a pool's first SERVED swap.
        CapWarm.arm(router, key.up(), quote, Currency.unwrap(key.currency0) == quote);
    }

    function _advance(uint32 s) internal {
        clock += s;
        vm.warp(clock);
    }

    /// `buys` buys of `quoteIn` each, two minutes apart, then two idle hours:
    /// the allowance fills to its cap and the average settles on spot, so the
    /// next press may be the largest the bucket allows.
    function _bank(PoolKey memory k, address quote, uint256 quoteIn, uint256 buys) internal {
        bool zeroForOne = Currency.unwrap(k.currency0) == quote;
        for (uint256 i = 0; i < buys; i++) {
            _advance(120);
            MockERC20(quote).mint(address(router), quoteIn);
            router.swap(
                k.up(),
                ICLPoolManager.SwapParams({
                    zeroForOne: zeroForOne,
                    amountSpecified: -int256(quoteIn),
                    sqrtPriceLimitX96: zeroForOne ? MIN_SQRT : MAX_SQRT
                }),
                ""
            );
        }
        _advance(2 hours);
    }

    /// The largest press the bucket allows: the allowance, full after `_bank`'s
    /// idle hours, is exactly `ALLOWANCE_CAP_BPS` of the bucket, and the pool is
    /// deep enough to fill all of it.
    function _pressLargest(address coin, PoolKey memory k)
        internal
        returns (uint256 spent, uint256 burned, uint256 tip)
    {
        PoolId id = k.toId();
        uint256 largest = hook.selfBurnPending(id) * FeastConstants.ALLOWANCE_CAP_BPS / FeastConstants.BPS;
        assertEq(hook.spendingAllowance(id), largest, "precondition: the allowance is the largest press");
        (spent, burned, tip) = _press(coin, k, largest);
        assertEq(spent, largest, "precondition: the pool filled the whole press");
    }

    /// One press, read from its `BoughtBackAndBurned`, and the event checked
    /// against what moved: its tip is the coin the presser received, and its
    /// burn is the supply that left.
    function _press(address coin, PoolKey memory k, uint256 amountIn)
        internal
        returns (uint256 spent, uint256 burned, uint256 tip)
    {
        uint256 heldBefore = FeastToken(coin).balanceOf(presser);
        uint256 supplyBefore = FeastToken(coin).totalSupply();

        vm.recordLogs();
        vm.prank(presser);
        hook.buyBackAndBurn(k, amountIn);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        uint256 seen;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(hook) && logs[i].topics[0] == FeastHook.BoughtBackAndBurned.selector) {
                (spent, burned, tip) = abi.decode(logs[i].data, (uint256, uint256, uint256));
                seen++;
            }
        }
        assertEq(seen, 1, "one BoughtBackAndBurned per press");
        assertEq(FeastToken(coin).balanceOf(presser) - heldBefore, tip, "the event's tip is what the presser received");
        assertEq(supplyBefore - FeastToken(coin).totalSupply(), burned, "the event's burn is the supply that left");
    }
}
