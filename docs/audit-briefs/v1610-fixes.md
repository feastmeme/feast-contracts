# v1.6.10 — the three proven findings, fixed; and the hook no longer fits

Task 567, branch `feat/v1.6.10-fixes`, cut from `15415d2` (the v1.6.9 pre-audit round, whose
proof gate exited 3 on three findings). The coordinator ruled the three fixes by their nature on
2026-09-19 under the 2026-09-13 precedent. **This document is the receipt, and the seal is NOT
taken**: `FeastHook` is over EIP-170 at this commit and cannot be deployed.

## The blocker, first, because it decides everything else

| build | runtime bytes | margin against EIP-170 (24,576) |
|---|---|---|
| `v1.6.9-internal` | 24,447 | **+129** |
| + the referrer fix only (CA-0d1fa81d6c) | 24,553 | **+23** |
| + both hook fixes | 24,659 | **−83** |

The referrer fix fits with 23 bytes to spare. The opening-cap fix costs 106 bytes and 23 remain.
`FeastFactory` is 16,489 with 8,087 to spare, so the vesting fix is unaffected.

`forge test` does **not** enforce EIP-170 — the suite is 517 passed, 0 failed, 0 skipped on this
tree — so nothing but `forge build --sizes` says so. The v1.6.4 pin note warned that "the
direction is one way, and the next feature has less room than the last one did". This is where
that ends.

**What was already spent getting there.** The first draft read `opener` and `capEndBlock`
unconditionally and cost 343 bytes. Folding the protocol-swap test into `_referrerFor`, so it is
emitted once instead of at both call sites, saved 65. Merging the cap's arming into the gate's
own comparison — which `_canSettle`'s strict `<` makes safe — saved another 66.

**Two levers measured and not taken, because they are the owner's call.**

| lever | saves | why it was not taken |
|---|---|---|
| drop the `sender == address(this)` clause | 28 bytes | it is the platform sink's path; the ruling named the sink. Unreachable today (the venue skips a hook's callbacks when the hook is the swapper), and the Codex diff lens independently proposed the same removal |
| remove the dead `ReentrancyGuard` inheritance | **0 runtime**, 36 initcode | a real LOW (`r1h-claude`, `r1h2-claude`), but it buys nothing against this limit |

Neither closes an 83-byte gap. The levers that plausibly do — moving code out of the hook into a
library, or shipping the referrer fix alone and re-declaring the platform pool's missing opening
cap as a disclosed boundary — change the contract's shape and need their own audit.

## The three fixes

**1. `CA-eeefa2ee72` — the opening cap (`src/FeastHook.sol`).** `capEndBlock` is written at pool
initialization only for an **ungated** pool, which opens in that very block. A gated pool is left
at zero and arms at its first public swap, inside the `else` of the gate's own comparison. The
window's settlement cannot reach that branch: `FeastLaunchWindow._canSettle` requires
`block.timestamp < openAt` **strictly**, which is also what lets the opener test be dropped from
the arming condition rather than carried as a special case. Both diff-round lens families checked
that claim against the code and confirmed it.

**2. `CA-0d1fa81d6c` — the settlement referrer (`src/FeastHook.sol`).** `_referrerFor` returns
the zero address for a protocol-initiated swap, identified **structurally** and never by
`tx.origin`: `p.opener` is the contract the pool was registered as gated to, and `address(this)`
covers the hook's own swaps. Ordering matters for gas as well as for correctness — see below.

**3. `CA-8ea162587a` — the vesting start (`src/FeastFactory.sol`).** `genesis` asks the team
wallet for `start()` and refuses any answer but the window's `endsAt()`, in the file's own
try/catch idiom so a recipient that cannot answer is refused rather than trusted. **This is a
real interface change**: a team-vesting recipient must now expose `start()`.
`docs/abi/FeastFactory.json` gains one custom error, and the genesis fixture's `RoleHolder`
stand-in learns to say its start — as the stand-in window was taught to say `endsAt` at v1.6.2.

## A gas regression, introduced and removed

The first draft put two cold SLOADs on every trade in every pool: the per-trade referral lookup
went **2,376 → 4,802 gas**. `test_gas_theLookupCostsOneColdSloadOnEveryTrade` caught it. Both new
tests now lead on `openAt`, which the gate has already read into a local, and the two fields with
cold slots of their own — `opener` and `capEndBlock` — are reached only by a pool that carries a
gate. An ordinary coin's trade touches no slot it did not touch at v1.6.9. What remains is
**2,634**, 258 gas of warm reads and branches; `docs/referrer-binding.md` §3 is updated, because
the mechanism sentence changed.

## What the round measured

- **The three PoCs go red → green, byte-unchanged.** That is the property, so the PoC test
  bodies were not touched. Both diff-round lens families reported the vesting PoC's bare `catch`
  as too weak to name its reason; three tests that DO name `TeamVestingStartNotWindowClose` were
  added beside it, leaving the PoC itself identical.
- **Full suite with the fork row: 517 passed, 0 failed, 0 skipped**, the 23 `test_fork_*` among
  them. `check-census` ok. `check-boundaries` ok after regenerating the factory ABI.
- **Mutation: 216 of 217 caught, 1 knowingly outstanding — and 3 reported "survived" that are
  not.** All three are gate mutants in `tools/mutate.py`, textually anchored on the single-line
  gate this fix rewrote, so the tool substituted nothing and called the unchanged suite a
  survivor. Verified by hand-mutating the NEW gate: dropping it fails 2 of `FeastGateTest`'s
  tests and lifting it one second early fails 1. **Coverage is intact; the three mutants need
  re-anchoring**, and `tools/mutate.py` is outside this lane's write surface.
- **The lens layer on the diff: 11 units, no HIGH, no new defect in the fixes.** `P10`, `P11`,
  `HK05` and the Codex review returned PASS; the Codex unit independently verified the
  `_canSettle` claim, the predicate's completeness, and that ordinary pools are unchanged.

### What the diff round did find, none of it blocking

| unit | sev | where | what |
|---|---|---|---|
| `P8-claude` | MEDIUM | `src/FeastFactory.sol:277` | genesis pins the wallet's start to the window's close but never bounds that close |
| `P12`, `r2a-claude` | MEDIUM | `src/FeastFactory.sol:312` | genesis now READS the window's close and still registers whatever `openAt` the key passes, instead of deriving it |
| `HK23-claude` | MEDIUM | `src/FeastHook.sol:497` | the 64-byte binding form and a relayed origin — pre-existing, not introduced here |
| `HK18-claude` | MEDIUM | `src/FeastHook.sol:1035` | the Payout lock hands control to the quote token — pre-existing |
| `r2a-claude` | LOW | `test/audit/poc/TeamVestingStart.t.sol` | the bare `catch` — **fixed here** |
| `P6-claude` | LOW | `src/FeastHook.sol:306-308` | the public `capEndBlock` view answers 0 for a gated pool until it arms |

The first two are the interesting ones and they are the same shape: fix 3 put the window's close
in genesis's hand, and two other things in that function still do not use it.

## The tag that is not taken

    git -c user.name=feast -c user.email=feast@users.noreply.github.com \
        tag -a v1.6.10-audit -m "..."      # DO NOT RUN

`FeastHook` is 83 bytes over EIP-170 at this commit. The owner rules how to make room; the hook's
two hashes change when they do, and the pin note records them as recorded, not sealed.
