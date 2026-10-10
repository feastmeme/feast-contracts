// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

import {FeastEmissions} from "../src/FeastEmissions.sol";
import {FeastFactory} from "../src/FeastFactory.sol";
import {FeastFeeLedger} from "../src/FeastFeeLedger.sol";
import {FeastGenesis} from "../src/FeastGenesis.sol";
import {FeastGenesisGrants} from "../src/FeastGenesisGrants.sol";
import {FeastHook} from "../src/FeastHook.sol";
import {FeastPlatformSink} from "../src/FeastPlatformSink.sol";
import {FeastPricer} from "../src/FeastPricer.sol";
import {PoolId, PoolIdLibrary} from "../src/venue/PoolId.sol";
import {PoolKey} from "../src/venue/PoolKey.sol";

import {FeastPlatformPool} from "./FeastPlatformPool.sol";
import {FeastScriptChecks} from "./FeastScriptChecks.sol";

/// @notice Package 2's core, at the factory's opening (owner ruling Q25):
///         the timelock, the pricer, emissions, the genesis grants and the sink,
///         all built against the platform coin's predicted address. The launch
///         window and the team's vesting follow at the TGE (`Genesis.s.sol`).
///
///         The sink exists from here but does not start selling from here. It
///         is built with the factory's genesis key, and that key sets its
///         opening once, at genesis, to the moment the launch window closes —
///         the moment the first platform coin can be held by anyone. Until then
///         `open` refuses, because a descent whose takes nobody can pay is a
///         timer and not a market (v1.6.2, rounds 4 and 5). Every asset's first
///         descent therefore begins at that opening or later, whenever someone
///         opens it.
contract DeployPackage2 is Script {
    using PoolIdLibrary for PoolKey;

    struct Inputs {
        FeastFactory factory;
        address multisig;
        uint256 targetNative;
        uint256 factoryOpening;
        address[8] partners;
        FeastPricer.Route[] routes;
    }

    struct Package2 {
        TimelockController timelock;
        FeastPricer pricer;
        FeastEmissions emissions;
        FeastGenesisGrants grants;
        FeastPlatformSink sink;
    }

    function run() external returns (Package2 memory p) {
        FeastScriptChecks.requirePackage2();
        vm.startBroadcast();
        p = deployPackage2(_inputsFromGenesisFile());
        vm.stopBroadcast();
    }

    function deployPackage2(Inputs memory i) public returns (Package2 memory p) {
        FeastHook hook = i.factory.hook();
        // Package 2 reads the guardian package 1 deployed rather than being told
        // one: the same address for the whole system, from the contract that
        // already holds it immutably.
        address guardian = address(hook.guardian());
        address feast = i.factory.predictPlatformCoin();
        address native = i.factory.wrappedNative();
        PoolId feastPoolId = FeastPlatformPool.key(i.factory).toId();

        address[] memory proposers = new address[](1);
        proposers[0] = i.multisig;
        address[] memory executors = new address[](1);
        executors[0] = address(0);
        p.timelock = new TimelockController(FeastGenesis.TIMELOCK_DELAY, proposers, executors, address(0));
        p.pricer = new FeastPricer(native, address(hook.oracle()), hook.poolManager(), feast, feastPoolId, i.routes);
        FeastFeeLedger ledger = hook.ledger();
        p.emissions = new FeastEmissions(
            address(ledger), address(hook), feast, feastPoolId, address(p.timelock), address(p.pricer), ledger.weekOf(i.factoryOpening), guardian
        );
        p.grants = new FeastGenesisGrants(feast, address(p.emissions), i.targetNative, i.partners, guardian);
        p.sink = new FeastPlatformSink(feast, i.factory.genesisKey(), guardian);
    }

    function _inputsFromGenesisFile() internal pure returns (Inputs memory i) {
        i.factory = FeastFactory(FeastGenesis.PACKAGE1_FACTORY);
        i.multisig = FeastGenesis.TEAM_MULTISIG;
        i.targetNative = FeastGenesis.TARGET_NATIVE;
        i.factoryOpening = FeastGenesis.FACTORY_OPENING;
        i.partners = FeastGenesis.partners();
        (address[] memory quotes, address[][] memory pools) = FeastGenesis.pricedRoutes();
        i.routes = new FeastPricer.Route[](quotes.length);
        for (uint256 k = 0; k < quotes.length; k++) {
            i.routes[k] = FeastPricer.Route({quote: quotes[k], pools: pools[k]});
        }
    }
}
