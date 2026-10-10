# Reference sources

Read-only. Nothing here is compiled, imported or deployed — `reference/` is
outside both `src` and `libs` in `foundry.toml`, so the compiler never sees it.
These are the MIT files whose logic the modules in `docs/plan.md` port, vendored
at a pinned commit so that "the deviation from the reference" is a claim a
reviewer can check with `diff` rather than take on trust.

Every file below is `// SPDX-License-Identifier: MIT` in its own header.

## `reference/clanker/` — `clanker-devco/v4-contracts` @ `b004c2edda29fa282a16d5d1441a26484f70b37f` (2025-11-07)

Audited by Cantina and 0xMacro (two rounds).

| File | Upstream path | Ported by |
|---|---|---|
| `ClankerHook.sol` | `src/hooks/ClankerHook.sol` | the four-branch single-leg fee take, and the two rate corrections |
| `ClankerFeeLocker.sol` | `src/ClankerFeeLocker.sol` | claim-based creator/referrer accounting |
| `ClankerToken.sol` | `src/ClankerToken.sol` | the fixed-supply ERC-20 |
| `Clanker.sol` | `src/Clanker.sol` | the one-transaction create sequence |
| `ClankerVault.sol` | `src/extensions/ClankerVault.sol` | linear vesting of the creator's share |
| `ClankerMevBlockDelay.sol` | `src/mev-modules/ClankerMevBlockDelay.sol` | the first-N-blocks window |
| `ClankerLpLockerFeeConversion.sol` | `src/lp-lockers/ClankerLpLockerFeeConversion.sol` | routing shape for the conversion button; also the owner-callable sweeps we must **not** copy |

## `reference/flaunch/` — `flayerlabs/flaunchgg-contracts` @ `3a7cde1bfcca36760de1e72a45677b9096c9d64d` (2026-07-23)

Reviewed in the Sherlock Flayer contest (2024).

| File | Upstream path | Ported by |
|---|---|---|
| `Oracle.sol` | `src/contracts/Oracle.sol` | the TWAP oracle, ported almost verbatim |
| `FeeDistributor.sol` | `src/contracts/hooks/FeeDistributor.sol` | referrer-from-`hookData`; the split shape (whose mutability we invert) |
| `FeeExemptions.sol` | `src/contracts/hooks/FeeExemptions.sol` | the exemption-list shape (whose owner we delete) |
| `InternalSwapPool.sol` | `src/contracts/hooks/InternalSwapPool.sol` | TWAP-priced conversion rather than spot |
| `BidWall.sol` | `src/contracts/bidwall/BidWall.sol` | direct `modifyLiquidity` inside a lock, with no position NFT |
| `BuyBackAndBurnFlay.sol` | `src/contracts/subscribers/BuyBackAndBurnFlay.sol` | threshold gating; the resting-bid alternative we are not building in v1 |

## Read but not vendored

`pancakeswap/infinity-hooks` (UNLICENSED), `pancake-create3-factory`
(UNLICENSED), `whetstoneresearch/doppler` (BUSL-1.1), `ourzora/zora-protocol`
(ZORA-DELAYED-OSL-v1), `OpenZeppelin/uniswap-hooks` (MIT, but Uniswap-v4-only
and single-leg-unspecified, so a cross-check rather than a source).
