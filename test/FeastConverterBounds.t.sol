// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {FeastConstants} from "../src/FeastConstants.sol";
import {FeastConverter} from "../src/FeastConverter.sol";
import {FeastMath} from "../src/FeastMath.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {MockERC20} from "./utils/MockERC20.sol";
import {MockV3Factory, MockV3Pool} from "./utils/MockV3Pool.sol";

/// A quote token whose issuer takes a cut of transfers made BY one named
/// address — here the hook, so the cut lands on the hook -> converter leg. The
/// same shape as B7's `OutboundTaxToken`, pointed at a different sender.
contract InboundTaxToken is MockERC20 {
    address public constant COLLECTOR = address(0xC0111EC7);
    address public taxedFrom;
    uint256 public taxBps;

    constructor() MockERC20("Taxed", "TAX", 18) {}

    function setTax(address from, uint256 bps) external {
        taxedFrom = from;
        taxBps = bps;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (taxBps != 0 && from == taxedFrom && to != COLLECTOR) {
            uint256 tax = value * taxBps / 10_000;
            super._update(from, COLLECTOR, tax);
            super._update(from, to, value - tax);
        } else {
            super._update(from, to, value);
        }
    }
}

/// A quote token that moves its OWN pool's price while it is being transferred
/// in. The measurement for v1.6.3 F4: the route floor's accumulation moved to
/// after the transfer, so the price it is built from must still be the one the
/// deviation check bounded, not whatever the token left behind.
contract PoolMovingToken is MockERC20 {
    MockV3Pool public pool;
    uint160 public moveTo;

    constructor() MockERC20("Mover", "MOV", 18) {}

    function arm(MockV3Pool pool_, uint160 moveTo_) external {
        pool = pool_;
        moveTo = moveTo_;
    }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        if (address(pool) != address(0) && moveTo != 0) {
            uint160 target = moveTo;
            moveTo = 0; // once, on the way in
            pool.setSqrtPrice(target);
        }
    }
}

/// A quote token that credits its recipient MORE than the transfer asked for —
/// a reflection or a rebase firing inside the transfer. The mirror of
/// `InboundTaxToken`, and the other side of what v1.6.3 F4 must not spend.
contract OverDeliveringToken is MockERC20 {
    uint256 public bonusBps;

    constructor() MockERC20("Bonus", "BON", 18) {}

    function setBonus(uint256 bps) external {
        bonusBps = bps;
    }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        if (bonusBps != 0 && from != address(0) && to != address(0)) {
            uint256 bonus = value * bonusBps / 10_000;
            bonusBps = 0; // once, on the way in
            _mint(to, bonus);
        }
    }
}

/// An intermediate token that takes a cut of what its POOL sends out, so the
/// converter receives less than the pool reports sending. `r1h`'s finding: the
/// next hop then spends what the pool REPORTED, and the shortfall comes out of
/// whatever else the converter holds.
contract MidTaxToken is MockERC20 {
    address public constant COLLECTOR = address(0xC0111EC8);
    address public taxedFrom;
    uint256 public taxBps;

    constructor() MockERC20("MidTax", "MTX", 18) {}

    function setTax(address from, uint256 bps) external {
        taxedFrom = from;
        taxBps = bps;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (taxBps != 0 && from == taxedFrom && to != COLLECTOR) {
            uint256 tax = value * taxBps / 10_000;
            super._update(from, COLLECTOR, tax);
            super._update(from, to, value - tax);
        } else {
            super._update(from, to, value);
        }
    }
}

/// A token that charges its SENDER on top of the amount transferred, so paying a
/// pool `owed` debits `owed + surcharge`. `r1v`'s third finding: the pool still
/// reports a full fill, and the surcharge comes out of whatever else is here.
contract SenderSurchargeToken is MockERC20 {
    address public constant COLLECTOR = address(0xC0111EC9);
    address public taxedFrom;
    uint256 public taxBps;

    constructor() MockERC20("Surcharge", "SUR", 18) {}

    function setSurcharge(address from, uint256 bps) external {
        taxedFrom = from;
        taxBps = bps;
    }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        if (taxBps != 0 && from == taxedFrom && to != COLLECTOR) {
            super._update(from, COLLECTOR, value * taxBps / 10_000);
        }
    }
}

/// A token that SHRINKS the converter's balance while transferring in — a
/// rebase down, a clawback, a burn on the holder. `r1v`'s second finding: the
/// inbound measurement is a checked subtraction, so this panics, and whether it
/// panics depends on the size of a prior donation.
contract InboundShrinkToken is MockERC20 {
    bool public armed;

    constructor() MockERC20("Shrink", "SHR", 18) {}

    function arm() external {
        armed = true;
    }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        if (armed && from != address(0) && to != address(0)) {
            armed = false; // once, on the way in
            _burn(to, balanceOf(to) / 2);
        }
    }
}

/// A token whose transfer is exact in NET terms but transiently requires the
/// sender to hold more than it is sending: one unit to a collector, the transfer
/// itself, then the unit back. No rebase, no fee, and every balance conserved
/// once the call returns. Round 3's verifier (`r3v`) found that this is enough
/// to make admission depend on a donation.
contract TransientHoldToken is MockERC20 {
    address public constant COLLECTOR = address(0xC0111ECA);
    address public taxedFrom;

    constructor() MockERC20("Transient", "TRN", 18) {}

    function setTaxedFrom(address from) external {
        taxedFrom = from;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from == taxedFrom && to != COLLECTOR && taxedFrom != address(0)) {
            super._update(from, COLLECTOR, 1);
            super._update(from, to, value);
            super._update(COLLECTOR, from, 1);
        } else {
            super._update(from, to, value);
        }
    }
}

