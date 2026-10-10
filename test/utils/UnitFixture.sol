// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

import {FeastConstants} from "../../src/FeastConstants.sol";
import {FeastConverter} from "../../src/FeastConverter.sol";
import {FeastEmissions} from "../../src/FeastEmissions.sol";
import {FeastFactory} from "../../src/FeastFactory.sol";
import {FeastFeeLedger} from "../../src/FeastFeeLedger.sol";
import {FeastGenesis} from "../../src/FeastGenesis.sol";
import {FeastGenesisGrants} from "../../src/FeastGenesisGrants.sol";
import {FeastHook} from "../../src/FeastHook.sol";
import {FeastReferrals} from "../../src/FeastReferrals.sol";
import {FeastLaunchWindow} from "../../src/FeastLaunchWindow.sol";
import {FeastOracle} from "../../src/FeastOracle.sol";
import {FeastPlatformSink} from "../../src/FeastPlatformSink.sol";
import {FeastPlatformTokenDeployer} from "../../src/FeastPlatformTokenDeployer.sol";
import {FeastPricer} from "../../src/FeastPricer.sol";
import {FeastTeamVesting} from "../../src/FeastTeamVesting.sol";
import {FeastVesting} from "../../src/FeastVesting.sol";
import {Currency} from "../../src/venue/Currency.sol";
import {PoolId, PoolIdLibrary} from "../../src/venue/PoolId.sol";
import {PoolKey} from "../../src/venue/PoolKey.sol";

import {Vault} from "infinity-core/src/Vault.sol";
import {CLPoolManager} from "infinity-core/src/pool-cl/CLPoolManager.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";

import {MockERC20} from "./MockERC20.sol";
import {MockV3Pool} from "./MockV3Pool.sol";
import {MockWrappedNative} from "./MockWrappedNative.sol";
import {PoolRouter} from "./PoolRouter.sol";
import {VenueBridge} from "./VenueBridge.sol";

