// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FeastGenesis} from "../../../src/FeastGenesis.sol";
import {FeastPlatformSink} from "../../../src/FeastPlatformSink.sol";
import {MockERC20} from "../../utils/MockERC20.sol";
import {UnitFixture} from "../../utils/UnitFixture.sol";

/// PoC for the round-r1 HIGH `sink-anchor-overflow` (`CA-fad351f89b`), reported by the codex lens
/// (`r1h`, the hook-checklist unit) at `src/FeastPlatformSink.sol:300` and by no other lens.
///
/// The claim: `take` re-anchors with
///
///     lot.anchor = Math.mulDiv(price, held + amountOut, held);
///
/// and evaluates `held + amountOut` in checked arithmetic BEFORE handing it to `mulDiv`. The
/// product `price * (held + amountOut)` is computed at 512 bits by `mulDiv` and the quotient here
/// is only `price * (1 + amountOut/held)` — at most twice the price, which always fits. The sum
/// alone is what overflows. So when the sink holds a plain ERC20's entire `type(uint256).max`
/// supply, every positive take reverts with an arithmetic panic, even though the price, the
/// payment and the resulting anchor all fit in a word.
///
/// Nothing hostile is required: no rebase, no clawback, no issuer privilege, no transfer hook —
/// only a token whose whole supply is in the lot. `open` accepts that lot (it holds something),
/// the published price is readable, and the purchase is affordable; it is the re-anchor on the way
/// out that fails. The asset is then permanently unobtainable from the sink: waiting does not
/// repair the addition, and `open` refuses to reopen an unchanged lot (`AlreadyOpened`).
///
/// This is the auditor's thread to pull: the assertion below is about the taker receiving what
/// they paid for, not about the panic. A fix that makes the sum unreachable — anchoring from
/// `held - amountOut` after the sale, or computing the ratio without forming the sum — turns this
/// test green without changing any price the sink publishes.
contract SinkAnchorOverflowPoC is UnitFixture {
    uint256 internal constant ONE = 1 << 128;
    address internal bidder = address(0x71DDE1);

    function test_aLotHoldingAnEntireSupplyCanStillBeBoughtFrom() public {
        _launch(10e18);

        // A plain 18-decimal ERC20 whose entire supply is the platform's to sell. Every token
        // here is an ordinary one: no fee on transfer, no rebase, no pause, no issuer powers.
        MockERC20 whole = new MockERC20("Whole Supply", "WHOLE", 18);
        whole.mint(address(sink), type(uint256).max);
        assertEq(
            whole.balanceOf(address(sink)),
            type(uint256).max,
            "the lot holds the asset's entire supply"
        );

        // The descent opens over it — the lot holds something, which is all `open` asks.
        sink.open(address(whole));

        // At the opening price one raw unit costs exactly 2^64 wei of platform coin, and the
        // taker can pay it. The published quote is readable and the purchase is affordable.
        uint256 price = sink.priceQ128(address(whole));
        assertEq(price, FeastGenesis.SINK_START_PRICE_Q128, "the descent starts at the top");
        uint256 cost = (price + ONE - 1) / ONE;
        assertEq(cost, 1 << 64, "one raw unit costs 2^64 wei at the opening price");

        deal(feast, bidder, cost);
        vm.prank(bidder);
        IERC20(feast).approve(address(sink), type(uint256).max);

        // The whole point of the sink: an opened lot can be bought from at the published price.
        // `take` instead reverts with an arithmetic panic while computing `held + amountOut`,
        // so this call never returns and neither assertion below is reached.
        vm.prank(bidder);
        sink.take(address(whole), 1, cost);

        assertEq(whole.balanceOf(bidder), 1, "the taker receives the unit they paid for");
        assertEq(whole.balanceOf(address(sink)), type(uint256).max - 1, "the lot is one unit lighter");
    }
}
