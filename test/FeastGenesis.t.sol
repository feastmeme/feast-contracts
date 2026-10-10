// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {FeastConstants} from "../src/FeastConstants.sol";
import {FeastConverter} from "../src/FeastConverter.sol";
import {FeastFactory} from "../src/FeastFactory.sol";
import {FeastFeeLedger} from "../src/FeastFeeLedger.sol";
import {FeastGenesis} from "../src/FeastGenesis.sol";
import {FeastHook} from "../src/FeastHook.sol";
import {FeastOracle} from "../src/FeastOracle.sol";
import {FeastPlatformToken} from "../src/FeastPlatformToken.sol";
import {FeastPlatformTokenDeployer} from "../src/FeastPlatformTokenDeployer.sol";
import {FeastVesting} from "../src/FeastVesting.sol";
import {Currency} from "../src/venue/Currency.sol";
import {IFeastCLHooks} from "../src/venue/IFeastCLHooks.sol";
import {PoolId, PoolIdLibrary} from "../src/venue/PoolId.sol";
import {PoolKey} from "../src/venue/PoolKey.sol";

import {Vault} from "infinity-core/src/Vault.sol";
import {CLPoolManager} from "infinity-core/src/pool-cl/CLPoolManager.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {CustomRevert} from "infinity-core/src/libraries/CustomRevert.sol";
import {CLPool} from "infinity-core/src/pool-cl/libraries/CLPool.sol";
import {Hooks} from "infinity-core/src/libraries/Hooks.sol";

import {MockERC20} from "./utils/MockERC20.sol";
import {PoolRouter} from "./utils/PoolRouter.sol";
import {VenueBridge} from "./utils/VenueBridge.sol";

import {GenesisFixture, Holder, RoleHolder} from "./utils/GenesisFixture.sol";

