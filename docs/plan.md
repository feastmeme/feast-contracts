# feast — build plan

**Status: ruled on 2026-09-09; building.** §7 records the questions, §0 the
answers. This document is the thing to disagree with; the code is downstream of
it.

## 0. Ruling (2026-09-09)

All recommendations adopted. Made explicit:

| Q | Ruling |
|---|---|
| Claims (2026-09-09, second ruling) | **(ii) with an explicit floor** — `claim()` always pays the accrued quote token and can never brick; `claimAsBnb(route, minOutFromTwap)` does claim-plus-conversion in one call through button (a)'s converter and TWAP bound, reverting the **whole call** if the bound fails — the claim and the conversion are one transaction, so nothing is half-done and the entitlement is left exactly as it was (round 9 M4: an earlier wording said the claim survived the conversion's failure, which is not what atomicity means). The app defaults to `claimAsBnb`, so the BNB story holds in practice while no dead route can trap a creator's money |
| Single-sided launches | Confirmed. `SeedWouldNeedQuote` is a named refusal (R17); the coin is the only thing a creator supplies |
| Q1 licence | **(b)** — `src/` stays MIT via the local venue interface declarations (§2.4); every GPL file confined to `test/`; ABI-identity asserted by fork test *and* by the boundary checker |
| Q2 quote tokens | Factory **open to any ERC-20**, leaning on per-pool isolation (I7); the allowlist lives in the app. The internal v1's fork-test quote is the stock token the survey probed, **explicitly a placeholder** — production quote contracts are confirmed by the owner before any deployment recipe is written |
| Q3 route | **(i)** — caller-supplied route validated by a TWAP-derived `minOut`; treasury stays in BNB |
| Q4a epoch | 86,400 s; pots claimable forever |
| Q4b denominator | **(i)** — one ledger and one pot per quote token, each credited from that token's own conversions |
| Q5 caps | Cap on **coin bought**, N = 2 blocks, 0.5% of supply. Numbers retunable; the shape is fixed |
| Q6 governance (revised after round 1) | 1% proposal threshold against the immutable initial supply; **quorum = max(0.25% of initial supply, 4% of the voting-wrapped supply at the snapshot)**. Measured against the wrapper alone, one wrapped token is the whole electorate; measured against initial supply alone it is unreachable, since the platform coin launches with all of its supply in the pool and the buy-back then burns supply while the denominator stays fixed. The floor is the reachable half of the pair, the proportional term the un-capturable half. Originally: 4% against the **immutable initial supply**; 1-day voting delay; 7-day voting period; 3-day timelock; band `[3000, 7000]` enforced at the callee; `ERC20Wrapper + ERC20Votes` wrapper so every coin stays plain |
| Q7 LP fee | The **lowest static tier the venue permits**, so the 1% hook take is the economic fee |
| Q8 LP fees | `collectLpFees()`, permissionless, into the same buckets |
| Q9 burn-address creator | When `creator == BURN_ADDRESS` the creator remainder routes to the buyback-burn path. **No balance may strand at a dead address — invariant I14** |
| Fork RPC | `https://bsc-mainnet.public.blastapi.io` at the pinned block; the venue deployed in-process for everything else |

All non-blocking defaults (Q10–Q14) stand as documented.

Two sources are authoritative and this plan does not restate them: the contract
reuse survey (module-by-module verdicts, on-chain addresses, licensing), and the
mechanism spec §§9.9–9.13 (the fee split, the two buttons, the epoch pot). Where
this plan departs from either, it says so and says why.

Everything here is subject to one product promise, which is also the reason the
work is hard: **no owner, no upgrade path, no pause, every economic parameter
fixed at creation** — with exactly one exception granted by the owner and
described in §2.10. Immutability means every bug is permanent, so the security
budget is spent on deletion: each feature not built is a bug class not shipped.

---

## 1. What Station 1 established

Toolchain: Foundry `1.6.0-nightly` (`5e88010a`, 2026-04-28), solc 0.8.26,
`evm_version = cancun`, `via_ir`, `optimizer = true` with
**`optimizer_runs = 1_000`**, `bytecode_hash = "none"`, `cbor_metadata = false`,
`isolate = true`. The run count is listed because it is load-bearing for anyone
reproducing the bytecode: BscScan verification and an external auditor's own
compile both need it, and it changed from 20 000 on 2026-09-19 (owner) to give
`FeastHook` room under EIP-170. Dependencies are vendored as
plain directories from pinned commits by `tools/vendor.sh` — no submodules, no
remotes, no `git config`. Pins and licences: `lib/MANIFEST.md`. Reference
sources we port from: `reference/MANIFEST.md`.

Six checks pass (`test/Toolchain.t.sol`), each of which was a real unknown:

| Verified | Result |
|---|---|
| Hook permission bitmap, recomputed from the venue's own offset constants | `0x0CC1` — matches the survey |
| `CLPoolManager.vault()` on the pinned fork | `0x238a…e6c4`, as documented |
| `protocolFeeController.protocolFeeSplitRatio()` | `330000` — the venue keeps 33% of the LP fee and can change it |
| Sample quote token | EIP-1967 proxy, non-zero `pauser()`, `isPaused() == false` at the pin |
| Venue deploys **in-process** (`Vault` + `CLPoolManager`) | yes, 3.7s compile — so most tests need no RPC at all |
| `IVault.mint` selector | `mint(address,address,uint256)` — accrual never touches the quote ERC-20 |

Three Station-1 findings that change the plan:

**(a) The public RPC in the brief cannot run the fork tests.**
`bsc-dataseed.binance.org` is a non-archive node; forking at the survey's pinned
block 120,721,477 fails with `missing trie node` even though that block was
~30 minutes old. Probed ten public endpoints: only
`https://bsc-mainnet.public.blastapi.io` serves archive state at the pin.
`bsc-rpc.publicnode.com` demands a token for archive requests, `1rpc.io/bnb`
lags 54k blocks, `drpc.org` rate-limits, `meowrpc`/`blockrazor` refuse
`eth_call`. The suite therefore pins `BSC_RPC_URL=https://bsc-mainnet.public.blastapi.io`,
and Foundry's on-disk RPC cache makes reruns offline-fast. Fork tests skip
themselves when the variable is unset, so a reviewer with no RPC still gets a
green local build.

**(b) The MIT interface set is not closed — this is stronger than the survey recorded.**
The survey read infinity-core as "MIT types and interfaces, GPL maths libraries",
and proposed reimplementing two bit-shift helpers to stay MIT. Walking the
import graph shows that does not work. `ICLPoolManager.sol` carries an MIT
header but imports `CLPool.sol`, `CLPosition.sol` and `Tick.sol`, all
GPL-2.0-or-later; `BalanceDelta.sol` (MIT) imports `SafeCast.sol` (GPL). A
single `import {ICLPoolManager}` in `src/` reaches **16 GPL files**, which
`tools/check-boundaries.py` prints as a full provenance chain. `ICLHooks` — the
interface the hook must implement — imports `ICLPoolManager`, so there is no
route around it by import selection. See §7 Q1.

**(c) The governance stack the owner has since specified compiles, and it has a
token conflict with a solved shape.** Verified by throwaway probe (deleted, as
it is past the plan stop; §2.10 records how to reproduce it in one file):
OZ v5.7.0 `Governor` + `TimelockController` + `ERC20Votes` build under solc
0.8.26, and a plain fixed-supply coin can stay plain while a separate
`ERC20Wrapper + ERC20Votes` contract carries the voting power. Quorum computed
against the coin's **immutable initial supply** returned exactly 4% in the
probe. The OZ pin was moved from an untagged master commit (`659f306`,
post-5.0.2) to the tagged release **v5.7.0** (`cab19933`) as part of this,
because "the exact reference version" of a governance dependency has to be a
release an auditor can name.

---

## 2. Modules

Fifteen modules. Each row of each table below is a claim a reviewer can check by
diffing against the file in `reference/`.

Naming: every constant, address and share lives in **one** file,
`src/FeastConstants.sol`, so a rename of the product touches one place. No
module hard-codes a number that appears in the spec.

### 2.0 Economic constants (`src/FeastConstants.sol`)

From spec §9.11 + §9.12 + §9.13. Shares are basis points **of the fee**, not of
the trade.

| Constant | Value | Source |
|---|---|---|
| `FEE_PIPS` | `10_000` of `1_000_000` = 1% | §9.10 |
| `PLATFORM_BPS` | `2_000` (20% of the fee) | §9.11 |
| `CREATOR_SIDE_BPS` | `8_000` (80% of the fee) | §9.11 |
| `selfBurnBps` (x) | default `2_000`, creator-set, range `[0, 5_000]` (v1.6.2 H3; was `[0, 3_000]`) | §9.12 |
| `referrerBps` (y) | default `1_000`, creator-set, range `[0, 3_000]` | §9.9 |
| creator remainder | computed `8_000 − x − y`, default `5_000` | §9.9 |
| `burnShareBps` | default `5_000`, **governed**, band `[3_000, 7_000]` | owner ruling, §2.10 |

The creator remainder is **computed, never stored**, so the four shares cannot
drift out of sync. Validation at creation: `x + y <= CREATOR_SIDE_BPS`, `x` and
`y` each within their band. `PLATFORM_BPS` is a `constant`, not an argument.

Where each share is settled (spec §9.12) — this is what makes the two buttons
different, and it is easy to get backwards:

- **self-burn (x)** — stays in the quote token, buys the coin *in the coin's own
  pool*, burns it. Never touches BNB.
- **referrer (y)** and **creator (remainder)** — settled in BNB, so they wait on
  the conversion button.
- **platform (20%)** — settled in BNB, buys the platform token in the
  TOKEN/BNB pool, then splits `burnShareBps` to the burn address and the rest to
  the epoch pot.

### 2.1 `FeastToken.sol` — the coin

| | |
|---|---|
| Reference | `reference/clanker/ClankerToken.sol` (MIT, Cantina + 0xMacro) |
| Deviation | Delete `IERC7802`/`crosschainMint`/`crosschainBurn` and the Superchain imports — meaningless on this chain. Delete `_admin`, `updateAdmin`, `updateImage`, `updateMetadata`, `verify`, `isVerified`: a mutable admin is an owner function wearing a different name. Drop `ERC20Votes` (a checkpoint SSTORE on every transfer, for governance the coin does not have — see §2.10 for how the platform token votes anyway). Keep `ERC20Burnable` (the buyback burns for real, so explorers report supply correctly) and `ERC20Permit` (free, and the app wants gasless approvals). |
| Result | ~60 lines from 194. No mint path exists after construction: fixed supply enforced by absence. |

### 2.2 `FeastCLHookBase.sol` — hook scaffold

| | |
|---|---|
| Reference | **None vendored.** `pancakeswap/infinity-hooks` `CLBaseHook.sol` is the natural base class and is `UNLICENSED` with no LICENSE file. Reimplemented from the MIT interface `ICLHooks`. |
| Deviation | Write only the three callbacks the bitmap registers — `beforeInitialize`, `beforeSwap`, `afterSwap` — plus `getHooksRegistrationBitmap()` and `lockAcquired`. Every unregistered callback is unreachable because the venue only calls what the bitmap enables, so implementing them as reverting stubs is dead weight. Under 100 lines instead of ~330. |

### 2.3 `FeastParameters.sol` — pool key encoding

| | |
|---|---|
| Reference | `infinity-core` `CLPoolParametersHelper.sol` + `libraries/math/Encoded.sol` — both GPL-2.0-or-later. |
| Deviation | Original ~20-line MIT reimplementation of the bit packing: hook bitmap in `parameters` bits `[0,16)`, tick spacing in `[16,40)`. Needed regardless of the Q1 ruling if `src/` is to stay MIT; harmless if it is not. |

### 2.4 `src/venue/` — local interface declarations *(only if Q1 resolves to option (b))*

| | |
|---|---|
| Reference | `infinity-core` `IVault.sol`, `ICLPoolManager.sol`, `ICLHooks.sol`, `PoolKey.sol`, `Currency.sol`, `BalanceDelta.sol`, `BeforeSwapDelta.sol`, `PoolId.sol` |
| Deviation | Re-declare only the functions and structs feast actually calls, so the shipped tree does not reach the 16 GPL files described in §1(b). ABI-identical by construction and asserted against the real deployment by a fork test that compares selectors and calls each one. ~150 lines. |

### 2.4b Deviations found while building (2026-09-09, ruled to stand)

Three departures from the reference, each discovered by building it rather than
reading it, and each with the evidence that forced it.

| Deviation | Evidence | Why the reference is wrong here |
|---|---|---|
| **Mask, never decode, a referral blob** — and keep the exact-length check | `testFuzz_anyHookDataIsSurvivable` found it; mutation #4 holds it | `abi.decode(..., (address))` reverts on dirty upper bits, so a full-width word of garbage reverts *the swap* — precisely what the guard exists to prevent. The length check is **not** made redundant by the mask: a blob shorter than a word is right-padded when read, and a 13-byte one pads into a plausible address, so without it a truncated referral tag silently pays a commission to an address nobody chose (mutation #3, `test_aShortBlobIsNeverReadAsAReferrer`) |
| **Exact integer division for the two rate corrections** | `testFuzz_exactInAndExactOutAgreeOnPrice`; mutations #1 and #2 | The reference routes both corrected rates through a `1e18` fixed-point intermediate, which truncates and leaves the four branches disagreeing by ~1e-16 relative — enough to fail a two-wei cross-case assertion. Dividing directly (`amount * FEE_PIPS / (FEE_DENOMINATOR ± FEE_PIPS)`) is exact, cannot overflow at any realistic size, and makes the branches agree to one wei |
| **"Skip when the fee rounds to zero" instead of a `MIN_FEEABLE_SWAP` threshold** | `test_dustSwapsRoundTheFeeToZeroWithoutReverting`, `testFuzz_noSwapSizeReverts` | A threshold *defines a trade size that pays no fee*, which is an invitation to split trades. Zero-fee rounding is inherent to integer division either way, is bounded at ~100 wei per trade, and needs no constant |

### 2.5 `FeastHook.sol` — the 1% take on the quote leg

The single most important file. The four-branch mechanism, verbatim in shape
from the reference, is the only known-audited implementation of "take a fee on
one *named* currency" rather than on whichever leg happens to be unspecified.

| | |
|---|---|
| Reference | `reference/clanker/ClankerHook.sol`, `_beforeSwap` / `_afterSwap` |
| Deviation 1 — **required, and the most important line in this plan** | The reference calls `_hookFeeClaim` *inside* `_beforeSwap`, which does `burn` + `take(feeCurrency, factory, fee)` — a real ERC-20 transfer of the quote token on the swap path. Against a quote token that can pause, blacklist or sanction, that means a third party can brick every swap in the pool. feast accrues with `vault.mint` only and moves value in a separate, permissionless sweep that is not on the swap path. |
| Deviation 2 | `poolManager.mint(addr, currency.toId(), amt)` → `vault.mint(addr, currency, amt)`. Custody and the ERC-6909 live on the `Vault`, not the pool manager; `Vault.mint` is gated only by `isLocked`, so the hook may call it inside the swapper's own lock. |
| Deviation 3 | Replace the reference's dynamic `protocolFee` (20% of a settable LP fee) with a fixed `FEE_PIPS`. Return `0` as the third `beforeSwap` value: the pool is static-fee, so the venue ignores it. |
| Deviation 4 — **revised while building** | **Dust floor.** The plan proposed skipping the fee below a `MIN_FEEABLE_SWAP` threshold. Built instead as "skip when the computed fee is zero", because a threshold *defines a trade size that pays no fee* — an invitation to split trades — whereas zero-fee rounding is inherent to integer division, bounded at ~100 wei per trade, and unavoidable either way. Strictly better and strictly less code. |
| Deviation 6 — **found while building** | The reference computes the two corrected rates through a `1e18` fixed-point intermediate, which truncates and leaves the four branches disagreeing by ~1e-16 relative — enough to fail a two-wei cross-case assertion. feast divides directly (`amount * FEE_PIPS / (FEE_DENOMINATOR ± FEE_PIPS)`), which is exact integer arithmetic, cannot overflow at any realistic size, and makes the four branches agree to within one wei *in the arithmetic itself*. **The witness is looser than that claim**: `test_theFourBranchesAgreeInBothTokenOrderings` compares end-to-end swap outcomes at a 0.1% tolerance, which also absorbs the venue's own price movement between the two executions, so it is a regression check rather than a proof of wei-scale equality (round 12, r12a M2). Deriving the exact end-to-end bound would mean modelling the venue's rounding as well as feast's. |
| Deviation 5 | **`hookData` guard.** The reference returns early on `length == 0`, which leaves 1–31 bytes of garbage hitting `abi.decode` and reverting *the swap*. feast returns "no referrer" on `length != 32`. |
| Kept verbatim | The two rate corrections, `fee * 1e18 / (1_000_000 ± fee)`, with their comments. They exist because the `beforeSwap` fee is taken before the venue's own LP fee; without them exact-in and exact-out price differently and the gap is arbitrageable. |

### 2.6 `FeastBuckets` (in `FeastHook.sol`) — immutable splits

| | |
|---|---|
| Reference | `reference/flaunch/FeeDistributor.sol` `feeSplit` |
| Deviation | The reference is a **waterfall** (protocol first, then creator, then remainder) and is `Ownable` with three live setters. feast uses **flat** basis points over the whole 1%, written once from the factory path, with no setter anywhere. Flat because the split is a marketing surface: "your 20% is 20% of what's left" does not survive contact with a creator. |
| Storage | `mapping(PoolId => Buckets)`, one slot, packed `uint16 selfBurnBps, uint16 referrerBps`. |

Accrual arithmetic, per swap, to keep the write count honest:

```
accrued[poolId].total        += fee                    // 1 SSTORE
epochPaid[epoch][quote][payer] += fee                  // 1 SSTORE
epochTotal[epoch][quote]     += fee                    // 1 SSTORE
accrued[poolId].referrerTotal += fee*y/1e4             // only on referred swaps
```

Bucket balances are *derived*, not stored: self-burn and platform are fractions
of `total`, and the creator's share is
`total − selfBurn − platform − referrerTotal`. That is why an unreferred swap
costs three writes and not five. The spec asks for one write for epoch
accounting; two are unavoidable because the pot needs a denominator, and §7 Q4b
explains why the ledger is keyed by quote token.

### 2.7 `FeastFeeLocker.sol` — claims

| | |
|---|---|
| Reference | `reference/clanker/ClankerFeeLocker.sol` (59 lines) |
| Deviation | Delete `Ownable` + `addDepositor` + `allowedDepositors`; one `immutable depositor` set in the constructor. ~45 lines. |
| Kept | `claim` callable by anyone, always paying the recorded owner — a creator with a lost key strands only their own bucket and cannot brick the platform's. Balance deltas around every transfer, because the quote token is upgradeable and could become fee-on-transfer after feast is frozen. |

### 2.8 `FeastVesting.sol` — creator's own share

| | |
|---|---|
| Reference | `reference/clanker/ClankerVault.sol` (142 lines) |
| Deviation | Delete `editAllocationAdmin` — it reassigns the vesting recipient, which contradicts "fixed at creation". Set `MIN_LOCKUP_DURATION = 0`: the spec says vest linearly, not cliff-then-vest, and the reference's 7-day floor blocks that. Replace the extension-bus plumbing with plain arguments. |
| Kept verbatim | `_getAmountToClaim`: `amountTotal * (now − lockupEnd) / (vestingEnd − lockupEnd) − amountClaimed`. |

### 2.9 `FeastLiquidityLock` (in `FeastHook.sol`) — the permanent lock

| | |
|---|---|
| Reference | `reference/flaunch/BidWall.sol` `_modifyAndSettleLiquidity` / `_addETHLiquidity` |
| Deviation | Every other reference locks liquidity by minting a position NFT through a periphery `PositionManager` and parking it in a contract with no withdraw path — which drags in Permit2, `Planner`/`Actions` encoding, subscribers and an ERC-721, for a position that must never move. feast's hook owns the liquidity directly: `vault.lock` → `modifyLiquidity(liquidityDelta > 0)` → settle by hand. **The lock is not a timelock, it is an absence**: no function on the hook can pass a negative `liquidityDelta`. Under 120 lines, no NFT, no periphery. |
| Consequence to accept | The position is invisible to the venue's own UI and to position-manager tooling. §7 Q11. |
| Fee collection | `modifyLiquidity(liquidityDelta == 0)` collects the position's LP fees without touching principal, and is safe to expose permissionlessly (shape from the reference's `collectRewardsWithoutUnlock`). Where those fees go is §7 Q9. |

### 2.10 `src/governance/` — the one governed parameter

