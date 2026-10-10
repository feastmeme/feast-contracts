// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {FeastConstants} from "../src/FeastConstants.sol";
import {FeastEmissions} from "../src/FeastEmissions.sol";
import {FeastFactory} from "../src/FeastFactory.sol";
import {FeastGenesis} from "../src/FeastGenesis.sol";
import {FeastPricer} from "../src/FeastPricer.sol";
import {Currency} from "../src/venue/Currency.sol";
import {PoolKey} from "../src/venue/PoolKey.sol";
import {PoolIdLibrary} from "../src/venue/PoolId.sol";
import {IFeastCLPoolManager} from "../src/venue/IFeastCLPoolManager.sol";
import {IPancakeV3Factory, IPancakeV3Pool} from "../src/venue/IPancakeV3.sol";

import {CLPoolManager} from "infinity-core/src/pool-cl/CLPoolManager.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {Vault} from "infinity-core/src/Vault.sol";

import {DeployPackage1} from "../script/DeployPackage1.s.sol";
import {DeployPackage2} from "../script/DeployPackage2.s.sol";
import {FeastScriptChecks} from "../script/FeastScriptChecks.sol";
import {Genesis} from "../script/Genesis.s.sol";

import {PoolRouter} from "./utils/PoolRouter.sol";
import {VenueBridge} from "./utils/VenueBridge.sol";

