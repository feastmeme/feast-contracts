// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {FeastConstants} from "../src/FeastConstants.sol";
import {FeastFeeLedger} from "../src/FeastFeeLedger.sol";
import {FeastOracle} from "../src/FeastOracle.sol";
import {FeastHook} from "../src/FeastHook.sol";
import {FeastReferrals} from "../src/FeastReferrals.sol";
import {Currency} from "../src/venue/Currency.sol";
import {PoolId, PoolIdLibrary} from "../src/venue/PoolId.sol";
import {PoolKey} from "../src/venue/PoolKey.sol";

import {Vault} from "infinity-core/src/Vault.sol";
import {CLPoolManager} from "infinity-core/src/pool-cl/CLPoolManager.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {CustomRevert} from "infinity-core/src/libraries/CustomRevert.sol";
import {Hooks} from "infinity-core/src/libraries/Hooks.sol";
import {IFeastCLHooks} from "../src/venue/IFeastCLHooks.sol";

import {MockERC20} from "./utils/MockERC20.sol";
import {CapWarm} from "./utils/CapWarm.sol";
import {PoolRouter} from "./utils/PoolRouter.sol";
import {VenueBridge} from "./utils/VenueBridge.sol";

import {FeastGuardian} from "../../../src/FeastGuardian.sol";

/// Registries that answer `referrerOf(address)` wrongly, so the hook's read of
/// the registry is witnessed refusing each answer Solidity's decoder refuses.
contract DirtyWordRegistry {
    fallback() external {
        assembly {
            mstore(0, not(0))
            return(0, 0x20)
        }
    }
}

/// Reverts with one clean, address-shaped word, so the call's success is the
/// only check that can refuse it: a reason string would be refused by the
/// clean-address check as well, and witness nothing about success.
contract RevertingRegistry {
    fallback() external {
        assembly {
            mstore(0, 0xBEEF)
            revert(0, 0x20)
        }
    }
}

contract ShortAnswerRegistry {
    fallback() external {
        assembly {
            mstore(0, 0)
            return(0, 0x1f)
        }
    }
}

