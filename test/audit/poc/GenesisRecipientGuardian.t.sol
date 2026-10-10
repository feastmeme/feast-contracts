// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {FeastEmissions} from "../../../src/FeastEmissions.sol";
import {FeastFactory} from "../../../src/FeastFactory.sol";
import {FeastGenesisGrants} from "../../../src/FeastGenesisGrants.sol";
import {FeastGuardian} from "../../../src/FeastGuardian.sol";
import {FeastPlatformSink} from "../../../src/FeastPlatformSink.sol";
import {PoolId} from "../../../src/venue/PoolId.sol";
import {UnitFixture} from "../../utils/UnitFixture.sol";

/// **`genesis-does-not-ask-grants-which-guardian`** — `CA-9abd1b1a68`,
/// `P19-claude` LOW, v1.6.20 round, at `src/FeastFactory.sol:437`.
///
/// Both of the grants' slot paths need its guardian's clock, which only the
/// factory's own guardian is ever given, so an empty slot in a grants contract
/// bound to another guardian can neither be filled nor burned. v1.6.21 asked the
/// TEAM WALLET whose brake it obeys; the other three contracts genesis pays or
/// names — grants, emissions and the sink — gate every exit on
/// `guardian.isFrozenAll()` too, and each is asked now. A guardian that is not
/// the platform's is somebody else's brake on that allocation, or, with no code
/// behind it, a revert on every exit for ever.
///
/// Same shape as its sibling file: genesis through a low-level call, the harm
/// logged where the tag admits it, the named refusal asserted.
///
/// Measured at `v1.6.21-audit` (`e5c0a77`): all three admitted. The grants
/// contract bound to another guardian took `8_000_000e18`; that guardian's clock
/// never started, and 100 days later `burnUnfilledSlot(6)` reverted
/// `AssignmentWindowNotOpen`.
contract GenesisRecipientGuardianTest is UnitFixture {
    function _sixOfEight() internal pure returns (address[8] memory six) {
        for (uint256 i = 0; i < 6; i++) six[i] = address(uint160(0xBB00 + i));
    }

    function _emissions(address hook_, PoolId poolId, address guardian_) internal returns (FeastEmissions) {
        return new FeastEmissions(
            address(ledger), hook_, feast, poolId, address(timelock), address(pricer), ledger.weekOf(OPENING), guardian_
        );
    }

    /// The fixture's own ceremony, up to the genesis call: the day before the
    /// window, the sink armed.
    function _ready() internal returns (FeastFactory.GenesisParams memory p) {
        _warpTo(windowStart - 1 days);
        vm.prank(genesisKey);
        sink.schedule(address(window));
        p = _genesisParams();
    }

    function _genesisCall(FeastFactory.GenesisParams memory p) internal returns (bool ok, bytes memory ret) {
        vm.prank(genesisKey);
        (ok, ret) = address(factory).call(abi.encodeCall(FeastFactory.genesis, (p)));
    }

    /// The window settles and the pool opens, so every claim that can ever open
    /// has opened.
    function _launchAfterGenesis() internal {
        _warpTo(windowStart + 1);
        address committer = address(0xC0D1);
        vm.deal(committer, 10e18);
        vm.prank(committer);
        window.commit{value: 10e18}();
        _warpTo(window.endsAt());
        window.settle();
        _warpTo(window.endsAt() + 1 days);
    }

    // --- CA-9abd1b1a68: which brake the grants, emissions and sink obey --------

    function test_genesisRefusesAGrantsContractReadingAnotherGuardian() public {
        FeastFactory.GenesisParams memory p = _ready();
        FeastGuardian other = new FeastGuardian(multisig, address(factory));
        FeastGenesisGrants g = new FeastGenesisGrants(feast, address(emissions), TARGET, _sixOfEight(), address(other));
        p.grants = address(g);

        (bool ok, bytes memory ret) = _genesisCall(p);
        if (ok) {
            console2.log("grants held         :", IERC20(feast).balanceOf(address(g)));
            console2.log("its clock started   :", other.clockStarted());
            _warpTo(block.timestamp + 100 days);
            (bool burned, bytes memory why) = address(g).call(abi.encodeCall(FeastGenesisGrants.burnUnfilledSlot, (6)));
            console2.log("slot 6 burned at 100 days:", burned);
            console2.logBytes(why);
        }
        assertFalse(ok, "genesis paid grants that answer to another guardian");
        assertEq(
            ret, abi.encodeWithSignature("GrantsGuardianMismatch(address,address)", address(other), address(guardian))
        );
    }

    /// The same question of the emissions contract: every one of its exits is
    /// `_requireUnfrozen()`, and a guardian that is not the platform's is
    /// somebody else's brake on 14.2% of the supply — or, with no code at all,
    /// a revert on every exit for ever.
    function test_genesisRefusesAnEmissionsReadingAnotherGuardian() public {
        FeastFactory.GenesisParams memory p = _ready();
        FeastGuardian other = new FeastGuardian(multisig, address(factory));
        FeastEmissions wrong = _emissions(address(hook), feastPoolId, address(other));
        p.emissions = address(wrong);
        p.grants = address(new FeastGenesisGrants(feast, address(wrong), TARGET, partnerList, address(guardian)));

        (bool ok, bytes memory ret) = _genesisCall(p);
        assertFalse(ok, "genesis paid an emissions that answers to another guardian");
        assertEq(
            ret, abi.encodeWithSignature("EmissionsGuardianMismatch(address,address)", address(other), address(guardian))
        );
    }

    /// And of the sink, whose `open` and `take` are how every fee the platform
    /// ever earns becomes a burn. Armed, so the arming check is passed and this
    /// is the question that answers.
    function test_genesisRefusesASinkReadingAnotherGuardian() public {
        FeastGuardian other = new FeastGuardian(multisig, address(factory));
        FeastPlatformSink wrong = new FeastPlatformSink(feast, genesisKey, address(other));
        _warpTo(windowStart - 1 days);
        vm.prank(genesisKey);
        wrong.schedule(address(window));
        FeastFactory.GenesisParams memory p = _genesisParams();
        p.platformSink = address(wrong);

        (bool ok, bytes memory ret) = _genesisCall(p);
        assertFalse(ok, "genesis named a sink that answers to another guardian");
        assertEq(ret, abi.encodeWithSignature("SinkGuardianMismatch(address,address)", address(other), address(guardian)));
    }
}
