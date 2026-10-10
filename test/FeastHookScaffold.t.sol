// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {FeastConstants} from "../src/FeastConstants.sol";
import {FeastOracle} from "../src/FeastOracle.sol";
import {FeastParameters} from "../src/FeastParameters.sol";
import {FeastCLHookBase} from "../src/FeastCLHookBase.sol";
import {Currency} from "../src/venue/Currency.sol";
import {IFeastCLPoolManager} from "../src/venue/IFeastCLPoolManager.sol";
import {PoolId, PoolIdLibrary} from "../src/venue/PoolId.sol";
import {PoolKey} from "../src/venue/PoolKey.sol";

import {Vault} from "infinity-core/src/Vault.sol";
import {CLPoolManager} from "infinity-core/src/pool-cl/CLPoolManager.sol";
import {CLPoolParametersHelper} from "infinity-core/src/pool-cl/libraries/CLPoolParametersHelper.sol";

import {MockERC20} from "./utils/MockERC20.sol";
import {VenueBridge} from "./utils/VenueBridge.sol";

/// A concrete hook that adds nothing to the scaffold. The point of these tests
/// is the scaffold itself: the registration bitmap, the parameter packing, and
/// the refusal that keeps strangers out of per-pool state.
contract BareHook is FeastCLHookBase {
    constructor(address pm, address vault_, address factory_) FeastCLHookBase(pm, vault_, factory_) {}

    bool public initialised;

    function _onPoolInitialized(PoolKey calldata) internal override {
        initialised = true;
    }
}

