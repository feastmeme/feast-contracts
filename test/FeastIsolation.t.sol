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
import {FeastVesting} from "../src/FeastVesting.sol";
import {Currency} from "../src/venue/Currency.sol";
import {PoolId, PoolIdLibrary} from "../src/venue/PoolId.sol";
import {PoolKey} from "../src/venue/PoolKey.sol";

import {Vault} from "infinity-core/src/Vault.sol";
import {CLPoolManager} from "infinity-core/src/pool-cl/CLPoolManager.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";

import {MockERC20, PausableMockERC20} from "./utils/MockERC20.sol";
import {PoolRouter} from "./utils/PoolRouter.sol";
import {VenueBridge} from "./utils/VenueBridge.sol";

import {FeastGuardian} from "../../../src/FeastGuardian.sol";
/// I2 and I7, the two invariants that justify the whole accrual design.
///
/// Feast pairs coins against tokenised stocks that are upgradeable proxies with
/// a pauser and a sanctions screen. The reference implementation this fee logic
/// comes from settles it with a real token transfer inside `beforeSwap`; against
/// a quote token like this, that hands a third party the power to stop every
/// trade in the pool. Feast mints a claim instead. These tests are what say so
/// out loud.
contract FeastIsolationTest is Test {
    using PoolIdLibrary for PoolKey;
    using VenueBridge for PoolKey;

    uint160 internal constant SQRT_PRICE_1_1 = 79_228_162_514_264_337_593_543_950_336;
    uint160 internal constant MIN_SQRT = 4_295_128_740;
    uint160 internal constant MAX_SQRT = 1_461_446_703_485_210_103_287_273_052_203_988_822_378_723_970_341;
    uint256 internal constant SUPPLY = 1_000_000_000e18;

    address internal creator = address(0xC0FFEE);
    address internal pauser = address(0xBADBAD);

    Vault internal vault;
    CLPoolManager internal pm;
    PoolRouter internal router;
    FeastGuardian internal guardian;
    FeastHook internal hook;
    FeastReferrals internal referrals;
    FeastVesting internal vesting;
    FeastFactory internal factory;

    PausableMockERC20 internal hostileQuote;
    MockERC20 internal healthyQuote;

    PoolKey internal hostileKey;
    PoolKey internal healthyKey;

    function setUp() public {
        vault = new Vault();
        pm = new CLPoolManager(vault);
        vault.registerApp(address(pm));
        router = new PoolRouter(vault, pm);

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

        hostileQuote = new PausableMockERC20("Stock", "STKx", 18, pauser);
        healthyQuote = new MockERC20("Healthy", "OK", 18);

        (, hostileKey) = factory.create(_params(address(hostileQuote), bytes32(uint256(1))));
        (, healthyKey) = factory.create(_params(address(healthyQuote), bytes32(uint256(2))));

        hostileQuote.mint(address(router), 100_000_000e18);
        healthyQuote.mint(address(router), 100_000_000e18);
    }

    function _params(address quote, bytes32 salt) internal view returns (FeastFactory.CreateParams memory) {
        return FeastFactory.CreateParams({
            name: "Coin",
            symbol: "COIN",
            supply: SUPPLY,
            quote: quote,
            creator: creator,
            selfBurnBps: FeastConstants.DEFAULT_SELF_BURN_BPS,
            referrerBps: FeastConstants.DEFAULT_REFERRER_BPS,
            prebuyQuoteIn: 0,
            minCoinsOut: 0,
            vestingDuration: 0,
            sqrtPriceX96: SQRT_PRICE_1_1,
            startTick: 0,
            liquidity: uint128(SUPPLY * 999 / 1_000),
            salt: salt,
            metadataHash: bytes32(0)
        });
    }

    function _buy(PoolKey memory key, address quote, int256 amount) internal {
        bool zeroForOne = Currency.unwrap(key.currency0) == quote;
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

    // --- I7: one bad pool cannot poison a good one ------------------------

    function test_aFrozenQuoteTokenDoesNotStopAnyOtherPool() public {
        _buy(hostileKey, address(hostileQuote), -100_000e18);
        _buy(healthyKey, address(healthyQuote), -100_000e18);

        vm.prank(pauser);
        hostileQuote.setPaused(true);

        // The frozen pool cannot trade — its own token refuses to move, which
        // is the issuer's prerogative and nothing feast can or should override.
        vm.expectRevert();
        _buy(hostileKey, address(hostileQuote), -1_000e18);

        // Every other pool is untouched. This is what per-pool state buys.
        uint256 before_ = hook.poolInfo(healthyKey.toId()).accruedQuote;
        _buy(healthyKey, address(healthyQuote), -100_000e18);
        assertGt(hook.poolInfo(healthyKey.toId()).accruedQuote, before_, "the healthy pool keeps earning");
    }

    // --- I2: value stuck, never lost --------------------------------------

    /// The ledger is written when the fee is taken and read when it is claimed.
    /// Freezing the token in between can delay the payment; it cannot change
    /// what is owed, and it cannot make the record disagree with itself.
    function test_freezingTheQuoteTokenDelaysAClaimButNeverChangesIt() public {
        _buy(hostileKey, address(hostileQuote), -1_000_000e18);
        PoolId id = hostileKey.toId();

        uint256 owed = hook.creatorPending(id);
        assertGt(owed, 0, "the creator earned something before the freeze");

        vm.prank(pauser);
        hostileQuote.setPaused(true);

        vm.expectRevert();
        hook.claimCreator(hostileKey);

        // Nothing was consumed by the failed attempt.
        assertEq(hook.creatorPending(id), owed, "the ledger is exactly as it was");
        assertEq(hostileQuote.balanceOf(creator), 0, "and nothing was paid");

        vm.prank(pauser);
        hostileQuote.setPaused(false);

        hook.claimCreator(hostileKey);
        assertEq(hostileQuote.balanceOf(creator), owed, "paid in full once the freeze lifts");
        assertEq(hook.creatorPending(id), 0, "and settled exactly once");
    }

    /// The accrual itself never touches the token contract, so the value is
    /// held as a vault claim rather than as a balance the issuer can freeze in
    /// place. Stated here as an explicit balance check because it is the single
    /// property the design turns on.
    function test_accruedValueLivesAsAClaimNotAsATokenBalance() public {
        _buy(hostileKey, address(hostileQuote), -1_000_000e18);
        assertGt(hook.poolInfo(hostileKey.toId()).accruedQuote, 0, "fees accrued");
        assertEq(hostileQuote.balanceOf(address(hook)), 0, "the hook holds no quote tokens between claims");
    }

    /// A pool whose quote token is frozen forever keeps its accounting intact,
    /// and the coin's own buy-and-burn bucket is denominated in that same quote
    /// — so nothing is silently reassigned to another pool's benefit.
    function test_aPermanentlyFrozenPoolKeepsItsOwnAccountingToItself() public {
        _buy(hostileKey, address(hostileQuote), -1_000_000e18);
        _buy(healthyKey, address(healthyQuote), -1_000_000e18);

        vm.prank(pauser);
        hostileQuote.setPaused(true);

        PoolId frozen = hostileKey.toId();
        PoolId healthy = healthyKey.toId();
        uint256 frozenTotal = hook.poolInfo(frozen).accruedQuote;

        assertEq(
            hook.selfBurnPending(frozen) + hook.platformPending(frozen) + hook.creatorPending(frozen),
            frozenTotal,
            "the frozen pool's shares still add up to its own fee"
        );
        assertTrue(hook.poolInfo(healthy).accruedQuote != 0, "and the healthy pool has its own, separate total");
    }
}
