// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FeastGenesisGrants} from "../../../src/FeastGenesisGrants.sol";
import {FeastGuardian} from "../../../src/FeastGuardian.sol";
import {PoolId} from "../../../src/venue/PoolId.sol";
import {UnitFixture} from "../../utils/UnitFixture.sol";

/// PoC for the v1.6.12 round's HIGH `guardian-sunset-wrong-epoch` /
/// `partner-window-starts-before-genesis` / `sunset-clock-from-deploy` /
/// `assignment-window-not-from-genesis` — FOUR units across BOTH families
/// (`P17`, `P19b`, `P17-claude`, `P19-claude`) at `src/FeastGuardian.sol:90-92`.
///
///     constructor(address guardian_) {
///         guardian   = guardian_;
///         genesisAt  = uint64(block.timestamp);   // <- package-1 DEPLOY time
///     }
///
/// Genesis is a separate, later act. The README's own deploy table puts package
/// 1 "with the factory" and genesis at "TGE — when the owner decides". The
/// design says the sunset is measured "from the immutable genesis time". It is
/// measured from the constructor, and the field is NAMED `genesisAt`, which is
/// what kept it invisible.
///
/// Both 90-day windows are therefore wrong by however long the owner waits:
///
///   - the brake can be part or wholly spent before the platform coin exists;
///   - the partner-assignment window shrinks by the same amount, while
///     `burnUnfilledSlot` — which opens when that window closes — opens EARLIER,
///     so an empty grant can be destroyed before the promised window has run.
///
/// Measured on this fixture before the fix: the guardian's sunset falls EIGHT
/// DAYS BEFORE the first emission week's claim expiry, so the brake is dead
/// before any claim window it might need to protect has closed.
contract GuardianClockStartsAtGenesisPoC is UnitFixture {
    /// The sunset is ninety days after GENESIS, not after an earlier deploy.
    ///
    /// @dev The fixture cannot simply wait sixty days before calling genesis —
    ///      a v1.6.10 fix bounds the launch window's close to within fourteen
    ///      days of genesis, so the wait has to be the one the fixture's own
    ///      calendar already contains. It is smaller than a real TGE delay and
    ///      the finding is the same: the two instants are not the same instant.
    function test_theNinetyDaysRunFromGenesis() public {
        uint64 deployedAt = guardian.genesisStartedAt();
        _genesis();
        uint256 genesisAt = block.timestamp;
        assertGt(genesisAt, deployedAt, "genesis is later than the deploy, as the recipe says it is");

        assertEq(
            uint256(guardian.sunsetAt()),
            genesisAt + 90 days,
            "the brake's ninety days are counted from the deploy, not from genesis"
        );
    }

    /// And the partner window with it: a slot must still be fillable on day 89
    /// AFTER genesis, whenever genesis happened.
    function test_aSlotIsStillFillableOnDayEightyNineAfterGenesis() public {
        _genesis();
        uint256 genesisAt = block.timestamp;

        address[8] memory some;
        for (uint256 i = 0; i < 6; i++) some[i] = partnerList[i];
        FeastGenesisGrants g = new FeastGenesisGrants(feast, address(emissions), TARGET, some, address(guardian));

        _warpTo(genesisAt + 89 days);
        vm.prank(multisig);
        g.assignPartner(6, address(0x1A7E));
        assertEq(g.partners()[6], address(0x1A7E), "a partner found on day 89 can still be given their slot");
    }

    /// The mirror: the unfilled-slot burn must not open early either.
    function test_anEmptySlotCannotBeBurnedBeforeTheWindowHasRun() public {
        _genesis();
        uint256 genesisAt = block.timestamp;

        address[8] memory some;
        for (uint256 i = 0; i < 6; i++) some[i] = partnerList[i];
        FeastGenesisGrants g = new FeastGenesisGrants(feast, address(emissions), TARGET, some, address(guardian));

        _warpTo(genesisAt + 89 days);
        vm.expectRevert();
        g.burnUnfilledSlot(6);
    }

    /// And the brake is alive for the whole ninety days after genesis, rather
    /// than having quietly spent part of them before the coin existed.
    function test_theBrakeIsAliveForNinetyDaysAfterGenesis() public {
        _genesis();
        uint256 genesisAt = block.timestamp;
        _warpTo(genesisAt + 89 days);

        vm.prank(multisig);
        guardian.freeze();
        assertTrue(guardian.isFrozenAll(), "the brake is still there when it is most likely to be needed");
    }
}
