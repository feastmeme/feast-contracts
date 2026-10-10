# Contract Review — feast v1.6.21-audit, the seven carried MEDIUMs priced (one memo unit)

## TREE PIN — MANDATORY, DO THIS BEFORE READING ANYTHING ELSE

```
AUDIT_WORKTREE=.
AUDITED_TREE=e5c0a771107a8a17f510806bafd50bfe33035ec7
```

Exactly one checkout is the subject: the worktree you are already in. The audited code is the
tag `v1.6.21-audit`, commit `e5c0a771107a8a17f510806bafd50bfe33035ec7`. The checkout's own HEAD is a
descendant of that tag, `d9b50c53c295d8393ef6f2d4e07b518de2d26241`, which adds evidence only — files under `audit-pack/`
and `docs/` — and changes nothing under `src/`, `test/`, `lib/` or `script/`: `src/` is tree
`a4162ac40cd0bff4561e68f50d6e387dca5374a2` at both commits. Other checkouts of this repository exist
on this machine.

1. Run `git rev-parse HEAD` — exactly that, with no `-C` and no path. It is the one shell command you
   are permitted, and under this sandbox your working directory already **is** the audited worktree.
   It should print `d9b50c53c295d8393ef6f2d4e07b518de2d26241`.
2. Make the **first line of your reply** exactly
   `AUDITED_TREE=e5c0a771107a8a17f510806bafd50bfe33035ec7` — the tag's commit, **not** the HEAD that
   step 1 printed. Make the **second line** `CHECKOUT_HEAD=<the oid step 1 printed>`. A first line
   that is not a prefix of `e5c0a771107a8a17f510806bafd50bfe33035ec7` voids this unit.
3. Read only files under this worktree. A path outside it in your citations voids the unit.
4. Every `file:line` you cite must resolve in this checkout (for `src/` and `test/` that is the tag).
   Several rows below cite a line from the older tag the finding was raised on; on this tree the line
   may have moved. **Find the function by name and cite the line as it is here.**
5. **Hypothetical paths must not carry a line number.** Anything shaped like `path/name.ext:123` is
   read as a citation and checked, so an invented one voids an otherwise sound answer.
6. Cite something. A memo with no resolvable citation proves nothing about which tree you read.

## WHAT THIS IS

An **internal engineering memo about our own team's code**, written for the project's owner. It is
not a search for new defects. Seven MEDIUM findings on this tag are already known, already
reproduced, and were deliberately **carried** — not fixed — when the tag was frozen. The tag went to
the external audit firm on 2026-09-24; their report is due 2026-10-03 and mainnet is 2026-10-06. On
**2026-10-01** the owner decides, for each of the seven, whether to fix it before mainnet or to accept
it and document it. The firm will ask why each was not fixed. Your memos are the owner's basis for
that decision, so what they need is **numbers the owner can check**, not adjectives.

Nothing here is third-party and nothing is deployed. Write in ordinary engineering language: *who
can cause it*, *what must be true*, *how much value moves to the wrong party or is stranded*, *what
the change costs*. Write every bound as the arithmetic that produces it, with the constant's
`file:line`.

**The system in two sentences.** feast launches meme coins on PancakeSwap Infinity (a
Uniswap-v4-style singleton venue with hooks) on BNB Smart Chain; `src/FeastHook.sol` takes 1% of the
quote leg of every swap and splits it four ways (platform, creator, referrer, coin self-burn). The
platform coin FEAST is launched once through `genesis`, with a 24-hour uniform-price window, 52 weeks
of emissions paid against the fee ledger, eight partner grants, and a sink that spends the platform's
share buying FEAST back. The design, every actor's powers and every constant are in
`docs/audit/overview-v1.6.21.md` (§1 actors, §3.5 the platform coin, §3.6 the guardian's freeze,
§4 contract by contract, §5 constants, §7 known residues). The owner's own notes on these seven are in
`audit-pack/notes.md` ("The ten MEDIUMs, each exercised" and "Known-open, with bounds").

## The seven rows

The ledger rows are in `audit-pack/findings.md` (each row's `status_reason` carries the measured
figures). Each finding's original write-up is the verdict of the review unit that raised it, in
`audit-pack/rounds/r1/lens/`. Each PoC below is a test in the tree that was **run red** and is now
skipped with `vm.skip(true)`, its measured numbers written in its docstring — read the test for the
exact setup and figures. You cannot run tests; you do not need to.

