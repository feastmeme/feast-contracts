// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {FeastConstants} from "../../../src/FeastConstants.sol";
import {FeastOracle} from "../../../src/FeastOracle.sol";
import {FeastPricer} from "../../../src/FeastPricer.sol";
import {PoolId} from "../../../src/venue/PoolId.sol";
import {UnitFixture} from "../../utils/UnitFixture.sol";

/// AstraSec L-2: `FeastOracle.consult` shortened the requested TWAP window to
/// the pool's own observation age, floored at `MIN_OBSERVATION_AGE = 300`
/// seconds (`src/FeastOracle.sol:126-127` at e5c0a77):
///
///     uint32 effective = window > age ? age : window;
///     if (effective < FeastConstants.MIN_OBSERVATION_AGE) effective = FeastConstants.MIN_OBSERVATION_AGE;
///
/// **Fixed in v1.6.24.** The window is clamped UP to the floor and then the
/// history must cover it, or `consult` reverts `OracleTooYoung(age, window)`.
/// The scenario the coordinator's PoC measured — 310 s of history answering a
/// 600 s request over 310 s — is kept below as the regression: it now refuses.
/// The test contract is the oracle's `writer`, which is the only way to put
/// observations in.
contract L2OracleShortensTheWindowToTheHistory is Test {
    FeastOracle internal oracle;
    PoolId internal id = PoolId.wrap(bytes32(uint256(1)));

    /// Absolute instants throughout. `via_ir` is on for this repo and the
    /// optimiser treats `TIMESTAMP` as constant within a call frame, so
    /// `vm.warp(block.timestamp + n)` twice in one test body warps to the same
    /// place twice. Measured here before it silently weakened an assertion.
    uint256 internal constant T0 = 1_000_000;

    function setUp() public {
        vm.warp(T0);
        oracle = new FeastOracle(address(this));
    }

    /// Two prices, each held for 305 seconds: tick 0 then tick 1000. A pool
    /// with 610 seconds of history answers `twapTick` (window 600) over the
    /// real 600 seconds and averages the two. The control for the next test.
    function test_withEnoughHistoryTheFullWindowIsUsed() public {
        oracle.write(id, 0);
        vm.warp(T0 + 305);
        oracle.write(id, 1_000);
        vm.warp(T0 + 610);
        assertEq(oracle.historySeconds(id), 610, "610s of history, past the 600s window");
        int24 twap = oracle.twapTick(id);
        emit log_named_int("twap over the full 600s window", twap);
        // The window [T0+10, T0+610] holds tick 0 for 295s and tick 1000 for 305s.
        assertApproxEqAbs(int256(twap), 508, 2, "both prices, weighted by the real 600s");
    }

    /// **The finding, as a regression.** The same pool with only 310 seconds of
    /// history used to answer the SAME `twapTick(600)` call over 310 seconds —
    /// tick 983, entirely the second price, with nothing in the bare `int24`
    /// to say the window had been halved. It refuses now, and the refusal
    /// carries both numbers. A caller who wants the 310 seconds that exist asks
    /// for them by length and gets exactly that, which is no longer a surprise.
    function test_aYoungPoolRefusesTheWindowItCannotCover() public {
        oracle.write(id, 0);
        vm.warp(T0 + 5);
        oracle.write(id, 1_000);
        vm.warp(T0 + 310);

        uint32 age = oracle.historySeconds(id);
        assertEq(age, 310, "only 310s of history");
        assertLt(age, FeastConstants.TWAP_WINDOW, "less than the window asked for");
        assertGe(age, FeastConstants.MIN_OBSERVATION_AGE, "and past the floor, where it used to answer");

        vm.expectRevert(abi.encodeWithSelector(FeastOracle.OracleTooYoung.selector, age, FeastConstants.TWAP_WINDOW));
        oracle.twapTick(id);

        // 5s at tick 0 then 305s at tick 1000, over the 310s that were ASKED for.
        assertApproxEqAbs(int256(oracle.consult(id, age)), 983, 10, "the short window, only when asked for by name");
    }

    /// The bound itself, from both sides: one second short of a whole window
    /// refuses, and a whole window answers. A witness at 310 s would pass
    /// against a refusal placed anywhere between 311 and 600.
    function test_theRefusalSitsExactlyAtTheRequestedWindow() public {
        oracle.write(id, 7);
        vm.warp(T0 + FeastConstants.TWAP_WINDOW - 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                FeastOracle.OracleTooYoung.selector, FeastConstants.TWAP_WINDOW - 1, FeastConstants.TWAP_WINDOW
            )
        );
        oracle.twapTick(id);

        vm.warp(T0 + FeastConstants.TWAP_WINDOW);
        assertEq(oracle.twapTick(id), 7, "a whole window of history is answered");
    }

    /// The floor is real: a one-second window is clamped UP to 300, so the
    /// caller cannot ask for a spot reading dressed as an average. This is the
    /// half of the behaviour that was always a mitigation, and it is unchanged.
    function test_theFloorHoldsAgainstADeliberatelyTinyWindow() public {
        oracle.write(id, 0);
        vm.warp(T0 + 600);
        oracle.write(id, 1_000);
        vm.warp(T0 + 610);
        assertEq(oracle.consult(id, 1), oracle.consult(id, FeastConstants.MIN_OBSERVATION_AGE), "clamped up to 300s");
    }

    /// Below the floor it refuses rather than degrading, which is the
    /// difference from the reference implementation its header cites. The
    /// refusal now names the window that was actually asked for.
    function test_belowTheFloorItRefuses() public {
        oracle.write(id, 0);
        vm.warp(T0 + 299);
        vm.expectRevert(
            abi.encodeWithSelector(FeastOracle.OracleTooYoung.selector, uint32(299), FeastConstants.TWAP_WINDOW)
        );
        oracle.twapTick(id);
        vm.expectRevert(
            abi.encodeWithSelector(
                FeastOracle.OracleTooYoung.selector, uint32(299), FeastConstants.MIN_OBSERVATION_AGE
            )
        );
        oracle.consult(id, 1);
    }
}

/// Every caller of `twapTick` has to handle the new refusal. The internal fill
/// asks with `try`; the buy-back button refuses the press. `FeastPricer` is the
/// one that promises never to revert on a price it cannot vouch for, and it
/// guarded with `historySeconds < MIN_OBSERVATION_AGE` — the oracle's OLD
/// refusal point. Left there, the platform pool's sixth to tenth minutes of
/// history would revert out of the pricer, and `FeastEmissions.settle` with it.
contract L2PricerSaysUnpriceableRatherThanReverting is UnitFixture {
    function test_theWindowsMissingMinutesAreUnpriceableNotARevert() public {
        _launch(10e18);
        uint256 traded = clock;
        _buy(feastKey, address(wbnb), 1e15, address(0xF1257), address(0));

        // Past the old floor, short of a whole window.
        _warpTo(traded + FeastConstants.MIN_OBSERVATION_AGE + 100);
        assertLt(oracle.historySeconds(feastPoolId), FeastConstants.TWAP_WINDOW, "short of a whole window");
        (FeastPricer.Status status, uint256 price) = pricer.platformPerNativeQ128();
        assertEq(uint256(status), uint256(FeastPricer.Status.Unpriceable), "said, not reverted");
        assertEq(price, 0, "and no number");

        _warpTo(traded + FeastConstants.TWAP_WINDOW);
        (status, price) = pricer.platformPerNativeQ128();
        assertEq(uint256(status), uint256(FeastPricer.Status.Ok), "a whole window prices");
        assertGt(price, 0, "with a number");
    }
}
