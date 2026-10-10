// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {FeastFactory} from "../../../src/FeastFactory.sol";
import {MockERC20} from "../../utils/MockERC20.sol";
import {UnitFixture} from "../../utils/UnitFixture.sol";

/// PoC for the v1.6.11 round's HIGH `prebuy-signed-wrap` / `prebuy-swap-mode-wrap` /
/// `prebuy-specified-sign-flip`, reported INDEPENDENTLY by three Codex units — `HK14`, `HK16b`
/// and `HK17` — all at `src/FeastFactory.sol:598`:
///
///     amountSpecified: -int256(quoteIn)
///
/// `quoteIn` is a `uint256` taken straight from the caller's parameters. Above `2^255` the cast
/// is negative and the negation is POSITIVE, which the venue reads as an exact-OUTPUT swap: the
/// factory asks the pool for that many coins instead of spending that much quote.
///
/// **RETRACTED 2026-09-21.** The paragraph below is wrong. `P6b` of the v1.6.12
/// round found the value both guards miss — `type(uint256).max`, where
/// `int256(...)` is `-1` and negating it is `1` — and the last test in this file
/// is that case. The two values tested below are the EDGES of the gap; nothing
/// tested the inside of it. Left as written because the mistake is the lesson.
///
/// **MEASURED, AND IT DOES NOT REPRODUCE.** Three units of one family agreed on this and all
/// three were wrong about the outcome. The cast is unchecked, but nothing downstream lets the
/// reinterpretation happen:
///
///   * at exactly `2^255`, `int256(quoteIn)` is `type(int256).min` and the NEGATION panics
///     under 0.8's checked arithmetic — `Panic(0x11)`;
///   * one above it the negation is an ordinary positive number, and the venue's own `SafeCast`
///     refuses it — `SafeCastOverflow()`, `lib/infinity-core`.
///
/// Either way the whole transaction reverts, so the `safeTransferFrom` at
/// `src/FeastFactory.sol:562` is rolled back with it and the caller's quote never moves. There
/// is no state in which an oversized pre-buy has been reinterpreted and a balance is stranded.
///
/// The test is kept, passing, as the pin on that: if a future change ever put a value between
/// the language's check and the venue's — a wider `amountSpecified`, or an early transfer that
/// is not rolled back — this is where it would show. Reaching the cast at all needs a quote
/// token of the caller's own making with a supply above `2^255`, and the funds at risk would be
/// the caller's own.
contract PrebuySignedCastPoC is UnitFixture {
    address internal whale = address(0x3A1E);

    function test_anOversizedPrebuyIsRefusedRatherThanReinterpreted() public {
        MockERC20 big = new MockERC20("Big", "BIG", 18);
        // `2^255` itself is `type(int256).min`, whose NEGATION panics under 0.8's checked
        // arithmetic — so that one value is caught by the language. One above it is not:
        // `int256(2^255 + 1)` is negative and ordinary, and negating it gives a POSITIVE
        // `amountSpecified`, which the venue reads as exact output.
        uint256 huge = (uint256(1) << 255) + 1;
        big.mint(whale, huge);
        vm.prank(whale);
        IERC20(address(big)).approve(address(factory), huge);

        uint256 before = big.balanceOf(whale);

        vm.prank(whale);
        try factory.create(
            FeastFactory.CreateParams({
                name: "Coin",
                symbol: "COIN",
                supply: 1_000_000_000e18,
                quote: address(big),
                creator: whale,
                selfBurnBps: 2_000,
                referrerBps: 1_000,
                prebuyQuoteIn: huge,
                minCoinsOut: 0,
                // v1.6.24 I-5: at zero this is refused by the vesting floor
                // before the cast is ever reached, which would leave the test
                // passing for the wrong reason.
                vestingDuration: 7 days,
                sqrtPriceX96: SQRT_PRICE_1_1,
                startTick: 0,
                liquidity: uint128(1_000_000_000e18 * 999 / 1_000),
                salt: bytes32(uint256(7)),
                metadataHash: bytes32(0)
            })
        ) {
            // It did not revert. Then the cast was reinterpreted and the quote moved.
            emit log_named_uint("whale quote after", big.balanceOf(whale));
            emit log_named_uint("factory quote after", big.balanceOf(address(factory)));
            assertEq(
                big.balanceOf(whale),
                before,
                "an oversized pre-buy was reinterpreted as exact-output and the quote did not come back"
            );
        } catch (bytes memory reason) {
            emit log_named_bytes("refused with", reason);
            assertEq(big.balanceOf(whale), before, "a refusal must leave the caller's quote where it was");
        }
    }

    /// **The value both guards miss, and the one this file got wrong.**
    ///
    /// `int256(type(uint256).max)` is `-1`. Negating `-1` is `1` — an ordinary
    /// positive number, which the venue reads as an exact-OUTPUT swap for a
    /// SINGLE unit of the coin. The language's checked negation only panics at
    /// exactly `type(int256).min`; the venue's `SafeCast` only refuses values
    /// above it. Between them sits a gap the width of the whole top half of the
    /// range, and the test above tested the two edges of that gap rather than
    /// the inside of it.
    ///
    /// Reported by `P6b` in the v1.6.12 round, four weeks after this file
    /// concluded the opposite.
    function test_aMaxUint256PrebuyIsRefusedAndTheQuoteComesBack() public {
        MockERC20 big = new MockERC20("Big", "BIG", 18);
        uint256 huge = type(uint256).max;
        big.mint(whale, huge);
        vm.prank(whale);
        IERC20(address(big)).approve(address(factory), huge);
        uint256 before = big.balanceOf(whale);

        vm.prank(whale);
        vm.expectRevert();
        factory.create(
            FeastFactory.CreateParams({
                name: "Coin",
                symbol: "COIN",
                supply: 1_000_000_000e18,
                quote: address(big),
                creator: whale,
                selfBurnBps: 2_000,
                referrerBps: 1_000,
                prebuyQuoteIn: huge,
                minCoinsOut: 0,
                // v1.6.24 I-5: at zero this is refused by the vesting floor
                // before the cast is ever reached, which would leave the test
                // passing for the wrong reason.
                vestingDuration: 7 days,
                sqrtPriceX96: SQRT_PRICE_1_1,
                startTick: 0,
                liquidity: uint128(1_000_000_000e18 * 999 / 1_000),
                salt: bytes32(uint256(8)),
                metadataHash: bytes32(0)
            })
        );

        assertEq(big.balanceOf(whale), before, "the whole quote is still the creator's");
        assertEq(big.balanceOf(address(factory)), 0, "and none of it stranded in the factory");
    }
}
