// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, Vm, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {FeastConverter} from "../src/FeastConverter.sol";
import {FeastFactory} from "../src/FeastFactory.sol";
import {FeastFeeLedger} from "../src/FeastFeeLedger.sol";
import {FeastHook} from "../src/FeastHook.sol";
import {FeastReferrals} from "../src/FeastReferrals.sol";
import {FeastOracle} from "../src/FeastOracle.sol";
import {FeastPlatformTokenDeployer} from "../src/FeastPlatformTokenDeployer.sol";
import {FeastVesting} from "../src/FeastVesting.sol";
import {Currency} from "../src/venue/Currency.sol";
import {PoolKey} from "../src/venue/PoolKey.sol";

import {CLPoolManager} from "infinity-core/src/pool-cl/CLPoolManager.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {Vault} from "infinity-core/src/Vault.sol";

import {PoolRouter} from "./utils/PoolRouter.sol";
import {VenueBridge} from "./utils/VenueBridge.sol";

import {FeastGuardian} from "../src/FeastGuardian.sol";
/// Per-swap gas, measured on the real venue at the pinned block.
///
/// The same sixteen trades per quote token — {buy, sell} × {exact-in,
/// exact-out} × {unreferred, referred} × {first in its week, warm} — against a
/// real tokenised stock and against wrapped native. The baseline is this file
/// run on the v1 tree (`git archive 4d008d1`) with only `_deploy` changed to
/// v1's constructors; `docs/tokenomics-v1.6.md` publishes both and the delta.
///
/// "First" warps to a fresh ledger week, so every ledger slot the trade touches
/// is written from zero; "warm" repeats the same trade in the same week, so
/// every slot already holds a value. `isolate = true` meters each router call
/// as its own transaction, so storage and account access start cold each time,
/// as they would on chain.
///
/// Prints `GAS,<quote>,<trade>,<gas>` lines; skips itself without an RPC.
contract FeastGasDeltaForkTest is Test {
    using VenueBridge for PoolKey;

    address internal constant CL_POOL_MANAGER = 0xa0FfB9c1CE1Fe56963B0321B32E7A0302114058b;
    address internal constant VAULT = 0x238a358808379702088667322f80aC48bAd5e6c4;
    address internal constant V3_FACTORY = 0x0BFbCF9fa4f9C56B0F40a671Ad40E0805A091865;
    address internal constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address internal constant AAPLB = 0x431a3BEE82E2ca41e49895CbECE5bB0F76A89b7A;
    address internal constant AAPLB_HOLDER = 0xe9b9998B2EC5430D2246c7f1F8D9f298c97D7365;

    uint256 internal constant FORK_BLOCK = 120_721_477;
    uint160 internal constant SQRT_PRICE_1_1 = 79_228_162_514_264_337_593_543_950_336;
    uint160 internal constant MIN_SQRT = 4_295_128_740;
    uint160 internal constant MAX_SQRT = 1_461_446_703_485_210_103_287_273_052_203_988_822_378_723_970_341;
    uint256 internal constant SUPPLY = 1_000_000_000e18;

    address internal creator = address(0xC0FFEE);
    address internal referrer = address(0xEE01);
    address internal trader = address(0x7EADE1);

    PoolRouter internal router;
    FeastFactory internal factory;
    uint256 internal clock;

    // ------------------------------------------------------------------
    // The only tree-specific part. On the v1 tree this body is replaced by
    // v1's constructors (FeastEpochRewards in the ledger's place, the
    // four-argument factory); nothing else in the file changes.
    function _deploy() internal {
        // The referral registry (v1.6.26) has no constructor and no immutables, so
        // its deployed code is the whole of it: etched, it spends none of this
        // contract's nonce — under `isolate` even `deployCodeTo`'s constructor call
        // is a transaction that moves it — and every address below, the tokens' and
        // the platform coin's CREATE2 draw included, is the one it was before.
        FeastReferrals referrals = FeastReferrals(address(uint160(uint256(keccak256("feast.referrals")))));
        vm.etch(address(referrals), vm.getDeployedCode("FeastReferrals.sol:FeastReferrals"));
        uint64 n = vm.getNonce(address(this));
        address predictedHook = vm.computeCreateAddress(address(this), n + 4);
        address predictedFactory = vm.computeCreateAddress(address(this), n + 7);
        FeastGuardian guardian = new FeastGuardian(address(0x3517), predictedFactory);
        FeastOracle oracle = new FeastOracle(predictedHook);
        FeastConverter converter = new FeastConverter(V3_FACTORY, WBNB, predictedHook);
        FeastFeeLedger ledger = new FeastFeeLedger(predictedHook);
        FeastHook hook = new FeastHook(
            CL_POOL_MANAGER, VAULT, predictedFactory, address(oracle), address(ledger), address(converter),
            address(guardian), address(referrals), new FeastHook.TipFloor[](0)
        );
        FeastVesting vesting = new FeastVesting(predictedFactory, address(guardian));
        FeastPlatformTokenDeployer deployer = new FeastPlatformTokenDeployer(predictedFactory);
        factory = new FeastFactory(
            CL_POOL_MANAGER, VAULT, address(hook), address(vesting), address(deployer), WBNB, address(this)
        );
        require(address(factory) == predictedFactory, "wiring");
    }
    // ------------------------------------------------------------------

    function _forked() internal returns (bool) {
        string memory url = vm.envOr("BSC_RPC_URL", string(""));
        if (bytes(url).length == 0) {
            vm.skip(true);
            return false;
        }
        vm.createSelectFork(url, FORK_BLOCK);
        clock = block.timestamp;
        router = new PoolRouter(Vault(VAULT), CLPoolManager(CL_POOL_MANAGER));
        _deploy();
        return true;
    }

    function _create(address quote, bytes32 salt) internal returns (address coin, PoolKey memory key) {
        uint256 g = gasleft();
        (coin, key) = factory.create(
            FeastFactory.CreateParams({
                name: "Coin",
                symbol: "COIN",
                supply: SUPPLY,
                quote: quote,
                creator: creator,
                selfBurnBps: 2_000,
                referrerBps: 1_000,
                prebuyQuoteIn: 0,
                minCoinsOut: 0,
                vestingDuration: 0,
                sqrtPriceX96: SQRT_PRICE_1_1,
                startTick: 0,
                liquidity: uint128(SUPPLY * 999 / 1_000),
                salt: salt,
                metadataHash: keccak256(abi.encode(salt))
            })
        );
        console.log(string.concat("GAS,create,", vm.toString(quote), ",", vm.toString(g - gasleft())));
    }

    function _advance(uint256 s) internal {
        clock += s;
        vm.warp(clock);
        vm.roll(vm.getBlockNumber() + 1);
    }

    /// @dev To the first second of the next week (and the next day) — the
    ///      start of a fresh week under v1.6's Monday alignment and a fresh day
    ///      under v1's, so both trees see "first".
    function _nextWeek() internal {
        uint256 monday = ((clock + 3 days) / 7 days + 1) * 7 days - 3 days;
        clock = monday + 60;
        vm.warp(clock);
        vm.roll(vm.getBlockNumber() + 1);
    }

    function _swap(PoolKey memory key, address quote, uint256 t, bool referred) internal returns (uint256 used) {
        bool buy = t < 2;
        bool exactIn = t % 2 == 0;
        bool quoteIs0 = Currency.unwrap(key.currency0) == quote;
        bool zeroForOne = buy ? quoteIs0 : !quoteIs0;
        // Small against a pool of a billion, so price impact never moves a
        // measurement; exact-out amounts are chosen to fill.
        int256 amount = exactIn ? -int256(1e18) : int256(0.5e18);
        bytes memory hookData = referred ? abi.encode(referrer) : bytes("");
        ICLPoolManager.SwapParams memory params = ICLPoolManager.SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: amount,
            sqrtPriceLimitX96: zeroForOne ? MIN_SQRT : MAX_SQRT
        });
        vm.prank(trader, trader);
        vm.recordLogs();
        uint256 g = gasleft();
        router.swap(key.up(), params, hookData);
        used = g - gasleft();
        _lastFilled = false;
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            // keccak256("InternalFill(bytes32,uint256,uint256)"): v1.6 only.
            if (logs[i].topics.length != 0 && logs[i].topics[0] == keccak256("InternalFill(bytes32,uint256,uint256)")) {
                _lastFilled = true;
            }
        }
    }

    bool internal _lastFilled;

    function _run(string memory label, PoolKey memory key, address quote) internal {
        string[4] memory names = ["buy-exact-in", "buy-exact-out", "sell-exact-in", "sell-exact-out"];
        for (uint256 t = 0; t < 4; t++) {
            for (uint256 r = 0; r < 2; r++) {
                bool referred = r == 1;
                _nextWeek();
                uint256 first = _swap(key, quote, t, referred);
                bool firstFilled = _lastFilled;
                _advance(60);
                uint256 warm = _swap(key, quote, t, referred);
                bool warmFilled = _lastFilled;
                _advance(60);
                string memory trade = string.concat(names[t], referred ? "/referred" : "/unreferred");
                console.log(string.concat("GAS,", label, ",", trade, "/first,", vm.toString(first), firstFilled ? ",filled" : ""));
                console.log(string.concat("GAS,", label, ",", trade, "/warm,", vm.toString(warm), warmFilled ? ",filled" : ""));
            }
        }
    }

    function test_fork_gasPerSwap() public {
        if (!_forked()) return;

        (address stockCoin, PoolKey memory stockKey) = _create(AAPLB, bytes32(uint256(0xA1)));
        (address nativeCoin, PoolKey memory nativeKey) = _create(WBNB, bytes32(uint256(0xB2)));
        vm.roll(vm.getBlockNumber() + 3);

        // Fund the router with both quotes, then with coin for the sells.
        vm.prank(AAPLB_HOLDER);
        IERC20(AAPLB).transfer(address(router), 50e18);
        deal(WBNB, address(router), 50e18);
        _swap(stockKey, AAPLB, 0, false);
        _swap(nativeKey, WBNB, 0, false);
        _advance(60);
        stockCoin;
        nativeCoin;

        _run("AAPLB", stockKey, AAPLB);
        _run("WBNB", nativeKey, WBNB);
    }
}
