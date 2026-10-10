// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {FeastConstants} from "../src/FeastConstants.sol";
import {FeastFeeLedger} from "../src/FeastFeeLedger.sol";
import {FeastOracle} from "../src/FeastOracle.sol";
import {FeastCLHookBase} from "../src/FeastCLHookBase.sol";
import {FeastHook} from "../src/FeastHook.sol";
import {FeastReferrals} from "../src/FeastReferrals.sol";
import {Currency} from "../src/venue/Currency.sol";
import {PoolId, PoolIdLibrary} from "../src/venue/PoolId.sol";
import {PoolKey} from "../src/venue/PoolKey.sol";

import {Vault} from "infinity-core/src/Vault.sol";
import {CLPoolManager} from "infinity-core/src/pool-cl/CLPoolManager.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";

import {MockERC20} from "./utils/MockERC20.sol";
import {PoolRouter} from "./utils/PoolRouter.sol";
import {VenueBridge} from "./utils/VenueBridge.sol";

import {FeastGuardian} from "../../../src/FeastGuardian.sol";
/// The split is a marketing surface: a creator advertises "20% of every trade
/// buys and burns this coin" and a buyer has to be able to believe it forever.
/// So the tests here are about two things — that the four shares always add up
/// to exactly what was taken, and that nothing anywhere can change them.
contract FeastBucketsTest is Test {
    using PoolIdLibrary for PoolKey;
    using VenueBridge for PoolKey;

    uint160 internal constant SQRT_PRICE_1_1 = 79_228_162_514_264_337_593_543_950_336;
    uint160 internal constant MIN_SQRT = 4_295_128_740;
    uint160 internal constant MAX_SQRT = 1_461_446_703_485_210_103_287_273_052_203_988_822_378_723_970_341;

    address internal factory = address(0xFAC7);
    address internal creator = address(0xC0FFEE);
    address internal referrer = address(0xEE);

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
        _createPool(creator, FeastConstants.DEFAULT_SELF_BURN_BPS, FeastConstants.DEFAULT_REFERRER_BPS);
    }

    function _createPool(address creator_, uint16 selfBurnBps, uint16 referrerBps) internal {
        coin = new MockERC20("Coin", "COIN", 18);
        quote = new MockERC20("Quote", "Q", 18);
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
        hook.registerPool(key, address(coin), creator_, selfBurnBps, referrerBps, 1_000_000_000e18, 0, address(0));
        vm.prank(factory);
        pm.initialize(key.up(), SQRT_PRICE_1_1);

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
        vm.roll(vm.getBlockNumber() + FeastConstants.CAP_BLOCKS);
    }

    function _buy(int256 amount, bytes memory hookData) internal {
        bool zeroForOne = !coinIsCurrency0;
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

    // --- I6: conservation --------------------------------------------------

    /// Four shares, one total, no wei created or destroyed. Fuzzed over trade
    /// sizes and both creator-set shares, because the remainder is *computed*
    /// and a computed remainder is exactly where an off-by-one hides.
    function testFuzz_theFourSharesAlwaysSumToWhatWasTaken(uint96 raw, uint16 x, uint16 y, bool referred) public {
        x = uint16(bound(x, 0, FeastConstants.MAX_SELF_BURN_BPS));
        y = uint16(bound(y, 0, FeastConstants.MAX_REFERRER_BPS));
        _createPool(creator, x, y);

        uint256 size = bound(uint256(raw), 1e18, 100_000e18);
        _buy(-int256(size), referred ? abi.encode(referrer) : bytes(""));

        PoolId id = key.toId();
        uint256 total = hook.poolInfo(id).accruedQuote;
        uint256 sum = hook.selfBurnPending(id) + hook.platformPending(id) + hook.creatorPending(id)
            + hook.referrerPending(id, referrer);
        assertEq(sum, total, "the four shares are the whole fee, exactly");
    }

    function test_defaultSplitIsTwentyFiftyTenTwenty() public {
        _buy(-100_000e18, abi.encode(referrer));
        PoolId id = key.toId();
        uint256 total = hook.poolInfo(id).accruedQuote;

        assertEq(hook.selfBurnPending(id), total * 2_000 / 10_000, "self-burn 20%");
        assertEq(hook.referrerPending(id, referrer), total * 1_000 / 10_000, "referrer 10%");
        assertEq(hook.platformPending(id), total * 2_000 / 10_000, "platform 20%");
        // The remainder absorbs the dust from three independent floor
        // divisions, so it is a subtraction here too — not `total * 50%`.
        assertEq(
            hook.creatorPending(id),
            total - (total * 2_000 / 10_000) - (total * 2_000 / 10_000) - (total * 1_000 / 10_000),
            "creator gets the remaining 50%"
        );
    }

    /// Spec: the referrer's share only exists on trades that name a referrer.
    /// On the rest it belongs to the creator, who is otherwise paying a
    /// commission for distribution that did not happen.
    function test_withoutAReferrerTheCreatorKeepsThatShareToo() public {
        _buy(-100_000e18, "");
        PoolId id = key.toId();
        uint256 total = hook.poolInfo(id).accruedQuote;
        assertEq(hook.referrerPending(id, referrer), 0, "nobody was credited as referrer");
        assertEq(
            hook.creatorPending(id),
            total - (total * 2_000 / 10_000) - (total * 2_000 / 10_000),
            "creator keeps 50 + the unclaimed 10"
        );
    }

    // --- R3: malformed referral data must not cost a trader their swap -----

    /// The reference exits early only on empty data, which leaves one to
    /// thirty-one bytes hitting `abi.decode` and reverting *the swap*. Any
    /// router that appends a byte would break every trade in the pool.
    function test_malformedReferralDataIsIgnoredRatherThanReverting() public {
        _buy(-1_000e18, hex"deadbeef");
        assertGt(hook.poolInfo(key.toId()).accruedQuote, 0, "the swap went through and the fee was taken");
        assertEq(hook.referrerPending(key.toId(), referrer), 0, "no referrer credited");
    }

    function testFuzz_anyHookDataIsSurvivable(bytes calldata blob) public {
        vm.assume(blob.length < 200);
        _buy(-1_000e18, blob);
        assertGt(hook.poolInfo(key.toId()).accruedQuote, 0, "the swap went through");
    }

    /// The length check earns its keep here rather than on the revert path.
    /// A blob shorter than a word is right-padded when read, and a 13-byte blob
    /// with a small value pads into a perfectly plausible address — so without
    /// an exact-length check, a truncated or malformed referral tag would
    /// silently credit a commission to an address nobody chose, forever.
    function test_aShortBlobIsNeverReadAsAReferrer() public {
        // 13 bytes: twelve zeros and a one. Right-padded to a word this is
        // 1 << 152, which is a valid address and not the zero address.
        bytes memory shortBlob = hex"00000000000000000000000001";
        address wouldBe = address(uint160(uint256(bytes32(shortBlob))));
        assertTrue(wouldBe != address(0), "the fixture really does pad into an address");

        _buy(-100_000e18, shortBlob);
        PoolId id = key.toId();
        assertEq(hook.referrerPending(id, wouldBe), 0, "no commission was invented");
        uint256 total = hook.poolInfo(id).accruedQuote;
        assertEq(
            hook.creatorPending(id),
            total - (total * 2_000 / 10_000) - (total * 2_000 / 10_000),
            "the creator keeps the referral share, as on any unreferred trade"
        );
    }

    function test_zeroAddressReferrerIsNoReferrer() public {
        _buy(-100_000e18, abi.encode(address(0)));
        PoolId id = key.toId();
        assertEq(hook.referrerPending(id, address(0)), 0, "the zero address is never a claimant");
        uint256 t0 = hook.poolInfo(id).accruedQuote;
        assertEq(hook.creatorPending(id), t0 - (t0 * 2_000 / 10_000) - (t0 * 2_000 / 10_000), "creator keeps it");
    }

    // --- R2: shares are refused at creation or never -----------------------

    function test_registrationRefusesSharesOutsideTheirBands() public {
        MockERC20 c = new MockERC20("c", "c", 18);
        MockERC20 q = new MockERC20("q", "q", 18);
        (address c0, address c1) = address(c) < address(q) ? (address(c), address(q)) : (address(q), address(c));
        PoolKey memory k = PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            hooks: address(hook),
            poolManager: address(pm),
            fee: FeastConstants.POOL_LP_FEE,
            parameters: hook.poolParameters()
        });

        vm.prank(factory);
        vm.expectRevert(FeastHook.ShareOutOfBand.selector);
        hook.registerPool(k, address(c), creator, FeastConstants.MAX_SELF_BURN_BPS + 1, 0, 1e27, 0, address(0));

        vm.prank(factory);
        vm.expectRevert(FeastHook.ShareOutOfBand.selector);
        hook.registerPool(k, address(c), creator, 0, FeastConstants.MAX_REFERRER_BPS + 1, 1e27, 0, address(0));
    }

    /// The cap is a number, not a symbol: v1.6.2 raised the self-burn cap from
    /// 30% of the fee to 50% (owner, 2026-09-12), and the witness above follows
    /// the constant wherever it goes. This one pins where it actually is, so a
    /// silent move of the constant fails a test rather than passing one.
    function test_theSelfBurnCapIsHalfTheFeeAndTheReferrerCapIsThirtyPercent() public {
        assertEq(FeastConstants.MAX_SELF_BURN_BPS, 5_000, "the self-burn cap is half the fee");
        assertEq(FeastConstants.MAX_REFERRER_BPS, 3_000, "the referrer cap is unchanged");

        MockERC20 c = new MockERC20("c", "c", 18);
        MockERC20 q = new MockERC20("q", "q", 18);
        (address c0, address c1) = address(c) < address(q) ? (address(c), address(q)) : (address(q), address(c));
        PoolKey memory k = PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            hooks: address(hook),
            poolManager: address(pm),
            fee: FeastConstants.POOL_LP_FEE,
            parameters: hook.poolParameters()
        });

        vm.prank(factory);
        vm.expectRevert(FeastHook.ShareOutOfBand.selector);
        hook.registerPool(k, address(c), creator, 5_001, 0, 1e27, 0, address(0));

        vm.prank(factory);
        hook.registerPool(k, address(c), creator, 5_000, 0, 1e27, 0, address(0));
        assertEq(hook.poolInfo(k.toId()).selfBurnBps, 5_000, "and 5,000 is accepted");
    }

    /// The bands still fit inside the creator side, and after v1.6.2 (H3) they
    /// fit it exactly: 50 + 30 is the whole 80, so a creator at both maxima
    /// keeps nothing but the rounding dust the three floors leave behind. This
    /// asserts the boundary is usable rather than merely documented — and that
    /// the remainder, computed by subtraction, does not underflow at the edge.
    function test_registrationAcceptsBothSharesAtTheirMaximum() public {
        _createPool(creator, FeastConstants.MAX_SELF_BURN_BPS, FeastConstants.MAX_REFERRER_BPS);
        _buy(-100_000e18, abi.encode(referrer));
        PoolId id = key.toId();
        uint256 total = hook.poolInfo(id).accruedQuote;
        assertEq(
            hook.creatorPending(id),
            total - (total * 5_000 / 10_000) - (total * 2_000 / 10_000) - (total * 3_000 / 10_000),
            "creator keeps 80 - 50 - 30 = 0, less the dust the floors leave"
        );
        assertLt(hook.creatorPending(id), 10, "which is dust, not a share");
    }

    /// I3. There is no setter. Asserted against the deployed bytecode, because
    /// "we did not write one" is a claim and this is evidence.
    function test_noShareSetterExists() public {
        string[4] memory sigs = [
            "setSelfBurnBps(bytes32,uint16)",
            "setReferrerBps(bytes32,uint16)",
            "setCreator(bytes32,address)",
            "setPlatformBps(uint16)"
        ];
        for (uint256 i = 0; i < sigs.length; i++) {
            (bool ok,) = address(hook).call(abi.encodeWithSignature(sigs[i], bytes32(0), uint16(1)));
            assertFalse(ok, sigs[i]);
        }
    }

    function test_registrationIsOnlyEverTheFactorysAndOnlyOnce() public {
        vm.expectRevert(FeastCLHookBase.NotFactory.selector);
        hook.registerPool(key, address(coin), creator, 0, 0, 1e27, 0, address(0));

        vm.prank(factory);
        vm.expectRevert(FeastHook.PoolAlreadyRegistered.selector);
        hook.registerPool(key, address(coin), creator, 0, 0, 1e27, 0, address(0));
    }

    // --- I14: nothing may strand at a dead address -------------------------

    /// The platform coin is created with the burn address as its creator. Left
    /// alone, ~70% of its own fee would accrue to a claim nobody can make —
    /// while the pitch says its fees burn entirely. Routing the remainder into
    /// the buy-and-burn bucket is what makes that sentence true.
    function test_aBurnAddressCreatorSendsItsShareToTheBurnBucketInstead() public {
        _createPool(FeastConstants.BURN_ADDRESS, 0, 0);
        _buy(-100_000e18, "");
        PoolId id = key.toId();
        uint256 total = hook.poolInfo(id).accruedQuote;

        assertEq(hook.creatorPending(id), 0, "nothing is stranded at the dead address");
        assertEq(hook.selfBurnPending(id), total - (total * 2_000 / 10_000), "the whole creator side buys and burns");
        assertEq(hook.platformPending(id), total * 2_000 / 10_000, "the platform share is unchanged");
    }
}
