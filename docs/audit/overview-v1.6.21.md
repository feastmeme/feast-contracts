# Feast — audit overview

Describes tag `v1.6.21-audit`, commit `e5c0a771107a8a17f510806bafd50bfe33035ec7` (`src/` tree `a4162ac4`). Written 2026-09-23.

Where a document and the code disagree, this file states what the code does and
names the document line. Everything behavioural cites `src/File.sol:line`.
Anything not confirmed against the code in this tree is marked `(unverified)`.

---

## 1. What Feast is

A creator mints a plain fixed-supply ERC-20, pairs it with a chosen quote token
(intended to be a tokenised-stock token) in one concentrated-liquidity pool, and
that happens in a single transaction. The liquidity seeded at creation can never
be removed. A hook takes 1% of every swap, on the quote leg only, and splits it
into four buckets whose shares are fixed in the creating transaction.

There is a second, separate thing: **FEAST**, the platform coin. It is launched
once, through a one-shot `genesis` call, with its own 24-hour uniform-price
launch auction, a 52-week emissions programme paid out of the fee ledger, and a
sink that buys FEAST back and burns it with the platform's 20% of every fee.

### The actors

| Actor | What it is | What it can do |
|---|---|---|
| **Coin creator** | Any address. Names itself in `create`. | Choose supply, quote, the self-burn and referrer shares, the opening price, and optionally a pre-buy of its own coin. After the transaction returns it can change nothing. |
| **Trader** | Anyone. | Swap. Pays 1% on the quote leg. |
| **Referrer** | Any address named in `hookData`. | Earn `referrerBps` of the fee on trades it brought. A wallet binds to one referrer for life on its first qualifying trade (`src/FeastHook.sol:617`). |
| **Guardian** | The team multisig. Immutable (`src/FeastGuardian.sol:44`). | Two powers only: stop new coin creation for ever, and pause outflows for at most 72 h at a time / 168 h over its life, expiring 90 days after genesis. It can move no balance. |
| **Genesis key** | One address, fixed in the factory's constructor (`src/FeastFactory.sol:261`). | Call `factory.genesis` exactly once (`src/FeastFactory.sol:364`) and `sink.schedule` exactly once (`src/FeastPlatformSink.sol:230`). Nothing else, before or after. |
| **Timelock** | OpenZeppelin `TimelockController`, 3 days, team multisig the only proposer. Package 2 only. | Three levers on `FeastEmissions` and nothing else (`src/FeastEmissions.sol:204,215,225`). |
| **Keepers** | Anyone. | `claim`, `claimCreator`, `claimReferrer`, `releasePlatformFees`, `buyBackAndBurn`, `collectLpFees`, `burnFilledCoin`, `settle`, `open`, `take`, `burnStray`, `settleLapsed`, `expire`, `burnExpired`, `burnUnearned`, `burnUnfilledSlot`, `burnRemainder`. All permissionless; each pays the recorded party, never the caller (except the buy-back tip). |

### The venue

PancakeSwap Infinity on BNB Smart Chain: a `Vault` that holds tokens and is the
ERC-6909, plus a `CLPoolManager` registered on it. Feast pools carry the Feast
hook, which registers five permissions —
`beforeInitialize | beforeSwap | afterSwap | beforeSwapReturnsDelta | afterSwapReturnsDelta`
(`src/FeastCLHookBase.sol:36-42`). The seven unregistered callbacks are omitted,
not stubbed. Tick spacing is 200 and the venue LP fee tier is 100
(`src/FeastConstants.sol:87,97`); both are packed into `poolKey.parameters`
(`src/FeastParameters.sol:23`).

Mainnet addresses the deploy scripts read: `CL_POOL_MANAGER`, `VAULT`,
`V3_FACTORY`, `WRAPPED_NATIVE` at `src/FeastGenesis.sol:21-24`.

### The hard properties

Each stated once. Source: `README.md`, checked against the code.

1. **No owner, no admin, no upgrade path, no `delegatecall`, no
   `selfdestruct`.** `tools/check-boundaries.py` fails the build on `onlyOwner`,
   `onlyRole`, `Ownable`, `AccessControl`, `initializer`, `upgradeTo`,
   `delegatecall`, `selfdestruct` in any shipped file. No contract in `src/` has
   an ownership surface; `FeastTeamVesting` inherits OpenZeppelin
   `VestingWallet`'s `Ownable` and disables `renounceOwnership`
   (`src/FeastTeamVesting.sol:69`) — that owner is the vesting beneficiary, not
   a protocol admin.
2. **Every economic parameter of a coin is fixed in its creating transaction.**
   Shares are validated once in `registerPool` (`src/FeastHook.sol:268-274`) and
   there is no setter anywhere for a share, a recipient, a price or a fee.
3. **Seeded liquidity can never be removed.** The lock is an absence: the hook
   registers no liquidity callbacks and exposes no withdrawal path. The only
   `modifyLiquidity` call the hook makes with a negative delta does not exist;
   `collectLpFees` moves liquidity by exactly zero (`src/FeastHook.sol:1729`).
4. **The fee is 1% of the quote leg, taken once per swap**
   (`FEE_PIPS = 10_000 / FEE_DENOMINATOR = 1_000_000`,
   `src/FeastConstants.sol:12-13`), split platform 20% / creator side 80%
   (`src/FeastConstants.sol:53-55`), with the creator side further divided into
   self-burn (default 20%, max 50%), referrer (default 10%, max 30%) and the
   creator's computed remainder (`src/FeastHook.sol:1842-1883`).
5. **The guardian is bounded on chain.** 72 h per freeze, 168 h lifetime budget,
   1 h minimum charge per pull, power gone 90 days after genesis
   (`src/FeastGuardian.sol:64,70,73,102`). After the sunset anyone may `expire()`
   a freeze left standing (`src/FeastGuardian.sol:322`) and `stopCreation` is the
   only power left (`src/FeastGuardian.sol:435`).
6. **The launch window is never freezable.** No `_requireUnfrozen` call exists in
   `src/FeastLaunchWindow.sol` — its refunds run on a clock.
7. **Supply is fixed.** `FeastToken` and `FeastPlatformToken` mint once in the
   constructor and have no mint entry point (`src/FeastToken.sol:44`,
   `src/FeastPlatformToken.sol:36`).

### What Feast does not control (stated in `README.md`, "What feast does not control")

- The venue's operator can pause the whole exchange, Feast's pools included.
- The venue takes a share of the LP fee at a rate its operator sets.
- A quote token can pause, blacklist or sanction. Feast holds accrued value as a
  vault claim rather than a token so this cannot brick swaps or corrupt
  accounting — but a claim in a frozen quote cannot be *paid out* until the
  freeze lifts. The entitlement survives; the payment waits.

---

## 2. System map

### Who calls whom

```
                          ┌──────────────────┐
   genesis key ──once──▶  │  FeastFactory    │ ◀── anyone: create()
                          └────────┬─────────┘
                                   │ registerPool / seedLiquidity /
                                   │ seedAuctionLiquidity / burnUnusedSeed
                                   ▼
  venue Vault ──lockAcquired──▶ ┌──────────────┐ ──record()──▶ FeastFeeLedger
  venue CLPoolManager ─────────▶│  FeastHook   │ ──write()────▶ FeastOracle
   (beforeInitialize/            │              │ ──convert()──▶ FeastConverter ──▶ Pancake v3
    beforeSwap/afterSwap)        └──────┬───────┘
                                        │ releasePlatformFees (quote, as-is)
                                        ▼
                                 FeastPlatformSink ◀─schedule()── genesis key
                                        ▲                 ▲
   FeastLaunchWindow ──settle fee───────┘                 │ take(): anyone pays FEAST, burned
        │  seedWindowPool / seedWindowOpening → FeastFactory → FeastHook
        │
        └── commit / withdraw / claim / refund : anyone

  FeastFactory ──startClock()──▶ FeastGuardian ◀── guardian: freeze/unfreeze/stopCreation
                                       ▲          ◀── anyone: settleLapsed/expire
        every guarded contract ────────┘ (isFrozenAll / frozenSeconds / allUnfrozenAt / sunsetAt)

  FeastFeeLedger ◀──reads── FeastEmissions ──reads──▶ FeastPricer ──reads──▶ FeastOracle, v3 pools
                                   ▲
                                   └── FeastGenesisGrants (referredValue, settledCount)

  FeastFactory ──deploy()──▶ FeastPlatformTokenDeployer ──▶ FeastPlatformToken
  FeastFactory ──createAllocation()──▶ FeastVesting          (creator pre-buy)
  FeastFactory ──transfer 25%──▶ FeastTeamVesting
```

### Deployment topology

