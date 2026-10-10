// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FeastGenesis} from "../../../src/FeastGenesis.sol";
import {FeastPlatformSink} from "../../../src/FeastPlatformSink.sol";
import {UnitFixture} from "../../utils/UnitFixture.sol";

/// PoC for the round-r1 HIGH `price-decay` (`CA-fb2e051555`), reported by the claude lens
/// (`r1a-claude`) at `src/FeastPlatformSink.sol:85-97` and by no other lens in this round.
///
/// The defect: `open` started an asset's descending price with no inventory requirement, so the
/// clock could run down on an empty lot. After 255 half-lives the price was clamped to one, at
/// which any amount up to 2^128 raw units ceiled to a single wei of platform coin. The post-sale
/// floor is the last sale price shifted right by `SINK_FLOOR_HALVINGS` (six), which for a sale at
/// one is zero, and the re-anchor is at most a doubling — so the *next* refill of that asset sold
/// for one wei too, and so did the one after that.
///
/// Fixed in v1.6.2: a descent prices the lot it was opened over. `open` requires inventory, and a
/// lot holding at least `SINK_REOPEN_MULTIPLE` times what it held when its descent began — which
/// includes every refill into an emptied lot — is priced from the start price again until someone
/// opens a descent over it. `take` prices through the same branch, so the taker whose refill
/// arrives cannot buy it at the price the smaller lot had descended to.
///
/// **What changed in this file at the fix, and why.** The test keeps its name and its closing
/// assertion — a refilled lot is not given away. Its middle assertion did not survive, because it
/// asserted the defect's own mechanism: it took the first release for one wei to show that the
/// empty-lot descent had reached the clamp. That descent cannot happen now, so the step is
/// replaced by the alternative the verdict itself named — `CostAboveLimit` at a limit of one — and
/// the clamp is reached the honest way instead, by a descent that runs over a lot genuinely on
/// offer. Nothing was weakened: the assertion that fails on the unfixed contract is unchanged.
contract SinkPriceDecayPoC is UnitFixture {
    uint256 internal constant ONE = 1 << 128;
    address internal taker = address(0x7A7E);

    function test_aRefillOfADecayedLotIsNotGivenAway() public {
        _launch(10e18);

        // A stranger tries to open the lot on day one, while it holds nothing at all. The clock
        // has nothing to price, and is refused at the door.
        vm.prank(address(0xBEEF));
        vm.expectRevert(abi.encodeWithSelector(FeastPlatformSink.NothingToOffer.selector, address(stock)));
        sink.open(address(stock));
        assertEq(stock.balanceOf(address(sink)), 0, "the lot is empty, so no descent begins");

        // Time passes — the time that used to be credited as a descent.
        _advance(uint256(FeastGenesis.SINK_HALF_LIFE) * 255);

        // The platform's first fee release lands. The elapsed time bought nobody anything: no
        // descent was ever opened over this asset, so there is no price to take it at.
        stock.mint(address(sink), 1e24);
        _fund(1);
        vm.prank(taker);
        vm.expectRevert(abi.encodeWithSelector(FeastPlatformSink.NotOpened.selector, address(stock)));
        sink.take(address(stock), 1e24, 1);

        // Opened now, over the lot that is actually here, it starts at the top — so the release is
        // not for sale at one wei either. This is the verdict's own alternative assertion.
        sink.open(address(stock));
        vm.prank(taker);
        vm.expectRevert(abi.encodeWithSelector(FeastPlatformSink.CostAboveLimit.selector, 1e24 << 64, 1));
        sink.take(address(stock), 1e24, 1);

        // The declared risk is unchanged: a lot that really is on offer, and that nobody takes,
        // descends to the clamp of one, and there it is sold for one wei.
        _advance(uint256(FeastGenesis.SINK_HALF_LIFE) * 255);
        _fund(1);
        vm.prank(taker);
        uint256 firstCost = sink.take(address(stock), 1e24, 1);
        assertEq(firstCost, 1, "a descent over an offered lot still reaches the clamp");

        // An hour later the next release arrives. The floor from a sale at one is zero and the
        // re-anchor at most two — so before v1.6.2 this refill was sold for one wei as well. It is
        // a different lot now, priced from the top, and it has to descend over itself in the open.
        _advance(uint256(FeastGenesis.SINK_HALF_LIFE));
        stock.mint(address(sink), 1e24);
        assertEq(
            sink.priceQ128(address(stock)),
            FeastGenesis.SINK_START_PRICE_Q128,
            "the refill is a new lot, not the remains of the old descent"
        );

        sink.open(address(stock));
        _advance(uint256(FeastGenesis.SINK_HALF_LIFE) * 77); // three days of descent, in the open
        uint256 secondCost = (1e24 * sink.priceQ128(address(stock)) + ONE - 1) / ONE;
        _fund(secondCost);
        vm.prank(taker);
        assertEq(sink.take(address(stock), 1e24, secondCost), secondCost, "taken at the published price");

        assertGt(
            secondCost,
            1e18,
            "a refilled lot is given away: 1,000,000 whole tokens for one wei of platform coin"
        );
    }

    function _fund(uint256 amount) private {
        deal(feast, taker, amount);
        vm.prank(taker);
        IERC20(feast).approve(address(sink), type(uint256).max);
    }
}