Granted by the owner, and the only exception to immutability. `burnShareBps` —
the split of the platform-side buyback between the burn address and the epoch
reward pot — may be changed by a token-holder vote, within a **hard-coded band
`[3_000, 7_000]`**, after a **3-day timelock**, taking effect **only at the next
epoch boundary**. Default `5_000`. No team multisig. No veto.

| | |
|---|---|
| Reference | OpenZeppelin Contracts **v5.7.0**, commit `cab19933c33c2ad1d4c7a84864a3601dddfd16f3` (tagged release, vendored at `lib/openzeppelin-contracts`): `governance/Governor.sol`, `governance/TimelockController.sol`, `governance/extensions/{GovernorSettings,GovernorCountingSimple,GovernorVotes,GovernorVotesQuorumFraction,GovernorTimelockControl}.sol`, `token/ERC20/extensions/{ERC20Votes,ERC20Wrapper,ERC20Permit}.sol` |
| Deviation 1 — **the token conflict** | `Governor` needs an `IVotes` token, but §2.1 deletes `ERC20Votes` from the coin, and requirement (d) says the platform token is launched through the same factory as every other coin. Making the factory mint checkpointed tokens would tax every meme coin with a checkpoint SSTORE per transfer and cost the aggregator compatibility that §9.12 chose plain ERC-20 to get. Resolution: the factory stays uniform and the platform token stays plain; a separate `FeastVotes` wrapper (`ERC20Wrapper + ERC20Votes + ERC20Permit`) lets holders opt into voting by wrapping. The platform token remains, literally, just another coin from the factory. |
| Deviation 2 — **quorum denominator** | `GovernorVotesQuorumFraction` computes quorum from the *voting token's* past total supply. Against a wrapper that is the wrapped supply, so one wrapped token would be 100% of "total supply" and could pass anything. feast overrides `quorum()` to a fraction of the coin's **immutable initial supply**, stored as an `immutable`. This fails closed: as the buyback burns supply, quorum gets harder, never easier. Verified in the Station-1 probe. |
| Deviation 3 — **the band is enforced at the callee** | The timelock is not given generic call power over feast. `FeastEpochRewards.setBurnShareBps(uint16)` accepts calls only from the timelock address and itself rejects anything outside `[3_000, 7_000]`. A compromised or malicious governor therefore still cannot leave the band — the band is a property of the contract being changed, not of the process changing it. |
| Deviation 4 — **deferred effect** | `setBurnShareBps` writes `pendingBurnShareBps` and `effectiveFromEpoch = currentEpoch() + 1`; the read path uses the pending value only once that epoch begins. An epoch's rules cannot change while it is being earned. |
| Deviation 5 — **no admin on the timelock** | `TimelockController`'s `DEFAULT_ADMIN_ROLE` must be renounced in the constructor path, `PROPOSER` granted only to the governor, `EXECUTOR` granted to `address(0)` so anyone may execute a passed, matured proposal. A retained admin role is an owner by another name; this is asserted by a deployment test, not by a comment. |
| Reproducing the Station-1 probe | One file: plain `ERC20` coin, `ERC20Wrapper + ERC20Votes + ERC20Permit` wrapper (overriding `decimals`, `_update`, `nonces`), a `Governor` with `GovernorSettings + GovernorCountingSimple + GovernorVotes + GovernorTimelockControl` and `quorum()` returning `initialSupply * bps / 1e4`, plus `TimelockController(3 days, [], [], admin)`. It compiles under solc 0.8.26 and deploys; that is all it was asked to show. |

`tools/check-boundaries.py` currently fails any `src/` file mentioning
`AccessControl`, `onlyRole` or `initializer`. `TimelockController` uses
`AccessControl`. The checker gains a narrow carve-out for `src/governance/**`
**plus** a new assertion that no `src/` file outside `src/governance/` names the
timelock as an authorised caller for any function other than
`setBurnShareBps`. The carve-out has to be narrower than the thing it permits,
or it silently becomes the owner hatch the whole design exists to avoid.

### 2.11 `FeastCaps` (in `FeastHook.sol`) — fair open

| | |
|---|---|
| Reference | `reference/clanker/ClankerMevBlockDelay.sol` (53 lines) |
| Deviation | The reference is an all-or-nothing freeze (`PoolLocked()` while `block.number < unlockTime`) paired with a sniper auction that sells the first block. feast wants a **cap, not a freeze**: a per-wallet purchase limit for the first N blocks, applied to buys only — getting the direction wrong traps early buyers in a coin they cannot sell. |
| Known limitation | The hook's `sender` is the router, not the trader, so capping on `sender` would cap an entire router to one wallet's allowance. feast caps on `tx.origin`, which tracks a human but is bypassable by a contract-per-swap. Documented rather than hidden; an auditor will flag it and should. |
| Exemption list | Requirement (a): an empty, publicly readable list. Shipped as `function isExempt(address) external pure returns (bool) { return false; }` — no storage, no setter, no owner. An `Ownable` exemption contract with an empty map is exactly the thing "no owner functions" promises does not exist. |
| The creator's pre-buy (v1.6.10) | The one purchase the per-wallet cap does not apply to, and it is not an exempt *wallet*: `isExempt` is still a constant `false`. The creator's stake is bought from the pool in the `create` transaction itself, and the hook recognises it **structurally** — the swapper is the factory AND the pool was registered in this very transaction (a transient marker `registerPool` writes). `tx.origin` is not in that test. It is bounded by `MAX_PREBUY_BPS_OF_SUPPLY` (20% of supply, measured in coins received) and by its own price impact, it does not write `purchasedDuringOpening`, and the creator's next buy from their own wallet is capped at 0.5% like anyone's. Disclosed by `FeastFactory.prebuyOf` and the `CreatorPrebuy` event from block one. |

### 2.12 `FeastOracle.sol` — TWAP bound

| | |
|---|---|
| Reference | `reference/flaunch/Oracle.sol` (370 lines, MIT) — the best single find in the survey. It consumes nothing but a `poolId` and an `int24 tick`, so the port to this venue is a namespace change. |
| Deviation — **the fail-open** | The reference's `consult` clamps the requested window to the age of the oldest observation and, at `effectiveWindow == 0`, `return _currentTick`. A pool thirty seconds old therefore yields a thirty-second "TWAP", and a brand-new pool yields the spot price wearing a costume — while the caller believes it holds a manipulation-resistant bound. feast **refuses** below `MIN_OBSERVATION_AGE` instead of degrading silently. This is the single highest-value deviation in the oracle and it is a two-line change to a fail-open default. |
| Cost | An SSTORE per swap to record an observation. feast already writes on every swap, so the marginal cost is small. |

### 2.13 `FeastConverter.sol` — button (a), quote → BNB

| | |
|---|---|
| Reference | No reference matches. Routing shape from `reference/clanker/ClankerLpLockerFeeConversion.sol` `_uniSwapUnlocked`. |
| Deviation — **do not copy the price limit** | The reference sets `sqrtPriceLimitX96` to `MIN_SQRT_PRICE + 1` / `MAX_SQRT_PRICE - 1`, i.e. **no price limit at all**. For a permissionless, tipped button that is a standing invitation. feast derives `minOut` from the TWAP and reverts below it; the slippage bound *is* the safety property. |
| Written from scratch | Size cap, minimum interval, caller tip, and the multi-hop route. **Corrected 2026-09-09 (owner survey):** this row previously said there is *no* quote/BNB pool, generalising from one sample. A QQQB/WBNB v3 pool does exist (≈ \$288k liquidity, ≈ \$4.15M/day). The accurate statement is that such pools are **thin and only exist for some tickers**, so a conversion path can assume neither a single hop nor a required multi-hop. See §6c B3 for what this means for v1.1, and note the converter is not in the v1 tree except as `claimAsBnb`'s route. §7 Q3. |
| Tip | Nothing in any surveyed contract has one. It is what makes "permissionless" true in practice rather than in theory. Sized against gas with a floor so it is never dust, capped so it cannot eat the conversion. |
| Deviation — **the bound is in ticks, not token amounts** (found while building) | Turning a time-weighted tick into a minimum output needs the venue's tick-math library, which is GPL-licensed, and an independent reimplementation would reproduce its constants anyway. Comparing *ticks* needs none of it: before each hop the pool's spot tick must sit within `MAX_TICK_DEVIATION` (300 ticks = 3.045% in price) of its own time-weighted tick, and the swap carries a price limit derived from the spot square-root price. The first refuses to trade into a price somebody just moved; the second bounds how far this swap may move it. **Corrected at v1.6.4 (§6e G3, Claude lens):** this row said the two were "the same tolerance" and the "same safety property". They are neither. They are an admission test and a movement limit, on different quantities, and they COMPOSE — a hop admitted at the edge of the first and walked to the second ends ≈ 6.1% from the time-weighted price. The route floor is what bounds the outcome here. No borrowed mathematics either way. |
| Deviation — **refuse a pool whose oracle cannot answer** (found on chain) | Probed at the pinned block: the v3 pool for the sample quote token holds **one** observation, so its 600-second average tick is `-58820` — *exactly* its spot tick. A bound priced against it is not a bound. `FeastConverter` refuses any hop whose pool has fewer than `MIN_ORACLE_CARDINALITY` observations or less than `MIN_OBSERVATION_AGE` of history, and `hopIsPriceable()` reports why. Growing a pool's cardinality is permissionless, so this is a **deployment-recipe step**, not a dead end — and until it is done, the quote-denominated claim floor is what stops anyone's money being trapped. |
| Deviation — **validate the whole route before moving any tokens** | A refused conversion never touches the caller's balance and never strands a part-finished route holding an intermediate token, and the caller learns *which hop* was unpriceable instead of watching a transfer fail for reasons of its own. |

### 2.14 `FeastBuyback.sol` — button (b)

Two flavours sharing the size cap, interval and TWAP bound:

1. **Coin buyback**, funded by the self-burn bucket, swapping quote → coin in the
   coin's own pool, then burning. Two properties fall out of the venue's design
   and both are worth stating: the venue's `shouldCall` carve-out means a hook's
   own swap does not re-enter its own callbacks, so this swap pays no feast fee
   and trips no feast cap without any `isSelfSwap` transient flag; and because
   the hook can settle its quote debt by **burning ERC-6909 claims** inside the
   lock rather than transferring the ERC-20 (`Vault.burn` credits the caller's
   delta), **a paused quote token does not block the coin buyback**.
2. **Platform-token buyback**, BNB → TOKEN in the TOKEN/BNB pool, splitting
   `burnShareBps` to the burn address and the remainder into the current epoch's
   pot. **Two entry points, not one** (2026-09-09, round 3): both lenses
   independently built a re-entrant call through the single combined function,
   because it wrote epoch, cooldown and entitlement state around external calls
   it did not control. `convertPlatformQuote` now debits the bucket and settles
   native; `platformBuyBack` spends only settled native. Each writes its own
   state before calling anything, both are `nonReentrant`, and neither can be
   re-entered into the other's bookkeeping. The user-visible cost is a two-step
   press; see `docs/interface.md`.

| | |
|---|---|
| Reference | `reference/flaunch/BuyBackAndBurnFlay.sol` (threshold gating) and `BidWall.sol` |
| Deviation | The reference does not market-swap at all: it places a one-tick resting bid just below spot and lets arbitrageurs fill it — zero slippage, zero sandwich surface, but the buy may never fill, hence its own stale-position chaser. That is a genuinely better design on two axes and worse on one. feast builds the **taker swap** because it is what the spec says, it is ~80 lines against ~250, and the self-swap carve-out makes it clean. The resting bid stays in the back pocket for v2. |

### 2.15 `FeastEpochRewards.sol` — the epoch attribution ledger

**The epoch pot ledger accrues attribution; funding arrives with the v1.1
buttons; v1 pays no pot.** Nothing in this tree can put value into a pot, so
nothing in this tree ships a payout path — `record`, `paid`, `total` and the
clock are the whole of it. Round 5's H4 (an index truncation that could erase a
whole funded pot) is not fixed here; it is unreachable, because the funding it
truncates cannot occur. It returns as a live question with the buttons.

What v1 does guarantee is that the record v1.1 will divide against is correct:
every fee attributed to its payer, its quote token and its day, never crossing
any of the three, and never decreasing.

| | |
|---|---|
| Reference | None. Original. |
| v1 scope | The ledger only. Pot funding, division and claiming are on branch `v1.1/platform-buttons`. |

### 2.16 `FeastFactory.sol` — one transaction

| | |
|---|---|
| Reference | `reference/clanker/Clanker.sol` `deployToken` → `_initializePool` → `_initializeLiquidity` → extensions → mev module. Steal the sequence. |
| Deviation 1 | Delete the registries. The reference gates on `enabledHooks`, `enabledLockers`, `enabledMevModules` and a `deprecated` kill switch, all owner-mutable. feast binds hook, locker and cap module as `immutable` constructor arguments and deletes all four mappings and the deprecation path. |
| Deviation 2 | Collapse the extension bus. The reference has a generic plugin system with `MAX_EXTENSIONS` and per-extension bps; feast has exactly one extension (vesting), inlined as one bps, one transfer, one call. |
| Deviation 3 | Build the `PoolKey` in the factory rather than delegating to the hook. Six fields on this venue, not five; `tickSpacing` lives in `parameters`, not as a struct field; `parameters` also carries the hook bitmap. Every `PoolKey` literal in ported code needs rewriting, and the `tickSpacing == 0` sentinel some references use does not port. |
| Deviation 4 | Port the reference's pre-existing-pool guard: `beforeInitialize` reverts unless the initialiser is the factory. Without it anyone can create a second pool bearing feast's hook with a hostile quote token or tick spacing, and a stranger writes feast's per-pool state. |
| Deviation 5 (**not in v1** — round 10 M1) | *Intended:* read the quote token's `decimals()` at creation and store it, since the quote is an upgradeable proxy and assuming 18 is how a later upgrade silently corrupts the maths. **v1 does neither**: nothing in `FeastFactory` reads or records `decimals()`. The snapshot is part of the v1.1 quote-allowlist unit. Recorded here as a design intention that was never built, rather than left reading as shipped behaviour. |
| Token ordering | Store `coinIsCurrency0` per pool and branch on it, rather than mining a salt so the coin always lands on one side. Salt mining deletes a branch class but costs a search in the create transaction and constrains vanity addresses; the stored flag is one bit and the reference has been audited with it. |

### 2.17 Deterministic deployment

Plain `CREATE2` from the immutable factory for the coins — the venue needs no
address mining, because hook permissions live in `poolKey.parameters` rather
than in the hook's address bits, which deletes the whole salt-mining apparatus
other ecosystems need. `CREATE3` buys only address-independence from
constructor arguments, which matters solely for cross-chain address parity;
§7 Q12 asks whether that is a requirement, and if it is not, this module is one
line. The venue's own CREATE3 factory is `UNLICENSED` *and* whitelist-gated, and
third-party deployers add an external dependency to a "verify it yourself"
product; neither is used.

---

## 3. Invariants

**One stated assumption.** `MIN_RATIONED_BUCKET` (§6c B4) is the only constant
expressed in raw token units rather than as a rate, so it assumes quote tokens
carry at least six decimals. Tokenised equities on this chain are 18-decimal, so
it is 1e-14 of a token; at six decimals it is 0.01. A quote token with fewer than
six decimals is outside the assumption, and a launch against one should be
refused by the application rather than relied on here. (v1.6: the internal fill's
exact price domain is narrower — sized for 18-decimal quotes, which is what the
pricer admits; a six-decimal quote can fall outside it and then trades unfilled.
`plans/v16/plan.md` §R4.)

The list the audit lenses will be pointed at. Each is stated so that it can
fail, and names how it is checked.

| # | Invariant | Checked by |
|---|---|---|
| I1 | **No swap reverts because of fee accounting**, with one declared exception: a *specified-quote* trade the venue stops early is refused rather than charged on an amount it never traded (R18). Otherwise — not on dust, not on malformed `hookData`, not on a rounding edge, not because a token moved. | dust-floor and `hookData` fuzz; `testFuzz_aPartialFillIsEitherRefusedOrChargedOnWhatFilled` for the exception; the accrual path makes no external call to the quote token |
| I2 | **A paused, blacklisting or sanctioning quote token cannot brick swaps of other pools, and cannot corrupt accrued state in its own.** Worst case value is *stuck*, never lost or stolen. | fork test with the real quote token paused by its real pauser |
| I3 | **No address can change any economic parameter after creation** — except `burnShareBps` within `[3_000, 7_000]`, by timelocked token vote, effective only at an epoch boundary. **Including the timelock**: it has no other reachable authority. | `tools/check-boundaries.py` authority scan; a test enumerating every state-changing external function and its caller set |
| I4 | **Both buttons are bounded and permissionless.** Bounded by size cap, minimum interval and a TWAP-derived `minOut`; callable by any address; the tip is capped and paid out of output. | unit + fork |
| I5 | **Seeded liquidity can never be removed.** No reachable path passes `liquidityDelta < 0`; the only liquidity call after creation is `liquidityDelta == 0` fee collection. | a test that enumerates every external function and asserts the negative-delta path is unreachable |
| I6 | **Conservation.** The four bucket shares sum to exactly the fee taken; no bucket is payable twice; no wei is created. | invariant fuzz over swap sequences |
| I7 | **Per-pool isolation, as a claim about VALUE.** No pool can read or write another pool's accrual, caps, buckets, oracle or epoch state. A bad pool cannot poison a good one. **Amended for v1.6.8**, because one thing now crosses and it should be stated rather than quietly true: `referrerOf` is the first hook state that is not keyed by pool, and a trade on one pool decides who is paid on another. That is the referral binding, and it is the feature. What crosses is a single global address-to-address fact that carries no value, that no pool's accounting depends on for soundness — every pool's four shares still sum to its own fee whoever the referrer is — and that only the wallet itself can write. | invariant fuzz across two pools, one with a hostile quote token; `test_theBindingIsNotPerPoolAndReachesACoinNeverTraded`, `testFuzz_theFourSharesStillSumToWhatWasTakenForABoundWallet` |
| I8 | **Claims are pull-only and always pay the recorded owner.** A lost creator key strands that creator's bucket and nothing else. | unit |
| I9 | **Epoch soundness.** Per-payer credits in an epoch sum to that epoch's denominator; claims cannot exceed the pot; an unclaimed epoch does not block the next; the current epoch cannot be claimed. | invariant fuzz |
| I10 | **Only the factory can create a pool bearing this hook**, so per-pool state is never written by a stranger. | fork test attempting a foreign `initialize` |
| I11 | **The four fee branches agree.** Exact-in and exact-out price identically for the same trade, to within rounding — otherwise the gap is arbitrageable. | cross-case equality assertions over all four branches; this is the reason the rate corrections are copied verbatim |
| I12 | **Supply is fixed.** No mint path exists after construction; burns only reduce supply. | unit |
| I13 | **The TWAP bound is never a spot price.** The oracle refuses below a minimum observation age rather than degrading to spot. | unit against a young pool |
| I15 | **Whoever bears the loss from a route chooses it.** `claimAsBnb` converts along a route the *claimant* supplies, and no one else may supply it. This is why that path survives the v1 cut while the platform buttons do not: round 5's H1 is about spending the protocol's money along a route the protocol did not choose, and here the chooser and the loser are the same person. Claiming in the quote token needs no route at all and cannot be bricked by market conditions — though it is not unconditional: a frozen quote makes it revert until the freeze lifts (entitlement intact), and an entitlement past one settlement is paid in pieces (§6c B5). | unit: `test_onlyTheClaimantMayChooseTheirOwnConversionRoute`, `test_aClaimantMayTakeTheirOwnClaimInTheChainsAsset`, `test_fork_aPausedQuoteTokenCorruptsNothing` |
| I16 | **A wallet's referrer is written once, by the wallet itself, and can never be changed.** One entry, in the swap path, and only from zero: the trade must name a referrer, the wallet it names must be `tx.origin`, and the referrer must be neither the zero address, nor that wallet, nor the burn address. There is no setter, no owner path and no re-binding — the consequence, ruled and accepted rather than overlooked, is that the first Feast trade a wallet makes with a referrer named decides its referrer for life, on any pool, with no remedy afterwards. Once written it decides every later trade of that wallet on every pool, and no `hookData` can redirect it. | `test/FeastReferrerBinding.t.sol` (26 tests), five mutations in `tools/mutate.py`, and `docs/site-census.md` mechanism `referral-binding`; `docs/referrer-binding.md` is the design |
| I14 | **No balance may strand at a dead address.** When the creator is the burn address, the creator remainder routes to the buyback-burn path instead of accruing to a claim no one can make. | unit + the platform-token creation test |

