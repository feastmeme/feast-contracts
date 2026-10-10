// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {FeastConstants} from "../../src/FeastConstants.sol";
import {FeastConverter} from "../../src/FeastConverter.sol";
import {FeastFactory} from "../../src/FeastFactory.sol";
import {FeastFeeLedger} from "../../src/FeastFeeLedger.sol";
import {FeastGenesis} from "../../src/FeastGenesis.sol";
import {FeastHook} from "../../src/FeastHook.sol";
import {FeastReferrals} from "../../src/FeastReferrals.sol";
import {FeastOracle} from "../../src/FeastOracle.sol";
import {FeastPlatformToken} from "../../src/FeastPlatformToken.sol";
import {FeastPlatformTokenDeployer} from "../../src/FeastPlatformTokenDeployer.sol";
import {FeastVesting} from "../../src/FeastVesting.sol";
import {Currency} from "../../src/venue/Currency.sol";
import {IFeastCLHooks} from "../../src/venue/IFeastCLHooks.sol";
import {PoolId, PoolIdLibrary} from "../../src/venue/PoolId.sol";
import {PoolKey} from "../../src/venue/PoolKey.sol";

import {Vault} from "infinity-core/src/Vault.sol";
import {CLPoolManager} from "infinity-core/src/pool-cl/CLPoolManager.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {CustomRevert} from "infinity-core/src/libraries/CustomRevert.sol";
import {Hooks} from "infinity-core/src/libraries/Hooks.sol";

import {MockERC20} from "./MockERC20.sol";
import {PoolRouter} from "./PoolRouter.sol";
import {VenueBridge} from "./VenueBridge.sol";

import {FeastGuardian} from "../../../src/FeastGuardian.sol";
/// @dev A recipient with code. Genesis refuses a code-less one, because tokens
///      sent to an address nobody has deployed to are stranded for ever.
contract Holder {}

/// @dev The launch window's stand-in: a router the tests trade through, which
///      reports the window's role.
contract RoleRouter is PoolRouter {
    bytes32 public constant genesisRole = keccak256("feast.genesis.launch-window");
    address public immutable platformCoin;
    /// @dev v1.6.2: the sink reads its opening from the window genesis names,
    ///      so a stand-in window has to be able to say when it closes.
    uint64 public immutable endsAt;

    constructor(Vault vault_, CLPoolManager pm_, address platformCoin_) PoolRouter(vault_, pm_) {
        platformCoin = platformCoin_;
        endsAt = uint64(block.timestamp + 7 days);
    }

    /// @dev v1.6.12: genesis asks the window whether the position its opening
    ///      tick implies can actually be placed, so a stand-in has to be able to
    ///      answer — the same reason it was taught `endsAt` at v1.6.2 and the
    ///      role holder was taught `start` at v1.6.10.
    ///
    ///      A plausible non-zero answer, not the real formula. These fixtures
    ///      are about the genesis ceremony and the gate; the opening BOUND is
    ///      pinned against the real window by
    ///      `test/audit/poc/NoCommitOpeningUnsettleable.t.sol` and by
    ///      `test/FeastWindowAuction.t.sol`, both of which run the real one.
    function openingLiquidityFor(uint256, int24) external pure returns (uint128) {
        return 1e18;
    }

    /// @dev v1.6.21: genesis asks the window which pool it is keyed to, so a
    ///      stand-in has to be able to answer — the same reason it was taught
    ///      `endsAt` at v1.6.2 and `openingLiquidityFor` at v1.6.12. Set by the
    ///      fixture once the factory exists, because the answer has to BE the
    ///      key the factory will build.
    PoolKey internal _key;

    function setPoolKey(PoolKey memory k) external {
        _key = k;
    }

    function poolKey() external view returns (PoolKey memory) {
        return _key;
    }

    /// @dev v1.6.22: genesis asks the window the whole of what its settlement
    ///      calls — the factory it seeds through, the hook whose gate it reads,
    ///      the token its pot is in (`FeastFactory._questions`); the pool
    ///      manager it initialises through is `PoolRouter.poolManager` already.
    ///      Taught by the fixture, for the same reason as `setPoolKey`: the
    ///      answers have to BE the factory's own.
    address public factory;
    address public hook;
    address public wrappedNative;

    function setWiring(address factory_, address hook_, address wrappedNative_) external {
        factory = factory_;
        hook = hook_;
        wrappedNative = wrappedNative_;
    }
}

