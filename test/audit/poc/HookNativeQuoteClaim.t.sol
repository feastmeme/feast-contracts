// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {FeastConverter} from "../../../src/FeastConverter.sol";
import {FeastHook} from "../../../src/FeastHook.sol";
import {PoolKey} from "../../../src/venue/PoolKey.sol";
import {UnitFixture} from "../../utils/UnitFixture.sol";

/// PoC for the v1.6.6 dual-family pack's `wrapped-native-claim`, reported by **both** families:
/// the codex coverage unit (`r1a2`, MEDIUM, `src/FeastHook.sol:990-1001`), the codex hook unit
/// (`r1h2`, MEDIUM, `src/FeastHook.sol:995-1001`) and the Claude coverage unit (`r1a2-claude`,
/// LOW, `src/FeastHook.sol:981-1002`). Three reports, two families, one defect.
///
/// The claim: `claimAsBnb` cannot serve a pool whose quote already IS wrapped native, because the
/// converter's accepted route set is empty for that input:
///
///   - an empty route is refused                    `FeastConverter.sol:190`
///   - every route must END in wrapped native       `FeastConverter.sol:200-202`
///   - any hop whose output is the INPUT token      `FeastConverter.sol:194-195`
///
/// The last two cannot both be satisfied when the input is wrapped native, and the revisit check
/// runs first, so the one-hop route that would otherwise be right reverts before any pool is
/// looked at.
///
/// **Wrapped native is an ordinary accepted quote** — `FeastFactory.sol:186` — and the platform
/// coin's own pool is quoted in it (`FeastFactory.sol:268`), so the coin every one of these
/// contracts exists to pay out is on the one quote this entry point cannot serve. The advertised
/// behaviour is at `docs/interface.md:181-184` and the natspec at `FeastHook.sol:975-976` names
/// no exception.
///
/// Nothing is stranded: plain `claim` pays the same wrapped native, which is why both codex units
/// called this MEDIUM and the Claude unit LOW. What fails is the documented convenience path.
contract HookNativeQuoteClaimPoC is UnitFixture {
    address internal coinA;
    PoolKey internal keyA;

    function setUp() public override {
        super.setUp();
        (coinA, keyA) = _create(address(wbnb), bytes32(uint256(1)));
        _buy(keyA, address(wbnb), 100e18, trader, referrer);
    }

    /// The defect. A creator with a wrapped-native entitlement asks for it through the documented
    /// entry point and cannot have it, by any route.
    function test_claimAsBnbPaysAnAlreadyWrappedNativeClaim() public {
        uint256 owed = hook.claimable(keyA, creator);
        assertGt(owed, 0, "the creator has something to claim");
        uint256 before_ = IERC20(address(wbnb)).balanceOf(creator);

        vm.prank(creator);
        uint256 out = hook.claimAsBnb(keyA, creator, new FeastConverter.Hop[](0), 0);

        assertEq(out, owed, "the claim is paid in full");
        assertEq(IERC20(address(wbnb)).balanceOf(creator) - before_, owed, "and it arrives");
        assertEq(hook.claimable(keyA, creator), 0, "and is settled exactly once");
    }

    /// The other half of "no route works". BEFORE the fix this asserted a refusal: the one-hop
    /// route to wrapped native — the route a caller would obviously try — reverted with
    /// `RouteRevisitsAToken` before any pool was read, because its output is the input token.
    /// Together with the empty route above that was the whole accepted set, and it was empty.
    ///
    /// AFTER the fix there is no route left to refuse: a native-quoted claim is paid in the token
    /// it already is, and what the caller passed is not consulted. So this now asserts the same
    /// payment through the same call with a non-empty route, which is the property that matters —
    /// no argument a claimant can supply makes this entry point unusable on their own pool.
    /// `FeastHook.claimAsBnb`'s natspec says the route is ignored for this quote.
    function test_andTheOneHopRouteACallerWouldTryIsPaidTheSameWay() public {
        FeastConverter.Hop[] memory one = new FeastConverter.Hop[](1);
        one[0] = FeastConverter.Hop({tokenOut: address(wbnb), fee: 100});

        uint256 owed = hook.claimable(keyA, creator);
        uint256 before_ = IERC20(address(wbnb)).balanceOf(creator);

        vm.prank(creator);
        uint256 out = hook.claimAsBnb(keyA, creator, one, 0);

        assertEq(out, owed, "paid in full, whatever the route said");
        assertEq(IERC20(address(wbnb)).balanceOf(creator) - before_, owed, "and it arrives");
    }

    /// The control is an EXISTING test, not one written here:
    /// `test/FeastAccounting.t.sol::FeastAccountingTest::test_aClaimantMayTakeTheirOwnClaimInTheChainsAsset`
    /// makes the same call, through the same entry point, on a pool quoted in an ordinary token,
    /// and it passes on this tree. So the refusal above is about the NATIVE quote and not about
    /// `claimAsBnb`.
    ///
    /// It is cited rather than copied because this fixture cannot host it: `UnitFixture` builds
    /// the converter over a dead v3 factory (`test/utils/UnitFixture.sol:107`), so no conversion
    /// can succeed here at all. A control written in this suite would have failed for a reason
    /// that has nothing to do with the finding — which is what the first draft of this file did,
    /// and a control that fails proves nothing.
    function test_theControlForThisFindingLivesInTheAccountingSuite() public pure {
        // Deliberately empty: the assertion is the citation above, and a test that
        // re-implemented it here would be asserting something this fixture cannot reach.
    }
}
