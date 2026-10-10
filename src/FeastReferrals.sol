// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";

import {FeastConstants} from "./FeastConstants.sol";

/// @title The referral registry
/// @notice Who brought each wallet: written once, by the wallet itself, and
///         never changed. The hook reads it on every trade; nothing writes it
///         but the wallet.
///
/// @dev **v1.6.26 (AstraSec M-4).** Until v1.6.25 the binding lived in the
///      hook and was INFERRED: a 64-byte `hookData` whose wallet word equalled
///      `tx.origin` bound that origin for life. Under ERC-4337, and for every
///      7702 sponsor and relayer, `tx.origin` is the party that SUBMITTED the
///      transaction while somebody else wrote its calldata, so one user
///      operation carrying `abi.encode(attacker, bundler)` bound the bundler
///      to the attacker, and every later trade it relayed paid the attacker
///      (`test/audit/poc/SharedOriginCapture.t.sol`). The chain cannot tell a
///      bundler's key from a user's, so no rule about WHICH origins to believe
///      could have closed it.
///
///      **A binding is authenticated, never inferred** (owner ruling,
///      2026-10-04). A wallet is bound only by its own call — `bind`, where
///      the wallet is `msg.sender` — or by its own signature — `bindWithSig`,
///      which anyone may relay, checked by OpenZeppelin's `SignatureChecker`:
///      ECDSA for a key, ERC-1271 for a contract account.
///
///      No admin, no setter, no clear, no upgrade path. The one write is
///      `_bind`, and only ever from zero, so the first binding wins for ever.
///      That is the v1.6.8 ruling unchanged: a second binding would be unfair
///      to the first referrer and would invite poaching.
contract FeastReferrals {
    error ZeroReferrer();
    error SelfReferral();
    error BurnReferrer();
    error AlreadyBound();
    error BadSignature();
    error SignatureExpired();

    event ReferrerBound(address indexed wallet, address indexed referrer);

    /// @dev EIP-712. The domain is `FeastReferrals`, version `1`, this chain
    ///      and this contract, so a signature cannot be replayed on another
    ///      chain or against another registry. The domain separator is
    ///      computed on every call rather than cached, so it follows the chain
    ///      id through a fork with no cache to invalidate.
    bytes32 private constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 private constant NAME_HASH = keccak256("FeastReferrals");
    bytes32 private constant VERSION_HASH = keccak256("1");
    bytes32 private constant BIND_TYPEHASH = keccak256("Bind(address wallet,address referrer,uint256 deadline)");

    /// @notice The referrer a wallet is bound to for life, or the zero address
    ///         if it has never bound. Global, not per pool: the relationship is
    ///         with the WALLET, so it follows the wallet into every coin.
    mapping(address wallet => address referrer) public referrerOf;

    /// @notice Bind the caller to `referrer`, for life.
    function bind(address referrer) external {
        _bind(msg.sender, referrer);
    }

    /// @notice Bind `wallet` to `referrer`, for life, on the wallet's own
    ///         EIP-712 signature of `Bind(wallet, referrer, deadline)`. Anyone
    ///         may relay it.
    /// @dev No nonce. A wallet binds once for ever, so a replay of a signature
    ///      that has already bound reverts `AlreadyBound`, and `deadline`
    ///      bounds how long an unused one lives: after it, `SignatureExpired`,
    ///      as for EIP-2612. An unexpired signature is a standing consent: if
    ///      the wallet binds otherwise first, the signature can never bind, and
    ///      if it is relayed first, it has bound.
    ///
    ///      The signature is checked before the referrer is, so a relayed call
    ///      learns nothing about a wallet that did not sign it. A contract
    ///      account's ERC-1271 answer is read when the call is made, which is
    ///      the only moment it can be: such a signature may be revoked.
    function bindWithSig(address wallet, address referrer, uint256 deadline, bytes calldata signature) external {
        if (block.timestamp > deadline) revert SignatureExpired();
        bytes32 digest = MessageHashUtils.toTypedDataHash(
            keccak256(abi.encode(DOMAIN_TYPEHASH, NAME_HASH, VERSION_HASH, block.chainid, address(this))),
            keccak256(abi.encode(BIND_TYPEHASH, wallet, referrer, deadline))
        );
        if (!SignatureChecker.isValidSignatureNow(wallet, digest, signature)) revert BadSignature();
        _bind(wallet, referrer);
    }

    /// @dev The one write, reached from both entries, so the refusals cannot
    ///      drift apart. They are the hook's own, unchanged since v1.6.8:
    ///      - nobody is not a referrer;
    ///      - a wallet cannot be its own introduction (v1.6 ruling 5, Q5), so
    ///        there is no lifetime self-rebate;
    ///      - the burn address is not a referrer: bound, it would burn the
    ///        referrer share of every fee the wallet paid, with no way back.
    function _bind(address wallet, address referrer) private {
        if (referrer == address(0)) revert ZeroReferrer();
        if (referrer == wallet) revert SelfReferral();
        if (referrer == FeastConstants.BURN_ADDRESS) revert BurnReferrer();
        if (referrerOf[wallet] != address(0)) revert AlreadyBound();
        referrerOf[wallet] = referrer;
        emit ReferrerBound(wallet, referrer);
    }
}
