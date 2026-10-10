// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {FeastConstants} from "../../../src/FeastConstants.sol";
import {FeastMath} from "../../../src/FeastMath.sol";

/// PoC for the round-r1 MEDIUM `slippage-bound` (`CA-7e39484115`), reported by the claude lens
/// (`r1a-claude`, the coverage unit) at `src/FeastHook.sol:801-809` and by no codex unit.
///
/// The claim: one tolerance is documented, and the button enforces twice it, because the same
/// basis-point figure is applied to a SQUARE-ROOT price in one place and to a price in the other.
///
/// `src/FeastConstants.sol:131-137` declares the pair, and declares them equal in as many words:
///
///     /// @notice Widest move from the time-weighted price a button will accept.
///     uint16 internal constant MAX_SLIPPAGE_BPS = 300;
///     /// @notice The same tolerance in the unit the check can actually use. Ticks
///     ///         are 1.0001 apart, so 300 of them is a shade under 3%.
///     int24 internal constant MAX_TICK_DEVIATION = 300;
///
/// `MAX_TICK_DEVIATION` is spent on a price: `_requireSpotNearAverage` at
/// `src/FeastHook.sol:1276-1281` compares ticks, and 300 ticks is 1.0001^300 = 3.045% in price.
/// `MAX_SLIPPAGE_BPS` is spent on the square root of one: `src/FeastHook.sol:801-809` builds the
/// swap's price limit as `sqrtPriceX96 * (BPS +/- MAX_SLIPPAGE_BPS) / BPS`. A ratio applied to a
/// square root is squared in the price it bounds, so 1.03 on the square root is 1.0609 on the
/// price — 6.09%, twice the tolerance the constant's own docstring names, and twice what the
/// tick check beside it admits.
///
/// This is a normative-claim defect at the MEDIUM bar: the documented guarantee an integrator
/// reads is not the guarantee the code enforces, and the two constants cannot both mean 3%. The
/// lens's wider point is that the two compose — the tick check already admits a spot 300 ticks
/// above the average, and the press may then walk the price 6.09% further — so a press that
/// reaches its own limit clears at about 6% below the time-weighted price rather than 3%. The
/// arithmetic below is the half that is settled by the constants alone and needs no pool: the
/// limit itself permits twice what it is documented to permit.
///
/// The claude lens also recorded WHY the dispositioned "buy-back bound" probe does not see this:
/// `test/audit/poc/BuybackBoundProbe.t.sol` has two fixtures and neither reaches the limit, so
/// both land inside 3% and the probe reports the bound as holding. A witness that cannot reach
/// the bound it is testing does not test it — the same lesson `docs/plan.md` section 6d records
/// against the v1.6.3 pass's own P19 witness, which was bounded away from the region where its
/// claim was weakest.
///
/// The converter carries the identical limit shape at `src/FeastConverter.sol:352-354`, but its
/// route floor bounds the outcome, so the assertion here is about the button, which has none.
contract BuybackSlippageBoundPoC is Test {
    uint256 internal constant Q96 = 1 << 96;

    /// **Edited by the v1.6.4 lane, and why.** As shipped at `88cbd30` this test
    /// re-implemented the hook's limit expression INLINE, as a copy. A witness
    /// that carries its own copy of the code under test cannot go green when the
    /// code is fixed, and would not have gone red had the hook been wrong in
    /// some other way — it was testing its own arithmetic. It now calls the
    /// derivation the hook and the converter both call. The assertion is
    /// unchanged; only the bookkeeping `assertEq` moves, from the defect's 608
    /// to the closure's 298, and it records both.
    function test_theButtonsPriceLimitPermitsNoMoreThanTheDocumentedTolerance() public pure {
        // The limit the hook computes, by calling what the hook calls, for a purchase of the coin
        // with the quote. The starting square-root price is 1.0 in Q96; nothing depends on that
        // choice, because the bound is a ratio.
        uint256 sqrtPriceX96 = Q96;
        uint256 limit = FeastMath.sqrtPriceLimit(
            uint160(sqrtPriceX96), FeastConstants.MAX_SLIPPAGE_BPS, FeastConstants.BPS, true
        );

        // The price that limit corresponds to, as a ratio to the starting price, in basis points.
        // Price is the square of the square-root price, so this squares the ratio.
        uint256 priceRatioBps = Math.mulDiv(limit * limit, FeastConstants.BPS, sqrtPriceX96 * sqrtPriceX96);
        uint256 moveBps = priceRatioBps - FeastConstants.BPS;

        // Recorded so the output carries the number. At `88cbd30` this was 608 basis points
        // against a documented 300 — the exact ratio 1.03^2 = 1.0609, less one basis point the
        // limit's own integer division truncated. With the limit derived from the tolerance in
        // price it is 298: `floor(sqrt(103_000_000)) = 10148` and `(10148/10000)^2 = 1.02982`.
        // The 2 basis points of slack are the floor rounding TOWARDS the current price, which is
        // the direction that cannot loosen the bound.
        assertEq(moveBps, 298, "the limit's implied price move, in basis points");

        // The documented tolerance, asserted. `MAX_SLIPPAGE_BPS` is declared as the "widest move
        // from the time-weighted price a button will accept", and its companion constant states
        // the same tolerance as 300 ticks, which is 3.045% in price. The limit permits 6.09%.
        assertLe(
            moveBps,
            FeastConstants.MAX_SLIPPAGE_BPS,
            "the button's price limit permits no more than the documented slippage tolerance"
        );
    }
}
