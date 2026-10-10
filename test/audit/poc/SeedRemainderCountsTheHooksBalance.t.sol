// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {FeastLaunchWindow} from "../../../src/FeastLaunchWindow.sol";
import {UnitFixture} from "../../utils/UnitFixture.sol";

/// **`settlement-liveness` / `stranded-supply`** — r2 (v1.6.26, `57eadbc`), reported by BOTH
/// lens families at HIGH: `U5b` (Codex) and `U5-claude` (Claude), at
/// `src/FeastFactory.sol:936-940`.
///
/// Both window seed paths measure the seed's unplaced remainder as the hook's WHOLE FEAST
/// balance. `seedWindowOpening` and `seedWindowPool` read `sent = balanceOf(hook)` after the
/// window's transfer, and `_burnUnplaced` reverts `PoolTooShallow` when the balance left after
/// seeding exceeds `sent / 100`. FEAST the hook held BEFORE the window's transfer is counted as
/// the seed's remainder, and nothing but the factory-only `burnUnusedSeed` can move an ERC-20
/// FEAST balance out of the hook. Since v1.6.24 `settle` has no deadline (AstraSec M-2), so a
/// window settled late can be made to revert for ever: the window's 60% of the supply never
/// reaches the pool and the pool is never initialised. The committers' quote stays refundable
/// from `abandonAt`; only the coin is stranded.
///
/// The FEAST here is the team's own vesting, released by `release(feast)` — anyone may call it —
/// fifty days after the close: 250M over three years with no cliff vests about 11.4M, above the
/// ~6.06M at which the no-participation branch reverts (99 x D > 6e26). U5-claude names a route
/// that needs no delay of that length: from `openAt`, pre-launch emission weeks pay about 5.3M
/// FEAST each to their claimants, and a freeze across the settle hour leaves `settle`, `claim`
/// and a transfer all live in the first unfrozen block.
///
/// Asserts the property the code claims (a late settle still places the window's coin); it
/// FAILS on `57eadbc` with `PoolTooShallow()`.
contract SeedRemainderCountsTheHooksBalanceTest is UnitFixture {
    function test_aLateSettleIsNotRefusedByFeastAlreadyOnTheHook() public {
        _genesis();
        _warpTo(window.endsAt() + 50 days);

        teamVesting.release(feast);
        uint256 vested = IERC20(feast).balanceOf(beneficiary);
        uint256 held = IERC20(feast).balanceOf(address(window));
        assertGt(vested * 99, held, "precondition: the released FEAST exceeds 1% of what the hook holds at seeding");
        vm.prank(beneficiary);
        IERC20(feast).transfer(address(hook), vested);

        (bool ok, bytes memory why) = address(window).call(abi.encodeCall(FeastLaunchWindow.settle, ()));
        if (!ok) emit log_named_bytes("settle reverted with", why);
        assertTrue(ok, "a late settle is refused because the hook already held FEAST the window did not send");
        assertEq(IERC20(feast).balanceOf(address(window)), 0, "the window's 60% reached the pool");
    }

    /// The counterfactual, which passes: the same late settle with nothing on the hook places
    /// the window's whole holding. The FEAST on the hook is the whole difference.
    function test_control_aLateSettleWithNothingOnTheHookPlacesTheCoin() public {
        _genesis();
        _warpTo(window.endsAt() + 50 days);
        teamVesting.release(feast);
        window.settle();
        assertTrue(window.settled(), "settled");
        assertEq(IERC20(feast).balanceOf(address(window)), 0, "the window's 60% reached the pool");
    }
}
