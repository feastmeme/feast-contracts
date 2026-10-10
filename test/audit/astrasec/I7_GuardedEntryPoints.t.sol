// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FeastConverter} from "../../../src/FeastConverter.sol";
import {FeastHook} from "../../../src/FeastHook.sol";
import {PoolId, PoolIdLibrary} from "../../../src/venue/PoolId.sol";
import {PoolKey} from "../../../src/venue/PoolKey.sol";
import {MockV3Factory} from "../../utils/MockV3Pool.sol";
import {UnitFixture} from "../../utils/UnitFixture.sol";
import {ReenteringPool} from "../poc/ConverterReentrancy.t.sol";

/// Calls several guarded entry points from ONE call frame, as a batching
/// contract would. Under `isolate = true` every top-level call from a test is
/// its own transaction, so only a contract like this can show the flag is
/// cleared on the way out rather than left for the transaction's end.
contract GuardedBatch {
    function run(FeastHook hook, PoolKey calldata key, address account) external {
        hook.collectLpFees(key);
        hook.burnFilledCoin(key);
        hook.claim(key, account);
        hook.collectLpFees(key);
    }
}

/// AstraSec I-7: `nonReentrant` on the hook entry points that move value out
/// or across, and never on `lockAcquired` or the venue's callbacks. v1.6.24
/// guarded five: `claim`, `claimAsBnb`, `buyBackAndBurn`, `burnFilledCoin`,
/// `collectLpFees`. v1.6.28 (AstraSec's suggestion of 7 Oct) moves `claim`'s
/// guard onto the three functions that pay — `claimCreator`, `claimReferrer`,
/// `releasePlatformFees` — so seven are guarded and `claim`, which pays
/// nothing itself, is not: it calls `claimCreator` and `claimReferrer` in turn.
///
/// The route a re-entry can actually take is the one `ConverterReentrancy`
/// models: `claimAsBnb` hands control to a pool on a route the claimant chose,
/// and that pool can call anything. Here it calls each of them, from inside a
/// creator's conversion. Before v1.6.24 every one of them was entered (or
/// refused for some reason of its own); now every one is refused by the one
/// shared guard, by name — `claim` one call down, by the guard on whichever
/// paying function it reaches. `I7_PayoutsHoldTheGuard.t.sol` re-enters the
/// three paying functions from inside their own payouts.
contract I7GuardedEntryPoints is UnitFixture {
    using PoolIdLibrary for PoolKey;

    ReenteringPool internal hostile;
    PoolKey internal key;
    uint24 internal constant HOSTILE_FEE = 3_000;
    /// `FeastHook.ReentrancyGuardReentrantCall.selector`, spelled out so this
    /// file also compiles against the tree before the guard existed.
    bytes4 internal constant GUARD_REFUSAL = bytes4(keccak256("ReentrancyGuardReentrantCall()"));

    function test_theRefusalIsTheHooksOwnError() public pure {
        assertEq(GUARD_REFUSAL, FeastHook.ReentrancyGuardReentrantCall.selector, "the named error");
    }

    function setUp() public override {
        super.setUp();
        deployCodeTo("MockV3Pool.sol:MockV3Factory", "", address(0xF3));
        hostile = new ReenteringPool(address(stock), address(wbnb));
        MockV3Factory(address(0xF3)).set(address(stock), address(wbnb), HOSTILE_FEE, address(hostile));
        vm.deal(address(this), 1_000 ether);
        wbnb.deposit{value: 1_000 ether}();
        wbnb.transfer(address(hostile), 1_000 ether);

        (, key) = _create(address(stock), bytes32(uint256(0x17)));
        // Two claimants: the creator, who converts through the hostile pool, and
        // a referrer, whose entitlement a re-entrant `claim` would pay.
        _buy(key, address(stock), 50_000e18, trader, referrer);
    }

    function _route() internal view returns (FeastConverter.Hop[] memory r) {
        r = new FeastConverter.Hop[](1);
        r[0] = FeastConverter.Hop({tokenOut: address(wbnb), fee: HOSTILE_FEE});
    }

    /// Arm the pool with `call`, run the creator's conversion, and require the
    /// re-entry to have been refused by the guard — and the conversion itself
    /// to have completed, so the refusal is the guard's and not a casualty of
    /// some other failure.
    function _reenterWith(bytes memory call) internal {
        hostile.arm(ReenteringPool.Mode.Reenter, address(hook), call);
        vm.prank(creator);
        uint256 out = hook.claimAsBnb(key, creator, _route(), 0);
        assertGt(out, 0, "the outer conversion completed");
        assertFalse(hostile.reentryOk(), "the re-entrant call went through");
        assertEq(bytes4(hostile.reentryReturn()), GUARD_REFUSAL, "refused by the guard, by name");
    }

    function test_claimCannotBeEnteredFromInsideAConversion() public {
        uint256 referrerOwed = hook.claimable(key, referrer);
        assertGt(referrerOwed, 0, "the referrer has something a re-entry would pay");
        _reenterWith(abi.encodeCall(FeastHook.claim, (key, referrer)));
        assertEq(hook.claimable(key, referrer), referrerOwed, "and it is still owed");
    }

    function test_claimAsBnbCannotBeEnteredFromInsideAConversion() public {
        _reenterWith(abi.encodeCall(FeastHook.claimAsBnb, (key, creator, _route(), 0)));
    }

    function test_collectLpFeesCannotBeEnteredFromInsideAConversion() public {
        _reenterWith(abi.encodeCall(FeastHook.collectLpFees, (key)));
    }

    function test_burnFilledCoinCannotBeEnteredFromInsideAConversion() public {
        _reenterWith(abi.encodeCall(FeastHook.burnFilledCoin, (key)));
    }

    function test_buyBackAndBurnCannotBeEnteredFromInsideAConversion() public {
        _reenterWith(abi.encodeCall(FeastHook.buyBackAndBurn, (key, 1)));
    }

    /// v1.6.28: the three paying functions are refused here too, by the flag
    /// `claimAsBnb` holds. Until then nothing stopped them: `claimCreator` was
    /// entered and found the creator's share already debited, `claimReferrer`
    /// was entered and PAID the referrer from inside the creator's conversion,
    /// and `releasePlatformFees` was entered and paid the platform's share.
    function test_claimCreatorCannotBeEnteredFromInsideAConversion() public {
        _reenterWith(abi.encodeCall(FeastHook.claimCreator, (key)));
    }

    function test_claimReferrerCannotBeEnteredFromInsideAConversion() public {
        uint256 referrerOwed = hook.claimable(key, referrer);
        assertGt(referrerOwed, 0, "the referrer has something a re-entry would pay");
        _reenterWith(abi.encodeCall(FeastHook.claimReferrer, (key, referrer)));
        assertEq(hook.claimable(key, referrer), referrerOwed, "and it is still owed");
    }

    /// After genesis, so the sink is bound: a re-entry the guard let through
    /// would pay the platform's share, rather than be refused
    /// `PlatformSinkNotBound` for a reason of its own.
    function test_releasePlatformFeesCannotBeEnteredFromInsideAConversion() public {
        _genesis();
        PoolId id = key.toId();
        uint256 platformOwed = hook.platformPending(id);
        assertGt(platformOwed, 0, "the platform has a share a re-entry would pay");
        _reenterWith(abi.encodeCall(FeastHook.releasePlatformFees, (key)));
        assertEq(hook.platformPending(id), platformOwed, "and it is still owed");
    }

    /// `claimAsBnb` keeps its own guard and pays through `_claimTo`, never
    /// through `claimCreator` or `claimReferrer`, so it does not nest with the
    /// guard those two hold since v1.6.28: an account owed as the creator AND
    /// as a referrer is paid both shares by one call. Routed through either of
    /// them, it would refuse itself by name.
    function test_claimAsBnbPaysACreatorWhoIsAlsoAReferrerInOneCall() public {
        _buy(key, address(stock), 50_000e18, trader2, creator);
        PoolId id = key.toId();
        uint256 asCreator = hook.creatorPending(id);
        uint256 asReferrer = hook.referrerPending(id, creator);
        assertGt(asCreator, 0, "owed as the creator");
        assertGt(asReferrer, 0, "and as a referrer");

        vm.prank(creator);
        uint256 out = hook.claimAsBnb(key, creator, _route(), 0);
        assertEq(out, asCreator + asReferrer, "both shares, converted at the pool's 1:1");
        assertEq(wbnb.balanceOf(creator), out, "delivered to the claimant");
        assertEq(hook.claimable(key, creator), 0, "and nothing is left owed");
    }

    /// The flag is cleared on the way OUT of each guarded call, not left for
    /// the transaction's end: four guarded calls in one frame all run.
    function test_guardedCallsInSequenceInOneTransactionAllRun() public {
        GuardedBatch batch = new GuardedBatch();
        uint256 referrerOwed = hook.claimable(key, referrer);
        batch.run(hook, key, referrer);
        assertEq(hook.claimable(key, referrer), 0, "the batched claim paid");
        assertGt(referrerOwed, 0, "and it had something to pay");
    }
}
