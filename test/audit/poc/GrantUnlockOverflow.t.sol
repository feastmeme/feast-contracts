// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {FeastGenesis} from "../../../src/FeastGenesis.sol";
import {FeastGenesisGrants} from "../../../src/FeastGenesisGrants.sol";
import {MockERC20} from "../../utils/MockERC20.sol";

import {FeastGuardian} from "../../../src/FeastGuardian.sol";
/// PoC for the round-r1 HIGH `integer-overflow` (`CA-5ba81ae0e6`), reported by the codex lens
/// (`r1a2`, the coverage unit re-run after the classifier stopped `r1a`) at
/// `src/FeastGenesisGrants.sol:102`, and by no other lens.
///
/// The claim: `unlocked` saturates AFTER it multiplies, not before.
///
///     uint256 u = grant * referredNative[partner] / targetNative;
///     return u > grant ? grant : u;
///
/// The published rule is `unlocked = min(grant, grant x referred / TARGET_NATIVE)`, and the
/// contract's own docstring states it that way. Read as mathematics that is total: once a partner
/// has referred `targetNative`, the minimum pins the answer at `grant` and every larger referral
/// gives the same answer. Read as Solidity it is not, because the numerator is formed first, in
/// checked arithmetic, at 256 bits. A partner who has referred far MORE than the target — the
/// partner who has most earned the grant — is the one whose numerator overflows, and the clamp
/// that would have discarded the overflowing value never runs.
///
/// This is the same shape as the v1.6.2 finding `CA-fad351f89b` that v1.6.3's F1 closed in the
/// sink: an intermediate formed in checked arithmetic ahead of the operation that would have made
/// it harmless. F1 rewrote the sink's re-anchor as `price + mulDiv(price, amountOut, held)`. The
/// grant was not part of that pass and still forms its product up front. `Math.mulDiv(grant,
/// referredNative[partner], targetNative)` computes the same quotient at 512 bits and cannot
/// panic, and the existing clamp then does its job.
///
/// The damage is not a view reverting. `claim` and `burnUnearned` both route through `unlocked`,
/// so a partner in this state can neither be paid what they earned nor have their remainder
/// burned: the grant is stranded, and `burnUnearned`'s once-only flag means the horizon's
/// accounting cannot be closed out either. Nothing hostile is required and no privilege is
/// used — only referral volume, which is the very thing the grant exists to reward.
///
/// The assertion below is about the partner being paid, not about the panic. A fix that computes
/// the quotient without forming the product turns this test green without changing any number the
/// contract publishes for a partner under the target.
contract GrantUnlockOverflowPoC is Test {
    FeastGuardian internal guardian = new FeastGuardian(address(0x3517), address(this));
    /// The eight partner addresses the constructor demands, all distinct and non-zero.
    address[8] internal partnerList;
    address internal partner = address(0xAA00);

    /// `targetNative` as the unit fixture sets it.
    uint256 internal constant TARGET = 100e18;

    /// What the constructor computes: 1e9 * 1e18 * 10 / 10_000 = 1e24, 0.1% of the supply.
    uint256 internal constant GRANT = 1e24;

    function setUp() public {
        for (uint256 i = 0; i < 8; i++) {
            partnerList[i] = address(uint160(0xAA00 + i));
        }
    }

    function test_aFullyEarnedGrantCanStillBeClaimed() public {
        // A referred total the emissions contract reports for week 1. `referredValue` returns
        // `mulDiv(credit.referred, priceQ128, 2**128)` — a native-denominated number whose size is
        // set by the quote's price, not by any bound this contract imposes. `checkpoint` adds it
        // to `referredNative` with no ceiling of its own.
        //
        // This value is 2e53. It is above `(2**256 - 1) / GRANT` = 1.1579e53, which is the exact
        // point where the product stops fitting in a word, and it is far above `TARGET`, so the
        // partner has earned the whole grant several times over.
        uint256 referred = 2e53;
        assertGt(referred, type(uint256).max / GRANT, "the product must not fit in a word");
        assertGt(referred, TARGET, "the partner must have earned the whole grant");

        StubEmissions emissions = new StubEmissions(referred);
        MockERC20 coin = new MockERC20("Feast", "FEAST", 18);
        FeastGenesisGrants grants =
            new FeastGenesisGrants(address(coin), address(emissions), TARGET, partnerList, address(guardian));

        assertEq(grants.grant(), GRANT, "the grant is 0.1% of the platform supply");

        // Genesis funds the grants contract with all eight grants.
        coin.mint(address(grants), GRANT * 8);

        // Week 1 is settled, and the partner's referred fees are counted through the contract's
        // own path. Nothing here is forced into storage: `checkpoint` reads the emissions
        // contract and writes what it is told, exactly as it would in production.
        grants.checkpoint(partner, 1);
        assertEq(grants.referredNative(partner), referred, "the referral is counted");

        // The published rule, evaluated as mathematics: min(grant, grant * referred / target).
        // `grant * referred / target` is about 2e57, so the minimum is the grant itself. The
        // partner has earned all of it and nothing is owed back.
        //
        // The assertion: claiming pays that. It fails — `claim` calls `unlocked`, which panics
        // with 0x11 forming `grant * referred` before the division and before the clamp.
        uint256 before = coin.balanceOf(partner);
        grants.claim(partner);
        assertEq(coin.balanceOf(partner) - before, GRANT, "a fully earned grant is paid in full");
    }
}

/// The three things `FeastGenesisGrants` asks of the emissions contract. `FeastEmissions(addr)` is
/// an address cast, so a contract carrying these selectors stands in for it exactly.
contract StubEmissions {
    uint256 internal immutable referred;

    constructor(uint256 referred_) {
        referred = referred_;
    }

    function settledCount() external pure returns (uint256) {
        return 1;
    }

    function claimsOpen() external pure returns (bool) {
        return true;
    }

    function referredValue(uint256, address) external view returns (uint256) {
        return referred;
    }
}
