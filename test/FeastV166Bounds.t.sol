// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {FeastConstants} from "../src/FeastConstants.sol";
import {FeastConverter} from "../src/FeastConverter.sol";
import {FeastGenesis} from "../src/FeastGenesis.sol";
import {FeastMath} from "../src/FeastMath.sol";
import {FeastPlatformSink} from "../src/FeastPlatformSink.sol";
import {FeastPricer} from "../src/FeastPricer.sol";
import {PoolId} from "../src/venue/PoolId.sol";

import {MockERC20} from "./utils/MockERC20.sol";
import {MockV3Factory} from "./utils/MockV3Pool.sol";
import {MockV3Pool} from "./utils/MockV3Pool.sol";
import {UnitFixture} from "./utils/UnitFixture.sol";

/// The v1.6.6 witnesses: the three arithmetic defects the v1.6.5 sweep measured
/// in sibling contracts, recorded there and left open for a ruling, now closed.
///
/// Each one is the same shape as the HIGH that started the pass — a product
/// whose RESULT may not fit a word, formed before anything asked whether it
/// could — and each is now refused BY NAME instead of panicking. So each witness
/// here is a pair: the last input that still works, and the first that does not,
/// one unit apart wherever a unit can be constructed.

/// Q2 — `FeastPricer` never panics on a square-root price, whatever a pool says.
contract FeastV166PricerBoundsTest is Test {
    MockERC20 internal wbnb;
    MockERC20 internal quoteAbove; // sorts ABOVE wbnb, so the pool prices it as token1
    MockERC20 internal quoteBelow; // sorts BELOW wbnb, so the pool prices it as token0
    MockV3Pool internal poolAbove;
    MockV3Pool internal poolBelow;
    FeastPricer internal pricer;

    function setUp() public {
        vm.warp(1_000_000);
        wbnb = new MockERC20("Wrapped", "W", 18);
        quoteAbove = _tokenOn(address(wbnb), true);
        quoteBelow = _tokenOn(address(wbnb), false);
        poolAbove = new MockV3Pool(address(quoteAbove), address(wbnb));
        poolBelow = new MockV3Pool(address(quoteBelow), address(wbnb));

        FeastPricer.Route[] memory routes = new FeastPricer.Route[](2);
        routes[0].quote = address(quoteAbove);
        routes[0].pools = new address[](1);
        routes[0].pools[0] = address(poolAbove);
        routes[1].quote = address(quoteBelow);
        routes[1].pools = new address[](1);
        routes[1].pools[0] = address(poolBelow);
        // The oracle and the pool manager are only reached by the PLATFORM
        // price; every test here reads a listed quote.
        pricer = new FeastPricer(
            address(wbnb), address(0), address(0), address(0xFEA57), PoolId.wrap(bytes32(0)), routes
        );

        poolAbove.setOldestTimestamp(uint32(block.timestamp - 3_600));
        poolBelow.setOldestTimestamp(uint32(block.timestamp - 3_600));
        poolAbove.setTicks(0, 0);
        poolBelow.setTicks(0, 0);
    }

    /// The reciprocal branch is `2^320 / sqrtP^2`, and it is the one that could
    /// leave a word. The boundary is the venue's own STORED-PRICE floor, which
    /// is INCLUSIVE — `TickMath.getTickAtSqrtRatio` accepts `MIN_SQRT_RATIO`
    /// itself, so a pool can legitimately hold it and this contract must price
    /// it (v1.6.6 round 1, r1v: the first spelling refused it). Straddled by
    /// one: AT the floor a price, ONE BELOW it a refusal.
    ///
    /// Kills: dropping the guard (at `2^32` and below, `Math.mulDiv` panics and
    /// `priceQ128` reverts — which `FeastEmissions.settle`, looping over every
    /// listed quote, would turn into a block on every emission week); and
    /// excluding the floor, which refuses a price the venue calls valid.
    function test_atTheVenuesFloorTheQuoteIsPricedAndOneBelowItIsRefused() public {
        poolAbove.setSqrtPrice(FeastMath.MIN_SQRT_RATIO);
        (FeastPricer.Status atFloor, uint256 price) = pricer.priceQ128(address(quoteAbove));
        assertEq(uint8(atFloor), uint8(FeastPricer.Status.Ok), "at the floor: a real tick's price, so priced");
        assertGt(price, 0, "and the price is a number");

        poolAbove.setSqrtPrice(FeastMath.MIN_SQRT_RATIO - 1);
        (FeastPricer.Status below,) = pricer.priceQ128(address(quoteAbove));
        assertEq(uint8(below), uint8(FeastPricer.Status.Unpriceable), "one below it: no pool holds this");
    }

    /// The square-root price at which the reciprocal branch actually leaves a
    /// word is `2^32` — a measured 161 443 units BELOW the venue's floor, which
    /// is why the guard is the venue's bound and not that number. What matters
    /// is that the pricer ANSWERS here rather than reverting.
    ///
    /// Kills: the guard. Without it this call panics (0x11) at `2^32` and
    /// divides by zero at 0.
    function test_belowTheWordBoundaryThePricerStillAnswers() public {
        assertEq(FeastMath.MIN_SQRT_RATIO - (uint160(1) << 32), 161_443, "the measured gap to the floor");

        poolAbove.setSqrtPrice(uint160(1) << 32);
        (FeastPricer.Status s,) = pricer.priceQ128(address(quoteAbove));
        assertEq(uint8(s), uint8(FeastPricer.Status.Unpriceable), "the first price no word can invert");

        poolAbove.setSqrtPrice(0);
        (FeastPricer.Status zero,) = pricer.priceQ128(address(quoteAbove));
        assertEq(uint8(zero), uint8(FeastPricer.Status.Unpriceable), "and zero, which used to divide by zero");
    }

    /// The other end, and the other branch. `sqrtP^2 / 2^64` fits for every
    /// `uint160` by type — at `type(uint160).max` it is exactly `2^256 - 2^97` —
    /// so the ceiling is the venue's bound rather than an arithmetic one, and it
    /// is straddled by one all the same.
    function test_atTheVenuesCeilingTheQuoteIsUnpriceableAndOneBelowItPrices() public {
        poolBelow.setSqrtPrice(FeastMath.MAX_SQRT_RATIO);
        (FeastPricer.Status atCeiling,) = pricer.priceQ128(address(quoteBelow));
        assertEq(uint8(atCeiling), uint8(FeastPricer.Status.Unpriceable), "at the ceiling: refused");

        poolBelow.setSqrtPrice(FeastMath.MAX_SQRT_RATIO - 1);
        (FeastPricer.Status below, uint256 price) = pricer.priceQ128(address(quoteBelow));
        assertEq(uint8(below), uint8(FeastPricer.Status.Ok), "one below the ceiling: priced");
        assertGt(price, 0, "and the price is a number");
    }

    /// The rising branch's type bound, asserted rather than argued: the widest
    /// `uint160` there is, squared over `2^64`, is `2^256 - 2^97`.
    function test_theRisingBranchFitsAWordAtTheWidestUint160() public pure {
        assertEq(
            Math.mulDiv(type(uint160).max, type(uint160).max, 1 << 64),
            type(uint256).max - (uint256(1) << 97) + 1,
            "2^256 - 2^97, so no uint160 can overflow the rising branch"
        );
    }

    /// The PLATFORM half of the same guard, which had no witness at all before
    /// v1.6.6 — not even for the `sqrtPriceX96 == 0` check that stood here since
    /// v1.6: removing that check broke no test in the suite. It reaches the
    /// identical `_ratioQ128`, so it carries the identical bound, and
    /// `FeastEmissions.settle` reads it on every settlement after launch.
    ///
    /// Kills: dropping the guard from `platformPerNativeQ128` (a price of zero
    /// divides by zero on the reciprocal branch; `2^32` panics on it).
    function test_thePlatformPriceIsUnpriceableOutsideTheVenuesRangeToo() public {
        V166StubManager manager = new V166StubManager();
        V166StubOracle oracle = new V166StubOracle();
        // The platform coin sorts BELOW wrapped native here, so the reader takes
        // the reciprocal branch — the one that can leave a word.
        MockERC20 platformCoin = _tokenOn(address(wbnb), false);
        FeastPricer.Route[] memory none = new FeastPricer.Route[](0);
        FeastPricer p = new FeastPricer(
            address(wbnb), address(oracle), address(manager), address(platformCoin), PoolId.wrap(bytes32(0)), none
        );

        for (uint256 i = 0; i < 3; i++) {
            uint160 outside = [uint160(0), uint160(1) << 32, FeastMath.MIN_SQRT_RATIO - 1][i];
            manager.setSqrtPrice(outside);
            (FeastPricer.Status s,) = p.platformPerNativeQ128();
            assertEq(uint8(s), uint8(FeastPricer.Status.Unpriceable), "outside the venue's range: refused");
        }

        manager.setSqrtPrice(FeastMath.MIN_SQRT_RATIO);
        (FeastPricer.Status ok, uint256 price) = p.platformPerNativeQ128();
        assertEq(uint8(ok), uint8(FeastPricer.Status.Ok), "at the floor, which the venue admits: priced");
        assertGt(price, 0, "and the price is a number");
    }

    function _tokenOn(address pivot, bool above) internal returns (MockERC20 t) {
        for (uint256 i = 0; i < 64; i++) {
            t = new MockERC20("Quote", "Q", 18);
            if ((address(t) > pivot) == above) return t;
        }
        revert("no token on the wanted side of the pivot");
    }
}

