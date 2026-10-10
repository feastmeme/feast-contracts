# Lifetime referrer binding

**Status: rebuilt in v1.6.26 (AstraSec M-4).** The binding moved out of the hook
into `FeastReferrals`, and a wallet binds only by its own call or its own
signature — never by a trade. The next section is the binding as it ships.

**Built, tested and sealed as v1.6.8-internal**, on top of `v1.6.7-internal`.
§1–3 are the design as it shipped then, §4 records how the design stop's six
questions were ruled, §5 is what a third-party integrator needs, and §6 records
the baseline error that cost this lane a build and how it was caught.

Ruled by the owner on 2026-09-18. Today the referrer is a property of a
*trade*: a router puts one ABI-encoded address in `hookData`, the hook credits
it `referrerBps` of that trade's fee, and nothing is remembered. A wallet
brought by a KOL's link pays the KOL on the buys made from the page that carried
the link and on nothing else — another coin, another device, another terminal,
and the introduction is worth nothing. The ruling makes the relationship a
property of the **wallet**, held in the hook, for life:

- every later trade of that wallet, through any router, pays the referrer who
  brought it;
- **no re-binding** — no `setReferrer`, not for the owner, not for anyone;
- the binding is **authorised by the wallet itself**, so nobody can bind a
  stranger to themselves;
- it costs the user no signature and no second transaction: the binding happens
  inside the first trade that names a referrer.

This is v1.6.8-internal, and it is the last window: the audit has not started
and the mainnet contracts are immutable afterwards.

**No contract outside `src/FeastHook.sol` changes.** The factory, the vault, the
converter, the oracle, the epoch ledger and `FeastConstants` are all untouched,
and the design needs nothing from any of them.

---

## v1.6.26 — authenticated, never inferred (AstraSec M-4)

**This section is the binding as it ships.** §1–§3 and §5 below are v1.6.8's
design record, kept because their measurements and rulings are cited; each says
what v1.6.26 changed in it.

### What was wrong

v1.6.8 bound `_referrerOf[tx.origin]` from the first 64-byte `hookData` whose
wallet word equalled `tx.origin` — the subject was the one party calldata cannot
forge, and the authorisation was a comparison with it. Under ERC-4337, and for
every 7702 sponsor and relayer, `tx.origin` is the party that SUBMITS the
transaction while somebody else writes its calldata. One user operation carrying
`abi.encode(attacker, bundler)` therefore bound the bundler to the attacker for
life, and every later trade the bundler relayed paid the attacker. The v1.6.20
lens found it (`HK23-claude`, `test/audit/poc/SharedOriginCapture.t.sol`, carried
with its red run recorded); AstraSec raised it as M-4 on 3 October; the owner
ruled on 4 October to fix it rather than carry it.

### The ruling

**A binding is authenticated, never inferred.** A wallet is bound only by its
own call or by its own signature. The chain cannot tell a bundler's key from a
user's, so there is no "only for the risky cases" switch: no trade binds
anybody, in any form.

### How a wallet binds

The binding lives in `src/FeastReferrals.sol`, an immutable registry with no
admin, no setter, no clear and no upgrade path:

```solidity
mapping(address wallet => address referrer) public referrerOf;
function bind(address referrer) external;     // binds msg.sender
function bindWithSig(address wallet, address referrer, uint256 deadline, bytes calldata signature) external;
event ReferrerBound(address indexed wallet, address indexed referrer);
```

- `bind` binds the caller: an EOA by a transaction, a contract account by its own
  call — for an ERC-4337 account, `bind` batched in a user operation.
- `bindWithSig` binds `wallet` on the wallet's own EIP-712 signature, and anyone
  may relay it. OpenZeppelin's `SignatureChecker.isValidSignatureNow` checks it:
  ECDSA for a wallet without code, ERC-1271 for one with code (a contract
  account, or a 7702-delegated EOA through its delegate).
- Domain `EIP712Domain(string name,string version,uint256 chainId,address
  verifyingContract)` = `FeastReferrals`, `1`, the chain, the registry; struct
  `Bind(address wallet,address referrer,uint256 deadline)`. The separator is
  computed on every call, so it follows the chain id through a fork with no
  cache to invalidate. The signing payload as JSON, and test vectors computed
  twice outside Solidity, are in `docs/interface.md`.
- No nonce: a wallet binds once, so a signature that has bound can only meet
  `AlreadyBound` again. `deadline` bounds an unused signature's life
  (`SignatureExpired` after it). An unexpired signature is a standing consent:
  whichever lands first, the wallet's own `bind` or a relay of the signature, is
  the binding.
- The refusals are the hook's own, unchanged since v1.6.8, and reached from both
  entries through one `_bind`: `ZeroReferrer`, `SelfReferral`, `BurnReferrer`,
  `AlreadyBound`; and `BadSignature`. The signature is checked first, so a
  relayed call learns nothing about a wallet that did not sign it.

