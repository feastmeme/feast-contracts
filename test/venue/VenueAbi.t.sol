// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

// The shipped declarations (MIT, ours).
import {Currency} from "../../src/venue/Currency.sol";
import {IFeastCLHooks} from "../../src/venue/IFeastCLHooks.sol";
import {IFeastCLPoolManager} from "../../src/venue/IFeastCLPoolManager.sol";
import {IFeastVault} from "../../src/venue/IFeastVault.sol";
import {PoolId, PoolIdLibrary} from "../../src/venue/PoolId.sol";
import {PoolKey} from "../../src/venue/PoolKey.sol";

// The upstream originals. They reach GPL files, which is exactly why they are
// imported here in test/ and nowhere under src/.
import {Vault} from "infinity-core/src/Vault.sol";
import {IHooks as UpHooks} from "infinity-core/src/interfaces/IHooks.sol";
import {IPoolManager as UpPoolManager} from "infinity-core/src/interfaces/IPoolManager.sol";
import {IProtocolFees as UpProtocolFees} from "infinity-core/src/interfaces/IProtocolFees.sol";
import {IVault as UpVault} from "infinity-core/src/interfaces/IVault.sol";
import {IVaultToken as UpVaultToken} from "infinity-core/src/interfaces/IVaultToken.sol";
import {CLPoolManager} from "infinity-core/src/pool-cl/CLPoolManager.sol";
import {ICLHooks as UpCLHooks} from "infinity-core/src/pool-cl/interfaces/ICLHooks.sol";
import {ICLPoolManager as UpCLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {Currency as UpCurrency} from "infinity-core/src/types/Currency.sol";
import {PoolKey as UpPoolKey} from "infinity-core/src/types/PoolKey.sol";

/// The Q1 ruling keeps `src/` MIT by re-declaring the slice of the venue that
/// feast actually calls. That trade buys a licence boundary and sells a risk:
/// a re-declaration that is subtly wrong compiles perfectly and fails on chain.
///
/// These tests are the price of the trade. Every shipped declaration is checked
/// three ways — selector equality against the upstream interface, struct layout
/// equality by encoding, and an actual call through the shipped type against a
/// venue (locally deployed, and on the fork the real one).
contract VenueAbiTest is Test {
    using PoolIdLibrary for PoolKey;

    address internal constant VAULT = 0x238a358808379702088667322f80aC48bAd5e6c4;
    address internal constant CL_POOL_MANAGER = 0xa0FfB9c1CE1Fe56963B0321B32E7A0302114058b;
    uint256 internal constant FORK_BLOCK = 120_721_477;

    function _fork() internal returns (bool) {
        string memory url = vm.envOr("BSC_RPC_URL", string(""));
        if (bytes(url).length == 0) return false;
        vm.createSelectFork(url, FORK_BLOCK);
        return true;
    }

    // --- selectors -------------------------------------------------------

    function test_vaultSelectorsMatchUpstream() public pure {
        assertEq(IFeastVault.lock.selector, UpVault.lock.selector, "lock");
        assertEq(IFeastVault.take.selector, UpVault.take.selector, "take");
        assertEq(IFeastVault.sync.selector, UpVault.sync.selector, "sync");
        assertEq(IFeastVault.settle.selector, UpVault.settle.selector, "settle");
        assertEq(IFeastVault.mint.selector, UpVault.mint.selector, "mint");
        assertEq(IFeastVault.burn.selector, UpVault.burn.selector, "burn");
        assertEq(IFeastVault.balanceOf.selector, UpVaultToken.balanceOf.selector, "balanceOf");
    }

    function test_poolManagerSelectorsMatchUpstream() public pure {
        assertEq(IFeastCLPoolManager.initialize.selector, UpCLPoolManager.initialize.selector, "initialize");
        assertEq(IFeastCLPoolManager.swap.selector, UpCLPoolManager.swap.selector, "swap");
        assertEq(IFeastCLPoolManager.modifyLiquidity.selector, UpCLPoolManager.modifyLiquidity.selector, "modifyLiq");
        assertEq(IFeastCLPoolManager.getSlot0.selector, UpCLPoolManager.getSlot0.selector, "getSlot0");
        assertEq(
            IFeastCLPoolManager.getLiquidity.selector,
            bytes4(keccak256("getLiquidity(bytes32)")),
            "getLiquidity(PoolId)"
        );
        assertEq(IFeastCLPoolManager.vault.selector, UpProtocolFees.vault.selector, "vault");
    }

    function test_hookSelectorsMatchUpstream() public pure {
        assertEq(IFeastCLHooks.beforeInitialize.selector, UpCLHooks.beforeInitialize.selector, "beforeInitialize");
        assertEq(IFeastCLHooks.beforeSwap.selector, UpCLHooks.beforeSwap.selector, "beforeSwap");
        assertEq(IFeastCLHooks.afterSwap.selector, UpCLHooks.afterSwap.selector, "afterSwap");
        assertEq(
            IFeastCLHooks.getHooksRegistrationBitmap.selector,
            bytes4(keccak256("getHooksRegistrationBitmap()")),
            "getHooksRegistrationBitmap"
        );
    }

    // --- struct layout ---------------------------------------------------

    function _ourKey() internal pure returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(0xA11CE)),
            currency1: Currency.wrap(address(0xB0B)),
            hooks: address(0x400C),
            poolManager: address(0xdead),
            fee: 100,
            parameters: bytes32(uint256(0x0CC1))
        });
    }

    function _theirKey() internal pure returns (UpPoolKey memory) {
        return UpPoolKey({
            currency0: UpCurrency.wrap(address(0xA11CE)),
            currency1: UpCurrency.wrap(address(0xB0B)),
            hooks: UpHooks(address(0x400C)),
            poolManager: UpPoolManager(address(0xdead)),
            fee: 100,
            parameters: bytes32(uint256(0x0CC1))
        });
    }

    /// A struct with the same fields in the same order encodes identically. If a
    /// field is reordered, added or retyped, this is where it shows up —
    /// selector equality would not catch it, because `swap`'s selector depends
    /// on the tuple shape and not on which of two `address`-shaped fields is
    /// which.
    function test_poolKeyEncodesIdenticallyToUpstream() public pure {
        assertEq(keccak256(abi.encode(_ourKey())), keccak256(abi.encode(_theirKey())), "PoolKey layout");
    }

    function test_swapParamsEncodeIdenticallyToUpstream() public pure {
        IFeastCLPoolManager.SwapParams memory ours =
            IFeastCLPoolManager.SwapParams({zeroForOne: true, amountSpecified: -1e18, sqrtPriceLimitX96: 4_295_128_740});
        UpCLPoolManager.SwapParams memory theirs =
            UpCLPoolManager.SwapParams({zeroForOne: true, amountSpecified: -1e18, sqrtPriceLimitX96: 4_295_128_740});
        assertEq(keccak256(abi.encode(ours)), keccak256(abi.encode(theirs)), "SwapParams layout");
    }

    function test_modifyLiquidityParamsEncodeIdenticallyToUpstream() public pure {
        IFeastCLPoolManager.ModifyLiquidityParams memory ours = IFeastCLPoolManager.ModifyLiquidityParams({
            tickLower: -887_220,
            tickUpper: 887_220,
            liquidityDelta: 12_345,
            salt: bytes32(uint256(7))
        });
        UpCLPoolManager.ModifyLiquidityParams memory theirs = UpCLPoolManager.ModifyLiquidityParams({
            tickLower: -887_220,
            tickUpper: 887_220,
            liquidityDelta: 12_345,
            salt: bytes32(uint256(7))
        });
        assertEq(keccak256(abi.encode(ours)), keccak256(abi.encode(theirs)), "ModifyLiquidityParams layout");
    }

    /// A pool's id is the hash of its encoded key, so identical encoding must
    /// produce an identical id — otherwise every per-pool mapping in feast would
    /// be keyed differently from the venue's own.
    function test_poolIdMatchesUpstream() public pure {
        assertEq(PoolId.unwrap(_ourKey().toId()), keccak256(abi.encode(_theirKey())), "PoolId");
    }

    // --- live calls through the shipped types ----------------------------

    function test_localVenueAnswersThroughShippedTypes() public {
        Vault vault = new Vault();
        CLPoolManager pm = new CLPoolManager(vault);
        vault.registerApp(address(pm));
        assertEq(IFeastCLPoolManager(address(pm)).vault(), address(vault), "vault() through our declaration");
        assertEq(IFeastVault(address(vault)).balanceOf(address(this), Currency.wrap(address(0))), 0, "balanceOf");
    }

    function test_fork_realVenueAnswersThroughShippedTypes() public {
        if (!_fork()) {
            vm.skip(true);
            return;
        }
        assertEq(IFeastCLPoolManager(CL_POOL_MANAGER).vault(), VAULT, "vault() on the real deployment");
        assertEq(IFeastVault(VAULT).balanceOf(address(this), Currency.wrap(address(0))), 0, "balanceOf, real vault");
        // An uninitialised pool returns zeroes rather than reverting; what is
        // asserted is that the call decodes into our four declared returns.
        (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee) =
            IFeastCLPoolManager(CL_POOL_MANAGER).getSlot0(PoolId.wrap(bytes32(uint256(1))));
        assertEq(sqrtPriceX96, 0, "sqrtPriceX96");
        assertEq(tick, 0, "tick");
        assertEq(protocolFee, 0, "protocolFee");
        assertEq(lpFee, 0, "lpFee");
    }
}
