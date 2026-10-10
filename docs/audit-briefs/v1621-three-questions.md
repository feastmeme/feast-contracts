# v1.6.21 — three questions genesis did not ask

Receipt for the release handed to AstraSec. Predecessor:
`v1620-two-highs-and-the-curve.md`. Earlier tags are never moved.

## The one sentence

The v1.6.20 focused re-round returned **no HIGH** and ten distinct MEDIUMs. The
owner ruled that the three genesis-time ones are fixed before the auditor sees
the pack and the other seven are carried with their bounds — **each of the ten
exercised by a PoC that was actually run**, not carried in a sentence.

## 1. What the ten PoCs measured

| finding | from | result |
|---|---|---|
| `genesis-window-key-unchecked` | `P4-claude` | PROVEN red → **fixed** |
| `team-wallet-guardian-unchecked` | `P8-claude` | PROVEN red → **fixed** |
| `sink-arming-unenforced` | `P12-claude` | PROVEN red → **fixed** |
| `floor-sale-misses-price-rise` | `P3` | PROVEN red → carried, and **pre-existing** |
| `own-brake-extends-own-window` | `P19-claude` | PROVEN red → carried |
| `sunset-unanchored-prefreeze` | `P19-claude` | PROVEN red → carried |
| `false-three-day-protection` | `P5` | PROVEN red → carried |
| `preopen-regime-decided-by-settle-instant` | `P16-claude` | PROVEN red → carried |
| `shared-origin-capture` | `HK23-claude` | PROVEN red → carried |
| `lp-income-platform-share` | `P3` | **false positive** — declared behaviour |

> The v1.6.20 tally reads eleven MEDIUM rows and there are **ten distinct
> findings**: `verdict-P12-claude.raw` repeats `verdict-P12-claude`. The list was
> taken from the verdict files.

`lp-income-platform-share` describes the code correctly and its expectation
contradicts a declaration three lines above the cited site: LP fees have no
discoverable earning epoch and the venue reports only a total, so their platform
share buys and burns instead of joining the pot. Its PoC pins the **declared**
behaviour and passes, so a future change to it fails there.

`floor-sale-misses-price-rise` cites `FeastPlatformSink.sol:603`, which is
v1.6.20's own line. The same PoC on `v1.6.19-audit` prints the same four numbers
and fails identically, so v1.6.21 does not touch it. That counterfactual was run
rather than argued, because an argument of mine about that exact line is what
the round before it disproved.

The six proven-and-carried PoCs carry `vm.skip(true)` and their measured numbers
in the docstring. A failing test makes the release gate unreadable and a deleted
one makes the finding a sentence again; a skipped one with its numbers written
down is the honest middle, and it is loud.

## 2. The three fixes, which are one shape

Genesis interrogates a contract it is about to trust with value about some of
what it must be, and not about the rest. Each ends the same way: a transfer
lands somewhere with no function able to move it again.

  * **The window must be keyed to the pool genesis registers.** It was asked its
    role, its coin, its close and its opening liquidity — never its `poolKey()`.
  * **The team wallet must obey THIS guardian.** It was asked when it starts, not
    whose brake it reads; a wallet built against an address with no code answers
    `start()` correctly and then every `release` reverts for ever, with
    250 000 000 in it.
  * **A sink that already exists must already be armed.** `settle` sends the
    pot's 1% to it and `schedule` refuses a window whose close has passed, so a
    sink nobody armed before the close can never be armed at all.

All three are asked through `try`, like `start()` at v1.6.10, so a contract that
cannot answer is refused **by name** rather than by an opaque revert. The sink's
question is asked after its role check, so a coded thing that is not a sink
still answers `RecipientNotAllowed`.

**The third changes the ceremony's order**, and that is the whole of its cost:
`sink.schedule(window)` now runs before `factory.genesis`. `script/Genesis.s.sol`
is reordered to match — its own comment already warned that a `schedule` which
did not land before the close left the window unschedulable for ever, and this
makes that warning enforceable instead of advisory.

`platformPoolKey()` is published because the check needs it and a deployer needs
it more: `poolKeyFor` answers with a zero quote before genesis, so there was no
way to check the window's key **before** signing.

## 3. What the release gate says

| check | result |
|---|---|
| suite | **761 passed, 0 failed, 6 skipped** with the fork row |
| boundaries | 9 of 9 |
| census | every row resolves |
| mutation | **15 of 15** on `FeastFactory`, incremental |
| sizes | factory 21,355 → 22,571 (margin **2,005**); hook 24,330 untouched (margin **246**); nothing else moved a byte |

## 4. And the gate caught something the suite could not

The first mutation run reported **two survivors**: the witnesses for the window
key and the team guardian went on passing with the checks they exist for
removed. Both used a bare `vm.expectRevert()`, which accepts any revert — and
neither armed the sink, so `SinkNotArmed` fired first and satisfied the
expectation. They proved genesis refused *something*, never that it refused
*this*.

Both now arm the sink against their own window and name the exact typed error.
The suite could never have found it: both tests were green throughout.
