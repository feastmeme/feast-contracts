# Audit brief — v1.6, one unit (the increment to `v1-internal`)

**Status: sealed as `v1.6.3-internal` (2026-09-14), on top of `v1.6.2-internal`
(`3856ba6`) — see the v1.6.3 seal receipt below. Previously sealed as
`v1.6.2-internal` (2026-09-13), on top of `v1.6.1-internal`
and `v1.6-internal`.** v1.6 is sealed and audited as ONE unit (owner ruling Q28).
The record and the seal receipt near the end of this file were filled in at that
seal. The "v1.6.1 — the pre-audit pass" section below is what changed at that
pass, and the v1.6.2 receipt beside it is what changed at this one: the sink's
descending-price clock, which the first dual-family `/contract-audit` run proved
broken, and two owner rulings taken alongside it.

## What this is

`v1-internal` (tag at `b30e796`; `4d008d1` is the same tree after a rename that
changed no logic) is the audited base: a factory that creates coins paired with
tokenised stocks, a hook that takes 1% of every swap on the quote leg into four
fixed buckets, permanently locked liquidity, no owner. Thirteen internal audit
rounds; see `docs/audit/`.

**The day-one part** — what must exist when the factory opens, because the
hook is immutable, shared by every pool and deployed with the factory — adds
eight things:

1. **A weekly three-track fee ledger** (`FeastFeeLedger`, replacing v1's daily
   payer-only `FeastEpochRewards`), written by the hook on every fee.
2. **An `openAt` gate** in the hook: before `openAt`, only a pool's opener may
   trade it. Zero for every ordinary coin; used once, by the platform coin's
   launch window.
3. **One referral rule**: a referrer equal to the payer (`tx.origin`) is no
   referral at all — no commission, no ledger credit.
4. **A platform-fee exit** (`releasePlatformFees`): v1 banked the platform's 20%
   with no way to spend it; it now leaves, as the asset it accrued in, to the
   sink the genesis call names.
5. **A one-shot genesis path** (`FeastFactory.genesis`) that mints the platform
   coin (`FeastPlatformToken`, via `FeastPlatformTokenDeployer`) and routes its
   supply 60 / 25 / 14.2 / 0.8. (It read 65 / 20 at the v1.6 seal; the owner
   ruled the change on 2026-09-16 and it entered the contracts at
   `v1.6.9-internal`. See "The allocation, re-ruled" below.)
6. **The internal fill** (owner ruling Q15): an exact-input sale is offered to the
   coin's own buy-and-burn bucket first, at spot, and the coin taken is burned.
7. **One `Trade` event per swap** (Q24), with the trader's own amounts.
8. **A metadata digest** (`bytes32 metadataHash`) in `create()` and genesis (Q23),
   stored with the coin and emitted in `CoinCreated`.