Two things that are **not** invariants and must be said out loud in the README
rather than discovered by a critic: the venue's `swap` and `modifyLiquidity` are
`whenNotPaused` under an owner feast does not control, so the honest claim is
"feast has no admin; the venue it is built on can be paused by its own". And the
venue takes 33% of the LP fee at a rate its owner can change, so any economics
that lean on the locked position's yield sit on someone else's mutable
parameter.

---

## 4. Refusal ledger

Every predicate that can refuse, what it excludes, and — the column that
prevents a refusal from quietly becoming a denial of service — what it must
**not** refuse.

| # | Predicate | Refuses | Excluded adversary | Must not refuse |
|---|---|---|---|---|
| R1 | `initialiser != factory` **and not this pool's registered opener** in `beforeInitialize` (widened v1.6.11) | a foreign pool bearing this hook | someone creating a pool with a hostile quote token or tick spacing to write our per-pool state | the factory's own creation, and the launch window opening the platform pool at settlement — an ordinary pool has no opener and stays factory-only |
| R2 | `x + y > CREATOR_SIDE_BPS`, or either outside its band, at creation | an over-allocated creator side | a creator claiming more than 80% of the fee, or one advertising a share the contract cannot honour | `x=3000,y=3000` (creator 20%) and `x=0,y=0` (creator 80%) |
| R3 | `hookData.length ∉ {32, 64}` → **no referrer, no revert** | the referrer credit only | a griefer routing swaps with 1–31 bytes of garbage to revert them | **the swap itself** (this is R3's whole point), and neither of the two accepted forms — 32 bytes is the per-trade referrer as it always was, 64 is `(referrer, wallet)` and can also bind (§3 I16) |
| R4 | `feeAmount == 0` → **skip the fee** | the fee only | a rounded-up fee reverting a dust swap | any swap whose fee rounds to a non-zero amount |
| R5 | per-wallet purchase cap, first N blocks | a buy above the cap | a sniper taking the float in block one. **Does not exclude** a contract-per-swap adversary — documented, not hidden | sells; any buy after the window; buys under the cap |
| R6 | `block.timestamp < last + MIN_INTERVAL` | a too-frequent button press | a caller farming the tip by splitting one conversion into many | a genuine call after the interval |
| R7 | `amountIn > MAX_SIZE` | an oversized conversion | a caller draining the whole accrual into one sandwichable swap | a conversion at or under the cap |
| R8 | `out < minOut` (TWAP-derived) | a fill at a manipulated price | an atomic spot-manipulator sandwiching the button | a fill within the slippage band during ordinary volatility |
| R9 | `observationAge < MIN_OBSERVATION_AGE` | the *bound*, hence the button | someone creating a pool and pressing the button before a real TWAP exists | any pool with enough history — and the fee accrual, which must keep working while the button is refusing |
| R10 | `msg.sender != depositor` in the fee locker | a foreign deposit | anyone inflating their own claim balance | the hook's deposits |
| R11 | `block.timestamp < lockupEnd` in vesting | an early claim | a creator front-running their own vesting schedule | a claim of the vested portion, by anyone, paid to the fixed recipient |
| R12 | `claimed[epoch][payer]` already set | a double claim | a payer claiming an epoch twice | a first claim for any other epoch |
| R13 | `epoch >= currentEpoch()` on claim | claiming an open epoch | a payer claiming early, then trading more into the same epoch | any closed epoch, forever |
| R14 | `bps < 3000 \|\| bps > 7000` in `setBurnShareBps` | an out-of-band proposal, **at the callee** | a governance capture — or a bug in the governor — moving the split outside the band | any in-band value proposed and passed |
| R15 | `msg.sender != timelock` in `setBurnShareBps` | a direct call | anyone bypassing the vote and the 3-day delay | the timelock executing a matured proposal |
| R16 | `effectiveFromEpoch > currentEpoch()` on read | a change taking effect mid-epoch | a proposal timed to land inside an epoch whose rewards are already being earned | the change, from the next epoch boundary onward |
| R18 | realised specified-leg amount != requested, when the quote is the specified currency (`PartialFillNotSupported`) | a trade the venue could only fill in part | a trader whose price limit stops the swap early and who would otherwise be charged a fee computed on the amount they *asked* for rather than the amount they *got* — at the extreme, 100% of the fill | any fully filled trade, and every partially filled trade in which the quote is the *unspecified* currency, where the fee is already taken from realised deltas |
| R17 | `quoteOwed < 0` when seeding (`SeedWouldNeedQuote`) | a launch whose opening range straddles the price | a creator who would need to supply the paired asset — feast launches are single-sided, the coin is the only thing a creator brings | any range sitting wholly on the coin's side of the opening price |

---

## 5. Fork-test plan

`BSC_RPC_URL=https://bsc-mainnet.public.blastapi.io`, pinned at block
**120,721,477**. Pinned because the quote token sits behind an upgradeable
proxy and an unpinned fork silently tracks upgrades — the test would then change
behaviour under us with no diff. Most of the suite runs against a locally
deployed venue (§1) and needs no RPC; the fork is reserved for the two things
only mainnet has: the real deployment's exact configuration, and a real quote
token with a pauser and a sanctions screen.

Build order — red-first at every step, deliberately front-loading the tests that
can invalidate the design:

| Step | Module | The test that earns the step |
|---|---|---|
| 0 | skeleton | *done* — see §1 |
| 1 | `FeastToken` | unit only; everything downstream needs a token |
| 2 | `FeastCLHookBase` + bitmap | **fork: build a `PoolKey` and call the real `CLPoolManager.initialize`.** This one test de-risks the whole project — if the bitmap encoding is wrong, nothing downstream matters |
| 3 | fee take, four branches | fork: all four of `{exactIn, exactOut} × {buy, sell}`, each within one wei of 1% of the quote leg, **and cross-asserted equal to each other** (I11). Without cross-case equality the rate corrections drift silently |
| 4 | `FeastFeeLocker` | unit |
| 5 | buckets + referrer | fork: with a referrer, without one, and with 7 bytes of garbage in `hookData` — the last must not revert the swap (R3) |
| 6 | `FeastFactory` + lock + vesting | fork: one transaction creating token, pool, locked liquidity and vesting; then (a) the pool trades, (b) no external function reaches a negative `liquidityDelta` (I5), (c) vesting accrues linearly |
| 7 | `FeastOracle` | many swaps across `vm.roll`/`vm.warp`; TWAP resists a single-block spike; **a young pool's oracle refuses** (I13/R9) |
| 8 | both buttons | below threshold is a no-op; interval refuses; size cap refuses; TWAP bound refuses a manipulated spot; tip paid to `msg.sender`; and a **self-swap test proving the buyback pays no feast fee**, on the real deployment |
| 9 | `FeastEpochRewards` | invariant fuzz for I9; the wash-trade arithmetic asserted as a property, not an example |
| 10 | governance | proposal → 3-day timelock → execution changes `burnShareBps`; out-of-band refused at the callee (R14); direct call refused (R15); the change does not touch the epoch in flight (R16); timelock has no admin role |
| 11 | **real quote token** | swap the mock for the real one on the pinned fork. Then the adversarial run: `vm.prank(pauser)` → pause → assert swaps may fail but **accrued state is not corrupted and nothing is permanently stuck**; unpause → claims work (I2). This is the test that validates the required deviation in §2.5 |
| 12 | deletion pass | grep for every owner surface; assert the authority scan is clean; freeze |
| 13 | caps | deliberately last: it adds an SSTORE to `beforeSwap` and muddies every earlier gas snapshot |

Then mutation checks by hand in `docs/mutations.md` — at minimum: drop each rate
correction and assert step 3 goes red; widen the burn-share band and assert R14
goes red; remove the minimum observation age and assert step 7 goes red; move
the fee claim back onto the swap path and assert step 11 goes red. A mutation
that no test catches is a missing test, not a passing mutation.

---

## 6. Schedule

Target: internal v1 **when two consecutive audit rounds come back clean with an
unconditional endorsement** — not a date. Round 1 (2026-09-09) returned
HIGH=10/MEDIUM=5 from the coverage lens and HIGH=7/MEDIUM=10/LOW=1 with
endorsement refused; the fix program is §8. Steps 1–6 are the critical path and depend on nothing but the Q1
ruling. Steps 7–10 depend on Q3, Q4 and the governance parameters. Step 11
depends on Q2, and is the step most likely to surface something unwelcome, so it
gets a mock-quote dry run at step 6 rather than waiting.

---

## 6b. Testing rules (added 2026-09-09, from round 1)

Round 1's sharpest finding was not any single defect. It was that **145 tests
were green and 23 of 23 mutations "caught" while eleven HIGH classes sat in the
code**. The endorsement lens named the mechanism: *adjacent assertions standing
in for invariants*. Three rules follow, and they bind every test written from
here.

1. **Every invariant gets a sequence or property test, not a snapshot.** The
   conservation fuzz checked one swap's derived identity and stayed green
   through a defect that only appears in accrue → claim → accrue. A single-state
   assertion is evidence about a single state and nothing more.
2. **A fixture may never disable a ledger or a collaborator with `address(0)`.**
   Every hook fixture did, so deleting the epoch-recording call outright would
   have left the suite green. If a collaborator is hard to stand up, stand it up
   anyway; that difficulty is the test's subject.
3. **Fix at the class boundary means enumerate every site the mechanism
   reaches.** Round 2 found six of round 1's twelve classes only patched: the
   fix went to the site each finding named and not to its siblings. One
   predicate implementation, called from every site, never a per-site copy —
   and the site list is derived from the source by `tools/check-census.py`
   rather than remembered. See `docs/site-census.md`.
4. **A test must be able to fail for the stated reason.** Before adding one, say
   which mutation it kills, and check that the mutation is one a person could
   plausibly make — not one contrived to match the assertion. `tools/mutate.py`
   is where that claim gets recorded and re-run.

---

## 6c. Boundaries — mechanisms withdrawn, and why

A boundary is something feast **does not do**, written down so a later reader
does not mistake the absence for an oversight and re-add it. Each entry takes
the form the audit rules ask for: the predicate, the separate constructions that
broke it, what was withdrawn, and what the caller does instead.

### B1. The partial-fill remainder (withdrawn 2026-09-09, round 3, Rule 8)

**The predicate.** *A button or a conversion may consume less input than it was
given; whatever is left must be returned to the party whose entitlement paid for
it, in the custody form that party's ledger assumes.*

**Three failures, three separate constructions.**

| Round | Finding | What broke |
|---|---|---|
| 1 | r1a **H6**, r1b **H2** | The buttons debited the bucket by the **request** and settled the venue's **actual** delta, so a partial fill retired entitlement that had bought nothing. Fixed by measuring realised spend. |
| 2 | r2a **H3**, r2b **H2** | Realised spend was measured now, but the remainder itself had nowhere to go: the converter refunded the *original* input token to its caller — the hook — which had already retired the claim; a partially filled **later** hop stranded the intermediate token, which the refund path never looked at; and a partial platform purchase left native sitting in the hook. Fixed by refunding at each hop and adding `Action.Restore` to put refunded quote back on its bucket. |
| 3 | r3a **H2**, r3b **H3** | Three kinds of entitlement still stranded. The reconciliation had itself become the surface: `Restore` was a fourth lock action carrying its own ordering obligation, the refund had to know each token's custody form (raw ERC-20 versus ERC-6909 claim), and the claimant path had no way to hand a refund back to a claimant who was no longer in the call. |

The same predicate broke three times, each time under a construction the
previous fix had not contemplated, and each fix was individually correct. That
is exactly the shape Rule 8 names, and a third incremental patch is forbidden.

**Withdrawn.** Partial fills are no longer *reconciled*; they are **refused**.
`FeastConverter` measures what the venue actually consumed
(`amountIn - balanceOf(this)`) and reverts `RouteWouldNotFill(consumed,
amountIn)` unless that is the whole request. Deleted with it: the per-hop refund
path, the intermediate-token sweep, `Action.Restore`, `_realisedSpend`, and the
post-settlement reconciliation in both buttons. A conversion is now
all-or-nothing, so there is no remainder to own and no custody form to decide.

**What the caller does now.** A refused route costs the caller gas and nothing
else — the refusal lands before any entitlement is retired, so the claim, the
bucket and the interval are all left exactly as they were. Note that `claimAsBnb`
takes no amount, so "retry smaller" applies to the platform conversion path in
v1.1 and not to a claim: a claimant whose route is too shallow claims in the
quote token instead, which needs no route (round 12, r12a M1). The caller retries
with a smaller `amountIn`, or through deeper pools. The size that will fill is a
property of those pools and the caller can read it; it is not something feast
can discover on the caller's behalf without moving the caller's money first.

**What this costs.** A route that would have filled 99% now reverts, and the
caller pays gas to find out. Accepted: the alternative is a reconciliation whose
correctness failed three independent audits, guarding value that a retry
recovers in full.

**The property that replaces it.** `test_aRouteThatCannotFillIsRefusedOutright`
— for any input the pool will only partly take, the call reverts and every
ledger on the path is unchanged. The census records this predicate under
`realised-spend`, and `tools/mutate.py` carries "let a route part-fill instead
of refusing (rule-8 withdrawal)" as a standing mutation.

**Round 4 correction: the boundary is enforced per site, from the venue's own
answer.** The first implementation of this withdrawal was a single outer check
comparing the request against the converter's whole input-token balance, and it
was wrong in both halves. It read a *balance*, which anybody can change by
sending tokens, so one unsolicited unit bricked every conversion of that token
forever (r4a H5, r4b H1); and it looked only at the *first* token, so a middle
hop that part-filled stranded the intermediate one (r4a H2, r4b H2). The
platform press had the same shape one level up: it debited the request while its
callback settled the venue's actual debt, leaving 65 of a 95-unit press held and
owned by nothing.

The rule now is one predicate, stated once, enforced at **every settlement site
and measured from the delta the venue itself returns** — never from a balance,
which any passer-by can change, and never from the request, which is what we
hoped rather than what happened:

| Site | Enforced by |
|---|---|
| `FeastConverter._hop`, each hop | `RouteWouldNotFill(taken, amountIn)`, `taken` from the venue's `amount0`/`amount1` |
| `FeastConverter.convert`, whole route | the conjunction of the above — a middle hop that part-fills reverts the route with it |
| `FeastHook.platformBuyBack` | `PressWouldNotFill(spent, amountIn)`, `spent` from the settled `BalanceDelta` |

`FeastHook.buyBackAndBurn` needs no refusal: it debits the realised spend, and
unspent quote stays in vault claims that `selfBurnPending` still counts, so
nothing strands there.

### B2. Stray balances are unowned (declared 2026-09-09, round 4)

Tokens sent to `FeastConverter` by anybody, for any reason, belong to nobody and
**cannot be recovered**. There is no skim, no sweep, no rescue function.

This is a consequence of B1, declared rather than fixed. A recovery path needs
an authority to decide who gets the tokens, and feast has no owner — which is
the property the whole design exists to keep. The other option, crediting a
stray balance to whichever bucket converts that token next, is precisely how the
round-4 brick happened: it makes a conversion depend on a number outside the
protocol's control, which anyone can set.

What *is* guaranteed, from v1.6.3, is exactly this:

> **A donation to the converter is neither spent nor needed on any leg: inbound
> and intermediate arrivals are measured, and the outbound payment is bounded by
> this hop's measured input.**

A conversion has three kinds of leg, and all three are now measured. The first
version of this pass measured one of them, which is why the sentence above is
written a leg at a time rather than as a slogan.

| Leg | What it does | What holds it |
|---|---|---|
| **Inbound** `hook → converter` | The balance before the `safeTransferFrom` against after it: what the route spends is what ARRIVED, clamped at the nominal so it is never more than the hook sent. A non-positive arrival — a token that *shrinks* this contract's balance on the way in — is the named refusal `NothingArrived`, identical with or without a donation, rather than a checked-subtraction panic whose reachability depended on the size of one. | `test_aTaxedInputWithNoDonationConvertsWhatArrived`, `test_aTokenThatDeliversMoreThanAskedDoesNotHaveTheSurplusSpent`, `test_anInboundThatShrinksTheBalanceIsRefusedByNameNotByPanic` |
| **Intermediate** `pool → converter` | `_hop` reads this contract's balance of the hop's output before and after the swap and hands the NEXT hop what arrived — not what the pool *reported* sending. The route floor is compared against that measured chain. | `test_aTaxedIntermediateNeitherSpendsADonationNorNeedsOne` |
| **Outbound** `converter → pool` | A hop pays only out of what it brought. The callback refuses an ask above this hop's measured input (`AskExceedsHop`), and the debit itself is measured after the swap — because the ask is not the debit: a token that charges its sender *on top* transfers what was asked and takes more, while the pool is credited in full and reports a fill. A plain fee-on-transfer on this leg is refused by the pool's own payment check, with or without a donation. | `test_anOutboundSurchargeNeverDipsIntoADonation`, `test_anOutboundFeeOnTransferIsRefusedByThePoolsOwnFillCheckEitherWay` |

Per-hop consumption is still measured from the venue's own signed return value
rather than from a balance, so nothing a passer-by sends can look like a
part-fill. So a donation of any size changes nothing about whether a conversion
is accepted, what it costs, or what any ledger records.

**With one declared limit, measured rather than asserted away.** A balance
difference can separate a donation from an arrival only if the token moves a
fixed amount between two parties — which covers ordinary tokens, tokens that
take a cut, and tokens that deliver more than asked. It does **not** cover a
token that REBASES the holder's balance, because the rebase falls on the
donation and the arrival together and no measurement this contract can make
separates them. Measured, all three rows of one call with a token that halves
the recipient's balance on the way in:

| Prior donation | Balance after | What happens |
|---:|---:|---|
| 0 | 5 | converts 5 of a nominal 10 |
| 5 | 7.5 | converts **2.5** — the identical call, for less, because somebody had donated |
| 30 | 20 | `NothingArrived`: the balance ends below where it started |

Nothing is *spent* out of the donation in any row — it ends where it started —
but what the conversion is *for* does depend on it.

**And a donation can be NEEDED without being spent, with no rebase at all.** Round
3's verifier found the other half: a token whose transfer is exact in net terms
but transiently requires the sender to hold more than it is sending — one unit
out to a collector, the transfer, the unit back. Every leg's measurement agrees,
every balance is conserved once the call returns, and the converter still needs
one unit more than the hop brought for the length of one `_update`. Without a
donation the payment reverts; with one it succeeds, and the donation is still
there afterwards.

**And a third shape, which is what makes the limit's wording general.** A token
whose *acceptance* of a transfer depends on the recipient's standing balance — a
per-holder cap, common on this chain — refuses inside its own `_update` when the
recipient would end above the cap. With an empty converter the conversion is
admitted; with a donation sitting near the cap the identical call is refused.
Nothing is spent, nothing is rewritten, nothing is transiently required of the
sender, and admission still turns on what somebody else left here.

So the limit is stated once, and generally: **a measurement of what a transfer
MOVES cannot cover what that transfer REQUIRES OF EITHER PARTY'S STANDING
BALANCE — before it, during it, or as a condition of accepting it.** Declared
rather than fixed, because no measurement this contract can make reaches inside
another contract's transfer.
The same family is already declared at the venue boundary in `README.md` (a quote
token that can rewrite balances can also pause, blacklist or seize) and for the
sink in §B9. The app's quote allowlist is the admission control for all of it.
Pinned by `test_theDeclaredLimitOfMeasuringAnArrival`,
`test_theDeclaredLimitOfMeasuringATransientRequirement` and
`test_theDeclaredLimitOfATransferThatReadsTheRecipientsBalance` — one witness per
shape, because a limit stated without one is a limit nobody has measured. Held by
`test_aDonatedUnitDoesNotBrickConversion`,
`test_aDonationLargerThanTheRequestDoesNotBrickConversionEither`,
the three rows above, and the dual-family pack's own proof,
`test/audit/poc/ConverterDonationAdmission.t.sol`.

**What it took to get here.** Until v1.6.3 only the per-hop half was measured.
`convert` pulled the nominal `amountIn` and then spent the nominal `amountIn`, so
a quote token taking a cut of the hook's outbound transfer (B7's shape, pointed
at a different leg) left 74.25 of a nominal 75 in the converter while the first
hop tried to spend 75 — and the shortfall came silently out of whatever else was
sitting there. Both halves of this boundary failed at once: the donation *was*
recovered, as part of somebody else's conversion, and it *was* the difference
between that conversion being admitted and refused. The dual-family
`/contract-audit` run on `v1.6.2-internal` proved it as `CA-58354019a2`.

