// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {FeastConstants} from "../../../src/FeastConstants.sol";
import {FeastGenesis} from "../../../src/FeastGenesis.sol";
import {FeastFactory} from "../../../src/FeastFactory.sol";
import {FeastHook} from "../../../src/FeastHook.sol";
import {PoolId} from "../../../src/venue/PoolId.sol";
import {PoolKey} from "../../../src/venue/PoolKey.sol";
import {UnitFixture} from "../../utils/UnitFixture.sol";

/// PoC for the v1.6.13 round's two HIGHs — **the clocks the v1.6.13 fix missed**.
///
/// v1.6.13 made three clocks exclude frozen time: the sink's DESCENT, the
/// emission claim grace, and the two ninety-day windows. The round that followed
/// pointed at two more of exactly the same shape, and between them seven units
/// across both families reported it:
///
///   `P3` HIGH, `P3-claude` MEDIUM, `P16-claude` HIGH, `P16b` HIGH
///       — `FeastPlatformSink._floorNow` decays the post-sale FLOOR on wall
///         time. `take` is frozen; the floor is not. A freeze therefore cuts the
///         floor that protects the lot, which is the same discount the descent
///         gave before it was fixed, through the other half of the price.
///
///   `P6` HIGH, `P16b` HIGH, `P6-claude` MEDIUM
///       — `FeastHook`'s opening purchase cap is a window of BLOCKS armed when
///         the pool opens. A freeze spanning those blocks consumes them while
///         every swap is refused, so the cap has lapsed by the time anyone may
///         trade and the first buyer is uncapped.
///
/// **This is the shape, not the site.** I fixed the three clocks the ruling
/// named and did not sweep for every clock a freeze can reach. These two are
/// what that cost.
contract FreezeRunsTheOtherClocksPoC is UnitFixture {
    address internal taker = address(0x7A4E5);

    /// The sink's FLOOR must not decay while nobody may buy.
    function test_aFreezeDoesNotDecayTheSinksFloor() public {
        _launch(10e18);
        stock.mint(address(sink), 100e18);
        sink.open(address(stock));

        // A real sale sets a floor, and the floor's clock starts at that sale.
        _advance(150 hours);
        uint256 price = sink.priceQ128(address(stock));
        uint256 cost = (25e18 * price + (1 << 128) - 1) / (1 << 128);
        deal(feast, taker, cost);
        vm.prank(taker);
        IERC20(feast).approve(address(sink), cost);
        vm.prank(taker);
        sink.take(address(stock), 25e18, cost);

        // **The witness has to reach its bound**: the floor only shows in the
        // price once the descent has fallen BELOW it, so let enough OPEN time
        // pass for that. Without this the descent is still the binding number
        // and the floor could decay to nothing unobserved.
        _advance(40 hours);
        uint256 floorBefore = sink.priceQ128(address(stock));
        assertGt(floorBefore, 0, "the floor is what is being read now");

        vm.prank(multisig);
        guardian.freeze();
        _advance(72 hours - 1);
        vm.prank(multisig);
        guardian.unfreeze();

        assertEq(
            sink.priceQ128(address(stock)),
            floorBefore,
            "seventy-two hours in which nobody could buy decayed the floor that protects the lot"
        );
    }

    /// The opening cap is a window of BLOCKS, and a freeze must not spend them.
    ///
    /// @dev Rewritten at v1.6.15. v1.6.14 answered this by subtracting the
    ///      guardian's frozen BLOCKS from `block.number`, and the v1.6.14 round
    ///      showed that counter cannot be written: a contract cannot observe its
    ///      chain's block rate, and the estimate was short by a factor of four
    ///      on BSC. The window is anchored on an event a freeze cannot spend
    ///      instead — the pool's first SERVED swap — so this test now asks the
    ///      same question of the mechanism that replaced the one it was written
    ///      against. The full v1.6.15 treatment, with the pre-buy and the gated
    ///      pool, is in `FreezeClockFixesLeftThreeGaps.t.sol`.
    function test_aFreezeDoesNotConsumeTheOpeningCapWindow() public {
        // NOT through `_create`: the fixture rolls `CAP_BLOCKS` forward after
        // every creation, which would spend the window before the test starts.
        (, PoolKey memory k) = factory.create(
            FeastFactory.CreateParams({
                name: "Coin", symbol: "COIN", supply: 1_000_000_000e18, quote: address(wbnb),
                creator: creator, selfBurnBps: 2_000, referrerBps: 1_000,
                prebuyQuoteIn: 0, minCoinsOut: 0, vestingDuration: 0,
                sqrtPriceX96: SQRT_PRICE_1_1, startTick: 0,
                liquidity: uint128(1_000_000_000e18 * 999 / 1_000),
                salt: bytes32(uint256(0xCA9)), metadataHash: bytes32(0)
            })
        );
        PoolId id = _idOf(k);

        // The brake goes down over the blocks the window used to be armed in.
        vm.prank(multisig);
        guardian.freeze();
        vm.roll(vm.getBlockNumber() + FeastConstants.CAP_BLOCKS + 1);
        vm.prank(multisig);
        guardian.unfreeze();

        // Nothing was spent, because nothing had started: the window is armed
        // by the first swap the pool serves, and it has served none.
        assertEq(
            uint256(hook.servedBlocks(id)),
            0,
            "the opening cap's window was spent while every swap was refused, so the first buyer is uncapped"
        );
    }

    function _idOf(PoolKey memory k) internal pure returns (PoolId) {
        return PoolId.wrap(keccak256(abi.encode(k)));
    }
}
