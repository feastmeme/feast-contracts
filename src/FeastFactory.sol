// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {TickMath} from "uniswap-v4-core/src/libraries/TickMath.sol";

import {FeastConstants} from "./FeastConstants.sol";
import {FeastGenesis} from "./FeastGenesis.sol";
import {FeastHook} from "./FeastHook.sol";
import {IFeastGenesisRecipient} from "./IFeastGenesisRecipient.sol";
import {IFeastGuardian} from "./IFeastGuardian.sol";
import {FeastPlatformTokenDeployer} from "./FeastPlatformTokenDeployer.sol";
import {FeastToken} from "./FeastToken.sol";
import {FeastVesting} from "./FeastVesting.sol";
import {BalanceDelta} from "./venue/BalanceDelta.sol";
import {Currency} from "./venue/Currency.sol";
import {IFeastVault} from "./venue/IFeastVault.sol";
import {IFeastCLPoolManager} from "./venue/IFeastCLPoolManager.sol";
import {PoolId, PoolIdLibrary} from "./venue/PoolId.sol";
import {PoolKey} from "./venue/PoolKey.sol";

/// @notice What genesis asks the launch window before it records an opening:
///         can the position that tick implies actually be placed?
interface IFeastWindowOpening {
    function openingLiquidityFor(uint256 coinHeld, int24 startTick) external view returns (uint128);
}

/// @notice The instant the launch window closes, asked at genesis.
interface IFeastWindowClose {
    function endsAt() external view returns (uint64);
}

/// @notice Every question genesis may put to a contract it names, in one
///         vocabulary. Which recipient is asked which is `_questions`.
/// @dev Declared here rather than importing the recipients, so the factory keeps
///      depending on the QUESTION and not on the implementation — exactly as
///      `IFeastGenesisRecipient` does for the role. The return types are the
///      recipients' own; genesis reads every answer as one word (a key as the
///      hash of its six), so only the selectors matter to it, and
///      `test/FeastGenesisTrust.t.sol` pins each one against the contract that
///      answers it.
interface IFeastGenesisQuestions {
    // the launch window
    function poolKey() external view returns (PoolKey memory);
    function factory() external view returns (address);
    function hook() external view returns (address);
    function poolManager() external view returns (address);
    function wrappedNative() external view returns (address);
    // the team's vesting wallet
    function start() external view returns (uint256);
    function duration() external view returns (uint256);
    // emissions
    function platformPoolId() external view returns (PoolId);
    function ledger() external view returns (address);
    function budget() external view returns (uint256);
    // the grants
    function emissions() external view returns (address);
    function grant() external view returns (uint256);
    // the sink
    function opensAt() external view returns (uint64);
    // every one of them
    function guardian() external view returns (address);
}

