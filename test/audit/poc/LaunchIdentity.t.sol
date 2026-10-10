// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FeastConstants} from "../../../src/FeastConstants.sol";
import {FeastFactory} from "../../../src/FeastFactory.sol";
import {UnitFixture} from "../../utils/UnitFixture.sol";

/// @notice B8, declared — the v1.6 re-run of the v1 finding CA-dca1852769 (launch-identity), which
///         the first dual-family pack raised again as `CA-065c50b469`.
///
/// @dev **This is a boundary, not a defect.** `predictCoin` commits to the four fields that enter
///      the coin's creation code — salt, name, symbol, supply — and to nothing else, so whoever
///      submits those four first takes that address with economics of their own. What is lost is
///      the prediction and nothing else: the intended launch is never blocked, a taken salt is
///      refused rather than overwritten, and the creator relaunches at another salt with their own
///      economics. Only an app that shows or commits value to a predicted address before its own
///      `create()` is mined is exposed, and `docs/interface.md` now says not to.
///
///      Declared at `docs/plan.md` §B8 (2026-09-12, v1.6.1), where the salt-level hardening is
///      recorded as considered and declined, with the reasoning, for the auditor to rank. The
///      primary witnesses are `test/FeastDeclaredBoundaries.t.sol:FeastLaunchIdentityBoundaryTest`.
contract LaunchIdentityPoC is UnitFixture {
    address internal constant INTENDED_CREATOR = address(0xC0FFEE01);
    address internal constant OTHER = address(0xBEEF);

    function _params(address who, bytes32 salt) internal view returns (FeastFactory.CreateParams memory) {
        return FeastFactory.CreateParams({
            name: "Coin",
            symbol: "COIN",
            supply: 1_000_000_000e18,
            quote: address(stock),
            creator: who,
            selfBurnBps: 2_000,
            referrerBps: 1_000,
            prebuyQuoteIn: 0,
            minCoinsOut: 0,
            vestingDuration: 0,
            sqrtPriceX96: SQRT_PRICE_1_1,
            startTick: 0,
            liquidity: uint128(1_000_000_000e18 * 999 / 1_000),
            salt: salt,
            metadataHash: bytes32(0)
        });
    }

    function test_B8_aPredictedAddressIsNotAReservation() public {
        bytes32 salt = bytes32(uint256(42));
        FeastFactory.CreateParams memory intended = _params(INTENDED_CREATOR, salt);
        address predicted = factory.predictCoin(intended.salt, intended.name, intended.symbol, intended.supply);

        // Another caller submits the same four committed fields first, naming itself creator.
        vm.prank(OTHER);
        (address taken,) = factory.create(_params(OTHER, salt));
        assertEq(taken, predicted, "the prediction commits to those four fields and no more");
        assertEq(factory.getCoin(predicted).creator, OTHER, "so the address carries the other economics");

        // What B8 says is lost is the prediction, and only that: the intended launch still
        // happens, with its own economics, at the address its own salt predicts.
        vm.roll(vm.getBlockNumber() + FeastConstants.CAP_BLOCKS);
        FeastFactory.CreateParams memory again = _params(INTENDED_CREATOR, bytes32(uint256(43)));
        address predictedAgain = factory.predictCoin(again.salt, again.name, again.symbol, again.supply);
        vm.prank(INTENDED_CREATOR);
        (address mine,) = factory.create(again);
        assertEq(mine, predictedAgain, "at the address its own salt predicts");
        assertEq(factory.getCoin(mine).creator, INTENDED_CREATOR, "with the intended economics");
        assertTrue(mine != predicted, "a different address: the prediction was the only casualty");
    }
}
