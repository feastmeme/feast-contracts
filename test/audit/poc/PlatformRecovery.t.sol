// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FeastConstants} from "../../../src/FeastConstants.sol";
import {PoolId, PoolIdLibrary} from "../../../src/venue/PoolId.sol";
import {PoolKey} from "../../../src/venue/PoolKey.sol";
import {UnitFixture} from "../../utils/UnitFixture.sol";

/// @notice v1.6 disposition of the v1 finding CA-b40f5b5225 (platform-recovery), task 444.
/// @dev On v1 the platform's 20% was banked as vault claims owned by an immutable hook with no
///      function that moved them, which contradicted the plan's "v1.1 spends exactly what v1
///      accumulated". v1.6 answers it with `FeastHook.releasePlatformFees`, which sends the
///      bucket to the sink the one-shot genesis call names. This test asserts the promise the
///      v1 PoC denied: the accrued platform share can leave. It PASSES on v1.6, which is what
///      closes the finding; it would fail on v1, where no such path exists.
contract PlatformRecoveryDisposition is UnitFixture {
    using PoolIdLibrary for PoolKey;

    function test_theAccumulatedPlatformShareCanLeaveToTheSink() public {
        (, PoolKey memory key) = _create(address(stock), bytes32(uint256(9)));
        PoolId id = key.toId();
        _buy(key, address(stock), 10_000e18, trader, address(0));

        uint256 accumulated = hook.platformPending(id);
        assertGt(accumulated, 0, "precondition: the platform share accrued");

        _genesis(); // binds the sink; before it, there is nowhere for the fees to go
        uint256 before_ = stock.balanceOf(address(sink));

        vm.prank(address(0x5712A));
        hook.releasePlatformFees(key);

        assertEq(stock.balanceOf(address(sink)) - before_, accumulated, "the sink received the whole bucket");
        assertEq(hook.platformPending(id), 0, "the bucket is empty afterwards");
    }

    /// The exit is bound by genesis: before it, the bucket still cannot move. Recorded so the
    /// disposition is not read as "the platform share can always leave".
    function test_beforeGenesisTheExitIsRefused() public {
        (, PoolKey memory key) = _create(address(stock), bytes32(uint256(11)));
        _buy(key, address(stock), 10_000e18, trader, address(0));
        vm.expectRevert();
        hook.releasePlatformFees(key);
    }
}
