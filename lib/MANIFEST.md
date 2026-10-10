# Vendored dependencies

Everything under `lib/` is a plain directory copied from a pinned upstream
commit by `tools/vendor.sh`. There are no git submodules and no remotes: the
repository is self-contained, and a reviewer reads the same bytes the compiler
does. Re-running `bash tools/vendor.sh` from a clean checkout reproduces this
tree exactly.

| Directory | Upstream | Commit | Date | Licence | Reason |
|---|---|---|---|---|---|
| `lib/forge-std` | `foundry-rs/forge-std` | `77041d2ce690e692d6e03cc812b57d1ddaa4d505` | — | MIT OR Apache-2.0 | test harness |
| `lib/ds-test` | `dapphub/ds-test` | `e282159d5170298eb2455a6c05280ab5a73a4ef0` | — | GPL-3.0 | forge-std's own dependency; **tests only** |
| `lib/openzeppelin-contracts` | `OpenZeppelin/openzeppelin-contracts` | `659f3063f82422cef820de746444e6f6cba6ca7c` | — | MIT | ERC-20, permit, burnable, reentrancy guard |
| `lib/solmate` | `transmissions11/solmate` | `fadb2e2778adbf01c80275bfb99e5c14969d964b` | — | AGPL-3.0-only | one file, imported by the venue's own sources; **tests only** |
| `lib/infinity-core` | `pancakeswap/infinity-core` | `d0e879334da8ea789a895d864dbe34259ea9fb65` | 2026-09-08 | GPL-2.0 repo, mixed per file | the venue |
| `lib/uniswap-v4-core` | `Uniswap/v4-core` | `46c6834698c48bc4a463a86d8420f4eb1d7f3b75` | 2026-09-20 | MIT (per-file; repo is dual BUSL/MIT) | tick math for the auction's two-sided seed — **the venue's own copy is GPL-2.0-or-later** |

The commits are the ones the reuse survey pinned and cross-checked on chain.
`forge-std`, `openzeppelin-contracts` and `solmate` are pinned to the revisions
`infinity-core` itself declares, so the venue compiles against the versions it
was written for.

## The one thing `src/` imports from `lib/`, and why

`lib/uniswap-v4-core` is **three files** — `TickMath.sol` and the two siblings it
imports, `BitMath.sol` and `CustomRevert.sol` — and it is the only vendored
directory `src/` reaches.

The launch window's uniform-price auction seeds two one-sided positions after
settlement, and turning each side's AMOUNT into the `liquidityDelta` the venue
takes needs the square-root price at the range's inner boundary tick. The
venue's own `TickMath` is **GPL-2.0-or-later** and `src/` is MIT, which is why
`FeastMath` writes the extreme square roots out by hand rather than importing
them, and why `FeastPricer` declines to call `getTickAtSqrtRatio`.

Uniswap's is the same mathematics — `1.0001^tick`, the same constant table — and
its constants are identical to the ones `FeastMath` already carries by hand:
`MIN_TICK = -887272`, `MAX_TICK = 887272`, `MIN_SQRT_PRICE = 4295128739`,
`MAX_SQRT_PRICE = 1461446703485210103287273052203988822378723970342`. It is
audited with the rest of v4-core, so this is a licence swap and not a new
implementation.

v4-core is dual-licensed at the repository level (BUSL-1.1 **and** MIT) with
per-file SPDX headers; all three files taken here carry `MIT`. Nothing else from
v4-core is vendored, and nothing else from it is compiled.

`test/FeastTickMath.t.sol` pins the agreement rather than assuming it: across
the usable range and against the venue's own GPL copy through a test-only
harness, both directions must agree.

## The licence boundary

`infinity-core` carries a GPL-2.0 repository licence with **per-file SPDX
headers that differ**: 24 files under `src/` are MIT, 55 are GPL-2.0-or-later,
6 are UNLICENSED. The survey read that as "types and interfaces are MIT, the
maths libraries are GPL". Walking the import graph shows the MIT set is **not
closed**, which is a stronger constraint than the survey recorded:

```
src/pool-cl/interfaces/ICLPoolManager.sol   (MIT)
  -> src/pool-cl/libraries/CLPool.sol       (GPL-2.0-or-later)
  -> src/pool-cl/libraries/CLPosition.sol   (GPL-2.0-or-later)
  -> src/pool-cl/libraries/Tick.sol         (GPL-2.0-or-later)
  ... 16 GPL files in total

src/types/BalanceDelta.sol                  (MIT)
  -> src/libraries/SafeCast.sol             (GPL-2.0-or-later)
```

`ICLPoolManager` is the interface the hook must implement against — its
`SwapParams` and `ModifyLiquidityParams` structs are unavoidable — and
`ICLHooks` imports it. So *reimplementing the two bit-shift helpers*, which is
the escape route the survey proposed, does not by itself keep the shipped tree
MIT.

`tools/check-boundaries.py` walks the import graph from `src/` and fails on any
non-permissive licence it can reach, so this boundary is enforced mechanically
rather than by convention. It reports clean today because `src/` is empty; the
resolution is a ruling recorded in `docs/plan.md` (open question Q1).

Until that ruling lands, `lib/` is a **test-time** dependency set. Nothing under
`src/` imports it.

## Files deliberately not vendored

| Upstream | Why not |
|---|---|
| `pancakeswap/infinity-hooks` | `CLBaseHook.sol` and the geomean oracle are `UNLICENSED` with no LICENSE file. The convenient base class is the one we may not copy; it is reimplemented from the MIT `ICLHooks` interface instead. |
| `pancakeswap/pancake-create3-factory` | `UNLICENSED`, and its `deploy` is whitelist-gated. |
| `whetstoneresearch/doppler` | BUSL-1.1: forbids production use. |
| `ourzora/zora-protocol` (`packages/coins`) | ZORA-DELAYED-OSL-v1. |
| `pancakeswap/infinity-periphery` | GPL-2.0, and needed only for a handful of router/quoter declarations that are cheaper to declare locally than to vendor with their Permit2 and solady dependencies. Pinned at `4efea658a051305052a948c74632c01470e769e2` for reading. |
