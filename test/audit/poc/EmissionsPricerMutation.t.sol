// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FeastEmissions} from "../../../src/FeastEmissions.sol";
import {FeastPricer} from "../../../src/FeastPricer.sol";
import {PoolKey} from "../../../src/venue/PoolKey.sol";
import {UnitFixture} from "../../utils/UnitFixture.sol";

/// A pricer module that prices exactly as the real one does, and whose LIST of quotes grows a
/// duplicate entry once a timestamp fixed at construction has passed. Its bytecode never changes
/// and no further privileged call is made after it is accepted.
contract FlippingPricer {
    FeastPricer public immutable inner;
    uint256 public immutable flipAt;

    constructor(FeastPricer inner_, uint256 flipAt_) {
        inner = inner_;
        flipAt = flipAt_;
    }

    function quotes() external view returns (address[] memory qs) {
        address[] memory base = inner.quotes();
        if (block.timestamp < flipAt) return base;
        qs = new address[](base.length * 2);
        for (uint256 i = 0; i < base.length; i++) {
            qs[2 * i] = base[i];
            qs[2 * i + 1] = base[i];
        }
    }

    function routeOf(address quote) external view returns (address[] memory) {
        return inner.routeOf(quote);
    }

    function priceQ128(address quote) external view returns (FeastPricer.Status, uint256) {
        return inner.priceQ128(quote);
    }

    function platformPerNativeQ128() external view returns (FeastPricer.Status, uint256) {
        return inner.platformPerNativeQ128();
    }
}

/// PoC for the round-r1 HIGH `mutable-pricer` (`CA-7e9b1e15be`), reported by the codex lens
/// (`r1a`) at `src/FeastEmissions.sol:418` and by no other lens.
///
/// The claim: settlement freezes a week's prices but not its QUOTE LIST. `settle` stores the
/// pricer's address (`wk.pricer`) and every quote's price (`priceOf[n][q]`), which are immutable
/// afterwards. But `_priced` — the function every claim, and every genesis grant, reads an
/// account's entitlement through — re-enumerates the list live:
///
///     address[] memory qs = FeastPricer(_weeks[n].pricer).quotes();
///
/// The stored address is fixed; what that address SAYS is not. An accepted module may return one
/// list during settlement and a longer one afterwards, with no bytecode change and no second
/// privileged call. A duplicated quote is counted twice into the claimant's numerator while the
/// denominator `wk.value[t]`, frozen at settlement, stays as it was — so `owed` for an already
/// settled week doubles, and `claim` debits the aggregate `liabilities` without ever checking the
/// affected week's own pot.
///
/// The lever's stated authority is narrower than this. Q26 preserves already-emitted pots, and
/// P14/P15 require claims to stay within their pots and settled weeks to stay settled. Replacing
/// the global pointer is meant to price the NEXT settlements, not to revalue past ones.
///
/// The assertion below is the codex unit's own: a settled entitlement does not change. Nothing in
/// this test touches the timelock after the module is accepted, and the clock is the only thing
/// that moves between the two reads.
contract EmissionsPricerMutationPoC is UnitFixture {
    PoolKey internal keyA;
    address internal coinA;
    uint256 internal constant FLIP_AT = 1_791_158_400 + 365 days;

    function setUp() public override {
        super.setUp();
        (coinA, keyA) = _create(address(wbnb), bytes32(uint256(1)));
        _buy(keyA, address(wbnb), 100e18, trader, referrer);
    }

    function test_aSettledEntitlementDoesNotChangeAfterItsWeekIsSettled() public {
        // The lever is pulled once, legitimately, through the timelock, before any settlement.
        FlippingPricer flip = new FlippingPricer(pricer, FLIP_AT);
        vm.prank(address(timelock));
        emissions.setPricer(address(flip));

        _launch(10e18);
        // v1.6.11: settling the window is an auction, not a swap, so it writes no oracle
        // observation. The platform coin needs a trade before it has a price at all.
        _firstPlatformTrade();
        _advance(10 minutes);

        // Settle every closed week with the accepted module. At this moment it reports one quote,
        // exactly as the real pricer does, so the week settles at the right prices and pots.
        uint256 n = emissions.settledCount() + 1;
        while (emissions.ledgerWeekOf(n) < ledger.currentWeek()) {
            emissions.settle(n);
            n++;
        }
        uint256 week = _weekOwing(trader);
        assertGt(week, 0, "the trader has a settled entitlement to protect");

        uint256 owedAtSettlement = emissions.owed(week, trader);
        uint256 traderPot = emissions.weekInfo(week).pot[1];
        assertGt(owedAtSettlement, 0, "and it is nonzero");

        // Nothing else happens. No call is made to the module, to emissions or to the timelock;
        // only the clock moves past the timestamp the accepted module was built with.
        _warpTo(FLIP_AT);

        assertEq(
            emissions.owed(week, trader),
            owedAtSettlement,
            "a settled week's entitlement changed after settlement, from the pricer's live quote list"
        );
        assertLe(
            emissions.owed(week, trader),
            traderPot,
            "and it now exceeds the week's own trader pot"
        );
    }

    /// @dev The first settled week in which `trader` is owed something.
    function _weekOwing(address account) internal view returns (uint256) {
        for (uint256 i = 1; i <= emissions.settledCount(); i++) {
            if (emissions.owed(i, account) != 0) return i;
        }
        return 0;
    }
}
