// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FeastConstants} from "../../../src/FeastConstants.sol";
import {FeastFactory} from "../../../src/FeastFactory.sol";
import {PoolId, PoolIdLibrary} from "../../../src/venue/PoolId.sol";
import {PoolKey} from "../../../src/venue/PoolKey.sol";
import {OutboundTaxToken} from "../../FeastDeclaredBoundaries.t.sol";
import {UnitFixture} from "../../utils/UnitFixture.sol";

/// @notice B7, declared — the v1.6 re-run of the v1 finding CA-9d2189a3b4 (taxed-payout), which
///         the first dual-family pack raised again as `CA-485fecaac2` and `CA-a3f6fbecc5`.
///
/// @dev **This is a boundary, not a defect.** Settlement retires the entitlement it was asked to
///      pay and transfers that same number of units; it never reads a balance to see what arrived,
///      and deliberately does not — measuring would mean a balance read on the swap-adjacent path
///      and a partial-retirement rule this unit does not have. So a quote token that taxes the
///      vault's outbound transfer delivers less than the ledger retires, at both settlement sites:
///      the creator's claim and v1.6's platform exit.
///
///      Declared at `docs/plan.md` §B7 (2026-09-12, v1.6.1), with the app's quote allowlist as the
///      admission-side answer. The primary witnesses are
///      `test/FeastDeclaredBoundaries.t.sol:FeastTaxedQuoteBoundaryTest`, including the control
///      that an untaxed quote delivers every unit it retires; these two assert the same numbers at
///      the path the pack reproduces from, so a future pack reads B7 as declared rather than
///      proven.
contract TaxedPayoutPoC is UnitFixture {
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

    /// `CA-485fecaac2`: at a 1% outbound tax a creator entitlement of 75 retires in full and
    /// delivers 74.25. The difference is the token's, and it is gone.
    function test_B7_aTaxedQuoteDeliversTheTaxedAmountOnAClaim() public {
        assertEq(hook.creatorPending(id), 75e18, "the creator is owed 75");

        taxed.setTax(address(vault), 100); // the issuer switches the tax on
        vm.prank(address(0xDEAD5));
        hook.claimCreator(key);

        assertEq(hook.creatorPending(id), 0, "the entitlement is retired in full");
        assertEq(taxed.balanceOf(creator), 74.25e18, "and 99% of it is delivered: the boundary, not a promise");
    }

    /// `CA-a3f6fbecc5`: v1.6's platform exit settles through the same primitive, so it carries the
    /// same boundary — 25 retired, 24.75 delivered to the sink.
    function test_B7_aTaxedQuoteDeliversTheTaxedAmountOnThePlatformExit() public {
        _genesis();
        assertEq(hook.platformPending(id), 25e18, "the platform bucket holds 25");

        taxed.setTax(address(vault), 100);
        uint256 before_ = taxed.balanceOf(address(sink));
        vm.prank(address(0xDEAD6));
        hook.releasePlatformFees(key);

        assertEq(hook.platformPending(id), 0, "retired in full");
        assertEq(taxed.balanceOf(address(sink)) - before_, 24.75e18, "99% delivered to the sink");
    }
}
