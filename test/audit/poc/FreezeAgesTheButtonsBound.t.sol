// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";

import {FeastConstants} from "../../../src/FeastConstants.sol";
import {IFeastCLPoolManager} from "../../../src/venue/IFeastCLPoolManager.sol";
import {FeastHook} from "../../../src/FeastHook.sol";
import {PoolId, PoolIdLibrary} from "../../../src/venue/PoolId.sol";
import {PoolKey} from "../../../src/venue/PoolKey.sol";
import {FeastBuybackTest} from "../../FeastBuyback.t.sol";

/// **`button-bound-ages-onto-frozen-spot`** — `P16-claude` LOW, and the one I
/// would put first of the v1.6.15 round's three.
///
/// `FeastHook._requireSpotNearAverage` (the button) and `_spotIsNearAverage`
/// (the internal fill) read `oracle.twapTick(poolId)` and compare it against
/// spot. `MAX_TICK_DEVIATION` asks whether spot has run away from the recent
/// average, and the remedy for a `yes` is to wait and let trading bring them
/// back together.
///
/// A freeze writes no observations. The average drifts onto the pinned spot
/// with no trade happening at all, so a price the bound REFUSED becomes one it
/// accepts while the corrective trades are prohibited — and the protocol then
/// spends its own bucket into a price nobody could move.
///
/// `FeastEmissions` was given exactly this rule at v1.6.15 and these two sites
/// were not. **That was the fourth time in this lane that a fix went to the site
/// a lens named rather than to the shape**, which is why `audit/guardian-reads.allow`
/// now enumerates every read of an average in `src/` with its decision.
contract FreezeAgesTheButtonsBoundPoC is FeastBuybackTest {
    using PoolIdLibrary for PoolKey;

    address internal constant GUARDIAN_KEY = address(0x3517);

    function test_aFreezeDoesNotAgeAMovedSpotPastTheButtonsBound() public {
        _warmUp();
        PoolId id = key.toId();

        // Push spot far enough from the average that the button refuses, and
        // assert the deviation rather than assuming it.
        _pushSpot();
        int24 dev = _spotTick() > _averageTick() ? _spotTick() - _averageTick() : _averageTick() - _spotTick();
        assertGt(dev, FeastConstants.MAX_TICK_DEVIATION, "the fixture really moved the price");

        uint256 amount = hook.selfBurnPending(id) / 10;
        assertGt(amount, 0, "there is a bucket to spend");
        bytes memory refusal =
            abi.encodeWithSelector(FeastHook.SpotTooFarFromAverage.selector, _spotTick(), _averageTick());
        vm.expectRevert(refusal);
        vm.prank(presser);
        hook.buyBackAndBurn(key, amount);

        // **The witness reaches its bound**: assert the freeze really does age
        // the average onto the pinned spot, with no trade at all. Without this
        // the refusal below could be a refusal for any other reason.
        vm.prank(GUARDIAN_KEY);
        guardian.freeze();
        _advance(FeastConstants.TWAP_WINDOW + 1);
        vm.prank(GUARDIAN_KEY);
        guardian.unfreeze();
        assertEq(_spotTick(), _averageTick(), "the freeze alone brought the average onto the pinned spot");

        // And the button must still refuse: the average has had no OPEN time.
        //
        // Both the amount and the expected data are read into locals FIRST. An
        // external call between `vm.expectRevert` and the call under test — an
        // argument counts — consumes the cheatcode, and the test then passes on
        // the wrong revert or on none. This exact slip cost a cycle here.
        uint256 amountAfter = hook.selfBurnPending(id) / 10;
        bytes memory stillRefused =
            abi.encodeWithSelector(FeastHook.SpotTooFarFromAverage.selector, _spotTick(), _spotTick());
        vm.expectRevert(stillRefused);
        vm.prank(presser);
        hook.buyBackAndBurn(key, amountAfter);
    }

    /// The control: once a full averaging window of OPEN time has passed, the
    /// button works again. The rule is a delay, not a halt.
    /// A one-sided buy far larger than the pool's depth near spot.
    function _pushSpot() internal {
        _trade(-40_000_000e18);
    }

    function _spotTick() internal view returns (int24 tick) {
        (, tick,,) = IFeastCLPoolManager(address(pm)).getSlot0(key.toId());
    }

    function _averageTick() internal view returns (int24) {
        return oracle.twapTick(key.toId());
    }

    function test_theButtonWorksAgainAfterAnAveragingWindowOfOpenTime() public {
        _warmUp();
        PoolId id = key.toId();

        vm.prank(GUARDIAN_KEY);
        guardian.freeze();
        _advance(1 hours);
        vm.prank(GUARDIAN_KEY);
        guardian.unfreeze();
        _advance(FeastConstants.TWAP_WINDOW + 1);

        vm.prank(presser);
        hook.buyBackAndBurn(key, hook.spendingAllowance(id));
    }
}
