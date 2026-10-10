// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {FeastConstants} from "./FeastConstants.sol";
import {FeastMath} from "./FeastMath.sol";
import {FeastOracle} from "./FeastOracle.sol";
import {IFeastCLPoolManager} from "./venue/IFeastCLPoolManager.sol";
import {IPancakeV3Pool} from "./venue/IPancakeV3.sol";
import {PoolId} from "./venue/PoolId.sol";

/// @title What a quote token, and the platform coin, are worth in WBNB
/// @notice A fixed list of priced quote tokens, each with a pinned route of at
///         most two v3 pools to wrapped native, and the platform coin's own price
///         from the hook's oracle. Read by emissions when it settles a week.
///
/// @dev **It never reverts on a price it cannot vouch for; it says so.** A route
///      whose pool cannot answer over the averaging window, or whose spot has
///      been moved more than `MAX_TICK_DEVIATION` from its own average, returns
///      `Unpriceable` / `Moved`, and the caller's written rule decides what that
///      means. The discipline is the converter's: an average is read only from a
///      pool that holds enough history, and the value is taken from the spot
///      square-root price only when spot sits inside the bound around that
///      average — so no GPL tick mathematics, and nothing a single block can set.
///
///      **The routes are pinned, not supplied.** B3's H1 (an attacker-selected
///      route priced by the attacker's own pools) needs a caller who chooses the
///      path; nobody does here. A stock listed later is simply not priced — the
///      owner's ruling (Q13) — and a new list means a new pricer, installed by
///      the emissions contract's timelocked lever (Q26).
///
///      **So are their depths** (v1.6.25, AstraSec Q-3). Every pool on a route
///      must have been asked for a ring of `MIN_RING_CARDINALITY` observations
///      before the pricer is built — the constructor refuses one that has not —
///      and `_vouch` reads a live ring shallower than that as `Unpriceable`.
///      The operating rule is to call `increaseObservationCardinalityNext` on
///      every routed pool before listing it; anyone may, and it costs whoever
///      does. A deep ring is not yet a full one: until its history covers the
///      whole `TWAP_WINDOW` — a young pool, or a ring just widened — it is
///      `Unpriceable` too, and never averaged over less (v1.6.27).
contract FeastPricer {
    enum Status {
        Ok,
        Unpriceable,
        Moved
    }

    struct Route {
        address quote;
        address[] pools;
    }

    error EmptyRoute(address quote);
    error RouteTooLong(address quote, uint256 hops);
    error RouteDoesNotConnect(address quote, address pool);
    error RouteDoesNotEndInNative(address quote);
    error QuoteListedTwice(address quote);
    error NativeNeedsNoRoute();
    error QuoteNotEighteenDecimals(address quote);
    /// @notice A route's pool has not been asked to keep the ring the pricer
    ///         needs; `increaseObservationCardinalityNext` on it, then list.
    error RingTooShallow(address quote, address pool, uint16 cardinalityNext, uint16 required);

    uint256 internal constant ONE = 1 << 128;
    uint256 internal constant Q96 = 0x1000000000000000000000000;
    uint256 public constant MAX_HOPS = 2;

    address public immutable wrappedNative;
    FeastOracle public immutable oracle;
    IFeastCLPoolManager public immutable poolManager;
    /// @notice The platform coin and its pool on the venue — both known before
    ///         the platform coin exists.
    address public immutable platformCoin;
    PoolId public immutable platformPoolId;
    bool internal immutable _platformIsCurrency0;

    address[] internal _quotes;
    mapping(address quote => address[] pools) internal _routes;

    constructor(
        address wrappedNative_,
        address oracle_,
        address poolManager_,
        address platformCoin_,
        PoolId platformPoolId_,
        Route[] memory routes
    ) {
        wrappedNative = wrappedNative_;
        oracle = FeastOracle(oracle_);
        poolManager = IFeastCLPoolManager(poolManager_);
        platformCoin = platformCoin_;
        platformPoolId = platformPoolId_;
        _platformIsCurrency0 = platformCoin_ < wrappedNative_;

        // Wrapped native is priced at one and needs no route; it is always listed.
        // Every listed quote is an 18-decimal token (round 4 L1): the internal
        // fill's exact price domain is sized for that, and a census of every
        // planned quote at the pinned block found no other.
        _requireEighteenDecimals(wrappedNative_);
        _quotes.push(wrappedNative_);
        for (uint256 i = 0; i < routes.length; i++) {
            Route memory r = routes[i];
            if (r.quote == wrappedNative_) revert NativeNeedsNoRoute();
            if (_routes[r.quote].length != 0) revert QuoteListedTwice(r.quote);
            if (r.pools.length == 0) revert EmptyRoute(r.quote);
            if (r.pools.length > MAX_HOPS) revert RouteTooLong(r.quote, r.pools.length);
            address token = r.quote;
            for (uint256 h = 0; h < r.pools.length; h++) {
                IPancakeV3Pool pool = IPancakeV3Pool(r.pools[h]);
                address t0 = pool.token0();
                address t1 = pool.token1();
                if (token != t0 && token != t1) revert RouteDoesNotConnect(r.quote, r.pools[h]);
                // v1.6.25 (AstraSec Q-3): the ring the pool has been ASKED for,
                // which is what a lister controls and what never shrinks. A
                // route through a shallower one is a deployment that fails by
                // name rather than a quote any later write can zero.
                (,,,, uint16 ringNext,,) = pool.slot0();
                if (ringNext < FeastConstants.MIN_RING_CARDINALITY) {
                    revert RingTooShallow(r.quote, r.pools[h], ringNext, FeastConstants.MIN_RING_CARDINALITY);
                }
                token = token == t0 ? t1 : t0;
            }
            if (token != wrappedNative_) revert RouteDoesNotEndInNative(r.quote);
            _requireEighteenDecimals(r.quote);
            _routes[r.quote] = r.pools;
            _quotes.push(r.quote);
        }
    }

    // --- the list -----------------------------------------------------------

    /// @notice Every priced quote token, wrapped native first.
    function quotes() external view returns (address[] memory) {
        return _quotes;
    }

    function routeOf(address quote) external view returns (address[] memory) {
        return _routes[quote];
    }

    // --- quote tokens -----------------------------------------------------------

    /// @notice WBNB per one raw unit of `quote`, as a 128.128 fixed-point number.
    /// @return status `Ok` with a price, or why there is none. A token not on the
    ///         list is `Unpriceable`.
    function priceQ128(address quote) external view returns (Status status, uint256 price) {
        if (quote == wrappedNative) return (Status.Ok, ONE);
        address[] storage pools = _routes[quote];
        if (pools.length == 0) return (Status.Unpriceable, 0);
        price = ONE;
        address token = quote;
        for (uint256 h = 0; h < pools.length; h++) {
            IPancakeV3Pool pool = IPancakeV3Pool(pools[h]);
            (Status s, uint160 sqrtPriceX96) = _vouch(pool);
            if (s != Status.Ok) return (s, 0);
            bool inIs0 = token == pool.token0();
            // Each hop's ratio fits a word over the venue's whole price range;
            // their product need not (round 4 L2). A price no word can hold is
            // no price: unpriceable, and the caller's written rule applies.
            uint256 ratio = _ratioQ128(sqrtPriceX96, inIs0);
            (uint256 high,) = Math.mul512(price, ratio);
            if (high >= ONE) return (Status.Unpriceable, 0);
            price = Math.mulDiv(price, ratio, ONE);
            token = inIs0 ? pool.token1() : pool.token0();
        }
        return (Status.Ok, price);
    }

    // --- the platform coin ------------------------------------------------------

    /// @notice Platform coin per one raw unit of WBNB, as a 128.128 number.
    /// @return status `Unpriceable` when the platform coin's pool has no price
    ///         history the oracle will answer for — before genesis, and for its
    ///         first `TWAP_WINDOW` (ten minutes) of trading. Emissions reads
    ///         that, before launch only, as the written first-week rule (token
    ///         cap only). `Moved` when spot has been pushed from the average:
    ///         retry, never guess.
    function platformPerNativeQ128() external view returns (Status status, uint256 price) {
        (uint160 sqrtPriceX96, int24 spotTick,,) = poolManager.getSlot0(platformPoolId);
        // v1.6.6 (Q2): the same bound as `_vouch`'s, for the same reason — this
        // reader reaches the identical `_ratioQ128`. It subsumes the zero check
        // that stood here, which was this contract's only guard of the kind.
        if (!_inVenueRange(sqrtPriceX96)) return (Status.Unpriceable, 0);
        if (oracle.observationCount(platformPoolId) == 0) return (Status.Unpriceable, 0);
        // v1.6.24 (AstraSec L-2): `twapTick` REFUSES below a whole window of
        // history now, rather than answering over what exists. This guard asked
        // about `MIN_OBSERVATION_AGE`, which was the oracle's old refusal point;
        // left there, the pool's sixth to tenth minutes would revert out of a
        // reader whose first sentence is that it never reverts on a price it
        // cannot vouch for — and `FeastEmissions.settle` with it.
        if (oracle.historySeconds(platformPoolId) < FeastConstants.TWAP_WINDOW) {
            return (Status.Unpriceable, 0);
        }
        int24 averageTick = oracle.twapTick(platformPoolId);
        int24 deviation = spotTick > averageTick ? spotTick - averageTick : averageTick - spotTick;
        if (deviation > FeastConstants.MAX_TICK_DEVIATION) return (Status.Moved, 0);
        // Platform coin per native: from native to the platform coin.
        return (Status.Ok, _ratioQ128(sqrtPriceX96, !_platformIsCurrency0));
    }

    // --- internals --------------------------------------------------------------

    function _requireEighteenDecimals(address token) internal view {
        if (IERC20Metadata(token).decimals() != 18) revert QuoteNotEighteenDecimals(token);
    }

    /// @dev Is a square-root price one the venue itself could be holding?
    ///
    ///      v1.6.6 (`Q2`, from the v1.6.5 sweep's row 12). `_ratioQ128`'s
    ///      reciprocal branch computes `2^320 / sqrtP^2`, which leaves a word at
    ///      `sqrtP <= 2^32` — a measured 161 443 units below the venue's own
    ///      `MIN_SQRT_RATIO` — and divides by zero at `sqrtP == 0`. Neither is
    ///      reachable from a real v3 pool, which is why this is a bound and not
    ///      a finding; but nothing in THIS contract enforced it, and a pool is
    ///      an external address whose `slot0` this contract does not own.
    ///
    ///      A panic there would contradict the first sentence of this contract —
    ///      it never reverts on a price it cannot vouch for, it says so — and
    ///      `FeastEmissions.settle` reads `priceQ128` in a loop over every
    ///      listed quote, so one misbehaving pinned pool would block every
    ///      emission week for good. That is `CA-5203dcf236`'s shape reached from
    ///      the other side, and the answer is the one this contract already
    ///      gives for a price it cannot use: say so, and let the caller's
    ///      written rule decide.
    ///
    ///      The bound is the venue's **stored-price** domain, `[MIN, MAX)` — and
    ///      that is not the domain `FeastMath.sqrtPriceLimit` clamps into, which
    ///      is the strict one (v1.6.6 round 1, r1v: the first spelling of this
    ///      predicate excluded both ends and so refused a price a pool can
    ///      legitimately hold). `TickMath.getTickAtSqrtRatio`, which
    ///      `CLPool.initialize` calls, accepts exactly
    ///      `MIN_SQRT_RATIO <= sqrtPriceX96 < MAX_SQRT_RATIO`: the minimum is a
    ///      real tick's price, and the maximum is the one price the pool can
    ///      never reach. A SWAP LIMIT must additionally be strictly inside,
    ///      which is a different question about a different quantity.
    ///
    ///      The reciprocal at the minimum fits a word with 0.0075 % to spare, so
    ///      admitting the minimum costs nothing arithmetically — it is simply
    ///      what the venue means.
    function _inVenueRange(uint160 sqrtPriceX96) internal pure returns (bool) {
        return sqrtPriceX96 >= FeastMath.MIN_SQRT_RATIO && sqrtPriceX96 < FeastMath.MAX_SQRT_RATIO;
    }

    /// @dev Whether a v3 pool can vouch for its spot price: enough observations,
    ///      enough history, spot inside the bound around the average.
    function _vouch(IPancakeV3Pool pool) internal view returns (Status, uint160) {
        (uint160 sqrtPriceX96, int24 spotTick, uint16 index, uint16 cardinality,,,) = pool.slot0();
        // v1.6.6 (Q2): a price outside the venue's own range is not a price this
        // contract can square or invert. Refused here, before the history reads,
        // because it is a statement about the number and not about the pool.
        if (!_inVenueRange(sqrtPriceX96)) return (Status.Unpriceable, 0);
        if (cardinality < 2) return (Status.Unpriceable, 0);
        // v1.6.25 (AstraSec Q-3). The line above is the arithmetic's own floor:
        // a ring of one has no average, and it stands whatever the constant is.
        // This is the depth no write can see through. A ring of two accepted
        // here was made `Unpriceable` by one in-range mint or burn just after a
        // trade, and past `PRICING_GRACE` that counts the quote's week as zero.
        // A live ring below the minimum is refused outright instead, from the
        // moment of listing, until the pool's writes reach the end of its old
        // ring and it takes the depth the constructor saw requested.
        if (cardinality < FeastConstants.MIN_RING_CARDINALITY) return (Status.Unpriceable, 0);
        // v1.6.27 (`CA-0d9ade0259`, AstraSec L-2's shape at this reader): a
        // ring whose history is shorter than the window is refused, the way a
        // ring too young always was. Until v1.6.27 it was refused only under
        // `MIN_OBSERVATION_AGE` and averaged over `min(age, TWAP_WINDOW)` above
        // it — so a ring that had just GROWN to 601, whose new slots are empty
        // and whose oldest observation is slot 0, answered `Ok` over as little
        // as five minutes. A full ring of 601 spans the window by construction
        // (one observation a second at most); one that is not full waits until
        // its history does.
        uint32 age = _oldestObservationAge(pool, index, cardinality);
        if (age < FeastConstants.TWAP_WINDOW) return (Status.Unpriceable, 0);
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = FeastConstants.TWAP_WINDOW;
        try pool.observe(secondsAgos) returns (int56[] memory cumulatives, uint160[] memory) {
            int24 averageTick = int24((cumulatives[1] - cumulatives[0]) / int56(uint56(FeastConstants.TWAP_WINDOW)));
            int24 deviation = spotTick > averageTick ? spotTick - averageTick : averageTick - spotTick;
            if (deviation > FeastConstants.MAX_TICK_DEVIATION) return (Status.Moved, 0);
            return (Status.Ok, sqrtPriceX96);
        } catch {
            return (Status.Unpriceable, 0);
        }
    }

    /// @dev Output per input unit across one pool, 128.128: token1 per token0 is
    ///      (sqrtP / 2^96)^2, and the reciprocal the other way. Plain 512-bit
    ///      multiply-divide on a price that is already a ratio.
    ///
    ///      **v1.6.5 sweep, row 12 — CLOSED in v1.6.6 by `_inVenueRange`**, which
    ///      both readers apply before they reach this function, so every input
    ///      here is inside the venue's own STORED-price range `[MIN, MAX)` — the
    ///      minimum included, because a pool can hold it. Both branches then fit
    ///      a word, and the numbers say by how much:
    ///
    ///        - rising, `sqrtP^2 / 2^64`: bounded BY TYPE, guard or no guard. At
    ///          `type(uint160).max` the result is exactly `2^256 - 2^97`, so it
    ///          fits for every `uint160` (measured).
    ///        - reciprocal, `2^320 / sqrtP^2`: at `MIN_SQRT_RATIO` the result is
    ///          `0.99992 * 2^256`, inside a word by 0.0075 %. It leaves a word
    ///          at `sqrtP <= 2^32 = 4_294_967_296`, a measured 161 443 units
    ///          BELOW that floor, and divides by zero at `sqrtP == 0`. The guard
    ///          is what keeps either out, rather than the venue's good behaviour.
    ///
    ///      Why a guard at all, for a number no real v3 pool reports: a panic
    ///      here would contradict this contract's own first sentence — it never
    ///      reverts on a price it cannot vouch for, it says so — and
    ///      `FeastEmissions.settle` reads `priceQ128` in a loop over every
    ///      listed quote, so one misbehaving pinned pool would block every
    ///      emission week for good. That is `CA-5203dcf236`'s shape reached from
    ///      the other side.
    function _ratioQ128(uint160 sqrtPriceX96, bool inIsToken0) internal pure returns (uint256) {
        return inIsToken0
            ? Math.mulDiv(sqrtPriceX96, sqrtPriceX96, 1 << 64)
            : Math.mulDiv(Math.mulDiv(ONE, Q96, sqrtPriceX96), Q96, sqrtPriceX96);
    }

    function _oldestObservationAge(IPancakeV3Pool pool, uint16 index, uint16 cardinality)
        internal
        view
        returns (uint32)
    {
        uint256 oldestIndex = (uint256(index) + 1) % cardinality;
        (uint32 ts,,, bool initialized) = pool.observations(oldestIndex);
        if (!initialized) {
            (ts,,, initialized) = pool.observations(0);
            if (!initialized) return 0;
        }
        // Full-width subtraction, truncated after: right across the 2106
        // rollover, when a stored uint32 timestamp has wrapped and the naive
        // subtraction would underflow (v1.6.1, CA-e2ba62d849).
        return uint32(block.timestamp - uint256(ts));
    }
}