/// The deployment recipe, as scripts: each refuses the genesis file as
/// committed, and — given explicit inputs — the whole of v1.6 is deployed and
/// run end to end on the real venue at the pinned block, in the README's order.
contract FeastRecipeTest is Test {
    using PoolIdLibrary for PoolKey;
    using VenueBridge for PoolKey;

    uint256 internal constant FORK_BLOCK = 120_721_477;
    address internal constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address internal constant USDT = 0x55d398326f99059fF775485246999027B3197955;
    address internal constant AAPLB = 0x431a3BEE82E2ca41e49895CbECE5bB0F76A89b7A;
    address internal constant AAPLB_HOLDER = 0xe9b9998B2EC5430D2246c7f1F8D9f298c97D7365;
    address internal constant V3_FACTORY = 0x0BFbCF9fa4f9C56B0F40a671Ad40E0805A091865;
    uint160 internal constant SQRT_PRICE_1_1 = 79_228_162_514_264_337_593_543_950_336;
    uint160 internal constant MIN_SQRT = 4_295_128_740;
    uint160 internal constant MAX_SQRT = 1_461_446_703_485_210_103_287_273_052_203_988_822_378_723_970_341;

    // --- the refusals (no RPC needed) ------------------------------------------

    function refusePackage2() external pure {
        FeastScriptChecks.requirePackage2();
    }

    function refuseGenesis() external pure {
        FeastScriptChecks.requireGenesis();
    }

    /// Kills: a script that deploys with an unset placeholder.
    function test_theScriptsRefuseTheGenesisFileAsCommitted() public {
        vm.expectRevert(abi.encodeWithSelector(FeastScriptChecks.Placeholder.selector, "PACKAGE1_FACTORY"));
        this.refusePackage2();
        vm.expectRevert(abi.encodeWithSelector(FeastScriptChecks.Placeholder.selector, "PACKAGE1_FACTORY"));
        this.refuseGenesis();
    }

    // --- the whole recipe, on the real venue -------------------------------------

    function _buy(PoolRouter router, PoolKey memory key, address quote, uint256 amount, address origin, address ref) internal {
        bool zeroForOne = Currency.unwrap(key.currency0) == quote;
        vm.prank(origin, origin);
        router.swap(
            key.up(),
            ICLPoolManager.SwapParams({zeroForOne: zeroForOne, amountSpecified: -int256(amount), sqrtPriceLimitX96: zeroForOne ? MIN_SQRT : MAX_SQRT}),
            ref == address(0) ? bytes("") : abi.encode(ref)
        );
    }

    function test_fork_theWholeRecipeRunsEndToEnd() public {
        string memory url = vm.envOr("BSC_RPC_URL", string(""));
        if (bytes(url).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(url, FORK_BLOCK);
        uint256 t0 = block.timestamp;
        address trader = address(0x7EADE1);
        address referrer = address(0xEE01);

        // Package 1 — the genesis key is the genesis script, which will make the call.
        Genesis g = new Genesis();
        DeployPackage1 d1 = new DeployPackage1();
        DeployPackage1.Package1 memory p1 = d1.deployPackage1(address(g), address(d1));
        FeastFactory factory = p1.factory;

        // Package 2's core, at the opening: AAPLB priced through USDT.
        DeployPackage2 d2 = new DeployPackage2();
        DeployPackage2.Inputs memory in2;
        in2.factory = factory;
        in2.multisig = address(0x3517);
        in2.targetNative = 1e18;
        in2.factoryOpening = t0;
        for (uint256 i = 0; i < 8; i++) in2.partners[i] = address(uint160(0xAA00 + i));
        in2.routes = new FeastPricer.Route[](1);
        in2.routes[0].quote = AAPLB;
        in2.routes[0].pools = new address[](2);
        in2.routes[0].pools[0] = IPancakeV3Factory(V3_FACTORY).getPool(AAPLB, USDT, 2500);
        in2.routes[0].pools[1] = IPancakeV3Factory(V3_FACTORY).getPool(USDT, WBNB, 500);
        // v1.6.25 (AstraSec Q-3): the recipe's step 2, which the pricer now
        // checks at listing. Every routed pool is asked for a ring of
        // `MIN_RING_CARDINALITY`; anyone may, and the lister pays. The AAPLB
        // pool's live ring stays at one until its next write, which this fork
        // never makes, so week 1 below still waits out the grace.
        for (uint256 h = 0; h < in2.routes[0].pools.length; h++) {
            IPancakeV3Pool(in2.routes[0].pools[h]).increaseObservationCardinalityNext(
                FeastConstants.MIN_RING_CARDINALITY
            );
        }
        DeployPackage2.Package2 memory p2 = d2.deployPackage2(in2);

        // Ordinary coins trade from the opening: one against WBNB, one against AAPLB.
        PoolRouter router = new PoolRouter(Vault(FeastGenesis.VAULT), CLPoolManager(FeastGenesis.CL_POOL_MANAGER));
        (, PoolKey memory kA) = factory.create(_params(WBNB, bytes32(uint256(1))));
        (, PoolKey memory kB) = factory.create(_params(AAPLB, bytes32(uint256(2))));
        vm.roll(vm.getBlockNumber() + 3);
        deal(WBNB, address(router), 20e18);
        vm.prank(AAPLB_HOLDER);
        IERC20(AAPLB).transfer(address(router), 20e18);
        _buy(router, kA, WBNB, 10e18, trader, referrer);
        _buy(router, kB, AAPLB, 10e18, trader, address(0));

        // Week 1 settles before the platform coin exists: the token cap alone.
        uint256 week1End = p1.ledger.weekStart(p2.emissions.ledgerWeekOf(1) + 1);
        vm.warp(week1End);
        try p2.emissions.settle(1) {}
        catch {
            // A route pool that cannot vouch (the sample stock's pool holds one
            // observation at this block) waits out the grace, then counts zero.
            vm.warp(week1End + FeastGenesis.PRICING_GRACE);
            p2.emissions.settle(1);
        }
        assertTrue(p2.emissions.weekInfo(1).tokenCapOnly, "settled under the first-week rule");

        // The TGE: window and vesting deployed, one genesis call.
        uint256 windowEnd = ((block.timestamp + 3 days) / 7 days + 1) * 7 days - 3 days; // the next Monday
        uint64 windowStart = uint64(windowEnd - FeastGenesis.WINDOW_DURATION);
        vm.warp(windowStart - 1 days);
        Genesis.Launched memory l = g.launch(
            Genesis.Inputs({
                factory: factory,
                emissions: address(p2.emissions),
                grants: address(p2.grants),
                sink: address(p2.sink),
                beneficiary: address(0x7EA3),
                windowStart: windowStart,
                sqrtPriceX96: SQRT_PRICE_1_1,
                metadataHash: keccak256("feast")
            })
        );
        assertEq(l.platformCoin, factory.predictPlatformCoin(), "the coin package 2 was built against");

        // The window: a real BNB commit, one swap, claims.
        address alice = address(0xA11CE);
        vm.deal(alice, 5e18);
        vm.warp(windowStart);
        vm.prank(alice);
        l.window.commit{value: 5e18}();
        vm.warp(l.window.endsAt());
        l.window.settle();
        vm.warp(l.window.endsAt() + FeastGenesis.SETTLE_GRACE);
        l.window.claim(alice);
        assertGt(IERC20(l.platformCoin).balanceOf(alice), 0, "the committer holds the platform coin");

        // Week 1's pots are claimable now the pool is open.
        uint256 owed = p2.emissions.owed(1, trader);
        assertGt(owed, 0, "the day-one trader earned FEAST");
        p2.emissions.claim(1, trader);
        assertEq(IERC20(l.platformCoin).balanceOf(trader), owed, "and is paid it");

        // v1.6.11: the auction's one percent of the pot reaches the sink as
        // wrapped native at settlement, straight from the window — it does not
        // pass through the hook and is recorded in no ledger. So the sink's
        // WBNB balance is no longer only what the hook releases, and the two
        // arrivals are asserted separately rather than summed by accident.
        assertEq(
            IERC20(WBNB).balanceOf(address(p2.sink)),
            5e18 / 100,
            "the auction's one percent of a five-ether pot, in wrapped native"
        );

        // The platform share of an ordinary coin leaves to the sink.
        uint256 pending = p1.hook.platformPending(kA.toId());
        uint256 sinkBefore = IERC20(WBNB).balanceOf(address(p2.sink));
        p1.hook.releasePlatformFees(kA);
        assertEq(
            IERC20(WBNB).balanceOf(address(p2.sink)) - sinkBefore, pending, "delivered as the asset itself"
        );
        assertTrue(p2.emissions.claimsOpen(), "claims open");
    }

    /// The auction, on the real venue, at the pinned block: a real BNB pot
    /// clears at one price, the pool opens AT that price, and both sides of it
    /// are seeded — the properties the unit fixtures pin, re-checked against
    /// PancakeSwap Infinity's own `CLPoolManager` rather than an in-process one.
    ///
    /// @dev It repeats the deployment the recipe test above performs. That is
    ///      deliberate: the recipe test interleaves ordinary-coin trading and a
    ///      week-1 settlement between genesis and the TGE, and those are part of
    ///      what IT pins. Folding both into one helper would have made each test
    ///      depend on the other's calendar.
    function test_fork_theAuctionSettlesOnTheRealVenue() public {
        string memory url = vm.envOr("BSC_RPC_URL", string(""));
        if (bytes(url).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(url, FORK_BLOCK);
        uint256 t0 = block.timestamp;

        Genesis g = new Genesis();
        DeployPackage1 d1 = new DeployPackage1();
        DeployPackage1.Package1 memory p1 = d1.deployPackage1(address(g), address(d1));

        DeployPackage2 d2 = new DeployPackage2();
        DeployPackage2.Inputs memory in2;
        in2.factory = p1.factory;
        in2.multisig = address(0x3517);
        in2.targetNative = 1e18;
        in2.factoryOpening = t0;
        for (uint256 i = 0; i < 8; i++) in2.partners[i] = address(uint160(0xAA00 + i));
        in2.routes = new FeastPricer.Route[](0);
        DeployPackage2.Package2 memory p2 = d2.deployPackage2(in2);

        uint256 windowEnd = ((block.timestamp + 3 days) / 7 days + 1) * 7 days - 3 days;
        uint64 windowStart = uint64(windowEnd - FeastGenesis.WINDOW_DURATION);
        vm.warp(windowStart - 1 days);
        Genesis.Launched memory l = g.launch(
            Genesis.Inputs({
                factory: p1.factory,
                emissions: address(p2.emissions),
                grants: address(p2.grants),
                sink: address(p2.sink),
                beneficiary: address(0x7EA3),
                windowStart: windowStart,
                sqrtPriceX96: SQRT_PRICE_1_1,
                metadataHash: keccak256("feast")
            })
        );
        PoolKey memory key = p1.factory.poolKeyFor(l.platformCoin);
        bool coinIsCurrency0 = Currency.unwrap(key.currency0) == l.platformCoin;

        // The pool does not exist yet: the price it must open at is the price
        // the auction has not cleared.
        (uint160 beforeSettle,,,) = IFeastCLPoolManager(FeastGenesis.CL_POOL_MANAGER).getSlot0(key.toId());
        assertEq(beforeSettle, 0, "genesis leaves the platform pool uninitialised");

        address alice = address(0xA11CE);
        address bob = address(0xB0B);
        vm.deal(alice, 4e18);
        vm.deal(bob, 6e18);
        vm.warp(windowStart);
        vm.prank(alice);
        l.window.commit{value: 4e18}();
        vm.prank(bob);
        l.window.commit{value: 6e18}();

        uint256 sinkBefore = IERC20(WBNB).balanceOf(address(p2.sink));
        // The real vault holds every other pool's reserves too, so this is a
        // delta and not a balance.
        uint256 vaultBefore = IERC20(WBNB).balanceOf(FeastGenesis.VAULT);
        vm.warp(l.window.endsAt());
        l.window.settle();

        // One price, and the pool opened at it — read in the committer's
        // direction, which is the pool's own only when the coin is currency0.
        uint160 cleared = l.window.clearingPrice();
        (uint160 opened,,,) = IFeastCLPoolManager(FeastGenesis.CL_POOL_MANAGER).getSlot0(key.toId());
        uint160 openedQuotePerCoin =
            coinIsCurrency0 ? opened : uint160(uint256(1 << 96) * uint256(1 << 96) / uint256(opened));
        assertGt(cleared, 0, "the auction cleared");
        assertLe(openedQuotePerCoin, cleared, "the pool opens at or below what every committer paid");

        // Both sides are in the vault: the net pot as the bid, the unsold half
        // of the holding as the ask.
        uint256 net = 10e18 - 10e18 / 100;
        assertApproxEqRel(
            IERC20(WBNB).balanceOf(FeastGenesis.VAULT) - vaultBefore, net, 1e12, "the net pot is the bid side"
        );
        assertEq(IERC20(WBNB).balanceOf(address(p2.sink)) - sinkBefore, 10e18 / 100, "and the 1% went to the sink");

        // One price for both, to the last unit the remainder rule can move.
        vm.warp(l.window.endsAt() + FeastGenesis.SETTLE_GRACE);
        uint256 ca = l.window.claim(alice);
        uint256 cb = l.window.claim(bob);
        assertEq(ca + cb, l.window.tranche(), "every unit of the tranche is paid");
        assertApproxEqAbs(ca * 6e18, cb * 4e18, 10e18, "the same price for both");
    }

    function _params(address quote, bytes32 salt) internal pure returns (FeastFactory.CreateParams memory) {
        return FeastFactory.CreateParams({
            name: "Coin",
            symbol: "COIN",
            supply: 1_000_000_000e18,
            quote: quote,
            creator: address(0xC0FFEE),
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
        });
    }
}
