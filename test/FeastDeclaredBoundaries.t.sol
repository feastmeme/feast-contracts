// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TickMath} from "infinity-core/src/pool-cl/libraries/TickMath.sol";

import {FeastConstants} from "../src/FeastConstants.sol";
import {FeastFactory} from "../src/FeastFactory.sol";
import {PoolId, PoolIdLibrary} from "../src/venue/PoolId.sol";
import {PoolKey} from "../src/venue/PoolKey.sol";

import {MockERC20} from "./utils/MockERC20.sol";
import {UnitFixture} from "./utils/UnitFixture.sol";

/// A quote token whose issuer can switch on a tax on transfers out of one
/// address — here the venue's vault. An upgradeable tokenised-stock proxy can
/// acquire exactly this behaviour after a pool exists.
contract OutboundTaxToken is MockERC20 {
    address public constant COLLECTOR = address(0x7A7);
    address public taxedFrom;
    uint256 public taxBps;

    constructor() MockERC20("Taxed", "TAX", 18) {}

    function setTax(address from, uint256 bps) external {
        taxedFrom = from;
        taxBps = bps;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (taxBps != 0 && from == taxedFrom && to != COLLECTOR) {
            uint256 tax = value * taxBps / 10_000;
            super._update(from, COLLECTOR, tax);
            super._update(from, to, value - tax);
        } else {
            super._update(from, to, value);
        }
    }
}

/// B7, declared: a quote token that taxes the vault's outbound transfer.
///
/// Settlement retires the entitlement it was asked to pay and transfers that
/// same amount; it does not measure what arrived, and it deliberately does not
/// (measuring would mean a balance read on the swap-adjacent path and a
/// partial-retirement rule this unit does not have). So a quote whose transfer
/// takes a cut delivers less than the ledger retires, and the difference is
/// gone. Both settlement sites inherit it: the creator's claim and the platform
/// exit. This test is the boundary made machine-visible, with the numbers the
/// pre-audit pack found; it is not a promise that this is acceptable.
contract FeastTaxedQuoteBoundaryTest is UnitFixture {
    using PoolIdLibrary for PoolKey;

    OutboundTaxToken internal taxed;
    PoolKey internal key;
    PoolId internal id;

    function setUp() public override {
        super.setUp();
        taxed = new OutboundTaxToken();
        (, key) = _createAgainst(address(taxed), bytes32(uint256(7)));
        id = key.toId();
        _buy(key, address(taxed), 12_625e18, trader, address(0));
    }

    function _createAgainst(address quote, bytes32 salt) internal returns (address c, PoolKey memory k) {
        (c, k) = factory.create(
            FeastFactory.CreateParams({
                name: "Coin",
                symbol: "COIN",
                supply: 1_000_000_000e18,
                quote: quote,
                creator: creator,
                selfBurnBps: 2_000,
                referrerBps: 1_000,
                prebuyQuoteIn: 0,
                minCoinsOut: 0,
                vestingDuration: 0,
                sqrtPriceX96: SQRT_PRICE_1_1,
                startTick: 0,
                liquidity: uint128(1_000_000_000e18 * 999 / 1_000),
                salt: salt,
                metadataHash: bytes32(0)
            })
        );
        vm.roll(vm.getBlockNumber() + FeastConstants.CAP_BLOCKS);
    }

    /// The creator's claim: 75 retired, 74.25 delivered at a 1% outbound tax.
    function test_aTaxedQuoteDeliversLessThanTheClaimRetires() public {
        uint256 owed = hook.creatorPending(id);
        assertEq(owed, 75e18, "the creator is owed 75");

        taxed.setTax(address(vault), 100); // the issuer switches the tax on
        vm.prank(address(0xDEAD5));
        hook.claimCreator(key);

        assertEq(hook.creatorPending(id), 0, "the entitlement is retired in full");
        assertEq(taxed.balanceOf(creator), 74.25e18, "and 99% of it is delivered: the boundary, not a promise");
    }

    /// The platform exit settles through the same primitive: 25 retired, 24.75
    /// delivered.
    function test_aTaxedQuoteDeliversLessThanThePlatformExitRetires() public {
        _genesis();
        uint256 owed = hook.platformPending(id);
        assertEq(owed, 25e18, "the platform bucket holds 25");

        taxed.setTax(address(vault), 100);
        uint256 before_ = taxed.balanceOf(address(sink));
        vm.prank(address(0xDEAD6));
        hook.releasePlatformFees(key);

        assertEq(hook.platformPending(id), 0, "retired in full");
        assertEq(taxed.balanceOf(address(sink)) - before_, 24.75e18, "99% delivered to the sink");
    }

    /// The boundary is the token's, not the mechanism's: an ordinary quote
    /// delivers every unit it retires.
    function test_anUntaxedQuoteDeliversEveryUnitItRetires() public {
        uint256 owed = hook.creatorPending(id);
        hook.claimCreator(key);
        assertEq(taxed.balanceOf(creator), owed, "every unit delivered when the token takes nothing");
    }
}

