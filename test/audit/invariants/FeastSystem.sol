// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FeastConstants} from "../../../src/FeastConstants.sol";
import {FeastConverter} from "../../../src/FeastConverter.sol";
import {FeastFactory} from "../../../src/FeastFactory.sol";
import {FeastFeeLedger} from "../../../src/FeastFeeLedger.sol";
import {FeastHook} from "../../../src/FeastHook.sol";
import {FeastOracle} from "../../../src/FeastOracle.sol";
import {FeastPlatformTokenDeployer} from "../../../src/FeastPlatformTokenDeployer.sol";
import {FeastReferrals} from "../../../src/FeastReferrals.sol";
import {FeastVesting} from "../../../src/FeastVesting.sol";
import {Currency} from "../../../src/venue/Currency.sol";
import {PoolId, PoolIdLibrary} from "../../../src/venue/PoolId.sol";
import {PoolKey} from "../../../src/venue/PoolKey.sol";

import {Vault} from "infinity-core/src/Vault.sol";
import {CLPoolManager} from "infinity-core/src/pool-cl/CLPoolManager.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {CustomRevert} from "infinity-core/src/libraries/CustomRevert.sol";
import {Currency as UpCurrency} from "infinity-core/src/types/Currency.sol";

import {MockERC20, PausableMockERC20} from "../../utils/MockERC20.sol";
import {MockWrappedNative} from "../../utils/MockWrappedNative.sol";
import {PoolRouter} from "../../utils/PoolRouter.sol";
import {VenueBridge} from "../../utils/VenueBridge.sol";

import {FeastGuardian} from "../../../src/FeastGuardian.sol";
interface IHevm {
    function warp(uint256) external;
    function roll(uint256) external;
}

