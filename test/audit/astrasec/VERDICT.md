# AstraSec M-1 / M-2 / L-2 — verification verdict

Worktree branch `audit/astrasec-poc-20261001`, built on `e837481` (v1.6.23 sandbox
build, branch `feat/v1.6.22-genesis-trust`). Audit scope commit was `e5c0a77`
(v1.6.21 receipt).

**Drift from the audited commit.** `src/FeastConverter.sol`,
`src/FeastLaunchWindow.sol` and `src/FeastOracle.sol` are **byte-identical**
between `e5c0a77` and `e837481` (`git diff --stat e5c0a77 e837481 -- <file>` is
empty for all three), so every line number the audit quotes for those files still
holds. `src/FeastHook.sol` changed (+71/-12) but only outside `claimAsBnb`: the
function moved from line 1413 to line 1452 and its body is untouched.

Tests: `forge test --match-path 'test/audit/astrasec/*'` →
**19 passed, 0 failed, 0 skipped (5 suites)**. Pure local; no RPC, no fork.

| Finding | Verdict | Key number |
|---|---|---|
| M-1 sandwich on `claimAsBnb` | **REAL** (severity is bounded — see below) | 8 865 bps realised vs the pre-manipulation quote over 3 hops = **11.35% max extraction**, matching the audit's `0.97045³ × 0.97` |
| M-2 permanent FEAST lock-up | **REAL, conditional on currency ordering** | Bricks for any pot ≤ **16 427 305 wei** (1.64e-11 BNB) when the coin sorts as currency1; **6e26 FEAST (60% of supply)** stranded |
| M-2 adjacent (other ordering) | **REAL, different outcome** | 1 wei buys **3e26 FEAST = 30% of total supply** |
| L-2 `consult` window shortening | **REAL as described**, informational | 600 s request answered over **310 s**; floored at 300 s |

---

## M-1 — "Potential sandwich attack on `FeastHook::claimAsBnb()`" → REAL

PoC: `test/audit/astrasec/M1_ClaimAsBnbSlippage.t.sol` (6 tests).

### (a) Is there really no caller `minOut`? — Yes, none.

Mechanically asserted in `test_noCallerMinOutExistsOnTheClaimAsBnbPath`:

- `FeastHook.claimAsBnb.selector == bytes4(keccak256("claimAsBnb((address,address,address,address,uint24,bytes32),address,(address,uint24)[])"))` — `src/FeastHook.sol:1452`
- `FeastConverter.convert.selector == bytes4(keccak256("convert(address,uint256,(address,uint24)[],address)"))` — `src/FeastConverter.sol:185`

A `minOut` would have to live in one of those two signatures. It is in neither.
`claimAsBnb` forwards straight through: `out = converter.convert(quote, amount, route, account)`
(`src/FeastHook.sol:1490`), with no post-check on `out`.

### (b) Measured cost, and is the 3% floor computed from a manipulated `expectedOut`? — Yes.

The two on-chain protections:

- per-hop admission, `src/FeastConverter.sol:352`:
  `if (deviation > MAX_TICK_DEVIATION) revert SpotTooFarFromAverage(...)`,
  `MAX_TICK_DEVIATION = 300` (`src/FeastConstants.sol:241`) = `1.0001^300` = +3.045% / −2.955%.
- route floor, `src/FeastConverter.sol:290-292`:
  `floor_ = mulDiv(expectedOut, BPS - 300, BPS); if (currentAmount < floor_) revert RouteReturnedTooLittle(...)`.

`expectedOut` is accumulated at `src/FeastConverter.sol:254-260` from `sqrtPrices[i]`,
which `_validateHop` captured **after** any manipulation
(`src/FeastConverter.sol:328-341`, the `slot0()` read). So the floor is a floor
under the manipulated number. Measured directly in
`test_theRouteFloorIsComputedFromAManipulatedExpectation` by decoding
`RouteReturnedTooLittle(got, expected, floor)` in both states:

```
expectedOut, clean spot                   9 995 000 000 000 000 000
expectedOut, spot parked at the band edge 9 699 617 656 263 023 987   (= 9 704 bps, exactly the band)
```

Both `expected` and `floor` shrink by the band factor. The floor does not defend
the pre-manipulation value; it ratifies the manipulated one.

Realised output as bps of the pre-manipulation quote:

| scenario | measured | loss |
|---|---|---|
| 1 hop, spot parked at the admitted edge only | 9 704 | 2.96% |
| 1 hop, band × route floor | 9 413 | 5.87% |
| 3 hops (`MAX_HOPS`), each at its own edge, floor spent once | **8 865** | **11.35%** |
| end-to-end through `claimAsBnb` on the full v1.6.23 deployment, 1 hop | 9 704 | 2.96% |

The 3-hop figure reproduces the audit's `0.97045³ × 0.97 ≈ 0.886` to the basis point.

### Caveats on severity (not on correctness)

