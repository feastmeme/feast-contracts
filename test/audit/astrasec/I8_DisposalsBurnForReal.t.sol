// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";

import {FeastConstants} from "../../../src/FeastConstants.sol";
import {Currency} from "../../../src/venue/Currency.sol";
import {PoolId} from "../../../src/venue/PoolId.sol";
import {PoolKey} from "../../../src/venue/PoolKey.sol";
import {UnitFixture} from "../../utils/UnitFixture.sol";
import {VenueBridge} from "../../utils/VenueBridge.sol";

/// AstraSec I-8: two disposal styles. Every burn in `src/` called the coin's
/// own `burn` except two in `FeastHook`, which SENT the coin to
/// `BURN_ADDRESS` (0x…dEaD): the seed's unplaced remainder (`burnUnusedSeed`,
/// reached from both of the factory's seeding paths) and the coin side of the
/// locked position's fees (`collectLpFees`). A transfer leaves `totalSupply`
/// where it was, so an explorer counted those coins as held.
///
/// Fixed in v1.6.24: both are real burns. Every coin either path disposes of
/// is one the factory deployed — a `FeastToken` or the platform coin, both
/// `ERC20Burnable` — so there is no coin for which the burn is unavailable.
/// Each test asserts the supply falls by exactly what was disposed of and that
/// the dead address receives nothing.
contract I8DisposalsBurnForReal is UnitFixture {
    using VenueBridge for PoolKey;

    /// A creator launch places 99.9% of its supply; the factory hands the
    /// remainder to `burnUnusedSeed`.
    function test_aCreatorSeedsRemainderIsBurned() public {
        (address coin,) = _create(address(stock), bytes32(uint256(0x18A)));
        uint256 supply = 1_000_000_000e18;
        uint256 burned = supply - IERC20(coin).totalSupply();
        assertGt(burned, 0, "the position did not take everything, and the rest is gone from the supply");
        assertEq(IERC20(coin).balanceOf(FeastConstants.BURN_ADDRESS), 0, "and none of it is parked at 0xdEaD");
    }

    /// The platform pool's auction seed leaves a few thousand wei unplaced,
    /// which the window's factory path burns the same way.
    function test_thePlatformSeedsRemainderIsBurned() public {
        _launch(10e18);
        assertLt(IERC20(feast).totalSupply(), SUPPLY, "the auction seed's remainder left the supply");
        assertEq(IERC20(feast).balanceOf(FeastConstants.BURN_ADDRESS), 0, "and none of it is parked at 0xdEaD");
    }

    /// The locked position's coin-side fees are owed to `burnFilledCoin`, which
    /// burns them: the supply falls by exactly what was collected.
    function test_theLpFeesCoinSideIsBurnedForReal() public {
        _launch(10e18);
        // Buy the platform coin, then sell it back: the sale pays the pool's
        // LP fee in the coin. One block, so the oracle is far too young for
        // the internal fill to take any of it — the whole sale meets the pool.
        // A tenth of a BNB stays under the opening blocks' 0.5% per-wallet cap.
        _buy(feastKey, address(wbnb), 1e17, address(0xF1257), address(0));
        uint256 held = IERC20(feast).balanceOf(address(router));
        bool coinIs0 = Currency.unwrap(feastKey.currency0) == feast;
        vm.prank(address(0xF1257), address(0xF1257));
        router.swap(
            feastKey.up(),
            ICLPoolManager.SwapParams({
                zeroForOne: coinIs0,
                amountSpecified: -int256(held),
                sqrtPriceLimitX96: coinIs0 ? MIN_SQRT : MAX_SQRT
            }),
            ""
        );

        PoolId id = feastPoolId;
        uint256 pendingBefore = hook.filledCoinPending(id);
        uint256 deadBefore = IERC20(feast).balanceOf(FeastConstants.BURN_ADDRESS);
        hook.collectLpFees(feastKey);
        uint256 owed = hook.filledCoinPending(id) - pendingBefore;
        assertGt(owed, 0, "the sale's coin-side fee was collected, and is owed to the burn");
        assertEq(IERC20(feast).balanceOf(FeastConstants.BURN_ADDRESS), deadBefore, "not sent to 0xdEaD");

        uint256 supplyBefore = IERC20(feast).totalSupply();
        hook.burnFilledCoin(feastKey);
        assertEq(supplyBefore - IERC20(feast).totalSupply(), pendingBefore + owed, "and burned, out of the supply");
        assertEq(hook.filledCoinPending(id), 0, "nothing left owed");
    }
}