/// B8, declared: a predicted coin address is not a reservation.
///
/// `predictCoin` commits to salt, name, symbol and supply — the four fields that
/// enter the coin's own creation code — and to nothing else. Anyone may submit
/// those four fields first with economics of their own, and they land on the
/// same address. The creator is not blocked: their launch succeeds at another
/// salt. What is unreliable is only the prediction, so an app must never show or
/// rely on a predicted address before its own `create()` is mined.
contract FeastLaunchIdentityBoundaryTest is UnitFixture {
    using PoolIdLibrary for PoolKey;

    address internal constant SQUATTER = address(0xBEEF);

    function _params(address who, bytes32 salt) internal view returns (FeastFactory.CreateParams memory) {
        return FeastFactory.CreateParams({
            name: "Coin",
            symbol: "COIN",
            supply: 1_000_000_000e18,
            quote: address(stock),
            creator: who,
            selfBurnBps: 2_000,
            referrerBps: 1_000,
            prebuyQuoteIn: 0,
            minCoinsOut: 0,
            vestingDuration: 0,
            sqrtPriceX96: SQRT_PRICE_1_1,
            startTick: 0,
            liquidity: uint128(1_000_000_000e18 * 999 / 1_000),
            salt: salt,
            metadataHash: bytes32(0)
        });
    }

    function test_aPredictedAddressIsNotAReservationButTheLaunchStillHappens() public {
        bytes32 salt = bytes32(uint256(42));
        FeastFactory.CreateParams memory intended = _params(creator, salt);
        address predicted = factory.predictCoin(intended.salt, intended.name, intended.symbol, intended.supply);

        // Another caller submits the same four committed fields first.
        vm.prank(SQUATTER);
        (address taken,) = factory.create(_params(SQUATTER, salt));
        assertEq(taken, predicted, "the prediction commits to those four fields and no more");
        assertEq(factory.getCoin(predicted).creator, SQUATTER, "so the address carries the other economics");

        // The intended launch is not blocked: it goes through at another salt,
        // with its own economics, at the address that salt predicts.
        vm.roll(vm.getBlockNumber() + FeastConstants.CAP_BLOCKS);
        FeastFactory.CreateParams memory again = _params(creator, bytes32(uint256(43)));
        address predictedAgain = factory.predictCoin(again.salt, again.name, again.symbol, again.supply);
        (address mine,) = factory.create(again);
        assertEq(mine, predictedAgain, "at the address its own salt predicts");
        assertEq(factory.getCoin(mine).creator, creator, "with the creator's own economics");
        assertTrue(mine != predicted, "a different address: the prediction was the only casualty");
    }

    /// And the salt itself is never reusable, so nothing is overwritten.
    function test_aTakenSaltIsRefusedRatherThanOverwritten() public {
        vm.prank(SQUATTER);
        factory.create(_params(SQUATTER, bytes32(uint256(44))));
        vm.roll(vm.getBlockNumber() + FeastConstants.CAP_BLOCKS);
        vm.expectRevert();
        factory.create(_params(creator, bytes32(uint256(44))));
    }
}

