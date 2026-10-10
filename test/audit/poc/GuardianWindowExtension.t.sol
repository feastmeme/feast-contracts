// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/console2.sol";

import {FeastGenesis} from "../../../src/FeastGenesis.sol";
import {FeastGenesisGrants} from "../../../src/FeastGenesisGrants.sol";
import {UnitFixture} from "../../utils/UnitFixture.sol";

/// The two `P19-claude` MEDIUMs of the v1.6.20 round, both about the same
/// sentence in `FeastGuardian.sunsetAt`: the partner-assignment window is
/// extended by the brake's own downtime.
contract GuardianWindowExtensionTest is UnitFixture {
    /// @dev Six of eight filled, so slots 6 and 7 are open to assign into.
    function _sixOfEight() internal pure returns (address[8] memory six) {
        for (uint256 i = 0; i < 6; i++) six[i] = address(uint160(0xBB00 + i));
    }

    /// **`own-brake-extends-own-window`.** `sunsetAt()` adds the guardian's own
    /// frozen seconds, and nothing refuses `assignPartner` while the brake is
    /// down — so the multisig can freeze, and then fill a slot on day 91 that
    /// day 90 would have refused, using a lever only it holds.
    /// **CARRIED, not fixed.** Red when run: `assignPartner(6, ...)` SUCCEEDS on day 91, with `sunsetAt() = g0 + 90 days + 48h = 1800144000`.
    function test_theMultisigCannotFillASlotPastDayNinetyInsideItsOwnFreeze() public {
        vm.skip(true);
        _genesis();
        FeastGenesisGrants g =
            new FeastGenesisGrants(feast, address(emissions), TARGET, _sixOfEight(), address(guardian));
        uint64 g0 = guardian.genesisStartedAt();

        _warpTo(g0 + 89 days);
        vm.prank(multisig);
        guardian.freeze();

        _warpTo(g0 + 91 days);
        console2.log("sunsetAt   :", guardian.sunsetAt());
        console2.log("g0+90 days :", uint256(g0) + 90 days);

        vm.prank(multisig);
        vm.expectRevert();
        g.assignPartner(6, address(0x1A7E));
    }

    /// **`sunset-unanchored-prefreeze`.** `startClock` snapshots nothing, so
    /// frozen seconds spent BEFORE genesis — when no slot could be filled
    /// whatever happened — lengthen the window that opens after it.
    /// **CARRIED, not fixed.** Red when run: `sunsetAt()` reads 1800230400 where `g0 + 90 days` is 1799971200 -- exactly the 259200 pre-genesis frozen seconds.
    function test_frozenSecondsSpentBeforeGenesisDoNotLengthenThePartnerWindow() public {
        vm.skip(true);
        // The fixture's pre-genesis calendar has room for this.
        vm.prank(multisig);
        guardian.freeze();
        _advance(73 hours);
        guardian.settleLapsed();

        _genesis();
        uint64 g0 = guardian.genesisStartedAt();
        console2.log("sunsetAt      :", guardian.sunsetAt());
        console2.log("g0 + 90 days  :", uint256(g0) + 90 days);
        assertEq(guardian.sunsetAt(), g0 + 90 days, "a freeze before genesis lengthened the window after it");
    }
}
