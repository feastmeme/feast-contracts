// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

/// The sealed unit's runtime bytecode, pinned.
///
/// v1.6 is sealed as one unit and handed to one external audit (Q28). Every
/// deployable contract is immutable code (Q26), so what the auditor reads must
/// be what deploys: each artifact's runtime code (immutables appear as zero
/// placeholders, and the build carries no metadata hash) must hash to the value
/// recorded at the seal, in `docs/audit-briefs/v16-unit.md`. No genesis
/// placeholder compiles into runtime code — they all enter by constructor
/// argument — so setting them for the deployment changes none of these bytes.
/// Changing a contract after the seal means changing this file too, visibly.
///
/// Re-pinned at `v1.6.1-internal`: the pre-audit pass changed four of them —
/// `FeastHook` (the fill's venue-delta bound), and `FeastOracle`,
/// `FeastConverter` and `FeastPricer` (the 2106 timestamp arithmetic). The
/// other twelve are byte-identical to `v1.6-internal`.
///
/// Re-pinned again at `v1.6.2-internal` for `FeastPlatformSink` (the descent's
/// clock) and `FeastHook` (an immutable, not the code's shape).
///
/// And at `v1.6.3-internal` for the three the dual-family pack's four findings
/// reached: `FeastPlatformSink` 5,551 -> 5,610 (the safe re-anchor, and the
/// floor's maximum rule), `FeastEmissions` 13,522 -> 13,958 (the settled week's
/// quote list, snapshotted), `FeastConverter` 7,307 -> 8,266 (every leg of a
/// conversion measured, after round 1). The other thirteen are untouched.
///
/// Re-pinned at `v1.6.4-internal` for SEVEN, which is what it costs to close a
/// shape everywhere it occurs rather than only where the lens pointed:
///   - `FeastGenesisGrants` 3,893 -> 4,099  (G1: the minimum established before
///     the multiply, not after it)
///   - `FeastPlatformSink`  5,610 -> 6,018  (G2: the schedule's two-ended bound;
///     and the sweep's two decay steps)
///   - `FeastHook`         22,783 -> 23,975 (G3: the price limit derived from the
///     tolerance; the sweep's allowance rows; and round r1's narrowing of the
///     swap amount before it is multiplied by the fee)
///   - `FeastConverter`     8,266 -> 9,313  (G3 swept here: the identical limit)
///   - `FeastFactory`      16,009 -> 16,088 (the sweep's `MAX_SUPPLY` refusal)
///   - `FeastEmissions`    13,958 -> 14,052 (the sweep's value-cap row)
///   - `FeastLaunchWindow`  7,522 -> 7,694  (the sweep's pro-rata row)
/// The other nine are byte-identical to `v1.6.3-internal`. `FeastHook` is now
/// 23,975 bytes against the EIP-170 limit of 24,576: 601 bytes of headroom.
/// Round r1 of this pass's own lens added the venue-bounds clamp inside
/// `FeastMath.sqrtPriceLimit`, which both the hook and the converter inline.
///
/// Re-pinned at `v1.6.9-internal` for ONE — the allocation the owner ruled on
/// 2026-09-16 and ordered into the contracts on 2026-09-18, 60 / 25 / 14.2 /
/// 0.8 in place of 65 / 20 / 14.2 / 0.8:
///   - `FeastFactory`      16,088 -> 16,088 (the SIZE is unchanged, the HASH is
///     not, and nothing about the contract's shape moved)
/// The other fifteen are byte-identical to `v1.6.8-internal`, `FeastHook`
/// included — so its 129 bytes of headroom stand exactly as v1.6.8 left them.
///
/// **What actually moved inside the factory.** This paragraph is on its third
/// spelling; the r1b and r2b endorsement rounds refused the first two, and the
/// corrections are kept visible because the seal receipt cites this note.
///
/// The genesis allocation RATIOS do not appear in runtime code — `via_ir` folds
/// each into the token AMOUNT it produces. That is true of the four allocation
/// shares only: other basis-point constants in this same contract DO survive as
/// operands, because they are passed on or compared rather than divided by.
/// `PUSH2 0x03e8` appears twice, both `PLATFORM_REFERRER_BPS` (the `registerPool`
/// argument and the `CoinCreated` field). `PUSH2 0x07d0` appears four times and
/// is NOT one constant — an earlier spelling of this note said it was all
/// `PLATFORM_SELF_BURN_BPS`, and r3b corrected that. Two are that constant, in
/// the same two places; the other two are `MAX_CREATOR_ALLOCATION_BPS`, which
/// is `public` (so it has a getter) and is compared against in `create`. Both
/// constants are 2_000, and an operand value is not a consumer.
///
/// Two of the folded amounts changed, and each has its OWN cause:
///
///     the team's amount   `PUSH11`  200_000_000e18 -> 250_000_000e18   TEAM_BPS
///     the pool's amount   `PUSH12`  650_000_000e18 -> 600_000_000e18   POOL_BPS
///
/// The pool's amount is written as the remainder, `supply - team - grants -
/// emissions`, but substituting the derived `EMISSIONS_BPS` into it collapses
/// the whole expression to `supply * POOL_BPS / BPS`, exactly, at a supply this
/// divisible. So `POOL_BPS` drives that operand directly. An earlier spelling
/// said both operands moved "because `TEAM_BPS` moved"; that is false, and so
/// was the claim before it that `POOL_BPS` reaches no runtime byte.
///
/// What the PAIRED change buys is the third amount staying still:
///
///     6_500 / 2_000  (v1.6.8)   pool 650m   team 200m   emissions 142m
///     6_500 / 2_500  team only  pool 650m   team 250m   emissions  92m
///     6_000 / 2_000  pool only  pool 600m   team 200m   emissions 192m
///     6_000 / 2_500  shipped    pool 600m   team 250m   emissions 142m
///
/// Either share moved alone would have taken emissions off 14.2%. Moved
/// together they cancel in `EMISSIONS_BPS`, which is why the grants and
/// emissions operands are byte-identical and why fifteen of the sixteen
/// contracts did not notice. The size holds because both changed operands keep
/// their widths: 11 and 12 bytes before and after.
///
/// A wrong `POOL_BPS` is caught by the balances, not only by the constants:
/// `POOL_BPS = 6_001` fails
/// `test_theSplitIsSixtyTwentyFiveFifteenToTheUnit` on the emissions balance
/// (141_900_000e18 against 142_000_000e18).
///
/// Re-pinned at `v1.6.8-internal` for ONE — the lifetime referrer binding:
///   - `FeastHook`         24,133 -> 24,447 (+314: one mapping, one getter, one
///     event, the parser widened to a second `hookData` form, and `_referrerFor`
///     — the binding's only entry. `docs/referrer-binding.md`.)
/// The other fifteen are byte-identical to `v1.6.7-internal`.
///
/// **Headroom against EIP-170 falls 443 -> 129 bytes.** That is the number to
/// read before proposing anything else for this contract: the hook is 24,447 of
/// 24,576 and the next change has 129 bytes to fit in. It is not a defect and
/// nothing is over the limit, but it is the tightest this unit has ever been and
/// it should be a decision rather than a discovery.
///
/// Re-pinned at `v1.6.7-internal` for THREE, the pack's own findings:
///   - `FeastHook`         23,975 -> 24,133 (a claim on a wrapped-native-quoted
///     pool is paid directly; the converter has no route for that input.
///     `_claimTo` now returns what it released, which made the fix one line and
///     is a better number than a balance delta - it is what the ledger was
///     debited by. **Headroom against EIP-170 falls 601 -> 443 bytes.**)
///   - `FeastEmissions`    14,490 -> 14,438 (the first-week rule keyed on the
///     LAUNCH STATE, as its docstring always said, instead of on whether a price
///     happened to exist. It SHRANK 52 bytes: asking `claimsOpen()` once, first,
///     replaces two later tests of it.)
///   - `FeastOracle`       2,859 -> 2888 (`consult` floors the WINDOW, not only
///     the history, which is what its own sentence always said)
/// The other thirteen are byte-identical to `v1.6.6-internal`.
///
/// Re-pinned at `v1.6.6-internal` for THREE — the sibling contracts the v1.6.5
/// sweep measured and the coordinator ruled closed (Q2, Q3, Q8):
///   - `FeastPricer`        5,510 -> 5,578  (Q2: a square-root price outside the
///     venue's own STORED-price range `[MIN, MAX)` is `Unpriceable` rather than
///     a panic, in both readers — round 1's verifier corrected the first
///     spelling, which excluded a minimum the venue itself admits)
///   - `FeastPlatformSink`  6,018 -> 6,257  (Q3: a cost no word can hold is
///     `CostAboveLimit`, guarded on the ROUNDING and not only on the floor)
///   - `FeastConverter`     9,313 -> 9,303  (Q8: a hop expectation too large to
///     hold is `RouteExpectationTooLarge` — and it SHRANK ten bytes, because
///     the two guarded steps share one internal function where the inlined
///     `mulDiv` pairs did not)
/// The other thirteen are byte-identical to `v1.6.5-internal`.
///
/// Re-pinned at `v1.6.5-internal` for ONE, which is what it costs to close two
/// findings in one function:
///   - `FeastEmissions`    14,052 -> 14,490 (F1: the minimum established before
///     the value cap is multiplied out, in the pricer's own `mul512` idiom;
///     F2: the listed quote's `Moved` refused by name, as the platform coin's
///     `Moved` already was, and refused only for a quote that carries fees,
///     which is the reach the platform branch has — round 1, r1v)
/// The other fifteen are byte-identical to `v1.6.4-internal` — including
/// `FeastPricer` and `FeastPlatformSink`, whose v1.6.5 sweep rows are recorded
/// in comments and carry no code yet.
/// Re-pinned at `v1.6.10-internal` for the creator's PRE-BUY, the owner's
/// feature of 2026-09-19 20:1x: `FeastHook` 22,155 -> 22,331 (+176, the
/// transient marker, the structural predicate and the cap skip) and
/// `FeastFactory` 14,857 -> 17,258 (+2,401, the factory's first `lockAcquired`,
/// the swap, its own settle/take path, the bound, the event and the view).
/// Margins after: the hook 2,167, the factory 7,318. Nothing else moved.
///
/// Re-pinned once more at `v1.6.10-internal` for `FeastFactory` alone,
/// 14,640 -> 14,857 (+217), for the two genesis fixes the v1.6.10 diff round
/// found: the launch window's close is bounded to a sane instant, and the
/// platform pool's gate is DERIVED from that close instead of registered from
/// whatever the genesis key passed. Both remove a number a human types into a
/// blind-signed transaction. `FeastHook` is untouched by them and stays at
/// 22,155 with 2,421 to spare.
///
/// Re-pinned again at `v1.6.10-internal`, and this time for FIFTEEN of the
/// sixteen — because `optimizer_runs` moved from 20 000 to 1 000 (owner,
/// 2026-09-19) and the compiler's inlining budget is what every one of these
/// hashes is a function of. **No source byte moved with it.** `FeastHook`
/// 24,659 -> 22,155 is the point of the change: the two v1.6.10 fixes had left
/// it 83 bytes OVER EIP-170 and undeployable, and it now has 2,421 to spare for
/// the external audit's own fixes, bought at +0.9% gas on a plain trade.
///
/// **All sixteen moved**, by 10-22%, `TimelockController` among them
/// (6,693 -> 5,790). An earlier draft of this note claimed the timelock was
/// byte-identical at both settings and reasoned about why. That was wrong, and
/// the way it was wrong is worth leaving here: `vm.getDeployedCode` reads
/// `out/`, and the first measurement was taken when that directory still held
/// the artifact from the previous setting for a contract nothing in `src/`
/// depends on. The hash the pin test then failed on is what caught it. **Re-pin
/// from a `forge build --force`, never from whatever `out/` happens to hold** —
/// the fifteen Feast contracts were recompiled by their own source changes and
/// so were honest by accident, and the one vendored contract was not.
///
/// The Medusa property harness `test/audit/medusa/FeastProperties.sol` is over
/// the EIP-3860 initcode limit at both settings (-89,295 at 20 000, -71,539
/// here) and is not in this table: it is a test harness Medusa deploys in its
/// own EVM, it is not in the audited surface, and it is not shipped.