/// A token that refuses a transfer which would take the RECIPIENT's balance
/// above a per-holder cap — a common shape on this chain. Round 3's Claude-family
/// verifier found the third way a donation can decide admission: nothing is
/// spent, nothing is rewritten, nothing is transiently required of the sender,
/// and the identical call is admitted or refused by what somebody else left
/// here.
contract HolderCapToken is MockERC20 {
    uint256 public cap = type(uint256).max;

    constructor() MockERC20("Capped", "CAP", 18) {}

    function setCap(uint256 cap_) external {
        cap = cap_;
    }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        if (to != address(0) && balanceOf(to) > cap) revert("holder cap");
    }
}

/// The refusals, exercised deterministically. Moving a real pool's price far
/// enough to trip the deviation bound means crossing hundreds of initialised
/// ticks — thousands of archive reads — and proves nothing these cannot prove
/// exactly. The real pools are exercised in `FeastConverterForkTest`.
contract FeastConverterBoundsTest is Test {
    FeastConverter internal converter;
    MockV3Factory internal factory;
    MockV3Pool internal pool;
    MockERC20 internal quote;
    MockERC20 internal wbnb;

    function setUp() public {
        vm.warp(1_000_000);
        quote = new MockERC20("Quote", "Q", 18);
        wbnb = new MockERC20("Wrapped", "W", 18);
        factory = new MockV3Factory();
        pool = new MockV3Pool(address(quote), address(wbnb));
        factory.set(address(quote), address(wbnb), 500, address(pool));
        converter = new FeastConverter(address(factory), address(wbnb), address(this));

        pool.setOldestTimestamp(uint32(block.timestamp - 3_600));
        pool.setTicks(0, 0);
        pool.setOutputBps(10_000);
        wbnb.mint(address(pool), 1_000e18);
        quote.mint(address(this), 1_000e18);
        quote.approve(address(converter), type(uint256).max);
    }

    function _route() internal view returns (FeastConverter.Hop[] memory r) {
        r = new FeastConverter.Hop[](1);
        r[0] = FeastConverter.Hop({tokenOut: address(wbnb), fee: 500});
    }

    function test_aPoolInLineWithItsAverageConverts() public {
        uint256 out = converter.convert(address(quote), 10e18, _route(), address(this), 0);
        assertGt(out, 0, "the hop went through");
    }

    /// The manipulation bound. Somebody pushes spot away from the average, and
    /// the converter declines to trade into the price they just made.
    function test_aSpotPriceFarFromTheAverageIsRefused() public {
        int24 far = converter.MAX_TICK_DEVIATION() + 1;
        pool.setTicks(far, 0);
        vm.expectRevert(
            abi.encodeWithSelector(FeastConverter.SpotTooFarFromAverage.selector, address(pool), far, int24(0))
        );
        converter.convert(address(quote), 10e18, _route(), address(this), 0);
    }

    /// Symmetric: a price pushed down is refused just as a price pushed up is.
    function test_theBoundIsSymmetric() public {
        int24 far = -(converter.MAX_TICK_DEVIATION() + 1);
        pool.setTicks(far, 0);
        vm.expectRevert(
            abi.encodeWithSelector(FeastConverter.SpotTooFarFromAverage.selector, address(pool), far, int24(0))
        );
        converter.convert(address(quote), 10e18, _route(), address(this), 0);
    }

    function test_exactlyAtTheBoundIsStillAllowed() public {
        pool.setTicks(converter.MAX_TICK_DEVIATION(), 0);
        converter.convert(address(quote), 10e18, _route(), address(this), 0);
    }

    /// R9 for somebody else's oracle. A pool holding one observation reports its
    /// spot tick as its average, so the deviation check above would pass
    /// trivially — which is why cardinality is checked first.
    function test_aPoolWithOneObservationIsRefused() public {
        pool.setCardinality(1);
        vm.expectRevert(
            abi.encodeWithSelector(FeastConverter.OracleUnusable.selector, address(pool), uint16(1), uint32(3_600))
        );
        converter.convert(address(quote), 10e18, _route(), address(this), 0);
    }

    /// v1.6.1 (CA-e2ba62d849): a v3 pool's observation timestamps are stored
    /// truncated to `uint32`. Past the 2106 rollover the naive subtraction
    /// underflows and every conversion through that pool reverts; the age must
    /// be taken from the full-width clock and truncated after.
    function test_aPoolsHistoryIsStillMeasurableAcrossTheTwentyOneOhSixRollover() public {
        uint256 rollover = uint256(type(uint32).max) + 1;
        pool.setOldestTimestamp(uint32(rollover - 3_600)); // an hour of history, written before it
        vm.warp(rollover + 600); // and now the clock has passed it
        uint256 out = converter.convert(address(quote), 10e18, _route(), address(this), 0);
        assertGt(out, 0, "the conversion still goes through");
    }

    function test_aPoolWithTooLittleHistoryIsRefused() public {
        uint32 tooYoung = FeastConstants.MIN_OBSERVATION_AGE - 1;
        pool.setOldestTimestamp(uint32(block.timestamp) - tooYoung);
        // The mock's own ring, read rather than spelled: its default moved from
        // 100 to `MIN_RING_CARDINALITY` in v1.6.25, and what this refuses is the
        // history, at any ring the converter accepts.
        uint16 ring = pool.observationCardinality();
        vm.expectRevert(
            abi.encodeWithSelector(FeastConverter.OracleUnusable.selector, address(pool), ring, tooYoung)
        );
        converter.convert(address(quote), 10e18, _route(), address(this), 0);
    }

    /// A refused route says why it was refused.
    ///
    /// Validating before pulling funds is not a safety property — the whole call
    /// reverts either way, so the transfer would roll back regardless. What it
    /// buys is a legible failure: a caller who has not approved anything, on a
    /// route that could never have been priced, is told the pool's oracle is
    /// unusable rather than that their allowance is short. Diagnosing the second
    /// message sends you looking in entirely the wrong place.
    function test_aRefusedRouteBlamesTheRouteAndNotTheAllowance() public {
        pool.setCardinality(1);
        // The route is checked before any allowance is, so a caller with no
        // approval at all is still told which pool is unpriceable.
        address broke = address(0xBADBAD);
        quote.approve(address(converter), 0);
        vm.expectRevert(
            abi.encodeWithSelector(FeastConverter.OracleUnusable.selector, address(pool), uint16(1), uint32(3_600))
        );
        converter.convert(address(quote), 10e18, _route(), broke, 0);
    }

    function test_aRefusedRouteStrandsNothingInTheConverter() public {
        pool.setCardinality(1);
        vm.expectRevert();
        converter.convert(address(quote), 10e18, _route(), address(this), 0);
        assertEq(quote.balanceOf(address(converter)), 0, "nothing is stranded in the converter");
    }

    /// The second half of the bound: the swap carries a price limit, so it
    /// cannot itself walk the price to wherever it likes.
    function test_theSwapCarriesAPriceLimit() public {
        converter.convert(address(quote), 10e18, _route(), address(this), 0);
        uint160 limit = pool.lastSwapPriceLimit();
        assertGt(limit, 0, "a limit was set");
        uint160 spot = pool.sqrtPriceX96();
        // Exact in both orderings: a limit in the right direction but the wrong
        // size is still a missing bound.
        bool up = !pool.lastSwapZeroForOne();
        if (!up) {
            assertLt(limit, spot, "selling token0 may only push the price down");
        } else {
            assertGt(limit, spot, "buying token0 may only push the price up");
        }

        // v1.6.4 G3. This used to re-implement the converter's own expression
        // inline — `spot * (10_000 +/- MAX_SLIPPAGE_BPS) / 10_000` — and assert
        // the limit equalled it, under the label "by 3%". That label was wrong:
        // the ratio was applied to a SQUARE-ROOT price, so the bound it actually
        // placed on the price was 1.03^2 = 6.09%. A witness that carries its own
        // copy of the code under test asserts only that the copy still matches.
        //
        // Asserted two ways now: the limit is what the shared derivation gives,
        // and — the property the constant actually claims — squaring it lands
        // inside `MAX_SLIPPAGE_BPS` of the spot price.
        assertEq(
            limit,
            FeastMath.sqrtPriceLimit(spot, FeastConstants.MAX_SLIPPAGE_BPS, FeastConstants.BPS, up),
            "the limit is the shared derivation's"
        );

        uint256 movedBps = Math.mulDiv(uint256(limit) * limit, FeastConstants.BPS, uint256(spot) * spot);
        uint256 moveBps = up ? movedBps - FeastConstants.BPS : FeastConstants.BPS - movedBps;
        assertLe(moveBps, FeastConstants.MAX_SLIPPAGE_BPS, "in PRICE, the limit is within the documented 3%");
    }

    /// Ruling 3. The one check about the route as a whole: what it returned
    /// against what its own prices implied it should. Round 2: every other
    /// check was per-hop and positional, so an attacker owning the pools could
    /// price each hop inside its band and keep the spread.
    function test_aRouteThatReturnsLessThanItsPricesImplyIsRefused() public {
        // Execution 10% below the quoted price — inside no per-hop check's
        // remit, since spot still equals the average and the price limit is
        // never reached.
        pool.setOutputBps(9_000);
        vm.expectRevert();
        converter.convert(address(quote), 10e18, _route(), address(this), 0);
    }

    function test_aRouteWithinTheDeviationBandIsAccepted() public {
        // A shortfall inside the band goes through: the bound is slippage
        // tolerance, not a demand for perfection.
        pool.setOutputBps(10_000 - converter.MAX_ROUTE_DEVIATION_BPS() + 50);
        assertGt(converter.convert(address(quote), 10e18, _route(), address(this), 0), 0, "accepted");
    }

    /// The pool's own fee is deducted from the expectation, which is what lets
    /// the band stay as tight as the documents claim rather than having to
    /// absorb the fees of every hop.
    function test_thePoolsOwnFeeIsNotCountedAsSlippage() public {
        pool.setOutputBps(10_000);
        assertGt(converter.convert(address(quote), 10e18, _route(), address(this), 0), 0, "a clean fill passes");
    }

    /// Only the pool being swapped may call the callback, or anyone could ask
    /// this contract to hand over its balance.
    function test_theSwapCallbackRefusesEveryoneButTheActivePool() public {
        vm.expectRevert(FeastConverter.NotThePool.selector);
        converter.pancakeV3SwapCallback(1e18, 0, abi.encode(address(quote)));
    }

    /// Only the hook may spend through the converter. Round 1: a public
    /// converter let anyone route anyone else's claim, and a route that passed
    /// every per-hop check could still grind forty percent of it away in pool
    /// fees.
    function test_onlyTheHookMaySpendThroughIt() public {
        FeastConverter.Hop[] memory route = _route();
        vm.prank(address(0xBADBAD));
        vm.expectRevert(FeastConverter.NotTheHook.selector);
        converter.convert(address(quote), 10e18, route, address(0xBADBAD), 0);
    }

    /// A route that revisits a token could cycle through a fee-charging pool
    /// as many times as it liked; each hop passed its own checks.
    function test_aRouteThatReturnsToTheInputTokenIsRefused() public {
        FeastConverter.Hop[] memory route = new FeastConverter.Hop[](2);
        route[0] = FeastConverter.Hop({tokenOut: address(quote), fee: 500});
        route[1] = FeastConverter.Hop({tokenOut: address(wbnb), fee: 500});
        vm.expectRevert(abi.encodeWithSelector(FeastConverter.RouteRevisitsAToken.selector, address(quote)));
        converter.convert(address(quote), 10e18, route, address(this), 0);
    }

    /// And a repeat between two hops, which is the shape that actually grinds:
    /// out to a token and back through the same fee-charging pool.
    function test_aRouteThatRevisitsAnIntermediateTokenIsRefused() public {
        MockERC20 mid = new MockERC20("Mid", "MID", 18);
        FeastConverter.Hop[] memory route = new FeastConverter.Hop[](3);
        route[0] = FeastConverter.Hop({tokenOut: address(wbnb), fee: 500});
        route[1] = FeastConverter.Hop({tokenOut: address(mid), fee: 500});
        route[2] = FeastConverter.Hop({tokenOut: address(wbnb), fee: 500});
        vm.expectRevert(abi.encodeWithSelector(FeastConverter.RouteRevisitsAToken.selector, address(wbnb)));
        converter.convert(address(quote), 10e18, route, address(this), 0);
    }

    function test_anOverlongRouteIsRefused() public {
        FeastConverter.Hop[] memory route = new FeastConverter.Hop[](4);
        for (uint256 i = 0; i < 4; i++) {
            route[i] = FeastConverter.Hop({tokenOut: address(wbnb), fee: 500});
        }
        vm.expectRevert(
            abi.encodeWithSelector(FeastConverter.RouteTooLong.selector, uint256(4), converter.MAX_HOPS())
        );
        converter.convert(address(quote), 10e18, route, address(this), 0);
    }

    function test_aRouteWithNoPoolIsRefusedByName() public {
        FeastConverter.Hop[] memory r = new FeastConverter.Hop[](1);
        r[0] = FeastConverter.Hop({tokenOut: address(wbnb), fee: 3_000});
        vm.expectRevert(
            abi.encodeWithSelector(FeastConverter.NoPoolForHop.selector, address(quote), address(wbnb), uint24(3_000))
        );
        converter.convert(address(quote), 10e18, r, address(this), 0);
    }

    // --- round 4: consumption is measured from the venue, not from a balance ---

    /// Round 4 (r4a H5 / r4b H1), and the defect the round-3 withdrawal itself
    /// introduced. The fill check subtracted the converter's ENTIRE input-token
    /// balance from this call's input, so any unsolicited unit sitting in the
    /// contract made a perfectly good conversion look like a part-fill. One wei
    /// bricked every conversion of that token, for every pool sharing it,
    /// forever — and the withdrawal had deleted the sweep that used to clear it.
    function test_aDonatedUnitDoesNotBrickConversion() public {
        quote.mint(address(converter), 1);

        uint256 out = converter.convert(address(quote), 10e18, _route(), address(this), 0);

        assertGt(out, 0, "an honest, fully-filling conversion still goes through");
        assertEq(quote.balanceOf(address(converter)), 1, "the donation is left exactly where it was");
    }

    /// The same defect at the size that reverses the subtraction. A donation
    /// larger than the request underflowed rather than reverting by name.
    function test_aDonationLargerThanTheRequestDoesNotBrickConversionEither() public {
        quote.mint(address(converter), 50e18);

        uint256 out = converter.convert(address(quote), 10e18, _route(), address(this), 0);

        assertGt(out, 0, "still an ordinary conversion");
        assertEq(quote.balanceOf(address(converter)), 50e18, "and still none of ours to touch");
    }

    // --- v1.6.3 F4: what the route spends is what arrived ---------------------

    /// `CA-58354019a2`. A taxed input, with nothing donated to fall back on, is
    /// converted for what ARRIVED rather than refused. Before v1.6.3 `convert`
    /// pulled the nominal amount and then spent the nominal amount, so 74.25 of
    /// a nominal 75 arrived and the first hop tried to spend 75: with a donation
    /// present the difference came silently out of it, and with none the call
    /// reverted on the pool's balance check. Both halves of B2, at once.
    ///
    /// Kills: hopping the nominal amount; building the route floor from it;
    /// emitting it.
    function test_aTaxedInputWithNoDonationConvertsWhatArrived() public {
        InboundTaxToken taxed = new InboundTaxToken();
        MockV3Pool taxedPool = new MockV3Pool(address(taxed), address(wbnb));
        factory.set(address(taxed), address(wbnb), 500, address(taxedPool));
        taxedPool.setOldestTimestamp(uint32(block.timestamp - 3_600));
        taxedPool.setTicks(0, 0);
        taxedPool.setOutputBps(10_000);
        wbnb.mint(address(taxedPool), 1_000e18);
        taxed.mint(address(this), 1_000e18);
        taxed.approve(address(converter), type(uint256).max);
        taxed.setTax(address(this), 100); // a 1% cut of what the hook sends out

        assertEq(taxed.balanceOf(address(converter)), 0, "nothing donated");

        FeastConverter.Hop[] memory route = new FeastConverter.Hop[](1);
        route[0] = FeastConverter.Hop({tokenOut: address(wbnb), fee: 500});

        // The event says what arrived, not what was asked for.
        vm.expectEmit(true, true, false, true, address(converter));
        emit FeastConverter.Converted(address(taxed), 74.25e18, 74.25e18, address(this));
        uint256 out = converter.convert(address(taxed), 75e18, route, address(this), 0);

        assertGt(out, 0, "admitted, with nothing to make up a shortfall from");
        assertEq(taxed.balanceOf(address(converter)), 0, "and the whole of what arrived was spent");
        assertEq(taxed.balanceOf(taxed.COLLECTOR()), 0.75e18, "the issuer took its cut and nobody else paid for it");

        // And a cut wider than the route's own 3% deviation band, which is what
        // separates a floor built from `received` from one built from the
        // nominal: at 5% the nominal floor sits above what can possibly arrive,
        // so a conversion that is perfectly honest about its own size would be
        // refused for a shortfall that is the issuer's and not the venue's.
        taxed.setTax(address(this), 500);
        uint256 bigger = converter.convert(address(taxed), 75e18, route, address(this), 0);
        assertEq(bigger, 71.25e18, "the route floor is built from what arrived, not from what was asked for");
        assertEq(taxed.balanceOf(address(converter)), 0, "still nothing of anyone else's touched");
    }

    /// The other side of v1.6.3 F4, and the exact form of B2's promise. What the
    /// route spends is what arrived — and never MORE than the hook sent. A token
    /// that credits its recipient above the amount asked for would otherwise
    /// have the route spend the surplus, which is balance this contract held
    /// rather than balance the hook sent: a stray balance spent, which is the
    /// half of B2 this pass exists to close.
    ///
    /// Kills: dropping the clamp at `amountIn`.
    function test_aTokenThatDeliversMoreThanAskedDoesNotHaveTheSurplusSpent() public {
        OverDeliveringToken bonus = new OverDeliveringToken();
        MockV3Pool bonusPool = new MockV3Pool(address(bonus), address(wbnb));
        factory.set(address(bonus), address(wbnb), 500, address(bonusPool));
        bonusPool.setOldestTimestamp(uint32(block.timestamp - 3_600));
        bonusPool.setTicks(0, 0);
        bonusPool.setOutputBps(10_000);
        wbnb.mint(address(bonusPool), 1_000e18);
        bonus.mint(address(this), 1_000e18);
        bonus.approve(address(converter), type(uint256).max);

        // Somebody has donated, and the token will credit 10% on top of the
        // transfer that is about to happen.
        bonus.mint(address(converter), 5e18);
        bonus.setBonus(1_000);

        FeastConverter.Hop[] memory route = new FeastConverter.Hop[](1);
        route[0] = FeastConverter.Hop({tokenOut: address(wbnb), fee: 500});

        uint256 out = converter.convert(address(bonus), 10e18, route, address(this), 0);

        assertEq(out, 10e18, "the route spent exactly what the hook sent, and no more");
        assertEq(
            bonus.balanceOf(address(converter)),
            6e18,
            "the donation and the surplus both stay: unowned, unrecoverable, untouched"
        );
    }

    /// The measurement v1.6.3 F4 owes, rather than an argument. Moving the route
    /// floor's accumulation to after the transfer puts it downstream of anything
    /// a hostile `tokenIn` does inside its own `transferFrom` — including moving
    /// the very pool the floor is computed from. So the price the floor is built
    /// from is the one `_validateHop` bounded against the pool's time-weighted
    /// average, carried forward, and NOT re-read afterwards.
    ///
    /// Without that, this conversion is admitted at a quarter of the value the
    /// deviation check vouched for, because the expectation moves with the pool
    /// and the shortfall it exists to catch cancels out exactly.
    ///
    /// Kills: re-reading `slot0()` in `_expectedAfterHop`.
    function test_aTokenThatMovesItsPoolDuringTransferCannotWidenTheRouteFloor() public {
        PoolMovingToken mover = new PoolMovingToken();
        MockV3Pool moverPool = new MockV3Pool(address(mover), address(wbnb));
        factory.set(address(mover), address(wbnb), 500, address(moverPool));
        moverPool.setOldestTimestamp(uint32(block.timestamp - 3_600));
        moverPool.setTicks(0, 0);
        moverPool.setOutputBps(10_000);
        wbnb.mint(address(moverPool), 1_000e18);
        mover.mint(address(this), 1_000e18);
        mover.approve(address(converter), type(uint256).max);

        FeastConverter.Hop[] memory route = new FeastConverter.Hop[](1);
        route[0] = FeastConverter.Hop({tokenOut: address(wbnb), fee: 500});

        // Unarmed, this is an ordinary conversion at the validated price.
        uint256 honest = converter.convert(address(mover), 10e18, route, address(this), 0);
        assertGt(honest, 0, "the honest conversion goes through");

        // Armed: the token halves its pool's square-root price — a quarter of
        // the value — on the way into the converter, after the deviation check
        // has passed and before the hop executes.
        mover.arm(moverPool, uint160(moverPool.sqrtPriceX96() / 2));
        vm.expectRevert();
        converter.convert(address(mover), 10e18, route, address(this), 0);

        assertEq(mover.balanceOf(address(converter)), 0, "and nothing of the input is left behind");
    }

    /// Round 4 (r4a H2 / r4b H2). The withdrawal reached ONE site: the outer
    /// check looked only at the FIRST token. A middle hop that part-filled left
    /// the intermediate token in the converter, bought and paid for by a bucket
    /// that had already been debited in full — the very remainder the
    /// withdrawal exists to abolish. Consumption must be enforced at each hop.
    function test_aMiddleHopThatPartFillsRefusesTheWholeRoute() public {
        (MockERC20 mid, MockV3Pool second) = _twoHopRoute();
        // The second hop takes 98% and returns a fair price for it, so the
        // route's value bound is satisfied and only per-hop consumption
        // separates this from an honest fill.
        second.setInputBps(9_800);

        FeastConverter.Hop[] memory route = new FeastConverter.Hop[](2);
        route[0] = FeastConverter.Hop({tokenOut: address(mid), fee: 500});
        route[1] = FeastConverter.Hop({tokenOut: address(wbnb), fee: 500});

        vm.expectRevert();
        converter.convert(address(quote), 10e18, route, address(this), 0);

        assertEq(mid.balanceOf(address(converter)), 0, "no intermediate token is stranded");
        assertEq(quote.balanceOf(address(converter)), 0, "and nothing of the input either");
    }

    /// The same route, filling completely, must still be accepted — a refusal
    /// that stops honest use is as much a defect as a missing one.
    function test_aTwoHopRouteThatFillsCompletelyIsStillAccepted() public {
        (MockERC20 mid, MockV3Pool second) = _twoHopRoute();
        second.setInputBps(10_000);

        FeastConverter.Hop[] memory route = new FeastConverter.Hop[](2);
        route[0] = FeastConverter.Hop({tokenOut: address(mid), fee: 500});
        route[1] = FeastConverter.Hop({tokenOut: address(wbnb), fee: 500});

        assertGt(converter.convert(address(quote), 10e18, route, address(this), 0), 0, "an honest two-hop route passes");
    }

    /// A first hop that part-fills is refused at that hop, not merely noticed
    /// afterwards by the balance it happened to leave.
    function test_aFirstHopThatPartFillsRefusesTheWholeRoute() public {
        pool.setInputBps(9_800);
        vm.expectRevert();
        converter.convert(address(quote), 10e18, _route(), address(this), 0);
        assertEq(quote.balanceOf(address(converter)), 0, "nothing stranded");
    }

    // --- round 1 of the v1.6.3 lens: the legs F4 did not measure -------------

    /// `r1h`'s MEDIUM. F4 measured the INBOUND leg only. `_hop` handed the next
    /// hop what the POOL REPORTED sending, so an intermediate token that takes a
    /// cut of the pool's outbound transfer left the converter holding less than
    /// the next hop was about to spend — made up out of a donation, and refused
    /// without one. Both halves of B2, one leg further along.
    ///
    /// Kills: handing the next hop the pool's reported output instead of the
    /// measured arrival.
    function test_aTaxedIntermediateNeitherSpendsADonationNorNeedsOne() public {
        (MidTaxToken mid, FeastConverter.Hop[] memory route) = _taxedMidRoute();

        // With a donation sitting in the converter.
        mid.mint(address(converter), 0.5e18);
        uint256 donation = mid.balanceOf(address(converter));
        uint256 withDonation = converter.convert(address(quote), 10e18, route, address(this), 0);
        assertGt(withDonation, 0, "the conversion went through");
        assertEq(mid.balanceOf(address(converter)), donation, "and the donation is exactly where it was");

        // And without one: the identical call, admitted, for what arrived.
        (MidTaxToken mid2, FeastConverter.Hop[] memory route2) = _taxedMidRoute();
        assertEq(mid2.balanceOf(address(converter)), 0, "nothing donated this time");
        uint256 without = converter.convert(address(quote), 10e18, route2, address(this), 0);
        assertGt(without, 0, "admitted with nothing to make up a shortfall from");
        assertEq(without, withDonation, "and converted for the same amount either way");
    }

    /// The ruling's named outbound witness. A plain fee-on-transfer quote on the
    /// `converter -> pool` leg deducts the cut from the transfer, so the pool is
    /// credited less than it asked and refuses at its OWN fill check — with or
    /// without a donation, identically, because nothing about the refusal
    /// depends on what this contract holds.
    function test_anOutboundFeeOnTransferIsRefusedByThePoolsOwnFillCheckEitherWay() public {
        (InboundTaxToken tax, FeastConverter.Hop[] memory route) = _outboundTaxedRoute();
        tax.mint(address(converter), 1e18);
        uint256 donation = tax.balanceOf(address(converter));
        vm.expectRevert(
            abi.encodeWithSelector(MockV3Pool.NotPaidInFull.selector, address(tax), 10e18, 9.9e18)
        );
        converter.convert(address(tax), 10e18, route, address(this), 0);
        assertEq(tax.balanceOf(address(converter)), donation, "the donation is untouched by the refusal");

        (InboundTaxToken tax2, FeastConverter.Hop[] memory route2) = _outboundTaxedRoute();
        assertEq(tax2.balanceOf(address(converter)), 0, "nothing donated this time");
        vm.expectRevert(
            abi.encodeWithSelector(MockV3Pool.NotPaidInFull.selector, address(tax2), 10e18, 9.9e18)
        );
        converter.convert(address(tax2), 10e18, route2, address(this), 0);
    }

    /// `r1v`'s third MEDIUM, and the bound that closes it. The callback used to
    /// pay whatever the pool ASKED out of whatever this contract happened to
    /// hold. A token that charges its sender ON TOP debits more than the hop
    /// brought while crediting the pool in full, so the pool reported a fill and
    /// the surcharge came out of a donation — reachable from the far side of a
    /// swap, which is a stray balance spent.
    ///
    /// Both calls are now refused and the donation is untouched, which is what
    /// B2 promises. The two refusals carry DIFFERENT names, and that is honest
    /// rather than tidy: with a donation present the surcharge succeeds and our
    /// own measured-debit bound catches it by name; with nothing to take it
    /// from, the token's own balance check fires first. Admission does not
    /// depend on the donation either way.
    ///
    /// Kills: removing the measured-debit bound in `_hop`; removing the ask
    /// bound in the callback.
    function test_anOutboundSurchargeNeverDipsIntoADonation() public {
        (SenderSurchargeToken sur, FeastConverter.Hop[] memory route) = _surchargeRoute();
        sur.mint(address(converter), 1e18);
        uint256 donation = sur.balanceOf(address(converter));
        vm.expectRevert(
            abi.encodeWithSelector(FeastConverter.AskExceedsHop.selector, address(sur), 10.1e18, 10e18)
        );
        converter.convert(address(sur), 10e18, route, address(this), 0);
        assertEq(sur.balanceOf(address(converter)), donation, "the donation is exactly where it was");

        (SenderSurchargeToken sur2, FeastConverter.Hop[] memory route2) = _surchargeRoute();
        assertEq(sur2.balanceOf(address(converter)), 0, "nothing donated this time");
        vm.expectRevert(); // the token's own balance check, with nothing to take it from
        converter.convert(address(sur2), 10e18, route2, address(this), 0);
    }

    /// `r1v`'s second MEDIUM. The inbound measurement is a CHECKED subtraction
    /// of the balance before from the balance after, so a token that SHRINKS
    /// this contract's balance while transferring in panics outright — and
    /// whether it panics depends on the size of a prior donation, which is
    /// admission deciding on a donation again.
    ///
    /// Under the ruling a non-positive arrival is a named refusal, identical
    /// with or without a donation.
    ///
    /// Kills: the bare subtraction.
    /// The third shape, and the one that makes the limit's wording general.
    /// Round 3's Claude-family verifier: a token whose ACCEPTANCE of a transfer
    /// depends on the recipient's standing balance. Nothing is spent, nothing is
    /// rewritten, nothing is transiently required of the sender — and the
    /// identical conversion is admitted with an empty converter and refused with
    /// a donation sitting near the cap.
    ///
    /// So the limit is not about rebases, and not about transient requirements
    /// either: it is about what a transfer requires of EITHER party's standing
    /// balance. Declared, for the same reason as the other two.
    ///
    /// Kills: a limit sentence that names only the sender, or only a rewrite.
    function test_theDeclaredLimitOfATransferThatReadsTheRecipientsBalance() public {
        (HolderCapToken a, FeastConverter.Hop[] memory ra) = _cappedRoute();
        a.setCap(15e18);
        assertEq(a.balanceOf(address(converter)), 0, "nothing donated");
        assertEq(converter.convert(address(a), 10e18, ra, address(this), 0), 10e18, "admitted, and converted");

        (HolderCapToken b, FeastConverter.Hop[] memory rb) = _cappedRoute();
        b.mint(address(converter), 9e18); // a donation, sitting near the cap
        b.setCap(15e18);
        vm.expectRevert(bytes("holder cap"));
        converter.convert(address(b), 10e18, rb, address(this), 0);
        assertEq(b.balanceOf(address(converter)), 9e18, "the donation is never spent - only in the way");
    }

    function _cappedRoute() internal returns (HolderCapToken t, FeastConverter.Hop[] memory route) {
        t = new HolderCapToken();
        MockV3Pool p = new MockV3Pool(address(t), address(wbnb));
        factory.set(address(t), address(wbnb), 500, address(p));
        p.setOldestTimestamp(uint32(block.timestamp - 3_600));
        p.setTicks(0, 0);
        p.setOutputBps(10_000);
        wbnb.mint(address(p), 1_000e18);
        t.mint(address(this), 1_000e18);
        t.approve(address(converter), type(uint256).max);
        route = new FeastConverter.Hop[](1);
        route[0] = FeastConverter.Hop({tokenOut: address(wbnb), fee: 500});
    }

    /// Round 3's verifier (`r3v`), and the second half of B2's declared limit:
    /// **a donation can be NEEDED without ever being spent, and without any
    /// rebase.** The measurement covers what a transfer moves; it cannot cover
    /// what a transfer transiently requires the sender to hold.
    ///
    /// The token here is exact in net terms — one unit out to a collector, the
    /// transfer, the unit back — so every leg's measurement agrees and every
    /// balance is conserved once the call returns. It still needs the converter
    /// to hold one unit more than the hop brought, for the length of one
    /// `_update`. Without a donation the payment reverts; with one it succeeds,
    /// and the donation is still there afterwards.
    ///
    /// Declared rather than fixed, for the same reason as the rebase row: no
    /// measurement this contract can make reaches inside another contract's
    /// transfer. Kills: a claim that B2's limit is only about rebases.
    function test_theDeclaredLimitOfMeasuringATransientRequirement() public {
        (TransientHoldToken a, FeastConverter.Hop[] memory ra) = _transientRoute();
        a.setTaxedFrom(address(converter));
        vm.expectRevert(); // the token's own balance check, mid-transfer
        converter.convert(address(a), 10e18, ra, address(this), 0);

        (TransientHoldToken b, FeastConverter.Hop[] memory rb) = _transientRoute();
        b.mint(address(converter), 1);
        b.setTaxedFrom(address(converter));
        uint256 out = converter.convert(address(b), 10e18, rb, address(this), 0);
        assertEq(out, 10e18, "the identical call, admitted because somebody had donated one unit");
        assertEq(b.balanceOf(address(converter)), 1, "and the donation was never spent - only needed");
    }

    function _transientRoute() internal returns (TransientHoldToken t, FeastConverter.Hop[] memory route) {
        t = new TransientHoldToken();
        MockV3Pool p = new MockV3Pool(address(t), address(wbnb));
        factory.set(address(t), address(wbnb), 500, address(p));
        p.setOldestTimestamp(uint32(block.timestamp - 3_600));
        p.setTicks(0, 0);
        p.setOutputBps(10_000);
        wbnb.mint(address(p), 1_000e18);
        t.mint(address(this), 1_000e18);
        t.approve(address(converter), type(uint256).max);
        route = new FeastConverter.Hop[](1);
        route[0] = FeastConverter.Hop({tokenOut: address(wbnb), fee: 500});
    }

    /// The limit of what measuring an arrival can do, measured rather than
    /// asserted away — round 2's verifier (`r2v`) found it and it is right.
    ///
    /// A balance difference can separate a donation from an arrival only if the
    /// token moves a fixed amount between two parties. A token that REBASES the
    /// holder's balance breaks that: the shrink falls on the donation and the
    /// arrival together, so what the converter measures as "what arrived"
    /// genuinely depends on what was donated, and no measurement it can make
    /// separates them. All three rows below are the same call.
    ///
    /// This is B2's declared limit, not a defect the next commit fixes. It is
    /// the family the README already declares at the venue boundary — a quote
    /// token that can rewrite balances can also pause, blacklist or seize — and
    /// the same family `docs/plan.md` §B9 declares for the sink. The app's quote
    /// allowlist is the admission control for all of it.
    ///
    /// Kills: a claim that B2 covers rebasing tokens.
    function test_theDeclaredLimitOfMeasuringAnArrival() public {
        // Row 1: nothing donated. 10 arrives, the rebase halves it to 5.
        (InboundShrinkToken a, FeastConverter.Hop[] memory ra) = _shrinkRoute();
        a.arm();
        uint256 alone = converter.convert(address(a), 10e18, ra, address(this), 0);
        assertEq(alone, 5e18, "converts 5 of a nominal 10");

        // Row 2: 5 donated. The identical call converts 2.5. Nothing was spent
        // out of the donation — it ends where it started — but the rebase fell
        // on the donation and the arrival together, so what the balance
        // difference SAYS arrived is smaller. The donation changed what the
        // conversion is for, which is the half of B2 about cost.
        (InboundShrinkToken b, FeastConverter.Hop[] memory rb) = _shrinkRoute();
        b.mint(address(converter), 5e18);
        b.arm();
        uint256 withDonation = converter.convert(address(b), 10e18, rb, address(this), 0);
        assertEq(withDonation, 2.5e18, "the same call, converting less because somebody had donated");
        assertLt(withDonation, alone, "which is the difference no measurement here can remove");
        assertEq(b.balanceOf(address(converter)), 5e18, "and the donation itself is where it was");

        // Row 3: 30 donated. The balance ends BELOW where it started, so there
        // is no arrival to measure and the call is refused by name.
        (InboundShrinkToken c, FeastConverter.Hop[] memory rc) = _shrinkRoute();
        c.mint(address(converter), 30e18);
        c.arm();
        vm.expectRevert(
            abi.encodeWithSelector(FeastConverter.NothingArrived.selector, address(c), 30e18, 20e18)
        );
        converter.convert(address(c), 10e18, rc, address(this), 0);
    }

    function _shrinkRoute() internal returns (InboundShrinkToken shr, FeastConverter.Hop[] memory route) {
        shr = new InboundShrinkToken();
        MockV3Pool p = new MockV3Pool(address(shr), address(wbnb));
        factory.set(address(shr), address(wbnb), 500, address(p));
        p.setOldestTimestamp(uint32(block.timestamp - 3_600));
        p.setTicks(0, 0);
        p.setOutputBps(10_000);
        wbnb.mint(address(p), 1_000e18);
        shr.mint(address(this), 1_000e18);
        shr.approve(address(converter), type(uint256).max);
        route = new FeastConverter.Hop[](1);
        route[0] = FeastConverter.Hop({tokenOut: address(wbnb), fee: 500});
    }

    function test_anInboundThatShrinksTheBalanceIsRefusedByNameNotByPanic() public {
        InboundShrinkToken shr = new InboundShrinkToken();
        MockV3Pool shrPool = new MockV3Pool(address(shr), address(wbnb));
        factory.set(address(shr), address(wbnb), 500, address(shrPool));
        shrPool.setOldestTimestamp(uint32(block.timestamp - 3_600));
        shrPool.setTicks(0, 0);
        shrPool.setOutputBps(10_000);
        wbnb.mint(address(shrPool), 1_000e18);
        shr.mint(address(this), 1_000e18);
        shr.approve(address(converter), type(uint256).max);

        FeastConverter.Hop[] memory route = new FeastConverter.Hop[](1);
        route[0] = FeastConverter.Hop({tokenOut: address(wbnb), fee: 500});

        // A donation big enough that the shrink takes the balance BELOW where it
        // started: 30 donated, 10 sent, halved to 20.
        shr.mint(address(converter), 30e18);
        shr.arm();
        vm.expectRevert(
            abi.encodeWithSelector(FeastConverter.NothingArrived.selector, address(shr), 30e18, 20e18)
        );
        converter.convert(address(shr), 10e18, route, address(this), 0);
        assertEq(shr.balanceOf(address(converter)), 30e18, "the donation is untouched by the refusal");
    }

    function _outboundTaxedRoute() internal returns (InboundTaxToken tax, FeastConverter.Hop[] memory route) {
        tax = new InboundTaxToken();
        MockV3Pool p = new MockV3Pool(address(tax), address(wbnb));
        factory.set(address(tax), address(wbnb), 500, address(p));
        p.setOldestTimestamp(uint32(block.timestamp - 3_600));
        p.setTicks(0, 0);
        p.setOutputBps(10_000);
        wbnb.mint(address(p), 1_000e18);
        tax.mint(address(this), 1_000e18);
        tax.approve(address(converter), type(uint256).max);
        tax.setTax(address(converter), 100); // charged only when THIS contract pays a pool
        route = new FeastConverter.Hop[](1);
        route[0] = FeastConverter.Hop({tokenOut: address(wbnb), fee: 500});
    }

    function _surchargeRoute() internal returns (SenderSurchargeToken sur, FeastConverter.Hop[] memory route) {
        sur = new SenderSurchargeToken();
        MockV3Pool p = new MockV3Pool(address(sur), address(wbnb));
        factory.set(address(sur), address(wbnb), 500, address(p));
        p.setOldestTimestamp(uint32(block.timestamp - 3_600));
        p.setTicks(0, 0);
        p.setOutputBps(10_000);
        wbnb.mint(address(p), 1_000e18);
        sur.mint(address(this), 1_000e18);
        sur.approve(address(converter), type(uint256).max);
        sur.setSurcharge(address(converter), 100);
        route = new FeastConverter.Hop[](1);
        route[0] = FeastConverter.Hop({tokenOut: address(wbnb), fee: 500});
    }

    function _taxedMidRoute() internal returns (MidTaxToken mid, FeastConverter.Hop[] memory route) {
        mid = new MidTaxToken();
        MockV3Pool first = new MockV3Pool(address(quote), address(mid));
        MockV3Pool second = new MockV3Pool(address(mid), address(wbnb));
        factory.set(address(quote), address(mid), 500, address(first));
        factory.set(address(mid), address(wbnb), 500, address(second));
        for (uint256 i = 0; i < 2; i++) {
            MockV3Pool p = i == 0 ? first : second;
            p.setOldestTimestamp(uint32(block.timestamp - 3_600));
            p.setTicks(0, 0);
            p.setOutputBps(10_000);
        }
        mid.mint(address(first), 1_000e18);
        wbnb.mint(address(second), 1_000e18);
        // The first pool's outbound transfer of the intermediate is taxed 1%.
        mid.setTax(address(first), 100);

        route = new FeastConverter.Hop[](2);
        route[0] = FeastConverter.Hop({tokenOut: address(mid), fee: 500});
        route[1] = FeastConverter.Hop({tokenOut: address(wbnb), fee: 500});
    }

    function _twoHopRoute() internal returns (MockERC20 mid, MockV3Pool second) {
        mid = new MockERC20("Mid", "MID", 18);
        MockV3Pool first = new MockV3Pool(address(quote), address(mid));
        second = new MockV3Pool(address(mid), address(wbnb));
        factory.set(address(quote), address(mid), 500, address(first));
        factory.set(address(mid), address(wbnb), 500, address(second));
        for (uint256 i = 0; i < 2; i++) {
            MockV3Pool p = i == 0 ? first : second;
            p.setOldestTimestamp(uint32(block.timestamp - 3_600));
            p.setTicks(0, 0);
            p.setOutputBps(10_000);
        }
        mid.mint(address(first), 1_000e18);
        wbnb.mint(address(second), 1_000e18);
    }
}
