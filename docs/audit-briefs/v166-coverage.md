# Coverage lens — feast-contracts at `v1.6.6-internal`

## What this codebase is

A factory that creates ERC-20 coins, pairs each with a caller-chosen quote token
(in practice a tokenised stock) in a concentrated-liquidity pool on PancakeSwap
Infinity, locks the opening liquidity permanently, and installs a hook that takes
1% of every swap **on the quote leg only** and divides it into shares fixed in the
coin's creating transaction. There is no owner, no upgrade path and no pause.

Around that core, v1.6 added a platform coin and the machinery that pays it out:
genesis and its grants, a launch window, a weekly emissions schedule read from the
hook's own fee ledger, a pricer that values each quote token, a sink that sells
stray assets at a descending price, a converter, and two public buttons.

Everything under `src/` is the subject. `lib/` and `reference/` are vendored
third-party code and are **not** the subject; cite them only to show what the
shipped code does or does not do with them.

## Your assignment

Work through the shipped contracts and, for each, answer two questions in the form
the code answers them:

**What does this component ACCEPT?** — which callers, which arguments, which
states of the world does it proceed on.

**What does this component REFUSE?** — which predicate stops it, and what would
otherwise get through.

A finding is any place where the accept set is wider than intended, or the refuse
set catches something it should not: a refusal that stops honest use is as much a
defect as a missing one. Show the concrete construction — caller, arguments, state
— and say what the failing Foundry test would assert. A severity without a
construction is not a finding; write it under EXECUTION-NOTES instead.

## The components, by file

**`FeastFactory`** — one transaction creates a coin, seeds a pool, locks the
position and registers it with the hook. Supply is capped at creation
(`FeastConstants.MAX_SUPPLY`). What can a creator choose, and what is fixed?

**`FeastHook`** — the venue calls it around every swap on a feast pool. It takes
the fee, splits it four ways, records the payer's credit in the ledger, enforces
the opening-window purchase cap, runs the internal fill, and holds the buy-back
and platform-exit buttons behind a rationed spending allowance. It is the largest
contract and the most reachable.

**`FeastFeeLedger`** — one packed word per (week, quote, account): fees paid,
earned and referred, as three `uint80` fields. Written by the hook, read by
emissions and by the genesis grants. Who can write? Can a credit be recorded
without a fee, or twice?

**`FeastOracle`** — the tick history the hook and the pricer read. What does it
return with little or no history, and does every caller tell that from an answer?

**`FeastPricer`** — what a listed quote token, and the platform coin, are worth in
wrapped native. A fixed list, each quote with a pinned route of at most two v3
pools. **It never reverts on a price it cannot vouch for; it says so** with a
status, and the caller's written rule decides what that means. Check that claim
against every path through it, including the arithmetic.

**`FeastEmissions`** — 14.2% of the platform coin, paid weekly for 52 weeks by the
fees actually paid, earned and brought. `settle(n)` is permissionless, strictly
ordered and once-only per week; it prices every listed quote, computes
`min(value cap, token cap, remaining)`, splits by the week's weights into three
track pots, and may redirect a share to an escrow. Claims read a snapshot the week
was settled over and never the live pricer. **Ordering is the thing to hold in
mind: a week that cannot settle blocks every week after it.**

**`FeastGenesis` / `FeastGenesisGrants`** — the supply split, and partner grants
that unlock by referred fees the ledger prices, capped at the grant, counted once
per week.

**`FeastLaunchWindow`** — commitments in wrapped native, one settlement, pro-rata
claims, refunds if it cannot settle.

**`FeastPlatformSink`** — sells any asset but the platform coin at a price that
descends by halvings from a start price, held up by a decaying floor, and burns
everything it is paid. Anyone may take.

**`FeastConverter`** — hook-only. Moves a fee bucket through a pinned route of at
most three v3 pools to wrapped native, measuring each hop against the pool's own
time-weighted price and refusing a partial fill.

**`FeastVesting` / `FeastTeamVesting` / `FeastPlatformToken`** — linear vesting and
the platform coin itself.

## What the last two releases changed, and why that matters here

`v1.6.5` and `v1.6.6` closed five findings and added five guards. **New code is
the least-reviewed code**, so give these sites a full reading rather than a
confirming glance — and remember that a guard added to stop one failure can create
another:

- `FeastEmissions::settle` — the value cap now decides which side of a minimum is
  smaller **before** multiplying it out, using the top word of a 512-bit product;
  and a listed quote whose price is `Moved` is refused by name rather than counted
  as zero, but only when that quote carries fees in the week.
- `FeastPricer::_inVenueRange` — a square-root price outside the venue's
  stored-price domain `[MIN_SQRT_RATIO, MAX_SQRT_RATIO)` is `Unpriceable` in both
  readers.
- `FeastPlatformSink::take` — a cost no word can hold is `CostAboveLimit`
  saturated, guarded on the ceiling the cost rounds to and not only on its floor.
- `FeastConverter::_expectedAfterHop` — each step of a hop's expectation is
  `RouteExpectationTooLarge` when its result needs more than a word.

Ask of each: is the predicate exactly the condition it claims, is it applied on
every path that reaches the arithmetic, and does it refuse anything the protocol
needs to accept?

## Adversary classes to work through by name

Plainly, without inventing scenarios the code cannot reach:

- **Reentrancy** — the hook is called by the venue mid-swap and itself calls back
  into the venue inside a lock. Trace which state is written before which external
  call.
- **Oracle staleness and thin history** — `FeastOracle` and the v3 pools the
  pricer and converter read. What does each return with little or no history, and
  does the caller distinguish that from a real answer?
- **Arithmetic that cannot be written down** — `Math.mulDiv` carries its
  intermediate at 512 bits and reverts when its RESULT exceeds 256. Every such
  call in `src/` is supposed to have a bound a reviewer can check. Find one that
  does not, or one whose recorded bound is wrong.
- **Rounding direction** — integer division appears in the fee, the shares, the
  tip, the burn split, the emission pots, the grants and the sink's descent. In
  each, who gains the remainder, and can it be steered?
- **Access control** — every state-changing external function and its caller set.
  `factory`, `vault`, `poolManager`, `recorder`, `timelock`, the genesis key and
  the hook itself are the privileged names.
- **Ordering and liveness** — emissions settle in order; the sink's lot must stay
  takeable; the launch window must settle or refund. What can hold one of these
  up, for how long, and who can end it?
- **A frozen, blacklisting or sanctions-screening quote token** — quote tokens are
  upgradeable proxies whose issuer can stop transfers. Which paths touch the quote
  token, and what happens on each when it refuses?
- **Gas griefing on the buttons**, and **ordering around them** — the buttons are
  public and tipped.

## Boundaries, not defects

The venue does not invoke a hook's callbacks when the hook is itself the swapper.
Feast relies on this: the buy-back's own swap pays no feast fee and trips no feast
cap. `lib/infinity-core/src/libraries/Hooks.sol` carries the check. If you believe
this reliance is misplaced, show the construction.

The venue can be paused by its own operator and takes a share of the LP fee at a
rate its operator sets. Feast has no admin; the venue does.

The remaining declared boundaries are in the boundaries file the overlay names.
Closing a finding as `BOUNDARY` requires one of those ids.

## Output

Follow the output contract in the header and the overlay above — the tree pin
first, `DETERMINISTIC-TRIAGE`, `LENS-FINDINGS`, severity sections with `file:line`
evidence at the pinned commit, and the `VERDICT:` line last. If nothing meets the
bar, say so plainly rather than padding.
