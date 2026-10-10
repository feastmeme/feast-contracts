// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice A currency is an address. The zero address is the chain's native
///         asset; every other value is an ERC-20.
/// @dev Re-declared rather than imported. The venue's own `Currency.sol` carries
///      an MIT header but its sibling types reach GPL-2.0-or-later libraries,
///      and this file must stay reachable only from permissively licensed code.
///      `test/venue/VenueAbi.t.sol` asserts this declaration encodes and behaves
///      identically to the venue's.
type Currency is address;

using {currencyEquals as ==, currencyLessThan as <, currencyGreaterThan as >} for Currency global;
using CurrencyLibrary for Currency global;

function currencyEquals(Currency a, Currency b) pure returns (bool) {
    return Currency.unwrap(a) == Currency.unwrap(b);
}

function currencyLessThan(Currency a, Currency b) pure returns (bool) {
    return Currency.unwrap(a) < Currency.unwrap(b);
}

function currencyGreaterThan(Currency a, Currency b) pure returns (bool) {
    return Currency.unwrap(a) > Currency.unwrap(b);
}

library CurrencyLibrary {
    function isNative(Currency currency) internal pure returns (bool) {
        return Currency.unwrap(currency) == address(0);
    }

    function toAddress(Currency currency) internal pure returns (address) {
        return Currency.unwrap(currency);
    }
}