**And the first attempt at the fix measured one leg of three.** v1.6.3's own
round-1 lens found the other two within the hour: `_hop` handed the next hop what
the pool *reported* sending (so a taxed intermediate spent a donation), and the
swap callback paid what the pool *asked* out of whatever this contract held (so a
sender-surcharge reached a donation from the far side of a swap). The lesson is
in the shape of the table above rather than in a sentence: a guarantee about
"a conversion" has to be written and witnessed one leg at a time, because the
legs fail independently and a slogan covers for the ones nobody enumerated.

### B3. The v1 cut: the platform buttons are not here (declared 2026-09-09, round 5)

The convergence cap fired at round 5 — HIGH=4 from both lenses, against a target
of two — and the cut proposed in `docs/ship-as-converged.md` was ratified.

**Not in this tree:** `convertPlatformQuote`, `platformBuyBack`, the
`Action.PlatformBuy` settlement branch, the pot's funding, division and claiming,
and the vote over the burn/reward split that only those buttons read. They are
removed rather than flagged off: no dead code, no feature flags, nothing to
audit that nobody can reach. The implementation is preserved intact on branch
**`v1.1/platform-buttons`**, cut from `34cd900`, which is where v1.1 starts.

**The vote is deferred, not abandoned.** `burnShareBps` and its governance return with the platform buttons in v1.1 (branch `v1.1/platform-buttons`); v1 has no vote because v1 has nothing for a vote to govern. The split between
burning and rewarding is a founder-level design decision and must stay
governance-adjustable; removing the governor here is a consequence of removing
its only reader, not a decision to fix the parameter forever. Every claim in v1's
documents that feast has no owner, admin, upgrade path, pause or vote is a claim
about **v1** and must be written that way.

**The platform 20% accrues to its bucket in v1 and nothing spends it.** The fee
is taken, banked and reported by `platformPending`; `platformUsed` stays zero.
The entitlement is monotone, so v1.1 spends exactly what v1 accumulated, and
nothing is stranded or lost in the meantime.

**Why this and not a sixth round.** Three of round 5's four HIGH classes lived in
the removed subsystem, and one of them — H1 — is not a bug but an open design
question. Cutting removed them by removing their code. The fourth, H3, is fixed
here (B4).

**The open design question v1.1 must answer, before those buttons return:**

> Bound the protocol's own spending against a valuation the router does not
> control.

`FeastConverter` derives its expected output from the prices of the very pools
the caller selected, and checks each against its own history. An attacker who
supplies genuine, mature Q/X and X/WBNB pools with attacker-issued X can take
valuable quote and leave negligible native while every per-hop check passes.
Four attempts have failed, each defeated by a different construction:

| Round | Finding | Attempt, and why it did not hold |
|---|---|---|
| 1 | r1a H4 / r1b H3 | Per-hop tick-deviation bound. Each hop sat inside its own band while the product of the hops did not. |
| 2 | r2a H1 / r2b H1 | Whole-route value bound against the product of spot prices. Still the attacker's own prices. |
| 3 | r3a H1 / r3b H2 | Route floor tightened, `MAX_ROUTE_DEVIATION_BPS`. Same defect: a tighter band around a number the attacker sets. |
| 4/5 | r4a H1 / r4b H3, r5a H1 / r5b H1 | Full-consumption enforcement. Correct and necessary, but orthogonal — it bounds *fill*, never *value*. |

The pattern is one mistake made four ways: every attempt bounded execution
against the route's own prices. A fifth variation on that theme is not worth
attempting. What v1.1 needs is a reference the router does not choose — an
independent oracle for the quote/native pair, an allowlist of routes, or a
protocol-chosen route with the caller supplying only the trigger.

#### Three facts the v1.1 design must start from (owner survey + on-chain probe, 2026-09-09)

**1. A direct stock/BNB pool sometimes exists — but the design may not assume
one.** This corrects deviation D-4 in §2.13, which was written from a single
sample and generalised too far. A QQQB/WBNB PancakeSwap v3 pool does exist
(liquidity ≈ \$288k, ≈ \$4.15M/day at 2026-09-09). But such pools are **thin,
and only some tickers have them**, so a v1.1 conversion path can neither assume a
single hop nor assume a multi-hop route is always required. Whatever replaces the
routing must work when the direct pool is absent *and* not be fooled when a thin
one is present — a thin direct pool is exactly the shape that makes an
attacker-supplied route look reasonable.

**2. The bStock blacklist is default-allow, verified read-only.** At block
120,800,816, `eth_call` of `transfer(to, 1)` from the QQQB/USDT pool returned
`true` to a never-seen EOA, to a contract (WBNB), and to a never-seen address.
So an arbitrary contract **can** receive bStocks, and being unknown is not itself
a refusal. Two rules follow and both already hold in v1, so v1.1 must not
regress them:

- a blocked or paused quote token is a **recoverable failure, never a brick** —
  the claim reverts, the ledger is untouched, and every other pool keeps trading
  (I2, I7);
- **balance-delta accounting only.** The five bStocks share one beacon whose
  owner and `DEFAULT_ADMIN` are single EOAs, so names, supply and UI multipliers
  can change under us. Nothing may be inferred from a token's metadata, and no
  amount may be taken on trust from anything but a measured delta — which is the
  same rule §6c B1 arrived at from a different direction.

**3. Nobody surveyed has solved this, which is the honest reason H1 is hard.**
No surveyed platform performs a permissionless, price-bounded on-chain
conversion. Pons uses a pull ledger with operator-EOA sweeps and a manual TWAP
buyback; Clanker's collect is permissionless with **no price floor at all**;
Flaunch avoids routing entirely by filling internally against the next swap in
its own pool. Four failed attempts at a bounded permissionless route is
consistent with the field, not with a local mistake.

**Candidate v1.1 shapes, pending the owner's ruling — none of them built in this
lane:**

| | Shape | What it avoids |
|---|---|---|
| (i) | Per-asset **pull ledger**: the protocol never routes; entitled parties withdraw their own share | No protocol-chosen route exists, so H1 cannot arise |
| (ii) | The coin's self-burn leg as a **Flaunch-style internal fill** against the next swap in feast's own pool | No external venue, no route, no slippage surface |
| (iii) | The platform-coin leg as **posted redemption**: the contract holds bStock, anyone brings FEAST at TWAP + discount and the FEAST is burned | The counterparty chooses to trade at a published price; the protocol never swaps |

All three replace "bound a route the caller chose" with "have no route at all",
which is the only answer four rounds of bounding did not reach.

### B5. Settlement is bounded, and the ledger is debited by what was paid (2026-09-09, rounds 10-11)

**The predicate.** *No single settlement exceeds what the venue can move in one
signed 128-bit delta, and any ledger it draws on is reduced by the amount
actually paid — never by the amount requested, and never cleared.*

| Round | Finding | What broke |
|---|---|---|
| 10 | r10a H1 | Every claim paid its *whole* entitlement in one settlement. A ledger past `type(int128).max` reverted every claim from then on, permanently; `claimAsBnb` took the same path and could not rescue it. Reachable at 36 decimals — admitted by §3's "at least six" — at about 170 whole tokens. |
| 11 | r11a H1, r11b H1 (both lenses) | The fix was applied at `claimCreator` and `_claimTo` and **not** at `claimReferrer`, which capped the payment and then zeroed the whole entry. That is strictly worse than the defect it was fixing: a claim that reverts keeps the money; a claim that silently deletes the excess does not. The path is permissionless, so a stranger could trigger someone else's loss. |

**This is failure two of a predicate that Rule 8 arms at three.** Both failures
are the same mistake — fixing the site a finding named and not its siblings —
which is the mistake this programme has made more than any other. The four
settlement sites are now enumerated rather than remembered:
`claimCreator`, `claimReferrer`, `_claimTo` (which shares one budget between two
components) and `_release`, with the census listing each.

### B6. The venue's own settlement ceiling on LP fees (declared 2026-09-09, round 11)

**Not fixed. Declared, because feast cannot bound it — and ratified as a
boundary rather than a seal blocker (coordinator, 2026-09-09).** The four facts
the ratification turns on, stated together:

| | |
|---|---|
| **Reachability** | Uncollected LP fees must exceed `type(int128).max` **raw** units. Collection is permissionless and costs one call, so ordinary operation never approaches it. |
| **Cost asymmetry** | Forcing it means donating more than the ceiling — strictly more than everything the attack destroys. |
| **What keeps working** | All four buckets, every claim path, trading, the buy-back button. Nothing anybody is owed is touched. |
| **What is lost** | That one pool's *future* LP income, and nothing else. |

Round 11 (r11a H2): `collectLpFees` collects the locked position's *entire*
accrued fees — `modifyLiquidity` with a zero delta offers no bounded amount — and
the venue narrows each total to `int128` **before returning it**. So the revert
happens inside the venue, before feast can cap, bank or even see the number.
There is no partial collection to fall back on.

Reaching it requires the pool's uncollected LP fees to exceed `type(int128).max`
**raw** units. Two honest observations about that:

- Collection is permissionless and costs one call, so in ordinary operation fees
  are collected continuously and never approach the ceiling.
- It can be *forced*: the venue accepts public donations into an active
  position's fee growth, and feast registers no donation callback. An attacker
  donating more than the ceiling permanently bricks that pool's LP fee
  collection — at the cost of the donation itself, which is larger than
  everything they destroy. What they destroy is the pool's future LP income, not
  anybody's claimed entitlement: the four buckets are untouched and every claim
  path keeps working.

Whether this is reachable *cheaply* is a property of the quote token, not of
feast: at 18 decimals the ceiling is 1.7 × 10²⁰ whole tokens, and at 36 it is
about 170. That is an argument for the v1.1 quote allowlist's admission checks —
a decimals snapshot and seed feasibility are exactly the two that bound it — and
it is recorded there. Until then it is bounded by the app-side allowlist, which
is where Q2 put quote suitability in the first place.

---

### The v1.1 backlog

Everything the v1 cut deferred, so v1.1 starts from a list rather than from
memory. Each entry is one unit with its own audit rounds; the branch
`v1.1/platform-buttons` carries the code that already existed.

**1. Fee handling, as a three-layer floor** (founder ruling, 2026-09-09) — and
with it the reward pot's funding, division and claiming. **No operator bot.**

- **Per-asset pull ledger.** Every fee share recorded in the quote asset it
  arrived in; no layer above can brick a claim. v1 already works this way, and
  v1.1 keeps it as the floor.
- **The coin's self-burn leg: an internal fill.** When a seller arrives, the hook
  takes their coins in exchange for the escrowed quote at the pool's own price,
  before the sale reaches the pool, and burns them. It buys from a real seller,
  moves the price nothing, and creates no separate swap to sandwich. With no sell
  flow the pending burn accumulates, and the fallback is the paced,
  TWAP-bounded, permissionless `buyBackAndBurn` button — the v1 mechanism,
  unchanged.
- **The platform-coin leg: posted redemption.** The contract holds the bStock it
  received; anyone brings the platform coin at TWAP plus a discount to take it,
  and that coin is burned on the spot. No router, no in-contract conversion, loss
  capped by the discount, and it works for a quote with no native pool at all.

*Rejected, deliberately:* buy-and-burn inside the same transaction — a
predictable buy behind every trade is a sandwich target, doubles gas, and pushes
the pool against the trader — and a bot accelerator. The weakening of the "all
fee flow benefits the native asset" narrative is accepted as the price.

**This answers B3's open design question**, at least for these two legs. Four
attempts failed to bound a caller-chosen route because each priced execution
against the route's own pools. All three layers avoid routing entirely: the
ledger never routes, the internal fill trades against a counterparty who came
anyway, and posted redemption lets the counterparty choose to trade at a
published price. That is the shape four rounds of bounding never reached.

**2. A pinned on-chain quote allowlist** (founder ruling, 2026-09-09). One unit,
three inseparable parts:

- the list itself, pinned at deploy as the bStock family **plus WBNB** — a
  BNB-priced coin's platform share needs no conversion, and WBNB is the fallback
  while a bStock is paused;
- **add-only governance** over it, under the same Governor and three-day timelock
  as the burn share;
- the **admission checks** applied to every listed quote, WBNB included: a
  decimals snapshot; a transfer round-trip that rejects tax tokens;
  balance-delta accounting; seed feasibility; a per-quote isolated ledger; and
  never a stock-price oracle. Two of these — the decimals snapshot and seed
  feasibility — are what would bound §6c B6, the venue's settlement ceiling on
  LP fees, so that boundary is an argument for this unit rather than an
  independent problem.

They ship together or not at all: the list without its governance is an
immutable parameter nobody can correct, and governance without the admission
checks admits a token the protocol cannot safely hold.

**3. Governance's return** — the Governor, timelock and voting wrapper, carrying
both governed parameters: `burnShareBps` and the add-only quote allowlist.

*Not in v1, deliberately.* v1 keeps the ratified Q2 shape — the factory is open
to any ERC-20 on chain, leaning on per-pool isolation (I7), with the allowlist in
the app. WBNB is therefore already an acceptable quote asset in v1, which is why
the founder's ruling needed no v1 code change. Adding an immutable on-chain list
now would be a new mechanism in the window before an audit round, which is where
new mechanisms have gone worst in this programme.

---

### B7. Quote tokens that take a cut of a transfer (declared 2026-09-12, v1.6.1)

**Not fixed. Declared.** Settlement retires the entitlement it was asked to pay
and transfers that same number of units; it never reads a balance to see what
arrived. So a quote token that taxes, rebases or otherwise shrinks a transfer out
of the vault delivers less than the ledger retires, and the difference is gone
for good. Both settlement sites inherit it, because both go through one
primitive: the creator's (and referrer's) claim, and v1.6's platform exit.

| | |
|---|---|
| **Reachability** | The quote must take a cut of the *vault's* outbound transfer. An upgradeable tokenised-stock proxy can acquire that behaviour after a pool exists, so this is not only a launch-time choice. |
| **Measured** | At a 1% outbound tax: a creator entitlement of 75 retires in full and delivers 74.25; a platform bucket of 25 retires in full and delivers 24.75 (`test/FeastDeclaredBoundaries.t.sol`). |
| **What keeps working** | Everything else: trading, accrual, the buckets, the buy-back button, the fill. Only the delivered amount on a payout is short, and only for such a quote. |
| **Why not fixed here** | Measuring delivery means a balance read on the payout path plus a partial-retirement rule — a new mechanism, and the wrong week to add one. It also cannot be made whole in general: a token that takes a cut takes it whichever way the accounting is written. The honest fix is admission, not settlement: the v1.1 quote allowlist (§6c B3) is where a token like this is refused entry. |

The app's quote allowlist is what keeps such a token out in the meantime.

### B8. A predicted coin address is not a reservation (declared 2026-09-12, v1.6.1)

**Not fixed. Declared, with the guidance in `docs/interface.md`.** `predictCoin`
commits to the four fields that enter the coin's creation code — salt, name,
symbol, supply — and to nothing else. Anyone who submits those four first takes
that address with economics of their own choosing (creator, quote, shares,
opening price).

| | |
|---|---|
| **What is lost** | The prediction, and nothing else. The launch is not blocked: a taken salt is refused, and the creator relaunches at another salt with their own economics (`test_aPredictedAddressIsNotAReservationButTheLaunchStillHappens`). |
| **Who is exposed** | Only an app that shows, or commits value to, a predicted address before its own `create()` is mined. The interface now says not to. |
| **Cost to the squatter** | A full launch: the whole supply seeded into a pool they cannot withdraw from, at their own cost, to occupy an address with no traffic. |

**The hardening was considered and declined (coordinator, 2026-09-12).** The
candidate was to mix the creator's economic parameters into the salt the factory
passes to `CREATE2`, so that a squat with different economics lands at a
different address, leaving the app's `predictCoin(salt, name, symbol, supply)`
call unchanged in shape. It is not taken, and the reasoning belongs here rather
than in a decision log the auditor will not read:

- **What a squat actually costs is the prediction, not the launch.** The witness
  above shows the creator's own launch still landing, with their own economics,
  at the address their next salt predicts. Nothing is stolen and nobody is
  locked out; an app that waits for its own `create()` to be mined — which
  `docs/interface.md` now tells it to do — is unaffected.
- **The change is to address derivation itself.** Every future coin's address
  would be computed differently, and a prediction interface the app already
  consumes would change meaning. That is a poor thing to re-derive late in a
  package that is otherwise sealed and about to be read by an external auditor.
- **The auditor gets to rank it.** They see this boundary and the interface
  guidance together. If they rate it above nuisance, it becomes a follow-up unit
  — contract change plus the app-side change that goes with it — rather than a
  last-minute re-derivation nobody has lived with.

So B8 stays declared for this package, deliberately.

### B9. A refill smaller than the lot it lands in is sold at the descent's price (declared 2026-09-12, v1.6.2)

**Not fixed. Declared.** v1.6.2 tied the sink's descending clock to the lot it
prices: `open` requires inventory, and a lot holding at least
`SINK_REOPEN_MULTIPLE` (two) times what it held when its descent began — every
refill into an emptied lot included — is priced from the start price again,
by the view and by a take alike. What that rule does **not** cover is a refill
*smaller* than the lot it lands in: the descent stands, and the whole lot,
new units included, is sold at the price that descent has reached.

The threshold is what makes the rule usable at all. Restarting the descent on
any growth whatever would let one wei an hour hold the price at the top for
ever, and the honest fee flow — permissionless, per pool, continuous — would do
it by accident, so the sink would never sell anything.

| | |
|---|---|
| **What it allows** | An attacker who leaves at least as much of an asset in the sink as the next release will bring can run the descent down over their own stake and then take both cheaply. |
| **What it costs them** | The stake, on offer at the same published price for the whole descent. Anyone may take it from them at that price at any point, for exactly what the attacker is waiting to pay. Their downside is the platform's upside, unit for unit. |
| **What it is not** | It is not the v1.6.1 defect (`CA-fb2e051555`), where the clock ran for free on a lot that held nothing at all and no stake was needed. |
| **An asset that shrinks a holder's balance** | A rebase, a clawback, a blacklist burn. Inside the sink `held == offered` after every write it makes — `open` records what it opened over, `take` records what it leaves — so `held > offered` means something arrived and `held < offered` means the asset took a holder's balance away. A descent prices its lot on exactly `offered ≤ held < 2 × offered`; outside that the lot reads from the top and anyone may open a new descent over it (rounds 2 and 3). **What the sink cannot see is a shrink that happens between two of its own writes.** If nobody reopens the lot in the meantime, any later arrival that brings the balance back to between once and twice the recorded size — not merely one that restores it exactly — revives the descent that priced the larger lot, elapsed time and all, and the lot sells at whatever that clock has reached. The whole family needs an asset whose issuer can burn a holder's balance; an issuer with that power can freeze or seize the lot outright, which is worse and is already declared under `VENUE` (`README.md`), and the app's quote allowlist is the admission control for both. |
| **The mitigation is operational, and it is ours** | A keeper that opens a lot the moment it holds less than its descent priced — and, from round 5, a sink that opens no descent at all until the launch window has closed and the coin is in hands that can bid. The reopen is permissionless by construction — whenever the price function refuses to price a lot, `open` accepts it — so the window closes on the first keeper transaction rather than waiting for a stranger. That keeper is the platform's own (task 452); nothing here assumes a stranger will act. |
| **Pinned by** | `test_aRefillSmallerThanTheLotDoesNotRestartTheDescent` (the descent stands for a smaller refill, and the stake that bought that price is takeable by anyone at it), `test_aLotThatShrankIsNotTheLotItsDescentPriced` (a shrunken lot is not priced by its old descent and can be reopened), `test_theDeclaredLimitOfWhatAShrunkenLotCanBeToldFrom` (the revival above, asserted rather than implied), and `testFuzz_aDescentPricesALotExactlyWhenOpeningItIsRefused` (the two readers cannot drift apart). |

Two neighbouring behaviours are consequences of the same rule and are stated
here rather than left to be found:

- **A descent can be reset, and what that does and does not cost.** Two routes
  put the price back at the top: donate enough of the asset to double the lot, or
  buy enough of it that what remains is at most half the size the descent priced.
  This paragraph has been wrong twice, and both corrections came from the lens
  review, so it is worth stating only what is true. The reset cost does **not**
  grow with repetition (round 1). And it is **not** compensation: a reset burns
  the platform coin the purchase paid, at the price the descent had reached,
  which can be *less* than the whole-lot sale it postpones — buying half a lot at
  1.2 coins per unit burns about 60 coins and can postpone a sale of 100 (round
  3). Nor does all the inventory necessarily stay: buying three quarters of a lot
  and returning a quarter leaves the sink with half of what it had, and still
  permits the reopen. What is true is narrower: every unit that leaves was
  **bought**, at the sink's own published price, and every coin paid for it was
  burned. The sink is never made to hand an asset over for less than the price it
  was offering; what a resetter buys is the ability to make the next buyer start
  the descent again.