import {FeastGuardian} from "../../../src/FeastGuardian.sol";
/// @dev The whole of v1.6, in-process, in the recipe's order: package 1 (the
///      day-one pieces), then package 2 built against the platform coin's
///      predicted address and pool key, then — when a test asks — the one
///      genesis call and the launch window. Every collaborator is real.
abstract contract UnitFixture is Test {
    using PoolIdLibrary for PoolKey;
    using VenueBridge for PoolKey;

    uint160 internal constant SQRT_PRICE_1_1 = 79_228_162_514_264_337_593_543_950_336;
    uint160 internal constant MIN_SQRT = 4_295_128_739 + 1;
    uint160 internal constant MAX_SQRT = 1_461_446_703_485_210_103_287_273_052_203_988_822_378_723_970_342 - 1;
    uint256 internal constant SUPPLY = FeastGenesis.PLATFORM_SUPPLY;
    /// Monday 2026-10-05 00:00 UTC: the factory opens here, in ledger week W0.
    uint256 internal constant OPENING = 1_791_158_400;

    address internal genesisKey = address(0x6E7E5);
    address internal multisig = address(0x3517);
    address internal beneficiary = address(0x7EA3);
    address internal creator = address(0xC0FFEE);
    address internal trader = address(0x7EADE1);
    address internal trader2 = address(0x7EADE2);
    address internal referrer = address(0xEE01);
    uint256 internal constant TARGET = 100e18;

    Vault internal vault;
    CLPoolManager internal pm;
    PoolRouter internal router;
    MockWrappedNative internal wbnb;
    MockERC20 internal stock;
    MockV3Pool internal stockPool;

    FeastOracle internal oracle;
    FeastFeeLedger internal ledger;
    FeastGuardian internal guardian;
    FeastHook internal hook;
    FeastReferrals internal referrals;
    FeastVesting internal vesting;
    FeastPlatformTokenDeployer internal tokenDeployer;
    FeastFactory internal factory;

    address internal feast;
    PoolKey internal feastKey;
    PoolId internal feastPoolId;

    TimelockController internal timelock;
    FeastPricer internal pricer;
    FeastEmissions internal emissions;
    FeastGenesisGrants internal grants;
    FeastTeamVesting internal teamVesting;
    FeastLaunchWindow internal window;
    FeastPlatformSink internal sink;
    address[8] internal partnerList;

    uint256 internal clock;
    uint256 internal windowStart;

    function setUp() public virtual {
        clock = OPENING + 1 hours;
        vm.warp(clock);
        vault = new Vault();
        pm = new CLPoolManager(vault);
        vault.registerApp(address(pm));
        router = new PoolRouter(vault, pm);
        wbnb = new MockWrappedNative();
        stock = new MockERC20("Stock", "STKB", 18);
        stockPool = new MockV3Pool(address(stock), address(wbnb));

        // --- package 1, as the recipe deploys it ---------------------------
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
        guardian = new FeastGuardian(multisig, predictedFactory);
        oracle = new FeastOracle(predictedHook);
        FeastConverter converter = new FeastConverter(address(0xF3), address(wbnb), predictedHook);
        ledger = new FeastFeeLedger(predictedHook);
        hook = new FeastHook(
            address(pm), address(vault), predictedFactory, address(oracle), address(ledger), address(converter),
            address(guardian), address(referrals), new FeastHook.TipFloor[](0)
        );
        vesting = new FeastVesting(predictedFactory, address(guardian));
        tokenDeployer = new FeastPlatformTokenDeployer(predictedFactory);
        factory = new FeastFactory(
            address(pm), address(vault), address(hook), address(vesting), address(tokenDeployer), address(wbnb), genesisKey
        );
        require(address(factory) == predictedFactory && address(hook) == predictedHook, "wiring");

        // --- package 2, against the platform coin's predicted address -----------
        feast = factory.predictPlatformCoin();
        feastKey = _keyFor(feast, address(wbnb));
        feastPoolId = feastKey.toId();

        address[] memory proposers = new address[](1);
        proposers[0] = multisig;
        address[] memory executors = new address[](1);
        executors[0] = address(0);
        timelock = new TimelockController(FeastGenesis.TIMELOCK_DELAY, proposers, executors, address(0));

        FeastPricer.Route[] memory routes = new FeastPricer.Route[](1);
        routes[0].quote = address(stock);
        routes[0].pools = new address[](1);
        routes[0].pools[0] = address(stockPool);
        pricer = new FeastPricer(address(wbnb), address(oracle), address(pm), feast, feastPoolId, routes);

        emissions = new FeastEmissions(
            address(ledger), address(hook), feast, feastPoolId, address(timelock), address(pricer), ledger.weekOf(OPENING), address(guardian));
        for (uint256 i = 0; i < 8; i++) {
            partnerList[i] = address(uint160(0xAA00 + i));
        }
        grants = new FeastGenesisGrants(feast, address(emissions), TARGET, partnerList, address(guardian));
        sink = new FeastPlatformSink(feast, genesisKey, address(guardian));

        // The window closes on the Monday two weeks after the opening.
        windowStart = OPENING + 14 days - FeastGenesis.WINDOW_DURATION;
        window = new FeastLaunchWindow(address(wbnb), feast, address(vault), address(pm), address(hook), address(factory), feastKey, uint64(windowStart));
        teamVesting = new FeastTeamVesting(beneficiary, uint64(window.endsAt()), feast, address(guardian));

        // A stock pool that can vouch for a 1:1 price.
        stockPool.setOldestTimestamp(uint32(block.timestamp - 1 hours));
    }

    // --- helpers -------------------------------------------------------------

    function _keyFor(address coin, address quote) internal view returns (PoolKey memory) {
        (address c0, address c1) = coin < quote ? (coin, quote) : (quote, coin);
        return PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            hooks: address(hook),
            poolManager: address(pm),
            fee: FeastConstants.POOL_LP_FEE,
            parameters: hook.poolParameters()
        });
    }

    function _advance(uint256 s) internal {
        clock += s;
        vm.warp(clock);
        vm.roll(vm.getBlockNumber() + 1);
    }

    function _warpTo(uint256 t) internal {
        clock = t;
        vm.warp(clock);
        vm.roll(vm.getBlockNumber() + 1);
    }

    /// @dev The wallet that arms each pool's opening cap in `_create`. Its
    ///      purchases are one wei and no test asserts on it.
    address internal constant capWarmer = address(0xCA9CA9);

    function _create(address quote, bytes32 salt) internal returns (address coin, PoolKey memory key) {
        (coin, key) = factory.create(
            FeastFactory.CreateParams({
                name: "Coin",
                symbol: "COIN",
                supply: 1_000_000_000e18,
                quote: quote,
                creator: creator,
                selfBurnBps: 2_000,
                referrerBps: 1_000,
                prebuyQuoteIn: 0,
                minCoinsOut: 0,
                vestingDuration: 0,
                sqrtPriceX96: SQRT_PRICE_1_1,
                startTick: 0,
                liquidity: uint128(1_000_000_000e18 * 999 / 1_000),
                salt: salt,
                metadataHash: bytes32(0)
            })
        );
        // **v1.6.15: the opening cap window opens at a pool's first SERVED
        // swap**, not at its creation block, so rolling forward from creation no
        // longer clears it. Arm it here with the smallest purchase there is and
        // then roll past, so `_create` leaves a pool in the state it always
        // did: open, and out of its opening blocks.
        //
        // One wei of quote is chosen because 1% of it floors to zero: the
        // arming buy accrues no fee to any bucket, records no referral and
        // credits no ledger track, so no test that counts fees can see it. What
        // it does move is the pool price, by one wei, and the oracle's
        // observation — both below anything the suite asserts on.
        //
        // Guarded on `coin`: a test that wraps `_create` in `vm.expectRevert`
        // gets a zero return rather than a revert of its own, and a creation
        // that did not happen has no pool to arm.
        // **v1.6.16: the window is a COUNT of distinct SERVED blocks**, so
        // rolling does not leave it — a mined block that serves no trade does
        // not count, which is the whole point of the change. `CAP_BLOCKS + 1`
        // served blocks, one per block, put the pool out of its opening blocks.
        //
        // Skipped while the brake is down as well: v1.6.17's freeze covers
        // everything, so the warm-up's own buys would revert and take the
        // creation with them. A pool created under a freeze leaves its window
        // unserved, which is correct — no block it could have served was open.
        if (coin != address(0) && !guardian.isFrozenAll()) {
            for (uint256 i = 0; i <= FeastConstants.CAP_BLOCKS; i++) {
                _buy(key, quote, 1, capWarmer, address(0));
                vm.roll(vm.getBlockNumber() + 1);
            }
        } else {
            vm.roll(vm.getBlockNumber() + FeastConstants.CAP_BLOCKS);
        }
    }

    function _buy(PoolKey memory key, address quote, uint256 quoteIn, address origin, address ref) internal {
        MockERC20(quote).mint(address(router), quoteIn);
        bool zeroForOne = Currency.unwrap(key.currency0) == quote;
        vm.prank(origin, origin);
        router.swap(
            key.up(),
            ICLPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(quoteIn),
                sqrtPriceLimitX96: zeroForOne ? MIN_SQRT : MAX_SQRT
            }),
            ref == address(0) ? bytes("") : abi.encode(ref)
        );
    }

    /// @dev A pricer listing one quote through two v3 hops, each at `sqrtPriceX96`
    ///      and each forward (the input is token0), so every hop multiplies.
    ///      The quote sorts below the middle token and the middle below wrapped
    ///      native; only the quote needs code (the pricer reads its decimals).
    function _twoHopPricer(uint160 sqrtPriceX96) internal returns (FeastPricer p, address quote) {
        quote = address(0x1000);
        address middle = address(0x1001);
        require(middle < address(wbnb), "ordering");
        deployCodeTo("MockERC20.sol:MockERC20", abi.encode("Tall", "TALL", uint8(18)), quote);
        MockV3Pool first = new MockV3Pool(quote, middle);
        MockV3Pool second = new MockV3Pool(middle, address(wbnb));
        first.setSqrtPrice(sqrtPriceX96);
        second.setSqrtPrice(sqrtPriceX96);
        first.setOldestTimestamp(uint32(block.timestamp - 1 hours));
        second.setOldestTimestamp(uint32(block.timestamp - 1 hours));
        FeastPricer.Route[] memory routes = new FeastPricer.Route[](1);
        routes[0].quote = quote;
        routes[0].pools = new address[](2);
        routes[0].pools[0] = address(first);
        routes[0].pools[1] = address(second);
        p = new FeastPricer(address(wbnb), address(oracle), address(pm), feast, feastPoolId, routes);
    }

    function _genesisParams() internal view returns (FeastFactory.GenesisParams memory) {
        uint256 poolAmount = SUPPLY * FeastGenesis.POOL_BPS / FeastGenesis.BPS;
        return FeastFactory.GenesisParams({
            window: address(window),
            openAt: uint64(window.endsAt() + FeastGenesis.SETTLE_GRACE),
            teamVesting: address(teamVesting),
            emissions: address(emissions),
            grants: address(grants),
            platformSink: address(sink),
            sqrtPriceX96: SQRT_PRICE_1_1,
            metadataHash: keccak256("feast.metadata")
        });
    }

    /// @dev Genesis a day before the window opens.
    function _genesis() internal {
        if (clock < windowStart - 1 days) _warpTo(windowStart - 1 days);
        // **The sink is armed BEFORE genesis since v1.6.21**, because genesis
        // now asks a sink that already has code whether it is armed, and a sink
        // nobody armed before the window's close can never be armed at all
        // (v1.6.20 round, `P12-claude`). `schedule` reads the sink's immutable
        // predicted coin, so it has never needed genesis to have happened.
        if (sink.opensAt() == 0) {
            vm.prank(genesisKey);
            sink.schedule(address(window));
        }
        FeastFactory.GenesisParams memory p = _genesisParams();
        vm.prank(genesisKey);
        factory.genesis(p);
    }

    /// @dev Genesis, a commit, and a settled window: the platform coin trades
    ///      and claims are open.
    /// v1.6.11: **the auction does not write the oracle.** The window used to
    /// buy the pot in one swap and that swap was the platform pool's first
    /// observation; the auction clears arithmetically and seeds, so the pool
    /// opens with a price and no history and the pricer calls it `Unpriceable`
    /// — correctly, because nothing has traded (owner, 2026-09-20).
    ///
    /// A test that wants the platform coin PRICED must therefore trade it
    /// first, the way the market does within minutes of `openAt`, and let the
    /// observation age past a whole `TWAP_WINDOW` — since v1.6.24 the oracle
    /// refuses a window longer than its history rather than shortening it
    /// (AstraSec L-2), so `MIN_OBSERVATION_AGE` is no longer enough. A test that
    /// expects a price before any trade is asserting the old swap, not a property.
    function _firstPlatformTrade() internal {
        _buy(feastKey, address(wbnb), 1e15, address(0xF1257), address(0));
        _warpTo(clock + FeastConstants.TWAP_WINDOW + 1);
    }

    function _launch(uint256 commitAmount) internal {
        _genesis();
        _warpTo(windowStart + 1);
        address committer = address(0xC0D1);
        vm.deal(committer, commitAmount);
        vm.prank(committer);
        window.commit{value: commitAmount}();
        _warpTo(window.endsAt());
        window.settle();
        _warpTo(window.endsAt() + FeastGenesis.SETTLE_GRACE);
    }
}
