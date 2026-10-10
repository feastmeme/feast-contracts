// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {FeastConstants} from "./FeastConstants.sol";
import {FeastMath} from "./FeastMath.sol";
import {IPancakeV3Factory, IPancakeV3Pool} from "./venue/IPancakeV3.sol";

/// @title Route a quote token to the chain's own asset
/// @notice Swaps an accrued quote token along a caller-supplied path, refusing
///         any hop it cannot price honestly.
///
/// @dev There is no pool pairing a tokenised stock directly against the chain's
///      asset, so the route is multi-hop — typically quote to a stablecoin and
///      then to wrapped native. The path is supplied by the caller and is
///      *untrusted*: the safety property is the bound, not the path, which is
///      what lets liquidity migrate without bricking the button.
///
///      **The bound is expressed in ticks, not in token amounts.** Converting a
///      time-weighted tick into a minimum output requires the venue's tick-math
///      library, which is GPL-licensed, and reimplementing it would mean
///      reproducing its constants. Comparing ticks needs none of that: before
///      each hop the pool's spot tick must sit within `MAX_TICK_DEVIATION` of
///      its own time-weighted tick, and the swap carries a price limit derived
///      from the spot square-root price by plain multiplication. The first check
///      refuses to trade into a price somebody has just moved; the second bounds
///      how far this swap may move it. Together they are the slippage bound,
///      with no borrowed mathematics.
///
///      **A pool whose oracle cannot answer is refused, not trusted.** Probed on
///      chain, the v3 pool for the sample quote token has an observation
///      cardinality of one, which makes its ten-minute average equal to its spot
///      tick — a bound that is not a bound. Growing a pool's cardinality is
///      permissionless, so this is a step in the deployment recipe rather than a
///      dead end; but until it is done, this contract refuses that hop, and the
///      quote-denominated claim is what stops anyone's money being trapped
///      meanwhile.
contract FeastConverter {
    using SafeERC20 for IERC20;

    error EmptyRoute();
    error NoPoolForHop(address tokenIn, address tokenOut, uint24 fee);
    error OracleUnusable(address pool, uint16 cardinality, uint32 age);
    error SpotTooFarFromAverage(address pool, int24 spotTick, int24 averageTick);
    error RouteMustEndInNative(address lastToken);
    error NothingOut();
    /// @dev A leg of a conversion delivered nothing, or left this contract with
    ///      less than it started with. Named, so the refusal is the same with or
    ///      without a stray balance rather than a checked-subtraction panic
    ///      whose reachability depends on one (v1.6.3 round 1, r1v).
    error NothingArrived(address token, uint256 heldBefore, uint256 heldAfter);
    /// @dev A hop's payment would exceed what that hop brought. The conversion
    ///      never dips into balance it did not bring (v1.6.3 round 1, r1v).
    error AskExceedsHop(address token, uint256 ask, uint256 brought);
    error NotThePool();
    error NotTheHook();
    error RouteTooLong(uint256 hops, uint256 max);
    error RouteRevisitsAToken(address token);
    error RouteReturnedTooLittle(uint256 got, uint256 expected, uint256 floor);
    /// @notice A hop's expected output needs more than a word to write down.
    error RouteExpectationTooLarge(address pool, uint256 amountIn);
    error RouteWouldNotFill(uint256 consumed, uint256 offered);
    /// @notice The route delivered less than the beneficiary said they would
    ///         accept (v1.6.24, AstraSec M-1).
    error BelowMinOut(uint256 got, uint256 minOut);

    event Converted(address indexed tokenIn, uint256 amountIn, uint256 amountOut, address indexed recipient);

    struct Hop {
        address tokenOut;
        uint24 fee;
    }

    /// @notice Widest gap between a pool's spot tick and its own time-weighted
    ///         tick that this contract will trade into.
    /// @dev Ticks are 1.0001 apart, so 300 of them is `1.0001^300 = 3.045%` in
    ///      price — a shade OVER three per cent, not under.
    ///
    ///      Round `v1.6.4` G3, and its Claude-family lens, which is the only
    ///      reader of three that saw this one. This said "the same tolerance
    ///      `MAX_SLIPPAGE_BPS` expresses in basis points". It is not the same
    ///      tolerance, and the two do not coincide — they COMPOSE. This is an
    ///      admission test: a hop whose spot sits further than this from its own
    ///      average is refused outright. `MAX_SLIPPAGE_BPS` is a limit on how far
    ///      the swap may then move the price from THAT spot. A hop admitted at
    ///      the edge of this check and walked to its own limit ends about
    ///      `3.045% + 2.98% ≈ 6.1%` from the time-weighted price, and that is the
    ///      figure an integrator should hold `claimAsBnb` to, per hop.
    ///
    ///      The route floor (`MAX_ROUTE_DEVIATION_BPS`, checked once over the
    ///      whole route against the price the hops' own spot checks vouched for)
    ///      was said here to be what bounds the OUTCOME. **It does not bound it
    ///      against a sandwich** (AstraSec M-1, v1.6.24): the price the spot
    ///      checks vouch for is the spot an attacker has parked at the edge of
    ///      each band, so the floor is a fraction of an already-deflated
    ///      expectation and the two COMPOSE — `0.97045^3 x 0.97 = 88.65%` of the
    ///      clean quote over three hops, measured. The outcome is bounded by the
    ///      beneficiary's `minOut`, which `convert` checks last; the floor stays,
    ///      as the protection a caller who passes zero still has.
    ///
    ///      G3 corrected this sentence on `FeastConstants.MAX_SLIPPAGE_BPS` and
    ///      left its sibling here standing — in the pass whose own rule is that a
    ///      shape closed in one contract must be swept across all of them. It is
    ///      recorded that way rather than quietly repaired.
    int24 public constant MAX_TICK_DEVIATION = FeastConstants.MAX_TICK_DEVIATION;

    /// @notice Fewest observations a pool must be able to hold before its
    ///         average is worth reading.
    uint16 public constant MIN_ORACLE_CARDINALITY = 2;

    /// @notice How far below the route's own expected output an execution may
    ///         land before it is refused.
    /// @dev This is the bound the documents always advertised and the code
    ///      never had. Round 2: every check was per-hop and positional — a
    ///      spot-versus-average comparison and a price limit — and none of them
    ///      compared what the route *returned* against what its prices implied
    ///      it should. So an attacker owning both pools of a two-hop route
    ///      could price each hop inside its band and keep the spread, and
    ///      `platformBuyBack`'s caller-chosen route had no answer at all.
    ///
    ///      Checking the outcome rather than the path is also why the route may
    ///      stay untrusted: whoever chose it cannot profit from a bad one.
    ///
    ///      **What it is measured against, stated** (v1.6.24, AstraSec M-1): the
    ///      expectation is built from each pool's spot price as admitted, not
    ///      from its average, so it moves with a spot an attacker has parked
    ///      inside the band. It refuses a route that under-delivers on its own
    ///      prices; it does not defend the price a claimant saw before sending.
    ///      That is `convert`'s `minOut`.
    uint16 public constant MAX_ROUTE_DEVIATION_BPS = 300;

    /// @notice The longest route this will walk.
    /// @dev Round 1: with no bound, a route could alternate through the same
    ///      fee-charging pool fifty-one times and consume forty percent of the
    ///      input in pool fees alone while every per-hop check passed. A route
    ///      that needs more than three hops is not a route, it is a grinder.
    uint256 public constant MAX_HOPS = 3;

    IPancakeV3Factory public immutable v3Factory;
    address public immutable wrappedNative;
    /// @notice The only contract that may spend through this one.
    /// @dev The protocol's money lives in the hook, and the hook's two buttons
    ///      already carry the size ceiling, the interval and the tip. A
    ///      separately permissionless converter would need its own copies of
    ///      all three and would let anyone route anyone else's claim; round 1
    ///      built exactly that attack. So the routing utility is not a button.
    address public immutable hook;

    /// @dev Set for the duration of one hop so the pool's callback can be
    ///      attributed. Transient by intent: written and cleared within a single
    ///      external call, never observable between transactions.
    uint256 internal constant Q96 = 0x1000000000000000000000000;

    address private _activePool;
    /// @dev What the hop in flight may pay, and the only balance its callback may
    ///      reach: this hop's own MEASURED input. Transient in exactly the way
    ///      `_activePool` is — written and cleared inside one external call,
    ///      never observable between transactions.
    uint256 private _activeBrought;

    constructor(address v3Factory_, address wrappedNative_, address hook_) {
        v3Factory = IPancakeV3Factory(v3Factory_);
        wrappedNative = wrappedNative_;
        hook = hook_;
    }

    /// @notice Swap `amountIn` of `tokenIn` along `route`, delivering wrapped
    ///         native to `recipient` — at least `minOut` of it, or nothing.
    /// @dev The caller must have approved this contract for `amountIn`.
    ///
    ///      **`minOut` is the beneficiary's own bound, and it is the last check**
    ///      (v1.6.24, AstraSec M-1). Every other protection here is anchored to
    ///      the pools' own prices as they stand when the route is walked: the
    ///      per-hop admission against each pool's average, and the route floor
    ///      against an expectation built from the very spot prices that
    ///      admission just accepted. A sandwich that parks each spot at the edge
    ///      of its band is therefore inside every one of them — measured at
    ///      `0.97045^3 x 0.97 = 88.65%` of the clean quote over three hops — and
    ///      only a number fixed BEFORE the transaction, by the person whose money
    ///      it is, can refuse it. Zero is "no bound of my own": it leaves exactly
    ///      the protection there was before, because the route floor is kept and
    ///      checked first. The floor still earns its place for every caller — it
    ///      is what refuses a route whose pools are each inside their bands but
    ///      compose badly (round 2) — and `minOut` binds whenever it is tighter.
    ///
    ///      The route is validated in full before a single token moves. This is
    ///      not a safety property — the whole call reverts either way, so a
    ///      transfer would roll back regardless — it is a legibility one: a
    ///      caller on a route that could never have been priced is told the
    ///      pool's oracle is unusable, rather than that their allowance is
    ///      short. The second message sends you looking in the wrong place. It
    ///      also avoids paying for a transfer that is about to be undone. That
    ///      reason is untouched by v1.6.3 moving the route floor's accumulation
    ///      to after the transfer: what moved is an arithmetic expectation, not
    ///      a refusal, and every refusal a caller can trip over still happens
    ///      before their allowance is spent.
    ///
    ///      **Every leg of a conversion is measured** (v1.6.3, and its round 1
    ///      for the legs this first missed): the inbound arrival, each
    ///      intermediate arrival, and each hop's outbound payment. So a stray
    ///      balance is inside the "before" of every one of them and cannot be
    ///      spent (B2).
    ///
    ///      **Admission is a weaker claim, and it has a declared limit.** A
    ///      measurement of what a transfer MOVES cannot cover what that transfer
    ///      requires of either party's standing balance — a token that rebases
    ///      the holder, one that transiently needs the sender to hold more than
    ///      it sends, or one that refuses a transfer which would take the
    ///      recipient over a cap. For those, a donation can decide whether a
    ///      conversion is admitted without ever being spent. `docs/plan.md` §B2
    ///      states the limit and names a witness for each shape; the app's quote
    ///      allowlist is the admission control.
    function convert(address tokenIn, uint256 amountIn, Hop[] calldata route, address recipient, uint256 minOut)
        external
        returns (uint256 amountOut)
    {
        if (msg.sender != hook) revert NotTheHook();
        if (route.length == 0) revert EmptyRoute();
        if (route.length > MAX_HOPS) revert RouteTooLong(route.length, MAX_HOPS);
        // No token may appear twice, so a route cannot cycle through a
        // fee-charging pool to grind the input away.
        for (uint256 i = 0; i < route.length; i++) {
            if (route[i].tokenOut == tokenIn) revert RouteRevisitsAToken(route[i].tokenOut);
            for (uint256 j = 0; j < i; j++) {
                if (route[i].tokenOut == route[j].tokenOut) revert RouteRevisitsAToken(route[i].tokenOut);
            }
        }
        if (route[route.length - 1].tokenOut != wrappedNative) {
            revert RouteMustEndInNative(route[route.length - 1].tokenOut);
        }

        address[] memory pools = new address[](route.length);
        // Each pool's square-root price AS VALIDATED, carried forward rather
        // than re-read below. The route floor is only as good as its anchor: the
        // deviation check above is what ties each hop's spot price to that
        // pool's own time-weighted average, and an expectation built from a
        // price read at some other moment is tied to nothing. Reading it once,
        // here, is also one `slot0()` per hop instead of two.
        uint160[] memory sqrtPrices = new uint160[](route.length);
        {
            address token = tokenIn;
            for (uint256 i = 0; i < route.length; i++) {
                (pools[i], sqrtPrices[i]) = _validateHop(token, route[i].tokenOut, route[i].fee);
                token = route[i].tokenOut;
            }
        }

        // MEASURE THE INBOUND LEG. What the route spends is what ARRIVED, never
        // the nominal `amountIn` (v1.6.3, `CA-58354019a2`). A quote that takes a
        // cut of its sender's transfer — B7's shape, pointed at the hook's
        // outbound leg rather than the vault's — delivered 74.25 of a nominal 75
        // while the first hop tried to spend 75, and the shortfall came silently
        // out of whatever else was sitting here. That made a stray balance
        // spendable and made admission depend on it, which is both halves of B2
        // at once. A prior donation is inside `before`, so it is neither spent
        // nor needed; a taxed input is converted for what arrived, not refused.
        uint256 before = IERC20(tokenIn).balanceOf(address(this));
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        uint256 nowHeld = IERC20(tokenIn).balanceOf(address(this));
        // A NON-POSITIVE arrival is a named refusal, not a panic. A token that
        // SHRINKS this contract's balance while transferring in — a rebase down,
        // a clawback, a burn on the holder — made the bare subtraction
        // `nowHeld - before` revert with an arithmetic panic, and whether it
        // panicked depended on the size of a prior donation: admission deciding
        // on a donation once more (v1.6.3 round 1, r1v). Now the refusal is the
        // same either way.
        if (nowHeld <= before) revert NothingArrived(tokenIn, before, nowHeld);
        uint256 received = nowHeld - before;
        // And never MORE than was sent. A token can credit its recipient above
        // the amount asked for — a reflection or a rebase that fires inside the
        // transfer — and without this the route would spend that surplus, which
        // is balance this contract held rather than balance the hook sent. That
        // is the same defect the other way round, and it would leave B2 true
        // only of tokens that shrink transfers. The surplus stays where every
        // other stray balance stays: unowned, unrecoverable, untouched.
        if (received > amountIn) received = amountIn;

        // The route floor is built from `received` for the same reason, so it
        // must be accumulated here rather than in the loop above. It is also the
        // correct pairing: the hops execute after the transfer, so an
        // expectation read at the same point is an expectation of the same swap.
        uint256 expectedOut = received;
        {
            address token = tokenIn;
            for (uint256 i = 0; i < route.length; i++) {
                expectedOut = _expectedAfterHop(pools[i], token, expectedOut, route[i].fee, sqrtPrices[i]);
                token = route[i].tokenOut;
            }
        }

        address currentToken = tokenIn;
        uint256 currentAmount = received;
        for (uint256 i = 0; i < route.length; i++) {
            currentAmount = _hop(pools[i], currentToken, route[i].tokenOut, currentAmount);
            currentToken = route[i].tokenOut;
        }

        if (currentAmount == 0) revert NothingOut();

        // The route's fill check is the conjunction of the per-hop ones in
        // `_hop`, so there is nothing left to check here. Round 4: this used to
        // be a single outer test comparing `amountIn` against the converter's
        // whole input-token balance, and it was wrong twice over. It read
        // *balances* rather than the venue's own answer, so one unsolicited
        // unit of the input token bricked every conversion of that token
        // forever (r4a H5, r4b H1); and it looked only at the FIRST token, so a
        // middle hop that part-filled stranded the intermediate one (r4a H2,
        // r4b H2). Measuring each hop from the delta the pool returns fixes
        // both at the site where the fact is actually known.

        // The one check about the route as a whole rather than any hop of it.
        // Each hop's spot price was already required to sit within
        // `MAX_TICK_DEVIATION` of that pool's own time-weighted price, so an
        // expectation built from spot prices is anchored to those averages; the
        // pools' own fees are deducted, so what remains is genuine slippage.
        // v1.6.4 G1 sweep: `expectedOut` is built from pool spot prices and a
        // caller-chosen `amountIn`; no creation-time cap bounds it.
        uint256 floor_ =
            Math.mulDiv(expectedOut, FeastConstants.BPS - MAX_ROUTE_DEVIATION_BPS, FeastConstants.BPS);
        if (currentAmount < floor_) revert RouteReturnedTooLittle(currentAmount, expectedOut, floor_);
        // And the beneficiary's bound, after the floor: a caller passing zero
        // gets the floor's refusal exactly as before, and one passing a tighter
        // number gets this one.
        if (currentAmount < minOut) revert BelowMinOut(currentAmount, minOut);

        amountOut = currentAmount;
        IERC20(wrappedNative).safeTransfer(recipient, amountOut);
        // What arrived, not what was asked for: the event is the only place the
        // two can still differ, and an indexer should see the truth rather than
        // the claim. Nothing in `src/` reads this event; the hook's accounting
        // reads the RETURN value, which was already measured per hop from the
        // venue's own signed answer. B7 is untouched and stays declared — the
        // ledger still retires the nominal entitlement on the hook's OUTBOUND
        // leg, which this pass does not touch.
        emit Converted(tokenIn, received, amountOut, recipient);
    }

    /// @notice Whether a hop could be priced right now, without attempting it.
    /// @dev Exposed so an operator can see *why* a route is refused, and so the
    ///      app can pick a path that will not revert.
    function hopIsPriceable(address tokenIn, address tokenOut, uint24 fee)
        external
        view
        returns (bool priceable, address pool, uint16 cardinality, uint32 age)
    {
        pool = v3Factory.getPool(tokenIn, tokenOut, fee);
        if (pool == address(0)) return (false, address(0), 0, 0);
        (, , uint16 index, uint16 card,,,) = IPancakeV3Pool(pool).slot0();
        cardinality = card;
        age = _oldestObservationAge(pool, index, card);
        priceable = card >= MIN_ORACLE_CARDINALITY && age >= FeastConstants.MIN_OBSERVATION_AGE;
    }

    // --- one hop ----------------------------------------------------------

    /// @dev Everything that can refuse a hop, with no side effects — and the
    ///      square-root price the refusals were decided on, returned so the
    ///      route floor can be built from the very price the deviation check
    ///      just bounded.
    function _validateHop(address tokenIn, address tokenOut, uint24 fee)
        internal
        view
        returns (address pool, uint160 sqrtPriceX96)
    {
        pool = v3Factory.getPool(tokenIn, tokenOut, fee);
        if (pool == address(0)) revert NoPoolForHop(tokenIn, tokenOut, fee);

        int24 spotTick;
        uint16 index;
        uint16 cardinality;
        (sqrtPriceX96, spotTick, index, cardinality,,,) = IPancakeV3Pool(pool).slot0();

        // Refuse a pool whose oracle cannot answer over the window. Without
        // this the next check compares the spot tick against an "average" that
        // *is* the spot tick, and passes trivially — which is the state the
        // sample quote token's pool is in on chain today.
        uint32 age = _oldestObservationAge(pool, index, cardinality);
        if (cardinality < MIN_ORACLE_CARDINALITY || age < FeastConstants.MIN_OBSERVATION_AGE) {
            revert OracleUnusable(pool, cardinality, age);
        }

        int24 averageTick = _averageTick(pool, age);
        int24 deviation = spotTick > averageTick ? spotTick - averageTick : averageTick - spotTick;
        if (deviation > MAX_TICK_DEVIATION) revert SpotTooFarFromAverage(pool, spotTick, averageTick);
    }

    /// @dev One hop, with BOTH its ends measured (v1.6.3 round 1). What it hands
    ///      the next hop is what ARRIVED here, not what the pool said it sent: an
    ///      intermediate token that takes a cut of the pool's outbound transfer
    ///      left the next hop spending a number this contract did not hold, made
    ///      up out of a stray balance and refused without one (r1h). And what it
    ///      pays is bounded by what it brought: a token that charges its sender
    ///      on top debited more than the hop brought while the pool still
    ///      reported a full fill (r1v). Between them, every leg of a conversion
    ///      is now measured, which is what B2 needs to be true.
    function _hop(address pool, address tokenIn, address tokenOut, uint256 amountIn) internal returns (uint256) {
        uint160 sqrtPriceX96;
        (sqrtPriceX96,,,,,,) = IPancakeV3Pool(pool).slot0();
        bool zeroForOne = tokenIn == IPancakeV3Pool(pool).token0();

        // v1.6.5 sweep rows 16-17, CLOSED in v1.6.6 (`Q8`) — and the sweep's own
        // row was WRONG before it was recorded (v1.6.5 round 1: all three lenses,
        // independently). The row bounded `amountIn` by the venue's
        // `MAX_SETTLEMENT`, which holds for the FIRST hop only: `convert` feeds
        // each hop's expected output into the next, so hop two's input is hop
        // one's output and carries no such ceiling.
        //
        // Measured counterexample: `amountIn = 2^126` through two forward hops
        // at `sqrtPriceX96 = 2^157`, both inside the venue's range — the first
        // expectation occupies 248 bits, and the second hop's inner quotient
        // needs 309. That used to panic inside `Math.mulDiv`, before any swap
        // executed, so a conversion reverted on the size of an EXPECTATION
        // rather than on anything it was going to move.
        //
        // Now each step is refused by name. Routes are validated per hop against
        // the trusted factory and each pool's own average, and a sane route
        // never reaches these magnitudes, so what this changes is the answer a
        // caller gets at the extreme: `RouteExpectationTooLarge` with the pool
        // and the amount, instead of an arithmetic panic.

        // Both ends, as they stand before the swap. A stray balance of either
        // token is inside these, so neither can be spent and neither can be
        // counted as something this hop produced.
        uint256 heldIn = IERC20(tokenIn).balanceOf(address(this));
        uint256 heldOut = IERC20(tokenOut).balanceOf(address(this));

        // Bound how far this swap may move the price. Multiplying the spot
        // square-root price by a ratio is the same bound the tick check applies,
        // expressed in the units the pool wants, and needs no tick mathematics.
        // Round `v1.6.4` G3, swept here from the hook's button: the same constant
        // was applied to the square-root price in both places, so both permitted
        // twice what `MAX_SLIPPAGE_BPS` documents. One derivation, used by both.
        uint160 limit =
            FeastMath.sqrtPriceLimit(sqrtPriceX96, FeastConstants.MAX_SLIPPAGE_BPS, FeastConstants.BPS, !zeroForOne);

        _activePool = pool;
        _activeBrought = amountIn;
        (int256 amount0, int256 amount1) =
            IPancakeV3Pool(pool).swap(address(this), zeroForOne, int256(amountIn), limit, abi.encode(tokenIn));
        _activePool = address(0);
        _activeBrought = 0;

        // ALL OR NOTHING, measured HERE, from the venue's own signed answer.
        //
        // Rule 8: the remainder predicate failed three audit rounds running —
        // refunds, restored claims, reconciliation — each fix reaching one site
        // and leaving a sibling, so the class was withdrawn rather than handled
        // a fourth time. Round 4 then found the withdrawal itself applied at one
        // site instead of its class. This is that boundary enforced where the
        // fact is known: a hop that cannot take the whole amount offered to it
        // takes none of it, and reverting unwinds every earlier hop with it.
        //
        // `amount0`/`amount1` are signed from the POOL's side, so the input leg
        // is the positive one. It is the venue's authenticated report of what it
        // took — not a balance, which any passer-by can change by sending
        // tokens, and not the request, which is what we hoped rather than what
        // happened.
        int256 takenSigned = zeroForOne ? amount0 : amount1;
        uint256 taken = takenSigned > 0 ? uint256(takenSigned) : 0;
        if (taken != amountIn) revert RouteWouldNotFill(taken, amountIn);

        // WHAT THIS HOP PAID, measured. The callback already refuses to ask for
        // more than the hop brought, but the ask is not the debit: a token that
        // charges its sender on top debits more than it transfers, and the pool
        // is credited in full so the check above passes. Measuring the debit is
        // the only place that fact is known.
        uint256 nowIn = IERC20(tokenIn).balanceOf(address(this));
        uint256 spent = heldIn > nowIn ? heldIn - nowIn : 0;
        if (spent > amountIn) revert AskExceedsHop(tokenIn, spent, amountIn);

        // WHAT THIS HOP BROUGHT, measured — not `-amount0`/`-amount1`, which is
        // what the pool says it sent rather than what got here.
        uint256 nowOut = IERC20(tokenOut).balanceOf(address(this));
        if (nowOut <= heldOut) revert NothingArrived(tokenOut, heldOut, nowOut);
        return nowOut - heldOut;
    }

    /// @dev Average tick over the window, or over the whole history when the
    ///      history is shorter. Never over less than `MIN_OBSERVATION_AGE`,
    ///      because the caller has already refused below it.
    /// @dev What one hop should return at the pool's current price, net of that
    ///      pool's own fee.
    ///
    ///      Prices come from `sqrtPriceX96` rather than from a tick, because
    ///      turning a tick into a ratio needs the venue's GPL-licensed
    ///      mathematics and a square-root price is already a ratio. The 512-bit
    ///      multiply-divide keeps `amount * sqrtP` from overflowing on the way.
    function _expectedAfterHop(address pool, address tokenIn, uint256 amountIn, uint24 fee, uint160 sqrtPriceX96)
        internal
        view
        returns (uint256)
    {
        bool zeroForOne = tokenIn == IPancakeV3Pool(pool).token0();

        // token1 per token0 is (sqrtP / 2^96)^2, applied in two steps — and each
        // step is guarded, because the second one's input is not this route's
        // input (v1.6.6, `Q8`; see the note above).
        uint256 out = zeroForOne
            ? _scaleOrRefuse(pool, _scaleOrRefuse(pool, amountIn, sqrtPriceX96, Q96), sqrtPriceX96, Q96)
            : _scaleOrRefuse(pool, _scaleOrRefuse(pool, amountIn, Q96, sqrtPriceX96), Q96, sqrtPriceX96);

        // The pool keeps its own fee, so an execution is expected to land below
        // the raw price by exactly that much. Deducting it is what lets the
        // deviation bound stay as tight as the documents claim.
        // v1.6.4 G1 sweep: `FEE_DENOMINATOR` is 1e6, so this overflowed above 2**256/1e6.
        // The factor is below one, so the result is below `out` and cannot be
        // the step that leaves a word.
        return Math.mulDiv(out, FeastConstants.FEE_DENOMINATOR - fee, FeastConstants.FEE_DENOMINATOR);
    }

    /// @dev One step of a hop's expectation, refused BY NAME when its result
    ///      needs more than a word rather than panicking inside `Math.mulDiv`.
    ///
    ///      `floor(x * y / d) < 2^256` exactly when `x * y < d * 2^256`, which
    ///      in 512-bit terms is `high < d` — the totality condition itself, not
    ///      an approximation of it. Same shape as `FeastEmissions.settle`'s
    ///      value cap and `FeastPricer.priceQ128`'s composed price: take the
    ///      high word, and decide before forming a quotient that cannot exist.
    function _scaleOrRefuse(address pool, uint256 x, uint256 y, uint256 d) private pure returns (uint256) {
        (uint256 high,) = Math.mul512(x, y);
        if (high >= d) revert RouteExpectationTooLarge(pool, x);
        return Math.mulDiv(x, y, d);
    }

    function _averageTick(address pool, uint32 age) internal view returns (int24) {
        uint32 window = age < FeastConstants.TWAP_WINDOW ? age : FeastConstants.TWAP_WINDOW;
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = window;
        secondsAgos[1] = 0;
        (int56[] memory cumulatives,) = IPancakeV3Pool(pool).observe(secondsAgos);
        return int24((cumulatives[1] - cumulatives[0]) / int56(uint56(window)));
    }

    /// @dev The age of the oldest observation the ring still holds. With a
    ///      cardinality of one this is zero, which is the signal that the pool's
    ///      "average" is really its spot price.
    function _oldestObservationAge(address pool, uint16 index, uint16 cardinality) internal view returns (uint32) {
        if (cardinality == 0) return 0;
        uint256 oldestIndex = (uint256(index) + 1) % cardinality;
        (uint32 ts,,, bool initialized) = IPancakeV3Pool(pool).observations(oldestIndex);
        if (!initialized) {
            (ts,,, initialized) = IPancakeV3Pool(pool).observations(0);
            if (!initialized) return 0;
        }
        // Full-width subtraction, truncated after: right across the 2106
        // rollover, when a stored uint32 timestamp has wrapped and the naive
        // subtraction would underflow (v1.6.1, CA-e2ba62d849).
        return uint32(block.timestamp - uint256(ts));
    }

    // --- the pool pays itself back ----------------------------------------

    function pancakeV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external {
        if (msg.sender != _activePool) revert NotThePool();
        address tokenIn = abi.decode(data, (address));
        uint256 owed = amount0Delta > 0 ? uint256(amount0Delta) : uint256(amount1Delta);
        // Only out of what this hop brought. Before v1.6.3's round 1 this paid
        // whatever the pool asked out of whatever this contract happened to
        // hold, so a stray balance was reachable from the far side of a swap
        // (r1v). The conversion never dips into balance it did not bring.
        if (owed > _activeBrought) revert AskExceedsHop(tokenIn, owed, _activeBrought);
        IERC20(tokenIn).safeTransfer(msg.sender, owed);
    }
}