### What the hook does

`FeastHook` keeps the registry as `referrals` (a constructor input) and reads it
in `_referrerFor`, after the protocol-initiated short-circuit, which is
unchanged. `b` is `referrals.referrerOf(tx.origin)`, `r` the named referrer, `w`
the named wallet; the first matching row decides:

| # | `hookData` | `b` | `r` | `w` | Paid |
|---|---|---|---|---|---|
| 1 | any | `b ≠ 0` | — | — | **`b`** — `hookData` is not consulted |
| 2 | not 32 or 64 bytes | `0` | — | — | nobody |
| 3 | either form | `0` | `r == 0` | — | nobody |
| 4 | either form | `0` | `r == tx.origin` | — | nobody — a payer is no referrer |
| 5 | 32 bytes | `0` | `r ≠ 0`, `r ≠ tx.origin` | — | `r` |
| 6 | 64 bytes | `0` | `r == 0x…dEaD` | any | nobody — the burn address is not a referrer |
| 7 | 64 bytes | `0` | `r ≠ 0` | `w == r` | nobody — the account named is no referrer either |
| 8 | 64 bytes | `0` | `r ≠ 0` | `w ≠ r` | `r`, for this trade only |

**No row binds.** v1.6.8's row 9, the only binding entry, is gone, and with it
the `_referrerOf` mapping, its write, the hook's `ReferrerBound` event and — by
the ruling below — the hook's `referrerOf` view.

### What did not fit, and what that costs

The hook was 24,566 bytes of EIP-170's 24,576 at v1.6.25. The brief's shape —
the view kept, and the 64-byte form's wallet word looked up as a smart account's
own binding — measured 24,887. The coordinator authorised two relaxations on
2026-10-04, in order, each only if the build before it was still over:

1. **The hook's `referrerOf` view is dropped.** The app reads
   `FeastReferrals.referrerOf`. Still over at every spelling of the read: 24,596
   at best.
2. **The wallet-word lookup is dropped.** Lifetime binding applies through
   `tx.origin` only, and the 64-byte form behaves like the 32-byte form: per
   trade, never binds, keeping its two refusals. **A smart account's lifetime
   binding is honoured only on its own direct trades** — and an ERC-4337 account
   is never `tx.origin`, so on its bundled trades its binding is recorded but not
   read; what pays is the referrer the trade names. An integrator that wants an
   account's referrer paid reads `referrerOf(account)` and names it per trade.
   **This is a bytecode decision, not a design one.**

The one read left is the Solidity call spelled in assembly — 24,602 as Solidity,
26 over; 24,541 as shipped, margin 35 — with the decoder's own checks: a failed
call, a short answer or a dirty word refuses the trade rather than paying a
garbage word, and four tests pin each of those. Every byte decision is in
`docs/audit/v1.6.26-changes.md`.

**Two consequences, stated so that nobody discovers them.** A bundler can no
longer be bound by a user operation; but a bundler that binds ITS OWN key, by its
own call or signature, is paid on every trade it originates, as any bound EOA is.
That is AstraSec I-1's boundary, accepted for v1.6.24, narrowed to the bundler's
own act. And the registry is shared by every pool: one binding is one fact about
a wallet, as it was in the hook.

### Gas

- **Every fee-paying trade: +3,042**, measured as the same plain trade on
  `FeastReferrerBindingTest`'s fixture at `bf1d930` (233,767) and at v1.6.26
  (236,809), every fixture address the same. The lookup is now a cold account and a cold slot in the registry,
  and the call, where it was one cold slot in the hook.
  `test_gas_theLookupCostsOneColdExternalReadOnEveryTrade` holds it at ±5%.
- **Binding, once per wallet, ever:** `bind` 52,650; `bindWithSig` for an EOA
  58,376 — measured under `isolate`, held by `FeastReferralsTest`'s two gas
  tests. v1.6.8's 21,984 in-trade binding is gone with the in-trade binding.

### The invariants this touches

