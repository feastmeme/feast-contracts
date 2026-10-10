// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {TickMath} from "uniswap-v4-core/src/libraries/TickMath.sol";

import {FeastCLHookBase} from "./FeastCLHookBase.sol";
import {FeastConstants} from "./FeastConstants.sol";
import {FeastMath} from "./FeastMath.sol";
import {FeastConverter} from "./FeastConverter.sol";
import {IFeastGuardian} from "./IFeastGuardian.sol";
import {FeastFeeLedger} from "./FeastFeeLedger.sol";
import {FeastGenesis} from "./FeastGenesis.sol";
import {FeastOracle} from "./FeastOracle.sol";
import {FeastReferrals} from "./FeastReferrals.sol";
import {IFeastGenesisRecipient} from "./IFeastGenesisRecipient.sol";
import {BalanceDelta} from "./venue/BalanceDelta.sol";
import {BeforeSwapDelta, ZERO_BEFORE_SWAP_DELTA, toBeforeSwapDelta} from "./venue/BeforeSwapDelta.sol";
import {Currency} from "./venue/Currency.sol";
import {IFeastCLPoolManager} from "./venue/IFeastCLPoolManager.sol";
import {IFeastVault} from "./venue/IFeastVault.sol";
import {PoolId, PoolIdLibrary} from "./venue/PoolId.sol";
import {PoolKey} from "./venue/PoolKey.sol";

/// @dev The coin burns for real rather than being sent to a dead address, so
///      that every explorer reports the supply honestly.
interface IFeastBurnable {
    function burn(uint256 amount) external;
}

/// @dev The one thing the hook asks the factory after deployment: where the
///      platform's share goes. Unset until the genesis call names it.
interface IFeastPlatformSinkSource {
    function platformSink() external view returns (address);
    function platformCoin() external view returns (address);
}