/// Re-pinned at `v1.6.10-internal` for TWO, the two the ruled fixes reach:
///   - `FeastHook`    24,447 -> 24,659 (+212: the gated pool's cap armed at its
///     first public swap, CA-eeefa2ee72; and the protocol-initiated swap that
///     carries no referrer, CA-0d1fa81d6c)
///   - `FeastFactory` 16,088 -> 16,489 (+401: genesis asks the team wallet when
///     its vesting starts and refuses any answer but the window's close,
///     CA-8ea162587a)
/// The other thirteen are byte-identical to `v1.6.9-internal`.
///
/// (Superseded by the optimizer change above.) **`FeastHook` WAS OVER EIP-170 at
/// 20 000 runs.** 24,659 against the
/// 24,576 limit: a margin of **-83 bytes**. v1.6.9 left 129 bytes of headroom
/// and the two hook fixes need 212. Measured per fix, on this toolchain:
///
///   | build                     | runtime | margin |
///   |---------------------------|---------|--------|
///   | v1.6.9-internal           |  24,447 |   +129 |
///   | + referrer fix only       |  24,553 |    +23 |
///   | + both hook fixes         |  24,659 |    -83 |
///
/// So the referrer fix fits with 23 bytes to spare and the opening-cap fix
/// needs 106 more than remain. `forge test` does not enforce EIP-170 — 516 of
/// 517 tests pass on this tree — so only `forge build --sizes` says so. This
/// pin is recorded, not sealed: the owner rules how to make room, and these
/// two hashes change again when they do.

