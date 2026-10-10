// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FeastConstants} from "../../../src/FeastConstants.sol";
import {FeastEmissions} from "../../../src/FeastEmissions.sol";
import {FeastGenesis} from "../../../src/FeastGenesis.sol";
import {FeastPricer} from "../../../src/FeastPricer.sol";
import {PoolKey} from "../../../src/venue/PoolKey.sol";
import {UnitFixture} from "../../utils/UnitFixture.sol";

/// PoC for the v1.6.6 dual-family pack's MEDIUM `pre-launch-value-cap`, reported by the
/// Claude-family lens (`r1a2-claude`) at `src/FeastEmissions.sol:342-377`, and by no other lens.
///
/// The claim: `settle` decides the first-week rule on PRICE AVAILABILITY, while the contract's
/// own docstring says it is decided on the LAUNCH STATE.
///
///     if (ps == FeastPricer.Status.Ok) {
///         ... the value cap ...
///     } else if (claimsOpen()) {
///         ...
///     } else {
///         wk.tokenCapOnly = true;          // "before launch only"
///     }
///
/// `claimsOpen()` is consulted only in the branches BELOW the value cap. So a week settled while
/// the platform coin's pool has not opened takes the value cap whenever a price happens to exist
/// — and `src/FeastEmissions.sol:30-35` says, in as many words:
///
///     a pre-launch week settles under the written first-week rule (the token cap alone — no
///     price is ever guessed) at the full weekly cap (Q25). That rule is keyed on the launch
///     state, never on price availability (round 4 H1)
///
/// **A price does exist there, for an hour.** The launch window's own settling swap writes the
/// platform pool's first oracle observation; `MIN_OBSERVATION_AGE` is 300 seconds and
/// `SETTLE_GRACE` — the gap between the window closing and the pool opening — is an hour. So for
/// 55 of those 60 minutes `platformPerNativeQ128()` returns `Ok` (the pool is gated, so spot is
/// its own average) while `claimsOpen()` is still false.
///
/// The fixture's calendar puts the seam exactly where the protocol's own recipe does: emission
/// week 2 closes at the very second the launch window ends (`script/Genesis.s.sol` puts both on a
/// Monday 00:00). Which cap that week gets is then decided by a permissionless race between two
/// callers of `settle(2)` five minutes apart — and this project's own test note at
/// `test/FeastEmissions.t.sol` records the gap the two rules produce as roughly 4.4 million
/// against 150.
///
/// Nothing here is hostile: no privilege, no manipulation, no unusual token. Only the clock.
///
/// **v1.6.11 removed the hour.** The launch window no longer buys: it clears a uniform-price
/// auction arithmetically and seeds the pool through the factory, and neither an `initialize`
/// nor a `modifyLiquidity` writes an oracle observation — only a swap does. Before `openAt` the
/// gate lets nobody but the registered opener trade, and the opener no longer trades. So there
/// is no longer any instant at which the platform coin has a price the pricer will vouch for and
/// the pool has not opened: the seam this PoC exploited has no price on EITHER side of it now.
///
/// That makes the witness below no longer straddle its bound — not because the assertion weakened
/// but because the shape it straddled is gone. It is kept, rewritten honestly, for two reasons:
/// it pins the branch order in `settle` that the finding was really about (the launch state is
/// consulted, not price availability), and it pins the v1.6.11 property that the auction writes
/// no observation, so a later change that made settlement swap again would show up here.
contract EmissionsPreLaunchValueCapPoC is UnitFixture {
    address internal coinA;
    PoolKey internal keyA;

    function setUp() public override {
        super.setUp();
        (coinA, keyA) = _create(address(wbnb), bytes32(uint256(1)));
    }

    /// The window has settled, the pool is open at the clearing price with the seed in place,
    /// and the pool has NOT opened to traders. A week closing on that seam must settle under the
    /// first-week rule — and from v1.6.11 the pricer has nothing to say there either, because
    /// settlement placed liquidity without ever swapping.
    function test_aWeekSettledBeforeThePoolOpensTakesTheTokenCapAlone() public {
        // Genesis lands inside emission week 2, so a buy here gives that week fees.
        _genesis();
        _buy(keyA, address(wbnb), 100e18, trader, referrer);

        // Week 1 closed before genesis and carries no fees, so it emits nothing;
        // settlement is strictly ordered, so it has to go first regardless.
        emissions.settle(1);
        assertEq(emissions.settledCount(), 1, "week 1 out of the way");
        assertEq(emissions.weekInfo(1).pot[emissions.TRADER()], 0, "and it had no fees to pay");

        // The launch window settles. Before v1.6.11 this was a swap, and it wrote the platform
        // pool's first oracle observation; it is now an arithmetic clearing and a seed, and it
        // writes none.
        _warpTo(windowStart + 1);
        address committer = address(0xC0D1);
        vm.deal(committer, 10e18);
        vm.prank(committer);
        window.commit{value: 10e18}();
        _warpTo(window.endsAt());
        window.settle();

        // Week 2 closes at the very second the window ends.
        uint256 w2 = emissions.ledgerWeekOf(2);
        assertEq(ledger.weekStart(w2 + 1), window.endsAt(), "week 2 closes as the window closes");

        // Five minutes later — the instant the finding turned on, when the settling swap's
        // observation would have aged past `MIN_OBSERVATION_AGE`. There is no observation to age.
        _advance(FeastConstants.MIN_OBSERVATION_AGE + 1);
        (FeastPricer.Status ps,) = pricer.platformPerNativeQ128();
        assertEq(
            uint8(ps),
            uint8(FeastPricer.Status.Unpriceable),
            "v1.6.11: settlement seeds without swapping, so the pool has a price and no history"
        );

        // And the pool has NOT opened: nobody can claim, nothing can expire.
        assertFalse(emissions.claimsOpen(), "the platform coin's pool has not opened");

        emissions.settle(2);

        // The written rule, asserted as the docstring states it.
        FeastEmissions.Week memory w = emissions.weekInfo(2);
        assertTrue(w.tokenCapOnly, "a pre-launch week settles under the first-week rule");
        uint256 cap = emissions.tokenCap(2);
        assertEq(w.pot[0], cap * FeastGenesis.EARLY_REFERRER_BPS / FeastGenesis.BPS, "referrers 40%");
        assertEq(w.pot[1], cap * FeastGenesis.EARLY_TRADER_BPS / FeastGenesis.BPS, "traders 45%");
        assertEq(w.pot[2], cap * FeastGenesis.EARLY_CREATOR_BPS / FeastGenesis.BPS, "creators 15%");
    }

    /// The control, so the witness is known to straddle its bound rather than to sit on one side
    /// of it: the SAME week, settled five minutes earlier — before the oracle has its minimum
    /// history — takes the first-week rule today, and must keep taking it after the fix. The only
    /// difference between this test and the one above is 301 seconds of clock.
    function test_theSameWeekFiveMinutesEarlierAlreadyTakesTheTokenCap() public {
        _genesis();
        _buy(keyA, address(wbnb), 100e18, trader, referrer);
        emissions.settle(1);

        _warpTo(windowStart + 1);
        address committer = address(0xC0D1);
        vm.deal(committer, 10e18);
        vm.prank(committer);
        window.commit{value: 10e18}();
        _warpTo(window.endsAt());
        window.settle();

        // One second after the close: the oracle has no history the pricer will read.
        _advance(1);
        (FeastPricer.Status ps,) = pricer.platformPerNativeQ128();
        assertEq(uint8(ps), uint8(FeastPricer.Status.Unpriceable), "too new to vouch for");
        assertFalse(emissions.claimsOpen(), "and the pool has not opened either");

        emissions.settle(2);

        FeastEmissions.Week memory w = emissions.weekInfo(2);
        assertTrue(w.tokenCapOnly, "the first-week rule, on the side the code already agrees with");
        uint256 cap = emissions.tokenCap(2);
        assertEq(w.pot[1], cap * FeastGenesis.EARLY_TRADER_BPS / FeastGenesis.BPS, "traders 45%");
    }
}
