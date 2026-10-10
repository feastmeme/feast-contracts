// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {CustomRevert} from "infinity-core/src/libraries/CustomRevert.sol";
import {CurrencyLibrary} from "infinity-core/src/types/Currency.sol";

import {FeastGenesis} from "../../../src/FeastGenesis.sol";
import {FeastHook} from "../../../src/FeastHook.sol";
import {PoolId, PoolIdLibrary} from "../../../src/venue/PoolId.sol";
import {PoolKey} from "../../../src/venue/PoolKey.sol";
import {HookFixture} from "../../utils/HookFixture.sol";
import {MockERC20} from "../../utils/MockERC20.sol";
import {SinkStandIn} from "../../FeastPlatformExit.t.sol";

/// A quote token that hands control to whoever armed it from inside a payout.
/// Every hook payout is a transfer OUT of the vault, made inside the vault's
/// lock — `_release` burns the hook's claim and takes the token to the payee —
/// so this is the one place a payee's token can call back into the function
/// paying it. It makes one call per payout and records how that call ended,
/// the revert data included, so a refusal can be asserted by name — or, with
/// `bubble` set, lets a refusal through and reverts its own transfer with it,
/// as a token that simply called back would.
contract PayoutReenteringQuote is MockERC20 {
    address public immutable vault;
    address public target;
    bytes public reentryCall;
    bool public bubble;
    bool[] internal _ok;
    bytes[] internal _returned;
    bool internal _calling;

    constructor(address vault_) MockERC20("Hostile", "HST", 18) {
        vault = vault_;
    }

    function arm(address target_, bytes calldata call) external {
        target = target_;
        reentryCall = call;
        delete _ok;
        delete _returned;
    }

    function setBubble(bool bubble_) external {
        bubble = bubble_;
    }

    /// How many payouts have handed it control since it was armed.
    function fired() external view returns (uint256) {
        return _ok.length;
    }

    function reentryOk(uint256 i) external view returns (bool) {
        return _ok[i];
    }

    function reentryReturn(uint256 i) external view returns (bytes memory) {
        return _returned[i];
    }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        if (from != vault || target == address(0) || _calling) return;
        _calling = true;
        (bool ok, bytes memory returned) = target.call(reentryCall);
        _calling = false;
        if (!ok && bubble) {
            assembly ("memory-safe") {
                revert(add(returned, 0x20), mload(returned))
            }
        }
        _ok.push(ok);
        _returned.push(returned);
    }
}

/// Calls the three paying functions one after another from ONE call frame, as
/// a batching contract would, then a function that was guarded before them.
/// Under `isolate = true` every top-level call from a test is its own
/// transaction, so only a contract like this can show each of them clears the
/// flag on the way out rather than leaving it for the transaction's end.
contract PayingBatch {
    function run(FeastHook hook, PoolKey calldata key, address referrer) external {
        hook.claimCreator(key);
        hook.claimReferrer(key, referrer);
        hook.releasePlatformFees(key);
        hook.burnFilledCoin(key);
    }
}