/// @title The factory
/// @notice Mints a coin, pairs it, seeds liquidity that can never be removed,
///         and starts the creator's vesting — in one transaction.
///
/// @dev The sequence is taken from a twice-audited reference. What is deleted
///      is everything that made that reference governable:
///
///      - No registries. The reference gates creation on owner-mutable maps of
///        approved hooks, lockers and MEV modules, plus a deprecation switch.
///        Feast binds its three collaborators as `immutable` constructor
///        arguments and deletes all four.
///      - No extension bus. The reference has a generic plugin system with a
///        per-extension share cap. Feast has exactly one extension — vesting —
///        so it is inlined as one share, one transfer, one call.
///      - The pool key is built here rather than delegated to the hook, because
///        this venue's key has six fields and carries tick spacing inside
///        `parameters` rather than as a field of its own.
///
///      There is no owner, no pause, and no function that can change anything
///      about a coin after its creating transaction returns.
contract FeastFactory {
    using PoolIdLibrary for PoolKey;
    using SafeERC20 for IERC20;

    error PrebuyTooLarge(uint256 coinsOut, uint256 max);
    error PrebuyBelowMinimum(uint256 coinsOut, uint256 minCoinsOut);
    error PrebuyNeedsAQuoteAmount();
    error PrebuyNeedsTheCreator(address creator, address caller);
    error PrebuyVestingTooShort(uint64 vestingDuration, uint64 minimum);
    error NotTheVault();

    /// @dev The venue's own usable range, as `FeastLaunchWindow` declares it.
    uint160 internal constant MIN_SQRT_PRICE = 4_295_128_739;
    uint160 internal constant MAX_SQRT_PRICE = 1_461_446_703_485_210_103_287_273_052_203_988_822_378_723_970_342;
    error SupplyTooLarge(uint256 supply);
    error QuoteIsNotAToken();
    error CoinAndQuoteMustDiffer();
    error PoolTooShallow();
    error ZeroCreator();
    error NotGenesisKey();
    error GenesisAlreadyDone();
    error RecipientHasNoCode(address recipient);
    error SupplyNotInCustody(uint256 held);
    error RecipientNotAllowed(address recipient);
    error TeamVestingStartNotWindowClose(uint256 start, uint256 windowClose);
    error WindowPoolKeyMismatch(PoolId named, PoolId expected);
    error TeamVestingGuardianMismatch(address named, address expected);
    error SinkNotArmed(uint64 opensAt, uint256 windowClose);
    // v1.6.22: the rest of each recipient's set, one refusal per question, every
    // one of them `(what the recipient named, what genesis expected)`. See
    // `_questions` for which recipient is asked which.
    error WindowFactoryMismatch(address named, address expected);
    error WindowHookMismatch(address named, address expected);
    error WindowPoolManagerMismatch(address named, address expected);
    error WindowWrappedNativeMismatch(address named, address expected);
    error TeamVestingDurationMismatch(uint256 named, uint256 expected);
    error EmissionsGuardianMismatch(address named, address expected);
    error EmissionsHookMismatch(address named, address expected);
    error EmissionsPoolMismatch(PoolId named, PoolId expected);
    error EmissionsLedgerMismatch(address named, address expected);
    error EmissionsBudgetMismatch(uint256 named, uint256 expected);
    error GrantsGuardianMismatch(address named, address expected);
    error GrantsEmissionsMismatch(address named, address expected);
    error GrantsGrantMismatch(uint256 named, uint256 expected);
    error SinkGuardianMismatch(address named, address expected);
    error WindowCloseOutOfRange(uint256 windowClose, uint256 earliest, uint256 latest);
    error GateIsNotTheWindowsClose(uint64 given, uint64 derived);

    /// @notice The furthest ahead of the genesis transaction the launch
    ///         window's close may sit. The recipe's window opens about a day
    ///         after genesis and runs 24 hours, so this is generous by an order
    ///         of magnitude; it exists to refuse a window whose calendar is
    ///         nothing like the one the signing ceremony assumed, not to pin
    ///         the schedule.
    uint256 internal constant MAX_WINDOW_CLOSE_AHEAD = 30 days;

    event Genesis(
        address indexed coin,
        PoolId poolId,
        address window,
        uint64 openAt,
        address teamVesting,
        address emissions,
        address grants,
        address platformSink
    );

    /// @notice What the creator bought of their own coin at its creation.
    /// @dev One event and one view (`prebuyOf`), so the coin page can show it
    ///      from block one without an indexer. `vestingEnd == block.timestamp`
    ///      of the creating block means "sellable at any time".
    event CreatorPrebuy(address indexed coin, uint256 quoteIn, uint256 coinsOut, uint64 vestingEnd);

    event CoinCreated(
        address indexed coin,
        address indexed creator,
        address indexed quote,
        PoolId poolId,
        uint256 supply,
        uint16 selfBurnBps,
        uint16 referrerBps,
        bytes32 metadataHash
    );

    /// @notice Largest share of supply a creator may allocate to themselves.
    /// @dev A ceiling, not a default. Without one, "fair launch" would be a
    ///      claim the contract does not support; with it, the worst case is
    ///      visible from the source.
    /// @notice The most of a coin's supply a creator may hold from its
    ///         creation, measured in COINS RECEIVED rather than quote paid —
    ///         quote in is a price, coins out is a share, and a share is what
    ///         P6 promises. 20%, the ceiling the free allocation had, so the
    ///         maximum a creator can hold at block one does not change.
    uint16 public constant MAX_PREBUY_BPS_OF_SUPPLY = 2_000;

    /// @notice The shortest a pre-buy may vest: seven days, linear from the
    ///         creating transaction (v1.6.24, AstraSec I-5).
    /// @dev Until v1.6.24 a creator could pre-buy up to 20% of supply with a
    ///      `vestingDuration` of zero — "sellable at any time" — and sell it
    ///      into the first public buyers in the same block the pool opened.
    ///      Seven days is the launch form's own default and its shortest
    ///      non-zero choice (`feast-app`, `src/lib/chain/prebuy.ts`,
    ///      `PREBUY_UNLOCK_DAYS = [0, 7, 30, 90, 180, 365]`, default 7, "the lock
    ///      the coordinator's interim disclosure names"), so the floor removes
    ///      exactly the zero option and moves no other choice a creator is
    ///      offered. It binds only a pre-buy: a launch without one vests
    ///      nothing, and its `vestingDuration` is not read.
    uint64 public constant MIN_PREBUY_VESTING = 7 days;

    struct CreateParams {
        string name;
        string symbol;
        uint256 supply;
        address quote;
        address creator;
        uint16 selfBurnBps;
        uint16 referrerBps;
        /// @notice Quote the creator pays into the coin's own pool in this
        ///         transaction, buying their stake at the pool's own price like
        ///         anyone else. Zero is no pre-buy. The creator must have
        ///         approved this factory for it first.
        uint256 prebuyQuoteIn;
        /// @notice The creator's slippage bound: the pre-buy must return at
        ///         least this many coins or the whole `create` reverts.
        uint256 minCoinsOut;
        /// @notice How long the pre-bought coins vest, linearly. At least
        ///         `MIN_PREBUY_VESTING` when there is a pre-buy (v1.6.24; zero
        ///         used to be allowed and disclosed as "sellable at any time").
        ///         The coin page reads it from `prebuyOf`.
        uint64 vestingDuration;
        uint160 sqrtPriceX96;
        /// @notice The tick the pool opens at. The opening position runs from
        ///         here to the far edge of the usable range, on whichever side
        ///         the coin sorted to, so that it needs only the coin.
        int24 startTick;
        uint128 liquidity;
        bytes32 salt;
        /// @notice The 32-byte digest of the coin's metadata on IPFS (the
        ///         sha2-256 digest a CIDv0, or a CIDv1 over raw sha2-256,
        ///         carries). No default: zero is a coin without metadata, chosen.
        bytes32 metadataHash;
    }

    /// @notice What the one genesis call names. Everything here is a
    ///         deployment decision, taken once, by the genesis key.
    struct GenesisParams {
        /// @notice The platform coin pool's opener: the launch window, the only
        ///         address that may trade the pool before `openAt`.
        address window;
        uint64 openAt;
        address teamVesting;
        address emissions;
        address grants;
        /// @notice Where the platform share of every pool's fees may go, and
        ///         where the launch window pays the pot's 1% at its close. It
        ///         must exist, and be armed, BEFORE genesis — like every other
        ///         recipient, since v1.6.22 (see `genesis`).
        address platformSink;
        /// @notice The price the platform pool opens at IF nobody commits to the
        ///         launch window. The genesis key signs this and nothing else
        ///         about the opening: the tick is DERIVED from it here and the
        ///         liquidity is derived from the holding at settlement, so there
        ///         are no longer three numbers that can disagree with each other.
        uint160 sqrtPriceX96;
        /// @notice The platform coin's own metadata digest.
        bytes32 metadataHash;
    }

    struct Coin {
        address quote;
        address creator;
        PoolId poolId;
        uint256 supply;
        bytes32 metadataHash;
    }

    address public immutable poolManager;
    address public immutable vault;
    FeastHook public immutable hook;
    FeastVesting public immutable vesting;
    FeastPlatformTokenDeployer public immutable platformTokenDeployer;
    /// @notice The platform coin's quote: the chain's wrapped native asset.
    address public immutable wrappedNative;
    /// @notice The one address that may call `genesis`, once.
    address public immutable genesisKey;

    /// @notice Set by the genesis call and never again.
    bool public genesisDone;
    /// @notice The brake. On this contract it reaches `create` and nothing
    ///         else: genesis, the seeding paths and the pre-buy's lock callback
    ///         are untouched, because a freeze must never strand a launch window
    ///         that is already running. See `FeastGuardian`.
    IFeastGuardian public immutable guardian;

    address public platformCoin;
    address public platformSink;

    address[] internal _coins;
    mapping(address coin => Coin) internal _coinInfo;

    constructor(
        address poolManager_,
        address vault_,
        address hook_,
        address vesting_,
        address platformTokenDeployer_,
        address wrappedNative_,
        address genesisKey_
    ) {
        poolManager = poolManager_;
        vault = vault_;
        hook = FeastHook(hook_);
        vesting = FeastVesting(vesting_);
        platformTokenDeployer = FeastPlatformTokenDeployer(platformTokenDeployer_);
        wrappedNative = wrappedNative_;
        genesisKey = genesisKey_;
        // The factory reads the guardian the HOOK was built with rather than
        // taking its own: one address for the whole deployment, and one place
        // where a mismatch would be visible. The hook is deployed first and its
        // guardian is immutable, so this cannot drift.
        guardian = FeastHook(hook_).guardian();
    }

    // --- the one transaction ---------------------------------------------

    function create(CreateParams calldata p) external returns (address coin, PoolKey memory key) {
        // **Two brakes, two questions.** `stopCreation` is permanent and says
        // "this deployment must never launch another coin"; an `ALL` freeze is
        // temporary and says "nothing new while we look". They are not two
        // brakes on one door.
        //
        // The practical reason the freeze reaches here at all: a `create` with a
        // pre-buy walks into the frozen `beforeSwap` and reverts half way,
        // AFTER registering the pool and seeding it. Refusing at the door is the
        // honest behaviour (coordinator, 2026-09-20 16:1x). A per-pool freeze
        // does not reach here — there is no pool yet to name.
        if (guardian.creationStopped()) revert CreationStopped();
        if (guardian.isFrozenAll()) revert Frozen();

        // A slippage bound with nothing to spend is a caller who filled in one
        // field and not the other; it is refused rather than silently ignored.
        if (p.prebuyQuoteIn == 0 && p.minCoinsOut != 0) revert PrebuyNeedsAQuoteAmount();
        // The pre-buy pulls the quote from `p.creator`, not from the caller, and
        // `create` is permissionless with `p.creator` a free parameter. Without
        // this line the approval a creator must give this contract in order to
        // pre-buy their OWN coin is spendable by anybody, on a coin of the
        // stranger's choosing, with a vesting duration of the stranger's
        // choosing. The victim is not robbed of the value — the coins are
        // allocated to them — they are robbed of the CHOICE, which is the whole
        // content of an approval. Found on `v1.6.11-audit` by the promise unit
        // `P6b`; `test/audit/poc/PrebuySpendsAnothersAllowance.t.sol` is the PoC.
        //
        // Only the pre-buy is gated. Creating a coin FOR somebody else, with no
        // pre-buy, spends nothing of theirs and stays permissionless.
        if (p.prebuyQuoteIn != 0 && msg.sender != p.creator) {
            revert PrebuyNeedsTheCreator(p.creator, msg.sender);
        }
        // AstraSec I-5: a pre-buy vests for at least a week. Refused here, with
        // the other pre-buy refusals and before anything is deployed.
        if (p.prebuyQuoteIn != 0 && p.vestingDuration < MIN_PREBUY_VESTING) {
            revert PrebuyVestingTooShort(p.vestingDuration, MIN_PREBUY_VESTING);
        }
        // Round `v1.6.4` G1. Refused HERE, ahead of `registerPool` below, because
        // the hook's `supply * CAP_BPS_OF_SUPPLY / BPS` is the first thing a huge
        // supply reaches and it panics rather than refusing. With this bound every
        // `supply * bps` in the system is bounded by construction.
        if (p.supply > FeastConstants.MAX_SUPPLY) revert SupplyTooLarge(p.supply);
        // Round 1: a zero creator stranded both the vesting allocation and the
        // creator's fee share permanently — the plain ERC-20 refuses a transfer
        // to zero, and there is no recipient setter by design. Only the burn
        // address gets the special routing that makes an unclaimable share
        // meaningful; zero gets refused.
        if (p.creator == address(0)) revert ZeroCreator();
        if (p.quote.code.length == 0) revert QuoteIsNotAToken();

        // Deterministic address from (this factory, salt, init code). This
        // venue encodes hook permissions in the pool key rather than in the
        // hook's address, so there is no salt to mine and plain CREATE2 is
        // enough — an entire apparatus other ecosystems need simply does not
        // apply here.
        coin = address(new FeastToken{salt: p.salt}(p.name, p.symbol, p.supply, address(this)));
        if (coin == p.quote) revert CoinAndQuoteMustDiffer();

        key = _buildKey(coin, p.quote);
        PoolId poolId = key.toId();

        hook.registerPool(key, coin, p.creator, p.selfBurnBps, p.referrerBps, p.supply, 0, address(0));
        IFeastCLPoolManager(poolManager).initialize(key, p.sqrtPriceX96);

        // The WHOLE supply seeds the pool now: nothing is carved out, because
        // the creator's stake is bought from the pool rather than taken before
        // it exists.
        _seed(key, coin, p.supply, p.startTick, p.liquidity);

        if (p.prebuyQuoteIn != 0) _prebuy(key, coin, p);

        _coins.push(coin);
        _coinInfo[coin] =
            Coin({quote: p.quote, creator: p.creator, poolId: poolId, supply: p.supply, metadataHash: p.metadataHash});
        emit CoinCreated(coin, p.creator, p.quote, poolId, p.supply, p.selfBurnBps, p.referrerBps, p.metadataHash);
    }

    // --- the platform coin's genesis -----------------------------------------

    /// @notice Mint the platform coin and route its whole supply: 60% into its
    ///         own pool, 25% to the team's vesting, 14.2% to the first year's
    ///         emissions, 0.8% to the genesis partners. Once, by the genesis
    ///         key, and never again by anyone.
    ///
    /// @dev The one privileged call in package 1, and it extinguishes itself:
    ///      `genesisDone` is set before anything else, and every later call
    ///      reverts. Everything it names is a deployment decision — which
    ///      contracts receive the three allocations, which contract may trade
    ///      the pool before it opens, where the platform's fee share goes — and
    ///      it is named here, once, rather than precomputed into package 1's
    ///      bytecode, so that package 2 can be fixed after an audit without a
    ///      reserved-nonce table having to stay true for a week.
    ///
    ///      The shares and the coin's own terms are not parameters: they come
    ///      from `FeastGenesis` and are compiled in. The pool goes through the
    ///      same seeding path as every coin, and the gate's bound is enforced by
    ///      the hook, which is the contract that enforces the gate.
    function genesis(GenesisParams calldata g) external returns (address coin, PoolKey memory key) {
        if (msg.sender != genesisKey) revert NotGenesisKey();
        if (genesisDone) revert GenesisAlreadyDone();
        genesisDone = true;

        // The split, computed once: what each recipient is handed below, and
        // the two amounts the recipients that hold them are asked to agree with.
        uint256 supply = FeastGenesis.PLATFORM_SUPPLY;
        uint256 teamAmount = supply * FeastGenesis.TEAM_BPS / FeastGenesis.BPS;
        uint256 grantsAmount = supply * FeastGenesis.GRANTS_BPS / FeastGenesis.BPS;
        uint256 emissionsAmount = supply * FeastGenesis.EMISSIONS_BPS / FeastGenesis.BPS;
        // The pool takes the remainder, so the four always sum to the supply.
        uint256 poolAmount = supply - teamAmount - grantsAmount - emissionsAmount;

        // **Every contract genesis names goes through ONE path before it is
        // paid or recorded, and is asked the whole of what it will be trusted
        // with** (v1.6.22). Tokens sent to an address with no code strand for
        // ever, so every recipient must already exist; having code is not
        // enough — rounds 1 and 2 found the factory, the oracle, the ledger and
        // the hook itself all accepted by lists of what may not be named — so
        // each must report its role and its coin (`IFeastGenesisRecipient`),
        // and five distinct roles make five distinct contracts.
        //
        // **And a role is not a wiring.** Five times a recipient answered every
        // question genesis asked and was still built against the wrong thing:
        // the window's key, the team wallet's guardian and the sink's arming
        // (v1.6.20 round, closed one by one in v1.6.21), then the grants
        // contract's guardian and the window's factory (Codex appendix on
        // v1.6.21-audit, `genesis-grants-guardian-unchecked` and
        // `genesis-window-wiring`, HIGH each: 8 000 000 and 600 000 000 FEAST
        // paid to contracts that could never move them). The owner ruled that the shape
        // is fixed once (2026-09-25): `_questions` lists everything each
        // recipient's exits call, wait on or hold, `_requireTrusted` asks all of
        // it, and nothing below pays or records a recipient that has not been
        // through it — `test/FeastGenesisTrust.t.sol` derives the recipients
        // from what genesis actually pays, calls and stores, and fails if any
        // is reached first.
        address coinToBe = platformTokenDeployer.predict();
        bytes32[12] memory facts;
        facts[FACT_FACTORY] = bytes32(uint256(uint160(address(this))));
        facts[FACT_HOOK] = bytes32(uint256(uint160(address(hook))));
        facts[FACT_POOL_MANAGER] = bytes32(uint256(uint160(poolManager)));
        facts[FACT_WRAPPED_NATIVE] = bytes32(uint256(uint160(wrappedNative)));
        facts[FACT_GUARDIAN] = bytes32(uint256(uint160(address(guardian))));
        facts[FACT_POOL_ID] = PoolId.unwrap(platformPoolKey().toId());
        facts[FACT_LEDGER] = bytes32(uint256(uint160(address(hook.ledger()))));
        facts[FACT_EMISSIONS] = bytes32(uint256(uint160(g.emissions)));
        facts[FACT_TEAM_DURATION] = bytes32(uint256(FeastGenesis.TEAM_VESTING_DURATION));
        facts[FACT_EMISSIONS_BUDGET] = bytes32(emissionsAmount);
        facts[FACT_GRANT_EACH] = bytes32(grantsAmount / FeastGenesis.PARTNERS);
        // The window first: its close is where the rest of the calendar comes
        // from, and it is read only once the window has proved it is one.
        _requireTrusted(g.window, FeastGenesis.ROLE_LAUNCH_WINDOW, coinToBe, facts);
        // Everything the launch calendar decides is derived from the window's
        // close, from one read: the sanity of that close and the pool's gate
        // here, and — as questions to the recipients that keep them — the team
        // wallet's vesting start and the sink's opening. Each was a number a
        // human typed into a blind-signed genesis transaction until v1.6.10.
        //
        // `openAt` is declared out here because `registerPool` below uses it.
        uint64 openAt;
        uint256 windowClose;
        {
            windowClose = IFeastWindowClose(g.window).endsAt();

            // **The window's close has to be a sane instant.** Everything below
            // is derived from it — the team's vesting start, the pool's gate —
            // so a window reporting a close in the past, or years out, would
            // carry both of them with it. The genesis call is signed blind on a
            // hardware wallet, and this is the one moment the chain can check
            // the calendar the ceremony assumed (v1.6.10 diff round, `P8`).
            // Not in the past, and at most 30 days out: the recipe's window
            // opens about a day after genesis and runs 24 hours.
            //
            // **Strictly in the future, and why the boundary second is not a
            // detail** (`P12` HIGH, v1.6.19 round; PoC
            // `test/audit/poc/RefundedWeightRevival.t.sol`). `FeastLaunchWindow`
            // opens refunds the moment it can no longer settle, and before
            // genesis it cannot: the gate has no opener yet, so from `endsAt`
            // onward `_refundable()` is true and commits start leaving. Genesis
            // then registers `opener = window` and `openAt = endsAt +
            // SETTLE_GRACE`, which makes `_canSettle()` true again — it REVIVES
            // a window that has already begun refunding.
            //
            // `_canSettle` and `_refundable` were exact complements and
            // exclusive at every second; what moves is not the predicate but the
            // gate underneath it, and only genesis can move that. Admitting a
            // `windowClose` equal to the genesis call's OWN second was the one
            // second at which both a refund and a genesis could have happened. Since `refund` cleared
            // `committed[account]` and left `total` standing — sound only
            // because a refunded window was never meant to settle — the revived
            // auction divided its tranche by a denominator that counted weight
            // which had left, the `claimedWeight == total` remainder path could
            // never fire, and the difference was platform coin nobody could
            // claim: **half the tranche, 150 000 000 FEAST, measured.**
            //
            // v1.6.24 (AstraSec M-2) closes the class a second way: `refund`
            // now decrements `total`, so no order of refunds, genesis and
            // settlement can leave the denominator counting weight that left.
            // The two predicates are no longer complements either — from the
            // auction's `abandonAt` both hold, and the settle that follows sells
            // nothing. This bound stays: a ceremony at the closing second is
            // still refused.
            if (windowClose <= block.timestamp || windowClose > block.timestamp + MAX_WINDOW_CLOSE_AHEAD) {
                revert WindowCloseOutOfRange(
                    windowClose, block.timestamp, block.timestamp + MAX_WINDOW_CLOSE_AHEAD
                );
            }

            // **The gate is DERIVED, never typed.** `FeastGenesis` already says
            // what it is — "genesis sets `openAt = window end + SETTLE_GRACE`
            // (Q12)" — and until now genesis registered whatever `openAt` the
            // key passed, so the one number that decides when the public may
            // first trade the platform coin was a figure a human typed into a
            // blind-signed transaction (v1.6.10 diff round, `P12`, and
            // `r2a-claude`). The value below is computed here and the passed
            // one is kept only as the signer's checksum: it must agree, and
            // what is registered is the derivation either way.
            openAt = uint64(windowClose + FeastGenesis.SETTLE_GRACE);
            if (g.openAt != openAt) revert GateIsNotTheWindowsClose(g.openAt, openAt);
        }
        // The rest of the calendar is a question to the recipients that keep
        // it: the team wallet's vesting start and the sink's opening must BE
        // this close (`_questions`).
        facts[FACT_WINDOW_CLOSE] = bytes32(windowClose);
        _requireTrusted(g.teamVesting, FeastGenesis.ROLE_TEAM_VESTING, coinToBe, facts);
        _requireTrusted(g.emissions, FeastGenesis.ROLE_EMISSIONS, coinToBe, facts);
        _requireTrusted(g.grants, FeastGenesis.ROLE_GRANTS, coinToBe, facts);
        // **The sink too, and it must exist** (v1.6.22). It used to be the one
        // recipient allowed no code yet, on the reasoning that it received
        // nothing here and the hook's exit checks it later. The window's
        // `settle` pays the pot's 1% to it at the close, and a sink deployed
        // after the close can never be armed — `schedule` refuses a closed
        // window — so no order of events turns a codeless address at genesis
        // into a sink that can sell what it was sent (`CA-8f254aa78e`, PoC
        // `test/audit/poc/WindowFeeCodelessSink.t.sol`). The ceremony already
        // deploys and arms it first (`script/Genesis.s.sol`).
        _requireTrusted(g.platformSink, FeastGenesis.ROLE_PLATFORM_SINK, coinToBe, facts);

        coin = platformTokenDeployer.deploy();
        // Belt and braces: the coin's constructor minted the supply here, and
        // the routing below assumes all of it.
        uint256 held = IERC20(coin).balanceOf(address(this));
        if (held != supply) revert SupplyNotInCustody(held);

        key = _buildKey(coin, wrappedNative);
        PoolId poolId = key.toId();
        hook.registerPool(
            key,
            coin,
            FeastConstants.BURN_ADDRESS,
            FeastGenesis.PLATFORM_SELF_BURN_BPS,
            FeastGenesis.PLATFORM_REFERRER_BPS,
            supply,
            openAt,
            g.window
        );
        // **Not initialised here, and not seeded here.** From v1.6.11 the launch
        // window is a true uniform-price auction: the price every committer
        // pays is the pot divided by the tranche, and it does not exist until
        // the window closes. There is no admin path that moves a pool's price —
        // by design, there is no owner and no setter anywhere in this system —
        // so a pool initialised now at a guessed price could never be
        // corrected. It is initialised inside `settle()`, at the clearing
        // price, by the window itself; `FeastHook._mayInitialize` admits a
        // gated pool's registered opener for exactly this.

        // The window holds it: half is the tranche it auctions, half becomes the
        // pool's ask side once the price is known. It can only ever reach the
        // pool or a committer — `seedWindowPool` below is the one way out and
        // the claim path is the other.
        IERC20(coin).safeTransfer(g.window, poolAmount);
        _platformWindow = g.window;
        _platformKey = key;
        // The tick is floored from the price the genesis key signed, and the
        // window is asked — with its own code, not a copy of it — whether the
        // position that tick implies can actually be placed for the coin this
        // very transaction is handing it. A price too near the usable edge makes
        // the one-sided range too thin to hold 60% of the supply, and the window
        // refuses by name (`LiquidityOverflow`). Refused HERE, while the
        // ceremony is still in the room, rather than at a settlement twenty-five
        // hours later that can never be retried.
        int24 openingTick = _openingTick(g.sqrtPriceX96);
        IFeastWindowOpening(g.window).openingLiquidityFor(poolAmount, openingTick);
        _platformOpening = Opening({startTick: openingTick});

        // **The guardian's ninety days start HERE, not at its deploy.** Package
        // 1 is built with the factory; this is the TGE, days or months later.
        // Counting from the constructor shortened both the brake and the
        // partner-assignment window by the whole wait — twelve days on the unit
        // fixture's own calendar — and `burnUnfilledSlot` opened that much
        // earlier. One-way, factory-only, and refused a second time.
        guardian.startClock();

        IERC20(coin).safeTransfer(g.teamVesting, teamAmount);
        IERC20(coin).safeTransfer(g.emissions, emissionsAmount);
        IERC20(coin).safeTransfer(g.grants, grantsAmount);

        platformCoin = coin;
        platformSink = g.platformSink;
        _coins.push(coin);
        _coinInfo[coin] = Coin({
            quote: wrappedNative,
            creator: FeastConstants.BURN_ADDRESS,
            poolId: poolId,
            supply: supply,
            metadataHash: g.metadataHash
        });
        emit CoinCreated(
            coin,
            FeastConstants.BURN_ADDRESS,
            wrappedNative,
            poolId,
            supply,
            FeastGenesis.PLATFORM_SELF_BURN_BPS,
            FeastGenesis.PLATFORM_REFERRER_BPS,
            g.metadataHash
        );
        emit Genesis(coin, poolId, g.window, g.openAt, g.teamVesting, g.emissions, g.grants, g.platformSink);
    }

    function _requireCode(address recipient) internal view {
        if (recipient.code.length == 0) revert RecipientHasNoCode(recipient);
    }

    /// @dev A recipient exists, reports `role`, and serves this platform coin.
    ///      A contract that does not implement the answer — one of feast's own,
    ///      the venue's, anyone's — is refused.
    function _requireRecipient(address recipient, bytes32 role, address coinToBe) internal view {
        _requireCode(recipient);
        try IFeastGenesisRecipient(recipient).genesisRole() returns (bytes32 reported) {
            if (reported != role) revert RecipientNotAllowed(recipient);
        } catch {
            revert RecipientNotAllowed(recipient);
        }
        try IFeastGenesisRecipient(recipient).platformCoin() returns (address served) {
            if (served != coinToBe) revert RecipientNotAllowed(recipient);
        } catch {
            revert RecipientNotAllowed(recipient);
        }
    }

    // --- what genesis asks each recipient (v1.6.22) --------------------------

    /// @dev What genesis measures the answers against: its own facts, never a
    ///      recipient's. `FACT_WINDOW_CLOSE` is filled in once the window has
    ///      passed and its close has been range-checked.
    uint256 private constant FACT_FACTORY = 0;
    uint256 private constant FACT_HOOK = 1;
    uint256 private constant FACT_POOL_MANAGER = 2;
    uint256 private constant FACT_WRAPPED_NATIVE = 3;
    uint256 private constant FACT_GUARDIAN = 4;
    uint256 private constant FACT_POOL_ID = 5;
    uint256 private constant FACT_LEDGER = 6;
    uint256 private constant FACT_EMISSIONS = 7;
    uint256 private constant FACT_TEAM_DURATION = 8;
    uint256 private constant FACT_EMISSIONS_BUDGET = 9;
    uint256 private constant FACT_GRANT_EACH = 10;
    uint256 private constant FACT_WINDOW_CLOSE = 11;

    /// @dev One question in one word: the getter asked (bits 40-71), the error
    ///      any other answer is refused with (bits 8-39), and the fact the answer
    ///      must equal (bits 0-7).
    function _ask(bytes4 getter, bytes4 refusal, uint256 fact) private pure returns (uint256) {
        return (uint256(uint32(getter)) << 40) | (uint256(uint32(refusal)) << 8) | fact;
    }

    /// @notice Everything genesis asks each recipient beyond its code, its role
    ///         and its coin — the whole of what that recipient will be trusted
    ///         with, in one table (v1.6.22).
    ///
    /// @dev **How the set was drawn.** From each recipient's EXITS — the
    ///      functions that move its allocation out — and everything those exits
    ///      call, wait on or hold: every collaborator an exit calls must be the
    ///      platform's own, every clock an exit waits on must be the one genesis
    ///      derives, and every amount a recipient believes it holds must be the
    ///      amount genesis sends — wherever the factory has ground truth. What is
    ///      left out, and why, is written beside each role. Reading this table
    ///      is reading the whole of the trust genesis extends.
    ///
    ///      Order matters only for which refusal a recipient wrong in two ways
    ///      reports first.
    function _questions(bytes32 role) internal pure returns (uint256[] memory q) {
        if (role == FeastGenesis.ROLE_LAUNCH_WINDOW) {
            // Exits: `settle`, `claim`, `refund`. Not asked: `vault()`, which no
            // function of the window reads; `startsAt`/`lockAt`, derived from
            // the close in its constructor, which gate committers' own funds and
            // not this allocation. Its close and its opening probe are asked in
            // `genesis` itself.
            q = new uint256[](5);
            // The pool it settles into: keyed to another, it takes the tranche
            // and can never place it (`P4-claude`, v1.6.21).
            q[0] = _ask(IFeastGenesisQuestions.poolKey.selector, WindowPoolKeyMismatch.selector, FACT_POOL_ID);
            // `settle` reads its opening from, and seeds through, this
            // factory; wired to another, it can never settle and 60% of the
            // supply has no exit (`genesis-window-wiring`, Codex, v1.6.21-audit).
            q[1] = _ask(IFeastGenesisQuestions.factory.selector, WindowFactoryMismatch.selector, FACT_FACTORY);
            // Its gate is read from this hook and its seed is paid to it.
            q[2] = _ask(IFeastGenesisQuestions.hook.selector, WindowHookMismatch.selector, FACT_HOOK);
            // `settle` initialises the pool through this manager.
            q[3] = _ask(IFeastGenesisQuestions.poolManager.selector, WindowPoolManagerMismatch.selector, FACT_POOL_MANAGER);
            // Every commit, the pot, its 1% and every refund are this token.
            q[4] = _ask(IFeastGenesisQuestions.wrappedNative.selector, WindowWrappedNativeMismatch.selector, FACT_WRAPPED_NATIVE);
        } else if (role == FeastGenesis.ROLE_TEAM_VESTING) {
            // Exit: `release`. Not asked: the beneficiary, for which the factory
            // has no ground truth (OpenZeppelin refuses a zero owner, and
            // renouncing is disabled).
            q = new uint256[](3);
            // "36 months from the window's close" is two claims, and until
            // v1.6.10 only one was a mechanism: a wallet already fully
            // releasable passed every question (CA-8ea162587a).
            q[0] = _ask(IFeastGenesisQuestions.start.selector, TeamVestingStartNotWindowClose.selector, FACT_WINDOW_CLOSE);
            // Every `release` reads this brake; on an address with no code
            // every one reverts for ever (`P8-claude`, v1.6.21).
            q[1] = _ask(IFeastGenesisQuestions.guardian.selector, TeamVestingGuardianMismatch.selector, FACT_GUARDIAN);
            // The other half of the schedule. Compiled into the genuine wallet,
            // so only a stale build can differ — and at zero, 25% of the supply
            // is releasable at the close.
            q[2] = _ask(IFeastGenesisQuestions.duration.selector, TeamVestingDurationMismatch.selector, FACT_TEAM_DURATION);
        } else if (role == FeastGenesis.ROLE_EMISSIONS) {
            // Exits: `claim`, `releaseRedirect`, `burnExpired`, `burnRemainder`,
            // fed by `settle`. Not asked: `timelock()` and `firstWeek()`, for
            // which the factory has no ground truth (the levers are bounded at
            // the callee); `pricer()`, which the timelock can replace — a bad
            // one delays settlement and cannot strand anything.
            q = new uint256[](5);
            // Every exit reads this brake (`CA-9abd1b1a68`).
            q[0] = _ask(IFeastGenesisQuestions.guardian.selector, EmissionsGuardianMismatch.selector, FACT_GUARDIAN);
            // `claimsOpen()` reads the gate through this hook ...
            q[1] = _ask(IFeastGenesisQuestions.hook.selector, EmissionsHookMismatch.selector, FACT_HOOK);
            // ... for this pool; keyed to another, claims never open and 14.2%
            // of the supply has no way out (`CA-c03b8b2ead`).
            q[2] = _ask(IFeastGenesisQuestions.platformPoolId.selector, EmissionsPoolMismatch.selector, FACT_POOL_ID);
            // `settle` and every claim read this ledger; with no code behind it
            // no week settles, and the remainder can never be burned.
            q[3] = _ask(IFeastGenesisQuestions.ledger.selector, EmissionsLedgerMismatch.selector, FACT_LEDGER);
            // What it will promise out of what it is sent: above the holding,
            // the last claims are insolvent. Compiled in; a stale build differs.
            q[4] = _ask(IFeastGenesisQuestions.budget.selector, EmissionsBudgetMismatch.selector, FACT_EMISSIONS_BUDGET);
        } else if (role == FeastGenesis.ROLE_GRANTS) {
            // Exits: `claim`, `burnUnearned`, `burnUnfilledSlot`; and
            // `assignPartner`. Not asked: `targetNative()` and `partners()`, for
            // which the factory has no ground truth (the constructor refuses a
            // zero target and a duplicate partner).
            q = new uint256[](3);
            // Every exit reads this brake, and both slot paths its clock: with
            // no guardian at all, 8 000 000 FEAST is funded and can never move
            // (`genesis-grants-guardian-unchecked`, Codex, v1.6.21-audit).
            q[0] = _ask(IFeastGenesisQuestions.guardian.selector, GrantsGuardianMismatch.selector, FACT_GUARDIAN);
            // Claims wait on these emissions' `claimsOpen()` and settled weeks.
            q[1] = _ask(IFeastGenesisQuestions.emissions.selector, GrantsEmissionsMismatch.selector, FACT_EMISSIONS);
            // Eight grants must be exactly what it is sent: it has no sweep, so
            // any difference strands for ever. Compiled in; a stale build differs.
            q[2] = _ask(IFeastGenesisQuestions.grant.selector, GrantsGrantMismatch.selector, FACT_GRANT_EACH);
        } else if (role == FeastGenesis.ROLE_PLATFORM_SINK) {
            // Exits: `open`, then `take`; `burnStray`. Not asked: `genesisKey()`,
            // whose one power — `schedule` — the first row proves is spent.
            q = new uint256[](2);
            // Armed to this close. `schedule` refuses a window that has closed,
            // so a sink not armed before genesis can never be, and the pot's 1%
            // strands in it — which is why the ceremony arms it first
            // (`P12-claude`, v1.6.21).
            q[0] = _ask(IFeastGenesisQuestions.opensAt.selector, SinkNotArmed.selector, FACT_WINDOW_CLOSE);
            // `open` and `take` read this brake (`CA-9abd1b1a68`).
            q[1] = _ask(IFeastGenesisQuestions.guardian.selector, SinkGuardianMismatch.selector, FACT_GUARDIAN);
        }
    }

    /// @dev **The one path** (v1.6.22). A recipient exists, reports `role` and
    ///      serves this coin (`_requireRecipient`), and then answers every
    ///      question `_questions(role)` asks with genesis's own fact.
    ///
    ///      Each question is a static call of a getter with no arguments. The
    ///      answer is read as one word when it is one word, and as the
    ///      `keccak256` of all of it when it is longer — which for a pool key's
    ///      six words is exactly its `PoolId` (`PoolIdLibrary.toId`). A call
    ///      that fails, or answers in less than a word, answered nothing, and is
    ///      refused as if it had named zero: a contract that cannot answer is
    ///      refused, never trusted.
    ///
    ///      A refusal is `refusal(named, expected)`: the error's selector and
    ///      two words, which is the ABI encoding of every error the table names.
    function _requireTrusted(address recipient, bytes32 role, address coinToBe, bytes32[12] memory facts)
        internal
        view
    {
        _requireRecipient(recipient, role, coinToBe);
        uint256[] memory q = _questions(role);
        for (uint256 i = 0; i < q.length; i++) {
            uint256 row = q[i];
            bytes32 expected = facts[row & 0xff];
            assembly ("memory-safe") {
                let p := mload(0x40)
                mstore(p, shl(224, shr(40, row)))
                // Two statements, not one expression: Yul evaluates arguments
                // right to left, so `and(staticcall(..), gt(returndatasize(), 31))`
                // reads the length of the PREVIOUS call's answer — caught by
                // `test_theEngineReadsAnAnswerByItsLengthToTheBit`.
                let ok := staticcall(gas(), recipient, p, 4, 0, 0)
                let answered := and(ok, gt(returndatasize(), 31))
                let named := 0
                if answered {
                    returndatacopy(p, 0, returndatasize())
                    named := mload(p)
                    if gt(returndatasize(), 32) { named := keccak256(p, returndatasize()) }
                }
                if or(iszero(answered), iszero(eq(named, expected))) {
                    mstore(p, shl(224, shr(8, row)))
                    mstore(add(p, 4), named)
                    mstore(add(p, 36), expected)
                    revert(p, 68)
                }
            }
        }
    }

    /// @notice Where the platform coin is, or will be.
    function predictPlatformCoin() external view returns (address) {
        return platformTokenDeployer.predict();
    }

    /// @dev Seed a pool. Everything allotted to it goes in, and the position
    ///      spans from the opening tick to the far edge of the usable range: a
    ///      no-curve launch, not a bonding curve. One implementation, used by
    ///      every coin and by the platform coin alike.
    // --- the platform pool's auction seed ------------------------------------

    /// @dev One number, because one number cannot disagree with itself. See
    ///      `platformOpening`.
    struct Opening {
        int24 startTick;
    }

    address private _platformWindow;
    PoolKey private _platformKey;
    Opening private _platformOpening;

    error NotTheWindow();
    error CreationStopped();
    error Frozen();
    error OpeningPriceOutOfRange(uint160 sqrtPriceX96);

    /// @notice The usable tick the platform pool opens at IF nobody commits to
    ///         the launch window, so the window can read it back at settlement.
    ///
    /// @dev **One number, derived, not three signed.** Until v1.6.12 genesis
    ///      recorded a price, a start tick and a liquidity, unchecked and with
    ///      no setter, and the three were first exercised together twenty-five
    ///      hours later on the no-commit branch of `settle()`. A price above its
    ///      own start tick put the coin-only range in range, the venue asked the
    ///      hook for wrapped native it does not hold, and the settlement reverted
    ///      — permanently, because after the grace hour the window could never
    ///      settle (until v1.6.24 removed that deadline), nothing was committed
    ///      so nothing was refundable, and 60% of the supply had no exit. Five units of the v1.6.11 round found it
    ///      across both families; `test/audit/poc/NoCommitOpeningUnsettleable.t.sol`
    ///      is the PoC.
    ///
    ///      Now the genesis key signs the PRICE alone. The tick is floored from
    ///      it here with the same align-DOWN rule the auction uses, the pool
    ///      opens AT that tick rather than at the raw price — so the position is
    ///      one-sided by construction — and the liquidity is derived from the
    ///      holding at settlement. There is nothing left to disagree.
    function platformOpening() external view returns (int24 startTick) {
        return _platformOpening.startTick;
    }

    /// @dev The largest usable tick at or below `sqrtPriceX96`. Solidity's
    ///      integer division truncates toward zero, so the correction below is
    ///      what makes it a floor on both sides of zero, and a platform pool
    ///      priced under one unit of quote is squarely in the negative half.
    ///      Refused by name rather than by panic when the price has no usable
    ///      tick strictly inside the range the two seed sides need.
    function _openingTick(uint160 sqrtPriceX96) internal pure returns (int24) {
        if (sqrtPriceX96 < TickMath.MIN_SQRT_PRICE || sqrtPriceX96 >= TickMath.MAX_SQRT_PRICE) {
            revert OpeningPriceOutOfRange(sqrtPriceX96);
        }
        int24 spacing = FeastConstants.POOL_TICK_SPACING;
        int24 tick = TickMath.getTickAtSqrtPrice(sqrtPriceX96);
        int24 aligned = (tick / spacing) * spacing;
        if (aligned > tick) aligned -= spacing;
        if (aligned <= _minUsableTick() || aligned >= _maxUsableTick()) {
            revert OpeningPriceOutOfRange(sqrtPriceX96);
        }
        return aligned;
    }

    /// @notice Place the platform pool's ONE opening position after its auction
    ///         has cleared: the whole usable range, holding both tokens. Only
    ///         the launch window genesis named may ask.
    /// @dev The window holds the coin and the pot and sends both to the hook
    ///      before calling. The trust boundary does not move: the hook still
    ///      answers to the factory alone, and the factory answers to the one
    ///      window `genesis` recorded.
    function seedWindowPool(uint128 liquidity) external {
        if (msg.sender != _platformWindow || _platformWindow == address(0)) revert NotTheWindow();
        address coin = platformCoin;
        uint256 held = IERC20(coin).balanceOf(address(hook));
        hook.seedAuctionLiquidity(_platformKey, liquidity);
        _burnUnplaced(coin, held);
    }

    /// @notice Place the platform pool's opening position when NOBODY committed:
    ///         a single-sided coin range from the opening tick to the far edge,
    ///         which is the shape every creator launch has. Only the launch
    ///         window genesis named may ask.
    /// @dev It goes through `seedLiquidity`, the creator path, precisely because
    ///      that path refuses a position that would need quote
    ///      (`SeedWouldNeedQuote`) — and a no-commit opening must not need any,
    ///      since nobody put up a wei. It records its range for the same reason
    ///      the auction's does: the range is the only handle `collectLpFees` has.
    function seedWindowOpening(int24 tickLower, int24 tickUpper, uint128 liquidity) external {
        if (msg.sender != _platformWindow || _platformWindow == address(0)) revert NotTheWindow();
        address coin = platformCoin;
        uint256 held = IERC20(coin).balanceOf(address(hook));
        hook.seedLiquidity(_platformKey, tickLower, tickUpper, liquidity);
        _burnUnplaced(coin, held);
    }

    /// @dev What genesis hands the launch window: the platform supply less the
    ///      team's, the grants' and the emissions' shares — `genesis`'s own
    ///      `poolAmount`, the same remainder of the same constants. A settle
    ///      that burns exactly the seed's remainder pins the two together
    ///      (`FeastWindowAuction.t.sol`).
    uint256 private constant WINDOW_SHARE = FeastGenesis.PLATFORM_SUPPLY
        - FeastGenesis.PLATFORM_SUPPLY * FeastGenesis.TEAM_BPS / FeastGenesis.BPS
        - FeastGenesis.PLATFORM_SUPPLY * FeastGenesis.GRANTS_BPS / FeastGenesis.BPS
        - FeastGenesis.PLATFORM_SUPPLY * FeastGenesis.EMISSIONS_BPS / FeastGenesis.BPS;

    /// @dev I14, the same rule `_seed` applies to a creator's launch: whatever
    ///      the position did not consume would otherwise sit in the hook owned
    ///      by nothing, so it is burned rather than left. Both window paths
    ///      floor their liquidity so the pool is never asked for more coin than
    ///      the window holds, which leaves a few thousand wei — 2,942 at a
    ///      ten-ether pot. The 1% tolerance is `_seed`'s, for the same reason:
    ///      a mis-stated liquidity should revert the settlement, not burn the
    ///      supply.
    ///
    ///      **The remainder is the seed's, never the hook's balance** (v1.6.27,
    ///      `CA-344cf3b11c`). Until v1.6.27 it was the hook's whole FEAST
    ///      balance after seeding, so FEAST that reached the hook by any other
    ///      route — the team's vesting, an emission claim, a stray transfer —
    ///      counted as remainder; past 1% of the seed, every `settle` reverted
    ///      `PoolTooShallow`, and since `settle` has no deadline the window's 60%
    ///      of the supply could be stranded for good. Now `sent` is what the
    ///      window delivered — the share genesis handed it, less what it still
    ///      holds: the tranche it sold, or nothing when nobody committed — and
    ///      the remainder is `sent` less what the seeding took out of the hook.
    ///      FEAST already on the hook is not the seed's business: it is neither
    ///      counted nor burned, and stays where its sender put it, owned by
    ///      nothing, as any token sent to a contract that cannot move it does.
    ///
    ///      `sent` cannot underflow: what the window still holds is its tranche,
    ///      half of its holding, and its holding is at most the whole supply —
    ///      so at most 50%, short of the 60% genesis handed it. FEAST sent
    ///      straight to the WINDOW before it settles is placed with the rest —
    ///      the window sizes its position from its whole holding — but `sent`
    ///      does not count it, so the seed's own rounding remainder, a few
    ///      thousand wei, is then left on the hook rather than burned; the
    ///      saturation below is that case, and never a revert.
    function _burnUnplaced(address coin, uint256 held) private {
        uint256 sent = WINDOW_SHARE - IERC20(coin).balanceOf(_platformWindow);
        uint256 placed = held - IERC20(coin).balanceOf(address(hook));
        uint256 unused = sent > placed ? sent - placed : 0;
        if (unused > sent / 100) revert PoolTooShallow();
        if (unused != 0) hook.burnUnusedSeed(coin, unused);
    }

    // --- the creator's pre-buy ----------------------------------------------

    /// @notice What the creator bought of their own coin when they created it,
    ///         and when it unlocks. `(0, 0, 0)` for a coin created without one.
    /// @dev One view so the coin page can render "the creator pre-bought x% of
    ///      supply for Y <quote> - vests N months / sellable at any time"
    ///      without an indexer. The percentage is `coinsOut / supply`, and the
    ///      supply is in `CoinCreated` and in `coinInfo`.
    mapping(address => Prebuy) private _prebuys;

    struct Prebuy {
        uint256 quoteIn;
        uint256 coinsOut;
        uint64 vestingEnd;
    }

    function prebuyOf(address coin) external view returns (uint256 quoteIn, uint256 coinsOut, uint64 vestingEnd) {
        Prebuy storage b = _prebuys[coin];
        return (b.quoteIn, b.coinsOut, b.vestingEnd);
    }

    /// @dev The creator's stake, bought rather than granted.
    ///
    ///      **The factory is the swapper, and that is the load-bearing choice.**
    ///      The hook owns all of this contract's other venue plumbing, so the
    ///      cheap move would be another `Action` on the hook. It is wrong: the
    ///      venue SKIPS a hook's callbacks when the hook is the swapper — the
    ///      hook relies on that and re-checks the gate by hand in
    ///      `buyBackAndBurn` for exactly this reason — so a hook-executed
    ///      pre-buy would pay no fee at all. With the factory as `sender` the
    ///      ordinary `beforeSwap`/`afterSwap` fire and the 1% is taken on the
    ///      normal path, with no special case anywhere in the fee code. The
    ///      creator's 50% share of that fee is theirs, exactly as it is on any
    ///      other trade of their coin.
    ///
    ///      The quote is pulled from the creator, spent into the pool, and stays
    ///      there inside the permanently locked position. A native quote is not
    ///      representable anywhere in this system (`QuoteIsNotAToken`), so a
    ///      WBNB creator wraps first.
    function _prebuy(PoolKey memory key, address coin, CreateParams calldata p) internal {
        IERC20(p.quote).safeTransferFrom(p.creator, address(this), p.prebuyQuoteIn);

        bytes memory result = IFeastVault(vault).lock(abi.encode(key, coin, p.prebuyQuoteIn));
        uint256 coinsOut = abi.decode(result, (uint256));

        // The bound is a SHARE of supply, measured in coins received, and it is
        // checked after the swap because that is the only moment the share is
        // known. The creator's own bound is `minCoinsOut`; this one is the
        // public's, and it is what P6 promises is enforced.
        uint256 max = p.supply * MAX_PREBUY_BPS_OF_SUPPLY / FeastConstants.BPS;
        if (coinsOut > max) revert PrebuyTooLarge(coinsOut, max);
        if (coinsOut < p.minCoinsOut) revert PrebuyBelowMinimum(coinsOut, p.minCoinsOut);

        IERC20(coin).safeTransfer(address(vesting), coinsOut);
        vesting.createAllocation(coin, p.creator, coinsOut, p.vestingDuration);

        uint64 vestingEnd = uint64(block.timestamp) + p.vestingDuration;
        _prebuys[coin] = Prebuy({quoteIn: p.prebuyQuoteIn, coinsOut: coinsOut, vestingEnd: vestingEnd});
        emit CreatorPrebuy(coin, p.prebuyQuoteIn, coinsOut, vestingEnd);
    }

    /// @dev The factory's only lock callback. It exists for the pre-buy and for
    ///      nothing else, so it decodes one shape and takes no action word.
    function lockAcquired(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != vault) revert NotTheVault();
        (PoolKey memory key, address coin, uint256 quoteIn) = abi.decode(data, (PoolKey, address, uint256));

        bool coinIsCurrency0 = Currency.unwrap(key.currency0) == coin;
        // Spending the quote to receive the coin. No price limit of our own: the
        // creator's `minCoinsOut` is the bound they chose, and a limit here
        // would refuse a launch for a price the creator set moments earlier.
        bool zeroForOne = !coinIsCurrency0;
        int256 delta = IFeastCLPoolManager(poolManager).swap(
            key,
            IFeastCLPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                // **Checked.** `int256(type(uint256).max)` is -1, and negating
                // it gives POSITIVE ONE: the venue reads that as an exact-OUTPUT
                // swap for a single unit, and almost all the creator's quote —
                // already transferred in — strands in this contract. Neither of
                // the two guards that catch the neighbouring values fires: the
                // language's checked negation only panics at exactly
                // `type(int256).min`, and the venue's own SafeCast only refuses
                // values above it.
                //
                // Found by `P6b` in the v1.6.12 round. **I had published this
                // shape as DISPROVED at v1.6.11**: my PoC tested `2^255` and
                // `2^255 + 1`, where those two guards do fire, and never tested
                // the one value where both miss. The retraction is dated in
                // `docs/audit-briefs/v1613-round-findings.md`.
                amountSpecified: -SafeCast.toInt256(quoteIn),
                sqrtPriceLimitX96: zeroForOne ? MIN_SQRT_PRICE + 1 : MAX_SQRT_PRICE - 1
            }),
            ""
        );

        int128 amount0 = BalanceDelta.wrap(delta).amount0();
        int128 amount1 = BalanceDelta.wrap(delta).amount1();
        _settle(key.currency0, amount0);
        _settle(key.currency1, amount1);

        int128 coinLeg = coinIsCurrency0 ? amount0 : amount1;
        return abi.encode(coinLeg > 0 ? uint256(uint128(coinLeg)) : 0);
    }

    /// @dev Pay what is owed with real tokens, take what is due. The factory
    ///      holds ERC-20s rather than vault claims, so this syncs and settles
    ///      rather than burning a claim the way the hook does.
    function _settle(Currency currency, int128 amount) private {
        if (amount < 0) {
            IFeastVault(vault).sync(currency);
            IERC20(Currency.unwrap(currency)).safeTransfer(vault, uint256(uint128(-amount)));
            IFeastVault(vault).settle();
        } else if (amount > 0) {
            IFeastVault(vault).take(currency, address(this), uint256(uint128(amount)));
        }
    }

    function _seed(PoolKey memory key, address coin, uint256 poolAmount, int24 startTick, uint128 liquidity) internal {
        IERC20(coin).safeTransfer(address(hook), poolAmount);
        bool coinIsCurrency0 = Currency.unwrap(key.currency0) == coin;
        (int24 tickLower, int24 tickUpper) =
            coinIsCurrency0 ? (startTick, _maxUsableTick()) : (_minUsableTick(), startTick);
        hook.seedLiquidity(key, tickLower, tickUpper, liquidity);

        // Whatever the position did not consume would otherwise sit in the hook
        // owned by nothing. It is burned rather than left, so no balance
        // strands (I14) — but only a rounding-sized remainder is tolerated.
        // A creator who understates the liquidity would otherwise burn most of
        // their own supply on a typo, permanently.
        uint256 unused = IERC20(coin).balanceOf(address(hook));
        if (unused > poolAmount / 100) revert PoolTooShallow();
        if (unused != 0) hook.burnUnusedSeed(coin, unused);
    }

    // --- what the app reads ----------------------------------------------

    function coinCount() external view returns (uint256) {
        return _coins.length;
    }

    function coinAt(uint256 index) external view returns (address) {
        return _coins[index];
    }

    /// @notice Every coin this factory has made, oldest first.
    function listCoins() external view returns (address[] memory) {
        return _coins;
    }

    function getCoin(address coin) external view returns (Coin memory) {
        return _coinInfo[coin];
    }

    function poolKeyFor(address coin) public view returns (PoolKey memory) {
        return _buildKey(coin, _coinInfo[coin].quote);
    }

    /// @notice The pool the platform coin will trade in — which is the key the
    ///         launch window must be built on, and the one genesis now checks
    ///         it against (v1.6.21, v1.6.20 round `P4-claude`).
    /// @dev Not `poolKeyFor`: before genesis the coin has no registered quote,
    ///      so that one would answer with a zero quote. This is the same
    ///      expression genesis evaluates, published so the ceremony can be
    ///      checked BEFORE it is signed rather than only refused after.
    function platformPoolKey() public view returns (PoolKey memory) {
        return _buildKey(platformTokenDeployer.predict(), wrappedNative);
    }

    function predictCoin(bytes32 salt, string calldata name, string calldata symbol, uint256 supply)
        external
        view
        returns (address)
    {
        bytes32 initCodeHash = keccak256(
            abi.encodePacked(type(FeastToken).creationCode, abi.encode(name, symbol, supply, address(this)))
        );
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, initCodeHash)))));
    }

    // --- helpers ----------------------------------------------------------

    function _buildKey(address coin, address quote) internal view returns (PoolKey memory) {
        (address c0, address c1) = coin < quote ? (coin, quote) : (quote, coin);
        return PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            hooks: address(hook),
            poolManager: poolManager,
            fee: FeastConstants.POOL_LP_FEE,
            parameters: hook.poolParameters()
        });
    }

    /// @dev The widest range whose endpoints are multiples of the tick spacing.
    ///      The venue's own tick bounds by name rather than as `±887_272`
    ///      (v1.6.24, AstraSec I-6): a constant, so the bytecode is unchanged.
    function _minUsableTick() internal pure returns (int24) {
        return (TickMath.MIN_TICK / FeastConstants.POOL_TICK_SPACING) * FeastConstants.POOL_TICK_SPACING;
    }

    function _maxUsableTick() internal pure returns (int24) {
        return (TickMath.MAX_TICK / FeastConstants.POOL_TICK_SPACING) * FeastConstants.POOL_TICK_SPACING;
    }
}