/// @title The hook
/// @notice Takes 1% of every swap, on the quote leg only, and accrues it as a
///         claim rather than as a token.
///
/// @dev The fee mechanism is ported from a twice-audited reference, including
///      its two rate corrections. What is *not* ported is where the value goes:
///      the reference settles the fee with a real token transfer inside
///      `beforeSwap`. Feast is paired against quote tokens that can pause,
///      blacklist and sanction, so a transfer on the swap path would let a third
///      party brick every swap in the pool. Feast mints an ERC-6909 claim
///      instead and moves value in separate, permissionless calls that are not
///      on the swap path. That is the required deviation, and it is the reason
///      the worst case here is value stuck rather than a pool that cannot trade.
contract FeastHook is FeastCLHookBase {
    using PoolIdLibrary for PoolKey;

    /// @notice The price history the buy-back button prices against.
    /// @dev The venue keeps no observations of its own, so feast keeps them.
    FeastOracle public immutable oracle;

    /// @notice The weekly fee ledger: who paid, whose coin earned, who
    ///         referred. Set once, never changed.
    FeastFeeLedger public immutable ledger;

    /// @notice The route to the chain's own asset, for claimants who want it.
    FeastConverter public immutable converter;

    /// @notice Who brought each wallet, for life. Written only by the wallet
    ///         itself — its own call or its own signature — and read here on
    ///         every trade (v1.6.26, AstraSec M-4).
    FeastReferrals public immutable referrals;

    /// @notice One row of the tip-floor table the hook is built with: a quote,
    ///         and the button's tip floor in raw units of that quote.
    struct TipFloor {
        address quote;
        uint256 floor;
    }

    constructor(
        address poolManager_,
        address vault_,
        address factory_,
        address oracle_,
        address ledger_,
        address converter_,
        address guardian_,
        address referrals_,
        TipFloor[] memory tipFloors
    ) FeastCLHookBase(poolManager_, vault_, factory_) {
        oracle = FeastOracle(oracle_);
        ledger = FeastFeeLedger(ledger_);
        converter = FeastConverter(converter_);
        guardian = IFeastGuardian(guardian_);
        referrals = FeastReferrals(referrals_);
        // Three deployment mistakes, refused by name rather than deployed:
        // - a zero floor lists a quote that is not floored;
        // - a quote listed twice would keep only its last row;
        // - a floor above 128 bits could overflow `coinOut * floor` at the tip
        //   site, and so refuse every press of that quote.
        for (uint256 i = 0; i < tipFloors.length; i++) {
            TipFloor memory row = tipFloors[i];
            if (row.floor == 0 || row.floor > type(uint128).max) revert TipFloorOutOfBounds(row.quote, row.floor);
            if (_tipFloorOf[row.quote] != 0) revert TipFloorListedTwice(row.quote);
            _tipFloorOf[row.quote] = row.floor;
            emit TipFloorListed(row.quote, row.floor);
        }
    }

    /// @notice The brake. It can stop this contract's outflows for at most 72
    ///         hours at a time and it can do nothing else here — no function it
    ///         reaches moves a balance on its behalf. See `FeastGuardian`.
    IFeastGuardian public immutable guardian;

    error Frozen();

    /// @dev One body, nine call sites. A guarded path asks the guardian and
    ///      refuses by name; everything else — the venue's callbacks below
    ///      `beforeSwap`, the factory's seeding, the accounting — is untouched,
    ///      because a freeze is about value LEAVING.
    ///      Took a `poolId` until v1.6.17, which removed the pool-scoped
    ///      freeze: there is one answer for the whole system now, so the
    ///      argument is gone rather than ignored. Left in place and unused it
    ///      cost 1,056 bytes of hook — the optimiser inlined the body at all
    ///      nine call sites once it no longer depended on anything.
    function _requireUnfrozen() internal view {
        if (guardian.isFrozenAll()) revert Frozen();
    }

    /// @notice OpenZeppelin's name for the refusal, so a reader recognises it.
    error ReentrancyGuardReentrantCall();

    /// @dev The transient slot `nonReentrant` keeps its flag in: 0, named
    ///      (v1.6.28, AstraSec's suggestion of 7 Oct). Assembly reads a
    ///      constant as its literal, so the name moved no byte.
    uint256 private constant REENTRANCY_GUARD_SLOT = 0;

    /// @dev **The re-entrancy guard (v1.6.24, AstraSec I-7)**, on the entry
    ///      points that move value out or across. Since v1.6.28 (AstraSec's
    ///      suggestion of 7 Oct) that is seven: the three that pay —
    ///      `claimCreator`, `claimReferrer`, `releasePlatformFees` — and
    ///      `claimAsBnb`, `buyBackAndBurn`, `burnFilledCoin`, `collectLpFees`.
    ///      v1.6.24 put it on `claim` instead of the first three. `claim` pays
    ///      nothing itself: it calls `claimCreator` and `claimReferrer` in turn,
    ///      and each of them takes the flag and gives it back. `claimAsBnb` pays
    ///      through `_claimTo`, never through those two, so it does not nest
    ///      with them. One flag for all seven, so none can be entered from
    ///      inside another. Each of them was already checks-effects-interactions
    ///      — every entitlement and bucket is debited before the call that pays
    ///      it, and every payout is made inside the vault's lock — so this is
    ///      depth, not a fix to a reachable theft;
    ///      `test/audit/poc/ConverterReentrancy.t.sol` is the record of what a
    ///      re-entry could and could not do without it.
    ///
    ///      **Never on `lockAcquired` or the venue's callbacks.** The venue calls
    ///      `lockAcquired` from inside the guarded functions' own `vault.lock`,
    ///      and `beforeSwap`/`afterSwap` from inside any swap, so a guard there
    ///      would refuse every press and every trade. Those are authenticated by
    ///      caller (`onlyVault`, `onlyPoolManager`) instead.
    ///
    ///      **Transient, at slot 0, and not OpenZeppelin's contract.** The hook
    ///      had 139 bytes of EIP-170 margin. `ReentrancyGuard` on v1.6.24's five
    ///      measured +322 and `ReentrancyGuardTransient` +317: both repeat a
    ///      32-byte slot constant at every site. Slot 0 of the hook's OWN
    ///      transient storage is free — its other three transient slots are
    ///      keccak-derived — and costs one byte at each site; the revert is
    ///      written in assembly because the Solidity spelling measured 27 bytes
    ///      more. This guard cost 97 on five sites; v1.6.28's move to seven cost
    ///      17 more. The OpenZeppelin base the hook inherited and never used is
    ///      gone with it; its namespaced slot moves nothing. Transient storage
    ///      clears with the transaction and a revert undoes the set, so the flag
    ///      can never be left standing.
    modifier nonReentrant() {
        _enter();
        _;
        assembly ("memory-safe") {
            tstore(REENTRANCY_GUARD_SLOT, 0)
        }
    }

    function _enter() private {
        assembly ("memory-safe") {
            if tload(REENTRANCY_GUARD_SLOT) {
                mstore(0, 0x3ee5aeb5) // ReentrancyGuardReentrantCall()
                revert(0x1c, 4)
            }
            tstore(REENTRANCY_GUARD_SLOT, 1)
        }
    }

    error PoolNotRegistered();
    error PoolAlreadyRegistered();
    error CoinNotInPool();
    error ShareOutOfBand();
    error AlreadySeeded();
    error SeedWouldNeedQuote();
    error PurchaseCapExceeded();
    error NothingToBuyBackWith();
    error SpotTooFarFromAverage(int24 spotTick, int24 averageTick);
    error RouteIsTheClaimantsToChoose(address account);
    error NothingSeeded();
    error PartialFillNotSupported(int256 requested, int256 realised);
    error BoughtNothing();
    error PoolNotOpenYet(uint64 openAt);
    error GateOutOfBounds(uint64 openAt, address opener);
    error PlatformSinkNotBound(address sink);
    error TipFloorOutOfBounds(address quote, uint256 floor);
    error TipFloorListedTwice(address quote);

    event PoolRegistered(
        PoolId indexed poolId, address indexed coin, address indexed creator, uint16 selfBurnBps, uint16 referrerBps
    );
    event FeeAccrued(PoolId indexed poolId, uint256 amount);
    event ReferralCredited(PoolId indexed poolId, address indexed referrer, uint256 amount);
    event LiquiditySeeded(PoolId indexed poolId, int24 tickLower, int24 tickUpper, uint128 liquidity);
    event CreatorPaid(PoolId indexed poolId, address indexed creator, uint256 amount);
    event ReferrerPaid(PoolId indexed poolId, address indexed referrer, uint256 amount);
    event BoughtBackAndBurned(PoolId indexed poolId, uint256 quoteSpent, uint256 coinBurned, uint256 tip);
    /// @notice One row of the tip-floor table, emitted once, by the constructor.
    ///         The table has no getter; this and the deploy record are how it
    ///         is read.
    event TipFloorListed(address indexed quote, uint256 floor);
    event LpFeesCollected(PoolId indexed poolId, uint256 quoteCollected);
    event PlatformFeesReleased(PoolId indexed poolId, address indexed sink, uint256 amount);
    /// @notice A seller's coin taken into the burn at the pool's price, paid from
    ///         the pool's buy-and-burn quote before the sale reached the pool.
    event InternalFill(PoolId indexed poolId, uint256 coinBurned, uint256 quotePaid);
    /// @notice Coin owed to the burn — the fill's, and since v1.6.24 the
    ///         position's coin-side fees — burned for real by `burnFilledCoin`.
    event FilledCoinBurned(PoolId indexed poolId, uint256 amount);
    /// @notice One per swap, with everything a chart or an indexer needs. The
    ///         amounts are the trader's own — what they paid or received — and
    ///         the fee is reported on its own.
    event Trade(
        address indexed coin,
        address indexed quote,
        bool buy,
        uint256 coinAmount,
        uint256 quoteAmount,
        uint160 sqrtPriceX96After,
        address indexed payer,
        uint256 fee
    );

    struct Pool {
        /// @dev Which slot the coin took is an accident of its deployed address.
        ///      Storing the flag costs one bit and is what the audited reference
        ///      does; mining a salt so the coin always sorts one way would delete
        ///      a branch class but cost a search in the creating transaction.
        bool coinIsCurrency0;
        bool live;
        bool seeded;
        /// @notice Set once, in the creating transaction. There is no setter for
        ///         any of these, anywhere, and `test_noShareSetterExists` checks
        ///         that against the deployed bytecode rather than taking it on
        ///         trust.
        uint16 selfBurnBps;
        uint16 referrerBps;
        address coin;
        address creator;
        /// @notice Before this instant only `opener` may trade the pool. Zero
        ///         for every ordinary coin; set only for the platform coin's
        ///         pool, whose launch window is the one trade allowed before it.
        uint64 openAt;
        address opener;
        /// @notice Everything the 1% has ever produced for this pool, in quote.
        ///         Reporting only: no bucket is derived from it.
        uint256 accruedQuote;
        /// @notice Monotone running totals, one per bucket, incremented at the
        ///         moment a fee is taken.
        /// @dev Round 1 found the previous shape unsound: the buckets were
        ///      *derived* from `accruedQuote` by subtracting independently
        ///      floored shares, so the creator's remainder could DECREASE as
        ///      accrual grew — and after a claim it could fall below what had
        ///      already been paid, reverting every future claim permanently.
        ///      A running total cannot decrease, so `earned - paid` cannot go
        ///      negative and conservation holds per accrual rather than only at
        ///      a snapshot.
        uint256 selfBurnEarned;
        uint256 platformEarned;
        uint256 creatorEarned;
        uint256 referrerEarned;
        // What has left each bucket. A bucket's pending balance is its earned
        // total minus this, and because earned only ever grows, that difference
        // can never underflow.
        uint256 selfBurnUsed;
        uint256 platformUsed;
        uint256 creatorPaid;
        /// @notice The button's spending allowance, and when it was last
        ///         touched. Round 6 withdrew interval-plus-floor pacing: a
        ///         binary "this press occupies the hour" needs a progress
        ///         predicate, and a progress predicate measured on the request
        ///         is gameable with dust while one measured on the realised
        ///         spend strands a bucket no thin pool can fill. A continuous
        ///         allowance needs no progress predicate at all.
        uint256 allowanceRemaining;
        uint64 allowanceUpdatedAt;
        int24 tickLower;
        int24 tickUpper;
        /// @notice Most coin one wallet may buy while the opening window is
        ///         open. Derived from supply at registration; no setter.
        uint256 perWalletCap;
        /// @notice How many DISTINCT blocks this pool has served a trade in.
        ///         The opening cap binds while this is at most `CAP_BLOCKS`.
        /// @dev **A count, not a height** (v1.6.16). The promise is about a
        ///      pool's first blocks of TRADING, and a height was the obvious way
        ///      to express that — but a height passes whether or not anybody may
        ///      trade, so a freeze spent it. v1.6.14 tried to correct the height
        ///      with a frozen-BLOCK counter and could not: a contract cannot
        ///      observe its chain's block rate. v1.6.15 anchored the height at
        ///      the pool's first served swap, which removed the clock between
        ///      arming and check but left the window itself in wall blocks — and
        ///      the v1.6.15 round showed the guardian could arm the window with
        ///      its OWN first trade and freeze the pool in the same block, so
        ///      the window lapsed with nobody but it able to trade (`P6-claude`
        ///      MEDIUM, `P16-claude` MEDIUM, and the PoC was red).
        ///
        ///      Counting the blocks the pool actually SERVED removes the last of
        ///      it: a frozen block serves no trade, so it does not count, and
        ///      there is no quantity left for a freeze to spend. The code now
        ///      measures the promise rather than a proxy for it.
        uint64 servedBlocks;
        /// @notice The block of the most recent served trade, so several trades
        ///         in one block count once.
        /// @dev Both fields stop being written at `CAP_BLOCKS + 1` served
        ///      blocks, so past the window an ordinary trade pays the one SLOAD
        ///      the check needs and no SSTORE — the same cost the height had.
        ///      They share the slot the height occupied.
        uint64 lastServedBlock;
        /// @notice Coin held as a vault claim and owed to `burnFilledCoin`:
        ///         what the internal fill has bought and, since v1.6.24, the
        ///         coin side of the position's own fees (AstraSec I-8).
        uint256 filledCoinPending;
    }

    mapping(PoolId => Pool) internal _pools;
    /// @notice Per-referrer entitlement, in the pool's quote token.
    mapping(PoolId => mapping(address => uint256)) internal _referrerPending;
    /// @notice Coin bought per wallet during the opening window.
    mapping(PoolId => mapping(address => uint256)) internal _purchased;
    /// @notice The buy-back button's tip floor for each quote the deployment
    ///         listed, in raw units of that quote; zero for every other quote.
    ///         `FeastConstants.TIP_BPS` has the rule it feeds.
    /// @dev Written in the constructor and nowhere else, like the shares: no
    ///      function here lists a quote or moves a floor afterwards. Internal,
    ///      because a getter costs 66 bytes of the hook's EIP-170 margin; each
    ///      row is announced by `TipFloorListed` in the deploying transaction
    ///      instead (v1.6.23, task 675). Declared LAST, so that no slot the
    ///      audited layout gave `_pools` and the rest moves.
    mapping(address quote => uint256) internal _tipFloorOf;

    /// @notice Register a pool's immutable configuration, before the venue is
    ///         asked to create it.
    /// @dev Factory-only, and once only. R2: the two creator-set shares are
    ///      checked against their bands here, which is the only moment they can
    ///      ever be checked — after this transaction they are facts.
    function registerPool(
        PoolKey calldata key,
        address coin,
        address creator,
        uint16 selfBurnBps,
        uint16 referrerBps,
        uint256 supply,
        uint64 openAt,
        address opener
    ) external {
        if (msg.sender != factory) revert NotFactory();
        if (selfBurnBps > FeastConstants.MAX_SELF_BURN_BPS || referrerBps > FeastConstants.MAX_REFERRER_BPS) {
            revert ShareOutOfBand();
        }
        // Belt and braces: the two bands already sum to less than the creator
        // side, but the creator's remainder is computed by subtraction and an
        // underflow there would be permanent.
        if (uint256(selfBurnBps) + uint256(referrerBps) > FeastConstants.CREATOR_SIDE_BPS) revert ShareOutOfBand();

        // The gate, bounded here, at the contract that enforces it: a pool is
        // either open from its first block (no gate, no opener) or closed to all
        // but one opener until an instant in the near future — never both, never
        // neither, and never for longer than `MAX_GATE_DURATION`, whatever the
        // caller asks for.
        if (openAt == 0) {
            if (opener != address(0)) revert GateOutOfBounds(openAt, opener);
        } else if (
            opener == address(0) || openAt <= block.timestamp
                || openAt > block.timestamp + FeastGenesis.MAX_GATE_DURATION
        ) {
            revert GateOutOfBounds(openAt, opener);
        }

        PoolId poolId = key.toId();
        Pool storage p = _pools[poolId];
        if (p.coin != address(0)) revert PoolAlreadyRegistered();

        bool isCurrency0 = Currency.unwrap(key.currency0) == coin;
        if (!isCurrency0 && Currency.unwrap(key.currency1) != coin) revert CoinNotInPool();

        p.coin = coin;
        p.coinIsCurrency0 = isCurrency0;
        p.creator = creator;
        p.selfBurnBps = selfBurnBps;
        p.referrerBps = referrerBps;
        p.openAt = openAt;
        p.opener = opener;
        p.perWalletCap = supply * FeastConstants.CAP_BPS_OF_SUPPLY / FeastConstants.BPS;
        // The marker the creator's pre-buy is recognised by. Written for every
        // pool, because the other half of the predicate — the factory is the
        // swapper — is what makes it mean anything, and the factory swaps only
        // inside `create`. Genesis registers a gated pool and never swaps.
        assembly ("memory-safe") {
            tstore(PREBUY_POOL_SLOT, poolId)
        }
        emit PoolRegistered(poolId, coin, creator, selfBurnBps, referrerBps);
    }

    function poolInfo(PoolId poolId) external view returns (Pool memory) {
        return _pools[poolId];
    }

    // --- what each bucket is owed ----------------------------------------
    //
    // Derived, not stored. `creatorPending` is the remainder, so the four
    // always sum to exactly `accruedQuote` however the arithmetic rounds.

    /// @notice Quote waiting to buy this coin in its own pool and burn it.
    function selfBurnPending(PoolId poolId) public view returns (uint256) {
        Pool storage p = _pools[poolId];
        return p.selfBurnEarned - p.selfBurnUsed;
    }

    /// @notice The platform's accrued share, in the pool's quote token.
    /// @dev    It leaves through `releasePlatformFees`, as the asset it accrued
    ///         in, to the sink the genesis call names. The total is monotone and
    ///         `platformUsed` grows only by what was paid.
    function platformPending(PoolId poolId) public view returns (uint256) {
        Pool storage p = _pools[poolId];
        return p.platformEarned - p.platformUsed;
    }

    /// @notice The creator's own remainder.
    function creatorPending(PoolId poolId) public view returns (uint256) {
        Pool storage p = _pools[poolId];
        return p.creatorEarned - p.creatorPaid;
    }

    function referrerPending(PoolId poolId, address referrer) public view returns (uint256) {
        return _referrerPending[poolId][referrer];
    }

    // Who a wallet is bound to is `referrals.referrerOf(wallet)`. The hook's own
    // `referrerOf` view re-exported it until v1.6.25 and is gone in v1.6.26: it
    // cost 64 bytes the hook did not have (`docs/audit/v1.6.26-changes.md`).

    // --- the fair open ----------------------------------------------------

    function perWalletCap(PoolId poolId) external view returns (uint256) {
        return _pools[poolId].perWalletCap;
    }

    /// @notice How many distinct blocks a pool has served a trade in. The
    ///         opening cap binds while this is at most `CAP_BLOCKS`.
    /// @dev    v1.6.14 kept this in "open blocks" — `block.number` less the
    ///         guardian's frozen blocks — so that a freeze could not spend the
    ///         window. A contract cannot observe its chain's block rate, so
    ///         those frozen blocks were an estimate (`granted / 3`) and the
    ///         estimate was short by a factor of four on BSC: 86,400 credited
    ///         for 345,598 blocks actually frozen, with `CAP_BLOCKS` at 2. The
    ///         correction did not work on the chain it ships to (v1.6.14 round,
    ///         `P16-claude` HIGH, `P6-claude` HIGH).
    ///
    ///         The block domain is gone. The window is anchored on an event a
    ///         freeze cannot spend instead — the pool's first served public
    ///         swap — so there is no clock between the arming and the check for
    ///         a freeze to run. See `_beforeSwap` for the one arming site.
    function servedBlocks(PoolId poolId) external view returns (uint64) {
        return _pools[poolId].servedBlocks;
    }

    /// @notice Whether the opening cap still binds on this pool.
    function capBinds(PoolId poolId) external view returns (bool) {
        return _pools[poolId].servedBlocks <= FeastConstants.CAP_BLOCKS;
    }

    function purchasedDuringOpening(PoolId poolId, address buyer) external view returns (uint256) {
        return _purchased[poolId][buyer];
    }

    /// @notice The exemption list, in full.
    /// @dev The product promises an empty, publicly readable exemption list.
        ///      Shipping an owner-managed mapping that merely happens to be empty
    ///      would be shipping the owner function the promise denies. This is a
    ///      pure function that returns false, and the verified source is the
    ///      proof — there is nothing to inspect and nothing to add to.
    function isExempt(address) external pure returns (bool) {
        return false;
    }

    /// @dev The factory, always — that is every creator launch. And, from
    ///      v1.6.11, a GATED pool's registered opener: the launch window
    ///      initialises the platform pool itself, at the auction's clearing
    ///      price, inside `settle()`. That price cannot be known before then,
    ///      which is the whole reason the pool is not initialised at genesis.
    ///
    ///      `opener` is `address(0)` for every ungated pool and `sender` is
    ///      never zero, so an ordinary coin stays factory-only without a second
    ///      test — and a pool nobody registered has no opener either.
    function _mayInitialize(address sender, PoolKey calldata key) internal view override returns (bool) {
        return sender == factory || sender == _pools[key.toId()].opener;
    }

    function _onPoolInitialized(PoolKey calldata key) internal override {
        Pool storage p = _pools[key.toId()];
        if (p.coin == address(0)) revert PoolNotRegistered();
        p.live = true;
        // The cap's window is armed by the pool's first SERVED public swap, in
        // `_beforeSwap`, for BOTH kinds of pool — and so not here. A gated pool
        // stopped arming here at v1.6.10, because arming at initialisation spent
        // the whole two-block window on blocks in which nobody but the opener
        // could trade, tens of thousands of blocks before the gate opened
        // (v1.6.9 pack, CA-eeefa2ee72). An ungated pool kept arming here until
        // v1.6.15, and the v1.6.14 round showed why that was the same mistake
        // wearing a shorter clock: a freeze spanning the opening blocks spent
        // the window while every swap was refused.
        //
        // Zero is how `_beforeSwap` recognises an unarmed pool, of either kind.
    }

    // --- the take ---------------------------------------------------------

    /// @dev Which real currency the venue calls "specified" depends on two
    ///      booleans, so landing the fee on the *quote* every time takes four
    ///      branches: two here and two in `_afterSwap`.
    /// @notice The fee for the two branches where the quote is the *specified*
    ///         currency, or zero for the other two.
    /// @dev Shared by `beforeSwap`, which charges it, and `afterSwap`, which
    ///      checks the venue filled the whole of what it was charged on. One
    ///      definition, so the two cannot drift apart.
    ///
    ///      The two corrections are the reason the four branches price alike.
    ///      This fee is taken *before* the venue's own LP fee, so a flat 1% of
    ///      the gross would overcharge relative to the afterSwap branches, which
    ///      see post-swap amounts. Dividing by (1e6 + fee) on the way in and
    ///      (1e6 - fee) on the way out makes it 1% of what actually crosses the
    ///      pool boundary — the same number the other two take 1% of. Drop
    ///      either and exact-in quietly prices differently from exact-out.
    function _specifiedLegFee(IFeastCLPoolManager.SwapParams calldata params, bool buyingCoin, bool isExactInput)
        private
        pure
        returns (int128)
    {
        if (isExactInput != buyingCoin) return 0;
        // v1.6.4 G1 sweep, round r1 (r1v): the swap amount was multiplied by
        // `FEE_PIPS` and only THEN narrowed, and `toInt128` bounds the result,
        // not the intermediate — so an absurd `amountSpecified` panicked 0x11 on
        // the product rather than being refused by name. `beforeSwap` runs
        // before the venue has cast the amount down to 128 bits, which is the
        // whole reason `toInt128` exists here. Narrowing FIRST bounds every
        // product below by `2**127 x 10**4 < 2**141`, and the refusal keeps the
        // name the library was written to give it.
        int256 specified = FeastMath.toInt128(params.amountSpecified);
        if (isExactInput) {
            return FeastMath.toInt128(
                -specified * int256(uint256(FeastConstants.FEE_PIPS))
                    / int256(uint256(FeastConstants.FEE_DENOMINATOR) + uint256(FeastConstants.FEE_PIPS))
            );
        }
        return FeastMath.toInt128(
            specified * int256(uint256(FeastConstants.FEE_PIPS))
                / int256(uint256(FeastConstants.FEE_DENOMINATOR) - uint256(FeastConstants.FEE_PIPS))
        );
    }

    /// @dev R3. The reference exits early only on empty data, which leaves one
    ///      to thirty-one bytes reaching `abi.decode` — where it reverts *the
    ///      swap*. Any router that appended a byte would break every trade in
    ///      the pool, so feast checks the length exactly and treats anything
    ///      that is not a form it knows as "no referrer" rather than as an
    ///      error. Refusing a commission is cheap; refusing a trade is not.
    ///
    ///      v1.6 (ruling 5, Q5): **a referrer who is the payer is no referral
    ///      at all** — no commission and no referral credit. Decided in
    ///      `_referrerFor`, the one place a referrer is resolved, so the two
    ///      consequences cannot drift apart. The payer is `tx.origin`, the same
    ///      identity the ledger credits; comparing with the router (`sender`)
    ///      would refuse nothing. A second address evades it, and the owner's
    ///      ruling accepts that.
    ///
    ///      Two forms, and only two:
    ///
    ///        32 bytes  `abi.encode(referrer)`          — this trade only, and
    ///                                                    it never binds. What
    ///                                                    v1.6.7 accepted, so
    ///                                                    every integrator
    ///                                                    built against it
    ///                                                    keeps working.
    ///        64 bytes  `abi.encode(referrer, wallet)`  — this trade only, and
    ///                                                    since v1.6.26 it
    ///                                                    never binds either
    ///                                                    (AstraSec M-4).
    ///                                                    `wallet` feeds only
    ///                                                    the refusals in
    ///                                                    `_referrerFor`.
    ///
    ///      Anything else is no referrer. `docs/referrer-binding.md` §1.
    function _referrerFrom(bytes calldata hookData) private pure returns (address referrer, address wallet) {
        if (hookData.length == 32) return (_addressFrom(bytes32(hookData[0:32])), address(0));
        if (hookData.length == 64) {
            return (_addressFrom(bytes32(hookData[0:32])), _addressFrom(bytes32(hookData[32:64])));
        }
        return (address(0), address(0));
    }

    /// @dev One word to one address, and never a revert.
    ///
    ///      Not `abi.decode(..., (address))`. Decoding an address checks that
    ///      the top 96 bits are clear and *reverts* if they are not — so a
    ///      caller who passes a full-width word of garbage would revert the
    ///      swap, which is the very thing R3 exists to prevent. Fuzzing found
    ///      it on the referrer word; the reference has the same hole one
    ///      length-check further out. The wallet word is the same hazard and
    ///      gets the same reader, so a malformed one reads as the zero address
    ///      — which names no wallet, so such a trade pays per-trade. It is
    ///      never an error.
    function _addressFrom(bytes32 word) private pure returns (address) {
        uint256 value = uint256(word);
        if (value > type(uint160).max) return address(0);
        return address(uint160(value));
    }

    /// @dev The creator's pre-buy, structurally: the factory is the swapper AND
    ///      this pool was registered in this very transaction. Both halves are
    ///      needed — the factory swaps only inside `create`, and the transient
    ///      marker cannot outlive the transaction that wrote it — so no later
    ///      trade by anyone, the creator included, can match. `tx.origin` is
    ///      never consulted.
    ///      Split so the cheap half is at the call site: every trade in every
    ///      pool evaluates `sender == factory`, which is an immutable compare
    ///      and touches nothing, and only a swap that passes it reaches the
    ///      transient load. Folding both into one helper cost 154 gas on every
    ///      trade for ever, which the referral gas test measured.
    function _prebuyMarked(PoolId poolId) private view returns (bool) {
        bytes32 marked;
        assembly ("memory-safe") {
            marked := tload(PREBUY_POOL_SLOT)
        }
        return marked == PoolId.unwrap(poolId);
    }

    function _referrerFor(PoolId poolId, Pool storage p, address sender, bytes calldata hookData)
        private
        view
        returns (address)
    {
        // A PROTOCOL-INITIATED swap introduces nobody, so it carries no referrer
        // and its fee routes as an unreferred trade's does. Identified
        // STRUCTURALLY, never by `tx.origin`: `p.opener` is the contract the
        // pool was registered as gated to — the launch window and nobody else —
        // and is zero for every ungated pool, while `sender` is never zero.
        // `address(this)` covers the hook's own swaps; the platform sink's
        // buy-back reaches the venue through `buyBackAndBurn`, so the hook is
        // the swapper there. That path does not reach the callbacks at all (the
        // venue skips a hook's callbacks when the hook is the swapper) and is
        // named anyway, so the rule is about who INITIATED the swap rather than
        // about which callbacks happen to fire. The converter's hops are v3
        // pools, never feast pools.
        //
        // Ordered so an ordinary pool pays nothing: the `address(this)` test
        // touches no storage, `p.openAt` is warm by the time either callback
        // asks, and `p.opener` — which has a cold slot of its own — is read only
        // for a pool that carries a gate. Folded into this ONE function rather
        // than tested at both call sites: emitted twice it cost 343 bytes of a
        // contract that had 129 to spare (v1.6.9 pack, CA-0d1fa81d6c).
        // The creator's pre-buy is factory-initiated and introduces nobody. It
        // matters more than it looks: a creator who happens to carry a lifetime
        // binding would otherwise hand their referrer a commission on the
        // largest single trade their coin will ever see.
        if (
            sender == address(this) || (p.openAt != 0 && sender == p.opener)
                || (sender == factory && _prebuyMarked(poolId))
        ) {
            return address(0);
        }


        address origin = tx.origin;

        // The binding is supreme. Once set it decides every later trade of this
        // wallet, on every pool, and `hookData` is not consulted at all.
        // v1.6.26 (AstraSec M-4): it is read from `referrals`, where only the
        // wallet itself can write it, by its own call or its own signature. No
        // trade writes a binding any more, in either form.
        //
        // The read is `referrals.referrerOf(origin)` spelled in assembly, because
        // the Solidity call measured 61 bytes more, 26 over the limit. It is
        // the call Solidity makes, with its decoder's checks: static, and
        // refused unless it succeeds with a whole word holding an address. A
        // failure is refused without the callee's revert data, which a mapping
        // getter has none of to give. `origin()` is `tx.origin`.
        //
        // Only `tx.origin` is looked up. The 64-byte form's wallet word is not:
        // a smart account's lifetime binding is honoured only on its own direct
        // trades. That is a bytecode decision, not a design one — the lookup did
        // not fit (`docs/audit/v1.6.26-changes.md`).
        address bound;
        address registry = address(referrals);
        assembly ("memory-safe") {
            mstore(0, 0xd21cacdf) // referrerOf(address)
            mstore(0x20, origin())
            let ok := staticcall(gas(), registry, 0x1c, 0x24, 0, 0x20)
            bound := mload(0)
            if iszero(and(ok, and(gt(returndatasize(), 0x1f), iszero(shr(160, bound))))) { revert(0, 0) }
        }
        if (bound != address(0)) return bound;

        (address named, address wallet) = _referrerFrom(hookData);
        if (named == address(0)) return address(0);

        // v1.6 ruling 5, Q5, and it now covers both forms from one line: a
        // referrer who is the payer is no referral at all. A wallet cannot be
        // its own introduction, so there is no self-rebate to pay once and none
        // to make permanent. A second address evades it, and the owner's ruling
        // accepts that.
        if (named == origin) return address(0);

        // The 64-byte form, which bound until v1.6.25 and keeps the refusals it
        // had then.
        if (wallet != address(0)) {
            // The burn address is not a referrer. It is a valid, non-zero
            // address, so a wallet bound to it would burn `referrerBps` of every
            // fee it paid for the rest of its life, with no way back — there is
            // no re-binding. Refused in the spirit of I14: `FeastReferrals`
            // refuses the binding, and this form, which made bindings until
            // v1.6.25, still refuses the trade. The 32-byte form may still name
            // it: what the ruling refuses is making the choice permanent, not
            // making it once.
            if (named == FeastConstants.BURN_ADDRESS) return address(0);
            // The same refusal as above, for the wallet this trade CLAIMS rather
            // than for the one that signed. Reached when a bundler submits a
            // trade naming an account as its own referrer.
            if (named == wallet) return address(0);
        }

        // Both forms: this trade only, and neither binds. Every integrator
        // built against v1.6.7 keeps working, unchanged.
        return named;
    }

    function _beforeSwap(
        address sender,
        PoolKey calldata key,
        IFeastCLPoolManager.SwapParams calldata params,
        bytes calldata hookData
    ) internal override returns (BeforeSwapDelta) {
        PoolId poolId = key.toId();
        // The brake, first of all: a frozen pool does not trade. The venue's own
        // pause has exactly this shape — a revert from the hook — and placing it
        // above everything else means no branch can slip past it.
        _requireUnfrozen();
        Pool storage p = _pools[poolId];

        // The gate. First, before the fee's early return, because the venue
        // calls `beforeSwap` on every swap but the exact-in sell takes its fee
        // only in `afterSwap` — a gate placed below the return would let that
        // branch through. `sender` is whoever called the venue: for the launch
        // window, the window itself. Zero `openAt` (every ordinary coin) makes
        // this a single comparison that never refuses.
        // The gate, and the cap's arming, from one comparison.
        //
        // `openAt` is read once into a local: a `storage` pointer re-reads the
        // slot on every mention. Below the gate, `block.timestamp >= openAt`
        // means the pool is open to everyone — so a pool that has not yet armed
        // its per-wallet cap arms it HERE, at the first swap it actually SERVES.
        //
        // **One arming site for both kinds of pool** (v1.6.15, coordinator
        // ruling). A gated pool has armed here since v1.6.10. An ungated pool
        // armed at initialisation until v1.6.15, in a block coordinate that a
        // freeze could spend — and v1.6.14's attempt to correct that coordinate
        // needed a frozen-BLOCK counter, which a contract cannot compute,
        // because it cannot observe its chain's block rate. Anchoring the window
        // on an event instead of on a clock removes the whole class: between the
        // arming and the check there is no clock for a freeze to run.
        //
        // What it means, stated: an ungated pool's cap window now starts at its
        // first served trade rather than at its creation block. A pool that has
        // not traded has not opened, so this is closer to P6 as written.
        //
        // **The boundary that remains.** The `CAP_BLOCKS` window is still wall
        // blocks once armed, so a freeze placed AFTER the arming and inside the
        // window lets it lapse while swaps are refused. With `CAP_BLOCKS` at 2
        // the guardian would have to freeze within one block of the pool's first
        // public trade, which it cannot schedule — it does not know when a
        // stranger will trade, and `freeze` is not callable from inside a swap.
        // The excluded adversary is a guardian that both predicts the first
        // trade and lands a freeze in the next block. If that is ever shown
        // reachable, the freeze-proof form is to count SERVED blocks — increment
        // a per-pool counter on each distinct block the pool trades in — which
        // costs a slot and a warm SSTORE per opening block. Not built.
        //
        // The window's settlement cannot reach the arming branch because it is
        // not a swap: since v1.6.12 it initialises the pool and seeds it, and
        // neither calls `beforeSwap`. That is what matters now — this note used
        // to rest on `FeastLaunchWindow._canSettle` requiring
        // `block.timestamp < openAt`, and since v1.6.24 `settle` has no deadline
        // and may run after `openAt` (AstraSec M-2).
        //
        // The creator's pre-buy does not arm it either. It is the creation of
        // the position, not a public trade, and it is bounded by the factory's
        // own `MAX_PREBUY_BPS_OF_SUPPLY`; letting it arm would put the window
        // back at the creation block, which is what this change removes. It is
        // the same structural pair `_afterSwap` exempts from the cap at :890.
        uint64 openAt = p.openAt;
        if (block.timestamp < openAt) {
            if (sender != p.opener) revert PoolNotOpenYet(openAt);
        } else if (
            p.servedBlocks <= FeastConstants.CAP_BLOCKS && uint64(block.number) != p.lastServedBlock
                && !(sender == factory && _prebuyMarked(poolId))
        ) {
            // One count per distinct block, and only while the window is open.
            p.lastServedBlock = uint64(block.number);
            p.servedBlocks += 1;
        }

        bool buyingCoin = params.zeroForOne != p.coinIsCurrency0;
        bool isExactInput = params.amountSpecified < 0;

        int128 fee = _specifiedLegFee(params, buyingCoin, isExactInput);
        if (fee <= 0) {
            // Layer 2 (owner ruling Q15): an exact-input sale is offered to the
            // pool's own buy-and-burn bucket first, at the pool's price. The
            // coin is the specified currency here, so the fill is a pure
            // specified-for-unspecified delta and the fee arithmetic of the four
            // branches is untouched; the fee on the whole sale is taken in
            // `afterSwap`, which learns the filled amount from `_takeFill`.
            // `type(int256).min` has no positive counterpart; a request that
            // size is a price-limited partial sale the venue may accept, and
            // negating it here would panic (round 3, L1). It is not filled.
            if (!buyingCoin && isExactInput && params.amountSpecified != type(int256).min) {
                (uint256 coinIn, uint256 quoteOut) = _fill(key, p, poolId, uint256(-params.amountSpecified));
                if (coinIn != 0) {
                    return toBeforeSwapDelta(
                        FeastMath.toInt128(int256(coinIn)), -FeastMath.toInt128(int256(quoteOut))
                    );
                }
            }
            return ZERO_BEFORE_SWAP_DELTA;
        }
        _accrue(key, p, uint256(uint128(fee)), _referrerFor(poolId, p, sender, hookData));
        return toBeforeSwapDelta(fee, 0);
    }

    // --- layer 2: the internal fill ------------------------------------------

    /// @dev Transient handoff of one fill from `beforeSwap` to `afterSwap` of the
    ///      same swap. Nothing runs between the two but the venue's own pool
    ///      arithmetic, so one pair of slots suffices; `_takeFill` clears them.
    ///      The slots are keccak256("feast.hook.fill.coin") and
    ///      keccak256("feast.hook.fill.quote"), written as literals because
    ///      inline assembly reads only literal constants.
    uint256 private constant FILL_COIN_SLOT = 0x0ac55f1e3d8b506a8b06480908578baa3de65144df8c049333c8786b1ebbced1;

    /// @dev The pool `registerPool` last registered, IN THIS TRANSACTION. It is
    ///      how the creator's pre-buy is recognised structurally: `registerPool`
    ///      is factory-only and runs exactly once per `create`, and transient
    ///      storage is cleared when the transaction ends, so the pair
    ///      (the factory is the swapper, this pool was registered in this
    ///      transaction) can only be true inside the creating call. `tx.origin`
    ///      is not part of it and must never become part of it.
    ///
    ///      `keccak256("feast.prebuy.pool")`.
    uint256 private constant PREBUY_POOL_SLOT = 0xa8995b7caf3773603f05a1684e75893f18910eb9077b2ed7c4a86d9b77b11e20;
    uint256 private constant FILL_QUOTE_SLOT = 0x157b049fe8c0decb1acdd49bd9d11fb4a118250f11dfe6df4735daab71b9e26a;
    uint256 private constant Q96 = 0x1000000000000000000000000;
    uint256 private constant Q192 = 1 << 192;
    uint160 private constant MIN_FILL_SQRT_PRICE = uint160(1 << 64);
    uint160 private constant MAX_FILL_SQRT_PRICE = uint160(1 << 128);

    /// @notice Burn the coin the internal fill has bought — and, since v1.6.24,
    ///         the coin side of the position's fees — held until now as a vault
    ///         claim. Callable by anyone; at most one settlement per call.
    /// @dev Off the swap path, where a token transfer belongs (the hook's founding
    ///      rule). A settlement site under §6c B5: bounded by `MAX_SETTLEMENT`,
    ///      debited by exactly what is burned. The coin is feast's own token, so
    ///      nothing can refuse it.
    function burnFilledCoin(PoolKey calldata key) external nonReentrant {
        _requireUnfrozen();
        PoolId poolId = key.toId();
        Pool storage p = _pools[poolId];
        uint256 amount = p.filledCoinPending;
        if (amount > FeastConstants.MAX_SETTLEMENT) amount = FeastConstants.MAX_SETTLEMENT;
        if (amount == 0) return;
        p.filledCoinPending -= amount;
        emit FilledCoinBurned(poolId, amount);
        Currency coin = p.coinIsCurrency0 ? key.currency0 : key.currency1;
        IFeastVault(vault).lock(abi.encode(Action.Payout, coin, address(this), amount));
        IFeastBurnable(p.coin).burn(amount);
    }

    function filledCoinPending(PoolId poolId) external view returns (uint256) {
        return _pools[poolId].filledCoinPending;
    }

    /// @notice Take part of an exact-input sale into the burn, paid from this
    ///         pool's buy-and-burn bucket at the pool's own price.
    /// @dev Never refuses the trade: every reason not to fill returns zero and the
    ///      whole sale goes to the pool. The fill
    ///
    ///      - happens only on an open pool with an allowance, and only when the
    ///        pool's spot price is within `MAX_TICK_DEVIATION` of its own average
    ///        (the button's bound; the oracle is asked with `try`, so a young
    ///        oracle means "no fill", never a revert);
    ///      - is priced at spot, rounded down, so the protocol never pays more
    ///        than the pool would and the seller never less than the curve;
    ///      - takes at most one unit short of the sale (the pool always swaps
    ///        something), at most the self-burn allowance — ONE allowance shared
    ///        with `buyBackAndBurn`, so the 20%-per-hour bound holds across both
    ///        legs — and at most one settlement (F7, `MAX_SETTLEMENT`);
    ///      - prices only inside the domain where it can be exact (see
    ///        `_quoteForCoin`);
    ///      - settles inside the swap in claims alone: the hook burns its quote
    ///        claims and is minted coin claims, so no token moves on the swap
    ///        path and a frozen quote cannot refuse any of it (I2); the coin is
    ///        burned for real by `burnFilledCoin`, off the path.
    function _fill(PoolKey calldata key, Pool storage p, PoolId poolId, uint256 coinOffered)
        private
        returns (uint256 coinIn, uint256 quoteOut)
    {
        if (block.timestamp < p.openAt || coinOffered < 2) return (0, 0);
        // The venue narrows the trader's merged delta to `int128` on both legs
        // when it subtracts the hook's delta from the pool's (`BalanceDelta.sub`
        // -> `SafeCast.toInt128`). The fill pays at spot, on top of what the
        // pool pays for the rest of the sale, and it pays better than the pool
        // would, so it can push that sum past the limit for a sale the pool
        // alone could have served. The bound below is the venue's own: serve
        // only a sale whose coin amount, and whose value at spot, each fit
        // `int128`. Then coin taken + coin the pool takes <= `coinOffered`, and
        // quote paid + quote the pool pays <= the sale's value at spot, because
        // a sale only moves the price against itself and the pool charges its
        // own fee on top. A larger sale is not refused: it goes to the pool
        // unfilled (v1.6.1, CA-ece82bf971).
        if (coinOffered > FeastConstants.MAX_SETTLEMENT) return (0, 0);
        uint256 pending = p.selfBurnEarned - p.selfBurnUsed;
        if (pending == 0) return (0, 0);
        uint256 allowanceScaled = _accruedScaled(p, pending);
        uint256 allowance = allowanceScaled / FeastConstants.ALLOWANCE_SCALE;
        if (allowance > FeastConstants.MAX_SETTLEMENT) allowance = FeastConstants.MAX_SETTLEMENT;
        if (allowance == 0) return (0, 0);

        (uint160 sqrtPriceX96, int24 spotTick,,) = IFeastCLPoolManager(poolManager).getSlot0(poolId);
        // Priced exactly, once, only inside the domain where the square of the
        // square-root price fits a word (raw prices between 2^-64 and 2^64 of
        // one token in the other). Outside it, no fill — never a revert: a
        // declared boundary, not a claim about every market (round 4 L1). Every
        // quote the protocol prices is 18-decimal; a six-decimal quote on the
        // open factory can fall outside and simply trades unfilled.
        if (sqrtPriceX96 < MIN_FILL_SQRT_PRICE || sqrtPriceX96 >= MAX_FILL_SQRT_PRICE) return (0, 0);
        if (!_spotIsNearAverage(poolId, spotTick)) return (0, 0);
        // The second half of the venue's bound, now that the price is known and
        // inside the domain where its square fits a word.
        if (_quoteForCoin(coinOffered, sqrtPriceX96, p.coinIsCurrency0) > FeastConstants.MAX_SETTLEMENT) {
            return (0, 0);
        }

        coinIn = coinOffered - 1;
        if (coinIn > FeastConstants.MAX_SETTLEMENT) coinIn = FeastConstants.MAX_SETTLEMENT;
        quoteOut = _quoteForCoin(coinIn, sqrtPriceX96, p.coinIsCurrency0);
        if (quoteOut > allowance) {
            coinIn = _coinForQuote(allowance, sqrtPriceX96, p.coinIsCurrency0);
            quoteOut = _quoteForCoin(coinIn, sqrtPriceX96, p.coinIsCurrency0);
        }
        if (coinIn == 0 || quoteOut == 0) return (0, 0);

        // Debited by what is paid, and the allowance with it — the same two
        // writes a press makes, so the button and the fill spend one budget.
        p.selfBurnUsed += quoteOut;
        p.allowanceRemaining = allowanceScaled - quoteOut * FeastConstants.ALLOWANCE_SCALE;
        p.allowanceUpdatedAt = uint64(block.timestamp);

        Currency quote = p.coinIsCurrency0 ? key.currency1 : key.currency0;
        Currency coin = p.coinIsCurrency0 ? key.currency0 : key.currency1;
        // Nothing physical moves: the hook pays in quote CLAIMS it already holds
        // and is paid in coin CLAIMS, so no token is transferred and the vault's
        // balances are untouched on the swap path — rounds 2 and 3 found two
        // honest router orderings that a physical take broke (graveyard). The
        // hook's delta nets to zero: the delta returned below credits `coinIn`
        // coin and debits `quoteOut` quote, and these two calls do the opposite.
        // The coin claim is burned for real by `burnFilledCoin`, off the path.
        IFeastVault(vault).burn(address(this), quote, quoteOut);
        IFeastVault(vault).mint(address(this), coin, coinIn);
        p.filledCoinPending += coinIn;

        assembly ("memory-safe") {
            tstore(FILL_COIN_SLOT, coinIn)
            tstore(FILL_QUOTE_SLOT, quoteOut)
        }
        emit InternalFill(poolId, coinIn, quoteOut);
    }

    /// @dev What `beforeSwap` filled in this swap, cleared as it is read.
    function _takeFill() private returns (uint256 coinIn, uint256 quoteOut) {
        assembly ("memory-safe") {
            coinIn := tload(FILL_COIN_SLOT)
            quoteOut := tload(FILL_QUOTE_SLOT)
            tstore(FILL_COIN_SLOT, 0)
            tstore(FILL_QUOTE_SLOT, 0)
        }
    }

    /// @dev The button's bound, as a question rather than a refusal. Same shape
    ///      and same open-time condition as `_requireSpotNearAverage`; this one
    ///      is on the swap path, through the internal fill.
    function _spotIsNearAverage(PoolId poolId, int24 spotTick) private view returns (bool) {
        if (!_averageHasHadOpenTime()) return false;
        try oracle.twapTick(poolId) returns (int24 averageTick) {
            int24 deviation = spotTick > averageTick ? spotTick - averageTick : averageTick - spotTick;
            return deviation <= FeastConstants.MAX_TICK_DEVIATION;
        } catch {
            return false;
        }
    }

    /// @dev Quote for `coinAmount` at a square-root price, rounded down ONCE from
    ///      the exact ratio (round 3, L2: flooring after each square-root factor
    ///      could pay less than both spot and the pool). `sqrtPriceX96` is inside
    ///      the fill's domain, so its square fits a word and one 512-bit
    ///      multiply-divide is exact — no tick mathematics, nothing GPL-licensed.
    function _quoteForCoin(uint256 coinAmount, uint160 sqrtPriceX96, bool coinIsCurrency0)
        private
        pure
        returns (uint256)
    {
        uint256 p2 = uint256(sqrtPriceX96) * uint256(sqrtPriceX96);
        return coinIsCurrency0 ? Math.mulDiv(coinAmount, p2, Q192) : Math.mulDiv(coinAmount, Q192, p2);
    }

    /// @dev The coin `quoteAmount` buys at a square-root price, rounded down once.
    function _coinForQuote(uint256 quoteAmount, uint160 sqrtPriceX96, bool coinIsCurrency0)
        private
        pure
        returns (uint256)
    {
        uint256 p2 = uint256(sqrtPriceX96) * uint256(sqrtPriceX96);
        return coinIsCurrency0 ? Math.mulDiv(quoteAmount, Q192, p2) : Math.mulDiv(quoteAmount, p2, Q192);
    }

    function _afterSwap(
        address sender,
        PoolKey calldata key,
        IFeastCLPoolManager.SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) internal override returns (int128) {
        PoolId poolId = key.toId();
        Pool storage p = _pools[poolId];

        uint160 sqrtPriceX96After = _observePrice(poolId);

        bool buyingCoin = params.zeroForOne != p.coinIsCurrency0;
        bool isExactInput = params.amountSpecified < 0;

        // R5. The cap is checked here rather than in `beforeSwap` because it is
        // denominated in coin *bought*, and for an exact-input trade that
        // number does not exist until the swap has happened. Reverting here
        // still reverts the whole trade.
        // The creator's pre-buy is not an opening purchase by a wallet; it is
        // the creation of the position, and it is bounded by the factory's own
        // `MAX_PREBUY_BPS_OF_SUPPLY` instead. It must not write `_purchased`
        // either: the creator's NEXT buy, from their own wallet, is capped at
        // 0.5% in these same opening blocks like anyone's (P6).
        // Ordinary `block.number`, against a window armed in the same unit at
        // the pool's first served swap — `_beforeSwap`, one site for both kinds
        // of pool. v1.6.13 found that a freeze spanning the opening blocks spent
        // a window armed at creation; v1.6.14 tried to correct the coordinate
        // with a frozen-block counter and could not, because a contract cannot
        // observe its chain's block rate. v1.6.15 anchors the window on an event
        // a freeze cannot spend instead, which leaves no clock here to correct.
        if (p.servedBlocks <= FeastConstants.CAP_BLOCKS && !(sender == factory && _prebuyMarked(poolId))) {
            int128 coinLeg = p.coinIsCurrency0 ? delta.amount0() : delta.amount1();
            // Only purchases. Capping sales would trap the earliest buyers in a
            // coin they are not allowed to leave — the opposite of the intent.
            if (coinLeg > 0) {
                uint256 bought = _purchased[poolId][tx.origin] + uint256(uint128(coinLeg));
                if (bought > p.perWalletCap) revert PurchaseCapExceeded();
                _purchased[poolId][tx.origin] = bought;
            }
        }

        if (isExactInput == buyingCoin) {
            // The quote was the SPECIFIED currency, so its fee was necessarily
            // taken in `beforeSwap` — the venue only accepts a specified-side
            // delta from there, and offers no way to adjust it once the real
            // amounts are known. That fee was therefore computed on the amount
            // *requested*.
            //
            // Which is only the amount *realised* when the swap filled whole.
            // A price limit that stops the venue early would leave the fee
            // charged on a trade that did not happen — at the extreme, the
            // whole of a tiny fill. Round 1 constructed exactly that.
            //
            // Since the fee cannot be refunded on this leg (an `afterSwap`
            // return only reaches the *unspecified* currency, which here is the
            // coin), the honest move is to refuse the trade rather than
            // misprice it. R18. Any partial fill whose quote is the unspecified
            // currency is unaffected: those fees are taken from realised deltas
            // below, and are always right.
            int128 realisedQuote = p.coinIsCurrency0 ? delta.amount1() : delta.amount0();
            int128 specifiedFee = _specifiedLegFee(params, buyingCoin, isExactInput);
            int256 requested = params.amountSpecified + int256(specifiedFee);
            if (int256(realisedQuote) != requested) {
                revert PartialFillNotSupported(requested, int256(realisedQuote));
            }
            // The fee was taken on the quote in `beforeSwap`, so the trader's
            // quote is the pool's less that fee.
            _emitTrade(
                key,
                p,
                buyingCoin,
                p.coinIsCurrency0 ? delta.amount0() : delta.amount1(),
                int256(realisedQuote) - int256(specifiedFee),
                sqrtPriceX96After,
                specifiedFee > 0 ? uint256(uint128(specifiedFee)) : 0,
                tx.origin
            );
            return 0;
        }

        // The quote leg of the swapper's delta: positive when the quote is
        // leaving the pool, negative when it is entering.
        int128 quoteLeg = p.coinIsCurrency0 ? delta.amount1() : delta.amount0();
        // What the internal fill paid the seller before the sale reached the
        // pool (zero for anything but a filled exact-input sale). The fee is
        // 1% of the whole sale, so it is charged on this too.
        (uint256 filledCoin, uint256 filledQuote) = _takeFill();

        int128 fee;
        if (isExactInput) {
            // Selling the coin: quote is flowing out, so take a slice of it and
            // the swapper receives that much less. No correction is needed —
            // this amount is already post-swap.
            fee = FeastMath.toInt128(
                (int256(quoteLeg) + int256(filledQuote)) * int256(uint256(FeastConstants.FEE_PIPS))
                    / int256(uint256(FeastConstants.FEE_DENOMINATOR))
            );
        } else {
            // Buying the coin exact-out: quote is flowing in, so charge a slice
            // on top and the swapper pays that much more.
            fee = FeastMath.toInt128(
                -int256(quoteLeg) * int256(uint256(FeastConstants.FEE_PIPS))
                    / int256(uint256(FeastConstants.FEE_DENOMINATOR))
            );
        }

        if (fee < 0) fee = 0;
        if (fee != 0) {
            _accrue(key, p, uint256(uint128(fee)), _referrerFor(poolId, p, sender, hookData));
        }
        _emitTrade(
            key,
            p,
            buyingCoin,
            int256(p.coinIsCurrency0 ? delta.amount0() : delta.amount1()) - int256(filledCoin),
            int256(quoteLeg) + int256(filledQuote) - int256(fee),
            sqrtPriceX96After,
            uint256(uint128(fee)),
            tx.origin
        );
        return fee;
    }

    // --- the permanent lock ----------------------------------------------

    /// @dev What `lockAcquired` is being asked to do. A tagged union rather
    ///      than separate callbacks, because the venue offers exactly one
    ///      callback entrypoint.
    enum Action {
        Seed,
        Payout,
        Buyback,
        CollectLpFees,
        SeedAuction
    }

    /// @notice Place the pool's opening liquidity, and never be able to take it
    ///         back.
    /// @dev The factory has already sent this contract the coins. Every
    ///      reference locks liquidity by minting a position NFT through a
    ///      periphery manager and parking it somewhere with no withdraw path,
    ///      which drags in an ERC-721, a permit system and a calldata planner
    ///      for a position that must never move. The hook owns the position
    ///      directly instead: fewer moving parts, and "permanently locked"
    ///      becomes mechanically obvious to anyone reading the verified source.
    ///
    ///      I5: the lock is not a timelock, it is an absence. No function here
    ///      passes a negative `liquidityDelta`, and none can be added later,
    ///      because there is no upgrade path.
    function seedLiquidity(PoolKey calldata key, int24 tickLower, int24 tickUpper, uint128 liquidity) external {
        if (msg.sender != factory) revert NotFactory();
        PoolId poolId = key.toId();
        Pool storage p = _pools[poolId];
        if (!p.live) revert PoolNotRegistered();
        if (p.seeded) revert AlreadySeeded();
        p.seeded = true;

        // Remembered so the position's own fees stay collectable: the range is
        // the only handle on a position that can never otherwise be addressed.
        p.tickLower = tickLower;
        p.tickUpper = tickUpper;

        IFeastVault(vault).lock(abi.encode(Action.Seed, key, tickLower, tickUpper, liquidity));
        emit LiquiditySeeded(poolId, tickLower, tickUpper, liquidity);
    }

    /// @notice Place the platform pool's ONE opening position — the whole usable
    ///         range — after the launch window's auction has cleared, and never
    ///         be able to take it back.
    /// @dev The window's uniform-price auction knows its clearing price only at
    ///      `settle()`, so the platform pool is initialised there and seeded
    ///      here. The position spans `[minUsableTick, maxUsableTick]` and holds
    ///      both tokens: the unsold half of the holding above the clearing price
    ///      and the whole net pot below it. It is a plain constant-product pool
    ///      with reserves `(T_rem, pot_net)`, which is what a half tranche buys
    ///      — see the branch in `_lockAcquired` for why the two sides balance.
    ///
    ///      This is a SEPARATE entry point rather than a flag on
    ///      `seedLiquidity`, because that function refuses any position needing
    ///      quote (`SeedWouldNeedQuote`) and that refusal is still true of every
    ///      creator launch. The platform pool is the one exception in the
    ///      system, and it is named rather than smuggled through.
    ///
    ///      I5 is unchanged: `seeded` flips exactly once, no function here
    ///      passes a negative `liquidityDelta`, and none can be added later.
    function seedAuctionLiquidity(PoolKey calldata key, uint128 liquidity) external {
        if (msg.sender != factory) revert NotFactory();
        PoolId poolId = key.toId();
        Pool storage p = _pools[poolId];
        if (!p.live) revert PoolNotRegistered();
        if (p.seeded) revert AlreadySeeded();
        p.seeded = true;

        // Remembered for the same reason `seedLiquidity` remembers it: the range
        // is the only handle on a position that can never otherwise be
        // addressed, and `collectLpFees` needs it. Leaving it at zero is what
        // stranded the platform pool's LP fees for ever at v1.6.11.
        p.tickLower = _minUsableTick();
        p.tickUpper = _maxUsableTick();

        IFeastVault(vault).lock(abi.encode(Action.SeedAuction, key, liquidity));
        emit LiquiditySeeded(poolId, p.tickLower, p.tickUpper, liquidity);
    }

    /// @dev The widest range whose endpoints are multiples of the tick spacing.
    ///      The same two the factory computes for a creator launch. The venue's
    ///      own tick bounds by name rather than as `±887_272` (v1.6.24, AstraSec
    ///      I-6): a constant, so the bytecode is unchanged.
    function _minUsableTick() private pure returns (int24) {
        return (TickMath.MIN_TICK / FeastConstants.POOL_TICK_SPACING) * FeastConstants.POOL_TICK_SPACING;
    }

    function _maxUsableTick() private pure returns (int24) {
        return (TickMath.MAX_TICK / FeastConstants.POOL_TICK_SPACING) * FeastConstants.POOL_TICK_SPACING;
    }

    /// @dev One position, placed and never removed.
    function _place(PoolKey memory key, int24 lower, int24 upper, uint128 liquidity) private returns (int256) {
        (int256 delta,) = IFeastCLPoolManager(poolManager).modifyLiquidity(
            key,
            IFeastCLPoolManager.ModifyLiquidityParams({
                tickLower: lower,
                tickUpper: upper,
                liquidityDelta: int256(uint256(liquidity)),
                salt: bytes32(0)
            }),
            ""
        );
        return delta;
    }

    /// @notice Burn coin the opening position did not consume.
    /// @dev Factory-only and only before the pool has traded. Rounding leaves a
    ///      remainder in this contract that nothing else would ever be able to
    ///      move; burning it keeps the promise that no balance strands (I14),
    ///      and burning is the only thing that can be done with it — there is
    ///      no path here that sends a coin to anyone.
    ///
    ///      **Burned, not sent to `BURN_ADDRESS`** (v1.6.24, AstraSec I-8). This
    ///      was the one place besides the LP fees' coin side that disposed of a
    ///      coin by transfer while every other disposal here burns, so an
    ///      explorer's supply counted it as held. Every coin this is called with
    ///      is one the factory itself deployed — a `FeastToken` or the platform
    ///      coin, both `ERC20Burnable` — so there is no coin for which a burn is
    ///      not available. Measured: 14 bytes SMALLER than the transfer.
    function burnUnusedSeed(address coin, uint256 amount) external {
        if (msg.sender != factory) revert NotFactory();
        IFeastBurnable(coin).burn(amount);
    }

    function _lockAcquired(bytes calldata data) internal override returns (bytes memory) {
        Action action = abi.decode(data[:32], (Action));
        if (action == Action.Seed) {
            (, PoolKey memory key, int24 tickLower, int24 tickUpper, uint128 liquidity) =
                abi.decode(data, (Action, PoolKey, int24, int24, uint128));
            (int256 delta,) = IFeastCLPoolManager(poolManager).modifyLiquidity(
                key,
                IFeastCLPoolManager.ModifyLiquidityParams({
                    tickLower: tickLower,
                    tickUpper: tickUpper,
                    liquidityDelta: int256(uint256(liquidity)),
                    salt: bytes32(0)
                }),
                ""
            );
            bool coinIsCurrency0 = _pools[key.toId()].coinIsCurrency0;
            int128 coinOwed = coinIsCurrency0 ? BalanceDelta.wrap(delta).amount0() : BalanceDelta.wrap(delta).amount1();
            int128 quoteOwed = coinIsCurrency0 ? BalanceDelta.wrap(delta).amount1() : BalanceDelta.wrap(delta).amount0();

            // A feast launch is single-sided by construction: the creator
            // supplies the coin and nothing else, and the opening position sits
            // entirely on one side of the starting price. A range that straddles
            // that price would demand quote nobody put up. Refusing here names
            // the mistake; letting it through would surface as an opaque
            // balance error from whichever token happened to be asked first.
            if (quoteOwed < 0) revert SeedWouldNeedQuote();

            _pay(coinIsCurrency0 ? key.currency0 : key.currency1, coinOwed);
        } else if (action == Action.SeedAuction) {
            (, PoolKey memory key, uint128 liquidity) = abi.decode(data, (Action, PoolKey, uint128));
            bool coinIsCurrency0 = _pools[key.toId()].coinIsCurrency0;

            // ONE position, the whole usable range. Until v1.6.12 this placed
            // two — the unsold coin above the clearing tick and the net pot
            // below it — and the two are the same thing. The tranche is HALF the
            // holding, so the coin left over equals the coin sold, and at the
            // clearing price `p* = pot_net / T_sold` the two one-sided
            // liquidities are `L_bid = pot_net/sqrt(p*)` and
            // `L_ask = T_rem*sqrt(p*)`, which are both `sqrt(T_sold * pot_net)`.
            // Two adjacent ranges carrying equal liquidity are, to the venue,
            // indistinguishable from one range spanning both — the pool is a
            // plain constant-product pool with reserves `(T_rem, pot_net)`.
            //
            // One position is not merely equivalent, it is CORRECT where two
            // were not: a position's range is the only handle on it, the hook
            // records one `(tickLower, tickUpper)` pair, and two positions could
            // never both be addressed by it. `collectLpFees` asked the venue for
            // `(0, 0)` and reverted for ever. Four units of the v1.6.11 round
            // found that across both families.
            int24 tickLower = _minUsableTick();
            int24 tickUpper = _maxUsableTick();
            int256 delta = _place(key, tickLower, tickUpper, liquidity);

            Currency coin = coinIsCurrency0 ? key.currency0 : key.currency1;
            Currency quote = coinIsCurrency0 ? key.currency1 : key.currency0;
            int128 coinOwed =
                coinIsCurrency0 ? BalanceDelta.wrap(delta).amount0() : BalanceDelta.wrap(delta).amount1();
            int128 quoteOwed =
                coinIsCurrency0 ? BalanceDelta.wrap(delta).amount1() : BalanceDelta.wrap(delta).amount0();

            // Unlike a creator launch, this one is expected to owe BOTH.
            _pay(coin, coinOwed);
            _pay(quote, quoteOwed);
            return "";
        } else if (action == Action.Buyback) {
            (, PoolKey memory key, uint256 amountIn) = abi.decode(data, (Action, PoolKey, uint256));
            PoolId poolId = key.toId();
            Pool storage p = _pools[poolId];

            (uint160 sqrtPriceX96,,,) = IFeastCLPoolManager(poolManager).getSlot0(poolId);
            // Spending the quote to receive the coin.
            bool zeroForOne = !p.coinIsCurrency0;
            // Round `v1.6.4` G3: derived from the tolerance in PRICE, not applied
            // to the square root of one. See `FeastMath.sqrtPriceLimit`.
            uint160 limit = FeastMath.sqrtPriceLimit(
                sqrtPriceX96, FeastConstants.MAX_SLIPPAGE_BPS, FeastConstants.BPS, !zeroForOne
            );

            int256 delta = IFeastCLPoolManager(poolManager).swap(
                key,
                IFeastCLPoolManager.SwapParams({
                    zeroForOne: zeroForOne,
                    amountSpecified: -int256(amountIn),
                    sqrtPriceLimitX96: limit
                }),
                ""
            );

            Currency quote = p.coinIsCurrency0 ? key.currency1 : key.currency0;
            Currency coin = p.coinIsCurrency0 ? key.currency0 : key.currency1;
            int128 quoteOwed = p.coinIsCurrency0 ? BalanceDelta.wrap(delta).amount1() : BalanceDelta.wrap(delta).amount0();
            int128 coinGained = p.coinIsCurrency0 ? BalanceDelta.wrap(delta).amount0() : BalanceDelta.wrap(delta).amount1();

            // Settle the quote by burning accrued claims rather than by moving
            // the token: nothing here can be paused, blacklisted or screened.
            uint256 spent;
            if (quoteOwed < 0) {
                spent = uint256(uint128(-quoteOwed));
                IFeastVault(vault).burn(address(this), quote, spent);
            }
            uint256 received = coinGained > 0 ? uint256(uint128(coinGained)) : 0;
            if (received != 0) IFeastVault(vault).take(coin, address(this), received);
            uint160 sqrtPriceX96After = _observePrice(poolId);
            // The quote's tip floor rides back with the purchase. This branch
            // already holds the quote; choosing it out of the key again at the
            // tip site measured 77 bytes more (v1.6.23).
            return abi.encode(received, spent, sqrtPriceX96After, _tipFloorOf[Currency.unwrap(quote)]);
        } else if (action == Action.CollectLpFees) {
            (, PoolKey memory key) = abi.decode(data, (Action, PoolKey));
            PoolId poolId = key.toId();
            Pool storage p = _pools[poolId];

            // Zero delta: collect what the range has earned, remove nothing.
            (, int256 feeDelta) = IFeastCLPoolManager(poolManager).modifyLiquidity(
                key,
                IFeastCLPoolManager.ModifyLiquidityParams({
                    tickLower: p.tickLower,
                    tickUpper: p.tickUpper,
                    liquidityDelta: 0,
                    salt: bytes32(0)
                }),
                ""
            );

            Currency quote = p.coinIsCurrency0 ? key.currency1 : key.currency0;
            Currency coin = p.coinIsCurrency0 ? key.currency0 : key.currency1;
            int128 quoteFees =
                p.coinIsCurrency0 ? BalanceDelta.wrap(feeDelta).amount1() : BalanceDelta.wrap(feeDelta).amount0();
            int128 coinFees =
                p.coinIsCurrency0 ? BalanceDelta.wrap(feeDelta).amount0() : BalanceDelta.wrap(feeDelta).amount1();

            uint256 quoteCollected;
            if (quoteFees > 0) {
                quoteCollected = uint256(uint128(quoteFees));
                // Held the same way swap fees are: as a claim, so nothing here
                // touches a quote token that might refuse to move.
                IFeastVault(vault).mint(address(this), quote, quoteCollected);
            }
            // The coin side is burned rather than banked: a coin-denominated
            // bucket is one nothing downstream can spend, and burning is the
            // one disposal that strands nothing (I14).
            //
            // **For real, since v1.6.24** (AstraSec I-8): it used to be taken
            // to `BURN_ADDRESS`, the one disposal here besides the seed's
            // remainder that an explorer counted as held supply. It is minted
            // to this contract as a claim and owed to `burnFilledCoin`, the
            // path that already burns the internal fill's coin for real — a
            // `take` and a `burn` here measured +95 bytes against a margin of
            // 139; this is +28. Same bound as the fill's: at most one
            // settlement per `burnFilledCoin`, the rest waiting.
            if (coinFees > 0) {
                IFeastVault(vault).mint(address(this), coin, uint256(uint128(coinFees)));
                p.filledCoinPending += uint256(uint128(coinFees));
            }
            return abi.encode(quoteCollected);
        } else {
            (, Currency currency, address to, uint256 amount) = abi.decode(data, (Action, Currency, address, uint256));
            // Burn the claim, then move the real token. Both inside the lock,
            // and deliberately nowhere near a swap: if the quote token refuses
            // this transfer, the call reverts and the ledger is untouched —
            // value stuck, never lost, and every other pool keeps trading.
            IFeastVault(vault).burn(address(this), currency, amount);
            IFeastVault(vault).take(currency, to, amount);
        }
        return "";
    }

    /// @dev Settle a debt to the vault by transferring the real token in.
    function _pay(Currency currency, int128 amount) private {
        if (amount >= 0) return;
        uint256 owed = uint256(uint128(-amount));
        IFeastVault(vault).sync(currency);
        SafeERC20.safeTransfer(IERC20(Currency.unwrap(currency)), vault, owed);
        IFeastVault(vault).settle();
    }

    // --- claims -----------------------------------------------------------

    /// @notice Pay the creator what their pool owes them, up to one settlement.
    /// @dev Round 12 (r12a M1): this used to say "everything". It pays at most
    ///      `MAX_SETTLEMENT` and leaves any remainder to claim again, so an
    ///      entitlement past the venue's signed delta drains in pieces instead
    ///      of reverting for ever (§6c B5).
    ///
    ///      I8. Callable by anyone, always paying the recorded creator: the
    ///      standard pull-payment shape, so a creator who loses their key
    ///      strands only their own bucket and cannot hold anyone else's up.
    function claimCreator(PoolKey calldata key) public nonReentrant {
        _requireUnfrozen();
        PoolId poolId = key.toId();
        Pool storage p = _pools[poolId];
        uint256 amount = creatorPending(poolId);
        if (amount > FeastConstants.MAX_SETTLEMENT) amount = FeastConstants.MAX_SETTLEMENT;
        if (amount == 0) return;
        p.creatorPaid += amount;
        emit CreatorPaid(poolId, p.creator, amount);
        _release(key, p, p.creator, amount);
    }

    /// @notice Pay a referrer the commissions they have earned on this pool.
    function claimReferrer(PoolKey calldata key, address referrer) public nonReentrant {
        _requireUnfrozen();
        PoolId poolId = key.toId();
        Pool storage p = _pools[poolId];
        uint256 amount = _referrerPending[poolId][referrer];
        if (amount > FeastConstants.MAX_SETTLEMENT) amount = FeastConstants.MAX_SETTLEMENT;
        if (amount == 0) return;
        // Debited by what is PAID, never zeroed. Round 11 (r11a H1 / r11b H1):
        // capping the payment while clearing the whole entry turned "the claim
        // reverts" into "the claim silently destroys the excess", which is
        // strictly worse — and this path is permissionless, so a stranger could
        // trigger someone else's loss.
        _referrerPending[poolId][referrer] -= amount;
        emit ReferrerPaid(poolId, referrer, amount);
        _release(key, p, referrer, amount);
    }

    /// @notice What `account` may claim from this pool right now, in the pool's
    ///         quote token. Creators and referrers both.
    /// @dev Named for the app's interface. A creator and a referrer can be the
    ///      same address, and then both are owed and both are returned here.
    function claimable(PoolKey calldata key, address account) external view returns (uint256) {
        PoolId poolId = key.toId();
        uint256 amount = _referrerPending[poolId][account];
        if (_pools[poolId].creator == account) amount += creatorPending(poolId);
        return amount;
    }

    /// @notice Pay `account` what this pool owes it, in the quote token. Each
    ///         creator/referrer component is paid up to one settlement, so a
    ///         combined claim may make two.
    /// @dev Round 13 (L1, both lenses): the previous notice said "up to one
    ///      settlement", which is true of `_claimTo` — where the two components
    ///      share a single budget — and false here, because this wrapper calls
    ///      `claimCreator` and `claimReferrer` in turn and each opens its own
    ///      bounded payout. `min(C, M) + min(R, M)` in one transaction. That
    ///      breaches no venue limit and loses nothing; the notice was simply
    ///      wrong.
    ///
    ///      The floor. It needs no route, no oracle and no counterparty, so
    ///      however the market around a quote token changes the money stays
    ///      reachable — but "reachable" is not "always immediately payable": a
    ///      quote token that freezes makes this revert until it unfreezes, with
    ///      the entitlement intact, and an entitlement past one settlement is
    ///      paid in pieces. `claimAsBnb` is the convenience on top; this is the
    ///      guarantee underneath.
    ///
    ///      **Not `nonReentrant` since v1.6.28** (AstraSec's suggestion of 7
    ///      Oct): it pays nothing itself. The two functions it calls hold the
    ///      flag while they pay and clear it on the way out; were this guarded
    ///      as well, the first of them would refuse itself.
    function claim(PoolKey calldata key, address account) public {
        _requireUnfrozen();
        PoolId poolId = key.toId();
        if (_pools[poolId].creator == account) claimCreator(key);
        if (_referrerPending[poolId][account] != 0) claimReferrer(key, account);
    }

    /// @notice Claim, then convert the proceeds to the chain's own asset along a
    ///         caller-supplied route, delivering at least `minOut` of it.
    /// @dev One call, and it either does both or does neither. If the route
    ///      cannot be priced the whole thing reverts and the claim is still
    ///      there to be taken as the quote token instead — which is why the
    ///      plain `claim` above has to exist.
    ///
    ///      **`minOut` is the claimant's bound on what the conversion delivers**
    ///      (v1.6.24, AstraSec M-1), checked by the converter after its own
    ///      route floor. Without it a sandwich that parked each hop's spot at
    ///      the edge of its admitted band was inside every check the converter
    ///      makes — they are all anchored to the prices as found — and the
    ///      claimant had no parameter with which to refuse it. Zero leaves the
    ///      converter's own protection exactly as it was; an app should pass a
    ///      quote taken before signing, less the tolerance its user chose.
    ///
    ///      **A pool quoted in wrapped native needs no route, and `route` and
    ///      `minOut` are both ignored for it** (v1.6.7; `minOut` since v1.6.24):
    ///      the claim is already in the asset this function converts to, so it
    ///      is paid as-is and there is no price for anyone to move. A claimant
    ///      owed nothing gets zero back the same way, with nothing converted.
    ///      Holding those two paths to `minOut` as well measured +83 bytes the
    ///      hook does not have; neither can lose a claimant anything to a price.
    function claimAsBnb(PoolKey calldata key, address account, FeastConverter.Hop[] calldata route, uint256 minOut)
        external
        nonReentrant
        returns (uint256 out)
    {
        _requireUnfrozen();
        // The plain `claim` is callable by anyone, because paying somebody what
        // they are owed in the token it accrued in needs no judgement. Choosing
        // the path it takes to another token does: round 1 constructed a route
        // that passed every per-hop check and still consumed forty percent of a
        // claim in pool fees. So this one is the claimant's own call.
        if (msg.sender != account) revert RouteIsTheClaimantsToChoose(account);
        PoolId poolId = key.toId();
        Pool storage p = _pools[poolId];
        Currency quote = p.coinIsCurrency0 ? key.currency1 : key.currency0;

        // v1.6.7 (the v1.6.6 pack, BOTH families): a pool quoted in wrapped
        // native is already paid in the asset this function converts TO, and the
        // converter's accepted route set for that input is empty — an empty
        // route is refused, every route must end in wrapped native, and any hop
        // whose output is the input token is refused, so no route exists. The
        // platform coin's own pool is quoted in wrapped native, which put the
        // coin all of this pays out on the one quote this entry point could not
        // serve. Nothing was stranded (plain `claim` pays the same token), but
        // the documented path reverted.
        //
        // So the claim is simply paid, in the token it already is, and the
        // converter is not asked a question with no answer. The claimant still
        // chooses — they called this — and `out` still reports what arrived.
        // `_claimTo` returns exactly what it released, which is a better answer
        // than a balance delta: it is the number the ledger was debited by.
        if (Currency.unwrap(quote) == converter.wrappedNative()) return _claimTo(key, account, account);

        uint256 before_ = IERC20(Currency.unwrap(quote)).balanceOf(address(this));
        _claimTo(key, account, address(this));
        uint256 amount = IERC20(Currency.unwrap(quote)).balanceOf(address(this)) - before_;
        if (amount == 0) return 0;

        SafeERC20.forceApprove(IERC20(Currency.unwrap(quote)), address(converter), amount);
        out = converter.convert(Currency.unwrap(quote), amount, route, account, minOut);
    }

    /// @dev Claim on behalf of `account` but deliver somewhere else, so the
    ///      conversion has something to spend.
    function _claimTo(PoolKey calldata key, address account, address to) private returns (uint256 amount) {
        PoolId poolId = key.toId();
        Pool storage p = _pools[poolId];

        // Bounded by what the venue can settle in one signed delta, and the
        // ledger is debited only by what is actually paid. Round 10 (r10a H1):
        // paying the WHOLE entitlement in one settlement meant a ledger that
        // grew past that limit reverted every claim afterwards, for ever, with
        // no smaller withdrawal available anywhere.
        uint256 room = FeastConstants.MAX_SETTLEMENT;
        if (p.creator == account) {
            uint256 owed = creatorPending(poolId);
            if (owed > room) owed = room;
            if (owed != 0) {
                p.creatorPaid += owed;
                amount += owed;
                room -= owed;
                emit CreatorPaid(poolId, account, owed);
            }
        }
        uint256 commission = _referrerPending[poolId][account];
        if (commission > room) commission = room;
        if (commission != 0) {
            _referrerPending[poolId][account] -= commission;
            amount += commission;
            emit ReferrerPaid(poolId, account, commission);
        }
        if (amount != 0) _release(key, p, to, amount);
    }

    function _release(PoolKey calldata key, Pool storage p, address to, uint256 amount) private {
        Currency quote = p.coinIsCurrency0 ? key.currency1 : key.currency0;
        IFeastVault(vault).lock(abi.encode(Action.Payout, quote, to, amount));
    }

    // --- the platform's share ----------------------------------------------

    /// @notice Send the platform's accrued share of this pool to the platform
    ///         sink, as the asset it accrued in. Callable by anyone.
    /// @dev The whole of v1.6's answer to "the platform 20% has no spend path"
    ///      (v1's B3). No route and no conversion: the asset moves as-is to the
    ///      one sink the genesis call named, which is what keeps B3's H1 — a
    ///      protocol-funded route an attacker chooses — from arising at all.
    ///
    ///      A settlement site, so it carries the bounded-settlement rules from its
    ///      first line (§6c B5): at most `MAX_SETTLEMENT` per call, the bucket
    ///      debited by exactly what is paid, the remainder left to leave next
    ///      time. A frozen quote token makes it revert with the entitlement
    ///      intact, exactly as a claim does.
    ///
    ///      Since v1.6.22 genesis refuses a sink with no code, and asks it every
    ///      question it asks any recipient, so on the ceremony's own path the
    ///      sink here always has code and always is the sink. This refusal stays
    ///      as defence in depth: a sink that has no code, or is not the sink,
    ///      is paid nothing, and the share simply stays here, owned.
    function releasePlatformFees(PoolKey calldata key) external nonReentrant {
        _requireUnfrozen();
        address sink = IFeastPlatformSinkSource(factory).platformSink();
        if (sink.code.length == 0 || !_isThePlatformSink(sink)) revert PlatformSinkNotBound(sink);

        PoolId poolId = key.toId();
        Pool storage p = _pools[poolId];
        uint256 amount = platformPending(poolId);
        if (amount > FeastConstants.MAX_SETTLEMENT) amount = FeastConstants.MAX_SETTLEMENT;
        if (amount == 0) return;
        p.platformUsed += amount;
        emit PlatformFeesReleased(poolId, sink, amount);
        _release(key, p, sink, amount);
    }

    /// @dev Round 2 (M1): genesis could not question a sink that did not exist
    ///      yet, so the exit does — the sink must report the sink's role for this
    ///      platform coin, or nothing is paid. (Genesis questions it too since
    ///      v1.6.22; this stays, and costs the hook no byte it did not have.)
    function _isThePlatformSink(address sink) private view returns (bool) {
        try IFeastGenesisRecipient(sink).genesisRole() returns (bytes32 role) {
            if (role != FeastGenesis.ROLE_PLATFORM_SINK) return false;
        } catch {
            return false;
        }
        try IFeastGenesisRecipient(sink).platformCoin() returns (address coin) {
            return coin == IFeastPlatformSinkSource(factory).platformCoin();
        } catch {
            return false;
        }
    }

    // --- the buy-back button ---------------------------------------------

    /// @notice Spend the coin's accrued buy-and-burn bucket buying the coin in
    ///         its own pool, and burn what it buys. Callable by anyone.
    ///
    /// @dev Two properties fall out of the venue's design and both are worth
    ///      stating, because neither needed any code:
    ///
    ///      The venue does not call a hook's callbacks when the hook is itself
    ///      the swapper. So this swap pays no feast fee and trips no feast cap,
    ///      with no re-entrancy flag and no special case.
    ///
    ///      The quote owed for the swap is settled by *burning claims* rather
    ///      than by transferring the token. A quote token that is paused,
    ///      blacklisting or sanctioning therefore cannot stop a coin buying
    ///      itself back — the value never leaves the vault's internal ledger.
    ///
    ///      The bound is the same shape as the conversion route's: refuse to
    ///      trade when spot has been pushed away from the time-weighted price,
    ///      and carry a price limit so this swap cannot walk the price itself.
    ///      Expressed in ticks for the same reason — the arithmetic that would
    ///      turn a tick into a token amount is GPL-licensed.
    function buyBackAndBurn(PoolKey calldata key, uint256 amountIn) external nonReentrant {
        _requireUnfrozen();
        PoolId poolId = key.toId();
        Pool storage p = _pools[poolId];

        // The gate, again. The venue skips this hook's callbacks when the hook
        // is the swapper, so the check in `beforeSwap` never sees this swap;
        // without this line a gated pool's buy-back could trade before the
        // pool opens (round 1, M1). Nobody but the opener trades a gated pool.
        if (block.timestamp < p.openAt) revert PoolNotOpenYet(p.openAt);

        uint256 pending = selfBurnPending(poolId);
        if (pending == 0 || amountIn == 0) revert NothingToBuyBackWith();

        // Spend at most what the allowance permits. A request above it is
        // CLAMPED rather than refused: the caller asks for what they want and
        // receives what the allowance and the pool between them permit. There
        // is no interval to be too soon for and no floor to be too small for,
        // because nothing is occupied by pressing.
        uint256 allowanceScaled = _accruedScaled(p, pending);
        uint256 allowance = allowanceScaled / FeastConstants.ALLOWANCE_SCALE;
        if (allowance == 0) revert NothingToBuyBackWith();
        uint256 offered = amountIn < allowance ? amountIn : allowance;

        _requireSpotNearAverage(poolId);

        bytes memory result = IFeastVault(vault).lock(abi.encode(Action.Buyback, key, offered));
        (uint256 coinOut, uint256 quoteSpent, uint160 sqrtPriceX96After, uint256 floor) =
            abi.decode(result, (uint256, uint256, uint160, uint256));

        // A press that buys nothing reverts, so it costs its sender gas and the
        // protocol nothing at all — no allowance consumed, no bucket debited,
        // no state to occupy.
        if (coinOut == 0) revert BoughtNothing();

        // Everything below is measured from what the venue actually took. Round
        // 6 (r6a H1 / r6b H1) is the reason this is stated so plainly: the
        // withdrawn predicate checked the REQUEST and then settled the realised
        // amount, so a request that cleared the floor and filled as dust still
        // consumed the hour. Here the realised spend is the only quantity that
        // moves anything.
        p.selfBurnUsed += quoteSpent;
        p.allowanceRemaining = allowanceScaled - quoteSpent * FeastConstants.ALLOWANCE_SCALE;
        p.allowanceUpdatedAt = uint64(block.timestamp);

        // The tip is a fraction of what the press actually bought, at a rate the
        // BUCKET sets (`FeastConstants.TIP_BPS` has the rule and why): 0.25%,
        // lifted to what the quote's floor would be on the largest press the
        // bucket allows, and never above 10%. The rate does not depend on the
        // press, so the tip has no flat component per press: a dust press earns
        // dust and splitting a press earns nothing (R6, v1.6.23). Paid out of
        // the proceeds, so a press can never cost more than it created, and at
        // least 90% of every print is burned.
        uint256 tip = coinOut * FeastConstants.TIP_BPS / FeastConstants.BPS;
        if (floor != 0) {
            // Both constants divide `BPS`, so both quotients are exact: `largest`
            // is `ALLOWANCE_CAP_BPS` of the bucket, and the floor is at most
            // `TIP_CEILING_BPS` of it exactly when the first comparison holds,
            // which also keeps `largest` above zero. `coinOut` is below 2**127
            // (an int128 delta) and the constructor holds `floor` to 128 bits,
            // so the product fits a word.
            uint256 largest = pending / (FeastConstants.BPS / FeastConstants.ALLOWANCE_CAP_BPS);
            uint256 floored = largest / (FeastConstants.BPS / FeastConstants.TIP_CEILING_BPS) >= floor
                ? coinOut * floor / largest
                : coinOut / (FeastConstants.BPS / FeastConstants.TIP_CEILING_BPS);
            if (floored > tip) tip = floored;
        }
        uint256 burned = coinOut - tip;
        if (tip != 0) SafeERC20.safeTransfer(IERC20(p.coin), msg.sender, tip);
        if (burned != 0) IFeastBurnable(p.coin).burn(burned);

        emit BoughtBackAndBurned(poolId, quoteSpent, burned, tip);
        // Round 2 (L1): the button's swap is a trade in the pool like any other,
        // bought by the hook itself and paying no feast fee.
        _emitTrade(
            key, p, true, int256(coinOut), -int256(quoteSpent), sqrtPriceX96After, 0, address(this)
        );
    }

    /// @notice What this pool's buy-back button may spend right now.
    function spendingAllowance(PoolId poolId) public view returns (uint256) {
        return _spendingAllowance(_pools[poolId], selfBurnPending(poolId));
    }

    /// @dev The leaky bucket. Allowance accrues linearly at
    ///      `ALLOWANCE_BPS_PER_HOUR` of the accrued bucket per
    ///      `ALLOWANCE_WINDOW`, and is capped at one window's worth — so the
    ///      most that can leave in any hour is exactly what the withdrawn
    ///      per-hour ceiling allowed. Spending is continuous rather than
    ///      binary, which is what removes the need for a progress predicate:
    ///      a dust fill deducts dust and a full fill deducts the full amount,
    ///      so there is nothing to jam. Stranding is greatly reduced but NOT
    ///      abolished (round 10 M1 — this comment used to say it was): if the
    ///      permitted press is small enough that the venue returns zero coin,
    ///      the press reverts and the bucket waits until it grows.
    /// @dev Settle accrual at the bucket's CURRENT size, so a later change to
    ///      that size cannot rewrite what has already accrued.
    ///
    ///      This is also what starts a pool's allowance clock, and why nothing
    ///      needs to start it at registration: the first fee ever banked
    ///      settles a bucket that is still zero, so the allowance begins at
    ///      zero and accrues from the moment there is anything to accrue
    ///      against (round 7 — a pool must not begin with a burst).
    function _checkpointAllowance(Pool storage p) private {
        p.allowanceRemaining = _accruedScaled(p, p.selfBurnEarned - p.selfBurnUsed);
        p.allowanceUpdatedAt = uint64(block.timestamp);
    }

    /// @dev The allowance in SCALED units, which is how it is stored.
    ///
    ///      Round 8 found the two defects this scaling exists to settle at
    ///      once. Storing it in whole quote units meant a checkpoint floored
    ///      the accrual and reset the clock, so a stream of one-unit banks held
    ///      the allowance at zero for an hour, a rounded-away second at a time
    ///      (L2). Carrying the lost fraction as *time* instead fixed that but
    ///      let the residue accrue at a later, larger rate — a small retroactive
    ///      credit, which is the very thing M1 is about. Carrying it in the
    ///      accumulator settles both: nothing is discarded, and the clock always
    ///      advances to now, so no time is ever re-priced.
    function _accruedScaled(Pool storage p, uint256 pending) private view returns (uint256) {
        (uint256 cap, uint256 perWindow) = _allowanceShape(pending);
        if (cap == 0) return 0;
        uint256 elapsed = block.timestamp - uint256(p.allowanceUpdatedAt);
        // v1.6.4 G1 sweep: `perWindow` is in scaled units (x 1e18), so this is the
        // largest product in the allowance path.
        uint256 accrued = elapsed >= FeastConstants.ALLOWANCE_WINDOW
            ? perWindow
            : Math.mulDiv(perWindow, elapsed, FeastConstants.ALLOWANCE_WINDOW);
        uint256 available = p.allowanceRemaining + accrued;
        return available > cap ? cap : available;
    }

    /// @dev The cap and the per-window rate for a bucket of this size, both in
    ///      scaled units. One definition, used by the checkpoint and by the
    ///      reader, so the two cannot drift — and so the dust exemption applies
    ///      identically to both.
    function _allowanceShape(uint256 pending) private pure returns (uint256 cap, uint256 perWindow) {
        if (pending == 0) return (0, 0);
        // v1.6.4 G1 sweep, and a reordering rather than a rewrite. `scaled =
        // pending * ALLOWANCE_SCALE` is a bare multiplication, not an `x * y / z`,
        // so it sits outside the sweep's stated shape — but it is the FIRST thing
        // in this path that can panic, and rewriting the two divisions below while
        // leaving it would be the half-measure this pass exists to stop making.
        //
        // `scaled` is wanted in two places: as the numerator of the cap and the
        // rate, and as the pair returned on the dust branch. On the dust branch
        // `pending <= MIN_RATIONED_BUCKET`, a constant, so forming it THERE is
        // bounded by `1e22`. So: take the cap from `pending` directly, decide the
        // dust question, and form `scaled` only inside the branch that bounds it.
        // No published number moves — both spellings floor a single quotient.
        cap = Math.mulDiv(
            pending, uint256(FeastConstants.ALLOWANCE_SCALE) * FeastConstants.ALLOWANCE_CAP_BPS, FeastConstants.BPS
        );
        // A bucket too small to ration is not rationed (round 5 M1): its
        // proportional share rounds to something no pool will fill, and a print
        // that size cannot be sandwiched by anybody. The RATE is lifted too, or
        // a few raw units would take days to become spendable.
        if (cap == 0 || pending <= FeastConstants.MIN_RATIONED_BUCKET) {
            uint256 scaled = pending * FeastConstants.ALLOWANCE_SCALE;
            return (scaled, scaled);
        }
        perWindow = Math.mulDiv(
            pending, uint256(FeastConstants.ALLOWANCE_SCALE) * FeastConstants.ALLOWANCE_BPS_PER_HOUR, FeastConstants.BPS
        );
    }

    function _spendingAllowance(Pool storage p, uint256 pending) internal view returns (uint256) {
        return _accruedScaled(p, pending) / FeastConstants.ALLOWANCE_SCALE;
    }

    /// @notice Collect the locked position's trading fees into the same four
    ///         buckets the swap fee goes to. Callable by anyone.
    ///
    /// @dev Ruled in Q8 and, round 1 found, never built — so the position that
    ///      can never be withdrawn was also earning fees that could never be
    ///      reached. A liquidity change of exactly zero collects what the
    ///      position has earned without touching its principal, which is the
    ///      one liquidity call that is safe to expose to everybody: it cannot
    ///      remove anything, because there is nothing to remove.
    ///
    ///      The proceeds are split by the same rule as a swap fee, so one
    ///      sentence explains every unit of protocol income. Only the quote
    ///      side is banked: the coin side would be a bucket denominated in the
    ///      coin, which nothing downstream knows how to spend. It is owed to
    ///      `burnFilledCoin` instead and burned for real (v1.6.24, AstraSec I-8;
    ///      until then it was sent to `BURN_ADDRESS`).
    function collectLpFees(PoolKey calldata key) external nonReentrant {
        _requireUnfrozen();
        PoolId poolId = key.toId();
        Pool storage p = _pools[poolId];
        if (!p.seeded) revert NothingSeeded();

        bytes memory result = IFeastVault(vault).lock(abi.encode(Action.CollectLpFees, key));
        uint256 collected = abi.decode(result, (uint256));
        // `attributable: false`. LP fees are earned continuously and the venue
        // reports only a total at collection, so there is no epoch to tag them
        // with. Tagging them with the epoch of *collection* is what round 2
        // found: anyone could wait for a day on which they were the only fee
        // payer and collect, taking a share funded by everybody else.
        //
        // Rather than invent an attribution, the platform share of LP fees is
        // withdrawn from the pot entirely and buys and burns instead. A stated
        // boundary, not a guess: the pot only ever contains money whose payers
        // are known.
        if (collected != 0) _bank(key, p, collected, address(0), false);
        emit LpFeesCollected(poolId, collected);
    }


    /// @dev Refuse to trade into a price somebody has just moved — **or into an
    ///      average that a freeze, rather than the market, brought onto it.**
    ///
    ///      `MAX_TICK_DEVIATION` asks whether spot has run away from the recent
    ///      average, and the remedy for a `yes` is to wait and let trading bring
    ///      them back together. A freeze writes no observations, so the average
    ///      drifts onto the pinned spot with no trade happening at all, and a
    ///      price this bound REFUSED becomes one it accepts while the corrective
    ///      trades are prohibited. The protocol then buys into a price nobody
    ///      could move, out of its own bucket.
    ///
    ///      `FeastEmissions` was given exactly this rule at v1.6.15 and these
    ///      two sites were not — the fourth time in this lane a fix went to the
    ///      site a lens named rather than to the shape (`P16-claude` LOW). The
    ///      three now share one condition, and `audit/freeze-clocks.allow`
    ///      enumerates every read of an average in `src/` so a fourth site
    ///      cannot be added without a decision.
    ///
    ///      `unfrozenAtFor`, not `allUnfrozenAt`: an average is built from THIS
    ///      pool's swaps, and a freeze scoped to this pool stops exactly those.
    function _requireSpotNearAverage(PoolId poolId) internal view {
        (, int24 spotTick,,) = IFeastCLPoolManager(poolManager).getSlot0(poolId);
        if (!_averageHasHadOpenTime()) revert SpotTooFarFromAverage(spotTick, spotTick);
        int24 averageTick = oracle.twapTick(poolId);
        int24 deviation = spotTick > averageTick ? spotTick - averageTick : averageTick - spotTick;
        if (deviation > FeastConstants.MAX_TICK_DEVIATION) revert SpotTooFarFromAverage(spotTick, averageTick);
    }

    /// @dev Has a whole averaging window of OPEN time passed in this pool since
    ///      trading in it last resumed? Until it has, the average is a reading
    ///      of a freeze and not of a market. See `_requireSpotNearAverage`.
    ///
    ///      The guardian read is WARM, and now it is also the ONLY one:
    ///      `_beforeSwap` asks `isFrozenAll` on every trade, and `frozenUntil`,
    ///      `frozenFrom` and `allUnfrozenTotal` share one slot in
    ///      `FeastGuardian`, so this second question reads a slot the first
    ///      already paid for. v1.6.16 needed a per-pool instant here, which was
    ///      a cold mapping read; v1.6.17 removed the scope that made it
    ///      necessary, and the cold read went with it.
    function _averageHasHadOpenTime() private view returns (bool) {
        uint64 resumed = guardian.allUnfrozenAt();
        // Zero means no freeze has ever ended, so there is nothing to wait out.
        // Without this the condition is a claim about the age of the CHAIN
        // rather than about open time — true by accident on a live chain and
        // false on a fresh one.
        return resumed == 0 || block.timestamp >= uint256(resumed) + FeastConstants.TWAP_WINDOW;
    }

    /// @dev The whole of feast's accrual. `mint` credits this contract an
    ///      ERC-6909 claim inside the swapper's own lock and debits its delta by
    ///      the same amount; the delta returned from the callback settles that
    ///      debt. No token contract is called, which is exactly the point: a
    ///      paused or screening quote token has nothing to refuse here.
    function _accrue(PoolKey calldata key, Pool storage p, uint256 amount, address referrer) private {
        Currency quote = p.coinIsCurrency0 ? key.currency1 : key.currency0;
        IFeastVault(vault).mint(address(this), quote, amount);
        _bank(key, p, amount, referrer, true);

        // Who paid, whose coin earned it, who brought it — for the first year's
        // emissions and the genesis partners. The venue hands a hook the
        // router's address rather than the trader's, so the payer is
        // `tx.origin`: the same compromise the purchase cap makes, documented in
        // both places. A burn-address creator has no creator track (its share
        // burns), and a trade before the gate lifts is the launch window's own
        // settlement, not anybody's trade, so it is recorded nowhere.
        if (block.timestamp >= p.openAt) {
            ledger.record(
                Currency.unwrap(quote),
                tx.origin,
                p.creator == FeastConstants.BURN_ADDRESS ? address(0) : p.creator,
                referrer,
                amount
            );
        }
    }

    /// @dev Split an amount of quote across the four buckets, once. The claim
    ///      is assumed already minted; this is only the accounting.
    function _bank(PoolKey calldata key, Pool storage p, uint256 amount, address referrer, bool attributable)
        private
    {
        p.accruedQuote += amount;

        PoolId poolId = key.toId();
        emit FeeAccrued(poolId, amount);

        // The split is computed and banked HERE, once, for this fee — not
        // derived later from a running total. Every share is a monotone
        // running total and the creator takes the remainder OF THIS ACCRUAL, so
        // the four always sum to exactly `amount` and none of them can shrink.
        uint256 selfBurn = amount * p.selfBurnBps / FeastConstants.BPS;
        uint256 platform = amount * FeastConstants.PLATFORM_BPS / FeastConstants.BPS;

        uint256 commission;
        if (referrer != address(0) && p.referrerBps != 0) {
            commission = amount * p.referrerBps / FeastConstants.BPS;
            if (commission != 0) {
                p.referrerEarned += commission;
                _referrerPending[poolId][referrer] += commission;
                emit ReferralCredited(poolId, referrer, commission);
            }
        }

        uint256 creator = amount - selfBurn - platform - commission;
        // I14. A coin whose creator is the burn address — which is how the
        // platform coin is launched — would otherwise bank a share nobody can
        // ever claim. It buys and burns instead, which is what makes "its fees
        // burn" true rather than aspirational.
        if (p.creator == FeastConstants.BURN_ADDRESS) {
            selfBurn += creator;
            creator = 0;
        }

        // LP fees have no discoverable earning epoch and the venue reports only
        // a total, so rather than invent an attribution their platform share is
        // withdrawn from the pot and buys and burns instead. Decided HERE,
        // before the checkpoint, because it is part of the self-burn credit.
        uint256 redirected = (platform != 0 && !attributable) ? platform : 0;

        // Checkpoint BEFORE the bucket moves. Round 7's second defect: accrual
        // is a rate on the CURRENT bucket, so raising the bucket without
        // settling first credits new principal for time in which it did not
        // exist. Round 8 (M1, both lenses) found this decided on `selfBurn`
        // alone while the redirected LP share credited the same bucket a few
        // lines below — so a pool with `selfBurnBps = 0` grew its bucket with
        // no checkpoint at all. The test is the COMPLETE credit.
        uint256 selfBurnCredit = selfBurn + redirected;
        if (selfBurnCredit != 0) _checkpointAllowance(p);

        p.selfBurnEarned += selfBurnCredit;
        p.platformEarned += platform - redirected;
        p.creatorEarned += creator;
    }

    /// @dev What a spend actually cost, given the balance before and after and
    ///      the amount it was allowed to use. One implementation, called from
    ///      both buttons — round 2's finding was that the coin button
    ///      reconciled by hand and the platform button did not reconcile at all,
    ///      so a third button could be added without it.
    /// @dev Record the tick a swap LEFT the pool at. One implementation, called
    ///      from every site that moves a price — the ordinary swap path and both
    ///      buttons.
    ///
    ///      The oracle attributes each recorded tick forward, to the interval
    ///      until the next write, so what it needs is the price that prevails
    ///      from now on. Round 1 fixed the tick's value here; round 2 found the
    ///      coverage still wrong, because the venue does not call a hook's
    ///      callbacks when the hook is itself the swapper — so the two button
    ///      swaps moved the price and told the oracle nothing, and the next
    ///      reader saw an average that skipped the move.
    function _observePrice(PoolId poolId) private returns (uint160 sqrtPriceX96After) {
        int24 tickAfter;
        (sqrtPriceX96After, tickAfter,,) = IFeastCLPoolManager(poolManager).getSlot0(poolId);
        oracle.write(poolId, tickAfter);
    }

    /// @dev The one `Trade` event (owner ruling Q24). The amounts are the
    ///      trader's: the venue's delta for the pool, less what this hook took
    ///      or gave on top of it. `fee` is what this swap paid, on whichever leg
    ///      it was charged. Emission only — no storage — and never for a gated
    ///      swap, which is the launch window's own settlement and not a trade.
    function _emitTrade(
        PoolKey calldata key,
        Pool storage p,
        bool buyingCoin,
        int256 traderCoin,
        int256 traderQuote,
        uint160 sqrtPriceX96After,
        uint256 fee,
        address payer
    ) private {
        if (block.timestamp < p.openAt) return;
        Currency quote = p.coinIsCurrency0 ? key.currency1 : key.currency0;
        emit Trade(
            p.coin,
            Currency.unwrap(quote),
            buyingCoin,
            traderCoin < 0 ? uint256(-traderCoin) : uint256(traderCoin),
            traderQuote < 0 ? uint256(-traderQuote) : uint256(traderQuote),
            sqrtPriceX96After,
            payer,
            fee
        );
    }
}