- Harness is the repo's own `MockV3Pool`, which executes at exactly `sqrtPriceX96`
  with an `outputBps` dial for shortfall — the same abstraction
  `test/FeastConverterBounds.t.sol` uses for every other bound in this contract.
  A real pool is **worse**, not better: the victim's own swap walks further down
  from the edge the attacker parked it at (bounded per hop by
  `MAX_SLIPPAGE_BPS = 300` on the sqrt-price limit, `src/FeastConverter.sol:401-402`;
  the converter's own docstring at `src/FeastConverter.sol:86-88` already states
  the composed per-hop figure as ~6.1%).
- 11.35% is the **maximum value extractable from the claimant**, not the
  attacker's net profit: the sandwicher pays pool fees and their own impact to
  park and unwind the price.
- Mitigations that cap the blast radius: the route is the claimant's own call
  (`RouteIsTheClaimantsToChoose`, `src/FeastHook.sol:1462`), and the plain
  `claim` (`src/FeastHook.sol:1434`) pays the same entitlement in the quote
  token with no route, no oracle and no slippage. So this is a loss a claimant
  opts into, on their own fee earnings — not protocol funds.

### Fix sketch

```solidity
// FeastHook.sol:1452 and FeastConverter.sol:185 — thread a bound the caller owns
function claimAsBnb(PoolKey calldata key, address account, Hop[] calldata route, uint256 minOut)
out = converter.convert(..., route, account, minOut);
if (out < minOut) revert BelowMinOut(out, minOut);      // in convert(), after floor_
// and anchor the floor to the TWAP, not to spot: build expectedOut from
// averageTick (already computed in _validateHop) instead of sqrtPrices[i].
```

---

## M-2 — "Potential permanent FEAST lock-up in `FeastLaunchWindow::settle()`" → REAL, ordering-conditional

PoC: `test/audit/astrasec/M2_SettleLockup.t.sol` (9 tests, two suites — one per
currency ordering).

The window holds `POOL_BPS = 6000` bps of the platform supply = **6e26 of 1e27**.
`settle()` is the only function that can move it (`claim` requires `settled`,
`refund` pays wrapped native), and it is callable only while `_canSettle()` holds
= `[endsAt, openAt)` with `openAt = endsAt + SETTLE_GRACE` = one hour
(`src/FeastLaunchWindow.sol:475-479`). There is **no rescue, sweep or guardian
power** that moves the coin: the window's whole external surface is
`commit / withdraw / settle / claim / refund`
(`src/FeastLaunchWindow.sol:169/179/207/443/460` (commit/withdraw/settle/claim/refund)), the two factory seeding entry
points answer only to the recorded window (`src/FeastFactory.sol:874`, `:891`
→ `NotTheWindow`), and `FeastGuardian`'s own header says it has "no function here
that moves a token" (`src/FeastGuardian.sol:39`).

### (a) Does the zero-commit fallback exist and open the pool? — Yes.

`src/FeastLaunchWindow.sol:216-241`. `test_theZeroCommitFallbackOpensThePoolAndEmptiesTheWindow`:
with `total == 0`, `settle()` initialises the pool single-sided at
`factory.platformOpening()` and leaves 0 FEAST in the window. So the pathology is
strictly about `total != 0` **and** tiny.

### (b) Does 1 wei brick `settle()`? — Yes, in the currency1 ordering only.

`src/FeastLaunchWindow.sol:271` sets `(num, den) = coinIsCurrency0 ? (net, sold) : (sold, net)`
and `:285` reverts `ClearingPriceUnrepresentable(num, den)` when `num / den >= 1 << 64`.
With `sold = coinHeld * WINDOW_TRANCHE_BPS / BPS` = `6e26 * 5000/10000` = **3e26**
(`src/FeastLaunchWindow.sol:252`):

- **coin as currency1** (the ordering the audit names, and which the code's own
  comment at `:282-284` says is the only reachable one): `num/den = 3e26/net`.
  `test_aOneWeiCommitMakesTheClearingPriceUnrepresentable` reverts with
  `ClearingPriceUnrepresentable(3e26, 1)`.
  Exact threshold, measured in `test_theBrickingThresholdIsSixteenMillionWei`:
  the guard fires for every `net <= 3e26 / 2^64 = 16 263 032`, i.e. every
  **`total <= 16 427 305` wei = 1.64e-11 BNB** (`net = total - total/100`).
  `total = 16 427 306` settles cleanly. A 1 BNB pot is ~6e10× above the threshold,
  so "very few commits" in the audit's Scenario 1 means *sub-gwei totals only* —
  in practice the deliberate dust commit of Scenario 2 is the whole exposure.
- **coin as currency0**: `num/den = net/3e26`, which would need a pot of 5.5e45
  wei. Unreachable; the guard never fires. See the adjacent finding below.

The fixture's CREATE2 coin happens to sort *below* the quote, so the audited
orientation is a coin-flip the recipe does not control. The `M2CoinAsCurrency1`
suite reaches it by bumping the test contract's nonce before `setUp` (shifting
every CREATE address, hence the token deployer's, hence the coin's) and asserts
the ordering as a precondition so it cannot silently become the other one.

### (c) Is it permanent, and is there any recovery? — Permanent; none found.

