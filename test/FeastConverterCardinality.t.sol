// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {FeastConstants} from "../src/FeastConstants.sol";
import {FeastConverter} from "../src/FeastConverter.sol";
import {IPancakeV3Pool} from "../src/venue/IPancakeV3.sol";

import {MockERC20} from "./utils/MockERC20.sol";
import {MockV3Factory, MockV3Pool} from "./utils/MockV3Pool.sol";

/// Step 1 of the deployment recipe, proven rather than asserted.
///
/// A quote token whose pool holds one observation cannot be converted, because
/// the pool's "average" is its spot price. That is a fixable condition, not a
/// permanent one: growing the ring is permissionless. These tests show the
/// mechanism on the real pool and the outcome on a deterministic one.
contract FeastConverterCardinalityTest is Test {
    address internal constant V3_FACTORY = 0x0BFbCF9fa4f9C56B0F40a671Ad40E0805A091865;
    address internal constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address internal constant USDT = 0x55d398326f99059fF775485246999027B3197955;
    /// Placeholder quote token: the family the survey probed, not the family the
    /// owner's evidence points at. `tools/discover_quotes.py` is how the real
    /// ones get identified; every fork test here takes the address as a
    /// constant so re-pointing is a one-line change.
    address internal constant PLACEHOLDER_QUOTE = 0x8aD3c73F833d3F9A523aB01476625F269aEB7Cf0;
    address internal constant PLACEHOLDER_POOL = 0x5E12d6EdB2b7D5330e474ea2D2694A3b3E35d492;

    uint256 internal constant FORK_BLOCK = 120_721_477;

    /// The mechanism, on the real pool: anyone may ask for a bigger ring, and
    /// the request lands. The ring itself only widens when the pool is next
    /// written to — which is why the recipe says "grow it, then trade through
    /// it, then check".
    function test_fork_growingTheRingIsPermissionlessAndTakesEffectOnTheNextWrite() public {
        string memory url = vm.envOr("BSC_RPC_URL", string(""));
        if (bytes(url).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(url, FORK_BLOCK);
        FeastConverter converter = new FeastConverter(V3_FACTORY, WBNB, address(this));

        (bool priceableBefore,, uint16 cardBefore,) = converter.hopIsPriceable(PLACEHOLDER_QUOTE, USDT, 2500);
        assertFalse(priceableBefore, "not priceable to begin with");
        assertEq(cardBefore, 1, "because the ring holds one observation");

        // No permission of any kind: an arbitrary address may do this.
        vm.prank(address(0xDEAD01));
        IPancakeV3Pool(PLACEHOLDER_POOL).increaseObservationCardinalityNext(200);

        (, , , uint16 card, uint16 cardNext,,) = IPancakeV3Pool(PLACEHOLDER_POOL).slot0();
        assertEq(cardNext, 200, "the request landed");
        assertEq(card, 1, "and takes effect on the next write, not now");

        (bool priceableAfter,,,) = converter.hopIsPriceable(PLACEHOLDER_QUOTE, USDT, 2500);
        assertFalse(priceableAfter, "so the hop is still refused until the pool trades");
    }

    /// The outcome, deterministically: once the ring really has widened and has
    /// history behind it, the same hop is accepted.
    function test_aWidenedRingWithHistoryBecomesPriceable() public {
        vm.warp(1_000_000);
        MockERC20 quote = new MockERC20("Quote", "Q", 18);
        MockERC20 wbnb = new MockERC20("Wrapped", "W", 18);
        MockV3Factory factory = new MockV3Factory();
        MockV3Pool pool = new MockV3Pool(address(quote), address(wbnb));
        factory.set(address(quote), address(wbnb), 500, address(pool));
        FeastConverter converter = new FeastConverter(address(factory), address(wbnb), address(this));

        pool.setOldestTimestamp(uint32(block.timestamp - 3_600));
        pool.setTicks(0, 0);
        pool.setOutputBps(10_000);
        wbnb.mint(address(pool), 100e18);
        quote.mint(address(this), 100e18);
        quote.approve(address(converter), type(uint256).max);

        pool.setCardinality(1);
        (bool before_,,,) = converter.hopIsPriceable(address(quote), address(wbnb), 500);
        assertFalse(before_, "one observation is not an average");

        pool.setCardinality(200);
        (bool after_,, uint16 card, uint32 age) = converter.hopIsPriceable(address(quote), address(wbnb), 500);
        assertTrue(after_, "a widened ring with history is priceable");
        assertEq(card, 200, "the ring really widened");
        assertGe(age, FeastConstants.MIN_OBSERVATION_AGE, "with history behind it");

        // And the conversion that was refused now goes through.
        FeastConverter.Hop[] memory route = new FeastConverter.Hop[](1);
        route[0] = FeastConverter.Hop({tokenOut: address(wbnb), fee: 500});
        assertGt(converter.convert(address(quote), 10e18, route, address(this), 0), 0, "it converts");
    }
}
