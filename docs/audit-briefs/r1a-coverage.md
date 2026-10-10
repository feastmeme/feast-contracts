# Round 1, lens A — coverage

## What this codebase is

A factory that creates ERC-20 coins, pairs each with a caller-chosen quote token
(in practice a tokenised stock) in a concentrated-liquidity pool on PancakeSwap
Infinity, locks the opening liquidity permanently, and installs a hook that takes
1% of every swap **on the quote leg only** and divides it into shares fixed in
the coin's creating transaction. There is no owner, no upgrade path and no pause.
Exactly one number can change after deployment, by token vote, inside a
hard-coded band.

Everything under `src/` is the subject. `lib/` and `reference/` are vendored
third-party code and are **not** the subject; cite them only to show what the
shipped code does or does not do with them.

## Your assignment

Work through the shipped contracts and, for each, answer two questions in the
form the code answers them:

**What does this component ACCEPT?** — which callers, which arguments, which
states of the world does it proceed on.

**What does this component REFUSE?** — which predicate stops it, and what would
otherwise get through.

A finding is any place where the accept set is wider than intended, or the
refuse set catches something it should not (a refusal that stops honest use is
as much a defect as a missing one). Show the concrete construction: caller,
arguments, chain state, and the path through the code.

## The refusal ledger to check against

`docs/plan.md` §4 lists seventeen predicates, each with what it refuses, which
adversary it excludes, and — the column that matters most here — **what it must
not refuse**. For each row: does the shipped code implement that predicate, does
it exclude that adversary, and does it still admit everything in the "must not
refuse" column? A predicate that over-refuses is a finding; so is one whose
stated adversary can still get through by another route.

Pay particular attention to these areas.

**The fee take, four branches.** Which currency the venue calls "specified"
depends on two booleans, so landing the fee on the quote leg every time takes
four branches — two in `beforeSwap`, two in `afterSwap`. Check each against the
others: does the same economic trade produce the same fee whichever branch it
takes? Both token orderings (the coin may sort above or below the quote), both
trade directions, exact-input and exact-output. Rounding direction matters: who
absorbs the remainder, and can it be made to favour the trader repeatedly.

**The share split.** Four shares are derived from one running total, and the
creator's is computed by subtraction. Do they always sum to exactly the fee
taken, for every combination of the two creator-set shares and every trade size?
Can any share be paid twice, or become unreachable?

**The opening caps.** A per-wallet purchase cap binds for the first N blocks, on
purchases only. Confirm it cannot refuse a sale, cannot refuse a purchase after
the window, and cannot be evaded within its own terms. Its keying on `tx.origin`
is a documented limitation, not a finding — but say whether the documentation
matches what the code does.

**The two buttons.** `FeastHook.buyBackAndBurn`, `FeastHook.platformBuyBack` and
`FeastConverter.convert` are all permissionless and all pay the caller a tip.
Check the bounds: size ceiling, minimum interval, the tick-deviation check
against the time-weighted price, and the price limit carried into the swap. Can
a caller extract more than the press produces? Can repeated presses drain
anything? Can a press be made to fail in a way that consumes state without
producing the effect?

**Epoch accounting.** `FeastEpochRewards` keeps one ledger and one pot per quote
token. Can claims for an epoch exceed that epoch's pot? Can an epoch still being
earned be claimed? Can a payer be credited without a corresponding fee, or
credited twice?

**Governance.** One parameter, a hard-coded band enforced at the contract being
changed rather than at the governor, a timelock, and an effect deferred to the
next epoch boundary. Can the band be left by any path? Can a change reach an
epoch already being earned? Can anything other than that one parameter be
reached? Note that the votes token reports a **timestamp** clock rather than a
block clock — check every place that assumes one or the other.

## Adversary classes to work through by name

Plainly, without inventing scenarios the code cannot reach:

- **Reentrancy** — the hook is called by the venue mid-swap and itself calls back
  into the venue inside a lock. Trace which state is written before which
  external call.
- **Oracle staleness and thin history** — `FeastOracle` and the v3 pools the
  converter reads. What does each return when it has little or no history, and
  does the caller distinguish that from a real answer?
- **Rounding direction** — integer division appears in the fee, the shares, the
  tip, the burn split, and the epoch pro-rata. In each, who gains the remainder?
- **Access control** — every state-changing external function and its caller
  set. `factory`, `vault`, `poolManager`, `recorder`, `timelock` are the
  privileged names; is each one checked where it should be, and is anything
  privileged that need not be?
- **A frozen, blacklisting or sanctions-screening quote token** — quote tokens
  are upgradeable proxies whose issuer can stop transfers. Which paths touch the
  quote token, and what happens on each when it refuses?
- **Gas griefing on the buttons** — can a caller make a press cost the protocol
  more than it returns, or make someone else's press fail?
- **Front-running of a buy-back** — the buttons are public and tipped. What can
  be extracted by ordering around them?

## A boundary, not a defect

The venue does not invoke a hook's callbacks when the hook is itself the
swapper. Feast relies on this: the buy-back's own swap pays no feast fee and
trips no feast cap, with no re-entrancy flag. `lib/infinity-core/src/libraries/Hooks.sol`
carries the check. If you believe this reliance is misplaced, show the
construction; "the hook could be re-entered here" without one is not a finding.

Similarly out of scope: the venue can be paused by its own operator, and takes a
share of the LP fee at a rate its operator sets. Feast has no admin; the venue
does. Both are documented in `README.md` and are not findings.

## Output

Follow the output contract in the header above. Group findings by severity with
`file:line` evidence at the pinned commit. For each finding, state which
component's accept or refuse set is wrong and what the concrete construction is.
If nothing meets the bar, say so plainly rather than padding.
