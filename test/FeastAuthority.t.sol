// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FeastCLHookBase} from "../src/FeastCLHookBase.sol";
import {FeastConverter} from "../src/FeastConverter.sol";
import {FeastFactory} from "../src/FeastFactory.sol";
import {FeastFeeLedger} from "../src/FeastFeeLedger.sol";
import {FeastOracle} from "../src/FeastOracle.sol";
import {FeastPlatformSink} from "../src/FeastPlatformSink.sol";
import {FeastPlatformTokenDeployer} from "../src/FeastPlatformTokenDeployer.sol";
import {FeastVesting} from "../src/FeastVesting.sol";
import {PoolId} from "../src/venue/PoolId.sol";
import {PoolKey} from "../src/venue/PoolKey.sol";
import {IFeastCLPoolManager} from "../src/venue/IFeastCLPoolManager.sol";
import {BalanceDelta} from "../src/venue/BalanceDelta.sol";

import {GenesisFixture} from "./utils/GenesisFixture.sol";

/// No admin key anywhere in package 1.
///
/// After genesis, the key that ran it is an address like any other. Every
/// package-1 entry point that is not permissionless is restricted to another
/// CONTRACT — the factory, the hook, the venue — never to a person; this walks
/// every one of them, from the genesis key and from a stranger, and requires
/// each to refuse. `tools/check-boundaries.py` (surface) holds the other half:
/// the list of non-view functions in the built ABI is exactly the list declared
/// there, so a new entry point cannot appear without being classified.
contract FeastAuthorityTest is GenesisFixture {
    function _everyRestrictedEntryPointRefuses(address who) internal {
        (, PoolKey memory key) = (address(0), _anyKey());
        FeastOracle oracle = FeastOracle(address(hook.oracle()));
        FeastConverter converter = FeastConverter(address(hook.converter()));

        // Built before the prank: `_params()` reads the window's close through
        // an external call from v1.6.10, and one between `expectRevert` and the
        // call under test consumes the expectation.
        FeastFactory.GenesisParams memory gp = _params();
        vm.startPrank(who);
        // The key meets the once-only check; anyone else meets the key check.
        vm.expectRevert(who == genesisKey ? FeastFactory.GenesisAlreadyDone.selector : FeastFactory.NotGenesisKey.selector);
        factory.genesis(gp);

        vm.expectRevert(FeastCLHookBase.NotFactory.selector);
        hook.registerPool(key, address(1), who, 0, 0, 1e18, 0, address(0));
        vm.expectRevert(FeastCLHookBase.NotFactory.selector);
        hook.seedLiquidity(key, 0, 200, 1);
        vm.expectRevert(FeastCLHookBase.NotFactory.selector);
        hook.burnUnusedSeed(address(1), 1);
        vm.expectRevert(FeastCLHookBase.NotPoolManager.selector);
        hook.beforeInitialize(who, key, 0);
        vm.expectRevert(FeastCLHookBase.NotPoolManager.selector);
        hook.beforeSwap(who, key, IFeastCLPoolManager.SwapParams(true, 1, 0), "");
        vm.expectRevert(FeastCLHookBase.NotPoolManager.selector);
        hook.afterSwap(who, key, IFeastCLPoolManager.SwapParams(true, 1, 0), BalanceDelta.wrap(0), "");
        vm.expectRevert(FeastCLHookBase.NotVault.selector);
        hook.lockAcquired("");

        vm.expectRevert(FeastFeeLedger.NotRecorder.selector);
        ledger.record(address(1), who, who, address(0), 1);
        vm.expectRevert(FeastOracle.NotWriter.selector);
        oracle.write(PoolId.wrap(bytes32(0)), 0);
        vm.expectRevert(FeastConverter.NotTheHook.selector);
        converter.convert(address(1), 1, new FeastConverter.Hop[](0), who, 0);
        vm.expectRevert(FeastConverter.NotThePool.selector);
        converter.pancakeV3SwapCallback(1, 1, abi.encode(address(1)));
        vm.expectRevert(FeastVesting.NotFactory.selector);
        vesting.createAllocation(address(1), who, 1, 1);
        vm.expectRevert(FeastPlatformTokenDeployer.NotFactory.selector);
        deployer.deploy();
        vm.stopPrank();
    }

    function _anyKey() internal view returns (PoolKey memory k) {
        k.hooks = address(hook);
        k.poolManager = address(pm);
    }

    /// Kills: any restricted entry point that forgets its caller check, and a
    /// genesis that leaves its key with a second use.
    function test_afterGenesisTheGenesisKeyHoldsNoPower() public {
        _genesis();
        _everyRestrictedEntryPointRefuses(genesisKey);
    }

    function test_aStrangerHoldsNoPowerEither() public {
        _genesis();
        _everyRestrictedEntryPointRefuses(stranger);
    }

    /// v1.6.2: the sink's opening — the moment its descending prices may start,
    /// which is the moment the launch window puts the platform coin in anyone's
    /// hands — is the genesis key's one other act, and it is spent by using it.
    /// Kills: an opening anyone can set, or set twice.
    function test_theSinksOpeningIsTheGenesisKeysAndIsSpentByUsingIt() public {
        _genesis();
        FeastPlatformSink real = new FeastPlatformSink(factory.predictPlatformCoin(), genesisKey, address(guardian));

        vm.prank(stranger);
        vm.expectRevert(FeastPlatformSink.NotGenesisKey.selector);
        real.schedule(address(window));

        vm.prank(genesisKey);
        real.schedule(address(window));
        assertEq(real.opensAt(), window.endsAt(), "set once, by the key, and read from the window");

        uint64 set = real.opensAt(); // read first: vm.prank covers one call
        vm.prank(genesisKey);
        vm.expectRevert(abi.encodeWithSelector(FeastPlatformSink.AlreadyScheduled.selector, set));
        real.schedule(address(window));

        vm.prank(stranger);
        vm.expectRevert(FeastPlatformSink.NotGenesisKey.selector);
        real.schedule(address(window));
    }
}