/// Answers the one selector `platformPerNativeQ128` reads from the venue.
contract V166StubManager {
    uint160 internal _sqrtPriceX96;

    function setSqrtPrice(uint160 p) external {
        _sqrtPriceX96 = p;
    }

    function getSlot0(PoolId) external view returns (uint160, int24, uint24, uint24) {
        return (_sqrtPriceX96, int24(0), uint24(0), uint24(0));
    }
}

/// Answers the three the oracle is asked for, always with enough history.
contract V166StubOracle {
    function observationCount(PoolId) external pure returns (uint256) {
        return 2;
    }

    function historySeconds(PoolId) external pure returns (uint32) {
        return FeastConstants.MIN_OBSERVATION_AGE * 2;
    }

    function twapTick(PoolId) external pure returns (int24) {
        return 0;
    }
}

/// Q3 — `FeastPlatformSink.take` refuses a cost no word can hold, by name.
contract FeastV166SinkBoundsTest is UnitFixture {
    uint256 internal constant ONE = 1 << 128;
    address internal bidder = address(0x71DDE1);

    /// The whole-supply lot of the v1.6.3 PoC, walked down to a price of
    /// EXACTLY one platform coin per raw unit — sixty-four half-lives, landing
    /// on the boundary rather than near it.
    function _wholeSupplyLotAtPriceOne() internal returns (MockERC20 whole) {
        _launch(10e18);
        whole = new MockERC20("Whole Supply", "WHOLE", 18);
        whole.mint(address(sink), type(uint256).max);
        sink.open(address(whole));
        // 2^192 >> 64 == 2^128, with no linear step inside the half-life.
        _advance(64 * FeastGenesis.SINK_HALF_LIFE);
        assertEq(sink.priceQ128(address(whole)), ONE, "the descent lands exactly on one");
    }

    /// AT the boundary: `amountOut * price` is exactly `2^384 - 2^128`, the
    /// largest product whose ceil-rounded quotient is still a word — the cost is
    /// `type(uint256).max` exactly, and it is COMPUTED. The take then fails
    /// where an unaffordable take should, at the payment, which is the proof
    /// that the arithmetic completed.
    function test_atTheLargestWritableCostTheTakeIsPricedAndThenUnaffordable() public {
        MockERC20 whole = _wholeSupplyLotAtPriceOne();
        vm.prank(bidder);
        IERC20(feast).approve(address(sink), type(uint256).max);

        // ceil((2^256 - 1) * 2^128 / 2^128) = 2^256 - 1, with no remainder — the
        // largest cost this function can name. It is computed, it is not above
        // the limit passed, and the take then fails where an unaffordable take
        // should: at the payment. That is the proof the arithmetic completed.
        vm.prank(bidder);
        vm.expectRevert(
            abi.encodeWithSelector(
                bytes4(keccak256("ERC20InsufficientBalance(address,uint256,uint256)")),
                bidder,
                uint256(0),
                type(uint256).max
            )
        );
        sink.take(address(whole), type(uint256).max, type(uint256).max);
    }

    /// ONE SECOND before the boundary the price is above one, the product passes
    /// `2^384 - 2^128`, and the cost cannot be written down. The refusal is the
    /// one this function always had, saturated — not an arithmetic panic.
    ///
    /// Kills: the guard itself (panic 0x11). NOT the high-word-only spelling —
    /// `amountOut` here is `type(uint256).max`, so the high word alone already
    /// says this one does not fit, and a weaker guard refuses it correctly. The
    /// band below is what kills that one (v1.6.6 round 1, r1v: the first draft
    /// of this line claimed both).
    function test_oneSecondEarlierTheCostCannotBeWrittenDownAndIsRefusedByName() public {
        MockERC20 whole = _wholeSupplyLotAtPriceOne();
        // Back one second: sixty-three halvings plus a linear step, so the price
        // is strictly above one and the same take no longer has a cost.
        vm.warp(block.timestamp - 1);
        assertGt(sink.priceQ128(address(whole)), ONE, "a second earlier the price is above one");

        vm.prank(bidder);
        vm.expectRevert(
            abi.encodeWithSelector(
                FeastPlatformSink.CostAboveLimit.selector, type(uint256).max, type(uint256).max
            )
        );
        sink.take(address(whole), type(uint256).max, type(uint256).max);
    }

    /// The band the guard's SECOND clause exists for, and it is reachable
    /// through the sink's own price ladder rather than only in the abstract.
    ///
    /// One second before the sixty-fourth half-life the price is
    /// `1.000277...  * 2^128`. At the `amountOut` below, the 512-bit product
    /// lands strictly between `2^384 - 2^128` and `2^384`: the high word is
    /// `ONE - 1`, so a guard that only asked `high >= ONE` lets it through; the
    /// FLOOR of the quotient still fits a word; and the CEILING — which is the
    /// rounding this function uses, because a taker must never be undercharged —
    /// needs one more than a word, so OZ's `result += 1` panics in checked
    /// arithmetic.
    ///
    /// That is the one-bit gap between "the intermediate fits" and "the result
    /// fits" the whole v1.6.5 sweep is about, appearing one last time inside the
    /// fix for it.
    ///
    /// Kills: dropping the `low` clause from the guard.
    function test_inTheBandWhereOnlyTheRoundingLeavesTheWordTheRefusalIsStillNamed() public {
        MockERC20 whole = _wholeSupplyLotAtPriceOne();
        vm.warp(block.timestamp - 1);

        uint256 price = sink.priceQ128(address(whole));
        uint256 amountOut =
            115_759_933_700_177_257_296_544_167_184_469_999_519_754_056_250_501_321_787_435_457_133_029_406_189_006;
        (uint256 high,) = Math.mul512(amountOut, price);
        assertEq(high, ONE - 1, "the high word alone says this one fits");
        assertEq(
            Math.mulDiv(amountOut, price, ONE),
            type(uint256).max,
            "the floor is the largest word there is - and the ceiling is one past it"
        );

        vm.prank(bidder);
        vm.expectRevert(
            abi.encodeWithSelector(
                FeastPlatformSink.CostAboveLimit.selector, type(uint256).max, type(uint256).max
            )
        );
        sink.take(address(whole), amountOut, type(uint256).max);
    }

    /// And the sentence the v1.6.3 closure wrote is now true at every size a
    /// taker can pay for: the whole supply of the platform coin buys 54 210 108
    /// raw units at the opening price, and that take goes through.
    function test_theLargestTakeAnybodyCanPayForGoesThrough() public {
        _launch(10e18);
        MockERC20 whole = new MockERC20("Whole Supply", "WHOLE", 18);
        whole.mint(address(sink), type(uint256).max);
        sink.open(address(whole));

        uint256 affordable = FeastGenesis.PLATFORM_SUPPLY * ONE / FeastGenesis.SINK_START_PRICE_Q128;
        assertEq(affordable, 54_210_108, "the entire supply, at the opening price");

        uint256 cost = Math.mulDiv(affordable, FeastGenesis.SINK_START_PRICE_Q128, ONE, Math.Rounding.Ceil);
        deal(feast, bidder, cost);
        vm.startPrank(bidder);
        IERC20(feast).approve(address(sink), type(uint256).max);
        sink.take(address(whole), affordable, cost);
        vm.stopPrank();

        assertEq(whole.balanceOf(bidder), affordable, "the taker receives every unit they paid for");
    }
}