| | Effect |
|---|---|
| **I7 — per-pool isolation** | Amended as v1.6.8 amended it, and the global fact has moved: the hook holds no referral state that is not keyed by pool, and the one wallet-to-referrer fact lives in the registry, written only by the wallet. |
| **I3 — no economic parameter changes after creation** | Held. The registry has no setter, clear or owner (`test_thereIsNoSetterNoClearAndNoOwner`; `tools/check-boundaries.py`'s authority scan reads every file in `src/`, the registry included), and the hook has no binding entry at all (`test_noReferrerSetterExists` now also asserts `bind`, `bindWithSig` and `referrerOf` are absent from it). |
| **I1 / R3 — no swap refused by fee accounting** | Held. No length of `hookData` refuses a trade. The registry read can refuse only if the registry misbehaves, and the registry is immutable code whose getter has no revert path of its own. |
| **I14 — nothing strands at a dead address** | Held: the registry refuses binding the burn address; the 64-byte form still refuses naming it; the 32-byte form may still name it, once. |
| **`FeastFeeLedger` — the referral track** | Held, unchanged in shape: a bound wallet's referrer is credited on every trade that wallet originates, on every pool, whatever `referrerBps` is. |
| **reentrancy** | Held. The read is a static call to an immutable registry whose getter calls nothing; `_referrerFor` is now `view`. |
| **open-gate, internal-fill, trade-record, LP fees, the buy-back button** | Untouched: the protocol-initiated short-circuit is kept exactly. |

### What holds it

- `test/FeastReferrals.t.sol` (22): both entries; an ERC-1271 account by
  signature and by its own call; relay by a third party; the deadline from both
  sides; replay; every refusal by both entries; first-wins; the domain binding a
  signature to its chain and registry; malformed signatures; the EIP-712
  vectors.
- `test/FeastReferrerBinding.t.sol` (35), rewritten: a wallet bound by call or
  signature paid on every pool and router; the 64-byte trade that bound until
  v1.6.25 binds nothing; a terminal cannot bind an unbound wallet; no trade of
  any shape binds; **the M-4 regression**, a user operation naming the bundler as
  the wallet binding nothing; the two consequences above; and the assembly
  read's four refusals.
- `test/audit/poc/SharedOriginCapture.t.sol`, un-skipped against v1.6.26 with
  its read pointed at the registry: green (it is red at `bf1d930`). Un-skipping
  it in the tree is the follow-up of the lane that holds `test/audit/`.

---

## 1. The encoding

> **Superseded in v1.6.26.** Both forms still parse exactly as below, and no length
> refuses a trade; but the 64-byte form no longer binds — it pays per trade, and its
> wallet word feeds only its two refusals. The `_referrerOf` mapping, the hook's
> `referrerOf` view and its `ReferrerBound` event below are gone; the binding is
> `FeastReferrals`'.

`hookData` gains one accepted length. Both forms below are read by
`_referrerFrom`, and **no length reverts a trade** — that is R3, and it is the
whole reason this function exists rather than an `abi.decode`.

| Bytes | Form | Built by | Means |
|---|---|---|---|
| 0, or anything not 32 or 64 | none | anybody | no referrer, no binding, no revert |
| 32 | legacy | `abi.encode(referrer)` | referrer **for this trade only**, never binds |
| 64 | binding | `abi.encode(referrer, wallet)` | referrer for this trade, **and** binds `wallet` if `wallet` is the signer |

The legacy form is exactly what v1.6.7 accepts and behaves exactly as it does
today. Every integrator built against v1.6.7 keeps working with no change and no
deadline.

### What `_referrerFrom` becomes

It stays `private pure` and gains a second return value:

```solidity
function _referrerFrom(bytes calldata hookData) private pure returns (address referrer, address wallet) {
    if (hookData.length == 32) return (_addressFrom(bytes32(hookData[0:32])), address(0));
    if (hookData.length == 64) {
        return (_addressFrom(bytes32(hookData[0:32])), _addressFrom(bytes32(hookData[32:64])));
    }
    return (address(0), address(0));
}
```

`_addressFrom` is the word-to-address reader lifted out of today's body
unchanged, and it is now applied to **both** words:

```solidity
function _addressFrom(bytes32 word) private pure returns (address) {
    uint256 value = uint256(word);
    if (value > type(uint160).max) return address(0);
    return address(uint160(value));
}
```

Not `abi.decode(..., (address))`, for the reason the current source already
gives: decoding an address *reverts* when the top 96 bits are dirty, and a
router that passed a full-width word of garbage would revert the swap behind it.
Fuzzing found that on the referrer word; the wallet word is the same hazard and
gets the same reader. A dirty wallet word therefore reads as `address(0)`, which
is never the signer, so such a trade pays per-trade and does not bind — it is
never an error.

`hookData[0:32]` and `hookData[32:64]` are calldata slices, so the 32-byte form
costs the same read it costs today and the 64-byte form costs one more word.

### What the app must pass

- While a user is unbound and the session carries a referrer (a KOL link, a
  terminal's own address): pass `abi.encode(referrer, userWalletAddress)`.
  `userWalletAddress` must be the EOA that signs the transaction.
- Once bound, `hookData` no longer matters: pass `""` and the bound referrer is
  still paid. Checking `hook.referrerOf(user)` first is an optimisation, not a
  requirement — passing the 64-byte form to a bound wallet is harmless and is
  simply ignored.
- A terminal with no referrer of its own should pass `""`, not the 64-byte form
  with a zero referrer; both do the same thing, and the shorter one is cheaper.
- **A smart-contract wallet cannot bind**, because the hook can only recognise a
  signer as `tx.origin` and a bundler is not the account. Such trades pay the
  per-trade referrer, as today. See §3.

### The state, and what reads it

```solidity
/// @notice The referrer a wallet is bound to, for life. Global, not per pool.
mapping(address => address) internal _referrerOf;

function referrerOf(address wallet) external view returns (address);

event ReferrerBound(address indexed wallet, address indexed referrer, PoolId firstPool);
```

It is written in exactly one place — `_referrerFor`, below — and only ever from
zero to non-zero. There is no setter, no owner path and no clear. The build
station adds `test_noReferrerSetterExists`, the same bytecode-level evidence
`test_noShareSetterExists` gives for the shares, over
`setReferrer`, `setReferrerOf`, `bindReferrer`, `rebindReferrer` and
`clearReferrer`.

---

## 2. The rule

> **Superseded in v1.6.26.** The rule as it ships, and its truth table, are in the
> v1.6.26 section above: row 9 below, the only binding entry, is gone, and `b` is
> read from the registry.

One function replaces `_referrerFrom` at the two accrual call sites. It answers
"whose commission is this trade's?" and is the only place a binding is written.

```solidity
function _referrerFor(PoolId poolId, bytes calldata hookData) private returns (address) {
    address origin = tx.origin;

    address bound = _referrerOf[origin];
    if (bound != address(0)) return bound;                 // the binding is supreme

    (address named, address wallet) = _referrerFrom(hookData);
    if (named == address(0)) return address(0);
    if (named == origin) return address(0);                // a payer is no referrer

    if (wallet != address(0)) {                            // the binding form
        if (named == FeastConstants.BURN_ADDRESS) return address(0);  // not a referrer
        if (named == wallet) return address(0);            // nor is the account named
        if (wallet != origin) return named;                // bundler shape: no bind
        _referrerOf[origin] = named;
        emit ReferrerBound(origin, named, poolId);
        return named;
    }

    return named;                                          // legacy: this trade only
}
```

### Truth table

`b` is `referrerOf[tx.origin]`, `r` the named referrer, `w` the named wallet.
Rows are evaluated top to bottom; the first that matches decides.

| # | `hookData` | `b` | `r` | `w` | Paid | Binds |
|---|---|---|---|---|---|---|
| 1 | any | `b ≠ 0` | — | — | **`b`** — `hookData` is not consulted | no |
| 2 | not 32 or 64 bytes | `0` | — | — | nobody | no |
| 3 | either form | `0` | `r == 0` | — | nobody | no |
| 4 | either form | `0` | `r == tx.origin` | — | nobody — a payer is no referrer | no |
| 5 | 32 bytes | `0` | `r ≠ 0`, `r ≠ tx.origin` | — | `r` | no |
| 6 | 64 bytes | `0` | `r == 0x…dEaD` | any | nobody — the burn address is not a referrer | no |
| 7 | 64 bytes | `0` | `r ≠ 0` | `w == r` | nobody — the account named is no referrer either | no |
| 8 | 64 bytes | `0` | `r ≠ 0` | `w ≠ r`, `w ≠ tx.origin` | `r` — the per-trade rule | no |
| 9 | 64 bytes | `0` | `r ≠ 0` | `w ≠ r`, `w == tx.origin` | `r` | **yes** |

Row 4 is not new. **v1.6 ruling 5, Q5 already refused a referrer who is the
payer**, in the 32-byte parser. This change moves that refusal up one level,
into `_referrerFor` above the split between the forms, so it now covers both
lengths from one line instead of living in one parser and being restated for the
other. There is no self-rebate anywhere in this contract, so there is none to
make permanent, and §4's Q4 records how nearly this went the other way.

Row 9 is the only binding entry in the contract. Three further facts complete
the rule, and each of them is a test:

- **Nothing here runs on a fee-free trade.** `_referrerFor` is called only from
  the two accrual sites, and both are behind the fee's own guard —
  `beforeSwap` has already taken its fee-free branch, `afterSwap` accrues only
  when `fee != 0`. A dust trade whose fee rounds away neither pays nor binds.
- **A binding is written only by a trade that succeeds.** The write happens in
  `beforeSwap` or `afterSwap`, so the opening-window cap (R5) and the
  specified-quote partial-fill refusal (R18) both take the binding down with the
  transaction they revert.
- **A pool with `referrerBps == 0` still binds.** The trade named a referrer;
  the pool simply pays no commission on it. So the cheapest place to bind is a
  pool that pays nothing, which is a fact about cost, not about soundness.

### Why the subject is `tx.origin` and never the named wallet

`tx.origin` is the one party to a swap that calldata cannot forge. The venue
hands a hook the *router's* address as `msg.sender`, and a wallet named in
`hookData` is a claim made by whoever built the calldata. If the payment lookup
keyed on that claim, any terminal could strip a lifetime binding by naming some
other wallet — and the promise "every later trade, through any router, pays the
referrer who brought you" would hold only for routers that felt like honouring
it. Keying on the origin is what makes it mechanically true.

It is also the identity the hook already uses three times over: the
opening-window cap keys `_purchased` on it, `FeastFeeLedger` credits it as the
payer, and `_emitTrade` reports it as the trader. Four sites now, documented in
all of them rather than in none.

The cost, stated rather than discovered: a trade submitted by a **bundler** on a
smart account's behalf has the bundler as its origin. It does not bind, and it
does not read the account's binding — it falls back to today's per-trade
behaviour, which is row 8. If the bundler's own EOA has itself bound, row 1
fires and the *bundler's* referrer is paid for somebody else's trade. That is
the price of the only unforgeable key, it is bounded by `referrerBps` of one
fee, and the alternative — believing the named wallet — hands every terminal a
bypass. The trade is deliberate.

---

## 3. What it costs, and what it touches

### Gas

> **Superseded in v1.6.26** for what it costs now: the v1.6.26 section above. The
> lookup test below is renamed `test_gas_theLookupCostsOneColdExternalReadOnEveryTrade`,
> and the binding test is gone with the in-trade binding.

Measured with `forge test`, `isolate = true`, one ordinary buy on a pool that
has already traded, `gasleft()` around the router call, every figure on the same
fixture. The v1.6.7 row is that tag's own `src/FeastHook.sol` under the same
fixture; the probe is archived at
`.runs/operator/spike/FeastV167GasBaseline.probe.sol`. Both figures are held by
tests — `test_gas_theLookupCostsOneColdSloadOnEveryTrade` and
`test_gas_theBindingCostsOneStoreAndNothingElse` — at a ±5% band.

All rows are a plain buy on a pool whose `referrerBps` is **zero**, so that no
commission credit sits inside the number being read.

**Every row below was measured at `optimizer_runs = 20_000`**, which was the
setting until 2026-09-19. The table is left as measured rather than restated,
because the rows are a history and rewriting them would erase the comparison
they were taken for. At the current setting (`1_000`) the same two ends of that
history measure **225,033** (v1.6.7, names nobody) and **227,694** (this tree,
names nobody): every contract got smaller and every trade got slightly dearer.
The difference between those two — what the mechanism costs — is unchanged at
2,661 against 2,634, which is the point.

| Case | Gas |
|---|---|
| v1.6.7, names nobody | 223,123 |
| v1.6.7, names a referrer (32-byte) | 245,942 |
| v1.6.8, names nobody | 225,499 |
| v1.6.8, names a referrer (32-byte) | 248,353 |
| v1.6.8, 64-byte form, wallet is not the signer — no binding | 231,665 |
| v1.6.8, 64-byte form, wallet is the signer — binds | 253,649 |

The two numbers the ruling asked for:

- **One SLOAD per trade, for ever: +2,756 gas** against v1.6.7. A cold `SLOAD`
  of `_referrerOf[tx.origin]` is 2,100; the rest is the widened length branch
  and, from v1.6.10, the test that keeps a protocol-initiated swap out of the
  referral track together with the arming of a gated pool's opening cap. Every
  trade in every feast pool pays this, bound or not, `hookData` or not.

  It was +2,376 through v1.6.9, and +2,634 once v1.6.10's two fixes landed; the
  next 27 are the optimizer's run count falling to 1_000, a 1.0% move that says
  the run count does not change what this lookup costs; and the last 95 are
  v1.6.10's creator pre-buy, whose structural test is a third clause every trade
  evaluates. Folding that test into one helper cost 154; splitting it so the
  call site does the immutable compare and only a factory swap reaches the
  transient load brought it to 95.
  The 258 gas v1.6.10 adds are warm reads and
  branches only: both new tests lead on `openAt`, which the gate has already
  read into a local, and the two fields that have cold slots of their own —
  `opener` and `capEndBlock` — are reached only by a pool that carries a gate,
  which is the platform coin and nothing else. An ordinary coin's trade touches
  no slot it did not touch at v1.6.9. The first draft of the fix read both
  fields unconditionally and cost 4,802; `test_gas_theLookupCostsOneColdSloadOnEveryTrade`
  is what caught it.
- **One SSTORE on the binding trade: +21,984 gas**, held as an in-tree
  subtraction of the last two rows — two trades of the same `hookData` length
  naming the same referrer, differing only in whether the wallet named is the
  signer, so the parse, the calldata and the ledger's referral track all cancel.
  The slot is warmed by the lookup a few opcodes earlier, so the
  zero-to-non-zero write is 20,000 rather than 22,100, and the `ReferrerBound`
  log is ~1,750. Paid once per wallet, ever.

**The +22,819 that naming a referrer costs is not this change**, and it is not a
commission either — the pool in every row pays none. It is
`FeastFeeLedger.record`, which opens a referral track for that referrer in that
week and quote. v1.6.7 pays it on any trade that names a referrer; v1.6.8 pays
it on every trade of a bound wallet. That is the subject of the ledger row in
the table below, and it is the largest economic consequence in this diff.

Two facts had to be learned before the subtraction was honest, and both are in
the test as comments. The pair must sit at equal depth in the sequence, or the
first is carrying whatever it warmed for the second — at one point that read as
an 18,239 binding on the earlier draft and a 26,485 one here. And nothing may
sit between the two measured trades, not even a view call: under `isolate` every
external call is metered as its own transaction, and one `referrerOf` read in
the middle moved the number by 4,501.

### The invariants this touches

Read out of `docs/plan.md` §3 and §4 in full, not grepped.

| | Effect |
|---|---|
| **I1 / R3** — no swap refused by fee accounting | Held, and the surface widens. 64 is now a meaningful length; every other length still reads as "no referrer" without reverting, and both words go through the dirty-high-bits reader. R3's ledger row needs its predicate restated as `length ∉ {32, 64}`. `testFuzz_anyHookDataIsSurvivable` in `FeastBuckets.t.sol` already fuzzes blobs under 200 bytes, so it covers the new length and must stay green unchanged; `test_noLengthOfHookDataRefusesATrade` adds the deterministic sweep, all-ones at nine lengths including both accepted ones. |
| **I6 — conservation** | Held, untouched. `_bank` is not modified: one referrer address per accrual, `referrerBps` of the fee, and the creator takes the remainder *of this accrual*. The four shares still sum to exactly the fee. What changes is only *how often* a non-zero commission occurs, and `testFuzz_theFourSharesStillSumToWhatWasTakenForABoundWallet` is the bound-wallet arm that says so. |
| **I7 — per-pool isolation** | **Amended, and this is the sharpest change in the diff.** `_referrerOf` is the first hook state that is not keyed by pool, and a trade on pool A decides who is paid on pool B. That is the feature. The isolation claim is about *value* — accrual, buckets, claims, caps, the oracle and the fee ledger's per-quote totals all stay strictly per pool or per quote, and pool B's four shares still sum to pool B's fee whoever the referrer is. What crosses is one global address-to-address fact that no pool's accounting depends on for soundness, that only the wallet itself can write, and that no pool can write *for* another wallet. I7 should say so explicitly rather than be quietly true. |
| **I3 — no economic parameter changes after creation** | Held. `referrerOf` is written by traders about themselves, never by an owner; there is no setter and no upgrade path, so `tools/check-boundaries.py`'s authority scan stays clean. Evidence, not assertion: `test_noReferrerSetterExists` against the deployed bytecode. |
| **I14 — nothing strands at a dead address** | Held, with one consequence and one question. On a pool whose creator is `BURN_ADDRESS` — which is how the platform coin launches — the commission is subtracted *before* the remainder folds into the burn bucket, so a bound trader now diverts `referrerBps` from the burn on that coin. That is the ruling working as intended, not a leak. Q2 closed the other half: `BURN_ADDRESS` is a valid non-zero address, so without a check a wallet could bind itself to it for life and burn `referrerBps` of every fee it ever paid. The binding form refuses it, for the trade as well as for the binding; the legacy form may still name it, because what the ruling refuses is making the choice permanent, not making it once. |
| **I8 — claims are pull-only and pay the recorded owner** | Held, untouched. A bound referrer is just an address that now appears in more pools' ledgers. `claimReferrer`, `claim`, `claimable` and `_claimTo` all key on `_referrerPending[poolId][account]` and are not modified. A referrer that cannot receive its quote strands its own bucket and nobody else's, exactly as an unreachable creator does. |
| **bounded-settlement (B5)** | Held, untouched. The cap and the debit-by-what-was-paid rule sit in the claim paths, which this change does not enter. |
| **R5 — the opening-window cap** | Held, untouched, and now sharing its key. The cap still reads `_purchased[poolId][tx.origin]`; a cap revert in `afterSwap` unwinds a binding written in `beforeSwap` along with the rest of the transaction. |
| **`FeastFeeLedger` — the referral track** | **This is the largest economic consequence in the diff, and it is not `referrerBps`.** `_accrue` calls `ledger.record(quote, payer, creator, referrer, amount)` on every gated-open trade, and it does so **whatever the pool's `referrerBps` is** — a pool paying no commission still writes the referrer's `referred` track. Before this change that happened only on trades a router chose to tag; now it happens on **every trade a bound wallet ever makes, on every pool, for ever**. The ledger is not a reporting surface: `FeastEmissions` prices `t.referred` into the weekly **REFERRER** pot (`wk.value[REFERRER] += referred × price`), and `FeastGenesisGrants` unlocks a partner's grant by `min(grant, grant × referred / TARGET_NATIVE)`. So a binding permanently routes a share of the **first year's emissions** and accelerates **genesis grant unlocks** toward whoever bound the wallet. That follows from the owner's ruling rather than contradicting it — "every later trade of that wallet pays the referrer who brought it" — but it is much larger than a commission, it did not exist on the tree the design stop was written against, and the owner should be shown it in these words before mainnet. Pinned by `test_aBindingCreditsTheReferrersLedgerTrackOnEveryTrade`. |
| **`emission-settlement`, `emission-claims`, `genesis-grants`** | Not modified, and not correct to call untouched. None of their arithmetic changes and no settled week can move — a week settles once, in order, after it closes. What changes is the *input*: more of the `referred` track, attributed to fewer addresses, for longer. The mechanisms are sound under any distribution of that track; the row above is about the distribution. |
| **`open-gate` — the launch window** | Held. A swap before `openAt` is refused for everyone but the pool's opener, and the window's own settlement swap carries no `hookData`, so it names no referrer and binds nothing. `_accrue` also skips the ledger entirely before the gate lifts, so a pre-open settlement cannot write a referral track either. |
| **`internal-fill`** | Held. An exact-input sale filled from the pool's own bucket returns from `beforeSwap` before any accrual; the fee on the whole sale is taken in `afterSwap`, which is where `_referrerFor` runs, so there is exactly one resolution per trade either way. |
| **`trade-record`** | Held, untouched. `_emitTrade` reports the payer as `tx.origin` and says nothing about referrers. |
| **LP fees** | Unchanged by construction: `collectLpFees` banks with `referrer = address(0)`, so LP fees never pay a referrer, bound or not. The binding applies to swap fees only. |
| **The buy-back button** | Cannot bind. The venue does not call a hook's callbacks when the hook is the swapper, so the button's swap never reaches `_referrerFor` and `referrerOf[hook]` can never be written. |
| **reentrancy** | Held. The binding is written before `_accrue` makes any external call — the argument is evaluated first — so the effect precedes every interaction. |
| **I11, I12, I13, I5, I10, I15, I2** | Not reachable from this diff. |

### What was done, and what holds it

- `test/FeastReferrerBinding.t.sol`: 27 tests, written red first. Fifteen failed
  on the behaviour they name before the rule existed; eleven were preservation
  tests that were green from the first commit and had to stay that way; one —
  the fee-ledger row above — went in green on purpose, because it pins a
  consequence rather than a decision.
- `tools/mutate.py`: five new mutations, one per predicate that stands between a
  referral link and a relationship nobody can undo — the subject, the
  authorisation, the supremacy of an existing binding, the burn-address refusal
  and the self refusal. Two older referral mutations went stale on the widened
  parser and were re-anchored rather than deleted; one of them moved to a
  witness that kills it deterministically instead of relying on the fuzzer to
  land on a 32-byte blob.
- `tools/check-census.py` and `docs/site-census.md`: `referral-binding` is a
  first-class mechanism with nine sites, plus four rows added to
  `swap-admission`, `fee-conservation` and `pool-isolation`. 261 rows, self-test
  passing, every row load-bearing. The gate earned its keep during this pass: it
  failed on a row naming `test_theLegacySelfRebateIsUnchanged` after Q4 was
  re-taken and that test was renamed.
- `docs/plan.md`: R3's predicate restated, I7 amended, **I16** added, and Q10 in
  §7 marked superseded — it still recorded self-referral as "allowed and
  documented", which v1.6 ruling 5, Q5 had already overruled.
- `README.md`: one row in the promises table.
- `docs/interface.md` and `docs/abi/FeastHook.json`: the 64-byte form, the
  `referrerOf` getter, the `ReferrerBound` event and §5.
- `test/FeastBytecodePin.t.sol`: `FeastHook` re-pinned, 24,133 → 24,447 bytes.
  **EIP-170 headroom fell 443 → 129 bytes**, which was the tightest this unit had
  ever been and is stated in the pin, in the seal receipt and here.

  **Superseded at v1.6.10.** The two fixes the v1.6.9 pre-audit round proved
  needed 212 of those 129 bytes, leaving `FeastHook` 83 bytes OVER the limit and
  undeployable. The owner lowered `optimizer_runs` from 20 000 to 1 000 on
  2026-09-19 rather than cut the fixes: `FeastHook` is now **22,155 bytes with
  2,421 to spare**, and the headroom exists for the external audit's own fixes.
  The cost is +0.9% gas on a plain trade, which is the trade the table above
  now records at both settings.

---

## 4. How the six questions were ruled

The design stop asked six. All six came back, and one of them came back twice.

| | |
|---|---|
| **Q1 — the census** | Granted. `referral-binding` is an entry in `tools/check-census.py`'s `INVARIANTS`, so the mechanism has a section of its own rather than being folded into `swap-admission`. Round 3's objection was that a guarded behaviour with no section is invisible. |
| **Q2 — the burn address** | Refused, as ruled. `0x…dEaD` is treated like the zero address in the 64-byte form, for the trade as well as for the binding. The 32-byte form may still name it: what the ruling refuses is making the choice permanent, not making it once. |
| **Q3 — the mutation ledger** | Granted. Five mutations, one per predicate standing between a referral link and a relationship nobody can undo. |
| **Q4 — self-referral** | **Ruled twice, and the second answer is the right one.** See below. |
| **Q5 — the disclosure** | Confirmed as a consequence the owner accepts, not an open question. It is §5, and it is in `docs/interface.md` in the same words. |
| **Q6 — the I7 amendment** | Confirmed, and in `docs/plan.md` as drafted. |
| **The subject** | `tx.origin`, never the named wallet. Confirmed: it is the only reading under which a terminal cannot strip a binding by naming somebody else. |

### Q4, and why it was answered wrong the first time

The design stop asked whether a per-trade self-referral pays anything today, and
reported that it does — quoting this contract's own docstring calling it "a
self-rebate at a rate the creator fixed at launch, not an exploit". The ruling
that came back was therefore "keep it unchanged in the legacy form, refuse it in
the binding form", which meant shipping an asymmetry and writing a paragraph to
justify it.

That reading was taken from `master`, which is **not** this line. On
`v1.6.7-internal` the 32-byte parser already carries
`if (referrer == tx.origin) return address(0);` — v1.6 ruling 5, Q5 — so a
per-trade self-referral pays **nothing** here. There was never a self-rebate to
preserve.

So the refusal moves up one level instead: one line in `_referrerFor`, above the
split between the forms, covering both lengths. No asymmetry, no paragraph, and
one fewer place for the rule to drift. The docstring that called it a self-rebate
was itself a leftover from the tree the design stop read, and it is gone.

---

## 5. What a third-party integrator has to know

> **Superseded in v1.6.26.** A trade no longer binds anybody: a wallet's first
> binding is the one it makes itself, by `bind` or by a signature somebody relays.
> The rest of this section — one binding for life, no remedy, and the ledger's
> track — still holds; `docs/interface.md` has the current note.

The full note is in `docs/interface.md`. The part that is not an API detail:

**The first Feast trade a wallet makes with a referrer named decides that
wallet's referrer for life** — on any pool, including a coin somebody launched
for the purpose, in the same transaction as a trade the user believes is
something else. A terminal that passes its own address for an unbound wallet
takes that wallet. **There is no re-binding, by anyone, ever** — no
`setReferrer`, not for the owner, not for the user — so there is no remedy
afterwards.

That is the owner's ruling and not an oversight: a second binding would be
unfair to the referrer who actually made the introduction, and would invite
poaching. And it is worth more than the commission, because of the ledger row in
§3 — a binding routes a share of the first year's emissions too.

An app that shows a user who they are about to be bound to, *before* they are
bound, is doing them a service. `referrerOf` is a public view for exactly that.

---

## 6. The baseline, and the build this cost

Recorded because the lane's own procedure is that a mistake is written down
where the next person will hit it, not in a message that scrolls away.

This work was first built against `master` (`4d008d1`, `anchor: sealed`), which
the task named as "= tag `v1.6.7-internal`, the sealed audit baseline". It is
not. `v1.6.7-internal` is `df999cb` on `feat/v1.6.5-preaudit`, **105 commits
ahead of `master`** on a line `master` has never merged: ten contracts `master`
has never seen — `FeastEmissions`, `FeastPlatformSink`, `FeastGenesis`,
`FeastGenesisGrants`, `FeastPricer`, `FeastLaunchWindow`, `FeastFeeLedger`,
`FeastPlatformToken`, `FeastPlatformTokenDeployer`, `FeastTeamVesting` — and
`FeastHook.sol` at +546/−201.

It was caught at the sealing step, by going to look at what a `-internal` tag
had contained before creating one. `git tag --contains` was the whole diagnosis.
The tag was not created, the lane handed back, and the branch was afterwards
rebased onto `v1.6.7-internal` and rebuilt against it.

Two things that only the real baseline could have told us, and both are in this
document rather than in an audit finding:

- **Q4 inverts.** §4.
- **The binding reaches the emissions ledger, not just the commission.** §3.
  `FeastFeeLedger` did not exist on `master`, so neither did the consequence.

The cost of the mistake was one build. The cost of not catching it would have
been a `v1.6.8-internal` tag pointing at a tree 105 commits behind the version
it claimed to succeed, handed to an audit that had not started.