| Contract | Deployed | Count |
|---|---|---|
| `FeastOracle`, `FeastConverter`, `FeastFeeLedger`, `FeastHook`, `FeastVesting`, `FeastPlatformTokenDeployer`, `FeastFactory`, `FeastGuardian` | Package 1, with the factory | once |
| `TimelockController`, `FeastPricer`, `FeastEmissions`, `FeastGenesisGrants`, `FeastPlatformSink` | Package 2, at the opening | once |
| `FeastLaunchWindow`, `FeastTeamVesting` | At the TGE, by the genesis key | once |
| `FeastToken` | Inside every `create` (CREATE2, creator's salt, `src/FeastFactory.sol:321`) | per coin |
| `FeastPlatformToken` | Inside `genesis`, via the deployer (CREATE2, fixed salt, `src/FeastPlatformTokenDeployer.sol:35`) | once |

Everything a contract needs from another is an `immutable` constructor argument.
There is no registry and no setter for a collaborator address, with one
exception: `FeastEmissions.pricer` is replaceable by the timelock
(`src/FeastEmissions.sol:225`).

> **Docs vs code.** `README.md`'s deployment recipe lists
> `FeastHook(poolManager, vault, factory*, oracle, ledger, converter)` and
> `FeastVesting(factory*)`. The code takes a seventh hook argument `guardian_`
> (`src/FeastHook.sol:66-79`) and a second vesting argument `guardian_`
> (`src/FeastVesting.sol:50`), and `FeastGuardian` does not appear in the
> recipe at all. The code is authoritative; the README recipe predates the
> guardian.

### Trust boundaries — every privileged caller

| Caller | Entry point | Check |
|---|---|---|
| venue `CLPoolManager` | `beforeInitialize`, `beforeSwap`, `afterSwap` | `src/FeastCLHookBase.sol:56` |
| venue `Vault` | `FeastHook.lockAcquired` | `src/FeastCLHookBase.sol:61` |
| venue `Vault` | `FeastFactory.lockAcquired` | `src/FeastFactory.sol:817` |
| factory | `FeastHook.registerPool` | `src/FeastHook.sol:267` |
| factory | `FeastHook.seedLiquidity` | `src/FeastHook.sol:1072` |
| factory | `FeastHook.seedAuctionLiquidity` | `src/FeastHook.sol:1114` |
| factory | `FeastHook.burnUnusedSeed` | `src/FeastHook.sol:1158` |
| factory | `FeastVesting.createAllocation` | `src/FeastVesting.sol:71` |
| factory | `FeastPlatformTokenDeployer.deploy` | `src/FeastPlatformTokenDeployer.sol:33` |
| factory | `FeastGuardian.startClock` (once) | `src/FeastGuardian.sol:195-196` |
| hook | `FeastFeeLedger.record` | `src/FeastFeeLedger.sol:112` |
| hook | `FeastOracle.write` | `src/FeastOracle.sol:62` |
| hook | `FeastConverter.convert` | `src/FeastConverter.sol:189` |
| v3 pool (transient) | `FeastConverter.pancakeV3SwapCallback` | `src/FeastConverter.sol:522` |
| genesis key (once) | `FeastFactory.genesis` | `src/FeastFactory.sol:364-366` |
| genesis key (once) | `FeastPlatformSink.schedule` | `src/FeastPlatformSink.sol:230-231` |
| the one launch window `genesis` named | `FeastFactory.seedWindowPool` | `src/FeastFactory.sol:715` |
| the one launch window `genesis` named | `FeastFactory.seedWindowOpening` | `src/FeastFactory.sol:732` |
| a gated pool's registered opener | `beforeInitialize` widening | `src/FeastHook.sol:409` |
| guardian | `FeastGuardian.freeze` / `unfreeze` / `stopCreation` | `src/FeastGuardian.sol:207` |
| team multisig (= `guardian.guardian()`) | `FeastGenesisGrants.assignPartner` | `src/FeastGenesisGrants.sol:159-160` |
| creator (self) | pre-buy inside `create` | `src/FeastFactory.sol:300-302` |
| claimant (self) | `FeastHook.claimAsBnb` route choice | `src/FeastHook.sol:1423` |
| timelock | `FeastEmissions.setValueRatioBps` / `setRedirect` / `setPricer` | `src/FeastEmissions.sol:199` |
| wrapped native (only) | `FeastLaunchWindow` native `receive` | `src/FeastLaunchWindow.sol:155` |

That table is the complete set of `msg.sender` comparisons in `src/`
(`grep -n "msg.sender" src/*.sol`). Invariant `P20` pins it: "no state-changing
function has a privileged caller beyond the declared set"
(`audit/invariants.yaml`).

---

## 3. Lifecycle

### 3.1 Coin creation (one transaction)

`FeastFactory.create(CreateParams)` — `src/FeastFactory.sol:271`. In order:

1. Refuse if the guardian stopped creation, or if an ALL freeze is live
   (`:282-283`).
2. Refuse a slippage bound with no pre-buy (`:287`); refuse a pre-buy whose
   caller is not `p.creator` (`:300`) — without this, a creator's approval to the
   factory is spendable by a stranger on a coin of the stranger's choosing.
3. Refuse `supply > MAX_SUPPLY = 2^128 - 1` (`:307`), a zero creator (`:313`), a
   codeless quote (`:314`).
4. `new FeastToken{salt}` — whole supply minted to the factory (`:321`); refuse
   coin == quote (`:322`).
5. Build the pool key, `hook.registerPool(...)` with `openAt = 0`, `opener = 0`
   (`:327`), then `poolManager.initialize` (`:328`).
6. `_seed` — the whole supply goes to the hook, one single-sided position from
   the creator's start tick to the far usable edge; anything the position did not
   consume is burned, and more than 1% unconsumed reverts `PoolTooShallow`
   (`:871-886`).
7. Optional pre-buy (`:792-812`): quote pulled from the creator, swapped through
   the *factory* as the venue caller so the ordinary fee path fires, capped at
   `MAX_PREBUY_BPS_OF_SUPPLY = 2_000` (20% of supply) measured in coin received
   (`:802-803`), then handed to `FeastVesting` with the creator's chosen duration.
8. Record and emit `CoinCreated` with the metadata digest (`:340`).

### 3.2 The opening window

The per-wallet cap is **0.5% of supply** (`CAP_BPS_OF_SUPPLY = 50`,
`src/FeastConstants.sol:105`), denominated in coin *bought*, enforced in
`_afterSwap` against `tx.origin` (`src/FeastHook.sol:952-960`). It binds while
`servedBlocks <= CAP_BLOCKS = 2` (`src/FeastConstants.sol:102`), and the counter
is armed at the pool's **first served public swap** — not at creation, not at
initialisation (`src/FeastHook.sol:688-698`). That is deliberate: a window armed
in a block coordinate can be spent by a freeze, and a frozen-*block* counter
cannot be computed on chain (a contract cannot observe its chain's block rate).
Nobody is exempt: `isExempt` is `pure … return false` (`src/FeastHook.sol:395`).
Sales are never capped (`:956`).

The creator's pre-buy is excluded from both the arming and the cap, recognised
structurally by (the factory is the swapper) AND (this pool was registered in
this transaction, a transient slot) — `src/FeastHook.sol:539-545, 693, 952`. It
is bounded instead by `MAX_PREBUY_BPS_OF_SUPPLY`, and it is public from block one
through `prebuyOf(coin)` (`src/FeastFactory.sol:769`) and the `CreatorPrebuy`
event; a duration of zero means "sellable at any time".

### 3.3 Trading through the hook

Four fee branches, because which currency the venue calls "specified" depends on
`zeroForOne` and the sign of `amountSpecified`. Two are charged in `beforeSwap`
(`src/FeastHook.sol:447,703`), two in `afterSwap` from realised deltas
(`src/FeastHook.sol:1011-1026`).

- **The fee never touches a token contract on the swap path.** It is minted as an
  ERC-6909 vault claim (`src/FeastHook.sol:1807`). A paused or screening quote
  token has nothing to refuse.
- **Buckets** (`_bank`, `src/FeastHook.sol:1830-1884`): `selfBurn = amount *
  selfBurnBps / BPS`; `platform = amount * PLATFORM_BPS / BPS`; `commission =
  amount * referrerBps / BPS` only if a referrer applies; the creator takes the
  arithmetic remainder, so the four always sum to the fee exactly. A burn-address
  creator's remainder is added to the self-burn bucket instead
  (`:1860-1863`).
- **Partial fills.** On the two branches where the quote is the specified
  currency, a swap the venue stops early is *refused*
  (`PartialFillNotSupported`, `src/FeastHook.sol:984-986`) rather than charged on
  a trade that did not happen. On the other two the fee comes from realised
  deltas and is always right.
- **The internal fill** (`src/FeastHook.sol:714-721, 799`): an exact-input *sale*
  is offered first to the pool's own buy-and-burn bucket at spot, inside the TWAP
  bound and the button's allowance. The coin so bought is held as a claim and
  burned by `burnFilledCoin` (`:760`). No sale is refused by it; a request of
  `type(int256).min` is not filled (`:714`).
- **`Trade` event**: exactly one per swap, with the trader's own amounts, emitted
  on every branch (`src/FeastHook.sol:989, 1032`), plus one for a buy-back press
  (`:1619`) attributed to the hook itself.
- **Referrer binding** (`_referrerFor`, `src/FeastHook.sol:547-625`):
  - A protocol-initiated swap introduces nobody — the hook itself, a gated pool's
    opener, or the factory's pre-buy (`:574-579`).
  - An existing binding is supreme; `hookData` is not consulted (`:586-587`).
  - A referrer equal to `tx.origin` is no referral (`:597`).
  - The 64-byte form binds for life, once, only when the named wallet *is* the
    signer (`:600-619`). The burn address may not be bound to (`:608`).
  - The 32-byte legacy form pays for that trade only and never binds (`:624`).
  - There is no rebinding and no setter.

### 3.4 The weekly fee ledger

`FeastFeeLedger.record` — hook-only (`src/FeastFeeLedger.sol:112`). Weeks turn at
Monday 00:00 UTC (`WEEK_LENGTH = 7 days`, `WEEK_ALIGNMENT = 3 days`,
`src/FeastGenesis.sol:34,37`). Three tracks — paid / earned / referred — each
credited the **whole** fee, per week, per quote token, packed three `uint80`s to
a word. A track whose `uint80` total would overflow is simply not credited, on
neither the account nor the total, so "a total is exactly the sum of its
accounts" holds without exception (`src/FeastFeeLedger.sol:116-143`). Nothing
here can revert a swap. A trade before a gated pool opens is recorded nowhere
(`src/FeastHook.sol:1817`).

### 3.5 The platform coin

**Genesis ceremony (v1.6.21 order).** `FeastFactory.genesis` —
`src/FeastFactory.sol:363`. `genesisDone` is set before anything else (`:366`).

Order of operations, and the three checks v1.6.21 added:

1. `_requireRecipient(window, ROLE_LAUNCH_WINDOW)`, `(teamVesting,
   ROLE_TEAM_VESTING)` — each must have code, report the right role and serve the
   predicted platform coin (`:378-379, 623-635`).
2. `windowClose = window.endsAt()`; must be **strictly** in the future and at
   most 30 days out (`:421-425`). Strictness closes `refunded-weight-revival`:
   genesis at the closing second would revive a window that had begun refunding.
3. `openAt` is **derived**, `windowClose + SETTLE_GRACE`, and the passed value is
   only a checksum (`:436-437`).
4. `teamVesting.start()` must equal `windowClose`, asked through `try`
   (`:447-453`).
5. **NEW (v1.6.21)** `window.poolKey()` must hash to `platformPoolKey().toId()`
   (`:471-478`). Fixes `genesis-window-key-unchecked`.
6. **NEW (v1.6.21)** `teamVesting.guardian()` must equal this deployment's
   guardian (`:488-494`). Fixes `team-wallet-guardian-unchecked`.
7. `_requireRecipient(emissions, ROLE_EMISSIONS)`, `(grants, ROLE_GRANTS)`
   (`:497-498`).
8. **NEW (v1.6.21)** if `platformSink` already has code, it must report the sink
   role **and** already be armed: `sink.opensAt() == windowClose` (`:500-526`).
   Fixes `sink-arming-unenforced`. **This is the check that reorders the
   ceremony: `sink.schedule(window)` must now run before `genesis`, not after.**
   A sink with no code yet is still admitted and still unasked; the hook asks
   again at the exit (`src/FeastHook.sol:1512`).
9. Mint via the deployer, assert the whole supply is in custody (`:528-533`).
10. `registerPool` with `openAt` and `opener = window` — **the pool is neither
    initialised nor seeded here**, because the price it must open at is the price
    the auction has not cleared yet (`:537-555`).
11. Split: team `2_500` bps, grants `80` bps, emissions `1_420` bps, and the pool
    takes the remainder so the four sum to the supply exactly (`:557-561`). The
    pool's 60% is transferred to the **window**, not to the pool (`:566`).
12. `openingLiquidityFor` is asked of the window with its own code, so a price
    too near the usable edge is refused now rather than 25 hours later (`:578`).
13. `guardian.startClock()` — the 90 days start here, not at deploy (`:587`).
14. Transfers to team vesting / emissions / grants (`:589-591`), records, emits.

**The launch window** (`src/FeastLaunchWindow.sol`). 24 hours
(`WINDOW_DURATION`), withdrawals allowed until `lockAt = endsAt - WINDOW_LOCK`
(1 hour, `src/FeastGenesis.sol:144,146`). `commit()` wraps BNB (`:169`);
`withdraw()` unwraps and pays out (`:179`). `settle()` is permissionless in the
exclusive hour `[endsAt, openAt)` (`:207, 475-479`):

- **No commits:** the whole holding is seeded single-sided at the tick the
  genesis key's price floored to, `tranche = 0` (`:216-243`).
- **With commits:** `fee = total / 100` to the sink; `net = total - fee`;
  `sold = coinHeld × WINDOW_TRANCHE_BPS(5_000) / BPS`; the clearing price is
  `p* = net / sold` as a Q96 square root with the radicand rounded up; the pool
  is initialised at exactly `p*`; both sides are seeded around it as one
  full-range position (`:249-317`).
- `settled = true` is written only after both positions are placed (`:329`).
- **Failure route:** if the window cannot settle — mis-wired opener, or the grace
  hour has passed — `_refundable()` becomes true and every commit is returned in
  full in wrapped native (`:460-467, 481-485`). `_canSettle` and `_refundable` are
  exact complements at every second.
- `claim(account)` pays the pro-rata share of `tranche`; the claimant who
  completes the committed weight receives the exact remainder (`:443-456`).

**Emissions** (`src/FeastEmissions.sol`). Budget = 14.2% of supply, fixed in the
constructor (`:170`). 52 weeks; week 1 is the factory's opening ledger week. Week
`n` emits `min(value cap, token cap, remaining)`, where the token cap falls
linearly (`budget × (53 − n) / 1378`, `:247`) and the value cap is
`valueRatioBps` (default 15%, band 5–20%) of the week's fees priced in FEAST.
Track weights are referrer/trader/creator 40/45/15 for weeks 1–8 and 20/65/15
after (`src/FeastGenesis.sol:123-128`). `settle(n)` is permissionless, in order,
once, after the week closes, and refuses under a freeze (`:266-272`). The
pricing grace is three days of **open** time measured from
`max(weekClose, guardian.allUnfrozenAt())`. Claims open only once the platform
pool has opened (`:584-587`); a settled week is claimable for 12 weeks, extended
by every frozen second since it settled (`:611`). What is unclaimed at expiry
burns (`:657`); what was never emitted burns after week 52 (`:685`).

**The platform sink** (`src/FeastPlatformSink.sol`). Every asset the hook
releases here is offered for FEAST at a published price that descends; whoever
brings FEAST takes the asset and the FEAST is burned on the spot (`:663-666`).
A lot's `anchor` starts at `SINK_START_PRICE_Q128 = 2^192` when someone `open`s
it (`:288`) and halves every hour, linearly within each half-life. `open` is
permissionless but refuses unless the platform coin has code and
`block.timestamp >= opensAt`, and refuses a lot a descent already prices
(`:271-301`). The anchor is clamped at `ANCHOR_CEILING = 2^224` (`:168, 604`) —
a bound drawn from the money, not from the sale arithmetic: at that price
FEAST's entire `1e27` supply buys about a hundredth of one raw unit. After a
sale the price never falls below that sale's price halved six times, on a floor
clock of its own that halves daily. A lot holding at least twice what it held
when its descent began is a different lot and is priced from the start price
again; only `open` sets the size a descent prices. `take` re-anchors by the
share of the **lot** consumed, not by the share of the balance carried away
(`:602-605`) — the v1.6.20 change that killed the refill pump. `burnStray()`
burns any FEAST held here; FEAST is never for sale (`:670`). Every clock here
subtracts `guardian.frozenSeconds()`, so a freeze cannot walk a price down while
nobody can trade.

**The converter** (`src/FeastConverter.sol`). Hook-only (`:189`). Converts a
claimant's quote to wrapped native along a **caller-supplied** route of at most
`MAX_HOPS = 3` Pancake v3 pools (`:124`). No token may appear twice (`:194-199`);
the route must end in wrapped native (`:200`). Each hop must have oracle
cardinality ≥ 2 and ≥ `MIN_OBSERVATION_AGE = 300 s` of history, and spot within
`MAX_TICK_DEVIATION = 300` ticks of its own average, or the hop is refused
(`:346`). What the route spends is what **arrived**, measured (`:229-231`), so a
transfer-taxed quote is converted for what arrived and a stray balance is never
spendable.

**The oracle** (`src/FeastOracle.sol`). A 1024-slot cumulative-tick ring, written
only by the hook, at most once per block, never reverting on the swap path
(`:61-69`). It **refuses rather than degrades**: below `MIN_OBSERVATION_AGE` it
reverts instead of handing back a spot price dressed as an average
(`TWAP_WINDOW = 600 s`, `src/FeastConstants.sol:201,204`).

**Vesting and grants.** `FeastVesting` holds each creator's pre-buy, linear from
the creating second, one allocation per coin, recipient fixed
(`src/FeastVesting.sol:70-80`). `FeastTeamVesting` is OpenZeppelin's
`VestingWallet`, 36 months of 30.4375 days (`TEAM_VESTING_DURATION = 94_672_800`,
`src/FeastGenesis.sol:155`), no cliff, from the window's close.
`FeastGenesisGrants` holds 8 × 0.1%, unlocking by `min(grant, grant × referred /
TARGET_NATIVE)` over the first 26 emission weeks
(`src/FeastGenesisGrants.sol:279-283`); what is not unlocked burns.

### 3.6 The guardian's freeze semantics

`src/FeastGuardian.sol`.

| Bound | Value | Line |
|---|---|---|
| One freeze | `FREEZE_MAX = 72 hours` | `:64` |
| Lifetime budget | `FREEZE_BUDGET = 168 hours` | `:70` |
| Minimum charge per pull | `MIN_FREEZE_CHARGE = 1 hour` → at most 168 pulls ever | `:102` |
| Freeze power ends | `GUARDIAN_SUNSET = 90 days` after `startClock()` | `:73` |

`freeze()` charges the whole grant up front, so the ceiling is exact at every
instant (`:254-262`). It refuses after the sunset (`:223`), while a freeze is
live (`:226`), **in the block an `unfreeze` cleared one** (`:247`), while a
lapsed freeze is unsettled (`:252`), and on a spent budget (`:255`).
`unfreeze()` refunds only the tail above the minimum charge (`:276-280`).
`settleLapsed()` is **permissionless** (`:311`): a freeze that simply runs out
stamps no block, so it gets a transaction of its own and `freeze` refuses until
someone calls it — if only the guardian could settle, it could block its own
brake. `expire()` is permissionless after the sunset and clears a freeze left
standing (`:322`). `stopCreation()` does **not** sunset (`:435`); after day 90
it is the only power left, and it cannot move a balance or touch an existing
pool.

Consumers read three questions: `isFrozenAll()` on the hot swap path,
`frozenSeconds()` for any deadline a freeze can eat, and `allUnfrozenAt()` for
"has enough open time passed since the world restarted". `frozenUntil`,
`frozenFrom`, `allUnfrozenTotal` and `lastUnfrozenBlock` share one storage slot
so the second read is warm (`:120-144`).

Nine guarded call sites in the hook, plus `FeastEmissions`, `FeastPlatformSink`,
`FeastVesting`, `FeastTeamVesting`, `FeastGenesisGrants`. The launch window is
not guarded at all.

---

## 4. Contract by contract

Every contract in `src/`: **no owner, no admin, no proxy, no upgrade path, no
initializer.** Stated once here and repeated per contract only where something
needs qualifying.

### 4.1 `FeastFactory` (`src/FeastFactory.sol`, 50 KB)

**Purpose.** Mints a coin, builds its pool key, registers it with the hook,
initialises and seeds it, optionally executes the creator's pre-buy, and records
it. Separately, it performs the one-shot platform-coin genesis.

**State it owns.** `_coins[]`, `_coinInfo`, `_prebuys`, `genesisDone`,
`platformCoin`, `platformSink`, `_platformWindow`, `_platformKey`,
`_platformOpening`. Immutables: `poolManager`, `vault`, `hook`, `vesting`,
`platformTokenDeployer`, `wrappedNative`, `genesisKey`, `guardian` (read from the
hook so it cannot drift, `:266`).

| Caller | Entry point | Refuses |
|---|---|---|
| anyone | `create` | creation stopped; ALL freeze; pre-buy by a non-creator; supply > `2^128-1`; zero creator; codeless quote; coin == quote; pre-buy > 20% of supply or below `minCoinsOut`; seed leaving > 1% unconsumed |
| genesis key, once | `genesis` | wrong caller; second call; any recipient that is codeless, reports the wrong role or serves another coin; window close not strictly future or > 30 days out; `openAt` disagreeing with the derivation; team vesting start ≠ window close; window pool key ≠ platform pool key; team vesting guardian ≠ this guardian; a coded sink not armed to the window close; supply not in custody; opening price with no usable tick |
| the named window | `seedWindowPool`, `seedWindowOpening` | any other caller; unset window |
| the vault | `lockAcquired` | any other caller |
| anyone | `predictCoin`, `predictPlatformCoin`, `platformPoolKey`, `poolKeyFor`, `listCoins`, `getCoin`, `coinAt`, `coinCount`, `prebuyOf`, `platformOpening` | views |

**Can never.** Move a coin's liquidity, change a share, a recipient or a price;
run `genesis` twice; create a coin while the guardian has stopped creation.

**Invariants.** `P9` (supply routed 60/25/14.2/0.8, nothing remains in the
factory), `P25` (genesis signs a price, not a tick or a liquidity), `P26` (only
the creator may ask for the creator's pre-buy), `P29` (creation once stopped
stays stopped). Tests: `test/FeastFactory.t.sol`, `test/FeastGenesis.t.sol`,
`test/FeastPrebuy.t.sol`.

### 4.2 `FeastLaunchWindow` (`src/FeastLaunchWindow.sol`)

**Purpose.** A 24-hour uniform-price auction for the platform coin's 60%. It is
the platform pool's registered opener: the pool does not exist until `settle`
initialises it at the clearing price.

**State it owns.** `committed`, `total`, `settled`, `tranche`, `claimedWeight`,
`claimedAmount`, `claimedBy`, `_key`. Immutables: `wrappedNative`,
`platformCoin`, `vault`, `poolManager`, `hook`, `factory`, `startsAt`, `endsAt`,
`lockAt`.

| Caller | Entry point | Refuses |
|---|---|---|
| anyone | `commit` (payable) | outside `[startsAt, endsAt)`; zero value |
| committer | `withdraw` | outside `[startsAt, lockAt)`; more than committed (checked subtraction) |
| anyone | `settle` | already settled; outside the exclusive hour; the hook's opener is not this contract; nothing to sell; a clearing price the venue cannot represent |
| anyone | `claim(account)` | not settled; nothing committed; already claimed |
| anyone | `refund(account)` | settled; not yet refundable; nothing committed |
| wrapped native | native `receive` | any other sender |
| anyone | `poolKey`, `clearingPrice`, `openingLiquidityFor`, `genesisRole` | views |

**Can never.** Be frozen by the guardian (no `_requireUnfrozen` anywhere in the
file); settle twice; pay a committer more than the tranche.

**Invariants.** `P17`, `P21` (every commit clears at one price; the pool opens at
exactly that price), `P22` (the failure routes stay reachable), `P24` (after
settlement the pool is ONE full-range position). Tests:
`test/FeastWindowAuction.t.sol`, `test/FeastPlatformExit.t.sol`.

### 4.3 `FeastHook` (+ `FeastCLHookBase`) (`src/FeastHook.sol`, 105 KB; `src/FeastCLHookBase.sol`)

**Purpose.** The economics. Takes the 1% on the quote leg, splits it into four
buckets as vault claims, records the ledger, writes the oracle, holds the
permanently locked positions, and exposes the permissionless payout and
buy-back paths.

`FeastCLHookBase` is registration and access control only: the permission bitmap
(`:36`), `onlyPoolManager` / `onlyVault` (`:55, 60`), and the default
"only the factory may initialise a pool bearing this hook" (`:134`).

**State it owns.** `_pools[poolId]` (coin, orientation, creator, the two bps,
`openAt`, `opener`, `perWalletCap`, `servedBlocks`, `lastServedBlock`, the
accrual/paid running totals, the allowance, the seeded range),
`_referrerPending`, `_purchased`, `_referrerOf`. Immutables: `poolManager`,
`vault`, `factory`, `oracle`, `ledger`, `converter`, `guardian`.

| Caller | Entry point | Refuses |
|---|---|---|
| pool manager | `beforeInitialize` | any initialiser but the factory or a gated pool's registered opener (`:409`); a pool nobody registered (`:414`) |
| pool manager | `beforeSwap` / `afterSwap` | while frozen (`:637`); before `openAt` for anyone but the opener (`:690`); a purchase over the per-wallet cap in the opening blocks (`:958`); a partial fill on a specified-quote branch (`:985`) |
| vault | `lockAcquired` | any other caller (`src/FeastCLHookBase.sol:61`) |
| factory | `registerPool` | shares out of band; a gate that is half-set or longer than 14 days; a pool already registered; a coin not in the key |
| factory | `seedLiquidity`, `seedAuctionLiquidity`, `burnUnusedSeed` | any other caller; a second seed (`AlreadySeeded`); a creator-path seed that would need quote |
| anyone | `claimCreator`, `claimReferrer`, `claim` | while frozen; pays at most `MAX_SETTLEMENT` and leaves the remainder |
| the claimant only | `claimAsBnb` | `msg.sender != account` (`:1423`) — choosing the route needs judgement |
| anyone | `releasePlatformFees` | while frozen; a sink with no code; a sink that does not report the sink role for this platform coin (`:1512`) |
| anyone | `buyBackAndBurn` | while frozen; before `openAt`; nothing accrued; zero allowance; spot too far from the average; a press that buys nothing |
| anyone | `collectLpFees` | while frozen; nothing seeded |
| anyone | `burnFilledCoin` | while frozen |
| anyone | views (`poolInfo`, `claimable`, `spendingAllowance`, `referrerOf`, `perWalletCap`, `capBinds`, `purchasedDuringOpening`, `servedBlocks`, `isExempt`, …) | — |

**Can never.** Remove seeded liquidity — there is no withdrawal path, and
`test_noWithdrawalPathExistsOnTheHook` requires eight plausible signatures to
fail to resolve. Change a share or a recipient. Rebind a wallet's referrer. Spend
more than `ALLOWANCE_CAP_BPS + ALLOWANCE_BPS_PER_HOUR = 20%` of an accrued bucket
in any sliding hour.

**Invariants.** `P3`, `P4`, `P5`, `P6`, `P7`, `P10`, `P11`, `P13`, `P23`, `P27`.
Tests: `test/FeastBuckets.t.sol`, `test/FeastFeeTake.t.sol`,
`test/FeastAttribution.t.sol`, `test/FeastGate.t.sol`, `test/FeastCaps.t.sol`,
`test/FeastInternalFill.t.sol`, `test/FeastTradeEvent.t.sol`,
`test/FeastReferrerBinding.t.sol`, `test/FeastBuyback.t.sol`,
`test/FeastIsolation.t.sol`.

### 4.4 `FeastFeeLedger` (`src/FeastFeeLedger.sol`)

**Purpose.** The weekly, per-quote record of who paid, whose coin earned and who
referred — the only source the emissions and the grants divide tokens against.

**State.** `_totals[week][quote]`, `_credits[week][quote][account]`, both packed
three `uint80`s to a word. Immutable: `recorder` (the hook).

| Caller | Entry point | Refuses |
|---|---|---|
| hook | `record` | any other caller (`:112`) |
| anyone | `totals`, `credit`, `weekOf`, `currentWeek`, `weekStart` | views |

**Can never.** Revert a swap; be corrected after the fact; credit a track whose
80-bit total would overflow (it silently skips that track, on neither side, so
the total always equals the sum of its accounts).

**Invariants.** `P1`, `P3`. Tests: `test/FeastFeeLedger.t.sol`,
`test/FeastAccounting.t.sol`.

### 4.5 `FeastPricer` (`src/FeastPricer.sol`)

**Purpose.** What each listed quote token, and FEAST itself, is worth in wrapped
native. Read by emissions at settlement.

**State.** `_quotes[]` and `_routes[quote]`, both written once in the
constructor and never again. Immutables: `wrappedNative`, `oracle`,
`poolManager`, `platformCoin`, `platformPoolId`, `_platformIsCurrency0`.

| Caller | Entry point | Refuses |
|---|---|---|
| anyone | `priceQ128`, `platformPerNativeQ128`, `quotes`, `routeOf` | views; return `Unpriceable` / `Moved` instead of reverting |

Constructor refuses an empty route, a route longer than `MAX_HOPS`, a route that
does not connect or does not end in wrapped native, a quote listed twice, a route
for wrapped native itself, or any token that is not 18-decimal
(`:90-108`).

**Can never.** Be reconfigured. A new list means a new pricer, installed by the
timelocked lever on `FeastEmissions`. Routes are pinned, never supplied by a
caller, which is what forecloses attacker-chosen-route pricing.

**Invariants.** `P14` (the quote list is fixed at settlement). Tests:
`test/FeastOracle.t.sol`, `test/FeastEmissions.t.sol`.

### 4.6 `FeastPlatformSink` (`src/FeastPlatformSink.sol`)

**Purpose.** Where the platform's 20% goes. Each asset is offered for FEAST at a
descending published price; FEAST paid in is burned immediately. No oracle, no
route, nothing to manipulate.

**State.** `opensAt`, `_lots[asset]` (`anchor`, `anchoredAt`, `frozenAtAnchor`,
`offered`, `floorBase`, `lastSaleAt`, `frozenAtSale`). Immutables:
`platformCoin`, `genesisKey`, `guardian`.

| Caller | Entry point | Refuses |
|---|---|---|
| genesis key, once | `schedule(window)` | any other caller (`:230`); a second call; a window that is not a launch window or serves another coin; a close already past or more than 14 days out |
| anyone | `open(asset)` | while frozen; the platform coin itself; a platform coin with no code; before `opensAt`; an empty lot; a lot a descent already prices |
| anyone | `take(asset, amountOut, maxCoinIn)` | while frozen; zero out; more than held; a cost above `maxCoinIn`; a cost no word can hold (named, not a panic) |
| anyone | `burnStray` | while frozen |
| anyone | `priceQ128`, `lot`, `genesisRole` | views |

**Can never.** Sell FEAST; hold a position it can be talked out of at a price
nobody set; run a descent while the coin cannot be obtained; put a lot beyond
every buyer — the anchor is clamped at `2^224`.

**Invariants.** `P19`, and `P7` at the other end of the pipe. Tests:
`test/FeastBuyback.t.sol`, `test/FeastPackageTwo.t.sol`,
`test/FeastPlatformExit.t.sol`.

### 4.7 `FeastEmissions` (`src/FeastEmissions.sol`)

**Purpose.** The first year: 14.2% of FEAST paid weekly for 52 weeks to traders,
creators and referrers, by the fees they actually paid, earned and brought.

**State.** `pricer`, `settledCount`, `remaining`, `liabilities`, `_ratio`,
`_redirect` (both checkpointed), `_weeks[n]`, `_weekQuotes[n]`, `priceOf`,
`claimed`. Immutables: `ledger`, `hook`, `platformCoin`, `platformPoolId`,
`timelock`, `firstWeek`, `budget`, `guardian`.

| Caller | Entry point | Refuses |
|---|---|---|
| timelock | `setValueRatioBps` | outside 500–2000 bps (`:205`); any other caller |
| timelock | `setRedirect` | above 5000 bps, or a bps/escrow pair that disagrees (`:216`) |
| timelock | `setPricer` | a pricer with no code (`:226`) |
| anyone | `settle(n)` | while frozen; out of range; out of order; before the week closed; inside the pricing grace when a listed quote cannot be priced |
| anyone | `claim`, `claimMany` | while frozen; claims not open; unsettled; expired; already claimed |
| anyone | `burnExpired`, `releaseRedirect`, `burnRemainder` | while frozen; not settled / not expired / already done / not finished |
| anyone | `owed`, `referredValue`, `weekInfo`, `settledQuotes`, `tokenCap`, `weights`, `expiryOf`, `claimsOpen` | views |

**Can never.** Emit more than `remaining`; touch a settled week (all three levers
apply from the next ledger week, the pricer from the next settlement); let a
freeze eat a claimant's 12-week window (`expiryOf` adds every frozen second since
settlement, `:611`).

**Invariants.** `P13`, `P14`, `P15`. Tests: `test/FeastEmissions.t.sol`,
`test/FeastPackageTwo.t.sol`.

### 4.8 `FeastConverter` (`src/FeastConverter.sol`)

**Purpose.** A hook-only route from a claim denominated in a quote token to
wrapped native, for claimants who want it. Bounded in ticks, not in token
amounts, so no GPL tick mathematics is needed.

**State.** `_activePool` (transient within one conversion). Immutables:
`v3Factory`, `wrappedNative`, `hook`.

| Caller | Entry point | Refuses |
|---|---|---|
| hook | `convert` | any other caller (`:189`); an empty route or > 3 hops; a route that revisits a token; a route not ending in wrapped native; a hop whose pool has cardinality < 2 or < 300 s of history; a hop whose spot is > 300 ticks from its average; a leg that delivered nothing; a hop asking more than it brought |
| the active v3 pool | `pancakeV3SwapCallback` | any other caller (`:522`) |

**Can never.** Choose a route itself; spend a stray balance (B2: tokens sent here
belong to nobody and cannot be recovered — a declared boundary).

**Invariants.** carried under `V1-CARRIED`. Tests: `test/FeastConverter.t.sol`,
`test/FeastConverterBounds.t.sol`, `test/FeastConverterCardinality.t.sol`,
`test/FeastConverterRealQuote.t.sol`.

### 4.9 `FeastGenesis` (`src/FeastGenesis.sol`)

Not a contract — a `library` of constants. Every number v1.6 adds, plus the
deployment placeholders the scripts refuse to run while unset (`GENESIS_KEY`,
`TEAM_BENEFICIARY`, `TEAM_MULTISIG`, `TARGET_NATIVE`, `FACTORY_OPENING`,
`WINDOW_START`, `PLATFORM_OPENING_TICK`, `PLATFORM_METADATA_HASH`, the package
addresses, `pricedRoutes()`, `partners()`). Values are in §5.

### 4.10 `FeastGenesisGrants` (`src/FeastGenesisGrants.sol`)

**Purpose.** Eight partner slots, 0.1% of FEAST each, unlocking by the fees their
referrals bring in the first 26 emission weeks. What does not unlock burns.

**State.** `_partners[8]`, `isPartner`, `assignedAt`, `referredNative`,
`claimed`, `_counted`, `unearnedBurned`, `slotBurned`. Immutables:
`platformCoin`, `emissions`, `targetNative`, `grant`, `guardian`.

| Caller | Entry point | Refuses |
|---|---|---|
| team multisig (= `guardian.guardian()`) | `assignPartner(slot, partner)` | any other caller (`:160`); before the clock started; after `guardian.sunsetAt()`; a slot out of range, already filled or already burned; a zero or duplicate partner |
| anyone | `burnUnfilledSlot(slot)` | while frozen; before the clock started; while the assignment window is still open; a slot that is filled or already burned |
| anyone | `checkpoint`, `checkpointAll` | a non-partner; a week out of range or not yet settled |
| anyone | `claim(partner)` | while frozen; a non-partner; claims not open |
| anyone | `burnUnearned(partner)` | while frozen; a non-partner; claims not open; before 26 weeks are settled; already burned |

**Can never.** Replace, remove or reassign a filled slot; move value on the
multisig's word; give a late partner a backdated start (weeks already closed at
assignment count zero and are still marked counted, `:235-241`).

