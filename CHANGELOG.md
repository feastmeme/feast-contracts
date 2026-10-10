# Changelog

Releases before v1.6.26 are recorded one note per release under `docs/audit/` —
`changelog-v1.6.22.md`, `changelog-v1.6.23.md`, `v1.6.24-changes.md`,
`v1.6.25-changes.md` — and in the commit history.

## v1.6.26 — 2026-10-04 — the referral binding moves into `FeastReferrals` (AstraSec M-4)

AstraSec's update of 3 October raised **M-4**: `_referrerFor` bound
`_referrerOf[tx.origin]` whenever a 64-byte `hookData`'s wallet word equalled
`tx.origin`. Under ERC-4337 the origin is the bundler, so one user operation
carrying `abi.encode(attacker, bundler)` bound the bundler to the attacker for
life, and every later trade it relayed paid the attacker. Owner ruling, 4
October: **a binding is authenticated, never inferred.**

### Added

- **`FeastReferrals`** (`src/FeastReferrals.sol`, 1,472 bytes): an immutable,
  admin-less registry. `bind(referrer)` binds the caller.
  `bindWithSig(wallet, referrer, deadline, signature)` binds `wallet` on its own
  EIP-712 signature of `Bind(address wallet,address referrer,uint256 deadline)`
  (domain `FeastReferrals`, version `1`, chain id, the registry) — ECDSA for a
  key, ERC-1271 for a contract account — and anyone may relay it. No nonce: a
  wallet binds once, and `deadline` bounds a signature's life. Refusals:
  `ZeroReferrer`, `SelfReferral`, `BurnReferrer`, `AlreadyBound`,
  `BadSignature`, `SignatureExpired`. Event `ReferrerBound(wallet, referrer)`.
- **`FeastHook.referrals()`**: the registry the hook reads.

### Changed

- `FeastHook`'s constructor takes `referrals_`, after `guardian_`.
- `FeastHook` reads `referrals.referrerOf(tx.origin)` on every fee-paying trade:
  a bound wallet's referrer is paid whatever `hookData` names.
- **No trade binds anybody.** The 64-byte `hookData` form pays the referrer it
  names for that trade only, as the 32-byte form does, and keeps its two
  refusals (the burn address; the wallet it names).
- `script/DeployPackage1.s.sol` deploys the registry immediately before the
  hook.

### Removed

- `FeastHook.referrerOf(address)`: read `FeastReferrals.referrerOf`.
- `FeastHook`'s `ReferrerBound(wallet, referrer, firstPool)` event: the registry
  emits `ReferrerBound(wallet, referrer)`.
- The hook's `_referrerOf` mapping; `_tipFloorOf` moves from storage slot 4 to 3.

### Known boundaries — bytecode decisions, coordinator ruling of 2026-10-04

- Only `tx.origin`'s binding is read. A smart account's lifetime binding is
  honoured only on its own direct trades, so on a bundled trade an integrator
  names the account's referrer per trade.
- A relayer that binds its own key is paid on every trade it originates, as any
  bound EOA is.

### Numbers

- `FeastHook` 24,566 → 24,541 bytes of 24,576 (margin 10 → 35). Every other
  contract is byte-identical to v1.6.25.
- +3,042 gas per fee-paying trade. Binding, once per wallet: `bind` 52,650 gas,
  `bindWithSig` 58,376 for an EOA.

### Acknowledged

- **L-5**: operational control, owner ruling of 2026-10-04 — every priced
  quote's pinned pool must show real trading activity and arbitrage depth at
  listing; the thresholds live in the genesis parameter table; no code change.

`docs/audit/v1.6.26-changes.md` has one row per item, every byte decision and the
test counts.