/// The platform coin's genesis: one call, once, by one key.
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
contract FeastGenesisTest is GenesisFixture {
    using PoolIdLibrary for PoolKey;
    using VenueBridge for PoolKey;

    // --- one call, once, by one key ----------------------------------------

    function test_onlyTheGenesisKeyMayCallIt() public {
        // Built first: `_params()` reads the window's close through an external
        // call from v1.6.10, and one between `expectRevert` and the call under
        // test consumes the expectation.
        FeastFactory.GenesisParams memory p = _params();
        vm.prank(stranger);
        vm.expectRevert(FeastFactory.NotGenesisKey.selector);
        factory.genesis(p);
    }

    /// Kills: a genesis that can run twice (a second mint of the platform coin).
    function test_itRunsOnceAndThenNothingIsPrivileged() public {
        _genesis();
        assertTrue(factory.genesisDone(), "done");
        FeastFactory.GenesisParams memory p = _params();
        vm.prank(genesisKey);
        vm.expectRevert(FeastFactory.GenesisAlreadyDone.selector);
        factory.genesis(p);
    }

    /// Every recipient, the sink included since v1.6.22: it used to be the one
    /// allowed to have no code yet, and the window's fee then stranded in it
    /// (`CA-8f254aa78e`).
    function test_aRecipientWithNoCodeIsRefused() public {
        address[5] memory bad =
            [address(0xDEAD01), address(0xDEAD02), address(0xDEAD03), address(0xDEAD04), address(0xDEAD05)];
        for (uint256 i = 0; i < 5; i++) {
            FeastFactory.GenesisParams memory p = _params();
            if (i == 0) p.window = bad[i];
            if (i == 1) p.teamVesting = bad[i];
            if (i == 2) p.emissions = bad[i];
            if (i == 3) p.grants = bad[i];
            if (i == 4) p.platformSink = bad[i];
            vm.prank(genesisKey);
            vm.expectRevert(abi.encodeWithSelector(FeastFactory.RecipientHasNoCode.selector, bad[i]));
            factory.genesis(p);
        }
    }

    /// Round 1 (M2): the factory has code, so naming it as a recipient passed
    /// the code check, every allocation became a self-transfer, and 35% of the
    /// supply stayed in a contract that can never move it. Kills: any recipient
    /// check that accepts the factory or another package-1 contract.
    function test_aRecipientThatIsAPackageOneContractIsRefused() public {
        address[4] memory insiders = [address(factory), address(hook), address(vesting), address(deployer)];
        for (uint256 i = 0; i < insiders.length; i++) {
            for (uint256 slot = 0; slot < 3; slot++) {
                FeastFactory.GenesisParams memory p = _params();
                if (slot == 0) p.teamVesting = insiders[i];
                if (slot == 1) p.emissions = insiders[i];
                if (slot == 2) p.grants = insiders[i];
                vm.prank(genesisKey);
                vm.expectRevert(abi.encodeWithSelector(FeastFactory.RecipientNotAllowed.selector, insiders[i]));
                factory.genesis(p);
            }
        }
    }

    /// Two allocations landing on one contract would merge two published
    /// buckets into one; the three recipients must be distinct.
    function test_theThreeRecipientsMustBeDistinct() public {
        FeastFactory.GenesisParams memory p = _params();
        p.grants = p.emissions;
        vm.prank(genesisKey);
        vm.expectRevert(abi.encodeWithSelector(FeastFactory.RecipientNotAllowed.selector, p.emissions));
        factory.genesis(p);
        p = _params();
        p.teamVesting = p.grants;
        vm.prank(genesisKey);
        vm.expectRevert(abi.encodeWithSelector(FeastFactory.RecipientNotAllowed.selector, p.grants));
        factory.genesis(p);
    }

    /// Round 2 (M1): a list of contracts genesis may not name can never be
    /// complete — the oracle, the ledger, the pool manager all have code and no
    /// way to spend an allocation. So genesis asks each recipient what it is.
    /// Kills: any recipient check that does not require the role.
    function test_aContractThatDoesNotSayWhatItIsIsRefused() public {
        address[4] memory strangers =
            [address(hook.oracle()), address(ledger), address(hook.converter()), address(pm)];
        for (uint256 i = 0; i < strangers.length; i++) {
            for (uint256 slot = 0; slot < 4; slot++) {
                FeastFactory.GenesisParams memory p = _params();
                if (slot == 0) p.teamVesting = strangers[i];
                if (slot == 1) p.emissions = strangers[i];
                if (slot == 2) p.grants = strangers[i];
                if (slot == 3) p.window = strangers[i];
                vm.prank(genesisKey);
                vm.expectRevert(abi.encodeWithSelector(FeastFactory.RecipientNotAllowed.selector, strangers[i]));
                factory.genesis(p);
            }
        }
    }

    function test_aRecipientServingAnotherCoinIsRefused() public {
        FeastFactory.GenesisParams memory p = _params();
        p.emissions = address(new RoleHolder(FeastGenesis.ROLE_EMISSIONS, address(0xBEEF), 0, 0, address(0)));
        vm.prank(genesisKey);
        vm.expectRevert(abi.encodeWithSelector(FeastFactory.RecipientNotAllowed.selector, p.emissions));
        factory.genesis(p);
    }

    /// A sink must say it is the sink, like every recipient says what it is.
    function test_aSinkWithCodeMustSayItIsTheSink() public {
        address[2] memory wrong = [address(hook), address(new RoleHolder(FeastGenesis.ROLE_GRANTS, factory.predictPlatformCoin(), 0, 0, address(0)))];
        for (uint256 i = 0; i < 2; i++) {
            FeastFactory.GenesisParams memory p = _params();
            p.platformSink = wrong[i];
            vm.prank(genesisKey);
            vm.expectRevert(abi.encodeWithSelector(FeastFactory.RecipientNotAllowed.selector, wrong[i]));
            factory.genesis(p);
        }
    }

    /// **Reversed in v1.6.22** (owner ruling R2, 2026-09-25). This test used to
    /// be `test_theSinkAloneMayHaveNoCodeYet` and asserted that genesis BOUND a
    /// codeless sink "to be deployed later". The window's `settle` pays the
    /// pot's 1% to that address at the close, and a sink deployed after the
    /// close can never be armed, so what reached it was stranded
    /// (`CA-8f254aa78e`, `test/audit/poc/WindowFeeCodelessSink.t.sol`). The
    /// ceremony must deploy and arm the sink before genesis, which
    /// `script/Genesis.s.sol` already does.
    function test_theSinkMustHaveCodeLikeEveryRecipient() public {
        FeastFactory.GenesisParams memory p = _params();
        p.platformSink = address(0x51CC);
        vm.prank(genesisKey);
        vm.expectRevert(abi.encodeWithSelector(FeastFactory.RecipientHasNoCode.selector, address(0x51CC)));
        factory.genesis(p);
        assertEq(factory.platformSink(), address(0), "nothing was bound");
    }

    function test_aZeroSinkIsRefused() public {
        FeastFactory.GenesisParams memory p = _params();
        p.platformSink = address(0);
        vm.prank(genesisKey);
        vm.expectRevert(abi.encodeWithSelector(FeastFactory.RecipientHasNoCode.selector, address(0)));
        factory.genesis(p);
    }

    /// v1.6.10 (diff round `P12`, `r2a-claude`): the gate is DERIVED from the
    /// window's close, so it can no longer be pushed anywhere by a typed value.
    /// The hook's own `GateOutOfBounds` is still the backstop for `create`,
    /// which is where a caller still chooses a gate; through genesis it is now
    /// unreachable, and the factory refuses the disagreement first.
    function test_theGateCannotBePushedOutOfBoundsThroughGenesis() public {
        FeastFactory.GenesisParams memory p = _params();
        uint64 derived = uint64(window.endsAt() + FeastGenesis.SETTLE_GRACE);
        p.openAt = uint64(clock + FeastGenesis.MAX_GATE_DURATION + 1);
        vm.expectRevert(
            abi.encodeWithSelector(FeastFactory.GateIsNotTheWindowsClose.selector, p.openAt, derived)
        );
        vm.prank(genesisKey);
        factory.genesis(p);
    }

    /// Even one second off is refused: it is an equality against a derivation,
    /// not a range.
    function test_aGateOneSecondFromTheDerivationIsRefused() public {
        FeastFactory.GenesisParams memory p = _params();
        uint64 derived = uint64(window.endsAt() + FeastGenesis.SETTLE_GRACE);
        p.openAt = derived + 1;
        vm.expectRevert(
            abi.encodeWithSelector(FeastFactory.GateIsNotTheWindowsClose.selector, derived + 1, derived)
        );
        vm.prank(genesisKey);
        factory.genesis(p);
    }

    /// And what the pool is REGISTERED with is the derivation — the passed
    /// value is a checksum, never the source.
    function test_theRegisteredGateIsTheWindowsClosePlusTheGrace() public {
        (, PoolKey memory k) = _genesis();
        assertEq(
            hook.poolInfo(k.toId()).openAt,
            uint64(window.endsAt() + FeastGenesis.SETTLE_GRACE),
            "the registered gate is the window's close plus the settle grace"
        );
    }

    /// v1.6.10 (diff round `P8`): the window's close is the root of the whole
    /// launch calendar, so genesis refuses one that is not a sane instant.
    function test_aWindowWhoseCloseIsInThePastIsRefused() public {
        FeastFactory.GenesisParams memory p = _params();
        // Walk past the stand-in window's close. Everything else is unchanged.
        vm.warp(window.endsAt() + 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                FeastFactory.WindowCloseOutOfRange.selector,
                window.endsAt(),
                block.timestamp,
                block.timestamp + 30 days
            )
        );
        vm.prank(genesisKey);
        factory.genesis(p);
    }

    // --- the coin -----------------------------------------------------------

    function test_theCoinIsWhereItWasPredictedFromDayOne() public {
        address predicted = factory.predictPlatformCoin();
        (address feast,) = _genesis();
        assertEq(feast, predicted, "predictable before it exists");
        assertEq(factory.platformCoin(), feast, "and recorded");
        assertEq(FeastPlatformToken(feast).totalSupply(), SUPPLY, "the whole supply, once");
        assertEq(FeastPlatformToken(feast).symbol(), "FEAST", "named in the genesis file");
        assertEq(FeastPlatformToken(feast).CLOCK_MODE(), "mode=timestamp", "votes count in seconds");
    }

    /// The platform coin carries its own metadata digest, like any coin.
    function test_thePlatformCoinsMetadataHashIsRecorded() public {
        (address feast,) = _genesis();
        assertEq(factory.getCoin(feast).metadataHash, keccak256("feast.metadata"), "genesis passes its own digest");
    }

    function test_onlyTheFactoryMayMintThePlatformCoin() public {
        vm.prank(stranger);
        vm.expectRevert(FeastPlatformTokenDeployer.NotFactory.selector);
        deployer.deploy();
    }

    /// Fixed supply by absence, as for every coin.
    function test_thePlatformCoinHasNoMintEntrypoint() public {
        (address feast,) = _genesis();
        bytes4[3] memory guesses = [bytes4(keccak256("mint(address,uint256)")), bytes4(keccak256("mint(uint256)")), bytes4(keccak256("issue(address,uint256)"))];
        for (uint256 i = 0; i < guesses.length; i++) {
            (bool ok,) = feast.call(abi.encodeWithSelector(guesses[i], stranger, 1));
            assertFalse(ok, "no mint path");
        }
    }

    /// Voting power exists only once delegated, so a contract that never
    /// delegates never votes.
    function test_heldTokensHaveNoVotesUntilDelegated() public {
        (address feast,) = _genesis();
        FeastPlatformToken t = FeastPlatformToken(feast);
        assertEq(t.getVotes(teamVesting), 0, "the team's allocation cannot vote");
        vm.prank(teamVesting);
        IERC20(feast).transfer(stranger, 1e18);
        assertEq(t.getVotes(stranger), 0, "a holder cannot either, until they delegate");
        vm.prank(stranger);
        t.delegate(stranger);
        assertEq(t.getVotes(stranger), 1e18, "then they can");
    }

    /// Burning is the only direction the platform coin's supply may move.
    function test_burningThePlatformCoinReducesItsSupply() public {
        (address feast,) = _genesis();
        FeastPlatformToken t = FeastPlatformToken(feast);
        vm.prank(teamVesting);
        t.burn(1e18);
        assertEq(t.totalSupply(), SUPPLY - 1e18, "down by exactly what was burned");
    }

    // --- the split ------------------------------------------------------------

    /// The published split, as of the owner's ruling of 2026-09-16: 60% into the
    /// permanently locked pool, 25% to the team, 14.2% to emissions, 0.8% to the
    /// eight genesis partners. The figures here are written out rather than read
    /// from `FeastGenesis`, so this test is an independent witness of them and
    /// not a restatement of the constants the factory divides by.
    ///
    /// Kills: any share off by one basis point; a remainder left in the factory.
    function test_theSplitIsSixtyTwentyFiveFifteenToTheUnit() public {
        (address feast,) = _genesis();
        IERC20 t = IERC20(feast);
        assertEq(t.balanceOf(teamVesting), SUPPLY * 2_500 / 10_000, "25% to the team");
        assertEq(t.balanceOf(emissions), SUPPLY * 1_420 / 10_000, "14.2% to emissions");
        assertEq(t.balanceOf(grants), SUPPLY * 80 / 10_000, "0.8% to the genesis partners");
        assertEq(t.balanceOf(address(factory)), 0, "the factory keeps nothing");

        // v1.6.11: genesis no longer seeds. The 60% goes to the launch window,
        // which auctions half of it and seeds the rest once the clearing price
        // exists. The unit test of the split is therefore about where the coin
        // IS at genesis, and it is all in one place.
        assertEq(t.balanceOf(address(window)), SUPPLY * 6_000 / 10_000, "60% to the window, to auction and to seed");
        assertEq(t.balanceOf(address(vault)), 0, "nothing in the pool yet: it is not even initialised");
        assertEq(
            t.balanceOf(address(window)) + t.balanceOf(teamVesting) + t.balanceOf(emissions) + t.balanceOf(grants),
            SUPPLY,
            "every unit accounted for"
        );
    }

    /// The same four shares, one level up: in basis points, before any supply is
    /// divided by them. Three of the four are written down in `FeastGenesis` and
    /// the fourth is derived as the remainder, so "they sum to `BPS`" is true by
    /// construction and witnesses nothing on its own. What is NOT true by
    /// construction is that each one is the published figure — and that the
    /// remainder lands on 1_420 exactly, which it does only while the other
    /// three sum to 8_580. Those are the assertions below; the sum is the last
    /// line, and it is the tautology, kept because it is the sentence the
    /// README makes.
    ///
    /// Kills: any of the three declared shares moved by one basis point; a
    /// partner count or per-partner grant that no longer multiplies out to the
    /// partners' share.
    function test_theFourSharesAreThePublishedOnesAndSumToTheWhole() public pure {
        assertEq(FeastGenesis.POOL_BPS, 6_000, "60% to the permanently locked pool");
        assertEq(FeastGenesis.TEAM_BPS, 2_500, "25% to the team");
        assertEq(FeastGenesis.EMISSIONS_BPS, 1_420, "14.2% to emissions");
        assertEq(FeastGenesis.GRANTS_BPS, 80, "0.8% to the eight genesis partners");
        assertEq(
            FeastGenesis.GRANT_BPS_EACH * FeastGenesis.PARTNERS,
            FeastGenesis.GRANTS_BPS,
            "eight partners at 0.1% each are the whole partners' share"
        );
        assertEq(
            uint256(FeastGenesis.POOL_BPS) + FeastGenesis.TEAM_BPS + FeastGenesis.EMISSIONS_BPS
                + FeastGenesis.GRANTS_BPS,
            FeastGenesis.BPS,
            "6_000 + 2_500 + 1_420 + 80 = 10_000"
        );
    }

    // --- the pool -------------------------------------------------------------

    function test_thePlatformCoinsPoolHasItsOwnTermsAndItsGate() public {
        (address feast, PoolKey memory key) = _genesis();
        FeastHook.Pool memory p = hook.poolInfo(key.toId());
        assertEq(p.coin, feast, "the coin");
        assertEq(p.creator, FeastConstants.BURN_ADDRESS, "creator is the burn address (ruling 8)");
        assertEq(p.selfBurnBps, 2_000, "20% self-burn");
        assertEq(p.referrerBps, 1_000, "10% referral");
        assertEq(p.opener, address(window), "the window opens it");
        assertEq(p.openAt, _params().openAt, "at the time genesis named");
        address quote = Currency.unwrap(key.currency0) == feast ? Currency.unwrap(key.currency1) : Currency.unwrap(key.currency0);
        assertEq(quote, address(wbnb), "paired with the wrapped native asset");
        // v1.6.11: registered and gated, but NOT seeded and not even
        // initialised — the clearing price does not exist until the window
        // closes, and there is no path that moves a pool's price afterwards.
        assertFalse(p.seeded, "not seeded at genesis");

        address[] memory coins = factory.listCoins();
        assertEq(coins[coins.length - 1], feast, "listed like every coin");
    }

    /// v1.6.11: the platform pool leaves genesis registered, gated, and NOT
    /// initialised — the price it opens at is the auction's clearing price, and
    /// that is not known until the window closes. So before the window opens
    /// it, nobody trades it, and the refusal comes from the venue rather than
    /// from the hook's gate: there is no pool to consult a hook about. Not even
    /// the registered opener can trade it, which is strictly stronger than the
    /// "only the window" this test asserted when genesis seeded the pool.
    /// (The gate itself, on a pool that has been opened, is pinned by
    /// `test_nobodyElseTradesThePoolBeforeItOpens` against the real window.)
    function test_nobodyTradesThePlatformPoolBeforeTheWindowOpensIt() public {
        (, PoolKey memory key) = _genesis();
        wbnb.mint(address(router), 1_000e18);
        wbnb.mint(address(window), 1_000e18);
        bool zeroForOne = Currency.unwrap(key.currency0) == address(wbnb);

        vm.expectRevert(CLPool.PoolNotInitialized.selector);
        _buy(router, key, zeroForOne);

        vm.expectRevert(CLPool.PoolNotInitialized.selector);
        _buy(window, key, zeroForOne);

        vm.warp(_params().openAt);
        vm.expectRevert(CLPool.PoolNotInitialized.selector);
        _buy(router, key, zeroForOne);
    }

    /// The exit reads the sink genesis bound: the platform share of an ordinary
    /// coin leaves to it once genesis has named it.
    function test_theExitPaysTheSinkGenesisNamed() public {
        MockERC20 q = new MockERC20("Stock", "STK", 18);
        (address coin, PoolKey memory key) = factory.create(
            FeastFactory.CreateParams({
                name: "Coin",
                symbol: "COIN",
                supply: 1_000_000_000e18,
                quote: address(q),
                creator: address(0xC0FFEE),
                selfBurnBps: 2_000,
                referrerBps: 1_000,
                prebuyQuoteIn: 0,
                minCoinsOut: 0,
                vestingDuration: 0,
                sqrtPriceX96: SQRT_PRICE_1_1,
                startTick: 0,
                liquidity: uint128(1_000_000_000e18 * 999 / 1_000),
                salt: bytes32(uint256(7)),
                metadataHash: bytes32(0)
            })
        );
        coin;
        vm.roll(vm.getBlockNumber() + FeastConstants.CAP_BLOCKS);
        q.mint(address(router), 1_000e18);
        _buy(router, key, Currency.unwrap(key.currency0) == address(q));

        vm.expectRevert(abi.encodeWithSelector(FeastHook.PlatformSinkNotBound.selector, address(0)));
        hook.releasePlatformFees(key);

        _genesis();
        uint256 pending = hook.platformPending(key.toId());
        hook.releasePlatformFees(key);
        assertEq(q.balanceOf(sink), pending, "the sink genesis named received it");
    }

    function _buy(PoolRouter via, PoolKey memory key, bool zeroForOne) internal {
        vm.prank(stranger, stranger);
        via.swap(
            key.up(),
            ICLPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(10e18),
                sqrtPriceLimitX96: zeroForOne ? MIN_SQRT : MAX_SQRT
            }),
            ""
        );
    }
}