**Invariants.** `P16`, `P30`. Tests: `test/FeastPackageTwo.t.sol`.

### 4.11 `FeastGuardian` (+ `IFeastGuardian`) (`src/FeastGuardian.sol`, `src/IFeastGuardian.sol`)

**Purpose.** The one bounded exception to "no owner". It buys time and nothing
else.

**State.** `genesisStartedAt`, `creationStopped`, `spent`, `frozenTotal`,
`frozenUntil`, `frozenFrom`, `allUnfrozenTotal`, `lastUnfrozenBlock`.
Immutables: `guardian`, `factory`.

| Caller | Entry point | Refuses |
|---|---|---|
| factory, once | `startClock` | any other caller (`:195`); a second call |
| guardian | `freeze` | any other caller; after the sunset; while already frozen; in the block an unfreeze cleared; while a lapsed freeze is unsettled; a spent budget |
| guardian | `unfreeze` | any other caller; when not frozen |
| guardian | `stopCreation` | any other caller; a second call |
| anyone | `settleLapsed` | when no freeze exists; while one is still live |
| anyone | `expire` | before the clock started; before the sunset |
| anyone | `isFrozenAll`, `frozenSeconds`, `allUnfrozenAt`, `sunsetAt`, `budgetLeft`, `clockStarted`, `creationStopped` | views |

