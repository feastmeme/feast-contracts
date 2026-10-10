# v1.6.11 — the launch window becomes a real uniform-price auction

Task 567, branch `feat/v1.6.10-fixes`, cut from `aae43a2`. The owner ruled the change on
2026-09-19 ("B · 真统一价拍卖") and accepted the design on the same day; four further rulings
followed as implementation found things the design had not. Design and every ruling:
`plans/audit/window-auction-design.md`. Spec: `docs/tokenomics-v1.6.md` §2. Plan record:
`docs/plan.md` §6i.

**The seal is taken.** Suite 574 passed, 0 failed, 0 skipped with the fork row at block
120,721,477; `FeastHook` 23,537 of 24,576 with 1,039 to spare.

## What was wrong

The window bought with the whole pot in **one swap** up a single-sided curve. Everybody paid the
same AVERAGE price — but a swap up a curve ends at the MARGINAL price, and that is where it left
the pool: about `sqrt(multiple)` above what every committer paid. Buys are capped at 0.5% of
supply in the opening blocks (refusal R5) and sells are deliberately **not**, so the first
committer to sell took that premium out of the pot and the last one ate it.

The site's promise — *窗内所有 BNB 按一个清算价成交* — described a uniform AVERAGE price plus a
race for the difference. It is now literally true.

## What it is

A fixed tranche, `WINDOW_TRANCHE_BPS` = 5 000 (half the holding), clears at one price:

    p* = (total − total/100) / tranche

`settle` opens the platform pool **at that price** and seeds both sides of it: the unsold half of
the supply above, the whole net pot below as permanently locked bid liquidity. Claims are pro
rata of the fixed tranche, and the claimant who completes the committed weight takes the exact
remainder. A committer who sells everything they were allotted in the first public block receives
less than they committed by the fee and their own impact — and by nothing else.

Genesis no longer initialises or seeds the platform pool. It hands the pool's 60% to the window
and records the opening the genesis key chose, for the no-commit path. **Before settlement the
pool does not exist**, because the price it must open at is the price the auction has not cleared.

## The four consequences, each an owner ruling

| | consequence | ruling |
|---|---|---|
| **licence** | one-sided liquidity cannot be derived without tick maths; the venue's `TickMath` is GPL-2.0 and `src/` is MIT | vendor Uniswap v4-core's **MIT** copy — `TickMath`, plus `BitMath` and `CustomRevert`, which it imports — at `lib/uniswap-v4-core/` from `46c6834698c48bc4a463a86d8420f4eb1d7f3b75`, and **test** that it agrees with the venue's in both directions across the extremes, 100 deterministic ticks and a fuzz over the sqrt-price domain (`test/FeastTickMath.t.sol`). v4-core is dual BUSL/MIT at repo level; all three files taken are MIT, and `lib/uniswap-v4-core/LICENSE` is upstream's own `licenses/MIT_LICENSE` |
| **oracle** | only a swap writes an observation, and the auction has none | **no trade, no price.** `FeastPricer.platformPerNativeQ128()` answers `Unpriceable` from the open until a real trade has aged past `MIN_OBSERVATION_AGE`, and a week settling in that gap takes the written first-week rule — the token cap alone, no price guessed. Eight tests rewritten to say so rather than repointed |
| **alignment** | a position boundary must be a multiple of the tick spacing, which here is 200 — one spacing is `1.0001^200 − 1` = **2.02%**, more than the 1% fee | align to the usable tick that is **cheaper in coin**, so the opening spot is never above what committers paid. The cost is that the first seller pays up to one spacing; the alternative hands them that spacing free, which is the leak this change exists to remove |
| **the fee** | there is no swap left to take the 1% | `settle` transfers it to the platform sink as wrapped native — the same destination `FeastHook.releasePlatformFees` reaches, and the sink prices and sells whatever it holds. On no ledger track, no `Trade`. Keeping this route **out of the hook** is what let the hook fit |

## The three defects the tests found, and the design did not anticipate

**1. The coin's currency slot was assumed.** A pool's price is currency1 per currency0, and the
platform coin's address is whatever CREATE2 produced: it is as likely to sort above the wrapped
native as below it. `settle` computed `sqrt(net/tranche)` unconditionally — the reciprocal of the
pool's price in that case — aligned the tick the wrong way, and applied each liquidity formula to
the wrong asset. The default unit fixture sorts the coin into slot 0, so **every test in the
design would have passed against a settlement that is wrong half the time**.

