// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {FeastFactory} from "../../../src/FeastFactory.sol";
import {FeastGenesis} from "../../../src/FeastGenesis.sol";
import {FeastLaunchWindow} from "../../../src/FeastLaunchWindow.sol";
import {IFeastCLPoolManager} from "../../../src/venue/IFeastCLPoolManager.sol";
import {UnitFixture} from "../../utils/UnitFixture.sol";

/// AstraSec M-2, "Potential permanent FEAST lock-up in
/// `FeastLaunchWindow::settle()`".
///
/// The window holds `POOL_BPS = 6000` bps of the platform supply — 6e26 of 1e27
/// — and `settle()` is the ONLY function that can move it. At e5c0a77 it was
/// callable only in `[endsAt, openAt)`, one hour, and nothing — no rescue, no
/// sweep, no guardian power — could move the coin after it. With
/// `(num, den) = coinIsCurrency0 ? (net, sold) : (sold, net)` and
/// `sold = 3e26`, the clearing-price guard
///
///     if (num / den >= 1 << 64) revert ClearingPriceUnrepresentable(num, den);
///
/// made one wei in the coin-as-currency1 ordering strand 60% of the supply, and
/// in the other ordering the same wei skipped the zero-commit branch and bought
/// the whole tranche, 30% of the supply. A freeze across the hour stranded it
/// with nobody at fault.
///
/// **Fixed in v1.6.24** (coordinator ruling of 2026-10-01 on plan 733):
///
///   - a pot below `FeastGenesis.MIN_POT`, or whose price cannot be
///     represented, is NO PARTICIPATION: `settle` opens the pool single-sided
///     at the genesis opening, sells nothing, and every commit is refundable —
///     in both orderings; both arithmetic errors are gone;
///   - `settle` has no deadline: the coin can always reach the pool. The
///     AUCTION may expire, at `abandonAt() = endsAt + ABANDON_AFTER +
///     guardian.frozenSeconds()`, after which `settle` takes the
///     no-participation branch and refunds open;
///   - `settle` refuses under an ALL freeze; `refund` decrements `total`.
///
/// Every scenario the coordinator's PoC measured is kept below as a regression,
/// in the ordering it was measured in, and asserts what happens now.
abstract contract M2Base is UnitFixture {
    address internal constant ATTACKER = address(0xA77AC);
    address internal constant HONEST = address(0x40E57);

    function _coinHeld() internal view returns (uint256) {
        return IERC20(feast).balanceOf(address(window));
    }

    function _sold() internal view returns (uint256) {
        return _coinHeld() * FeastGenesis.WINDOW_TRANCHE_BPS / FeastGenesis.BPS;
    }

    function _net(uint256 total) internal pure returns (uint256) {
        return total - total / 100;
    }

    function _commitAs(address who, uint256 amount) internal {
        vm.deal(who, amount);
        vm.prank(who);
        window.commit{value: amount}();
    }

    function _openWindowAndCommit(uint256 amount) internal {
        _genesis();
        _warpTo(windowStart + 1);
        _commitAs(ATTACKER, amount);
    }

    function _poolIsUninitialised() internal view returns (bool) {
        (uint160 sqrtPriceX96,,,) = IFeastCLPoolManager(address(pm)).getSlot0(feastPoolId);
        return sqrtPriceX96 == 0;
    }

    /// @dev What "no participation" means, asserted whole: settled, nothing
    ///      sold, no clearing price, the pool open, the 60% all in it, nothing
    ///      to claim — and `who` refunded every wei of `committed`.
    function _assertNothingSoldAndRefunded(address who, uint256 committed_) internal {
        assertTrue(window.settled(), "settled");
        assertEq(window.tranche(), 0, "nothing sold");
        assertEq(window.clearingPrice(), 0, "no clearing price");
        assertFalse(_poolIsUninitialised(), "the platform pool opened");
        assertEq(_coinHeld(), 0, "none of the window's 60% is left behind");
        vm.expectRevert(FeastLaunchWindow.NothingWasSold.selector);
        window.claim(who);
        assertEq(window.refund(who), committed_, "every wei committed comes back");
    }

    // --- in both orderings ---------------------------------------------------

    /// (a) The zero-commit fallback exists and opens the pool, emptying the
    /// window — the branch every non-clearing pot now takes.
    function test_theZeroCommitFallbackOpensThePoolAndEmptiesTheWindow() public {
        _genesis();
        _warpTo(window.endsAt());
        assertTrue(_poolIsUninitialised(), "precondition: the pool has not opened yet");
        window.settle();
        assertTrue(window.settled(), "the no-commit path settles");
        assertFalse(_poolIsUninitialised(), "and the platform pool is initialised");
        assertEq(_coinHeld(), 0, "nothing is left in the window");
    }

    /// The floor from both sides: one wei under `MIN_POT` sells nothing; a pot
    /// of exactly `MIN_POT` clears the whole tranche at that price.
    function test_theFloorFromBothSides() public {
        _genesis();
        _warpTo(windowStart + 1);
        uint256 snap = vm.snapshotState();

        _commitAs(HONEST, FeastGenesis.MIN_POT - 1);
        _warpTo(window.endsAt());
        window.settle();
        _assertNothingSoldAndRefunded(HONEST, FeastGenesis.MIN_POT - 1);

        vm.revertToState(snap);
        _commitAs(HONEST, FeastGenesis.MIN_POT);
        _warpTo(window.endsAt());
        window.settle();
        assertGt(window.tranche(), 0, "a pot of exactly MIN_POT clears");
        assertEq(window.claim(HONEST), window.tranche(), "and its committer receives the whole tranche");
    }

    /// The auction's end from both sides, to the second: at `abandonAt - 1` a
    /// clearing pot still clears; at `abandonAt` it sells nothing and refunds.
    function test_theAuctionIsAbandonedExactlyAtAbandonAt() public {
        _openWindowAndCommit(10 ether);
        uint256 abandon = window.abandonAt();
        assertEq(abandon, window.endsAt() + FeastGenesis.ABANDON_AFTER, "a week after the close, with no freeze");
        uint256 snap = vm.snapshotState();

        _warpTo(abandon - 1);
        vm.expectRevert(FeastLaunchWindow.NotRefundable.selector);
        window.refund(ATTACKER);
        window.settle();
        assertGt(window.tranche(), 0, "one second before, the auction clears");

        vm.revertToState(snap);
        _warpTo(abandon);
        window.settle();
        _assertNothingSoldAndRefunded(ATTACKER, 10 ether);
    }

    /// Unsettled refunds open at `abandonAt` and the coin still reaches the
    /// pool afterwards. `total` falls with every refund, so it is always the
    /// live pot.
    function test_refundsBeforeSettlementLeaveTheCoinAWayOut() public {
        _openWindowAndCommit(10 ether);
        _commitAs(HONEST, 5 ether);
        _warpTo(window.abandonAt());
        assertEq(window.refund(ATTACKER), 10 ether, "refunds open at abandonAt");
        assertEq(window.total(), 5 ether, "and the pot no longer counts the refunded weight");
        window.settle();
        _assertNothingSoldAndRefunded(HONEST, 5 ether);
        assertEq(window.total(), 0, "the pot is empty");
    }

    /// A freeze holds `settle` — the one irreversible act — and moves
    /// `abandonAt` by exactly its frozen seconds, so the brake can never push an
    /// auction into abandonment. Measured with a freeze that runs out by itself.
    function test_aFreezeHoldsSettleAndMovesAbandonAtByItsFrozenSeconds() public {
        _openWindowAndCommit(10 ether);
        _warpTo(window.endsAt());
        uint256 before_ = window.abandonAt();
        vm.prank(multisig);
        guardian.freeze();
        vm.expectRevert(FeastLaunchWindow.Frozen.selector);
        window.settle();

        uint64 lapse = guardian.frozenUntil();
        _warpTo(uint256(lapse) + 1);
        assertEq(window.abandonAt(), before_ + (uint256(lapse) - window.endsAt()), "moved by the frozen seconds");
        window.settle();
        assertGt(window.tranche(), 0, "and the auction still clears after the brake");
    }
}

