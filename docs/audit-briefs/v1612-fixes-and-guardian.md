# v1.6.12 — three proven findings fixed, a guardian, and partner slots that can be filled

Task 567, branch `feat/v1.6.10-fixes`, cut from `v1.6.11-audit`. This is the receipt for the
commit handed to AstraSec. Design documents: `plans/audit/window-auction-design.md` (the
auction, amended), `plans/audit/guardian-design.md` (the guardian, and §10 for the partner
slots). Plan record: `docs/plan.md` §6i.

> **Superseded by `v1613-round-findings.md`.** The round on this tag found four
> HIGH-shaped defects — three in the guardian this release added, and one that
> overturns the disproof recorded in §1 below. This brief was never handed over.

**The seal is taken.** Suite 613 passed, 0 failed, 0 skipped with the fork row at block
120,721,477; mutation 234 of 235 with 1 knowingly outstanding and 0 survivors; census and
boundaries ok across all seven checks; `FeastHook` 23,934 of 24,576 with 642 to spare.

---

## 1. The three findings the v1.6.11 round proved, fixed

The round on `v1.6.11-audit` ran 37 hunter classes in both families. Three findings reproduced
as failing Foundry tests and one did not; all four PoCs are in `test/audit/poc/` and stay.

### HIGH `auction-lp-fees-stranded` — four units, both families

A position's range is the only handle on it. `FeastHook` records one `(tickLower, tickUpper)`
pair; v1.6.11's auction placed **two** positions and recorded neither, so `collectLpFees` on the
platform pool handed the venue `(0, 0)` and reverted `TicksMisordered(0, 0)` for ever. The LP
fees of the permanently locked liquidity were earned always and collectable never. Two positions
could not both have been addressed by one pair even if it had been written.

**The two ranges were never needed.** The tranche is half the holding, so the coin left over
equals the coin sold, and at `p* = net/sold` the two one-sided liquidities are both
`√(sold · net)`. Settlement now places ONE position, `[minUsableTick, maxUsableTick]`, and
records it.

**And the tick alignment went with it.** The alignment existed only because the two ranges MET at
a tick and a meeting point must be a multiple of the spacing. One full-range position has no
meeting point, so the pool opens at `p*` **exactly**. That is where 1.2% of a ten-ether pot was
going: at an opening price up to 2.02% under `p*` the position wanted less quote per coin than
the window held, so it took all the coin and left quote behind. It also deletes the up-to-2.02%
the first seller used to pay for the alignment.

The **no-commit** path was stranded for the same reason and nobody had noticed. It goes through
`seedLiquidity` — the creator path, precisely because that path refuses a position needing quote
— via `FeastFactory.seedWindowOpening`.

### HIGH `unauthorized-creator-prebuy` — `P6b`

`_prebuy` pulls the quote from `p.creator`; `create` is permissionless and `p.creator` is a free
parameter. So the approval a creator must give the factory to pre-buy their own coin was
spendable by anybody, on a coin of the stranger's choosing, with a vesting duration of the
stranger's choosing. `PrebuyNeedsTheCreator(creator, caller)`, and only on the pre-buy: creating
a coin FOR somebody else with no pre-buy stays permissionless.

### MEDIUM the no-commit opening — five units, both families

Genesis recorded three numbers for the fallback opening (price, tick, liquidity), unchecked, with
no setter, first exercised together twenty-five hours later. A price above its own start tick put
the coin-only range in range, the venue asked the hook for wrapped native it does not hold, and
the settlement reverted — permanently, with 60% of the supply and no exit.

`GenesisParams` now carries the **price alone**. The tick is floored from it inside `genesis`,
the pool opens AT that tick, and the liquidity comes from the coin actually held at settlement.
`FeastLaunchWindow.openingLiquidityFor` — the window's own code, not a copy — is called by
`genesis` before it records anything, so a price whose position could not be placed is refused in
the room. `script/Genesis.s.sol` loses two arguments.

**Two venue ceilings the fuzz found**, both of which genesis would have accepted and settlement
failed on: `liquidityDelta` is cast to `int128` (`SafeCastOverflow`), and gross liquidity at any
one tick is capped at `type(uint128).max / numTicks`, about 3.8e34 (`TickLiquidityOverflow`). The
window refuses above the tighter of the two by name, which is what makes the genesis check exact.
`test_theWindowsLiquidityCeilingIsTheVenuesOwn` pins the arithmetic against the venue's.

### ~~DISPROVED~~ — the pre-buy's signed cast · **RETRACTED 2026-09-21**

> **This section is wrong and is withdrawn.** The v1.6.12 round's `P6b` found the
> value both guards miss: `int256(type(uint256).max)` is `-1` and negating it is
> `1`, a one-unit exact-OUTPUT swap that strands almost all the creator's quote.
> The PoC below tested `2^255` and `2^255 + 1` — the two EDGES of the gap — and
> never the inside of it, so its witness did not reach its bound. Fixed with
> `SafeCast.toInt256` in `eaedc20`; the full retraction is in
> `docs/audit-briefs/v1613-round-findings.md` §4. What follows is left as
> written, because the mistake is part of the record.

### DISPROVED — the pre-buy's signed cast

Three Codex units agreed that `-int256(quoteIn)` at `FeastFactory` turns an oversized input into
an exact-OUTPUT swap and strands the quote. Measured: at exactly `2^255` the negation panics
under 0.8's checked arithmetic, and one above it the venue's own `SafeCast` refuses. Either way
the transaction reverts and the transfer is rolled back, so no balance is ever stranded. The test
is kept PASSING as the pin on that.

---

