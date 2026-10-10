// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Currency} from "./Currency.sol";

/// @notice Identifies a pool on the venue.
/// @dev Six fields, not the five that ecosystems built on the other singleton
///      use: this venue adds `poolManager`, and `tickSpacing` is not a field at
///      all — it is packed into `parameters` alongside the hook permission
///      bitmap. Every ported pool-key literal has to be rewritten for this
///      shape, and the `tickSpacing == 0` sentinel some references rely on does
///      not exist here.
/// @dev `hooks` and `poolManager` are declared as `address` rather than as
///      interface types. The encoding is identical — an interface is an address
///      on the wire — and it keeps this file free of imports that would drag the
///      GPL tree in behind them. Asserted in `test/venue/VenueAbi.t.sol`.
struct PoolKey {
    Currency currency0;
    Currency currency1;
    address hooks;
    address poolManager;
    uint24 fee;
    bytes32 parameters;
}