- **A cold start after a lot is emptied.** The next refill begins at
  `SINK_START_PRICE_Q128`, which is far above any real value by construction, and
  descends an hour at a time. It reaches one platform coin per whole unit of an
  18-decimal asset after about 64 hours, and one further hour for every halving
  below that the asset is actually worth. The lot accumulates while it descends,
  and the post-sale floor still stops the descent six halvings below the last
  sale — itself halving every `SINK_FLOOR_HALF_LIFE` since that sale (v1.6.2,
  H2), so the floor cannot pin a lot above the market permanently.
  Nothing is lost but time — the price of refusing to carry a stale price across
  a period when there was nothing to price.

---

### B4. The progress predicate, withdrawn (2026-09-09, round 6, Rule 8)

**The predicate.** *A press occupies the shared interval only if it made
meaningful progress.*

**Two attempts, and why there was never going to be a third.**

| Attempt | Shape | How it failed |
|---|---|---|
| 1 (round 5 fix, round 6 finding) | Measured on the **request**: `amountIn >= 1%` of the bucket, checked before the swap | r6a H1 / r6b H1, both lenses independently. The check ran before the swap and the settlement ran after it, so a request that cleared the floor and then filled as dust — against a thin range inside the price limit — still consumed the hour. Exactly the griefing the predicate was written to stop. |
| 2 (proposed by both lenses; **rejected at design**) | Measured on the **realised spend**: require `quoteSpent >= 1%` before consuming the clock | Never built. In a pool too thin to fill 1% of the bucket, *no* press can ever satisfy it, so the bucket becomes permanently unspendable. It trades a griefing vector for a stranding vector. r6a asked for this "shallow-pool liveness boundary" to be addressed explicitly; the honest answer is that it cannot be, within this shape. |

The two attempts fail in opposite directions, and that is the tell: the defect is
not in either predicate but in **the shape that requires one**. Any binary "this
press occupies the hour" needs a rule for who has earned the right to occupy it,
and any such rule is either gameable with dust (request-measured) or stranding
(realised-measured). So the mechanism is withdrawn rather than patched a third
time.

**Withdrawn.** The minimum interval, the proportional per-press ceiling and the
progress floor are all gone, along with `TooSoonSinceLastBuyback`,
`BuybackTooLarge`, `PressTooSmall`, `lastBuybackAt` and `nextBuybackAt`. Pressing
the button no longer occupies anything.

**The replacement: a continuous spending allowance.** The button may spend at
most a rate-limited allowance, which accrues linearly at
`ALLOWANCE_BPS_PER_HOUR` of the accrued bucket and is capped at
`ALLOWANCE_CAP_BPS` of it. A press spends
`min(request, allowance, what the pool fills inside the existing price bound)`,
and the **realised** spend, measured from the venue's balance delta, is what is
deducted from the allowance and debited from the bucket.

The rate and the cap **sum** to the hourly bound, which is what keeps it; see
the round-7 correction below, where setting them both to the bound turned out to
permit nearly twice it.

Both failure modes disappear rather than being defended against:

- **Jamming disappears** because nothing is occupied. A dust press deducts dust
  and the productive press behind it proceeds in the same block.
- **Stranding is greatly reduced, not eliminated** — round 8 (M2) is right that
  the stronger claim was unsupported. The allowance keeps accruing and any
  positive fill makes progress, so a pool too thin to fill a whole press still
  drains over time. What remains is a granularity boundary: if the permitted
  press is small enough that the venue returns *zero* coin for it, the press
  reverts and the bucket waits until it grows. Above `MIN_RATIONED_BUCKET` the
  allowance never exceeds `ALLOWANCE_CAP_BPS` of pending, so waiting alone does
  not lift it — a low-decimal quote against a high-priced coin can sit there.
  Declared, not fixed: the alternatives all reintroduce a burst.

**Tip.** `TIP_BPS` = 25 (0.25%) of what the press actually bought, so it is
proportional to the realised spend with no flat component: a dust press earns
dust, which is what makes farming pointless. Paid from the proceeds, so a press
can never cost more than it created.

**Price bound unchanged.** Execution is still bounded against this pool's own
time-weighted price and fails closed when that price is unavailable. The
allowance shifts *timing* only, so per-press loss stays bounded by the existing
bound and per-hour exposure by the allowance.

**Dust.** Below `MIN_RATIONED_BUCKET` the allowance is the whole bucket: a
proportional share of a few raw units rounds to something no pool will fill, and
a print that size cannot be sandwiched by anybody. This is round 5's M1, carried
across intact.

**Held by** `test_aDustPressDoesNotBlockTheProductivePressBehindIt`,
`test_aPartialFillConsumesOnlyWhatItActuallySpent`,
`test_aShallowPoolsBucketStillDrainsOverTime`,
`test_dustPressesEarnDustAndCannotBeFarmed`,
`test_theAllowanceRefillsContinuouslyAndIsCapped`,
`test_anIdlePoolDoesNotBankUnlimitedAllowance`,
`test_aBucketBelowOneUnitOfAllowanceIsNotRationed` and
`test_anOversizedRequestIsClampedToTheAllowance`, with five mutations in
`tools/mutate.py`, and enumerated in `docs/site-census.md` under
`### mechanism: spending-rate`.

**Attempt one of the allowance failed (round 7, r7a H1 / r7b H1); attempt two
is below.** Both lenses, independently, and the finding was against the design's
own paragraph as much as its code: capping the *available* allowance is not
capping *cumulative* spending. A token bucket permits a burst **plus** a refill —
that is what a token bucket is for — so a bucket of 1,000 admitted 280 in thirty
minutes and 359.96 in one hour, against a bound of 200.

The error was a reasoning error rather than a slip: setting the accrual rate and
the cap to the same number reproduces the old ceiling only for a *pure rate
limiter*, not for a bucket that can be full when the window opens.

**Attempt two: the burst and the rate SUM to the bound.**