## 2. The guardian — a brake that can never touch the money

Owner 2026-09-20 14:2x, into this audit version rather than a V2. feast has no owner and this is
the one exception; the whole design exists to keep that sentence true.

| | |
|---|---|
| `stopCreation()` | one-way, never unpulled, and deliberately **not** sunset — after day 90 it is the only power left |
| `freeze(scope)` | `ALL` or one `PoolId`; **≤72 h** per pull, expiring by itself; **≤168 h** over the guardian's life; gone **90 days** after genesis, after which anyone may `expire()` a freeze left standing |

The whole grant is charged to the budget at `freeze`, not when it lifts, so the ceiling is exact
at every instant; an early `unfreeze` refunds the unused tail.

**What a freeze reaches** is enumerated in `plans/audit/guardian-design.md` §2 and checked by
`tools/check-boundaries.py`'s `guarded` check: every state-changing function in the tree carries a
verdict, and every verdict is compared against the source. **The launch window is not freezable**
— its refunds are on a clock, and a freeze could only push it past its own hour and turn a brake
into a confiscation. **A holder's own balance is never frozen**: an ERC-20 transfer moves the
caller's own tokens, and freezing that would be a power over property rather than over the
protocol.

**`FeastEmissions.settle` is frozen, and the condition for that is verified rather than
asserted.** It has exactly one instant comparison that can refuse and it is a lower bound; the
`settlement-deadline` check reads the source and fails if a deadline ever appears.

**The cost, reported because it is one.** Every trade pays **5,374 gas** — a cold account access
plus a cold `SLOAD` of `frozenUntil` — which is 2.3% of a 233,163-gas plain trade. It is held as
its own constant so it does not hide inside the referral lookup's. The hook has 642 bytes left,
so inlining the state to make the read warm is not available.

---

## 3. Partner slots that can be filled after genesis

Owner 2026-09-20 18:5x. Eight partner addresses no longer have to exist before launch: a slot
left at `address(0)` may be filled **once**, by the team multisig, inside the guardian's own
90-day window. It borrows both of the guardian's facts and creates neither — the key is
`guardian.guardian()` and the deadline is `guardian.sunsetAt()`, both read from the guardian, so
they cannot disagree.

A filled slot is immutable, whether it was filled at genesis or last week. The assignment moves
no value. The six-month unlock clock runs from genesis and is not restarted, and an emission week
that had already closed when a slot was filled counts **zero** toward it — an address that was
already referring fees as an ordinary referrer does not arrive with a head start. A week still
open at the moment of assignment counts in full: at most one week, stated rather than hidden.

A slot nobody fills burns: `burnUnfilledSlot(uint8)`, callable by anyone once the window closes.
That is a new entry point and `plans/audit/guardian-design.md` §10 records why — `burnUnearned`
takes a partner ADDRESS and an empty slot has none, so without it the grant would strand (I14).

---

## 4. Runtime bytecode (immutables as zero placeholders; no metadata hash)

Measured from `forge build --force --sizes`. Against `v1.6.11-audit`:

| Contract | Bytes | Δ | margin | keccak256 |
|---|---:|---:|---:|---|
| `FeastHook` | 23,934 | +430 | **642** | `0xc5feff7087b95d934d60cafdd5a5135e54c89b5bf60e8f758ec8c8ffd010f003` |
| `FeastFactory` | 21,127 | +2,978 | 3,449 | `0x624419e3f68c23ff8a261a4231d7960393da570a15a64ef96f118e42371d7c37` |
| `FeastLaunchWindow` | 9,569 | −923 | 15,007 | `0xeb943917cf8b6d9bd082bd177ad7e2fadafdd48f911d74f4287b5d8894511d4e` |
| `FeastGenesisGrants` | 5,855 | +2,401 | 18,721 | `0xf3ee4d0afecbfc9177d4119896a4f88a7f20d20a2487a4412cad9f5cd3c164af` |
| `FeastEmissions` | 13,008 | +339 | 11,568 | `0xecbc9fbcac5fcde56ea9a38e935aea98c838a7884ca01ece9ce68738693c61c2` |
| `FeastPlatformSink` | 5,304 | +311 | 19,272 | `0x319bd1082e859ac5b266e4f371a8933d7d30ff1fa6c9f82b4d266481f073cce5` |
| `FeastTeamVesting` | 2,623 | +314 | 21,953 | `0xa2cdccc725f9591350badd57075e0171d49bb1415d090f5805f9bd3ce041decc` |
| `FeastVesting` | 1,757 | +321 | 22,819 | `0x175a2c94f6cdccb5c655db63f0e807034f807c24c84eddac54adc5017a83ff27` |
| `FeastGuardian` | 2,482 | **new** | 22,094 | `0xee6cd021c3ffe62344394ce3a21c2c78f47fa7033417c25bbfc466573c8ed65c` |

The rest are byte-identical to `v1.6.11-audit`. The seventeen are in
`test/FeastBytecodePinTest`, which is the check; this table is not.

---

## 5. How to reproduce

```
forge build --force --sizes
forge test                                          # 613 passed, 0 failed, 0 skipped with FORK_URL
forge test --match-contract FeastBytecodePinTest    # the seventeen runtime hashes
forge test --match-path 'test/FeastGuardian.t.sol'  # the brake, sixteen tests
forge test --match-path 'test/audit/poc/*'          # the round's findings, three fixed and one disproved
python3 tools/mutate.py                             # 234 of 235, 1 knowingly outstanding
python3 tools/check-census.py
python3 tools/check-boundaries.py                   # licence, authority, identity, surface, abi, guarded, settlement-deadline
```
