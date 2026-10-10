AUDITED_TREE=e5c0a771107a8a17f510806bafd50bfe33035ec7
CHECKOUT_HEAD=d9b50c53c295d8393ef6f2d4e07b518de2d26241
# Carried MEDIUMs at v1.6.21-audit — what each costs, and what to do (r1.1)

| # | row | class | trigger | loss upper bound | who bears it | fix (contract / lines / bytes of free) | recommendation |
|---|---|---|---|---|---|---|---|
| 1 | `CA-33ea5aaf49` | preopen-regime-decided-by-settle-instant | guardian freeze across the close/openAt seam, or nobody settles in that hour | ≤ tokenCap(n) − valueCap: ≤ 5,255,443 FEAST at n = 2 (5,358,491 at n = 1); 0.53% of supply | the seam week's traders, referrers, creators; all holders gain via the week-52 burn | `FeastEmissions.settle` / ~3 lines / +40–90 of 10,897 | FIX BEFORE MAINNET |
| 2 | `CA-2d81ea2290` | false-three-day-protection | anyone reading the residue's justification; settle after 600 s of open time | promise short by 258,299 s (measured); no balance moves; the FEAST is row 1's | the owner (a wrong acceptance basis) | `FeastEmissions` comment / ~10 comment lines / 0 bytes | FIX BEFORE MAINNET (rides with row 1) |
| 3 | `CA-7da18d1e43` | own-brake-extends-own-window | multisig freezes near day 90, then assigns | window +604,800 s max, +172,800 s measured; ≤ 1e24 FEAST per empty slot named late instead of burned | FEAST holders (foregone burn); multisig and late partner gain time | `FeastGuardian.sunsetAt` / 1 line / about −30 of 20,772; closes rows 3 and 4 | FIX BEFORE MAINNET |
| 4 | `CA-7dca95d8e3` | sunset-unanchored-prefreeze | any freeze before genesis | +259,200 s measured; +604,800 s max, shared with row 3 | as row 3 | same one line (alone: +3 lines, +1 storage slot, +60–100) | FIX BEFORE MAINNET |
| 5 | `CA-407dffa3a4` | shared-origin-capture | anyone, one dust user-op through an unbound bundler | ≤ 30 bps of the quote leg of every later trade through that origin, plus that origin's share of the weekly referrer pot (≤ 40% of the week's emission) | KOLs and creators (commission); honest referrers (pot dilution); attacker gains | `FeastHook` / ~12 lines / net +60–160 of 246, rough and tight | FIX BEFORE MAINNET, if the bytes fit |
| 6 | `CA-4e08c595d3` | floor-sale-misses-price-rise | any taker, after a floor dominates (24 h in the PoC) | ≤ 50% of the FEAST the (1+f) rule would burn on the next take; 48,828,125,000,000,000 wei measured; zero against a one-call whole-lot take the tree already allows | FEAST holders (less burned); the next taker gains | docs only / 0 bytes (code alternative ~8 lines, +100–200 of 18,437) | ACCEPT |
| 7 | `CA-2fbb35d7a1` | hop-rounding-amplification | nobody; a static property of pinned pool prices | 11.111% understated on the synthetic route (measured); < 50% per hop at the venue's price floor (derived); < 1e-20 on any real 18-decimal route | emissions claimants and partners, negligibly; holders gain; conservative | `FeastPricer` / ~20 lines / +150–300 of 20,137 | ACCEPT |

**What was read.** The seven ledger rows (`audit-pack/findings.md:119-129`; the markdown cells are cut short, the full reasons are in `audit-pack/findings.json`), the four PoC files, the five original write-ups, `audit-pack/notes.md`, `docs/audit/overview-v1.6.21.md`, and each cited function as it stands on the tag. Every number below is tagged **measured** (a PoC or write-up figure, with where it is written), **derived** (arithmetic from the code, shown) or **assumed** (an input the tree does not fix).

**Two facts that apply to every row.**