/// The referral relationship is a property of the WALLET, not of a trade.
/// A wallet brought by somebody's link pays that somebody on every later trade
/// it ever makes, through any router, on any coin — and the binding is written
/// once, by the wallet itself, and can never be changed.
///
/// **v1.6.26 (AstraSec M-4): the binding is authenticated, never inferred.**
/// Until v1.6.25 the first 64-byte trade whose wallet word equalled
/// `tx.origin` bound that origin, and under ERC-4337 the origin is the
/// bundler, so one user operation could bind a bundler to a stranger for life
/// (`test/audit/poc/SharedOriginCapture.t.sol`). Now a wallet binds only in
/// `FeastReferrals`, by its own call or its own signature, and no trade writes
/// a binding in any form. The hook reads `referrals.referrerOf(tx.origin)`
/// first; with no binding, a trade pays only the referrer it names, for itself.
/// `FeastReferrals.t.sol` is the registry alone; this suite is what the hook
/// does with it.
///
/// Self-referral needs no new rule here. v1.6 ruling 5, Q5 already refused a
/// referrer who is the payer, in both forms of `hookData`, and the registry
/// refuses binding a wallet to itself.
contract FeastReferrerBindingTest is Test {
    using PoolIdLibrary for PoolKey;
    using VenueBridge for PoolKey;

    uint160 internal constant SQRT_PRICE_1_1 = 79_228_162_514_264_337_593_543_950_336;
    uint160 internal constant MIN_SQRT = 4_295_128_740;
    uint160 internal constant MAX_SQRT = 1_461_446_703_485_210_103_287_273_052_203_988_822_378_723_970_341;
    uint256 internal constant SUPPLY = 1_000_000_000e18;

    address internal factory = address(0xFAC7);
    address internal creator = address(0xC0FFEE);
    address internal referrer = address(0xEE);
    address internal other = address(0x0EE2);
    address internal trader = address(0xBEEF);
    address internal stranger = address(0x57A0);

    Vault internal vault;
    CLPoolManager internal pm;
    PoolRouter internal router;
    FeastGuardian internal guardian;
    FeastReferrals internal referrals;
    FeastHook internal hook;
    FeastFeeLedger internal ledger;

    /// The pool most things are measured on: the default 10% referrer share.
    PoolKey internal key;
    bool internal coinIsCurrency0;
    MockERC20 internal quoteToken;
    /// A second pool whose referrer share is ZERO: a binding reaches it and is
    /// paid nothing there, and the plain-trade gas is measured on it.
    PoolKey internal key0;
    bool internal coinIsCurrency0_0;

    event ReferralCredited(PoolId indexed poolId, address indexed referrer, uint256 amount);

    function setUp() public {
        vault = new Vault();
        pm = new CLPoolManager(vault);
        vault.registerApp(address(pm));
        router = new PoolRouter(vault, pm);
        // Every collaborator real, none zero: testing rule 2.
        // Before any address prediction: every CREATE after this shifts by one.
        guardian = new FeastGuardian(address(0x3517), address(this));
        // The referral registry (v1.6.26) has no constructor and no immutables, so
        // its deployed code is the whole of it: etched, it spends none of this
        // contract's nonce — under `isolate` even `deployCodeTo`'s constructor call
        // is a transaction that moves it — and every address below, the tokens' and
        // the platform coin's CREATE2 draw included, is the one it was before.
        referrals = FeastReferrals(address(uint160(uint256(keccak256("feast.referrals")))));
        vm.etch(address(referrals), vm.getDeployedCode("FeastReferrals.sol:FeastReferrals"));
        address predictedHook = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 2);
        FeastOracle oracle = new FeastOracle(predictedHook);
        ledger = new FeastFeeLedger(predictedHook);
        hook = new FeastHook(address(pm), address(vault), factory, address(oracle), address(ledger), address(0),
            address(guardian), address(referrals), new FeastHook.TipFloor[](0));
        assertEq(address(hook), predictedHook, "hook wiring");

        (key, coinIsCurrency0) = _createPool(FeastConstants.DEFAULT_REFERRER_BPS, SUPPLY);
        quoteToken = MockERC20(Currency.unwrap(coinIsCurrency0 ? key.currency1 : key.currency0));
        (key0, coinIsCurrency0_0) = _createPool(0, SUPPLY);
        // v1.6.15: the opening cap window opens at a pool's first SERVED
        // swap, so rolling past CAP_BLOCKS only clears a window that exists.
        CapWarm.arm(router, key.up(), address(quoteToken), !coinIsCurrency0);
        CapWarm.arm(router, key0.up(), address(quoteToken), !coinIsCurrency0_0);
        vm.roll(vm.getBlockNumber() + FeastConstants.CAP_BLOCKS);

        // Warm each pool's first-trade-only writes, so every measurement below
        // is an ORDINARY trade rather than a pool's very first.
        _buy(key, coinIsCurrency0, -1_000e18, "", trader);
        _buy(key0, coinIsCurrency0_0, -1_000e18, "", trader);
    }

    function _createPool(uint16 referrerBps, uint256 supply) internal returns (PoolKey memory k, bool coinIs0) {
        return _createPoolOn(hook, referrerBps, supply);
    }

    function _createPoolOn(FeastHook h, uint16 referrerBps, uint256 supply)
        internal
        returns (PoolKey memory k, bool coinIs0)
    {
        MockERC20 c = new MockERC20("Coin", "COIN", 18);
        MockERC20 q = new MockERC20("Quote", "Q", 18);
        (address c0, address c1) = address(c) < address(q) ? (address(c), address(q)) : (address(q), address(c));
        coinIs0 = c0 == address(c);
        k = PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            hooks: address(h),
            poolManager: address(pm),
            fee: FeastConstants.POOL_LP_FEE,
            parameters: h.poolParameters()
        });
        vm.prank(factory);
        // No launch gate: `openAt = 0`, `opener = address(0)`. These suites are
        // about the referral binding and a closed window would confound them.
        h.registerPool(k, address(c), creator, FeastConstants.DEFAULT_SELF_BURN_BPS, referrerBps, supply, 0, address(0));
        vm.prank(factory);
        pm.initialize(k.up(), SQRT_PRICE_1_1);

        c.mint(address(router), SUPPLY);
        q.mint(address(router), SUPPLY);
        router.modifyLiquidity(
            k.up(),
            ICLPoolManager.ModifyLiquidityParams({
                tickLower: -887_200,
                tickUpper: 887_200,
                liquidityDelta: 100_000_000e18,
                salt: bytes32(0)
            })
        );
    }

    function _buy(PoolKey memory k, bool coinIs0, int256 amount, bytes memory hookData, address origin)
        internal
        returns (uint256 used)
    {
        bool zeroForOne = !coinIs0;
        ICLPoolManager.SwapParams memory params = ICLPoolManager.SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: amount,
            sqrtPriceLimitX96: zeroForOne ? MIN_SQRT : MAX_SQRT
        });
        vm.prank(origin, origin);
        uint256 before_ = gasleft();
        router.swap(k.up(), params, hookData);
        used = before_ - gasleft();
    }

    /// An ordinary buy on the 10%-referrer pool, as `origin`.
    function _buyAs(address origin, bytes memory hookData) internal returns (uint256) {
        return _buy(key, coinIsCurrency0, -1_000e18, hookData, origin);
    }

    /// The same on the pool that pays no commission at all.
    function _buyAsOnZeroPool(address origin, bytes memory hookData) internal returns (uint256) {
        return _buy(key0, coinIsCurrency0_0, -1_000e18, hookData, origin);
    }

    /// A user operation's shape: the account calls the router and a bundler
    /// signed the transaction, so `msg.sender` is the account and `tx.origin`
    /// is the bundler.
    function _relayedBuy(address account, address bundler, bytes memory hookData) internal {
        bool zeroForOne = !coinIsCurrency0;
        vm.prank(account, bundler);
        router.swap(
            key.up(),
            ICLPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -1_000e18,
                sqrtPriceLimitX96: zeroForOne ? MIN_SQRT : MAX_SQRT
            }),
            hookData
        );
    }

    /// The 64-byte form, `abi.encode(referrer, wallet)`: the shape that bound
    /// until v1.6.25 and pays per trade since.
    function _binding(address r, address w) internal pure returns (bytes memory) {
        return abi.encode(r, w);
    }

    /// The 32-byte legacy form, unchanged since v1.6.7.
    function _legacy(address r) internal pure returns (bytes memory) {
        return abi.encode(r);
    }

    /// A wallet binds itself, by its own call.
    function _bind(address w, address r) internal {
        vm.prank(w);
        referrals.bind(r);
    }

    function _pending(address who) internal view returns (uint256) {
        return hook.referrerPending(key.toId(), who);
    }

    // --- binding: the wallet's own act, and what the hook does with it ------

    /// The whole feature in one test. A wallet that binds itself is paid for on
    /// every later trade: on any pool, through any router, naming nobody.
    function test_aWalletBindsByItsOwnCallAndIsPaidForOnEveryPoolAndRouter() public {
        assertEq(referrals.referrerOf(trader), address(0), "nobody starts bound");
        _bind(trader, referrer);
        assertEq(referrals.referrerOf(trader), referrer, "the wallet's own call wrote it");

        _buyAs(trader, "");
        uint256 first = _pending(referrer);
        assertGt(first, 0, "paid on a trade that named nobody");

        PoolRouter second = new PoolRouter(vault, pm);
        quoteToken.mint(address(second), 1_000e18);
        bool zeroForOne = !coinIsCurrency0;
        vm.prank(trader, trader);
        second.swap(
            key.up(),
            ICLPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -1_000e18,
                sqrtPriceLimitX96: zeroForOne ? MIN_SQRT : MAX_SQRT
            }),
            ""
        );
        assertGt(_pending(referrer), first, "and through a router the wallet had never used");

        uint256 week = ledger.currentWeek();
        address quote0 = Currency.unwrap(coinIsCurrency0_0 ? key0.currency1 : key0.currency0);
        uint256 track = ledger.credit(week, quote0, referrer).referred;
        _buyAsOnZeroPool(trader, "");
        assertGt(ledger.credit(week, quote0, referrer).referred, track, "and on the other pool too");
    }

    /// The signed entry binds the same way: relayed by a stranger, decided by
    /// the wallet's own key, read by the hook like any other binding.
    function test_aWalletBoundBySignatureIsPaidForLikeOneBoundByItsCall() public {
        uint256 walletKey = 0xB0B;
        address wallet = vm.addr(walletKey);
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                keccak256(
                    abi.encode(
                        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                        keccak256("FeastReferrals"),
                        keccak256("1"),
                        block.chainid,
                        address(referrals)
                    )
                ),
                keccak256(
                    abi.encode(
                        keccak256("Bind(address wallet,address referrer,uint256 deadline)"), wallet, referrer, deadline
                    )
                )
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(walletKey, digest);
        vm.prank(stranger);
        referrals.bindWithSig(wallet, referrer, deadline, abi.encodePacked(r, s, v));

        _buyAs(wallet, _legacy(stranger));

        assertGt(_pending(referrer), 0, "the signed binding pays");
        assertEq(_pending(stranger), 0, "and the relayer, named in the trade, is paid nothing");
    }

    /// The binding is global. It lives in the registry, outside every pool, and
    /// decides who is paid on a pool where the wallet never named anybody —
    /// which is exactly what "every later trade, on any coin" means.
    function test_theBindingIsNotPerPoolAndReachesACoinNeverTraded() public {
        _bind(trader, referrer);
        assertEq(_pending(referrer), 0, "nothing on this pool yet");

        _buyAs(trader, "");

        assertGt(_pending(referrer), 0, "a coin the wallet had not named a referrer on pays the bound one");
    }

    /// No re-binding. Not by a later trade, not by a different referrer, not by
    /// the wallet itself asking again.
    function test_aBoundWalletCanNeverBeReboundByAnyLaterTrade() public {
        _bind(trader, referrer);

        _buyAs(trader, _binding(other, trader));
        _buyAs(trader, _legacy(other));
        _buyAs(trader, _binding(stranger, trader));
        vm.prank(trader);
        vm.expectRevert(FeastReferrals.AlreadyBound.selector);
        referrals.bind(other);

        assertEq(referrals.referrerOf(trader), referrer, "still the first referrer, four attempts later");
        assertEq(_pending(other), 0, "and the challenger was never paid a wei");
        assertEq(_pending(stranger), 0, "nor the second challenger");
    }

    function test_aBoundWalletIsPaidOnATradeThatNamesNobody() public {
        _bind(trader, referrer);
        _buyAs(trader, "");
        assertGt(_pending(referrer), 0, "empty hookData, and the bound referrer is still paid");
    }

    /// Whatever a router puts in `hookData`, a bound wallet's commission goes
    /// to the referrer that brought it. This is the property that makes the
    /// promise hold "through any router" — a terminal cannot redirect it.
    function test_aBoundWalletIgnoresTheReferrerInHookDataInBothForms() public {
        _bind(trader, referrer);
        uint256 startedAt = _pending(referrer);

        _buyAs(trader, _legacy(stranger));
        _buyAs(trader, _binding(stranger, trader));
        _buyAs(trader, _binding(stranger, stranger));
        _buyAs(trader, hex"deadbeef");

        assertEq(_pending(stranger), 0, "four attempts to redirect, none paid");
        assertGt(_pending(referrer), startedAt, "and all four paid the bound referrer");
        assertEq(referrals.referrerOf(trader), referrer, "the binding is untouched");
    }

    // --- no trade binds anything any more -------------------------------------

    /// The 64-byte form naming the wallet that signed is exactly the trade that
    /// bound for life until v1.6.25. It pays its named referrer for itself and
    /// binds nothing: the next trade, naming nobody, pays nobody.
    function test_theFirstNamedTradeBindsNothing() public {
        _buyAs(trader, _binding(referrer, trader));
        uint256 paid = _pending(referrer);
        assertGt(paid, 0, "the trade paid the referrer it named");
        assertEq(referrals.referrerOf(trader), address(0), "and bound nothing");

        _buyAs(trader, "");
        assertEq(_pending(referrer), paid, "so the next trade, naming nobody, pays nobody");
    }

    /// Design item 3 until v1.6.25: a terminal passing its own address for an
    /// unbound wallet bound that wallet to itself. It can no longer: it is paid
    /// for the trade it carried, and for nothing after.
    function test_aThirdPartyTerminalCannotBindAnUnboundWallet() public {
        _buyAs(trader, _binding(stranger, trader));
        uint256 paid = _pending(stranger);
        assertGt(paid, 0, "the terminal is paid for the trade it carried");
        assertEq(referrals.referrerOf(trader), address(0), "and the wallet is still its own");

        _buyAs(trader, "");
        assertEq(_pending(stranger), paid, "and for nothing after");
    }

    /// Every shape a trade can take, and none of them binds: the registry is
    /// written by wallets, never by trades.
    function test_noTradeBindsAWalletWhateverItsShape() public {
        bytes[6] memory shapes = [
            bytes(""),
            _legacy(referrer),
            _binding(referrer, trader),
            _binding(referrer, other),
            _binding(referrer, address(0)),
            bytes(hex"deadbeef")
        ];
        for (uint256 i = 0; i < shapes.length; i++) {
            _buyAs(trader, shapes[i]);
        }
        assertEq(referrals.referrerOf(trader), address(0), "the trader is unbound");
        assertEq(referrals.referrerOf(other), address(0), "and so is the wallet one trade claimed");
        assertGt(_pending(referrer), 0, "while the named trades were paid, so they were reached");
    }

    function testFuzz_noTradeBindsAWallet(bytes calldata blob, address origin) public {
        vm.assume(blob.length < 200 && origin != address(0));
        _buyAs(origin, blob);
        assertEq(referrals.referrerOf(origin), address(0), "no trade binds its origin");
    }

    /// **AstraSec M-4, the regression.** A user operation: an account calls,
    /// the bundler signed, and the calldata names the BUNDLER as the wallet.
    /// Until v1.6.25 that bound the bundler to the attacker for life, and every
    /// later trade it relayed paid the attacker. The PoC that was red on
    /// v1.6.25 is `test/audit/poc/SharedOriginCapture.t.sol`; this is the same
    /// sequence, asserting the outcome now.
    function test_aUserOperationCannotBindTheBundlerThatSubmittedIt() public {
        address bundler = address(0xB0D1E);
        address attacker = address(0xA77AC);
        address kol = address(0x604);

        _relayedBuy(address(0xACC1), bundler, _binding(attacker, bundler));
        assertEq(referrals.referrerOf(bundler), address(0), "the bundler is not bound");
        uint256 attackerPaid = _pending(attacker);

        // A later, unrelated user through the same bundler, naming their own
        // referrer: that referrer is paid, and the attacker is not.
        _relayedBuy(address(0xACC2), bundler, _binding(kol, address(0xACC2)));
        assertGt(_pending(kol), 0, "the second user's own referrer is paid");
        assertEq(_pending(attacker), attackerPaid, "and the attacker is paid nothing for it");
    }

    /// Stated so that nobody discovers it. The hook reads `tx.origin`'s binding
    /// first, and the chain cannot tell a bundler's key from a user's — so a
    /// relayer that binds ITS OWN key, by its own call, is paid on every trade it
    /// originates, whatever the trade names. That is an authenticated act by
    /// the key holder, which is the line the ruling draws; what M-4 closed is a
    /// binding written by somebody else's calldata.
    function test_aRelayerThatBindsItsOwnKeyIsPaidOnTheTradesItOriginates() public {
        address bundler = address(0xB0D1E);
        _bind(bundler, referrer);

        _relayedBuy(address(0xACC1), bundler, _binding(other, address(0xACC1)));

        assertGt(_pending(referrer), 0, "the relayer's own binding decides");
        assertEq(_pending(other), 0, "and the referrer the user named is not paid");
    }

    /// **The boundary v1.6.26 ships with — a bytecode decision, not a design
    /// one.** Only `tx.origin` is looked up. A contract account is never
    /// `tx.origin`, so its own binding, written by its own call, is NOT read on a
    /// trade a bundler submits, even when the trade names the account as the
    /// wallet. What pays is the referrer the trade names, for itself — so an
    /// integrator that wants the account's referrer paid names it.
    function test_aSmartAccountsBindingIsNotReadOnATradeABundlerSubmits() public {
        address account = address(0xACC1);
        address bundler = address(0xB0D1E);
        _bind(account, referrer);

        _relayedBuy(account, bundler, _binding(stranger, account));
        assertEq(_pending(referrer), 0, "the account's binding is not read");
        assertGt(_pending(stranger), 0, "the trade's own referrer is paid");

        _relayedBuy(account, bundler, _binding(referrer, account));
        assertGt(_pending(referrer), 0, "named in the trade, the account's referrer is paid");
    }

    // --- what the 64-byte form refuses, per trade -----------------------------

    /// A wallet cannot be its own introduction: no commission on the trade that
    /// tries, the same answer the 32-byte form has given since v1.6 ruling 5, Q5.
    function test_selfReferralIsRefusedInTheWalletForm() public {
        _buyAs(trader, _binding(trader, trader));
        assertEq(referrals.referrerOf(trader), address(0), "no lifetime self-rebate");
        assertEq(_pending(trader), 0, "and nothing paid on the trade that tried");
    }

    /// The same refusal, for the wallet the trade CLAIMS rather than for the
    /// one that signed. Found by `tools/mutate.py`: removing this check left
    /// every test in this suite green, because the rule above — a referrer who
    /// is the payer is no referrer — already catches the case where the named
    /// wallet IS the signer. The case it does not catch is the bundler shape,
    /// where the trade names an account as its own referrer and the account
    /// never signs anything. Without this test the check had no witness at all.
    function test_selfReferralIsRefusedForTheNamedWalletToo() public {
        // `trader` submits; the trade names `stranger` as both referrer and wallet.
        _buy(key, coinIsCurrency0, -1_000e18, _binding(stranger, stranger), trader);

        assertEq(_pending(stranger), 0, "an account cannot be its own introduction, signed or bundled");
        assertEq(referrals.referrerOf(stranger), address(0), "and nothing bound");
        assertEq(referrals.referrerOf(trader), address(0), "nor for the wallet that submitted it");
    }

    /// Q2, ruled: `0x…dEaD` is not a referrer in the 64-byte form, so no trade
    /// in that form burns a tenth of its fee; the registry refuses to bind it.
    function test_theBurnAddressIsNeverAReferrerInTheWalletForm() public {
        _buyAs(trader, _binding(FeastConstants.BURN_ADDRESS, trader));
        assertEq(referrals.referrerOf(trader), address(0), "the burn address cannot be bound");
        assertEq(_pending(FeastConstants.BURN_ADDRESS), 0, "and is paid nothing on the trade that tried");
    }

    function test_aZeroReferrerNeitherBindsNorPays() public {
        _buyAs(trader, _binding(address(0), trader));
        assertEq(referrals.referrerOf(trader), address(0), "no binding to nobody");
        assertEq(_pending(address(0)), 0, "the zero address is never a claimant");
    }

    /// A bundler-submitted account-abstraction trade: the wallet named in
    /// `hookData` is not the signer, so the hook does not believe the claim. It
    /// does not bind, and it falls back to exactly today's per-trade rule.
    function test_aBundlerShapedTradeDoesNotBindButStillPaysPerTrade() public {
        // `stranger` submits; the trade names `trader` as the wallet.
        _buy(key, coinIsCurrency0, -1_000e18, _binding(referrer, trader), stranger);

        assertEq(referrals.referrerOf(trader), address(0), "the named wallet was not bound");
        assertEq(referrals.referrerOf(stranger), address(0), "and neither was the submitter");
        assertGt(_pending(referrer), 0, "but the referrer was paid for this trade, as today");
    }

    /// A word whose top 96 bits are dirty is not an address. The wallet word
    /// gets the same reader the referrer word has always had, so a malformed
    /// one reads as zero, and the trade pays per trade. It is never an error.
    function test_aDirtyWalletWordDoesNotBindAndStillPays() public {
        bytes memory data = abi.encodePacked(bytes32(uint256(uint160(referrer))), bytes32(type(uint256).max));
        assertEq(data.length, 64, "still the 64-byte length");

        _buyAs(trader, data);

        assertEq(referrals.referrerOf(trader), address(0), "garbage is not an authorisation");
        assertGt(_pending(referrer), 0, "and the trade behind it was neither refused nor unpaid");
    }

    // --- the legacy form, unchanged ---------------------------------------

    function test_theLegacyFormPaysPerTradeAndNeverBinds() public {
        _buyAs(trader, _legacy(referrer));
        assertGt(_pending(referrer), 0, "paid, exactly as on v1.6.7");
        assertEq(referrals.referrerOf(trader), address(0), "and bound nothing");

        _buyAs(trader, "");
        uint256 afterUnnamed = _pending(referrer);
        _buyAs(trader, "");
        assertEq(_pending(referrer), afterUnnamed, "an unnamed trade afterwards still pays nobody");
    }

    /// v1.6 ruling 5, Q5 already decided this for the per-trade form: a referrer
    /// who is the payer is no referral at all, no commission and no credit. The
    /// 64-byte form refuses it the same way, so the two cannot drift apart —
    /// one rule, stated once, reached from both lengths.
    function test_theLegacyFormRefusesSelfReferralAsItAlreadyDid() public {
        _buyAs(trader, _legacy(trader));
        assertEq(_pending(trader), 0, "no self-rebate, exactly as on v1.6.7");
        assertEq(referrals.referrerOf(trader), address(0), "and nothing bound");
    }

    /// The legacy form may still name the burn address, and the commission is
    /// burned when anybody claims it. Unchanged from v1.6.7 on purpose: what
    /// the ruling refuses is making that choice permanent, not making it once.
    function test_theLegacyFormMayStillNameTheBurnAddress() public {
        _buyAs(trader, _legacy(FeastConstants.BURN_ADDRESS));
        assertGt(_pending(FeastConstants.BURN_ADDRESS), 0, "unchanged from v1.6.7");
        assertEq(referrals.referrerOf(trader), address(0), "but it never becomes a binding");
    }

    // --- I1 / R3: no length of hookData may cost a trader their swap -------

    function test_noLengthOfHookDataRefusesATrade() public {
        // Both valid forms are in here too, filled with garbage: an all-ones
        // 32- or 64-byte blob is a length the hook KNOWS, carrying words it
        // must still refuse to read as addresses.
        uint256[9] memory lengths = [uint256(0), 1, 31, 32, 33, 63, 64, 65, 128];
        for (uint256 i = 0; i < lengths.length; i++) {
            bytes memory blob = new bytes(lengths[i]);
            for (uint256 j = 0; j < blob.length; j++) {
                blob[j] = 0xff;
            }
            _buyAs(stranger, blob);
        }
        assertEq(referrals.referrerOf(stranger), address(0), "and not one of them bound anything");
    }

    function testFuzz_anyHookDataIsStillSurvivableIncludingTheNewLength(bytes calldata blob) public {
        vm.assume(blob.length < 200);
        _buyAs(stranger, blob);
        assertGt(hook.poolInfo(key.toId()).accruedQuote, 0, "the swap went through");
    }

    // --- I6: the four shares still sum to what was taken -------------------

    /// The binding changes WHO is paid, never HOW MUCH. `_bank` is not touched,
    /// so a bound wallet's trade splits exactly as a named trade always has.
    function testFuzz_theFourSharesStillSumToWhatWasTakenForABoundWallet(uint96 raw, bool bindFirst) public {
        if (bindFirst) _bind(trader, referrer);

        uint256 size = bound(uint256(raw), 1e18, 100_000e18);
        _buy(key, coinIsCurrency0, -int256(size), "", trader);

        PoolId id = key.toId();
        uint256 total = hook.poolInfo(id).accruedQuote;
        uint256 sum = hook.selfBurnPending(id) + hook.platformPending(id) + hook.creatorPending(id)
            + hook.referrerPending(id, referrer);
        assertEq(sum, total, "the four shares are the whole fee, exactly");
    }

    /// A bound wallet's ordinary trade is banked as a referred trade: the
    /// referrer takes `referrerBps` and the creator's remainder shrinks by
    /// exactly that, which is the economics the owner signed off.
    function test_aBoundWalletsUnnamedTradeIsSplitAsAReferredTrade() public {
        _bind(trader, referrer);

        PoolId id = key.toId();
        uint256 before_ = hook.poolInfo(id).accruedQuote;
        _buyAs(trader, "");
        uint256 taken = hook.poolInfo(id).accruedQuote - before_;

        assertEq(
            _pending(referrer),
            taken * FeastConstants.DEFAULT_REFERRER_BPS / FeastConstants.BPS,
            "the bound referrer takes referrerBps of this trade's fee"
        );
    }

    /// The claim paths are not touched by any of this, and the way to say so is
    /// to take the money out. A bound referrer is just an address that now
    /// appears in more pools' ledgers.
    function test_aBoundReferrerCanClaimWhatTheBindingEarnedThem() public {
        _bind(trader, referrer);
        _buyAs(trader, "");

        uint256 owed = _pending(referrer);
        assertGt(owed, 0, "the binding earned a commission on a trade that named nobody");

        hook.claimReferrer(key, referrer);

        assertEq(quoteToken.balanceOf(referrer), owed, "paid, in the pool's quote token");
        assertEq(_pending(referrer), 0, "and not owed twice");
    }

    // --- I3: nothing in the hook writes a binding, and the bytecode says so ---

    /// "We did not write one" is a claim; this is evidence. The same shape
    /// `test_noShareSetterExists` uses for the shares. Since v1.6.26 the hook
    /// has no binding entry and no binding getter at all — they are the
    /// registry's.
    function test_noReferrerSetterExists() public {
        string[8] memory sigs = [
            "setReferrer(address,address)",
            "setReferrerOf(address,address)",
            "bindReferrer(address,address)",
            "rebindReferrer(address,address)",
            "clearReferrer(address,address)",
            "bind(address)",
            "bindWithSig(address,address,uint256,bytes)",
            "referrerOf(address)"
        ];
        for (uint256 i = 0; i < sigs.length; i++) {
            (bool ok,) = address(hook).call(abi.encodeWithSignature(sigs[i], trader, referrer));
            assertFalse(ok, sigs[i]);
        }
        assertEq(referrals.referrerOf(trader), address(0), "and nothing moved");
    }

    // --- what the binding reaches beyond referrerBps -----------------------

    /// `_accrue` records the referrer in `FeastFeeLedger` whatever the pool's
    /// `referrerBps` is — that ledger is what the first year's emissions and the
    /// genesis partners are divided against. So a binding does not only
    /// redirect `referrerBps`: it credits the bound referrer's REFERRED track on
    /// every trade the wallet ever makes, on every pool, including pools that
    /// pay no commission at all.
    ///
    /// Stated and pinned rather than discovered. It follows from the owner's
    /// ruling rather than contradicting it, but it is larger than "who receives
    /// the commission" and the docs say so.
    function test_aBindingCreditsTheReferrersLedgerTrackOnEveryTrade() public {
        _bind(trader, referrer);
        uint256 week = ledger.currentWeek();
        address quote0 = Currency.unwrap(coinIsCurrency0_0 ? key0.currency1 : key0.currency0);

        // A trade that names nobody, on a pool that pays no commission.
        _buyAsOnZeroPool(trader, "");
        uint256 first = ledger.credit(week, quote0, referrer).referred;
        assertGt(first, 0, "the first trade after binding credited the track");

        _buyAsOnZeroPool(trader, "");

        assertEq(hook.referrerPending(key0.toId(), referrer), 0, "no commission: referrerBps is zero here");
        assertGt(
            ledger.credit(week, quote0, referrer).referred,
            first,
            "and the referred track grew again, on a trade that named nobody"
        );
    }

    // --- the read of the registry ----------------------------------------------
    //
    // `_referrerFor` reads `referrals.referrerOf(tx.origin)` in assembly, for
    // bytes. These pin that it is the call Solidity would make: to the registry
    // the hook was built with, under the getter's selector, refusing every
    // answer Solidity's decoder would refuse rather than paying a garbage word.

    function test_theHookReadsTheRegistryItWasBuiltWith() public view {
        assertEq(address(hook.referrals()), address(referrals), "the registry the hook was built with");
        assertEq(referrals.referrerOf.selector, bytes4(0xd21cacdf), "the selector the hook's read names");
    }

    /// A hook on its own pool, built over `registry`, and the buy that has to
    /// read it.
    function _buyOnAHookOver(address registry) internal returns (FeastHook h) {
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 2);
        FeastOracle o = new FeastOracle(predicted);
        FeastFeeLedger l = new FeastFeeLedger(predicted);
        h = new FeastHook(address(pm), address(vault), factory, address(o), address(l), address(0),
            address(guardian), registry, new FeastHook.TipFloor[](0));
        assertEq(address(h), predicted, "hook wiring");
        (PoolKey memory k, bool coinIs0) = _createPoolOn(h, FeastConstants.DEFAULT_REFERRER_BPS, SUPPLY);

        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(h),
                IFeastCLHooks.beforeSwap.selector,
                bytes(""),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        _buy(k, coinIs0, -1_000e18, "", trader);
    }

    /// No code: the call "succeeds" with no answer, and the hook would read its
    /// own calldata back as a referrer. It refuses instead.
    function test_aRegistryWithNoCodeRefusesTheTradeRatherThanPayingGarbage() public {
        _buyOnAHookOver(address(0xC0DE1E55));
    }

    function test_aRegistryAnsweringADirtyWordRefusesTheTrade() public {
        _buyOnAHookOver(address(new DirtyWordRegistry()));
    }

    function test_aRegistryAnsweringShortRefusesTheTrade() public {
        _buyOnAHookOver(address(new ShortAnswerRegistry()));
    }

    function test_aRegistryThatRevertsRefusesTheTrade() public {
        _buyOnAHookOver(address(new RevertingRegistry()));
    }

    // --- gas ---------------------------------------------------------------
    //
    // Measured on this fixture. `docs/referrer-binding.md` §3 has the table and
    // the provenance.

    /// The same plain trade on `v1.6.7-internal`, this fixture. Reproduce it by
    /// pointing `src/FeastHook.sol` at `git show v1.6.7-internal:src/FeastHook.sol`
    /// and running the probe archived at
    /// `.runs/operator/spike/FeastV167GasBaseline.probe.sol`.
    ///
    /// **223,123 -> 225,033, re-measured at `optimizer_runs = 1_000`** (task 567,
    /// 2026-09-19). This is a CALIBRATION constant, not a budget: it is one half
    /// of a subtraction, and a subtraction between two numbers compiled at
    /// different settings measures the settings. The v1.6.7 hook costs 1,910 gas
    /// more per trade at 1_000 runs than at 20_000, for the same reason every
    /// contract got smaller — less inlining. Re-measured the way the line above
    /// says: v1.6.7's `FeastHook.sol` in the tree, this fixture copied verbatim
    /// into a throwaway probe (today's suite does not compile against a hook
    /// with no `referrerOf`), `forge test` at the current setting.
    uint256 internal constant V167_PLAIN_TRADE_GAS = 225_033;
    /// What this mechanism costs every trade in every feast pool, for ever,
    /// bound or not, `hookData` or not: until v1.6.25 one cold SLOAD of
    /// `_referrerOf[tx.origin]` at 2,100, plus the widened length branch, plus
    /// — from v1.6.10 — the two tests that keep a protocol-initiated swap out
    /// of the referral track at all (CA-0d1fa81d6c) and arm a gated pool's
    /// opening cap when its gate opens (CA-eeefa2ee72).
    ///
    /// **2,376 -> 2,634, and every one of those 258 gas is a warm read or a
    /// branch.** Both new tests lead on `openAt`, which the gate has already
    /// read into a local, so an ORDINARY pool touches no slot it was not
    /// touching before: `opener` and the served-block counters each have a cold slot of
    /// their own and are reached only by a pool that actually carries a gate.
    /// The first draft of the fix read both unconditionally and cost 4,802.
    ///
    /// **2,376 -> 2,634 -> 2,661.** The first step is the mechanism growing at
    /// v1.6.10; the second is the optimizer setting, and it is 27 gas — the
    /// measurement moved by 1.0%, well inside this test's 5% band, which is the
    /// answer to "did lowering the run count change what the referral lookup
    /// costs". It did not, to within a rounding of the tolerance. The constant
    /// is set to the number that was measured rather than left at the number
    /// that would still have passed.
    ///
    /// **2,661 -> 2,756 at v1.6.10's creator pre-buy.** The protocol-swap test
    /// gained a third clause, and every trade in every pool evaluates it. The
    /// first draft folded the whole predicate into one helper and cost 154 gas;
    /// splitting it so the call site does the immutable compare
    /// (`sender == factory`) and only a swap that passes it reaches the
    /// transient load brought that to 95. This test is what measured both.
    ///
    /// **2,756 -> 5,798 at v1.6.26 (AstraSec M-4), +3,042.** The binding moved
    /// to `FeastReferrals`, so the lookup is an external read — a cold account
    /// and a cold slot THERE, and the call — where it was a cold slot here.
    /// Measured as the same plain trade on this fixture at `bf1d930` (v1.6.25),
    /// 233,767, and at v1.6.26, 236,809, with every address in the fixture the
    /// same: the registry is etched and spends no nonce. (Deployed with `new`,
    /// it moved the tokens and the hook by one CREATE and the same trade read
    /// 93 gas more — a fixture artefact, not the read.) With `GUARDIAN_GAS` the
    /// expectation is 11,474 against 11,776 measured; the 302 between them was
    /// already there at `bf1d930` (8,734 measured against 8,432) and is not
    /// attributed here either.
    uint256 internal constant LOOKUP_GAS = 5_798;
    /// What the GUARDIAN costs every trade in every feast pool, for ever: the
    /// first thing `_beforeSwap` does is ask it whether this pool is frozen.
    /// Measured at v1.6.12, held separately from `LOOKUP_GAS` so neither number
    /// hides inside the other.
    ///
    /// **5,374 gas**, and it is not one cold SLOAD — it is a cold ACCOUNT access
    /// (2,600) plus a cold SLOAD of `frozenUntil` (2,100) plus the call frame.
    /// The non-frozen path returns on that first slot, so it is one SLOAD and
    /// not three: `allFrozen` and `frozenPool` are never reached.
    ///
    /// It is 2.3% of a plain trade and it is the price of the brake existing at
    /// all. The alternative — the freeze state inlined into the hook, so the
    /// read is warm — does not fit: the hook has 642 bytes of margin after this
    /// change, and moving the timing arithmetic in would take more than that.
    /// Reported rather than optimised away, because the coordinator asked for
    /// the number and this is the number.
    /// **5,374 -> 8,430 at v1.6.14 -> 5,556 at v1.6.15.** v1.6.14 made
    /// `_afterSwap` ask the guardian a second question, `frozenBlocks()`, on
    /// every trade, so the opening cap could be measured in open blocks. v1.6.15
    /// deletes that counter — a contract cannot observe its chain's block rate —
    /// and anchors the cap window on the pool's first served swap instead, so
    /// the second question is gone and the brake is one read again.
    ///
    /// **5,556 measured**, as `plain - V167_PLAIN_TRADE_GAS - LOOKUP_GAS`
    /// = 8,312 - 2,756. 2.4% of a plain trade of 233,345.
    ///
    /// The 182 gas above v1.6.13's 5,374 is NOT attributed here. The
    /// counterfactual was run rather than narrated: short-circuiting the new
    /// counting branch in `_beforeSwap` so its `servedBlocks` read cannot happen
    /// measures 8,337, which is 25 gas MORE than with the branch live and in the
    /// wrong direction — the branch costs nothing measurable on an ordinary
    /// trade, because the slot it reads is already warm. Whatever the 182 is, it
    /// is not the arming read, and this comment does not guess.
    ///
    /// **5,556 -> 5,676 at v1.6.16**, measured as
    /// `plain - V167_PLAIN_TRADE_GAS - LOOKUP_GAS` = 8,432 - 2,756, on a plain
    /// trade of 233,465. The open-time gate v1.6.16 put on every read of an
    /// oracle average costs **120 gas** on a plain BUY, because a buy does not
    /// reach the internal fill and the button is not on the swap path.
    ///
    /// **On an exact-input SELL that does reach the fill it costs 3,771 gas**,
    /// 1.6% of a plain trade. Counterfactual rather than narrated: removing the
    /// gate from `_spotIsNearAverage` alone moves
    /// `FeastInternalFillTest.test_aFillNeverTouchesTheQuoteToken` from 370,022
    /// to 366,251 and `test_aFilledSaleReportsTheSellersOwnAmounts` from
    /// 363,145 to 359,374 — the same 3,771 in both, which is what one gated
    /// fill costs.
    ///
    /// The guardian's `allFrozen`, `frozenUntil`, `frozenFrom` and
    /// `allUnfrozenTotal` share one slot so that the gate's question is a WARM
    /// read of the slot `isFrozen` already paid for; what remains cold is the
    /// per-pool resume instant, which is a mapping and cannot be packed.
    ///
    /// Reported rather than optimised away, and held separately from
    /// `LOOKUP_GAS` so neither number hides inside the other.
    uint256 internal constant GUARDIAN_GAS = 5_676;

    function _within5Percent(uint256 measured, uint256 expected, string memory what) internal pure {
        require(measured * 100 >= expected * 95 && measured * 100 <= expected * 105, what);
    }

    function test_gas_theLookupCostsOneColdExternalReadOnEveryTrade() public {
        _buyAsOnZeroPool(trader, "");
        uint256 plain = _buyAsOnZeroPool(trader, "");
        emit log_named_uint("plain trade, referrerBps = 0", plain);
        emit log_named_uint("the lookup, against v1.6.7", plain - V167_PLAIN_TRADE_GAS);
        _within5Percent(
            plain - V167_PLAIN_TRADE_GAS, LOOKUP_GAS + GUARDIAN_GAS, "the lookup and the guardian, and nothing else"
        );
    }
}
