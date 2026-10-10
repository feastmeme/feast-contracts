// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FeastConstants} from "../../../src/FeastConstants.sol";
import {FeastEmissions} from "../../../src/FeastEmissions.sol";
import {FeastGenesis} from "../../../src/FeastGenesis.sol";
import {FeastPricer} from "../../../src/FeastPricer.sol";
import {PoolKey} from "../../../src/venue/PoolKey.sol";
import {RingV3Pool} from "../../utils/RingV3Pool.sol";
import {UnitFixture} from "../../utils/UnitFixture.sol";

/// AstraSec Q-3 (report of 2026-10-02, scope `e5c0a77`): **a shallow v3
/// observation ring let one write zero a quote's week.** Reproduced on v1.6.24
/// (`2ebf5ef`), where `FeastPricer._vouch` (`src/FeastPricer.sol:233-236`)
/// accepted any ring of two or more observations, refused one whose oldest
/// observation was under `MIN_OBSERVATION_AGE` (300 s) old, and otherwise
/// shortened the window to that age; and `FeastEmissions.settle`
/// (`src/FeastEmissions.sol:402-403`) counts a quote it cannot price as zero
/// once `PRICING_GRACE` is over.
///
/// A ring of two holds the last two writes. A v3 pool writes on an in-range
/// mint or burn and on a swap that moves the tick, so when the pool had just
/// traded, one more write — anyone's in-range liquidity change — left both
/// observations inside the last 300 seconds, and the quote read `Unpriceable`.
/// The PoC commit before the fix asserted that; each scenario is kept here
/// asserting the outcome now.
///
/// **Fixed in v1.6.25.** `FeastConstants.MIN_RING_CARDINALITY` is
/// `TWAP_WINDOW + 1`: a pool writes at most one observation per second, so a
/// full ring of that many spans at least the whole window, and no write
/// pattern can make it younger. The pricer refuses at construction a route
/// pool not asked for that ring, and `_vouch` reads a live ring shallower than
/// it as `Unpriceable` — deterministically, from the moment of listing, instead
/// of whenever someone writes. The operating rule is to call
/// `increaseObservationCardinalityNext` on every routed pool before listing it;
/// anyone may, and it costs whoever does.
///
/// The pool here is `RingV3Pool`, the venue's observation rules restated, not
/// `MockV3Pool`'s settable "oldest" timestamp: what this asserts is what a ring
/// of a given size can be made to say.
contract Q3ShallowRingZeroesAQuote is UnitFixture {
    uint16 internal constant MIN = FeastConstants.MIN_RING_CARDINALITY;

    PoolKey internal stockKey;
    address internal attacker = address(0xA77AC4);

    function setUp() public override {
        super.setUp();
        // Week one carries fees in the stock.
        (, stockKey) = _create(address(stock), bytes32(uint256(0x53)));
        _buy(stockKey, address(stock), 50e18, trader2, address(0));
    }

    function _routeThrough(address pool) internal view returns (FeastPricer.Route[] memory routes) {
        routes = new FeastPricer.Route[](1);
        routes[0].quote = address(stock);
        routes[0].pools = new address[](1);
        routes[0].pools[0] = pool;
    }

    function _list(address pool) internal returns (FeastPricer p, FeastEmissions e) {
        p = new FeastPricer(address(wbnb), address(oracle), address(pm), feast, feastPoolId, _routeThrough(pool));
        e = new FeastEmissions(
            address(ledger),
            address(hook),
            feast,
            feastPoolId,
            address(timelock),
            address(p),
            ledger.weekOf(OPENING),
            address(guardian)
        );
    }

    /// @dev A pool at one to one whose ring has been asked for `size` slots and
    ///      has taken them: the request, then the one write that reaches the
    ///      end of a ring of one.
    function _poolWithRing(uint16 size) internal returns (RingV3Pool ring) {
        ring = new RingV3Pool(address(stock), address(wbnb), SQRT_PRICE_1_1, 0);
        ring.increaseObservationCardinalityNext(size);
        _advance(60);
        ring.poke();
    }

    /// @dev Week one's close, and the end of its pricing grace, where
    ///      `Unpriceable` stops holding the week and starts counting as zero.
    function _pastTheGrace(FeastEmissions e) internal {
        _warpTo(ledger.weekStart(e.ledgerWeekOf(1) + 1) + FeastGenesis.PRICING_GRACE);
    }

    // --- the constant ------------------------------------------------------------

    /// The minimum is one observation per second of the window, and one more:
    /// a full ring of `n` slots spans at least `n - 1` seconds whoever writes
    /// it, so `TWAP_WINDOW + 1` is the least that spans the window. Never under
    /// two, the floor `_vouch` keeps for a ring that has no average at all.
    function test_theMinimumIsAWholeWindowOfSecondsAndOneMore() public pure {
        assertEq(uint256(MIN), uint256(FeastConstants.TWAP_WINDOW) + 1, "one per second of the window, plus one");
        assertEq(MIN, 601, "601 observations");
        assertGe(MIN, 2, "never under the floor of two");
    }

    /// The arithmetic the constant rests on, on the venue's own ring rules: a
    /// ring written every second for as long as anyone likes spans exactly
    /// `size - 1` seconds once full. At the minimum that is the whole window;
    /// one slot fewer and it is a second short. A witness at any looser size
    /// would pass against a minimum anywhere above it.
    function test_aFullRingWrittenEverySecondSpansOneSecondPerSlotLessOne() public {
        RingV3Pool atMin = new RingV3Pool(address(stock), address(wbnb), SQRT_PRICE_1_1, 0);
        RingV3Pool oneShort = new RingV3Pool(address(stock), address(wbnb), SQRT_PRICE_1_1, 0);
        atMin.increaseObservationCardinalityNext(MIN);
        oneShort.increaseObservationCardinalityNext(MIN - 1);
        for (uint256 i = 0; i < 2 * uint256(MIN); i++) {
            _advance(1);
            atMin.poke();
            oneShort.poke();
        }
        assertEq(atMin.oldestAge(), FeastConstants.TWAP_WINDOW, "at the minimum: exactly the window");
        assertEq(oneShort.oldestAge(), FeastConstants.TWAP_WINDOW - 1, "one slot fewer: a second short of it");
    }

    // --- at listing --------------------------------------------------------------

    /// **The PoC's pool is refused at listing now**, by name, with the ring it
    /// was asked for and the ring it needs. From both sides of the bound: one
    /// slot short is refused, the minimum is listed. Kills: no listing check,
    /// and a check against the wrong side of the minimum.
    function test_aRouteThroughAShallowRingIsRefusedAtListing() public {
        RingV3Pool two = _poolWithRing(2);
        vm.expectRevert(
            abi.encodeWithSelector(FeastPricer.RingTooShallow.selector, address(stock), address(two), uint16(2), MIN)
        );
        this.list(address(two));

        RingV3Pool oneShort = _poolWithRing(MIN - 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                FeastPricer.RingTooShallow.selector, address(stock), address(oneShort), MIN - 1, MIN
            )
        );
        this.list(address(oneShort));

        this.list(address(_poolWithRing(MIN)));
    }

    /// @dev External, so `expectRevert` covers exactly the construction.
    function list(address pool) external returns (FeastPricer) {
        return new FeastPricer(address(wbnb), address(oracle), address(pm), feast, feastPoolId, _routeThrough(pool));
    }

    /// The read at its exact bound, on the fixture's own listed pool, with an
    /// hour of history behind it: a live ring one slot short of the minimum is
    /// `Unpriceable`, and so is the ring of two v1.6.24 read; the minimum
    /// prices. Kills: no read check, and a check on the wrong side of the bound.
    function test_aLiveRingShallowerThanTheMinimumIsUnpriceable() public {
        stockPool.setOldestTimestamp(uint32(clock - 1 hours));
        stockPool.setCardinality(MIN - 1);
        (FeastPricer.Status s,) = pricer.priceQ128(address(stock));
        assertEq(uint8(s), uint8(FeastPricer.Status.Unpriceable), "one slot short of the minimum: refused");
        stockPool.setCardinality(2);
        (s,) = pricer.priceQ128(address(stock));
        assertEq(uint8(s), uint8(FeastPricer.Status.Unpriceable), "the ring of two v1.6.24 read: refused");
        stockPool.setCardinality(MIN);
        (s,) = pricer.priceQ128(address(stock));
        assertEq(uint8(s), uint8(FeastPricer.Status.Ok), "at the minimum: priced");
    }

    /// The listing check reads the ring the pool has been ASKED for, which is
    /// what a lister controls: one permissionless call. The venue widens the
    /// live ring only at a write that finds its index on the last slot, so
    /// until then the ring is the old one and the quote reads `Unpriceable` —
    /// from the moment of listing, whatever anyone writes, rather than when
    /// someone chooses to write. Then it prices, over a ring nobody can see
    /// through.
    function test_aListedRingIsUnpriceableUntilThePoolHasWidenedIt() public {
        RingV3Pool ring = _poolWithRing(2);
        _advance(1);
        ring.poke(); // the index wraps to the first of the two slots
        _advance(1 hours);
        ring.increaseObservationCardinalityNext(MIN); // the operating rule, done
        (FeastPricer p,) = _list(address(ring));

        (FeastPricer.Status s,) = p.priceQ128(address(stock));
        assertEq(uint8(s), uint8(FeastPricer.Status.Unpriceable), "a live ring of two is not read, however old");

        _advance(1);
        ring.poke(); // onto the last slot of the ring of two: not widened yet
        (,,, uint16 live,,,) = ring.slot0();
        assertEq(live, 2, "the request waits for a write at the end of the ring");
        (s,) = p.priceQ128(address(stock));
        assertEq(uint8(s), uint8(FeastPricer.Status.Unpriceable), "and so does the quote");

        _advance(1);
        ring.poke(); // the write that finds the index on the last slot takes the new size
        (,,, live,,,) = ring.slot0();
        assertEq(live, MIN, "the pool's next write widened it");
        (s,) = p.priceQ128(address(stock));
        assertEq(uint8(s), uint8(FeastPricer.Status.Ok), "and the quote prices");
    }

    // --- at settlement -------------------------------------------------------------

    /// **The finding, at the minimum.** The PoC's exact sequence — an ordinary
    /// trade a minute before settlement and an in-range write just before it —
    /// against a ring of the minimum size, listed by the rule. The ring's oldest
    /// observation is untouched by both writes, so the quote prices and the
    /// week counts the stock's fees. Kills: a minimum a single write can see
    /// through.
    function test_theFrontRunThatZeroedAWeekDoesNotReachARingOfTheMinimum() public {
        RingV3Pool ring = _poolWithRing(MIN);
        (FeastPricer p, FeastEmissions e) = _list(address(ring));
        _pastTheGrace(e);
        _advance(1);
        ring.swapTo(SQRT_PRICE_1_1, 1); // the ordinary trade
        _advance(60);
        vm.prank(attacker);
        ring.poke(); // the front-run

        assertGe(ring.oldestAge(), FeastConstants.TWAP_WINDOW, "the ring still spans the window");
        (FeastPricer.Status s,) = p.priceQ128(address(stock));
        assertEq(uint8(s), uint8(FeastPricer.Status.Ok), "the quote prices");
        e.settle(1);
        assertGt(e.priceOf(1, address(stock)), 0, "and the week counts the stock's fees");
    }

    /// The front-run at its most patient: a write in every second for a whole
    /// window and a half, from a ring of the minimum that the same writes have
    /// filled. The ring never spans less than the window, the window is never
    /// shortened, and the quote never reads `Unpriceable`. Kills: a minimum
    /// below `TWAP_WINDOW + 1`, which a write per second would see through.
    function test_noWritePatternMakesARingOfTheMinimumTooYoung() public {
        RingV3Pool ring = _poolWithRing(MIN);
        (FeastPricer p,) = _list(address(ring));
        _advance(1 hours); // a pool with history, as a listed one has
        for (uint256 i = 0; i < uint256(MIN) + FeastConstants.TWAP_WINDOW / 2; i++) {
            _advance(1);
            ring.poke();
            (FeastPricer.Status s,) = p.priceQ128(address(stock));
            assertEq(uint8(s), uint8(FeastPricer.Status.Ok), "a write every second never zeroes the quote");
        }
        assertEq(ring.oldestAge(), FeastConstants.TWAP_WINDOW, "full, and spanning exactly the window");
    }

    /// The other half of the old surface: a quote whose ring IS too shallow
    /// still counts as zero after the grace — `Q11`'s written rule, unchanged —
    /// but now it is `Unpriceable` from listing onwards, visibly, rather than
    /// whenever someone writes. Here, a pool listed by the rule and never
    /// written to again: the week counts it zero, and that was visible on day
    /// one.
    function test_aRingThatNeverWidensIsUnpriceableFromListingNotFromAWrite() public {
        RingV3Pool ring = _poolWithRing(2);
        _advance(1 hours); // history enough: what refuses below is the ring, not its age
        ring.increaseObservationCardinalityNext(MIN);
        (FeastPricer p, FeastEmissions e) = _list(address(ring));
        (FeastPricer.Status s,) = p.priceQ128(address(stock));
        assertEq(uint8(s), uint8(FeastPricer.Status.Unpriceable), "unpriceable the day it is listed");

        _pastTheGrace(e);
        e.settle(1);
        assertEq(e.priceOf(1, address(stock)), 0, "and counted zero after the grace, as the written rule says");
    }
}