**The rest** deploys later (at the factory's opening and at the TGE) and reads
the day-one contracts; the day-one contracts carry none of its addresses:

9. **`FeastPricer`** — a pinned list of priced quotes with at most two v3 pools
   each to wrapped native, and the platform coin's own price from the hook's
   oracle; reports `Unpriceable` / `Moved` instead of reverting.
10. **`FeastEmissions`** — 14.2% over 52 weeks from the factory's opening week;
    weeks settle before the platform coin exists (accounting against the budget);
    three timelock levers bounded at the callee.
11. **`FeastGenesisGrants`** — eight partners, 0.1% each, unlocking by referred
    fees in weeks 1–26 read from emissions; the unearned part burns.
12. **`FeastLaunchWindow`** — 24-hour uniform-price commit, one swap through the
    gated pool, pro-rata claims, refunds as written rules.
13. **`FeastTeamVesting`** — OpenZeppelin `VestingWallet`, no cliff, 36 months,
    renounce disabled.
14. **`FeastPlatformSink`** — descending-price redemption of the platform's fee
    share for the platform coin, which is burned.
15. **`IFeastGenesisRecipient`** — what every genesis recipient reports.
16. **Deployment**: OpenZeppelin `TimelockController` (proposer = team multisig,
    executor = anyone, admin = itself) and the scripts `DeployPackage1`,
    `DeployPackage2`, `Genesis`, which refuse while any placeholder is unset.

## The diff, file by file (against `4d008d1`)

Read in this order. `git diff 4d008d1 -- src` reproduces it.

| File | Change | What to check |
|---|---|---|
| `src/FeastGenesis.sol` | **new**, 195 lines, constants and placeholders only | the split sums to 10,000 bps; `MAX_GATE_DURATION` 14 days; week alignment gives Monday 00:00 UTC; the chain facts and the `GENESIS_KEY` placeholder are read only by the deploy script |
| `src/FeastFeeLedger.sol` | **new**, 159 lines; replaces `FeastEpochRewards.sol` (57 lines, deleted) | `record`: recorder-only; three tracks each credited the whole fee; one packed word per account and one per (week, quote) total; a track without headroom is skipped **on both sides**, so a total is always exactly the sum of its accounts and no fee can revert a swap; the same-address coalescing (payer = creator, creator = referrer) writes each address once and credits each role once |
| `src/FeastHook.sol` | +406 / −40 | (a) `Pool` gains `openAt` (packed beside `creator`) and `opener`; (b) `registerPool` takes both and bounds them: a gate needs an opener and vice versa, `now < openAt ≤ now + 14 days`; (c) `_beforeSwap` checks the gate **before** the fee's early return, so all four fee branches see it, and `buyBackAndBurn` checks it too (its swap skips the callbacks — round 1, M1); (d) `_referrerFrom` returns zero when the referrer is `tx.origin` — the one place a referrer is resolved, for both the commission and the ledger; (e) `_accrue` calls `ledger.record(quote, tx.origin, creator-or-zero, referrer, fee)` unless the pool is gated; (f) `releasePlatformFees`: sink read from the factory, refused while it has no code, `min(pending, MAX_SETTLEMENT)`, `platformUsed` debited by exactly that, paid through the existing `_release`; (g) **the internal fill** — `_fill`, reached only from the fee-free early branch of `_beforeSwap` for an exact-input sale: spot price by `mulDiv` (`_quoteForCoin` / `_coinForQuote`), `_spotIsNearAverage` (the oracle asked with `try`), at most `coinOffered − 1`, the shared allowance and one settlement; settled in claims alone — `vault.burn` of the hook's quote claims and `vault.mint` of coin claims, so nothing physical moves on the swap path (rounds 2–3) — with the coin burned later by `burnFilledCoin` (bounded, debit by paid); priced once, exactly, only for square-root prices in [2^64, 2^128) — outside it no fill, a declared boundary sized for 18-decimal quotes (round 4, L1); `type(int256).min` never filled; the filled amounts handed to `afterSwap` in transient storage (`_takeFill`), where the fee is charged on the whole sale; (h) **`Trade`** — `_emitTrade` once per ungated swap in `_afterSwap`, the trader's amounts being the pool's delta less the hook's own; `_observePrice` now also returns the post-swap `sqrtPriceX96` |
| `src/FeastFactory.sol` | +214 / −16 | (a) constructor gains the token deployer, the wrapped-native address and the genesis key; (b) the seeding sequence of `create` moves verbatim into `_seed`, now shared with genesis; (c) `genesis`: key-only, `genesisDone` set first, code-less token recipients refused (the sink may await its code; zero refused), no allocation to the factory, hook, vesting contract or coin deployer and three distinct recipients (round 1, M2), custody of the whole supply checked before and an empty factory checked after, pool registered with the platform coin's fixed terms and the named gate, 65% seeded, 20% / 14.2% / 0.8% transferred; (d) `CreateParams.metadataHash` and `GenesisParams.metadataHash`, stored in `Coin` and emitted in `CoinCreated` |
| `src/FeastPlatformToken.sol` | **new**, 58 lines | OpenZeppelin `ERC20 + Burnable + Permit + Votes`, timestamp clock, whole supply minted in the constructor, nothing else |
| `src/FeastPlatformTokenDeployer.sol` | **new**, 55 lines | exists only for the 24,576-byte limit (measured: the factory held the token's creation code with 1,039 bytes spare, before genesis); factory-only `deploy` with a fixed `CREATE2` salt; `predict` |

| `src/IFeastGenesisRecipient.sol` | **new**, 15 lines, interface | `genesisRole()` and `platformCoin()`: genesis and the exit ask; no contract that does not answer is ever a recipient |
| `src/FeastPricer.sol` | **new**, 220 lines | routes validated at construction (connect, end in native, no duplicates, ≤ 2 hops; every listed quote, wrapped native included, 18-decimal — round 4, L1); a route price no word can hold is `Unpriceable`, checked with `mul512` before composing (round 4, L2); `_vouch`: cardinality ≥ 2, history ≥ `MIN_OBSERVATION_AGE`, spot within 300 ticks of the average; `_ratioQ128` direction; `platformPerNativeQ128` before genesis, while young and when moved |
| `src/FeastEmissions.sol` | **new**, 428 lines | `settle` (order, closure, pricing grace, first-week rule **before launch only** — after launch a moved or unreadable platform price refuses settlement with no timeout (round 4, H1) —, value cap, weights, empty tracks, the redirect as its share of each nonempty track's share (round 4, M1), `remaining`/`liabilities`); `claim`/`owed`/`_priced` (floors: Σ claims ≤ pots); `claimsOpen` read from the hook; `expiryOf`; `burnExpired`, `releaseRedirect`, `burnRemainder`; the three levers and their `Checkpoints` |
| `src/FeastGenesisGrants.sol` | **new**, 130 lines | distinct partners, non-zero target; `checkpoint` once per week per partner, only settled weeks 1–26; `unlocked` capped; claims and the burn only once claims are open; the burn only after week 26 |
| `src/FeastLaunchWindow.sol` | **new**, 233 lines | commit/withdraw windows (the locked last hour); `settle` only as the pool's opener in `[endsAt, openAt)`, once; the swap and its settlement in `lockAcquired`; pro-rata claims with the exact remainder; refunds when it can no longer settle |
| `src/FeastTeamVesting.sol` | **new**, 43 lines | `VestingWallet` with start = the window's close, 94,672,800 s; `renounceOwnership` reverts; no delegate function |
| `src/FeastPlatformSink.sol` | **new**, 130 lines | `open` once per asset (never the platform coin); the price: halving, linear within a half-life, the post-sale floor, never zero; `take`: ceiling cost, burn, re-anchor by the share taken; `burnStray` |

Unchanged: `FeastCLHookBase`, `FeastConverter`, `FeastOracle`, `FeastToken`,
`FeastVesting`, `FeastMath`, `FeastParameters`, `FeastConstants`, `src/venue/*`.

Scripts (deploy nothing of their own): `DeployPackage1`, `DeployPackage2` and
`Genesis`, the placeholder checker `FeastScriptChecks`, and `FeastPlatformPool`,
an internal library that computes the platform coin's pool key for both later
scripts (round 4, M2: `Genesis` used to deploy a 42 KB script contract inside its
broadcast to compute it). The real sequence was broadcast to a local fork of the
pinned block under the default 24,576-byte limit: 15 contracts, the largest
`FeastHook` at 22,725 bytes; genesis is three transactions.

## Invariants to break

Each is held by named tests (`docs/site-census.md`, sections `fee-attribution`,
`open-gate`, `genesis-once`, `internal-fill`, `trade-record`, and the new rows of
`bounded-settlement`, `realised-spend`, `pool-isolation`, `spending-rate`,
`swap-admission`, `launch-identity`, `principal-locking`, `reentrancy`,
`asset-backing`, `fixed-supply`).

| # | Invariant |
|---|---|
| P1 | For every (week, quote, track), the total equals the sum of the accounts. |
| P2 | No swap reverts because of the ledger, whatever the fee size or the roles. |
| P3 | A fee is credited whole, once, to each of its roles, in the week and quote it was paid in; a zero role and a burn-address creator are never accounts. |
| P4 | A referrer equal to `tx.origin` earns neither commission nor ledger credit, on any branch. |
| P5 | Before `openAt`, no address but the opener completes a swap in a gated pool, on any of the four fee branches; from `openAt`, everyone does. A pool registered without a gate is unaffected. |
| P6 | A gate is never longer than 14 days and never without an opener; the launch window's own swap is recorded on no track. |
| P7 | The platform share leaves only to the sink genesis named, never before it has code, at most one settlement per call, debited by exactly what was paid; no other bucket moves. |
| P8 | `genesis` succeeds once, only for the genesis key, and afterwards no package-1 function has a privileged caller other than contract-to-contract wiring (factory → hook registration, hook → ledger). |
| P9 | The platform coin's supply is minted once and routed 60 / 25 / 14.2 / 0.8 to the unit; nothing remains in the factory. (65 / 20 at the v1.6 seal; re-ruled 2026-09-16, in the contracts at `v1.6.9-internal`.) |
| P10 | The internal fill never refuses a trade; it fills only exact-input sales on open pools, at spot, inside the TWAP bound, the shared allowance and one settlement; the self-burn bucket is debited by exactly the quote paid, the coin taken is burned, and the sale pays 1% of its whole amount. Across fills and presses together, at most 20% of a bucket leaves in any hour. |
| P11 | Every ungated swap emits exactly one `Trade`, whose amounts equal the venue's delta for the trader and whose price is the pool's post-swap price; nothing else emits one. |
| P12 | A coin's metadata digest is exactly the argument its creator passed, recorded and announced in the creating transaction. |
| P13 | A week settles once, in order, after it closes; it emits `min(value cap, token cap, remaining)` — the token cap alone only **before launch** while the platform coin has no price the oracle will vouch for; **after launch the value cap always binds**, and a price the oracle will not vouch for refuses settlement; the sum of everything ever settled never exceeds the budget, so every pot settled before genesis is funded by genesis. |
| P14 | The claims of a week never exceed its pots; nothing is claimable before the platform coin's pool opens; an unclaimed pot burns only after its grace; after week 52 exactly what nobody is owed burns. |
| P15 | Only the timelock pulls a lever; each lever stays in its band at the callee and applies from the next ledger week (the pricer from the next settlement); a settled week is never changed; the redirect never takes more than its share of what a week actually emits. |
| P16 | A partner's grant unlocks by the referred fees the emissions ledger prices, capped at the grant, counted once per week; the unearned part burns only after week 26. |
| P17 | The launch window settles exactly once, only as the pool's opener in its exclusive hour; every committer gets the same average price and every unit bought is paid; a window that cannot settle refunds every commit in full. |
| P18 | The team's allocation vests linearly from the window's close over 36 months, cannot be renounced into the void, and never votes. |
| P19 | The sink sells any asset but the platform coin, at a price that only descends between sales, never at zero, and burns everything it is paid. |
| P20 | No state-changing function in the unit has a privileged caller other than: the genesis key once; the timelock for the three levers; contract-to-contract wiring; the team beneficiary for its own wallet (`tools/check-boundaries.py`, surface). |
| — | Every v1 invariant (I1–I15, `docs/plan.md` §3) still holds; the whole v1 suite runs unchanged against this tree. |

## Declared, not defects

- **Payer is `tx.origin`**, as v1's opening cap. A contract wallet behind a
  bundler credits the bundler; a contract-per-swap evades nothing it could not
  evade anyway. Ruled (Q10).
- **The referral rule is evadable with a second address.** Ruled (ruling 5,
  Q5): it is the only anti-abuse rule and it is not meant to be complete.
- **A fee in a quote with absurd decimals** can exceed a `uint80` track and go
  unrecorded; package 2 values only a fixed list of priced quotes, each an
  18-decimal token (the pricer refuses any other).
- **The internal fill's exact domain is sized for 18-decimal quotes** (round 4,
  L1). The factory is open (Q2), so a coin quoted in a six-decimal token can have
  a raw price outside `[2^-64, 2^64)`; it then trades normally and is never
  filled. Every planned quote was 18-decimal at the pinned block.
- **Settlement can be delayed, not bent** (round 4, ruled residue). After launch
  anyone can hold up one settle attempt by paying to move the platform coin's
  price past the bound in that block; each attempt costs that again, and the
  average converges to a sustained move.
- **The internal fill serves exact-input sales only.** An exact-output sale names
  the quote amount, which is the currency the specified-leg fee and the
  partial-fill refusal (R18) already act on; it goes to the pool as before.
- **The fill's two `MAX_SETTLEMENT` caps are defence in depth.** The venue
  refuses any swap whose deltas exceed a signed 128-bit value before either cap
  could bind, so neither has a killing mutation.
- **v1's declared boundaries B1–B6 stand**, unchanged.

## Out of scope

The venue (PancakeSwap Infinity) and its operator's powers; quote tokens' own
admin powers; OpenZeppelin's `TimelockController` and `VestingWallet` as such
(their wiring is in scope); Snapshot and the team multisig's off-chain
commitments; `lib/` and `reference/`.

## Record (filled at the seal)

| | |
|---|---|
| Tree | the commit tagged `v1.6-internal`; its `src/` and `script/` are byte-identical to `7bdb5fc`, the tree internal round 7 read (`git diff --quiet 7bdb5fc -- src script`) |
| Runtime bytecode hashes | below, pinned by `test/FeastBytecodePin.t.sol` (a changed byte fails it — mutation "change one byte of a sealed contract") |
| Tests | 315 in-process and 23 fork tests at block 120,721,477, all passing |
| Mutations | 136 of 136 caught on the sealed tree (`tools/mutate.py`; `KNOWN_UNKILLED` empty) |
| Census | 203 rows, self-test passing (`tools/check-census.py`) |
| Boundaries | licence, authority, identity, surface, abi — all clean (`tools/check-boundaries.py`) |
| Internal audit rounds | seven, `docs/audit/v16/` — HIGH / MEDIUM per round: 0/2, 0/3, 0/1, 1/2, 0/0, 0/0, PASS; the endorsing round 5, then two consecutive zero-HIGH rounds; residues in `plans/v16/plan.md` §R4 and "Declared, not defects" above |
| Deploy rehearsal | the three scripts broadcast in order to a local fork of the pinned block under the default 24,576-byte limit: 15 contracts, the largest `FeastHook` at 22,725 bytes (plan §R4) |
| Measured gas | `docs/tokenomics-v1.6.md` Part 2 |

### Runtime bytecode (immutables as zero placeholders; no metadata hash)

No genesis placeholder compiles into runtime code — they all enter by
constructor argument — so filling them in for the deployment changes none of
these bytes.

| Contract | Bytes | keccak256 |
|---|---:|---|
| `FeastHook` | 22,725 | `0x35be8b26ef30222d0f38d7d5766d4cb0400b80c475b61ae24dedd83545cc921a` |
| `FeastFactory` | 16,009 | `0x5539a5c2555b177c8ffb3e2254404b882851393a6b1528ebfe2979e7e5e0cafc` |
| `FeastFeeLedger` | 2,296 | `0x27ea4f1ed29c62ab2125d5d0f10fb503167a3b57bec939295f4b887008308583` |
| `FeastOracle` | 2,846 | `0x11b8f0b5d866b1d821a7a39e855f786d36b874e249d241bcd5697ffd78ecf775` |
| `FeastConverter` | 7,311 | `0xa8171fb3c81016e11700be2dd7bf3b4d1d368392a67237d092e77288fb20f4f0` |
| `FeastVesting` | 1,840 | `0x4f5bfe2bb590b6e7a11ff42c73b529a23a489c31a25c3c94ff60f85b7748815c` |
| `FeastToken` | 3,904 | `0xf42811b7cd4d5a0eea33299dd376344f3030ffc14cd2c994fda77cb2d4afcb4d` |
| `FeastPlatformTokenDeployer` | 13,255 | `0x505a76342433b4946bd80c61785c5474ed2d07d33b7534efd1c52dde08a98f2d` |
| `FeastPlatformToken` | 8,947 | `0x78f97e2cd38b7e6d3d6846469d987b79f4e0ad840fabd6dfdaea3a1bd1c88997` |
| `FeastPricer` | 5,514 | `0x1ad711b9ff958904c909fcfc203a5dfb3f0afe12d5affa8789845fff3bb19640` |
| `FeastEmissions` | 13,522 | `0xb78cc850c4772b3d76c9b0a9b510eeeade3d349a377c14720c7def265d77eac0` |
| `FeastGenesisGrants` | 3,893 | `0x81ee0b29e6105ffd5b06f9f7361e73d443f86d2e0bab45f7f28d18e329d8485b` |
| `FeastPlatformSink` | 3,412 | `0xdabc5ca90b48995cc48cb9c53fc0fbf10f6d05f214de36eae7eccc10cc2e0d6c` |
| `FeastLaunchWindow` | 7,522 | `0x902eac0287c3aa5aba885c385d8622da70965b71e22d554252a5c302f1b59bdb` |
| `FeastTeamVesting` | 2,570 | `0xaab2a20edfaa13f1fa1e5e8267b81d00f06280fc86d67a16f211af38e7418d2f` |
| `TimelockController` | 6,693 | `0x136978950834cdcd36efdf6032e4ad08881b24eb417393837cce16a2be729877` |

## v1.6.1 — the pre-audit pass (2026-09-12)

`/contract-audit` (task 444) ran its pipeline against the sealed tree `4fca684`
and produced an evidence pack: several independent engines for recall, and one
rule for precision — a HIGH or MEDIUM counts only if a Foundry test fails on it.
This section is what that pack changed. The external auditor should be able to
verify each row rather than rediscover it.

### Disposition

| Pack id | v1 id | Severity | What it says | Disposition here |
|---|---|---|---|---|
| `CA-ece82bf971` | — | HIGH, unproven | The fill caps its own payment at `MAX_SETTLEMENT` without leaving room for the residual pool output, so the venue's `int128` narrowing of the merged delta can refuse a sale the pool alone could serve (P10). | **Fixed.** `src/FeastHook.sol`, `_fill`: the fill serves only a sale whose coin amount, and whose value at spot, each fit `int128`. A larger sale is not refused — it goes to the pool unfilled. |
| `CA-485fecaac2`, `CA-a3f6fbecc5` | M3 | MEDIUM, proven | A quote token that taxes the vault's outbound transfer makes settlement retire more than it delivers: 74.25 of 75 on a creator claim, 24.75 of 25 on the platform exit. | **Declared, B7** (`docs/plan.md` §6c), with those numbers asserted in `test/FeastDeclaredBoundaries.t.sol`. The settlement primitive is unchanged. |
| `CA-065c50b469` | M1 | MEDIUM, proven | `predictCoin` commits to salt, name, symbol and supply only, so another caller can occupy a predicted address with different economics. | **Declared, B8**, plus guidance in `docs/interface.md`. The launch is never blocked; only the prediction is unreliable. A salt-level hardening is proposed in B8 and **not taken** — it awaits a coordinator ruling. |
| `CA-e5eba58f91` | M5 | MEDIUM, proven | The documented liquidity estimate reverts `PoolTooShallow` at a non-unit opening price. | **Closed by withdrawal, not by a formula** (coordinator, 2026-09-12). Four corrected estimates were each broken by a later internal round — the range's far edge, shading, the allocation's own rounding, the venue's signed limits and the search's convergence — so no formula is published in any form. `docs/interface.md` states the constraint the factory enforces (`_seed`'s line, quoted) and tells an integrator to size by simulating `create()`; the witnesses run that search against the real factory and encode no arithmetic. `plans/v16/plan.md` §R6 records why. |
| `CA-e2ba62d849` | — | LOW, unproven | `uint32` truncation before a checked subtraction: the 2106 rollover blocks observation writes. | **Fixed at all five sites** (`FeastOracle` ×3, `FeastConverter`, `FeastPricer`): the subtraction is taken from the full-width clock and truncated after; the ring orders and interpolates modulo 2^32. |
| — | M2 | — | The platform bucket had no exit. | Already closed in v1.6 by `releasePlatformFees`. |
| `CA-bc7d82ad28` | — | MEDIUM | `tx.origin` for payer identity. | On a declared boundary (Q10), as the pack itself records. |
| 212 others | — | — | Deterministic-engine output. | False positives, each with the triaging lens's reason in the pack. |

### What changed in the code

Four contracts, and nothing else: `FeastHook` (the fill's bound), `FeastOracle`,
`FeastConverter` and `FeastPricer` (the timestamp arithmetic). The other twelve
deployable contracts are byte-identical to `v1.6-internal`; the pins below were
re-taken for all sixteen.

**The fill's bound, in full.** The venue narrows the trader's merged delta to
`int128` on both legs when it subtracts the hook's delta from the pool's
(`BalanceDelta.sub` → `SafeCast.toInt128`). The fill pays at spot, on top of what
the pool pays for the rest of the sale, and it pays better than the pool would —
so it can push that sum past the limit for a sale the pool alone could have
served. The bound is the venue's own: serve only a sale whose coin amount, and
whose value at spot, each fit `int128`. Then coin taken plus coin the pool takes
is at most the sale itself, and quote paid plus quote the pool pays is at most
the sale's value at spot, because a sale only moves the price against itself and
the pool charges its own fee on top. Three witnesses pin it: over by value, over
by size, and a control a hair inside that is still filled.

**Not proven here.** The pack's own construction for `CA-ece82bf971` — an actual
revert — needs a self-burn bucket above about twenty times `int128`'s maximum,
which no test in this suite can reach honestly (every trade and every collection
that funds the bucket is itself bounded by `int128`). The arithmetic is real and
the bound is now pinned behaviourally and by two mutations; the reachability
caveat is recorded in `plans/v16/plan.md` §R6. An auditor who wants the revert
itself will need synthetic state.

### v1.6.1 seal receipt (2026-09-12, tag `v1.6.1-internal`)

Every gate run on the sealed tree — the tree round 15 read, unchanged since.

```
git diff --quiet <the tree round 15 audited> -- src script test tools docs plans
### exit=0
forge test                                   # 335 passed, 23 fork tests skipped
### exit=0
BSC_RPC_URL=<read-only fork source> forge test --match-test fork   # 23 passed
### exit=0
python3 tools/check-boundaries.py            # licence, authority, identity, surface, abi
### exit=0
python3 tools/check-census.py                # completeness against the invariant list
### exit=0
python3 tools/check-census.py --self-test    # 208 rows, and the checker can fail
### exit=0
forge test --match-contract FeastBytecodePinTest   # the sixteen runtime hashes
### exit=0
python3 tools/mutate.py                      # 145 of 145 mutations caught, at this tree
### exit=0
```

**The internal rounds of this pass.** Eight, all by one verifier lens over
`git diff 4fca684..HEAD`, each pinned and citation-checked:

| Round | Verdict | What it found |
|---|---|---|
| 8 | HIGH 0 · MEDIUM 1 | Items 1–4 STAND. The liquidity formula dropped the range's far edge |
| 9 | HIGH 0 · MEDIUM 1 | Its replacement shaded a small allocation below what the factory accepts |
| 10 | HIGH 0 · MEDIUM 2 | The allocation rounded differently from the factory; a false feasibility claim |
| 11 | HIGH 0 · MEDIUM 2 | The recipe as code: a feasibility claim the venue's signed deltas cannot honour; a search that cannot converge |
| 12 | HIGH 0 · MEDIUM 1 | After withdrawal: the leftover enumeration of refusals |
| 13 | HIGH 0 · MEDIUM 1 | That claim still standing in three other files |
| 14 | HIGH 0 · MEDIUM 1 | And in the probe's inline comments |
| 15 | **PASS** | Endorsed for external audit |

Every one of those findings was in guidance this pass added, and none in the
sealed unit: `src/` differs from `v1.6-internal` only by the two ruled fixes
(the fill's venue-delta bound and the 2106 arithmetic), which rounds 8–15 leave
standing. What the sequence cost is worth stating plainly: four corrected
liquidity formulas and three corrected retractions, until the recipe was
withdrawn and nothing was published in its place but the factory's own
constraint.

**Not done, deliberately:** no pull request, CI run or merge — this repository
has no remote, as at `v1-internal` and `v1.6-internal`; no deployment; no keys;
nothing was sent to chain id 56.

### v1.6.2 seal receipt (2026-09-13, tag `v1.6.2-internal`)

The pre-audit fix pass on top of `v1.6.1-internal` (`64257bb`). Its subject was the
one proven HIGH of the first dual-family `/contract-audit` run — the sink's
descending-price clock, `CA-fb2e051555` — plus two owner rulings taken in the
same pass, and the four v1.6-era proofs-of-concept the pack listed as proven
MEDIUMs which were not defects at all.

Every gate run on the sealed tree; the line after each is its exit status.

```
forge test                                   # 376 passed, 0 failed, 23 fork tests skipped
### exit=0
FOUNDRY_PROFILE=ci forge test --match-path test/audit/invariants/FeastInvariants.t.sol   # 7 passed
### exit=0
python3 tools/check-boundaries.py            # licence, authority, identity, surface, abi
### exit=0
python3 tools/check-census.py                # completeness against the invariant list
### exit=0
python3 tools/check-census.py --self-test    # 229 rows, and the checker can fail
### exit=0
forge test --match-contract FeastBytecodePinTest   # the sixteen runtime hashes
### exit=0
python3 tools/mutate.py                      # 168 of 168 mutations caught, at this tree
### exit=0
```

**Not run:** the 23 fork tests. No archive endpoint exists in this worktree, in
the environment or in the main checkout, and one was not invented
(coordinator ruling, 2026-09-13). They passed at `v1.6.1-internal` and nothing in
this pass touches the venue path.

**What changed in `src/`.** `FeastPlatformSink` throughout — the descent is tied
to the lot it prices, the sink opens only when the launch window closes, the
floor is weighted by what sold and clears at a new descent. `FeastGenesis` gains
three constants; `FeastConstants` loses eight unreferenced ones and raises the
self-burn cap to half the fee. Runtime pins: `FeastPlatformSink` 3,412 → 5,551
bytes, `FeastHook` re-pinned at the same 22,783 (an immediate changed, not the
code's shape), the other fourteen untouched.

**The rounds of this pass.** Seven, each two lenses — a verifier on the fix edge
and a hunter for anything new — over `git diff 64257bb..HEAD`, every one pinned
to a frozen tree oid and citation-checked:

| Round | Verdict | What it found |
|---|---|---|
| 1 | HIGH 2 · MEDIUM 1, both lenses independently | A take could raise the size a descent prices, which rebuilt the giveaway for 81 wei; the refilled-lot branch sold under its own floor and let `open` raise a quote |
| 2 | no verdict | Both units stopped by the provider's content filter. The verifier's log had printed a worked counterexample first: `open` was not guarded against re-entry |
| 3 | HIGH 1 · MEDIUM 3 | A lot that shrank could be neither priced nor reopened; B9's reset-cost claim and the interface's transfer claim were false |
| 4 | verifier PASS · hunter HIGH 1 · MEDIUM 1 | A descent could run to its clamp before genesis, when no take could be paid for; one raw unit could seed a floor 2^58 above parity |
| 5 | HIGH 1 · MEDIUM 1 | Having code is not being obtainable: the same descent could run through the launch window; the floor still carried across incompatible lot sizes |
| 6 | HIGH 1 · MEDIUM 1, both lenses the same | A timestamp the key chooses is a promise, not a mechanism; and the production script never scheduled the sink at all |
| 7 | **HIGH 0 · MEDIUM 1, both lenses** | The scheduling is its own broadcast transaction, so "in the same transaction" was a claim this pass had made and not something the code did |

Round 7 is the termination: zero HIGH from both units. Its MEDIUM was corrected
after it, under the post-lens allowance — the claim rewritten where it was made,
and the launch script made to refuse a launch that leaves the sink unscheduled.

**What the sequence cost, plainly.** Six of the seven rounds found something, and
every HIGH after the first was in a correction this pass had just made. Two were
found by both lenses independently; one round produced no verdict at all and was
recovered from a dead unit's log; three were ruled by the coordinator rather than
self-fixed, under the rule that a HIGH inside one's own fix hands over. Two of the
findings were mine to notice and not the lens's: a mutation catalogue whose
anchors a refactor had stranded, so four of the teeth guarding this pass's own
fixes were biting nothing; and a fix wired into the test fixture and not into the
deployment script, which every test passed over.

**Sealed tree.** `<sha256>  <path>` for every file this pass changed but this
one — a document cannot carry its own hash, and the tag is the pin for the whole
tree including it:

```
7e850192ca44bf97abbb695ccd361ce15da99df77867b1d3852fca66e9fe1978  .gitignore
ff2783e147510b936dc6471e5295f5273a326b13e60531c62a75992c0f1f9bba  audit/invariants.yaml
33b2ae0e859fa061e3d130d8c6a9a5c319725b4494526d328468886015e499a3  contract-audit.yaml
35a0daf6c1deb779fb7e3627d6201bfdfa8a536e3ceb92910f6397b465a5b6a8  docs/abi/FeastPlatformSink.json
83becce8cb1432b6aca7d28caac5a8a4ae783df472f6a99ee41d438e28e9ed9f  docs/interface.md
f46e8a3ef302231e5d55208e2db8748a35cb93c35c62ebb2cf0138b5c10f2fcc  docs/plan.md
fd5f73bcaff5c28c7e9026cdeb0ac4ba4a7d791485cadaf870c226e9159c34d1  docs/site-census.md
58893866b07d8e459b06d3c0b13e2683d57be7cbb86b49d1a2c1a2269bed2617  docs/tokenomics-v1.6.md
4e62fdc39fdd8ba2918573b03a939cb86a496720fa3bcce294f89740078250f5  plans/v16/plan.md
1433315e663a351398066c4e4ada20980d56991aa596cd64893b0032f4eec0c6  plans/v162/plan.md
35734aef8b6e215a46287228480520a8823a0fb00d4d76c0a5bd180a79fd3ada  script/DeployPackage2.s.sol
895acf4188bff2a6d79dc27e5854a47d67ad75c5c4e49580d1dbdb567a5afd8b  script/Genesis.s.sol
474b0568607f26d66a03d3125abce5cc219b1eb392886b059e6f94a8d7c8cff2  src/FeastConstants.sol
4ba92872882f217911de54c545ad819caf4369c0d772cf57cddd28c4628c5d8c  src/FeastGenesis.sol
eaccb7653cec34c454c96bee9ee35d0b6a728113e975c6a8601e46db101ec546  src/FeastPlatformSink.sol
6bd0a01ee45d135d92e13582a93810a0f4d36fc4a703bb44e07e331c35ad4c86  test/audit/invariants/FeastInvariants.t.sol
9481d4c52dc3191e3874bfe3c78d1c389f632d2ccc14873a4fcf348af61829f5  test/audit/invariants/FeastSystem.sol
2c26eada0442b4bd62fa82e134af260b44756c16d79f1ac2f32b205d9719e7aa  test/audit/medusa/FeastProperties.sol
bcc1ec49229d45b4b88811c3d18c325f9808d9a96426dd0f0a77f9e38b1076c9  test/audit/medusa/medusa.json
8e436ba386bafa87e94bb488e1609fe09f33f738c19f9f8493e4b12fd83a11f3  test/audit/poc/BuybackBoundProbe.t.sol
df0b83d4f3d76ffc214a6d1053fd8101706449a762885fa70f14af47b5b12f2e  test/audit/poc/LaunchIdentity.t.sol
8a92f2fcb4f9081960239bf93339fec66a57617ebe2c99b74af5b8cb95bef809  test/audit/poc/PlatformRecovery.t.sol
7ab47ef4a37799724e302a60fe33ad405449c891d21417341affcf054f463657  test/audit/poc/SinkPriceDecay.t.sol
e5fa6c241f84412b332ade7beca1bf8c643a874d31e6aa415b23d8c171689b16  test/audit/poc/TaxedPayout.t.sol
c8f6fbf8a90e0724e5000970a0516fc1ebd92ee2ea7b3a156d9cd8fbc43890df  test/FeastAuthority.t.sol
1bc7b06f7d122ca8e954a34511d1254c8c44268fbfc6a95911834e93f9701f67  test/FeastBuckets.t.sol
be520006f1ead8e325e5b273c8bdc5f3a042748cb19d58af86412d093ec2c313  test/FeastBytecodePin.t.sol
629ba503ab32ee569fbbe72259636dab4ed5050325860c63258a90315ab3eb7a  test/FeastPackageTwo.t.sol
7a95d7d0dc088d75b45ec0730952c640dca826e98bc1237d4dbf447086ced3e4  test/utils/GenesisFixture.sol
7d369e7dbbeab0e2e0650d36ce2198922a250c12825b200554998d8540112367  test/utils/UnitFixture.sol
79dc1bb0dc9041eed303461078a49a37004404a2c157f0427b9720a3e7247cc9  tools/check-boundaries.py
5c052dc3110a4bac0fbfc0b489e8eee1924c8087e180bb6138976406e323f343  tools/mutate.py
```

**Not done, deliberately:** no pull request, CI run or merge — this repository has
no remote, as at `v1-internal`, `v1.6-internal` and `v1.6.1-internal`; no
deployment; no keys; nothing was sent to chain id 56. The dual-family
`/contract-audit` pack for the external-audit hand-off is the coordinator's to
run on this tag.

### v1.6.3 seal receipt (2026-09-14, tag `v1.6.3-internal`)

The pre-audit fix pass on top of `v1.6.2-internal` (`3856ba6`). Its whole subject
was the four findings the first dual-family `/contract-audit` run proved with
failing Foundry tests at that tag — two HIGH, two MEDIUM — which blocked the
v1.6.2 seal at proof-gate exit 3. Four findings, four closures, nothing else.

**Two of the four sat inside v1.6.2's own fix pass** — the re-anchor its round 1
wrote and the share-weighted floor its round 4 wrote — and the seven Codex lens
rounds before that seal read past all four. The floor erasure was found by both
Claude units independently and by no Codex unit at all. So this pass added a
Claude-family lens of its own, and made a rule of what v1.6.2 taught: every fix
here ships with its PoC green, a mutation that reddens a named test, and the
property written into the docstring beside the code.

Every gate run on the sealed tree; the line after each is its exit status.

```
forge test                                   # 403 passed, 0 failed, 23 fork tests skipped
### exit=0
FOUNDRY_PROFILE=ci forge test --match-path test/audit/invariants/FeastInvariants.t.sol   # 7 passed
### exit=0
python3 tools/check-boundaries.py            # licence, authority, identity, surface, abi
### exit=0
python3 tools/check-census.py                # completeness against the invariant list
### exit=0
python3 tools/check-census.py --self-test    # 240 rows, and the checker can fail
### exit=0
forge test --match-contract FeastBytecodePinTest   # the sixteen runtime hashes
### exit=0
python3 .runs/v163/mutate-slice.py <s> <e>   # 182 of 183 mutations caught, 1 knowingly unkilled
### exit=0
git diff --stat 3856ba6..HEAD -- script      # empty: nothing here touches deployment
### exit=0
```

**Not run:** the 23 fork tests. `FORK_URL` is unset on this machine, no archive
endpoint exists in this worktree or the main checkout, and one was not invented
(coordinator ruling, 2026-09-13). They passed at `v1.6.2-internal` and nothing in
this pass touches the venue path. `not-run` is never `pass`.

**`KNOWN_UNKILLED` is not empty, for the first time since `v1-internal`.** One
entry: the converter's callback ask bound, which refuses a pool's ask above the
hop's measured input. The outbound leg is bounded twice and only the second bound
— `_hop`'s measured debit — has behaviour nobody else has; a pool address comes
from the trusted v3 factory, so a pool that asks for more than it took is outside
the model. It is kept because it refuses before any token moves, and recorded as
unkilled rather than deleted, which is this repository's own rule.

**What changed in `src/`.** Three contracts. `FeastPlatformSink` — the re-anchor
is written in a form whose intermediate cannot overflow, and the floor is a
maximum rather than an overwrite (`_floorNow` factored out, read by the price
path and by `take` alike). `FeastEmissions` — settlement snapshots the quote list
it priced into `_weekQuotes`, and nothing on the owed/claim path asks the pricer
anything. `FeastConverter` — every leg of a conversion is measured: the inbound
arrival (clamped at the nominal, with a named refusal for a non-positive one),
each intermediate arrival, and each hop's outbound payment. Runtime pins:
`FeastPlatformSink` 5,551 → 5,610, `FeastEmissions` 13,522 → 13,958,
`FeastConverter` 7,307 → 8,266; the other thirteen untouched.

**The rounds of this pass.** Three Codex rounds, each two lenses, over
`git diff 3856ba6..HEAD`, every one pinned to a frozen tree oid; then one
Claude-family verifier on the final diff.

| Round | Verdict | What it found |
|---|---|---|
| 1 | `FIX_EDGE: DEFECTIVE` · **HIGH 1 · MEDIUM 3** | P19's chord-gap bound was stated in real numbers and is false in integer arithmetic — and this pass's own witness for it could not have failed. The converter measured one of a conversion's three kinds of leg. **All four were inside this pass's own fixes, so it handed over under rule 8 and the coordinator ruled both corrections.** |
| 2 | **HIGH 0** · MEDIUM 1 (+1 recovered) | B2's guarantee has a limit no measurement can reach. And "a take may raise the floor, never lower it" is exact at the sale and a unit under afterwards — recovered from a hunter the content filter stopped. |
| 3 | **HIGH 0** · MEDIUM 3, hunter `VERDICT: PASS` | Three claims this pass had written that the code does not deliver: B2's limit needed to be wider, "four units of Q128 price is economically zero" is false on a large lot, and F1's "four times the first take" is false at the price clamp. |
| Fable | **HIGH 0** · MEDIUM 2 | The invariant list still carried a sentence round 3 had retracted everywhere else; B2's limit named two shapes where there are three. Plus eight execution notes, every one a place this pass's words had drifted from its code. |

Rounds 2 and 3 are two consecutive zero-HIGH round groups, which is the
termination this pass was given.

**Unmeasured, recorded as such:** `r2h` — `unmeasured: codex-refused`; the
provider's content classifier stopped both the unit and its one permitted
relaunch, and both logs are preserved under `dead-rounds/`. Five of the seven
lens units died without writing a verdict file after printing complete verdicts
to their logs, and each was recovered from the log with the log preserved first;
the Fable unit's verdict was voided by its runner on a grammar check and is kept
as recovered evidence for the same reason. Only one unit of the seven —
round 3's hunter — landed its artifact cleanly.

**What the sequence cost, plainly.** Eleven findings across seven lens reads in
two families, and **exactly one of them was a defect in a mechanism**: round 1's
HIGH, which was a bound this pass had stated in real numbers and enforced in
integers. Every other finding was a sentence wider than the code it described —
including three witness names in this pass's own plan that named tests which do
not exist, and a boundary whose declared shape had to be widened twice. The
mechanisms held; the sentences did not. Two of the pass's own new mutations had
to be fixed before they bit, one because a fuzz witness is random and its failing
region narrow. And the harness had a hole of its own: `MockV3Pool.swap` never
checked that the swap callback actually paid it, which is why no test here could
witness anything about the converter's outbound leg — a pool that cannot refuse
is a harness that cannot witness a refusal.

**Two things this pass decided rather than inherited**, both inside F4, both
measured before they were written down, both ruled by the coordinator and
DECLARED — a finding against either counts, restating either does not: the route
floor's price is carried from `_validateHop` rather than re-read after the
transfer, and `received` is clamped at `amountIn`.

**One operating incident, recorded rather than tidied away.** A run ended inside
a mutation slice and left `src/FeastPlatformSink.sol` carrying a mutant; the
coordinator restored it, and no gate result was taken while it was there. The
slicer is now self-repairing — it records the mutant in flight and every start
restores from git before doing anything — because a `finally` block is not a
guarantee when the process is killed, and neither is `SIGINT`, which reaches
`forge` first.

**Sealed tree.** `<sha256>  <path>` for every file this pass changed but this
one — a document cannot carry its own hash, and the tag is the pin for the whole
tree including it:

```
afa606eaa5f82fac0620f960b15bb730a419fbb3050fa0d625d4c7d09dcfb182  audit/invariants.yaml
97c86d6c90cf893a5b84dd3af8ca459d8d0419158f40d3c41b88a51ecdcc9040  docs/abi/FeastConverter.json
366353e6df1df9f594acf060fe04b4283ccca92d618d110c225d7f4207f7f9e9  docs/abi/FeastEmissions.json
db7cf587ff06a17202155d54d674bcd422ca6322537d764b9edf407b8908d784  docs/interface.md
f34ccb5133493904cb234729f7f12545ccda8d665e432b2e142ed65d93ae2a54  docs/plan.md
264611628c26998ba6365259ebc924e1427e3112b68c2f2ed392f4ccabd4e12c  docs/site-census.md
d957196073239264b6db7a9965296cac80b254b695a63e914e58c6a9ba21a707  docs/tokenomics-v1.6.md
e2f5eec4f31a51546dc5ab1906d8c6faa276a87b49a545a289efc6460046c8be  plans/v163/plan.md
5ce1daa9a3dc77929ad331db9447902b0cd8b98ccad55365a6bc23c7712a5046  src/FeastConverter.sol
66fd19be526bc872950097e90c0b12e0eb297e6a1255a814cf8b06df32885436  src/FeastEmissions.sol
29e96d790708727bc199b6ff2809d161bc5861a19246cc42ffc7898388ff1932  src/FeastPlatformSink.sol
2c15b9461c1e88d2a250bacd2b09629c9559d9d9a014e51344cb93e26eecf74c  test/audit/poc/ConverterDonationAdmission.t.sol
4677540309825760e592457ed8cf75b0922000e038368cc2a45c59b031b1fc20  test/audit/poc/EmissionsPricerMutation.t.sol
069de6f2d32f9608ebae24bbda5e2464c22dd8cb5674e1990a110cf6a45e3a3c  test/audit/poc/SinkAnchorOverflow.t.sol
06faf78294f168a7810d1873a3af847fe1191b9bb9574fb5e4ecd37743942db0  test/audit/poc/SinkFloorErasure.t.sol
b5fb735ffe4e04256c993d9f5d991e4f43d8d35690eafb445eba0b9fa92f6b1f  test/FeastBytecodePin.t.sol
9f9ddf78938fe1f72b52f054fc990e51e0bd8432322f4b7ec9c4aed455df451e  test/FeastConverterBounds.t.sol
cfdfd1c5284efc3df41d6e5181d79b4434686a4d5c3a8f5329a83784324c8b4a  test/FeastEmissions.t.sol
92f3f56c27f358aaf5cfdc9993715f737b1fe3c0eed0f5b5c6ec3520ff0d0f67  test/FeastPackageTwo.t.sol
b96c4a2bccca48a3b983245f5828b330ad638a4c02ea0a63838bf7c1811c2379  test/utils/MockV3Pool.sol
21e3015d688814290c6fb106105e292adce876a8922c15d2c915aeda4a418e6b  tools/mutate.py
```

**Not done, deliberately:** no pull request, CI run or merge — this repository has
no remote, as at `v1-internal`, `v1.6-internal`, `v1.6.1-internal` and
`v1.6.2-internal`; no deployment; no keys; nothing was sent to chain id 56. The
dual-family `/contract-audit` pack on this tag is the coordinator's to run as the
next lane.

### v1.6.4 seal receipt (2026-09-14, tag `v1.6.4-internal`)

The pre-audit fix pass on top of `v1.6.3-internal` (`3fc27d4`). Its subject was the
three findings the dual-family `/contract-audit` run on that tag proved with
failing Foundry tests — one HIGH and two MEDIUM — and, behind the HIGH, the sweep
that pass did not do.

**Why the sweep is the substance.** v1.6.2 found an overflow shape in the sink.
v1.6.3 closed it there, as F1, and looked nowhere else. One release later the
identical shape returned as a HIGH in `FeastGenesisGrants`, a contract that was
already in the tree when F1 landed. So this pass enumerated **every** `x * y / z`
in `src/` — thirty-four of them — and gave each either a bound argument a reviewer
can check or a `Math.mulDiv` rewrite, and added a creation-time `MAX_SUPPLY`
refusal so the whole `supply * bps` family is bounded by construction.

**Three things this pass got wrong and had to be told.** The ruling's own spelling
of the G1 fix, `min(grant, mulDiv(...))`, still panics — `mulDiv` bounds its
intermediate but not its *result* — so the minimum is established before anything
is multiplied, and the divergence is flagged rather than taken quietly. The sweep's
first pass missed four signed fee expressions and the plan had already claimed the
enumeration was complete. And G3's sentence was corrected on one constant and left
standing on its public sibling in `FeastConverter` — in the pass whose own rule is
that a shape closed in one contract must be swept across all of them. The
Claude-family lens found that last one; two Codex rounds did not.

Every gate run on the sealed tree; the line after each is its exit status.

```
forge test                                   # 425 passed, 0 failed, 23 fork skipped
### exit=0
FOUNDRY_PROFILE=ci forge test                # the same, at 10,000 fuzz runs per property
### exit=0
FOUNDRY_PROFILE=ci forge test --match-path 'test/audit/invariants/*'   # 7 passed, 512 runs / 65,536 calls
### exit=0
python3 tools/check-boundaries.py            # licence, authority, identity, surface, abi
### exit=0
python3 tools/check-census.py                # 30 properties; all 5 `_release` sites enumerated
### exit=0
forge test --match-path test/FeastBytecodePin.t.sol   # the sixteen runtime hashes, seven re-pinned
### exit=0
python3 tools/mutate.py --slice=k/19 (k=1..19)   # 192 of 193 caught, 0 survived, 1 knowingly unkilled
### exit=0
```

**Not run:** the 23 fork tests. `FORK_URL` is unset on this machine and no endpoint
was invented. They are recorded `not-run`, never as passing.

**The lens record.** Two Codex round groups over `3fc27d4..HEAD`, verifier and
hunter each, and one Claude-family verifier on the final diff. **Zero HIGH in all
three reads**, which is the termination. Fifteen findings between them — five
MEDIUM and one LOW in round 1, five and one in round 2, one MEDIUM and three LOW
from the Claude unit — and **not one of them a defect in a mechanism**. Every
single one was a sentence claiming more than the code beneath it kept. Two produced
real code changes anyway (the price limit's `uint160` clamp, and narrowing the swap
amount before it is multiplied by the fee), both from findings the lenses labelled
pre-existing rather than introduced, so neither engaged rule 8.

The Claude unit's verdict was **voided by its own runner on a grammar check** — it
emitted no `VERDICT:` line — exactly as at v1.6.3. It is kept as recovered evidence
under `.runs/codex-loop/v164-claude/`, and every citation in it was checked by hand
and resolves. It is recorded `unmeasured: fable-verdict-voided`, and its findings
are acted on regardless, because the reading was sound whatever the runner made of
the grammar. No codex round refused; there is no `codex-refused` row this pass.

**Sealed tree.** `<sha256>  <path>` for every file this pass changed but this one —
a document cannot carry its own hash, and the tag is the pin for the whole tree
including it. `.claude/skills/` arrived with the cherry-picked PoC commit
(`88cbd30`) and is not this pass's work, so it is not listed:

```
d9fdb8b5c6268a78d30d5757ad103b9659e0f29c9aed6b933244f2f7e36c4fd9  docs/abi/FeastFactory.json
bb1ea7e9dbf0a14af8b9c84d0a2f2dad2524f4e2ee31465f5cc2ae11baa22edb  docs/abi/FeastPlatformSink.json
3609166d037dc0940854ac5c81a1b709daf4e6fd1389092668897e93909e88f3  docs/plan.md
43e9394adf18b3e72b81d8693c4a03dc4d9b460fa93c5159d86446f49557f400  plans/v164/plan.md
5715a63c6920d1a8cac0246e695a8d7fdc22a9389c75641159fcec5c7b0725a3  script/Genesis.s.sol
6c65927b50481cccddc8465058f638ced0c5ea8b80290283d791f7f62653501d  src/FeastConstants.sol
56984c9c2e3a8afc0a75343775b5821eb9a548b5748b02b05228803fcd469a03  src/FeastConverter.sol
a973613c903620f81c78d0f3641017524ef7ad3f58f8e622a7241444eb6a9717  src/FeastEmissions.sol
ed47902e6cfabda72dc48fd05959f2c3d7154873103b34fb310c6742baecad88  src/FeastFactory.sol
65b430f1a7089d0025d2c2d7b910b858e20d49e47f467a64a7817c30d63ddfba  src/FeastGenesisGrants.sol
653ca80120148ab14ebeb89e9c36c6b6df0d983e9e49ce58aeb5ff117c68bcf2  src/FeastHook.sol
86cc65f552421b1381315aae8570ba99de2f312bb6288aa24bf0ac4aa69f12cb  src/FeastLaunchWindow.sol
a157edc834362937f80264351bdd34dd9c2a99047e96346a67b370df8f32388e  src/FeastMath.sol
a2ebf623ab6047326c90264856f95b1fdd42a3735cf2a165e2a4aa77c997ce0c  src/FeastPlatformSink.sol
48ac032ba625c12917dfdce798d584c62063c497adec511a9884867436cada9d  test/FeastBytecodePin.t.sol
d75738bdeba620d8c13d919c8fa1490a7b0615d9d2b037fdb92f00f3357257b4  test/FeastConverterBounds.t.sol
64107cd53b1525ade0636a89a118bba6e6bfe8bdb921d081921f60adc8077032  test/FeastPackageTwo.t.sol
815472c43a850fa90fb3787bdd6e11cae994d84bb8cc46b7063b00b575f117ce  test/FeastV164Bounds.t.sol
e6c2a285c10134d2d3afceea0bf2acb3ae0d9630c17831ea8458256e840977f0  test/audit/poc/BuybackBoundProbe.t.sol
aae0ca5058a73906534a163f62170389e1600726e0568443eda2945b49b32a5c  test/audit/poc/BuybackSlippageBound.t.sol
e6d9e20bf1ca443bf3b084bb0fc1d30a64015a7f32f05282ee747dd1be5094bc  test/audit/poc/SinkScheduleBound.t.sol
2afa886bdf69999528968d757e5e5b05a8aba891ee15fabbd1039e9f80c3be77  tools/mutate.py
```

**Not done, deliberately:** no pull request, CI run or merge — this repository has
no remote, as at every seal since `v1-internal`; no deployment; no keys; nothing
was sent to chain id 56. No audit pack was built: the dual-family
`/contract-audit` pack on this tag is the coordinator's to run as the next lane.

### v1.6.5 seal receipt (2026-09-15, tag `v1.6.5-internal`)

The pre-audit fix pass on top of `v1.6.4-internal` (`125c5b4`). Its subject was the
two findings the dual-family `/contract-audit` run on that tag proved with failing
Foundry tests — one HIGH and one MEDIUM, **both inside `FeastEmissions::settle`** —
and, behind the HIGH, the sweep the previous pass's sweep did not do.

**Why the sweep is again the substance.** v1.6.4 enumerated every `x * y / z` in
`src/` and closed ten of its thirty-four rows by rewriting them as `Math.mulDiv`.
But `mulDiv` bounds its intermediate and not its **result**, which that pass's own
prose says four paragraphs above its own table. Row 17 of it is the site of this
pass's HIGH, and the comment it left there says the site was swept. So this pass
re-enumerated by the failure mode instead of by the expression shape: every
`Math.mulDiv` call in `src/`, read file by file — thirty-four executable calls in
twenty-eight rows — each with a RESULT bound a reviewer can check or a rewrite.
Three rows turned out to rest on nothing this tree enforces. All three are in
contracts this pass was not scoped to change, and all three are recorded **in those
files**, with their measured numbers and their counterexamples, rather than left
silent.

**What was measured rather than argued.** The value cap's word boundary is
`ceil(2^384 / inner)`, asserted against `mul512`'s own high word, with a witness on
it and a witness one unit below it. `FeastPricer._ratioQ128`'s reciprocal branch
crosses a word at `sqrtP <= 2^32`, a measured 161 443 units **below** the venue's
own floor and not immediately below it. `FeastPlatformSink.take` panics at exactly
`amountOut = 2^192` at the opening price, where the whole platform supply buys
54 210 108 raw units. `FeastConverter._expectedAfterHop` needs 309 bits on the
second of two hops at `sqrtPriceX96 = 2^157` from an input of `2^126`. **Every one
of those four sites carries a number this pass first got wrong** — the quotient at
the boundary, the pricer's crossing point, whether the sink's last representable
take can be paid for, and the converter's bound altogether — **and a lens, not
this lane, found each of them.**

Every gate run on the sealed tree; the line after each is its exit status.

```
forge test                                   # 438 passed, 0 failed, 23 fork skipped (461 total)
### exit=0
FOUNDRY_PROFILE=ci forge test                # the same, at 10,000 fuzz runs per property
### exit=0
FOUNDRY_PROFILE=ci forge test --match-path 'test/audit/invariants/*'   # 7 passed, 512 runs / 65,536 calls
### exit=0
python3 tools/check-boundaries.py            # licence, authority, identity, surface, abi
### exit=0
python3 tools/check-census.py                # 30 mechanisms, 244 rows; all 5 `_release` sites enumerated
### exit=0
python3 tools/check-census.py --self-test    # 244 rows, every one load-bearing, and the two new settlement probes
### exit=0
python3 tools/mutate.py --self-test          # four probes on the recovery path, all green
### exit=0
forge test --match-path test/FeastBytecodePin.t.sol   # the sixteen runtime hashes, one re-pinned
### exit=0
python3 tools/mutate.py --slice=k/20 (k=1..20)   # 197 of 198 caught, 0 survived, 1 knowingly unkilled
### exit=0
#   two invocations, both on 2026-09-14 UTC: slices 1-16 at 16:57-19:06Z, slices 17-20 at
#   19:33-20:11Z. The account's rolling five-hour usage limit killed the run mid-slice-17.
#   Both invocations ran against the IDENTICAL `src` tree: the killed run left its mutant
#   on disk ("take the redirect from the cap, not from the tracks that emit") and
#   `mutate.py`'s own recovery path - the one round 2 repaired, three commits before it
#   was needed in anger - restored it byte-for-byte and consumed its journal pair.
```

**Not run:** the 23 fork tests. No RPC endpoint is configured on this machine and
none was invented. They are recorded `not-run`, never as passing.

**The lens record.** Five reads in two round groups, `codex gpt-6-astra` at effort
high: a verifier, a hunter and a fresh-eyes review on the first tree, then a
fix-edge verifier and a hunter on the second. **HIGH 0 in all five**, which is the
termination. MEDIUM 7 and LOW 11 between them, every one accepted and closed, and
**not one of them a defect in a mechanism** — the arithmetic of both closures was
independently confirmed three times over. What they found were sentences claiming
more than the code or the measurement beneath them kept, four of those sentences
this pass's own, two of them inside the sweep whose whole purpose is to stop
exactly that; and two gates that could not fail — a `forge` process *killed* before
it ran anything scored as a mutation kill, and the census accepted a settlement
site under a shorter site's name. `docs/plan.md` §6f carries the table.

**One departure from the v1.6.4 shape, recorded rather than glossed.** That pass's
third read was a Claude-family verifier, and it found the one thing two Codex
rounds did not. This lane may not spawn sub-agents and the coordinator did not
answer the question about it, so all five reads here are one family. A
second-family read on this tag is the thing this record is weakest for lacking.

**Residue.** Every row with the effort it takes to reach it and the witness that
measures its limit.

| id | what remains | effort | limit witness |
|---|---|---|---|
| `R-F2-liveness` | a quote that carries fees and whose pool stays `Moved` holds up settlement, and settlement is ordered | keeping one listed pool's spot more than `MAX_TICK_DEVIATION` from its own 600-second average at every block anyone calls `settle`; the escape is the timelocked pricer lever, the same one the platform-coin branch has relied on since round 4 | `test_aMovedQuoteSettlesOnceItsSpotIsBackInsideTheBound` — recovery works once the deviation closes; `test_aMovedQuoteWithNoFeesThatWeekDoesNotHoldTheWeekUp` — the reach stops at quotes that carry fees |
| `R-grace-reach` | an EMPTY listed quote that is `Unpriceable` still blocks its week inside the grace. Predates this pass; `Moved`'s reach was narrowed, this one was left | none: a pool with too little history | bounded at three days by `PRICING_GRACE`; `test_anUnpriceableQuoteBlocksItsWeekThenCountsAsZero`. Coordinator question Q7 |
| `R-Q2-pricer` | `_ratioQ128`'s reciprocal branch panics below `sqrtP = 2^32` and divides by zero at `sqrtP = 0`; `_vouch` refuses neither. `settle` reads `priceQ128` in a loop, so a panic there blocks every emission week | a pinned route pool that reports a square-root price outside the venue's own range — the deployer chooses those pools, and a real v3 pool cannot | the measurement in `src/FeastPricer.sol`: 0.0075 % of output headroom at `MIN_SQRT_RATIO`, 161 443 input units above the crossing. Coordinator question Q2 |
| `R-Q3-sink` | `take`'s cost panics at `amountOut >= 2^192` instead of refusing by name | a lot above `2^192` raw units and a single take of it. Unreachable with money: the entire platform supply buys 54 210 108 units at the opening price | the measured threshold in `src/FeastPlatformSink.sol`. Coordinator question Q3 |
| `R-Q8-converter` | `_expectedAfterHop` compounds each hop's expectation into the next with no ceiling, so a two-hop route at extreme prices panics before any swap runs | a route whose pools sit at those prices; it costs the caller their own conversion and nothing else | the measured counterexample in `src/FeastConverter.sol`. Coordinator question Q8 |
| `R-sweep-4` | a week's track values accumulate across the quote list under no bound | a pricer listing on the order of `2^48` quotes, each costing two external calls inside one `settle` | none. A counting argument, labelled as one |
| `R-sweep-27-28` | the hook's allowance cap and rate | on the order of `1e22` settlements; the RATE overflows first, at `pending ≈ 7.72e59` | none. Carried forward from §6e unchanged, and now stated as a RESULT row |
| `R-fork` | the 23 fork tests | an RPC endpoint this machine does not have | none. Recorded `not-run`, never as passing |
| `R-lens-family` | five lens reads, one family | — | the v1.6.4 record itself: its Claude-family unit found the one thing two Codex rounds did not |

**One identifier changed in a pack's proof.** F2's closure needs a named
`QuotePriceMoved` to mirror `PlatformPriceMoved`, so the MEDIUM's PoC has one
identifier amended — its `expectRevert` selector — with the pack's original line
kept verbatim in a comment beside it. The assertion's intent is untouched:
settlement is refused and `settledCount` stays 0. Round 1's fresh-eyes lens was
asked to judge that specifically and called it legitimate.

**The coordinator ruled on nothing.** `plans/v165/plan.md` was anchored
`state: plan-stop, ball: coordinator` with eight questions and polled in the
foreground for about an hour before the work began, and at every step after it;
no `plans/v165/ruling.md` ever appeared. The coordinator's one message in the
whole pass was the instruction to reconcile the tree and continue after the
quota kill, under the same brief and the same stop protocol, and it answered none
of the eight. The unit proceeded on the brief alone: everything the brief mandates
in as many words is done, and **every question that would have widened the work
into another contract was answered by recording the defect in that contract's own
file and changing nothing** — Q2, Q3 and Q8. Q1 was taken as recommended and declared. Q4 is
unchanged from §6e. Q5's second lens family was not run. Q6 and Q7 stand open.

**Sealed tree.** `<sha256>  <path>` for every file this pass changed but this one —
a document cannot carry its own hash, and the tag is the pin for the whole tree
including it.

```
cf2292f24a088592c72cfa8a575a23773d8e47b63bd1fecdc100d49f488e4061  audit/invariants.yaml
6779ba16f4844889f74a7aaeaac7c83662cf3e11f0f6c9a0bd0831382c0c740e  contract-audit.yaml
2a9465a45f170bf2afc716af6dfb031acf3752a7321248b8fad13a9f23fd2b9c  docs/abi/FeastEmissions.json
099739574fd1e4604909231ee755b759851f67ee841671f387c543dc116d179a  docs/plan.md
155aa76e0fa51b4e791e42530a0e4ff3368f714ec76d5c64ceb65767db6f5f5f  docs/site-census.md
6db8a2dfed830cf864c881097f69c0691787c85f2f253f4a0d45acd739718490  plans/v165/plan.md
43d8ff1a3dd921a95373ed794760aeef9938a8d754385d1fd18e62006394f98e  src/FeastConverter.sol
56c00d893011fd339ee77ff58117b4f7f2707cf04428a38bd7627fd51e5df7db  src/FeastEmissions.sol
dc33aa3cc21a6e67fe605cf9d88c107a790e572363f057250766657dfaf73f4c  src/FeastPlatformSink.sol
c9ed34067fba54303dd6fbe87472f81f8781c494852491e862008621f868c5a5  src/FeastPricer.sol
67a316542a9b3aa80710eaf023655e3c7b7705b0844bc8d1b22b8161ca549c57  test/audit/poc/EmissionsMovedQuoteZeroed.t.sol
b184ebdbc00a092233a60fad3d054f2498352e2e6331385bf588bd19c11c24a5  test/audit/poc/EmissionsValueCapOverflow.t.sol
e0ca21fa9e234a29ddb1ffdd117d965d1241b19b754da0d55ec96028eb9f1ffe  test/FeastBytecodePin.t.sol
148baeadad340641fe03b7bfd85fcc57ffe83f8c1cbb7cc5cbb4abebd9464959  test/FeastEmissions.t.sol
3fa0f3c5ebdc5f6e18ff92105ccbfb9dc6e3d41a1928315e89260cc45569ddab  test/FeastV165Bounds.t.sol
900969773840a3780818d90998b5c9885e2bbe5d46b518fe838d4c0d79a55ca7  tools/check-census.py
78e159f8a23de8ef4aa6447b1d9a42d58975e3c67d9b3206b9cabce2b9aef4b2  tools/mutate.py
```

**Not done, deliberately:** no pull request, CI run or merge — this repository has
no remote, as at every seal since `v1-internal`; no deployment; no keys; nothing was
sent to chain id 56. No audit pack was built: the dual-family `/contract-audit` pack
on this tag is the coordinator's to run as the next lane, and it is how the two
findings this pass closed get checked by someone other than the lane that closed
them.

### v1.6.6 seal receipt (2026-09-15, tag `v1.6.6-internal`)

The coordinator's ruling on `v1.6.5`'s eight open questions, applied on top of
`v1.6.5-internal` (`69ed26f`). That tag stays exactly where it is: the ruling
arrived after it was sealed — the run that should have received it was killed by
an account quota wall before it was written — so nothing sealed was undone, and
this is what the ruling added.

**Q2, Q3 and Q8 are fixed; Q1, Q4, Q5, Q6 and Q7 stand as recorded.** All three
fixes are the shape the whole pass is about — a product whose RESULT may not fit
a word, formed before anything asked whether it could — and all three now refuse
**by name** where they panicked: `_inVenueRange` in the pricer, a saturated
`CostAboveLimit` in the sink, and `RouteExpectationTooLarge` in the converter.
Sweep rows 12, 16, 17 and 21 are closed, each naming the witness that closes it.

**Nothing reachable moves.** Q2's bound is one a real v3 pool cannot leave; Q3's
threshold sits fifty orders of magnitude above what the platform coin's entire
supply can buy; Q8's needs a route whose pools sit at prices no sane route
reaches. What changes is the answer at the extreme, in three contracts whose
documented promise was already that they do not panic.

**What the lenses took off this pass, in four reads.** Two round groups, two
lenses each, `codex gpt-6-astra` at effort high: **HIGH 0 in all four**, MEDIUM 0,
LOW 12 — and one of the twelve was in the production code the ruling had just
added. Q2's first predicate excluded `MIN_SQRT_RATIO` on the strength of a
sentence about swap *limits*; the venue's *stored*-price domain is `[MIN, MAX)`,
so a guard meant to stop the pricer refusing to answer was refusing a price the
venue calls valid. Q8's first witnesses never reached `high == d` and both ran
forward, so relaxing the guard by one, or leaving the reciprocal arm unguarded,
escaped them — while the sweep row for the reciprocal case was closed on their
strength. And the reciprocal witness's own lower case accepted any revert, so an
unguarded OUTER step satisfied it too.

**And four repairs to the gates, three of them in the same two files.** A
`_release` call written with a space or a comment before its paren escaped
settlement discovery entirely. A commented-out test still satisfied every census
obligation. The declaration index — the one that EXEMPTS rows from the stale-row
check — found zero of the sixteen constructors and counted block-commented
functions as declared. And the mutation classifier was repaired for the third
time in two passes: v1.6.5 caught a process that never ran, v1.6.6 round 1 a
process that ran while the network failed under it, round 2 a failure record with
no reason at all. Every one of those is a gate reporting success without having
checked — which is the same defect as the findings, one level up.

Every gate run on the sealed tree; the line after each is its exit status.

```
forge test                                   # 451 passed, 0 failed, 23 fork skipped (474 total)
### exit=0
BSC_RPC_URL=<from the ruling's endpoint> forge test --match-test fork   # 23 passed, 0 failed, 0 skipped
### exit=0
FOUNDRY_PROFILE=ci forge test                # the same 451, at 10,000 fuzz runs per property
### exit=0
FOUNDRY_PROFILE=ci forge test --match-path 'test/audit/invariants/*'   # 7 passed, 512 runs / 65,536 calls
### exit=0
python3 tools/check-boundaries.py            # licence, authority, identity, surface, abi
### exit=0
python3 tools/check-census.py                # 30 mechanisms, 247 rows; all 5 _release sites enumerated, none stale
### exit=0
python3 tools/check-census.py --self-test    # eleven probes: three row checks, five source scanners, and the coverage pair both ways
### exit=0
python3 tools/mutate.py --self-test          # fourteen probes: ten on the kill classifier, four on the recovery path
### exit=0
forge test --match-path test/FeastBytecodePin.t.sol   # the sixteen runtime hashes, three re-pinned
### exit=0
python3 tools/mutate.py --slice=k/21 (k=1..21)   # 207 of 208 caught, 0 survived, 1 knowingly unkilled
### exit=0
```

**The fork tests ran, for the first time in this programme.** The ruling supplied
an endpoint; the variable the suite reads is `BSC_RPC_URL`, filled from it by a
shell pipeline that never prints it. The endpoint was independently confirmed to
be a real archive node — it serves both the header and the account STATE at the
pinned block `120 721 477`, 1.18 million blocks back — and foundry's local RPC
cache for those blocks already existed on this machine, so this run measured the
tests rather than the network. **23 passed, 0 failed, 0 skipped.** No URL and no
key fragment appears in this repository or in any log it keeps.

**Residue.** `R-Q2-pricer`, `R-Q3-sink` and `R-Q8-converter` are gone — they are
closed. What remains, each with the effort it takes to reach it and the witness
that measures its limit:

| id | what remains | effort | limit witness |
|---|---|---|---|
| `R-F2-liveness` | a quote that carries fees and whose pool stays `Moved` holds up settlement, and settlement is ordered | keeping one listed pool's spot more than `MAX_TICK_DEVIATION` from its own 600-second average at every block anyone calls `settle`; the escape is the timelocked pricer lever | `test_aMovedQuoteSettlesOnceItsSpotIsBackInsideTheBound`; `test_aMovedQuoteWithNoFeesThatWeekDoesNotHoldTheWeekUp` |
| `R-grace-reach` | an EMPTY listed quote that is `Unpriceable` still blocks its week inside the grace — v1.6.4 behaviour, left by Q7 | none: a pool with too little history | bounded at three days by `PRICING_GRACE`; `test_anUnpriceableQuoteBlocksItsWeekThenCountsAsZero` |
| `R-sweep-4` | a week's track values accumulate across the quote list under no bound | a pricer listing on the order of `2^48` quotes, each costing two external calls inside one `settle` | none. A counting argument, labelled as one |
| `R-sweep-27-28` | the hook's allowance cap and rate | on the order of `1e22` settlements; the RATE overflows first, at `pending ≈ 7.72e59` | none. Carried forward by Q4, unchanged since §6e |
| `R-comment-stripper` | the census's comment stripper does not parse string literals, so a `//` inside a Solidity string would blank the rest of that line | none; it is a property of the tool, not of an attacker | it can only LOSE a declaration or a call, and every scanner using it fails closed — stated in the code |
| `R-lens-family` | six lens reads across v1.6.5 and v1.6.6, all one family | — | the v1.6.4 record: its Claude-family unit found the one thing two Codex rounds did not. Q5 confirms the next station answers this, not this pass |

**Sealed tree.** `<sha256>  <path>` for every file this pass changed but this one.

```
ac87bd7aaadaef1217617981212196bcc511aabb34756c7f16b7a6a202adbc7a  docs/abi/FeastConverter.json
68960672179ed99457430a5cfcccab99a7819188672069993664d7af44181e61  docs/plan.md
0b13ca22601e4b418b6f6d5552717457230b7bd26ae64d5597c891e3e97f9f49  docs/site-census.md
46f61a50521c9a682faff8e27293abf1f54b7782f602ff0403edff811adbd657  plans/v165/plan.md
0903cedce6dc72e43a152af94b2f147aa5a6a51a2a93f6fb96e4aa0e3acbd200  plans/v165/ruling.md
20de6acc9f0e4cd744156f12b93c79236bc0fe1d33390c3a9fea8cb5f8ce0ac3  src/FeastConverter.sol
26943dd96afa064acaecb438806b4a10b8fb4b32cb35c1d213a9508c29222496  src/FeastPlatformSink.sol
eba202a6384b248dc8fa667740cb059808f0404c04f2e04b854c631fcb8e5757  src/FeastPricer.sol
3d92b0b00e4d5fbfb465ff9deb0a234a5abf461ae419a02795b248e6eeca8d83  test/FeastBytecodePin.t.sol
235a8aa74e5bf11c02278aaac67fb7708c3aa341040d323393b4ecad1ad3eef9  test/FeastV166Bounds.t.sol
1f943166ddd17ad94498bfed0ae511947ef886c18db9b4632663e215ff93d5b2  tools/check-census.py
37436ae2263ba21f1a8bb968c8cc8477870cea42878e6a53a8db80677e5345e8  tools/mutate.py
```

**Not done, deliberately:** no pull request, CI run or merge — this repository has
no remote, as at every seal since `v1-internal`; no deployment; no keys; nothing
was sent to chain id 56. The `v1.6.5-internal` tag is untouched. The dual-family
`/contract-audit` pack on this tag is the coordinator's to launch.

### v1.6.7 seal receipt (2026-09-15, tag `v1.6.7-internal`)

What the dual-family `/contract-audit` pack found on `v1.6.6-internal`, and the fixes its findings
forced. `v1.6.6-internal` stays where it is; the pack audits it and this tag carries the answer.

**Three defects and three false sentences, from four lens reads.** One defect was found by the
Claude family alone, one by both families at three separate sites, one by the codex family in both
its units. None was found by any of the three static engines, which between them produced 337
normalised records and 236 after deduplication — every one of which a lens triaged.

| | Finding | Families | Where |
|---|---|---|---|
| P1 | the first-week rule decided on price availability, not the launch state | Claude | `FeastEmissions::settle` |
| P2 | `claimAsBnb` has no admissible route for a wrapped-native quote | **both** | `FeastHook::claimAsBnb` |
| P3 | `consult` floors the history but not the window it promises to floor | codex | `FeastOracle::consult` |

P1 is the substantial one: for the 55 minutes between the launch window's settling swap giving the
platform pool a price and the pool actually opening, a closing week could settle either way, and
which one it got was a permissionless race. Measured on the fixture's own calendar — where week 2
closes at the very second the window ends, as the shipped recipe puts them — the two rules produce
**0.149 and 5 255 443 platform coin** for the same week. The shortfall was never stolen (it stays
in `remaining`), but it never reached that week's traders, creators and referrers either.

Every gate run on the sealed tree; the line after each is its exit status.

```
forge test                                   # 462 passed, 0 failed, 23 fork skipped (485 total)
### exit=0
BSC_RPC_URL=<the ruling's endpoint> forge test --match-test fork   # 23 passed, 0 failed, 0 skipped
### exit=0
FOUNDRY_PROFILE=ci forge test                # the same 462, at 10,000 fuzz runs per property
### exit=0
FOUNDRY_PROFILE=ci forge test --match-path 'test/audit/invariants/*'   # 7 passed, 512 runs / 65,536 calls
### exit=0
python3 tools/check-boundaries.py            # licence, authority, identity, surface, abi
### exit=0
python3 tools/check-census.py                # 30 mechanisms, 248 rows; all 5 _release sites, none stale
### exit=0
python3 tools/check-census.py --self-test    # eleven probes
### exit=0
python3 tools/mutate.py --self-test          # fourteen probes
### exit=0
forge test --match-path test/FeastBytecodePin.t.sol   # the sixteen runtime hashes, three re-pinned
### exit=0
python3 tools/mutate.py --slice=k/22 (k=1..22)   # 210 of 211 caught, 0 survived, 1 knowingly unkilled
### exit=0
```

**The fork row is measured again**, over the same pinned archive endpoint at block 120 721 477;
the sandbox chain that moved to a port-forward is a different facility and these tests do not use
it. No URL or key fragment is in this repository or in any log it keeps.

**What the pack costs to trust, stated plainly.** Four of the eight lens units this station
launched produced nothing: round 1's four were lost to operator-side failures (two stall-killed by
contention, two voided by an edit made under them), and the hook unit's Claude half hit the
account's session limit and is recorded `UNMEASURED`, never substituted. So the **hook checklist
has one family's answers, not two** — 19 HOLDS, 1 FINDING, 3 N/A across its 23 rows — and the
coverage unit is the only one this pack can call dual-family. The pack's own Engine coverage table
says which is which.

**Residue.** Every row with the effort it takes to reach it and the witness that measures its limit.

| id | what remains | effort | limit witness |
|---|---|---|---|
| `R-hook-headroom` | `FeastHook` is **24 133 bytes against EIP-170's 24 576 — 443 left**, down from 601 | none; it is a property of the tree. P2's first draft cost 400 bytes and returning `_claimTo`'s own amount bought 242 back | `test/FeastBytecodePin.t.sol` fails the moment it does not fit; the number is stated there and here |
| `R-hook-lens-one-family` | the 23-row hook checklist was answered by the codex family only | none; the Claude unit hit an account limit mid-run | the pack's Engine coverage table records `UNMEASURED` with the provider's reason, so "we never looked" is legible as such |
| `R-pricer-no-revert` | `FeastPricer`'s "never reverts" promise still excludes several external reads — token getters, `slot0`, observation getters — which can revert outside its `try` | a pinned route pool that reverts on a getter; the deployer chooses those pools | recorded as a lens LOW with its construction; wrapping every read is a design change, not a line |
| `R-converter-preflight` | `hopIsPriceable` approves a hop the deviation guard would refuse, so the preflight is wider than the conversion | none; it is a view | `CA-fab4a4a463`, carried from the v1.6.4 pack where three lenses disagreed; this pack's codex unit CONFIRMED it |
| `R-external-liquidity` | anyone may add a position to a feast pool and initialise the ticks it needs | ordinary LP cost | the sentence is corrected; the behaviour is the venue's and is not changed here |
| `R-F2-liveness` | a quote that carries fees and whose pool stays `Moved` holds up settlement | keeping one listed pool's spot outside `MAX_TICK_DEVIATION` at every block anyone calls `settle`; the escape is the timelocked pricer lever | `test_aMovedQuoteSettlesOnceItsSpotIsBackInsideTheBound` |
| `R-grace-reach` | an empty listed quote that is `Unpriceable` still blocks its week inside the grace | none: a pool with too little history | bounded at three days by `PRICING_GRACE` |
| `R-sweep-4`, `R-sweep-27-28` | the quote-list accumulation, and the hook's allowance cap and rate | `~2^48` listed quotes; `~1e22` settlements | none. Counting arguments, labelled as such |
| `R-comment-stripper` | the census's comment stripper does not parse string literals | none; a property of the tool | it can only LOSE a declaration or a call, and every scanner using it fails closed |

**Sealed tree.** `<sha256>  <path>` for every file this pass changed but this one.

```
5c70c38ad8771d0b29691873340035a8882efcb7df42b040bb5716f47c964cfa  .gitignore
c2fef548b43ceed405aa5ff6880d98052b55c09fafec7a1d35fa709a42ef5646  audit-pack/rounds/r1/deterministic.json
7236325e3d598e185a10c079ca45e0502d2b60f288dc4277d2765be1cb868e1f  audit-pack/rounds/r1/deterministic.md
80d147c5c26135a3597b010a7e4a9d225aa14072d5b9f2f5bb28fcd34489c37f  audit-pack/rounds/r1/runtime.json
d9fcbdaa7c4ab644128461538b73f51556539036d36c52225c87c85246fb0772  audit-pack/rounds/r1/tools/aderyn.json
055817b82c413075adb6e7336a79d12a2f568f02d238564d19e31a40eec238f4  audit-pack/rounds/r1/tools/aderyn.log
e2f6465ac9d336bbe605292e726ae47d326f9f779250baf462c921871ba7423b  audit-pack/rounds/r1/tools/semgrep.json
6e6d05d864cc45b6238addec8661737aea8f7c307c8975f4c2a124b34f211929  audit-pack/rounds/r1/tools/semgrep.log
d997ba7fdbc87bcc442d29fee9815c05730408a7fa429bcb7ee404bd7a9af81e  audit-pack/rounds/r1/tools/slither.json
2ec2b9be54931be366a173e6a74b618c3d3b7bf3dc8e9efa02630484db1df612  audit-pack/rounds/r1/tools/slither.log
d1114de964fc0487841c0f03c46cbffdf4aa932e7d895eddcab71dd7bb3c5f4a  audit-pack/rounds/r1/tools/versions.json
9c88bf7df0ee26d9717659521c056f7e44802d9d427cf01ea1b1b1edfe241f29  contract-audit.yaml
903d91fb8e5a2a7db23ce19051f0531a8e3fae8e8fe7803e229c023c281fc505  docs/interface.md
adcc43f4608f7a6dd4fd1cb502dd15b848e09c4804b37f02d12e047e7bec8c03  docs/plan.md
d3daeaf4721601e7e4e95e7bb8a0d9b3b65a2f5a4c03319278b80bb768335fc1  docs/site-census.md
cd606e6690157183552ed12676df7e957a4466a57c0f8670f110cb3280c422d8  src/FeastConstants.sol
1731b84f7a90404b9f6c3ff8ddb31c45565e24b07b85e47e08ce8cb2df94ca41  src/FeastEmissions.sol
8bec8b096d0708fb9cfdf19d7f5bd138aad027cc3252f3a736e2ad3885e9c137  src/FeastHook.sol
422a4d15c007b72d137c387a81ac9142aef08b38693f5c68f9da65088b0b8a6c  src/FeastOracle.sol
56b031e4120256d321034e07f6a726630049b8ca2557e643f1a02246ca3d191d  test/audit/poc/EmissionsPreLaunchValueCap.t.sol
b528248cd9f64aa9c1e7974b3311c7fa470f38a71551808ff2c3455ce9b69126  test/audit/poc/EmissionsValueCapOverflow.t.sol
ae8815f5525f363cbcfbbcb0832504570b10fc8c00ae4c9de51504b9eb531471  test/audit/poc/HookNativeQuoteClaim.t.sol
cf79dd1907a490a5b8b6e978739bb1c3857d104e9a06b8c404ae0ffd595ef99d  test/FeastBytecodePin.t.sol
dba5a87240abbd234bc13e624bea64c6ed64b1f1d2376919d985dfd0281b4adf  test/FeastV165Bounds.t.sol
1509ee1520a52099590aece79c6317b620674524b04fe62e1d2c7a9aa9c54868  test/FeastV167Bounds.t.sol
01b395790395cada139c283ca6249f521025d15b82c73df25590b37c1b965c0d  tools/mutate.py
```

**Not done, deliberately:** no pull request, CI run or merge — this repository has no remote; no
deployment; no keys; nothing was sent to chain id 56. `v1.6.6-internal` is untouched. The pack
under `audit-pack/` is the artefact for the AstraSec submission and the Savant comparison.

## Seal receipt

Each gate was run on the sealed tree; the line after each is its exit status.

```
git diff --quiet 7bdb5fc -- src script
### exit=0
forge test                                   # Ran 37 test suites in 1.51s (6.14s CPU time): 315 tests passed, 0 failed, 23 skipped (338 total tests)
### exit=0
BSC_RPC_URL=<read-only fork source> forge test --match-test fork   # Ran 10 test suites in 1.98s (14.09s CPU time): 23 tests passed, 0 failed, 0 skipped (23 total tests)
### exit=0
python3 tools/check-boundaries.py            # licence, authority, identity, surface, abi
### exit=0
python3 tools/check-census.py                # completeness against the invariant list
### exit=0
python3 tools/check-census.py --self-test    # 203 rows, and the checker can fail
### exit=0
python3 tools/mutate.py                      # 136 of 136 mutations caught
### exit=0
```

Not done, deliberately: no pull request, CI run or merge — this repository has
no remote of any kind, as at `v1-internal`; no deployment; no keys; nothing
was sent to chain id 56 (the deploy rehearsal ran on a local fork with chain id
31337, reading the pinned block from a read-only source).

---

## v1.6.8 — the lifetime referrer binding (2026-09-18)

The increment to `v1.6.7-internal`. **One contract changes.** Not a finding, not
a correction: an owner ruling, taken before the audit starts because the mainnet
contracts are immutable afterwards and this is the only window.

Today a referrer is a property of a *trade* — a router puts one address in
`hookData`, the hook credits it, nothing is remembered. A wallet brought by a
KOL's link pays that KOL on the buys made from the page that carried the link
and on nothing else. The ruling makes the relationship a property of the
**wallet**: written once, by the wallet itself, inside the first trade that names
a referrer, and never changeable by anyone afterwards.

`docs/referrer-binding.md` is the design, the truth table, the gas and the
invariant walk. This section is what an auditor should point a lens at.

### The diff, file by file (against `v1.6.7-internal`)

| File | Δ | What |
|---|---|---|
| `src/FeastHook.sol` | +135 / −21 | (a) `mapping(address => address) _referrerOf`, the first hook state **not keyed by pool**, with a `referrerOf(address)` view and a `ReferrerBound(wallet, referrer, firstPool)` event; (b) `_referrerFrom` returns `(referrer, wallet)` and accepts a second `hookData` length — 32 bytes unchanged, 64 bytes `abi.encode(referrer, wallet)`, everything else still "no referrer, no revert" (R3); (c) `_addressFrom` — the masking word reader lifted out of the old parser and now applied to **both** words, so a dirty wallet word reads as zero rather than reverting the swap; (d) `_referrerFor(poolId, hookData)` replaces `_referrerFrom` at the two accrual sites and is the **only** place `_referrerOf` is written; (e) the v1.6 ruling-5 Q5 refusal of a referrer who is the payer moves out of the 32-byte parser and up into `_referrerFor`, so it now covers both forms from one line |
| `test/FeastReferrerBinding.t.sol` | +580 | 27 tests, written red first |
| `test/FeastBytecodePin.t.sol` | re-pin | `FeastHook` 24,133 → 24,447 bytes |
| `tools/mutate.py` | +5, 2 re-anchored | one mutation per predicate |
| `tools/check-census.py`, `docs/site-census.md` | +1 mechanism, +13 rows | `referral-binding`, 248 → 261 rows |
| `docs/plan.md` | R3, I7, I16, §7 Q10 | see below |
| `docs/referrer-binding.md`, `docs/interface.md`, `docs/abi/FeastHook.json`, `README.md` | — | the design, the integrator note, the ABI, one promise row |

### The rule, in one place

```
referrerOf[tx.origin] set        -> pay it; hookData is not consulted at all
otherwise, referrer named == 0   -> nobody
otherwise, referrer == tx.origin -> nobody          (v1.6 ruling 5, Q5, both forms now)
64-byte form:
  referrer == BURN_ADDRESS       -> nobody, no bind
  referrer == the named wallet   -> nobody, no bind
  named wallet != tx.origin      -> pay per trade, no bind   (bundler shape)
  named wallet == tx.origin      -> pay, AND bind for life
32-byte form                     -> pay per trade, never binds
```

**The subject is `tx.origin` and never the wallet named in `hookData`.** The
venue hands a hook the router's address, so a named wallet is a claim by whoever
built the calldata; if the payment lookup keyed on that claim, any terminal could
strip a binding by naming somebody else. The named wallet is an authorisation and
nothing more. This is the fourth site in this contract keyed on the origin, after
the opening cap, the ledger's payer and `_emitTrade`'s trader.

### Invariants to break

| # | Statement | Where to push |
|---|---|---|
| B1 | `_referrerOf[w]` is written **only** from zero, **only** in `_referrerFor`, and **only** when `w == tx.origin` | any second write; any path that reaches the assignment with `bound != 0`; a router that binds a wallet it merely names |
| B2 | No `hookData` can redirect a bound wallet's commission | the binding is read before the parse — find an ordering that is not |
| B3 | No `hookData` length reverts a trade | 64 is now meaningful; both words go through `_addressFrom`; the fuzz is `testFuzz_anyHookDataIsStillSurvivableIncludingTheNewLength` and the deterministic sweep is `test_noLengthOfHookDataRefusesATrade` |
| B4 | A binding belongs to a trade that happened | a fee-free trade must not bind; a trade the cap or R18 refuses must not leave one behind |
| B5 | The split is unchanged | `_bank` is not modified; the binding decides **who**, never **how much** |
| B6 | I7 as amended | one global address-to-address fact crosses pools; every unit of *value* — buckets, claims, caps, the ledger's per-quote totals — stays where it was |

### Declared, not defects

- **A bound bundler is paid for somebody else's trade.** An ERC-4337 trade has
  the bundler as `tx.origin`, so it neither binds nor reads the account's
  binding. If the bundler's own EOA has itself bound, row 1 fires and the
  bundler's referrer takes that commission. Bounded by `referrerBps` of one fee.
  The alternative — believing the named wallet — hands every terminal a bypass,
  which is worse and unbounded.
- **The first Feast trade a wallet makes with a referrer named decides its
  referrer for life**, on any pool, including a coin an adversary launched for
  the purpose, in the same transaction as a trade the user believes is something
  else. There is no re-binding, so there is no remedy. Ruled, and accepted: a
  second binding would be unfair to the referrer who made the introduction and
  would invite poaching.
- **A self-referral is still evadable with a second address.** Unchanged from
  v1.6; the refusal is a statement, not an enforcement.

### Residue

| id | what remains | effort | limit witness |
|---|---|---|---|
| `R-hook-headroom` | `FeastHook` is **24,447 bytes against EIP-170's 24,576 — 129 left**, down from 443. The binding cost 314 | none; it is a property of the tree. It is the tightest this unit has been, and the next change to this contract has 129 bytes | `test/FeastBytecodePin.t.sol` fails the moment it does not fit; the number is stated there, in `docs/referrer-binding.md` §3 and here |
| `R-binding-reaches-emissions` | a binding credits the referrer's `referred` track in `FeastFeeLedger` on **every** trade of a bound wallet, whatever the pool's `referrerBps` — and `FeastEmissions` prices that track into the weekly referrer pot while `FeastGenesisGrants` unlocks a partner's grant against it. So a binding routes a share of the **first year's emissions**, permanently, not only a slice of one fee | none; it is what the ruling asks for, applied to a ledger that did not exist when the ruling was taken | `test_aBindingCreditsTheReferrersLedgerTrackOnEveryTrade`. **Flagged for the owner rather than closed** — the arithmetic is sound under any distribution of that track; the question is whether the distribution is the intended one |
| `R-bundler-binding` | a smart-contract wallet cannot bind, and a bound bundler is paid for its users' trades | none | declared above; `test_aBundlerShapedTradeDoesNotBindButStillPaysPerTrade` |

### v1.6.8 seal receipt (2026-09-18, tag `v1.6.8-internal`)

Each gate run on the sealed tree; the line after each is its exit status.

```
forge test                                   # Ran 66 test suites: 490 passed, 0 failed, 23 skipped (513 total)
### exit=0
forge test --match-test fork                 # 23 skipped: this environment has no archive endpoint
### exit=1 (not run — see below)
python3 tools/check-boundaries.py            # licence, authority, identity, surface, abi
### exit=0
python3 tools/check-census.py                # completeness against the invariant list
### exit=0
python3 tools/check-census.py --self-test    # 261 rows, and the checker can fail
### exit=0
BSC_RPC_URL="" python3 tools/mutate.py       # 215 of 216 caught; 1 knowingly outstanding; 0 survived
### exit=0
```

**The fork row was NOT measured at this seal, and that is a gap rather than a
pass.** This lane's environment has no `BSC_RPC_URL`, and the endpoint
`tools/mutate.py` falls back to is not an archive node — it cannot serve the
pinned block 120 721 477, so the 23 fork tests error rather than skip and the
mutation baseline never goes green against it. The sweep was therefore run with
`BSC_RPC_URL=""`, which makes the fork tests skip themselves. **Any mutation
whose only witness is a fork test could have survived unnoticed.** None did —
every one of the 216 was killed by a non-fork witness or is the single
long-standing exception — but the stronger statement, that the fork witnesses
were also available to kill them, is not one this seal can make. `v1.6.7`'s seal
measured that row over a real archive endpoint and this one did not.

**The mutation sweep, honestly.** It ran twice. The first pass reported one
survivor — `allow a wallet to be its own referrer for life (Q4)` — which was a
real gap: deleting `if (named == wallet)` from the binding form left all 27
tests green, because Q4's re-taken rule already covers every case where the
named wallet is the signer, and nothing covered the bundler shape where it is
not. One test closed it. The second pass, on the sealed tree, is the one quoted
above. Three mutations were also re-anchored before either pass, found by
walking every `find` string against the tree it names rather than by running
them: two on the referrer-is-the-payer rule this change moved, one on a block
of `_beforeSwap` ending at the accrual call.

`KNOWN_UNKILLED` still holds exactly one entry, unchanged by this pass: `let the
callback ask for more than the hop brought (v1.6.3 r1, r1v)`, defence in depth
behind `_hop`'s measured-debit bound.

**Sealed tree.** `<sha256>  <path>` for every file this pass changed but this one.

```
4f85117616a63591bb6132e156e121c69088c2f3799154070c68279719de2b7b  README.md
63f25a0fc2f334ac2daa10b0852007d78514606df3673b3e6cd7cf7d05a8c6f7  docs/abi/FeastHook.json
ecaf30e274cd12806fb9e428aa2651c2456a6befd651513eba0c6a9a6ad4d125  docs/interface.md
e3d14a7d0161d4df9e24634db28d66ecedf10d0cca103f029d81f9df7e59590c  docs/plan.md
f1fb8c0be47262345629aac5a981a5b972807fe75202b1dbaca83650286c6ffd  docs/referrer-binding.md
bc17d4db4784193ea71a85b0e6635eb7215cae78282eb5067d7448157aa4c804  docs/site-census.md
d5b53875b684abf5a3f96cff196be110dfb4aa1eddaa4d7659df7aeb7232c1f6  src/FeastHook.sol
8924f7d1020d0e9db022f23ccafd8f80518b16e3695d5058074cc01cce49c162  test/FeastBytecodePin.t.sol
60ab5cbd53d3da51b1c6b90a9e8f8f0c0a52375a7a4ab7f546cc8b8eca2fc924  test/FeastReferrerBinding.t.sol
5044aba388982bb6666d3a65a8f4c02f1e7a7d35fb4e3bd1398c0e640823dfe7  tools/check-census.py
20b11f10732a9ce86e119bc60a03b2ac86c3834483c33748230010b935a29bc3  tools/mutate.py
```

**Runtime bytecode.** One contract moves; the other fifteen are byte-identical
to `v1.6.7-internal`, which `test/FeastBytecodePin.t.sol` asserts for all
sixteen.

| contract | bytes | keccak256 of runtime code |
|---|---|---|
| `FeastHook` | 24,447 (was 24,133) | `0x1eb471e2638e04dbf5c8f9c25835b6de4e1541c107aa8e9ad0b149688a28f60f` |

**A note on this branch's own history.** The commit `anchor: no seal — the
branch point is not v1.6.7-internal, and the tag would say it was` sits in the
middle of this line and its title is no longer true of the tree it is on. It is
kept deliberately: it is the record of the handback, made when the work was
still on `master` and before the rebase onto this tag. `docs/referrer-binding.md`
§6 is the standing account.

**Not done, deliberately:** no pull request, CI run or merge — this repository
has no remote; no deployment; no keys; nothing was sent to chain id 56.
`v1.6.7-internal` is untouched.

### v1.6.9 seal receipt (2026-09-19, tag `v1.6.9-internal`)

The allocation the owner ruled on 2026-09-16 and ordered into the contracts on
2026-09-18: **60 / 25 / 14.2 / 0.8** in place of 65 / 20 / 14.2 / 0.8. The
change's own page is `docs/audit-briefs/v169-allocation.md`. Each gate run on
the sealed tree; the line after each is its exit status.

```
forge test                                   # Ran 66 test suites: 491 passed, 0 failed, 23 skipped (514 total)
### exit=0
forge test --match-path .../FeastInvariants  # 7 passed, 0 failed
### exit=0
forge test --match-test fork                 # 23 skipped: this environment has no archive endpoint
### exit=1 (not run — see below)
python3 tools/check-boundaries.py            # licence, authority, identity, surface, abi
### exit=0
python3 tools/check-census.py                # completeness against the invariant list
### exit=0
python3 tools/check-census.py --self-test    # 261 rows, and the checker can fail
### exit=0
BSC_RPC_URL="" python3 tools/mutate.py       # 216 of 217 caught; 1 knowingly outstanding; 0 survived
### exit=0
```

**The fork row was NOT measured at this seal**, for the same reason v1.6.8's
receipt gives: this lane's environment has no `BSC_RPC_URL`, so the 23 fork
tests skip themselves and the sweep ran with them skipping. Any mutation whose
only witness is a fork test could have survived unnoticed; none did. This is the
second consecutive seal that cannot make the stronger statement `v1.6.7` made.

**`KNOWN_UNKILLED` is NOT empty, and this seal does not claim it is.** The
task's brief called for it empty. It holds exactly one entry, unchanged since
v1.6.3 and unchanged by this pass: `let the callback ask for more than the hop
brought (v1.6.3 r1, r1v)`, defence in depth behind `_hop`'s measured-debit
bound. Emptying it would mean either deleting a documented exception or writing
a witness for a refusal that has no reachable behaviour in the shipped model —
a test that cannot fail. `src/FeastConverter.sol` is also outside this lane's
write surface. Recorded as a divergence from the brief rather than resolved.

**The mutation sweep ran on `eebc797` and still carries, checkably.** Five
commits followed it, all narrative corrections. `git rev-parse
eebc797^{tree}:src` and `HEAD^{tree}:src` are both
`1365aeec28e3dee0a23a015317a3a5c710ac34e2`; `test/` changed in comments only;
and `tools/mutate.py`'s sole non-comment change is one `destroys` string, which
is printed when a mutation survives and never executed. No mutation's `find`,
`replace` or `filt` moved.

**The endorsing rounds, honestly: it took four, and the first three refused.**
`.runs/codex-loop/v169-allocation/`, briefs and verdicts preserved.

| round | tree | verdict | what it found |
|---|---|---|---|
| r1b | `eebc797` | HIGH=0 MEDIUM=0 LOW=2 | `POOL_BPS` does not "reach no runtime byte" and a wrong one is not "invisible in every token balance"; four more current statements still published the old split |
| r2b | `8a3b2be` | LOW=1 | the corrected account still attributed both moved operands to `TEAM_BPS`, and over-generalised "no basis-point constant reaches runtime code" |
| r3b | `cce64f0` | LOW=1 | the pin said "fourteen" where its own earlier line said fifteen; four `PUSH2 0x07d0` were all attributed to one constant when two are `MAX_CREATOR_ALLOCATION_BPS` |
| r4b | `2b5faf5` | **PASS** | endorsed |

**Not one of the findings was in the allocation.** All four were in prose
*about* it, and three were the same error repeated: reading a number off an
artifact and narrating a cause for it without checking the cause. The
allocation has been correct since the first commit. The corrections are left
visible in the documents — each names the spelling it replaces — rather than
applied silently.

**Four current statements still publish the old split, and this seal does not
close them.** They are outside this lane's write surface (`src/` limited to
`FeastGenesis.sol` and `FeastConstants.sol`; `audit/` not included at all):

| location | what it says | what is true |
|---|---|---|
| `audit/invariants.yaml:49` | invariant **P9**: "routed 65/20/14.2/0.8" | 60/25/14.2/0.8 |
| `src/FeastFactory.sol:219-222` | `@notice` "65% into its own pool, 20% to the team's vesting" | 60% / 25% |
| `src/FeastTeamVesting.sol:8` | `@title The team's 20%` | 25% |
| `src/FeastTeamVesting.sol:20` | "so the 20% would sit here for ever" | 25% |

`audit/invariants.yaml:49` is the one to fix first: it is not a comment but the
active invariant list a reviewer is handed, and P9 is the invariant about this
very allocation. The three `src/` lines are comments and reach no runtime byte
(`bytecode_hash = "none"`, `cbor_metadata = false`), so no bytecode claim here
depends on them. Four in-surface statements of the same kind *were* fixed:
`docs/site-census.md`, two in `tools/check-census.py`, one in `tools/mutate.py`.

**The audit pack, and how far the tree has moved from it.** `audit-pack/`
scanned `50994f8`, whose `src` tree is `72ff9e0daa28dce72904454995753d9f444dea76`
— byte-identical to `v1.6.6-internal`. The sealed tree's `src` is
`1365aeec28e3dee0a23a015317a3a5c710ac34e2`. Five files differ, across three
releases:

| file | releases since the scan |
|---|---|
| `src/FeastHook.sol` | v1.6.7 (native-quote claim), v1.6.8 (lifetime referrer binding) |
| `src/FeastEmissions.sol` | v1.6.7 (first-week rule keyed on launch state) |
| `src/FeastOracle.sol` | v1.6.7 (`consult` floors the window) |
| `src/FeastConstants.sol` | v1.6.7 (the tick-spacing sentence corrected, HK03) |
| `src/FeastGenesis.sol` | **v1.6.9 (this change)** |

`audit-pack/notes.md` still says "the tree now carries tag `v1.6.7-internal`";
that sentence is two seals stale. It was not updated here because `audit-pack/`
is outside this lane's write surface, and the note is recorded in the same
list as the four above. `build_pack.py` will still refuse to assemble a
`summary.md` against HEAD, for the reason its own notes give.

**Sealed tree.** `<sha256>  <path>` for every file this pass changed but this one.

```
1166e16e50bb31fd94a0e5ddbabea15fcf3db173e6d172073b8c8cd2615d4b4f  README.md
a9de8af1fed8e09a76d4e1fc3215009c176b9baa2c9f83671586d5beca086143  docs/audit-briefs/v169-allocation.md
875432021dfba2db10c773d3c197ea971c8b4a3a0ed763073383d3501ba8f03a  docs/interface.md
407c3877568ab24773381d25e25b6caa06c7a87a34f25ac3b563cec1f78789d0  docs/mutations.md
e4a86b62295f197d89926f9a97c57056942d5cecfa9b101018de877d9b697157  docs/site-census.md
a6729742a712a615b1b46610478b283732bc17f395e018dd920249ac121a4a4a  src/FeastGenesis.sol
0a4b13685bbe81469cd12a2b5f4dd003dff85d8f6449cc7cef9aa949e4ee31c2  test/FeastBytecodePin.t.sol
d63c6d5d9c7eed36428bb830fc4087d64ed5301f3a51fd591c6b75b7076bb3a8  test/FeastGenesis.t.sol
0e1d1880962c3f9501542e8a0037092225f34aec3163b23e59d72fbc25a9f2d4  test/FeastPackageTwo.t.sol
f873a676a18c28ebc2a1153b49e90be050d7073cdec743ab1942797197c48190  test/FeastRecipe.t.sol
27c4c451951b3720551fbe3d69b042e188ce76b4250568252f0425994ba66c6a  test/utils/GenesisFixture.sol
81ee9259b5ccea0eddf9a0bf9c768cb446fa345a420ff6cda9e0f6714966433b  tools/check-census.py
511f49d081d0313be3cc61764c23cd5dbbe2f6a8d33fd9c83e302cbfc74d3993  tools/mutate.py
```

**Runtime bytecode.** One contract moves; the other fifteen are byte-identical
to `v1.6.8-internal`, which `test/FeastBytecodePin.t.sol` asserts for all
sixteen. `FeastHook` is among the unchanged, so its **129 bytes of EIP-170
headroom stand exactly as v1.6.8 left them**.

| contract | bytes | keccak256 of runtime code |
|---|---|---|
| `FeastFactory` | 16,088 (was 16,088) | `0xca92a2de2ff25d4b4e1a4772d851b367892ef50756fc09d1ec69065ee4f10246` |

The size is unchanged and the hash is not. Two folded token-amount operands
moved, each driven by its own constant — the team's `PUSH11` 200,000,000e18 →
250,000,000e18 by `TEAM_BPS`, and the pool's `PUSH12` 650,000,000e18 →
600,000,000e18 by `POOL_BPS`, since the factory's remainder collapses to
`supply * POOL_BPS / BPS` exactly at this supply. Both keep their widths, which
is why the length holds. The grants and emissions operands are byte-identical:
either share moved alone would have taken emissions off 14.2%, and moved
together they cancel in the derived `EMISSIONS_BPS`.

**Not done, deliberately:** no pull request, CI run or merge — this repository
has no remote; no deployment; no keys; nothing was sent to chain id 56.
`v1.6.8-internal` is untouched. No reserve-allotment or matching-funding
parameter was added, per the owner's ruling of 2026-09-18: investors subscribe
off chain from the team's 25%.
