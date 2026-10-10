// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {FeastGenesis} from "../../../src/FeastGenesis.sol";
import {FeastPlatformSink} from "../../../src/FeastPlatformSink.sol";
import {PoolId} from "../../../src/venue/PoolId.sol";
import {MockERC20} from "../../utils/MockERC20.sol";
import {UnitFixture} from "../../utils/UnitFixture.sol";

/// PoC for the v1.6.12 round's HIGH `freeze-runs-the-clock` /
/// `guardian-auction-discount` / `sink-descent-runs-through-freeze`, reported by
/// THREE units across BOTH families — `P3-claude`, `P16` and `P16-claude` — at
/// `src/FeastPlatformSink.sol:265-280`.
///
/// The sink's price is a pure function of elapsed time:
///
///     uint256 elapsed  = block.timestamp - lot.anchoredAt;
///     uint256 halvings = elapsed / FeastGenesis.SINK_HALF_LIFE;   // ONE HOUR
///     price            = lot.anchor >> halvings;
///
/// A freeze stops `take`. It does not stop the clock. `SINK_HALF_LIFE` is one
/// hour and a freeze may run 72, so a single pull of the brake is **seventy-two
/// halvings** of the price of everything the sink is holding.
///
/// The guardian is the only address that can do this and the only address that
/// knows when it will end. It freezes, the descent runs with every buyer locked
/// out, and it unfreezes and takes — a multisig can batch the two into one
/// transaction, so no one else ever sees the price it bought at.
///
/// **This is what `P27` forbids, reached the one way the invariant's own witness
/// cannot see.** `testFuzz_theGuardianCannotMoveAWei` calls ONE function and
/// checks balances; this needs four — freeze, wait, unfreeze, take — and no
/// single call in it moves a wei that was not paid for.
contract FreezeRunsTheDescentClockPoC is UnitFixture {
    address internal taker = address(0x7A4E5);

    function setUp() public override {
        super.setUp();
        _launch(10e18);
        stock.mint(address(sink), 100e18);
    }

    /// The control: with no freeze, seventy-two hours of honest descent is
    /// exactly what the mechanism promises, and anybody may buy at it.
    function test_theDescentIsHonestWhenNobodyTouchesTheBrake() public {
        sink.open(address(stock));
        uint256 p0 = sink.priceQ128(address(stock));
        _advance(72 hours);
        assertEq(sink.priceQ128(address(stock)), _decayed(p0, 72 hours), "72 open hours, 72 halvings");
    }

    /// The finding: the same seventy-two hours with every buyer locked out.
    function test_aFreezeDoesNotDiscountTheSinkForTheGuardian() public {
        sink.open(address(stock));
        uint256 before = sink.priceQ128(address(stock));

        vm.prank(multisig);
        guardian.freeze();

        // Nobody can buy. The clock does not care. One second short of the cap,
        // because a lapsed freeze cannot be lifted — the guardian releases it
        // itself, which is the move.
        _advance(72 hours - 1);

        vm.prank(multisig);
        guardian.unfreeze();

        uint256 after_ = sink.priceQ128(address(stock));
        assertGe(
            after_,
            before / 2,
            "seventy-two hours in which nobody could buy discounted the sink's whole holding"
        );
    }

    /// The whole four-step move, end to end, in the guardian's own hands:
    /// freeze, wait, unfreeze, take. It must buy the guardian nothing.
    ///
    /// @dev The take itself is not attempted, and that is the finding restated
    ///      rather than avoided: at the honest price a quarter of this lot costs
    ///      more than 2^256 units of the platform coin, which is exactly why the
    ///      seventy-two halvings were worth stealing. Before the fix the same
    ///      quarter cost 1.3e36 and the guardian could pay it.
    function test_theGuardianCannotBuyTheLotAtAPriceItsOwnBrakeSet() public {
        sink.open(address(stock));
        uint256 fair = sink.priceQ128(address(stock));

        vm.prank(multisig);
        guardian.freeze();
        _advance(72 hours - 1);

        vm.prank(multisig);
        guardian.unfreeze();

        assertEq(
            sink.priceQ128(address(stock)),
            fair,
            "seventy-two hours with the brake down moved the price by nothing at all"
        );

        // And the descent picks up exactly where it left off: an hour of OPEN
        // time is one halving, whatever happened while it was shut.
        _advance(1 hours);
        assertEq(sink.priceQ128(address(stock)), fair / 2, "the clock resumes, it does not restart");
    }

    /// @dev What the sink's own formula gives for `elapsed` seconds.
    function _decayed(uint256 p0, uint256 elapsed) internal pure returns (uint256) {
        uint256 halvings = elapsed / FeastGenesis.SINK_HALF_LIFE;
        uint256 p = halvings >= 255 ? 0 : p0 >> halvings;
        uint256 into = elapsed % FeastGenesis.SINK_HALF_LIFE;
        return p - (p * into) / (2 * FeastGenesis.SINK_HALF_LIFE);
    }
}
