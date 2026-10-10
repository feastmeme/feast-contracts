// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {FeastFeeLedger} from "../src/FeastFeeLedger.sol";
import {FeastGenesis} from "../src/FeastGenesis.sol";

/// The weekly three-track fee ledger.
///
/// Emissions and the genesis grants divide real tokens against this record, and
/// neither can correct it afterwards, so what is held here is what a payout
/// would silently inherit: every fee lands on the right address in the right
/// track, week and quote; a week's total is exactly the sum of its accounts, so
/// no division against it can pay out more than its pot; and nothing about the
/// record — not a huge fee, not a zero one — can revert the swap that wrote it.
contract FeastFeeLedgerTest is Test {
    FeastFeeLedger internal ledger;

    address internal hook = address(0xB00C);
    address internal quoteA = address(0xA0A0);
    address internal quoteB = address(0xB0B0);

    address internal payer = address(0x7EADE1);
    address internal creator = address(0xC0FFEE);
    address internal referrer = address(0xEE01);

    /// Monday 2026-10-05 00:00:00 UTC.
    uint256 internal constant A_MONDAY = 1_791_158_400;

    function setUp() public {
        vm.warp(A_MONDAY + 1 days);
        ledger = new FeastFeeLedger(hook);
    }

    function _record(address quote, address p, address c, address r, uint256 amount) internal {
        vm.prank(hook);
        ledger.record(quote, p, c, r, amount);
    }

    function _paid(address quote, address a) internal view returns (uint256) {
        return ledger.credit(ledger.currentWeek(), quote, a).paid;
    }

    function _earned(address quote, address a) internal view returns (uint256) {
        return ledger.credit(ledger.currentWeek(), quote, a).earned;
    }

    function _referred(address quote, address a) internal view returns (uint256) {
        return ledger.credit(ledger.currentWeek(), quote, a).referred;
    }

    // --- who may write ----------------------------------------------------

    function test_onlyTheHookMayRecord() public {
        vm.prank(address(0xBADBAD));
        vm.expectRevert(FeastFeeLedger.NotRecorder.selector);
        ledger.record(quoteA, payer, creator, referrer, 1e18);
    }

    // --- the three tracks -------------------------------------------------

    /// Kills: crediting a track to the wrong role, or crediting a share of the
    /// fee instead of the whole of it (ruling Q3/Q4: every track counts the
    /// whole fee).
    function test_eachTrackCreditsTheWholeFeeToItsOwnRole() public {
        _record(quoteA, payer, creator, referrer, 30e18);
        uint256 w = ledger.currentWeek();

        assertEq(_paid(quoteA, payer), 30e18, "the payer paid it");
        assertEq(_earned(quoteA, creator), 30e18, "the creator's coin earned it");
        assertEq(_referred(quoteA, referrer), 30e18, "the referrer brought it");

        assertEq(_earned(quoteA, payer) + _referred(quoteA, payer), 0, "the payer holds no other track");
        assertEq(_paid(quoteA, creator) + _referred(quoteA, creator), 0, "nor does the creator");
        assertEq(_paid(quoteA, referrer) + _earned(quoteA, referrer), 0, "nor does the referrer");

        FeastFeeLedger.Credit memory t = ledger.totals(w, quoteA);
        assertEq(t.paid, 30e18, "the week's fees");
        assertEq(t.earned, 30e18, "the week's creator track");
        assertEq(t.referred, 30e18, "the week's referral track");
    }

    /// A creator trading their own coin is both roles; both are credited.
    function test_oneAddressInTwoRolesIsCreditedInBoth() public {
        _record(quoteA, creator, creator, referrer, 10e18);

        assertEq(_paid(quoteA, creator), 10e18, "as payer");
        assertEq(_earned(quoteA, creator), 10e18, "and as creator");
        assertEq(_referred(quoteA, referrer), 10e18, "and the referrer still gets theirs");
    }

    /// A creator may also refer trades on their own coin — nothing forbids it.
    function test_theCreatorMayAlsoBeTheReferrer() public {
        _record(quoteA, payer, creator, creator, 10e18);

        assertEq(_earned(quoteA, creator), 10e18, "as creator");
        assertEq(_referred(quoteA, creator), 10e18, "and as referrer");
        assertEq(_paid(quoteA, payer), 10e18, "the payer unchanged");
    }

    /// The hook passes zero for "no creator track" (a burn-address creator) and
    /// "no referral". Zero is never an account.
    function test_aZeroRoleIsNotAnAccount() public {
        _record(quoteA, payer, address(0), address(0), 10e18);
        uint256 w = ledger.currentWeek();

        FeastFeeLedger.Credit memory t = ledger.totals(w, quoteA);
        assertEq(t.paid, 10e18, "the fee is still a fee");
        assertEq(t.earned, 0, "no creator track without a creator");
        assertEq(t.referred, 0, "no referral track without a referrer");
        FeastFeeLedger.Credit memory z = ledger.credit(w, quoteA, address(0));
        assertEq(uint256(z.paid) + z.earned + z.referred, 0, "and the zero address holds nothing");
    }

    function test_aZeroFeeRecordsNothing() public {
        _record(quoteA, payer, creator, referrer, 0);
        FeastFeeLedger.Credit memory t = ledger.totals(ledger.currentWeek(), quoteA);
        assertEq(uint256(t.paid) + t.earned + t.referred, 0, "nothing to record");
    }

    function test_theRecordIsAnnounced() public {
        vm.expectEmit(address(ledger));
        emit FeastFeeLedger.FeesRecorded(ledger.currentWeek(), quoteA, payer, creator, referrer, 7e18);
        _record(quoteA, payer, creator, referrer, 7e18);
    }

    // --- weeks and quotes -------------------------------------------------

    /// Kills: an alignment that turns the week on any day but Monday 00:00 UTC.
    function test_weeksTurnAtMondayMidnightUtc() public view {
        assertEq(ledger.weekOf(A_MONDAY), ledger.weekOf(A_MONDAY - 1) + 1, "Sunday 23:59:59 is last week");
        assertEq(ledger.weekOf(A_MONDAY + 7 days - 1), ledger.weekOf(A_MONDAY), "the next Sunday is this week");
        assertEq(ledger.weekStart(ledger.weekOf(A_MONDAY)), A_MONDAY, "and a week starts on its Monday");
    }

    function test_aWeekIsClosedWhenTheNextBegins() public {
        _record(quoteA, payer, creator, referrer, 10e18);
        uint256 first = ledger.currentWeek();

        vm.warp(A_MONDAY + 7 days);
        _record(quoteA, payer, creator, referrer, 3e18);
        uint256 second = ledger.currentWeek();

        assertEq(second, first + 1, "a new week");
        assertEq(ledger.credit(first, quoteA, payer).paid, 10e18, "last week is unchanged forever");
        assertEq(ledger.credit(second, quoteA, payer).paid, 3e18, "this week starts from nothing");
    }

    /// One unit of a four-hundred-dollar share is not one unit of a
    /// twenty-dollar one, so quotes are never summed here; emissions prices each.
    function test_eachQuoteKeepsItsOwnLedger() public {
        _record(quoteA, payer, creator, referrer, 100e18);
        _record(quoteB, payer, creator, address(0), 3e18);
        uint256 w = ledger.currentWeek();

        assertEq(ledger.totals(w, quoteA).paid, 100e18, "A's week");
        assertEq(ledger.totals(w, quoteB).paid, 3e18, "B's week, separately");
        assertEq(ledger.credit(w, quoteB, referrer).referred, 0, "and no credit crosses between them");
    }

    // --- nothing reverts a swap, and totals stay exact ---------------------

    /// Kills: letting a huge fee revert (I1), or saturating only the total so
    /// that accounts could sum past it and a division pay out more than its pot.
    function test_aTrackWithNoHeadroomSkipsBothSidesAndTheSwapStillRecords() public {
        uint256 max = type(uint80).max;
        _record(quoteA, payer, creator, referrer, max - 5);
        uint256 w = ledger.currentWeek();

        // A second fee of 10 overflows all three tracks; it must not revert.
        _record(quoteA, address(0xAAA), address(0xBBB), address(0xCCC), 10);
        FeastFeeLedger.Credit memory t = ledger.totals(w, quoteA);
        assertEq(t.paid, max - 5, "the full track took nothing");
        assertEq(ledger.credit(w, quoteA, address(0xAAA)).paid, 0, "and neither did the account");

        // A fee that fits still lands.
        _record(quoteA, address(0xAAA), address(0xBBB), address(0xCCC), 5);
        assertEq(ledger.totals(w, quoteA).paid, max, "exactly to the brim");
        assertEq(ledger.credit(w, quoteA, address(0xAAA)).paid, 5, "on the account too");
    }

    /// One track full while another has room: the full one is skipped on BOTH
    /// sides and the others still land. Kills: crediting an account on a track
    /// whose total was skipped (accounts would then sum past their total, and a
    /// division against it would pay out more than its pot).
    function test_aSaturatedTrackSkipsOnlyItselfAndOnBothSides() public {
        uint256 max = type(uint80).max;
        // Fill `paid` and `referred` to within 5 of the ceiling; leave `earned` empty.
        _record(quoteA, payer, address(0), referrer, max - 5);
        uint256 w = ledger.currentWeek();

        address p2 = address(0xAAA);
        address c2 = address(0xBBB);
        address r2 = address(0xCCC);
        _record(quoteA, p2, c2, r2, 10);

        assertEq(ledger.credit(w, quoteA, c2).earned, 10, "the track with room took the fee");
        assertEq(ledger.credit(w, quoteA, p2).paid, 0, "the full payer track credited no account");
        assertEq(ledger.credit(w, quoteA, r2).referred, 0, "nor did the full referral track");
        FeastFeeLedger.Credit memory t = ledger.totals(w, quoteA);
        assertEq(t.paid, max - 5, "paid total unchanged");
        assertEq(t.referred, max - 5, "referred total unchanged");
        assertEq(t.earned, 10, "earned total took it");
        assertEq(
            uint256(t.referred),
            uint256(ledger.credit(w, quoteA, referrer).referred) + ledger.credit(w, quoteA, r2).referred,
            "and each total is still the sum of its accounts"
        );
    }

    /// A fee too large for any track at all is simply not recorded.
    function test_aFeeLargerThanATrackIsIgnoredNotReverted() public {
        _record(quoteA, payer, creator, referrer, uint256(type(uint80).max) + 1);
        FeastFeeLedger.Credit memory t = ledger.totals(ledger.currentWeek(), quoteA);
        assertEq(uint256(t.paid) + t.earned + t.referred, 0, "nothing recorded, nothing reverted");
    }

    /// The property every payout rests on: per week, quote and track, the total
    /// is exactly the sum of the accounts — over any interleaving of roles,
    /// including roles that coincide, and amounts near the ceiling.
    function testFuzz_eachTotalIsExactlyTheSumOfItsAccounts(uint8[16] calldata roles, uint88[16] calldata amounts)
        public
    {
        address[4] memory who = [address(0x1001), address(0x1002), address(0x1003), address(0)];
        for (uint256 i = 0; i < 16; i++) {
            // Two bits per role, so roles collide often and zero appears often.
            address p = who[roles[i] & 3] == address(0) ? who[0] : who[roles[i] & 3];
            address c = who[(roles[i] >> 2) & 3];
            address r = who[(roles[i] >> 4) & 3];
            _record(quoteA, p, c, r, amounts[i]);
        }
        uint256 w = ledger.currentWeek();
        uint256 sp;
        uint256 se;
        uint256 sr;
        for (uint256 i = 0; i < 3; i++) {
            FeastFeeLedger.Credit memory a = ledger.credit(w, quoteA, who[i]);
            sp += a.paid;
            se += a.earned;
            sr += a.referred;
        }
        FeastFeeLedger.Credit memory t = ledger.totals(w, quoteA);
        assertEq(t.paid, sp, "paid total is the sum of its payers");
        assertEq(t.earned, se, "earned total is the sum of its creators");
        assertEq(t.referred, sr, "referred total is the sum of its referrers");
    }

    function testFuzz_aRecordNeverDecreasesAnything(uint64 first, uint64 second) public {
        _record(quoteA, payer, creator, referrer, first);
        FeastFeeLedger.Credit memory before = ledger.credit(ledger.currentWeek(), quoteA, payer);
        _record(quoteA, payer, creator, referrer, second);
        FeastFeeLedger.Credit memory after_ = ledger.credit(ledger.currentWeek(), quoteA, payer);
        assertGe(after_.paid, before.paid, "a later fee can only add");
    }

    function test_theWeekIsTheGenesisFilesWeek() public pure {
        assertEq(FeastGenesis.WEEK_LENGTH, 7 days, "seven days");
    }
}
