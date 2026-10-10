// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Currency} from "../../../src/venue/Currency.sol";
import {Hooks} from "infinity-core/src/libraries/Hooks.sol";
import {CustomRevert} from "infinity-core/src/libraries/CustomRevert.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";

import {FeastConstants} from "../../../src/FeastConstants.sol";
import {FeastHook} from "../../../src/FeastHook.sol";
import {IFeastCLHooks} from "../../../src/venue/IFeastCLHooks.sol";
import {FeastGenesis} from "../../../src/FeastGenesis.sol";
import {FeastFactory} from "../../../src/FeastFactory.sol";
import {PoolId} from "../../../src/venue/PoolId.sol";
import {PoolKey} from "../../../src/venue/PoolKey.sol";
import {UnitFixture} from "../../utils/UnitFixture.sol";
import {VenueBridge} from "../../utils/VenueBridge.sol";

/// PoC for the v1.6.14 round — **three gaps the v1.6.14 fixes themselves left**.
///
/// v1.6.14 answered the ruling's principle (every clock a freeze can reach
/// measures OPEN time or OPEN blocks) with three changes: `frozenBlocks()` in
/// the guardian, a frozen-time subtraction in the sink's floor, and the hook's
/// opening cap re-expressed in open-block coordinates. The focused re-round
/// pointed at all three of them. Nineteen verdicts across both families;
/// the units that carried each finding are named on the test.
///
/// The shape is the one this lane has now been taught three times: **a fix
/// applied at the sites that were reported rather than to the shape.** The
/// v1.6.14 sweep was supposed to end it, and it did end it for the clocks it
/// enumerated — but it enumerated the clocks that EXISTED, and these three gaps
/// are in the corrections themselves.
contract FreezeClockFixesLeftThreeGapsPoC is UnitFixture {
    using VenueBridge for PoolKey;

    address internal taker = address(0x7A4E5);

    /// GAP 1 — `P3` HIGH, `P16b` HIGH, `P3-claude` MEDIUM.
    ///
    /// `take` writes `lot.frozenAtAnchor` unconditionally
    /// (`FeastPlatformSink.sol:444`) but writes `lot.lastSaleAt` only when the
    /// sale RAISES the floor (`:498-500`). The floor's clock is `lastSaleAt`
    /// and its frozen-time checkpoint is `frozenAtAnchor`, so after any take
    /// that does not raise the floor the pair no longer refers to the same
    /// instant: every freeze between the last RAISING sale and that take is
    /// thereafter charged to the floor as OPEN time.
    ///
    /// The docstring on `_floorNow` (`:352-354`) states the opposite —
    /// "`lastSaleAt` and `frozenAtAnchor` are written together by `take`" — and
    /// the comment thirty lines below it at `:456-466` says in terms that a
    /// non-raising sale leaves "neither the base nor the clock" touched. I wrote
    /// both. The second is the code; the first is what the fix assumed.
    ///
    /// Anyone may buy one raw unit. This hands back the whole discount v1.6.14
    /// had just taken away, for the cost of a dust purchase.
    function test_aDustTakeDoesNotSpendTheFreezeOnTheFloor() public {
        _launch(10e18);
        stock.mint(address(sink), 100e18);
        sink.open(address(stock));

        // A real sale raises the floor and starts the floor's own clock.
        _advance(150 hours);
        _take(25e18);

        // Let the descent fall below the floor, so what is read from here on is
        // the FLOOR. One hour is the descent's half-life and twenty-four the
        // floor's, so after forty open hours the descent is far beneath it.
        _advance(40 hours);
        uint256 floorBefore = sink.priceQ128(address(stock));
        assertGt(floorBefore, 0, "the floor is what is being read");

        // Seventy-two hours in which nobody may buy. v1.6.14 made this free.
        vm.prank(multisig);
        guardian.freeze();
        _advance(72 hours - 1);
        vm.prank(multisig);
        guardian.unfreeze();
        assertEq(sink.priceQ128(address(stock)), floorBefore, "the freeze alone is free, as v1.6.14 made it");

        // One raw unit, bought by anyone. `mulDiv(price, 1, 75e18)` is zero, so
        // this sale seeds nothing and cannot raise the floor — and therefore, by
        // the v1.6.3 rule, must not restart the floor's clock either.
        _take(1);

        // Four OPEN hours. The floor's half-life is twenty-four, so a correct
        // floor is still within an eighth of where it stood; the descent this
        // dust take re-anchored has halved four times and is at most a sixteenth
        // of it, which is how this reading is known to be the floor and not the
        // descent.
        _advance(4 hours);
        assertGt(
            sink.priceQ128(address(stock)),
            floorBefore * 3 / 4,
            "a one-unit purchase charged the floor for seventy-two hours in which nobody could buy"
        );
    }

    /// **The floor's checkpoint is its OWN, and a freeze before the sale proves
    /// it.** The v1.6.19 sweep found the test above no longer kills
    /// `read the floor's clock against the descent's checkpoint`, and it was
    /// right to: since v1.6.19 a take no longer writes `frozenAtAnchor` at all —
    /// the descent's clock is not restarted by a sale, so its checkpoint must
    /// not move either. `frozenAtAnchor` is now written once, at `open`.
    ///
    /// So the two checkpoints can only differ if frozen time falls BETWEEN the
    /// open and the raising sale, and the test above has none: both read zero,
    /// and swapping one for the other changes nothing. The mutation is still a
    /// real defect — it is just no longer reachable by that witness.
    ///
    /// This is the witness that reaches it. Two worlds with the SAME open time
    /// before the sale, one of which spends 72 hours frozen first. The floor's
    /// own clock starts at the sale, so the earlier freeze must not touch it and
    /// the two floors must agree to the wei. Reading the descent's checkpoint
    /// instead credits the floor with the pre-sale freeze and holds it up.
    function test_aFreezeBeforeTheSaleDoesNotTouchTheFloorsOwnClock() public {
        _launch(10e18);
        stock.mint(address(sink), 100e18);
        sink.open(address(stock));

        uint256 snap = vm.snapshotState();

        // World A: 150 open hours, then the sale, then 40 open hours.
        _advance(150 hours);
        _take(25e18);
        _advance(40 hours);
        uint256 floorA = sink.priceQ128(address(stock));
        assertGt(floorA, 0, "there is a floor to compare");

        vm.revertToState(snap);

        // World B: the same 150 OPEN hours before the sale, with 72 frozen
        // hours in the middle of them. The sale sees an identical descent, so
        // it seeds an identical floor.
        _advance(10 hours);
        vm.prank(multisig);
        guardian.freeze();
        _advance(72 hours - 1);
        vm.prank(multisig);
        guardian.unfreeze();
        _advance(140 hours);
        _take(25e18);
        _advance(40 hours);

        assertEq(
            sink.priceQ128(address(stock)),
            floorA,
            "a freeze that ended before the sale was credited to the floor's own clock"
        );
    }

    /// GAP 2 — `P16-claude` MEDIUM, `P6-claude` MEDIUM, `HK11-claude` MEDIUM,
    /// `HK11b` MEDIUM, `P16b` MEDIUM. Five units, both families.
    ///
    /// v1.6.14 moved the ungated arming and the check into open-block
    /// coordinates and left the GATED arming (`FeastHook.sol:635`) in wall
    /// blocks, so a gated pool's window was `CAP_BLOCKS` plus every block the
    /// guardian had ever frozen. Measured before the fix: 1,003 where
    /// `CAP_BLOCKS` is 2.
    ///
    /// **v1.6.15 removed the coordinate rather than aligning it**, and v1.6.16
    /// removed the height too: the window is a COUNT of the distinct blocks the
    /// pool has SERVED a trade in, for both kinds of pool, through one site. A
    /// frozen block serves no trade, so frozen history cannot be in it at all.
    /// This test pins that, and it is what GAP 2 becomes.
    function test_aGatedPoolsWindowCountsOnlyTheBlocksItServed() public {
        _launch(10e18);
        PoolId feastId = _idOf(feastKey);
        assertEq(hook.servedBlocks(feastId), 0, "the platform pool has served no block until its first served swap");

        // A freeze BEFORE the platform pool ever trades. By the time the cap is
        // armed it is simply history.
        vm.prank(multisig);
        guardian.freeze();
        vm.roll(vm.getBlockNumber() + 1_000);
        _advance(1 hours);
        vm.prank(multisig);
        guardian.unfreeze();

        // The first served public swap arms the cap, here and nowhere else.
        _buy(feastKey, address(wbnb), 0.001e18, taker, address(0));
        assertEq(
            uint256(hook.servedBlocks(feastId)),
            1,
            "a freeze that ended before this pool opened lengthened its opening cap"
        );

        // What that is worth to someone: once the pool has SERVED its opening
        // blocks the cap is over and an ordinary buyer may take an ordinary
        // position. A thousand blocks of frozen history used to say otherwise,
        // with `PurchaseCapExceeded`. v1.6.16: mined blocks do not count, so the
        // window is served out rather than rolled past.
        for (uint256 i = 0; i < FeastConstants.CAP_BLOCKS; i++) {
            vm.roll(vm.getBlockNumber() + 1);
            _buy(feastKey, address(wbnb), 0.001e18, taker, address(0));
        }
        assertFalse(hook.capBinds(feastId), "the platform pool has served its opening blocks");
        vm.roll(vm.getBlockNumber() + 1);
        _buy(feastKey, address(wbnb), 1e18, address(0xB0B), address(0));
    }

    /// GAP 3 — `P16-claude` HIGH, `P6-claude` HIGH; the mirror direction in
    /// `P16-claude` LOW, `P16b` MEDIUM and `HK11b` MEDIUM.
    ///
    /// `frozenBlocks()` did not count blocks, it estimated them at
    /// `granted / SECONDS_PER_BLOCK` with `SECONDS_PER_BLOCK = 3`. Measured at
    /// BSC's real rate: 86,400 credited for 345,598 blocks actually frozen, and
    /// with `CAP_BLOCKS` at 2 that meant any freeze at all spent the whole
    /// window. The counter is deleted; the window is anchored on an event a
    /// freeze cannot spend instead.
    ///
    /// This test is the v1.6.13 question asked at four blocks a second — the
    /// rate that broke the estimate — and answered without one.
    function test_aFreezeDoesNotSpendAnUngatedPoolsCapWindow() public {
        // NOT through `_create`: the fixture rolls past the window after every
        // creation, which would end the window before the test starts.
        (address coin, PoolKey memory k) = factory.create(
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
        assertEq(hook.servedBlocks(id), 0, "an ungated pool has served no block until its first served swap either");

        // Seventy-two hours of brake at four blocks a second: what the chain
        // does, not what a constant assumed.
        vm.prank(multisig);
        guardian.freeze();
        uint256 frozenFor = 72 hours - 1;
        vm.roll(vm.getBlockNumber() + frozenFor * 4 / 3);
        clock += frozenFor;
        vm.warp(clock);
        vm.prank(multisig);
        guardian.unfreeze();

        // **The witness must reach its bound.** A cap nobody can exceed proves
        // nothing, so this buys MORE than the per-wallet cap and requires the
        // refusal. Three hundred and forty-five thousand blocks of freeze must
        // not have bought this wallet an uncapped opening.
        uint256 cap = hook.perWalletCap(id);
        assertGt(cap, 0, "the pool has a cap to exceed");
        // Funded FIRST: an external call between `vm.expectRevert` and the call
        // under test consumes the cheatcode, and the test then passes on the
        // wrong revert or on none.
        wbnb.mint(address(router), (cap + 1e18) * 2);
        _expectCapRefusal();
        _buyExactCoin(k, coin, address(0xB0B), cap + 1e18);
    }

    /// The pre-buy must not arm the window either. It is the creation of the
    /// position, not a public trade, and letting it arm would put the window
    /// back at the creation block — which is what GAP 3 removes.
    function test_aPrebuyDoesNotArmTheOpeningCap() public {
        wbnb.mint(creator, 10e18);
        vm.prank(creator);
        wbnb.approve(address(factory), 10e18);
        vm.prank(creator);
        (, PoolKey memory k) = factory.create(
            FeastFactory.CreateParams({
                name: "Pre", symbol: "PRE", supply: 1_000_000_000e18, quote: address(wbnb),
                creator: creator, selfBurnBps: 2_000, referrerBps: 1_000,
                prebuyQuoteIn: 1e18, minCoinsOut: 0, vestingDuration: 7 days,
                sqrtPriceX96: SQRT_PRICE_1_1, startTick: 0,
                liquidity: uint128(1_000_000_000e18 * 999 / 1_000),
                salt: bytes32(uint256(0xCA8)), metadataHash: bytes32(0)
            })
        );
        assertEq(hook.servedBlocks(_idOf(k)), 0, "the creator's pre-buy counted as a served block");
    }

    /// The venue wraps anything a hook reverts with; unwrapping keeps the
    /// assertion specific to the cap.
    function _expectCapRefusal() internal {
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IFeastCLHooks.afterSwap.selector,
                abi.encodeWithSelector(FeastHook.PurchaseCapExceeded.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
    }

    /// @dev The caller funds the router first — see the note at the call site.
    function _buyExactCoin(PoolKey memory k, address coin, address who, uint256 coinOut) internal {
        bool zeroForOne = Currency.unwrap(k.currency0) != coin;
        vm.prank(who, who);
        router.swap(
            k.up(),
            ICLPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: int256(coinOut),
                sqrtPriceLimitX96: zeroForOne ? MIN_SQRT : MAX_SQRT
            }),
            ""
        );
    }

    function _take(uint256 amountOut) internal {
        uint256 price = sink.priceQ128(address(stock));
        uint256 cost = (amountOut * price + (1 << 128) - 1) / (1 << 128);
        if (cost == 0) cost = 1;
        deal(feast, taker, cost);
        vm.prank(taker);
        IERC20(feast).approve(address(sink), cost);
        vm.prank(taker);
        sink.take(address(stock), amountOut, cost);
    }

    function _idOf(PoolKey memory k) internal pure returns (PoolId) {
        return PoolId.wrap(keccak256(abi.encode(k)));
    }
}
