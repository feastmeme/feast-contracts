// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FeastConstants} from "../src/FeastConstants.sol";
import {FeastConverter} from "../src/FeastConverter.sol";
import {IPancakeV3Pool} from "../src/venue/IPancakeV3.sol";

/// The production route, end to end, against the real tokens.
///
/// `tools/discover_quotes.py` identified these addresses by symbol and then
/// verified each one on chain at the pinned block; the tool's output is what
/// picks them, and re-pointing this file is a matter of changing the constants
/// below. Both a two-hop and a single-hop route are exercised, because the
/// survey's conclusion that no stock/native pool exists turns out not to hold
/// for this family.
contract FeastConverterRealQuoteTest is Test {
    address internal constant V3_FACTORY = 0x0BFbCF9fa4f9C56B0F40a671Ad40E0805A091865;
    address internal constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address internal constant USDT = 0x55d398326f99059fF775485246999027B3197955;

    // --- the quote tokens under test (swap these to re-point) -------------
    address internal constant AAPLB = 0x431a3BEE82E2ca41e49895CbECE5bB0F76A89b7A;
    address internal constant AAPLB_USDT_2500 = 0xe9b9998B2EC5430D2246c7f1F8D9f298c97D7365;
    uint24 internal constant AAPLB_USDT_FEE = 2500;

    address internal constant QQQB = 0x205812CdBed920aFf76C6580abD681a46D11efc7;
    address internal constant QQQB_WBNB_500 = 0x47BC06722295AC316A569EEF87aC32FAA455F441;
    uint24 internal constant QQQB_WBNB_FEE = 500;

    uint256 internal constant FORK_BLOCK = 120_721_477;

    FeastConverter internal converter;

    function _fork() internal returns (bool) {
        string memory url = vm.envOr("BSC_RPC_URL", string(""));
        if (bytes(url).length == 0) {
            vm.skip(true);
            return false;
        }
        vm.createSelectFork(url, FORK_BLOCK);
        converter = new FeastConverter(V3_FACTORY, WBNB, address(this));
        return true;
    }

    /// These tokens are proxies with namespaced storage, so writing a balance
    /// slot is not an option. Borrowing from an address that already holds some
    /// is, and is closer to reality anyway.
    function _borrowFrom(address token, address holder, uint256 amount) internal {
        require(IERC20(token).balanceOf(holder) >= amount, "holder too small");
        vm.prank(holder);
        IERC20(token).transfer(address(this), amount);
        IERC20(token).approve(address(converter), amount);
    }

    /// The general case: stock to stablecoin to native, both hops bounded.
    function test_fork_theTwoHopProductionRouteConverts() public {
        if (!_fork()) return;

        (bool leg1,,uint16 card1, uint32 age1) = converter.hopIsPriceable(AAPLB, USDT, AAPLB_USDT_FEE);
        assertTrue(leg1, "the stock/stablecoin leg is priceable");
        assertGe(card1, 2, "it holds a real observation ring");
        assertGe(age1, FeastConstants.MIN_OBSERVATION_AGE, "with history behind it");

        (bool leg2,,,) = converter.hopIsPriceable(USDT, WBNB, 500);
        assertTrue(leg2, "and so is the stablecoin/native leg");

        uint256 amountIn = 1e18;
        _borrowFrom(AAPLB, AAPLB_USDT_2500, amountIn);

        FeastConverter.Hop[] memory route = new FeastConverter.Hop[](2);
        route[0] = FeastConverter.Hop({tokenOut: USDT, fee: AAPLB_USDT_FEE});
        route[1] = FeastConverter.Hop({tokenOut: WBNB, fee: 500});

        uint256 before_ = IERC20(WBNB).balanceOf(address(this));
        uint256 out = converter.convert(AAPLB, amountIn, route, address(this), 0);

        assertGt(out, 0, "the route produced native");
        assertEq(IERC20(WBNB).balanceOf(address(this)) - before_, out, "and it arrived");
        assertEq(IERC20(USDT).balanceOf(address(converter)), 0, "no intermediate token is left behind");
        assertEq(IERC20(AAPLB).balanceOf(address(converter)), 0, "nor any of the input");
    }

    /// The survey concluded no stock/native pool exists, and for the token it
    /// probed that was true. It is not true of this family: this one converts
    /// in a single hop.
    function test_fork_aSingleHopStockToNativeRouteAlsoExists() public {
        if (!_fork()) return;

        (bool priceable,,,) = converter.hopIsPriceable(QQQB, WBNB, QQQB_WBNB_FEE);
        assertTrue(priceable, "a direct stock/native pool, priceable");

        uint256 amountIn = 1e18;
        _borrowFrom(QQQB, QQQB_WBNB_500, amountIn);

        FeastConverter.Hop[] memory route = new FeastConverter.Hop[](1);
        route[0] = FeastConverter.Hop({tokenOut: WBNB, fee: QQQB_WBNB_FEE});

        uint256 out = converter.convert(QQQB, amountIn, route, address(this), 0);
        assertGt(out, 0, "one hop, no stablecoin in the middle");
    }

    /// Symbol is not identity. The discovery tool surfaces several tokens
    /// answering to each of these symbols; the impostors are distinguishable
    /// because they have no liquidity anywhere, which is exactly what the
    /// converter refuses on.
    function test_fork_anImpostorTokenHasNoPriceableRoute() public {
        if (!_fork()) return;
        address impostor = 0x0f8c84735C3FdB9bd2046C19D3eEcBDb94f1ffff; // answers to "AAPLB"
        (bool priceable, address pool,,) = converter.hopIsPriceable(impostor, USDT, 2500);
        assertFalse(priceable, "no route, so nothing to convert through");
        assertEq(pool, address(0), "and no pool at all");
    }
}