/// @dev A genesis recipient that says what it is — the stand-in for a package-2
///      contract. Any contract that does not implement the answer is refused.
contract RoleHolder {
    bytes32 public immutable genesisRole;
    address public immutable platformCoin;
    /// @dev v1.6.10: genesis now asks the team wallet when its vesting starts
    ///      and refuses any answer but the window's close, so a stand-in for
    ///      that role has to be able to say — exactly as the stand-in window
    ///      was taught to say when it closes at v1.6.2. Zero for every other
    ///      role, which genesis never asks.
    uint256 public immutable start;
    /// @dev v1.6.21: and genesis now asks a sink that already has code whether
    ///      it is armed, for the same reason and by the same rule — a stand-in
    ///      for a role genesis interrogates has to be able to answer. Zero for
    ///      every other role, which genesis never asks.
    uint64 public immutable opensAt;
    /// @dev v1.6.21: and genesis now asks the team wallet whose brake it reads.
    address public immutable guardian;

    constructor(bytes32 role_, address platformCoin_, uint256 start_, uint64 opensAt_, address guardian_) {
        genesisRole = role_;
        platformCoin = platformCoin_;
        start = start_;
        opensAt = opensAt_;
        guardian = guardian_;
    }

    /// @dev v1.6.22: genesis asks every recipient the whole of what it will be
    ///      trusted with (`FeastFactory._questions`), so a stand-in for a role
    ///      genesis interrogates must be able to answer all of it — the same
    ///      rule that taught it `start` at v1.6.10 and `guardian` and `opensAt`
    ///      at v1.6.21. Zero until taught: a stand-in built ad hoc to be refused
    ///      for its role or its coin is never asked any of these.
    uint256 public duration;
    address public hook;
    PoolId public platformPoolId;
    address public ledger;
    uint256 public budget;
    address public emissions;
    uint256 public grant;

    function teach(
        uint256 duration_,
        address hook_,
        PoolId platformPoolId_,
        address ledger_,
        uint256 budget_,
        address emissions_,
        uint256 grant_
    ) external {
        duration = duration_;
        hook = hook_;
        platformPoolId = platformPoolId_;
        ledger = ledger_;
        budget = budget_;
        emissions = emissions_;
        grant = grant_;
    }
}