**Can never.** Move a balance, change a share or a price, prevent a refund,
extend its own life (the freeze power ends at `started + 90 days` in wall time
regardless of downtime, `:459-462`), or outlive day 90 — except `stopCreation`,
which is deliberately permanent. There is no setter for `guardian` and no
pool-scoped freeze (removed at v1.6.17).

**Invariants.** `P27`, `P28`, `P29` — `P27` is pinned by a fuzz over every
external function in the tree with the guardian as the caller. Tests:
`test/FeastGuardian.t.sol`, `test/FeastAuthority.t.sol`.

### 4.12 `FeastOracle` (`src/FeastOracle.sol`)

**Purpose.** A tick oracle for Feast pools, because the venue keeps no
observations of its own.

**State.** `_observations[poolId][i]` (1024 slots), `_count[poolId]`. Immutable:
`writer` (the hook).

| Caller | Entry point | Refuses |
|---|---|---|
| hook | `write` | any other caller (`:62`). A second write in the same block is a no-op, never a revert — it sits on the swap path |
| anyone | `consult`, `twapTick`, `observationCount`, `historySeconds` | views; revert `OracleTooYoung` below 300 s rather than returning a spot price |

**Can never.** Be written by anything but the hook; return a degraded average.

**Invariants.** `P14`. Tests: `test/FeastOracle.t.sol`.