| # | row | class | cited site (older tag's line) | PoC | original write-up |
|---|---|---|---|---|---|
| 1 | `CA-33ea5aaf49` | `preopen-regime-decided-by-settle-instant` | `FeastEmissions.settle` (cited `:498`) | `test/audit/poc/EmissionsRegimeUnderAFreeze.t.sol` `test_aFreezeAcrossTheWindowsCloseCannotStripAPreLaunchWeeksTokenCap` | `P16-claude-verdict.txt` |
| 2 | `CA-2d81ea2290` | `false-three-day-protection` | `FeastEmissions.settle` (cited `:505`, the RESIDUE justification near `:492`) | same file, `test_capRegimeWaitsThreeOpenDays` | `P5-verdict.txt` |
| 3 | `CA-7da18d1e43` | `own-brake-extends-own-window` | `FeastGenesisGrants.assignPartner` (cited `:164`) | `test/audit/poc/GuardianWindowExtension.t.sol` `test_theMultisigCannotFillASlotPastDayNinetyInsideItsOwnFreeze` | `P19-claude-verdict.txt` |
| 4 | `CA-7dca95d8e3` | `sunset-unanchored-prefreeze` | `FeastGuardian.sunsetAt` (cited `:462`) | same file, `test_frozenSecondsSpentBeforeGenesisDoNotLengthenThePartnerWindow` | `P19-claude-verdict.txt` |
| 5 | `CA-407dffa3a4` | `shared-origin-capture` | `FeastHook._referrerFor` (cited `:615-619`) | `test/audit/poc/SharedOriginCapture.t.sol` `test_aUserOpCannotBindTheBundlerThatSubmittedIt` | `HK23-claude-verdict.txt` |
| 6 | `CA-4e08c595d3` | `floor-sale-misses-price-rise` | `FeastPlatformSink.take` (cited `:603`) | `test/audit/poc/FloorSalePriceRise.t.sol` `test_aSaleAtTheFloorRaisesThePublishedPrice` | `P3-verdict.txt` |
| 7 | `CA-2fbb35d7a1` | `hop-rounding-amplification` | `FeastPricer.priceQ128` (cited `:141`) | **none in the tree** | not in the tree; the figures are in the row's `status_reason` and in `audit-pack/notes.md`; earlier mentions in `docs/audit-briefs/v1614-round-findings.md`, `v1615-scope-and-cost.md`, `v1616-count-what-was-served.md` |