contract FeastHookScaffoldTest is Test {
    using PoolIdLibrary for PoolKey;
    using VenueBridge for PoolKey;

    address internal constant CL_POOL_MANAGER = 0xa0FfB9c1CE1Fe56963B0321B32E7A0302114058b;
    address internal constant VAULT = 0x238a358808379702088667322f80aC48bAd5e6c4;
    uint256 internal constant FORK_BLOCK = 120_721_477;
    /// 1:1 price.
    uint160 internal constant SQRT_PRICE_1_1 = 79_228_162_514_264_337_593_543_950_336;

    address internal factory = address(0xFAC7);

    Vault internal vault;
    CLPoolManager internal pm;
    BareHook internal hook;

    function setUp() public {
        vault = new Vault();
        pm = new CLPoolManager(vault);
        vault.registerApp(address(pm));
        hook = new BareHook(address(pm), address(vault), factory);
    }

    function _key(address hook_, address pm_, bytes32 params) internal returns (PoolKey memory k) {
        MockERC20 a = new MockERC20("A", "A", 18);
        MockERC20 b = new MockERC20("B", "B", 18);
        (address c0, address c1) = address(a) < address(b) ? (address(a), address(b)) : (address(b), address(a));
        k = PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            hooks: hook_,
            poolManager: pm_,
            fee: FeastConstants.POOL_LP_FEE,
            parameters: params
        });
    }

    // --- the bitmap ------------------------------------------------------

    function test_bitmapIsTheFiveCallbacksFeastRegistersAndNoOthers() public view {
        uint16 b = hook.getHooksRegistrationBitmap();
        assertEq(b, 0x0CC1, "bitmap");
        assertTrue(b & (1 << 0) != 0, "beforeInitialize");
        assertTrue(b & (1 << 6) != 0, "beforeSwap");
        assertTrue(b & (1 << 7) != 0, "afterSwap");
        assertTrue(b & (1 << 10) != 0, "beforeSwapReturnsDelta");
        assertTrue(b & (1 << 11) != 0, "afterSwapReturnsDelta");
        // Everything feast does not register must be off: an enabled callback
        // feast does not implement would revert every swap in the pool.
        assertEq(b & ~uint16(0x0CC1), 0, "no other callback is registered");
    }

    // --- parameter packing ------------------------------------------------

    /// Ours is an original implementation because the venue's helper is
    /// GPL-licensed. That makes it exactly the kind of code that is easy to get
    /// subtly wrong, so it is fuzzed against the original rather than eyeballed.
    function testFuzz_parameterPackingMatchesTheVenues(uint16 bitmap, int24 tickSpacing) public pure {
        bytes32 ours = FeastParameters.encode(bitmap, tickSpacing);
        bytes32 theirs = CLPoolParametersHelper.setTickSpacing(bytes32(uint256(bitmap)), tickSpacing);
        assertEq(ours, theirs, "packing");
        assertEq(FeastParameters.bitmapOf(ours), bitmap, "bitmap roundtrip");
        assertEq(FeastParameters.tickSpacingOf(ours), tickSpacing, "tickSpacing roundtrip");
    }

    /// The venue rejects a key with anything set above bit 40, so the encoder
    /// must never write there.
    function testFuzz_parameterPackingLeavesTheUnusedBitsZero(uint16 bitmap, int24 tickSpacing) public pure {
        bytes32 p = FeastParameters.encode(bitmap, tickSpacing);
        assertEq(uint256(p) >> 40, 0, "bits 40+ must be zero");
    }

    // --- creation is the factory's alone ---------------------------------

    function test_localPoolInitializesWhenTheFactoryAsksFor() public {
        PoolKey memory k = _key(address(hook), address(pm), hook.poolParameters());
        vm.prank(factory);
        pm.initialize(k.up(), SQRT_PRICE_1_1);
        assertTrue(hook.initialised(), "per-pool state was written");
    }

    /// R1. Without this refusal anyone could create a second pool bearing
    /// feast's hook with a hostile quote token or tick spacing, and a stranger
    /// would be the one writing feast's per-pool state.
    function test_localPoolRefusesAnyInitialiserButTheFactory() public {
        PoolKey memory k = _key(address(hook), address(pm), hook.poolParameters());
        vm.prank(address(0xBAD));
        vm.expectRevert();
        pm.initialize(k.up(), SQRT_PRICE_1_1);
    }

    /// A key whose declared bitmap disagrees with the hook's is refused by the
    /// venue itself. Asserted so that a future bitmap change cannot silently
    /// register a callback feast does not implement.
    function test_localPoolRefusesAKeyWhoseBitmapDisagreesWithTheHook() public {
        PoolKey memory k = _key(address(hook), address(pm), FeastParameters.encode(0x00C1, 200));
        vm.prank(factory);
        vm.expectRevert();
        pm.initialize(k.up(), SQRT_PRICE_1_1);
    }

    // --- callbacks belong to the venue ------------------------------------

    function test_callbacksRefuseAnyCallerButThePoolManager() public {
        PoolKey memory k = _key(address(hook), address(pm), hook.poolParameters());
        vm.expectRevert(FeastCLHookBase.NotPoolManager.selector);
        hook.beforeInitialize(factory, k, SQRT_PRICE_1_1);

        IFeastCLPoolManager.SwapParams memory sp =
            IFeastCLPoolManager.SwapParams({zeroForOne: true, amountSpecified: -1, sqrtPriceLimitX96: 0});
        vm.expectRevert(FeastCLHookBase.NotPoolManager.selector);
        hook.beforeSwap(address(this), k, sp, "");
    }

    function test_lockCallbackRefusesAnyCallerButTheVault() public {
        vm.expectRevert(FeastCLHookBase.NotVault.selector);
        hook.lockAcquired("");
    }

    // --- the test that de-risks the project -------------------------------

    /// If the registration bitmap is encoded wrongly, this is where it shows up,
    /// against the real deployment rather than against a local copy of it.
    /// Nothing downstream matters until this passes.
    function test_fork_realVenueAcceptsFeastsHookConfiguration() public {
        string memory url = vm.envOr("BSC_RPC_URL", string(""));
        if (bytes(url).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(url, FORK_BLOCK);

        BareHook forkHook = new BareHook(CL_POOL_MANAGER, VAULT, factory);
        PoolKey memory k = _key(address(forkHook), CL_POOL_MANAGER, forkHook.poolParameters());

        vm.prank(factory);
        CLPoolManager(CL_POOL_MANAGER).initialize(k.up(), SQRT_PRICE_1_1);

        assertTrue(forkHook.initialised(), "the real venue called feast's beforeInitialize");
        (uint160 sqrtPriceX96,,,) = IFeastCLPoolManager(CL_POOL_MANAGER).getSlot0(k.toId());
        assertEq(sqrtPriceX96, SQRT_PRICE_1_1, "the pool exists at the price we asked for");
    }

}
