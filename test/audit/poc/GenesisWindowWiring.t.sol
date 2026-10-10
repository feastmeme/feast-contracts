// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {FeastFactory} from "../../../src/FeastFactory.sol";
import {FeastLaunchWindow} from "../../../src/FeastLaunchWindow.sol";
import {UnitFixture} from "../../utils/UnitFixture.sol";

/// **`genesis-window-wiring`** — HIGH, Codex family, appendix round on
/// `v1.6.21-audit`, at `src/FeastFactory.sol:471`.
///
/// Genesis asks the window its role, its coin, its close, its opening liquidity
/// and — since v1.6.21 — its `poolKey()`. It does not ask which FACTORY it was
/// built against. A genuine window wired to the wrong factory answers every
/// question correctly, takes the 60% allocation, and cannot settle: its
/// `platformOpening()` read goes to a contract that has none.
contract GenesisWindowWiringTest is UnitFixture {
    function test_genesisRefusesAWindowWiredToAnotherFactory() public {
        _warpTo(windowStart - 1 days);

        // The genuine window in every respect genesis asks about, wired to a
        // contract that is not the factory.
        window = new FeastLaunchWindow(
            address(wbnb), feast, address(vault), address(pm), address(hook),
            address(vesting), feastKey, uint64(windowStart)
        );

        vm.prank(genesisKey);
        sink.schedule(address(window));

        FeastFactory.GenesisParams memory p = _genesisParams();
        vm.prank(genesisKey);
        (bool accepted,) = address(factory).call(abi.encodeCall(FeastFactory.genesis, (p)));

        if (accepted) {
            uint256 held = IERC20(feast).balanceOf(address(window));
            console2.log("genesis funded the mis-wired window with:", held);
            assertGt(held, 0, "genesis funded the window");

            // The no-commit path, which is the one that needs no buyer at all.
            _warpTo(window.endsAt());
            (bool settled,) = address(window).call(abi.encodeWithSignature("settle()"));
            assertTrue(settled, "the window genesis funded can never settle, and the allocation has no exit");
        }
        assertFalse(accepted, "genesis accepted a window wired to another factory");
    }
}