///
/// What is held here is what the owner promised publicly: 60 / 25 / 15 to the
/// exact unit, the platform coin's own terms (burn creator, 20% self-burn, 10%
/// referral), a pool no one but the launch window can trade until `openAt`, a
/// voting token that can never be minted again — and afterwards, no privileged
/// caller anywhere in package 1.
///
/// The 20% and the 10% in that sentence are the pool's FEE terms and are not
/// the team's share; the team's is the 25%. Four different 20%s live in this
/// repository and only one of them moved.
/// @dev The package-1 wiring in the recipe's order, plus stand-in genesis
///      recipients. Shared by the genesis and authority suites.
abstract contract GenesisFixture is Test {
    using PoolIdLibrary for PoolKey;
    using VenueBridge for PoolKey;

    uint160 internal constant SQRT_PRICE_1_1 = 79_228_162_514_264_337_593_543_950_336;
    uint160 internal constant MIN_SQRT = 4_295_128_739 + 1;
    uint160 internal constant MAX_SQRT = 1_461_446_703_485_210_103_287_273_052_203_988_822_378_723_970_342 - 1;
    uint256 internal constant SUPPLY = FeastGenesis.PLATFORM_SUPPLY;

    address internal genesisKey = address(0x6E7E5);
    address internal stranger = address(0x5712A);

    Vault internal vault;
    CLPoolManager internal pm;
    FeastFeeLedger internal ledger;
    FeastGuardian internal guardian;
    FeastHook internal hook;
    FeastReferrals internal referrals;
    FeastVesting internal vesting;
    FeastPlatformTokenDeployer internal deployer;
    FeastFactory internal factory;
    MockERC20 internal wbnb;

    RoleRouter internal window;
    PoolRouter internal router;
    address internal teamVesting;
    address internal emissions;
    address internal grants;
    address internal sink;

    uint256 internal clock;

    function setUp() public {
        clock = 1_791_158_400; // a Monday
        vm.warp(clock);
        vault = new Vault();
        pm = new CLPoolManager(vault);
        vault.registerApp(address(pm));
        wbnb = new MockERC20("Wrapped", "WBNB", 18);

        // The package-1 order the recipe prescribes.
        // Deployed BEFORE the nonce is read, so the predicted addresses below
        // still land: every CREATE from here on shifts by one otherwise.
        // The referral registry (v1.6.26) has no constructor and no immutables, so
        // its deployed code is the whole of it: etched, it spends none of this
        // contract's nonce — under `isolate` even `deployCodeTo`'s constructor call
        // is a transaction that moves it — and every address below, the tokens' and
        // the platform coin's CREATE2 draw included, is the one it was before.
        referrals = FeastReferrals(address(uint160(uint256(keccak256("feast.referrals")))));
        vm.etch(address(referrals), vm.getDeployedCode("FeastReferrals.sol:FeastReferrals"));
        uint64 n = vm.getNonce(address(this));
        address predictedHook = vm.computeCreateAddress(address(this), n + 4);
        address predictedFactory = vm.computeCreateAddress(address(this), n + 7);
        // The guardian is deployed FIRST of the contracts whose addresses are
        // predicted above, so the offsets there already count it; it takes the
        // factory's predicted address because only the factory may start its clock.
        guardian = new FeastGuardian(address(0x3517), predictedFactory);
        FeastOracle oracle = new FeastOracle(predictedHook);
        FeastConverter converter = new FeastConverter(address(0xF3), address(wbnb), predictedHook);
        ledger = new FeastFeeLedger(predictedHook);
        hook = new FeastHook(
            address(pm), address(vault), predictedFactory, address(oracle), address(ledger), address(converter),
            address(guardian), address(referrals), new FeastHook.TipFloor[](0)
        );
        vesting = new FeastVesting(predictedFactory, address(guardian));
        deployer = new FeastPlatformTokenDeployer(predictedFactory);
        factory = new FeastFactory(
            address(pm), address(vault), address(hook), address(vesting), address(deployer), address(wbnb), genesisKey
        );
        assertEq(address(hook), predictedHook, "hook wiring");
        assertEq(address(factory), predictedFactory, "factory wiring");

        window = new RoleRouter(vault, pm, factory.predictPlatformCoin());
        router = new PoolRouter(vault, pm);
        address coin = factory.predictPlatformCoin();
        teamVesting = address(new RoleHolder(FeastGenesis.ROLE_TEAM_VESTING, coin, window.endsAt(), 0, address(guardian)));
        // v1.6.22: every recipient is asked whose brake it reads, so every
        // stand-in reads this one — until then only the team wallet was asked.
        emissions = address(new RoleHolder(FeastGenesis.ROLE_EMISSIONS, coin, 0, 0, address(guardian)));
        grants = address(new RoleHolder(FeastGenesis.ROLE_GRANTS, coin, 0, 0, address(guardian)));
        sink = address(new RoleHolder(FeastGenesis.ROLE_PLATFORM_SINK, coin, 0, window.endsAt(), address(guardian)));
        // The stand-in window is keyed to the pool the factory will build, and
        // wired to the factory, hook and wrapped native it will settle through.
        window.setPoolKey(factory.platformPoolKey());
        window.setWiring(address(factory), address(hook), address(wbnb));
        // And each stand-in knows the rest of what genesis asks it: the answers
        // a genuine recipient built for this deployment would give.
        _teachTheRestOfTheSet(RoleHolder(teamVesting));
        _teachTheRestOfTheSet(RoleHolder(emissions));
        _teachTheRestOfTheSet(RoleHolder(grants));
        _teachTheRestOfTheSet(RoleHolder(sink));
    }

    /// @dev One set of answers for all four: each role is asked only its own
    ///      questions (`FeastFactory._questions`), so the rest go unread.
    function _teachTheRestOfTheSet(RoleHolder r) internal {
        r.teach(
            FeastGenesis.TEAM_VESTING_DURATION,
            address(hook),
            factory.platformPoolKey().toId(),
            address(ledger),
            SUPPLY * FeastGenesis.EMISSIONS_BPS / FeastGenesis.BPS,
            emissions,
            SUPPLY * FeastGenesis.GRANT_BPS_EACH / FeastGenesis.BPS
        );
    }

    function _params() internal view returns (FeastFactory.GenesisParams memory) {
        uint256 poolAmount = SUPPLY * FeastGenesis.POOL_BPS / FeastGenesis.BPS;
        return FeastFactory.GenesisParams({
            window: address(window),
            openAt: uint64(window.endsAt() + FeastGenesis.SETTLE_GRACE),
            teamVesting: teamVesting,
            emissions: emissions,
            grants: grants,
            platformSink: sink,
            sqrtPriceX96: SQRT_PRICE_1_1,
            metadataHash: keccak256("feast.metadata")
        });
    }

    function _genesis() internal returns (address feast, PoolKey memory key) {
        // Build the params BEFORE the prank. From v1.6.10 `_params()` reads the
        // window's close through an external call, and an external call between
        // `vm.prank` and the call being pranked consumes the prank — genesis
        // then runs as the test contract and reverts `NotGenesisKey()`.
        FeastFactory.GenesisParams memory p = _params();
        vm.prank(genesisKey);
        (feast, key) = factory.genesis(p);
    }

}
