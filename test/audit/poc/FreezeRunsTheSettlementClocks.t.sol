// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FeastConstants} from "../../../src/FeastConstants.sol";
import {FeastEmissions} from "../../../src/FeastEmissions.sol";
import {FeastGenesis} from "../../../src/FeastGenesis.sol";
import {FeastPricer} from "../../../src/FeastPricer.sol";
import {PoolId} from "../../../src/venue/PoolId.sol";
import {FeastEmissionsTest} from "../../FeastEmissions.t.sol";

/// PoCs for the three settlement clocks the v1.6.14 round found a freeze runs —
/// the two the sweep classified wrongly and the residue it named.
///
/// Every one of them is the same instrument: `settle` is refused under an ALL
/// freeze, and every window it is measured against ran anyway. None of them
/// needs a per-week checkpoint, because the only freeze that reaches `settle`
/// is an ALL freeze and the instant one ends is a single number:
/// `FeastGuardian.allUnfrozenAt()`.
contract FreezeRunsTheSettlementClocksPoC is FeastEmissionsTest {
    /// **R1 — the pricing grace.** `P5b` HIGH, `P16b` HIGH.
    ///
    /// The grace is three days in which a quote the oracle cannot price blocks
    /// its week rather than being valued at zero. Past it, the quote counts as
    /// ZERO for ever — that is the irreversible valuation, and the three days
    /// are the whole protection against it. `settle` is frozen and the grace
    /// was not, so a freeze straddling it consumed the window with nobody able
    /// to price anything.
    ///
    /// @dev The first version of this test asserted the refusal through a MOVED
    ///      platform price, and the mutation gate caught it as vacuous: after
    ///      launch a moved platform price refuses settlement past the grace too
    ///      (round 4 H1), so the revert came from that rule and not from the
    ///      grace, and reverting `graceFrom` to `closesAt` changed nothing the
    ///      test could see. `graceOver` binds in exactly two places, and the one
    ///      that loses value is the unpriceable quote at `FeastEmissions:367`.
    ///      This is that path.
    function test_aFreezeDoesNotConsumeTheSettlementPricingGrace() public {
        // A listed quote the oracle will not answer for: one observation is not
        // enough history, so the price is `Unpriceable` and never `Moved`.
        stockPool.setCardinality(1);
        _closeWeek(1);

        uint256 closesAt = ledger.weekStart(emissions.ledgerWeekOf(1) + 1);

        // Seventy-two hours of brake, straddling the three-day grace. Nobody may
        // settle and nobody may bring a price.
        vm.prank(multisig);
        guardian.freeze();
        _advance(72 hours - 1);
        vm.prank(multisig);
        guardian.unfreeze();
        _advance(1 hours);

        // **The witness reaches its bound**: on the wall clock the grace has
        // expired, so without the fix this settles and prices the quote at zero.
        assertGe(block.timestamp, closesAt + FeastGenesis.PRICING_GRACE, "on the wall clock the grace is over");

        bytes memory expected =
            abi.encodeWithSelector(FeastEmissions.QuoteUnpriceable.selector, address(stock));
        vm.expectRevert(expected);
        emissions.settle(1);
        assertEq(emissions.settledCount(), 0, "nothing settled, and nothing was valued at zero");

        // And the refusal is the GRACE, not a halt: three open days later the
        // same unpriceable quote counts as zero, exactly as it always did.
        _advance(FeastGenesis.PRICING_GRACE);
        emissions.settle(1);
        assertEq(emissions.priceOf(1, address(stock)), 0, "three OPEN days later it counts as zero");
        assertEq(emissions.settledCount(), 1, "and the week settles");
    }

    /// The control that stops the above being a test of nothing: with no freeze
    /// at all the grace is unchanged to the second.
    function test_theGraceIsUnchangedWhenNobodyTouchesTheBrake() public {
        stockPool.setCardinality(1);
        _closeWeek(1);

        bytes memory expected =
            abi.encodeWithSelector(FeastEmissions.QuoteUnpriceable.selector, address(stock));
        vm.expectRevert(expected);
        emissions.settle(1);

        _advance(FeastGenesis.PRICING_GRACE);
        emissions.settle(1);
        assertEq(emissions.priceOf(1, address(stock)), 0, "past the grace, an unfrozen week counts it as zero");
        assertEq(emissions.settledCount(), 1, "and settles");
    }

    /// **The same rule, through the OTHER scope** — `P16-claude` MEDIUM,
    /// `P5-claude` MEDIUM, and the finding that v1.6.15's fix created.
    ///
    /// The aging rule below was written to stop a freeze ageing a refused price
    /// into an accepted one. It read the ALL-scope resume instant, and a freeze
    /// scoped to the PLATFORM POOL stops exactly the observations that pool's
    /// average is built from — so the defect came back through the scope owner
    /// ruling 2 had introduced the same day. It reads `unfrozenAtFor` now.
    function test_theAgingRuleAndTheGraceReadTheSameInstantAndAgree() public {
        _launch(10e18);
        _firstPlatformTrade();
        _advance(10 minutes);
        uint256 n = _settleClosedWeeks();
        _buy(keyA, address(wbnb), 1e18, trader, address(0));
        _buy(feastKey, address(wbnb), 1e15, trader2, address(0));
        _closeWeek(n);
        _advance(FeastGenesis.PRICING_GRACE + 1 hours);

        _buy(feastKey, address(wbnb), 30_000_000e18, trader2, address(0));
        (FeastPricer.Status ps,) = pricer.platformPerNativeQ128();
        assertEq(uint8(ps), uint8(FeastPricer.Status.Moved), "the fixture really moved the price");

        // v1.6.17: the only freeze there is.
        vm.prank(multisig);
        guardian.freeze();
        _advance(72 hours - 1);
        vm.prank(multisig);
        guardian.unfreeze();

        // **The witness reaches its bound.** Assert the freeze really did mature
        // the price with no trade, and that `settle` was never itself frozen.
        (FeastPricer.Status after_,) = pricer.platformPerNativeQ128();
        assertEq(uint8(after_), uint8(FeastPricer.Status.Ok), "the freeze alone matured the price, with no trade");
        assertFalse(guardian.isFrozenAll(), "the brake is up again before settlement is attempted");

        vm.expectRevert(FeastEmissions.PlatformPriceMoved.selector);
        emissions.settle(n);

        // And it settles once the pool has had an averaging window of OPEN time.
        _advance(FeastConstants.TWAP_WINDOW + 1);
        emissions.settle(n);
        assertEq(emissions.settledCount(), n, "one open averaging window later, the same price settles");
    }

    /// **`grace-blind-to-platform-pool-freeze`** — `P16-claude` MEDIUM in the
    /// v1.6.16 round, **CLOSED BY CONSTRUCTION in v1.6.17** and kept as a
    /// regression test.
    ///
    /// The finding was that v1.6.16's own sentence — the grace may read
    /// `allUnfrozenAt()` because "nothing but an all-scope freeze refuses
    /// `settle`" — was made false by the aging rule added in the same release:
    /// a freeze scoped to the PLATFORM POOL turned an `Ok` price into `Moved`,
    /// a `Moved` price refuses `settle`, and so a scoped freeze consumed a
    /// grace that could not see it. The cost was the one the grace exists to
    /// prevent: an unpriceable listed quote valued at ZERO, for ever.
    ///
    /// v1.6.17 removed the pool-scoped freeze. The sentence is true again, and
    /// for a better reason than the one it was first written for: there is no
    /// other scope, so the grace and the aging rule are refused by the same
    /// thing and may read the same instant. This test now proves that the one
    /// freeze there is cannot eat the grace through either route.
    function test_aFreezeDoesNotConsumeTheSettlementPricingGraceThroughTheAgingRule() public {
        _launch(10e18);
        _firstPlatformTrade();
        _advance(10 minutes);
        uint256 n = _settleClosedWeeks();

        // A listed quote the oracle will not answer for, and a week that
        // carries fees in it — so the zero is worth something to somebody.
        stockPool.setCardinality(1);
        _buy(keyA, address(wbnb), 1e18, trader, address(0));
        _closeWeek(n);
        uint256 closesAt = ledger.weekStart(emissions.ledgerWeekOf(n) + 1);

        // v1.6.17: there is no freeze that covers the platform pool alone, so
        // this is the freeze that exists. It stops `settle` as well, which is
        // precisely why the grace can be measured against one instant again.
        vm.prank(multisig);
        guardian.freeze();
        _advance(72 hours - 1);
        vm.prank(multisig);
        guardian.unfreeze();
        assertFalse(guardian.isFrozenAll(), "the brake is up again before settlement is attempted");

        // **The witness reaches its bound**: on the wall clock the three-day
        // grace has expired, and the freeze was the whole of what passed.
        _advance(1 hours);
        assertGe(block.timestamp, closesAt + FeastGenesis.PRICING_GRACE, "on the wall clock the grace is over");

        // The grace must still hold: three OPEN days have not passed for a pool
        // that was frozen for three of them. Today it does not, and the
        // unpriceable quote is valued at zero for ever.
        bytes memory expected =
            abi.encodeWithSelector(FeastEmissions.QuoteUnpriceable.selector, address(stock));
        vm.expectRevert(expected);
        emissions.settle(n);
        assertEq(emissions.settledCount(), n - 1, "nothing settled, and nothing was valued at zero");
    }

    /// **Ruling 3 — the platform price must age over OPEN time.** `P16b`
    /// MEDIUM, reported at `FeastOracle:168`.
    ///
    /// `Moved` means spot has been pushed away from the average and the remedy
    /// is to let trading bring them back. A freeze writes no observations, so
    /// the average drifts toward the stale spot with no trade happening at all,
    /// and a price settlement REFUSED ages into one it accepts while the
    /// corrective trades are prohibited.
    function test_aFreezeDoesNotAgeAMovedPriceIntoAnAcceptedOne() public {
        _launch(10e18);
        _firstPlatformTrade();
        _advance(10 minutes);
        uint256 n = _settleClosedWeeks();
        _buy(keyA, address(wbnb), 1e18, trader, address(0));
        _buy(feastKey, address(wbnb), 1e15, trader2, address(0));
        _closeWeek(n);
        _advance(FeastGenesis.PRICING_GRACE + 1 hours);

        _buy(feastKey, address(wbnb), 30_000_000e18, trader2, address(0));
        (FeastPricer.Status ps,) = pricer.platformPerNativeQ128();
        assertEq(uint8(ps), uint8(FeastPricer.Status.Moved), "the fixture really moved the price");

        // A freeze long enough that the average catches the stale spot with no
        // trade at all. The witness has to reach its bound: assert the pricer
        // really does say `Ok` afterwards, or this proves nothing.
        vm.prank(multisig);
        guardian.freeze();
        _advance(72 hours - 1);
        vm.prank(multisig);
        guardian.unfreeze();
        (FeastPricer.Status after_,) = pricer.platformPerNativeQ128();
        assertEq(uint8(after_), uint8(FeastPricer.Status.Ok), "the freeze alone matured the price, with no trade");

        // Settlement must not take it. A full averaging window of OPEN time is
        // what the average needs to mean anything, and none has passed.
        vm.expectRevert(FeastEmissions.PlatformPriceMoved.selector);
        emissions.settle(n);

        // And it must take it once that open time HAS passed, or the rule is a
        // halt rather than a delay.
        _advance(FeastConstants.TWAP_WINDOW + 1);
        emissions.settle(n);
        assertEq(emissions.settledCount(), n, "one open averaging window later, the same price settles");
    }
}