Rows 1 and 2 share one seam (a freeze across the window's close and `openAt`); rows 3 and 4 share
one window (`sunsetAt`). Price each row on its own, and where one change would close both rows of a
pair, say so in both memos and give the combined cost once.

## What each memo contains — about one page per row

Use these six headings, in this order, for every row. Mark every number as **measured** (a PoC's
figure, quote where it is written), **derived** (your arithmetic from the code — show it) or
**assumed** (an input the tree does not fix — name it and say why you chose the value).

1. **Trigger.** Who can cause it (a role from the overview's actor table, or "anyone"); when (which
   phase: before genesis, the seam between the window's close and `openAt`, the first 90 days after
   genesis, any time); and what else must be true. Say whether it needs a privileged role, whether
   it can happen by accident with no one intending it, and whether it can recur.
2. **Loss upper bound.** The largest amount that can move to the wrong party, be stranded, or be
   mispriced under the trigger — in FEAST, BNB, the quote asset, or bps, whichever the mechanism
   moves — computed from the constants in the code (cite each `file:line`) and the PoC's figures.
   An upper bound, not a typical case: show the formula, then the number. Where the bound depends on
   a quantity the tree does not fix (trading volume through one address, a price), state it per unit
   of that quantity (e.g. "X bps of every fee routed through the bundler") and give one worked number
   at a named assumption. If no value moves and the harm is a broken promise — a window longer than
   documented, a regime different from the one the docs promise — price the promise in its own unit
   (seconds, slots, the FEAST a regime difference can emit) and say plainly that no balance moves.
3. **Who bears it.** Platform, creator, trader or partner (name referrers or FEAST holders where that
   is more exact, and say which of the four they fall under). Say who gains, if anyone.
4. **Fix cost.** The smallest change that closes it: which contract and function, roughly how many
   lines, whether it changes storage layout, ABI, events or a deploy script, which tests change, and
   the **bytecode room** it must fit in (table below; `FeastHook` has **246 bytes**). Give your
   estimate of the runtime bytes it adds and say whether that estimate is tight or rough. A sketch of
   at most ten lines is welcome **as an illustration of the cost** — it is not the patch, and it is
   not reviewed as one. Include the process cost: the tag is frozen and with the external firm, so
   any fix means a new tag, a re-pinned bytecode record, a mutation re-run on the changed file, and a
   delta the firm must re-review before 2026-10-06.
5. **Side effects.** What else the change alters: other invariants (`audit/invariants.yaml`), other
   documented promises, earlier rounds' fixes on the same lines, gas on the swap path.
   `audit-pack/notes.md` records five consecutive releases whose own fix carried a defect — weigh the
   regression risk of a change made this late honestly, in both directions.
6. **Recommendation.** One line, exactly one of `**Recommendation:** FIX BEFORE MAINNET` or
   `**Recommendation:** ACCEPT` (an ACCEPT may add `, with <an operational mitigation you name>`),
   then one sentence of reason, then one sentence on **what would change this recommendation**.

The owner will read the seven memos side by side, so open the document with **one summary table**:
row, class, trigger (at most twelve words), loss upper bound, who bears it, fix (contract / about how
many lines / about how many bytes of how many free), recommendation.

### Bytecode room at this tag (runtime bytes; EIP-170 limit 24,576)

From `audit-pack/bytecode.md` (built at the tag with `via_ir`, optimizer runs 1,000):

| contract | runtime bytes | free |
|---|---|---|
| `FeastHook` | 24,330 | **246** |
| `FeastFactory` | 22,571 | 2,005 |
| `FeastEmissions` | 13,679 | 10,897 |
| `FeastLaunchWindow` | 9,595 | 14,981 |
| `FeastPlatformSink` | 6,139 | 18,437 |
| `FeastGenesisGrants` | 6,034 | 18,542 |
| `FeastPricer` | 4,439 | 20,137 |
| `FeastGuardian` | 3,804 | 20,772 |

`FeastGuardian` is not in the pack's pin list; its figure was read by the operator from the build
artifact of the same compiler settings, built at `eeb59ce6ab9e69285c134cbbf8bd5363e83ef210` (whose `src/` is the tag's); the
seven pinned contracts above measured identically in that same build.

## Rules

- **Read only.** Read, Grep and Glob are your reading tools; `git rev-parse HEAD` is your only shell
  command. Write no file. Your reply is the deliverable; the operator saves it verbatim as
  `docs/audit-r11/carried-medium-memos-v1621.md`.
- **Your final message must contain the whole document**, from the `AUDITED_TREE=` line to the
  `VERDICT:` line. Only your final message is kept; text from an earlier turn is lost.
- **Do not re-litigate whether a row is real.** Each has a red PoC (six) or a measured figure (row 7).
  If your reading of the code gives a different number than the one recorded, say so in that memo
  with both numbers and the arithmetic — that is worth more than agreeing.
- **Severity is yours to restate.** The ledger grades all seven MEDIUM. If a memo concludes a row
  deserves HIGH or LOW on this tree, say why in that memo; the counts on your last line use your
  grades.
- **No new hunting.** If you notice something outside the seven, one line each in a closing section
  "Observations outside the seven", with a citation and no severity.
- A candidate fix for each row is being prepared elsewhere. You have not seen it and must not assume
  its shape; price the smallest fix **you** can justify from this tree.

## OUTPUT CONTRACT

1. **Line 1:** `AUDITED_TREE=e5c0a771107a8a17f510806bafd50bfe33035ec7`
2. **Line 2:** `CHECKOUT_HEAD=<the oid git rev-parse HEAD printed>`
3. Then the document, in Markdown, beginning with the heading
   `# Carried MEDIUMs at v1.6.21-audit — what each costs, and what to do (r1.1)`, then the summary
   table, then one `## <row id> — <class>` section per row in the order of the table above, each with
   the six headings, then "Observations outside the seven" (write "None." if there are none).
4. **The last non-blank line of your reply**, with nothing after it — no code fence, no prose:

```
VERDICT: HIGH=0 MEDIUM=7 LOW=0
```

   with the three counts replaced by how many of the seven **you** grade HIGH, MEDIUM and LOW (a row
   you would grade below LOW is counted LOW and its memo says so). The three counts must sum to 7. Use
   `=` and single spaces. A reply that ends any other way is refused and the whole unit is wasted.
