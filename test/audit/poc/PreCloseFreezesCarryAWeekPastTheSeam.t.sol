// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FeastEmissions} from "../../../src/FeastEmissions.sol";
import {FeastGenesis} from "../../../src/FeastGenesis.sol";
import {PoolKey} from "../../../src/venue/PoolKey.sol";
import {UnitFixture} from "../../utils/UnitFixture.sol";

/// **`regime-flip`** — r2 (v1.6.26, `57eadbc`), reported MEDIUM by `U3-claude` (Claude) at
/// `src/FeastEmissions.sol:325-326`. The Codex half of U3 did not report it.
///
/// v1.6.22 (`3611106`) ends a week's pricing grace at
/// `closesAt + PRICING_GRACE + (frozenSeconds() - anchor)`, the anchor being the previous week's
/// `frozenAtSettle` when that week settled by this week's close, else zero. With a zero (or early)
/// anchor, frozen seconds that ended BEFORE the week closed — which blocked no settlement — still
/// lengthen its grace. The changelog calls the cost "at most 168 h of delay, never a zero
/// valuation" (`docs/audit/changelog-v1.6.22.md`). For the week before the seam that is not true:
/// it closes seven days before the window's close, `openAt` is that close plus an hour, so more
/// than 97 h of such freezes push its first settleable instant past `openAt` whenever a listed
/// quote is Unpriceable at its close. From `openAt` `claimsOpen()` is true and the week settles
/// under the VALUE cap rather than the TOKEN cap the written rule gives a pre-launch week; the
/// difference stays in `remaining` and burns. Two lapsed 72 h freezes are enough.
///
/// Asserts the written rule for a pre-launch week (token cap only); it FAILS on `57eadbc`.
///
/// **v1.6.27: fixed, and the PoC's timing adjusted** (task 757, the coordinator's instruction of 4
/// October). As committed by the audit lane it settled at the OLD grace end,
/// `close + 72 h + 144 h`, which is past `openAt`; there round 4 H1's rule puts every week under the
/// value cap, so no fix to the grace could make that settle a token-cap one. It now settles where the
/// corrected grace ends, `close + 72 h`, before `openAt`, and asserts what the finding is about: the
/// two lapsed freezes, which ended before the close, no longer hold the week past the seam, so it
/// settles under the pre-launch token cap — and not a second early. On `57eadbc` this form fails too
/// (the grace still runs 144 hours late, so the settle refuses with `QuoteUnpriceable`). The audit
/// lane's record of the original red run stands as the finding's evidence. The control is unchanged.
contract PreCloseFreezesCarryAWeekPastTheSeamTest is UnitFixture {
    address internal coinA;
    PoolKey internal keyA;
    address internal coinB;
    PoolKey internal keyB;

    function setUp() public override {
        super.setUp();
        (coinA, keyA) = _create(address(wbnb), bytes32(uint256(1)));
        (coinB, keyB) = _create(address(stock), bytes32(uint256(2)));
        // Week 1 carries fees in both quotes, as `FeastPricingGraceTest`'s does.
        _buy(keyA, address(wbnb), 100e18, trader, referrer);
        _advance(60);
        _buy(keyB, address(stock), 50e18, trader2, address(0));
    }

    function _closesAt(uint256 n) internal view returns (uint256) {
        return ledger.weekStart(emissions.ledgerWeekOf(n) + 1);
    }

    function _lapsedFreeze() internal {
        vm.prank(multisig);
        guardian.freeze();
        _advance(guardian.FREEZE_MAX());
        guardian.settleLapsed();
    }

    function test_freezesThatEndedBeforeAPreLaunchWeekClosedDoNotSettleItUnderTheValueCap() public {
        stockPool.setCardinality(1); // a listed quote the pricer cannot vouch for, from week 1 on
        _lapsedFreeze();
        _advance(1);
        _lapsedFreeze(); // 144 h of brake, every second of it before week 1 closes
        assertLt(clock, _closesAt(1), "precondition: every frozen second predates week 1's close");

        uint256 graceEnd = _closesAt(1) + FeastGenesis.PRICING_GRACE;
        assertLt(graceEnd, window.endsAt() + FeastGenesis.SETTLE_GRACE, "precondition: the grace ends before openAt");
        _warpTo(graceEnd - 1);
        (bool early, bytes memory why) = address(emissions).call(abi.encodeCall(FeastEmissions.settle, (1)));
        assertFalse(early, "not a second early");
        assertEq(bytes4(why), FeastEmissions.QuoteUnpriceable.selector, "held by the grace, and by nothing else");

        _warpTo(graceEnd);
        emissions.settle(1);
        assertTrue(emissions.weekInfo(1).tokenCapOnly, "a pre-launch week settled under the value cap after its grace crossed openAt");
    }

    /// The counterfactual, which passes: with no freeze, the same week settles at the end of its
    /// three-day grace, before `openAt`, under the token cap. The freezes are the whole difference.
    function test_control_withoutTheFreezesTheWeekSettlesUnderTheTokenCapBeforeOpenAt() public {
        stockPool.setCardinality(1);
        _warpTo(_closesAt(1) + FeastGenesis.PRICING_GRACE);
        assertLt(clock, window.endsAt() + FeastGenesis.SETTLE_GRACE, "precondition: before openAt");
        emissions.settle(1);
        assertTrue(emissions.weekInfo(1).tokenCapOnly, "a pre-launch week settles under the token cap");
    }
}
