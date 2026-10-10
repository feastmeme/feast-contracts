// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {Currency} from "../../../src/venue/Currency.sol";
import {PoolKey} from "../../../src/venue/PoolKey.sol";
import {MockERC20} from "../../utils/MockERC20.sol";
import {VenueBridge} from "../../utils/VenueBridge.sol";
import {UnitFixture} from "../../utils/UnitFixture.sol";

/// PoC for the v1.6.9 pack's HIGH `hook:hk23` — the defect SEVEN lens units reported under
/// seven class slugs, across both the triage round and the hunter layer:
///
///   r1h-claude   HIGH    hook checklist HK23, src/FeastHook.sol:456
///   r1h2-claude  HIGH    bound-referrer-on-gated-swap, src/FeastHook.sol:461
///   r1a-claude   MEDIUM  gated-swap-referrer, src/FeastHook.sol:456
///   HK23-claude  MEDIUM  gated-settle-pays-bound-referrer, src/FeastHook.sol:543
///   P10-claude   MEDIUM  settlement-pays-settlers-referrer, src/FeastHook.sol:461
///   P11-claude   MEDIUM  bound-settler-commission, src/FeastHook.sol:543
///   P12-claude   MEDIUM  settler-referral-skim, src/FeastHook.sol:543
///
/// The launch window buys the whole pot in ONE swap through the hook, and that swap pays the
/// 1% fee like any other. `_referrerFor` decides who is credited the referrer share, and its
/// first rule is supreme:
///
///     // src/FeastHook.sol:456-462
///     address origin = tx.origin;
///     address bound = _referrerOf[origin];
///     if (bound != address(0)) return bound;
///
/// On the settlement swap `tx.origin` is whoever called `settle()`. `settle()` is permissionless
/// — it has to be, or the launch could be withheld. So any wallet that has ever bound a referrer
/// can call `settle()` and hand `referrerBps` of the fee on the WHOLE pot to its own referrer,
/// for introducing nobody to this trade. The pot is every committer's BNB, not the settler's.
///
/// `docs/referrer-binding.md` promises the binding "routes the referred track into emissions and
/// grant unlocks" for the bound wallet's OWN later trades. Nothing declares that pressing a
/// public button monetises other people's commitments. The race is winnable by anyone: the
/// settle window is an hour wide and the reward is fixed at settlement time.
///
/// The test binds a settler to a referrer on an ordinary pool, lets that settler press
/// `settle()`, and asserts the referrer earned nothing from the window's swap.
contract SettlementReferrerSkimPoC is UnitFixture {
    using VenueBridge for PoolKey;

    address internal settler = address(0x5E77);
    address internal freeloader = address(0xF2EE);

    /// @dev The 64-byte binding form: `abi.encode(referrer, wallet)`, with `tx.origin == wallet`.
    ///      `UnitFixture._buy` sends the 32-byte per-trade form, which binds nothing.
    function _bindingBuy(PoolKey memory key, address quote, uint256 quoteIn, address origin, bytes memory hookData)
        internal
    {
        MockERC20(quote).mint(address(router), quoteIn);
        bool zeroForOne = Currency.unwrap(key.currency0) == quote;
        vm.prank(origin, origin);
        router.swap(
            key.up(),
            ICLPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(quoteIn),
                sqrtPriceLimitX96: zeroForOne ? MIN_SQRT : MAX_SQRT
            }),
            hookData
        );
    }

    function test_theWindowsSettlementPaysNoCommissionToWhoeverPressedTheButton() public {
        _genesis();

        // The settler binds itself to `freeloader` — since v1.6.26 in the registry, by its own
        // call — and trades an ORDINARY pool, the ordinary way.
        (, PoolKey memory coinKey) = _create(address(wbnb), bytes32("skim"));
        vm.prank(settler);
        referrals.bind(freeloader);
        _bindingBuy(coinKey, address(wbnb), 1_000e18, settler, abi.encode(freeloader, settler));
        assertEq(referrals.referrerOf(settler), freeloader, "the settler is bound");

        // An ordinary launch window: somebody else's BNB.
        _warpTo(windowStart + 1);
        address committer = address(0xC0D1);
        vm.deal(committer, 100 ether);
        vm.prank(committer);
        window.commit{value: 100 ether}();

        uint256 earnedBefore = hook.claimable(feastKey, freeloader);

        // Anyone may settle. The settler is bound; it presses the button.
        _warpTo(window.endsAt());
        vm.prank(settler, settler);
        window.settle();

        uint256 earnedAfter = hook.claimable(feastKey, freeloader);

        // The witness has to reach its bound. This assertion is the one that fails today, so it
        // plainly reaches it — but it must not be able to pass VACUOUSLY later, if a fix made
        // `settle()` revert or take no fee at all. So: the settlement really happened, and the
        // referrer seat really is the one the fee would land in. (The platform pool's creator
        // seat is the burn address by construction, so it is not usable as the fee witness.)
        assertTrue(window.settled(), "the window did not settle, so this test witnesses nothing");
        assertGt(
            hook.claimable(coinKey, freeloader),
            0,
            "the referrer seat accrues nothing even on the binding trade, so this test witnesses nothing"
        );

        // 10% of the 1% fee on a 100 BNB pot is 0.1 BNB. Measured today: 99009900990099009 wei
        // to a wallet that introduced nobody to this trade.
        assertEq(
            earnedAfter - earnedBefore,
            0,
            "the window's settlement paid a referral commission on the whole pot to the settler's referrer"
        );
    }
}
