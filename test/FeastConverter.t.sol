// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FeastConstants} from "../src/FeastConstants.sol";
import {FeastConverter} from "../src/FeastConverter.sol";
import {IPancakeV3Pool} from "../src/venue/IPancakeV3.sol";

/// The conversion route is the one part of feast that has to work against
/// somebody else's liquidity, so it is tested against the real thing. These are
/// fork tests by necessity: a mock would only prove the mock.
contract FeastConverterForkTest is Test {
    address internal constant V3_FACTORY = 0x0BFbCF9fa4f9C56B0F40a671Ad40E0805A091865;
    address internal constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address internal constant USDT = 0x55d398326f99059fF775485246999027B3197955;
    /// The tokenised stock the survey probed. A placeholder for the production
    /// quote tokens, and labelled as one everywhere it appears.
    address internal constant STOCK = 0x8aD3c73F833d3F9A523aB01476625F269aEB7Cf0;

    /// The deep stablecoin/native pool: cardinality 900, real history.
    address internal constant USDT_WBNB_500 = 0x36696169C63e42cd08ce11f5deeBbCeBae652050;
    /// The stock pool: cardinality 1, so its average *is* its spot price.
    address internal constant STOCK_USDT_2500 = 0x5E12d6EdB2b7D5330e474ea2D2694A3b3E35d492;

    uint256 internal constant FORK_BLOCK = 120_721_477;

    FeastConverter internal converter;

    function setUp() public {
        string memory url = vm.envOr("BSC_RPC_URL", string(""));
        if (bytes(url).length == 0) return;
        vm.createSelectFork(url, FORK_BLOCK);
        converter = new FeastConverter(V3_FACTORY, WBNB, address(this));
    }

    function _forked() internal returns (bool) {
        if (address(converter) == address(0)) {
            vm.skip(true);
            return false;
        }
        return true;
    }

    /// Funding by direct storage write. Foundry's `deal` brute-forces the
    /// balance slot, which over a public archive endpoint means hundreds of
    /// round trips per call; this token's balances live at slot 1, verified
    /// against `balanceOf` at the pinned block.
    function _fundUsdt(address to, uint256 amount) internal {
        vm.store(USDT, keccak256(abi.encode(to, uint256(1))), bytes32(amount));
        assertEq(IERC20(USDT).balanceOf(to), amount, "funding landed in the right slot");
    }

    function _route(address tokenOut, uint24 fee) internal pure returns (FeastConverter.Hop[] memory r) {
        r = new FeastConverter.Hop[](1);
        r[0] = FeastConverter.Hop({tokenOut: tokenOut, fee: fee});
    }

    // --- the leg that works -----------------------------------------------

    /// One real hop, on the real deployment, at a pinned block: stablecoin in,
    /// wrapped native out, priced against the pool's own time-weighted tick.
    function test_fork_aRealStablecoinToNativeHopConverts() public {
        if (!_forked()) return;

        uint256 amountIn = 1_000e18;
        _fundUsdt(address(this), amountIn);
        IERC20(USDT).approve(address(converter), amountIn);

        uint256 before_ = IERC20(WBNB).balanceOf(address(this));
        uint256 out = converter.convert(USDT, amountIn, _route(WBNB, 500), address(this), 0);

        assertGt(out, 0, "the swap produced something");
        assertEq(IERC20(WBNB).balanceOf(address(this)) - before_, out, "and it arrived");
        // Sanity on the magnitude rather than on a hard-coded price: 1000 units
        // of a dollar stablecoin should be somewhere between 0.1 and 10 of the
        // native asset at any plausible price.
        assertGt(out, 0.1e18, "not dust");
        assertLt(out, 10e18, "not absurd");
    }

    function test_fork_theDeepPoolsOracleIsUsable() public {
        if (!_forked()) return;
        (bool priceable,, uint16 cardinality, uint32 age) = converter.hopIsPriceable(USDT, WBNB, 500);
        assertTrue(priceable, "the stablecoin/native pool can be priced");
        assertGe(cardinality, converter.MIN_ORACLE_CARDINALITY(), "it holds a real ring of observations");
        assertGe(age, FeastConstants.MIN_OBSERVATION_AGE, "with real history behind it");
    }

    // --- the leg that must be refused --------------------------------------

    /// The finding that shaped this contract. The stock pool reports a
    /// ten-minute average tick identical to its spot tick, because it holds one
    /// observation. Anything pricing against it is pricing against spot while
    /// believing otherwise — so the hop is refused rather than trusted.
    function test_fork_aPoolWhoseAverageIsItsSpotPriceIsRefused() public {
        if (!_forked()) return;

        (,int24 spotTick,, uint16 cardinality,,,) = IPancakeV3Pool(STOCK_USDT_2500).slot0();
        assertEq(cardinality, 1, "the pool holds exactly one observation");

        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = 600;
        secondsAgos[1] = 0;
        (int56[] memory c,) = IPancakeV3Pool(STOCK_USDT_2500).observe(secondsAgos);
        assertEq(int24((c[1] - c[0]) / 600), spotTick, "its ten-minute average IS its spot tick");

        (bool priceable,,, uint32 age) = converter.hopIsPriceable(STOCK, USDT, 2500);
        assertFalse(priceable, "so the converter will not price it");

        // Worth being precise about *which* check catches this. The single
        // observation is old — some fifty minutes at this block — so an
        // age-only test would pass it happily and then average a window that
        // contains one point. Cardinality is what catches it, and this is why
        // both are checked rather than either.
        assertGe(age, FeastConstants.MIN_OBSERVATION_AGE, "the lone observation is not young");

        // No stock balance is needed: the route is validated before anything
        // moves, so the refusal lands before the transfer would have.
        uint256 amountIn = 1e15;

        FeastConverter.Hop[] memory route = new FeastConverter.Hop[](2);
        route[0] = FeastConverter.Hop({tokenOut: USDT, fee: 2500});
        route[1] = FeastConverter.Hop({tokenOut: WBNB, fee: 500});

        vm.expectRevert(
            abi.encodeWithSelector(FeastConverter.OracleUnusable.selector, STOCK_USDT_2500, uint16(1), age)
        );
        converter.convert(STOCK, amountIn, route, address(this), 0);
    }

    // --- route shape -------------------------------------------------------

    function test_fork_aRouteThatDoesNotEndInNativeIsRefused() public {
        if (!_forked()) return;
        _fundUsdt(address(this), 1e18);
        IERC20(USDT).approve(address(converter), 1e18);
        vm.expectRevert(abi.encodeWithSelector(FeastConverter.RouteMustEndInNative.selector, USDT));
        converter.convert(WBNB, 1e18, _route(USDT, 500), address(this), 0);
    }

    function test_fork_anEmptyRouteIsRefused() public {
        if (!_forked()) return;
        FeastConverter.Hop[] memory empty = new FeastConverter.Hop[](0);
        vm.expectRevert(FeastConverter.EmptyRoute.selector);
        converter.convert(USDT, 1e18, empty, address(this), 0);
    }

    function test_fork_aNonexistentPoolIsRefusedByName() public {
        if (!_forked()) return;
        _fundUsdt(address(this), 1e18);
        IERC20(USDT).approve(address(converter), 1e18);
        // No pool at this fee tier for this pair.
        vm.expectRevert(abi.encodeWithSelector(FeastConverter.NoPoolForHop.selector, USDT, WBNB, uint24(9_999)));
        converter.convert(USDT, 1e18, _route(WBNB, 9_999), address(this), 0);
    }

}