`FeastWindowAuctionInvertedTest` searches deployment nonces until the sort flips, asserts the
flip it is named for, and runs the whole auction suite again against it. It also found the
alignment a fraction of a tick out: `getTickAtSqrtPrice` floors, so rounding that floor up to a
spacing is not the ceiling — measured at 2.3e-5 over `p*` on a pot the fuzzer found in a few
hundred runs.

**2. `Math.mulDiv` panics on an overflowing RESULT**, not merely an overflowing product.
Inverted, the radicand is `tranche · 2^192 / net`, and the tranche is 3e26 units of coin, so a pot
under about 1.7e7 wei overflowed 256 bits. `settle` now tests `num / den < 2^64` first and reverts
`ClearingPriceUnrepresentable`, which leaves the window unsettled and every commit refundable —
the written failure route, with a diagnosis instead of a panic. The usable-range check also moved
onto the **aligned** tick, which is what the two ranges are built from and which the alignment
itself can push past the end.

**3. `seedWindowPool` did not burn what the positions did not take.** The creator path has always
burned it (I14, with a 1% tolerance so a mis-stated liquidity reverts rather than burning the
supply). The no-commit path leaves 0.1% of the holding — **600,000 FEAST** — unplaced by
construction, because the recipe names 999/1000 of the pool amount as the liquidity. It would
have stranded in the hook for ever.

## Surface

| contract | added | removed |
|---|---|---|
| `FeastLaunchWindow` | the clearing arithmetic in both orientations, `_amount0Liquidity` / `_amount1Liquidity`, the tick alignment, the fee transfer, `tranche()`, `clearingPrice()`, errors `NothingToSell` / `ClearingPriceOutOfRange` / `ClearingPriceUnrepresentable` / `LiquidityOverflow`, a `factory` constructor argument | the swap, `lockAcquired`, `IFeastLockCallback`, `bought()`, `NotVault`, two local sqrt-price bounds |
| `FeastHook` | `seedAuctionLiquidity` (factory-only, `seeded` flips once), the `SeedAuction` lock branch placing both ranges in one lock, `_minUsableTick`/`_maxUsableTick`, `_mayInitialize` overridden to admit a gated pool's registered opener | — |
| `FeastFactory` | `seedWindowPool` (window-gated, burns the unplaced remainder), `platformOpening()`, the `Opening` record, `NotTheWindow` | genesis no longer calls `initialize` or `_seed` for the platform pool |
| `FeastCLHookBase` | `_mayInitialize` as a virtual with the factory-only default | the inline factory comparison in `beforeInitialize` |

`FeastGenesis` gains one constant, `WINDOW_TRANCHE_BPS = 5_000`.

Invariants `P21` (one price, the pool opens at it, the pot stays as locked bid liquidity, no
observation until a real trade), `P22` (the failure routes stay reachable and nothing unplaced is
left owned by nothing) and `P23` (who may initialise) are added to `audit/invariants.yaml`, with
every witness checked against `forge test --list`.

## Runtime bytecode (immutables as zero placeholders; no metadata hash)

Measured from `forge build --force --sizes`. Thirteen of the sixteen are byte-identical to
`v1.6.10-internal`; the three that moved:

| Contract | Bytes | Δ | margin | keccak256 |
|---|---:|---:|---:|---|
| `FeastLaunchWindow` | 10,357 | +3,525 | 14,219 | `0x815c4e5974cef50ae5b319abd19c4ce3d17a53f456b5cee544427c4141ff4ade` |
| `FeastHook` | 23,537 | +1,128 | **1,039** | `0x7615e2373d2db1c50145825e0efc6031332ea96780e3b54ebd5c724c71ef4596` |
| `FeastFactory` | 18,149 | +891 | 6,427 | `0x103899ea9f380d60435c3836e5f05d41be2a00f7d039b23b1be791dcb2942d7c` |

The full sixteen are in `test/FeastBytecodePinTest`, which is the check, not this table.

## How to reproduce

```
forge build --force --sizes
forge test                                         # 574 passed, 0 failed, 0 skipped with FORK_URL set
forge test --match-contract FeastBytecodePinTest   # the sixteen runtime hashes
forge test --match-path 'test/FeastWindowAuction.t.sol'   # 31: the auction, both orientations
forge test --match-path 'test/FeastTickMath.t.sol'        # the vendored MIT tick maths against the venue's
python3 tools/check-census.py
python3 tools/check-boundaries.py
```