/// @notice The v1.6 day-one surface under stateful fuzzing (contract-audit dynamic layer, task
///         444, second leg). Package 1 only: factory, hook, fee ledger, oracle, vesting. The
///         genesis path and package 2 are exercised by the repo's own suite and by the PoCs.
/// @dev    Deployed without address-prediction cheatcodes so the same contract drives Foundry's
///         invariant runner and Medusa. Three pools: A and B share one quote (so solvency is
///         checked across pools sharing a Vault claim balance), B's creator is the burn address
///         (v1's I14), C's quote can be frozen. Every check compares exact integers.
contract FeastSystem {
    using PoolIdLibrary for PoolKey;
    using VenueBridge for PoolKey;

    IHevm internal constant HEVM = IHevm(address(uint160(uint256(keccak256("hevm cheat code")))));
    uint160 internal constant SQRT_PRICE_1_1 = 79_228_162_514_264_337_593_543_950_336;
    uint160 internal constant MIN_SQRT = 4_295_128_740;
    uint160 internal constant MAX_SQRT = 1_461_446_703_485_210_103_287_273_052_203_988_822_378_723_970_341;
    uint256 internal constant SUPPLY = 1_000_000_000e18;
    uint256 internal constant POOLS = 3;
    uint256 internal constant ACCOUNTS = 5;

    Vault public vault;
    CLPoolManager public pm;
    PoolRouter public router;
    MockWrappedNative public wbnb;
    FeastOracle public oracle;
    FeastFeeLedger public ledger;
    FeastGuardian public guardian;
    FeastHook public hook;
    FeastFactory public factory;
    MockERC20 public quoteShared;
    PausableMockERC20 public quoteFrozen;

    PoolKey[POOLS] internal keys;
    address[POOLS] internal quotes;
    address[POOLS] internal coins;
    address[ACCOUNTS] internal accounts;
    address internal constant CREATOR_A = address(0xA11CE);
    address internal constant CREATOR_C = address(0xC4201);

    uint256 public clock;

    error Refused(bool fromHook, bytes reason);

    uint256 public ghostUndeclaredHookReverts;
    bytes public ghostLastUndeclared;
    uint256 public ghostSwapsLanded;
    uint256 public ghostCrossPoolWrites;
    uint256 public ghostDecreases;
    uint256 public ghostMisdirectedPayments;
    uint256 public ghostClaimsPaid;
    uint256 public ghostBuybacksLanded;
    uint256 public ghostCollectsBanked;
    uint256 public ghostFilledCoinBurned;
    mapping(uint256 => mapping(address => uint256)) public ghostReferrerPaid;
    mapping(uint256 => uint256[4]) internal lastEarned;

    constructor() {
        clock = 1_791_162_000; // an hour after the recipe's opening Monday
        HEVM.warp(clock);
        HEVM.roll(1_000);

        vault = new Vault(); // 1
        pm = new CLPoolManager(vault); // 2
        vault.registerApp(address(pm));
        router = new PoolRouter(vault, pm); // 3
        wbnb = new MockWrappedNative(); // 4
        quoteShared = new MockERC20("Shared", "SHR", 18); // 5
        quoteFrozen = new PausableMockERC20("Frozen", "FRZ", 18, address(this)); // 6

        address hookAt = _createAddress(address(this), 12);
        address factoryAt = _createAddress(address(this), 15);
        guardian = new FeastGuardian(address(0x3517), address(this)); // 7
        oracle = new FeastOracle(hookAt); // 8
        FeastConverter converter = new FeastConverter(address(0xF3), address(wbnb), hookAt); // 9
        ledger = new FeastFeeLedger(hookAt); // 10
        FeastReferrals referrals = new FeastReferrals(); // 11 (v1.6.26: the referral registry the hook reads)
        hook = new FeastHook(address(pm), address(vault), factoryAt, address(oracle), address(ledger), address(converter),
            address(guardian), address(referrals), new FeastHook.TipFloor[](0)); // 12
        FeastVesting vesting = new FeastVesting(factoryAt, address(guardian)); // 13
        FeastPlatformTokenDeployer deployer = new FeastPlatformTokenDeployer(factoryAt); // 14
        factory = new FeastFactory(
            address(pm), address(vault), address(hook), address(vesting), address(deployer), address(wbnb), address(0x6E7E5)
        ); // 15
        require(address(hook) == hookAt && address(factory) == factoryAt, "address prediction");

        accounts = [CREATOR_A, address(0xB0B), CREATOR_C, address(0xD0D0), address(0xE0E0)];
        _launch(0, address(quoteShared), CREATOR_A, bytes32(uint256(1)));
        _launch(1, address(quoteShared), FeastConstants.BURN_ADDRESS, bytes32(uint256(2)));
        _launch(2, address(quoteFrozen), CREATOR_C, bytes32(uint256(3)));

        quoteShared.mint(address(router), 1_000_000_000e18);
        quoteFrozen.mint(address(router), 1_000_000_000e18);
        HEVM.roll(1_000 + FeastConstants.CAP_BLOCKS + 1);
    }

    function _launch(uint256 i, address quote, address creator, bytes32 salt) internal {
        (address coin, PoolKey memory key) = factory.create(
            FeastFactory.CreateParams({
                name: "Coin",
                symbol: "COIN",
                supply: SUPPLY,
                quote: quote,
                creator: creator,
                selfBurnBps: FeastConstants.DEFAULT_SELF_BURN_BPS,
                referrerBps: FeastConstants.DEFAULT_REFERRER_BPS,
                prebuyQuoteIn: 0,
                minCoinsOut: 0,
                vestingDuration: 0,
                sqrtPriceX96: SQRT_PRICE_1_1,
                startTick: 0,
                liquidity: uint128(SUPPLY * 999 / 1_000),
                salt: salt,
                metadataHash: bytes32(0)
            })
        );
        keys[i] = key;
        quotes[i] = quote;
        coins[i] = coin;
    }

    /// CREATE address for nonces below 0x80 (RLP: 0xd6 0x94 <address> <nonce>).
    function _createAddress(address deployer, uint256 nonce) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xd6), bytes1(0x94), deployer, bytes1(uint8(nonce)))))));
    }

    // --- actions -----------------------------------------------------------

    function _pool(uint256 seed) internal pure returns (uint256) {
        return seed % POOLS;
    }

    function _snapshotOthers(uint256 touched) internal view returns (bytes32[POOLS] memory out) {
        for (uint256 j; j < POOLS; ++j) {
            if (j == touched) continue;
            PoolId id = keys[j].toId();
            bytes memory refs;
            for (uint256 a; a < ACCOUNTS; ++a) {
                refs = abi.encodePacked(refs, hook.referrerPending(id, accounts[a]));
            }
            out[j] = keccak256(abi.encode(hook.poolInfo(id), refs));
        }
    }

    function _checkOthers(uint256 touched, bytes32[POOLS] memory before_) internal {
        bytes32[POOLS] memory after_ = _snapshotOthers(touched);
        for (uint256 j; j < POOLS; ++j) {
            if (j != touched && after_[j] != before_[j]) ghostCrossPoolWrites++;
        }
    }

    function _hookData(uint256 seed) internal view returns (bytes memory) {
        uint256 kind = seed % 6;
        if (kind == 0) return "";
        if (kind == 1) return new bytes(31);
        if (kind == 2) return abi.encodePacked(bytes32(type(uint256).max));
        if (kind == 3) return abi.encodePacked(bytes32(uint256(uint160(accounts[(seed >> 8) % ACCOUNTS]))), bytes1(0x01));
        return abi.encode(accounts[(seed >> 8) % ACCOUNTS]);
    }

    function _amount(uint256 seed) internal pure returns (uint256) {
        uint256 magnitude = 10 ** (3 + (seed % 22));
        return magnitude * (1 + ((seed >> 8) % 9));
    }

    function swap(uint256 poolSeed, bool buy, bool exactIn, uint256 amountSeed, uint256 dataSeed) public {
        uint256 i = _pool(poolSeed);
        PoolKey memory key = keys[i];
        bool coinIs0 = Currency.unwrap(key.currency0) == coins[i];
        bool zeroForOne = buy ? !coinIs0 : coinIs0;
        uint256 amount = _amount(amountSeed);
        if (!buy && exactIn) {
            uint256 held = MockERC20(coins[i]).balanceOf(address(router));
            if (held == 0) return;
            if (amount > held) amount = held;
        }
        bytes32[POOLS] memory before_ = _snapshotOthers(i);
        try router.swap(
            key.up(),
            ICLPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: exactIn ? -int256(amount) : int256(amount),
                sqrtPriceLimitX96: zeroForOne ? MIN_SQRT + 1 : MAX_SQRT - 1
            }),
            _hookData(dataSeed)
        ) {
            ghostSwapsLanded++;
        } catch (bytes memory reason) {
            (bool fromHook, bool declared, bytes memory inner) = _classify(reason);
            if (fromHook && !declared) {
                ghostUndeclaredHookReverts++;
                ghostLastUndeclared = inner;
                return;
            }
            revert Refused(fromHook, inner);
        }
        _checkOthers(i, before_);
        _checkMonotone();
    }

    /// Declared hook refusals on a swap: R18 (specified-quote partial fill), R5 (opening cap),
    /// and v1.6's `openAt` gate (NotOpenYet), which is zero for every ordinary coin.
    function _classify(bytes memory reason) internal view returns (bool fromHook, bool declared, bytes memory inner) {
        if (reason.length >= 4 && bytes4(reason) == CustomRevert.WrappedError.selector) {
            bytes memory body = new bytes(reason.length - 4);
            for (uint256 k; k < body.length; ++k) {
                body[k] = reason[k + 4];
            }
            address target;
            (target,, inner,) = abi.decode(body, (address, bytes4, bytes, bytes));
            if (target == address(hook)) {
                bytes4 sel = inner.length >= 4 ? bytes4(inner) : bytes4(0);
                return (
                    true,
                    sel == FeastHook.PartialFillNotSupported.selector || sel == FeastHook.PurchaseCapExceeded.selector,
                    inner
                );
            }
        }
        return (false, false, reason);
    }

    function claim(uint256 poolSeed, uint256 accountSeed) public {
        uint256 i = _pool(poolSeed);
        PoolKey memory key = keys[i];
        PoolId id = key.toId();
        address account = accounts[accountSeed % ACCOUNTS];
        if (i == 1 && accountSeed % 7 == 0) account = FeastConstants.BURN_ADDRESS;
        bool isCreator = hook.poolInfo(id).creator == account;
        uint256 creatorBefore = isCreator ? hook.creatorPending(id) : 0;
        uint256 refBefore = hook.referrerPending(id, account);
        uint256 balBefore = MockERC20(quotes[i]).balanceOf(account);
        uint256 selfBal = MockERC20(quotes[i]).balanceOf(address(this));
        bytes32[POOLS] memory before_ = _snapshotOthers(i);
        hook.claim(key, account);
        uint256 paidCreator = creatorBefore - (isCreator ? hook.creatorPending(id) : 0);
        uint256 paidRef = refBefore - hook.referrerPending(id, account);
        ghostReferrerPaid[i][account] += paidRef;
        if (paidCreator + paidRef != 0) ghostClaimsPaid++;
        if (MockERC20(quotes[i]).balanceOf(account) - balBefore != paidCreator + paidRef) ghostMisdirectedPayments++;
        if (MockERC20(quotes[i]).balanceOf(address(this)) != selfBal) ghostMisdirectedPayments++;
        _checkOthers(i, before_);
        _checkMonotone();
    }

    function buyBack(uint256 poolSeed, uint256 amountSeed) public {
        uint256 i = _pool(poolSeed);
        bytes32[POOLS] memory before_ = _snapshotOthers(i);
        hook.buyBackAndBurn(keys[i], _amount(amountSeed));
        ghostBuybacksLanded++;
        _checkOthers(i, before_);
        _checkMonotone();
    }

    function collect(uint256 poolSeed) public {
        uint256 i = _pool(poolSeed);
        bytes32[POOLS] memory before_ = _snapshotOthers(i);
        uint256 accrued = hook.poolInfo(keys[i].toId()).accruedQuote;
        hook.collectLpFees(keys[i]);
        if (hook.poolInfo(keys[i].toId()).accruedQuote > accrued) ghostCollectsBanked++;
        _checkOthers(i, before_);
        _checkMonotone();
    }

    /// v1.6's internal fill banks coin claims; this is the only path that retires them.
    function burnFilled(uint256 poolSeed) public {
        uint256 i = _pool(poolSeed);
        bytes32[POOLS] memory before_ = _snapshotOthers(i);
        uint256 pendingBefore = hook.filledCoinPending(keys[i].toId());
        hook.burnFilledCoin(keys[i]);
        if (pendingBefore > hook.filledCoinPending(keys[i].toId())) ghostFilledCoinBurned++;
        _checkOthers(i, before_);
        _checkMonotone();
    }

    /// Time only moves forward: Medusa advances block.timestamp itself, and warping behind the
    /// chain's own time made the allowance clock underflow in the first trial.
    function elapse(uint256 secondsSeed) public {
        uint256 base = block.timestamp > clock ? block.timestamp : clock;
        clock = base + 1 + (secondsSeed % 7_200);
        HEVM.warp(clock);
        HEVM.roll(block.number + 1);
    }

    function freeze(bool paused) public {
        quoteFrozen.setPaused(paused);
    }

    function _checkMonotone() internal {
        for (uint256 i; i < POOLS; ++i) {
            FeastHook.Pool memory p = hook.poolInfo(keys[i].toId());
            uint256[4] memory now_ = [p.selfBurnEarned, p.platformEarned, p.creatorEarned, p.referrerEarned];
            for (uint256 b; b < 4; ++b) {
                if (now_[b] < lastEarned[i][b]) ghostDecreases++;
            }
            lastEarned[i] = now_;
        }
    }

    // --- checks: (holds, why) ----------------------------------------------

    function checkConservation() public view returns (bool, string memory) {
        for (uint256 i; i < POOLS; ++i) {
            FeastHook.Pool memory p = hook.poolInfo(keys[i].toId());
            if (p.selfBurnEarned + p.platformEarned + p.creatorEarned + p.referrerEarned != p.accruedQuote) {
                return (false, "buckets do not sum to accruedQuote");
            }
        }
        return (true, "");
    }

    /// The hook's Vault claim balance in each quote equals, to the wei, the sum of every bucket
    /// still pending across all pools denominated in that quote.
    function checkSolvency() public view returns (bool, string memory) {
        address[2] memory qs = [address(quoteShared), address(quoteFrozen)];
        for (uint256 q; q < 2; ++q) {
            uint256 owed;
            for (uint256 i; i < POOLS; ++i) {
                if (quotes[i] != qs[q]) continue;
                PoolId id = keys[i].toId();
                owed += hook.selfBurnPending(id) + hook.platformPending(id) + hook.creatorPending(id);
                for (uint256 a; a < ACCOUNTS; ++a) {
                    owed += hook.referrerPending(id, accounts[a]);
                }
            }
            uint256 held = vault.balanceOf(address(hook), UpCurrency.wrap(qs[q]));
            if (held != owed) {
                return (false, held > owed ? "claims exceed what is owed (value stranded)" : "claims short of what is owed (insolvent)");
            }
        }
        return (true, "");
    }

    /// v1.6: the internal fill's coin claims equal what the ledger says is pending, per pool.
    function checkFilledCoinBacked() public view returns (bool, string memory) {
        for (uint256 i; i < POOLS; ++i) {
            PoolId id = keys[i].toId();
            uint256 held = vault.balanceOf(address(hook), UpCurrency.wrap(coins[i]));
            if (held != hook.filledCoinPending(id)) return (false, "filled-coin claims do not match the pool's pending fill");
        }
        return (true, "");
    }

    function checkReferrerLedger() public view returns (bool, string memory) {
        for (uint256 i; i < POOLS; ++i) {
            PoolId id = keys[i].toId();
            uint256 sum;
            for (uint256 a; a < ACCOUNTS; ++a) {
                sum += hook.referrerPending(id, accounts[a]) + ghostReferrerPaid[i][accounts[a]];
            }
            if (sum != hook.poolInfo(id).referrerEarned) return (false, "referrer ledger does not reconcile");
        }
        return (true, "");
    }

    function checkNothingStrandsAndPlatformIsUnspent() public view returns (bool, string memory) {
        if (hook.poolInfo(keys[1].toId()).creatorEarned != 0) return (false, "burn-address creator banked a share");
        // No genesis in this harness, so no sink is bound and the platform exit cannot run.
        for (uint256 i; i < POOLS; ++i) {
            if (hook.poolInfo(keys[i].toId()).platformUsed != 0) return (false, "platform bucket spent with no sink bound");
        }
        return (true, "");
    }

    function checkGhosts() public view returns (bool, string memory) {
        if (ghostUndeclaredHookReverts != 0) return (false, "a swap reverted inside the hook for an undeclared reason");
        if (ghostCrossPoolWrites != 0) return (false, "an action on one pool wrote another pool's state");
        if (ghostDecreases != 0) return (false, "a running total decreased");
        if (ghostMisdirectedPayments != 0) return (false, "a claim paid someone other than the recorded owner, or the wrong amount");
        return (true, "");
    }
}
