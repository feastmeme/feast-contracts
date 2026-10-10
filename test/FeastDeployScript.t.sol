// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {FeastGenesis} from "../src/FeastGenesis.sol";
import {DeployPackage1} from "../script/DeployPackage1.s.sol";

/// The package-1 recipe, as a script: it refuses the genesis file as committed
/// (a placeholder is unset), and — given a key — wires package 1 on the real
/// venue at the pinned block exactly as the README says.
contract FeastDeployScriptTest is Test {
    uint256 internal constant FORK_BLOCK = 120_721_477;

    /// Kills: a script that deploys with a zero genesis key, which would leave
    /// the platform coin impossible to launch through this factory for ever.
    function test_theScriptRefusesWhileTheGenesisKeyIsUnset() public {
        DeployPackage1 s = new DeployPackage1();
        vm.expectRevert(abi.encodeWithSelector(DeployPackage1.Placeholder.selector, "GENESIS_KEY"));
        s.check();
    }

    function test_fork_theRecipeWiresPackageOneOnTheRealVenue() public {
        string memory url = vm.envOr("BSC_RPC_URL", string(""));
        if (bytes(url).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(url, FORK_BLOCK);
        DeployPackage1 s = new DeployPackage1();
        address key = address(0x6E7E5);
        DeployPackage1.Package1 memory p = s.deployPackage1(key, address(s));

        assertEq(p.hook.factory(), address(p.factory), "hook knows the factory");
        assertEq(address(p.factory.hook()), address(p.hook), "factory knows the hook");
        assertEq(p.ledger.recorder(), address(p.hook), "only the hook records");
        assertEq(p.oracle.writer(), address(p.hook), "only the hook writes prices");
        assertEq(p.converter.hook(), address(p.hook), "only the hook converts");
        assertEq(address(p.hook.referrals()), address(p.referrals), "the hook reads the registry deployed for it");
        assertEq(p.vesting.factory(), address(p.factory), "vesting answers the factory");
        assertEq(p.platformTokenDeployer.factory(), address(p.factory), "and so does the coin's deployer");
        assertEq(p.factory.genesisKey(), key, "the key named");
        assertEq(p.factory.wrappedNative(), FeastGenesis.WRAPPED_NATIVE, "paired with wrapped native");
        assertEq(p.hook.poolManager(), FeastGenesis.CL_POOL_MANAGER, "on the real pool manager");
        assertEq(p.hook.vault(), FeastGenesis.VAULT, "and the real vault");
        assertTrue(p.factory.predictPlatformCoin() != address(0), "the platform coin's address is known");
        assertFalse(p.factory.genesisDone(), "and genesis is still to come");
    }
}
