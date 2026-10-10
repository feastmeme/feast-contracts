// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {FeastEmissions} from "../src/FeastEmissions.sol";
import {FeastFeeLedger} from "../src/FeastFeeLedger.sol";
import {FeastHook} from "../src/FeastHook.sol";
import {FeastGenesis} from "../src/FeastGenesis.sol";
import {FeastPricer} from "../src/FeastPricer.sol";
import {PoolId} from "../src/venue/PoolId.sol";

import {FeastGuardian} from "../src/FeastGuardian.sol";
/// The v1.6.5 pre-audit pass's own witnesses, for the two findings the v1.6.4
/// dual-family pack proved.
///
/// The proofs of concept under `test/audit/poc/` assert the findings. These
/// assert the **bounds** — the properties the closures establish, measured at
/// the extremes where they are weakest, and at a distance of ONE from the
/// boundary rather than at a comfortable distance from it. §6e records the
/// v1.6.4 pass for an assertion that could not fail in the direction its
/// finding was about; these are written against that.
///
/// The stubs below answer exactly the three selectors `settle` reads through its
/// ledger and pricer references, as the HIGH's PoC does — the only way to drive
/// a platform price to a chosen 128.128 value without a pool that can hold it.
contract FeastV165BoundsTest is Test {
    FeastGuardian internal guardian = new FeastGuardian(address(0x3517), address(this));
    uint256 internal constant ONE = 1 << 128;
    uint256 internal constant FIRST_WEEK = 2_960;
    address internal constant QUOTE = address(0xBEEF);

    /// The HIGH's own fee and quote price: `feesNative = 20 * 2^192`, so the
    /// inner product at the default 1 500 bps is exactly `3 * 2^192`.
    uint80 internal constant PAID = uint80(20 * (uint256(1) << 70));
    uint256 internal constant QUOTE_PRICE = uint256(1) << 250;
    uint256 internal constant INNER = 3 * (uint256(1) << 192);

    /// `ceil(2^384 / INNER)` = `(2^192 + 2) / 3`: the SMALLEST platform price at
    /// which `inner * perNative` needs more than 384 bits, so the value cap
    /// needs more than a word. Computed off-chain and asserted below against the
    /// 512-bit product itself, so the constant is measured and not merely
    /// asserted.
    uint256 internal constant BOUNDARY_PER_NATIVE =
        2_092_367_245_128_893_587_945_263_141_069_222_138_700_785_148_154_678_170_966;

    // --- F1: the value cap's word boundary --------------------------------

    /// EXACTLY on the boundary: `high == ONE`, at the smallest platform price
    /// whose value cap needs more than a word. The quotient there is
    /// `2^256 + 2^65` — the first draft of this comment said "exactly `2^256`",
    /// which is what the boundary would be if `inner` were a power of two and
    /// is not what this fixture's `inner = 3 * 2^192` produces (v1.6.5 round 1,
    /// r1v). The week settles, and it settles at the TOKEN cap — the side of
    /// the minimum this comparison keeps.
    ///
    /// Kills: computing the value cap before deciding which side is smaller
    /// (the finding); and admitting a value cap of exactly one word
    /// (`high <= ONE`), which panics here and nowhere else in the suite.
    function test_atTheExactWordBoundaryTheTokenCapIsTaken() public {
        (uint256 high,) = Math.mul512(INNER, BOUNDARY_PER_NATIVE);
        assertEq(high, ONE, "the construction sits exactly on the word boundary");
        (uint256 lowerHigh,) = Math.mul512(INNER, BOUNDARY_PER_NATIVE - 1);
        assertEq(lowerHigh, ONE - 1, "and one below it is the last product that fits");
        // The boundary is the SMALLEST such price, which is the property the
        // witness needs: one below it fits, and this one does not.
        assertEq(BOUNDARY_PER_NATIVE, (uint256(1) << 192) / 3 + 1, "ceil(2^384 / inner)");

        FeastEmissions e = _emissions(PAID, QUOTE_PRICE, BOUNDARY_PER_NATIVE);
        uint256 tokenCap = e.tokenCap(1);
        e.settle(1);

        assertEq(e.settledCount(), 1, "the week settles");
        assertEq(
            e.weekInfo(1).pot[e.TRADER()],
            tokenCap * FeastGenesis.EARLY_TRADER_BPS / FeastGenesis.BPS,
            "at the token cap, which is the smaller side"
        );
        assertFalse(e.weekInfo(1).tokenCapOnly, "and not under the pre-launch first-week rule");
    }

    /// One unit below the boundary, where the value cap is the LARGEST this
    /// contract can represent — `2^256 - 2^64` — and is still the discarded
    /// side. The same settlement, the same pot: the only difference across the
    /// boundary is whether the discarded number could be written down.
    function test_oneUnitBelowTheWordBoundaryTheValueCapIsComputed() public {
        uint256 perNative = BOUNDARY_PER_NATIVE - 1;
        assertEq(
            Math.mulDiv(INNER, perNative, ONE),
            type(uint256).max - (uint256(1) << 64) + 1,
            "the largest value cap THIS inner operand can produce inside a word: 2^256 - 2^64"
        );

        FeastEmissions e = _emissions(PAID, QUOTE_PRICE, perNative);
        uint256 tokenCap = e.tokenCap(1);
        e.settle(1);

        assertEq(e.settledCount(), 1, "the week settles");
        assertEq(
            e.weekInfo(1).pot[e.TRADER()],
            tokenCap * FeastGenesis.EARLY_TRADER_BPS / FeastGenesis.BPS,
            "the same pot the boundary case settles at"
        );
    }

    /// Where the value cap BINDS it is still exactly the number it always was.
    /// The expected emission is a literal computed off-chain, so the assertion
    /// is about a number and not about the code that produced it.
    ///
    /// Kills: dropping the value cap when it is the smaller side; any rounding
    /// change in the rewritten expression.
    function test_whereTheValueCapBindsItIsExactlyTheOldNumber() public {
        FeastEmissions e = _emissions(PAID, QUOTE_PRICE, 50_000);
        uint256 tokenCap = e.tokenCap(1);
        assertEq(tokenCap, 5_358_490_566_037_735_849_056_603, "week 1 token cap");

        e.settle(1);

        // valueCap = 3 * 2^192 * 50 000 / 2^128 = 150 000 * 2^64.
        uint256 valueCap = 2_767_011_611_056_432_742_400_000;
        assertEq(valueCap, 150_000 * (uint256(1) << 64), "the value cap, written two ways");
        assertLt(valueCap, tokenCap, "and it is the binding side here");
        assertEq(
            e.weekInfo(1).pot[e.TRADER()],
            1_245_155_224_975_394_734_080_000,
            "the trader pot is the value cap's share, to the unit"
        );
    }

    /// The floors are visible where they actually round (v1.6.5 round 1, r1v).
    /// `test_whereTheValueCapBindsItIsExactlyTheOldNumber` above divides exactly
    /// at every step, so flooring and ceiling agree and it could not have caught
    /// a rounding change — the defect this project keeps finding in its own
    /// witnesses. These two cases have a remainder in every division that
    /// matters, and the expected pots are computed off-chain.
    ///
    ///   A. `paid = 7`, `perNative = 10 * ONE`: inner is `7 * 1500 / 10000 =
    ///      1.05`, the value cap is 10, the trader pot is 4. Rounding the INNER
    ///      quotient up gives an inner of 2, a cap of 20 and a pot of 9.
    ///   B. `paid = 20`, `perNative = 1.5 * ONE`: inner is 3 exactly, the value
    ///      cap is `4.5`, the trader pot is `1.8`. Rounding the OUTER quotient
    ///      up gives a cap of 5 and a pot of 2; rounding the TRACK SHARE up
    ///      gives a pot of 2 as well.
    function test_theValueCapsFloorsAreVisibleWhereTheyRound() public {
        FeastEmissions a = _emissions(7, ONE, 10 * ONE);
        a.settle(1);
        assertEq(a.weekInfo(1).pot[a.TRADER()], 4, "A: the inner quotient floors");

        FeastEmissions b = _emissions(20, ONE, ONE + ONE / 2);
        b.settle(1);
        assertEq(b.weekInfo(1).pot[b.TRADER()], 1, "B: the outer quotient and the share floor");
    }

    /// The bound F1 establishes: `settle` is total in the size of its cap. No
    /// platform price, quote price, fee or ratio makes it revert, and the cap it
    /// settles at never exceeds the week's token cap.
    ///
    /// Deliberately NOT a re-spelling of the branch under test — a witness that
    /// re-implements the code it is checking cannot fail where that code is
    /// wrong. Exactness is pinned by the three literal-valued cases above.
    function testFuzz_settleNeverRevertsOnTheSizeOfItsCap(uint80 paid, uint256 price, uint256 perNative)
        public
    {
        perNative = bound(perNative, 1, type(uint256).max);
        FeastEmissions e = _emissions(paid, price, perNative);
        uint256 tokenCap = e.tokenCap(1);

        e.settle(1);

        assertEq(e.settledCount(), 1, "every week settles, whatever the prices are worth");
        uint256[3] memory pot = e.weekInfo(1).pot;
        assertLe(pot[0] + pot[1] + pot[2], tokenCap, "and never emits above its token cap");
    }

    /// A settled cap never FALLS as the platform coin gets dearer. The old code
    /// broke this by reverting at the top of the range; a closure that zeroed or
    /// clamped the overflowing side would break it too, in the other direction.
    function testFuzz_theSettledCapNeverFallsAsThePlatformPriceRises(uint256 lo, uint256 hi) public {
        lo = bound(lo, 1, type(uint256).max - 1);
        hi = bound(hi, lo + 1, type(uint256).max);

        FeastEmissions cheap = _emissions(PAID, QUOTE_PRICE, lo);
        FeastEmissions dear = _emissions(PAID, QUOTE_PRICE, hi);
        cheap.settle(1);
        dear.settle(1);

        assertLe(
            cheap.weekInfo(1).pot[cheap.TRADER()],
            dear.weekInfo(1).pot[dear.TRADER()],
            "a dearer platform coin never settles a smaller pot"
        );
    }

    // --- the fixture ------------------------------------------------------

    function _emissions(uint80 paid, uint256 quotePrice, uint256 perNative)
        internal
        returns (FeastEmissions e)
    {
        V165StubLedger ledger = new V165StubLedger();
        V165StubPricer pricer = new V165StubPricer();
        ledger.setTotals(FIRST_WEEK, QUOTE, FeastFeeLedger.Credit({paid: paid, earned: 0, referred: 0}));
        pricer.setQuote(QUOTE, FeastPricer.Status.Ok, quotePrice);
        pricer.setPlatform(FeastPricer.Status.Ok, perNative);

        e = new FeastEmissions(
            address(ledger),
            address(new V165StubHook()), // v1.6.7: `settle` reads the launch state first
            address(0),
            PoolId.wrap(bytes32(0)),
            address(this),
            address(pricer),
            FIRST_WEEK,
            address(guardian)
        );
        vm.warp(ledger.weekStart(FIRST_WEEK + 1) + FeastGenesis.PRICING_GRACE + 1);
    }
}