The bound is stated once, as `MAX_HOURLY_SPEND_BPS` (2,000 — the withdrawn
design's, kept): *at most 20% of an accrued bucket may leave in any one hour,
**except a bucket at or below `MIN_RATIONED_BUCKET`, which may be spent in
full.*** Round 8 (L1) is why the exemption is written into the guarantee rather
than beside it: a window that begins above the threshold and crosses below it
during the hour can spend almost the whole bucket, because the first press
activates the dust branch for the rest of the window. The exemption is
deliberate — an amount that small cannot be rationed into presses that buy
anything, and cannot be sandwiched — but a guarantee that does not name its own
exception is not a guarantee.
The pacing keeps it by construction, because for a token bucket the worst an
hour can carry is its capacity plus one window's refill:

> `ALLOWANCE_CAP_BPS + ALLOWANCE_BPS_PER_HOUR <= MAX_HOURLY_SPEND_BPS`

with `ALLOWANCE_CAP_BPS` = 500 and `ALLOWANCE_BPS_PER_HOUR` = 1,500. Measured
greedily (press whatever is available, every second, for an hour, starting from
a full allowance) this yields **18.2%** — under the bound, with the margin coming
from the base shrinking as it is spent.

The cost is long-run throughput: 15% per hour sustained rather than 20%. The 5%
cap is also the largest single press, which is the sandwich surface, so a
smaller cap is worth something in its own right.

**A fresh pool starts empty**, and nothing at registration says so: the first fee
ever banked settles a bucket that is still zero, which starts the clock at zero.
Two mechanisms establishing the same fact would mean one of them untestable, so
there is one.

**Banking checkpoints accrual first.** Round 7's second defect: accrual is a rate
on the *current* bucket, so raising the bucket without settling first credited
new principal for time in which it did not exist — fees banked a second before a
press received almost an hour of allowance. `_bank` now settles at the old size
before it grows. This costs two storage writes on the accrual path, which is the
honest price of the arithmetic being right.

**What was NOT done, and why it is worth saying.** The ruling was "start empty
and only accrue"; that alone does not deliver the bound. It removes the burst for
a *new* pool, but any pool idle for an hour has a full allowance again and the
36% construction returns unchanged. Verified numerically before implementing.
Splitting the cap from the rate is the smallest change that makes the promise
true, and it is a change to a ratified parameter, so it is flagged rather than
buried: **long-run throughput falls from 20%/hour to 15%/hour.**

**Round 8 corrections (both lenses, HIGH=0).** Two defects, both mine, both in
the machinery above:

- **M1**: `_bank` decided whether to checkpoint by looking at its local
  `selfBurn` share, while LP income redirects the *platform* share into the same
  bucket a few lines later. A pool with `selfBurnBps = 0` therefore grew its
  self-burn bucket with no checkpoint at all, and the allowance was computed
  against elapsed time the new principal had never lived through. The test is
  now the **complete** credit, decided before either credit lands.
- **L2**: the allowance was accumulated in whole quote units, so every
  checkpoint floored the accrual and reset the clock — a stream of tiny fee
  credits could hold it at zero for an hour, a rounded-away second at a time.
  Carrying the lost fraction as *time* instead would have let it accrue at a
  later, larger rate, which is M1 again in miniature. It is accumulated in fixed
  point (`ALLOWANCE_SCALE`) instead: nothing is discarded and the clock always
  advances to now, so no elapsed time is ever re-priced.

**Held by** `test_atMostTwentyPercentLeavesInAnySlidingHour` (greedy, one press a
second for an hour), `test_theThirtyMinuteConstructionStaysUnderTheBound` (the
lenses' own construction), `test_aNewPoolHasNothingToPressUntilItsAllowanceAccrues`
`test_feesBankedLaterDoNotReceiveRetroactiveAllowance`,
`test_lpIncomeRedirectedIntoTheBucketDoesNotArriveWithAllowance`,
`test_frequentBankingDoesNotSuppressAccrual`,
`test_aSmallBucketStillAccruesWhenBankedEverySecond` and
`test_theBurstAndTheRateSumToTheHourlyBound`, plus the earlier allowance
properties, with mutations for the parameter split and the checkpoint.

**A note worth keeping.** Building this closed the last two entries in
`KNOWN_UNKILLED`, which had stood since round 1. Both existed for the same
reason: no fixture could make a press part-fill, so realised and requested spend
were the same number in every test. The allowance made that difference
load-bearing, which forced the shallow-pool fixture that both admissions had been
waiting on. `KNOWN_UNKILLED` was emptied here for the first time. It has since been reopened and re-emptied as fixtures caught up; `tools/mutate.py` is the live record, not this sentence.

---

## 6d. v1.6.3 — the four the dual-family pack proved

The first dual-family `/contract-audit` run on `v1.6.2-internal` (Codex
gpt-6-astra and Claude Fable 5.1, both families, 51-file pack) proved four
findings with failing Foundry tests at the tag — two HIGH, two MEDIUM — and
blocked the seal at proof-gate exit 3. This section is what was done about them.
The working plan, with the change sets line by line, is `plans/v163/plan.md`.

Two of the four sat **inside v1.6.2's own fix pass**: the re-anchor its round 1
wrote, and the share-weighted floor its round 4 wrote. Seven Codex lens rounds
ran over that pass before it sealed and read past all four; the floor erasure was
found by both Claude units independently and by no Codex unit at all. That is why
this pass added a Claude-family lens of its own before sealing, and why every fix
here ships with a PoC, a mutation that reddens a named test, and the property
written into the docstring beside the code.

| | Finding | Where | What it was |
|---|---|---|---|
| **F1** | `CA-fad351f89b` HIGH | `FeastPlatformSink::take` | The re-anchor formed `held + amountOut` in checked arithmetic before handing it to a 512-bit `mulDiv`. Only the sum overflowed. A lot holding an ordinary ERC20's entire `type(uint256).max` supply panicked on every take, and `open` refused to reopen the unchanged lot: the asset was permanently unobtainable. |
| **F2** | `CA-7e9b1e15be` HIGH | `FeastEmissions::_priced` | Settlement froze the pricer's address and every quote's price, but re-read the pricer's quote LIST live at claim time. An accepted module returning a longer list afterwards — no bytecode change, no second privileged call — doubled a settled week's entitlements, above that week's own pot. |
| **F3** | `CA-b229a31396` MEDIUM | `FeastPlatformSink::take` | Every take overwrote the floor and restarted its clock. Round 4's share weighting runs one way: it stops dust *raising* a floor and did nothing to stop dust *erasing* one. One wei of platform coin bought away the floor a real sale had set and sent the remainder back to halving hourly — 754× below, ten hours later. |
| **F4** | `CA-58354019a2` MEDIUM | `FeastConverter::convert` | The nominal amount was pulled and then spent, with nothing measuring what arrived. A taxed input spent a stray donation to cover its shortfall, and without one the identical call was refused. It falsified **B2** in both halves. |

### What the code now says

**F1.** `lot.anchor = price + Math.mulDiv(price, amountOut, held)` — the same
number, since `⌊p(h+a)/h⌋ = p + ⌊pa/h⌋` exactly, and `amountOut ≤ held` is
enforced two lines above, so the added term is at most `price` and the sum at
most twice it. Proved equal by fuzz wherever the old form worked
(`testFuzz_theReanchorIsTheSameNumberWrittenSafely`).

The sink was then swept for every other arithmetic over a balance or an amount.
Two sites — the price's decay and the floor's — multiply by an elapsed-seconds
remainder and so need the price under `2^244`. **That is a bound, not a defect,
and this is its arithmetic.** A take of the fraction `f` re-anchors at
`price·(1+f)`, so one take at most doubles the anchor and a ratchet must use
partial takes. Half a lot of size `L` at `p` costs `pL/2` and lifts the anchor to
`1.5p`; half of *that* costs `0.75` of the step before it; so the whole chain
costs at most `4×` its first take **plus one wei per take** however long it runs,
while lifting the anchor by only `1.5×` a step. The `+1 wei` is the ceiling in
`cost = mulDiv(amountOut, price, ONE, Ceil)`, and at the `price == 1` clamp it is
the whole story: every take costs exactly one wei and the re-anchor stays at 1,
so ten takes of a 1,024-unit lot cost ten wei against a first take of one — four
times the first take is 4, and the geometric argument says nothing there. Round
3's verifier (`r3v`) found the unqualified form false; the witness had allowed
`+ steps` all along, so it was the sentence that was wrong and not the test.
Reaching `2^244` from the `2^192` start price needs ~89
such steps, whose total spend at that price is `2^65·L` wei of platform coin —
inside the coin's entire supply only for a lot under about `2^25` raw units,
which runs out of units after 25 steps. Waiting instead of paying does not help:
time lowers the price a re-anchor is taken from. Pinned by
`testFuzz_aChainOfHalfLotTakesCostsAtMostFourTimesItsFirstTake`.

`_pricesThisLot` is left exactly as written: `held / SINK_REOPEN_MULTIPLE <
lot.offered` divides first, where the natural `held < 2 × lot.offered` would
overflow. And `cost = mulDiv(amountOut, price, ONE, Ceil)` can exceed a word and
revert — for a number of platform-coin wei above `2^256`, against a supply of
about `2^90`. Nothing affordable reverts, and a smaller take always succeeds.

**F2.** Settlement snapshots the quote list it priced into `_weekQuotes[n]`,
each distinct quote once, and `_priced` iterates that and `priceOf[n][·]` and
nothing else. `wk.pricer` remains as the record of which module settled the week
and is read by nothing. Exposed as `settledQuotes(n)`.

The property, stated exactly: **nothing on the owed/claim path asks the pricer
anything after settlement.** Not "no external call" — `_priced` still reads
`ledger.credit`, `claim` reads `hook.poolInfo` through `claimsOpen()`, and `claim`
transfers the platform coin. All three are immutable addresses fixed in the
constructor, replaceable by no lever and by nobody. The pricer is the one thing on this contract a timelock call
can swap, and it is the one thing the path no longer consults.

A duplicate at settlement is **counted once, not refused**, and that choice is
load-bearing. Refusing would hand any accepted module — or an honest one with an
accidental duplicate — a way to brick settlement for good: `settle` runs strictly
in order, so week `n` reverting blocks weeks `n+1 … 52`, and the only way out
would be the same lever under suspicion. Counting once also keeps the two halves
of a claim's fraction consistent: the denominator `value[t]` accumulates per
distinct quote and the numerator iterates that same distinct list.

**F3.** > **A take may raise the standing floor, never lower it, and never
> restarts a clock it did not raise.**

The decayed floor is factored into one helper, `_floorNow` — *the floor now, on
its own clock* — read by the price path and by `take` alike. `take` computes the
sale's own share-weighted floor and writes `floorBase`/`lastSaleAt` only when
that strictly beats the standing floor, comparing effective floor with effective
floor. `open` still clears both for a new descent, and is now the only thing that
can clear them.

### P19, restated as what the code enforces

The old sentence — *"after a sale the price never falls below that sale's
share-weighted price halved `SINK_FLOOR_HALVINGS` times, on that sale's own
clock"* — was written for a world in which every sale set the floor. Under the
maximum rule it splits in two:

1. **The floor a sale actually set is held exactly, on its own clock.** A later
   sale that does not raise it writes nothing — not the base, not the clock — so
   the curve it started continues undisturbed. A sale that DOES raise it is
   exactly not-lower at the instant of the sale, and thereafter within **one raw
   price unit** of what leaving it alone would have given: a raising write starts
   a fresh curve from a higher base, and the same two truncations that the chord
   gap needs its slack for can leave the fresh curve a unit under the old one's
   continuation. Round 2's hunter found that before the provider's content
   filter stopped it; the counterexample and the one-unit bound are pinned by
   `test_aRaisingTakeIsExactAtTheSaleAndWithinOneUnitAfterIt` and
   `testFuzz_aRaisingTakeNeverCostsMoreThanOneUnitLaterOn`.
2. **A later, LOWER sale's own-clock floor is held to within the decay curve's
   chord gap — never worse than 8/9 of it, LESS AN ABSOLUTE SLACK OF FOUR RAW
   PRICE UNITS.**

The decay is `d(x) = 2^(−⌊x/H⌋)·(1 − {x/H}/2)` — halvings of
`H = SINK_FLOOR_HALF_LIFE`, then **linear** inside the half-life in progress. A
chord above an exponential is above it, so `d(a+b) ≤ d(a)·d(b)`: a restarted
clock never loses, and the single clock the contract keeps never gains. The most
it can be under is at `a = b = H/2`, where `d(H/2) = 3/4` gives `d(a)d(b) = 9/16`
against `d(a+b) = d(H) = 1/2` — a ratio of `9/8`. Writing `a = H(k+f)`,
`t = H(m+g)`, the ratio is `1 + fg/(4 − 2(f+g))` below the carry and
`[(1−u) + p/2]/(1 − u/2)` above it, and both peak at `f = g = 1/2`, so `9/8` is
the maximum over all ages — 12.5%, of a number already `SINK_FLOOR_HALVINGS` (a
factor of 64) below the sale that seeded it.

**And then the slack, which is not decoration.** All of that is about real
numbers. `_floorNow` shifts down and then floors one linear step, and the promise
is read the same way, so two readings truncate twice each and the real bound can
be missed. Round 1's verifier (`r1v`) found the unqualified clause false and gave
a sequence that reproduces exactly in the contract's own arithmetic: a published
price of **1** against an own-clock promise of **2**, a ratio of one half. Hence
the four raw units. Where four units matter the relative half says nothing and
the slack is the whole promise.

**What four units is worth, stated properly.** An earlier draft of this section
called it "economically zero". Round 3's verifier (`r3v`) showed that is false,
and the correction is worth more than the claim was: a take pays
`amountOut × price / 2^128`, so a shortfall of four Q128 units over a lot of `N`
raw units is up to `4N / 2^128` platform coin. Per raw unit that is nothing; over
an enormous lot it is not. On the lens's own sequence — a lot of about `8 × 10^59`
raw units — the measured difference is **2,360.75 FEAST**, and the stated slack
would bound it at **9,443 FEAST**. The floor there is one or two Q128 units, so
the shortfall is of the same order as the whole remaining price; that is the
clamp's territory, where the sink's rule is only that a take always burns
something. The honest statement is therefore: *the slack is four raw units of
Q128 price, which is a real number of platform coin on a large lot, and it is the
price of reading a decaying floor with integer arithmetic.* It is not zero and it
is not called zero.

**One thing the ruling assumed which measurement contradicts, recorded because
it is the more useful fact.** The coordinator asked for a second assertion: that
above `2^64` the relative bound alone holds with slack 0, that being the region
the old witness lived in. It does not hold there — or anywhere. At `a = t` of
exactly half a half-life the real inequality is **tight**, the ratio *being* 9/8,
so the truncations cross it at every magnitude. The fixed counterexample is a
floor of **9,999** raw units (`f = 19,998`, both ages half a half-life), which is
not a small number by any reading. So the slack is structural rather than a
small-magnitude artefact, and the assertion written in its place says exactly
that. The measured maximum shortfall over the whole domain is **2** units against
a stated 4.

Pinned by `testFuzz_theChordGapIsNeverWorseThanEightNinthsLessItsSlack` —
log-uniform over the whole domain, because a uniform draw from `[1, 2^192]` is a
draw from the top few bits and would never visit the magnitudes where the claim
is weakest — by `test_theChordGapNeedsItsAbsoluteSlackAtEveryMagnitude`, and by
`test_theLensSequenceHoldsUnderTheRestatedClauseAndNotTheOldOne`, which runs
round 1's own sequence through the real contract and asserts that the old clause
is false there and the restated one holds. Stated in the docstring at the write
itself.

**What the rule costs, stated rather than left to be found.** A floor is cleared
by `open` and by nothing else. Before v1.6.3 a sale could clear one — which is
exactly the erasure — so a floor carried by an emptied lot into a refill now
stands until a keeper opens a descent over that refill. It stands in the safe
direction: an unopened lot reads at the start price or the floor, whichever is
higher, so a carried floor can only make the sink refuse to sell cheaply, and
`open` is permissionless (B9 already names the keeper). Pinned by
`test_aCarriedFloorIsClearedByOpeningAndNotByASale`.

**F4.** Every leg of a conversion is measured — inbound by the balance across
the `safeTransferFrom` (clamped at the nominal, and a non-positive arrival a
named refusal), intermediate by this contract's balance of each hop's output
across the swap, outbound by bounding each hop's payment at what that hop
brought. B2 above is restated on that basis, one leg at a time. The first
version of this fix measured the inbound leg alone; round 1 of the lens found
the other two, and `docs/plan.md` §B2's table is the result.

`_validateHop` stays **before** the transfer. The reason in its docstring was
always a legibility one — a caller on a route that could never have been priced
is told the pool's oracle is unusable, rather than that their allowance is short
— and it survives: every refusal a caller can trip over still happens before
their allowance is spent.

**One thing measured rather than argued.** Moving the route floor's accumulation
after the transfer puts it downstream of anything a hostile `tokenIn` does inside
its own `transferFrom` — including moving the very pool the floor is computed
from. Measured: with the price re-read after the transfer, a token that halves
its pool's square-root price on the way in is converted at a quarter of what the
deviation check vouched for, because the expectation moves with the pool and the
shortfall it exists to catch cancels out exactly. So `_validateHop` now returns
the square-root price its own spot-versus-average check bounded, and the
expectation is built from that price carried forward rather than from a fresh
read. For an honest token this is the identical number and one `slot0()` per hop
instead of two. Pinned by
`test_aTokenThatMovesItsPoolDuringTransferCannotWidenTheRouteFloor`, whose tooth
was checked to bite before it was written down.

**Two things this pass decided rather than inherited**, both inside F4. The
coordinator's ruling for F4 was to keep `_validateHop` before the transfer and
move the `expectedOut` accumulation after it; these two are how that was
implemented, each measured before it was written down. **Both were put to the
coordinator and both are ruled to stand** (2026-09-13), for the reasons measured:
a token that moves its own pool inside `transferFrom` must not be converted at a
price the deviation check never vouched for, and a token crediting more than was
sent must not make the route spend more than the hook accounted for.

They are **declared, not settled.** Restating either is a declaration and not a
finding; a finding *against* either — a case where the carried price is the wrong
anchor, or where the clamp strands or misroutes value — counts at the bar, from
either lens family.

1. **The route floor's price is carried, not re-read.** Measured, above: a fresh
   read after the transfer admits a conversion at a quarter of what the deviation
   check vouched for. Carrying the validated price is the identical number for an
   honest token and one `slot0()` per hop instead of two.
2. **`received` is clamped at `amountIn`.** The ruling says to spend what arrived
   and never the nominal; for a token that delivers *more* than asked, spending
   "what arrived" would spend this contract's own balance, which is the defect
   F4 exists to close, pointed the other way. Measured: without the clamp a token
   crediting 10% on top has the route spend 11 where the hook sent 10
   (`test_aTokenThatDeliversMoreThanAskedDoesNotHaveTheSurplusSpent`).

**B7 is untouched and stays declared.** The ledger still retires the nominal
entitlement on the hook's *outbound* leg, and this pass does not touch the hook.
B7 is about what the vault pays out; F4 is about what the converter receives.
The `Converted` event now reports what arrived — an indexer sees the truth rather
than the claim — and no on-chain number depends on it: the hook's accounting
reads the return value, which was already measured per hop from the venue's own
signed answer.

### The lens record

**Round 1 (Codex gpt-6-astra, verifier + hunter, over `3856ba6..9a2d159`):
HIGH 1 · MEDIUM 3 — every one of them inside this pass's own four fixes.**
`FIX_EDGE: DEFECTIVE`. Under rule 8 — a HIGH inside one's own fix hands over —
this pass stopped there and made no further source change. The findings are
below as they were verified, not as they were claimed.

| # | Lens | Bar | Subject |
|---|---|---|---|
| 1 | r1v | HIGH | F3's 8/9 chord-gap bound is a real-valued claim and is false in integer arithmetic at small floor magnitudes |
| 2 | r1v | MEDIUM | F4's inbound subtraction underflows when a token *reduces* the converter's balance across `transferFrom` |
| 3 | r1v | MEDIUM | F4 does not bound the converter's own outbound debit, so a surcharge on `converter → pool` is met from a donation |
| 4 | r1h | MEDIUM | F4 measures only the FIRST token; a taxed intermediate on `pool → converter` is met from a donation |

**Finding 1, reproduced in the contract's own integer arithmetic.** A lot of
`2^200` units, opened, left 172 hours (price `2^20`). A take of `3 × 2^186`
sets `floorBase = 192`, an effective floor of `3`. Twelve hours later the price
is `256`; a half-lot take's own floor is `2`, which does not beat `3`, so nothing
is written — correct under the maximum rule. Twelve hours after that the descent
has decayed to `0`, the standing floor is `3 >> 1 = 1`, and the second sale's
own-clock floor is `2 − ⌊2 × 12/48⌋ = 2`. The published price is `1` against a
promise of `2`: a ratio of **1/2**, not 8/9. The chord-gap derivation is right in
the reals; `_floorNow` shifts down and then floors the linear term, and at floors
of a few raw units that rounding dominates the bound entirely. **The witness this
pass wrote did not catch it because it was bounded away from exactly that
region** — `base` fuzzed over `[2^64, 2^192]`, with an absolute `+8` slack that
absorbs the very rounding at issue. A witness that cannot fail where the claim is
weakest is not a witness.

**Findings 2, 3 and 4 are one finding about F4's shape.** A conversion has three
kinds of leg — `hook → converter` inbound, `pool → converter` intermediate, and
`converter → pool` outbound — and F4 measured the first. The other two still
spend numbers the converter did not verify it holds: `_hop` hands the next hop
what the *pool reported* sending, and `pancakeV3SwapCallback` pays what the pool
*asks* out of the converter's balance. A quote that taxes either of those legs is
made whole from a stray balance, and is refused without one. So **B2's
restatement above claims more than the code delivers**, and finding 2 adds that
the inbound measurement itself is a checked subtraction that panics outright when
a token shrinks the converter's balance during the transfer — with a donation
deciding whether it panics.

**Rounds 2 and 3 (Codex): zero HIGH from both lenses in each, which is the
termination.** Round 2 returned one MEDIUM (B2 has a limit no measurement can
reach) and a second finding recovered from a hunter the content filter stopped
("never lower" is exact at the sale and a unit under afterwards). Round 3
returned three MEDIUM, all of them claims this pass had written that the code
does not deliver, and a `VERDICT: PASS` from its hunter. `r2h` is recorded
`unmeasured: codex-refused` — the provider's content classifier stopped both it
and its one permitted relaunch.

**The Claude-family verifier (`claude-fable-5-1`) ran on the final diff and
returned HIGH 0 · MEDIUM 2**, both again in the prose: the invariant list still
carried a sentence round 3 had retracted everywhere else, and B2's declared limit
named two shapes where there are three. It added eight execution notes, every one
of them a place this pass's words had drifted from its code — including three
witness names in `plans/v163/plan.md` that named tests which do not exist. All
are fixed. Its verdict was voided by its runner on a grammar check and is kept
as recovered evidence; `plans/v163/plan.md` has the detail.

**Across seven lens reads in two families: the mechanisms held and the sentences
did not.** One HIGH, ten MEDIUM, and all but the HIGH's mechanism were claims
wider than the code they described.

<!-- v163-lens-record -->

---

## 6e. v1.6.4 — the three the dual-family pack proved, and the sweep behind the HIGH

The dual-family `/contract-audit` run on `v1.6.3-internal` (Codex gpt-6-astra and
Claude Fable 5.1, 51-file pack at `c69080f`) proved three findings with failing
Foundry tests at the tag — one HIGH, two MEDIUM — and blocked the seal. Four at
v1.6.2, three at v1.6.3: the loop converges. The working plan, with the change
sets line by line and the measurements that shaped them, is `plans/v164/plan.md`.

| | Finding | Where | What it was |
|---|---|---|---|
| **G1** | `CA-5ba81ae0e6` HIGH | `FeastGenesisGrants::unlocked` | `grant * referredNative[partner] / targetNative` formed its numerator in checked 256-bit arithmetic and clamped to `grant` only afterwards. The partner who had referred the MOST — the one who had most earned the grant — was the one whose numerator overflowed. `claim` and `burnUnearned` both route through `unlocked`, so the grant stranded and its unearned remainder could never be burned; `burnUnearned`'s once-only flag meant the horizon could not be closed out either. |
| **G2** | `CA-4ce8a94deb` MEDIUM | `FeastPlatformSink::schedule` | The docstring said the genesis key's discretion was "bounded at both ends: never a time already past, and never further out than the longest gate the hook itself will accept". Neither end was enforced; a window closing 365 days out was accepted. Found by **both** lens families independently. |
| **G3** | `CA-7e39484115` MEDIUM | `FeastHook` buy-back (and `FeastConverter`) | `MAX_SLIPPAGE_BPS = 300` is documented as the widest move from the time-weighted price, and its companion `MAX_TICK_DEVIATION = 300` states "the same tolerance". But the buy-back scaled the SQUARE-ROOT price by `(BPS ± 300)/BPS`, and a ratio on a square root is squared in the price it bounds: the button permitted `1.03² = 6.09 %`, twice what it documented and twice what the tick check beside it admits. |

### What v1.6.3's sweep taught, and what this pass did about it

v1.6.2 found this overflow shape in the sink (`CA-fad351f89b`). v1.6.3 closed it
there, as F1, and **looked nowhere else**. One release later the identical
shape — a product formed in checked arithmetic ahead of the operation that would
have made it harmless — came back as a HIGH in a contract that was already in the
tree when F1 landed.

> **A shape closed in one contract must be swept across all of them in the same
> pass.** The unit of a fix is the shape, not the line the lens pointed at.

So G1 is one line of fix and thirty rows of table. Every `x * y / z` in `src/` was
enumerated and given either a bound argument a reviewer can check or a
`Math.mulDiv` rewrite; sites whose operands are not bounded by a creation-time cap
got the rewrite, because a bound resting on how many settlements an attacker can
afford is not a bound. The full table is `plans/v164/plan.md`. Its shape:

| disposition | rows | examples |
|---|---|---|
| **mulDiv** | 10 | the grant's quotient; the sink's two decay steps; the launch window's pro-rata; the converter's route floor and fee deduction; the emissions value cap; the hook's allowance accrual, cap and rate |
| **bound, from a compile-time constant** | 6 | `PLATFORM_SUPPLY * GRANT_BPS_EACH`, the three genesis splits, the emissions budget and curve |
| **bound, from the new `MAX_SUPPLY`** | 3 | the factory's creator allocation, the hook's per-wallet cap, the vesting entitlement |
| **bound, from the venue's `int128` settlement** | 6 | the tip, the four fee-split shares, the two scaled allowance debits |
| **bound, from an enforced domain guard** | 5 | the emissions track shares; `_quoteForCoin`/`_coinForQuote`'s squares, guarded by `MIN_FILL_SQRT_PRICE`..`MAX_FILL_SQRT_PRICE` |

### The supply cap, and the measurement that produced it

`FeastFactory.create` took `p.supply` from the caller and capped it nowhere, so
every `supply * bps / BPS` was unbounded above. This was **measured**, not argued
(`plans/v164/plan.md` carries the harness and its output):

- `FeastHook`'s `supply * CAP_BPS_OF_SUPPLY / BPS` panics `0x11` for
  `supply > (2²⁵⁶ − 1) / 50`;
- the factory's own `supply * creatorAllocationBps / BPS` panics for
  `supply > (2²⁵⁶ − 1) / 2000` at the maximum allocation;
- and because `registerPool` runs **before** `_seed`, that panic fires ahead of
  every named refusal the factory has, including `PoolTooShallow`.

`FeastConstants.MAX_SUPPLY = type(uint128).max`, refused in `create` with
`SupplyTooLarge(uint256)` ahead of `registerPool`. The number is chosen so that
the venue's own bound is stated by name rather than met opaquely: a seed moves the
pool amount through the vault in one settlement and `_pay` takes an `int128`, so a
supply above `MAX_SETTLEMENT` cannot be seeded at all. It bounds every
`supply * bps` product under `2¹⁴²`, and it sits eleven orders of magnitude above
`PLATFORM_SUPPLY`.

*The brief that ruled this closure anticipated the panic at a supply near
`2²⁵⁶ / BPS`. At exactly that supply the refusal is **named** (`PoolTooShallow`),
not an overflow; the overflow threshold is higher, at `2²⁵⁶ / 50`. The remedy is
unchanged and the number is recorded as measured.*

### G1, and a correction to the ruling's literal form

The ruling read `unlocked = min(grant, Math.mulDiv(grant, referred, target))`,
"512-bit intermediate, cannot panic". **That parenthetical is wrong, and the fuzz
witness found it rather than the argument.** OpenZeppelin's `Math.mulDiv` carries
the *intermediate* at 512 bits but panics when its **result** exceeds 256 bits —
which `grant × referred / target` does once `referred / target` passes
`2²⁵⁶ / grant`. The literal spelling therefore reintroduces this very finding in a
narrower range: a product formed ahead of the clamp that would have made it
harmless, which is the shape of the finding one level up.

So the minimum is established **before** anything is multiplied:

```solidity
uint256 referred = referredNative[partner];
if (referred >= targetNative) return grant;
return Math.mulDiv(grant, referred, targetNative);
```

Past the target the published rule is `grant` by inspection; below it the quotient
is strictly less than `grant` and cannot overflow at all. `unlocked` is now total
for every input, which is what `claim` and `burnUnearned` need to be reachable.
Both spellings are pinned by mutations: restoring the original reddens the PoC,
and the ruling's literal `mulDiv`-then-clamp reddens the fuzz.

### What the code now says

**G2.** `schedule` refuses `closes <= block.timestamp` with
`WindowAlreadyClosed(closes)` and `closes > block.timestamp + MAX_GATE_DURATION`
with `WindowTooFarOut(closes, bound)` — the hook's own predicate at
`FeastHook.sol:224-231`, on the same constant, so the sink and the hook now refuse
the same set. A fuzz asserts exactly that correspondence over the whole `uint64`
range.

**G3.** One derivation, `FeastMath.sqrtPriceLimit`, used by the hook's button and
by the converter — which carried the identical expression against the identical
constant, and which this pass swept rather than leaving for the next one. The
limit is `sqrtPrice × √((BPS ∓ tolerance) × BPS) / BPS`, so squaring it returns the
documented tolerance in price. **Each limit is rounded towards the current price**,
which is the only direction that cannot loosen the bound: the rising side floors
the root (`⌊√103 000 000⌋ = 10148`, a permitted rise of 298 bp), and the falling
side takes the ceiling (`⌈√97 000 000⌉ = 9849`, a permitted fall of 299.7 bp —
flooring there would give 301.7 bp, outside the tolerance). `MAX_TICK_DEVIATION` is
left alone: ticks are already price-based.

### The one residual, recorded rather than closed

The hook's allowance cap and rate (`_allowanceShape`) are improved but not made
total. `mulDiv(pending, ALLOWANCE_SCALE × ALLOWANCE_CAP_BPS, BPS)` exceeds 256 bits
for `pending > ≈ 2.3e60`, against the old spelling's `≈ 1.16e59` — twenty times the
headroom, not infinite headroom. The remaining gap rests on a **counting
argument**, and is labelled as one: `pending` accumulates from fee accruals each
bounded by an `int128`, so reaching that value needs on the order of `1e22`
separate settlements. Not reachable, but not a proof from a creation-time cap
either, and this pass has no clean way to add one without changing what the
allowance means.

### What G3 does not close, and the sentence that moved instead

Round 1's verifier pointed out that `MAX_SLIPPAGE_BPS` was documented as the widest move *from the
time-weighted price*, and the new limit is derived from **spot**. The two checks compose rather
than coincide: `_requireSpotNearAverage` admits a spot up to 3.045 % from the average, and the
press may then walk the price a further 2.98 % from that spot — about **6.1 % from the
time-weighted price** for a press admitted at the edge of the tick check.

That is the composition the original finding's own PoC named as "the lens's wider point" and
deliberately scoped out of its assertion, and closing it means deriving the limit from the average
rather than from spot — a different design. So the **sentence** moved: `FeastConstants` now says
that this bounds a move in price, from spot, caused by the button's own swap; says explicitly that
it is *not* a bound from the time-weighted price; and states the composed figure an integrator
should hold it to. The companion constant's "the same tolerance" is withdrawn — the two are
numerically equal and semantically different, which was the other half of the original finding.

### The lens record

**Round 1 (Codex gpt-6-astra, verifier + hunter, over `3fc27d4..44041f0`): HIGH 0 · MEDIUM 5 ·
LOW 1 — every one of them in this pass's own sentences rather than its mechanisms.** Neither unit
refused; both pinned the tree.

| # | Lens | Bar | Subject |
|---|---|---|---|
| 1 | r1v | MEDIUM | `MAX_SLIPPAGE_BPS` still documented as a bound from the TWAP; the limit is from spot and the two compose to ≈ 6.1 % |
| 2 | r1v | MEDIUM | The sweep's "every `x * y / z`" claim missed four signed fee expressions in `FeastHook` |
| 3 | r1v | MEDIUM | The plan promised witnesses that did not exist: limit-reaching probe fixtures, a `uint160`-wide fuzz, per-site extreme fuzzing |
| 4 | r1h | MEDIUM | `mutate.py`'s restore-on-start replayed its journal unconditionally and could revert a corrected file to a stale snapshot |
| 5 | r1h | MEDIUM | At the top of the price range the unchecked `uint160` narrowing wrapped a rising limit to below spot |
| 6 | r1h | LOW | Slice selection had no bounds check; `--slice 20/20` selected nothing and exited 0 — a gate that could not fail |

All six are closed. Two produced real code changes — `FeastMath.sqrtPriceLimit` now clamps into the
venue's own bounds, and `_specifiedLegFee` narrows the swap amount before multiplying it by the fee
— and both were labelled by the lenses as pre-existing rather than introduced, so neither engaged
rule 8. Two were the sweep's own completeness claims, which is the price of making a claim that
strong; the answer taken was to keep the claim and make it true rather than to weaken it.

**The mechanisms held under both lenses.** G1's early return was checked at every boundary, all
twenty original BOUND rows were re-derived and stood, G3's polarity was verified at both call
sites, and all four tests this lane edited were judged to have kept their original intent.

**Round 2 (same units, over `3fc27d4..41f4587`): HIGH 0 · MEDIUM 5 · LOW 1** — the second
consecutive zero-HIGH round group, which terminates the codex loop. The most valuable was the LOW:
the G3 assertions measured the permitted move in whole basis points, which *floors* it, so a rising
limit permitting 300.2201 bps measured 300 and passed "at most 300". The assertion could not fail in
the direction the finding was about. It is now made at 1e12, and a mutation for the rising ceiling
is caught.

**The Claude-family verifier (`claude-fable-5-1`) on the final diff: HIGH 0 · MEDIUM 1 · LOW 3.**
Its verdict was voided by its own runner on a grammar check — no `VERDICT:` line — exactly as at
v1.6.3, and is kept as recovered evidence under `.runs/codex-loop/v164-claude/`; every citation in
it was checked by hand. **It found the one thing two Codex rounds did not: G3's own sibling sentence,
left standing.** `FeastConverter.MAX_TICK_DEVIATION` is a public constant whose docstring still
called 300 ticks "a shade under 3% — the same tolerance `MAX_SLIPPAGE_BPS` expresses", and §2.13's
converter row above said the same and added "Same safety property". Both halves are wrong: 300 ticks
is 3.045%, a shade *over*, and the two compose rather than coincide. **The sentence half of
`CA-7e39484115` was closed at one site and not its siblings, in the pass whose own rule is that a
shape closed in one contract must be swept across all of them.** Its three LOWs were the same
family: two sweep-table rows still naming fuzzes that do not exist, a `MAX_SUPPLY` justification
wider than the code, and the claim that the sink and the hook "refuse the same set" — they do not,
because the hook bounds the window's close *plus an hour of grace* and the sink bounds the close.
It also noticed that G2 narrows a genesis recovery path that nothing had recorded. All four are
closed.

**Across three lens reads in two families: fifteen findings, zero HIGH, and not one a defect in a
mechanism.** Every one was a sentence that claimed more than the code beneath it kept — which is
what this project wrote about v1.6.3, now true of v1.6.4, including once for failing to sweep the
very sentence whose unswept sibling is the reason this pass exists.

<!-- v164-lens-record -->

---

## 6f. v1.6.5 — the two the dual-family pack proved, and the sweep v1.6.4's sweep did not do

The dual-family `/contract-audit` run on `v1.6.4-internal` (two Codex units and two Claude Fable
units, hook checklist 23/23, dynamic 439/0, mutation 192/193, 239 raw findings, pack at `2bc9c19`)
proved two findings with failing Foundry tests at the tag — one HIGH, one MEDIUM — and blocked the
seal at proof-gate exit 3. **Both are in one function**, `FeastEmissions::settle`. Four at v1.6.2,
three at v1.6.3, two at v1.6.4: the loop converges. The working plan is `plans/v165/plan.md`.

| | Finding | Where | What it was |
|---|---|---|---|
| **F1** | `CA-5203dcf236` HIGH | `FeastEmissions::settle`, the value cap | `valueCap = mulDiv(mulDiv(feesNative, ratio, BPS), perNative, ONE)` was formed and only THEN compared with the token cap. `Math.mulDiv` carries its intermediate at 512 bits and panics when its **result** exceeds 256 bits, so a week whose settled cap is the token cap — a number under `2^93` that never needed the value cap to compute — reverted on the size of the side the comparison discards. Settlement is strictly in order, so that week blocked every week after it. Reported independently by **both** Codex units. |
| **F2** | `CA-81659c1034` MEDIUM | `FeastEmissions::settle`, the pricing grace | Past the grace, every non-`Ok` pricer status for a listed quote collapsed into price zero, while the same function kept `Moved` and `Unpriceable` apart for the platform coin thirty lines below and refused `Moved` past the grace as well. The quote leaves the week's snapshot, so every payer, creator and referrer in it is owed nothing for the week and every genesis partner's `referredValue` reads zero — counted once by `checkpoint` and never revised. Found by the Claude-family lens and by no other. |

### What v1.6.4's sweep missed, and why it missed it

v1.6.4 exists because v1.6.3 closed an overflow shape at the site a lens pointed at and looked
nowhere else. Its answer was to enumerate **every `x * y / z` in `src/`** — thirty-four of them —
and give each either a bound argument or a `Math.mulDiv` rewrite. Ten rows got the rewrite. Row 17
of that table is `feesNative * valueRatioAt(w) / BPS`, at `FeastEmissions.sol:293`, and the comment
the pass left at that site says the site was swept.

It was not. **A `mulDiv` is not a bound.** It moves the failure from the intermediate to the result
and leaves the result unasked. §6e above says exactly that, four paragraphs before the table —
about the G1 ruling's literal spelling, where the fuzz witness falsified it — and the table was
built anyway with **mulDiv** in the disposition column as though the rewrite were the closure.

> The sweep enumerated by the **shape of the expression** and closed by the **shape of the
> rewrite**, when the thing it was hunting is a **failure mode**: a product whose result may not
> fit. A population enumerated by syntax cannot be closed by syntax.

So v1.6.5's sweep re-enumerates by the failure mode, over the population the last pass created:
**every `Math.mulDiv` call in `src/`, found by reading each file rather than by grepping one
alias** — thirty-four executable calls in twenty-eight rows, each with a RESULT bound a reviewer
can check or a rewrite. The full table is `plans/v165/plan.md`. Its shape:

| disposition | rows | what the bound rests on |
|---|---|---|
| **total** | 11 | the result is smaller than an operand for every input of the declared types — a factor under one, `weight <= total`, `elapsed < window`, `mine[t] <= value[t]` |
| **bound, from a constant or an enforced guard** | 9 | the ledger's `uint80` fee fields, `MAX_VALUE_RATIO_BPS < BPS`, `MIN/MAX_FILL_SQRT_PRICE`, `MAX_SETTLEMENT`, the platform coin's own `1e27` supply, and `type(uint160)` itself |
| **rewrite** | 1 | F1, the finding |
| **bound, from the VENUE rather than from this tree** | 1 | `FeastPricer._ratioQ128`'s reciprocal branch |
| **unbounded — recorded in the code, not closed** | 3 | the sink's take cost, and the converter's two compounded hop expectations |
| **counting argument, labelled as one** | 3 | the hook's allowance cap and rate (carried forward from §6e), and the accumulation of a week's track values across the quote list |

### F1, and the bound it rests on

```solidity
uint256 inner = Math.mulDiv(feesNative, valueRatioAt(w), FeastGenesis.BPS);
(uint256 high,) = Math.mul512(inner, perNative);
if (high < ONE) {
    uint256 valueCap = Math.mulDiv(inner, perNative, ONE);
    if (valueCap < cap) cap = valueCap;
}
```

The minimum is established **before** anything is multiplied out, which is v1.6.3's own rule, in
the idiom this repository already had for exactly this question: `FeastPricer.priceQ128` takes the
top word of a 512-bit product and asks whether the quotient fits before forming it
(`src/FeastPricer.sol:141-143`). The bound is not conservative, it is exact —

> `valueCap < 2^256` ⟺ `inner × perNative < 2^384` ⟺ `high < 2^128 = ONE`

— which is precisely when `mulDiv` does not panic. And when `high >= ONE` the comparison's answer
is already known without forming either side: `valueCap >= 2^256` while `cap <= tokenCap(n) <=
budget < 2^93`. The inner product cannot overflow at all, because `valueRatioAt` is capped at
`MAX_VALUE_RATIO_BPS = 2000` against a divisor of `BPS = 10000`. **No published number moves.**

**The measurement.** The boundary is `perNative = ceil(2^384 / inner)` — for the PoC's fees,
`(2^192 + 2)/3` — the smallest platform price whose value cap needs more than a word. It is
asserted against `mul512`'s own high word, and one unit below it the value cap is `2^256 - 2^64`,
the largest **this inner operand** can produce inside a word, and is *still* the discarded side.
(The quotient at the boundary itself is `2^256 + 2^65`, not `2^256`: the first draft of that note
said `2^256`, which is what it would be if `inner` were a power of two. Round 1's verifier caught
it; the constant and the guard are unchanged.) The witness sits **on**
the boundary and at a distance of **one** from it, because §6e records this pass's predecessor for
an assertion that could not fail in the direction its finding was about. A mutation flipping
`high < ONE` to `high <= ONE` is killed by that witness and by nothing else in the suite.

### F2, and why the two statuses cannot share an outcome

`FeastPricer.Status` has three members and the two non-`Ok` ones do not mean the same thing:

- **`Moved`** is a price the pool HAS and the oracle will not vouch for — spot more than
  `MAX_TICK_DEVIATION` from its own ten-minute average (`FeastPricer.sol:190-191`). The pricer
  calls it "retry, never guess" (`:155-157`). It is a statement about one block's spot against a
  ten-minute window, and `settle` is permissionless, so a refusal here **can** end — and that is
  the strongest form of it that is true. It is not guaranteed to: see the correction below.
- **`Unpriceable`** is no route, too little history, an oracle that will not answer, or a composed
  two-hop price no word can hold. None of those need ever resolve — and the suite already pins the
  last one as *permanent*, in `test_aRoutePriceTooLargeToHoldBlocksItsWeekOnlyForTheGrace`.

Q11's rule — wait out the grace, then count it as zero — is therefore a rule **for a price that may
never come**. It buys termination at the cost of one week's valuation of one quote. It was never
right for a status that self-heals, and zero is the one guess that status forbids. The code now
branches: `Moved` refuses by name with `QuotePriceMoved`, inside the grace and past it alike, as
the platform coin's `Moved` has since round 4; `Unpriceable` keeps Q11's rule untouched. Each
branch has its own witness, and the second `Moved` witness is the one that matters — the spot comes
back inside the bound, the week settles at a real price, and the payer is owed what the old rule
erased. Without it, "refuse and wait" is only half measured: a refusal that never resolved would
pass the first witness and brick every later week.

**Two things this pass first claimed here and had to correct, both from round 1's verifier.**

*The wait is not guaranteed to end.* The comment said the average "catches up by itself" and this
section said refusal "terminates". Neither is unconditional: a pool whose spot keeps moving against
its own average — ticks alternating either side of the window's mean — holds `Moved` for as long as
it keeps moving. And the recovery witness does not wait it out; the fixture's pool carries its
average as a settable field, so the test supplies the correction rather than observing one. What it
measures is that recovery WORKS once the spot is back inside the bound. Both the comment and the
test's own docstring now say that, and the residue is recorded rather than tested away.

*The refusal reached further than the branch it mirrors.* Every listed quote is priced before the
week's fees are known, and the platform coin's price is consulted only when the week HAS fees. So a
continuously moved quote carrying no credits could hold up a week that needed no valuation at all —
a reach the platform branch does not have, in a fix whose whole claim is that the two halves agree.
`Moved` is now refused only for a quote that carries fees that week, at the cost of one ledger read
on the refusal path, with its own witness and its own mutation.

**What remains, recorded rather than hidden.** A quote that carries fees and whose pool stays moved
holds up settlement, and settlement is ordered. That is the same trade the platform-coin branch
already takes ("for ever if need be, until the pricer lever replaces the pricer"), with the same
escape hatch. Residue row `R-F2-liveness`.

### The two rows the sweep found in other contracts, and did not close

Neither is in the contract this pass was scoped to, and both are recorded **in the code**, where a
reader meets them, rather than only in a plan — the sweep's rule is a bound or a rewrite, never
silence. Both are questions to the coordinator in `plans/v165/plan.md` (Q2, Q3), and both were
measured rather than argued:

- **`FeastPricer._ratioQ128`, the reciprocal branch.** `2^320 / sqrtP²` is inside a word by
  0.0075 % at the venue's `MIN_SQRT_RATIO`, and crosses it at `sqrtP <= 2^32` — a measured 161 443
  units below that floor. `sqrtPriceX96 == 0` divides by zero outright, and `_vouch` refuses
  neither, though `platformPerNativeQ128` refuses zero. A panic there contradicts the contract's
  own first sentence and, because `settle` reads `priceQ128` in a loop, would block every emission
  week: **F1's shape reached from the other side**. (The first draft of this note said the panic
  starts immediately below `MIN_SQRT_RATIO`. The measurement says otherwise; the sentence is
  corrected and the remedy is unchanged.)
- **`FeastPlatformSink.take`.** `cost = mulDiv(amountOut, price, ONE, Ceil)` panics once
  `amountOut × price > 2^384 - 2^128`; at the opening price the smallest take that panics is
  exactly `2^192` raw units. v1.6.3 made the *re-anchor* total for a whole-`type(uint256).max`
  lot; its witness takes **one** unit, so it never reached the line above it. *This pass first
  wrote that a take of `2^192 - 1` units "still settles". It does not* — all three lenses said so.
  Its cost is `2^256 - 2^64` platform coin against a whole supply of `1e27`, so it fails at
  `CostAboveLimit` or at the transfer; **the entire supply buys 54 210 108 raw units at that
  price**. Below the threshold the cost CALCULATION fits, and nothing more. What the panic costs is
  legibility rather than funds: an impossible take answers with a panic instead of the named
  refusal it has.
- **`FeastConverter._expectedAfterHop`.** Rows 16–17 of this sweep were **wrong when written**, and
  all three round-1 lenses found it independently. They bounded the hop input by the venue's
  `MAX_SETTLEMENT`, which holds for the FIRST hop only: `convert` feeds each hop's expected output
  into the next, so hop two's input is hop one's output. Measured: `amountIn = 2^126` through two
  forward hops at `sqrtPriceX96 = 2^157`, both inside the venue's range, needs 309 bits at the
  second hop's inner quotient and panics — before any swap runs, on the size of an EXPECTATION
  rather than of anything it was going to move. One conversion, on a route whose pools sit at those
  prices; the remedy is a bound or a named refusal, and it is Q8.

  That a sweep written to catch exactly this shape stated a false bound of its own is worth saying
  plainly. The population was right; the row was lazy — it read the ceiling at the call site's
  first caller and never followed the loop that feeds it.

### One identifier changed in a pack's proof, declared

F2's closure needs a named `QuotePriceMoved` to mirror `PlatformPriceMoved`, so the MEDIUM's PoC —
which asserted `QuoteUnpriceable` — has **one identifier** amended, its original line kept verbatim
in a comment beside it. The assertion's intent is untouched: settlement is refused and
`settledCount` stays 0. The alternative, reusing `QuoteUnpriceable` for both statuses, keeps the
proof byte-identical and leaves one error name telling a caller "unpriceable" about a price the
pricer says it has. Recorded here because a lane editing the proof that judges it is worth saying
out loud.

### The lens record

**Five reads in two round groups, all `codex gpt-6-astra` at effort high, every one of them
pinned to the oid it was given and every citation in the closed `path:line:sha8` form. HIGH 0 in
all five, which is the termination.**

**Round 1, three lenses launched together on `20e5a68`** — a VERIFIER on the closures, a HUNTER
for anything new, and a FRESH-EYES review asked to endorse or refuse the seal. **HIGH 0 · MEDIUM
6 · LOW 7**, in 451 s, 361 s and 286 s.

| # | lens | bar | subject |
|---|---|---|---|
| 1 | r1v, r1h, r1e — **all three, independently** | MEDIUM | sweep rows 16–17 bounded the converter's hop input by `MAX_SETTLEMENT`, which holds for the first hop only; `convert` feeds each hop's expectation into the next |
| 2 | r1v | MEDIUM | F2's refusal reached further than the branch it mirrors: a moved quote carrying no fees could hold up a week that needed no valuation |
| 3 | r1v | MEDIUM | the rounding witness divided exactly at every step, so it could not detect the rounding change it claimed to kill |
| 4 | r1v, r1h, r1e | MEDIUM | the sink note said a take of `2^192 - 1` units "still settles"; its cost exceeds the whole platform supply |
| 5 | r1e | MEDIUM | the v1.6.5 receipt did not exist and the gate table held expectations rather than measurements |
| 6 | r1v | MEDIUM | (with 2) the liveness prose: "the average catches up by itself", and a recovery witness that supplies its own correction |
| 7 | r1h | LOW | `mutate.py`'s recovery deleted the journal and the original-source snapshot in a `finally`, so a restore that RAISED left the mutant installed and destroyed the only copy of what it replaced |
| 8–13 | r1v, r1e | LOW | the boundary quotient is `2^256 + 2^65`; 34 executable `mulDiv` calls, not 30; row 5's bound is `<=`; row 28's constant is the LARGER one, so the rate overflows first; the fuzz has no ratio parameter and cannot; the census declared 240 rows and contained 242 |

**Round 2, verifier and hunter on `5724ad3`: HIGH 0 · MEDIUM 1 · LOW 4** — the second consecutive
zero-HIGH group. The MEDIUM was this receipt, still unwritten. The four LOWs were two more gates
that could not fail — a forge process *killed* before it ran anything scored as a mutation kill,
and the census accepted a settlement site under a shorter site's name by substring — and three
sentences this pass had corrected in one place and left standing in another, which is the exact
defect §6f is about, committed inside its own correction.

**What the lenses did not find.** No HIGH in five reads. No defect in either closure's arithmetic:
`high < ONE` was independently confirmed exact, the token cap independently confirmed the smaller
side above it, the empty-quote skip independently confirmed to change no claim and no grant. The
findings were, again and almost entirely, **sentences claiming more than the code or the
measurement beneath them kept** — this time including four of this pass's own, two of them inside
the sweep whose whole purpose is to stop exactly that.

**One departure from the v1.6.4 shape, recorded rather than glossed.** That pass's third read was a
Claude-family verifier. This lane may not spawn sub-agents, and the coordinator did not answer the
question about it (`plans/v165/plan.md`, Q5), so all five reads here are one family. A
second-family read on this tag remains available to the coordinator and is the thing this record is
weakest for lacking.

<!-- v165-lens-record -->

---

## 6g. v1.6.6 — the three the v1.6.5 sweep measured and the coordinator ruled closed

`plans/v165/plan.md` ended with eight questions and was anchored `plan-stop`. The ruling
(`plans/v165/ruling.md`, 2026-09-15) arrived after `v1.6.5-internal` had already been sealed on
the recommended path — the first run was killed by an account quota wall before it was written —
so nothing sealed was undone and this section is what the ruling added on top.

**Q1** taken as recommended: a named `QuotePriceMoved` and the one-identifier amendment of the
pack's PoC, with the standing rule stated for the first time — *an edit to a pack's proof is
declared, kept beside the original, and does not weaken the assertion's intent.* **Q4** carries
rows 27–28 forward unchanged; **Q7** leaves the `Unpriceable`-inside-grace asymmetry as
`R-grace-reach`; **Q5** confirms the lens shape; **Q6** agrees this was never the owner's call.

**Q2, Q3 and Q8 are fixed.** All three are the shape the whole pass is about — a product whose
RESULT may not fit a word, formed before anything asked whether it could — and all three now
**refuse by name** where they panicked:

| | Site | The defect, and the closure |
|---|---|---|
| **Q2** | `FeastPricer._vouch`, `platformPerNativeQ128` | `_ratioQ128`'s reciprocal branch leaves a word at `sqrtP <= 2^32` and divides by zero at `0`. `_inVenueRange` refuses a square-root price outside the venue's own `MIN_SQRT_RATIO..MAX_SQRT_RATIO` in **both** readers, so the contract's own totality sentence is kept by code rather than by the venue's good behaviour. `FeastEmissions.settle` reads `priceQ128` in a loop over every listed quote, so a panic there is `CA-5203dcf236`'s shape reached from the other side. |
| **Q3** | `FeastPlatformSink.take` | A cost no word can hold answered with a panic where every other limit there has a name. `mul512` first, then `CostAboveLimit` saturated — `maxCoinIn` is itself a `uint256`, so no limit can be above such a cost. |
| **Q8** | `FeastConverter._expectedAfterHop` | `convert` feeds each hop's expectation into the next, so only the FIRST is bounded by the venue's settlement ceiling — the row the v1.6.5 sweep got wrong and all three of its lenses caught. Each step is now `_scaleOrRefuse`, refusing with `RouteExpectationTooLarge(pool, amountIn)`. |

### What the closures cost, and what they measured

**Nothing reachable moves.** Q2's bound is one a real v3 pool cannot leave; Q3's threshold sits
fifty orders of magnitude above what the platform coin's entire supply can buy; Q8's needs a route
whose pools sit at prices no sane route reaches. What changes is the **answer at the extreme**: a
named refusal instead of an arithmetic panic, in three contracts whose documented promise was
already that they do not panic.

**The one-bit gap, one last time, inside the fix for it.** Q3's guard cannot ask only whether the
high word fits. `take` rounds the cost UP, and between `2^384 - 2^128` and `2^384` the FLOOR of the
quotient is still a word while OpenZeppelin's `result += 1` panics in checked arithmetic. That band
is one part in `2^256` wide — and it is **reachable through the sink's own price ladder**: one
second before the sixty-fourth half-life, at a measured `amountOut`, with its own witness and its
own mutation. A guard on the floor alone reddens it.

**Q3's number.** v1.6.3 closed `CA-fad351f89b` so that a lot holding an asset's entire
`type(uint256).max` supply could be bought from, and its witness proves that by buying one unit.
That witness does reach the cost calculation; what it never reached is the OVERFLOW, which one unit
at any price this sink publishes is nowhere near. (Round 1's verifier corrected this pass for
writing that it "never reached the line" — a fix does not get to enlarge the defect it closes.) The
largest take anyone can actually pay for is **54 210 108 raw units** at the opening price, and that
take now has a witness of its own that goes through.

**Q8's counterexample is the test.** `2^126` through two forward hops at `sqrtPriceX96 = 2^157`,
both inside the venue's range: the first expectation occupies 248 bits and the second hop's inner
step needs 309. The refusal names the pool and the amount that reached it — and that amount is the
first hop's **output**, not the route's input, which is the entire content of the row that was wrong.

### Two things the gates themselves taught, again

The platform half of Q2's guard replaced a `sqrtPriceX96 == 0` check that had stood since v1.6
**with no witness at all**: removing it broke nothing in the suite until this pass's test existed.
And Q8's comment displaced the find string of a v1.6.3 mutation, whose anchor named the
`zeroForOne` line that opens *both* `_hop` and `_expectedAfterHop` — caught by the static anchor
audit, which is round 2's own finding (*a mutation whose find string no longer matches is a gate
that silently checks nothing*) doing its job one release later.

