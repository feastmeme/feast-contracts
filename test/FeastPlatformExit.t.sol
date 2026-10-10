// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {stdStorage, StdStorage} from "forge-std/Test.sol";

import {FeastConstants} from "../src/FeastConstants.sol";
import {FeastGenesis} from "../src/FeastGenesis.sol";
import {FeastHook} from "../src/FeastHook.sol";
import {PoolId, PoolIdLibrary} from "../src/venue/PoolId.sol";
import {PoolKey} from "../src/venue/PoolKey.sol";

import {Currency as UpCurrency} from "infinity-core/src/types/Currency.sol";

import {HookFixture} from "./utils/HookFixture.sol";
import {PausableMockERC20, ReentrantMockERC20} from "./utils/MockERC20.sol";

/// @dev A sink that says what it is (round 2, M1: the exit pays only a
///      contract that reports the sink's role for the platform coin).
contract SinkStandIn {
    bytes32 public immutable genesisRole;
    address public immutable platformCoin;

    constructor(bytes32 role_, address platformCoin_) {
        genesisRole = role_;
        platformCoin = platformCoin_;
    }
}

/// The platform-bucket exit.
///
/// v1 banked the platform's 20% and had no way to spend it. In v1.6 it leaves
/// the hook, as the asset it accrued in, to the one sink the genesis call names
/// — permissionlessly, with no route and no conversion. It is a settlement site,
/// so it carries the same two rules every other settlement site does (§6c B5,
/// two failures recorded of the three Rule 8 allows): no more than one signed
/// 128-bit delta per call, and the bucket is debited by exactly what was paid.
contract FeastPlatformExitTest is HookFixture {
    using PoolIdLibrary for PoolKey;
    using stdStorage for StdStorage;

    address internal stranger = address(0x5712A);

    function setUp() public override {
        super.setUp();
        _pool(creator, 2_000, 1_000, 0, address(0));
        for (uint256 b = 0; b < 4; b++) {
            _branch(router, b, trader, _referral(referrer));
        }
    }

    function _bind() internal returns (address sink) {
        sink = address(new SinkStandIn(FeastGenesis.ROLE_PLATFORM_SINK, platformCoin));
        platformSink = sink;
    }

    // --- refusals ---------------------------------------------------------

    function test_beforeGenesisNamesASinkTheExitRefuses() public {
        vm.expectRevert(abi.encodeWithSelector(FeastHook.PlatformSinkNotBound.selector, address(0)));
        hook.releasePlatformFees(key);
    }

    /// The one recipient genesis may name before its code exists. Until it
    /// does, the platform share stays in the hook, owned and intact.
    function test_aSinkWithNoCodeYetIsRefusedAndTheBucketIsUntouched() public {
        platformSink = address(0x51CC);
        uint256 pending = hook.platformPending(key.toId());
        vm.expectRevert(abi.encodeWithSelector(FeastHook.PlatformSinkNotBound.selector, address(0x51CC)));
        hook.releasePlatformFees(key);
        assertEq(hook.platformPending(key.toId()), pending, "nothing moved");
    }

    /// Round 2 (M1): once the sink has code it must be the sink — genesis
    /// could not check a sink that did not exist yet, so the exit does.
    /// Kills: an exit that pays any contract with code.
    function test_aSinkThatIsNotTheSinkIsRefusedAtTheExit() public {
        address[3] memory wrong = [
            address(hook),
            address(new SinkStandIn(FeastGenesis.ROLE_GRANTS, platformCoin)),
            address(new SinkStandIn(FeastGenesis.ROLE_PLATFORM_SINK, address(0xBEEF)))
        ];
        for (uint256 i = 0; i < wrong.length; i++) {
            platformSink = wrong[i];
            vm.expectRevert(abi.encodeWithSelector(FeastHook.PlatformSinkNotBound.selector, wrong[i]));
            hook.releasePlatformFees(key);
        }
    }

    // --- the exit ---------------------------------------------------------

    /// Kills: an exit that does not debit; one that pays the wrong recipient.
    function test_anyoneMovesExactlyThePlatformShareToTheSink() public {
        address sink = _bind();
        PoolId id = key.toId();
        uint256 pending = hook.platformPending(id);
        assertGt(pending, 0, "the four trades banked a platform share");

        vm.expectEmit(address(hook));
        emit FeastHook.PlatformFeesReleased(id, sink, pending);
        vm.prank(stranger);
        hook.releasePlatformFees(key);

        assertEq(quote.balanceOf(sink), pending, "the sink holds the asset itself, unconverted");
        assertEq(hook.platformPending(id), 0, "the bucket is empty");
        assertEq(hook.poolInfo(id).platformUsed, pending, "and debited by exactly what was paid");
    }

    function test_theExitTouchesNoOtherBucket() public {
        _bind();
        PoolId id = key.toId();
        uint256 selfBurn = hook.selfBurnPending(id);
        uint256 creatorOwed = hook.creatorPending(id);
        uint256 referral = hook.referrerPending(id, referrer);
        hook.releasePlatformFees(key);
        assertEq(hook.selfBurnPending(id), selfBurn, "self-burn untouched");
        assertEq(hook.creatorPending(id), creatorOwed, "creator untouched");
        assertEq(hook.referrerPending(id, referrer), referral, "referrer untouched");
    }

    function test_anEmptyBucketIsANoOpNotARevert() public {
        _bind();
        hook.releasePlatformFees(key);
        hook.releasePlatformFees(key);
        assertEq(hook.platformPending(key.toId()), 0, "still empty");
    }

    /// New fees after an exit accrue and leave again; the bucket is a running
    /// total minus what was paid, never reset.
    function test_theBucketRefillsAndLeavesAgain() public {
        address sink = _bind();
        PoolId id = key.toId();
        hook.releasePlatformFees(key);
        uint256 first = quote.balanceOf(sink);
        _branch(router, 0, trader, "");
        uint256 more = hook.platformPending(id);
        assertGt(more, 0, "refilled");
        hook.releasePlatformFees(key);
        assertEq(quote.balanceOf(sink), first + more, "and left");
    }

    /// Kills: an unbounded exit. A bucket past one signed 128-bit delta is paid
    /// in pieces, each debited by what it paid — never reverting for ever, and
    /// never clearing the excess (rounds 10 and 11).
    function test_aBucketLargerThanOneSettlementLeavesInPieces() public {
        address sink = _bind();
        PoolId id = key.toId();
        uint256 huge = FeastConstants.MAX_SETTLEMENT + 12_345;
        _setPlatformPending(id, huge);

        hook.releasePlatformFees(key);
        assertEq(quote.balanceOf(sink), FeastConstants.MAX_SETTLEMENT, "one settlement's worth");
        assertEq(hook.platformPending(id), 12_345, "the rest is still owed");

        hook.releasePlatformFees(key);
        assertEq(quote.balanceOf(sink), huge, "and paid next time");
        assertEq(hook.platformPending(id), 0, "exactly");
    }

    /// A quote token that freezes makes the exit revert, with the entitlement
    /// intact — stuck, never lost — and every other pool keeps trading (I2).
    function test_aFrozenQuoteDelaysTheExitButNeverChangesIt() public {
        address pauser = address(0x9A05E);
        PausableMockERC20 frozen = new PausableMockERC20("Frozen", "FRZ", 18, pauser);
        _poolAgainst(frozen, creator, 2_000, 1_000, 0, address(0));
        _branch(router, 0, trader, "");
        PoolId id = key.toId();
        address sink = _bind();
        uint256 pending = hook.platformPending(id);

        vm.prank(pauser);
        frozen.setPaused(true);
        vm.expectRevert();
        hook.releasePlatformFees(key);
        assertEq(hook.platformPending(id), pending, "the entitlement is intact");

        vm.prank(pauser);
        frozen.setPaused(false);
        hook.releasePlatformFees(key);
        assertEq(frozen.balanceOf(sink), pending, "and leaves once the freeze lifts");
    }

    /// A quote token that calls back during the exit's own payout finds the
    /// bucket already debited, so the share can neither leave twice nor be
    /// stranded. Kills: debiting after the payout instead of before it.
    ///
    /// Round 2 (L2) saw the debit through a nested exit that SUCCEEDED and paid
    /// nothing. Since v1.6.28 (AstraSec, 7 October) the exit holds the hook's
    /// re-entrancy guard, so a nested exit reverts
    /// `ReentrancyGuardReentrantCall()` before it reads the bucket, whatever the
    /// order of debit and payout. Both facts are pinned here: the refusal, by
    /// name, and the debit, read from inside the payout through the view, which
    /// no guard covers — debited after the payout, the bucket would still show
    /// the whole share there. `test/audit/astrasec/I7_PayoutsHoldTheGuard.t.sol`
    /// re-enters the other two paying functions the same way.
    function test_aQuoteThatReentersTheExitCannotDoubleThePayout() public {
        ReentrantMockERC20 q = new ReentrantMockERC20("Hostile", "HST", 18);
        _poolAgainst(q, creator, 2_000, 1_000, 0, address(0));
        _branch(router, 0, trader, "");
        PoolId id = key.toId();
        address sink = _bind();
        uint256 pending = hook.platformPending(id);

        q.arm(address(hook), abi.encodeCall(FeastHook.releasePlatformFees, (key)), 1);
        hook.releasePlatformFees(key);

        assertTrue(q.fired(), "the token did call back in");
        assertFalse(q.lastCallOk(), "the nested exit is refused");
        assertEq(q.balanceOf(sink), pending, "the share left exactly once");
        assertEq(hook.platformPending(id), 0, "and the bucket is empty, not negative, not stranded");

        // From inside the next payout: the bucket as it stands there, and the
        // exit called again through this contract, which keeps the revert data
        // the token discards.
        _branch(router, 0, trader, "");
        uint256 more = hook.platformPending(id);
        assertGt(more, 0, "the bucket refilled");
        _bucketSeenInsideThePayout = type(uint256).max;
        q.arm(address(this), abi.encodeCall(this.probeThePayout, (key, id)), 1);
        hook.releasePlatformFees(key);
        assertTrue(q.lastCallOk(), "the probe ran inside the payout");
        assertEq(_bucketSeenInsideThePayout, 0, "the bucket was already debited when the token moved");
        assertFalse(_nestedExitOk, "the nested exit is refused");
        assertEq(
            bytes4(_nestedExitReturn), FeastHook.ReentrancyGuardReentrantCall.selector, "by the guard, by name"
        );
        assertEq(q.balanceOf(sink), pending + more, "and the share left once more");
    }

    uint256 internal _bucketSeenInsideThePayout;
    bool internal _nestedExitOk;
    bytes internal _nestedExitReturn;

    /// What the hostile quote calls from inside the exit's payout: the bucket
    /// as it stands there, then the exit again, keeping how that call ended.
    function probeThePayout(PoolKey calldata k, PoolId id) external {
        _bucketSeenInsideThePayout = hook.platformPending(id);
        (_nestedExitOk, _nestedExitReturn) = address(hook).call(abi.encodeCall(FeastHook.releasePlatformFees, (k)));
    }

    // --- helpers --------------------------------------------------------

    /// @dev Raise a pool's platform bucket past one settlement without five
    ///      hundred maximal swaps: write the bucket's running total, give the
    ///      hook the matching vault claim, and give the vault the tokens behind
    ///      it — the three facts a real accrual would have produced together.
    function _setPlatformPending(PoolId id, uint256 amount) internal {
        // Found by effect rather than by offset: several buckets can hold the
        // same number (20% self-burn and 20% platform do), so a candidate slot
        // is written, kept only if it moved `platformPending`, else restored.
        uint256 earned = hook.poolInfo(id).platformEarned;
        uint256 used = hook.poolInfo(id).platformUsed;
        bytes32 base = keccak256(abi.encode(PoolId.unwrap(id), uint256(0)));
        bool found;
        for (uint256 i = 0; i < 16 && !found; i++) {
            bytes32 slot = bytes32(uint256(base) + i);
            bytes32 old = vm.load(address(hook), slot);
            if (uint256(old) != earned) continue;
            vm.store(address(hook), slot, bytes32(used + amount));
            if (hook.platformPending(id) == amount && hook.selfBurnPending(id) != 0) found = true;
            else vm.store(address(hook), slot, old);
        }
        require(found, "platformEarned slot not found");

        uint256 held = vault.balanceOf(address(hook), UpCurrency.wrap(address(quote)));
        stdstore.target(address(vault)).sig("balanceOf(address,address)").with_key(address(hook)).with_key(
            address(quote)
        ).checked_write(held + amount);
        quote.mint(address(vault), amount);
    }
}
