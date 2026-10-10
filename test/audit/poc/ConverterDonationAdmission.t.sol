// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {FeastConverter} from "../../../src/FeastConverter.sol";
import {MockERC20} from "../../utils/MockERC20.sol";
import {MockV3Factory, MockV3Pool} from "../../utils/MockV3Pool.sol";

/// A quote token whose issuer takes a cut of transfers made BY one named address. Here that
/// address is the hook, so the cut lands on the hook -> converter leg. This is the same shape as
/// the `OutboundTaxToken` the B7 boundary test uses, pointed at a different sender.
contract HookOutboundTaxToken is MockERC20 {
    address public constant COLLECTOR = address(0xC0111EC7);
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

/// PoC for the round-r1 MEDIUM `donation-dependent-conversion` (`CA-58354019a2`), reported by the
/// codex lens (`r1a`) at `src/FeastConverter.sol:157` and by no other lens.
///
/// The claim: `convert` pulls the nominal `amountIn` and then spends the nominal `amountIn`:
///
///     IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
///     uint256 currentAmount = amountIn;
///
/// Nothing measures what arrived. The hook does measure its own receipt from the vault, but that
/// is a different leg — it does not measure the hook -> converter transfer. So a quote token that
/// takes a cut of the hook's outbound transfer leaves the converter holding 99% of `amountIn`
/// while the first hop tries to spend 100% of it. The shortfall is met, silently, out of whatever
/// else is sitting in the converter.
///
/// Why this is a finding rather than a restatement of B7. B7 is about the VAULT's outbound
/// transfer at settlement: what the ledger retires is more than what the recipient receives. That
/// transfer is untaxed in this construction. What is taxed is the hook's own transfer into the
/// converter, on the claim path, which B7 does not cover.
///
/// What it falsifies is B2 — "stray balances are unowned... tokens sent to the converter belong to
/// nobody and cannot be recovered". Under the construction below a donation IS recovered: it is
/// spent, as part of somebody's conversion, and it is the difference between that conversion being
/// admitted and being refused. Both halves of B2 fail at once: the donation is consumed, and
/// admission depends on it. The round-4 tests that pin donations as untouchable
/// (`test_aDonatedUnitDoesNotBrickConversion`) all use untaxed inputs, which is why they hold.
///
/// The assertion below is the one those round-4 tests make, under a taxed input: the donation is
/// left exactly where it was.
contract ConverterDonationAdmissionPoC is Test {
    FeastConverter internal converter;
    MockV3Factory internal factory;
    MockV3Pool internal pool;
    HookOutboundTaxToken internal taxed;
    MockERC20 internal wbnb;

    address internal claimant = address(0xC1A1);

    function setUp() public {
        vm.warp(1_000_000);
        taxed = new HookOutboundTaxToken();
        wbnb = new MockERC20("Wrapped", "W", 18);
        factory = new MockV3Factory();
        pool = new MockV3Pool(address(taxed), address(wbnb));
        factory.set(address(taxed), address(wbnb), 500, address(pool));
        // This test contract stands in for the hook, exactly as FeastConverterBoundsTest does.
        converter = new FeastConverter(address(factory), address(wbnb), address(this));

        pool.setOldestTimestamp(uint32(block.timestamp - 3_600));
        pool.setTicks(0, 0);
        pool.setOutputBps(10_000);
        wbnb.mint(address(pool), 1_000e18);
        taxed.mint(address(this), 1_000e18);
        taxed.approve(address(converter), type(uint256).max);
    }

    function _route() internal view returns (FeastConverter.Hop[] memory r) {
        r = new FeastConverter.Hop[](1);
        r[0] = FeastConverter.Hop({tokenOut: address(wbnb), fee: 500});
    }

    function test_aDonationIsNeitherSpentNorNeededByATaxedConversion() public {
        // The issuer switches on a 1% cut of what the hook sends out.
        taxed.setTax(address(this), 100);

        // Somebody has donated 0.75 to the converter. By B2 it belongs to nobody and cannot be
        // recovered; by the round-4 rule it changes no conversion's outcome either way.
        taxed.mint(address(converter), 0.75e18);
        uint256 donation = taxed.balanceOf(address(converter));
        assertEq(donation, 0.75e18, "a donation is sitting in the converter");

        // A 75 creator claim is converted. The converter is sent 75 and receives 74.25.
        uint256 out = converter.convert(address(taxed), 75e18, _route(), claimant, 0);
        assertGt(out, 0, "the conversion went through");

        assertEq(
            taxed.balanceOf(address(converter)),
            donation,
            "the donation was spent to cover a taxed conversion's shortfall, so it was recoverable after all"
        );
    }

    /// The other half of B2's guarantee, stated separately: whether a conversion is admitted at
    /// all does not depend on what somebody donated. Without the donation the identical call has
    /// nothing to make up the shortfall from.
    function test_admissionDoesNotDependOnWhatSomebodyDonated() public {
        taxed.setTax(address(this), 100);
        assertEq(taxed.balanceOf(address(converter)), 0, "nothing donated this time");

        uint256 out = converter.convert(address(taxed), 75e18, _route(), claimant, 0);
        assertGt(out, 0, "the same conversion, admitted or refused by the donation alone");
    }
}