### The lens record

**One round group, two lenses, `codex gpt-6-astra` at effort high, both pinned to `6a9b5bf`:
HIGH 0 in both**, which is what the ruling asked for before sealing. MEDIUM 0. LOW 5, all
accepted and closed — and one of them was in the production code the ruling had just added.

| # | lens | bar | subject |
|---|---|---|---|
| 1 | r1v | LOW | **Q2's predicate was wrong at one end.** It excluded `MIN_SQRT_RATIO`, but the venue's *stored-price* domain is `[MIN, MAX)` — `TickMath.getTickAtSqrtRatio`, which `CLPool.initialize` calls, accepts the minimum, and the reciprocal there fits a word with 0.0075 % to spare. The strict domain belongs to a swap LIMIT, which is a different quantity about a different thing. The guard now admits the floor, and its witness asserts a price there rather than a refusal. |
| 2 | r1v | LOW | **Q8's witnesses did not reach their own boundary.** Neither case had `high == d`, so relaxing the guard to `high > d` changed nothing; and both routes ran FORWARD, so leaving the reciprocal arm unguarded escaped them while sweep row 17 closed the reciprocal case on their strength. Two new witnesses, at exactly `high == d` and at the reciprocal arm's own boundary, each straddled by one unit of input. |
| 3 | r1v | LOW | Three records claimed more than they kept: that v1.6.3's one-unit witness "never reached" the cost line (it does — what it never reached is the overflow); that the one-second-earlier test kills the high-word-only guard (it does not — the rounding-band test does); and sweep row 12's "refuses neither", now marked as what it was when written. |
| 4 | r1h | LOW | **An RPC failure inside a test still counted as a mutation kill.** v1.6.5 round 2 fixed the case where the process never ran; this is the case where it ran and the network failed under it, printing exactly the markers the textual classifier looked for. The classifier is now structural — `forge test --json`, a result per test — and a kill needs at least one failure whose reason is not the harness. Six probes in the self-test. |
| 5 | r1h | LOW | **The census's stale-row probe passed for the wrong reason**: it deleted a site AND added an unlisted one, and the addition alone caused the rejection. It also never tested `listed − source` at all. Both fixed — and the first spelling of the new check flagged `burnFilledCoin` and `_fill`, which settle through the vault without going near `_release`, so the rule is now about whether the function EXISTS rather than whether it reaches the primitive. A check deciding what a census section is about would have been the same defect one level up. |

