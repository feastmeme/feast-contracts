// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {FeastConstants} from "../../src/FeastConstants.sol";

/// @dev A v3-shaped pool with a settable spot tick and a settable average, so
///      the converter's refusals can be exercised deterministically. The real
///      pools are exercised on the fork; moving a real pool's price far enough
///      to trip the deviation bound would mean crossing hundreds of initialised
///      ticks, which is thousands of archive reads and proves nothing a mock
///      cannot prove exactly.
contract MockV3Pool {
    address public token0;
    address public token1;
    uint160 public sqrtPriceX96 = 79_228_162_514_264_337_593_543_950_336;
    int24 public spotTick;
    uint16 public observationIndex;
    /// @dev Reported as both the live ring and the ring asked for. The
    ///      default is the least a priced quote's pool may keep (v1.6.25,
    ///      AstraSec Q-3), so a fixture that lists a quote through this pool
    ///      lists a compliant one, exactly at the bound. It was 100, which the
    ///      pricer now refuses to list.
    uint16 public observationCardinality = FeastConstants.MIN_RING_CARDINALITY;
    uint32 public oldestTimestamp;
    /// @dev The average this pool will report over any window.
    int24 public averageTick;

    /// @dev Recorded so a test can assert the converter bounded its own impact.
    uint160 public lastSwapPriceLimit;
    bool public lastSwapZeroForOne;
    /// @notice Output as a fraction of what this pool's own price implies, in
    ///         basis points. 10_000 is an execution exactly at the quoted
    ///         price; lower values are the shortfall a route bound must catch.
    uint256 public outputBps = 10_000;
    /// @notice Fraction of the offered input this pool will actually take, in
    ///         basis points — a stand-in for a price limit stopping a hop early.
    uint256 public inputBps = 10_000;

    constructor(address token0_, address token1_) {
        (token0, token1) = token0_ < token1_ ? (token0_, token1_) : (token1_, token0_);
        oldestTimestamp = uint32(block.timestamp);
    }

    function setTicks(int24 spot, int24 average) external {
        spotTick = spot;
        averageTick = average;
    }

    function setSqrtPrice(uint160 p) external {
        sqrtPriceX96 = p;
    }

    function setCardinality(uint16 c) external {
        observationCardinality = c;
    }

    function setOldestTimestamp(uint32 t) external {
        oldestTimestamp = t;
    }

    function setOutputBps(uint256 bps) external {
        outputBps = bps;
    }

    function setInputBps(uint256 bps) external {
        inputBps = bps;
    }

    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint32, bool) {
        return (sqrtPriceX96, spotTick, observationIndex, observationCardinality, observationCardinality, 0, true);
    }

    function observations(uint256) external view returns (uint32, int56, uint160, bool) {
        return (oldestTimestamp, 0, 0, true);
    }

    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory)
    {
        tickCumulatives = new int56[](2);
        // A constant average over the window: cumulative[1] - cumulative[0]
        // divided by the window is exactly `averageTick`.
        tickCumulatives[0] = 0;
        tickCumulatives[1] = int56(averageTick) * int56(uint56(secondsAgos[0]));
        return (tickCumulatives, new uint160[](2));
    }

    function liquidity() external pure returns (uint128) {
        return 1e24;
    }

    function swap(address recipient, bool zeroForOne, int256 amountSpecified, uint160 limit, bytes calldata data)
        external
        returns (int256 amount0, int256 amount1)
    {
        lastSwapPriceLimit = limit;
        lastSwapZeroForOne = zeroForOne;
        // Price-consistent by default, so a route bound sees what a real pool
        // would give it; `outputBps` is the dial a test uses to underpay.
        uint256 offered = uint256(amountSpecified > 0 ? amountSpecified : -amountSpecified);
        uint256 raw = offered * inputBps / 10_000;
        uint256 priced = Math.mulDiv(Math.mulDiv(raw, sqrtPriceX96, 2 ** 96), sqrtPriceX96, 2 ** 96);
        if (!zeroForOne) priced = Math.mulDiv(Math.mulDiv(raw, 2 ** 96, sqrtPriceX96), 2 ** 96, sqrtPriceX96);
        int256 out = int256(priced * outputBps / 10_000);
        address tokenOut = zeroForOne ? token1 : token0;
        IERC20(tokenOut).transfer(recipient, uint256(out));
        int256 consumed = int256(raw);
        (amount0, amount1) = zeroForOne ? (consumed, -out) : (-out, consumed);

        // THE POOL'S OWN CHECK, which a real v3 pool makes and this mock did
        // not: the callback must actually deliver what the pool says it took.
        // Without it the mock reported a full fill for a payment it never
        // received, so no test here could see a token that takes a cut of the
        // converter's OUTBOUND transfer — the leg v1.6.3's round 1 found
        // unmeasured (r1v). A pool that does not check is a pool that cannot
        // refuse, and a harness that cannot refuse cannot witness a refusal.
        address tokenIn = zeroForOne ? token0 : token1;
        uint256 owedToPool = IERC20(tokenIn).balanceOf(address(this)) + raw;
        ISwapCallback(msg.sender).pancakeV3SwapCallback(amount0, amount1, data);
        if (IERC20(tokenIn).balanceOf(address(this)) < owedToPool) {
            revert NotPaidInFull(tokenIn, owedToPool, IERC20(tokenIn).balanceOf(address(this)));
        }
    }

    error NotPaidInFull(address token, uint256 expected, uint256 received);
}

interface ISwapCallback {
    function pancakeV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external;
}

contract MockV3Factory {
    mapping(bytes32 => address) internal _pools;

    function set(address a, address b, uint24 fee, address pool) external {
        _pools[_key(a, b, fee)] = pool;
    }

    function getPool(address a, address b, uint24 fee) external view returns (address) {
        return _pools[_key(a, b, fee)];
    }

    function _key(address a, address b, uint24 fee) internal pure returns (bytes32) {
        (address x, address y) = a < b ? (a, b) : (b, a);
        return keccak256(abi.encode(x, y, fee));
    }
}
