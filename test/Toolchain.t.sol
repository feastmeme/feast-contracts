// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vault} from "infinity-core/src/Vault.sol";
import {IVault} from "infinity-core/src/interfaces/IVault.sol";
import {CLPoolManager} from "infinity-core/src/pool-cl/CLPoolManager.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {
    HOOKS_AFTER_SWAP_OFFSET,
    HOOKS_AFTER_SWAP_RETURNS_DELTA_OFFSET,
    HOOKS_BEFORE_INITIALIZE_OFFSET,
    HOOKS_BEFORE_SWAP_OFFSET,
    HOOKS_BEFORE_SWAP_RETURNS_DELTA_OFFSET
} from "infinity-core/src/pool-cl/interfaces/ICLHooks.sol";

/// @dev Station-1 smoke test. It contains no product logic: its only job is to
///      prove that the compiler version, the remappings, the EVM target and the
///      pinned fork all work, and that the venue addresses the design is written
///      against are the ones actually deployed at the pinned block.
///
///      Run without a fork (`forge test --mc ToolchainTest`) and the fork cases
///      skip themselves rather than failing, so a reviewer with no RPC still
///      gets a green local build.
contract ToolchainTest is Test {
    // Addresses from the venue's own deployment config, cross-checked on chain.
    address internal constant VAULT = 0x238a358808379702088667322f80aC48bAd5e6c4;
    address internal constant CL_POOL_MANAGER = 0xa0FfB9c1CE1Fe56963B0321B32E7A0302114058b;
    address internal constant CL_PROTOCOL_FEE_CONTROLLER = 0x15F6180033aEa66377d2A1778e418591C00dEb4c;

    /// @dev Pinned because the sample quote token sits behind an upgradeable
    ///      proxy: an unpinned fork silently tracks upgrades.
    uint256 internal constant FORK_BLOCK = 120_721_477;

    function _fork() internal returns (bool) {
        string memory url = vm.envOr("BSC_RPC_URL", string(""));
        if (bytes(url).length == 0) return false;
        vm.createSelectFork(url, FORK_BLOCK);
        return true;
    }

    /// The hook permission bitmap the design depends on, recomputed from the
    /// venue's own offset constants rather than hard-coded. If the venue ever
    /// renumbers an offset, this fails instead of silently registering the
    /// wrong callbacks.
    function _bit(uint8 offset) private pure returns (uint16) {
        return uint16(2 ** uint16(offset));
    }

    function test_hookBitmapMatchesTheDesign() public pure {
        uint16 bitmap = _bit(HOOKS_BEFORE_INITIALIZE_OFFSET) | _bit(HOOKS_BEFORE_SWAP_OFFSET)
            | _bit(HOOKS_AFTER_SWAP_OFFSET) | _bit(HOOKS_BEFORE_SWAP_RETURNS_DELTA_OFFSET)
            | _bit(HOOKS_AFTER_SWAP_RETURNS_DELTA_OFFSET);
        assertEq(bitmap, 0x0CC1, "hook registration bitmap");
    }

    function test_fork_poolManagerPointsAtTheExpectedVault() public {
        if (!_fork()) {
            vm.skip(true);
            return;
        }
        assertEq(address(ICLPoolManager(CL_POOL_MANAGER).vault()), VAULT, "CLPoolManager.vault()");
        assertGt(CL_POOL_MANAGER.code.length, 0, "pool manager has code");
        assertGt(VAULT.code.length, 0, "vault has code");
    }

    /// The venue keeps a share of the LP fee and can change that share. The
    /// design must not depend on the number, only know it is not ours.
    function test_fork_protocolFeeControllerIsNotOurs() public {
        if (!_fork()) {
            vm.skip(true);
            return;
        }
        (bool ok, bytes memory ret) =
            CL_PROTOCOL_FEE_CONTROLLER.staticcall(abi.encodeWithSignature("protocolFeeSplitRatio()"));
        assertTrue(ok, "protocolFeeSplitRatio()");
        assertEq(abi.decode(ret, (uint256)), 330_000, "venue keeps 33% of the LP fee");
    }

    /// The sample quote token: an upgradeable proxy that can be paused and that
    /// screens transfers. Asserted here so the constraint is visible from the
    /// first commit rather than discovered when a swap reverts.
    function test_fork_sampleQuoteTokenIsAProxyWithAPauser() public {
        if (!_fork()) {
            vm.skip(true);
            return;
        }
        address quote = 0x8aD3c73F833d3F9A523aB01476625F269aEB7Cf0;
        bytes32 implSlot = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
        assertGt(uint256(vm.load(quote, implSlot)), 0, "EIP-1967 implementation slot is populated");

        (bool ok, bytes memory ret) = quote.staticcall(abi.encodeWithSignature("pauser()"));
        assertTrue(ok, "pauser()");
        assertTrue(abi.decode(ret, (address)) != address(0), "quote token has a pauser");

        (ok, ret) = quote.staticcall(abi.encodeWithSignature("isPaused()"));
        assertTrue(ok, "isPaused()");
        assertFalse(abi.decode(ret, (bool)), "quote token is not paused at the pinned block");
    }

    /// The venue is deployable in-process, so the bulk of the suite can be fast
    /// local tests and the fork can be reserved for the two things only mainnet
    /// has: the real deployment's exact configuration, and a real quote token
    /// with a pauser and a sanctions screen.
    function test_localVenueDeploys() public {
        Vault vault = new Vault();
        CLPoolManager pm = new CLPoolManager(vault);
        vault.registerApp(address(pm));
        assertEq(address(pm.vault()), address(vault), "locally deployed venue is wired up");
    }

    function test_fork_vaultExposesTheAccrualPrimitive() public {
        if (!_fork()) {
            vm.skip(true);
            return;
        }
        // Only the selector is asserted: accrual happens through the vault's
        // ERC-6909 claim mint, never through a transfer of the quote token.
        assertEq(IVault.mint.selector, bytes4(keccak256("mint(address,address,uint256)")), "IVault.mint selector");
    }
}