/// AstraSec, 7 Oct (v1.6.28): the guard moved off `claim` and onto the three
/// functions that pay — `claimCreator`, `claimReferrer` and
/// `releasePlatformFees`. `I7_GuardedEntryPoints` shows each of them refused
/// from inside a conversion, by the flag `claimAsBnb` holds; this file shows
/// each of them HOLDING it: a re-entry from inside its own payout is refused
/// by name, and so is one into either of the other two or into a function
/// guarded since v1.6.24.
///
/// Until v1.6.28 none of the three was guarded and each was re-entrant from
/// inside its own payout. What kept that harmless is still there underneath:
/// each debits before it pays, so a nested call found nothing left to pay, and
/// each pays inside the vault's lock, so a nested call that did find something
/// was refused `LockerAlreadySet` by the vault. Both are depth now; the
/// refusal a payee's token meets first is the hook's own. The last test is the
/// one behaviour this changes: a token that lets that refusal through now
/// reverts its own pool's payout instead of seeing it succeed.
contract I7PayoutsHoldTheGuard is HookFixture {
    using PoolIdLibrary for PoolKey;

    /// `FeastHook.ReentrancyGuardReentrantCall.selector`, as in
    /// `I7_GuardedEntryPoints`.
    bytes4 internal constant GUARD_REFUSAL = bytes4(keccak256("ReentrancyGuardReentrantCall()"));

    PayoutReenteringQuote internal hostile;
    PoolId internal id;

    function setUp() public override {
        super.setUp();
        hostile = new PayoutReenteringQuote(address(vault));
        _poolAgainst(hostile, creator, 2_000, 1_000, 0, address(0));
        id = key.toId();
        // Every bucket a payout can come from has something in it: a referrer's
        // commission, and the creator's both as the creator and as a referrer,
        // so that `claim` has two shares to pay them.
        _branch(router, 0, trader, _referral(referrer));
        _branch(router, 0, trader, _referral(creator));
        platformSink = address(new SinkStandIn(FeastGenesis.ROLE_PLATFORM_SINK, platformCoin));
    }

    /// Every payout since arming handed the token control, there were exactly
    /// `payouts` of them, and every re-entry it made was refused by the guard,
    /// by name.
    function _assertEveryReentryRefused(uint256 payouts) internal view {
        assertEq(hostile.fired(), payouts, "one re-entry from inside each payout");
        for (uint256 i = 0; i < payouts; i++) {
            assertFalse(hostile.reentryOk(i), "a re-entrant call went through");
            assertEq(bytes4(hostile.reentryReturn(i)), GUARD_REFUSAL, "refused by the guard, by name");
        }
    }

    // --- each paying function, re-entered from inside its own payout ---------

    function test_claimCreatorCannotBeEnteredFromInsideItsOwnPayout() public {
        uint256 owed = hook.creatorPending(id);
        assertGt(owed, 0, "the creator is owed");
        hostile.arm(address(hook), abi.encodeCall(FeastHook.claimCreator, (key)));
        hook.claimCreator(key);
        _assertEveryReentryRefused(1);
        assertEq(hostile.balanceOf(creator), owed, "paid once");
        assertEq(hook.creatorPending(id), 0, "and nothing is left owed");
    }

    function test_claimReferrerCannotBeEnteredFromInsideItsOwnPayout() public {
        uint256 owed = hook.referrerPending(id, referrer);
        assertGt(owed, 0, "the referrer is owed");
        hostile.arm(address(hook), abi.encodeCall(FeastHook.claimReferrer, (key, referrer)));
        hook.claimReferrer(key, referrer);
        _assertEveryReentryRefused(1);
        assertEq(hostile.balanceOf(referrer), owed, "paid once");
        assertEq(hook.referrerPending(id, referrer), 0, "and nothing is left owed");
    }

    function test_releasePlatformFeesCannotBeEnteredFromInsideItsOwnPayout() public {
        uint256 owed = hook.platformPending(id);
        assertGt(owed, 0, "the platform is owed");
        hostile.arm(address(hook), abi.encodeCall(FeastHook.releasePlatformFees, (key)));
        hook.releasePlatformFees(key);
        _assertEveryReentryRefused(1);
        assertEq(hostile.balanceOf(platformSink), owed, "paid once");
        assertEq(hook.platformPending(id), 0, "and nothing is left owed");
    }

    /// One flag for all of them: from inside `claimCreator`'s payout neither
    /// other paying function, nor a function guarded since v1.6.24, can be
    /// entered. Until v1.6.28 the first two were refused only by the vault's
    /// lock, and `burnFilledCoin` was entered.
    function test_fromInsideOnePayoutNoOtherGuardedFunctionCanBeEntered() public {
        bytes[3] memory calls = [
            abi.encodeCall(FeastHook.claimReferrer, (key, referrer)),
            abi.encodeCall(FeastHook.releasePlatformFees, (key)),
            abi.encodeCall(FeastHook.burnFilledCoin, (key))
        ];
        for (uint256 i = 0; i < calls.length; i++) {
            if (i > 0) _branch(router, 0, trader, _referral(referrer)); // something to pay again
            assertGt(hook.creatorPending(id), 0, "the creator is owed");
            hostile.arm(address(hook), calls[i]);
            hook.claimCreator(key);
            _assertEveryReentryRefused(1);
        }
    }

    // --- claim, which pays nothing itself ------------------------------------

    /// `claim` holds no flag of its own. It calls `claimCreator` and then
    /// `claimReferrer`, and each takes the flag and gives it back, so an
    /// account owed both shares is paid both by one `claim` — which could not
    /// happen if `claim` held the flag as well (the first inner call would
    /// refuse itself) or if the first inner call left it standing. Re-entering
    /// `claim` from inside either payout is still refused by name, one call
    /// down, by the guard on the paying function it reaches.
    function test_claimPaysBothSharesThroughTheTwoGuardedFunctionsInTurn() public {
        uint256 asCreator = hook.creatorPending(id);
        uint256 asReferrer = hook.referrerPending(id, creator);
        assertGt(asCreator, 0, "owed as the creator");
        assertGt(asReferrer, 0, "and as a referrer");
        hostile.arm(address(hook), abi.encodeCall(FeastHook.claim, (key, creator)));
        hook.claim(key, creator);
        _assertEveryReentryRefused(2);
        assertEq(hostile.balanceOf(creator), asCreator + asReferrer, "both shares, once each");
        assertEq(hook.claimable(key, creator), 0, "and nothing is left owed");
    }

    // --- the flag comes down after each call ---------------------------------

    /// In one transaction the three paying functions run one after another:
    /// the flag is up for the whole of each payout (the re-entry from inside
    /// each is refused by name) and down again after each call (the next one
    /// runs, and so does `burnFilledCoin`, guarded since v1.6.24, after the
    /// last of them).
    function test_eachPayingFunctionClearsTheFlagOnTheWayOut() public {
        uint256 creatorOwed = hook.creatorPending(id);
        uint256 referrerOwed = hook.referrerPending(id, referrer);
        uint256 platformOwed = hook.platformPending(id);
        PayingBatch batch = new PayingBatch();
        hostile.arm(address(hook), abi.encodeCall(FeastHook.burnFilledCoin, (key)));
        batch.run(hook, key, referrer);
        _assertEveryReentryRefused(3);
        assertEq(hostile.balanceOf(creator), creatorOwed, "the creator was paid");
        assertEq(hostile.balanceOf(referrer), referrerOwed, "the referrer was paid");
        assertEq(hostile.balanceOf(platformSink), platformOwed, "the platform was paid");
    }

    // --- the one behaviour change --------------------------------------------

    /// What v1.6.28 changes for a quote token that calls back into the
    /// function paying it and lets the refusal through. Until v1.6.28 the call
    /// back was entered, found the share already debited and returned, and the
    /// payout went through with nothing extra paid. Now the call back reverts
    /// `ReentrancyGuardReentrantCall()`, the token's own transfer reverts with
    /// it (the vault wraps it, ERC-7751), and so does the payout. Stuck, never
    /// lost: every entitlement is where it was, as under a paused quote, and a
    /// pool quoted in an ordinary token pays exactly as before.
    function test_aQuoteThatLetsTheRefusalThroughHoldsUpOnlyItsOwnPoolsPayouts() public {
        uint256 creatorOwed = hook.creatorPending(id);
        uint256 referrerOwed = hook.referrerPending(id, referrer);
        uint256 platformOwed = hook.platformPending(id);
        bytes memory refused = abi.encodeWithSelector(
            CustomRevert.WrappedError.selector,
            address(hostile),
            IERC20.transfer.selector,
            abi.encodeWithSelector(GUARD_REFUSAL),
            abi.encodeWithSelector(CurrencyLibrary.ERC20TransferFailed.selector)
        );
        hostile.setBubble(true);

        hostile.arm(address(hook), abi.encodeCall(FeastHook.claimCreator, (key)));
        vm.expectRevert(refused);
        hook.claimCreator(key);

        hostile.arm(address(hook), abi.encodeCall(FeastHook.claimReferrer, (key, referrer)));
        vm.expectRevert(refused);
        hook.claimReferrer(key, referrer);

        hostile.arm(address(hook), abi.encodeCall(FeastHook.releasePlatformFees, (key)));
        vm.expectRevert(refused);
        hook.releasePlatformFees(key);

        assertEq(hook.creatorPending(id), creatorOwed, "the creator is still owed");
        assertEq(hook.referrerPending(id, referrer), referrerOwed, "and the referrer");
        assertEq(hook.platformPending(id), platformOwed, "and the platform");

        // A second pool, quoted in an ordinary token, pays as before.
        _pool(creator, 2_000, 1_000, 0, address(0));
        _branch(router, 0, trader, "");
        PoolId other = key.toId();
        uint256 otherOwed = hook.creatorPending(other);
        assertGt(otherOwed, 0, "the other pool owes its creator");
        hook.claimCreator(key);
        assertEq(quote.balanceOf(creator), otherOwed, "and pays");
        assertEq(hook.creatorPending(id), creatorOwed, "while the first pool's creator is still owed");
    }
}