### 4.13 `FeastToken` (`src/FeastToken.sol`)

A plain fixed-supply ERC-20, burnable and permit-enabled. Whole supply minted in
the constructor to the factory; refuses a zero supply or a zero recipient
(`:42-43`). No mint entry point, no admin, no metadata setter, no votes, no
cross-chain mint/burn — fixed supply is enforced by *absence*, pinned by
`test_noMintEntrypointExists`. Test: `test/FeastToken.t.sol`.

### 4.14 `FeastPlatformToken` (+ `FeastPlatformTokenDeployer`)

`FeastPlatformToken` is `FeastToken` plus `ERC20Votes` on a **timestamp** clock
(`:42-48`), because exactly one parameter set is governed. Voting power counts
only after a holder delegates, and no Feast contract calls `delegate`. Same
absences otherwise: minted once, no mint entry point, no admin, no setter.

`FeastPlatformTokenDeployer` exists only because of the 24 KB contract-size
limit. `deploy()` is factory-only (`:33`) and uses CREATE2 with a fixed salt, so
the coin's address is known from the day package 1 ships; `predict()` is the
public form. No state, no owner.

### 4.15 `FeastVesting` (`src/FeastVesting.sol`)

Holds each creator's pre-buy: one allocation per coin, written once by the
factory (`:71-73`), recipient fixed at creation, linear from the creating second
with no cliff (duration zero means already fully vested). `claim(coin)` is
permissionless and always pays the recorded recipient (`:93`), and refuses while
frozen. No `editAllocationAdmin` and no minimum lock-up — both deleted from the
reference on purpose. Invariant `P6`. Test: `test/FeastPrebuy.t.sol`.

