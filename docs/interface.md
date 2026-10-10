# Interface for the app lane

ABI JSON for every contract is in `docs/abi/`, regenerated with
`forge inspect <Contract> abi --json`. This document is the part the ABI cannot
say: what each call means, what it refuses, and which of them can fail for
reasons outside feast's control.

Every address below is set at deployment and never changes. There is no owner,
no upgrade path and no pause, and every economic parameter of a coin is fixed in
its creating transaction.

**This document describes v1.6** — sealed and audited as one unit. The contracts
deployed with the factory add, to internal v1: the weekly fee ledger, the platform
coin's genesis, the `openAt` gate its launch window uses, the rule that a
referrer who is the payer is no referral, the exit that moves the platform's fee
share to the platform sink, the **internal fill** (a seller's coin taken into
the burn from the pool's own bucket), one **`Trade` event per swap**, and a
**metadata digest** on every coin. Two things in package 1 are not permissionless,
and both are stated here in full:

- **`FeastFactory.genesis` — one call, once, by the genesis key.** It mints the
  platform coin and routes its supply; it sets `genesisDone` before anything
  else, and every later call reverts. After it, nothing in package 1 has a
  privileged caller.
- The hook's factory-only registration and the ledger's hook-only `record`, as in
  v1: one contract writing another's state, never a person.

The governed levers of v1.6 — the emissions value ratio, a bridge redirect and
the pricer — live in `FeastEmissions`, behind a three-day timelock. See
[Governance](#governance--the-timelock).
`docs/tokenomics-v1.6.md` is the spec; `plans/v16/plan.md` is the plan and its
ruling.

---

## Creating a coin — `FeastFactory`

```solidity
function create(CreateParams calldata p) external returns (address coin, PoolKey memory key);
function getCoin(address coin) external view returns (Coin memory);
function listCoins() external view returns (address[] memory);
function coinCount() external view returns (uint256);
function coinAt(uint256 index) external view returns (address);
function predictCoin(bytes32 salt, string name, string symbol, uint256 supply) external view returns (address);
function poolKeyFor(address coin) external view returns (PoolKey memory);
```

One transaction mints the coin, creates the pool, seeds liquidity that can never
be removed, and starts the creator's vesting.

**`predictCoin` is not a reservation.** It commits to the four fields that enter
the coin's own creation code — `salt`, `name`, `symbol`, `supply` — and to
nothing else, so anyone who submits those four first lands on that address with
economics of their own (creator, quote, shares, opening price). The launch
itself is never blocked: a taken salt is refused, and the creator's launch goes
through at another salt. So do not show a predicted address, or commit anything
to it, before the creating transaction is mined; read the address from
`CoinCreated` or the `create` return instead. This is a declared boundary
(`docs/plan.md` §6c, B8).

### `CreateParams`

| Field | Meaning | Refused if |
|---|---|---|
| `name`, `symbol` | the coin's metadata, fixed forever | — |
| `supply` | total supply, minted once | zero |
| `quote` | the tokenised stock to pair against | not a contract, or equal to the coin |
| `creator` | receives the creator share of fees, and the vesting | — |
| `selfBurnBps` | share of the fee that buys this coin back and burns it | above `5000` |
| `referrerBps` | share paid to a referrer, on referred trades only | above `3000`, or `selfBurnBps + referrerBps > 8000` |
| `prebuyQuoteIn` | *v1.6.10.* Quote the creator pays into the coin's own pool in this transaction, buying their stake at the pool's own price like anyone else. Zero is no pre-buy. **The creator must approve the factory for it first** — this is the one new step in the launch flow | more than the creator's balance or allowance; a pre-buy that returns more than `MAX_PREBUY_BPS_OF_SUPPLY` (20%) of supply in coins |
| `minCoinsOut` | *v1.6.10.* The creator's slippage bound: the pre-buy must return at least this many coins | set while `prebuyQuoteIn` is zero; not met by the swap |
| `vestingDuration` | seconds, linear from the creating transaction (never a cliff). Read only with a pre-buy. *v1.6.24 (AstraSec I-5):* at least `MIN_PREBUY_VESTING` (seven days); zero used to be allowed and disclosed as "sellable at any time" — the launch form's 0-day unlock choice must go | below `MIN_PREBUY_VESTING` with a pre-buy: `PrebuyVestingTooShort(given, minimum)` |
| `sqrtPriceX96` | the opening price | — |
| `startTick` | the tick the pool opens at | see below |
| `liquidity` | the opening position's size | leaves more than 1% of the pool allocation unused |
| `salt` | CREATE2 salt; the coin's address follows from it | already used |
| `metadataHash` | *v1.6.* the 32-byte digest of the coin's metadata on IPFS — the sha2-256 digest a CIDv0 (or a CIDv1 over raw sha2-256) carries. Stored in `getCoin(coin).metadataHash` and emitted in `CoinCreated`, so a site can be rebuilt from the chain and IPFS alone. No default: zero is a coin with no metadata, and the app must write it deliberately | — |

**Two things the app has to compute.** `startTick` must be the tick
corresponding to `sqrtPriceX96`, and `liquidity` must be sized so the position
consumes essentially all of the pool allocation. A feast launch is single-sided —
the creator supplies the coin and nothing else — so the opening position runs
from `startTick` to the far edge of the usable range, on whichever side the coin
sorted to. If `startTick` puts the opening price *inside* the range, the position
would need quote nobody supplied and creation reverts with
`SeedWouldNeedQuote()`.

**Sizing `liquidity`: feast does not compute it for you, and no longer suggests
a formula.** Four internal rounds broke four different published estimates for
it, each wrong in a new way, so what is published now is only the constraint the
factory enforces — which is one line, and is not in doubt:

```solidity
// src/FeastFactory.sol, _seed
uint256 unused = IERC20(coin).balanceOf(address(hook));
if (unused > poolAmount / 100) revert PoolTooShallow();
```

`poolAmount` is what the factory seeds: the supply less the creator's allocation.
The position you open runs from `startTick` to the usable edge on the coin's
side, and it must consume all but at most 1% of that allocation. (The remainder
that *is* tolerated is burned, so a launch never strands coin.)

A candidate is right when `create()` succeeds, and that is the only test worth
applying. Of the refusals, exactly one carries information you can act on:
`PoolTooShallow()` means that position was too small for the coin on offer.
Anything else means that candidate was refused — read the refusal you actually
got rather than inferring one.

**Size by simulating `create()`.** Consumption rises with liquidity, so a
handful of `eth_call`s bracket the window and close on it: start from the
allocation itself, climb while the answer is `PoolTooShallow()`, come down on
any other refusal, and send the candidate that succeeds. A rejected attempt
costs nothing and consumes no salt, because the call reverts. Simulate against a fork or an in-process node — the sandbox's
`sandbox/up.sh` brings up exactly that, a pinned fork with the contracts
deployed. `test/FeastDeclaredBoundaries.t.sol` does the same search against the
real factory at a unit price, well above and below it, hard against either
usable edge, and with a creator allocation taken out first.

Some configurations admit no liquidity at all, and the simulation tells you that
too: nothing anywhere in the bracket is accepted. `test/FeastDeclaredBoundaries.t.sol`
holds one such case — a small allocation hard against an edge. A tick further
in, or a larger allocation, is the way out of it.

---

## The platform coin's genesis — `FeastFactory` (not an app call)

```solidity
function genesis(GenesisParams calldata g) external returns (address coin, PoolKey memory key);
function genesisDone() external view returns (bool);
function platformCoin() external view returns (address);      // zero until genesis
function platformSink() external view returns (address);      // zero until genesis
function predictPlatformCoin() external view returns (address); // known from day one
```

Documented so an app can *read* it; no app calls it. One call, by the
`genesisKey` the factory was deployed with, once. It mints FEAST (fixed supply,
`ERC20Votes`, timestamp clock) and routes the whole supply: **60%** seeded into
the FEAST/WBNB pool through the same seeding path every coin uses, **25%** to the
team's vesting, **14.2%** to emissions, **0.8%** to the genesis partners'
grants. The FEAST pool's own terms are fixed: the creator is the burn address,
20% self-burn, 10% referral — so nine tenths of every FEAST fee burns.

It also names the pool's **opener** (the launch window) and **`openAt`**, and the
**platform sink**. Refused: any caller but the key, a second call, a token
recipient with no code (the sink alone may be deployed later), a zero sink, and
an `openAt` in the past or more than 14 days away.

## The gate — before `openAt`, the platform coin's pool is the window's

Every ordinary coin has `openAt == 0` and never sees this. The platform coin's
pool refuses every swap before `openAt` except one sent by its opener, the launch
window, with:

| Error (wrapped by the venue as `WrappedError(hook, beforeSwap, …)`) | Meaning |
|---|---|
| `PoolNotOpenYet(openAt)` | the pool opens at `openAt`; until then only the launch window trades it |

Read `poolInfo(poolId).openAt` and `.opener` to show a countdown. From v1.6.11
the window has no settlement swap to exempt: it clears its auction
arithmetically and seeds the pool, so the only thing this gate now holds back is
everybody else. Before settlement there is no pool at all and the venue's
`PoolNotInitialized()` is what a caller sees.
## The referral binding — `FeastReferrals` (v1.6.26)

**A referral is a property of the wallet, not of a trade.** A wallet that has
bound a referrer pays that referrer on every later trade it makes — any coin,
any router, any terminal, for ever. `docs/referrer-binding.md` is the full
design; this is what the app has to do about it.

**v1.6.26 (AstraSec M-4): a wallet binds itself, and no trade binds anybody.**
Until v1.6.25 the first 64-byte `hookData` whose wallet word equalled
`tx.origin` bound that origin for life. Under ERC-4337 the origin is the
bundler, so one user operation could bind a bundler to a stranger, and every
later trade it relayed paid the stranger. The binding now lives in
`FeastReferrals`, an immutable registry with no admin, and only the wallet
writes it: by its own call, or by its own signature, which anyone may relay.
**The hook's `referrerOf` view and its `ReferrerBound` event are gone** — read
the registry, whose address is `hook.referrals()`.

```solidity
// FeastReferrals — this ABI is frozen
function referrerOf(address wallet) external view returns (address);
function bind(address referrer) external;
function bindWithSig(address wallet, address referrer, uint256 deadline, bytes calldata signature) external;
event ReferrerBound(address indexed wallet, address indexed referrer);
```

| Error | Meaning |
|---|---|
| `ZeroReferrer()` | `referrer` is the zero address |
| `SelfReferral()` | `referrer` is the wallet itself |
| `BurnReferrer()` | `referrer` is `0x…dEaD`: bound, it would burn the referrer share of every fee the wallet paid |
| `AlreadyBound()` | the wallet is bound; the first binding wins, for ever |
| `BadSignature()` | not the wallet's signature of exactly this `Bind` on this registry and chain |
| `SignatureExpired()` | `block.timestamp > deadline` |

### How a wallet binds

- **By its own call:** `referrals.bind(referrer)`, sent by the wallet — 52,650
  gas measured for an EOA. An ERC-4337 account batches `bind` into a user
  operation, beside or before its first trade: the account is `msg.sender`, so
  it binds itself.
- **By its own signature:** the wallet signs the EIP-712 message below and
  anyone — the app, a keeper — submits `bindWithSig(wallet, referrer, deadline,
  signature)` and pays the gas: 58,376 measured for an EOA's. A key signs as
  usual (65 bytes, `r ‖ s ‖ v`; a high-`s` signature is refused). A contract
  account answers through ERC-1271 `isValidSignature`, read when the call is
  made. A 7702-delegated EOA has code, so it is checked through its delegate's
  ERC-1271; if the delegate does not implement it, the EOA uses `bind`.
- **No nonce.** A wallet binds once, so a signature that has bound can only meet
  `AlreadyBound` again. `deadline` is the signature's life: good at
  `block.timestamp == deadline`, refused one second later. An unexpired
  signature is a standing consent — whichever lands first, the wallet's own
  `bind` or a relay of the signature, is the binding — so ask for deadlines of
  minutes, not months.
- The signature is checked before the refusals, so a relayed call learns
  nothing about a wallet that did not sign it.

### The signing payload

```json
{
  "types": {
    "EIP712Domain": [
      {"name": "name", "type": "string"},
      {"name": "version", "type": "string"},
      {"name": "chainId", "type": "uint256"},
      {"name": "verifyingContract", "type": "address"}
    ],
    "Bind": [
      {"name": "wallet", "type": "address"},
      {"name": "referrer", "type": "address"},
      {"name": "deadline", "type": "uint256"}
    ]
  },
  "primaryType": "Bind",
  "domain": {"name": "FeastReferrals", "version": "1", "chainId": 56, "verifyingContract": "<the registry>"},
  "message": {"wallet": "<the signer>", "referrer": "<the referrer>", "deadline": "<unix seconds>"}
}
```

The registry computes its domain separator on every call, from the chain it is
on, and has no getter for it: build it from the four domain fields. The vectors
below are pinned by `FeastReferralsTest.test_theEip712VectorsTheAppSignsAgainst`
and were computed twice outside Solidity — by hand with `cast keccak` and
`cast abi-encode`, and by alloy's EIP-712 encoder through `cast wallet sign
--data`, whose signature over the typed data equals the one over the hand-built
digest.

| | |
|---|---|
| chain id; registry | `56`; `0x00000000000000000000000000000000000fea57` |
| wallet (test key 1); referrer (test key 2); deadline | `0x7E5F4552091A69125d5DfCb7b8C2659029395Bdf`; `0x2B5AD5c4795c026514f8317c7a215E218DcCD6cF`; `1800000000` |
| domain type hash | `0x8b73c3c69bb8fe3d512ecc4cf759cc79239f7b179b0ffacaa9a75d522b39400f` |
| `Bind` type hash | `0x5c22698b6ffa0a9eeddd2868e00c1aafa8abe2abe36ac892441c080afe5c29a3` |
| domain separator | `0xff720bfdecbbe1f58723d4cc3fbdb617718f5bcce5ef8492aa9b7ddbc1425aa9` |
| struct hash | `0xf53efa9e196be2889581b3a2c48cc6d03094c17f4833ab2a907c89ef22dfb61d` |
| digest, `keccak256(0x1901 ‖ separator ‖ struct hash)` | `0x9a7ee5d3d9bb3b5b5c998dc01464bb5807bad490b34a9e95f190f7df3bea948b` |
| signature by test key 1 | `0x76dba4a7cc611f28d3c71e256dfd42924f05d32343b398b578f0737ed7082557142e3e77e56f98998b6725467e1ea412fd404595caca13ea366026b4299261011c` |

### What to put in `hookData`

| Bytes | Build it with | Means |
|---|---|---|
| 0 | `""` | no referrer |
| 32 | `abi.encode(referrer)` | referrer **for this trade only** |
| 64 | `abi.encode(referrer, wallet)` | referrer **for this trade only** — since v1.6.26 this form binds nobody |

Any other length is read as "no referrer". **No length ever refuses the trade**
— that is R3, and it is why a router that appends a byte does not break every
swap in the pool.

- Once a wallet is bound, `hookData` no longer matters for it: pass `""`.
- While a user is unbound and the session carries a referrer — a KOL link, your
  own address — name it per trade, in either form, and offer the user the
  binding: a per-trade referrer is paid on that trade and no other.
- The 32-byte form is exactly what v1.6.7 accepted. The 64-byte form still
  parses and still pays per trade, so an integration that sends it keeps
  working — it just no longer binds anybody.

### What the hook does with it

If `referrals.referrerOf(tx.origin)` is set, that address is paid and `hookData`
is not consulted at all. If it is not set, the trade's own referrer is paid, for
this trade only.

Paying nothing, in **either** form: the zero address, and a referrer who is the
trade's own payer (v1.6 ruling 5, Q5). In the **64-byte** form only: the burn
address, and a referrer equal to the wallet the trade names. The 32-byte form
may still name the burn address, exactly as it could before; what the ruling
refuses is letting that become permanent, and the registry refuses binding it.

**It is worth more than the commission.** `FeastFeeLedger` records the referrer
on every trade, whatever the pool's `referrerBps` — and `FeastEmissions` prices
that `referred` track into the weekly referrer pot, while `FeastGenesisGrants`
unlocks a partner's grant against it. So a binding routes a share of the first
year's emissions, for ever, not just a slice of one fee.

**Smart accounts — the boundary v1.6.26 ships with.** The hook looks up only
`tx.origin`'s binding, and an ERC-4337 account is never `tx.origin`: its trades
arrive through a bundler. So an account can bind — by its own call inside a user
operation, or by ERC-1271 signature — and its binding is recorded, but the hook
does not read it on the account's bundled trades. **To pay an account's
referrer, name it in the trade:** read `referrals.referrerOf(account)` and pass
it in `hookData`. This is a bytecode decision, not a design one: looking up the
64-byte form's wallet word did not fit the hook under EIP-170, and the
coordinator ruled it out on 2026-10-04 (`docs/audit/v1.6.26-changes.md`).

**Bundlers.** A user operation can no longer bind its bundler, because no trade
binds. A bundler that binds ITS OWN key, by its own call or signature, is paid
on every trade it originates, as any bound EOA is: the chain cannot tell a
bundler's key from a user's. That is AstraSec I-1's boundary, accepted by the
owner for v1.6.24, narrowed by v1.6.26 to the bundler's own act.

### The consequence, stated plainly

**A wallet's first binding is for life** — made by its own call, or by the first
relay of a signature it gave. **There is no re-binding, by anyone, ever** — no
`setReferrer`, not for the owner, not for the user — so there is no remedy
afterwards.

That is the owner's ruling and not an oversight: a second binding would be
unfair to the referrer who actually made the introduction, and would invite
poaching. An app that shows users who they are about to be bound to, before they
sign or send anything, is doing them a service; `referrals.referrerOf` is a
public view for exactly that.

---

## Fees owed to a creator or referrer — `FeastHook`

```solidity
function claimable(PoolKey calldata key, address account) external view returns (uint256);
function claim(PoolKey calldata key, address account) external;
function claimAsBnb(PoolKey calldata key, address account, FeastConverter.Hop[] calldata route, uint256 minOut)
    external returns (uint256 out);
```

`claimable` returns what `account` is owed **in the pool's quote token** — the
creator's remainder, a referrer's commissions, or both if they are the same
address.

**`claim` is the floor.** It pays the quote token, needs no route, no oracle and
no counterparty, and therefore cannot be broken by anything happening in the
market around that token. It is the reason nobody's money can be trapped.

**`claimAsBnb` is the default the app should offer.** It claims and converts in
one call along a route the claimant supplies. It either does both or does
neither: if the route cannot be priced, the whole call reverts and the claim is
still sitting there to be taken with `claim` instead.

`claim` is callable by **anyone** and always pays `account` — paying somebody
what they are owed in the token it accrued in needs no judgement, so a creator
who has lost their key strands only their own bucket and nobody else's.
`claimAsBnb` requires `msg.sender == account`: choosing the *path* the money
takes does need judgement, and a route that passes every per-hop check can still
consume a large fraction of a claim in pool fees.

**Always pass `minOut`** (v1.6.24, AstraSec M-1): the least wrapped native the
claimant accepts, taken from a quote before signing less the tolerance they
chose. The converter checks it last and reverts `BelowMinOut(got, minOut)`; the
claim is untouched and can be taken again. Every other protection on the path is
anchored to the pools' prices as found, so a sandwich that parks each hop's spot
at the edge of its admitted band is inside all of them — measured, 88.65% of the
clean quote over three hops. Zero means "no bound of my own" and leaves only the
converter's own floor. On a pool quoted in wrapped native, nothing is converted
and `minOut`, like `route`, is not consulted; a claimant owed nothing gets 0.

`claimCreator`, `claimReferrer`, `releasePlatformFees` and `claimAsBnb` — with
`buyBackAndBurn`, `burnFilledCoin` and `collectLpFees` — share one re-entrancy
guard (v1.6.24, AstraSec I-7; the three that pay since v1.6.28): none of the
seven can be entered from inside another, and a call that tries reverts
`ReentrancyGuardReentrantCall()`. `claim` pays nothing itself and is not
guarded; it calls `claimCreator` and `claimReferrer` in turn, so a re-entrant
`claim` reverts the same way as soon as it reaches either. Calling several of
them in sequence, from one transaction, is unaffected.

Routes are bounded: at most `FeastConverter.MAX_HOPS` (3), and no token may
appear twice, so a route cannot cycle through one fee-charging pool.

### Choosing a route

```solidity
struct Hop { address tokenOut; uint24 fee; }
```

The route is a list of hops from the quote token to wrapped native; the last hop
**must** end in wrapped native. The path is untrusted — the safety property is
the bound, not the path — so the app is free to pick whichever pools are
deepest, and liquidity can migrate without bricking anything.

Before offering a route, ask:

```solidity
FeastConverter.hopIsPriceable(tokenIn, tokenOut, fee)
    returns (bool priceable, address pool, uint16 cardinality, uint32 age);
```

`priceable == false` means the conversion **will** revert, and the two fields say
why: a `cardinality` below 2 means the pool reports its spot price as its
time-weighted price, and an `age` below the minimum means it has no history yet.
Neither is a feast decision — see the [deployment recipe](../README.md) for what
to do about the first.

Some quote tokens have a direct pool against wrapped native and convert in a
single hop; others need a stablecoin in the middle. `tools/discover_quotes.py`
reports which is which.

---

## One event per swap — `FeastHook.Trade`

```solidity
event Trade(address indexed coin, address indexed quote, bool buy, uint256 coinAmount,
            uint256 quoteAmount, uint160 sqrtPriceX96After, address indexed payer, uint256 fee);
event InternalFill(PoolId indexed poolId, uint256 coinBurned, uint256 quotePaid);
```

Emitted once for every swap in a pool that is open, on every fee branch, and
built so that a price chart needs nothing else: `coinAmount` and `quoteAmount`
are **the trader's own** — what the venue moved for them, the fee included on
whichever side it was charged (a buyer's `quoteAmount` is what they paid; a
seller's is what they received) — `fee` is what the swap paid feast,
`sqrtPriceX96After` is the pool's price after the swap, and `payer` is the
transaction's origin. An execution price is `quoteAmount / coinAmount` (the fee
is inside it); the fee-free price is the pool's. **No `Trade`** for LP-fee
collection, and none for the launch window's settlement — which from v1.6.11 is
not a swap at all. `FeesRecorded` (the ledger) is unchanged.

## The internal fill — what a seller sees

When somebody sells a coin with an **exact-input** swap (they name how much coin
they sell), the hook first offers part of the sale to that coin's own
buy-and-burn bucket, **at the pool's current price**: it takes that part of the
coin and pays the seller from the bucket, before the rest of the sale reaches the
pool. Nothing physical moves inside the swap — the hook pays in vault claims and
is paid in vault claims — and the coin it bought is burned for real by a separate
permissionless call:

```solidity
function burnFilledCoin(PoolKey calldata key) external;          // anyone; at most one settlement per call
function filledCoinPending(PoolId poolId) external view returns (uint256);
event FilledCoinBurned(PoolId indexed poolId, uint256 amount);
```
 The seller receives the pool's price for the filled part with
no slippage and no LP fee, and without moving the price. The coin the fill takes
off the seller's hands is **not burned inside the sale**: it is added to the
pool's `filledCoinPending`, and the supply falls when anyone calls
`burnFilledCoin` (v1.6.7, the v1.6.6 pack, both codex units — this sentence used
to say the burn happened without a separate transaction, and the separate
transaction is exactly what it takes). Since v1.6.24 (AstraSec I-8) the coin side
of the locked position's own fees joins the same pile when `collectLpFees` runs,
and burns the same way — it used to be sent to `0x…dEaD`, where explorers counted
it as held supply. The seed's tolerated remainder is burned for real too. The sale pays the same 1% fee on the whole amount.
`InternalFill(poolId, coinBurned, quotePaid)` is emitted when it happens, and the
sale's `Trade` reports the whole sale.

It never refuses a trade and it never fills when: the pool is still gated; the
bucket's spending allowance is empty (the fill and `buyBackAndBurn` share **one**
allowance, so together they spend no more than 20% of the bucket in any hour);
the pool's price history is under ten minutes old (five before v1.6.24); the pool's spot price has
been moved more than ≈ 3% from its own average; the trade is anything but an
exact-input sale; or the pool's raw price is outside the fill's exact domain
(between 2^-64 and 2^64 raw units of one token per raw unit of the other). Every
quote the protocol prices is an 18-decimal token and sits well inside it; a coin
quoted in a six-decimal token on the open factory can fall outside, and then
simply trades with no fill. It always leaves at least one unit of the sale for
the pool.

## The platform's share — `FeastHook.releasePlatformFees`

```solidity
function releasePlatformFees(PoolKey calldata key) external;
function platformPending(PoolId poolId) external view returns (uint256);
```

Permissionless. Moves the pool's accrued platform share, **as the asset it
accrued in**, to the platform sink genesis named — no route and no conversion.
At most one settlement per call (`MAX_SETTLEMENT`, the venue's signed 128-bit
limit); a larger bucket leaves in pieces, each debited by exactly what it paid.
Refused with `PlatformSinkNotBound(sink)` before genesis, and while the named
sink has no code (it may ship after the platform coin's launch — the share
simply waits, owned). A frozen quote token makes it revert with the entitlement
intact, exactly as a claim does. The sink is package 2.

## The button

The platform conversion and buy-back buttons of the v1.1 branch are retired in
v1.6 (the exit above and the package-2 sink replace them), so what an
application can press here is the coin's own burn.

```solidity
// FeastHook — spend a coin's accrued bucket buying that coin, and burn it.
function buyBackAndBurn(PoolKey calldata key, uint256 amountIn) external;
function spendingAllowance(PoolId poolId) external view returns (uint256);
function selfBurnPending(PoolId poolId) external view returns (uint256);

// FeastHook — collect the locked position's own trading fees into the buckets.
function collectLpFees(PoolKey calldata key) external;

// FeastHook — a claimant may take their own claim in the chain's asset.
function claimAsBnb(PoolKey calldata key, address account, FeastConverter.Hop[] calldata route, uint256 minOut)
    external returns (uint256);
```

It is permissionless and pays the caller a tip out of what the press produced,
so a press can never cost the *protocol* more than it creates. Two honest limits
on that, for anyone building a keeper: the tip is a rate of the coin bought that
the bucket sets, not the press (0.25%, lifted toward the quote's listed floor on a
small bucket and never above 10%; `FeastConstants.TIP_BPS`), so a purchase too
small for that rate to reach one raw coin unit tips **zero**; and nothing here bounds the
caller's gas, so whether a press is worth making is the caller's arithmetic, not
a guarantee this contract offers.

**How its pacing works, in plain words.** The button has a *spending allowance*
that refills continuously, like water into a bucket. It fills at 15% of the
accrued bucket per hour and never holds more than 5% of it at once. A press
spends whichever is smallest: what you asked for, what the allowance holds, or
what the pool will actually fill inside the price bound. Whatever it *actually*
spends is then taken out of the allowance, which refills from that moment.

Those two numbers add up to the rule the whole design exists to keep: **no more
than 20% of an accrued bucket can leave in any one hour.** Two consequences worth
stating on their own:

- **Sustained throughput is 15% of the bucket per hour.** That is the refill
  rate, and it is what a patient presser can move over a long period.
- **The largest a single press can ever be is 5% of the bucket.** That is the
  cap, and it is also the largest print anyone could sandwich — which is the
  reason to prefer a small cap even though it costs throughput.

**One exception, and it is deliberate:** a bucket at or below 10,000 raw quote
units may be spent in full, because a share that small rounds to something no
pool will fill. A press that crosses from above that threshold to below it can
therefore spend more than 20% in the hour that crosses. A bucket that can be
full when the hour starts can pay out its fill *and* its refill, so the fill and
the refill have to add up to the limit rather than each being the whole of it.

**A new pool's allowance starts empty and grows.** It is not an hour's lockout —
accrual is continuous, so a pool that has banked a substantial bucket can have a
usable allowance within minutes; it simply starts at nothing and is small at
first. An app should read `spendingAllowance(poolId)` and offer that, rather than
implying either that a press is ready or that one must wait an hour.

Three things follow, and they are the point of the design:

- **There is no cooldown to wait for and no minimum press size.** Press whenever
  you like, for whatever the allowance holds. `spendingAllowance(poolId)` tells
  you what that is right now, and it is the number an app should offer as the
  default.
- **A small press costs you only what it spends.** It does not "use up" a turn,
  so it cannot block anyone else — someone else may press again in the same
  block if the allowance still holds something.
- **A pool too thin to fill a whole press still works** — up to a point. The
  press fills what it can, only that much is deducted, and the rest of the
  allowance stays available. The limit is granularity, not thinness: if the
  permitted press is small enough that the pool returns *zero* coin, the press
  reverts and the bucket waits until it grows. Above the dust threshold the
  allowance never exceeds 5% of the bucket, so waiting alone does not lift it.

This replaced an hourly interval with a minimum press size, which was withdrawn
in round 6 (`docs/plan.md` §6c B4). The old shape could be jammed: anyone could
press for a trivial amount, consume the hour, and block the productive press
behind them for the price of gas.

**Correction (round 7, now resolved):** an earlier draft said the total
spendable per hour was unchanged by that replacement. It was not — an allowance
that could be full at the start of an hour paid out a burst *and* a refill,
about 36% rather than 20%. The fill rate and the cap now sum to the 20% bound
instead of each being the whole of it, which restores it with margin. The cost
is sustained throughput: 15% per hour rather than 20%.

**The tip has no flat component per press — the rate is set by the bucket, not
the press** (v1.6.23). It is 0.25% of what the press bought, lifted to what the
quote's listed floor would be on the largest press the bucket allows, and never
above 10%. A dust press earns dust, and splitting a press earns at most a bounded drift: each
piece lowers the bucket, so the later pieces are tipped at a slightly higher rate — +1.3% for two
pieces, +2.3% for ten, inside the 6% the team's own witness allows — and from about 0.03 gwei up
that is worth less than the gas of the extra presses (v1.6.27, `CA-40dcf992a5`). The floors
are written once, in the hook's constructor, and announced by `TipFloorListed`;
there is no getter.

**Below 10,000 raw quote units the allowance is the whole bucket**, and it fills
within the hour rather than at the usual rate. A share that small rounds to
something no pool will fill, and a print that size cannot be sandwiched by
anyone.

`buyBackAndBurn` refuses when:

| Error | Meaning |
|---|---|
| `NothingToBuyBackWith()` | the bucket is empty, `amountIn` is zero, or the allowance is currently empty |
| `BoughtNothing()` | the purchase produced nothing, so no allowance is consumed and no bucket debited |
| `SpotTooFarFromAverage(spot, average)` | the pool's price has been moved; it will not buy into that |
| `OracleTooYoung(age, required)` | the pool has less than `required` seconds of price history — the whole ten-minute window (v1.6.24, AstraSec L-2: the oracle used to answer a shorter average from five minutes on, without saying so) |

**`claimAsBnb` is the one conversion path in v1.** The route is supplied by the
claimant and only by the claimant — `RouteIsTheClaimantsToChoose(account)`
otherwise. That is the whole reason it survives the cut: whoever picks the route
bears the loss from it. Claiming in the quote token needs no route at all and is the path to prefer. It
is not unconditional, and an app should not say it is: a quote token that
freezes makes the claim revert until it unfreezes — the entitlement survives
untouched — and an entitlement larger than one settlement is paid in pieces
across successive calls.

A conversion is **all-or-nothing** at every hop: if any hop cannot take the whole
amount offered to it, the call reverts with `RouteWouldNotFill(taken, offered)`
and nothing moves. See `docs/plan.md` §6c B1, and §6c B2 for why tokens sent
directly to the converter can never be recovered by anyone.

---

## The weekly fee ledger — `FeastFeeLedger`

```solidity
struct Credit { uint80 paid; uint80 earned; uint80 referred; }

function credit(uint256 week, address quote, address account) external view returns (Credit memory);
function totals(uint256 week, address quote) external view returns (Credit memory);
function currentWeek() external view returns (uint256);
function weekOf(uint256 timestamp) external pure returns (uint256);
function weekStart(uint256 week) external pure returns (uint256);
event FeesRecorded(uint256 indexed week, address indexed quote, address indexed payer,
                   address creator, address referrer, uint256 amount);
```

Written by the hook on every fee, read by package 2's emissions and genesis
grants. Weeks are seven days and **turn at Monday 00:00 UTC**. Per week and per
quote token, three tracks, each counting the **whole fee**:

| Track | Who | Credited with |
|---|---|---|
| `paid` | the trader (`tx.origin`) | the fee they paid |
| `earned` | the coin's creator | the fee their coin earned — whatever split they chose |
| `referred` | the trade's referrer: the payer's bound one if it has one, else the one named in `hookData` | the fee the trade they brought paid — whatever commission the creator set, including none |

**A referrer who is the payer is no referral at all** — no commission, no
`referred` credit. Evadable with a second address; the owner's ruling accepts
that. A burn-address creator (the platform coin) earns no creator track. LP-fee
collections and the launch window's settlement are recorded on no track — and
the settlement's 1% reaches the platform sink by transfer, not by swap.

**Payer means `tx.origin`**, the same identity the opening cap uses. A contract
wallet whose transactions are sent by a bundler is credited to the bundler; say
so in the UI.

**Per quote token, never summed.** One unit of a four-hundred-dollar share is not
one unit of a twenty-dollar one; emissions prices each quote when it settles a
week. An app may show "your share of this week's fees in QQQB" as
`credit.paid / totals.paid`; it must not show a FEAST amount as owed until the
week is settled by package 2.

A track that would overflow `uint80` (1.2 million whole 18-decimal tokens of fees
in one week and quote) is simply not recorded for that fee — no swap ever
reverts because of the ledger.

## The first year's emissions — `FeastEmissions`

```solidity
function settle(uint256 week) external;                       // anyone; in order; after the week closes
function claim(uint256 week, address account) external returns (uint256);
function claimMany(uint256[] calldata weeks, address account) external returns (uint256);
function owed(uint256 week, address account) external view returns (uint256);
function claimsOpen() external view returns (bool);
function expiryOf(uint256 week) external view returns (uint256);
function tokenCap(uint256 week) external view returns (uint256);
function weekInfo(uint256 week) external view returns (Week memory); // pots, values, flags
function settledQuotes(uint256 week) external view returns (address[] memory); // the list that week settled over (v1.6.3)
function settledCount() external view returns (uint256);
function ledgerWeekOf(uint256 week) external view returns (uint256);
function burnExpired(uint256 week) external;                  // anyone, after the week's grace
function releaseRedirect(uint256 week) external;              // anyone
function burnRemainder() external;                            // anyone, after week 52
```

Week 1 is the ledger week the factory opened in; there are 52. Fees count only
in the pricer's listed quotes — each an 18-decimal token (the pricer refuses any
other when it is built) with a pinned route to WBNB. Anyone may settle the next
week once it has closed; a week may settle **before the platform
coin exists** (its pots are then accounting, funded when genesis delivers the
14.2%). Show `owed(week, account)` per settled week; **claims open only when
`claimsOpen()`** — the platform coin's pool has opened — and a settled week stays
claimable for 12 weeks from the later of its settlement and that opening
(`expiryOf`). `claim` is callable by anyone and always pays `account`.

A week's pots (`weekInfo(week).pot`: referrer, trader, creator) are the smaller of
its value cap and token cap, split 40/45/15 in weeks 1–8 and 20/65/15 after; a
track with no fees that week emits nothing. `tokenCapOnly` marks a week settled
**before launch** (the platform coin's pool not yet open) while the platform coin
had no price the oracle would vouch for; after launch that never happens — the
value cap always binds. Refusals worth surfacing: `WeekNotClosed`, `NotInOrder`,
`QuoteUnpriceable` (a listed quote's pool cannot vouch for its price, or its
route's price is too large to hold; retry, or after three days it counts as
zero), `PlatformPriceMoved` (retry; before launch only until the three-day grace,
after launch with no timeout), `PlatformUnpriceable` (after launch only: the
platform coin's price cannot be read; settlement waits until it can, or until the
timelock replaces the pricer), `ClaimsNotOpen`, `Expired`, `AlreadyClaimed`.

**Every listed quote's pools keep a ring of 601 observations** (v1.6.25, AstraSec
Q-3; `FeastConstants.MIN_RING_CARDINALITY`, one per second of the ten-minute
window and one more). A v3 pool writes at most one observation per second, so a
FULL ring that deep spans the whole window, whoever writes to it. A ring that has
just widened is not full: its new slots are empty, so its history is only the time
since the write that widened it, and until that is the whole ten minutes the
pricer reads the pool as `Unpriceable` and never averages it over less (v1.6.27,
`CA-0d9ade0259`). The pricer
refuses to be built over a route pool that has not been asked for that ring —
`RingTooShallow(quote, pool, cardinalityNext, required)` — and reads a pool whose
live ring is still shallower as `Unpriceable`. **Operating rule, before a quote
is listed:** call `increaseObservationCardinalityNext(601)` on every pool of its
route (anyone may; it costs the caller one fresh storage slot per observation
added), then make sure each pool has written since: it takes the new depth at the
first write that reaches the end of its old ring — the very next one for a ring
of one — and `slot0()`'s `observationCardinality` shows when it has. **Then
wait ten minutes** before the quote's first settlement can count on it: until the
widened ring's history covers the window, the quote reads as `Unpriceable`. Until
v1.6.25 a ring of two was accepted, and one in-range mint or burn just after a
trade made the quote `Unpriceable` at settlement — which, after the grace,
counts its week as zero. A quote whose ring has not widened yet is now
`Unpriceable` from the day it is listed, visibly, rather than whenever someone
writes before a settlement.

**The three governed levers** — `setValueRatioBps` (5%–20%, default 15%),
`setRedirect` (up to 50% of what each new week actually emits, taken track by
track, to a bridge escrow), `setPricer` — are
callable only by the timelock, bounded at the callee, and apply from the next
ledger week (the pricer from the next settlement). A settled week never changes.

## The genesis partners — `FeastGenesisGrants`

```solidity
function partners() external view returns (address[8] memory);
function unlocked(address partner) external view returns (uint256);
function referredNative(address partner) external view returns (uint256);
function checkpointAll(address partner) external;             // anyone
function claim(address partner) external returns (uint256);   // anyone; pays the partner
function burnUnearned(address partner) external;              // anyone, after week 26
```

Each of the eight holds 0.1% of the supply, unlocking in proportion to the fees
their referral links brought in emission weeks 1–26 (priced exactly as the
referral pots are), up to the whole grant at `targetNative`. The unearned part
burns after week 26; the earned part stays claimable.

## The launch window — `FeastLaunchWindow`

```solidity
function commit() external payable;                           // [startsAt, endsAt)
function withdraw(uint256 amount) external;                   // [startsAt, lockAt): not the last hour
function settle() external;                                   // anyone, once, from endsAt until it succeeds; not while frozen
function claim(address account) external returns (uint256);   // anyone, after a settle that sold; pays account
function refund(address account) external returns (uint256);  // anyone, when nothing was or can be sold
function abandonAt() external view returns (uint256);         // when the auction expires (v1.6.24)
function committed(address) external view returns (uint256);
function total() external view returns (uint256);
function tranche() external view returns (uint256);           // what the auction cleared
function clearingPrice() external view returns (uint160);     // sqrt(quote per coin), Q96
function settled() external view returns (bool);
function startsAt() external view returns (uint64);
function endsAt() external view returns (uint64);
function lockAt() external view returns (uint64);
```

Show `total()` live and the implied clearing price: the tranche is fixed, so
the price the window is heading for is `(total - total/100) / tranche` and it
moves with every commit.

After `endsAt`, `settle` **clears a uniform-price auction** — there is no swap.
A fixed tranche (half of what the window holds) clears at one price
`p* = net / tranche`, the platform coin's pool is created **at that price**, and
both sides are seeded around it: the unsold half of the supply above, the whole
net pot below as permanently locked bid liquidity. Every committer receives
`tranche × committed / total`, and the claimant who completes the committed
weight receives the exact remainder, so nothing strands.

`clearingPrice()` returns `p*` as a Q96 square root of **wrapped native per
platform coin**, whichever currency slot the coin sorted into — the direction a
committer thinks in. It is zero before settlement and whenever nothing was sold.
The pool opens at exactly `p*` (since v1.6.12; this page said "at or just below"
until v1.6.24, describing the aligned opening that version removed), carried in
the pool's own direction by `Settled(committed, sold, clearingSqrtPriceX96)`.

**When the pot does not clear** (v1.6.24, AstraSec M-2). A pot below
`FeastGenesis.MIN_POT` (1 BNB, owner to confirm before the ceremony), or one whose
price cannot be represented, is **no participation**: `settle` opens the pool
single-sided at the opening the genesis key signed, sells nothing
(`Settled(total, 0, 0)`, `tranche() == 0`), `claim` reverts `NothingWasSold()`,
and `refund` returns every commit in full. This holds in both currency orderings;
until v1.6.24 one wei either stranded the window's 60% of the supply or bought
the whole tranche, depending on which slot the coin sorted into. Show the floor
next to the pot, and show "refunds open" — not "claim" — after a no-sale settle.

**Before settlement the pool does not exist.** Genesis registers it and does not
initialise it, because the price it must open at is not known until the window
closes. A swap against it reverts `PoolNotInitialized()` from the venue, before
the hook is consulted; between settlement and `openAt` the hook's gate takes
over. Show the two states differently: "not open yet" and "opening at X" are not
the same screen.

**The platform coin has no price until it trades.** Seeding writes no oracle
observation — only a swap does — so `FeastPricer.platformPerNativeQ128()`
answers `Unpriceable` from the open until the first real trade has aged past
`TWAP_WINDOW` (600 s; 300 s before v1.6.24). That is the honest answer, not an
outage; do not render it as one.

**`settle` has no deadline** (v1.6.24). It may be called from `endsAt` until it
succeeds — after `openAt` too, in which case the pool opens to everyone in the
settling transaction — so the window's 60% of the supply always reaches the
pool. The AUCTION expires: from `abandonAt()` — `ABANDON_AFTER` (seven days,
owner to confirm) after the close, plus every second the guardian has held the
brake — `settle` takes the no-participation branch whatever the pot, and an
unsettled window refunds every commit in full, in wrapped native. Until v1.6.24
a window not settled by `openAt` could never settle and its supply had no exit.
`refund` lowers `total()` by what it returns. A settle that refuses with
`Frozen()` is the guardian's brake: wait, it lifts by itself. The pot pays the
1% fee like any trade — `settle` transfers it to the platform sink as wrapped
native, on no ledger track.

**The window's start is never in the past** (v1.6.24, AstraSec I-9): a window
deployed after its `startsAt` opens at its deploying block, and `endsAt` and
`lockAt` follow from that, so it always runs its whole 24 hours.

## The genesis partners — `FeastGenesisGrants`

```solidity
function partners() external view returns (address[8] memory);   // address(0) = not yet named
function assignPartner(uint8 slot, address partner) external;    // team multisig, once, <= 90 days
function burnUnfilledSlot(uint8 slot) external;                  // anyone, after the window
function assignedAt(address partner) external view returns (uint64);
function slotBurned(uint8 slot) external view returns (bool);
```

From v1.6.12 a genesis may name **fewer than eight** partners. An empty slot reads
`address(0)` and can be filled once, by the team multisig — the same address that holds the
guardian's brake — while `FeastGuardian.sunsetAt()` has not passed. Render an empty slot as
"not yet named", with that deadline, rather than as a partner with no address.

**A filled slot is immutable.** `assignPartner` on a slot that already holds somebody reverts
`SlotAlreadyFilled(slot, partner)`, whether it was filled at genesis or last week. Nobody can
replace, remove or reassign a partner, and the call moves no tokens.

**A late partner starts late.** `assignedAt(partner)` is the instant their slot was filled, and
an emission week that had already closed by then counts zero toward their grant. The six-month
unlock horizon runs from genesis and is not restarted — show a partner assigned on day 85 the
remaining horizon, not a fresh one.

**A slot nobody fills burns.** After the window, `burnUnfilledSlot(slot)` is callable by anyone,
once; `slotBurned(slot)` says whether it has happened.

## The guardian — `FeastGuardian`

```solidity
function isFrozen(PoolId poolId) external view returns (bool);
function isFrozenAll() external view returns (bool);
function creationStopped() external view returns (bool);
function sunsetAt() external view returns (uint64);   // genesisAt + 90 days
function budgetLeft() external view returns (uint64); // frozen seconds still available
function frozenUntil() external view returns (uint64);
function guardian() external view returns (address);
```

feast has no owner; this is the one exception, and the app should say what it is rather than
leave a user to discover it. The guardian can do exactly two things and **cannot move a balance**:

- **stop new coin creation**, once and for ever (`creationStopped()`). `create` then reverts
  `CreationStopped()`. Nothing else changes: existing pools trade, claims pay, the window settles.
  This power does **not** expire.
- **freeze outflows** for at most 72 hours at a stretch, at most 168 hours in total, and not at
  all after `sunsetAt()`. A freeze covers either everything (`isFrozenAll()`) or one pool
  (`isFrozen(poolId)`).

**Render a freeze as a pause, not as a fault.** Every guarded call reverts with a named
`Frozen()` from the contract it was made on — `FeastHook.Frozen`, `FeastEmissions.Frozen`, and so
on. Show `frozenUntil()` as a countdown: it lifts by itself and needs nobody to act.

**What a freeze never touches**, and the app should not grey out:

- the launch window's `commit`, `withdraw`, `claim` and `refund` — the committers' own money,
  and `withdraw` has a deadline a freeze must never eat. **`settle` is the one exception**
  (v1.6.24): it refuses with `FeastLaunchWindow.Frozen()` under an `ALL` freeze. It has no
  deadline any more, and the auction's `abandonAt` moves by every frozen second, so waiting
  costs nothing but time;
- a holder's own tokens — transfer, approve, delegate and burn are ordinary ERC-20 and
  ERC-20Votes calls on the user's own balance.

An `ALL` freeze also refuses `create` at the door (`FeastFactory.Frozen`), so a creation form
should read `isFrozenAll()` as well as `creationStopped()`.

**The address is `TEAM_MULTISIG`** — the same Safe that proposes to the three-day timelock —
fixed at construction with no setter and no transfer. The two roles are separate powers on one
key, and the honest sentence for a FAQ is in `plans/audit/guardian-design.md` §5.

## The team's vesting — `FeastTeamVesting`

OpenZeppelin's `VestingWallet`: `releasable(token)`, `release(token)` (anyone;
pays the beneficiary), `start()` = the window's close, `duration()` = 36 × 30.4375
days, no cliff. It never votes and cannot be renounced.

## The platform sink — `FeastPlatformSink`

```solidity
function open(address asset) external;                        // anyone, over a lot that holds something
function priceQ128(address asset) external view returns (uint256); // platform coin per raw unit, 128.128
function take(address asset, uint256 amountOut, uint256 maxCoinIn) external returns (uint256 cost);
function burnStray() external;
```

Every asset the platform's fee share arrives in is offered for the platform
coin at a price that halves every hour (linearly within the hour) and rises after
each sale by the share of the lot sold. Whoever takes it pays in the platform
coin, which is burned on the spot. There is no oracle and no route; before an
asset's first sale its price can fall towards zero. After a sale *inside the
descent that is running*, it never falls below that sale's price — weighted by
the share of the lot the sale took, so a dust purchase seeds a floor of dust —
halved six times; that floor then halves every 24 hours since the sale, so a
quote the market has left behind stops holding a price up within days; and
opening a new descent clears it, because a floor is what a sale said about the
lot its own descent priced.

**A descent prices the lot it was opened over** (v1.6.2). `open` refuses a lot
with nothing in it (`NothingToOffer`); refuses before the sink's opening, which
genesis fixes once by naming the launch window — the sink checks that window's
role and coin and reads its close (`NotOpenYet`, and `PlatformCoinNotLive` while
the coin has no code at all) — the sink ships before
the coin does, and the coin's whole supply is in a gated pool and an unsettled
window until that moment, so a price falling before it could only be a timer; and
refuses a lot that is already descending unless it now holds at least twice what
it held when that descent began, or less than it held then (`AlreadyOpened`). A lot that does — which includes every refill into a
lot that was taken to empty — reads at the start price until someone opens a
descent over it. So an app must not treat a quote as a function of time alone:

- **`priceQ128` reads the sink's live balance, and a transfer in the same block
  can move the quote either way.** A transfer that brings the lot to twice what
  its descent priced switches the quote from that descent to the start price —
  upwards if the descent had fallen below it, which is the ordinary case, but
  *downwards* if the descent had climbed above it (each take re-anchors at
  `price × (1 + f)`, so a lot bought in pieces can be priced above the start
  price). A balance that *falls* below what the descent priced — which only an
  asset that can shrink a holder's balance can do — switches it the same way. And
  the switched-to quote is floored, so it can itself exceed the start price when
  the last sale was above it.
- **Quote and take in one transaction, and always set `maxCoinIn`.** A take is
  priced through the same rule as the view, so a refill that lands between a
  quote and a take is priced as the new lot it makes. With `maxCoinIn` set, the
  worst a change between them can do is make the take revert
  `CostAboveLimit(cost, maxCoinIn)`; it can never make a taker pay more than they
  allowed.
- **A lot nobody opens does not sell.** That is the safe way round, and opening
  is permissionless — the call only ever starts a descent, which only ever
  lowers the price.
- **A take from a lot that reads at the start price restarts its descent there**
  (v1.6.25, AstraSec M-3). The take pays the quote the view showed — the start
  price, or the floor if that is higher — and from that take the lot descends
  from the start price again. It keeps its floor, and the take never enlarges
  the size its descent prices (so `open` is still accepted while the lot reads
  from the top, and still clears that floor).
  Until v1.6.25 the descent's clock kept running underneath the start-price
  quote, so a take that brought the lot back into its band landed it on an
  older, lower curve that no quote had shown: measured, one raw unit at the top
  for 2^64 wei, then the rest of a 200e18 lot for 0.288 FEAST. Now the quote
  after such a take is never below the start price at that moment. The one case
  the sink cannot see is a lot that leaves its band and comes back with no take
  in between — only an asset that can shrink a holder's balance can do that —
  and a keeper's `open` is the answer there.
- **The floor moves with time too.** A quote is bounded below by the last sale
  that RAISED it — its price weighted by the share that sale took, halved six
  times and then halved once per 24 hours since it. A later sale whose own
  effective floor is lower leaves the standing one in place, so the floor is not
  reset by every sale and the guarantee is the weaker one `FeastPlatformSink`
  states at its `_floorNow` (eight ninths of the chord, less four raw price
  units) rather than "the last sale's floor, from that sale's clock" (v1.6.7,
  the v1.6.6 pack's coverage lens, L5). Two quotes a day apart can still differ
  by the floor's own step even when no take happened in between — and an `open` in between
  removes the bound entirely. Quote at the moment you send the take.

## Governance — the timelock

**One governed parameter set, one path.** OpenZeppelin's `TimelockController`
with a three-day delay: the team multisig is its only proposer (committed to
propose only Snapshot-passed changes), anyone may execute a matured proposal, and
it has no admin but itself. The only functions it can meaningfully call are the
three emission levers above, each bounded at the callee. There is no on-chain
Governor (owner ruling Q27); the proposer role is the timelock's own to reassign,
so a Governor can take over later without redeploying anything.

## What feast does not control

Worth surfacing in the UI, because a user will otherwise read a failure as a
feast bug:

- **The venue can be paused.** Swaps and liquidity changes on the underlying
  exchange are pausable by its own operator. Feast has no admin; the venue it is
  built on does.
- **The venue takes a share of the LP fee** — 33% at the time of writing, at a
  rate its operator can change. Feast's 1% is separate and untouched by it.
- **Quote tokens are upgradeable proxies** that can pause transfers and screen
  addresses. When one does, that pool's swaps and quote-denominated claims fail
  until it lifts — but the accounting is untouched, every other pool keeps
  trading, and the coin can still buy itself back, because that path never moves
  the quote token at all.

## The creator's pre-buy — `FeastFactory` (v1.6.10)

The creator's stake in their own coin is a **paid trade at creation**, not a
free allocation. They spend quote in the `create` transaction, the quote stays
in the pool's permanently locked liquidity, and the coins bought go straight to
`FeastVesting` on the schedule they chose.

```solidity
event CreatorPrebuy(address indexed coin, uint256 quoteIn, uint256 coinsOut, uint64 vestingEnd);

/// (0, 0, 0) for a coin created without one.
function prebuyOf(address coin) external view returns (uint256 quoteIn, uint256 coinsOut, uint64 vestingEnd);
```

One view and one event, so the coin page renders *"the creator pre-bought 4.2%
of supply for 12.5 WBNB · vests 6 months"* — or *"· sellable at any time"* when
`vestingEnd` equals the creating block's timestamp — without an indexer. The
percentage is `coinsOut / supply`, and the supply is in `CoinCreated` and in
`getCoin(coin)`.

It is an ordinary trade for the fee: it pays the 1% like everyone, and the
creator's 50% share of that fee is theirs exactly as it is on any other trade of
their coin. It is exempt from the per-wallet opening cap — recognised
structurally, never by `tx.origin` — and bounded instead by
`MAX_PREBUY_BPS_OF_SUPPLY` (20% of supply, measured in coins received). The
creator's **next** buy, from their own wallet, is capped at 0.5% like anyone's.

A WBNB creator wraps first: a native quote is not representable anywhere in this
system. The platform coin's genesis has no pre-buy.
