// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {FeastFactory} from "../../../src/FeastFactory.sol";
import {FeastGenesisGrants} from "../../../src/FeastGenesisGrants.sol";
import {UnitFixture} from "../../utils/UnitFixture.sol";

/// **`genesis-grants-guardian-unchecked`** — `P19` HIGH, Codex family, appendix
/// round on `v1.6.21-audit`, at `src/FeastFactory.sol:498`.
///
/// **This is v1.6.21's own shape, one recipient over.** v1.6.21 taught genesis
/// to ask the TEAM WALLET whose brake it reads, because a wallet built against
/// an address with no code answers every other question and then can never
/// release. It did not ask the same of the GRANTS contract.
/// `_requireRecipient(g.grants, ROLE_GRANTS, coinToBe)` asks the role and the
/// coin and stops there, so a genuine `FeastGenesisGrants` constructed with
/// `guardian = address(0)` is accepted, funded with the whole grants
/// allocation, and every call that reads the brake reverts for ever.
contract GenesisGrantsGuardianTest is UnitFixture {
    function test_genesisRefusesGrantsWithNoGuardian() public {
        _warpTo(windowStart - 1 days);

        address[8] memory empty;
        FeastGenesisGrants rogue =
            new FeastGenesisGrants(feast, address(emissions), TARGET, empty, address(0));

        // Arm the sink first: since v1.6.21 genesis refuses an unarmed coded
        // sink, and that refusal would otherwise satisfy any bare expectation
        // here for the wrong reason.
        vm.prank(genesisKey);
        sink.schedule(address(window));

        FeastFactory.GenesisParams memory p = _genesisParams();
        p.grants = address(rogue);

        vm.prank(genesisKey);
        (bool accepted,) = address(factory).call(abi.encodeCall(FeastFactory.genesis, (p)));

        if (accepted) {
            // The consequence, measured rather than asserted in the abstract:
            // the allocation is in a contract whose every brake read reverts.
            uint256 held = IERC20(feast).balanceOf(address(rogue));
            console2.log("genesis funded the unusable grants contract with:", held);
            assertGt(held, 0, "genesis funded the grants contract");
            vm.prank(multisig);
            (bool ok,) = address(rogue).call(
                abi.encodeWithSignature("assignPartner(uint8,address)", uint8(0), address(0x1A7E))
            );
            assertTrue(ok, "the grants contract genesis funded cannot be operated at all");
        }
        assertFalse(accepted, "genesis accepted a grants contract with no guardian");
    }
}