/// The fixture's CREATE2 platform coin sorts BELOW the wrapped native, so
/// `coinIsCurrency0` is true and `(num, den) = (net, sold)`. The clearing-price
/// guard could not fire here; what the same dust commit did instead was buy the
/// tranche.
contract M2CoinAsCurrency0 is M2Base {
    function test_preconditionTheCoinSortedBelowTheQuote() public view {
        assertLt(uint160(feast), uint160(address(wbnb)), "this suite is the coinIsCurrency0 ordering");
    }

    /// The two constants the owner confirms at the genesis-parameter review,
    /// stated: changing either is a one-constant edit in `FeastGenesis`, and
    /// this test is where the edit shows.
    function test_theTwoConstantsTheOwnerConfirms() public pure {
        assertEq(FeastGenesis.MIN_POT, 1 ether, "MIN_POT: the smallest pot that counts as participation");
        assertEq(FeastGenesis.ABANDON_AFTER, 7 days, "ABANDON_AFTER: how long after the close the auction may clear");
    }

    /// **The finding's other half, as a regression.** One wei committed in the
    /// window skipped the zero-commit branch, cleared at `p* = 1 wei / 3e26`,
    /// and `claim` paid the sole committer 3e26 FEAST — 30% of the supply. It
    /// now buys nothing: the pool opens single-sided, the whole 60% goes into
    /// it, and the wei comes back.
    function test_oneWeiBuysThirtyPercentOfTheSupplyInThisOrdering() public {
        _openWindowAndCommit(1);
        _warpTo(window.endsAt());
        window.settle();
        _assertNothingSoldAndRefunded(ATTACKER, 1);
        assertEq(IERC20(feast).balanceOf(ATTACKER), 0, "not one unit of the tranche for the wei");
    }

    /// (c) The hour used to be the whole of the opportunity: past `openAt` the
    /// window could never settle again. It can now — the next day, or a year
    /// later.
    function test_settleIsPermanentlyUnavailableOnceTheGraceHourPasses() public {
        _genesis();
        uint256 snap = vm.snapshotState();
        _warpTo(window.endsAt() + FeastGenesis.SETTLE_GRACE);
        window.settle();
        assertFalse(_poolIsUninitialised(), "past the hour, the platform pool opens");
        assertEq(_coinHeld(), 0, "with the whole 60% in it");

        vm.revertToState(snap);
        _warpTo(window.endsAt() + 365 days);
        window.settle();
        assertEq(_coinHeld(), 0, "and a year later, the same");
    }
}

