// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FeastEmissions} from "../src/FeastEmissions.sol";
import {FeastGenesis} from "../src/FeastGenesis.sol";
import {PoolKey} from "../src/venue/PoolKey.sol";

import {UnitFixture} from "./utils/UnitFixture.sol";

/// **The pricing grace moves only by frozen seconds** (v1.6.22).
///
/// The grace is three days, after a week closes, in which a listed quote the
/// oracle cannot price blocks the week rather than being counted as zero. A
/// freeze stops `settle`, so the grace is extended by frozen time. From v1.6.15
/// to v1.6.21 it was extended by RESTARTING it from the last unfreeze, and a
/// freeze of no seconds at all restarted a grace that had already expired
/// (`pricing-grace-restart`, Codex appendix on v1.6.21-audit; PoC
/// `test/audit/poc/PricingGraceRestart.t.sol`). From v1.6.22 its end was the
/// close, plus three days, plus the guardian's frozen seconds since an anchor:
/// the previous week's settlement when that came before this week's close, else
/// zero. **Since v1.6.27 it is the close, plus three days, plus the frozen
/// seconds since the CLOSE** — read from the guardian's history — so a freeze
/// that ended before the close extends nothing (`CA-6b91a230c6`, PoC
/// `test/audit/poc/PreCloseFreezesCarryAWeekPastTheSeam.t.sol`).
///
/// The rule is checked against a model the test keeps itself — the stretches
/// of time IT held the brake down — never against the guardian's own counters,
/// so the properties below are not a restatement of the code:
///
///   1. **never early** — the week settles only once three days of OPEN time
///      have passed since its close;
///   2. **never before the close plus the grace**;
///   3. **never later than the close plus the grace plus every frozen second
///      since the anchor**, and so never later than the close plus the grace
///      plus the whole `FREEZE_BUDGET` (the bound the coordinator ruled the
///      over-count must keep, R4);
///   4. **never again** — once the week can settle, it can at every later
///      instant; no freeze of any length reopens the grace;
///   5. **exactly** (v1.6.27) — once three days of open time have passed since
///      the close, the week settles: frozen seconds before the close hold
///      nothing.
contract FeastPricingGraceTest is UnitFixture {
    address internal coinA;
    PoolKey internal keyA;
    address internal coinB;
    PoolKey internal keyB;

    /// @dev Every stretch of time this test held the brake down, as the test
    ///      itself counted it.
    uint256[] internal heldFrom;
    uint256[] internal heldTo;

    function setUp() public override {
        super.setUp();
        (coinA, keyA) = _create(address(wbnb), bytes32(uint256(1)));
        (coinB, keyB) = _create(address(stock), bytes32(uint256(2)));
        // Week 1 carries fees in both quotes, as `FeastEmissionsTest`'s does.
        _buy(keyA, address(wbnb), 100e18, trader, referrer);
        _advance(60);
        _buy(keyB, address(stock), 50e18, trader2, address(0));
    }

    // --- the model -------------------------------------------------------------

    function _closesAt(uint256 n) internal view returns (uint256) {
        return ledger.weekStart(emissions.ledgerWeekOf(n) + 1);
    }

    function _closeWeek(uint256 n) internal {
        uint256 end = _closesAt(n);
        if (clock < end) _warpTo(end);
    }

    /// @dev Frozen seconds inside `[a, b]`, from the test's own record.
    function _frozenBetween(uint256 a, uint256 b) internal view returns (uint256 s) {
        for (uint256 i = 0; i < heldFrom.length; i++) {
            uint256 lo = heldFrom[i] > a ? heldFrom[i] : a;
            uint256 hi = heldTo[i] < b ? heldTo[i] : b;
            if (hi > lo) s += hi - lo;
        }
    }

    /// @dev Hold the brake for `d` seconds from now. Zero is a freeze taken and
    ///      lifted in the same second; at or past the grant, it lapses and is
    ///      settled. Nothing, once the budget is gone.
    function _hold(uint256 d) internal {
        uint256 left = guardian.budgetLeft();
        if (left == 0) return;
        uint256 granted = left < guardian.FREEZE_MAX() ? left : guardian.FREEZE_MAX();
        uint256 from = clock;
        vm.prank(multisig);
        guardian.freeze();
        if (d >= granted) {
            _advance(granted);
            guardian.settleLapsed();
            d = granted;
        } else {
            if (d != 0) _advance(d);
            vm.prank(multisig);
            guardian.unfreeze();
        }
        heldFrom.push(from);
        heldTo.push(from + d);
    }

    /// @dev Would week `n` settle at this instant? Asked, then forgotten. The
    ///      only refusal the fixture allows is the grace's own.
    function _settles(uint256 n) internal returns (bool ok) {
        uint256 snap = vm.snapshotState();
        bytes memory ret;
        (ok, ret) = address(emissions).call(abi.encodeCall(FeastEmissions.settle, (n)));
        vm.revertToState(snap);
        if (!ok) {
            assertEq(bytes4(ret), FeastEmissions.QuoteUnpriceable.selector, "held by the grace and by nothing else");
        }
    }

    /// @dev The four properties, at this instant.
    function _check(uint256 n, uint256 anchoredAt, bool[1] memory over) internal {
        uint256 closesAt = _closesAt(n);
        if (clock < closesAt || guardian.isFrozenAll()) return;
        bool ok = _settles(n);
        uint256 grace = FeastGenesis.PRICING_GRACE;

        // 1. Never early.
        if (ok) {
            assertGe(clock - closesAt - _frozenBetween(closesAt, clock), grace, "over before three open days since the close");
        }
        // 2. Never before the close plus the grace.
        if (clock < closesAt + grace) assertFalse(ok, "over before the close plus the grace");
        // 3. Never after the close plus the grace plus every frozen second since
        //    the anchor — nor, therefore, after the whole freeze budget on top.
        if (clock >= closesAt + grace + _frozenBetween(anchoredAt, clock)) {
            assertTrue(ok, "held past every frozen second since the anchor");
        }
        if (clock >= closesAt + grace + guardian.FREEZE_BUDGET()) assertTrue(ok, "held past the whole freeze budget");
        // 4. Never again.
        if (over[0]) assertTrue(ok, "a grace that was over reopened");
        if (ok) over[0] = true;
        // 5. Exactly: three open days since the close, and not a frozen second
        //    before it, are what the grace waits for (v1.6.27).
        if (clock - closesAt - _frozenBetween(closesAt, clock) >= grace) {
            assertTrue(ok, "held past three open days since the close");
        }
    }

    /// @dev Six pulls of the brake at random gaps — a quarter of them holding
    ///      nothing at all, the rest up to 80 hours, past the 72-hour grant, so
    ///      some lapse — with the properties checked before and after each, and
    ///      then once more beyond everything the rule can add.
    function _walk(uint256 n, uint256 anchoredAt, uint256 seed) internal {
        bool[1] memory over;
        for (uint256 i = 0; i < 6; i++) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            _advance(1 + r % 3 days);
            _check(n, anchoredAt, over);
            _hold((r >> 32) % 4 == 0 ? 0 : (r >> 64) % 80 hours);
            _check(n, anchoredAt, over);
        }
        uint256 end = _closesAt(n) + FeastGenesis.PRICING_GRACE + guardian.FREEZE_BUDGET();
        if (clock < end) _warpTo(end);
        _check(n, anchoredAt, over);
        assertTrue(over[0], "the week settles in the end");
    }

    // --- the properties, fuzzed ----------------------------------------------------

    /// Week one has no week before it: the anchor is zero and every frozen
    /// second of the guardian's life counts. Pulls land before the close,
    /// across it and after it.
    function testFuzz_theGraceNeverEndsEarlyNorReopens_weekOne(uint256 seed) public {
        stockPool.setCardinality(1);
        _warpTo(_closesAt(1) - 1 - seed % 6 days);
        _walk(1, 0, seed);
    }

    /// Week two, after week one settled — promptly, so its stamp anchors week
    /// two's grace, or so late that week two had already closed and the anchor
    /// is zero. A pull may land in week one before any anchor exists.
    function testFuzz_theGraceNeverEndsEarlyNorReopens_afterASettledWeek(uint256 seed) public {
        uint256 r = uint256(keccak256(abi.encode(seed, "the anchor")));
        if (r % 2 == 0) {
            _advance(1 + (r >> 8) % 2 days);
            _hold((r >> 16) % 30 hours);
        }
        _closeWeek(1);
        _advance(1 + (r >> 64) % 10 days);
        emissions.settle(1); // every quote prices: no grace is involved
        uint256 anchoredAt = clock <= _closesAt(2) ? clock : 0;
        stockPool.setCardinality(1);
        _walk(2, anchoredAt, seed);
    }

    // --- the properties, pinned at their edges --------------------------------------

    /// **A freeze of no seconds moves nothing, even after a real one.** Week
    /// two, anchored on week one's prompt settlement; a real day of brake
    /// inside week two before it closes — which until v1.6.27 held the grace a
    /// day longer, and since then holds nothing, because it blocked nothing;
    /// then, once the grace is over, a freeze taken and lifted in the same
    /// second. It moves nothing.
    function test_aFreezeOfNoSecondsMovesNothingEvenAfterARealOne() public {
        _closeWeek(1);
        _advance(1 hours);
        emissions.settle(1);
        stockPool.setCardinality(1);
        _advance(1 days);
        _hold(24 hours);

        uint256 end = _closesAt(2) + FeastGenesis.PRICING_GRACE;
        _warpTo(end - 1);
        assertFalse(_settles(2), "three open days since the close, less a second");
        _warpTo(end);
        assertTrue(_settles(2), "the day of brake before the close holds nothing");

        _hold(0);
        assertTrue(_settles(2), "a freeze of no seconds restarts nothing");
    }

    /// **Open time, exactly.** A two-day freeze wholly after the close moves
    /// the grace's end by two days, and the week settles the moment three days
    /// of open time have passed — not three days after the unfreeze, which is
    /// what the restart rule gave.
    function test_aFreezeAfterTheCloseMovesTheGraceByItsFrozenSecondsExactly() public {
        _closeWeek(1);
        _advance(1 hours);
        emissions.settle(1);
        stockPool.setCardinality(1);
        _closeWeek(2);
        _advance(1 days);
        _hold(48 hours);

        uint256 end = _closesAt(2) + FeastGenesis.PRICING_GRACE + 48 hours;
        _warpTo(end - 1);
        assertFalse(_settles(2), "two open days and 23:59:59 of the third");
        _warpTo(end);
        assertTrue(_settles(2), "three open days: over, a day before the restart rule would have let it be");
    }

    /// **R4's bound, reached** (coordinator ruling on the plan). The whole
    /// 168-hour budget is spent after week two closes and before its grace
    /// ends, so every one of those seconds counts: the grace ends exactly
    /// `FREEZE_BUDGET` late, and never later. Until v1.6.27 this test spent the
    /// budget BEFORE the close and settled week one late, so that a zero anchor
    /// counted it all; since v1.6.27 those seconds count for nothing
    /// (`test_freezesThatEndedBeforeTheCloseExtendNothing`).
    function test_theWholeFreezeBudgetIsTheMostTheGraceCanBeHeld() public {
        _closeWeek(1);
        _advance(1 hours);
        emissions.settle(1);
        stockPool.setCardinality(1);
        _closeWeek(2);
        _advance(1 hours);
        _hold(72 hours);
        _advance(1 hours);
        _hold(72 hours);
        _advance(1 hours);
        _hold(72 hours); // the last 24 hours of the budget: granted 24, lapses at 24
        assertEq(guardian.budgetLeft(), 0, "the whole budget is spent");
        assertEq(guardian.frozenSeconds(), guardian.FREEZE_BUDGET(), "all of it frozen");

        uint256 end = _closesAt(2) + FeastGenesis.PRICING_GRACE + guardian.FREEZE_BUDGET();
        _warpTo(end - 1);
        assertFalse(_settles(2), "held by every frozen second since the close");
        _warpTo(end);
        assertTrue(_settles(2), "and by nothing more: the budget is the bound");
    }

    // --- the close, read exactly (v1.6.27, `CA-6b91a230c6`) -------------------------

    /// **Freezes that ended before the close extend nothing.** The PoC's shape on
    /// week one, which has no week before it: 144 hours of brake, every second
    /// before the close. Until v1.6.27 the anchor was zero and the grace ended
    /// 144 hours late; now it ends three open days after the close, to the
    /// second.
    function test_freezesThatEndedBeforeTheCloseExtendNothing() public {
        stockPool.setCardinality(1);
        _hold(72 hours);
        _advance(1);
        _hold(72 hours);
        assertLt(clock, _closesAt(1), "precondition: every frozen second predates the close");
        assertEq(guardian.frozenSeconds(), 144 hours, "precondition: 144 hours of brake");

        uint256 end = _closesAt(1) + FeastGenesis.PRICING_GRACE;
        _warpTo(end - 1);
        assertFalse(_settles(1), "not a second early");
        _warpTo(end);
        assertTrue(_settles(1), "three open days after the close, and not 144 hours later");
    }

    /// **A freeze running at the close extends the grace by its part after the
    /// close, and only that.** Placed ten hours before week one closes, it
    /// lapses at 72 hours: 62 of them fall after the close.
    function test_aFreezeAcrossTheCloseExtendsTheGraceByItsPartAfterTheClose() public {
        stockPool.setCardinality(1);
        _warpTo(_closesAt(1) - 10 hours);
        _hold(72 hours);
        assertGt(clock, _closesAt(1), "precondition: the freeze ran across the close");

        uint256 end = _closesAt(1) + FeastGenesis.PRICING_GRACE + 62 hours;
        _warpTo(end - 1);
        assertFalse(_settles(1), "the 62 hours after the close hold it");
        _warpTo(end);
        assertTrue(_settles(1), "and the 10 before it do not");
    }

    /// **The seed the storage-free rule failed on.** v1.6.27's first draft read
    /// the frozen seconds at the close from the guardian's latest fold, and
    /// `testFuzz_theGraceNeverEndsEarlyNorReopens_afterASettledWeek` found a
    /// grace that was over reopened at seed 6195, after 33 runs. Pinned here as
    /// a deterministic regression. On v1.6.26 it held property 4 and fails
    /// property 5, as every walk with a frozen second before the close does;
    /// on the history read it holds all five.
    function test_seed6195_aGraceThatIsOverStaysOver() public {
        testFuzz_theGraceNeverEndsEarlyNorReopens_afterASettledWeek(6195);
    }

}
