// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FeastConstants} from "../src/FeastConstants.sol";
import {FeastFeeLedger} from "../src/FeastFeeLedger.sol";
import {PoolId, PoolIdLibrary} from "../src/venue/PoolId.sol";
import {PoolKey} from "../src/venue/PoolKey.sol";

import {HookFixture} from "./utils/HookFixture.sol";

/// Who the hook says paid, earned and referred each fee.
///
/// Emissions and the genesis grants pay FEAST against these three tracks, so an
/// attribution error is a payout error. The one anti-abuse rule the owner
/// ruled (ruling 5, and Q5: one definition) is that a referrer who is the payer
/// is no referral at all — no commission and no referral credit — decided in
/// ONE place, so the two consequences cannot drift apart.
contract FeastAttributionTest is HookFixture {
    using PoolIdLibrary for PoolKey;

    function setUp() public override {
        super.setUp();
        _pool(creator, 2_000, 1_000, 0, address(0));
    }

    function _credit(address a) internal view returns (FeastFeeLedger.Credit memory) {
        return ledger.credit(ledger.currentWeek(), address(quote), a);
    }

    function _totals() internal view returns (FeastFeeLedger.Credit memory) {
        return ledger.totals(ledger.currentWeek(), address(quote));
    }

    // --- the three tracks, through the real hook --------------------------

    /// Every fee the hook takes lands whole on each of the three tracks.
    /// Kills: dropping the creator or referrer argument; passing a share.
    function test_eachBranchCreditsTheWholeFeeToPayerCreatorAndReferrer() public {
        PoolId id = key.toId();
        for (uint256 b = 0; b < 4; b++) {
            uint256 accruedBefore = hook.poolInfo(id).accruedQuote;
            FeastFeeLedger.Credit memory before = _totals();
            _branch(router, b, trader, _referral(referrer));
            uint256 fee = hook.poolInfo(id).accruedQuote - accruedBefore;
            FeastFeeLedger.Credit memory after_ = _totals();

            assertGt(fee, 0, "a fee was taken");
            assertEq(after_.paid - before.paid, fee, "the payer track took the whole fee");
            assertEq(after_.earned - before.earned, fee, "the creator track took the whole fee");
            assertEq(after_.referred - before.referred, fee, "the referral track took the whole fee");
        }
        assertEq(_credit(trader).paid, _totals().paid, "all of it is the trader's");
        assertEq(_credit(creator).earned, _totals().earned, "all of it the creator's coin earned");
        assertEq(_credit(referrer).referred, _totals().referred, "all of it the referrer brought");
    }

    /// The payer is the transaction's origin, not the router the hook sees.
    function test_thePayerIsTheOriginNotTheRouter() public {
        _branch(router, 0, trader, "");
        assertGt(_credit(trader).paid, 0, "the trader");
        assertEq(_credit(address(router)).paid, 0, "not the router");
    }

    // --- referrer == payer: no referral at all ------------------------------

    /// Kills: dropping the payer check; checking it in the ledger path only (the
    /// commission would survive); checking it in the commission path only.
    function test_aSelfReferralIsNoReferralOnAnyBranch() public {
        PoolId id = key.toId();
        for (uint256 b = 0; b < 4; b++) {
            _branch(router, b, trader, _referral(trader));
        }
        assertEq(hook.referrerPending(id, trader), 0, "no commission to oneself");
        assertEq(hook.poolInfo(id).referrerEarned, 0, "none banked at all");
        assertEq(_credit(trader).referred, 0, "no referral credit to oneself");
        assertEq(_totals().referred, 0, "and none on the track");
        assertGt(_credit(trader).paid, 0, "the fees are still the trader's as payer");
    }

    /// With no referral, the commission stays with the creator — the creator's
    /// remainder is computed exactly as for an unreferred trade.
    function test_aSelfReferralLeavesTheSplitExactlyAsAnUnreferredTrade() public {
        PoolId id = key.toId();
        _branch(router, 0, trader, _referral(trader));
        uint256 creatorSelf = hook.creatorPending(id);
        uint256 accruedSelf = hook.poolInfo(id).accruedQuote;

        _pool(creator, 2_000, 1_000, 0, address(0));
        PoolId id2 = key.toId();
        _branch(router, 0, trader, "");
        assertEq(hook.poolInfo(id2).accruedQuote, accruedSelf, "same trade, same fee");
        assertEq(hook.creatorPending(id2), creatorSelf, "and the same creator remainder");
    }

    /// The rule compares against the PAYER. Naming the router — or anybody who
    /// is not the origin — is an ordinary referral.
    /// Kills: comparing the referrer with the hook's `sender` instead.
    function test_naming_theRouterIsAnOrdinaryReferral() public {
        PoolId id = key.toId();
        _branch(router, 0, trader, _referral(address(router)));
        assertGt(hook.referrerPending(id, address(router)), 0, "commission paid");
        assertGt(_credit(address(router)).referred, 0, "and credited");
    }

    /// Ruling Q4: the referral track counts referred fees whatever share the
    /// creator gave referrers — including none.
    function test_aReferralOnACoinWithNoCommissionStillEarnsTheTrack() public {
        _pool(creator, 2_000, 0, 0, address(0));
        PoolId id = key.toId();
        _branch(router, 0, trader, _referral(referrer));
        assertEq(hook.referrerPending(id, referrer), 0, "no commission: the creator set none");
        assertGt(_credit(referrer).referred, 0, "but the referral is still a referral");
    }

    /// A burn-address creator (the platform coin) earns no creator track: its
    /// share is burned, not owned.
    function test_aBurnAddressCreatorEarnsNoCreatorTrack() public {
        _pool(FeastConstants.BURN_ADDRESS, 2_000, 1_000, 0, address(0));
        _branch(router, 0, trader, _referral(referrer));
        assertEq(_totals().earned, 0, "no creator track for the burn address");
        assertEq(_credit(FeastConstants.BURN_ADDRESS).earned, 0, "and nothing held by it");
        assertGt(_totals().paid, 0, "the payer is still credited");
        assertGt(_totals().referred, 0, "and the referrer");
    }

    /// Whatever the hookData and whoever the origin, a referrer equal to the
    /// payer is never credited on either consequence.
    function testFuzz_aReferrerEqualToThePayerNeverCredits(address origin, uint8 branch) public {
        vm.assume(origin != address(0) && origin.code.length == 0);
        vm.assume(origin != address(router) && origin != address(this));
        PoolId id = key.toId();
        _branch(router, branch % 4, origin, _referral(origin));
        assertEq(hook.referrerPending(id, origin), 0, "no commission");
        assertEq(_credit(origin).referred, 0, "no credit");
    }
}
