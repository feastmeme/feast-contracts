// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FeastConstants} from "../../../src/FeastConstants.sol";
import {FeastPricer} from "../../../src/FeastPricer.sol";
import {RingV3Pool} from "../../utils/RingV3Pool.sol";
import {UnitFixture} from "../../utils/UnitFixture.sol";

/// **`window-shortening` / `shortened-window`** — r2 (v1.6.26, `57eadbc`). `U6` (Codex)
/// reports it MEDIUM at `src/FeastPricer.sol:261-268`; `U6-claude` (Claude) reports the same
/// defect LOW at `src/FeastPricer.sol:264`, and `U3` (Codex) LOW at `docs/interface.md:696-707`.
///
/// Q-3 (`baaa402`) requires a live ring of `MIN_RING_CARDINALITY` (601) before `_vouch` reads a
/// route pool, on the argument that a FULL ring of 601 spans a whole window. A ring that has just
/// GROWN to 601 is not full: its new slots are uninitialised, the oldest observation is slot 0,
/// and `_vouch` then takes `window = min(age, TWAP_WINDOW)` — an average over 300 to 599 seconds,
/// returned as `Ok`. `docs/audit/v1.6.25-changes.md` names this residual ("the first ten minutes
/// after a ring is widened"); `docs/interface.md:696-707` tells a lister that a ring this deep
/// covers the window. AstraSec L-2's shape, at the pricer.
///
/// Asserts that the pricer never vouches over less than the window; it FAILS on `57eadbc`.
contract PricerWarmupShortensTheWindowTest is UnitFixture {
    function _routeThrough(address pool) internal view returns (FeastPricer.Route[] memory routes) {
        routes = new FeastPricer.Route[](1);
        routes[0].quote = address(stock);
        routes[0].pools = new address[](1);
        routes[0].pools[0] = pool;
    }

    function test_aRingThatHasJustGrownIsNotVouchedForOverLessThanTheWindow() public {
        uint256 t0 = block.timestamp;
        RingV3Pool ring = new RingV3Pool(address(stock), address(wbnb), SQRT_PRICE_1_1, 0);
        ring.increaseObservationCardinalityNext(FeastConstants.MIN_RING_CARDINALITY);
        _advance(1);
        ring.poke(); // the write that reaches the end of the old ring of one: it grows to 601
        (,,, uint16 cardinality,,,) = ring.slot0();
        assertEq(cardinality, FeastConstants.MIN_RING_CARDINALITY, "precondition: the live ring is the minimum");

        FeastPricer p = new FeastPricer(address(wbnb), address(oracle), address(pm), feast, feastPoolId, _routeThrough(address(ring)));

        _warpTo(t0 + FeastConstants.MIN_OBSERVATION_AGE);
        uint32 age = ring.oldestAge();
        assertLt(age, FeastConstants.TWAP_WINDOW, "precondition: the ring's history is shorter than the window");
        (FeastPricer.Status s,) = p.priceQ128(address(stock));
        emit log_named_uint("history the pricer averaged over, seconds", age);
        assertEq(uint8(s), uint8(FeastPricer.Status.Unpriceable), "the pricer vouched for an average over less than the window");
    }
}
