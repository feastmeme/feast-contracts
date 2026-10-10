// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/console2.sol";

import {FeastFactory} from "../../../src/FeastFactory.sol";
import {FeastPlatformSink} from "../../../src/FeastPlatformSink.sol";
import {UnitFixture} from "../../utils/UnitFixture.sol";

/// **`window-fee-to-codeless-sink`** — `CA-8f254aa78e`, `P3-claude` + `P3`
/// (both families) LOW, v1.6.20 round, at `src/FeastLaunchWindow.sol:319`.
///
/// Genesis exempts a sink with no code from every question it asks
/// (`FeastFactory.sol:499-526`) so that the sink could ship after the coin.
/// `settle` then sends the pot's 1% to that address unconditionally, while the
/// hook's own exit refuses the same address until it has code.
///
/// v1.6.21 closed the ARMING half for a sink that exists (`CA-10b38aa83e`): a
/// coded sink must be armed at genesis, because `schedule` refuses a window
/// whose close has passed. The same fact decides the exemption. The window
/// settles at or after its close, so a sink that has no code when the 1%
/// arrives can only be deployed AFTER the close — and then it can never be
/// armed, `open` refuses every lot `NotOpenYet`, and what reached it is
/// stranded. There is no order of events in which an address with no code at
/// settlement becomes a sink that can sell what it was sent.
///
/// Measured at `v1.6.21-audit` (`e5c0a77`): genesis admits `0x51CC` with no
/// code; a 10e18 pot's settlement sends `100000000000000000` wei of wrapped
/// native there; a sink deployed at that address after the close is refused
/// `WindowAlreadyClosed` by `schedule` and `NotOpenYet` by `open`.
contract WindowFeeCodelessSinkTest is UnitFixture {
    address internal constant CODELESS = address(0x51CC);

    function test_theWindowsFeeNeverLeavesForAnAddressThatCanNeverSellIt() public {
        _warpTo(windowStart - 1 days);
        FeastFactory.GenesisParams memory p = _genesisParams();
        p.platformSink = CODELESS;

        vm.prank(genesisKey);
        (bool ok, bytes memory ret) = address(factory).call(abi.encodeCall(FeastFactory.genesis, (p)));
        if (ok) {
            // The harm, end to end, where genesis admits it.
            _warpTo(windowStart + 1);
            address committer = address(0xC0D1);
            vm.deal(committer, 10e18);
            vm.prank(committer);
            window.commit{value: 10e18}();
            _warpTo(window.endsAt());
            window.settle();
            console2.log("fee at the codeless sink:", wbnb.balanceOf(CODELESS));

            // The sink arrives, as the exemption assumed it would — after the close.
            deployCodeTo("FeastPlatformSink.sol:FeastPlatformSink", abi.encode(feast, genesisKey, address(guardian)), CODELESS);
            vm.prank(genesisKey);
            (bool armed, bytes memory why) =
                CODELESS.call(abi.encodeCall(FeastPlatformSink.schedule, (address(window))));
            console2.log("armed after the close   :", armed);
            console2.logBytes(why);
            (bool opened, bytes memory why2) = CODELESS.call(abi.encodeCall(FeastPlatformSink.open, (address(wbnb))));
            console2.log("its lot opened          :", opened);
            console2.logBytes(why2);
        }
        assertFalse(ok, "genesis named a sink with no code, and the window's fee went to it");
        assertEq(
            ret,
            abi.encodeWithSelector(FeastFactory.RecipientHasNoCode.selector, CODELESS),
            "refused as a recipient with no code, like every other recipient"
        );
    }
}