/// Re-pinned at `v1.6.11-internal` for THREE — the launch window's uniform-price
/// auction, the owner's ruling of 2026-09-19, design
/// `plans/audit/window-auction-design.md`:
///   - `FeastLaunchWindow`  6,832 -> 10,357 (+3,525: the clearing arithmetic in
///     both currency orientations, the two one-sided liquidity formulas, the
///     tick alignment, the fee route and `clearingPrice()`, against the swap and
///     the lock callback it lost)
///   - `FeastHook`         22,409 -> 23,537 (+1,128: `seedAuctionLiquidity` and
///     its two-sided lock branch, the usable-tick helpers, and `_mayInitialize`
///     widened to a gated pool's registered opener)
///   - `FeastFactory`      17,258 -> 18,149 (+891: `seedWindowPool` with its
///     burn of whatever the positions did not take, `platformOpening`, and
///     genesis handing the pool's share to the window instead of seeding it)
/// The other thirteen are byte-identical to `v1.6.10-internal`. Margins after:
/// the hook **1,039**, the factory 6,427, the window 14,219. The hook fits
/// because the fee route stayed OUT of it: the window transfers the pot's 1%
/// straight to the platform sink, which is the same destination
/// `releasePlatformFees` reaches.
///
/// Measured from `forge build --force --sizes`, per the rule two paragraphs up.
///
/// Re-pinned at `v1.6.28` for `FeastHook` alone — AstraSec's two suggestions of
/// 7 October (`docs/audit/v1.6.28-changes.md`):
///   - `FeastHook`         24,541 -> 24,558 (+17: `nonReentrant` moves off
///     `claim` onto `claimCreator`, `claimReferrer` and `releasePlatformFees`;
///     the guard's transient slot is named `REENTRANCY_GUARD_SLOT`, which moved
///     no byte; margin 18)
/// The other seventeen are byte-identical to v1.6.27.
/// `test_theHookIsTheV1628Hook` replaces `test_theHookIsByteIdenticalToV1626`.
///
/// Re-pinned at `v1.6.27` for the r2 delta audit's proven findings, as the owner
/// ruled on 4 October (`docs/audit/v1.6.27-changes.md` has one row per finding):
///   - `FeastFactory`      23,743 -> 23,957 (+214, `CA-344cf3b11c`: the window's
///     seed burns its own remainder — `WINDOW_SHARE` less what the window still
///     holds, less what the seeding placed — never the hook's FEAST balance;
///     margin 619)
///   - `FeastPricer`        4,463 -> 4,403  (-60, `CA-0d9ade0259`: a route pool
///     whose history is shorter than `TWAP_WINDOW` is `Unpriceable`, and the
///     average is always taken over exactly the window; margin 20,173)
///   - `FeastGuardian`      3,804 -> 4,454  (+650, `CA-6b91a230c6`, the owner's
///     ruling of 4 October, option A: the guardian keeps every freeze that has
///     ended — one slot each, at most 168 — and answers `frozenSecondsAt(t)`
///     with no clock read of its own; margin 20,122)
///   - `FeastEmissions`    13,813 -> 13,824 (+11, `CA-6b91a230c6`: a week's
///     pricing grace counts frozen seconds from its close, read from the
///     guardian, in place of the previous week's settlement stamp; margin
///     10,752)
/// The other fourteen are byte-identical to v1.6.26 — `FeastHook` included, at
/// 24,541 bytes with a margin of 35, which `test_theHookIsByteIdenticalToV1626`
/// asserts on its own. The comment corrected in `FeastConstants` moves no byte.
/// Measured on a build of `src/` in a fresh tree, which reproduces every other
/// v1.6.26 pin byte for byte.
///
/// Re-pinned at `v1.6.26` for AstraSec's M-4 of 3 October
/// (`docs/audit/v1.6.26-changes.md` has the row and every byte decision):
///   - `FeastHook`         24,566 -> 24,541 (-25: the lifetime binding moved out
///     to `FeastReferrals` — the mapping, its write, its event and the
///     `referrerOf` view are gone, `_referrerFor` reads
///     `referrals.referrerOf(tx.origin)` spelled in assembly, and the public
///     `referrals` getter is new. The literal port measured 24,887, 311 over;
///     the coordinator's ruling of 4 October dropped the view and then the
///     wallet-word lookup, in that order, and the Solidity call measured 26
///     over without the assembly; margin 35)
///   - `FeastReferrals`    new, 1,472 (the registry: `bind`, `bindWithSig`,
///     `referrerOf`; margin 23,104)
/// The other sixteen are byte-identical to v1.6.25 — `FeastFactory` included,
/// which takes the hook's address and never its constructor. Measured on a
/// build of `src/` in a fresh tree, which reproduces every other v1.6.25 pin
/// byte for byte.
///
/// Re-pinned at `v1.6.25` for AstraSec's report of 2 October, M-3 and Q-3
/// (`docs/audit/v1.6.25-changes.md` has one row per item and the commit that
/// moved each contract):
///   - `FeastPlatformSink`  6,139 -> 6,398  (+259, M-3: a take on a lot the
///     view reads from the top restarts its curve there — `open`'s anchor,
///     clock and frozen checkpoint — keeping the floor and never raising the
///     size; margin 18,178)
///   - `FeastPricer`        4,439 -> 4,463  (+24, Q-3: `_vouch` reads a live
///     ring under `MIN_RING_CARDINALITY` as `Unpriceable`; the listing check,
///     `RingTooShallow`, is constructor code and moves only the initcode,
///     6,282 -> 6,580; margin 20,113)
/// `FeastHook` and `FeastFactory` are byte-identical to v1.6.24 (margins 10 and
/// 833). Measured on a source-only build of `src/` in a fresh tree, which
/// reproduces every v1.6.24 pin byte for byte before any change.
///
/// Re-pinned at `v1.6.24` for the AstraSec draft's fixes (`docs/audit/v1.6.24-changes.md`
/// has one row per finding and the commit that moved each contract):
///   - `FeastOracle`        2,191 -> 2,223  (+32, L-2: a window longer than the
///     history is refused by `OracleTooYoung(age, window)` instead of being
///     shortened to the history)
///   - `FeastPricer`        4,439 -> 4,439  (L-2: the platform price's history
///     guard is the whole `TWAP_WINDOW`, the oracle's new refusal point; same
///     size, new hash)
///   - `FeastConverter`     7,281 -> 7,349  (+68, M-1: `convert` takes the
///     beneficiary's `minOut` and checks it last, after the route floor)
///   - `FeastHook`         24,437 -> 24,455 (+18, M-1: `claimAsBnb` takes
///     `minOut` and forwards it; margin 121)
///                         24,455 -> 24,469 (+14, I-8: the seed's remainder
///     is burned, -14 against the transfer; the position's coin-side fees are
///     owed to `burnFilledCoin` and burned there, +28; margin 107)
///                         24,469 -> 24,566 (+97, I-7: one transient
///     re-entrancy flag at slot 0 on `claim`, `claimAsBnb`, `buyBackAndBurn`,
///     `burnFilledCoin` and `collectLpFees`; OpenZeppelin's `ReentrancyGuard`
///     measured +322 and `ReentrancyGuardTransient` +317, both over the limit;
///     margin **10**)
///   - `FeastFactory`, `FeastHook`: I-6 names `TickMath.MIN_TICK`/`MAX_TICK`
///     in place of `±887_272` and moves neither hash.
///   - `FeastFactory`      23,585 -> 23,743 (+158, I-5: a pre-buy must vest
///     for at least `MIN_PREBUY_VESTING`, seven days, refused by name, with a
///     public getter beside `MAX_PREBUY_BPS_OF_SUPPLY`; margin 833)
///   - `FeastLaunchWindow`  9,595 -> 10,250 (+655, M-2: a pot below `MIN_POT`
///     or with no representable price is no participation and refundable; no
///     deadline for `settle`, the auction abandoned at `abandonAt`; `settle`
///     frozen under ALL; `refund` decrements `total`; margin 14,326). I-9's
///     start clamp is initcode only and moved no runtime byte.
/// Measured on a source-only build of `src/` in a fresh tree, which reproduces
/// every v1.6.23 pin byte for byte before any change.
///
/// Re-pinned at `v1.6.23` for `FeastHook` alone, and nothing else moved a
/// byte:
///   - `FeastHook`         24,330 -> 24,437 (+107: the buy-back button's tip
///     floor -- a constructor-only table of each listed quote's floor, read in
///     the lock callback that already holds the quote, and the tip at a rate
///     the bucket sets: `max(TIP_BPS, min(floor / largest, TIP_CEILING_BPS))`.
///     No getter: the rows are announced by a constructor event, which costs
///     no runtime byte. The first spellings measured +277 to +437, over the
///     limit, and a getter alone is +66. The table is declared after every
///     audited variable: declared first, it moved `_pools` to slot 1, which
///     broke a test that writes that slot and cost 28 bytes of PUSH1 where
///     PUSH0 had been)
/// Measured on a clean build of `src/FeastHook.sol` in a fresh tree, which is
/// the rule's intent: no artifact from a previous setting. Margins after: the
/// hook **139**, the factory 991.
///
/// Re-pinned at `v1.6.22` for `FeastFactory` and `FeastEmissions`, and nothing
/// else moved a byte — `FeastHook` and `FeastGuardian` took comment-only edits
/// and their pins below are the `v1.6.21-audit` ones, unchanged:
///   - `FeastFactory`      22,571 -> 23,585 (+1,014: genesis asks every
///     recipient the whole of what it is trusted with through one path —
///     `_requireTrusted` over the 18-row `_questions` table, 14 questions new —
///     and the four per-site `try` questions and the codeless-sink exemption
///     are gone; the owner's size gate was 23,600)
///   - `FeastEmissions`    13,679 -> 13,813 (+134: the pricing grace moves only
///     by frozen seconds counted from the previous settlement's stamp, instead
///     of restarting from the last unfreeze)
/// Margins after: the hook **246** (untouched), the factory **991**, emissions
/// 10,763.
///
/// Re-pinned at `v1.6.21-audit` for `FeastFactory` alone, and nothing else
/// moved a byte:
///   - `FeastFactory`      21,355 -> 22,571 (+1,216: the three genesis-time
///     questions of the v1.6.20 round -- the window's `poolKey()`, the team
///     wallet's `guardian()` and whether a coded sink is armed -- each asked
///     through `try` with its own typed refusal, plus the `platformPoolKey()`
///     view the first of them needs and a deployer needs more)
/// Margins after: the hook **246** (untouched, and still the one that matters),
/// the factory 2,005, the sink 18,437.
///
/// Re-pinned at `v1.6.20-audit` for the two contracts the v1.6.19 round's HIGH
/// findings reached, and no others:
///   - `FeastPlatformSink`  6,097 -> 6,139  (+42: `ANCHOR_CEILING` and the
///     `Math.min` that clamps the growth term to it -- `HK19`, the anchor could
///     otherwise be walked past `2^255` by refilling the lot between takes --
///     and then the consumed share, which scores a sale by what it took out of
///     the LOT rather than out of the balance, closing the pump the ceiling
///     alone only bounded)
///   - `FeastFactory`      21,354 -> 21,355 (+1: the window's close must now be
///     STRICTLY ahead of the genesis call, `<` becoming `<=` -- `P12`, genesis
///     at the closing second revived a window that had begun refunding)
/// The other twelve are byte-identical to `v1.6.19-audit`. Margins after: the
/// hook **246** (untouched), the sink 18,437, the factory 3,221.
///
contract FeastBytecodePinTest is Test {
    function _pinned(string memory artifact, bytes32 expected) internal view {
        bytes32 got = keccak256(vm.getDeployedCode(artifact));
        assertEq(got, expected, artifact);
    }

    function test_theSealedUnitIsWhatWasAudited() public view {
        _pinned("FeastHook.sol:FeastHook", 0xf30b87466d824d2fa6bcdcfe1e8d780ba230f5b7e287e3a11081a1614ed738f6); // 24,558 bytes (+17, v1.6.28: the guard on the three paying functions, off claim); margin 18
        _pinned("FeastFactory.sol:FeastFactory", 0xcd4b2272d6656a46efdc880f3763a2de36c15255416774b7f74f019c7cdf2425); // 23,957 bytes (+214, v1.6.27 CA-344cf3b11c: the seed burns its own remainder); margin 619
        _pinned("FeastFeeLedger.sol:FeastFeeLedger", 0xe20d72860101be0e2bf6cc3386619d843e8cd5c2bd2dfd0de470d99e26a2d495); // 1,787 bytes (was 2,296)
        _pinned("FeastOracle.sol:FeastOracle", 0x759056a9a244cfa7f1e8c07c1e873082a49ea06357bd23c70a4ccce92b42ec59); // 2,223 bytes (+32, v1.6.24 L-2: refuse, never shorten)
        _pinned("FeastConverter.sol:FeastConverter", 0x1d04dbe1241e0d12a219a95f303bb0cc0b0311a65b0c12de730befa489db53b4); // 7,349 bytes (+68, v1.6.24 M-1: minOut, checked last)
        _pinned("FeastVesting.sol:FeastVesting", 0x175a2c94f6cdccb5c655db63f0e807034f807c24c84eddac54adc5017a83ff27); // 1,757 bytes (+321)
        _pinned("FeastToken.sol:FeastToken", 0x7edb46ed6b01e3fc7480777c3cfa716ffd2b13fb24b2871ee6028f67131a6d49); // 3,409 bytes (was 3,904)
        _pinned("FeastPlatformTokenDeployer.sol:FeastPlatformTokenDeployer", 0xd2c285f7f1194cbb8279b9e4b2a63a15dbffaae7a8b3c81615345503e8c7e0fd); // 11,309 bytes (was 13,255)
        _pinned("FeastPlatformToken.sol:FeastPlatformToken", 0x23e3a8bc9c85fc962a63ec6783f361bc683dd33198f6736419bbfb496d202220); // 7,374 bytes (was 8,947)
        _pinned("FeastPricer.sol:FeastPricer", 0x357c6b0d3f5527056e13bb1490d8618bdf6456762e1fbb8ccddf834392bce919); // 4,403 bytes (-60, v1.6.27 CA-0d9ade0259: the whole window or no price)
        _pinned("FeastEmissions.sol:FeastEmissions", 0x16aff3ef8ff166fd9860c35efa793a9800146c61c1e599129a17fb33501d7f3c); // 13,824 bytes (+11, v1.6.27 CA-6b91a230c6: the grace counts from the close)
        _pinned("FeastGenesisGrants.sol:FeastGenesisGrants", 0x56c5391ae1f2cbdf6069cf03c7a2470a4800339176908eba5312fd3db7ddecd7); // 6,034 bytes (+179: the assignment window waits for genesis)
        _pinned("FeastPlatformSink.sol:FeastPlatformSink", 0xd95c950a5b8af4f3f99808546a1c4a783ae26d73765577bf1ff3e2293836ac32); // 6,398 bytes (+259, v1.6.25 M-3: a take outside the band restarts the curve); margin 18,178
        _pinned("FeastLaunchWindow.sol:FeastLaunchWindow", 0x324e8cc26919b7f2b0d4cd234cc96af0b1bd32388a5bc0db64f21d3e71c29895); // 10,250 bytes (+655, v1.6.24 M-2: dust is no participation, no deadline for the coin)
        _pinned("FeastTeamVesting.sol:FeastTeamVesting", 0xa2cdccc725f9591350badd57075e0171d49bb1415d090f5805f9bd3ce041decc); // 2,623 bytes (+314: both arities overridden)
        _pinned("FeastGuardian.sol:FeastGuardian", 0xf0b28be9ea93b78f0865f34764359d4594df716752bc5bf70a0e603435de93e0); // 4,454 bytes (+650, v1.6.27 CA-6b91a230c6: the freezes that have ended, and frozenSecondsAt)
        _pinned("FeastReferrals.sol:FeastReferrals", 0xfbc282869f256d90925f015176529d751b636d8959aaadaa9fb2c78a0513f0c4); // 1,472 bytes (new, v1.6.26 M-4: a wallet binds by its own call or signature); margin 23,104
        _pinned("TimelockController.sol:TimelockController", 0x3172cd82739b956712a8e394aef78be5da391759f5854df9684157e497a9d6d5); // 5,790 bytes (was 6,693)
    }

    /// v1.6.28 changes the hook and nothing else — AstraSec's two suggestions
    /// of 7 October: the hash in the table above, and the size, on their own.
    function test_theHookIsTheV1628Hook() public view {
        bytes memory code = vm.getDeployedCode("FeastHook.sol:FeastHook");
        assertEq(
            keccak256(code), 0xf30b87466d824d2fa6bcdcfe1e8d780ba230f5b7e287e3a11081a1614ed738f6, "the v1.6.28 hook"
        );
        assertEq(code.length, 24_558, "24,558 bytes, a margin of 18");
    }
}