/// Q8 — `FeastConverter` refuses an expectation no word can hold, by name.
contract FeastV166ConverterBoundsTest is Test {
    FeastConverter internal converter;
    MockV3Factory internal factory;
    MockERC20 internal quote;
    MockERC20 internal mid;
    MockERC20 internal wbnb;
    MockV3Pool internal firstPool;
    MockV3Pool internal secondPool;

    function setUp() public {
        vm.warp(1_000_000);
        // Deployed in DESCENDING address order, so `quote < mid < wbnb` and both
        // hops price token0 into token1 — the rising branch, which is the one
        // that compounds upward and the one the counterexample uses.
        wbnb = new MockERC20("Wrapped", "W", 18);
        mid = _tokenBelow(address(wbnb));
        quote = _tokenBelow(address(mid));
        assertTrue(address(quote) < address(mid) && address(mid) < address(wbnb), "ordered chain");

        factory = new MockV3Factory();
        firstPool = new MockV3Pool(address(quote), address(mid));
        secondPool = new MockV3Pool(address(mid), address(wbnb));
        factory.set(address(quote), address(mid), 500, address(firstPool));
        factory.set(address(mid), address(wbnb), 500, address(secondPool));
        converter = new FeastConverter(address(factory), address(wbnb), address(this));

        firstPool.setOldestTimestamp(uint32(block.timestamp - 3_600));
        secondPool.setOldestTimestamp(uint32(block.timestamp - 3_600));
        firstPool.setTicks(0, 0);
        secondPool.setTicks(0, 0);
        mid.mint(address(firstPool), 1_000e18);
        wbnb.mint(address(secondPool), 1_000e18);
        quote.approve(address(converter), type(uint256).max);
    }

    function _twoHops() internal view returns (FeastConverter.Hop[] memory r) {
        r = new FeastConverter.Hop[](2);
        r[0] = FeastConverter.Hop({tokenOut: address(mid), fee: 500});
        r[1] = FeastConverter.Hop({tokenOut: address(wbnb), fee: 500});
    }

    /// The v1.6.5 round-1 counterexample, which all three lenses produced
    /// independently and which the sweep's own row said could not happen:
    /// `2^126` through two forward hops at `sqrtPriceX96 = 2^157`, both inside
    /// the venue's range. The first expectation occupies 248 bits; the second
    /// hop's inner step needs 309, because `convert` feeds each hop's
    /// expectation into the next and only the FIRST is bounded by the venue's
    /// settlement ceiling.
    ///
    /// The refusal names the pool it happened at and the amount that reached it
    /// — and that amount is the first hop's OUTPUT, not this call's input, which
    /// is the whole content of the finding.
    ///
    /// Kills: the guard (panic 0x11, before any swap executes); and bounding the
    /// later hops by the route's input amount, which is the row that was wrong.
    function test_aCompoundedExpectationTooLargeToHoldIsRefusedByName() public {
        uint160 steep = uint160(1) << 157;
        assertLt(steep, FeastMath.MAX_SQRT_RATIO, "a price the venue itself could hold");
        firstPool.setSqrtPrice(steep);
        secondPool.setSqrtPrice(steep);

        uint256 amountIn = uint256(1) << 126;
        quote.mint(address(this), amountIn);

        uint256 reachedTheSecondHop = _firstHopOut(amountIn, steep);
        assertEq(_bits(amountIn), 127, "the route's input is 127 bits");
        assertEq(_bits(reachedTheSecondHop), 248, "what reaches the second hop is 248");

        vm.expectRevert(
            abi.encodeWithSelector(
                FeastConverter.RouteExpectationTooLarge.selector, address(secondPool), reachedTheSecondHop
            )
        );
        converter.convert(address(quote), amountIn, _twoHops(), address(this), 0);
    }

    /// EXACTLY on the guard's boundary, which the compounded counterexample
    /// above does not reach (v1.6.6 round 1, r1v). `high >= d` is the refusal
    /// condition; at `high == d` the quotient is exactly `2^256`, one past a
    /// word, so the guard must refuse there and does. One unit of input less
    /// and the same hop converts.
    ///
    /// `amountIn = 2^196` at `sqrtPriceX96 = 2^156` makes the FIRST step's
    /// product exactly `d * 2^256`, with `d = Q96`. One unit less passes that
    /// step and is refused at the next one — this route is far past the size
    /// anything converts at, and the pair is about WHERE the refusal falls, not
    /// about a conversion succeeding.
    ///
    /// Kills: relaxing `high >= d` to `high > d`, which admits exactly this
    /// input and then panics inside `Math.mulDiv`.
    function test_exactlyAtTheGuardsBoundaryTheHopIsRefusedAndOneUnitLessConverts() public {
        uint160 steep = uint160(1) << 156;
        firstPool.setSqrtPrice(steep);
        secondPool.setSqrtPrice(steep);

        uint256 atBoundary = uint256(1) << 196;
        (uint256 high,) = Math.mul512(atBoundary, uint256(steep));
        assertEq(high, 1 << 96, "the product is exactly d * 2^256");

        quote.mint(address(this), atBoundary);
        vm.expectRevert(
            abi.encodeWithSelector(
                FeastConverter.RouteExpectationTooLarge.selector, address(firstPool), atBoundary
            )
        );
        converter.convert(address(quote), atBoundary, _twoHops(), address(this), 0);

        // One unit below, the first STEP fits — its quotient is `2^256 - 2^60`,
        // the largest this construction can produce inside a word — and the hop
        // gets as far as its own second step, which refuses with that quotient
        // as the amount. Same pool, different number: the proof that the
        // boundary moved by exactly one unit of input.
        (uint256 lower,) = Math.mul512(atBoundary - 1, uint256(steep));
        assertLt(lower, 1 << 96, "one unit less fits the first step");
        uint256 firstStepOut = Math.mulDiv(atBoundary - 1, uint256(steep), 1 << 96);
        vm.expectRevert(
            abi.encodeWithSelector(
                FeastConverter.RouteExpectationTooLarge.selector, address(firstPool), firstStepOut
            )
        );
        converter.convert(address(quote), atBoundary - 1, _twoHops(), address(this), 0);
    }

    /// The RECIPROCAL direction, which sweep row 17 closes and which no witness
    /// here reached before (v1.6.6 round 1, r1v): both routes above run forward,
    /// so removing the guard from the reciprocal arm alone escaped them.
    ///
    /// `mulDiv(amountIn, Q96, sqrtP)` leaves a word when
    /// `high(amountIn * Q96) >= sqrtP`, so a SMALL square-root price is what
    /// makes this branch overflow — the opposite of the forward branch. At the
    /// venue's own floor the smallest refused input is 193 bits; one unit less
    /// passes the INNER step and is then refused by the OUTER one, which is what
    /// this test asserts rather than "converts" (v1.6.6 round 2, r2v).
    function test_theReciprocalDirectionIsGuardedAtItsOwnBoundary() public {
        (MockERC20 high_, MockV3Pool pool) = _reciprocalHop();
        pool.setSqrtPrice(FeastMath.MIN_SQRT_RATIO);

        uint256 smallestRefused =
            6_277_337_684_595_516_376_795_612_980_698_114_630_981_897_757_181_570_187_264;
        (uint256 hi,) = Math.mul512(smallestRefused, uint256(1) << 96);
        assertEq(hi, FeastMath.MIN_SQRT_RATIO, "exactly at the reciprocal branch's boundary");

        FeastConverter.Hop[] memory one = new FeastConverter.Hop[](1);
        one[0] = FeastConverter.Hop({tokenOut: address(wbnb), fee: 500});

        high_.mint(address(this), smallestRefused);
        high_.approve(address(converter), type(uint256).max);
        vm.expectRevert(
            abi.encodeWithSelector(
                FeastConverter.RouteExpectationTooLarge.selector, address(pool), smallestRefused
            )
        );
        converter.convert(address(high_), smallestRefused, one, address(this), 0);

        // One unit less fits the INNER step — and then the OUTER one refuses,
        // by name, with the inner quotient as its amount. Naming that exactly is
        // the point: an earlier draft of this line accepted any revert, which a
        // panic from an unguarded outer step satisfies just as well, so removing
        // the outer guard alone escaped this witness entirely (v1.6.6 round 2,
        // r2v and r2h, independently).
        (uint256 lower,) = Math.mul512(smallestRefused - 1, uint256(1) << 96);
        assertLt(lower, FeastMath.MIN_SQRT_RATIO, "one unit less fits the inner step");
        uint256 innerOut = Math.mulDiv(smallestRefused - 1, uint256(1) << 96, FeastMath.MIN_SQRT_RATIO);
        assertEq(
            innerOut,
            115_792_089_237_316_195_423_570_985_008_687_907_853_269_984_665_640_564_039_439_137_957_205_762_393_872,
            "the inner quotient, which the outer step is handed"
        );
        vm.expectRevert(
            abi.encodeWithSelector(FeastConverter.RouteExpectationTooLarge.selector, address(pool), innerOut)
        );
        converter.convert(address(high_), smallestRefused - 1, one, address(this), 0);
    }

    /// A token sorting ABOVE wrapped native, so its pool prices it as token1 and
    /// the converter takes the reciprocal arm.
    function _reciprocalHop() internal returns (MockERC20 t, MockV3Pool pool) {
        for (uint256 i = 0; i < 64; i++) {
            t = new MockERC20("High", "H", 18);
            if (address(t) > address(wbnb)) break;
        }
        require(address(t) > address(wbnb), "no token above wrapped native");
        pool = new MockV3Pool(address(t), address(wbnb));
        pool.setOldestTimestamp(uint32(block.timestamp - 3_600));
        pool.setTicks(0, 0);
        factory.set(address(t), address(wbnb), 500, address(pool));
        wbnb.mint(address(pool), 1_000e18);
    }

    /// The same route, the same two hops, at a price the compounding survives:
    /// the conversion goes through. So the refusal above is about the SIZE and
    /// not about the shape of a two-hop route.
    function test_theSameTwoHopRouteAtASanePriceConverts() public {
        uint256 amountIn = 10e18;
        quote.mint(address(this), amountIn);
        uint256 out = converter.convert(address(quote), amountIn, _twoHops(), address(this), 0);
        assertGt(out, 0, "two hops at the default price convert");
    }

    /// What the first hop returns, by the contract's own arithmetic: the value
    /// the second hop is handed, and the one the refusal reports.
    function _firstHopOut(uint256 amountIn, uint160 sqrtPriceX96) internal pure returns (uint256) {
        uint256 raw = Math.mulDiv(Math.mulDiv(amountIn, sqrtPriceX96, 1 << 96), sqrtPriceX96, 1 << 96);
        return Math.mulDiv(raw, FeastConstants.FEE_DENOMINATOR - 500, FeastConstants.FEE_DENOMINATOR);
    }

    function _bits(uint256 x) internal pure returns (uint256 n) {
        while (x != 0) {
            n++;
            x >>= 1;
        }
    }

    function _tokenBelow(address pivot) internal returns (MockERC20 t) {
        for (uint256 i = 0; i < 64; i++) {
            t = new MockERC20("Quote", "Q", 18);
            if (address(t) < pivot) return t;
        }
        revert("no token below the pivot");
    }
}