### 4.16 `FeastTeamVesting` (`src/FeastTeamVesting.sol`)

OpenZeppelin `VestingWallet`, 36 months from the launch window's close, no
cliff. Both `release()` arities are overridden to refuse while frozen
(`:54, 59`) — overriding both, not just the one in use, is the point.
`renounceOwnership` is disabled (`:69`) so the 25% cannot be stranded by giving
the wallet up. `platformCoin` and `guardian` are immutable and genesis checks
both as of v1.6.21. It never delegates, so it never votes. Its `Ownable` owner is
the vesting beneficiary, not a protocol admin.

### 4.17 `FeastMath`, `FeastConstants`, `FeastParameters`

Libraries, no state, no callers to gate. `FeastMath` holds the checked narrowing
casts and the square-root price limit both buy-back paths share — written rather
than imported because the venue's equivalent is GPL-licensed, and load-bearing
because the fee is computed in `beforeSwap`, before the venue has cast the swap
amount down to 128 bits (`test/FeastTickMath.t.sol`). `FeastConstants` is every
number the per-coin mechanism shares (§5). `FeastParameters` packs the hook
bitmap and tick spacing into the single `bytes32` the venue carries on every pool
key (`:23`), fuzzed against the venue's original in
`test/FeastHookScaffold.t.sol`.

### 4.18 `src/venue/` — the venue's types, not Feast logic

MIT re-declarations of the exchange interfaces and value types Feast calls. They
exist because an MIT-headered interface in the venue's own repository reaches 16
GPL-2.0-or-later files through its imports, and the shipped tree must stay
permissive. `tools/check-boundaries.py` walks the import graph and fails on any
non-permissive licence it can reach.

| File | What |
|---|---|
| `BalanceDelta.sol` | two `int128`s packed into one `int256` |
| `BeforeSwapDelta.sol` | specified delta in the upper 128 bits, unspecified in the lower |
| `Currency.sol` | a currency is an address; zero is the native asset |
| `PoolId.sol` | `bytes32`, derived as the hash of the ABI-encoded key — must agree with the venue's derivation to the bit |
| `PoolKey.sol` | six fields; `tickSpacing` lives inside `parameters`, not as a field |
| `IFeastCLHooks.sol` | the three callbacks Feast registers plus `getHooksRegistrationBitmap` |
| `IFeastCLPoolManager.sol` | the slice of the pool manager Feast calls |
| `IFeastVault.sol` | the slice of the vault Feast calls (custody + ERC-6909) |
| `IFeastLockCallback.sol` | `lockAcquired` |
| `IPancakeV3.sol` | the v3 factory/pool slice the conversion route uses |

Struct layouts and selectors are asserted against the venue's own interfaces in
`test/venue/VenueAbi.t.sol`. None of these files contains Feast logic.

---

## 5. Parameters and constants

### `src/FeastConstants.sol`

