// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {FeastConverter} from "../../../src/FeastConverter.sol";
import {FeastHook} from "../../../src/FeastHook.sol";
import {PoolKey} from "../../../src/venue/PoolKey.sol";
import {ISwapCallback} from "../../utils/MockV3Pool.sol";
import {FeastAccountingTest} from "../../FeastAccounting.t.sol";

/// A v3-shaped pool that is HOSTILE, and is registered in the factory the
/// converter trusts — which is a stronger attacker than the chain can field: a
/// real route pool comes from PancakeSwap's own factory and runs PancakeSwap's
/// own code, so the only way back into feast from inside a real swap is a token
/// transfer hook. Modelling the pool itself as the attacker covers that case
/// and every other, because the pool sees and controls everything a token
/// callback could.
///
/// Price 1:1, a history old enough to vouch for it, spot on its own average,
/// so every check `_validateHop` makes passes and the swap is reached.
contract ReenteringPool {
    address public immutable token0;
    address public immutable token1;
    uint160 public constant sqrtPriceX96 = 79_228_162_514_264_337_593_543_950_336;
    uint32 public immutable oldestTimestamp;

    /// What the swap does besides swapping.
    enum Mode {
        Honest,
        Reenter,
        PullTwice,
        PullAnotherToken
    }

    Mode public mode;
    address public reentryTarget;
    bytes public reentryCall;
    bool public reentryOk;
    bytes public reentryReturn;
    address public otherToken;
    uint256 public otherAmount;

    constructor(address a, address b) {
        (token0, token1) = a < b ? (a, b) : (b, a);
        oldestTimestamp = uint32(block.timestamp - 1 hours);
    }

    function arm(Mode m, address target, bytes calldata data) external {
        mode = m;
        reentryTarget = target;
        reentryCall = data;
    }

    function armPull(address token, uint256 amount) external {
        mode = Mode.PullAnotherToken;
        otherToken = token;
        otherAmount = amount;
    }

    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint32, bool) {
        return (sqrtPriceX96, 0, 0, 100, 100, 0, true);
    }

    function observations(uint256) external view returns (uint32, int56, uint160, bool) {
        return (oldestTimestamp, 0, 0, true);
    }

    function observe(uint32[] calldata) external pure returns (int56[] memory c, uint160[] memory s) {
        c = new int56[](2);
        s = new uint160[](2);
    }

    function swap(address recipient, bool zeroForOne, int256 amountSpecified, uint160, bytes calldata data)
        external
        returns (int256 amount0, int256 amount1)
    {
        uint256 amountIn = uint256(amountSpecified);
        (address tokenIn, address tokenOut) = zeroForOne ? (token0, token1) : (token1, token0);
        // 1:1, the full amount: the price every check was just made against.
        IERC20(tokenOut).transfer(recipient, amountIn);
        (amount0, amount1) = zeroForOne ? (int256(amountIn), -int256(amountIn)) : (-int256(amountIn), int256(amountIn));

        if (mode == Mode.Reenter) {
            (reentryOk, reentryReturn) = reentryTarget.call(reentryCall);
        }
        uint256 owedToPool = IERC20(tokenIn).balanceOf(address(this)) + amountIn;
        if (mode == Mode.PullAnotherToken) {
            // Ask the converter for a token this hop never brought, under the
            // hop's own allowance, before asking for what it did bring.
            ISwapCallback(msg.sender).pancakeV3SwapCallback(int256(otherAmount), 0, abi.encode(otherToken));
        }
        ISwapCallback(msg.sender).pancakeV3SwapCallback(amount0, amount1, data);
        if (mode == Mode.PullTwice) ISwapCallback(msg.sender).pancakeV3SwapCallback(amount0, amount1, data);
        require(IERC20(tokenIn).balanceOf(address(this)) >= owedToPool, "not paid");
    }
}

