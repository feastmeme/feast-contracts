// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FeastConstants} from "./FeastConstants.sol";
import {FeastParameters} from "./FeastParameters.sol";
import {BalanceDelta} from "./venue/BalanceDelta.sol";
import {BeforeSwapDelta, ZERO_BEFORE_SWAP_DELTA} from "./venue/BeforeSwapDelta.sol";
import {IFeastCLHooks} from "./venue/IFeastCLHooks.sol";
import {IFeastCLPoolManager} from "./venue/IFeastCLPoolManager.sol";
import {IFeastLockCallback} from "./venue/IFeastLockCallback.sol";
import {PoolKey} from "./venue/PoolKey.sol";

/// @title Hook scaffold
/// @notice Registration, access control, and nothing else. The economics live in
///         `FeastHook`, which extends this.
///
/// @dev Written from scratch rather than inherited. The venue publishes a base
///      class that does exactly this job, and it is `UNLICENSED` with no LICENSE
///      file in its repository — the most convenient code is the code we may not
///      use. The interface it targets *is* MIT, so this reimplements against the
///      interface: about eighty lines rather than the three hundred and thirty
///      the original spends wrapping callbacks feast never registers.
///
///      Only the five registered permissions can ever fire. The venue reads the
///      bitmap from the pool key and calls nothing else, so the seven
///      unregistered callbacks are omitted rather than stubbed out as reverts.
abstract contract FeastCLHookBase is IFeastCLHooks, IFeastLockCallback {
    error NotPoolManager();
    error NotVault();
    error NotFactory();

    /// @notice beforeInitialize | beforeSwap | afterSwap | both return-delta bits.
    /// @dev The two return-delta permissions are what let the hook take a fee on
    ///      a named currency at all. The venue enforces that each requires its
    ///      base callback, which this satisfies.
    uint16 internal constant HOOKS_BITMAP = uint16(
        (1 << 0) // beforeInitialize
            | (1 << 6) // beforeSwap
            | (1 << 7) // afterSwap
            | (1 << 10) // beforeSwapReturnsDelta
            | (1 << 11) // afterSwapReturnsDelta
    );

    address public immutable poolManager;
    address public immutable vault;
    /// @notice The only address whose pool creation this hook will serve.
    address public immutable factory;

    constructor(address poolManager_, address vault_, address factory_) {
        poolManager = poolManager_;
        vault = vault_;
        factory = factory_;
    }

    modifier onlyPoolManager() {
        if (msg.sender != poolManager) revert NotPoolManager();
        _;
    }

    modifier onlyVault() {
        if (msg.sender != vault) revert NotVault();
        _;
    }

    /// @inheritdoc IFeastCLHooks
    function getHooksRegistrationBitmap() external pure returns (uint16) {
        return HOOKS_BITMAP;
    }

    /// @notice The `parameters` word every feast pool carries.
    /// @dev Exposed so the factory and any reviewer derive it from the same
    ///      place the hook reports, rather than from a copied literal.
    function poolParameters() public pure returns (bytes32) {
        return FeastParameters.encode(HOOKS_BITMAP, FeastConstants.POOL_TICK_SPACING);
    }

    /// @inheritdoc IFeastCLHooks
    /// @dev R1. `sender` is whoever called the venue's `initialize`. Refusing
    ///      everyone but the factory is what stops a stranger from creating a
    ///      second pool that bears this hook — with a quote token or a tick
    ///      spacing of their choosing — and thereby writing this hook's
    ///      per-pool state. The refusal has to live here, in the hook, because
    ///      the venue will happily build any pool whose key validates.
    function beforeInitialize(address sender, PoolKey calldata key, uint160)
        external
        onlyPoolManager
        returns (bytes4)
    {
        // The DEFAULT is the factory and nobody else, and it stays here rather
        // than in the override so that a hook which forgets to think about this
        // inherits the safe answer. `FeastHook` widens it for one case it can
        // see and the base cannot; see `_mayInitialize`.
        if (!_mayInitialize(sender, key)) revert NotFactory();
        _onPoolInitialized(key);
        return IFeastCLHooks.beforeInitialize.selector;
    }

    /// @inheritdoc IFeastCLHooks
    function beforeSwap(
        address sender,
        PoolKey calldata key,
        IFeastCLPoolManager.SwapParams calldata params,
        bytes calldata hookData
    ) external onlyPoolManager returns (bytes4, BeforeSwapDelta, uint24) {
        (BeforeSwapDelta delta) = _beforeSwap(sender, key, params, hookData);
        // The third return value is the dynamic LP fee. Feast pools are
        // static-fee, so the venue ignores it; returning zero is not a
        // placeholder, it is the correct value.
        return (IFeastCLHooks.beforeSwap.selector, delta, 0);
    }

    /// @inheritdoc IFeastCLHooks
    function afterSwap(
        address sender,
        PoolKey calldata key,
        IFeastCLPoolManager.SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) external onlyPoolManager returns (bytes4, int128) {
        int128 unspecifiedDelta = _afterSwap(sender, key, params, delta, hookData);
        return (IFeastCLHooks.afterSwap.selector, unspecifiedDelta);
    }

    /// @inheritdoc IFeastLockCallback
    function lockAcquired(bytes calldata data) external onlyVault returns (bytes memory) {
        return _lockAcquired(data);
    }

    // --- to be filled in by FeastHook ------------------------------------

    /// @dev Who may bring a pool carrying this hook into existence. The factory,
    ///      and by default nobody else. A subclass that knows more about a pool
    ///      than the base does may widen it.
    function _mayInitialize(address sender, PoolKey calldata) internal view virtual returns (bool) {
        return sender == factory;
    }

    function _onPoolInitialized(PoolKey calldata key) internal virtual;

    function _beforeSwap(
        address,
        PoolKey calldata,
        IFeastCLPoolManager.SwapParams calldata,
        bytes calldata
    ) internal virtual returns (BeforeSwapDelta) {
        return ZERO_BEFORE_SWAP_DELTA;
    }

    function _afterSwap(
        address,
        PoolKey calldata,
        IFeastCLPoolManager.SwapParams calldata,
        BalanceDelta,
        bytes calldata
    ) internal virtual returns (int128) {
        return 0;
    }

    function _lockAcquired(bytes calldata) internal virtual returns (bytes memory) {
        return "";
    }
}
