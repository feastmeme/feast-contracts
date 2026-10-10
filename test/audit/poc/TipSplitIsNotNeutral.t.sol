// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolId, PoolIdLibrary} from "../../../src/venue/PoolId.sol";
import {PoolKey} from "../../../src/venue/PoolKey.sol";

import {FeastTipFloorTest} from "../../FeastTipFloor.t.sol";

/// **`tip-splitting` / `normative-claim`** — r2 (v1.6.26, `57eadbc`). `U1` (Codex) reports it
/// MEDIUM at `src/FeastHook.sol:1751-1775`; `U1-claude` (Claude) reports the same defect LOW
/// at `src/FeastConstants.sol:197-198` ("off by a bounded 2.6%").
///
/// The v1.6.23 rule tips a press `coinOut x max(TIP_BPS, min(floor / largest, TIP_CEILING_BPS))`
/// with `largest` read from the bucket BEFORE the press. Each piece of a split press lowers the
/// bucket, so every later piece divides the floor by a smaller `largest` and is tipped at a
/// higher rate. `FeastConstants` and `docs/interface.md` state that "splitting a press earns
/// nothing"; the team's own witness `test_splittingAPressEarnsNothing` allows 6% more. The drift
/// is bounded (about 1.3% for two pieces, 2.6% at the limit of many) and is smaller than the gas
/// an extra press costs, so splitting is not profitable net; the stated property is still false.
///
/// **v1.6.27: the property is restated as a bounded margin, and the hook is not edited** (the
/// owner's ruling of 4 October 2026 on `CA-40dcf992a5`). On `57eadbc` this asserted the exact
/// claim and FAILED: ten presses of a tenth were tipped 511,567,736,157,263 against one press's
/// 499,949,504,529,650, +2.32%. It now asserts the bounded form — the ten pieces earn at most the
/// 6% the team's witness allows, and what they earn above the one press is worth less than the
/// gas of the nine extra presses at 0.1 gwei, the low end of `docs/button-economics.md` — and it
/// keeps recording the drift. The name is the proof ledger's id and is kept.
///
/// Inherits the team's fixture unchanged (so its own tests run again under this contract).
contract TipSplitIsNotNeutralTest is FeastTipFloorTest {
    using PoolIdLibrary for PoolKey;

    /// The cheapest gas price `docs/button-economics.md` prices a press at: 0.1 gwei.
    uint256 internal constant GAS_PRICE = 0.1 gwei;

    function test_tenPressesOfATenthAreTippedNoMoreThanOnePress() public {
        _bank(keyW, address(wbnb), 100e18, 5); // the medium bucket, where the floor binds
        PoolId id = keyW.toId();
        uint256 largest = hook.spendingAllowance(id);
        assertEq(largest, hook.selfBurnPending(id) / 20, "precondition: the allowance is the largest press");

        uint256 snap = vm.snapshotState();
        (uint256 spent, uint256 burned, uint256 oneTip) = _press(coinW, keyW, largest);

        vm.revertToState(snap);
        uint256 splitTips;
        uint256 pressGas;
        for (uint256 i = 0; i < 10; i++) {
            if (i == 0) {
                // One tenth-press's own gas, measured on the call alone and then undone.
                uint256 probe = vm.snapshotState();
                vm.prank(presser);
                uint256 g = gasleft();
                hook.buyBackAndBurn(keyW, largest / 10);
                pressGas = g - gasleft();
                vm.revertToState(probe);
            }
            (,, uint256 t) = _press(coinW, keyW, largest / 10);
            splitTips += t;
        }

        assertGt(oneTip, 0, "the witness reaches its bound: the one press was tipped");
        emit log_named_uint("one press, tip", oneTip);
        emit log_named_uint("ten presses of a tenth, tips", splitTips);
        assertLe(splitTips, oneTip * 106 / 100, "ten presses of a tenth earned more than the 6% margin");
        uint256 extra = splitTips > oneTip ? splitTips - oneTip : 0;
        emit log_named_uint("the drift, in millionths of the one press's tip", extra * 1e6 / oneTip);

        // The extra tip in wrapped native, at the one press's own rate of coin per quote, against
        // what the nine extra presses cost to send.
        uint256 extraValue = extra * spent / (burned + oneTip);
        uint256 extraGasCost = 9 * pressGas * GAS_PRICE;
        emit log_named_uint("gas of one tenth-press", pressGas);
        emit log_named_uint("the extra tip, in wei of wrapped native", extraValue);
        emit log_named_uint("nine extra presses at 0.1 gwei, wei", extraGasCost);
        assertLt(extraValue, extraGasCost, "the extra tip pays for the extra presses' gas");
    }
}
