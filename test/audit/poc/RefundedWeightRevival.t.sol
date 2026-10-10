// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {FeastFactory} from "../../../src/FeastFactory.sol";
import {FeastGenesis} from "../../../src/FeastGenesis.sol";
import {UnitFixture} from "../../utils/UnitFixture.sol";

/// **`refunded-weight-revival`** — `P12` HIGH, v1.6.19 round, Codex family,
/// against `src/FeastLaunchWindow.sol:464` and `src/FeastFactory.sol:380`.
///
/// `refund` zeroes `committed[account]` and does NOT decrement `total`
/// (`:459-:466`) — which is sound exactly as long as a refunded window can
/// never settle again. `_canSettle` and `_refundable` (`:475-:485`) are written
/// as complements and ARE exclusive at every second, so the Claude unit's
/// NOTHING-FOUND on that pair is correct as far as it reads.
///
/// What neither reads is that the pair is evaluated against a gate that GENESIS
/// can still move. Before genesis the pool has no opener, so `_refundable()` is
/// true from `endsAt` onward and refunds are open. Genesis then registers
/// `opener = window` and `openAt = endsAt + SETTLE_GRACE`, which makes
/// `_canSettle()` true again — the window is revived.
///
/// The only thing standing between the two is `FeastFactory:380`, which admits
/// a window whose close is `>= block.timestamp`. At the boundary second —
/// `windowClose == block.timestamp` — genesis is allowed at the very instant
/// refunds have opened. **The exclusivity holds at every second; the WINDOW's
/// own state does not, and only at that one second can both have happened.**
///
/// `total` then still carries the refunded weight, so the per-committer share
/// is computed against a denominator that over-counts, the `claimedWeight ==
/// total` remainder path can never fire, and the difference is FEAST that no
/// one can ever claim.
///
/// **v1.6.24 closes the class a second way** (AstraSec M-2): `refund` now
/// decrements `total`, as `withdraw` always did, so a refund can no longer
/// leave the denominator counting weight that has left — whatever the order of
/// refunds, genesis and settlement. The boundary check at genesis still holds
/// and still refuses the ceremony at that second; this file keeps both.
contract RefundedWeightRevivalTest is UnitFixture {
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);
    address internal donor = address(0xD0405);

    /// @dev Two equal commits, then Alice refunded at the boundary second. The
    ///      donor's wrap covers the native Alice took away, so `settle` — which
    ///      spends `total`, not the balance — still has the funds to run.
    function _twoCommitsAndARefundAtTheBoundary() internal {
        _warpTo(windowStart + 1);
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        window.commit{value: 1 ether}();
        vm.deal(bob, 1 ether);
        vm.prank(bob);
        window.commit{value: 1 ether}();

        // The sink's opening is scheduled while the window is still open —
        // `schedule` refuses a window that has already closed (sink:218) — and
        // it is genesis-key business that has nothing to do with settlement.
        vm.prank(genesisKey);
        sink.schedule(address(window));

        vm.deal(donor, 1 ether);
        vm.startPrank(donor);
        wbnb.deposit{value: 1 ether}();
        IERC20(address(wbnb)).transfer(address(window), 1 ether);
        vm.stopPrank();

        // Exactly the close. Refunds are open because no genesis has named a
        // pool yet, so the gate has no opener.
        _warpTo(window.endsAt());
        assertEq(window.endsAt(), uint64(block.timestamp), "standing on the boundary second");
        window.refund(alice);
        assertEq(window.committed(alice), 0, "Alice is out");
        assertEq(window.total(), 1 ether, "and, since v1.6.24, `total` no longer counts her");
    }

    /// **The property.** Every unit of a settled tranche is claimable by
    /// someone. Nothing may settle a window against weight that has left.
    function test_everySettledTrancheUnitRemainsClaimable() public {
        _twoCommitsAndARefundAtTheBoundary();

        // Genesis at that same second. `windowClose < block.timestamp` is false
        // when the two are equal, so `FeastFactory:380` lets it through.
        FeastFactory.GenesisParams memory p = _genesisParams();
        vm.prank(genesisKey);
        (bool admitted,) = address(factory).call(abi.encodeCall(FeastFactory.genesis, (p)));

        // Refusing the ceremony at this second is a SAFE answer, and the one
        // the fix gives: nothing was revived, Bob's commit is still his, and no
        // pool was opened. The window simply stays refundable, which is what it
        // already was.
        if (!admitted) {
            window.refund(bob);
            assertEq(IERC20(address(wbnb)).balanceOf(bob), 1 ether, "Bob got his commit back");
            assertFalse(window.settled(), "nothing settled");
            return;
        }

        // The revival: a window that was refundable one line ago settles.
        window.settle();
        assertTrue(window.settled(), "the refunded window settled");

        vm.prank(bob);
        window.claim(bob);

        console2.log("tranche        :", window.tranche());
        console2.log("claimed        :", window.claimedAmount());
        console2.log("stranded       :", window.tranche() - window.claimedAmount());
        assertEq(window.claimedAmount(), window.tranche(), "part of the tranche can never be claimed");
    }

    /// The control that keeps the finding honest: one second later the same
    /// sequence is refused, so this is a BOUNDARY defect and not a standing
    /// one. If this ever fails, the range check is not what is holding.
    function test_oneSecondLaterGenesisIsRefused() public {
        _twoCommitsAndARefundAtTheBoundary();
        _warpTo(window.endsAt() + 1);

        FeastFactory.GenesisParams memory p = _genesisParams();
        // Hoisted: an external call inside `expectRevert`'s argument list is
        // made BEFORE the prank reaches the call under test and consumes it.
        bytes memory expected = abi.encodeWithSelector(
            FeastFactory.WindowCloseOutOfRange.selector, window.endsAt(), block.timestamp, block.timestamp + 30 days
        );
        vm.expectRevert(expected);
        vm.prank(genesisKey);
        factory.genesis(p);
    }
}
