// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

import {FeastConstants} from "../src/FeastConstants.sol";
import {FeastReferrals} from "../src/FeastReferrals.sol";

/// A contract account in the smallest honest shape: one key signs for it
/// (ERC-1271), and only that key makes it call out.
contract MockSmartAccount {
    address internal immutable signer;

    constructor(address signer_) {
        signer = signer_;
    }

    function isValidSignature(bytes32 hash, bytes calldata signature) external view returns (bytes4) {
        (address recovered, ECDSA.RecoverError err,) = ECDSA.tryRecover(hash, signature);
        return err == ECDSA.RecoverError.NoError && recovered == signer
            ? IERC1271.isValidSignature.selector
            : bytes4(0xffffffff);
    }

    function execute(address target, bytes calldata data) external {
        require(msg.sender == signer, "not the account's key");
        (bool ok, bytes memory reason) = target.call(data);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(reason, 0x20), mload(reason))
            }
        }
    }
}

/// The referral registry (v1.6.26, AstraSec M-4): a wallet is bound only by
/// its own call or its own signature, once, for ever.
///
/// The hook side — which binding pays on which trade — is
/// `FeastReferrerBinding.t.sol`. This suite is the registry alone: who may
/// write, what is refused, and the exact bytes an integrator signs.
contract FeastReferralsTest is Test {
    FeastReferrals internal referrals;

    uint256 internal constant WALLET_KEY = 0xA11CE;
    uint256 internal constant ACCOUNT_KEY = 0xACC7;
    uint256 internal constant STRANGER_KEY = 0x57A0;
    address internal wallet;
    address internal referrer = address(0xEE);
    address internal other = address(0x0EE2);
    address internal relayer = address(0x7E1A7);

    uint256 internal deadline;

    /// secp256k1's group order: `s` above half of it is the malleable twin of
    /// a valid signature, which OpenZeppelin's ECDSA refuses.
    uint256 internal constant SECP256K1_N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;

    function setUp() public {
        vm.warp(1_791_158_400);
        referrals = new FeastReferrals();
        wallet = vm.addr(WALLET_KEY);
        deadline = block.timestamp + 1 days;
    }

    // --- helpers -------------------------------------------------------------

    /// EIP-712, written out again here rather than read from the contract, so
    /// the registry is checked against the standard and not against itself.
    function _digest(address registry, uint256 chainId, address w, address r, uint256 d)
        internal
        pure
        returns (bytes32)
    {
        bytes32 domainSeparator = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("FeastReferrals"),
                keccak256("1"),
                chainId,
                registry
            )
        );
        bytes32 structHash =
            keccak256(abi.encode(keccak256("Bind(address wallet,address referrer,uint256 deadline)"), w, r, d));
        return keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
    }

    function _sign(uint256 key, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }

    /// The wallet's own signature of `Bind(w, r, d)` on this registry, this chain.
    function _signed(uint256 key, address w, address r, uint256 d) internal view returns (bytes memory) {
        return _sign(key, _digest(address(referrals), block.chainid, w, r, d));
    }

    function _relay(address w, address r, uint256 d, bytes memory signature) internal {
        vm.prank(relayer);
        referrals.bindWithSig(w, r, d, signature);
    }

    // --- the two ways in -----------------------------------------------------

    function test_aWalletBindsItselfByItsOwnCall() public {
        assertEq(referrals.referrerOf(wallet), address(0), "nobody starts bound");

        vm.expectEmit(true, true, false, true, address(referrals));
        emit FeastReferrals.ReferrerBound(wallet, referrer);
        vm.prank(wallet);
        referrals.bind(referrer);

        assertEq(referrals.referrerOf(wallet), referrer, "the caller is bound");
    }

    /// Relayed by a third party, which pays the gas and decides nothing: the
    /// pair bound is the pair the wallet signed.
    function test_anEoaBindsBySignatureAndAnyoneMayRelayIt() public {
        bytes memory signature = _signed(WALLET_KEY, wallet, referrer, deadline);

        vm.expectEmit(true, true, false, true, address(referrals));
        emit FeastReferrals.ReferrerBound(wallet, referrer);
        _relay(wallet, referrer, deadline, signature);

        assertEq(referrals.referrerOf(wallet), referrer, "the signer is bound");
        assertEq(referrals.referrerOf(relayer), address(0), "and the relayer is not");
    }

    /// ERC-1271: a contract account signs through its own `isValidSignature`.
    function test_aContractAccountBindsBySignatureThroughErc1271() public {
        MockSmartAccount account = new MockSmartAccount(vm.addr(ACCOUNT_KEY));
        bytes memory signature = _signed(ACCOUNT_KEY, address(account), referrer, deadline);

        _relay(address(account), referrer, deadline, signature);

        assertEq(referrals.referrerOf(address(account)), referrer, "the account is bound");
    }

    /// And the account's answer is what decides: a key that is not the
    /// account's cannot sign for it, however well-formed the signature.
    function test_aContractAccountRefusesASignatureItDoesNotRecognise() public {
        MockSmartAccount account = new MockSmartAccount(vm.addr(ACCOUNT_KEY));
        bytes memory signature = _signed(STRANGER_KEY, address(account), referrer, deadline);

        vm.expectRevert(FeastReferrals.BadSignature.selector);
        _relay(address(account), referrer, deadline, signature);
        assertEq(referrals.referrerOf(address(account)), address(0), "nothing bound");
    }

    /// The other way in for a contract account: its own call, which is how a
    /// user operation binds — `bind` batched beside the trade.
    function test_aContractAccountBindsByItsOwnCallToo() public {
        address key = vm.addr(ACCOUNT_KEY);
        MockSmartAccount account = new MockSmartAccount(key);

        vm.prank(key);
        account.execute(address(referrals), abi.encodeCall(FeastReferrals.bind, (referrer)));

        assertEq(referrals.referrerOf(address(account)), referrer, "the account bound itself");
        assertEq(referrals.referrerOf(key), address(0), "and its key is not bound");
    }

    // --- the deadline ----------------------------------------------------------

    /// Both sides of the bound: a signature is good AT its deadline and
    /// refused one second after it.
    function test_aSignatureIsGoodUntilItsDeadlineAndNotASecondLonger() public {
        bytes memory signature = _signed(WALLET_KEY, wallet, referrer, deadline);

        vm.warp(deadline + 1);
        vm.expectRevert(FeastReferrals.SignatureExpired.selector);
        _relay(wallet, referrer, deadline, signature);

        vm.warp(deadline);
        _relay(wallet, referrer, deadline, signature);
        assertEq(referrals.referrerOf(wallet), referrer, "bound at the deadline itself");
    }

    // --- once, for ever ----------------------------------------------------------

    /// No nonce, and none needed: a signature that has bound can only bind a
    /// wallet that is already bound.
    function test_aReplayedSignatureIsRefusedOnceItHasBound() public {
        bytes memory signature = _signed(WALLET_KEY, wallet, referrer, deadline);
        _relay(wallet, referrer, deadline, signature);

        vm.expectRevert(FeastReferrals.AlreadyBound.selector);
        _relay(wallet, referrer, deadline, signature);
    }

    /// First wins, by either entry, against either entry.
    function test_theFirstBindingWinsByEitherEntry() public {
        vm.prank(wallet);
        referrals.bind(referrer);

        vm.prank(wallet);
        vm.expectRevert(FeastReferrals.AlreadyBound.selector);
        referrals.bind(other);

        bytes memory signature = _signed(WALLET_KEY, wallet, other, deadline);
        vm.expectRevert(FeastReferrals.AlreadyBound.selector);
        _relay(wallet, other, deadline, signature);

        assertEq(referrals.referrerOf(wallet), referrer, "still the first referrer");
    }

    /// A standing signature loses to the wallet's own later call, and the other
    /// way round: whichever lands first is the binding.
    function test_aStandingSignatureLosesToTheWalletsOwnEarlierCall() public {
        bytes memory signature = _signed(WALLET_KEY, wallet, other, deadline);

        vm.prank(wallet);
        referrals.bind(referrer);

        vm.expectRevert(FeastReferrals.AlreadyBound.selector);
        _relay(wallet, other, deadline, signature);
        assertEq(referrals.referrerOf(wallet), referrer, "the call landed first");
    }

    // --- the refusals, the hook's own since v1.6.8 ------------------------------

    function test_eachRefusalByTheCallersOwnEntry() public {
        vm.startPrank(wallet);
        vm.expectRevert(FeastReferrals.ZeroReferrer.selector);
        referrals.bind(address(0));
        vm.expectRevert(FeastReferrals.SelfReferral.selector);
        referrals.bind(wallet);
        vm.expectRevert(FeastReferrals.BurnReferrer.selector);
        referrals.bind(FeastConstants.BURN_ADDRESS);
        vm.stopPrank();

        assertEq(referrals.referrerOf(wallet), address(0), "three refusals, nothing bound");
    }

    /// The same three, reached through a valid signature, so the refusal and
    /// not the signature is what stops each one.
    function test_eachRefusalBySignatureToo() public {
        address[3] memory refused = [address(0), wallet, FeastConstants.BURN_ADDRESS];
        bytes4[3] memory errors = [
            FeastReferrals.ZeroReferrer.selector,
            FeastReferrals.SelfReferral.selector,
            FeastReferrals.BurnReferrer.selector
        ];
        for (uint256 i = 0; i < 3; i++) {
            bytes memory signature = _signed(WALLET_KEY, wallet, refused[i], deadline);
            vm.expectRevert(errors[i]);
            _relay(wallet, refused[i], deadline, signature);
        }
        assertEq(referrals.referrerOf(wallet), address(0), "nothing bound");
    }

    /// A signature binds exactly the wallet, referrer and deadline it signed:
    /// change any one and it is somebody else's statement.
    function test_aSignatureBindsOnlyWhatItSigned() public {
        bytes memory signature = _signed(WALLET_KEY, wallet, referrer, deadline);

        vm.expectRevert(FeastReferrals.BadSignature.selector);
        _relay(wallet, other, deadline, signature);
        vm.expectRevert(FeastReferrals.BadSignature.selector);
        _relay(wallet, referrer, deadline + 1, signature);
        vm.expectRevert(FeastReferrals.BadSignature.selector);
        _relay(vm.addr(STRANGER_KEY), referrer, deadline, signature);

        // And the control, so the three refusals above are about the change:
        _relay(wallet, referrer, deadline, signature);
        assertEq(referrals.referrerOf(wallet), referrer, "the signed pair binds");
    }

    function test_aStrangersSignatureCannotBindAWallet() public {
        bytes memory signature = _signed(STRANGER_KEY, wallet, referrer, deadline);
        vm.expectRevert(FeastReferrals.BadSignature.selector);
        _relay(wallet, referrer, deadline, signature);
        assertEq(referrals.referrerOf(wallet), address(0), "nothing bound");
    }

    /// Malformed signatures are refused by name rather than reverting inside
    /// the library: a short one, a long one, an empty one, and the malleable
    /// high-`s` twin of a valid one.
    function test_malformedSignaturesAreRefusedByName() public {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(WALLET_KEY, _digest(address(referrals), block.chainid, wallet, referrer, deadline));
        bytes memory good = abi.encodePacked(r, s, v);

        bytes[4] memory bad = [
            abi.encodePacked(r, s),
            abi.encodePacked(r, s, v, uint8(0)),
            bytes(""),
            abi.encodePacked(r, bytes32(SECP256K1_N - uint256(s)), v == 27 ? uint8(28) : uint8(27))
        ];
        for (uint256 i = 0; i < bad.length; i++) {
            vm.expectRevert(FeastReferrals.BadSignature.selector);
            _relay(wallet, referrer, deadline, bad[i]);
        }

        // The control: the untouched signature binds.
        _relay(wallet, referrer, deadline, good);
        assertEq(referrals.referrerOf(wallet), referrer, "the well-formed one binds");
    }

    /// The zero address has no key, so no signature can bind it.
    function test_noSignatureBindsTheZeroAddress() public {
        bytes memory signature = _signed(WALLET_KEY, address(0), referrer, deadline);
        vm.expectRevert(FeastReferrals.BadSignature.selector);
        _relay(address(0), referrer, deadline, signature);
    }

    // --- the domain ------------------------------------------------------------

    /// A signature is this registry's, on this chain: the same bytes on a second
    /// registry, or on another chain, are refused.
    /// The chain ids are literals on purpose: via-IR re-reads `block.chainid`
    /// at each use, so a "home" saved from it follows `vm.chainId` away.
    function test_aSignatureIsBoundToItsChainAndItsRegistry() public {
        vm.chainId(56);
        bytes memory signature = _sign(WALLET_KEY, _digest(address(referrals), 56, wallet, referrer, deadline));

        FeastReferrals second = new FeastReferrals();
        vm.prank(relayer);
        vm.expectRevert(FeastReferrals.BadSignature.selector);
        second.bindWithSig(wallet, referrer, deadline, signature);

        vm.chainId(97);
        vm.expectRevert(FeastReferrals.BadSignature.selector);
        _relay(wallet, referrer, deadline, signature);

        vm.chainId(56);
        _relay(wallet, referrer, deadline, signature);
        assertEq(referrals.referrerOf(wallet), referrer, "at home it binds");
    }

    /// **The vectors the app signs against** (`docs/referrer-binding.md` §1).
    /// Computed twice outside this file and pinned here: by hand from
    /// `cast keccak` and `cast abi-encode`, and by alloy's EIP-712 encoder
    /// through `cast wallet sign --data`, whose signature over the typed data
    /// equals the signature over the hand-built digest. Chain 56, a registry at
    /// `0x…0fea57`, the well-known test keys 1 (wallet) and 2 (referrer).
    function test_theEip712VectorsTheAppSignsAgainst() public {
        address registry = address(uint160(0xfea57));
        deployCodeTo("FeastReferrals.sol:FeastReferrals", registry);
        vm.chainId(56);
        address w = vm.addr(1);
        address r = vm.addr(2);
        uint256 d = 1_800_000_000;
        assertEq(w, 0x7E5F4552091A69125d5DfCb7b8C2659029395Bdf, "test key 1");
        assertEq(r, 0x2B5AD5c4795c026514f8317c7a215E218DcCD6cF, "test key 2");

        assertEq(
            keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
            0x8b73c3c69bb8fe3d512ecc4cf759cc79239f7b179b0ffacaa9a75d522b39400f,
            "the domain type hash"
        );
        assertEq(
            keccak256("Bind(address wallet,address referrer,uint256 deadline)"),
            0x5c22698b6ffa0a9eeddd2868e00c1aafa8abe2abe36ac892441c080afe5c29a3,
            "the Bind type hash"
        );
        bytes32 domainSeparator = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("FeastReferrals"),
                keccak256("1"),
                uint256(56),
                registry
            )
        );
        assertEq(
            domainSeparator, 0xff720bfdecbbe1f58723d4cc3fbdb617718f5bcce5ef8492aa9b7ddbc1425aa9, "the domain separator"
        );
        bytes32 digest = _digest(registry, 56, w, r, d);
        assertEq(digest, 0x9a7ee5d3d9bb3b5b5c998dc01464bb5807bad490b34a9e95f190f7df3bea948b, "the digest");

        bytes memory signature =
            hex"76dba4a7cc611f28d3c71e256dfd42924f05d32343b398b578f0737ed7082557142e3e77e56f98998b6725467e1ea412fd404595caca13ea366026b4299261011c";
        assertEq(_sign(1, digest), signature, "the signature cast produced from the typed data");

        // And the registry agrees, which is the only proof that its digest is
        // this one: the signature binds there and nowhere else.
        vm.warp(d);
        vm.prank(relayer);
        FeastReferrals(registry).bindWithSig(w, r, d, signature);
        assertEq(FeastReferrals(registry).referrerOf(w), r, "the vector binds");
    }

    // --- no admin ----------------------------------------------------------------

    /// The registry's whole write surface is `bind` and `bindWithSig`; nothing
    /// clears, moves or overrides a binding, and the bytecode says so.
    function test_thereIsNoSetterNoClearAndNoOwner() public {
        vm.prank(wallet);
        referrals.bind(referrer);

        string[7] memory sigs = [
            "setReferrer(address,address)",
            "setReferrerOf(address,address)",
            "rebind(address,address)",
            "unbind(address)",
            "clearReferrer(address)",
            "transferOwnership(address)",
            "owner()"
        ];
        for (uint256 i = 0; i < sigs.length; i++) {
            (bool ok,) = address(referrals).call(abi.encodeWithSignature(sigs[i], wallet, other));
            assertFalse(ok, sigs[i]);
        }
        assertEq(referrals.referrerOf(wallet), referrer, "and nothing moved");
    }

    // --- fuzz --------------------------------------------------------------------

    function testFuzz_aSignatureBindsExactlyTheSignedPair(uint256 key, address r, uint32 lifetime) public {
        key = bound(key, 1, SECP256K1_N - 1);
        address w = vm.addr(key);
        vm.assume(r != address(0) && r != w && r != FeastConstants.BURN_ADDRESS);
        uint256 d = block.timestamp + lifetime;

        _relay(w, r, d, _signed(key, w, r, d));

        assertEq(referrals.referrerOf(w), r, "the signed pair, exactly");
    }

    function testFuzz_noKeyButTheWalletsBindsIt(uint256 key) public {
        key = bound(key, 1, SECP256K1_N - 1);
        vm.assume(key != WALLET_KEY);
        bytes memory signature = _signed(key, wallet, referrer, deadline);
        vm.expectRevert(FeastReferrals.BadSignature.selector);
        _relay(wallet, referrer, deadline, signature);
    }

    // --- gas -----------------------------------------------------------------------
    //
    // What a binding costs, once per wallet ever, under `isolate`: a cold
    // zero-to-non-zero store and one log, plus the signature check for the
    // relayed entry. Recorded for integrators in `docs/referrer-binding.md` §3.

    uint256 internal constant BIND_GAS = 52_651;
    uint256 internal constant BIND_WITH_SIG_GAS = 58_377;

    function _within5Percent(uint256 measured, uint256 expected, string memory what) internal pure {
        require(measured * 100 >= expected * 95 && measured * 100 <= expected * 105, what);
    }

    function test_gas_aBindingCostsOneStoreAndOneLog() public {
        vm.prank(wallet);
        uint256 before_ = gasleft();
        referrals.bind(referrer);
        uint256 used = before_ - gasleft();
        emit log_named_uint("bind", used);
        _within5Percent(used, BIND_GAS, "bind: one store and one log");
    }

    function test_gas_aRelayedBindingAddsTheSignatureCheck() public {
        bytes memory signature = _signed(WALLET_KEY, wallet, referrer, deadline);
        vm.prank(relayer);
        uint256 before_ = gasleft();
        referrals.bindWithSig(wallet, referrer, deadline, signature);
        uint256 used = before_ - gasleft();
        emit log_named_uint("bindWithSig (EOA)", used);
        _within5Percent(used, BIND_WITH_SIG_GAS, "bindWithSig: the store, the log and one ecrecover");
    }
}
