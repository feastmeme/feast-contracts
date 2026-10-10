// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {TickMath} from "uniswap-v4-core/src/libraries/TickMath.sol";

import {FeastConstants} from "../../../src/FeastConstants.sol";
import {FeastFactory} from "../../../src/FeastFactory.sol";
import {IFeastCLPoolManager} from "../../../src/venue/IFeastCLPoolManager.sol";
import {FeastGenesis} from "../../../src/FeastGenesis.sol";
import {FeastLaunchWindow} from "../../../src/FeastLaunchWindow.sol";
import {UnitFixture} from "../../utils/UnitFixture.sol";

/// PoC for the v1.6.11 round's `no-commit-seed-unrecoverable` cluster, reported by FIVE units
/// across BOTH families and never by a tool:
///
///   `HK09-claude`  LOW     `no-commit-seed-unsettleable-quote`  src/FeastHook.sol:1099-1101
///   `HK10-claude`  MEDIUM  `no-commit-seed-unrecoverable`       src/FeastLaunchWindow.sol:213-225
///   `HK14-claude`  MEDIUM  `unvalidated-no-commit-opening`      src/FeastFactory.sol:409
///   `HK20-claude`  MEDIUM  `opening-tick-unchecked`             src/FeastFactory.sol:409
///   `HK20`         MEDIUM  `deferred-tick-validation`           src/FeastFactory.sol:409
///
/// Before v1.6.11 genesis initialised and seeded the platform pool through the same path as
/// every creator launch, so a starting price that disagreed with the start tick was refused by
/// name — `SeedWouldNeedQuote` — inside the genesis transaction, while the ceremony was still
/// in the room. v1.6.11 moved the seeding to settlement and left the pair RECORDED instead:
///
///     // src/FeastFactory.sol:409
///     _platformOpening = Opening({sqrtPriceX96: g.sqrtPriceX96, startTick: g.startTick, liquidity: g.liquidity});
///
/// Nothing checks that the three agree, and the record has no setter. It is consumed exactly
/// once, on the NO-COMMIT branch of `settle()`, twenty-five hours later. If the recorded price
/// sits above the recorded tick the ask range is in range, the venue books a wrapped-native
/// debt against a hook that holds none, and the settlement reverts inside `_pay`.
///
/// The outcome is permanent and has no owner: after the grace hour `settle` can never be
/// called, nothing was committed so nothing is refundable, `claim` needs a settled window, and
/// nobody but the factory or the window may initialise the pool. Sixty per cent of the platform
/// supply sits in the window with no exit.
///
/// **FIXED in v1.6.12 by removing the parameters.** See the tests below.
///
/// **What made it reachable.** Two conditions must coincide: the genesis key signs a price and
/// a tick that disagree — the deploy script takes the price as a runtime argument and the tick
/// from a compiled constant, with no consistency check between them — and nobody commits. The
/// first is a deployer error made once, in a blind-signed ceremony, with nothing between it and
/// the mistake; the second is a market outcome. The v1.6.10 round's own P8/P12 fixes exist to
/// delete exactly this shape: a number a human types into a ceremony and nothing checks.
contract NoCommitOpeningUnsettleablePoC is UnitFixture {
    /// The control: the recipe's own pair — price 1:1 at tick 0 — settles with no commits, so
    /// the no-commit path works and what follows is about the pair, not the path.
    function test_theRecipesOwnOpeningSettlesWithNoCommits() public {
        _genesis();
        _warpTo(window.endsAt());
        window.settle();
        assertTrue(window.settled(), "the recipe's opening settles");
    }

    /// **FIXED, and the shape is gone rather than guarded.** Owner ruling
    /// 2026-09-20 12:3x: genesis signs the PRICE and nothing else. `GenesisParams`
    /// has no `startTick` and no `liquidity`; the tick is floored from the price
    /// inside `genesis` with the same align-DOWN rule the auction uses, the pool
    /// opens AT that tick rather than at the raw price — so the coin-only range
    /// starts exactly where the price is and cannot straddle it — and the
    /// liquidity comes from the coin actually held at settlement.
    ///
    /// There is no longer a tick to disagree with, so this test cannot be the
    /// one it was. It pins the property instead: whatever price the genesis key
    /// signs, the no-commit settlement goes through, and the tick it opens at is
    /// the floor of that price.
    function test_anyPriceGenesisSignsSettlesOnTheNoCommitPath() public {
        _warpTo(windowStart - 1 days);
        // v1.6.21: genesis asks a coded sink whether it is armed, so the
        // arming comes first. See `FeastFactory.genesis`.
        vm.prank(genesisKey);
        sink.schedule(address(window));
        FeastFactory.GenesisParams memory p = _genesisParams();
        // The price the old parameter set could not express safely: two units of
        // quote per coin, against a start tick of zero that nobody types now.
        p.sqrtPriceX96 = uint160(uint256(SQRT_PRICE_1_1) * 2);
        vm.prank(genesisKey);
        factory.genesis(p);

        int24 startTick = factory.platformOpening();
        int24 spacing = FeastConstants.POOL_TICK_SPACING;
        assertEq(startTick % spacing, 0, "the opening tick is usable");
        assertLe(
            TickMath.getSqrtPriceAtTick(startTick),
            p.sqrtPriceX96,
            "and it is at or below the price the genesis key signed"
        );
        assertGt(
            TickMath.getSqrtPriceAtTick(startTick + spacing),
            p.sqrtPriceX96,
            "by less than one spacing, so it is the floor and not merely below"
        );

        _warpTo(window.endsAt());
        window.settle();
        assertTrue(window.settled(), "the settlement the old parameter set could not survive");

        (uint160 opened,,,) = IFeastCLPoolManager(address(pm)).getSlot0(feastPoolId);
        assertEq(opened, TickMath.getSqrtPriceAtTick(startTick), "the pool opened AT the tick, not at the raw price");
        assertApproxEqRel(
            IERC20(feast).balanceOf(address(vault)),
            SUPPLY * FeastGenesis.POOL_BPS / FeastGenesis.BPS,
            1e12,
            "with the whole holding in it"
        );
    }

    /// Fuzzed over the WHOLE price domain, because the claim is about every
    /// price the key can type and not about the two this file happens to name.
    ///
    /// The property is not "every price settles" — an extreme price makes the
    /// one-sided range too thin to hold 60% of the supply, and that one is
    /// refused. The property is that **the refusal is always in the genesis
    /// transaction**: whatever genesis accepts, the no-commit settlement goes
    /// through; whatever it cannot serve, it says so while the ceremony is still
    /// in the room. There is no price that is accepted and then unsettleable,
    /// which is exactly the shape this PoC was written for.
    function testFuzz_everyPriceGenesisAcceptsSettles(uint160 sqrtPriceX96) public {
        sqrtPriceX96 = uint160(
            bound(uint256(sqrtPriceX96), uint256(TickMath.MIN_SQRT_PRICE), uint256(TickMath.MAX_SQRT_PRICE) - 1)
        );
        _warpTo(windowStart - 1 days);
        // v1.6.21: genesis asks a coded sink whether it is armed, so the
        // arming comes first. See `FeastFactory.genesis`.
        vm.prank(genesisKey);
        sink.schedule(address(window));
        FeastFactory.GenesisParams memory p = _genesisParams();
        p.sqrtPriceX96 = sqrtPriceX96;

        vm.prank(genesisKey);
        try factory.genesis(p) {
            _warpTo(window.endsAt());
            window.settle();
            assertTrue(window.settled(), "a price genesis accepted always settles");
            assertEq(IERC20(feast).balanceOf(address(window)), 0, "and nothing is left in the window");
        } catch (bytes memory reason) {
            // Three named refusals live at the extremes and all three are
            // reached inside the genesis transaction: `OpeningPriceOutOfRange`
            // (the tick has no room for the range), the window's
            // `LiquidityOverflow` (the range is too thin to hold the holding),
            // and the venue's own `SafeCastOverflow` beyond even that. What the
            // property forbids is a PANIC — an unnamed arithmetic failure tells
            // a signer nothing — and, above all, a genesis that returns.
            assertTrue(bytes4(reason) != bytes4(0x4e487b71), "refused by name, never by panic");
            assertTrue(reason.length >= 4, "and with something to read");
            assertEq(factory.platformCoin(), address(0), "and it recorded nothing");
        }
    }

    /// A price outside the usable range is refused by name, in the genesis
    /// transaction, while the ceremony is still in the room.
    function test_aPriceOutsideTheUsableRangeIsRefusedAtGenesis() public {
        _warpTo(windowStart - 1 days);
        // v1.6.21: genesis asks a coded sink whether it is armed, so the
        // arming comes first. See `FeastFactory.genesis`.
        vm.prank(genesisKey);
        sink.schedule(address(window));
        FeastFactory.GenesisParams memory p = _genesisParams();
        p.sqrtPriceX96 = uint160(TickMath.MIN_SQRT_PRICE);
        vm.prank(genesisKey);
        vm.expectRevert(
            abi.encodeWithSelector(FeastFactory.OpeningPriceOutOfRange.selector, uint160(TickMath.MIN_SQRT_PRICE))
        );
        factory.genesis(p);
    }
}
