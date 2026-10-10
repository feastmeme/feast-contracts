// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {FeastEmissions} from "../../../src/FeastEmissions.sol";
import {FeastFeeLedger} from "../../../src/FeastFeeLedger.sol";
import {FeastHook} from "../../../src/FeastHook.sol";
import {FeastGenesis} from "../../../src/FeastGenesis.sol";
import {FeastPricer} from "../../../src/FeastPricer.sol";
import {PoolId} from "../../../src/venue/PoolId.sol";

import {FeastGuardian} from "../../../src/FeastGuardian.sol";
/// PoC for the round-r1 HIGH `value-cap-overflow` (`CA-5203dcf236`), reported independently by
/// BOTH Codex lens units — `r1h` (the hook-checklist unit) at `src/FeastEmissions.sol:297-300`
/// and `r1a2` (the coverage unit, re-run after the classifier stopped `r1a`) at
/// `src/FeastEmissions.sol:297` — and folded into one id. Neither Claude unit reported it.
///
/// The claim: `settle` computes the value cap and only THEN takes the minimum against the token
/// cap.
///
///     uint256 valueCap = Math.mulDiv(
///         Math.mulDiv(feesNative, valueRatioAt(w), FeastGenesis.BPS), perNative, ONE
///     );
///     if (valueCap < cap) cap = valueCap;
///
/// `Math.mulDiv` carries its intermediate at 512 bits but **panics when its RESULT exceeds 256
/// bits**. So a week whose settled cap is the token cap — a small, representable number the
/// contract never needed the value cap to compute — reverts, because the larger quantity it was
/// going to discard did not fit a word.
///
/// This is the shape of `CA-5ba81ae0e6`, the v1.6.3 HIGH, one release later and one contract
/// over. `docs/plan.md` section 6e states the correction in as many words — "the minimum is
/// established **before** anything is multiplied", and that the ruling's `min(grant, mulDiv(…))`
/// spelling "reintroduces this very finding" because `mulDiv` "bounds its intermediate but not
/// its result". That paragraph was applied to `FeastGenesisGrants::unlocked` and not here, in the
/// pass whose own stated rule is that a shape closed in one contract must be swept across all of
/// them. `src/FeastEmissions.sol:291-296` carries a comment claiming this very site was swept.
///
/// Settlement is strictly ordered (`src/FeastEmissions.sol:239`), so week `n` reverting blocks
/// every week after it for as long as the prices hold. That is the reason this is a HIGH and not
/// a MEDIUM: it is not one week's pot, it is the emissions schedule.
///
/// The numbers below are the `r1h` unit's own. The fee fits the ledger's `uint80` field
/// (`src/FeastFeeLedger.sol:54-58`), and both prices are ones the real pricer can return.
contract EmissionsValueCapOverflowPoC is Test {
    FeastGuardian internal guardian = new FeastGuardian(address(0x3517), address(this));
    StubLedger internal ledger;
    StubPricer internal pricer;
    FeastEmissions internal emissions;

    address internal constant QUOTE = address(0xBEEF);
    uint256 internal constant FIRST_WEEK = 2_960;

    /// 20 x 2^70 = 23611832414348226068480, inside the ledger's 80-bit `paid` field.
    uint80 internal constant PAID = uint80(20 * (uint256(1) << 70));
    /// A quote-token0 pool at square-root price 2^157 gives this Q128 price.
    uint256 internal constant QUOTE_PRICE = uint256(1) << 250;
    /// A platform-token0 pool at 2^64 gives this reciprocal Q128 price.
    uint256 internal constant PLATFORM_PER_NATIVE = uint256(1) << 192;

    function setUp() public {
        ledger = new StubLedger();
        pricer = new StubPricer();

        ledger.setTotals(FIRST_WEEK, QUOTE, FeastFeeLedger.Credit({paid: PAID, earned: 0, referred: 0}));
        pricer.setQuote(QUOTE, FeastPricer.Status.Ok, QUOTE_PRICE);
        pricer.setPlatform(FeastPricer.Status.Ok, PLATFORM_PER_NATIVE);

        emissions = new FeastEmissions(
            address(ledger),
            address(new PoCStubHook()), // v1.6.7: `settle` reads the launch state first
            address(0),
            PoolId.wrap(bytes32(0)),
            address(this),
            address(pricer),
            FIRST_WEEK,
            address(guardian)
        );

        // Week 1 has closed, and its three-day pricing grace has passed.
        vm.warp(ledger.weekStart(FIRST_WEEK + 1) + FeastGenesis.PRICING_GRACE + 1);
    }

    /// The defect. The settled cap is `tokenCap(1)` — the value cap is larger and is discarded —
    /// but the discarded quantity is computed first and does not fit a word.
    function test_aWeekWhoseCapIsTheTokenCapCanSettle() public {
        // The answer the contract should reach, stated before the call so the assertion is about
        // a number and not about the absence of a revert.
        uint256 expectedCap = emissions.tokenCap(1);
        assertEq(expectedCap, 5_358_490_566_037_735_849_056_603, "week 1 token cap");

        // The arithmetic the contract performs, in order:
        //   feesNative                  = 20 * 2^192
        //   inner = feesNative * 1500 / 10000
        //                               =  3 * 2^192
        //   valueCap = inner * perNative / ONE
        //                               = inner * 2^192 / 2^128  =  inner * 2^64  =  3 * 2^256
        // `3 * 2^256` cannot be written down here, so the overflow is asserted in the only form
        // a uint256 can carry it: the outer `mulDiv` scales `inner` by `2^64`, so its RESULT
        // exceeds a word exactly when `inner > type(uint256).max / 2^64`.
        uint256 inner = 3 * (uint256(1) << 192);
        assertGt(inner, type(uint256).max / (uint256(1) << 64), "the outer mulDiv's result exceeds a word");

        // And that result is the side of the minimum the contract DISCARDS: `valueCap < cap` is
        // false, so `cap` stays `tokenCap(1)`. The contract never needs the left-hand side's
        // value; it only needs to know which of the two is smaller.
        assertGt(inner / (uint256(1) << 64), expectedCap, "the value cap is the discarded side");

        emissions.settle(1);

        assertEq(emissions.settledCount(), 1, "week 1 settles");
        uint256 expectedTraderPot =
            expectedCap * FeastGenesis.EARLY_TRADER_BPS / FeastGenesis.BPS;
        assertEq(expectedTraderPot, 2_411_320_754_716_981_132_075_471, "the trader track's share");
        assertEq(emissions.weekInfo(1).pot[emissions.TRADER()], expectedTraderPot, "trader pot");
    }

    /// The control, so the witness is known to straddle its bound rather than to sit on one side
    /// of it. Two bits off the platform price and nothing else changes — the same fee, the same
    /// quote price, the same ratio, the same token cap, the same pot — and it succeeds.
    ///
    /// Two bits, not one: at `2^191` the result is still `3 * 2^255`, which is `1.5 * 2^256` and
    /// does not fit either. The first draft of this test used one bit and reverted, which is the
    /// witness telling its author that it had not yet crossed the boundary it was asserting
    /// about. At `2^190` the result is `3 * 2^254`, inside a word and still far above the token
    /// cap — so the comparison this settlement makes is the identical comparison, decided the
    /// identical way, and the ONLY difference from the test above is whether the discarded side
    /// could be written down.
    function test_theSameSettlementTwoBitsBelowTheOverflowSucceeds() public {
        pricer.setPlatform(FeastPricer.Status.Ok, PLATFORM_PER_NATIVE >> 2);

        uint256 expectedCap = emissions.tokenCap(1);
        // Still the discarded side: 3 * 2^254 is four orders of magnitude above the token cap.
        assertGt(3 * (uint256(1) << 254), expectedCap, "the value cap is still the larger side");

        emissions.settle(1);

        assertEq(emissions.settledCount(), 1, "week 1 settles");
        assertEq(
            emissions.weekInfo(1).pot[emissions.TRADER()],
            expectedCap * FeastGenesis.EARLY_TRADER_BPS / FeastGenesis.BPS,
            "the same pot as the case above asserts"
        );
    }
}

/// Answers the three selectors `FeastEmissions.settle` reads through its `FeastFeeLedger`
/// reference, with the real contract's own `weekStart` formula.
contract StubLedger {
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

/// Answers the three selectors `FeastEmissions.settle` reads through its `FeastPricer` reference.
contract StubPricer {
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
contract PoCStubHook {
    function poolInfo(PoolId) external view returns (FeastHook.Pool memory p) {
        p.coin = address(0xC01B);
        p.openAt = uint64(block.timestamp);
    }
}
