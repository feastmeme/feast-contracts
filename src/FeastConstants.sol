// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Every number and name the protocol depends on, in one place.
/// @dev The product's working name may change. Nothing outside this file spells
///      it, and no module hard-codes a share that appears in the spec — so a
///      rename or a retune touches one file and the tests that assert on it.
library FeastConstants {
    // --- the take ---------------------------------------------------------

    /// @notice 1%, in hundredths of a basis point, matching the venue's fee unit.
    uint24 internal constant FEE_PIPS = 10_000;
    uint24 internal constant FEE_DENOMINATOR = 1_000_000;

    /// @notice Basis points, the unit for every share *of the fee* below.
    uint16 internal constant BPS = 10_000;

    /// @notice The largest supply a coin may be created with.
    /// @dev Round `v1.6.4` G1: `create` took `p.supply` from the caller and
    ///      capped it nowhere, so `supply * bps / BPS` was unbounded above. The
    ///      first site to give way is the hook's per-wallet cap
    ///      (`FeastHook.sol`, `supply * CAP_BPS_OF_SUPPLY / BPS`), which panics
    ///      0x11 for `supply > (2**256 - 1) / 50` — and because `registerPool`
    ///      runs BEFORE `_seed`, that panic fires ahead of every named refusal
    ///      the factory has. Measured, not assumed.
    ///
    ///      `2**128 - 1` for three reasons. The venue already bounds a coin's
    ///      supply one step later and far less legibly: a seed moves the POOL
    ///      AMOUNT through the vault in a single settlement and `_pay` takes an
    ///      `int128`, so a supply whose pool amount exceeds `MAX_SETTLEMENT`
    ///      cannot be seeded at all — this refuses by name, above, what the
    ///      venue would refuse opaquely. It bounds every `supply * bps` product
    ///      at under `2**142`, an argument a reviewer can check in one
    ///      multiplication. And it refuses nothing anyone would launch:
    ///      `PLATFORM_SUPPLY` is `1e27`, eleven orders of magnitude below it.
    ///
    ///      **The venue-implied ceiling is not `MAX_SETTLEMENT` itself** (round
    ///      `v1.6.4`, Claude lens). The pool amount is the supply LESS the
    ///      creator's allocation, which may be up to 20%, and `_seed` tolerates
    ///      a further 1% unconsumed — so a supply of about `1.26 x 2**127`, or
    ///      `0.63 x 2**128`, still seeds in one settlement. `MAX_SUPPLY` sits
    ///      above that, so the cap does not bind before the venue does; it
    ///      bounds the ARITHMETIC, which is what it is for. An earlier draft of
    ///      this comment said a supply above `MAX_SETTLEMENT` "cannot be seeded
    ///      at all", which is a fifth of a bit too strong.
    uint256 internal constant MAX_SUPPLY = type(uint128).max;

    // --- the split of the fee --------------------------------------------
    // Shares are of the fee itself, not of the trade. They are set once, in the
    // creating transaction, and no contract has a setter for any of them.

    /// @notice The platform's share. A constant, never an argument.
    uint16 internal constant PLATFORM_BPS = 2_000;
    /// @notice Everything the creator gets to divide up.
    uint16 internal constant CREATOR_SIDE_BPS = 8_000;

    /// @notice Share used to buy the coin in its own pool and burn it. The cap
    ///         is half the fee (owner, 2026-09-12, v1.6.2 H3): a creator who
    ///         wants the coin bought back harder may spend up to half of what
    ///         the fee takes on it, and the referrer cap and the band check
    ///         below are unchanged, so the creator's own remainder still cannot
    ///         underflow.
    uint16 internal constant DEFAULT_SELF_BURN_BPS = 2_000;
    uint16 internal constant MAX_SELF_BURN_BPS = 5_000;

    /// @notice Share paid to a referrer, and only on trades that name one.
    uint16 internal constant DEFAULT_REFERRER_BPS = 1_000;
    uint16 internal constant MAX_REFERRER_BPS = 3_000;

    // The creator's own remainder is CREATOR_SIDE_BPS - selfBurn - referrer.
    // It is computed, never stored, so the four shares cannot drift apart.

    // --- the epoch pot ----------------------------------------------------

    uint32 internal constant EPOCH_LENGTH = 86_400;

    // --- governance -------------------------------------------------------

    uint256 internal constant TIMELOCK_DELAY = 3 days;

    // --- the pool ---------------------------------------------------------

    /// @notice The venue's own LP fee for feast pools: the lowest conventional
    ///         tier, so that feast's 1% take is the economic fee a trader pays
    ///         and the venue's cut is negligible. The venue validates only that
    ///         it is under 100%; the tiers are a convention, not a contract.
    uint24 internal constant POOL_LP_FEE = 100;

    /// @notice Tick spacing for feast pools.
    /// @dev The seeded position is full-range, so the two ticks FEAST itself
    ///      initialises are its endpoints. That is not the same as "only two are
    ///      ever initialised", which this sentence used to say: the hook
    ///      registers no liquidity callbacks, so anyone may add a position of
    ///      their own and initialise the ticks it needs (v1.6.7, the v1.6.6
    ///      pack's hook lens, HK03). Crossing those costs what crossing any
    ///      initialised tick costs; the spacing bounds how many there can be.
    int24 internal constant POOL_TICK_SPACING = 200;

    // --- the fair open ----------------------------------------------------

    /// @notice Blocks after pool creation during which the per-wallet cap binds.
    uint64 internal constant CAP_BLOCKS = 2;
    /// @notice Per-wallet purchase cap, in basis points of the coin's supply,
    ///         denominated in coin bought rather than quote spent.
    uint16 internal constant CAP_BPS_OF_SUPPLY = 50;

    // --- the buttons ------------------------------------------------------

    /// @notice The bound the pacing must keep: at most this share of an
    ///         accrued bucket may leave in any one hour.
    /// @dev The withdrawn design kept it by quantising — at most one press per
    ///      hour, each at most 20% — so a half-open hour carried 20% and no
    ///      more. Any replacement has to keep the same bound.
    uint16 internal constant MAX_HOURLY_SPEND_BPS = 2_000;
    /// @notice The largest allowance the button may ever hold, in basis points
    ///         of the accrued bucket. This is also the largest single press.
    /// @notice How fast the allowance refills, in basis points of the accrued
    ///         bucket per hour.
    /// @dev **These two must sum to no more than `MAX_HOURLY_SPEND_BPS`, and
    ///      that is the whole of the arithmetic.** A token bucket permits a
    ///      burst of its capacity PLUS a window's refill, so the worst an hour
    ///      can carry is `cap + rate`. Round 7 (r7a H1 / r7b H1) found both set
    ///      to 2,000 on the theory that equal rate and cap reproduced the old
    ///      ceiling; they do not, and an idled pool could spend ~36% in an hour.
    ///
    ///      Splitting them keeps the bound and costs long-run throughput: 15%
    ///      per hour sustained rather than 20%. The 5% cap is also the largest
    ///      single print, which is the sandwich surface, so a smaller cap is
    ///      worth something on its own.
    uint16 internal constant ALLOWANCE_CAP_BPS = 500;
    uint16 internal constant ALLOWANCE_BPS_PER_HOUR = 1_500;
    /// @notice The window the allowance accrues over.
    uint32 internal constant ALLOWANCE_WINDOW = 1 hours;
    /// @notice Below this many raw quote units, a bucket is not rationed.
    /// @dev Round 5 (M1). A bucket of a few raw units has an allowance that
    ///      rounds to zero or to one, and a press that small is entirely eaten
    ///      by the venue's own fee rounding — so the bucket could never be
    ///      emptied. Nobody can sandwich a print that size, so rationing it
    ///      protects nothing.
    ///
    ///      This is the one constant here in RAW units rather than as a rate,
    ///      so it carries a decimals assumption: quote tokens are tokenised
    ///      equities, 18-decimal on this chain, making this 1e-14 of a token.
    ///      It stays dust down to six decimals (0.01 units). A quote token with
    ///      fewer than six decimals is outside the assumption, and
    ///      `docs/plan.md` §3 says so.
    uint256 internal constant MIN_RATIONED_BUCKET = 10_000;
    /// @notice Fixed-point scale the spending allowance is accumulated in.
    /// @dev Round 8 (L2 and part of M1). Accumulating in whole quote units
    ///      meant every checkpoint floored the accrual away, so a stream of
    ///      tiny fee credits could hold the allowance at zero indefinitely.
    ///      Carrying the fraction here means nothing is discarded and the
    ///      accrual clock can always advance to now, so no elapsed time is ever
    ///      re-priced at a later rate.
    uint256 internal constant ALLOWANCE_SCALE = 1e18;
    /// @notice The most that can leave the vault in one settlement.
    /// @dev The venue settles in a signed 128-bit delta, so no single burn or
    ///      take may exceed this. Round 10 (r10a H1): every claim paid its
    ///      WHOLE entitlement in one settlement, so a ledger that grew past this
    ///      — reachable with a high-decimal quote — reverted every claim
    ///      afterwards, for ever, with no smaller withdrawal available. A claim
    ///      pays at most this much and leaves the remainder to claim again.
    uint256 internal constant MAX_SETTLEMENT = uint256(uint128(type(int128).max));
    /// @notice Paid to whoever presses the buy-back button, out of the coin the
    ///         press bought: `coinOut × max(TIP_BPS, min(floor ÷ largest,
    ///         TIP_CEILING_BPS))`, the rates in basis points.
    /// @dev v1.6.23 (task 675). The two terms the floor adds:
    ///
    ///      - `floor` is the tip floor of the pool's quote, in raw units of that
    ///        quote, from the table the hook is built with. One unit of value
    ///        for every quote: the wrapped-native row is `TIP_FLOOR_NATIVE`
    ///        (0.0005 ether), and each listed stock's row is the amount of that
    ///        stock worth 0.0005 BNB at deploy. The owner fills the stock rows in
    ///        the genesis table (task 570's sheet) before the mainnet deploy; the
    ///        sandbox deploy uses the sandbox's own quote prices. A quote nobody
    ///        listed has no floor, and its tip is `TIP_BPS` alone, as before.
    ///      - `largest` is the largest press the bucket allows:
    ///        `ALLOWANCE_CAP_BPS` of the bucket before the press, in quote.
    ///
    ///      **Why a floor.** A press costs about 227,000 gas, roughly $0.13. At
    ///      0.25% of a 5% print the tip was 0.0125% of the bucket, so no bucket
    ///      under about $1,040 was worth pressing. With a floor worth 0.0005 BNB
    ///      (about $0.30), the largest press of a bucket is tipped `max(0.25% of
    ///      it, min(floor, 10% of it))`: a bucket of about $26 covers its gas, and
    ///      one above 8,000 floors (about $2,400) is tipped exactly as before.
    ///      `docs/button-economics.md` has the table.
    ///
    ///      **Why the largest press, and not this one.** The first spelling of
    ///      the rule converted the floor at the press's own price, which divides
    ///      it by THIS press. The presser chooses the size, and nothing bounds
    ///      how small or how often (round 6 removed the interval), so the best
    ///      press would have been `10 × floor`, where the ceiling meets the
    ///      floor: a farmer splitting at that size takes 10% of all spend on any
    ///      bucket. That is R6 again (`docs/plan.md`, "farming the tip by
    ///      splitting one conversion into many"). Divided by the largest press,
    ///      the rate is set by the bucket, not the press, so the tip still has no
    ///      flat component per press: a dust press earns dust, and splitting a
    ///      press earns at most a bounded drift. Each piece lowers the bucket,
    ///      so the later pieces are tipped a little higher: +1.3% for two
    ///      pieces, +2.3% for ten, inside the 6% the team's witness allows, and
    ///      less than the gas of the extra presses from about 0.03 gwei up
    ///      (v1.6.27, `CA-40dcf992a5`; `test/audit/poc/TipSplitIsNotNeutral.t.sol`).
    ///
    ///      **The ceiling.** `TIP_CEILING_BPS` holds every tip to a tenth of what
    ///      the press bought, so at least 90% of every print is burned.
    uint16 internal constant TIP_BPS = 25;
    /// @notice The most a press is ever tipped, in basis points of what it bought.
    uint16 internal constant TIP_CEILING_BPS = 1_000;
    /// @notice The wrapped-native row of the tip-floor table: 0.0005 BNB, in wei.
    /// @dev The unit every other row is priced in: a listed stock's floor is the
    ///      amount of that stock worth this much BNB at deploy. Read by the deploy
    ///      script, never by the hook, which sees only the table.
    uint256 internal constant TIP_FLOOR_NATIVE = 0.0005 ether;
    /// @notice Widest move in PRICE that a button's own swap may cause, measured
    ///         from the SPOT price the swap starts at.
    /// @dev Round `v1.6.4` G3 (`CA-7e39484115`) and its round-r1 verifier, in two
    ///      parts, because the first sentence was wrong twice.
    ///
    ///      **What it bounds.** This figure is spent by
    ///      `FeastMath.sqrtPriceLimit`, which now takes the square root of the
    ///      ratio before applying it. Until v1.6.4 the ratio was applied to the
    ///      SQUARE-ROOT price directly, so this constant said 3% and the button
    ///      permitted `1.03² = 6.09%`.
    ///
    ///      **What it does NOT bound, and used to claim it did.** This said
    ///      "widest move from the time-weighted price". It is not that, and the
    ///      two checks COMPOSE rather than coincide: `_requireSpotNearAverage`
    ///      admits a spot up to `MAX_TICK_DEVIATION` from the average, and the
    ///      press may then walk the price this much further from THAT spot. A
    ///      press that reaches its own limit having been admitted at the edge of
    ///      the tick check clears about `3.045% + 2.98% ≈ 6.1%` from the
    ///      time-weighted price. That is the bound an integrator should hold this
    ///      to; the round-1 verifier is the reason it is written down rather than
    ///      left to be discovered a third time.
    uint16 internal constant MAX_SLIPPAGE_BPS = 300;
    /// @notice How far spot may sit from the time-weighted price before a button
    ///         refuses to press at all. Ticks are 1.0001 apart, so 300 of them is
    ///         3.045% in price. Stated in ticks because turning a tick into a
    ///         token amount needs the venue's GPL-licensed mathematics and
    ///         comparing ticks does not.
    /// @dev Numerically equal to `MAX_SLIPPAGE_BPS` and NOT the same tolerance —
    ///      this one is an admission test against the average, that one is a
    ///      limit on the swap's own movement from spot. They used to be
    ///      documented as "the same tolerance"; see above.
    int24 internal constant MAX_TICK_DEVIATION = 300;

    // --- the oracle -------------------------------------------------------

    uint32 internal constant TWAP_WINDOW = 600;
    /// @notice Below this, the oracle refuses rather than returning a short
    ///         window that is a spot price wearing a costume.
    uint32 internal constant MIN_OBSERVATION_AGE = 300;
    /// @notice The fewest observations a priced quote's v3 pool must keep: one
    ///         for every second of `TWAP_WINDOW`, and one more (v1.6.25,
    ///         AstraSec Q-3).
    /// @dev **Chosen from the window and the pool's write rate.** A v3 pool
    ///      writes at most one observation per block timestamp — `Oracle.write`
    ///      returns early when its newest observation already carries this
    ///      second — and timestamps are whole seconds. So a full ring of `n`
    ///      slots spans at least `n - 1` seconds, however often anyone writes
    ///      and however short the chain's blocks, and at `TWAP_WINDOW + 1` its
    ///      oldest observation is always a whole window old. No trade and no
    ///      liquidity change, ordinary or placed just before `settle`, can then
    ///      leave the pool's history too short to answer, and the average is
    ///      never taken over less than the window.
    ///
    ///      `FeastPricer` accepted a ring of TWO until v1.6.25. Two writes in any
    ///      300 seconds put it under `MIN_OBSERVATION_AGE`, so one in-range mint
    ///      or burn just after a trade made the quote `Unpriceable`, and once
    ///      `PRICING_GRACE` was over its week counted zero.
    ///
    ///      The pricer refuses to list a pool whose ring has not been ASKED for
    ///      this depth, and reads a live ring shallower than it as `Unpriceable`.
    ///      Asking is permissionless — `increaseObservationCardinalityNext` on
    ///      the pool, paid by the caller, one fresh storage slot per observation
    ///      added — and the pool takes the new depth at its next write that
    ///      reaches the end of its current ring. `FeastConverter` keeps its own,
    ///      lower floor (`MIN_ORACLE_CARDINALITY`): a ring it cannot read makes
    ///      a conversion revert, which the claimant may retry, and zeroes
    ///      nothing.
    uint16 internal constant MIN_RING_CARDINALITY = uint16(TWAP_WINDOW) + 1;

    // --- misc -------------------------------------------------------------

    address internal constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;
}
