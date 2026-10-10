// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FeastFeeLedger} from "../src/FeastFeeLedger.sol";
import {FeastGenesis} from "../src/FeastGenesis.sol";
import {FeastHook} from "../src/FeastHook.sol";
import {PoolId, PoolIdLibrary} from "../src/venue/PoolId.sol";
import {PoolKey} from "../src/venue/PoolKey.sol";

import {HookFixture} from "./utils/HookFixture.sol";

/// The `openAt` gate.
///
/// Before `openAt`, only the pool's opener — the platform coin's launch window —
/// may trade the pool. That is the whole of the uniform-price promise: nobody
/// can buy the bottom of the curve ahead of the window's one swap. The gate
/// must hold on all four fee branches (the exact-in sell takes its fee in
/// `afterSwap`, so a gate placed after the early return would miss it), must
/// lift at `openAt` and not a second later, must not record the window's trade
/// as anyone's fee, and must be invisible to every ordinary coin.
contract FeastGateTest is HookFixture {
    using PoolIdLibrary for PoolKey;

    uint64 internal openAt;

    function setUp() public override {
        super.setUp();
        openAt = uint64(clock + 1 days);
        _pool(creator, 2_000, 1_000, openAt, address(openerRouter));
    }

    function _notOpen() internal view returns (bytes memory) {
        return abi.encodeWithSelector(FeastHook.PoolNotOpenYet.selector, openAt);
    }

    // --- closed to everyone but the opener --------------------------------

    /// Kills: dropping the gate; placing it after the fee's early return (the
    /// exact-in sell would get through).
    function test_beforeOpenAtAStrangerCannotTradeOnAnyBranch() public {
        for (uint256 b = 0; b < 4; b++) {
            _expectHookRevert(_notOpen());
            this.branchVia(false, b);
        }
    }

    /// Kills: an off-by-one that lifts the gate a second early.
    function test_oneSecondBeforeOpenAtIsStillClosed() public {
        vm.warp(openAt - 1);
        _expectHookRevert(_notOpen());
        this.branchVia(false, 0);
    }

    function test_theOpenerTradesBeforeOpenAtOnEveryBranch() public {
        for (uint256 b = 0; b < 4; b++) {
            this.branchVia(true, b);
        }
    }

    function test_atOpenAtEveryoneTrades() public {
        vm.warp(openAt);
        for (uint256 b = 0; b < 4; b++) {
            this.branchVia(false, b);
        }
    }

    /// The window's settlement swap is not a trade by anybody. Recorded, it
    /// would credit whoever called `settle` with 1% of the whole pot.
    /// Kills: recording a gated swap.
    function test_theOpenersTradeIsChargedButRecordedNowhere() public {
        PoolId id = key.toId();
        uint256 week = ledger.currentWeek();
        this.branchVia(true, 0);

        assertGt(hook.poolInfo(id).accruedQuote, 0, "the window pays the fee like any trade");
        FeastFeeLedger.Credit memory t = ledger.totals(week, address(quote));
        assertEq(uint256(t.paid) + t.earned + t.referred, 0, "and nobody is credited with it");
    }

    function test_afterOpenAtTradesAreRecordedAgain() public {
        vm.warp(openAt);
        uint256 week = ledger.currentWeek();
        this.branchVia(false, 0);
        assertGt(ledger.totals(week, address(quote)).paid, 0, "an open pool's fees are fees");
    }

    // --- invisible to ordinary coins ---------------------------------------

    function test_aPoolWithNoGateTradesAtOnceForEveryone() public {
        _pool(creator, 2_000, 1_000, 0, address(0));
        for (uint256 b = 0; b < 4; b++) {
            this.branchVia(false, b);
        }
        assertGt(ledger.totals(ledger.currentWeek(), address(quote)).paid, 0, "and is recorded from the first trade");
    }

    // --- the bound, at the callee --------------------------------------------

    function test_aGateWithNoOpenerIsRefused() public {
        PoolKey memory k = _freshKey();
        vm.expectRevert(abi.encodeWithSelector(FeastHook.GateOutOfBounds.selector, uint64(clock + 1), address(0)));
        hook.registerPool(k, address(coin), creator, 0, 0, 1e27, uint64(clock + 1), address(0));
    }

    function test_anOpenerWithNoGateIsRefused() public {
        PoolKey memory k = _freshKey();
        vm.expectRevert(abi.encodeWithSelector(FeastHook.GateOutOfBounds.selector, uint64(0), address(0xABC)));
        hook.registerPool(k, address(coin), creator, 0, 0, 1e27, 0, address(0xABC));
    }

    function test_aGateAlreadyInThePastIsRefused() public {
        PoolKey memory k = _freshKey();
        vm.expectRevert(abi.encodeWithSelector(FeastHook.GateOutOfBounds.selector, uint64(clock), address(0xABC)));
        hook.registerPool(k, address(coin), creator, 0, 0, 1e27, uint64(clock), address(0xABC));
    }

    /// Kills: widening or dropping `MAX_GATE_DURATION`. Even a mistaken genesis
    /// key cannot close the platform coin's pool for longer than this.
    function test_aGateLongerThanTheBoundIsRefusedAndTheBoundItselfIsAccepted() public {
        PoolKey memory k = _freshKey();
        uint64 tooLate = uint64(clock + FeastGenesis.MAX_GATE_DURATION + 1);
        vm.expectRevert(abi.encodeWithSelector(FeastHook.GateOutOfBounds.selector, tooLate, address(0xABC)));
        hook.registerPool(k, address(coin), creator, 0, 0, 1e27, tooLate, address(0xABC));

        hook.registerPool(
            k, address(coin), creator, 0, 0, 1e27, uint64(clock + FeastGenesis.MAX_GATE_DURATION), address(0xABC)
        );
        assertEq(hook.poolInfo(k.toId()).openAt, uint64(clock + FeastGenesis.MAX_GATE_DURATION), "fourteen days is allowed");
    }

    // --- r1 M1: the hook's own swap is behind the gate too --------------

    /// The venue skips a hook's callbacks when the hook itself swaps, so the
    /// gate in `beforeSwap` never sees `buyBackAndBurn`. Round 1 (M1) built
    /// it: the opener's swap banks a self-burn share and starts the oracle, and
    /// five minutes later a stranger's buy-back trades the gated pool and takes
    /// a tip. Kills: a buy-back with no gate check.
    function test_theBuyBackButtonIsClosedWhileThePoolIsGated() public {
        this.branchVia(true, 0);
        _advance(301);
        assertGt(hook.spendingAllowance(key.toId()), 0, "the bucket and the oracle are ready");
        vm.prank(address(0x5712A));
        vm.expectRevert(abi.encodeWithSelector(FeastHook.PoolNotOpenYet.selector, openAt));
        hook.buyBackAndBurn(key, 1e18);
    }

    function test_theBuyBackButtonWorksOnceThePoolOpens() public {
        this.branchVia(true, 0);
        clock = openAt;
        vm.warp(clock);
        vm.roll(vm.getBlockNumber() + 1);
        this.branchVia(false, 0);
        _advance(301);
        uint256 before = hook.selfBurnPending(key.toId());
        vm.prank(address(0x5712A));
        hook.buyBackAndBurn(key, 1e18);
        assertLt(hook.selfBurnPending(key.toId()), before, "it spends once the pool is open");
    }

    // --- r1 L1: fourteen days, literally --------------------------------

    /// Kills: changing `MAX_GATE_DURATION` itself. The other bound tests derive
    /// their timestamps from the constant, so a 28-day constant would pass them.
    function test_theGateBoundIsFourteenDaysLiterally() public {
        assertEq(FeastGenesis.MAX_GATE_DURATION, 14 days, "fourteen days");
        PoolKey memory k = _freshKey();
        uint64 fifteen = uint64(clock + 15 days);
        vm.expectRevert(abi.encodeWithSelector(FeastHook.GateOutOfBounds.selector, fifteen, address(0xABC)));
        hook.registerPool(k, address(coin), creator, 0, 0, 1e27, fifteen, address(0xABC));
    }

    // --- helpers --------------------------------------------------------

    /// @dev External so a revert expectation can wrap exactly one swap.
    function branchVia(bool opener, uint256 b) external {
        _branch(opener ? openerRouter : router, b, trader, "");
    }

    function _freshKey() internal returns (PoolKey memory k) {
        k = key;
        // A different fee tier gives a different pool id over the same pair.
        k.fee = k.fee + 1;
    }
}