`test_afterTheGraceHourSixtyPercentOfTheSupplyIsStrandedForEver`: attacker
commits 1 wei at `endsAt - 1` (final second, so nobody can out-commit it);
`settle()` reverts for the whole grace hour; past `openAt` every path is refused —
`settle()` → `CannotSettle`, `claim()` → `NotSettled`,
`factory.seedWindowOpening` / `seedWindowPool` → `NotTheWindow` (tried from both
`multisig` and `genesisKey`). The platform pool's `slot0.sqrtPriceX96` is still 0
a year later and the window still holds exactly **6e26 FEAST**. The attacker
recovers their wei through `refund()`, so **the attack costs gas alone**.

The audit's general case is also real and needs no attacker:
`test_aFreezeAcrossTheGraceHourAlsoConsumesIt` — `FeastLaunchWindow` names no
guardian anywhere, so an `ALL` freeze straddling the hour consumes it on the wall
clock and the supply locks with nobody at fault. (Contrast
`test/audit/poc/FreezeRunsTheSettlementClocks.t.sol`, where the same class of bug
was fixed for `FeastEmissions.settle` — the window was not swept.)

### Adjacent, same precondition, other ordering — REAL and arguably worse

`test_oneWeiBuysThirtyPercentOfTheSupplyInThisOrdering`: with the coin as
currency0, a 1-wei dust commit does **not** revert. It skips the zero-commit
fallback, clears at `p* = 1 wei / 3e26 coin` (`clearingPrice()` sqrt = 4.574e15,
i.e. ~3.3e-27 quote per coin), and `claim()` pays the sole committer the **entire
tranche: 3e26 FEAST = 3 000 bps = 30% of total supply, for one wei**. Nothing in
`settle()` imposes a minimum pot or a reserve price. Same root cause as the
lock-up: the dust branch is unguarded; which of the two outcomes you get is
decided by a CREATE2 address comparison.

### Fix sketch

```solidity
// FeastLaunchWindow.settle(), replacing `if (total == 0) {` at :216 —
// route every pot too small to price into the single-sided fallback, and
// mark those commits refundable instead of letting them buy the tranche.
uint256 sold_ = Math.mulDiv(coinHeld, FeastGenesis.WINDOW_TRANCHE_BPS, FeastGenesis.BPS);
if (total == 0 || (total - total / 100) <= sold_ >> 64 || total < MIN_POT) {
    dustRefundable = true;            // honoured by _refundable()
    ... existing no-commit opening ...
}
```
`MIN_POT` should be an economic floor (so 30%-of-supply-for-dust is impossible),
not merely the arithmetic one. Separately, the one-hour `SETTLE_GRACE` is a
single point of failure for 60% of the supply: either widen it, or keep `settle()`
callable while the pool is still uninitialised and make the refund route trigger
on an explicit failure declaration rather than on the clock.

---

## L-2 — `FeastOracle.consult` shortens the TWAP window → REAL as described

PoC: `test/audit/astrasec/L2_OracleWindowShortening.t.sol` (4 tests).

`src/FeastOracle.sol:126-127`:

```solidity
uint32 effective = window > age ? age : window;
if (effective < FeastConstants.MIN_OBSERVATION_AGE) effective = FeastConstants.MIN_OBSERVATION_AGE;
```

Measured in `test_aYoungPoolAnswersTheSameCallOverHalfTheWindow`: a pool with
310 s of history answers the same `twapTick()` call (window
`TWAP_WINDOW = 600`, `src/FeastConstants.sol:245`) over **310 s**, returning
tick 983 where the full window would give 508 — and
`consult(id, 310) == twapTick(id)` exactly. `twapTick` returns a bare `int24`:
nothing in the signature or return value tells the caller the window was halved;
`historySeconds()` has to be consulted separately. So "silently" is accurate.

Both mitigations are also real and are pinned here: the floor holds
(`consult(id, 1) == consult(id, 300)`, `test_theFloorHoldsAgainstADeliberatelyTinyWindow`)
and below 300 s it refuses rather than degrading to spot
(`OracleTooYoung(299, 300)`, `test_belowTheFloorItRefuses`). Net effect is that a
fresh pool's manipulation-resistance window can be half of what callers assume,
for its first ~5 minutes of life. Informational-to-low, as filed.

### Fix sketch

```solidity
function consult(PoolId poolId, uint32 window) public view returns (int24 tick, uint32 usedWindow)
// or, for the shipped callers, refuse the shortening outright:
if (age < window) revert OracleTooYoung(age, window);   // in twapTick's path only
```

---

## Not tested, and why

- **Real-pool slippage geometry.** No forking node and no RPC were permitted, so
  the per-hop execution curve is modelled by `MockV3Pool`'s `outputBps` dial
  rather than by PancakeSwap v3 tick crossing. The repo's own fork tests
  (`test/FeastConverterRealQuote.t.sol`) skip without `BSC_RPC_URL`. The
  direction of the error is known and stated above (a real pool loses more).
- **Attacker net profit for M-1.** Needs real pool depth and real gas/bundle
  costs; the measured number is the claimant's loss ceiling, not the attacker's
  take.
- **Whether the shipped platform coin will sort as currency0 or currency1.** It
  is a CREATE2 address the deploy decides; both orderings are tested, each with
  its own outcome.