| Constant | Value | Meaning | Line |
|---|---|---|---|
| `FEE_PIPS` | `10_000` | 1% of the quote leg | `:12` |
| `FEE_DENOMINATOR` | `1_000_000` | fee unit | `:13` |
| `BPS` | `10_000` | unit for every share *of the fee* | `:16` |
| `MAX_SUPPLY` | `type(uint128).max` | largest supply a coin may be created with | `:46` |
| `PLATFORM_BPS` | `2_000` | platform's share of the fee | `:53` |
| `CREATOR_SIDE_BPS` | `8_000` | everything the creator divides up | `:55` |
| `DEFAULT_SELF_BURN_BPS` | `2_000` | default buy-and-burn share | `:63` |
| `MAX_SELF_BURN_BPS` | `5_000` | ceiling on it | `:64` |
| `DEFAULT_REFERRER_BPS` | `1_000` | default referral commission | `:67` |
| `MAX_REFERRER_BPS` | `3_000` | ceiling on it | `:68` |
| `EPOCH_LENGTH` | `86_400` | one day | `:75` |
| `TIMELOCK_DELAY` | `3 days` | governance delay | `:79` |
| `POOL_LP_FEE` | `100` | the venue's LP fee tier for Feast pools | `:87` |
| `POOL_TICK_SPACING` | `200` | tick spacing | `:97` |
| `CAP_BLOCKS` | `2` | blocks the opening cap binds for | `:102` |
| `CAP_BPS_OF_SUPPLY` | `50` | per-wallet cap = 0.5% of supply | `:105` |
| `MAX_HOURLY_SPEND_BPS` | `2_000` | most of an accrued bucket that may leave in any hour | `:114` |
| `ALLOWANCE_CAP_BPS` | `500` | token-bucket capacity = largest single press | `:130` |
| `ALLOWANCE_BPS_PER_HOUR` | `1_500` | refill rate | `:131` |
| `ALLOWANCE_WINDOW` | `1 hours` | the accrual window | `:133` |
| `MIN_RATIONED_BUCKET` | `10_000` | below this many raw units a bucket is not rationed | `:147` |
| `ALLOWANCE_SCALE` | `1e18` | fixed-point scale for the allowance | `:155` |
| `MAX_SETTLEMENT` | `uint128(type(int128).max)` | most that may leave the vault in one settlement | `:163` |
| `TIP_BPS` | `25` | 0.25% of a press's output, to whoever pressed | `:165` |
| `MAX_SLIPPAGE_BPS` | `300` | widest price move a button's own swap may cause, from spot | `:187` |
| `MAX_TICK_DEVIATION` | `300` | how far spot may sit from the average (≈3.045%) | `:197` |
| `TWAP_WINDOW` | `600` | averaging window, seconds | `:201` |
| `MIN_OBSERVATION_AGE` | `300` | below this the oracle refuses | `:204` |
| `BURN_ADDRESS` | `0x…dEaD` | the dead address the routing recognises | `:208` |

`ALLOWANCE_CAP_BPS + ALLOWANCE_BPS_PER_HOUR = 2_000 = MAX_HOURLY_SPEND_BPS`. That
sum is the whole of the arithmetic: a token bucket permits a burst of its
capacity plus a window's refill.

`MAX_SLIPPAGE_BPS` and `MAX_TICK_DEVIATION` are numerically equal and are **not**
the same tolerance — they compose. A press admitted at the edge of the tick check
and reaching its own limit clears about 3.045% + 2.98% ≈ 6.1% from the
time-weighted price (`src/FeastConstants.sol:178-186`).

### `src/FeastGenesis.sol`

| Constant | Value | Meaning | Line |
|---|---|---|---|
| `WEEK_LENGTH` | `7 days` | ledger week | `:34` |
| `WEEK_ALIGNMENT` | `3 days` | shifts the boundary to Monday 00:00 UTC | `:37` |
| `PLATFORM_NAME` / `PLATFORM_SYMBOL` | `"Feast"` / `"FEAST"` | | `:41-42` |
| `PLATFORM_SUPPLY` | `1_000_000_000e18` | minted once | `:45` |
| `PLATFORM_SALT` | `keccak256("feast.platform-coin")` | fixes the coin's address | `:48` |
| `POOL_BPS` | `6_000` | 60% to the pool, via the window | `:67` |
| `WINDOW_TRANCHE_BPS` | `5_000` | half of the 60% is the auctioned tranche | `:75` |
| `TEAM_BPS` | `2_500` | 25% to the team | `:76` |
| `GRANTS_BPS` | `80` | 0.8% to eight partners | `:77` |
| `EMISSIONS_BPS` | `1_420` (derived) | 14.2% bootstrap | `:82` |
| `PLATFORM_SELF_BURN_BPS` | `2_000` | FEAST pool's own buy-and-burn share | `:89` |
| `PLATFORM_REFERRER_BPS` | `1_000` | FEAST pool's referral share | `:90` |
| `MAX_GATE_DURATION` | `14 days` | longest a pool may be closed to all but its opener | `:104` |
| `DEFAULT_VALUE_RATIO_BPS` | `1_500` | value cap default | `:110` |
| `MIN_VALUE_RATIO_BPS` / `MAX_VALUE_RATIO_BPS` | `500` / `2_000` | governed band | `:111-112` |
| `MAX_REDIRECT_BPS` | `5_000` | most of a new week that may go to a bridge escrow | `:115` |
| `EMISSION_WEEKS` | `52` | | `:117` |
| `CURVE_DENOMINATOR` | `1_378` | 1 + 2 + … + 52 | `:120` |
| `EARLY_WEEKS` | `8` | weeks on the early weights | `:122` |
| early referrer / trader / creator | `4_000` / `4_500` / `1_500` | weeks 1–8 | `:123-125` |
| late referrer / trader / creator | `2_000` / `6_500` / `1_500` | weeks 9+ | `:126-128` |
| `PRICING_GRACE` | `3 days` | of open time, after which an unpriceable quote counts zero | `:131` |
| `CLAIM_GRACE` | `12 weeks` | how long a settled week stays claimable | `:133` |
| `PARTNERS` | `8` | | `:137` |
| `GRANT_BPS_EACH` | `10` | 0.1% per partner | `:138` |
| `GRANT_WEEKS` | `26` | the partner unlock horizon | `:140` |
| `WINDOW_DURATION` | `24 hours` | | `:144` |
| `WINDOW_LOCK` | `1 hours` | commits become irreversible this long before the close | `:146` |
| `SETTLE_GRACE` | `1 hours` | the window's exclusive settling hour; `openAt = close + this` | `:149` |
| `TEAM_VESTING_DURATION` | `94_672_800` | 36 months of 30.4375 days | `:155` |
| `TIMELOCK_DELAY` | `3 days` | | `:159` |
| `SINK_HALF_LIFE` | `1 hours` | the descent halves this often | `:164` |
| `SINK_START_PRICE_Q128` | `1 << 192` | where a new descent starts | `:167` |
| `SINK_FLOOR_HALVINGS` | `6` | floor = last sale price halved six times | `:170` |
| `SINK_FLOOR_HALF_LIFE` | `24 hours` | the floor's own clock | `:174` |
| `SINK_REOPEN_MULTIPLE` | `2` | a lot this much larger is a different lot | `:178` |

### `src/FeastFactory.sol`

| Constant | Value | Line |
|---|---|---|
| `MAX_PREBUY_BPS_OF_SUPPLY` | `2_000` (20% of supply) | `:155` |
| `MAX_WINDOW_CLOSE_AHEAD` | `30 days` | `:116` |

### `src/FeastGuardian.sol`

| Constant | Value | Line |
|---|---|---|
| `FREEZE_MAX` | `72 hours` | `:64` |
| `FREEZE_BUDGET` | `168 hours` | `:70` |
| `GUARDIAN_SUNSET` | `90 days` | `:73` |
| `MIN_FREEZE_CHARGE` | `1 hours` | `:102` |

### `src/FeastPlatformSink.sol` / `src/FeastConverter.sol` / `src/FeastOracle.sol`

| Constant | Value | Line |
|---|---|---|
| `ANCHOR_CEILING` | `SINK_START_PRICE_Q128 << 32` = `2^224` | `src/FeastPlatformSink.sol:168` |
| `MAX_HOPS` | `3` | `src/FeastConverter.sol:124` |
| `MIN_ORACLE_CARDINALITY` | `2` | `src/FeastConverter.sol:103` |
| `CARDINALITY` | `1024` | `src/FeastOracle.sol:46` |

---

## 6. How this tag came about (v1.6.19 → v1.6.21, internal pre-audit tags)

This is Feast's first external audit; nothing before this tag was sent to
anyone. `v1.6.19` and `v1.6.20` are internal pre-audit tags from our own
lens-and-PoC rounds, and `audit-pack/notes.md`, "READ THIS FIRST", is the
authoritative account of them; this is its summary. Three releases in one
evening, each caused by the round on the one before it.

