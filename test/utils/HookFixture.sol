// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {FeastConstants} from "../../src/FeastConstants.sol";
import {FeastConverter} from "../../src/FeastConverter.sol";
import {FeastFeeLedger} from "../../src/FeastFeeLedger.sol";
import {FeastGuardian} from "../../src/FeastGuardian.sol";
import {FeastHook} from "../../src/FeastHook.sol";
import {FeastReferrals} from "../../src/FeastReferrals.sol";
import {FeastOracle} from "../../src/FeastOracle.sol";
import {Currency} from "../../src/venue/Currency.sol";
import {IFeastCLHooks} from "../../src/venue/IFeastCLHooks.sol";
import {PoolId, PoolIdLibrary} from "../../src/venue/PoolId.sol";
import {PoolKey} from "../../src/venue/PoolKey.sol";

import {Vault} from "infinity-core/src/Vault.sol";
import {CLPoolManager} from "infinity-core/src/pool-cl/CLPoolManager.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {CustomRevert} from "infinity-core/src/libraries/CustomRevert.sol";
import {Hooks} from "infinity-core/src/libraries/Hooks.sol";

import {MockERC20} from "./MockERC20.sol";
import {PoolRouter} from "./PoolRouter.sol";
import {VenueBridge} from "./VenueBridge.sol";

