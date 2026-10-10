// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";

import {FeastFactory} from "../src/FeastFactory.sol";
import {FeastGenesis} from "../src/FeastGenesis.sol";
import {FeastHook} from "../src/FeastHook.sol";
import {FeastLaunchWindow} from "../src/FeastLaunchWindow.sol";
import {FeastPlatformSink} from "../src/FeastPlatformSink.sol";
import {FeastTeamVesting} from "../src/FeastTeamVesting.sol";
import {PoolKey} from "../src/venue/PoolKey.sol";

import {FeastPlatformPool} from "./FeastPlatformPool.sol";
import {FeastScriptChecks} from "./FeastScriptChecks.sol";

/// @notice The TGE, when the owner decides it (Q25): deploy the launch window
///         and the team's vesting wallet, then the one genesis call. The window
///         closes on a Monday 00:00 UTC; the pool opens one hour later.
contract Genesis is Script {
    struct Inputs {
        FeastFactory factory;
        address emissions;
        address grants;
        address sink;
        address beneficiary;
        uint64 windowStart;
        uint160 sqrtPriceX96;
        bytes32 metadataHash;
    }

    struct Launched {
        FeastLaunchWindow window;
        FeastTeamVesting teamVesting;
        address platformCoin;
    }

    /// @dev The genesis key broadcasts this. **One number, from v1.6.12**: the
    ///      price the platform pool opens at if nobody commits to the launch
    ///      window. The tick is floored from it inside `genesis`, and the
    ///      liquidity is derived from the holding at settlement — neither is
    ///      typed, so neither can disagree with the price. Two arguments this
    ///      script used to take, computed off chain with the venue's tick maths
    ///      and signed blind, are gone.
    function run(uint160 sqrtPriceX96) external returns (Launched memory l) {
        FeastScriptChecks.requireGenesis();
        Inputs memory i = Inputs({
            factory: FeastFactory(FeastGenesis.PACKAGE1_FACTORY),
            emissions: FeastGenesis.PACKAGE2_EMISSIONS,
            grants: FeastGenesis.PACKAGE2_GRANTS,
            sink: FeastGenesis.PACKAGE2_SINK,
            beneficiary: FeastGenesis.TEAM_BENEFICIARY,
            windowStart: uint64(FeastGenesis.WINDOW_START),
            sqrtPriceX96: sqrtPriceX96,
            metadataHash: FeastGenesis.PLATFORM_METADATA_HASH
        });
        vm.startBroadcast();
        l = launch(i);
        vm.stopBroadcast();
    }

    /// @dev The launch is not finished while the sink is unscheduled; a script
    ///      that broadcast genesis and stopped there would leave it shut.
    error SinkNotScheduled(address sink, uint64 expected);

    function launch(Inputs memory i) public returns (Launched memory l) {
        FeastHook hook = i.factory.hook();
        PoolKey memory key = FeastPlatformPool.key(i.factory);
        l.window = new FeastLaunchWindow(
            i.factory.wrappedNative(),
            i.factory.predictPlatformCoin(),
            i.factory.vault(),
            hook.poolManager(),
            address(hook),
            address(i.factory),
            key,
            i.windowStart
        );
        l.teamVesting = new FeastTeamVesting(
            i.beneficiary,
            l.window.endsAt(),
            i.factory.predictPlatformCoin(),
            address(i.factory.hook().guardian())
        );
        // And the sink's opening: it may sell only once the window named here
        // has closed, because until then the coin every take is paid in is in
        // nobody's hands (v1.6.2, rounds 5 and 6). The sink was built at the
        // factory's opening against this coin's predicted address, so it is
        // here to be told.
        //
        // This is its own transaction, not part of the one that creates the
        // coin: a script broadcasts each call separately, and the genesis key
        // is an address, not a contract that could batch them (round 7, both
        // lenses, correcting a claim this pass had made).
        //
        // **It now runs BEFORE genesis, and that is v1.6.21's doing.** This
        // comment used to end by observing that if the call did not land before
        // `l.window.endsAt()` the window could never be scheduled, and that the
        // check below was what made an omission loud instead of silent. The
        // v1.6.20 round's `P12-claude` pointed out what the observation left
        // open: nothing on CHAIN enforced it, so a ceremony that skipped this
        // step still produced a live platform whose sink could never open and
        // whose fees were stranded on arrival. Genesis now asks a coded sink
        // whether it is armed, so the order here is not a convention any more —
        // it is the only order the factory will accept.
        FeastPlatformSink(i.sink).schedule(address(l.window));
        if (FeastPlatformSink(i.sink).opensAt() != l.window.endsAt()) {
            revert SinkNotScheduled(i.sink, l.window.endsAt());
        }

        (l.platformCoin,) = i.factory.genesis(
            FeastFactory.GenesisParams({
                window: address(l.window),
                openAt: uint64(l.window.endsAt() + FeastGenesis.SETTLE_GRACE),
                teamVesting: address(l.teamVesting),
                emissions: i.emissions,
                grants: i.grants,
                platformSink: i.sink,
                sqrtPriceX96: i.sqrtPriceX96,
                metadataHash: i.metadataHash
            })
        );

    }
}