**v1.6.19** was audited by a full double-family round and returned two HIGHs,
both with PoCs that were red on that tag: `sink-anchor-growth-overflow` (154
refill-and-take rounds walked the sink's anchor past `2^255` for 154 wei of
platform coin and zero asset, leaving 93.99% of the lot beyond every buyer) and
`refunded-weight-revival` (genesis at the window's closing second revived a
window that had begun refunding — 150 000 000 FEAST of a 300 000 000 tranche,
measured). **v1.6.20** fixed both: the anchor gained `ANCHOR_CEILING` drawn from
the money rather than from the sale arithmetic, and a sale now moves the curve by
what it took out of the **lot** rather than by the share of the balance it
carried away; `genesis` now requires the window's close strictly in the future.
v1.6.20 was re-rounded, focused, in both families, returned no HIGH and ten
distinct MEDIUMs. **v1.6.21 (this tag)** fixes the three genesis-time ones —
`genesis-window-key-unchecked`, `team-wallet-guardian-unchecked`,
`sink-arming-unenforced` — and carries the rest. v1.6.21 differs from v1.6.20 by
those three `try`-guarded questions in `FeastFactory.genesis`, the
`platformPoolKey()` view one of them needs, and the ceremony reorder that follows
from the third (`sink.schedule` before `genesis`). No pricing, no clock, no band,
no emission path changed.

Mutation coverage: 263 mutants, all re-validated to match exactly once; v1.6.21's
incremental run caught 15 of 15 on `FeastFactory`, including one new mutant per
applied check.

---

## 7. Known residues and accepted designs — already known to us

Each of these is reproduced by a PoC in `test/audit/poc/` that was **run**, is
red, and carries `vm.skip(true)` with its measured numbers in the docstring, so
the proof gate stays readable. `audit-pack/findings.md` has the full rows.

| Residue | Bound |
|---|---|
| `floor-sale-misses-price-rise` (`src/FeastPlatformSink.sol:603`) | A sale at the floor still raises the published anchor. **Pre-existing** — the same PoC prints the same four numbers on `v1.6.19-audit`. Left open deliberately: what the floor *means* is a design question, and every alternative touches the round-4 weighting and the v1.6.3 no-lowering rule at once. |
| `own-brake-extends-own-window` (`src/FeastGenesisGrants.sol:164`) | `assignPartner` succeeds on day 91 when `sunsetAt()` has been extended by 48 h of the guardian's own freeze. The multisig can lengthen its own assignment window by spending its own budget. No value moves. |
| `sunset-unanchored-prefreeze` (`src/FeastGuardian.sol:462`) | Frozen seconds spent **before** genesis lengthen the partner window, because `sunsetAt` adds lifetime `frozenSeconds()` without anchoring at `startClock`. Measured: 259 200 s. |
| `false-three-day-protection` (`src/FeastEmissions.sol:505`) | `settle(2)` succeeded after **901** open seconds where the residue's own justification promises 259 200. The grace's "three open days" is not enforced as written. |
| `preopen-regime-decided-by-settle-instant` (`src/FeastEmissions.sol:498`) | One hour of the guardian's budget changes which cap regime the last pre-launch week settles under (`tokenCapOnly` true vs false). |
| `shared-origin-capture` (`src/FeastHook.sol:615-619`) | A bundler that submits a user operation naming itself as the wallet can be bound to the submitter's chosen referrer. One binding, no rebinding, and the referral rule's evadability is already declared. |
| `lp-income-platform-share` (`src/FeastHook.sol:1869`) | **False positive.** The behaviour is real and declared three lines above the cited site: LP income has no discoverable earning epoch, so its platform share is withdrawn from the pot and buys and burns instead. |
| `prelaunch-regime` | A freeze across the seam between the window's close and `openAt` decides which regime the last pre-launch week settles under. Both halves carried. |
| The same-block bracket | The guardian can still *trade* in the block a lapse opens. `settleLapsed()` closes the freeze half, not the trade half. Defeating the rest needs block-builder collusion, and costs two `MIN_FREEZE_CHARGE` pulls per bracketed block. Bounded and stated at v1.6.19. |
| `settleLapsed` keeper integration | `settleLapsed()` is **permissionless by design** — if only the guardian could settle, it could decline and block its own brake. **Nothing operates it.** A lapsed freeze sits unsettled until somebody calls, and `freeze()` refuses until they do. Safe direction, but an operational dependency with no owner yet. This is a deployment task, not a code question. |
| The anchor ceiling is load-bearing | The consumed-share rule kills the refill pump, but honest compounding still reaches `2^224` in **899** takes of 2.5% with no refill anywhere. The clamp is what stands between that sequence and a word. |
| `unowned-seed-quote-remainder` (LOW) | The auction seed burns the coin the position did not take and leaves the **quote** it did not take unowned (`_burnUnplaced`, `src/FeastFactory.sol:747-751`). |
| `window-fee-to-codeless-sink` (LOW) | `settle` transfers its 1% before the named sink has code (`src/FeastLaunchWindow.sol:319`). v1.6.21's arming check narrows this: a sink **with** code must now be armed at genesis, but a sink with none is still admitted and still unasked. |
| `hop-rounding-amplification` (`src/FeastPricer.sol:141`, MEDIUM) | The pricer rounds each hop before composing the route, so a valid two-hop reciprocal route is priced **11.111% under** its true value. The error is one-directional and conservative: an understated price makes every consumer — the grant caps, the emissions value cap, the converter's admission — accept a **smaller** number, never a larger one. Pre-existing since v1.6.13, reported again in the v1.6.19 round; carried with its bound. |

Declared boundaries B1–B9, `CAPS`, `DEFAULTS`, `VENUE`, `V16-DECLARED` and
`V16-SCOPE` are listed with their source sections and section hashes in
`audit-pack/boundaries.md`. In particular: `tx.origin` is the fee-payer and
cap-subject identity (the venue hands a hook the router's address, not the
trader's); self-referral is allowed by ruling; the referral rule is evadable with
a second address by ruling; the internal fill assumes an 18-decimal quote domain;
tokens sent to the converter belong to nobody.

> Two line-number notes. `audit-pack/notes.md` cites
> `src/FeastFactory.sol:380` and `:662`, and
> `audit-pack/findings.md` cites `src/FeastFactory.sol:662
> predictPlatformCoin`. Those numbers are from the tags the findings were
> raised on. On this tree line 380 is inside `genesis` (a comment) and line 662
> is blank; `predictPlatformCoin` is at `:638` and the behaviour
> `unowned-seed-quote-remainder` describes lives in `_burnUnplaced`
> (`:747-751`). Read the function names, not the line numbers, in the older
> pack files.

---

## 8. How to read the evidence pack

`audit-pack/` holds the round that produced this tag. Top level:
`notes.md` (start here), `findings.md` / `findings.json` (every finding with its
severity, status, cited site, PoC path and measured numbers), `invariants.md`,
`mutations.md`, `boundaries.md` / `boundaries.json` (declared out-of-scope
behaviour, with section hashes), `bytecode.md` / `bytecode.json` (runtime
bytecode hashes per contract), `summary.md`, and `manifest.json`.

`audit-pack/rounds/r1/` holds the raw round: `deterministic.json` / `.md`
(slither, semgrep, aderyn, the project checks), `dynamic/` (the forge suite and
fork logs, the invariant run, halmos, medusa), `tools/`, `lens/` (one brief and
one verdict per analysis unit, both families), `proof/` (`proof-gate.json` plus
one `CA-*.log` per proven finding), `hook-checklist.json` (23 rows, inherited
from the overlay unit), `bytecode.json` and `runtime.json`.

`manifest.json` records the target (`tag v1.6.21-audit`, commit `e5c0a77`,
`src` tree `a4162ac4`, `dirty: false`), the tool versions and licences, the
counts, and a sha256 for every file in the pack, so any file can be checked
against it independently. The pack's own tooling lives under the audit skill,
not under `tools/`; from the commit that carries the pack:

```
python3 .claude/skills/contract-audit/assets/build_pack.py --root . --round r1 --verify     # every file against manifest.json
python3 .claude/skills/contract-audit/assets/proof_gate.py --root . --pack audit-pack --round r1   # re-runs every PoC
python3 .claude/skills/contract-audit/assets/run_layer.py deterministic --root . --round r1-repro  # a fresh scan
```

`audit-pack/summary.md` ends with the same three commands under "Reproduce".

---

## Appendix — the mechanical checks

`python3 tools/check-boundaries.py` enforces three claims that would otherwise be
prose: **licence** (walks the import graph from `src/` and fails on any
non-permissive licence it can reach), **authority** (fails on `onlyOwner`,
`onlyRole`, `Ownable`, `AccessControl`, `initializer`, `upgradeTo`,
`delegatecall` or `selfdestruct` in a shipped file), and **identity** (fails on
operator identity strings). `python3 tools/mutate.py` breaks 23 of the README's
promise table on purpose and requires the suite to notice every one
(`docs/mutations.md`). `python3 tools/check-census.py` asserts every call site of
every guarded mechanism appears in `docs/site-census.md`.
`python3 tools/discover_quotes.py` reports which quote tokens are usable, and why.

The fork tests pin block 120,721,477, because quote tokens are upgradeable
proxies and an unpinned fork silently tracks upgrades. Most public endpoints for
this chain are not archive nodes and cannot serve that block.
