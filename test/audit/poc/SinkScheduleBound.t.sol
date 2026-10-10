// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {FeastGenesis} from "../../../src/FeastGenesis.sol";
import {FeastPlatformSink} from "../../../src/FeastPlatformSink.sol";
import {MockERC20} from "../../utils/MockERC20.sol";

import {FeastGuardian} from "../../../src/FeastGuardian.sol";
/// PoC for the round-r1 MEDIUM `schedule-bounds` (`CA-4ce8a94deb`) — the one finding of this round
/// that BOTH lens families reported independently, under different class slugs and at different
/// severities, and which the operator folded into the codex id:
///
///   - codex `r1h` (hook checklist), MEDIUM, `src/FeastPlatformSink.sol:177`:
///     "The advertised upper bound on sink scheduling is not enforced."
///   - claude `r1a-claude` (coverage), LOW L2, `src/FeastPlatformSink.sol:168-180`:
///     "the sink's opening is bounded only by the key's choice of window; the docstring's
///     two-ended bound is not implemented."
///
/// The claim: `schedule`'s docstring states a bound that `schedule` does not implement. It says
/// the key's discretion is "bounded at both ends: never a time already past, and never further out
/// than the longest gate the hook itself will accept" — the hook's own `MAX_GATE_DURATION`, 14
/// days, enforced at `src/FeastHook.sol:224-231` for the `openAt` genesis passes.
///
/// What `schedule` actually checks is four things: the caller is the genesis key, nothing is
/// scheduled yet, the named contract answers `genesisRole()` with the launch-window role, and it
/// serves this platform coin. It then copies `endsAt()` verbatim into `opensAt`. Neither end of
/// the advertised bound appears. Nothing ties the window the sink is given to the window genesis
/// registered with the hook, so the two numbers are free to disagree.
///
/// This is a normative-claim defect: the code is self-consistent, and the documented guarantee an
/// integrator would rely on is not the one enforced. It sits inside the genesis key's trust, which
/// is why the claude lens rated it LOW; the codex lens rated it MEDIUM because the guarantee is
/// stated as an API bound rather than as a description of intent. It is recorded at the higher of
/// the two, and the fix is a choice rather than a correction: enforce the bound, or withdraw the
/// sentence. Both lenses said so in nearly the same words.
///
/// The assertion below is the codex lens's own, verbatim in effect: the scheduled opening is
/// within the longest gate the hook will accept.
contract SinkScheduleBoundPoC is Test {
    FeastGuardian internal guardian = new FeastGuardian(address(0x3517), address(this));
    address internal genesisKey = address(0x6E0E515);

    /// **Edited by the v1.6.4 lane, and why.** As shipped at `88cbd30` this test
    /// scheduled the year-out window, let it through, and asserted the bound on
    /// `opensAt` afterwards — the only shape available while `schedule` accepted
    /// everything. G2's closure makes the antecedent false: an out-of-bound
    /// window is now REFUSED, so the original assertion can no longer be reached
    /// down that path and the test would fail on the revert instead of on the
    /// bound. The claim is unchanged and is now asserted on both paths — the
    /// out-of-bound window is refused by name, and a window the sink does accept
    /// still satisfies the original assertion, verbatim. Nothing was weakened:
    /// the refusal is strictly stronger than the bound it replaces.
    function test_theSinkCannotBeScheduledPastTheLongestGateTheHookAccepts() public {
        MockERC20 coin = new MockERC20("Feast", "FEAST", 18);
        FeastPlatformSink sink = new FeastPlatformSink(address(coin), genesisKey, address(guardian));

        // A launch window that answers every question the sink asks, truthfully: it carries the
        // launch-window role and it serves this very platform coin. It differs from the intended
        // one in one respect only — it closes a year out, well past the fourteen days the hook
        // would accept for its own gate.
        uint64 closes = uint64(block.timestamp + 365 days);
        StubWindow window = new StubWindow(address(coin), closes);

        uint256 scheduledAt = block.timestamp;

        // The year-out window is refused, by name, with the bound it broke.
        vm.prank(genesisKey);
        vm.expectRevert(
            abi.encodeWithSelector(
                FeastPlatformSink.WindowTooFarOut.selector,
                closes,
                uint64(scheduledAt + FeastGenesis.MAX_GATE_DURATION)
            )
        );
        sink.schedule(address(window));

        // Nothing was scheduled, so the sink is still open to the right window.
        assertEq(sink.opensAt(), 0, "a refused window schedules nothing");

        // A window inside the bound is accepted, and `endsAt` is copied straight through.
        uint64 ok = uint64(scheduledAt + 24 hours);
        StubWindow good = new StubWindow(address(coin), ok);
        vm.prank(genesisKey);
        sink.schedule(address(good));
        assertEq(sink.opensAt(), ok, "the window's close is copied verbatim");

        // The documented bound, asserted — the original assertion of this PoC, verbatim.
        // `schedule`'s docstring says the opening is "never further out than the longest gate
        // the hook itself will accept".
        assertLe(
            sink.opensAt(),
            scheduledAt + FeastGenesis.MAX_GATE_DURATION,
            "the sink opens no further out than the longest gate the hook accepts"
        );
    }
}

/// A contract that answers the three questions `schedule` asks, and answers them honestly.
contract StubWindow {
    address internal immutable coin;
    uint64 internal immutable closes;

    constructor(address coin_, uint64 closes_) {
        coin = coin_;
        closes = closes_;
    }

    function genesisRole() external pure returns (bytes32) {
        return keccak256("feast.genesis.launch-window");
    }

    function platformCoin() external view returns (address) {
        return coin;
    }

    function endsAt() external view returns (uint64) {
        return closes;
    }
}