/// @dev The hook, really wired to a real ledger and oracle, with THIS contract
///      standing in for the factory — so a test can register pools with any
///      gate, and answer the hook's `platformSink()` question itself. Every v1.6
///      hook suite starts here; testing rule 2 holds (no collaborator is zero).
abstract contract HookFixture is Test {
    using PoolIdLibrary for PoolKey;
    using VenueBridge for PoolKey;

    uint160 internal constant SQRT_PRICE_1_1 = 79_228_162_514_264_337_593_543_950_336;
    uint160 internal constant MIN_SQRT = 4_295_128_739 + 1;
    uint160 internal constant MAX_SQRT = 1_461_446_703_485_210_103_287_273_052_203_988_822_378_723_970_342 - 1;

    address internal creator = address(0xC0FFEE);
    address internal trader = address(0x7EADE1);
    address internal referrer = address(0xEE01);

    Vault internal vault;
    CLPoolManager internal pm;
    PoolRouter internal router;
    PoolRouter internal openerRouter;
    FeastOracle internal oracle;
    FeastFeeLedger internal ledger;
    FeastGuardian internal guardian;
    FeastHook internal hook;
    FeastReferrals internal referrals;

    /// @dev What this stand-in factory reports as the platform sink and coin.
    address public platformSink;
    address public platformCoin = address(0xFEA57);

    MockERC20 internal coin;
    MockERC20 internal quote;
    PoolKey internal key;
    bool internal coinIsCurrency0;

    uint256 internal clock;

    function setUp() public virtual {
        clock = 1_791_158_400 + 1 days; // a Tuesday; ledger weeks turn on Mondays
        vm.warp(clock);
        vault = new Vault();
        pm = new CLPoolManager(vault);
        vault.registerApp(address(pm));
        router = new PoolRouter(vault, pm);
        openerRouter = new PoolRouter(vault, pm);

        // Every collaborator real, none zero (testing rule 2; round 2, L4).
        guardian = new FeastGuardian(address(0x3517), address(this));
        // The referral registry (v1.6.26) has no constructor and no immutables, so
        // its deployed code is the whole of it: etched, it spends none of this
        // contract's nonce — under `isolate` even `deployCodeTo`'s constructor call
        // is a transaction that moves it — and every address below, the tokens' and
        // the platform coin's CREATE2 draw included, is the one it was before.
        referrals = FeastReferrals(address(uint160(uint256(keccak256("feast.referrals")))));
        vm.etch(address(referrals), vm.getDeployedCode("FeastReferrals.sol:FeastReferrals"));
        address predictedHook = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 3);
        oracle = new FeastOracle(predictedHook);
        ledger = new FeastFeeLedger(predictedHook);
        FeastConverter converter = new FeastConverter(address(0xF3), address(0xB4B), predictedHook);
        hook =
            new FeastHook(address(pm), address(vault), address(this), address(oracle), address(ledger), address(converter),
            address(guardian), address(referrals), new FeastHook.TipFloor[](0));
        assertEq(address(hook), predictedHook, "hook wiring");
    }

    function _advance(uint256 s) internal {
        clock += s;
        vm.warp(clock);
        vm.roll(vm.getBlockNumber() + 1);
    }

    /// @dev Register and initialise a pool with deep liquidity placed by an
    ///      ordinary router, then step past the opening cap's blocks.
    function _pool(address creator_, uint16 selfBurnBps, uint16 referrerBps, uint64 openAt, address opener) internal {
        _poolAgainst(new MockERC20("Quote", "Q", 18), creator_, selfBurnBps, referrerBps, openAt, opener);
    }

    function _poolAgainst(
        MockERC20 quote_,
        address creator_,
        uint16 selfBurnBps,
        uint16 referrerBps,
        uint64 openAt,
        address opener
    ) internal {
        _poolAt(quote_, creator_, selfBurnBps, referrerBps, openAt, opener, 0);
    }

    /// @dev As `_poolAgainst`, opening at a chosen quote-per-coin price given as
    ///      `sqrtPriceCoinX96` (the square-root price of the coin in quote);
    ///      zero means 1:1.
    function _poolAt(
        MockERC20 quote_,
        address creator_,
        uint16 selfBurnBps,
        uint16 referrerBps,
        uint64 openAt,
        address opener,
        uint160 sqrtPriceCoinX96
    ) internal {
        _poolAt(quote_, creator_, selfBurnBps, referrerBps, openAt, opener, sqrtPriceCoinX96, 100_000_000e18);
    }

    /// @dev The same, with the position's liquidity chosen: a pool priced far
    ///      from one needs far less liquidity to hold a realistic amount of
    ///      quote.
    function _poolAt(
        MockERC20 quote_,
        address creator_,
        uint16 selfBurnBps,
        uint16 referrerBps,
        uint64 openAt,
        address opener,
        uint160 sqrtPriceCoinX96,
        uint128 liquidity
    ) internal {
        coin = new MockERC20("Coin", "COIN", 18);
        quote = quote_;
        (address c0, address c1) =
            address(coin) < address(quote) ? (address(coin), address(quote)) : (address(quote), address(coin));
        coinIsCurrency0 = c0 == address(coin);
        key = PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            hooks: address(hook),
            poolManager: address(pm),
            fee: FeastConstants.POOL_LP_FEE,
            parameters: hook.poolParameters()
        });
        hook.registerPool(key, address(coin), creator_, selfBurnBps, referrerBps, 1_000_000_000e18, openAt, opener);
        uint160 initial = SQRT_PRICE_1_1;
        if (sqrtPriceCoinX96 != 0) {
            // The venue's price is token1 per token0; invert when the coin is token1.
            initial = coinIsCurrency0 ? sqrtPriceCoinX96 : uint160((uint256(1) << 192) / sqrtPriceCoinX96);
        }
        pm.initialize(key.up(), initial);

        coin.mint(address(router), 1_000_000_000e18);
        quote.mint(address(router), 1_000_000_000e18);
        coin.mint(address(openerRouter), 1_000_000_000e18);
        quote.mint(address(openerRouter), 1_000_000_000e18);
        router.modifyLiquidity(
            key.up(),
            ICLPoolManager.ModifyLiquidityParams({
                tickLower: -887_200,
                tickUpper: 887_200,
                liquidityDelta: int256(uint256(liquidity)),
                salt: bytes32(0)
            })
        );
        vm.roll(vm.getBlockNumber() + FeastConstants.CAP_BLOCKS);
    }

    function _buyDirection() internal view returns (bool) {
        return !coinIsCurrency0;
    }

    /// @dev One of the four fee branches, by index: 0 buy exact-in, 1 buy
    ///      exact-out, 2 sell exact-in, 3 sell exact-out.
    function _branch(PoolRouter via, uint256 branch, address origin, bytes memory hookData) internal {
        bool buy = branch < 2;
        bool exactIn = branch % 2 == 0;
        bool zeroForOne = buy ? _buyDirection() : !_buyDirection();
        vm.prank(origin, origin);
        via.swap(
            key.up(),
            ICLPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: exactIn ? -int256(1_000e18) : int256(900e18),
                sqrtPriceLimitX96: zeroForOne ? MIN_SQRT : MAX_SQRT
            }),
            hookData
        );
    }

    function _referral(address r) internal pure returns (bytes memory) {
        return abi.encode(r);
    }

    function _quote() internal view returns (address) {
        return address(quote);
    }

    /// @dev The venue wraps anything a hook reverts with in `beforeSwap`.
    function _expectHookRevert(bytes memory reason) internal {
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IFeastCLHooks.beforeSwap.selector,
                reason,
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
    }
}
