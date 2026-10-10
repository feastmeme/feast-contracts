// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {UnitFixture} from "../../utils/UnitFixture.sol";

/// **`stranded-quote` / `stranded-dust`** — r2 (v1.6.26, `57eadbc`). `U5b` (Codex) reports it
/// HIGH at `src/FeastLaunchWindow.sol:329`, by the brief's literal bar that breaking a stated
/// invariant is HIGH (`audit/invariants.yaml` P22: "Nothing the settlement does not place is
/// left owned by nothing"). `U5-claude` (Claude) reports the same defect LOW at
/// `src/FeastFactory.sol:936-940`: "value is negligible; the claim is the defect".
///
/// On a clearing settle the window sends the whole net pot to the hook, the hook pays the venue
/// only the position's rounded-up quote debt, and `_burnUnplaced` disposes of the COIN
/// remainder only. The quote remainder stays in the hook as an ERC-20 balance nothing moves:
/// about 937 wei on a 1 ether pot (Codex's figure), up to about 1e6 wei on a very large one.
/// `test/FeastWindowAuction.t.sol` already tolerates it ("the seeding dust is dust", < 1e6).
///
/// **v1.6.27: P22 is amended and the code is not** (the owner's ruling of 4 October 2026 on
/// `CA-a364c3530f`). On `57eadbc` this asserted P22 as then written — no quote left at all — and
/// FAILED by the dust, 937 wei. P22 now tolerates rounding dust of at most 1e6 wei of quote for any
/// pot up to 1,000,000 BNB, the bound the window's own test already allowed; this asserts that
/// bound and keeps recording the dust. `test/FeastWindowAuction.t.sol` fuzzes it across the
/// range and reaches it at the top. The name is the proof ledger's id and is kept.
contract SettleLeavesQuoteInTheHookTest is UnitFixture {
    address internal constant ALICE = address(0xA11CE);

    function test_aClearingSettleLeavesNoQuoteOwnedByNothing() public {
        _genesis();
        _warpTo(windowStart + 1);
        vm.deal(ALICE, 1 ether);
        vm.prank(ALICE);
        window.commit{value: 1 ether}();
        _warpTo(window.endsAt());

        uint256 before_ = wbnb.balanceOf(address(hook));
        window.settle();
        assertGt(window.tranche(), 0, "precondition: the pot cleared and a tranche sold");
        uint256 left = wbnb.balanceOf(address(hook)) - before_;
        emit log_named_uint("quote left in the hook, wei", left);
        assertLe(left, 1e6, "more than rounding dust of quote is left in the hook, owned by nothing");
    }
}
