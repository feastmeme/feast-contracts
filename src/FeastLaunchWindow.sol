// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {TickMath} from "uniswap-v4-core/src/libraries/TickMath.sol";

import {FeastConstants} from "./FeastConstants.sol";
import {FeastGenesis} from "./FeastGenesis.sol";
import {FeastHook} from "./FeastHook.sol";
import {IFeastGuardian} from "./IFeastGuardian.sol";
import {Currency} from "./venue/Currency.sol";
import {IFeastCLPoolManager} from "./venue/IFeastCLPoolManager.sol";
import {IFeastVault} from "./venue/IFeastVault.sol";
import {PoolId, PoolIdLibrary} from "./venue/PoolId.sol";
import {PoolKey} from "./venue/PoolKey.sol";

/// @notice What the launch window asks of the factory: the opening the genesis
///         key chose for the no-commit path, the one way into the hook's seed,
///         and where the pot's 1% goes.
interface IFeastWindowFactory {
    function platformOpening() external view returns (int24 startTick);
    function seedWindowPool(uint128 liquidity) external;
    function seedWindowOpening(int24 tickLower, int24 tickUpper, uint128 liquidity) external;
    function platformSink() external view returns (address);
}

/// @dev The chain's wrapped native asset.
interface IWrappedNative {
    function deposit() external payable;
    function withdraw(uint256 amount) external;
}

