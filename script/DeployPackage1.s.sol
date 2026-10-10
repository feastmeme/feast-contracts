// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";

import {FeastConstants} from "../src/FeastConstants.sol";
import {FeastConverter} from "../src/FeastConverter.sol";
import {FeastFactory} from "../src/FeastFactory.sol";
import {FeastFeeLedger} from "../src/FeastFeeLedger.sol";
import {FeastGenesis} from "../src/FeastGenesis.sol";
import {FeastHook} from "../src/FeastHook.sol";
import {FeastOracle} from "../src/FeastOracle.sol";
import {FeastPlatformTokenDeployer} from "../src/FeastPlatformTokenDeployer.sol";
import {FeastReferrals} from "../src/FeastReferrals.sol";
import {FeastVesting} from "../src/FeastVesting.sol";
import {FeastGuardian} from "../src/FeastGuardian.sol";

/// @notice Package 1, in the order the README prescribes. Reads every value
///         from `FeastGenesis` and refuses while a placeholder is unset.
///
/// @dev Never broadcast from this repository. `run()` is what a deployer would
///      execute; `deployPackage1` is the same sequence, callable by a test with
///      an explicit genesis key and creator so the wiring can be proved on the
///      pinned fork without touching the placeholder check.
contract DeployPackage1 is Script {
    error Placeholder(string name);
    error Wiring(string what);

    struct Package1 {
        FeastGuardian guardian;
        FeastOracle oracle;
        FeastConverter converter;
        FeastFeeLedger ledger;
        FeastReferrals referrals;
        FeastHook hook;
        FeastVesting vesting;
        FeastPlatformTokenDeployer platformTokenDeployer;
        FeastFactory factory;
    }

    /// @notice Refuse while any package-1 placeholder is unset.
    function check() public pure {
        if (FeastGenesis.GENESIS_KEY == address(0)) revert Placeholder("GENESIS_KEY");
        if (FeastGenesis.TEAM_MULTISIG == address(0)) revert Placeholder("TEAM_MULTISIG");
    }

    function run() external returns (Package1 memory p) {
        check();
        vm.startBroadcast();
        p = deployPackage1(FeastGenesis.GENESIS_KEY, msg.sender);
        vm.stopBroadcast();
    }

    /// @param creator the address whose nonce the CREATEs consume: the
    ///        broadcaster under `run`, this contract under a test.
    function deployPackage1(address genesisKey, address creator) public returns (Package1 memory p) {
        uint64 n = vm.getNonce(creator);
        // The guardian goes first, so its address is a plain constructor
        // argument everywhere else rather than a prediction. Every later index
        // shifts by one. The referral registry (v1.6.26) goes immediately
        // before the hook, its one reader, and shifts every later index again.
        address hook = vm.computeCreateAddress(creator, n + 5);
        address factory = vm.computeCreateAddress(creator, n + 8);

        p.guardian = new FeastGuardian(FeastGenesis.TEAM_MULTISIG, factory);
        p.oracle = new FeastOracle(hook);
        p.converter = new FeastConverter(FeastGenesis.V3_FACTORY, FeastGenesis.WRAPPED_NATIVE, hook);
        p.ledger = new FeastFeeLedger(hook);
        p.referrals = new FeastReferrals();
        p.hook = new FeastHook(
            FeastGenesis.CL_POOL_MANAGER,
            FeastGenesis.VAULT,
            factory,
            address(p.oracle),
            address(p.ledger),
            address(p.converter),
            address(p.guardian),
            address(p.referrals),
            tipFloors()
        );
        p.vesting = new FeastVesting(factory, address(p.guardian));
        p.platformTokenDeployer = new FeastPlatformTokenDeployer(factory);
        p.factory = new FeastFactory(
            FeastGenesis.CL_POOL_MANAGER,
            FeastGenesis.VAULT,
            address(p.hook),
            address(p.vesting),
            address(p.platformTokenDeployer),
            FeastGenesis.WRAPPED_NATIVE,
            genesisKey
        );
        if (address(p.hook) != hook) revert Wiring("hook");
        if (address(p.factory) != factory) revert Wiring("factory");
    }

    /// @notice The hook's tip-floor table: wrapped native at
    ///         `FeastConstants.TIP_FLOOR_NATIVE`, then every stock row of
    ///         `FeastGenesis.tipFloors()` (v1.6.23).
    function tipFloors() public pure returns (FeastHook.TipFloor[] memory rows) {
        (address[] memory quotes, uint256[] memory floors) = FeastGenesis.tipFloors();
        if (floors.length != quotes.length) revert Wiring("tip floors");
        rows = new FeastHook.TipFloor[](quotes.length + 1);
        rows[0] = FeastHook.TipFloor({quote: FeastGenesis.WRAPPED_NATIVE, floor: FeastConstants.TIP_FLOOR_NATIVE});
        for (uint256 i = 0; i < quotes.length; i++) {
            rows[i + 1] = FeastHook.TipFloor({quote: quotes[i], floor: floors[i]});
        }
    }
}
