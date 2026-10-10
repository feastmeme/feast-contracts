// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FeastHook} from "../../../src/FeastHook.sol";
import {PoolKey} from "../../../src/venue/PoolKey.sol";
import {UnitFixture} from "../../utils/UnitFixture.sol";

/// PoC for the v1.6.11 round's HIGH `auction-lp-fees-stranded`, reported INDEPENDENTLY by four
/// units across BOTH families: `HK10-claude` (HIGH), `HK10b` (HIGH, `auction-position-handles-
/// lost`), `HK20` (HIGH, `auction-collection-ticks`) and `HK20-claude` (MEDIUM,
/// `auction-seed-ticks-unrecorded`), all at `src/FeastHook.sol:1000-1013`.
///
/// `seedLiquidity` records the range it placed, and says why in as many words:
///
///     // src/FeastHook.sol:967-969
///     // Remembered so the position's own fees stay collectable: the range is
///     // the only handle on a position that can never otherwise be addressed.
///     p.tickLower = tickLower;
///     p.tickUpper = tickUpper;
///
/// `seedAuctionLiquidity` — v1.6.11's new entry point, and the ONLY way the platform pool is
/// ever seeded — does not. It flips `seeded` and opens the lock, and both `tickLower` and
/// `tickUpper` stay at their zero values. `collectLpFees` then hands the venue the pair `(0, 0)`
/// at `src/FeastHook.sol:1152`, which is not a position and not even a valid range.
///
/// The platform pool is the one pool in the system with TWO positions, so there is no single
/// `(lower, upper)` that could address them both even if one had been written. The LP fees of
/// the permanently locked bid and ask — the whole net pot and half the supply — are earned for
/// ever and collectable never.
contract AuctionLpFeesStrandedPoC is UnitFixture {
    /// An ordinary coin's LP fees collect, which is the control: the mechanism works, and what
    /// follows is about the platform pool alone.
    function test_anOrdinaryPoolsLpFeesCollect() public {
        (, PoolKey memory k) = _create(address(wbnb), bytes32(uint256(1)));
        _buy(k, address(wbnb), 10e18, trader, address(0));
        hook.collectLpFees(k);
    }

    /// The platform pool, seeded by the auction, cannot collect anything — ever.
    function test_thePlatformPoolsLpFeesAreCollectable() public {
        _launch(10e18);
        _firstPlatformTrade();

        // The witness has to reach its bound at BOTH ends. A collection that reverted because
        // there were no fees would prove nothing, so trade again — and the platform coin opens
        // at the auction's clearing price, so a whole ether of it is past the 0.5%-of-supply
        // opening cap and reverts `PurchaseCapExceeded` long before the collection is reached.
        // The first draft of this PoC failed on exactly that and measured nothing.
        _buy(feastKey, address(wbnb), 1e15, trader2, address(0));

        hook.collectLpFees(feastKey);
    }

    /// And the handles the collection needs were never written.
    function test_theAuctionSeedRecordsTheRangesItPlaced() public {
        _launch(10e18);
        FeastHook.Pool memory p = hook.poolInfo(feastPoolId);
        assertTrue(p.seeded, "the platform pool is seeded");
        assertTrue(
            p.tickLower != 0 || p.tickUpper != 0,
            "the auction seed recorded no range, so there is no handle on either position"
        );
    }

}
