// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {FeastGenesis} from "../../../src/FeastGenesis.sol";
import {FeastLaunchWindow} from "../../../src/FeastLaunchWindow.sol";
import {Currency} from "../../../src/venue/Currency.sol";
import {PoolKey} from "../../../src/venue/PoolKey.sol";

/// AstraSec I-9: `FeastLaunchWindow` took `startsAt` as given, so a window
/// deployed after its own start opened part-spent: its 24 hours, and its
/// withdrawal period with them, were short by however late the deploy was.
/// Fixed in v1.6.24: a past start is clamped to the deploying block and
/// `endsAt` and `lockAt` are derived from the clamped start.
///
/// The constructor only stores what it is given, so the window is built with
/// placeholder collaborators; nothing here reaches them.
contract I9WindowStartClamp is Test {
    uint256 internal constant T0 = 1_800_000_000;

    function _window(uint64 startsAt_) internal returns (FeastLaunchWindow) {
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(0xC0)),
            currency1: Currency.wrap(address(0xC1)),
            hooks: address(0xB0),
            poolManager: address(0xB1),
            fee: 0,
            parameters: bytes32(0)
        });
        return new FeastLaunchWindow(
            address(0xA0), address(0xA1), address(0xA2), address(0xA3), address(0xA4), address(0xA5), key, startsAt_
        );
    }

    /// A start an hour in the past opens NOW, for the whole window.
    function test_aStartInThePastIsClampedToTheDeployingBlock() public {
        vm.warp(T0);
        FeastLaunchWindow w = _window(uint64(T0 - 1 hours));
        assertEq(w.startsAt(), T0, "the window opens when it is deployed");
        assertEq(w.endsAt(), T0 + FeastGenesis.WINDOW_DURATION, "and runs its whole 24 hours from there");
        assertEq(w.lockAt(), T0 + FeastGenesis.WINDOW_DURATION - FeastGenesis.WINDOW_LOCK, "with its last hour");
    }

    /// A day late is the case that mattered most: unclamped, the window was
    /// closed before it existed.
    function test_aStartADayLateStillGetsItsDay() public {
        vm.warp(T0);
        FeastLaunchWindow w = _window(uint64(T0 - FeastGenesis.WINDOW_DURATION));
        assertGt(w.endsAt(), T0, "not closed on arrival");
        assertEq(w.endsAt() - w.startsAt(), FeastGenesis.WINDOW_DURATION, "a whole day");
    }

    /// The boundary and the ordinary case are untouched: a start of exactly
    /// now, or in the future, is kept as given.
    function test_aStartNowOrLaterIsKeptAsGiven() public {
        vm.warp(T0);
        assertEq(_window(uint64(T0)).startsAt(), T0, "now is now");
        FeastLaunchWindow later = _window(uint64(T0 + 1 days));
        assertEq(later.startsAt(), T0 + 1 days, "a future start is the recipe's, unchanged");
        assertEq(later.endsAt(), T0 + 1 days + FeastGenesis.WINDOW_DURATION, "and so is its close");
    }
}