/// The three selectors `settle` reads through its `FeastFeeLedger` reference,
/// with the real contract's own `weekStart` formula.
contract V165StubLedger {
    mapping(uint256 => mapping(address => FeastFeeLedger.Credit)) internal _totals;

    function setTotals(uint256 week, address quote, FeastFeeLedger.Credit memory c) external {
        _totals[week][quote] = c;
    }

    function totals(uint256 week, address quote) external view returns (FeastFeeLedger.Credit memory) {
        return _totals[week][quote];
    }

    function weekStart(uint256 week) public pure returns (uint256) {
        return week * FeastGenesis.WEEK_LENGTH - FeastGenesis.WEEK_ALIGNMENT;
    }

    function currentWeek() external view returns (uint256) {
        return (block.timestamp + FeastGenesis.WEEK_ALIGNMENT) / FeastGenesis.WEEK_LENGTH;
    }
}

/// The three selectors `settle` reads through its `FeastPricer` reference.
contract V165StubPricer {
    address[] internal _quotes;
    mapping(address => FeastPricer.Status) internal _status;
    mapping(address => uint256) internal _price;
    FeastPricer.Status internal _platformStatus;
    uint256 internal _platformPrice;

    function setQuote(address quote, FeastPricer.Status s, uint256 p) external {
        _quotes.push(quote);
        _status[quote] = s;
        _price[quote] = p;
    }

    function setPlatform(FeastPricer.Status s, uint256 p) external {
        _platformStatus = s;
        _platformPrice = p;
    }

    function quotes() external view returns (address[] memory) {
        return _quotes;
    }

    function priceQ128(address quote) external view returns (FeastPricer.Status, uint256) {
        return (_status[quote], _price[quote]);
    }

    function platformPerNativeQ128() external view returns (FeastPricer.Status, uint256) {
        return (_platformStatus, _platformPrice);
    }
}

/// Answers the one selector `claimsOpen()` reads through the emissions
/// contract's `FeastHook` reference.
///
/// v1.6.7: before the pack's MEDIUM was closed, `settle` consulted the launch
/// state only on the branches BELOW the value cap, so a fixture driving an `Ok`
/// platform price never reached the hook at all — which is why this stub did not
/// exist and the constructor was handed `address(0)` with a comment saying the
/// hook was not reached. The fix asks the launch state FIRST, so every settle
/// with fees reads it, and a fixture whose subject is the value cap has to say
/// the pool is open. Saying so is also the honest fixture: the value cap is a
/// post-launch rule.
contract V165StubHook {
    function poolInfo(PoolId) external view returns (FeastHook.Pool memory p) {
        p.coin = address(0xC01B);
        p.openAt = uint64(block.timestamp);
    }
}