/// @title The 24-hour uniform-price launch window
/// @notice For 24 hours anyone may commit BNB; for all but the last hour they
///         may take it back. When the window closes the pot buys a FIXED
///         TRANCHE of the platform coin at ONE price — `p* = net / tranche` —
///         and the pool is then opened at that price and seeded on both sides.
///         Every committer pays exactly `p*`, pro rata to what they committed.
///
/// @dev There is no swap. The auction clears arithmetically and the pool is
///      created by this settlement, which is what makes the uniform price real:
///      a swap up a curve ends at the MARGINAL price, so the pool was left above
///      what everybody paid and the first seller took the difference out of the
///      pot. Opening AT the clearing price removes that premium; a committer who
///      sells into the first public block loses the fee and their own impact and
///      nothing else.
///
///      The pool is gated until `openAt`, one hour after the window closes, and
///      this contract is its registered opener. Before `settle` the pool is not
///      merely gated — it does not exist, because the price it must open at is
///      not known until the window closes. Every failure is a written rule, not
///      an operator's decision:
///
///      - **No participation:** nobody committed, or the pot is below
///        `FeastGenesis.MIN_POT`, or it is too small to price at all. `settle`
///        seeds the whole holding single-sided at the opening the genesis key
///        chose and sells nothing, and every commit is refunded in full, in
///        wrapped native. The pool opens with its supply unsold — the one path
///        that keeps the old shape.
///      - **Nobody settles, or the auction's seed cannot be placed:** `settle`
///        has NO deadline (v1.6.24, AstraSec M-2). It may be called from the
///        close until it succeeds, so the coin can always reach the pool. The
///        AUCTION may expire: from `abandonAt()` — `ABANDON_AFTER` after the
///        close plus every second the guardian has held the brake — `settle`
///        takes the no-participation branch whatever the pot, and an unsettled
///        window refunds every commit. A reverted seed leaves the window
///        unsettled, and nothing has to be cleaned up, because an uninitialised
///        pool is not a half-built one.
///      - **A mis-wired genesis** (this contract not the pool's opener) can never
///        settle, and refunds open when the window closes.
///
///      **Until v1.6.24 the coin's only exit had a deadline**: `settle` was
///      callable only in the hour before `openAt`, and anything that kept it
///      from succeeding there — a pot of one wei in the currency ordering that
///      made the clearing price unrepresentable, a freeze, nobody calling it —
///      left 60% of the supply in this contract for ever, with no function
///      anywhere that could move it. In the other ordering the same one wei
///      bought the whole tranche, 30% of the supply. Both are gone: dust is no
///      participation, and the coin has no deadline.
///
///      **The brake holds `settle` and nothing else** (v1.6.24). Settlement is
///      the one irreversible act here — it fixes the price for ever and places
///      a position that can never be removed — so it refuses under an ALL
///      freeze, and since it has no deadline that costs nothing but time;
///      `abandonAt` moves by every frozen second, so the guardian cannot push
///      an auction into abandonment either. `commit`, `withdraw`, `claim` and
///      `refund` stay open: the money they move is the committers' own, and
///      `withdraw` has a deadline a freeze must not eat.
///
///      The pot pays the 1% like any trade. With no swap to take it, `settle`
///      takes it and transfers it to the platform sink genesis named — the same
///      destination `FeastHook.releasePlatformFees` reaches, and the sink prices
///      and sells whatever it holds, so a transfer is all it needs. It is
///      recorded on no ledger track and emits no `Trade`: it is nobody's trade.
///
///      **The auction writes no oracle observation.** Only a swap does, and
///      there is none; `initialize` and `modifyLiquidity` do not. So the
///      platform coin has a price and no HISTORY until somebody trades it, and
///      `FeastPricer` says Unpriceable until then. That is the honest answer —
///      no trade, no price — and `FeastEmissions` settles such a week under the
///      written first-week rule, the token cap alone.
contract FeastLaunchWindow is ReentrancyGuard {
    using PoolIdLibrary for PoolKey;
    using SafeERC20 for IERC20;

    error NotOpenForCommits();
    error NotOpenForWithdrawals();
    error NothingCommitted();
    error CannotSettle();
    error AlreadySettled();
    error NotSettled();
    error AlreadyClaimed(address account);
    error NotRefundable();
    error NotWrappedNative();
    error PaymentFailed();
    error NothingToSell();
    error LiquidityOverflow(uint256 liquidity);
    error Frozen();
    /// @notice The window settled without selling: nothing to claim, and every
    ///         commit is refundable instead.
    error NothingWasSold();

    event Committed(address indexed account, uint256 amount, uint256 total);
    event Withdrawn(address indexed account, uint256 amount, uint256 total);
    /// @param committed the whole pot
    /// @param sold the tranche the auction cleared, which is what the claims pay from
    /// @param clearingSqrtPriceX96 the one price everybody paid, and the price the pool opened at
    event Settled(uint256 committed, uint256 sold, uint160 clearingSqrtPriceX96);
    event Claimed(address indexed account, uint256 amount);
    event Refunded(address indexed account, uint256 amount);

    address public immutable wrappedNative;
    address public immutable platformCoin;
    IFeastVault public immutable vault;
    IFeastCLPoolManager public immutable poolManager;
    FeastHook public immutable hook;
    /// @notice The factory, which owns the one path to the hook's seed.
    IFeastWindowFactory public immutable factory;
    uint64 public immutable startsAt;
    uint64 public immutable endsAt;
    uint64 public immutable lockAt;

    PoolKey internal _key;

    mapping(address => uint256) public committed;
    uint256 public total;
    bool public settled;
    /// @notice The tranche the auction cleared. Claims are pro-rata of THIS —
    ///         a fixed quantity at one price — and not of whatever a swap
    ///         happened to buy. Zero when nothing was sold: nobody committed, the
    ///         pot did not clear, or the auction was abandoned.
    uint256 public tranche;
    uint256 public claimedWeight;
    uint256 public claimedAmount;
    mapping(address => bool) public claimedBy;

    constructor(
        address wrappedNative_,
        address platformCoin_,
        address vault_,
        address poolManager_,
        address hook_,
        address factory_,
        PoolKey memory key_,
        uint64 startsAt_
    ) {
        wrappedNative = wrappedNative_;
        platformCoin = platformCoin_;
        vault = IFeastVault(vault_);
        poolManager = IFeastCLPoolManager(poolManager_);
        hook = FeastHook(hook_);
        factory = IFeastWindowFactory(factory_);
        _key = key_;
        // AstraSec I-9 (v1.6.24): a start already in the past is clamped to the
        // deploying block, and the close and the lock are derived from the
        // clamped start, so the window always runs its whole 24 hours and its
        // last hour. Unclamped, a ceremony that ran late opened a window
        // already part-spent — or, a day late, one already closed. Genesis then
        // reads `endsAt` from here, so the team's vesting start and the sink's
        // opening follow the clamped close with no second number to agree.
        uint64 deployedAt = uint64(block.timestamp);
        uint64 start = startsAt_ < deployedAt ? deployedAt : startsAt_;
        startsAt = start;
        endsAt = start + uint64(FeastGenesis.WINDOW_DURATION);
        lockAt = endsAt - uint64(FeastGenesis.WINDOW_LOCK);
    }

    receive() external payable {
        if (msg.sender != wrappedNative) revert NotWrappedNative();
    }

    function poolKey() external view returns (PoolKey memory) {
        return _key;
    }

    /// @notice What genesis asks every contract it names.
    function genesisRole() external pure returns (bytes32) {
        return FeastGenesis.ROLE_LAUNCH_WINDOW;
    }

    // --- the 24 hours ---------------------------------------------------------

    function commit() external payable nonReentrant {
        if (block.timestamp < startsAt || block.timestamp >= endsAt) revert NotOpenForCommits();
        if (msg.value == 0) revert NothingCommitted();
        IWrappedNative(wrappedNative).deposit{value: msg.value}();
        committed[msg.sender] += msg.value;
        total += msg.value;
        emit Committed(msg.sender, msg.value, total);
    }

    /// @notice Take some or all of your commit back — until the last hour.
    function withdraw(uint256 amount) external nonReentrant {
        if (block.timestamp < startsAt || block.timestamp >= lockAt) revert NotOpenForWithdrawals();
        committed[msg.sender] -= amount;
        total -= amount;
        emit Withdrawn(msg.sender, amount, total);
        IWrappedNative(wrappedNative).withdraw(amount);
        (bool ok,) = msg.sender.call{value: amount}("");
        if (!ok) revert PaymentFailed();
    }

    // --- the auction -------------------------------------------------------

    /// @notice Clear the auction: one price for everyone, then open the pool AT
    ///         that price — or, if the pot does not clear, open it as if nobody
    ///         had committed and make every commit refundable. Permissionless,
    ///         from the close until it succeeds; refused while the system is
    ///         frozen.
    ///
    /// @dev Until v1.6.11 this bought with the whole pot in ONE swap up a
    ///      single-sided curve. Everyone paid the same AVERAGE price, but a swap
    ///      up a curve ends at the MARGINAL price and that is where the pool was
    ///      left — about `sqrt(multiple)` above what every committer paid. Buys
    ///      are capped at 0.5% in the opening blocks and sells are deliberately
    ///      not, so the first committer to sell took that premium out of the pot
    ///      and the last one ate it. It was a uniform AVERAGE price plus a race.
    ///
    ///      Now: a fixed tranche clears at `p* = net / tranche`, the pool is
    ///      initialised at exactly `p*`, and both sides are seeded around it.
    ///      Opening spot IS every committer's cost, so a committer who sells at
    ///      the open loses the fee and their own impact and nothing else.
    ///
    ///      **When the pot clears** (v1.6.24, AstraSec M-2) is decided once, here:
    ///      it is at least `MIN_POT`, its price can be represented in the venue's
    ///      range, and the auction has not been abandoned. Anything else is no
    ///      participation, in either currency ordering — never a revert for an
    ///      arithmetic reason, and never a tranche sold for dust.
    function settle() external nonReentrant {
        _requireUnfrozen();
        if (settled) revert AlreadySettled();
        if (!_canSettle()) revert CannotSettle();

        uint256 coinHeld = IERC20(platformCoin).balanceOf(address(this));
        if (coinHeld == 0) revert NothingToSell();

        bool coinIsCurrency0 = Currency.unwrap(_key.currency0) == platformCoin;

        // The pot pays the 1% like any trade. There is no swap to take it any
        // more, so it is taken here and sent to the sink genesis named — the
        // same destination `FeastHook.releasePlatformFees` reaches, and the sink
        // prices and sells whatever it holds, so a transfer is all it needs.
        uint256 fee = total / 100;
        uint256 net = total - fee;
        uint256 sold = Math.mulDiv(coinHeld, FeastGenesis.WINDOW_TRANCHE_BPS, FeastGenesis.BPS);
        uint256 sqrtP = _clearingSqrtPrice(net, sold, coinIsCurrency0);

        if (total < FeastGenesis.MIN_POT || sqrtP == 0 || block.timestamp >= abandonAt()) {
            // No participation: nobody committed, the pot is dust, its price
            // cannot be represented, or the auction was abandoned. The pool
            // opens with the whole holding single-sided at the opening tick —
            // the one path that keeps the shape this contract had before the
            // auction — the pot stays here, and `refund` returns every commit.
            //
            // **v1.6.12: everything here is derived, nothing is signed.** The
            // genesis key chose a price; the factory floored it to a usable tick
            // and kept only that. The pool opens AT the tick rather than at the
            // raw price, so the coin-only range starts exactly where the price
            // is and cannot straddle it; and the liquidity comes from the coin
            // actually held, by the same closed-form the auction uses. A price
            // that disagreed with a signed tick, or a signed liquidity that
            // asked for more coin than existed, is no longer expressible.
            int24 startTick = factory.platformOpening();
            uint160 sqrtStart = TickMath.getSqrtPriceAtTick(startTick);
            poolManager.initialize(_key, sqrtStart);
            uint128 openingLiquidity = coinIsCurrency0
                ? _amount0Liquidity(coinHeld, sqrtStart)
                : _amount1Liquidity(coinHeld, sqrtStart);
            IERC20(platformCoin).safeTransfer(address(hook), coinHeld);
            (int24 lower, int24 upper) =
                coinIsCurrency0 ? (startTick, _maxUsableTick()) : (_minUsableTick(), startTick);
            factory.seedWindowOpening(lower, upper, openingLiquidity);
            settled = true;
            emit Settled(total, 0, 0);
            return;
        }
        tranche = sold;

        // **The pool opens at `p*` exactly.** Until v1.6.12 it opened at the
        // usable tick below `p*`, and that was forced: two ranges MET at that
        // tick, so the meeting point had to be a position boundary, and a
        // boundary must be a multiple of the tick spacing. With ONE range
        // spanning the whole usable domain there is no meeting point. Only the
        // position's ENDPOINTS must be usable ticks, and `minUsableTick` and
        // `maxUsableTick` are. The price is free.
        //
        // That is not a tidying-up, it is where 1.2% of a ten-ether pot was
        // going. One spacing on this pool is `1.0001^200 - 1` = 2.02%, so an
        // opening price up to 2% under `p*` wants less quote per coin than the
        // window holds: the position took all the coin and left quote behind.
        // Opening at `p*` uses both sides to the last wei, and the first seller
        // no longer pays the alignment either — the opening spot IS the clearing
        // price, exactly, which is what this whole redesign was for.
        poolManager.initialize(_key, uint160(sqrtP));

        uint256 coinLeft = coinHeld - sold;
        uint160 sqrtOpening = uint160(sqrtP);
        uint128 askLiquidity =
            coinIsCurrency0 ? _amount0Liquidity(coinLeft, sqrtOpening) : _amount1Liquidity(coinLeft, sqrtOpening);
        uint128 bidLiquidity =
            coinIsCurrency0 ? _amount1Liquidity(net, sqrtOpening) : _amount0Liquidity(net, sqrtOpening);
        uint128 liquidity = askLiquidity < bidLiquidity ? askLiquidity : bidLiquidity;

        IERC20(platformCoin).safeTransfer(address(hook), coinHeld - sold);
        IERC20(wrappedNative).safeTransfer(address(hook), net);
        factory.seedWindowPool(liquidity);

        if (fee != 0) IERC20(wrappedNative).safeTransfer(factory.platformSink(), fee);

        // Written after both positions are placed. **This ordering is
        // defensive, not load-bearing**, and saying so is more useful than
        // implying otherwise: `seedWindowPool` reverts on any failure and a
        // revert rolls back this write with it, so a failed seed leaves the
        // window unsettled whichever order these two lines are in. The ordering
        // is what stops that from depending on the seed's future shape — a
        // `try`/`catch` there, or a seed that could half-succeed, would make it
        // the only thing keeping the refund route reachable.
        settled = true;
        emit Settled(total, sold, sqrtOpening);
    }

    /// @dev `p* = net / sold` as a Q96 square root in the pool's own direction,
    ///      or ZERO when there is no price to open at: no pot, nothing to sell,
    ///      a ratio whose square root the venue cannot hold.
    ///
    ///      **Which slot the coin sorted into decides everything here.** A
    ///      pool's price is currency1 per currency0, and the platform coin's
    ///      address is not chosen — it is whatever CREATE2 produced — so it is as
    ///      likely to sort ABOVE the wrapped native as below it. When it does, the
    ///      pool's price is COIN PER QUOTE and the square root, and which side
    ///      each liquidity formula applies to, are the other way round.
    ///
    ///      The radicand is rounded UP so the price is never rounded down, which
    ///      would be a cheaper clearing price than the pot actually paid —
    ///      against the pool and in the committer's favour. `Math.sqrt` floors,
    ///      so `Ceil` on the radicand is what carries the direction.
    ///
    ///      `Math.mulDiv` panics on a RESULT that overflows 256 bits, so the
    ///      radicand is shown to fit first: `num · 2^192 / den < 2^256` is
    ///      exactly `num / den < 2^64`. Only the inverted ordering can fail it —
    ///      `tranche / net`, with a tranche of 3e26, fails for every pot up to
    ///      16,427,305 wei. Until v1.6.24 that was a named REVERT, and since
    ///      `settle` could run only in one hour, one wei committed in the
    ///      window's last second stranded 60% of the supply (AstraSec M-2). It is
    ///      "does not clear" now, and so is a square root outside the venue's
    ///      range: both errors are gone. (`MIN_POT` is far above either bound;
    ///      these keep the answer total for any constant someone sets.)
    function _clearingSqrtPrice(uint256 net, uint256 sold, bool coinIsCurrency0) private pure returns (uint256) {
        if (net == 0 || sold == 0) return 0;
        (uint256 num, uint256 den) = coinIsCurrency0 ? (net, sold) : (sold, net);
        if (num / den >= 1 << 64) return 0;
        uint256 sqrtP = Math.sqrt(Math.mulDiv(num, 1 << 192, den, Math.Rounding.Ceil));
        if (sqrtP < TickMath.MIN_SQRT_PRICE || sqrtP >= TickMath.MAX_SQRT_PRICE) return 0;
        return sqrtP;
    }

    /// @dev The single-asset range `[boundary, maxUsable]`, which holds only
    ///      currency0: `amount0 = L · (√b − √a) · 2^96 / (√a · √b)`, so
    ///      `L = amount0 · √a · √b / ((√b − √a) · 2^96)`, floored — the pool is
    ///      never asked for more than the window holds.
    function _amount0Liquidity(uint256 amount0, uint160 sqrtLower) private pure returns (uint128) {
        uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(_maxUsableTick());
        uint256 numerator = Math.mulDiv(uint256(sqrtLower), uint256(sqrtUpper), 1 << 96);
        return _toUint128(Math.mulDiv(amount0, numerator, uint256(sqrtUpper - sqrtLower)));
    }

    /// @dev The single-asset range `[minUsable, boundary]`, which holds only
    ///      currency1: `amount1 = L · (√b − √a) / 2^96`, so
    ///      `L = amount1 · 2^96 / (√b − √a)`, floored for the same reason.
    function _amount1Liquidity(uint256 amount1, uint160 sqrtUpper) private pure returns (uint128) {
        uint160 sqrtLower = TickMath.getSqrtPriceAtTick(_minUsableTick());
        return _toUint128(Math.mulDiv(amount1, 1 << 96, uint256(sqrtUpper - sqrtLower)));
    }

    function _minUsableTick() private pure returns (int24) {
        return (TickMath.MIN_TICK / FeastConstants.POOL_TICK_SPACING) * FeastConstants.POOL_TICK_SPACING;
    }

    function _maxUsableTick() private pure returns (int24) {
        return (TickMath.MAX_TICK / FeastConstants.POOL_TICK_SPACING) * FeastConstants.POOL_TICK_SPACING;
    }

    /// @notice The liquidity the no-commit opening would place for `coinHeld`
    ///         at `startTick`, in this pool's own currency orientation.
    /// @dev Genesis calls this BEFORE it records an opening tick, so a price
    ///      whose position could not be placed is refused in the genesis
    ///      transaction rather than at a settlement that can never be retried.
    ///      It is the same closed form `settle()` uses — the same code, not a
    ///      copy of it — so the two cannot drift apart.
    function openingLiquidityFor(uint256 coinHeld, int24 startTick) external view returns (uint128) {
        uint160 sqrtStart = TickMath.getSqrtPriceAtTick(startTick);
        return Currency.unwrap(_key.currency0) == platformCoin
            ? _amount0Liquidity(coinHeld, sqrtStart)
            : _amount1Liquidity(coinHeld, sqrtStart);
    }

    /// @dev The bound is `int128`, not `uint128`. The venue takes a SIGNED
    ///      `liquidityDelta` and casts it down to `int128`, so anything above
    ///      `type(int128).max` is refused by `SafeCastOverflow()` from inside
    ///      the lock — a venue error, with nothing in it to tell a signer which
    ///      of their numbers was wrong. Refusing it here, by name, is what lets
    ///      `openingLiquidityFor` be an EXACT test at genesis rather than an
    ///      approximate one: found by `testFuzz_everyPriceGenesisAcceptsSettles`
    ///      at an opening tick of 529 800, where the first draft of this bound
    ///      let 1.914e38 through against the venue's own 1.701e38 ceiling.
    function _toUint128(uint256 value) private pure returns (uint128) {
        if (value > _maxLiquidity()) revert LiquidityOverflow(value);
        return uint128(value);
    }

    /// @dev The most liquidity a single position on this pool may carry. TWO
    ///      ceilings, and the tighter one wins:
    ///
    ///        * the venue takes a SIGNED `liquidityDelta` and casts it down to
    ///          `int128`, so `type(int128).max` is one bound;
    ///        * and it caps the GROSS liquidity referencing any one tick at
    ///          `type(uint128).max / numTicks`, which for this pool's spacing of
    ///          200 is about 3.8e34 — far the tighter of the two.
    ///
    ///      Both were found by `testFuzz_everyPriceGenesisAcceptsSettles`, one
    ///      after the other, at opening ticks of 529 800 and 509 800: the venue
    ///      refuses them as `SafeCastOverflow()` and `TickLiquidityOverflow()`
    ///      from inside the lock, with nothing in either to tell a signer which
    ///      of their numbers was wrong. Refusing here, by name, is what lets
    ///      `openingLiquidityFor` be an EXACT test at genesis.
    ///
    ///      The arithmetic is the venue's own, written out rather than imported
    ///      (`src/` is MIT and the venue is GPL-2.0), and
    ///      `test_theWindowsLiquidityCeilingIsTheVenuesOwn` pins that the two
    ///      agree — the same discipline the vendored tick maths is held to.
    function _maxLiquidity() private pure returns (uint256) {
        int24 spacing = FeastConstants.POOL_TICK_SPACING;
        int24 minTick = TickMath.MIN_TICK / spacing;
        if (TickMath.MIN_TICK % spacing != 0) minTick--;
        int24 maxTick = TickMath.MAX_TICK / spacing;
        uint256 numTicks = uint256(uint24(maxTick - minTick)) + 1;
        uint256 perTick = uint256(type(uint128).max) / numTicks;
        uint256 signedMax = uint256(uint128(type(int128).max));
        return perTick < signedMax ? perTick : signedMax;
    }

    // --- after -----------------------------------------------------------------
    /// @notice The one price the auction cleared at, as a Q96 square root of
    ///         wrapped native per platform coin — what every committer paid.
    ///         Zero before settlement and whenever nothing was sold, where there
    ///         is no clearing price to report.
    /// @dev Derived, never stored. `total` and `tranche` are both final once
    ///      the window has settled with a sale — `refund` is closed then, so
    ///      `total` cannot fall — and this repeats the arithmetic `settle` used,
    ///      so there is no second copy of the price to go stale or to disagree.
    ///      It is always quote per coin, whichever currency slot the coin
    ///      sorted into, because that is the direction a committer thinks in.
    ///      The pool opened at exactly this price (since v1.6.12; the note that
    ///      it opened "at or just below" described the aligned opening that
    ///      version removed), and its own sqrt price, in the pool's own
    ///      direction, is carried by `Settled`.
    function clearingPrice() external view returns (uint160 sqrtPriceX96) {
        if (!settled || tranche == 0) return 0;
        uint256 net = total - total / 100;
        return uint160(Math.sqrt(Math.mulDiv(net, 1 << 192, tranche, Math.Rounding.Ceil)));
    }


    /// @notice Pay `account` its pro-rata share of what the pot bought — the same
    ///         average price as everyone. The claimant who completes the
    ///         committed weight receives the exact remainder, so every unit is
    ///         paid. Anyone may call.
    function claim(address account) external nonReentrant returns (uint256 amount) {
        if (!settled) revert NotSettled();
        // v1.6.24: a window that settled without selling pays its committers
        // back through `refund`. Claiming here used to pay zero and mark the
        // account; it is refused by name instead.
        if (tranche == 0) revert NothingWasSold();
        uint256 weight = committed[account];
        if (weight == 0) revert NothingCommitted();
        if (claimedBy[account]) revert AlreadyClaimed(account);
        claimedBy[account] = true;
        claimedWeight += weight;
        // v1.6.4 G1 sweep: `bought * weight` overflowed well inside the reachable
        // range for a large committed weight. `total != 0` because `weight != 0`.
        amount = claimedWeight == total ? tranche - claimedAmount : Math.mulDiv(tranche, weight, total);
        claimedAmount += amount;
        emit Claimed(account, amount);
        if (amount != 0) IERC20(platformCoin).safeTransfer(account, amount);
    }

    /// @notice If the window sold nothing — it settled with no participation,
    ///         or its auction was abandoned, or it can never settle — return
    ///         `account`'s whole commit in wrapped native. Anyone may call.
    /// @dev **`total` falls with every refund** (v1.6.24), exactly as it does
    ///      with every `withdraw`, so it is always the live pot. It used to stay
    ///      where it was, which was sound only because a refunded window was
    ///      never meant to settle — the assumption `RefundedWeightRevival`
    ///      broke at v1.6.19. Nothing now depends on it.
    function refund(address account) external nonReentrant returns (uint256 amount) {
        if (!_refundable()) revert NotRefundable();
        amount = committed[account];
        if (amount == 0) revert NothingCommitted();
        committed[account] = 0;
        total -= amount;
        emit Refunded(account, amount);
        IERC20(wrappedNative).safeTransfer(account, amount);
    }

    // --- the rules --------------------------------------------------------------

    function _gate() internal view returns (FeastHook.Pool memory p) {
        p = hook.poolInfo(_key.toId());
    }

    /// @dev From the close, for as long as it takes (v1.6.24): no upper bound.
    function _canSettle() internal view returns (bool) {
        if (block.timestamp < endsAt) return false;
        return _gate().opener == address(this);
    }

    /// @dev A settled window refunds only if it sold nothing. An unsettled one
    ///      refunds once its auction is abandoned, or from the close if it can
    ///      never settle at all. `settle` and `refund` are no longer exact
    ///      complements: from `abandonAt` both are open, which is safe because
    ///      the settle that follows is the no-participation branch, which reads
    ///      no `total` and sells nothing.
    function _refundable() internal view returns (bool) {
        if (block.timestamp < endsAt) return false;
        if (settled) return tranche == 0;
        return _gate().opener != address(this) || block.timestamp >= abandonAt();
    }

    /// @notice When the auction stops being able to clear: `ABANDON_AFTER`
    ///         after the close, plus every second the guardian has held the
    ///         brake. From then `settle` opens the pool with nothing sold and
    ///         every commit is refundable.
    /// @dev `frozenSeconds()` is the guardian's whole-life total, so a freeze
    ///      before the close extends this too — the safe direction, a longer
    ///      auction. It grows no faster than the clock, so once `abandonAt` is
    ///      reached it stays reached: refunds that have opened cannot close.
    function abandonAt() public view returns (uint256) {
        IFeastGuardian guardian = hook.guardian();
        return uint256(endsAt) + FeastGenesis.ABANDON_AFTER + guardian.frozenSeconds();
    }

    /// @dev The brake, asked the way every guarded contract asks it, so the
    ///      repo's own sweeps (`tools/check-boundaries.py`, `guarded` and
    ///      `guardian-reads`) see this site. The guardian is read through the
    ///      hook rather than stored: genesis already checks this window's hook,
    ///      and the hook's guardian is the system's, so there is no second
    ///      address to wire or to question.
    function _requireUnfrozen() internal view {
        IFeastGuardian guardian = hook.guardian();
        if (guardian.isFrozenAll()) revert Frozen();
    }
}
