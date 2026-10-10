// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {TickMath} from "uniswap-v4-core/src/libraries/TickMath.sol";

import {FeastConstants} from "../src/FeastConstants.sol";
import {FeastFactory} from "../src/FeastFactory.sol";
import {FeastGenesis} from "../src/FeastGenesis.sol";
import {FeastHook} from "../src/FeastHook.sol";
import {FeastLaunchWindow} from "../src/FeastLaunchWindow.sol";
import {Currency} from "../src/venue/Currency.sol";
import {IFeastCLPoolManager} from "../src/venue/IFeastCLPoolManager.sol";
import {PoolKey} from "../src/venue/PoolKey.sol";

import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {CLPool} from "infinity-core/src/pool-cl/libraries/CLPool.sol";

import {UnitFixture} from "./utils/UnitFixture.sol";
import {VenueBridge} from "./utils/VenueBridge.sol";

/// The launch window as a **uniform-price auction** (v1.6.11).
///
/// Until v1.6.11 the window bought with the whole pot in one swap up a
/// single-sided curve. Everybody paid the same AVERAGE price, but a swap up a
/// curve ends at the MARGINAL price and that is where it left the pool — about
/// `sqrt(multiple)` above what every committer paid. Buys are capped at 0.5% of
/// supply in the opening blocks and sells are deliberately not, so the first
/// committer to sell took that premium out of the pot and the last one ate it.
///
/// The auction clears a fixed tranche at `p* = net / tranche` and opens the pool
/// at that price with both sides seeded around it. These tests pin the
/// arithmetic, the direction every rounding goes, and the one behaviour the
/// whole change exists for: selling at the open costs the fee and your own
/// impact, and nothing else.
contract FeastWindowAuctionTest is UnitFixture {
    using VenueBridge for PoolKey;

    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);
    address internal carol = address(0xCA201);

    /// @dev Genesis, then commits from whoever is named, then the close. Leaves
    ///      the clock at `endsAt` with the window unsettled.
    function _commit(address who, uint256 amount) internal {
        vm.deal(who, amount);
        vm.prank(who);
        window.commit{value: amount}();
    }

    function _openWithPot(uint256 pot) internal {
        _genesis();
        _warpTo(windowStart + 1);
        _commit(alice, pot);
        _warpTo(window.endsAt());
        window.settle();
    }

    function _slot0Sqrt() internal view returns (uint160 sqrtPriceX96) {
        (sqrtPriceX96,,,) = IFeastCLPoolManager(address(pm)).getSlot0(feastPoolId);
    }

    function _coinIsCurrency0() internal view returns (bool) {
        return Currency.unwrap(feastKey.currency0) == feast;
    }

    /// @dev The pool's opening price in the direction a committer thinks in —
    ///      quote per coin, as a Q96 square root — so it is comparable with
    ///      `clearingPrice()` whichever currency slot the coin sorted into. A
    ///      pool's own price is currency1 per currency0, so when the coin is
    ///      currency1 the pool's number is the reciprocal of this one.
    function _openingQuotePerCoinSqrt() internal view returns (uint160) {
        uint160 s = _slot0Sqrt();
        if (s == 0) return 0;
        return _coinIsCurrency0() ? s : uint160(Math.mulDiv(1 << 96, 1 << 96, s));
    }

    /// @dev `amount` of platform coin valued at the pool's opening spot, in
    ///      wrapped native. Orientation-safe: the pool's own price is currency1
    ///      per currency0, so it is inverted when the coin sorted into slot 1.
    function _valueInQuote(uint256 amount) internal view returns (uint256) {
        uint160 s = _openingQuotePerCoinSqrt();
        return Math.mulDiv(amount, uint256(s) * uint256(s), 1 << 192);
    }

    /// @dev What the window held when it settled: the whole POOL_BPS share.
    function _coinHeld() internal pure returns (uint256) {
        return SUPPLY * FeastGenesis.POOL_BPS / FeastGenesis.BPS;
    }

    // --- the price ---------------------------------------------------------

    /// `p*` is the pot net of the fee over the tranche, exactly — and the
    /// tranche is half of what the window held, as `WINDOW_TRANCHE_BPS` says.
    /// Kills: clearing on the gross pot; clearing on the whole holding.
    function test_theClearingPriceIsThePotOverTheTranche() public {
        uint256 pot = 10e18;
        _openWithPot(pot);

        uint256 held = _coinHeld();
        uint256 sold = Math.mulDiv(held, FeastGenesis.WINDOW_TRANCHE_BPS, FeastGenesis.BPS);
        assertEq(window.tranche(), sold, "the tranche is WINDOW_TRANCHE_BPS of the holding");
        assertEq(sold * 2, held, "and WINDOW_TRANCHE_BPS is half");

        uint256 net = pot - pot / 100;
        uint160 expected = uint160(Math.sqrt(Math.mulDiv(net, 1 << 192, sold, Math.Rounding.Ceil)));
        assertEq(window.clearingPrice(), expected, "p* = sqrt(net / tranche) as a Q96 root");

        // And it is a PRICE, not a root of one: the tranche valued at `p*`
        // recovers the net pot to within the square root's own last unit.
        uint256 priceQ192 = uint256(expected) * uint256(expected);
        assertApproxEqRel(Math.mulDiv(sold, priceQ192, 1 << 192), net, 1e12, "the tranche is worth the net pot");
    }

    /// Every rounding in the settlement goes against the committer and in favour
    /// of the pool. The one that BITES is the tick alignment: the pool opens at
    /// or just below `p*`, never above it, so the first seller is never handed a
    /// premium the auction did not charge for.
    ///
    /// @dev The `Math.Rounding.Ceil` on the radicand inside `settle` is
    ///      defensive rather than operative, and this test does not pretend
    ///      otherwise. The radicand is of order `net · 2^192 / tranche` ≈ 2e50
    ///      for a ten-ether pot; `sqrt(x)` and `sqrt(x+1)` differ only when
    ///      `x+1` is a perfect square, which at that magnitude has probability
    ///      about `1/(2·sqrt(x))` ≈ 3e-26. No reachable pot makes it bite, so
    ///      no test can witness it, and the assertion below is the direction
    ///      that a reader can actually check.
    function test_theClearingPriceRoundsAgainstTheCommitter() public {
        _openWithPot(7_777_777_777_777_777_777);

        uint160 cleared = window.clearingPrice();
        uint160 opened = _openingQuotePerCoinSqrt();
        assertGt(cleared, 0, "the auction cleared");
        assertLe(opened, cleared, "the pool never opens ABOVE what the committers paid");
    }

    /// Opening spot IS the clearing price — **exactly**, from v1.6.12. Kills:
    /// opening at the owner's genesis price; opening at the marginal price of a
    /// swap; and re-introducing the tick alignment.
    ///
    /// @dev Until v1.6.12 this asserted "within one tick spacing, on the cheap
    ///      side", because the auction placed TWO ranges that MET at a tick and
    ///      a meeting point must be a multiple of the spacing. One full-range
    ///      position has no meeting point: only its endpoints must be usable
    ///      ticks, and `minUsableTick`/`maxUsableTick` are. So the price is
    ///      free, and the up-to-2.02% the first seller used to pay for the
    ///      alignment — and the 1.2% of the pot that was left behind when one
    ///      position had to choose between the two sides — are both gone.
    function test_theOpeningSpotEqualsTheClearingPrice() public {
        _openWithPot(10e18);

        uint160 cleared = window.clearingPrice();
        uint160 opened = _openingQuotePerCoinSqrt();

        // Equal to the last unit the reciprocal can move it: the pool stores one
        // number and `clearingPrice()` reports quote-per-coin, so the two agree
        // exactly when the coin is currency0 and to one wei of sqrt price when
        // it is currency1.
        assertApproxEqRel(uint256(opened), uint256(cleared), 1e6, "the pool opens AT the clearing price");

        // And for this pot it is NOT on a spacing boundary — which is the
        // point. A test that demanded one would be pinning the machinery this
        // change removed, and `p*` lands where the arithmetic puts it.
        (, int24 tick,,) = IFeastCLPoolManager(address(pm)).getSlot0(feastPoolId);
        assertTrue(tick % FeastConstants.POOL_TICK_SPACING != 0, "and not forced onto a usable tick");
    }

    // --- the whole point ---------------------------------------------------

    /// **The reason this change exists.** A committer who sells everything they
    /// were allotted, in the first public block, receives less than they
    /// committed — and the shortfall is the 1% fee plus their own impact on the
    /// curve, with no premium handed to whoever sold first.
    ///
    /// Alice is a small part of a large pot, so her own impact is small and the
    /// bound below is tight enough to bite. Under the old settling swap the
    /// pool was left about `sqrt(multiple)` above what everybody paid; with a
    /// pot this size that premium was tens of percent, so this assertion is not
    /// one a passing accident reaches.
    function test_aCommitterWhoSellsAtTheOpenLosesOnlyTheFee() public {
        _genesis();
        _warpTo(windowStart + 1);
        _commit(alice, 1e18);
        _commit(bob, 99e18);
        _warpTo(window.endsAt());
        window.settle();
        _warpTo(window.endsAt() + FeastGenesis.SETTLE_GRACE);

        uint256 got = window.claim(alice);
        assertGt(got, 0, "alice was allotted coin");

        // Read the opening spot BEFORE the sale — her own trade moves it, which
        // is the impact the bounds below are meant to leave room for and not a
        // price anything should be measured against.
        uint256 valueAtOpen = _valueInQuote(got);

        // Sell all of it back into the pool she helped seed.
        vm.prank(alice);
        IERC20(feast).transfer(address(router), got);
        bool zeroForOne = Currency.unwrap(feastKey.currency0) == feast;
        uint256 before = wbnb.balanceOf(address(router));
        vm.prank(alice, alice);
        router.swap(
            feastKey.up(),
            ICLPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(got),
                sqrtPriceLimitX96: zeroForOne ? MIN_SQRT : MAX_SQRT
            }),
            ""
        );
        uint256 back = wbnb.balanceOf(address(router)) - before;

        // Where her 1 BNB went, each part asserted rather than summed into one
        // magic bound:
        //
        //   * the pot paid the 1% like any trade, so her coin cost `net` —
        //   * the pool opened at or below `p*`, by at most one tick spacing
        //     (2.02%), which is the price of the align-DOWN ruling and is paid
        //     by whoever sells first rather than handed to them —
        //   * her sale paid the 1% again —
        //   * and her own impact on the curve.
        uint256 net = 1e18 * 99 / 100;
        assertLe(valueAtOpen, net, "her allotment is never worth MORE at the open than she paid");
        assertGe(valueAtOpen, net * 100 / 102_02 * 100, "and never more than one tick spacing less");

        assertLt(back, valueAtOpen, "selling at the open is not free: the fee is real");
        assertGe(back, valueAtOpen * 98 / 100, "and it costs only the 1% and her own impact");
    }

    // --- what is in the pool ----------------------------------------------

    /// The whole pot, net of the fee, is in the pool as permanently locked bid
    /// liquidity — the site's promise, measured at the vault. Kills: keeping
    /// any of the pot in the window; routing it anywhere but the pool.
    function test_theWholePotIsInThePoolAsBidLiquidity() public {
        uint256 pot = 10e18;
        _openWithPot(pot);

        uint256 net = pot - pot / 100;
        uint256 inPool = wbnb.balanceOf(address(vault));
        assertApproxEqRel(inPool, net, 1e12, "the net pot is in the vault as the bid side");
        assertLe(inPool, net, "and never more than the window held");
        assertEq(wbnb.balanceOf(address(window)), 0, "nothing stays in the window");
        // The floored liquidity leaves at most dust behind with the hook.
        assertLt(wbnb.balanceOf(address(hook)), 1e6, "and the seeding dust is dust");
    }

    /// The other half of the holding is the ask: the supply the auction did not
    /// sell sits above the clearing tick, for the market to buy at a price it
    /// discovers. Kills: seeding the whole holding; seeding the tranche.
    function test_theRemainingSupplyIsTheAskSide() public {
        _openWithPot(10e18);

        uint256 held = _coinHeld();
        uint256 sold = window.tranche();
        uint256 inPool = IERC20(feast).balanceOf(address(vault));
        assertApproxEqRel(inPool, held - sold, 1e12, "the unsold half is the ask side");
        assertLe(inPool, held - sold, "never more than the window held");
        assertEq(IERC20(feast).balanceOf(address(window)), sold, "and the tranche waits for its claimants");
    }

    /// **The pool is ONE full-range position, and that is what half a tranche
    /// buys.** Owner ruling 2026-09-20 12:3x.
    ///
    /// The tranche is half the holding, so the coin left over equals the coin
    /// sold. At the clearing price `p* = net / sold` the two one-sided
    /// liquidities are `L_bid = net/sqrt(p*)` and `L_ask = coinLeft*sqrt(p*)`,
    /// and with `coinLeft == sold` both are `sqrt(sold * net)`. Equal liquidity
    /// on two adjacent ranges is one range spanning both: a plain
    /// constant-product pool with reserves `(coinLeft, net)`.
    ///
    /// Kills: seeding two positions again; a tranche that is not half; taking
    /// the wrong side's liquidity.
    function test_thePlatformPoolIsOneFullRangePosition() public {
        uint256 pot = 10e18;
        _openWithPot(pot);

        uint256 net = pot - pot / 100;
        uint256 sold = window.tranche();
        uint256 coinLeft = _coinHeld() - sold;
        assertEq(coinLeft, sold, "half a tranche: what is left equals what was sold");

        // The position's range is the whole usable domain, and it is RECORDED —
        // the range is the only handle a position has, and `collectLpFees`
        // reverted for ever when it was not.
        FeastHook.Pool memory p = hook.poolInfo(feastPoolId);
        assertEq(p.tickLower, _minUsable(), "the position spans from the far bottom");
        assertEq(p.tickUpper, _maxUsable(), "to the far top");

        // Liquidity is sqrt(sold * net). Each side is floored independently and
        // the smaller is taken, so the bound is one unit of liquidity below the
        // exact root — measured in parts per 1e18 of a number near 1.7e23.
        // `Math.sqrt` floors and so does each side's own formula, but they floor
        // different expressions, so the two agree to a handful of units of
        // liquidity rather than exactly. The bound below is 1e-7% of a number
        // near 1.7e23 — about 1.7e14 units — and the measured gap is under ten.
        uint256 expected = Math.sqrt(sold * net);
        assertApproxEqRel(_positionLiquidity(), expected, 1e9, "L = sqrt(T_rem * pot_net)");
        assertApproxEqAbs(_positionLiquidity(), expected, 16, "to a handful of units of liquidity");

        // And the reserves are the two things that went in, to dust.
        assertApproxEqRel(IERC20(feast).balanceOf(address(vault)), coinLeft, 1e12, "the unsold half is in the pool");
        assertApproxEqRel(wbnb.balanceOf(address(vault)), net, 1e12, "and so is the whole net pot");
        // **Exactly zero, not "dust".** Whatever the position did not take is
        // burned by `FeastFactory._burnUnplaced`, so the hook holds no coin at
        // all — and a bound of "less than 1e6" would let the burn be deleted
        // without anything noticing, which is what the mutation
        // `leave the window's unplaced seed in the hook` demonstrated.
        assertEq(IERC20(feast).balanceOf(address(hook)), 0, "nothing at all is left behind in coin");
        assertLt(wbnb.balanceOf(address(hook)), 1e6, "and only the floor's dust in quote");
    }

    /// The no-commit path is one position too — single-sided, from the opening
    /// tick to the far edge — and it records its range for the same reason.
    /// Kills: leaving the no-commit position unaddressable, which stranded its
    /// LP fees exactly as the auction's did.
    function test_theNoCommitPoolsLpFeesAreCollectableToo() public {
        _genesis();
        _warpTo(window.endsAt());
        window.settle();

        FeastHook.Pool memory p = hook.poolInfo(feastPoolId);
        int24 startTick = factory.platformOpening();
        (int24 lower, int24 upper) =
            _coinIsCurrency0() ? (startTick, _maxUsable()) : (_minUsable(), startTick);
        assertEq(p.tickLower, lower, "the single-sided range's lower bound is recorded");
        assertEq(p.tickUpper, upper, "and its upper bound");

        _warpTo(window.endsAt() + FeastGenesis.SETTLE_GRACE);
        _buy(feastKey, address(wbnb), 1e15, trader, address(0));
        hook.collectLpFees(feastKey);
    }

    function _minUsable() internal pure returns (int24) {
        return (TickMath.MIN_TICK / FeastConstants.POOL_TICK_SPACING) * FeastConstants.POOL_TICK_SPACING;
    }

    function _maxUsable() internal pure returns (int24) {
        return (TickMath.MAX_TICK / FeastConstants.POOL_TICK_SPACING) * FeastConstants.POOL_TICK_SPACING;
    }

    /// @dev What the venue holds for the platform pool's one position.
    function _positionLiquidity() internal view returns (uint256) {
        return uint256(IFeastCLPoolManager(address(pm)).getLiquidity(feastPoolId));
    }

    // --- the failure rules -------------------------------------------------

    /// The one path that keeps the pre-auction shape: nobody committed, so the
    /// whole holding opens single-sided at the tick the genesis key chose, and
    /// the pool opens by time with its supply unsold.
    function test_noCommitsOpensTheWholeSixtyPercentByTime() public {
        _genesis();
        _warpTo(window.endsAt());
        window.settle();

        assertEq(window.tranche(), 0, "nothing was sold");
        assertEq(window.clearingPrice(), 0, "and there is no clearing price to report");
        assertEq(_slot0Sqrt(), SQRT_PRICE_1_1, "the pool opened at the owner's price");
        assertEq(wbnb.balanceOf(address(vault)), 0, "and there is no bid side at all");
        assertEq(IERC20(feast).balanceOf(address(window)), 0, "the window keeps nothing");

        // **v1.6.12: the liquidity is DERIVED from the holding, not signed.**
        // The genesis key used to name it, and the recipe named 999/1000 of the
        // pool amount, so a tenth of a percent — 600,000 FEAST — was unplaced by
        // construction and had to be burned. Nothing is unplaced now: the whole
        // holding goes in, and what the floor leaves behind is dust.
        uint256 held = _coinHeld();
        assertApproxEqRel(IERC20(feast).balanceOf(address(vault)), held, 1e12, "the whole holding is the ask");
        assertLe(IERC20(feast).balanceOf(address(vault)), held, "and never more than it");
        assertEq(IERC20(feast).balanceOf(address(hook)), 0, "nothing strands in the hook");
        assertLt(
            IERC20(feast).balanceOf(FeastConstants.BURN_ADDRESS), 1e6, "and only dust is burned, not a tenth of a percent"
        );
    }

    /// Nobody settles for a week: the auction is abandoned and every commit
    /// comes back in full, and there is no half-built pool to clean up, because
    /// the pool was never initialised. Kills: initialising before the seed.
    ///
    /// v1.6.24 (AstraSec M-2): this used to happen at `openAt`, one hour after
    /// the close, and past it `settle` was refused for ever — the 60% of supply
    /// the window holds with it. Refunds now open at `abandonAt`, and the coin
    /// still reaches the pool afterwards, through the no-participation branch.
    function test_settleNotCalledInTheGraceOpensRefunds() public {
        _genesis();
        _warpTo(windowStart + 1);
        _commit(alice, 4e18);
        _warpTo(window.abandonAt() - 1);
        vm.expectRevert(FeastLaunchWindow.NotRefundable.selector);
        window.refund(alice);
        _warpTo(window.abandonAt());

        wbnb.mint(address(router), 1e18);
        bool zeroForOne = Currency.unwrap(feastKey.currency0) == address(wbnb);
        vm.expectRevert(CLPool.PoolNotInitialized.selector);
        router.swap(
            feastKey.up(),
            ICLPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -1e15,
                sqrtPriceLimitX96: zeroForOne ? MIN_SQRT : MAX_SQRT
            }),
            ""
        );

        window.refund(alice);
        assertEq(wbnb.balanceOf(alice), 4e18, "in full, in wrapped native");

        // And the supply still has a way out: an abandoned auction settles as
        // no participation, single-sided at the genesis opening.
        window.settle();
        assertEq(window.tranche(), 0, "nothing was sold");
        assertEq(IERC20(feast).balanceOf(address(window)), 0, "and none of the 60% is left behind");
        assertGt(_slot0Sqrt(), 0, "the pool opened");
    }

    /// The new failure row: a seed that reverts leaves the window unsettled and
    /// therefore still refundable.
    ///
    /// @dev **This witness does not reach the bound its first draft claimed.**
    ///      It was written to kill "writing `settled` before the seed", and it
    ///      cannot: `seedWindowPool` reverts on failure and the revert rolls
    ///      back the write with it, so the two orderings are indistinguishable
    ///      from outside the transaction. The mutation was removed rather than
    ///      left looking killed. What this test does pin is the OUTCOME — a
    ///      failed settlement is refundable — which is a property of the whole
    ///      path and would break if any part of it started swallowing errors.
    function test_aFailedSeedLeavesTheWindowUnsettledAndRefundable() public {
        _genesis();
        _warpTo(windowStart + 1);
        _commit(alice, 4e18);
        _warpTo(window.endsAt());

        vm.mockCallRevert(
            address(factory), abi.encodeWithSelector(FeastFactory.seedWindowPool.selector), "seed refused"
        );
        vm.expectRevert();
        window.settle();
        vm.clearMockedCalls();

        assertFalse(window.settled(), "a failed seed settles nothing");
        assertEq(window.tranche(), 0, "and sells nothing");

        // v1.6.24: refundable once the auction is abandoned, not at `openAt`.
        _warpTo(window.abandonAt());
        window.refund(alice);
        assertEq(wbnb.balanceOf(alice), 4e18, "so the commit is still refundable, in full");
    }

    // --- the seed's remainder (v1.6.27, `CA-344cf3b11c`) ---------------------

    /// @dev FEAST that reached the hook by a route the settlement did not take.
    ///      Moved out of the team's vesting by a prank so the supply stays the
    ///      real one: the route does not matter, only that it is not the
    ///      window's. `test/audit/poc/SeedRemainderCountsTheHooksBalance.t.sol`
    ///      takes the real one, a release of the team's vesting.
    function _strayOnTheHook(uint256 amount) internal {
        vm.prank(address(teamVesting));
        IERC20(feast).transfer(address(hook), amount);
    }

    /// @dev Settle twice from the same state, once as it is and once with
    ///      `stray` FEAST put on the hook first, and compare. Above 1% of what
    ///      the window delivers, v1.6.26 refused the second with
    ///      `PoolTooShallow` for good.
    function _settleBurnsTheSeedsRemainderAndNothingElse(uint256 stray, uint256 delivered) internal {
        assertGt(stray, delivered / 100, "precondition: the stray is above 1% of what the window delivers");
        uint256 supply = IERC20(feast).totalSupply();
        uint256 snap = vm.snapshotState();
        window.settle();
        uint256 burnedAlone = supply - IERC20(feast).totalSupply();
        assertGt(burnedAlone, 0, "the witness reaches its bound: the seed leaves a remainder to burn");
        assertEq(IERC20(feast).balanceOf(address(hook)), 0, "with nothing on the hook, all of it is burned");

        vm.revertToState(snap);
        _strayOnTheHook(stray);
        window.settle();
        assertTrue(window.settled(), "a stray on the hook does not refuse the settlement");
        assertEq(supply - IERC20(feast).totalSupply(), burnedAlone, "exactly the seed's remainder is burned");
        assertEq(IERC20(feast).balanceOf(address(hook)), stray, "and the stray is neither counted nor burned");
    }

    /// **A clearing settle burns the seed's remainder and nothing else**, with
    /// ten million FEAST already on the hook. The window delivers the half of
    /// its holding it did not sell (`seedWindowPool`).
    function test_feastAlreadyOnTheHookIsNotTheClearingSeedsRemainder() public {
        _genesis();
        _warpTo(windowStart + 1);
        _commit(alice, 10e18);
        _warpTo(window.endsAt());
        _settleBurnsTheSeedsRemainderAndNothingElse(10_000_000e18, _coinHeld() / 2);
        assertGt(window.tranche(), 0, "the pot cleared");
        assertEq(IERC20(feast).balanceOf(address(window)), window.tranche(), "the window keeps exactly the tranche");
    }

    /// **And so does the no-participation opening** (`seedWindowOpening`), late
    /// — the settle v1.6.24 left open for ever — where the window delivers its
    /// whole holding. Near the fixture's 1:1 price one unit of liquidity holds
    /// less than a wei of coin and the single-sided seed places every wei, so
    /// the genesis key prices the coin at a millionth of a quote here, where a
    /// unit holds about a thousand wei and the floored liquidity leaves some.
    function test_feastAlreadyOnTheHookIsNotTheOpeningSeedsRemainder() public {
        if (clock < windowStart - 1 days) _warpTo(windowStart - 1 days);
        if (sink.opensAt() == 0) {
            vm.prank(genesisKey);
            sink.schedule(address(window));
        }
        FeastFactory.GenesisParams memory p = _genesisParams();
        // The pool's price is currency1 per currency0.
        p.sqrtPriceX96 = _coinIsCurrency0() ? SQRT_PRICE_1_1 / 1_000 : SQRT_PRICE_1_1 * 1_000;
        vm.prank(genesisKey);
        factory.genesis(p);
        _warpTo(window.abandonAt() + 30 days);
        _settleBurnsTheSeedsRemainderAndNothingElse(10_000_000e18, _coinHeld());
        assertEq(window.tranche(), 0, "nothing was sold");
        assertEq(IERC20(feast).balanceOf(address(window)), 0, "the window's whole holding reached the pool");
    }

    /// **FEAST sent straight to the window is placed, and never refuses the
    /// settlement.** The window sizes its position from its whole holding, so
    /// the extra reaches the pool; the factory measures the delivery against
    /// the share genesis handed the window and does not count the extra, so
    /// what it burns saturates at zero instead of going negative. The cost,
    /// pinned rather than hidden: the seed's own rounding remainder, which
    /// v1.6.26 burned here, is left on the hook — about two thousand wei.
    function test_feastSentToTheWindowIsPlacedAndNeverRefusesTheSettlement() public {
        _genesis();
        _warpTo(windowStart + 1);
        _commit(alice, 10e18);
        vm.prank(address(teamVesting));
        IERC20(feast).transfer(address(window), 1_000_000e18);
        _warpTo(window.endsAt());
        uint256 supply = IERC20(feast).totalSupply();
        window.settle();
        assertTrue(window.settled(), "settled");
        assertEq(IERC20(feast).balanceOf(address(window)), window.tranche(), "the window keeps exactly the tranche");
        assertGt(window.tranche(), _coinHeld() / 2, "and the extra was auctioned with the rest");
        assertEq(supply, IERC20(feast).totalSupply(), "nothing it cannot attribute to the seed is burned");
        emit log_named_uint("the seed's remainder left on the hook, wei", IERC20(feast).balanceOf(address(hook)));
        assertLt(IERC20(feast).balanceOf(address(hook)), 1e6, "and what it leaves on the hook is dust");
    }

    // --- the quote's rounding dust (v1.6.27, `CA-a364c3530f`, P22) ------------

    /// @dev The wrapped native a clearing settle of `pot` leaves in the hook.
    function _quoteDustOf(uint256 pot) internal returns (uint256 dust) {
        _genesis();
        _warpTo(windowStart + 1);
        _commit(alice, pot);
        _warpTo(window.endsAt());
        uint256 before = wbnb.balanceOf(address(hook));
        window.settle();
        dust = wbnb.balanceOf(address(hook)) - before;
    }

    /// **P22's tolerance, as amended in v1.6.27.** A clearing settle places the
    /// net pot to within rounding dust, which stays in the hook: at most 1e6 wei
    /// for any pot up to 1,000,000 BNB, and never more than a 1e-15 share of the
    /// pot. Measured, it grows as the square root of the pot — 937 wei at 1 BNB,
    /// 29,650 at 1,000 — so the absolute bound needs its range: past about 1.1M
    /// BNB it is exceeded (2,867,244 wei at 10M), and the share is the bound
    /// that holds everywhere. The coin's remainder is burned; this is the quote.
    function testFuzz_aClearingSettleLeavesOnlyDustOfQuote(uint256 pot) public {
        pot = bound(pot, FeastGenesis.MIN_POT, 1_000_000e18);
        uint256 dust = _quoteDustOf(pot);
        assertLe(dust, 1e6, "more than 1e6 wei of quote left in the hook");
        assertLe(dust * 1e15, pot, "more than a 1e-15 share of the pot left in the hook");
    }

    /// And at any size a commit can carry, the share.
    function testFuzz_theQuoteDustIsNeverMoreThanAShareOfThePot(uint96 pot) public {
        uint256 p = bound(uint256(pot), FeastGenesis.MIN_POT, type(uint96).max);
        assertLe(_quoteDustOf(p) * 1e15, p, "more than a 1e-15 share of the pot left in the hook");
    }

    /// The bound is reached, not slack: at 1,000,000 BNB the dust is within a
    /// tenth of 1e6 wei, and at 1 BNB it is the 937 wei the audit measured.
    function test_theQuoteDustReachesItsBoundAtAMillionBnb() public {
        uint256 snap = vm.snapshotState();
        uint256 dust = _quoteDustOf(1_000_000e18);
        emit log_named_uint("quote dust at a 1,000,000 BNB pot, wei", dust);
        assertGt(dust, 900_000, "the witness reaches its bound");
        assertLe(dust, 1e6, "and stays under it");
        vm.revertToState(snap);
        assertEq(_quoteDustOf(1e18), 937, "937 wei at 1 BNB");
    }

    /// The pot pays the 1% like any trade, and it reaches the platform sink
    /// genesis named — as wrapped native, straight from the window, recorded on
    /// no ledger track. Kills: keeping the fee; routing it through the hook.
    function test_thePotPaysTheOnePercentToThePlatformPath() public {
        uint256 pot = 10e18;
        uint256 before = wbnb.balanceOf(address(sink));
        _openWithPot(pot);
        assertEq(wbnb.balanceOf(address(sink)) - before, pot / 100, "one percent, to the sink, as the asset itself");
        assertEq(ledger.totals(ledger.currentWeek(), address(wbnb)).paid, 0, "and on no ledger track");
    }

    /// Every unit of the tranche is claimed: the claimant who completes the
    /// committed weight takes the exact remainder, so nothing strands. The
    /// amounts below do not divide evenly, which is what makes the rule bite.
    function test_everyUnitOfTheTrancheIsClaimed() public {
        _genesis();
        _warpTo(windowStart + 1);
        _commit(alice, 1_000_000_000_000_000_001);
        _commit(bob, 3_333_333_333_333_333_333);
        _commit(carol, 7);
        _warpTo(window.endsAt());
        window.settle();

        uint256 sold = window.tranche();
        uint256 paid = window.claim(alice) + window.claim(bob) + window.claim(carol);
        assertEq(paid, sold, "every unit of the tranche is paid out");
        assertEq(IERC20(feast).balanceOf(address(window)), 0, "and nothing strands in the window");
    }

    /// A pot too small to turn into a square-root price at all — and, since
    /// v1.6.24, far below `MIN_POT` anyway. Until v1.6.24 the coin-as-currency1
    /// ordering refused it by name (`ClearingPriceUnrepresentable`), and since
    /// `settle` then had one hour, that refusal stranded 60% of the supply
    /// (AstraSec M-2); the other ordering sold the tranche for it. In BOTH
    /// orderings it is now no participation: the pool opens single-sided at the
    /// genesis opening, nothing is sold, and the commit comes back in full.
    function test_aPotTooSmallToPriceIsRefusedByName() public {
        _genesis();
        _warpTo(windowStart + 1);
        _commit(alice, 1e6);
        _warpTo(window.endsAt());

        window.settle();
        assertTrue(window.settled(), "settled, in either ordering");
        assertEq(window.tranche(), 0, "with nothing sold");
        assertEq(window.clearingPrice(), 0, "and no clearing price to report");
        assertEq(IERC20(feast).balanceOf(address(window)), 0, "the whole holding went to the pool");
        vm.expectRevert(FeastLaunchWindow.NothingWasSold.selector);
        window.claim(alice);

        window.refund(alice);
        assertEq(wbnb.balanceOf(alice), 1e6, "the commit comes back in full");
    }

    // --- who may initialise ------------------------------------------------

    /// The gate on `beforeInitialize`, in all three directions it has to hold.
    /// v1.6.11 widened it from "the factory" to "the factory or this pool's
    /// registered opener", because the window now initialises the platform pool
    /// at settlement — and a widening is exactly the kind of change that can
    /// let a stranger in by accident.
    function test_nobodyButTheWindowCanInitialiseTheGatedPool() public {
        _genesis();

        // A stranger is refused, even though the pool is registered and waiting.
        vm.prank(address(0xBAD));
        vm.expectRevert();
        pm.initialize(feastKey.up(), SQRT_PRICE_1_1);

        // The registered opener is admitted — and this is how it is admitted in
        // production, through `settle`.
        _warpTo(window.endsAt());
        window.settle();
        assertGt(_slot0Sqrt(), 0, "the window opened the pool it is the opener of");

        // And an ORDINARY pool, which has no opener, is still factory-only: the
        // widening did not reach the pools it was not for.
        (, PoolKey memory k) = _create(address(wbnb), bytes32(uint256(0x9E11)));
        vm.prank(address(0xBAD));
        vm.expectRevert();
        pm.initialize(k.up(), SQRT_PRICE_1_1);
    }

    /// The pool is seeded once and once only. `settle` is already one-shot, but
    /// the hook's `seeded` flag is the thing that makes a SECOND seed impossible
    /// even if a later path reached it — and the factory is the only caller, so
    /// nothing but this flag stands between a re-seed and the pool.
    function test_thePoolCannotBeSeededTwice() public {
        _openWithPot(10e18);

        vm.prank(address(factory));
        vm.expectRevert(FeastHook.AlreadySeeded.selector);
        hook.seedAuctionLiquidity(feastKey, 1);

        // And not through the factory's own door either.
        vm.prank(address(window));
        vm.expectRevert(FeastHook.AlreadySeeded.selector);
        factory.seedWindowPool(1);
    }

    // --- the properties ----------------------------------------------------

    /// The seed must never revert on rounding, at any pot the window can take.
    /// Both liquidity figures are floored, so the pool is never asked for more
    /// than the window holds — the bug an earlier draft shipped, which asked for
    /// 0.2% more coin than existed.
    function testFuzz_thePoolIsAlwaysSeededAndNeverRevertsOnRounding(uint96 pot) public {
        // Every pot that clears: from `MIN_POT` (v1.6.24) up. Below it nothing
        // is sold, which `testFuzz_aPotBelowTheFloorSellsNothing` holds.
        pot = uint96(bound(pot, FeastGenesis.MIN_POT, type(uint96).max));
        _genesis();
        _warpTo(windowStart + 1);
        _commit(alice, pot);
        _warpTo(window.endsAt());
        window.settle();

        assertTrue(window.settled(), "settled");
        assertGt(_slot0Sqrt(), 0, "the pool opened");
        // v1.6.12: the pool opens AT `p*`, not at a tick below it, so this is an
        // equality to the last unit the reciprocal can move rather than a bound.
        // Relative, not absolute: when the coin is currency1 the comparison is
        // through a reciprocal, whose last-unit error scales with the price.
        assertApproxEqRel(
            uint256(_openingQuotePerCoinSqrt()), uint256(window.clearingPrice()), 1e6, "opens at the clearing price"
        );
        assertLe(wbnb.balanceOf(address(vault)), uint256(pot), "never more quote than the pot");
        assertLe(IERC20(feast).balanceOf(address(vault)), _coinHeld(), "never more coin than the holding");

        // One position, the whole range, at `sqrt(T_rem * pot_net)` — at every
        // pot, not only at the one the named test picks.
        FeastHook.Pool memory p = hook.poolInfo(feastPoolId);
        assertEq(p.tickLower, _minUsable(), "one full-range position");
        assertEq(p.tickUpper, _maxUsable(), "one full-range position");
        uint256 net = uint256(pot) - uint256(pot) / 100;
        uint256 expected = Math.sqrt(window.tranche() * net);
        assertApproxEqRel(_positionLiquidity(), expected, 1e9, "L = sqrt(T_rem * pot_net)");
    }

    /// The property itself: whatever two committers put in, they receive the
    /// tranche in the same ratio — one price for everyone, to the last unit the
    /// remainder rule can move.
    function testFuzz_everyCommittersCostIsTheSamePrice(uint96 a, uint96 b) public {
        // Any two commits whose pot clears (v1.6.24: at least `MIN_POT`). Either
        // side may still be small, so the lopsided pairs stay in the domain.
        a = uint96(bound(a, 1e9, type(uint96).max));
        b = uint96(bound(b, a >= FeastGenesis.MIN_POT ? 1e9 : FeastGenesis.MIN_POT - a, type(uint96).max));
        _genesis();
        _warpTo(windowStart + 1);
        _commit(alice, a);
        _commit(bob, b);
        _warpTo(window.endsAt());
        window.settle();

        uint256 ca = window.claim(alice);
        uint256 cb = window.claim(bob);
        assertEq(ca + cb, window.tranche(), "every unit paid");
        // a/b == ca/cb, cross-multiplied so there is no division to round. Each
        // claim is `mulDiv(tranche, weight, total)` or the exact remainder, so
        // each is within one unit of coin of its share; cross-multiplied, that
        // is `a + b` and not a percentage — which matters, because a lopsided
        // pair makes any RELATIVE bound meaningless on the small side.
        assertApproxEqAbs(ca * uint256(b), cb * uint256(a), uint256(a) + uint256(b), "the same price for both");
    }

    /// Below the floor nothing is sold, at any pot, in either ordering (this
    /// suite runs again inverted): the pool opens at the genesis opening with
    /// the whole holding, and every wei committed is refundable. A dust commit
    /// can neither strand the supply nor buy the tranche (AstraSec M-2).
    function testFuzz_aPotBelowTheFloorSellsNothing(uint256 pot) public {
        pot = bound(pot, 1, FeastGenesis.MIN_POT - 1);
        _genesis();
        _warpTo(windowStart + 1);
        _commit(alice, pot);
        _warpTo(window.endsAt());
        window.settle();

        assertEq(window.tranche(), 0, "nothing sold");
        assertEq(IERC20(feast).balanceOf(address(window)), 0, "the whole holding is in the pool");
        assertGt(_slot0Sqrt(), 0, "the pool opened");
        assertEq(window.refund(alice), pot, "and the pot comes back, every wei");
        assertEq(window.total(), 0, "leaving nothing counted");
    }
}

