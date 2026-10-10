// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice What every contract the genesis call names must say about itself.
/// @dev Round 2 (M1) broke the second list of "addresses genesis may not name"
///      — an oracle, a ledger, the hook itself all have code and no way to spend
///      an allocation. A list of the wrong answers can never be complete, so
///      genesis asks for the right one instead: a recipient must report the role
///      it was built for and the platform coin it serves. Any other contract —
///      one of feast's own, the venue's, a stray — does not implement this and
///      is refused.
interface IFeastGenesisRecipient {
    function genesisRole() external view returns (bytes32);
    function platformCoin() external view returns (address);
}