/// The seeding constraint, and sizing a launch by simulating against it.
///
/// A feast launch is single-sided, and `create()` takes the position's
/// `liquidity` from the caller. What that number has to satisfy is the
/// factory's, and it is one line: the position must consume all but at most 1%
/// of the allocation, or the launch is refused (`FeastFactory._seed`,
/// `PoolTooShallow`). How a caller arrives at the number is the caller's.
///
/// Four internal rounds broke four different published formulas for it (the
/// range's far edge, shading, the allocation's own rounding, the venue's signed
/// limits and the search's convergence), so no formula is published any more
/// and none is encoded here. These witnesses do what an integrator does:
/// simulate `create()` and let the factory answer. What they hold is the
/// constraint — that a position inside the tolerance is accepted, that one
/// outside it is refused loudly, and that some configurations admit no
/// liquidity at all and say so.
contract FeastLiquiditySizingTest is UnitFixture {
    uint256 internal constant SUPPLY_ = 1_000_000_000e18;

    uint256 internal saltCursor = 1;

    /// The next unused salt whose coin sorts on the wanted side of the quote.
    function _saltWhereCoinSortsFor(bool first, uint256 supply) internal returns (bytes32) {
        for (uint256 i = saltCursor; i < 4096; ++i) {
            address c = factory.predictCoin(bytes32(i), "Coin", "COIN", supply);
            if ((c < address(stock)) == first) {
                saltCursor = i + 1;
                return bytes32(i);
            }
        }
        revert("no salt sorts that way");
    }

    function _params(uint256 supply, uint256 prebuyQuoteIn, int24 startTick, uint128 liquidity, bytes32 salt)
        internal
        view
        returns (FeastFactory.CreateParams memory)
    {
        return FeastFactory.CreateParams({
            name: "Coin",
            symbol: "COIN",
            supply: supply,
            quote: address(stock),
            creator: creator,
            selfBurnBps: 2_000,
            referrerBps: 1_000,
            prebuyQuoteIn: prebuyQuoteIn,
            minCoinsOut: 0,
            vestingDuration: 7 days, // v1.6.24 I-5: the floor; one day is refused now
            sqrtPriceX96: TickMath.getSqrtRatioAtTick(startTick),
            startTick: startTick,
            liquidity: liquidity,
            salt: salt,
            metadataHash: bytes32(0)
        });
    }

    /// Sizing the way the interface now tells an integrator to: try `create()`
    /// and read the answer. A rejected attempt costs nothing and consumes no
    /// salt — the call reverts — so the search is free off-chain, against a fork
    /// (`sandbox/up.sh`) or a node's `eth_call`.
    ///
    /// No formula, and no inference about why a candidate was refused. The first
    /// candidate is simply the allocation itself; `PoolTooShallow` says this
    /// position was too small and the search climbs, any other refusal says
    /// only that this candidate was refused and the search comes down.
    /// Consumption rises with liquidity, so bracketing and halving finds the
    /// window if there is one and ends without a candidate if there is not.
    function _probe(uint256 supply, uint256 prebuyQuoteIn, int24 startTick, bytes32 salt, uint256 candidate)
        internal
        returns (uint8 outcome)
    {
        uint256 snap = vm.snapshotState();
        // v1.6.12: a pre-buy spends the creator's own approval, so only the
        // creator may ask for one. The probe launches as the creator either
        // way — creating your own coin is what every one of these searches is.
        vm.prank(creator);
        (bool ok, bytes memory reason) = address(factory).call(
            abi.encodeCall(FeastFactory.create, (_params(supply, prebuyQuoteIn, startTick, uint128(candidate), salt)))
        );
        vm.revertToState(snap);
        if (ok) return ACCEPTED;
        // One refusal carries information the search can use, and it is the only
        // one it reads: `PoolTooShallow` means this position was too small for
        // the coin on offer. Every other refusal is just that — refused — and
        // the search infers nothing from it.
        return bytes4(reason) == FeastFactory.PoolTooShallow.selector ? TOO_SMALL : NOT_ACCEPTED;
    }

    uint8 internal constant ACCEPTED = 0;
    uint8 internal constant TOO_SMALL = 1;
    uint8 internal constant NOT_ACCEPTED = 2;

    function _sizeBySimulating(uint256 supply, uint256 prebuyQuoteIn, int24 startTick, bytes32 salt)
        internal
        returns (uint128 liquidity, bool found)
    {
        uint256 lo; // a candidate refused as too shallow (zero always is)
        uint256 hi; // a candidate refused for anything else
        uint256 candidate = supply == 0 ? 1 : supply;

        // Bracket the window: step by sixteens, up when the factory says too
        // shallow and down on any other refusal, until one of each is known.
        // If the parameters are wrong in a way that has nothing to do with
        // liquidity, every candidate is refused the same way and the search
        // ends without one — which is the right answer to give.
        // Round 14's example: an allocation above the cap is refused before
        // liquidity is looked at, at every candidate.
        for (uint256 i = 0; i < 60 && (lo == 0 || hi == 0); ++i) {
            uint8 outcome = _probe(supply, prebuyQuoteIn, startTick, salt, candidate);
            if (outcome == ACCEPTED) return (uint128(candidate), true);
            if (outcome == TOO_SMALL) {
                lo = candidate;
                if (candidate >= type(uint128).max) return (0, false);
                candidate = candidate > type(uint128).max / 16 ? type(uint128).max : candidate * 16;
            } else {
                hi = candidate;
                candidate /= 16;
                if (candidate == 0) break; // nothing below is large enough to try
            }
        }
        if (hi == 0) return (0, false);

        // Then halve the bracket. Consumption rises with liquidity, so this
        // finds the window if there is one and closes on nothing if there is not.
        while (hi - lo > 1) {
            uint256 mid = lo + (hi - lo) / 2;
            uint8 outcome = _probe(supply, prebuyQuoteIn, startTick, salt, mid);
            if (outcome == ACCEPTED) return (uint128(mid), true);
            if (outcome == TOO_SMALL) lo = mid;
            else hi = mid;
        }
        return (0, false);
    }

    function _launchBySimulating(uint256 supply, uint256 prebuyQuoteIn, int24 startTick, bool coinFirst) internal {
        bytes32 salt = _saltWhereCoinSortsFor(coinFirst, supply);
        (uint128 liquidity, bool found) = _sizeBySimulating(supply, prebuyQuoteIn, startTick, salt);
        assertTrue(found, "the simulation found a liquidity the factory accepts");
        vm.prank(creator);
        factory.create(_params(supply, prebuyQuoteIn, startTick, liquidity, salt));
        vm.roll(vm.getBlockNumber() + FeastConstants.CAP_BLOCKS);
    }

    /// The constraint holds wherever the pool opens. One configuration per test:
    /// each probe is a whole simulated launch.
    function test_simulatingFindsAnAcceptedLaunchAtAUnitPrice() public {
        _launchBySimulating(SUPPLY_, 0, 0, true);
    }

    function test_simulatingFindsAnAcceptedLaunchWellAboveAUnitPrice() public {
        _launchBySimulating(SUPPLY_, 0, 14_000, true);
    }

    function test_simulatingFindsAnAcceptedLaunchWellBelowAUnitPrice() public {
        _launchBySimulating(SUPPLY_, 0, -14_000, true);
    }

    function test_simulatingFindsAnAcceptedLaunchWhenTheCoinSortsSecond() public {
        _launchBySimulating(SUPPLY_, 0, -14_000, false);
    }

    /// Hard against the factory's own usable edge, where the position is nothing
    /// like the allocation.
    function test_simulatingFindsAnAcceptedLaunchAtTheUsableEdge() public {
        _launchBySimulating(1e12, 0, 887_000, true);
    }

    /// With a real creator allocation taken out first, so the position is sized
    /// against what the factory seeds rather than the supply.
    /// v1.6.10: the creator's stake is a pre-buy, so the simulated launch has a
    /// real swap inside it. The constraint the search is about — a position that
    /// leaves more than 1% of the coin unused is refused — is unchanged, and the
    /// search still answers where no published formula did.
    function test_simulatingFindsAnAcceptedLaunchWithAPrebuy() public {
        stock.mint(creator, 1_000_000e18);
        vm.prank(creator);
        stock.approve(address(factory), type(uint256).max);
        _launchBySimulating(1_000_000e18, 1_000e18, 0, true);
    }

    /// And at a supply so small that the two ways of rounding it differ by more
    /// than the whole tolerance — where published formulas kept going wrong, and
    /// where simulating simply answers. No pre-buy: 99 wei of supply cannot be
    /// bought into meaningfully, and the subject here is the rounding.
    function test_simulatingFindsAnAcceptedLaunchAtATinySupply() public {
        _launchBySimulating(99, 0, 0, true);
    }

    /// The constraint itself, stated as the factory states it: a position that
    /// leaves more than 1% of the allocation unused is refused, by name, rather
    /// than silently burning the difference. Here the position is sized for a
    /// unit price and opened well away from one.
    function test_aPositionThatLeavesMoreThanOnePercentIsRefusedByName() public {
        bytes32 salt = _saltWhereCoinSortsFor(true, SUPPLY_);
        vm.expectRevert(FeastFactory.PoolTooShallow.selector);
        factory.create(_params(SUPPLY_, 0, 14_000, uint128(SUPPLY_ * 999 / 1_000), salt));
    }

    /// And some configurations admit no liquidity at all: next to the edge with
    /// an allocation so small that one unit of liquidity is more than the whole
    /// tolerance. The simulation says so instead of returning something to send,
    /// which is the answer an integrator needs — move the tick in, or raise the
    /// allocation.
    function test_someConfigurationsAdmitNoLiquidityAndTheSimulationSaysSo() public {
        bytes32 tight = _saltWhereCoinSortsFor(true, 1_000e18);
        (, bool found) = _sizeBySimulating(1_000e18, 0, -887_000, tight);
        assertFalse(found, "no liquidity is both affordable and inside the tolerance here");
        // The neighbouring allocation, one percent larger, is launchable.
        _launchBySimulating(1_010e18, 0, -887_000, true);
    }
}