/// **The same auction with the platform coin in the other currency slot.**
///
/// A pool's price is currency1 per currency0, and the platform coin's address is
/// whatever CREATE2 produced — it is as likely to sort ABOVE the wrapped native
/// as below it. The default fixture happens to sort it below, so every test
/// above exercises one orientation only, and the first draft of `settle` was
/// wrong for the other: it computed `sqrt(net/tranche)` unconditionally, which
/// is the RECIPROCAL of the pool's price when the coin is currency1, and aligned
/// the tick in the direction that is cheaper in coin only in that same case.
///
/// This fixture searches for a deployment nonce that flips the sort and then
/// runs the whole suite above against it. It asserts the flip it is named for,
/// so it cannot quietly stop testing what it claims to test.
contract FeastWindowAuctionInvertedTest is FeastWindowAuctionTest {
    function setUp() public override {
        uint64 base = uint64(vm.getNonce(address(this)));
        for (uint64 k = 0; k < 48; k++) {
            uint256 snap = vm.snapshotState();
            vm.setNonce(address(this), base + k);
            super.setUp();
            if (Currency.unwrap(feastKey.currency1) == feast) return;
            vm.revertToState(snap);
        }
        revert("no nonce in range sorts the platform coin into currency1");
    }

    function test_theFixtureReallyIsInverted() public view {
        assertEq(Currency.unwrap(feastKey.currency1), feast, "the coin is currency1 here");
        assertEq(Currency.unwrap(feastKey.currency0), address(wbnb), "and the quote is currency0");
    }
}
