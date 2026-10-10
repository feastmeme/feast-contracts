// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FeastGenesis} from "./FeastGenesis.sol";
import {IFeastGuardian} from "./IFeastGuardian.sol";
import {PoolId} from "./venue/PoolId.sol";

/// @title The guardian: a brake that can never touch the money
/// @notice feast has no owner. This is the one exception, and it is written so
///         that the sentence stays true: the guardian can stop new coins being
///         created, and it can pause outflows for at most 72 hours at a time —
///         and it can do nothing else, ever, to anybody's balance.
///
/// @dev Design and every ruling: `plans/audit/guardian-design.md`.
///
///      **What it buys is TIME.** If a defect surfaces on day three there is
///      otherwise nothing anybody can do: every pool keeps trading and every
///      claim keeps paying while a fix is written. A freeze stops the next
///      transaction, not the last one — it is a brake, not a rescue, and not a
///      steering wheel.
///
///      **Everything that bounds it is on chain, not promised.**
///
///        - one freeze lasts at most `FREEZE_MAX` and expires BY ITSELF;
///          `unfreeze` is a courtesy, not a requirement;
///        - the total over the guardian's life is `FREEZE_BUDGET`, so a
///          guardian cannot assemble a long pause out of short ones;
///        - the freeze power is gone `GUARDIAN_SUNSET` after genesis, measured
///          from an immutable instant rather than a block or a settable field,
///          and after that anyone may `expire()` a freeze left standing — the
///          last act of the guardian's life must not need the guardian.
///
///      **`stopCreation` does not sunset** (coordinator, 2026-09-20 16:1x). It
///      is one-way, funds-safe and the mildest brake there is, and a defect that
///      surfaces in month six still deserves a way to stop NEW exposure. After
///      day 90 it is the only power left.
///
///      There is no upgrade path, no setter for `guardian`, no way to add a
///      power, and no function here that moves a token.
contract FeastGuardian is IFeastGuardian {
    /// @notice The address that may pull either brake. Immutable: changing who
    ///         can pull it is a change inside the Safe — signers, threshold, a
    ///         module — and never a change to this contract (owner, 15:0x).
    address public immutable guardian;

    /// @notice The factory, the one address that may start the clock.
    address public immutable factory;

    /// @notice When GENESIS happened — zero until the factory says so.
    ///
    /// @dev **This was the constructor's `block.timestamp` and that was wrong.**
    ///      Package 1 is deployed "with the factory"; genesis is a separate,
    ///      later act at the TGE, "when the owner decides". Counting ninety days
    ///      from the deploy shortened both windows by however long the owner
    ///      waited — measured on the unit fixture's own calendar, twelve days —
    ///      and the field was NAMED `genesisAt`, which is what kept it
    ///      invisible. Four units of the v1.6.12 round found it across both
    ///      families. It is `genesisStartedAt` now, set once by `startClock`.
    uint64 public genesisStartedAt;

    /// @notice The longest a single freeze can last. Long enough to design a fix
    ///         and tell people; short enough that nobody has to trust the
    ///         guardian to release it.
    uint64 public constant FREEZE_MAX = 72 hours;

    /// @notice The total frozen time available over this contract's whole life:
    ///         two full incidents and a spare day. Without it, "unbounded within
    ///         90 days" is a 90-day pause assembled from 72-hour pieces
    ///         (coordinator, 2026-09-20 16:1x).
    uint64 public constant FREEZE_BUDGET = 168 hours;

    /// @notice How long after genesis the freeze power lasts.
    uint64 public constant GUARDIAN_SUNSET = 90 days;

    /// @notice The least a single pull can cost the budget, however briefly it
    ///         is held.
    ///
    /// @dev Owner ruling, 2026-09-22. Before this, `unfreeze` refunded the whole
    ///      unused tail — so a freeze lifted in the SECOND it was placed
    ///      refunded its entire grant and folded zero, and a freeze/unfreeze
    ///      pair per block refused every guarded call ordered between them at no
    ///      cost at all. The 168-hour lifetime bound did not bind it, which is
    ///      the one thing that bound says (`P17-claude` MEDIUM; Codex `P17` read
    ///      the same lines and returned NOTHING-FOUND, and its reasoning — that
    ///      only the unused tail is refunded — is true and still permits this).
    ///
    ///      With a minimum charge the budget bounds the COUNT as well as the
    ///      duration: at most `FREEZE_BUDGET / MIN_FREEZE_CHARGE` = 168 pulls
    ///      over this contract's life.
    ///
    ///      The minimum binds the BUDGET, never the clocks. `_fold` still counts
    ///      the seconds actually frozen, so a one-second freeze delays no
    ///      deadline by an hour — it costs an hour of the guardian's own budget
    ///      and moves every other clock by one second. Those are different
    ///      quantities and they are kept apart deliberately.
    ///
    ///      The brake is an emergency instrument, and this makes that explicit:
    ///      every pull costs an hour of budget. No automated caller exists to be
    ///      surprised — there is no `freeze` call anywhere in `src/`, `script/`
    ///      or this repository's documents outside the tests, which was checked
    ///      before the constant landed.
    uint64 public constant MIN_FREEZE_CHARGE = 1 hours;

    /// @notice Pulled once, never unpulled.
    bool public creationStopped;
    /// @notice Frozen seconds already committed, over this contract's life.
    uint64 public spent;
    /// @notice ALL-SCOPE frozen seconds already FOLDED IN — completed freezes
    ///         only. The live or lapsed one is added by `frozenSeconds()`.
    /// @dev    Owner ruling 2, 2026-09-22: **a scoped freeze does not feed this.**
    ///         It used to. Every clock in the system subtracted this one number,
    ///         and `take` and `settle` are refused only under an ALL freeze — so
    ///         a freeze on one coin's pool held the price of every lot in the
    ///         sink and stopped clocks in pools that were trading normally,
    ///         which is the guardian moving a price (`P16b` HIGH against P27,
    ///         and four more across both families). The counter now matches the
    ///         gate that guards its consumers exactly.
    uint64 public frozenTotal;

    // --- one slot, read by everything on the swap path -----------------------
    //
    // `frozenUntil` + `frozenFrom` + `allUnfrozenTotal` is 192 bits and shares a
    // single slot, deliberately (v1.6.16, coordinator ruling 3).
    // `FeastHook._beforeSwap` asks `isFrozenAll` on every trade, which reads
    // `frozenUntil`; the open-time gate on the oracle average then asks
    // `allUnfrozenAt`, which reads all three. Packing them makes the second
    // question a WARM read of a slot the first already paid for, instead of a
    // second cold SLOAD on every swap that reaches the internal fill.
    //
    // Nothing about the guardian's promise moves with them: a layout choice.

    /// @notice The instant the live freeze lifts by itself. Zero when none.
    uint64 public frozenUntil;
    /// @notice When the live-or-lapsed freeze began. Zero once folded.
    uint64 public frozenFrom;
    /// @notice When the most recent FOLDED freeze ended. The live or lapsed one
    ///         is accounted for by `allUnfrozenAt()`; read that, not this. Zero
    ///         when no freeze has ever ended.
    uint64 public allUnfrozenTotal;
    /// @notice The block an `unfreeze` last cleared a freeze in. A new freeze is
    ///         refused in that block.
    /// @dev    Fills the hot slot exactly: four `uint64` is 256 bits, so this
    ///         costs no extra SLOAD on the swap path.
    uint64 public lastUnfrozenBlock;

    /// @notice One freeze that has ended: when it began, when it ended, and the
    ///         frozen seconds folded before it.
    struct Freeze {
        uint64 from;
        uint64 until;
        uint64 frozenBefore;
    }

    /// @dev Every freeze that has ended, in time order, so `frozenSecondsAt`
    ///      can answer for any past instant (v1.6.27, `CA-6b91a230c6`).
    ///      Appended by `_fold` — the one place every freeze ends — and edited
    ///      by nothing. Bounded by the budget's own count: every pull costs at
    ///      least `MIN_FREEZE_CHARGE`, so there are at most 168 rows, one slot
    ///      each. Declared after every other variable, so no slot moves.
    Freeze[] private _ended;

    // **There is no pool-scoped freeze, and no `frozenPool`** (v1.6.17, owner
    // ruling). The brake had two scopes: everything, or one pool. The pool one
    // is gone, and with it `_poolFrozenTotal`, `_poolUnfrozenAt`,
    // `frozenSecondsFor(poolId)`, `unfrozenAtFor(poolId)`, the `all` and
    // `poolId` arguments of `freeze`, the pool field of `Frozen`, and the
    // overlap rules — there is nothing left to overlap.
    //
    // The reason is a table, and it is in `docs/audit-briefs/v1617-one-scope.md`
    // in full: the opening purchase cap was redesigned FIVE times against one
    // shape, and **every** defeat needed a pool-scoped freeze the guardian could
    // interleave with its own trades. A freeze that covers everything refuses
    // the guardian's trades too, so it cannot be used to clear a room. The class
    // ends when the instrument does, which is cheaper and more honest than a
    // sixth correction.
    //
    // What it costs: a defect in one coin's pool can now only be answered by
    // pausing outflows everywhere. That is a real loss of precision and it is
    // the price of the brake being unable to single anybody out.

    error NotTheGuardian(address caller);
    error AlreadyFrozen(uint64 until);
    error UnfrozenThisBlock(uint64 blockNumber);
    error LapsedFreezeNotSettled(uint64 lapsedAt);
    error NotFrozen();
    error FreezePowerExpired(uint64 sunsetAt);
    error FreezeBudgetSpent(uint64 budget, uint64 spent);
    error NotYetExpired(uint64 sunsetAt);
    error CreationAlreadyStopped();
    error NotTheFactory(address caller);
    error ClockAlreadyStarted(uint64 at);

    event Frozen(uint64 until, uint64 spent);
    event Unfrozen(uint64 at, uint64 refunded, uint64 spent);
    event Expired(uint64 at);
    event CreationStopped(uint64 at);
    event ClockStarted(uint64 at);

    constructor(address guardian_, address factory_) {
        guardian = guardian_;
        factory = factory_;
    }

    /// @notice Start the ninety-day clock. The factory, from genesis, once.
    /// @dev Before this the clock has NOT started: the brake is fully live and
    ///      nothing that depends on the deadline may happen yet. That is the
    ///      safe direction — a guardian whose genesis never comes keeps its
    ///      brake, and a partner slot whose window never opened cannot be
    ///      burned out from under anybody.
    function startClock() external {
        if (msg.sender != factory) revert NotTheFactory(msg.sender);
        if (genesisStartedAt != 0) revert ClockAlreadyStarted(genesisStartedAt);
        genesisStartedAt = uint64(block.timestamp);
        emit ClockStarted(genesisStartedAt);
    }

    /// @notice Has genesis happened?
    function clockStarted() external view returns (bool) {
        return genesisStartedAt != 0;
    }

    modifier onlyGuardian() {
        if (msg.sender != guardian) revert NotTheGuardian(msg.sender);
        _;
    }

    // --- the brake ------------------------------------------------------------

    /// @notice Pause outflows. Everything, because there is no other scope.
    /// @dev The whole grant is charged to the budget HERE, not when it lifts, so
    ///      the ceiling is exact at every instant and a guardian that simply
    ///      walks away cannot have spent less than it took. An early `unfreeze`
    ///      refunds the unused tail above `MIN_FREEZE_CHARGE`.
    ///
    ///      Took `(bool all, PoolId poolId)` until v1.6.17. See the note above
    ///      the storage for why the second scope is gone.
    function freeze() external onlyGuardian {
        uint64 started = genesisStartedAt;
        if (started != 0 && block.timestamp >= started + GUARDIAN_SUNSET) {
            revert FreezePowerExpired(started + GUARDIAN_SUNSET);
        }
        if (block.timestamp < frozenUntil) revert AlreadyFrozen(frozenUntil);
        // **No freeze in the block an unfreeze cleared** (v1.6.18, coordinator
        // ruling). Removing the pool-scoped freeze at v1.6.17 stopped the
        // guardian standing OUTSIDE a freeze; it did not stop it standing
        // BETWEEN two. One transaction of `unfreeze, trade, freeze` served an
        // opening block no stranger could reach, and the sixth redesign of the
        // opening cap fell to the same shape as the five before it
        // (`P6-claude` MEDIUM, `P16-claude` MEDIUM, red PoC in
        // `test/audit/poc/V1617RoundFindings.t.sol`).
        //
        // This is a guard on the instrument, not a seventh redesign of the cap.
        // With it, bracketing a served block needs the guardian's trade and its
        // re-freeze in DIFFERENT blocks — which leaves the block open to every
        // stranger whose transaction lands after the guardian's.
        //
        // **The bound that remains, stated:** defeating it needs block-builder
        // collusion, so that no stranger's transaction is ordered after the
        // guardian's in the blocks it serves. And it costs twice as much —
        // two `MIN_FREEZE_CHARGE` pulls per bracketed block instead of one, so
        // `CAP_BLOCKS = 2` costs four hours of a 168-hour lifetime budget, every
        // pull of it on chain.
        if (uint64(block.number) == lastUnfrozenBlock) revert UnfrozenThisBlock(lastUnfrozenBlock);
        // And a freeze that LAPSED must be settled first, in its own
        // transaction, so that its ending stamps a block like every other
        // ending does. Without this the guardian brackets the lapse's own block
        // — see `settleLapsed`.
        if (frozenFrom != 0 && block.timestamp >= frozenUntil) revert LapsedFreezeNotSettled(frozenUntil);

        uint64 left = FREEZE_BUDGET - spent;
        if (left == 0) revert FreezeBudgetSpent(FREEZE_BUDGET, spent);
        uint64 granted = left < FREEZE_MAX ? left : FREEZE_MAX;

        _fold();
        spent += granted;
        frozenFrom = uint64(block.timestamp);
        frozenUntil = uint64(block.timestamp) + granted;
        emit Frozen(frozenUntil, spent);
    }

    /// @notice Lift the live freeze early and give the unused time back to the
    ///         budget. The guardian's, because it is the guardian's to give up.
    function unfreeze() external onlyGuardian {
        uint64 until = frozenUntil;
        if (block.timestamp >= until) revert NotFrozen();
        // The tail ABOVE the minimum charge, and no more (owner ruling 5). The
        // grant was charged in full when the freeze was placed; what comes back
        // is what was neither used nor owed. `granted` is recovered from the two
        // stamps rather than stored, and the clamp is what keeps a pull whose
        // grant was already smaller than the minimum — the last sliver of the
        // budget — from refunding a negative number.
        uint64 granted = until - frozenFrom;
        uint64 held = uint64(block.timestamp) - frozenFrom;
        uint64 charged = held > MIN_FREEZE_CHARGE ? held : MIN_FREEZE_CHARGE;
        uint64 refunded = granted > charged ? granted - charged : 0;
        spent -= refunded;
        _fold();
        _clear();
        emit Unfrozen(uint64(block.timestamp), refunded, spent);
    }

    /// @notice Settle a freeze that ran out by itself. Anyone, at any time.
    ///
    /// @dev **A lapse is the one ending with no transaction in it**, and that is
    ///      what made it the seventh way through the opening cap. `unfreeze` and
    ///      `expire` both run code at the moment they end a freeze, so both can
    ///      stamp the block; a freeze that simply runs out stamps nothing, and
    ///      the guardian could `trade, freeze` in one transaction in the block
    ///      the lapse opened — serving a block nobody else could reach.
    ///
    ///      So a lapse gets a transaction of its own, and `freeze` refuses until
    ///      it has happened. The guardian must therefore settle in one block and
    ///      freeze in a later one, which leaves the settling block open to
    ///      everyone.
    ///
    ///      **Permissionless on purpose.** If only the guardian could settle,
    ///      the guardian could simply not do it, and `freeze` would be the thing
    ///      it was blocked on — a lockout of its own brake. Anyone may clear the
    ///      way, and the guardian cannot stall it.
    ///
    ///      **The bound that remains, stated:** the settling block and the
    ///      blocks after it are open to every stranger, so bracketing one needs
    ///      the guardian's transaction ordered ahead of every other in that
    ///      block. That is BLOCK-BUILDER COLLUSION, and it is the same residue
    ///      the same-block bracket leaves. Nothing in this contract can reach
    ///      it; it is named rather than claimed away.
    function settleLapsed() external {
        if (frozenFrom == 0) revert NotFrozen();
        if (block.timestamp < frozenUntil) revert AlreadyFrozen(frozenUntil);
        _fold();
        _clear();
        emit Expired(uint64(block.timestamp));
    }

    /// @notice After the sunset, clear a freeze left standing. Anyone.
    /// @dev A freeze placed on the last day can outlive the power that placed
    ///      it by up to `FREEZE_MAX`. This is how it ends without the guardian.
    function expire() external {
        uint64 started = genesisStartedAt;
        if (started == 0 || block.timestamp < started + GUARDIAN_SUNSET) {
            revert NotYetExpired(started == 0 ? type(uint64).max : started + GUARDIAN_SUNSET);
        }
        _fold();
        _clear();
        emit Expired(uint64(block.timestamp));
    }

    /// @dev Add the live-or-lapsed freeze to the running total and forget it.
    ///      A freeze that LAPSED without anybody calling `unfreeze` still counts
    ///      in full, which is why this reads `frozenUntil` rather than `now`.
    function _fold() private {
        uint64 from = frozenFrom;
        if (from == 0) return;
        uint64 until = frozenUntil;
        uint64 end = uint64(block.timestamp) < until ? uint64(block.timestamp) : until;
        _ended.push(Freeze({from: from, until: end, frozenBefore: frozenTotal}));
        // One scope, one counter (v1.6.17). Owner ruling 2 of 2026-09-22 split
        // this by scope; the ruling that removed the second scope removed the
        // split with it.
        frozenTotal += end - from;
        allUnfrozenTotal = end;
        frozenFrom = 0;
    }

    /// @notice The instant trading last became possible again after an ALL-scope
    ///         freeze — or, while one is live, the moving instant it would.
    ///
    /// @dev The stamp a mechanism reads when it asks "how long has the market
    ///      been open SINCE it last reopened?" — the platform price's open-time
    ///      aging in `FeastEmissions.settle` and the hook's oracle gate. They do
    ///      not want a DURATION — `frozenSeconds()` is that — they want the
    ///      instant the world restarted.
    ///
    ///      **Not a deadline's clock.** Settlement's pricing grace read this
    ///      stamp from v1.6.15 and restarted from it, and the stamp moves on a
    ///      freeze of no seconds at all: a freeze taken and lifted in one second
    ///      handed an expired grace three fresh days (`pricing-grace-restart`,
    ///      Codex appendix on v1.6.21-audit). Since v1.6.22 the grace counts
    ///      `frozenSeconds()` instead, and moves only by frozen time.
    ///
    ///      Only ALL-scope freezes count. A pool-scoped freeze does not stop
    ///      `settle`, so it defers nothing here.
    ///
    ///      Shaped exactly like `frozenSeconds()`: a folded total plus the live
    ///      or lapsed tail, so a freeze that LAPSED with nobody calling
    ///      `unfreeze` reads correctly without anyone having to call anything.
    ///      While a freeze is live this returns `block.timestamp` and therefore
    ///      recedes, which is the property the callers need — a window cannot be
    ///      consumed while nobody may act — and it folds to the real end the
    ///      moment the freeze lifts.
    function allUnfrozenAt() public view returns (uint64) {
        if (frozenFrom == 0) return allUnfrozenTotal;
        uint64 until = frozenUntil;
        return uint64(block.timestamp) < until ? uint64(block.timestamp) : until;
    }

    // There is no `frozenBlocks()`. v1.6.14 added one — the block-domain twin
    // of `frozenSeconds()`, so that the hook's opening cap could measure OPEN
    // blocks — and the v1.6.14 round showed it cannot be written. A live
    // freeze's end is known in SECONDS; how many blocks that is depends on how
    // fast the chain runs, which a contract cannot observe. The estimate
    // (`granted / 3`) was short by a factor of four on BSC — 86,400 blocks
    // credited for 345,598 actually frozen — and with `CAP_BLOCKS` at 2 that
    // meant any freeze at all spent the whole window the counter existed to
    // protect (`P16-claude` HIGH, `P6-claude` HIGH; the mirror direction, a
    // lapsed freeze crediting blocks after trading reopened, in three more).
    //
    // The coordinator's ruling of 2026-09-22 withdraws the block half of the
    // v1.6.14 principle: **a clock a freeze can reach measures open time only,
    // and that holds for seconds — which are observable on chain — and does not
    // extend to blocks.** A block window must instead be anchored on an event a
    // freeze cannot spend. `FeastHook` now arms its opening cap at a pool's
    // first served swap, so there is no clock between arming and check.

    /// @notice How many seconds this guardian has held the brake down, over its
    ///         whole life, including the freeze that is live right now.
    ///
    /// @dev **Every deadline in the system that a freeze can eat is measured
    ///      against this.** A price that falls with the clock, or a claim window
    ///      that closes on one, must not run while the brake is down: the sink's
    ///      descent ran through a freeze and let the guardian buy the protocol's
    ///      assets at a price its own brake set — three units of the v1.6.12
    ///      round found that, one in each family and one twice.
    ///
    ///      **Why this and not `frozenSecondsSince(t)`.** The coordinator's
    ///      ruling named a function taking an instant. Exactly answering "how
    ///      much frozen time fell inside [t, now]" for an ARBITRARY `t` needs
    ///      the whole freeze history, and the number of freezes is bounded only
    ///      by the budget's duration, not its count — a guardian spending its
    ///      168 hours in one-second pulls would put unbounded gas on the sink's
    ///      price path, which is read on every take. A consumer records this
    ///      cumulative number when its own clock starts and subtracts; that is
    ///      exact, O(1), and costs one field per record. The divergence is
    ///      deliberate and is recorded in the guardian design.
    ///
    ///      A consumer whose clock starts at an instant NO transaction marks
    ///      has nothing to record, and for that one case v1.6.27 adds
    ///      `frozenSecondsAt` below. `MIN_FREEZE_CHARGE` has since
    ///      bounded the count at 168, so the history it reads is bounded too.
    ///      The sink keeps its O(1) subtraction.
    function frozenSeconds() public view returns (uint64) {
        uint64 from = frozenFrom;
        if (from == 0) return frozenTotal;
        uint64 until = frozenUntil;
        uint64 end = uint64(block.timestamp) < until ? uint64(block.timestamp) : until;
        return frozenTotal + (end - from);
    }

    /// @notice `frozenSeconds()` as it read at instant `t`: the frozen seconds
    ///         accrued by then. An instant not yet reached reads as now.
    ///
    /// @dev v1.6.27 (`CA-6b91a230c6`). Emissions needs the frozen seconds AT a
    ///      week's close, and a close is not a transaction, so nothing could
    ///      record them. The latest fold alone could not say: once a freeze
    ///      that ran after the close had been folded, a history whose frozen
    ///      seconds all came before the close read the same as one where some
    ///      came after. Every rule built on that state either counted frozen
    ///      seconds that had blocked nothing, or let a later freeze reopen a
    ///      grace that was over.
    ///
    ///      Exact for any `t`: the freeze live or lapsed at `t` counts up to
    ///      `t`, and so does an ended one `t` falls inside. A binary search over
    ///      the ended freezes by start, at most 168 of them, so at most eight
    ///      probes; a `t` inside the live or lapsed freeze, or later, reads no
    ///      history at all. It reads no clock of its own: an instant past the
    ///      last freeze reads the folded total, and one inside the live freeze
    ///      is capped by `frozenSeconds()`, so `freeze-clocks` counts nothing new.
    function frozenSecondsAt(uint64 t) external view returns (uint64) {
        uint64 from = frozenFrom;
        if (from != 0 && t >= from) {
            uint64 until = frozenUntil;
            uint64 atT = frozenTotal + ((t < until ? t : until) - from);
            uint64 sinceNow = frozenSeconds();
            return atT < sinceNow ? atT : sinceNow;
        }
        // The last ended freeze that began at or before `t`, if any.
        uint256 lo = 0;
        uint256 hi = _ended.length;
        while (lo < hi) {
            uint256 mid = (lo + hi) / 2;
            if (_ended[mid].from > t) hi = mid;
            else lo = mid + 1;
        }
        if (lo == 0) return 0;
        Freeze memory f = _ended[lo - 1];
        return f.frozenBefore + ((t < f.until ? t : f.until) - f.from);
    }

    /// @dev Every way a freeze can END passes through here, and each of them
    ///      stamps the block: `unfreeze`, `expire`, and `settleLapsed` for a
    ///      freeze that ran out by itself. v1.6.18 stamped in `unfreeze` alone,
    ///      which left `expire()` and a lapse unstamped — the seventh iteration
    ///      of the opening-cap attack (`P6-claude`, `P16-claude`).
    function _clear() private {
        frozenUntil = 0;
        lastUnfrozenBlock = uint64(block.number);
    }

    // --- the sunset switch ----------------------------------------------------

    /// @notice Stop this deployment ever creating another coin. Once, for ever.
    /// @dev Deliberately NOT sunset: after day 90 it is the guardian's only
    ///      power, and it cannot move a balance or touch a pool that exists.
    function stopCreation() external onlyGuardian {
        if (creationStopped) revert CreationAlreadyStopped();
        creationStopped = true;
        emit CreationStopped(uint64(block.timestamp));
    }

    // --- what the guarded contracts ask ---------------------------------------

    /// @notice Is the brake down? There is one answer for the whole system:
    ///         `isFrozen(poolId)` is gone with the scope it asked about.
    function isFrozenAll() external view returns (bool) {
        return block.timestamp < frozenUntil;
    }

    /// @notice When the freeze power ends. A fact from construction, so the app
    ///         can count down to it.
    /// @dev `type(uint64).max` until genesis: the clock has not started, so
    ///      there is no deadline yet and everything that reads one must wait.
    function sunsetAt() external view returns (uint64) {
        uint64 started = genesisStartedAt;
        // Extended by the brake's own downtime, for the same reason every other
        // deadline here is: the partner-assignment window is 90 days of time in
        // which a slot can be FILLED, and a freeze is time in which it cannot.
        // Note what this does NOT do — the freeze POWER still ends at
        // `started + GUARDIAN_SUNSET` measured in wall time (see `freeze`), so
        // the guardian cannot lengthen its own life by using it. Only the
        // windows that others act inside are extended.
        return started == 0 ? type(uint64).max : started + GUARDIAN_SUNSET + frozenSeconds();
    }

    /// @notice Frozen seconds still available over this contract's life.
    function budgetLeft() external view returns (uint64) {
        return FREEZE_BUDGET - spent;
    }
}
