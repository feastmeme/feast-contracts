// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FeastConstants} from "../../../src/FeastConstants.sol";
import {FeastEmissions} from "../../../src/FeastEmissions.sol";
import {FeastGenesis} from "../../../src/FeastGenesis.sol";
import {FeastPricer} from "../../../src/FeastPricer.sol";
import {PoolKey} from "../../../src/venue/PoolKey.sol";
import {UnitFixture} from "../../utils/UnitFixture.sol";

/// PoC for the round-r1 MEDIUM `settlement-grace` (`CA-81659c1034`), reported by the Claude
/// lens (`r1a-claude`) at `src/FeastEmissions.sol:269-276`, and by no other lens.
///
/// The claim: past the three-day pricing grace, `settle` collapses every non-`Ok` pricer status
/// for a LISTED QUOTE into the same outcome —
///
///     if (s != FeastPricer.Status.Ok) {
///         if (!graceOver) revert QuoteUnpriceable(qs[i]);
///         price = 0;
///     }
///
/// — while the very same contract keeps the two statuses apart for the PLATFORM COIN thirty lines
/// later, refusing `Moved` with `PlatformPriceMoved()` past the grace as well
/// (`src/FeastEmissions.sol:301-307`, pinned by
/// `test/FeastEmissions.t.sol:test_afterLaunchAMovedPlatformPriceRefusesSettlementPastTheGrace`).
///
/// `FeastPricer` states the difference itself: `Moved` means the pool's spot sits more than
/// `MAX_TICK_DEVIATION` ticks from its own average, and the contract at `src/FeastPricer.sol:156`
/// says that means **retry, never guess**. `Unpriceable` means there is no history to read at
/// all, and Q11's written rule — wait out the grace, then count it as zero — is about that case.
/// Zero is a guess, and it is the one guess the pricer's own contract forbids for `Moved`.
///
/// The consequence is not one week's rounding. The week settles with that quote absent from the
/// snapshot, so every payer, creator and referrer in that quote is owed nothing for the week
/// (`src/FeastEmissions.sol:474-485` iterates the snapshot only), and every genesis partner's
/// `referredValue` for that week reads zero (`src/FeastEmissions.sol:377-380`), which `checkpoint`
/// counts once and never revises. When the token cap binds, the zeroed quote's share of a fixed
/// pot is paid to the other quotes' participants, so the transfer has a beneficiary.
///
/// **The assertion below is the reporting lens's own**, and it is the behaviour the pricer's
/// contract states and the platform-coin branch already implements — not a design this lane
/// invented. A moved quote is refused, and settlement retries, exactly as its platform-coin
/// analogue does.
///
/// Existing witnesses do not reach this. `test/FeastEmissions.t.sol:370-379` drives
/// `Unpriceable` by setting the pool's cardinality to one; nothing in the suite drives `Moved`
/// on a listed quote.
contract EmissionsMovedQuoteZeroedPoC is UnitFixture {
    address internal coinA;
    PoolKey internal keyA;
    address internal coinB;
    PoolKey internal keyB;

    function setUp() public override {
        super.setUp();
        (coinA, keyA) = _create(address(wbnb), bytes32(uint256(1)));
        (coinB, keyB) = _create(address(stock), bytes32(uint256(2)));
        // Week 1: a referred buy in A, an unreferred buy in B, so the stock quote carries fees.
        _buy(keyA, address(wbnb), 100e18, trader, referrer);
        _advance(60);
        _buy(keyB, address(stock), 50e18, trader2, address(0));
    }

    function test_aMovedQuoteIsRefusedPastTheGraceAsTheMovedPlatformPriceIs() public {
        _closeWeek(1);
        _advance(FeastGenesis.PRICING_GRACE + 1);

        // The spot the pool vouches for sits one tick outside the bound it admits, and nothing
        // else about the pool changes: the history is there and the price is readable.
        stockPool.setTicks(FeastConstants.MAX_TICK_DEVIATION + 1, 0);
        (FeastPricer.Status s,) = pricer.priceQ128(address(stock));
        assertEq(uint8(s), uint8(FeastPricer.Status.Moved), "the fixture really moved the quote");

        // The platform coin's identical status refuses past the grace. The listed quote's does
        // not: the week settles and the quote is valued at zero, for good.
        //
        // v1.6.5 F2 amended ONE identifier on the line below, and nothing else in this file.
        // As the pack wrote it, the expected refusal was:
        //
        //     vm.expectRevert(abi.encodeWithSelector(FeastEmissions.QuoteUnpriceable.selector, address(stock)));
        //
        // The closure this finding asks for is that a listed quote's `Moved` be handled exactly
        // as the platform coin's `Moved` is — and the platform half has carried its OWN name
        // since round 4 (`PlatformPriceMoved`, `FeastEmissions.sol:306`). Mirroring it faithfully
        // means a named `QuotePriceMoved`, so the selector this proof expects moves with it. The
        // assertion's intent is untouched: settlement is refused, and `settledCount` stays 0.
        vm.expectRevert(abi.encodeWithSelector(FeastEmissions.QuotePriceMoved.selector, address(stock)));
        emissions.settle(1);
        assertEq(emissions.settledCount(), 0, "nothing settled, so the week can be retried");
    }

    /// The same construction one tick inside the bound, so the witness is known to straddle the
    /// boundary rather than to sit on one side of it: the quote prices, the week settles, and the
    /// fees paid in it are worth something.
    function test_theSameQuoteOneTickInsideTheBoundStillSettles() public {
        _closeWeek(1);
        _advance(FeastGenesis.PRICING_GRACE + 1);

        stockPool.setTicks(FeastConstants.MAX_TICK_DEVIATION - 1, 0);
        (FeastPricer.Status s,) = pricer.priceQ128(address(stock));
        assertEq(uint8(s), uint8(FeastPricer.Status.Ok), "one tick inside, the quote prices");

        emissions.settle(1);
        assertEq(emissions.settledCount(), 1, "the week settles");
        assertGt(emissions.priceOf(1, address(stock)), 0, "and the quote carries a price");
    }

    function _closeWeek(uint256 n) internal {
        uint256 end = ledger.weekStart(emissions.ledgerWeekOf(n) + 1);
        if (clock < end) _warpTo(end);
    }
}