**What this round did not find.** No HIGH, no MEDIUM, and no defect in the arithmetic of any of
the three closures: `high >= d` was independently confirmed exact, Q3's two clauses independently
confirmed necessary, the rounding band's `amountOut` and the `54 210 108` figure independently
recomputed. Every finding was a boundary a witness did not reach, a gate that could pass without
checking, or a sentence wider than its code — which is now four passes running.

**Round 2, the same two lenses on `bef3ce4`: HIGH 0 · MEDIUM 0 · LOW 7** — the second
consecutive zero-HIGH group, which is the termination. Nothing in the three closures' arithmetic
was faulted in either round; everything found was a witness that stopped short, a gate that could
pass without checking, or a record that outlived its own correction.

| # | lens | subject |
|---|---|---|
| 1 | r2v, r2h | **The reciprocal witness accepted a panic.** Its lower case used a bare `expectRevert()`, so unguarding the arm's OUTER step — where the compounded size actually lands — left both assertions passing. It now names the exact refusal and the exact intermediate, and both outer-step escapes have mutations of their own. |
| 2 | r2v | The classifier still scored a kill on a failure record with **no reason at all**, and misread ordinary assertion prose (`assertion failed: failed to get expected payout`) as an infrastructure failure, throwing a real kill away. Markers are anchored to the start of the reason now, a missing reason is not evidence, and a payload that is not forge's shape counts as nothing. |
| 3 | r2h | **`_release /* c */ (` escaped settlement discovery**, which matched one literal spelling — so a new payout path could acquire no census obligation while the gate passed. |
| 4 | r2h | **A commented-out test still satisfied every census obligation**, because test discovery read raw source. |
| 5 | r2v | The declaration index read line by line and required whitespace after the keyword, so it found **zero of the sixteen constructors**, missed a name on the next line, and counted block-commented functions as declared. It is a whole-file match over uncommented source now. |
| 6 | r2v | Three records still carried the superseded domain: `_ratioQ128`'s "strictly inside", row 12's reference to a test that had been renamed, and row 17 closing the reciprocal direction on the forward witness. |
| 7 | r2v, r2h | Two witnesses claimed one unit less "converts" when both expect a further refusal — the route is far past any size that converts, and the pair is about WHERE the refusal falls. |

All three source scanners share one comment stripper now, and take their source as a parameter so
the five new probes drive the real parsers rather than re-spelling them — which is the defect this
project has caught in its own witnesses four passes running, and caught again this round in the
first draft of the census probe.

<!-- v166-lens-record -->

---

## 6h. v1.6.7 — what the dual-family pack found on the sealed tag

The `/contract-audit` pack ran on `v1.6.6-internal` with two lens families over one
byte-identical brief per unit: a **coverage** unit over the whole shipped set and the mandatory
**hook checklist** (23 rows). This section is what it found and what was done about it; the pack
itself is `audit-pack/`.

**The brief was rewritten before the units ran, and that is why there is anything to report.**
The v1.6.4 pack used the v1 coverage brief — it names the factory, the hook and the epoch ledger,
and never mentions `FeastEmissions`, `FeastPricer`, `FeastPlatformSink`, `FeastGenesisGrants` or
`FeastLaunchWindow`. Both of that pack's proven findings were in contracts the brief does not
name, and so was every fix of the two releases since. `docs/audit-briefs/v166-coverage.md` covers
the shipped set by file and names the five guards v1.6.5 and v1.6.6 added as the least-reviewed
code in the tree.

| | Finding | Family | Where | What it was |
|---|---|---|---|---|
| **P1** | pre-launch value cap | **Claude only** | `FeastEmissions::settle` | The first-week rule was decided on **price availability**; the contract's own docstring says it is decided on the **launch state**, "never on price availability (round 4 H1)". A price exists before the pool opens — the launch window's own settling swap writes the platform pool's first oracle observation, and `MIN_OBSERVATION_AGE` (300 s) sits far inside `SETTLE_GRACE` (an hour) — so for 55 minutes a week could settle either way. Measured on the fixture's own calendar, where week 2 closes at the very second the window ends: **0.149 against 5 255 443 platform coin**, decided by whoever called `settle` first. |
| **P2** | native-quote claim | **both** (codex ×2 units MEDIUM, Claude LOW) | `FeastHook::claimAsBnb` | A pool quoted in wrapped native has no route the converter accepts — an empty route is refused, every route must end in wrapped native, and no hop may return to the input token — so the documented convenience path reverted for every argument. The platform coin's own pool is quoted in wrapped native. Nothing was stranded: plain `claim` pays the same token. |
| **P3** | oracle window floor | codex, both units | `FeastOracle::consult` | Its docstring says the window is "shortened, but never below the floor". It floored the **history** and not the **window**, so any caller could ask a pool with hours of history for a one-second average and get one. No shipped path did: the hook and the pricer both read `twapTick`, whose window is the fixed 600. |

**All three are fixed.** P1 asks the launch state first and the price second. P2 pays a
native-quoted claim directly, which took one line because `_claimTo` now returns what it released
— a better number than the balance delta the first draft measured, because it is what the ledger
was debited by. P3 clamps the window to the floor it promises.

**Three sentences were false and are corrected at their source**: the interface said an internal
fill's burn "happens without a separate transaction" (the separate transaction is exactly what it
takes); it promised the sink's floor was the last sale's, from that sale's clock (a sale that does
not beat the standing floor leaves it in place); and `FeastConstants` said only two ticks are
"ever initialised" (the hook registers no liquidity callbacks, so anyone may add a position).

### What the sweep said about the fix

The mutation for P1's neighbouring refusal — a pre-launch `Moved` price waiting out the grace —
**survived**. Nothing in the suite noticed it being deleted. That refusal predates this pass and
the fix carried it into a new branch with no witness watching, which is the tool reporting a
missing test rather than a passing gate. `test/FeastV167Bounds.t.sol` now pins all three
behaviours of that branch on a fixture that can drive the launch state and the platform status
independently — which the real fixture cannot, because before the pool opens nobody but the
launch window can move the platform price at all.

Two older mutations lost their anchors to the restructure and were re-anchored with their intent
unchanged. The static anchor audit caught both: round 2 of the v1.6.5 pass, still working.

### The run itself, recorded rather than tidied

**Round 1 lost all four units to operator-side failures.** Both codex units were `STALL_KILLED` at
1800 s of silent log — four heavyweight read-only units on one machine starve each other, and a
whole-`src` read with a 236-record triage thinks for a long time between writes. Both Claude units
were `VOIDED`: the runner watches HEAD, each scope directory's tree oid **and the worktree's
status**, and an operator edited `.gitignore` while they were reading. Round 2 launched two units
at a time against a frozen tree and three of the four landed.

**The hook unit's Claude half is `UNMEASURED`** — `fable-unavailable`, the account's session
limit, after 1468 s. It was not relaunched and was not substituted by another model. So the hook
checklist has one family's answers (19 HOLDS, 1 FINDING, 3 N/A across 23 rows) and not two, and
the pack's coverage table says so rather than implying a second reading that never happened.

<!-- v167-record -->

---

## 6i. v1.6.11 — the launch window becomes a real uniform-price auction

Design and rulings: `plans/audit/window-auction-design.md`. Spec: `docs/tokenomics-v1.6.md` §2.

**What was wrong.** The window bought with the whole pot in ONE swap up a
single-sided curve. Everybody paid the same AVERAGE price, but a swap up a curve
ends at the MARGINAL price and that is where it left the pool — about
`sqrt(multiple)` above what every committer paid. Buys are capped at 0.5% of
supply in the opening blocks (R5) and sells are deliberately not, so the first
committer to sell took that premium out of the pot and the last one ate it. The
site's promise — *窗内所有 BNB 按一个清算价成交* — was a uniform average price
plus a race.

**What it is now.** A fixed tranche (`WINDOW_TRANCHE_BPS`, half the holding)
clears at one price `p* = (total - total/100) / tranche`; the pool is created BY
the settlement, at that price, with the unsold supply above it and the whole net
pot below it as permanently locked bid liquidity. Genesis no longer initialises
or seeds the platform pool, because the price it must open at is not known until
the window closes.

**Four consequences that are not details, each ruled by the owner:**

| | consequence | ruling |
|---|---|---|
| licence | one-sided liquidity cannot be derived without tick maths, and the venue's is GPL-2.0 while `src/` is MIT | vendor Uniswap v4-core's MIT `TickMath` (with `BitMath` and `CustomRevert`, which it imports) into `lib/uniswap-v4-core/`, and TEST that it agrees with the venue's in both directions rather than assert it |
| oracle | only a swap writes an observation; the auction has none | **no trade, no price.** `FeastPricer` answers `Unpriceable` from the open until a real trade has aged past `MIN_OBSERVATION_AGE`, and a week settling in that gap takes the written first-week rule. Eight tests rewritten to say so |
| alignment | a position boundary must be a multiple of the tick spacing, which here is 200 — one spacing is 2.02%, more than the 1% fee | align to the side that is **cheaper in coin**, so the opening spot is never above what committers paid. The cost is that the first seller pays up to one spacing; the alternative is handing them that spacing free |
| the fee | there is no swap to take the 1% | `settle` transfers it to the platform sink as wrapped native. Keeping the fee route OUT of the hook is what let the hook fit: 23,537 of 24,576, margin 1,039 |

**What implementation found that the design did not.** Three defects in the
first working settlement, all found by tests rather than by reading:

1. **The coin's currency slot was assumed.** A pool's price is currency1 per
   currency0 and the platform coin's address is whatever CREATE2 produced, so it
   is as likely to sort above the wrapped native as below it. `settle` computed
   the reciprocal price, aligned the wrong way and applied each liquidity
   formula to the wrong asset in that case. The default unit fixture sorts the
   coin into slot 0, so no existing test covered the other orientation;
   `FeastWindowAuctionInvertedTest` searches deployment nonces until the sort
   flips and runs the whole auction suite again against it.
2. **`Math.mulDiv` panics on an overflowing RESULT**, not merely an overflowing
   product. Inverted, the radicand is `tranche · 2^192 / net`, so a pot under
   about 1.7e7 wei panicked. It is now refused by name, which leaves the window
   unsettled and every commit refundable — the written failure route.
3. **`seedWindowPool` did not burn what the positions did not take.** The
   creator path has always burned it (I14, with a 1% tolerance so a mis-stated
   liquidity reverts rather than burns the supply); the no-commit path leaves
   0.1% of the holding — 600,000 FEAST — unplaced by construction, and it would
   have stranded in the hook for ever.

**What did not change.** No tick maths written in `src/`. No admin path to move
a pool's price — the pool is simply not initialised until the price is known. No
weakening of `SeedWouldNeedQuote` for creator launches. No change to R5, the
opening cap, or the creator's pre-buy. The refund rules are unchanged other than
the order they become reachable in.

## 7. Open questions for the owner

### Blocking — the plan cannot be executed without these

**Q1. Licence.** The MIT interface set is not closed (§1(b)): a shipped file
importing `ICLPoolManager` reaches 16 GPL-2.0-or-later files, and `ICLHooks`
imports it, so there is no way around by import selection. Reimplementing the
two bit-shift helpers — the survey's escape route — does not resolve it.
Three options:

- **(a)** Release feast under GPL-2.0-or-later and import the venue freely.
  Costs nothing for an anonymous, verified-source, unowned contract, and
  arguably helps credibility. Simplest.
- **(b) — recommended.** Keep `src/` MIT by declaring the ~150 lines of venue
  interface feast actually calls (§2.4), confining every GPL file to `test/`.
  Enforced mechanically by the checker that already exists, and asserted
  ABI-identical against the real deployment by fork test. Costs one small module
  and one class of "did you re-declare it correctly" risk, which a selector
  test closes.
- **(c)** Dual-license, MIT where possible, GPL where forced. Worst of both:
  a reviewer has to hold two licences in their head while reading one hook.

**Q2. Quote tokens.** The survey could not verify from a first-party source that
the product's "stock token" branding refers to the token family it probed; all
the vendor's documentation URLs returned 404. Before an address goes into an
immutable contract: which exact contracts, and is the factory **open to any
ERC-20** as a quote, or restricted to an immutable allowlist fixed at
deployment? Per-pool isolation (I7) means an open factory only endangers the
pool that chose a hostile quote — but it also means anyone can mint a
feast-branded pool against anything. *Recommendation: open, with the allowlist
living in the app rather than the contract, because an on-chain allowlist that
cannot be extended is a slow-motion owner function.*

**Q3. Settlement route.** There is no quote/BNB pool; the sample quote token's
liquidity is against USDT on v2/v3. Three shapes:
(i) caller-supplied route validated by a TWAP-derived `minOut` — the bound *is*
the safety property, so the path can be untrusted, and liquidity migration does
not brick the button; (ii) an immutable route quote→USDT→BNB — no
caller-chosen-path surface, but brittle the day that pool moves;
(iii) denominate the treasury in USDT and make the platform pool TOKEN/USDT —
one hop shorter, but it discards "every fee buys the chain's own asset", which
is the whole pitch to this chain. *Recommendation: (i), keeping BNB.*

**Q4a. Epoch length.** Timestamp-based and immutable; the spec says "per day".
Confirm 86,400s. Also: do unclaimed pots stay claimable forever (value can sit
unclaimed indefinitely, but no one is expropriated) or roll into a later epoch
after N epochs (no dust, but a deadline is a de-facto expropriation)?
*Recommendation: claimable forever.*

**Q4b. The cross-quote-token denominator — not addressed by the spec.** The pot
is claimed pro-rata by "fees paid", but fees are paid in different quote tokens
across pools, and one unit of a $400 stock token is not one unit of a $20 one.
Summing them nominally hands the pot to whoever trades the highest-priced stock.
Two workable shapes: (i) **one epoch ledger and one pot per quote token**
(`epochPaid[epoch][quote][payer]`, `epochTotal[epoch][quote]`, pot credited from
the BNB that that quote token's own conversions produced) — correct, attribution
preserved, at the cost of tracking platform BNB per quote token; (ii) a single
ledger in nominal quote units — one slot cheaper and visibly unfair.
*Recommendation: (i). This plan is written against (i).*

**Q5. Caps.** The spec cites two different shapes: a competitor's 2-block window
with 5% holding and 5.5% purchase caps, and "≤0.5% of supply per wallet for the
first N blocks". Which N, which percentage, and is the cap denominated in **coin
bought** (a share-of-supply story) or **quote spent** (a fairness-of-spend
story)? *Recommendation: coin bought, N = 2, 0.5% of supply.*

**Q6. Governance parameters.** Proposal threshold and quorum, both as a fraction
of the platform token's **immutable initial supply** (§2.10 deviation 2), not of
wrapped supply. The suggested 1% / 4% are adopted unless changed. Also: voting
delay and voting period — `GovernorSettings` needs both, and neither was
specified. *Recommendation: 1-day delay, 7-day period, so the 3-day timelock is
not the only thing standing between a proposal and a change.*

**Q7. LP fee rate.** Separate from feast's 1% hook take, the pool carries the
venue's own static LP fee, which accrues to the only LP — the permanently locked
position — minus the venue's 33%. Setting it high raises revenue and the
all-in cost of trading feast coins. No number is in the spec.

**Q8. Where the locked position's LP fees go.** They accrue to a position no one
can withdraw. Not addressed by the spec. *Recommendation: into the same four
buckets via a permissionless `collectLpFees()`, so one rule explains all
protocol income.* The alternative — leaving them to compound — means feast
publicly accrues value it can never route, which invites exactly the wrong
question.

**Q9. Platform token, creator = burn address.** Requirement (d) sets the creator
to the burn address and the self-burn share to 0, which strands the creator
remainder (~70% of the platform token's own fee) at a dead address forever.
Spec §9.9 claims the platform token's fees "100% burn", which is only true if
that remainder is routed. *Recommendation: when `creator == BURN_ADDRESS`, the
creator remainder joins the platform bucket, making §9.9's claim literally true.
Three lines, and it materially changes the platform token's story.*

### Non-blocking — a documented default is taken unless overruled

**Q10. Self-referral.** A swapper can name themselves as referrer; the rate is
fixed at creation, so this is a self-rebate, not an exploit. *Default: allowed
and documented, because blocking it is unenforceable anyway.*
**Superseded — the default was overruled and this paragraph outlived it.** v1.6
ruling 5, Q5 refused a referrer who is the payer, and v1.6.8 moved that refusal
up into `_referrerFor` so it covers both `hookData` forms from one line. A
self-referral pays nothing and binds nothing. A second address still evades it,
and that is accepted; what is no longer true is the sentence above.

**Q11. Fee-payer identity** for caps and epoch credit: `tx.origin` or the
router's `sender`. Both are wrong in different directions. *Default: `tx.origin`,
documented as a known limitation (§2.11).*

**Q12. Position NFT.** The direct-liquidity lock means the pool's liquidity is
invisible to the venue's own UI and position tooling. *Default: accepted — this
is much cheaper to decide now than after the lock is immutable.*

**Q13. Cross-chain address parity.** If not required, §2.17 drops to plain
`CREATE2` and one line. *Default: not required.*

**Q14. Creator's vesting share** — the fraction of supply a creator may allocate
to themselves, and the vesting duration. *Default: a hard cap on the fraction,
duration set by the creator at creation within an immutable band.* **(Not built: v1 enforces no minimum or maximum duration — zero means immediately vested. Round 10 M1; recorded as a design intention, not shipped behaviour.)** The platform
token uses zero, per requirement (d).