/// **`reentrancy-balance`** — `CA-06f26997ef`, slither HIGH (untriaged), at
/// `src/FeastConverter.sol:364-444` `_hop`.
///
/// The claim: the v3 swap callback can re-enter the converter, `claimAsBnb` has
/// no `nonReentrant`, and the `spent > amountIn` check at `:437` reads `heldIn`
/// from before the swap, so a balance the callback moved could reach it.
///
/// What a re-entrant call CAN move, stated precisely, and each line below is a
/// test:
///   - **its own caller's own entitlement, and nothing else of anybody's.**
///     `claimAsBnb` is the claimant's call alone (`msg.sender == account`), so a
///     re-entrant `claimAsBnb` for somebody else is `RouteIsTheClaimantsToChoose`,
///     and `convert` is the hook's alone (`NotTheHook`). The plain `claim` pays
///     an account in its own token, to itself, which moves nothing to anyone
///     else. And the hook debits the ledger BEFORE it releases, so re-entering
///     one's own claim finds nothing left to pay.
///   - **nothing of the conversion in flight beyond what the hop brought.** The
///     callback pays at most `_activeBrought`, and `:437` is not stale: `nowIn`
///     is read AFTER the swap returns, so a second pull of the input — even one
///     funded by a stray balance sitting in the converter — makes `spent`
///     exceed `amountIn` and the whole conversion reverts `AskExceedsHop`.
///   - **no stray balance of any OTHER token either**, on net. A pull of a token
///     the hop never brought is taken out of what the hop must deliver:
///     `nowOut - heldOut` is measured, so the stray comes back inside the swap's
///     own output, the claimant is paid what arrived net of it, and the route
///     floor bounds that at `MAX_ROUTE_DEVIATION_BPS` of the claim — exactly the
///     bound a pool that simply paid less already had.
///
/// What it cannot do at all: move another claimant's balance, spend a stray,
/// or push a conversion past the route floor the claimant accepted. A re-entry
/// that clobbers `_activePool` before the outer pool's callback only makes that
/// callback `NotThePool` — the attacker's own transaction reverts.
///
/// Run at `v1.6.21-audit` (`e5c0a77`): **green**. Nothing here needed a fix, so
/// the file is kept as the regression witness for the row.
///
/// v1.6.24 (AstraSec I-7) puts a re-entrancy guard on `claimAsBnb` and four
/// siblings anyway, as depth: the re-entrant `claimAsBnb` below is now refused
/// by the guard one step before `RouteIsTheClaimantsToChoose` would refuse it.
/// `test/audit/astrasec/I7_GuardedEntryPoints.t.sol` re-enters all five.
contract ConverterReentrancyTest is FeastAccountingTest {
    ReenteringPool internal hostile;
    uint24 internal constant HOSTILE_FEE = 3_000;

    /// @dev Not a `setUp` override: the parent's is not virtual, and a hostile
    ///      pool is wired on top of it, the same in every test here.
    function _wireTheHostilePool() internal {
        hostile = new ReenteringPool(address(quote), address(wbnb));
        v3Factory.set(address(quote), address(wbnb), HOSTILE_FEE, address(hostile));
        wbnb.mint(address(hostile), 1_000_000e18);
        // Two claimants: the creator, who converts through the hostile pool, and
        // a referrer, whose entitlement is the thing a re-entry would want.
        _buy(-50_000e18, abi.encode(referrer));
    }

    function _hostileRoute() internal pure returns (FeastConverter.Hop[] memory route) {
        route = new FeastConverter.Hop[](1);
        route[0] = FeastConverter.Hop({tokenOut: address(0), fee: HOSTILE_FEE});
    }

    function _route() internal view returns (FeastConverter.Hop[] memory route) {
        route = _hostileRoute();
        route[0].tokenOut = address(wbnb);
    }

    /// A re-entry for SOMEBODY ELSE's claim, and one straight into the
    /// converter, from inside the creator's own conversion. Both are refused by
    /// name; the creator's conversion completes; the referrer's entitlement is
    /// exactly where it was.
    function test_aReentrantCallCannotMoveAnotherClaimantsEntitlement() public {
        _wireTheHostilePool();
        uint256 creatorOwed = hook.claimable(key, creator);
        uint256 referrerOwed = hook.claimable(key, referrer);
        assertGt(creatorOwed, 0, "the creator has a claim to convert");
        assertGt(referrerOwed, 0, "and the referrer has one a re-entry would want");

        hostile.arm(
            ReenteringPool.Mode.Reenter,
            address(hook),
            abi.encodeCall(FeastHook.claimAsBnb, (key, referrer, _route(), 0))
        );
        vm.prank(creator);
        uint256 out = hook.claimAsBnb(key, creator, _route(), 0);
        assertFalse(hostile.reentryOk(), "a re-entrant claim for another account went through");
        // v1.6.24 (AstraSec I-7): refused one step earlier now, by the hook's
        // re-entrancy guard, before `RouteIsTheClaimantsToChoose` is reached —
        // which still refuses the same call made from outside a conversion.
        assertEq(
            bytes4(hostile.reentryReturn()),
            FeastHook.ReentrancyGuardReentrantCall.selector,
            "refused by the re-entrancy guard"
        );
        assertEq(hook.claimable(key, referrer), referrerOwed, "the referrer's entitlement moved");
        assertEq(wbnb.balanceOf(creator), out, "the creator was paid their own conversion");
        assertEq(hook.claimable(key, creator), 0, "exactly once");

        // Straight into the converter, from inside a later conversion.
        _buy(-50_000e18, "");
        hostile.arm(
            ReenteringPool.Mode.Reenter,
            address(converter),
            abi.encodeCall(FeastConverter.convert, (address(quote), 1, _route(), address(hostile), 0))
        );
        vm.prank(creator);
        hook.claimAsBnb(key, creator, _route(), 0);
        assertFalse(hostile.reentryOk(), "a re-entrant convert went through");
        assertEq(bytes4(hostile.reentryReturn()), FeastConverter.NotTheHook.selector, "refused: the hook's alone");
        assertEq(hook.claimable(key, referrer), referrerOwed, "and the referrer's entitlement is still untouched");
    }

    /// The `:437` check the finding calls stale, given something to catch: a
    /// stray balance of the input token in the converter, and a pool that asks
    /// for the hop's amount TWICE. The second ask is inside the callback's own
    /// per-call bound, and the stray can fund it — which is exactly why the hop
    /// measures what it SPENT after the swap returns.
    function test_aPoolThatPullsTwiceCannotSpendAStrayBalance() public {
        _wireTheHostilePool();
        uint256 owed = hook.claimable(key, creator);
        quote.mint(address(converter), owed); // a stray, as large as the claim
        uint256 stray = quote.balanceOf(address(converter));

        hostile.arm(ReenteringPool.Mode.PullTwice, address(0), "");
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(FeastConverter.AskExceedsHop.selector, address(quote), 2 * owed, owed));
        hook.claimAsBnb(key, creator, _route(), 0);

        assertEq(quote.balanceOf(address(converter)), stray, "the stray balance was spent");
        assertEq(hook.claimable(key, creator), owed, "and the claim is still owed, whole");
    }

    /// A pull of a token the hop never brought — a stray WBNB balance in the
    /// converter — under the hop's own allowance. It comes back out of what the
    /// hop must deliver: the stray stays where it was, and the claimant is paid
    /// what arrived net of the pull, inside the route floor they accepted.
    function test_aPoolThatPullsAnotherTokenLeavesTheStrayWhereItWas() public {
        _wireTheHostilePool();
        uint256 owed = hook.claimable(key, creator);
        uint256 stray = owed / 100; // 1% of the claim: inside the route floor's 3%
        wbnb.mint(address(converter), stray);

        hostile.armPull(address(wbnb), stray);
        vm.prank(creator);
        uint256 out = hook.claimAsBnb(key, creator, _route(), 0);

        assertEq(wbnb.balanceOf(address(converter)), stray, "the stray WBNB left the converter");
        assertEq(out, owed - stray, "the claimant is paid what arrived, net of the pull");
        assertGe(
            out,
            owed * (10_000 - converter.MAX_ROUTE_DEVIATION_BPS()) / 10_000,
            "and never below the route floor the claimant accepted"
        );

        // Past the route floor, the same pull is refused rather than paid.
        _buy(-50_000e18, "");
        owed = hook.claimable(key, creator);
        wbnb.mint(address(converter), owed / 10);
        hostile.armPull(address(wbnb), owed / 10 + stray);
        vm.prank(creator);
        vm.expectPartialRevert(FeastConverter.RouteReturnedTooLittle.selector);
        hook.claimAsBnb(key, creator, _route(), 0);
        assertEq(wbnb.balanceOf(address(converter)), stray + owed / 10, "and nothing left the converter");
    }
}