/// The ordering the finding is written for: the platform coin sorts ABOVE the
/// wrapped native, so `coinIsCurrency0` is false and `(num, den) = (sold, net)`.
///
/// The coin's address is CREATE2 from the token deployer, so the ordering is a
/// coin-flip the recipe does not control. The fixture is reused unchanged; the
/// only intervention is bumping this test contract's nonce before `setUp`,
/// which shifts every CREATE address (the deployer's, hence the coin's) to a
/// draw where the coin sorts above the quote. Asserted as a precondition below,
/// so the suite cannot silently become the other ordering.
contract M2CoinAsCurrency1 is M2Base {
    constructor() {
        vm.setNonce(address(this), 13);
    }

    function test_preconditionTheCoinSortedAboveTheQuote() public view {
        assertGt(uint160(feast), uint160(address(wbnb)), "this suite is the coinIsCurrency1 ordering");
    }

    /// (b) One wei made `settle()` revert `ClearingPriceUnrepresentable(3e26, 1)`.
    /// It settles now — as no participation — and the wei is refunded.
    function test_aOneWeiCommitMakesTheClearingPriceUnrepresentable() public {
        _openWindowAndCommit(1);
        _warpTo(window.endsAt());
        assertGe(_sold() / _net(1), 1 << 64, "the price is still unrepresentable");
        window.settle();
        _assertNothingSoldAndRefunded(ATTACKER, 1);
    }

    /// The old threshold, measured: every `total <= 16_427_305` wei made the
    /// guard fire, and one wei more settled. Both sides of it now settle the
    /// same way, because both are far below `MIN_POT` — the arithmetic floor no
    /// longer decides anything.
    function test_theBrickingThresholdIsSixteenMillionWei() public {
        uint256 last = 16_427_305;
        assertEq(_net(last), 16_263_032, "the largest net the old guard refused");

        uint256 snap = vm.snapshotState();
        _openWindowAndCommit(last);
        _warpTo(window.endsAt());
        assertGe(_sold() / _net(last), 1 << 64, "sold/net is at or above 2^64 here");
        window.settle();
        _assertNothingSoldAndRefunded(ATTACKER, last);

        vm.revertToState(snap);
        _openWindowAndCommit(last + 1);
        _warpTo(window.endsAt());
        assertLt(_sold() / _net(last + 1), 1 << 64, "and representable one wei more");
        window.settle();
        _assertNothingSoldAndRefunded(ATTACKER, last + 1);
    }

    /// (c) The whole of the finding: 1 wei in the window's final second, and
    /// after the grace hour 60% of the platform supply had no exit. Every
    /// recovery path the PoC tried is tried again: `settle` now succeeds after
    /// the hour, the factory's seeding paths still answer only to the window,
    /// and the attacker's wei comes back — having bought nothing and stranded
    /// nothing.
    function test_afterTheGraceHourSixtyPercentOfTheSupplyIsStrandedForEver() public {
        _genesis();
        _warpTo(window.endsAt() - 1); // the final second: nobody can out-commit it
        _commitAs(ATTACKER, 1);

        _warpTo(window.endsAt() + FeastGenesis.SETTLE_GRACE);

        // Nobody but the window may ask the factory to seed, still.
        vm.prank(multisig);
        vm.expectRevert(FeastFactory.NotTheWindow.selector);
        factory.seedWindowOpening(0, 100, 1);
        vm.prank(genesisKey);
        vm.expectRevert(FeastFactory.NotTheWindow.selector);
        factory.seedWindowPool(1);

        window.settle();
        _assertNothingSoldAndRefunded(ATTACKER, 1);
    }

    /// The finding's general case, with no attacker at all: an ALL freeze
    /// straddling the grace hour consumed it on the wall clock and locked the
    /// supply. Now the brake holds `settle` while it is down, and `settle`
    /// succeeds — and the auction still clears — once it is off.
    function test_aFreezeAcrossTheGraceHourAlsoConsumesIt() public {
        _openWindowAndCommit(10 ether);
        _warpTo(window.endsAt());
        vm.prank(multisig);
        guardian.freeze();
        vm.expectRevert(FeastLaunchWindow.Frozen.selector);
        window.settle();
        _warpTo(window.endsAt() + FeastGenesis.SETTLE_GRACE + 1);
        vm.prank(multisig);
        guardian.unfreeze();
        _advance(1);
        window.settle();
        assertGt(window.tranche(), 0, "the brake ate nothing: the auction cleared after it");
        assertGt(window.claim(ATTACKER), 0, "and its committer is paid");
    }
}