- *Process cost of any fix.* A new tag; `audit-pack/bytecode.md` re-pinned for the changed contract; a mutation re-run on the changed file (v1.6.21's own incremental run was 15 of 15 on one file with one new mutant per applied check, `audit-pack/notes.md:131-132`); the proof gate re-run with the affected PoC un-skipped; and a delta the firm must re-review. The decision is 2026-10-01, their report is due 2026-10-03, mainnet is 2026-10-06: two working days of their time for any delta.
- *Fix now or never.* No contract in `src/` has an upgrade path (`docs/audit/overview-v1.6.21.md:54`). The one replaceable collaborator is the pricer, through the timelock (`src/FeastEmissions.sol:225`, overview `:146-147`). Rows 1 to 6 sit in code that cannot be patched after mainnet; row 7 can be corrected later with a new pricer.

**Grades.** I keep MEDIUM for rows 1 and 5 and grade rows 2, 3, 4, 6 and 7 LOW; each memo says why.

## CA-33ea5aaf49 — preopen-regime-decided-by-settle-instant

### 1. Trigger

The regime of emission week n is chosen at `src/FeastEmissions.sol:498` by `claimsOpen()` (`:584-587`), which asks whether the platform pool has opened *at the settle instant*, not whether week n closed before the pool opened. The last pre-launch week closes at the window's close: the recipe puts that close on a Monday 00:00 UTC ledger turn (`script/FeastScriptChecks.sol:42-46`, `script/Genesis.s.sol:19`; the fixture asserts the alignment at `test/audit/poc/EmissionsPreLaunchValueCap.t.sol:95-97`), and the pool opens `SETTLE_GRACE = 1 hours` later (`src/FeastGenesis.sol:149`; the derivation is at overview `:305-306`). So the token-cap regime is available for exactly 3,600 s (derived).

Who can cause it:

- **The guardian** (the team multisig, overview `:31`), a privileged role. A freeze live across that hour refuses `settle` (`:267`); after the unfreeze `claimsOpen()` is true. Cheapest form: freeze at close − 1 s, unfreeze at openAt + 1 s; charged = max(held, `MIN_FREEZE_CHARGE`) = 1 h + 2 s of the 168 h budget (`src/FeastGuardian.sol:276-279`, `:102`). PoC: `test/audit/poc/EmissionsRegimeUnderAFreeze.t.sol:80-93`; the red result is written at `:68` (control `tokenCapOnly = true`, frozen `false`, **measured**).
- **Anyone, by omission.** If no keeper calls `settle(n)` inside the hour with every earlier week already settled (`:269`), the outcome is the same with no freeze at all. This is the older settle-instant race v1.6.7 narrowed (`:458-467`), not a new fact.
- **By accident:** a genuine incident freeze around the launch does it with nobody intending it.

Phase: the seam only. It cannot recur; there is one genesis.

### 2. Loss upper bound

`emitted = min(value cap, token cap, remaining)` (`:408`, `:537-538`, `:549`).

- Token cap: `tokenCap(n) = budget × (53 − n) / 1378` (`:247`); `budget = 1e27 × 1420 / 10000 = 1.42e26` wei (`:170`; `src/FeastGenesis.sol:45,82`).
- Value cap: `fees_n × 1500 / 10000 × perNative` (`:522`, `:537`; ratio default `src/FeastGenesis.sol:110`).
- The difference `D(n) = max(0, tokenCap(n) − valueCap_n)` is FEAST not emitted; it stays in `remaining` (`:575`) and burns after week 52 (`:685-693`).

Upper bound, valueCap → 0 (a seam week with almost no fees): **derived**

- n = 2 (the fixture's calendar; **assumed** for production): 1.42e26 × 51 / 1378 = 5,255,442,670,537,010,159,651,669 wei = **5,255,442.67 FEAST**. Its 45% trader pot is 2,364,949.20 FEAST, which P5 **measured** as 2,364,949,201,741,654,571,843,251 wei on the older tag (`audit-pack/rounds/r1/lens/P5-verdict.txt:33`).
- Worst n = 1: 1.42e26 × 52 / 1378 = **5,358,490.57 FEAST**, 0.536% of supply.

Worked number at the tree's PoC inputs (**assumed**: 10 WBNB pot, 100 WBNB of seam-week volume): tranche = 30% of supply = 3e26 (`src/FeastGenesis.sol:67,75`); net = 9.9 WBNB (overview `:341-343`); perNative ≈ 3e26 / 9.9e18 = 30,303,030 FEAST per WBNB; fees ≈ 1 WBNB; valueCap ≈ 0.15 × 30,303,030 = 4,545,454 FEAST; **D ≈ 709,988 FEAST**. At 1 WBNB of volume, the P16 write-up's variant, valueCap ≈ 45,454 FEAST and D ≈ 5,209,988 FEAST; that write-up **measured** trader pots of about 2.37e24 against about 2.0e22 wei (`P16-claude-verdict.txt:31-32`), consistent. D is zero once 0.15 × fees_n × perNative ≥ tokenCap(n), about 116 WBNB of seam-week volume at that clearing price (derived).

No balance is taken from anyone. A promised emission is withheld and later burned.

### 3. Who bears it

The seam week's traders (45%), referrers (40%) and creators (15%) (`src/FeastGenesis.sol:123-125`): trader, referrer and creator categories. Gain: every FEAST holder pro rata through the week-52 burn, the team's vested 25% included. Platform gains, diffusely.

### 4. Fix cost

Key the regime on the week's close against the pool's `openAt`, not on the settle instant. `FeastEmissions.settle`, about 3 lines replacing `:498`:

```solidity
FeastHook.Pool memory pp = hook.poolInfo(platformPoolId);
bool preLaunch = pp.coin == address(0) || closesAt < pp.openAt; // the week closed before the pool opened
if (preLaunch) {                                                 // was: if (!claimsOpen())
```

No storage, ABI, event or script change; `claimsOpen()` stays for the claim paths. Runtime bytes: **+40 to +90 of 10,897** (rough; `claimsOpen()` already copies `poolInfo`, so no new external call). Tests: `test/FeastEmissions.t.sol:333-350` asserts a week that closed before launch and settles after it takes the value cap and first reverts `PlatformUnpriceable`; both flip and the witness is rewritten. Helpers that settle pre-launch weeks after launch (`test/FeastEmissions.t.sol:296-302`, `test/FeastPackageTwo.t.sol:169-173`) keep passing. The two skipped PoCs (`EmissionsRegimeUnderAFreeze.t.sol:36,70`) un-skip and go green. One new mutant (drop the `closesAt < openAt` clause). The comment at `:479-497` is rewritten, which is row 2. Process cost as above, one contract.

### 5. Side effects

- P13's "keyed on the launch state" (`audit/invariants.yaml:106-130`; docstring `:33-37`) becomes exactly true; the P15 witness is rewritten; P14 unchanged. `audit/guardian-reads.allow:32-33` unchanged, no new guardian read. No swap-path gas.
- The `Moved && !graceOver` refusal at `:503` now also holds a pre-launch week settled after launch; delay only, at most three open days.
- Weeks that closed before `openAt` but settle after it now emit the full token cap even when fees were tiny. That is the written rule (Q25) and pays fee-payers more; it cannot exceed the budget (`:549`).
- Regression risk, both ways: `audit-pack/notes.md:5` records five consecutive releases with a defect in their own fix, and the v1.6.15 attempt on this exact seam was "written, measured and removed" (`:483-489`). A predicate change with witnesses already standing on both sides is the least risky shape a fix here can take; it is still a delta the firm gets two days for. Leaving it means a 5.26M-FEAST decision rides on a one-hour keeper race, for ever.

### 6. Recommendation

**Recommendation:** FIX BEFORE MAINNET. A three-line predicate change removes a regime decision worth up to 5,255,443 FEAST from a one-hour keeper race and from one hour of the guardian's budget, in code that cannot be patched after 2026-10-06. What would change it: an owner ruling that the seam week should take the value cap whenever a price exists, reversing Q25, in which case accept and rewrite the docstring at `:33-37`.

Grade: MEDIUM, kept.

## CA-2d81ea2290 — false-three-day-protection

### 1. Trigger

The comment at `src/FeastEmissions.sol:491-497` says the regime "is decided at least three open days later, with the pool live and the price tested". After `openAt` the code takes the value cap the moment the platform price is `Ok` (`:505`). The only waits are `TWAP_WINDOW = 600` s of open time since the last unfreeze (`:451-457`; `src/FeastConstants.sol:201`) and `MIN_OBSERVATION_AGE = 300` s of oracle history (`src/FeastPricer.sol:166`; `src/FeastConstants.sol:204`). `graceOver` (`:318`) is consulted only for an `Unpriceable` quote (`:393`) and for a `Moved` price before launch (`:503`). No role; anyone may settle; the same seam as row 1; once.

### 2. Loss upper bound

No balance moves. The promise, in seconds: `PRICING_GRACE = 3 days = 259,200` (`src/FeastGenesis.sol:131`); `settle(2)` succeeded 901 open seconds after the unfreeze (**measured**, `test/audit/poc/EmissionsRegimeUnderAFreeze.t.sol:34,55`), so the promise is short by 258,299 s; the least the code enforces is 600 s, so by 258,600 s at the minimum (derived). The FEAST at stake is row 1's D(n) and is not counted twice.

### 3. Who bears it

The owner. The acceptance basis for row 1 rests on a protection that does not exist, in source the firm is reading.

### 4. Fix cost

Rewrite `:479-497` to say what the code does; if row 1 is fixed, the residue paragraph is deleted with it. About ten comment lines, **0 runtime bytes**: the build uses `bytecode_hash: none` and no CBOR metadata (`audit-pack/bytecode.md:3`), so the runtime hash does not move, though the source the firm holds does, which still means a new tag. The alternative that makes the comment true, adding `if (!graceOver) revert` to the value-cap branch at `:505`, is one line and about +20 bytes, but it delays every post-launch week by three days and flips `test/audit/poc/FreezeRunsTheSettlementClocks.t.sol:124-130` and `:228-230` and `test/FeastEmissions.t.sol:260-282`. Not recommended.

### 5. Side effects

None in code. `plans/audit/freeze-clock-sweep.md:342` carries the same sentence and should change with it.

### 6. Recommendation

**Recommendation:** FIX BEFORE MAINNET. It is a comment change that rides in row 1's delta, or stands alone at zero bytecode cost if row 1 is accepted; a false justification in audited source has no upside. What would change it: nothing.

Grade: LOW. A documentation defect; its economic content is row 1's.

## CA-7da18d1e43 — own-brake-extends-own-window

### 1. Trigger

The team multisig, which holds both `freeze` (`src/FeastGuardian.sol:221`) and `assignPartner` (`src/FeastGenesisGrants.sol:158-160`). `assignPartner` refuses only after `guardian.sunsetAt()` (`:164-165`), which returns `started + 90 days + frozenSeconds()` (`src/FeastGuardian.sol:462`), and it is not frozen: no `_requireUnfrozen` in `:158-177`, by decision (`tools/check-boundaries.py:432-437`). Frozen time therefore extends a window in which no assignment was ever refused. Phase: the first 90 days after genesis. **Measured**: freeze at day 89 (72 h grant, `:256`), assign at day 91 succeeds, `sunsetAt() = g0 + 90 days + 172,800 = 1800144000` (`test/audit/poc/GuardianWindowExtension.t.sol:23,31-41`). By accident: any incident freeze in the 90 days extends the window. Recurs with every freeze, up to the budget.

### 2. Loss upper bound

No balance moves. Extension ≤ `FREEZE_BUDGET = 168 hours = 604,800 s` (`src/FeastGuardian.sol:70`), because every grant is charged in full (`:259`), only the tail above the charge is refunded (`:276-280`), and `_fold` counts only seconds actually frozen (`:343`); so the window ends at day 97 at the latest (derived).

FEAST whose destination can change: an empty slot that should burn at day 90 (`burnUnfilledSlot`, `:195-209`) can instead be named through day 97. One grant = 1e27 × 10 / 10000 = 1e24 wei = **1,000,000 FEAST** (`src/FeastGenesisGrants.sol:102`; `src/FeastGenesis.sol:138`); eight slots = 8,000,000 FEAST, 0.8% of supply, the theoretical ceiling (derived). Realistic: the number of slots still empty at day 90 (**assumed**; a deployment choice) × 1e24. A partner named that late still unlocks only `min(grant, grant × referred / TARGET)` over emission weeks ≤ 26 (`:279-283`, `:214`), with weeks closed before assignment counting zero (`:235-240`); by day 90 to 97 about 13 of the 26 weeks are gone. Each hour of extension costs the multisig an hour of the brake's own emergency budget.

### 3. Who bears it

FEAST holders (platform), as a burn day 90 would have forced may not happen. Gain: the multisig, in time, and a late-named partner, up to 1e24 FEAST if earned. Partner category.

### 4. Fix cost

One line in `FeastGuardian.sunsetAt` (`:462`): drop `+ frozenSeconds()`, so the window is wall time from genesis exactly as the freeze power already is (`:223`):

```solidity
return started == 0 ? type(uint64).max : started + GUARDIAN_SUNSET;
```

Closes rows 3 and 4 together; this is the combined cost. No storage, ABI, event or script change; `src/IFeastGuardian.sol:47` unchanged. Runtime bytes: **about −20 to −40 of 20,772** (rough; it removes an internal call). Tests: nothing green today asserts the extension. `test/FeastGuardian.t.sol:173-192`, `:196-209`, `:257-264`, `test/FeastPackageTwo.t.sol:255-267`, `:337-368` and `test/audit/poc/GuardianClockStartsAtGenesis.t.sol:49-53` all read `sunsetAt()` with no freeze folded before it, so they pass unchanged; the two skipped PoCs go green. Docstring `:455-461`, `plans/audit/guardian-design.md:334` and `plans/audit/freeze-clock-sweep.md:57` are rewritten to match `plans/audit/guardian-design.md:262` and `tools/check-boundaries.py:435-436`, which already say a freeze cannot extend this window. `tools/mutate.py` has no anchor on `:462` (its `:1750` anchor is the wall-time check in `freeze`); add one mutant, caught by the un-skipped PoCs. `FeastGuardian` is not in the pin list, so the operator adds its hash.

The alternative that keeps the extension, `_requireUnfrozen()` at the top of `assignPartner` (one line, about +30 bytes of 18,542), makes frozen time "time in which a slot cannot be filled" as the docstring claims, but leaves the window at up to 97 days. It also satisfies the PoC as written, which assigns during the live freeze, without closing the extension: the multisig unfreezes first, then assigns.

### 5. Side effects

P30's "only inside the guardian's own 90-day window" (`audit/invariants.yaml:470-486`) becomes exact; P28 unchanged, the freeze power was already wall time. `burnUnfilledSlot` opens at day 90 sharp; it is frozen (`:196`) so a live freeze can delay it, but it has no deadline to miss. The design sentence "the windows others act inside are extended by frozen time" (`plans/audit/guardian-design.md:334`) is dropped, correctly, since no assignment is ever refused by a freeze. Regression risk: the guardian is on its seventh iteration (`src/FeastGuardian.sol:146-163`, `:227-247`) and each round found a defect in the last fix; this change deletes a term rather than adding logic, and the deleted term has no green witness. Leaving it means three documents the firm reads contradict the view that runs.

### 6. Recommendation

**Recommendation:** FIX BEFORE MAINNET. One line, negative bytes, closes two rows and three contradicting documents at once. What would change it: an owner ruling that the window really is meant to grow with downtime, in which case add `_requireUnfrozen()` to `assignPartner` and the row-4 checkpoint instead, and rewrite `:262` and the tool comment.

Grade: LOW. Bounded at seven days, no balance moves, the grant still has to be earned, and it costs the brake's own budget.

## CA-7dca95d8e3 — sunset-unanchored-prefreeze

### 1. Trigger

Any freeze before genesis. `freeze()` skips the sunset check while `genesisStartedAt == 0` (`src/FeastGuardian.sol:222-225`), `startClock` records only the instant (`:194-199`), so `frozenSeconds()` at genesis already carries pre-genesis time and `sunsetAt` adds all of it (`:462`). Guardian role; phase: before genesis. **Measured**: one 72 h freeze that lapsed and was settled reads `sunsetAt() = 1800230400` against `g0 + 90 days = 1799971200`, exactly 259,200 s (`test/audit/poc/GuardianWindowExtension.t.sol:47,51-60`). By accident: a rehearsal or a real pre-launch incident. Recurs up to the budget.

### 2. Loss upper bound

Same units as row 3. Extension ≤ 604,800 s (derived, `:70`); the budget is lifetime, so rows 3 and 4 share one bound, and a budget spent before genesis leaves nothing for row 3. FEAST bound as row 3: ≤ 1e24 per empty slot, ≤ 8e24 in all. No balance moves.

### 3. Who bears it

As row 3.

### 4. Fix cost

The one-line wall-time change in row 3 closes this row too; the combined cost is given there. Alone: a checkpoint, a new `uint64` written in `startClock` (`:197`) and subtracted in `sunsetAt`; about 3 lines. Storage: slot 0 holds 25 bytes today (`:59`, `:105`, `:107`, `:118`), so the field opens a new slot; harmless, nothing is deployed. Runtime bytes: about +60 to +100 of 20,772 (rough). Same document updates as row 3.

### 5. Side effects

As row 3. The alone-fix keeps the post-genesis extension, and therefore row 3.

### 6. Recommendation

**Recommendation:** FIX BEFORE MAINNET, by the same one line as row 3. What would change it: an owner ruling that keeps the downtime extension, in which case the checkpoint is the fix.

Grade: LOW, for row 3's reasons.

## CA-407dffa3a4 — shared-origin-capture

### 1. Trigger

Anyone. Sequence (PoC `test/audit/poc/SharedOriginCapture.t.sol:51-58`; red result at `:39-40`, **measured**): a user operation submitted through bundler B, so `tx.origin = B`, swaps dust on any feast pool with 64-byte `hookData` naming referrer A and wallet B (`src/FeastHook.sol:503-506`). In `_referrerFor` B has no binding (`:586-587`), A ≠ B (`:597`), A is not the burn address (`:608`), A ≠ wallet (`:612`), wallet == origin (`:615`), so `_referrerOf[B] = A` (`:617-619`). From then on every trade through B pays A, `hookData` unread (`:586-587`), and credits A's referred track with the whole fee (`:1818-1824`). What must be true: B is unbound; the trade is served; the fee rounds to at least one unit. No privileged role. Any time after any pool opens. Recurs once per origin and is permanent: there is no rebinding (`:586`, overview `:278`). By accident: yes, an account-abstraction app that fills the wallet word with the transaction signer binds its own bundler to its own referrer.

### 2. Loss upper bound

Per unit of volume V routed through the captured origin, in the quote asset:

- **Commission.** fee = V × 10,000 / 1,000,000 = 1% of the quote leg (`src/FeastConstants.sol:12-13`); commission = fee × `referrerBps` / 10,000 (`:1847`); `referrerBps ≤ MAX_REFERRER_BPS = 3,000` (`:68`), so **≤ 30 bps of V**; at the default 1,000 (`:67`) and on the platform pool (`src/FeastGenesis.sol:90`), 10 bps (derived). **Measured**, two 1,000e18 exact-in buys on the fixture's 10% pool: A holds 1,980,198,019,801,980,198 where an uncaptured origin gives 990,099,009,900,990,099; the KOL holds 0 instead of 990,099,009,900,990,099 (`HK23-claude-verdict.txt:30-35`; PoC `:57-58`).
- **Referred track.** 100 bps of V per trade credited to A (**measured** 19,801,980,198,019,801,980 against 9,900,990,099,009,900,990). A's share of week n's referrer pot is A's referred value over the week's total (`src/FeastEmissions.sol:400`, `:620`); the pot is cap × 4,000 / 10,000 in weeks 1 to 8 and 2,000 after (`:558`; `src/FeastGenesis.sol:123,126`), so ≤ 0.4 × tokenCap(n): **2,143,396 FEAST in week 1, 2,102,177 in week 2** (derived). If A is also a partner, `referredNative` grows by the same (`src/FeastGenesisGrants.sol:237-239`) toward a 1e24 grant.
- **Worked** (**assumed**: 1,000 WBNB per week through one captured bundler, the default 10% referrer share, that origin carrying 10% of the week's referred fees, week 2 under the token cap): commission 1 WBNB per week; pot share 0.10 × 2,102,177 = 210,218 FEAST per week.

### 3. Who bears it

Per-trade referrers (KOLs) named by users behind the origin: referrer category. Creators, when the user named nobody: the commission then comes out of the creator's remainder (`:1855`; pinned by `test/FeastReferrerBinding.t.sol:473-485`): creator category. On the platform pool the creator is the burn address, so it comes out of the self-burn (`:1860-1863`): FEAST holders. Honest referrers everywhere are diluted in the weekly pot. Gain: the attacker.

### 4. Fix cost

The smallest fix that keeps the lifetime binding: bind by a direct call in which the wallet is `msg.sender`, and make the 64-byte form per-trade only. In `FeastHook`, about ten new lines plus replacing `:615-619` with `return named;`:

```solidity
function bindReferrer(address referrer) external {
    if (referrer == address(0) || referrer == msg.sender || referrer == FeastConstants.BURN_ADDRESS) revert NotAReferrer();
    if (_referrerOf[msg.sender] != address(0)) revert AlreadyBound();
    _referrerOf[msg.sender] = referrer;
    emit ReferrerBound(msg.sender, referrer, PoolId.wrap(0));
}
```

ABI: one new function and two errors; storage (`:250`) and the event (`:126`) unchanged; scripts unchanged. Runtime bytes: +130 to +200 for the function, −50 to −80 for the removed write, **net +60 to +160 of 246**. Rough, and this contract's estimates have missed before: a helper emitted twice cost 343 bytes of 129 free (`:568-569`). Measure before deciding. Tests: every test in `test/FeastReferrerBinding.t.sol` that binds through a trade (for example `:201-202`) moves to the direct call; the gas constant at `:663` changes; `docs/referrer-binding.md:96-98,203-209` and `docs/interface.md:220-222` are rewritten; the guarded table in `tools/check-boundaries.py` and `docs/site-census.md` gain a row; mutation anchors on `:615-619` are re-targeted; the skipped PoC goes green. Swap-path gas falls slightly, since no SSTORE or emit is reachable from a swap any more.

Fallback if the bytes do not fit: delete `:617-619` only, so the 64-byte form never binds. About 3 lines, −50 to −80 bytes, ABI unchanged, but the lifetime-binding feature is gone and `test/FeastReferrerBinding.t.sol` loses its subject.

### 5. Side effects

P4 (self-referral) unchanged, `:597` stays. `stranger-binds-nontrader`, the accepted LOW (`audit-pack/notes.md:168-172`), closes too, since a contract can no longer bind the EOA that called it. The declared row at `docs/referrer-binding.md:203-209` becomes true. A smart account could now bind itself by calling `bindReferrer`, but its trades still read `_referrerOf[tx.origin]` (`:582-586`); the read side is unchanged, a limitation rather than a regression. Regression risk: the hook is the swap path and the largest contract (24,330 bytes, `audit-pack/bytecode.md:9`); the change touches one mapping and one branch, but a hook delta is the costliest one for the firm to re-review. Leaving it means the capture is permanent per origin on an immutable contract.

### 6. Recommendation

**Recommendation:** FIX BEFORE MAINNET, if the measured net addition fits the 246 bytes. The hook is immutable, a captured origin stays captured for life, and the fix is local to one mapping. What would change it: a measured byte overrun, or an owner ruling that account-abstraction volume is out of scope at launch, in which case ACCEPT with this mitigation: bundler operators pre-bind each signing EOA to an address of their own through one dust trade (only self and the burn address are refused, `:597`, `:608`), and `docs/interface.md:220-222` is corrected to say a bundler's EOA is bound by the first user to name it.

Grade: MEDIUM, kept.

## CA-4e08c595d3 — floor-sale-misses-price-rise

### 1. Trigger

Any taker, any time after the sink opens; needs an earlier raising sale and enough time that the floor, with its 24 h half-life (`src/FeastGenesis.sol:174`), exceeds the descent, with its 1 h half-life (`:164`). PoC (`test/audit/poc/FloorSalePriceRise.t.sol:38-54`), reproduced from the code: open at 2^192 (`src/FeastGenesis.sol:167`; `src/FeastPlatformSink.sol:288`); 64 h later the price is 2^128 (`:333-334`); take 50e18 of 100e18, cost 50e18 FEAST, anchor 3 × 2^191 (`:602-605`), `floorBase = 2^127` (`:653-655`), floor 2^121 (`:386`); 24 h later the descent is 3 × 2^103 and the floor 2^120 (`:406-413`), so the published price is 2^120 (`:340`, `:418-421`). Take 25e18 of 50e18: anchor 9 × 2^190 (**measured** 1.5×, `:63-67`); candidate floor 2^119 >> 6 = 2^113 < 2^120 (`:654`), so the published price stays 2^120 (**measured**, `:27`). A sale executed at the floor can never raise it: the candidate is floor × f, and (floor × f) >> 6 > floor needs f > 64. Ordinary operation; no role; recurs on every lot after every real sale.

### 2. Loss upper bound

FEAST not burned relative to the docstring's "re-anchors the price at price × (1 + f)" (`:58-60`; P19 at `audit/invariants.yaml:180-182`): on the next take of `amountOut` at floor p after a sale of share f, `f × p × amountOut / 2^128`. **Measured**: 25e18 × 2^120 / 2^128 = 97,656,250,000,000,000 wei paid (`:476`) against 146,484,375,000,000,000 under 1.5×, a shortfall of **48,828,125,000,000,000 wei (0.0488 FEAST)** on the fixture's synthetic lot. Relative: f / (1 + f) ≤ 50% of the promised burn for one take (derived). A chain of takes compounds without bound in the limit: the anchor's own docstring notes twelve half-lot takes give 129× (`:149-151`), which is why `ANCHOR_CEILING` exists (`:168`). Against what the tree already permits the bound is **zero**: one call may take the whole remaining lot at the same floor price (`:431`; the price is fixed at `:436` before the take), so no sequence extracts more than a single call could.

### 3. Who bears it

Platform, as FEAST holders: fewer FEAST are burned than a compounding rule would burn. Gain: the subsequent taker. Nobody is deprived of a balance.

### 4. Fix cost

Smallest: documentation. Restate `:58-60` and P19's clause as "a sale raises the descent curve; while the standing floor exceeds the curve, the quote is the floor". 0 runtime bytes. The code alternative lifts `floorBase` by (1 + f) when a sale executes at the floor (`price == _floorNow(lot)`): about 6 to 10 lines in `take` after `:653`, +100 to +200 of 18,437 (rough). It reopens the round-4 weighting and the v1.6.3 no-lowering, no-restart rule (`:614-623`), re-derives the chord-gap witnesses (P19 witnesses at `audit/invariants.yaml:228-233`), and creates a floor that compounds: a chain of floor sales pins the platform's inventory above market for days, since a floor raised 2^k needs k days to decay.

### 5. Side effects

Of the code alternative: P19's floor clauses, `test_afterASaleThePriceStopsAtItsFloor`, `test_aTakeThatDoesNotRaiseTheFloorLeavesItAndItsClockExactlyWhereTheyWere` and the fuzzes change; the sink is the contract with the five-release fix-defect history (`audit-pack/notes.md:11-36`), and v1.6.20's first draft broke a v1.6.2 property (`:26-31`). No swap-path gas either way.

### 6. Recommendation

**Recommendation:** ACCEPT, with the docstring at `:58-60` restated so the firm reads the floor as designed. No value moves beyond a one-call whole-lot take the sink already permits, and every code alternative reopens floor rules that took four rounds to settle. What would change it: a ruling that the floor must compound with sales, which is a redesign needing its own round, not a delta.

Grade: LOW.

## CA-2fbb35d7a1 — hop-rounding-amplification

### 1. Trigger

Nobody. `priceQ128` floors each hop's ratio in `_ratioQ128` (`src/FeastPricer.sol:269-273`: rising s² / 2^64, reciprocal 2^320 / s²) and floors once more when composing (`:144`). Routes are pinned at construction (`:90-108`), at most two hops (`:55`), and a hop is refused unless spot sits within 300 ticks of its own average (`:236`), so the understatement is a static property of the pinned pools' prices. Read at settlement only (`src/FeastEmissions.sol:345`) and through it by the grants (`src/FeastGenesisGrants.sol:237-239`). Not by the converter: it holds no pricer reference, so `audit-pack/notes.md:163` overstates the reach.

### 2. Loss upper bound

Direction: always at or below the true price, since every step floors. Fewer FEAST are emitted (`src/FeastEmissions.sol:537-538`), less unlocks (`src/FeastGenesisGrants.sol:279-283`), and the shortfall burns (`src/FeastEmissions.sol:685-693`).

Magnitude, **measured**: 11.111% on the lens's synthetic route (expected 2^128 = 340,282,366,920,938,463,463,374,607,431,768,211,456, read 302,473,215,040,834,189,745,221,873,272,682,854,627, exactly 8/9; `audit-pack/notes.md:165-166`, with a middle token at `address(type(uint160).max)` per the row's reason in `audit-pack/findings.json`). My reading gives a larger supremum, stated as the rules ask: per hop the relative error is below 1/r for a rising hop and below 2/r for a reciprocal hop, r being the hop's ratio in raw Q128 units. At the venue's stored-price floor `MIN_SQRT_RATIO` (`:215-217`) r = ⌊1.000075⌋ = 1, and any s below 2^32.5 gives r in [1, 2), so one hop can be understated by just under 50% (a true 1.999 floors to 1); the 8/9 is one point on that curve, r = 8 (derived). Reaching it needs a pool priced under 2^-127 token per token. For any listed 18-decimal route (`:88`, `:105`) at a price above 1e-12 WBNB per token, r ≥ 1e-12 × 2^128 ≈ 3.4e26 and the understatement is below 6e-27 (derived): in FEAST, at most 6e-27 × tokenCap(1) ≈ 0.03 wei per week.

### 3. Who bears it

Emissions claimants (trader, referrer, creator categories) and partners, negligibly; FEAST holders gain the burn. Conservative.

### 4. Fix cost

Compose the square-root prices in 512 bits before flooring, multiplying the two hops' factors and dividing once: about 15 to 25 lines across `priceQ128` and `_ratioQ128`, +150 to +300 of 20,137 (rough). No storage, ABI, event or script change; Package 2, not yet deployed. Tests: `FeastPricerTest` in `test/FeastPackageTwo.t.sol`; the two-hop witnesses in `test/FeastEmissions.t.sol:356-361`, whose overflow boundary at `1 << 136` moves; the v1.6.6 Q2 boundary witnesses (`docs/plan.md:2006-2007`, `:2025`); mutation anchors on `FeastPricer`. A post-mainnet path exists: a new pricer through `setPricer` (`src/FeastEmissions.sol:225`), effective from the next settlement.

### 5. Side effects

512-bit boundary arithmetic is exactly where the v1.6.6 fix and its witnesses were found wrong twice (`docs/plan.md:2006-2007`, `:2025`). P13's "every division on the value-cap path floors" (`audit/invariants.yaml:114`) is preserved either way. No swap-path gas.

### 6. Recommendation

**Recommendation:** ACCEPT. The direction is conservative, the magnitude is below 1e-20 on any real route, and it is the only row with a post-mainnet fix path. What would change it: a listed quote whose pinned route passes through a pool priced near the venue's floor, which cannot happen while every quote is 18-decimal and priced in WBNB.

Grade: LOW.

## Observations outside the seven

- `src/FeastEmissions.sol:503`: a pre-launch week is refused `PlatformPriceMoved` inside the grace although the token-cap branch never uses the price; delay only, at most three open days.
- `audit-pack/findings.md:119-129`: every `status_reason` cell in the markdown ledger is cut mid-sentence (`:119` ends at "changed which r"); `audit-pack/findings.json:4328` and its siblings carry the full text, and the firm reads the markdown.

VERDICT: HIGH=0 MEDIUM=2 LOW=5