// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {FeastPlatformSink} from "../../../src/FeastPlatformSink.sol";
import {UnitFixture} from "../../utils/UnitFixture.sol";

/// **`unfreeze-is-a-guaranteed-first-take`** — `CA-d3e0eee989`, `P16-claude`
/// LOW, v1.6.20 round, at `src/FeastGuardian.sol:267-284`.
///
/// The claim: `unfreeze` lifts the brake INSIDE the guardian's own transaction,
/// so the guardian is ordered ahead of every other taker in the lift by
/// construction — the ordering v1.6.19 said a LAPSE could only get from a
/// colluding builder. On the sink that is the whole prize: the descent's clock
/// stops while the brake is down (`FeastPlatformSink.sol:330-332`), so after up
/// to 72 hours of the lot asset's price moving outside, the guardian can take
/// first at the pre-freeze price, and only when the move went its way.
///
/// Not an outsider's power — the guardian is the team multisig — so not HIGH,
/// and the bound is the asset's own move over at most 72 hours. The witness
/// below is the lens's sequence: freeze, an hour, a stranger refused, then the
/// guardian's unfreeze and take in one instant; and the next second, a
/// stranger's identical take at the same price — which pins that the answer is
/// a one-second lift, not a price change.
///
/// Measured at `v1.6.21-audit` (`e5c0a77`): the guardian's take in the lift
/// instant SUCCEEDS, buying 25e18 of the lot at the price the freeze held.
contract UnfreezeIsNotAFirstTakeTest is UnitFixture {
    address internal taker = address(0x7A4E5);

    function _fund(address who) internal {
        deal(feast, who, 1e30);
        vm.prank(who);
        IERC20(feast).approve(address(sink), type(uint256).max);
    }

    function test_theGuardianCannotTakeInTheInstantItsOwnUnfreezeLifts() public {
        // RED on v1.6.21-audit and on v1.6.22 (measured): the guardian's take in the second its own unfreeze lifts SUCCEEDS, at the price the freeze held — sink/guardian ordering, not genesis trust; skipped for the owner's separate decision (coordinator 2026-09-25 23:5x)
        vm.skip(true);
        _launch(10e18);
        stock.mint(address(sink), 100e18);
        sink.open(address(stock));
        _advance(150 hours); // far enough down that a quarter of the lot is affordable
        _fund(taker);
        _fund(multisig);
        uint256 held = sink.priceQ128(address(stock));

        vm.prank(multisig);
        guardian.freeze();
        _advance(1 hours);

        // Ordered before the lift: refused, as every take under the brake is.
        vm.prank(taker);
        vm.expectRevert(FeastPlatformSink.Frozen.selector);
        sink.take(address(stock), 25e18, type(uint256).max);

        // The guardian's own lift, and its own take in the same instant.
        vm.prank(multisig);
        guardian.unfreeze();
        vm.prank(multisig);
        (bool took, bytes memory why) =
            address(sink).call(abi.encodeCall(FeastPlatformSink.take, (address(stock), 25e18, type(uint256).max)));
        console2.log("guardian took in the lift instant:", took);
        console2.log("guardian's stock                 :", stock.balanceOf(multisig));
        assertFalse(took, "the guardian took first at the price its own freeze held");
        // Refused BY NAME: a take that failed for any other reason -- an
        // allowance, a cost limit -- would not be the lift refusing it.
        assertEq(why, abi.encodeWithSelector(FeastPlatformSink.Frozen.selector), "refused as the brake, not otherwise");
        assertEq(stock.balanceOf(multisig), 0, "and bought nothing");

        // One second later the lift is everybody's, at the price the freeze held
        // less the one open second that has now run.
        _advance(1);
        uint256 price = sink.priceQ128(address(stock));
        assertLe(price, held, "the freeze raised the price");
        assertGe(price, held - held / 3600, "the freeze discounted the price");
        vm.prank(taker);
        sink.take(address(stock), 25e18, type(uint256).max);
        assertEq(stock.balanceOf(taker), 25e18, "a stranger takes first once the lift is public");
    }
}
